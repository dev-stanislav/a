class_name RibbonTrail3D
extends MeshInstance3D
## Procedural camera-facing 3D energy ribbon trail built with ImmediateMesh
## and `res://shaders/motion_trail.gdshader`. Zero-vector & --headless safe.

const TRAIL_SHADER_PATH := "res://shaders/motion_trail.gdshader"
const DEFAULT_TRAIL_COLOR := Color(0.0, 0.92, 1.0, 1.0)

@export var trail_color: Color = DEFAULT_TRAIL_COLOR
@export var trail_width: float = 0.24
@export var max_points: int = 24
@export var point_lifetime: float = 0.32
@export var min_sample_distance: float = 0.04
@export var emitting: bool = true
@export var intensity: float = 1.35

var auto_sample_target: Node3D = null
var sample_offset: Vector3 = Vector3.ZERO

var _points: Array[Dictionary] = [] # {pos: Vector3, age: float}
var _imm_mesh: ImmediateMesh = null
var _trail_material: ShaderMaterial = null
var _vertex_count: int = 0
var _initialized: bool = false


func _ready() -> void:
	_ensure_initialized()


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	if auto_sample_target != null and is_instance_valid(auto_sample_target) and auto_sample_target.is_inside_tree():
		sample_point(auto_sample_target.global_position + sample_offset, delta)
	elif not _points.is_empty():
		_age_and_prune(delta)
		_rebuild_mesh()


func _ensure_initialized() -> void:
	if _initialized:
		return
	_initialized = true

	top_level = true
	global_transform = Transform3D.IDENTITY
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_imm_mesh = ImmediateMesh.new()
	mesh = _imm_mesh

	_trail_material = ShaderMaterial.new()
	if ResourceLoader.exists(TRAIL_SHADER_PATH):
		var sh := load(TRAIL_SHADER_PATH) as Shader
		if sh != null:
			_trail_material.shader = sh
	_trail_material.set_shader_parameter("trail_color", trail_color)
	_trail_material.set_shader_parameter("intensity", intensity)
	material_override = _trail_material


func set_target_node(target: Node3D, offset: Vector3 = Vector3.ZERO) -> void:
	_ensure_initialized()
	auto_sample_target = target
	sample_offset = offset


func set_emitting(enabled: bool) -> void:
	_ensure_initialized()
	emitting = enabled


func is_emitting() -> bool:
	return emitting


func set_trail_color(color: Color) -> void:
	_ensure_initialized()
	trail_color = Color(color.r, color.g, color.b, 1.0)
	if _trail_material != null:
		_trail_material.set_shader_parameter("trail_color", trail_color)


func get_trail_color() -> Color:
	return trail_color


func set_width(w: float) -> void:
	trail_width = maxf(0.01, w)


func get_width() -> float:
	return trail_width


func set_intensity(val: float) -> void:
	_ensure_initialized()
	intensity = clampf(val, 0.0, 4.0)
	if _trail_material != null:
		_trail_material.set_shader_parameter("intensity", intensity)


func get_trail_material() -> ShaderMaterial:
	_ensure_initialized()
	return _trail_material


func clear_trail() -> void:
	_ensure_initialized()
	_points.clear()
	_vertex_count = 0
	if _imm_mesh != null:
		_imm_mesh.clear_surfaces()


func get_point_count() -> int:
	return _points.size()


func get_vertex_count() -> int:
	return _vertex_count


func sample_point(world_pos: Vector3, dt: float = 0.0166667) -> void:
	_ensure_initialized()
	if dt > 0.0:
		_age_and_prune(dt)

	if emitting:
		var should_add: bool = _points.is_empty()
		if not should_add:
			var last_pos: Vector3 = _points[_points.size() - 1]["pos"]
			if world_pos.distance_squared_to(last_pos) >= (min_sample_distance * min_sample_distance):
				should_add = true
		if should_add:
			_points.append({"pos": world_pos, "age": 0.0})
			while _points.size() > maxi(2, max_points):
				_points.pop_front()

	_rebuild_mesh()


func _age_and_prune(dt: float) -> void:
	var life: float = maxf(0.02, point_lifetime)
	var kept: Array[Dictionary] = []
	for entry in _points:
		var next_age: float = float(entry["age"]) + dt
		if next_age < life:
			entry["age"] = next_age
			kept.append(entry)
	_points = kept


