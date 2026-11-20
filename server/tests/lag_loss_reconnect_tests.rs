use std::collections::{HashSet, VecDeque};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use phantom_court_server::config::ServerConfig;
use phantom_court_server::net::{spawn_game_server, NetLinkConfig, SimulatedNetLink};
use phantom_court_server::protocol::{
    decode_packet, encode_packet, ClientInputBatchMsg, EventAckMsg, HelloJoinMsg,
    MatchEventPayload, NetMessage, Packet, PlayerInputFrameWire, ReconnectRequestMsg,
    ServerWorldSnapshotMsg, WelcomeJoinedMsg, BTN_SPRINT, STATE_DISCONNECTED_GRACE,
};
use tokio::net::UdpSocket;

async fn join_via_addr(
    target_addr: std::net::SocketAddr,
    name: &str,
    archetype_id: u8,
) -> (UdpSocket, WelcomeJoinedMsg) {
    let sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    sock.connect(target_addr).await.unwrap();
    let mut buf = vec![0u8; 2048];
    let mut retry = tokio::time::interval(Duration::from_millis(120));
    let mut pkt_seq = 1u32;
    let deadline = Instant::now() + Duration::from_secs(4);

    while Instant::now() < deadline {
        tokio::select! {
            _ = retry.tick() => {
                let hello = Packet::new(
                    pkt_seq,
                    0,
                    0,
                    NetMessage::HelloJoin(HelloJoinMsg {
                        username: name.to_string(),
                        archetype_id,
                        room_id: "lossy-court".to_string(),
                        auth_token: String::new(),
                        preferred_team: 255,
                    }),
                );
                let _ = sock.send(&encode_packet(&hello)).await;
                pkt_seq += 1;
            }
            res = tokio::time::timeout(Duration::from_millis(100), sock.recv(&mut buf)) => {
                if let Ok(Ok(n)) = res {
                    if let Ok(pkt) = decode_packet(&buf[..n]) {
                        if let NetMessage::WelcomeJoined(w) = pkt.payload {
                            return (sock, w);
                        }
                    }
                }
            }
        }
    }
    panic!("Timed out joining {name} through simulated net link");
}

