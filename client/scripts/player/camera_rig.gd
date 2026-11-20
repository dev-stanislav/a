class_name CameraRig
extends Node3D
## Third-person SpringArm3D + Camera3D rig with mouse look, arrow-key/right-stick fallback,
## Dramatic Zone Awakening FOV widening (72.0° -> 84.0° + activation zoom-punch + Dutch-angle roll),
## Phase 12 ScreenShake + CinematicDirector dunk camera override integration,
## ConfigManager settings, and zero-vector safe camera basis helpers.

const MIN_PITCH: float = -1.05
const MAX_PITCH: float = 0.30
const KEY_TURN_SPEED: float = 2.2
const STICK_TURN_SPEED: float = 2.6

const DEFAULT_BASE_FOV: float = 72.0
const ZONE_FOV_BONUS: float = 12.0 # 72.0 -> 84.0 in Zone
const ZONE_MAX_ROLL_DEG: float = 4.5

@export var spring_length: float = 4.6
@export var camera_fov: float = DEFAULT_BASE_FOV
@export var active_for_local_player: bool = true

var yaw: float = 0.0
var pitch: float = -0.26
var base_fov: float = DEFAULT_BASE_FOV

var _zone_mode_active: bool = false
var _lateral_velocity_hint: float = 0.0
var _fov_punch_offset: float = 0.0
var _current_roll_rad: float = 0.0
var _shake_strength: float = 0.0
var _local_shake_clock: float = 0.0

# Phase 12 VFXManager ScreenShake + CinematicDirector state
var _applied_shake_offset: Vector3 = Vector3.ZERO
var _applied_shake_roll_rad: float = 0.0
var _applied_cinematic_fov_delta: float = 0.0
var _applied_cinematic_offset: Vector3 = Vector3.ZERO
var _cinematic_override_active: bool = false

@onready var spring_arm: SpringArm3D = get_node_or_null("SpringArm3D")
@onready var camera: Camera3D = get_node_or_null("SpringArm3D/Camera3D")


func _ready() -> void:
	_ensure_nodes()
	_sync_from_config()
	_apply_transform()


func _ensure_nodes() -> void:
	if spring_arm == null:
		spring_arm = SpringArm3D.new()
		spring_arm.name = "SpringArm3D"
		add_child(spring_arm)
	spring_arm.spring_length = spring_length
	spring_arm.collision_mask = 1
	spring_arm.margin = 0.25

	if camera == null:
		camera = Camera3D.new()
		camera.name = "Camera3D"
		spring_arm.add_child(camera)
	camera.fov = camera_fov
	camera.current = active_for_local_player


func _sync_from_config() -> void:
	if ConfigManager != null:
		camera_fov = float(ConfigManager.get_setting("gameplay", "camera_fov", DEFAULT_BASE_FOV))
	base_fov = camera_fov
	if camera != null and not _zone_mode_active:
		camera.fov = base_fov


func set_active_camera(is_active: bool) -> void:
	active_for_local_player = is_active
	if camera != null:
		camera.current = is_active


func set_zone_mode(is_zone: bool, lateral_speed: float = 0.0) -> void:
	if is_zone and not _zone_mode_active:
		# Brief dramatic zoom-in punch (-5.5°) before snapping outward to 84.0° Zone FOV
		_fov_punch_offset = -5.5
		add_camera_shake(0.16)
	_zone_mode_active = is_zone
	_lateral_velocity_hint = lateral_speed if is_zone else 0.0


func reset_zone_camera() -> void:
	_zone_mode_active = false
	_lateral_velocity_hint = 0.0
	_fov_punch_offset = 0.0
	_current_roll_rad = 0.0
	_shake_strength = 0.0
	_applied_shake_offset = Vector3.ZERO
	_applied_shake_roll_rad = 0.0
	_applied_cinematic_fov_delta = 0.0
	_applied_cinematic_offset = Vector3.ZERO
	_cinematic_override_active = false
	if camera != null:
		camera.fov = base_fov
		camera.rotation.z = 0.0
		camera.h_offset = 0.0
		camera.v_offset = 0.0
	if spring_arm != null:
		spring_arm.spring_length = spring_length


func is_zone_camera_active() -> bool:
	return _zone_mode_active


func get_current_fov() -> float:
	return camera.fov if camera != null else base_fov


func get_current_roll_deg() -> float:
	return rad_to_deg(camera.rotation.z) if camera != null else 0.0


func get_applied_shake_offset() -> Vector3:
	return _applied_shake_offset


func get_applied_cinematic_fov_delta() -> float:
	return _applied_cinematic_fov_delta


