class_name PracticeArenaController
extends Node3D
## Practice Arena / Skill Training Dojo Controller for PHANTOM COURT ONLINE (Phase 11).
## Mounts Arena, configures LocalPlayer (Team 0) + programmable DefensiveDummy (Team 1),
## wires ComboTrainer + MasteryTracker, runs continuous training (no match/shot-clock end),
## drives 5-Spot Shot Practice with auto_return_ball(), and dynamically binds TrainingHUD.

signal tutorial_updated(state: Dictionary)
signal input_history_updated(history: Array)
signal timing_analyzed(analysis: Dictionary)
signal shot_drill_updated(drill_state: Dictionary)
signal challenge_updated(challenge_state: Dictionary)
signal dummy_mode_changed(mode: int, mode_name: String)
signal mastery_updated(summary: Dictionary)

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"
const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
const TRAINING_HUD_SCENE_PATH := "res://scenes/ui/training_hud.tscn"

const TARGET_RIM_POS := Vector3(0.0, 3.05, -12.425) # HoopB (Team 0 attacks)
const DEFAULT_DRILL_PLAYER_POS := Vector3(0.0, 0.0, -5.0)
const AUTO_RETURN_DELAY_SEC: float = 0.55
const SHOT_MISS_TIMEOUT_SEC: float = 2.60

# 5 Regulation Shot Practice Spots attacking HoopB (z = -12.425)
const SHOT_SPOTS: Array[Dictionary] = [
	{"id": "left_corner_3",  "name": "Left Corner 3",  "pos": Vector3(-6.80, 0.0, -11.40), "is_three": true},
	{"id": "left_wing_3",    "name": "Left Wing 3",    "pos": Vector3(-5.20, 0.0, -7.20),  "is_three": true},
	{"id": "top_of_key_3",   "name": "Top of Key 3",   "pos": Vector3(0.0, 0.0, -5.00),    "is_three": true},
	{"id": "right_wing_mid", "name": "Right Wing Mid", "pos": Vector3(3.60, 0.0, -8.80),   "is_three": false},
	{"id": "right_corner_3", "name": "Right Corner 3", "pos": Vector3(6.80, 0.0, -11.40),  "is_three": true},
]

@export var default_archetype_id: String = ""
@export var auto_mount_hud: bool = true

var _arena: Node3D = null
var _match_controller: Node = null
var _basketball: Node3D = null
var _player: Node3D = null
var _dummy_player: Node3D = null
var _dummy: DefensiveDummy = null
var _combo_trainer: ComboTrainer = null
var _mastery_tracker: MasteryTracker = null
var _hud: Node = null
var _spot_marker: MeshInstance3D = null

var _event_bus_connected: bool = false

# 5-Spot Shot Practice state
var _shot_drill_active: bool = false
var _active_spot_index: int = 0
var _drill_attempts: int = 0
var _drill_makes: int = 0
var _drill_streak: int = 0
var _drill_best_streak: int = 0

# Live shot outcome tracking & auto ball return
var _awaiting_shot_outcome: bool = false
var _shot_elapsed: float = 0.0
var _last_shot_was_perfect: bool = false
var _last_shot_offset_ms: float = 0.0
var _return_ball_timer: float = -1.0


func _ready() -> void:
	add_to_group("practice_arena")
	add_to_group("full_hud") # Suppresses MatchController's minimal Phase 1 HUD overlay
	_setup_training_arena()


func _exit_tree() -> void:
	_disconnect_event_bus()


