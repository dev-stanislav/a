use crate::protocol::{
    quantize_pos_vel, MatchEventPayload, PlayerInputFrameWire, ServerWorldSnapshotMsg, BTN_JUMP,
    BTN_PASS, BTN_SHOOT, BTN_SKILL_E, BTN_SKILL_Q, BTN_SPRINT, BTN_STANCE, BTN_STEAL, BTN_ZONE,
    MAX_PLAYERS,
};

use super::ball_sim::{BallSim, BallState};
use super::combo_validator::{ComboTriggerResult, MoveId};
use super::lag_comp::{LagCompHistory, PlayerPose, WorldPoseSnapshot};
use super::player_sim::{
    ArchetypeId, PlayerSim, StealPhase, AUTO_JUMP_RELEASE_SEC, AUTO_LAYUP_RELEASE_SEC,
    BLOCK_LANDING_RECOVERY_FRAMES, COST_BLOCK, COST_DRIBBLE_MOVE, COST_DUNK, COST_JUMP, COST_STEAL,
    LANDING_RECOVERY_TICKS, LAYUP_RANGE_XZ, OPTIMAL_JUMP_CHARGE_SEC, OPTIMAL_LAYUP_CHARGE_SEC,
    STEAL_STARTUP_FRAMES,
};
use super::{
    clamp_to_court, defended_rim_for_team, target_rim_for_team, Vec2, Vec3, FIXED_DT, FLOOR_Y,
    PLAYER_GRAVITY, STANCE_SPEED, ZONE_DURATION_SECS,
};

const SPAWN_POSITIONS: [Vec3; 6] = [
    Vec3::new(0.0, 0.0, 4.0),   // Slot 0: Team 0 PG
    Vec3::new(0.0, 0.0, -4.0),  // Slot 1: Team 1 PG
    Vec3::new(-3.2, 0.0, 5.5),  // Slot 2: Team 0 Wing
    Vec3::new(3.2, 0.0, -5.5),  // Slot 3: Team 1 Wing
    Vec3::new(3.2, 0.0, 5.5),   // Slot 4: Team 0 Big
    Vec3::new(-3.2, 0.0, -5.5), // Slot 5: Team 1 Big
];

#[derive(Debug, Clone)]
pub struct SimWorld {
    pub server_tick: u64,
    pub match_duration_secs: f32,
    pub match_clock_secs: f32,
    pub shot_clock_secs: f32,
    pub shot_clock_duration: f32,
    pub scores: [u16; 2],
    pub possession_team: u8, // 0, 1, or 255 = none
    pub match_ended: bool,

    pub players: Vec<PlayerSim>,
    pub ball: BallSim,
    pub lag_comp: LagCompHistory,

    pending_events: Vec<MatchEventPayload>,
    next_player_id: u32,
    bot_input_seq: u32,
}

impl Default for SimWorld {
    fn default() -> Self {
        Self::new(180.0, 24.0)
    }
}

impl SimWorld {
    pub fn new(match_duration_secs: f32, shot_clock_secs: f32) -> Self {
        let dur = match_duration_secs.max(10.0);
        let sc = shot_clock_secs.max(5.0);
        Self {
            server_tick: 0,
            match_duration_secs: dur,
            match_clock_secs: dur,
            shot_clock_secs: sc,
            shot_clock_duration: sc,
            scores: [0, 0],
            possession_team: 255,
            match_ended: false,
            players: Vec::with_capacity(MAX_PLAYERS),
            ball: BallSim::new(),
            lag_comp: LagCompHistory::new(),
            pending_events: Vec::new(),
            next_player_id: 1,
            bot_input_seq: 0,
        }
    }

    pub fn drain_events(&mut self) -> Vec<MatchEventPayload> {
        std::mem::take(&mut self.pending_events)
    }

    pub fn push_event(&mut self, ev: MatchEventPayload) {
        self.pending_events.push(ev);
    }

    pub fn get_player(&self, player_id: u32) -> Option<&PlayerSim> {
        self.players.iter().find(|p| p.player_id == player_id)
    }

    pub fn get_player_mut(&mut self, player_id: u32) -> Option<&mut PlayerSim> {
        self.players.iter_mut().find(|p| p.player_id == player_id)
    }

    /// Spawns a new authoritative player into an open slot (`0..6`).
    pub fn add_player(
        &mut self,
        username: String,
        archetype: ArchetypeId,
        preferred_team: u8,
    ) -> Option<(u32, u8, u8)> {
        if self.players.len() >= MAX_PLAYERS {
            return None;
        }

        let team0_count = self.players.iter().filter(|p| p.team_id == 0).count();
        let team1_count = self.players.iter().filter(|p| p.team_id == 1).count();
        let team_id = match preferred_team {
            0 if team0_count < 3 => 0,
            1 if team1_count < 3 => 1,
            _ => {
                if team0_count <= team1_count {
                    0
                } else {
                    1
                }
            }
        };

        // Pick lowest unused slot with matching team parity, or any free slot
        let mut chosen_slot = None;
        for slot in 0..(MAX_PLAYERS as u8) {
            if slot % 2 == team_id && !self.players.iter().any(|p| p.slot == slot) {
                chosen_slot = Some(slot);
                break;
            }
        }
        let slot = chosen_slot.or_else(|| {
            (0..(MAX_PLAYERS as u8)).find(|&s| !self.players.iter().any(|p| p.slot == s))
        })?;

        let player_id = self.next_player_id;
        self.next_player_id += 1;
        let spawn_pos = SPAWN_POSITIONS[slot as usize % SPAWN_POSITIONS.len()];

        let player = PlayerSim::new(player_id, team_id, slot, username, archetype, spawn_pos);
        self.players.push(player);

        // Give initial possession to the first player on court if the ball has no carrier
        if self.players.len() == 1 && self.ball.carrier_id.is_none() {
            self.give_ball_to_player(player_id, BallState::Held, true);
        }

        Some((player_id, team_id, slot))
    }

    /// Spawns a bot-controlled player into an open slot on `team_id`.
    pub fn add_bot_player(
        &mut self,
        username: String,
        archetype: ArchetypeId,
        team_id: u8,
    ) -> Option<(u32, u8, u8)> {
        let (pid, assigned_team, slot) = self.add_player(username, archetype, team_id)?;
        if let Some(p) = self.get_player_mut(pid) {
            p.is_bot = true;
        }
        Some((pid, assigned_team, slot))
    }

    /// Steps authoritative server-side AI inputs for all bot-flagged players on the court.
    pub fn step_bots(&mut self) {
        let bot_ids: Vec<u32> = self
            .players
            .iter()
            .filter(|p| p.is_bot)
            .map(|p| p.player_id)
            .collect();
        if bot_ids.is_empty() {
            return;
        }
        self.bot_input_seq = self.bot_input_seq.wrapping_add(1).max(1);
        let seq = self.bot_input_seq;
        for pid in bot_ids {
            let frame = super::bot_ai::compute_bot_input(self, pid, seq);
            self.apply_player_input(pid, frame, 0.0);
        }
    }

