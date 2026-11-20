use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::net::{TcpListener, UdpSocket};
use tokio::sync::{watch, Mutex};
use tokio::task::JoinHandle;
use tokio::time::MissedTickBehavior;
use tracing::{debug, info, warn};

use crate::config::ServerConfig;
use crate::db::{EphemeralStore, PostgresStore, SharedRankingStore, DEFAULT_DATABASE_URL};
use crate::http::{build_http_router, HttpSharedState};
use crate::modes::{persist_completed_room_match, RoomManager};
use crate::protocol::{decode_packet, MatchEventPayload};

const MAX_RECORDED_TICK_SAMPLES: usize = 4096;
const MAX_UDP_RECV_BATCH: usize = 64;

#[derive(Debug, Clone)]
pub struct ServerRuntimeMetrics {
    pub server_tick: u64,
    pub active_players: usize,
    pub connected_sessions: usize,
    pub total_snapshots_sent: u64,
    pub total_snapshot_bytes_sent: u64,
    pub last_snapshot_bytes: usize,
    pub total_events_emitted: u64,
    pub player_inputs_processed: Vec<(u32, u32, u64)>, // (player_id, last_seq, total_processed)
    pub scores: [u16; 2],
}

#[derive(Debug, Clone)]
pub struct RoomLoadSnapshot {
    pub room_id: u32,
    pub server_tick: u64,
    pub world_players: usize,
    pub connected_sessions: usize,
    pub total_snapshots_sent: u64,
    pub total_snapshot_bytes_sent: u64,
}

#[derive(Debug, Clone)]
pub struct LoadTelemetrySnapshot {
    pub window_elapsed_secs: f64,
    pub full_tick_durations_us: Vec<u64>,
    pub sim_step_durations_us: Vec<u64>,
    pub udp_rx_packets: u64,
    pub udp_tx_packets: u64,
    pub udp_rx_bytes: u64,
    pub udp_tx_bytes: u64,
    pub rooms: Vec<RoomLoadSnapshot>,
}

#[derive(Debug)]
struct LoadTelemetryInner {
    window_start: Instant,
    full_tick_durations_us: Vec<u64>,
    sim_step_durations_us: Vec<u64>,
    udp_rx_packets: u64,
    udp_tx_packets: u64,
    udp_rx_bytes: u64,
    udp_tx_bytes: u64,
}

impl LoadTelemetryInner {
    fn new() -> Self {
        Self {
            window_start: Instant::now(),
            full_tick_durations_us: Vec::with_capacity(512),
            sim_step_durations_us: Vec::with_capacity(512),
            udp_rx_packets: 0,
            udp_tx_packets: 0,
            udp_rx_bytes: 0,
            udp_tx_bytes: 0,
        }
    }

    fn reset(&mut self) {
        self.window_start = Instant::now();
        self.full_tick_durations_us.clear();
        self.sim_step_durations_us.clear();
        self.udp_rx_packets = 0;
        self.udp_tx_packets = 0;
        self.udp_rx_bytes = 0;
        self.udp_tx_bytes = 0;
    }

    fn record_tick(&mut self, sim_us: u64, full_us: u64) {
        if self.full_tick_durations_us.len() >= MAX_RECORDED_TICK_SAMPLES {
            self.full_tick_durations_us.remove(0);
            self.sim_step_durations_us.remove(0);
        }
        self.sim_step_durations_us.push(sim_us);
        self.full_tick_durations_us.push(full_us);
    }
}

pub struct GameServerHandle {
    pub udp_addr: SocketAddr,
    pub http_addr: SocketAddr,
    pub config: ServerConfig,
    room_manager: Arc<Mutex<RoomManager>>,
    ranking_store: SharedRankingStore,
    telemetry: Arc<Mutex<LoadTelemetryInner>>,
    shutdown_tx: watch::Sender<bool>,
    udp_task: Option<JoinHandle<()>>,
    http_task: Option<JoinHandle<()>>,
}

impl GameServerHandle {
    pub async fn get_metrics(&self) -> Option<ServerRuntimeMetrics> {
        let rm = self.room_manager.lock().await;
        Some(rm.default_room_metrics())
    }

    pub async fn reset_load_telemetry(&self) {
        let mut tel = self.telemetry.lock().await;
        tel.reset();
    }

