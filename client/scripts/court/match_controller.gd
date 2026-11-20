class_name MatchController
extends Node
## Authoritative local Match Rules, 2pt/3pt Classifier, Timers, Restart Manager,
## and Phase 1 Playable Scoreboard Overlay for Phantom Court Online.

const DEFAULT_MATCH_DURATION: float = 180.0
const DEFAULT_SHOT_CLOCK: float = 24.0
const THREE_POINT_ARC_RADIUS: float = 6.75
const THREE_POINT_CORNER_X: float = 6.60

@export var match_duration_seconds: float = DEFAULT_MATCH_DURATION
@export var shot_clock_seconds: float = DEFAULT_SHOT_CLOCK
@export var auto_start_on_ready: bool = true
@export var ball_spawn_position: Vector3 = Vector3(1.6, 1.15, -4.8)
@export var record_career_on_finish: bool = true

var match_stats: Dictionary = {
	"two_pointers": [0, 0],
	"three_pointers": [0, 0],
	"turnovers": [0, 0],
}

var _player_spawns: Dictionary = {} # instance_id -> Transform3D
var _last_possession_team: int = 0
var _banner_timer: float = 0.0
var _player_box_stats: Dictionary = {} # player_id: int -> Dictionary
var _rebound_baseline_by_pid: Dictionary = {} # player_id: int -> int
var _scoring_via_hoop: bool = false
var _absorb_duplicate_ui_restart_frame: int = -1
var _last_career_rating_update: Dictionary = {}

# Phase 1 HUD Overlay references
var _overlay_layer: CanvasLayer = null
var _score_label_t0: Label = null
var _score_label_t1: Label = null
var _clock_label: Label = null
var _shot_clock_label: Label = null
var _possession_label: Label = null
var _banner_label: Label = null
var _stamina_bar: ProgressBar = null
var _zone_bar: ProgressBar = null
var _zone_status_label: Label = null
var _last_passer_by_team: Dictionary = {} # team_id -> {passer_id, time}

@onready var shot_clock: ShotClock = get_node_or_null("ShotClock") as ShotClock


static func is_three_point_shot(shot_pos: Vector3, rim_pos: Vector3) -> bool:
	var dist_xz: float = Vector2(shot_pos.x, shot_pos.z).distance_to(Vector2(rim_pos.x, rim_pos.z))
	return (dist_xz > THREE_POINT_ARC_RADIUS) or (absf(shot_pos.x) > THREE_POINT_CORNER_X)


static func get_shot_point_value(shot_pos: Vector3, rim_pos: Vector3) -> int:
	return 3 if is_three_point_shot(shot_pos, rim_pos) else 2


func classify_shot(shot_pos: Vector3, rim_pos: Vector3) -> Dictionary:
	var dist_xz: float = Vector2(shot_pos.x, shot_pos.z).distance_to(Vector2(rim_pos.x, rim_pos.z))
	var is_three: bool = (dist_xz > THREE_POINT_ARC_RADIUS) or (absf(shot_pos.x) > THREE_POINT_CORNER_X)
	return {
		"points": 3 if is_three else 2,
		"is_three": is_three,
		"dist_xz": dist_xz,
	}


func _ready() -> void:
	add_to_group("match_controller")
	if shot_clock == null:
		shot_clock = ShotClock.new()
		shot_clock.name = "ShotClock"
		add_child(shot_clock)
	shot_clock.max_seconds = shot_clock_seconds
	if not shot_clock.shot_clock_expired.is_connected(_on_shot_clock_expired):
		shot_clock.shot_clock_expired.connect(_on_shot_clock_expired)

	_connect_event_bus()
	_build_phase1_overlay()
	if _overlay_layer != null and get_tree() != null and not get_tree().get_nodes_in_group("full_hud").is_empty():
		_overlay_layer.visible = false

	# Defer initial registration by 0 frames or run immediately on ready siblings
	_register_scene_entities()
	if auto_start_on_ready:
		start_match()


func _exit_tree() -> void:
	_disconnect_event_bus()


