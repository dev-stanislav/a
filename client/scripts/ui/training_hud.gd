class_name TrainingHUD
extends CanvasLayer
## Phase 11 — Anime Sports Skill Training Dojo HUD for PHANTOM COURT ONLINE.
## Displays live combo tutorial prompts & 30s challenge trial, fighting-game 16-entry
## input history tape, visual Early|Good|PERFECT|Late timing analysis bar,
## archetype/dummy/5-spot shot drill controls, and persistent skill mastery stats.
## Works cleanly BOTH bound to PracticeArenaController AND standalone in UI tests.

signal return_to_menu_requested()

const MAX_INPUT_HISTORY_ITEMS: int = 16
const TIMING_MAX_OFFSET_MS: float = 120.0
const MAIN_MENU_SCENE_PATH := "res://scenes/ui/main_menu.tscn"

# Anime sports high-contrast palette
const COL_BG_PANEL := Color(0.045, 0.068, 0.135, 0.86)
const COL_BG_SUBPANEL := Color(0.075, 0.110, 0.205, 0.92)
const COL_BORDER_CYAN := Color(0.0, 0.94, 1.0, 0.88)
const COL_BORDER_SLATE := Color(0.26, 0.36, 0.52, 0.72)
const COL_CHIP_DONE_BG := Color(0.05, 0.42, 0.28, 0.95)
const COL_CHIP_DONE_BORDER := Color(0.20, 0.95, 0.62, 1.0)
const COL_CHIP_ACTIVE_BG := Color(0.02, 0.32, 0.46, 0.98)
const COL_CHIP_ACTIVE_BORDER := Color(0.0, 0.95, 1.0, 1.0)
const COL_CHIP_PENDING_BG := Color(0.12, 0.16, 0.25, 0.90)
const COL_CHIP_PENDING_BORDER := Color(0.36, 0.45, 0.58, 0.78)
const COL_PERFECT := Color(0.18, 0.98, 0.68, 1.0)
const COL_GOOD := Color(0.22, 0.74, 0.98, 1.0)
const COL_EARLY := Color(0.98, 0.66, 0.16, 1.0)
const COL_LATE := Color(0.96, 0.28, 0.44, 1.0)
const COL_GOLD := Color(1.0, 0.84, 0.24, 1.0)
const COL_TEXT_PRIMARY := Color(0.95, 0.98, 1.0, 1.0)
const COL_TEXT_MUTED := Color(0.64, 0.74, 0.88, 1.0)

const TUTORIAL_CATALOG: Array[Dictionary] = [
	{"id": "phantom_drive", "name": "Phantom Drive", "tag": "Universal", "sequence": ["Q", "E", "Q", "Shift"]},
	{"id": "meteor_dunk", "name": "Meteor Dunk", "tag": "Universal", "sequence": ["Shift", "W", "Space", "R"]},
	{"id": "ankle_breaker", "name": "Ankle Breaker", "tag": "Universal", "sequence": ["E", "Q", "E", "LMB"]},
	{"id": "mirror_step", "name": "Mirror Step", "tag": "Universal", "sequence": ["Q", "Q", "E", "R"]},
	{"id": "volt_dash", "name": "Volt Dash", "tag": "Speedster", "sequence": ["Q", "Shift", "Q"]},
	{"id": "starlight_high_arc", "name": "Starlight High Arc", "tag": "Sharpshooter", "sequence": ["E", "S", "LMB"]},
	{"id": "mirage_thread", "name": "Mirage Thread", "tag": "Playmaker", "sequence": ["Q", "E", "RMB"]},
	{"id": "tectonic_slam", "name": "Tectonic Slam", "tag": "Powerhouse", "sequence": ["Shift", "Space", "LMB"]},
	{"id": "eclipse_counter", "name": "Eclipse Counter", "tag": "All-Rounder", "sequence": ["C", "Q", "E", "Shift"]},
]

const ARCHETYPE_OPTIONS: Array[Dictionary] = [
	{"id": "speedster", "label": "Speedster — Volt"},
	{"id": "sharpshooter", "label": "Sharpshooter — Deadeye"},
	{"id": "playmaker", "label": "Playmaker — Mirage"},
	{"id": "powerhouse", "label": "Powerhouse — Titan"},
	{"id": "all_rounder", "label": "All-Rounder — Eclipse"},
]

const DUMMY_MODE_NAMES: Array[String] = [
	"Idle",
	"Stance Contest",
	"Jump Block",
	"Steal Interval",
	"Mirror Guard",
	"Live Phantom AI",
]

# Bound controller reference (optional — null in standalone UI tests)
var _controller: Node = null
var _tracked_player_id: int = 1
var _suppress_ui_callbacks: bool = false
var _ui_ready: bool = false

# Live display state (inspected by QA getters)
var _current_tutorial_move: String = "phantom_drive"
var _current_tutorial_name: String = "Phantom Drive"
var _current_sequence: Array[String] = ["Q", "E", "Q", "Shift"]
var _current_step_statuses: Array[String] = ["active", "pending", "pending", "pending"]
var _current_archetype_id: String = "speedster"
var _current_dummy_mode_idx: int = 0
var _current_dummy_mode_name: String = "Idle"
var _challenge_active: bool = false
var _challenge_grade: String = "--"
var _shot_drill_active: bool = false
var _displayed_timing_text: String = "READY — INPUT COMBO OR SHOT"
var _displayed_mastery_text: String = ""
var _displayed_shot_drill_text: String = "Shot Drill: Ready (5 Spots)"
var _input_history_entries: Array[Dictionary] = []

# Standalone fallback input parser state (only used when unbound from PracticeArenaController)
var _standalone_prev_buttons: int = 0
var _standalone_prev_dir: String = ""
var _standalone_last_frame: int = -1
var _standalone_attempts: int = 0
var _standalone_completions: int = 0
var _standalone_perfects: int = 0
var _standalone_streak: int = 0
var _standalone_best_streak: int = 0

# Animation state
var _pulse_time: float = 0.0
var _target_needle_norm: float = 0.0
var _current_needle_norm: float = 0.0
var _active_chip_styles: Array[StyleBoxFlat] = []

# Resolved UI node references
var _hud_root: Control = null
var _combo_card: PanelContainer = null
var _combo_selector: OptionButton = null
var _tutorial_move_label: Label = null
var _prompt_chips_row: HBoxContainer = null
var _tutorial_feedback_label: Label = null
var _challenge_button: Button = null
var _challenge_timer_label: Label = null
var _challenge_count_label: Label = null
var _challenge_grade_badge: PanelContainer = null
var _challenge_grade_label: Label = null
var _challenge_grade_style: StyleBoxFlat = null

var _history_panel: PanelContainer = null
var _history_list: VBoxContainer = null

var _timing_panel: PanelContainer = null
var _timing_track: Control = null
var _timing_needle: ColorRect = null
var _timing_readout_label: Label = null

var _controls_panel: PanelContainer = null
var _archetype_selector: OptionButton = null
var _dummy_mode_selector: OptionButton = null
var _shot_drill_button: Button = null
var _shot_drill_label: Label = null
var _reset_button: Button = null
var _return_menu_button: Button = null

var _mastery_card: PanelContainer = null
var _mastery_rank_badge: PanelContainer = null
var _mastery_rank_label: Label = null
var _mastery_rank_style: StyleBoxFlat = null
var _mastery_stats_label: Label = null


func _enter_tree() -> void:
	_connect_event_bus()


func _ready() -> void:
	layer = 15
	_ensure_ui_ready()
	_connect_event_bus()
	var gs: Node = _get_autoload("GameState")
	if gs != null:
		var lpid: Variant = gs.get("local_player_id")
		if lpid != null:
			_tracked_player_id = int(lpid)
		var sel_arch: Variant = gs.get("selected_archetype")
		if sel_arch is String and _find_archetype_index(sel_arch as String) >= 0:
			select_archetype_by_id(sel_arch as String, false)


func _exit_tree() -> void:
	_disconnect_event_bus()
	_disconnect_controller()


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	_pulse_time += delta
	_animate_active_chips()
	_animate_timing_needle(delta)


# ==============================================================================
# Public Controller Binding Contract (Phase 11)
# ==============================================================================

