class_name AIUtilityBrain
extends RefCounted
## Pure deterministic utility + behavior-state brain for PHANTOM COURT ONLINE AI (Phase 7).
## Evaluates 6 canonical roles (LOOSE_BALL_CHASE, OFFENSE_BALL_HANDLER, OFFENSE_OFF_BALL,
## DEFENSE_ON_BALL, DEFENSE_HELP_OFF_BALL, REBOUND_CRASH) and scores offensive, passing,
## spacing, combo, Zone, and defensive containment actions deterministically from a
## perceived WorldSnapshot, AIDifficulty profile, and seeded RandomNumberGenerator.

# Canonical AI Roles / States
const ROLE_LOOSE_BALL_CHASE := "LOOSE_BALL_CHASE"
const ROLE_OFFENSE_BALL_HANDLER := "OFFENSE_BALL_HANDLER"
const ROLE_OFFENSE_OFF_BALL := "OFFENSE_OFF_BALL"
const ROLE_DEFENSE_ON_BALL := "DEFENSE_ON_BALL"
const ROLE_DEFENSE_HELP_OFF_BALL := "DEFENSE_HELP_OFF_BALL"
const ROLE_REBOUND_CRASH := "REBOUND_CRASH"

# Canonical AI Actions
const ACT_CHASE_BALL := "CHASE_BALL"
const ACT_SHOOT_JUMP := "SHOOT_JUMP"
const ACT_SHOOT_LAYUP := "SHOOT_LAYUP"
const ACT_SHOOT_DUNK := "SHOOT_DUNK"
const ACT_DRIVE_RIM := "DRIVE_RIM"
const ACT_PASS_TEAMMATE := "PASS_TEAMMATE"
const ACT_DRIBBLE_MOVE := "DRIBBLE_MOVE"
const ACT_EXECUTE_COMBO := "EXECUTE_COMBO"
const ACT_ACTIVATE_ZONE := "ACTIVATE_ZONE"
const ACT_SPACE_FLOOR := "SPACE_FLOOR"
const ACT_CUT_TO_RIM := "CUT_TO_RIM"
const ACT_DEFEND_ON_BALL := "DEFEND_ON_BALL"
const ACT_CONTEST_BLOCK := "CONTEST_BLOCK"
const ACT_ATTEMPT_STEAL := "ATTEMPT_STEAL"
const ACT_DEFEND_MARK := "DEFEND_MARK"
const ACT_HELP_ROTATE := "HELP_ROTATE"
const ACT_CRASH_REBOUND := "CRASH_REBOUND"

const COURT_CLAMP_X: float = 6.9
const COURT_CLAMP_Z: float = 13.2

const BALL_STATE_FREE: int = 0
const BALL_STATE_HELD: int = 1
const BALL_STATE_DRIBBLING: int = 2
const BALL_STATE_PASS_FLIGHT: int = 3
const BALL_STATE_SHOT_FLIGHT: int = 4
const BALL_STATE_DUNK_LOCKED: int = 5


static func safe_normalize_xz(vec: Vector3, fallback: Vector3 = Vector3(0.0, 0.0, -1.0)) -> Vector3:
	var flat := Vector3(vec.x, 0.0, vec.z)
	if flat.length_squared() > 1e-8:
		return flat.normalized()
	var fb := Vector3(fallback.x, 0.0, fallback.z)
	if fb.length_squared() > 1e-8:
		return fb.normalized()
	return Vector3(0.0, 0.0, -1.0)


static func clamp_to_court(pos: Vector3) -> Vector3:
	return Vector3(
		clampf(pos.x, -COURT_CLAMP_X, COURT_CLAMP_X),
		0.0,
		clampf(pos.z, -COURT_CLAMP_Z, COURT_CLAMP_Z)
	)


static func classify_role(snapshot: Dictionary) -> String:
	var me: Dictionary = snapshot.get("self", {})
	var ball: Dictionary = snapshot.get("ball", {})
	var def_asgn: Dictionary = snapshot.get("defense_assignment", {})

	var b_state: int = int(ball.get("state", BALL_STATE_FREE))
	var b_reboundable: bool = bool(ball.get("is_reboundable", false))
	var carrier_team: int = int(ball.get("carrier_team", -1))
	var my_team: int = int(me.get("team_id", 0))
	var has_ball: bool = bool(me.get("has_ball", false))

	if b_state == BALL_STATE_SHOT_FLIGHT:
		return ROLE_REBOUND_CRASH

	if b_state == BALL_STATE_FREE:
		var b_pos: Vector3 = ball.get("position", Vector3.ZERO)
		if b_reboundable and b_pos.y > 0.85:
			return ROLE_REBOUND_CRASH
		return ROLE_LOOSE_BALL_CHASE

	if has_ball:
		return ROLE_OFFENSE_BALL_HANDLER

	if b_state == BALL_STATE_PASS_FLIGHT:
		if carrier_team == my_team:
			return ROLE_OFFENSE_OFF_BALL
		return ROLE_DEFENSE_HELP_OFF_BALL

	if carrier_team == my_team:
		return ROLE_OFFENSE_OFF_BALL

	if bool(def_asgn.get("is_primary_on_ball", true)):
		return ROLE_DEFENSE_ON_BALL

	return ROLE_DEFENSE_HELP_OFF_BALL


