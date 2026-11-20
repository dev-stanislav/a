class_name ShootingSystem
extends Node
## Handles Jump Shots (charge meter -> Early, Good, Perfect, Late),
## Driving Layups (<= 3.4m), Rim-Bound Slam Dunks (<= dunk_range_xz),
## Ultimate Meteor Dunk & Powerhouse Tectonic Slam (armored + shockwave),
## Sharpshooter Starlight High Arc, Playmaker Mirage Thread laser pass, and Chest/Lead Passing.

const OPTIMAL_JUMP_CHARGE_SEC: float = 0.26
const AUTO_JUMP_RELEASE_SEC: float = 0.48
const OPTIMAL_LAYUP_CHARGE_SEC: float = 0.18
const AUTO_LAYUP_RELEASE_SEC: float = 0.25

const DUNK_RANGE_XZ: float = 2.90
const LAYUP_RANGE_XZ: float = 3.40

var player: CharacterBody3D = null
var animator: CharacterAnimator = null
var stamina: StaminaComponent = null
var dribble: DribbleSystem = null

var is_charging_shot: bool = false
var is_layup_gather: bool = false
var is_dunking: bool = false
var is_meteor_dunk: bool = false
var is_armored_dunk: bool = false

# Archetype-tunable parameters
var shot_arc_bonus: float = 1.35
var timing_window_scale: float = 1.0
var dunk_range_xz: float = DUNK_RANGE_XZ
var three_point_range: float = 8.20
var pass_speed_mult: float = 1.0
var shot_release_height_offset: float = 0.0

# Telemetry / inspection hooks for HUD, AI, and QA suites
var last_shot_type: String = "jump_shot"
var last_shot_was_ex: bool = false
var last_timing_label: String = ""
var last_timing_quality: float = 0.0
var last_timing_error: float = 0.0
var last_shot_contest: float = 0.0
var last_pass_speed: float = 0.0
var peak_dunk_ball_y: float = 0.0

var _charge_time: float = 0.0
var _shot_origin_floor: Vector3 = Vector3.ZERO
var _target_rim_cached: Vector3 = Vector3(0.0, 3.05, -12.425)

var _dunk_elapsed: float = 0.0
var _dunk_duration: float = 0.26
var _dunk_start_pos: Vector3 = Vector3.ZERO
var _dunk_end_pos: Vector3 = Vector3.ZERO
var _dunk_apex_lift: float = 0.55
var _dunk_power: float = 1.0
var _dunk_shockwave_radius: float = 0.0
var _dunk_balance_damage: float = 65.0
var _shot_counter: int = 0


func setup(
	owner_player: CharacterBody3D,
	char_animator: CharacterAnimator,
	stam: StaminaComponent = null,
	drib: DribbleSystem = null
) -> void:
	player = owner_player
	animator = char_animator
	stamina = stam
	dribble = drib


func cancel_actions() -> void:
	is_charging_shot = false
	is_layup_gather = false
	is_dunking = false
	is_meteor_dunk = false
	is_armored_dunk = false
	_charge_time = 0.0
	_dunk_elapsed = 0.0
	_dunk_apex_lift = 0.55
	_dunk_power = 1.0
	_dunk_shockwave_radius = 0.0
	_dunk_balance_damage = 65.0


func get_charge_time() -> float:
	return _charge_time


func get_optimal_charge_time() -> float:
	return OPTIMAL_LAYUP_CHARGE_SEC if is_layup_gather else OPTIMAL_JUMP_CHARGE_SEC


