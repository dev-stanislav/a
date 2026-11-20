class_name SkillExecutor
extends RefCounted
## Stateless skill-execution planner & math helper for the 5 Phase 4 archetype-unique skills:
##   - volt_dash          (Speedster):    15.0 m/s two-stage lightning zig-zag burst + steal immunity
##   - starlight_high_arc (Sharpshooter): step-fade 5.8m rainbow jumper (up to 9.8m, +0.18 quality/block resist)
##   - mirage_thread      (Playmaker):    1.35x laser pass (+12 Zone & shot bonus) OR solo self-toss burst dash
##   - tectonic_slam      (Powerhouse):   armored poster dunk (<= 4.2m, 4.2m shockwave, 135 balance dmg, 1.65 power)
##   - eclipse_counter    (All-Rounder):  on-ball counter-drive + shield OR off-ball defense closeout + steal/contest boost

const SKILL_IDS: Array[String] = [
	"volt_dash",
	"starlight_high_arc",
	"mirage_thread",
	"tectonic_slam",
	"eclipse_counter",
]


static func is_archetype_skill(move_id: String) -> bool:
	return SKILL_IDS.has(move_id.strip_edges().to_lower())


static func safe_normalize_xz(vec: Vector3, fallback: Vector3 = Vector3(0.0, 0.0, -1.0)) -> Vector3:
	var flat := Vector3(vec.x, 0.0, vec.z)
	if flat.length_squared() > 1e-8:
		return flat.normalized()
	var fb_flat := Vector3(fallback.x, 0.0, fallback.z)
	if fb_flat.length_squared() > 1e-8:
		return fb_flat.normalized()
	return Vector3(0.0, 0.0, -1.0)


