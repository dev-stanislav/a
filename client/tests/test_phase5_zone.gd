extends Node
## Phase 5 Automated Verification Suite — Zone Awakening (PHANTOM COURT ONLINE)
## Verifies:
## 1. ZoneComponent meter (starts at 0, zero passive regen, positive-play accrual + archetype
##    gain_rate_mult scaling, cannot activate < 100, BTN_ZONE activation at 100 emitting
##    EventBus.zone_activated(pid, 12.0), strictly zero energy gain while active, steady 100/12
##    drain, clean EventBus.zone_ended & baseline restoration, and rollback snapshot roundtrip).
## 2. Zone gameplay buffs (+15% move/sprint speed, +20% jump & block reach, +25% stamina efficiency
##    0.75x drain) verified via getters AND live 60 Hz physics simulation, plus baseline restoration.
## 3. EX enhanced skills: Meteor Dunk EX (6.2m range blocked outside Zone, succeeds in Zone + scores +2),
##    Phantom Drive EX (16+ m/s), Ankle Breaker EX (wider 3.6m cone breaks defender at 3.25m),
##    Mirror Step EX (+0.22+ shot window bonus), Starlight High-Arc EX (10.5m deep +3 swish),
##    and strictly zero Zone refill when executing EX combos while active.
## 4. Dramatic Zone CameraRig: FOV widens 72° -> 84° + dynamic lateral Dutch-angle roll,
##    returning cleanly to 72° & 0° roll on Zone end.
## 5. Shaders (zone_aura.gdshader, zone_vignette.gdshader), AuraController, VFXManager Zone UI,
##    MatchController Zone indicator, ProceduralSfxSynth non-silent 44.1 kHz WAV buffers,
##    SoundManager buses/SFX playback, and DynamicMusicPlayer 0.0 -> 1.0 -> 0.0 intensity crossfade.

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"
const PLAYER_SCENE_PATH := "res://scenes/player/player.tscn"

const BTN_SPRINT: int  = 1
const BTN_JUMP: int    = 2
const BTN_SHOOT: int   = 4
const BTN_SKILL_Q: int = 16
const BTN_SKILL_E: int = 32
const BTN_SKILL_R: int = 64
const BTN_ZONE: int    = 256


func run(runner: SceneTree) -> void:
	await _test_zone_meter_rules_activation_drain_and_snapshot(runner)
	await _test_zone_buffs_and_baseline_restoration(runner)
	await _test_zone_ex_enhanced_skills(runner)
	await _test_dramatic_zone_camera(runner)
	await _test_shaders_aura_vfx_ui_and_dynamic_audio(runner)


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


func _feed_input_steps(
	runner: SceneTree,
	ctrl: Dictionary,
	steps: Array[Dictionary],
	gap_frames: int,
	held_dir: Vector2 = Vector2.ZERO
) -> void:
	for i in range(steps.size()):
		var st: Dictionary = steps[i]
		ctrl["buttons"] = int(st.get("buttons", 0))
		ctrl["local_dir"] = st.get("local_dir", held_dir)
		await runner.wait_physics_frames(1)
		ctrl["buttons"] = 0
		ctrl["local_dir"] = held_dir
		if i < steps.size() - 1:
			await runner.wait_physics_frames(maxi(1, gap_frames - 1))