func _rebuild_mesh() -> void:
	if _imm_mesh == null:
		return
	_imm_mesh.clear_surfaces()
	_vertex_count = 0

	var count: int = _points.size()
	if count < 2:
		return

	var cam_pos: Vector3 = _resolve_camera_position(_points[count - 1]["pos"])
	var left_verts: Array[Vector3] = []
	var right_verts: Array[Vector3] = []
	var u_coords: Array[float] = []
	var alphas: Array[float] = []
	left_verts.resize(count)
	right_verts.resize(count)
	u_coords.resize(count)
	alphas.resize(count)

	var life: float = maxf(0.02, point_lifetime)
	var denom: float = float(maxi(1, count - 1))

	for i in range(count):
		var pos: Vector3 = _points[i]["pos"]
		var age: float = float(_points[i]["age"])
		var u: float = float(i) / denom
		var life_alpha: float = clampf(1.0 - (age / life), 0.0, 1.0)

		var tangent: Vector3
		if i == 0:
			tangent = (_points[1]["pos"] as Vector3) - pos
		elif i == count - 1:
			tangent = pos - (_points[count - 2]["pos"] as Vector3)
		else:
			tangent = (_points[i + 1]["pos"] as Vector3) - (_points[i - 1]["pos"] as Vector3)

		if tangent.length_squared() > 1e-8:
			tangent = tangent.normalized()
		else:
			tangent = Vector3(0.0, 0.0, -1.0)

		var to_cam: Vector3 = cam_pos - pos
		if to_cam.length_squared() > 1e-8:
			to_cam = to_cam.normalized()
		else:
			to_cam = Vector3(0.0, 0.6, 0.8).normalized()

		var side: Vector3 = tangent.cross(to_cam)
		if side.length_squared() <= 1e-8:
			side = tangent.cross(Vector3.UP)
		if side.length_squared() <= 1e-8:
			side = Vector3.RIGHT
		else:
			side = side.normalized()

		var half_w: float = (trail_width * 0.5) * (0.20 + 0.80 * u) * (0.35 + 0.65 * life_alpha)
		left_verts[i] = pos - side * half_w
		right_verts[i] = pos + side * half_w
		u_coords[i] = u
		alphas[i] = life_alpha

	_imm_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(count - 1):
		var u0: float = u_coords[i]
		var u1: float = u_coords[i + 1]
		var c0 := Color(1.0, 1.0, 1.0, alphas[i])
		var c1 := Color(1.0, 1.0, 1.0, alphas[i + 1])

		var l0: Vector3 = left_verts[i]
		var r0: Vector3 = right_verts[i]
		var l1: Vector3 = left_verts[i + 1]
		var r1: Vector3 = right_verts[i + 1]

		# Triangle 1: l0 -> r0 -> r1
		_imm_mesh.surface_set_color(c0)
		_imm_mesh.surface_set_uv(Vector2(u0, 0.0))
		_imm_mesh.surface_add_vertex(l0)

		_imm_mesh.surface_set_color(c0)
		_imm_mesh.surface_set_uv(Vector2(u0, 1.0))
		_imm_mesh.surface_add_vertex(r0)

		_imm_mesh.surface_set_color(c1)
		_imm_mesh.surface_set_uv(Vector2(u1, 1.0))
		_imm_mesh.surface_add_vertex(r1)

		# Triangle 2: l0 -> r1 -> l1
		_imm_mesh.surface_set_color(c0)
		_imm_mesh.surface_set_uv(Vector2(u0, 0.0))
		_imm_mesh.surface_add_vertex(l0)

		_imm_mesh.surface_set_color(c1)
		_imm_mesh.surface_set_uv(Vector2(u1, 1.0))
		_imm_mesh.surface_add_vertex(r1)

		_imm_mesh.surface_set_color(c1)
		_imm_mesh.surface_set_uv(Vector2(u1, 0.0))
		_imm_mesh.surface_add_vertex(l1)

		_vertex_count += 6

	_imm_mesh.surface_end()


func _resolve_camera_position(anchor_pos: Vector3) -> Vector3:
	if is_inside_tree():
		var vp: Viewport = get_viewport()
		if vp != null:
			var cam: Camera3D = vp.get_camera_3d()
			if cam != null and is_instance_valid(cam):
				return cam.global_position
	return anchor_pos + Vector3(0.0, 3.0, 5.0)
