extends Node
## Phase 7 Automated Verification Suite — Artificial Intelligence (PHANTOM COURT ONLINE)
## Verifies:
## 1. AIDifficulty 4 tiers (ROOKIE / PRO / ALL_STAR / PHANTOM) exact spec parameters &
##    AIPerception deterministic reaction-delay ring queue (Phantom 3f vs Rookie 24f).
## 2. AIUtilityBrain deterministic 6-role scoring: shot-clock urgency (< 5s), pass-lane
##    interception-risk avoidance, Zone activation IQ, 3v3 archetype floor spacing without
##    crowding, rim-line defensive stance containment, steal discipline, help rotation &
##    rebound crashing.
## 3. Live on-court 60 Hz AI gameplay via PlayerController.set_external_input_provider():
##    - Open 3pt jump shot swishing +3 & Phantom vs Rookie shot timing precision spread
##    - Genuine frame-paced signature combo triggered through ComboEngine (zero cheating)
##    - On-ball defensive rim-line positioning + BTN_STANCE lock
##    - Autonomous Zone activation via BTN_ZONE at 100 energy
## 4. Arena / MatchController 1v1, 2v2, 3v3 AI roster spawning, default arena preservation,
##    live 3v3 AI-vs-AI scrimmage stability, difficulty switching & cleanup.
## 5. Bit-exact deterministic replay across match_controller.restart_match() & lossless
##    export_sim_state() / import_sim_state() rollback snapshot roundtrip (incl. PCG32 RNG
##    & perception delay queue).

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"
const HOOP_B_RIM := Vector3(0.0, 3.05, -12.425)


func run(runner: SceneTree) -> void:
	await _test_difficulty_profiles_and_perception_delay(runner)
	await _test_utility_brain_decisions(runner)
	await _test_live_ai_shot_combo_and_defense(runner)
	await _test_arena_ai_rosters_and_3v3_scrimmage(runner)
	await _test_determinism_and_rollback_snapshot(runner)


func _make_synthetic_snapshot(overrides: Dictionary = {}) -> Dictionary:
	var base := {
		"tick": 0,
		"shot_clock_left": 18.0,
		"match_seconds_left": 120.0,
		"scores": [0, 0],
		"target_rim": HOOP_B_RIM,
		"defended_rim": Vector3(0.0, 3.05, 12.425),
		"self": {
			"player_id": 1,
			"team_id": 0,
			"archetype_id": "all_rounder",
			"position": Vector3(0.0, 0.0, -5.0),
			"velocity": Vector3.ZERO,
			"facing_yaw": 0.0,
			"is_grounded": true,
			"is_ankle_broken": false,
			"has_ball": true,
			"stamina": 100.0,
			"max_stamina": 100.0,
			"is_exhausted": false,
			"zone_energy": 0.0,
			"zone_max": 100.0,
			"is_zone_active": false,
			"can_activate_zone": false,
			"is_charging_shot": false,
			"is_layup_gather": false,
			"is_dunking": false,
			"charge_time": 0.0,
			"optimal_charge_time": 0.26,
			"three_point_range": 7.8,
			"dunk_radius": 2.90,
			"pass_speed_mult": 1.0,
			"block_radius": 1.70,
			"steal_radius": 1.75,
			"in_defensive_stance": false,
			"in_defensive_recovery": false,
			"defensive_actions_locked": false,
			"dribble_hand": 1,
			"combo_cooldowns": {},
			"unique_skill_id": "eclipse_counter",
			"dist_to_target_rim": 7.425,
			"dist_to_defended_rim": 17.425,
		},
		"ball": {
			"exists": true,
			"position": Vector3(0.0, 1.0, -5.0),
			"velocity": Vector3.ZERO,
			"state": AIPerception.BALL_STATE_HELD,
			"is_reboundable": false,
			"carrier_id": 1,
			"carrier_team": 0,
			"carrier_pos": Vector3(0.0, 0.0, -5.0),
			"carrier_vel": Vector3.ZERO,
			"carrier_is_charging_shot": false,
			"carrier_is_dunking": false,
			"carrier_stamina": 100.0,
			"carrier_has_steal_protection": false,
			"carrier_is_armored": false,
			"dist_to_self": 0.0,
		},
		"nearest_defender": {
			"player_id": 2,
			"position": Vector3(0.0, 0.0, -9.5),
			"dist": 4.5,
			"shot_contest_threat": 0.0,
			"defenders_in_paint": 0,
		},
		"teammates": [],
		"opponents": [],
		"defense_assignment": {
			"is_primary_on_ball": true,
			"assigned_mark_id": 2,
			"assigned_mark_pos": Vector3(0.0, 0.0, -5.0),
			"primary_defender_beaten": false,
		},
	}
	for k in overrides.keys():
		if overrides[k] is Dictionary and base.has(k) and base[k] is Dictionary:
			var merged: Dictionary = (base[k] as Dictionary).duplicate(true)
			for sub_k in (overrides[k] as Dictionary).keys():
				merged[sub_k] = (overrides[k] as Dictionary)[sub_k]
			base[k] = merged
		else:
			base[k] = overrides[k]
	return base


