extends Node
## Phase 11 Automated Verification Suite — Skill Training (Practice Arena & Dojo HUD)
## (PHANTOM COURT ONLINE)
## Verifies:
## 1. PracticeArena scene boot, continuous training mode (match/shot clock paused),
##    and automatic TrainingHUD binding + standalone TrainingHUD instantiation.
## 2. Combo Tutorials (all 4 universal + all 5 archetype unique skills), auto archetype
##    switching, live step-by-step highlight progression (done/active/pending), live
##    input history tape with EARLY/PERFECT/LATE/START tags, and combo/shot timing analysis
##    reflected in TrainingHUD.
## 3. 5-Spot Shot Practice: all 5 court spots, physical made basket recording, streak &
##    make% tracking, and automatic ball return (auto_return_ball).
## 4. Programmable Defensive Dummy: all 6 modes (IDLE, STANCE_CONTEST, JUMP_BLOCK,
##    STEAL_INTERVAL, MIRROR_GUARD, LIVE_PHANTOM_AI) verified on-court.
## 5. Timed Combo Challenges (S/A/B/C/FAIL grading, live completions, score) +
##    MasteryTracker isolated JSON disk persistence roundtrip (cleaned up on teardown).

const PRACTICE_ARENA_SCENE_PATH := "res://scenes/training/practice_arena.tscn"
const TRAINING_HUD_SCENE_PATH := "res://scenes/ui/training_hud.tscn"
const TEST_MASTERY_PATH := "user://test_skill_mastery_phase11.json"

const BTN_SPRINT: int  = 1
const BTN_JUMP: int    = 2
const BTN_SHOOT: int   = 4
const BTN_SKILL_Q: int = 16
const BTN_SKILL_E: int = 32
const BTN_SKILL_R: int = 64
const BTN_STEAL: int   = 128
const BTN_STANCE: int  = 512


func run(runner: SceneTree) -> void:
	_cleanup_test_mastery_file()
	await _test_practice_arena_boot_and_hud_binding(runner)
	await _test_combo_tutorials_input_history_and_timing(runner)
	await _test_five_spot_shot_practice(runner)
	await _test_all_six_defensive_dummy_modes(runner)
	await _test_combo_challenges_and_mastery_persistence(runner)
	_cleanup_test_mastery_file()


func _cleanup_test_mastery_file() -> void:
	if FileAccess.file_exists(TEST_MASTERY_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_MASTERY_PATH))


func _make_input_controller(player: Node3D) -> Dictionary:
	var ctrl := {
		"local_dir": Vector2.ZERO,
		"move_world_xz": Vector2.ZERO,
		"buttons": 0,
		"aim_yaw": 0.0,
		"seq": 0,
	}
	player.call("set_external_input_provider", func(tick: int, _dt: float) -> Dictionary:
		ctrl["seq"] = int(ctrl["seq"]) + 1
		return {
			"seq": int(ctrl["seq"]),
			"tick": tick,
			"move_world_xz": ctrl["move_world_xz"],
			"local_dir": ctrl["local_dir"],
			"buttons": int(ctrl["buttons"]),
			"aim_yaw": float(ctrl["aim_yaw"]),
		}
	)
	return ctrl


func _feed_input_steps(
	runner: SceneTree,
	ctrl: Dictionary,
	steps: Array[Dictionary],
	gap_frames: int
) -> void:
	for i in range(steps.size()):
		var st: Dictionary = steps[i]
		ctrl["buttons"] = int(st.get("buttons", 0))
		ctrl["local_dir"] = st.get("local_dir", Vector2.ZERO)
		await runner.wait_physics_frames(1)
		ctrl["buttons"] = 0
		ctrl["local_dir"] = Vector2.ZERO
		if i < steps.size() - 1:
			await runner.wait_physics_frames(maxi(1, gap_frames - 1))


