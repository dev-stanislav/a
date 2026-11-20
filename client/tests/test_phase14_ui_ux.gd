extends Node
## Phase 14 Automated Verification Suite — Premium Anime UI/UX & Full Scene Routing
## (PHANTOM COURT ONLINE)
## Verifies:
## 1. UIThemeBuilder & clean headless instantiation of all 10 UI scenes (zero parse/null errors).
## 2. Full Main.navigate_to() routing across all 11 canonical routes + CharacterSelect -> play_offline
##    auto-spawning 2v2 AI roster & selected archetype on Arena + child signal navigation.
## 3. SettingsMenuUI reading/saving ConfigManager & syncing live AudioServer buses + reset defaults.
## 4. Honest online status (SERVER OFFLINE disables queue/lookup) & live Lobby/Profile/Leaderboard binding.
## 5. Live Arena HUDController, offline vs online PauseMenuUI (NEVER pauses SceneTree online!),
##    MatchController per-player Box Score -> PostMatchUI + Glicko-2 delta + offline Rematch,
##    and Spectator Mode broadcast camera + HUD banner.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"

const ALL_UI_SCENES: Array[Dictionary] = [
	{"name": "main_menu",        "path": "res://scenes/ui/main_menu.tscn"},
	{"name": "settings_menu",    "path": "res://scenes/ui/settings_menu.tscn"},
	{"name": "character_select", "path": "res://scenes/ui/character_select.tscn"},
	{"name": "training_hud",     "path": "res://scenes/ui/training_hud.tscn"},
	{"name": "matchmaking",      "path": "res://scenes/ui/matchmaking.tscn"},
	{"name": "lobby",            "path": "res://scenes/ui/lobby.tscn"},
	{"name": "hud",              "path": "res://scenes/ui/hud.tscn"},
	{"name": "pause_menu",       "path": "res://scenes/ui/pause_menu.tscn"},
	{"name": "post_match",       "path": "res://scenes/ui/post_match.tscn"},
	{"name": "profile_rankings", "path": "res://scenes/ui/profile_rankings.tscn"},
]


func run(runner: SceneTree) -> void:
	# Snapshot global state so Phase 14 tests leave zero side-effects
	var saved_gs := _snapshot_game_state()
	var saved_cfg := _snapshot_config()

	await _test_theme_and_all_10_ui_scenes(runner)
	await _test_main_router_all_11_routes_and_character_select_launch(runner)
	await _test_settings_menu_config_and_audio_sync(runner)
	await _test_honest_online_status_lobby_and_profile_binding(runner)
	await _test_arena_hud_pause_postmatch_and_spectator(runner)

	# Guaranteed cleanup & restoration
	runner.paused = false
	Engine.time_scale = 1.0
	_restore_game_state(saved_gs)
	_restore_config(saved_cfg)


func _snapshot_game_state() -> Dictionary:
	return {
		"is_online": GameState.is_online,
		"is_spectator": GameState.is_spectator,
		"auto_spawn_roster": GameState.auto_spawn_roster,
		"auto_quickplay": GameState.auto_quickplay,
		"selected_archetype": GameState.selected_archetype,
		"selected_mode": GameState.selected_mode,
		"selected_difficulty": GameState.selected_difficulty,
		"selected_difficulty_name": GameState.selected_difficulty_name,
		"match_mode": GameState.match_mode,
		"lobby_state": GameState.lobby_state.duplicate(true),
		"current_room_id": GameState.current_room_id,
		"current_room_code": GameState.current_room_code,
		"server_host": GameState.server_host,
		"server_udp_port": GameState.server_udp_port,
		"server_http_port": GameState.server_http_port,
	}


func _restore_game_state(snap: Dictionary) -> void:
	GameState.is_online = bool(snap["is_online"])
	GameState.is_spectator = bool(snap["is_spectator"])
	GameState.auto_spawn_roster = bool(snap["auto_spawn_roster"])
	GameState.auto_quickplay = bool(snap["auto_quickplay"])
	GameState.selected_archetype = str(snap["selected_archetype"])
	GameState.selected_mode = str(snap["selected_mode"])
	GameState.selected_difficulty = int(snap["selected_difficulty"])
	GameState.selected_difficulty_name = str(snap["selected_difficulty_name"])
	GameState.match_mode = str(snap["match_mode"])
	GameState.lobby_state = (snap["lobby_state"] as Dictionary).duplicate(true)
	GameState.current_room_id = int(snap["current_room_id"])
	GameState.current_room_code = str(snap["current_room_code"])
	GameState.server_host = str(snap["server_host"])
	GameState.server_udp_port = int(snap["server_udp_port"])
	GameState.server_http_port = int(snap["server_http_port"])


func _snapshot_config() -> Dictionary:
	var snap: Dictionary = {}
	for section in ConfigManager.settings.keys():
		snap[section] = (ConfigManager.settings[section] as Dictionary).duplicate(true)
	return snap


func _restore_config(snap: Dictionary) -> void:
	for section in snap.keys():
		ConfigManager.settings[section] = (snap[section] as Dictionary).duplicate(true)
	ConfigManager.apply_settings()
	var nc: Node = Engine.get_main_loop().root.get_node_or_null("NetClient") if Engine.get_main_loop() is SceneTree else null
	if nc != null:
		nc.set("host", str(ConfigManager.get_setting("network", "default_host", "127.0.0.1")))
		nc.set("udp_port", int(ConfigManager.get_setting("network", "default_udp_port", 7777)))
		nc.set("http_port", int(ConfigManager.get_setting("network", "default_http_port", 8080)))


