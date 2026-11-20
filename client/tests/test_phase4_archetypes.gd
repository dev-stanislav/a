extends Node
## Phase 4 Automated Verification Suite — Character Archetypes (PHANTOM COURT ONLINE)
## Verifies:
## 1. ArchetypeData & ArchetypeRegistry: all 5 original characters (speedster, sharpshooter,
##    playmaker, powerhouse, all_rounder), complete metadata/colors/rig_scale/anim_variation/18 stats/
##    ratings, to_dict/from_dict roundtrip, and class-scoped MoveDatabase registration.
## 2. On-court archetype differentiation: Speedster vs Powerhouse speed/stamina/dribble_stamina_mult/
##    balance_resistance/rig_scale/block_radius, Sharpshooter 3pt range/timing window/arc/release height,
##    Playmaker pass_speed_mult/cancel_window_bonus/ankle_break_mult/zone_gain_mult, visual tinting,
##    and cross-class unique skill rejection.
## 3. Speedster unique skill: volt_dash (Q, Shift, Q) — 15+ m/s zig-zag burst, steal immunity, defender phase-through.
## 4. Sharpshooter unique skill: starlight_high_arc (E, S, LMB) — step-fade 5.8m rainbow 3pt swish from 9.5m deep.
## 5. Playmaker unique skill: mirage_thread (Q, E, RMB) — 1.35x laser pass (+12 Zone & shot bonus to teammate)
##    AND solo self-toss burst dash fallback when no teammate is present.
## 6. Powerhouse unique skill: tectonic_slam (Shift, Space, LMB) — 4.2m range armored poster dunk
##    (immune to stun/balance dmg), 4.2m shockwave (135+ balance dmg), dunk_impact >= 1.65, and +2 score.
## 7. All-Rounder unique skill: eclipse_counter (C, Q, E, Shift) — works BOTH on-ball (counter-drive + shield +
##    shot bonus) AND off-ball on defense (instant closeout burst + boosted steal radius & contest bonus).

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
	await _test_archetype_registry_and_move_scoping(runner)
	await _test_archetype_stat_visual_and_class_isolation(runner)
	await _test_speedster_volt_dash(runner)
	await _test_sharpshooter_starlight_high_arc(runner)
	await _test_playmaker_mirage_thread_pass_and_solo(runner)
	await _test_powerhouse_tectonic_slam(runner)
	await _test_all_rounder_eclipse_counter_both_modes(runner)


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


func _feed_input_steps(runner: SceneTree, ctrl: Dictionary, steps: Array[Dictionary], gap_frames: int) -> void:
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
# 1. ArchetypeRegistry, ArchetypeData & Class-Scoped MoveDatabase
# ==============================================================================
func _test_archetype_registry_and_move_scoping(runner: SceneTree) -> void:
	await runner.clear_stage()

	var all_ids: Array[String] = ArchetypeRegistry.get_all_ids()
	runner.assert_eq(all_ids.size(), 5, "ArchetypeRegistry registers exactly 5 archetypes")
	for expected_id in ["speedster", "sharpshooter", "playmaker", "powerhouse", "all_rounder"]:
		runner.assert_true(ArchetypeRegistry.has_archetype(expected_id), "Registry contains '%s'" % expected_id)

	var expected_skills := {
		"speedster": "volt_dash",
		"sharpshooter": "starlight_high_arc",
		"playmaker": "mirage_thread",
		"powerhouse": "tectonic_slam",
		"all_rounder": "eclipse_counter",
	}

	var db := MoveDatabase.new(true)
	runner.assert_eq(db.get_combo_moves("").size(), 4, "Default empty archetype sees only the 4 universal signature combos")

	for arch_id in all_ids:
		var arch: ArchetypeData = ArchetypeRegistry.get_archetype(arch_id)
		runner.assert_not_null(arch, "ArchetypeData loaded for '%s'" % arch_id)
		runner.assert_false(arch.character_name.is_empty(), "%s has character_name" % arch_id)
		runner.assert_ge(float(arch.strengths.size()), 2.0, "%s defines >= 2 strengths" % arch_id)
		runner.assert_ge(float(arch.weaknesses.size()), 2.0, "%s defines >= 2 weaknesses" % arch_id)
		runner.assert_eq(arch.unique_skill_id, expected_skills[arch_id], "%s unique_skill_id == '%s'" % [arch_id, expected_skills[arch_id]])

		# Roundtrip to_dict / from_dict
		var d: Dictionary = arch.to_dict()
		var copy := ArchetypeData.from_dict(d)
		runner.assert_eq(copy.id, arch.id, "%s ArchetypeData to_dict/from_dict preserves id" % arch_id)
		runner.assert_eq(copy.unique_skill_id, arch.unique_skill_id, "%s to_dict/from_dict preserves unique_skill_id" % arch_id)
		runner.assert_approx(copy.rig_scale.distance_to(arch.rig_scale), 0.0, 0.001, "%s preserves rig_scale" % arch_id)

		# Verify MoveDatabase scopes unique skill strictly to matching archetype
		var class_moves: Array[FrameData] = db.get_combo_moves(arch_id)
		runner.assert_eq(class_moves.size(), 5, "%s sees 4 universal + 1 own unique skill (5 total)" % arch_id)
		var move_ids: Array[String] = []
		for m in class_moves:
			move_ids.append(m.id)
		runner.assert_true(move_ids.has(expected_skills[arch_id]), "%s has access to '%s'" % [arch_id, expected_skills[arch_id]])
		for other_arch in expected_skills.keys():
			if other_arch != arch_id:
				runner.assert_false(move_ids.has(expected_skills[other_arch]), "%s cannot access %s's skill '%s'" % [arch_id, other_arch, expected_skills[other_arch]])


