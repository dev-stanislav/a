class_name ProtocolSerializer
extends RefCounted
## Byte-exact little-endian UDP wire codec matching server/src/protocol/codec.rs 100%.

const MAGIC: int = 0x5043 # "PC"
const PROTOCOL_VERSION: int = 1
const HEADER_SIZE: int = 16
const MAX_INPUT_BATCH: int = 4
const MAX_PLAYERS: int = 6

const AXIS_SCALE: float = 10000.0
const YAW_SCALE: float = 10000.0
const POS_VEL_SCALE: float = 100.0
const METER_SCALE: float = 2.0

# Message types (0x01..0x0A)
const MSG_HELLO_JOIN: int = 0x01
const MSG_WELCOME_JOINED: int = 0x02
const MSG_CLIENT_INPUT_BATCH: int = 0x03
const MSG_SERVER_WORLD_SNAPSHOT: int = 0x04
const MSG_RELIABLE_MATCH_EVENT: int = 0x05
const MSG_EVENT_ACK: int = 0x06
const MSG_PING: int = 0x07
const MSG_PONG: int = 0x08
const MSG_RECONNECT_REQUEST: int = 0x09
const MSG_SPECTATOR_JOIN: int = 0x0A

# Player state flags
const STATE_GROUNDED: int = 1 << 0
const STATE_SPRINTING: int = 1 << 1
const STATE_DEFENSIVE_STANCE: int = 1 << 2
const STATE_ZONE_ACTIVE: int = 1 << 3
const STATE_ANKLE_BROKEN: int = 1 << 4
const STATE_CHARGING_SHOT: int = 1 << 5
const STATE_DUNKING: int = 1 << 6
const STATE_STEAL_STARTUP: int = 1 << 7
const STATE_STEAL_ACTIVE: int = 1 << 8
const STATE_STEAL_WHIFF_RECOVERY: int = 1 << 9
const STATE_BLOCK_RECOVERY: int = 1 << 10
const STATE_PHANTOM_PHASING: int = 1 << 11
const STATE_STEAL_SHIELDED: int = 1 << 12
const STATE_ARMORED: int = 1 << 13
const STATE_DISCONNECTED_GRACE: int = 1 << 14
const STATE_DRIBBLE_HAND_RIGHT: int = 1 << 15

# Cooldown & buff flags
const CD_PHANTOM_DRIVE: int = 1 << 0
const CD_METEOR_DUNK: int = 1 << 1
const CD_ANKLE_BREAKER: int = 1 << 2
const CD_MIRROR_STEP: int = 1 << 3
const CD_UNIQUE_SKILL: int = 1 << 4
const CD_STEAL: int = 1 << 5
const CD_BLOCK: int = 1 << 6
const CD_DRIBBLE_NORMAL: int = 1 << 7
const BUFF_DEFENSE_COUNTER: int = 1 << 8
const BUFF_SHOT_BONUS: int = 1 << 9

# Reliable event kind codes
const EVENT_SCORE: int = 1
const EVENT_POSSESSION: int = 2
const EVENT_COMBO: int = 3
const EVENT_STEAL: int = 4
const EVENT_BLOCK: int = 5
const EVENT_ANKLE_BREAK: int = 6
const EVENT_ZONE: int = 7
const EVENT_MATCH_END: int = 8

const ARCHETYPE_NAMES: Array[String] = [
	"speedster",
	"sharpshooter",
	"playmaker",
	"powerhouse",
	"all_rounder",
]

const MOVE_NAMES: Array[String] = [
	"",
	"phantom_drive",
	"meteor_dunk",
	"ankle_breaker",
	"mirror_step",
	"volt_dash",
	"starlight_high_arc",
	"mirage_thread",
	"tectonic_slam",
	"eclipse_counter",
	"crossover",
	"behind_the_back",
	"spin",
	"stepback",
	"hesitation",
]


