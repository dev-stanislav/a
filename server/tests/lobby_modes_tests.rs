use std::net::SocketAddr;
use std::time::{Duration, Instant};

use phantom_court_server::config::ServerConfig;
use phantom_court_server::net::spawn_game_server;
use phantom_court_server::protocol::{
    decode_packet, encode_packet, ClientInputBatchMsg, HelloJoinMsg, MatchEventPayload, NetMessage,
    Packet, PlayerInputFrameWire, ServerWorldSnapshotMsg, SpectatorJoinMsg, WelcomeJoinedMsg,
    BTN_SPRINT,
};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};

async fn http_json(
    http_addr: SocketAddr,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> (u16, Value) {
    let mut stream = TcpStream::connect(http_addr).await.expect("tcp connect");
    let body_str = body.map(|v| v.to_string()).unwrap_or_default();
    let req = if body_str.is_empty() {
        format!(
            "{method} {path} HTTP/1.1\r\nHost: {http_addr}\r\nConnection: close\r\n\r\n"
        )
    } else {
        format!(
            "{method} {path} HTTP/1.1\r\nHost: {http_addr}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body_str}",
            body_str.len()
        )
    };
    stream.write_all(req.as_bytes()).await.unwrap();
    let mut resp = String::new();
    stream.read_to_string(&mut resp).await.unwrap();
    let status_line = resp.lines().next().unwrap_or("");
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let body_part = resp.split("\r\n\r\n").nth(1).unwrap_or("");
    let parsed: Value = serde_json::from_str(body_part).unwrap_or_else(|_| json!({ "raw": body_part }));
    (status, parsed)
}

async fn udp_hello_join(
    server_udp: SocketAddr,
    room_id: &str,
    username: &str,
    archetype_id: u8,
) -> (UdpSocket, WelcomeJoinedMsg) {
    let sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    sock.connect(server_udp).await.unwrap();
    let hello = Packet::new(
        1,
        0,
        0,
        NetMessage::HelloJoin(HelloJoinMsg {
            username: username.to_string(),
            archetype_id,
            room_id: room_id.to_string(),
            auth_token: String::new(),
            preferred_team: 255,
        }),
    );
    sock.send(&encode_packet(&hello)).await.unwrap();
    let mut buf = vec![0u8; 2048];
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(120), sock.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                if let NetMessage::WelcomeJoined(w) = pkt.payload {
                    return (sock, w);
                }
            }
        }
    }
    panic!("Timed out waiting for WelcomeJoined for {username} in room {room_id}");
}

async fn udp_spectator_join(
    server_udp: SocketAddr,
    room_id: &str,
    name: &str,
) -> (UdpSocket, WelcomeJoinedMsg) {
    let sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    sock.connect(server_udp).await.unwrap();
    let pkt = Packet::new(
        1,
        0,
        0,
        NetMessage::SpectatorJoin(SpectatorJoinMsg {
            room_id: room_id.to_string(),
            spectator_name: name.to_string(),
        }),
    );
    sock.send(&encode_packet(&pkt)).await.unwrap();
    let mut buf = vec![0u8; 2048];
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(120), sock.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                if let NetMessage::WelcomeJoined(w) = pkt.payload {
                    return (sock, w);
                }
            }
        }
    }
    panic!("Timed out waiting for Spectator WelcomeJoined in room {room_id}");
}

async fn wait_for_player_ack(
    sock: &UdpSocket,
    target_player_id: u32,
    min_input_seq: u32,
    timeout: Duration,
) -> Option<ServerWorldSnapshotMsg> {
    let mut buf = vec![0u8; 2048];
    let deadline = Instant::now() + timeout;
    let mut latest = None;
    while Instant::now() < deadline {
        let rem = deadline.saturating_duration_since(Instant::now());
        if rem.is_zero() {
            break;
        }
        if let Ok(Ok(n)) = tokio::time::timeout(rem.min(Duration::from_millis(80)), sock.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                if let NetMessage::ServerWorldSnapshot(s) = pkt.payload {
                    let ack_ok = s
                        .players
                        .iter()
                        .find(|p| p.player_id == target_player_id as u16)
                        .map_or(false, |p| p.last_processed_input_seq >= min_input_seq);
                    latest = Some(s);
                    if ack_ok {
                        return latest;
                    }
                }
            }
        }
    }
    latest
}