# ==============================================================================
# 1. PracticeArena Boot, Match Timer Pause & TrainingHUD Auto-Binding
# ==============================================================================
func _test_practice_arena_boot_and_hud_binding(runner: SceneTree) -> void:
	await runner.clear_stage()

	# Verify standalone TrainingHUD instantiates cleanly without controller
	var standalone_hud := await runner.mount_scene(TRAINING_HUD_SCENE_PATH) as CanvasLayer
	runner.assert_not_null(standalone_hud, "Standalone training_hud.tscn instantiates cleanly")
	if standalone_hud != null:
		runner.assert_true(standalone_hud is TrainingHUD, "TrainingHUD script attached properly")
		runner.assert_eq(int(standalone_hud.call("get_displayed_input_history_count")), 0, "Standalone HUD input history starts empty")

	# Mount full PracticeArena scene
	await runner.clear_stage()
	var practice := await runner.mount_scene(PRACTICE_ARENA_SCENE_PATH) as Node3D
	if not runner.assert_not_null(practice, "practice_arena.tscn mounts cleanly"):
		return
	runner.assert_true(practice is PracticeArenaController, "Root node is PracticeArenaController")
	runner.assert_not_null(practice.call("get_arena"), "PracticeArena mounts Arena")
	runner.assert_not_null(practice.call("get_player"), "PracticeArena mounts LocalPlayer")
	runner.assert_not_null(practice.call("get_dummy_player"), "PracticeArena mounts DummyDefender")
	runner.assert_not_null(practice.call("get_dummy"), "PracticeArena mounts DefensiveDummy")
	runner.assert_not_null(practice.call("get_combo_trainer"), "PracticeArena mounts ComboTrainer")
	runner.assert_not_null(practice.call("get_mastery_tracker"), "PracticeArena initializes MasteryTracker")
	runner.assert_not_null(practice.call("get_hud"), "PracticeArena automatically mounts & binds TrainingHUD")

	# Isolate mastery tracker onto test path immediately
	var mt: MasteryTracker = practice.call("get_mastery_tracker")
	mt.set_save_path(TEST_MASTERY_PATH)
	mt.reset_stats()

	# Verify continuous training mode freezes match & shot clock timers over 60 physics frames (1.0s)
	var t_match_0: float = GameState.match_seconds_left
	var t_shot_0: float = GameState.shot_clock_left
	await runner.wait_physics_frames(60)
	runner.assert_approx(GameState.match_seconds_left, t_match_0, 0.05, "PracticeArena pauses match countdown timer")
	runner.assert_approx(GameState.shot_clock_left, t_shot_0, 0.05, "PracticeArena pauses 24s shot clock timer")

	# Verify initial TrainingHUD binding state
	var hud: Node = practice.call("get_hud")
	runner.assert_eq(String(hud.call("get_displayed_tutorial_move")), "phantom_drive", "Bound TrainingHUD defaults to 'phantom_drive' tutorial")
	runner.assert_eq(String(hud.call("get_displayed_dummy_mode")), "Idle", "Bound TrainingHUD displays 'Idle' dummy mode")


