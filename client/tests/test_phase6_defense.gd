extends Node
## Phase 6 Automated Verification Suite — Defensive Gameplay (PHANTOM COURT ONLINE)
## Verifies:
## 1. Defensive Stance (BTN_STANCE / C and off-ball BTN_PASS / RMB): lowered posture
##    ("defensive_stance" AnimationTree state), +25% lateral shuffle accel, instant facing
##    lock toward ball-handler, widened shot contest cone & 1.15m pass interception reach,
##    and +40% balance resistance.
## 2. Frame-accurate Active Stealing (BTN_STEAL / F): 6f STARTUP -> 5f ACTIVE -> 24f
##    WHIFF_RECOVERY (0.45x speed, stance/steal/jump locked), protected-hip behind-the-back
##    failure into 24f whiff recovery, successful active dribble strip skipping whiff recovery
##    (+22 Zone), and skillful positioning / exposed-dribble / low-stamina strip reach bonuses.
## 3. Shot Contesting, Vertical Apex Blocking & 18f Block-Landing Recovery: disciplined
##    hands-up stance contest (> 0.70), timed vertical swat (SHOT_FLIGHT -> FREE, block_performed,
##    no baited landing penalty), and baited missed block jump landing into 18f block_recovery_frames
##    (0.55x speed, action lock, collapsed contest < 0.20 giving shooter an open look).
## 4. Pass Lane Interception: opponent PASS_FLIGHT intercepted at <= 1.15m in DEFENSIVE_STANCE
##    (missed at 1.00m out of stance), <= 0.85m moving/facing, increments interceptions_made,
##    transfers possession (EventBus.possession_changed), awards +22 Zone, blocked in recovery.
## 5. Defensive Positioning Alignment [0..1], Momentum & Balance Meter, and 66f Ankle-Break
##    Reaction: normal crossover breaks an over-committed sprinting defender's ankles
##    ("ankle_stumble", 66f lock, lateral knockback, EventBus.ankle_broken, clean restore to 100
##    balance), whereas a well-positioned defender in DEFENSIVE_STANCE absorbs the cross (> 50 bal).
## 6. Deterministic rollback snapshot roundtrip for all Phase 6 defensive state fields.

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
const BTN_ZONE: int    = 256
const BTN_STANCE: int  = 512

const HOOP_B_RIM := Vector3(0.0, 3.05, -12.425)


