use phantom_court_server::config::ServerConfig;
use phantom_court_server::net::spawn_game_server;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt().with_env_filter(filter).init();

    let config = ServerConfig::from_env_and_args();
    let handle = spawn_game_server(config).await?;

    info!(
        "Phantom Court Online server ready | UDP={} | HTTP=http://{}/health",
        handle.udp_addr, handle.http_addr
    );

    tokio::signal::ctrl_c().await?;
    info!("Shutdown signal received; stopping server cleanly...");
    handle.shutdown().await;
    Ok(())
}