# ==============================================================================
# 2. Combo Tutorials, Step Highlighting, Live Input History & Timing Analysis
# ==============================================================================
func _test_combo_tutorials_input_history_and_timing(runner: SceneTree) -> void:
	await runner.clear_stage()
	var practice := await runner.mount_scene(PRACTICE_ARENA_SCENE_PATH) as Node3D
	var player: CharacterBody3D = practice.call("get_player")
	var trainer: ComboTrainer = practice.call("get_combo_trainer")
	var mt: MasteryTracker = practice.call("get_mastery_tracker")
	var hud: Node = practice.call("get_hud")
	mt.set_save_path(TEST_MASTERY_PATH)
	mt.reset_stats()

	# Verify all 9 tutorials registered (4 universal + 5 archetype unique)
	var avail: Array = trainer.get_available_tutorials()
	runner.assert_eq(avail.size(), 9, "ComboTrainer exposes all 9 tutorials (4 universal + 5 archetype)")

	# Verify selecting archetype-unique tutorials auto-switches player archetype
	var arch_tutorials := [
		["volt_dash", "speedster"],
		["starlight_high_arc", "sharpshooter"],
		["mirage_thread", "playmaker"],
		["tectonic_slam", "powerhouse"],
		["eclipse_counter", "all_rounder"],
	]
	for pair in arch_tutorials:
		practice.call("select_tutorial", String(pair[0]))
		runner.assert_eq(String(player.get("archetype_id")), String(pair[1]), "Selecting '%s' auto-switches player to '%s'" % [String(pair[0]), String(pair[1])])
		runner.assert_eq(String(hud.call("get_displayed_tutorial_move")), String(pair[0]), "TrainingHUD updates displayed tutorial to '%s'" % String(pair[0]))

	# Live step-by-step highlight progression on Phantom Drive (Q -> E -> Q -> Shift)
	practice.call("select_tutorial", "phantom_drive")
	practice.call("reset_drill_positions")
	trainer.clear_input_history()
	var ctrl := _make_input_controller(player)
	await runner.wait_physics_frames(2)

	var st0: Dictionary = trainer.get_tutorial_state()
	runner.assert_eq(st0["step_statuses"], ["active", "pending", "pending", "pending"], "Phantom Drive starts with step 0 active")
	runner.assert_eq(hud.call("get_displayed_prompt_statuses"), ["active", "pending", "pending", "pending"], "TrainingHUD prompt chips match initial statuses")

	# Step 1: Q -> ["done", "active", "pending", "pending"]
	ctrl["buttons"] = BTN_SKILL_Q
	await runner.wait_physics_frames(1)
	ctrl["buttons"] = 0
	var st1: Dictionary = trainer.get_tutorial_state()
	runner.assert_eq(st1["step_statuses"], ["done", "active", "pending", "pending"], "Step 1 (Q) advances tutorial highlight to step 1")
	runner.assert_eq(hud.call("get_displayed_prompt_statuses"), ["done", "active", "pending", "pending"], "TrainingHUD reflects step 1 highlight progression")

	# Complete remaining steps at exact 6-frame Perfect rhythm (E -> Q -> Shift)
	await runner.wait_physics_frames(5)
	ctrl["buttons"] = BTN_SKILL_E
	await runner.wait_physics_frames(1)
	ctrl["buttons"] = 0
	await runner.wait_physics_frames(5)
	ctrl["buttons"] = BTN_SKILL_Q
	await runner.wait_physics_frames(1)
	ctrl["buttons"] = 0
	await runner.wait_physics_frames(5)
	ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(1)
	ctrl["buttons"] = 0
	await runner.wait_physics_frames(2)

	var st_done: Dictionary = trainer.get_tutorial_state()
	runner.assert_true(bool(st_done["just_completed"]), "Live Phantom Drive marks tutorial just_completed == true")
	runner.assert_eq(st_done["step_statuses"], ["done", "done", "done", "done"], "Completed tutorial highlights all 4 steps 'done'")
	runner.assert_ge(int(st_done["perfects"]), 1, "6-frame rhythm registers Perfect tutorial completion")
	runner.assert_eq(hud.call("get_displayed_prompt_statuses"), ["done", "done", "done", "done"], "TrainingHUD shows all 4 chips 'done' on completion")

	# Verify Live Input History Tape + PERFECT tags
	var hist: Array = trainer.get_input_history(16)
	runner.assert_ge(hist.size(), 4, "Input history recorded all 4 combo inputs (count=%d)" % hist.size())
	runner.assert_eq(int(hud.call("get_displayed_input_history_count")), hist.size(), "TrainingHUD displays exact live input history count")
	var perfect_tags := 0
	for h in hist:
		if String((h as Dictionary).get("timing_tag", "")) == "PERFECT":
			perfect_tags += 1
	runner.assert_ge(perfect_tags, 3, "6-frame gaps tagged 'PERFECT' in input history (count=%d)" % perfect_tags)

	# Verify EARLY (< 4f) and LATE (> 9f) timing tags directly
	var early_entry: Dictionary = trainer.on_input_recorded({"symbol": "Q", "frame": 100, "gap_frames": 2})
	var late_entry: Dictionary = trainer.on_input_recorded({"symbol": "E", "frame": 112, "gap_frames": 12})
	runner.assert_eq(String(early_entry.get("timing_tag", "")), "EARLY", "2-frame gap tagged 'EARLY'")
	runner.assert_eq(String(late_entry.get("timing_tag", "")), "LATE", "12-frame gap tagged 'LATE'")

	# Verify Combo & Shot Timing Analysis readout in TrainingHUD
	var combo_timing: Dictionary = trainer.get_last_timing_analysis()
	runner.assert_eq(String(combo_timing.get("kind", "")), "combo", "Timing analysis captured completed combo")
	runner.assert_true(bool(combo_timing.get("is_perfect", false)), "Combo timing analysis flagged is_perfect == true")

	var shot_timing: Dictionary = trainer.on_shot_timing_feedback("Perfect", 0.004)
	runner.assert_approx(float(shot_timing.get("offset_ms", 0.0)), 4.0, 0.05, "Shot timing analysis computes exact +4.0ms offset")
	runner.assert_approx(float(shot_timing.get("offset_frames", 0.0)), 0.24, 0.02, "Shot timing analysis computes exact +0.24f offset")
	var hud_timing_txt: String = String(hud.call("get_displayed_timing_text"))
	runner.assert_true(hud_timing_txt.contains("ms") and hud_timing_txt.to_upper().contains("PERFECT"), "TrainingHUD timing readout displays ms & PERFECT ('%s')" % hud_timing_txt)