## Evaluates the perceived snapshot deterministically and returns a complete Decision/Intent Dictionary.
static func evaluate(
	snapshot: Dictionary,
	profile: Dictionary,
	rng: RandomNumberGenerator
) -> Dictionary:
	if snapshot.is_empty():
		return _empty_decision(ROLE_LOOSE_BALL_CHASE, ACT_CHASE_BALL, Vector3.ZERO)

	var role: String = classify_role(snapshot)
	match role:
		ROLE_LOOSE_BALL_CHASE:
			return _eval_loose_ball_chase(snapshot)
		ROLE_REBOUND_CRASH:
			return _eval_rebound_crash(snapshot, profile)
		ROLE_OFFENSE_BALL_HANDLER:
			return _eval_offense_ball_handler(snapshot, profile, rng)
		ROLE_OFFENSE_OFF_BALL:
			return _eval_offense_off_ball(snapshot, profile)
		ROLE_DEFENSE_ON_BALL:
			return _eval_defense_on_ball(snapshot, profile, rng)
		ROLE_DEFENSE_HELP_OFF_BALL:
			return _eval_defense_help_off_ball(snapshot, profile)
		_:
			return _eval_loose_ball_chase(snapshot)


# ==============================================================================
# 1. Loose Ball Chase & Rebound Crash
# ==============================================================================

static func _eval_loose_ball_chase(snapshot: Dictionary) -> Dictionary:
	var ball: Dictionary = snapshot.get("ball", {})
	var b_pos: Vector3 = ball.get("position", Vector3.ZERO)
	var b_vel: Vector3 = ball.get("velocity", Vector3.ZERO)
	var dist_ball: float = float(ball.get("dist_to_self", 99.0))
	var lead_target: Vector3 = clamp_to_court(Vector3(b_pos.x + b_vel.x * 0.16, 0.0, b_pos.z + b_vel.z * 0.16))

	return {
		"role": ROLE_LOOSE_BALL_CHASE,
		"action": ACT_CHASE_BALL,
		"target_pos": lead_target,
		"aim_target": b_pos,
		"utility_scores": {ACT_CHASE_BALL: 1.0},
		"wants_sprint": dist_ball > 1.2,
		"wants_stance": false,
		"wants_jump": b_pos.y > 1.65 and dist_ball < 1.85,
		"wants_steal": dist_ball <= 2.15 and b_pos.y <= 1.75,
		"queued_combo_id": "",
		"dribble_move_id": "",
		"target_teammate_id": -1,
		"target_teammate_pos": Vector3.ZERO,
	}


static func _eval_rebound_crash(snapshot: Dictionary, profile: Dictionary) -> Dictionary:
	var ball: Dictionary = snapshot.get("ball", {})
	var b_pos: Vector3 = ball.get("position", Vector3.ZERO)
	var b_vel: Vector3 = ball.get("velocity", Vector3.ZERO)
	var me: Dictionary = snapshot.get("self", {})
	var my_pos: Vector3 = me.get("position", Vector3.ZERO)

	# Predict rebound landing zone near the closer rim
	var target_rim: Vector3 = snapshot.get("target_rim", AIPerception.HOOP_B_RIM)
	var defended_rim: Vector3 = snapshot.get("defended_rim", AIPerception.HOOP_A_RIM)
	var rim_focus: Vector3 = target_rim if _dist_xz(b_pos, target_rim) <= _dist_xz(b_pos, defended_rim) else defended_rim
	var crash_spot: Vector3 = clamp_to_court(Vector3(
		lerpf(b_pos.x, rim_focus.x, 0.35),
		0.0,
		lerpf(b_pos.z, rim_focus.z, 0.35)
	))

	var dist_ball_xz: float = _dist_xz(my_pos, b_pos)
	var dist_crash: float = _dist_xz(my_pos, crash_spot)
	var b_reboundable: bool = bool(ball.get("is_reboundable", false))
	var block_acc: float = float(profile.get("block_timing_accuracy", 0.62))
	var jump_height_ok: bool = b_pos.y >= 1.35 and b_pos.y <= (3.35 if block_acc >= 0.70 else 2.85)
	var wants_jump: bool = (b_reboundable or b_vel.y < 0.25) and dist_ball_xz <= 2.15 and jump_height_ok

	return {
		"role": ROLE_REBOUND_CRASH,
		"action": ACT_CRASH_REBOUND,
		"target_pos": crash_spot,
		"aim_target": b_pos,
		"utility_scores": {ACT_CRASH_REBOUND: 1.0},
		"wants_sprint": dist_crash > 1.1,
		"wants_stance": false,
		"wants_jump": wants_jump,
		"wants_steal": b_reboundable and dist_ball_xz <= 1.8 and b_pos.y <= 1.6,
		"queued_combo_id": "",
		"dribble_move_id": "",
		"target_teammate_id": -1,
		"target_teammate_pos": Vector3.ZERO,
	}


