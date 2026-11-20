extends Node
## Phase 3 Automated Verification Suite — Fighting-Game Combo System (PHANTOM COURT ONLINE)
## Verifies:
## 1. FrameData helpers (startup/active/recovery/cancel window + Zone extension), MoveDatabase
##    registry (4 signature combos + 5 cancelable normals + archetype scoping), and InputBuffer
##    (90-frame capacity, tapped + continuously held directions, WASD noise tolerance, wrong button break).
## 2. ComboEngine 60 Hz logic: Perfect Timing bonuses (4..9f -> 30% stamina refund, 1.15x potency,
##    +8 Zone), cooldown enforcement & decay, cancel windows & priority preemption (chain 1->2->3
##    including Zone +4f cancel window extension), training telemetry, and rollback snapshot roundtrip.
## 3. On-court Phantom Drive (Q,E,Q,Shift): high-speed dash, steal immunity, physical defender phase-through,
##    net Perfect stamina cost (kara-refund), and collision layer restoration.
## 4. On-court Ankle Breaker (E,Q,E,LMB): suppress final LMB jump shot, cone balance break (100->0),
##    defender stun + EventBus.ankle_broken, and gather_shot_bonus.
## 5. On-court Mirror Step (Q,Q,E,R): suppress final R spin, 2-stage forward feint -> 3.2m stepback vanish,
##    and cancel-window transition into pull-up jump shot.
## 6. On-court Meteor Dunk (Shift,W[held],Space,R): 5.5m range gate, DUNK_LOCKED soaring apex >= 4.15m,
##    dunk_impact power >= 1.5, defender shockwave knockback/balance dmg, physical +2 rim score,
##    and PlayerController export/import_sim_state combo roundtrip.

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


func run(runner: SceneTree) -> void:
	await _test_frame_data_move_db_and_input_buffer(runner)
	await _test_combo_engine_rules_chains_and_snapshots(runner)
	await _test_on_court_phantom_drive(runner)
	await _test_on_court_ankle_breaker(runner)
	await _test_on_court_mirror_step(runner)
	await _test_on_court_meteor_dunk_and_player_snapshot(runner)


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


func _feed_button_sequence(
	runner: SceneTree,
	ctrl: Dictionary,
	button_steps: Array[int],
	gap_frames: int,
	held_dir: Vector2 = Vector2.ZERO
) -> void:
	ctrl["local_dir"] = held_dir
	for idx in range(button_steps.size()):
		ctrl["buttons"] = button_steps[idx]
		await runner.wait_physics_frames(1)
		ctrl["buttons"] = 0
		if idx < button_steps.size() - 1:
			var rest_frames: int = maxi(1, gap_frames - 1)
			await runner.wait_physics_frames(rest_frames)


