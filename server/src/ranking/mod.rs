pub mod divisions;
pub mod glicko2;

pub use divisions::{division_for_rating, DivisionInfo, DivisionTier};
pub use glicko2::{
    compute_match_rating_updates, expected_score, g_phi, team_composite_opponent, update_rating,
    Glicko2Rating, MatchOutcome, DEFAULT_RATING, DEFAULT_RD, DEFAULT_VOLATILITY, GLICKO2_SCALE,
    SYSTEM_TAU,
};
