class_name DefenseSystem
extends Node
## Phase 6 Skillful Defense System:
## - Defensive Stance (+25% lateral shuffle accel, instant facing lock, widened shot contest cone,
##   1.15m pass-lane interception reach, +40% balance resistance)
## - Frame-accurate Active Steal (6f STARTUP -> 5f ACTIVE -> 24f WHIFF_RECOVERY at 0.45x speed & action lock)
## - Shot Contesting, Vertical Apex Blocking, and 18f Block-Landing Recovery on baited/missed block jumps
## - Pass Lane Interception (PASS_FLIGHT -> HELD, interceptions_made, possession transfer, +22 Zone)
## - Defensive Positioning Alignment score [0.0..1.0] (optimal 1.3m..2.3m rim-line cushion)
## - All-Rounder Eclipse Counter temporary defense buffs

enum StealPhase {
	IDLE = 0,
	STARTUP = 1,
	ACTIVE = 2,
	WHIFF_RECOVERY = 3,
}

const CONTEST_MAX_RANGE: float = 2.40
const STANCE_CONTEST_MAX_RANGE: float = 2.75

const STANCE_LATERAL_ACCEL_MULT: float = 1.25
const STANCE_BALANCE_RESISTANCE_MULT: float = 1.40
const STANCE_PASS_INTERCEPT_RADIUS: float = 1.15
const MOVING_PASS_INTERCEPT_RADIUS: float = 0.85

const STEAL_STARTUP_FRAMES: int = 6
const STEAL_ACTIVE_FRAMES: int = 5
const STEAL_WHIFF_RECOVERY_FRAMES: int = 24
const STEAL_WHIFF_SPEED_MULT: float = 0.45

const BLOCK_LANDING_RECOVERY_FRAMES: int = 18
const BLOCK_RECOVERY_SPEED_MULT: float = 0.55

const OPTIMAL_CUSHION_MIN: float = 1.30
const OPTIMAL_CUSHION_MAX: float = 2.30

var player: CharacterBody3D = null
var animator: CharacterAnimator = null
var stamina: StaminaComponent = null

var auto_pickup_radius: float = 1.05
var manual_pickup_radius: float = 2.15
var rebound_air_radius: float = 1.75
var pass_catch_radius: float = 1.45
var steal_radius: float = 1.75
var block_radius: float = 1.70

var rebounds_grabbed: int = 0
var steals_made: int = 0
var blocks_made: int = 0
var interceptions_made: int = 0

var steal_phase: StealPhase = StealPhase.IDLE
var steal_phase_frames_left: int = 0
var block_recovery_frames: int = 0
var force_strict_steal_startup: bool = false

var _in_stance: bool = false
var _block_jump_committed: bool = false
var _jump_succeeded_defensively: bool = false

var _steal_cooldown: float = 0.0
var _block_cooldown: float = 0.0

# Phase 4 Eclipse Counter defense buff state
var _defense_buff_timer: float = 0.0
var _steal_radius_bonus: float = 0.0
var _contest_bonus: float = 0.0


func setup(owner_player: CharacterBody3D, char_animator: CharacterAnimator, stam: StaminaComponent = null) -> void:
	player = owner_player
	animator = char_animator
	stamina = stam


# ==============================================================================
# Defensive Stance, Recovery & Steal Phase Public Getters
# ==============================================================================

func set_in_stance(active: bool) -> void:
	_in_stance = active and not is_in_steal_whiff_recovery()


func is_in_stance() -> bool:
	if _in_stance:
		return true
	if player != null and bool(player.get("_in_defensive_stance")):
		return true
	return false


func get_lateral_accel_multiplier() -> float:
	return STANCE_LATERAL_ACCEL_MULT if is_in_stance() else 1.0


func get_stance_balance_resistance() -> float:
	return STANCE_BALANCE_RESISTANCE_MULT if is_in_stance() else 1.0


