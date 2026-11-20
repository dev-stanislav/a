use std::collections::HashMap;

use chrono::{DateTime, Utc};
use tokio::sync::Mutex;
use tokio_postgres::{Client, NoTls};
use tracing::{info, warn};
use uuid::Uuid;

use crate::ranking::{
    compute_match_rating_updates, division_for_rating, Glicko2Rating, DEFAULT_RATING, DEFAULT_RD,
    DEFAULT_VOLATILITY,
};

use super::models::*;
use super::{BoxFuture, RankingStore};

const MIGRATION_001_INITIAL_SCHEMA: &str =
    include_str!("../../migrations/001_initial_schema.sql");

/// Production PostgreSQL 16 `RankingStore` powered by pure-Rust `tokio-postgres` (no OpenSSL).
pub struct PostgresStore {
    client: Mutex<Client>,
}

impl PostgresStore {
    /// Connects to PostgreSQL at `database_url` and idempotently applies `001_initial_schema.sql`.
    pub async fn connect(database_url: &str) -> Result<Self, DbError> {
        let (client, connection) = tokio_postgres::connect(database_url, NoTls)
            .await
            .map_err(|e| DbError::Backend(format!("failed to connect to PostgreSQL: {e}")))?;

        tokio::spawn(async move {
            if let Err(err) = connection.await {
                warn!("PostgreSQL connection loop terminated: {err}");
            }
        });

        client
            .batch_execute(MIGRATION_001_INITIAL_SCHEMA)
            .await
            .map_err(|e| DbError::Backend(format!("failed running 001_initial_schema.sql: {e}")))?;

        info!("PostgreSQL connected and 001_initial_schema.sql verified");
        Ok(Self {
            client: Mutex::new(client),
        })
    }

    async fn fetch_profile_by_uuid(
        client: &Client,
        player_id: Uuid,
    ) -> Result<PlayerProfileDto, DbError> {
        let row = client
            .query_opt(
                "SELECT p.id, p.username, p.archetype_fav, p.rating, p.rd, p.volatility,
                        p.wins, p.losses, p.created_at, p.updated_at,
                        COALESCE(s.matches_played, 0), COALESCE(s.wins, 0), COALESCE(s.losses, 0),
                        COALESCE(s.points_scored, 0), COALESCE(s.assists, 0), COALESCE(s.rebounds, 0),
                        COALESCE(s.blocks, 0), COALESCE(s.steals, 0), COALESCE(s.zone_activations, 0),
                        COALESCE(s.peak_rating, p.rating)
                 FROM players p
                 LEFT JOIN seasonal_stats s
                   ON s.player_id = p.id AND s.season_id = $2
                 WHERE p.id = $1",
                &[&player_id, &DEFAULT_SEASON_ID],
            )
            .await
            .map_err(|e| DbError::Backend(e.to_string()))?
            .ok_or_else(|| DbError::NotFound(format!("player {player_id} not found")))?;

        Ok(row_to_profile_dto(&row))
    }

    async fn resolve_uuid(client: &Client, id_or_username: &str) -> Result<Uuid, DbError> {
        let trimmed = id_or_username.trim();
        if let Ok(uid) = Uuid::parse_str(trimmed) {
            let exists = client
                .query_opt("SELECT id FROM players WHERE id = $1", &[&uid])
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;
            if exists.is_some() {
                return Ok(uid);
            }
        }
        let row = client
            .query_opt(
                "SELECT id FROM players WHERE LOWER(username) = LOWER($1)",
                &[&trimmed],
            )
            .await
            .map_err(|e| DbError::Backend(e.to_string()))?
            .ok_or_else(|| DbError::NotFound(format!("player '{trimmed}' not found")))?;
        Ok(row.get::<_, Uuid>(0))
    }
}