func _connect_event_bus() -> void:
	if not EventBus.possession_changed.is_connected(_on_possession_changed):
		EventBus.possession_changed.connect(_on_possession_changed)
	if not EventBus.ball_bounced.is_connected(_on_ball_bounced):
		EventBus.ball_bounced.connect(_on_ball_bounced)
	if not EventBus.score_changed.is_connected(_on_score_changed_ui):
		EventBus.score_changed.connect(_on_score_changed_ui)
	if not EventBus.shot_timing_feedback.is_connected(_on_shot_feedback_ui):
		EventBus.shot_timing_feedback.connect(_on_shot_feedback_ui)
	if not EventBus.stamina_updated.is_connected(_on_stamina_updated_ui):
		EventBus.stamina_updated.connect(_on_stamina_updated_ui)
	if not EventBus.zone_meter_updated.is_connected(_on_zone_updated_ui):
		EventBus.zone_meter_updated.connect(_on_zone_updated_ui)
	if not EventBus.zone_activated.is_connected(_on_zone_activated_ui):
		EventBus.zone_activated.connect(_on_zone_activated_ui)
	if not EventBus.zone_ended.is_connected(_on_zone_ended_ui):
		EventBus.zone_ended.connect(_on_zone_ended_ui)
	if not EventBus.combo_triggered.is_connected(_on_combo_triggered_stats):
		EventBus.combo_triggered.connect(_on_combo_triggered_stats)
	if not EventBus.block_performed.is_connected(_on_block_performed_stats):
		EventBus.block_performed.connect(_on_block_performed_stats)
	if not EventBus.steal_performed.is_connected(_on_steal_performed_stats):
		EventBus.steal_performed.connect(_on_steal_performed_stats)


func _disconnect_event_bus() -> void:
	if EventBus == null:
		return
	if EventBus.possession_changed.is_connected(_on_possession_changed):
		EventBus.possession_changed.disconnect(_on_possession_changed)
	if EventBus.ball_bounced.is_connected(_on_ball_bounced):
		EventBus.ball_bounced.disconnect(_on_ball_bounced)
	if EventBus.score_changed.is_connected(_on_score_changed_ui):
		EventBus.score_changed.disconnect(_on_score_changed_ui)
	if EventBus.shot_timing_feedback.is_connected(_on_shot_feedback_ui):
		EventBus.shot_timing_feedback.disconnect(_on_shot_feedback_ui)
	if EventBus.stamina_updated.is_connected(_on_stamina_updated_ui):
		EventBus.stamina_updated.disconnect(_on_stamina_updated_ui)
	if EventBus.zone_meter_updated.is_connected(_on_zone_updated_ui):
		EventBus.zone_meter_updated.disconnect(_on_zone_updated_ui)
	if EventBus.zone_activated.is_connected(_on_zone_activated_ui):
		EventBus.zone_activated.disconnect(_on_zone_activated_ui)
	if EventBus.zone_ended.is_connected(_on_zone_ended_ui):
		EventBus.zone_ended.disconnect(_on_zone_ended_ui)
	if EventBus.combo_triggered.is_connected(_on_combo_triggered_stats):
		EventBus.combo_triggered.disconnect(_on_combo_triggered_stats)
	if EventBus.block_performed.is_connected(_on_block_performed_stats):
		EventBus.block_performed.disconnect(_on_block_performed_stats)
	if EventBus.steal_performed.is_connected(_on_steal_performed_stats):
		EventBus.steal_performed.disconnect(_on_steal_performed_stats)


func _register_scene_entities() -> void:
	var tree := get_tree()
	if tree == null:
		return

	for node in tree.get_nodes_in_group("hoops"):
		if node is HoopController:
			var hc := node as HoopController
			if not hc.basket_scored.is_connected(_on_hoop_basket_scored):
				hc.basket_scored.connect(_on_hoop_basket_scored)

	for p_node in tree.get_nodes_in_group("players"):
		if p_node is Node3D:
			var pid: int = p_node.get_instance_id()
			if not _player_spawns.has(pid):
				_player_spawns[pid] = (p_node as Node3D).global_transform


func sync_roster_spawns(spawn_map: Dictionary) -> void:
	_player_spawns.clear()
	for k in spawn_map.keys():
		_player_spawns[int(k)] = spawn_map[k]


func spawn_ai_match_roster(
	mode: String = "1v1",
	difficulty_tier: int = AIDifficulty.Tier.PRO,
	base_seed: int = 1337,
	local_human_on_team0: bool = true
) -> Array[PlayerController]:
	var arena := get_parent() as ArenaBuilder
	if arena != null:
		return arena.spawn_ai_match_roster(mode, difficulty_tier, base_seed, local_human_on_team0)
	return []


func set_ai_difficulty_all(difficulty_tier: int) -> void:
	var arena := get_parent() as ArenaBuilder
	if arena != null:
		arena.set_ai_difficulty_all(difficulty_tier)


func get_ai_controllers() -> Array[AIController]:
	var arena := get_parent() as ArenaBuilder
	if arena != null:
		return arena.get_ai_controllers()
	return []


func start_match() -> void:
	_register_scene_entities()
	match_stats = {
		"two_pointers": [0, 0],
		"three_pointers": [0, 0],
		"turnovers": [0, 0],
	}
	_reset_box_score_stats()
	GameState.reset_match_state(match_duration_seconds, shot_clock_seconds)
	_last_possession_team = GameState.possession_team
	if shot_clock != null:
		shot_clock.max_seconds = shot_clock_seconds
		shot_clock.reset_clock(shot_clock_seconds)

	GameState.update_timers(match_duration_seconds, shot_clock_seconds)
	EventBus.match_started.emit({
		"mode": GameState.match_mode,
		"duration": match_duration_seconds,
		"shot_clock": shot_clock_seconds,
	})
	_refresh_overlay_labels()


