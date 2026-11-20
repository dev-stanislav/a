class_name ArenaBuilder
extends Node3D
## Procedural 3D Anime Indoor Basketball Gymnasium & Regulation Court Builder.
## Constructs playable court floor (y = 0, x in [-7.5, +7.5], z in [-14.0, +14.0]),
## boundary colliders, FIBA/Phantom 3pt arcs (6.75m / corner 6.60m), paint boxes,
## center circle, bleachers, roof trusses, lighting, and WorldEnvironment.

const COURT_WIDTH: float = 15.0
const COURT_LENGTH: float = 28.0
const HALF_WIDTH: float = 7.5
const HALF_LENGTH: float = 14.0

const RIM_Z_OFFSET: float = 12.425
const THREE_PT_RADIUS: float = 6.75
const THREE_PT_CORNER_X: float = 6.60
const KEY_WIDTH: float = 4.90
const KEY_LENGTH: float = 5.80
const CENTER_CIRCLE_RADIUS: float = 1.80
const LINE_WIDTH: float = 0.055


signal navigate_requested(route: String, params: Dictionary)

const VFX_MANAGER_PATH := "res://scripts/vfx/vfx_manager.gd"
const SOUND_MANAGER_PATH := "res://scripts/audio/sound_manager.gd"
const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"
const HUD_SCENE_PATH := "res://scenes/ui/hud.tscn"
const PAUSE_MENU_SCENE_PATH := "res://scenes/ui/pause_menu.tscn"
const POST_MATCH_SCENE_PATH := "res://scenes/ui/post_match.tscn"
const TOUCH_CONTROLS_SCENE_PATH := "res://scenes/ui/touch_controls.tscn"

const SPECTATOR_CAM_POSITION := Vector3(11.2, 7.6, 2.2)
const SPECTATOR_CAM_TARGET := Vector3(0.0, 1.2, 0.0)
const SPECTATOR_CAM_FOV: float = 66.0

const TEAM0_SPAWN_POSITIONS: Array[Vector3] = [
	Vector3(0.0, 0.0, -3.5),
	Vector3(-3.8, 0.0, -2.5),
	Vector3(3.8, 0.0, -2.5),
]
const TEAM1_SPAWN_POSITIONS: Array[Vector3] = [
	Vector3(0.0, 0.0, -6.8),
	Vector3(-3.8, 0.0, -6.5),
	Vector3(3.8, 0.0, -6.5),
]
const TEAM0_AI_ARCHETYPES: Array[String] = ["playmaker", "sharpshooter", "powerhouse"]
const TEAM1_AI_ARCHETYPES: Array[String] = ["speedster", "sharpshooter", "all_rounder"]

@export var auto_spawn_ai_mode: String = ""
@export var auto_spawn_ai_difficulty: int = AIDifficulty.Tier.PRO
@export var auto_spawn_ai_seed: int = 1337

var active_ai_roster_mode: String = ""
var _spawned_ai_players: Array[PlayerController] = []
var _court_floor_material: ShaderMaterial = null
var _hud_instance: Node = null
var _pause_menu_instance: Node = null
var _post_match_instance: Node = null
var _touch_controls_instance: Node = null
var _spectator_camera: Camera3D = null
var _spectator_mode_active: bool = false


func _enter_tree() -> void:
	_build_arena_if_needed()


func _exit_tree() -> void:
	if EventBus != null and EventBus.match_restarted.is_connected(_on_match_restarted_ui_cleanup):
		EventBus.match_restarted.disconnect(_on_match_restarted_ui_cleanup)


func _ready() -> void:
	add_to_group("arena")
	_build_arena_if_needed()
	_mount_optional_managers()
	_mount_match_overlays()
	_check_optional_auto_ai_spawn()
	_check_menu_launched_setup()
	if EventBus != null and not EventBus.match_restarted.is_connected(_on_match_restarted_ui_cleanup):
		EventBus.match_restarted.connect(_on_match_restarted_ui_cleanup)


func _check_optional_auto_ai_spawn() -> void:
	var mode_to_spawn: String = auto_spawn_ai_mode.strip_edges()
	var diff_to_spawn: int = auto_spawn_ai_difficulty
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--ai-mode" and i + 1 < args.size():
			mode_to_spawn = args[i + 1].strip_edges()
		elif args[i] == "--ai-difficulty" and i + 1 < args.size():
			diff_to_spawn = AIDifficulty.from_name(args[i + 1])
	if not mode_to_spawn.is_empty():
		spawn_ai_match_roster(mode_to_spawn, diff_to_spawn, auto_spawn_ai_seed)