fn row_to_profile_dto(row: &tokio_postgres::Row) -> PlayerProfileDto {
    let id: Uuid = row.get(0);
    let username: String = row.get(1);
    let archetype_fav: String = row.get(2);
    let rating: f64 = row.get(3);
    let rd: f64 = row.get(4);
    let volatility: f64 = row.get(5);
    let wins: i32 = row.get(6);
    let losses: i32 = row.get(7);
    let created_at: DateTime<Utc> = row.get(8);
    let updated_at: DateTime<Utc> = row.get(9);

    let seasonal_stats = SeasonalStatsDto {
        season_id: DEFAULT_SEASON_ID,
        matches_played: row.get(10),
        wins: row.get(11),
        losses: row.get(12),
        points_scored: row.get(13),
        assists: row.get(14),
        rebounds: row.get(15),
        blocks: row.get(16),
        steals: row.get(17),
        zone_activations: row.get(18),
        peak_rating: row.get(19),
    };

    PlayerProfileDto {
        id,
        player_id: id,
        username,
        archetype_fav,
        rating,
        rd,
        volatility,
        wins,
        losses,
        win_rate: compute_win_rate(wins, losses),
        division: division_for_rating(rating),
        seasonal_stats,
        created_at,
        updated_at,
    }
}

impl RankingStore for PostgresStore {
    fn backend_name(&self) -> &'static str {
        "postgres"
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
            let arch_opt = archetype_fav
                .map(|s| s.trim().to_ascii_lowercase())
                .filter(|s| !s.is_empty());
            let insert_arch = arch_opt.as_deref().unwrap_or("all_rounder");

            let client = self.client.lock().await;

            // Check existing case-insensitively first so username lookup is consistent
            let existing = client
                .query_opt(
                    "SELECT id FROM players WHERE LOWER(username) = LOWER($1)",
                    &[&clean],
                )
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;

            let player_id = if let Some(row) = existing {
                let pid: Uuid = row.get(0);
                if let Some(ref new_arch) = arch_opt {
                    client
                        .execute(
                            "UPDATE players SET archetype_fav = $2, updated_at = NOW() WHERE id = $1",
                            &[&pid, new_arch],
                        )
                        .await
                        .map_err(|e| DbError::Backend(e.to_string()))?;
                }
                pid
            } else {
                let new_id = Uuid::new_v4();
                let row = client
                    .query_one(
                        "INSERT INTO players (id, username, archetype_fav, rating, rd, volatility)
                         VALUES ($1, $2, $3, $4, $5, $6)
                         ON CONFLICT (username) DO UPDATE SET updated_at = NOW()
                         RETURNING id",
                        &[
                            &new_id,
                            &clean,
                            &insert_arch,
                            &DEFAULT_RATING,
                            &DEFAULT_RD,
                            &DEFAULT_VOLATILITY,
                        ],
                    )
                    .await
                    .map_err(|e| DbError::Backend(e.to_string()))?;
                row.get::<_, Uuid>(0)
            };

            // Ensure current season stats row exists
            client
                .execute(
                    "INSERT INTO seasonal_stats (player_id, season_id, peak_rating)
                     SELECT id, $2, rating FROM players WHERE id = $1
                     ON CONFLICT (player_id, season_id) DO NOTHING",
                    &[&player_id, &DEFAULT_SEASON_ID],
                )
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;

