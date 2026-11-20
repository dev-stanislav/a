class_name HoopController
extends Node3D
## Regulation Hoop & Scoring Sensor Controller (HoopA / HoopB).
## Builds the mandatory 12-segment hollow rim collider (inner radius = 0.225m at y = 3.05m),
## tempered backboard (1.80m x 1.05m, bottom y = 2.90m, front face z = +0.375 local -> ±12.80 world),
## and validates UpperGate (y = 3.08) -> LowerGate (y = 2.86) downward passage within 0.60s.

signal basket_scored(
	hoop: Node3D,
	scoring_team: int,
	ball: Node3D,
	points: int,
	is_three: bool,
	scorer_id: int
)

const RIM_HEIGHT: float = 3.05
const RIM_INNER_RADIUS: float = 0.225
const RIM_TUBE_RADIUS: float = 0.010
const RIM_CENTERLINE_RADIUS: float = RIM_INNER_RADIUS + RIM_TUBE_RADIUS # 0.235m -> inner 0.225m
const RIM_SEGMENT_COUNT: int = 12

const BACKBOARD_WIDTH: float = 1.80
const BACKBOARD_HEIGHT: float = 1.05
const BACKBOARD_BOTTOM_Y: float = 2.90
const BACKBOARD_THICKNESS: float = 0.06
const BACKBOARD_FRONT_OFFSET_Z: float = 0.375 # 12.425 + 0.375 = 12.80m

const UPPER_GATE_Y: float = 3.08
const LOWER_GATE_Y: float = 2.86
const GATE_MAX_INTERVAL_SEC: float = 0.60
const GATE_RADIUS: float = 0.195

@export var hoop_id: String = "HoopA"
@export var defended_by_team: int = 0

var _elapsed_time: float = 0.0
# Per-ball tracking: ball_instance_id -> Dictionary
var _ball_gate_state: Dictionary = {}

@onready var rim_body: StaticBody3D = get_node_or_null("Rim")
@onready var backboard_body: StaticBody3D = get_node_or_null("Backboard")
@onready var upper_gate: Area3D = get_node_or_null("UpperGate")
@onready var lower_gate: Area3D = get_node_or_null("LowerGate")
@onready var net_verlet: NetVerlet = get_node_or_null("NetVerlet") as NetVerlet


func _enter_tree() -> void:
	_ensure_hollow_rim_segments()


func _ready() -> void:
	add_to_group("hoops")
	_ensure_hollow_rim_segments()
	_configure_backboard()
	_configure_support_structure()
	_configure_gates()


func get_rim_center() -> Vector3:
	if rim_body != null:
		return rim_body.global_position
	return global_transform * Vector3(0.0, RIM_HEIGHT, 0.0)


func get_attacking_team() -> int:
	return 1 - defended_by_team


func get_rim_segment_count() -> int:
	if rim_body == null:
		return 0
	var count: int = 0
	for child in rim_body.get_children():
		if child is CollisionShape3D:
			count += 1
	return count


func reset_hoop_state() -> void:
	_ball_gate_state.clear()
	if net_verlet != null:
		net_verlet.reset_net()


