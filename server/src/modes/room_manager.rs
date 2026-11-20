use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::config::ServerConfig;
use crate::db::{
    ParticipantInput, RecordMatchInput, RecordMatchResult, SharedRankingStore, DEFAULT_SEASON_ID,
};
use crate::net::{ReconnectOutcome, ServerRuntimeMetrics};
use crate::protocol::{encode_packet, MatchEventPayload, NetMessage, Packet, PongMsg, WelcomeJoinedMsg};
use crate::sim::ArchetypeId;

use super::lobby::{
    generate_room_code, CompletedRoomMatch, LobbyMember, LobbyStateDto, MatchRoom, RoomSummaryDto,
};
use super::matchmaker::{Matchmaker, MatchmakingTicket};
use super::spectator::{generate_spectator_token, SnapshotPreviewDto, SpectatorTicket};
use super::{GameMode, ModeError};

fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[derive(Debug)]
pub struct RoomManager {
    pub config: ServerConfig,
    pub udp_port: u16,
    rooms: HashMap<u32, MatchRoom>,
    code_to_room_id: HashMap<String, u32>,
    token_to_room_id: HashMap<u64, u32>,
    next_room_id: u32,
    pub matchmaker: Matchmaker,
}

impl RoomManager {
    pub fn new(config: ServerConfig, udp_port: u16) -> Self {
        let mut rooms = HashMap::new();
        let default_arena = MatchRoom::new_default_arena(&config);
        let mut code_to_room_id = HashMap::new();
        code_to_room_id.insert(default_arena.room_code.clone(), 0);
        rooms.insert(0, default_arena);

        Self {
            config,
            udp_port,
            rooms,
            code_to_room_id,
            token_to_room_id: HashMap::new(),
            next_room_id: 1,
            matchmaker: Matchmaker::new(),
        }
    }

    pub fn rooms_count(&self) -> usize {
        self.rooms.len()
    }

    pub fn total_active_players(&self) -> usize {
        self.rooms
            .values()
            .map(|r| r.sessions.active_player_count())
            .sum()
    }

    pub fn default_server_tick(&self) -> u64 {
        self.rooms.get(&0).map_or(0, |r| r.world.server_tick)
    }

    pub fn get_room(&self, room_id: u32) -> Option<&MatchRoom> {
        self.rooms.get(&room_id)
    }

    pub fn get_room_mut(&mut self, room_id: u32) -> Option<&mut MatchRoom> {
        self.rooms.get_mut(&room_id)
    }

    fn allocate_unique_code(&self) -> String {
        loop {
            let code = generate_room_code();
            if !self.code_to_room_id.contains_key(&code) {
                return code;
            }
        }
    }

    /// Resolves a UDP `room_id` string into a room ID:
    /// - `""`, `"0"`, `"default"` -> room `0`
    /// - numeric `"1"`, `"2"`, ... -> exact room if present (`None` if unknown)
    /// - 6-char room code `"CRT9X2"` -> exact room
    /// - non-numeric legacy strings (Phase 8 tests like `"test-arena"`, `"lossy-court"`) -> room `0`
    pub fn resolve_udp_room_id(&self, raw: &str) -> Option<u32> {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed == "0" || trimmed.eq_ignore_ascii_case("default") {
            return Some(0);
        }
        if let Ok(num) = trimmed.parse::<u32>() {
            return if self.rooms.contains_key(&num) {
                Some(num)
            } else {
                None
            };
        }
        let upper = trimmed.to_ascii_uppercase();
        if let Some(&rid) = self.code_to_room_id.get(&upper) {
            return Some(rid);
        }
        // Backward compatibility for Phase 8 legacy string room labels
        Some(0)
    }

    // =========================================================================
    // Lobby, Room & Matchmaking Control API
    // =========================================================================

    pub fn create_room(
        &mut self,
        mode: GameMode,
        is_private: bool,
        fill_bots: bool,
        host_username: String,
        archetype: ArchetypeId,
    ) -> Result<(u32, String, LobbyMember, LobbyStateDto), ModeError> {
        let room_id = self.next_room_id;
        self.next_room_id += 1;
        let code = self.allocate_unique_code();

        let mut room = MatchRoom::new_lobby(
            room_id,
            code.clone(),
            mode,
            is_private,
            fill_bots,
            &self.config,
        );
        let host = room.add_member(host_username, archetype, false, true, Some(0))?;
        let dto = room.to_lobby_dto(self.udp_port);

        self.code_to_room_id.insert(code.clone(), room_id);
        self.rooms.insert(room_id, room);
        Ok((room_id, code, host, dto))
    }

