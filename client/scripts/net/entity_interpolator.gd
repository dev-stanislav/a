class_name EntityInterpolator
extends RefCounted
## Buffered 100ms snapshot interpolation for remote players & basketball,
## with capped 80ms velocity dead-reckoning during packet burst loss.

const DEFAULT_INTERP_DELAY_MS: float = 100.0
const DEFAULT_MAX_EXTRAPOLATION_MS: float = 80.0
const MAX_SNAPSHOT_BUFFER: int = 32

const COURT_HALF_WIDTH: float = 7.5
const COURT_HALF_LENGTH: float = 14.0

var interp_delay_ms: float = DEFAULT_INTERP_DELAY_MS
var max_extrapolation_ms: float = DEFAULT_MAX_EXTRAPOLATION_MS

var _ball_buffer: Array[Dictionary] = []
var _player_buffers: Dictionary = {} # player_id: int -> Array[Dictionary]
var _latest_server_time_ms: float = 0.0
var _latest_server_tick: int = 0


func clear() -> void:
	_ball_buffer.clear()
	_player_buffers.clear()
	_latest_server_time_ms = 0.0
	_latest_server_tick = 0


func get_effective_delay_ms() -> float:
	return interp_delay_ms


func get_latest_server_tick() -> int:
	return _latest_server_tick


func get_tracked_player_ids() -> Array[int]:
	var ids: Array[int] = []
	for k in _player_buffers.keys():
		ids.append(int(k))
	ids.sort()
	return ids


## Pushes a decoded ServerWorldSnapshot at `timestamp_ms` (typically server_tick * 1000.0 / 60.0 or local clock).
func push_world_snapshot(snapshot: Dictionary, timestamp_ms: float = -1.0) -> void:
	var tick: int = int(snapshot.get("server_tick", 0))
	var ts_ms: float = timestamp_ms if timestamp_ms >= 0.0 else (float(tick) * (1000.0 / 60.0))
	if ts_ms > _latest_server_time_ms:
		_latest_server_time_ms = ts_ms
	if tick > _latest_server_tick:
		_latest_server_tick = tick

	var ball_entry: Dictionary = {
		"time_ms": ts_ms,
		"tick": tick,
		"position": snapshot.get("ball_pos", Vector3.ZERO),
		"velocity": snapshot.get("ball_vel", Vector3.ZERO),
		"ball_state": int(snapshot.get("ball_state", 0)),
		"carrier_id": int(snapshot.get("carrier_id", 0)),
	}
	_insert_sorted(_ball_buffer, ball_entry)

	var players: Array = snapshot.get("players", [])
	for p_variant in players:
		if not (p_variant is Dictionary):
			continue
		var p: Dictionary = p_variant
		var pid: int = int(p.get("player_id", 0))
		if pid <= 0:
			continue
		var entry: Dictionary = {
			"time_ms": ts_ms,
			"tick": tick,
			"player_id": pid,
			"position": p.get("position", Vector3.ZERO),
			"velocity": p.get("velocity", Vector3.ZERO),
			"yaw": float(p.get("yaw", 0.0)),
			"stamina": float(p.get("stamina", 100.0)),
			"zone": float(p.get("zone", 0.0)),
			"balance": float(p.get("balance", 100.0)),
			"team_id": int(p.get("team_id", 0)),
			"slot": int(p.get("slot", 0)),
			"archetype_id": str(p.get("archetype_id", "all_rounder")),
			"state_flags": int(p.get("state_flags", 0)),
			"cooldown_flags": int(p.get("cooldown_flags", 0)),
			"active_move_id": int(p.get("active_move_id", 0)),
		}
		if not _player_buffers.has(pid):
			_player_buffers[pid] = [] as Array[Dictionary]
		_insert_sorted(_player_buffers[pid] as Array[Dictionary], entry)


func push_player_sample(player_id: int, timestamp_ms: float, state: Dictionary) -> void:
	if player_id <= 0:
		return
	var entry: Dictionary = state.duplicate(true)
	entry["player_id"] = player_id
	entry["time_ms"] = timestamp_ms
	if not _player_buffers.has(player_id):
		_player_buffers[player_id] = [] as Array[Dictionary]
	_insert_sorted(_player_buffers[player_id] as Array[Dictionary], entry)
	if timestamp_ms > _latest_server_time_ms:
		_latest_server_time_ms = timestamp_ms


func sample_ball(render_time_ms: float = -1.0) -> Dictionary:
	var ref_ms: float = render_time_ms if render_time_ms >= 0.0 else _latest_server_time_ms
	var target_ms: float = ref_ms - interp_delay_ms
	return _sample_buffer(_ball_buffer, target_ms, false)


func sample_player(player_id: int, render_time_ms: float = -1.0) -> Dictionary:
	if not _player_buffers.has(player_id):
		return {}
	var ref_ms: float = render_time_ms if render_time_ms >= 0.0 else _latest_server_time_ms
	var target_ms: float = ref_ms - interp_delay_ms
	return _sample_buffer(_player_buffers[player_id] as Array[Dictionary], target_ms, true)


