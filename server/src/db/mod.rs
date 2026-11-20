pub mod ephemeral_store;
pub mod models;
pub mod postgres_store;

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

pub use ephemeral_store::EphemeralStore;
pub use models::*;
pub use postgres_store::PostgresStore;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

pub const DEFAULT_DATABASE_URL: &str = "postgres://postgres@127.0.0.1:15432/phantom_court";

/// Backend-agnostic async persistence trait implemented by both `PostgresStore` (PostgreSQL 16)
/// and `EphemeralStore` (explicit `--ephemeral-db` test mode).
pub trait RankingStore: Send + Sync {
    fn backend_name(&self) -> &'static str;

    fn create_or_get_profile<'a>(
        &'a self,
        username: &'a str,
        archetype_fav: Option<&'a str>,
    ) -> BoxFuture<'a, Result<PlayerProfileDto, DbError>>;

    fn get_profile<'a>(
        &'a self,
        id_or_username: &'a str,
    ) -> BoxFuture<'a, Result<PlayerProfileDto, DbError>>;

    fn get_match_history<'a>(
        &'a self,
        id_or_username: &'a str,
        limit: i64,
    ) -> BoxFuture<'a, Result<Vec<MatchHistoryEntryDto>, DbError>>;

    fn get_leaderboard<'a>(
        &'a self,
        season_id: i32,
        limit: i64,
    ) -> BoxFuture<'a, Result<Vec<LeaderboardEntryDto>, DbError>>;

    fn record_match<'a>(
        &'a self,
        input: RecordMatchInput,
    ) -> BoxFuture<'a, Result<RecordMatchResult, DbError>>;
}

pub type SharedRankingStore = Arc<dyn RankingStore>;
