class_name CinematicDirector
extends Node
## Anime Impact & Camera Cinematography Director for PHANTOM COURT ONLINE.
## Orchestrates offline-safe slow-motion hit-stop (strictly locked to 1.0x online),
## 2-3 frame monochrome impact flashes, radial speed-lines, dramatic dunk camera
## overrides, and dynamic gymnasium spotlight shifts.

@export var auto_process: bool = true

# Slow-motion hit-stop state (unscaled time tracking!)
var _hit_stop_remaining: float = 0.0
var _hit_stop_scale: float = 1.0
var _time_scale_active: bool = false
var _visual_hit_stop_remaining: float = 0.0

# 2-3 frame monochrome impact flash state
var _impact_frames_left: int = 0
var _impact_frame_accum: float = 0.0
var _impact_flash_strength: float = 0.0
var _impact_flash_color: Color = Color.WHITE

# Screen-edge anime radial speed lines state
var _speed_lines_base: float = 0.0
var _speed_lines_pulse: float = 0.0
var _speed_lines_decay: float = 2.5

# Dramatic dunk camera override state
var _dunk_cam_time_left: float = 0.0
var _dunk_cam_duration: float = 0.42
var _dunk_fov_peak: float = -7.5
var _dunk_fov_delta: float = 0.0
var _dunk_cam_offset: Vector3 = Vector3.ZERO
var _dunk_rim_pos: Vector3 = Vector3.ZERO