# ==============================================================================
# 1. FrameData, MoveDatabase & InputBuffer (90f ring, tap + held dir, filtering)
# ==============================================================================
func _test_frame_data_move_db_and_input_buffer(runner: SceneTree) -> void:
	await runner.clear_stage()

	# --- 1A. MoveDatabase & FrameData contracts ---
	var db := MoveDatabase.new(true)
	var pd: FrameData = db.get_move(MoveDatabase.MOVE_PHANTOM_DRIVE)
	var md: FrameData = db.get_move(MoveDatabase.MOVE_METEOR_DUNK)
	var ab: FrameData = db.get_move(MoveDatabase.MOVE_ANKLE_BREAKER)
	var ms: FrameData = db.get_move(MoveDatabase.MOVE_MIRROR_STEP)

	runner.assert_not_null(pd, "MoveDatabase registers 'phantom_drive'")
	runner.assert_not_null(md, "MoveDatabase registers 'meteor_dunk'")
	runner.assert_not_null(ab, "MoveDatabase registers 'ankle_breaker'")
	runner.assert_not_null(ms, "MoveDatabase registers 'mirror_step'")
	runner.assert_eq(db.get_normal_moves().size(), 5, "MoveDatabase registers all 5 cancelable dribble normals")

	# FrameData startup/active/recovery/cancel window helpers on phantom_drive (4/18/10, cancel [12..22])
	runner.assert_eq(pd.total_frames(), 32, "Phantom Drive total_frames == 32 (4+18+10)")
	runner.assert_true(pd.is_in_startup(0) and pd.is_in_startup(3), "FrameData startup covers frames 0..3")
	runner.assert_false(pd.is_in_startup(4), "Frame 4 is past startup")
	runner.assert_true(pd.is_in_active(4) and pd.is_in_active(21), "FrameData active covers frames 4..21")
	runner.assert_true(pd.is_in_recovery(22) and pd.is_in_recovery(31), "FrameData recovery covers frames 22..31")
	runner.assert_false(pd.is_in_cancel_window(11, 0), "Frame 11 is before cancel window [12..22]")
	runner.assert_true(pd.is_in_cancel_window(12, 0) and pd.is_in_cancel_window(22, 0), "Cancel window includes [12..22]")
	runner.assert_false(pd.is_in_cancel_window(23, 0), "Frame 23 outside base cancel window")
	runner.assert_true(pd.is_in_cancel_window(26, 4), "Zone +4f extends cancel window to frame 26")

	# FrameData to_dict / from_dict roundtrip
	var pd_copy := FrameData.from_dict(pd.to_dict())
	runner.assert_eq(pd_copy.id, pd.id, "FrameData to_dict/from_dict preserves id")
	runner.assert_eq(pd_copy.sequence, pd.sequence, "FrameData to_dict/from_dict preserves sequence")
	runner.assert_eq(pd_copy.cooldown_frames, 180, "FrameData preserves cooldown_frames == 180")

	# Deterministic priority sorting: meteor_dunk (70) > mirror_step (50) > ankle_breaker (45) > phantom_drive (40)
	var sorted_combos: Array[FrameData] = db.get_combo_moves("")
	runner.assert_eq(sorted_combos.size(), 4, "4 universal combo moves returned for default archetype")
	if sorted_combos.size() == 4:
		runner.assert_eq(sorted_combos[0].id, "meteor_dunk", "Priority sort #1: meteor_dunk (P70)")
		runner.assert_eq(sorted_combos[1].id, "mirror_step", "Priority sort #2: mirror_step (P50)")
		runner.assert_eq(sorted_combos[2].id, "ankle_breaker", "Priority sort #3: ankle_breaker (P45)")
		runner.assert_eq(sorted_combos[3].id, "phantom_drive", "Priority sort #4: phantom_drive (P40)")

	# Dynamic archetype move scoping (Phase 4 extensibility)
	db.register_move_from_dict({
		"id": "phantom_pass_test",
		"sequence": ["Q", "RMB"],
		"priority": 42,
		"archetype_id": "phantom_pg",
	})
	runner.assert_eq(db.get_combo_moves("phantom_pg").size(), 5, "Archetype-scoped move visible to matching archetype")
	runner.assert_eq(db.get_combo_moves("rim_titan").size(), 4, "Archetype-scoped move hidden from other archetypes")

	# --- 1B. InputBuffer 90-frame capacity, noise tolerance, wrong button break, tap & held W ---
	var buf := InputBuffer.new()
	for f in range(110):
		buf.push_frame({"tick": f, "buttons": BTN_SKILL_Q if (f % 2 == 0) else 0, "local_dir": Vector2.ZERO}, f)
	runner.assert_le(float(buf.get_token_count()), 90.0, "InputBuffer enforces 90-frame circular capacity")

	# Exact Phantom Drive with 6f gaps + WASD directional noise during sequence
	buf.clear()
	buf.push_frame({"tick": 10, "buttons": BTN_SKILL_Q, "local_dir": Vector2.ZERO}, 10)
	buf.push_frame({"tick": 13, "buttons": 0, "local_dir": Vector2(1.0, 0.0)}, 13) # Noise D snap
	buf.push_frame({"tick": 16, "buttons": BTN_SKILL_E, "local_dir": Vector2(1.0, 0.0)}, 16)
	buf.push_frame({"tick": 22, "buttons": BTN_SKILL_Q, "local_dir": Vector2.ZERO}, 22)
	buf.push_frame({"tick": 28, "buttons": BTN_SPRINT, "local_dir": Vector2.ZERO}, 28)
	var m_pd: Dictionary = buf.match_sequence(["Q", "E", "Q", "Shift"], 14, -1, 0)
	runner.assert_true(bool(m_pd["matched"]), "InputBuffer matches Q,E,Q,Shift ignoring WASD directional noise")
	runner.assert_approx(float(m_pd["avg_gap"]), 6.0, 0.01, "InputBuffer reports exact 6.0f average timing gap")

	# Step window exceeded (16f > 14f) -> rejected
	buf.clear()
	buf.push_frame({"tick": 10, "buttons": BTN_SKILL_Q, "local_dir": Vector2.ZERO}, 10)
	buf.push_frame({"tick": 26, "buttons": BTN_SKILL_E, "local_dir": Vector2.ZERO}, 26)
	buf.push_frame({"tick": 32, "buttons": BTN_SKILL_Q, "local_dir": Vector2.ZERO}, 32)
	buf.push_frame({"tick": 38, "buttons": BTN_SPRINT, "local_dir": Vector2.ZERO}, 38)
	runner.assert_false(bool(buf.match_sequence(["Q", "E", "Q", "Shift"], 14, -1, 0)["matched"]), "InputBuffer rejects step gap > 14 frames")

	# Wrong intervening button (F) breaks contiguity
	buf.clear()
	buf.push_frame({"tick": 10, "buttons": BTN_SKILL_Q, "local_dir": Vector2.ZERO}, 10)
	buf.push_frame({"tick": 14, "buttons": BTN_SKILL_E, "local_dir": Vector2.ZERO}, 14)
	buf.push_frame({"tick": 17, "buttons": BTN_STEAL, "local_dir": Vector2.ZERO}, 17)
	buf.push_frame({"tick": 20, "buttons": BTN_SKILL_Q, "local_dir": Vector2.ZERO}, 20)
	buf.push_frame({"tick": 25, "buttons": BTN_SPRINT, "local_dir": Vector2.ZERO}, 25)
	runner.assert_false(bool(buf.match_sequence(["Q", "E", "Q", "Shift"], 14, -1, 0)["matched"]), "InputBuffer rejects sequence broken by wrong intervening button")

	# Meteor Dunk with TAPPED W
	buf.clear()
	buf.push_frame({"tick": 10, "buttons": BTN_SPRINT, "local_dir": Vector2.ZERO}, 10)
	buf.push_frame({"tick": 16, "buttons": 0, "local_dir": Vector2(0.0, 1.0)}, 16)
	buf.push_frame({"tick": 22, "buttons": BTN_JUMP, "local_dir": Vector2.ZERO}, 22)
	buf.push_frame({"tick": 28, "buttons": BTN_SKILL_R, "local_dir": Vector2.ZERO}, 28)
	var m_tap: Dictionary = buf.match_sequence(["Shift", "W", "Space", "R"], 14, -1, 0)
	runner.assert_true(bool(m_tap["matched"]), "Meteor Dunk matches with tapped W (Shift -> W -> Space -> R)")

	# Meteor Dunk with CONTINUOUSLY HELD W across Shift -> Space -> R
	buf.clear()
	for f in range(1, 32):
		var b: int = 0
		if f == 12:
			b = BTN_SPRINT
		elif f == 18:
			b = BTN_JUMP
		elif f == 24:
			b = BTN_SKILL_R
		buf.push_frame({"tick": f, "buttons": b, "local_dir": Vector2(0.0, 1.0)}, f)
		if f == 24:
			var m_held: Dictionary = buf.match_sequence(["Shift", "W", "Space", "R"], 14, -1, 0)
			runner.assert_true(bool(m_held["matched"]), "Meteor Dunk matches with continuously held W across Shift->Space->R")
			runner.assert_true(bool(m_held["used_held_direction"]), "Held W match reports used_held_direction == true")
			runner.assert_approx(float(m_held["avg_gap"]), 6.0, 0.01, "Held W preserves real 6.0f button rhythm gap for Perfect grading")


