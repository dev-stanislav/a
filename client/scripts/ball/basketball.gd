class_name Basketball
extends RigidBody3D
## Canonical 60 Hz Basketball simulation with bounce restitution, air drag, Magnus spin,
## state machine (FREE, HELD, DRIBBLING, PASS_FLIGHT, SHOT_FLIGHT, DUNK_LOCKED),
## rebound readiness, teammate pass tracking, and EventBus possession/bounce signals.

enum BallState {
	FREE = 0,
	HELD = 1,
	DRIBBLING = 2,
	PASS_FLIGHT = 3,
	SHOT_FLIGHT = 4,
	DUNK_LOCKED = 5,
}

const BALL_RADIUS: float = 0.12
const BALL_MASS: float = 0.62
const GRAVITY_ACCEL: float = 9.81
const FLOOR_BOUNCE: float = 0.78
const RIM_BOUNCE: float = 0.58
const BACKBOARD_BOUNCE: float = 0.65

const AIR_DRAG_COEFF: float = 0.0045
const MAGNUS_COEFF: float = 0.00042

const LAYER_WORLD: int = 1
const LAYER_PLAYER: int = 2
const LAYER_BALL: int = 4

var ball_state: BallState = BallState.FREE
var carrier: Node3D = null
var carrier_player_id: int = -1
var carrier_team_id: int = -1

# Shot / pass / rebound provenance
var has_valid_shot_origin: bool = false
var is_reboundable: bool = false
var last_shot_pos: Vector3 = Vector3.ZERO
var last_target_rim: Vector3 = Vector3.ZERO
var last_shooter_id: int = -1
var last_shooter_team: int = -1
var last_shot_is_three: bool = false
var last_touch_player_id: int = -1
var last_touch_team_id: int = -1

# Pass targeting
var pass_target_player: Node3D = null
var last_passer_node: Node3D = null
var last_passer_id: int = -1
var last_passer_team: int = -1

# Pickup & collision exception management
var pickup_lockout_timer: float = 0.0
var _lockout_owner: Node3D = null
var _exception_body: PhysicsBody3D = null
var _exception_timer: float = 0.0
var _prev_linear_vel: Vector3 = Vector3.ZERO
var _bounce_signal_cooldown: float = 0.0
var ribbon_trail: RibbonTrail3D = null
var _trail_registered_with_vfx: bool = false

@onready var visual_root: Node3D = get_node_or_null("BallVisual")


func _ready() -> void:
	add_to_group("basketball")
	mass = BALL_MASS
	var default_grav: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	if default_grav > 0.001:
		gravity_scale = GRAVITY_ACCEL / default_grav
	else:
		gravity_scale = 1.0

	# Must remain false so GodotPhysics3D preserves exact 0.78 floor restitution
	continuous_cd = false
	contact_monitor = true
	max_contacts_reported = 8
	can_sleep = false
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.25

	if physics_material_override == null:
		var mat := PhysicsMaterial.new()
		mat.bounce = FLOOR_BOUNCE
		mat.friction = 0.55
		physics_material_override = mat
	else:
		physics_material_override.bounce = FLOOR_BOUNCE

	_build_visual_details()
	_ensure_ribbon_trail()
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

	_apply_physics_mode_for_state()


func get_ribbon_trail() -> RibbonTrail3D:
	_ensure_ribbon_trail()
	return ribbon_trail


func _ensure_ribbon_trail() -> void:
	if ribbon_trail == null or not is_instance_valid(ribbon_trail):
		ribbon_trail = get_node_or_null("RibbonTrail3D") as RibbonTrail3D
	if is_inside_tree() and get_tree() != null:
		var vfx := get_tree().get_first_node_in_group("vfx_manager") as VFXManager
		if vfx != null:
			var cur_col: Color = ribbon_trail.get_trail_color() if ribbon_trail != null else Color(1.0, 0.58, 0.16, 1.0)
			ribbon_trail = vfx.attach_trail_to_node(self, cur_col, 0.20)
			_trail_registered_with_vfx = true
	if ribbon_trail == null:
		ribbon_trail = RibbonTrail3D.new()
		ribbon_trail.name = "RibbonTrail3D"
		add_child(ribbon_trail)
		ribbon_trail.set_target_node(self)
		ribbon_trail.set_trail_color(Color(1.0, 0.58, 0.16, 1.0))
		ribbon_trail.set_width(0.20)
		ribbon_trail.set_emitting(false)