# ==============================================================================
# 2. On-Court Stat Differentiation, Visual Tinting, Rig Scale & Class Isolation
# ==============================================================================
func _test_archetype_stat_visual_and_class_isolation(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var p1 := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	if not runner.assert_not_null(p1, "Archetypes: LocalPlayer present"):
		return

	var p2 := _spawn_extra_player(arena, "ComparePlayer", 2, 1, Vector3(4.0, 0.0, 2.0))
	await runner.wait_physics_frames(2)

	var ctrl1 := _make_input_controller(p1)
	var ctrl2 := _make_input_controller(p2)

	# Apply Speedster to p1 & Powerhouse to p2
	runner.assert_true(bool(p1.call("apply_archetype_by_id", "speedster")), "apply_archetype_by_id('speedster') succeeds")
	runner.assert_true(bool(p2.call("apply_archetype_by_id", "powerhouse")), "apply_archetype_by_id('powerhouse') succeeds")

	# Verify visual palette, rig scaling & animation variations
	runner.assert_approx(p1.animator.jersey_color.r, Color("#00F0FF").r, 0.02, "Speedster jersey primary color is Cyan #00F0FF")
	runner.assert_approx(p1.animator.jersey_color.b, Color("#00F0FF").b, 0.02, "Speedster jersey blue channel matches #00F0FF")
	runner.assert_approx(float(p1.dribble_system.get("dribble_speed_scale")), 1.20, 0.01, "Speedster dribble_speed_scale == 1.20")

	runner.assert_approx(p2.animator.scale.x, 1.14, 0.01, "Powerhouse animator rig_scale.x == 1.14")
	runner.assert_approx(p2.animator.scale.y, 1.08, 0.01, "Powerhouse animator rig_scale.y == 1.08")
	runner.assert_approx(p2.scale.distance_to(Vector3.ONE), 0.0, 0.001, "Powerhouse CharacterBody3D root stays (1,1,1)")
	runner.assert_approx(float(p2.stamina.get("max_stamina")), 115.0, 0.1, "Powerhouse max_stamina == 115.0")
	runner.assert_approx(float(p1.stamina.get("max_stamina")), 85.0, 0.1, "Speedster max_stamina == 85.0")
	runner.assert_gt(float(p2.defense_system.get("block_radius")), float(p1.defense_system.get("block_radius")) + 0.6, "Powerhouse block_radius (2.15) > Speedster (1.40)")
	runner.assert_gt(float(p2.shooting_system.get("dunk_range_xz")), float(p1.shooting_system.get("dunk_range_xz")) + 1.0, "Powerhouse dunk_radius (4.20) > Speedster (2.75)")

	# Measure live sprint speed: Speedster (9.8 m/s) > Powerhouse (8.3 m/s)
	p1.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.0, 4.0)))
	p2.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(2.0, 0.0, 4.0)))
	ball.call("reset_to_free", Vector3(6.5, 0.5, 11.0))
	ctrl1["local_dir"] = Vector2(0.0, 1.0)
	ctrl1["buttons"] = BTN_SPRINT
	ctrl2["local_dir"] = Vector2(0.0, 1.0)
	ctrl2["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(24)
	var spd_speedster: float = Vector2(p1.velocity.x, p1.velocity.z).length()
	var spd_powerhouse: float = Vector2(p2.velocity.x, p2.velocity.z).length()
	ctrl1["local_dir"] = Vector2.ZERO
	ctrl1["buttons"] = 0
	ctrl2["local_dir"] = Vector2.ZERO
	ctrl2["buttons"] = 0
	runner.assert_approx(spd_speedster, 9.8, 0.35, "Speedster live sprint speed == 9.8 m/s")
	runner.assert_approx(spd_powerhouse, 8.3, 0.35, "Powerhouse live sprint speed == 8.3 m/s")
	runner.assert_gt(spd_speedster, spd_powerhouse + 1.1, "Speedster sprints noticeably faster than Powerhouse")

	# Dribble stamina efficiency: Speedster (0.80x -> 7.2) vs Powerhouse (1.30x -> 11.7)
	p1.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(-2.0, 0.0, 0.0)))
	p2.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(2.0, 0.0, 0.0)))
	await runner.wait_physics_frames(2)
	var s1_before: float = float(p1.stamina.get("current_stamina"))
	var s2_before: float = float(p2.stamina.get("current_stamina"))
	p1.call("perform_dribble_move", "crossover", false)
	p2.call("perform_dribble_move", "crossover", false)
	var s1_cost: float = s1_before - float(p1.stamina.get("current_stamina"))
	var s2_cost: float = s2_before - float(p2.stamina.get("current_stamina"))
	runner.assert_approx(s1_cost, 7.2, 0.25, "Speedster crossover costs 7.2 stamina (0.80x)")
	runner.assert_approx(s2_cost, 11.7, 0.25, "Powerhouse crossover costs 11.7 stamina (1.30x)")

	# Balance resistance: 100 damage breaks Speedster (0.80x -> 125 dmg) but Powerhouse (2.0x -> 50 dmg) shrugs it off!
	p1.call("apply_balance_damage", 100.0, 2)
	p2.call("apply_balance_damage", 100.0, 1)
	runner.assert_true(bool(p1.call("is_ankle_broken")), "Speedster (0.80x balance_resistance) breaks ankles on 100 balance dmg")
	runner.assert_false(bool(p2.call("is_ankle_broken")), "Powerhouse (2.0x balance_resistance) resists 100 balance dmg without stunning")
	runner.assert_approx(float(p2.get("balance")), 50.0, 0.5, "Powerhouse retains 50 balance after 100 dmg (100/2.0)")

	# Cross-class unique skill isolation: Powerhouse cannot execute Speedster's volt_dash
	runner.assert_false(bool(p2.call("execute_combo_move", {"id": "volt_dash"}, false)), "Powerhouse blocked from executing Speedster's volt_dash")

	# Verify Sharpshooter & Playmaker stat application
	p1.call("apply_archetype_by_id", "sharpshooter")
	runner.assert_approx(float(p1.shooting_system.get("three_point_range")), 9.8, 0.05, "Sharpshooter three_point_range == 9.8m")
	runner.assert_approx(float(p1.shooting_system.get("timing_window_scale")), 1.35, 0.02, "Sharpshooter timing_window_scale == 1.35 (+35%)")
	runner.assert_approx(float(p1.shooting_system.get("shot_release_height_offset")), 0.18, 0.01, "Sharpshooter shot_release_height_offset == +0.18m")

	p1.call("apply_archetype_by_id", "playmaker")
	runner.assert_approx(float(p1.shooting_system.get("pass_speed_mult")), 1.35, 0.02, "Playmaker pass_speed_mult == 1.35")
	runner.assert_eq(int(p1.combo_engine.call("get_extra_cancel_frames")), 4, "Playmaker cancel_window_bonus == +4f")
	runner.assert_approx(float(p1.get("ankle_break_mult")), 1.25, 0.02, "Playmaker ankle_break_mult == 1.25")
	runner.assert_approx(float(p1.zone.get("gain_rate_mult")), 1.25, 0.02, "Playmaker zone_gain_mult == 1.25")