func run(runner: SceneTree) -> void:
	await _test_defensive_stance_mechanics(runner)
	await _test_active_steal_frames_and_whiff_recovery(runner)
	await _test_shot_contest_vertical_block_and_landing_recovery(runner)
	await _test_pass_lane_interception(runner)
	await _test_positioning_momentum_balance_and_ankle_break(runner)
	await _test_phase6_snapshot_roundtrip(runner)


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
# 1. Defensive Stance (C / off-ball RMB), Posture, +25% Lateral Accel, Facing
#    Lock, Widened Contest Cone, 1.15m Intercept Reach & +40% Balance Resistance
# ==============================================================================
func _test_defensive_stance_mechanics(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var defender := _spawn_extra_player(arena, "StanceDef", 2, 1, Vector3(0.0, 0.0, -6.0))
	if not runner.assert_not_null(offense, "Stance: LocalPlayer present") or not runner.assert_not_null(defender, "Stance: Defender spawned"):
		return
	await runner.wait_physics_frames(2)

	var off_ctrl := _make_input_controller(offense)
	var def_ctrl := _make_input_controller(defender)
	var def_sys: Node = defender.defense_system

	# Neutral setup: offense holds ball at (0, 0, -4.0), defender at (0, 0, -6.55) (2.55m toward HoopB)
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.55)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Baseline out-of-stance checks
	var idle_pelvis_y: float = float(defender.animator.pelvis.position.y)
	var base_accel: float = float(defender.call("get_effective_acceleration"))
	var base_bal_res: float = float(defender.call("get_effective_balance_resistance"))
	runner.assert_false(bool(defender.call("is_in_defensive_stance")), "Defender starts out of defensive stance")
	runner.assert_false(bool(def_sys.call("is_in_stance")), "DefenseSystem.is_in_stance() starts false")
	runner.assert_approx(float(def_sys.call("get_lateral_accel_multiplier")), 1.0, 0.001, "Out-of-stance lateral accel multiplier == 1.0")
	runner.assert_approx(float(def_sys.call("get_stance_balance_resistance")), 1.0, 0.001, "Out-of-stance balance resistance mult == 1.0")
	runner.assert_approx(float(def_sys.call("get_pass_interception_radius", false)), 0.85, 0.001, "Out-of-stance pass interception reach == 0.85m")

	# At 2.55m (> 2.40m normal range, < 2.75m stance range), out-of-stance shot contest == 0.0
	var contest_out_255: float = float(DefenseSystem.compute_shot_contest(offense, HOOP_B_RIM))
	runner.assert_approx(contest_out_255, 0.0, 0.001, "At 2.55m out-of-stance defender does NOT reach shot contest cone")

	# Face defender completely AWAY from offense (facing -Z while offense is at +Z from defender)
	defender.set("facing_yaw", 0.0) # forward = (0, 0, -1), completely opposite offense at (0, 0, -4.0)
	def_ctrl["buttons"] = BTN_STANCE
	await runner.wait_physics_frames(1)

	# Frame-1 instant facing lock toward ball-handler (+Z -> yaw ~ PI or -PI)
	var locked_fwd := Vector2(-sin(float(defender.get("facing_yaw"))), -cos(float(defender.get("facing_yaw"))))
	var to_offense := Vector2(offense.global_position.x - defender.global_position.x, offense.global_position.z - defender.global_position.z).normalized()
	runner.assert_true(bool(defender.call("is_in_defensive_stance")), "BTN_STANCE (C) activates defensive stance")
	runner.assert_true(bool(def_sys.call("is_in_stance")), "DefenseSystem.is_in_stance() == true under BTN_STANCE")
	runner.assert_gt(locked_fwd.dot(to_offense), 0.98, "Stance locks facing instantly toward ball-handler on frame 1 (dot=%.3f)" % locked_fwd.dot(to_offense))
	runner.assert_eq(defender.call("get_animation_state"), &"defensive_stance", "CharacterAnimator enters 'defensive_stance' AnimationTree state")

	# Wait 6 frames for AnimationTree crouch posture & verify lowered pelvis
	await runner.wait_physics_frames(6)
	var stance_pelvis_y: float = float(defender.animator.pelvis.position.y)
	runner.assert_lt(stance_pelvis_y, idle_pelvis_y - 0.08, "Defensive stance lowers rig pelvis posture (%.2f < %.2f)" % [stance_pelvis_y, idle_pelvis_y])

	# Verify +25% lateral accel, +40% balance resistance, 1.15m intercept reach & widened 2.75m shot contest
	runner.assert_approx(float(def_sys.call("get_lateral_accel_multiplier")), 1.25, 0.001, "Stance lateral accel multiplier == 1.25 (+25%)")
	runner.assert_approx(float(defender.call("get_effective_acceleration")), base_accel * 1.25, 0.05, "Player effective acceleration scales by 1.25x in stance")
	runner.assert_approx(float(def_sys.call("get_stance_balance_resistance")), 1.40, 0.001, "Stance balance resistance multiplier == 1.40 (+40%)")
	runner.assert_approx(float(defender.call("get_effective_balance_resistance")), base_bal_res * 1.40, 0.01, "Player effective balance resistance scales by 1.40x in stance")
	runner.assert_approx(float(def_sys.call("get_pass_interception_radius", false)), 1.15, 0.001, "Stance pass interception reach widens to 1.15m")

	var contest_stance_255: float = float(DefenseSystem.compute_shot_contest(offense, HOOP_B_RIM))
	runner.assert_gt(contest_stance_255, 0.05, "At 2.55m defensive stance widens shot contest cone (actual=%.3f)" % contest_stance_255)

	# Verify balance damage mitigation in stance (+40% resistance): 70 raw dmg -> 50 dmg vs 70 dmg out of stance
	defender.set("balance", 100.0)
	defender.call("apply_balance_damage", 70.0, 1)
	var bal_after_stance: float = float(defender.get("balance"))
	runner.assert_approx(bal_after_stance, 100.0 - (70.0 / (base_bal_res * 1.40)), 0.5, "Stance reduces balance damage via +40% resistance")

	# Verify off-ball BTN_PASS (RMB) ALSO activates defensive stance
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(2)
	runner.assert_false(bool(defender.call("is_in_defensive_stance")), "Releasing BTN_STANCE exits defensive stance")
	def_ctrl["buttons"] = BTN_PASS
	await runner.wait_physics_frames(1)
	runner.assert_true(bool(defender.call("is_in_defensive_stance")), "Off-ball BTN_PASS (RMB) activates defensive stance")
	runner.assert_eq(defender.call("get_animation_state"), &"defensive_stance", "Off-ball RMB enters 'defensive_stance' anim state")
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(1)

	# Live 60 Hz lateral shuffle acceleration comparison (2-frame velocity ramp from standstill)
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.0)))
	def_ctrl["move_world_xz"] = Vector2(1.0, 0.0)
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(2)
	var dv_normal_2f: float = absf(defender.velocity.x)

	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.0)))
	def_ctrl["move_world_xz"] = Vector2(1.0, 0.0)
	def_ctrl["buttons"] = BTN_STANCE
	await runner.wait_physics_frames(2)
	var dv_stance_2f: float = absf(defender.velocity.x)
	def_ctrl["move_world_xz"] = Vector2.ZERO
	def_ctrl["buttons"] = 0

	runner.assert_gt(dv_stance_2f, dv_normal_2f * 1.18, "Live 60 Hz stance lateral shuffle accel exceeds normal run (%.2f vs %.2f)" % [dv_stance_2f, dv_normal_2f])
	off_ctrl["buttons"] = 0