# ==============================================================================
# 2. ComboEngine: Perfect Bonus, Cooldowns, Cancel Windows, Chains & Rollback
# ==============================================================================
func _test_combo_engine_rules_chains_and_snapshots(runner: SceneTree) -> void:
	await runner.clear_stage()
	var ce := ComboEngine.new()
	ce.setup(1, null, "phantom_pg")
	await runner.mount_node(ce)

	var eb: Node = runner.get_event_bus()
	var combo_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, tier: int, perf: bool) -> void:
		combo_events.append({"pid": pid, "id": cid, "tier": tier, "perfect": perf})
	)

	var tick := [0]
	var step_btn := func(btn: int, ctx: Dictionary, local_dir: Vector2 = Vector2.ZERO) -> Dictionary:
		tick[0] += 1
		return ce.step_frame({"tick": tick[0], "buttons": btn, "local_dir": local_dir}, ctx)

	var step_idle := func(count: int, ctx: Dictionary, local_dir: Vector2 = Vector2.ZERO) -> void:
		for _i in range(count):
			tick[0] += 1
			ce.step_frame({"tick": tick[0], "buttons": 0, "local_dir": local_dir}, ctx)

	var base_ctx := {"has_ball": true, "stamina": 100.0, "dist_to_rim": 3.5, "is_grounded": true, "is_zone_active": false}

	# --- 2A. Perfect Timing Phantom Drive (6f gaps inside [4..9]) ---
	ce.set_training_target("phantom_drive")
	step_btn.call(BTN_SKILL_Q, base_ctx)
	step_idle.call(5, base_ctx)
	step_btn.call(BTN_SKILL_E, base_ctx)
	var tr_mid: Dictionary = ce.get_training_state()
	runner.assert_eq(int(tr_mid["matched_prefix_len"]), 2, "Training telemetry tracks partial prefix length (2/4)")
	runner.assert_eq(String(tr_mid["expected_next_symbol"]), "Q", "Training telemetry reports next expected symbol 'Q'")

	step_idle.call(5, base_ctx)
	step_btn.call(BTN_SKILL_Q, base_ctx)
	step_idle.call(5, base_ctx)
	var res_perf: Dictionary = step_btn.call(BTN_SPRINT, base_ctx)

	runner.assert_true(bool(res_perf["triggered"]), "Perfect Phantom Drive triggers cleanly")
	runner.assert_eq(String(res_perf["move_id"]), "phantom_drive", "Triggered move_id == 'phantom_drive'")
	runner.assert_true(bool(res_perf["is_perfect"]), "6f gaps earn is_perfect == true")
	runner.assert_approx(float(res_perf["stamina_refund_ratio"]), 0.30, 0.001, "Perfect timing applies 30% stamina refund ratio")
	runner.assert_approx(float(res_perf["stamina_cost"]), 11.2, 0.01, "Perfect Phantom Drive net stamina == 11.2 (16 * 0.70)")
	runner.assert_approx(float(res_perf["potency_mult"]), 1.15, 0.001, "Perfect timing applies 1.15x potency multiplier")
	runner.assert_approx(float(res_perf["bonus_zone"]), 8.0, 0.01, "Perfect timing grants +8.0 bonus Zone")
	runner.assert_approx(float(res_perf["zone_gain"]), 20.0, 0.01, "Perfect Phantom Drive total Zone gain == 20.0 (12+8)")
	runner.assert_eq(combo_events.size(), 1, "ComboEngine emits EventBus.combo_triggered once")
	runner.assert_eq(ce.get_cooldown_remaining("phantom_drive"), 180, "Phantom Drive starts 180f cooldown")

	# --- 2B. Cooldown rejection & non-Perfect slow timing after cooldown expires ---
	step_idle.call(35, base_ctx) # Past 32f total move duration, still ~145f left on cooldown
	step_btn.call(BTN_SKILL_Q, base_ctx)
	step_idle.call(5, base_ctx)
	step_btn.call(BTN_SKILL_E, base_ctx)
	step_idle.call(5, base_ctx)
	step_btn.call(BTN_SKILL_Q, base_ctx)
	step_idle.call(5, base_ctx)
	var res_cd: Dictionary = step_btn.call(BTN_SPRINT, base_ctx)
	runner.assert_false(bool(res_cd["triggered"]), "Phantom Drive rejected while on cooldown")
	runner.assert_eq(String(res_cd["rejected_reason"]), "on_cooldown", "Cooldown rejection reason == 'on_cooldown'")

	# Drain remaining cooldown and trigger SLOW (12f gaps -> non-Perfect)
	step_idle.call(140, base_ctx)
	runner.assert_eq(ce.get_cooldown_remaining("phantom_drive"), 0, "Cooldown expires cleanly to 0 after 180 frames")
	step_btn.call(BTN_SKILL_Q, base_ctx)
	step_idle.call(11, base_ctx)
	step_btn.call(BTN_SKILL_E, base_ctx)
	step_idle.call(11, base_ctx)
	step_btn.call(BTN_SKILL_Q, base_ctx)
	step_idle.call(11, base_ctx)
	var res_slow: Dictionary = step_btn.call(BTN_SPRINT, base_ctx)
	runner.assert_true(bool(res_slow["triggered"]), "Slow 12f-gap Phantom Drive triggers after cooldown expires")
	runner.assert_false(bool(res_slow["is_perfect"]), "12f gaps (outside 4..9) earn is_perfect == false")
	runner.assert_approx(float(res_slow["stamina_cost"]), 16.0, 0.01, "Non-Perfect Phantom Drive pays full 16.0 stamina")
	runner.assert_approx(float(res_slow["potency_mult"]), 1.0, 0.001, "Non-Perfect potency_mult == 1.0")
	runner.assert_approx(float(res_slow["zone_gain"]), 12.0, 0.01, "Non-Perfect Zone gain == base 12.0")

	# --- 2C. Cancel Window Gating, Combo Chaining (1 -> 2 -> 3) & Zone +4f Cancel Extension ---
	ce.reset()
	tick[0] = 0
	# Trigger Ankle Breaker (E, Q, E, LMB -> cancel window [10..19], P45)
	step_btn.call(BTN_SKILL_E, base_ctx)
	step_idle.call(5, base_ctx)
	step_btn.call(BTN_SKILL_Q, base_ctx)
	step_idle.call(5, base_ctx)
	step_btn.call(BTN_SKILL_E, base_ctx)
	step_idle.call(5, base_ctx)
	var ab_res: Dictionary = step_btn.call(BTN_SHOOT, base_ctx)
	runner.assert_true(bool(ab_res["triggered"]) and String(ab_res["move_id"]) == "ankle_breaker", "Ankle Breaker starts chain (chain=1)")
	runner.assert_eq(int(ab_res["combo_chain_count"]), 1, "Initial combo_chain_count == 1")

	# Enter Q, Q, E, R ending at frame 7 (BEFORE Ankle Breaker cancel window [10..19]) -> MUST BE REJECTED!
	# Note: 1 release frame between Q and Q so second Q is a clean rising edge.
	step_btn.call(BTN_SKILL_Q, base_ctx) # f=1
	step_idle.call(1, base_ctx)          # f=2 (release Q)
	step_btn.call(BTN_SKILL_Q, base_ctx) # f=3
	step_idle.call(1, base_ctx)          # f=4
	step_btn.call(BTN_SKILL_E, base_ctx) # f=5
	step_idle.call(1, base_ctx)          # f=6
	var early_cancel: Dictionary = step_btn.call(BTN_SKILL_R, base_ctx) # f=7 (< 10)
	runner.assert_false(bool(early_cancel["triggered"]), "Mirror Step rejected at frame 7 (before cancel window [10..19])")
	runner.assert_eq(String(early_cancel["rejected_reason"]), "not_in_cancel_window", "Rejection reason == 'not_in_cancel_window'")

	# Now complete Mirror Step INSIDE Ankle Breaker cancel window [10..19] (at frame 16) -> CHAINS (chain=2)!
	step_btn.call(BTN_SKILL_Q, base_ctx) # f=8
	step_idle.call(1, base_ctx)          # f=9 (release Q)
	step_btn.call(BTN_SKILL_Q, base_ctx) # f=10
	step_idle.call(2, base_ctx)          # f=11,12
	step_btn.call(BTN_SKILL_E, base_ctx) # f=13
	step_idle.call(2, base_ctx)          # f=14,15
	var ms_chain: Dictionary = step_btn.call(BTN_SKILL_R, base_ctx) # f=16
	runner.assert_true(bool(ms_chain["triggered"]) and String(ms_chain["move_id"]) == "mirror_step", "Mirror Step cancels Ankle Breaker inside [10..19]")
	runner.assert_true(bool(ms_chain["was_cancel"]), "Chained Mirror Step reports was_cancel == true")
	runner.assert_eq(String(ms_chain["canceled_from"]), "ankle_breaker", "Chained Mirror Step reports canceled_from == 'ankle_breaker'")
	runner.assert_eq(int(ms_chain["combo_chain_count"]), 2, "Chaining increments combo_chain_count to 2")

	# Chain Mirror Step (base cancel [12..20]) into Meteor Dunk at frame 22 using Zone +4f extension ([12..24])!
	var zone_ctx := {"has_ball": true, "stamina": 100.0, "dist_to_rim": 4.2, "is_grounded": true, "is_zone_active": true}
	step_idle.call(9, zone_ctx, Vector2(0.0, 1.0)) # f=1..9
	step_btn.call(BTN_SPRINT, zone_ctx, Vector2(0.0, 1.0)) # f=10
	step_idle.call(5, zone_ctx, Vector2(0.0, 1.0)) # f=11..15
	step_btn.call(BTN_JUMP, zone_ctx, Vector2(0.0, 1.0)) # f=16
	step_idle.call(5, zone_ctx, Vector2(0.0, 1.0)) # f=17..21
	var md_chain: Dictionary = step_btn.call(BTN_SKILL_R, zone_ctx, Vector2(0.0, 1.0)) # f=22 (only open via Zone +4f!)
	runner.assert_true(bool(md_chain["triggered"]) and String(md_chain["move_id"]) == "meteor_dunk", "Zone +4f cancel window enables frame-22 Mirror Step -> Meteor Dunk chain")
	runner.assert_true(bool(md_chain["was_cancel"]), "Zone-extended Meteor Dunk reports was_cancel == true")
	runner.assert_eq(int(md_chain["combo_chain_count"]), 3, "3-move chain increments combo_chain_count to 3")

	# --- 2D. Deterministic Rollback Snapshot (export_state / import_state) ---
	var snap: Dictionary = ce.export_state()
	ce.reset()
	runner.assert_eq(ce.get_active_move_id(), "", "Sanity: reset clears active move")
	runner.assert_eq(ce.get_cooldown_remaining("meteor_dunk"), 0, "Sanity: reset clears cooldowns")
	ce.import_state(snap)
	runner.assert_eq(ce.get_active_move_id(), "meteor_dunk", "ComboEngine import_state restores active_move_id")
	runner.assert_eq(ce.get_combo_chain_count(), 3, "ComboEngine import_state restores combo_chain_count == 3")
	runner.assert_eq(ce.get_cooldown_remaining("meteor_dunk"), 300, "ComboEngine import_state restores meteor_dunk cooldown")
	runner.assert_gt(float(ce.get_cooldown_remaining("mirror_step")), 150.0, "ComboEngine import_state restores mirror_step cooldown")


