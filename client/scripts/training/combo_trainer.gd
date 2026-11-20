class_name ComboTrainer
extends Node
## Fighting-Game Combo Tutorial, Live Input History Tape, Rhythm/Shot Timing Analyzer,
## and Timed 30s Combo Execution Challenge Engine for PHANTOM COURT ONLINE (Phase 11).

signal tutorial_updated(state: Dictionary)
signal input_history_updated(history: Array)
signal timing_analyzed(analysis: Dictionary)
signal challenge_updated(challenge_state: Dictionary)

const MAX_HISTORY_ENTRIES: int = 24
const PERFECT_GAP_MIN: int = 4
const PERFECT_GAP_MAX: int = 9
const PERFECT_GAP_CENTER: float = 6.5
const FRAME_MS: float = 1000.0 / 60.0

const TUTORIAL_ORDER: Array[String] = [
	MoveDatabase.MOVE_PHANTOM_DRIVE,
	MoveDatabase.MOVE_METEOR_DUNK,
	MoveDatabase.MOVE_ANKLE_BREAKER,
	MoveDatabase.MOVE_MIRROR_STEP,
	MoveDatabase.MOVE_VOLT_DASH,
	MoveDatabase.MOVE_STARLIGHT_HIGH_ARC,
	MoveDatabase.MOVE_MIRAGE_THREAD,
	MoveDatabase.MOVE_TECTONIC_SLAM,
	MoveDatabase.MOVE_ECLIPSE_COUNTER,
]

var owner_player: Node = null
var owner_player_id: int = 1
var mastery_tracker: MasteryTracker = null
var move_db: MoveDatabase

var _event_bus_connected: bool = false
var _input_history: Array[Dictionary] = []
var _last_timing_analysis: Dictionary = {}

# Active Tutorial State
var _tutorial_move_id: String = MoveDatabase.MOVE_PHANTOM_DRIVE
var _tutorial_sequence: Array[String] = []
var _tutorial_display_name: String = "Phantom Drive"
var _tutorial_archetype_id: String = ""
var _tutorial_step_index: int = 0
var _tutorial_completions: int = 0
var _tutorial_perfects: int = 0
var _tutorial_feedback: String = ""
var _tutorial_just_completed: bool = false

# Active Timed Challenge State
var _challenge_active: bool = false
var _challenge_finished: bool = false
var _challenge_move_id: String = ""
var _challenge_display_name: String = ""
var _challenge_target_count: int = 3
var _challenge_duration_sec: float = 30.0
var _challenge_time_left: float = 0.0
var _challenge_completions: int = 0
var _challenge_perfects: int = 0
var _challenge_score: int = 0
var _challenge_grade: String = ""


func _init() -> void:
	move_db = MoveDatabase.new(true)
	_load_tutorial_metadata(_tutorial_move_id)


func _ready() -> void:
	_connect_event_bus()


func _exit_tree() -> void:
	_disconnect_event_bus()


func setup(target_player: Node, tracker: MasteryTracker = null) -> void:
	owner_player = target_player
	if target_player != null and target_player.get("player_id") != null:
		owner_player_id = int(target_player.get("player_id"))
	mastery_tracker = tracker if tracker != null else MasteryTracker.new()
	_connect_event_bus()
	select_tutorial(_tutorial_move_id)


func _physics_process(delta: float) -> void:
	if _challenge_active:
		var dt: float = delta if (delta > 0.0 and delta <= 0.05) else (1.0 / 60.0)
		step_challenge(dt)


# ==============================================================================
# 1. Combo Tutorials (All 4 Universal + All 5 Archetype Unique Skills)
# ==============================================================================

func get_available_tutorials() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for mid in TUTORIAL_ORDER:
		var m: FrameData = move_db.get_move(mid)
		if m != null:
			var seq_copy: Array[String] = []
			for s in m.sequence:
				seq_copy.append(s)
			list.append({
				"move_id": m.id,
				"display_name": m.display_name,
				"sequence": seq_copy,
				"archetype_id": m.archetype_id,
				"priority": m.priority,
				"stamina_cost": m.stamina_cost,
			})
	return list