func _ensure_hollow_rim_segments() -> void:
	var r_body: StaticBody3D = get_node_or_null("Rim") as StaticBody3D
	if r_body == null:
		r_body = StaticBody3D.new()
		r_body.name = "Rim"
		r_body.position = Vector3(0.0, RIM_HEIGHT, 0.0)
		add_child(r_body)
	rim_body = r_body

	rim_body.position = Vector3(0.0, RIM_HEIGHT, 0.0)
	rim_body.collision_layer = 1
	rim_body.collision_mask = 0
	rim_body.add_to_group("rim")
	rim_body.set_meta("surface_type", "rim")
	rim_body.set_meta("restitution", 0.58)

	# Combined with ball bounce 0.78 -> absorbent 0.20 yields 0.78 - 0.20 = 0.58 rim restitution
	if rim_body.physics_material_override == null:
		var rim_phys := PhysicsMaterial.new()
		rim_phys.bounce = 0.20
		rim_phys.absorbent = true
		rim_phys.friction = 0.35
		rim_body.physics_material_override = rim_phys

	var existing_shapes: int = 0
	for child in rim_body.get_children():
		if child is CollisionShape3D:
			existing_shapes += 1

	if existing_shapes < RIM_SEGMENT_COUNT:
		for child in rim_body.get_children():
			if child is CollisionShape3D:
				child.queue_free()

		# Chord length at centerline R=0.235 for 30 deg = 2 * 0.235 * sin(PI/12) = 0.1216m
		var seg_capsule := CapsuleShape3D.new()
		seg_capsule.radius = RIM_TUBE_RADIUS
		seg_capsule.height = 0.136

		for i in range(RIM_SEGMENT_COUNT):
			var angle: float = float(i) * TAU / float(RIM_SEGMENT_COUNT)
			var seg := CollisionShape3D.new()
			seg.name = "RimSeg%d" % i
			seg.shape = seg_capsule
			var seg_pos := Vector3(
				cos(angle) * RIM_CENTERLINE_RADIUS,
				0.0,
				sin(angle) * RIM_CENTERLINE_RADIUS
			)
			var seg_basis: Basis = Basis(Vector3.UP, -angle) * Basis(Vector3.RIGHT, PI * 0.5)
			seg.transform = Transform3D(seg_basis, seg_pos)
			rim_body.add_child(seg)

	if rim_body.get_node_or_null("RimVisual") == null:
		var rim_vis := MeshInstance3D.new()
		rim_vis.name = "RimVisual"
		var torus := TorusMesh.new()
		torus.inner_radius = RIM_INNER_RADIUS
		torus.outer_radius = RIM_INNER_RADIUS + RIM_TUBE_RADIUS * 2.0
		torus.rings = 32
		torus.ring_segments = 12
		var rim_mat := StandardMaterial3D.new()
		rim_mat.albedo_color = Color(0.98, 0.30, 0.08, 1.0)
		rim_mat.metallic = 0.55
		rim_mat.roughness = 0.30
		rim_mat.emission_enabled = true
		rim_mat.emission = Color(0.98, 0.26, 0.06, 1.0)
		rim_mat.emission_energy_multiplier = 0.18
		torus.material = rim_mat
		rim_vis.mesh = torus
		rim_body.add_child(rim_vis)

		# Rim neck bracket connecting rim to backboard front face (z = +0.375)
		var neck := MeshInstance3D.new()
		neck.name = "RimBracket"
		var neck_box := BoxMesh.new()
		neck_box.size = Vector3(0.14, 0.05, 0.13)
		neck_box.material = rim_mat
		neck.mesh = neck_box
		neck.position = Vector3(0.0, -0.02, 0.305)
		rim_body.add_child(neck)