func begin_meteor_dunk(
	ball: Basketball,
	target_rim: Vector3,
	player_id: int,
	team_id: int,
	params: Dictionary = {},
	potency_mult: float = 1.0
) -> bool:
	if player == null or ball == null or ball.carrier != player:
		return false

	cancel_actions()
	if dribble != null:
		dribble.cancel_active_move()
		dribble.steal_shield_timer = maxf(dribble.steal_shield_timer, 0.65)

	_target_rim_cached = target_rim
	_shot_origin_floor = Vector3(player.global_position.x, 0.0, player.global_position.z)

	var to_rim_xz := Vector3(
		target_rim.x - player.global_position.x,
		0.0,
		target_rim.z - player.global_position.z
	)
	var dir_to_rim: Vector3 = BallTrajectory.safe_normalize_xz(to_rim_xz)

	var shot_kind: String = str(params.get("shot_type", "meteor_dunk"))
	var desired_apex: float = float(params.get("apex_height", 4.15)) * lerpf(1.0, potency_mult, 0.5)
	_dunk_power = float(params.get("dunk_power", 1.5)) * potency_mult
	_dunk_shockwave_radius = float(params.get("shockwave_radius", 3.5)) * potency_mult
	_dunk_balance_damage = float(params.get("balance_damage", 65.0 * float(params.get("dunk_power", 1.5)))) * potency_mult

	var dunk_frames: int = maxi(16, int(params.get("dunk_duration_frames", 28)))
	is_dunking = true
	is_meteor_dunk = true
	is_armored_dunk = bool(params.get("armored", true))
	last_shot_type = shot_kind
	last_shot_was_ex = bool(params.get("is_zone_ex", false))
	peak_dunk_ball_y = 0.0
	_dunk_elapsed = 0.0
	_dunk_duration = float(dunk_frames) / 60.0
	_dunk_start_pos = player.global_position
	_dunk_end_pos = Vector3(target_rim.x, 1.32, target_rim.z) - dir_to_rim * 0.25

	var mid_base_y: float = (_dunk_start_pos.y + _dunk_end_pos.y) * 0.5
	_dunk_apex_lift = maxf(1.30, (desired_apex - 1.35) - mid_base_y)

	ball.set_controlled_state(Basketball.BallState.DUNK_LOCKED, player, player_id, team_id, false)
	if animator != null:
		var anim_name := StringName(shot_kind) if shot_kind == "tectonic_slam" else &"meteor_dunk"
		animator.trigger_action(anim_name, _dunk_duration + 0.16)
	return true


func execute_starlight_high_arc(
	ball: Basketball,
	plan: Dictionary,
	player_id: int,
	team_id: int
) -> bool:
	if player == null or ball == null or ball.carrier != player:
		return false
	if not bool(plan.get("valid", false)):
		return false

	cancel_actions()
	if dribble != null:
		dribble.cancel_active_move()

	_shot_counter += 1
	var fade_vel: Vector3 = plan.get("fade_vel", Vector3.ZERO)
	player.velocity.x = fade_vel.x
	player.velocity.z = fade_vel.z
	player.velocity.y = maxf(player.velocity.y, float(plan.get("jump_impulse", 5.2)))

	var release_pos: Vector3 = plan.get("release_pos", player.global_position + Vector3(0.0, 2.28 + shot_release_height_offset, 0.0))
	var shot_origin_floor: Vector3 = plan.get("shot_origin_floor", Vector3(player.global_position.x, 0.0, player.global_position.z))
	var target_rim: Vector3 = plan.get("face_target", _target_rim_cached)
	var launch_vel: Vector3 = plan.get("launch_velocity", Vector3.ZERO)
	var backspin: Vector3 = plan.get("backspin_omega", Vector3.ZERO)
	var is_three: bool = bool(plan.get("is_three", true))
	var quality: float = float(plan.get("shot_quality", 1.0))
	var label: String = str(plan.get("timing_label", "Perfect"))
	var block_res: float = float(plan.get("block_resistance", 0.18))

	last_shot_type = "starlight_high_arc"
	last_shot_was_ex = bool(plan.get("is_zone_ex", false))
	last_timing_label = label
	last_timing_quality = quality
	last_timing_error = 0.0
	last_shot_contest = DefenseSystem.compute_shot_contest(player, target_rim)

	ball.set_meta("block_resistance", clampf(block_res + 0.35, 0.0, 0.75))
	ball.launch_shot(
		player,
		player_id,
		team_id,
		release_pos,
		shot_origin_floor,
		target_rim,
		launch_vel,
		backspin,
		is_three
	)
	if animator != null:
		animator.trigger_action(&"starlight_high_arc", 0.36)

	EventBus.shot_released.emit(player_id, shot_origin_floor, target_rim, is_three, quality)
	EventBus.shot_timing_feedback.emit(player_id, label, 0.0)
	return true


