use std::time::{Duration, Instant};

use phantom_court_server::config::ServerConfig;
use phantom_court_server::net::spawn_game_server;
use phantom_court_server::protocol::{
    decode_packet, encode_packet, ClientInputBatchMsg, HelloJoinMsg, MatchEventPayload, NetMessage,
    Packet, PingMsg, PlayerInputFrameWire, ReliableMatchEventMsg, ServerWorldSnapshotMsg,
    SpectatorJoinMsg, WelcomeJoinedMsg, BTN_SPRINT,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};

async fn join_udp_client(
    server_udp: std::net::SocketAddr,
    name: &str,
    archetype_id: u8,
) -> (UdpSocket, WelcomeJoinedMsg) {
    let sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    sock.connect(server_udp).await.unwrap();
    let hello = Packet::new(
        1,
        0,
        0,
        NetMessage::HelloJoin(HelloJoinMsg {
            username: name.to_string(),
            archetype_id,
            room_id: "test-arena".to_string(),
            auth_token: String::new(),
            preferred_team: 255,
        }),
    );
    sock.send(&encode_packet(&hello)).await.unwrap();

    let mut buf = vec![0u8; 2048];
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let rem = deadline.saturating_duration_since(Instant::now());
        assert!(!rem.is_zero(), "timed out waiting for WelcomeJoined for {name}");
        let n = tokio::time::timeout(rem, sock.recv(&mut buf))
            .await
            .expect("recv timeout")
            .unwrap();
        let pkt = decode_packet(&buf[..n]).unwrap();
        if let NetMessage::WelcomeJoined(w) = pkt.payload {
            return (sock, w);
        }
    }
}