func _build_visual_details() -> void:
	if visual_root == null:
		visual_root = Node3D.new()
		visual_root.name = "BallVisual"
		add_child(visual_root)

	if visual_root.get_child_count() > 0:
		return

	var sphere_inst := MeshInstance3D.new()
	sphere_inst.name = "OrangeSphere"
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = BALL_RADIUS
	sphere_mesh.height = BALL_RADIUS * 2.0
	sphere_mesh.radial_segments = 24
	sphere_mesh.rings = 16
	var orange_mat := StandardMaterial3D.new()
	orange_mat.albedo_color = Color(0.93, 0.42, 0.11, 1.0)
	orange_mat.roughness = 0.62
	orange_mat.metallic = 0.05
	sphere_mesh.material = orange_mat
	sphere_inst.mesh = sphere_mesh
	visual_root.add_child(sphere_inst)

	var seam_mat := StandardMaterial3D.new()
	seam_mat.albedo_color = Color(0.11, 0.09, 0.08, 1.0)
	seam_mat.roughness = 0.85
	var seam_rotations: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(PI * 0.5, 0.0, 0.0),
		Vector3(0.0, 0.0, PI * 0.5),
	]
	for i in range(seam_rotations.size()):
		var seam := MeshInstance3D.new()
		seam.name = "Seam%d" % i
		var torus := TorusMesh.new()
		torus.inner_radius = BALL_RADIUS - 0.0025
		torus.outer_radius = BALL_RADIUS + 0.0025
		torus.rings = 24
		torus.ring_segments = 8
		torus.material = seam_mat
		seam.mesh = torus
		seam.rotation = seam_rotations[i]
		visual_root.add_child(seam)


func _physics_process(delta: float) -> void:
	var dt: float = delta if delta > 0.0 else (1.0 / 60.0)
	if pickup_lockout_timer > 0.0:
		pickup_lockout_timer = maxf(0.0, pickup_lockout_timer - dt)
		if pickup_lockout_timer <= 0.0:
			_lockout_owner = null
	if _bounce_signal_cooldown > 0.0:
		_bounce_signal_cooldown = maxf(0.0, _bounce_signal_cooldown - dt)

	if _exception_body != null:
		_exception_timer -= dt
		if _exception_timer <= 0.0:
			if is_instance_valid(_exception_body):
				remove_collision_exception_with(_exception_body)
			_exception_body = null

	if not _trail_registered_with_vfx:
		_ensure_ribbon_trail()

	if not freeze:
		_apply_aerodynamics()
		_prev_linear_vel = linear_velocity
		if ribbon_trail != null and is_instance_valid(ribbon_trail):
			var should_emit: bool = (
				ball_state == BallState.SHOT_FLIGHT
				or ball_state == BallState.PASS_FLIGHT
				or (ball_state == BallState.FREE and linear_velocity.length_squared() > 36.0)
			)
			ribbon_trail.set_emitting(should_emit)
			if should_emit:
				ribbon_trail.sample_point(global_position, 0.0)
		if global_position.y < -4.0:
			reset_to_free(Vector3(0.0, 1.2, 0.0))


func _apply_aerodynamics() -> void:
	var v: Vector3 = linear_velocity
	var speed_sq: float = v.length_squared()
	if speed_sq > 6.25:
		var speed: float = sqrt(speed_sq)
		var drag_force: Vector3 = -v * (AIR_DRAG_COEFF * speed)
		apply_central_force(drag_force)

	if angular_velocity.length_squared() > 0.01 and speed_sq > 0.25:
		var magnus_force: Vector3 = angular_velocity.cross(v) * MAGNUS_COEFF
		apply_central_force(magnus_force)


