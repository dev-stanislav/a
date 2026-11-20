extends Node
## Phase 16 Automated Verification Suite — iOS Local Offline .ipa Edition & Touch Controls
## (PHANTOM COURT ONLINE)
## Verifies:
## 1. LocalCareer autoload (LocalCareerStore): genuine Glicko-2 math (starting 1500/350/0.06,
##    win/loss/RD shrinkage, Phantom vs Rookie upset delta, Bronze..Phantom divisions, 7-entry
##    Local League Table, reverse-chronological match history, and JSON disk persistence).
## 2. TouchControlsUI + live PlayerController/CameraRig integration: auto-visibility ("auto"/"on"/"off"),
##    all 11 buttons >= 64px, Zone ready pulsing, touch Pause toggle, stick deadzone + camera-relative
##    movement + outer-ring >= 0.85 auto-sprint, simultaneous touch camera swipe, AND touch-driven
##    Phantom Drive (Q, E, Q, Shift) with outer-ring auto-sprint retrigger firing via ComboEngine!
## 3. iOS Safe Area insets (iPhone 15 Pro landscape Dynamic Island + home bar) & idempotency +
##    Local Offline Mode UX across MainMenuUI, MatchmakingUI, ProfileRankingsUI, SettingsMenuUI,
##    and MatchController.end_match() -> LocalCareer -> PostMatchUI ("LOCAL CAREER GLICKO-2").
## 4. iOS packaging assets (all 6 PNG dimensions + opaque RGB8 icon_1024), export_presets.cfg
##    [preset.1] iOS configuration, and .github/workflows/build-ios-ipa.yml contract.

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"
const TEST_CAREER_PATH := "user://test_local_career_phase16.json"

const BTN_SPRINT: int  = 1
const BTN_SKILL_Q: int = 16
const BTN_SKILL_E: int = 32


func run(runner: SceneTree) -> void:
	# Snapshot global autoload state for zero side-effects
	var lc: Node = runner.root.get_node_or_null("LocalCareer")
	var orig_career_path: String = str(lc.call("get_save_path")) if lc != null and lc.has_method("get_save_path") else LocalCareerStore.DEFAULT_SAVE_PATH
	var orig_offline_mode: bool = GameState.offline_local_mode
	var orig_is_online: bool = GameState.is_online
	var orig_is_spectator: bool = GameState.is_spectator
	var orig_player_name: String = GameState.player_name
	var orig_arch: String = GameState.selected_archetype
	var orig_touch_mode: String = str(ConfigManager.get_setting("gameplay", "touch_controls_mode", "auto"))

	await _test_local_career_glicko2_and_persistence(runner)
	await _test_touch_controls_and_live_arena_gameplay(runner)
	await _test_safe_area_and_local_offline_ios_ux(runner)
	await _test_ios_assets_export_preset_and_workflow_contract(runner)

	# Guaranteed cleanup & state restoration
	runner.paused = false
	Engine.time_scale = 1.0
	GameState.offline_local_mode = orig_offline_mode
	GameState.is_online = orig_is_online
	GameState.is_spectator = orig_is_spectator
	GameState.player_name = orig_player_name
	GameState.selected_archetype = orig_arch
	ConfigManager.set_setting("gameplay", "touch_controls_mode", orig_touch_mode, false)
	if FileAccess.file_exists(TEST_CAREER_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CAREER_PATH))
	if lc != null and lc.has_method("set_save_path"):
		lc.call("set_save_path", orig_career_path, true)


