use super::{BallState, Vec3, FIXED_DT};

/// 16-tick (~267ms @ 60 Hz) authoritative world pose history ring.
pub const LAG_COMP_HISTORY_TICKS: usize = 16;
/// Maximum permitted lag-compensation rewind window (250ms = 15 ticks @ 60 Hz).
pub const MAX_LAG_COMP_MS: f32 = 250.0;
pub const MAX_LAG_COMP_TICKS: u64 = 15;

#[derive(Debug, Clone, Copy)]
pub struct PlayerPose {
    pub player_id: u32,
    pub team_id: u8,
    pub pos: Vec3,
    pub vel: Vec3,
    pub facing_yaw: f32,
    pub grounded: bool,
    pub is_dunking: bool,
    pub is_armored: bool,
    pub steal_shielded: bool,
    pub ankle_broken: bool,
    pub in_stance: bool,
    pub stamina: f32,
    pub dribble_hand_right: bool,
}

#[derive(Debug, Clone)]
pub struct WorldPoseSnapshot {
    pub tick: u64,
    pub ball_pos: Vec3,
    pub ball_vel: Vec3,
    pub ball_state: BallState,
    pub carrier_id: Option<u32>,
    pub last_shooter_team: Option<u8>,
    pub last_shooter_id: Option<u32>,
    pub block_resistance: f32,
    pub players: Vec<PlayerPose>,
}

impl WorldPoseSnapshot {
    pub fn find_player(&self, player_id: u32) -> Option<&PlayerPose> {
        self.players.iter().find(|p| p.player_id == player_id)
    }
}

#[derive(Debug, Clone)]
pub struct LagCompHistory {
    ring: Vec<Option<WorldPoseSnapshot>>,
    latest_tick: u64,
    has_samples: bool,
}

impl Default for LagCompHistory {
    fn default() -> Self {
        Self::new()
    }
}

impl LagCompHistory {
    pub fn new() -> Self {
        Self {
            ring: vec![None; LAG_COMP_HISTORY_TICKS],
            latest_tick: 0,
            has_samples: false,
        }
    }

    pub fn clear(&mut self) {
        for slot in &mut self.ring {
            *slot = None;
        }
        self.latest_tick = 0;
        self.has_samples = false;
    }

    pub fn record(&mut self, snapshot: WorldPoseSnapshot) {
        let idx = (snapshot.tick as usize) % LAG_COMP_HISTORY_TICKS;
        self.latest_tick = snapshot.tick;
        self.has_samples = true;
        self.ring[idx] = Some(snapshot);
    }

    pub fn latest_tick(&self) -> u64 {
        self.latest_tick
    }

    pub fn len(&self) -> usize {
        self.ring.iter().filter(|s| s.is_some()).count()
    }

    pub fn is_empty(&self) -> bool {
        !self.has_samples
    }

    /// Converts a client's round-trip time (RTT in ms) into a clamped rewind tick count.
    /// Uses one-way latency (`rtt_ms * 0.5`) clamped to `[0, 250ms]` (`<= 15 ticks`).
    pub fn rewind_ticks_for_rtt(rtt_ms: f32) -> u64 {
        if !rtt_ms.is_finite() || rtt_ms <= 0.0 {
            return 0;
        }
        let one_way_ms = (rtt_ms * 0.5).clamp(0.0, MAX_LAG_COMP_MS);
        let ticks = (one_way_ms / (FIXED_DT * 1000.0)).round() as u64;
        ticks.min(MAX_LAG_COMP_TICKS)
    }

    /// Converts a full perceived latency window in milliseconds (clamped max 250ms) into ticks.
    pub fn rewind_ticks_for_latency_ms(latency_ms: f32) -> u64 {
        if !latency_ms.is_finite() || latency_ms <= 0.0 {
            return 0;
        }
        let clamped_ms = latency_ms.clamp(0.0, MAX_LAG_COMP_MS);
        let ticks = (clamped_ms / (FIXED_DT * 1000.0)).round() as u64;
        ticks.min(MAX_LAG_COMP_TICKS)
    }

    /// Returns the authoritative historical pose at `target_tick` (clamped inside the 250ms window).
    pub fn sample_at_tick(&self, current_tick: u64, target_tick: u64) -> Option<&WorldPoseSnapshot> {
        if !self.has_samples {
            return None;
        }
        let min_allowed = current_tick.saturating_sub(MAX_LAG_COMP_TICKS);
        let clamped_tick = target_tick.clamp(min_allowed, current_tick);

        // Exact lookup first
        let idx = (clamped_tick as usize) % LAG_COMP_HISTORY_TICKS;
        if let Some(ref snap) = self.ring[idx] {
            if snap.tick == clamped_tick {
                return Some(snap);
            }
        }

        // Nearest recorded sample within window
        self.ring
            .iter()
            .filter_map(|s| s.as_ref())
            .min_by_key(|s| s.tick.abs_diff(clamped_tick))
    }

    /// Computes perceived target tick for a defender with `perceived_latency_ms` (clamped <= 250ms)
    /// and returns that historical world pose snapshot.
    pub fn sample_rewound_by_ms(&self, current_tick: u64, latency_ms: f32) -> Option<&WorldPoseSnapshot> {
        let rewind_ticks = Self::rewind_ticks_for_latency_ms(latency_ms);
        let target_tick = current_tick.saturating_sub(rewind_ticks);
        self.sample_at_tick(current_tick, target_tick)
    }
}