func _on_body_entered(body: Node) -> void:
	if freeze or body == null:
		return

	var surface_type: String = "court"
	if has_meta("block_resistance"):
		set_meta("block_resistance", 0.0)
	if body.is_in_group("rim") or body.get_meta("surface_type", "") == "rim":
		surface_type = "rim"
		if ball_state == BallState.SHOT_FLIGHT:
			# Shot bounced off rim -> transitions to FREE for live rebounds while keeping last_shot_pos for shooter's roll!
			ball_state = BallState.FREE
			is_reboundable = true
			pickup_lockout_timer = 0.0
			_lockout_owner = null
		elif ball_state == BallState.PASS_FLIGHT:
			ball_state = BallState.FREE
	elif body.is_in_group("backboard") or body.get_meta("surface_type", "") == "backboard":
		surface_type = "backboard"
		if ball_state == BallState.SHOT_FLIGHT:
			# Shot bounced off backboard -> FREE for live rebounds while keeping last_shot_pos for bank shots!
			ball_state = BallState.FREE
			is_reboundable = true
			pickup_lockout_timer = 0.0
			_lockout_owner = null
		elif ball_state == BallState.PASS_FLIGHT:
			ball_state = BallState.FREE
	elif body.is_in_group("players"):
		surface_type = "player"
		if ball_state == BallState.PASS_FLIGHT:
			var body_team: Variant = body.get("team_id")
			if (
				body_team != null
				and last_touch_team_id >= 0
				and int(body_team) != last_touch_team_id
				and body.has_method("try_pass_lane_interception")
			):
				if bool(body.call("try_pass_lane_interception", self)):
					return
			ball_state = BallState.FREE
		elif ball_state == BallState.SHOT_FLIGHT:
			ball_state = BallState.FREE
			is_reboundable = true
	else:
		surface_type = str(body.get_meta("surface_type", "court"))
		if surface_type == "court":
			if ball_state == BallState.SHOT_FLIGHT or ball_state == BallState.PASS_FLIGHT:
				ball_state = BallState.FREE
			has_valid_shot_origin = false

	var impact_speed: float = maxf(_prev_linear_vel.length(), linear_velocity.length())
	if impact_speed > 0.45 and _bounce_signal_cooldown <= 0.0:
		_bounce_signal_cooldown = 0.04
		EventBus.ball_bounced.emit(global_position, impact_speed, surface_type)


func get_ball_state() -> BallState:
	return ball_state


func get_state_name() -> String:
	match ball_state:
		BallState.FREE:
			return "FREE"
		BallState.HELD:
			return "HELD"
		BallState.DRIBBLING:
			return "DRIBBLING"
		BallState.PASS_FLIGHT:
			return "PASS_FLIGHT"
		BallState.SHOT_FLIGHT:
			return "SHOT_FLIGHT"
		BallState.DUNK_LOCKED:
			return "DUNK_LOCKED"
	return "FREE"


func is_loose() -> bool:
	return ball_state == BallState.FREE or ball_state == BallState.PASS_FLIGHT


func is_opponent_pass_for_team(check_team_id: int) -> bool:
	if ball_state != BallState.PASS_FLIGHT:
		return false
	var origin_team: int = last_passer_team if last_passer_team >= 0 else last_touch_team_id
	return origin_team >= 0 and origin_team != check_team_id


func can_be_picked_up_by(player: Node3D) -> bool:
	if player == null:
		return false
	if (
		ball_state == BallState.HELD
		or ball_state == BallState.DRIBBLING
		or ball_state == BallState.DUNK_LOCKED
	):
		return false
	if pickup_lockout_timer > 0.0 and player == _lockout_owner:
		return false
	if ball_state == BallState.SHOT_FLIGHT:
		return false
	return true


func set_controlled_state(
	new_state: BallState,
	holder: Node3D,
	player_id: int,
	team_id: int,
	emit_possession: bool = true
) -> void:
	var holder_changed: bool = (carrier != holder) or (carrier_player_id != player_id) or (carrier_team_id != team_id)
	ball_state = new_state
	carrier = holder
	carrier_player_id = player_id
	carrier_team_id = team_id
	last_touch_player_id = player_id
	last_touch_team_id = team_id
	pass_target_player = null
	last_passer_node = null
	last_passer_id = -1
	last_passer_team = -1
	has_valid_shot_origin = false
	is_reboundable = false
	pickup_lockout_timer = 0.0
	_lockout_owner = null
	if ribbon_trail != null and is_instance_valid(ribbon_trail):
		ribbon_trail.set_emitting(false)
	_apply_physics_mode_for_state()

	if emit_possession and holder_changed and player_id >= 0 and team_id >= 0:
		if GameState.possession_team != team_id or GameState.ball_carrier_id != player_id:
			GameState.set_possession(team_id, player_id)


func update_controlled_transform(world_pos: Vector3, spin_delta: Vector3 = Vector3.ZERO) -> void:
	global_position = world_pos
	if visual_root != null and spin_delta.length_squared() > 0.000001:
		var axis: Vector3 = spin_delta.normalized()
		visual_root.rotate(axis, spin_delta.length())


