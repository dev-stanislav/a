pub mod reconnect;
pub mod session;
pub mod sim_channel;
pub mod udp_server;

pub use reconnect::{ReconnectOutcome, SessionManager};
pub use session::{ClientSession, PendingReliableEvent, SessionState};
pub use sim_channel::{NetLinkConfig, NetLinkStats, SimulatedNetLink};
pub use udp_server::{
    spawn_game_server, GameServerHandle, LoadTelemetrySnapshot, RoomLoadSnapshot,
    ServerRuntimeMetrics,
};