## Builds a deterministic actor context Dictionary by inspecting a PlayerController node
## and its scene tree (open teammates, nearest opponent, basketball position).
static func build_actor_context_from_player(
	player: Node3D,
	target_rim: Vector3,
	has_ball: bool,
	potency_mult: float = 1.0,
	zone_speed_mult: float = 1.0,
	pass_speed_mult: float = 1.0,
	dribble_hand: int = 1,
	is_zone_ex: Variant = null
) -> Dictionary:
	var resolved_zone_ex: bool = false
	if is_zone_ex is bool:
		resolved_zone_ex = bool(is_zone_ex)
	elif player != null:
		var z_node: Variant = player.get("zone")
		if z_node != null and z_node is Object:
			resolved_zone_ex = bool((z_node as Object).get("is_active"))
	var pos: Vector3 = player.global_position if player != null else Vector3.ZERO
	var facing_fwd: Vector3 = safe_normalize_xz(target_rim - pos)
	if player != null and player.get("facing_yaw") != null:
		var fy: float = float(player.get("facing_yaw"))
		facing_fwd = safe_normalize_xz(Vector3(-sin(fy), 0.0, -cos(fy)), facing_fwd)

	var team_id: int = int(player.get("team_id")) if (player != null and player.get("team_id") != null) else 0
	var open_teammate: Node3D = null
	var teammate_pos: Vector3 = Vector3.ZERO
	var teammate_vel: Vector3 = Vector3.ZERO
	var has_teammate: bool = false

	var nearest_opp: Node3D = null
	var nearest_opp_pos: Vector3 = Vector3.ZERO
	var has_opp: bool = false
	var nearest_opp_dist_sq: float = INF

	var ball_pos: Vector3 = Vector3.ZERO
	var has_ball_pos: bool = false

	if player != null:
		var tree: SceneTree = player.get_tree()
		if tree != null:
			var best_mate_score: float = -INF
			for node in tree.get_nodes_in_group("players"):
				if node == player or not (node is Node3D):
					continue
				var other := node as Node3D
				var other_team: int = int(other.get("team_id")) if other.get("team_id") != null else -1
				var delta := other.global_position - pos
				var dist_sq: float = delta.x * delta.x + delta.z * delta.z

				if other_team == team_id:
					if dist_sq < 0.25 or dist_sq > 625.0:
						continue
					var dir_mate: Vector3 = safe_normalize_xz(delta, facing_fwd)
					var align: float = dir_mate.dot(facing_fwd)
					var dist_to_rim: float = Vector2(other.global_position.x - target_rim.x, other.global_position.z - target_rim.z).length()
					var score: float = align * 1.6 - sqrt(dist_sq) * 0.03 - dist_to_rim * 0.05
					if score > best_mate_score:
						best_mate_score = score
						open_teammate = other
				else:
					# Prefer ball carrier if opponent has ball, otherwise nearest opponent
					var opp_has_ball: bool = bool(other.call("has_ball")) if other.has_method("has_ball") else false
					var eff_dist_sq: float = dist_sq * (0.25 if opp_has_ball else 1.0)
					if eff_dist_sq < nearest_opp_dist_sq:
						nearest_opp_dist_sq = eff_dist_sq
						nearest_opp = other

			if open_teammate != null:
				has_teammate = true
				teammate_pos = open_teammate.global_position
				if open_teammate is CharacterBody3D:
					teammate_vel = (open_teammate as CharacterBody3D).velocity

			if nearest_opp != null:
				has_opp = true
				nearest_opp_pos = nearest_opp.global_position

			for bnode in tree.get_nodes_in_group("basketball"):
				if bnode is Node3D:
					ball_pos = (bnode as Node3D).global_position
					has_ball_pos = true
					break

	return {
		"position": pos,
		"facing_forward": facing_fwd,
		"target_rim": target_rim,
		"has_ball": has_ball,
		"dribble_hand": dribble_hand,
		"potency_mult": maxf(0.5, potency_mult),
		"zone_speed_mult": maxf(0.5, zone_speed_mult),
		"pass_speed_mult": maxf(0.5, pass_speed_mult),
		"open_teammate": open_teammate,
		"has_teammate": has_teammate,
		"teammate_pos": teammate_pos,
		"teammate_vel": teammate_vel,
		"nearest_opponent": nearest_opp,
		"has_nearest_opponent": has_opp,
		"nearest_opponent_pos": nearest_opp_pos,
		"ball_pos": ball_pos,
		"has_ball_pos": has_ball_pos,
		"is_zone_ex": resolved_zone_ex,
		"scatter_seed": int(player.get("player_id")) * 131 if (player != null and player.get("player_id") != null) else 131,
	}


## Master dispatcher computing an immutable execution plan for any of the 5 unique class skills.
static func build_skill_plan(
	move_id: String,
	params: Dictionary,
	actor_context: Dictionary
) -> Dictionary:
	var canonical: String = move_id.strip_edges().to_lower()
	match canonical:
		"volt_dash":
			return plan_volt_dash(params, actor_context)
		"starlight_high_arc":
			return plan_starlight_high_arc(params, actor_context)
		"mirage_thread":
			return plan_mirage_thread(params, actor_context)
		"tectonic_slam":
			return plan_tectonic_slam(params, actor_context)
		"eclipse_counter":
			return plan_eclipse_counter(params, actor_context)
		_:
			return {
				"valid": false,
				"move_id": canonical,
				"kind": "unknown",
				"reason": "unsupported_skill",
			}


# ==============================================================================
# 1. Speedster — Volt Dash (Q, Shift, Q)
# ==============================================================================