func bind_practice_controller(controller: Node) -> void:
	_ensure_ui_ready()
	_disconnect_controller()
	_controller = controller
	if _controller == null or not is_instance_valid(_controller):
		_controller = null
		return

	if _controller.has_method("get_player"):
		var player: Variant = _controller.call("get_player")
		if player is Node and is_instance_valid(player):
			var pid: Variant = (player as Node).get("player_id")
			if pid != null:
				_tracked_player_id = int(pid)

	_connect_controller_signal("tutorial_updated", _on_tutorial_updated)
	_connect_controller_signal("input_history_updated", _on_input_history_updated)
	_connect_controller_signal("timing_analyzed", _on_timing_analyzed)
	_connect_controller_signal("shot_drill_updated", _on_shot_drill_updated)
	_connect_controller_signal("challenge_updated", _on_challenge_updated)
	_connect_controller_signal("dummy_mode_changed", _on_dummy_mode_changed)
	_connect_controller_signal("mastery_updated", _on_mastery_updated)

	if _controller.has_method("get_training_snapshot"):
		var snap: Variant = _controller.call("get_training_snapshot")
		if snap is Dictionary:
			apply_training_snapshot(snap as Dictionary)


func apply_training_snapshot(snapshot: Dictionary) -> void:
	_ensure_ui_ready()
	if snapshot.has("archetype_id"):
		select_archetype_by_id(str(snapshot["archetype_id"]), false)
	elif snapshot.has("archetype"):
		select_archetype_by_id(str(snapshot["archetype"]), false)

	if snapshot.has("dummy_mode"):
		var d_name: String = str(snapshot.get("dummy_mode_name", ""))
		_on_dummy_mode_changed(snapshot["dummy_mode"], d_name)
	elif snapshot.has("dummy") and snapshot["dummy"] is Dictionary:
		var d_dict: Dictionary = snapshot["dummy"]
		_on_dummy_mode_changed(d_dict.get("mode", 0), str(d_dict.get("mode_name", "")))

	if snapshot.has("tutorial") and snapshot["tutorial"] is Dictionary:
		_on_tutorial_updated(snapshot["tutorial"] as Dictionary)

	if snapshot.has("input_history") and snapshot["input_history"] is Array:
		_on_input_history_updated(snapshot["input_history"] as Array)

	if snapshot.has("last_timing_analysis") and snapshot["last_timing_analysis"] is Dictionary and not (snapshot["last_timing_analysis"] as Dictionary).is_empty():
		_on_timing_analyzed(snapshot["last_timing_analysis"] as Dictionary)
	elif snapshot.has("timing") and snapshot["timing"] is Dictionary and not (snapshot["timing"] as Dictionary).is_empty():
		_on_timing_analyzed(snapshot["timing"] as Dictionary)
	elif snapshot.has("last_timing") and snapshot["last_timing"] is Dictionary and not (snapshot["last_timing"] as Dictionary).is_empty():
		_on_timing_analyzed(snapshot["last_timing"] as Dictionary)

	if snapshot.has("shot_drill") and snapshot["shot_drill"] is Dictionary:
		_on_shot_drill_updated(snapshot["shot_drill"] as Dictionary)

	if snapshot.has("challenge") and snapshot["challenge"] is Dictionary:
		_on_challenge_updated(snapshot["challenge"] as Dictionary)

	if snapshot.has("mastery") and snapshot["mastery"] is Dictionary:
		_on_mastery_updated(snapshot["mastery"] as Dictionary)


# ==============================================================================
# Required QA Inspection Getters & Programmatic Helpers
# ==============================================================================

func get_displayed_input_history_count() -> int:
	_ensure_ui_ready()
	return _input_history_entries.size()


func get_displayed_timing_text() -> String:
	_ensure_ui_ready()
	return _timing_readout_label.text if _timing_readout_label != null else _displayed_timing_text


func get_displayed_tutorial_move() -> String:
	_ensure_ui_ready()
	return _current_tutorial_move


func get_displayed_tutorial_name() -> String:
	_ensure_ui_ready()
	return _current_tutorial_name


func get_displayed_dummy_mode() -> String:
	_ensure_ui_ready()
	return _current_dummy_mode_name


func get_displayed_dummy_mode_index() -> int:
	_ensure_ui_ready()
	return _current_dummy_mode_idx


func get_displayed_mastery_text() -> String:
	_ensure_ui_ready()
	return _mastery_stats_label.text if _mastery_stats_label != null else _displayed_mastery_text


func get_displayed_shot_drill_text() -> String:
	_ensure_ui_ready()
	return _shot_drill_label.text if _shot_drill_label != null else _displayed_shot_drill_text


func get_displayed_challenge_grade() -> String:
	_ensure_ui_ready()
	return _challenge_grade_label.text if _challenge_grade_label != null else _challenge_grade


func get_displayed_prompt_statuses() -> Array[String]:
	return _current_step_statuses.duplicate()


func get_displayed_archetype() -> String:
	return _current_archetype_id


func select_combo_by_id(move_id: String, notify_controller: bool = true) -> void:
	_ensure_ui_ready()
	var idx: int = _find_tutorial_index(move_id)
	if idx < 0:
		return
	var entry: Dictionary = TUTORIAL_CATALOG[idx]
	_current_tutorial_move = str(entry["id"])
	_current_tutorial_name = str(entry["name"])
	var seq_arr: Array[String] = []
	var statuses: Array[String] = []
	var raw_seq: Array = entry["sequence"]
	for i in range(raw_seq.size()):
		seq_arr.append(str(raw_seq[i]))
		statuses.append("active" if i == 0 else "pending")
	_current_sequence = seq_arr
	_current_step_statuses = statuses

	_suppress_ui_callbacks = true
	if _combo_selector != null and _combo_selector.selected != idx:
		_combo_selector.select(idx)
	_suppress_ui_callbacks = false

	_refresh_tutorial_widgets("STEP 1 / %d — FOLLOW PROMPT" % maxi(1, seq_arr.size()))
	if notify_controller and _controller != null and is_instance_valid(_controller) and _controller.has_method("select_tutorial"):
		_controller.call("select_tutorial", _current_tutorial_move)


func select_archetype_by_id(arch_id: String, notify_controller: bool = true) -> void:
	_ensure_ui_ready()
	var idx: int = _find_archetype_index(arch_id)
	if idx < 0:
		return
	_current_archetype_id = str(ARCHETYPE_OPTIONS[idx]["id"])
	_suppress_ui_callbacks = true
	if _archetype_selector != null and _archetype_selector.selected != idx:
		_archetype_selector.select(idx)
	_suppress_ui_callbacks = false

	if notify_controller and _controller != null and is_instance_valid(_controller) and _controller.has_method("set_player_archetype"):
		_controller.call("set_player_archetype", _current_archetype_id)


func select_dummy_mode_by_index(mode_idx: int, notify_controller: bool = true) -> void:
	_ensure_ui_ready()
	var clamped: int = clampi(mode_idx, 0, DUMMY_MODE_NAMES.size() - 1)
	_current_dummy_mode_idx = clamped
	_current_dummy_mode_name = DUMMY_MODE_NAMES[clamped]
	_suppress_ui_callbacks = true
	if _dummy_mode_selector != null and _dummy_mode_selector.selected != clamped:
		_dummy_mode_selector.select(clamped)
	_suppress_ui_callbacks = false

	if notify_controller and _controller != null and is_instance_valid(_controller) and _controller.has_method("set_dummy_mode"):
		_controller.call("set_dummy_mode", clamped)


# ==============================================================================
# Controller & EventBus Signal Handlers
# ==============================================================================

func _on_tutorial_updated(state: Dictionary) -> void:
	_ensure_ui_ready()
	var move_id: String = str(state.get("move_id", state.get("id", _current_tutorial_move))).strip_edges()
	if not move_id.is_empty():
		_current_tutorial_move = move_id
		var cat_idx: int = _find_tutorial_index(move_id)
		if cat_idx >= 0:
			_suppress_ui_callbacks = true
			if _combo_selector != null and _combo_selector.selected != cat_idx:
				_combo_selector.select(cat_idx)
			_suppress_ui_callbacks = false
			_current_tutorial_name = str(state.get("display_name", state.get("move_name", TUTORIAL_CATALOG[cat_idx]["name"])))
		else:
			_current_tutorial_name = str(state.get("display_name", state.get("move_name", move_id.capitalize())))

	var seq_arr: Array[String] = []
	var raw_seq: Variant = state.get("sequence", [])
	if raw_seq is Array and not (raw_seq as Array).is_empty():
		for item in raw_seq:
			seq_arr.append(str(item))
	else:
		var idx_fb: int = _find_tutorial_index(_current_tutorial_move)
		if idx_fb >= 0:
			for item in TUTORIAL_CATALOG[idx_fb]["sequence"]:
				seq_arr.append(str(item))
		else:
			seq_arr = _current_sequence.duplicate()

	var step_idx: int = int(state.get("current_step_index", state.get("step_index", 0)))
	var statuses: Array[String] = []
	var raw_statuses: Variant = state.get("step_statuses", [])
	if raw_statuses is Array and (raw_statuses as Array).size() == seq_arr.size():
		for st in raw_statuses:
			statuses.append(str(st).to_lower())
	else:
		for i in range(seq_arr.size()):
			if i < step_idx:
				statuses.append("done")
			elif i == step_idx:
				statuses.append("active")
			else:
				statuses.append("pending")

	_current_sequence = seq_arr
	_current_step_statuses = statuses

	var feedback: String = str(state.get("feedback", ""))
	var completed: bool = bool(state.get("completed", state.get("just_completed", false)))
	var is_perfect: bool = bool(state.get("is_perfect", false))
	if feedback.is_empty():
		if completed:
			feedback = "PERFECT EXECUTION! ★" if is_perfect else "COMBO COMPLETE!"
		else:
			var disp_step: int = clampi(step_idx + 1, 1, maxi(1, seq_arr.size()))
			feedback = "STEP %d / %d — FOLLOW PROMPT" % [disp_step, maxi(1, seq_arr.size())]

	_refresh_tutorial_widgets(feedback, completed, is_perfect)