    /// Force-ends an active match cleanly (for API match-end triggers or mercy-rule finishes),
    /// emitting an authoritative `MatchEnd` reliable event.
    pub fn force_end_match(&mut self, override_scores: Option<[u16; 2]>) {
        if let Some(s) = override_scores {
            self.scores = s;
        }
        self.match_clock_secs = 0.0;
        self.match_ended = true;
        let winner = if self.scores[0] > self.scores[1] {
            0
        } else if self.scores[1] > self.scores[0] {
            1
        } else {
            255
        };
        self.pending_events.push(MatchEventPayload::MatchEnd {
            winner_team: winner,
            score_a: self.scores[0],
            score_b: self.scores[1],
        });
    }

    /// Cleanly resets scores, clocks, positions, stamina, Zone, balance, cooldowns, and ball possession
    /// for a rematch in the exact same room with the exact same player roster!
    pub fn reset_for_rematch(&mut self) {
        self.match_clock_secs = self.match_duration_secs;
        self.shot_clock_secs = self.shot_clock_duration;
        self.scores = [0, 0];
        self.possession_team = 255;
        self.match_ended = false;
        self.lag_comp.clear();
        self.ball.reset_to_free(Vec3::new(0.0, 1.2, 0.0));

        for p in &mut self.players {
            let spawn = SPAWN_POSITIONS[p.slot as usize % SPAWN_POSITIONS.len()];
            p.reset_for_rematch(spawn);
        }

        if let Some(first_pid) = self
            .players
            .iter()
            .min_by_key(|p| p.slot)
            .map(|p| p.player_id)
        {
            self.give_ball_to_player(first_pid, BallState::Held, true);
        }
    }

    pub fn remove_player(&mut self, player_id: u32) -> bool {
        if let Some(pos) = self.players.iter().position(|p| p.player_id == player_id) {
            let p_pos = self.players[pos].pos;
            self.players.remove(pos);
            if self.ball.carrier_id == Some(player_id) {
                self.ball
                    .drop_free(Vec3::new(p_pos.x, p_pos.y + 1.0, p_pos.z), Vec3::ZERO, None);
                self.possession_team = 255;
            }
            true
        } else {
            false
        }
    }

    pub fn give_ball_to_player(&mut self, player_id: u32, state: BallState, emit_event: bool) {
        if let Some(p) = self.players.iter().find(|p| p.player_id == player_id) {
            let team_id = p.team_id;
            let hand_pos = p.active_hand_world_pos();
            let team_changed = self.possession_team != team_id;
            let holder_changed = self.ball.carrier_id != Some(player_id) || team_changed;
            self.ball.set_controlled(state, player_id, team_id, hand_pos);
            self.possession_team = team_id;
            if team_changed {
                self.shot_clock_secs = self.shot_clock_duration;
            }
            if emit_event && holder_changed {
                self.pending_events.push(MatchEventPayload::Possession {
                    team_id,
                    carrier_id: player_id as u16,
                });
            }
        }
    }