static func plan_volt_dash(params: Dictionary, ctx: Dictionary) -> Dictionary:
	var pos: Vector3 = ctx.get("position", Vector3.ZERO)
	var target_rim: Vector3 = ctx.get("target_rim", Vector3(0.0, 3.05, -12.425))
	var facing: Vector3 = safe_normalize_xz(ctx.get("facing_forward", Vector3(0.0, 0.0, -1.0)))
	var potency: float = maxf(0.5, float(ctx.get("potency_mult", 1.0)))
	var zone_mult: float = maxf(0.5, float(ctx.get("zone_speed_mult", 1.0)))
	var dribble_hand: int = int(ctx.get("dribble_hand", 1))
	var is_zone_ex: bool = bool(ctx.get("is_zone_ex", params.get("is_zone_ex", false)))

	var dir_to_rim: Vector3 = safe_normalize_xz(target_rim - pos, facing)
	var right: Vector3 = safe_normalize_xz(dir_to_rim.cross(Vector3.UP), Vector3(1.0, 0.0, 0.0))

	# Cut sharp across body toward off-hand, then snap back on opposite vector
	var zig_sign: float = -1.0 if dribble_hand == 1 else 1.0
	var lat: float = float(params.get("lateral_cut_weight", 0.62))
	var base_speed: float = float(params.get("dash_speed", 15.0)) * (1.18 if is_zone_ex else 1.0)
	var eff_speed: float = base_speed * potency * zone_mult
	var base_dur: float = maxf(0.12, float(params.get("duration", 0.24)))
	var duration: float = maxf(base_dur, 0.28) if is_zone_ex else base_dur
	var split_ratio: float = clampf(float(params.get("zigzag_split_ratio", 0.45)), 0.25, 0.70)
	var split_time: float = duration * split_ratio

	var stage1_dir: Vector3 = safe_normalize_xz(dir_to_rim * 0.78 + right * (lat * zig_sign), dir_to_rim)
	var stage2_dir: Vector3 = safe_normalize_xz(dir_to_rim * 0.92 - right * (lat * 0.70 * zig_sign), dir_to_rim)
	var stage1_vel: Vector3 = stage1_dir * eff_speed
	var stage2_vel: Vector3 = stage2_dir * (eff_speed * 1.05)

	var steal_immune: bool = bool(params.get("steal_immune", true))
	var pass_through: bool = bool(params.get("pass_through_defender", true))
	var shield_extra: float = 0.26 if is_zone_ex else 0.16

	return {
		"valid": true,
		"move_id": "volt_dash",
		"kind": "two_stage_dash",
		"is_zone_ex": is_zone_ex,
		"anim_action": &"volt_dash",
		"face_target": target_rim,
		"dash_speed": eff_speed,
		"duration": duration,
		"split_time": split_time,
		"stage1_dir": stage1_dir,
		"stage2_dir": stage2_dir,
		"stage1_vel": stage1_vel,
		"stage2_vel": stage2_vel,
		"steal_immune": steal_immune,
		"steal_shield_duration": (duration + shield_extra) if steal_immune else 0.0,
		"pass_through_defender": pass_through,
		"phase_duration": (duration + (0.08 if is_zone_ex else 0.04)) if pass_through else 0.0,
		"swap_hand": true,
	}


# ==============================================================================
# 2. Sharpshooter — Starlight High Arc (E, S, LMB)
# ==============================================================================

