class_name DribbleSystem
extends Node
## Synchronizes left/right hand dribbling (DribbleHand {LEFT, RIGHT}) between the active
## character hand joint and court floor (y = 0.12m), emits EventBus.ball_bounced on floor touch,
## and executes all 6 canonical dribble moves with physical velocity displacement & hand swaps:
##   1. Left/Right Dribble ("dribble_left" / "dribble_right")
##   2. Crossover ("crossover")
##   3. Behind-the-Back ("behind_the_back")
##   4. Spin Move ("spin")
##   5. Stepback ("stepback")
##   6. Hesitation ("hesitation")

enum DribbleHand {
	LEFT = 0,
	RIGHT = 1,
}

const MOVE_DRIBBLE_LEFT := "dribble_left"
const MOVE_DRIBBLE_RIGHT := "dribble_right"
const MOVE_CROSSOVER := "crossover"
const MOVE_BEHIND_THE_BACK := "behind_the_back"
const MOVE_SPIN := "spin"
const MOVE_STEPBACK := "stepback"
const MOVE_HESITATION := "hesitation"

var player: CharacterBody3D = null
var animator: CharacterAnimator = null

var active_hand: DribbleHand = DribbleHand.RIGHT
var is_right_hand: bool = true:
	get:
		return active_hand == DribbleHand.RIGHT
	set(val):
		active_hand = DribbleHand.RIGHT if val else DribbleHand.LEFT

var last_move_performed: String = ""
var last_cut_dir: Vector3 = Vector3.ZERO
var dribble_speed_scale: float = 1.0
var stepback_gather_timer: float = 0.0
var steal_shield_timer: float = 0.0
var combo_shot_bonus_timer: float = 0.0
var combo_shot_bonus_amount: float = 0.0

var _dribble_phase: float = 0.0
var _bounce_armed: bool = true
var _move_cooldown: float = 0.0
var _behind_wrap_timer: float = 0.0

# Active dribble move velocity trajectory state
var _active_move_name: String = ""
var _move_elapsed: float = 0.0
var _move_duration: float = 0.0
var _move_primary_vel: Vector3 = Vector3.ZERO
var _move_secondary_vel: Vector3 = Vector3.ZERO
var _move_split_time: float = 0.0


func setup(owner_player: CharacterBody3D, char_animator: CharacterAnimator) -> void:
	player = owner_player
	animator = char_animator


func get_dribble_hand() -> DribbleHand:
	return active_hand


func get_dribble_hand_name() -> String:
	return "RIGHT" if active_hand == DribbleHand.RIGHT else "LEFT"


func set_dribble_hand(hand: int) -> void:
	active_hand = DribbleHand.RIGHT if hand != 0 else DribbleHand.LEFT


func swap_hand() -> void:
	active_hand = DribbleHand.LEFT if active_hand == DribbleHand.RIGHT else DribbleHand.RIGHT


func is_move_active() -> bool:
	return _move_elapsed < _move_duration and _move_duration > 0.0


func has_steal_protection() -> bool:
	return steal_shield_timer > 0.0


func is_exposed_dribble_window() -> bool:
	if steal_shield_timer > 0.0:
		return false
	return is_move_active() and (_active_move_name == MOVE_CROSSOVER or _active_move_name == MOVE_HESITATION)


func get_last_cut_direction() -> Vector3:
	return last_cut_dir


func has_stepback_gather_bonus() -> bool:
	return stepback_gather_timer > 0.0 or combo_shot_bonus_timer > 0.0


func get_combo_shot_bonus() -> float:
	if combo_shot_bonus_timer > 0.0:
		return combo_shot_bonus_amount
	if stepback_gather_timer > 0.0:
		return 0.08
	return 0.0


func grant_shot_bonus(amount: float, duration: float = 0.90) -> void:
	combo_shot_bonus_amount = maxf(combo_shot_bonus_amount, amount)
	combo_shot_bonus_timer = maxf(combo_shot_bonus_timer, duration)
	stepback_gather_timer = maxf(stepback_gather_timer, duration)


func can_execute_move(move_name: String) -> bool:
	if player == null:
		return false
	if move_name == MOVE_DRIBBLE_LEFT or move_name == MOVE_DRIBBLE_RIGHT:
		return true
	return _move_cooldown <= 0.0