func get_pass_interception_radius(is_zone_active: bool = false) -> float:
	var base_r: float = STANCE_PASS_INTERCEPT_RADIUS if is_in_stance() else MOVING_PASS_INTERCEPT_RADIUS
	if steal_phase == StealPhase.ACTIVE:
		base_r = maxf(base_r, 1.00)
	if is_zone_active:
		base_r *= 1.15
	return base_r


func get_steal_phase_name() -> String:
	match steal_phase:
		StealPhase.STARTUP:
			return "STARTUP"
		StealPhase.ACTIVE:
			return "ACTIVE"
		StealPhase.WHIFF_RECOVERY:
			return "WHIFF_RECOVERY"
		_:
			return "IDLE"


func is_in_steal_whiff_recovery() -> bool:
	return steal_phase == StealPhase.WHIFF_RECOVERY and steal_phase_frames_left > 0


func is_in_block_recovery() -> bool:
	return block_recovery_frames > 0


func is_in_recovery() -> bool:
	return is_in_steal_whiff_recovery() or is_in_block_recovery()


func get_recovery_frames_remaining() -> int:
	var whiff_f: int = steal_phase_frames_left if steal_phase == StealPhase.WHIFF_RECOVERY else 0
	return maxi(whiff_f, block_recovery_frames)


func get_movement_speed_multiplier() -> float:
	if is_in_steal_whiff_recovery():
		return STEAL_WHIFF_SPEED_MULT
	if is_in_block_recovery():
		return BLOCK_RECOVERY_SPEED_MULT
	return 1.0


func are_defensive_actions_locked() -> bool:
	return steal_phase != StealPhase.IDLE or block_recovery_frames > 0


func on_defensive_jump_started() -> void:
	_block_jump_committed = true
	_jump_succeeded_defensively = false


func on_landed_check_block_recovery() -> void:
	if _block_jump_committed and not _jump_succeeded_defensively:
		block_recovery_frames = maxi(block_recovery_frames, BLOCK_LANDING_RECOVERY_FRAMES)
	_block_jump_committed = false
	_jump_succeeded_defensively = false


func cancel_on_stun() -> void:
	_in_stance = false
	_block_jump_committed = false
	_jump_succeeded_defensively = false
	if steal_phase == StealPhase.STARTUP or steal_phase == StealPhase.ACTIVE:
		steal_phase = StealPhase.IDLE
		steal_phase_frames_left = 0


# ==============================================================================
# Eclipse Counter Buffs & Reset / Deterministic Snapshot
# ==============================================================================

func grant_defense_buff(steal_bonus: float, contest_bonus: float, duration: float = 0.90) -> void:
	_steal_radius_bonus = maxf(_steal_radius_bonus, steal_bonus)
	_contest_bonus = maxf(_contest_bonus, contest_bonus)
	_defense_buff_timer = maxf(_defense_buff_timer, duration)


func has_defense_buff() -> bool:
	return _defense_buff_timer > 0.0


func get_effective_steal_radius() -> float:
	return steal_radius + (_steal_radius_bonus if _defense_buff_timer > 0.0 else 0.0)


func get_contest_bonus() -> float:
	return _contest_bonus if _defense_buff_timer > 0.0 else 0.0


func reset_defense() -> void:
	_in_stance = false
	steal_phase = StealPhase.IDLE
	steal_phase_frames_left = 0
	block_recovery_frames = 0
	_block_jump_committed = false
	_jump_succeeded_defensively = false
	_steal_cooldown = 0.0
	_block_cooldown = 0.0
	_defense_buff_timer = 0.0
	_steal_radius_bonus = 0.0
	_contest_bonus = 0.0


func reset_stats() -> void:
	rebounds_grabbed = 0
	steals_made = 0
	blocks_made = 0
	interceptions_made = 0