func _on_input_history_updated(history: Array) -> void:
	_ensure_ui_ready()
	_input_history_entries.clear()
	var total: int = history.size()
	var start_idx: int = maxi(0, total - MAX_INPUT_HISTORY_ITEMS)
	for i in range(start_idx, total):
		var item: Variant = history[i]
		if item is Dictionary:
			_input_history_entries.append((item as Dictionary).duplicate())
	_rebuild_input_history_list()


func _on_timing_analyzed(analysis: Dictionary) -> void:
	_ensure_ui_ready()
	if analysis.is_empty():
		return
	var offset_ms: float
	var offset_frames: float
	if analysis.has("offset_ms"):
		offset_ms = float(analysis["offset_ms"])
		offset_frames = float(analysis.get("offset_frames", offset_ms * 0.06))
	elif analysis.has("offset_frames"):
		offset_frames = float(analysis["offset_frames"])
		offset_ms = offset_frames * (1000.0 / 60.0)
	else:
		offset_ms = 0.0
		offset_frames = 0.0

	var grade: String = str(analysis.get("grade", analysis.get("label", analysis.get("timing_tag", "GOOD")))).strip_edges()
	if grade.is_empty():
		grade = "GOOD"
	var grade_upper: String = grade.to_upper()
	var suffix: String = "!" if grade_upper == "PERFECT" else ""
	_displayed_timing_text = "%+.0fms (%+.1ff) %s%s" % [offset_ms, offset_frames, grade_upper, suffix]

	if _timing_readout_label != null:
		_timing_readout_label.text = _displayed_timing_text
		_timing_readout_label.add_theme_color_override("font_color", _color_for_timing_grade(grade_upper))

	_target_needle_norm = clampf(offset_ms / TIMING_MAX_OFFSET_MS, -1.0, 1.0)
	_current_needle_norm = _target_needle_norm
	_position_timing_needle(_current_needle_norm)


func _on_shot_drill_updated(drill_state: Dictionary) -> void:
	_ensure_ui_ready()
	_shot_drill_active = bool(drill_state.get("active", drill_state.get("is_active", false)))
	if _shot_drill_button != null:
		_shot_drill_button.text = "Stop Shot Drill" if _shot_drill_active else "Start 5-Spot Shot Drill"

	var spot_name: String = str(drill_state.get("spot_name", drill_state.get("current_spot_name", drill_state.get("spot", ""))))
	var spot_idx: int = int(drill_state.get("spot_index", 0))
	var total_spots: int = maxi(1, int(drill_state.get("spot_count", drill_state.get("total_spots", 5))))
	var makes: int = int(drill_state.get("makes", drill_state.get("total_makes", 0)))
	var attempts: int = int(drill_state.get("attempts", drill_state.get("total_attempts", 0)))
	var streak: int = int(drill_state.get("streak", drill_state.get("current_streak", 0)))
	var pct: float = float(drill_state.get("make_pct", drill_state.get("accuracy_pct", -1.0)))
	if pct < 0.0:
		pct = (100.0 * float(makes) / float(attempts)) if attempts > 0 else 0.0

	if _shot_drill_active:
		var spot_label: String = spot_name if not spot_name.is_empty() else ("Spot %d/%d" % [spot_idx + 1, total_spots])
		_displayed_shot_drill_text = "%s (%d/%d)\nMakes: %d/%d (%.0f%%) • Streak: %d" % [
			spot_label,
			clampi(spot_idx + 1, 1, total_spots),
			total_spots,
			makes,
			attempts,
			pct,
			streak,
		]
	else:
		if attempts > 0:
			_displayed_shot_drill_text = "Shot Drill: Idle | Last: %d/%d (%.0f%%)" % [makes, attempts, pct]
		else:
			_displayed_shot_drill_text = "Shot Drill: Ready (5 Spots)"

	if _shot_drill_label != null:
		_shot_drill_label.text = _displayed_shot_drill_text
		_shot_drill_label.add_theme_color_override("font_color", COL_PERFECT if _shot_drill_active else COL_TEXT_MUTED)


func _on_challenge_updated(challenge_state: Dictionary) -> void:
	_ensure_ui_ready()
	_challenge_active = bool(challenge_state.get("active", challenge_state.get("is_active", false)))
	var time_left: float = maxf(0.0, float(challenge_state.get("time_remaining", challenge_state.get("time_left", 30.0))))
	var completions: int = int(challenge_state.get("completions", 0))
	var target: int = maxi(1, int(challenge_state.get("target_count", challenge_state.get("target", 3))))
	var grade: String = str(challenge_state.get("grade", "--")).strip_edges()
	if grade.is_empty():
		grade = "--"
	_challenge_grade = grade

	if _challenge_button != null:
		_challenge_button.text = "Stop Challenge" if _challenge_active else "Start 30s Challenge"
	if _challenge_timer_label != null:
		_challenge_timer_label.text = "%.1fs" % time_left
		_challenge_timer_label.add_theme_color_override(
			"font_color",
			COL_LATE if (_challenge_active and time_left <= 5.0) else (COL_BORDER_CYAN if _challenge_active else COL_TEXT_MUTED)
		)
	if _challenge_count_label != null:
		_challenge_count_label.text = "%d / %d" % [completions, target]
	if _challenge_grade_label != null:
		_challenge_grade_label.text = grade
		var g_col: Color = _color_for_challenge_grade(grade)
		_challenge_grade_label.add_theme_color_override("font_color", g_col)
		if _challenge_grade_style != null:
			_challenge_grade_style.border_color = g_col


func _on_dummy_mode_changed(mode: Variant, mode_name: String = "") -> void:
	_ensure_ui_ready()
	var resolved_idx: int = _current_dummy_mode_idx
	if mode is int:
		resolved_idx = clampi(int(mode), 0, DUMMY_MODE_NAMES.size() - 1)
	elif mode is String:
		var lower_m: String = (mode as String).strip_edges().to_lower()
		for i in range(DUMMY_MODE_NAMES.size()):
			var candidate: String = DUMMY_MODE_NAMES[i].to_lower()
			if candidate == lower_m or candidate.replace(" ", "_") == lower_m:
				resolved_idx = i
				break

	_current_dummy_mode_idx = resolved_idx
	_current_dummy_mode_name = mode_name if not mode_name.strip_edges().is_empty() else DUMMY_MODE_NAMES[resolved_idx]

	_suppress_ui_callbacks = true
	if _dummy_mode_selector != null and _dummy_mode_selector.selected != resolved_idx:
		_dummy_mode_selector.select(resolved_idx)
	_suppress_ui_callbacks = false