func restart_match_from_ui_signal() -> void:
	_absorb_duplicate_ui_restart_frame = -1
	restart_match()
	_absorb_duplicate_ui_restart_frame = Engine.get_process_frames()
	call_deferred("_clear_duplicate_ui_restart_guard")


func _clear_duplicate_ui_restart_guard() -> void:
	_absorb_duplicate_ui_restart_frame = -1


func restart_match() -> void:
	if _absorb_duplicate_ui_restart_frame == Engine.get_process_frames():
		_absorb_duplicate_ui_restart_frame = -1
		return
	_register_scene_entities()
	var tree := get_tree()
	if tree != null:
		for node in tree.get_nodes_in_group("hoops"):
			if node is HoopController:
				(node as HoopController).reset_hoop_state()

		for p_node in tree.get_nodes_in_group("players"):
			if p_node is PlayerController:
				var pc := p_node as PlayerController
				var xform: Transform3D = _player_spawns.get(pc.get_instance_id(), pc.global_transform)
				pc.reset_for_match(xform)
				var ai_ctrl: Node = pc.get_node_or_null("AIController")
				if ai_ctrl != null and ai_ctrl.has_method("reset"):
					ai_ctrl.call("reset")

		for b_node in tree.get_nodes_in_group("basketball"):
			if b_node is Basketball:
				(b_node as Basketball).reset_to_free(ball_spawn_position)

	match_stats = {
		"two_pointers": [0, 0],
		"three_pointers": [0, 0],
		"turnovers": [0, 0],
	}
	_last_passer_by_team.clear()
	_reset_box_score_stats()
	GameState.reset_match_state(match_duration_seconds, shot_clock_seconds)
	_last_possession_team = 0
	if shot_clock != null:
		shot_clock.max_seconds = shot_clock_seconds
		shot_clock.reset_clock(shot_clock_seconds)

	GameState.set_team_score(0, 0, 0, false, -1)
	GameState.set_team_score(1, 0, 0, false, -1)
	GameState.set_possession(0, -1)
	GameState.update_timers(match_duration_seconds, shot_clock_seconds)

	_show_banner("MATCH RESTARTED", Color(0.35, 0.92, 1.0, 1.0), 1.4)
	EventBus.match_restarted.emit()
	EventBus.match_started.emit({
		"mode": GameState.match_mode,
		"duration": match_duration_seconds,
		"shot_clock": shot_clock_seconds,
	})
	_refresh_overlay_labels()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo and ke.keycode == KEY_F5:
			restart_match()


func _physics_process(delta: float) -> void:
	var dt: float = 1.0 / 60.0
	if delta > 0.0 and delta <= 0.05:
		dt = delta

	# Auto-connect any dynamically spawned hoops/players
	_register_scene_entities()

	# Hide Phase 1 minimal HUD automatically if full Phase 3 HUD is mounted
	if _overlay_layer != null:
		var tree := get_tree()
		if tree != null and not tree.get_nodes_in_group("full_hud").is_empty():
			_overlay_layer.visible = false

	if _banner_timer > 0.0:
		_banner_timer = maxf(0.0, _banner_timer - dt)
		if _banner_timer <= 0.0 and _banner_label != null:
			_banner_label.visible = false

	if GameState.match_phase != GameState.MatchPhase.LIVE:
		return

	GameState.current_tick += 1

	# Pause shot clock while a valid shot is mid-flight toward the basket
	var bball: Basketball = _get_primary_ball()
	if shot_clock != null:
		shot_clock.paused = (bball != null and bball.ball_state == Basketball.BallState.SHOT_FLIGHT)
		shot_clock.step_clock(dt, GameState.possession_team)

	var new_match_left: float = maxf(0.0, GameState.match_seconds_left - dt)
	var sc_left: float = shot_clock.time_left if shot_clock != null else GameState.shot_clock_left
	GameState.update_timers(new_match_left, sc_left)
	_refresh_overlay_labels()

	if new_match_left <= 0.0:
		_finish_match()


func end_match() -> void:
	_finish_match()


func get_last_career_rating_update() -> Dictionary:
	return _last_career_rating_update.duplicate(true)