func export_state() -> Dictionary:
	return {
		"in_stance": _in_stance,
		"steal_phase": int(steal_phase),
		"steal_phase_frames_left": steal_phase_frames_left,
		"block_recovery_frames": block_recovery_frames,
		"block_jump_committed": _block_jump_committed,
		"jump_succeeded_defensively": _jump_succeeded_defensively,
		"rebounds_grabbed": rebounds_grabbed,
		"steals_made": steals_made,
		"blocks_made": blocks_made,
		"interceptions_made": interceptions_made,
		"steal_cooldown": _steal_cooldown,
		"block_cooldown": _block_cooldown,
		"defense_buff_timer": _defense_buff_timer,
		"steal_radius_bonus": _steal_radius_bonus,
		"contest_bonus": _contest_bonus,
	}


func import_state(state: Dictionary) -> void:
	_in_stance = bool(state.get("in_stance", false))
	steal_phase = int(state.get("steal_phase", int(StealPhase.IDLE))) as StealPhase
	steal_phase_frames_left = int(state.get("steal_phase_frames_left", 0))
	block_recovery_frames = int(state.get("block_recovery_frames", 0))
	_block_jump_committed = bool(state.get("block_jump_committed", false))
	_jump_succeeded_defensively = bool(state.get("jump_succeeded_defensively", false))
	if state.has("rebounds_grabbed"):
		rebounds_grabbed = int(state["rebounds_grabbed"])
	if state.has("steals_made"):
		steals_made = int(state["steals_made"])
	if state.has("blocks_made"):
		blocks_made = int(state["blocks_made"])
	if state.has("interceptions_made"):
		interceptions_made = int(state["interceptions_made"])
	_steal_cooldown = float(state.get("steal_cooldown", 0.0))
	_block_cooldown = float(state.get("block_cooldown", 0.0))
	_defense_buff_timer = float(state.get("defense_buff_timer", 0.0))
	_steal_radius_bonus = float(state.get("steal_radius_bonus", 0.0))
	_contest_bonus = float(state.get("contest_bonus", 0.0))


# ==============================================================================
# Defensive Positioning Alignment [0.0..1.0] & Shot Contest [0.0..1.0]
# ==============================================================================

static func compute_defensive_positioning(
	defender: Node3D,
	ball_handler: Node3D,
	defended_rim: Vector3
) -> float:
	if defender == null or ball_handler == null:
		return 0.0

	var bh_xz := Vector2(ball_handler.global_position.x, ball_handler.global_position.z)
	var def_xz := Vector2(defender.global_position.x, defender.global_position.z)
	var rim_xz := Vector2(defended_rim.x, defended_rim.z)

	var bh_to_rim: Vector2 = rim_xz - bh_xz
	if bh_to_rim.length_squared() <= 0.0001:
		return 0.5
	var axis_to_rim: Vector2 = bh_to_rim.normalized()

	var bh_to_def: Vector2 = def_xz - bh_xz
	var dist: float = bh_to_def.length()
	if dist <= 0.001 or dist > 5.0:
		return 0.0

	var dir_to_def: Vector2 = bh_to_def / dist
	var cos_angle: float = axis_to_rim.dot(dir_to_def)
	if cos_angle <= 0.0:
		return 0.0

	var lat_offset: float = absf(bh_to_def.x * axis_to_rim.y - bh_to_def.y * axis_to_rim.x)
	var angle_factor: float = pow(cos_angle, 1.45)
	var lane_factor: float = clampf(1.0 - (lat_offset / 1.85), 0.0, 1.0)
	var align_score: float = clampf(0.55 * angle_factor + 0.45 * lane_factor, 0.0, 1.0)

	var cushion_score: float = 1.0
	if dist < OPTIMAL_CUSHION_MIN:
		cushion_score = clampf(0.55 + 0.45 * ((dist - 0.45) / maxf(0.01, OPTIMAL_CUSHION_MIN - 0.45)), 0.40, 1.0)
	elif dist > OPTIMAL_CUSHION_MAX:
		cushion_score = clampf(1.0 - ((dist - OPTIMAL_CUSHION_MAX) / 2.35), 0.0, 1.0)

	var facing_factor: float = 1.0
	if defender.get("facing_yaw") != null:
		var def_fy: float = float(defender.get("facing_yaw"))
		var def_fwd := Vector2(-sin(def_fy), -cos(def_fy))
		if def_fwd.length_squared() > 0.0001:
			var face_dot: float = def_fwd.normalized().dot(-dir_to_def)
			facing_factor = clampf(0.75 + 0.25 * maxf(0.0, face_dot), 0.65, 1.0)

	return clampf(align_score * cushion_score * facing_factor, 0.0, 1.0)


