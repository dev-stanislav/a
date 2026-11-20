use std::collections::HashMap;

use chrono::{DateTime, Utc};
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::ranking::{
    compute_match_rating_updates, division_for_rating, Glicko2Rating, DEFAULT_RATING, DEFAULT_RD,
    DEFAULT_VOLATILITY,
};

use super::models::*;
use super::{BoxFuture, RankingStore};

#[derive(Debug, Clone)]
struct PlayerRow {
    id: Uuid,
    username: String,
    archetype_fav: String,
    rating: f64,
    rd: f64,
    volatility: f64,
    wins: i32,
    losses: i32,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
struct MatchRow {
    id: Uuid,
    season_id: i32,
    mode: String,
    team_a_score: i32,
    team_b_score: i32,
    winner_team: i16,
    duration_sec: i32,
    played_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
struct MatchParticipantRow {
    match_id: Uuid,
    player_id: Uuid,
    team: i16,
    archetype: String,
    points: i32,
    assists: i32,
    rebounds: i32,
    blocks: i32,
    steals: i32,
    zone_activations: i32,
    rating_before: f64,
    rating_after: f64,
    rating_delta: f64,
}

#[derive(Debug, Default)]
struct InnerState {
    players: HashMap<Uuid, PlayerRow>,
    username_index: HashMap<String, Uuid>,
    seasonal: HashMap<(Uuid, i32), SeasonalStatsDto>,
    matches: HashMap<Uuid, MatchRow>,
    participants: Vec<MatchParticipantRow>,
}

/// In-memory `RankingStore` implementation used ONLY when `--ephemeral-db` is explicitly passed.
#[derive(Debug, Default)]
pub struct EphemeralStore {
    inner: Mutex<InnerState>,
}

impl EphemeralStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn resolve_player_id(state: &InnerState, key: &str) -> Option<Uuid> {
        let trimmed = key.trim();
        if let Ok(uid) = Uuid::parse_str(trimmed) {
            if state.players.contains_key(&uid) {
                return Some(uid);
            }
        }
        state.username_index.get(&trimmed.to_ascii_lowercase()).copied()
    }

    fn build_profile_dto(state: &InnerState, row: &PlayerRow) -> PlayerProfileDto {
        let seasonal = state
            .seasonal
            .get(&(row.id, DEFAULT_SEASON_ID))
            .cloned()
            .unwrap_or_else(|| SeasonalStatsDto::empty(DEFAULT_SEASON_ID, row.rating));
        PlayerProfileDto {
            id: row.id,
            player_id: row.id,
            username: row.username.clone(),
            archetype_fav: row.archetype_fav.clone(),
            rating: row.rating,
            rd: row.rd,
            volatility: row.volatility,
            wins: row.wins,
            losses: row.losses,
            win_rate: compute_win_rate(row.wins, row.losses),
            division: division_for_rating(row.rating),
            seasonal_stats: seasonal,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

impl RankingStore for EphemeralStore {
    fn backend_name(&self) -> &'static str {
        "ephemeral"
    }

    fn create_or_get_profile<'a>(
        &'a self,
        username: &'a str,
        archetype_fav: Option<&'a str>,
    ) -> BoxFuture<'a, Result<PlayerProfileDto, DbError>> {
        Box::pin(async move {
            let clean = username.trim();
            if clean.is_empty() {
                return Err(DbError::BadInput("username must not be empty".to_string()));
            }
            let lower = clean.to_ascii_lowercase();
            let mut state = self.inner.lock().await;
            if let Some(&existing_id) = state.username_index.get(&lower) {
                if let Some(arch) = archetype_fav {
                    if !arch.trim().is_empty() {
                        if let Some(p) = state.players.get_mut(&existing_id) {
                            p.archetype_fav = arch.trim().to_ascii_lowercase();
                            p.updated_at = Utc::now();
                        }
                    }
                }
                let row = state.players.get(&existing_id).unwrap().clone();
                return Ok(Self::build_profile_dto(&state, &row));
            }

            let id = Uuid::new_v4();
            let now = Utc::now();
            let arch = archetype_fav
                .map(|s| s.trim().to_ascii_lowercase())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "all_rounder".to_string());
            let row = PlayerRow {
                id,
                username: clean.to_string(),
                archetype_fav: arch,
                rating: DEFAULT_RATING,
                rd: DEFAULT_RD,
                volatility: DEFAULT_VOLATILITY,
                wins: 0,
                losses: 0,
                created_at: now,
                updated_at: now,
            };
            state.players.insert(id, row.clone());
            state.username_index.insert(lower, id);
            state.seasonal.insert(
                (id, DEFAULT_SEASON_ID),
                SeasonalStatsDto::empty(DEFAULT_SEASON_ID, DEFAULT_RATING),
            );
            Ok(Self::build_profile_dto(&state, &row))
        })
    }

