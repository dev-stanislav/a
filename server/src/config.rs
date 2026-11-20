use std::env;
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub bind_addr: String,
    pub udp_port: u16,
    pub http_port: u16,
    pub tick_rate: u32,
    pub snapshot_rate: u32,
    pub database_url: Option<String>,
    pub ephemeral_db: bool,
    pub idle_disconnect_timeout: Duration,
    pub reconnect_grace_window: Duration,
    pub reliable_retry_interval: Duration,
    pub match_duration_secs: f32,
    pub shot_clock_secs: f32,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            bind_addr: "127.0.0.1".to_string(),
            udp_port: 7777,
            http_port: 8080,
            tick_rate: 60,
            snapshot_rate: 30,
            database_url: None,
            ephemeral_db: true,
            idle_disconnect_timeout: Duration::from_secs(5),
            reconnect_grace_window: Duration::from_secs(30),
            reliable_retry_interval: Duration::from_millis(200),
            match_duration_secs: 180.0,
            shot_clock_secs: 24.0,
        }
    }
}

impl ServerConfig {
    /// Load configuration from environment variables (`PCO_UDP_PORT`, `PCO_HTTP_PORT`,
    /// `PCO_TICK_RATE`, `PCO_SNAPSHOT_RATE`, `PCO_BIND_ADDR`, `DATABASE_URL`) and
    /// command-line overrides (`--udp-port`, `--http-port`, `--tick-rate`, `--bind`, `--ephemeral-db`).
    ///
    /// Defaults to PostgreSQL (`DATABASE_URL` or `postgres://postgres@127.0.0.1:15432/phantom_court`)
    /// unless `--ephemeral-db` is explicitly passed.
    pub fn from_env_and_args() -> Self {
        let mut cfg = Self::default();
        cfg.bind_addr = env::var("PCO_BIND_ADDR").unwrap_or_else(|_| "0.0.0.0".to_string());
        cfg.ephemeral_db = false;
        cfg.database_url = Some(crate::db::DEFAULT_DATABASE_URL.to_string());

        if let Ok(val) = env::var("PCO_UDP_PORT") {
            if let Ok(port) = val.trim().parse::<u16>() {
                cfg.udp_port = port;
            }
        }
        if let Ok(val) = env::var("PCO_HTTP_PORT") {
            if let Ok(port) = val.trim().parse::<u16>() {
                cfg.http_port = port;
            }
        }
        if let Ok(val) = env::var("PCO_TICK_RATE") {
            if let Ok(rate) = val.trim().parse::<u32>() {
                cfg.tick_rate = rate.clamp(20, 120);
            }
        }
        if let Ok(val) = env::var("PCO_SNAPSHOT_RATE") {
            if let Ok(rate) = val.trim().parse::<u32>() {
                cfg.snapshot_rate = rate.clamp(10, 60);
            }
        }
        if let Ok(val) = env::var("DATABASE_URL") {
            let trimmed = val.trim();
            if !trimmed.is_empty() {
                cfg.database_url = Some(trimmed.to_string());
            }
        }

        let args: Vec<String> = env::args().skip(1).collect();
        let mut i = 0;
        while i < args.len() {
            match args[i].as_str() {
                "--udp-port" => {
                    if let Some(v) = args.get(i + 1) {
                        if let Ok(port) = v.parse::<u16>() {
                            cfg.udp_port = port;
                        }
                        i += 1;
                    }
                }
                "--http-port" => {
                    if let Some(v) = args.get(i + 1) {
                        if let Ok(port) = v.parse::<u16>() {
                            cfg.http_port = port;
                        }
                        i += 1;
                    }
                }
                "--tick-rate" => {
                    if let Some(v) = args.get(i + 1) {
                        if let Ok(rate) = v.parse::<u32>() {
                            cfg.tick_rate = rate.clamp(20, 120);
                        }
                        i += 1;
                    }
                }
                "--snapshot-rate" => {
                    if let Some(v) = args.get(i + 1) {
                        if let Ok(rate) = v.parse::<u32>() {
                            cfg.snapshot_rate = rate.clamp(10, 60);
                        }
                        i += 1;
                    }
                }
                "--bind" => {
                    if let Some(v) = args.get(i + 1) {
                        cfg.bind_addr = v.clone();
                        i += 1;
                    }
                }
                "--ephemeral-db" => {
                    cfg.ephemeral_db = true;
                }
                _ => {}
            }
            i += 1;
        }

        if cfg.snapshot_rate > cfg.tick_rate {
            cfg.snapshot_rate = cfg.tick_rate;
        }
        cfg
    }

    pub fn for_ephemeral_test() -> Self {
        Self {
            bind_addr: "127.0.0.1".to_string(),
            udp_port: 0,
            http_port: 0,
            tick_rate: 60,
            snapshot_rate: 30,
            database_url: None,
            ephemeral_db: true,
            idle_disconnect_timeout: Duration::from_secs(5),
            reconnect_grace_window: Duration::from_secs(30),
            reliable_retry_interval: Duration::from_millis(200),
            match_duration_secs: 180.0,
            shot_clock_secs: 24.0,
        }
    }

    pub fn for_postgres_test(database_url: String) -> Self {
        Self {
            bind_addr: "127.0.0.1".to_string(),
            udp_port: 0,
            http_port: 0,
            tick_rate: 60,
            snapshot_rate: 30,
            database_url: Some(database_url),
            ephemeral_db: false,
            idle_disconnect_timeout: Duration::from_secs(5),
            reconnect_grace_window: Duration::from_secs(30),
            reliable_retry_interval: Duration::from_millis(200),
            match_duration_secs: 180.0,
            shot_clock_secs: 24.0,
        }
    }
}