func launch_shot(
	shooter: Node3D,
	shooter_id: int,
	shooter_team: int,
	release_pos: Vector3,
	shot_origin_floor_pos: Vector3,
	target_rim: Vector3,
	initial_vel: Vector3,
	spin_vel: Vector3,
	is_three: bool
) -> void:
	_clear_carrier_with_exception(shooter, 0.26)
	ball_state = BallState.SHOT_FLIGHT
	has_valid_shot_origin = true
	is_reboundable = false
	last_shot_pos = shot_origin_floor_pos
	last_target_rim = target_rim
	last_shooter_id = shooter_id
	last_shooter_team = shooter_team
	last_shot_is_three = is_three
	last_touch_player_id = shooter_id
	last_touch_team_id = shooter_team
	pickup_lockout_timer = 0.30
	_lockout_owner = shooter

	_apply_physics_mode_for_state()
	global_position = release_pos
	linear_velocity = initial_vel
	angular_velocity = spin_vel
	_prev_linear_vel = initial_vel
	_ensure_ribbon_trail()
	if ribbon_trail != null:
		ribbon_trail.clear_trail()
		ribbon_trail.set_emitting(true)
		ribbon_trail.sample_point(release_pos, 0.0)


func launch_dunk_drop(
	dunker: Node3D,
	dunker_id: int,
	dunker_team: int,
	rim_center: Vector3,
	slam_speed: float = 9.0
) -> void:
	_clear_carrier_with_exception(dunker, 0.32)
	ball_state = BallState.SHOT_FLIGHT
	has_valid_shot_origin = true
	is_reboundable = false
	last_shot_pos = Vector3(rim_center.x, 0.0, rim_center.z)
	last_target_rim = rim_center
	last_shooter_id = dunker_id
	last_shooter_team = dunker_team
	last_shot_is_three = false
	last_touch_player_id = dunker_id
	last_touch_team_id = dunker_team
	pickup_lockout_timer = 0.32
	_lockout_owner = dunker

	_apply_physics_mode_for_state()
	global_position = Vector3(rim_center.x, rim_center.y + 0.36, rim_center.z)
	linear_velocity = Vector3(0.0, -absf(slam_speed), 0.0)
	angular_velocity = Vector3(6.0, 0.0, 0.0)
	_prev_linear_vel = linear_velocity


func launch_pass(
	passer: Node3D,
	passer_id: int,
	passer_team: int,
	release_pos: Vector3,
	initial_vel: Vector3,
	target_teammate: Node3D = null
) -> void:
	_clear_carrier_with_exception(passer, 0.24)
	ball_state = BallState.PASS_FLIGHT
	has_valid_shot_origin = false
	is_reboundable = false
	pass_target_player = target_teammate
	last_passer_node = passer
	last_passer_id = passer_id
	last_passer_team = passer_team
	last_touch_player_id = passer_id
	last_touch_team_id = passer_team
	pickup_lockout_timer = 0.26
	_lockout_owner = passer

	_apply_physics_mode_for_state()
	global_position = release_pos
	linear_velocity = initial_vel
	angular_velocity = Vector3(0.0, 4.0, 0.0)
	_prev_linear_vel = initial_vel
	_ensure_ribbon_trail()
	if ribbon_trail != null:
		ribbon_trail.clear_trail()
		ribbon_trail.set_trail_color(Color(0.25, 0.90, 1.0, 1.0))
		ribbon_trail.set_width(0.18)
		ribbon_trail.set_emitting(true)
		ribbon_trail.sample_point(release_pos, 0.0)


func drop_free(release_pos: Vector3, impulse_vel: Vector3 = Vector3.ZERO, ex_body: Node3D = null) -> void:
	_clear_carrier_with_exception(ex_body, 0.22)
	ball_state = BallState.FREE
	has_valid_shot_origin = false
	is_reboundable = true
	pass_target_player = null
	last_passer_node = null
	last_passer_id = -1
	last_passer_team = -1
	pickup_lockout_timer = 0.22
	_lockout_owner = ex_body

	_apply_physics_mode_for_state()
	global_position = release_pos
	linear_velocity = impulse_vel
	angular_velocity = Vector3.ZERO
	_prev_linear_vel = impulse_vel