func cancel_active_move() -> void:
	_move_cooldown = 0.0
	_active_move_name = ""
	_move_elapsed = 0.0
	_move_duration = 0.0
	_move_split_time = 0.0


func start_signature_trajectory(move_id: String, duration: float, vel: Vector3) -> void:
	_move_cooldown = 0.0
	_start_move_trajectory(move_id, duration, vel)


func start_signature_two_stage(
	move_id: String,
	split_t: float,
	vel_stage1: Vector3,
	total_duration: float,
	vel_stage2: Vector3
) -> void:
	_move_cooldown = 0.0
	_start_two_stage_trajectory(move_id, split_t, vel_stage1, total_duration, vel_stage2)


func get_active_move_velocity() -> Vector3:
	if not is_move_active():
		return Vector3.ZERO
	if _move_split_time > 0.0 and _move_elapsed >= _move_split_time:
		return _move_secondary_vel
	return _move_primary_vel


func get_active_hand_world_position() -> Vector3:
	return _get_carrier_hand_pos(active_hand == DribbleHand.RIGHT)


func step_timers(dt: float) -> void:
	if _move_cooldown > 0.0:
		_move_cooldown = maxf(0.0, _move_cooldown - dt)
	if _behind_wrap_timer > 0.0:
		_behind_wrap_timer = maxf(0.0, _behind_wrap_timer - dt)
	if stepback_gather_timer > 0.0:
		stepback_gather_timer = maxf(0.0, stepback_gather_timer - dt)
	if combo_shot_bonus_timer > 0.0:
		combo_shot_bonus_timer = maxf(0.0, combo_shot_bonus_timer - dt)
		if combo_shot_bonus_timer <= 0.0:
			combo_shot_bonus_amount = 0.0
	if steal_shield_timer > 0.0:
		steal_shield_timer = maxf(0.0, steal_shield_timer - dt)
	if is_move_active():
		_move_elapsed += dt
		if _move_elapsed >= _move_duration:
			_active_move_name = ""
			_move_duration = 0.0


func step_dribble(
	dt: float,
	ball: Basketball,
	horiz_speed: float,
	is_grounded: bool,
	is_sprinting: bool,
	player_id: int,
	team_id: int
) -> void:
	if ball == null or player == null:
		return
	if ball.carrier != player:
		return

	var right_side: bool = (active_hand == DribbleHand.RIGHT)

	if ball.ball_state == Basketball.BallState.DUNK_LOCKED:
		var dunk_hand_pos: Vector3 = _get_carrier_hand_pos(true) + Vector3(0.0, 0.24, 0.0)
		ball.update_controlled_transform(dunk_hand_pos)
		return

	var moving_or_skill: bool = (horiz_speed > 0.40 and is_grounded) or is_move_active()
	if stepback_gather_timer > 0.0 and not is_move_active() and horiz_speed < 1.0:
		moving_or_skill = false

	var desired_state: Basketball.BallState = (
		Basketball.BallState.DRIBBLING if moving_or_skill else Basketball.BallState.HELD
	)
	if ball.ball_state != desired_state:
		ball.set_controlled_state(desired_state, player, player_id, team_id)

	var fwd: Vector3 = _get_player_forward_xz()
	var right: Vector3 = _get_player_right_xz()
	var hand_joint: Vector3 = _get_carrier_hand_pos(right_side)
	var hand_sign: float = 1.0 if right_side else -1.0

	if desired_state == Basketball.BallState.HELD:
		_dribble_phase = 0.0
		_bounce_armed = true
		var held_pos: Vector3 = hand_joint.lerp(
			player.global_position + right * (0.28 * hand_sign) + fwd * 0.26 + Vector3(0.0, 1.06, 0.0),
			0.55
		)
		ball.update_controlled_transform(held_pos)
		return

	# Active synchronized oscillation between hand joint and court floor (y = 0.12m)
	var freq: float = (3.35 if (is_sprinting or is_move_active()) else 2.40) * maxf(0.5, dribble_speed_scale)
	_dribble_phase += dt * freq * TAU
	if _dribble_phase >= TAU:
		_dribble_phase -= TAU
		_bounce_armed = true

	# Cosine wave: 0 -> hand (1.0), PI -> floor (0.0), TAU -> hand (1.0)
	var height_alpha: float = 0.5 * (1.0 + cos(_dribble_phase))
	var floor_contact_y: float = maxf(Basketball.BALL_RADIUS, player.global_position.y + Basketball.BALL_RADIUS)
	var top_hand_y: float = maxf(floor_contact_y + 0.45, hand_joint.y)
	var ball_y: float = lerpf(floor_contact_y, top_hand_y, height_alpha)

	# Emit EventBus.ball_bounced once per cycle as the ball kisses the floor at phase ~ PI
	if _bounce_armed and _dribble_phase >= PI * 0.92:
		_bounce_armed = false
		var floor_hit_pos := Vector3(hand_joint.x, floor_contact_y, hand_joint.z)
		var bounce_spd: float = 4.6 if (is_sprinting or is_move_active()) else 3.3
		EventBus.ball_bounced.emit(floor_hit_pos, bounce_spd, "court")

	var z_offset_dir: float = -0.22 if _behind_wrap_timer > 0.0 else 0.18
	var target_xz: Vector3 = hand_joint.lerp(
		player.global_position + right * (0.30 * hand_sign) + fwd * z_offset_dir,
		0.45
	)
	var dribble_world_pos := Vector3(target_xz.x, ball_y, target_xz.z)
	ball.update_controlled_transform(dribble_world_pos, right * (dt * 9.0))

	if animator != null and not is_move_active():
		animator.trigger_action(&"dribble", 0.12, right_side)


