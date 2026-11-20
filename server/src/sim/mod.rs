pub mod ball_sim;
pub mod bot_ai;
pub mod combo_validator;
pub mod lag_comp;
pub mod player_sim;
pub mod world;

pub use ball_sim::{BallSim, BallState, ScoredBasket};
pub use bot_ai::compute_bot_input;
pub use combo_validator::{ComboTriggerResult, ComboValidator, MoveDef, MoveId};
pub use lag_comp::{LagCompHistory, PlayerPose, WorldPoseSnapshot, LAG_COMP_HISTORY_TICKS, MAX_LAG_COMP_MS};
pub use player_sim::{ArchetypeId, ArchetypeProfile, PlayerSim, StealPhase};
pub use world::SimWorld;

// ============================================================================
// Canonical Simulation & Court Geometry Constants (ARCHITECTURE.md)
// ============================================================================

pub const FIXED_TICK_RATE: u32 = 60;
pub const FIXED_DT: f32 = 1.0 / 60.0;

pub const COURT_HALF_WIDTH: f32 = 7.5; // x in [-7.5, +7.5]
pub const COURT_HALF_LENGTH: f32 = 14.0; // z in [-14.0, +14.0]
pub const FLOOR_Y: f32 = 0.0;

// Hoop A: Team 0 defends, Team 1 attacks
pub const HOOP_A_RIM: Vec3 = Vec3 {
    x: 0.0,
    y: 3.05,
    z: 12.425,
};
pub const HOOP_A_BACKBOARD_Z: f32 = 12.80;

// Hoop B: Team 1 defends, Team 0 attacks
pub const HOOP_B_RIM: Vec3 = Vec3 {
    x: 0.0,
    y: 3.05,
    z: -12.425,
};
pub const HOOP_B_BACKBOARD_Z: f32 = -12.80;

pub const RIM_INNER_RADIUS: f32 = 0.225;
pub const RIM_TUBE_RADIUS: f32 = 0.016;
pub const RIM_SEGMENTS: usize = 12;

pub const BACKBOARD_HALF_WIDTH: f32 = 0.90; // 1.80m wide
pub const BACKBOARD_MIN_Y: f32 = 2.90;
pub const BACKBOARD_MAX_Y: f32 = 3.95;

pub const UPPER_GATE_Y: f32 = 3.08;
pub const LOWER_GATE_Y: f32 = 2.86;
pub const GATE_WINDOW_SECS: f32 = 0.60;

pub const THREE_POINT_RADIUS: f32 = 6.75;
pub const CORNER_THREE_ABS_X: f32 = 6.60;

pub const BALL_RADIUS: f32 = 0.12;
pub const BALL_MASS: f32 = 0.62;
pub const BALL_GRAVITY: f32 = 9.81;
pub const FLOOR_BOUNCE: f32 = 0.78;
pub const RIM_BOUNCE: f32 = 0.58;
pub const BACKBOARD_BOUNCE: f32 = 0.65;
pub const AIR_DRAG_COEFF: f32 = 0.0045;
pub const MAGNUS_COEFF: f32 = 0.00042;

pub const PLAYER_GRAVITY: f32 = 15.0;
pub const STANCE_SPEED: f32 = 4.4;

pub const ZONE_MAX_ENERGY: f32 = 100.0;
pub const ZONE_DURATION_SECS: f32 = 12.0;
pub const ZONE_SPEED_MULT: f32 = 1.15;
pub const ZONE_JUMP_MULT: f32 = 1.20;
pub const ZONE_BLOCK_REACH_MULT: f32 = 1.20;
pub const ZONE_STAMINA_COST_MULT: f32 = 0.75;

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Vec2 {
    pub x: f32,
    pub y: f32,
}

impl Vec2 {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    pub fn length_sq(self) -> f32 {
        self.x * self.x + self.y * self.y
    }

    pub fn length(self) -> f32 {
        self.length_sq().sqrt()
    }

    pub fn dot(self, other: Self) -> f32 {
        self.x * other.x + self.y * other.y
    }

    pub fn normalized_or_zero(self) -> Self {
        let l2 = self.length_sq();
        if l2 > 1e-8 {
            let inv = l2.sqrt().recip();
            Self {
                x: self.x * inv,
                y: self.y * inv,
            }
        } else {
            Self::ZERO
        }
    }