    /// Processes a single authoritative `PlayerInputFrameWire` for `player_id` at fixed `dt = 1/60s`.
    /// Never trusts client-claimed position, speed, cooldowns, or scores.
    pub fn apply_player_input(
        &mut self,
        player_id: u32,
        frame: PlayerInputFrameWire,
        perceived_latency_ms: f32,
    ) {
        let idx = match self.players.iter().position(|p| p.player_id == player_id) {
            Some(i) => i,
            None => return,
        };

        let dt = FIXED_DT;
        let buttons = frame.buttons;

        // Sanitize & clamp movement vectors to unit disk (anti-cheat speedhack guard)
        let raw_move = Vec2::new(frame.move_x(), frame.move_z()).clamp_unit();
        let local_dir = Vec2::new(frame.local_x(), frame.local_y()).clamp_unit();
        let aim_yaw = frame.aim_yaw();

        let prev_buttons = self.players[idx].prev_buttons;
        let just_pressed = buttons & !prev_buttons;

        self.players[idx].aim_yaw = aim_yaw;
        self.players[idx].perceived_latency_ms = perceived_latency_ms.clamp(0.0, 250.0);
        if frame.seq > self.players[idx].last_processed_input_seq {
            self.players[idx].last_processed_input_seq = frame.seq;
        }

        // 1. Pre-move timers & defensive phase progression
        {
            let p = &mut self.players[idx];
            p.phantom_phase_timer = (p.phantom_phase_timer - dt).max(0.0);
            p.steal_shield_timer = (p.steal_shield_timer - dt).max(0.0);
            p.dribble_cooldown_timer = (p.dribble_cooldown_timer - dt).max(0.0);
            p.steal_cooldown = (p.steal_cooldown - dt).max(0.0);
            p.block_cooldown = (p.block_cooldown - dt).max(0.0);
            if p.shot_bonus_timer > 0.0 {
                p.shot_bonus_timer = (p.shot_bonus_timer - dt).max(0.0);
                if p.shot_bonus_timer <= 0.0 {
                    p.shot_bonus = 0.0;
                }
            }
            if p.defense_buff_timer > 0.0 {
                p.defense_buff_timer = (p.defense_buff_timer - dt).max(0.0);
                if p.defense_buff_timer <= 0.0 {
                    p.steal_radius_bonus = 0.0;
                    p.contest_bonus = 0.0;
                }
            }

            p.step_steal_phase_pre_move();

            if p.ankle_break_frames > 0 {
                p.ankle_break_frames -= 1;
                if p.ankle_break_frames == 0 {
                    p.balance = 100.0;
                }
            } else {
                p.balance = (p.balance + 24.0 * dt).min(100.0);
            }

            if p.strip_flinch_timer > 0.0 {
                p.strip_flinch_timer = (p.strip_flinch_timer - dt).max(0.0);
            }
        }

        // 2. Zone activation (V / BTN_ZONE) & 60 Hz Zone timer drain
        let zone_activated_now = if (just_pressed & BTN_ZONE) != 0 {
            self.players[idx].try_activate_zone()
        } else {
            false
        };
        if zone_activated_now {
            self.pending_events.push(MatchEventPayload::Zone {
                player_id: player_id as u16,
                activated: true,
                duration_ms: (ZONE_DURATION_SECS * 1000.0) as u16,
            });
        }
        let zone_ended_now = self.players[idx].step_zone(dt);
        if zone_ended_now {
            self.pending_events.push(MatchEventPayload::Zone {
                player_id: player_id as u16,
                activated: false,
                duration_ms: 0,
            });
        }

        let is_stunned = self.players[idx].is_stunned();
        let mut carrying_ball = self.ball.carrier_id == Some(player_id);
        let team_id = self.players[idx].team_id;
        let target_rim = target_rim_for_team(team_id);

        // 3. Authoritative Combo Validator (4 universal combos + 5 archetype unique skills)
        let mut suppress_default_actions = false;
        let combo_res = {
            let p = &mut self.players[idx];
            let dist_to_rim = p.pos.distance_xz(target_rim);
            let arch = p.profile.id;
            let stam = p.stamina;
            let z_act = p.zone_active;
            p.combo_validator.step_frame(
                buttons,
                local_dir,
                arch,
                carrying_ball,
                stam,
                dist_to_rim,
                z_act,
                is_stunned,
            )
        };

        if let Some(res) = combo_res {
            if self.execute_authoritative_combo(idx, res, carrying_ball, target_rim) {
                suppress_default_actions = true;
                carrying_ball = self.ball.carrier_id == Some(player_id);
            }
        }

        // 4. Basic dribble moves (Q / E when carrying ball)
        if !suppress_default_actions
            && carrying_ball
            && !is_stunned
            && !self.players[idx].is_charging_shot
            && !self.players[idx].is_dunking
            && self.players[idx].dribble_cooldown_timer <= 0.0
            && ((just_pressed & (BTN_SKILL_Q | BTN_SKILL_E)) != 0)
        {
            let stam_cost = COST_DRIBBLE_MOVE * self.players[idx].profile.dribble_stamina_mult;
            if self.players[idx].consume_stamina(stam_cost, false, false) {
                let p = &mut self.players[idx];
                p.dribble_hand_right = !p.dribble_hand_right;
                p.dribble_cooldown_timer = 0.22;
                let fwd = p.forward_xz();
                let right = Vec2::new(-fwd.y, fwd.x);
                let side = if (just_pressed & BTN_SKILL_E) != 0 {
                    1.0
                } else {
                    -1.0
                };
                let cut_dir = Vec2::new(fwd.x * 0.55 + right.x * side * 0.84, fwd.y * 0.55 + right.y * side * 0.84)
                    .normalized_or_zero();
                let burst_speed = 10.4 * p.zone_speed_mult();
                p.burst_vel = Vec3::new(cut_dir.x * burst_speed, 0.0, cut_dir.y * burst_speed);
                p.burst_timer = 0.20;
                p.steal_shield_timer = p.steal_shield_timer.max(0.24);
                p.add_zone_charge(6.0);
            }
        }

        // 5. Locomotion: Defensive stance, Sprint, Acceleration, Jumping, Gravity, Court Bounds Clamping
        let move_xz = if is_stunned { Vec2::ZERO } else { raw_move };
        let mut just_jumped = false;
        let grounded_pre = self.players[idx].grounded;

        {
            let p = &mut self.players[idx];
            let whiff_locked = p.is_in_steal_whiff_recovery();
            let def_actions_locked =
                !carrying_ball && (p.steal_phase != StealPhase::Idle || p.block_recovery_frames > 0);

            let wants_stance = !carrying_ball && ((buttons & (BTN_STANCE | BTN_PASS)) != 0);
            p.in_defensive_stance =
                wants_stance && !whiff_locked && !is_stunned && !suppress_default_actions;

            let wants_sprint = (buttons & BTN_SPRINT) != 0 && move_xz.length_sq() > 0.01;
            p.is_sprinting = wants_sprint
                && !p.in_defensive_stance
                && !whiff_locked
                && !is_stunned
                && p.can_sprint();

            p.step_stamina(dt, p.is_sprinting && grounded_pre);

            let z_mult = p.zone_speed_mult();
            let stam_mult = if p.is_exhausted() { 0.78 } else { 1.0 };
            let def_rec_mult = if !carrying_ball {
                p.defense_speed_mult()
            } else {
                1.0
            };

            let mut target_speed = if p.is_sprinting {
                p.profile.sprint_speed * stam_mult
            } else if p.in_defensive_stance {
                STANCE_SPEED
            } else if carrying_ball && p.is_exhausted() {
                p.profile.run_speed * stam_mult
            } else {
                p.profile.run_speed
            };
            target_speed *= z_mult * def_rec_mult;
            if p.landing_frames_left > 0 && !p.in_defensive_stance {
                target_speed *= 0.78;
            }

            if !p.is_dunking {
                if p.burst_timer > 0.0 {
                    p.burst_timer = (p.burst_timer - dt).max(0.0);
                    p.vel.x = p.burst_vel.x;
                    p.vel.z = p.burst_vel.z;
                } else {
                    let target_v = Vec2::new(move_xz.x * target_speed, move_xz.y * target_speed);
                    let cur_v = Vec2::new(p.vel.x, p.vel.z);
                    let lat_mult = if p.in_defensive_stance { 1.25 } else { 1.0 };
                    let accel_rate = if grounded_pre {
                        if move_xz.length_sq() > 0.001 {
                            p.profile.acceleration * lat_mult
                        } else {
                            44.0 * lat_mult
                        }
                    } else {
                        11.0
                    };
                    let next_v = cur_v.move_toward(target_v, accel_rate * dt);
                    p.vel.x = next_v.x;
                    p.vel.z = next_v.y;
                }

                // Jump / vertical block jump & gravity
                if grounded_pre {
                    if p.vel.y < 0.0 {
                        p.vel.y = 0.0;
                    }
                    let wants_offball_block = !carrying_ball && (just_pressed & BTN_SHOOT) != 0;
                    let wants_jump = (just_pressed & BTN_JUMP) != 0 || wants_offball_block;
                    if !suppress_default_actions && wants_jump && !is_stunned && !def_actions_locked
                    {
                        p.vel.y = p.effective_jump_velocity();
                        p.grounded = false;
                        p.landing_frames_left = 0;
                        just_jumped = true;
                        if !carrying_ball {
                            p.block_jump_committed = true;
                            p.jump_succeeded_defensively = false;
                        }
                        p.consume_stamina(COST_JUMP, true, false);
                    }
                } else {
                    p.vel.y -= PLAYER_GRAVITY * dt;
                }

                // Integrate position and strictly enforce court bounds
                p.pos = p.pos.add(p.vel.scale(dt));
                let was_airborne = !p.grounded;
                if p.pos.y <= FLOOR_Y {
                    p.pos.y = FLOOR_Y;
                    p.vel.y = 0.0;
                    p.grounded = true;
                    if was_airborne {
                        p.landing_frames_left = LANDING_RECOVERY_TICKS;
                        if p.block_jump_committed && !p.jump_succeeded_defensively {
                            p.block_recovery_frames =
                                p.block_recovery_frames.max(BLOCK_LANDING_RECOVERY_FRAMES);
                        }
                        p.block_jump_committed = false;
                        p.jump_succeeded_defensively = false;
                    } else if p.landing_frames_left > 0 {
                        p.landing_frames_left -= 1;
                    }
                } else {
                    p.grounded = false;
                }
                p.pos = clamp_to_court(p.pos);

                // Update facing yaw
                if move_xz.length_sq() > 0.01 && !p.in_defensive_stance {
                    p.facing_yaw = (-move_xz.x).atan2(-move_xz.y);
                } else {
                    p.facing_yaw = aim_yaw;
                }
            }
        }

        // 6. Active dunk flight progression
        if self.players[idx].is_dunking {
            self.step_dunk_flight(idx, dt);
            carrying_ball = self.ball.carrier_id == Some(player_id);
        }

        // 7. Shooting / Dunking / Passing while carrying ball
        if carrying_ball && !suppress_default_actions && !is_stunned && !self.players[idx].is_dunking
        {
            if (just_pressed & BTN_PASS) != 0 {
                self.execute_pass(idx);
                carrying_ball = false;
            } else if (just_pressed & BTN_SHOOT) != 0 && !self.players[idx].is_charging_shot {
                self.begin_shot_or_dunk(idx, target_rim, (buttons & BTN_SPRINT) != 0);
            }
        }

        if self.players[idx].is_charging_shot {
            let holding_shoot = (buttons & BTN_SHOOT) != 0;
            self.players[idx].shot_charge_time += dt;
            let auto_rel = if self.players[idx].is_layup_gather {
                AUTO_LAYUP_RELEASE_SEC
            } else {
                AUTO_JUMP_RELEASE_SEC
            };
            if !holding_shoot || self.players[idx].shot_charge_time >= auto_rel {
                self.release_charged_shot(idx, target_rim);
                carrying_ball = false;
            }
        }

        // Keep carried ball synced to player's hand
        if carrying_ball && self.ball.carrier_id == Some(player_id) && !self.players[idx].is_dunking
        {
            let hand_pos = self.players[idx].active_hand_world_pos();
            let horiz_speed = Vec2::new(self.players[idx].vel.x, self.players[idx].vel.z).length();
            self.ball.pos = hand_pos;
            self.ball.vel = self.players[idx].vel;
            self.ball.state = if horiz_speed > 0.35 && self.players[idx].grounded {
                BallState::Dribbling
            } else {
                BallState::Held
            };
        }

        // 8. Defense: Lag-Compensated Block, Pass Interception, Rebound/Pickup, Lag-Compensated Steal
        if !carrying_ball && !suppress_default_actions && !is_stunned {
            let steal_pressed = (just_pressed & BTN_STEAL) != 0;
            let block_pressed = (just_pressed & (BTN_SHOOT | BTN_JUMP)) != 0;
            let manual_pickup = (just_pressed & BTN_SKILL_E) != 0;
            self.step_player_defense(idx, steal_pressed, just_jumped, block_pressed, manual_pickup);
        }

        self.players[idx].prev_buttons = buttons;
    }