static func archetype_name_to_u8(raw_id: String) -> int:
	var key: String = raw_id.strip_edges().to_lower()
	match key:
		"speedster", "phantom_pg", "volt", "pg":
			return 0
		"sharpshooter", "deadeye", "sg":
			return 1
		"playmaker", "mirage", "sf":
			return 2
		"powerhouse", "titan", "pf", "c", "rim_titan":
			return 3
		_:
			return 4


static func u8_to_archetype_name(code: int) -> String:
	if code >= 0 and code < ARCHETYPE_NAMES.size():
		return ARCHETYPE_NAMES[code]
	return "all_rounder"


static func move_id_to_name(move_id: int) -> String:
	if move_id >= 0 and move_id < MOVE_NAMES.size():
		return MOVE_NAMES[move_id]
	return ""


static func wrap_angle(rad: float) -> float:
	if is_nan(rad) or is_inf(rad):
		return 0.0
	var a: float = fposmod(rad + PI, TAU) - PI
	if a < -PI:
		a += TAU
	return a


static func quantize_axis(v: float) -> int:
	if is_nan(v) or is_inf(v):
		return 0
	return clampi(int(roundf(clampf(v, -1.0, 1.0) * AXIS_SCALE)), -10000, 10000)


static func dequantize_axis(q: int) -> float:
	return clampf(float(q) / AXIS_SCALE, -1.0, 1.0)


static func quantize_yaw(rad: float) -> int:
	var w: float = wrap_angle(rad)
	return clampi(int(roundf(w * YAW_SCALE)), -31416, 31416)


static func dequantize_yaw(q: int) -> float:
	return float(q) / YAW_SCALE


static func quantize_pos_vel(v: float) -> int:
	if is_nan(v) or is_inf(v):
		return 0
	return clampi(int(roundf(v * POS_VEL_SCALE)), -32767, 32767)


static func dequantize_pos_vel(q: int) -> float:
	return float(q) / POS_VEL_SCALE


static func quantize_meter(v: float) -> int:
	if is_nan(v) or is_inf(v):
		return 0
	return clampi(int(roundf(clampf(v, 0.0, 127.5) * METER_SCALE)), 0, 255)


static func dequantize_meter(q: int) -> float:
	return float(q) / METER_SCALE


static func pack_team_slot_arch(team_id: int, slot: int, archetype_id: int) -> int:
	return (team_id & 0x01) | ((slot & 0x07) << 1) | ((archetype_id & 0x0F) << 4)


static func _new_writer() -> StreamPeerBuffer:
	var peer := StreamPeerBuffer.new()
	peer.big_endian = false
	return peer


static func _write_header(peer: StreamPeerBuffer, msg_type: int, seq: int, ack: int, ack_bits: int) -> void:
	peer.put_u16(MAGIC)
	peer.put_u8(PROTOCOL_VERSION)
	peer.put_u8(msg_type)
	peer.put_u32(seq)
	peer.put_u32(ack)
	peer.put_u32(ack_bits)


static func _write_short_string(peer: StreamPeerBuffer, text: String, max_len: int) -> void:
	var utf8: PackedByteArray = text.to_utf8_buffer()
	var n: int = mini(utf8.size(), mini(max_len, 255))
	peer.put_u8(n)
	if n > 0:
		peer.put_data(utf8.slice(0, n))


static func _read_short_string(peer: StreamPeerBuffer, max_len: int) -> Variant:
	if peer.get_available_bytes() < 1:
		return null
	var n: int = peer.get_u8()
	if peer.get_available_bytes() < n:
		return null
	if n == 0:
		return ""
	var res: Array = peer.get_data(n)
	if int(res[0]) != OK:
		return null
	var raw: PackedByteArray = res[1]
	if raw.size() > max_len:
		raw = raw.slice(0, max_len)
	return raw.get_string_from_utf8()


