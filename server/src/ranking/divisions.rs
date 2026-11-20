use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum DivisionTier {
    Bronze = 0,
    Silver = 1,
    Gold = 2,
    Platinum = 3,
    Diamond = 4,
    Phantom = 5,
}

impl DivisionTier {
    pub fn name(self) -> &'static str {
        match self {
            Self::Bronze => "Bronze",
            Self::Silver => "Silver",
            Self::Gold => "Gold",
            Self::Platinum => "Platinum",
            Self::Diamond => "Diamond",
            Self::Phantom => "Phantom",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DivisionInfo {
    pub name: String,
    pub tier_index: u8,
    pub min_rating: f64,
    pub next_threshold: Option<f64>,
    pub progress_pct: f64,
}

/// Maps a Glicko-2 display rating onto Phantom Court Online's 6 competitive divisions:
/// - `Bronze`:   `< 1300`
/// - `Silver`:   `1300 .. 1499` (`[1300.0, 1500.0)`)
/// - `Gold`:     `1500 .. 1699` (`[1500.0, 1700.0)`)
/// - `Platinum`: `1700 .. 1899` (`[1700.0, 1900.0)`)
/// - `Diamond`:  `1900 .. 2099` (`[1900.0, 2100.0)`)
/// - `Phantom`:  `>= 2100`
pub fn division_for_rating(rating: f64) -> DivisionInfo {
    let r = if rating.is_finite() { rating } else { 1500.0 };

    let (tier, min_rating, next_threshold): (DivisionTier, f64, Option<f64>) = if r < 1300.0 {
        (DivisionTier::Bronze, 0.0, Some(1300.0))
    } else if r < 1500.0 {
        (DivisionTier::Silver, 1300.0, Some(1500.0))
    } else if r < 1700.0 {
        (DivisionTier::Gold, 1500.0, Some(1700.0))
    } else if r < 1900.0 {
        (DivisionTier::Platinum, 1700.0, Some(1900.0))
    } else if r < 2100.0 {
        (DivisionTier::Diamond, 1900.0, Some(2100.0))
    } else {
        (DivisionTier::Phantom, 2100.0, None)
    };

    let progress_pct = match next_threshold {
        Some(next) => {
            let span = (next - min_rating).max(1.0);
            (((r - min_rating) / span) * 100.0).clamp(0.0, 100.0)
        }
        None => 100.0,
    };

    DivisionInfo {
        name: tier.name().to_string(),
        tier_index: tier as u8,
        min_rating,
        next_threshold,
        progress_pct,
    }
}