    fn execute_authoritative_combo(
        &mut self,
        idx: usize,
        res: ComboTriggerResult,
        carrying_ball: bool,
        target_rim: Vec3,
    ) -> bool {
        // Deduct authoritative stamina
        if !self.players[idx].consume_stamina(res.stamina_cost, false, true) {
            return false;
        }

        let player_id = self.players[idx].player_id;
        let team_id = self.players[idx].team_id;
        let p_pos = self.players[idx].pos;
        let to_rim = target_rim.sub(p_pos).normalized_xz_or_forward();
        let right = to_rim.cross(Vec3::UP).normalized_or_zero();
        let perf = res.potency_mult;

        match res.move_def.id {
            MoveId::PhantomDrive => {
                let speed = 13.5 * if res.is_ex { 1.22 } else { 1.0 } * perf;
                let dur = 0.30 * if res.is_ex { 1.16 } else { 1.0 };
                let p = &mut self.players[idx];
                p.dribble_hand_right = !p.dribble_hand_right;
                p.phantom_phase_timer = p.phantom_phase_timer.max(dur + 0.06);
                p.steal_shield_timer = p.steal_shield_timer.max(dur + 0.16);
                p.burst_vel = to_rim.scale(speed);
                p.burst_timer = dur;
            }
            MoveId::MeteorDunk => {
                if !carrying_ball {
                    return false;
                }
                let shock_r = 3.5 * if res.is_ex { 1.25 } else { 1.0 } * perf;
                let apex = if res.is_ex { 4.55 } else { 4.15 };
                self.start_signature_dunk(idx, target_rim, 28, apex, shock_r, 97.5 * perf, true);
            }
            MoveId::AnkleBreaker => {
                let cone_r = if res.is_ex { 3.6 } else { 2.8 } * perf;
                let bal_dmg = 110.0 * if res.is_ex { 1.35 } else { 1.0 } * perf
                    * self.players[idx].profile.ankle_break_mult;
                {
                    let p = &mut self.players[idx];
                    p.dribble_hand_right = !p.dribble_hand_right;
                    let sign = if p.dribble_hand_right { 1.0 } else { -1.0 };
                    let cut = to_rim.scale(-0.45).add(right.scale(0.89 * sign)).normalized_xz_or_forward();
                    p.steal_shield_timer = p.steal_shield_timer.max(0.38);
                    p.shot_bonus = 0.14 * perf;
                    p.shot_bonus_timer = 0.95;
                    p.burst_vel = cut.scale(10.2 * perf * p.zone_speed_mult());
                    p.burst_timer = 0.20;
                }
                self.apply_cone_ankle_break(player_id, team_id, p_pos, cone_r, bal_dmg);
            }
            MoveId::MirrorStep => {
                let stepback_dist = if res.is_ex { 3.8 } else { 3.2 } * perf;
                let p = &mut self.players[idx];
                p.dribble_hand_right = !p.dribble_hand_right;
                let sign = if p.dribble_hand_right { 1.0 } else { -1.0 };
                let dur = 20.0 / 60.0;
                let disp = to_rim.scale(-stepback_dist).add(right.scale(1.1 * sign));
                p.steal_shield_timer = p.steal_shield_timer.max(dur + 0.12);
                p.shot_bonus = if res.is_ex { 0.22 } else { 0.15 } * perf;
                p.shot_bonus_timer = 1.05;
                p.burst_vel = disp.scale(1.0 / dur);
                p.burst_timer = dur;
            }
            MoveId::VoltDash => {
                let dur = 0.24;
                let p = &mut self.players[idx];
                p.dribble_hand_right = !p.dribble_hand_right;
                p.phantom_phase_timer = p.phantom_phase_timer.max(dur + 0.06);
                p.steal_shield_timer = p.steal_shield_timer.max(dur + 0.16);
                p.burst_vel = to_rim.scale(15.0 * perf);
                p.burst_timer = dur;
            }
            MoveId::StarlightHighArc => {
                if !carrying_ball {
                    return false;
                }
                let release_pos = Vec3::new(p_pos.x, p_pos.y + 2.46, p_pos.z);
                let spin = BallSim::compute_backspin_omega(release_pos, target_rim, 20.0);
                let launch_vel =
                    BallSim::solve_ballistic_velocity_with_spin(release_pos, target_rim, 5.85, spin);
                self.ball.launch_shot(
                    player_id,
                    team_id,
                    release_pos,
                    Vec3::new(p_pos.x, 0.0, p_pos.z),
                    target_rim,
                    launch_vel,
                    spin,
                    0.53, // Starlight high-arc block resistance
                );
                let p = &mut self.players[idx];
                p.burst_vel = to_rim.scale(-8.0);
                p.burst_timer = 0.16;
                p.vel.y = p.vel.y.max(5.2);
                p.grounded = false;
            }
            MoveId::MirageThread => {
                if !carrying_ball {
                    return false;
                }
                let has_mate = self
                    .players
                    .iter()
                    .any(|o| o.player_id != player_id && o.team_id == team_id);
                if has_mate {
                    self.execute_pass(idx);
                } else {
                    let p = &mut self.players[idx];
                    p.dribble_hand_right = !p.dribble_hand_right;
                    p.steal_shield_timer = p.steal_shield_timer.max(0.42);
                    p.burst_vel = to_rim.scale(12.8 * perf);
                    p.burst_timer = 0.26;
                }
            }
            MoveId::TectonicSlam => {
                if !carrying_ball {
                    return false;
                }
                self.start_signature_dunk(
                    idx,
                    target_rim,
                    24,
                    3.85,
                    4.2 * perf,
                    135.0 * perf,
                    true,
                );
            }
            MoveId::EclipseCounter => {
                if carrying_ball {
                    let p = &mut self.players[idx];
                    p.dribble_hand_right = !p.dribble_hand_right;
                    p.steal_shield_timer = p.steal_shield_timer.max(0.45);
                    p.shot_bonus = 0.12 * perf;
                    p.shot_bonus_timer = 0.90;
                    p.burst_vel = to_rim.scale(12.6 * perf);
                    p.burst_timer = 0.28;
                } else {
                    let close_dir = self.ball.pos.sub(p_pos).normalized_xz_or_forward();
                    let p = &mut self.players[idx];
                    p.burst_vel = close_dir.scale(13.2 * perf);
                    p.burst_timer = 0.24;
                    p.steal_radius_bonus = 0.65 * perf;
                    p.contest_bonus = 0.30 * perf;
                    p.defense_buff_timer = 0.90;
                }
            }
            _ => {}
        }

        self.players[idx].add_zone_charge(res.move_def.zone_gain);
        self.pending_events.push(MatchEventPayload::Combo {
            player_id: player_id as u16,
            move_id: res.move_def.id.as_u8(),
            combo_tier: res.combo_tier,
            is_perfect: res.is_perfect,
            is_ex: res.is_ex,
        });
        true
    }

