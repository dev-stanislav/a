class_name PredictionReconciler
extends RefCounted
## Client-side 128-tick prediction ring buffer with authoritative rollback, input replay,
## and 4-frame smooth visual offset decay for PHANTOM COURT ONLINE.

const RING_CAPACITY: int = 128
const POSITION_ERROR_THRESHOLD: float = 0.05 # meters
const VELOCITY_ERROR_THRESHOLD: float = 0.45 # m/s
const VISUAL_DECAY_FRAMES: int = 4
const SNAP_TELEPORT_THRESHOLD: float = 6.0 # meters (snap immediately on inbound/reset)

# Critical state flags that trigger reconciliation on mismatch
const CRITICAL_STATE_MASK: int = (
	ProtocolSerializer.STATE_ZONE_ACTIVE
	| ProtocolSerializer.STATE_ANKLE_BROKEN
	| ProtocolSerializer.STATE_DUNKING
	| ProtocolSerializer.STATE_STEAL_WHIFF_RECOVERY
	| ProtocolSerializer.STATE_BLOCK_RECOVERY
)

var _ring: Array[Dictionary] = []
var _last_acked_seq: int = 0
var _reconciliation_count: int = 0
var _last_position_error: float = 0.0

var _visual_offset: Vector3 = Vector3.ZERO
var _visual_offset_initial: Vector3 = Vector3.ZERO
var _visual_decay_frames_left: int = 0


func _init() -> void:
	clear()


func clear() -> void:
	_ring.clear()
	_ring.resize(RING_CAPACITY)
	for i in range(RING_CAPACITY):
		_ring[i] = {"valid": false, "seq": 0}
	_last_acked_seq = 0
	_reconciliation_count = 0
	_last_position_error = 0.0
	_visual_offset = Vector3.ZERO
	_visual_offset_initial = Vector3.ZERO
	_visual_decay_frames_left = 0


func record_prediction(seq: int, input_frame: Dictionary, predicted_state: Dictionary) -> void:
	if seq <= 0:
		return
	var idx: int = posmod(seq, RING_CAPACITY)
	_ring[idx] = {
		"valid": true,
		"seq": seq,
		"tick": int(input_frame.get("tick", 0)),
		"input_frame": input_frame.duplicate(true),
		"predicted_state": predicted_state.duplicate(true),
	}


func get_prediction(seq: int) -> Dictionary:
	if seq <= 0:
		return {}
	var idx: int = posmod(seq, RING_CAPACITY)
	var entry: Dictionary = _ring[idx]
	if bool(entry.get("valid", false)) and int(entry.get("seq", 0)) == seq:
		return entry
	return {}


func get_pending_inputs_after(ack_seq: int) -> Array[Dictionary]:
	var pending: Array[Dictionary] = []
	for entry in _ring:
		if bool(entry.get("valid", false)) and int(entry.get("seq", 0)) > ack_seq:
			pending.append(entry)
	pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["seq"]) < int(b["seq"])
	)
	return pending


func discard_through(ack_seq: int) -> void:
	for i in range(RING_CAPACITY):
		if bool(_ring[i].get("valid", false)) and int(_ring[i].get("seq", 0)) <= ack_seq:
			_ring[i] = {"valid": false, "seq": 0}


func get_reconciliation_count() -> int:
	return _reconciliation_count


func get_last_position_error() -> float:
	return _last_position_error


func get_last_acked_seq() -> int:
	return _last_acked_seq


func get_visual_offset() -> Vector3:
	return _visual_offset


func step_visual_decay() -> Vector3:
	if _visual_decay_frames_left <= 0:
		_visual_offset = Vector3.ZERO
		return _visual_offset
	_visual_decay_frames_left -= 1
	if _visual_decay_frames_left <= 0:
		_visual_offset = Vector3.ZERO
	else:
		var ratio: float = float(_visual_decay_frames_left) / float(VISUAL_DECAY_FRAMES)
		_visual_offset = _visual_offset_initial * ratio
	return _visual_offset