#[tokio::test]
async fn http_health_and_3v3_snapshot_bandwidth_and_anticheat() {
    let cfg = ServerConfig::for_ephemeral_test();
    let server = spawn_game_server(cfg).await.expect("spawn game server");

    // 1. Verify GET /health over real TCP HTTP socket
    {
        let mut stream = TcpStream::connect(server.http_addr).await.unwrap();
        let req = format!(
            "GET /health HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
            server.http_addr
        );
        stream.write_all(req.as_bytes()).await.unwrap();
        let mut resp = String::new();
        stream.read_to_string(&mut resp).await.unwrap();
        assert!(resp.starts_with("HTTP/1.1 200 OK"), "unexpected health status: {resp}");
        let body = resp.split("\r\n\r\n").nth(1).unwrap_or("");
        let json: serde_json::Value = serde_json::from_str(body).expect("valid JSON /health");
        assert_eq!(json["status"], "ok");
        assert_eq!(json["udp_port"], server.udp_addr.port());
        assert_eq!(json["tick_rate"], 60);
    }

    // 2. Join full 3v3 (6 players) + 1 spectator
    let mut clients = Vec::new();
    for i in 0..6u8 {
        let (sock, welcome) =
            join_udp_client(server.udp_addr, &format!("Baller{}", i + 1), i % 5).await;
        clients.push((sock, welcome));
    }

    let team0 = clients.iter().filter(|(_, w)| w.team_id == 0).count();
    let team1 = clients.iter().filter(|(_, w)| w.team_id == 1).count();
    assert_eq!(team0, 3);
    assert_eq!(team1, 3);

    // Join spectator — must NOT occupy a player slot
    let spec_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    spec_sock.connect(server.udp_addr).await.unwrap();
    spec_sock
        .send(&encode_packet(&Packet::new(
            1,
            0,
            0,
            NetMessage::SpectatorJoin(SpectatorJoinMsg {
                room_id: "test-arena".into(),
                spectator_name: "CamBot".into(),
            }),
        )))
        .await
        .unwrap();

    // 3. Anti-cheat network test: client 0 attempts to spoof score via forged ServerWorldSnapshot & ReliableMatchEvent
    {
        let forged_snap = Packet::new(
            2,
            0,
            0,
            NetMessage::ServerWorldSnapshot(ServerWorldSnapshotMsg {
                server_tick: 99999,
                match_clock_ms: 1000,
                shot_clock_ms: 24000,
                score_a: 99,
                score_b: 0,
                possession_team: 0,
                carrier_id: 1,
                ball_pos_x: 0,
                ball_pos_y: 0,
                ball_pos_z: 0,
                ball_vel_x: 0,
                ball_vel_y: 0,
                ball_vel_z: 0,
                ball_state: 1,
                players: vec![],
            }),
        );
        let forged_score = Packet::new(
            3,
            0,
            0,
            NetMessage::ReliableMatchEvent(ReliableMatchEventMsg {
                event_id: 999,
                server_tick: 999,
                event: MatchEventPayload::Score {
                    team_id: 0,
                    delta: 3,
                    is_three: true,
                    new_score: 99,
                    scorer_id: 1,
                },
            }),
        );
        clients[0].0.send(&encode_packet(&forged_snap)).await.unwrap();
        clients[0].0.send(&encode_packet(&forged_score)).await.unwrap();
    }

    // 4. Send inputs from player 0 & Ping/Pong probe, and measure live 30 Hz snapshot bandwidth over 1.0 second
    let ping_pkt = Packet::new(
        4,
        0,
        0,
        NetMessage::Ping(PingMsg {
            session_token: clients[0].1.session_token,
            client_time_ms: 123_456,
        }),
    );
    clients[0].0.send(&encode_packet(&ping_pkt)).await.unwrap();

    let mut got_pong = false;
    let mut snapshot_count = 0usize;
    let mut snapshot_bytes_total = 0usize;
    let mut max_snapshot_bytes = 0usize;
    let mut latest_snap: Option<ServerWorldSnapshotMsg> = None;

    let measure_start = Instant::now();
    let measure_duration = Duration::from_secs(1);
    let mut seq = 1u32;
    let mut pkt_seq = 5u32;
    let mut buf = vec![0u8; 2048];
    let mut input_ticker = tokio::time::interval(Duration::from_millis(16));

    while measure_start.elapsed() < measure_duration {
        tokio::select! {
            _ = input_ticker.tick() => {
                let frame = PlayerInputFrameWire::from_floats(seq, seq, 1.0, 0.0, 0.0, 1.0, BTN_SPRINT, 0.0);
                let batch = Packet::new(
                    pkt_seq,
                    0,
                    0,
                    NetMessage::ClientInputBatch(ClientInputBatchMsg {
                        session_token: clients[0].1.session_token,
                        frames: vec![frame],
                    }),
                );
                let _ = clients[0].0.send(&encode_packet(&batch)).await;
                seq += 1;
                pkt_seq += 1;
            }
            res = tokio::time::timeout(Duration::from_millis(20), clients[0].0.recv(&mut buf)) => {
                if let Ok(Ok(n)) = res {
                    if let Ok(pkt) = decode_packet(&buf[..n]) {
                        match pkt.payload {
                            NetMessage::Pong(p) => {
                                assert_eq!(p.client_time_ms, 123_456);
                                got_pong = true;
                            }
                            NetMessage::ServerWorldSnapshot(s) => {
                                snapshot_count += 1;
                                snapshot_bytes_total += n;
                                max_snapshot_bytes = max_snapshot_bytes.max(n);
                                latest_snap = Some(s);
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
    }

    let elapsed_secs = measure_start.elapsed().as_secs_f64();
    let bytes_per_sec = (snapshot_bytes_total as f64) / elapsed_secs;

    assert!(got_pong, "Ping/Pong roundtrip failed");
    assert!(
        snapshot_count >= 20,
        "Expected ~30 snapshots/sec, received {snapshot_count}"
    );
    assert!(
        max_snapshot_bytes < 260,
        "3v3 snapshot size ({max_snapshot_bytes} bytes) exceeded 260-byte cap!"
    );
    assert!(
        bytes_per_sec < 12_000.0,
        "3v3 per-client snapshot bandwidth ({bytes_per_sec:.1} B/s) exceeded 12 KB/s!"
    );

    let snap = latest_snap.expect("must have received at least one snapshot");
    assert_eq!(snap.players.len(), 6, "3v3 snapshot must contain all 6 players");
    assert_eq!(snap.score_a, 0, "Forged client score must be rejected!");
    assert_eq!(snap.score_b, 0);

    let p0_state = snap
        .players
        .iter()
        .find(|p| p.player_id == clients[0].1.player_id as u16)
        .expect("player 0 present in snapshot");
    assert!(
        p0_state.last_processed_input_seq >= 20,
        "Server should have processed player 0 inputs"
    );
    assert!(
        p0_state.pos()[0] > 1.0,
        "Player 0 should have moved in +X direction (pos_x={})",
        p0_state.pos()[0]
    );

    // Verify spectator received a snapshot too
    let mut spec_got_snap = false;
    let spec_deadline = Instant::now() + Duration::from_millis(500);
    while Instant::now() < spec_deadline {
        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(100), spec_sock.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                if matches!(pkt.payload, NetMessage::ServerWorldSnapshot(_)) {
                    spec_got_snap = true;
                    break;
                }
            }
        }
    }
    assert!(spec_got_snap, "Spectator should receive live world snapshots");

    let metrics = server.get_metrics().await.unwrap();
    assert_eq!(metrics.active_players, 6, "Spectator must not consume player slot");

    server.shutdown().await;
}