# ==============================================================================
# 3. Speedster Unique Skill — Volt Dash (Q, Shift, Q)
# ==============================================================================
func _test_speedster_volt_dash(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var speedster := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var defender := _spawn_extra_player(arena, "VoltBlocker", 2, 1, Vector3(0.0, 0.0, -5.8))
	await runner.wait_physics_frames(2)

	speedster.call("apply_archetype_by_id", "speedster")
	var off_ctrl := _make_input_controller(speedster)
	var def_ctrl := _make_input_controller(defender)
	var eb: Node = runner.get_event_bus()

	var skill_hits := [0]
	var steals := [0]
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, _p: bool) -> void:
		if pid == 1 and cid == "volt_dash":
			skill_hits[0] += 1
	)
	runner.connect_temp_signal(eb.steal_performed, func(_s: int, _v: int, _pos: Vector3) -> void:
		steals[0] += 1
	)

	speedster.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.8)))
	ball.call("set_controlled_state", 1, speedster, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Feed Perfect Q -> Shift -> Q (6f gaps)
	await _feed_input_steps(runner, off_ctrl, [
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SPRINT},
		{"buttons": BTN_SKILL_Q},
	], 6)

	var phasing: bool = bool(speedster.call("is_phantom_phasing"))
	var shielded: bool = bool(speedster.call("has_steal_protection"))
	var peak_speed: float = 0.0
	for k in range(18):
		def_ctrl["buttons"] = BTN_STEAL if (k == 4 or k == 8) else 0
		await runner.physics_frame
		var spd: float = Vector2(speedster.velocity.x, speedster.velocity.z).length()
		if spd > peak_speed:
			peak_speed = spd
	def_ctrl["buttons"] = 0

	runner.assert_eq(skill_hits[0], 1, "Speedster Volt Dash (Q, Shift, Q) triggers once")
	runner.assert_true(phasing, "Volt Dash activates defender pass-through phasing")
	runner.assert_true(shielded, "Volt Dash grants steal immunity")
	runner.assert_gt(peak_speed, 14.5, "Volt Dash reaches blazing >= 15 m/s burst speed (peak=%.2f)" % peak_speed)
	runner.assert_eq(steals[0], 0, "Defender cannot strip ball during Volt Dash")
	runner.assert_lt(speedster.global_position.z, -7.2, "Volt Dash bursts past blocking defender at z=-5.8 (z=%.2f)" % speedster.global_position.z)