# ==============================================================================
# 2. Frame-Accurate Active Steal (6f STARTUP -> 5f ACTIVE -> 24f WHIFF_RECOVERY)
#    Protected-Hip Shield Failure, Successful Strip & Skillful Reach Bonuses
# ==============================================================================
func _test_active_steal_frames_and_whiff_recovery(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var defender := _spawn_extra_player(arena, "StealDef", 2, 1, Vector3(0.0, 0.0, -6.0))
	if not runner.assert_not_null(offense, "Steal: LocalPlayer present") or not runner.assert_not_null(defender, "Steal: Defender spawned"):
		return
	await runner.wait_physics_frames(2)

	var off_ctrl := _make_input_controller(offense)
	var def_ctrl := _make_input_controller(defender)
	var def_sys: Node = defender.defense_system
	var eb: Node = runner.get_event_bus()

	var steal_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.steal_performed, func(sid: int, vid: int, pos: Vector3) -> void:
		steal_events.append({"stealer": sid, "victim": vid, "pos": pos})
	)

	# --- 2A. Exact 6f STARTUP -> 5f ACTIVE -> 24f WHIFF_RECOVERY frame audit on open-air whiff ---
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, 6.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "IDLE", "Steal phase starts IDLE")
	runner.assert_false(bool(def_sys.call("is_in_recovery")), "Defender not in recovery initially")

	# Tick 1: press BTN_STEAL -> STARTUP with 6 frames left
	def_ctrl["buttons"] = BTN_STEAL
	await runner.wait_physics_frames(1)
	def_ctrl["buttons"] = 0
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "STARTUP", "Steal tick 1 enters STARTUP")
	runner.assert_eq(int(def_sys.get("steal_phase_frames_left")), 6, "Steal STARTUP starts at 6 frames")

	# Ticks 2..6: remains STARTUP counting down 5..1
	var startup_ok := true
	for expected_rem in [5, 4, 3, 2, 1]:
		await runner.wait_physics_frames(1)
		if String(def_sys.call("get_steal_phase_name")) != "STARTUP" or int(def_sys.get("steal_phase_frames_left")) != expected_rem:
			startup_ok = false
			break
	runner.assert_true(startup_ok, "Steal STARTUP lasts exact 6 frames (6 -> 1)")

	# Tick 7: transitions to ACTIVE with 5 frames left; Ticks 8..11 count 4..1
	var active_ok := true
	for expected_rem in [5, 4, 3, 2, 1]:
		await runner.wait_physics_frames(1)
		if String(def_sys.call("get_steal_phase_name")) != "ACTIVE" or int(def_sys.get("steal_phase_frames_left")) != expected_rem:
			active_ok = false
			break
	runner.assert_true(active_ok, "Steal ACTIVE lasts exact 5 frames (5 -> 1)")

	# Tick 12: transitions to WHIFF_RECOVERY with 24 frames left!
	await runner.wait_physics_frames(1)
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "WHIFF_RECOVERY", "Missed active poke enters WHIFF_RECOVERY on tick 12")
	runner.assert_eq(int(def_sys.get("steal_phase_frames_left")), 24, "Steal WHIFF_RECOVERY lasts exact 24 frames")
	runner.assert_true(bool(def_sys.call("is_in_steal_whiff_recovery")), "is_in_steal_whiff_recovery() == true")
	runner.assert_true(bool(def_sys.call("is_in_recovery")), "is_in_recovery() == true during whiff recovery")
	runner.assert_eq(int(def_sys.call("get_recovery_frames_remaining")), 24, "get_recovery_frames_remaining() == 24")
	runner.assert_approx(float(def_sys.call("get_movement_speed_multiplier")), 0.45, 0.001, "Whiff recovery speed multiplier == 0.45x")

	# During WHIFF_RECOVERY: movement speed reduced ~0.45x, and stance/steal/jump are LOCKED
	def_ctrl["move_world_xz"] = Vector2(1.0, 0.0)
	def_ctrl["buttons"] = BTN_STANCE | BTN_JUMP | BTN_STEAL
	await runner.wait_physics_frames(10)
	var whiff_speed: float = Vector2(defender.velocity.x, defender.velocity.z).length()
	var base_run: float = float(defender.get("run_speed"))
	runner.assert_approx(whiff_speed, base_run * 0.45, 0.35, "Whiff recovery throttles live movement speed to 0.45x (actual=%.2f)" % whiff_speed)
	runner.assert_false(bool(defender.call("is_in_defensive_stance")), "Defensive stance LOCKED during steal whiff recovery")
	runner.assert_true(defender.is_on_floor(), "Jump/block LOCKED during steal whiff recovery")
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "WHIFF_RECOVERY", "Cannot re-trigger steal during whiff recovery")
	def_ctrl["move_world_xz"] = Vector2.ZERO
	def_ctrl["buttons"] = 0

	# Remaining 14 frames -> Tick 35 has 1 left, Tick 36 cleanly returns to IDLE
	await runner.wait_physics_frames(13)
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "WHIFF_RECOVERY", "Still in WHIFF_RECOVERY on final 24th recovery frame")
	runner.assert_eq(int(def_sys.get("steal_phase_frames_left")), 1, "Final whiff recovery frame has 1 frame left")
	await runner.wait_physics_frames(1)
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "IDLE", "Returns cleanly to IDLE after 24 recovery frames")
	runner.assert_false(bool(def_sys.call("is_in_recovery")), "is_in_recovery() == false after whiff recovery ends")
	runner.assert_approx(float(def_sys.call("get_movement_speed_multiplier")), 1.0, 0.001, "Movement speed multiplier restored to 1.0")

	# --- 2B. Poking into protected hip (behind_the_back shield) fails -> enters 24f WHIFF_RECOVERY ---
	steal_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.1)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	offense.call("perform_dribble_move", "behind_the_back", false)
	runner.assert_true(bool(offense.call("has_steal_protection")), "Behind-the-back activates steal protection shield")
	def_ctrl["buttons"] = BTN_STEAL
	await runner.wait_physics_frames(1)
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(11) # 6f startup + 5f active all blocked by 0.38s (23f) shield -> tick 12 WHIFF_RECOVERY!
	runner.assert_eq(ball.carrier, offense, "Poking into behind-the-back shield fails to strip ball")
	runner.assert_eq(steal_events.size(), 0, "No steal_performed emitted against shielded behind-the-back")
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "WHIFF_RECOVERY", "Shielded steal poke punishes defender with 24f WHIFF_RECOVERY")

	# --- 2C. Successful Active Steal on dribbling carrier (strict 6f startup -> strips on tick 7 ACTIVE, skips whiff, +22 Zone) ---
	steal_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.35)))
	ball.call("set_controlled_state", 2, offense, 1, 0, true) # BallState.DRIBBLING
	def_sys.set("force_strict_steal_startup", true)
	await runner.wait_physics_frames(2)
	var pre_steals: int = int(def_sys.get("steals_made"))
	var pre_zone: float = float(defender.zone.get("current_energy"))

	def_ctrl["buttons"] = BTN_STEAL
	await runner.wait_physics_frames(1)
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(5) # End of 6th startup tick -> still STARTUP, not stolen yet!
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "STARTUP", "Active steal does NOT strip during 6f STARTUP")
	runner.assert_eq(ball.carrier, offense, "Ball still held by offense during defender steal STARTUP")

	await runner.wait_physics_frames(1) # Tick 7 -> ACTIVE -> strips immediately!
	runner.assert_eq(ball.carrier, defender, "Active steal strips ball on ACTIVE frame #1 (tick 7)")
	runner.assert_eq(String(ball.call("get_state_name")), "HELD", "Stolen ball enters BallState.HELD")
	runner.assert_eq(int(def_sys.get("steals_made")), pre_steals + 1, "steals_made incremented by 1")
	runner.assert_eq(steal_events.size(), 1, "EventBus.steal_performed emitted once on strip")
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "IDLE", "Successful active steal resets to IDLE (skips whiff recovery)")
	runner.assert_false(bool(def_sys.call("is_in_recovery")), "Successful active steal incurs zero whiff recovery")
	runner.assert_approx(float(defender.zone.get("current_energy")) - pre_zone, 22.0, 0.25, "Successful steal awards +22.0 Zone energy")

	# --- 2D. Skillful Positioning & Low-Stamina Strip Reach Bonus (at 2.02m > 1.75m base steal_radius) ---
	# Case 1: Reaching from BEHIND offense at 2.02m (pos_score == 0.0, facing back -> penalized 0.55x) -> WHIFFS
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -1.98))) # 2.02m BEHIND offense (HoopB is at -12.425)
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)
	def_ctrl["buttons"] = BTN_STEAL
	await runner.wait_physics_frames(1)
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(11)
	runner.assert_eq(ball.carrier, offense, "Reaching blindly from behind at 2.02m whiffs")
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "WHIFF_RECOVERY", "Poor-position reach from behind enters WHIFF_RECOVERY")

	# Case 2: Optimal front-side positioning (pos_score ~ 1.0 -> +0.28m) + exhausted carrier (<25 stam -> +0.25m) at 2.02m -> STRIPS!
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.02))) # 2.02m IN FRONT on rim line!
	defender.set("facing_yaw", PI) # facing offense at +Z
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	offense.stamina.call("set_stamina", 15.0)
	await runner.wait_physics_frames(2)
	def_ctrl["buttons"] = BTN_STEAL
	await runner.wait_physics_frames(1)
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(7)
	runner.assert_eq(ball.carrier, defender, "Optimal front positioning + exhausted carrier boosts active steal reach at 2.02m")
	def_sys.set("force_strict_steal_startup", false)
	off_ctrl["buttons"] = 0


