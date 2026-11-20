use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use crate::db::{
    DbError, LeaderboardEntryDto, MatchHistoryEntryDto, RecordMatchInput, RecordMatchResult,
    SharedRankingStore, DEFAULT_SEASON_ID,
};
use crate::modes::{
    persist_completed_room_match, GameMode, LobbyStateDto, MatchmakingTicket, ModeError,
    RoomManager, RoomSummaryDto, SpectatorTicket,
};
use crate::sim::ArchetypeId;

pub struct HttpSharedState {
    pub udp_port: u16,
    pub http_port: u16,
    pub tick_rate: u32,
    pub snapshot_rate: u32,
    pub ephemeral_db: bool,
    pub active_players: AtomicUsize,
    pub server_tick: AtomicU64,
    pub room_manager: Arc<Mutex<RoomManager>>,
    pub ranking_store: SharedRankingStore,
}

#[derive(Debug, Serialize)]
pub struct ApiErrorBody {
    pub error: String,
}

fn db_error_response(err: DbError) -> Response {
    let status = match &err {
        DbError::NotFound(_) => StatusCode::NOT_FOUND,
        DbError::BadInput(_) => StatusCode::BAD_REQUEST,
        DbError::Backend(_) => StatusCode::INTERNAL_SERVER_ERROR,
    };
    (status, Json(ApiErrorBody { error: err.to_string() })).into_response()
}