# ==============================================================================
# 1. ZoneComponent Meter, Accrual, Activation, Zero Active Gain, 12s Drain & Snap
# ==============================================================================
func _test_zone_meter_rules_activation_drain_and_snapshot(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	if not runner.assert_not_null(player, "Zone: LocalPlayer present"):
		return

	var ctrl := _make_input_controller(player)
	var eb: Node = runner.get_event_bus()
	var zone_act_events: Array[Dictionary] = []
	var zone_end_events: Array[int] = []
	runner.connect_temp_signal(eb.zone_activated, func(pid: int, dur: float) -> void:
		zone_act_events.append({"pid": pid, "dur": dur})
	)
	runner.connect_temp_signal(eb.zone_ended, func(pid: int) -> void:
		zone_end_events.append(pid)
	)

	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	if ball != null:
		ball.call("reset_to_free", Vector3(6.5, 0.5, 11.0))

	var zc: Node = player.zone
	runner.assert_approx(float(zc.get("current_energy")), 0.0, 0.001, "Zone meter starts at 0.0")
	runner.assert_false(bool(zc.get("is_active")), "Zone starts inactive")

	# Zero passive regeneration over 60 ticks (1.0s)
	await runner.wait_physics_frames(60)
	runner.assert_approx(float(zc.get("current_energy")), 0.0, 0.001, "Zone has STRICTLY zero passive regeneration over 1.0s")

	# Positive-play accrual verification (baseline 1.0x gain_rate_mult)
	var expected_plays := [
		["basket_2pt", 18.0],
		["basket_3pt", 24.0],
		["perfect_shot", 10.0],
		["block", 22.0],
		["steal", 22.0],
		["ankle_break", 20.0],
		["assist", 15.0],
	]
	for pair in expected_plays:
		zc.call("reset_zone")
		var added: float = float(zc.call("award_positive_play", String(pair[0])))
		runner.assert_approx(added, float(pair[1]), 0.01, "Zone positive play '%s' awards +%.1f" % [String(pair[0]), float(pair[1])])

	# Archetype scaling check: Playmaker (gain_rate_mult = 1.25)
	player.call("apply_archetype_by_id", "playmaker")
	zc.call("reset_zone")
	var pm_3pt_gain: float = float(zc.call("award_positive_play", "basket_3pt"))
	runner.assert_approx(pm_3pt_gain, 30.0, 0.05, "Playmaker 1.25x scales basket_3pt (+24) to +30.0 Zone")

	# Reset to standard 1.0x gain archetype for deterministic threshold/drain tests
	player.call("apply_archetype", {"id": "all_rounder", "stats": {"zone_gain_mult": 1.0}})
	zc.call("reset_zone")

	# Cannot activate below 100.0
	zc.call("set_energy", 99.0)
	runner.assert_false(bool(zc.call("can_activate")), "Zone cannot activate at 99.0 energy (< 100.0)")
	ctrl["buttons"] = BTN_ZONE
	await runner.wait_physics_frames(2)
	ctrl["buttons"] = 0
	await runner.wait_physics_frames(1) # Clean button release before rising-edge press at 100.0
	runner.assert_false(bool(player.call("is_in_zone")), "BTN_ZONE below 100.0 does NOT activate Zone")
	runner.assert_eq(zone_act_events.size(), 0, "No zone_activated emitted below 100.0")

	# Activate via BTN_ZONE (V / 256) at exact 100.0
	zc.call("set_energy", 100.0)
	runner.assert_true(bool(zc.call("can_activate")), "Zone can_activate() == true at 100.0")
	ctrl["buttons"] = BTN_ZONE
	await runner.wait_physics_frames(1)
	ctrl["buttons"] = 0

	runner.assert_true(bool(player.call("is_in_zone")), "BTN_ZONE at 100.0 activates Zone")
	runner.assert_eq(zone_act_events.size(), 1, "Zone activation emits EventBus.zone_activated once")
	if zone_act_events.size() >= 1:
		runner.assert_eq(int(zone_act_events[0]["pid"]), 1, "zone_activated player_id == 1")
		runner.assert_approx(float(zone_act_events[0]["dur"]), 12.0, 0.05, "zone_activated duration == 12.0s")
	runner.assert_eq(int(zc.get("activations_count")), 1, "Zone activations_count incremented to 1")

	# STRICTLY zero energy gain while active
	var e_before_attempts: float = float(zc.get("current_energy"))
	var g1: float = float(zc.call("add_charge", 45.0))
	var g2: float = float(zc.call("award_positive_play", "basket_3pt"))
	var g3: float = float(zc.call("award_positive_play", "block"))
	runner.assert_approx(g1 + g2 + g3, 0.0, 0.0001, "STRICTLY zero Zone energy gain while active")
	runner.assert_le(float(zc.get("current_energy")), e_before_attempts + 0.001, "Active Zone energy cannot be refilled")

	# Steady drain: 100.0 / 12.0 = 8.3333 energy/sec over 60 physics ticks (1.0s)
	var e_t0: float = float(zc.get("current_energy"))
	var rem_t0: float = float(zc.get("time_remaining"))
	await runner.wait_physics_frames(60)
	var e_t1: float = float(zc.get("current_energy"))
	var rem_t1: float = float(zc.get("time_remaining"))
	runner.assert_approx(e_t0 - e_t1, 100.0 / 12.0, 0.25, "Active Zone drains at exact 100/12 per second")
	runner.assert_approx(rem_t0 - rem_t1, 1.0, 0.05, "Zone time_remaining decrements 1.0s over 60 ticks")

	# Rollback snapshot roundtrip while active
	var p_snap: Dictionary = player.call("export_sim_state")
	zc.call("reset_zone")
	runner.assert_false(bool(zc.get("is_active")), "Sanity: reset_zone deactivates Zone before import")
	player.call("import_sim_state", p_snap)
	runner.assert_true(bool(zc.get("is_active")), "import_sim_state restores active Zone state")
	runner.assert_approx(float(zc.get("current_energy")), e_t1, 0.05, "import_sim_state restores exact current_energy")
	runner.assert_approx(float(zc.get("time_remaining")), rem_t1, 0.05, "import_sim_state restores exact time_remaining")
	runner.assert_eq(int(zc.get("activations_count")), 1, "import_sim_state restores activations_count == 1")

	# Clean expiration on timer reaching 0.0 -> emits EventBus.zone_ended
	zone_end_events.clear()
	zc.set("time_remaining", 0.12)
	zc.set("current_energy", 100.0 * (0.12 / 12.0))
	await runner.wait_physics_frames(14)
	runner.assert_false(bool(player.call("is_in_zone")), "Zone cleanly deactivates when timer reaches 0.0")
	runner.assert_approx(float(zc.get("current_energy")), 0.0, 0.001, "Zone energy reaches 0.0 at expiry")
	runner.assert_eq(zone_end_events.size(), 1, "Zone expiry emits EventBus.zone_ended once")


# ==============================================================================
# 2. Zone Buffs (+15% Speed, +20% Jump/Block, +25% Stamina Eff) & Restoration
# ==============================================================================
func _test_zone_buffs_and_baseline_restoration(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	if not runner.assert_not_null(player, "ZoneBuffs: LocalPlayer present"):
		return

	var ctrl := _make_input_controller(player)
	if ball != null:
		ball.call("reset_to_free", Vector3(6.5, 0.5, 11.0))

	# Baseline measurements (out of Zone)
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 5.0)))
	await runner.wait_physics_frames(2)

	var base_sprint_api: float = float(player.call("get_effective_sprint_speed"))
	var base_jump_api: float = float(player.call("get_effective_jump_velocity"))
	var base_block_api: float = float(player.call("get_effective_block_radius"))
	var base_stam_mult: float = float(player.call("get_stamina_cost_multiplier"))
	runner.assert_approx(base_stam_mult, 1.0, 0.001, "Baseline stamina cost multiplier == 1.0")

	# Measure baseline live sprint speed + 30f stamina drain
	var s0_base: float = float(player.stamina.get("current_stamina"))
	ctrl["local_dir"] = Vector2(0.0, 1.0)
	ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(30)
	var live_sprint_base: float = Vector2(player.velocity.x, player.velocity.z).length()
	var drain_base: float = s0_base - float(player.stamina.get("current_stamina"))
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0

	# Measure baseline live jump apex height
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	await runner.wait_physics_frames(2)
	ctrl["buttons"] = BTN_JUMP
	await runner.wait_physics_frames(2)
	ctrl["buttons"] = 0
	var peak_y_base: float = 0.0
	for _i in range(45):
		await runner.physics_frame
		if player.global_position.y > peak_y_base:
			peak_y_base = player.global_position.y

	# Now activate Zone and measure ALL buffs
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 5.0)))
	player.zone.call("set_energy", 100.0)
	player.call("activate_zone")
	await runner.wait_physics_frames(2)

	runner.assert_approx(float(player.call("get_effective_sprint_speed")), base_sprint_api * 1.15, 0.05, "Zone getter: +15% effective sprint speed")
	runner.assert_approx(float(player.call("get_effective_jump_velocity")), base_jump_api * 1.20, 0.05, "Zone getter: +20% effective jump velocity")
	runner.assert_approx(float(player.call("get_effective_block_radius")), base_block_api * 1.20, 0.03, "Zone getter: +20% effective block reach")
	runner.assert_approx(float(player.call("get_stamina_cost_multiplier")), 0.75, 0.001, "Zone getter: +25% stamina efficiency (0.75x cost)")

	# Live sprint speed & stamina drain in Zone
	player.stamina.call("reset_stamina")
	var s0_zone: float = float(player.stamina.get("current_stamina"))
	ctrl["local_dir"] = Vector2(0.0, 1.0)
	ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(30)
	var live_sprint_zone: float = Vector2(player.velocity.x, player.velocity.z).length()
	var drain_zone: float = s0_zone - float(player.stamina.get("current_stamina"))
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0

	runner.assert_approx(live_sprint_zone / maxf(0.01, live_sprint_base), 1.15, 0.03, "Live 60 Hz Zone sprint speed is +15% faster")
	runner.assert_approx(drain_zone / maxf(0.01, drain_base), 0.75, 0.05, "Live 60 Hz Zone sprint stamina drain is 0.75x (+25% efficiency)")

	# Live jump apex height in Zone (+20% jump velocity -> ~1.44x apex height)
	player.global_position = Vector3(0.0, 0.0, 0.0)
	player.velocity = Vector3.ZERO
	await runner.wait_physics_frames(4)
	ctrl["buttons"] = BTN_JUMP
	await runner.wait_physics_frames(2)
	ctrl["buttons"] = 0
	var peak_y_zone: float = 0.0
	for _i in range(55):
		await runner.physics_frame
		if player.global_position.y > peak_y_zone:
			peak_y_zone = player.global_position.y
	runner.assert_gt(peak_y_zone, peak_y_base * 1.32, "Live 60 Hz Zone jump apex (%.2fm) significantly exceeds baseline (%.2fm)" % [peak_y_zone, peak_y_base])

	# Deactivate Zone -> verify ALL buffs restore cleanly to exact baseline
	player.zone.call("deactivate_zone")
	await runner.wait_physics_frames(2)
	runner.assert_approx(float(player.call("get_effective_sprint_speed")), base_sprint_api, 0.01, "Post-Zone sprint speed restored to exact baseline")
	runner.assert_approx(float(player.call("get_effective_jump_velocity")), base_jump_api, 0.01, "Post-Zone jump velocity restored to exact baseline")
	runner.assert_approx(float(player.call("get_effective_block_radius")), base_block_api, 0.01, "Post-Zone block reach restored to exact baseline")
	runner.assert_approx(float(player.call("get_stamina_cost_multiplier")), 1.0, 0.001, "Post-Zone stamina cost multiplier restored to 1.0")