    pub async fn get_load_telemetry(&self) -> LoadTelemetrySnapshot {
        let (elapsed, full_us, sim_us, rx_pkts, tx_pkts, rx_bytes, tx_bytes) = {
            let tel = self.telemetry.lock().await;
            (
                tel.window_start.elapsed().as_secs_f64(),
                tel.full_tick_durations_us.clone(),
                tel.sim_step_durations_us.clone(),
                tel.udp_rx_packets,
                tel.udp_tx_packets,
                tel.udp_rx_bytes,
                tel.udp_tx_bytes,
            )
        };
        let rooms = {
            let rm = self.room_manager.lock().await;
            rm.room_load_snapshots()
                .into_iter()
                .map(
                    |(
                        room_id,
                        server_tick,
                        world_players,
                        connected_sessions,
                        total_snapshots_sent,
                        total_snapshot_bytes_sent,
                    )| RoomLoadSnapshot {
                        room_id,
                        server_tick,
                        world_players,
                        connected_sessions,
                        total_snapshots_sent,
                        total_snapshot_bytes_sent,
                    },
                )
                .collect()
        };
        LoadTelemetrySnapshot {
            window_elapsed_secs: elapsed,
            full_tick_durations_us: full_us,
            sim_step_durations_us: sim_us,
            udp_rx_packets: rx_pkts,
            udp_tx_packets: tx_pkts,
            udp_rx_bytes: rx_bytes,
            udp_tx_bytes: tx_bytes,
            rooms,
        }
    }

    pub fn room_manager(&self) -> Arc<Mutex<RoomManager>> {
        Arc::clone(&self.room_manager)
    }

    pub fn ranking_store(&self) -> SharedRankingStore {
        Arc::clone(&self.ranking_store)
    }

    pub fn inject_reliable_event(&self, event: MatchEventPayload) {
        let rm = Arc::clone(&self.room_manager);
        tokio::spawn(async move {
            let mut guard = rm.lock().await;
            guard.inject_reliable_event_default_room(event);
        });
    }

    pub fn set_player_zone_full(&self, player_id: u32) {
        let rm = Arc::clone(&self.room_manager);
        tokio::spawn(async move {
            let mut guard = rm.lock().await;
            guard.set_player_zone_full_default_room(player_id);
        });
    }

    pub async fn shutdown(mut self) {
        let _ = self.shutdown_tx.send(true);
        if let Some(t) = self.udp_task.take() {
            let _ = t.await;
        }
        if let Some(t) = self.http_task.take() {
            let _ = t.await;
        }
    }
}

impl Drop for GameServerHandle {
    fn drop(&mut self) {
        let _ = self.shutdown_tx.send(true);
        if let Some(t) = self.udp_task.take() {
            t.abort();
        }
        if let Some(t) = self.http_task.take() {
            t.abort();
        }
    }
}

