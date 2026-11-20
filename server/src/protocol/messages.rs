use std::f32::consts::{PI, TAU};

pub const PROTOCOL_MAGIC: u16 = 0x5043; // "PC"
pub const PROTOCOL_VERSION: u8 = 1;
pub const HEADER_SIZE: usize = 16;
pub const MAX_INPUT_BATCH: usize = 4;
pub const MAX_PLAYERS: usize = 6;

pub const AXIS_SCALE: f32 = 10_000.0;
pub const YAW_SCALE: f32 = 10_000.0;
pub const POS_VEL_SCALE: f32 = 100.0;
pub const METER_SCALE: f32 = 2.0;

// Canonical PlayerInputFrame button bitmasks (ARCHITECTURE.md Section 5.2)
pub const BTN_SPRINT: u16 = 1 << 0; // 1
pub const BTN_JUMP: u16 = 1 << 1; // 2
pub const BTN_SHOOT: u16 = 1 << 2; // 4
pub const BTN_PASS: u16 = 1 << 3; // 8
pub const BTN_SKILL_Q: u16 = 1 << 4; // 16
pub const BTN_SKILL_E: u16 = 1 << 5; // 32
pub const BTN_SKILL_R: u16 = 1 << 6; // 64
pub const BTN_STEAL: u16 = 1 << 7; // 128
pub const BTN_ZONE: u16 = 1 << 8; // 256
pub const BTN_STANCE: u16 = 1 << 9; // 512

// Message opcodes (0x01..=0x0A)
pub const MSG_HELLO_JOIN: u8 = 0x01;
pub const MSG_WELCOME_JOINED: u8 = 0x02;
pub const MSG_CLIENT_INPUT_BATCH: u8 = 0x03;
pub const MSG_SERVER_WORLD_SNAPSHOT: u8 = 0x04;
pub const MSG_RELIABLE_MATCH_EVENT: u8 = 0x05;
pub const MSG_EVENT_ACK: u8 = 0x06;
pub const MSG_PING: u8 = 0x07;
pub const MSG_PONG: u8 = 0x08;
pub const MSG_RECONNECT_REQUEST: u8 = 0x09;
pub const MSG_SPECTATOR_JOIN: u8 = 0x0A;

// Player state flags in QuantizedPlayerState
pub const STATE_GROUNDED: u16 = 1 << 0;
pub const STATE_SPRINTING: u16 = 1 << 1;
pub const STATE_DEFENSIVE_STANCE: u16 = 1 << 2;
pub const STATE_ZONE_ACTIVE: u16 = 1 << 3;
pub const STATE_ANKLE_BROKEN: u16 = 1 << 4;
pub const STATE_CHARGING_SHOT: u16 = 1 << 5;
pub const STATE_DUNKING: u16 = 1 << 6;
pub const STATE_STEAL_STARTUP: u16 = 1 << 7;
pub const STATE_STEAL_ACTIVE: u16 = 1 << 8;
pub const STATE_STEAL_WHIFF_RECOVERY: u16 = 1 << 9;
pub const STATE_BLOCK_RECOVERY: u16 = 1 << 10;
pub const STATE_PHANTOM_PHASING: u16 = 1 << 11;
pub const STATE_STEAL_SHIELDED: u16 = 1 << 12;
pub const STATE_ARMORED: u16 = 1 << 13;
pub const STATE_DISCONNECTED_GRACE: u16 = 1 << 14;
pub const STATE_DRIBBLE_HAND_RIGHT: u16 = 1 << 15;

// Cooldown / buff flags in QuantizedPlayerState
pub const CD_PHANTOM_DRIVE: u16 = 1 << 0;
pub const CD_METEOR_DUNK: u16 = 1 << 1;
pub const CD_ANKLE_BREAKER: u16 = 1 << 2;
pub const CD_MIRROR_STEP: u16 = 1 << 3;
pub const CD_UNIQUE_SKILL: u16 = 1 << 4;
pub const CD_STEAL: u16 = 1 << 5;
pub const CD_BLOCK: u16 = 1 << 6;
pub const CD_DRIBBLE_NORMAL: u16 = 1 << 7;
pub const BUFF_DEFENSE_COUNTER: u16 = 1 << 8;
pub const BUFF_SHOT_BONUS: u16 = 1 << 9;

