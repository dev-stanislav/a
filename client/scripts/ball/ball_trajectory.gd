class_name BallTrajectory
extends RefCounted
## Deterministic 60 Hz ballistic + aerodynamic + Magnus spin trajectory solver.
## Uses iterative forward-stepped shooting correction so Perfect/Green shots swish
## dead-center through the hollow 0.225m rim despite quadratic air drag and Magnus lift,
## while Early/Late timing, high contest, and exhaustion introduce realistic scatter.

const GRAVITY: float = 9.81
const BALL_RADIUS: float = 0.12
const BALL_MASS: float = 0.62
const AIR_DRAG_COEFF: float = 0.0045
const MAGNUS_COEFF: float = 0.00042
const FIXED_DT: float = 1.0 / 60.0


static func safe_normalize_xz(vec: Vector3) -> Vector3:
	var flat := Vector3(vec.x, 0.0, vec.z)
	if flat.length_squared() > 0.0001:
		return flat.normalized()
	return Vector3(0.0, 0.0, -1.0)


static func safe_normalize(vec: Vector3, fallback: Vector3 = Vector3.FORWARD) -> Vector3:
	if vec.length_squared() > 0.0001:
		return vec.normalized()
	return fallback


static func compute_backspin_angular_velocity(
	origin: Vector3,
	target_rim: Vector3,
	spin_rad_sec: float = 16.0
) -> Vector3:
	var to_rim_xz := Vector3(target_rim.x - origin.x, 0.0, target_rim.z - origin.z)
	if to_rim_xz.length_squared() <= 0.0001:
		return Vector3(spin_rad_sec, 0.0, 0.0)
	var dir_xz: Vector3 = to_rim_xz.normalized()
	# Right-hand rule: right = dir_xz.cross(UP). Positive rotation around +right spins top of ball
	# backward toward shooter, so omega.cross(v) points +Y (authentic upward Magnus backspin lift!).
	var right_axis: Vector3 = dir_xz.cross(Vector3.UP)
	if right_axis.length_squared() <= 0.0001:
		return Vector3(spin_rad_sec, 0.0, 0.0)
	return right_axis.normalized() * spin_rad_sec


static func compute_shot_target_with_scatter(
	origin: Vector3,
	target_rim: Vector3,
	timing_quality: float = 1.0,
	timing_error: float = 0.0,
	contest_intensity: float = 0.0,
	exhaustion_penalty: float = 0.0,
	scatter_seed: int = 0
) -> Vector3:
	var clamped_q: float = clampf(timing_quality, 0.0, 1.0)
	var clamped_contest: float = clampf(contest_intensity, 0.0, 1.0)
	var clamped_exhaust: float = clampf(exhaustion_penalty, 0.0, 0.5)

	# Perfect / Green uncontested release aims dead-center in the cylinder
	if clamped_q >= 0.95 and clamped_contest <= 0.05 and clamped_exhaust <= 0.01:
		return target_rim

	var to_rim_xz := Vector3(target_rim.x - origin.x, 0.0, target_rim.z - origin.z)
	var fwd_xz := Vector3(0.0, 0.0, -1.0)
	if to_rim_xz.length_squared() > 0.0001:
		fwd_xz = to_rim_xz.normalized()
	var right_xz: Vector3 = fwd_xz.cross(Vector3.UP)
	if right_xz.length_squared() > 0.0001:
		right_xz = right_xz.normalized()
	else:
		right_xz = Vector3(1.0, 0.0, 0.0)

	var imperfection: float = maxf(0.0, 0.96 - clamped_q) + clamped_contest * 0.42 + clamped_exhaust * 0.35
	if imperfection <= 0.005:
		return target_rim

	# Deterministic pseudo-random lateral & depth scatter
	var hash_val: int = abs((scatter_seed * 1103515245 + 12345) & 0x7fffffff)
	var angle: float = float(hash_val % 6283) * 0.001
	var scatter_radius: float = clampf(imperfection * 0.36, 0.0, 0.42)

	# Early shots bias slightly short; Late shots bias slightly long
	var depth_bias: float = clampf(timing_error * 0.55, -0.22, 0.22)
	var lateral_offset: float = sin(angle) * scatter_radius
	var depth_offset: float = cos(angle) * (scatter_radius * 0.65) + depth_bias

	return target_rim + right_xz * lateral_offset + fwd_xz * depth_offset


