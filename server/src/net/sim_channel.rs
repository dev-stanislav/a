use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use tokio::net::UdpSocket;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

/// Configuration for `SimulatedNetLink` fault-injection bridge (latency, jitter, loss, reordering).
#[derive(Debug, Clone, Copy)]
pub struct NetLinkConfig {
    /// Base one-way delay in ms (e.g., 50ms one-way == 100ms RTT).
    pub one_way_latency_ms: u64,
    /// Max random extra delay in ms (`[0..=jitter_ms]`).
    pub jitter_ms: u64,
    /// Independent drop probability in `[0.0, 1.0]` (e.g., `0.10` = 10% loss).
    pub loss_rate: f64,
    /// Probability of delaying a packet extra to induce out-of-order delivery.
    pub reorder_rate: f64,
    /// Deterministic PRNG seed for reproducible tests.
    pub seed: u64,
}

impl Default for NetLinkConfig {
    fn default() -> Self {
        Self {
            one_way_latency_ms: 50, // 100ms RTT
            jitter_ms: 10,
            loss_rate: 0.10,
            reorder_rate: 0.15,
            seed: 0x5043_0008,
        }
    }
}

#[derive(Debug, Default)]
pub struct NetLinkStats {
    pub c2s_received: AtomicU64,
    pub c2s_delivered: AtomicU64,
    pub c2s_dropped: AtomicU64,
    pub c2s_reordered: AtomicU64,
    pub c2s_bytes_delivered: AtomicU64,
    pub s2c_received: AtomicU64,
    pub s2c_delivered: AtomicU64,
    pub s2c_dropped: AtomicU64,
    pub s2c_reordered: AtomicU64,
    pub s2c_bytes_delivered: AtomicU64,
}

/// Reusable async Tokio UDP proxy simulating RTT latency, jitter, packet loss, and out-of-order delivery.
///
/// Clients send packets to `client_facing_addr()`; the link forwards them to `server_addr` through a
/// dedicated server-facing UDP socket so the server sees a consistent source address for that client.
pub struct SimulatedNetLink {
    client_facing_addr: SocketAddr,
    stats: Arc<NetLinkStats>,
    tasks: Vec<JoinHandle<()>>,
}

impl SimulatedNetLink {
    pub async fn spawn(server_addr: SocketAddr, config: NetLinkConfig) -> std::io::Result<Self> {
        let client_side = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
        let client_facing_addr = client_side.local_addr()?;

        let server_side = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
        server_side.connect(server_addr).await?;

        let last_client_addr: Arc<Mutex<Option<SocketAddr>>> = Arc::new(Mutex::new(None));
        let stats = Arc::new(NetLinkStats::default());

        // C2S pump (Client -> Server)
        let c2s_task = {
            let client_side = Arc::clone(&client_side);
            let server_side = Arc::clone(&server_side);
            let last_client_addr = Arc::clone(&last_client_addr);
            let stats = Arc::clone(&stats);
            tokio::spawn(async move {
                let mut rng = StdRng::seed_from_u64(config.seed);
                let mut buf = vec![0u8; 2048];
                while let Ok((len, src)) = client_side.recv_from(&mut buf).await {
                    {
                        let mut guard = last_client_addr.lock().await;
                        *guard = Some(src);
                    }
                    stats.c2s_received.fetch_add(1, Ordering::Relaxed);
                    if config.loss_rate > 0.0 && rng.gen::<f64>() < config.loss_rate {
                        stats.c2s_dropped.fetch_add(1, Ordering::Relaxed);
                        continue;
                    }
                    let mut delay_ms = config.one_way_latency_ms;
                    if config.jitter_ms > 0 {
                        delay_ms += rng.gen_range(0..=config.jitter_ms);
                    }
                    if config.reorder_rate > 0.0 && rng.gen::<f64>() < config.reorder_rate {
                        delay_ms += 25 + rng.gen_range(0..=30);
                        stats.c2s_reordered.fetch_add(1, Ordering::Relaxed);
                    }
                    let payload = buf[..len].to_vec();
                    let server_side = Arc::clone(&server_side);
                    let stats = Arc::clone(&stats);
                    tokio::spawn(async move {
                        if delay_ms > 0 {
                            tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                        }
                        if server_side.send(&payload).await.is_ok() {
                            stats.c2s_delivered.fetch_add(1, Ordering::Relaxed);
                            stats
                                .c2s_bytes_delivered
                                .fetch_add(payload.len() as u64, Ordering::Relaxed);
                        }
                    });
                }
            })
        };

        // S2C pump (Server -> Client)
        let s2c_task = {
            let client_side = Arc::clone(&client_side);
            let server_side = Arc::clone(&server_side);
            let last_client_addr = Arc::clone(&last_client_addr);
            let stats = Arc::clone(&stats);
            tokio::spawn(async move {
                let mut rng = StdRng::seed_from_u64(config.seed ^ 0xA5A5_5A5A);
                let mut buf = vec![0u8; 2048];
                while let Ok(len) = server_side.recv(&mut buf).await {
                    let target = { *last_client_addr.lock().await };
                    let Some(client_addr) = target else {
                        continue;
                    };
                    stats.s2c_received.fetch_add(1, Ordering::Relaxed);
                    if config.loss_rate > 0.0 && rng.gen::<f64>() < config.loss_rate {
                        stats.s2c_dropped.fetch_add(1, Ordering::Relaxed);
                        continue;
                    }
                    let mut delay_ms = config.one_way_latency_ms;
                    if config.jitter_ms > 0 {
                        delay_ms += rng.gen_range(0..=config.jitter_ms);
                    }
                    if config.reorder_rate > 0.0 && rng.gen::<f64>() < config.reorder_rate {
                        delay_ms += 25 + rng.gen_range(0..=30);
                        stats.s2c_reordered.fetch_add(1, Ordering::Relaxed);
                    }
                    let payload = buf[..len].to_vec();
                    let client_side = Arc::clone(&client_side);
                    let stats = Arc::clone(&stats);
                    tokio::spawn(async move {
                        if delay_ms > 0 {
                            tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                        }
                        if client_side.send_to(&payload, client_addr).await.is_ok() {
                            stats.s2c_delivered.fetch_add(1, Ordering::Relaxed);
                            stats
                                .s2c_bytes_delivered
                                .fetch_add(payload.len() as u64, Ordering::Relaxed);
                        }
                    });
                }
            })
        };

        Ok(Self {
            client_facing_addr,
            stats,
            tasks: vec![c2s_task, s2c_task],
        })
    }

    pub fn client_facing_addr(&self) -> SocketAddr {
        self.client_facing_addr
    }

    pub fn stats(&self) -> Arc<NetLinkStats> {
        Arc::clone(&self.stats)
    }
}

impl Drop for SimulatedNetLink {
    fn drop(&mut self) {
        for t in &self.tasks {
            t.abort();
        }
    }
}