# ==============================================================================
# 3. Shot Contesting, Vertical Apex Blocking & 18f Block-Landing Recovery
# ==============================================================================
func _test_shot_contest_vertical_block_and_landing_recovery(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var defender := _spawn_extra_player(arena, "BlockDef", 2, 1, Vector3(0.0, 0.0, -5.5))
	if not runner.assert_not_null(offense, "Block: LocalPlayer present") or not runner.assert_not_null(defender, "Block: Defender spawned"):
		return
	await runner.wait_physics_frames(2)

	var _off_ctrl := _make_input_controller(offense)
	var def_ctrl := _make_input_controller(defender)
	var def_sys: Node = defender.defense_system
	var eb: Node = runner.get_event_bus()

	var block_events := [0]
	var state_at_block := [""]
	runner.connect_temp_signal(eb.block_performed, func(bid: int, _sid: int, _pos: Vector3) -> void:
		if bid == 2:
			block_events[0] += 1
			state_at_block[0] = String(ball.call("get_state_name"))
	)

	# --- 3A. Disciplined hands-up stance contest directly between shooter & rim (> 0.70 grounded!) ---
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.20))) # 1.20m tight closeout on rim line
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	def_ctrl["buttons"] = BTN_STANCE
	await runner.wait_physics_frames(2)
	var disciplined_contest: float = float(DefenseSystem.compute_shot_contest(offense, HOOP_B_RIM))
	runner.assert_true(defender.is_on_floor(), "Disciplined stance contest stays grounded (no bait jump)")
	runner.assert_gt(disciplined_contest, 0.70, "Disciplined hands-up stance yields strong contest > 0.70 (actual=%.3f)" % disciplined_contest)
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(1)

	# --- 3B. Baited/missed off-ball block jump -> 18f block-landing recovery & collapsed contest (< 0.20) ---
	def_ctrl["buttons"] = BTN_SHOOT # Off-ball BTN_SHOOT triggers vertical block jump
	await runner.wait_physics_frames(1)
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(3)
	runner.assert_false(defender.is_on_floor(), "Off-ball BTN_SHOOT launches defender into vertical block jump")

	# Wait for defender to land cleanly back on court floor
	var landed_frame := -1
	for i in range(60):
		await runner.wait_physics_frames(1)
		if defender.is_on_floor():
			landed_frame = i
			break
	runner.assert_gt(float(landed_frame), 0.0, "Baited block jumper lands back on floor cleanly")
	runner.assert_eq(int(def_sys.get("block_recovery_frames")), 18, "Landing after missed block jump incurs exact 18f block_recovery_frames")
	runner.assert_true(bool(def_sys.call("is_in_block_recovery")), "is_in_block_recovery() == true on landing")
	runner.assert_true(bool(def_sys.call("is_in_recovery")), "is_in_recovery() == true during block recovery")
	runner.assert_approx(float(def_sys.call("get_movement_speed_multiplier")), 0.55, 0.001, "Block recovery speed multiplier == 0.55x")

	# Shooter gets a wide-open look (< 0.20 contest) while baited defender is in 18f recovery!
	var baited_contest: float = float(DefenseSystem.compute_shot_contest(offense, HOOP_B_RIM))
	runner.assert_lt(baited_contest, 0.20, "Baited block-landing recovery collapses contest < 0.20 (actual=%.3f)" % baited_contest)

	# Jump and steal are locked during 18f block recovery
	def_ctrl["buttons"] = BTN_JUMP | BTN_STEAL
	await runner.wait_physics_frames(2)
	def_ctrl["buttons"] = 0
	runner.assert_true(defender.is_on_floor(), "Cannot immediately jump again during 18f block-landing recovery")
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "IDLE", "Cannot start steal during 18f block-landing recovery")

	# Wait remaining 16 frames -> recovery clears cleanly
	await runner.wait_physics_frames(16)
	runner.assert_eq(int(def_sys.get("block_recovery_frames")), 0, "block_recovery_frames decays cleanly to 0 after 18 ticks")
	runner.assert_false(bool(def_sys.call("is_in_block_recovery")), "is_in_block_recovery() == false after recovery")

	# --- 3C. Timed vertical apex swat blocks SHOT_FLIGHT -> FREE, awards +22 Zone & avoids baited penalty ---
	block_events[0] = 0
	state_at_block[0] = ""
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.5)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -7.8)))
	await runner.wait_physics_frames(2)
	var pre_blocks: int = int(def_sys.get("blocks_made"))
	var pre_zone: float = float(defender.zone.get("current_energy"))

	# Launch live SHOT_FLIGHT past defender and jump vertically to swat it
	ball.call(
		"launch_shot",
		offense, 1, 0,
		Vector3(0.0, 2.25, -6.9),
		offense.global_position,
		HOOP_B_RIM,
		Vector3(0.0, 4.4, -5.2),
		Vector3(-12.0, 0.0, 0.0),
		false
	)
	def_ctrl["buttons"] = BTN_JUMP
	await runner.wait_physics_frames(1)
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(14)

	runner.assert_eq(block_events[0], 1, "Timed vertical block jump emits EventBus.block_performed")
	runner.assert_eq(state_at_block[0], "FREE", "Vertical block deflects SHOT_FLIGHT -> FREE")
	runner.assert_eq(int(def_sys.get("blocks_made")), pre_blocks + 1, "blocks_made incremented by 1")
	runner.assert_gt(ball.linear_velocity.z, 1.0, "Swatted ball deflected away from HoopB (+Z)")
	runner.assert_approx(float(defender.zone.get("current_energy")) - pre_zone, 22.0, 0.25, "Successful block awards +22.0 Zone energy")

	# Wait for successful blocker to land -> should NOT incur 18f baited recovery penalty!
	for _i in range(50):
		await runner.wait_physics_frames(1)
		if defender.is_on_floor():
			break
	runner.assert_eq(int(def_sys.get("block_recovery_frames")), 0, "Successful block jump does NOT trigger 18f baited landing penalty")