# Dynamic arena lighting baseline cache & telemetry
var _lighting_baselines: Dictionary = {} # instance_id -> {sun_energy, sun_color, glow_intensity, spots: {id -> {energy, color}}}
var _last_lighting_state: Dictionary = {
	"zone_active": false,
	"dunk_flash": 0.0,
	"sun_energy": 1.25,
	"spotlight_energy": 2.2,
	"glow_intensity": 0.45,
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	_restore_time_scale()


func _process(delta: float) -> void:
	if not auto_process or delta <= 0.0:
		return
	var unscaled_dt: float = delta / maxf(Engine.time_scale, 0.05)
	step_director(unscaled_dt)


func is_online_match() -> bool:
	var gs: Node = _get_autoload("GameState")
	if gs == null:
		return false
	if gs.has_method("is_online_match"):
		return bool(gs.call("is_online_match"))
	var raw: Variant = gs.get("is_online")
	return bool(raw) if raw != null else false


func trigger_hit_stop(
	duration_sec: float = 0.18,
	time_scale: float = 0.25,
	allow_time_scale: bool = true
) -> bool:
	var dur: float = clampf(duration_sec, 0.02, 0.65)
	if is_online_match() or not allow_time_scale:
		# Online safety: NEVER drift network simulation ticks! Pure visual punch only.
		_restore_time_scale()
		_visual_hit_stop_remaining = maxf(_visual_hit_stop_remaining, dur)
		_dunk_cam_time_left = maxf(_dunk_cam_time_left, dur * 1.4)
		_dunk_cam_duration = maxf(_dunk_cam_duration, _dunk_cam_time_left)
		_dunk_fov_peak = minf(_dunk_fov_peak, -6.0)
		_dunk_fov_delta = _dunk_fov_peak
		trigger_impact_frame(2, Color.WHITE)
		return false

	_hit_stop_remaining = maxf(_hit_stop_remaining, dur)
	_hit_stop_scale = clampf(time_scale, 0.05, 1.0)
	_time_scale_active = true
	Engine.time_scale = _hit_stop_scale
	return true


func is_hit_stop_active() -> bool:
	return _time_scale_active or _hit_stop_remaining > 0.0 or _visual_hit_stop_remaining > 0.0


func is_time_scale_modified() -> bool:
	return _time_scale_active and not is_equal_approx(Engine.time_scale, 1.0)


func trigger_impact_frame(frames: int = 3, color: Color = Color.WHITE) -> void:
	_impact_frames_left = maxi(_impact_frames_left, clampi(frames, 1, 8))
	_impact_frame_accum = 0.0
	_impact_flash_strength = 1.0
	_impact_flash_color = Color(color.r, color.g, color.b, 1.0)


func is_impact_frame_active() -> bool:
	return _impact_frames_left > 0 and _impact_flash_strength > 0.001


func get_impact_flash_strength() -> float:
	return _impact_flash_strength


func get_impact_flash_color() -> Color:
	return _impact_flash_color


func get_impact_frames_left() -> int:
	return _impact_frames_left


func set_speed_lines_intensity(val: float) -> void:
	_speed_lines_base = clampf(val, 0.0, 1.0)


func pulse_speed_lines(peak: float = 0.80, duration: float = 0.35) -> void:
	_speed_lines_pulse = maxf(_speed_lines_pulse, clampf(peak, 0.0, 1.0))
	_speed_lines_decay = maxf(0.5, _speed_lines_pulse / maxf(0.05, duration))


func get_speed_lines_intensity() -> float:
	return clampf(maxf(_speed_lines_base, _speed_lines_pulse), 0.0, 1.0)


func trigger_cinematic_dunk(rim_pos: Vector3, power: float = 1.5) -> void:
	var p: float = clampf(power, 0.8, 2.5)
	_dunk_rim_pos = rim_pos
	_dunk_cam_duration = clampf(0.32 + p * 0.10, 0.35, 0.60)
	_dunk_cam_time_left = _dunk_cam_duration
	_dunk_fov_peak = -clampf(4.5 + p * 2.4, 5.5, 11.0)
	_dunk_fov_delta = _dunk_fov_peak
	var toward_rim_z: float = -0.32 if rim_pos.z < 0.0 else 0.32
	_dunk_cam_offset = Vector3(0.0, -0.18 * (p / 1.5), toward_rim_z)


func get_cinematic_camera_override() -> Dictionary:
	return {
		"active": _dunk_cam_time_left > 0.0,
		"fov_delta": _dunk_fov_delta,
		"offset": _dunk_cam_offset,
		"time_left": _dunk_cam_time_left,
		"rim_pos": _dunk_rim_pos,
	}


func update_arena_lighting(
	arena_root: Node,
	zone_active: bool,
	dunk_flash: float = 0.0,
	accent_color: Color = Color(0.15, 0.90, 1.0, 1.0)
) -> Dictionary:
	var flash: float = clampf(dunk_flash, 0.0, 1.0)
	if arena_root == null or not is_instance_valid(arena_root):
		_last_lighting_state = {
			"zone_active": zone_active,
			"dunk_flash": flash,
			"sun_energy": (0.88 if zone_active else 1.25) + flash * 0.25,
			"spotlight_energy": (3.10 if zone_active else 2.20) + flash * 1.40,
			"glow_intensity": (0.72 if zone_active else 0.45) + flash * 0.25,
		}
		return _last_lighting_state.duplicate()

	var aid: int = arena_root.get_instance_id()
	var sun: DirectionalLight3D = arena_root.get_node_or_null("SunLight") as DirectionalLight3D
	var we: WorldEnvironment = arena_root.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var spots_root: Node = arena_root.get_node_or_null("StadiumSpotlights")

	if not _lighting_baselines.has(aid):
		var spot_base: Dictionary = {}
		if spots_root != null:
			for child in spots_root.get_children():
				if child is SpotLight3D:
					var sp := child as SpotLight3D
					spot_base[sp.get_instance_id()] = {
						"energy": sp.light_energy,
						"color": sp.light_color,
					}
		_lighting_baselines[aid] = {
			"sun_energy": sun.light_energy if sun != null else 1.25,
			"sun_color": sun.light_color if sun != null else Color(1.0, 0.97, 0.92, 1.0),
			"glow_intensity": we.environment.glow_intensity if (we != null and we.environment != null) else 0.45,
			"spots": spot_base,
		}

	var base: Dictionary = _lighting_baselines[aid]
	var base_sun_energy: float = float(base["sun_energy"])
	var base_sun_color: Color = base["sun_color"] as Color
	var base_glow: float = float(base["glow_intensity"])
	var spots_base: Dictionary = base["spots"] as Dictionary

	var target_sun_energy: float = (base_sun_energy * 0.72 if zone_active else base_sun_energy) + flash * 0.30
	var target_glow: float = (base_glow + 0.26 if zone_active else base_glow) + flash * 0.22
	var avg_spot_energy: float = 2.2

	if sun != null:
		sun.light_energy = target_sun_energy
		sun.light_color = base_sun_color.lerp(accent_color.lerp(Color.WHITE, 0.55), 0.28 if zone_active else 0.0)

	if we != null and we.environment != null:
		we.environment.glow_intensity = clampf(target_glow, 0.2, 1.5)

	if spots_root != null:
		var sum_e: float = 0.0
		var cnt: int = 0
		for child in spots_root.get_children():
			if child is SpotLight3D:
				var sp := child as SpotLight3D
				var sid: int = sp.get_instance_id()
				var b_entry: Dictionary = spots_base.get(sid, {"energy": 2.2, "color": Color.WHITE})
				var b_e: float = float(b_entry["energy"])
				var b_c: Color = b_entry["color"] as Color
				sp.light_energy = (b_e * 1.42 if zone_active else b_e) + flash * 1.45
				sp.light_color = b_c.lerp(accent_color, 0.42 if zone_active else 0.0).lerp(Color.WHITE, flash * 0.5)
				sum_e += sp.light_energy
				cnt += 1
		if cnt > 0:
			avg_spot_energy = sum_e / float(cnt)

	_last_lighting_state = {
		"zone_active": zone_active,
		"dunk_flash": flash,
		"sun_energy": target_sun_energy,
		"spotlight_energy": avg_spot_energy,
		"glow_intensity": target_glow,
	}
	return _last_lighting_state.duplicate()


func get_last_lighting_state() -> Dictionary:
	return _last_lighting_state.duplicate()


func step_director(unscaled_dt: float) -> void:
	if unscaled_dt <= 0.0:
		return

	# 1. Slow-Motion Hit-Stop timer (real unscaled dt)
	if _time_scale_active:
		if is_online_match():
			_restore_time_scale()
		else:
			_hit_stop_remaining = maxf(0.0, _hit_stop_remaining - unscaled_dt)
			if _hit_stop_remaining <= 0.0:
				_restore_time_scale()
			else:
				Engine.time_scale = _hit_stop_scale

	if _visual_hit_stop_remaining > 0.0:
		_visual_hit_stop_remaining = maxf(0.0, _visual_hit_stop_remaining - unscaled_dt)

	# 2. Monochrome Impact Frame countdown (exact 60 Hz frame budget)
	if _impact_frames_left > 0:
		_impact_frame_accum += unscaled_dt
		var elapsed_frames: int = int(floor(_impact_frame_accum * 60.0 + 0.0001))
		if elapsed_frames > 0:
			_impact_frame_accum = maxf(0.0, _impact_frame_accum - float(elapsed_frames) / 60.0)
			_impact_frames_left = maxi(0, _impact_frames_left - elapsed_frames)
		if _impact_frames_left <= 0:
			_impact_flash_strength = 0.0
		else:
			_impact_flash_strength = clampf(0.65 + 0.35 * (float(_impact_frames_left) / 3.0), 0.5, 1.0)
	else:
		_impact_flash_strength = 0.0

	# 3. Radial Speed Lines burst decay
	if _speed_lines_pulse > 0.0:
		_speed_lines_pulse = maxf(0.0, _speed_lines_pulse - _speed_lines_decay * unscaled_dt)

	# 4. Cinematic Dunk Camera Override smooth ease-out
	if _dunk_cam_time_left > 0.0:
		_dunk_cam_time_left = maxf(0.0, _dunk_cam_time_left - unscaled_dt)
		var norm: float = clampf(_dunk_cam_time_left / maxf(0.01, _dunk_cam_duration), 0.0, 1.0)
		var ease_curve: float = norm * norm
		_dunk_fov_delta = _dunk_fov_peak * ease_curve
		var toward_rim_z: float = -0.32 if _dunk_rim_pos.z < 0.0 else 0.32
		_dunk_cam_offset = Vector3(0.0, -0.18 * ease_curve, toward_rim_z * ease_curve)
		if _dunk_cam_time_left <= 0.0:
			_dunk_fov_delta = 0.0
			_dunk_cam_offset = Vector3.ZERO
	else:
		_dunk_fov_delta = 0.0
		_dunk_cam_offset = Vector3.ZERO


func reset() -> void:
	_restore_time_scale()
	_visual_hit_stop_remaining = 0.0
	_impact_frames_left = 0
	_impact_frame_accum = 0.0
	_impact_flash_strength = 0.0
	_speed_lines_base = 0.0
	_speed_lines_pulse = 0.0
	_dunk_cam_time_left = 0.0
	_dunk_fov_delta = 0.0
	_dunk_cam_offset = Vector3.ZERO


func _restore_time_scale() -> void:
	_hit_stop_remaining = 0.0
	_hit_stop_scale = 1.0
	_time_scale_active = false
	if not is_equal_approx(Engine.time_scale, 1.0):
		Engine.time_scale = 1.0


func _get_autoload(autoload_name: String) -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null(autoload_name)
	return null