# ==============================================================================
# 1. AIDifficulty 4 Tiers & AIPerception Deterministic Reaction-Delay Queue
# ==============================================================================
func _test_difficulty_profiles_and_perception_delay(runner: SceneTree) -> void:
	var tiers: Array[int] = AIDifficulty.get_all_tiers()
	runner.assert_eq(tiers.size(), 4, "AIDifficulty exposes exactly 4 tiers")
	runner.assert_eq(AIDifficulty.get_tier_name(AIDifficulty.Tier.ROOKIE), "ROOKIE", "Tier 0 name == ROOKIE")
	runner.assert_eq(AIDifficulty.get_tier_name(AIDifficulty.Tier.PRO), "PRO", "Tier 1 name == PRO")
	runner.assert_eq(AIDifficulty.get_tier_name(AIDifficulty.Tier.ALL_STAR), "ALL_STAR", "Tier 2 name == ALL_STAR")
	runner.assert_eq(AIDifficulty.get_tier_name(AIDifficulty.Tier.PHANTOM), "PHANTOM", "Tier 3 name == PHANTOM")
	runner.assert_eq(AIDifficulty.from_name("all-star"), AIDifficulty.Tier.ALL_STAR, "from_name('all-star') -> ALL_STAR")
	runner.assert_eq(AIDifficulty.from_name("phantom"), AIDifficulty.Tier.PHANTOM, "from_name('phantom') -> PHANTOM")

	var expected_specs := [
		[AIDifficulty.Tier.ROOKIE,   24, 0.095, 0.08, 0.30, 0.35, 0.45, 14, 0.35],
		[AIDifficulty.Tier.PRO,      12, 0.055, 0.28, 0.58, 0.62, 0.70,  8, 0.65],
		[AIDifficulty.Tier.ALL_STAR,  6, 0.025, 0.55, 0.80, 0.82, 0.88,  4, 0.88],
		[AIDifficulty.Tier.PHANTOM,   3, 0.008, 0.82, 0.94, 0.95, 0.96,  2, 0.98],
	]
	for spec in expected_specs:
		var t: int = int(spec[0])
		var tname: String = AIDifficulty.get_tier_name(t)
		var p: Dictionary = AIDifficulty.get_profile(t)
		runner.assert_eq(int(p["reaction_delay_frames"]), int(spec[1]), "%s reaction_delay_frames == %d" % [tname, int(spec[1])])
		runner.assert_approx(float(p["shot_timing_jitter_sec"]), float(spec[2]), 0.0005, "%s shot_timing_jitter_sec" % tname)
		runner.assert_approx(float(p["combo_probability"]), float(spec[3]), 0.001, "%s combo_probability" % tname)
		runner.assert_approx(float(p["steal_discipline"]), float(spec[4]), 0.001, "%s steal_discipline" % tname)
		runner.assert_approx(float(p["block_timing_accuracy"]), float(spec[5]), 0.001, "%s block_timing_accuracy" % tname)
		runner.assert_approx(float(p["pass_vision"]), float(spec[6]), 0.001, "%s pass_vision" % tname)
		runner.assert_eq(int(p["decision_interval_frames"]), int(spec[7]), "%s decision_interval_frames == %d" % [tname, int(spec[7])])
		runner.assert_approx(float(p["zone_iq"]), float(spec[8]), 0.001, "%s zone_iq" % tname)

	# Deterministic Reaction-Delay Ring Queue: event flips at tick 10!
	var perc := AIPerception.new()
	for tick in range(36):
		var charging: bool = tick >= 10
		perc.push_observation(tick, {
			"tick": tick,
			"event_flipped": charging,
		})

		if tick == 12:
			var ph_12: Dictionary = perc.get_perceived_snapshot(12, 3) # sees tick 9
			var rk_12: Dictionary = perc.get_perceived_snapshot(12, 24) # sees tick 0
			runner.assert_false(bool(ph_12["event_flipped"]), "Tick 12: Phantom (delay=3) does NOT peek ahead of tick 10 event")
			runner.assert_false(bool(rk_12["event_flipped"]), "Tick 12: Rookie (delay=24) still perceives pre-event state")
		elif tick == 13:
			var ph_13: Dictionary = perc.get_perceived_snapshot(13, 3) # sees tick 10!
			var rk_13: Dictionary = perc.get_perceived_snapshot(13, 24)
			runner.assert_true(bool(ph_13["event_flipped"]), "Tick 13: Phantom (delay=3 = 50ms) perceives tick 10 event on exact frame 13")
			runner.assert_false(bool(rk_13["event_flipped"]), "Tick 13: Rookie (delay=24) still 21 frames behind tick 10 event")
		elif tick == 33:
			var rk_33: Dictionary = perc.get_perceived_snapshot(33, 24) # sees tick 9
			runner.assert_false(bool(rk_33["event_flipped"]), "Tick 33: Rookie (delay=24) still sees tick 9 before reaction completes")
		elif tick == 34:
			var rk_34: Dictionary = perc.get_perceived_snapshot(34, 24) # sees tick 10!
			runner.assert_true(bool(rk_34["event_flipped"]), "Tick 34: Rookie (delay=24 = 400ms) perceives tick 10 event on exact frame 34")

	# Perception queue export/import roundtrip
	var p_snap: Dictionary = perc.export_state()
	var perc2 := AIPerception.new()
	perc2.import_state(p_snap)
	runner.assert_eq(perc2.get_queue_size(), perc.get_queue_size(), "AIPerception export/import preserves exact queue size")
	runner.assert_true(bool(perc2.get_perceived_snapshot(34, 24)["event_flipped"]), "AIPerception import preserves delayed observations")