static func compute_shot_contest(shooter: Node3D, target_rim: Vector3) -> float:
	if shooter == null or shooter.get_tree() == null:
		return 0.0

	var shooter_pos: Vector3 = shooter.global_position
	var shooter_team: Variant = shooter.get("team_id")
	var to_rim_xz := Vector2(target_rim.x - shooter_pos.x, target_rim.z - shooter_pos.z)
	var dir_to_rim := Vector2(0.0, -1.0)
	if to_rim_xz.length_squared() > 0.0001:
		dir_to_rim = to_rim_xz.normalized()

	var max_contest: float = 0.0
	for node in shooter.get_tree().get_nodes_in_group("players"):
		if node == shooter or not (node is Node3D):
			continue
		if shooter_team != null and node.get("team_id") == shooter_team:
			continue
		var def_node := node as Node3D

		# Ankle-broken defenders yield a completely wide-open look (0.0 contest)
		if def_node.has_method("is_ankle_broken") and bool(def_node.call("is_ankle_broken")):
			continue

		var delta_xz := Vector2(def_node.global_position.x - shooter_pos.x, def_node.global_position.z - shooter_pos.z)
		var dist: float = delta_xz.length()
		var def_sys: DefenseSystem = def_node.get_node_or_null("DefenseSystem") as DefenseSystem
		var in_stance: bool = (
			(def_sys != null and def_sys.is_in_stance())
			or bool(def_node.get("_in_defensive_stance"))
		)
		var extra_contest: float = def_sys.get_contest_bonus() if def_sys != null else 0.0
		var base_range: float = STANCE_CONTEST_MAX_RANGE if in_stance else CONTEST_MAX_RANGE
		var max_r: float = base_range + (0.60 if extra_contest > 0.0 else 0.0)
		if dist >= max_r:
			continue

		var prox: float = clampf(1.0 - (dist / max_r), 0.0, 1.0)
		var dir_to_def: Vector2 = delta_xz / maxf(0.001, dist)
		var cone_dot: float = dir_to_rim.dot(dir_to_def)
		var cone_factor: float = (
			clampf(0.58 + 0.42 * maxf(0.0, cone_dot), 0.48, 1.0)
			if in_stance
			else clampf(0.42 + 0.58 * maxf(0.0, cone_dot), 0.32, 1.0)
		)

		var pos_score: float = compute_defensive_positioning(def_node, shooter, target_rim)
		var hands_jump_bonus: float = extra_contest + 0.14 * pos_score
		if def_node is CharacterBody3D and not (def_node as CharacterBody3D).is_on_floor():
			var height_gain: float = clampf(def_node.global_position.y / 1.1, 0.25, 1.0)
			hands_jump_bonus += 0.34 * height_gain
		if in_stance:
			hands_jump_bonus += 0.22

		var contest_val: float = clampf(prox * cone_factor + prox * hands_jump_bonus, 0.0, 1.0)

		# Baited block-landing recovery or whiffed-steal recovery collapses contest, rewarding pump-fakes/stepbacks!
		if def_sys != null and def_sys.is_in_recovery():
			contest_val *= 0.20

		if contest_val > max_contest:
			max_contest = contest_val

	return max_contest


# ==============================================================================
# 60 Hz Pre-Move Frame Tick & Main Defense Step
# ==============================================================================

