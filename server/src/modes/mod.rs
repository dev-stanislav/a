pub mod lobby;
pub mod matchmaker;
pub mod room_manager;
pub mod spectator;

use serde::{Deserialize, Serialize};

use crate::sim::ArchetypeId;

pub use lobby::{
    CompletedRoomMatch, CompletedRoomParticipant, LobbyMember, LobbyStateDto, MatchRoom,
    RoomSummaryDto,
};
pub use matchmaker::{Matchmaker, MatchmakingTicket, TicketStatus};
pub use room_manager::{persist_completed_room_match, RoomManager};
pub use spectator::{SnapshotPreviewDto, SpectatorTicket};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum GameMode {
    #[serde(rename = "1v1")]
    OneVsOne,
    #[serde(rename = "2v2")]
    TwoVsTwo,
    #[serde(rename = "3v3")]
    ThreeVsThree,
}

impl GameMode {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "1v1" | "online_1v1" | "duel" => Some(Self::OneVsOne),
            "2v2" | "online_2v2" | "duos" => Some(Self::TwoVsTwo),
            "3v3" | "online_3v3" | "trios" => Some(Self::ThreeVsThree),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::OneVsOne => "1v1",
            Self::TwoVsTwo => "2v2",
            Self::ThreeVsThree => "3v3",
        }
    }

    pub fn team_size(self) -> usize {
        match self {
            Self::OneVsOne => 1,
            Self::TwoVsTwo => 2,
            Self::ThreeVsThree => 3,
        }
    }

    pub fn max_players(self) -> usize {
        self.team_size() * 2
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RoomState {
    Lobby,
    Countdown,
    InMatch,
    PostMatch,
}

impl RoomState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Lobby => "Lobby",
            Self::Countdown => "Countdown",
            Self::InMatch => "InMatch",
            Self::PostMatch => "PostMatch",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModeError {
    RoomNotFound,
    MemberNotFound,
    TicketNotFound,
    RoomFull,
    TeamFull,
    InvalidMode(String),
    InvalidState(String),
    BadRequest(String),
}

impl ModeError {
    pub fn message(&self) -> String {
        match self {
            Self::RoomNotFound => "room not found".to_string(),
            Self::MemberNotFound => "member not found".to_string(),
            Self::TicketNotFound => "matchmaking ticket not found".to_string(),
            Self::RoomFull => "room is full".to_string(),
            Self::TeamFull => "target team is full".to_string(),
            Self::InvalidMode(m) => format!("invalid game mode: {m}"),
            Self::InvalidState(msg) => msg.clone(),
            Self::BadRequest(msg) => msg.clone(),
        }
    }
}

pub fn archetype_to_name(arch: ArchetypeId) -> &'static str {
    match arch {
        ArchetypeId::Speedster => "speedster",
        ArchetypeId::Sharpshooter => "sharpshooter",
        ArchetypeId::Playmaker => "playmaker",
        ArchetypeId::Powerhouse => "powerhouse",
        ArchetypeId::AllRounder => "all_rounder",
    }
}