func _finish_match() -> void:
	GameState.match_phase = GameState.MatchPhase.POST_MATCH
	var s0: int = GameState.scores[0]
	var s1: int = GameState.scores[1]
	var winner: int = -1
	if s0 > s1:
		winner = 0
	elif s1 > s0:
		winner = 1

	var win_text: String = "DRAW GAME!"
	if winner == 0:
		win_text = "PHANTOM TEAM WINS! (%d - %d)" % [s0, s1]
	elif winner == 1:
		win_text = "RIVAL TEAM WINS! (%d - %d)" % [s1, s0]
	_show_banner(win_text, Color(1.0, 0.85, 0.20, 1.0), 6.0)

	var end_stats: Dictionary = build_match_end_summary()

	# Record Offline Match to Local Glicko-2 Career (`LocalCareer` autoload) when active
	var is_online_match: bool = GameState != null and bool(GameState.get("is_online"))
	var is_spectating: bool = GameState != null and bool(GameState.get("is_spectator"))
	if record_career_on_finish and not is_online_match and not is_spectating:
		var local_career: Node = (
			get_tree().root.get_node_or_null("LocalCareer")
			if (get_tree() != null and get_tree().root != null)
			else null
		)
		if local_career != null and local_career.has_method("record_offline_match"):
			var mode_str: String = "3v3"
			var diff_tier: int = 1
			var local_pid: int = 1
			if GameState != null:
				local_pid = int(GameState.local_player_id)
				if GameState.get("selected_mode") != null and not str(GameState.get("selected_mode")).strip_edges().is_empty():
					mode_str = str(GameState.get("selected_mode")).strip_edges()
				elif GameState.get("match_mode") != null and not str(GameState.get("match_mode")).strip_edges().is_empty():
					mode_str = str(GameState.get("match_mode")).strip_edges().trim_prefix("offline_")
				if GameState.get("selected_difficulty") != null:
					diff_tier = clampi(int(GameState.get("selected_difficulty")), 0, 3)

			var local_box: Dictionary = get_player_box_score(local_pid)
			var elapsed_sec: int = maxi(1, int(roundf(match_duration_seconds - GameState.match_seconds_left)))
			var raw_update: Variant = local_career.call(
				"record_offline_match",
				mode_str,
				diff_tier,
				s0,
				s1,
				local_box,
				elapsed_sec
			)
			if raw_update is Dictionary and not (raw_update as Dictionary).is_empty():
				var rating_upd: Dictionary = (raw_update as Dictionary).duplicate(true)
				if not rating_upd.has("delta") and rating_upd.has("rating_delta"):
					rating_upd["delta"] = float(rating_upd["rating_delta"])
				_last_career_rating_update = rating_upd.duplicate(true)
				end_stats["rating_update"] = rating_upd.duplicate(true)
				end_stats["ranked_update"] = rating_upd.duplicate(true)

	EventBus.match_ended.emit(winner, GameState.scores.duplicate(), end_stats)


func _on_hoop_basket_scored(
	hoop: Node3D,
	scoring_team: int,
	_ball: Node3D,
	points: int,
	is_three: bool,
	scorer_id: int
) -> void:
	if GameState.match_phase != GameState.MatchPhase.LIVE:
		return

	if scoring_team >= 0 and scoring_team <= 1:
		if is_three:
			match_stats["three_pointers"][scoring_team] += 1
		else:
			match_stats["two_pointers"][scoring_team] += 1

	if scorer_id >= 0:
		_record_player_points(scorer_id, points, is_three, scoring_team)

	# Reward scorer's Zone meter (+24.0 for 3pt, +18.0 for 2pt; strictly 0 if already in Zone)
	var tree := get_tree()
	if tree != null and scorer_id >= 0:
		for p_node in tree.get_nodes_in_group("players"):
			if p_node is PlayerController and (p_node as PlayerController).player_id == scorer_id:
				var pc := p_node as PlayerController
				if pc.zone != null:
					pc.zone.award_positive_play("basket_3pt" if is_three else "basket_2pt")
				break
		# Credit recent teammate passer with +15.0 Assist Zone energy & Box Score Assist
		if _last_passer_by_team.has(scoring_team):
			var p_info: Dictionary = _last_passer_by_team[scoring_team]
			var assist_pid: int = int(p_info.get("passer_id", -1))
			if assist_pid >= 0 and assist_pid != scorer_id:
				var a_entry: Dictionary = _ensure_player_box_entry(assist_pid)
				a_entry["assists"] = int(a_entry.get("assists", 0)) + 1
				for p_node in tree.get_nodes_in_group("players"):
					if p_node is PlayerController and (p_node as PlayerController).player_id == assist_pid:
						var apc := p_node as PlayerController
						if apc.zone != null:
							apc.zone.award_positive_play("assist")
						break
			_last_passer_by_team.erase(scoring_team)

	_scoring_via_hoop = true
	GameState.add_team_score(scoring_team, points, is_three, scorer_id)
	_scoring_via_hoop = false
	var next_poss_team: int = 1 - scoring_team
	_last_possession_team = next_poss_team
	GameState.set_possession(next_poss_team, -1)
	if shot_clock != null:
		shot_clock.reset_clock(shot_clock_seconds)
	GameState.update_timers(GameState.match_seconds_left, shot_clock_seconds)

	var tag: String = "SPLASH +3!" if is_three else "BUCKET +2!"
	var col: Color = Color(0.25, 0.95, 1.0, 1.0) if scoring_team == 0 else Color(1.0, 0.45, 0.45, 1.0)
	_show_banner("%s (%s)" % [tag, hoop.name], col, 1.8)