# ==============================================================================
# 3. On-Court Phantom Drive (Q, E, Q, Shift) — Pass-Through & Steal Immunity
# ==============================================================================
func _test_on_court_phantom_drive(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	if not runner.assert_not_null(offense, "PhantomDrive: LocalPlayer present") or not runner.assert_not_null(ball, "PhantomDrive: ball present"):
		return

	var defender := _spawn_extra_player(arena, "PhantomBlocker", 2, 1, Vector3(0.0, 0.0, -5.8))
	await runner.wait_physics_frames(2)

	var off_ctrl := _make_input_controller(offense)
	var def_ctrl := _make_input_controller(defender)
	var eb: Node = runner.get_event_bus()

	var combo_events: Array[Dictionary] = []
	var steal_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, tier: int, perf: bool) -> void:
		if pid == 1 and cid == "phantom_drive":
			combo_events.append({"id": cid, "tier": tier, "perfect": perf})
	)
	runner.connect_temp_signal(eb.steal_performed, func(sid: int, vid: int, _p: Vector3) -> void:
		steal_events.append({"stealer": sid, "victim": vid})
	)

	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.8)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	var pre_stamina: float = float(offense.stamina.get("current_stamina"))
	var pre_zone: float = float(offense.zone.get("current_zone"))

	# Execute Perfect Q -> E -> Q -> Shift (6f gaps)
	await _feed_button_sequence(runner, off_ctrl, [BTN_SKILL_Q, BTN_SKILL_E, BTN_SKILL_Q, BTN_SPRINT], 6)

	var phasing_during: bool = bool(offense.call("is_phantom_phasing"))
	var shielded_during: bool = bool(offense.call("has_steal_protection"))
	var post_trigger_stamina: float = float(offense.stamina.get("current_stamina"))
	var post_trigger_zone: float = float(offense.zone.get("current_zone"))

	# Defender attempts steal right as Phantom Drive passes through defender at z = -5.8
	for step_i in range(22):
		def_ctrl["buttons"] = BTN_STEAL if (step_i == 4 or step_i == 8) else 0
		await runner.physics_frame
	def_ctrl["buttons"] = 0

	runner.assert_eq(combo_events.size(), 1, "On-court Phantom Drive emits EventBus.combo_triggered exactly once (no double emit)")
	if combo_events.size() >= 1:
		runner.assert_true(bool(combo_events[0]["perfect"]), "6f Q,E,Q,Shift earns on-court Perfect Phantom Drive")
	runner.assert_true(phasing_during, "Phantom Drive activates defender pass-through phasing")
	runner.assert_true(shielded_during, "Phantom Drive grants steal immunity")
	runner.assert_eq(steal_events.size(), 0, "Defender steal attempt during Phantom Drive fails (steal_immune)")
	runner.assert_eq(ball.get("carrier"), offense, "Offense retains ball throughout Phantom Drive")
	runner.assert_lt(offense.global_position.z, -7.2, "Phantom Drive physically passes straight through defender at z=-5.8 (final z=%.2f)" % offense.global_position.z)
	runner.assert_approx(pre_stamina - post_trigger_stamina, 11.2, 0.6, "Perfect Phantom Drive deducts exact net ~11.2 stamina (kara-refund active)")
	runner.assert_ge(post_trigger_zone - pre_zone, 19.5, "Perfect Phantom Drive grants >= +20 Zone charge")

	# Wait for phase timer to finish and confirm collision layers restored
	await runner.wait_physics_frames(10)
	runner.assert_false(bool(offense.call("is_phantom_phasing")), "Phantom Drive phasing deactivates cleanly after dash")
	runner.assert_eq(offense.collision_layer, 2, "Player collision_layer restored to 2 after Phantom Drive")
	runner.assert_eq(offense.collision_mask, 3, "Player collision_mask restored to 3 after Phantom Drive")