    fn get_profile<'a>(
        &'a self,
        id_or_username: &'a str,
    ) -> BoxFuture<'a, Result<PlayerProfileDto, DbError>> {
        Box::pin(async move {
            let state = self.inner.lock().await;
            let pid = Self::resolve_player_id(&state, id_or_username)
                .ok_or_else(|| DbError::NotFound(format!("player '{id_or_username}' not found")))?;
            let row = state
                .players
                .get(&pid)
                .ok_or_else(|| DbError::NotFound(format!("player '{id_or_username}' not found")))?;
            Ok(Self::build_profile_dto(&state, row))
        })
    }

    fn get_match_history<'a>(
        &'a self,
        id_or_username: &'a str,
        limit: i64,
    ) -> BoxFuture<'a, Result<Vec<MatchHistoryEntryDto>, DbError>> {
        Box::pin(async move {
            let state = self.inner.lock().await;
            let pid = Self::resolve_player_id(&state, id_or_username)
                .ok_or_else(|| DbError::NotFound(format!("player '{id_or_username}' not found")))?;
            let max_items = limit.clamp(1, 200) as usize;

            let mut entries: Vec<MatchHistoryEntryDto> = state
                .participants
                .iter()
                .filter(|mp| mp.player_id == pid)
                .filter_map(|mp| {
                    let m = state.matches.get(&mp.match_id)?;
                    Some(MatchHistoryEntryDto {
                        match_id: m.id,
                        season_id: m.season_id,
                        mode: m.mode.clone(),
                        team: mp.team,
                        scores: [m.team_a_score, m.team_b_score],
                        team_a_score: m.team_a_score,
                        team_b_score: m.team_b_score,
                        winner_team: m.winner_team,
                        won: m.winner_team >= 0 && mp.team == m.winner_team,
                        archetype: mp.archetype.clone(),
                        points: mp.points,
                        assists: mp.assists,
                        rebounds: mp.rebounds,
                        blocks: mp.blocks,
                        steals: mp.steals,
                        zone_activations: mp.zone_activations,
                        rating_before: mp.rating_before,
                        rating_after: mp.rating_after,
                        rating_delta: mp.rating_delta,
                        duration_sec: m.duration_sec,
                        played_at: m.played_at,
                    })
                })
                .collect();

            entries.sort_by(|a, b| {
                b.played_at
                    .cmp(&a.played_at)
                    .then_with(|| b.match_id.cmp(&a.match_id))
            });
            entries.truncate(max_items);
            Ok(entries)
        })
    }

    fn get_leaderboard<'a>(
        &'a self,
        season_id: i32,
        limit: i64,
    ) -> BoxFuture<'a, Result<Vec<LeaderboardEntryDto>, DbError>> {
        Box::pin(async move {
            let state = self.inner.lock().await;
            let max_items = limit.clamp(1, 200) as usize;
            let mut rows: Vec<&PlayerRow> = state.players.values().collect();
            rows.sort_by(|a, b| {
                b.rating
                    .total_cmp(&a.rating)
                    .then_with(|| b.wins.cmp(&a.wins))
                    .then_with(|| a.username.cmp(&b.username))
            });

            let entries = rows
                .into_iter()
                .take(max_items)
                .enumerate()
                .map(|(idx, p)| {
                    let s = state.seasonal.get(&(p.id, season_id));
                    LeaderboardEntryDto {
                        rank: idx + 1,
                        player_id: p.id,
                        username: p.username.clone(),
                        rating: p.rating,
                        rd: p.rd,
                        division: division_for_rating(p.rating),
                        wins: p.wins,
                        losses: p.losses,
                        win_rate: compute_win_rate(p.wins, p.losses),
                        peak_rating: s.map_or(p.rating, |st| st.peak_rating.max(p.rating)),
                        points_scored: s.map_or(0, |st| st.points_scored),
                        archetype_fav: p.archetype_fav.clone(),
                    }
                })
                .collect();
            Ok(entries)
        })
    }

    fn record_match<'a>(
        &'a self,
        input: RecordMatchInput,
    ) -> BoxFuture<'a, Result<RecordMatchResult, DbError>> {
        Box::pin(async move {
            if input.participants.is_empty() {
                return Err(DbError::BadInput(
                    "participants must not be empty".to_string(),
                ));
            }

            let mut state = self.inner.lock().await;
            let mut team_a = Vec::new();
            let mut team_b = Vec::new();

            for part in &input.participants {
                let p = state.players.get(&part.player_id).ok_or_else(|| {
                    DbError::NotFound(format!("participant player {} not found", part.player_id))
                })?;
                let g = Glicko2Rating::new(p.rating, p.rd, p.volatility);
                if part.team == 0 {
                    team_a.push((p.id, g));
                } else if part.team == 1 {
                    team_b.push((p.id, g));
                } else {
                    return Err(DbError::BadInput(format!(
                        "invalid participant team {} (expected 0 or 1)",
                        part.team
                    )));
                }
            }

            let winner_team = compute_winner_team(input.team_a_score, input.team_b_score);
            let updates = compute_match_rating_updates(&team_a, &team_b, winner_team);
            let update_map: HashMap<Uuid, (Glicko2Rating, f64)> =
                updates.into_iter().map(|(id, r, d)| (id, (r, d))).collect();

            let match_id = Uuid::new_v4();
            let now = Utc::now();
            state.matches.insert(
                match_id,
                MatchRow {
                    id: match_id,
                    season_id: input.season_id,
                    mode: input.mode.clone(),
                    team_a_score: input.team_a_score,
                    team_b_score: input.team_b_score,
                    winner_team,
                    duration_sec: input.duration_sec.max(0),
                    played_at: now,
                },
            );

            let mut rating_updates = Vec::with_capacity(input.participants.len());

            for part in &input.participants {
                let (after, delta) = update_map[&part.player_id];
                let won = winner_team >= 0 && part.team == winner_team;
                let lost = winner_team >= 0 && part.team != winner_team;

                let (username, before_rating) = {
                    let p = state.players.get_mut(&part.player_id).unwrap();
                    let before = p.rating;
                    p.rating = after.rating;
                    p.rd = after.rd;
                    p.volatility = after.volatility;
                    if won {
                        p.wins += 1;
                    } else if lost {
                        p.losses += 1;
                    }
                    p.updated_at = now;
                    (p.username.clone(), before)
                };

                let seasonal = state
                    .seasonal
                    .entry((part.player_id, input.season_id))
                    .or_insert_with(|| SeasonalStatsDto::empty(input.season_id, before_rating));
                seasonal.matches_played += 1;
                if won {
                    seasonal.wins += 1;
                } else if lost {
                    seasonal.losses += 1;
                }
                seasonal.points_scored += part.points;
                seasonal.assists += part.assists;
                seasonal.rebounds += part.rebounds;
                seasonal.blocks += part.blocks;
                seasonal.steals += part.steals;
                seasonal.zone_activations += part.zone_activations;
                if after.rating > seasonal.peak_rating {
                    seasonal.peak_rating = after.rating;
                }

                state.participants.push(MatchParticipantRow {
                    match_id,
                    player_id: part.player_id,
                    team: part.team,
                    archetype: part.archetype.clone(),
                    points: part.points,
                    assists: part.assists,
                    rebounds: part.rebounds,
                    blocks: part.blocks,
                    steals: part.steals,
                    zone_activations: part.zone_activations,
                    rating_before: before_rating,
                    rating_after: after.rating,
                    rating_delta: delta,
                });

                rating_updates.push(RatingUpdateDto {
                    player_id: part.player_id,
                    username,
                    team: part.team,
                    rating_before: before_rating,
                    rating_after: after.rating,
                    rating_delta: delta,
                    rd_after: after.rd,
                    volatility_after: after.volatility,
                    division: division_for_rating(after.rating),
                });
            }

            Ok(RecordMatchResult {
                match_id,
                season_id: input.season_id,
                mode: input.mode,
                team_a_score: input.team_a_score,
                team_b_score: input.team_b_score,
                winner_team,
                rating_updates,
            })
        })
    }
}