fn mode_error_response(err: ModeError) -> Response {
    let status = match &err {
        ModeError::RoomNotFound | ModeError::MemberNotFound | ModeError::TicketNotFound => {
            StatusCode::NOT_FOUND
        }
        ModeError::RoomFull | ModeError::TeamFull | ModeError::InvalidState(_) => {
            StatusCode::CONFLICT
        }
        ModeError::InvalidMode(_) | ModeError::BadRequest(_) => StatusCode::BAD_REQUEST,
    };
    (status, Json(ApiErrorBody { error: err.message() })).into_response()
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum ArchetypeInput {
    Name(String),
    Code(u8),
}

impl ArchetypeInput {
    fn into_archetype(self) -> ArchetypeId {
        match self {
            ArchetypeInput::Name(s) => ArchetypeId::from_name(&s),
            ArchetypeInput::Code(c) => ArchetypeId::from_u8(c),
        }
    }
}

impl Default for ArchetypeInput {
    fn default() -> Self {
        ArchetypeInput::Name("all_rounder".to_string())
    }
}

// ============================================================================
// GET /health
// ============================================================================

#[derive(Debug, Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub udp_port: u16,
    pub http_port: u16,
    pub tick_rate: u32,
    pub snapshot_rate: u32,
    pub ephemeral_db: bool,
    pub db_backend: &'static str,
    pub active_players: usize,
    pub server_tick: u64,
    pub rooms_count: usize,
    pub supported_modes: [&'static str; 5],
}

async fn health_handler(State(state): State<Arc<HttpSharedState>>) -> Json<HealthResponse> {
    let rooms_count = {
        let rm = state.room_manager.lock().await;
        rm.rooms_count()
    };
    Json(HealthResponse {
        status: "ok",
        udp_port: state.udp_port,
        http_port: state.http_port,
        tick_rate: state.tick_rate,
        snapshot_rate: state.snapshot_rate,
        ephemeral_db: state.ephemeral_db,
        db_backend: state.ranking_store.backend_name(),
        active_players: state.active_players.load(Ordering::Relaxed),
        server_tick: state.server_tick.load(Ordering::Relaxed),
        rooms_count,
        supported_modes: ["1v1", "2v2", "3v3", "private", "spectator"],
    })
}

// ============================================================================
// Matchmaking Endpoints
// ============================================================================

#[derive(Debug, Deserialize)]
pub struct EnqueueRequest {
    pub mode: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub archetype: ArchetypeInput,
    #[serde(default = "default_rating")]
    pub rating: i32,
    #[serde(default)]
    pub fill_bots: bool,
}

fn default_rating() -> i32 {
    1000
}

#[derive(Debug, Serialize)]
pub struct MatchmakingTicketResponse {
    #[serde(flatten)]
    pub ticket: MatchmakingTicket,
    pub udp_port: u16,
    pub lobby_state: Option<LobbyStateDto>,
}

async fn matchmaking_enqueue_handler(
    State(state): State<Arc<HttpSharedState>>,
    Json(req): Json<EnqueueRequest>,
) -> Response {
    let Some(mode) = GameMode::parse(&req.mode) else {
        return mode_error_response(ModeError::InvalidMode(req.mode));
    };
    let arch = req.archetype.into_archetype();
    let (ticket, lobby_state) = {
        let mut rm = state.room_manager.lock().await;
        rm.enqueue_matchmaking(req.username, arch, mode, req.rating, req.fill_bots)
    };
    Json(MatchmakingTicketResponse {
        ticket,
        udp_port: state.udp_port,
        lobby_state,
    })
    .into_response()
}

#[derive(Debug, Deserialize)]
pub struct CancelMatchmakingRequest {
    pub ticket_id: String,
}

#[derive(Debug, Serialize)]
pub struct CancelMatchmakingResponse {
    pub ticket_id: String,
    pub cancelled: bool,
    pub status: String,
}

async fn matchmaking_cancel_handler(
    State(state): State<Arc<HttpSharedState>>,
    Json(req): Json<CancelMatchmakingRequest>,
) -> Response {
    let res = {
        let mut rm = state.room_manager.lock().await;
        rm.cancel_matchmaking(&req.ticket_id)
    };
    match res {
        Ok(ticket) => Json(CancelMatchmakingResponse {
            ticket_id: ticket.ticket_id,
            cancelled: ticket.status == crate::modes::TicketStatus::Cancelled,
            status: format!("{:?}", ticket.status).to_ascii_lowercase(),
        })
        .into_response(),
        Err(e) => mode_error_response(e),
    }
}

async fn matchmaking_status_handler(
    State(state): State<Arc<HttpSharedState>>,
    Path(ticket_id): Path<String>,
) -> Response {
    let res = {
        let rm = state.room_manager.lock().await;
        rm.get_matchmaking_status(&ticket_id)
    };
    match res {
        Ok((ticket, lobby_state)) => Json(MatchmakingTicketResponse {
            ticket,
            udp_port: state.udp_port,
            lobby_state,
        })
        .into_response(),
        Err(e) => mode_error_response(e),
    }
}

// ============================================================================
// Room / Lobby / Ready / Config / Rematch / Spectate Endpoints
// ============================================================================

#[derive(Debug, Deserialize)]
pub struct CreateRoomRequest {
    #[serde(default = "default_mode")]
    pub mode: String,
    #[serde(default)]
    pub is_private: bool,
    #[serde(default)]
    pub fill_bots: bool,
    #[serde(default, alias = "username")]
    pub host_username: String,
    #[serde(default)]
    pub archetype: ArchetypeInput,
}

fn default_mode() -> String {
    "3v3".to_string()
}

#[derive(Debug, Serialize)]
pub struct CreateRoomResponse {
    pub room_id: u32,
    pub room_code: String,
    pub member_id: String,
    pub team_id: u8,
    pub udp_port: u16,
    pub lobby_state: LobbyStateDto,
}

async fn create_room_handler(
    State(state): State<Arc<HttpSharedState>>,
    Json(req): Json<CreateRoomRequest>,
) -> Response {
    let Some(mode) = GameMode::parse(&req.mode) else {
        return mode_error_response(ModeError::InvalidMode(req.mode));
    };
    let arch = req.archetype.into_archetype();
    let res = {
        let mut rm = state.room_manager.lock().await;
        rm.create_room(mode, req.is_private, req.fill_bots, req.host_username, arch)
    };
    match res {
        Ok((room_id, room_code, member, lobby_state)) => Json(CreateRoomResponse {
            room_id,
            room_code,
            member_id: member.member_id,
            team_id: member.team_id,
            udp_port: state.udp_port,
            lobby_state,
        })
        .into_response(),
        Err(e) => mode_error_response(e),
    }
}

#[derive(Debug, Serialize)]
pub struct ListRoomsResponse {
    pub rooms: Vec<RoomSummaryDto>,
    pub total: usize,
}

async fn list_rooms_handler(State(state): State<Arc<HttpSharedState>>) -> Json<ListRoomsResponse> {
    let rooms = {
        let rm = state.room_manager.lock().await;
        rm.list_public_and_live_rooms()
    };
    let total = rooms.len();
    Json(ListRoomsResponse { rooms, total })
}

#[derive(Debug, Deserialize)]
pub struct JoinRoomRequest {
    pub room_code: Option<String>,
    pub room_id: Option<u32>,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub archetype: ArchetypeInput,
    #[serde(default)]
    pub as_spectator: bool,
}

#[derive(Debug, Serialize)]
pub struct JoinRoomResponse {
    pub room_id: u32,
    pub room_code: String,
    pub member_id: String,
    pub team_id: u8,
    pub is_spectator: bool,
    pub udp_port: u16,
    pub lobby_state: LobbyStateDto,
}

async fn join_room_handler(
    State(state): State<Arc<HttpSharedState>>,
    Json(req): Json<JoinRoomRequest>,
) -> Response {
    let arch = req.archetype.into_archetype();
    let res = {
        let mut rm = state.room_manager.lock().await;
        rm.join_room(
            req.room_id,
            req.room_code.as_deref(),
            req.username,
            arch,
            req.as_spectator,
        )
    };
    match res {
        Ok((room_id, room_code, member, lobby_state)) => Json(JoinRoomResponse {
            room_id,
            room_code,
            member_id: member.member_id,
            team_id: member.team_id,
            is_spectator: member.team_id == 255,
            udp_port: state.udp_port,
            lobby_state,
        })
        .into_response(),
        Err(e) => mode_error_response(e),
    }
}

async fn get_room_handler(
    State(state): State<Arc<HttpSharedState>>,
    Path(room_id): Path<u32>,
) -> Response {
    let res = {
        let rm = state.room_manager.lock().await;
        rm.get_room_state(room_id)
    };
    match res {
        Ok(dto) => Json(dto).into_response(),
        Err(e) => mode_error_response(e),
    }
}

#[derive(Debug, Deserialize)]
pub struct ReadyRequest {
    pub member_id: String,
    pub ready: bool,
}

#[derive(Debug, Serialize)]
pub struct ReadyResponse {
    pub room_id: u32,
    pub member_id: String,
    pub ready: bool,
    pub started: bool,
    pub state: String,
    pub lobby_state: LobbyStateDto,
}

async fn ready_room_handler(
    State(state): State<Arc<HttpSharedState>>,
    Path(room_id): Path<u32>,
    Json(req): Json<ReadyRequest>,
) -> Response {
    let res = {
        let mut rm = state.room_manager.lock().await;
        rm.set_ready(room_id, &req.member_id, req.ready)
    };
    match res {
        Ok((started, lobby_state)) => Json(ReadyResponse {
            room_id,
            member_id: req.member_id,
            ready: req.ready,
            started,
            state: lobby_state.state.clone(),
            lobby_state,
        })
        .into_response(),
        Err(e) => mode_error_response(e),
    }
}

#[derive(Debug, Deserialize)]
pub struct ConfigRoomRequest {
    pub member_id: String,
    pub team: Option<u8>,
    pub archetype: Option<ArchetypeInput>,
    pub fill_bots: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct ConfigRoomResponse {
    pub room_id: u32,
    pub lobby_state: LobbyStateDto,
}

async fn config_room_handler(
    State(state): State<Arc<HttpSharedState>>,
    Path(room_id): Path<u32>,
    Json(req): Json<ConfigRoomRequest>,
) -> Response {
    let arch = req.archetype.map(ArchetypeInput::into_archetype);
    let res = {
        let mut rm = state.room_manager.lock().await;
        rm.configure_room_member(room_id, &req.member_id, req.team, arch, req.fill_bots)
    };
    match res {
        Ok(lobby_state) => Json(ConfigRoomResponse {
            room_id,
            lobby_state,
        })
        .into_response(),
        Err(e) => mode_error_response(e),
    }
}

#[derive(Debug, Deserialize)]
pub struct RematchRequest {
    pub member_id: String,
    pub vote: bool,
}

#[derive(Debug, Serialize)]
pub struct RematchResponse {
    pub room_id: u32,
    pub member_id: String,
    pub vote: bool,
    pub rematch_started: bool,
    pub match_number: u32,
    pub state: String,
    pub lobby_state: LobbyStateDto,
}

async fn rematch_room_handler(
    State(state): State<Arc<HttpSharedState>>,
    Path(room_id): Path<u32>,
    Json(req): Json<RematchRequest>,
) -> Response {
    let res = {
        let mut rm = state.room_manager.lock().await;
        rm.vote_rematch(room_id, &req.member_id, req.vote)
    };
    match res {
        Ok((rematch_started, lobby_state)) => Json(RematchResponse {
            room_id,
            member_id: req.member_id,
            vote: req.vote,
            rematch_started,
            match_number: lobby_state.match_number,
            state: lobby_state.state.clone(),
            lobby_state,
        })
        .into_response(),
        Err(e) => mode_error_response(e),
    }
}

#[derive(Debug, Default, Deserialize)]
pub struct FinishMatchRequest {
    pub score_a: Option<u16>,
    pub score_b: Option<u16>,
}

#[derive(Debug, Serialize)]
pub struct FinishMatchResponse {
    pub room_id: u32,
    pub state: String,
    pub scores: [u16; 2],
    pub lobby_state: LobbyStateDto,
    pub ranked_record: Option<RecordMatchResult>,
}

async fn finish_room_handler(
    State(state): State<Arc<HttpSharedState>>,
    Path(room_id): Path<u32>,
    payload: Option<Json<FinishMatchRequest>>,
) -> Response {
    let override_scores = payload.and_then(|Json(req)| match (req.score_a, req.score_b) {
        (Some(a), Some(b)) => Some([a, b]),
        _ => None,
    });
    let res = {
        let mut rm = state.room_manager.lock().await;
        rm.finish_room_match(room_id, override_scores)
    };
    match res {
        Ok((lobby_state, maybe_completed)) => {
            let ranked_record = if let Some(completed) = maybe_completed {
                persist_completed_room_match(&state.ranking_store, completed).await
            } else {
                None
            };
            Json(FinishMatchResponse {
                room_id,
                state: lobby_state.state.clone(),
                scores: lobby_state.scores,
                lobby_state,
                ranked_record,
            })
            .into_response()
        }
        Err(e) => mode_error_response(e),
    }
}

#[derive(Debug, Default, Deserialize)]
pub struct SpectateRequest {
    #[serde(default)]
    pub username: String,
}

async fn spectate_room_handler(
    State(state): State<Arc<HttpSharedState>>,
    Path(room_id): Path<u32>,
    payload: Option<Json<SpectateRequest>>,
) -> Response {
    let uname = payload
        .map(|Json(r)| r.username)
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "Spectator".to_string());
    let res: Result<SpectatorTicket, ModeError> = {
        let mut rm = state.room_manager.lock().await;
        rm.issue_spectate_ticket(room_id, uname)
    };
    match res {
        Ok(ticket) => Json(ticket).into_response(),
        Err(e) => mode_error_response(e),
    }
}

// ============================================================================
// Phase 10 Ranking & Persistence Endpoints (/api/profile*, /api/leaderboard, /api/matches/record)
// ============================================================================

#[derive(Debug, Deserialize)]
pub struct UpsertProfileRequest {
    pub username: String,
    pub archetype_fav: Option<String>,
}

async fn upsert_profile_handler(
    State(state): State<Arc<HttpSharedState>>,
    Json(req): Json<UpsertProfileRequest>,
) -> Response {
    match state
        .ranking_store
        .create_or_get_profile(&req.username, req.archetype_fav.as_deref())
        .await
    {
        Ok(profile) => Json(profile).into_response(),
        Err(e) => db_error_response(e),
    }
}

async fn get_profile_handler(
    State(state): State<Arc<HttpSharedState>>,
    Path(id_or_username): Path<String>,
) -> Response {
    match state.ranking_store.get_profile(&id_or_username).await {
        Ok(profile) => Json(profile).into_response(),
        Err(e) => db_error_response(e),
    }
}

#[derive(Debug, Default, Deserialize)]
pub struct HistoryQuery {
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct MatchHistoryResponse {
    pub player_id: uuid::Uuid,
    pub username: String,
    pub history: Vec<MatchHistoryEntryDto>,
    pub total: usize,
}

async fn get_profile_history_handler(
    State(state): State<Arc<HttpSharedState>>,
    Path(id_or_username): Path<String>,
    Query(q): Query<HistoryQuery>,
) -> Response {
    let limit = q.limit.unwrap_or(20).clamp(1, 200);
    let profile = match state.ranking_store.get_profile(&id_or_username).await {
        Ok(p) => p,
        Err(e) => return db_error_response(e),
    };
    match state
        .ranking_store
        .get_match_history(&profile.id.to_string(), limit)
        .await
    {
        Ok(history) => {
            let total = history.len();
            Json(MatchHistoryResponse {
                player_id: profile.id,
                username: profile.username,
                history,
                total,
            })
            .into_response()
        }
        Err(e) => db_error_response(e),
    }
}

#[derive(Debug, Default, Deserialize)]
pub struct LeaderboardQuery {
    pub season: Option<i32>,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct LeaderboardResponse {
    pub season_id: i32,
    pub entries: Vec<LeaderboardEntryDto>,
    pub total: usize,
}

async fn get_leaderboard_handler(
    State(state): State<Arc<HttpSharedState>>,
    Query(q): Query<LeaderboardQuery>,
) -> Response {
    let season_id = q.season.unwrap_or(DEFAULT_SEASON_ID).max(1);
    let limit = q.limit.unwrap_or(50).clamp(1, 200);
    match state.ranking_store.get_leaderboard(season_id, limit).await {
        Ok(entries) => {
            let total = entries.len();
            Json(LeaderboardResponse {
                season_id,
                entries,
                total,
            })
            .into_response()
        }
        Err(e) => db_error_response(e),
    }
}

async fn record_match_handler(
    State(state): State<Arc<HttpSharedState>>,
    Json(req): Json<RecordMatchInput>,
) -> Response {
    match state.ranking_store.record_match(req).await {
        Ok(result) => Json(result).into_response(),
        Err(e) => db_error_response(e),
    }
}

pub fn build_http_router(state: Arc<HttpSharedState>) -> Router {
    Router::new()
        .route("/health", get(health_handler))
        .route("/api/matchmaking/enqueue", post(matchmaking_enqueue_handler))
        .route("/api/matchmaking/cancel", post(matchmaking_cancel_handler))
        .route("/api/matchmaking/status/:ticket_id", get(matchmaking_status_handler))
        .route("/api/rooms", post(create_room_handler).get(list_rooms_handler))
        .route("/api/rooms/join", post(join_room_handler))
        .route("/api/rooms/:room_id", get(get_room_handler))
        .route("/api/rooms/:room_id/ready", post(ready_room_handler))
        .route("/api/rooms/:room_id/config", post(config_room_handler))
        .route("/api/rooms/:room_id/rematch", post(rematch_room_handler))
        .route("/api/rooms/:room_id/finish", post(finish_room_handler))
        .route("/api/rooms/:room_id/spectate", post(spectate_room_handler))
        .route("/api/profile", post(upsert_profile_handler))
        .route("/api/profile/:id", get(get_profile_handler))
        .route("/api/profile/:id/history", get(get_profile_history_handler))
        .route("/api/leaderboard", get(get_leaderboard_handler))
        .route("/api/matches/record", post(record_match_handler))
        .with_state(state)
}
