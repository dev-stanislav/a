class_name AIPerception
extends RefCounted
## Builds immutable, deterministic 60 Hz WorldSnapshots from the live arena scene
## (players, basketball, hoops, match_controller) and maintains a deterministic
## reaction-delay ring queue so lower-tier AI genuinely perceives state changes
## later than high-tier AI (e.g., Rookie 24f = 400ms vs Phantom 3f = 50ms).

const QUEUE_CAPACITY: int = 48

const COURT_HALF_WIDTH: float = 7.5
const COURT_HALF_LENGTH: float = 14.0
const HOOP_A_RIM := Vector3(0.0, 3.05, 12.425)  # Team 0 defends, Team 1 attacks
const HOOP_B_RIM := Vector3(0.0, 3.05, -12.425) # Team 1 defends, Team 0 attacks

const STANCE_PASS_LANE_RADIUS: float = 1.65
const MOVING_PASS_LANE_RADIUS: float = 1.25

const BALL_STATE_FREE: int = 0
const BALL_STATE_HELD: int = 1
const BALL_STATE_DRIBBLING: int = 2
const BALL_STATE_PASS_FLIGHT: int = 3
const BALL_STATE_SHOT_FLIGHT: int = 4
const BALL_STATE_DUNK_LOCKED: int = 5

var _queue: Array[Dictionary] = [] # Ascending by tick: {"tick": int, "snapshot": Dictionary}


func clear() -> void:
	_queue.clear()


func get_queue_size() -> int:
	return _queue.size()


## Records an observation snapshot stamped with `tick`.
func push_observation(tick: int, snapshot: Dictionary) -> void:
	var entry := {
		"tick": tick,
		"snapshot": snapshot.duplicate(true),
	}
	if not _queue.is_empty() and int(_queue[_queue.size() - 1]["tick"]) == tick:
		_queue[_queue.size() - 1] = entry
	else:
		_queue.append(entry)
	while _queue.size() > QUEUE_CAPACITY:
		_queue.pop_front()


## Returns the newest buffered snapshot whose tick <= (current_tick - delay_frames).
## Guarantees exact frame-accurate reaction latency without peeking into the future.
func get_perceived_snapshot(current_tick: int, delay_frames: int) -> Dictionary:
	if _queue.is_empty():
		return {}

	var clamped_delay: int = maxi(0, delay_frames)
	var target_tick: int = current_tick - clamped_delay

	for i in range(_queue.size() - 1, -1, -1):
		var entry: Dictionary = _queue[i]
		if int(entry["tick"]) <= target_tick:
			return (entry["snapshot"] as Dictionary).duplicate(true)

	# During initial startup frames before `delay_frames` ticks have elapsed,
	# return the oldest recorded observation (never leaking newer observations early).
	return (_queue[0]["snapshot"] as Dictionary).duplicate(true)


func export_state() -> Dictionary:
	var q_copy: Array[Dictionary] = []
	for entry in _queue:
		q_copy.append({
			"tick": int(entry["tick"]),
			"snapshot": (entry["snapshot"] as Dictionary).duplicate(true),
		})
	return {"queue": q_copy}


func import_state(state: Dictionary) -> void:
	_queue.clear()
	if state.has("queue") and state["queue"] is Array:
		for item in (state["queue"] as Array):
			if item is Dictionary:
				var d := item as Dictionary
				_queue.append({
					"tick": int(d.get("tick", 0)),
					"snapshot": (d.get("snapshot", {}) as Dictionary).duplicate(true),
				})


# ==============================================================================
# Live Arena WorldSnapshot Builder
# ==============================================================================