func _check_menu_launched_setup() -> void:
	if GameState == null:
		return

	# 1. Menu-Launched Offline Exhibition Roster (`GameState.auto_spawn_roster == true`)
	if bool(GameState.get("auto_spawn_roster")):
		GameState.set("auto_spawn_roster", false)

		var raw_mode: String = ""
		if GameState.get("selected_mode") != null:
			raw_mode = str(GameState.get("selected_mode")).strip_edges()
		if raw_mode.is_empty() and GameState.get("match_mode") != null:
			raw_mode = str(GameState.get("match_mode")).strip_edges()
		if raw_mode.is_empty():
			raw_mode = "3v3"

		var diff_tier: int = AIDifficulty.Tier.PRO
		if GameState.get("selected_difficulty") != null:
			var raw_diff: Variant = GameState.get("selected_difficulty")
			if raw_diff is int:
				diff_tier = clampi(raw_diff as int, 0, 3)
			else:
				diff_tier = AIDifficulty.from_name(str(raw_diff))
		elif GameState.get("selected_difficulty_name") != null:
			diff_tier = AIDifficulty.from_name(str(GameState.get("selected_difficulty_name")))

		var raw_arch: String = (
			str(GameState.get("selected_archetype")).strip_edges()
			if GameState.get("selected_archetype") != null
			else "phantom_pg"
		)
		var chosen_arch: String = ArchetypeRegistry.resolve_id(raw_arch)

		spawn_ai_match_roster(raw_mode, diff_tier, auto_spawn_ai_seed, true)

		var players_root: Node = get_node_or_null("Players")
		if players_root != null:
			var local_p := players_root.get_node_or_null("LocalPlayer") as PlayerController
			if local_p != null and ArchetypeRegistry.has_archetype(chosen_arch):
				local_p.apply_archetype_by_id(chosen_arch)
				local_p.reset_for_match(local_p.global_transform)

		var mc := get_node_or_null("MatchController") as MatchController
		if mc != null:
			mc.refresh_box_score_roster()

	# 2. Spectator Broadcast Mode (`GameState.is_spectator == true`)
	if bool(GameState.get("is_spectator")):
		set_spectator_mode(true)


# ==============================================================================
# Phase 7 Optional 1v1 / 2v2 / 3v3 AI Match Roster Spawner & Controls
# ==============================================================================

func spawn_ai_match_roster(
	mode: String = "1v1",
	difficulty_tier: int = AIDifficulty.Tier.PRO,
	base_seed: int = 1337,
	local_human_on_team0: bool = true
) -> Array[PlayerController]:
	clear_spawned_ai_players()

	var norm_mode: String = mode.strip_edges().to_lower()
	var team_size: int = 1
	if norm_mode.contains("3v3"):
		team_size = 3
	elif norm_mode.contains("2v2"):
		team_size = 2
	else:
		team_size = 1

	var human_slot0: bool = local_human_on_team0
	if norm_mode.contains("ai_vs_ai") or norm_mode.contains("bot_vs_bot"):
		human_slot0 = false

	active_ai_roster_mode = mode
	var players_root: Node3D = get_node_or_null("Players") as Node3D
	if players_root == null:
		players_root = Node3D.new()
		players_root.name = "Players"
		add_child(players_root)

	var packed_player := load(PLAYER_SCENE_PATH) as PackedScene
	var all_roster: Array[PlayerController] = []
	var spawn_map: Dictionary = {} # instance_id -> Transform3D

	# 1. Configure Team 0 Slot 0 (LocalPlayer P1)
	var local_p: PlayerController = players_root.get_node_or_null("LocalPlayer") as PlayerController
	if local_p == null and packed_player != null:
		local_p = packed_player.instantiate() as PlayerController
		local_p.name = "LocalPlayer"
		local_p.player_id = 1
		local_p.team_id = 0
		players_root.add_child(local_p)

	if local_p != null:
		var t0_xform := Transform3D(Basis.IDENTITY, TEAM0_SPAWN_POSITIONS[0])
		local_p.player_id = 1
		local_p.team_id = 0
		local_p.global_transform = t0_xform
		spawn_map[local_p.get_instance_id()] = t0_xform
		if human_slot0:
			_detach_ai_from_player(local_p, true)
		else:
			if not ArchetypeRegistry.has_archetype(local_p.archetype_id):
				local_p.apply_archetype_by_id(TEAM0_AI_ARCHETYPES[0])
			attach_ai_to_player(local_p, difficulty_tier, base_seed + local_p.player_id * 97)
		all_roster.append(local_p)

	# 2. Spawn Team 0 AI Teammates (Slots 1..team_size-1 -> P3, P5)
	for slot_idx in range(1, team_size):
		if packed_player == null:
			break
		var pid_t0: int = 1 + slot_idx * 2 # 3, 5
		var pos_t0: Vector3 = TEAM0_SPAWN_POSITIONS[mini(slot_idx, TEAM0_SPAWN_POSITIONS.size() - 1)]
		var xform_t0 := Transform3D(Basis.IDENTITY, pos_t0)
		var bot_t0 := packed_player.instantiate() as PlayerController
		bot_t0.name = "TeammateAI_%d" % slot_idx
		bot_t0.player_id = pid_t0
		bot_t0.team_id = 0
		bot_t0.is_local_human = false
		players_root.add_child(bot_t0)
		bot_t0.global_transform = xform_t0
		bot_t0.apply_archetype_by_id(TEAM0_AI_ARCHETYPES[slot_idx % TEAM0_AI_ARCHETYPES.size()])
		attach_ai_to_player(bot_t0, difficulty_tier, base_seed + pid_t0 * 97)
		_spawned_ai_players.append(bot_t0)
		spawn_map[bot_t0.get_instance_id()] = xform_t0
		all_roster.append(bot_t0)

	# 3. Spawn Team 1 AI Opponents (Slots 0..team_size-1 -> P2, P4, P6 facing +Z)
	var basis_t1 := Basis.from_euler(Vector3(0.0, PI, 0.0))
	for slot_idx in range(team_size):
		if packed_player == null:
			break
		var pid_t1: int = 2 + slot_idx * 2 # 2, 4, 6
		var pos_t1: Vector3 = TEAM1_SPAWN_POSITIONS[mini(slot_idx, TEAM1_SPAWN_POSITIONS.size() - 1)]
		var xform_t1 := Transform3D(basis_t1, pos_t1)
		var bot_t1 := packed_player.instantiate() as PlayerController
		bot_t1.name = "OpponentAI_%d" % (slot_idx + 1)
		bot_t1.player_id = pid_t1
		bot_t1.team_id = 1
		bot_t1.is_local_human = false
		players_root.add_child(bot_t1)
		bot_t1.global_transform = xform_t1
		bot_t1.apply_archetype_by_id(TEAM1_AI_ARCHETYPES[slot_idx % TEAM1_AI_ARCHETYPES.size()])
		attach_ai_to_player(bot_t1, difficulty_tier, base_seed + pid_t1 * 97)
		_spawned_ai_players.append(bot_t1)
		spawn_map[bot_t1.get_instance_id()] = xform_t1
		all_roster.append(bot_t1)

	all_roster.sort_custom(func(a: PlayerController, b: PlayerController) -> bool:
		return a.player_id < b.player_id
	)

	if GameState != null:
		GameState.match_mode = "offline_%dv%d" % [team_size, team_size]

	var mc := get_node_or_null("MatchController") as MatchController
	if mc != null:
		mc.sync_roster_spawns(spawn_map)
		mc.restart_match()

	return all_roster