func step_pre_move_frames() -> void:
	if block_recovery_frames > 0:
		block_recovery_frames -= 1

	match steal_phase:
		StealPhase.STARTUP:
			if steal_phase_frames_left > 1:
				steal_phase_frames_left -= 1
			else:
				steal_phase = StealPhase.ACTIVE
				steal_phase_frames_left = STEAL_ACTIVE_FRAMES
		StealPhase.ACTIVE:
			if steal_phase_frames_left > 1:
				steal_phase_frames_left -= 1
			else:
				steal_phase = StealPhase.WHIFF_RECOVERY
				steal_phase_frames_left = STEAL_WHIFF_RECOVERY_FRAMES
				_in_stance = false
		StealPhase.WHIFF_RECOVERY:
			if steal_phase_frames_left > 1:
				steal_phase_frames_left -= 1
			else:
				steal_phase = StealPhase.IDLE
				steal_phase_frames_left = 0


func try_intercept_pass(
	ball: Basketball,
	player_id: int,
	team_id: int,
	is_zone_active: bool = false,
	dt: float = 1.0 / 60.0
) -> bool:
	if player == null or ball == null:
		return false
	if not ball.is_opponent_pass_for_team(team_id):
		return false
	if is_in_recovery():
		return false
	if player.has_method("is_ankle_broken") and bool(player.call("is_ankle_broken")):
		return false

	var intercept_r: float = get_pass_interception_radius(is_zone_active)
	var def_xz := Vector2(player.global_position.x, player.global_position.z)
	var ball_cur_xz := Vector2(ball.global_position.x, ball.global_position.z)
	var ball_prev_pos: Vector3 = ball.global_position - ball.linear_velocity * maxf(0.0, dt)
	var ball_prev_xz := Vector2(ball_prev_pos.x, ball_prev_pos.z)

	var closest_xz: Vector2 = _closest_point_on_segment_2d(def_xz, ball_prev_xz, ball_cur_xz)
	var dist_xz: float = def_xz.distance_to(closest_xz)
	if dist_xz > intercept_r:
		return false

	var airborne: bool = not player.is_on_floor()
	var center_y: float = player.global_position.y + (1.40 if airborne else 1.05)
	var max_dy: float = 1.95 if airborne else 1.65
	if absf(ball.global_position.y - center_y) > max_dy:
		return false

	# Facing check: stance locks facing to ball/lane; otherwise reject only if back is completely turned
	if not is_in_stance() and steal_phase != StealPhase.ACTIVE:
		var def_fwd := _get_defender_forward_xz_2d()
		var to_ball: Vector2 = ball_cur_xz - def_xz
		var facing_ok: bool = true
		if to_ball.length_squared() > 0.0025:
			var dot_ball: float = def_fwd.dot(to_ball.normalized())
			var dot_passer: float = 1.0
			if ball.last_passer_node != null and is_instance_valid(ball.last_passer_node):
				var to_passer := Vector2(
					ball.last_passer_node.global_position.x - def_xz.x,
					ball.last_passer_node.global_position.z - def_xz.y
				)
				if to_passer.length_squared() > 0.0025:
					dot_passer = def_fwd.dot(to_passer.normalized())
			var pass_vel_xz := Vector2(ball.linear_velocity.x, ball.linear_velocity.z)
			var perp_align: float = 0.0
			if pass_vel_xz.length_squared() > 0.01:
				var p_dir: Vector2 = pass_vel_xz.normalized()
				var p_perp := Vector2(-p_dir.y, p_dir.x)
				perp_align = absf(def_fwd.dot(p_perp))
			facing_ok = (dot_ball >= -0.25) or (dot_passer >= -0.25) or (perp_align >= 0.55)
		if not facing_ok:
			return false

	var passer_id: int = ball.last_passer_id if ball.last_passer_id >= 0 else ball.last_touch_player_id
	interceptions_made += 1
	_jump_succeeded_defensively = true
	if steal_phase == StealPhase.STARTUP or steal_phase == StealPhase.ACTIVE:
		steal_phase = StealPhase.IDLE
		steal_phase_frames_left = 0
	if animator != null:
		animator.trigger_action(&"steal", 0.24)
	ball.set_controlled_state(Basketball.BallState.HELD, player, player_id, team_id, true)
	EventBus.steal_performed.emit(player_id, passer_id, ball.global_position)
	return true