static func build_snapshot(owner_player: Node, tick: int) -> Dictionary:
	if owner_player == null or not (owner_player is Node3D):
		return {}

	var p3d := owner_player as Node3D
	var my_id: int = int(owner_player.get("player_id")) if owner_player.get("player_id") != null else 1
	var my_team: int = int(owner_player.get("team_id")) if owner_player.get("team_id") != null else 0
	var my_arch: String = str(owner_player.get("archetype_id")) if owner_player.get("archetype_id") != null else "all_rounder"
	var my_pos: Vector3 = p3d.global_position
	var my_vel: Vector3 = (owner_player as CharacterBody3D).velocity if owner_player is CharacterBody3D else Vector3.ZERO
	var my_yaw: float = float(owner_player.get("facing_yaw")) if owner_player.get("facing_yaw") != null else 0.0
	var my_grounded: bool = (owner_player as CharacterBody3D).is_on_floor() if owner_player is CharacterBody3D else true
	var my_ankle_stun: float = float(owner_player.get("_ankle_broken_stun")) if owner_player.get("_ankle_broken_stun") != null else 0.0

	var target_rim: Vector3 = HOOP_B_RIM if my_team == 0 else HOOP_A_RIM
	var defended_rim: Vector3 = HOOP_A_RIM if my_team == 0 else HOOP_B_RIM

	var tree: SceneTree = owner_player.get_tree()
	if tree != null:
		for h_node in tree.get_nodes_in_group("hoops"):
			if h_node.has_method("get_attacking_team") and h_node.has_method("get_rim_center"):
				var atk_team: int = int(h_node.call("get_attacking_team"))
				var rc: Vector3 = h_node.call("get_rim_center")
				if atk_team == my_team:
					target_rim = rc
				else:
					defended_rim = rc

	# Inspect subcomponents on owner_player safely
	var stam_node: Variant = owner_player.get("stamina")
	var my_stamina: float = float(stam_node.get("current_stamina")) if (stam_node != null and stam_node is Object) else 100.0
	var my_max_stamina: float = float(stam_node.get("max_stamina")) if (stam_node != null and stam_node is Object) else 100.0
	var my_exhausted: bool = bool(stam_node.call("is_exhausted")) if (stam_node != null and stam_node is Object and stam_node.has_method("is_exhausted")) else false

	var zone_node: Variant = owner_player.get("zone")
	var my_zone_energy: float = float(zone_node.get("current_zone")) if (zone_node != null and zone_node is Object) else 0.0
	var my_zone_max: float = float(zone_node.get("max_zone")) if (zone_node != null and zone_node is Object) else 100.0
	var my_zone_active: bool = bool(zone_node.get("is_active")) if (zone_node != null and zone_node is Object) else false
	var my_can_zone: bool = bool(zone_node.call("can_activate")) if (zone_node != null and zone_node is Object and zone_node.has_method("can_activate")) else false

	var shoot_node: Variant = owner_player.get("shooting_system")
	var my_charging: bool = bool(shoot_node.get("is_charging_shot")) if (shoot_node != null and shoot_node is Object) else false
	var my_layup: bool = bool(shoot_node.get("is_layup_gather")) if (shoot_node != null and shoot_node is Object) else false
	var my_dunking: bool = bool(shoot_node.get("is_dunking")) if (shoot_node != null and shoot_node is Object) else false
	var my_charge_time: float = float(shoot_node.call("get_charge_time")) if (shoot_node != null and shoot_node is Object and shoot_node.has_method("get_charge_time")) else 0.0
	var my_opt_charge: float = float(shoot_node.call("get_optimal_charge_time")) if (shoot_node != null and shoot_node is Object and shoot_node.has_method("get_optimal_charge_time")) else 0.26
	var my_3pt_range: float = float(shoot_node.get("three_point_range")) if (shoot_node != null and shoot_node is Object and shoot_node.get("three_point_range") != null) else 7.8
	var my_dunk_radius: float = float(shoot_node.get("dunk_range_xz")) if (shoot_node != null and shoot_node is Object and shoot_node.get("dunk_range_xz") != null) else 2.90
	var my_pass_mult: float = float(shoot_node.get("pass_speed_mult")) if (shoot_node != null and shoot_node is Object and shoot_node.get("pass_speed_mult") != null) else 1.0

	var def_node: Variant = owner_player.get("defense_system")
	var my_block_radius: float = float(def_node.get("block_radius")) if (def_node != null and def_node is Object) else 1.70
	var my_steal_radius: float = float(def_node.get("steal_radius")) if (def_node != null and def_node is Object) else 1.75
	var my_in_stance: bool = bool(owner_player.call("is_in_defensive_stance")) if owner_player.has_method("is_in_defensive_stance") else false
	var my_def_recovery: bool = bool(def_node.call("is_in_recovery")) if (def_node != null and def_node is Object and def_node.has_method("is_in_recovery")) else false
	var my_def_locked: bool = bool(def_node.call("are_defensive_actions_locked")) if (def_node != null and def_node is Object and def_node.has_method("are_defensive_actions_locked")) else false

	var drib_node: Variant = owner_player.get("dribble_system")
	var my_drib_hand: int = int(drib_node.call("get_dribble_hand")) if (drib_node != null and drib_node is Object and drib_node.has_method("get_dribble_hand")) else 1

	var combo_node: Variant = owner_player.get("combo_engine")
	var combo_cooldowns: Dictionary = {}
	if combo_node != null and combo_node is Object and combo_node.has_method("get_all_cooldowns"):
		combo_cooldowns = combo_node.call("get_all_cooldowns")

	var unique_skill_id: String = ArchetypeRegistry.get_unique_skill_id(my_arch)

	# Basketball state
	var ball_exists: bool = false
	var ball_pos: Vector3 = Vector3.ZERO
	var ball_vel: Vector3 = Vector3.ZERO
	var ball_state: int = BALL_STATE_FREE
	var ball_reboundable: bool = false
	var carrier_node: Node3D = null
	var carrier_id: int = -1
	var carrier_team: int = -1
	var carrier_pos: Vector3 = Vector3.ZERO
	var carrier_vel: Vector3 = Vector3.ZERO
	var carrier_charging: bool = false
	var carrier_dunking: bool = false
	var carrier_stamina: float = 100.0
	var carrier_steal_protected: bool = false
	var carrier_armored: bool = false

	if tree != null:
		for b_node in tree.get_nodes_in_group("basketball"):
			if b_node is Node3D:
				ball_exists = true
				ball_pos = (b_node as Node3D).global_position
				if b_node is RigidBody3D:
					ball_vel = (b_node as RigidBody3D).linear_velocity
				if b_node.get("ball_state") != null:
					ball_state = int(b_node.get("ball_state"))
				if b_node.get("is_reboundable") != null:
					ball_reboundable = bool(b_node.get("is_reboundable"))
				var c_var: Variant = b_node.get("carrier")
				if c_var is Node3D:
					carrier_node = c_var as Node3D
					carrier_pos = carrier_node.global_position
					if carrier_node is CharacterBody3D:
						carrier_vel = (carrier_node as CharacterBody3D).velocity
					carrier_id = int(carrier_node.get("player_id")) if carrier_node.get("player_id") != null else -1
					carrier_team = int(carrier_node.get("team_id")) if carrier_node.get("team_id") != null else -1
					var cs: Variant = carrier_node.get("shooting_system")
					if cs != null and cs is Object:
						carrier_charging = bool(cs.get("is_charging_shot"))
						carrier_dunking = bool(cs.get("is_dunking"))
					var cst: Variant = carrier_node.get("stamina")
					if cst != null and cst is Object:
						carrier_stamina = float(cst.get("current_stamina"))
					if carrier_node.has_method("has_steal_protection"):
						carrier_steal_protected = bool(carrier_node.call("has_steal_protection"))
					if carrier_node.has_method("is_armored"):
						carrier_armored = bool(carrier_node.call("is_armored"))
				else:
					if b_node.get("carrier_player_id") != null:
						carrier_id = int(b_node.get("carrier_player_id"))
					if b_node.get("carrier_team_id") != null:
						carrier_team = int(b_node.get("carrier_team_id"))
				break

	var my_has_ball: bool = (carrier_node == owner_player)

	# Match & Shot Clock from GameState / MatchController
	var match_secs: float = 180.0
	var shot_clock_left: float = 24.0
	var scores: Array[int] = [0, 0]
	var gs: Node = _get_game_state(tree)
	if gs != null:
		if gs.get("match_seconds_left") != null:
			match_secs = float(gs.get("match_seconds_left"))
		if gs.get("shot_clock_left") != null:
			shot_clock_left = float(gs.get("shot_clock_left"))
		if gs.get("scores") is Array:
			var s_arr: Array = gs.get("scores")
			if s_arr.size() >= 2:
				scores = [int(s_arr[0]), int(s_arr[1])]
	if tree != null:
		for mc in tree.get_nodes_in_group("match_controller"):
			var sc: Variant = mc.get("shot_clock")
			if sc != null and sc is Object and sc.get("time_left") != null:
				shot_clock_left = float(sc.get("time_left"))
				break

	# Gather all teammates & opponents deterministically sorted by player_id
	var raw_mates: Array[Dictionary] = []
	var raw_opps: Array[Dictionary] = []
	var all_team_members: Array[Dictionary] = [] # Includes self for defensive mark assignment

	all_team_members.append({
		"player_id": my_id,
		"position": my_pos,
		"is_self": true,
	})

	if tree != null:
		for node in tree.get_nodes_in_group("players"):
			if node == owner_player or not (node is Node3D):
				continue
			var other := node as Node3D
			var o_id: int = int(other.get("player_id")) if other.get("player_id") != null else -1
			var o_team: int = int(other.get("team_id")) if other.get("team_id") != null else -1
			var o_arch: String = str(other.get("archetype_id")) if other.get("archetype_id") != null else "all_rounder"
			var o_pos: Vector3 = other.global_position
			var o_vel: Vector3 = (other as CharacterBody3D).velocity if other is CharacterBody3D else Vector3.ZERO
			var o_has_ball: bool = (carrier_node == other)
			var o_stance: bool = bool(other.call("is_in_defensive_stance")) if other.has_method("is_in_defensive_stance") else false
			var o_shoot: Variant = other.get("shooting_system")
			var o_charging: bool = bool(o_shoot.get("is_charging_shot")) if (o_shoot != null and o_shoot is Object) else false
			var o_dunking: bool = bool(o_shoot.get("is_dunking")) if (o_shoot != null and o_shoot is Object) else false
			var o_3pt: float = float(o_shoot.get("three_point_range")) if (o_shoot != null and o_shoot is Object and o_shoot.get("three_point_range") != null) else 7.8
			var o_dunk_r: float = float(o_shoot.get("dunk_range_xz")) if (o_shoot != null and o_shoot is Object and o_shoot.get("dunk_range_xz") != null) else 2.90
			var o_stam_n: Variant = other.get("stamina")
			var o_stam: float = float(o_stam_n.get("current_stamina")) if (o_stam_n != null and o_stam_n is Object) else 100.0
			var o_shield: bool = bool(other.call("has_steal_protection")) if other.has_method("has_steal_protection") else false
			var o_broken: bool = bool(other.call("is_ankle_broken")) if other.has_method("is_ankle_broken") else false

			var dist_self: float = _dist_xz(my_pos, o_pos)
			if o_team == my_team:
				var entry := {
					"player_id": o_id,
					"archetype_id": o_arch,
					"position": o_pos,
					"velocity": o_vel,
					"has_ball": o_has_ball,
					"dist_to_self": dist_self,
					"dist_to_target_rim": _dist_xz(o_pos, target_rim),
					"three_point_range": o_3pt,
					"dunk_radius": o_dunk_r,
					"nearest_opp_dist": 99.0,
					"pass_lane_risk": 0.0,
					"is_open": true,
				}
				raw_mates.append(entry)
				all_team_members.append({
					"player_id": o_id,
					"position": o_pos,
					"is_self": false,
				})
			else:
				raw_opps.append({
					"player_id": o_id,
					"archetype_id": o_arch,
					"position": o_pos,
					"velocity": o_vel,
					"has_ball": o_has_ball,
					"dist_to_self": dist_self,
					"dist_to_defended_rim": _dist_xz(o_pos, defended_rim),
					"dist_to_target_rim": _dist_xz(o_pos, target_rim),
					"is_in_stance": o_stance,
					"is_charging_shot": o_charging,
					"is_dunking": o_dunking,
					"stamina": o_stam,
					"has_steal_protection": o_shield,
					"is_ankle_broken": o_broken,
				})

	raw_mates.sort_custom(_sort_by_player_id)
	raw_opps.sort_custom(_sort_by_player_id)
	all_team_members.sort_custom(_sort_by_player_id)

	# Compute nearest defender, paint congestion, and shot contest threat
	var nearest_def_id: int = -1
	var nearest_def_dist: float = 99.0
	var nearest_def_pos: Vector3 = Vector3.ZERO
	var nearest_def_stance: bool = false
	var defenders_in_paint: int = 0

	for opp in raw_opps:
		var d_self: float = float(opp["dist_to_self"])
		if d_self < nearest_def_dist:
			nearest_def_dist = d_self
			nearest_def_id = int(opp["player_id"])
			nearest_def_pos = opp["position"]
			nearest_def_stance = bool(opp["is_in_stance"])
		if float(opp["dist_to_target_rim"]) <= 4.0:
			defenders_in_paint += 1

	var shot_contest_threat: float = 0.0
	if owner_player.has_method("compute_current_shot_contest"):
		shot_contest_threat = float(owner_player.call("compute_current_shot_contest"))
	elif nearest_def_dist < 2.75:
		var max_r: float = 2.75 if nearest_def_stance else 2.40
		shot_contest_threat = clampf(1.0 - (nearest_def_dist / max_r), 0.0, 1.0)

	# Compute teammate openness & pass-lane interception risk against stance/moving opponents
	for mate in raw_mates:
		var m_pos: Vector3 = mate["position"]
		var closest_o: float = 99.0
		for opp in raw_opps:
			var d_mo: float = _dist_xz(m_pos, opp["position"])
			if d_mo < closest_o:
				closest_o = d_mo
		var lane_risk: float = compute_pass_lane_risk(my_pos, m_pos, raw_opps)
		mate["nearest_opp_dist"] = closest_o
		mate["pass_lane_risk"] = lane_risk
		mate["is_open"] = (closest_o >= 2.2) and (lane_risk < 0.45)

	# Deterministic defensive role & matchup assignment
	var is_primary_defender: bool = false
	var assigned_mark_id: int = -1
	var assigned_mark_pos: Vector3 = carrier_pos
	var primary_defender_beaten: bool = false

	if not raw_opps.is_empty():
		var primary_def_id: int = my_id
		var best_c_dist: float = INF
		var primary_def_pos: Vector3 = my_pos
		var ref_ball_pos: Vector3 = carrier_pos if carrier_id >= 0 else ball_pos
		for tm in all_team_members:
			var dc: float = _dist_xz(tm["position"], ref_ball_pos)
			if dc < best_c_dist - 0.001:
				best_c_dist = dc
				primary_def_id = int(tm["player_id"])
				primary_def_pos = tm["position"]

		is_primary_defender = (primary_def_id == my_id)
		if carrier_id >= 0 and carrier_team != my_team:
			var carrier_rim_d: float = _dist_xz(carrier_pos, defended_rim)
			var primary_rim_d: float = _dist_xz(primary_def_pos, defended_rim)
			primary_defender_beaten = (carrier_rim_d + 0.55 < primary_rim_d) and (carrier_rim_d < 6.5)

		if is_primary_defender:
			assigned_mark_id = carrier_id if (carrier_id >= 0 and carrier_team != my_team) else int(raw_opps[0]["player_id"])
		else:
			# Match remaining off-ball defenders 1-to-1 to off-ball opponents deterministically
			var off_defs: Array[int] = []
			for tm in all_team_members:
				var tid: int = int(tm["player_id"])
				if tid != primary_def_id:
					off_defs.append(tid)
			var off_opps: Array[Dictionary] = []
			for opp in raw_opps:
				if int(opp["player_id"]) != carrier_id:
					off_opps.append(opp)
			var my_slot: int = off_defs.find(my_id)
			if my_slot >= 0 and not off_opps.is_empty():
				var picked: Dictionary = off_opps[my_slot % off_opps.size()]
				assigned_mark_id = int(picked["player_id"])
			else:
				assigned_mark_id = int(raw_opps[0]["player_id"])

		for opp in raw_opps:
			if int(opp["player_id"]) == assigned_mark_id:
				assigned_mark_pos = opp["position"]
				break

	var own_score: int = scores[my_team] if (my_team >= 0 and my_team < scores.size()) else 0
	var opp_score: int = scores[1 - my_team] if (my_team >= 0 and (1 - my_team) < scores.size()) else 0

	return {
		"tick": tick,
		"self": {
			"player_id": my_id,
			"team_id": my_team,
			"archetype_id": my_arch,
			"unique_skill_id": unique_skill_id,
			"position": my_pos,
			"velocity": my_vel,
			"facing_yaw": my_yaw,
			"is_grounded": my_grounded,
			"has_ball": my_has_ball,
			"is_ankle_broken": my_ankle_stun > 0.0,
			"stamina": my_stamina,
			"max_stamina": my_max_stamina,
			"is_exhausted": my_exhausted,
			"zone_energy": my_zone_energy,
			"zone_max": my_zone_max,
			"is_zone_active": my_zone_active,
			"can_activate_zone": my_can_zone,
			"is_charging_shot": my_charging,
			"is_layup_gather": my_layup,
			"is_dunking": my_dunking,
			"charge_time": my_charge_time,
			"optimal_charge_time": my_opt_charge,
			"three_point_range": my_3pt_range,
			"dunk_radius": my_dunk_radius,
			"pass_speed_mult": my_pass_mult,
			"block_radius": my_block_radius,
			"steal_radius": my_steal_radius,
			"is_in_stance": my_in_stance,
			"in_defense_recovery": my_def_recovery,
			"defensive_actions_locked": my_def_locked,
			"dribble_hand": my_drib_hand,
			"combo_cooldowns": combo_cooldowns.duplicate(true),
			"dist_to_target_rim": _dist_xz(my_pos, target_rim),
			"dist_to_defended_rim": _dist_xz(my_pos, defended_rim),
		},
		"target_rim": target_rim,
		"defended_rim": defended_rim,
		"match_seconds_left": match_secs,
		"shot_clock_left": shot_clock_left,
		"scores": scores,
		"score_diff": own_score - opp_score,
		"ball": {
			"exists": ball_exists,
			"position": ball_pos,
			"velocity": ball_vel,
			"state": ball_state,
			"is_reboundable": ball_reboundable,
			"carrier_id": carrier_id,
			"carrier_team": carrier_team,
			"carrier_pos": carrier_pos,
			"carrier_vel": carrier_vel,
			"carrier_is_charging_shot": carrier_charging,
			"carrier_is_dunking": carrier_dunking,
			"carrier_stamina": carrier_stamina,
			"carrier_has_steal_protection": carrier_steal_protected,
			"carrier_is_armored": carrier_armored,
			"dist_to_self": _dist_xz(my_pos, ball_pos),
		},
		"nearest_defender": {
			"player_id": nearest_def_id,
			"dist": nearest_def_dist,
			"position": nearest_def_pos,
			"is_in_stance": nearest_def_stance,
			"shot_contest_threat": shot_contest_threat,
			"defenders_in_paint": defenders_in_paint,
		},
		"teammates": raw_mates,
		"opponents": raw_opps,
		"defense_assignment": {
			"is_primary_on_ball": is_primary_defender,
			"assigned_mark_id": assigned_mark_id,
			"assigned_mark_pos": assigned_mark_pos,
			"primary_defender_beaten": primary_defender_beaten,
		},
	}