func _configure_backboard() -> void:
	if backboard_body == null:
		backboard_body = StaticBody3D.new()
		backboard_body.name = "Backboard"
		add_child(backboard_body)

	backboard_body.collision_layer = 1
	backboard_body.collision_mask = 0
	backboard_body.add_to_group("backboard")
	backboard_body.set_meta("surface_type", "backboard")
	backboard_body.set_meta("restitution", 0.65)

	# Combined with ball bounce 0.78 -> absorbent 0.13 yields 0.78 - 0.13 = 0.65 backboard restitution
	if backboard_body.physics_material_override == null:
		var bb_phys := PhysicsMaterial.new()
		bb_phys.bounce = 0.13
		bb_phys.absorbent = true
		bb_phys.friction = 0.30
		backboard_body.physics_material_override = bb_phys

	var bb_center := Vector3(
		0.0,
		BACKBOARD_BOTTOM_Y + BACKBOARD_HEIGHT * 0.5, # 3.425m -> bottom at 2.90m, top at 3.95m
		BACKBOARD_FRONT_OFFSET_Z + BACKBOARD_THICKNESS * 0.5 # 0.405m -> front plane at +0.375m (±12.80m world)
	)
	var bb_shape_node := backboard_body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if bb_shape_node == null:
		bb_shape_node = CollisionShape3D.new()
		bb_shape_node.name = "CollisionShape3D"
		var box := BoxShape3D.new()
		box.size = Vector3(BACKBOARD_WIDTH, BACKBOARD_HEIGHT, BACKBOARD_THICKNESS)
		bb_shape_node.shape = box
		backboard_body.add_child(bb_shape_node)
	bb_shape_node.position = bb_center

	if backboard_body.get_node_or_null("GlassVisual") == null:
		var glass := MeshInstance3D.new()
		glass.name = "GlassVisual"
		var glass_mesh := BoxMesh.new()
		glass_mesh.size = Vector3(BACKBOARD_WIDTH, BACKBOARD_HEIGHT, BACKBOARD_THICKNESS)
		var glass_mat := StandardMaterial3D.new()
		glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass_mat.albedo_color = Color(0.75, 0.88, 1.0, 0.32)
		glass_mat.roughness = 0.12
		glass_mat.metallic = 0.25
		glass_mesh.material = glass_mat
		glass.mesh = glass_mesh
		glass.position = bb_center
		backboard_body.add_child(glass)

		# Crisp white frame & shooter's target box on front face (z = +0.374)
		var line_mat := StandardMaterial3D.new()
		line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		line_mat.albedo_color = Color(0.96, 0.98, 1.0, 1.0)
		var front_z: float = BACKBOARD_FRONT_OFFSET_Z - 0.002

		# Outer border strips
		_add_frame_strip(backboard_body, "FrameTop", Vector3(BACKBOARD_WIDTH, 0.035, 0.006), Vector3(0.0, BACKBOARD_BOTTOM_Y + BACKBOARD_HEIGHT - 0.0175, front_z), line_mat)
		_add_frame_strip(backboard_body, "FrameBottom", Vector3(BACKBOARD_WIDTH, 0.035, 0.006), Vector3(0.0, BACKBOARD_BOTTOM_Y + 0.0175, front_z), line_mat)
		_add_frame_strip(backboard_body, "FrameLeft", Vector3(0.035, BACKBOARD_HEIGHT, 0.006), Vector3(-BACKBOARD_WIDTH * 0.5 + 0.0175, 3.425, front_z), line_mat)
		_add_frame_strip(backboard_body, "FrameRight", Vector3(0.035, BACKBOARD_HEIGHT, 0.006), Vector3(BACKBOARD_WIDTH * 0.5 - 0.0175, 3.425, front_z), line_mat)

		# Shooter's square (0.59m x 0.45m above rim)
		var sq_mat := StandardMaterial3D.new()
		sq_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sq_mat.albedo_color = (
			Color(0.25, 0.85, 1.0, 1.0)
			if defended_by_team == 0
			else Color(1.0, 0.35, 0.42, 1.0)
		)
		_add_frame_strip(backboard_body, "SqTop", Vector3(0.59, 0.03, 0.006), Vector3(0.0, 3.50, front_z), sq_mat)
		_add_frame_strip(backboard_body, "SqBot", Vector3(0.59, 0.03, 0.006), Vector3(0.0, 3.08, front_z), sq_mat)
		_add_frame_strip(backboard_body, "SqLeft", Vector3(0.03, 0.45, 0.006), Vector3(-0.28, 3.29, front_z), sq_mat)
		_add_frame_strip(backboard_body, "SqRight", Vector3(0.03, 0.45, 0.006), Vector3(0.28, 3.29, front_z), sq_mat)