static func encode_hello_join(
	username: String,
	archetype_id: Variant,
	room_id: String = "default",
	auth_token: String = "",
	preferred_team: int = 255,
	seq: int = 1,
	ack: int = 0,
	ack_bits: int = 0
) -> PackedByteArray:
	var peer := _new_writer()
	_write_header(peer, MSG_HELLO_JOIN, seq, ack, ack_bits)
	_write_short_string(peer, username, 32)
	var arch_u8: int = int(archetype_id) if archetype_id is int else archetype_name_to_u8(str(archetype_id))
	peer.put_u8(arch_u8)
	_write_short_string(peer, room_id, 32)
	_write_short_string(peer, auth_token, 64)
	peer.put_u8(clampi(preferred_team, 0, 255))
	return peer.data_array


static func encode_client_input_batch(
	session_token: int,
	frames: Array,
	seq: int = 1,
	ack: int = 0,
	ack_bits: int = 0
) -> PackedByteArray:
	var peer := _new_writer()
	_write_header(peer, MSG_CLIENT_INPUT_BATCH, seq, ack, ack_bits)
	peer.put_u64(session_token)
	var count: int = mini(frames.size(), MAX_INPUT_BATCH)
	peer.put_u8(count)
	for i in range(count):
		var f: Dictionary = frames[i]
		var move_xz: Vector2 = f.get("move_world_xz", Vector2.ZERO) if f.get("move_world_xz") is Vector2 else Vector2.ZERO
		var local_dir: Vector2 = f.get("local_dir", Vector2.ZERO) if f.get("local_dir") is Vector2 else Vector2.ZERO
		peer.put_u32(int(f.get("seq", 0)))
		peer.put_u32(int(f.get("tick", 0)))
		peer.put_16(quantize_axis(move_xz.x))
		peer.put_16(quantize_axis(move_xz.y))
		peer.put_16(quantize_axis(local_dir.x))
		peer.put_16(quantize_axis(local_dir.y))
		peer.put_u16(int(f.get("buttons", 0)) & 0xFFFF)
		peer.put_16(quantize_yaw(float(f.get("aim_yaw", 0.0))))
	return peer.data_array


static func encode_event_ack(
	session_token: int,
	event_id: int,
	ack_mask: int = 0,
	seq: int = 1,
	ack: int = 0,
	ack_bits: int = 0
) -> PackedByteArray:
	var peer := _new_writer()
	_write_header(peer, MSG_EVENT_ACK, seq, ack, ack_bits)
	peer.put_u64(session_token)
	peer.put_u32(event_id)
	peer.put_u32(ack_mask)
	return peer.data_array


static func encode_ping(
	session_token: int,
	client_time_ms: int,
	seq: int = 1,
	ack: int = 0,
	ack_bits: int = 0
) -> PackedByteArray:
	var peer := _new_writer()
	_write_header(peer, MSG_PING, seq, ack, ack_bits)
	peer.put_u64(session_token)
	peer.put_u64(client_time_ms)
	return peer.data_array


static func encode_reconnect_request(
	session_token: int,
	last_acked_event_id: int = 0,
	seq: int = 1,
	ack: int = 0,
	ack_bits: int = 0
) -> PackedByteArray:
	var peer := _new_writer()
	_write_header(peer, MSG_RECONNECT_REQUEST, seq, ack, ack_bits)
	peer.put_u64(session_token)
	peer.put_u32(last_acked_event_id)
	return peer.data_array


static func encode_spectator_join(
	room_id: String = "default",
	spectator_name: String = "Spectator",
	seq: int = 1,
	ack: int = 0,
	ack_bits: int = 0
) -> PackedByteArray:
	var peer := _new_writer()
	_write_header(peer, MSG_SPECTATOR_JOIN, seq, ack, ack_bits)
	_write_short_string(peer, room_id, 32)
	_write_short_string(peer, spectator_name, 32)
	return peer.data_array