# ==============================================================================
# 2. Offense With Ball (Shot Selection, Passing, Dribble, Combos, Zone)
# ==============================================================================

static func _eval_offense_ball_handler(
	snapshot: Dictionary,
	profile: Dictionary,
	rng: RandomNumberGenerator
) -> Dictionary:
	var me: Dictionary = snapshot.get("self", {})
	var nd: Dictionary = snapshot.get("nearest_defender", {})
	var mates: Array = snapshot.get("teammates", [])
	var target_rim: Vector3 = snapshot.get("target_rim", AIPerception.HOOP_B_RIM)

	var my_pos: Vector3 = me.get("position", Vector3.ZERO)
	var arch_id: String = str(me.get("archetype_id", "all_rounder"))
	var dist_rim: float = float(me.get("dist_to_target_rim", _dist_xz(my_pos, target_rim)))
	var stamina: float = float(me.get("stamina", 100.0))
	var is_zone: bool = bool(me.get("is_zone_active", false))
	var can_zone: bool = bool(me.get("can_activate_zone", false))
	var three_range: float = float(me.get("three_point_range", 7.8)) + (1.0 if is_zone else 0.0)
	var dunk_radius: float = float(me.get("dunk_radius", 2.90))
	var pass_mult: float = float(me.get("pass_speed_mult", 1.0))
	var cooldowns: Dictionary = me.get("combo_cooldowns", {})

	var def_dist: float = float(nd.get("dist", 99.0))
	var contest: float = float(nd.get("shot_contest_threat", 0.0))
	var def_pos: Vector3 = nd.get("position", my_pos + Vector3(0.0, 0.0, -5.0))
	var paint_defs: int = int(nd.get("defenders_in_paint", 0))
	var shot_clock: float = float(snapshot.get("shot_clock_left", 24.0))

	var combo_prob: float = float(profile.get("combo_probability", 0.28))
	var pass_vision: float = float(profile.get("pass_vision", 0.70))
	var zone_iq: float = float(profile.get("zone_iq", 0.65))
	var noise_amp: float = float(profile.get("decision_noise", 0.05))

	var scores: Dictionary = {}

	# A. Zone Activation
	var zone_score: float = 0.0
	if can_zone and not is_zone:
		zone_score = 0.86 + 0.42 * zone_iq
		if rng != null and zone_iq < 0.70:
			zone_score -= rng.randf_range(0.0, (1.0 - zone_iq) * 0.45)
	scores[ACT_ACTIVATE_ZONE] = maxf(0.0, zone_score)

	# B. Dunk Selection
	var dunk_score: float = 0.0
	if dist_rim <= dunk_radius and stamina >= 18.0:
		dunk_score = 0.90 - contest * 0.18
		if dunk_radius >= 3.8:
			dunk_score += 0.18 # Powerhouse paint dominance
		if def_dist > 1.7:
			dunk_score += 0.14
		if shot_clock < 5.0:
			dunk_score += 0.30
	scores[ACT_SHOOT_DUNK] = maxf(0.0, dunk_score)

	# C. Driving Layup Selection
	var layup_score: float = 0.0
	if dist_rim <= 3.40:
		layup_score = 0.76 - contest * 0.28
		if dist_rim <= 2.4:
			layup_score += 0.10
		if shot_clock < 5.0:
			layup_score += 0.28
	scores[ACT_SHOOT_LAYUP] = maxf(0.0, layup_score)

	# D. Jump Shot Selection
	var jump_score: float = 0.0
	var clock_urgent: bool = shot_clock < 5.0
	if dist_rim <= three_range + 0.8:
		var openness: float = clampf((def_dist - 1.35) / 2.25, 0.0, 1.0)
		jump_score = 0.46 + openness * 0.50 - contest * 0.54
		# Archetype range affinity
		if dist_rim >= 6.65 and dist_rim <= three_range:
			if three_range >= 9.0:
				jump_score += 0.22 # Sharpshooter deep 3pt sniper
			elif three_range <= 7.0:
				jump_score -= 0.24 # Powerhouse discourages perimeter threes
			else:
				jump_score += 0.06
		elif dist_rim >= 3.6 and dist_rim < 6.65:
			jump_score += 0.08 # Clean mid-range pull-up
		if is_zone:
			jump_score += 0.08
	elif shot_clock < 2.4:
		jump_score = 0.98 # Desperation buzzer-beater heave!

	if clock_urgent:
		var urgency: float = clampf((5.0 - shot_clock) / 4.2, 0.0, 1.0)
		if dist_rim <= three_range + 2.5:
			jump_score += lerpf(0.32, 0.85, urgency)
		elif shot_clock < 2.2:
			jump_score = maxf(jump_score, 1.10)
	scores[ACT_SHOOT_JUMP] = maxf(0.0, jump_score)

	# E. Drive to Rim
	var drive_score: float = 0.52
	if dist_rim > 3.2:
		drive_score += clampf((dist_rim - 3.2) / 9.0, 0.0, 0.26)
	if paint_defs == 0:
		drive_score += 0.14
	elif paint_defs >= 2:
		drive_score -= 0.16
	if def_dist > 2.3 and dist_rim > three_range:
		drive_score += 0.22 # Walk up into range cleanly
	if arch_id == "speedster" or arch_id == "powerhouse":
		drive_score += 0.08
	if clock_urgent and dist_rim > three_range + 1.5:
		drive_score += 0.40 # Push rapidly into shooting range
	elif clock_urgent and dist_rim <= three_range:
		drive_score -= 0.22 # Don't dribble out the shot clock when already in range!
	scores[ACT_DRIVE_RIM] = maxf(0.0, drive_score)

	# F. Passing Decisions (2v2 / 3v3 with pass-lane interception risk!)
	var best_pass_score: float = 0.0
	var best_mate_id: int = -1
	var best_mate_pos: Vector3 = target_rim

	for mate_var in mates:
		if not (mate_var is Dictionary):
			continue
		var mate: Dictionary = mate_var
		var m_dist_rim: float = float(mate.get("dist_to_target_rim", 10.0))
		var m_opp_dist: float = float(mate.get("nearest_opp_dist", 2.0))
		var lane_risk: float = float(mate.get("pass_lane_risk", 0.0))
		var m_3pt: float = float(mate.get("three_point_range", 7.8))

		var mate_open: float = clampf((m_opp_dist - 1.4) / 2.2, 0.0, 1.0)
		var pos_quality: float = 0.0
		if m_dist_rim <= 3.5:
			pos_quality = 0.26 # Open paint cut / dunker spot
		elif m_dist_rim <= m_3pt:
			pos_quality = 0.22 if m_3pt >= 9.0 else 0.16 # Open shooter

		# Higher pass_vision avoids throwing into stance defenders; also rewards passing out of double-team/tight pressure
		var pressure_bonus: float = 0.24 if (def_dist < 2.25 or contest > 0.45) else 0.0
		var lane_penalty: float = lane_risk * (0.45 + 0.72 * pass_vision)
		var playmaker_bonus: float = 0.10 if pass_mult >= 1.25 else 0.0

		var m_score: float = 0.22 + mate_open * 0.48 + pos_quality + pressure_bonus + playmaker_bonus - lane_penalty
		if clock_urgent and shot_clock < 2.0:
			m_score -= 0.35 # Too late to pass; shoot it!
		if m_score > best_pass_score:
			best_pass_score = m_score
			best_mate_id = int(mate.get("player_id", -1))
			best_mate_pos = mate.get("position", target_rim)

	scores[ACT_PASS_TEAMMATE] = maxf(0.0, best_pass_score)

	# G. Basic Dribble Move
	var dribble_score: float = 0.0
	var chosen_dribble: String = "crossover"
	if def_dist < 2.85 and stamina >= 20.0 and not clock_urgent:
		dribble_score = 0.50 + clampf((2.85 - def_dist) / 2.0, 0.0, 0.20)
		if dist_rim >= 5.0 and dist_rim <= three_range + 0.5 and three_range >= 8.5:
			chosen_dribble = "stepback"
		elif def_dist < 1.7:
			chosen_dribble = "behind_the_back"
		else:
			chosen_dribble = "crossover"
	scores[ACT_DRIBBLE_MOVE] = maxf(0.0, dribble_score)

	# H. Fighting-Game Signature / Archetype Combo Execution
	var combo_pick: String = _pick_best_combo(me, dist_rim, def_dist, is_zone, stamina, cooldowns, mates, arch_id)
	var combo_score: float = 0.0
	if not combo_pick.is_empty():
		var guard_factor: float = 1.0 if def_dist < 2.75 else (0.75 if combo_pick == "meteor_dunk" or combo_pick == "tectonic_slam" or combo_pick == "starlight_high_arc" else 0.45)
		combo_score = (0.28 + 0.72 * combo_prob) * guard_factor
		if combo_pick == "meteor_dunk" or combo_pick == "tectonic_slam":
			combo_score += 0.16 # High-value rim finishers!
		elif combo_pick == "starlight_high_arc" and dist_rim >= 6.8:
			combo_score += 0.14
		if clock_urgent and (combo_pick == "phantom_drive" or combo_pick == "ankle_breaker" or combo_pick == "mirror_step"):
			combo_score -= 0.40 # Don't burn clock on setup combos with < 5s left
	scores[ACT_EXECUTE_COMBO] = maxf(0.0, combo_score)

	# Select highest-utility action with small deterministic tier-scaled noise
	var ordered_actions: Array[String] = [
		ACT_ACTIVATE_ZONE,
		ACT_SHOOT_DUNK,
		ACT_SHOOT_LAYUP,
		ACT_SHOOT_JUMP,
		ACT_PASS_TEAMMATE,
		ACT_EXECUTE_COMBO,
		ACT_DRIVE_RIM,
		ACT_DRIBBLE_MOVE,
	]

	var best_act: String = ACT_DRIVE_RIM
	var best_val: float = -INF
	for act in ordered_actions:
		var base_s: float = float(scores.get(act, 0.0))
		if base_s <= 0.001:
			continue
		var jitter: float = rng.randf_range(-noise_amp, noise_amp) if rng != null else 0.0
		var final_s: float = base_s + jitter
		if final_s > best_val:
			best_val = final_s
			best_act = act

	# Compute movement target & aim target for the chosen action
	var drive_target: Vector3 = _compute_drive_target(my_pos, target_rim, def_pos, def_dist)
	var target_pos: Vector3 = drive_target
	var aim_target: Vector3 = target_rim
	var wants_sprint: bool = (best_act == ACT_DRIVE_RIM or best_act == ACT_SHOOT_DUNK) and stamina > 22.0

	if best_act == ACT_PASS_TEAMMATE and best_mate_id >= 0:
		aim_target = best_mate_pos
		target_pos = my_pos
		wants_sprint = false
	elif best_act == ACT_SHOOT_JUMP:
		target_pos = my_pos
		wants_sprint = false

	return {
		"role": ROLE_OFFENSE_BALL_HANDLER,
		"action": best_act,
		"target_pos": target_pos,
		"aim_target": aim_target,
		"utility_scores": scores,
		"wants_sprint": wants_sprint,
		"wants_stance": false,
		"wants_jump": false,
		"wants_steal": false,
		"queued_combo_id": combo_pick if best_act == ACT_EXECUTE_COMBO else "",
		"dribble_move_id": chosen_dribble if best_act == ACT_DRIBBLE_MOVE else "",
		"target_teammate_id": best_mate_id if best_act == ACT_PASS_TEAMMATE else -1,
		"target_teammate_pos": best_mate_pos if best_act == ACT_PASS_TEAMMATE else Vector3.ZERO,
	}