func sample_world(render_time_ms: float = -1.0) -> Dictionary:
	var ref_ms: float = render_time_ms if render_time_ms >= 0.0 else _latest_server_time_ms
	var players_out: Dictionary = {}
	for pid in _player_buffers.keys():
		var sampled: Dictionary = sample_player(int(pid), ref_ms)
		if not sampled.is_empty():
			players_out[int(pid)] = sampled
	return {
		"render_time_ms": ref_ms,
		"interp_delay_ms": interp_delay_ms,
		"ball": sample_ball(ref_ms),
		"players": players_out,
	}


func is_extrapolating(player_id: int, render_time_ms: float) -> bool:
	if not _player_buffers.has(player_id):
		return false
	var buf: Array[Dictionary] = _player_buffers[player_id]
	if buf.is_empty():
		return false
	var target_ms: float = render_time_ms - interp_delay_ms
	return target_ms > float(buf[buf.size() - 1]["time_ms"])


func _insert_sorted(buf: Array[Dictionary], entry: Dictionary) -> void:
	var ts: float = float(entry["time_ms"])
	# Replace if duplicate timestamp, else insert in ascending order
	for i in range(buf.size() - 1, -1, -1):
		var cur_ts: float = float(buf[i]["time_ms"])
		if is_equal_approx(cur_ts, ts):
			buf[i] = entry
			return
		if cur_ts < ts:
			buf.insert(i + 1, entry)
			while buf.size() > MAX_SNAPSHOT_BUFFER:
				buf.pop_front()
			return
	buf.insert(0, entry)
	while buf.size() > MAX_SNAPSHOT_BUFFER:
		buf.pop_front()


func _sample_buffer(buf: Array[Dictionary], target_ms: float, is_player: bool) -> Dictionary:
	if buf.is_empty():
		return {}
	if buf.size() == 1:
		var only: Dictionary = buf[0].duplicate(true)
		only["extrapolated"] = false
		return only

	var first: Dictionary = buf[0]
	if target_ms <= float(first["time_ms"]):
		var out_first: Dictionary = first.duplicate(true)
		out_first["extrapolated"] = false
		return out_first

	var last: Dictionary = buf[buf.size() - 1]
	var last_t: float = float(last["time_ms"])
	if target_ms >= last_t:
		# Capped 80ms velocity dead-reckoning during packet burst loss
		var extra_ms: float = clampf(target_ms - last_t, 0.0, max_extrapolation_ms)
		var extra_sec: float = extra_ms / 1000.0
		var pos: Vector3 = last.get("position", Vector3.ZERO)
		var vel: Vector3 = last.get("velocity", Vector3.ZERO)
		var pred_pos: Vector3 = pos + vel * extra_sec
		pred_pos.x = clampf(pred_pos.x, -COURT_HALF_WIDTH, COURT_HALF_WIDTH)
		pred_pos.z = clampf(pred_pos.z, -COURT_HALF_LENGTH, COURT_HALF_LENGTH)
		pred_pos.y = maxf(0.0, pred_pos.y)
		var out_ext: Dictionary = last.duplicate(true)
		out_ext["position"] = pred_pos
		out_ext["extrapolated"] = extra_ms > 0.001
		out_ext["extrapolation_ms"] = extra_ms
		return out_ext

	# Find bracketing pair [a, b] where a.time_ms <= target_ms <= b.time_ms
	for i in range(buf.size() - 1):
		var a: Dictionary = buf[i]
		var b: Dictionary = buf[i + 1]
		var ta: float = float(a["time_ms"])
		var tb: float = float(b["time_ms"])
		if target_ms >= ta and target_ms <= tb:
			var span: float = maxf(0.0001, tb - ta)
			var alpha: float = clampf((target_ms - ta) / span, 0.0, 1.0)
			var out: Dictionary = b.duplicate(true)
			var pos_a: Vector3 = a.get("position", Vector3.ZERO)
			var pos_b: Vector3 = b.get("position", Vector3.ZERO)
			var vel_a: Vector3 = a.get("velocity", Vector3.ZERO)
			var vel_b: Vector3 = b.get("velocity", Vector3.ZERO)
			out["position"] = pos_a.lerp(pos_b, alpha)
			out["velocity"] = vel_a.lerp(vel_b, alpha)
			if is_player:
				out["yaw"] = lerp_angle(float(a.get("yaw", 0.0)), float(b.get("yaw", 0.0)), alpha)
				out["stamina"] = lerpf(float(a.get("stamina", 100.0)), float(b.get("stamina", 100.0)), alpha)
				out["zone"] = lerpf(float(a.get("zone", 0.0)), float(b.get("zone", 0.0)), alpha)
				out["balance"] = lerpf(float(a.get("balance", 100.0)), float(b.get("balance", 100.0)), alpha)
			out["extrapolated"] = false
			out["extrapolation_ms"] = 0.0
			return out

	return last.duplicate(true)