    pub fn clamp_unit(self) -> Self {
        if !self.x.is_finite() || !self.y.is_finite() {
            return Self::ZERO;
        }
        let l2 = self.length_sq();
        if l2 > 1.0 {
            let inv = l2.sqrt().recip();
            Self {
                x: self.x * inv,
                y: self.y * inv,
            }
        } else {
            self
        }
    }

    pub fn move_toward(self, target: Self, max_delta: f32) -> Self {
        let dx = target.x - self.x;
        let dy = target.y - self.y;
        let dist_sq = dx * dx + dy * dy;
        if dist_sq <= max_delta * max_delta || dist_sq <= 1e-10 {
            target
        } else {
            let dist = dist_sq.sqrt();
            Self {
                x: self.x + dx / dist * max_delta,
                y: self.y + dy / dist * max_delta,
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vec3 {
    pub const ZERO: Self = Self {
        x: 0.0,
        y: 0.0,
        z: 0.0,
    };
    pub const UP: Self = Self {
        x: 0.0,
        y: 1.0,
        z: 0.0,
    };

    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }

    pub fn add(self, other: Self) -> Self {
        Self {
            x: self.x + other.x,
            y: self.y + other.y,
            z: self.z + other.z,
        }
    }

    pub fn sub(self, other: Self) -> Self {
        Self {
            x: self.x - other.x,
            y: self.y - other.y,
            z: self.z - other.z,
        }
    }

    pub fn scale(self, s: f32) -> Self {
        Self {
            x: self.x * s,
            y: self.y * s,
            z: self.z * s,
        }
    }

    pub fn dot(self, other: Self) -> f32 {
        self.x * other.x + self.y * other.y + self.z * other.z
    }

    pub fn cross(self, other: Self) -> Self {
        Self {
            x: self.y * other.z - self.z * other.y,
            y: self.z * other.x - self.x * other.z,
            z: self.x * other.y - self.y * other.x,
        }
    }

    pub fn length_sq(self) -> f32 {
        self.dot(self)
    }

    pub fn length(self) -> f32 {
        self.length_sq().sqrt()
    }

    pub fn distance_to(self, other: Self) -> f32 {
        self.sub(other).length()
    }

    pub fn distance_xz(self, other: Self) -> f32 {
        let dx = self.x - other.x;
        let dz = self.z - other.z;
        (dx * dx + dz * dz).sqrt()
    }

    pub fn normalized_or_zero(self) -> Self {
        let l2 = self.length_sq();
        if l2 > 1e-8 {
            self.scale(l2.sqrt().recip())
        } else {
            Self::ZERO
        }
    }

    pub fn normalized_xz_or_forward(self) -> Self {
        let flat = Self::new(self.x, 0.0, self.z);
        let l2 = flat.length_sq();
        if l2 > 1e-8 {
            flat.scale(l2.sqrt().recip())
        } else {
            Self::new(0.0, 0.0, -1.0)
        }
    }
}

/// Target rim attacked by `team_id` (Team 0 attacks Hoop B `-Z`; Team 1 attacks Hoop A `+Z`).
pub fn target_rim_for_team(team_id: u8) -> Vec3 {
    if team_id == 0 {
        HOOP_B_RIM
    } else {
        HOOP_A_RIM
    }
}

/// Rim defended by `team_id` (Team 0 defends Hoop A `+Z`; Team 1 defends Hoop B `-Z`).
pub fn defended_rim_for_team(team_id: u8) -> Vec3 {
    if team_id == 0 {
        HOOP_A_RIM
    } else {
        HOOP_B_RIM
    }
}

/// Canonical 2pt vs 3pt check from ARCHITECTURE.md Section 3.3.
pub fn is_three_pointer(shot_floor_pos: Vec3, target_rim: Vec3) -> bool {
    let dist_xz = shot_floor_pos.distance_xz(target_rim);
    if dist_xz > THREE_POINT_RADIUS {
        return true;
    }
    // Corner three on the attacking half (same Z sign as target rim)
    let same_half = (shot_floor_pos.z * target_rim.z) >= 0.0;
    same_half && shot_floor_pos.x.abs() > CORNER_THREE_ABS_X
}

pub fn clamp_to_court(pos: Vec3) -> Vec3 {
    Vec3 {
        x: pos.x.clamp(-COURT_HALF_WIDTH, COURT_HALF_WIDTH),
        y: pos.y.max(FLOOR_Y),
        z: pos.z.clamp(-COURT_HALF_LENGTH, COURT_HALF_LENGTH),
    }
}