func _on_shot_clock_expired(offending_team: int) -> void:
	if GameState.match_phase != GameState.MatchPhase.LIVE:
		return
	if offending_team >= 0 and offending_team <= 1:
		match_stats["turnovers"][offending_team] += 1

	var bball: Basketball = _get_primary_ball()
	if bball != null and bball.carrier != null:
		bball.drop_free(bball.global_position + Vector3(0.0, 0.15, 0.0), Vector3(0.0, 1.5, 0.0), bball.carrier)

	var new_team: int = 1 - clampi(offending_team, 0, 1)
	_last_possession_team = new_team
	GameState.set_possession(new_team, -1)
	if shot_clock != null:
		shot_clock.reset_clock(shot_clock_seconds)
	GameState.update_timers(GameState.match_seconds_left, shot_clock_seconds)
	_show_banner("24s SHOT CLOCK VIOLATION!", Color(1.0, 0.35, 0.25, 1.0), 1.6)


func _on_possession_changed(team_id: int, carrier_id: int) -> void:
	if team_id != _last_possession_team and team_id >= 0:
		_last_possession_team = team_id
		_last_passer_by_team.clear()
		if shot_clock != null:
			shot_clock.reset_clock(shot_clock_seconds)
	elif team_id >= 0 and carrier_id >= 0:
		var bball: Basketball = _get_primary_ball()
		if bball != null and bball.last_passer_node is PlayerController:
			var passer := bball.last_passer_node as PlayerController
			if passer.team_id == team_id and passer.player_id != carrier_id:
				_last_passer_by_team[team_id] = {"passer_id": passer.player_id}
	_refresh_overlay_labels()


func _on_ball_bounced(_world_pos: Vector3, _impact_speed: float, surface_type: String) -> void:
	if surface_type == "rim" and shot_clock != null:
		shot_clock.reset_offensive_rebound()


func _get_primary_ball() -> Basketball:
	var tree := get_tree()
	if tree == null:
		return null
	for node in tree.get_nodes_in_group("basketball"):
		if node is Basketball:
			return node as Basketball
	return null


# ==============================================================================
# Minimal Phase 1 Playable HUD Scoreboard Overlay
# ==============================================================================

func set_phase1_overlay_visible(vis: bool) -> void:
	if _overlay_layer != null:
		_overlay_layer.visible = vis


