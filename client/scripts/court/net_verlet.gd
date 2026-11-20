class_name NetVerlet
extends MeshInstance3D
## Real-time 3D Verlet basketball net suspended from the hollow rim (r = 0.225m).
## Reacts dynamically to basketball passage, rim vibrations, and swishes at 60 Hz.

const RING_SEGMENTS: int = 12
const RING_COUNT: int = 5
const TOP_RADIUS: float = 0.225
const BOTTOM_RADIUS: float = 0.115
const NET_LENGTH: float = 0.42
const GRAVITY: float = 9.81
const DAMPING: float = 0.968
const SOLVER_ITERATIONS: int = 4

var _positions: PackedVector3Array = PackedVector3Array()
var _prev_positions: PackedVector3Array = PackedVector3Array()
var _pinned: PackedByteArray = PackedByteArray()
var _constraints: Array[Dictionary] = []
var _imm_mesh: ImmediateMesh = null
var _net_material: StandardMaterial3D = null


func _ready() -> void:
	_imm_mesh = ImmediateMesh.new()
	mesh = _imm_mesh

	_net_material = StandardMaterial3D.new()
	_net_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_net_material.albedo_color = Color(0.92, 0.96, 1.0, 1.0)
	_net_material.vertex_color_use_as_albedo = true
	material_override = _net_material

	reset_net()


func reset_net() -> void:
	_positions.clear()
	_prev_positions.clear()
	_pinned.clear()
	_constraints.clear()

	for r in range(RING_COUNT):
		var t: float = float(r) / float(RING_COUNT - 1)
		var ring_radius: float = lerpf(TOP_RADIUS, BOTTOM_RADIUS, pow(t, 0.85))
		var y: float = -t * NET_LENGTH
		var angle_offset: float = (PI / float(RING_SEGMENTS)) if (r % 2 == 1) else 0.0

		for s in range(RING_SEGMENTS):
			var angle: float = (float(s) * TAU / float(RING_SEGMENTS)) + angle_offset
			var local_pos := Vector3(cos(angle) * ring_radius, y, sin(angle) * ring_radius)
			_positions.append(local_pos)
			_prev_positions.append(local_pos)
			_pinned.append(1 if r == 0 else 0)

	# Build diamond-mesh structural & ring constraints
	for r in range(RING_COUNT):
		for s in range(RING_SEGMENTS):
			var idx: int = r * RING_SEGMENTS + s
			var next_s: int = r * RING_SEGMENTS + ((s + 1) % RING_SEGMENTS)
			if r > 0:
				_add_constraint(idx, next_s, 1.0)

			if r < RING_COUNT - 1:
				var lower_a: int = (r + 1) * RING_SEGMENTS + s
				var lower_b: int = (r + 1) * RING_SEGMENTS + ((s + RING_SEGMENTS - (1 if r % 2 == 0 else 0)) % RING_SEGMENTS)
				if r % 2 == 1:
					lower_b = (r + 1) * RING_SEGMENTS + ((s + 1) % RING_SEGMENTS)
				_add_constraint(idx, lower_a, 1.0)
				if lower_b != lower_a:
					_add_constraint(idx, lower_b, 1.0)

	_rebuild_mesh()


func _add_constraint(a: int, b: int, stiffness: float) -> void:
	var rest_len: float = _positions[a].distance_to(_positions[b])
	_constraints.append({
		"a": a,
		"b": b,
		"rest": rest_len,
		"stiffness": stiffness,
	})


func apply_swish_impulse(strength: float = 1.0) -> void:
	var count: int = _positions.size()
	for i in range(count):
		if _pinned[i] != 0:
			continue
		var p: Vector3 = _positions[i]
		var radial := Vector3(p.x, 0.0, p.z)
		if radial.length_squared() > 0.0001:
			var outward: Vector3 = radial.normalized() * (0.032 * strength)
			var upward := Vector3(0.0, 0.025 * strength, 0.0)
			_prev_positions[i] = _positions[i] - (outward + upward)


func _physics_process(delta: float) -> void:
	if _positions.is_empty():
		return

	var dt: float = 1.0 / 60.0
	if delta > 0.0 and delta <= 0.05:
		dt = delta

	var grav_step := Vector3(0.0, -GRAVITY * dt * dt, 0.0)
	var count: int = _positions.size()

	for i in range(count):
		if _pinned[i] != 0:
			continue
		var curr: Vector3 = _positions[i]
		var vel: Vector3 = (curr - _prev_positions[i]) * DAMPING
		_prev_positions[i] = curr
		_positions[i] = curr + vel + grav_step

	_collide_with_balls()

	for _iter in range(SOLVER_ITERATIONS):
		for c in _constraints:
			var ia: int = int(c["a"])
			var ib: int = int(c["b"])
			var pa: Vector3 = _positions[ia]
			var pb: Vector3 = _positions[ib]
			var diff: Vector3 = pb - pa
			var dist_sq: float = diff.length_squared()
			if dist_sq <= 0.000001:
				continue
			var dist: float = sqrt(dist_sq)
			var rest: float = float(c["rest"])
			var err: float = (dist - rest) / dist
			var correction: Vector3 = diff * (0.5 * err * float(c["stiffness"]))

			var pin_a: bool = _pinned[ia] != 0
			var pin_b: bool = _pinned[ib] != 0
			if pin_a and not pin_b:
				_positions[ib] -= correction * 2.0
			elif pin_b and not pin_a:
				_positions[ia] += correction * 2.0
			elif not pin_a and not pin_b:
				_positions[ia] += correction
				_positions[ib] -= correction

	_rebuild_mesh()


func _collide_with_balls() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var balls: Array[Node] = tree.get_nodes_in_group("basketball")
	if balls.is_empty():
		return

	var inv_xform: Transform3D = global_transform.affine_inverse()
	var min_dist: float = 0.145 # Ball radius 0.12 + net strand clearance 0.025

	for b_node in balls:
		if not (b_node is Node3D):
			continue
		var b3d := b_node as Node3D
		if b3d.global_position.distance_squared_to(global_position) > 0.85:
			continue
		var local_ball: Vector3 = inv_xform * b3d.global_position
		for i in range(_positions.size()):
			if _pinned[i] != 0:
				continue
			var delta_v: Vector3 = _positions[i] - local_ball
			var d_sq: float = delta_v.length_squared()
			if d_sq > 0.000001 and d_sq < min_dist * min_dist:
				var d: float = sqrt(d_sq)
				var push_dir: Vector3 = delta_v / d
				_positions[i] = local_ball + push_dir * min_dist


func _rebuild_mesh() -> void:
	if _imm_mesh == null:
		return
	_imm_mesh.clear_surfaces()
	if _constraints.is_empty():
		return

	_imm_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var top_col := Color(1.0, 0.96, 0.92, 1.0)
	var bot_col := Color(0.72, 0.90, 1.0, 1.0)

	for c in _constraints:
		var pa: Vector3 = _positions[int(c["a"])]
		var pb: Vector3 = _positions[int(c["b"])]
		var ta: float = clampf(-pa.y / NET_LENGTH, 0.0, 1.0)
		var tb: float = clampf(-pb.y / NET_LENGTH, 0.0, 1.0)
		_imm_mesh.surface_set_color(top_col.lerp(bot_col, ta))
		_imm_mesh.surface_add_vertex(pa)
		_imm_mesh.surface_set_color(top_col.lerp(bot_col, tb))
		_imm_mesh.surface_add_vertex(pb)

	_imm_mesh.surface_end()
