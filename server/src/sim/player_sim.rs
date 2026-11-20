use crate::protocol::{
    quantize_meter, quantize_pos_vel, quantize_yaw, QuantizedPlayerState, BUFF_DEFENSE_COUNTER,
    BUFF_SHOT_BONUS, CD_BLOCK, CD_DRIBBLE_NORMAL, CD_STEAL, STATE_ANKLE_BROKEN, STATE_ARMORED,
    STATE_BLOCK_RECOVERY, STATE_CHARGING_SHOT, STATE_DEFENSIVE_STANCE, STATE_DISCONNECTED_GRACE,
    STATE_DRIBBLE_HAND_RIGHT, STATE_DUNKING, STATE_GROUNDED, STATE_PHANTOM_PHASING,
    STATE_SPRINTING, STATE_STEAL_ACTIVE, STATE_STEAL_SHIELDED, STATE_STEAL_STARTUP,
    STATE_STEAL_WHIFF_RECOVERY, STATE_ZONE_ACTIVE,
};

use super::combo_validator::{ComboValidator, MoveId};
use super::{
    Vec2, Vec3, FLOOR_Y, ZONE_BLOCK_REACH_MULT, ZONE_DURATION_SECS, ZONE_JUMP_MULT,
    ZONE_MAX_ENERGY, ZONE_SPEED_MULT, ZONE_STAMINA_COST_MULT,
};

pub const EXHAUSTED_THRESHOLD: f32 = 20.0;
pub const SPRINT_DRAIN_PER_SEC: f32 = 15.0;
pub const STAMINA_REGEN_DELAY: f32 = 0.50;
pub const COST_DRIBBLE_MOVE: f32 = 9.0;
pub const COST_JUMP: f32 = 7.0;
pub const COST_STEAL: f32 = 7.0;
pub const COST_BLOCK: f32 = 9.0;
pub const COST_DUNK: f32 = 18.0;

pub const STEAL_STARTUP_FRAMES: u16 = 6;
pub const STEAL_ACTIVE_FRAMES: u16 = 5;
pub const STEAL_WHIFF_RECOVERY_FRAMES: u16 = 24;
pub const STEAL_WHIFF_SPEED_MULT: f32 = 0.45;
pub const BLOCK_LANDING_RECOVERY_FRAMES: u16 = 18;
pub const BLOCK_RECOVERY_SPEED_MULT: f32 = 0.55;
pub const ANKLE_BREAK_FRAMES: u16 = 66;
pub const LANDING_RECOVERY_TICKS: u16 = 8;

pub const OPTIMAL_JUMP_CHARGE_SEC: f32 = 0.26;
pub const AUTO_JUMP_RELEASE_SEC: f32 = 0.48;
pub const OPTIMAL_LAYUP_CHARGE_SEC: f32 = 0.18;
pub const AUTO_LAYUP_RELEASE_SEC: f32 = 0.25;
pub const LAYUP_RANGE_XZ: f32 = 3.40;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum ArchetypeId {
    Speedster = 0,
    Sharpshooter = 1,
    Playmaker = 2,
    Powerhouse = 3,
    AllRounder = 4,
}