func _on_mastery_updated(summary: Dictionary) -> void:
	_ensure_ui_ready()
	var attempts: int = int(summary.get("total_attempts", summary.get("attempts", 0)))
	var completions: int = int(summary.get("total_completions", summary.get("completions", 0)))
	var perfects: int = int(summary.get("total_perfect_completions", summary.get("perfect_completions", summary.get("perfects", 0))))
	var best_streak: int = int(summary.get("best_streak", 0))

	var perfect_pct: float = 0.0
	if summary.has("perfect_rate_pct"):
		perfect_pct = float(summary["perfect_rate_pct"])
	elif summary.has("perfect_rate"):
		var raw_pr: float = float(summary["perfect_rate"])
		perfect_pct = raw_pr * 100.0 if (raw_pr <= 1.0 and raw_pr > 0.0) else raw_pr
	elif completions > 0:
		perfect_pct = 100.0 * float(perfects) / float(completions)

	var shot_attempts: int = int(summary.get("shot_attempts", 0))
	var shot_makes: int = int(summary.get("shot_makes", 0))
	var shot_pct: float = -1.0
	if summary.has("shots") and summary["shots"] is Dictionary:
		var sh: Dictionary = summary["shots"]
		shot_attempts = int(sh.get("attempts", sh.get("total_attempts", shot_attempts)))
		shot_makes = int(sh.get("makes", sh.get("total_makes", shot_makes)))
		if sh.has("accuracy_pct"):
			shot_pct = float(sh["accuracy_pct"])
		elif sh.has("make_pct"):
			shot_pct = float(sh["make_pct"])
	if shot_pct < 0.0:
		if summary.has("shot_accuracy_pct"):
			shot_pct = float(summary["shot_accuracy_pct"])
		elif summary.has("shot_accuracy"):
			var raw_sa: float = float(summary["shot_accuracy"])
			shot_pct = raw_sa * 100.0 if (raw_sa <= 1.0 and raw_sa > 0.0) else raw_sa
		else:
			shot_pct = (100.0 * float(shot_makes) / float(shot_attempts)) if shot_attempts > 0 else 0.0

	var rank: String = str(summary.get("mastery_rank", summary.get("overall_rank", summary.get("rank", "Novice")))).strip_edges()
	if rank.is_empty():
		rank = "Novice"

	_render_mastery_display(attempts, completions, perfect_pct, best_streak, shot_makes, shot_attempts, shot_pct, rank)


func _on_event_bus_input_recorded(player_id: int, frame: Dictionary) -> void:
	if player_id != _tracked_player_id:
		return
	# When bound to PracticeArenaController, its ComboTrainer owns input_history_updated.
	if _controller != null and is_instance_valid(_controller) and _controller.has_signal("input_history_updated"):
		return

	# Support direct ComboEngine token records ({symbol, frame, gap_frames}) as well as raw PlayerInputFrames
	if frame.has("symbol"):
		var sym_direct: String = str(frame.get("symbol", "")).strip_edges()
		if sym_direct.is_empty():
			return
		var f_num: int = int(frame.get("frame", _standalone_last_frame + 1))
		var gap_direct: int = int(frame.get("gap_frames", 0 if _standalone_last_frame < 0 else maxi(0, f_num - _standalone_last_frame)))
		var tag_direct: String = "START"
		var perf_direct: bool = false
		if not _input_history_entries.is_empty() and gap_direct > 0 and gap_direct <= 18:
			if gap_direct >= 4 and gap_direct <= 9:
				tag_direct = "PERFECT"
				perf_direct = true
			elif gap_direct < 4:
				tag_direct = "EARLY"
			else:
				tag_direct = "LATE"
		_standalone_last_frame = f_num
		_input_history_entries.append({
			"symbol": sym_direct,
			"frame": f_num,
			"gap_frames": gap_direct,
			"timing_tag": tag_direct,
			"is_perfect_gap": perf_direct,
		})
		if _input_history_entries.size() > MAX_INPUT_HISTORY_ITEMS:
			_input_history_entries.pop_front()
		if tag_direct != "START":
			var off_df: float = float(gap_direct) - 6.5
			_on_timing_analyzed({
				"offset_frames": off_df,
				"offset_ms": off_df * (1000.0 / 60.0),
				"grade": tag_direct,
			})
		_rebuild_input_history_list()
		return

	var tick: int = int(frame.get("tick", _standalone_last_frame + 1))
	var buttons: int = int(frame.get("buttons", 0))
	var rising: int = buttons & (~_standalone_prev_buttons)
	_standalone_prev_buttons = buttons

	var emitted_symbols: Array[String] = []
	var local_dir_val: Variant = frame.get("local_dir", Vector2.ZERO)
	var dir_sym: String = ""
	if local_dir_val is Vector2:
		var v: Vector2 = local_dir_val as Vector2
		if v.length_squared() >= 0.2025:
			if absf(v.y) >= absf(v.x):
				dir_sym = "W" if v.y > 0.0 else "S"
			else:
				dir_sym = "D" if v.x > 0.0 else "A"
	if not dir_sym.is_empty() and dir_sym != _standalone_prev_dir:
		emitted_symbols.append(dir_sym)
	_standalone_prev_dir = dir_sym

	for btn_def in InputBuffer.BUTTON_DEFINITIONS:
		var bit: int = int(btn_def["bit"])
		if (rising & bit) != 0:
			emitted_symbols.append(str(btn_def["symbol"]))

	if emitted_symbols.is_empty():
		return

	for sym in emitted_symbols:
		var gap: int = 0 if _standalone_last_frame < 0 else maxi(0, tick - _standalone_last_frame)
		var tag: String = "START"
		var is_perf: bool = false
		if _standalone_last_frame >= 0:
			if gap >= 4 and gap <= 9:
				tag = "PERFECT"
				is_perf = true
			elif gap < 4:
				tag = "EARLY"
			else:
				tag = "LATE"
		_standalone_last_frame = tick
		_input_history_entries.append({
			"symbol": sym,
			"frame": tick,
			"gap_frames": gap,
			"timing_tag": tag,
			"is_perfect_gap": is_perf,
		})
		if _input_history_entries.size() > MAX_INPUT_HISTORY_ITEMS:
			_input_history_entries.pop_front()
		if tag != "START":
			var target_gap: float = 6.5
			var off_f: float = float(gap) - target_gap
			_on_timing_analyzed({
				"offset_frames": off_f,
				"offset_ms": off_f * (1000.0 / 60.0),
				"grade": tag,
			})

	_rebuild_input_history_list()


func _on_event_bus_combo_triggered(player_id: int, combo_id: String, _combo_tier: int, is_perfect: bool) -> void:
	if player_id != _tracked_player_id:
		return
	if combo_id == _current_tutorial_move:
		var done_statuses: Array[String] = []
		for _i in range(_current_sequence.size()):
			done_statuses.append("done")
		_current_step_statuses = done_statuses
		_refresh_tutorial_widgets("PERFECT COMBO! ★" if is_perfect else "COMBO COMPLETE!", true, is_perfect)

	if _controller == null or not is_instance_valid(_controller):
		_standalone_attempts += 1
		_standalone_completions += 1
		if is_perfect:
			_standalone_perfects += 1
		_standalone_streak += 1
		_standalone_best_streak = maxi(_standalone_best_streak, _standalone_streak)
		var pct: float = 100.0 * float(_standalone_perfects) / float(maxi(1, _standalone_completions))
		var rank: String = "Phantom" if _standalone_completions >= 15 else ("Master" if _standalone_completions >= 8 else ("Adept" if _standalone_completions >= 3 else "Novice"))
		_render_mastery_display(_standalone_attempts, _standalone_completions, pct, _standalone_best_streak, 0, 0, 0.0, rank)


func _on_event_bus_shot_timing_feedback(player_id: int, label: String, timing_error: float) -> void:
	if player_id != _tracked_player_id:
		return
	var offset_ms: float = timing_error * 1000.0
	var offset_frames: float = timing_error * 60.0
	_on_timing_analyzed({
		"offset_ms": offset_ms,
		"offset_frames": offset_frames,
		"grade": label,
		"source": "shot",
	})


# ==============================================================================
# UI Control Callbacks
# ==============================================================================

func _on_combo_selected(index: int) -> void:
	if _suppress_ui_callbacks or index < 0 or index >= TUTORIAL_CATALOG.size():
		return
	select_combo_by_id(str(TUTORIAL_CATALOG[index]["id"]), true)


func _on_challenge_button_pressed() -> void:
	if _controller != null and is_instance_valid(_controller):
		if _challenge_active:
			if _controller.has_method("stop_challenge"):
				_controller.call("stop_challenge")
		else:
			if _controller.has_method("start_challenge"):
				_controller.call("start_challenge", _current_tutorial_move, 3, 30.0)
	else:
		_on_challenge_updated({
			"active": not _challenge_active,
			"time_remaining": 30.0,
			"completions": 0,
			"target_count": 3,
			"grade": "--",
		})


func _on_archetype_selected(index: int) -> void:
	if _suppress_ui_callbacks or index < 0 or index >= ARCHETYPE_OPTIONS.size():
		return
	select_archetype_by_id(str(ARCHETYPE_OPTIONS[index]["id"]), true)


func _on_dummy_mode_selected(index: int) -> void:
	if _suppress_ui_callbacks or index < 0 or index >= DUMMY_MODE_NAMES.size():
		return
	select_dummy_mode_by_index(index, true)


func _on_shot_drill_pressed() -> void:
	if _controller != null and is_instance_valid(_controller):
		if _shot_drill_active:
			if _controller.has_method("stop_shot_practice"):
				_controller.call("stop_shot_practice")
		else:
			if _controller.has_method("start_shot_practice"):
				_controller.call("start_shot_practice")
	else:
		_on_shot_drill_updated({
			"active": not _shot_drill_active,
			"spot_name": "Left Corner 3",
			"spot_index": 0,
			"total_spots": 5,
			"makes": 0,
			"attempts": 0,
			"streak": 0,
		})