static func plan_starlight_high_arc(params: Dictionary, ctx: Dictionary) -> Dictionary:
	var pos: Vector3 = ctx.get("position", Vector3.ZERO)
	var target_rim: Vector3 = ctx.get("target_rim", Vector3(0.0, 3.05, -12.425))
	var facing: Vector3 = safe_normalize_xz(ctx.get("facing_forward", Vector3(0.0, 0.0, -1.0)))
	var potency: float = maxf(0.5, float(ctx.get("potency_mult", 1.0)))
	var is_zone_ex: bool = bool(ctx.get("is_zone_ex", params.get("is_zone_ex", false)))

	var dist_xz: float = Vector2(pos.x - target_rim.x, pos.z - target_rim.z).length()
	var base_max_dist: float = float(params.get("max_rim_dist", 9.8))
	var max_dist: float = maxf(base_max_dist, 10.8) if is_zone_ex else base_max_dist
	if dist_xz > max_dist + 0.15:
		return {
			"valid": false,
			"move_id": "starlight_high_arc",
			"kind": "high_arc_shot",
			"is_zone_ex": is_zone_ex,
			"reason": "out_of_rim_range",
			"dist_to_rim": dist_xz,
			"max_rim_dist": max_dist,
		}

	var dir_to_rim: Vector3 = safe_normalize_xz(target_rim - pos, facing)
	var fade_dir: Vector3 = -dir_to_rim
	var fade_dist: float = float(params.get("fade_dist", 1.35)) * (1.12 if is_zone_ex else 1.0)
	var base_fade_dur: float = maxf(0.10, float(params.get("fade_duration", 0.16)))
	var fade_duration: float = maxf(0.10, base_fade_dur * (0.80 if is_zone_ex else 1.0))
	var fade_vel: Vector3 = fade_dir * (fade_dist / fade_duration)

	var base_arc_h: float = float(params.get("arc_height", 5.8))
	var arc_height: float = maxf(base_arc_h, 6.2) if is_zone_ex else base_arc_h
	var arc_above_rim: float = maxf(2.75, arc_height - target_rim.y)
	var quality_bonus: float = (float(params.get("quality_bonus", 0.18)) + (0.06 if is_zone_ex else 0.0)) * potency
	var block_resistance: float = (float(params.get("block_resistance", 0.18)) + (0.08 if is_zone_ex else 0.0)) * potency
	var spin_rate: float = float(params.get("spin_rate", 20.0)) * (1.12 if is_zone_ex else 1.0)
	var release_height: float = 2.40 if is_zone_ex else 2.28

	# Step-fade origin & elevated rainbow release point
	var shot_origin_floor := Vector3(pos.x, 0.0, pos.z)
	var release_pos: Vector3 = pos + dir_to_rim * 0.18 + Vector3(0.0, release_height, 0.0)
	var is_three: bool = (dist_xz > 6.75) or (absf(pos.x) > 6.60)
	var base_quality: float = clampf((0.88 + quality_bonus) if potency > 1.05 else (0.82 + quality_bonus), 0.85, 1.0)
	var backspin: Vector3 = BallTrajectory.compute_backspin_angular_velocity(release_pos, target_rim, spin_rate)
	var launch_vel: Vector3 = BallTrajectory.compute_shot_velocity(
		release_pos,
		target_rim,
		arc_above_rim,
		base_quality,
		int(ctx.get("scatter_seed", 131)),
		backspin,
		0.0,
		0.0,
		0.0
	)

	return {
		"valid": true,
		"move_id": "starlight_high_arc",
		"kind": "high_arc_shot",
		"is_zone_ex": is_zone_ex,
		"anim_action": &"starlight_high_arc",
		"face_target": target_rim,
		"fade_dir": fade_dir,
		"fade_vel": fade_vel,
		"fade_dist": fade_dist,
		"fade_duration": fade_duration,
		"jump_impulse": 5.6 if is_zone_ex else 5.2,
		"arc_height": arc_height,
		"arc_above_rim": arc_above_rim,
		"max_rim_dist": max_dist,
		"quality_bonus": quality_bonus,
		"block_resistance": block_resistance,
		"shot_quality": base_quality,
		"is_three": is_three,
		"dist_to_rim": dist_xz,
		"shot_origin_floor": shot_origin_floor,
		"release_pos": release_pos,
		"launch_velocity": launch_vel,
		"backspin_omega": backspin,
		"timing_label": "Perfect" if base_quality >= 0.96 else "Good",
	}


# ==============================================================================
# 3. Playmaker — Mirage Thread (Q, E, RMB)
# ==============================================================================