static func compute_shot_velocity(
	origin: Vector3,
	target_rim: Vector3,
	arc_height_above_rim: float = 1.35,
	timing_quality: float = 1.0,
	scatter_seed: int = 0,
	spin_omega: Variant = null,
	timing_error: float = 0.0,
	contest_intensity: float = 0.0,
	exhaustion_penalty: float = 0.0
) -> Vector3:
	var aim_target: Vector3 = compute_shot_target_with_scatter(
		origin,
		target_rim,
		timing_quality,
		timing_error,
		contest_intensity,
		exhaustion_penalty,
		scatter_seed
	)

	var omega: Vector3 = (
		spin_omega as Vector3
		if (spin_omega is Vector3)
		else compute_backspin_angular_velocity(origin, aim_target, 16.0)
	)

	var dx: float = aim_target.x - origin.x
	var dz: float = aim_target.z - origin.z
	var dist_xz: float = sqrt(dx * dx + dz * dz)

	var extra_arc: float = clampf(arc_height_above_rim + dist_xz * 0.10, 0.55, 3.15)
	var peak_y: float = maxf(origin.y + 0.30, aim_target.y + extra_arc)

	var rise_h: float = maxf(0.05, peak_y - origin.y)
	var fall_h: float = maxf(0.05, peak_y - aim_target.y)

	var t_up: float = sqrt(2.0 * rise_h / GRAVITY)
	var t_down: float = sqrt(2.0 * fall_h / GRAVITY)
	var total_time: float = maxf(0.20, t_up + t_down)

	var v0 := Vector3(dx / total_time, GRAVITY * t_up, dz / total_time)

	# 4-iteration 60 Hz aerodynamic + Magnus shooting refinement for sub-millimeter precision
	for _iter in range(4):
		var sim: Dictionary = _simulate_to_target_plane(origin, v0, omega, aim_target.y, peak_y)
		if not bool(sim["reached"]):
			v0.y += 0.45
			continue
		var hit_pos: Vector3 = sim["pos"]
		var flight_t: float = maxf(0.15, float(sim["time"]))
		var apex_err: float = peak_y - float(sim["max_y"])
		v0.x -= (hit_pos.x - aim_target.x) / flight_t
		v0.z -= (hit_pos.z - aim_target.z) / flight_t
		v0.y += apex_err * 1.65

	return v0


static func _simulate_to_target_plane(
	origin: Vector3,
	initial_vel: Vector3,
	omega: Vector3,
	target_y: float,
	_desired_peak_y: float
) -> Dictionary:
	var pos: Vector3 = origin
	var vel: Vector3 = initial_vel
	var ang: Vector3 = omega
	var max_y: float = pos.y
	var elapsed: float = 0.0
	var inv_mass: float = 1.0 / BALL_MASS
	var ang_damp_factor: float = clampf(1.0 - 0.25 * FIXED_DT, 0.0, 1.0)

	for _step in range(180):
		var prev_pos: Vector3 = pos
		var speed_sq: float = vel.length_squared()
		var force := Vector3.ZERO
		if speed_sq > 6.25:
			force += -vel * (AIR_DRAG_COEFF * sqrt(speed_sq))
		if ang.length_squared() > 0.01 and speed_sq > 0.25:
			force += ang.cross(vel) * MAGNUS_COEFF

		var accel: Vector3 = Vector3(0.0, -GRAVITY, 0.0) + force * inv_mass
		vel += accel * FIXED_DT
		pos += vel * FIXED_DT
		ang *= ang_damp_factor
		elapsed += FIXED_DT

		if pos.y > max_y:
			max_y = pos.y

		if vel.y < 0.0 and prev_pos.y >= target_y and pos.y <= target_y:
			var denom: float = prev_pos.y - pos.y
			var alpha: float = (prev_pos.y - target_y) / denom if denom > 0.00001 else 1.0
			var cross_pos: Vector3 = prev_pos.lerp(pos, clampf(alpha, 0.0, 1.0))
			var cross_t: float = elapsed - FIXED_DT * (1.0 - alpha)
			return {"reached": true, "pos": cross_pos, "time": cross_t, "max_y": max_y}

	return {"reached": false, "pos": pos, "time": elapsed, "max_y": max_y}


static func compute_layup_velocity(
	origin: Vector3,
	target_rim: Vector3,
	timing_quality: float = 1.0,
	contest_intensity: float = 0.0,
	scatter_seed: int = 0
) -> Vector3:
	var spin: Vector3 = compute_backspin_angular_velocity(origin, target_rim, 10.5)
	return compute_shot_velocity(
		origin,
		target_rim,
		0.62,
		timing_quality,
		scatter_seed,
		spin,
		0.0,
		contest_intensity * 0.75,
		0.0
	)


static func compute_pass_velocity(
	origin: Vector3,
	target_pos: Vector3,
	target_vel: Vector3 = Vector3.ZERO,
	pass_speed: float = 15.0
) -> Vector3:
	var safe_speed: float = maxf(4.0, pass_speed)
	var initial_delta: Vector3 = target_pos - origin
	var approx_dist: float = initial_delta.length()
	var flight_time: float = clampf(approx_dist / safe_speed, 0.10, 1.20)

	var lead_target: Vector3 = target_pos + Vector3(target_vel.x, 0.0, target_vel.z) * (flight_time * 0.80)
	var delta: Vector3 = lead_target - origin

	var vx: float = delta.x / flight_time
	var vz: float = delta.z / flight_time
	var vy: float = (delta.y + 0.5 * GRAVITY * flight_time * flight_time) / flight_time
	return Vector3(vx, vy, vz)


static func sample_arc_points(
	origin: Vector3,
	initial_velocity: Vector3,
	steps: int = 24,
	step_dt: float = 0.05
) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var pos := origin
	var vel := initial_velocity
	pts.append(pos)
	for _i in range(maxi(1, steps)):
		vel.y -= GRAVITY * step_dt
		pos += vel * step_dt
		pts.append(pos)
		if pos.y < BALL_RADIUS:
			break
	return pts