# ==============================================================================
# 1. LocalCareer Offline Glicko-2 Store & Disk Persistence
# ==============================================================================
func _test_local_career_glicko2_and_persistence(runner: SceneTree) -> void:
	await runner.clear_stage()

	var lc: Node = runner.root.get_node_or_null("LocalCareer")
	if not runner.assert_not_null(lc, "LocalCareer autoload is mounted on /root"):
		return

	# Isolate test persistence file
	if FileAccess.file_exists(TEST_CAREER_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CAREER_PATH))
	lc.call("set_save_path", TEST_CAREER_PATH, true)
	lc.call("reset_career", false)

	var p0: Dictionary = lc.call("get_profile")
	runner.assert_approx(float(p0.get("rating", 0.0)), 1500.0, 0.01, "Fresh LocalCareer starts at rating 1500.0")
	runner.assert_approx(float(p0.get("rating_deviation", 0.0)), 350.0, 0.01, "Fresh LocalCareer starts at RD 350.0")
	runner.assert_approx(float(p0.get("volatility", 0.0)), 0.06, 0.001, "Fresh LocalCareer starts at volatility 0.06")
	runner.assert_eq(str(p0.get("division", "")), "Gold", "Rating 1500 starts in Gold division")
	runner.assert_eq(int(p0.get("matches_played", -1)), 0, "Fresh LocalCareer has 0 matches played")

	# Pure Glicko-2 mathematical invariants
	var win_rookie: Dictionary = LocalCareerStore.compute_glicko2_step(1500.0, 350.0, 0.06, 1150.0, 65.0, 1.0)
	var win_phantom: Dictionary = LocalCareerStore.compute_glicko2_step(1500.0, 350.0, 0.06, 2050.0, 65.0, 1.0)
	var loss_pro: Dictionary = LocalCareerStore.compute_glicko2_step(1500.0, 350.0, 0.06, 1450.0, 65.0, 0.0)

	var d_rookie: float = float(win_rookie["rating"]) - 1500.0
	var d_phantom: float = float(win_phantom["rating"]) - 1500.0
	var d_loss: float = float(loss_pro["rating"]) - 1500.0

	runner.assert_gt(d_rookie, 0.0, "Beating Rookie AI (1150) raises rating (+%.1f)" % d_rookie)
	runner.assert_gt(d_phantom, d_rookie + 50.0, "Beating Phantom AI (2050) yields much larger gain than Rookie (+%.1f > +%.1f)" % [d_phantom, d_rookie])
	runner.assert_lt(d_loss, -50.0, "Losing to Pro AI (1450) lowers rating (%.1f)" % d_loss)
	runner.assert_lt(float(win_phantom["rd"]), 350.0, "Playing a match shrinks rating deviation RD (%.1f < 350)" % float(win_phantom["rd"]))
	runner.assert_lt(float(loss_pro["rd"]), 350.0, "Loss also shrinks rating deviation RD (%.1f < 350)" % float(loss_pro["rd"]))

	# Division thresholds (Bronze .. Phantom)
	runner.assert_eq(LocalCareerStore.division_for_rating(1200.0), "Bronze", "1200 -> Bronze")
	runner.assert_eq(LocalCareerStore.division_for_rating(1400.0), "Silver", "1400 -> Silver")
	runner.assert_eq(LocalCareerStore.division_for_rating(1550.0), "Gold", "1550 -> Gold")
	runner.assert_eq(LocalCareerStore.division_for_rating(1750.0), "Platinum", "1750 -> Platinum")
	runner.assert_eq(LocalCareerStore.division_for_rating(1950.0), "Diamond", "1950 -> Diamond")
	runner.assert_eq(LocalCareerStore.division_for_rating(2150.0), "Phantom", "2150 -> Phantom")

	# Record live career matches & verify stats, history ordering, leaderboard merge, and JSON persistence
	lc.call("set_player_identity", "MobileBaller", "speedster")
	var upd1: Dictionary = lc.call("record_offline_match", "3v3", 0, 21, 10, {"points": 14, "three_pointers_made": 2, "assists": 4, "combos": 3, "zone_activations": 1}, 180)
	var upd2: Dictionary = lc.call("record_offline_match", "1v1", 3, 21, 18, {"points": 21, "three_pointers_made": 3, "steals": 2, "blocks": 1, "combos": 5, "zone_activations": 2}, 180)
	var upd3: Dictionary = lc.call("record_offline_match", "2v2", 2, 12, 19, {"points": 8, "rebounds": 4}, 180)

	runner.assert_gt(float(upd1["delta"]), 0.0, "Match 1 win delta > 0")
	runner.assert_gt(float(upd2["delta"]), float(upd1["delta"]), "Match 2 Phantom upset delta > Match 1 Rookie win delta")
	runner.assert_lt(float(upd3["delta"]), 0.0, "Match 3 loss delta < 0")

	var p_now: Dictionary = lc.call("get_profile")
	runner.assert_eq(str(p_now.get("username", "")), "MobileBaller", "Profile preserves custom callsign")
	runner.assert_eq(int(p_now.get("wins", 0)), 2, "Profile tracks 2 wins")
	runner.assert_eq(int(p_now.get("losses", 0)), 1, "Profile tracks 1 loss")
	runner.assert_eq(int(p_now.get("matches_played", 0)), 3, "Profile tracks 3 matches played")
	runner.assert_eq(int(p_now.get("total_points", 0)), 43, "Profile aggregates total points (14+21+8=43)")
	runner.assert_eq(int(p_now.get("total_combos", 0)), 8, "Profile aggregates total combos (3+5=8)")
	runner.assert_eq(int(p_now.get("total_zone_activations", 0)), 3, "Profile aggregates total Zone activations (1+2=3)")

	var hist: Array = lc.call("get_match_history", 10)
	runner.assert_eq(hist.size(), 3, "Match history stores all 3 recorded matches")
	if hist.size() == 3:
		runner.assert_eq(str((hist[0] as Dictionary).get("mode", "")), "2v2", "Most recent match appears first in history")
		runner.assert_false(bool((hist[0] as Dictionary).get("won", true)), "Most recent entry reflects loss")
		runner.assert_eq(str((hist[2] as Dictionary).get("mode", "")), "3v3", "Oldest match appears last in history")

	var lb: Array = lc.call("get_leaderboard")
	runner.assert_eq(lb.size(), 7, "Local League Table merges 6 AI rivals + local player (7 rows)")
	var local_rows: int = 0
	var prev_r: float = 99999.0
	var sorted_ok: bool = true
	for i in range(lb.size()):
		var row: Dictionary = lb[i] as Dictionary
		if int(row.get("rank", 0)) != i + 1:
			sorted_ok = false
		var rr: float = float(row.get("rating", 0.0))
		if rr > prev_r + 0.001:
			sorted_ok = false
		prev_r = rr
		if bool(row.get("is_local_player", false)):
			local_rows += 1
	runner.assert_true(sorted_ok, "Local League Table is ranked 1..7 strictly descending by Glicko-2 rating")
	runner.assert_eq(local_rows, 1, "Local League Table contains exactly 1 local player row")

	# Disk persistence roundtrip into a brand new LocalCareerStore instance!
	runner.assert_true(FileAccess.file_exists(TEST_CAREER_PATH), "LocalCareer persists JSON file to isolated save path")
	var fresh_store := LocalCareerStore.new()
	fresh_store.set_save_path(TEST_CAREER_PATH, false)
	var loaded: bool = fresh_store.load_from_disk()
	runner.assert_true(loaded, "Fresh LocalCareerStore reloads persisted JSON cleanly")
	var p_reloaded: Dictionary = fresh_store.get_profile()
	runner.assert_eq(str(p_reloaded.get("username", "")), "MobileBaller", "Reloaded profile preserves username")
	runner.assert_approx(float(p_reloaded.get("rating", 0.0)), float(p_now.get("rating", -1.0)), 0.01, "Reloaded profile preserves exact Glicko-2 rating")
	runner.assert_approx(float(p_reloaded.get("rating_deviation", 0.0)), float(p_now.get("rating_deviation", -1.0)), 0.01, "Reloaded profile preserves exact RD")
	runner.assert_eq(int(p_reloaded.get("total_points", 0)), 43, "Reloaded profile preserves career total_points")
	runner.assert_eq(fresh_store.get_match_history(10).size(), 3, "Reloaded store preserves all 3 history entries")
	fresh_store.free()


