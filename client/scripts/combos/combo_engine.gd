class_name ComboEngine
extends Node
## 60 Hz fighting-game combo recognition, cancel-window, priority-preemption,
## cooldown, perfect-timing bonus, training telemetry, and rollback-snapshot engine
## for PHANTOM COURT ONLINE.

const PERFECT_STAMINA_REFUND_RATIO: float = 0.30
const PERFECT_POTENCY_MULT: float = 1.15
const PERFECT_BONUS_ZONE: float = 8.0
const ZONE_EXTRA_CANCEL_FRAMES: int = 4

# Phase 5 Zone EX skill modifiers
const ZONE_EX_STAMINA_MULT: float = 0.75 # +25% stamina efficiency in Zone
const ZONE_EX_POTENCY_MULT: float = 1.15 # Stacks cleanly with Perfect Timing (1.15 * 1.15 = 1.3225)
const ZONE_EX_MAX_RIM_OVERRIDES: Dictionary = {
	"meteor_dunk": 6.5,         # vs 5.5m base
	"starlight_high_arc": 10.8, # vs 9.8m base
	"tectonic_slam": 5.0,       # vs 4.2m base
}

@export var owner_player_id: int = 1
@export var default_archetype_id: String = ""
var base_extra_cancel_frames: int = 0

var input_buffer: InputBuffer
var move_db: MoveDatabase

var active_move_frame: int = 0
var combo_chain_count: int = 0
var last_triggered_move_id: String = ""
var last_triggered_perfect: bool = false

var _active_move_id: String = ""
var _cooldowns: Dictionary = {} # move_id: String -> remaining_frames: int
var _consumed_token_id: int = -1
var _last_was_cancel: bool = false
var _last_timing_analysis: Dictionary = {}
var _total_frames_stepped: int = 0

# Training telemetry (Phase 11 Combo Trainer)
var _training_target_id: String = ""
var _training_attempts: int = 0
var _training_successes: int = 0
var _training_perfects: int = 0
var _training_last_failure_reason: String = ""
var _training_matched_prefix_len: int = 0


func _init() -> void:
	input_buffer = InputBuffer.new()
	move_db = MoveDatabase.new(true)


func setup(player_id: int, database: MoveDatabase = null, arch_id: String = "") -> void:
	owner_player_id = player_id
	if database != null:
		move_db = database
	elif move_db == null:
		move_db = MoveDatabase.new(true)
	if not arch_id.is_empty():
		default_archetype_id = arch_id


func reset() -> void:
	input_buffer.clear()
	_active_move_id = ""
	active_move_frame = 0
	combo_chain_count = 0
	last_triggered_move_id = ""
	last_triggered_perfect = false
	_cooldowns.clear()
	_consumed_token_id = -1
	_last_was_cancel = false
	_last_timing_analysis.clear()
	_total_frames_stepped = 0
	_training_matched_prefix_len = 0
	_training_last_failure_reason = ""


func register_move(move: FrameData) -> void:
	move_db.register_move(move)


func register_move_from_dict(data: Dictionary) -> FrameData:
	return move_db.register_move_from_dict(data)


func set_extra_cancel_frames(bonus_frames: int) -> void:
	base_extra_cancel_frames = maxi(0, bonus_frames)


func get_extra_cancel_frames() -> int:
	return base_extra_cancel_frames


static func get_effective_max_rim_distance(move: FrameData, is_zone_active: bool) -> float:
	if move == null:
		return 0.0
	if is_zone_active and ZONE_EX_MAX_RIM_OVERRIDES.has(move.id):
		return maxf(move.max_rim_distance, float(ZONE_EX_MAX_RIM_OVERRIDES[move.id]))
	return move.max_rim_distance


# ==============================================================================
# Core 60 Hz Simulation Step
# ==============================================================================