func clear_spawned_ai_players() -> void:
	for p in _spawned_ai_players:
		if p != null and is_instance_valid(p):
			p.remove_from_group("players")
			if p.get_parent() != null:
				p.get_parent().remove_child(p)
			p.queue_free()
	_spawned_ai_players.clear()
	active_ai_roster_mode = ""

	var players_root: Node = get_node_or_null("Players")
	if players_root != null:
		var local_p := players_root.get_node_or_null("LocalPlayer") as PlayerController
		if local_p != null:
			_detach_ai_from_player(local_p, true)


func attach_ai_to_player(
	player: PlayerController,
	difficulty_tier: int = AIDifficulty.Tier.PRO,
	seed_val: int = 1337
) -> AIController:
	if player == null:
		return null
	var ai := player.get_node_or_null("AIController") as AIController
	if ai == null:
		ai = AIController.new()
		ai.name = "AIController"
		player.add_child(ai)
	ai.setup(player, difficulty_tier, seed_val)
	player.is_local_human = false
	player.set_external_input_provider(ai)
	return ai


func _detach_ai_from_player(player: PlayerController, restore_human: bool = true) -> void:
	if player == null:
		return
	var existing_ai: Node = player.get_node_or_null("AIController")
	if existing_ai != null:
		player.remove_child(existing_ai)
		existing_ai.queue_free()
	player.is_local_human = restore_human
	player.set_external_input_provider(null)


func set_ai_difficulty_all(difficulty_tier: int) -> void:
	for ai in get_ai_controllers():
		ai.set_difficulty(difficulty_tier)


func get_ai_controllers() -> Array[AIController]:
	var list: Array[AIController] = []
	var players_root: Node = get_node_or_null("Players")
	var candidates: Array[Node] = players_root.get_children() if players_root != null else get_children()
	for child in candidates:
		if child is PlayerController:
			var ai := (child as PlayerController).get_node_or_null("AIController") as AIController
			if ai != null:
				list.append(ai)
	list.sort_custom(func(a: AIController, b: AIController) -> bool:
		var pa: int = int(a.owner_player.get("player_id")) if a.owner_player != null else 0
		var pb: int = int(b.owner_player.get("player_id")) if b.owner_player != null else 0
		return pa < pb
	)
	return list


func get_team_players(check_team_id: int) -> Array[PlayerController]:
	var res: Array[PlayerController] = []
	var players_root: Node = get_node_or_null("Players")
	if players_root == null:
		return res
	for child in players_root.get_children():
		if child is PlayerController and (child as PlayerController).team_id == check_team_id:
			res.append(child as PlayerController)
	res.sort_custom(func(a: PlayerController, b: PlayerController) -> bool:
		return a.player_id < b.player_id
	)
	return res


func _mount_optional_managers() -> void:
	if get_node_or_null("VFXManager") == null and ResourceLoader.exists(VFX_MANAGER_PATH):
		var vfx_scr := load(VFX_MANAGER_PATH) as GDScript
		if vfx_scr != null and vfx_scr.can_instantiate():
			var vfx_inst: Variant = vfx_scr.new()
			if vfx_inst is Node:
				(vfx_inst as Node).name = "VFXManager"
				add_child(vfx_inst as Node)

	if get_node_or_null("SoundManager") == null and ResourceLoader.exists(SOUND_MANAGER_PATH):
		var snd_scr := load(SOUND_MANAGER_PATH) as GDScript
		if snd_scr != null and snd_scr.can_instantiate():
			var snd_inst: Variant = snd_scr.new()
			if snd_inst is Node:
				(snd_inst as Node).name = "SoundManager"
				add_child(snd_inst as Node)