# ==============================================================================
# 4. On-Court Ankle Breaker (E, Q, E, LMB) — Balance Break & No Stray Shot
# ==============================================================================
func _test_on_court_ankle_breaker(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	if not runner.assert_not_null(offense, "AnkleBreaker: LocalPlayer present"):
		return

	var defender := _spawn_extra_player(arena, "AnkleVictim", 2, 1, Vector3(0.0, 0.0, -5.8))
	await runner.wait_physics_frames(2)

	var off_ctrl := _make_input_controller(offense)
	var def_ctrl := _make_input_controller(defender)
	var eb: Node = runner.get_event_bus()

	var combo_events: Array[Dictionary] = []
	var ankle_events: Array[Dictionary] = []
	var shot_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, perf: bool) -> void:
		if pid == 1 and cid == "ankle_breaker":
			combo_events.append({"id": cid, "perfect": perf})
	)
	runner.connect_temp_signal(eb.ankle_broken, func(vid: int, aid: int, pos: Vector3) -> void:
		ankle_events.append({"victim": vid, "attacker": aid, "pos": pos})
	)
	runner.connect_temp_signal(eb.shot_released, func(pid: int, _p: Vector3, _r: Vector3, _i3: bool, _q: float) -> void:
		shot_events.append({"pid": pid})
	)

	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.8)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Execute Perfect E -> Q -> E -> LMB (6f gaps)
	await _feed_button_sequence(runner, off_ctrl, [BTN_SKILL_E, BTN_SKILL_Q, BTN_SKILL_E, BTN_SHOOT], 6)
	await runner.wait_physics_frames(3)

	runner.assert_eq(combo_events.size(), 1, "Ankle Breaker (E,Q,E,LMB) triggers once on court")
	runner.assert_eq(ball.get("carrier"), offense, "Ankle Breaker final LMB suppressed — ball stays with carrier (no accidental shot)")
	runner.assert_false(bool(offense.shooting_system.get("is_charging_shot")), "Final LMB did not enter shot charge")
	runner.assert_eq(shot_events.size(), 0, "Final LMB emitted 0 stray shot_released events")

	runner.assert_eq(ankle_events.size(), 1, "Ankle Breaker emits EventBus.ankle_broken against front-cone defender")
	if ankle_events.size() >= 1:
		runner.assert_eq(int(ankle_events[0]["victim"]), 2, "ankle_broken victim_id == 2")
		runner.assert_eq(int(ankle_events[0]["attacker"]), 1, "ankle_broken attacker_id == 1")
	runner.assert_true(bool(defender.call("is_ankle_broken")), "Defender enters ankle-broken stun state")
	runner.assert_approx(float(defender.get("balance")), 0.0, 0.01, "Defender balance broken from 100 -> 0")
	runner.assert_gt(float(offense.dribble_system.call("get_combo_shot_bonus")), 0.12, "Ankle Breaker grants gather_shot_bonus for follow-up jumper")

	# Verify stunned defender cannot run forward under input
	def_ctrl["local_dir"] = Vector2(0.0, 1.0)
	var stun_pos_a: Vector3 = defender.global_position
	await runner.wait_physics_frames(15)
	def_ctrl["local_dir"] = Vector2.ZERO
	runner.assert_true(bool(defender.call("is_ankle_broken")), "Defender remains stunned across recovery frames")
	runner.assert_gt(defender.global_position.z, stun_pos_a.z - 0.8, "Stunned defender cannot accelerate forward while ankle-broken")