## Reconciles local predicted history against an authoritative player state snapshot.
## - `apply_auth_callable`: `func(auth_state: Dictionary) -> void` (restores actor to server state)
## - `replay_callable`: `func(input_frame: Dictionary) -> Dictionary` (re-simulates 1 fixed tick and returns updated state dict)
## - `current_pos_callable`: optional `func() -> Vector3` to capture exact pre/post positions for smooth 4-frame visual decay.
func reconcile(
	auth_player_state: Dictionary,
	apply_auth_callable: Callable = Callable(),
	replay_callable: Callable = Callable(),
	current_pos_callable: Callable = Callable()
) -> Dictionary:
	var ack_seq: int = int(auth_player_state.get("last_processed_input_seq", 0))
	if ack_seq <= 0 or ack_seq <= _last_acked_seq:
		return {
			"corrected": false,
			"ack_seq": ack_seq,
			"position_error": 0.0,
			"replayed_count": 0,
			"state_mismatch": false,
		}
	_last_acked_seq = ack_seq

	var auth_pos: Vector3 = auth_player_state.get("position", Vector3.ZERO)
	var auth_vel: Vector3 = auth_player_state.get("velocity", Vector3.ZERO)
	var auth_flags: int = int(auth_player_state.get("state_flags", 0))

	var stored: Dictionary = get_prediction(ack_seq)
	var pos_error: float = 0.0
	var vel_error: float = 0.0
	var state_mismatch: bool = false

	if stored.is_empty():
		# No buffered prediction for this ack (e.g., first snapshot or reconnect) -> reconcile directly
		if current_pos_callable.is_valid():
			var cur_p: Vector3 = current_pos_callable.call()
			pos_error = cur_p.distance_to(auth_pos)
		state_mismatch = true
	else:
		var pred_state: Dictionary = stored.get("predicted_state", {})
		var pred_pos: Vector3 = pred_state.get("position", Vector3.ZERO)
		var pred_vel: Vector3 = pred_state.get("velocity", Vector3.ZERO)
		pos_error = pred_pos.distance_to(auth_pos)
		vel_error = pred_vel.distance_to(auth_vel)
		if pred_state.has("state_flags"):
			var pred_flags: int = int(pred_state["state_flags"])
			state_mismatch = ((pred_flags ^ auth_flags) & CRITICAL_STATE_MASK) != 0
		elif pred_state.has("ankle_break_frames_left"):
			var pred_ab: bool = int(pred_state["ankle_break_frames_left"]) > 0
			var auth_ab: bool = (auth_flags & ProtocolSerializer.STATE_ANKLE_BROKEN) != 0
			state_mismatch = pred_ab != auth_ab

	_last_position_error = pos_error
	var needs_correction: bool = (
		pos_error > POSITION_ERROR_THRESHOLD
		or vel_error > VELOCITY_ERROR_THRESHOLD
		or state_mismatch
	)

	var pending_entries: Array[Dictionary] = get_pending_inputs_after(ack_seq)
	discard_through(ack_seq)

	if not needs_correction:
		return {
			"corrected": false,
			"ack_seq": ack_seq,
			"position_error": pos_error,
			"replayed_count": 0,
			"state_mismatch": false,
		}

	var pre_pos: Vector3 = auth_pos
	if current_pos_callable.is_valid():
		pre_pos = current_pos_callable.call()

	_reconciliation_count += 1

	if apply_auth_callable.is_valid():
		apply_auth_callable.call(auth_player_state)

	var replayed_count: int = 0
	if replay_callable.is_valid():
		for entry in pending_entries:
			var f: Dictionary = entry["input_frame"]
			var new_state_variant: Variant = replay_callable.call(f)
			replayed_count += 1
			if new_state_variant is Dictionary and not (new_state_variant as Dictionary).is_empty():
				record_prediction(int(entry["seq"]), f, new_state_variant as Dictionary)

	var post_pos: Vector3 = auth_pos
	if current_pos_callable.is_valid():
		post_pos = current_pos_callable.call()

	var delta_vec: Vector3 = pre_pos - post_pos
	if delta_vec.length() > SNAP_TELEPORT_THRESHOLD:
		_visual_offset = Vector3.ZERO
		_visual_offset_initial = Vector3.ZERO
		_visual_decay_frames_left = 0
	else:
		_visual_offset = delta_vec
		_visual_offset_initial = delta_vec
		_visual_decay_frames_left = VISUAL_DECAY_FRAMES

	return {
		"corrected": true,
		"ack_seq": ack_seq,
		"position_error": pos_error,
		"replayed_count": replayed_count,
		"state_mismatch": state_mismatch,
		"visual_offset": _visual_offset,
	}


## Convenience integration directly with PlayerController (export_sim_state / import_sim_state / step_with_input).
func reconcile_player_controller(
	player_controller: Node,
	auth_player_state: Dictionary,
	dt: float = 1.0 / 60.0
) -> Dictionary:
	if player_controller == null:
		return {"corrected": false, "ack_seq": 0, "position_error": 0.0, "replayed_count": 0}

	var apply_fn := func(auth: Dictionary) -> void:
		if not player_controller.has_method("export_sim_state") or not player_controller.has_method("import_sim_state"):
			return
		var sim_state: Dictionary = player_controller.call("export_sim_state")
		sim_state["position"] = auth.get("position", sim_state.get("position", Vector3.ZERO))
		sim_state["velocity"] = auth.get("velocity", sim_state.get("velocity", Vector3.ZERO))
		sim_state["facing_yaw"] = float(auth.get("yaw", sim_state.get("facing_yaw", 0.0)))
		sim_state["balance"] = float(auth.get("balance", sim_state.get("balance", 100.0)))
		var flags: int = int(auth.get("state_flags", 0))
		sim_state["was_on_floor"] = (flags & ProtocolSerializer.STATE_GROUNDED) != 0
		sim_state["is_sprinting"] = (flags & ProtocolSerializer.STATE_SPRINTING) != 0
		sim_state["in_defensive_stance"] = (flags & ProtocolSerializer.STATE_DEFENSIVE_STANCE) != 0
		if sim_state.has("stamina") and sim_state["stamina"] is Dictionary:
			(sim_state["stamina"] as Dictionary)["current"] = float(auth.get("stamina", 100.0))
		if sim_state.has("zone") and sim_state["zone"] is Dictionary:
			var zdict: Dictionary = sim_state["zone"]
			zdict["current_energy"] = float(auth.get("zone", 0.0))
			zdict["is_active"] = (flags & ProtocolSerializer.STATE_ZONE_ACTIVE) != 0
		player_controller.call("import_sim_state", sim_state)

	var replay_fn := func(frame: Dictionary) -> Dictionary:
		if player_controller.has_method("step_with_input"):
			player_controller.call("step_with_input", frame, dt)
		if player_controller.has_method("export_sim_state"):
			return player_controller.call("export_sim_state")
		return {}

	var pos_fn := func() -> Vector3:
		if player_controller is Node3D:
			return (player_controller as Node3D).global_position
		return Vector3.ZERO

	return reconcile(auth_player_state, apply_fn, replay_fn, pos_fn)