    #[allow(clippy::too_many_arguments)]
    fn start_signature_dunk(
        &mut self,
        idx: usize,
        target_rim: Vec3,
        duration_frames: u16,
        desired_apex: f32,
        shockwave_radius: f32,
        balance_damage: f32,
        armored: bool,
    ) {
        let player_id = self.players[idx].player_id;
        let team_id = self.players[idx].team_id;
        let start = self.players[idx].pos;
        let dir = target_rim.sub(start).normalized_xz_or_forward();
        let end = Vec3::new(target_rim.x - dir.x * 0.25, 1.32, target_rim.z - dir.z * 0.25);
        let dur = (duration_frames as f32) * FIXED_DT;
        let mid_base_y = (start.y + end.y) * 0.5;

        {
            let p = &mut self.players[idx];
            p.is_charging_shot = false;
            p.is_dunking = true;
            p.is_armored_dunk = armored;
            p.dunk_elapsed = 0.0;
            p.dunk_duration = dur;
            p.dunk_start_pos = start;
            p.dunk_end_pos = end;
            p.dunk_apex_lift = ((desired_apex - 1.35) - mid_base_y).max(1.20);
            p.dunk_target_rim = target_rim;
            p.dunk_shockwave_radius = shockwave_radius;
            p.dunk_balance_damage = balance_damage;
            p.steal_shield_timer = p.steal_shield_timer.max(dur + 0.15);
            p.phantom_phase_timer = p.phantom_phase_timer.max(dur + 0.06);
            p.grounded = false;
        }
        self.ball
            .set_controlled(BallState::DunkLocked, player_id, team_id, start.add(Vec3::new(0.0, 1.8, 0.0)));
    }

    fn step_dunk_flight(&mut self, idx: usize, dt: f32) {
        let (done, player_id, team_id, rim, shock_r, bal_dmg, pos_now) = {
            let p = &mut self.players[idx];
            p.dunk_elapsed += dt;
            let t = (p.dunk_elapsed / p.dunk_duration.max(0.05)).clamp(0.0, 1.0);
            let lerp_pos = Vec3::new(
                p.dunk_start_pos.x + (p.dunk_end_pos.x - p.dunk_start_pos.x) * t,
                p.dunk_start_pos.y
                    + (p.dunk_end_pos.y - p.dunk_start_pos.y) * t
                    + 4.0 * p.dunk_apex_lift * t * (1.0 - t),
                p.dunk_start_pos.z + (p.dunk_end_pos.z - p.dunk_start_pos.z) * t,
            );
            p.pos = clamp_to_court(lerp_pos);
            p.vel = Vec3::ZERO;
            p.grounded = false;
            (
                t >= 1.0,
                p.player_id,
                p.team_id,
                p.dunk_target_rim,
                p.dunk_shockwave_radius,
                p.dunk_balance_damage,
                p.pos,
            )
        };

        if !done {
            self.ball.pos = Vec3::new(pos_now.x, pos_now.y + 1.45, pos_now.z);
        } else {
            {
                let p = &mut self.players[idx];
                p.is_dunking = false;
                p.is_armored_dunk = false;
                p.vel = Vec3::new(0.0, -2.0, 0.0);
            }
            self.ball.launch_dunk_drop(player_id, team_id, rim, 9.5);
            if shock_r > 0.1 && bal_dmg > 0.1 {
                self.apply_cone_ankle_break(player_id, team_id, rim, shock_r, bal_dmg);
            }
        }
    }

    fn begin_shot_or_dunk(&mut self, idx: usize, target_rim: Vec3, sprint_held: bool) {
        let dist_xz = self.players[idx].pos.distance_xz(target_rim);
        let horiz_speed = Vec2::new(self.players[idx].vel.x, self.players[idx].vel.z).length();
        let dunk_radius = self.players[idx].profile.dunk_radius;

        if dist_xz <= dunk_radius && sprint_held && self.players[idx].consume_stamina(COST_DUNK, false, false) {
            let frames = ((dist_xz / 8.2).clamp(0.18, 0.42) * 60.0).round() as u16;
            self.start_signature_dunk(idx, target_rim, frames.max(12), 3.45, 0.0, 0.0, false);
            return;
        }

        let p = &mut self.players[idx];
        p.is_charging_shot = true;
        p.is_layup_gather = dist_xz <= LAYUP_RANGE_XZ && horiz_speed > 1.0;
        p.shot_charge_time = 0.0;
        p.shot_origin_floor = Vec3::new(p.pos.x, 0.0, p.pos.z);
        if p.grounded {
            p.vel.y = p.vel.y.max(if p.is_layup_gather { 5.0 } else { 4.5 });
            p.grounded = false;
        }
    }