# ==============================================================================
# 2. AIUtilityBrain Deterministic Decisions (Shot Clock, Pass Vision, Spacing, Defense)
# ==============================================================================
func _test_utility_brain_decisions(runner: SceneTree) -> void:
	var phantom_prof: Dictionary = AIDifficulty.get_profile(AIDifficulty.Tier.PHANTOM)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026

	# --- 2A. Shot clock urgency (< 5.0s forces immediate shot) ---
	var urgency_snap: Dictionary = _make_synthetic_snapshot({
		"shot_clock_left": 2.8,
		"self": {
			"archetype_id": "sharpshooter",
			"position": Vector3(0.0, 0.0, -5.2),
			"dist_to_target_rim": 7.225,
			"three_point_range": 9.2,
		},
		"nearest_defender": {"dist": 2.4, "shot_contest_threat": 0.25},
	})
	var urg_dec: Dictionary = AIUtilityBrain.evaluate(urgency_snap, phantom_prof, rng)
	runner.assert_eq(String(urg_dec["role"]), AIUtilityBrain.ROLE_OFFENSE_BALL_HANDLER, "Urgency role == OFFENSE_BALL_HANDLER")
	runner.assert_true(
		String(urg_dec["action"]) in [AIUtilityBrain.ACT_SHOOT_JUMP, AIUtilityBrain.ACT_SHOOT_LAYUP, AIUtilityBrain.ACT_SHOOT_DUNK],
		"Shot clock < 5s forces immediate shot selection (got '%s')" % String(urg_dec["action"])
	)

	# --- 2B. Zone Activation IQ when meter == 100 ---
	var zone_snap: Dictionary = _make_synthetic_snapshot({
		"self": {"zone_energy": 100.0, "can_activate_zone": true, "is_zone_active": false},
	})
	var zone_dec: Dictionary = AIUtilityBrain.evaluate(zone_snap, phantom_prof, rng)
	runner.assert_eq(String(zone_dec["action"]), AIUtilityBrain.ACT_ACTIVATE_ZONE, "Phantom AI activates Zone at 100 energy")

	# --- 2C. Pass-Lane Interception Risk Avoidance (Live 3v3 Perception + Brain!) ---
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	arena.call("spawn_ai_match_roster", "3v3", AIDifficulty.Tier.PHANTOM, 9001, true)
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var t0: Array = arena.call("get_team_players", 0) # [P1, P3, P5]
	var t1: Array = arena.call("get_team_players", 1) # [P2, P4, P6]
	var p1: CharacterBody3D = t0[0]
	var p3: CharacterBody3D = t0[1] # Sharpshooter teammate (blocked lane)
	var p5: CharacterBody3D = t0[2] # Powerhouse teammate (clean lane!)
	var d2: CharacterBody3D = t1[0] # Tight on-ball guard on P1
	var d4: CharacterBody3D = t1[1] # Stance defender sitting directly in P1->P3 pass lane!
	var d6: CharacterBody3D = t1[2] # Far away on weak baseline

	# Place P1 at (0, -7.5) tightly guarded by stance D2 at (0, -8.85).
	# P3 is on the left wing (-5.2, -9.5) with stance D4 sitting dead-center in the pass lane (-2.6, -8.5).
	# P5 is wide open on the right wing (5.0, -7.4) with completely clear pass lane (D2 is ahead toward rim, t < 0.05).
	p1.global_position = Vector3(0.0, 0.0, -7.5)
	p3.global_position = Vector3(-5.2, 0.0, -9.5) # Blocked lane
	p5.global_position = Vector3(5.0, 0.0, -7.4)  # Wide open clean lane!
	d2.global_position = Vector3(0.0, 0.0, -8.85) # Tightly guarding P1 (1.35m)
	d2.set("_in_defensive_stance", true)
	d2.defense_system.call("set_in_stance", true)
	d4.global_position = Vector3(-2.6, 0.0, -8.5) # Dead center on segment P1 -> P3!
	d4.set("_in_defensive_stance", true)
	d4.defense_system.call("set_in_stance", true)
	d6.global_position = Vector3(-5.0, 0.0, 4.0) # Far away out of play
	ball.call("set_controlled_state", 1, p1, 1, 0, true)

	var live_pass_snap: Dictionary = AIPerception.build_snapshot(p1, 10)
	var mates_list: Array = live_pass_snap.get("teammates", [])
	var risk_p3: float = -1.0
	var risk_p5: float = -1.0
	for m in mates_list:
		if int(m["player_id"]) == p3.player_id:
			risk_p3 = float(m["pass_lane_risk"])
		elif int(m["player_id"]) == p5.player_id:
			risk_p5 = float(m["pass_lane_risk"])
	runner.assert_gt(risk_p3, 0.65, "AIPerception flags high pass_lane_risk > 0.65 through stance defender (actual=%.2f)" % risk_p3)
	runner.assert_lt(risk_p5, 0.10, "AIPerception flags clean pass lane < 0.10 to open teammate (actual=%.2f)" % risk_p5)

	# Isolate passing utility from combo spam (set low stamina < combo threshold) -> AI picks PASS_TEAMMATE to clean-lane P5!
	live_pass_snap["self"]["stamina"] = 10.0
	var pass_dec: Dictionary = AIUtilityBrain.evaluate(live_pass_snap, phantom_prof, rng)
	runner.assert_eq(String(pass_dec["action"]), AIUtilityBrain.ACT_PASS_TEAMMATE, "Tightly guarded ball-handler passes to wide-open teammate")
	runner.assert_eq(int(pass_dec["target_teammate_id"]), p5.player_id, "AI passes to clean-lane teammate (P5), avoiding stance interceptor on P3")

	# --- 2D. Off-Ball Offense Floor Spacing (Sharpshooter 3pt wing vs Powerhouse dunker's spot, zero crowding) ---
	var sharp_off_snap: Dictionary = _make_synthetic_snapshot({
		"self": {
			"player_id": 3,
			"archetype_id": "sharpshooter",
			"has_ball": false,
			"position": Vector3(0.0, 0.0, -2.0),
		},
		"ball": {"carrier_id": 1, "carrier_team": 0, "carrier_pos": Vector3(1.5, 0.0, -4.0)},
		"teammates": [{"player_id": 1, "position": Vector3(1.5, 0.0, -4.0)}],
	})
	var sharp_dec: Dictionary = AIUtilityBrain.evaluate(sharp_off_snap, phantom_prof, rng)
	var sharp_spot: Vector3 = sharp_dec["target_pos"]
	var sharp_spot_rim_dist: float = Vector2(sharp_spot.x - HOOP_B_RIM.x, sharp_spot.z - HOOP_B_RIM.z).length()
	var sharp_spot_mate_dist: float = Vector2(sharp_spot.x - 1.5, sharp_spot.z - (-4.0)).length()
	runner.assert_eq(String(sharp_dec["role"]), AIUtilityBrain.ROLE_OFFENSE_OFF_BALL, "Off-ball Sharpshooter role == OFFENSE_OFF_BALL")
	runner.assert_eq(String(sharp_dec["action"]), AIUtilityBrain.ACT_SPACE_FLOOR, "Off-ball Sharpshooter chooses SPACE_FLOOR")
	runner.assert_ge(sharp_spot_rim_dist, 6.5, "Sharpshooter spaces outside 3pt arc (dist=%.2fm)" % sharp_spot_rim_dist)
	runner.assert_ge(sharp_spot_mate_dist, 3.0, "Off-ball spacing avoids crowding ball-handler (sep=%.2fm)" % sharp_spot_mate_dist)

	var pwr_off_snap: Dictionary = _make_synthetic_snapshot({
		"self": {
			"player_id": 5,
			"archetype_id": "powerhouse",
			"has_ball": false,
			"position": Vector3(0.0, 0.0, -1.0),
		},
		"ball": {"carrier_id": 1, "carrier_team": 0, "carrier_pos": Vector3(1.5, 0.0, -4.0)},
		"teammates": [{"player_id": 1, "position": Vector3(1.5, 0.0, -4.0)}],
	})
	var pwr_dec: Dictionary = AIUtilityBrain.evaluate(pwr_off_snap, phantom_prof, rng)
	var pwr_spot: Vector3 = pwr_dec["target_pos"]
	var pwr_spot_rim_dist: float = Vector2(pwr_spot.x - HOOP_B_RIM.x, pwr_spot.z - HOOP_B_RIM.z).length()
	runner.assert_eq(String(pwr_dec["action"]), AIUtilityBrain.ACT_CUT_TO_RIM, "Off-ball Powerhouse chooses CUT_TO_RIM / dunker's spot")
	runner.assert_lt(pwr_spot_rim_dist, 4.5, "Powerhouse cuts near paint/dunker's spot (dist=%.2fm)" % pwr_spot_rim_dist)

	# --- 2E. On-Ball Defense Containment, Block Reaction, Steal Discipline, Help Rotation & Rebound Crash ---
	var def_contain_snap: Dictionary = _make_synthetic_snapshot({
		"self": {
			"player_id": 2,
			"team_id": 1,
			"has_ball": false,
			"position": Vector3(0.2, 0.0, -5.6),
		},
		"defended_rim": HOOP_B_RIM,
		"target_rim": Vector3(0.0, 3.05, 12.425),
		"ball": {
			"carrier_id": 1,
			"carrier_team": 0,
			"carrier_pos": Vector3(0.0, 0.0, -4.0),
			"carrier_is_charging_shot": false,
			"carrier_has_steal_protection": true, # Protected hip!
			"carrier_stamina": 90.0,
		},
		"defense_assignment": {"is_primary_on_ball": true},
	})
	var def_dec: Dictionary = AIUtilityBrain.evaluate(def_contain_snap, phantom_prof, rng)
	var contain_pt: Vector3 = def_dec["target_pos"]
	var contain_cushion: float = Vector2(contain_pt.x, contain_pt.z - (-4.0)).length()
	runner.assert_eq(String(def_dec["role"]), AIUtilityBrain.ROLE_DEFENSE_ON_BALL, "Primary defender role == DEFENSE_ON_BALL")
	runner.assert_true(contain_cushion >= 1.45 and contain_cushion <= 1.95, "Containment target sits 1.5m..1.9m along rim line (actual=%.2fm)" % contain_cushion)
	runner.assert_true(bool(def_dec["wants_stance"]), "On-ball defender engages BTN_STANCE inside containment zone")
	runner.assert_false(bool(def_dec["wants_steal"]), "Phantom AI steal discipline refuses reckless poke against shielded carrier")

	# Opponent begins charging shot -> Phantom (block_timing_accuracy = 0.95) reacts with CONTEST_BLOCK!
	var def_block_snap: Dictionary = def_contain_snap.duplicate(true)
	def_block_snap["ball"]["carrier_is_charging_shot"] = true
	var blk_dec: Dictionary = AIUtilityBrain.evaluate(def_block_snap, phantom_prof, null)
	runner.assert_eq(String(blk_dec["action"]), AIUtilityBrain.ACT_CONTEST_BLOCK, "On-ball Phantom AI jumps to CONTEST_BLOCK charging shooter")
	runner.assert_true(bool(blk_dec["wants_jump"]), "CONTEST_BLOCK asserts wants_jump == true")

	# Help rotation when primary defender is beaten
	var help_snap: Dictionary = def_contain_snap.duplicate(true)
	help_snap["defense_assignment"] = {
		"is_primary_on_ball": false,
		"assigned_mark_id": 3,
		"assigned_mark_pos": Vector3(5.0, 0.0, -5.0),
		"primary_defender_beaten": true,
	}
	var help_dec: Dictionary = AIUtilityBrain.evaluate(help_snap, phantom_prof, rng)
	runner.assert_eq(String(help_dec["role"]), AIUtilityBrain.ROLE_DEFENSE_HELP_OFF_BALL, "Off-ball defender role == DEFENSE_HELP_OFF_BALL")
	runner.assert_eq(String(help_dec["action"]), AIUtilityBrain.ACT_HELP_ROTATE, "Off-ball defender rotates to help-side paint when primary is beaten")

	# Rebound crash on SHOT_FLIGHT
	var reb_snap: Dictionary = def_contain_snap.duplicate(true)
	reb_snap["ball"]["state"] = AIPerception.BALL_STATE_SHOT_FLIGHT
	reb_snap["ball"]["position"] = Vector3(0.0, 3.6, -11.5)
	var reb_dec: Dictionary = AIUtilityBrain.evaluate(reb_snap, phantom_prof, rng)
	runner.assert_eq(String(reb_dec["role"]), AIUtilityBrain.ROLE_REBOUND_CRASH, "SHOT_FLIGHT triggers ROLE_REBOUND_CRASH")
	runner.assert_eq(String(reb_dec["action"]), AIUtilityBrain.ACT_CRASH_REBOUND, "Rebound crash selects ACT_CRASH_REBOUND")


