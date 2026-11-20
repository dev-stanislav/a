use std::collections::{BTreeMap, VecDeque};
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use crate::protocol::{
    EventAckMsg, MatchEventPayload, NetMessage, Packet, PlayerInputFrameWire,
    ReliableMatchEventMsg,
};
use crate::sim::ArchetypeId;

pub const MAX_PENDING_INPUTS: usize = 32;
pub const MAX_RELIABLE_RETRIES: u32 = 40;
pub const MAX_INPUTS_PER_TICK_CATCHUP: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Connected,
    DisconnectedGrace { disconnected_at: Instant },
}

#[derive(Debug, Clone)]
pub struct PendingReliableEvent {
    pub event_id: u32,
    pub server_tick: u32,
    pub payload: MatchEventPayload,
    pub last_sent: Instant,
    pub retries: u32,
}

#[derive(Debug, Clone)]
pub struct ClientSession {
    pub session_token: u64,
    pub player_id: u32, // 0 for spectators
    pub team_id: u8,    // 255 for spectators
    pub slot: u8,       // 255 for spectators
    pub username: String,
    pub archetype: ArchetypeId,
    pub room_id: String,
    pub is_spectator: bool,
    pub addr: SocketAddr,
    pub state: SessionState,

    // Transport packet sequencing & ack bitfield
    pub local_packet_seq: u32,
    pub remote_packet_seq: u32,
    pub remote_ack_bits: u32,
    pub last_packet_received: Instant,
    pub estimated_rtt_ms: f32,

    // Input deduplication & anti-flood burst cap
    pub last_processed_input_seq: u32,
    pub total_inputs_accepted: u64,
    pub total_inputs_processed: u64,
    pub ticks_since_join: u64,
    pending_inputs: BTreeMap<u32, PlayerInputFrameWire>,
    last_applied_input: Option<PlayerInputFrameWire>,

    // Reliable match events & history for reconnect replay
    pub highest_acked_event_id: u32,
    unacked_events: VecDeque<PendingReliableEvent>,
    event_history: VecDeque<(u32, u32, MatchEventPayload)>,

    // Metrics
    pub bytes_sent: u64,
    pub bytes_received: u64,
    pub packets_sent: u64,
    pub packets_received: u64,
}