# ==============================================================================
# 1. UIThemeBuilder & All 10 UI Scenes Clean Headless Instantiation
# ==============================================================================
func _test_theme_and_all_10_ui_scenes(runner: SceneTree) -> void:
	await runner.clear_stage()

	var theme: Theme = UIThemeBuilder.build_theme()
	runner.assert_not_null(theme, "UIThemeBuilder.build_theme() returns valid Theme")
	runner.assert_eq(UIThemeBuilder.MAIN_MENU_ROUTES.size(), 11, "UIThemeBuilder defines all 11 canonical routes")
	runner.assert_eq(UIThemeBuilder.format_clock(125.0), "02:05", "UIThemeBuilder.format_clock(125) == '02:05'")
	var div_prog: Dictionary = UIThemeBuilder.compute_division_progress(1950.0, "Diamond")
	runner.assert_eq(str(div_prog.get("name", "")), "Diamond", "UIThemeBuilder.compute_division_progress resolves Diamond")
	runner.assert_gt(float(div_prog.get("progress", 0.0)), 0.50, "Diamond 1950 progress > 50%")

	# Instantiate all 10 UI scenes cleanly in headless mode
	for spec in ALL_UI_SCENES:
		await runner.clear_stage()
		var sname: String = str(spec["name"])
		var spath: String = str(spec["path"])
		runner.assert_true(ResourceLoader.exists(spath), "UI scene exists: %s" % sname)
		var inst: Node = await runner.mount_scene(spath)
		runner.assert_not_null(inst, "UI scene instantiates cleanly in headless mode: %s" % sname)

		if sname == "main_menu" and inst is MainMenuUI:
			var mm := inst as MainMenuUI
			runner.assert_true(mm.get_selected_character_text().contains("SELECTED BALLER:"), "MainMenuUI displays selected character pill")
			mm.apply_health_status(false, {})
			runner.assert_false(mm.is_server_online(), "MainMenuUI starts offline when health fails")
			runner.assert_true(mm.get_server_status_text().contains("SERVER OFFLINE"), "MainMenuUI shows honest offline status")
			mm.apply_health_status(true, {"db_backend": "postgres", "active_players": 6, "rooms_count": 2})
			runner.assert_true(mm.is_server_online(), "MainMenuUI updates to online when health succeeds")
			runner.assert_true(mm.get_server_status_text().contains("postgres"), "MainMenuUI displays live db_backend")

		elif sname == "character_select" and inst is CharacterSelectUI:
			var cs := inst as CharacterSelectUI
			runner.assert_eq(cs.get_roster_count(), 5, "CharacterSelectUI populates all 5 ArchetypeRegistry ballers")
			runner.assert_not_null(cs.get_preview_animator(), "CharacterSelectUI mounts headless-safe 3D CharacterAnimator turntable")
			for aid in ArchetypeRegistry.ORDERED_IDS:
				cs.select_archetype(aid)
				runner.assert_eq(cs.get_selected_archetype_id(), aid, "CharacterSelectUI selects archetype '%s' cleanly" % aid)

		elif sname == "training_hud" and inst != null:
			var hud_root: Control = inst.get("_hud_root") as Control
			var has_theme: bool = (inst is Control and (inst as Control).theme != null) or (hud_root != null and hud_root.theme != null)
			runner.assert_true(has_theme, "TrainingHUD applies UIThemeBuilder theme cleanly")


