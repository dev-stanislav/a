use std::collections::{HashMap, VecDeque};

use crate::protocol::{
    BTN_JUMP, BTN_PASS, BTN_SHOOT, BTN_SKILL_E, BTN_SKILL_Q, BTN_SKILL_R, BTN_SPRINT, BTN_STANCE,
    BTN_STEAL, BTN_ZONE, CD_ANKLE_BREAKER, CD_METEOR_DUNK, CD_MIRROR_STEP, CD_PHANTOM_DRIVE,
    CD_UNIQUE_SKILL,
};

use super::player_sim::ArchetypeId;
use super::{Vec2, ZONE_STAMINA_COST_MULT};

pub const INPUT_BUFFER_CAPACITY: usize = 90;
pub const DIR_DEADZONE: f32 = 0.45;
pub const PERFECT_STAMINA_REFUND: f32 = 0.20;
pub const PERFECT_POTENCY_MULT: f32 = 1.15;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MoveId {
    None = 0,
    PhantomDrive = 1,
    MeteorDunk = 2,
    AnkleBreaker = 3,
    MirrorStep = 4,
    VoltDash = 5,
    StarlightHighArc = 6,
    MirageThread = 7,
    TectonicSlam = 8,
    EclipseCounter = 9,
    Crossover = 10,
    BehindTheBack = 11,
    Spin = 12,
    Stepback = 13,
    Hesitation = 14,
}

impl MoveId {
    pub fn as_u8(self) -> u8 {
        self as u8
    }

    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::PhantomDrive,
            2 => Self::MeteorDunk,
            3 => Self::AnkleBreaker,
            4 => Self::MirrorStep,
            5 => Self::VoltDash,
            6 => Self::StarlightHighArc,
            7 => Self::MirageThread,
            8 => Self::TectonicSlam,
            9 => Self::EclipseCounter,
            10 => Self::Crossover,
            11 => Self::BehindTheBack,
            12 => Self::Spin,
            13 => Self::Stepback,
            14 => Self::Hesitation,
            _ => Self::None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputSymbol {
    W,
    S,
    A,
    D,
    Shift,
    Space,
    Lmb,
    Rmb,
    Q,
    E,
    R,
    F,
    C,
    V,
}

impl InputSymbol {
    pub fn is_direction(self) -> bool {
        matches!(self, Self::W | Self::S | Self::A | Self::D)
    }