#[tokio::test]
async fn redundant_input_batching_zero_lost_inputs_and_reliable_events_under_100ms_rtt_10pct_loss() {
    let cfg = ServerConfig::for_ephemeral_test();
    let server = spawn_game_server(cfg).await.expect("spawn server");

    // 100ms RTT (50ms one-way) + 10% packet loss + 12ms jitter + 15% out-of-order delivery
    let link_a = SimulatedNetLink::spawn(
        server.udp_addr,
        NetLinkConfig {
            one_way_latency_ms: 50,
            jitter_ms: 12,
            loss_rate: 0.10,
            reorder_rate: 0.15,
            seed: 0x1111_2222,
        },
    )
    .await
    .unwrap();

    let link_b = SimulatedNetLink::spawn(
        server.udp_addr,
        NetLinkConfig {
            one_way_latency_ms: 50,
            jitter_ms: 12,
            loss_rate: 0.10,
            reorder_rate: 0.15,
            seed: 0x3333_4444,
        },
    )
    .await
    .unwrap();

    let (sock_a, welcome_a) = join_via_addr(link_a.client_facing_addr(), "ClientA", 0).await;
    let (sock_b, welcome_b) = join_via_addr(link_b.client_facing_addr(), "ClientB", 3).await;

    // Inject 4 reliable match events to verify reliable delivery & ACK under 10% loss
    for i in 1..=4u16 {
        server.inject_reliable_event(MatchEventPayload::Score {
            team_id: 0,
            delta: 2,
            is_three: false,
            new_score: i * 2,
            scorer_id: welcome_a.player_id as u16,
        });
    }

    // Stream 90 sequential 60 Hz inputs from Client A using 4-frame redundant ClientInputBatch,
    // plus send tail flush batches so the final 3 inputs also survive 10% loss cleanly!
    const TOTAL_INPUTS: u32 = 90;
    let mut window_a: VecDeque<PlayerInputFrameWire> = VecDeque::with_capacity(4);
    let mut pkt_seq_a = 10u32;
    let mut pkt_seq_b = 10u32;

    let mut received_events_a: HashSet<u32> = HashSet::new();
    let mut received_events_b: HashSet<u32> = HashSet::new();
    let mut latest_snap_a: Option<ServerWorldSnapshotMsg> = None;
    let mut latest_snap_b: Option<ServerWorldSnapshotMsg> = None;

    let mut tick_int = tokio::time::interval(Duration::from_millis(16));
    let mut buf_a = vec![0u8; 2048];
    let mut buf_b = vec![0u8; 2048];

    // Run 90 input ticks + 35 drain/flush ticks (~2.0s total)
    for step in 1..=(TOTAL_INPUTS + 35) {
        tick_int.tick().await;

        if step <= TOTAL_INPUTS {
            let f = PlayerInputFrameWire::from_floats(step, step, 1.0, 0.0, 0.0, 1.0, BTN_SPRINT, 0.0);
            window_a.push_back(f);
            while window_a.len() > 4 {
                window_a.pop_front();
            }
        }
        // Send redundant batch carrying up to last 4 inputs
        let batch_a = Packet::new(
            pkt_seq_a,
            0,
            0,
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token: welcome_a.session_token,
                frames: window_a.iter().copied().collect(),
            }),
        );
        let _ = sock_a.send(&encode_packet(&batch_a)).await;
        pkt_seq_a += 1;

        // Client B sends a simple input batch too so both clients move & converge
        let fb = PlayerInputFrameWire::from_floats(
            step.min(TOTAL_INPUTS),
            step.min(TOTAL_INPUTS),
            -1.0,
            0.0,
            0.0,
            1.0,
            0,
            0.0,
        );
        let batch_b = Packet::new(
            pkt_seq_b,
            0,
            0,
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token: welcome_b.session_token,
                frames: vec![fb],
            }),
        );
        let _ = sock_b.send(&encode_packet(&batch_b)).await;
        pkt_seq_b += 1;

        // Drain incoming packets for Client A
        while let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(1), sock_a.recv(&mut buf_a)).await {
            if let Ok(pkt) = decode_packet(&buf_a[..n]) {
                match pkt.payload {
                    NetMessage::ServerWorldSnapshot(s) => latest_snap_a = Some(s),
                    NetMessage::ReliableMatchEvent(ev) => {
                        received_events_a.insert(ev.event_id);
                        let ack = Packet::new(
                            pkt_seq_a,
                            pkt.header.seq,
                            0,
                            NetMessage::EventAck(EventAckMsg {
                                session_token: welcome_a.session_token,
                                event_id: ev.event_id,
                                ack_mask: 0,
                            }),
                        );
                        pkt_seq_a += 1;
                        let _ = sock_a.send(&encode_packet(&ack)).await;
                    }
                    _ => {}
                }
            }
        }

        // Drain incoming packets for Client B
        while let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(1), sock_b.recv(&mut buf_b)).await {
            if let Ok(pkt) = decode_packet(&buf_b[..n]) {
                match pkt.payload {
                    NetMessage::ServerWorldSnapshot(s) => latest_snap_b = Some(s),
                    NetMessage::ReliableMatchEvent(ev) => {
                        received_events_b.insert(ev.event_id);
                        let ack = Packet::new(
                            pkt_seq_b,
                            pkt.header.seq,
                            0,
                            NetMessage::EventAck(EventAckMsg {
                                session_token: welcome_b.session_token,
                                event_id: ev.event_id,
                                ack_mask: 0,
                            }),
                        );
                        pkt_seq_b += 1;
                        let _ = sock_b.send(&encode_packet(&ack)).await;
                    }
                    _ => {}
                }
            }
        }
    }

    // 1. Verify simulated link genuinely dropped & reordered packets!
    let stats_a = link_a.stats();
    let dropped_c2s = stats_a.c2s_dropped.load(Ordering::Relaxed);
    let reordered_c2s = stats_a.c2s_reordered.load(Ordering::Relaxed);
    assert!(
        dropped_c2s > 0,
        "SimulatedNetLink must actually drop C2S packets at 10% loss (got {dropped_c2s})"
    );
    assert!(
        reordered_c2s > 0,
        "SimulatedNetLink must actually reorder C2S packets at 15% reorder (got {reordered_c2s})"
    );

    // 2. Verify ZERO DROPPED INPUTS for Client A via 4-frame redundant batching!
    let metrics = server.get_metrics().await.unwrap();
    let (_, last_seq_a, total_proc_a) = metrics
        .player_inputs_processed
        .iter()
        .copied()
        .find(|(pid, _, _)| *pid == welcome_a.player_id)
        .expect("Client A metrics present");
    assert_eq!(
        last_seq_a, TOTAL_INPUTS,
        "Server must reach final input seq {TOTAL_INPUTS} despite {dropped_c2s} dropped packets"
    );
    assert_eq!(
        total_proc_a, TOTAL_INPUTS as u64,
        "Redundant 4-frame batching must yield ZERO missing inputs ({total_proc_a}/{TOTAL_INPUTS})"
    );

    // 3. Verify reliable match events were delivered to BOTH clients despite 10% packet loss
    assert!(
        received_events_a.len() >= 4,
        "Client A must receive all reliable events under 10% loss (got {})",
        received_events_a.len()
    );
    assert!(
        received_events_b.len() >= 4,
        "Client B must receive all reliable events under 10% loss (got {})",
        received_events_b.len()
    );

    // 4. Verify snapshot convergence across both clients
    let snap_a = latest_snap_a.expect("Client A received snapshots");
    let snap_b = latest_snap_b.expect("Client B received snapshots");
    let pa_from_a = snap_a
        .players
        .iter()
        .find(|p| p.player_id == welcome_a.player_id as u16)
        .unwrap();
    let pa_from_b = snap_b
        .players
        .iter()
        .find(|p| p.player_id == welcome_a.player_id as u16)
        .unwrap();
    assert!(pa_from_a.pos()[0] > 4.0, "Client A moved across court");
    assert!(
        (pa_from_a.pos()[0] - pa_from_b.pos()[0]).abs() < 1.5,
        "Client A and Client B snapshots converged (A={:.2}, B={:.2})",
        pa_from_a.pos()[0],
        pa_from_b.pos()[0]
    );

    server.shutdown().await;
}