func execute_mirage_laser_pass(
	ball: Basketball,
	plan: Dictionary,
	player_id: int,
	team_id: int
) -> bool:
	if player == null or ball == null or ball.carrier != player:
		return false
	if not bool(plan.get("valid", false)):
		return false

	cancel_actions()
	if dribble != null:
		dribble.cancel_active_move()

	var mate: Node3D = plan.get("target_teammate", null) as Node3D
	var release_pos: Vector3 = plan.get("release_pos", player.global_position + Vector3(0.0, 1.32, 0.0))
	var pass_vel: Vector3 = plan.get("launch_velocity", Vector3.ZERO)
	last_pass_speed = float(plan.get("pass_speed", pass_vel.length()))

	ball.launch_pass(player, player_id, team_id, release_pos, pass_vel, mate)

	# Grant teammate immediate Mirage Thread Zone charge & catch-and-shoot bonus
	if mate != null:
		var z_grant: float = float(plan.get("teammate_zone_grant", 12.0))
		var s_bonus: float = float(plan.get("teammate_shot_bonus", 0.15))
		var s_dur: float = float(plan.get("teammate_shot_bonus_duration", 1.5))
		var mate_zone: ZoneComponent = mate.get_node_or_null("ZoneComponent") as ZoneComponent
		if mate_zone != null and z_grant > 0.0:
			mate_zone.add_charge(z_grant)
		var mate_drib: DribbleSystem = mate.get_node_or_null("DribbleSystem") as DribbleSystem
		if mate_drib != null and s_bonus > 0.0:
			mate_drib.grant_shot_bonus(s_bonus, s_dur)
		# Credit passer +15.0 Assist / Mirage Thread pass Zone accrual (ignored if passer is in Zone)
		if player != null:
			var passer_zone: ZoneComponent = player.get_node_or_null("ZoneComponent") as ZoneComponent
			if passer_zone != null:
				passer_zone.award_positive_play("assist")

	if animator != null:
		animator.trigger_action(&"mirage_thread", 0.26)
	return true


func begin_shot_or_dunk(
	ball: Basketball,
	target_rim: Vector3,
	player_id: int,
	team_id: int,
	is_sprinting: bool
) -> bool:
	if player == null or ball == null or ball.carrier != player:
		return false
	if is_charging_shot or is_dunking:
		return false

	_target_rim_cached = target_rim
	_shot_origin_floor = Vector3(player.global_position.x, 0.0, player.global_position.z)

	var to_rim_xz := Vector3(
		target_rim.x - player.global_position.x,
		0.0,
		target_rim.z - player.global_position.z
	)
	var dist_xz: float = Vector2(to_rim_xz.x, to_rim_xz.z).length()
	var horiz_speed: float = Vector2(player.velocity.x, player.velocity.z).length()
	var dir_to_rim: Vector3 = BallTrajectory.safe_normalize_xz(to_rim_xz)

	# 1. Rim-Bound Slam Dunk: sprinting inside archetype dunk_range_xz with sufficient stamina
	var can_afford_dunk: bool = (stamina == null) or stamina.has_stamina(StaminaComponent.COST_DUNK)
	if dist_xz <= dunk_range_xz and is_sprinting and can_afford_dunk:
		if stamina != null:
			stamina.consume(StaminaComponent.COST_DUNK, true)
		is_dunking = true
		is_meteor_dunk = false
		is_armored_dunk = false
		last_shot_type = "dunk"
		peak_dunk_ball_y = 0.0
		_dunk_elapsed = 0.0
		_dunk_duration = clampf(dist_xz / 8.2, 0.18, 0.42)
		_dunk_start_pos = player.global_position
		_dunk_end_pos = Vector3(target_rim.x, 1.25, target_rim.z) - dir_to_rim * 0.28
		_dunk_apex_lift = 0.55
		_dunk_power = 1.0
		_dunk_shockwave_radius = 0.0
		_dunk_balance_damage = 0.0

		ball.set_controlled_state(Basketball.BallState.DUNK_LOCKED, player, player_id, team_id, false)
		if animator != null:
			animator.trigger_action(&"dunk", _dunk_duration + 0.12)
		return true

	# 2. Driving Finger-Roll / Bank Layup: moving inside 3.4m of target hoop
	if dist_xz <= LAYUP_RANGE_XZ and horiz_speed > 1.0:
		is_charging_shot = true
		is_layup_gather = true
		last_shot_type = "layup"
		_charge_time = 0.0
		player.velocity.x = dir_to_rim.x * minf(horiz_speed, 4.6)
		player.velocity.z = dir_to_rim.z * minf(horiz_speed, 4.6)
		if player.is_on_floor():
			player.velocity.y = maxf(player.velocity.y, 5.0)
		if animator != null:
			animator.trigger_action(&"layup", 0.30)
		return true

	# 3. Standard Jump Shot Gather
	is_charging_shot = true
	is_layup_gather = false
	last_shot_type = "jump_shot"
	_charge_time = 0.0
	if player.is_on_floor():
		player.velocity.y = maxf(player.velocity.y, 4.5)
		player.velocity.x *= 0.30
		player.velocity.z *= 0.30
	if animator != null:
		animator.trigger_action(&"shoot", 0.36)
	return true


