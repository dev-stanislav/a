use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use rand::Rng;

use crate::sim::ArchetypeId;

use super::session::{ClientSession, SessionState};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReconnectOutcome {
    Rebound {
        player_id: u32,
        team_id: u8,
        slot: u8,
        archetype_id: u8,
        session_token: u64,
        was_in_grace: bool,
    },
    UnknownToken,
    GraceExpired,
}

#[derive(Debug, Default)]
pub struct SessionManager {
    sessions_by_token: HashMap<u64, ClientSession>,
    token_by_addr: HashMap<SocketAddr, u64>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn generate_token() -> u64 {
        // Mask off top sign bit so token is always a non-negative 64-bit int in GDScript too.
        let raw: u64 = rand::thread_rng().gen();
        let masked = raw & 0x7FFF_FFFF_FFFF_FFFF;
        if masked == 0 {
            1
        } else {
            masked
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn register_session(
        &mut self,
        player_id: u32,
        team_id: u8,
        slot: u8,
        username: String,
        archetype: ArchetypeId,
        room_id: String,
        is_spectator: bool,
        addr: SocketAddr,
        now: Instant,
    ) -> u64 {
        // If same address already had a session, clean up mapping
        if let Some(old_tok) = self.token_by_addr.remove(&addr) {
            self.sessions_by_token.remove(&old_tok);
        }

        let mut token = Self::generate_token();
        while self.sessions_by_token.contains_key(&token) {
            token = Self::generate_token();
        }

        let session = ClientSession::new(
            token,
            player_id,
            team_id,
            slot,
            username,
            archetype,
            room_id,
            is_spectator,
            addr,
            now,
        );
        self.sessions_by_token.insert(token, session);
        self.token_by_addr.insert(addr, token);
        token
    }

    pub fn get_by_token(&self, token: u64) -> Option<&ClientSession> {
        self.sessions_by_token.get(&token)
    }

    pub fn get_by_token_mut(&mut self, token: u64) -> Option<&mut ClientSession> {
        self.sessions_by_token.get_mut(&token)
    }

    pub fn get_by_addr(&self, addr: &SocketAddr) -> Option<&ClientSession> {
        let tok = self.token_by_addr.get(addr)?;
        self.sessions_by_token.get(tok)
    }

    pub fn get_by_addr_mut(&mut self, addr: &SocketAddr) -> Option<&mut ClientSession> {
        let tok = *self.token_by_addr.get(addr)?;
        self.sessions_by_token.get_mut(&tok)
    }

    pub fn token_for_addr(&self, addr: &SocketAddr) -> Option<u64> {
        self.token_by_addr.get(addr).copied()
    }

    pub fn all_sessions(&self) -> impl Iterator<Item = &ClientSession> {
        self.sessions_by_token.values()
    }

    pub fn all_sessions_mut(&mut self) -> impl Iterator<Item = &mut ClientSession> {
        self.sessions_by_token.values_mut()
    }

    pub fn active_player_count(&self) -> usize {
        self.sessions_by_token
            .values()
            .filter(|s| !s.is_spectator)
            .count()
    }

    pub fn connected_count(&self) -> usize {
        self.sessions_by_token
            .values()
            .filter(|s| s.is_connected())
            .count()
    }

    /// Rebinds an existing session (whether active or within the 30-second grace window)
    /// to a brand-new client UDP `SocketAddr` without losing player state, score, stamina, Zone, or slot!
    pub fn handle_reconnect(
        &mut self,
        session_token: u64,
        new_addr: SocketAddr,
        now: Instant,
        grace_window: Duration,
    ) -> ReconnectOutcome {
        let (old_addr, was_in_grace, expired) = match self.sessions_by_token.get(&session_token) {
            None => return ReconnectOutcome::UnknownToken,
            Some(sess) => match sess.state {
                SessionState::Connected => (sess.addr, false, false),
                SessionState::DisconnectedGrace { disconnected_at } => {
                    let is_expired = now.duration_since(disconnected_at) > grace_window;
                    (sess.addr, true, is_expired)
                }
            },
        };

        if expired {
            self.remove_session_by_token(session_token);
            return ReconnectOutcome::GraceExpired;
        }

        if old_addr != new_addr {
            if self.token_by_addr.get(&old_addr) == Some(&session_token) {
                self.token_by_addr.remove(&old_addr);
            }
            self.token_by_addr.insert(new_addr, session_token);
        }

        let sess = self
            .sessions_by_token
            .get_mut(&session_token)
            .expect("session verified present");
        sess.addr = new_addr;
        sess.state = SessionState::Connected;
        sess.last_packet_received = now;

        ReconnectOutcome::Rebound {
            player_id: sess.player_id,
            team_id: sess.team_id,
            slot: sess.slot,
            archetype_id: sess.archetype.as_u8(),
            session_token,
            was_in_grace,
        }
    }

    /// Checks idle sessions, moves timed-out clients into the 30s grace window,
    /// and evicts sessions whose grace window has fully expired.
    /// Returns `(newly_entered_grace_player_ids, permanently_evicted_player_ids)`.
    pub fn sweep_timeouts(
        &mut self,
        now: Instant,
        idle_timeout: Duration,
        grace_window: Duration,
    ) -> (Vec<u32>, Vec<u32>) {
        let mut entered_grace = Vec::new();
        let mut expired_tokens = Vec::new();

        for (&token, sess) in self.sessions_by_token.iter_mut() {
            match sess.state {
                SessionState::Connected => {
                    if now.duration_since(sess.last_packet_received) >= idle_timeout {
                        sess.state = SessionState::DisconnectedGrace {
                            disconnected_at: now,
                        };
                        if !sess.is_spectator {
                            entered_grace.push(sess.player_id);
                        }
                    }
                }
                SessionState::DisconnectedGrace { disconnected_at } => {
                    if now.duration_since(disconnected_at) >= grace_window {
                        expired_tokens.push(token);
                    }
                }
            }
        }

        let mut evicted_players = Vec::new();
        for tok in expired_tokens {
            if let Some(sess) = self.remove_session_by_token(tok) {
                if !sess.is_spectator {
                    evicted_players.push(sess.player_id);
                }
            }
        }

        (entered_grace, evicted_players)
    }

    pub fn remove_session_by_token(&mut self, token: u64) -> Option<ClientSession> {
        let sess = self.sessions_by_token.remove(&token)?;
        if self.token_by_addr.get(&sess.addr) == Some(&token) {
            self.token_by_addr.remove(&sess.addr);
        }
        Some(sess)
    }
}
