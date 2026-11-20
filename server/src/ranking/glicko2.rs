//! Full documented implementation of Mark Glickman's **Glicko-2** rating algorithm
//! ("Example of the Glicko-2 system", 2012/2022) adapted for 1v1 and team (2v2 / 3v3) matches.
//!
//! ### Mathematical Formulation
//!
//! 1. **Constants & Starting Values**
//!    - Glicko-2 scale constant: `GLICKO2_SCALE = 173.7178` (`400 / ln(10)`).
//!    - Default new player: `R = 1500.0`, `RD = 350.0`, `sigma = 0.06`.
//!    - System volatility constraint `tau = 0.5` (controls how fast volatility `sigma` can shift).
//!    - Illinois root-finding tolerance `epsilon = 1e-6`.
//!
//! 2. **Scale Conversion (Step 2)**
//!    ```text
//!    mu  = (R - 1500.0) / 173.7178
//!    phi = RD / 173.7178
//!    ```
//!
//! 3. **Impact Factor `g(phi)` and Expected Score `E(mu, mu_j, phi_j)` (Step 3)**
//!    ```text
//!    g(phi_j)           = 1 / sqrt(1 + 3 * phi_j^2 / pi^2)
//!    E(mu, mu_j, phi_j) = 1 / (1 + exp(-g(phi_j) * (mu - mu_j)))
//!    ```
//!    Estimated variance of the player's rating based solely on game outcomes:
//!    ```text
//!    v = [ sum_j ( g(phi_j)^2 * E_j * (1 - E_j) ) ]^(-1)
//!    ```
//!
//! 4. **Estimated Rating Improvement `Delta` (Step 4)**
//!    ```text
//!    Delta = v * sum_j ( g(phi_j) * (s_j - E_j) )
//!    ```
//!    where `s_j in {1.0 = win, 0.5 = draw, 0.0 = loss}`.
//!
//! 5. **Updated Volatility `sigma'` via Illinois Iterative Root-Finding (Step 5)**
//!    Let `a = ln(sigma^2)` and define:
//!    ```text
//!    f(x) = [ exp(x) * (Delta^2 - phi^2 - v - exp(x)) ] / [ 2 * (phi^2 + v + exp(x))^2 ]
//!           - (x - a) / tau^2
//!    ```
//!    Initialize bracket `[A, B]`:
//!    - `A = a`
//!    - If `Delta^2 > phi^2 + v`: `B = ln(Delta^2 - phi^2 - v)`
//!    - Else: find smallest integer `k >= 1` such that `f(a - k * tau) >= 0`, then `B = a - k * tau`.
//!    Iterate Illinois secant refinement until `|B - A| <= epsilon`, then set:
//!    ```text
//!    sigma' = exp(A / 2)
//!    ```
//!
//! 6. **Pre-Rating Period Deviation `phi*`, New `phi'`, and New `mu'` (Steps 6–7)**
//!    ```text
//!    phi* = sqrt(phi^2 + sigma'^2)
//!    phi' = 1 / sqrt(1 / phi*^2 + 1 / v)
//!    mu'  = mu + phi'^2 * sum_j ( g(phi_j) * (s_j - E_j) )
//!    ```
//!
//! 7. **Back-Conversion to Display Scale (Step 8)**
//!    ```text
//!    R'  = 173.7178 * mu' + 1500.0
//!    RD' = 173.7178 * phi'
//!    ```
//!
//! For **team matches (2v2 / 3v3)**, each player is evaluated against the opposing team's
//! composite opponent (`team_composite_opponent`: mean rating and RMS rating deviation of
//! the opposing roster), ensuring consistent 1v1 / 2v2 / 3v3 deltas and RD shrinkage.

use std::f64::consts::PI;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const GLICKO2_SCALE: f64 = 173.7178;
pub const DEFAULT_RATING: f64 = 1500.0;
pub const DEFAULT_RD: f64 = 350.0;
pub const DEFAULT_VOLATILITY: f64 = 0.06;
pub const SYSTEM_TAU: f64 = 0.5;
const CONVERGENCE_EPSILON: f64 = 1e-6;

const MIN_RATING: f64 = 100.0;
const MAX_RATING: f64 = 4000.0;
const MIN_RD: f64 = 30.0;
const MAX_RD: f64 = 350.0;
const MIN_VOLATILITY: f64 = 0.01;
const MAX_VOLATILITY: f64 = 0.25;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Glicko2Rating {
    pub rating: f64,
    pub rd: f64,
    pub volatility: f64,
}

impl Default for Glicko2Rating {
    fn default() -> Self {
        Self {
            rating: DEFAULT_RATING,
            rd: DEFAULT_RD,
            volatility: DEFAULT_VOLATILITY,
        }
    }
}