    fn release_charged_shot(&mut self, idx: usize, target_rim: Vec3) {
        let (player_id, team_id, origin_floor, release_pos, apex_y, quality) = {
            let p = &mut self.players[idx];
            p.is_charging_shot = false;
            let opt = if p.is_layup_gather {
                OPTIMAL_LAYUP_CHARGE_SEC
            } else {
                OPTIMAL_JUMP_CHARGE_SEC
            };
            let err = (p.shot_charge_time - opt).abs();
            let window_scale = (1.0 + p.profile.perfect_window_bonus).max(0.5);
            let norm_err = (err / (0.20 * window_scale)).clamp(0.0, 1.0);
            let mut q = (1.0 - norm_err) + p.shot_bonus;
            if p.zone_active {
                q += 0.12;
            }
            if p.is_exhausted() {
                q -= 0.15;
            }
            let rel_pos = Vec3::new(p.pos.x, p.pos.y + 2.25, p.pos.z);
            let dist_xz = p.pos.distance_xz(target_rim);
            let arc_h = (3.75 + dist_xz * 0.14 + p.profile.shot_arc_bonus).clamp(3.65, 6.2);
            (
                p.player_id,
                p.team_id,
                p.shot_origin_floor,
                rel_pos,
                arc_h,
                q.clamp(0.0, 1.0),
            )
        };

        // Evaluate lag-compensated defensive shot contest
        let contest = self.compute_shot_contest(player_id, team_id, origin_floor, target_rim);
        let effective_quality = (quality - contest * 0.35).clamp(0.0, 1.0);

        // Aim target: high quality hits dead-center rim; poor/contested quality drifts slightly off center
        let miss_offset = if effective_quality >= 0.55 {
            0.0
        } else {
            let severity = (0.55 - effective_quality) / 0.55;
            0.26 * severity
        };
        let aim_point = Vec3::new(target_rim.x + miss_offset, target_rim.y + 0.02, target_rim.z);
        let spin = BallSim::compute_backspin_omega(release_pos, aim_point, 14.0);
        let launch_vel =
            BallSim::solve_ballistic_velocity_with_spin(release_pos, aim_point, apex_y, spin);

        self.ball.launch_shot(
            player_id,
            team_id,
            release_pos,
            origin_floor,
            target_rim,
            launch_vel,
            spin,
            0.0,
        );
    }

    fn execute_pass(&mut self, idx: usize) {
        let passer_id = self.players[idx].player_id;
        let team_id = self.players[idx].team_id;
        let passer_pos = self.players[idx].pos;
        let pass_speed = 15.0 * self.players[idx].profile.pass_speed_mult;
        let release_pos = Vec3::new(passer_pos.x, passer_pos.y + 1.32, passer_pos.z);

        let mate = self
            .players
            .iter()
            .filter(|p| p.player_id != passer_id && p.team_id == team_id)
            .min_by(|a, b| {
                a.pos
                    .distance_xz(passer_pos)
                    .total_cmp(&b.pos.distance_xz(passer_pos))
            });

        let (target_id, target_pos) = if let Some(m) = mate {
            (Some(m.player_id), Vec3::new(m.pos.x, m.pos.y + 1.25, m.pos.z))
        } else {
            let fwd = self.players[idx].forward_xz();
            (
                None,
                Vec3::new(
                    passer_pos.x + fwd.x * 6.0,
                    1.25,
                    passer_pos.z + fwd.y * 6.0,
                ),
            )
        };

        let dir = target_pos.sub(release_pos).normalized_or_zero();
        let vel = Vec3::new(dir.x * pass_speed, (dir.y * pass_speed) + 1.2, dir.z * pass_speed);
        self.ball
            .launch_pass(passer_id, team_id, release_pos, vel, target_id);
    }

    /// Evaluates lag-compensated defensive contest (`0.0..=1.0`) for `shooter_id`.
    pub fn compute_shot_contest(
        &self,
        shooter_id: u32,
        shooter_team: u8,
        shooter_pos: Vec3,
        target_rim: Vec3,
    ) -> f32 {
        let mut max_contest = 0.0f32;
        let to_rim = Vec2::new(target_rim.x - shooter_pos.x, target_rim.z - shooter_pos.z)
            .normalized_or_zero();

        for def in &self.players {
            if def.player_id == shooter_id || def.team_id == shooter_team {
                continue;
            }
            if def.ankle_break_frames > 0 {
                continue;
            }
            // Lag-compensated defender pose if defender has latency
            let def_pos = if def.perceived_latency_ms > 0.0 {
                self.lag_comp
                    .sample_rewound_by_ms(self.server_tick, def.perceived_latency_ms)
                    .and_then(|snap| snap.find_player(def.player_id))
                    .map(|pose| pose.pos)
                    .unwrap_or(def.pos)
            } else {
                def.pos
            };

            let delta_xz = Vec2::new(def_pos.x - shooter_pos.x, def_pos.z - shooter_pos.z);
            let dist = delta_xz.length();
            let base_range = if def.in_defensive_stance { 2.75 } else { 2.40 };
            let max_r = base_range + if def.defense_buff_timer > 0.0 { 0.60 } else { 0.0 };
            if dist >= max_r {
                continue;
            }
            let prox = (1.0 - dist / max_r).clamp(0.0, 1.0);
            let cone_dot = to_rim.dot(delta_xz.normalized_or_zero()).max(0.0);
            let cone_factor = if def.in_defensive_stance {
                0.58 + 0.42 * cone_dot
            } else {
                0.42 + 0.58 * cone_dot
            };
            let mut bonus = def.contest_bonus;
            if !def.grounded {
                bonus += 0.34 * (def_pos.y / 1.1).clamp(0.25, 1.0);
            }
            if def.in_defensive_stance {
                bonus += 0.22;
            }
            let mut val = (prox * cone_factor + prox * bonus).clamp(0.0, 1.0);
            if def.is_in_defense_recovery() {
                val *= 0.20;
            }
            max_contest = max_contest.max(val);
        }

        max_contest
    }

    fn apply_cone_ankle_break(
        &mut self,
        attacker_id: u32,
        attacker_team: u8,
        origin: Vec3,
        radius: f32,
        balance_damage: f32,
    ) {
        let mut broken_victims = Vec::new();
        for p in &mut self.players {
            if p.player_id == attacker_id || p.team_id == attacker_team {
                continue;
            }
            if p.pos.distance_xz(origin) <= radius && p.apply_balance_damage(balance_damage) {
                broken_victims.push((p.player_id, p.pos));
            }
        }
        if !broken_victims.is_empty() {
            if let Some(att) = self.get_player_mut(attacker_id) {
                att.add_zone_charge(20.0);
            }
            for (vid, vpos) in broken_victims {
                self.pending_events.push(MatchEventPayload::AnkleBreak {
                    victim_id: vid as u16,
                    attacker_id: attacker_id as u16,
                    pos_x: quantize_pos_vel(vpos.x),
                    pos_y: quantize_pos_vel(vpos.y),
                    pos_z: quantize_pos_vel(vpos.z),
                });
            }
        }
    }

