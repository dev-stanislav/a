use serde::Serialize;
use uuid::Uuid;

use crate::sim::SimWorld;

use super::{archetype_to_name, LobbyStateDto};

#[derive(Debug, Clone, Serialize)]
pub struct PlayerPreviewDto {
    pub player_id: u32,
    pub team_id: u8,
    pub slot: u8,
    pub username: String,
    pub archetype: &'static str,
    pub is_bot: bool,
    pub pos: [f32; 3],
    pub stamina: f32,
    pub zone: f32,
}

#[derive(Debug, Clone, Serialize)]
pub struct SnapshotPreviewDto {
    pub server_tick: u64,
    pub match_clock_ms: u32,
    pub shot_clock_ms: u16,
    pub score_a: u16,
    pub score_b: u16,
    pub possession_team: u8,
    pub carrier_id: u32,
    pub ball_pos: [f32; 3],
    pub ball_vel: [f32; 3],
    pub ball_state: u8,
    pub player_count: usize,
    pub players: Vec<PlayerPreviewDto>,
}

impl SnapshotPreviewDto {
    pub fn from_world(world: &SimWorld) -> Self {
        Self {
            server_tick: world.server_tick,
            match_clock_ms: (world.match_clock_secs * 1000.0).round().max(0.0) as u32,
            shot_clock_ms: (world.shot_clock_secs * 1000.0).round().clamp(0.0, 65_535.0) as u16,
            score_a: world.scores[0],
            score_b: world.scores[1],
            possession_team: world.possession_team,
            carrier_id: world.ball.carrier_id.unwrap_or(0),
            ball_pos: [world.ball.pos.x, world.ball.pos.y, world.ball.pos.z],
            ball_vel: [world.ball.vel.x, world.ball.vel.y, world.ball.vel.z],
            ball_state: world.ball.state.as_u8(),
            player_count: world.players.len(),
            players: world
                .players
                .iter()
                .map(|p| PlayerPreviewDto {
                    player_id: p.player_id,
                    team_id: p.team_id,
                    slot: p.slot,
                    username: p.username.clone(),
                    archetype: archetype_to_name(p.profile.id),
                    is_bot: p.is_bot,
                    pos: [p.pos.x, p.pos.y, p.pos.z],
                    stamina: p.stamina,
                    zone: p.zone_energy,
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SpectatorTicket {
    pub room_id: u32,
    pub udp_port: u16,
    pub spectator_token: String,
    pub state: String,
    pub snapshot_preview: SnapshotPreviewDto,
    pub lobby_state: LobbyStateDto,
}

pub fn generate_spectator_token() -> String {
    format!("spec_{}", Uuid::new_v4().simple())
}