impl Glicko2Rating {
    pub fn new(rating: f64, rd: f64, volatility: f64) -> Self {
        Self {
            rating: rating.clamp(MIN_RATING, MAX_RATING),
            rd: rd.clamp(MIN_RD, MAX_RD),
            volatility: volatility.clamp(MIN_VOLATILITY, MAX_VOLATILITY),
        }
    }

    pub fn mu(self) -> f64 {
        (self.rating - DEFAULT_RATING) / GLICKO2_SCALE
    }

    pub fn phi(self) -> f64 {
        self.rd / GLICKO2_SCALE
    }
}

#[derive(Debug, Clone, Copy)]
pub struct MatchOutcome {
    pub opponent: Glicko2Rating,
    /// `1.0` = win, `0.5` = draw, `0.0` = loss
    pub score: f64,
}

/// Glicko-2 weighting factor `g(phi) = 1 / sqrt(1 + 3 * phi^2 / pi^2)`.
pub fn g_phi(phi: f64) -> f64 {
    1.0 / (1.0 + (3.0 * phi * phi) / (PI * PI)).sqrt()
}

/// Expected win probability `E(mu, mu_j, phi_j) = 1 / (1 + exp(-g(phi_j) * (mu - mu_j)))`.
pub fn expected_score(mu: f64, opp_mu: f64, opp_phi: f64) -> f64 {
    let exponent = (-g_phi(opp_phi) * (mu - opp_mu)).clamp(-40.0, 40.0);
    1.0 / (1.0 + exponent.exp())
}

/// Computes a composite opponent profile for team matches (2v2 / 3v3):
/// mean rating, RMS rating deviation, and mean volatility of the opposing squad.
pub fn team_composite_opponent(opponents: &[Glicko2Rating]) -> Glicko2Rating {
    if opponents.is_empty() {
        return Glicko2Rating::default();
    }
    let n = opponents.len() as f64;
    let avg_rating = opponents.iter().map(|r| r.rating).sum::<f64>() / n;
    let rms_rd = (opponents.iter().map(|r| r.rd * r.rd).sum::<f64>() / n).sqrt();
    let avg_vol = opponents.iter().map(|r| r.volatility).sum::<f64>() / n;
    Glicko2Rating::new(avg_rating, rms_rd, avg_vol)
}

/// Updates a player's Glicko-2 `(R, RD, sigma)` after a rating period of `outcomes`.
/// If `outcomes` is empty, performs Glicko-2 inactivity RD inflation `phi' = sqrt(phi^2 + sigma^2)`.
pub fn update_rating(player: Glicko2Rating, outcomes: &[MatchOutcome], tau: f64) -> Glicko2Rating {
    let mu = player.mu();
    let phi = player.phi();
    let sigma = player.volatility.clamp(MIN_VOLATILITY, MAX_VOLATILITY);
    let tau = tau.clamp(0.1, 1.5);

    if outcomes.is_empty() {
        let phi_new = (phi * phi + sigma * sigma).sqrt();
        let rd_new = (phi_new * GLICKO2_SCALE).clamp(MIN_RD, MAX_RD);
        return Glicko2Rating::new(player.rating, rd_new, sigma);
    }

    // Step 3 & Step 4: compute variance `v` and outcome sum `sum_g_diff`
    let mut inv_v = 0.0;
    let mut sum_g_diff = 0.0;
    for outcome in outcomes {
        let opp_mu = outcome.opponent.mu();
        let opp_phi = outcome.opponent.phi();
        let g = g_phi(opp_phi);
        let e = expected_score(mu, opp_mu, opp_phi);
        let s = outcome.score.clamp(0.0, 1.0);
        inv_v += g * g * e * (1.0 - e);
        sum_g_diff += g * (s - e);
    }

    if inv_v <= 1e-12 {
        return player;
    }

    let v = 1.0 / inv_v;
    let delta = v * sum_g_diff;

    // Step 5: solve for new volatility `sigma'` using the Illinois algorithm
    let a = (sigma * sigma).ln();
    let phi_sq = phi * phi;
    let delta_sq = delta * delta;
    let tau_sq = tau * tau;

    let f = |x: f64| -> f64 {
        let ex = x.exp();
        let denom = phi_sq + v + ex;
        let left = (ex * (delta_sq - phi_sq - v - ex)) / (2.0 * denom * denom);
        let right = (x - a) / tau_sq;
        left - right
    };

    let mut upper_a = a;
    let mut upper_b = if delta_sq > phi_sq + v {
        (delta_sq - phi_sq - v).ln()
    } else {
        let mut k = 1.0;
        while f(a - k * tau) < 0.0 && k < 100.0 {
            k += 1.0;
        }
        a - k * tau
    };

    let mut fa = f(upper_a);
    let mut fb = f(upper_b);

    for _ in 0..100 {
        if (upper_b - upper_a).abs() <= CONVERGENCE_EPSILON {
            break;
        }
        let denom = fb - fa;
        if denom.abs() <= 1e-15 {
            break;
        }
        let c = upper_a + (upper_a - upper_b) * fa / denom;
        let fc = f(c);
        if fc * fb <= 0.0 {
            upper_a = upper_b;
            fa = fb;
        } else {
            fa *= 0.5;
        }
        upper_b = c;
        fb = fc;
    }

    let sigma_prime = (upper_a * 0.5).exp().clamp(MIN_VOLATILITY, MAX_VOLATILITY);

    // Step 6: update rating deviation to pre-rating period value `phi*`
    let phi_star = (phi_sq + sigma_prime * sigma_prime).sqrt();

    // Step 7: compute updated `phi'` and `mu'`
    let phi_prime = 1.0 / ((1.0 / (phi_star * phi_star)) + (1.0 / v)).sqrt();
    let mu_prime = mu + (phi_prime * phi_prime) * sum_g_diff;

    // Step 8: convert back to display rating scale
    let new_rating = (GLICKO2_SCALE * mu_prime + DEFAULT_RATING).clamp(MIN_RATING, MAX_RATING);
    let new_rd = (GLICKO2_SCALE * phi_prime).clamp(MIN_RD, MAX_RD);

    Glicko2Rating::new(new_rating, new_rd, sigma_prime)
}