func _setup_training_arena() -> void:
	# 1. Instantiate Arena
	var arena_packed := load(ARENA_SCENE_PATH) as PackedScene
	if arena_packed != null:
		_arena = arena_packed.instantiate() as Node3D
		_arena.name = "Arena"
		add_child(_arena)
		_match_controller = _arena.get_node_or_null("MatchController")
		_basketball = _arena.get_node_or_null("Basketball") as Node3D
		_player = _arena.get_node_or_null("Players/LocalPlayer") as Node3D

	# Configure continuous training mode on MatchController
	_freeze_match_timers()
	if _match_controller != null:
		var ov: Variant = _match_controller.get("_overlay_layer")
		if ov is CanvasLayer:
			(ov as CanvasLayer).visible = false

	# 2. Configure LocalPlayer (Team 0) with selected archetype
	var arch_to_apply: String = default_archetype_id
	if arch_to_apply.is_empty():
		var gs: Node = _get_game_state()
		if gs != null and gs.get("selected_archetype") != null:
			arch_to_apply = str(gs.get("selected_archetype"))
	arch_to_apply = ArchetypeRegistry.resolve_id(arch_to_apply)

	if _player != null:
		_player.set("player_id", 1)
		_player.set("team_id", 0)
		_player.set("is_local_human", true)
		set_player_archetype(arch_to_apply)

	# 3. Spawn & wire DummyDefender (Team 1) + DefensiveDummy
	var player_packed := load(PLAYER_SCENE_PATH) as PackedScene
	if player_packed != null and _arena != null:
		_dummy_player = player_packed.instantiate() as Node3D
		_dummy_player.name = "DummyDefender"
		_dummy_player.set("player_id", 2)
		_dummy_player.set("team_id", 1)
		_dummy_player.set("is_local_human", false)
		var players_root: Node = _arena.get_node_or_null("Players")
		if players_root != null:
			players_root.add_child(_dummy_player)
		else:
			_arena.add_child(_dummy_player)
		if _dummy_player.has_method("apply_archetype"):
			_dummy_player.call("apply_archetype", ArchetypeRegistry.get_archetype_dict(ArchetypeRegistry.ID_ALL_ROUNDER))

		_dummy = DefensiveDummy.new()
		_dummy.name = "DefensiveDummy"
		_dummy_player.add_child(_dummy)
		_dummy.setup(_dummy_player, _player, DefensiveDummy.Mode.IDLE, 404, TARGET_RIM_POS)
		if _dummy_player.has_method("set_external_input_provider"):
			_dummy_player.call("set_external_input_provider", _dummy)

	# 4. Mount MasteryTracker & ComboTrainer
	_mastery_tracker = MasteryTracker.new()
	_mastery_tracker.load_from_disk()

	_combo_trainer = ComboTrainer.new()
	_combo_trainer.name = "ComboTrainer"
	add_child(_combo_trainer)
	_combo_trainer.setup(_player, _mastery_tracker)

	_combo_trainer.tutorial_updated.connect(_on_trainer_tutorial_updated)
	_combo_trainer.input_history_updated.connect(_on_trainer_input_history_updated)
	_combo_trainer.timing_analyzed.connect(_on_trainer_timing_analyzed)
	_combo_trainer.challenge_updated.connect(_on_trainer_challenge_updated)

	# 5. Visual 3D floor marker for 5-Spot Shot Practice
	_build_shot_spot_marker()

	# 6. Connect EventBus for shot make/miss tracking & auto ball return
	_connect_event_bus()

	# 7. Position player & dummy cleanly with basketball held
	reset_drill_positions()

	# 8. Dynamically mount & bind TrainingHUD if present (zero hard cross-owner dependency!)
	if auto_mount_hud and ResourceLoader.exists(TRAINING_HUD_SCENE_PATH):
		var hud_packed := load(TRAINING_HUD_SCENE_PATH) as PackedScene
		if hud_packed != null:
			_hud = hud_packed.instantiate()
			_hud.name = "TrainingHUD"
			add_child(_hud)
			if _hud.has_method("bind_practice_controller"):
				_hud.call("bind_practice_controller", self)

	# Emit initial state snapshots for bound UI listeners
	tutorial_updated.emit(_combo_trainer.get_tutorial_state())
	input_history_updated.emit(_combo_trainer.get_input_history(16))
	shot_drill_updated.emit(get_shot_drill_state())
	challenge_updated.emit(_combo_trainer.get_challenge_state())
	if _dummy != null:
		dummy_mode_changed.emit(_dummy.get_mode(), _dummy.get_mode_name())
	mastery_updated.emit(_mastery_tracker.get_overall_summary())