static func _pick_best_combo(
	me: Dictionary,
	dist_rim: float,
	def_dist: float,
	is_zone: bool,
	stamina: float,
	cooldowns: Dictionary,
	mates: Array,
	arch_id: String
) -> String:
	var stam_mult: float = 0.75 if is_zone else 1.0

	# 1. Powerhouse Tectonic Slam (<= 4.2m / 5.0m EX)
	if arch_id == "powerhouse":
		var tec_max: float = 5.0 if is_zone else 4.2
		if dist_rim <= tec_max and int(cooldowns.get("tectonic_slam", 0)) <= 0 and stamina >= 22.0 * stam_mult:
			return "tectonic_slam"

	# 2. Universal Meteor Dunk (<= 5.5m / 6.5m EX)
	var md_max: float = 6.5 if is_zone else 5.5
	if dist_rim <= md_max and int(cooldowns.get("meteor_dunk", 0)) <= 0 and stamina >= 24.0 * stam_mult:
		return "meteor_dunk"

	# 3. Sharpshooter Starlight High Arc (<= 9.8m / 10.8m EX)
	if arch_id == "sharpshooter":
		var sl_max: float = 10.8 if is_zone else 9.8
		if dist_rim >= 6.4 and dist_rim <= sl_max and int(cooldowns.get("starlight_high_arc", 0)) <= 0 and stamina >= 15.0 * stam_mult:
			return "starlight_high_arc"

	# 4. Playmaker Mirage Thread when an open teammate exists
	if arch_id == "playmaker" and not mates.is_empty():
		if int(cooldowns.get("mirage_thread", 0)) <= 0 and stamina >= 12.0 * stam_mult:
			for m in mates:
				if m is Dictionary and bool((m as Dictionary).get("is_open", false)):
					return "mirage_thread"

	# 5. Speedster Volt Dash when driving past defender
	if arch_id == "speedster":
		if def_dist < 2.8 and int(cooldowns.get("volt_dash", 0)) <= 0 and stamina >= 10.0 * stam_mult:
			return "volt_dash"

	# 6. All-Rounder Eclipse Counter on-ball
	if arch_id == "all_rounder":
		if def_dist < 2.6 and int(cooldowns.get("eclipse_counter", 0)) <= 0 and stamina >= 13.0 * stam_mult:
			return "eclipse_counter"

	# 7. Universal tightly-guarded break moves: Ankle Breaker / Phantom Drive / Mirror Step
	if def_dist < 2.65:
		if int(cooldowns.get("ankle_breaker", 0)) <= 0 and stamina >= 14.0 * stam_mult:
			return "ankle_breaker"
		if int(cooldowns.get("phantom_drive", 0)) <= 0 and stamina >= 16.0 * stam_mult:
			return "phantom_drive"
		if int(cooldowns.get("mirror_step", 0)) <= 0 and stamina >= 14.0 * stam_mult:
			return "mirror_step"

	return ""