# ==============================================================================
# 4. Pass Lane Interception (1.15m Stance vs 0.85m Moving, Possession & +22 Zone)
# ==============================================================================
func _test_pass_lane_interception(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var passer := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var teammate := _spawn_extra_player(arena, "PassReceiver", 3, 0, Vector3(4.0, 0.0, -2.0))
	var defender := _spawn_extra_player(arena, "LaneHawk", 2, 1, Vector3(0.0, 0.0, -3.0))
	if not runner.assert_not_null(passer, "Intercept: Passer present") or not runner.assert_not_null(teammate, "Intercept: Teammate spawned") or not runner.assert_not_null(defender, "Intercept: Defender spawned"):
		return
	await runner.wait_physics_frames(2)

	var pass_ctrl := _make_input_controller(passer)
	var _tm_ctrl := _make_input_controller(teammate)
	var def_ctrl := _make_input_controller(defender)
	var def_sys: Node = defender.defense_system
	var eb: Node = runner.get_event_bus()

	var poss_events: Array[Dictionary] = []
	var steal_events := [0]
	runner.connect_temp_signal(eb.possession_changed, func(tid: int, cid: int) -> void:
		poss_events.append({"team": tid, "carrier": cid})
	)
	runner.connect_temp_signal(eb.steal_performed, func(sid: int, _vid: int, _pos: Vector3) -> void:
		if sid == 2:
			steal_events[0] += 1
	)

	# --- 4A. Out-of-stance defender at 1.00m lateral offset (0.85m < 1.00m <= 1.15m) does NOT intercept ---
	passer.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-4.0, 0.0, -2.0)))
	teammate.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(4.0, 0.0, -2.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.0))) # exact 1.00m off pass line z=-2
	defender.set("facing_yaw", PI) # facing pass line (+Z)
	def_sys.call("reset_stats")
	ball.call("set_controlled_state", 1, passer, 1, 0, true)
	await runner.wait_physics_frames(2)

	pass_ctrl["aim_yaw"] = -PI * 0.5 # +X toward teammate
	pass_ctrl["buttons"] = BTN_PASS
	await runner.wait_physics_frames(1)
	pass_ctrl["buttons"] = 0
	await runner.wait_physics_frames(45)

	runner.assert_eq(ball.carrier, teammate, "Out-of-stance defender at 1.00m offset does NOT intercept pass; teammate catches it")
	runner.assert_eq(int(def_sys.get("interceptions_made")), 0, "interceptions_made stays 0 when out-of-stance at 1.00m")

	# --- 4B. In DEFENSIVE_STANCE at exact same 1.00m offset (<= 1.15m) cleanly intercepts! ---
	poss_events.clear()
	steal_events[0] = 0
	passer.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-4.0, 0.0, -2.0)))
	teammate.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(4.0, 0.0, -2.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.0))) # exact 1.00m offset
	ball.call("set_controlled_state", 1, passer, 1, 0, true)
	def_ctrl["buttons"] = BTN_STANCE
	await runner.wait_physics_frames(2)
	var pre_zone: float = float(defender.zone.get("current_energy"))

	pass_ctrl["aim_yaw"] = -PI * 0.5
	pass_ctrl["buttons"] = BTN_PASS
	await runner.wait_physics_frames(1)
	pass_ctrl["buttons"] = 0
	# Confirm ball tagged as opponent pass for team 1 right after launch
	runner.assert_true(bool(ball.call("is_opponent_pass_for_team", 1)), "PASS_FLIGHT reports is_opponent_pass_for_team(1) == true")
	runner.assert_false(bool(ball.call("is_opponent_pass_for_team", 0)), "PASS_FLIGHT reports is_opponent_pass_for_team(0) == false")
	await runner.wait_physics_frames(35)
	def_ctrl["buttons"] = 0

	runner.assert_eq(ball.carrier, defender, "Defender in DEFENSIVE_STANCE intercepts opponent pass at 1.00m (<= 1.15m)")
	runner.assert_eq(String(ball.call("get_state_name")), "HELD", "Intercepted pass transitions directly to BallState.HELD")
	runner.assert_eq(int(def_sys.get("interceptions_made")), 1, "interceptions_made increments to 1")
	runner.assert_eq(GameState.possession_team, 1, "Interception transfers GameState.possession_team to defender team (1)")
	runner.assert_true(poss_events.size() >= 1 and int(poss_events[poss_events.size() - 1]["team"]) == 1, "EventBus.possession_changed fires for defender team")
	runner.assert_eq(steal_events[0], 1, "Interception emits EventBus.steal_performed")
	runner.assert_approx(float(defender.zone.get("current_energy")) - pre_zone, 22.0, 0.25, "Pass interception awards +22.0 Zone energy")

	# --- 4C. Non-stance defender inside 0.85m moving lane (0.40m offset) facing pass intercepts cleanly ---
	passer.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-4.0, 0.0, -2.0)))
	teammate.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(4.0, 0.0, -2.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -2.40))) # 0.40m <= 0.85m
	defender.set("facing_yaw", PI)
	ball.call("set_controlled_state", 1, passer, 1, 0, true)
	await runner.wait_physics_frames(2)

	pass_ctrl["aim_yaw"] = -PI * 0.5
	pass_ctrl["buttons"] = BTN_PASS
	await runner.wait_physics_frames(1)
	pass_ctrl["buttons"] = 0
	await runner.wait_physics_frames(35)
	runner.assert_eq(ball.carrier, defender, "Out-of-stance facing defender inside 0.85m lane intercepts pass")
	runner.assert_eq(int(def_sys.get("interceptions_made")), 2, "interceptions_made increments to 2")

	# --- 4D. Defender in WHIFF_RECOVERY cannot intercept even directly in pass lane ---
	passer.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-4.0, 0.0, -2.0)))
	teammate.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(4.0, 0.0, -2.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -2.40)))
	defender.set("facing_yaw", PI)
	def_sys.set("steal_phase", DefenseSystem.StealPhase.WHIFF_RECOVERY)
	def_sys.set("steal_phase_frames_left", 24)
	ball.call("set_controlled_state", 1, passer, 1, 0, true)
	await runner.wait_physics_frames(2)

	pass_ctrl["aim_yaw"] = -PI * 0.5
	pass_ctrl["buttons"] = BTN_PASS
	await runner.wait_physics_frames(1)
	pass_ctrl["buttons"] = 0
	await runner.wait_physics_frames(45)
	runner.assert_eq(int(def_sys.get("interceptions_made")), 2, "Defender in WHIFF_RECOVERY cannot intercept pass")