impl ArchetypeId {
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::Speedster,
            1 => Self::Sharpshooter,
            2 => Self::Playmaker,
            3 => Self::Powerhouse,
            _ => Self::AllRounder,
        }
    }

    pub fn as_u8(self) -> u8 {
        self as u8
    }

    pub fn from_name(name: &str) -> Self {
        match name.trim().to_ascii_lowercase().as_str() {
            "speedster" | "phantom_pg" | "volt" | "pg" => Self::Speedster,
            "sharpshooter" | "deadeye" | "sg" => Self::Sharpshooter,
            "playmaker" | "mirage" | "sf" => Self::Playmaker,
            "powerhouse" | "titan" | "pf" | "c" | "rim_titan" => Self::Powerhouse,
            _ => Self::AllRounder,
        }
    }

    pub fn profile(self) -> ArchetypeProfile {
        match self {
            Self::Speedster => ArchetypeProfile {
                id: self,
                run_speed: 6.9,
                sprint_speed: 9.8,
                acceleration: 46.0,
                jump_velocity: 6.8,
                max_stamina: 85.0,
                stamina_regen: 26.0,
                dribble_stamina_mult: 0.80,
                three_point_range: 7.4,
                perfect_window_bonus: 0.0,
                shot_arc_bonus: 0.0,
                dunk_radius: 2.75,
                pass_speed_mult: 1.05,
                cancel_window_bonus: 2,
                ankle_break_mult: 1.10,
                block_radius: 1.40,
                steal_radius: 1.90,
                balance_resistance: 0.80,
                zone_gain_mult: 1.05,
            },
            Self::Sharpshooter => ArchetypeProfile {
                id: self,
                run_speed: 5.9,
                sprint_speed: 8.2,
                acceleration: 34.0,
                jump_velocity: 6.7,
                max_stamina: 95.0,
                stamina_regen: 21.0,
                dribble_stamina_mult: 1.05,
                three_point_range: 9.8,
                perfect_window_bonus: 0.35,
                shot_arc_bonus: 0.55,
                dunk_radius: 2.35,
                pass_speed_mult: 1.00,
                cancel_window_bonus: 0,
                ankle_break_mult: 0.90,
                block_radius: 1.55,
                steal_radius: 1.55,
                balance_resistance: 0.90,
                zone_gain_mult: 1.05,
            },
            Self::Playmaker => ArchetypeProfile {
                id: self,
                run_speed: 6.4,
                sprint_speed: 9.0,
                acceleration: 41.0,
                jump_velocity: 6.75,
                max_stamina: 100.0,
                stamina_regen: 22.0,
                dribble_stamina_mult: 0.90,
                three_point_range: 7.8,
                perfect_window_bonus: 0.10,
                shot_arc_bonus: 0.10,
                dunk_radius: 2.65,
                pass_speed_mult: 1.35,
                cancel_window_bonus: 4,
                ankle_break_mult: 1.25,
                block_radius: 1.55,
                steal_radius: 1.85,
                balance_resistance: 0.95,
                zone_gain_mult: 1.25,
            },
            Self::Powerhouse => ArchetypeProfile {
                id: self,
                run_speed: 5.8,
                sprint_speed: 8.3,
                acceleration: 33.0,
                jump_velocity: 7.35,
                max_stamina: 115.0,
                stamina_regen: 18.0,
                dribble_stamina_mult: 1.30,
                three_point_range: 6.8,
                perfect_window_bonus: -0.05,
                shot_arc_bonus: 0.0,
                dunk_radius: 4.20,
                pass_speed_mult: 0.95,
                cancel_window_bonus: 0,
                ankle_break_mult: 0.85,
                block_radius: 2.15,
                steal_radius: 1.50,
                balance_resistance: 2.00,
                zone_gain_mult: 1.00,
            },
            Self::AllRounder => ArchetypeProfile {
                id: self,
                run_speed: 6.4,
                sprint_speed: 9.0,
                acceleration: 40.0,
                jump_velocity: 7.0,
                max_stamina: 105.0,
                stamina_regen: 22.0,
                dribble_stamina_mult: 0.95,
                three_point_range: 8.0,
                perfect_window_bonus: 0.12,
                shot_arc_bonus: 0.18,
                dunk_radius: 3.20,
                pass_speed_mult: 1.10,
                cancel_window_bonus: 2,
                ankle_break_mult: 1.05,
                block_radius: 1.80,
                steal_radius: 1.85,
                balance_resistance: 1.20,
                zone_gain_mult: 1.10,
            },
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ArchetypeProfile {
    pub id: ArchetypeId,
    pub run_speed: f32,
    pub sprint_speed: f32,
    pub acceleration: f32,
    pub jump_velocity: f32,
    pub max_stamina: f32,
    pub stamina_regen: f32,
    pub dribble_stamina_mult: f32,
    pub three_point_range: f32,
    pub perfect_window_bonus: f32,
    pub shot_arc_bonus: f32,
    pub dunk_radius: f32,
    pub pass_speed_mult: f32,
    pub cancel_window_bonus: u8,
    pub ankle_break_mult: f32,
    pub block_radius: f32,
    pub steal_radius: f32,
    pub balance_resistance: f32,
    pub zone_gain_mult: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StealPhase {
    Idle,
    Startup,
    Active,
    WhiffRecovery,
}

#[derive(Debug, Clone)]
pub struct PlayerSim {
    pub player_id: u32,
    pub team_id: u8,
    pub slot: u8,
    pub username: String,
    pub profile: ArchetypeProfile,

    pub pos: Vec3,
    pub vel: Vec3,
    pub facing_yaw: f32,
    pub aim_yaw: f32,
    pub grounded: bool,

    pub stamina: f32,
    pub stamina_regen_cd: f32,
    pub stamina_depleted_lock: bool,

    pub zone_energy: f32,
    pub zone_active: bool,
    pub zone_time_left: f32,

    pub balance: f32,
    pub ankle_break_frames: u16,
    pub strip_flinch_timer: f32,
    pub phantom_phase_timer: f32,
    pub landing_frames_left: u16,

    pub is_sprinting: bool,
    pub in_defensive_stance: bool,
    pub dribble_hand_right: bool,
    pub steal_shield_timer: f32,
    pub dribble_cooldown_timer: f32,
    pub shot_bonus: f32,
    pub shot_bonus_timer: f32,

    // Defense state
    pub steal_phase: StealPhase,
    pub steal_phase_frames: u16,
    pub steal_cooldown: f32,
    pub block_cooldown: f32,
    pub block_recovery_frames: u16,
    pub block_jump_committed: bool,
    pub jump_succeeded_defensively: bool,
    pub defense_buff_timer: f32,
    pub steal_radius_bonus: f32,
    pub contest_bonus: f32,

    // Active combo burst & dunk flight state
    pub burst_vel: Vec3,
    pub burst_timer: f32,
    pub is_charging_shot: bool,
    pub is_layup_gather: bool,
    pub shot_charge_time: f32,
    pub shot_origin_floor: Vec3,

    pub is_dunking: bool,
    pub is_armored_dunk: bool,
    pub dunk_elapsed: f32,
    pub dunk_duration: f32,
    pub dunk_start_pos: Vec3,
    pub dunk_end_pos: Vec3,
    pub dunk_apex_lift: f32,
    pub dunk_target_rim: Vec3,
    pub dunk_shockwave_radius: f32,
    pub dunk_balance_damage: f32,

    // Combo engine & networking metadata
    pub combo_validator: ComboValidator,
    pub prev_buttons: u16,
    pub last_processed_input_seq: u32,
    pub disconnected_grace: bool,
    pub is_bot: bool,
    pub perceived_latency_ms: f32,
}

impl PlayerSim {
    pub fn new(
        player_id: u32,
        team_id: u8,
        slot: u8,
        username: String,
        archetype: ArchetypeId,
        spawn_pos: Vec3,
    ) -> Self {
        let profile = archetype.profile();
        let facing_yaw = if team_id == 0 { 0.0 } else { std::f32::consts::PI };
        Self {
            player_id,
            team_id,
            slot,
            username,
            stamina: profile.max_stamina,
            profile,
            pos: spawn_pos,
            vel: Vec3::ZERO,
            facing_yaw,
            aim_yaw: facing_yaw,
            grounded: spawn_pos.y <= FLOOR_Y + 0.02,
            stamina_regen_cd: 0.0,
            stamina_depleted_lock: false,
            zone_energy: 0.0,
            zone_active: false,
            zone_time_left: 0.0,
            balance: 100.0,
            ankle_break_frames: 0,
            strip_flinch_timer: 0.0,
            phantom_phase_timer: 0.0,
            landing_frames_left: 0,
            is_sprinting: false,
            in_defensive_stance: false,
            dribble_hand_right: true,
            steal_shield_timer: 0.0,
            dribble_cooldown_timer: 0.0,
            shot_bonus: 0.0,
            shot_bonus_timer: 0.0,
            steal_phase: StealPhase::Idle,
            steal_phase_frames: 0,
            steal_cooldown: 0.0,
            block_cooldown: 0.0,
            block_recovery_frames: 0,
            block_jump_committed: false,
            jump_succeeded_defensively: false,
            defense_buff_timer: 0.0,
            steal_radius_bonus: 0.0,
            contest_bonus: 0.0,
            burst_vel: Vec3::ZERO,
            burst_timer: 0.0,
            is_charging_shot: false,
            is_layup_gather: false,
            shot_charge_time: 0.0,
            shot_origin_floor: Vec3::ZERO,
            is_dunking: false,
            is_armored_dunk: false,
            dunk_elapsed: 0.0,
            dunk_duration: 0.28,
            dunk_start_pos: Vec3::ZERO,
            dunk_end_pos: Vec3::ZERO,
            dunk_apex_lift: 0.55,
            dunk_target_rim: Vec3::ZERO,
            dunk_shockwave_radius: 0.0,
            dunk_balance_damage: 0.0,
            combo_validator: ComboValidator::new(),
            prev_buttons: 0,
            last_processed_input_seq: 0,
            disconnected_grace: false,
            is_bot: false,
            perceived_latency_ms: 0.0,
        }
    }

    /// Resets per-match runtime state for a clean rematch while preserving identity, team, slot, archetype & bot flag.
    pub fn reset_for_rematch(&mut self, spawn_pos: Vec3) {
        let facing_yaw = if self.team_id == 0 {
            0.0
        } else {
            std::f32::consts::PI
        };
        self.pos = spawn_pos;
        self.vel = Vec3::ZERO;
        self.facing_yaw = facing_yaw;
        self.aim_yaw = facing_yaw;
        self.grounded = true;
        self.stamina = self.profile.max_stamina;
        self.stamina_regen_cd = 0.0;
        self.stamina_depleted_lock = false;
        self.zone_energy = 0.0;
        self.zone_active = false;
        self.zone_time_left = 0.0;
        self.balance = 100.0;
        self.ankle_break_frames = 0;
        self.strip_flinch_timer = 0.0;
        self.phantom_phase_timer = 0.0;
        self.landing_frames_left = 0;
        self.is_sprinting = false;
        self.in_defensive_stance = false;
        self.dribble_hand_right = true;
        self.steal_shield_timer = 0.0;
        self.dribble_cooldown_timer = 0.0;
        self.shot_bonus = 0.0;
        self.shot_bonus_timer = 0.0;
        self.steal_phase = StealPhase::Idle;
        self.steal_phase_frames = 0;
        self.steal_cooldown = 0.0;
        self.block_cooldown = 0.0;
        self.block_recovery_frames = 0;
        self.block_jump_committed = false;
        self.jump_succeeded_defensively = false;
        self.defense_buff_timer = 0.0;
        self.steal_radius_bonus = 0.0;
        self.contest_bonus = 0.0;
        self.burst_vel = Vec3::ZERO;
        self.burst_timer = 0.0;
        self.is_charging_shot = false;
        self.is_layup_gather = false;
        self.shot_charge_time = 0.0;
        self.is_dunking = false;
        self.is_armored_dunk = false;
        self.dunk_elapsed = 0.0;
        self.combo_validator.reset();
        self.prev_buttons = 0;
    }

    pub fn is_stunned(&self) -> bool {
        self.ankle_break_frames > 0 || self.strip_flinch_timer > 0.0
    }

    pub fn is_exhausted(&self) -> bool {
        self.stamina < EXHAUSTED_THRESHOLD
    }

    pub fn can_sprint(&self) -> bool {
        !self.stamina_depleted_lock && self.stamina > 1.0
    }

    pub fn stamina_cost_mult(&self) -> f32 {
        if self.zone_active {
            ZONE_STAMINA_COST_MULT
        } else {
            1.0
        }
    }

    pub fn zone_speed_mult(&self) -> f32 {
        if self.zone_active {
            ZONE_SPEED_MULT
        } else {
            1.0
        }
    }

    pub fn effective_jump_velocity(&self) -> f32 {
        self.profile.jump_velocity * if self.zone_active { ZONE_JUMP_MULT } else { 1.0 }
    }

    pub fn effective_block_radius(&self) -> f32 {
        self.profile.block_radius
            * if self.zone_active {
                ZONE_BLOCK_REACH_MULT
            } else {
                1.0
            }
    }

    pub fn effective_steal_radius(&self) -> f32 {
        self.profile.steal_radius
            + if self.defense_buff_timer > 0.0 {
                self.steal_radius_bonus
            } else {
                0.0
            }
    }

    pub fn effective_balance_resistance(&self) -> f32 {
        let stance_mult = if self.in_defensive_stance { 1.40 } else { 1.0 };
        (self.profile.balance_resistance * stance_mult).max(0.2)
    }

    pub fn is_in_steal_whiff_recovery(&self) -> bool {
        self.steal_phase == StealPhase::WhiffRecovery && self.steal_phase_frames > 0
    }

    pub fn is_in_defense_recovery(&self) -> bool {
        self.is_in_steal_whiff_recovery() || self.block_recovery_frames > 0
    }

    pub fn defense_speed_mult(&self) -> f32 {
        if self.is_in_steal_whiff_recovery() {
            STEAL_WHIFF_SPEED_MULT
        } else if self.block_recovery_frames > 0 {
            BLOCK_RECOVERY_SPEED_MULT
        } else {
            1.0
        }
    }

    pub fn has_steal_protection(&self) -> bool {
        self.steal_shield_timer > 0.0 || self.is_armored_dunk || self.phantom_phase_timer > 0.0
    }

    pub fn consume_stamina(&mut self, base_cost: f32, allow_partial: bool, already_discounted: bool) -> bool {
        if base_cost <= 0.0 {
            return true;
        }
        let eff = if already_discounted {
            base_cost
        } else {
            base_cost * self.stamina_cost_mult()
        };
        if self.stamina + 1e-4 < eff && !allow_partial {
            return false;
        }
        self.stamina = (self.stamina - eff).max(0.0);
        self.stamina_regen_cd = STAMINA_REGEN_DELAY;
        if self.stamina <= 0.5 {
            self.stamina_depleted_lock = true;
        }
        true
    }

    pub fn step_stamina(&mut self, dt: f32, sprinting_now: bool) {
        if sprinting_now && self.can_sprint() {
            let drain = SPRINT_DRAIN_PER_SEC * self.stamina_cost_mult() * dt;
            self.stamina = (self.stamina - drain).max(0.0);
            self.stamina_regen_cd = STAMINA_REGEN_DELAY;
            if self.stamina <= 0.5 {
                self.stamina_depleted_lock = true;
            }
        } else if self.stamina_regen_cd > 0.0 {
            self.stamina_regen_cd = (self.stamina_regen_cd - dt).max(0.0);
        } else {
            self.stamina = (self.stamina + self.profile.stamina_regen * dt).min(self.profile.max_stamina);
            if self.stamina_depleted_lock && self.stamina >= 12.0 {
                self.stamina_depleted_lock = false;
            }
        }
    }

    /// Accrues Zone meter ONLY when NOT currently in Zone (strictly 0 gain while active!).
    pub fn add_zone_charge(&mut self, base_amount: f32) -> f32 {
        if self.zone_active || base_amount <= 0.0 {
            return 0.0;
        }
        let prev = self.zone_energy;
        self.zone_energy = (self.zone_energy + base_amount * self.profile.zone_gain_mult)
            .clamp(0.0, ZONE_MAX_ENERGY);
        self.zone_energy - prev
    }

    pub fn try_activate_zone(&mut self) -> bool {
        if self.zone_active || self.zone_energy < ZONE_MAX_ENERGY - 0.001 {
            return false;
        }
        self.zone_active = true;
        self.zone_time_left = ZONE_DURATION_SECS;
        self.zone_energy = ZONE_MAX_ENERGY;
        true
    }

    /// Steps Zone timer at 60 Hz; returns `true` on the exact tick Zone expires and baseline restores.
    pub fn step_zone(&mut self, dt: f32) -> bool {
        if !self.zone_active {
            return false;
        }
        let drain_rate = ZONE_MAX_ENERGY / ZONE_DURATION_SECS;
        self.zone_time_left = (self.zone_time_left - dt).max(0.0);
        self.zone_energy = (self.zone_energy - drain_rate * dt).max(0.0);
        if self.zone_time_left <= 0.0 || self.zone_energy <= 0.0001 {
            self.zone_active = false;
            self.zone_time_left = 0.0;
            self.zone_energy = 0.0;
            return true;
        }
        false
    }

    pub fn apply_balance_damage(&mut self, raw_damage: f32) -> bool {
        if self.is_armored_dunk || self.ankle_break_frames > 0 || raw_damage <= 0.0 {
            return false;
        }
        let eff = raw_damage / self.effective_balance_resistance();
        self.balance = (self.balance - eff).max(0.0);
        if self.balance <= 0.001 {
            self.ankle_break_frames = ANKLE_BREAK_FRAMES;
            self.in_defensive_stance = false;
            self.block_jump_committed = false;
            if matches!(self.steal_phase, StealPhase::Startup | StealPhase::Active) {
                self.steal_phase = StealPhase::Idle;
                self.steal_phase_frames = 0;
            }
            return true;
        }
        false
    }

    pub fn step_steal_phase_pre_move(&mut self) {
        if self.block_recovery_frames > 0 {
            self.block_recovery_frames -= 1;
        }
        match self.steal_phase {
            StealPhase::Idle => {}
            StealPhase::Startup => {
                if self.steal_phase_frames > 1 {
                    self.steal_phase_frames -= 1;
                } else {
                    self.steal_phase = StealPhase::Active;
                    self.steal_phase_frames = STEAL_ACTIVE_FRAMES;
                }
            }
            StealPhase::Active => {
                if self.steal_phase_frames > 1 {
                    self.steal_phase_frames -= 1;
                } else {
                    self.steal_phase = StealPhase::WhiffRecovery;
                    self.steal_phase_frames = STEAL_WHIFF_RECOVERY_FRAMES;
                    self.in_defensive_stance = false;
                }
            }
            StealPhase::WhiffRecovery => {
                if self.steal_phase_frames > 1 {
                    self.steal_phase_frames -= 1;
                } else {
                    self.steal_phase = StealPhase::Idle;
                    self.steal_phase_frames = 0;
                }
            }
        }
    }

    pub fn forward_xz(&self) -> Vec2 {
        Vec2::new(-self.facing_yaw.sin(), -self.facing_yaw.cos()).normalized_or_zero()
    }

    pub fn active_hand_world_pos(&self) -> Vec3 {
        let fwd = self.forward_xz();
        let right = Vec2::new(-fwd.y, fwd.x);
        let side = if self.dribble_hand_right { 0.34 } else { -0.34 };
        Vec3::new(
            self.pos.x + fwd.x * 0.42 + right.x * side,
            self.pos.y + 0.95,
            self.pos.z + fwd.y * 0.42 + right.y * side,
        )
    }

    pub fn to_quantized_state(&self) -> QuantizedPlayerState {
        let mut state_flags = 0u16;
        if self.grounded {
            state_flags |= STATE_GROUNDED;
        }
        if self.is_sprinting {
            state_flags |= STATE_SPRINTING;
        }
        if self.in_defensive_stance {
            state_flags |= STATE_DEFENSIVE_STANCE;
        }
        if self.zone_active {
            state_flags |= STATE_ZONE_ACTIVE;
        }
        if self.ankle_break_frames > 0 {
            state_flags |= STATE_ANKLE_BROKEN;
        }
        if self.is_charging_shot {
            state_flags |= STATE_CHARGING_SHOT;
        }
        if self.is_dunking {
            state_flags |= STATE_DUNKING;
        }
        match self.steal_phase {
            StealPhase::Startup => state_flags |= STATE_STEAL_STARTUP,
            StealPhase::Active => state_flags |= STATE_STEAL_ACTIVE,
            StealPhase::WhiffRecovery => state_flags |= STATE_STEAL_WHIFF_RECOVERY,
            StealPhase::Idle => {}
        }
        if self.block_recovery_frames > 0 {
            state_flags |= STATE_BLOCK_RECOVERY;
        }
        if self.phantom_phase_timer > 0.0 {
            state_flags |= STATE_PHANTOM_PHASING;
        }
        if self.steal_shield_timer > 0.0 {
            state_flags |= STATE_STEAL_SHIELDED;
        }
        if self.is_armored_dunk {
            state_flags |= STATE_ARMORED;
        }
        if self.disconnected_grace {
            state_flags |= STATE_DISCONNECTED_GRACE;
        }
        if self.dribble_hand_right {
            state_flags |= STATE_DRIBBLE_HAND_RIGHT;
        }

        let mut cooldown_flags = self.combo_validator.cooldown_flags(self.profile.id);
        if self.steal_cooldown > 0.0 {
            cooldown_flags |= CD_STEAL;
        }
        if self.block_cooldown > 0.0 {
            cooldown_flags |= CD_BLOCK;
        }
        if self.dribble_cooldown_timer > 0.0 {
            cooldown_flags |= CD_DRIBBLE_NORMAL;
        }
        if self.defense_buff_timer > 0.0 {
            cooldown_flags |= BUFF_DEFENSE_COUNTER;
        }
        if self.shot_bonus_timer > 0.0 {
            cooldown_flags |= BUFF_SHOT_BONUS;
        }

        let active_move = if self.combo_validator.active_move() != MoveId::None {
            self.combo_validator.active_move().as_u8()
        } else {
            0
        };

        QuantizedPlayerState {
            player_id: self.player_id as u16,
            last_processed_input_seq: self.last_processed_input_seq,
            pos_x: quantize_pos_vel(self.pos.x),
            pos_y: quantize_pos_vel(self.pos.y),
            pos_z: quantize_pos_vel(self.pos.z),
            vel_x: quantize_pos_vel(self.vel.x),
            vel_y: quantize_pos_vel(self.vel.y),
            vel_z: quantize_pos_vel(self.vel.z),
            yaw: quantize_yaw(self.facing_yaw),
            stamina_u8: quantize_meter(self.stamina),
            zone_u8: quantize_meter(self.zone_energy),
            balance_u8: quantize_meter(self.balance),
            team_id: self.team_id,
            slot: self.slot,
            archetype_id: self.profile.id.as_u8(),
            state_flags,
            cooldown_flags,
            active_move_id: active_move,
        }
    }
}