# ==============================================================================
# 2. Full Main.navigate_to() Routing (All 11 Routes) & CharacterSelect Launch
# ==============================================================================
func _test_main_router_all_11_routes_and_character_select_launch(runner: SceneTree) -> void:
	await runner.clear_stage()
	GameState.auto_quickplay = false
	GameState.is_online = false
	GameState.is_spectator = false

	var main_node: Node = await runner.mount_scene(MAIN_SCENE_PATH)
	if not runner.assert_not_null(main_node, "Main scene boots cleanly"):
		return
	main_node.set("suppress_quit_in_tests", true)

	runner.assert_eq(str(main_node.call("get_current_route")), "main_menu", "Main boots directly into 'main_menu' route")
	runner.assert_true(main_node.call("get_active_scene") is MainMenuUI, "Main active scene on boot is MainMenuUI")

	var route_log: Array[String] = []
	var quit_hits := [0]
	main_node.connect("route_changed", func(r: String, _sc: Node) -> void:
		route_log.append(r)
	)
	main_node.connect("quit_requested", func() -> void:
		quit_hits[0] = int(quit_hits[0]) + 1
	)

	# Test child button signal routing from MainMenuUI -> character_select
	var mm := main_node.call("get_active_scene") as MainMenuUI
	var play_btn: Button = mm.find_child("PlayAIButton", true, false) as Button
	runner.assert_not_null(play_btn, "MainMenuUI exposes PlayAIButton")
	if play_btn != null:
		play_btn.pressed.emit()
		await runner.wait_physics_frames(2)
		runner.assert_eq(str(main_node.call("get_current_route")), "character_select", "Clicking PlayAIButton routes Main -> 'character_select'")
		runner.assert_true(main_node.call("get_active_scene") is CharacterSelectUI, "Active scene switched to CharacterSelectUI")

	# Test CharacterSelect -> Start Match ("play_offline") auto-spawning 2v2 AI roster + chosen archetype!
	var cs := main_node.call("get_active_scene") as CharacterSelectUI
	if cs != null:
		cs.select_archetype("sharpshooter")
		var mode_opt: OptionButton = cs.find_child("ModeSelector", true, false) as OptionButton
		var diff_opt: OptionButton = cs.find_child("DifficultySelector", true, false) as OptionButton
		runner.assert_not_null(mode_opt, "CharacterSelectUI exposes ModeSelector")
		runner.assert_not_null(diff_opt, "CharacterSelectUI exposes DifficultySelector")
		if mode_opt != null:
			mode_opt.select(1) # 2v2
		if diff_opt != null:
			diff_opt.select(3) # Phantom
		cs.call("_on_start_match_pressed")
		await runner.wait_physics_frames(3)

		runner.assert_eq(str(main_node.call("get_current_route")), "play_offline", "CharacterSelect Start Match routes Main -> 'play_offline'")
		runner.assert_false(GameState.is_online, "play_offline keeps GameState.is_online == false")
		runner.assert_false(GameState.auto_spawn_roster, "Arena resets GameState.auto_spawn_roster back to false after spawning")
		var arena := main_node.call("get_active_scene") as ArenaBuilder
		runner.assert_not_null(arena, "play_offline mounts ArenaBuilder")
		if arena != null:
			var total_players: int = arena.get_team_players(0).size() + arena.get_team_players(1).size()
			runner.assert_eq(total_players, 4, "CharacterSelect 2v2 auto-spawns 4 players on Arena (2v2)")
			var local_p := arena.get_node_or_null("Players/LocalPlayer") as PlayerController
			if local_p != null:
				runner.assert_eq(local_p.archetype_id, "sharpshooter", "Arena applies CharacterSelect archetype ('sharpshooter') to LocalPlayer")
			var ais: Array[AIController] = arena.get_ai_controllers()
			runner.assert_eq(ais.size(), 3, "2v2 match attaches 3 AIControllers (1 teammate + 2 opponents)")
			if ais.size() > 0:
				runner.assert_eq(ais[0].difficulty_tier, AIDifficulty.Tier.PHANTOM, "Arena applies CharacterSelect AI difficulty (Phantom)")

	# Test remaining canonical routes via Main.navigate_to()
	var ok_settings: bool = bool(main_node.call("navigate_to", "settings"))
	await runner.wait_physics_frames(1)
	runner.assert_true(ok_settings and str(main_node.call("get_current_route")) == "settings", "Route 'settings' loads SettingsMenuUI")
	runner.assert_true(main_node.call("get_active_scene") is SettingsMenuUI, "Active scene for 'settings' is SettingsMenuUI")

	var ok_training: bool = bool(main_node.call("navigate_to", "training"))
	await runner.wait_physics_frames(2)
	runner.assert_true(ok_training and str(main_node.call("get_current_route")) == "training", "Route 'training' loads PracticeArena")
	runner.assert_not_null(main_node.call("get_active_scene"), "Active scene for 'training' mounted cleanly")

	var ok_mm: bool = bool(main_node.call("navigate_to", "matchmaking"))
	await runner.wait_physics_frames(1)
	runner.assert_true(ok_mm and str(main_node.call("get_current_route")) == "matchmaking", "Route 'matchmaking' loads MatchmakingUI")
	runner.assert_true(main_node.call("get_active_scene") is MatchmakingUI, "Active scene for 'matchmaking' is MatchmakingUI")

	var sample_lobby := {
		"room_id": 42,
		"room_code": "PHNT0M",
		"mode": "2v2",
		"state": "Lobby",
		"fill_bots": true,
		"members": [
			{"member_id": "m1", "username": "Sora", "team": 0, "archetype": "sharpshooter", "ready": true, "is_bot": false},
			{"member_id": "m2", "username": "Volt", "team": 1, "archetype": "speedster", "ready": false, "is_bot": false},
		],
	}
	var ok_lobby: bool = bool(main_node.call("navigate_to", "lobby", {"lobby_state": sample_lobby}))
	await runner.wait_physics_frames(1)
	runner.assert_true(ok_lobby and str(main_node.call("get_current_route")) == "lobby", "Route 'lobby' loads LobbyUI")
	var lobby_sc := main_node.call("get_active_scene") as LobbyUI
	runner.assert_not_null(lobby_sc, "Active scene for 'lobby' is LobbyUI")
	if lobby_sc != null:
		runner.assert_eq(lobby_sc.get_displayed_room_code(), "PHNT0M", "Main.navigate_to('lobby', params) hydrates LobbyUI room code")
		runner.assert_eq(lobby_sc.get_team_a_count(), 1, "Main.navigate_to('lobby', params) hydrates Team A roster")
		runner.assert_eq(lobby_sc.get_team_b_count(), 1, "Main.navigate_to('lobby', params) hydrates Team B roster")

	var ok_prof: bool = bool(main_node.call("navigate_to", "profile_rankings"))
	await runner.wait_physics_frames(1)
	runner.assert_true(ok_prof and str(main_node.call("get_current_route")) == "profile_rankings", "Route 'profile_rankings' loads ProfileRankingsUI")
	runner.assert_true(main_node.call("get_active_scene") is ProfileRankingsUI, "Active scene for 'profile_rankings' is ProfileRankingsUI")

	var ok_online: bool = bool(main_node.call("navigate_to", "play_online", {"room_id": 7, "room_code": "ONLN99", "mode": "3v3"}))
	await runner.wait_physics_frames(2)
	runner.assert_true(ok_online and str(main_node.call("get_current_route")) == "play_online", "Route 'play_online' loads Arena")
	runner.assert_true(GameState.is_online, "Route 'play_online' sets GameState.is_online == true")
	runner.assert_false(GameState.is_spectator, "Route 'play_online' keeps GameState.is_spectator == false")
	runner.assert_eq(GameState.current_room_id, 7, "Route 'play_online' sets GameState.current_room_id")

	var ok_spec: bool = bool(main_node.call("navigate_to", "spectate", {"room_id": 9, "room_code": "SPEC01"}))
	await runner.wait_physics_frames(2)
	runner.assert_true(ok_spec and str(main_node.call("get_current_route")) == "spectate", "Route 'spectate' loads Arena in Spectator Mode")
	runner.assert_true(GameState.is_online and GameState.is_spectator, "Route 'spectate' sets is_online & is_spectator")
	var spec_arena := main_node.call("get_active_scene") as ArenaBuilder
	if spec_arena != null:
		runner.assert_true(spec_arena.is_spectator_mode_active(), "Route 'spectate' activates Arena spectator mode")
		var spec_cam: Camera3D = spec_arena.get_spectator_camera()
		runner.assert_not_null(spec_cam, "Route 'spectate' creates SpectatorBroadcastCamera")
		if spec_cam != null:
			runner.assert_true(spec_cam.current, "SpectatorBroadcastCamera is set current")
		var spec_hud := spec_arena.get_hud() as HUDController
		if spec_hud != null:
			runner.assert_true(spec_hud.is_spectator_banner_visible(), "Route 'spectate' displays HUD Spectator Mode banner")

	var ok_menu: bool = bool(main_node.call("navigate_to", "main_menu"))
	await runner.wait_physics_frames(1)
	runner.assert_true(ok_menu and str(main_node.call("get_current_route")) == "main_menu", "Route 'main_menu' returns cleanly to MainMenuUI")
	runner.assert_false(GameState.is_online, "Returning to 'main_menu' clears GameState.is_online")
	runner.assert_false(GameState.is_spectator, "Returning to 'main_menu' clears GameState.is_spectator")

	var ok_quit: bool = bool(main_node.call("navigate_to", "quit"))
	runner.assert_true(ok_quit, "Route 'quit' succeeds safely under suppress_quit_in_tests")
	runner.assert_eq(int(quit_hits[0]), 1, "Route 'quit' emits quit_requested without killing test runner")
	runner.assert_ge(float(route_log.size()), 9.0, "route_changed emitted across all scene transitions (count=%d)" % route_log.size())


