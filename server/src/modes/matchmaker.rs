use std::collections::HashMap;

use serde::Serialize;
use uuid::Uuid;

use crate::sim::ArchetypeId;

use super::{archetype_to_name, GameMode, ModeError};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TicketStatus {
    Queued,
    Matched,
    Cancelled,
}

#[derive(Debug, Clone, Serialize)]
pub struct MatchmakingTicket {
    pub ticket_id: String,
    pub username: String,
    pub archetype_id: u8,
    pub archetype: String,
    pub mode: String,
    pub rating: i32,
    pub fill_bots: bool,
    pub status: TicketStatus,
    pub room_id: Option<u32>,
    pub room_code: Option<String>,
    pub member_id: Option<String>,
    pub team_id: Option<u8>,
}

#[derive(Debug, Default)]
pub struct Matchmaker {
    tickets: HashMap<String, MatchmakingTicket>,
    queues: HashMap<GameMode, Vec<String>>,
}

impl Matchmaker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn enqueue(
        &mut self,
        username: String,
        archetype: ArchetypeId,
        mode: GameMode,
        rating: i32,
        fill_bots: bool,
    ) -> (MatchmakingTicket, Option<Vec<String>>) {
        let clean_name = if username.trim().is_empty() {
            "PhantomPlayer".to_string()
        } else {
            username.trim().to_string()
        };
        let ticket_id = format!("tkt_{}", Uuid::new_v4().simple());
        let ticket = MatchmakingTicket {
            ticket_id: ticket_id.clone(),
            username: clean_name,
            archetype_id: archetype.as_u8(),
            archetype: archetype_to_name(archetype).to_string(),
            mode: mode.as_str().to_string(),
            rating,
            fill_bots,
            status: TicketStatus::Queued,
            room_id: None,
            room_code: None,
            member_id: None,
            team_id: None,
        };
        self.tickets.insert(ticket_id.clone(), ticket.clone());

        let queue = self.queues.entry(mode).or_default();
        queue.push(ticket_id.clone());

        // If fill_bots quick-match requested, immediately pop this ticket (plus up to max_players-1 queued peers)
        if fill_bots {
            let max_p = mode.max_players();
            let take_n = queue.len().min(max_p);
            let matched_ids: Vec<String> = queue.drain(0..take_n).collect();
            return (ticket, Some(matched_ids));
        }

        // Standard queue matching: pop exact `mode.max_players()` players sorted by closest rating!
        let needed = mode.max_players();
        if queue.len() >= needed {
            // Sort by rating to pair closely rated players together cleanly
            let ratings: HashMap<String, i32> = queue
                .iter()
                .filter_map(|id| self.tickets.get(id).map(|t| (id.clone(), t.rating)))
                .collect();
            queue.sort_by_key(|id| ratings.get(id).copied().unwrap_or(1000));
            let matched_ids: Vec<String> = queue.drain(0..needed).collect();
            return (ticket, Some(matched_ids));
        }

        (ticket, None)
    }

    pub fn mark_matched(
        &mut self,
        ticket_id: &str,
        room_id: u32,
        room_code: String,
        member_id: String,
        team_id: u8,
    ) {
        if let Some(t) = self.tickets.get_mut(ticket_id) {
            t.status = TicketStatus::Matched;
            t.room_id = Some(room_id);
            t.room_code = Some(room_code);
            t.member_id = Some(member_id);
            t.team_id = Some(team_id);
        }
    }

    pub fn cancel(&mut self, ticket_id: &str) -> Result<MatchmakingTicket, ModeError> {
        let Some(t) = self.tickets.get_mut(ticket_id) else {
            return Err(ModeError::TicketNotFound);
        };
        if t.status != TicketStatus::Queued {
            return Ok(t.clone());
        }
        t.status = TicketStatus::Cancelled;
        for q in self.queues.values_mut() {
            q.retain(|id| id != ticket_id);
        }
        Ok(t.clone())
    }

    pub fn get_ticket(&self, ticket_id: &str) -> Option<&MatchmakingTicket> {
        self.tickets.get(ticket_id)
    }

    pub fn queue_depth(&self, mode: GameMode) -> usize {
        self.queues.get(&mode).map_or(0, Vec::len)
    }
}