# ==============================================================================
# 4. Sharpshooter Unique Skill — Starlight High Arc (E, S, LMB) from 9.5m Deep
# ==============================================================================
func _test_sharpshooter_starlight_high_arc(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var sniper := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var mc := arena.get_node_or_null("MatchController") as Node
	await runner.wait_physics_frames(2)

	sniper.call("apply_archetype_by_id", "sharpshooter")
	var ctrl := _make_input_controller(sniper)
	var eb: Node = runner.get_event_bus()

	var skill_hits := [0]
	var score_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, _p: bool) -> void:
		if pid == 1 and cid == "starlight_high_arc":
			skill_hits[0] += 1
	)
	runner.connect_temp_signal(eb.score_changed, func(tid: int, _ns: int, d: int, is3: bool, _sid: int) -> void:
		score_events.append({"team": tid, "delta": d, "is_three": is3})
	)

	mc.call("restart_match")
	score_events.clear()
	# Deep 9.5m range from HoopB (z = -12.425 -> z = -2.925)
	sniper.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -2.925)))
	ball.call("set_controlled_state", 1, sniper, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Feed Perfect E -> S -> LMB (6f gaps)
	await _feed_input_steps(runner, ctrl, [
		{"buttons": BTN_SKILL_E},
		{"local_dir": Vector2(0.0, -1.0)},
		{"buttons": BTN_SHOOT},
	], 6)

	var shot_type_now := String(sniper.shooting_system.get("last_shot_type"))
	var max_ball_y: float = 0.0
	for _i in range(135):
		await runner.physics_frame
		if ball.global_position.y > max_ball_y:
			max_ball_y = ball.global_position.y

	runner.assert_eq(skill_hits[0], 1, "Sharpshooter Starlight High Arc (E, S, LMB) triggers once from 9.5m")
	runner.assert_eq(shot_type_now, "starlight_high_arc", "ShootingSystem records last_shot_type == 'starlight_high_arc'")
	runner.assert_ge(max_ball_y, 5.65, "Starlight High Arc reaches soaring ~5.8m rainbow apex (peak=%.2fm)" % max_ball_y)
	runner.assert_eq(score_events.size(), 1, "Deep 9.5m Starlight High Arc swishes through HoopB")
	if score_events.size() >= 1:
		runner.assert_eq(int(score_events[0]["delta"]), 3, "Starlight High Arc from 9.5m awards +3 points")
		runner.assert_true(bool(score_events[0]["is_three"]), "Starlight High Arc from 9.5m sets is_three == true")


# ==============================================================================
# 5. Playmaker Unique Skill — Mirage Thread (Q, E, RMB): Laser Pass & Solo Dash
# ==============================================================================
func _test_playmaker_mirage_thread_pass_and_solo(runner: SceneTree) -> void:
	# --- 5A. With open teammate: 1.35x laser pass + Zone & shot bonus buff ---
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var pm := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var teammate := _spawn_extra_player(arena, "MirageTarget", 3, 0, Vector3(5.0, 0.0, -4.0))
	await runner.wait_physics_frames(2)

	pm.call("apply_archetype_by_id", "playmaker")
	teammate.call("apply_archetype_by_id", "sharpshooter")
	var pm_ctrl := _make_input_controller(pm)
	var _tm_ctrl := _make_input_controller(teammate)
	var eb: Node = runner.get_event_bus()

	var skill_hits := [0]
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, _p: bool) -> void:
		if pid == 1 and cid == "mirage_thread":
			skill_hits[0] += 1
	)

	pm.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	teammate.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, -4.0)))
	ball.call("set_controlled_state", 1, pm, 1, 0, true)
	await runner.wait_physics_frames(2)

	var tm_zone_before: float = float(teammate.zone.get("current_zone"))
	await _feed_input_steps(runner, pm_ctrl, [
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SKILL_E},
		{"buttons": BTN_PASS},
	], 6)

	var pass_spd: float = float(pm.shooting_system.get("last_pass_speed"))
	var pass_state_after := String(ball.call("get_state_name"))
	await runner.wait_physics_frames(30)

	runner.assert_eq(skill_hits[0], 1, "Playmaker Mirage Thread (Q, E, RMB) triggers once with teammate")
	runner.assert_ge(pass_spd, 20.0, "Mirage Thread fires >= 1.35x laser pass speed (actual=%.2f m/s)" % pass_spd)
	runner.assert_true(pass_state_after == "PASS_FLIGHT" or ball.get("carrier") == teammate, "Mirage Thread launches PASS_FLIGHT toward teammate")
	runner.assert_eq(ball.get("carrier"), teammate, "Teammate catches Mirage Thread laser pass cleanly")
	runner.assert_ge(float(teammate.zone.get("current_zone")) - tm_zone_before, 11.5, "Mirage Thread grants teammate >= +12 Zone charge")
	runner.assert_gt(float(teammate.dribble_system.call("get_combo_shot_bonus")), 0.14, "Mirage Thread grants teammate follow-up shot bonus")

	# --- 5B. Solo court (no teammate): self-toss burst dash forward ---
	await runner.clear_stage()
	var solo_arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var solo_pm := solo_arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var solo_ball := solo_arena.get_node_or_null("Basketball") as RigidBody3D
	await runner.wait_physics_frames(2)

	solo_pm.call("apply_archetype_by_id", "playmaker")
	var solo_ctrl := _make_input_controller(solo_pm)
	var solo_hits := [0]
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, _p: bool) -> void:
		if pid == 1 and cid == "mirage_thread":
			solo_hits[0] += 1
	)

	solo_pm.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.0)))
	solo_ball.call("set_controlled_state", 1, solo_pm, 1, 0, true)
	await runner.wait_physics_frames(2)
	var pre_solo_z: float = solo_pm.global_position.z

	await _feed_input_steps(runner, solo_ctrl, [
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SKILL_E},
		{"buttons": BTN_PASS},
	], 6)
	var solo_shield: bool = bool(solo_pm.call("has_steal_protection"))
	await runner.wait_physics_frames(18)

	runner.assert_eq(solo_hits[0], 1, "Solo Mirage Thread triggers cleanly when no teammate is present")
	runner.assert_eq(solo_ball.get("carrier"), solo_pm, "Solo Mirage Thread retains ball (suppresses default pass)")
	runner.assert_true(solo_shield, "Solo Mirage Thread grants steal shield")
	runner.assert_lt(solo_pm.global_position.z - pre_solo_z, -2.0, "Solo Mirage Thread executes self-toss burst dash forward")