# ==============================================================================
# 3. 5-Spot Shot Practice, Physical Basket Recording & Auto Ball Return
# ==============================================================================
func _test_five_spot_shot_practice(runner: SceneTree) -> void:
	await runner.clear_stage()
	var practice := await runner.mount_scene(PRACTICE_ARENA_SCENE_PATH) as Node3D
	var player: CharacterBody3D = practice.call("get_player")
	var ball: RigidBody3D = practice.call("get_basketball")
	var mt: MasteryTracker = practice.call("get_mastery_tracker")
	var hud: Node = practice.call("get_hud")
	mt.set_save_path(TEST_MASTERY_PATH)
	mt.reset_stats()

	var spots: Array = practice.call("get_shot_spots")
	runner.assert_eq(spots.size(), 5, "5-Spot Shot Practice defines exact 5 court spots")

	# Start at spot 2 (Top of Key 3, (0, 0, -5.0)) with Sharpshooter and Idle dummy out of way
	practice.call("set_player_archetype", "sharpshooter")
	practice.call("set_dummy_mode", DefensiveDummy.Mode.IDLE)
	var ctrl := _make_input_controller(player)
	var drill0: Dictionary = practice.call("start_shot_practice", 2)
	runner.assert_true(bool(drill0["active"]), "5-Spot Shot Practice activates cleanly")
	runner.assert_eq(String(drill0["spot_id"]), "top_of_key_3", "Spot 2 == 'top_of_key_3'")
	runner.assert_approx(player.global_position.z, -5.0, 0.05, "Player positioned at Top of Key 3 spot")
	runner.assert_eq(ball.carrier, player, "Player starts holding basketball at shot spot")
	runner.assert_true(String(hud.call("get_displayed_shot_drill_text")).contains("Top of Key 3"), "TrainingHUD displays active shot spot name")

	# Execute a live 60 Hz Perfect jump shot (hold BTN_SHOOT 15 ticks ~ 0.25s -> release -> swish!)
	await runner.wait_physics_frames(2)
	ctrl["buttons"] = BTN_SHOOT
	await runner.wait_physics_frames(15)
	ctrl["buttons"] = 0

	# Wait for physical HoopB swish + 0.55s auto_return_ball() cycle
	await runner.wait_physics_frames(155)
	var drill1: Dictionary = practice.call("get_shot_drill_state")
	runner.assert_ge(int(drill1["attempts"]), 1, "Shot drill recorded completed shot attempt")
	runner.assert_ge(int(drill1["makes"]), 1, "Physical swish recorded as made basket in 5-Spot Shot Practice")
	runner.assert_ge(int(drill1["streak"]), 1, "Made basket increments shot streak")
	runner.assert_approx(float(drill1["make_pct"]), 100.0, 0.5, "1/1 swish reports 100% make accuracy")
	runner.assert_eq(ball.carrier, player, "auto_return_ball() automatically returns basketball to shooter after make")

	# Progress across all 5 distinct spots and verify wrap-around
	var visited_spots: Array[String] = [String(drill1["spot_id"])]
	for _s in range(5):
		var adv: Dictionary = practice.call("advance_shot_spot")
		var sid := String(adv["spot_id"])
		if not visited_spots.has(sid):
			visited_spots.append(sid)
	runner.assert_eq(visited_spots.size(), 5, "advance_shot_spot() cycles cleanly across all 5 distinct shot spots")