    pub fn list_public_and_live_rooms(&self) -> Vec<RoomSummaryDto> {
        let mut out: Vec<RoomSummaryDto> = self
            .rooms
            .values()
            .filter(|r| !r.is_default_arena && (!r.is_private || r.state == super::RoomState::InMatch))
            .map(|r| r.to_summary_dto())
            .collect();
        out.sort_by_key(|r| r.room_id);
        out
    }

    pub fn join_room(
        &mut self,
        room_id: Option<u32>,
        room_code: Option<&str>,
        username: String,
        archetype: ArchetypeId,
        as_spectator: bool,
    ) -> Result<(u32, String, LobbyMember, LobbyStateDto), ModeError> {
        let resolved_id = if let Some(code) = room_code {
            let upper = code.trim().to_ascii_uppercase();
            *self
                .code_to_room_id
                .get(&upper)
                .ok_or(ModeError::RoomNotFound)?
        } else if let Some(id) = room_id {
            if self.rooms.contains_key(&id) {
                id
            } else {
                return Err(ModeError::RoomNotFound);
            }
        } else {
            return Err(ModeError::BadRequest(
                "must provide room_code or room_id".to_string(),
            ));
        };

        let udp_port = self.udp_port;
        let room = self
            .rooms
            .get_mut(&resolved_id)
            .ok_or(ModeError::RoomNotFound)?;
        let member = room.add_member(username, archetype, as_spectator, false, None)?;
        let code = room.room_code.clone();
        let dto = room.to_lobby_dto(udp_port);
        Ok((resolved_id, code, member, dto))
    }

    pub fn get_room_state(&self, room_id: u32) -> Result<LobbyStateDto, ModeError> {
        let room = self.rooms.get(&room_id).ok_or(ModeError::RoomNotFound)?;
        Ok(room.to_lobby_dto(self.udp_port))
    }

    pub fn set_ready(
        &mut self,
        room_id: u32,
        member_id: &str,
        ready: bool,
    ) -> Result<(bool, LobbyStateDto), ModeError> {
        let udp_port = self.udp_port;
        let room = self
            .rooms
            .get_mut(&room_id)
            .ok_or(ModeError::RoomNotFound)?;
        let started = room.set_member_ready(member_id, ready)?;
        Ok((started, room.to_lobby_dto(udp_port)))
    }

    pub fn configure_room_member(
        &mut self,
        room_id: u32,
        member_id: &str,
        team: Option<u8>,
        archetype: Option<ArchetypeId>,
        fill_bots: Option<bool>,
    ) -> Result<LobbyStateDto, ModeError> {
        let udp_port = self.udp_port;
        let room = self
            .rooms
            .get_mut(&room_id)
            .ok_or(ModeError::RoomNotFound)?;
        room.configure_member(member_id, team, archetype, fill_bots)?;
        Ok(room.to_lobby_dto(udp_port))
    }

    pub fn finish_room_match(
        &mut self,
        room_id: u32,
        override_scores: Option<[u16; 2]>,
    ) -> Result<(LobbyStateDto, Option<CompletedRoomMatch>), ModeError> {
        let udp_port = self.udp_port;
        let room = self
            .rooms
            .get_mut(&room_id)
            .ok_or(ModeError::RoomNotFound)?;
        let completed = room.finish_match_now(override_scores)?;
        Ok((room.to_lobby_dto(udp_port), completed))
    }

    pub fn vote_rematch(
        &mut self,
        room_id: u32,
        member_id: &str,
        vote: bool,
    ) -> Result<(bool, LobbyStateDto), ModeError> {
        let udp_port = self.udp_port;
        let room = self
            .rooms
            .get_mut(&room_id)
            .ok_or(ModeError::RoomNotFound)?;
        let started = room.vote_rematch(member_id, vote)?;
        Ok((started, room.to_lobby_dto(udp_port)))
    }

    pub fn issue_spectate_ticket(
        &mut self,
        room_id: u32,
        _username: String,
    ) -> Result<SpectatorTicket, ModeError> {
        let udp_port = self.udp_port;
        let room = self
            .rooms
            .get_mut(&room_id)
            .ok_or(ModeError::RoomNotFound)?;
        let token = generate_spectator_token();
        room.spectator_tokens.push(token.clone());
        let preview = SnapshotPreviewDto::from_world(&room.world);
        let dto = room.to_lobby_dto(udp_port);
        Ok(SpectatorTicket {
            room_id,
            udp_port,
            spectator_token: token,
            state: room.state.as_str().to_string(),
            snapshot_preview: preview,
            lobby_state: dto,
        })
    }