func select_tutorial(move_id: String) -> Dictionary:
	var canonical: String = move_id.strip_edges().to_lower()
	if not move_db.has_move(canonical) or move_db.get_move(canonical).sequence.is_empty():
		canonical = MoveDatabase.MOVE_PHANTOM_DRIVE

	_tutorial_move_id = canonical
	_load_tutorial_metadata(canonical)
	_tutorial_step_index = 0
	_tutorial_just_completed = false
	_tutorial_feedback = "Enter: " + " -> ".join(_tutorial_sequence)

	var ce: Node = _get_combo_engine()
	if ce != null and ce.has_method("set_training_target"):
		ce.call("set_training_target", canonical)

	var state: Dictionary = get_tutorial_state()
	tutorial_updated.emit(state)
	return state


func get_tutorial_state() -> Dictionary:
	var statuses: Array[String] = []
	var seq_len: int = _tutorial_sequence.size()
	for i in range(seq_len):
		if _tutorial_just_completed or i < _tutorial_step_index:
			statuses.append("done")
		elif i == _tutorial_step_index:
			statuses.append("active")
		else:
			statuses.append("pending")

	var seq_copy: Array[String] = []
	for s in _tutorial_sequence:
		seq_copy.append(s)

	var expected_next: String = ""
	if not _tutorial_just_completed and _tutorial_step_index >= 0 and _tutorial_step_index < seq_len:
		expected_next = _tutorial_sequence[_tutorial_step_index]

	return {
		"move_id": _tutorial_move_id,
		"display_name": _tutorial_display_name,
		"archetype_id": _tutorial_archetype_id,
		"sequence": seq_copy,
		"current_step_index": _tutorial_step_index,
		"step_statuses": statuses,
		"expected_next_symbol": expected_next,
		"completions": _tutorial_completions,
		"perfects": _tutorial_perfects,
		"just_completed": _tutorial_just_completed,
		"feedback": _tutorial_feedback,
	}


# ==============================================================================
# 2. Live Input History Tape (Last 24 Entries)
# ==============================================================================

func get_input_history(limit: int = 16) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _input_history.is_empty() or limit <= 0:
		return out
	var count: int = mini(limit, _input_history.size())
	var start_idx: int = _input_history.size() - count
	for i in range(start_idx, _input_history.size()):
		out.append((_input_history[i] as Dictionary).duplicate(true))
	return out


func clear_input_history() -> void:
	_input_history.clear()
	input_history_updated.emit([])


func on_input_recorded(token_record: Dictionary) -> Dictionary:
	# Ignore raw PlayerInputFrame dicts that lack a discrete fighting-game token symbol
	if not token_record.has("symbol"):
		return {}

	var sym: String = str(token_record.get("symbol", ""))
	if sym.is_empty():
		return {}

	var frame_num: int = int(token_record.get("frame", 0))
	var gap: int = int(token_record.get("gap_frames", 0))
	var timing_tag: String = "START"
	var is_perfect_gap: bool = false

	if _input_history.is_empty() or gap <= 0 or gap > 18:
		timing_tag = "START"
		is_perfect_gap = false
	elif gap < PERFECT_GAP_MIN:
		timing_tag = "EARLY"
		is_perfect_gap = false
	elif gap <= PERFECT_GAP_MAX:
		timing_tag = "PERFECT"
		is_perfect_gap = true
	else:
		timing_tag = "LATE"
		is_perfect_gap = false

	var entry := {
		"symbol": sym,
		"frame": frame_num,
		"gap_frames": gap,
		"timing_tag": timing_tag,
		"is_perfect_gap": is_perfect_gap,
		"is_direction": bool(token_record.get("is_direction", false)),
		"local_dir": token_record.get("local_dir", Vector2.ZERO),
	}

	_input_history.append(entry)
	while _input_history.size() > MAX_HISTORY_ENTRIES:
		_input_history.pop_front()

	# Refresh tutorial step progression from ComboEngine (or direct prefix fallback)
	_tutorial_just_completed = false
	var ce: Node = _get_combo_engine()
	if ce != null and ce.has_method("get_training_state"):
		var ts: Dictionary = ce.call("get_training_state")
		_tutorial_step_index = clampi(int(ts.get("matched_prefix_len", 0)), 0, _tutorial_sequence.size())
	else:
		_advance_standalone_tutorial_step(sym)

	input_history_updated.emit(get_input_history(16))
	tutorial_updated.emit(get_tutorial_state())
	return entry