func is_cinematic_override_active() -> bool:
	return _cinematic_override_active


func set_yaw(new_yaw: float) -> void:
	yaw = wrapf(new_yaw, -PI, PI)
	_apply_transform()


func get_yaw() -> float:
	return yaw


func get_forward_xz() -> Vector3:
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	if fwd.length_squared() > 0.0001:
		return fwd.normalized()
	return Vector3(0.0, 0.0, -1.0)


func get_right_xz() -> Vector3:
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	if right.length_squared() > 0.0001:
		return right.normalized()
	return Vector3(1.0, 0.0, 0.0)


func add_camera_shake(amount: float) -> void:
	var scale_cfg: float = 1.0
	if ConfigManager != null:
		scale_cfg = float(ConfigManager.get_setting("gameplay", "camera_shake_scale", 1.0))
	_shake_strength = clampf(_shake_strength + amount * scale_cfg, 0.0, 0.35)
	var vfx: VFXManager = _find_vfx_manager()
	if vfx != null:
		var ss: ScreenShake = vfx.get_screen_shake()
		if ss != null:
			ss.add_trauma(amount * 0.5)


func step_camera_fx(dt: float) -> void:
	_step_zone_and_cinematic_effects(dt)
	_apply_transform()


func _unhandled_input(event: InputEvent) -> void:
	if not active_for_local_player:
		return
	if DisplayServer.get_name() == "headless":
		return

	if event is InputEventKey and event.is_action_pressed("pause"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE:
			if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			var sens: float = 0.0028
			var inv_y: bool = false
			if ConfigManager != null:
				sens = float(ConfigManager.get_setting("gameplay", "mouse_sensitivity", 0.0028))
				inv_y = bool(ConfigManager.get_setting("gameplay", "invert_y", false))
			yaw = wrapf(yaw - mm.relative.x * sens, -PI, PI)
			var y_sign: float = 1.0 if inv_y else -1.0
			pitch = clampf(pitch + mm.relative.y * sens * y_sign, MIN_PITCH, MAX_PITCH)
			_apply_transform()


func _physics_process(delta: float) -> void:
	var dt: float = delta if delta > 0.0 else (1.0 / 60.0)
	_local_shake_clock += dt

	if active_for_local_player:
		poll_touch_camera_input()

		var yaw_input: float = 0.0
		var pitch_input: float = 0.0
		if Input.is_physical_key_pressed(KEY_LEFT):
			yaw_input += 1.0
		if Input.is_physical_key_pressed(KEY_RIGHT):
			yaw_input -= 1.0
		if Input.is_physical_key_pressed(KEY_UP):
			pitch_input += 1.0
		if Input.is_physical_key_pressed(KEY_DOWN):
			pitch_input -= 1.0

		var joy_rx: float = Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
		var joy_ry: float = Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
		if absf(joy_rx) > 0.2:
			yaw_input -= joy_rx * (STICK_TURN_SPEED / KEY_TURN_SPEED)
		if absf(joy_ry) > 0.2:
			pitch_input -= joy_ry * (STICK_TURN_SPEED / KEY_TURN_SPEED)

		if absf(yaw_input) > 0.001 or absf(pitch_input) > 0.001:
			yaw = wrapf(yaw + yaw_input * KEY_TURN_SPEED * dt, -PI, PI)
			pitch = clampf(pitch + pitch_input * (KEY_TURN_SPEED * 0.7) * dt, MIN_PITCH, MAX_PITCH)

	if absf(_fov_punch_offset) > 0.01:
		_fov_punch_offset = move_toward(_fov_punch_offset, 0.0, dt * 48.0)
	else:
		_fov_punch_offset = 0.0

	if _shake_strength > 0.001:
		_shake_strength = maxf(0.0, _shake_strength - dt * 2.2)

	_step_zone_and_cinematic_effects(dt)
	_apply_transform()


func poll_touch_camera_input() -> void:
	if not active_for_local_player:
		return
	var tc: Node = _find_touch_controls()
	if tc == null:
		return
	if tc.has_method("is_touch_active") and not bool(tc.call("is_touch_active")):
		return
	if not tc.has_method("consume_camera_delta"):
		return
	var raw_delta: Variant = tc.call("consume_camera_delta")
	if not (raw_delta is Vector2):
		return
	var drag_delta: Vector2 = raw_delta as Vector2
	if drag_delta.length_squared() <= 0.000001:
		return

	var sens: float = 0.0028
	var inv_y: bool = false
	if ConfigManager != null:
		sens = float(ConfigManager.get_setting("gameplay", "mouse_sensitivity", 0.0028))
		inv_y = bool(ConfigManager.get_setting("gameplay", "invert_y", false))
	yaw = wrapf(yaw - drag_delta.x * sens, -PI, PI)
	var y_sign: float = 1.0 if inv_y else -1.0
	pitch = clampf(pitch + drag_delta.y * sens * y_sign, MIN_PITCH, MAX_PITCH)
	_apply_transform()


func _find_touch_controls() -> Node:
	if is_inside_tree() and get_tree() != null:
		var tc: Node = get_tree().get_first_node_in_group("touch_controls")
		if tc != null:
			return tc
		var arena_node: Node = get_tree().get_first_node_in_group("arena")
		if arena_node != null and arena_node.has_method("get_touch_controls"):
			return arena_node.call("get_touch_controls")
	return null


func _step_zone_and_cinematic_effects(dt: float) -> void:
	if camera == null:
		return

	# Sample Phase 12 VFXManager ScreenShake + CinematicDirector camera frame
	var vfx: VFXManager = _find_vfx_manager()
	if vfx != null:
		var fx: Dictionary = vfx.get_camera_fx_frame()
		_applied_shake_offset = fx.get("shake_offset", Vector3.ZERO)
		_applied_shake_roll_rad = float(fx.get("shake_roll_rad", 0.0))
		_cinematic_override_active = bool(fx.get("cinematic_active", false))
		_applied_cinematic_fov_delta = float(fx.get("cinematic_fov_delta", 0.0))
		var target_cine_off: Vector3 = fx.get("cinematic_offset", Vector3.ZERO)
		_applied_cinematic_offset = _applied_cinematic_offset.lerp(target_cine_off, clampf(dt * 14.0, 0.0, 1.0))
		if not _cinematic_override_active and _applied_cinematic_offset.length_squared() < 0.0001:
			_applied_cinematic_offset = Vector3.ZERO
	else:
		_applied_shake_offset = Vector3.ZERO
		_applied_shake_roll_rad = 0.0
		_cinematic_override_active = false
		_applied_cinematic_fov_delta = 0.0
		_applied_cinematic_offset = Vector3.ZERO

	var zone_target_fov: float = (base_fov + ZONE_FOV_BONUS + _fov_punch_offset) if _zone_mode_active else base_fov
	var target_fov: float = zone_target_fov + _applied_cinematic_fov_delta
	var fov_rate: float = 14.0 if (_zone_mode_active or _cinematic_override_active) else 16.0
	camera.fov = lerpf(camera.fov, target_fov, clampf(dt * fov_rate, 0.0, 1.0))
	if not _zone_mode_active and not _cinematic_override_active and absf(camera.fov - base_fov) < 0.05:
		camera.fov = base_fov

	var max_roll_rad: float = deg_to_rad(ZONE_MAX_ROLL_DEG)
	var target_roll: float = 0.0
	if _zone_mode_active:
		var norm_lat: float = clampf(_lateral_velocity_hint / 9.0, -1.0, 1.0)
		target_roll = -norm_lat * max_roll_rad

	_current_roll_rad = lerpf(_current_roll_rad, target_roll, clampf(dt * 12.0, 0.0, 1.0))
	if not _zone_mode_active and absf(_current_roll_rad) < 0.001:
		_current_roll_rad = 0.0
	camera.rotation.z = _current_roll_rad + _applied_shake_roll_rad

	if spring_arm != null:
		var target_arm: float = ((spring_length + 0.35) if _zone_mode_active else spring_length) + _applied_cinematic_offset.z + _applied_shake_offset.z
		spring_arm.spring_length = lerpf(spring_arm.spring_length, target_arm, clampf(dt * 10.0, 0.0, 1.0))


func _apply_transform() -> void:
	rotation = Vector3(0.0, yaw, 0.0)
	if spring_arm != null:
		spring_arm.rotation = Vector3(pitch, 0.0, 0.0)
	if camera != null:
		var hx: float = _applied_shake_offset.x + _applied_cinematic_offset.x
		var vy: float = _applied_shake_offset.y + _applied_cinematic_offset.y
		if _shake_strength > 0.001:
			var t: float = _local_shake_clock * 45.0
			hx += sin(t * 1.7) * _shake_strength * 0.12
			vy += cos(t * 2.3) * _shake_strength * 0.12
		camera.h_offset = hx
		camera.v_offset = vy


func _find_vfx_manager() -> VFXManager:
	if is_inside_tree() and get_tree() != null:
		return get_tree().get_first_node_in_group("vfx_manager") as VFXManager
	return null