func _on_reset_position_pressed() -> void:
	if _controller != null and is_instance_valid(_controller) and _controller.has_method("reset_drill_positions"):
		_controller.call("reset_drill_positions")


func _on_return_menu_pressed() -> void:
	return_to_menu_requested.emit()
	var main_node: Node = _get_autoload("Main")
	if main_node != null and is_instance_valid(main_node):
		if main_node.has_method("load_scene") and ResourceLoader.exists(MAIN_MENU_SCENE_PATH):
			main_node.call("load_scene", MAIN_MENU_SCENE_PATH)
		elif main_node.has_method("show_main_menu"):
			main_node.call("show_main_menu")


# ==============================================================================
# Widget Rendering & Procedural Styling
# ==============================================================================

func _refresh_tutorial_widgets(feedback: String, completed: bool = false, is_perfect: bool = false) -> void:
	if _tutorial_move_label != null:
		var idx: int = _find_tutorial_index(_current_tutorial_move)
		var tag: String = str(TUTORIAL_CATALOG[idx]["tag"]) if idx >= 0 else "Skill"
		_tutorial_move_label.text = "%s  •  %s" % [_current_tutorial_name.to_upper(), tag.to_upper()]

	if _tutorial_feedback_label != null:
		_tutorial_feedback_label.text = feedback
		var fb_col: Color = COL_GOLD if (completed and is_perfect) else (COL_PERFECT if completed else COL_BORDER_CYAN)
		_tutorial_feedback_label.add_theme_color_override("font_color", fb_col)

	_rebuild_prompt_chips()


func _rebuild_prompt_chips() -> void:
	if _prompt_chips_row == null:
		return
	for child in _prompt_chips_row.get_children():
		_prompt_chips_row.remove_child(child)
		child.free()
	_active_chip_styles.clear()

	for i in range(_current_sequence.size()):
		if i > 0:
			var arrow := Label.new()
			arrow.text = "→"
			arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
			arrow.add_theme_font_size_override("font_size", 14)
			arrow.add_theme_color_override("font_color", COL_TEXT_MUTED)
			_prompt_chips_row.add_child(arrow)

		var status: String = _current_step_statuses[i] if i < _current_step_statuses.size() else "pending"
		var chip := PanelContainer.new()
		chip.name = "PromptChip_%d" % i
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(6)
		style.set_border_width_all(2)
		style.content_margin_left = 10.0
		style.content_margin_right = 10.0
		style.content_margin_top = 4.0
		style.content_margin_bottom = 4.0

		var text_col: Color = COL_TEXT_PRIMARY
		match status:
			"done":
				style.bg_color = COL_CHIP_DONE_BG
				style.border_color = COL_CHIP_DONE_BORDER
				text_col = Color(0.86, 1.0, 0.94, 1.0)
			"active":
				style.bg_color = COL_CHIP_ACTIVE_BG
				style.border_color = COL_CHIP_ACTIVE_BORDER
				text_col = Color(1.0, 1.0, 1.0, 1.0)
				_active_chip_styles.append(style)
			_:
				style.bg_color = COL_CHIP_PENDING_BG
				style.border_color = COL_CHIP_PENDING_BORDER
				text_col = COL_TEXT_MUTED

		chip.add_theme_stylebox_override("panel", style)
		var lbl := Label.new()
		lbl.text = _format_input_symbol(_current_sequence[i])
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.add_theme_font_size_override("font_size", 14)
		lbl.add_theme_color_override("font_color", text_col)
		chip.add_child(lbl)
		_prompt_chips_row.add_child(chip)


func _rebuild_input_history_list() -> void:
	if _history_list == null:
		return
	for child in _history_list.get_children():
		_history_list.remove_child(child)
		child.free()

	# Display newest inputs at top of the fighting-game tape
	for idx in range(_input_history_entries.size() - 1, -1, -1):
		var entry: Dictionary = _input_history_entries[idx]
		var sym: String = str(entry.get("symbol", "?"))
		var gap: int = int(entry.get("gap_frames", 0))
		var tag: String = str(entry.get("timing_tag", "START")).to_upper()
		var is_perf: bool = bool(entry.get("is_perfect_gap", tag == "PERFECT"))

		var row := PanelContainer.new()
		row.name = "HistoryEntry_%d" % idx
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var row_style := StyleBoxFlat.new()
		row_style.bg_color = Color(0.08, 0.12, 0.22, 0.88) if not is_perf else Color(0.05, 0.24, 0.28, 0.92)
		row_style.border_color = COL_PERFECT if is_perf else COL_BORDER_SLATE
		row_style.border_width_left = 3
		row_style.set_corner_radius_all(4)
		row_style.content_margin_left = 8.0
		row_style.content_margin_right = 8.0
		row_style.content_margin_top = 3.0
		row_style.content_margin_bottom = 3.0
		row.add_theme_stylebox_override("panel", row_style)

		var hbox := HBoxContainer.new()
		hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_theme_constant_override("separation", 6)
		row.add_child(hbox)

		var sym_lbl := Label.new()
		sym_lbl.text = "[%s]" % _format_input_symbol(sym)
		sym_lbl.custom_minimum_size = Vector2(68.0, 0.0)
		sym_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sym_lbl.add_theme_font_size_override("font_size", 13)
		sym_lbl.add_theme_color_override("font_color", COL_TEXT_PRIMARY)
		hbox.add_child(sym_lbl)

		var delta_lbl := Label.new()
		delta_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		delta_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		delta_lbl.add_theme_font_size_override("font_size", 12)
		if tag == "START":
			delta_lbl.text = "START"
			delta_lbl.add_theme_color_override("font_color", COL_TEXT_MUTED)
		elif is_perf:
			delta_lbl.text = "+%df ★ PERFECT" % gap
			delta_lbl.add_theme_color_override("font_color", COL_PERFECT)
		else:
			delta_lbl.text = "+%df %s" % [gap, tag]
			delta_lbl.add_theme_color_override("font_color", _color_for_timing_grade(tag))
		hbox.add_child(delta_lbl)

		_history_list.add_child(row)


func _render_mastery_display(
	attempts: int,
	completions: int,
	perfect_pct: float,
	best_streak: int,
	shot_makes: int,
	shot_attempts: int,
	shot_pct: float,
	rank: String
) -> void:
	_displayed_mastery_text = (
		"Attempts: %d  |  Completions: %d\n"
		+ "Perfect Rate: %.1f%%  |  Best Streak: %d\n"
		+ "Shot Accuracy: %.1f%% (%d/%d)\n"
		+ "Mastery Rank: %s"
	) % [
		attempts,
		completions,
		clampf(perfect_pct, 0.0, 100.0),
		best_streak,
		clampf(shot_pct, 0.0, 100.0),
		shot_makes,
		shot_attempts,
		rank,
	]

	if _mastery_stats_label != null:
		_mastery_stats_label.text = _displayed_mastery_text
	if _mastery_rank_label != null:
		_mastery_rank_label.text = rank.to_upper()
		var rank_col: Color = _color_for_mastery_rank(rank)
		_mastery_rank_label.add_theme_color_override("font_color", rank_col)
		if _mastery_rank_style != null:
			_mastery_rank_style.border_color = rank_col


func _animate_active_chips() -> void:
	if _active_chip_styles.is_empty():
		return
	var pulse: float = 0.5 + 0.5 * sin(_pulse_time * 7.0)
	var border_col: Color = COL_CHIP_ACTIVE_BORDER.lerp(Color.WHITE, pulse * 0.45)
	for style in _active_chip_styles:
		style.border_color = border_col


func _animate_timing_needle(dt: float) -> void:
	if _timing_needle == null:
		return
	if absf(_current_needle_norm - _target_needle_norm) > 0.002:
		_current_needle_norm = lerpf(_current_needle_norm, _target_needle_norm, clampf(dt * 18.0, 0.0, 1.0))
		_position_timing_needle(_current_needle_norm)


func _position_timing_needle(norm_offset: float) -> void:
	if _timing_needle == null:
		return
	var ratio: float = clampf(0.5 + norm_offset * 0.48, 0.02, 0.98)
	_timing_needle.anchor_left = ratio
	_timing_needle.anchor_right = ratio
	_timing_needle.offset_left = -2.0
	_timing_needle.offset_right = 2.0


# ==============================================================================
# Scene Tree Resolution / Programmatic Fallback Construction
# ==============================================================================