# ==============================================================================
# 3. SettingsMenuUI — ConfigManager & Live AudioServer Bus Sync
# ==============================================================================
func _test_settings_menu_config_and_audio_sync(runner: SceneTree) -> void:
	await runner.clear_stage()
	# Ensure SoundManager creates Master/SFX/Music/Ambience buses cleanly
	var sm := SoundManager.new()
	sm.auto_start_music = false
	sm.auto_start_ambience = false
	runner._stage.add_child(sm)
	await runner.wait_physics_frames(1)

	var settings_ui := await runner.mount_scene("res://scenes/ui/settings_menu.tscn") as SettingsMenuUI
	if not runner.assert_not_null(settings_ui, "SettingsMenuUI mounts cleanly"):
		return

	var saved_hits := [0]
	settings_ui.settings_saved.connect(func() -> void:
		saved_hits[0] = int(saved_hits[0]) + 1
	)

	# Adjust sliders & options programmatically
	settings_ui._master_slider.value = 0.55
	settings_ui._sfx_slider.value = 0.45
	settings_ui._music_slider.value = 0.35
	settings_ui._ambience_slider.value = 0.50
	settings_ui._fov_slider.value = 80.0
	settings_ui._shake_slider.value = 0.50
	settings_ui._quality_opt.select(1) # medium
	settings_ui.save_settings_to_config(false)

	runner.assert_eq(int(saved_hits[0]), 1, "save_settings_to_config emits settings_saved")
	runner.assert_approx(float(ConfigManager.get_setting("audio", "master_volume", 0.0)), 0.55, 0.01, "SettingsMenuUI updates ConfigManager master_volume")
	runner.assert_approx(float(ConfigManager.get_setting("audio", "sfx_volume", 0.0)), 0.45, 0.01, "SettingsMenuUI updates ConfigManager sfx_volume")
	runner.assert_approx(float(ConfigManager.get_setting("audio", "music_volume", 0.0)), 0.35, 0.01, "SettingsMenuUI updates ConfigManager music_volume")
	runner.assert_approx(float(ConfigManager.get_setting("audio", "ambience_volume", 0.0)), 0.50, 0.01, "SettingsMenuUI updates ConfigManager ambience_volume")
	runner.assert_approx(float(ConfigManager.get_setting("gameplay", "camera_fov", 0.0)), 80.0, 0.1, "SettingsMenuUI updates ConfigManager camera_fov")
	runner.assert_approx(float(ConfigManager.get_setting("gameplay", "camera_shake_scale", 0.0)), 0.50, 0.01, "SettingsMenuUI updates ConfigManager camera_shake_scale")
	runner.assert_eq(str(ConfigManager.get_setting("graphics", "quality", "")), "medium", "SettingsMenuUI updates ConfigManager quality")

	# Verify AudioServer buses received the live linear volumes!
	runner.assert_approx(sm.get_bus_volume_linear("Master"), 0.55, 0.02, "AudioServer Master bus matches SettingsMenuUI (0.55)")
	runner.assert_approx(sm.get_bus_volume_linear("SFX"), 0.45, 0.02, "AudioServer SFX bus matches SettingsMenuUI (0.45)")
	runner.assert_approx(sm.get_bus_volume_linear("Music"), 0.35, 0.02, "AudioServer Music bus matches SettingsMenuUI (0.35)")
	runner.assert_approx(sm.get_bus_volume_linear("Ambience"), 0.50, 0.02, "AudioServer Ambience bus matches SettingsMenuUI (0.50)")

	# Reset defaults restores canonical values cleanly
	settings_ui.reset_defaults(false)
	runner.assert_approx(float(ConfigManager.get_setting("audio", "master_volume", 0.0)), 0.85, 0.01, "reset_defaults restores Master volume (0.85)")
	runner.assert_approx(float(ConfigManager.get_setting("audio", "sfx_volume", 0.0)), 0.90, 0.01, "reset_defaults restores SFX volume (0.90)")
	runner.assert_approx(float(ConfigManager.get_setting("audio", "music_volume", 0.0)), 0.70, 0.01, "reset_defaults restores Music volume (0.70)")
	runner.assert_approx(float(ConfigManager.get_setting("audio", "ambience_volume", 0.0)), 0.65, 0.01, "reset_defaults restores Ambience volume (0.65)")
	runner.assert_approx(float(ConfigManager.get_setting("gameplay", "camera_fov", 0.0)), 72.0, 0.1, "reset_defaults restores camera_fov (72.0)")
	runner.assert_eq(str(ConfigManager.get_setting("graphics", "quality", "")), "high", "reset_defaults restores graphics quality ('high')")
	runner.assert_approx(sm.get_bus_volume_linear("SFX"), 0.90, 0.02, "reset_defaults syncs AudioServer SFX bus back to 0.90")


