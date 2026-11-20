use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ranking::DivisionInfo;

pub const DEFAULT_SEASON_ID: i32 = 1;

#[derive(Debug, Clone)]
pub enum DbError {
    NotFound(String),
    BadInput(String),
    Backend(String),
}

impl std::fmt::Display for DbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DbError::NotFound(m) => write!(f, "not found: {m}"),
            DbError::BadInput(m) => write!(f, "bad input: {m}"),
            DbError::Backend(m) => write!(f, "database error: {m}"),
        }
    }
}

impl std::error::Error for DbError {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SeasonalStatsDto {
    pub season_id: i32,
    pub matches_played: i32,
    pub wins: i32,
    pub losses: i32,
    pub points_scored: i32,
    pub assists: i32,
    pub rebounds: i32,
    pub blocks: i32,
    pub steals: i32,
    pub zone_activations: i32,
    pub peak_rating: f64,
}

impl SeasonalStatsDto {
    pub fn empty(season_id: i32, peak_rating: f64) -> Self {
        Self {
            season_id,
            matches_played: 0,
            wins: 0,
            losses: 0,
            points_scored: 0,
            assists: 0,
            rebounds: 0,
            blocks: 0,
            steals: 0,
            zone_activations: 0,
            peak_rating,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerProfileDto {
    pub id: Uuid,
    pub player_id: Uuid,
    pub username: String,
    pub archetype_fav: String,
    pub rating: f64,
    pub rd: f64,
    pub volatility: f64,
    pub wins: i32,
    pub losses: i32,
    pub win_rate: f64,
    pub division: DivisionInfo,
    pub seasonal_stats: SeasonalStatsDto,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchHistoryEntryDto {
    pub match_id: Uuid,
    pub season_id: i32,
    pub mode: String,
    pub team: i16,
    pub scores: [i32; 2],
    pub team_a_score: i32,
    pub team_b_score: i32,
    pub winner_team: i16,
    pub won: bool,
    pub archetype: String,
    pub points: i32,
    pub assists: i32,
    pub rebounds: i32,
    pub blocks: i32,
    pub steals: i32,
    pub zone_activations: i32,
    pub rating_before: f64,
    pub rating_after: f64,
    pub rating_delta: f64,
    pub duration_sec: i32,
    pub played_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LeaderboardEntryDto {
    pub rank: usize,
    pub player_id: Uuid,
    pub username: String,
    pub rating: f64,
    pub rd: f64,
    pub division: DivisionInfo,
    pub wins: i32,
    pub losses: i32,
    pub win_rate: f64,
    pub peak_rating: f64,
    pub points_scored: i32,
    pub archetype_fav: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ParticipantInput {
    pub player_id: Uuid,
    pub team: i16, // 0 or 1
    #[serde(default = "default_archetype")]
    pub archetype: String,
    #[serde(default)]
    pub points: i32,
    #[serde(default)]
    pub assists: i32,
    #[serde(default)]
    pub rebounds: i32,
    #[serde(default)]
    pub blocks: i32,
    #[serde(default)]
    pub steals: i32,
    #[serde(default)]
    pub zone_activations: i32,
}

fn default_archetype() -> String {
    "all_rounder".to_string()
}

#[derive(Debug, Clone, Deserialize)]
pub struct RecordMatchInput {
    #[serde(default = "default_mode")]
    pub mode: String,
    #[serde(default = "default_season")]
    pub season_id: i32,
    pub team_a_score: i32,
    pub team_b_score: i32,
    #[serde(default = "default_duration")]
    pub duration_sec: i32,
    pub participants: Vec<ParticipantInput>,
}

fn default_mode() -> String {
    "1v1".to_string()
}
fn default_season() -> i32 {
    DEFAULT_SEASON_ID
}
fn default_duration() -> i32 {
    180
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RatingUpdateDto {
    pub player_id: Uuid,
    pub username: String,
    pub team: i16,
    pub rating_before: f64,
    pub rating_after: f64,
    pub rating_delta: f64,
    pub rd_after: f64,
    pub volatility_after: f64,
    pub division: DivisionInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordMatchResult {
    pub match_id: Uuid,
    pub season_id: i32,
    pub mode: String,
    pub team_a_score: i32,
    pub team_b_score: i32,
    pub winner_team: i16,
    pub rating_updates: Vec<RatingUpdateDto>,
}

pub fn compute_win_rate(wins: i32, losses: i32) -> f64 {
    let total = wins + losses;
    if total <= 0 {
        0.0
    } else {
        (wins as f64) / (total as f64)
    }
}

pub fn compute_winner_team(team_a_score: i32, team_b_score: i32) -> i16 {
    if team_a_score > team_b_score {
        0
    } else if team_b_score > team_a_score {
        1
    } else {
        -1
    }
}