    /// Processes defensive BLOCK, PASS INTERCEPTION, PICKUP/REBOUND, and STEAL with 16-tick lag compensation!
    fn step_player_defense(
        &mut self,
        idx: usize,
        steal_pressed: bool,
        just_jumped: bool,
        block_pressed: bool,
        manual_pickup: bool,
    ) {
        let player_id = self.players[idx].player_id;
        let team_id = self.players[idx].team_id;
        let def_pos = self.players[idx].pos;
        let def_vel = self.players[idx].vel;
        let airborne = !self.players[idx].grounded;
        let in_rec = self.players[idx].is_in_defense_recovery();
        let zone_active = self.players[idx].zone_active;
        let latency_ms = self.players[idx].perceived_latency_ms;

        // 1. Lag-Compensated Vertical Shot Block
        if !in_rec
            && self.players[idx].block_cooldown <= 0.0
            && (just_jumped || airborne || block_pressed)
        {
            let eff_block_r = self.players[idx].effective_block_radius()
                * if airborne && def_vel.y.abs() < 3.2 {
                    1.12
                } else {
                    1.0
                };
            let reach_h = if airborne { 2.18 } else { 1.85 } * if zone_active { 1.20 } else { 1.0 };
            let hand_pos = Vec3::new(def_pos.x, def_pos.y + reach_h, def_pos.z);

            let live_hit = self.ball.state == BallState::ShotFlight
                && self.ball.last_shooter_team != Some(team_id)
                && self.ball.vel.y > -1.8
                && hand_pos.distance_to(self.ball.pos)
                    <= eff_block_r * (1.0 - self.ball.block_resistance);

            let rewound_hit = if !live_hit && latency_ms > 0.0 {
                self.lag_comp
                    .sample_rewound_by_ms(self.server_tick, latency_ms)
                    .map(|snap| {
                        snap.ball_state == BallState::ShotFlight
                            && snap.last_shooter_team != Some(team_id)
                            && snap.ball_vel.y > -1.8
                            && hand_pos.distance_to(snap.ball_pos)
                                <= eff_block_r * (1.0 - snap.block_resistance)
                    })
                    .unwrap_or(false)
            } else {
                false
            };

            if (live_hit || rewound_hit)
                && self.ball.state == BallState::ShotFlight
                && self.ball.last_shooter_team != Some(team_id)
            {
                let shooter_id = self.ball.last_shooter_id.unwrap_or(0);
                let block_pos = self.ball.pos;
                let away = block_pos.sub(self.ball.last_target_rim).normalized_xz_or_forward();
                let swat_vel = away.scale(7.8).add(Vec3::new(0.0, 2.1, 0.0));
                self.ball.drop_free(block_pos, swat_vel, Some(player_id));

                let p = &mut self.players[idx];
                p.consume_stamina(COST_BLOCK, true, false);
                p.block_cooldown = 0.60;
                p.jump_succeeded_defensively = true;
                p.add_zone_charge(22.0);

                self.pending_events.push(MatchEventPayload::Block {
                    blocker_id: player_id as u16,
                    shooter_id: shooter_id as u16,
                    pos_x: quantize_pos_vel(block_pos.x),
                    pos_y: quantize_pos_vel(block_pos.y),
                    pos_z: quantize_pos_vel(block_pos.z),
                });
                return;
            }
        }

        // 2. Opponent Pass Lane Interception
        if !in_rec && self.ball.is_opponent_pass_for_team(team_id) {
            let mut r: f32 = if self.players[idx].in_defensive_stance {
                1.15
            } else {
                0.85
            };
            if self.players[idx].steal_phase == StealPhase::Active {
                r = r.max(1.0);
            }
            if zone_active {
                r *= 1.15;
            }
            let dist_xz = def_pos.distance_xz(self.ball.pos);
            let dy = (self.ball.pos.y - (def_pos.y + 1.15)).abs();
            if dist_xz <= r && dy <= 1.75 {
                let passer_id = self.ball.last_passer_id.unwrap_or(0);
                let steal_pos = self.ball.pos;
                self.give_ball_to_player(player_id, BallState::Held, true);
                let p = &mut self.players[idx];
                p.jump_succeeded_defensively = true;
                p.steal_phase = StealPhase::Idle;
                p.steal_phase_frames = 0;
                p.add_zone_charge(22.0);
                self.pending_events.push(MatchEventPayload::Steal {
                    stealer_id: player_id as u16,
                    victim_id: passer_id as u16,
                    is_interception: true,
                    pos_x: quantize_pos_vel(steal_pos.x),
                    pos_y: quantize_pos_vel(steal_pos.y),
                    pos_z: quantize_pos_vel(steal_pos.z),
                });
                return;
            }
        }

        // 3. Rebound / Loose-ball / Teammate Pass Reception
        if self.ball.can_be_picked_up_by(player_id) && !self.ball.is_opponent_pass_for_team(team_id) {
            let mut reach_xz = 1.05f32;
            let mut reach_y = 1.65f32;
            let mut center_y = def_pos.y + 1.0;

            if self.ball.state == BallState::PassFlight && self.ball.pass_target_id == Some(player_id)
            {
                reach_xz = 1.45;
                reach_y = 1.95;
            } else if steal_pressed || manual_pickup {
                reach_xz = 2.15;
            }
            if airborne {
                reach_xz = reach_xz.max(1.95);
                reach_y = 1.90;
                center_y = def_pos.y + 1.45;
            }

            if def_pos.distance_xz(self.ball.pos) <= reach_xz
                && (self.ball.pos.y - center_y).abs() <= reach_y
            {
                let was_rebound = self.ball.is_reboundable;
                self.give_ball_to_player(player_id, BallState::Held, true);
                let p = &mut self.players[idx];
                if was_rebound || airborne {
                    p.jump_succeeded_defensively = true;
                }
                if was_rebound {
                    p.add_zone_charge(10.0);
                }
                return;
            }
        }

        // 4. Active Steal State Machine (6f STARTUP -> 5f ACTIVE -> 24f WHIFF_RECOVERY) + Lag Compensation
        if steal_pressed
            && self.players[idx].steal_phase == StealPhase::Idle
            && self.players[idx].block_recovery_frames == 0
            && self.players[idx].steal_cooldown <= 0.0
        {
            if self.players[idx].consume_stamina(COST_STEAL, true, false) {
                self.players[idx].steal_phase = StealPhase::Startup;
                self.players[idx].steal_phase_frames = STEAL_STARTUP_FRAMES;
            }
            return;
        }

        if self.players[idx].steal_phase == StealPhase::Active {
            if let Some((victim_id, steal_pos)) = self.evaluate_lag_comp_steal(idx) {
                self.give_ball_to_player(player_id, BallState::Held, true);
                if let Some(victim) = self.get_player_mut(victim_id) {
                    victim.strip_flinch_timer = 0.28;
                    victim.is_charging_shot = false;
                }
                let p = &mut self.players[idx];
                p.steal_phase = StealPhase::Idle;
                p.steal_phase_frames = 0;
                p.steal_cooldown = 0.25;
                p.add_zone_charge(22.0);
                self.pending_events.push(MatchEventPayload::Steal {
                    stealer_id: player_id as u16,
                    victim_id: victim_id as u16,
                    is_interception: false,
                    pos_x: quantize_pos_vel(steal_pos.x),
                    pos_y: quantize_pos_vel(steal_pos.y),
                    pos_z: quantize_pos_vel(steal_pos.z),
                });
            }
        }
    }