            Self::fetch_profile_by_uuid(&client, player_id).await
        })
    }

    fn get_profile<'a>(
        &'a self,
        id_or_username: &'a str,
    ) -> BoxFuture<'a, Result<PlayerProfileDto, DbError>> {
        Box::pin(async move {
            let client = self.client.lock().await;
            let pid = Self::resolve_uuid(&client, id_or_username).await?;
            Self::fetch_profile_by_uuid(&client, pid).await
        })
    }

    fn get_match_history<'a>(
        &'a self,
        id_or_username: &'a str,
        limit: i64,
    ) -> BoxFuture<'a, Result<Vec<MatchHistoryEntryDto>, DbError>> {
        Box::pin(async move {
            let clamped_limit = limit.clamp(1, 200);
            let client = self.client.lock().await;
            let pid = Self::resolve_uuid(&client, id_or_username).await?;

            let rows = client
                .query(
                    "SELECT m.id, m.season_id, m.mode, mp.team, m.team_a_score, m.team_b_score,
                            m.winner_team, mp.archetype, mp.points, mp.assists, mp.rebounds,
                            mp.blocks, mp.steals, mp.zone_activations,
                            mp.rating_before, mp.rating_after, mp.rating_delta,
                            m.duration_sec, m.played_at
                     FROM match_participants mp
                     INNER JOIN matches m ON m.id = mp.match_id
                     WHERE mp.player_id = $1
                     ORDER BY m.played_at DESC, m.id DESC
                     LIMIT $2",
                    &[&pid, &clamped_limit],
                )
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;

            let mut out = Vec::with_capacity(rows.len());
            for row in rows {
                let team: i16 = row.get(3);
                let team_a_score: i32 = row.get(4);
                let team_b_score: i32 = row.get(5);
                let winner_team: i16 = row.get(6);
                out.push(MatchHistoryEntryDto {
                    match_id: row.get(0),
                    season_id: row.get(1),
                    mode: row.get(2),
                    team,
                    scores: [team_a_score, team_b_score],
                    team_a_score,
                    team_b_score,
                    winner_team,
                    won: winner_team >= 0 && team == winner_team,
                    archetype: row.get(7),
                    points: row.get(8),
                    assists: row.get(9),
                    rebounds: row.get(10),
                    blocks: row.get(11),
                    steals: row.get(12),
                    zone_activations: row.get(13),
                    rating_before: row.get(14),
                    rating_after: row.get(15),
                    rating_delta: row.get(16),
                    duration_sec: row.get(17),
                    played_at: row.get(18),
                });
            }
            Ok(out)
        })
    }

    fn get_leaderboard<'a>(
        &'a self,
        season_id: i32,
        limit: i64,
    ) -> BoxFuture<'a, Result<Vec<LeaderboardEntryDto>, DbError>> {
        Box::pin(async move {
            let clamped_limit = limit.clamp(1, 200);
            let client = self.client.lock().await;
            let rows = client
                .query(
                    "SELECT p.id, p.username, p.rating, p.rd, p.wins, p.losses, p.archetype_fav,
                            GREATEST(COALESCE(s.peak_rating, p.rating), p.rating) AS peak_rating,
                            COALESCE(s.points_scored, 0) AS points_scored
                     FROM players p
                     LEFT JOIN seasonal_stats s
                       ON s.player_id = p.id AND s.season_id = $1
                     ORDER BY p.rating DESC, p.wins DESC, p.username ASC
                     LIMIT $2",
                    &[&season_id, &clamped_limit],
                )
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;

            let mut out = Vec::with_capacity(rows.len());
            for (idx, row) in rows.into_iter().enumerate() {
                let rating: f64 = row.get(2);
                let wins: i32 = row.get(4);
                let losses: i32 = row.get(5);
                out.push(LeaderboardEntryDto {
                    rank: idx + 1,
                    player_id: row.get(0),
                    username: row.get(1),
                    rating,
                    rd: row.get(3),
                    division: division_for_rating(rating),
                    wins,
                    losses,
                    win_rate: compute_win_rate(wins, losses),
                    peak_rating: row.get(7),
                    points_scored: row.get(8),
                    archetype_fav: row.get(6),
                });
            }
            Ok(out)
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

            let mut client = self.client.lock().await;
            let tx = client
                .transaction()
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;

            let mut team_a = Vec::new();
            let mut team_b = Vec::new();
            let mut player_meta: HashMap<Uuid, (String, f64)> = HashMap::new();

            for part in &input.participants {
                let row = tx
                    .query_opt(
                        "SELECT username, rating, rd, volatility FROM players WHERE id = $1 FOR UPDATE",
                        &[&part.player_id],
                    )
                    .await
                    .map_err(|e| DbError::Backend(e.to_string()))?
                    .ok_or_else(|| {
                        DbError::NotFound(format!("participant player {} not found", part.player_id))
                    })?;

                let uname: String = row.get(0);
                let rating: f64 = row.get(1);
                let rd: f64 = row.get(2);
                let vol: f64 = row.get(3);
                let g = Glicko2Rating::new(rating, rd, vol);
                player_meta.insert(part.player_id, (uname, rating));
                if part.team == 0 {
                    team_a.push((part.player_id, g));
                } else if part.team == 1 {
                    team_b.push((part.player_id, g));
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
            let duration_sec = input.duration_sec.max(0);
            tx.execute(
                "INSERT INTO matches (id, season_id, mode, team_a_score, team_b_score, winner_team, duration_sec)
                 VALUES ($1, $2, $3, $4, $5, $6, $7)",
                &[
                    &match_id,
                    &input.season_id,
                    &input.mode,
                    &input.team_a_score,
                    &input.team_b_score,
                    &winner_team,
                    &duration_sec,
                ],
            )
            .await
            .map_err(|e| DbError::Backend(e.to_string()))?;

            let mut rating_updates = Vec::with_capacity(input.participants.len());

            for part in &input.participants {
                let (after, delta) = update_map[&part.player_id];
                let (username, before_rating) = player_meta[&part.player_id].clone();
                let win_inc: i32 = i32::from(winner_team >= 0 && part.team == winner_team);
                let loss_inc: i32 = i32::from(winner_team >= 0 && part.team != winner_team);

                tx.execute(
                    "UPDATE players
                     SET rating = $2, rd = $3, volatility = $4,
                         wins = wins + $5, losses = losses + $6, updated_at = NOW()
                     WHERE id = $1",
                    &[
                        &part.player_id,
                        &after.rating,
                        &after.rd,
                        &after.volatility,
                        &win_inc,
                        &loss_inc,
                    ],
                )
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;

                let peak_candidate = after.rating.max(before_rating);
                tx.execute(
                    "INSERT INTO seasonal_stats (
                        player_id, season_id, matches_played, wins, losses,
                        points_scored, assists, rebounds, blocks, steals, zone_activations, peak_rating
                     ) VALUES ($1, $2, 1, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                     ON CONFLICT (player_id, season_id) DO UPDATE SET
                        matches_played = seasonal_stats.matches_played + 1,
                        wins = seasonal_stats.wins + EXCLUDED.wins,
                        losses = seasonal_stats.losses + EXCLUDED.losses,
                        points_scored = seasonal_stats.points_scored + EXCLUDED.points_scored,
                        assists = seasonal_stats.assists + EXCLUDED.assists,
                        rebounds = seasonal_stats.rebounds + EXCLUDED.rebounds,
                        blocks = seasonal_stats.blocks + EXCLUDED.blocks,
                        steals = seasonal_stats.steals + EXCLUDED.steals,
                        zone_activations = seasonal_stats.zone_activations + EXCLUDED.zone_activations,
                        peak_rating = GREATEST(seasonal_stats.peak_rating, EXCLUDED.peak_rating)",
                    &[
                        &part.player_id,
                        &input.season_id,
                        &win_inc,
                        &loss_inc,
                        &part.points,
                        &part.assists,
                        &part.rebounds,
                        &part.blocks,
                        &part.steals,
                        &part.zone_activations,
                        &peak_candidate,
                    ],
                )
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;

                tx.execute(
                    "INSERT INTO match_participants (
                        match_id, player_id, team, archetype,
                        points, assists, rebounds, blocks, steals, zone_activations,
                        rating_before, rating_after, rating_delta
                     ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)",
                    &[
                        &match_id,
                        &part.player_id,
                        &part.team,
                        &part.archetype,
                        &part.points,
                        &part.assists,
                        &part.rebounds,
                        &part.blocks,
                        &part.steals,
                        &part.zone_activations,
                        &before_rating,
                        &after.rating,
                        &delta,
                    ],
                )
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;

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

            tx.commit()
                .await
                .map_err(|e| DbError::Backend(e.to_string()))?;

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