# ==============================================================================
# 3. Timing Analysis (Combo Inter-Step Rhythm + Jump-Shot Release Timing)
# ==============================================================================

func get_last_timing_analysis() -> Dictionary:
	return _last_timing_analysis.duplicate(true)


func on_combo_triggered(combo_id: String, chain_count: int, is_perfect: bool) -> Dictionary:
	var cid: String = combo_id.strip_edges().to_lower()
	var move: FrameData = move_db.get_move(cid)
	if move == null or move.sequence.is_empty():
		return {}

	var arch_id: String = _get_player_archetype_id()

	# Build detailed combo timing analysis from ComboEngine (or recent history fallback)
	var avg_gap: float = PERFECT_GAP_CENTER if is_perfect else 11.0
	var final_gap: int = 6 if is_perfect else 11
	var step_gaps: Array = []
	var steps_detail: Array = []

	var ce: Node = _get_combo_engine()
	if ce != null and ce.has_method("get_last_timing_analysis"):
		var ce_analysis: Dictionary = ce.call("get_last_timing_analysis")
		if str(ce_analysis.get("move_id", "")) == cid:
			avg_gap = float(ce_analysis.get("avg_gap", avg_gap))
			final_gap = int(ce_analysis.get("final_gap", final_gap))
			step_gaps = (ce_analysis.get("step_gaps", []) as Array).duplicate()
			steps_detail = (ce_analysis.get("steps", []) as Array).duplicate(true)

	var offset_frames: float = avg_gap - PERFECT_GAP_CENTER
	var offset_ms: float = offset_frames * FRAME_MS
	var grade: String = "Perfect"
	if not is_perfect:
		grade = "Early" if (avg_gap < float(PERFECT_GAP_MIN) or final_gap < PERFECT_GAP_MIN) else "Late"

	_last_timing_analysis = {
		"kind": "combo",
		"move_id": cid,
		"display_name": move.display_name,
		"chain_count": chain_count,
		"is_perfect": is_perfect,
		"grade": grade,
		"avg_gap_frames": avg_gap,
		"final_gap_frames": final_gap,
		"optimal_min_frames": move.perfect_gap_min,
		"optimal_max_frames": move.perfect_gap_max,
		"offset_frames": offset_frames,
		"offset_ms": offset_ms,
		"step_gaps": step_gaps,
		"steps": steps_detail,
	}

	# Record mastery progress
	if mastery_tracker != null:
		mastery_tracker.record_combo_completion(cid, is_perfect, arch_id)

	# Update tutorial completion feedback if this matches the active tutorial
	if cid == _tutorial_move_id:
		_tutorial_completions += 1
		if is_perfect:
			_tutorial_perfects += 1
		_tutorial_step_index = _tutorial_sequence.size()
		_tutorial_just_completed = true
		_tutorial_feedback = (
			"PERFECT %s! (+%.1fms)" % [move.display_name, offset_ms]
			if is_perfect
			else "%s Complete (%s)" % [move.display_name, grade]
		)
		tutorial_updated.emit(get_tutorial_state())

	# Update live timed challenge progress if active and matching target move
	if _challenge_active and cid == _challenge_move_id:
		_challenge_completions += 1
		if is_perfect:
			_challenge_perfects += 1
		_challenge_score = _compute_live_challenge_score()
		challenge_updated.emit(get_challenge_state())

	timing_analyzed.emit(_last_timing_analysis.duplicate(true))
	return _last_timing_analysis.duplicate(true)