func execute_move(
	move_name: String,
	player_id: int,
	speed_scale: float = 1.0,
	is_perfect: bool = false
) -> bool:
	if player == null:
		return false
	if _move_cooldown > 0.0 and move_name != MOVE_DRIBBLE_LEFT and move_name != MOVE_DRIBBLE_RIGHT:
		return false

	var fwd: Vector3 = _get_player_forward_xz()
	var right: Vector3 = _get_player_right_xz()
	var boost: float = speed_scale * (1.12 if is_perfect else 1.0)
	var canonical: String = move_name.strip_edges().to_lower()

	match canonical:
		MOVE_DRIBBLE_LEFT:
			active_hand = DribbleHand.LEFT
			last_move_performed = MOVE_DRIBBLE_LEFT
			if animator != null:
				animator.trigger_action(&"dribble", 0.24, false)
			EventBus.dribble_move_performed.emit(player_id, MOVE_DRIBBLE_LEFT, player.global_position)
			return true

		MOVE_DRIBBLE_RIGHT:
			active_hand = DribbleHand.RIGHT
			last_move_performed = MOVE_DRIBBLE_RIGHT
			if animator != null:
				animator.trigger_action(&"dribble", 0.24, true)
			EventBus.dribble_move_performed.emit(player_id, MOVE_DRIBBLE_RIGHT, player.global_position)
			return true

		MOVE_CROSSOVER, "crossover_q", "crossover_e":
			swap_hand()
			var cut_sign: float = 1.0 if active_hand == DribbleHand.RIGHT else -1.0
			var cut_dir: Vector3 = BallTrajectory.safe_normalize_xz(fwd * 0.62 + right * (0.78 * cut_sign))
			_start_move_trajectory(MOVE_CROSSOVER, 0.22, cut_dir * (10.6 * boost))
			_move_cooldown = 0.20
			if animator != null:
				animator.trigger_action(&"crossover", 0.26, active_hand == DribbleHand.RIGHT)
			EventBus.dribble_move_performed.emit(player_id, MOVE_CROSSOVER, player.global_position)
			return true

		MOVE_BEHIND_THE_BACK:
			swap_hand()
			var wrap_sign: float = 1.0 if active_hand == DribbleHand.RIGHT else -1.0
			var wrap_dir: Vector3 = BallTrajectory.safe_normalize_xz(fwd * 0.52 + right * (0.85 * wrap_sign))
			_behind_wrap_timer = 0.24
			steal_shield_timer = 0.38
			_start_move_trajectory(MOVE_BEHIND_THE_BACK, 0.23, wrap_dir * (10.2 * boost))
			_move_cooldown = 0.22
			if animator != null:
				animator.trigger_action(&"behind_the_back", 0.26, active_hand == DribbleHand.RIGHT)
			EventBus.dribble_move_performed.emit(player_id, MOVE_BEHIND_THE_BACK, player.global_position)
			return true

		MOVE_SPIN:
			var spin_clockwise: bool = (active_hand == DribbleHand.RIGHT)
			swap_hand()
			var spin_side: float = 1.0 if active_hand == DribbleHand.RIGHT else -1.0
			var spin_dir: Vector3 = BallTrajectory.safe_normalize_xz(fwd * 0.86 + right * (0.50 * spin_side))
			steal_shield_timer = 0.34
			_start_move_trajectory(MOVE_SPIN, 0.26, spin_dir * (10.4 * boost))
			_move_cooldown = 0.26
			if animator != null:
				animator.start_spin_360(0.28, spin_clockwise)
			EventBus.dribble_move_performed.emit(player_id, MOVE_SPIN, player.global_position)
			return true

		MOVE_STEPBACK:
			# Sudden backward separation >= 1.6m (-fwd * 9.6 m/s * 0.21s = ~2.0m) + immediate shot gather bonus
			var back_dir: Vector3 = -fwd
			stepback_gather_timer = 0.75
			steal_shield_timer = 0.25
			_start_move_trajectory(MOVE_STEPBACK, 0.21, back_dir * (9.6 * boost))
			_move_cooldown = 0.24
			if animator != null:
				animator.trigger_action(&"stepback", 0.28, active_hand == DribbleHand.RIGHT)
			EventBus.dribble_move_performed.emit(player_id, MOVE_STEPBACK, player.global_position)
			return true

		MOVE_HESITATION:
			# Stutter slowdown (0.10s at 1.8 m/s) -> explosive first-step burst (0.18s at 11.4 m/s)
			var hesi_side: float = 0.22 if active_hand == DribbleHand.RIGHT else -0.22
			var burst_dir: Vector3 = BallTrajectory.safe_normalize_xz(fwd * 0.96 + right * hesi_side)
			_start_two_stage_trajectory(
				MOVE_HESITATION,
				0.10,
				fwd * 1.8,
				0.28,
				burst_dir * (11.4 * boost)
			)
			_move_cooldown = 0.26
			if animator != null:
				animator.trigger_action(&"hesitation", 0.30, active_hand == DribbleHand.RIGHT)
			EventBus.dribble_move_performed.emit(player_id, MOVE_HESITATION, player.global_position)
			return true

	# Generic fallback for future Phase 3 custom combo IDs
	swap_hand()
	var fallback_sign: float = 1.0 if active_hand == DribbleHand.RIGHT else -1.0
	var fallback_dir: Vector3 = BallTrajectory.safe_normalize_xz(fwd * 0.70 + right * (0.70 * fallback_sign))
	_start_move_trajectory(canonical, 0.20, fallback_dir * (9.8 * boost))
	_move_cooldown = 0.20
	if animator != null:
		animator.trigger_action(&"crossover", 0.24, active_hand == DribbleHand.RIGHT)
	EventBus.dribble_move_performed.emit(player_id, canonical, player.global_position)
	return true