func _build_phase1_overlay() -> void:
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "Phase1ScoreboardOverlay"
	_overlay_layer.layer = 5
	add_child(_overlay_layer)

	var root_ctrl := Control.new()
	root_ctrl.name = "OverlayRoot"
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_layer.add_child(root_ctrl)

	# Top Scoreboard Panel
	var top_bar := PanelContainer.new()
	top_bar.name = "ScoreboardPanel"
	top_bar.anchor_left = 0.5
	top_bar.anchor_right = 0.5
	top_bar.offset_left = -310.0
	top_bar.offset_right = 310.0
	top_bar.offset_top = 12.0
	top_bar.offset_bottom = 68.0

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.05, 0.08, 0.16, 0.88)
	panel_style.border_color = Color(0.22, 0.78, 1.0, 0.85)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 16.0
	panel_style.content_margin_right = 16.0
	panel_style.content_margin_top = 6.0
	panel_style.content_margin_bottom = 6.0
	top_bar.add_theme_stylebox_override("panel", panel_style)
	root_ctrl.add_child(top_bar)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 18)
	top_bar.add_child(hbox)

	_score_label_t0 = _create_hud_label("PHANTOM  00", 20, Color(0.35, 0.88, 1.0, 1.0))
	_clock_label = _create_hud_label("03:00", 22, Color(1.0, 1.0, 1.0, 1.0))
	_shot_clock_label = _create_hud_label("24.0", 20, Color(1.0, 0.82, 0.22, 1.0))
	_score_label_t1 = _create_hud_label("00  RIVAL", 20, Color(1.0, 0.42, 0.48, 1.0))
	_possession_label = _create_hud_label("POSS: TEAM 0", 13, Color(0.75, 0.85, 0.96, 1.0))

	hbox.add_child(_score_label_t0)
	hbox.add_child(_clock_label)
	hbox.add_child(_shot_clock_label)
	hbox.add_child(_score_label_t1)
	hbox.add_child(_possession_label)

	# Restart Button (Top Right)
	var restart_btn := Button.new()
	restart_btn.name = "RestartMatchButton"
	restart_btn.text = "Restart (F5)"
	restart_btn.anchor_left = 1.0
	restart_btn.anchor_right = 1.0
	restart_btn.offset_left = -138.0
	restart_btn.offset_right = -16.0
	restart_btn.offset_top = 16.0
	restart_btn.offset_bottom = 50.0
	restart_btn.focus_mode = Control.FOCUS_NONE
	restart_btn.pressed.connect(restart_match)
	root_ctrl.add_child(restart_btn)

	# Center Feedback Banner
	_banner_label = _create_hud_label("", 26, Color(0.30, 0.95, 1.0, 1.0))
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_label.anchor_left = 0.5
	_banner_label.anchor_right = 0.5
	_banner_label.offset_left = -280.0
	_banner_label.offset_right = 280.0
	_banner_label.offset_top = 82.0
	_banner_label.offset_bottom = 122.0
	_banner_label.visible = false
	root_ctrl.add_child(_banner_label)

	# Bottom-left Stamina & Zone meters
	var meters_vbox := VBoxContainer.new()
	meters_vbox.anchor_top = 1.0
	meters_vbox.anchor_bottom = 1.0
	meters_vbox.offset_left = 18.0
	meters_vbox.offset_right = 240.0
	meters_vbox.offset_top = -78.0
	meters_vbox.offset_bottom = -18.0
	root_ctrl.add_child(meters_vbox)

	_stamina_bar = ProgressBar.new()
	_stamina_bar.max_value = 100.0
	_stamina_bar.value = 100.0
	_stamina_bar.show_percentage = false
	_stamina_bar.custom_minimum_size = Vector2(210.0, 16.0)
	meters_vbox.add_child(_stamina_bar)

	_zone_bar = ProgressBar.new()
	_zone_bar.name = "ZoneProgressBar"
	_zone_bar.max_value = 100.0
	_zone_bar.value = 0.0
	_zone_bar.show_percentage = false
	_zone_bar.custom_minimum_size = Vector2(210.0, 14.0)
	meters_vbox.add_child(_zone_bar)

	_zone_status_label = _create_hud_label("ZONE: 0% (Press V at 100%)", 13, Color(0.45, 0.90, 1.0, 0.92))
	_zone_status_label.name = "ZoneStatusLabel"
	meters_vbox.add_child(_zone_status_label)

	# Bottom Controls Hint
	var hint := _create_hud_label(
		"WASD: Move | Shift: Sprint | Space: Jump | LMB/J: Shoot/Dunk | RMB/K: Pass | F/E: Pickup/Steal | Q: Crossover | F5: Restart",
		13,
		Color(0.82, 0.90, 1.0, 0.85)
	)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.anchor_top = 1.0
	hint.anchor_bottom = 1.0
	hint.anchor_left = 0.5
	hint.anchor_right = 0.5
	hint.offset_left = -460.0
	hint.offset_right = 460.0
	hint.offset_top = -28.0
	hint.offset_bottom = -6.0
	root_ctrl.add_child(hint)


func _create_hud_label(txt: String, font_sz: int, col: Color) -> Label:
	var lbl := Label.new()
	lbl.text = txt
	lbl.add_theme_font_size_override("font_size", font_sz)
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	return lbl


func _refresh_overlay_labels() -> void:
	if _score_label_t0 != null:
		_score_label_t0.text = "PHANTOM  %02d" % GameState.scores[0]
	if _score_label_t1 != null:
		_score_label_t1.text = "%02d  RIVAL" % GameState.scores[1]
	if _clock_label != null:
		var total_sec: int = maxi(0, int(ceil(GameState.match_seconds_left)))
		var mins: int = total_sec / 60
		var secs: int = total_sec % 60
		_clock_label.text = "%02d:%02d" % [mins, secs]
	if _shot_clock_label != null:
		var sc: float = GameState.shot_clock_left
		_shot_clock_label.text = "%04.1f" % sc if sc < 10.0 else "%02d" % int(ceil(sc))
	if _possession_label != null:
		_possession_label.text = "POSS: P%d (T%d)" % [GameState.ball_carrier_id, GameState.possession_team] if GameState.ball_carrier_id >= 0 else "POSS: T%d" % GameState.possession_team


func _on_score_changed_ui(team_id: int, _new_score: int, delta: int, is_three: bool, scorer_id: int) -> void:
	if not _scoring_via_hoop and delta > 0 and scorer_id >= 0:
		_record_player_points(scorer_id, delta, is_three, team_id)
	_refresh_overlay_labels()