## Advances the combo engine by exactly one 60 Hz physics tick.
## `input_frame`: Canonical PlayerInputFrame Dictionary.
## `context`: {has_ball, stamina, dist_to_rim, is_grounded, is_zone_active, archetype_id, extra_cancel_frames}
## Returns a result Dictionary describing any triggered move, bonuses, and active frame state.
func step_frame(input_frame: Dictionary, context: Dictionary = {}) -> Dictionary:
	_total_frames_stepped += 1

	# 1. Tick down active cooldowns by 1 frame (60 Hz)
	if not _cooldowns.is_empty():
		var expired_ids: Array[String] = []
		for key in _cooldowns.keys():
			var mid: String = str(key)
			var rem: int = int(_cooldowns[mid]) - 1
			if rem <= 0:
				expired_ids.append(mid)
			else:
				_cooldowns[mid] = rem
		for mid in expired_ids:
			_cooldowns.erase(mid)

	# 2. Advance currently active move frame and clear upon full recovery completion
	if not _active_move_id.is_empty():
		active_move_frame += 1
		var cur_active: FrameData = move_db.get_move(_active_move_id)
		if cur_active == null or active_move_frame >= cur_active.total_frames():
			_active_move_id = ""
			active_move_frame = 0
			combo_chain_count = 0

	# 3. Record canonical input frame into 90-frame circular InputBuffer & emit token telemetry
	var new_tokens: Array[Dictionary] = input_buffer.push_frame(input_frame)
	if not new_tokens.is_empty():
		_update_training_prefix()
	for tok in new_tokens:
		_emit_input_recorded(tok)

	# 4. Resolve gameplay context
	var has_ball: bool = bool(context.get("has_ball", true))
	var has_stamina_ctx: bool = context.has("stamina")
	var stamina: float = float(context.get("stamina", 100.0))
	var dist_to_rim: float = float(context.get("dist_to_rim", 3.0))
	var is_grounded: bool = bool(context.get("is_grounded", true))
	var is_zone_active: bool = bool(context.get("is_zone_active", false))
	var arch_id: String = str(context.get("archetype_id", default_archetype_id))
	var default_extra_cancel: int = base_extra_cancel_frames + (ZONE_EXTRA_CANCEL_FRAMES if is_zone_active else 0)
	var extra_cancel_frames: int = maxi(
		0,
		int(context.get("extra_cancel_frames", default_extra_cancel))
	)

	# 5. Match highest-priority / longest valid combo sequence when new input arrives
	var rejected_reason: String = ""
	if not new_tokens.is_empty():
		var candidates: Array[FrameData] = move_db.get_combo_moves(arch_id)
		var cur_move: FrameData = get_active_move()

		for move in candidates:
			var match_res: Dictionary = input_buffer.match_sequence(
				move.sequence,
				move.step_window_frames,
				_consumed_token_id,
				0
			)
			if not bool(match_res["matched"]):
				continue

			var timing_gaps: Array[int] = _to_int_array(match_res["timing_gaps"])
			var step_gaps: Array[int] = _to_int_array(match_res["step_gaps"])
			var eval_gaps: Array[int] = timing_gaps if not timing_gaps.is_empty() else step_gaps
			var avg_gap: float = float(match_res["avg_gap"])
			var final_gap: int = int(match_res["final_gap"])
			var is_perfect: bool = _evaluate_perfect_timing(move, eval_gaps, avg_gap, final_gap)

			var stamina_refund_ratio: float = PERFECT_STAMINA_REFUND_RATIO if is_perfect else 0.0
			var stamina_refund: float = move.stamina_cost * stamina_refund_ratio
			var zone_stamina_mult: float = ZONE_EX_STAMINA_MULT if is_zone_active else 1.0
			var effective_stamina_cost: float = (move.stamina_cost - stamina_refund) * zone_stamina_mult
			var effective_max_rim: float = get_effective_max_rim_distance(move, is_zone_active)

			# Validate gameplay prerequisites & state gates
			var gate_err: String = _validate_move_gates(
				move,
				has_ball,
				has_stamina_ctx,
				stamina,
				effective_stamina_cost,
				dist_to_rim,
				is_grounded,
				effective_max_rim
			)
			if not gate_err.is_empty():
				if rejected_reason.is_empty():
					rejected_reason = gate_err
				if move.id == _training_target_id:
					_training_attempts += 1
					_training_last_failure_reason = gate_err
				continue

			# Validate priority preemption / cancel window transition from active move
			var trans: Dictionary = _can_transition_from_active(
				cur_move,
				active_move_frame,
				move,
				extra_cancel_frames
			)
			if not bool(trans["allowed"]):
				var reason: String = str(trans["reason"])
				if rejected_reason.is_empty():
					rejected_reason = reason
				if move.id == _training_target_id:
					_training_attempts += 1
					_training_last_failure_reason = reason
				continue

			# Trigger winning candidate!
			var prev_move_id: String = _active_move_id
			var was_cancel: bool = bool(trans["is_cancel"])
			if was_cancel and combo_chain_count > 0:
				combo_chain_count += 1
			else:
				combo_chain_count = 1

			_active_move_id = move.id
			active_move_frame = 0
			_last_was_cancel = was_cancel
			last_triggered_move_id = move.id
			last_triggered_perfect = is_perfect

			if move.cooldown_frames > 0:
				_cooldowns[move.id] = move.cooldown_frames

			_consumed_token_id = maxi(_consumed_token_id, int(match_res["last_token_id"]))

			var potency_mult: float = (PERFECT_POTENCY_MULT if is_perfect else 1.0) * (ZONE_EX_POTENCY_MULT if is_zone_active else 1.0)
			# Zero Zone refill while already in Zone (competitive balance)
			var bonus_zone: float = 0.0 if is_zone_active else (PERFECT_BONUS_ZONE if is_perfect else 0.0)
			var effective_zone_gain: float = 0.0 if is_zone_active else (move.zone_gain + bonus_zone)

			_last_timing_analysis = _build_timing_analysis(
				move,
				match_res,
				is_perfect,
				was_cancel,
				prev_move_id,
				combo_chain_count
			)

			if move.id == _training_target_id:
				_training_attempts += 1
				_training_successes += 1
				if is_perfect:
					_training_perfects += 1
				_training_last_failure_reason = ""
				_training_matched_prefix_len = move.sequence.size()

			_emit_combo_triggered(move.id, combo_chain_count, is_perfect)

			var move_def: Dictionary = move.to_dict()
			move_def["base_stamina_cost"] = move.stamina_cost
			move_def["stamina_cost"] = effective_stamina_cost
			move_def["stamina_refund_ratio"] = stamina_refund_ratio
			move_def["stamina_refund"] = stamina_refund
			move_def["zone_stamina_mult"] = zone_stamina_mult
			move_def["is_zone_ex"] = is_zone_active
			move_def["potency_mult"] = potency_mult
			move_def["base_zone_gain"] = move.zone_gain
			move_def["bonus_zone"] = bonus_zone
			move_def["zone_gain"] = effective_zone_gain
			move_def["max_rim_distance"] = effective_max_rim
			if is_zone_active and move_def.has("gameplay_params") and move_def["gameplay_params"] is Dictionary:
				var gp: Dictionary = move_def["gameplay_params"]
				gp["is_zone_ex"] = true
				if effective_max_rim > 0.0:
					gp["max_rim_dist"] = effective_max_rim
			move_def["is_perfect"] = is_perfect
			move_def["combo_chain_count"] = combo_chain_count
			move_def["tier"] = combo_chain_count
			move_def["was_cancel"] = was_cancel
			move_def["canceled_from"] = prev_move_id
			move_def["emitted_by_combo_engine"] = true

			return {
				"triggered": true,
				"move_id": move.id,
				"display_name": move.display_name,
				"move": move,
				"move_def": move_def,
				"priority": move.priority,
				"is_perfect": is_perfect,
				"is_zone_ex": is_zone_active,
				"was_cancel": was_cancel,
				"canceled_from": prev_move_id,
				"combo_chain_count": combo_chain_count,
				"base_stamina_cost": move.stamina_cost,
				"stamina_cost": effective_stamina_cost,
				"stamina_refund_ratio": stamina_refund_ratio,
				"stamina_refund": stamina_refund,
				"zone_stamina_mult": zone_stamina_mult,
				"potency_mult": potency_mult,
				"base_zone_gain": move.zone_gain,
				"bonus_zone": bonus_zone,
				"zone_gain": effective_zone_gain,
				"max_rim_distance": effective_max_rim,
				"gameplay_params": (move_def["gameplay_params"] as Dictionary).duplicate(true),
				"timing": _last_timing_analysis.duplicate(true),
				"active_move_id": _active_move_id,
				"active_move_frame": active_move_frame,
				"active_move_phase": move.get_phase(active_move_frame),
				"in_cancel_window": move.is_in_cancel_window(active_move_frame, extra_cancel_frames),
				"new_tokens": new_tokens,
				"suppress_default_action": true,
				"rejected_reason": "",
			}

	_update_training_prefix()

	var active_now: FrameData = get_active_move()
	return {
		"triggered": false,
		"move_id": "",
		"display_name": "",
		"move": null,
		"move_def": {},
		"priority": 0,
		"is_perfect": false,
		"is_zone_ex": is_zone_active,
		"was_cancel": false,
		"canceled_from": "",
		"combo_chain_count": combo_chain_count,
		"base_stamina_cost": 0.0,
		"stamina_cost": 0.0,
		"stamina_refund_ratio": 0.0,
		"stamina_refund": 0.0,
		"zone_stamina_mult": ZONE_EX_STAMINA_MULT if is_zone_active else 1.0,
		"potency_mult": 1.0,
		"base_zone_gain": 0.0,
		"bonus_zone": 0.0,
		"zone_gain": 0.0,
		"max_rim_distance": 0.0,
		"gameplay_params": {},
		"timing": {},
		"active_move_id": _active_move_id,
		"active_move_frame": active_move_frame,
		"active_move_phase": active_now.get_phase(active_move_frame) if active_now != null else "idle",
		"in_cancel_window": active_now.is_in_cancel_window(active_move_frame, extra_cancel_frames) if active_now != null else false,
		"new_tokens": new_tokens,
		"suppress_default_action": false,
		"rejected_reason": rejected_reason,
	}