// Reliable event kind codes
pub const EVENT_SCORE: u8 = 1;
pub const EVENT_POSSESSION: u8 = 2;
pub const EVENT_COMBO: u8 = 3;
pub const EVENT_STEAL: u8 = 4;
pub const EVENT_BLOCK: u8 = 5;
pub const EVENT_ANKLE_BREAK: u8 = 6;
pub const EVENT_ZONE: u8 = 7;
pub const EVENT_MATCH_END: u8 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacketHeader {
    pub magic: u16,
    pub version: u8,
    pub msg_type: u8,
    pub seq: u32,
    pub ack: u32,
    pub ack_bits: u32,
}

impl PacketHeader {
    pub fn new(msg_type: u8, seq: u32, ack: u32, ack_bits: u32) -> Self {
        Self {
            magic: PROTOCOL_MAGIC,
            version: PROTOCOL_VERSION,
            msg_type,
            seq,
            ack,
            ack_bits,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet {
    pub header: PacketHeader,
    pub payload: NetMessage,
}

impl Packet {
    pub fn new(seq: u32, ack: u32, ack_bits: u32, payload: NetMessage) -> Self {
        let msg_type = payload.msg_type();
        Self {
            header: PacketHeader::new(msg_type, seq, ack, ack_bits),
            payload,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NetMessage {
    HelloJoin(HelloJoinMsg),
    WelcomeJoined(WelcomeJoinedMsg),
    ClientInputBatch(ClientInputBatchMsg),
    ServerWorldSnapshot(ServerWorldSnapshotMsg),
    ReliableMatchEvent(ReliableMatchEventMsg),
    EventAck(EventAckMsg),
    Ping(PingMsg),
    Pong(PongMsg),
    ReconnectRequest(ReconnectRequestMsg),
    SpectatorJoin(SpectatorJoinMsg),
}

impl NetMessage {
    pub fn msg_type(&self) -> u8 {
        match self {
            NetMessage::HelloJoin(_) => MSG_HELLO_JOIN,
            NetMessage::WelcomeJoined(_) => MSG_WELCOME_JOINED,
            NetMessage::ClientInputBatch(_) => MSG_CLIENT_INPUT_BATCH,
            NetMessage::ServerWorldSnapshot(_) => MSG_SERVER_WORLD_SNAPSHOT,
            NetMessage::ReliableMatchEvent(_) => MSG_RELIABLE_MATCH_EVENT,
            NetMessage::EventAck(_) => MSG_EVENT_ACK,
            NetMessage::Ping(_) => MSG_PING,
            NetMessage::Pong(_) => MSG_PONG,
            NetMessage::ReconnectRequest(_) => MSG_RECONNECT_REQUEST,
            NetMessage::SpectatorJoin(_) => MSG_SPECTATOR_JOIN,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HelloJoinMsg {
    pub username: String,
    pub archetype_id: u8,
    pub room_id: String,
    pub auth_token: String,
    pub preferred_team: u8, // 0 = Team A, 1 = Team B, 255 = Auto
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WelcomeJoinedMsg {
    pub player_id: u32,
    pub team_id: u8,
    pub assigned_slot: u8,
    pub archetype_id: u8,
    pub session_token: u64,
    pub server_tick: u32,
    pub tick_rate: u16,
    pub snapshot_rate: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PlayerInputFrameWire {
    pub seq: u32,
    pub tick: u32,
    pub move_x_i16: i16,
    pub move_z_i16: i16,
    pub local_x_i16: i16,
    pub local_y_i16: i16,
    pub buttons: u16,
    pub aim_yaw_i16: i16,
}

impl PlayerInputFrameWire {
    pub fn from_floats(
        seq: u32,
        tick: u32,
        move_x: f32,
        move_z: f32,
        local_x: f32,
        local_y: f32,
        buttons: u16,
        aim_yaw: f32,
    ) -> Self {
        Self {
            seq,
            tick,
            move_x_i16: quantize_axis(move_x),
            move_z_i16: quantize_axis(move_z),
            local_x_i16: quantize_axis(local_x),
            local_y_i16: quantize_axis(local_y),
            buttons,
            aim_yaw_i16: quantize_yaw(aim_yaw),
        }
    }

    pub fn move_x(&self) -> f32 {
        dequantize_axis(self.move_x_i16)
    }

    pub fn move_z(&self) -> f32 {
        dequantize_axis(self.move_z_i16)
    }

    pub fn local_x(&self) -> f32 {
        dequantize_axis(self.local_x_i16)
    }

    pub fn local_y(&self) -> f32 {
        dequantize_axis(self.local_y_i16)
    }

    pub fn aim_yaw(&self) -> f32 {
        dequantize_yaw(self.aim_yaw_i16)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientInputBatchMsg {
    pub session_token: u64,
    pub frames: Vec<PlayerInputFrameWire>, // 1..=4
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct QuantizedPlayerState {
    pub player_id: u16,
    pub last_processed_input_seq: u32,
    pub pos_x: i16,
    pub pos_y: i16,
    pub pos_z: i16,
    pub vel_x: i16,
    pub vel_y: i16,
    pub vel_z: i16,
    pub yaw: i16,
    pub stamina_u8: u8,
    pub zone_u8: u8,
    pub balance_u8: u8,
    pub team_id: u8,
    pub slot: u8,
    pub archetype_id: u8,
    pub state_flags: u16,
    pub cooldown_flags: u16,
    pub active_move_id: u8,
}

impl QuantizedPlayerState {
    pub fn pos(&self) -> [f32; 3] {
        [
            dequantize_pos_vel(self.pos_x),
            dequantize_pos_vel(self.pos_y),
            dequantize_pos_vel(self.pos_z),
        ]
    }

    pub fn vel(&self) -> [f32; 3] {
        [
            dequantize_pos_vel(self.vel_x),
            dequantize_pos_vel(self.vel_y),
            dequantize_pos_vel(self.vel_z),
        ]
    }

    pub fn stamina(&self) -> f32 {
        dequantize_meter(self.stamina_u8)
    }

    pub fn zone(&self) -> f32 {
        dequantize_meter(self.zone_u8)
    }

    pub fn balance(&self) -> f32 {
        dequantize_meter(self.balance_u8)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerWorldSnapshotMsg {
    pub server_tick: u32,
    pub match_clock_ms: u32,
    pub shot_clock_ms: u16,
    pub score_a: u16,
    pub score_b: u16,
    pub possession_team: u8, // 0, 1, 255 = none
    pub carrier_id: u16,     // 0 = none
    pub ball_pos_x: i16,
    pub ball_pos_y: i16,
    pub ball_pos_z: i16,
    pub ball_vel_x: i16,
    pub ball_vel_y: i16,
    pub ball_vel_z: i16,
    pub ball_state: u8,
    pub players: Vec<QuantizedPlayerState>,
}

impl ServerWorldSnapshotMsg {
    pub fn ball_pos(&self) -> [f32; 3] {
        [
            dequantize_pos_vel(self.ball_pos_x),
            dequantize_pos_vel(self.ball_pos_y),
            dequantize_pos_vel(self.ball_pos_z),
        ]
    }

    pub fn ball_vel(&self) -> [f32; 3] {
        [
            dequantize_pos_vel(self.ball_vel_x),
            dequantize_pos_vel(self.ball_vel_y),
            dequantize_pos_vel(self.ball_vel_z),
        ]
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MatchEventPayload {
    Score {
        team_id: u8,
        delta: u8,
        is_three: bool,
        new_score: u16,
        scorer_id: u16,
    },
    Possession {
        team_id: u8,
        carrier_id: u16,
    },
    Combo {
        player_id: u16,
        move_id: u8,
        combo_tier: u8,
        is_perfect: bool,
        is_ex: bool,
    },
    Steal {
        stealer_id: u16,
        victim_id: u16,
        is_interception: bool,
        pos_x: i16,
        pos_y: i16,
        pos_z: i16,
    },
    Block {
        blocker_id: u16,
        shooter_id: u16,
        pos_x: i16,
        pos_y: i16,
        pos_z: i16,
    },
    AnkleBreak {
        victim_id: u16,
        attacker_id: u16,
        pos_x: i16,
        pos_y: i16,
        pos_z: i16,
    },
    Zone {
        player_id: u16,
        activated: bool,
        duration_ms: u16,
    },
    MatchEnd {
        winner_team: u8, // 0, 1, 255 = draw
        score_a: u16,
        score_b: u16,
    },
}

impl MatchEventPayload {
    pub fn kind_code(&self) -> u8 {
        match self {
            MatchEventPayload::Score { .. } => EVENT_SCORE,
            MatchEventPayload::Possession { .. } => EVENT_POSSESSION,
            MatchEventPayload::Combo { .. } => EVENT_COMBO,
            MatchEventPayload::Steal { .. } => EVENT_STEAL,
            MatchEventPayload::Block { .. } => EVENT_BLOCK,
            MatchEventPayload::AnkleBreak { .. } => EVENT_ANKLE_BREAK,
            MatchEventPayload::Zone { .. } => EVENT_ZONE,
            MatchEventPayload::MatchEnd { .. } => EVENT_MATCH_END,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReliableMatchEventMsg {
    pub event_id: u32,
    pub server_tick: u32,
    pub event: MatchEventPayload,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventAckMsg {
    pub session_token: u64,
    pub event_id: u32,
    pub ack_mask: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PingMsg {
    pub session_token: u64,
    pub client_time_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PongMsg {
    pub client_time_ms: u64,
    pub server_tick: u32,
    pub server_time_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReconnectRequestMsg {
    pub session_token: u64,
    pub last_acked_event_id: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpectatorJoinMsg {
    pub room_id: String,
    pub spectator_name: String,
}

// ============================================================================
// Quantization Helpers (byte-exact with client/scripts/net/protocol_serializer.gd)
// ============================================================================

pub fn wrap_angle(rad: f32) -> f32 {
    if !rad.is_finite() {
        return 0.0;
    }
    let mut a = (rad + PI).rem_euclid(TAU) - PI;
    if a < -PI {
        a += TAU;
    }
    a
}

pub fn quantize_axis(v: f32) -> i16 {
    if !v.is_finite() {
        return 0;
    }
    let clamped = v.clamp(-1.0, 1.0);
    (clamped * AXIS_SCALE).round().clamp(-10_000.0, 10_000.0) as i16
}

pub fn dequantize_axis(q: i16) -> f32 {
    (q as f32 / AXIS_SCALE).clamp(-1.0, 1.0)
}

pub fn quantize_yaw(rad: f32) -> i16 {
    let w = wrap_angle(rad);
    (w * YAW_SCALE).round().clamp(-31_416.0, 31_416.0) as i16
}

pub fn dequantize_yaw(q: i16) -> f32 {
    q as f32 / YAW_SCALE
}

pub fn quantize_pos_vel(v: f32) -> i16 {
    if !v.is_finite() {
        return 0;
    }
    (v * POS_VEL_SCALE).round().clamp(-32_767.0, 32_767.0) as i16
}

pub fn dequantize_pos_vel(q: i16) -> f32 {
    q as f32 / POS_VEL_SCALE
}

pub fn quantize_meter(v: f32) -> u8 {
    if !v.is_finite() {
        return 0;
    }
    (v.clamp(0.0, 127.5) * METER_SCALE)
        .round()
        .clamp(0.0, 255.0) as u8
}

pub fn dequantize_meter(q: u8) -> f32 {
    q as f32 / METER_SCALE
}

pub fn pack_team_slot_arch(team_id: u8, slot: u8, archetype_id: u8) -> u8 {
    (team_id & 0x01) | ((slot & 0x07) << 1) | ((archetype_id & 0x0F) << 4)
}

pub fn unpack_team_slot_arch(packed: u8) -> (u8, u8, u8) {
    (packed & 0x01, (packed >> 1) & 0x07, (packed >> 4) & 0x0F)
}