func _on_shot_feedback_ui(_player_id: int, label: String, _timing_error: float) -> void:
	var col := Color(0.30, 1.0, 0.58, 1.0) if label.to_upper() == "PERFECT" else Color(1.0, 0.88, 0.30, 1.0)
	_show_banner("RELEASE: %s" % label, col, 1.1)


func _on_stamina_updated_ui(player_id: int, current: float, maximum: float) -> void:
	if player_id == GameState.local_player_id and _stamina_bar != null:
		_stamina_bar.max_value = maximum
		_stamina_bar.value = current


func _on_zone_updated_ui(player_id: int, current: float, maximum: float) -> void:
	if player_id == GameState.local_player_id and _zone_bar != null:
		_zone_bar.max_value = maximum
		_zone_bar.value = current
		if _zone_status_label != null and not _zone_status_label.text.begins_with("ZONE ACTIVE"):
			var pct: int = int(round((current / maxf(1.0, maximum)) * 100.0))
			_zone_status_label.text = "ZONE READY! [PRESS V]" if pct >= 100 else ("ZONE: %d%%" % pct)


func _on_zone_activated_ui(player_id: int, duration: float) -> void:
	if player_id >= 0:
		var entry: Dictionary = _ensure_player_box_entry(player_id)
		entry["zone_activations"] = int(entry.get("zone_activations", 0)) + 1
	if player_id == GameState.local_player_id and _zone_status_label != null:
		_zone_status_label.text = "ZONE ACTIVE (%.0fs)" % duration
		_zone_status_label.add_theme_color_override("font_color", Color(0.20, 1.0, 0.92, 1.0))
	_show_banner("ZONE AWAKENED!", Color(0.20, 1.0, 0.95, 1.0), 1.8)


func _on_zone_ended_ui(player_id: int) -> void:
	if player_id == GameState.local_player_id and _zone_status_label != null:
		_zone_status_label.text = "ZONE: 0%"
		_zone_status_label.add_theme_color_override("font_color", Color(0.45, 0.90, 1.0, 0.92))


func _on_combo_triggered_stats(player_id: int, _combo_id: String, _combo_tier: int, _is_perfect: bool) -> void:
	if player_id >= 0:
		var entry: Dictionary = _ensure_player_box_entry(player_id)
		entry["combos"] = int(entry.get("combos", 0)) + 1


func _on_block_performed_stats(blocker_id: int, _shooter_id: int, _world_pos: Vector3) -> void:
	if blocker_id >= 0:
		var entry: Dictionary = _ensure_player_box_entry(blocker_id)
		entry["blocks"] = int(entry.get("blocks", 0)) + 1


func _on_steal_performed_stats(stealer_id: int, _victim_id: int, _world_pos: Vector3) -> void:
	if stealer_id >= 0:
		var entry: Dictionary = _ensure_player_box_entry(stealer_id)
		entry["steals"] = int(entry.get("steals", 0)) + 1


# ==============================================================================
# Per-Player Live Match Box Score Tracking (Phase 14 PostMatchUI Integration)
# ==============================================================================

func _reset_box_score_stats() -> void:
	_player_box_stats.clear()
	_rebound_baseline_by_pid.clear()
	_last_career_rating_update.clear()
	refresh_box_score_roster()


func refresh_box_score_roster() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for p_node in tree.get_nodes_in_group("players"):
		if p_node is PlayerController:
			var pc := p_node as PlayerController
			var is_new_entry: bool = not _player_box_stats.has(pc.player_id)
			var entry: Dictionary = _ensure_player_box_entry(pc.player_id, pc)
			_sync_player_identity_into_entry(entry, pc)
			if is_new_entry and pc.defense_system != null:
				_rebound_baseline_by_pid[pc.player_id] = pc.defense_system.rebounds_grabbed


func _find_player_by_id(player_id: int) -> PlayerController:
	var tree := get_tree()
	if tree == null:
		return null
	for p_node in tree.get_nodes_in_group("players"):
		if p_node is PlayerController and (p_node as PlayerController).player_id == player_id:
			return p_node as PlayerController
	return null


func _resolve_player_display_name(pc: PlayerController, fallback_pid: int) -> String:
	if pc != null:
		if pc.is_local_human and GameState != null and not GameState.player_name.strip_edges().is_empty():
			return GameState.player_name
		var arch_dict: Dictionary = ArchetypeRegistry.get_archetype_dict(pc.archetype_id)
		if not arch_dict.is_empty():
			var nick: String = str(arch_dict.get("nickname", "")).strip_edges()
			if not nick.is_empty():
				return "%s (P%d)" % [nick, pc.player_id]
		return str(pc.name)
	return "Player %d" % fallback_pid