func _mount_match_overlays() -> void:
	# 1. Broadcast Cyber-Anime Match HUD (`HUDController`)
	_hud_instance = get_node_or_null("HUD")
	if _hud_instance == null and ResourceLoader.exists(HUD_SCENE_PATH):
		var hud_packed := load(HUD_SCENE_PATH) as PackedScene
		if hud_packed != null:
			var hud_node: Node = hud_packed.instantiate()
			if hud_node != null:
				hud_node.name = "HUD"
				add_child(hud_node)
				_hud_instance = hud_node

	if _hud_instance != null:
		if GameState != null and _hud_instance.has_method("set_tracked_player_id"):
			_hud_instance.call("set_tracked_player_id", GameState.local_player_id)
		var mc := get_node_or_null("MatchController") as MatchController
		if mc != null:
			mc.set_phase1_overlay_visible(false)

	# 2. In-Match Pause Menu Overlay (`PauseMenuUI`)
	_pause_menu_instance = get_node_or_null("PauseMenu")
	if _pause_menu_instance == null and ResourceLoader.exists(PAUSE_MENU_SCENE_PATH):
		var pause_packed := load(PAUSE_MENU_SCENE_PATH) as PackedScene
		if pause_packed != null:
			var pause_node: Node = pause_packed.instantiate()
			if pause_node != null:
				pause_node.name = "PauseMenu"
				add_child(pause_node)
				_pause_menu_instance = pause_node

	if _pause_menu_instance != null:
		if _pause_menu_instance.has_signal("restart_requested") and not _pause_menu_instance.is_connected("restart_requested", _on_pause_restart_requested):
			_pause_menu_instance.connect("restart_requested", _on_pause_restart_requested)
		if _pause_menu_instance.has_signal("navigate_requested") and not _pause_menu_instance.is_connected("navigate_requested", _on_overlay_navigate_requested):
			_pause_menu_instance.connect("navigate_requested", _on_overlay_navigate_requested)

	# 3. Post-Match Results & Box Score Overlay (`PostMatchUI`)
	_post_match_instance = get_node_or_null("PostMatchUI")
	if _post_match_instance == null and ResourceLoader.exists(POST_MATCH_SCENE_PATH):
		var pm_packed := load(POST_MATCH_SCENE_PATH) as PackedScene
		if pm_packed != null:
			var pm_node: Node = pm_packed.instantiate()
			if pm_node != null:
				pm_node.name = "PostMatchUI"
				add_child(pm_node)
				_post_match_instance = pm_node

	if _post_match_instance != null:
		if _post_match_instance.has_signal("rematch_requested") and not _post_match_instance.is_connected("rematch_requested", _on_post_match_rematch_requested):
			_post_match_instance.connect("rematch_requested", _on_post_match_rematch_requested)
		if _post_match_instance.has_signal("navigate_requested") and not _post_match_instance.is_connected("navigate_requested", _on_overlay_navigate_requested):
			_post_match_instance.connect("navigate_requested", _on_overlay_navigate_requested)

	# 4. Mobile / iOS Virtual Touch Controls Overlay (`TouchControlsUI`)
	_touch_controls_instance = get_node_or_null("TouchControls")
	if _touch_controls_instance == null and ResourceLoader.exists(TOUCH_CONTROLS_SCENE_PATH):
		var tc_packed := load(TOUCH_CONTROLS_SCENE_PATH) as PackedScene
		if tc_packed != null:
			var tc_node: Node = tc_packed.instantiate()
			if tc_node != null:
				tc_node.name = "TouchControls"
				add_child(tc_node)
				_touch_controls_instance = tc_node

	if _touch_controls_instance != null:
		if _touch_controls_instance.has_signal("pause_pressed") and not _touch_controls_instance.is_connected("pause_pressed", _on_touch_pause_pressed):
			_touch_controls_instance.connect("pause_pressed", _on_touch_pause_pressed)


func get_hud() -> Node:
	if _hud_instance != null and is_instance_valid(_hud_instance):
		return _hud_instance
	return get_node_or_null("HUD")


func get_pause_menu() -> Node:
	if _pause_menu_instance != null and is_instance_valid(_pause_menu_instance):
		return _pause_menu_instance
	return get_node_or_null("PauseMenu")


func get_post_match_ui() -> Node:
	if _post_match_instance != null and is_instance_valid(_post_match_instance):
		return _post_match_instance
	return get_node_or_null("PostMatchUI")


func get_touch_controls() -> Node:
	if _touch_controls_instance != null and is_instance_valid(_touch_controls_instance):
		return _touch_controls_instance
	return get_node_or_null("TouchControls")


func _on_touch_pause_pressed() -> void:
	var pause_ui: Node = get_pause_menu()
	if pause_ui != null and pause_ui.has_method("toggle_pause"):
		pause_ui.call("toggle_pause")


func get_spectator_camera() -> Camera3D:
	if _spectator_camera != null and is_instance_valid(_spectator_camera):
		return _spectator_camera
	return get_node_or_null("SpectatorBroadcastCamera") as Camera3D


func is_spectator_mode_active() -> bool:
	return _spectator_mode_active