func step_shooting(
	dt: float,
	shoot_held: bool,
	ball: Basketball,
	player_id: int,
	team_id: int,
	zone_bonus: float = 0.0,
	combo_bonus: float = 0.0
) -> bool:
	if player == null:
		return false

	if is_dunking:
		_dunk_elapsed += dt
		var t: float = clampf(_dunk_elapsed / maxf(0.05, _dunk_duration), 0.0, 1.0)
		var arc_pos: Vector3 = _dunk_start_pos.lerp(_dunk_end_pos, t)
		arc_pos.y += sin(t * PI) * _dunk_apex_lift
		var desired_vel: Vector3 = (arc_pos - player.global_position) / maxf(0.008, dt)
		player.velocity = desired_vel
		if ball != null and ball.global_position.y > peak_dunk_ball_y:
			peak_dunk_ball_y = ball.global_position.y

		if _dunk_elapsed >= _dunk_duration:
			var was_meteor: bool = is_meteor_dunk
			var impact_power: float = _dunk_power
			var shock_r: float = _dunk_shockwave_radius
			var shock_bal_dmg: float = _dunk_balance_damage
			is_dunking = false
			is_meteor_dunk = false
			is_armored_dunk = false
			player.velocity = Vector3(0.0, -1.5, 0.0)
			if ball != null and ball.carrier == player:
				last_timing_label = "Perfect"
				last_timing_quality = 1.0
				last_timing_error = 0.0
				last_shot_contest = 0.0
				ball.launch_dunk_drop(player, player_id, team_id, _target_rim_cached, 11.5 if was_meteor else 9.2)
				EventBus.shot_released.emit(player_id, _shot_origin_floor, _target_rim_cached, false, 1.0)
				EventBus.dunk_impact.emit(player_id, _target_rim_cached, impact_power)
				if shock_r > 0.05 and player.has_method("trigger_dunk_shockwave"):
					player.call("trigger_dunk_shockwave", _target_rim_cached, shock_r, impact_power, shock_bal_dmg)
				return true
		return false

	if not is_charging_shot:
		return false

	_charge_time += dt
	var max_hold: float = AUTO_LAYUP_RELEASE_SEC if is_layup_gather else AUTO_JUMP_RELEASE_SEC
	if (not shoot_held) or (_charge_time >= max_hold):
		return _release_charged_shot(ball, player_id, team_id, zone_bonus, combo_bonus)

	return false