# ==============================================================================
# 4. Honest Online Status & Live Matchmaking / Lobby / Profile / Leaderboard UI
# ==============================================================================
func _test_honest_online_status_lobby_and_profile_binding(runner: SceneTree) -> void:
	# 4A. MatchmakingUI: Honest offline gating + live online hydration
	await runner.clear_stage()
	var mm_ui := await runner.mount_scene("res://scenes/ui/matchmaking.tscn") as MatchmakingUI
	if runner.assert_not_null(mm_ui, "MatchmakingUI mounts cleanly"):
		mm_ui.apply_health_result(false, {})
		runner.assert_false(mm_ui.is_server_online(), "MatchmakingUI offline state == false")
		runner.assert_true(mm_ui.get_server_status_text().contains("SERVER OFFLINE"), "MatchmakingUI displays honest SERVER OFFLINE banner")
		runner.assert_false(mm_ui.are_queue_buttons_enabled(), "MatchmakingUI disables queue buttons while server offline")

		mm_ui.apply_health_result(true, {"db_backend": "postgres", "active_players": 12, "rooms_count": 3})
		runner.assert_true(mm_ui.is_server_online(), "MatchmakingUI switches online on healthy response")
		runner.assert_true(mm_ui.get_server_status_text().contains("ONLINE (postgres)"), "MatchmakingUI displays ONLINE (postgres)")
		runner.assert_true(mm_ui.are_queue_buttons_enabled(), "MatchmakingUI enables 1v1/2v2/3v3 queue buttons when online")

		mm_ui.populate_rooms([
			{"room_id": 10, "mode": "3v3", "room_code": "R00M10", "state": "Lobby", "player_count": 4, "max_players": 6},
			{"room_id": 11, "mode": "1v1", "room_code": "R00M11", "state": "InMatch", "player_count": 2, "max_players": 2},
		])
		runner.assert_eq(mm_ui.get_displayed_room_count(), 2, "MatchmakingUI populates live public & spectatable rooms")

		mm_ui.apply_health_result(false, {})
		runner.assert_eq(mm_ui.get_displayed_room_count(), 0, "Going offline clears stale room list cleanly")
		runner.assert_false(mm_ui.are_queue_buttons_enabled(), "Going offline re-disables queue buttons")

	# 4B. LobbyUI: EventBus.lobby_state_updated hydration & InMatch Enter Court unlock
	await runner.clear_stage()
	GameState.lobby_state = {}
	var lobby_ui := await runner.mount_scene("res://scenes/ui/lobby.tscn") as LobbyUI
	if runner.assert_not_null(lobby_ui, "LobbyUI mounts cleanly"):
		EventBus.lobby_state_updated.emit({
			"room_id": 55,
			"room_code": "AB12CD",
			"mode": "2v2",
			"state": "Lobby",
			"fill_bots": false,
			"members": [
				{"member_id": "a1", "username": "Volt", "team": 0, "archetype": "speedster", "ready": true, "is_bot": false},
				{"member_id": "a2", "username": "Mirage", "team": 0, "archetype": "playmaker", "ready": false, "is_bot": false},
				{"member_id": "b1", "username": "Titan", "team": 1, "archetype": "powerhouse", "ready": true, "is_bot": false},
				{"member_id": "b2", "username": "Deadeye", "team": 1, "archetype": "sharpshooter", "ready": true, "is_bot": true},
			],
		})
		runner.assert_eq(lobby_ui.get_displayed_room_code(), "AB12CD", "LobbyUI hydrates 6-char room code from EventBus.lobby_state_updated")
		runner.assert_eq(lobby_ui.get_displayed_state(), "Lobby", "LobbyUI displays 'Lobby' state")
		runner.assert_eq(lobby_ui.get_team_a_count(), 2, "LobbyUI displays 2 players on Team A")
		runner.assert_eq(lobby_ui.get_team_b_count(), 2, "LobbyUI displays 2 players on Team B")
		runner.assert_true(lobby_ui._enter_court_btn.disabled, "Enter Court button stays disabled while state == 'Lobby'")

		EventBus.lobby_state_updated.emit({
			"room_id": 55,
			"room_code": "AB12CD",
			"mode": "2v2",
			"state": "InMatch",
			"members": [],
		})
		runner.assert_eq(lobby_ui.get_displayed_state(), "InMatch", "LobbyUI updates to 'InMatch'")
		runner.assert_false(lobby_ui._enter_court_btn.disabled, "Enter Court button unlocks when state == 'InMatch'")

	# 4C. ProfileRankingsUI: Honest offline fallback + EventBus profile & leaderboard hydration
	await runner.clear_stage()
	var prof_ui := await runner.mount_scene("res://scenes/ui/profile_rankings.tscn") as ProfileRankingsUI
	if runner.assert_not_null(prof_ui, "ProfileRankingsUI mounts cleanly"):
		prof_ui.apply_health_result(false, {})
		runner.assert_false(prof_ui.is_server_online(), "ProfileRankingsUI starts offline when server unreachable")
		runner.assert_true(prof_ui.get_server_status_text().contains("SERVER OFFLINE"), "ProfileRankingsUI displays honest SERVER OFFLINE banner")
		runner.assert_true(prof_ui._lookup_btn.disabled, "Profile lookup disabled while server offline")
		runner.assert_true(prof_ui._refresh_lb_btn.disabled, "Leaderboard refresh disabled while server offline")

		prof_ui.apply_health_result(true, {"db_backend": "postgres"})
		runner.assert_true(prof_ui.is_server_online(), "ProfileRankingsUI switches online cleanly")
		runner.assert_false(prof_ui._lookup_btn.disabled, "Profile lookup enabled when online")
		runner.assert_false(prof_ui._refresh_lb_btn.disabled, "Leaderboard refresh enabled when online")

		EventBus.profile_loaded.emit({
			"username": "KaelenAce",
			"rating": 1950.0,
			"rating_deviation": 78.0,
			"peak_rating": 2010.0,
			"division": "Diamond",
			"wins": 14,
			"losses": 4,
			"matches_played": 18,
			"archetype_fav": "speedster",
			"total_points": 284,
			"total_assists": 42,
			"total_rebounds": 31,
			"total_blocks": 11,
			"total_steals": 29,
			"total_zone_activations": 24,
		})
		runner.assert_eq(prof_ui.get_displayed_profile_username(), "KaelenAce", "ProfileRankingsUI hydrates username from EventBus.profile_loaded")
		runner.assert_eq(prof_ui.get_displayed_division(), "Diamond", "ProfileRankingsUI hydrates Diamond division emblem")
		runner.assert_true(prof_ui._rating_label.text.contains("1950"), "ProfileRankingsUI displays Glicko-2 rating (1950)")

		EventBus.leaderboard_loaded.emit([
			{"rank": 1, "username": "PhantomKing", "division": "Phantom", "rating": 2280.0, "wins": 40, "losses": 5, "peak_rating": 2310.0, "archetype_fav": "playmaker"},
			{"rank": 2, "username": "KaelenAce",   "division": "Diamond", "rating": 1950.0, "wins": 14, "losses": 4, "peak_rating": 2010.0, "archetype_fav": "speedster"},
			{"rank": 3, "username": "TitanSlam",   "division": "Gold",    "rating": 1580.0, "wins": 9,  "losses": 6, "peak_rating": 1620.0, "archetype_fav": "powerhouse"},
		])
		runner.assert_eq(prof_ui.get_displayed_leaderboard_count(), 3, "ProfileRankingsUI populates 3 global leaderboard entries via EventBus.leaderboard_loaded")