static func _compute_drive_target(my_pos: Vector3, target_rim: Vector3, def_pos: Vector3, def_dist: float) -> Vector3:
	var to_rim: Vector3 = safe_normalize_xz(target_rim - my_pos)
	var aim_point: Vector3 = target_rim - to_rim * 1.4
	if def_dist < 3.2:
		var right: Vector3 = safe_normalize_xz(to_rim.cross(Vector3.UP), Vector3(1.0, 0.0, 0.0))
		var def_rel: Vector3 = def_pos - my_pos
		# Curve away from defender's side toward open driving lane
		var evade_sign: float = -1.0 if def_rel.dot(right) >= 0.0 else 1.0
		if absf(my_pos.x + evade_sign * 2.2) > COURT_CLAMP_X:
			evade_sign = -evade_sign
		aim_point = my_pos + to_rim * 3.8 + right * (evade_sign * 1.85)
	return clamp_to_court(aim_point)


# ==============================================================================
# 3. Off-Ball Offense (2v2 / 3v3 Clean Floor Spacing & Rim Cuts)
# ==============================================================================

static func _eval_offense_off_ball(snapshot: Dictionary, _profile: Dictionary) -> Dictionary:
	var me: Dictionary = snapshot.get("self", {})
	var ball: Dictionary = snapshot.get("ball", {})
	var mates: Array = snapshot.get("teammates", [])
	var target_rim: Vector3 = snapshot.get("target_rim", AIPerception.HOOP_B_RIM)

	var my_pos: Vector3 = me.get("position", Vector3.ZERO)
	var my_id: int = int(me.get("player_id", 1))
	var arch_id: String = str(me.get("archetype_id", "all_rounder"))
	var carrier_pos: Vector3 = ball.get("carrier_pos", my_pos)

	# Attack direction from target rim back toward center court (+Z for HoopB, -Z for HoopA)
	var out_z: float = 1.0 if target_rim.z < 0.0 else -1.0
	var weak_side_x: float = -1.0 if carrier_pos.x >= 0.0 else 1.0
	if absf(carrier_pos.x) < 0.8:
		weak_side_x = -1.0 if (my_id % 2 == 0) else 1.0

	var action: String = ACT_SPACE_FLOOR
	var spot: Vector3

	match arch_id:
		"sharpshooter":
			# Stretch floor to open 3pt wing/corner on weak side (~7.4m from rim)
			spot = Vector3(weak_side_x * 5.6, 0.0, target_rim.z + out_z * 5.0)
		"powerhouse":
			# Opposite dunker's spot / rim seal (~2.8m from rim)
			spot = Vector3(weak_side_x * 2.3, 0.0, target_rim.z + out_z * 2.2)
			action = ACT_CUT_TO_RIM
		"speedster":
			# Dynamic backdoor slasher wing / rim cut
			var carrier_dist_rim: float = _dist_xz(carrier_pos, target_rim)
			if carrier_dist_rim > 6.0:
				spot = Vector3(weak_side_x * 2.6, 0.0, target_rim.z + out_z * 3.0)
				action = ACT_CUT_TO_RIM
			else:
				spot = Vector3(weak_side_x * 5.2, 0.0, target_rim.z + out_z * 5.4)
		_:
			# Playmaker / All-Rounder: balanced weak-side wing spacing
			spot = Vector3(weak_side_x * 4.8, 0.0, target_rim.z + out_z * 5.8)

	# Repel cleanly away from teammates so AI never crowds the ball-handler or another teammate
	for mate_var in mates:
		if not (mate_var is Dictionary):
			continue
		var m_pos: Vector3 = (mate_var as Dictionary).get("position", Vector3.ZERO)
		var delta: Vector3 = Vector3(spot.x - m_pos.x, 0.0, spot.z - m_pos.z)
		var d: float = delta.length()
		if d < 3.4:
			var push_dir: Vector3 = safe_normalize_xz(delta, Vector3(weak_side_x, 0.0, out_z))
			spot += push_dir * (3.6 - d)

	spot = clamp_to_court(spot)
	var dist_spot: float = _dist_xz(my_pos, spot)

	return {
		"role": ROLE_OFFENSE_OFF_BALL,
		"action": action,
		"target_pos": spot,
		"aim_target": carrier_pos,
		"utility_scores": {
			ACT_SPACE_FLOOR: 0.85 if action == ACT_SPACE_FLOOR else 0.45,
			ACT_CUT_TO_RIM: 0.85 if action == ACT_CUT_TO_RIM else 0.45,
		},
		"wants_sprint": dist_spot > 2.2,
		"wants_stance": false,
		"wants_jump": false,
		"wants_steal": false,
		"queued_combo_id": "",
		"dribble_move_id": "",
		"target_teammate_id": -1,
		"target_teammate_pos": Vector3.ZERO,
	}