# ==============================================================================
# Normal Dribble Integration Hooks (for PlayerController)
# ==============================================================================

## Checks whether a context-triggered normal dribble (e.g., crossover, spin, stepback)
## is currently allowed given the active move & cancel window.
func can_start_normal_move(move_id: String, extra_cancel_frames: int = 0) -> bool:
	var move: FrameData = move_db.get_move(move_id)
	if move == null:
		return false
	var cur: FrameData = get_active_move()
	if cur == null:
		return true
	var trans: Dictionary = _can_transition_from_active(cur, active_move_frame, move, extra_cancel_frames)
	return bool(trans["allowed"])


## Registers a normal dribble move as the active frame-tracked move in ComboEngine
## WITHOUT consuming InputBuffer tokens (so Q/E/Q can still complete signature combos!).
func notify_normal_move(move_id: String, extra_cancel_frames: int = 0, force: bool = false) -> bool:
	var move: FrameData = move_db.get_move(move_id)
	if move == null:
		return false

	var cur: FrameData = get_active_move()
	var was_cancel: bool = false
	if cur != null and not force:
		var trans: Dictionary = _can_transition_from_active(cur, active_move_frame, move, extra_cancel_frames)
		if not bool(trans["allowed"]):
			return false
		was_cancel = bool(trans["is_cancel"])
	elif cur != null and force:
		was_cancel = cur.is_in_cancel_window(active_move_frame, extra_cancel_frames)

	if was_cancel and combo_chain_count > 0:
		combo_chain_count += 1
	else:
		combo_chain_count = 1

	_active_move_id = move.id
	active_move_frame = 0
	_last_was_cancel = was_cancel
	return true


