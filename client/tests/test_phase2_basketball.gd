extends Node
## Phase 2 Automated Verification Suite — Advanced Basketball (PHANTOM COURT ONLINE)
## Verifies:
## 1. Left/Right hand dribbling synchronized between active hand joint and floor (y=0.12m),
##    EventBus.ball_bounced telemetry, and all 6 dribble moves (dribble_left/right, crossover,
##    behind_the_back, spin, stepback, hesitation) with physical displacement & animation hooks.
## 2. Ballistic arc solver with upward Magnus backspin, Jump Shots (Early/Good/Perfect/Late
##    timing labels + Perfect 2pt & 3pt physical swish scoring), Driving Layups (<= 3.4m),
##    and Rim-Bound Slam Dunks (sprint <= 2.9m -> DUNK_LOCKED -> dunk_impact -> +2 score).
## 3. Rebounds (missed shot -> FREE -> airborne apex grab -> possession_changed),
##    Steals (shielded during behind_the_back, stripped when exposed -> steal_performed),
##    Blocks (airborne swat SHOT_FLIGHT -> FREE deflected away from rim -> block_performed),
##    and Shot Contests ([0..1] intensity degrading non-Perfect shot quality & widening scatter).
## 4. Stamina (0..100 drain on sprint/dribble/jump/dunk, idle regen, exhausted < 20 speed &
##    variance penalties), Teammate Passing (PASS_FLIGHT -> HELD + possession_changed),
##    all 6 canonical BallState transitions, and extended export/import_sim_state roundtrip.

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"
const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"

const BTN_SPRINT: int  = 1
const BTN_JUMP: int    = 2
const BTN_SHOOT: int   = 4
const BTN_PASS: int    = 8
const BTN_SKILL_Q: int = 16
const BTN_SKILL_E: int = 32
const BTN_SKILL_R: int = 64
const BTN_STEAL: int   = 128
const BTN_STANCE: int  = 512


func run(runner: SceneTree) -> void:
	await _test_dribble_oscillation_and_six_moves(runner)
	await _test_ballistic_shots_layups_and_dunks(runner)
	await _test_rebounds_steals_blocks_and_contests(runner)
	await _test_stamina_passing_and_state_snapshots(runner)


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


func _spawn_extra_player(arena: Node3D, node_name: String, pid: int, tid: int, pos: Vector3) -> CharacterBody3D:
	var packed := load(PLAYER_SCENE_PATH) as PackedScene
	if packed == null:
		return null
	var p := packed.instantiate() as CharacterBody3D
	p.name = node_name
	p.set("player_id", pid)
	p.set("team_id", tid)
	p.set("is_local_human", false)
	var players_root := arena.get_node_or_null("Players")
	if players_root != null:
		players_root.add_child(p)
	else:
		arena.add_child(p)
	p.global_position = pos
	return p