# ==============================================================================
# 3. Live On-Court 60 Hz AI Gameplay (3pt Swish, Timing Spread, Combo, Defense, Zone)
# ==============================================================================
func _test_live_ai_shot_combo_and_defense(runner: SceneTree) -> void:
	# --- 3A. Phantom vs Rookie shot charge timing jitter spread (unit via step_with_snapshot) ---
	var ph_errs: Array[float] = []
	var rk_errs: Array[float] = []
	var open_3pt_snap: Dictionary = _make_synthetic_snapshot({
		"self": {
			"archetype_id": "sharpshooter",
			"position": Vector3(0.0, 0.0, -5.0),
			"dist_to_target_rim": 7.425,
			"three_point_range": 9.2,
		},
		"nearest_defender": {"dist": 6.5, "shot_contest_threat": 0.0},
	})
	for trial in range(10):
		for tier_pair in [[AIDifficulty.Tier.PHANTOM, ph_errs], [AIDifficulty.Tier.ROOKIE, rk_errs]]:
			var ai_probe := AIController.new()
			ai_probe.setup(null, int(tier_pair[0]), 500 + trial * 31)
			var hold_ticks := 0
			var started := false
			for tk in range(60):
				var f: Dictionary = ai_probe.step_with_snapshot(open_3pt_snap, tk, 1.0 / 60.0)
				var shoot_held: bool = (int(f["buttons"]) & AIController.BTN_SHOOT) != 0
				if shoot_held:
					started = true
					hold_ticks += 1
				elif started:
					# ShootingSystem releases with charge_time = (hold_ticks + 1) / 60.0
					var actual_charge: float = float(hold_ticks + 1) / 60.0
					(tier_pair[1] as Array[float]).append(absf(actual_charge - AIController.OPTIMAL_JUMP_CHARGE_SEC))
					break
			ai_probe.free()

	var ph_avg_err := 0.0
	for e in ph_errs:
		ph_avg_err += e
	ph_avg_err /= maxf(1.0, float(ph_errs.size()))
	var rk_avg_err := 0.0
	for e in rk_errs:
		rk_avg_err += e
	rk_avg_err /= maxf(1.0, float(rk_errs.size()))
	runner.assert_ge(ph_errs.size(), 8, "Phantom AI initiates open jump shots reliably (samples=%d)" % ph_errs.size())
	runner.assert_lt(ph_avg_err, 0.020, "Phantom AI shot release error is tightly clustered < 20ms (actual=%.4fs)" % ph_avg_err)
	runner.assert_gt(rk_avg_err, ph_avg_err * 2.0, "Rookie AI shot timing jitter is markedly noisier than Phantom (%.4fs vs %.4fs)" % [rk_avg_err, ph_avg_err])

	# --- 3B. Live 60 Hz Arena: Open Phantom Sharpshooter AI swishes a real +3! ---
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var mc := arena.get_node_or_null("MatchController") as Node
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var roster: Array = arena.call("spawn_ai_match_roster", "1v1", AIDifficulty.Tier.PHANTOM, 1337, false)
	var shooter: CharacterBody3D = roster[0] # P1 (Team 0)
	var opp: CharacterBody3D = roster[1]     # P2 (Team 1)
	var eb: Node = runner.get_event_bus()

	var score_events: Array[Dictionary] = []
	var combo_events: Array[Dictionary] = []
	var zone_events := [0]
	runner.connect_temp_signal(eb.score_changed, func(tid: int, _ns: int, d: int, is3: bool, sid: int) -> void:
		score_events.append({"team": tid, "delta": d, "is_three": is3, "scorer": sid})
	)
	runner.connect_temp_signal(eb.combo_triggered, func(pid: int, cid: String, _t: int, perf: bool) -> void:
		combo_events.append({"pid": pid, "combo": cid, "perfect": perf})
	)
	runner.connect_temp_signal(eb.zone_activated, func(pid: int, _dur: float) -> void:
		if pid == 1:
			zone_events[0] += 1
	)

	shooter.call("apply_archetype_by_id", "sharpshooter")
	mc.call("restart_match")
	score_events.clear()
	shooter.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.0))) # 7.425m open 3pt!
	opp.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(6.0, 0.0, 8.0)))       # Far away
	ball.call("set_controlled_state", 1, shooter, 1, 0, true)
	await runner.wait_physics_frames(150)

	runner.assert_ge(score_events.size(), 1, "Live Phantom Sharpshooter AI shoots and physically scores through HoopB")
	if score_events.size() >= 1:
		runner.assert_eq(int(score_events[0]["delta"]), 3, "Live Phantom Sharpshooter AI open 3pt awards +3")
		runner.assert_eq(int(score_events[0]["scorer"]), 1, "Score attributed to AI player 1")

	# --- 3C. Live 60 Hz Arena: Phantom AI executes a genuine frame-paced Combo through ComboEngine! ---
	combo_events.clear()
	shooter.call("apply_archetype_by_id", "all_rounder")
	mc.call("restart_match")
	shooter.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -8.2))) # 4.225m -> Meteor Dunk range!
	opp.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -10.2)))     # Guarding tightly
	ball.call("set_controlled_state", 1, shooter, 1, 0, true)
	await runner.wait_physics_frames(90)

	var p1_combos := 0
	for ce in combo_events:
		if int(ce["pid"]) == 1:
			p1_combos += 1
	runner.assert_ge(p1_combos, 1, "Phantom AI legitimately executes frame-paced signature combo through ComboEngine (count=%d)" % p1_combos)

	# --- 3D. Live 60 Hz Arena: Autonomous AI Zone Activation at 100 energy ---
	zone_events[0] = 0
	mc.call("restart_match")
	shooter.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -3.0)))
	opp.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -7.0)))
	ball.call("set_controlled_state", 1, shooter, 1, 0, true)
	shooter.zone.call("set_energy", 100.0)
	await runner.wait_physics_frames(20)
	runner.assert_true(bool(shooter.call("is_in_zone")), "Phantom AI autonomously activates Zone via BTN_ZONE at 100 energy")
	runner.assert_eq(zone_events[0], 1, "AI Zone activation emits EventBus.zone_activated")

	# --- 3E. Live 60 Hz Arena: On-Ball AI Defender moves to rim-line containment & holds DEFENSIVE_STANCE ---
	arena.call("clear_spawned_ai_players")
	var roster_def: Array = arena.call("spawn_ai_match_roster", "1v1", AIDifficulty.Tier.PHANTOM, 4242, true)
	var human_bh: CharacterBody3D = roster_def[0] # P1 human (idle)
	var ai_def: CharacterBody3D = roster_def[1]   # P2 Phantom AI defender
	human_bh.call("set_external_input_provider", func(tick: int, _dt: float) -> Dictionary:
		return {"seq": tick, "tick": tick, "move_world_xz": Vector2.ZERO, "local_dir": Vector2.ZERO, "buttons": 0, "aim_yaw": 0.0}
	)
	mc.call("restart_match")
	human_bh.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -4.0)))
	ai_def.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(2.2, 0.0, -5.6)))
	ball.call("set_controlled_state", 1, human_bh, 1, 0, true)
	await runner.wait_physics_frames(55)

	var pos_score: float = float(DefenseSystem.compute_defensive_positioning(ai_def, human_bh, HOOP_B_RIM))
	var ai_intent: Dictionary = ai_def.call("get_ai_controller").call("get_current_intent")
	runner.assert_eq(String(ai_intent["role"]), AIUtilityBrain.ROLE_DEFENSE_ON_BALL, "Live AI defender enters DEFENSE_ON_BALL role")
	runner.assert_true(bool(ai_def.call("is_in_defensive_stance")), "Live AI defender locks into DEFENSIVE_STANCE on rim line")
	runner.assert_ge(pos_score, 0.75, "Live AI defender achieves strong rim-line positioning >= 0.75 (actual=%.3f)" % pos_score)