    pub fn enqueue_matchmaking(
        &mut self,
        username: String,
        archetype: ArchetypeId,
        mode: GameMode,
        rating: i32,
        fill_bots: bool,
    ) -> (MatchmakingTicket, Option<LobbyStateDto>) {
        let (ticket, maybe_group) = self
            .matchmaker
            .enqueue(username, archetype, mode, rating, fill_bots);
        let my_id = ticket.ticket_id.clone();

        if let Some(group_ids) = maybe_group {
            // Pop matched players into a brand-new public match lobby room!
            let room_id = self.next_room_id;
            self.next_room_id += 1;
            let code = self.allocate_unique_code();
            let room_fill_bots = fill_bots
                || group_ids.iter().any(|tid| {
                    self.matchmaker
                        .get_ticket(tid)
                        .map_or(false, |t| t.fill_bots)
                });
            let mut room = MatchRoom::new_lobby(
                room_id,
                code.clone(),
                mode,
                false,
                room_fill_bots,
                &self.config,
            );

            for (idx, tid) in group_ids.iter().enumerate() {
                if let Some(t) = self.matchmaker.get_ticket(tid).cloned() {
                    let arch = ArchetypeId::from_u8(t.archetype_id);
                    let pref_team = Some((idx % 2) as u8);
                    if let Ok(member) =
                        room.add_member(t.username, arch, false, idx == 0, pref_team)
                    {
                        self.matchmaker.mark_matched(
                            tid,
                            room_id,
                            code.clone(),
                            member.member_id,
                            member.team_id,
                        );
                    }
                }
            }

            let dto = room.to_lobby_dto(self.udp_port);
            self.code_to_room_id.insert(code, room_id);
            self.rooms.insert(room_id, room);

            let updated = self
                .matchmaker
                .get_ticket(&my_id)
                .cloned()
                .unwrap_or(ticket);
            return (updated, Some(dto));
        }

        (ticket, None)
    }

    pub fn cancel_matchmaking(&mut self, ticket_id: &str) -> Result<MatchmakingTicket, ModeError> {
        self.matchmaker.cancel(ticket_id)
    }

    pub fn get_matchmaking_status(
        &self,
        ticket_id: &str,
    ) -> Result<(MatchmakingTicket, Option<LobbyStateDto>), ModeError> {
        let ticket = self
            .matchmaker
            .get_ticket(ticket_id)
            .cloned()
            .ok_or(ModeError::TicketNotFound)?;
        let lobby = ticket
            .room_id
            .and_then(|rid| self.rooms.get(&rid).map(|r| r.to_lobby_dto(self.udp_port)));
        Ok((ticket, lobby))
    }

    // =========================================================================
    // UDP Routing, Reconnect & 60 Hz Tick Execution
    // =========================================================================