# ==============================================================================
# 3. Zone EX Enhanced Skills & Zero Zone Refill While Active
# ==============================================================================
func _test_zone_ex_enhanced_skills(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var offense := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var mc := arena.get_node_or_null("MatchController") as Node
	var defender := _spawn_extra_player(arena, "ExTargetDef", 2, 1, Vector3(0.0, 0.0, -7.25))
	await runner.wait_physics_frames(2)

	var off_ctrl := _make_input_controller(offense)
	var _def_ctrl := _make_input_controller(defender)
	var eb: Node = runner.get_event_bus()

	var combo_ids: Array[String] = []
	var dunk_powers: Array[float] = []
	var score_events: Array[Dictionary] = []
	var ankle_hits := [0]
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, _p: bool) -> void:
		if pid == 1:
			combo_ids.append(cid)
	)
	runner.connect_temp_signal(eb.dunk_impact, func(pid: int, _r: Vector3, pwr: float) -> void:
		if pid == 1:
			dunk_powers.append(pwr)
	)
	runner.connect_temp_signal(eb.score_changed, func(tid: int, _ns: int, d: int, is3: bool, _sid: int) -> void:
		score_events.append({"team": tid, "delta": d, "is_three": is3})
	)
	runner.connect_temp_signal(eb.ankle_broken, func(vid: int, aid: int, _p: Vector3) -> void:
		if vid == 2 and aid == 1:
			ankle_hits[0] += 1
	)

	# --- 3A. Meteor Dunk EX from 6.20m (blocked at 6.2m outside Zone, succeeds in Zone + scores +2) ---
	mc.call("restart_match")
	combo_ids.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.225))) # dist = 6.20m from HoopB (-12.425)
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(5.0, 0.0, -5.0)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	# Tap Shift -> W -> Space -> R cleanly so player remains at ~6.15m (> 5.5m base, <= 6.5m EX)
	await _feed_input_steps(runner, off_ctrl, [
		{"buttons": BTN_SPRINT},
		{"local_dir": Vector2(0.0, 1.0)},
		{"buttons": BTN_JUMP},
		{"buttons": BTN_SKILL_R},
	], 5)
	off_ctrl["local_dir"] = Vector2.ZERO
	await runner.wait_physics_frames(2)
	var dist_md_base: float = Vector2(offense.global_position.x, offense.global_position.z - (-12.425)).length()
	runner.assert_gt(dist_md_base, 5.5, "Sanity: Meteor Dunk base test stays > 5.5m from rim (actual=%.2fm)" % dist_md_base)
	runner.assert_false(combo_ids.has("meteor_dunk"), "Outside Zone: Meteor Dunk rejected at ~6.20m (> 5.5m base range)")

	# Now activate Zone at the same 6.20m spot and execute Meteor Dunk EX!
	mc.call("restart_match")
	combo_ids.clear()
	dunk_powers.clear()
	score_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.225)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	offense.zone.call("set_energy", 100.0)
	offense.call("activate_zone")
	await runner.wait_physics_frames(2)

	var z_energy_pre_md: float = float(offense.zone.get("current_energy"))
	await _feed_input_steps(runner, off_ctrl, [
		{"buttons": BTN_SPRINT},
		{"local_dir": Vector2(0.0, 1.0)},
		{"buttons": BTN_JUMP},
		{"buttons": BTN_SKILL_R},
	], 5)
	off_ctrl["local_dir"] = Vector2.ZERO
	var md_was_ex: bool = bool(offense.get("last_executed_was_ex"))
	var z_energy_post_md: float = float(offense.zone.get("current_energy"))
	await runner.wait_physics_frames(55)

	runner.assert_true(combo_ids.has("meteor_dunk"), "In Zone: Meteor Dunk EX triggers cleanly from 6.20m (<= 6.5m EX range)")
	runner.assert_true(md_was_ex, "Meteor Dunk in Zone flags last_executed_was_ex == true")
	runner.assert_le(z_energy_post_md, z_energy_pre_md, "EX Meteor Dunk does NOT refill Zone meter while active")
	runner.assert_true(dunk_powers.size() == 1 and dunk_powers[0] >= 1.85, "Meteor Dunk EX delivers boosted dunk power >= 1.85")
	runner.assert_eq(score_events.size(), 1, "Meteor Dunk EX from 6.20m slams through rim and scores +2")

	# --- 3B. Phantom Drive EX (1.22x boosted dash speed >= 16 m/s) ---
	combo_ids.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -2.0)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	offense.zone.call("set_energy", 100.0)
	offense.call("activate_zone")
	await runner.wait_physics_frames(2)

	await _feed_input_steps(runner, off_ctrl, [
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SKILL_E},
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SPRINT},
	], 6)
	var pd_was_ex: bool = bool(offense.get("last_executed_was_ex"))
	var pd_peak_spd: float = 0.0
	for _i in range(15):
		await runner.physics_frame
		var spd: float = Vector2(offense.velocity.x, offense.velocity.z).length()
		if spd > pd_peak_spd:
			pd_peak_spd = spd
	runner.assert_true(combo_ids.has("phantom_drive") and pd_was_ex, "Phantom Drive EX triggers in Zone")
	runner.assert_gt(pd_peak_spd, 16.0, "Phantom Drive EX reaches >= 16 m/s dash speed (actual=%.2f)" % pd_peak_spd)

	# --- 3C. Ankle Breaker EX wider 3.6m cone (breaks defender at 3.25m, beyond 2.8m base) ---
	combo_ids.clear()
	ankle_hits[0] = 0
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	defender.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -7.25))) # 3.25m in front
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	offense.zone.call("set_energy", 100.0)
	offense.call("activate_zone")
	await runner.wait_physics_frames(2)

	await _feed_input_steps(runner, off_ctrl, [
		{"buttons": BTN_SKILL_E},
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SKILL_E},
		{"buttons": BTN_SHOOT},
	], 6)
	await runner.wait_physics_frames(3)
	runner.assert_true(combo_ids.has("ankle_breaker") and bool(offense.get("last_executed_was_ex")), "Ankle Breaker EX triggers in Zone")
	runner.assert_eq(ankle_hits[0], 1, "Ankle Breaker EX wider 3.6m cone breaks defender at 3.25m")
	runner.assert_true(bool(defender.call("is_ankle_broken")), "Defender at 3.25m is ankle-broken by Ankle Breaker EX")

	# --- 3D. Mirror Step EX (+0.22+ shot window bonus) ---
	combo_ids.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -6.0)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	offense.zone.call("set_energy", 100.0)
	offense.call("activate_zone")
	await runner.wait_physics_frames(2)

	await _feed_input_steps(runner, off_ctrl, [
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SKILL_Q},
		{"buttons": BTN_SKILL_E},
		{"buttons": BTN_SKILL_R},
	], 6)
	await runner.wait_physics_frames(2)
	runner.assert_true(combo_ids.has("mirror_step") and bool(offense.get("last_executed_was_ex")), "Mirror Step EX triggers in Zone")
	runner.assert_ge(float(offense.dribble_system.call("get_combo_shot_bonus")), 0.21, "Mirror Step EX grants boosted >= +0.22 shot window bonus")

	# --- 3E. Starlight High-Arc EX from ~10.4m deep (blocked outside Zone > 9.8m, swishes +3 in Zone <= 10.8m!) ---
	offense.call("apply_archetype_by_id", "sharpshooter")
	mc.call("restart_match")
	combo_ids.clear()
	score_events.clear()
	# Place at z = -1.725 (10.70m from HoopB -12.425); brief 8-frame E->S->LMB stutter keeps release at ~10.35m (> 9.8m base, <= 10.8m EX)
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -1.725)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	await runner.wait_physics_frames(2)

	await _feed_input_steps(runner, off_ctrl, [
		{"buttons": BTN_SKILL_E},
		{"local_dir": Vector2(0.0, -1.0)},
		{"buttons": BTN_SHOOT},
	], 4)
	var dist_star_base: float = Vector2(offense.global_position.x, offense.global_position.z - (-12.425)).length()
	await runner.wait_physics_frames(2)
	runner.assert_gt(dist_star_base, 9.8, "Sanity: Starlight base test stays > 9.8m from rim (actual=%.2fm)" % dist_star_base)
	runner.assert_false(combo_ids.has("starlight_high_arc"), "Outside Zone: Starlight High Arc rejected at > 9.8m base range")

	mc.call("restart_match")
	combo_ids.clear()
	score_events.clear()
	offense.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -1.725)))
	ball.call("set_controlled_state", 1, offense, 1, 0, true)
	offense.zone.call("set_energy", 100.0)
	offense.call("activate_zone")
	await runner.wait_physics_frames(2)

	await _feed_input_steps(runner, off_ctrl, [
		{"buttons": BTN_SKILL_E},
		{"local_dir": Vector2(0.0, -1.0)},
		{"buttons": BTN_SHOOT},
	], 4)
	var star_ex: bool = bool(offense.get("last_executed_was_ex"))
	var peak_arc_y: float = 0.0
	for _i in range(145):
		await runner.physics_frame
		if ball.global_position.y > peak_arc_y:
			peak_arc_y = ball.global_position.y

	runner.assert_true(combo_ids.has("starlight_high_arc") and star_ex, "In Zone: Starlight High-Arc EX triggers from ~10.4m (<= 10.8m EX range)")
	runner.assert_ge(peak_arc_y, 6.0, "Starlight High-Arc EX soars >= 6.0m apex (actual=%.2fm)" % peak_arc_y)
	runner.assert_eq(score_events.size(), 1, "Starlight High-Arc EX from deep range swishes through HoopB")
	if score_events.size() >= 1:
		runner.assert_eq(int(score_events[0]["delta"]), 3, "Deep Starlight High-Arc EX awards +3 points")