## Returns true if the player can currently cancel into a pull-up jump shot
## (e.g. from neutral or during ankle_breaker / mirror_step / stepback cancel windows).
func can_cancel_into_shot(extra_cancel_frames: int = 0) -> bool:
	var cur: FrameData = get_active_move()
	if cur == null:
		return true
	return cur.is_in_cancel_window(active_move_frame, extra_cancel_frames)


## Returns any active shot-window bonus from a recently triggered combo (Ankle Breaker / Mirror Step).
func get_active_shot_bonus() -> float:
	var cur: FrameData = get_active_move()
	if cur == null:
		return 0.0
	var bonus: float = 0.0
	if cur.gameplay_params.has("gather_shot_bonus"):
		bonus = float(cur.gameplay_params["gather_shot_bonus"])
	elif cur.gameplay_params.has("shot_window_bonus"):
		bonus = float(cur.gameplay_params["shot_window_bonus"])
	if bonus > 0.0 and last_triggered_perfect and last_triggered_move_id == cur.id:
		bonus *= PERFECT_POTENCY_MULT
	return bonus


# ==============================================================================
# Queries, Cooldowns & Training Telemetry
# ==============================================================================

func get_cooldown_remaining(move_id: String) -> int:
	return maxi(0, int(_cooldowns.get(move_id, 0)))