# ==============================================================================
# 5. Positioning Alignment [0..1], Momentum & Balance, and 66f Ankle-Break
# ==============================================================================
func _test_positioning_momentum_balance_and_ankle_break(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var defender := _spawn_extra_player(arena, "AnkleDef", 2, 1, Vector3(0.0, 0.0, -5.8))
	if not runner.assert_not_null(offense, "Momentum: LocalPlayer present") or not runner.assert_not_null(defender, "Momentum: Defender spawned"):
		return
	await runner.wait_physics_frames(2)

	var _off_ctrl := _make_input_controller(offense)
	var def_ctrl := _make_input_controller(defender)
	var eb: Node = runner.get_event_bus()

	var ankle_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.ankle_broken, func(vid: int, aid: int, pos: Vector3) -> void:
		ankle_events.append({"victim": vid, "attacker": aid, "pos": pos})
	)

	# --- 5A. Defensive Positioning Alignment Score [0.0..1.0] ---
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)

	# Optimal: centered on rim line (-4 -> -12.425) at 1.80m cushion (inside 1.3..2.3m), facing ball-handler
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.80)))
	defender.set("facing_yaw", PI)
	var pos_optimal: float = float(DefenseSystem.compute_defensive_positioning(defender, offense, HOOP_B_RIM))
	var pos_via_player: float = float(defender.call("compute_defensive_positioning_score", offense))
	runner.assert_ge(pos_optimal, 0.90, "Optimal 1.8m rim-line cushion positioning score >= 0.90 (actual=%.3f)" % pos_optimal)
	runner.assert_approx(pos_via_player, pos_optimal, 0.01, "Player.compute_defensive_positioning_score() matches DefenseSystem")

	# Off-axis laterally (2.0m off lane) -> degraded score
	defender.global_position = Vector3(2.0, 0.0, -5.80)
	var pos_off_axis: float = float(DefenseSystem.compute_defensive_positioning(defender, offense, HOOP_B_RIM))
	runner.assert_lt(pos_off_axis, 0.55, "Laterally off-axis defender positioning score drops < 0.55 (actual=%.3f)" % pos_off_axis)

	# Beat behind ball-handler (further from HoopB than offense) -> exact 0.0
	defender.global_position = Vector3(0.0, 0.0, -2.0)
	var pos_beat: float = float(DefenseSystem.compute_defensive_positioning(defender, offense, HOOP_B_RIM))
	runner.assert_approx(pos_beat, 0.0, 0.001, "Defender beat behind ball-handler scores 0.0 positioning")

	# --- 5B. Directional Momentum Vector buildup on sprint & decay on stop ---
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-3.0, 0.0, -5.8)))
	def_ctrl["move_world_xz"] = Vector2(1.0, 0.0)
	def_ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(22)
	var mom_sprint: Vector2 = defender.call("get_momentum_vector")
	runner.assert_gt(mom_sprint.x, 5.0, "Sprinting right builds strong +X momentum_vec > 5.0 (actual=%.2f)" % mom_sprint.x)

	def_ctrl["move_world_xz"] = Vector2.ZERO
	def_ctrl["buttons"] = 0
	await runner.wait_physics_frames(30)
	var mom_decayed: Vector2 = defender.call("get_momentum_vector")
	runner.assert_lt(mom_decayed.length(), 1.5, "Stopping decays momentum_vec toward 0 (actual=%.2f)" % mom_decayed.length())

	# --- 5C. Over-committed sprinting defender vs normal CROSSOVER -> ANKLE_BROKEN (66f lock + recovery!) ---
	ankle_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	offense.set("facing_yaw", 0.0) # facing HoopB (-Z); right hand -> crossover cuts LEFT (-X, -Z)!
	offense.dribble_system.call("set_dribble_hand", 1) # RIGHT hand -> crossover swaps to LEFT (-X cut!)
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-2.6, 0.0, -5.6)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Sprint defender hard RIGHT (+X) across the front of offense so momentum_vec.x > 5.5 opposes LEFT crossover!
	def_ctrl["move_world_xz"] = Vector2(1.0, 0.0)
	def_ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(22)
	var pre_cross_mom: Vector2 = defender.call("get_momentum_vector")
	var pre_cross_dist: float = Vector2(defender.global_position.x - offense.global_position.x, defender.global_position.z - offense.global_position.z).length()
	var pre_atk_zone: float = float(offense.zone.get("current_energy"))
	runner.assert_gt(pre_cross_mom.x, 4.5, "Sanity: defender built strong +X sprint momentum (%.2f)" % pre_cross_mom.x)
	runner.assert_lt(pre_cross_dist, 3.0, "Sanity: over-committed defender is inside 3.2m crossover radius (%.2fm)" % pre_cross_dist)

	# Execute a NORMAL crossover (not even Ankle Breaker combo!)
	var cross_ok: bool = bool(offense.call("perform_dribble_move", "crossover", false))
	var cut_dir: Vector3 = offense.dribble_system.call("get_last_cut_direction")
	runner.assert_true(cross_ok, "Normal crossover executes cleanly")
	runner.assert_lt(cut_dir.x, -0.4, "Right-to-left crossover cuts strongly toward -X (cut_dir.x=%.2f)" % cut_dir.x)
	runner.assert_true(bool(defender.call("is_ankle_broken")), "Normal crossover BREAKS ankles of over-committed sprinting defender!")
	runner.assert_approx(float(defender.get("balance")), 0.0, 0.01, "Ankle-broken defender balance drops to 0.0")
	runner.assert_eq(int(defender.call("get_ankle_break_frames_remaining")), 66, "Ankle-break stun sets exact 66-frame (1.10s) recovery window")
	runner.assert_eq(defender.call("get_animation_state"), &"ankle_stumble", "Ankle-broken defender enters 'ankle_stumble' AnimationTree state")
	runner.assert_gt(defender.velocity.x, 1.5, "Ankle-broken defender knocked laterally opposite cut (+X, vel.x=%.2f)" % defender.velocity.x)
	runner.assert_eq(ankle_events.size(), 1, "EventBus.ankle_broken emitted once")
	runner.assert_approx(float(offense.zone.get("current_energy")) - pre_atk_zone, 26.0, 0.25, "Crossover (+6.0) + ankle break (+20.0) credits attacker +26.0 Zone energy")

	# During 66-frame stun: defender actions (stance, steal, jump) are locked and contest == 0.0
	def_ctrl["buttons"] = BTN_STANCE | BTN_JUMP | BTN_STEAL
	await runner.wait_physics_frames(20)
	runner.assert_true(bool(defender.call("is_ankle_broken")), "Defender remains ankle-broken 20 frames into 66f stun")
	runner.assert_eq(int(defender.call("get_ankle_break_frames_remaining")), 46, "Ankle-break timer decrements frame-accurately (66 - 20 = 46)")
	runner.assert_false(bool(defender.call("is_in_defensive_stance")), "Stance locked during ankle-break stun")
	runner.assert_true(defender.is_on_floor(), "Jump locked during ankle-break stun")
	runner.assert_eq(String(defender.defense_system.call("get_steal_phase_name")), "IDLE", "Steal locked during ankle-break stun")
	runner.assert_approx(float(DefenseSystem.compute_shot_contest(offense, HOOP_B_RIM)), 0.0, 0.001, "Ankle-broken defender yields 0.0 shot contest")
	def_ctrl["buttons"] = 0
	def_ctrl["move_world_xz"] = Vector2.ZERO

	# Wait remaining 46 ticks -> clean restoration to 100.0 balance & full control!
	await runner.wait_physics_frames(46)
	runner.assert_false(bool(defender.call("is_ankle_broken")), "Ankle-break cleanly expires at exact 66th frame")
	runner.assert_approx(float(defender.get("balance")), 100.0, 0.01, "Balance restores cleanly to 100.0 on ankle-break recovery")

	# --- 5D. Well-positioned defender in DEFENSIVE_STANCE absorbs exact same crossover (> 50 balance!) ---
	ankle_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	offense.set("facing_yaw", 0.0)
	offense.dribble_system.call("set_dribble_hand", 1) # RIGHT hand -> LEFT crossover
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-0.35, 0.0, -5.75)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Shuffle right IN DEFENSIVE STANCE (builds stance momentum > 3.6 while centered on rim line!)
	def_ctrl["move_world_xz"] = Vector2(1.0, 0.0)
	def_ctrl["buttons"] = BTN_STANCE
	await runner.wait_physics_frames(12)
	var stance_mom: Vector2 = defender.call("get_momentum_vector")
	runner.assert_true(bool(defender.call("is_in_defensive_stance")), "Sanity: disciplined defender holds DEFENSIVE_STANCE")
	runner.assert_gt(stance_mom.x, 3.6, "Sanity: shuffling stance defender has opposing momentum > 3.5 (%.2f)" % stance_mom.x)

	offense.call("perform_dribble_move", "crossover", false)
	def_ctrl["move_world_xz"] = Vector2.ZERO
	def_ctrl["buttons"] = 0
	var stance_bal_left: float = float(defender.get("balance"))
	runner.assert_false(bool(defender.call("is_ankle_broken")), "Disciplined DEFENSIVE_STANCE defender absorbs crossover without ankle break!")
	runner.assert_gt(stance_bal_left, 50.0, "Disciplined DEFENSIVE_STANCE defender retains > 50 balance (actual=%.1f)" % stance_bal_left)
	runner.assert_eq(ankle_events.size(), 0, "No EventBus.ankle_broken emitted against disciplined stance defender")


