extends Node
## Phase 1 Automated Verification Suite — Game Foundation (PHANTOM COURT ONLINE)
## Verifies:
## 1. Arena court geometry (15m x 28m), floor y=0, boundary walls, lighting, and both hoops (z = ±12.425).
## 2. Hollow 12-segment rim collider physical drop-through (+2 / +3 scoring via UpperGate -> LowerGate)
##    and upward under-rim false-score rejection (launch from (0, 2.4, 12.425) upward through gates).
## 3. Third-person camera-relative movement, sprint speed > run speed, jump & land cycle,
##    AnimationTree active state machine transitions (idle -> run -> sprint -> jump_start -> fall -> land),
##    and canonical Section 7 PlayerController integration API.
## 4. Basketball physical floor bounce restitution (~0.78) and backboard (~0.65) / rim (~0.58) collisions.
## 5. 2pt vs 3pt line classification (dist_xz <= 6.75 vs > 6.75 and corner |x| > 6.60),
##    match timer countdown, 24s shot clock countdown + violation reset, and restart_match() full reset.

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"
const MAIN_SCENE_PATH := "res://scenes/main.tscn"


func run(runner: SceneTree) -> void:
	await _test_arena_geometry_and_hoops(runner)
	await _test_hollow_rim_scoring_and_under_rim_rejection(runner)
	await _test_player_movement_jump_and_animation_tree(runner)
	await _test_basketball_restitution_and_surface_collisions(runner)
	await _test_match_rules_timers_and_restart(runner)
	await _test_main_boot_router_scene(runner)


