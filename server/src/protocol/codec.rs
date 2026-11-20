use std::fmt;

use super::messages::*;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodecError {
    PacketTooShort { expected: usize, actual: usize },
    InvalidMagic(u16),
    UnsupportedVersion(u8),
    UnknownMessageType(u8),
    UnknownEventKind(u8),
    InvalidBatchCount(u8),
    InvalidPlayerCount(u8),
    InvalidUtf8,
}

impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CodecError::PacketTooShort { expected, actual } => {
                write!(f, "packet too short: expected >= {expected}, got {actual}")
            }
            CodecError::InvalidMagic(m) => write!(f, "invalid packet magic: 0x{m:04X}"),
            CodecError::UnsupportedVersion(v) => write!(f, "unsupported protocol version: {v}"),
            CodecError::UnknownMessageType(t) => write!(f, "unknown message type: 0x{t:02X}"),
            CodecError::UnknownEventKind(k) => write!(f, "unknown event kind: {k}"),
            CodecError::InvalidBatchCount(c) => write!(f, "invalid input batch count: {c}"),
            CodecError::InvalidPlayerCount(c) => write!(f, "invalid snapshot player count: {c}"),
            CodecError::InvalidUtf8 => write!(f, "invalid UTF-8 string in packet"),
        }
    }
}

impl std::error::Error for CodecError {}

struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn read_bytes(&mut self, n: usize) -> Result<&'a [u8], CodecError> {
        if self.pos + n > self.buf.len() {
            return Err(CodecError::PacketTooShort {
                expected: self.pos + n,
                actual: self.buf.len(),
            });
        }
        let slice = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(slice)
    }

    fn read_u8(&mut self) -> Result<u8, CodecError> {
        Ok(self.read_bytes(1)?[0])
    }

    fn read_u16(&mut self) -> Result<u16, CodecError> {
        let b = self.read_bytes(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    fn read_i16(&mut self) -> Result<i16, CodecError> {
        let b = self.read_bytes(2)?;
        Ok(i16::from_le_bytes([b[0], b[1]]))
    }

    fn read_u32(&mut self) -> Result<u32, CodecError> {
        let b = self.read_bytes(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn read_u64(&mut self) -> Result<u64, CodecError> {
        let b = self.read_bytes(8)?;
        Ok(u64::from_le_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }

    fn read_short_string(&mut self, max_len: usize) -> Result<String, CodecError> {
        let len = self.read_u8()? as usize;
        let clamped = len.min(max_len);
        let raw = self.read_bytes(len)?;
        let s = std::str::from_utf8(&raw[..clamped]).map_err(|_| CodecError::InvalidUtf8)?;
        Ok(s.to_string())
    }
}

fn write_short_string(out: &mut Vec<u8>, s: &str, max_len: usize) {
    let bytes = s.as_bytes();
    let mut len = bytes.len().min(max_len).min(255);
    while len > 0 && !s.is_char_boundary(len) {
        len -= 1;
    }
    out.push(len as u8);
    out.extend_from_slice(&bytes[..len]);
}

pub fn encode_packet(packet: &Packet) -> Vec<u8> {
    let mut out = Vec::with_capacity(256);

    // 16-byte header (little-endian)
    out.extend_from_slice(&packet.header.magic.to_le_bytes());
    out.push(packet.header.version);
    out.push(packet.payload.msg_type());
    out.extend_from_slice(&packet.header.seq.to_le_bytes());
    out.extend_from_slice(&packet.header.ack.to_le_bytes());
    out.extend_from_slice(&packet.header.ack_bits.to_le_bytes());

    match &packet.payload {
        NetMessage::HelloJoin(m) => {
            write_short_string(&mut out, &m.username, 32);
            out.push(m.archetype_id);
            write_short_string(&mut out, &m.room_id, 32);
            write_short_string(&mut out, &m.auth_token, 64);
            out.push(m.preferred_team);
        }
        NetMessage::WelcomeJoined(m) => {
            out.extend_from_slice(&m.player_id.to_le_bytes());
            out.push(m.team_id);
            out.push(m.assigned_slot);
            out.push(m.archetype_id);
            out.push(0u8); // reserved alignment byte
            out.extend_from_slice(&m.session_token.to_le_bytes());
            out.extend_from_slice(&m.server_tick.to_le_bytes());
            out.extend_from_slice(&m.tick_rate.to_le_bytes());
            out.extend_from_slice(&m.snapshot_rate.to_le_bytes());
        }
        NetMessage::ClientInputBatch(m) => {
            out.extend_from_slice(&m.session_token.to_le_bytes());
            let count = m.frames.len().min(MAX_INPUT_BATCH) as u8;
            out.push(count);
            for frame in m.frames.iter().take(MAX_INPUT_BATCH) {
                out.extend_from_slice(&frame.seq.to_le_bytes());
                out.extend_from_slice(&frame.tick.to_le_bytes());
                out.extend_from_slice(&frame.move_x_i16.to_le_bytes());
                out.extend_from_slice(&frame.move_z_i16.to_le_bytes());
                out.extend_from_slice(&frame.local_x_i16.to_le_bytes());
                out.extend_from_slice(&frame.local_y_i16.to_le_bytes());
                out.extend_from_slice(&frame.buttons.to_le_bytes());
                out.extend_from_slice(&frame.aim_yaw_i16.to_le_bytes());
            }
        }
        NetMessage::ServerWorldSnapshot(m) => {
            out.extend_from_slice(&m.server_tick.to_le_bytes());
            out.extend_from_slice(&m.match_clock_ms.to_le_bytes());
            out.extend_from_slice(&m.shot_clock_ms.to_le_bytes());
            out.extend_from_slice(&m.score_a.to_le_bytes());
            out.extend_from_slice(&m.score_b.to_le_bytes());
            out.push(m.possession_team);
            out.extend_from_slice(&m.carrier_id.to_le_bytes());
            out.extend_from_slice(&m.ball_pos_x.to_le_bytes());
            out.extend_from_slice(&m.ball_pos_y.to_le_bytes());
            out.extend_from_slice(&m.ball_pos_z.to_le_bytes());
            out.extend_from_slice(&m.ball_vel_x.to_le_bytes());
            out.extend_from_slice(&m.ball_vel_y.to_le_bytes());
            out.extend_from_slice(&m.ball_vel_z.to_le_bytes());
            out.push(m.ball_state);
            let pcount = m.players.len().min(MAX_PLAYERS) as u8;
            out.push(pcount);
            for p in m.players.iter().take(MAX_PLAYERS) {
                out.extend_from_slice(&p.player_id.to_le_bytes());
                out.extend_from_slice(&p.last_processed_input_seq.to_le_bytes());
                out.extend_from_slice(&p.pos_x.to_le_bytes());
                out.extend_from_slice(&p.pos_y.to_le_bytes());
                out.extend_from_slice(&p.pos_z.to_le_bytes());
                out.extend_from_slice(&p.vel_x.to_le_bytes());
                out.extend_from_slice(&p.vel_y.to_le_bytes());
                out.extend_from_slice(&p.vel_z.to_le_bytes());
                out.extend_from_slice(&p.yaw.to_le_bytes());
                out.push(p.stamina_u8);
                out.push(p.zone_u8);
                out.push(p.balance_u8);
                out.push(pack_team_slot_arch(p.team_id, p.slot, p.archetype_id));
                out.extend_from_slice(&p.state_flags.to_le_bytes());
                out.extend_from_slice(&p.cooldown_flags.to_le_bytes());
                out.push(p.active_move_id);
            }
        }
        NetMessage::ReliableMatchEvent(m) => {
            out.extend_from_slice(&m.event_id.to_le_bytes());
            out.extend_from_slice(&m.server_tick.to_le_bytes());
            out.push(m.event.kind_code());
            match &m.event {
                MatchEventPayload::Score {
                    team_id,
                    delta,
                    is_three,
                    new_score,
                    scorer_id,
                } => {
                    out.push(*team_id);
                    out.push(*delta);
                    out.push(u8::from(*is_three));
                    out.extend_from_slice(&new_score.to_le_bytes());
                    out.extend_from_slice(&scorer_id.to_le_bytes());
                }
                MatchEventPayload::Possession {
                    team_id,
                    carrier_id,
                } => {
                    out.push(*team_id);
                    out.extend_from_slice(&carrier_id.to_le_bytes());
                }
                MatchEventPayload::Combo {
                    player_id,
                    move_id,
                    combo_tier,
                    is_perfect,
                    is_ex,
                } => {
                    out.extend_from_slice(&player_id.to_le_bytes());
                    out.push(*move_id);
                    out.push(*combo_tier);
                    let flags = u8::from(*is_perfect) | (u8::from(*is_ex) << 1);
                    out.push(flags);
                }
                MatchEventPayload::Steal {
                    stealer_id,
                    victim_id,
                    is_interception,
                    pos_x,
                    pos_y,
                    pos_z,
                } => {
                    out.extend_from_slice(&stealer_id.to_le_bytes());
                    out.extend_from_slice(&victim_id.to_le_bytes());
                    out.push(u8::from(*is_interception));
                    out.extend_from_slice(&pos_x.to_le_bytes());
                    out.extend_from_slice(&pos_y.to_le_bytes());
                    out.extend_from_slice(&pos_z.to_le_bytes());
                }
                MatchEventPayload::Block {
                    blocker_id,
                    shooter_id,
                    pos_x,
                    pos_y,
                    pos_z,
                } => {
                    out.extend_from_slice(&blocker_id.to_le_bytes());
                    out.extend_from_slice(&shooter_id.to_le_bytes());
                    out.extend_from_slice(&pos_x.to_le_bytes());
                    out.extend_from_slice(&pos_y.to_le_bytes());
                    out.extend_from_slice(&pos_z.to_le_bytes());
                }
                MatchEventPayload::AnkleBreak {
                    victim_id,
                    attacker_id,
                    pos_x,
                    pos_y,
                    pos_z,
                } => {
                    out.extend_from_slice(&victim_id.to_le_bytes());
                    out.extend_from_slice(&attacker_id.to_le_bytes());
                    out.extend_from_slice(&pos_x.to_le_bytes());
                    out.extend_from_slice(&pos_y.to_le_bytes());
                    out.extend_from_slice(&pos_z.to_le_bytes());
                }
                MatchEventPayload::Zone {
                    player_id,
                    activated,
                    duration_ms,
                } => {
                    out.extend_from_slice(&player_id.to_le_bytes());
                    out.push(u8::from(*activated));
                    out.extend_from_slice(&duration_ms.to_le_bytes());
                }
                MatchEventPayload::MatchEnd {
                    winner_team,
                    score_a,
                    score_b,
                } => {
                    out.push(*winner_team);
                    out.extend_from_slice(&score_a.to_le_bytes());
                    out.extend_from_slice(&score_b.to_le_bytes());
                }
            }
        }
        NetMessage::EventAck(m) => {
            out.extend_from_slice(&m.session_token.to_le_bytes());
            out.extend_from_slice(&m.event_id.to_le_bytes());
            out.extend_from_slice(&m.ack_mask.to_le_bytes());
        }
        NetMessage::Ping(m) => {
            out.extend_from_slice(&m.session_token.to_le_bytes());
            out.extend_from_slice(&m.client_time_ms.to_le_bytes());
        }
        NetMessage::Pong(m) => {
            out.extend_from_slice(&m.client_time_ms.to_le_bytes());
            out.extend_from_slice(&m.server_tick.to_le_bytes());
            out.extend_from_slice(&m.server_time_ms.to_le_bytes());
        }
        NetMessage::ReconnectRequest(m) => {
            out.extend_from_slice(&m.session_token.to_le_bytes());
            out.extend_from_slice(&m.last_acked_event_id.to_le_bytes());
        }
        NetMessage::SpectatorJoin(m) => {
            write_short_string(&mut out, &m.room_id, 32);
            write_short_string(&mut out, &m.spectator_name, 32);
        }
    }

    out
}

pub fn decode_packet(buf: &[u8]) -> Result<Packet, CodecError> {
    if buf.len() < HEADER_SIZE {
        return Err(CodecError::PacketTooShort {
            expected: HEADER_SIZE,
            actual: buf.len(),
        });
    }

    let mut cur = Cursor::new(buf);
    let magic = cur.read_u16()?;
    if magic != PROTOCOL_MAGIC {
        return Err(CodecError::InvalidMagic(magic));
    }
    let version = cur.read_u8()?;
    if version != PROTOCOL_VERSION {
        return Err(CodecError::UnsupportedVersion(version));
    }
    let msg_type = cur.read_u8()?;
    let seq = cur.read_u32()?;
    let ack = cur.read_u32()?;
    let ack_bits = cur.read_u32()?;

    let header = PacketHeader {
        magic,
        version,
        msg_type,
        seq,
        ack,
        ack_bits,
    };

    let payload = match msg_type {
        MSG_HELLO_JOIN => {
            let username = cur.read_short_string(32)?;
            let archetype_id = cur.read_u8()?;
            let room_id = cur.read_short_string(32)?;
            let auth_token = cur.read_short_string(64)?;
            let preferred_team = cur.read_u8()?;
            NetMessage::HelloJoin(HelloJoinMsg {
                username,
                archetype_id,
                room_id,
                auth_token,
                preferred_team,
            })
        }
        MSG_WELCOME_JOINED => {
            let player_id = cur.read_u32()?;
            let team_id = cur.read_u8()?;
            let assigned_slot = cur.read_u8()?;
            let archetype_id = cur.read_u8()?;
            let _reserved = cur.read_u8()?;
            let session_token = cur.read_u64()?;
            let server_tick = cur.read_u32()?;
            let tick_rate = cur.read_u16()?;
            let snapshot_rate = cur.read_u16()?;
            NetMessage::WelcomeJoined(WelcomeJoinedMsg {
                player_id,
                team_id,
                assigned_slot,
                archetype_id,
                session_token,
                server_tick,
                tick_rate,
                snapshot_rate,
            })
        }
        MSG_CLIENT_INPUT_BATCH => {
            let session_token = cur.read_u64()?;
            let count = cur.read_u8()?;
            if count == 0 || (count as usize) > MAX_INPUT_BATCH {
                return Err(CodecError::InvalidBatchCount(count));
            }
            let mut frames = Vec::with_capacity(count as usize);
            for _ in 0..count {
                let f_seq = cur.read_u32()?;
                let tick = cur.read_u32()?;
                let move_x_i16 = cur.read_i16()?;
                let move_z_i16 = cur.read_i16()?;
                let local_x_i16 = cur.read_i16()?;
                let local_y_i16 = cur.read_i16()?;
                let buttons = cur.read_u16()?;
                let aim_yaw_i16 = cur.read_i16()?;
                frames.push(PlayerInputFrameWire {
                    seq: f_seq,
                    tick,
                    move_x_i16,
                    move_z_i16,
                    local_x_i16,
                    local_y_i16,
                    buttons,
                    aim_yaw_i16,
                });
            }
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token,
                frames,
            })
        }
        MSG_SERVER_WORLD_SNAPSHOT => {
            let server_tick = cur.read_u32()?;
            let match_clock_ms = cur.read_u32()?;
            let shot_clock_ms = cur.read_u16()?;
            let score_a = cur.read_u16()?;
            let score_b = cur.read_u16()?;
            let possession_team = cur.read_u8()?;
            let carrier_id = cur.read_u16()?;
            let ball_pos_x = cur.read_i16()?;
            let ball_pos_y = cur.read_i16()?;
            let ball_pos_z = cur.read_i16()?;
            let ball_vel_x = cur.read_i16()?;
            let ball_vel_y = cur.read_i16()?;
            let ball_vel_z = cur.read_i16()?;
            let ball_state = cur.read_u8()?;
            let pcount = cur.read_u8()?;
            if (pcount as usize) > MAX_PLAYERS {
                return Err(CodecError::InvalidPlayerCount(pcount));
            }
            let mut players = Vec::with_capacity(pcount as usize);
            for _ in 0..pcount {
                let player_id = cur.read_u16()?;
                let last_processed_input_seq = cur.read_u32()?;
                let pos_x = cur.read_i16()?;
                let pos_y = cur.read_i16()?;
                let pos_z = cur.read_i16()?;
                let vel_x = cur.read_i16()?;
                let vel_y = cur.read_i16()?;
                let vel_z = cur.read_i16()?;
                let yaw = cur.read_i16()?;
                let stamina_u8 = cur.read_u8()?;
                let zone_u8 = cur.read_u8()?;
                let balance_u8 = cur.read_u8()?;
                let packed = cur.read_u8()?;
                let (team_id, slot, archetype_id) = unpack_team_slot_arch(packed);
                let state_flags = cur.read_u16()?;
                let cooldown_flags = cur.read_u16()?;
                let active_move_id = cur.read_u8()?;
                players.push(QuantizedPlayerState {
                    player_id,
                    last_processed_input_seq,
                    pos_x,
                    pos_y,
                    pos_z,
                    vel_x,
                    vel_y,
                    vel_z,
                    yaw,
                    stamina_u8,
                    zone_u8,
                    balance_u8,
                    team_id,
                    slot,
                    archetype_id,
                    state_flags,
                    cooldown_flags,
                    active_move_id,
                });
            }
            NetMessage::ServerWorldSnapshot(ServerWorldSnapshotMsg {
                server_tick,
                match_clock_ms,
                shot_clock_ms,
                score_a,
                score_b,
                possession_team,
                carrier_id,
                ball_pos_x,
                ball_pos_y,
                ball_pos_z,
                ball_vel_x,
                ball_vel_y,
                ball_vel_z,
                ball_state,
                players,
            })
        }
        MSG_RELIABLE_MATCH_EVENT => {
            let event_id = cur.read_u32()?;
            let server_tick = cur.read_u32()?;
            let kind = cur.read_u8()?;
            let event = match kind {
                EVENT_SCORE => MatchEventPayload::Score {
                    team_id: cur.read_u8()?,
                    delta: cur.read_u8()?,
                    is_three: cur.read_u8()? != 0,
                    new_score: cur.read_u16()?,
                    scorer_id: cur.read_u16()?,
                },
                EVENT_POSSESSION => MatchEventPayload::Possession {
                    team_id: cur.read_u8()?,
                    carrier_id: cur.read_u16()?,
                },
                EVENT_COMBO => {
                    let player_id = cur.read_u16()?;
                    let move_id = cur.read_u8()?;
                    let combo_tier = cur.read_u8()?;
                    let flags = cur.read_u8()?;
                    MatchEventPayload::Combo {
                        player_id,
                        move_id,
                        combo_tier,
                        is_perfect: (flags & 0x01) != 0,
                        is_ex: (flags & 0x02) != 0,
                    }
                }
                EVENT_STEAL => MatchEventPayload::Steal {
                    stealer_id: cur.read_u16()?,
                    victim_id: cur.read_u16()?,
                    is_interception: cur.read_u8()? != 0,
                    pos_x: cur.read_i16()?,
                    pos_y: cur.read_i16()?,
                    pos_z: cur.read_i16()?,
                },
                EVENT_BLOCK => MatchEventPayload::Block {
                    blocker_id: cur.read_u16()?,
                    shooter_id: cur.read_u16()?,
                    pos_x: cur.read_i16()?,
                    pos_y: cur.read_i16()?,
                    pos_z: cur.read_i16()?,
                },
                EVENT_ANKLE_BREAK => MatchEventPayload::AnkleBreak {
                    victim_id: cur.read_u16()?,
                    attacker_id: cur.read_u16()?,
                    pos_x: cur.read_i16()?,
                    pos_y: cur.read_i16()?,
                    pos_z: cur.read_i16()?,
                },
                EVENT_ZONE => MatchEventPayload::Zone {
                    player_id: cur.read_u16()?,
                    activated: cur.read_u8()? != 0,
                    duration_ms: cur.read_u16()?,
                },
                EVENT_MATCH_END => MatchEventPayload::MatchEnd {
                    winner_team: cur.read_u8()?,
                    score_a: cur.read_u16()?,
                    score_b: cur.read_u16()?,
                },
                other => return Err(CodecError::UnknownEventKind(other)),
            };
            NetMessage::ReliableMatchEvent(ReliableMatchEventMsg {
                event_id,
                server_tick,
                event,
            })
        }
        MSG_EVENT_ACK => NetMessage::EventAck(EventAckMsg {
            session_token: cur.read_u64()?,
            event_id: cur.read_u32()?,
            ack_mask: cur.read_u32()?,
        }),
        MSG_PING => NetMessage::Ping(PingMsg {
            session_token: cur.read_u64()?,
            client_time_ms: cur.read_u64()?,
        }),
        MSG_PONG => NetMessage::Pong(PongMsg {
            client_time_ms: cur.read_u64()?,
            server_tick: cur.read_u32()?,
            server_time_ms: cur.read_u64()?,
        }),
        MSG_RECONNECT_REQUEST => NetMessage::ReconnectRequest(ReconnectRequestMsg {
            session_token: cur.read_u64()?,
            last_acked_event_id: cur.read_u32()?,
        }),
        MSG_SPECTATOR_JOIN => NetMessage::SpectatorJoin(SpectatorJoinMsg {
            room_id: cur.read_short_string(32)?,
            spectator_name: cur.read_short_string(32)?,
        }),
        other => return Err(CodecError::UnknownMessageType(other)),
    };

    Ok(Packet { header, payload })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_3v3_size_is_under_260_bytes() {
        let mut players = Vec::new();
        for i in 0..6u16 {
            players.push(QuantizedPlayerState {
                player_id: i + 1,
                last_processed_input_seq: 1200 + i as u32,
                pos_x: quantize_pos_vel((i as f32) - 2.5),
                pos_y: quantize_pos_vel(0.0),
                pos_z: quantize_pos_vel((i as f32) * 2.0 - 5.0),
                vel_x: quantize_pos_vel(3.2),
                vel_y: quantize_pos_vel(0.0),
                vel_z: quantize_pos_vel(-4.1),
                yaw: quantize_yaw(1.25),
                stamina_u8: quantize_meter(92.5),
                zone_u8: quantize_meter(45.0),
                balance_u8: quantize_meter(100.0),
                team_id: (i % 2) as u8,
                slot: i as u8,
                archetype_id: (i % 5) as u8,
                state_flags: STATE_GROUNDED | STATE_SPRINTING,
                cooldown_flags: CD_PHANTOM_DRIVE,
                active_move_id: 1,
            });
        }
        let pkt = Packet::new(
            42,
            41,
            0xFFFF_FFFF,
            NetMessage::ServerWorldSnapshot(ServerWorldSnapshotMsg {
                server_tick: 1800,
                match_clock_ms: 150_000,
                shot_clock_ms: 19_500,
                score_a: 12,
                score_b: 9,
                possession_team: 0,
                carrier_id: 1,
                ball_pos_x: quantize_pos_vel(1.25),
                ball_pos_y: quantize_pos_vel(1.10),
                ball_pos_z: quantize_pos_vel(-3.50),
                ball_vel_x: quantize_pos_vel(0.0),
                ball_vel_y: quantize_pos_vel(-4.2),
                ball_vel_z: quantize_pos_vel(0.0),
                ball_state: 2,
                players,
            }),
        );

        let bytes = encode_packet(&pkt);
        assert_eq!(bytes.len(), 221, "6-player snapshot should be exact 221 bytes");
        assert!(bytes.len() < 260);
        // 30 Hz bandwidth check: < 8 KB/s
        assert!(bytes.len() * 30 < 8_000);
        let decoded = decode_packet(&bytes).expect("decode snapshot");
        assert_eq!(decoded, pkt);
    }

    #[test]
    fn roundtrip_all_message_variants() {
        let cases = vec![
            NetMessage::HelloJoin(HelloJoinMsg {
                username: "VoltPlayer".into(),
                archetype_id: 0,
                room_id: "arena-1".into(),
                auth_token: "".into(),
                preferred_team: 255,
            }),
            NetMessage::WelcomeJoined(WelcomeJoinedMsg {
                player_id: 7,
                team_id: 1,
                assigned_slot: 3,
                archetype_id: 2,
                session_token: 0x1234_5678_9ABC_DEF0,
                server_tick: 900,
                tick_rate: 60,
                snapshot_rate: 30,
            }),
            NetMessage::ClientInputBatch(ClientInputBatchMsg {
                session_token: 999,
                frames: vec![
                    PlayerInputFrameWire::from_floats(10, 100, 0.5, -0.5, 0.0, 1.0, BTN_SPRINT, 0.75),
                    PlayerInputFrameWire::from_floats(11, 101, 1.0, 0.0, 1.0, 0.0, BTN_SHOOT, -1.57),
                ],
            }),
            NetMessage::ReliableMatchEvent(ReliableMatchEventMsg {
                event_id: 5,
                server_tick: 300,
                event: MatchEventPayload::Score {
                    team_id: 0,
                    delta: 3,
                    is_three: true,
                    new_score: 9,
                    scorer_id: 2,
                },
            }),
            NetMessage::EventAck(EventAckMsg {
                session_token: 12345,
                event_id: 5,
                ack_mask: 0b1111,
            }),
            NetMessage::Ping(PingMsg {
                session_token: 42,
                client_time_ms: 987_654,
            }),
            NetMessage::Pong(PongMsg {
                client_time_ms: 987_654,
                server_tick: 500,
                server_time_ms: 1_234_567,
            }),
            NetMessage::ReconnectRequest(ReconnectRequestMsg {
                session_token: 0x00FF_EE11_2233_4455,
                last_acked_event_id: 14,
            }),
            NetMessage::SpectatorJoin(SpectatorJoinMsg {
                room_id: "default".into(),
                spectator_name: "CameraBot".into(),
            }),
        ];

        for (idx, msg) in cases.into_iter().enumerate() {
            let pkt = Packet::new(idx as u32 + 1, idx as u32, 0x5, msg);
            let bytes = encode_packet(&pkt);
            let decoded = decode_packet(&bytes).expect("roundtrip decode");
            assert_eq!(decoded, pkt);
        }
    }
}