func step_defense(
	dt: float,
	ball: Basketball,
	has_ball: bool,
	steal_pressed: bool,
	just_jumped: bool,
	block_action_pressed: bool,
	player_id: int,
	team_id: int,
	manual_pickup_only: bool = false,
	is_zone_active: bool = false,
	defended_rim: Vector3 = Vector3.ZERO
) -> String:
	if _steal_cooldown > 0.0:
		_steal_cooldown = maxf(0.0, _steal_cooldown - dt)
	if _block_cooldown > 0.0:
		_block_cooldown = maxf(0.0, _block_cooldown - dt)
	if _defense_buff_timer > 0.0:
		_defense_buff_timer = maxf(0.0, _defense_buff_timer - dt)
		if _defense_buff_timer <= 0.0:
			_steal_radius_bonus = 0.0
			_contest_bonus = 0.0

	if player == null or ball == null or has_ball:
		return ""
	if player.has_method("is_ankle_broken") and bool(player.call("is_ankle_broken")):
		return ""

	var airborne: bool = not player.is_on_floor()
	var in_rec: bool = is_in_recovery()

	# 1. Airborne / Apex Vertical Shot Block (+20% vertical & radial block reach while in Zone!)
	if not in_rec and _block_cooldown <= 0.0 and (just_jumped or airborne or block_action_pressed):
		if ball.ball_state == Basketball.BallState.SHOT_FLIGHT and ball.last_shooter_team != team_id:
			if ball.linear_velocity.y > -1.8:
				var blk_res: float = clampf(float(ball.get_meta("block_resistance", 0.0)), 0.0, 0.75)
				var zone_blk_mult: float = ZoneComponent.ZONE_BLOCK_REACH_MULT if is_zone_active else 1.0
				var apex_swat_mult: float = 1.12 if (airborne and absf(player.velocity.y) < 3.2) else 1.0
				var eff_block_r: float = block_radius * zone_blk_mult * apex_swat_mult * (1.0 - blk_res)
				var reach_h: float = (2.18 if airborne else 1.85) * zone_blk_mult
				var hand_reach_pos: Vector3 = player.global_position + Vector3(0.0, reach_h, 0.0)
				if hand_reach_pos.distance_to(ball.global_position) <= eff_block_r:
					if stamina == null or stamina.consume(StaminaComponent.COST_BLOCK, true):
						_block_cooldown = 0.60
						blocks_made += 1
						_jump_succeeded_defensively = true
						if animator != null:
							animator.trigger_action(&"block", 0.32)
						var shooter_id: int = ball.last_shooter_id
						var away_xz: Vector3 = BallTrajectory.safe_normalize_xz(
							ball.global_position - ball.last_target_rim
						)
						var swat_vel: Vector3 = away_xz * 7.8 + Vector3(0.0, 2.1, 0.0)
						ball.drop_free(ball.global_position, swat_vel, player)
						EventBus.block_performed.emit(player_id, shooter_id, ball.global_position)
						return "blocked_shot"

	# 2. Opponent Pass Lane Interception (1.15m in DEFENSIVE_STANCE, 0.85m moving/stealing)
	if ball.is_opponent_pass_for_team(team_id):
		if try_intercept_pass(ball, player_id, team_id, is_zone_active, dt):
			return "intercepted_pass"

	# 3. Rebounds, Teammate Pass Reception & Loose-Ball Pickup
	#    (Opponent PASS_FLIGHT is handled strictly by Pass Lane Interception above!)
	if ball.can_be_picked_up_by(player) and not ball.is_opponent_pass_for_team(team_id):
		var reach_xz: float = auto_pickup_radius
		var reach_y: float = 1.65
		var center_y: float = player.global_position.y + 1.00

		if ball.ball_state == Basketball.BallState.PASS_FLIGHT and ball.pass_target_player == player:
			reach_xz = pass_catch_radius
			reach_y = 1.95
		elif steal_pressed or manual_pickup_only:
			reach_xz = manual_pickup_radius

		if airborne:
			var near_apex: bool = absf(player.velocity.y) < 2.8
			var apex_boost: float = 1.25 if near_apex else 1.05
			reach_xz = maxf(reach_xz, rebound_air_radius * apex_boost)
			reach_y = 1.90
			center_y = player.global_position.y + 1.45

		var dx: float = ball.global_position.x - player.global_position.x
		var dz: float = ball.global_position.z - player.global_position.z
		var dy: float = absf(ball.global_position.y - center_y)

		if (dx * dx + dz * dz) <= (reach_xz * reach_xz) and dy <= reach_y:
			var was_rebound: bool = ball.is_reboundable
			if was_rebound or airborne:
				_jump_succeeded_defensively = true
			ball.set_controlled_state(Basketball.BallState.HELD, player, player_id, team_id, true)
			if was_rebound:
				rebounds_grabbed += 1
				return "rebounded"
			return "picked_up"

	# 4. Frame-Accurate Active Steal State Machine (6f STARTUP -> 5f ACTIVE -> 24f WHIFF_RECOVERY)
	if steal_pressed and steal_phase == StealPhase.IDLE and block_recovery_frames <= 0 and _steal_cooldown <= 0.0:
		if stamina == null or stamina.consume(StaminaComponent.COST_STEAL, true):
			steal_phase = StealPhase.STARTUP
			steal_phase_frames_left = STEAL_STARTUP_FRAMES
			if animator != null:
				animator.trigger_action(&"steal", 0.30)
			# Point-blank stationary HELD chest-snatch triggers on Startup Frame #2 (< STEAL_STARTUP_FRAMES)
			return ""

	if steal_phase == StealPhase.STARTUP and not force_strict_steal_startup and steal_phase_frames_left <= (STEAL_STARTUP_FRAMES - 1):
		if _try_point_blank_stationary_held_snatch(ball, player_id, team_id):
			steal_phase = StealPhase.IDLE
			steal_phase_frames_left = 0
			return "stole_ball"

	if steal_phase == StealPhase.ACTIVE:
		if _evaluate_active_steal_poke(ball, player_id, team_id, defended_rim):
			steal_phase = StealPhase.IDLE
			steal_phase_frames_left = 0
			_steal_cooldown = 0.25
			return "stole_ball"

	return ""


