use std::net::SocketAddr;
use std::time::{Duration, Instant};

use rand::Rng;
use serde::Serialize;
use uuid::Uuid;

use crate::config::ServerConfig;
use crate::net::SessionManager;
use crate::protocol::{
    encode_packet, HelloJoinMsg, MatchEventPayload, NetMessage, SpectatorJoinMsg, WelcomeJoinedMsg,
};
use crate::sim::{ArchetypeId, SimWorld};

use super::{archetype_to_name, GameMode, ModeError, RoomState};

const ROOM_CODE_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

pub fn generate_room_code() -> String {
    let mut rng = rand::thread_rng();
    let mut out = String::with_capacity(6);
    for _ in 0..6 {
        let idx = rng.gen_range(0..ROOM_CODE_ALPHABET.len());
        out.push(ROOM_CODE_ALPHABET[idx] as char);
    }
    out
}

#[derive(Debug, Clone, Serialize)]
pub struct LobbyMember {
    pub member_id: String,
    pub username: String,
    pub team_id: u8, // 0 = Team A, 1 = Team B, 255 = Spectator
    pub archetype_id: u8,
    pub archetype: String,
    pub ready: bool,
    pub rematch_vote: bool,
    pub is_bot: bool,
    pub is_host: bool,
    pub player_id: Option<u32>,
    pub slot: Option<u8>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LobbyStateDto {
    pub room_id: u32,
    pub room_code: String,
    pub mode: String,
    pub state: String,
    pub is_private: bool,
    pub fill_bots: bool,
    pub match_number: u32,
    pub team_size: usize,
    pub max_players: usize,
    pub udp_port: u16,
    pub server_tick: u64,
    pub scores: [u16; 2],
    pub match_clock_ms: u32,
    pub shot_clock_ms: u16,
    pub world_player_count: usize,
    pub human_count: usize,
    pub spectator_count: usize,
    pub all_ready: bool,
    pub all_rematch_voted: bool,
    pub members: Vec<LobbyMember>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RoomSummaryDto {
    pub room_id: u32,
    pub room_code: Option<String>,
    pub mode: String,
    pub state: String,
    pub is_private: bool,
    pub fill_bots: bool,
    pub human_count: usize,
    pub player_count: usize,
    pub max_players: usize,
    pub spectator_count: usize,
    pub scores: [u16; 2],
    pub spectatable: bool,
}

#[derive(Debug, Clone)]
pub struct CompletedRoomParticipant {
    pub username: String,
    pub team: i16,
    pub archetype: String,
    pub points: i32,
    pub assists: i32,
    pub rebounds: i32,
    pub blocks: i32,
    pub steals: i32,
    pub zone_activations: i32,
}

#[derive(Debug, Clone)]
pub struct CompletedRoomMatch {
    pub room_id: u32,
    pub mode: String,
    pub team_a_score: i32,
    pub team_b_score: i32,
    pub duration_sec: i32,
    pub participants: Vec<CompletedRoomParticipant>,
}

#[derive(Debug, Clone, Default)]
pub struct LivePlayerStats {
    pub points: i32,
    pub assists: i32,
    pub rebounds: i32,
    pub blocks: i32,
    pub steals: i32,
    pub zone_activations: i32,
}

#[derive(Debug)]
pub struct MatchRoom {
    pub room_id: u32,
    pub room_code: String,
    pub mode: GameMode,
    pub state: RoomState,
    pub is_private: bool,
    pub fill_bots: bool,
    pub match_number: u32,
    pub is_default_arena: bool,

    pub members: Vec<LobbyMember>,
    pub live_stats: std::collections::HashMap<u32, LivePlayerStats>,
    pub spectator_tokens: Vec<String>,
    pub world: SimWorld,
    pub sessions: SessionManager,

    pub next_event_id: u32,
    pub total_snapshots_sent: u64,
    pub total_snapshot_bytes_sent: u64,
    pub last_snapshot_bytes: usize,
    pub total_events_emitted: u64,
    pub countdown_ticks_left: u16,
}

impl MatchRoom {
    pub fn new_default_arena(config: &ServerConfig) -> Self {
        Self {
            room_id: 0,
            room_code: "ARENA0".to_string(),
            mode: GameMode::ThreeVsThree,
            state: RoomState::InMatch,
            is_private: false,
            fill_bots: false,
            match_number: 1,
            is_default_arena: true,
            members: Vec::new(),
            live_stats: std::collections::HashMap::new(),
            spectator_tokens: Vec::new(),
            world: SimWorld::new(config.match_duration_secs, config.shot_clock_secs),
            sessions: SessionManager::new(),
            next_event_id: 1,
            total_snapshots_sent: 0,
            total_snapshot_bytes_sent: 0,
            last_snapshot_bytes: 0,
            total_events_emitted: 0,
            countdown_ticks_left: 0,
        }
    }

    pub fn new_lobby(
        room_id: u32,
        room_code: String,
        mode: GameMode,
        is_private: bool,
        fill_bots: bool,
        config: &ServerConfig,
    ) -> Self {
        Self {
            room_id,
            room_code,
            mode,
            state: RoomState::Lobby,
            is_private,
            fill_bots,
            match_number: 0,
            is_default_arena: false,
            members: Vec::new(),
            live_stats: std::collections::HashMap::new(),
            spectator_tokens: Vec::new(),
            world: SimWorld::new(config.match_duration_secs, config.shot_clock_secs),
            sessions: SessionManager::new(),
            next_event_id: 1,
            total_snapshots_sent: 0,
            total_snapshot_bytes_sent: 0,
            last_snapshot_bytes: 0,
            total_events_emitted: 0,
            countdown_ticks_left: 0,
        }
    }

    pub fn human_players(&self) -> impl Iterator<Item = &LobbyMember> {
        self.members
            .iter()
            .filter(|m| !m.is_bot && m.team_id <= 1)
    }

    pub fn team_human_count(&self, team_id: u8) -> usize {
        self.members
            .iter()
            .filter(|m| !m.is_bot && m.team_id == team_id)
            .count()
    }

    pub fn total_human_player_count(&self) -> usize {
        self.human_players().count()
    }

    pub fn spectator_count(&self) -> usize {
        let lobby_specs = self.members.iter().filter(|m| m.team_id == 255).count();
        let udp_specs = self
            .sessions
            .all_sessions()
            .filter(|s| s.is_spectator && s.is_connected())
            .count();
        lobby_specs.max(udp_specs)
    }

    pub fn add_member(
        &mut self,
        username: String,
        archetype: ArchetypeId,
        as_spectator: bool,
        is_host: bool,
        preferred_team: Option<u8>,
    ) -> Result<LobbyMember, ModeError> {
        let clean_name = if username.trim().is_empty() {
            "PhantomPlayer".to_string()
        } else {
            username.trim().to_string()
        };

        let team_id = if as_spectator {
            255
        } else {
            if self.state != RoomState::Lobby {
                return Err(ModeError::InvalidState(
                    "cannot join as player while match is already in progress".to_string(),
                ));
            }
            if self.total_human_player_count() >= self.mode.max_players() {
                return Err(ModeError::RoomFull);
            }
            let t0 = self.team_human_count(0);
            let t1 = self.team_human_count(1);
            let cap = self.mode.team_size();
            match preferred_team {
                Some(0) if t0 < cap => 0,
                Some(1) if t1 < cap => 1,
                _ => {
                    if t0 <= t1 && t0 < cap {
                        0
                    } else if t1 < cap {
                        1
                    } else {
                        return Err(ModeError::RoomFull);
                    }
                }
            }
        };

        let member = LobbyMember {
            member_id: format!("mem_{}", Uuid::new_v4().simple()),
            username: clean_name,
            team_id,
            archetype_id: archetype.as_u8(),
            archetype: archetype_to_name(archetype).to_string(),
            ready: false,
            rematch_vote: false,
            is_bot: false,
            is_host,
            player_id: None,
            slot: None,
        };
        self.members.push(member.clone());
        Ok(member)
    }

    pub fn configure_member(
        &mut self,
        member_id: &str,
        team: Option<u8>,
        archetype: Option<ArchetypeId>,
        fill_bots: Option<bool>,
    ) -> Result<(), ModeError> {
        if self.state != RoomState::Lobby {
            return Err(ModeError::InvalidState(
                "room config can only be changed in Lobby state".to_string(),
            ));
        }

        if let Some(fb) = fill_bots {
            self.fill_bots = fb;
        }

        let Some(idx) = self.members.iter().position(|m| m.member_id == member_id) else {
            return Err(ModeError::MemberNotFound);
        };

        if let Some(new_team) = team {
            let cur_team = self.members[idx].team_id;
            if new_team != cur_team {
                if new_team <= 1 {
                    let target_count = self.team_human_count(new_team);
                    if target_count >= self.mode.team_size() {
                        return Err(ModeError::TeamFull);
                    }
                } else if new_team != 255 {
                    return Err(ModeError::BadRequest(format!(
                        "invalid team id {new_team} (expected 0, 1, or 255)"
                    )));
                }
                self.members[idx].team_id = new_team;
                if new_team == 255 {
                    self.members[idx].ready = false;
                }
            }
        }

        if let Some(arch) = archetype {
            self.members[idx].archetype_id = arch.as_u8();
            self.members[idx].archetype = archetype_to_name(arch).to_string();
        }

        Ok(())
    }

    /// Updates a member's ready flag and transitions `Lobby -> InMatch` ONLY when
    /// all human members are `ready == true` AND roster has valid teams or `fill_bots == true`.
    pub fn set_member_ready(&mut self, member_id: &str, ready: bool) -> Result<bool, ModeError> {
        if self.state != RoomState::Lobby {
            return Err(ModeError::InvalidState(
                "ready check is only valid in Lobby state".to_string(),
            ));
        }
        let Some(member) = self.members.iter_mut().find(|m| m.member_id == member_id) else {
            return Err(ModeError::MemberNotFound);
        };
        if member.team_id > 1 {
            return Err(ModeError::BadRequest(
                "spectators cannot toggle player ready state".to_string(),
            ));
        }
        member.ready = ready;

        if self.can_start_match() {
            self.start_match_from_lobby();
            return Ok(true);
        }
        Ok(false)
    }

    pub fn all_humans_ready(&self) -> bool {
        let mut count = 0usize;
        for m in self.human_players() {
            count += 1;
            if !m.ready {
                return false;
            }
        }
        count > 0
    }

    pub fn can_start_match(&self) -> bool {
        if self.state != RoomState::Lobby {
            return false;
        }
        if !self.all_humans_ready() {
            return false;
        }
        let t0 = self.team_human_count(0);
        let t1 = self.team_human_count(1);
        if self.fill_bots {
            (t0 + t1) >= 1
        } else {
            t0 == self.mode.team_size() && t1 == self.mode.team_size()
        }
    }

    fn start_match_from_lobby(&mut self) {
        self.state = RoomState::InMatch;
        self.match_number += 1;
        self.live_stats.clear();

        // Fresh authoritative world preserving room match/shot clock durations
        let dur = self.world.match_duration_secs;
        let sc = self.world.shot_clock_duration;
        self.world = SimWorld::new(dur, sc);

        // Remove any previous bot entries from member list before regenerating
        self.members.retain(|m| !m.is_bot);

        // 1. Spawn all human members into their selected teams & archetypes
        for m in &mut self.members {
            m.rematch_vote = false;
            if m.team_id <= 1 {
                let arch = ArchetypeId::from_u8(m.archetype_id);
                if let Some((pid, tid, slot)) =
                    self.world.add_player(m.username.clone(), arch, m.team_id)
                {
                    m.team_id = tid;
                    m.player_id = Some(pid);
                    m.slot = Some(slot);
                }
            }
        }

        // 2. If fill_bots is enabled, spawn authoritative AI bots for every open team slot
        if self.fill_bots {
            let team_cap = self.mode.team_size();
            let bot_archetypes = [
                ArchetypeId::Speedster,
                ArchetypeId::Sharpshooter,
                ArchetypeId::Playmaker,
                ArchetypeId::Powerhouse,
                ArchetypeId::AllRounder,
            ];
            let mut bot_idx = 0usize;
            for team in 0..=1u8 {
                let current = self
                    .world
                    .players
                    .iter()
                    .filter(|p| p.team_id == team)
                    .count();
                for n in current..team_cap {
                    let arch = bot_archetypes[bot_idx % bot_archetypes.len()];
                    bot_idx += 1;
                    let bot_name = format!("Bot_{}_{}", if team == 0 { "A" } else { "B" }, n + 1);
                    if let Some((pid, tid, slot)) =
                        self.world.add_bot_player(bot_name.clone(), arch, team)
                    {
                        self.members.push(LobbyMember {
                            member_id: format!("bot_{}_{}", team, pid),
                            username: bot_name,
                            team_id: tid,
                            archetype_id: arch.as_u8(),
                            archetype: archetype_to_name(arch).to_string(),
                            ready: true,
                            rematch_vote: true,
                            is_bot: true,
                            is_host: false,
                            player_id: Some(pid),
                            slot: Some(slot),
                        });
                    }
                }
            }
        }
    }

    pub fn build_completed_match_summary(&self) -> CompletedRoomMatch {
        let elapsed_secs =
            ((self.world.match_duration_secs - self.world.match_clock_secs).round() as i32).max(1);
        let participants = self
            .members
            .iter()
            .filter(|m| !m.is_bot && m.team_id <= 1)
            .map(|m| {
                let st = m
                    .player_id
                    .and_then(|pid| self.live_stats.get(&pid))
                    .cloned()
                    .unwrap_or_default();
                CompletedRoomParticipant {
                    username: m.username.clone(),
                    team: m.team_id as i16,
                    archetype: m.archetype.clone(),
                    points: st.points,
                    assists: st.assists,
                    rebounds: st.rebounds,
                    blocks: st.blocks,
                    steals: st.steals,
                    zone_activations: st.zone_activations,
                }
            })
            .collect();

        CompletedRoomMatch {
            room_id: self.room_id,
            mode: self.mode.as_str().to_string(),
            team_a_score: self.world.scores[0] as i32,
            team_b_score: self.world.scores[1] as i32,
            duration_sec: elapsed_secs,
            participants,
        }
    }

    pub fn finish_match_now(
        &mut self,
        override_scores: Option<[u16; 2]>,
    ) -> Result<Option<CompletedRoomMatch>, ModeError> {
        if self.state != RoomState::InMatch && self.state != RoomState::PostMatch {
            return Err(ModeError::InvalidState(
                "match can only be finished from InMatch state".to_string(),
            ));
        }
        if self.state == RoomState::InMatch {
            self.world.force_end_match(override_scores);
            self.state = RoomState::PostMatch;
            for m in &mut self.members {
                if !m.is_bot {
                    m.rematch_vote = false;
                }
            }
            return Ok(Some(self.build_completed_match_summary()));
        }
        Ok(None)
    }

    pub fn all_humans_voted_rematch(&self) -> bool {
        let mut count = 0usize;
        for m in self.human_players() {
            count += 1;
            if !m.rematch_vote {
                return false;
            }
        }
        count > 0
    }

    /// Records a human member's rematch vote while in `PostMatch`.
    /// When ALL human players vote `true`, cleanly resets the same room's `SimWorld` & roster into `InMatch`!
    pub fn vote_rematch(&mut self, member_id: &str, vote: bool) -> Result<bool, ModeError> {
        if self.state != RoomState::PostMatch {
            return Err(ModeError::InvalidState(
                "rematch voting is only available in PostMatch state".to_string(),
            ));
        }
        let Some(member) = self.members.iter_mut().find(|m| m.member_id == member_id) else {
            return Err(ModeError::MemberNotFound);
        };
        if member.team_id > 1 || member.is_bot {
            return Err(ModeError::BadRequest(
                "only human players can vote for rematch".to_string(),
            ));
        }
        member.rematch_vote = vote;

        if self.all_humans_voted_rematch() {
            self.world.reset_for_rematch();
            self.live_stats.clear();
            self.state = RoomState::InMatch;
            self.match_number += 1;
            for m in &mut self.members {
                if !m.is_bot {
                    m.rematch_vote = false;
                }
            }
            return Ok(true);
        }
        Ok(false)
    }

    pub fn to_lobby_dto(&self, udp_port: u16) -> LobbyStateDto {
        LobbyStateDto {
            room_id: self.room_id,
            room_code: self.room_code.clone(),
            mode: self.mode.as_str().to_string(),
            state: self.state.as_str().to_string(),
            is_private: self.is_private,
            fill_bots: self.fill_bots,
            match_number: self.match_number,
            team_size: self.mode.team_size(),
            max_players: self.mode.max_players(),
            udp_port,
            server_tick: self.world.server_tick,
            scores: self.world.scores,
            match_clock_ms: (self.world.match_clock_secs * 1000.0).round().max(0.0) as u32,
            shot_clock_ms: (self.world.shot_clock_secs * 1000.0)
                .round()
                .clamp(0.0, 65_535.0) as u16,
            world_player_count: self.world.players.len(),
            human_count: self.total_human_player_count(),
            spectator_count: self.spectator_count(),
            all_ready: self.all_humans_ready(),
            all_rematch_voted: self.all_humans_voted_rematch(),
            members: self.members.clone(),
        }
    }

    pub fn to_summary_dto(&self) -> RoomSummaryDto {
        RoomSummaryDto {
            room_id: self.room_id,
            room_code: if self.is_private {
                None
            } else {
                Some(self.room_code.clone())
            },
            mode: self.mode.as_str().to_string(),
            state: self.state.as_str().to_string(),
            is_private: self.is_private,
            fill_bots: self.fill_bots,
            human_count: self.total_human_player_count(),
            player_count: self.world.players.len(),
            max_players: self.mode.max_players(),
            spectator_count: self.spectator_count(),
            scores: self.world.scores,
            spectatable: !self.is_default_arena || !self.world.players.is_empty(),
        }
    }

    /// Handles a UDP `HelloJoin` routed to this room. Returns `(session_token, outbound_packets)`.
    pub fn handle_hello_join(
        &mut self,
        hello: HelloJoinMsg,
        pkt_seq: u32,
        raw_len: usize,
        src_addr: SocketAddr,
        config: &ServerConfig,
        now: Instant,
    ) -> Option<(u64, Vec<(SocketAddr, Vec<u8>)>)> {
        let mut outbound = Vec::new();

        // 1. Idempotent reply if this UDP address already joined this room
        if let Some(existing_tok) = self.sessions.token_for_addr(&src_addr) {
            if let Some(sess) = self.sessions.get_by_token_mut(existing_tok) {
                sess.on_packet_received(pkt_seq, raw_len, now);
                let welcome = WelcomeJoinedMsg {
                    player_id: sess.player_id,
                    team_id: sess.team_id,
                    assigned_slot: sess.slot,
                    archetype_id: sess.archetype.as_u8(),
                    session_token: sess.session_token,
                    server_tick: self.world.server_tick as u32,
                    tick_rate: config.tick_rate as u16,
                    snapshot_rate: config.snapshot_rate as u16,
                };
                let out = sess.next_packet(NetMessage::WelcomeJoined(welcome));
                outbound.push((src_addr, encode_packet(&out)));
                return Some((existing_tok, outbound));
            }
        }

        let req_arch = ArchetypeId::from_u8(hello.archetype_id);
        let username = if hello.username.trim().is_empty() {
            "PhantomPlayer".to_string()
        } else {
            hello.username.trim().to_string()
        };

        // 2. If room has pre-spawned human roster entities (from Phase 9 Lobby -> InMatch),
        //    bind this UDP socket to the matching unbound human player entity!
        let bound_pids: Vec<u32> = self
            .sessions
            .all_sessions()
            .filter(|s| !s.is_spectator)
            .map(|s| s.player_id)
            .collect();

        let matched_pre_spawned = self
            .members
            .iter()
            .find(|m| {
                !m.is_bot
                    && m.team_id <= 1
                    && m.player_id.map_or(false, |pid| !bound_pids.contains(&pid))
                    && m.username.eq_ignore_ascii_case(&username)
            })
            .or_else(|| {
                self.members.iter().find(|m| {
                    !m.is_bot
                        && m.team_id <= 1
                        && m.player_id.map_or(false, |pid| !bound_pids.contains(&pid))
                })
            })
            .and_then(|m| Some((m.player_id?, m.team_id, m.slot?, ArchetypeId::from_u8(m.archetype_id))));

        let (player_id, team_id, slot, arch) = if let Some(existing) = matched_pre_spawned {
            existing
        } else {
            // Direct UDP join (default room 0 or room with free capacity)
            if !self.is_default_arena && self.world.players.len() >= self.mode.max_players() {
                return None;
            }
            let (pid, tid, sl) = self
                .world
                .add_player(username.clone(), req_arch, hello.preferred_team)?;
            (pid, tid, sl, req_arch)
        };

        let token = self.sessions.register_session(
            player_id,
            team_id,
            slot,
            username,
            arch,
            self.room_id.to_string(),
            false,
            src_addr,
            now,
        );

        if let Some(sess) = self.sessions.get_by_token_mut(token) {
            sess.on_packet_received(pkt_seq, raw_len, now);
            let welcome = WelcomeJoinedMsg {
                player_id,
                team_id,
                assigned_slot: slot,
                archetype_id: arch.as_u8(),
                session_token: token,
                server_tick: self.world.server_tick as u32,
                tick_rate: config.tick_rate as u16,
                snapshot_rate: config.snapshot_rate as u16,
            };
            let out = sess.next_packet(NetMessage::WelcomeJoined(welcome));
            let bytes = encode_packet(&out);
            sess.bytes_sent += bytes.len() as u64;
            sess.packets_sent += 1;
            outbound.push((src_addr, bytes));

            let snap = self.world.build_snapshot();
            let snap_pkt = sess.next_packet(NetMessage::ServerWorldSnapshot(snap));
            let snap_bytes = encode_packet(&snap_pkt);
            sess.bytes_sent += snap_bytes.len() as u64;
            sess.packets_sent += 1;
            outbound.push((src_addr, snap_bytes));
        }

        Some((token, outbound))
    }

    /// Registers a read-only UDP spectator in this room WITHOUT spawning any player body in `SimWorld`.
    pub fn handle_spectator_join(
        &mut self,
        spec: SpectatorJoinMsg,
        pkt_seq: u32,
        raw_len: usize,
        src_addr: SocketAddr,
        config: &ServerConfig,
        now: Instant,
    ) -> (u64, Vec<(SocketAddr, Vec<u8>)>) {
        let mut outbound = Vec::new();
        if let Some(existing_tok) = self.sessions.token_for_addr(&src_addr) {
            if let Some(sess) = self.sessions.get_by_token_mut(existing_tok) {
                sess.on_packet_received(pkt_seq, raw_len, now);
                let welcome = WelcomeJoinedMsg {
                    player_id: 0,
                    team_id: 255,
                    assigned_slot: 255,
                    archetype_id: 0,
                    session_token: sess.session_token,
                    server_tick: self.world.server_tick as u32,
                    tick_rate: config.tick_rate as u16,
                    snapshot_rate: config.snapshot_rate as u16,
                };
                let out = sess.next_packet(NetMessage::WelcomeJoined(welcome));
                outbound.push((src_addr, encode_packet(&out)));
                return (existing_tok, outbound);
            }
        }

        let name = if spec.spectator_name.trim().is_empty() {
            "Spectator".to_string()
        } else {
            spec.spectator_name.trim().to_string()
        };

        let token = self.sessions.register_session(
            0,
            255,
            255,
            name,
            ArchetypeId::AllRounder,
            self.room_id.to_string(),
            true,
            src_addr,
            now,
        );

        if let Some(sess) = self.sessions.get_by_token_mut(token) {
            sess.on_packet_received(pkt_seq, raw_len, now);
            let welcome = WelcomeJoinedMsg {
                player_id: 0,
                team_id: 255,
                assigned_slot: 255,
                archetype_id: 0,
                session_token: token,
                server_tick: self.world.server_tick as u32,
                tick_rate: config.tick_rate as u16,
                snapshot_rate: config.snapshot_rate as u16,
            };
            let out = sess.next_packet(NetMessage::WelcomeJoined(welcome));
            outbound.push((src_addr, encode_packet(&out)));

            // Send immediate live world snapshot to spectator
            let snap = self.world.build_snapshot();
            let snap_pkt = sess.next_packet(NetMessage::ServerWorldSnapshot(snap));
            outbound.push((src_addr, encode_packet(&snap_pkt)));
        }

        (token, outbound)
    }

    /// Steps 1 fixed 60 Hz simulation tick for this room and returns
    /// `(outbound_packets, evicted_tokens, optional_completed_match)`.
    pub fn step_room_tick(
        &mut self,
        now: Instant,
        snapshot_every_ticks: u64,
        reliable_retry_interval: Duration,
        idle_timeout: Duration,
        grace_window: Duration,
    ) -> (Vec<(SocketAddr, Vec<u8>)>, Vec<u64>, Option<CompletedRoomMatch>) {
        let mut outbound = Vec::new();
        let mut evicted_tokens = Vec::new();
        let mut completed_match: Option<CompletedRoomMatch> = None;

        // Advance simulation only when InMatch (default room 0 is always InMatch)
        if self.state == RoomState::InMatch {
            // 1. Apply buffered deduplicated human inputs
            let player_tokens: Vec<u64> = self
                .sessions
                .all_sessions()
                .filter(|s| !s.is_spectator && s.is_connected())
                .map(|s| s.session_token)
                .collect();

            for tok in player_tokens {
                let (player_id, rtt_ms, inputs) = match self.sessions.get_by_token_mut(tok) {
                    Some(sess) => (
                        sess.player_id,
                        sess.estimated_rtt_ms,
                        sess.pop_inputs_for_tick(),
                    ),
                    None => continue,
                };
                let one_way_ms = (rtt_ms * 0.5).clamp(0.0, 250.0);
                for input_frame in inputs {
                    self.world
                        .apply_player_input(player_id, input_frame, one_way_ms);
                }
            }

            // 2. Step server-side authoritative bot AI inputs
            self.world.step_bots();

            // 3. Step authoritative global physics, scoring gates, clocks, and lag-comp history
            self.world.step_tick();

            if self.world.match_ended && !self.is_default_arena {
                self.state = RoomState::PostMatch;
                for m in &mut self.members {
                    if !m.is_bot {
                        m.rematch_vote = false;
                    }
                }
                completed_match = Some(self.build_completed_match_summary());
            }
        }

        // 4. Track per-player stats & emit newly generated reliable events to all sessions in this room
        let new_events: Vec<MatchEventPayload> = self.world.drain_events();
        for ev_payload in new_events {
            match &ev_payload {
                MatchEventPayload::Score {
                    delta, scorer_id, ..
                } if *scorer_id > 0 => {
                    self.live_stats
                        .entry(*scorer_id as u32)
                        .or_default()
                        .points += *delta as i32;
                }
                MatchEventPayload::Steal { stealer_id, .. } if *stealer_id > 0 => {
                    self.live_stats
                        .entry(*stealer_id as u32)
                        .or_default()
                        .steals += 1;
                }
                MatchEventPayload::Block { blocker_id, .. } if *blocker_id > 0 => {
                    self.live_stats
                        .entry(*blocker_id as u32)
                        .or_default()
                        .blocks += 1;
                }
                MatchEventPayload::Zone {
                    player_id,
                    activated: true,
                    ..
                } if *player_id > 0 => {
                    self.live_stats
                        .entry(*player_id as u32)
                        .or_default()
                        .zone_activations += 1;
                }
                _ => {}
            }

            let eid = self.next_event_id;
            self.next_event_id = self.next_event_id.wrapping_add(1).max(1);
            self.total_events_emitted += 1;
            let tick_u32 = self.world.server_tick as u32;

            for sess in self.sessions.all_sessions_mut() {
                let msg = sess.enqueue_reliable_event(eid, tick_u32, ev_payload.clone(), now);
                if sess.is_connected() {
                    let pkt = sess.next_packet(NetMessage::ReliableMatchEvent(msg));
                    let bytes = encode_packet(&pkt);
                    sess.bytes_sent += bytes.len() as u64;
                    sess.packets_sent += 1;
                    outbound.push((sess.addr, bytes));
                }
            }
        }

        // 5. Retransmit unacked reliable events every 200ms
        for sess in self.sessions.all_sessions_mut() {
            let due = sess.collect_due_retransmissions(now, reliable_retry_interval);
            for ev_msg in due {
                let pkt = sess.next_packet(NetMessage::ReliableMatchEvent(ev_msg));
                let bytes = encode_packet(&pkt);
                sess.bytes_sent += bytes.len() as u64;
                sess.packets_sent += 1;
                outbound.push((sess.addr, bytes));
            }
        }

        // 6. Broadcast 30 Hz quantized world snapshots to all connected players & spectators in this room
        if self.state == RoomState::InMatch
            && self.world.server_tick > 0
            && self.world.server_tick % snapshot_every_ticks == 0
        {
            let snap = self.world.build_snapshot();
            for sess in self.sessions.all_sessions_mut() {
                if !sess.is_connected() {
                    continue;
                }
                let pkt = sess.next_packet(NetMessage::ServerWorldSnapshot(snap.clone()));
                let bytes = encode_packet(&pkt);
                self.last_snapshot_bytes = bytes.len();
                self.total_snapshots_sent += 1;
                self.total_snapshot_bytes_sent += bytes.len() as u64;
                sess.bytes_sent += bytes.len() as u64;
                sess.packets_sent += 1;
                outbound.push((sess.addr, bytes));
            }
        }

        // 7. Sweep idle timeouts -> 30s reconnect grace window -> expiry eviction
        if self.world.server_tick % 6 == 0 {
            let before_tokens: Vec<u64> = self
                .sessions
                .all_sessions()
                .map(|s| s.session_token)
                .collect();
            let (entered_grace, evicted_pids) =
                self.sessions.sweep_timeouts(now, idle_timeout, grace_window);
            for pid in entered_grace {
                if let Some(p) = self.world.get_player_mut(pid) {
                    p.disconnected_grace = true;
                }
            }
            for pid in evicted_pids {
                if self.is_default_arena {
                    self.world.remove_player(pid);
                }
            }
            for tok in before_tokens {
                if self.sessions.get_by_token(tok).is_none() {
                    evicted_tokens.push(tok);
                }
            }
        }

        (outbound, evicted_tokens, completed_match)
    }
}