static func plan_mirage_thread(params: Dictionary, ctx: Dictionary) -> Dictionary:
	var pos: Vector3 = ctx.get("position", Vector3.ZERO)
	var target_rim: Vector3 = ctx.get("target_rim", Vector3(0.0, 3.05, -12.425))
	var facing: Vector3 = safe_normalize_xz(ctx.get("facing_forward", Vector3(0.0, 0.0, -1.0)))
	var potency: float = maxf(0.5, float(ctx.get("potency_mult", 1.0)))
	var zone_mult: float = maxf(0.5, float(ctx.get("zone_speed_mult", 1.0)))
	var is_zone_ex: bool = bool(ctx.get("is_zone_ex", params.get("is_zone_ex", false)))

	var open_teammate: Variant = ctx.get("open_teammate", null)
	var has_teammate: bool = (open_teammate != null) or bool(ctx.get("has_teammate", false))

	if has_teammate:
		var mate_pos: Vector3 = ctx.get("teammate_pos", Vector3.ZERO)
		var mate_vel: Vector3 = ctx.get("teammate_vel", Vector3.ZERO)
		if open_teammate is Node3D:
			mate_pos = (open_teammate as Node3D).global_position
			if open_teammate is CharacterBody3D:
				mate_vel = (open_teammate as CharacterBody3D).velocity

		var to_mate_dir: Vector3 = safe_normalize_xz(mate_pos - pos, facing)
		var release_pos: Vector3 = pos + to_mate_dir * 0.36 + Vector3(0.0, 1.32, 0.0)
		var target_pos: Vector3 = mate_pos + Vector3(0.0, 1.25, 0.0)

		var base_pass_spd: float = float(params.get("base_pass_speed", 15.0))
		var skill_mult: float = float(params.get("pass_speed_mult", 1.35))
		var arch_pass_mult: float = maxf(1.0, float(ctx.get("pass_speed_mult", 1.0)))
		var effective_mult: float = maxf(skill_mult, arch_pass_mult) * (1.18 if is_zone_ex else 1.0)
		var laser_speed: float = base_pass_spd * effective_mult * potency

		var pass_vel: Vector3 = BallTrajectory.compute_pass_velocity(release_pos, target_pos, mate_vel, laser_speed)
		var zone_grant: float = (float(params.get("teammate_zone_grant", 12.0)) + (4.0 if is_zone_ex else 0.0)) * potency
		var shot_bonus: float = (float(params.get("teammate_shot_bonus", 0.15)) + (0.05 if is_zone_ex else 0.0)) * potency
		var shot_bonus_dur: float = float(params.get("teammate_shot_bonus_duration", 1.5)) + (0.5 if is_zone_ex else 0.0)

		return {
			"valid": true,
			"move_id": "mirage_thread",
			"kind": "laser_pass",
			"mode": "laser_pass",
			"is_zone_ex": is_zone_ex,
			"anim_action": &"mirage_thread",
			"face_target": mate_pos,
			"target_teammate": open_teammate,
			"release_pos": release_pos,
			"target_pos": target_pos,
			"pass_speed": laser_speed,
			"pass_speed_mult": effective_mult,
			"launch_velocity": pass_vel,
			"teammate_zone_grant": zone_grant,
			"teammate_shot_bonus": shot_bonus,
			"teammate_shot_bonus_duration": shot_bonus_dur,
		}

	# Solo fallback when no teammate is on court: flashy self-toss burst dash forward!
	var dash_dir: Vector3 = safe_normalize_xz(target_rim - pos, facing)
	var solo_speed: float = float(params.get("solo_dash_speed", 12.8)) * (1.18 if is_zone_ex else 1.0) * potency * zone_mult
	var base_solo_dur: float = maxf(0.14, float(params.get("solo_dash_duration", 0.26)))
	var solo_dur: float = maxf(base_solo_dur, 0.30) if is_zone_ex else base_solo_dur
	var steal_immune: bool = bool(params.get("steal_immune", true))

	return {
		"valid": true,
		"move_id": "mirage_thread",
		"kind": "solo_dash",
		"mode": "solo_self_toss",
		"is_zone_ex": is_zone_ex,
		"anim_action": &"mirage_thread",
		"face_target": target_rim,
		"dash_dir": dash_dir,
		"dash_speed": solo_speed,
		"dash_vel": dash_dir * solo_speed,
		"duration": solo_dur,
		"steal_immune": steal_immune,
		"steal_shield_duration": (solo_dur + (0.24 if is_zone_ex else 0.16)) if steal_immune else 0.0,
		"swap_hand": true,
	}