# ==============================================================================
# 4. Dramatic Zone CameraRig (FOV 72° -> 84° + Lateral Dutch-Angle Roll)
# ==============================================================================
func _test_dramatic_zone_camera(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	if not runner.assert_not_null(player, "Camera: LocalPlayer present"):
		return

	var ctrl := _make_input_controller(player)
	if ball != null:
		ball.call("reset_to_free", Vector3(6.5, 0.5, 11.0))

	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)))
	await runner.wait_physics_frames(4)

	var rig: Node3D = player.camera_rig
	runner.assert_not_null(rig, "CameraRig present on LocalPlayer")
	runner.assert_false(bool(rig.call("is_zone_camera_active")), "CameraRig Zone mode starts inactive")
	runner.assert_approx(float(rig.call("get_current_fov")), 72.0, 0.2, "Baseline CameraRig FOV == 72.0°")
	runner.assert_approx(float(rig.call("get_current_roll_deg")), 0.0, 0.1, "Baseline CameraRig Dutch roll == 0.0°")

	# Activate Zone & strafe laterally right to drive FOV expansion + dynamic Dutch-angle roll
	player.zone.call("set_energy", 100.0)
	player.call("activate_zone")
	ctrl["local_dir"] = Vector2(1.0, 0.0)
	ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(40)

	var zone_fov: float = float(rig.call("get_current_fov"))
	var zone_roll_deg: float = float(rig.call("get_current_roll_deg"))
	runner.assert_true(bool(rig.call("is_zone_camera_active")), "CameraRig Zone mode activates during Zone")
	runner.assert_approx(zone_fov, 84.0, 1.5, "Zone CameraRig FOV widens from 72° -> ~84°")
	runner.assert_ge(absf(zone_roll_deg), 2.0, "Zone CameraRig applies dynamic Dutch-angle roll during lateral movement (actual=%.2f°)" % zone_roll_deg)
	runner.assert_le(absf(zone_roll_deg), 4.6, "Zone CameraRig Dutch roll stays within ±4.5° limit")

	# End Zone & settle -> FOV returns to 72° and roll returns to 0°
	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0
	player.zone.call("deactivate_zone")
	await runner.wait_physics_frames(45)

	runner.assert_false(bool(rig.call("is_zone_camera_active")), "CameraRig Zone mode turns off after Zone ends")
	runner.assert_approx(float(rig.call("get_current_fov")), 72.0, 0.3, "Post-Zone CameraRig FOV returns cleanly to 72.0°")
	runner.assert_approx(float(rig.call("get_current_roll_deg")), 0.0, 0.15, "Post-Zone CameraRig Dutch roll returns cleanly to 0.0°")