func perform_crossover(move_name: String, player_id: int) -> bool:
	return execute_move(move_name, player_id, 1.0, false)


func reset_dribble() -> void:
	active_hand = DribbleHand.RIGHT
	_dribble_phase = 0.0
	_bounce_armed = true
	_move_cooldown = 0.0
	_behind_wrap_timer = 0.0
	stepback_gather_timer = 0.0
	combo_shot_bonus_timer = 0.0
	combo_shot_bonus_amount = 0.0
	steal_shield_timer = 0.0
	last_cut_dir = Vector3.ZERO
	_active_move_name = ""
	_move_elapsed = 0.0
	_move_duration = 0.0


func export_state() -> Dictionary:
	return {
		"active_hand": int(active_hand),
		"dribble_phase": _dribble_phase,
		"move_cooldown": _move_cooldown,
		"stepback_gather_timer": stepback_gather_timer,
		"combo_shot_bonus_timer": combo_shot_bonus_timer,
		"combo_shot_bonus_amount": combo_shot_bonus_amount,
		"steal_shield_timer": steal_shield_timer,
		"last_cut_dir": last_cut_dir,
		"active_move_name": _active_move_name,
		"move_elapsed": _move_elapsed,
		"move_duration": _move_duration,
		"move_primary_vel": _move_primary_vel,
		"move_secondary_vel": _move_secondary_vel,
		"move_split_time": _move_split_time,
	}