# ==============================================================================
# 4. Powerhouse — Tectonic Slam (Shift, Space, LMB)
# ==============================================================================

static func plan_tectonic_slam(params: Dictionary, ctx: Dictionary) -> Dictionary:
	var pos: Vector3 = ctx.get("position", Vector3.ZERO)
	var target_rim: Vector3 = ctx.get("target_rim", Vector3(0.0, 3.05, -12.425))
	var potency: float = maxf(0.5, float(ctx.get("potency_mult", 1.0)))
	var is_zone_ex: bool = bool(ctx.get("is_zone_ex", params.get("is_zone_ex", false)))

	var dist_xz: float = Vector2(pos.x - target_rim.x, pos.z - target_rim.z).length()
	var base_max_dist: float = float(params.get("max_rim_dist", 4.2))
	var max_dist: float = maxf(base_max_dist, 5.0) if is_zone_ex else base_max_dist
	if dist_xz > max_dist + 0.15:
		return {
			"valid": false,
			"move_id": "tectonic_slam",
			"kind": "armored_dunk",
			"is_zone_ex": is_zone_ex,
			"reason": "out_of_rim_range",
			"dist_to_rim": dist_xz,
			"max_rim_dist": max_dist,
		}

	var base_apex: float = float(params.get("apex_height", 3.85))
	var apex_height: float = maxf(base_apex, 4.25) if is_zone_ex else base_apex
	var base_shock: float = float(params.get("shockwave_radius", 4.2)) * (1.25 if is_zone_ex else 1.0)
	var base_bal: float = float(params.get("balance_damage", 135.0)) * (1.25 if is_zone_ex else 1.0)
	var base_pow: float = float(params.get("dunk_power", 1.65)) * (1.20 if is_zone_ex else 1.0)
	var shockwave_radius: float = base_shock * potency
	var balance_damage: float = base_bal * potency
	var dunk_power: float = base_pow * potency
	var dunk_frames: int = maxi(16, int(params.get("dunk_duration_frames", 24)))
	var armored: bool = bool(params.get("armored", true))

	return {
		"valid": true,
		"move_id": "tectonic_slam",
		"kind": "armored_dunk",
		"is_zone_ex": is_zone_ex,
		"anim_action": &"tectonic_slam",
		"face_target": target_rim,
		"dist_to_rim": dist_xz,
		"max_rim_dist": max_dist,
		"apex_height": apex_height,
		"shockwave_radius": shockwave_radius,
		"balance_damage": balance_damage,
		"dunk_power": dunk_power,
		"armored": armored,
		"dunk_duration_frames": dunk_frames,
		"dunk_duration_sec": float(dunk_frames) / 60.0,
		"dunk_params": {
			"max_rim_dist": max_dist,
			"apex_height": apex_height,
			"shockwave_radius": base_shock,
			"balance_damage": base_bal,
			"dunk_power": base_pow,
			"armored": armored,
			"is_zone_ex": is_zone_ex,
			"dunk_duration_frames": dunk_frames,
			"shot_type": "tectonic_slam",
		},
	}


# ==============================================================================
# 5. All-Rounder — Eclipse Counter (C, Q, E, Shift) — On-Ball OR Off-Ball!
# ==============================================================================