# ==============================================================================
# 6. Deterministic Rollback Snapshot Roundtrip for All Phase 6 Defense Fields
# ==============================================================================
func _test_phase6_snapshot_roundtrip(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var defender := _spawn_extra_player(arena, "SnapDef", 2, 1, Vector3(1.5, 0.0, -6.2))
	if not runner.assert_not_null(defender, "Snap: Defender spawned"):
		return
	await runner.wait_physics_frames(2)

	var def_sys: Node = defender.defense_system

	# Snapshot A: stance, momentum_vec, partial balance, WHIFF_RECOVERY, block_recovery_frames, interceptions_made
	defender.set("_in_defensive_stance", true)
	def_sys.call("set_in_stance", true)
	defender.set("momentum_vec", Vector2(4.75, -2.25))
	defender.set("balance", 62.5)
	def_sys.set("steal_phase", DefenseSystem.StealPhase.WHIFF_RECOVERY)
	def_sys.set("steal_phase_frames_left", 17)
	def_sys.set("block_recovery_frames", 11)
	def_sys.set("interceptions_made", 3)

	var snap_a: Dictionary = defender.call("export_sim_state")
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	def_sys.call("reset_stats")
	runner.assert_eq(int(def_sys.get("interceptions_made")), 0, "Sanity: reset_stats clears interceptions_made")

	defender.call("import_sim_state", snap_a)
	var rest_mom: Vector2 = defender.call("get_momentum_vector")
	runner.assert_true(bool(defender.call("is_in_defensive_stance")), "Snapshot restores in_defensive_stance == true")
	runner.assert_approx(rest_mom.x, 4.75, 0.001, "Snapshot restores momentum_vec.x")
	runner.assert_approx(rest_mom.y, -2.25, 0.001, "Snapshot restores momentum_vec.y")
	runner.assert_approx(float(defender.get("balance")), 62.5, 0.001, "Snapshot restores partial balance == 62.5")
	runner.assert_eq(String(def_sys.call("get_steal_phase_name")), "WHIFF_RECOVERY", "Snapshot restores steal_phase == WHIFF_RECOVERY")
	runner.assert_eq(int(def_sys.get("steal_phase_frames_left")), 17, "Snapshot restores steal_phase_frames_left == 17")
	runner.assert_eq(int(def_sys.get("block_recovery_frames")), 11, "Snapshot restores block_recovery_frames == 11")
	runner.assert_eq(int(def_sys.get("interceptions_made")), 3, "Snapshot restores interceptions_made == 3")

	# Snapshot B: active ankle_break_frames_left == 42
	defender.set("ankle_break_frames_left", 42)
	defender.set("_ankle_broken_stun", 42.0 / 60.0)
	defender.set("balance", 0.0)
	var snap_b: Dictionary = defender.call("export_sim_state")
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	runner.assert_false(bool(defender.call("is_ankle_broken")), "Sanity: reset_for_match clears ankle_break_frames_left")

	defender.call("import_sim_state", snap_b)
	runner.assert_true(bool(defender.call("is_ankle_broken")), "Snapshot restores active ankle-broken state")
	runner.assert_eq(int(defender.call("get_ankle_break_frames_remaining")), 42, "Snapshot restores exact ankle_break_frames_left == 42")