# ==============================================================================
# 2. TouchControlsUI + Live PlayerController / CameraRig / ComboEngine Integration
# ==============================================================================
func _test_touch_controls_and_live_arena_gameplay(runner: SceneTree) -> void:
	await runner.clear_stage()
	GameState.is_online = false
	GameState.is_spectator = false
	GameState.auto_spawn_roster = false
	ConfigManager.set_setting("gameplay", "touch_controls_mode", "auto", false)

	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as ArenaBuilder
	if not runner.assert_not_null(arena, "Touch test: Arena mounts cleanly"):
		return
	await runner.wait_physics_frames(2)

	var touch := arena.get_touch_controls() as TouchControlsUI
	var player := arena.get_node_or_null("Players/LocalPlayer") as PlayerController
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var pause_menu := arena.get_pause_menu() as PauseMenuUI
	if not runner.assert_not_null(touch, "Arena.get_touch_controls() mounts TouchControlsUI"):
		return
	if player == null or ball == null or pause_menu == null:
		runner.fail("Arena missing LocalPlayer/Basketball/PauseMenuUI")
		return

	# 2A. Auto-visibility logic & live ConfigManager reaction
	touch.clear_touch_override()
	if not OS.has_feature("ios") and not OS.has_feature("mobile"):
		runner.assert_false(touch.is_touch_active(), "TouchControlsUI hidden on PC when touch_controls_mode == 'auto'")
	ConfigManager.set_setting("gameplay", "touch_controls_mode", "on", false)
	runner.assert_true(touch.is_touch_active(), "TouchControlsUI becomes visible live when touch_controls_mode == 'on'")
	ConfigManager.set_setting("gameplay", "touch_controls_mode", "off", false)
	runner.assert_false(touch.is_touch_active(), "TouchControlsUI hides live when touch_controls_mode == 'off'")
	ConfigManager.set_setting("gameplay", "touch_controls_mode", "on", false)

	# 2B. All 11 ergonomic touch buttons >= 64x64px
	var btn_keys: Array[String] = [
		"shoot", "pass", "jump", "sprint", "steal", "stance",
		"skill_q", "skill_e", "skill_r", "zone", "pause",
	]
	var all_ge_64: bool = true
	for bk in btn_keys:
		var sz: Vector2 = touch.get_button_size(bk)
		if sz.x < 64.0 or sz.y < 64.0:
			all_ge_64 = false
			runner.fail("Touch button '%s' below 64px ergonomic minimum: %s" % [bk, str(sz)])
	runner.assert_true(all_ge_64, "All 11 touch controls buttons meet >= 64x64px ergonomic target")

	# 2C. Pulsing ZONE [V] button glow reactivity
	EventBus.zone_meter_updated.emit(1, 50.0, 100.0)
	runner.assert_false(touch.is_zone_button_ready_glowing(), "ZONE touch button does not glow at 50% energy")
	EventBus.zone_meter_updated.emit(1, 100.0, 100.0)
	runner.assert_true(touch.is_zone_button_ready_glowing(), "ZONE touch button pulses/glows at 100% ready")
	EventBus.zone_activated.emit(1, 12.0)
	runner.assert_true(touch.is_zone_button_ready_glowing(), "ZONE touch button stays glowing while Zone active")
	EventBus.zone_ended.emit(1)
	runner.assert_false(touch.is_zone_button_ready_glowing(), "ZONE touch button clears glow on zone_ended")

	# 2D. Touch Pause button toggles PauseMenuUI cleanly
	runner.assert_false(pause_menu.is_pause_open(), "PauseMenuUI closed before touch pause tap")
	touch.pause_pressed.emit()
	runner.assert_true(pause_menu.is_pause_open(), "TouchControlsUI.pause_pressed opens PauseMenuUI")
	touch.pause_pressed.emit()
	runner.assert_false(pause_menu.is_pause_open(), "Second touch pause tap closes PauseMenuUI")
	runner.assert_false(runner.paused, "SceneTree unpaused after closing PauseMenuUI")

	# 2E. Live multi-touch stick + deadzone + outer-ring sprint + simultaneous camera swipe
	player.set_external_input_provider(null)
	player.is_local_human = true
	player.apply_archetype_by_id("all_rounder")
	player.reset_for_match(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	ball.call("reset_to_free", Vector3(6.0, 0.5, 10.0))
	if player.camera_rig != null:
		player.camera_rig.set_yaw(0.0)
	await runner.wait_physics_frames(2)

	# Deadzone (< 0.12)
	touch.simulate_stick(Vector2(0.05, 0.05))
	var ov_dead: Dictionary = touch.get_touch_input_overlay()
	runner.assert_approx((ov_dead["move_local"] as Vector2).length(), 0.0, 0.001, "Stick deadzone (< 0.12) outputs zero movement")
	runner.assert_eq(int(ov_dead["buttons"]) & BTN_SPRINT, 0, "Stick inside deadzone does not engage auto-sprint")

	# Mid-ring run (0.60 < 0.85) -> moves forward camera-relatively without sprint
	var z_before_run: float = player.global_position.z
	touch.simulate_stick(Vector2(0.0, 0.60))
	runner.assert_eq(touch.get_active_buttons_mask() & BTN_SPRINT, 0, "Stick at 0.60 does not trigger outer-ring sprint")
	await runner.wait_physics_frames(20)
	runner.assert_lt(player.global_position.z, z_before_run - 0.8, "Touch stick forward drives camera-relative -Z run movement (dz=%.2fm)" % (player.global_position.z - z_before_run))

	# Outer-ring (>= 0.85) -> auto-engages BTN_SPRINT + simultaneous touch camera swipe rotates CameraRig yaw!
	var yaw_before: float = player.camera_rig.get_yaw() if player.camera_rig != null else 0.0
	touch.simulate_stick(Vector2(0.0, 0.95))
	runner.assert_eq(touch.get_active_buttons_mask() & BTN_SPRINT, BTN_SPRINT, "Stick outer ring (>= 0.85) auto-engages BTN_SPRINT")
	touch.simulate_camera_drag(Vector2(140.0, 0.0))
	await runner.wait_physics_frames(22)
	var yaw_after: float = player.camera_rig.get_yaw() if player.camera_rig != null else 0.0
	var horiz_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
	runner.assert_gt(absf(yaw_after - yaw_before), 0.10, "Simultaneous touch camera drag rotates CameraRig yaw (dyaw=%.3f rad)" % (yaw_after - yaw_before))
	runner.assert_gt(horiz_speed, 7.2, "Outer-ring touch auto-sprint reaches sprint velocity (actual=%.2f m/s)" % horiz_speed)
	runner.assert_approx(touch.consume_camera_delta().length(), 0.0, 0.001, "CameraRig consumed touch camera delta cleanly")

	# 2F. Real Touch-Driven Fighting-Game Combo: Phantom Drive (Q -> E -> Q -> Shift) WITH Outer-Ring Sprint Held!
	touch.clear_simulated_inputs()
	if player.camera_rig != null:
		player.camera_rig.set_yaw(0.0)
	player.reset_for_match(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0)))
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(3)

	var triggered_combos: Array[String] = []
	var on_combo := func(pid: int, cid: String, _tier: int, _perf: bool) -> void:
		if pid == 1:
			triggered_combos.append(cid)
	EventBus.combo_triggered.connect(on_combo)

	# Hold full outer-ring sprint continuously while tapping Q -> E -> Q -> Sprint button!
	touch.simulate_stick(Vector2(0.0, 0.95))
	await runner.wait_physics_frames(3)

	for btn_bit in [BTN_SKILL_Q, BTN_SKILL_E, BTN_SKILL_Q]:
		touch.simulate_button(btn_bit, true)
		await runner.wait_physics_frames(2)
		touch.simulate_button(btn_bit, false)
		await runner.wait_physics_frames(4)

	# Tap right-thumb SPRINT button (hold 3 frames so PlayerController's 1-tick release/retrigger fires cleanly!)
	touch.simulate_button(BTN_SPRINT, true)
	await runner.wait_physics_frames(4)
	touch.simulate_button(BTN_SPRINT, false)
	await runner.wait_physics_frames(5)

	EventBus.combo_triggered.disconnect(on_combo)
	touch.clear_simulated_inputs()

	runner.assert_true(
		triggered_combos.has("phantom_drive"),
		"LIVE TOUCH COMBO: Outer-ring stick sprint + Q->E->Q->Sprint button fires Phantom Drive via ComboEngine (seen=%s)" % str(triggered_combos)
	)