func _release_charged_shot(
	ball: Basketball,
	player_id: int,
	team_id: int,
	zone_bonus: float,
	combo_bonus: float = 0.0
) -> bool:
	var was_layup: bool = is_layup_gather
	is_charging_shot = false
	is_layup_gather = false

	if ball == null or ball.carrier != player:
		return false

	_shot_counter += 1
	var contest: float = DefenseSystem.compute_shot_contest(player, _target_rim_cached)
	last_shot_contest = contest

	var dist_xz: float = Vector2(_shot_origin_floor.x, _shot_origin_floor.z).distance_to(
		Vector2(_target_rim_cached.x, _target_rim_cached.z)
	)
	var range_over: float = maxf(0.0, dist_xz - three_point_range) if not was_layup else 0.0
	var range_penalty: float = clampf(range_over * 0.12, 0.0, 0.35)

	var exhaust_pen: float = stamina.get_shot_variance_penalty() if stamina != null else 0.0
	var drib_bonus: float = dribble.get_combo_shot_bonus() if dribble != null else 0.0
	var total_skill_bonus: float = maxf(drib_bonus, combo_bonus)

	var opt_sec: float = OPTIMAL_LAYUP_CHARGE_SEC if was_layup else OPTIMAL_JUMP_CHARGE_SEC
	var timing_error: float = _charge_time - opt_sec
	var abs_err: float = absf(timing_error)

	var base_green: float = (0.068 if was_layup else 0.050) * timing_window_scale
	var exhaust_win_mult: float = 0.72 if exhaust_pen > 0.0 else 1.0
	var green_half_win: float = (
		base_green * lerpf(1.0, 0.45, contest) * exhaust_win_mult
		+ (0.025 if zone_bonus > 0.0 else 0.0)
		+ total_skill_bonus * 0.20
	)
	var good_half_win: float = green_half_win + (0.095 if was_layup else 0.075)

	var label: String = "Good"
	var quality: float = 0.85

	if abs_err <= green_half_win:
		label = "Perfect"
		quality = clampf(1.0 - contest * 0.06 - range_penalty * 0.25, 0.92, 1.0)
	elif abs_err <= good_half_win:
		label = "Good"
		quality = clampf(0.86 - contest * 0.38 - exhaust_pen - range_penalty + zone_bonus + total_skill_bonus, 0.25, 0.96)
	elif timing_error < 0.0:
		label = "Early"
		var early_sev: float = clampf((abs_err - good_half_win) / 0.14, 0.0, 1.0)
		quality = clampf(0.66 - early_sev * 0.28 - contest * 0.35 - exhaust_pen - range_penalty + zone_bonus + total_skill_bonus * 0.5, 0.18, 0.72)
	else:
		label = "Late"
		var late_sev: float = clampf((abs_err - good_half_win) / 0.14, 0.0, 1.0)
		quality = clampf(0.66 - late_sev * 0.28 - contest * 0.35 - exhaust_pen - range_penalty + zone_bonus + total_skill_bonus * 0.5, 0.18, 0.72)

	last_timing_label = label
	last_timing_quality = quality
	last_timing_error = timing_error

	var to_rim_xz := Vector3(
		_target_rim_cached.x - player.global_position.x,
		0.0,
		_target_rim_cached.z - player.global_position.z
	)
	var fwd: Vector3 = BallTrajectory.safe_normalize_xz(to_rim_xz)
	var release_pos: Vector3 = player.global_position + fwd * 0.26 + Vector3(0.0, 1.98 + shot_release_height_offset, 0.0)
	var is_three: bool = (not was_layup) and ((dist_xz > 6.75) or (absf(_shot_origin_floor.x) > 6.60))

	var spin: Vector3 = BallTrajectory.compute_backspin_angular_velocity(
		release_pos,
		_target_rim_cached,
		10.5 if was_layup else 16.5
	)
	var vel: Vector3
	if was_layup:
		vel = BallTrajectory.compute_layup_velocity(
			release_pos,
			_target_rim_cached,
			quality,
			contest,
			player_id * 97 + _shot_counter
		)
	else:
		vel = BallTrajectory.compute_shot_velocity(
			release_pos,
			_target_rim_cached,
			shot_arc_bonus,
			quality,
			player_id * 97 + _shot_counter,
			spin,
			timing_error if label != "Perfect" else 0.0,
			contest if label != "Perfect" else 0.0,
			(exhaust_pen + range_penalty) if label != "Perfect" else 0.0
		)

	ball.set_meta("block_resistance", 0.0)
	ball.launch_shot(
		player,
		player_id,
		team_id,
		release_pos,
		_shot_origin_floor,
		_target_rim_cached,
		vel,
		spin,
		is_three
	)
	if animator != null:
		animator.trigger_action(&"layup" if was_layup else &"shoot", 0.28)

	# Award +10.0 Zone energy for Perfect shot timing (strictly ignored if already in Zone)
	if label == "Perfect" and player != null:
		var shooter_zone: ZoneComponent = player.get_node_or_null("ZoneComponent") as ZoneComponent
		if shooter_zone != null:
			shooter_zone.award_positive_play("perfect_shot")

	EventBus.shot_released.emit(player_id, _shot_origin_floor, _target_rim_cached, is_three, quality)
	EventBus.shot_timing_feedback.emit(player_id, label, timing_error)
	return true