func _add_frame_strip(parent: Node3D, node_name: String, sz: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var bm := BoxMesh.new()
	bm.size = sz
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)


func _configure_support_structure() -> void:
	var pole := get_node_or_null("SupportPole") as StaticBody3D
	if pole == null:
		pole = StaticBody3D.new()
		pole.name = "SupportPole"
		add_child(pole)
	pole.collision_layer = 1
	pole.collision_mask = 0
	pole.set_meta("surface_type", "stanchion")

	if pole.get_node_or_null("PoleMesh") != null:
		return

	var dark_mat := StandardMaterial3D.new()
	dark_mat.albedo_color = Color(0.11, 0.14, 0.22, 1.0)
	dark_mat.metallic = 0.45
	dark_mat.roughness = 0.42

	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = (
		Color(0.10, 0.42, 0.85, 1.0)
		if defended_by_team == 0
		else Color(0.82, 0.16, 0.24, 1.0)
	)
	pad_mat.roughness = 0.65

	# Stanchion base & upright safely behind baseline (local z = +1.70 -> world ±14.125m)
	var upright_col := CollisionShape3D.new()
	upright_col.name = "PoleCollision"
	var upright_box := BoxShape3D.new()
	upright_box.size = Vector3(0.38, 3.60, 0.38)
	upright_col.shape = upright_box
	upright_col.position = Vector3(0.0, 1.80, 1.72)
	pole.add_child(upright_col)

	var pole_mesh := MeshInstance3D.new()
	pole_mesh.name = "PoleMesh"
	var p_bm := BoxMesh.new()
	p_bm.size = Vector3(0.28, 3.65, 0.28)
	p_bm.material = dark_mat
	pole_mesh.mesh = p_bm
	pole_mesh.position = Vector3(0.0, 1.825, 1.72)
	pole.add_child(pole_mesh)

	var pad_mesh := MeshInstance3D.new()
	pad_mesh.name = "SafetyPadding"
	var pad_bm := BoxMesh.new()
	pad_bm.size = Vector3(0.42, 2.10, 0.42)
	pad_bm.material = pad_mat
	pad_mesh.mesh = pad_bm
	pad_mesh.position = Vector3(0.0, 1.05, 1.72)
	pole.add_child(pad_mesh)

	var arm_mesh := MeshInstance3D.new()
	arm_mesh.name = "BoomArm"
	var arm_bm := BoxMesh.new()
	arm_bm.size = Vector3(0.22, 0.22, 1.35)
	arm_bm.material = dark_mat
	arm_mesh.mesh = arm_bm
	arm_mesh.position = Vector3(0.0, 3.45, 1.08)
	pole.add_child(arm_mesh)


func _configure_gates() -> void:
	if upper_gate == null:
		upper_gate = Area3D.new()
		upper_gate.name = "UpperGate"
		add_child(upper_gate)
	upper_gate.position = Vector3(0.0, UPPER_GATE_Y, 0.0)
	upper_gate.collision_layer = 0
	upper_gate.collision_mask = 1 | 4
	upper_gate.monitoring = true
	upper_gate.monitorable = false
	if upper_gate.get_node_or_null("CollisionShape3D") == null:
		var cs := CollisionShape3D.new()
		cs.name = "CollisionShape3D"
		var cyl := CylinderShape3D.new()
		cyl.height = 0.05
		cyl.radius = GATE_RADIUS
		cs.shape = cyl
		upper_gate.add_child(cs)
	if not upper_gate.body_entered.is_connected(_on_upper_gate_body_entered):
		upper_gate.body_entered.connect(_on_upper_gate_body_entered)

	if lower_gate == null:
		lower_gate = Area3D.new()
		lower_gate.name = "LowerGate"
		add_child(lower_gate)
	lower_gate.position = Vector3(0.0, LOWER_GATE_Y, 0.0)
	lower_gate.collision_layer = 0
	lower_gate.collision_mask = 1 | 4
	lower_gate.monitoring = true
	lower_gate.monitorable = false
	if lower_gate.get_node_or_null("CollisionShape3D") == null:
		var cs_low := CollisionShape3D.new()
		cs_low.name = "CollisionShape3D"
		var cyl_low := CylinderShape3D.new()
		cyl_low.height = 0.05
		cyl_low.radius = GATE_RADIUS
		cs_low.shape = cyl_low
		lower_gate.add_child(cs_low)
	if not lower_gate.body_entered.is_connected(_on_lower_gate_body_entered):
		lower_gate.body_entered.connect(_on_lower_gate_body_entered)