# ==============================================================================
# 3. Safe Area Insets & Local Offline iOS Mode UX
# ==============================================================================
func _test_safe_area_and_local_offline_ios_ux(runner: SceneTree) -> void:
	await runner.clear_stage()

	# 3A. Simulated iPhone 15 Pro Landscape Safe Area (2556x1179 screen, Dynamic Island + Home Indicator)
	var vp_size := Vector2(1280.0, 590.0)
	var display_size := Vector2i(2556, 1179)
	var safe_rect := Rect2i(177, 0, 2202, 1116)
	var insets: Dictionary = UIThemeBuilder.compute_safe_area_insets(vp_size, safe_rect, display_size)

	runner.assert_approx(float(insets["left"]), 88.64, 1.5, "iPhone 15 Pro landscape left Dynamic Island inset scales accurately")
	runner.assert_approx(float(insets["right"]), 88.64, 1.5, "iPhone 15 Pro landscape right inset scales accurately")
	runner.assert_approx(float(insets["top"]), 0.0, 0.5, "iPhone 15 Pro landscape top inset == 0")
	runner.assert_approx(float(insets["bottom"]), 31.53, 1.5, "iPhone 15 Pro landscape bottom home-bar inset scales accurately")

	# Idempotency check on MarginContainer
	var mc_ui := MarginContainer.new()
	mc_ui.add_theme_constant_override("margin_left", 16)
	mc_ui.add_theme_constant_override("margin_bottom", 12)
	runner._stage.add_child(mc_ui)
	UIThemeBuilder.apply_safe_area_margins(mc_ui, 12, insets)
	var left_once: int = mc_ui.get_theme_constant("margin_left")
	var bottom_once: int = mc_ui.get_theme_constant("margin_bottom")
	UIThemeBuilder.apply_safe_area_margins(mc_ui, 12, insets)
	var left_twice: int = mc_ui.get_theme_constant("margin_left")
	var bottom_twice: int = mc_ui.get_theme_constant("margin_bottom")

	runner.assert_gt(float(left_once), 95.0, "apply_safe_area_margins adds left safe inset to base margin (%d)" % left_once)
	runner.assert_eq(left_once, left_twice, "apply_safe_area_margins is strictly idempotent on margin_left")
	runner.assert_eq(bottom_once, bottom_twice, "apply_safe_area_margins is strictly idempotent on margin_bottom")

	# 3B. Enable Local Offline iOS Edition mode & test all screens
	var lc: Node = runner.root.get_node_or_null("LocalCareer")
	lc.call("set_save_path", TEST_CAREER_PATH, true)
	lc.call("reset_career", true)
	GameState.set_offline_local_mode(true)
	runner.assert_true(UIThemeBuilder.is_local_offline_build(), "UIThemeBuilder.is_local_offline_build() reflects GameState.offline_local_mode")

	# MainMenuUI
	await runner.clear_stage()
	var mm := await runner.mount_scene("res://scenes/ui/main_menu.tscn") as MainMenuUI
	if runner.assert_not_null(mm, "Offline Mode: MainMenuUI mounts cleanly"):
		runner.assert_false(mm.is_server_online(), "MainMenuUI reports offline in Local Offline Edition")
		runner.assert_true(mm.get_server_status_text().to_upper().contains("LOCAL OFFLINE EDITION"), "MainMenuUI displays 'LOCAL OFFLINE EDITION' badge")

	# MatchmakingUI
	await runner.clear_stage()
	var mmu := await runner.mount_scene("res://scenes/ui/matchmaking.tscn") as MatchmakingUI
	if runner.assert_not_null(mmu, "Offline Mode: MatchmakingUI mounts cleanly"):
		runner.assert_true(mmu.get_server_status_text().to_upper().contains("LOCAL OFFLINE"), "MatchmakingUI shows honest Local Offline Build notice")
		runner.assert_false(mmu.are_queue_buttons_enabled(), "MatchmakingUI disables online queues in Local Offline Edition")

	# ProfileRankingsUI hydrated from /root/LocalCareer
	await runner.clear_stage()
	var prof := await runner.mount_scene("res://scenes/ui/profile_rankings.tscn") as ProfileRankingsUI
	if runner.assert_not_null(prof, "Offline Mode: ProfileRankingsUI mounts cleanly"):
		runner.assert_true(prof.is_using_local_career(), "ProfileRankingsUI binds directly to /root/LocalCareer")
		runner.assert_eq(prof.get_displayed_leaderboard_count(), 7, "ProfileRankingsUI renders 7-row Local League Table")
		var saved_ok: bool = prof.save_local_career_identity("iOSAcer", "playmaker")
		runner.assert_true(saved_ok, "ProfileRankingsUI saves custom Local Career callsign & favorite archetype")
		runner.assert_eq(prof.get_displayed_profile_username(), "iOSAcer", "ProfileRankingsUI immediately reflects updated callsign")
		var stored_prof: Dictionary = lc.call("get_profile")
		runner.assert_eq(str(stored_prof.get("username", "")), "iOSAcer", "/root/LocalCareer persisted 'iOSAcer'")
		runner.assert_eq(str(stored_prof.get("archetype_fav", "")), "playmaker", "/root/LocalCareer persisted 'playmaker'")

	# SettingsMenuUI TouchControlsOption
	await runner.clear_stage()
	var sm_ui := await runner.mount_scene("res://scenes/ui/settings_menu.tscn") as SettingsMenuUI
	if runner.assert_not_null(sm_ui, "Offline Mode: SettingsMenuUI mounts cleanly"):
		var touch_opt: OptionButton = sm_ui.find_child("TouchControlsOption", true, false) as OptionButton
		runner.assert_not_null(touch_opt, "SettingsMenuUI exposes TouchControlsOption selector")
		if touch_opt != null:
			touch_opt.select(1) # "on"
			sm_ui.save_settings_to_config(false)
			runner.assert_eq(sm_ui.get_selected_touch_controls_mode(), "on", "SettingsMenuUI selects touch_controls_mode 'on'")
			runner.assert_eq(str(ConfigManager.get_setting("gameplay", "touch_controls_mode", "")), "on", "ConfigManager updated to touch_controls_mode 'on'")
			sm_ui.reset_defaults(false)
			runner.assert_eq(sm_ui.get_selected_touch_controls_mode(), "auto", "SettingsMenuUI reset_defaults restores touch_controls_mode 'auto'")

	# MatchController.end_match() -> LocalCareer -> PostMatchUI ("LOCAL CAREER GLICKO-2")
	await runner.clear_stage()
	GameState.is_online = false
	GameState.is_spectator = false
	GameState.selected_difficulty = 3 # Phantom AI
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as ArenaBuilder
	if runner.assert_not_null(arena, "Offline Career E2E: Arena mounts cleanly"):
		await runner.wait_physics_frames(2)
		var mc := arena.get_node_or_null("MatchController") as MatchController
		var pm := arena.get_post_match_ui() as PostMatchUI
		if mc != null and pm != null:
			var before_matches: int = int((lc.call("get_profile") as Dictionary).get("matches_played", 0))
			GameState.set_team_score(0, 21, 2, false, 1)
			GameState.set_team_score(1, 14, 2, false, 2)
			mc.end_match()
			await runner.wait_physics_frames(1)

			var after_prof: Dictionary = lc.call("get_profile")
			var last_upd: Dictionary = mc.get_last_career_rating_update()
			runner.assert_eq(int(after_prof.get("matches_played", 0)), before_matches + 1, "MatchController.end_match() records offline match into /root/LocalCareer")
			runner.assert_gt(float(last_upd.get("delta", 0.0)), 0.0, "MatchController records positive Glicko-2 delta on win (+%.1f)" % float(last_upd.get("delta", 0.0)))
			runner.assert_true(pm.is_results_visible(), "PostMatchUI opens automatically on MatchController.end_match()")
			runner.assert_true(
				pm.get_displayed_rating_delta_text().contains("LOCAL CAREER GLICKO-2"),
				"PostMatchUI displays 'LOCAL CAREER GLICKO-2' rating delta card (text='%s')" % pm.get_displayed_rating_delta_text()
			)