# ==============================================================================
# 6. Powerhouse Unique Skill — Tectonic Slam (Shift, Space, LMB)
# ==============================================================================
func _test_powerhouse_tectonic_slam(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var titan := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var mc := arena.get_node_or_null("MatchController") as Node
	var defender := _spawn_extra_player(arena, "RimGuard", 2, 1, Vector3(0.6, 0.0, -11.3))
	await runner.wait_physics_frames(2)

	titan.call("apply_archetype_by_id", "powerhouse")
	defender.call("apply_archetype_by_id", "speedster")
	var off_ctrl := _make_input_controller(titan)
	var _def_ctrl := _make_input_controller(defender)
	var eb: Node = runner.get_event_bus()

	var skill_hits := [0]
	var dunk_events: Array[Dictionary] = []
	var score_events: Array[Dictionary] = []
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, _p: bool) -> void:
		if pid == 1 and cid == "tectonic_slam":
			skill_hits[0] += 1
	)
	runner.connect_temp_signal(eb.dunk_impact, func(pid: int, _r: Vector3, power: float) -> void:
		dunk_events.append({"pid": pid, "power": power})
	)
	runner.connect_temp_signal(eb.score_changed, func(tid: int, _ns: int, d: int, _i3: bool, _s: int) -> void:
		score_events.append({"team": tid, "delta": d})
	)

	mc.call("restart_match")
	score_events.clear()
	# Place at z = -8.6 -> dist = 3.825m (inside Powerhouse 4.2m Tectonic Slam reach, beyond normal 2.9m dunk!)
	titan.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -8.6)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.6, 0.0, -11.3)))
	ball.call("set_controlled_state", 1, titan, 1, 0, true)
	await runner.wait_physics_frames(2)

	await _feed_input_steps(runner, off_ctrl, [
		{"buttons": BTN_SPRINT},
		{"buttons": BTN_JUMP},
		{"buttons": BTN_SHOOT},
	], 6)

	var shot_type_now := String(titan.shooting_system.get("last_shot_type"))
	var locked_now := String(ball.call("get_state_name"))
	var armored_now: bool = bool(titan.call("is_armored"))

	# Verify armor resists massive incoming balance damage mid-flight!
	titan.call("apply_balance_damage", 250.0, 2)
	var stunned_while_armored: bool = bool(titan.call("is_ankle_broken"))

	await runner.wait_physics_frames(50)

	runner.assert_eq(skill_hits[0], 1, "Powerhouse Tectonic Slam (Shift, Space, LMB) triggers from 3.83m")
	runner.assert_eq(shot_type_now, "tectonic_slam", "ShootingSystem activates 'tectonic_slam'")
	runner.assert_eq(locked_now, "DUNK_LOCKED", "Tectonic Slam locks ball in DUNK_LOCKED")
	runner.assert_true(armored_now, "Tectonic Slam grants super-armor (is_armored() == true)")
	runner.assert_false(stunned_while_armored, "Armored Tectonic Slam ignores incoming balance break/stun")
	runner.assert_eq(dunk_events.size(), 1, "Tectonic Slam emits EventBus.dunk_impact")
	if dunk_events.size() >= 1:
		runner.assert_ge(float(dunk_events[0]["power"]), 1.65, "Tectonic Slam dunk power >= 1.65 (actual=%.2f)" % float(dunk_events[0]["power"]))
	runner.assert_true(bool(defender.call("is_ankle_broken")), "Tectonic Slam 4.2m shockwave breaks nearby defender's ankles")
	runner.assert_eq(score_events.size(), 1, "Tectonic Slam slams ball through UpperGate -> LowerGate and scores")
	if score_events.size() >= 1:
		runner.assert_eq(int(score_events[0]["delta"]), 2, "Tectonic Slam awards +2 points")