func reset_to_free(spawn_pos: Vector3) -> void:
	if _exception_body != null and is_instance_valid(_exception_body):
		remove_collision_exception_with(_exception_body)
	_exception_body = null
	_exception_timer = 0.0

	carrier = null
	carrier_player_id = -1
	carrier_team_id = -1
	pass_target_player = null
	last_passer_node = null
	last_passer_id = -1
	last_passer_team = -1
	has_valid_shot_origin = false
	is_reboundable = false
	last_shooter_id = -1
	last_shooter_team = -1
	last_shot_is_three = false
	last_touch_player_id = -1
	last_touch_team_id = -1
	pickup_lockout_timer = 0.0
	_lockout_owner = null
	ball_state = BallState.FREE

	global_transform = Transform3D(Basis.IDENTITY, spawn_pos)
	_apply_physics_mode_for_state()
	global_transform = Transform3D(Basis.IDENTITY, spawn_pos)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_prev_linear_vel = Vector3.ZERO
	if ribbon_trail != null and is_instance_valid(ribbon_trail):
		ribbon_trail.set_emitting(false)
		ribbon_trail.clear_trail()
	if is_inside_tree():
		PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis.IDENTITY, spawn_pos))
		PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)


func export_sim_state() -> Dictionary:
	return {
		"state": int(ball_state),
		"position": global_position,
		"linear_velocity": linear_velocity,
		"angular_velocity": angular_velocity,
		"carrier_player_id": carrier_player_id,
		"carrier_team_id": carrier_team_id,
		"has_valid_shot_origin": has_valid_shot_origin,
		"is_reboundable": is_reboundable,
		"last_shot_pos": last_shot_pos,
		"last_target_rim": last_target_rim,
		"last_shooter_id": last_shooter_id,
		"last_shooter_team": last_shooter_team,
		"last_shot_is_three": last_shot_is_three,
		"last_touch_player_id": last_touch_player_id,
		"last_touch_team_id": last_touch_team_id,
		"last_passer_id": last_passer_id,
		"last_passer_team": last_passer_team,
	}


func import_sim_state(state_dict: Dictionary) -> void:
	ball_state = int(state_dict.get("state", int(BallState.FREE))) as BallState
	carrier_player_id = int(state_dict.get("carrier_player_id", -1))
	carrier_team_id = int(state_dict.get("carrier_team_id", -1))
	has_valid_shot_origin = bool(state_dict.get("has_valid_shot_origin", false))
	is_reboundable = bool(state_dict.get("is_reboundable", false))
	last_shot_pos = state_dict.get("last_shot_pos", Vector3.ZERO)
	last_target_rim = state_dict.get("last_target_rim", Vector3.ZERO)
	last_shooter_id = int(state_dict.get("last_shooter_id", -1))
	last_shooter_team = int(state_dict.get("last_shooter_team", -1))
	last_shot_is_three = bool(state_dict.get("last_shot_is_three", false))
	last_touch_player_id = int(state_dict.get("last_touch_player_id", last_touch_player_id))
	last_touch_team_id = int(state_dict.get("last_touch_team_id", last_touch_team_id))
	last_passer_id = int(state_dict.get("last_passer_id", -1))
	last_passer_team = int(state_dict.get("last_passer_team", -1))
	_apply_physics_mode_for_state()
	global_position = state_dict.get("position", global_position)
	if not freeze:
		linear_velocity = state_dict.get("linear_velocity", Vector3.ZERO)
		angular_velocity = state_dict.get("angular_velocity", Vector3.ZERO)


func _clear_carrier_with_exception(ex_node: Node3D, duration: float) -> void:
	if _exception_body != null and is_instance_valid(_exception_body):
		remove_collision_exception_with(_exception_body)
		_exception_body = null

	if ex_node is PhysicsBody3D:
		_exception_body = ex_node as PhysicsBody3D
		add_collision_exception_with(_exception_body)
		_exception_timer = duration

	carrier = null
	carrier_player_id = -1
	carrier_team_id = -1


func _apply_physics_mode_for_state() -> void:
	var controlled: bool = (
		ball_state == BallState.HELD
		or ball_state == BallState.DRIBBLING
		or ball_state == BallState.DUNK_LOCKED
	)
	if controlled:
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true
		collision_layer = 0
		collision_mask = 0
	else:
		freeze = false
		collision_layer = LAYER_BALL
		collision_mask = LAYER_WORLD | LAYER_PLAYER
