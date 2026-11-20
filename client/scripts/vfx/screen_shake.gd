class_name ScreenShake
extends Node
## Damped quadratic trauma camera shake controller for PHANTOM COURT ONLINE.
## Computes deterministic offset + roll impulses scaled by ConfigManager camera_shake_scale.

@export var trauma_decay: float = 2.4
@export var max_offset: Vector3 = Vector3(0.22, 0.18, 0.08)
@export var max_roll_rad: float = 0.0733038 # ~4.2 degrees
@export var auto_process: bool = true

var _trauma: float = 0.0
var _time: float = 0.0
var _last_offset: Vector3 = Vector3.ZERO
var _last_roll_rad: float = 0.0


func _process(delta: float) -> void:
	if auto_process and delta > 0.0:
		step_shake(delta)


func add_trauma(amount: float) -> void:
	if amount <= 0.0:
		return
	var scale_cfg: float = _get_shake_scale()
	if scale_cfg <= 0.0001:
		return
	_trauma = clampf(_trauma + amount * scale_cfg, 0.0, 1.0)


func get_trauma() -> float:
	return _trauma


func reset() -> void:
	_trauma = 0.0
	_time = 0.0
	_last_offset = Vector3.ZERO
	_last_roll_rad = 0.0


func get_last_shake() -> Dictionary:
	return {
		"offset": _last_offset,
		"roll_rad": _last_roll_rad,
		"trauma": _trauma,
	}


func step_shake(dt: float) -> Dictionary:
	if dt <= 0.0:
		return get_last_shake()

	var scale_cfg: float = _get_shake_scale()
	if _trauma <= 0.0001 or scale_cfg <= 0.0001:
		_trauma = 0.0
		_last_offset = Vector3.ZERO
		_last_roll_rad = 0.0
		return get_last_shake()

	_time += dt
	# Quadratic trauma response (punchy peak, smooth non-jarring decay)
	var shake_mag: float = (_trauma * _trauma) * clampf(scale_cfg, 0.0, 2.0)

	var ox: float = (sin(_time * 31.7) * 0.65 + cos(_time * 47.3) * 0.35) * max_offset.x * shake_mag
	var oy: float = (cos(_time * 37.1) * 0.65 + sin(_time * 53.9) * 0.35) * max_offset.y * shake_mag
	var oz: float = (sin(_time * 23.3 + 1.1) * 0.70 + cos(_time * 41.7) * 0.30) * max_offset.z * shake_mag
	var roll: float = (sin(_time * 29.3 + 0.5) * 0.60 + cos(_time * 43.1) * 0.40) * max_roll_rad * shake_mag

	_last_offset = Vector3(ox, oy, oz)
	_last_roll_rad = roll

	_trauma = maxf(0.0, _trauma - trauma_decay * dt)
	if _trauma <= 0.0005:
		_trauma = 0.0

	return {
		"offset": _last_offset,
		"roll_rad": _last_roll_rad,
		"trauma": _trauma,
	}


func _get_shake_scale() -> float:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		var cm: Node = (ml as SceneTree).root.get_node_or_null("ConfigManager")
		if cm != null and cm.has_method("get_setting"):
			return clampf(float(cm.call("get_setting", "gameplay", "camera_shake_scale", 1.0)), 0.0, 2.0)
	return 1.0