    pub fn handle_udp_packet(
        &mut self,
        src_addr: SocketAddr,
        pkt: Packet,
        raw_len: usize,
        now: Instant,
    ) -> Vec<(SocketAddr, Vec<u8>)> {
        match pkt.payload {
            NetMessage::HelloJoin(hello) => {
                let Some(room_id) = self.resolve_udp_room_id(&hello.room_id) else {
                    return Vec::new();
                };
                let cfg = self.config.clone();
                if let Some(room) = self.rooms.get_mut(&room_id) {
                    if let Some((tok, outbound)) =
                        room.handle_hello_join(hello, pkt.header.seq, raw_len, src_addr, &cfg, now)
                    {
                        self.token_to_room_id.insert(tok, room_id);
                        return outbound;
                    }
                }
                Vec::new()
            }
            NetMessage::SpectatorJoin(spec) => {
                let Some(room_id) = self.resolve_udp_room_id(&spec.room_id) else {
                    return Vec::new();
                };
                let cfg = self.config.clone();
                if let Some(room) = self.rooms.get_mut(&room_id) {
                    let (tok, outbound) = room.handle_spectator_join(
                        spec,
                        pkt.header.seq,
                        raw_len,
                        src_addr,
                        &cfg,
                        now,
                    );
                    self.token_to_room_id.insert(tok, room_id);
                    return outbound;
                }
                Vec::new()
            }
            NetMessage::ClientInputBatch(batch) => {
                if let Some(&room_id) = self.token_to_room_id.get(&batch.session_token) {
                    if let Some(room) = self.rooms.get_mut(&room_id) {
                        if let Some(sess) = room.sessions.get_by_token_mut(batch.session_token) {
                            // Strictly reject spectators and source-address spoofing!
                            if sess.addr != src_addr || sess.is_spectator {
                                return Vec::new();
                            }
                            sess.on_packet_received(pkt.header.seq, raw_len, now);
                            sess.ingest_input_batch(&batch.frames);
                        }
                    }
                }
                Vec::new()
            }
            NetMessage::EventAck(ack) => {
                if let Some(&room_id) = self.token_to_room_id.get(&ack.session_token) {
                    if let Some(room) = self.rooms.get_mut(&room_id) {
                        if let Some(sess) = room.sessions.get_by_token_mut(ack.session_token) {
                            if sess.addr == src_addr {
                                sess.on_packet_received(pkt.header.seq, raw_len, now);
                                sess.handle_event_ack(&ack);
                            }
                        }
                    }
                }
                Vec::new()
            }
            NetMessage::Ping(ping) => {
                if let Some(&room_id) = self.token_to_room_id.get(&ping.session_token) {
                    if let Some(room) = self.rooms.get_mut(&room_id) {
                        let srv_tick = room.world.server_tick as u32;
                        if let Some(sess) = room.sessions.get_by_token_mut(ping.session_token) {
                            if sess.addr == src_addr {
                                sess.on_packet_received(pkt.header.seq, raw_len, now);
                                let pong = PongMsg {
                                    client_time_ms: ping.client_time_ms,
                                    server_tick: srv_tick,
                                    server_time_ms: unix_time_ms(),
                                };
                                let out = sess.next_packet(NetMessage::Pong(pong));
                                let bytes = encode_packet(&out);
                                sess.bytes_sent += bytes.len() as u64;
                                sess.packets_sent += 1;
                                return vec![(src_addr, bytes)];
                            }
                        }
                    }
                }
                // Reply cleanly to unauthenticated ping probes too
                let pong = PongMsg {
                    client_time_ms: ping.client_time_ms,
                    server_tick: self.default_server_tick() as u32,
                    server_time_ms: unix_time_ms(),
                };
                let out = Packet::new(1, pkt.header.seq, 0, NetMessage::Pong(pong));
                vec![(src_addr, encode_packet(&out))]
            }
            NetMessage::ReconnectRequest(req) => {
                let Some(&room_id) = self.token_to_room_id.get(&req.session_token) else {
                    return Vec::new();
                };
                let grace = self.config.reconnect_grace_window;
                let tick_rate = self.config.tick_rate as u16;
                let snap_rate = self.config.snapshot_rate as u16;
                let Some(room) = self.rooms.get_mut(&room_id) else {
                    return Vec::new();
                };
                let outcome =
                    room.sessions
                        .handle_reconnect(req.session_token, src_addr, now, grace);
                let mut outbound = Vec::new();
                if let ReconnectOutcome::Rebound {
                    player_id,
                    team_id,
                    slot,
                    archetype_id,
                    session_token,
                    ..
                } = outcome
                {
                    if player_id > 0 {
                        if let Some(p) = room.world.get_player_mut(player_id) {
                            p.disconnected_grace = false;
                        }
                    }
                    if let Some(sess) = room.sessions.get_by_token_mut(session_token) {
                        sess.on_packet_received(pkt.header.seq, raw_len, now);
                        let welcome = WelcomeJoinedMsg {
                            player_id,
                            team_id,
                            assigned_slot: slot,
                            archetype_id,
                            session_token,
                            server_tick: room.world.server_tick as u32,
                            tick_rate,
                            snapshot_rate: snap_rate,
                        };
                        let out = sess.next_packet(NetMessage::WelcomeJoined(welcome));
                        outbound.push((src_addr, encode_packet(&out)));

                        let snap = room.world.build_snapshot();
                        let snap_pkt = sess.next_packet(NetMessage::ServerWorldSnapshot(snap));
                        outbound.push((src_addr, encode_packet(&snap_pkt)));

                        let missed = sess.replay_events_after(req.last_acked_event_id, now);
                        for ev in missed {
                            let ev_pkt = sess.next_packet(NetMessage::ReliableMatchEvent(ev));
                            outbound.push((src_addr, encode_packet(&ev_pkt)));
                        }
                    }
                }
                outbound
            }
            _ => Vec::new(), // Ignore client-forged ServerWorldSnapshot, WelcomeJoined, Pong, ReliableMatchEvent
        }
    }