# ==============================================================================
# 1. Dribble Oscillation (Hand <-> Floor y=0.12) & All 6 Dribble Moves
# ==============================================================================
func _test_dribble_oscillation_and_six_moves(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	if not runner.assert_not_null(player, "Phase2: LocalPlayer present") or not runner.assert_not_null(ball, "Phase2: Basketball present"):
		return

	var ctrl := _make_input_controller(player)
	var eb: Node = runner.get_event_bus()
	var court_bounces := [0]
	var dribble_events: Array[String] = []
	runner.connect_temp_signal(eb.ball_bounced, func(_pos: Vector3, _spd: float, surf: String) -> void:
		if surf == "court":
			court_bounces[0] += 1
	)
	runner.connect_temp_signal(eb.dribble_move_performed, func(_pid: int, move_name: String, _pos: Vector3) -> void:
		dribble_events.append(move_name)
	)

	# Give LocalPlayer ball at center court facing -Z
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0)))
	ball.call("set_controlled_state", 1, player, 1, 0, true) # HELD
	await runner.wait_physics_frames(2)
	runner.assert_eq(String(ball.call("get_state_name")), "HELD", "Stationary ball carrier starts in HELD state")

	# Run forward -> DRIBBLING oscillation between active RIGHT hand and court floor (y=0.12)
	court_bounces[0] = 0
	ctrl["local_dir"] = Vector2(0.0, 1.0)
	ctrl["aim_yaw"] = 0.0
	var min_ball_y: float = 99.0
	var max_ball_y: float = -99.0
	var right_side_samples: int = 0
	for _i in range(36):
		await runner.physics_frame
		if ball.global_position.y < min_ball_y:
			min_ball_y = ball.global_position.y
		if ball.global_position.y > max_ball_y:
			max_ball_y = ball.global_position.y
		if ball.global_position.x > player.global_position.x + 0.05:
			right_side_samples += 1

	runner.assert_eq(String(ball.call("get_state_name")), "DRIBBLING", "Moving ball carrier transitions to DRIBBLING state")
	runner.assert_le(min_ball_y, 0.24, "Dribble oscillation touches near floor y=0.12m")
	runner.assert_ge(max_ball_y, 0.72, "Dribble oscillation rises cleanly up to active hand joint")
	runner.assert_gt(float(court_bounces[0]), 0.0, "Active dribbling emits EventBus.ball_bounced('court') on floor touch")
	runner.assert_gt(float(right_side_samples), 15.0, "RIGHT hand dribble keeps ball on player's +X right side")

	# Move 1: Left / Right Dribble hand switch
	var left_ok: bool = bool(player.call("perform_dribble_move", "dribble_left", false))
	runner.assert_true(left_ok, "perform_dribble_move('dribble_left') succeeds")
	runner.assert_eq(String(player.dribble_system.call("get_dribble_hand_name")), "LEFT", "dribble_left switches active hand to LEFT")
	await runner.wait_physics_frames(8)
	runner.assert_lt(ball.global_position.x, player.global_position.x - 0.05, "LEFT hand dribble keeps ball on player's -X left side")
	var right_ok: bool = bool(player.call("perform_dribble_move", "dribble_right", false))
	runner.assert_true(right_ok, "perform_dribble_move('dribble_right') succeeds")
	runner.assert_eq(String(player.dribble_system.call("get_dribble_hand_name")), "RIGHT", "dribble_right switches active hand back to RIGHT")

	# Move 2: Crossover (BTN_SKILL_Q when in RIGHT hand -> swaps to LEFT + sharp lateral cut)
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0)))
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)
	var pre_cross: Vector3 = player.global_position
	ctrl["buttons"] = BTN_SKILL_Q
	await runner.wait_physics_frames(2)
	ctrl["buttons"] = 0
	var cross_anim := String(player.animator.call("get_active_action"))
	await runner.wait_physics_frames(14)
	runner.assert_eq(String(player.dribble_system.call("get_dribble_hand_name")), "LEFT", "Crossover (Q from RIGHT hand) swaps active hand to LEFT")
	runner.assert_eq(cross_anim, "crossover", "Crossover sets CharacterAnimator active action to 'crossover'")
	runner.assert_lt(player.global_position.x - pre_cross.x, -0.75, "Crossover produces sharp lateral cut toward new left hand")
	runner.assert_true(dribble_events.has("crossover"), "Crossover emitted EventBus.dribble_move_performed('crossover')")

	# Move 3: Behind-the-Back (back input + BTN_SKILL_E -> hand swap + steal protection + wrap burst)
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0)))
	player.dribble_system.call("set_dribble_hand", 0) # LEFT
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)
	var pre_btb: Vector3 = player.global_position
	ctrl["local_dir"] = Vector2(0.0, -0.5)
	ctrl["buttons"] = BTN_SKILL_E
	await runner.wait_physics_frames(2)
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0
	var btb_shield: bool = bool(player.call("has_steal_protection"))
	var btb_anim := String(player.animator.call("get_active_action"))
	await runner.wait_physics_frames(14)
	runner.assert_eq(String(player.dribble_system.call("get_dribble_hand_name")), "RIGHT", "Behind-the-Back swaps hand LEFT -> RIGHT")
	runner.assert_true(btb_shield, "Behind-the-Back activates steal protection shield")
	runner.assert_eq(btb_anim, "behind_the_back", "Behind-the-Back triggers 'behind_the_back' animation action")
	runner.assert_gt(player.global_position.x - pre_btb.x, 0.85, "Behind-the-Back produces physical wrap-cut displacement")
	runner.assert_true(dribble_events.has("behind_the_back"), "Behind-the-Back emitted EventBus.dribble_move_performed('behind_the_back')")

	# Move 4: Spin Move (BTN_SKILL_R while driving -> 360-deg pelvis pivot + hand swap + drive burst)
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0)))
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)
	var pre_spin: Vector3 = player.global_position
	ctrl["local_dir"] = Vector2(0.0, 1.0)
	ctrl["buttons"] = BTN_SKILL_R
	await runner.wait_physics_frames(2)
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0
	var max_pelvis_rot: float = 0.0
	var spin_shield: bool = bool(player.call("has_steal_protection"))
	for _i in range(20):
		await runner.physics_frame
		var pyaw: float = absf(player.animator.pelvis.rotation.y)
		if pyaw > max_pelvis_rot:
			max_pelvis_rot = pyaw
	runner.assert_eq(String(player.dribble_system.call("get_dribble_hand_name")), "LEFT", "Spin Move swaps hand RIGHT -> LEFT")
	runner.assert_true(spin_shield, "Spin Move grants protective steal shield")
	runner.assert_gt(max_pelvis_rot, 3.0, "Spin Move rotates character pelvis through 360-deg pivot")
	runner.assert_lt(player.global_position.z - pre_spin.z, -1.2, "Spin Move drives forward past defender")
	runner.assert_true(dribble_events.has("spin"), "Spin Move emitted EventBus.dribble_move_performed('spin')")

	# Move 5: Stepback (BTN_SKILL_R + back input -> sudden backward separation >= 1.6m + gather window)
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)
	var pre_step: Vector3 = player.global_position
	ctrl["local_dir"] = Vector2(0.0, -0.6)
	ctrl["buttons"] = BTN_SKILL_R
	await runner.wait_physics_frames(2)
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0
	var step_anim := String(player.animator.call("get_active_action"))
	var has_gather: bool = bool(player.dribble_system.call("has_stepback_gather_bonus"))
	await runner.wait_physics_frames(15)
	var backward_sep: float = player.global_position.z - pre_step.z # facing -Z -> backward is +Z
	runner.assert_ge(backward_sep, 1.60, "Stepback creates >= 1.6m backward separation (actual=%.2fm)" % backward_sep)
	runner.assert_true(has_gather, "Stepback opens immediate shot gather bonus window")
	runner.assert_eq(step_anim, "stepback", "Stepback triggers 'stepback' animation action")
	runner.assert_true(dribble_events.has("stepback"), "Stepback emitted EventBus.dribble_move_performed('stepback')")

	# Move 6: Hesitation (BTN_SKILL_E on same RIGHT hand -> stutter slowdown then explosive first-step burst)
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0)))
	player.dribble_system.call("set_dribble_hand", 1) # RIGHT
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = BTN_SKILL_E
	await runner.wait_physics_frames(2)
	ctrl["buttons"] = 0
	var hesi_anim := String(player.animator.call("get_active_action"))
	await runner.wait_physics_frames(2)
	var stutter_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
	await runner.wait_physics_frames(7)
	var burst_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
	runner.assert_eq(hesi_anim, "hesitation", "Hesitation triggers 'hesitation' animation action")
	runner.assert_lt(stutter_speed, 3.0, "Hesitation stage 1 produces rhythmic stutter slowdown")
	runner.assert_gt(burst_speed, 9.5, "Hesitation stage 2 explodes into high-speed first-step burst")
	runner.assert_true(dribble_events.has("hesitation"), "Hesitation emitted EventBus.dribble_move_performed('hesitation')")