#[tokio::test]
async fn mid_match_disconnect_grace_window_and_token_reconnect_from_new_udp_port() {
    let mut cfg = ServerConfig::for_ephemeral_test();
    // Fast idle disconnect timeout (250ms) while preserving full 30-second reconnect grace window!
    cfg.idle_disconnect_timeout = Duration::from_millis(250);
    cfg.reconnect_grace_window = Duration::from_secs(30);
    let server = spawn_game_server(cfg).await.expect("spawn server");

    // Join Client 1 and Client 2
    let (sock1_old, welcome1) = join_via_addr(server.udp_addr, "Reconnector", 2).await;
    let old_local_port = sock1_old.local_addr().unwrap().port();
    let (sock2, _welcome2) = join_via_addr(server.udp_addr, "Observer", 1).await;

    // Fill Client 1's Zone meter and move Client 1 to verify state preservation across reconnect!
    server.set_player_zone_full(welcome1.player_id);
    for seq in 1..=30u32 {
        let f = PlayerInputFrameWire::from_floats(seq, seq, 1.0, 0.0, 0.0, 1.0, BTN_SPRINT, 0.0);
        let batch = Packet::new(
            seq + 1,
            0,
            0,
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token: welcome1.session_token,
                frames: vec![f],
            }),
        );
        sock1_old.send(&encode_packet(&batch)).await.unwrap();

        // Keep Observer (Client 2) active so it does not hit the short test idle timeout
        let f2 = PlayerInputFrameWire::from_floats(seq, seq, 0.0, 0.0, 0.0, 0.0, 0, 0.0);
        let batch2 = Packet::new(
            seq + 1,
            0,
            0,
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token: _welcome2.session_token,
                frames: vec![f2],
            }),
        );
        sock2.send(&encode_packet(&batch2)).await.unwrap();
        tokio::time::sleep(Duration::from_millis(16)).await;
    }

    // Record pre-disconnect position via Client 2 snapshot once server has processed all 30 inputs
    let mut buf = vec![0u8; 2048];
    let mut pre_pos_x = 0.0f32;
    let wait_move_deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < wait_move_deadline {
        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(80), sock2.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                if let NetMessage::ServerWorldSnapshot(s) = pkt.payload {
                    if let Some(p1) = s.players.iter().find(|p| p.player_id == welcome1.player_id as u16) {
                        pre_pos_x = p1.pos()[0];
                        if p1.last_processed_input_seq >= 30 {
                            break;
                        }
                    }
                }
            }
        }
    }
    assert!(pre_pos_x > 1.5, "Client 1 should have moved before disconnect (x={pre_pos_x})");

    // Simulate hard disconnect: DROP old UDP socket completely!
    drop(sock1_old);

    // Keep Client 2 alive and wait for Client 1 to enter the 30s grace window!
    let mut saw_grace_flag = false;
    let grace_deadline = Instant::now() + Duration::from_secs(2);
    let mut keepalive_seq = 1u32;
    while Instant::now() < grace_deadline {
        let f = PlayerInputFrameWire::from_floats(keepalive_seq, keepalive_seq, 0.0, 0.0, 0.0, 0.0, 0, 0.0);
        let _ = sock2
            .send(&encode_packet(&Packet::new(
                keepalive_seq + 5,
                0,
                0,
                NetMessage::ClientInputBatch(ClientInputBatchMsg {
                    session_token: _welcome2.session_token,
                    frames: vec![f],
                }),
            )))
            .await;
        keepalive_seq += 1;

        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(80), sock2.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                if let NetMessage::ServerWorldSnapshot(s) = pkt.payload {
                    if let Some(p1) = s.players.iter().find(|p| p.player_id == welcome1.player_id as u16) {
                        if (p1.state_flags & STATE_DISCONNECTED_GRACE) != 0 {
                            saw_grace_flag = true;
                            // Entity, slot, and Zone must remain preserved during grace window!
                            assert_eq!(p1.slot, welcome1.assigned_slot);
                            assert!(p1.zone() >= 99.0, "Zone meter preserved during grace window");
                            break;
                        }
                    }
                }
            }
        }
    }
    assert!(saw_grace_flag, "Server must place dropped client in 30s reconnect grace window");

    // Emit a reliable event while Client 1 is disconnected to test reconnect event replay!
    server.inject_reliable_event(MatchEventPayload::Score {
        team_id: 1,
        delta: 3,
        is_three: true,
        new_score: 3,
        scorer_id: _welcome2.player_id as u16,
    });
    tokio::time::sleep(Duration::from_millis(60)).await;

    // Now open a BRAND-NEW UDP socket on a different ephemeral local port and reconnect via session_token!
    let sock1_new = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let new_local_port = sock1_new.local_addr().unwrap().port();
    assert_ne!(
        new_local_port, old_local_port,
        "Reconnect test must use a brand-new UDP source port"
    );
    sock1_new.connect(server.udp_addr).await.unwrap();

    let recon_pkt = Packet::new(
        1,
        0,
        0,
        NetMessage::ReconnectRequest(ReconnectRequestMsg {
            session_token: welcome1.session_token,
            last_acked_event_id: 0,
        }),
    );
    sock1_new.send(&encode_packet(&recon_pkt)).await.unwrap();

    let mut reconnected_welcome: Option<WelcomeJoinedMsg> = None;
    let mut got_live_snapshot = false;
    let mut got_replayed_score = false;

    let recon_deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < recon_deadline
        && !(reconnected_welcome.is_some() && got_live_snapshot && got_replayed_score)
    {
        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(100), sock1_new.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                match pkt.payload {
                    NetMessage::WelcomeJoined(w) => {
                        reconnected_welcome = Some(w);
                    }
                    NetMessage::ServerWorldSnapshot(s) => {
                        if let Some(p1) = s.players.iter().find(|p| p.player_id == welcome1.player_id as u16) {
                            assert_eq!(p1.state_flags & STATE_DISCONNECTED_GRACE, 0);
                            assert!((p1.pos()[0] - pre_pos_x).abs() < 0.25);
                            assert!(p1.zone() >= 99.0);
                            got_live_snapshot = true;
                        }
                    }
                    NetMessage::ReliableMatchEvent(ev) => {
                        if matches!(ev.event, MatchEventPayload::Score { delta: 3, .. }) {
                            got_replayed_score = true;
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    let rw = reconnected_welcome.expect("Must receive WelcomeJoined on reconnect");
    assert_eq!(rw.player_id, welcome1.player_id);
    assert_eq!(rw.team_id, welcome1.team_id);
    assert_eq!(rw.assigned_slot, welcome1.assigned_slot);
    assert_eq!(rw.session_token, welcome1.session_token);
    assert!(got_live_snapshot, "Must immediately resume live snapshots on new UDP port");
    assert!(got_replayed_score, "Must replay reliable events missed during disconnect");

    // Verify reconnected client can continue sending inputs from the new UDP port!
    for seq in 31..=45u32 {
        let f = PlayerInputFrameWire::from_floats(seq, seq, 0.0, 1.0, 0.0, 1.0, BTN_SPRINT, 0.0);
        let batch = Packet::new(
            seq,
            0,
            0,
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token: welcome1.session_token,
                frames: vec![f],
            }),
        );
        sock1_new.send(&encode_packet(&batch)).await.unwrap();
        tokio::time::sleep(Duration::from_millis(16)).await;
    }

    let metrics = server.get_metrics().await.unwrap();
    let (_, last_seq, _) = metrics
        .player_inputs_processed
        .iter()
        .copied()
        .find(|(pid, _, _)| *pid == welcome1.player_id)
        .unwrap();
    assert!(
        last_seq >= 40,
        "Reconnected client must control its preserved player entity from new port (last_seq={last_seq})"
    );

    server.shutdown().await;
}