func _sync_player_identity_into_entry(entry: Dictionary, pc: PlayerController) -> void:
	if pc == null:
		return
	entry["player_id"] = pc.player_id
	entry["team_id"] = pc.team_id
	var uname: String = _resolve_player_display_name(pc, pc.player_id)
	entry["username"] = uname
	entry["name"] = uname
	var arch_id: String = ArchetypeRegistry.resolve_id(pc.archetype_id)
	entry["archetype"] = arch_id
	entry["archetype_id"] = arch_id


func _ensure_player_box_entry(player_id: int, pc: PlayerController = null) -> Dictionary:
	if _player_box_stats.has(player_id):
		var existing: Dictionary = _player_box_stats[player_id] as Dictionary
		if pc != null:
			_sync_player_identity_into_entry(existing, pc)
		return existing

	var resolved_pc: PlayerController = pc if pc != null else _find_player_by_id(player_id)
	var default_team: int = resolved_pc.team_id if resolved_pc != null else (0 if (player_id % 2 == 1) else 1)
	var uname: String = _resolve_player_display_name(resolved_pc, player_id)
	var arch_id: String = ArchetypeRegistry.resolve_id(resolved_pc.archetype_id) if resolved_pc != null else "all_rounder"
	if resolved_pc != null and resolved_pc.defense_system != null and not _rebound_baseline_by_pid.has(player_id):
		_rebound_baseline_by_pid[player_id] = resolved_pc.defense_system.rebounds_grabbed

	var entry: Dictionary = {
		"player_id": player_id,
		"team_id": default_team,
		"username": uname,
		"name": uname,
		"archetype": arch_id,
		"archetype_id": arch_id,
		"points": 0,
		"two_pointers_made": 0,
		"three_pointers_made": 0,
		"threes_made": 0,
		"assists": 0,
		"rebounds": 0,
		"steals": 0,
		"blocks": 0,
		"combos": 0,
		"zone_activations": 0,
	}
	_player_box_stats[player_id] = entry
	return entry


func _record_player_points(scorer_id: int, points: int, is_three: bool, fallback_team: int = -1) -> void:
	var entry: Dictionary = _ensure_player_box_entry(scorer_id)
	if fallback_team >= 0 and _find_player_by_id(scorer_id) == null:
		entry["team_id"] = fallback_team
	entry["points"] = int(entry.get("points", 0)) + points
	if is_three:
		entry["three_pointers_made"] = int(entry.get("three_pointers_made", 0)) + 1
		entry["threes_made"] = int(entry.get("threes_made", 0)) + 1
	else:
		entry["two_pointers_made"] = int(entry.get("two_pointers_made", 0)) + 1


func get_player_box_score(player_id: int) -> Dictionary:
	refresh_box_score_roster()
	var pc: PlayerController = _find_player_by_id(player_id)
	var entry: Dictionary = _ensure_player_box_entry(player_id, pc)
	if pc != null and pc.defense_system != null:
		var reb_delta: int = maxi(0, pc.defense_system.rebounds_grabbed - int(_rebound_baseline_by_pid.get(player_id, 0)))
		entry["rebounds"] = maxi(int(entry.get("rebounds", 0)), reb_delta)
	return entry.duplicate(true)


func build_box_score_players_array() -> Array[Dictionary]:
	refresh_box_score_roster()
	var tree := get_tree()
	if tree != null:
		for p_node in tree.get_nodes_in_group("players"):
			if p_node is PlayerController:
				var pc := p_node as PlayerController
				var entry: Dictionary = _ensure_player_box_entry(pc.player_id, pc)
				if pc.defense_system != null:
					var reb_delta: int = maxi(0, pc.defense_system.rebounds_grabbed - int(_rebound_baseline_by_pid.get(pc.player_id, 0)))
					entry["rebounds"] = maxi(int(entry.get("rebounds", 0)), reb_delta)

	var list: Array[Dictionary] = []
	for k in _player_box_stats.keys():
		var e: Dictionary = (_player_box_stats[k] as Dictionary).duplicate(true)
		list.append(e)

	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ta: int = int(a.get("team_id", 0))
		var tb: int = int(b.get("team_id", 0))
		if ta != tb:
			return ta < tb
		return int(a.get("player_id", 0)) < int(b.get("player_id", 0))
	)
	return list


func build_match_end_summary() -> Dictionary:
	var summary: Dictionary = match_stats.duplicate(true)
	summary["players"] = build_box_score_players_array()
	summary["is_online"] = GameState != null and bool(GameState.get("is_online"))
	return summary


func is_zone_indicator_active() -> bool:
	return _zone_status_label != null and _zone_status_label.text.begins_with("ZONE ACTIVE")


func _show_banner(msg: String, col: Color, duration: float) -> void:
	if _banner_label == null:
		return
	_banner_label.text = msg
	_banner_label.add_theme_color_override("font_color", col)
	_banner_label.visible = true
	_banner_timer = duration