# ==============================================================================
# 4. On-Ball Defense (Rim-Line Cushion, Stance Lock, Blocks, Disciplined Steals)
# ==============================================================================

static func _eval_defense_on_ball(
	snapshot: Dictionary,
	profile: Dictionary,
	rng: RandomNumberGenerator
) -> Dictionary:
	var me: Dictionary = snapshot.get("self", {})
	var ball: Dictionary = snapshot.get("ball", {})
	var defended_rim: Vector3 = snapshot.get("defended_rim", AIPerception.HOOP_A_RIM)

	var my_pos: Vector3 = me.get("position", Vector3.ZERO)
	var arch_id: String = str(me.get("archetype_id", "all_rounder"))
	var stamina: float = float(me.get("stamina", 100.0))
	var block_r: float = float(me.get("block_radius", 1.70))
	var steal_r: float = float(me.get("steal_radius", 1.75))
	var def_locked: bool = bool(me.get("defensive_actions_locked", false))
	var is_zone: bool = bool(me.get("is_zone_active", false))
	var can_zone: bool = bool(me.get("can_activate_zone", false))
	var cooldowns: Dictionary = me.get("combo_cooldowns", {})

	var carrier_pos: Vector3 = ball.get("carrier_pos", ball.get("position", Vector3.ZERO))
	var carrier_charging: bool = bool(ball.get("carrier_is_charging_shot", false))
	var carrier_dunking: bool = bool(ball.get("carrier_is_dunking", false))
	var carrier_stamina: float = float(ball.get("carrier_stamina", 100.0))
	var carrier_protected: bool = bool(ball.get("carrier_has_steal_protection", false))
	var carrier_armored: bool = bool(ball.get("carrier_is_armored", false))

	var steal_disc: float = float(profile.get("steal_discipline", 0.58))
	var block_acc: float = float(profile.get("block_timing_accuracy", 0.62))
	var combo_prob: float = float(profile.get("combo_probability", 0.28))
	var zone_iq: float = float(profile.get("zone_iq", 0.65))

	# Optimal containment point strictly 1.5m..1.9m along ball_handler -> defended_rim vector
	var to_def_rim: Vector3 = safe_normalize_xz(defended_rim - carrier_pos)
	var cushion: float = 1.68
	var dist_carrier_to_rim: float = _dist_xz(carrier_pos, defended_rim)
	if dist_carrier_to_rim > 6.5:
		cushion = 1.55 # Tighter perimeter closeout on shooters
	elif dist_carrier_to_rim < 3.5:
		cushion = 1.50 # Body up in the paint
	var contain_pos: Vector3 = clamp_to_court(carrier_pos + to_def_rim * cushion)

	var dist_to_carrier: float = _dist_xz(my_pos, carrier_pos)
	var dist_to_contain: float = _dist_xz(my_pos, contain_pos)

	var scores: Dictionary = {
		ACT_DEFEND_ON_BALL: 0.72,
		ACT_CONTEST_BLOCK: 0.0,
		ACT_ATTEMPT_STEAL: 0.0,
		ACT_ACTIVATE_ZONE: 0.0,
		ACT_EXECUTE_COMBO: 0.0,
	}

	if can_zone and not is_zone:
		scores[ACT_ACTIVATE_ZONE] = 0.75 + 0.35 * zone_iq

	# Shot Block reaction when opponent is shooting/dunking within reach
	var eff_block_reach: float = (block_r * (1.20 if is_zone else 1.0)) + 1.25
	if (carrier_charging or carrier_dunking) and dist_to_carrier <= eff_block_reach and not def_locked:
		var roll_b: float = rng.randf() if rng != null else 0.5
		if roll_b <= block_acc:
			scores[ACT_CONTEST_BLOCK] = 0.96 + block_acc * 0.20

	# Disciplined Steal evaluation (avoids 24f whiff recovery on high tiers!)
	if not def_locked and stamina >= 15.0:
		if carrier_protected or carrier_armored or dist_to_carrier > steal_r * 1.02:
			# Risky gamble! High-discipline AI refuses; Rookie occasionally reaches recklessly
			var reckless_prob: float = clampf((1.0 - steal_disc) * 0.22, 0.0, 0.20)
			if rng != null and rng.randf() < reckless_prob and dist_to_carrier < steal_r * 1.35:
				scores[ACT_ATTEMPT_STEAL] = 0.76
		else:
			var exposure: float = 0.52
			if carrier_stamina < 35.0:
				exposure += 0.34 # Exhausted dribbler is prime strip target!
			if dist_to_carrier <= steal_r * 0.85:
				exposure += 0.18
			if exposure >= 0.74:
				scores[ACT_ATTEMPT_STEAL] = 0.78 + steal_disc * 0.14

	# All-Rounder off-ball Eclipse Counter defensive closeout!
	var queued_combo: String = ""
	if arch_id == "all_rounder" and dist_to_carrier >= 2.5 and dist_to_carrier <= 5.6 and stamina >= 18.0:
		if int(cooldowns.get("eclipse_counter", 0)) <= 0 and combo_prob >= 0.45:
			scores[ACT_EXECUTE_COMBO] = 0.78 + combo_prob * 0.20
			queued_combo = "eclipse_counter"

	var best_act: String = ACT_DEFEND_ON_BALL
	var best_s: float = -INF
	for act in [ACT_CONTEST_BLOCK, ACT_ACTIVATE_ZONE, ACT_EXECUTE_COMBO, ACT_ATTEMPT_STEAL, ACT_DEFEND_ON_BALL]:
		var s: float = float(scores.get(act, 0.0))
		if s > best_s:
			best_s = s
			best_act = act

	var wants_stance: bool = (dist_to_carrier <= 3.35) and (dist_to_contain <= 2.35) and (best_act != ACT_CONTEST_BLOCK) and (best_act != ACT_EXECUTE_COMBO)
	var wants_sprint: bool = (not wants_stance) and (dist_to_contain > 1.35) and stamina > 22.0

	return {
		"role": ROLE_DEFENSE_ON_BALL,
		"action": best_act,
		"target_pos": contain_pos,
		"aim_target": carrier_pos,
		"utility_scores": scores,
		"wants_sprint": wants_sprint,
		"wants_stance": wants_stance,
		"wants_jump": best_act == ACT_CONTEST_BLOCK,
		"wants_steal": best_act == ACT_ATTEMPT_STEAL,
		"queued_combo_id": queued_combo if best_act == ACT_EXECUTE_COMBO else "",
		"dribble_move_id": "",
		"target_teammate_id": -1,
		"target_teammate_pos": Vector3.ZERO,
	}