# ==============================================================================
# 7. All-Rounder Unique Skill — Eclipse Counter (C, Q, E, Shift) On-Ball & Off-Ball
# ==============================================================================
func _test_all_rounder_eclipse_counter_both_modes(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var eclipse := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var opp := _spawn_extra_player(arena, "EclipseOpp", 2, 1, Vector3(0.0, 0.0, -7.8))
	await runner.wait_physics_frames(2)

	eclipse.call("apply_archetype_by_id", "all_rounder")
	opp.call("apply_archetype_by_id", "sharpshooter")
	var ec_ctrl := _make_input_controller(eclipse)
	var _opp_ctrl := _make_input_controller(opp)
	var eb: Node = runner.get_event_bus()

	var skill_hits := [0]
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, _p: bool) -> void:
		if pid == 1 and cid == "eclipse_counter":
			skill_hits[0] += 1
	)

	# --- 7A. On-Ball Offense Mode (counter-drive burst + steal shield + shot bonus) ---
	eclipse.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.5)))
	opp.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, -8.0)))
	ball.call("set_controlled_state", 1, eclipse, 1, 0, true)
	await runner.wait_physics_frames(2)
	var pre_off_z: float = eclipse.global_position.z

	await _feed_input_steps(runner, ec_ctrl, [
		{"buttons": BTN_STANCE},
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SKILL_E},
		{"buttons": BTN_SPRINT},
	], 6)
	var off_shield: bool = bool(eclipse.call("has_steal_protection"))
	var off_shot_bon: float = float(eclipse.dribble_system.call("get_combo_shot_bonus"))
	await runner.wait_physics_frames(18)

	runner.assert_eq(skill_hits[0], 1, "All-Rounder Eclipse Counter (C, Q, E, Shift) triggers ON-BALL")
	runner.assert_true(off_shield, "On-ball Eclipse Counter activates steal shield")
	runner.assert_gt(off_shot_bon, 0.11, "On-ball Eclipse Counter grants gather shot bonus")
	runner.assert_lt(eclipse.global_position.z - pre_off_z, -2.0, "On-ball Eclipse Counter bursts toward hoop")

	# --- 7B. Off-Ball Defense Mode (instant closeout burst + steal/contest buff, requires_ball=false!) ---
	eclipse.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.5)))
	opp.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -7.8)))
	ball.call("set_controlled_state", 1, opp, 2, 1, true) # Opponent holds ball!
	await runner.wait_physics_frames(2)

	var pre_dist_to_opp: float = eclipse.global_position.distance_to(opp.global_position)
	await _feed_input_steps(runner, ec_ctrl, [
		{"buttons": BTN_STANCE},
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SKILL_E},
		{"buttons": BTN_SPRINT},
	], 6)

	var has_def_buff: bool = bool(eclipse.defense_system.call("has_defense_buff"))
	var eff_steal_r: float = float(eclipse.defense_system.call("get_effective_steal_radius"))
	var contest_bon: float = float(eclipse.defense_system.call("get_contest_bonus"))
	await runner.wait_physics_frames(16)
	var post_dist_to_opp: float = eclipse.global_position.distance_to(opp.global_position)

	runner.assert_eq(skill_hits[0], 2, "All-Rounder Eclipse Counter ALSO triggers OFF-BALL on defense (requires_ball=false)")
	runner.assert_true(has_def_buff, "Off-ball Eclipse Counter activates temporary defense buff")
	runner.assert_ge(eff_steal_r, 2.45, "Off-ball Eclipse Counter boosts effective steal radius >= 2.45m (actual=%.2fm)" % eff_steal_r)
	runner.assert_ge(contest_bon, 0.29, "Off-ball Eclipse Counter grants >= +0.30 shot contest bonus (actual=%.2f)" % contest_bon)
	runner.assert_lt(post_dist_to_opp, pre_dist_to_opp - 1.8, "Off-ball Eclipse Counter closes out rapidly toward opponent (%.2fm -> %.2fm)" % [pre_dist_to_opp, post_dist_to_opp])