# ==============================================================================
# 4. iOS Assets, Export Presets & GitHub Actions Workflow Contract
# ==============================================================================
func _test_ios_assets_export_preset_and_workflow_contract(runner: SceneTree) -> void:
	await runner.clear_stage()

	# 4A. All 6 branded iOS PNGs exist, load cleanly, exact dimensions, opaque RGB8 1024 icon
	var expected_assets: Array[Dictionary] = [
		{"path": "res://assets/ios/icon_120.png",      "w": 120,  "h": 120,  "opaque": true},
		{"path": "res://assets/ios/icon_152.png",      "w": 152,  "h": 152,  "opaque": true},
		{"path": "res://assets/ios/icon_167.png",      "w": 167,  "h": 167,  "opaque": true},
		{"path": "res://assets/ios/icon_180.png",      "w": 180,  "h": 180,  "opaque": true},
		{"path": "res://assets/ios/icon_1024.png",     "w": 1024, "h": 1024, "opaque": true},
		{"path": "res://assets/ios/launch_splash.png", "w": 1280, "h": 720,  "opaque": true},
	]
	for spec in expected_assets:
		var apath: String = str(spec["path"])
		var abs_path: String = ProjectSettings.globalize_path(apath)
		runner.assert_true(FileAccess.file_exists(abs_path), "iOS asset exists on disk: %s" % apath.get_file())
		var img := Image.new()
		var err: int = img.load(abs_path)
		runner.assert_eq(err, OK, "iOS asset decodes cleanly as PNG: %s" % apath.get_file())
		if err == OK:
			runner.assert_eq(img.get_width(), int(spec["w"]), "%s width == %d" % [apath.get_file(), int(spec["w"])])
			runner.assert_eq(img.get_height(), int(spec["h"]), "%s height == %d" % [apath.get_file(), int(spec["h"])])
			if bool(spec["opaque"]):
				runner.assert_eq(img.get_format(), Image.FORMAT_RGB8, "%s is opaque RGB8 (Apple actool safe)" % apath.get_file())

	# 4B. client/export_presets.cfg [preset.1] iOS contract
	var preset_path: String = ProjectSettings.globalize_path("res://export_presets.cfg")
	runner.assert_true(FileAccess.file_exists(preset_path), "client/export_presets.cfg exists")
	if FileAccess.file_exists(preset_path):
		var cfg := ConfigFile.new()
		var perr: int = cfg.load(preset_path)
		runner.assert_eq(perr, OK, "client/export_presets.cfg parses cleanly via ConfigFile")
		if perr == OK:
			runner.assert_eq(str(cfg.get_value("preset.1", "name", "")), "iOS", "preset.1 is named 'iOS'")
			runner.assert_eq(str(cfg.get_value("preset.1", "platform", "")), "iOS", "preset.1 platform is 'iOS'")
			runner.assert_eq(str(cfg.get_value("preset.1.options", "application/bundle_identifier", "")), "com.phantomcourt.online", "iOS bundle_identifier == com.phantomcourt.online")
			runner.assert_true(bool(cfg.get_value("preset.1.options", "architectures/arm64", false)), "iOS architectures/arm64 == true")
			runner.assert_true(bool(cfg.get_value("preset.1.options", "application/export_project_only", false)), "iOS export_project_only == true (for unsigned xcodebuild)")
			runner.assert_true(bool(cfg.get_value("preset.1.options", "orientation/landscape_left", false)), "iOS landscape_left enabled")
			runner.assert_true(bool(cfg.get_value("preset.1.options", "orientation/landscape_right", false)), "iOS landscape_right enabled")
			runner.assert_false(bool(cfg.get_value("preset.1.options", "orientation/portrait", true)), "iOS portrait disabled")
			runner.assert_eq(str(cfg.get_value("preset.1.options", "icons/icon_1024x1024", "")), "res://assets/ios/icon_1024.png", "iOS icon_1024x1024 wired cleanly")
			runner.assert_eq(str(cfg.get_value("preset.1.options", "storyboard/custom_image@2x", "")), "res://assets/ios/launch_splash.png", "iOS launch storyboard wired cleanly")

	# 4C. GitHub Actions workflow contract (.github/workflows/build-ios-ipa.yml)
	var repo_root: String = ProjectSettings.globalize_path("res://").get_base_dir().get_base_dir()
	var wf_path: String = repo_root.path_join(".github/workflows/build-ios-ipa.yml")
	runner.assert_true(FileAccess.file_exists(wf_path), ".github/workflows/build-ios-ipa.yml exists")
	if FileAccess.file_exists(wf_path):
		var wf_txt: String = FileAccess.get_file_as_string(wf_path)
		runner.assert_true(wf_txt.contains("macos-latest"), "Workflow runs on macos-latest")
		runner.assert_true(wf_txt.contains("Godot_v4.7.2-stable_macos.universal.zip"), "Workflow uses verified Godot 4.7.2-stable macOS Universal URL")
		runner.assert_true(wf_txt.contains("Godot_v4.7.2-stable_export_templates.tpz"), "Workflow uses verified Godot 4.7.2-stable export templates URL")
		runner.assert_true(wf_txt.contains("--export-release \"iOS\""), "Workflow exports Godot iOS release project")
		runner.assert_true(wf_txt.contains("xcodebuild") and wf_txt.contains("CODE_SIGNING_ALLOWED=NO"), "Workflow compiles unsigned arm64 app via xcodebuild")
		runner.assert_true(wf_txt.contains("PhantomCourtOnline-iOS-unsigned.ipa"), "Workflow packages and uploads PhantomCourtOnline-iOS-unsigned.ipa")