/// Spawns the authoritative multi-room 60 Hz UDP simulation server + Axum HTTP Control API + Ranking Store.
pub async fn spawn_game_server(config: ServerConfig) -> std::io::Result<GameServerHandle> {
    let ranking_store: SharedRankingStore = if config.ephemeral_db {
        Arc::new(EphemeralStore::new())
    } else {
        let db_url = config
            .database_url
            .as_deref()
            .unwrap_or(DEFAULT_DATABASE_URL);
        let pg = PostgresStore::connect(db_url).await.map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::ConnectionRefused, e.to_string())
        })?;
        Arc::new(pg)
    };

    let udp_bind = format!("{}:{}", config.bind_addr, config.udp_port);
    let udp_socket = UdpSocket::bind(&udp_bind).await?;
    let udp_addr = udp_socket.local_addr()?;

    let http_bind = format!("{}:{}", config.bind_addr, config.http_port);
    let tcp_listener = TcpListener::bind(&http_bind).await?;
    let http_addr = tcp_listener.local_addr()?;

    let room_manager = Arc::new(Mutex::new(RoomManager::new(config.clone(), udp_addr.port())));
    let telemetry = Arc::new(Mutex::new(LoadTelemetryInner::new()));

    let http_state = Arc::new(HttpSharedState {
        udp_port: udp_addr.port(),
        http_port: http_addr.port(),
        tick_rate: config.tick_rate,
        snapshot_rate: config.snapshot_rate,
        ephemeral_db: config.ephemeral_db,
        active_players: AtomicUsize::new(0),
        server_tick: AtomicU64::new(0),
        room_manager: Arc::clone(&room_manager),
        ranking_store: Arc::clone(&ranking_store),
    });

    let (shutdown_tx, mut shutdown_rx_http) = watch::channel(false);
    let mut shutdown_rx_udp = shutdown_tx.subscribe();

    // Spawn HTTP control & health server
    let router = build_http_router(Arc::clone(&http_state));
    let http_task = tokio::spawn(async move {
        let server = axum::serve(tcp_listener, router).with_graceful_shutdown(async move {
            let _ = shutdown_rx_http.changed().await;
        });
        if let Err(err) = server.await {
            warn!("HTTP server exited with error: {err}");
        }
    });

    let cfg_clone = config.clone();
    let http_state_udp = Arc::clone(&http_state);
    let rm_udp = Arc::clone(&room_manager);
    let store_udp = Arc::clone(&ranking_store);
    let tel_udp = Arc::clone(&telemetry);

    // Spawn multi-room authoritative 60 Hz UDP loop
    let udp_task = tokio::spawn(async move {
        let tick_period = Duration::from_secs_f64(1.0 / (cfg_clone.tick_rate.max(1) as f64));
        let snapshot_every_ticks =
            (cfg_clone.tick_rate / cfg_clone.snapshot_rate.max(1)).max(1) as u64;
        let mut tick_interval = tokio::time::interval(tick_period);
        tick_interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

        let mut recv_buf = vec![0u8; 2048];

        info!(
            "Authoritative Multi-Room UDP server listening on {} (HTTP {}, {} Hz sim / {} Hz snapshots, db={})",
            udp_addr,
            http_addr,
            cfg_clone.tick_rate,
            cfg_clone.snapshot_rate,
            store_udp.backend_name()
        );

        loop {
            tokio::select! {
                _ = shutdown_rx_udp.changed() => {
                    if *shutdown_rx_udp.borrow() {
                        break;
                    }
                }
                recv_res = udp_socket.recv_from(&mut recv_buf) => {
                    let Ok((first_len, first_src)) = recv_res else {
                        continue;
                    };
                    let now = Instant::now();
                    let mut rx_pkts = 0u64;
                    let mut rx_bytes = 0u64;
                    let mut outbound: Vec<(SocketAddr, Vec<u8>)> = Vec::new();

                    let active_players = {
                        let mut rm = rm_udp.lock().await;

                        rx_pkts += 1;
                        rx_bytes += first_len as u64;
                        match decode_packet(&recv_buf[..first_len]) {
                            Ok(pkt) => {
                                outbound.extend(rm.handle_udp_packet(first_src, pkt, first_len, now));
                            }
                            Err(_) => {
                                debug!("Dropped malformed UDP packet ({} bytes) from {}", first_len, first_src);
                            }
                        }

                        // Drain up to MAX_UDP_RECV_BATCH-1 additional ready packets under one lock
                        for _ in 1..MAX_UDP_RECV_BATCH {
                            match udp_socket.try_recv_from(&mut recv_buf) {
                                Ok((len, src_addr)) => {
                                    rx_pkts += 1;
                                    rx_bytes += len as u64;
                                    if let Ok(pkt) = decode_packet(&recv_buf[..len]) {
                                        outbound.extend(rm.handle_udp_packet(src_addr, pkt, len, now));
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                        rm.total_active_players()
                    };

                    http_state_udp
                        .active_players
                        .store(active_players, Ordering::Relaxed);

                    let mut tx_pkts = 0u64;
                    let mut tx_bytes = 0u64;
                    for (addr, bytes) in outbound {
                        if udp_socket.send_to(&bytes, addr).await.is_ok() {
                            tx_pkts += 1;
                            tx_bytes += bytes.len() as u64;
                        }
                    }

                    let mut tel = tel_udp.lock().await;
                    tel.udp_rx_packets += rx_pkts;
                    tel.udp_rx_bytes += rx_bytes;
                    tel.udp_tx_packets += tx_pkts;
                    tel.udp_tx_bytes += tx_bytes;
                }
                _ = tick_interval.tick() => {
                    let tick_start = Instant::now();
                    let now = tick_start;
                    let (outbound, completed_matches, active_players, default_tick) = {
                        let mut rm = rm_udp.lock().await;
                        let (out, completed) = rm.step_all_rooms(now, snapshot_every_ticks);
                        let ap = rm.total_active_players();
                        let tick = rm.default_server_tick();
                        (out, completed, ap, tick)
                    };
                    let sim_step_us = tick_start.elapsed().as_micros() as u64;

                    http_state_udp
                        .active_players
                        .store(active_players, Ordering::Relaxed);
                    http_state_udp
                        .server_tick
                        .store(default_tick, Ordering::Relaxed);

                    let mut tx_pkts = 0u64;
                    let mut tx_bytes = 0u64;
                    for (addr, bytes) in outbound {
                        if udp_socket.send_to(&bytes, addr).await.is_ok() {
                            tx_pkts += 1;
                            tx_bytes += bytes.len() as u64;
                        }
                    }

                    let full_tick_us = tick_start.elapsed().as_micros() as u64;
                    {
                        let mut tel = tel_udp.lock().await;
                        tel.record_tick(sim_step_us, full_tick_us);
                        tel.udp_tx_packets += tx_pkts;
                        tel.udp_tx_bytes += tx_bytes;
                    }

                    // Persist any naturally completed online matches asynchronously without blocking 60 Hz ticks
                    for cm in completed_matches {
                        let store_clone = Arc::clone(&store_udp);
                        tokio::spawn(async move {
                            let _ = persist_completed_room_match(&store_clone, cm).await;
                        });
                    }
                }
            }
        }
    });

    Ok(GameServerHandle {
        udp_addr,
        http_addr,
        config,
        room_manager,
        ranking_store,
        telemetry,
        shutdown_tx,
        udp_task: Some(udp_task),
        http_task: Some(http_task),
    })
}