func on_shot_timing_feedback(label: String, timing_error_sec: float) -> Dictionary:
	var offset_ms: float = timing_error_sec * 1000.0
	var offset_frames: float = timing_error_sec * 60.0
	var grade: String = label if not label.is_empty() else "Good"
	var is_perfect: bool = (grade == "Perfect")

	_last_timing_analysis = {
		"kind": "shot",
		"move_id": "jump_shot",
		"display_name": "Jump Shot",
		"is_perfect": is_perfect,
		"grade": grade,
		"timing_error_sec": timing_error_sec,
		"offset_ms": offset_ms,
		"offset_frames": offset_frames,
	}

	timing_analyzed.emit(_last_timing_analysis.duplicate(true))
	return _last_timing_analysis.duplicate(true)


# ==============================================================================
# 4. Timed 30-Second Combo Challenges
# ==============================================================================

func start_challenge(
	move_id: String = "",
	target_count: int = 3,
	duration_sec: float = 30.0
) -> Dictionary:
	var chosen_id: String = move_id.strip_edges().to_lower()
	if chosen_id.is_empty():
		chosen_id = _tutorial_move_id
	if not move_db.has_move(chosen_id) or move_db.get_move(chosen_id).sequence.is_empty():
		chosen_id = MoveDatabase.MOVE_PHANTOM_DRIVE

	select_tutorial(chosen_id)
	var m: FrameData = move_db.get_move(chosen_id)

	_challenge_active = true
	_challenge_finished = false
	_challenge_move_id = chosen_id
	_challenge_display_name = m.display_name if m != null else chosen_id
	_challenge_target_count = maxi(1, target_count)
	_challenge_duration_sec = maxf(1.0, duration_sec)
	_challenge_time_left = _challenge_duration_sec
	_challenge_completions = 0
	_challenge_perfects = 0
	_challenge_score = 0
	_challenge_grade = ""

	var st: Dictionary = get_challenge_state()
	challenge_updated.emit(st)
	return st


func step_challenge(dt: float) -> Dictionary:
	if not _challenge_active:
		return get_challenge_state()

	_challenge_time_left = maxf(0.0, _challenge_time_left - maxf(0.0, dt))
	_challenge_score = _compute_live_challenge_score()

	if _challenge_time_left <= 0.0:
		return _finalize_challenge()

	var st: Dictionary = get_challenge_state()
	challenge_updated.emit(st)
	return st


func stop_challenge(finalize: bool = false) -> Dictionary:
	if not _challenge_active:
		return get_challenge_state()
	if finalize:
		return _finalize_challenge()
	_challenge_active = false
	_challenge_finished = false
	_challenge_time_left = 0.0
	_challenge_grade = ""
	var st: Dictionary = get_challenge_state()
	challenge_updated.emit(st)
	return st


func is_challenge_active() -> bool:
	return _challenge_active


func get_challenge_state() -> Dictionary:
	return {
		"active": _challenge_active,
		"finished": _challenge_finished,
		"move_id": _challenge_move_id,
		"display_name": _challenge_display_name,
		"target_count": _challenge_target_count,
		"duration_sec": _challenge_duration_sec,
		"time_left": _challenge_time_left,
		"completions": _challenge_completions,
		"perfects": _challenge_perfects,
		"score": _challenge_score,
		"grade": _challenge_grade,
	}


static func compute_challenge_grade(completions: int, perfects: int, target_count: int) -> String:
	var tgt: int = maxi(1, target_count)
	if (completions >= tgt and perfects >= tgt) or (completions >= tgt + 2 and perfects >= ceili(float(tgt) * 0.5)):
		return "S"
	if completions >= tgt and perfects >= maxi(1, int(floor(float(tgt) * 0.5))):
		return "A"
	if completions >= tgt:
		return "B"
	if completions >= 1:
		return "C"
	return "FAIL"


func _finalize_challenge() -> Dictionary:
	_challenge_active = false
	_challenge_finished = true
	_challenge_time_left = 0.0
	_challenge_grade = compute_challenge_grade(_challenge_completions, _challenge_perfects, _challenge_target_count)
	_challenge_score = _compute_live_challenge_score()

	if mastery_tracker != null:
		mastery_tracker.record_challenge_result(
			_challenge_move_id,
			_challenge_completions,
			_challenge_perfects,
			_challenge_score,
			_challenge_grade,
			_get_player_archetype_id()
		)

	var st: Dictionary = get_challenge_state()
	challenge_updated.emit(st)
	return st