func _ensure_ui_ready() -> void:
	if _ui_ready:
		return
	_ui_ready = true

	_hud_root = get_node_or_null("HUDRoot") as Control
	if _hud_root == null:
		_build_fallback_scene_tree()
	else:
		_resolve_scene_nodes()
	UIThemeBuilder.apply_safe_area_margins(_hud_root, 0)

	_apply_panel_themes()
	_populate_selectors()
	_wire_ui_signals()
	select_combo_by_id(_current_tutorial_move, false)
	select_archetype_by_id(_current_archetype_id, false)
	select_dummy_mode_by_index(_current_dummy_mode_idx, false)
	_position_timing_needle(0.0)
	_render_mastery_display(0, 0, 0.0, 0, 0, 0, 0.0, "Novice")


func _resolve_scene_nodes() -> void:
	_combo_card = _hud_root.get_node_or_null("ComboTutorialCard") as PanelContainer
	_combo_selector = _hud_root.get_node_or_null("ComboTutorialCard/TutorialVBox/ComboSelector") as OptionButton
	_tutorial_move_label = _hud_root.get_node_or_null("ComboTutorialCard/TutorialVBox/TutorialMoveLabel") as Label
	_prompt_chips_row = _hud_root.get_node_or_null("ComboTutorialCard/TutorialVBox/PromptChipsRow") as HBoxContainer
	_tutorial_feedback_label = _hud_root.get_node_or_null("ComboTutorialCard/TutorialVBox/TutorialFeedbackLabel") as Label
	_challenge_button = _hud_root.get_node_or_null("ComboTutorialCard/TutorialVBox/ChallengeRow/ChallengeButton") as Button
	_challenge_timer_label = _hud_root.get_node_or_null("ComboTutorialCard/TutorialVBox/ChallengeRow/ChallengeTimerLabel") as Label
	_challenge_count_label = _hud_root.get_node_or_null("ComboTutorialCard/TutorialVBox/ChallengeRow/ChallengeCountLabel") as Label
	_challenge_grade_badge = _hud_root.get_node_or_null("ComboTutorialCard/TutorialVBox/ChallengeRow/ChallengeGradeBadge") as PanelContainer
	_challenge_grade_label = _hud_root.get_node_or_null("ComboTutorialCard/TutorialVBox/ChallengeRow/ChallengeGradeBadge/ChallengeGradeLabel") as Label

	_history_panel = _hud_root.get_node_or_null("InputHistoryPanel") as PanelContainer
	_history_list = _hud_root.get_node_or_null("InputHistoryPanel/HistoryVBox/InputHistoryScroll/InputHistoryList") as VBoxContainer

	_timing_panel = _hud_root.get_node_or_null("TimingAnalysisPanel") as PanelContainer
	_timing_track = _hud_root.get_node_or_null("TimingAnalysisPanel/TimingVBox/TimingBarTrack") as Control
	_timing_needle = _hud_root.get_node_or_null("TimingAnalysisPanel/TimingVBox/TimingBarTrack/TimingNeedle") as ColorRect
	_timing_readout_label = _hud_root.get_node_or_null("TimingAnalysisPanel/TimingVBox/TimingReadoutLabel") as Label

	_controls_panel = _hud_root.get_node_or_null("PracticeControlsPanel") as PanelContainer
	_archetype_selector = _hud_root.get_node_or_null("PracticeControlsPanel/ControlsVBox/ArchetypeSelector") as OptionButton
	_dummy_mode_selector = _hud_root.get_node_or_null("PracticeControlsPanel/ControlsVBox/DummyModeSelector") as OptionButton
	_shot_drill_button = _hud_root.get_node_or_null("PracticeControlsPanel/ControlsVBox/ShotDrillToggleButton") as Button
	_shot_drill_label = _hud_root.get_node_or_null("PracticeControlsPanel/ControlsVBox/ShotDrillReadoutLabel") as Label
	_reset_button = _hud_root.get_node_or_null("PracticeControlsPanel/ControlsVBox/ActionsRow/ResetPositionButton") as Button
	_return_menu_button = _hud_root.get_node_or_null("PracticeControlsPanel/ControlsVBox/ActionsRow/ReturnMenuButton") as Button

	_mastery_card = _hud_root.get_node_or_null("SkillMasteryCard") as PanelContainer
	_mastery_rank_badge = _hud_root.get_node_or_null("SkillMasteryCard/MasteryVBox/MasteryHeaderRow/MasteryRankBadge") as PanelContainer
	_mastery_rank_label = _hud_root.get_node_or_null("SkillMasteryCard/MasteryVBox/MasteryHeaderRow/MasteryRankBadge/MasteryRankLabel") as Label
	_mastery_stats_label = _hud_root.get_node_or_null("SkillMasteryCard/MasteryVBox/MasteryStatsLabel") as Label