impl ClientSession {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        session_token: u64,
        player_id: u32,
        team_id: u8,
        slot: u8,
        username: String,
        archetype: ArchetypeId,
        room_id: String,
        is_spectator: bool,
        addr: SocketAddr,
        now: Instant,
    ) -> Self {
        Self {
            session_token,
            player_id,
            team_id,
            slot,
            username,
            archetype,
            room_id,
            is_spectator,
            addr,
            state: SessionState::Connected,
            local_packet_seq: 0,
            remote_packet_seq: 0,
            remote_ack_bits: 0,
            last_packet_received: now,
            estimated_rtt_ms: 0.0,
            last_processed_input_seq: 0,
            total_inputs_accepted: 0,
            total_inputs_processed: 0,
            ticks_since_join: 0,
            pending_inputs: BTreeMap::new(),
            last_applied_input: None,
            highest_acked_event_id: 0,
            unacked_events: VecDeque::new(),
            event_history: VecDeque::with_capacity(64),
            bytes_sent: 0,
            bytes_received: 0,
            packets_sent: 0,
            packets_received: 0,
        }
    }

    pub fn is_connected(&self) -> bool {
        matches!(self.state, SessionState::Connected)
    }

    pub fn next_packet(&mut self, payload: NetMessage) -> Packet {
        self.local_packet_seq = self.local_packet_seq.wrapping_add(1).max(1);
        Packet::new(
            self.local_packet_seq,
            self.remote_packet_seq,
            self.remote_ack_bits,
            payload,
        )
    }

    /// Updates sequence/ack tracking upon receiving a UDP packet from this client.
    /// Returns `true` if the packet is fresh or within the 32-packet ack window (not duplicate).
    pub fn on_packet_received(&mut self, packet_seq: u32, byte_len: usize, now: Instant) -> bool {
        self.last_packet_received = now;
        self.packets_received += 1;
        self.bytes_received += byte_len as u64;

        if self.remote_packet_seq == 0 {
            self.remote_packet_seq = packet_seq;
            self.remote_ack_bits = 0;
            return true;
        }

        if packet_seq > self.remote_packet_seq {
            let shift = packet_seq - self.remote_packet_seq;
            if shift < 32 {
                self.remote_ack_bits = (self.remote_ack_bits << shift) | (1u32 << (shift - 1));
            } else {
                self.remote_ack_bits = 0;
            }
            self.remote_packet_seq = packet_seq;
            true
        } else if packet_seq == self.remote_packet_seq {
            false
        } else {
            let diff = self.remote_packet_seq - packet_seq;
            if diff <= 32 {
                let bit = 1u32 << (diff - 1);
                let already = (self.remote_ack_bits & bit) != 0;
                self.remote_ack_bits |= bit;
                !already
            } else {
                false
            }
        }
    }

    /// Deduplicates and buffers incoming `ClientInputBatch` frames (recovering up to 3 dropped packets!).
    /// Returns the number of brand-new input frames accepted.
    pub fn ingest_input_batch(&mut self, frames: &[PlayerInputFrameWire]) -> usize {
        let mut accepted = 0usize;
        for &frame in frames {
            // Drop stale / already processed inputs
            if frame.seq == 0 || frame.seq <= self.last_processed_input_seq {
                continue;
            }
            // Prevent unreasonable future seq jump spoofing
            if self.last_processed_input_seq > 0
                && frame.seq > self.last_processed_input_seq.saturating_add(120)
            {
                continue;
            }
            if !self.pending_inputs.contains_key(&frame.seq) {
                self.pending_inputs.insert(frame.seq, frame);
                accepted += 1;
                self.total_inputs_accepted += 1;
            }
        }
        // Cap queue length to prevent memory abuse
        while self.pending_inputs.len() > MAX_PENDING_INPUTS {
            if let Some(&first_key) = self.pending_inputs.keys().next() {
                self.pending_inputs.remove(&first_key);
            } else {
                break;
            }
        }
        accepted
    }

    /// Pops up to `MAX_INPUTS_PER_TICK_CATCHUP` sequential inputs to process on this 60 Hz tick,
    /// while enforcing anti-speedhack input pacing (`total_inputs_processed <= ticks_since_join + 6`).
    pub fn pop_inputs_for_tick(&mut self) -> Vec<PlayerInputFrameWire> {
        self.ticks_since_join += 1;
        let mut out = Vec::new();
        let max_allowed_total = self.ticks_since_join.saturating_add(6);

        while out.len() < MAX_INPUTS_PER_TICK_CATCHUP
            && self.total_inputs_processed < max_allowed_total
        {
            let next_key = match self.pending_inputs.keys().next().copied() {
                Some(k) => k,
                None => break,
            };
            if let Some(frame) = self.pending_inputs.remove(&next_key) {
                if frame.seq > self.last_processed_input_seq {
                    self.last_processed_input_seq = frame.seq;
                    self.total_inputs_processed += 1;
                    self.last_applied_input = Some(frame);
                    out.push(frame);
                }
            }
        }
        out
    }

    pub fn last_applied_input(&self) -> Option<PlayerInputFrameWire> {
        self.last_applied_input
    }

    pub fn pending_input_count(&self) -> usize {
        self.pending_inputs.len()
    }

    /// Enqueues a reliable match event for initial send & 200ms retry until ACKed.
    pub fn enqueue_reliable_event(
        &mut self,
        event_id: u32,
        server_tick: u32,
        payload: MatchEventPayload,
        now: Instant,
    ) -> ReliableMatchEventMsg {
        self.event_history
            .push_back((event_id, server_tick, payload.clone()));
        while self.event_history.len() > 64 {
            self.event_history.pop_front();
        }
        self.unacked_events.push_back(PendingReliableEvent {
            event_id,
            server_tick,
            payload: payload.clone(),
            last_sent: now,
            retries: 0,
        });
        ReliableMatchEventMsg {
            event_id,
            server_tick,
            event: payload,
        }
    }

    pub fn handle_event_ack(&mut self, ack: &EventAckMsg) {
        if ack.event_id > self.highest_acked_event_id {
            self.highest_acked_event_id = ack.event_id;
        }
        self.unacked_events.retain(|ev| {
            if ev.event_id == ack.event_id {
                return false;
            }
            if ev.event_id < ack.event_id {
                let diff = ack.event_id - ev.event_id;
                if diff <= 32 && (ack.ack_mask & (1u32 << (diff - 1))) != 0 {
                    return false;
                }
            }
            true
        });
    }

    /// Collects reliable events due for 200ms retransmission.
    pub fn collect_due_retransmissions(
        &mut self,
        now: Instant,
        retry_interval: Duration,
    ) -> Vec<ReliableMatchEventMsg> {
        if !self.is_connected() {
            return Vec::new();
        }
        let mut due = Vec::new();
        self.unacked_events.retain_mut(|ev| {
            if ev.retries >= MAX_RELIABLE_RETRIES {
                return false;
            }
            if now.duration_since(ev.last_sent) >= retry_interval {
                ev.last_sent = now;
                ev.retries += 1;
                due.push(ReliableMatchEventMsg {
                    event_id: ev.event_id,
                    server_tick: ev.server_tick,
                    event: ev.payload.clone(),
                });
            }
            true
        });
        due
    }

    /// Returns all reliable events after `last_acked_event_id` for reconnect replay.
    pub fn replay_events_after(
        &mut self,
        last_acked_event_id: u32,
        now: Instant,
    ) -> Vec<ReliableMatchEventMsg> {
        let mut out = Vec::new();
        for (eid, tick, payload) in &self.event_history {
            if *eid > last_acked_event_id {
                if !self.unacked_events.iter().any(|u| u.event_id == *eid) {
                    self.unacked_events.push_back(PendingReliableEvent {
                        event_id: *eid,
                        server_tick: *tick,
                        payload: payload.clone(),
                        last_sent: now,
                        retries: 0,
                    });
                }
                out.push(ReliableMatchEventMsg {
                    event_id: *eid,
                    server_tick: *tick,
                    event: payload.clone(),
                });
            }
        }
        out
    }

    pub fn unacked_event_count(&self) -> usize {
        self.unacked_events.len()
    }
}