func _try_point_blank_stationary_held_snatch(ball: Basketball, player_id: int, team_id: int) -> bool:
	if (
		ball.carrier == null
		or ball.carrier == player
		or ball.carrier_team_id == team_id
		or ball.ball_state != Basketball.BallState.HELD
	):
		return false

	var carrier_node: Node3D = ball.carrier
	if carrier_node.has_method("has_steal_protection") and bool(carrier_node.call("has_steal_protection")):
		return false
	if carrier_node is CharacterBody3D:
		var cv: Vector3 = (carrier_node as CharacterBody3D).velocity
		if Vector2(cv.x, cv.z).length() > 0.15:
			return false

	var target_hand_pos: Vector3 = carrier_node.global_position
	if carrier_node.has_method("get_active_hand_world_position"):
		target_hand_pos = carrier_node.call("get_active_hand_world_position")

	var dist_carrier_xz: float = Vector2(
		carrier_node.global_position.x - player.global_position.x,
		carrier_node.global_position.z - player.global_position.z
	).length()
	var dist_hand_xz: float = Vector2(
		target_hand_pos.x - player.global_position.x,
		target_hand_pos.z - player.global_position.z
	).length()

	if dist_carrier_xz <= 1.06 and dist_hand_xz <= 0.96:
		return _complete_steal_strip(ball, carrier_node, player_id, team_id)
	return false