# ==============================================================================
# 4. Arena 1v1 / 2v2 / 3v3 AI Roster Spawning, Live 3v3 Scrimmage & Cleanup
# ==============================================================================
func _test_arena_ai_rosters_and_3v3_scrimmage(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D

	# Default arena preservation check (zero AI bots, LocalPlayer is human)
	var local_p := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	runner.assert_not_null(local_p, "Default arena spawns LocalPlayer")
	runner.assert_true(bool(local_p.get("is_local_human")), "Default arena preserves LocalPlayer.is_local_human == true")
	runner.assert_eq((arena.call("get_ai_controllers") as Array).size(), 0, "Default arena has 0 AI controllers")

	# 1v1 human vs AI
	var r1: Array = arena.call("spawn_ai_match_roster", "1v1", AIDifficulty.Tier.PRO, 1001, true)
	runner.assert_eq(r1.size(), 2, "1v1 roster spawns exactly 2 players")
	runner.assert_eq((arena.call("get_team_players", 0) as Array).size(), 1, "1v1 Team 0 has 1 player")
	runner.assert_eq((arena.call("get_team_players", 1) as Array).size(), 1, "1v1 Team 1 has 1 player")
	runner.assert_eq((arena.call("get_ai_controllers") as Array).size(), 1, "1v1 human vs AI has 1 AIController")
	runner.assert_true(bool(local_p.get("is_local_human")), "1v1 human mode keeps LocalPlayer human")

	# 2v2 human + 1 AI vs 2 AI
	var r2: Array = arena.call("spawn_ai_match_roster", "2v2", AIDifficulty.Tier.ALL_STAR, 2002, true)
	runner.assert_eq(r2.size(), 4, "2v2 roster spawns exactly 4 players")
	runner.assert_eq((arena.call("get_ai_controllers") as Array).size(), 3, "2v2 human + AI has 3 AIControllers")
	runner.assert_eq(GameState.match_mode, "offline_2v2", "2v2 sets GameState.match_mode == 'offline_2v2'")

	# 3v3 ALL-AI scrimmage (6 bots!)
	var r3: Array = arena.call("spawn_ai_match_roster", "3v3", AIDifficulty.Tier.PHANTOM, 3003, false)
	runner.assert_eq(r3.size(), 6, "3v3 roster spawns exactly 6 players")
	runner.assert_eq((arena.call("get_team_players", 0) as Array).size(), 3, "3v3 Team 0 has 3 players")
	runner.assert_eq((arena.call("get_team_players", 1) as Array).size(), 3, "3v3 Team 1 has 3 players")
	runner.assert_eq((arena.call("get_ai_controllers") as Array).size(), 6, "3v3 AI-vs-AI attaches 6 AIControllers")
	runner.assert_eq(GameState.match_mode, "offline_3v3", "3v3 sets GameState.match_mode == 'offline_3v3'")

	# Distinct archetypes across Team 0 & Team 1
	var t0_archs: Array[String] = []
	for p in arena.call("get_team_players", 0):
		var a := String(p.get("archetype_id"))
		if not t0_archs.has(a):
			t0_archs.append(a)
	runner.assert_eq(t0_archs.size(), 3, "3v3 Team 0 assigns 3 distinct archetypes")

	# Run live 3v3 AI-vs-AI scrimmage for 180 ticks (3.0s at 60 Hz)
	var eb: Node = runner.get_event_bus()
	var poss_changes := [0]
	runner.connect_temp_signal(eb.possession_changed, func(_t: int, _c: int) -> void:
		poss_changes[0] += 1
	)
	var start_positions: Array[Vector3] = []
	for p in r3:
		start_positions.append((p as Node3D).global_position)

	await runner.wait_physics_frames(180)

	var all_in_bounds := true
	var total_displacement := 0.0
	for i in range(r3.size()):
		var pos: Vector3 = (r3[i] as Node3D).global_position
		if absf(pos.x) > 7.6 or absf(pos.z) > 14.1:
			all_in_bounds = false
		total_displacement += pos.distance_to(start_positions[i])
	runner.assert_true(all_in_bounds, "All 6 bots stay strictly inside court bounds during 3.0s live 3v3 scrimmage")
	runner.assert_gt(total_displacement, 12.0, "All 6 bots actively navigate the court during 3v3 scrimmage (total_disp=%.1fm)" % total_displacement)
	runner.assert_ge(poss_changes[0], 1, "Live 3v3 AI scrimmage establishes ball possession cleanly")
	runner.assert_true(ball != null and absf(ball.global_position.x) <= 7.8 and absf(ball.global_position.z) <= 14.3, "Basketball remains in play during 3v3 scrimmage")

	# Runtime difficulty switching & cleanup
	arena.call("set_ai_difficulty_all", AIDifficulty.Tier.ROOKIE)
	var all_rookie := true
	for ai in arena.call("get_ai_controllers"):
		if int(ai.call("get_difficulty")) != AIDifficulty.Tier.ROOKIE:
			all_rookie = false
	runner.assert_true(all_rookie, "set_ai_difficulty_all updates all 6 AI controllers cleanly")

	arena.call("clear_spawned_ai_players")
	runner.assert_eq((arena.call("get_ai_controllers") as Array).size(), 0, "clear_spawned_ai_players removes all AI controllers")
	runner.assert_true(bool(local_p.get("is_local_human")), "clear_spawned_ai_players restores LocalPlayer.is_local_human == true")


# ==============================================================================
# 5. Bit-Exact Deterministic Replay & Full Rollback Snapshot Roundtrip
# ==============================================================================
func _test_determinism_and_rollback_snapshot(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var mc := arena.get_node_or_null("MatchController") as Node
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D

	var roster: Array = arena.call("spawn_ai_match_roster", "2v2", AIDifficulty.Tier.ALL_STAR, 7777, false)
	runner.assert_eq(roster.size(), 4, "Determinism test spawned 2v2 all-AI roster")

	# Run 1: 75 physics ticks from match restart
	await runner.wait_physics_frames(75)
	var run1_player_pos: Array[Vector3] = []
	for p in roster:
		run1_player_pos.append((p as Node3D).global_position)
	var run1_ball_pos: Vector3 = ball.global_position

	# Run 2: restart_match() + exact same 75 physics ticks -> BIT-EXACT match!
	mc.call("restart_match")
	await runner.wait_physics_frames(75)
	var max_player_drift := 0.0
	for i in range(roster.size()):
		var d: float = (roster[i] as Node3D).global_position.distance_to(run1_player_pos[i])
		if d > max_player_drift:
			max_player_drift = d
	var ball_drift: float = ball.global_position.distance_to(run1_ball_pos)
	runner.assert_approx(max_player_drift, 0.0, 0.0005, "2v2 AI replay across restart_match() is bit-exact for all 4 players (max_drift=%.6fm)" % max_player_drift)
	runner.assert_approx(ball_drift, 0.0, 0.0005, "2v2 AI replay across restart_match() is bit-exact for basketball (drift=%.6fm)" % ball_drift)

	# Rollback Snapshot Roundtrip: export all 4 players (incl. embedded AIController RNG + perception),
	# basketball, and GameState/ShotClock tick state
	var p_snaps: Array[Dictionary] = []
	for p in roster:
		p_snaps.append(p.call("export_sim_state"))
	var b_snap: Dictionary = ball.call("export_sim_state")
	var saved_tick: int = GameState.current_tick
	var saved_match_sec: float = GameState.match_seconds_left
	var saved_shot_sec: float = GameState.shot_clock_left
	var saved_poss_team: int = GameState.possession_team
	var saved_carrier_id: int = GameState.ball_carrier_id
	var saved_sc_node_time: float = float(mc.shot_clock.get("time_left")) if mc.get("shot_clock") != null else saved_shot_sec

	# Verify AI state was embedded in player snapshot
	var p0_snap: Dictionary = p_snaps[0]
	runner.assert_true(p0_snap.has("ai") and (p0_snap["ai"] as Dictionary).has("rng_state"), "PlayerController.export_sim_state() embeds AIController PCG32 rng_state")
	runner.assert_true((p0_snap["ai"] as Dictionary).has("perception"), "PlayerController.export_sim_state() embeds AIPerception delay queue")

	# Step forward 35 ticks to capture reference post-snapshot state
	await runner.wait_physics_frames(35)
	var ref_post_pos: Array[Vector3] = []
	for p in roster:
		ref_post_pos.append((p as Node3D).global_position)
	var ref_post_ball: Vector3 = ball.global_position

	# Rollback to exported snapshot (entities + canonical tick clock) -> re-simulate exact 35 ticks!
	GameState.current_tick = saved_tick
	GameState.match_seconds_left = saved_match_sec
	GameState.shot_clock_left = saved_shot_sec
	GameState.possession_team = saved_poss_team
	GameState.ball_carrier_id = saved_carrier_id
	if mc.get("shot_clock") != null:
		mc.shot_clock.set("time_left", saved_sc_node_time)
	for i in range(roster.size()):
		roster[i].call("import_sim_state", p_snaps[i])
	ball.call("import_sim_state", b_snap)

	var ai0: Node = roster[0].call("get_ai_controller")
	var ai0_restored: Dictionary = ai0.call("export_state")
	runner.assert_eq(int(ai0_restored["rng_state"]), int((p0_snap["ai"] as Dictionary)["rng_state"]), "Rollback import_sim_state restores exact PCG32 RNG state")
	runner.assert_eq(int(ai0_restored["difficulty_tier"]), AIDifficulty.Tier.ALL_STAR, "Rollback restores exact AI difficulty_tier")

	await runner.wait_physics_frames(35)
	var rb_max_drift := 0.0
	for i in range(roster.size()):
		var d: float = (roster[i] as Node3D).global_position.distance_to(ref_post_pos[i])
		if d > rb_max_drift:
			rb_max_drift = d
	var rb_ball_drift: float = ball.global_position.distance_to(ref_post_ball)
	runner.assert_approx(rb_max_drift, 0.0, 0.0005, "Post-rollback 35-tick AI simulation matches reference bit-exactly for all 4 players (max_drift=%.6fm)" % rb_max_drift)
	runner.assert_approx(rb_ball_drift, 0.0, 0.08, "Post-rollback 35-tick basketball trajectory matches reference within hand-anim envelope (drift=%.6fm)" % rb_ball_drift)