func _build_fallback_scene_tree() -> void:
	# Mirrors training_hud.tscn so TrainingHUD.new() works cleanly even without loading .tscn
	_hud_root = Control.new()
	_hud_root.name = "HUDRoot"
	_hud_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hud_root)

	# 1. Top-Left: Combo Tutorial & Challenge Card
	_combo_card = PanelContainer.new()
	_combo_card.name = "ComboTutorialCard"
	_combo_card.offset_left = 18.0
	_combo_card.offset_top = 16.0
	_combo_card.offset_right = 426.0
	_combo_card.offset_bottom = 228.0
	_hud_root.add_child(_combo_card)

	var tut_vbox := VBoxContainer.new()
	tut_vbox.name = "TutorialVBox"
	tut_vbox.add_theme_constant_override("separation", 6)
	_combo_card.add_child(tut_vbox)

	var tut_hdr := Label.new()
	tut_hdr.name = "TutorialHeaderLabel"
	tut_hdr.text = "SKILL DOJO // COMBO TUTORIAL"
	tut_hdr.add_theme_font_size_override("font_size", 13)
	tut_hdr.add_theme_color_override("font_color", COL_BORDER_CYAN)
	tut_vbox.add_child(tut_hdr)

	_combo_selector = OptionButton.new()
	_combo_selector.name = "ComboSelector"
	tut_vbox.add_child(_combo_selector)

	_tutorial_move_label = Label.new()
	_tutorial_move_label.name = "TutorialMoveLabel"
	_tutorial_move_label.text = "PHANTOM DRIVE  •  UNIVERSAL"
	_tutorial_move_label.add_theme_font_size_override("font_size", 15)
	_tutorial_move_label.add_theme_color_override("font_color", COL_TEXT_PRIMARY)
	tut_vbox.add_child(_tutorial_move_label)

	_prompt_chips_row = HBoxContainer.new()
	_prompt_chips_row.name = "PromptChipsRow"
	_prompt_chips_row.add_theme_constant_override("separation", 6)
	tut_vbox.add_child(_prompt_chips_row)

	_tutorial_feedback_label = Label.new()
	_tutorial_feedback_label.name = "TutorialFeedbackLabel"
	_tutorial_feedback_label.text = "STEP 1 / 4 — FOLLOW PROMPT"
	_tutorial_feedback_label.add_theme_font_size_override("font_size", 12)
	_tutorial_feedback_label.add_theme_color_override("font_color", COL_BORDER_CYAN)
	tut_vbox.add_child(_tutorial_feedback_label)

	var ch_row := HBoxContainer.new()
	ch_row.name = "ChallengeRow"
	ch_row.add_theme_constant_override("separation", 8)
	tut_vbox.add_child(ch_row)

	_challenge_button = Button.new()
	_challenge_button.name = "ChallengeButton"
	_challenge_button.text = "Start 30s Challenge"
	ch_row.add_child(_challenge_button)

	_challenge_timer_label = Label.new()
	_challenge_timer_label.name = "ChallengeTimerLabel"
	_challenge_timer_label.text = "30.0s"
	ch_row.add_child(_challenge_timer_label)

	_challenge_count_label = Label.new()
	_challenge_count_label.name = "ChallengeCountLabel"
	_challenge_count_label.text = "0 / 3"
	ch_row.add_child(_challenge_count_label)

	_challenge_grade_badge = PanelContainer.new()
	_challenge_grade_badge.name = "ChallengeGradeBadge"
	ch_row.add_child(_challenge_grade_badge)

	_challenge_grade_label = Label.new()
	_challenge_grade_label.name = "ChallengeGradeLabel"
	_challenge_grade_label.text = "--"
	_challenge_grade_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_challenge_grade_badge.add_child(_challenge_grade_label)

	# 2. Left-Side: Input History Tape
	_history_panel = PanelContainer.new()
	_history_panel.name = "InputHistoryPanel"
	_history_panel.offset_left = 18.0
	_history_panel.offset_top = 240.0
	_history_panel.offset_right = 278.0
	_history_panel.offset_bottom = 698.0
	_hud_root.add_child(_history_panel)

	var hist_vbox := VBoxContainer.new()
	hist_vbox.name = "HistoryVBox"
	hist_vbox.add_theme_constant_override("separation", 4)
	_history_panel.add_child(hist_vbox)

	var hist_hdr := Label.new()
	hist_hdr.name = "HistoryHeaderLabel"
	hist_hdr.text = "INPUT HISTORY (16)"
	hist_hdr.add_theme_font_size_override("font_size", 12)
	hist_hdr.add_theme_color_override("font_color", COL_BORDER_CYAN)
	hist_vbox.add_child(hist_hdr)

	var scroll := ScrollContainer.new()
	scroll.name = "InputHistoryScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hist_vbox.add_child(scroll)

	_history_list = VBoxContainer.new()
	_history_list.name = "InputHistoryList"
	_history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_history_list)

	# 3. Bottom-Center: Timing Analysis Bar
	_timing_panel = PanelContainer.new()
	_timing_panel.name = "TimingAnalysisPanel"
	_timing_panel.anchor_left = 0.5
	_timing_panel.anchor_right = 0.5
	_timing_panel.anchor_top = 1.0
	_timing_panel.anchor_bottom = 1.0
	_timing_panel.offset_left = -215.0
	_timing_panel.offset_right = 215.0
	_timing_panel.offset_top = -126.0
	_timing_panel.offset_bottom = -16.0
	_hud_root.add_child(_timing_panel)

	var tim_vbox := VBoxContainer.new()
	tim_vbox.name = "TimingVBox"
	tim_vbox.add_theme_constant_override("separation", 5)
	_timing_panel.add_child(tim_vbox)

	var tim_hdr := Label.new()
	tim_hdr.name = "TimingHeaderLabel"
	tim_hdr.text = "TIMING ANALYSIS"
	tim_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tim_hdr.add_theme_font_size_override("font_size", 12)
	tim_hdr.add_theme_color_override("font_color", COL_BORDER_CYAN)
	tim_vbox.add_child(tim_hdr)

	_timing_track = Control.new()
	_timing_track.name = "TimingBarTrack"
	_timing_track.custom_minimum_size = Vector2(390.0, 22.0)
	_timing_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tim_vbox.add_child(_timing_track)

	_add_timing_band(_timing_track, "EarlyBand", 0.00, 0.24, Color(0.95, 0.58, 0.14, 0.80))
	_add_timing_band(_timing_track, "GoodLeftBand", 0.24, 0.41, Color(0.20, 0.68, 0.95, 0.85))
	_add_timing_band(_timing_track, "PerfectBand", 0.41, 0.59, Color(0.12, 0.92, 0.64, 0.95))
	_add_timing_band(_timing_track, "GoodRightBand", 0.59, 0.76, Color(0.20, 0.68, 0.95, 0.85))
	_add_timing_band(_timing_track, "LateBand", 0.76, 1.00, Color(0.92, 0.24, 0.42, 0.80))

	_timing_needle = ColorRect.new()
	_timing_needle.name = "TimingNeedle"
	_timing_needle.color = Color(1.0, 1.0, 1.0, 1.0)
	_timing_needle.anchor_top = 0.0
	_timing_needle.anchor_bottom = 1.0
	_timing_needle.offset_top = -3.0
	_timing_needle.offset_bottom = 3.0
	_timing_needle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timing_track.add_child(_timing_needle)

	_timing_readout_label = Label.new()
	_timing_readout_label.name = "TimingReadoutLabel"
	_timing_readout_label.text = _displayed_timing_text
	_timing_readout_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timing_readout_label.add_theme_font_size_override("font_size", 15)
	_timing_readout_label.add_theme_color_override("font_color", COL_TEXT_PRIMARY)
	tim_vbox.add_child(_timing_readout_label)

	# 4. Top-Right: Practice Controls & Shot Drill Panel
	_controls_panel = PanelContainer.new()
	_controls_panel.name = "PracticeControlsPanel"
	_controls_panel.anchor_left = 1.0
	_controls_panel.anchor_right = 1.0
	_controls_panel.offset_left = -336.0
	_controls_panel.offset_right = -18.0
	_controls_panel.offset_top = 16.0
	_controls_panel.offset_bottom = 296.0
	_hud_root.add_child(_controls_panel)

	var ctrl_vbox := VBoxContainer.new()
	ctrl_vbox.name = "ControlsVBox"
	ctrl_vbox.add_theme_constant_override("separation", 6)
	_controls_panel.add_child(ctrl_vbox)

	var ctrl_hdr := Label.new()
	ctrl_hdr.name = "ControlsHeaderLabel"
	ctrl_hdr.text = "PRACTICE CONTROLS"
	ctrl_hdr.add_theme_font_size_override("font_size", 13)
	ctrl_hdr.add_theme_color_override("font_color", COL_BORDER_CYAN)
	ctrl_vbox.add_child(ctrl_hdr)

	_archetype_selector = OptionButton.new()
	_archetype_selector.name = "ArchetypeSelector"
	ctrl_vbox.add_child(_archetype_selector)

	_dummy_mode_selector = OptionButton.new()
	_dummy_mode_selector.name = "DummyModeSelector"
	ctrl_vbox.add_child(_dummy_mode_selector)

	_shot_drill_button = Button.new()
	_shot_drill_button.name = "ShotDrillToggleButton"
	_shot_drill_button.text = "Start 5-Spot Shot Drill"
	ctrl_vbox.add_child(_shot_drill_button)

	_shot_drill_label = Label.new()
	_shot_drill_label.name = "ShotDrillReadoutLabel"
	_shot_drill_label.text = _displayed_shot_drill_text
	_shot_drill_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ctrl_vbox.add_child(_shot_drill_label)

	var act_row := HBoxContainer.new()
	act_row.name = "ActionsRow"
	act_row.add_theme_constant_override("separation", 8)
	ctrl_vbox.add_child(act_row)

	_reset_button = Button.new()
	_reset_button.name = "ResetPositionButton"
	_reset_button.text = "Reset Position"
	_reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	act_row.add_child(_reset_button)

	_return_menu_button = Button.new()
	_return_menu_button.name = "ReturnMenuButton"
	_return_menu_button.text = "Main Menu"
	_return_menu_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	act_row.add_child(_return_menu_button)

	# 5. Bottom-Right: Skill Mastery Card
	_mastery_card = PanelContainer.new()
	_mastery_card.name = "SkillMasteryCard"
	_mastery_card.anchor_left = 1.0
	_mastery_card.anchor_right = 1.0
	_mastery_card.anchor_top = 1.0
	_mastery_card.anchor_bottom = 1.0
	_mastery_card.offset_left = -336.0
	_mastery_card.offset_right = -18.0
	_mastery_card.offset_top = -196.0
	_mastery_card.offset_bottom = -16.0
	_hud_root.add_child(_mastery_card)

	var mast_vbox := VBoxContainer.new()
	mast_vbox.name = "MasteryVBox"
	mast_vbox.add_theme_constant_override("separation", 6)
	_mastery_card.add_child(mast_vbox)

	var mast_row := HBoxContainer.new()
	mast_row.name = "MasteryHeaderRow"
	mast_vbox.add_child(mast_row)

	var mast_hdr := Label.new()
	mast_hdr.name = "MasteryTitleLabel"
	mast_hdr.text = "SKILL MASTERY"
	mast_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mast_hdr.add_theme_font_size_override("font_size", 13)
	mast_hdr.add_theme_color_override("font_color", COL_BORDER_CYAN)
	mast_row.add_child(mast_hdr)

	_mastery_rank_badge = PanelContainer.new()
	_mastery_rank_badge.name = "MasteryRankBadge"
	mast_row.add_child(_mastery_rank_badge)

	_mastery_rank_label = Label.new()
	_mastery_rank_label.name = "MasteryRankLabel"
	_mastery_rank_label.text = "NOVICE"
	_mastery_rank_badge.add_child(_mastery_rank_label)

	_mastery_stats_label = Label.new()
	_mastery_stats_label.name = "MasteryStatsLabel"
	_mastery_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mast_vbox.add_child(_mastery_stats_label)


func _add_timing_band(parent: Control, band_name: String, left_a: float, right_a: float, col: Color) -> void:
	var rect := ColorRect.new()
	rect.name = band_name
	rect.anchor_left = left_a
	rect.anchor_right = right_a
	rect.anchor_top = 0.0
	rect.anchor_bottom = 1.0
	rect.color = col
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(rect)