# ==============================================================================
# 1. Arena Geometry (15m x 28m) & Regulation Hoops (z = ±12.425)
# ==============================================================================
func _test_arena_geometry_and_hoops(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena: Node3D = await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	if not runner.assert_not_null(arena, "Arena scene instantiates cleanly"):
		return

	var court_size: Vector2 = arena.call("get_court_size")
	runner.assert_approx(court_size.x, 15.0, 0.01, "Arena court width is 15.0m")
	runner.assert_approx(court_size.y, 28.0, 0.01, "Arena court length is 28.0m")

	runner.assert_true(bool(arena.call("is_in_bounds", Vector3(0.0, 0.0, 0.0))), "Center court (0,0,0) is in bounds")
	runner.assert_true(bool(arena.call("is_in_bounds", Vector3(7.5, 0.0, 14.0))), "Corner boundary (7.5, 0, 14.0) is in bounds")
	runner.assert_false(bool(arena.call("is_in_bounds", Vector3(7.6, 0.0, 0.0))), "Sideline x=7.6 is out of bounds")
	runner.assert_false(bool(arena.call("is_in_bounds", Vector3(0.0, 0.0, -14.1))), "Baseline z=-14.1 is out of bounds")

	var court_floor := arena.get_node_or_null("CourtFloor") as StaticBody3D
	runner.assert_not_null(court_floor, "CourtFloor StaticBody3D exists")
	if court_floor != null:
		var floor_cs := court_floor.get_node_or_null("CollisionShape3D") as CollisionShape3D
		runner.assert_not_null(floor_cs, "CourtFloor has CollisionShape3D")
		if floor_cs != null and floor_cs.shape is BoxShape3D:
			var fbox := floor_cs.shape as BoxShape3D
			var top_y: float = court_floor.global_position.y + floor_cs.position.y + fbox.size.y * 0.5
			runner.assert_approx(top_y, 0.0, 0.005, "CourtFloor top collision plane is at exact y = 0.0")
		var playable_mesh := court_floor.get_node_or_null("PlayableCourtSurface") as MeshInstance3D
		runner.assert_not_null(playable_mesh, "PlayableCourtSurface visual mesh exists")
		if playable_mesh != null and playable_mesh.mesh is BoxMesh:
			var pbm := playable_mesh.mesh as BoxMesh
			runner.assert_approx(pbm.size.x, 15.0, 0.01, "PlayableCourtSurface mesh width is 15.0m")
			runner.assert_approx(pbm.size.z, 28.0, 0.01, "PlayableCourtSurface mesh length is 28.0m")

	runner.assert_not_null(arena.get_node_or_null("BoundaryWalls"), "BoundaryWalls collider exists")
	runner.assert_not_null(arena.get_node_or_null("CourtMarkings"), "CourtMarkings mesh exists")
	runner.assert_not_null(arena.get_node_or_null("WorldEnvironment"), "WorldEnvironment exists")
	runner.assert_not_null(arena.get_node_or_null("SunLight"), "SunLight DirectionalLight3D exists")

	# Verify HoopA (z = +12.425, defended by Team 0) and HoopB (z = -12.425, defended by Team 1)
	var hoop_a := arena.get_node_or_null("HoopA") as Node3D
	var hoop_b := arena.get_node_or_null("HoopB") as Node3D
	if not runner.assert_not_null(hoop_a, "HoopA node exists") or not runner.assert_not_null(hoop_b, "HoopB node exists"):
		return

	var rim_a: Vector3 = hoop_a.call("get_rim_center")
	var rim_b: Vector3 = hoop_b.call("get_rim_center")
	runner.assert_approx(rim_a.x, 0.0, 0.01, "HoopA rim center X == 0.0")
	runner.assert_approx(rim_a.y, 3.05, 0.01, "HoopA rim center Y == 3.05")
	runner.assert_approx(rim_a.z, 12.425, 0.01, "HoopA rim center Z == +12.425")
	runner.assert_eq(int(hoop_a.get("defended_by_team")), 0, "HoopA defended_by_team == 0")

	runner.assert_approx(rim_b.x, 0.0, 0.01, "HoopB rim center X == 0.0")
	runner.assert_approx(rim_b.y, 3.05, 0.01, "HoopB rim center Y == 3.05")
	runner.assert_approx(rim_b.z, -12.425, 0.01, "HoopB rim center Z == -12.425")
	runner.assert_eq(int(hoop_b.get("defended_by_team")), 1, "HoopB defended_by_team == 1")

	for hoop_pair in [["HoopA", hoop_a, 12.80], ["HoopB", hoop_b, -12.80]]:
		var hname: String = hoop_pair[0]
		var hoop: Node3D = hoop_pair[1]
		var expected_bb_front_z: float = hoop_pair[2]

		var seg_count: int = int(hoop.call("get_rim_segment_count"))
		runner.assert_eq(seg_count, 12, "%s has 12 discrete hollow rim collider segments" % hname)

		var upper_gate := hoop.get_node_or_null("UpperGate") as Area3D
		var lower_gate := hoop.get_node_or_null("LowerGate") as Area3D
		runner.assert_not_null(upper_gate, "%s UpperGate Area3D exists" % hname)
		runner.assert_not_null(lower_gate, "%s LowerGate Area3D exists" % hname)
		if upper_gate != null and lower_gate != null:
			runner.assert_approx(upper_gate.global_position.y, 3.08, 0.01, "%s UpperGate at y = 3.08m" % hname)
			runner.assert_approx(lower_gate.global_position.y, 2.86, 0.01, "%s LowerGate at y = 2.86m" % hname)

		var bb := hoop.get_node_or_null("Backboard") as StaticBody3D
		runner.assert_not_null(bb, "%s Backboard StaticBody3D exists" % hname)
		if bb != null:
			var bb_cs := bb.get_node_or_null("CollisionShape3D") as CollisionShape3D
			if bb_cs != null and bb_cs.shape is BoxShape3D:
				var bb_box := bb_cs.shape as BoxShape3D
				runner.assert_approx(bb_box.size.x, 1.80, 0.02, "%s Backboard width == 1.80m" % hname)
				runner.assert_approx(bb_box.size.y, 1.05, 0.02, "%s Backboard height == 1.05m" % hname)
				var bb_bottom_y: float = bb_cs.global_position.y - bb_box.size.y * 0.5
				runner.assert_approx(bb_bottom_y, 2.90, 0.02, "%s Backboard bottom edge y == 2.90m" % hname)
				var sign_z: float = signf(expected_bb_front_z)
				var bb_front_z: float = bb_cs.global_position.z - sign_z * (bb_box.size.z * 0.5)
				runner.assert_approx(bb_front_z, expected_bb_front_z, 0.02, "%s Backboard front plane at z = %.2fm" % [hname, expected_bb_front_z])

		runner.assert_not_null(hoop.get_node_or_null("NetVerlet"), "%s Verlet 3D net node exists" % hname)


# ==============================================================================
# 2. Hollow Rim Drop-Through (+2 & +3 Score) & Upward Under-Rim Rejection
# ==============================================================================
func _test_hollow_rim_scoring_and_under_rim_rejection(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena: Node3D = await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var hoop_a := arena.get_node_or_null("HoopA") as Node3D
	var hoop_b := arena.get_node_or_null("HoopB") as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D

	if not runner.assert_not_null(ball, "Basketball present in Arena"):
		return

	# Park LocalPlayer safely at center court with idle external input so it never touches the ball
	if player != null:
		player.global_position = Vector3(4.0, 0.0, 0.0)
		player.call("set_external_input_provider", func(_tick: int, _dt: float) -> Dictionary:
			return {"seq": 1, "tick": _tick, "move_world_xz": Vector2.ZERO, "local_dir": Vector2.ZERO, "buttons": 0, "aim_yaw": 0.0}
		)

	var score_events: Array[Dictionary] = []
	var eb: Node = runner.get_event_bus()
	var gs: Node = runner.get_game_state()
	runner.connect_temp_signal(eb.score_changed, func(team_id: int, new_score: int, delta: int, is_three: bool, scorer_id: int) -> void:
		score_events.append({
			"team_id": team_id,
			"new_score": new_score,
			"delta": delta,
			"is_three": is_three,
			"scorer_id": scorer_id,
		})
	)

	var upper_a := hoop_a.get_node_or_null("UpperGate") as Area3D
	var lower_a := hoop_a.get_node_or_null("LowerGate") as Area3D
	var crossed_upper_down := [false]
	var crossed_lower_down := [false]
	runner.connect_temp_signal(upper_a.body_entered, func(b: Node) -> void:
		if b == ball and ball.linear_velocity.y < 0.0:
			crossed_upper_down[0] = true
	)
	runner.connect_temp_signal(lower_a.body_entered, func(b: Node) -> void:
		if b == ball and ball.linear_velocity.y < 0.0:
			crossed_lower_down[0] = true
	)

	# --- 2A. Drop ball from (0, 3.8, 12.425) straight through hollow 12-segment rim of HoopA (+2 score) ---
	var scores_before: Array = gs.get("scores").duplicate()
	ball.call("reset_to_free", Vector3(0.0, 3.8, 12.425))
	await runner.wait_physics_frames(45)

	runner.assert_lt(ball.global_position.y, 2.5, "Ball physically fell cleanly through hollow 12-segment rim below y=2.5m")
	runner.assert_true(crossed_upper_down[0], "Ball crossed HoopA UpperGate downward")
	runner.assert_true(crossed_lower_down[0], "Ball crossed HoopA LowerGate downward")
	runner.assert_eq(score_events.size(), 1, "Downward drop through HoopA triggered exactly 1 score_changed event")
	if score_events.size() >= 1:
		var ev2: Dictionary = score_events[0]
		runner.assert_eq(int(ev2["team_id"]), 1, "HoopA (defended by Team 0) awards score to attacking Team 1")
		runner.assert_eq(int(ev2["delta"]), 2, "Close drop at rim XZ awards +2 points")
		runner.assert_false(bool(ev2["is_three"]), "Close drop is classified as 2-pointer (is_three == false)")
	runner.assert_eq(int(gs.get("scores")[1]), int(scores_before[1]) + 2, "GameState Team 1 score incremented by +2")

	# --- 2B. 3-Point shot origin drop through HoopB (z = -12.425) triggers +3 score for Team 0 ---
	score_events.clear()
	hoop_b.call("reset_hoop_state")
	ball.call(
		"launch_shot",
		null,
		1,
		0,
		Vector3(0.0, 3.8, -12.425),
		Vector3(0.0, 0.0, -4.5), # dist_xz = 7.925m > 6.75m -> 3-pointer!
		Vector3(0.0, 3.05, -12.425),
		Vector3(0.0, -0.5, 0.0),
		Vector3.ZERO,
		true
	)
	await runner.wait_physics_frames(45)

	runner.assert_lt(ball.global_position.y, 2.5, "3pt-origin drop passed cleanly through HoopB hollow rim")
	runner.assert_eq(score_events.size(), 1, "Downward 3pt pass through HoopB triggered 1 score_changed event")
	if score_events.size() >= 1:
		var ev3: Dictionary = score_events[0]
		runner.assert_eq(int(ev3["team_id"]), 0, "HoopB (defended by Team 1) awards score to attacking Team 0")
		runner.assert_eq(int(ev3["delta"]), 3, "Shot from dist_xz > 6.75m awards +3 points")
		runner.assert_true(bool(ev3["is_three"]), "Shot from dist_xz > 6.75m sets is_three == true")

	# --- 2C. Upward Under-Rim False-Score Rejection from (0, 2.4, 12.425) ---
	# Launch upward through LowerGate -> Rim -> UpperGate to apex ~4.9m, AND let it fall back down through UpperGate -> LowerGate!
	# Neither the upward pass NOR the tainted return fall may score!
	score_events.clear()
	hoop_a.call("reset_hoop_state")
	var score_t0_pre: int = int(gs.get("scores")[0])
	var score_t1_pre: int = int(gs.get("scores")[1])

	ball.call("reset_to_free", Vector3(0.0, 2.4, 12.425))
	await runner.wait_physics_frames(1)
	ball.linear_velocity = Vector3(0.0, 7.0, 0.0)

	var max_ball_y: float = ball.global_position.y
	for _i in range(95):
		await runner.physics_frame
		if ball.global_position.y > max_ball_y:
			max_ball_y = ball.global_position.y

	runner.assert_gt(max_ball_y, 3.45, "Under-rim upward launch rose completely above UpperGate (max_y=%.2fm)" % max_ball_y)
	runner.assert_lt(ball.global_position.y, 2.5, "Ball subsequently fell back below hoop after under-rim launch")
	runner.assert_eq(score_events.size(), 0, "Upward under-rim launch (including return descent) emitted ZERO false scores")
	runner.assert_eq(int(gs.get("scores")[0]), score_t0_pre, "Team 0 score unchanged after upward under-rim pass")
	runner.assert_eq(int(gs.get("scores")[1]), score_t1_pre, "Team 1 score unchanged after upward under-rim pass")


# ==============================================================================
# 3. Camera-Relative Movement, Sprint > Run, Jump/Land, & AnimationTree States
# ==============================================================================
func _test_player_movement_jump_and_animation_tree(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena: Node3D = await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D

	if not runner.assert_not_null(player, "LocalPlayer CharacterBody3D exists in Arena"):
		return

	# Park ball out of player's path so movement/jump tests measure pure locomotion
	if ball != null:
		ball.call("reset_to_free", Vector3(6.5, 0.5, 11.0))

	# Verify canonical ARCHITECTURE.md Section 7 public methods exist
	runner.assert_has_method(player, "set_external_input_provider", "PlayerController exposes set_external_input_provider")
	runner.assert_has_method(player, "apply_archetype", "PlayerController exposes apply_archetype")
	runner.assert_has_method(player, "execute_combo_move", "PlayerController exposes execute_combo_move")
	runner.assert_has_method(player, "export_sim_state", "PlayerController exposes export_sim_state")
	runner.assert_has_method(player, "import_sim_state", "PlayerController exposes import_sim_state")

	# Verify real active AnimationTree + AnimationNodeStateMachine
	var animator := player.get_node_or_null("CharacterAnimator") as Node3D
	runner.assert_not_null(animator, "CharacterAnimator node exists on LocalPlayer")
	var anim_tree: AnimationTree = animator.call("get_animation_tree") if animator != null else null
	if not runner.assert_not_null(anim_tree, "Real AnimationTree exists on CharacterAnimator"):
		return
	runner.assert_true(anim_tree.active, "AnimationTree is active")
	runner.assert_true(anim_tree.tree_root is AnimationNodeStateMachine, "AnimationTree root is AnimationNodeStateMachine")
	var playback := anim_tree.get("parameters/playback") as AnimationNodeStateMachinePlayback
	runner.assert_not_null(playback, "AnimationTree parameters/playback is valid AnimationNodeStateMachinePlayback")

	# Shared mutable input state fed via canonical PlayerInputFrame provider
	var input_ctrl := {
		"local_dir": Vector2.ZERO,
		"buttons": 0,
		"aim_yaw": 0.0,
	}
	var seq_counter := [0]
	player.call("set_external_input_provider", func(tick: int, _dt: float) -> Dictionary:
		seq_counter[0] += 1
		return {
			"seq": seq_counter[0],
			"tick": tick,
			"move_world_xz": Vector2.ZERO,
			"local_dir": input_ctrl["local_dir"],
			"buttons": int(input_ctrl["buttons"]),
			"aim_yaw": float(input_ctrl["aim_yaw"]),
		}
	)

	# --- 3A. Idle state on floor ---
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	await runner.wait_physics_frames(6)
	runner.assert_true(player.is_on_floor(), "Player settles grounded on floor at y=0")
	runner.assert_eq(String(playback.get_current_node()), "idle", "AnimationTree state starts in 'idle'")

	# --- 3B. Camera-relative movement: yaw = 0 -> forward moves -Z; yaw = -PI/2 -> forward moves +X ---
	var start_pos_a: Vector3 = player.global_position
	input_ctrl["local_dir"] = Vector2(0.0, 1.0)
	input_ctrl["buttons"] = 0
	input_ctrl["aim_yaw"] = 0.0
	await runner.wait_physics_frames(24)

	var after_fwd_z: Vector3 = player.global_position
	var run_speed_measured: float = Vector2(player.velocity.x, player.velocity.z).length()
	runner.assert_lt(after_fwd_z.z - start_pos_a.z, -1.5, "Camera yaw=0 + local forward moves player along -Z")
	runner.assert_approx(after_fwd_z.x - start_pos_a.x, 0.0, 0.05, "Camera yaw=0 + local forward has ~0 X drift")
	runner.assert_eq(String(playback.get_current_node()), "run", "AnimationTree transitions 'idle' -> 'run'")
	runner.assert_approx(run_speed_measured, 6.2, 0.35, "Steady-state run speed matches ~6.2 m/s")

	# Rotate camera aim_yaw by -90 deg (-PI/2 -> camera faces +X) while keeping identical local_dir = (0, 1)
	input_ctrl["local_dir"] = Vector2.ZERO
	input_ctrl["buttons"] = 0
	input_ctrl["aim_yaw"] = -PI * 0.5
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	await runner.wait_physics_frames(3)
	input_ctrl["local_dir"] = Vector2(0.0, 1.0)
	await runner.wait_physics_frames(24)

	var after_fwd_x: Vector3 = player.global_position
	runner.assert_gt(after_fwd_x.x, 1.5, "Camera yaw=-PI/2 + local forward moves player along +X (camera-relative)")
	runner.assert_approx(after_fwd_x.z, 0.0, 0.05, "Camera yaw=-PI/2 + local forward has ~0 Z drift")

	# --- 3C. Sprint speed > Run speed & 'sprint' AnimationTree state ---
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 4.0)))
	await runner.wait_physics_frames(3)
	input_ctrl["local_dir"] = Vector2(0.0, 1.0)
	input_ctrl["buttons"] = 1 # BTN_SPRINT
	input_ctrl["aim_yaw"] = 0.0
	await runner.wait_physics_frames(24)

	var sprint_speed_measured: float = Vector2(player.velocity.x, player.velocity.z).length()
	runner.assert_gt(sprint_speed_measured, run_speed_measured + 1.8, "Sprint speed (%.2f) > Run speed (%.2f)" % [sprint_speed_measured, run_speed_measured])
	runner.assert_approx(sprint_speed_measured, 8.8, 0.45, "Steady-state sprint speed matches ~8.8 m/s")
	runner.assert_eq(String(playback.get_current_node()), "sprint", "AnimationTree transitions 'run' -> 'sprint'")

	# --- 3D. Jump & Land cycle + AnimationTree ('jump_start' -> 'fall' -> 'land' -> 'idle') ---
	input_ctrl["local_dir"] = Vector2.ZERO
	input_ctrl["buttons"] = 0
	await runner.wait_physics_frames(12)

	# Trigger jump edge (BTN_JUMP = 2)
	input_ctrl["buttons"] = 2
	await runner.wait_physics_frames(2)
	input_ctrl["buttons"] = 0

	var saw_jump_start: bool = (String(playback.get_current_node()) == "jump_start")
	var saw_fall: bool = false
	var saw_land: bool = false
	var peak_player_y: float = player.global_position.y

	for _step in range(75):
		await runner.physics_frame
		if player.global_position.y > peak_player_y:
			peak_player_y = player.global_position.y
		var st_now := String(playback.get_current_node())
		if st_now == "jump_start":
			saw_jump_start = true
		elif st_now == "fall":
			saw_fall = true
		elif st_now == "land":
			saw_land = true

	runner.assert_gt(peak_player_y, 1.15, "Jump impulse lifts player above y=1.15m (peak=%.2fm)" % peak_player_y)
	runner.assert_true(player.is_on_floor(), "Player lands cleanly back on court floor")
	runner.assert_true(saw_jump_start, "AnimationTree entered 'jump_start' during upward ascent")
	runner.assert_true(saw_fall, "AnimationTree entered 'fall' during airborne descent")
	runner.assert_true(saw_land, "AnimationTree entered 'land' during touchdown recovery frames")

	await runner.wait_physics_frames(12)
	runner.assert_eq(String(playback.get_current_node()), "idle", "AnimationTree returns to 'idle' after landing recovery")

	# --- 3E. Snapshot export/import roundtrip (Section 7 contract) ---
	var snap: Dictionary = player.call("export_sim_state")
	player.global_position = Vector3(-5.0, 2.0, 9.0)
	player.velocity = Vector3(3.0, -2.0, 4.0)
	player.call("import_sim_state", snap)
	runner.assert_approx(player.global_position.distance_to(snap["position"]), 0.0, 0.001, "export_sim_state / import_sim_state restores exact position")

	player.call("set_external_input_provider", null)