# ==============================================================================
# 2. Ballistic Solver, Magnus Backspin, Jump Shots (4 Timings), Layups & Dunks
# ==============================================================================
func _test_ballistic_shots_layups_and_dunks(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var hoop_b := arena.get_node_or_null("HoopB") as Node3D
	var mc := arena.get_node_or_null("MatchController") as Node
	if not runner.assert_not_null(player, "Shots: LocalPlayer present") or not runner.assert_not_null(ball, "Shots: Basketball present"):
		return

	var ctrl := _make_input_controller(player)
	var eb: Node = runner.get_event_bus()
	var gs: Node = runner.get_game_state()
	var rim_b: Vector3 = hoop_b.call("get_rim_center")

	# 2A. Verify authentic upward Magnus backspin lift from BallTrajectory solver
	var test_origin := Vector3(0.0, 2.0, -5.0)
	var omega: Vector3 = BallTrajectory.compute_backspin_angular_velocity(test_origin, rim_b, 16.5)
	var v_perf: Vector3 = BallTrajectory.compute_shot_velocity(test_origin, rim_b, 1.35, 1.0, 1, omega)
	var magnus_y: float = omega.cross(v_perf).y
	runner.assert_gt(magnus_y, 20.0, "Backspin angular velocity generates authentic upward (+Y) Magnus lift")

	# Verify scatter increases for Early/Late/contested vs Perfect
	var tgt_perf: Vector3 = BallTrajectory.compute_shot_target_with_scatter(test_origin, rim_b, 1.0, 0.0, 0.0, 0.0, 7)
	var tgt_early: Vector3 = BallTrajectory.compute_shot_target_with_scatter(test_origin, rim_b, 0.55, -0.18, 0.0, 0.0, 7)
	var tgt_contested: Vector3 = BallTrajectory.compute_shot_target_with_scatter(test_origin, rim_b, 0.80, 0.0, 0.85, 0.0, 7)
	runner.assert_approx(tgt_perf.distance_to(rim_b), 0.0, 0.001, "Perfect uncontested shot aims dead-center at rim")
	runner.assert_gt(tgt_early.distance_to(rim_b), 0.10, "Early shot applies realistic scatter offset")
	runner.assert_gt(tgt_contested.distance_to(rim_b), 0.10, "Heavily contested non-Perfect shot applies scatter offset")

	# Track signals
	var shot_events: Array[Dictionary] = []
	var timing_events: Array[Dictionary] = []
	var dunk_events: Array[Dictionary] = []
	var score_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.shot_released, func(pid: int, rpos: Vector3, trim: Vector3, is3: bool, q: float) -> void:
		shot_events.append({"pid": pid, "pos": rpos, "rim": trim, "is_three": is3, "quality": q})
	)
	runner.connect_temp_signal(eb.shot_timing_feedback, func(pid: int, lbl: String, err: float) -> void:
		timing_events.append({"pid": pid, "label": lbl, "error": err})
	)
	runner.connect_temp_signal(eb.dunk_impact, func(pid: int, rpos: Vector3, power: float) -> void:
		dunk_events.append({"pid": pid, "rim": rpos, "power": power})
	)
	runner.connect_temp_signal(eb.score_changed, func(tid: int, ns: int, d: int, is3: bool, sid: int) -> void:
		score_events.append({"team_id": tid, "new_score": ns, "delta": d, "is_three": is3, "scorer_id": sid})
	)

	# 2B. Uncontested Perfect 2pt Jump Shot from midrange (0, 0, -7.5) physically swishes through HoopB!
	mc.call("restart_match")
	score_events.clear()
	shot_events.clear()
	timing_events.clear()
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -7.5)))
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)

	ctrl["buttons"] = BTN_SHOOT
	await runner.wait_physics_frames(15) # ~0.25s -> inside Perfect green window around 0.26s
	ctrl["buttons"] = 0
	await runner.wait_physics_frames(2)

	runner.assert_eq(String(ball.call("get_state_name")), "SHOT_FLIGHT", "Jump shot release transitions ball to SHOT_FLIGHT")
	runner.assert_eq(shot_events.size(), 1, "Jump shot emits EventBus.shot_released")
	runner.assert_eq(timing_events.size(), 1, "Jump shot emits EventBus.shot_timing_feedback")
	if timing_events.size() >= 1:
		runner.assert_eq(String(timing_events[0]["label"]), "Perfect", "0.25s jump shot charge yields 'Perfect' timing label")

	await runner.wait_physics_frames(95) # Allow full ballistic flight through hollow HoopB rim
	runner.assert_eq(score_events.size(), 1, "Uncontested Perfect midrange jump shot physically swishes and scores")
	if score_events.size() >= 1:
		runner.assert_eq(int(score_events[0]["delta"]), 2, "Midrange Perfect jump shot awards +2 points")
		runner.assert_false(bool(score_events[0]["is_three"]), "Midrange Perfect jump shot is_three == false")

	# 2C. Uncontested Perfect 3pt Jump Shot from (0, 0, -5.0) (dist=7.425m > 6.75m) physically swishes +3!
	score_events.clear()
	shot_events.clear()
	timing_events.clear()
	hoop_b.call("reset_hoop_state")
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.0)))
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)

	ctrl["buttons"] = BTN_SHOOT
	await runner.wait_physics_frames(15)
	ctrl["buttons"] = 0
	await runner.wait_physics_frames(105)

	runner.assert_eq(score_events.size(), 1, "Uncontested Perfect 3-pointer physically swishes through HoopB")
	if score_events.size() >= 1:
		runner.assert_eq(int(score_events[0]["delta"]), 3, "3-point Perfect jump shot awards +3 points")
		runner.assert_true(bool(score_events[0]["is_three"]), "3-point Perfect jump shot sets is_three == true")

	# 2D. Verify Early, Good, and Late jump-shot timing labels
	for timing_case in [
		{"ticks": 4, "expected": "Early"},
		{"ticks": 10, "expected": "Good"},
		{"ticks": 31, "expected": "Late"},
	]:
		timing_events.clear()
		player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.5)))
		ball.call("set_controlled_state", 1, player, 1, 0, true)
		await runner.wait_physics_frames(2)
		ctrl["buttons"] = BTN_SHOOT
		await runner.wait_physics_frames(int(timing_case["ticks"]))
		ctrl["buttons"] = 0
		await runner.wait_physics_frames(2)
		var got_lbl: String = String(timing_events[0]["label"]) if timing_events.size() > 0 else "<none>"
		runner.assert_eq(got_lbl, String(timing_case["expected"]), "Jump shot hold %d ticks yields '%s' feedback" % [int(timing_case["ticks"]), String(timing_case["expected"])])

	# 2E. Driving Layup (moving inside 3.4m, NOT sprinting -> last_shot_type == 'layup' & scores +2)
	score_events.clear()
	hoop_b.call("reset_hoop_state")
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(1.2, 0.0, -9.6)))
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)
	ctrl["local_dir"] = Vector2(0.0, 1.0)
	ctrl["buttons"] = 0
	await runner.wait_physics_frames(8) # Build driving run speed (> 1.0 m/s) inside 3.4m of HoopB
	ctrl["buttons"] = BTN_SHOOT
	await runner.wait_physics_frames(10) # ~0.18s optimal layup charge
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0
	runner.assert_eq(String(player.shooting_system.get("last_shot_type")), "layup", "Driving shoot inside 3.4m triggers 'layup'")
	await runner.wait_physics_frames(75)
	runner.assert_eq(score_events.size(), 1, "Uncontested driving layup scores cleanly")
	if score_events.size() >= 1:
		runner.assert_eq(int(score_events[0]["delta"]), 2, "Driving layup awards +2 points")

	# 2F. Rim-Bound Slam Dunk (sprinting inside 2.9m with sufficient stamina -> DUNK_LOCKED -> dunk_impact -> +2)
	score_events.clear()
	dunk_events.clear()
	hoop_b.call("reset_hoop_state")
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -10.0)))
	player.stamina.call("reset_stamina")
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)

	var pre_dunk_stamina: float = float(player.stamina.get("current_stamina"))
	ctrl["local_dir"] = Vector2(0.0, 1.0)
	ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(4)
	ctrl["buttons"] = BTN_SPRINT | BTN_SHOOT
	await runner.wait_physics_frames(2)
	ctrl["buttons"] = 0
	ctrl["local_dir"] = Vector2.ZERO

	runner.assert_eq(String(player.shooting_system.get("last_shot_type")), "dunk", "Sprinting shoot inside 2.9m initiates 'dunk'")
	runner.assert_eq(String(ball.call("get_state_name")), "DUNK_LOCKED", "Dunk flight locks ball into canonical DUNK_LOCKED state")
	runner.assert_le(float(player.stamina.get("current_stamina")), pre_dunk_stamina - 17.5, "Dunk consumes 18 stamina")

	var peak_dunk_y: float = 0.0
	for _i in range(45):
		await runner.physics_frame
		if player.global_position.y > peak_dunk_y:
			peak_dunk_y = player.global_position.y

	runner.assert_gt(peak_dunk_y, 0.90, "Rim-bound dunk launches player airborne toward rim (peak=%.2fm)" % peak_dunk_y)
	runner.assert_eq(dunk_events.size(), 1, "Slam dunk emits EventBus.dunk_impact")
	runner.assert_eq(score_events.size(), 1, "Slam dunk drives ball through UpperGate -> LowerGate and scores")
	if score_events.size() >= 1:
		runner.assert_eq(int(score_events[0]["delta"]), 2, "Slam dunk awards +2 points")
	runner.assert_gt(int(gs.get("scores")[0]), 0, "Team 0 score reflects completed shots/dunks")

	# 2G. Insufficient stamina (< 18) blocks dunk and falls back to layup/jump shot
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -10.2)))
	player.stamina.call("set_stamina", 10.0)
	ball.call("set_controlled_state", 1, player, 1, 0, true)
	await runner.wait_physics_frames(2)
	ctrl["local_dir"] = Vector2(0.0, 1.0)
	ctrl["buttons"] = BTN_SPRINT | BTN_SHOOT
	await runner.wait_physics_frames(2)
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0
	runner.assert_ne(String(player.shooting_system.get("last_shot_type")), "dunk", "Low stamina (<18) prevents dunk initiation")
	runner.assert_ne(String(ball.call("get_state_name")), "DUNK_LOCKED", "Low stamina prevents DUNK_LOCKED state")