func _physics_process(delta: float) -> void:
	var dt: float = delta if (delta > 0.0 and delta <= 0.05) else (1.0 / 60.0)
	_freeze_match_timers()

	# Track active shot flight for miss detection & auto ball return
	if _awaiting_shot_outcome:
		_shot_elapsed += dt
		var b_state: int = int(_basketball.get("ball_state")) if (_basketball != null and _basketball.get("ball_state") != null) else 0
		var b_pos: Vector3 = _basketball.global_position if _basketball != null else Vector3.ZERO
		var missed_timeout: bool = _shot_elapsed >= SHOT_MISS_TIMEOUT_SEC
		var hit_floor_after_shot: bool = (_shot_elapsed >= 0.45) and (b_state == 0) and (b_pos.y <= 0.35)
		var dummy_grabbed: bool = (_basketball != null and _basketball.get("carrier") == _dummy_player)
		if missed_timeout or hit_floor_after_shot or dummy_grabbed:
			_finalize_shot_outcome(false)

	# Execute pending auto_return_ball() timer
	if _return_ball_timer >= 0.0:
		_return_ball_timer -= dt
		if _return_ball_timer <= 0.0:
			_return_ball_timer = -1.0
			auto_return_ball()


# ==============================================================================
# Public Practice Controls API (Bound by TrainingHUD & QA Tests)
# ==============================================================================

func select_tutorial(move_id: String) -> Dictionary:
	if _combo_trainer == null:
		return {}
	# Auto-switch archetype if tutorial is a class-unique skill so player can practice immediately
	var m: FrameData = _combo_trainer.move_db.get_move(move_id.strip_edges().to_lower())
	if m != null and not m.archetype_id.is_empty():
		var cur_arch: String = str(_player.get("archetype_id")) if (_player != null and _player.get("archetype_id") != null) else ""
		if cur_arch != m.archetype_id:
			set_player_archetype(m.archetype_id)
	return _combo_trainer.select_tutorial(move_id)


func start_challenge(
	move_id: String = "",
	target_count: int = 3,
	duration_sec: float = 30.0
) -> Dictionary:
	if _combo_trainer == null:
		return {}
	if not move_id.is_empty():
		select_tutorial(move_id)
	reset_drill_positions()
	return _combo_trainer.start_challenge(move_id, target_count, duration_sec)


func stop_challenge(finalize: bool = false) -> Dictionary:
	if _combo_trainer == null:
		return {}
	var res: Dictionary = _combo_trainer.stop_challenge(finalize)
	mastery_updated.emit(_mastery_tracker.get_overall_summary())
	return res


func set_dummy_mode(mode: int) -> void:
	if _dummy == null:
		return
	_dummy.set_mode(mode)
	_position_dummy_for_current_mode()
	dummy_mode_changed.emit(_dummy.get_mode(), _dummy.get_mode_name())


func set_player_archetype(arch_id: String) -> bool:
	var resolved: String = ArchetypeRegistry.resolve_id(arch_id)
	if not ArchetypeRegistry.has_archetype(resolved):
		return false
	if _player == null:
		return false
	var arch_dict: Dictionary = ArchetypeRegistry.get_archetype_dict(resolved)
	if _player.has_method("apply_archetype"):
		_player.call("apply_archetype", arch_dict)
	var gs: Node = _get_game_state()
	if gs != null:
		gs.set("selected_archetype", resolved)
	if _mastery_tracker != null:
		mastery_updated.emit(_mastery_tracker.get_overall_summary())
	return true


# ==============================================================================
# 5-Spot Shot Practice API
# ==============================================================================

func get_shot_spots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in SHOT_SPOTS:
		out.append(s.duplicate(true))
	return out


func start_shot_practice(spot_index: int = 0) -> Dictionary:
	_shot_drill_active = true
	_active_spot_index = posmod(spot_index, SHOT_SPOTS.size())
	_drill_attempts = 0
	_drill_makes = 0
	_drill_streak = 0
	_drill_best_streak = 0
	_awaiting_shot_outcome = false
	_return_ball_timer = -1.0

	_teleport_player_to_active_spot()
	var st: Dictionary = get_shot_drill_state()
	shot_drill_updated.emit(st)
	return st


func stop_shot_practice() -> Dictionary:
	_shot_drill_active = false
	_awaiting_shot_outcome = false
	_return_ball_timer = -1.0
	if _spot_marker != null:
		_spot_marker.visible = false
	var st: Dictionary = get_shot_drill_state()
	shot_drill_updated.emit(st)
	return st