func get_cooldown_seconds(move_id: String) -> float:
	return float(get_cooldown_remaining(move_id)) / 60.0


func get_all_cooldowns() -> Dictionary:
	return _cooldowns.duplicate(true)


func clear_cooldowns() -> void:
	_cooldowns.clear()


func get_active_move() -> FrameData:
	if _active_move_id.is_empty():
		return null
	return move_db.get_move(_active_move_id)


func get_active_move_id() -> String:
	return _active_move_id


func get_active_move_frame() -> int:
	return active_move_frame


func get_active_move_phase() -> String:
	var cur: FrameData = get_active_move()
	if cur == null:
		return "idle"
	return cur.get_phase(active_move_frame)


func is_in_cancel_window(extra_cancel_frames: int = 0) -> bool:
	var cur: FrameData = get_active_move()
	if cur == null:
		return false
	return cur.is_in_cancel_window(active_move_frame, extra_cancel_frames)


func get_combo_chain_count() -> int:
	return combo_chain_count


func get_input_history(max_count: int = 16) -> Array[Dictionary]:
	return input_buffer.get_history(max_count)


func set_training_target(move_id: String) -> void:
	_training_target_id = move_id
	_training_attempts = 0
	_training_successes = 0
	_training_perfects = 0
	_training_last_failure_reason = ""
	_training_matched_prefix_len = 0


func get_last_timing_analysis() -> Dictionary:
	return _last_timing_analysis.duplicate(true)


func get_training_state() -> Dictionary:
	var target_move: FrameData = move_db.get_move(_training_target_id) if not _training_target_id.is_empty() else null
	var seq: Array[String] = []
	var expected_next: String = ""
	if target_move != null:
		for s in target_move.sequence:
			seq.append(s)
		if _training_matched_prefix_len < seq.size():
			expected_next = seq[_training_matched_prefix_len]

	return {
		"target_move_id": _training_target_id,
		"target_display_name": target_move.display_name if target_move != null else "",
		"target_sequence": seq,
		"matched_prefix_len": _training_matched_prefix_len,
		"expected_next_symbol": expected_next,
		"attempts": _training_attempts,
		"successes": _training_successes,
		"perfects": _training_perfects,
		"last_failure_reason": _training_last_failure_reason,
		"active_move_id": _active_move_id,
		"active_move_frame": active_move_frame,
		"active_move_phase": get_active_move_phase(),
		"in_cancel_window": is_in_cancel_window(0),
		"combo_chain_count": combo_chain_count,
		"cooldown_remaining": get_cooldown_remaining(_training_target_id) if not _training_target_id.is_empty() else 0,
		"recent_inputs": input_buffer.get_history(12),
		"last_timing_analysis": _last_timing_analysis.duplicate(true),
	}


# ==============================================================================
# Deterministic Rollback Snapshots (Phase 8)
# ==============================================================================

func export_state() -> Dictionary:
	return {
		"owner_player_id": owner_player_id,
		"default_archetype_id": default_archetype_id,
		"base_extra_cancel_frames": base_extra_cancel_frames,
		"active_move_id": _active_move_id,
		"active_move_frame": active_move_frame,
		"combo_chain_count": combo_chain_count,
		"last_triggered_move_id": last_triggered_move_id,
		"last_triggered_perfect": last_triggered_perfect,
		"last_was_cancel": _last_was_cancel,
		"consumed_token_id": _consumed_token_id,
		"total_frames_stepped": _total_frames_stepped,
		"cooldowns": _cooldowns.duplicate(true),
		"last_timing_analysis": _last_timing_analysis.duplicate(true),
		"training": {
			"target_id": _training_target_id,
			"attempts": _training_attempts,
			"successes": _training_successes,
			"perfects": _training_perfects,
			"last_failure_reason": _training_last_failure_reason,
			"matched_prefix_len": _training_matched_prefix_len,
		},
		"input_buffer": input_buffer.export_state(),
	}


