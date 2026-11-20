use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use phantom_court_server::config::ServerConfig;
use phantom_court_server::modes::GameMode;
use phantom_court_server::net::spawn_game_server;
use phantom_court_server::protocol::{
    decode_packet, encode_packet, ClientInputBatchMsg, EventAckMsg, HelloJoinMsg, NetMessage,
    Packet, PlayerInputFrameWire, WelcomeJoinedMsg, BTN_JUMP, BTN_SHOOT, BTN_SKILL_E, BTN_SKILL_Q,
    BTN_SPRINT, BTN_STANCE, BTN_STEAL,
};
use phantom_court_server::sim::ArchetypeId;
use tokio::net::UdpSocket;
use tokio::sync::{watch, Barrier};
use tokio::time::MissedTickBehavior;

const NUM_ROOMS: usize = 20;
const PLAYERS_PER_ROOM: usize = 6; // 3v3
const TOTAL_CLIENTS: usize = NUM_ROOMS * PLAYERS_PER_ROOM; // 120 active UDP clients
const TARGET_TICKS: u64 = 300; // 5.0 full seconds @ 60 Hz
const BENCH_DURATION_SECS: f64 = 5.35; // slight margin so all 20 rooms cleanly exceed 300 ticks

#[derive(Debug, Default)]
struct ClientRunStats {
    room_id: u32,
    player_id: u32,
    inputs_sent: u64,
    packets_sent: u64,
    snapshots_received: u64,
    snapshot_bytes_received: u64,
    events_received: u64,
    last_server_tick: u32,
    max_players_seen: usize,
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((p / 100.0) * ((sorted.len() - 1) as f64)).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

fn summarize_us_to_ms(samples_us: &[u64]) -> (f64, f64, f64, f64, f64) {
    if samples_us.is_empty() {
        return (0.0, 0.0, 0.0, 0.0, 0.0);
    }
    let mut ms: Vec<f64> = samples_us.iter().map(|&u| (u as f64) / 1000.0).collect();
    ms.sort_by(|a, b| a.total_cmp(b));
    let mean = ms.iter().sum::<f64>() / (ms.len() as f64);
    let p50 = percentile(&ms, 50.0);
    let p95 = percentile(&ms, 95.0);
    let p99 = percentile(&ms, 99.0);
    let max = *ms.last().unwrap_or(&0.0);
    (mean, p50, p95, p99, max)
}

/// Generates varied, realistic basketball inputs per tick (movement, sprint, dribble moves,
/// Phantom Drive combo `Q->E->Q->Shift`, jump shots, defensive stance & steals).
fn synth_player_input(client_idx: usize, seq: u32) -> PlayerInputFrameWire {
    let phase = ((seq as usize) + client_idx * 13) % 180;
    let angle = (seq as f32) * 0.08 + (client_idx as f32) * 0.55;
    let move_x = angle.cos();
    let move_z = angle.sin();
    let local_x = (angle * 0.5).sin();
    let local_y = 0.85f32;

    let mut buttons: u16 = 0;
    match phase {
        // Phantom Drive combo sequence (Q -> E -> Q -> Shift spaced by 5 frames)
        10 => buttons |= BTN_SKILL_Q,
        15 => buttons |= BTN_SKILL_E,
        20 => buttons |= BTN_SKILL_Q,
        25 => buttons |= BTN_SPRINT,
        // Sprint drive + dribble crossover
        35..=55 => {
            buttons |= BTN_SPRINT;
            if phase == 42 {
                buttons |= BTN_SKILL_Q;
            }
            if phase == 50 {
                buttons |= BTN_SKILL_E;
            }
        }
        // Jump shot charge & release (16 frames ~ 0.26s optimal release)
        70..=85 => buttons |= BTN_SHOOT,
        // Defensive stance + active steal poke
        110..=135 => {
            buttons |= BTN_STANCE;
            if phase == 120 {
                buttons |= BTN_STEAL;
            }
        }
        // Vertical block/rebound jump
        150 => buttons |= BTN_JUMP,
        _ => {
            if phase % 2 == 0 {
                buttons |= BTN_SPRINT;
            }
        }
    }

    PlayerInputFrameWire::from_floats(seq, seq, move_x, move_z, local_x, local_y, buttons, angle)
}

async fn run_simulated_client(
    server_udp: SocketAddr,
    room_id: u32,
    client_idx: usize,
    username: String,
    archetype_id: u8,
    join_barrier: Arc<Barrier>,
    mut stop_rx: watch::Receiver<bool>,
) -> ClientRunStats {
    let sock = UdpSocket::bind("127.0.0.1:0").await.expect("bind client udp");
    sock.connect(server_udp).await.expect("connect client udp");

    // 1. Handshake HelloJoin -> WelcomeJoined (with retries in case of initial burst)
    let mut recv_buf = vec![0u8; 2048];
    let mut pkt_seq: u32 = 1;
    let welcome: WelcomeJoinedMsg = {
        let mut retry_int = tokio::time::interval(Duration::from_millis(80));
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                Instant::now() < deadline,
                "Client {username} (room {room_id}) timed out waiting for WelcomeJoined"
            );
            tokio::select! {
                _ = retry_int.tick() => {
                    let hello = Packet::new(
                        pkt_seq,
                        0,
                        0,
                        NetMessage::HelloJoin(HelloJoinMsg {
                            username: username.clone(),
                            archetype_id,
                            room_id: room_id.to_string(),
                            auth_token: String::new(),
                            preferred_team: 255,
                        }),
                    );
                    pkt_seq += 1;
                    let _ = sock.send(&encode_packet(&hello)).await;
                }
                res = sock.recv(&mut recv_buf) => {
                    if let Ok(n) = res {
                        if let Ok(pkt) = decode_packet(&recv_buf[..n]) {
                            if let NetMessage::WelcomeJoined(w) = pkt.payload {
                                break w;
                            }
                        }
                    }
                }
            }
        }
    };

    // Wait until all 120 clients across all 20 rooms have joined & server telemetry is reset
    join_barrier.wait().await;

    // Drain any pre-window packets sitting in socket buffer
    while sock.try_recv(&mut recv_buf).is_ok() {}

    let mut stats = ClientRunStats {
        room_id,
        player_id: welcome.player_id,
        ..Default::default()
    };

    let mut input_window: VecDeque<PlayerInputFrameWire> = VecDeque::with_capacity(4);
    let mut input_seq: u32 = 0;
    let mut remote_seq: u32 = 0;
    let mut send_interval = tokio::time::interval(Duration::from_secs_f64(1.0 / 60.0));
    send_interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = stop_rx.changed() => {
                if *stop_rx.borrow() {
                    break;
                }
            }
            _ = send_interval.tick() => {
                input_seq += 1;
                let frame = synth_player_input(client_idx, input_seq);
                input_window.push_back(frame);
                while input_window.len() > 4 {
                    input_window.pop_front();
                }

                let batch = Packet::new(
                    pkt_seq,
                    remote_seq,
                    0,
                    NetMessage::ClientInputBatch(ClientInputBatchMsg {
                        session_token: welcome.session_token,
                        frames: input_window.iter().copied().collect(),
                    }),
                );
                pkt_seq += 1;
                if sock.send(&encode_packet(&batch)).await.is_ok() {
                    stats.inputs_sent += 1;
                    stats.packets_sent += 1;
                }
            }
            res = sock.recv(&mut recv_buf) => {
                if let Ok(n) = res {
                    if let Ok(pkt) = decode_packet(&recv_buf[..n]) {
                        if pkt.header.seq > remote_seq {
                            remote_seq = pkt.header.seq;
                        }
                        match pkt.payload {
                            NetMessage::ServerWorldSnapshot(snap) => {
                                stats.snapshots_received += 1;
                                stats.snapshot_bytes_received += n as u64;
                                if snap.server_tick > stats.last_server_tick {
                                    stats.last_server_tick = snap.server_tick;
                                }
                                if snap.players.len() > stats.max_players_seen {
                                    stats.max_players_seen = snap.players.len();
                                }
                            }
                            NetMessage::ReliableMatchEvent(ev) => {
                                stats.events_received += 1;
                                let ack = Packet::new(
                                    pkt_seq,
                                    remote_seq,
                                    0,
                                    NetMessage::EventAck(EventAckMsg {
                                        session_token: welcome.session_token,
                                        event_id: ev.event_id,
                                        ack_mask: 0,
                                    }),
                                );
                                pkt_seq += 1;
                                if sock.send(&encode_packet(&ack)).await.is_ok() {
                                    stats.packets_sent += 1;
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
    }

    stats
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn load_bench_20_concurrent_3v3_rooms_120_udp_clients_60hz() {
    let mut cfg = ServerConfig::for_ephemeral_test();
    cfg.idle_disconnect_timeout = Duration::from_secs(15);
    let server = spawn_game_server(cfg)
        .await
        .expect("spawn authoritative server for load benchmark");

    // 1. Provision 20 concurrent 3v3 rooms (6 players each = 120 players) into live InMatch state
    let mut client_roster: Vec<(u32, String, u8)> = Vec::with_capacity(TOTAL_CLIENTS);
    {
        let rm_arc = server.room_manager();
        let mut rm = rm_arc.lock().await;
        for r_idx in 0..NUM_ROOMS {
            let host_name = format!("R{}_P1", r_idx + 1);
            let host_arch = ArchetypeId::from_u8((r_idx % 5) as u8);
            let (room_id, _code, host_member, _) = rm
                .create_room(GameMode::ThreeVsThree, false, false, host_name.clone(), host_arch)
                .expect("create 3v3 room");

            let mut member_ids = vec![host_member.member_id];
            client_roster.push((room_id, host_name, host_arch.as_u8()));

            for p_idx in 1..PLAYERS_PER_ROOM {
                let uname = format!("R{}_P{}", r_idx + 1, p_idx + 1);
                let arch = ArchetypeId::from_u8(((r_idx + p_idx) % 5) as u8);
                let (_, _, member, _) = rm
                    .join_room(Some(room_id), None, uname.clone(), arch, false)
                    .expect("join 3v3 room");
                member_ids.push(member.member_id);
                client_roster.push((room_id, uname, arch.as_u8()));
            }

            for (m_i, mid) in member_ids.iter().enumerate() {
                let (started, dto) = rm.set_ready(room_id, mid, true).expect("ready member");
                if m_i + 1 == PLAYERS_PER_ROOM {
                    assert!(started, "Room {room_id} must transition to InMatch at 6/6 ready");
                    assert_eq!(dto.world_player_count, PLAYERS_PER_ROOM);
                }
            }
        }
        assert_eq!(rm.rooms_count(), NUM_ROOMS + 1); // 20 active 3v3 rooms + default room 0
    }

    // 2. Spawn all 120 simulated UDP clients concurrently & synchronize start
    let join_barrier = Arc::new(Barrier::new(TOTAL_CLIENTS + 1));
    let (stop_tx, stop_rx) = watch::channel(false);

    let mut handles = Vec::with_capacity(TOTAL_CLIENTS);
    for (idx, (room_id, username, arch_u8)) in client_roster.into_iter().enumerate() {
        let b = Arc::clone(&join_barrier);
        let s_rx = stop_rx.clone();
        let udp_addr = server.udp_addr;
        handles.push(tokio::spawn(async move {
            run_simulated_client(udp_addr, room_id, idx, username, arch_u8, b, s_rx).await
        }));
    }

    // Wait for all 120 clients to finish HelloJoin/WelcomeJoined, then reset telemetry & record starting ticks
    join_barrier.wait().await;
    server.reset_load_telemetry().await;
    let start_snapshot = server.get_load_telemetry().await;
    let start_room_ticks: Vec<(u32, u64)> = start_snapshot
        .rooms
        .iter()
        .map(|r| (r.room_id, r.server_tick))
        .collect();
    let start_room_snap_bytes: Vec<(u32, u64)> = start_snapshot
        .rooms
        .iter()
        .map(|r| (r.room_id, r.total_snapshot_bytes_sent))
        .collect();

    // 3. Run active 60 Hz multi-room simulation until all 20 rooms pass >= 300 ticks (>= 5.0s)
    let bench_start = Instant::now();
    tokio::time::sleep(Duration::from_secs_f64(BENCH_DURATION_SECS)).await;

    let end_telemetry = server.get_load_telemetry().await;
    let measured_secs = end_telemetry.window_elapsed_secs.max(bench_start.elapsed().as_secs_f64());

    // Stop all 120 simulated clients cleanly
    let _ = stop_tx.send(true);
    let mut client_stats = Vec::with_capacity(TOTAL_CLIENTS);
    for h in handles {
        client_stats.push(h.await.expect("client task exited without panic"));
    }

    // 4. Compute real verbatim telemetry
    let (full_mean_ms, full_p50_ms, full_p95_ms, full_p99_ms, full_max_ms) =
        summarize_us_to_ms(&end_telemetry.full_tick_durations_us);
    let (sim_mean_ms, sim_p50_ms, sim_p95_ms, sim_p99_ms, sim_max_ms) =
        summarize_us_to_ms(&end_telemetry.sim_step_durations_us);

    let total_rooms = end_telemetry.rooms.len();
    let total_world_players: usize = end_telemetry.rooms.iter().map(|r| r.world_players).sum();
    let total_connected: usize = end_telemetry
        .rooms
        .iter()
        .map(|r| r.connected_sessions)
        .sum();

    let mut min_ticks_progressed = u64::MAX;
    let mut max_ticks_progressed = 0u64;
    let mut total_window_snapshot_bytes_server = 0u64;
    for r in &end_telemetry.rooms {
        let start_t = start_room_ticks
            .iter()
            .find(|(id, _)| *id == r.room_id)
            .map_or(0, |(_, t)| *t);
        let prog = r.server_tick.saturating_sub(start_t);
        min_ticks_progressed = min_ticks_progressed.min(prog);
        max_ticks_progressed = max_ticks_progressed.max(prog);

        let start_b = start_room_snap_bytes
            .iter()
            .find(|(id, _)| *id == r.room_id)
            .map_or(0, |(_, b)| *b);
        total_window_snapshot_bytes_server += r.total_snapshot_bytes_sent.saturating_sub(start_b);
    }

    let total_client_snaps_rx: u64 = client_stats.iter().map(|c| c.snapshots_received).sum();
    let total_client_snap_bytes_rx: u64 =
        client_stats.iter().map(|c| c.snapshot_bytes_received).sum();
    let total_client_inputs_sent: u64 = client_stats.iter().map(|c| c.inputs_sent).sum();
    let min_client_snaps_rx = client_stats
        .iter()
        .map(|c| c.snapshots_received)
        .min()
        .unwrap_or(0);

    let server_rx_pps = (end_telemetry.udp_rx_packets as f64) / measured_secs;
    let server_tx_pps = (end_telemetry.udp_tx_packets as f64) / measured_secs;
    let aggregate_pps = server_rx_pps + server_tx_pps;

    let avg_outbound_snap_kbps_per_client =
        (total_window_snapshot_bytes_server as f64) / (TOTAL_CLIENTS as f64) / measured_secs / 1024.0;
    let avg_client_rx_snap_kbps =
        (total_client_snap_bytes_rx as f64) / (TOTAL_CLIENTS as f64) / measured_secs / 1024.0;

    let build_profile = if cfg!(debug_assertions) {
        "debug"
    } else {
        "release"
    };

    println!();
    println!("========================================================================");
    println!("PHANTOM COURT ONLINE — AUTHORITATIVE SERVER LOAD BENCHMARK ({build_profile})");
    println!("========================================================================");
    println!("Simulated Rooms:                {total_rooms} concurrent 3v3 rooms");
    println!("Active Players:                 {total_world_players} simulated ({total_connected} live UDP sessions)");
    println!("Benchmark Window:               {measured_secs:.3} s ({} recorded server ticks)", end_telemetry.full_tick_durations_us.len());
    println!("Room Tick Progression:          min={min_ticks_progressed}, max={max_ticks_progressed} ticks (target >= {TARGET_TICKS})");
    println!("Full Wall-Clock Tick (sim+TX):  mean={full_mean_ms:.3} ms | p50={full_p50_ms:.3} ms | p95={full_p95_ms:.3} ms | p99={full_p99_ms:.3} ms | max={full_max_ms:.3} ms");
    println!("Pure Sim+Encode Step:           mean={sim_mean_ms:.3} ms | p50={sim_p50_ms:.3} ms | p95={sim_p95_ms:.3} ms | p99={sim_p99_ms:.3} ms | max={sim_max_ms:.3} ms");
    println!("60 Hz Budget Headroom (p95):    {:.2}% free ({full_p95_ms:.3} ms / 16.667 ms)", ((16.6667 - full_p95_ms).max(0.0) / 16.6667) * 100.0);
    println!("UDP Packets (Server Window):    rx={} ({server_rx_pps:.1}/s) | tx={} ({server_tx_pps:.1}/s) | aggregate={aggregate_pps:.1} pkt/s", end_telemetry.udp_rx_packets, end_telemetry.udp_tx_packets);
    println!("Client Telemetry (120 UDP):     inputs_sent={total_client_inputs_sent} | snaps_rx={total_client_snaps_rx} (min/client={min_client_snaps_rx})");
    println!("Outbound Snapshot BW/Client:    server_tx={avg_outbound_snap_kbps_per_client:.2} KB/s | client_rx={avg_client_rx_snap_kbps:.2} KB/s (budget < 12.00 KB/s)");
    println!("========================================================================");
    println!();

    // 5. Strict Real-Time & Throughput Assertions
    assert_eq!(total_rooms, NUM_ROOMS, "Must simulate all 20 concurrent 3v3 rooms");
    assert_eq!(total_world_players, TOTAL_CLIENTS, "Must simulate all 120 players");
    assert_eq!(total_connected, TOTAL_CLIENTS, "All 120 UDP sessions must remain connected");
    assert!(
        min_ticks_progressed >= TARGET_TICKS,
        "All 20 rooms must progress >= {TARGET_TICKS} ticks (min={min_ticks_progressed})"
    );
    assert_eq!(
        max_ticks_progressed - min_ticks_progressed,
        0,
        "All 20 rooms must step deterministically in lockstep (min={min_ticks_progressed}, max={max_ticks_progressed})"
    );
    assert!(
        full_p95_ms < 16.67,
        "Server full tick p95 ({full_p95_ms:.3} ms) exceeded 60 Hz budget (16.67 ms)!"
    );
    assert!(
        avg_outbound_snap_kbps_per_client > 1.0 && avg_outbound_snap_kbps_per_client < 12.0,
        "Per-client snapshot bandwidth ({avg_outbound_snap_kbps_per_client:.2} KB/s) outside (1.0..12.0 KB/s)!"
    );
    assert!(
        min_client_snaps_rx >= 80,
        "Every client must continuously receive 30 Hz snapshots (min={min_client_snaps_rx})"
    );
    for cs in &client_stats {
        assert_eq!(
            cs.max_players_seen, PLAYERS_PER_ROOM,
            "Client in room {} player {} must observe full 6-player 3v3 snapshot",
            cs.room_id, cs.player_id
        );
    }

    server.shutdown().await;
}