func execute_pass(
	ball: Basketball,
	player_id: int,
	team_id: int,
	aim_forward_xz: Vector3
) -> bool:
	if player == null or ball == null or ball.carrier != player:
		return false
	cancel_actions()

	var fwd: Vector3 = BallTrajectory.safe_normalize_xz(aim_forward_xz)
	var best_teammate: Node3D = _find_best_teammate(team_id, fwd)
	var release_pos: Vector3 = player.global_position + fwd * 0.36 + Vector3(0.0, 1.32, 0.0)

	var target_pos: Vector3 = player.global_position + fwd * 7.5 + Vector3(0.0, 1.25, 0.0)
	var target_vel: Vector3 = Vector3.ZERO
	if best_teammate != null:
		var to_mate: Vector3 = best_teammate.global_position - player.global_position
		var mate_fwd: Vector3 = BallTrajectory.safe_normalize_xz(to_mate)
		release_pos = player.global_position + mate_fwd * 0.36 + Vector3(0.0, 1.32, 0.0)
		target_pos = best_teammate.global_position + Vector3(0.0, 1.25, 0.0)
		if best_teammate is CharacterBody3D:
			target_vel = (best_teammate as CharacterBody3D).velocity

	var eff_pass_speed: float = 15.0 * maxf(0.5, pass_speed_mult)
	last_pass_speed = eff_pass_speed
	var pass_vel: Vector3 = BallTrajectory.compute_pass_velocity(release_pos, target_pos, target_vel, eff_pass_speed)
	ball.launch_pass(player, player_id, team_id, release_pos, pass_vel, best_teammate)
	if animator != null:
		animator.trigger_action(&"shoot", 0.18)
	return true


func export_state() -> Dictionary:
	return {
		"is_charging_shot": is_charging_shot,
		"is_layup_gather": is_layup_gather,
		"is_dunking": is_dunking,
		"is_meteor_dunk": is_meteor_dunk,
		"is_armored_dunk": is_armored_dunk,
		"charge_time": _charge_time,
		"shot_origin_floor": _shot_origin_floor,
		"target_rim_cached": _target_rim_cached,
		"dunk_elapsed": _dunk_elapsed,
		"dunk_duration": _dunk_duration,
		"dunk_start_pos": _dunk_start_pos,
		"dunk_end_pos": _dunk_end_pos,
		"dunk_apex_lift": _dunk_apex_lift,
		"dunk_power": _dunk_power,
		"dunk_shockwave_radius": _dunk_shockwave_radius,
		"dunk_balance_damage": _dunk_balance_damage,
		"shot_counter": _shot_counter,
	}


func import_state(state: Dictionary) -> void:
	is_charging_shot = bool(state.get("is_charging_shot", false))
	is_layup_gather = bool(state.get("is_layup_gather", false))
	is_dunking = bool(state.get("is_dunking", false))
	is_meteor_dunk = bool(state.get("is_meteor_dunk", false))
	is_armored_dunk = bool(state.get("is_armored_dunk", false))
	_charge_time = float(state.get("charge_time", 0.0))
	_shot_origin_floor = state.get("shot_origin_floor", Vector3.ZERO)
	_target_rim_cached = state.get("target_rim_cached", _target_rim_cached)
	_dunk_elapsed = float(state.get("dunk_elapsed", 0.0))
	_dunk_duration = float(state.get("dunk_duration", 0.26))
	_dunk_start_pos = state.get("dunk_start_pos", Vector3.ZERO)
	_dunk_end_pos = state.get("dunk_end_pos", Vector3.ZERO)
	_dunk_apex_lift = float(state.get("dunk_apex_lift", 0.55))
	_dunk_power = float(state.get("dunk_power", 1.0))
	_dunk_shockwave_radius = float(state.get("dunk_shockwave_radius", 0.0))
	_dunk_balance_damage = float(state.get("dunk_balance_damage", 65.0))
	_shot_counter = int(state.get("shot_counter", _shot_counter))


func _find_best_teammate(team_id: int, aim_fwd: Vector3) -> Node3D:
	var tree := player.get_tree()
	if tree == null:
		return null
	var best: Node3D = null
	var best_score: float = -999.0
	for node in tree.get_nodes_in_group("players"):
		if node == player or not (node is Node3D):
			continue
		if node.get("team_id") != team_id:
			continue
		var other := node as Node3D
		var delta: Vector3 = other.global_position - player.global_position
		var flat := Vector3(delta.x, 0.0, delta.z)
		var dist_sq: float = flat.length_squared()
		if dist_sq < 0.25 or dist_sq > 625.0:
			continue
		var dir: Vector3 = flat.normalized()
		var align: float = dir.dot(aim_fwd)
		var score: float = align * 2.0 - sqrt(dist_sq) * 0.04
		if score > best_score:
			best_score = score
			best = other
	return best