func import_state(state: Dictionary) -> void:
	owner_player_id = int(state.get("owner_player_id", owner_player_id))
	default_archetype_id = str(state.get("default_archetype_id", default_archetype_id))
	base_extra_cancel_frames = maxi(0, int(state.get("base_extra_cancel_frames", base_extra_cancel_frames)))
	_active_move_id = str(state.get("active_move_id", ""))
	active_move_frame = int(state.get("active_move_frame", 0))
	combo_chain_count = int(state.get("combo_chain_count", 0))
	last_triggered_move_id = str(state.get("last_triggered_move_id", ""))
	last_triggered_perfect = bool(state.get("last_triggered_perfect", false))
	_last_was_cancel = bool(state.get("last_was_cancel", false))
	_consumed_token_id = int(state.get("consumed_token_id", -1))
	_total_frames_stepped = int(state.get("total_frames_stepped", 0))

	_cooldowns.clear()
	if state.has("cooldowns") and state["cooldowns"] is Dictionary:
		var cd_src: Dictionary = state["cooldowns"]
		for k in cd_src.keys():
			_cooldowns[str(k)] = int(cd_src[k])

	if state.has("last_timing_analysis") and state["last_timing_analysis"] is Dictionary:
		_last_timing_analysis = (state["last_timing_analysis"] as Dictionary).duplicate(true)
	else:
		_last_timing_analysis.clear()

	if state.has("training") and state["training"] is Dictionary:
		var tr: Dictionary = state["training"]
		_training_target_id = str(tr.get("target_id", ""))
		_training_attempts = int(tr.get("attempts", 0))
		_training_successes = int(tr.get("successes", 0))
		_training_perfects = int(tr.get("perfects", 0))
		_training_last_failure_reason = str(tr.get("last_failure_reason", ""))
		_training_matched_prefix_len = int(tr.get("matched_prefix_len", 0))

	if state.has("input_buffer") and state["input_buffer"] is Dictionary:
		input_buffer.import_state(state["input_buffer"])


# ==============================================================================
# Internal Helpers
# ==============================================================================

func _evaluate_perfect_timing(
	move: FrameData,
	gaps: Array[int],
	avg_gap: float,
	final_gap: int
) -> bool:
	if gaps.is_empty():
		return false
	var avg_ok: bool = avg_gap >= float(move.perfect_gap_min) and avg_gap <= float(move.perfect_gap_max)
	var final_ok: bool = final_gap >= move.perfect_gap_min and final_gap <= move.perfect_gap_max
	return avg_ok and final_ok


func _validate_move_gates(
	move: FrameData,
	has_ball: bool,
	has_stamina_ctx: bool,
	stamina: float,
	effective_stamina_cost: float,
	dist_to_rim: float,
	is_grounded: bool,
	effective_max_rim: float = -1.0
) -> String:
	if move.requires_ball and not has_ball:
		return "requires_ball"
	if move.requires_grounded and not is_grounded:
		return "requires_grounded"
	var max_rim: float = effective_max_rim if effective_max_rim >= 0.0 else move.max_rim_distance
	if max_rim > 0.0 and dist_to_rim > max_rim:
		return "out_of_rim_range"
	if get_cooldown_remaining(move.id) > 0:
		return "on_cooldown"
	if has_stamina_ctx and move.stamina_cost > 0.0 and stamina < effective_stamina_cost:
		return "insufficient_stamina"
	return ""


func _can_transition_from_active(
	cur_move: FrameData,
	cur_frame: int,
	next_move: FrameData,
	extra_cancel_frames: int
) -> Dictionary:
	if cur_move == null:
		return {"allowed": true, "is_cancel": false, "reason": ""}

	if cur_move.id == next_move.id and next_move.priority >= FrameData.PRIORITY_SPECIAL:
		return {"allowed": false, "is_cancel": false, "reason": "already_active"}

	var in_cancel: bool = cur_move.is_in_cancel_window(cur_frame, extra_cancel_frames)
	var higher_prio: bool = next_move.priority > cur_move.priority
	var allowed_chain: bool = next_move.can_chain_after(cur_move.id)

	# 1. Cancel window transition: higher-priority move OR explicitly allowed chain move cancels cleanly
	if in_cancel:
		if higher_prio or allowed_chain:
			return {"allowed": true, "is_cancel": true, "reason": ""}
		return {"allowed": false, "is_cancel": false, "reason": "priority_too_low"}

	# 2. Normal/Dribble -> Special/Ultimate priority preemption (kara-cancel / special override)
	# Ensures single-button normal dribbles fired on earlier inputs never jam multi-button combos.
	if cur_move.priority <= FrameData.PRIORITY_DRIBBLE and next_move.priority >= FrameData.PRIORITY_SPECIAL:
		var counts_as_chain: bool = not cur_move.is_in_startup(cur_frame)
		return {"allowed": true, "is_cancel": counts_as_chain, "reason": ""}

	return {"allowed": false, "is_cancel": false, "reason": "not_in_cancel_window"}