# ==============================================================================
# 3. Rebounds, Steals (+ Shield), Blocks & Shot Contests (Multi-Player)
# ==============================================================================
func _test_rebounds_steals_blocks_and_contests(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var hoop_b := arena.get_node_or_null("HoopB") as Node3D
	if not runner.assert_not_null(offense, "Defense tests: offense player present") or not runner.assert_not_null(ball, "Defense tests: ball present"):
		return

	var defender := _spawn_extra_player(arena, "DefenderBot", 2, 1, Vector3(0.0, 0.0, -8.5))
	await runner.wait_physics_frames(2)
	if not runner.assert_not_null(defender, "Spawned Team 1 defender PlayerController"):
		return

	var off_ctrl := _make_input_controller(offense)
	var def_ctrl := _make_input_controller(defender)
	var eb: Node = runner.get_event_bus()
	var gs: Node = runner.get_game_state()
	var rim_b: Vector3 = hoop_b.call("get_rim_center")

	var poss_events: Array[Dictionary] = []
	var steal_events: Array[Dictionary] = []
	var block_events: Array[Dictionary] = []
	var state_on_block := [""]
	var vel_on_block := [Vector3.ZERO]
	runner.connect_temp_signal(eb.possession_changed, func(tid: int, cid: int) -> void:
		poss_events.append({"team": tid, "carrier": cid})
	)
	runner.connect_temp_signal(eb.steal_performed, func(sid: int, vid: int, pos: Vector3) -> void:
		steal_events.append({"stealer": sid, "victim": vid, "pos": pos})
	)
	runner.connect_temp_signal(eb.block_performed, func(bid: int, shid: int, pos: Vector3) -> void:
		block_events.append({"blocker": bid, "shooter": shid, "pos": pos})
		state_on_block[0] = String(ball.call("get_state_name"))
		vel_on_block[0] = ball.linear_velocity
	)

	# --- 3A. Rebound after missed shot off backboard -> FREE -> airborne grab -> possession_changed ---
	poss_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -11.3)))
	await runner.wait_physics_frames(2)

	# Launch missed shot straight into HoopB backboard glass (z = -12.80) so it rebounds back toward z = -11.3
	ball.call(
		"launch_shot",
		offense,
		1,
		0,
		Vector3(0.0, 3.45, -11.6),
		Vector3(0.0, 0.0, -8.0),
		rim_b,
		Vector3(0.0, 0.9, -7.2),
		Vector3.ZERO,
		false
	)

	var became_reboundable: bool = false
	var defender_jumped: bool = false
	for _i in range(60):
		await runner.physics_frame
		if bool(ball.get("is_reboundable")) and String(ball.call("get_state_name")) == "FREE":
			became_reboundable = true
			if not defender_jumped:
				defender_jumped = true
				def_ctrl["buttons"] = BTN_JUMP
			else:
				def_ctrl["buttons"] = 0
		if ball.get("carrier") == defender:
			def_ctrl["buttons"] = 0
			break
	def_ctrl["buttons"] = 0

	runner.assert_true(became_reboundable, "Missed shot off backboard transitions SHOT_FLIGHT -> FREE with is_reboundable=true")
	runner.assert_eq(ball.get("carrier"), defender, "Jumping defender cleanly secures live rebound")
	runner.assert_ge(int(defender.defense_system.get("rebounds_grabbed")), 1, "DefenseSystem tracks rebounds_grabbed >= 1")
	runner.assert_eq(int(gs.get("possession_team")), 1, "Rebound flips GameState possession_team to Team 1")
	runner.assert_true(poss_events.size() > 0 and int(poss_events[-1]["carrier"]) == 2, "Rebound emits EventBus.possession_changed(1, 2)")

	# --- 3B. Steal Protection during Behind-the-Back, then Clean Steal Strip ---
	steal_events.clear()
	poss_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.45, 0.0, -0.95)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Trigger behind_the_back steal protection on offense; defender poke must NOT strip while shielded
	offense.call("perform_dribble_move", "behind_the_back", false)
	runner.assert_true(bool(offense.call("has_steal_protection")), "Behind-the-back enables steal protection window")
	def_ctrl["buttons"] = BTN_STEAL
	await runner.wait_physics_frames(2)
	def_ctrl["buttons"] = 0
	runner.assert_eq(ball.get("carrier"), offense, "Steal attempt during behind-the-back shield does NOT strip carrier")
	runner.assert_eq(steal_events.size(), 0, "Shielded steal attempt emits 0 steal_performed events")

	# Wait for shield & steal cooldown (0.50s) to expire, reposition close, then poke exposed ball-handler
	await runner.wait_physics_frames(36)
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.40, 0.0, -0.95)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	def_ctrl["buttons"] = BTN_STEAL
	await runner.wait_physics_frames(2)
	def_ctrl["buttons"] = 0

	runner.assert_eq(ball.get("carrier"), defender, "Exposed steal within reach transfers ball to defender")
	runner.assert_eq(String(ball.call("get_state_name")), "HELD", "Successful steal places ball in defender HELD state")
	runner.assert_ge(int(defender.defense_system.get("steals_made")), 1, "DefenseSystem increments steals_made")
	runner.assert_eq(steal_events.size(), 1, "Successful steal emits EventBus.steal_performed")
	if steal_events.size() >= 1:
		runner.assert_eq(int(steal_events[0]["stealer"]), 2, "steal_performed stealer_id == 2")
		runner.assert_eq(int(steal_events[0]["victim"]), 1, "steal_performed victim_id == 1")

	# --- 3C. Airborne Shot Block (SHOT_FLIGHT -> FREE deflected away from hoop + block_performed) ---
	block_events.clear()
	var score_t0_before_blk: int = int(gs.get("scores")[0])
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.9)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Offense charges and releases a jump shot while defender leaps to contest/block at release
	off_ctrl["buttons"] = BTN_SHOOT
	await runner.wait_physics_frames(13)
	def_ctrl["buttons"] = BTN_JUMP | BTN_SHOOT # Defender jumps up to swat right as ball leaves hand
	await runner.wait_physics_frames(2)
	off_ctrl["buttons"] = 0
	await runner.wait_physics_frames(6)
	def_ctrl["buttons"] = 0

	var blocked_ball_vz: float = vel_on_block[0].z
	runner.assert_eq(block_events.size(), 1, "Airborne block emits EventBus.block_performed")
	runner.assert_ge(int(defender.defense_system.get("blocks_made")), 1, "DefenseSystem increments blocks_made")
	runner.assert_eq(state_on_block[0], "FREE", "Blocked shot transitions SHOT_FLIGHT -> FREE")
	runner.assert_gt(blocked_ball_vz, 2.0, "Blocked shot is swatted away (+Z) from HoopB (z=-12.425)")
	await runner.wait_physics_frames(40)
	runner.assert_eq(int(gs.get("scores")[0]), score_t0_before_blk, "Blocked shot does not score")

	# --- 3D. Shot Contest Intensity [0..1] & Non-Perfect Quality Degradation ---
	# Wide open: defender far away
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, 5.0)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	var open_contest: float = float(offense.call("compute_current_shot_contest"))
	runner.assert_approx(open_contest, 0.0, 0.02, "Wide-open shooter has 0.0 shot contest")

	off_ctrl["buttons"] = BTN_SHOOT
	await runner.wait_physics_frames(10) # Non-perfect "Good" release
	off_ctrl["buttons"] = 0
	await runner.wait_physics_frames(2)
	var open_quality: float = float(offense.shooting_system.get("last_timing_quality"))

	# Heavily contested: defender directly between shooter and HoopB in defensive stance
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.9)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	def_ctrl["buttons"] = BTN_STANCE
	await runner.wait_physics_frames(4)

	var heavy_contest: float = float(offense.call("compute_current_shot_contest"))
	runner.assert_gt(heavy_contest, 0.60, "Close front defender in stance yields high shot contest (> 0.60)")
	runner.assert_le(heavy_contest, 1.0, "Shot contest stays clamped <= 1.0")

	off_ctrl["buttons"] = BTN_SHOOT
	await runner.wait_physics_frames(10) # Same non-perfect "Good" release under heavy contest
	off_ctrl["buttons"] = 0
	await runner.wait_physics_frames(2)
	def_ctrl["buttons"] = 0
	var contested_quality: float = float(offense.shooting_system.get("last_timing_quality"))

	runner.assert_gt(float(offense.shooting_system.get("last_shot_contest")), 0.60, "ShootingSystem records high last_shot_contest")
	runner.assert_lt(contested_quality, open_quality - 0.15, "Heavy contest visibly degrades non-Perfect shot quality (%.3f < %.3f)" % [contested_quality, open_quality])