func set_spectator_mode(enabled: bool) -> void:
	_spectator_mode_active = enabled
	var hud: Node = get_hud()
	if hud != null and hud.has_method("set_spectator_mode"):
		hud.call("set_spectator_mode", enabled)

	if enabled:
		if _spectator_camera == null or not is_instance_valid(_spectator_camera):
			_spectator_camera = get_node_or_null("SpectatorBroadcastCamera") as Camera3D
		if _spectator_camera == null:
			_spectator_camera = Camera3D.new()
			_spectator_camera.name = "SpectatorBroadcastCamera"
			_spectator_camera.fov = SPECTATOR_CAM_FOV
			_spectator_camera.near = 0.1
			_spectator_camera.far = 120.0
			add_child(_spectator_camera)

		var look_vec: Vector3 = SPECTATOR_CAM_TARGET - SPECTATOR_CAM_POSITION
		var look_basis := Basis.IDENTITY
		if look_vec.length_squared() > 0.0001:
			var up_axis: Vector3 = Vector3.UP if absf(look_vec.normalized().dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
			look_basis = Basis.looking_at(look_vec.normalized(), up_axis)
		_spectator_camera.global_transform = Transform3D(look_basis, SPECTATOR_CAM_POSITION)

		var players_root: Node = get_node_or_null("Players")
		if players_root != null:
			for child in players_root.get_children():
				if child is PlayerController:
					var pc := child as PlayerController
					if pc.camera_rig != null:
						pc.camera_rig.set_active_camera(false)
					if pc.name == "LocalPlayer" and pc.get_node_or_null("AIController") == null:
						pc.is_local_human = false

		_spectator_camera.current = true
		if _spectator_camera.is_inside_tree():
			_spectator_camera.make_current()
	else:
		if _spectator_camera != null and is_instance_valid(_spectator_camera):
			_spectator_camera.current = false
		var players_root_off: Node = get_node_or_null("Players")
		if players_root_off != null:
			var local_p := players_root_off.get_node_or_null("LocalPlayer") as PlayerController
			if local_p != null and local_p.get_node_or_null("AIController") == null:
				local_p.is_local_human = true
				if local_p.camera_rig != null:
					local_p.camera_rig.set_active_camera(true)
					if local_p.camera_rig.camera != null and local_p.camera_rig.camera.is_inside_tree():
						local_p.camera_rig.camera.make_current()


func _on_pause_restart_requested() -> void:
	if GameState != null and bool(GameState.get("is_online")):
		return
	var mc := get_node_or_null("MatchController") as MatchController
	if mc != null:
		mc.restart_match_from_ui_signal()


func _on_post_match_rematch_requested() -> void:
	if GameState != null and bool(GameState.get("is_online")):
		return
	var pm: Node = get_post_match_ui()
	if pm != null and pm.has_method("hide_results"):
		pm.call("hide_results")
	var mc := get_node_or_null("MatchController") as MatchController
	if mc != null:
		mc.restart_match_from_ui_signal()


func _on_overlay_navigate_requested(route: String, params: Dictionary = {}) -> void:
	navigate_requested.emit(route, params)


func _on_match_restarted_ui_cleanup() -> void:
	var pm: Node = get_post_match_ui()
	if pm != null and pm.has_method("hide_results"):
		pm.call("hide_results")
	var pause_ui: Node = get_pause_menu()
	if pause_ui != null and pause_ui.has_method("is_pause_open") and bool(pause_ui.call("is_pause_open")):
		if pause_ui.has_method("close_pause"):
			pause_ui.call("close_pause")


func get_court_size() -> Vector2:
	return Vector2(COURT_WIDTH, COURT_LENGTH)


func get_court_floor_material() -> ShaderMaterial:
	return _court_floor_material


func get_vfx_manager() -> VFXManager:
	return get_node_or_null("VFXManager") as VFXManager


func is_in_bounds(world_pos: Vector3) -> bool:
	return absf(world_pos.x) <= HALF_WIDTH and absf(world_pos.z) <= HALF_LENGTH


func _build_arena_if_needed() -> void:
	if get_node_or_null("CourtFloor") != null:
		return

	_build_environment_and_lights()
	_build_court_floor_and_walls()
	_build_court_markings()
	_build_gymnasium_shell_and_bleachers()


func _build_environment_and_lights() -> void:
	if get_node_or_null("WorldEnvironment") == null:
		var we := WorldEnvironment.new()
		we.name = "WorldEnvironment"
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.05, 0.07, 0.13, 1.0)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.62, 0.72, 0.92, 1.0)
		env.ambient_light_energy = 0.72
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.glow_enabled = true
		env.glow_intensity = 0.45
		env.glow_bloom = 0.08
		we.environment = env
		add_child(we)

	if get_node_or_null("SunLight") == null:
		var sun := DirectionalLight3D.new()
		sun.name = "SunLight"
		sun.light_color = Color(1.0, 0.97, 0.92, 1.0)
		sun.light_energy = 1.25
		var shadows_on: bool = DisplayServer.get_name() != "headless"
		if ConfigManager != null:
			shadows_on = shadows_on and bool(ConfigManager.get_setting("graphics", "shadows_enabled", true))
		sun.shadow_enabled = shadows_on
		sun.rotation_degrees = Vector3(-58.0, 26.0, 0.0)
		add_child(sun)

	var lights_root := Node3D.new()
	lights_root.name = "StadiumSpotlights"
	add_child(lights_root)

	var spot_positions: Array[Vector3] = [
		Vector3(-4.2, 10.4, -8.5),
		Vector3(4.2, 10.4, -8.5),
		Vector3(-4.2, 10.4, 8.5),
		Vector3(4.2, 10.4, 8.5),
	]
	for i in range(spot_positions.size()):
		var spot := SpotLight3D.new()
		spot.name = "StadiumSpot%d" % i
		spot.position = spot_positions[i]
		spot.rotation_degrees = Vector3(-78.0, 0.0, 0.0)
		spot.spot_range = 20.0
		spot.spot_angle = 52.0
		spot.light_energy = 2.2
		spot.light_color = Color(0.88, 0.95, 1.0, 1.0) if (i < 2) else Color(1.0, 0.94, 0.88, 1.0)
		lights_root.add_child(spot)