static func plan_eclipse_counter(params: Dictionary, ctx: Dictionary) -> Dictionary:
	var pos: Vector3 = ctx.get("position", Vector3.ZERO)
	var target_rim: Vector3 = ctx.get("target_rim", Vector3(0.0, 3.05, -12.425))
	var facing: Vector3 = safe_normalize_xz(ctx.get("facing_forward", Vector3(0.0, 0.0, -1.0)))
	var has_ball: bool = bool(ctx.get("has_ball", false))
	var potency: float = maxf(0.5, float(ctx.get("potency_mult", 1.0)))
	var zone_mult: float = maxf(0.5, float(ctx.get("zone_speed_mult", 1.0)))
	var dribble_hand: int = int(ctx.get("dribble_hand", 1))
	var is_zone_ex: bool = bool(ctx.get("is_zone_ex", params.get("is_zone_ex", false)))

	if has_ball:
		# Offense: counter-drive burst + steal shield + gather shot bonus
		var dir_to_rim: Vector3 = safe_normalize_xz(target_rim - pos, facing)
		var right: Vector3 = safe_normalize_xz(dir_to_rim.cross(Vector3.UP), Vector3(1.0, 0.0, 0.0))
		var side_sign: float = 1.0 if dribble_hand == 0 else -1.0
		var drive_dir: Vector3 = safe_normalize_xz(dir_to_rim * 0.88 + right * (0.47 * side_sign), dir_to_rim)
		var dash_speed: float = float(params.get("offense_dash_speed", 12.6)) * (1.16 if is_zone_ex else 1.0) * potency * zone_mult
		var base_dur: float = maxf(0.14, float(params.get("offense_duration", 0.28)))
		var duration: float = maxf(base_dur, 0.32) if is_zone_ex else base_dur
		var shield_dur: float = float(params.get("offense_steal_shield", 0.45)) + (0.15 if is_zone_ex else 0.0)
		var shot_bonus: float = (float(params.get("offense_shot_bonus", 0.12)) + (0.06 if is_zone_ex else 0.0)) * potency

		return {
			"valid": true,
			"move_id": "eclipse_counter",
			"kind": "offense_counter",
			"mode": "offense_counter_drive",
			"is_zone_ex": is_zone_ex,
			"anim_action": &"eclipse_counter",
			"face_target": target_rim,
			"dash_dir": drive_dir,
			"dash_speed": dash_speed,
			"dash_vel": drive_dir * dash_speed,
			"duration": duration,
			"steal_immune": true,
			"steal_shield_duration": shield_dur,
			"shot_bonus": shot_bonus,
			"shot_bonus_duration": 1.15 if is_zone_ex else 0.90,
			"swap_hand": true,
		}

	# Defense (off-ball): instant closeout burst toward opponent/ball + boosted steal & contest window
	var closeout_target: Vector3 = pos + facing * 3.0
	if bool(ctx.get("has_nearest_opponent", false)):
		closeout_target = ctx.get("nearest_opponent_pos", closeout_target)
	elif bool(ctx.get("has_ball_pos", false)):
		closeout_target = ctx.get("ball_pos", closeout_target)

	var closeout_dir: Vector3 = safe_normalize_xz(closeout_target - pos, facing)
	var closeout_speed: float = float(params.get("defense_closeout_speed", 13.2)) * (1.18 if is_zone_ex else 1.0) * potency * zone_mult
	var base_def_dur: float = maxf(0.14, float(params.get("defense_duration", 0.24)))
	var def_dur: float = maxf(base_def_dur, 0.28) if is_zone_ex else base_def_dur
	var steal_bonus: float = (float(params.get("defense_steal_radius_bonus", 0.65)) + (0.25 if is_zone_ex else 0.0)) * potency
	var contest_bonus: float = (float(params.get("defense_contest_bonus", 0.30)) + (0.12 if is_zone_ex else 0.0)) * potency
	var window_dur: float = float(params.get("defense_window_duration", 0.90)) + (0.30 if is_zone_ex else 0.0)

	return {
		"valid": true,
		"move_id": "eclipse_counter",
		"kind": "defense_counter",
		"mode": "defense_closeout",
		"is_zone_ex": is_zone_ex,
		"anim_action": &"eclipse_counter",
		"face_target": closeout_target,
		"closeout_dir": closeout_dir,
		"closeout_speed": closeout_speed,
		"closeout_vel": closeout_dir * closeout_speed,
		"duration": def_dur,
		"steal_radius_bonus": steal_bonus,
		"contest_bonus": contest_bonus,
		"window_duration": window_dur,
	}