# ==============================================================================
# Pass-Lane & Spatial Geometry Helpers
# ==============================================================================

## Evaluates interception risk [0.0..1.0] along the XZ segment `from_pos -> to_pos`
## checking every opponent (with wider danger cone for defenders holding Defensive Stance).
static func compute_pass_lane_risk(from_pos: Vector3, to_pos: Vector3, opponents: Array) -> float:
	var seg_a := Vector2(from_pos.x, from_pos.z)
	var seg_b := Vector2(to_pos.x, to_pos.z)
	var ab: Vector2 = seg_b - seg_a
	var ab_len_sq: float = ab.length_squared()
	if ab_len_sq < 0.04:
		return 0.0

	var max_risk: float = 0.0
	for opp_var in opponents:
		if not (opp_var is Dictionary):
			continue
		var opp: Dictionary = opp_var
		var o_pos: Vector3 = opp.get("position", Vector3.ZERO)
		var p := Vector2(o_pos.x, o_pos.z)
		var t: float = clampf((p - seg_a).dot(ab) / ab_len_sq, 0.0, 1.0)
		# Ignore defenders far behind passer (< 0.06) or far behind receiver (> 0.96)
		if t < 0.05:
			continue
		var closest: Vector2 = seg_a + ab * t
		var perp_dist: float = p.distance_to(closest)
		var in_stance: bool = bool(opp.get("is_in_stance", false))
		var danger_radius: float = STANCE_PASS_LANE_RADIUS if in_stance else MOVING_PASS_LANE_RADIUS
		if perp_dist < danger_radius:
			var raw_risk: float = clampf(1.0 - (perp_dist / danger_radius), 0.0, 1.0)
			if in_stance:
				raw_risk = clampf(raw_risk * 1.25 + 0.15, 0.0, 1.0)
			if raw_risk > max_risk:
				max_risk = raw_risk
	return max_risk


static func point_to_segment_distance_xz(p: Vector3, a: Vector3, b: Vector3) -> float:
	var pa := Vector2(p.x - a.x, p.z - a.z)
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var len_sq: float = ab.length_squared()
	if len_sq < 1e-8:
		return pa.length()
	var t: float = clampf(pa.dot(ab) / len_sq, 0.0, 1.0)
	var proj := Vector2(a.x, a.z) + ab * t
	return Vector2(p.x, p.z).distance_to(proj)


static func _dist_xz(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)


static func _sort_by_player_id(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("player_id", 0)) < int(b.get("player_id", 0))


static func _get_game_state(tree: SceneTree) -> Node:
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("GameState")