func _build_court_floor_and_walls() -> void:
	# 1. Playable Court Floor at exact y = 0.0
	var floor_body := StaticBody3D.new()
	floor_body.name = "CourtFloor"
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	floor_body.set_meta("surface_type", "court")
	floor_body.set_meta("restitution", 0.78)

	# Bounce = 0.0 on floor so combined with Basketball bounce = 0.78 yields exact 0.78 floor restitution
	var floor_phys := PhysicsMaterial.new()
	floor_phys.bounce = 0.0
	floor_phys.friction = 0.75
	floor_body.physics_material_override = floor_phys
	add_child(floor_body)

	var floor_col := CollisionShape3D.new()
	floor_col.name = "CollisionShape3D"
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(24.0, 0.50, 36.0)
	floor_col.shape = floor_box
	floor_col.position = Vector3(0.0, -0.25, 0.0) # Top plane is exact y = 0.0
	floor_body.add_child(floor_col)

	# Regulation 15m x 28m Stylized Anime Maple Hardwood Visual Mesh (`court_floor.gdshader`)
	var court_mesh_inst := MeshInstance3D.new()
	court_mesh_inst.name = "PlayableCourtSurface"
	var court_bm := BoxMesh.new()
	court_bm.size = Vector3(COURT_WIDTH, 0.02, COURT_LENGTH)
	_court_floor_material = VFXManager.create_court_floor_material()
	court_bm.material = _court_floor_material
	court_mesh_inst.material_override = _court_floor_material
	court_mesh_inst.mesh = court_bm
	court_mesh_inst.position = Vector3(0.0, -0.01, 0.0)
	floor_body.add_child(court_mesh_inst)

	# Out-of-bounds dark phantom-blue stadium apron
	var apron_mat := StandardMaterial3D.new()
	apron_mat.albedo_color = Color(0.08, 0.12, 0.22, 1.0)
	apron_mat.roughness = 0.55
	var apron := MeshInstance3D.new()
	apron.name = "OutOfBoundsApron"
	var apron_bm := BoxMesh.new()
	apron_bm.size = Vector3(24.0, 0.02, 36.0)
	apron_bm.material = apron_mat
	apron.mesh = apron_bm
	apron.position = Vector3(0.0, -0.015, 0.0)
	floor_body.add_child(apron)

	# Painted Key / Paint Boxes (Team 0 North z in [-14.0, -8.2], Team 1 South z in [8.2, 14.0])
	var paint_t0_mat := StandardMaterial3D.new()
	paint_t0_mat.albedo_color = Color(0.11, 0.32, 0.72, 1.0)
	paint_t0_mat.roughness = 0.35
	_add_flat_panel(floor_body, "PaintNorthB", Vector2(KEY_WIDTH, KEY_LENGTH), Vector3(0.0, 0.002, -HALF_LENGTH + KEY_LENGTH * 0.5), paint_t0_mat)

	var paint_t1_mat := StandardMaterial3D.new()
	paint_t1_mat.albedo_color = Color(0.70, 0.14, 0.24, 1.0)
	paint_t1_mat.roughness = 0.35
	_add_flat_panel(floor_body, "PaintSouthA", Vector2(KEY_WIDTH, KEY_LENGTH), Vector3(0.0, 0.002, HALF_LENGTH - KEY_LENGTH * 0.5), paint_t1_mat)

	# 2. Boundary Wall Colliders keeping players & loose balls inside the stadium apron
	var walls_body := StaticBody3D.new()
	walls_body.name = "BoundaryWalls"
	walls_body.collision_layer = 1
	walls_body.collision_mask = 0
	walls_body.set_meta("surface_type", "wall")
	var wall_phys := PhysicsMaterial.new()
	wall_phys.bounce = 0.20
	wall_phys.absorbent = true
	wall_phys.friction = 0.40
	walls_body.physics_material_override = wall_phys
	add_child(walls_body)

	_add_wall_collider(walls_body, "WallWest", Vector3(0.5, 12.0, 34.0), Vector3(-9.25, 6.0, 0.0))
	_add_wall_collider(walls_body, "WallEast", Vector3(0.5, 12.0, 34.0), Vector3(9.25, 6.0, 0.0))
	_add_wall_collider(walls_body, "WallNorth", Vector3(20.0, 12.0, 0.5), Vector3(0.0, 6.0, -16.25))
	_add_wall_collider(walls_body, "WallSouth", Vector3(20.0, 12.0, 0.5), Vector3(0.0, 6.0, 16.25))
	_add_wall_collider(walls_body, "CeilingCollider", Vector3(22.0, 0.5, 34.0), Vector3(0.0, 12.25, 0.0))


func _add_flat_panel(parent: Node3D, panel_name: String, sz_xz: Vector2, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = panel_name
	var bm := BoxMesh.new()
	bm.size = Vector3(sz_xz.x, 0.002, sz_xz.y)
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)


func _add_wall_collider(parent: StaticBody3D, wall_name: String, sz: Vector3, pos: Vector3) -> void:
	var cs := CollisionShape3D.new()
	cs.name = wall_name
	var box := BoxShape3D.new()
	box.size = sz
	cs.shape = box
	cs.position = pos
	parent.add_child(cs)