# ==============================================================================
# 4. Programmable Defensive Dummy — All 6 Modes Verified On-Court
# ==============================================================================
func _test_all_six_defensive_dummy_modes(runner: SceneTree) -> void:
	await runner.clear_stage()
	var practice := await runner.mount_scene(PRACTICE_ARENA_SCENE_PATH) as Node3D
	var player: CharacterBody3D = practice.call("get_player")
	var dummy_p: CharacterBody3D = practice.call("get_dummy_player")
	var dummy: DefensiveDummy = practice.call("get_dummy")
	var hud: Node = practice.call("get_hud")
	var mt: MasteryTracker = practice.call("get_mastery_tracker")
	mt.set_save_path(TEST_MASTERY_PATH)
	mt.reset_stats()
	var ctrl := _make_input_controller(player)

	# Mode 0: IDLE
	practice.call("set_dummy_mode", DefensiveDummy.Mode.IDLE)
	await runner.wait_physics_frames(4)
	var f_idle: Dictionary = dummy.sample_input(10, 1.0 / 60.0)
	runner.assert_eq(int(f_idle["buttons"]), 0, "Dummy IDLE emits 0 buttons")
	runner.assert_approx((f_idle["move_world_xz"] as Vector2).length(), 0.0, 0.001, "Dummy IDLE stays stationary")
	runner.assert_eq(String(hud.call("get_displayed_dummy_mode")), "Idle", "TrainingHUD displays 'Idle'")

	# Mode 1: STANCE_CONTEST
	practice.call("set_dummy_mode", DefensiveDummy.Mode.STANCE_CONTEST)
	await runner.wait_physics_frames(20)
	runner.assert_true(bool(dummy_p.call("is_in_defensive_stance")), "Dummy STANCE_CONTEST locks into DEFENSIVE_STANCE")
	runner.assert_eq(String(hud.call("get_displayed_dummy_mode")), "Stance Contest", "TrainingHUD displays 'Stance Contest'")

	# Mode 2: JUMP_BLOCK (jumps when offense starts charging a shot!)
	practice.call("set_dummy_mode", DefensiveDummy.Mode.JUMP_BLOCK)
	practice.call("reset_drill_positions")
	await runner.wait_physics_frames(6)
	ctrl["buttons"] = BTN_SHOOT # Begin jump-shot charge -> dummy detects & jumps!
	var dummy_jumped := false
	for _i in range(14):
		await runner.wait_physics_frames(1)
		if not dummy_p.is_on_floor():
			dummy_jumped = true
			break
	ctrl["buttons"] = 0
	runner.assert_true(dummy_jumped, "Dummy JUMP_BLOCK jumps vertically to contest when player starts shooting")
	runner.assert_eq(String(hud.call("get_displayed_dummy_mode")), "Jump Block", "TrainingHUD displays 'Jump Block'")

	# Mode 3: STEAL_INTERVAL (pulses BTN_STEAL every 90 ticks = 1.5s)
	practice.call("set_dummy_mode", DefensiveDummy.Mode.STEAL_INTERVAL)
	practice.call("reset_drill_positions")
	var steal_triggered := false
	for _i in range(96):
		await runner.wait_physics_frames(1)
		if String(dummy_p.defense_system.call("get_steal_phase_name")) != "IDLE":
			steal_triggered = true
			break
	runner.assert_true(steal_triggered, "Dummy STEAL_INTERVAL executes periodic steal poke at 90-frame cadence")
	runner.assert_eq(String(hud.call("get_displayed_dummy_mode")), "Steal Interval", "TrainingHUD displays 'Steal Interval'")

	# Mode 4: MIRROR_GUARD (sprints laterally in sync with player's lateral velocity!)
	practice.call("set_dummy_mode", DefensiveDummy.Mode.MIRROR_GUARD)
	practice.call("reset_drill_positions")
	await runner.wait_physics_frames(4)
	ctrl["move_world_xz"] = Vector2(1.0, 0.0)
	ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(22)
	var dummy_mirror_vx: float = dummy_p.velocity.x
	ctrl["move_world_xz"] = Vector2.ZERO
	ctrl["buttons"] = 0
	runner.assert_gt(dummy_mirror_vx, 3.0, "Dummy MIRROR_GUARD sprints laterally in sync with player (+X vel=%.2f)" % dummy_mirror_vx)
	runner.assert_eq(String(hud.call("get_displayed_dummy_mode")), "Mirror Guard", "TrainingHUD displays 'Mirror Guard'")

	# Mode 5: LIVE_PHANTOM_AI (delegates to full Phantom-tier AIController)
	practice.call("set_dummy_mode", DefensiveDummy.Mode.LIVE_PHANTOM_AI)
	practice.call("reset_drill_positions")
	var phantom_ai: AIController = dummy.get_phantom_ai()
	runner.assert_not_null(phantom_ai, "Dummy LIVE_PHANTOM_AI owns AIController")
	runner.assert_eq(phantom_ai.get_difficulty(), AIDifficulty.Tier.PHANTOM, "Dummy LIVE_PHANTOM_AI runs at PHANTOM difficulty")
	await runner.wait_physics_frames(20)
	var ai_intent: Dictionary = phantom_ai.get_current_intent()
	runner.assert_eq(String(ai_intent["role"]), AIUtilityBrain.ROLE_DEFENSE_ON_BALL, "Dummy LIVE_PHANTOM_AI actively evaluates DEFENSE_ON_BALL")
	runner.assert_eq(String(hud.call("get_displayed_dummy_mode")), "Live Phantom AI", "TrainingHUD displays 'Live Phantom AI'")