# ==============================================================================
# 4. Basketball Floor Restitution (~0.78) & Backboard / Rim Collisions
# ==============================================================================
func _test_basketball_restitution_and_surface_collisions(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena: Node3D = await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D

	if not runner.assert_not_null(ball, "Basketball RigidBody3D exists for physics tests"):
		return

	if player != null:
		player.global_position = Vector3(-6.0, 0.0, 0.0)
		player.call("set_external_input_provider", func(_tick: int, _dt: float) -> Dictionary:
			return {"seq": 1, "tick": _tick, "move_world_xz": Vector2.ZERO, "local_dir": Vector2.ZERO, "buttons": 0, "aim_yaw": 0.0}
		)

	runner.assert_approx(ball.mass, 0.62, 0.01, "Basketball mass == 0.62 kg")

	var bounce_surfaces: Array[String] = []
	var eb: Node = runner.get_event_bus()
	runner.connect_temp_signal(eb.ball_bounced, func(_pos: Vector3, _spd: float, surface_type: String) -> void:
		bounce_surfaces.append(surface_type)
	)

	# --- 4A. Floor bounce restitution (~0.78) ---
	# Drop from center y0 = 1.62m -> height above ball-floor contact (y=0.12m) is h0 = 1.50m.
	# Expected apex height above contact: h1 = e^2 * h0 = 0.78^2 * 1.50 = 0.9126m -> e = sqrt(h1 / h0) ≈ 0.78.
	var drop_center_y: float = 1.62
	var contact_y: float = 0.12
	var h0: float = drop_center_y - contact_y
	ball.call("reset_to_free", Vector3(0.0, drop_center_y, 0.0))

	var hit_floor: bool = false
	var min_vy_before_bounce: float = 0.0
	var max_vy_after_bounce: float = 0.0
	var rebound_apex_y: float = 0.0
	for _i in range(95):
		await runner.physics_frame
		if not hit_floor:
			if ball.linear_velocity.y < min_vy_before_bounce:
				min_vy_before_bounce = ball.linear_velocity.y
			if ball.linear_velocity.y > 0.2 and ball.global_position.y < 0.6:
				hit_floor = true
				max_vy_after_bounce = ball.linear_velocity.y
		if hit_floor:
			if ball.linear_velocity.y > max_vy_after_bounce:
				max_vy_after_bounce = ball.linear_velocity.y
			if ball.global_position.y > rebound_apex_y:
				rebound_apex_y = ball.global_position.y

	var vel_ratio: float = max_vy_after_bounce / maxf(0.001, absf(min_vy_before_bounce))
	var h1: float = maxf(0.0, rebound_apex_y - contact_y)
	var measured_restitution: float = sqrt(h1 / h0)
	runner.assert_true(hit_floor, "Basketball bounced upward off CourtFloor")
	runner.assert_approx(
		measured_restitution,
		0.78,
		0.05,
		"Basketball floor bounce restitution ~0.78 (vel_ratio=%.4f, apex_y=%.4f)" % [vel_ratio, rebound_apex_y]
	)
	runner.assert_true(bounce_surfaces.has("court"), "EventBus.ball_bounced emitted with surface_type == 'court'")

	# --- 4B. Backboard collision & rebound (HoopA backboard front plane at z = +12.80, y in [2.90, 3.95]) ---
	bounce_surfaces.clear()
	ball.call("reset_to_free", Vector3(0.0, 3.45, 11.60))
	await runner.wait_physics_frames(1)
	ball.linear_velocity = Vector3(0.0, 1.1, 7.5) # Aim straight into backboard glass above rim

	var rebounded_backboard: bool = false
	for _i in range(35):
		await runner.physics_frame
		if ball.linear_velocity.z < -2.0:
			rebounded_backboard = true
			break

	runner.assert_true(rebounded_backboard, "Basketball physically collided and rebounded (-Z) off HoopA Backboard")
	runner.assert_true(bounce_surfaces.has("backboard"), "EventBus.ball_bounced emitted with surface_type == 'backboard'")

	# --- 4C. Rim segment collision (drop directly onto front rim lip at z = 12.425 - 0.235 = 12.190) ---
	bounce_surfaces.clear()
	ball.call("reset_to_free", Vector3(0.0, 3.65, 12.190))
	var rim_deflected: bool = false
	for _i in range(40):
		await runner.physics_frame
		if absf(ball.linear_velocity.z) > 0.25 or (ball.linear_velocity.y > 0.2 and ball.global_position.y > 3.0):
			rim_deflected = true
			break

	runner.assert_true(rim_deflected, "Basketball collided and deflected off discrete hollow rim collider segment")
	runner.assert_true(bounce_surfaces.has("rim"), "EventBus.ball_bounced emitted with surface_type == 'rim'")


# ==============================================================================
# 5. 2pt vs 3pt Classification, Match Timer, 24s Shot Clock, & restart_match()
# ==============================================================================
func _test_match_rules_timers_and_restart(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena: Node3D = await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var mc := arena.get_node_or_null("MatchController") as Node
	var sc := arena.get_node_or_null("MatchController/ShotClock") as Node
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D

	if not runner.assert_not_null(mc, "MatchController exists in Arena") or not runner.assert_not_null(sc, "ShotClock exists under MatchController"):
		return

	var eb: Node = runner.get_event_bus()
	var gs: Node = runner.get_game_state()

	# --- 5A. 2pt vs 3pt line classification (dist_xz <= 6.75 vs > 6.75 and corner |x| > 6.60) ---
	var rim_a := Vector3(0.0, 3.05, 12.425)
	var rim_b := Vector3(0.0, 3.05, -12.425)

	# Paint / Midrange / Exact 6.75m boundary -> 2pt
	var c_paint: Dictionary = mc.call("classify_shot", Vector3(0.0, 0.0, 10.0), rim_a)
	runner.assert_eq(int(c_paint["points"]), 2, "Paint shot (dist=2.425m) classified as 2pt")
	runner.assert_false(bool(c_paint["is_three"]), "Paint shot is_three == false")

	var c_exact_arc: Dictionary = mc.call("classify_shot", Vector3(0.0, 0.0, 12.425 - 6.75), rim_a)
	runner.assert_eq(int(c_exact_arc["points"]), 2, "Exact arc boundary dist_xz == 6.75m classified as 2pt (<= 6.75)")

	var c_inside_corner: Dictionary = mc.call("classify_shot", Vector3(6.55, 0.0, 12.20), rim_a)
	runner.assert_eq(int(c_inside_corner["points"]), 2, "Inside corner line (|x|=6.55 <= 6.60, dist <= 6.75) classified as 2pt")

	# Top of arc > 6.75m -> 3pt
	var c_top_three: Dictionary = mc.call("classify_shot", Vector3(0.0, 0.0, 12.425 - 6.80), rim_a)
	runner.assert_eq(int(c_top_three["points"]), 3, "Beyond top arc (dist_xz=6.80 > 6.75) classified as 3pt")
	runner.assert_true(bool(c_top_three["is_three"]), "Beyond top arc sets is_three == true")

	# Left & Right Corner 3s (|x| > 6.60 while dist_xz = 6.65 <= 6.75!) -> 3pt
	var c_corner_left: Dictionary = mc.call("classify_shot", Vector3(-6.65, 0.0, 12.425), rim_a)
	runner.assert_eq(int(c_corner_left["points"]), 3, "Left corner |x|=6.65 > 6.60 (dist=6.65 <= 6.75) classified as 3pt")

	var c_corner_right_b: Dictionary = mc.call("classify_shot", Vector3(6.68, 0.0, -12.30), rim_b)
	runner.assert_eq(int(c_corner_right_b["points"]), 3, "Right corner on HoopB |x|=6.68 > 6.60 classified as 3pt")

	# --- 5B. Match Timer (180s) & 24s Shot Clock deterministic 60 Hz countdown ---
	mc.call("restart_match")
	var timer_events := [0]
	runner.connect_temp_signal(eb.timer_updated, func(_m_left: float, _sc_left: float) -> void:
		timer_events[0] += 1
	)

	var m_start: float = float(gs.get("match_seconds_left"))
	var sc_start: float = float(gs.get("shot_clock_left"))
	runner.assert_approx(m_start, 180.0, 0.05, "Match timer initializes to 180.0s")
	runner.assert_approx(sc_start, 24.0, 0.05, "Shot clock initializes to 24.0s")

	await runner.wait_physics_frames(60) # Exact 1.00s at 60 Hz

	var m_after_1s: float = float(gs.get("match_seconds_left"))
	var sc_after_1s: float = float(gs.get("shot_clock_left"))
	runner.assert_approx(m_after_1s, 179.0, 0.08, "Match timer counts down by 1.0s over 60 physics frames")
	runner.assert_approx(sc_after_1s, 23.0, 0.08, "24s shot clock counts down by 1.0s over 60 physics frames")
	runner.assert_gt(float(timer_events[0]), 30.0, "EventBus.timer_updated emitted continuously during countdown")

	# Test 24s shot clock expiration turnover & auto-reset
	gs.call("set_possession", 0, 1)
	sc.call("reset_clock", 0.20)
	await runner.wait_physics_frames(18) # 0.30s -> expires!
	runner.assert_eq(int(gs.get("possession_team")), 1, "Shot clock expiration flips possession from Team 0 to Team 1")
	runner.assert_gt(float(gs.get("shot_clock_left")), 23.5, "Shot clock resets back to 24s after violation")

	# --- 5C. restart_match() full state reset ---
	var restarted_count := [0]
	var started_count := [0]
	runner.connect_temp_signal(eb.match_restarted, func() -> void: restarted_count[0] += 1)
	runner.connect_temp_signal(eb.match_started, func(_cfg: Dictionary) -> void: started_count[0] += 1)

	# Dirty every piece of match, player, and ball state
	gs.call("set_team_score", 0, 11, 3, true, 1)
	gs.call("set_team_score", 1, 8, 2, false, 2)
	gs.call("update_timers", 42.5, 5.2)
	if player != null:
		player.global_position = Vector3(5.5, 1.5, 9.2)
		player.velocity = Vector3(4.0, 2.0, -3.0)
		if ball != null:
			ball.call("set_controlled_state", 1, player, 1, 0) # HELD

	mc.call("restart_match")
	await runner.wait_physics_frames(2)

	runner.assert_eq(restarted_count[0], 1, "restart_match() emitted EventBus.match_restarted")
	runner.assert_eq(started_count[0], 1, "restart_match() emitted EventBus.match_started")
	runner.assert_eq(int(gs.get("scores")[0]), 0, "restart_match() resets Team 0 score to 0")
	runner.assert_eq(int(gs.get("scores")[1]), 0, "restart_match() resets Team 1 score to 0")
	runner.assert_approx(float(gs.get("match_seconds_left")), 180.0, 0.10, "restart_match() restores match timer to 180s")
	runner.assert_approx(float(gs.get("shot_clock_left")), 24.0, 0.10, "restart_match() restores shot clock to 24s")
	runner.assert_eq(int(gs.get("ball_carrier_id")), -1, "restart_match() clears ball_carrier_id")

	if player != null:
		runner.assert_approx(player.global_position.distance_to(Vector3(0.0, 0.0, -3.5)), 0.0, 0.15, "restart_match() restores LocalPlayer to spawn (0, 0, -3.5)")
	if ball != null:
		runner.assert_eq(String(ball.call("get_state_name")), "FREE", "restart_match() resets Basketball state to FREE")
		var spawn_ball: Vector3 = mc.get("ball_spawn_position")
		runner.assert_approx(ball.global_position.x, spawn_ball.x, 0.05, "restart_match() restores Basketball spawn X")
		runner.assert_approx(ball.global_position.z, spawn_ball.z, 0.05, "restart_match() restores Basketball spawn Z")


# ==============================================================================
# 6. Main Boot Router (`res://scenes/main.tscn`) Integration Smoke Check
# ==============================================================================
func _test_main_boot_router_scene(runner: SceneTree) -> void:
	await runner.clear_stage()
	var main_node: Node = await runner.mount_scene(MAIN_SCENE_PATH)
	if not runner.assert_not_null(main_node, "res://scenes/main.tscn boots cleanly"):
		return
	await runner.wait_physics_frames(5)
	var loaded_arena := main_node.get_node_or_null("Arena")
	runner.assert_not_null(loaded_arena, "main.tscn routes automatically into Arena when main_menu.tscn is not yet present")