# ==============================================================================
# 5. Off-Ball Defense (Mark Shading & Help-Side Paint Rotation)
# ==============================================================================

static func _eval_defense_help_off_ball(snapshot: Dictionary, _profile: Dictionary) -> Dictionary:
	var me: Dictionary = snapshot.get("self", {})
	var ball: Dictionary = snapshot.get("ball", {})
	var def_asgn: Dictionary = snapshot.get("defense_assignment", {})
	var defended_rim: Vector3 = snapshot.get("defended_rim", AIPerception.HOOP_A_RIM)

	var my_pos: Vector3 = me.get("position", Vector3.ZERO)
	var carrier_pos: Vector3 = ball.get("carrier_pos", ball.get("position", Vector3.ZERO))
	var mark_pos: Vector3 = def_asgn.get("assigned_mark_pos", carrier_pos)
	var primary_beaten: bool = bool(def_asgn.get("primary_defender_beaten", false))

	var action: String = ACT_DEFEND_MARK
	var target_pos: Vector3
	var aim_target: Vector3 = carrier_pos

	if primary_beaten:
		# Rotate into help-side paint to stop unobstructed drive to rim!
		action = ACT_HELP_ROTATE
		var to_rim: Vector3 = safe_normalize_xz(defended_rim - carrier_pos)
		target_pos = clamp_to_court(defended_rim - to_rim * 2.0)
	else:
		# Shade between assigned offensive mark and defended rim (30% toward rim, guarding pass lane)
		var mark_to_rim: Vector3 = safe_normalize_xz(defended_rim - mark_pos)
		var mark_rim_dist: float = _dist_xz(mark_pos, defended_rim)
		var shade_dist: float = clampf(mark_rim_dist * 0.30, 1.5, 2.8)
		target_pos = clamp_to_court(mark_pos + mark_to_rim * shade_dist)

	var dist_target: float = _dist_xz(my_pos, target_pos)
	var wants_stance: bool = dist_target <= 2.2
	var wants_sprint: bool = dist_target > 2.4

	return {
		"role": ROLE_DEFENSE_HELP_OFF_BALL,
		"action": action,
		"target_pos": target_pos,
		"aim_target": aim_target,
		"utility_scores": {
			ACT_HELP_ROTATE: 0.92 if primary_beaten else 0.25,
			ACT_DEFEND_MARK: 0.84 if not primary_beaten else 0.40,
		},
		"wants_sprint": wants_sprint,
		"wants_stance": wants_stance,
		"wants_jump": false,
		"wants_steal": false,
		"queued_combo_id": "",
		"dribble_move_id": "",
		"target_teammate_id": -1,
		"target_teammate_pos": Vector3.ZERO,
	}


static func _empty_decision(role: String, action: String, target_pos: Vector3) -> Dictionary:
	return {
		"role": role,
		"action": action,
		"target_pos": target_pos,
		"aim_target": target_pos,
		"utility_scores": {},
		"wants_sprint": false,
		"wants_stance": false,
		"wants_jump": false,
		"wants_steal": false,
		"queued_combo_id": "",
		"dribble_move_id": "",
		"target_teammate_id": -1,
		"target_teammate_pos": Vector3.ZERO,
	}


static func _dist_xz(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)