func _evaluate_active_steal_poke(
	ball: Basketball,
	player_id: int,
	team_id: int,
	defended_rim: Vector3
) -> bool:
	if (
		ball.carrier == null
		or ball.carrier == player
		or ball.carrier_team_id == team_id
		or ball.ball_state == Basketball.BallState.DUNK_LOCKED
	):
		return false

	var carrier_node: Node3D = ball.carrier
	# Poking into protected hip (behind_the_back / spin / off-hand shield) fails -> flows into 24f WHIFF_RECOVERY!
	if carrier_node.has_method("has_steal_protection") and bool(carrier_node.call("has_steal_protection")):
		return false

	var target_hand_pos: Vector3 = carrier_node.global_position
	if carrier_node.has_method("get_active_hand_world_position"):
		target_hand_pos = carrier_node.call("get_active_hand_world_position")

	var dist_carrier_xz: float = Vector2(
		carrier_node.global_position.x - player.global_position.x,
		carrier_node.global_position.z - player.global_position.z
	).length()
	var dist_hand_xz: float = Vector2(
		target_hand_pos.x - player.global_position.x,
		target_hand_pos.z - player.global_position.z
	).length()

	var reach: float = get_effective_steal_radius()

	# Skillful positioning & timing bonuses:
	var rim_ref: Vector3 = defended_rim
	if rim_ref == Vector3.ZERO and carrier_node.has_method("_get_target_rim_position"):
		rim_ref = carrier_node.call("_get_target_rim_position")
	var pos_score: float = compute_defensive_positioning(player, carrier_node, rim_ref)
	if pos_score >= 0.60:
		reach += 0.28 * pos_score

	var carrier_drib: DribbleSystem = carrier_node.get_node_or_null("DribbleSystem") as DribbleSystem
	if carrier_drib != null and carrier_drib.is_exposed_dribble_window():
		reach += 0.32

	var carrier_stam: StaminaComponent = carrier_node.get_node_or_null("StaminaComponent") as StaminaComponent
	if carrier_stam != null and carrier_stam.current_stamina < 25.0:
		reach += 0.25

	# Reaching blindly from behind the ball-handler's back reduces strip reach
	if pos_score < 0.15 and carrier_node.get("facing_yaw") != null:
		var c_fy: float = float(carrier_node.get("facing_yaw"))
		var c_fwd := Vector2(-sin(c_fy), -cos(c_fy))
		var c_to_def := Vector2(
			player.global_position.x - carrier_node.global_position.x,
			player.global_position.z - carrier_node.global_position.z
		)
		if c_to_def.length_squared() > 0.0025 and c_fwd.dot(c_to_def.normalized()) < -0.25:
			reach *= 0.55

	if minf(dist_hand_xz, dist_carrier_xz * 0.94) <= reach:
		return _complete_steal_strip(ball, carrier_node, player_id, team_id)

	return false


func _complete_steal_strip(ball: Basketball, carrier_node: Node3D, player_id: int, team_id: int) -> bool:
	var victim_id: int = ball.carrier_player_id
	if carrier_node.has_method("on_ball_stolen"):
		carrier_node.call("on_ball_stolen")
	steals_made += 1
	ball.set_controlled_state(Basketball.BallState.HELD, player, player_id, team_id, true)
	EventBus.steal_performed.emit(player_id, victim_id, ball.global_position)
	return true


func _get_defender_forward_xz_2d() -> Vector2:
	if player != null and player.get("facing_yaw") != null:
		var fy: float = float(player.get("facing_yaw"))
		var f := Vector2(-sin(fy), -cos(fy))
		if f.length_squared() > 0.0001:
			return f.normalized()
	return Vector2(0.0, -1.0)


static func _closest_point_on_segment_2d(pt: Vector2, seg_a: Vector2, seg_b: Vector2) -> Vector2:
	var ab: Vector2 = seg_b - seg_a
	var len_sq: float = ab.length_squared()
	if len_sq <= 0.000001:
		return seg_a
	var t: float = clampf((pt - seg_a).dot(ab) / len_sq, 0.0, 1.0)
	return seg_a + ab * t