func _build_timing_analysis(
	move: FrameData,
	match_res: Dictionary,
	is_perfect: bool,
	was_cancel: bool,
	prev_move_id: String,
	chain_count: int
) -> Dictionary:
	var matched_tokens: Array = match_res.get("matched_tokens", [])
	var step_gaps: Array[int] = _to_int_array(match_res.get("step_gaps", []))
	var timing_gaps: Array[int] = _to_int_array(match_res.get("timing_gaps", []))
	var avg_gap: float = float(match_res.get("avg_gap", 0.0))
	var final_gap: int = int(match_res.get("final_gap", 0))

	var rating: String = "perfect"
	if not is_perfect:
		if avg_gap < float(move.perfect_gap_min) or final_gap < move.perfect_gap_min:
			rating = "fast"
		else:
			rating = "slow"

	var steps: Array[Dictionary] = []
	for i in range(1, matched_tokens.size()):
		var prev_tok: Dictionary = matched_tokens[i - 1]
		var curr_tok: Dictionary = matched_tokens[i]
		var gap: int = maxi(0, int(curr_tok["frame"]) - int(prev_tok["frame"]))
		var status: String = "perfect"
		if bool(curr_tok.get("synthetic_held", false)) or bool(prev_tok.get("synthetic_held", false)):
			status = "held"
		elif gap < move.perfect_gap_min:
			status = "fast"
		elif gap > move.perfect_gap_max:
			status = "slow"
		steps.append({
			"from_symbol": str(prev_tok["symbol"]),
			"to_symbol": str(curr_tok["symbol"]),
			"gap_frames": gap,
			"target_min": move.perfect_gap_min,
			"target_max": move.perfect_gap_max,
			"status": status,
		})

	var seq_copy: Array[String] = []
	for s in move.sequence:
		seq_copy.append(s)

	return {
		"move_id": move.id,
		"display_name": move.display_name,
		"sequence": seq_copy,
		"is_perfect": is_perfect,
		"rating": rating,
		"step_gaps": step_gaps,
		"timing_gaps": timing_gaps,
		"avg_gap": avg_gap,
		"final_gap": final_gap,
		"perfect_gap_min": move.perfect_gap_min,
		"perfect_gap_max": move.perfect_gap_max,
		"step_window_frames": move.step_window_frames,
		"used_held_direction": bool(match_res.get("used_held_direction", false)),
		"was_cancel": was_cancel,
		"canceled_from": prev_move_id,
		"combo_chain_count": chain_count,
		"steps": steps,
	}


func _update_training_prefix() -> void:
	if _training_target_id.is_empty():
		_training_matched_prefix_len = 0
		return
	var target: FrameData = move_db.get_move(_training_target_id)
	if target == null or target.sequence.is_empty():
		_training_matched_prefix_len = 0
		return
	_training_matched_prefix_len = input_buffer.measure_prefix_progress(
		target.sequence,
		target.step_window_frames,
		_consumed_token_id
	)


func _emit_combo_triggered(combo_id: String, chain_count: int, is_perfect: bool) -> void:
	var eb: Node = _get_event_bus()
	if eb != null:
		eb.emit_signal("combo_triggered", owner_player_id, combo_id, chain_count, is_perfect)


func _emit_input_recorded(token_record: Dictionary) -> void:
	var eb: Node = _get_event_bus()
	if eb != null:
		eb.emit_signal("input_recorded", owner_player_id, token_record.duplicate(true))


func _get_event_bus() -> Node:
	var main_loop: MainLoop = Engine.get_main_loop()
	if main_loop is SceneTree:
		var root: Window = (main_loop as SceneTree).root
		if root != null:
			return root.get_node_or_null("EventBus")
	return null


static func _to_int_array(raw: Variant) -> Array[int]:
	var out: Array[int] = []
	if raw is Array:
		for item in (raw as Array):
			out.append(int(item))
	return out