# ==============================================================================
# 5. Live Arena HUDController, PauseMenuUI (Offline/Online), PostMatchUI & Spectator
# ==============================================================================
func _test_arena_hud_pause_postmatch_and_spectator(runner: SceneTree) -> void:
	await runner.clear_stage()
	GameState.is_online = false
	GameState.is_spectator = false
	GameState.auto_spawn_roster = false

	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as ArenaBuilder
	if not runner.assert_not_null(arena, "Live Arena mounts cleanly"):
		return
	await runner.wait_physics_frames(2)

	var hud := arena.get_hud() as HUDController
	var pause_menu := arena.get_pause_menu() as PauseMenuUI
	var post_match := arena.get_post_match_ui() as PostMatchUI
	var mc := arena.get_node_or_null("MatchController") as MatchController

	runner.assert_not_null(hud, "Arena.get_hud() mounts HUDController")
	runner.assert_not_null(pause_menu, "Arena.get_pause_menu() mounts PauseMenuUI")
	runner.assert_not_null(post_match, "Arena.get_post_match_ui() mounts PostMatchUI")
	runner.assert_not_null(mc, "Arena has MatchController")
	if hud == null or pause_menu == null or post_match == null or mc == null:
		return

	# Backward-compatibility contract: Phase1ScoreboardOverlay stays in tree but visually hidden!
	var legacy_overlay := mc.get_node_or_null("Phase1ScoreboardOverlay") as CanvasLayer
	runner.assert_not_null(legacy_overlay, "Phase1ScoreboardOverlay remains in tree for Phase 1–5 compatibility")
	if legacy_overlay != null:
		runner.assert_false(legacy_overlay.visible, "Phase1ScoreboardOverlay is visually hidden while HUDController is mounted")

	# 5A. HUDController live EventBus updates
	EventBus.score_changed.emit(0, 12, 3, true, 1)
	EventBus.score_changed.emit(1, 9, 2, false, 2)
	runner.assert_eq(hud.get_displayed_score_a(), 12, "HUDController updates Team A score (12)")
	runner.assert_eq(hud.get_displayed_score_b(), 9, "HUDController updates Team B score (9)")

	EventBus.timer_updated.emit(125.0, 4.2)
	runner.assert_eq(hud.get_displayed_clock(), "02:05", "HUDController formats match clock ('02:05')")
	runner.assert_eq(hud.get_displayed_shot_clock(), "4.2", "HUDController updates 24s shot clock ('4.2')")

	EventBus.stamina_updated.emit(1, 15.0, 100.0)
	runner.assert_approx(hud.get_stamina_percent(), 15.0, 0.1, "HUDController updates Stamina bar (15%)")

	EventBus.zone_meter_updated.emit(1, 100.0, 100.0)
	runner.assert_approx(hud.get_zone_percent(), 100.0, 0.1, "HUDController updates Zone meter (100%)")
	runner.assert_true(hud.is_zone_ready_displayed(), "HUDController displays ZONE READY at 100%")

	EventBus.zone_activated.emit(1, 12.0)
	runner.assert_true(hud.is_zone_active_displayed(), "HUDController switches to ZONE AWAKENED on zone_activated")
	runner.assert_false(hud.is_zone_ready_displayed(), "ZONE READY clears while Zone is active")
	EventBus.zone_ended.emit(1)
	runner.assert_false(hud.is_zone_active_displayed(), "HUDController clears ZONE AWAKENED on zone_ended")

	EventBus.combo_triggered.emit(1, "meteor_dunk", 3, true)
	var combo_txt: String = hud.get_displayed_combo_callout().to_upper()
	runner.assert_true(combo_txt.contains("METEOR DUNK"), "HUDController displays combo callout ('METEOR DUNK')")
	runner.assert_true(combo_txt.contains("PERFECT"), "HUDController annotates PERFECT combo timing")

	EventBus.shot_timing_feedback.emit(1, "Perfect", 0.004)
	runner.assert_true(hud.get_displayed_shot_feedback().to_upper().contains("PERFECT"), "HUDController displays shot timing release feedback")

	EventBus.net_metrics_updated.emit({"rtt_ms": 28.0, "packet_loss_pct": 0.5, "interp_delay_ms": 96.0})
	var pill: String = hud.get_net_pill_text()
	runner.assert_true(pill.contains("28") and pill.contains("96"), "HUDController displays online telemetry pill (RTT/Interp)")

	# 5B. PauseMenuUI — Offline pauses SceneTree + Restart enabled; Online NEVER pauses SceneTree + Restart disabled!
	runner.assert_false(pause_menu.is_pause_open(), "PauseMenuUI starts closed")
	GameState.is_online = false
	pause_menu.open_pause()
	runner.assert_true(pause_menu.is_pause_open(), "Offline open_pause() opens PauseMenuUI")
	runner.assert_true(runner.paused, "Offline open_pause() pauses SceneTree")
	runner.assert_true(pause_menu.is_restart_enabled(), "Offline PauseMenuUI enables Restart Match")

	# Embedded Settings opens & closes cleanly inside PauseMenu
	pause_menu.call("_on_settings_pressed")
	runner.assert_not_null(pause_menu._embedded_settings, "PauseMenuUI embeds SettingsMenuUI cleanly")
	pause_menu.call("_close_embedded_settings")
	runner.assert_true(pause_menu._embedded_settings == null, "Closing embedded settings restores PauseMenu card")

	pause_menu.close_pause()
	runner.assert_false(pause_menu.is_pause_open(), "close_pause() closes PauseMenuUI")
	runner.assert_false(runner.paused, "close_pause() unpauses SceneTree")

	# Online safety check!
	GameState.is_online = true
	pause_menu.open_pause()
	runner.assert_true(pause_menu.is_pause_open(), "Online open_pause() opens overlay")
	runner.assert_false(runner.paused, "ONLINE SAFETY: PauseMenuUI NEVER pauses SceneTree during online match!")
	runner.assert_false(pause_menu.is_restart_enabled(), "ONLINE SAFETY: PauseMenuUI disables/hides Restart during online match!")
	pause_menu.close_pause()
	GameState.is_online = false

	# 5C. MatchController live Box Score + PostMatchUI + Glicko-2 Delta + Offline Rematch
	mc.restart_match()
	await runner.wait_physics_frames(2)

	EventBus.score_changed.emit(0, 3, 3, true, 1)
	EventBus.combo_triggered.emit(1, "phantom_drive", 1, true)
	EventBus.zone_activated.emit(1, 12.0)
	EventBus.steal_performed.emit(1, 2, Vector3.ZERO)
	EventBus.block_performed.emit(1, 2, Vector3.ZERO)

	var p1_box: Dictionary = mc.get_player_box_score(1)
	runner.assert_ge(int(p1_box.get("points", 0)), 3, "MatchController tracks per-player points (actual=%d)" % int(p1_box.get("points", 0)))
	runner.assert_ge(int(p1_box.get("combos", 0)), 1, "MatchController tracks per-player combos")
	runner.assert_ge(int(p1_box.get("zone_activations", 0)), 1, "MatchController tracks per-player zone_activations")
	runner.assert_ge(int(p1_box.get("steals", 0)), 1, "MatchController tracks per-player steals")
	runner.assert_ge(int(p1_box.get("blocks", 0)), 1, "MatchController tracks per-player blocks")

	var box_players: Array[Dictionary] = mc.build_box_score_players_array()
	runner.assert_ge(float(box_players.size()), 1.0, "MatchController.build_box_score_players_array() exports live rows")

	# Augment with a 2nd player row + Glicko-2 delta and fire EventBus.match_ended
	var full_rows: Array = box_players.duplicate(true)
	full_rows.append({
		"player_id": 2, "team_id": 1, "username": "RivalAI", "archetype": "powerhouse",
		"points": 14, "three_pointers_made": 0, "assists": 2, "rebounds": 5,
		"steals": 1, "blocks": 2, "combos": 3, "zone_activations": 1,
	})
	var end_stats: Dictionary = {
		"players": full_rows,
		"is_online": false,
		"rating_delta": {
			"rating_before": 1500.0,
			"rating_after": 1662.3,
			"delta": 162.3,
			"division": "Gold",
		},
	}
	runner.assert_false(post_match.is_results_visible(), "PostMatchUI starts hidden before match_ended")
	EventBus.match_ended.emit(0, [21, 14], end_stats)

	runner.assert_true(post_match.is_results_visible(), "PostMatchUI opens automatically on EventBus.match_ended")
	runner.assert_eq(post_match.get_displayed_winner_text(), "TEAM A VICTORY", "PostMatchUI displays 'TEAM A VICTORY'")
	runner.assert_true(post_match.get_displayed_final_score().contains("21") and post_match.get_displayed_final_score().contains("14"), "PostMatchUI displays final score '21 — 14'")
	runner.assert_ge(float(post_match.get_box_score_row_count()), 2.0, "PostMatchUI renders per-player Box Score rows (count=%d)" % post_match.get_box_score_row_count())
	var rtxt: String = post_match.get_displayed_rating_delta_text()
	runner.assert_true(rtxt.contains("1500") and rtxt.contains("1662") and rtxt.contains("GOLD"), "PostMatchUI displays Glicko-2 rating delta card")

	# Offline Rematch triggers single clean restart_match() and hides PostMatchUI
	var restart_hits := [0]
	var on_restarted := func() -> void:
		restart_hits[0] = int(restart_hits[0]) + 1
	EventBus.match_restarted.connect(on_restarted)
	post_match.call("_on_rematch_pressed")
	await runner.wait_physics_frames(2)
	EventBus.match_restarted.disconnect(on_restarted)

	runner.assert_eq(int(restart_hits[0]), 1, "Offline PostMatchUI Rematch triggers match_restarted exactly once (no double-fire)")
	runner.assert_false(post_match.is_results_visible(), "Offline Rematch hides PostMatchUI cleanly")
	runner.assert_eq(hud.get_displayed_score_a(), 0, "Offline Rematch resets HUD Team A score to 0")
	runner.assert_eq(hud.get_displayed_score_b(), 0, "Offline Rematch resets HUD Team B score to 0")

	# 5D. Live Spectator Mode toggle on Arena
	arena.set_spectator_mode(true)
	runner.assert_true(arena.is_spectator_mode_active(), "Arena.set_spectator_mode(true) activates spectator mode")
	runner.assert_not_null(arena.get_spectator_camera(), "SpectatorBroadcastCamera mounted on Arena")
	if arena.get_spectator_camera() != null:
		runner.assert_true(arena.get_spectator_camera().current, "SpectatorBroadcastCamera set active")
	runner.assert_true(hud.is_spectator_banner_visible(), "HUDController displays Spectator banner")
	arena.set_spectator_mode(false)
	runner.assert_false(arena.is_spectator_mode_active(), "Arena.set_spectator_mode(false) exits spectator mode cleanly")
	runner.assert_false(hud.is_spectator_banner_visible(), "HUDController hides Spectator banner on exit")