    pub fn held_in_vec(self, v: Vec2) -> bool {
        match self {
            Self::W => v.y >= DIR_DEADZONE,
            Self::S => v.y <= -DIR_DEADZONE,
            Self::A => v.x <= -DIR_DEADZONE,
            Self::D => v.x >= DIR_DEADZONE,
            _ => false,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct MoveDef {
    pub id: MoveId,
    pub sequence: &'static [InputSymbol],
    pub startup_frames: u16,
    pub active_frames: u16,
    pub recovery_frames: u16,
    pub cooldown_frames: u16,
    pub priority: u8,
    pub step_window_frames: u32,
    pub perfect_gap_min: u32,
    pub perfect_gap_max: u32,
    pub stamina_cost: f32,
    pub zone_gain: f32,
    pub requires_ball: bool,
    pub max_rim_distance: Option<f32>,
    pub archetype: Option<ArchetypeId>,
}

/// Ordered deterministically by (priority DESC, sequence.len DESC) matching MoveDatabase.
pub const COMBO_DEFS: &[MoveDef] = &[
    // 1. Meteor Dunk (priority 70): Shift -> W -> Space -> R
    MoveDef {
        id: MoveId::MeteorDunk,
        sequence: &[
            InputSymbol::Shift,
            InputSymbol::W,
            InputSymbol::Space,
            InputSymbol::R,
        ],
        startup_frames: 6,
        active_frames: 28,
        recovery_frames: 16,
        cooldown_frames: 300,
        priority: 70,
        step_window_frames: 14,
        perfect_gap_min: 4,
        perfect_gap_max: 9,
        stamina_cost: 24.0,
        zone_gain: 18.0,
        requires_ball: true,
        max_rim_distance: Some(5.5),
        archetype: None,
    },
    // 2. Tectonic Slam (priority 68, Powerhouse): Shift -> Space -> LMB
    MoveDef {
        id: MoveId::TectonicSlam,
        sequence: &[InputSymbol::Shift, InputSymbol::Space, InputSymbol::Lmb],
        startup_frames: 5,
        active_frames: 26,
        recovery_frames: 15,
        cooldown_frames: 270,
        priority: 68,
        step_window_frames: 14,
        perfect_gap_min: 4,
        perfect_gap_max: 9,
        stamina_cost: 22.0,
        zone_gain: 16.0,
        requires_ball: true,
        max_rim_distance: Some(4.2),
        archetype: Some(ArchetypeId::Powerhouse),
    },
    // 3. Starlight High Arc (priority 60, Sharpshooter): E -> S -> LMB
    MoveDef {
        id: MoveId::StarlightHighArc,
        sequence: &[InputSymbol::E, InputSymbol::S, InputSymbol::Lmb],
        startup_frames: 4,
        active_frames: 20,
        recovery_frames: 10,
        cooldown_frames: 210,
        priority: 60,
        step_window_frames: 14,
        perfect_gap_min: 4,
        perfect_gap_max: 9,
        stamina_cost: 15.0,
        zone_gain: 14.0,
        requires_ball: true,
        max_rim_distance: Some(9.8),
        archetype: Some(ArchetypeId::Sharpshooter),
    },
    // 4. Eclipse Counter (priority 58, All-Rounder): C -> Q -> E -> Shift (on-ball OR off-ball!)
    MoveDef {
        id: MoveId::EclipseCounter,
        sequence: &[
            InputSymbol::C,
            InputSymbol::Q,
            InputSymbol::E,
            InputSymbol::Shift,
        ],
        startup_frames: 4,
        active_frames: 18,
        recovery_frames: 10,
        cooldown_frames: 180,
        priority: 58,
        step_window_frames: 14,
        perfect_gap_min: 4,
        perfect_gap_max: 9,
        stamina_cost: 13.0,
        zone_gain: 14.0,
        requires_ball: false,
        max_rim_distance: None,
        archetype: Some(ArchetypeId::AllRounder),
    },
    // 5. Mirage Thread (priority 55, Playmaker): Q -> E -> RMB
    MoveDef {
        id: MoveId::MirageThread,
        sequence: &[InputSymbol::Q, InputSymbol::E, InputSymbol::Rmb],
        startup_frames: 4,
        active_frames: 14,
        recovery_frames: 10,
        cooldown_frames: 180,
        priority: 55,
        step_window_frames: 14,
        perfect_gap_min: 4,
        perfect_gap_max: 9,
        stamina_cost: 12.0,
        zone_gain: 14.0,
        requires_ball: true,
        max_rim_distance: None,
        archetype: Some(ArchetypeId::Playmaker),
    },
    // 6. Volt Dash (priority 55, Speedster): Q -> Shift -> Q
    MoveDef {
        id: MoveId::VoltDash,
        sequence: &[InputSymbol::Q, InputSymbol::Shift, InputSymbol::Q],
        startup_frames: 3,
        active_frames: 15,
        recovery_frames: 8,
        cooldown_frames: 150,
        priority: 55,
        step_window_frames: 14,
        perfect_gap_min: 4,
        perfect_gap_max: 9,
        stamina_cost: 10.0,
        zone_gain: 12.0,
        requires_ball: true,
        max_rim_distance: None,
        archetype: Some(ArchetypeId::Speedster),
    },
    // 7. Mirror Step (priority 50): Q -> Q -> E -> R
    MoveDef {
        id: MoveId::MirrorStep,
        sequence: &[
            InputSymbol::Q,
            InputSymbol::Q,
            InputSymbol::E,
            InputSymbol::R,
        ],
        startup_frames: 4,
        active_frames: 16,
        recovery_frames: 10,
        cooldown_frames: 180,
        priority: 50,
        step_window_frames: 14,
        perfect_gap_min: 4,
        perfect_gap_max: 9,
        stamina_cost: 14.0,
        zone_gain: 12.0,
        requires_ball: true,
        max_rim_distance: None,
        archetype: None,
    },
    // 8. Ankle Breaker (priority 45): E -> Q -> E -> LMB
    MoveDef {
        id: MoveId::AnkleBreaker,
        sequence: &[
            InputSymbol::E,
            InputSymbol::Q,
            InputSymbol::E,
            InputSymbol::Lmb,
        ],
        startup_frames: 5,
        active_frames: 14,
        recovery_frames: 12,
        cooldown_frames: 210,
        priority: 45,
        step_window_frames: 14,
        perfect_gap_min: 4,
        perfect_gap_max: 9,
        stamina_cost: 14.0,
        zone_gain: 14.0,
        requires_ball: true,
        max_rim_distance: None,
        archetype: None,
    },
    // 9. Phantom Drive (priority 40): Q -> E -> Q -> Shift
    MoveDef {
        id: MoveId::PhantomDrive,
        sequence: &[
            InputSymbol::Q,
            InputSymbol::E,
            InputSymbol::Q,
            InputSymbol::Shift,
        ],
        startup_frames: 4,
        active_frames: 18,
        recovery_frames: 10,
        cooldown_frames: 180,
        priority: 40,
        step_window_frames: 14,
        perfect_gap_min: 4,
        perfect_gap_max: 9,
        stamina_cost: 16.0,
        zone_gain: 12.0,
        requires_ball: true,
        max_rim_distance: None,
        archetype: None,
    },
];

#[derive(Debug, Clone, Copy)]
struct BufferedToken {
    symbol: InputSymbol,
    frame: u64,
    token_id: u64,
}

#[derive(Debug, Clone, Copy, Default)]
struct FrameSlot {
    valid: bool,
    frame: u64,
    local_dir: Vec2,
}

#[derive(Debug, Clone, Copy)]
pub struct ComboTriggerResult {
    pub move_def: MoveDef,
    pub is_perfect: bool,
    pub is_ex: bool,
    pub stamina_cost: f32,
    pub potency_mult: f32,
    pub combo_tier: u8,
}

#[derive(Debug, Clone)]
pub struct ComboValidator {
    current_frame: u64,
    prev_buttons: u16,
    prev_dir: Option<InputSymbol>,
    next_token_id: u64,
    last_consumed_token_id: u64,
    tokens: VecDeque<BufferedToken>,
    frame_ring: Vec<FrameSlot>,
    cooldowns: HashMap<MoveId, u16>,
    active_move: MoveId,
    active_frames_left: u16,
    chain_count: u8,
    chain_reset_timer: u16,
}

impl Default for ComboValidator {
    fn default() -> Self {
        Self::new()
    }
}

impl ComboValidator {
    pub fn new() -> Self {
        Self {
            current_frame: 0,
            prev_buttons: 0,
            prev_dir: None,
            next_token_id: 1,
            last_consumed_token_id: 0,
            tokens: VecDeque::with_capacity(INPUT_BUFFER_CAPACITY),
            frame_ring: vec![FrameSlot::default(); INPUT_BUFFER_CAPACITY],
            cooldowns: HashMap::new(),
            active_move: MoveId::None,
            active_frames_left: 0,
            chain_count: 0,
            chain_reset_timer: 0,
        }
    }

    pub fn reset(&mut self) {
        self.current_frame = 0;
        self.prev_buttons = 0;
        self.prev_dir = None;
        self.next_token_id = 1;
        self.last_consumed_token_id = 0;
        self.tokens.clear();
        for s in &mut self.frame_ring {
            *s = FrameSlot::default();
        }
        self.cooldowns.clear();
        self.active_move = MoveId::None;
        self.active_frames_left = 0;
        self.chain_count = 0;
        self.chain_reset_timer = 0;
    }

    pub fn active_move(&self) -> MoveId {
        if self.active_frames_left > 0 {
            self.active_move
        } else {
            MoveId::None
        }
    }

    pub fn is_on_cooldown(&self, id: MoveId) -> bool {
        self.cooldowns.get(&id).copied().unwrap_or(0) > 0
    }

    pub fn cooldown_remaining(&self, id: MoveId) -> u16 {
        self.cooldowns.get(&id).copied().unwrap_or(0)
    }

    pub fn cooldown_flags(&self, archetype: ArchetypeId) -> u16 {
        let mut flags = 0u16;
        if self.is_on_cooldown(MoveId::PhantomDrive) {
            flags |= CD_PHANTOM_DRIVE;
        }
        if self.is_on_cooldown(MoveId::MeteorDunk) {
            flags |= CD_METEOR_DUNK;
        }
        if self.is_on_cooldown(MoveId::AnkleBreaker) {
            flags |= CD_ANKLE_BREAKER;
        }
        if self.is_on_cooldown(MoveId::MirrorStep) {
            flags |= CD_MIRROR_STEP;
        }
        let unique = match archetype {
            ArchetypeId::Speedster => MoveId::VoltDash,
            ArchetypeId::Sharpshooter => MoveId::StarlightHighArc,
            ArchetypeId::Playmaker => MoveId::MirageThread,
            ArchetypeId::Powerhouse => MoveId::TectonicSlam,
            ArchetypeId::AllRounder => MoveId::EclipseCounter,
        };
        if self.is_on_cooldown(unique) {
            flags |= CD_UNIQUE_SKILL;
        }
        flags
    }

    fn local_dir_to_cardinal(dir: Vec2) -> Option<InputSymbol> {
        if dir.length_sq() < DIR_DEADZONE * DIR_DEADZONE {
            return None;
        }
        if dir.y.abs() >= dir.x.abs() {
            if dir.y > 0.0 {
                Some(InputSymbol::W)
            } else {
                Some(InputSymbol::S)
            }
        } else if dir.x > 0.0 {
            Some(InputSymbol::D)
        } else {
            Some(InputSymbol::A)
        }
    }

    fn push_token(&mut self, sym: InputSymbol) {
        let id = self.next_token_id;
        self.next_token_id += 1;
        self.tokens.push_back(BufferedToken {
            symbol: sym,
            frame: self.current_frame,
            token_id: id,
        });
    }

    fn is_dir_held_in_span(&self, sym: InputSymbol, start_f: u64, end_f: u64) -> bool {
        let lo = start_f.min(end_f);
        let hi = start_f.max(end_f);
        let min_valid = self
            .current_frame
            .saturating_sub((INPUT_BUFFER_CAPACITY - 1) as u64);
        let from = lo.max(min_valid);
        for f in from..=hi {
            let slot = self.frame_ring[(f as usize) % INPUT_BUFFER_CAPACITY];
            if slot.valid && slot.frame == f && sym.held_in_vec(slot.local_dir) {
                return true;
            }
        }
        false
    }

    /// Steps 1 fixed 60 Hz frame, recording rising edges, decrementing cooldowns, and
    /// validating any matched combo against archetype ownership, cooldowns, stamina, ball state, and rim range.
    #[allow(clippy::too_many_arguments)]
    pub fn step_frame(
        &mut self,
        buttons: u16,
        local_dir: Vec2,
        archetype: ArchetypeId,
        has_ball: bool,
        stamina: f32,
        dist_to_rim: f32,
        zone_active: bool,
        is_stunned: bool,
    ) -> Option<ComboTriggerResult> {
        self.current_frame += 1;

        // Decrement cooldowns & active move timer
        for cd in self.cooldowns.values_mut() {
            if *cd > 0 {
                *cd -= 1;
            }
        }
        if self.active_frames_left > 0 {
            self.active_frames_left -= 1;
            if self.active_frames_left == 0 {
                self.active_move = MoveId::None;
            }
        }
        if self.chain_reset_timer > 0 {
            self.chain_reset_timer -= 1;
            if self.chain_reset_timer == 0 {
                self.chain_count = 0;
            }
        }

        // Write ring slot
        let idx = (self.current_frame as usize) % INPUT_BUFFER_CAPACITY;
        self.frame_ring[idx] = FrameSlot {
            valid: true,
            frame: self.current_frame,
            local_dir,
        };

        let just_pressed = buttons & !self.prev_buttons;
        let cur_dir = Self::local_dir_to_cardinal(local_dir);

        // Emit Shift rising edge first so simultaneous Shift+W preserves Shift -> W order
        if (just_pressed & BTN_SPRINT) != 0 {
            self.push_token(InputSymbol::Shift);
        }
        if let Some(d) = cur_dir {
            if Some(d) != self.prev_dir {
                self.push_token(d);
            }
        }

        const BUTTON_ORDER: &[(u16, InputSymbol)] = &[
            (BTN_SKILL_Q, InputSymbol::Q),
            (BTN_SKILL_E, InputSymbol::E),
            (BTN_SKILL_R, InputSymbol::R),
            (BTN_JUMP, InputSymbol::Space),
            (BTN_SHOOT, InputSymbol::Lmb),
            (BTN_PASS, InputSymbol::Rmb),
            (BTN_STEAL, InputSymbol::F),
            (BTN_STANCE, InputSymbol::C),
            (BTN_ZONE, InputSymbol::V),
        ];
        for &(bit, sym) in BUTTON_ORDER {
            if (just_pressed & bit) != 0 {
                self.push_token(sym);
            }
        }

        self.prev_buttons = buttons;
        self.prev_dir = cur_dir;

        // Prune expired tokens
        let min_frame = self
            .current_frame
            .saturating_sub((INPUT_BUFFER_CAPACITY - 1) as u64);
        while let Some(front) = self.tokens.front() {
            if front.frame < min_frame || self.tokens.len() > INPUT_BUFFER_CAPACITY {
                self.tokens.pop_front();
            } else {
                break;
            }
        }

        if is_stunned {
            return None;
        }

        // Evaluate candidates in strict deterministic priority order
        for def in COMBO_DEFS {
            // 1. Authoritative archetype ownership check
            if let Some(req_arch) = def.archetype {
                if req_arch != archetype {
                    continue;
                }
            }
            // 2. Ball possession check
            if def.requires_ball && !has_ball {
                continue;
            }
            // 3. Server-side cooldown enforcement
            if self.is_on_cooldown(def.id) {
                continue;
            }
            // 4. Max rim distance check (Meteor Dunk EX extends 5.5m -> 6.5m)
            if let Some(base_max_r) = def.max_rim_distance {
                let eff_max_r = if def.id == MoveId::MeteorDunk && zone_active {
                    6.5
                } else {
                    base_max_r
                };
                if dist_to_rim > eff_max_r + 0.15 {
                    continue;
                }
            }

            // 5. Sequence match against unconsumed tokens
            if let Some((last_tid, is_perfect)) = self.match_sequence(def) {
                // 6. Server-side stamina check (with Zone 0.75x and Perfect 20% refund)
                let zone_mult = if zone_active {
                    ZONE_STAMINA_COST_MULT
                } else {
                    1.0
                };
                let perf_refund = if is_perfect {
                    1.0 - PERFECT_STAMINA_REFUND
                } else {
                    1.0
                };
                let eff_cost = def.stamina_cost * zone_mult * perf_refund;
                if stamina + 1e-4 < eff_cost {
                    continue;
                }

                // Consume tokens, apply authoritative cooldown & chain state
                self.last_consumed_token_id = last_tid;
                self.cooldowns.insert(def.id, def.cooldown_frames);
                self.active_move = def.id;
                self.active_frames_left =
                    def.startup_frames + def.active_frames + def.recovery_frames;
                self.chain_count = self.chain_count.saturating_add(1).min(5);
                self.chain_reset_timer = 90;

                let potency_mult = (if is_perfect {
                    PERFECT_POTENCY_MULT
                } else {
                    1.0
                }) * (if zone_active { 1.15 } else { 1.0 });

                return Some(ComboTriggerResult {
                    move_def: *def,
                    is_perfect,
                    is_ex: zone_active,
                    stamina_cost: eff_cost,
                    potency_mult,
                    combo_tier: self.chain_count,
                });
            }
        }

        None
    }

    fn match_sequence(&self, def: &MoveDef) -> Option<(u64, bool)> {
        let seq = def.sequence;
        if seq.is_empty() || self.tokens.is_empty() {
            return None;
        }
        let final_sym = *seq.last()?;

        // Final token must have occurred on THIS tick (age == 0) and be unconsumed
        for idx in (0..self.tokens.len()).rev() {
            let anchor = self.tokens[idx];
            if anchor.frame < self.current_frame {
                break;
            }
            if anchor.token_id <= self.last_consumed_token_id {
                break;
            }
            if anchor.symbol != final_sym {
                continue;
            }

            if seq.len() == 1 {
                return Some((anchor.token_id, false));
            }

            let mut matched_frames = Vec::with_capacity(seq.len());
            let mut used_ids = Vec::with_capacity(seq.len());
            used_ids.push(anchor.token_id);

            if self.match_prefix(
                seq,
                seq.len() - 2,
                anchor.frame,
                def.step_window_frames as u64,
                &mut used_ids,
                &mut matched_frames,
            ) {
                matched_frames.push((anchor.frame, false));
                // Evaluate perfect timing from real (non-synthetic) consecutive frame gaps
                let real_frames: Vec<u64> = matched_frames
                    .iter()
                    .filter(|(_, synthetic)| !*synthetic)
                    .map(|(f, _)| *f)
                    .collect();
                let is_perfect = if real_frames.len() >= 2 {
                    let mut total_gap = 0u64;
                    let mut all_ok = true;
                    for pair in real_frames.windows(2) {
                        let g = pair[1].saturating_sub(pair[0]);
                        total_gap += g;
                        if g < def.perfect_gap_min as u64 || g > def.perfect_gap_max as u64 {
                            all_ok = false;
                        }
                    }
                    let avg = total_gap as f32 / (real_frames.len() - 1) as f32;
                    all_ok
                        || (avg >= def.perfect_gap_min as f32 && avg <= def.perfect_gap_max as f32)
                } else {
                    false
                };
                return Some((anchor.token_id, is_perfect));
            }
        }
        None
    }

    fn match_prefix(
        &self,
        seq: &[InputSymbol],
        step_idx: usize,
        next_frame: u64,
        max_window: u64,
        used_ids: &mut Vec<u64>,
        out_frames: &mut Vec<(u64, bool)>,
    ) -> bool {
        let target = seq[step_idx];
        let mut blocked_at_frame: Option<u64> = None;

        // Path 1: Discrete buffered token
        for j in (0..self.tokens.len()).rev() {
            let tok = self.tokens[j];
            if tok.frame > next_frame {
                continue;
            }
            if used_ids.contains(&tok.token_id) {
                continue;
            }
            if tok.token_id <= self.last_consumed_token_id {
                break;
            }
            if let Some(bf) = blocked_at_frame {
                if tok.frame < bf {
                    break;
                }
            }
            if next_frame.saturating_sub(tok.frame) > max_window {
                break;
            }

            if tok.symbol == target {
                used_ids.push(tok.token_id);
                let prev_len = out_frames.len();
                let ok = if step_idx == 0 {
                    true
                } else {
                    self.match_prefix(
                        seq,
                        step_idx - 1,
                        tok.frame,
                        max_window,
                        used_ids,
                        out_frames,
                    )
                };
                if ok {
                    out_frames.push((tok.frame, false));
                    return true;
                }
                out_frames.truncate(prev_len);
                used_ids.pop();
            } else if !tok.symbol.is_direction() && tok.frame < next_frame {
                blocked_at_frame = Some(blocked_at_frame.map_or(tok.frame, |b| b.max(tok.frame)));
            }
        }

        // Path 2: Continuously held direction across buttons (e.g. holding W during Meteor Dunk)
        if target.is_direction() {
            if step_idx == 0 {
                if self.is_dir_held_in_span(target, next_frame.saturating_sub(1), next_frame) {
                    out_frames.push((next_frame, true));
                    return true;
                }
            } else {
                let prev_len = out_frames.len();
                if self.match_prefix(
                    seq,
                    step_idx - 1,
                    next_frame,
                    max_window,
                    used_ids,
                    out_frames,
                ) {
                    if let Some(&(prev_frame, _)) = out_frames.last() {
                        if self.is_dir_held_in_span(target, prev_frame, next_frame) {
                            let mid = (prev_frame + next_frame) / 2;
                            out_frames.push((mid, true));
                            return true;
                        }
                    }
                }
                out_frames.truncate(prev_len);
            }
        }

        false
    }
}