func advance_shot_spot() -> Dictionary:
	if not _shot_drill_active:
		return start_shot_practice(0)
	_active_spot_index = (_active_spot_index + 1) % SHOT_SPOTS.size()
	_awaiting_shot_outcome = false
	_return_ball_timer = -1.0
	_teleport_player_to_active_spot()
	var st: Dictionary = get_shot_drill_state()
	shot_drill_updated.emit(st)
	return st


func get_shot_drill_state() -> Dictionary:
	var spot: Dictionary = SHOT_SPOTS[posmod(_active_spot_index, SHOT_SPOTS.size())]
	var make_pct: float = (float(_drill_makes) / float(_drill_attempts) * 100.0) if _drill_attempts > 0 else 0.0
	return {
		"active": _shot_drill_active,
		"spot_index": _active_spot_index,
		"spot_count": SHOT_SPOTS.size(),
		"spot_id": str(spot["id"]),
		"spot_name": str(spot["name"]),
		"spot_position": spot["pos"],
		"is_three_spot": bool(spot["is_three"]),
		"attempts": _drill_attempts,
		"makes": _drill_makes,
		"make_pct": make_pct,
		"streak": _drill_streak,
		"best_streak": _drill_best_streak,
	}


func auto_return_ball() -> void:
	_return_ball_timer = -1.0
	_awaiting_shot_outcome = false
	_shot_elapsed = 0.0
	if _player == null or _basketball == null:
		return

	if _shot_drill_active:
		_teleport_player_to_active_spot()
		return

	var pid: int = int(_player.get("player_id")) if _player.get("player_id") != null else 1
	var tid: int = int(_player.get("team_id")) if _player.get("team_id") != null else 0
	if _basketball.has_method("set_controlled_state"):
		_basketball.call("set_controlled_state", 1, _player, pid, tid, true) # HELD
	var stam: Variant = _player.get("stamina")
	if stam != null and stam is Object and stam.has_method("reset_stamina"):
		stam.call("reset_stamina")


func reset_drill_positions() -> void:
	_awaiting_shot_outcome = false
	_shot_elapsed = 0.0
	_return_ball_timer = -1.0

	var target_pos: Vector3 = DEFAULT_DRILL_PLAYER_POS
	if _shot_drill_active:
		target_pos = SHOT_SPOTS[posmod(_active_spot_index, SHOT_SPOTS.size())]["pos"]

	if _player != null:
		var xform: Transform3D = _facing_transform(target_pos, TARGET_RIM_POS)
		if _player.has_method("reset_for_match"):
			_player.call("reset_for_match", xform)
		else:
			_player.global_transform = xform
		var pid: int = int(_player.get("player_id")) if _player.get("player_id") != null else 1
		var tid: int = int(_player.get("team_id")) if _player.get("team_id") != null else 0
		if _basketball != null and _basketball.has_method("set_controlled_state"):
			_basketball.call("set_controlled_state", 1, _player, pid, tid, true) # HELD

	_position_dummy_for_current_mode()
	if _spot_marker != null:
		_spot_marker.visible = _shot_drill_active
		if _shot_drill_active:
			_spot_marker.global_position = Vector3(target_pos.x, 0.02, target_pos.z)


# ==============================================================================
# Inspection Getters & Snapshot
# ==============================================================================

func get_player() -> Node3D:
	return _player


func get_dummy_player() -> Node3D:
	return _dummy_player


func get_dummy() -> DefensiveDummy:
	return _dummy


func get_combo_trainer() -> ComboTrainer:
	return _combo_trainer


func get_mastery_tracker() -> MasteryTracker:
	return _mastery_tracker


func get_arena() -> Node3D:
	return _arena


func get_basketball() -> Node3D:
	return _basketball


func get_hud() -> Node:
	return _hud


func get_training_snapshot() -> Dictionary:
	return {
		"archetype_id": str(_player.get("archetype_id")) if (_player != null and _player.get("archetype_id") != null) else "",
		"dummy_mode": _dummy.get_mode() if _dummy != null else 0,
		"dummy_mode_name": _dummy.get_mode_name() if _dummy != null else "Idle",
		"tutorial": _combo_trainer.get_tutorial_state() if _combo_trainer != null else {},
		"input_history": _combo_trainer.get_input_history(16) if _combo_trainer != null else [],
		"last_timing_analysis": _combo_trainer.get_last_timing_analysis() if _combo_trainer != null else {},
		"challenge": _combo_trainer.get_challenge_state() if _combo_trainer != null else {},
		"shot_drill": get_shot_drill_state(),
		"mastery": _mastery_tracker.get_overall_summary() if _mastery_tracker != null else {},
	}