static func encode_world_snapshot(
	snapshot: Dictionary,
	seq: int = 1,
	ack: int = 0,
	ack_bits: int = 0
) -> PackedByteArray:
	var peer := _new_writer()
	_write_header(peer, MSG_SERVER_WORLD_SNAPSHOT, seq, ack, ack_bits)
	peer.put_u32(int(snapshot.get("server_tick", 0)))
	peer.put_u32(int(snapshot.get("match_clock_ms", 180000)))
	peer.put_u16(int(snapshot.get("shot_clock_ms", 24000)))
	peer.put_u16(int(snapshot.get("score_a", 0)))
	peer.put_u16(int(snapshot.get("score_b", 0)))
	peer.put_u8(int(snapshot.get("possession_team", 255)))
	peer.put_u16(int(snapshot.get("carrier_id", 0)))

	var bpos: Vector3 = snapshot.get("ball_pos", Vector3.ZERO)
	var bvel: Vector3 = snapshot.get("ball_vel", Vector3.ZERO)
	peer.put_16(quantize_pos_vel(bpos.x))
	peer.put_16(quantize_pos_vel(bpos.y))
	peer.put_16(quantize_pos_vel(bpos.z))
	peer.put_16(quantize_pos_vel(bvel.x))
	peer.put_16(quantize_pos_vel(bvel.y))
	peer.put_16(quantize_pos_vel(bvel.z))
	peer.put_u8(int(snapshot.get("ball_state", 0)))

	var players: Array = snapshot.get("players", [])
	var pcount: int = mini(players.size(), MAX_PLAYERS)
	peer.put_u8(pcount)
	for i in range(pcount):
		var p: Dictionary = players[i]
		var pos: Vector3 = p.get("position", Vector3.ZERO)
		var vel: Vector3 = p.get("velocity", Vector3.ZERO)
		peer.put_u16(int(p.get("player_id", 0)))
		peer.put_u32(int(p.get("last_processed_input_seq", 0)))
		peer.put_16(quantize_pos_vel(pos.x))
		peer.put_16(quantize_pos_vel(pos.y))
		peer.put_16(quantize_pos_vel(pos.z))
		peer.put_16(quantize_pos_vel(vel.x))
		peer.put_16(quantize_pos_vel(vel.y))
		peer.put_16(quantize_pos_vel(vel.z))
		peer.put_16(quantize_yaw(float(p.get("yaw", 0.0))))
		peer.put_u8(quantize_meter(float(p.get("stamina", 100.0))))
		peer.put_u8(quantize_meter(float(p.get("zone", 0.0))))
		peer.put_u8(quantize_meter(float(p.get("balance", 100.0))))
		var arch_u8: int = int(p.get("archetype_u8", archetype_name_to_u8(str(p.get("archetype_id", "all_rounder")))))
		peer.put_u8(pack_team_slot_arch(int(p.get("team_id", 0)), int(p.get("slot", i)), arch_u8))
		peer.put_u16(int(p.get("state_flags", 0)) & 0xFFFF)
		peer.put_u16(int(p.get("cooldown_flags", 0)) & 0xFFFF)
		peer.put_u8(int(p.get("active_move_id", 0)) & 0xFF)
	return peer.data_array