func _build_court_markings() -> void:
	var markings_inst := MeshInstance3D.new()
	markings_inst.name = "CourtMarkings"
	var imm := ImmediateMesh.new()
	markings_inst.mesh = imm

	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.albedo_color = Color(0.96, 0.98, 1.0, 1.0)
	line_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	markings_inst.material_override = line_mat
	add_child(markings_inst)

	imm.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var y: float = 0.006

	# Outer court boundary lines (x = ±7.5, z = ±14.0)
	_draw_line_quad(imm, Vector2(-HALF_WIDTH, -HALF_LENGTH), Vector2(HALF_WIDTH, -HALF_LENGTH), LINE_WIDTH, y)
	_draw_line_quad(imm, Vector2(-HALF_WIDTH, HALF_LENGTH), Vector2(HALF_WIDTH, HALF_LENGTH), LINE_WIDTH, y)
	_draw_line_quad(imm, Vector2(-HALF_WIDTH, -HALF_LENGTH), Vector2(-HALF_WIDTH, HALF_LENGTH), LINE_WIDTH, y)
	_draw_line_quad(imm, Vector2(HALF_WIDTH, -HALF_LENGTH), Vector2(HALF_WIDTH, HALF_LENGTH), LINE_WIDTH, y)

	# Half-court line (z = 0) & center circles
	_draw_line_quad(imm, Vector2(-HALF_WIDTH, 0.0), Vector2(HALF_WIDTH, 0.0), LINE_WIDTH, y)
	_draw_arc_quads(imm, Vector2.ZERO, CENTER_CIRCLE_RADIUS, 0.0, TAU, 48, LINE_WIDTH, y)
	_draw_arc_quads(imm, Vector2.ZERO, 0.60, 0.0, TAU, 32, LINE_WIDTH, y)

	# Both ends: Key boxes, free-throw circles, restricted arcs, and 6.75m / 6.60m 3-point lines
	_draw_half_court_end(imm, 1.0, y)  # South end (+Z, HoopA at +12.425)
	_draw_half_court_end(imm, -1.0, y) # North end (-Z, HoopB at -12.425)

	imm.surface_end()


func _draw_half_court_end(imm: ImmediateMesh, z_sign: float, y: float) -> void:
	var baseline_z: float = HALF_LENGTH * z_sign
	var ft_z: float = (HALF_LENGTH - KEY_LENGTH) * z_sign # ±8.20m
	var rim_z: float = RIM_Z_OFFSET * z_sign             # ±12.425m
	var khw: float = KEY_WIDTH * 0.5                     # 2.45m

	# Key perimeter
	_draw_line_quad(imm, Vector2(-khw, baseline_z), Vector2(-khw, ft_z), LINE_WIDTH, y)
	_draw_line_quad(imm, Vector2(khw, baseline_z), Vector2(khw, ft_z), LINE_WIDTH, y)
	_draw_line_quad(imm, Vector2(-khw, ft_z), Vector2(khw, ft_z), LINE_WIDTH, y)

	# Free-throw circle (r = 1.80m centered at ft_z)
	_draw_arc_quads(imm, Vector2(0.0, ft_z), 1.80, 0.0, TAU, 40, LINE_WIDTH, y)

	# Restricted area semicircle (r = 1.25m around rim_z toward center court)
	var rest_start: float = PI if z_sign > 0.0 else 0.0
	_draw_arc_quads(imm, Vector2(0.0, rim_z), 1.25, rest_start, rest_start + PI, 24, LINE_WIDTH, y)

	# Exact 3-Point Line:
	# Corner straight segments at x = ±6.60 joined seamlessly to 6.75m arc around (0, rim_z)
	var half_sweep: float = asin(clampf(THREE_PT_CORNER_X / THREE_PT_RADIUS, -1.0, 1.0))
	var join_dz: float = THREE_PT_RADIUS * cos(half_sweep) # ~1.4151m toward center court from rim
	var join_z: float = rim_z - z_sign * join_dz

	_draw_line_quad(imm, Vector2(-THREE_PT_CORNER_X, baseline_z), Vector2(-THREE_PT_CORNER_X, join_z), LINE_WIDTH, y)
	_draw_line_quad(imm, Vector2(THREE_PT_CORNER_X, baseline_z), Vector2(THREE_PT_CORNER_X, join_z), LINE_WIDTH, y)

	# Parametric arc facing center court
	var steps: int = 44
	for i in range(steps):
		var a0: float = lerpf(-half_sweep, half_sweep, float(i) / float(steps))
		var a1: float = lerpf(-half_sweep, half_sweep, float(i + 1) / float(steps))
		var p0 := Vector2(sin(a0) * THREE_PT_RADIUS, rim_z - z_sign * cos(a0) * THREE_PT_RADIUS)
		var p1 := Vector2(sin(a1) * THREE_PT_RADIUS, rim_z - z_sign * cos(a1) * THREE_PT_RADIUS)
		_draw_line_quad(imm, p0, p1, LINE_WIDTH, y)


func _draw_arc_quads(
	imm: ImmediateMesh,
	center_xz: Vector2,
	radius: float,
	start_angle: float,
	end_angle: float,
	segments: int,
	width: float,
	y: float
) -> void:
	for i in range(segments):
		var a0: float = lerpf(start_angle, end_angle, float(i) / float(segments))
		var a1: float = lerpf(start_angle, end_angle, float(i + 1) / float(segments))
		var p0 := center_xz + Vector2(cos(a0) * radius, sin(a0) * radius)
		var p1 := center_xz + Vector2(cos(a1) * radius, sin(a1) * radius)
		_draw_line_quad(imm, p0, p1, width, y)