/// Computes Glicko-2 updates for all players in a 1v1, 2v2, or 3v3 match.
/// `winner_team`: `0` = Team A wins, `1` = Team B wins, `-1` (or other) = Draw (`0.5`).
/// Returns `(player_id, new_rating, rating_delta)` for every participant.
pub fn compute_match_rating_updates(
    team_a: &[(Uuid, Glicko2Rating)],
    team_b: &[(Uuid, Glicko2Rating)],
    winner_team: i16,
) -> Vec<(Uuid, Glicko2Rating, f64)> {
    let opp_for_a = if team_b.is_empty() {
        Glicko2Rating::default()
    } else {
        let ratings: Vec<Glicko2Rating> = team_b.iter().map(|(_, r)| *r).collect();
        team_composite_opponent(&ratings)
    };
    let opp_for_b = if team_a.is_empty() {
        Glicko2Rating::default()
    } else {
        let ratings: Vec<Glicko2Rating> = team_a.iter().map(|(_, r)| *r).collect();
        team_composite_opponent(&ratings)
    };

    let (score_a, score_b) = match winner_team {
        0 => (1.0, 0.0),
        1 => (0.0, 1.0),
        _ => (0.5, 0.5),
    };

    let mut results = Vec::with_capacity(team_a.len() + team_b.len());
    for &(pid, before) in team_a {
        let after = update_rating(
            before,
            &[MatchOutcome {
                opponent: opp_for_a,
                score: score_a,
            }],
            SYSTEM_TAU,
        );
        results.push((pid, after, after.rating - before.rating));
    }
    for &(pid, before) in team_b {
        let after = update_rating(
            before,
            &[MatchOutcome {
                opponent: opp_for_b,
                score: score_b,
            }],
            SYSTEM_TAU,
        );
        results.push((pid, after, after.rating - before.rating));
    }
    results
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verifies exact Mark Glickman (2012) reference paper worked example!
    /// Player: R=1500, RD=200, sigma=0.06 vs 3 opponents:
    /// (1400, 30, Win=1), (1550, 100, Loss=0), (1700, 300, Loss=0) with tau=0.5
    /// Paper reference result: R' ≈ 1464.06, RD' ≈ 151.52, sigma' ≈ 0.05999
    #[test]
    fn glickman_reference_worked_example() {
        let player = Glicko2Rating::new(1500.0, 200.0, 0.06);
        let outcomes = vec![
            MatchOutcome {
                opponent: Glicko2Rating::new(1400.0, 30.0, 0.06),
                score: 1.0,
            },
            MatchOutcome {
                opponent: Glicko2Rating::new(1550.0, 100.0, 0.06),
                score: 0.0,
            },
            MatchOutcome {
                opponent: Glicko2Rating::new(1700.0, 300.0, 0.06),
                score: 0.0,
            },
        ];
        let updated = update_rating(player, &outcomes, 0.5);
        assert!(
            (updated.rating - 1464.06).abs() < 0.05,
            "Expected R'≈1464.06, got {}",
            updated.rating
        );
        assert!(
            (updated.rd - 151.52).abs() < 0.05,
            "Expected RD'≈151.52, got {}",
            updated.rd
        );
        assert!(
            (updated.volatility - 0.05999).abs() < 0.0005,
            "Expected sigma'≈0.05999, got {}",
            updated.volatility
        );
    }
}