static func decode_packet(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < HEADER_SIZE:
		return {"ok": false, "error": "packet_too_short"}

	var peer := StreamPeerBuffer.new()
	peer.big_endian = false
	peer.data_array = bytes

	var magic: int = peer.get_u16()
	if magic != MAGIC:
		return {"ok": false, "error": "invalid_magic"}
	var version: int = peer.get_u8()
	if version != PROTOCOL_VERSION:
		return {"ok": false, "error": "unsupported_version"}

	var msg_type: int = peer.get_u8()
	var seq: int = peer.get_u32()
	var ack: int = peer.get_u32()
	var ack_bits: int = peer.get_u32()

	var result: Dictionary = {
		"ok": true,
		"msg_type": msg_type,
		"seq": seq,
		"ack": ack,
		"ack_bits": ack_bits,
	}

	match msg_type:
		MSG_HELLO_JOIN:
			var uname: Variant = _read_short_string(peer, 32)
			if uname == null or peer.get_available_bytes() < 1:
				return {"ok": false, "error": "truncated_hello"}
			var arch_u8: int = peer.get_u8()
			var room: Variant = _read_short_string(peer, 32)
			var token: Variant = _read_short_string(peer, 64)
			if room == null or token == null or peer.get_available_bytes() < 1:
				return {"ok": false, "error": "truncated_hello"}
			var pref_team: int = peer.get_u8()
			result["payload"] = {
				"username": str(uname),
				"archetype_u8": arch_u8,
				"archetype_id": u8_to_archetype_name(arch_u8),
				"room_id": str(room),
				"auth_token": str(token),
				"preferred_team": pref_team,
			}

		MSG_WELCOME_JOINED:
			if peer.get_available_bytes() < 24:
				return {"ok": false, "error": "truncated_welcome"}
			var player_id: int = peer.get_u32()
			var team_id: int = peer.get_u8()
			var assigned_slot: int = peer.get_u8()
			var arch_u8: int = peer.get_u8()
			var _reserved: int = peer.get_u8()
			var session_token: int = peer.get_u64()
			var server_tick: int = peer.get_u32()
			var tick_rate: int = peer.get_u16()
			var snapshot_rate: int = peer.get_u16()
			result["payload"] = {
				"player_id": player_id,
				"team_id": team_id,
				"assigned_slot": assigned_slot,
				"archetype_u8": arch_u8,
				"archetype_id": u8_to_archetype_name(arch_u8),
				"session_token": session_token,
				"server_tick": server_tick,
				"tick_rate": tick_rate,
				"snapshot_rate": snapshot_rate,
			}

		MSG_CLIENT_INPUT_BATCH:
			if peer.get_available_bytes() < 9:
				return {"ok": false, "error": "truncated_input_batch"}
			var session_token: int = peer.get_u64()
			var count: int = peer.get_u8()
			if count < 1 or count > MAX_INPUT_BATCH or peer.get_available_bytes() < count * 20:
				return {"ok": false, "error": "invalid_input_batch"}
			var frames: Array[Dictionary] = []
			for _i in range(count):
				var f_seq: int = peer.get_u32()
				var f_tick: int = peer.get_u32()
				var mx: float = dequantize_axis(peer.get_16())
				var mz: float = dequantize_axis(peer.get_16())
				var lx: float = dequantize_axis(peer.get_16())
				var ly: float = dequantize_axis(peer.get_16())
				var btns: int = peer.get_u16()
				var yaw: float = dequantize_yaw(peer.get_16())
				frames.append({
					"seq": f_seq,
					"tick": f_tick,
					"move_world_xz": Vector2(mx, mz),
					"local_dir": Vector2(lx, ly),
					"buttons": btns,
					"aim_yaw": yaw,
				})
			result["payload"] = {
				"session_token": session_token,
				"frames": frames,
			}

		MSG_SERVER_WORLD_SNAPSHOT:
			if peer.get_available_bytes() < 31:
				return {"ok": false, "error": "truncated_snapshot"}
			var server_tick: int = peer.get_u32()
			var match_clock_ms: int = peer.get_u32()
			var shot_clock_ms: int = peer.get_u16()
			var score_a: int = peer.get_u16()
			var score_b: int = peer.get_u16()
			var possession_team: int = peer.get_u8()
			var carrier_id: int = peer.get_u16()
			var ball_pos := Vector3(
				dequantize_pos_vel(peer.get_16()),
				dequantize_pos_vel(peer.get_16()),
				dequantize_pos_vel(peer.get_16())
			)
			var ball_vel := Vector3(
				dequantize_pos_vel(peer.get_16()),
				dequantize_pos_vel(peer.get_16()),
				dequantize_pos_vel(peer.get_16())
			)
			var ball_state: int = peer.get_u8()
			var pcount: int = peer.get_u8()
			if pcount > MAX_PLAYERS or peer.get_available_bytes() < pcount * 29:
				return {"ok": false, "error": "truncated_snapshot_players"}

			var players: Array[Dictionary] = []
			for _i in range(pcount):
				var pid: int = peer.get_u16()
				var last_seq: int = peer.get_u32()
				var pos := Vector3(
					dequantize_pos_vel(peer.get_16()),
					dequantize_pos_vel(peer.get_16()),
					dequantize_pos_vel(peer.get_16())
				)
				var vel := Vector3(
					dequantize_pos_vel(peer.get_16()),
					dequantize_pos_vel(peer.get_16()),
					dequantize_pos_vel(peer.get_16())
				)
				var yaw: float = dequantize_yaw(peer.get_16())
				var stamina: float = dequantize_meter(peer.get_u8())
				var zone: float = dequantize_meter(peer.get_u8())
				var balance: float = dequantize_meter(peer.get_u8())
				var packed: int = peer.get_u8()
				var team_id: int = packed & 0x01
				var slot: int = (packed >> 1) & 0x07
				var arch_u8: int = (packed >> 4) & 0x0F
				var state_flags: int = peer.get_u16()
				var cooldown_flags: int = peer.get_u16()
				var active_move_id: int = peer.get_u8()
				players.append({
					"player_id": pid,
					"last_processed_input_seq": last_seq,
					"position": pos,
					"velocity": vel,
					"yaw": yaw,
					"stamina": stamina,
					"zone": zone,
					"balance": balance,
					"team_id": team_id,
					"slot": slot,
					"archetype_u8": arch_u8,
					"archetype_id": u8_to_archetype_name(arch_u8),
					"state_flags": state_flags,
					"cooldown_flags": cooldown_flags,
					"active_move_id": active_move_id,
					"active_move_name": move_id_to_name(active_move_id),
				})
			result["payload"] = {
				"server_tick": server_tick,
				"match_clock_ms": match_clock_ms,
				"shot_clock_ms": shot_clock_ms,
				"score_a": score_a,
				"score_b": score_b,
				"possession_team": possession_team,
				"carrier_id": carrier_id,
				"ball_pos": ball_pos,
				"ball_vel": ball_vel,
				"ball_state": ball_state,
				"players": players,
			}

		MSG_RELIABLE_MATCH_EVENT:
			if peer.get_available_bytes() < 9:
				return {"ok": false, "error": "truncated_event"}
			var event_id: int = peer.get_u32()
			var server_tick: int = peer.get_u32()
			var kind: int = peer.get_u8()
			var ev: Dictionary = {
				"event_id": event_id,
				"server_tick": server_tick,
				"kind": kind,
			}
			match kind:
				EVENT_SCORE:
					if peer.get_available_bytes() < 7:
						return {"ok": false, "error": "truncated_score_event"}
					ev["team_id"] = peer.get_u8()
					ev["delta"] = peer.get_u8()
					ev["is_three"] = peer.get_u8() != 0
					ev["new_score"] = peer.get_u16()
					ev["scorer_id"] = peer.get_u16()
				EVENT_POSSESSION:
					if peer.get_available_bytes() < 3:
						return {"ok": false, "error": "truncated_possession_event"}
					ev["team_id"] = peer.get_u8()
					ev["carrier_id"] = peer.get_u16()
				EVENT_COMBO:
					if peer.get_available_bytes() < 5:
						return {"ok": false, "error": "truncated_combo_event"}
					ev["player_id"] = peer.get_u16()
					var move_u8: int = peer.get_u8()
					ev["move_id"] = move_u8
					ev["combo_id"] = move_id_to_name(move_u8)
					ev["combo_tier"] = peer.get_u8()
					var cflags: int = peer.get_u8()
					ev["is_perfect"] = (cflags & 0x01) != 0
					ev["is_ex"] = (cflags & 0x02) != 0
				EVENT_STEAL:
					if peer.get_available_bytes() < 11:
						return {"ok": false, "error": "truncated_steal_event"}
					ev["stealer_id"] = peer.get_u16()
					ev["victim_id"] = peer.get_u16()
					ev["is_interception"] = peer.get_u8() != 0
					ev["world_pos"] = Vector3(
						dequantize_pos_vel(peer.get_16()),
						dequantize_pos_vel(peer.get_16()),
						dequantize_pos_vel(peer.get_16())
					)
				EVENT_BLOCK:
					if peer.get_available_bytes() < 10:
						return {"ok": false, "error": "truncated_block_event"}
					ev["blocker_id"] = peer.get_u16()
					ev["shooter_id"] = peer.get_u16()
					ev["world_pos"] = Vector3(
						dequantize_pos_vel(peer.get_16()),
						dequantize_pos_vel(peer.get_16()),
						dequantize_pos_vel(peer.get_16())
					)
				EVENT_ANKLE_BREAK:
					if peer.get_available_bytes() < 10:
						return {"ok": false, "error": "truncated_ankle_event"}
					ev["victim_id"] = peer.get_u16()
					ev["attacker_id"] = peer.get_u16()
					ev["world_pos"] = Vector3(
						dequantize_pos_vel(peer.get_16()),
						dequantize_pos_vel(peer.get_16()),
						dequantize_pos_vel(peer.get_16())
					)
				EVENT_ZONE:
					if peer.get_available_bytes() < 5:
						return {"ok": false, "error": "truncated_zone_event"}
					ev["player_id"] = peer.get_u16()
					ev["activated"] = peer.get_u8() != 0
					ev["duration_ms"] = peer.get_u16()
				EVENT_MATCH_END:
					if peer.get_available_bytes() < 5:
						return {"ok": false, "error": "truncated_match_end_event"}
					ev["winner_team"] = peer.get_u8()
					ev["score_a"] = peer.get_u16()
					ev["score_b"] = peer.get_u16()
				_:
					return {"ok": false, "error": "unknown_event_kind"}
			result["payload"] = ev

		MSG_EVENT_ACK:
			if peer.get_available_bytes() < 16:
				return {"ok": false, "error": "truncated_event_ack"}
			var ack_tok: int = peer.get_u64()
			var ack_eid: int = peer.get_u32()
			var ack_m: int = peer.get_u32()
			result["payload"] = {
				"session_token": ack_tok,
				"event_id": ack_eid,
				"ack_mask": ack_m,
			}

		MSG_PING:
			if peer.get_available_bytes() < 16:
				return {"ok": false, "error": "truncated_ping"}
			var ping_tok: int = peer.get_u64()
			var ping_ms: int = peer.get_u64()
			result["payload"] = {
				"session_token": ping_tok,
				"client_time_ms": ping_ms,
			}

		MSG_PONG:
			if peer.get_available_bytes() < 20:
				return {"ok": false, "error": "truncated_pong"}
			var pong_client_ms: int = peer.get_u64()
			var pong_srv_tick: int = peer.get_u32()
			var pong_srv_ms: int = peer.get_u64()
			result["payload"] = {
				"client_time_ms": pong_client_ms,
				"server_tick": pong_srv_tick,
				"server_time_ms": pong_srv_ms,
			}

		MSG_RECONNECT_REQUEST:
			if peer.get_available_bytes() < 12:
				return {"ok": false, "error": "truncated_reconnect"}
			var rec_tok: int = peer.get_u64()
			var rec_last_eid: int = peer.get_u32()
			result["payload"] = {
				"session_token": rec_tok,
				"last_acked_event_id": rec_last_eid,
			}

		MSG_SPECTATOR_JOIN:
			var room: Variant = _read_short_string(peer, 32)
			var spec_name: Variant = _read_short_string(peer, 32)
			if room == null or spec_name == null:
				return {"ok": false, "error": "truncated_spectator_join"}
			result["payload"] = {
				"room_id": str(room),
				"spectator_name": str(spec_name),
			}

		_:
			return {"ok": false, "error": "unknown_msg_type"}

	return result