# ==============================================================================
# Internal Helpers & Signal Relays
# ==============================================================================

func _teleport_player_to_active_spot() -> void:
	var spot: Dictionary = SHOT_SPOTS[posmod(_active_spot_index, SHOT_SPOTS.size())]
	var spot_pos: Vector3 = spot["pos"]

	if _player != null:
		var xform: Transform3D = _facing_transform(spot_pos, TARGET_RIM_POS)
		if _player.has_method("reset_for_match"):
			_player.call("reset_for_match", xform)
		else:
			_player.global_transform = xform
		var pid: int = int(_player.get("player_id")) if _player.get("player_id") != null else 1
		var tid: int = int(_player.get("team_id")) if _player.get("team_id") != null else 0
		if _basketball != null and _basketball.has_method("set_controlled_state"):
			_basketball.call("set_controlled_state", 1, _player, pid, tid, true) # HELD

	if _spot_marker != null:
		_spot_marker.visible = true
		_spot_marker.global_position = Vector3(spot_pos.x, 0.02, spot_pos.z)

	_position_dummy_for_current_mode()


func _position_dummy_for_current_mode() -> void:
	if _dummy_player == null or _player == null:
		return
	var p_pos: Vector3 = _player.global_position
	var to_rim: Vector3 = _safe_norm_xz(TARGET_RIM_POS - p_pos)
	var dummy_pos: Vector3
	if _shot_drill_active and _dummy != null and _dummy.get_mode() == DefensiveDummy.Mode.IDLE:
		# Keep idle dummy safely out of shooter's shot-contest cone during open spot shooting drills
		dummy_pos = Vector3(0.0, 0.0, 2.5)
	else:
		dummy_pos = p_pos + to_rim * 2.0
		dummy_pos = Vector3(clampf(dummy_pos.x, -6.8, 6.8), 0.0, clampf(dummy_pos.z, -13.0, 13.0))

	var d_xform: Transform3D = _facing_transform(dummy_pos, p_pos)
	if _dummy_player.has_method("reset_for_match"):
		_dummy_player.call("reset_for_match", d_xform)
	else:
		_dummy_player.global_transform = d_xform
	if _dummy != null:
		_dummy.reset()


func _freeze_match_timers() -> void:
	var gs: Node = _get_game_state()
	if gs != null:
		gs.set("match_seconds_left", 180.0)
		gs.set("shot_clock_left", 24.0)
	if _match_controller != null:
		var sc: Variant = _match_controller.get("shot_clock")
		if sc != null and sc is Object:
			sc.set("paused", true)
			sc.set("time_left", 24.0)


func _build_shot_spot_marker() -> void:
	_spot_marker = MeshInstance3D.new()
	_spot_marker.name = "ShotSpotMarker"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.58
	torus.outer_radius = 0.72
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.0, 0.94, 1.0, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(0.0, 0.94, 1.0, 1.0)
	mat.emission_energy_multiplier = 2.2
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	torus.material = mat
	_spot_marker.mesh = torus
	_spot_marker.visible = false
	add_child(_spot_marker)


func _connect_event_bus() -> void:
	if _event_bus_connected:
		return
	var eb: Node = _get_event_bus()
	if eb == null:
		return
	if eb.has_signal("shot_released") and not eb.is_connected("shot_released", _on_eb_shot_released):
		eb.connect("shot_released", _on_eb_shot_released)
	if eb.has_signal("shot_timing_feedback") and not eb.is_connected("shot_timing_feedback", _on_eb_shot_timing_feedback):
		eb.connect("shot_timing_feedback", _on_eb_shot_timing_feedback)
	if eb.has_signal("score_changed") and not eb.is_connected("score_changed", _on_eb_score_changed):
		eb.connect("score_changed", _on_eb_score_changed)
	_event_bus_connected = true