    pub fn step_all_rooms(
        &mut self,
        now: Instant,
        snapshot_every_ticks: u64,
    ) -> (Vec<(SocketAddr, Vec<u8>)>, Vec<CompletedRoomMatch>) {
        let mut all_outbound = Vec::new();
        let mut all_evicted_tokens = Vec::new();
        let mut completed_matches = Vec::new();
        let retry = self.config.reliable_retry_interval;
        let idle = self.config.idle_disconnect_timeout;
        let grace = self.config.reconnect_grace_window;

        for room in self.rooms.values_mut() {
            let (mut out, mut evicted, maybe_completed) =
                room.step_room_tick(now, snapshot_every_ticks, retry, idle, grace);
            all_outbound.append(&mut out);
            all_evicted_tokens.append(&mut evicted);
            if let Some(cm) = maybe_completed {
                completed_matches.push(cm);
            }
        }

        for tok in all_evicted_tokens {
            self.token_to_room_id.remove(&tok);
        }

        (all_outbound, completed_matches)
    }

    pub fn room_load_snapshots(&self) -> Vec<(u32, u64, usize, usize, u64, u64)> {
        let mut out: Vec<_> = self
            .rooms
            .values()
            .filter(|r| !r.is_default_arena)
            .map(|r| {
                (
                    r.room_id,
                    r.world.server_tick,
                    r.world.players.len(),
                    r.sessions.connected_count(),
                    r.total_snapshots_sent,
                    r.total_snapshot_bytes_sent,
                )
            })
            .collect();
        out.sort_by_key(|t| t.0);
        out
    }

    /// Backward-compatible runtime metrics for default arena room 0 (used by Phase 8 tests).
    pub fn default_room_metrics(&self) -> ServerRuntimeMetrics {
        let room = self.rooms.get(&0).expect("default room 0 exists");
        let mut player_inputs: Vec<(u32, u32, u64)> = room
            .sessions
            .all_sessions()
            .filter(|s| !s.is_spectator)
            .map(|s| {
                (
                    s.player_id,
                    s.last_processed_input_seq,
                    s.total_inputs_processed,
                )
            })
            .collect();
        player_inputs.sort_by_key(|t| t.0);
        ServerRuntimeMetrics {
            server_tick: room.world.server_tick,
            active_players: room.sessions.active_player_count(),
            connected_sessions: room.sessions.connected_count(),
            total_snapshots_sent: room.total_snapshots_sent,
            total_snapshot_bytes_sent: room.total_snapshot_bytes_sent,
            last_snapshot_bytes: room.last_snapshot_bytes,
            total_events_emitted: room.total_events_emitted,
            player_inputs_processed: player_inputs,
            scores: room.world.scores,
        }
    }

    pub fn inject_reliable_event_default_room(&mut self, ev: MatchEventPayload) {
        if let Some(room) = self.rooms.get_mut(&0) {
            room.world.push_event(ev);
        }
    }

    pub fn set_player_zone_full_default_room(&mut self, player_id: u32) {
        if let Some(room) = self.rooms.get_mut(&0) {
            if let Some(p) = room.world.get_player_mut(player_id) {
                p.zone_energy = 100.0;
            }
        }
    }
}

/// Automatically persists a completed online room match and updates Glicko-2 ratings
/// for every registered player profile found in `store`.
pub async fn persist_completed_room_match(
    store: &SharedRankingStore,
    completed: CompletedRoomMatch,
) -> Option<RecordMatchResult> {
    let mut participants = Vec::new();
    for p in completed.participants {
        if let Ok(profile) = store.get_profile(&p.username).await {
            participants.push(ParticipantInput {
                player_id: profile.id,
                team: p.team,
                archetype: p.archetype,
                points: p.points,
                assists: p.assists,
                rebounds: p.rebounds,
                blocks: p.blocks,
                steals: p.steals,
                zone_activations: p.zone_activations,
            });
        }
    }
    if participants.is_empty() {
        return None;
    }
    let input = RecordMatchInput {
        mode: completed.mode,
        season_id: DEFAULT_SEASON_ID,
        team_a_score: completed.team_a_score,
        team_b_score: completed.team_b_score,
        duration_sec: completed.duration_sec,
        participants,
    };
    store.record_match(input).await.ok()
}