func _physics_process(delta: float) -> void:
	var dt: float = delta if delta > 0.0 else (1.0 / 60.0)
	_elapsed_time += dt
	_step_continuous_gate_tracking()


func _is_basketball_body(body: Node) -> bool:
	if body == null:
		return false
	return (
		body.is_in_group("basketball")
		or body is Basketball
		or (body is RigidBody3D and body.name.to_lower().contains("ball"))
	)


func _get_ball_velocity(body: Node3D) -> Vector3:
	if body is RigidBody3D:
		return (body as RigidBody3D).linear_velocity
	return Vector3.ZERO


func _get_or_create_ball_entry(ball: Node3D) -> Dictionary:
	var bid: int = ball.get_instance_id()
	if not _ball_gate_state.has(bid):
		_ball_gate_state[bid] = {
			"ball": ball,
			"upper_armed": false,
			"upper_time": -100.0,
			"under_rim_invalidated": false,
			"invalid_time": -100.0,
			"last_scored_time": -100.0,
			"prev_pos": ball.global_position,
		}
	return _ball_gate_state[bid]


func _check_teleport_reset(ball: Node3D, entry: Dictionary) -> bool:
	var curr_pos: Vector3 = ball.global_position
	var prev_pos: Vector3 = entry["prev_pos"]
	if curr_pos.distance_to(prev_pos) > 0.55:
		entry["upper_armed"] = false
		entry["under_rim_invalidated"] = false
		entry["prev_pos"] = curr_pos
		return true
	return false


func _on_upper_gate_body_entered(body: Node) -> void:
	if not _is_basketball_body(body):
		return
	var ball := body as Node3D
	var entry: Dictionary = _get_or_create_ball_entry(ball)
	_check_teleport_reset(ball, entry)
	var vel: Vector3 = _get_ball_velocity(ball)
	var upper_y: float = upper_gate.global_position.y

	if vel.y > 0.05:
		entry["under_rim_invalidated"] = true
		entry["invalid_time"] = _elapsed_time
		entry["upper_armed"] = false
		return

	if bool(entry["under_rim_invalidated"]):
		return

	if vel.y < 0.0 and ball.global_position.y >= upper_y - 0.16:
		entry["upper_armed"] = true
		entry["upper_time"] = _elapsed_time


func _on_lower_gate_body_entered(body: Node) -> void:
	if not _is_basketball_body(body):
		return
	var ball := body as Node3D
	var entry: Dictionary = _get_or_create_ball_entry(ball)
	_check_teleport_reset(ball, entry)
	var vel: Vector3 = _get_ball_velocity(ball)

	# Upward pass from underneath the rim invalidates this upward-and-downward flight
	if vel.y > 0.05:
		entry["under_rim_invalidated"] = true
		entry["invalid_time"] = _elapsed_time
		entry["upper_armed"] = false
		return

	if bool(entry["under_rim_invalidated"]):
		return

	_try_complete_score(ball, entry, vel)