# ==============================================================================
# 5. Timed Combo Challenges (S/A/B/C/FAIL) & MasteryTracker JSON Persistence
# ==============================================================================
func _test_combo_challenges_and_mastery_persistence(runner: SceneTree) -> void:
	# Verify all 5 challenge grade brackets deterministically
	runner.assert_eq(ComboTrainer.compute_challenge_grade(3, 3, 3), "S", "Challenge grade (3/3 perfect) == 'S'")
	runner.assert_eq(ComboTrainer.compute_challenge_grade(3, 2, 3), "A", "Challenge grade (3/3 with 2 perfect) == 'A'")
	runner.assert_eq(ComboTrainer.compute_challenge_grade(3, 0, 3), "B", "Challenge grade (3/3 with 0 perfect) == 'B'")
	runner.assert_eq(ComboTrainer.compute_challenge_grade(1, 0, 3), "C", "Challenge grade (1/3) == 'C'")
	runner.assert_eq(ComboTrainer.compute_challenge_grade(0, 0, 3), "FAIL", "Challenge grade (0/3) == 'FAIL'")

	# Live timed challenge inside PracticeArena
	await runner.clear_stage()
	var practice := await runner.mount_scene(PRACTICE_ARENA_SCENE_PATH) as Node3D
	var player: CharacterBody3D = practice.call("get_player")
	var trainer: ComboTrainer = practice.call("get_combo_trainer")
	var mt: MasteryTracker = practice.call("get_mastery_tracker")
	var hud: Node = practice.call("get_hud")
	mt.set_save_path(TEST_MASTERY_PATH)
	mt.reset_stats()

	practice.call("set_dummy_mode", DefensiveDummy.Mode.IDLE)
	var ctrl := _make_input_controller(player)

	# Start 30s challenge for 2x Phantom Drive
	var ch0: Dictionary = practice.call("start_challenge", "phantom_drive", 2, 30.0)
	runner.assert_true(bool(ch0["active"]), "Timed challenge starts active")
	runner.assert_eq(String(ch0["move_id"]), "phantom_drive", "Challenge target == 'phantom_drive'")

	# Execute 2 live Perfect Phantom Drives (Q -> E -> Q -> Shift @ 6f gap, cooldown cleared between reps via 185f wait)
	for rep in range(2):
		if rep > 0:
			practice.call("reset_drill_positions")
			await runner.wait_physics_frames(2)
		await _feed_input_steps(runner, ctrl, [
			{"buttons": BTN_SKILL_Q},
			{"buttons": BTN_SKILL_E},
			{"buttons": BTN_SKILL_Q},
			{"buttons": BTN_SPRINT},
		], 6)
		await runner.wait_physics_frames(4)

	var ch_mid: Dictionary = trainer.get_challenge_state()
	runner.assert_eq(int(ch_mid["completions"]), 2, "Timed challenge counted 2 live Phantom Drive completions")
	runner.assert_eq(int(ch_mid["perfects"]), 2, "Timed challenge counted 2 Perfect completions")
	runner.assert_gt(int(ch_mid["score"]), 800, "Timed challenge live score > 800 (actual=%d)" % int(ch_mid["score"]))

	# Finalize challenge -> Grade S + MasteryTracker rank -> Phantom!
	var ch_fin: Dictionary = practice.call("stop_challenge", true)
	runner.assert_true(bool(ch_fin["finished"]), "Finalized challenge marks finished == true")
	runner.assert_eq(String(ch_fin["grade"]), "S", "2/2 Perfect completions awards Grade 'S'")
	runner.assert_eq(String(hud.call("get_displayed_challenge_grade")), "S", "TrainingHUD displays Grade 'S' badge")
	runner.assert_true(String(hud.call("get_displayed_mastery_text")).contains("Phantom"), "TrainingHUD mastery card displays 'Phantom' rank")

	# Record shot stats & save MasteryTracker to isolated JSON file
	mt.record_shot("top_of_key_3", true, true, 3.5, "sharpshooter")
	mt.record_shot("left_corner_3", true, false, 18.0, "sharpshooter")
	mt.record_shot("left_corner_3", false, false, 45.0, "sharpshooter")
	var saved_ok: bool = mt.save_to_disk()
	runner.assert_true(saved_ok, "MasteryTracker.save_to_disk() writes isolated JSON cleanly")
	runner.assert_true(FileAccess.file_exists(TEST_MASTERY_PATH), "Isolated JSON file exists on disk")

	# Reload into brand-new MasteryTracker instance and verify lossless disk persistence!
	var mt_reloaded := MasteryTracker.new(TEST_MASTERY_PATH)
	var loaded_ok: bool = mt_reloaded.load_from_disk()
	runner.assert_true(loaded_ok, "Fresh MasteryTracker.load_from_disk() parses saved JSON")

	var pd_stats: Dictionary = mt_reloaded.get_move_stats("phantom_drive")
	runner.assert_eq(int(pd_stats["completions"]), 2, "Persisted phantom_drive completions == 2")
	runner.assert_eq(int(pd_stats["perfect_completions"]), 2, "Persisted phantom_drive perfect_completions == 2")
	runner.assert_eq(String(pd_stats["challenge_best_grade"]), "S", "Persisted challenge_best_grade == 'S'")
	runner.assert_eq(String(pd_stats["mastery_rank"]), MasteryTracker.RANK_PHANTOM, "Persisted mastery_rank == 'Phantom'")

	var shot_stats: Dictionary = mt_reloaded.get_shot_stats()
	runner.assert_eq(int(shot_stats["total_attempts"]), 3, "Persisted shot total_attempts == 3")
	runner.assert_eq(int(shot_stats["total_makes"]), 2, "Persisted shot total_makes == 2")
	runner.assert_eq(int(shot_stats["total_perfect_releases"]), 1, "Persisted shot total_perfect_releases == 1")
	runner.assert_eq(int(shot_stats["best_streak"]), 2, "Persisted shot best_streak == 2")

	var sharp_totals: Dictionary = mt_reloaded.get_archetype_stats("sharpshooter")
	runner.assert_eq(int(sharp_totals["shots_made"]), 2, "Persisted archetype totals track sharpshooter shots_made == 2")

	# Teardown cleanup verification
	_cleanup_test_mastery_file()
	runner.assert_false(FileAccess.file_exists(TEST_MASTERY_PATH), "Isolated test mastery JSON removed cleanly on teardown")