func _compute_live_challenge_score() -> int:
	var completion_pts: int = _challenge_completions * 250
	var perfect_pts: int = _challenge_perfects * 150
	var target_bonus: int = 300 if _challenge_completions >= _challenge_target_count else 0
	var time_bonus: int = int(floor(_challenge_time_left * 10.0)) if _challenge_completions >= _challenge_target_count else 0
	return completion_pts + perfect_pts + target_bonus + time_bonus


# ==============================================================================
# Internal Wiring & Helpers
# ==============================================================================

func _load_tutorial_metadata(move_id: String) -> void:
	var m: FrameData = move_db.get_move(move_id)
	_tutorial_sequence.clear()
	if m != null:
		_tutorial_display_name = m.display_name
		_tutorial_archetype_id = m.archetype_id
		for s in m.sequence:
			_tutorial_sequence.append(s)
	else:
		_tutorial_display_name = move_id
		_tutorial_archetype_id = ""


func _advance_standalone_tutorial_step(symbol: String) -> void:
	if _tutorial_sequence.is_empty():
		_tutorial_step_index = 0
		return
	var norm: String = InputBuffer.normalize_symbol(symbol)
	if _tutorial_step_index < _tutorial_sequence.size() and InputBuffer.normalize_symbol(_tutorial_sequence[_tutorial_step_index]) == norm:
		_tutorial_step_index += 1
	elif InputBuffer.normalize_symbol(_tutorial_sequence[0]) == norm:
		_tutorial_step_index = 1
	else:
		_tutorial_step_index = 0


func _connect_event_bus() -> void:
	if _event_bus_connected:
		return
	var eb: Node = _get_event_bus()
	if eb == null:
		return
	if eb.has_signal("input_recorded") and not eb.is_connected("input_recorded", _on_eb_input_recorded):
		eb.connect("input_recorded", _on_eb_input_recorded)
	if eb.has_signal("combo_triggered") and not eb.is_connected("combo_triggered", _on_eb_combo_triggered):
		eb.connect("combo_triggered", _on_eb_combo_triggered)
	if eb.has_signal("shot_timing_feedback") and not eb.is_connected("shot_timing_feedback", _on_eb_shot_timing_feedback):
		eb.connect("shot_timing_feedback", _on_eb_shot_timing_feedback)
	_event_bus_connected = true


func _disconnect_event_bus() -> void:
	if not _event_bus_connected:
		return
	var eb: Node = _get_event_bus()
	if eb != null:
		if eb.is_connected("input_recorded", _on_eb_input_recorded):
			eb.disconnect("input_recorded", _on_eb_input_recorded)
		if eb.is_connected("combo_triggered", _on_eb_combo_triggered):
			eb.disconnect("combo_triggered", _on_eb_combo_triggered)
		if eb.is_connected("shot_timing_feedback", _on_eb_shot_timing_feedback):
			eb.disconnect("shot_timing_feedback", _on_eb_shot_timing_feedback)
	_event_bus_connected = false


func _on_eb_input_recorded(pid: int, record: Dictionary) -> void:
	if pid != owner_player_id:
		return
	on_input_recorded(record)


func _on_eb_combo_triggered(pid: int, combo_id: String, chain_count: int, is_perfect: bool) -> void:
	if pid != owner_player_id:
		return
	on_combo_triggered(combo_id, chain_count, is_perfect)


func _on_eb_shot_timing_feedback(pid: int, label: String, timing_error: float) -> void:
	if pid != owner_player_id:
		return
	on_shot_timing_feedback(label, timing_error)


func _get_combo_engine() -> Node:
	if owner_player == null:
		return null
	var ce: Variant = owner_player.get("combo_engine")
	if ce is Node:
		return ce as Node
	return owner_player.get_node_or_null("ComboEngine")


func _get_player_archetype_id() -> String:
	if owner_player != null and owner_player.get("archetype_id") != null:
		return str(owner_player.get("archetype_id"))
	return ""


func _get_event_bus() -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null("EventBus")
	return null