func _draw_line_quad(imm: ImmediateMesh, p0: Vector2, p1: Vector2, width: float, y: float) -> void:
	var dir: Vector2 = p1 - p0
	if dir.length_squared() <= 0.000001:
		return
	var n: Vector2 = dir.normalized()
	var perp := Vector2(-n.y, n.x) * (width * 0.5)

	var v0 := Vector3(p0.x - perp.x, y, p0.y - perp.y)
	var v1 := Vector3(p0.x + perp.x, y, p0.y + perp.y)
	var v2 := Vector3(p1.x + perp.x, y, p1.y + perp.y)
	var v3 := Vector3(p1.x - perp.x, y, p1.y - perp.y)

	imm.surface_set_normal(Vector3.UP)
	imm.surface_add_vertex(v0)
	imm.surface_add_vertex(v1)
	imm.surface_add_vertex(v2)

	imm.surface_set_normal(Vector3.UP)
	imm.surface_add_vertex(v0)
	imm.surface_add_vertex(v2)
	imm.surface_add_vertex(v3)


func _build_gymnasium_shell_and_bleachers() -> void:
	var gym := Node3D.new()
	gym.name = "GymnasiumArchitecture"
	add_child(gym)

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.11, 0.14, 0.23, 1.0)
	wall_mat.roughness = 0.72

	var beam_mat := StandardMaterial3D.new()
	beam_mat.albedo_color = Color(0.18, 0.23, 0.35, 1.0)
	beam_mat.metallic = 0.55
	beam_mat.roughness = 0.38

	var window_glow_mat := StandardMaterial3D.new()
	window_glow_mat.albedo_color = Color(0.55, 0.82, 1.0, 1.0)
	window_glow_mat.emission_enabled = true
	window_glow_mat.emission = Color(0.42, 0.74, 1.0, 1.0)
	window_glow_mat.emission_energy_multiplier = 0.85

	var seat_blue_mat := StandardMaterial3D.new()
	seat_blue_mat.albedo_color = Color(0.13, 0.36, 0.78, 1.0)
	seat_blue_mat.roughness = 0.55

	var seat_red_mat := StandardMaterial3D.new()
	seat_red_mat.albedo_color = Color(0.76, 0.16, 0.26, 1.0)
	seat_red_mat.roughness = 0.55

	# Outer Gymnasium Walls (beyond bleachers at x = ±14.2m, z = ±17.0m)
	_add_gym_box(gym, "GymWallWest", Vector3(0.4, 12.2, 34.8), Vector3(-14.2, 6.1, 0.0), wall_mat)
	_add_gym_box(gym, "GymWallEast", Vector3(0.4, 12.2, 34.8), Vector3(14.2, 6.1, 0.0), wall_mat)
	_add_gym_box(gym, "GymWallNorth", Vector3(28.8, 12.2, 0.4), Vector3(0.0, 6.1, -17.2), wall_mat)
	_add_gym_box(gym, "GymWallSouth", Vector3(28.8, 12.2, 0.4), Vector3(0.0, 6.1, 17.2), wall_mat)
	_add_gym_box(gym, "GymRoofDeck", Vector3(29.0, 0.35, 35.0), Vector3(0.0, 12.3, 0.0), wall_mat)

	# Clerestory Anime Gym Windows along upper walls
	for w in range(-3, 4):
		var wz: float = float(w) * 4.4
		_add_gym_box(gym, "WindowWest_%d" % (w + 3), Vector3(0.08, 2.1, 3.1), Vector3(-13.95, 8.6, wz), window_glow_mat)
		_add_gym_box(gym, "WindowEast_%d" % (w + 3), Vector3(0.08, 2.1, 3.1), Vector3(13.95, 8.6, wz), window_glow_mat)

	# Stepped Sideline Bleachers (5 tiers on West & East sidelines)
	for tier in range(5):
		var tx: float = 9.7 + float(tier) * 0.85
		var ty: float = 0.32 + float(tier) * 0.52
		_add_gym_box(gym, "BleacherWest_%d" % tier, Vector3(0.78, 0.48, 25.0), Vector3(-tx, ty, 0.0), seat_blue_mat)
		_add_gym_box(gym, "BleacherEast_%d" % tier, Vector3(0.78, 0.48, 25.0), Vector3(tx, ty, 0.0), seat_red_mat)

	# Overhead Steel Roof Trusses & Center Jumbotron
	for b in range(-3, 4):
		var bz: float = float(b) * 4.8
		_add_gym_box(gym, "RoofBeam_%d" % (b + 3), Vector3(28.0, 0.38, 0.32), Vector3(0.0, 11.4, bz), beam_mat)

	_add_gym_box(gym, "CenterJumbotron", Vector3(3.4, 1.4, 2.2), Vector3(0.0, 9.2, 0.0), beam_mat)
	_add_gym_box(gym, "JumbotronScreenN", Vector3(3.0, 1.0, 0.08), Vector3(0.0, 9.2, -1.12), window_glow_mat)
	_add_gym_box(gym, "JumbotronScreenS", Vector3(3.0, 1.0, 0.08), Vector3(0.0, 9.2, 1.12), window_glow_mat)


func _add_gym_box(parent: Node3D, box_name: String, sz: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = box_name
	var bm := BoxMesh.new()
	bm.size = sz
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)