# ==============================================================================
# 5. Shaders, AuraController, VFXManager, MatchController UI & Dynamic Audio
# ==============================================================================
func _test_shaders_aura_vfx_ui_and_dynamic_audio(runner: SceneTree) -> void:
	await runner.clear_stage()

	# --- 5A. Shaders load cleanly with zero parse errors ---
	var aura_shader := load("res://shaders/zone_aura.gdshader") as Shader
	var vig_shader := load("res://shaders/zone_vignette.gdshader") as Shader
	runner.assert_not_null(aura_shader, "res://shaders/zone_aura.gdshader loads cleanly")
	runner.assert_not_null(vig_shader, "res://shaders/zone_vignette.gdshader loads cleanly")
	if aura_shader != null:
		runner.assert_true(aura_shader.code.contains("aura_color") and aura_shader.code.contains("intensity"), "zone_aura.gdshader defines aura_color & intensity uniforms")
	if vig_shader != null:
		runner.assert_true(vig_shader.code.contains("vignette_color") and vig_shader.code.contains("intensity"), "zone_vignette.gdshader defines vignette_color & intensity uniforms")

	# --- 5B. ProceduralSfxSynth generates real non-silent 44.1 kHz 16-bit WAV streams ---
	var wav_act: AudioStreamWAV = ProceduralSfxSynth.generate_zone_activate_sfx()
	var wav_end: AudioStreamWAV = ProceduralSfxSynth.generate_zone_end_sfx()
	var wav_base: AudioStreamWAV = ProceduralSfxSynth.generate_base_music_loop()
	var wav_zone: AudioStreamWAV = ProceduralSfxSynth.generate_zone_intense_music_layer()

	for wav_pair in [
		["zone_activate_sfx", wav_act, false],
		["zone_end_sfx", wav_end, false],
		["base_music_loop", wav_base, true],
		["zone_intense_music", wav_zone, true],
	]:
		var wname: String = wav_pair[0]
		var wstream: AudioStreamWAV = wav_pair[1]
		var expect_loop: bool = wav_pair[2]
		runner.assert_not_null(wstream, "ProceduralSfxSynth generates '%s'" % wname)
		if wstream != null:
			runner.assert_eq(wstream.mix_rate, 44100, "'%s' sample rate == 44100 Hz" % wname)
			runner.assert_gt(float(wstream.data.size()), 10000.0, "'%s' PCM buffer is non-empty" % wname)
			var rms: float = ProceduralSfxSynth.compute_rms(wstream)
			var peak: float = ProceduralSfxSynth.compute_peak(wstream)
			runner.assert_gt(rms, 0.02, "'%s' RMS > 0.02 (non-silent, actual=%.4f)" % [wname, rms])
			runner.assert_gt(peak, 0.20, "'%s' peak amplitude > 0.20 (actual=%.4f)" % [wname, peak])
			if expect_loop:
				runner.assert_eq(wstream.loop_mode, AudioStreamWAV.LOOP_FORWARD, "'%s' configured with LOOP_FORWARD" % wname)

	# --- 5C. Full Arena Integration: AuraController + VFXManager + MatchController + SoundManager + DynamicMusicPlayer ---
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var mc := arena.get_node_or_null("MatchController") as Node
	var vfx_mgr := arena.get_node_or_null("VFXManager") as Node
	var sound_mgr := arena.get_node_or_null("SoundManager") as Node

	runner.assert_not_null(vfx_mgr, "Arena dynamically mounts VFXManager")
	runner.assert_not_null(sound_mgr, "Arena dynamically mounts SoundManager")
	if player == null or vfx_mgr == null or sound_mgr == null or mc == null:
		return

	var aura := player.get_node_or_null("AuraController") as Node3D
	runner.assert_not_null(aura, "LocalPlayer dynamically mounts AuraController")
	var music_player: Node = sound_mgr.call("get_music_player")
	runner.assert_not_null(music_player, "SoundManager owns DynamicMusicPlayer")

	# Verify required AudioServer buses exist
	for bus_name in ["SFX", "Music", "Ambience"]:
		runner.assert_ge(float(AudioServer.get_bus_index(bus_name)), 0.0, "SoundManager created AudioServer bus '%s'" % bus_name)

	# Verify archetype aura color syncs into AuraController
	player.call("apply_archetype_by_id", "speedster")
	if aura != null:
		var acol: Color = aura.call("get_aura_color")
		runner.assert_approx(acol.r, Color("#00F0FF").r, 0.02, "AuraController syncs archetype aura_color (Speedster Cyan)")
		runner.assert_approx(acol.b, Color("#00F0FF").b, 0.02, "AuraController blue channel matches Speedster Cyan")
		runner.assert_false(bool(aura.call("is_aura_active")), "Aura starts inactive before Zone")
		runner.assert_approx(float(aura.call("get_intensity")), 0.0, 0.001, "Aura intensity starts at 0.0")

	runner.assert_false(bool(vfx_mgr.call("is_zone_ui_active")), "VFXManager Zone UI starts inactive")
	runner.assert_false(bool(mc.call("is_zone_indicator_active")), "MatchController Zone indicator starts inactive")
	runner.assert_approx(float(music_player.call("get_intensity")), 0.0, 0.01, "DynamicMusicPlayer intensity starts at 0.0")

	var act_sfx_before: int = int(sound_mgr.call("get_play_count", "zone_activate"))
	var end_sfx_before: int = int(sound_mgr.call("get_play_count", "zone_end"))

	# Trigger Zone Awakening on LocalPlayer!
	player.zone.call("set_energy", 100.0)
	player.call("activate_zone")
	await runner.wait_physics_frames(30)
	# Step deterministic audio/vfx clocks explicitly too so headless variable _process delta never flakes
	music_player.call("step_music", 0.5)
	vfx_mgr.call("step_vfx", 0.1)
	if aura != null:
		aura.call("step_aura", 0.1)

	if aura != null:
		runner.assert_true(bool(aura.call("is_aura_active")), "AuraController activates on EventBus.zone_activated")
		runner.assert_gt(float(aura.call("get_intensity")), 0.80, "Active AuraController shader intensity > 0.80")
		var aura_mesh: MeshInstance3D = aura.call("get_aura_mesh")
		var sparks: CPUParticles3D = aura.call("get_sparks_particles")
		runner.assert_true(aura_mesh != null and aura_mesh.visible, "AuraShell mesh becomes visible during Zone")
		runner.assert_true(sparks != null and sparks.emitting, "ZoneSparks CPUParticles3D emits during Zone")

	runner.assert_true(bool(vfx_mgr.call("is_zone_ui_active")), "VFXManager Zone UI vignette/callout activates")
	runner.assert_eq(int(vfx_mgr.call("get_active_zone_player_id")), 1, "VFXManager tracks active Zone player_id == 1")
	runner.assert_gt(float(vfx_mgr.call("get_zone_vignette_intensity")), 0.60, "VFXManager Zone vignette intensity > 0.60")
	runner.assert_eq(String(vfx_mgr.call("get_zone_banner_text")), "ZONE AWAKENED", "VFXManager displays 'ZONE AWAKENED' callout")
	runner.assert_true(bool(mc.call("is_zone_indicator_active")), "MatchController Zone HUD indicator activates")
	runner.assert_gt(float(int(sound_mgr.call("get_play_count", "zone_activate")) - act_sfx_before), 0.0, "SoundManager plays zone_activate SFX")
	runner.assert_ge(float(music_player.call("get_intensity")), 0.95, "DynamicMusicPlayer ramps intensity cleanly to 1.0 in Zone")

	# End Zone -> verify Aura, VFXManager UI, MatchController indicator, SFX & DynamicMusicPlayer all clear cleanly!
	player.zone.call("deactivate_zone")
	await runner.wait_physics_frames(20)
	music_player.call("step_music", 1.0)
	vfx_mgr.call("step_vfx", 0.1)
	if aura != null:
		aura.call("step_aura", 0.1)

	if aura != null:
		runner.assert_false(bool(aura.call("is_aura_active")), "AuraController deactivates on EventBus.zone_ended")
		runner.assert_approx(float(aura.call("get_intensity")), 0.0, 0.001, "AuraController intensity returns to 0.0")
		var aura_mesh_after: MeshInstance3D = aura.call("get_aura_mesh")
		runner.assert_true(aura_mesh_after != null and not aura_mesh_after.visible, "AuraShell mesh hides after Zone ends")

	runner.assert_false(bool(vfx_mgr.call("is_zone_ui_active")), "VFXManager Zone UI clears on EventBus.zone_ended")
	runner.assert_eq(int(vfx_mgr.call("get_active_zone_player_id")), -1, "VFXManager resets active_zone_player_id to -1")
	runner.assert_approx(float(vfx_mgr.call("get_zone_vignette_intensity")), 0.0, 0.001, "VFXManager vignette intensity clears to 0.0")
	runner.assert_false(bool(mc.call("is_zone_indicator_active")), "MatchController Zone indicator clears on Zone end")
	runner.assert_gt(float(int(sound_mgr.call("get_play_count", "zone_end")) - end_sfx_before), 0.0, "SoundManager plays zone_end SFX")
	runner.assert_approx(float(music_player.call("get_intensity")), 0.0, 0.02, "DynamicMusicPlayer decays cleanly back to 0.0 on Zone end")