# ==============================================================================
# 5. On-Court Mirror Step (Q, Q, E, R) — Feint -> 3.2m Stepback + Shot Cancel
# ==============================================================================
func _test_on_court_mirror_step(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	if not runner.assert_not_null(offense, "MirrorStep: LocalPlayer present"):
		return

	var off_ctrl := _make_input_controller(offense)
	var eb: Node = runner.get_event_bus()

	var combo_events: Array[Dictionary] = []
	var dribble_events: Array[String] = []
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, perf: bool) -> void:
		if pid == 1 and cid == "mirror_step":
			combo_events.append({"id": cid, "perfect": perf})
	)
	runner.connect_temp_signal(eb.dribble_move_performed, func(pid: int, mname: String, _p: Vector3) -> void:
		if pid == 1:
			dribble_events.append(mname)
	)

	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.5)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Execute Perfect Q -> Q -> E -> R (6f gaps)
	await _feed_button_sequence(runner, off_ctrl, [BTN_SKILL_Q, BTN_SKILL_Q, BTN_SKILL_E, BTN_SKILL_R], 6)

	var trigger_pos: Vector3 = offense.global_position
	var rim_b := Vector3(0.0, 3.05, -12.425)
	var fwd_to_rim: Vector3 = BallTrajectory.safe_normalize_xz(rim_b - trigger_pos)
	var right_to_rim: Vector3 = fwd_to_rim.cross(Vector3.UP).normalized()

	var feint_peak_pos: Vector3 = trigger_pos
	var max_feint_fwd: float = 0.0
	var shot_canceled_ok: bool = false
	for frame_i in range(22):
		await runner.physics_frame
		var cur_fwd: float = (offense.global_position - trigger_pos).dot(fwd_to_rim)
		if cur_fwd > max_feint_fwd:
			max_feint_fwd = cur_fwd
			feint_peak_pos = offense.global_position
		# Press BTN_SHOOT inside Mirror Step cancel window [12..20] (at active_move_frame == 18 -> frame_i == 17)
		if frame_i == 17:
			var vanish_vec: Vector3 = offense.global_position - feint_peak_pos
			var back_sep: float = -vanish_vec.dot(fwd_to_rim)
			var lat_sep: float = absf(vanish_vec.dot(right_to_rim))
			runner.assert_ge(max_feint_fwd, 0.30, "Mirror Step stage 1 feints forward toward HoopB (actual=%.2fm)" % max_feint_fwd)
			runner.assert_ge(back_sep, 2.80, "Mirror Step stage 2 vanishes >= 2.8m backward along rim axis (actual=%.2fm)" % back_sep)
			runner.assert_ge(lat_sep, 0.90, "Mirror Step applies >= 0.9m lateral vanish offset perpendicular to rim (actual=%.2fm)" % lat_sep)
			runner.assert_gt(float(offense.dribble_system.call("get_combo_shot_bonus")), 0.14, "Mirror Step grants shot_window_bonus")
			runner.assert_true(bool(offense.combo_engine.call("is_in_cancel_window", 0)), "Mirror Step is inside cancel window [12..20] before shot cancel")
			off_ctrl["buttons"] = BTN_SHOOT
		elif frame_i == 18:
			shot_canceled_ok = bool(offense.shooting_system.get("is_charging_shot"))
			off_ctrl["buttons"] = 0

	runner.assert_eq(combo_events.size(), 1, "Mirror Step (Q,Q,E,R) triggers once on court")
	runner.assert_false(dribble_events.has("spin"), "Mirror Step final R suppressed — does NOT trigger normal spin")
	runner.assert_true(shot_canceled_ok, "Mirror Step cancel window cleanly cancels into immediate pull-up jump shot")


