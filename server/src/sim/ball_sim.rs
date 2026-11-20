use std::f32::consts::TAU;

use super::{
    is_three_pointer, Vec3, AIR_DRAG_COEFF, BACKBOARD_BOUNCE, BACKBOARD_HALF_WIDTH,
    BACKBOARD_MAX_Y, BACKBOARD_MIN_Y, BALL_GRAVITY, BALL_MASS, BALL_RADIUS, COURT_HALF_LENGTH,
    COURT_HALF_WIDTH, FLOOR_BOUNCE, FLOOR_Y, GATE_WINDOW_SECS, HOOP_A_BACKBOARD_Z, HOOP_A_RIM,
    HOOP_B_BACKBOARD_Z, HOOP_B_RIM, LOWER_GATE_Y, MAGNUS_COEFF, RIM_BOUNCE, RIM_INNER_RADIUS,
    RIM_SEGMENTS, RIM_TUBE_RADIUS, UPPER_GATE_Y,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum BallState {
    Free = 0,
    Held = 1,
    Dribbling = 2,
    PassFlight = 3,
    ShotFlight = 4,
    DunkLocked = 5,
}

impl BallState {
    pub fn as_u8(self) -> u8 {
        self as u8
    }

    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Held,
            2 => Self::Dribbling,
            3 => Self::PassFlight,
            4 => Self::ShotFlight,
            5 => Self::DunkLocked,
            _ => Self::Free,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScoredBasket {
    pub scoring_team: u8,
    pub points: u8,
    pub is_three: bool,
    pub scorer_id: u32,
}

#[derive(Debug, Clone, Copy, Default)]
struct HoopGateState {
    upper_crossed_timer: f32,
    score_cooldown: f32,
}

#[derive(Debug, Clone)]
pub struct BallSim {
    pub state: BallState,
    pub pos: Vec3,
    pub vel: Vec3,
    pub angular_vel: Vec3,

    pub carrier_id: Option<u32>,
    pub carrier_team: Option<u8>,

    pub has_valid_shot_origin: bool,
    pub is_reboundable: bool,
    pub last_shot_pos: Vec3,
    pub last_target_rim: Vec3,
    pub last_shooter_id: Option<u32>,
    pub last_shooter_team: Option<u8>,
    pub last_shot_is_three: bool,
    pub block_resistance: f32,

    pub pass_target_id: Option<u32>,
    pub last_passer_id: Option<u32>,
    pub last_passer_team: Option<u8>,
    pub pickup_lockout_owner: Option<u32>,
    pub pickup_lockout_timer: f32,

    gate_a: HoopGateState, // Hoop A (+Z): Team 1 scores here
    gate_b: HoopGateState, // Hoop B (-Z): Team 0 scores here
}

impl Default for BallSim {
    fn default() -> Self {
        Self::new()
    }
}

impl BallSim {
    pub fn new() -> Self {
        Self {
            state: BallState::Free,
            pos: Vec3::new(0.0, 1.2, 0.0),
            vel: Vec3::ZERO,
            angular_vel: Vec3::ZERO,
            carrier_id: None,
            carrier_team: None,
            has_valid_shot_origin: false,
            is_reboundable: false,
            last_shot_pos: Vec3::ZERO,
            last_target_rim: HOOP_B_RIM,
            last_shooter_id: None,
            last_shooter_team: None,
            last_shot_is_three: false,
            block_resistance: 0.0,
            pass_target_id: None,
            last_passer_id: None,
            last_passer_team: None,
            pickup_lockout_owner: None,
            pickup_lockout_timer: 0.0,
            gate_a: HoopGateState::default(),
            gate_b: HoopGateState::default(),
        }
    }

    pub fn is_controlled(&self) -> bool {
        matches!(
            self.state,
            BallState::Held | BallState::Dribbling | BallState::DunkLocked
        )
    }

    pub fn is_opponent_pass_for_team(&self, team_id: u8) -> bool {
        if self.state != BallState::PassFlight {
            return false;
        }
        matches!(self.last_passer_team, Some(t) if t != team_id)
    }

    pub fn can_be_picked_up_by(&self, player_id: u32) -> bool {
        if self.is_controlled() || self.state == BallState::ShotFlight {
            return false;
        }
        if self.pickup_lockout_timer > 0.0 && self.pickup_lockout_owner == Some(player_id) {
            return false;
        }
        true
    }

    pub fn reset_to_free(&mut self, spawn_pos: Vec3) {
        self.state = BallState::Free;
        self.pos = spawn_pos;
        self.vel = Vec3::ZERO;
        self.angular_vel = Vec3::ZERO;
        self.carrier_id = None;
        self.carrier_team = None;
        self.has_valid_shot_origin = false;
        self.is_reboundable = false;
        self.last_shooter_id = None;
        self.last_shooter_team = None;
        self.last_shot_is_three = false;
        self.block_resistance = 0.0;
        self.pass_target_id = None;
        self.last_passer_id = None;
        self.last_passer_team = None;
        self.pickup_lockout_owner = None;
        self.pickup_lockout_timer = 0.0;
        self.gate_a = HoopGateState::default();
        self.gate_b = HoopGateState::default();
    }

    pub fn set_controlled(&mut self, state: BallState, player_id: u32, team_id: u8, pos: Vec3) {
        self.state = state;
        self.carrier_id = Some(player_id);
        self.carrier_team = Some(team_id);
        self.pos = pos;
        self.vel = Vec3::ZERO;
        self.angular_vel = Vec3::ZERO;
        self.has_valid_shot_origin = false;
        self.is_reboundable = false;
        self.block_resistance = 0.0;
        self.pass_target_id = None;
        self.last_passer_id = None;
        self.last_passer_team = None;
        self.pickup_lockout_owner = None;
        self.pickup_lockout_timer = 0.0;
    }

    #[allow(clippy::too_many_arguments)]
    pub fn launch_shot(
        &mut self,
        shooter_id: u32,
        shooter_team: u8,
        release_pos: Vec3,
        shot_origin_floor: Vec3,
        target_rim: Vec3,
        initial_vel: Vec3,
        spin_vel: Vec3,
        block_resistance: f32,
    ) {
        let is_three = is_three_pointer(shot_origin_floor, target_rim);
        self.state = BallState::ShotFlight;
        self.carrier_id = None;
        self.carrier_team = None;
        self.pos = release_pos;
        self.vel = initial_vel;
        self.angular_vel = spin_vel;
        self.has_valid_shot_origin = true;
        self.is_reboundable = false;
        self.last_shot_pos = shot_origin_floor;
        self.last_target_rim = target_rim;
        self.last_shooter_id = Some(shooter_id);
        self.last_shooter_team = Some(shooter_team);
        self.last_shot_is_three = is_three;
        self.block_resistance = block_resistance.clamp(0.0, 0.75);
        self.pass_target_id = None;
        self.last_passer_id = None;
        self.last_passer_team = None;
        self.pickup_lockout_owner = Some(shooter_id);
        self.pickup_lockout_timer = 0.30;
    }

    pub fn launch_dunk_drop(
        &mut self,
        dunker_id: u32,
        dunker_team: u8,
        rim_center: Vec3,
        slam_speed: f32,
    ) {
        self.state = BallState::ShotFlight;
        self.carrier_id = None;
        self.carrier_team = None;
        self.pos = Vec3::new(rim_center.x, rim_center.y + 0.36, rim_center.z);
        self.vel = Vec3::new(0.0, -slam_speed.abs().max(6.0), 0.0);
        self.angular_vel = Vec3::new(6.0, 0.0, 0.0);
        self.has_valid_shot_origin = true;
        self.is_reboundable = false;
        self.last_shot_pos = Vec3::new(rim_center.x, 0.0, rim_center.z);
        self.last_target_rim = rim_center;
        self.last_shooter_id = Some(dunker_id);
        self.last_shooter_team = Some(dunker_team);
        self.last_shot_is_three = false;
        self.block_resistance = 0.0;
        self.pickup_lockout_owner = Some(dunker_id);
        self.pickup_lockout_timer = 0.32;
    }

    pub fn launch_pass(
        &mut self,
        passer_id: u32,
        passer_team: u8,
        release_pos: Vec3,
        initial_vel: Vec3,
        target_teammate_id: Option<u32>,
    ) {
        self.state = BallState::PassFlight;
        self.carrier_id = None;
        self.carrier_team = None;
        self.pos = release_pos;
        self.vel = initial_vel;
        self.angular_vel = Vec3::new(0.0, 4.0, 0.0);
        self.has_valid_shot_origin = false;
        self.is_reboundable = false;
        self.block_resistance = 0.0;
        self.pass_target_id = target_teammate_id;
        self.last_passer_id = Some(passer_id);
        self.last_passer_team = Some(passer_team);
        self.pickup_lockout_owner = Some(passer_id);
        self.pickup_lockout_timer = 0.26;
    }

    pub fn drop_free(&mut self, release_pos: Vec3, impulse_vel: Vec3, lockout_owner: Option<u32>) {
        self.state = BallState::Free;
        self.carrier_id = None;
        self.carrier_team = None;
        self.pos = release_pos;
        self.vel = impulse_vel;
        self.angular_vel = Vec3::ZERO;
        self.has_valid_shot_origin = false;
        self.is_reboundable = true;
        self.block_resistance = 0.0;
        self.pass_target_id = None;
        self.last_passer_id = None;
        self.last_passer_team = None;
        self.pickup_lockout_owner = lockout_owner;
        self.pickup_lockout_timer = if lockout_owner.is_some() { 0.22 } else { 0.0 };
    }

    /// Computes authentic backspin angular velocity around the horizontal right axis perpendicular to the shot.
    pub fn compute_backspin_omega(release_pos: Vec3, target_point: Vec3, spin_rad_sec: f32) -> Vec3 {
        let dir_xz = Vec3::new(
            target_point.x - release_pos.x,
            0.0,
            target_point.z - release_pos.z,
        )
        .normalized_xz_or_forward();
        let right = dir_xz.cross(Vec3::UP).normalized_or_zero();
        if right.length_sq() > 1e-6 {
            right.scale(spin_rad_sec)
        } else {
            Vec3::new(spin_rad_sec, 0.0, 0.0)
        }
    }

    /// Computes clean ballistic launch velocity from `release_pos` to `target_point` peaking at `apex_y`,
    /// refined over 4 aerodynamic + Magnus forward-step iterations for sub-centimeter hollow-rim precision.
    pub fn solve_ballistic_velocity(release_pos: Vec3, target_point: Vec3, apex_y: f32) -> Vec3 {
        let omega = Self::compute_backspin_omega(release_pos, target_point, 14.0);
        Self::solve_ballistic_velocity_with_spin(release_pos, target_point, apex_y, omega)
    }

    pub fn solve_ballistic_velocity_with_spin(
        release_pos: Vec3,
        target_point: Vec3,
        apex_y: f32,
        spin_omega: Vec3,
    ) -> Vec3 {
        let g = BALL_GRAVITY;
        let peak_y = apex_y.max(release_pos.y + 0.35).max(target_point.y + 0.35);
        let vy = (2.0 * g * (peak_y - release_pos.y)).sqrt();
        let t_up = vy / g;
        let t_down = (2.0 * (peak_y - target_point.y) / g).sqrt();
        let total_t = (t_up + t_down).max(0.20);
        let mut v0 = Vec3::new(
            (target_point.x - release_pos.x) / total_t,
            vy,
            (target_point.z - release_pos.z) / total_t,
        );

        let sub_dt = (1.0 / 60.0) * 0.5;
        for _ in 0..5 {
            let mut p = release_pos;
            let mut v = v0;
            let mut ang = spin_omega;
            let mut max_y = p.y;
            let mut elapsed = 0.0f32;
            let mut hit: Option<(Vec3, f32)> = None;

            for _step in 0..360 {
                let prev_p = p;
                let mut accel = Vec3::new(0.0, -BALL_GRAVITY, 0.0);
                let speed_sq = v.length_sq();
                if speed_sq > 6.25 {
                    let speed = speed_sq.sqrt();
                    accel = accel.add(v.scale(-AIR_DRAG_COEFF * speed / BALL_MASS));
                }
                if ang.length_sq() > 0.01 && speed_sq > 0.25 {
                    accel = accel.add(ang.cross(v).scale(MAGNUS_COEFF / BALL_MASS));
                }
                v = v.add(accel.scale(sub_dt));
                p = p.add(v.scale(sub_dt));
                ang = ang.scale((1.0 - 0.25 * sub_dt).max(0.0));
                elapsed += sub_dt;
                if p.y > max_y {
                    max_y = p.y;
                }
                if v.y < 0.0 && prev_p.y >= target_point.y && p.y <= target_point.y {
                    let frac = ((prev_p.y - target_point.y) / (prev_p.y - p.y).max(1e-5))
                        .clamp(0.0, 1.0);
                    let cross = Vec3::new(
                        prev_p.x + (p.x - prev_p.x) * frac,
                        target_point.y,
                        prev_p.z + (p.z - prev_p.z) * frac,
                    );
                    hit = Some((cross, elapsed));
                    break;
                }
            }

            if let Some((hit_pos, flight_t)) = hit {
                let ft = flight_t.max(0.15);
                v0.x -= (hit_pos.x - target_point.x) / ft;
                v0.z -= (hit_pos.z - target_point.z) / ft;
                v0.y += (peak_y - max_y) * 1.35;
            } else {
                v0.y += 0.45;
            }
        }

        v0
    }

    /// Advances free/in-flight ball physics by `dt` (1/60s) with 2 substeps for accurate rim/gate crossing.
    pub fn step(&mut self, dt: f32) -> Option<ScoredBasket> {
        if self.pickup_lockout_timer > 0.0 {
            self.pickup_lockout_timer = (self.pickup_lockout_timer - dt).max(0.0);
            if self.pickup_lockout_timer <= 0.0 {
                self.pickup_lockout_owner = None;
            }
        }
        self.gate_a.score_cooldown = (self.gate_a.score_cooldown - dt).max(0.0);
        self.gate_b.score_cooldown = (self.gate_b.score_cooldown - dt).max(0.0);
        if self.gate_a.upper_crossed_timer > 0.0 {
            self.gate_a.upper_crossed_timer = (self.gate_a.upper_crossed_timer - dt).max(0.0);
        }
        if self.gate_b.upper_crossed_timer > 0.0 {
            self.gate_b.upper_crossed_timer = (self.gate_b.upper_crossed_timer - dt).max(0.0);
        }

        if self.is_controlled() {
            return None;
        }

        let substeps = 2;
        let sub_dt = dt / (substeps as f32);
        let mut scored: Option<ScoredBasket> = None;

        for _ in 0..substeps {
            let prev_pos = self.pos;

            // Gravity + air drag + Magnus spin
            let mut accel = Vec3::new(0.0, -BALL_GRAVITY, 0.0);
            let speed_sq = self.vel.length_sq();
            if speed_sq > 6.25 {
                let speed = speed_sq.sqrt();
                let drag = self.vel.scale(-AIR_DRAG_COEFF * speed / BALL_MASS);
                accel = accel.add(drag);
            }
            if self.angular_vel.length_sq() > 0.01 && speed_sq > 0.25 {
                let magnus = self
                    .angular_vel
                    .cross(self.vel)
                    .scale(MAGNUS_COEFF / BALL_MASS);
                accel = accel.add(magnus);
            }

            self.vel = self.vel.add(accel.scale(sub_dt));
            self.pos = self.pos.add(self.vel.scale(sub_dt));
            self.angular_vel = self.angular_vel.scale((1.0 - 0.25 * sub_dt).max(0.0));

            // 1. Floor bounce (restitution = 0.78)
            let floor_min_y = FLOOR_Y + BALL_RADIUS;
            if self.pos.y < floor_min_y {
                self.pos.y = floor_min_y;
                if self.vel.y < 0.0 {
                    self.vel.y = -self.vel.y * FLOOR_BOUNCE;
                    self.vel.x *= 0.92;
                    self.vel.z *= 0.92;
                    if self.vel.y.abs() < 0.35 {
                        self.vel.y = 0.0;
                    }
                }
                if matches!(self.state, BallState::ShotFlight | BallState::PassFlight) {
                    self.state = BallState::Free;
                    self.is_reboundable = true;
                }
                self.has_valid_shot_origin = false;
                self.block_resistance = 0.0;
            }

            // 2. Court sideline / baseline containment bounce
            let max_x = COURT_HALF_WIDTH - BALL_RADIUS;
            if self.pos.x > max_x {
                self.pos.x = max_x;
                self.vel.x = -self.vel.x.abs() * 0.65;
            } else if self.pos.x < -max_x {
                self.pos.x = -max_x;
                self.vel.x = self.vel.x.abs() * 0.65;
            }
            let max_z = COURT_HALF_LENGTH - BALL_RADIUS;
            if self.pos.z > max_z {
                self.pos.z = max_z;
                self.vel.z = -self.vel.z.abs() * 0.65;
            } else if self.pos.z < -max_z {
                self.pos.z = -max_z;
                self.vel.z = self.vel.z.abs() * 0.65;
            }

            // 3. Backboards (restitution = 0.65)
            self.collide_backboard(HOOP_A_BACKBOARD_Z, -1.0);
            self.collide_backboard(HOOP_B_BACKBOARD_Z, 1.0);

            // 4. Hollow 12-segment rims (restitution = 0.58)
            self.collide_hollow_rim(HOOP_A_RIM);
            self.collide_hollow_rim(HOOP_B_RIM);

            // 5. Scoring sensors (UpperGate 3.08m -> LowerGate 2.86m downward within 0.60s)
            if scored.is_none() {
                if let Some(b) = self.check_hoop_gates(prev_pos, HOOP_A_RIM, 1, true) {
                    scored = Some(b);
                } else if let Some(b) = self.check_hoop_gates(prev_pos, HOOP_B_RIM, 0, false) {
                    scored = Some(b);
                }
            }
        }

        scored
    }

    fn collide_backboard(&mut self, board_z: f32, front_normal_z: f32) {
        if self.pos.x.abs() > BACKBOARD_HALF_WIDTH + BALL_RADIUS {
            return;
        }
        if self.pos.y < BACKBOARD_MIN_Y - BALL_RADIUS || self.pos.y > BACKBOARD_MAX_Y + BALL_RADIUS
        {
            return;
        }
        let dz = self.pos.z - board_z;
        // Collide on front face of backboard
        if dz.abs() < BALL_RADIUS && (self.vel.z * front_normal_z) < 0.0 {
            self.pos.z = board_z + front_normal_z * BALL_RADIUS;
            self.vel.z = -self.vel.z * BACKBOARD_BOUNCE;
            self.vel.x *= 0.90;
            self.vel.y *= 0.92;
            if self.state == BallState::ShotFlight {
                self.state = BallState::Free;
                self.is_reboundable = true;
                self.pickup_lockout_timer = 0.0;
                self.pickup_lockout_owner = None;
            }
            self.block_resistance = 0.0;
        }
    }

    fn collide_hollow_rim(&mut self, rim_center: Vec3) {
        // Broadphase bounding sphere around the hollow ring
        if self.pos.distance_to(rim_center) > (RIM_INNER_RADIUS + RIM_TUBE_RADIUS + BALL_RADIUS + 0.1)
        {
            return;
        }

        let ring_center_radius = RIM_INNER_RADIUS + RIM_TUBE_RADIUS;
        let combined_r = BALL_RADIUS + RIM_TUBE_RADIUS;
        let combined_r_sq = combined_r * combined_r;

        // 12 discrete hollow segments around the rim ring (NEVER a solid cylinder!)
        for i in 0..RIM_SEGMENTS {
            let angle = (i as f32) * (TAU / RIM_SEGMENTS as f32);
            let seg_pos = Vec3::new(
                rim_center.x + ring_center_radius * angle.cos(),
                rim_center.y,
                rim_center.z + ring_center_radius * angle.sin(),
            );
            let diff = self.pos.sub(seg_pos);
            let dist_sq = diff.length_sq();
            if dist_sq < combined_r_sq && dist_sq > 1e-8 {
                let dist = dist_sq.sqrt();
                let normal = diff.scale(1.0 / dist);
                self.pos = seg_pos.add(normal.scale(combined_r));
                let vn = self.vel.dot(normal);
                if vn < 0.0 {
                    let bounce = normal.scale(-(1.0 + RIM_BOUNCE) * vn);
                    self.vel = self.vel.add(bounce);
                    if self.state == BallState::ShotFlight {
                        self.state = BallState::Free;
                        self.is_reboundable = true;
                        self.pickup_lockout_timer = 0.0;
                        self.pickup_lockout_owner = None;
                    }
                    self.block_resistance = 0.0;
                }
            }
        }
    }

    fn check_hoop_gates(
        &mut self,
        prev_pos: Vec3,
        rim: Vec3,
        scoring_team: u8,
        is_hoop_a: bool,
    ) -> Option<ScoredBasket> {
        let gate = if is_hoop_a {
            &mut self.gate_a
        } else {
            &mut self.gate_b
        };

        if gate.score_cooldown > 0.0 {
            return None;
        }

        // Only downward motion counts!
        if self.vel.y >= 0.0 {
            return None;
        }

        let gate_radius = RIM_INNER_RADIUS + 0.04;

        // Check UpperGate crossing (y = 3.08m downward)
        if prev_pos.y >= UPPER_GATE_Y && self.pos.y < UPPER_GATE_Y {
            let t = ((prev_pos.y - UPPER_GATE_Y) / (prev_pos.y - self.pos.y).max(1e-5))
                .clamp(0.0, 1.0);
            let cross_x = prev_pos.x + (self.pos.x - prev_pos.x) * t;
            let cross_z = prev_pos.z + (self.pos.z - prev_pos.z) * t;
            let dist_xz = ((cross_x - rim.x).powi(2) + (cross_z - rim.z).powi(2)).sqrt();
            if dist_xz <= gate_radius {
                gate.upper_crossed_timer = GATE_WINDOW_SECS;
            }
        }

        // Check LowerGate crossing (y = 2.86m downward) while upper gate window is active
        if gate.upper_crossed_timer > 0.0 && prev_pos.y >= LOWER_GATE_Y && self.pos.y < LOWER_GATE_Y
        {
            let t = ((prev_pos.y - LOWER_GATE_Y) / (prev_pos.y - self.pos.y).max(1e-5))
                .clamp(0.0, 1.0);
            let cross_x = prev_pos.x + (self.pos.x - prev_pos.x) * t;
            let cross_z = prev_pos.z + (self.pos.z - prev_pos.z) * t;
            let dist_xz = ((cross_x - rim.x).powi(2) + (cross_z - rim.z).powi(2)).sqrt();
            if dist_xz <= gate_radius {
                gate.upper_crossed_timer = 0.0;
                gate.score_cooldown = 1.0;

                // Evaluate 2pt vs 3pt strictly from server-recorded shot_origin_floor
                let is_three = self.has_valid_shot_origin && is_three_pointer(self.last_shot_pos, rim);
                let points = if is_three { 3 } else { 2 };
                let scorer_id = self.last_shooter_id.unwrap_or(0);
                self.has_valid_shot_origin = false;
                return Some(ScoredBasket {
                    scoring_team,
                    points,
                    is_three,
                    scorer_id,
                });
            }
        }

        None
    }
}