func _step_continuous_gate_tracking() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var rim_c: Vector3 = get_rim_center()
	var upper_y: float = upper_gate.global_position.y if upper_gate != null else (rim_c.y + 0.03)
	var lower_y: float = lower_gate.global_position.y if lower_gate != null else (rim_c.y - 0.19)

	for node in tree.get_nodes_in_group("basketball"):
		if not (node is Node3D):
			continue
		var ball := node as Node3D
		var entry: Dictionary = _get_or_create_ball_entry(ball)
		if _check_teleport_reset(ball, entry):
			continue

		var prev_pos: Vector3 = entry["prev_pos"]
		var curr_pos: Vector3 = ball.global_position
		var vel: Vector3 = _get_ball_velocity(ball)
		var dist_xz: float = Vector2(curr_pos.x - rim_c.x, curr_pos.z - rim_c.z).length()

		# Clear under-rim violation once ball drops completely clear below hoop or exits cylinder horizontally
		if bool(entry["under_rim_invalidated"]):
			if (curr_pos.y < lower_y - 0.24 and vel.y <= 0.0) or dist_xz > 0.42 or (_elapsed_time - float(entry["invalid_time"])) > 5.0:
				entry["under_rim_invalidated"] = false

		if dist_xz <= RIM_INNER_RADIUS:
			# Detect upward crossing of LowerGate or UpperGate from below
			if ((prev_pos.y < lower_y and curr_pos.y >= lower_y) or (prev_pos.y < upper_y and curr_pos.y >= upper_y)) and vel.y > 0.0:
				entry["under_rim_invalidated"] = true
				entry["invalid_time"] = _elapsed_time
				entry["upper_armed"] = false
			elif not bool(entry["under_rim_invalidated"]) and vel.y < 0.0:
				# Swept downward crossing of UpperGate (3.08)
				if prev_pos.y >= upper_y and curr_pos.y <= upper_y:
					entry["upper_armed"] = true
					entry["upper_time"] = _elapsed_time
				# Swept downward crossing of LowerGate (2.86)
				if prev_pos.y >= lower_y and curr_pos.y <= lower_y:
					_try_complete_score(ball, entry, vel)

		entry["prev_pos"] = curr_pos


func _try_complete_score(ball: Node3D, entry: Dictionary, vel: Vector3) -> void:
	if not bool(entry["upper_armed"]):
		return
	if vel.y >= 0.0:
		return

	var dt_gates: float = _elapsed_time - float(entry["upper_time"])
	if dt_gates < 0.0 or dt_gates > GATE_MAX_INTERVAL_SEC:
		entry["upper_armed"] = false
		return

	# Prevent duplicate trigger on the same pass
	if (_elapsed_time - float(entry["last_scored_time"])) < 0.35:
		entry["upper_armed"] = false
		return

	entry["upper_armed"] = false
	entry["last_scored_time"] = _elapsed_time

	if net_verlet != null:
		net_verlet.apply_swish_impulse(1.25)

	var rim_c: Vector3 = get_rim_center()
	var scoring_team: int = get_attacking_team()
	var scorer_id: int = -1
	var shot_pos: Vector3 = ball.global_position
	var is_three: bool = false

	if ball is Basketball:
		var bball := ball as Basketball
		scorer_id = bball.last_shooter_id
		if bball.has_valid_shot_origin:
			shot_pos = bball.last_shot_pos
			var dist_xz: float = Vector2(shot_pos.x, shot_pos.z).distance_to(Vector2(rim_c.x, rim_c.z))
			is_three = (dist_xz > 6.75) or (absf(shot_pos.x) > 6.60)
		else:
			var drop_dist_xz: float = Vector2(shot_pos.x, shot_pos.z).distance_to(Vector2(rim_c.x, rim_c.z))
			is_three = (drop_dist_xz > 6.75) or (absf(shot_pos.x) > 6.60)
		if bball.ball_state == Basketball.BallState.SHOT_FLIGHT:
			bball.ball_state = Basketball.BallState.FREE
			bball.has_valid_shot_origin = false

	var points: int = 3 if is_three else 2
	basket_scored.emit(self, scoring_team, ball, points, is_three, scorer_id)