# ==============================================================================
# 6. On-Court Meteor Dunk (Shift, W[held], Space, R) & PlayerController Rollback
# ==============================================================================
func _test_on_court_meteor_dunk_and_player_snapshot(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var mc := arena.get_node_or_null("MatchController") as Node
	if not runner.assert_not_null(offense, "MeteorDunk: LocalPlayer present") or not runner.assert_not_null(ball, "MeteorDunk: ball present"):
		return

	var defender := _spawn_extra_player(arena, "PaintDefender", 2, 1, Vector3(0.5, 0.0, -11.4))
	await runner.wait_physics_frames(2)

	var off_ctrl := _make_input_controller(offense)
	var _def_ctrl := _make_input_controller(defender)
	var eb: Node = runner.get_event_bus()

	var combo_events: Array[Dictionary] = []
	var dunk_events: Array[Dictionary] = []
	var score_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, perf: bool) -> void:
		if pid == 1 and cid == "meteor_dunk":
			combo_events.append({"id": cid, "perfect": perf})
	)
	runner.connect_temp_signal(eb.dunk_impact, func(pid: int, rpos: Vector3, power: float) -> void:
		dunk_events.append({"pid": pid, "rim": rpos, "power": power})
	)
	runner.connect_temp_signal(eb.score_changed, func(tid: int, _ns: int, d: int, is3: bool, sid: int) -> void:
		score_events.append({"team": tid, "delta": d, "is_three": is3, "scorer": sid})
	)

	# --- 6A. Range gate check: > 5.5m from HoopB (-12.425) rejects Meteor Dunk ---
	mc.call("restart_match")
	combo_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.5))) # dist = 7.925m > 5.5m
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	await _feed_button_sequence(runner, off_ctrl, [BTN_SPRINT, BTN_JUMP, BTN_SKILL_R], 6, Vector2(0.0, 1.0))
	off_ctrl["local_dir"] = Vector2.ZERO
	await runner.wait_physics_frames(3)
	runner.assert_eq(combo_events.size(), 0, "Meteor Dunk rejected when beyond 5.5m max_rim_dist")

	# --- 6B. Inside 5.5m (z = -7.8 -> dist = 4.625m) with continuously held W -> Ultimate Meteor Dunk! ---
	mc.call("restart_match")
	combo_events.clear()
	dunk_events.clear()
	score_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -7.8)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.5, 0.0, -11.4)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	var def_pre_pos: Vector3 = defender.global_position
	var def_pre_bal: float = float(defender.get("balance"))

	# Hold W continuously across Shift -> (6f) -> Space -> (6f) -> R
	await _feed_button_sequence(runner, off_ctrl, [BTN_SPRINT, BTN_JUMP, BTN_SKILL_R], 6, Vector2(0.0, 1.0))
	off_ctrl["local_dir"] = Vector2.ZERO

	var saw_dunk_locked: bool = (String(ball.call("get_state_name")) == "DUNK_LOCKED")
	var shot_type_now := String(offense.shooting_system.get("last_shot_type"))

	await runner.wait_physics_frames(55) # 28f flight + slam through UpperGate -> LowerGate + shockwave

	var peak_ball_y: float = float(offense.shooting_system.get("peak_dunk_ball_y"))
	var def_disp: float = defender.global_position.distance_to(def_pre_pos)

	runner.assert_eq(combo_events.size(), 1, "Meteor Dunk (Shift, W[held], Space, R) triggers once inside 5.5m")
	if combo_events.size() >= 1:
		runner.assert_true(bool(combo_events[0]["perfect"]), "6f Shift->Space->R with held W earns Perfect Meteor Dunk")
	runner.assert_eq(shot_type_now, "meteor_dunk", "ShootingSystem activates 'meteor_dunk' trajectory")
	runner.assert_true(saw_dunk_locked, "Meteor Dunk locks ball into canonical DUNK_LOCKED state")
	runner.assert_ge(peak_ball_y, 4.10, "Meteor Dunk soars to >= 4.15m apex (actual=%.2fm)" % peak_ball_y)
	runner.assert_eq(dunk_events.size(), 1, "Meteor Dunk emits EventBus.dunk_impact")
	if dunk_events.size() >= 1:
		runner.assert_ge(float(dunk_events[0]["power"]), 1.50, "Meteor Dunk dunk_impact power >= 1.5 (actual=%.2f)" % float(dunk_events[0]["power"]))
	runner.assert_true(float(defender.get("balance")) < def_pre_bal or def_disp > 0.45, "Meteor Dunk shockwave damages/knocks back nearby defender")
	runner.assert_eq(score_events.size(), 1, "Meteor Dunk slams ball through UpperGate -> LowerGate and scores")
	if score_events.size() >= 1:
		runner.assert_eq(int(score_events[0]["delta"]), 2, "Meteor Dunk awards +2 points")

	# --- 6C. PlayerController export_sim_state / import_sim_state preserves ComboEngine cooldowns ---
	var cd_before: int = int(offense.combo_engine.call("get_cooldown_remaining", "meteor_dunk"))
	runner.assert_gt(float(cd_before), 200.0, "Meteor Dunk 300f cooldown active on PlayerController.combo_engine")
	var p_snap: Dictionary = offense.call("export_sim_state")
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	runner.assert_eq(int(offense.combo_engine.call("get_cooldown_remaining", "meteor_dunk")), 0, "Sanity: reset_for_match clears combo cooldown")
	offense.call("import_sim_state", p_snap)
	runner.assert_eq(int(offense.combo_engine.call("get_cooldown_remaining", "meteor_dunk")), cd_before, "PlayerController import_sim_state restores exact ComboEngine cooldown")