# ==============================================================================
# 4. Stamina Drain/Regen/Exhaustion, Teammate Passing & Extended State Snapshots
# ==============================================================================
func _test_stamina_passing_and_state_snapshots(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var p1 := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	if not runner.assert_not_null(p1, "Stamina/Pass: LocalPlayer present") or not runner.assert_not_null(ball, "Stamina/Pass: ball present"):
		return

	var teammate := _spawn_extra_player(arena, "TeammateBot", 3, 0, Vector3(4.5, 0.0, -3.5))
	await runner.wait_physics_frames(2)
	if not runner.assert_not_null(teammate, "Spawned Team 0 teammate PlayerController"):
		return

	var p1_ctrl := _make_input_controller(p1)
	var _tm_ctrl := _make_input_controller(teammate)
	var eb: Node = runner.get_event_bus()
	var gs: Node = runner.get_game_state()

	var stamina_events := [0]
	var poss_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.stamina_updated, func(pid: int, _cur: float, _mx: float) -> void:
		if pid == 1:
			stamina_events[0] += 1
	)
	runner.connect_temp_signal(eb.possession_changed, func(tid: int, cid: int) -> void:
		poss_events.append({"team": tid, "carrier": cid})
	)

	# --- 4A. Stamina Drain (Sprint, Jump, Dribble Move), Idle Regen, & Exhaustion (< 20.0) ---
	p1.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0)))
	ball.call("reset_to_free", Vector3(-6.0, 0.5, 10.0))
	stamina_events[0] = 0
	await runner.wait_physics_frames(2)

	var s_init: float = float(p1.stamina.get("current_stamina"))
	runner.assert_approx(s_init, 100.0, 0.1, "Stamina initializes to 100.0")
	runner.assert_false(bool(p1.stamina.call("is_exhausted")), "Fresh stamina is not exhausted")

	# Sprint 30 ticks (0.5s -> ~7.5 stamina drained)
	p1_ctrl["local_dir"] = Vector2(0.0, 1.0)
	p1_ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(30)
	var fresh_sprint_spd: float = Vector2(p1.velocity.x, p1.velocity.z).length()
	var s_after_sprint: float = float(p1.stamina.get("current_stamina"))
	runner.assert_lt(s_after_sprint, s_init - 5.5, "Sprinting drains stamina (%.1f < %.1f)" % [s_after_sprint, s_init])
	runner.assert_gt(float(stamina_events[0]), 5.0, "Stamina drain emits EventBus.stamina_updated")

	# Jump drains 7 stamina
	p1_ctrl["local_dir"] = Vector2.ZERO
	p1_ctrl["buttons"] = BTN_JUMP
	await runner.wait_physics_frames(2)
	p1_ctrl["buttons"] = 0
	var s_after_jump: float = float(p1.stamina.get("current_stamina"))
	runner.assert_le(s_after_jump, s_after_sprint - 6.5, "Jump consumes 7 stamina")

	# Idle regeneration (wait 0.50s delay + 1.0s regen at 20/s -> +20 stamina)
	await runner.wait_physics_frames(90)
	var s_after_regen: float = float(p1.stamina.get("current_stamina"))
	runner.assert_gt(s_after_regen, s_after_jump + 12.0, "Idle/walking regenerates stamina after cooldown")

	# Exhausted (< 20.0) reduces sprint speed & introduces shot variance penalty
	p1.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 3.0)))
	p1.stamina.call("set_stamina", 14.0)
	runner.assert_true(bool(p1.stamina.call("is_exhausted")), "Stamina < 20.0 sets is_exhausted() == true")
	runner.assert_lt(float(p1.stamina.call("get_speed_multiplier")), 0.85, "Exhausted speed multiplier < 0.85 (0.78)")
	runner.assert_gt(float(p1.stamina.call("get_shot_variance_penalty")), 0.04, "Exhausted widens shot release variance penalty")

	p1_ctrl["local_dir"] = Vector2(0.0, 1.0)
	p1_ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(24)
	var exhausted_sprint_spd: float = Vector2(p1.velocity.x, p1.velocity.z).length()
	p1_ctrl["local_dir"] = Vector2.ZERO
	p1_ctrl["buttons"] = 0
	runner.assert_lt(exhausted_sprint_spd, fresh_sprint_spd - 1.2, "Exhausted sprint speed (%.2f) noticeably slower than fresh sprint (%.2f)" % [exhausted_sprint_spd, fresh_sprint_spd])

	# --- 4B. Teammate Chest/Lead Pass (HELD -> PASS_FLIGHT -> HELD + possession_changed) ---
	poss_events.clear()
	p1.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.5)))
	teammate.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(4.5, 0.0, -3.5)))
	ball.call("set_controlled_state", 1, p1, 1, 0, true)
	await runner.wait_physics_frames(2)

	p1_ctrl["aim_yaw"] = -PI * 0.5 # Aim right (+X) toward teammate
	p1_ctrl["buttons"] = BTN_PASS
	await runner.wait_physics_frames(2)
	p1_ctrl["buttons"] = 0

	runner.assert_eq(String(ball.call("get_state_name")), "PASS_FLIGHT", "Passing transitions ball to canonical PASS_FLIGHT state")
	runner.assert_eq(ball.get("pass_target_player"), teammate, "Pass targets open same-team teammate")

	await runner.wait_physics_frames(35)
	runner.assert_eq(ball.get("carrier"), teammate, "Teammate catches pass cleanly in flight")
	runner.assert_eq(String(ball.call("get_state_name")), "HELD", "Caught pass transitions PASS_FLIGHT -> HELD")
	runner.assert_eq(int(gs.get("ball_carrier_id")), 3, "GameState ball_carrier_id updates to teammate (3)")
	runner.assert_true(poss_events.size() > 0 and int(poss_events[-1]["carrier"]) == 3, "Pass reception emits EventBus.possession_changed(0, 3)")

	# --- 4C. Extended Phase 2 export_sim_state / import_sim_state Roundtrip ---
	p1.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-1.5, 0.0, 1.0)))
	ball.call("set_controlled_state", 1, p1, 1, 0, true)
	p1.dribble_system.call("set_dribble_hand", 0) # LEFT
	p1.stamina.call("set_stamina", 47.5)
	p1.call("perform_dribble_move", "stepback", false)
	await runner.wait_physics_frames(2)

	var snap: Dictionary = p1.call("export_sim_state")
	var snap_stam: float = float(p1.stamina.get("current_stamina"))
	var snap_gather: float = float(p1.dribble_system.get("stepback_gather_timer"))
	runner.assert_eq(int(snap["dribble_hand"]), 0, "export_sim_state captures dribble_hand == LEFT (0)")

	# Mutate all fields completely
	p1.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(6.0, 0.0, 9.0)))
	p1.dribble_system.call("set_dribble_hand", 1) # RIGHT
	p1.stamina.call("set_stamina", 100.0)
	runner.assert_eq(int(p1.call("get_dribble_hand")), 1, "Sanity: mutated dribble hand to RIGHT before import")

	p1.call("import_sim_state", snap)
	runner.assert_eq(int(p1.call("get_dribble_hand")), 0, "import_sim_state restores dribble_hand == LEFT (0)")
	runner.assert_approx(float(p1.stamina.get("current_stamina")), snap_stam, 0.01, "import_sim_state restores exact stamina")
	runner.assert_approx(float(p1.dribble_system.get("stepback_gather_timer")), snap_gather, 0.01, "import_sim_state restores stepback_gather_timer")
	runner.assert_approx(p1.global_position.distance_to(snap["position"]), 0.0, 0.001, "import_sim_state restores exact position")