func _disconnect_event_bus() -> void:
	if not _event_bus_connected:
		return
	var eb: Node = _get_event_bus()
	if eb != null:
		if eb.is_connected("shot_released", _on_eb_shot_released):
			eb.disconnect("shot_released", _on_eb_shot_released)
		if eb.is_connected("shot_timing_feedback", _on_eb_shot_timing_feedback):
			eb.disconnect("shot_timing_feedback", _on_eb_shot_timing_feedback)
		if eb.is_connected("score_changed", _on_eb_score_changed):
			eb.disconnect("score_changed", _on_eb_score_changed)
	_event_bus_connected = false


func _on_eb_shot_released(
	player_id: int,
	_release_pos: Vector3,
	_target_rim: Vector3,
	_is_three: bool,
	_timing_quality: float
) -> void:
	var my_pid: int = int(_player.get("player_id")) if (_player != null and _player.get("player_id") != null) else 1
	if player_id != my_pid:
		return
	_awaiting_shot_outcome = true
	_shot_elapsed = 0.0
	_return_ball_timer = -1.0


func _on_eb_shot_timing_feedback(player_id: int, label: String, timing_error: float) -> void:
	var my_pid: int = int(_player.get("player_id")) if (_player != null and _player.get("player_id") != null) else 1
	if player_id != my_pid:
		return
	_last_shot_was_perfect = (label == "Perfect")
	_last_shot_offset_ms = timing_error * 1000.0


func _on_eb_score_changed(
	_team_id: int,
	_new_score: int,
	delta: int,
	_is_three: bool,
	scorer_id: int
) -> void:
	if delta <= 0:
		return
	var my_pid: int = int(_player.get("player_id")) if (_player != null and _player.get("player_id") != null) else 1
	if scorer_id != my_pid:
		return
	if _awaiting_shot_outcome:
		_finalize_shot_outcome(true)


func _finalize_shot_outcome(made: bool) -> void:
	_awaiting_shot_outcome = false
	_shot_elapsed = 0.0

	var spot_id: String = "free_court"
	if _shot_drill_active:
		spot_id = str(SHOT_SPOTS[posmod(_active_spot_index, SHOT_SPOTS.size())]["id"])
		_drill_attempts += 1
		if made:
			_drill_makes += 1
			_drill_streak += 1
			_drill_best_streak = maxi(_drill_best_streak, _drill_streak)
		else:
			_drill_streak = 0

	var arch_id: String = str(_player.get("archetype_id")) if (_player != null and _player.get("archetype_id") != null) else ""
	if _mastery_tracker != null:
		_mastery_tracker.record_shot(spot_id, made, _last_shot_was_perfect, _last_shot_offset_ms, arch_id)
		mastery_updated.emit(_mastery_tracker.get_overall_summary())

	if _shot_drill_active:
		shot_drill_updated.emit(get_shot_drill_state())
		_return_ball_timer = AUTO_RETURN_DELAY_SEC


func _on_trainer_tutorial_updated(state: Dictionary) -> void:
	tutorial_updated.emit(state)


func _on_trainer_input_history_updated(history: Array) -> void:
	input_history_updated.emit(history)


func _on_trainer_timing_analyzed(analysis: Dictionary) -> void:
	timing_analyzed.emit(analysis)
	if _mastery_tracker != null:
		mastery_updated.emit(_mastery_tracker.get_overall_summary())


func _on_trainer_challenge_updated(challenge_state: Dictionary) -> void:
	challenge_updated.emit(challenge_state)
	if bool(challenge_state.get("finished", false)) and _mastery_tracker != null:
		mastery_updated.emit(_mastery_tracker.get_overall_summary())


static func _facing_transform(pos: Vector3, look_target: Vector3) -> Transform3D:
	var dx: float = look_target.x - pos.x
	var dz: float = look_target.z - pos.z
	var yaw: float = atan2(-dx, -dz) if (dx * dx + dz * dz) > 1e-6 else 0.0
	return Transform3D(Basis(Vector3.UP, yaw), pos)


static func _safe_norm_xz(v: Vector3) -> Vector3:
	var flat := Vector3(v.x, 0.0, v.z)
	if flat.length_squared() > 1e-8:
		return flat.normalized()
	return Vector3(0.0, 0.0, -1.0)


func _get_event_bus() -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null("EventBus")
	return null


func _get_game_state() -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null("GameState")
	return null