func import_state(state: Dictionary) -> void:
	active_hand = int(state.get("active_hand", int(DribbleHand.RIGHT))) as DribbleHand
	_dribble_phase = float(state.get("dribble_phase", 0.0))
	_move_cooldown = float(state.get("move_cooldown", 0.0))
	stepback_gather_timer = float(state.get("stepback_gather_timer", 0.0))
	combo_shot_bonus_timer = float(state.get("combo_shot_bonus_timer", 0.0))
	combo_shot_bonus_amount = float(state.get("combo_shot_bonus_amount", 0.0))
	steal_shield_timer = float(state.get("steal_shield_timer", 0.0))
	last_cut_dir = state.get("last_cut_dir", Vector3.ZERO)
	_active_move_name = str(state.get("active_move_name", ""))
	_move_elapsed = float(state.get("move_elapsed", 0.0))
	_move_duration = float(state.get("move_duration", 0.0))
	_move_primary_vel = state.get("move_primary_vel", Vector3.ZERO)
	_move_secondary_vel = state.get("move_secondary_vel", Vector3.ZERO)
	_move_split_time = float(state.get("move_split_time", 0.0))


func _start_move_trajectory(move_id: String, duration: float, vel: Vector3) -> void:
	last_move_performed = move_id
	if Vector2(vel.x, vel.z).length_squared() > 0.0001:
		last_cut_dir = BallTrajectory.safe_normalize_xz(vel)
	_active_move_name = move_id
	_move_elapsed = 0.0
	_move_duration = duration
	_move_split_time = 0.0
	_move_primary_vel = vel
	_move_secondary_vel = vel
	if player != null:
		player.velocity.x = vel.x
		player.velocity.z = vel.z


func _start_two_stage_trajectory(
	move_id: String,
	split_t: float,
	vel_stage1: Vector3,
	total_duration: float,
	vel_stage2: Vector3
) -> void:
	last_move_performed = move_id
	if Vector2(vel_stage2.x, vel_stage2.z).length_squared() > 0.0001:
		last_cut_dir = BallTrajectory.safe_normalize_xz(vel_stage2)
	elif Vector2(vel_stage1.x, vel_stage1.z).length_squared() > 0.0001:
		last_cut_dir = BallTrajectory.safe_normalize_xz(vel_stage1)
	_active_move_name = move_id
	_move_elapsed = 0.0
	_move_duration = total_duration
	_move_split_time = split_t
	_move_primary_vel = vel_stage1
	_move_secondary_vel = vel_stage2
	if player != null:
		player.velocity.x = vel_stage1.x
		player.velocity.z = vel_stage1.z


func _get_player_forward_xz() -> Vector3:
	if player == null:
		return Vector3(0.0, 0.0, -1.0)
	if player.get("facing_yaw") != null:
		var fy: float = float(player.get("facing_yaw"))
		var f := Vector3(-sin(fy), 0.0, -cos(fy))
		if f.length_squared() > 0.0001:
			return f.normalized()
	return BallTrajectory.safe_normalize_xz(-player.global_transform.basis.z)


func _get_player_right_xz() -> Vector3:
	var fwd: Vector3 = _get_player_forward_xz()
	var r: Vector3 = fwd.cross(Vector3.UP)
	if r.length_squared() > 0.0001:
		return r.normalized()
	return Vector3(1.0, 0.0, 0.0)


func _get_carrier_hand_pos(right_hand: bool) -> Vector3:
	if animator != null:
		return animator.get_hand_world_position(right_hand)
	if player != null:
		return player.global_position + Vector3(0.26 if right_hand else -0.26, 1.12, -0.24)
	return Vector3(0.0, 1.12, 0.0)