func _apply_panel_themes() -> void:
	if _hud_root != null:
		_hud_root.theme = UIThemeBuilder.build_theme()
	for panel in [_combo_card, _history_panel, _timing_panel, _controls_panel, _mastery_card]:
		if panel == null:
			continue
		var st := StyleBoxFlat.new()
		st.bg_color = COL_BG_PANEL
		st.border_color = COL_BORDER_CYAN if (panel == _combo_card or panel == _timing_panel) else COL_BORDER_SLATE
		st.set_border_width_all(2)
		st.set_corner_radius_all(8)
		st.content_margin_left = 12.0
		st.content_margin_right = 12.0
		st.content_margin_top = 10.0
		st.content_margin_bottom = 10.0
		panel.add_theme_stylebox_override("panel", st)

	if _challenge_grade_badge != null:
		_challenge_grade_style = StyleBoxFlat.new()
		_challenge_grade_style.bg_color = COL_BG_SUBPANEL
		_challenge_grade_style.border_color = COL_BORDER_SLATE
		_challenge_grade_style.set_border_width_all(2)
		_challenge_grade_style.set_corner_radius_all(5)
		_challenge_grade_style.content_margin_left = 10.0
		_challenge_grade_style.content_margin_right = 10.0
		_challenge_grade_style.content_margin_top = 2.0
		_challenge_grade_style.content_margin_bottom = 2.0
		_challenge_grade_badge.add_theme_stylebox_override("panel", _challenge_grade_style)

	if _mastery_rank_badge != null:
		_mastery_rank_style = StyleBoxFlat.new()
		_mastery_rank_style.bg_color = COL_BG_SUBPANEL
		_mastery_rank_style.border_color = COL_BORDER_SLATE
		_mastery_rank_style.set_border_width_all(2)
		_mastery_rank_style.set_corner_radius_all(5)
		_mastery_rank_style.content_margin_left = 10.0
		_mastery_rank_style.content_margin_right = 10.0
		_mastery_rank_style.content_margin_top = 2.0
		_mastery_rank_style.content_margin_bottom = 2.0
		_mastery_rank_badge.add_theme_stylebox_override("panel", _mastery_rank_style)

	if _timing_readout_label != null:
		_timing_readout_label.text = _displayed_timing_text


func _populate_selectors() -> void:
	_suppress_ui_callbacks = true
	if _combo_selector != null:
		_combo_selector.clear()
		for i in range(TUTORIAL_CATALOG.size()):
			var item: Dictionary = TUTORIAL_CATALOG[i]
			var seq_str: String = " → ".join(item["sequence"])
			var label: String = "%s [%s] (%s)" % [item["name"], item["tag"], seq_str]
			_combo_selector.add_item(label, i)
			_combo_selector.set_item_metadata(i, item["id"])

	if _archetype_selector != null:
		_archetype_selector.clear()
		for i in range(ARCHETYPE_OPTIONS.size()):
			var arch: Dictionary = ARCHETYPE_OPTIONS[i]
			_archetype_selector.add_item(str(arch["label"]), i)
			_archetype_selector.set_item_metadata(i, arch["id"])

	if _dummy_mode_selector != null:
		_dummy_mode_selector.clear()
		for i in range(DUMMY_MODE_NAMES.size()):
			_dummy_mode_selector.add_item(DUMMY_MODE_NAMES[i], i)
	_suppress_ui_callbacks = false


func _wire_ui_signals() -> void:
	if _combo_selector != null and not _combo_selector.item_selected.is_connected(_on_combo_selected):
		_combo_selector.item_selected.connect(_on_combo_selected)
	if _challenge_button != null and not _challenge_button.pressed.is_connected(_on_challenge_button_pressed):
		_challenge_button.pressed.connect(_on_challenge_button_pressed)
	if _archetype_selector != null and not _archetype_selector.item_selected.is_connected(_on_archetype_selected):
		_archetype_selector.item_selected.connect(_on_archetype_selected)
	if _dummy_mode_selector != null and not _dummy_mode_selector.item_selected.is_connected(_on_dummy_mode_selected):
		_dummy_mode_selector.item_selected.connect(_on_dummy_mode_selected)
	if _shot_drill_button != null and not _shot_drill_button.pressed.is_connected(_on_shot_drill_pressed):
		_shot_drill_button.pressed.connect(_on_shot_drill_pressed)
	if _reset_button != null and not _reset_button.pressed.is_connected(_on_reset_position_pressed):
		_reset_button.pressed.connect(_on_reset_position_pressed)
	if _return_menu_button != null and not _return_menu_button.pressed.is_connected(_on_return_menu_pressed):
		_return_menu_button.pressed.connect(_on_return_menu_pressed)


# ==============================================================================
# Helpers & Autoload / Signal Plumbing
# ==============================================================================

func _find_tutorial_index(move_id: String) -> int:
	var target: String = move_id.strip_edges().to_lower()
	for i in range(TUTORIAL_CATALOG.size()):
		if str(TUTORIAL_CATALOG[i]["id"]) == target:
			return i
	return -1


func _find_archetype_index(arch_id: String) -> int:
	var target: String = arch_id.strip_edges().to_lower()
	for i in range(ARCHETYPE_OPTIONS.size()):
		if str(ARCHETYPE_OPTIONS[i]["id"]) == target:
			return i
	return -1


func _format_input_symbol(sym: String) -> String:
	match sym.strip_edges().to_upper():
		"W":
			return "↑ W"
		"S":
			return "↓ S"
		"A":
			return "← A"
		"D":
			return "→ D"
		"SHIFT":
			return "SHIFT"
		"SPACE":
			return "SPACE"
		_:
			return sym.strip_edges().to_upper()


func _color_for_timing_grade(grade_upper: String) -> Color:
	match grade_upper:
		"PERFECT":
			return COL_PERFECT
		"GOOD":
			return COL_GOOD
		"EARLY":
			return COL_EARLY
		"LATE":
			return COL_LATE
		_:
			return COL_TEXT_PRIMARY


func _color_for_challenge_grade(grade: String) -> Color:
	match grade.strip_edges().to_upper():
		"S":
			return COL_GOLD
		"A":
			return COL_BORDER_CYAN
		"B":
			return COL_PERFECT
		"C":
			return COL_EARLY
		"FAIL":
			return COL_LATE
		_:
			return COL_TEXT_MUTED


func _color_for_mastery_rank(rank: String) -> Color:
	match rank.strip_edges().to_lower():
		"phantom":
			return COL_GOLD
		"master":
			return COL_BORDER_CYAN
		"adept":
			return COL_PERFECT
		_:
			return COL_TEXT_MUTED


func _get_autoload(autoload_name: String) -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null(autoload_name)
	return null


func _connect_event_bus() -> void:
	var eb: Node = _get_autoload("EventBus")
	if eb == null:
		return
	if not eb.is_connected("input_recorded", _on_event_bus_input_recorded):
		eb.connect("input_recorded", _on_event_bus_input_recorded)
	if not eb.is_connected("combo_triggered", _on_event_bus_combo_triggered):
		eb.connect("combo_triggered", _on_event_bus_combo_triggered)
	if not eb.is_connected("shot_timing_feedback", _on_event_bus_shot_timing_feedback):
		eb.connect("shot_timing_feedback", _on_event_bus_shot_timing_feedback)


func _disconnect_event_bus() -> void:
	var eb: Node = _get_autoload("EventBus")
	if eb == null:
		return
	if eb.is_connected("input_recorded", _on_event_bus_input_recorded):
		eb.disconnect("input_recorded", _on_event_bus_input_recorded)
	if eb.is_connected("combo_triggered", _on_event_bus_combo_triggered):
		eb.disconnect("combo_triggered", _on_event_bus_combo_triggered)
	if eb.is_connected("shot_timing_feedback", _on_event_bus_shot_timing_feedback):
		eb.disconnect("shot_timing_feedback", _on_event_bus_shot_timing_feedback)


func _connect_controller_signal(sig_name: String, cb: Callable) -> void:
	if _controller != null and _controller.has_signal(sig_name):
		if not _controller.is_connected(sig_name, cb):
			_controller.connect(sig_name, cb)


func _disconnect_controller() -> void:
	if _controller == null or not is_instance_valid(_controller):
		_controller = null
		return
	var pairs: Array = [
		["tutorial_updated", _on_tutorial_updated],
		["input_history_updated", _on_input_history_updated],
		["timing_analyzed", _on_timing_analyzed],
		["shot_drill_updated", _on_shot_drill_updated],
		["challenge_updated", _on_challenge_updated],
		["dummy_mode_changed", _on_dummy_mode_changed],
		["mastery_updated", _on_mastery_updated],
	]
	for p in pairs:
		var sig_name: String = p[0]
		var cb: Callable = p[1]
		if _controller.has_signal(sig_name) and _controller.is_connected(sig_name, cb):
			_controller.disconnect(sig_name, cb)
	_controller = null