async fn recv_latest_snapshot(
    sock: &UdpSocket,
    min_tick: u32,
    timeout: Duration,
) -> Option<ServerWorldSnapshotMsg> {
    let mut buf = vec![0u8; 2048];
    let deadline = Instant::now() + timeout;
    let mut latest = None;
    while Instant::now() < deadline {
        let rem = deadline.saturating_duration_since(Instant::now());
        if rem.is_zero() {
            break;
        }
        if let Ok(Ok(n)) = tokio::time::timeout(rem.min(Duration::from_millis(80)), sock.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                if let NetMessage::ServerWorldSnapshot(s) = pkt.payload {
                    let t = s.server_tick;
                    latest = Some(s);
                    if t >= min_tick {
                        return latest;
                    }
                }
            }
        }
    }
    latest
}

#[tokio::test]
async fn health_and_1v1_matchmaking_ready_gate_and_room_isolation() {
    let server = spawn_game_server(ServerConfig::for_ephemeral_test())
        .await
        .expect("spawn server");

    // 1. Health reports rooms_count and supported_modes
    let (code, health) = http_json(server.http_addr, "GET", "/health", None).await;
    assert_eq!(code, 200);
    assert_eq!(health["status"], "ok");
    assert!(health["rooms_count"].as_u64().unwrap() >= 1);
    let modes = health["supported_modes"].as_array().unwrap();
    assert!(modes.iter().any(|v| v == "1v1"));
    assert!(modes.iter().any(|v| v == "2v2"));
    assert!(modes.iter().any(|v| v == "3v3"));
    assert!(modes.iter().any(|v| v == "private"));
    assert!(modes.iter().any(|v| v == "spectator"));

    // 2. Enqueue Player A + cancel a separate queued ticket cleanly
    let (c, t_cancel) = http_json(
        server.http_addr,
        "POST",
        "/api/matchmaking/enqueue",
        Some(json!({ "mode": "1v1", "username": "CancelMe", "archetype": "playmaker" })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(t_cancel["status"], "queued");
    let cancel_id = t_cancel["ticket_id"].as_str().unwrap().to_string();

    let (c, cancel_res) = http_json(
        server.http_addr,
        "POST",
        "/api/matchmaking/cancel",
        Some(json!({ "ticket_id": cancel_id })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(cancel_res["cancelled"], true);

    // Enqueue Player A -> queued
    let (c, t_a) = http_json(
        server.http_addr,
        "POST",
        "/api/matchmaking/enqueue",
        Some(json!({ "mode": "1v1", "username": "Alice", "archetype": "speedster", "rating": 1200 })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(t_a["status"], "queued");
    let ticket_a = t_a["ticket_id"].as_str().unwrap().to_string();

    // Enqueue Player B -> immediately matches with Alice into a 1v1 Lobby room!
    let (c, t_b) = http_json(
        server.http_addr,
        "POST",
        "/api/matchmaking/enqueue",
        Some(json!({ "mode": "1v1", "username": "Bob", "archetype": "powerhouse", "rating": 1220 })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(t_b["status"], "matched");
    let room_id = t_b["room_id"].as_u64().unwrap() as u32;
    let member_b = t_b["member_id"].as_str().unwrap().to_string();
    assert!(room_id >= 1);

    // Check Alice's matchmaking status reflects the exact matched room
    let (c, status_a) = http_json(
        server.http_addr,
        "GET",
        &format!("/api/matchmaking/status/{ticket_a}"),
        None,
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(status_a["status"], "matched");
    assert_eq!(status_a["room_id"], room_id);
    let member_a = status_a["member_id"].as_str().unwrap().to_string();

    // 3. Ready Check Gate: Alice readies -> MUST NOT start until Bob is also ready!
    let (c, r1) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/ready"),
        Some(json!({ "member_id": member_a, "ready": true })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(r1["started"], false);
    assert_eq!(r1["state"], "Lobby");

    // Bob readies -> transitions Lobby -> InMatch!
    let (c, r2) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/ready"),
        Some(json!({ "member_id": member_b, "ready": true })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(r2["started"], true);
    assert_eq!(r2["state"], "InMatch");
    assert_eq!(r2["lobby_state"]["world_player_count"], 2);

    // 4. Connect both players via UDP to their exact matched room & verify room isolation vs room 0
    let (sock_a, w_a) = udp_hello_join(server.udp_addr, &room_id.to_string(), "Alice", 0).await;
    let (sock_b, w_b) = udp_hello_join(server.udp_addr, &room_id.to_string(), "Bob", 3).await;
    assert_ne!(w_a.team_id, w_b.team_id);

    // Connect an unrelated player to default room 0 to verify complete room isolation!
    let (sock_r0, _w_r0) = udp_hello_join(server.udp_addr, "0", "RoomZeroPlayer", 1).await;

    // Move Alice inside matched room
    for seq in 1..=18u32 {
        let f = PlayerInputFrameWire::from_floats(seq, seq, 1.0, 0.0, 0.0, 1.0, BTN_SPRINT, 0.0);
        let pkt = Packet::new(
            seq + 1,
            0,
            0,
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token: w_a.session_token,
                frames: vec![f],
            }),
        );
        sock_a.send(&encode_packet(&pkt)).await.unwrap();
        tokio::time::sleep(Duration::from_millis(16)).await;
    }

    let snap_b = wait_for_player_ack(&sock_b, w_a.player_id, 18, Duration::from_secs(2))
        .await
        .expect("Bob receives live 1v1 snapshots");
    assert_eq!(snap_b.players.len(), 2, "1v1 room must contain ONLY its 2 players");
    let alice_in_b = snap_b
        .players
        .iter()
        .find(|p| p.player_id == w_a.player_id as u16)
        .unwrap();
    assert!(
        alice_in_b.pos()[0] > 0.8,
        "Bob sees Alice move across court (pos_x={})",
        alice_in_b.pos()[0]
    );

    let snap_r0 = recv_latest_snapshot(&sock_r0, 15, Duration::from_secs(1))
        .await
        .expect("Room 0 receives its own isolated snapshot");
    assert_eq!(
        snap_r0.players.len(),
        1,
        "Room 0 must remain isolated from Room {room_id}"
    );

    server.shutdown().await;
}

#[tokio::test]
async fn online_2v2_and_3v3_with_fill_bots_and_full_human_2v2_gate() {
    let server = spawn_game_server(ServerConfig::for_ephemeral_test())
        .await
        .expect("spawn server");

    // 1. 2v2 with 2 humans + fill_bots=true -> spawns 4 players on court (2 humans + 2 bots)!
    let (c, room2) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms",
        Some(json!({
            "mode": "2v2",
            "is_private": false,
            "fill_bots": true,
            "host_username": "Duo1",
            "archetype": "speedster"
        })),
    )
    .await;
    assert_eq!(c, 200);
    let r2_id = room2["room_id"].as_u64().unwrap() as u32;
    let m2_1 = room2["member_id"].as_str().unwrap().to_string();

    let (c, join2) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms/join",
        Some(json!({ "room_id": r2_id, "username": "Duo2", "archetype": "powerhouse" })),
    )
    .await;
    assert_eq!(c, 200);
    let m2_2 = join2["member_id"].as_str().unwrap().to_string();

    let (_, r2_a) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{r2_id}/ready"),
        Some(json!({ "member_id": m2_1, "ready": true })),
    )
    .await;
    assert_eq!(r2_a["started"], false);

    let (_, r2_b) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{r2_id}/ready"),
        Some(json!({ "member_id": m2_2, "ready": true })),
    )
    .await;
    assert_eq!(r2_b["started"], true);
    assert_eq!(r2_b["lobby_state"]["world_player_count"], 4);

    // 2. 3v3 with 2 humans + fill_bots=true -> spawns 6 players on court (2 humans + 4 bots) & bots move!
    let (c, room3) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms",
        Some(json!({
            "mode": "3v3",
            "is_private": false,
            "fill_bots": true,
            "host_username": "Trio1",
            "archetype": "playmaker"
        })),
    )
    .await;
    assert_eq!(c, 200);
    let r3_id = room3["room_id"].as_u64().unwrap() as u32;
    let m3_1 = room3["member_id"].as_str().unwrap().to_string();

    let (c, join3) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms/join",
        Some(json!({ "room_id": r3_id, "username": "Trio2", "archetype": "sharpshooter" })),
    )
    .await;
    assert_eq!(c, 200);
    let m3_2 = join3["member_id"].as_str().unwrap().to_string();

    http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{r3_id}/ready"),
        Some(json!({ "member_id": m3_1, "ready": true })),
    )
    .await;
    let (c, start3) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{r3_id}/ready"),
        Some(json!({ "member_id": m3_2, "ready": true })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(start3["started"], true);
    assert_eq!(start3["lobby_state"]["world_player_count"], 6);

    let (sock3, w3) = udp_hello_join(server.udp_addr, &r3_id.to_string(), "Trio1", 2).await;
    let snap_early = recv_latest_snapshot(&sock3, 1, Duration::from_secs(1))
        .await
        .expect("early 3v3 snapshot");
    assert_eq!(snap_early.players.len(), 6, "3v3 with bots must stream all 6 players");

    // Let authoritative server-side bots run for ~450ms and confirm bots actually move!
    tokio::time::sleep(Duration::from_millis(450)).await;
    let snap_later = recv_latest_snapshot(&sock3, snap_early.server_tick + 20, Duration::from_secs(1))
        .await
        .expect("later 3v3 snapshot");
    assert_eq!(snap_later.players.len(), 6);
    let bot_moved = snap_later.players.iter().any(|p| {
        if p.player_id == w3.player_id as u16 {
            return false;
        }
        if let Some(prev) = snap_early.players.iter().find(|o| o.player_id == p.player_id) {
            let dx = p.pos()[0] - prev.pos()[0];
            let dz = p.pos()[2] - prev.pos()[2];
            (dx * dx + dz * dz).sqrt() > 0.25
        } else {
            false
        }
    });
    assert!(bot_moved, "Server-side AI bots must actively step and move on court");

    // 3. Full 4-human 2v2 with fill_bots=false enforces full team requirement!
    let (_, r_full) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms",
        Some(json!({
            "mode": "2v2",
            "is_private": false,
            "fill_bots": false,
            "host_username": "H1",
            "archetype": "speedster"
        })),
    )
    .await;
    let rf_id = r_full["room_id"].as_u64().unwrap() as u32;
    let mut member_ids = vec![r_full["member_id"].as_str().unwrap().to_string()];
    for name in ["H2", "H3", "H4"] {
        let (sc, j) = http_json(
            server.http_addr,
            "POST",
            "/api/rooms/join",
            Some(json!({ "room_id": rf_id, "username": name, "archetype": "all_rounder" })),
        )
        .await;
        assert_eq!(sc, 200);
        member_ids.push(j["member_id"].as_str().unwrap().to_string());
    }
    // 5th player rejected with 409 Conflict (room full)
    let (sc_overflow, _) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms/join",
        Some(json!({ "room_id": rf_id, "username": "Overflow", "archetype": "all_rounder" })),
    )
    .await;
    assert_eq!(sc_overflow, 409);

    for (idx, mid) in member_ids.iter().enumerate() {
        let (sc, rr) = http_json(
            server.http_addr,
            "POST",
            &format!("/api/rooms/{rf_id}/ready"),
            Some(json!({ "member_id": mid, "ready": true })),
        )
        .await;
        assert_eq!(sc, 200);
        if idx < 3 {
            assert_eq!(rr["started"], false);
        } else {
            assert_eq!(rr["started"], true);
            assert_eq!(rr["lobby_state"]["world_player_count"], 4);
        }
    }

    server.shutdown().await;
}

#[tokio::test]
async fn private_room_code_config_and_rematch_voting_resets_same_room() {
    let server = spawn_game_server(ServerConfig::for_ephemeral_test())
        .await
        .expect("spawn server");

    // 1. Create Private 1v1 Room -> gets unique 6-char room code
    let (c, created) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms",
        Some(json!({
            "mode": "1v1",
            "is_private": true,
            "fill_bots": false,
            "host_username": "HostOne",
            "archetype": "playmaker"
        })),
    )
    .await;
    assert_eq!(c, 200);
    let room_id = created["room_id"].as_u64().unwrap() as u32;
    let room_code = created["room_code"].as_str().unwrap().to_string();
    let host_mid = created["member_id"].as_str().unwrap().to_string();
    assert_eq!(room_code.len(), 6);
    assert!(room_code.chars().all(|ch| ch.is_ascii_alphanumeric()));

    // Private lobby room is NOT listed in public GET /api/rooms while in Lobby
    let (c, listed) = http_json(server.http_addr, "GET", "/api/rooms", None).await;
    assert_eq!(c, 200);
    assert!(
        !listed["rooms"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["room_id"] == room_id),
        "Private lobby room must not appear in public room list"
    );

    // 2. Invalid room code rejected with 404 Not Found
    let (bad_code, _) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms/join",
        Some(json!({ "room_code": "ZZZZ99", "username": "Intruder", "archetype": "speedster" })),
    )
    .await;
    assert_eq!(bad_code, 404);

    // 3. Valid 6-char room code join succeeds
    let (c, joined) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms/join",
        Some(json!({ "room_code": room_code, "username": "GuestTwo", "archetype": "speedster" })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(joined["room_id"], room_id);
    assert_eq!(joined["team_id"], 1);
    let guest_mid = joined["member_id"].as_str().unwrap().to_string();

    // 4. Config: change guest archetype -> sharpshooter; verify full Team 0 switch returns 409
    let (c, cfg_res) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/config"),
        Some(json!({ "member_id": guest_mid, "archetype": "sharpshooter" })),
    )
    .await;
    assert_eq!(c, 200);
    let guest_info = cfg_res["lobby_state"]["members"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["member_id"] == guest_mid)
        .unwrap();
    assert_eq!(guest_info["archetype"], "sharpshooter");

    let (full_team_status, _) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/config"),
        Some(json!({ "member_id": guest_mid, "team": 0 })),
    )
    .await;
    assert_eq!(full_team_status, 409);

    // 5. Ready both -> start match #1 & move HostOne over UDP
    http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/ready"),
        Some(json!({ "member_id": host_mid, "ready": true })),
    )
    .await;
    let (_, started) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/ready"),
        Some(json!({ "member_id": guest_mid, "ready": true })),
    )
    .await;
    assert_eq!(started["started"], true);
    assert_eq!(started["lobby_state"]["match_number"], 1);

    let (sock_host, w_host) =
        udp_hello_join(server.udp_addr, &room_code, "HostOne", 2).await;

    for seq in 1..=20u32 {
        let f = PlayerInputFrameWire::from_floats(seq, seq, 1.0, 0.0, 0.0, 1.0, BTN_SPRINT, 0.0);
        let pkt = Packet::new(
            seq + 1,
            0,
            0,
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token: w_host.session_token,
                frames: vec![f],
            }),
        );
        sock_host.send(&encode_packet(&pkt)).await.unwrap();
        tokio::time::sleep(Duration::from_millis(16)).await;
    }

    let snap_before_end =
        wait_for_player_ack(&sock_host, w_host.player_id, 20, Duration::from_secs(2))
            .await
            .unwrap();
    let host_before = snap_before_end
        .players
        .iter()
        .find(|p| p.player_id == w_host.player_id as u16)
        .unwrap();
    assert!(
        host_before.pos()[0] > 1.0,
        "Host moved before match end (pos_x={})",
        host_before.pos()[0]
    );

    // 6. Trigger match finish -> PostMatch with score 16-12 + authoritative MatchEnd UDP event
    let (c, fin) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/finish"),
        Some(json!({ "score_a": 16, "score_b": 12 })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(fin["state"], "PostMatch");
    assert_eq!(fin["scores"], json!([16, 12]));

    // Verify UDP client receives MatchEnd reliable event
    let mut got_match_end = false;
    let mut buf = vec![0u8; 2048];
    let end_wait = Instant::now() + Duration::from_secs(1);
    while Instant::now() < end_wait {
        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(80), sock_host.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                if let NetMessage::ReliableMatchEvent(ev) = pkt.payload {
                    if matches!(
                        ev.event,
                        MatchEventPayload::MatchEnd {
                            winner_team: 0,
                            score_a: 16,
                            score_b: 12
                        }
                    ) {
                        got_match_end = true;
                        break;
                    }
                }
            }
        }
    }
    assert!(got_match_end, "UDP client must receive authoritative MatchEnd event");

    // 7. Rematch Voting: host votes -> still PostMatch; guest votes -> clean reset to InMatch #2!
    let (c, rv1) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/rematch"),
        Some(json!({ "member_id": host_mid, "vote": true })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(rv1["rematch_started"], false);
    assert_eq!(rv1["state"], "PostMatch");

    let (c, rv2) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/rematch"),
        Some(json!({ "member_id": guest_mid, "vote": true })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(rv2["rematch_started"], true);
    assert_eq!(rv2["state"], "InMatch");
    assert_eq!(rv2["match_number"], 2);
    assert_eq!(rv2["lobby_state"]["scores"], json!([0, 0]));
    assert_eq!(rv2["lobby_state"]["room_code"], room_code);

    // Verify UDP snapshot in same room shows reset score [0,0], reset pos x==0.0, full stamina!
    let snap_rematch =
        recv_latest_snapshot(&sock_host, snap_before_end.server_tick + 5, Duration::from_secs(1))
            .await
            .unwrap();
    assert_eq!(snap_rematch.score_a, 0);
    assert_eq!(snap_rematch.score_b, 0);
    assert_eq!(snap_rematch.players.len(), 2);
    let host_after = snap_rematch
        .players
        .iter()
        .find(|p| p.player_id == w_host.player_id as u16)
        .unwrap();
    assert!(
        host_after.pos()[0].abs() < 0.1,
        "Rematch must reset player position to spawn (x={})",
        host_after.pos()[0]
    );
    assert!(host_after.stamina() >= 99.0, "Rematch must restore full stamina");

    server.shutdown().await;
}

#[tokio::test]
async fn spectator_mode_streams_live_snapshots_with_zero_bodies_and_ignores_inputs() {
    let server = spawn_game_server(ServerConfig::for_ephemeral_test())
        .await
        .expect("spawn server");

    // Start a live 1v1 match
    let (_, cr) = http_json(
        server.http_addr,
        "POST",
        "/api/rooms",
        Some(json!({
            "mode": "1v1",
            "is_private": false,
            "fill_bots": true,
            "host_username": "ProPlayer",
            "archetype": "speedster"
        })),
    )
    .await;
    let room_id = cr["room_id"].as_u64().unwrap() as u32;
    let mid = cr["member_id"].as_str().unwrap().to_string();
    let (sc, _) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/ready"),
        Some(json!({ "member_id": mid, "ready": true })),
    )
    .await;
    assert_eq!(sc, 200);

    // 1. Request HTTP spectator ticket + snapshot preview
    let (sc, spec_ticket) = http_json(
        server.http_addr,
        "POST",
        &format!("/api/rooms/{room_id}/spectate"),
        Some(json!({ "username": "BroadcastCam" })),
    )
    .await;
    assert_eq!(sc, 200);
    assert_eq!(spec_ticket["room_id"], room_id);
    assert_eq!(spec_ticket["udp_port"], server.udp_addr.port());
    assert!(spec_ticket["spectator_token"]
        .as_str()
        .unwrap()
        .starts_with("spec_"));
    assert_eq!(spec_ticket["snapshot_preview"]["player_count"], 2);

    // 2. Connect UDP spectator to exact room -> receives player_id=0, team=255, slot=255
    let (spec_sock, spec_w) =
        udp_spectator_join(server.udp_addr, &room_id.to_string(), "BroadcastCam").await;
    assert_eq!(spec_w.player_id, 0);
    assert_eq!(spec_w.team_id, 255);
    assert_eq!(spec_w.assigned_slot, 255);

    // 3. Spectator attempts to inject forged ClientInputBatch -> MUST be ignored!
    for seq in 1..=10u32 {
        let forged_in = PlayerInputFrameWire::from_floats(seq, seq, 1.0, 1.0, 0.0, 1.0, BTN_SPRINT, 0.0);
        let pkt = Packet::new(
            seq + 1,
            0,
            0,
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token: spec_w.session_token,
                frames: vec![forged_in],
            }),
        );
        spec_sock.send(&encode_packet(&pkt)).await.unwrap();
    }

    // 4. Verify spectator streams live 30 Hz snapshots & room still has strictly 2 players (0 spectator bodies!)
    let mut snap_count = 0usize;
    let mut buf = vec![0u8; 2048];
    let window_end = Instant::now() + Duration::from_millis(450);
    while Instant::now() < window_end {
        if let Ok(Ok(n)) = tokio::time::timeout(Duration::from_millis(60), spec_sock.recv(&mut buf)).await {
            if let Ok(pkt) = decode_packet(&buf[..n]) {
                if let NetMessage::ServerWorldSnapshot(s) = pkt.payload {
                    assert_eq!(
                        s.players.len(),
                        2,
                        "Spectator must NEVER spawn a player body on court"
                    );
                    snap_count += 1;
                }
            }
        }
    }
    assert!(
        snap_count >= 8,
        "Spectator must receive live 30 Hz snapshots (got {snap_count} in 450ms)"
    );

    let (sc, room_state) = http_json(
        server.http_addr,
        "GET",
        &format!("/api/rooms/{room_id}"),
        None,
    )
    .await;
    assert_eq!(sc, 200);
    assert_eq!(room_state["world_player_count"], 2);
    assert_eq!(room_state["spectator_count"], 1);

    server.shutdown().await;
}