    fn evaluate_lag_comp_steal(&self, def_idx: usize) -> Option<(u32, Vec3)> {
        let def = &self.players[def_idx];
        let carrier_id = self.ball.carrier_id?;
        if carrier_id == def.player_id
            || self.ball.carrier_team == Some(def.team_id)
            || self.ball.state == BallState::DunkLocked
        {
            return None;
        }

        let live_carrier = self.get_player(carrier_id)?;
        if live_carrier.has_steal_protection() {
            return None;
        }

        let reach = def.effective_steal_radius();

        // Check live pose first
        let live_dist = def.pos.distance_xz(live_carrier.pos);
        if live_dist * 0.94 <= reach {
            return Some((carrier_id, self.ball.pos));
        }

        // Check lag-compensated pose (up to max 250ms = 15 ticks rewind!)
        if def.perceived_latency_ms > 0.0 {
            if let Some(snap) = self
                .lag_comp
                .sample_rewound_by_ms(self.server_tick, def.perceived_latency_ms)
            {
                if snap.carrier_id == Some(carrier_id) && snap.ball_state != BallState::DunkLocked {
                    if let Some(hist_carrier) = snap.find_player(carrier_id) {
                        if !hist_carrier.steal_shielded && !hist_carrier.is_armored {
                            let hist_dist = def.pos.distance_xz(hist_carrier.pos);
                            if hist_dist * 0.94 <= reach {
                                return Some((carrier_id, hist_carrier.pos));
                            }
                        }
                    }
                }
            }
        }

        None
    }

    /// Advances global world physics (ball, hollow rim scoring, shot clock, match timer, lag-comp history).
    pub fn step_tick(&mut self) {
        let dt = FIXED_DT;
        self.server_tick += 1;

        if !self.match_ended {
            // Advance ball & authoritative scoring gates
            if let Some(basket) = self.ball.step(dt) {
                let team_idx = (basket.scoring_team as usize).min(1);
                self.scores[team_idx] = self.scores[team_idx].saturating_add(basket.points as u16);
                let new_score = self.scores[team_idx];

                if let Some(scorer) = self.get_player_mut(basket.scorer_id) {
                    scorer.add_zone_charge(if basket.is_three { 24.0 } else { 18.0 });
                }

                self.pending_events.push(MatchEventPayload::Score {
                    team_id: basket.scoring_team,
                    delta: basket.points,
                    is_three: basket.is_three,
                    new_score,
                    scorer_id: basket.scorer_id as u16,
                });

                // Inbound to conceding team & reset 24s shot clock
                let next_team = if basket.scoring_team == 0 { 1 } else { 0 };
                self.shot_clock_secs = self.shot_clock_duration;
                if let Some(receiver_id) = self
                    .players
                    .iter()
                    .find(|p| p.team_id == next_team)
                    .map(|p| p.player_id)
                {
                    let inbound_z = if next_team == 0 { 9.0 } else { -9.0 };
                    if let Some(r) = self.get_player_mut(receiver_id) {
                        r.pos = Vec3::new(0.0, 0.0, inbound_z);
                        r.vel = Vec3::ZERO;
                    }
                    self.give_ball_to_player(receiver_id, BallState::Held, true);
                } else {
                    self.ball.reset_to_free(Vec3::new(0.0, 1.2, 0.0));
                }
            }

            // Advance shot clock when a team holds possession
            if self.possession_team <= 1 {
                self.shot_clock_secs = (self.shot_clock_secs - dt).max(0.0);
                if self.shot_clock_secs <= 0.0 {
                    // Turnover to opposing team
                    let next_team = if self.possession_team == 0 { 1 } else { 0 };
                    self.shot_clock_secs = self.shot_clock_duration;
                    if let Some(receiver_id) = self
                        .players
                        .iter()
                        .find(|p| p.team_id == next_team)
                        .map(|p| p.player_id)
                    {
                        self.give_ball_to_player(receiver_id, BallState::Held, true);
                    } else {
                        self.ball.reset_to_free(Vec3::new(0.0, 1.2, 0.0));
                        self.possession_team = 255;
                    }
                }
            }

            // Advance match clock
            if !self.players.is_empty() {
                self.match_clock_secs = (self.match_clock_secs - dt).max(0.0);
                if self.match_clock_secs <= 0.0 {
                    self.match_ended = true;
                    let winner = if self.scores[0] > self.scores[1] {
                        0
                    } else if self.scores[1] > self.scores[0] {
                        1
                    } else {
                        255
                    };
                    self.pending_events.push(MatchEventPayload::MatchEnd {
                        winner_team: winner,
                        score_a: self.scores[0],
                        score_b: self.scores[1],
                    });
                }
            }
        }

        // Record authoritative world pose into 16-tick lag-comp ring
        let pose_snapshot = WorldPoseSnapshot {
            tick: self.server_tick,
            ball_pos: self.ball.pos,
            ball_vel: self.ball.vel,
            ball_state: self.ball.state,
            carrier_id: self.ball.carrier_id,
            last_shooter_team: self.ball.last_shooter_team,
            last_shooter_id: self.ball.last_shooter_id,
            block_resistance: self.ball.block_resistance,
            players: self
                .players
                .iter()
                .map(|p| PlayerPose {
                    player_id: p.player_id,
                    team_id: p.team_id,
                    pos: p.pos,
                    vel: p.vel,
                    facing_yaw: p.facing_yaw,
                    grounded: p.grounded,
                    is_dunking: p.is_dunking,
                    is_armored: p.is_armored_dunk,
                    steal_shielded: p.has_steal_protection(),
                    ankle_broken: p.ankle_break_frames > 0,
                    in_stance: p.in_defensive_stance,
                    stamina: p.stamina,
                    dribble_hand_right: p.dribble_hand_right,
                })
                .collect(),
        };
        self.lag_comp.record(pose_snapshot);
    }

    pub fn build_snapshot(&self) -> ServerWorldSnapshotMsg {
        ServerWorldSnapshotMsg {
            server_tick: self.server_tick as u32,
            match_clock_ms: (self.match_clock_secs * 1000.0).round().max(0.0) as u32,
            shot_clock_ms: (self.shot_clock_secs * 1000.0).round().clamp(0.0, 65_535.0) as u16,
            score_a: self.scores[0],
            score_b: self.scores[1],
            possession_team: self.possession_team,
            carrier_id: self.ball.carrier_id.unwrap_or(0) as u16,
            ball_pos_x: quantize_pos_vel(self.ball.pos.x),
            ball_pos_y: quantize_pos_vel(self.ball.pos.y),
            ball_pos_z: quantize_pos_vel(self.ball.pos.z),
            ball_vel_x: quantize_pos_vel(self.ball.vel.x),
            ball_vel_y: quantize_pos_vel(self.ball.vel.y),
            ball_vel_z: quantize_pos_vel(self.ball.vel.z),
            ball_state: self.ball.state.as_u8(),
            players: self.players.iter().map(|p| p.to_quantized_state()).collect(),
        }
    }

    /// Helper exposing defended rim calculation for external tests/modules.
    pub fn defended_rim(team_id: u8) -> Vec3 {
        defended_rim_for_team(team_id)
    }
}
