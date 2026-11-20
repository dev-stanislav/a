class_name VFXManager
extends Node
## Central Visual Effects, Custom Shader Factory & Cinematic Impact Manager (Phases 5 + 12).
## Drives Zone Awakening overlays & player auras, pooled stylized 3D particle bursts,
## RibbonTrail3D attachments, quadratic ScreenShake, and CinematicDirector impact frames,
## radial speed lines, offline-safe hit-stop, and dynamic arena spotlighting.

const SHADER_ZONE_AURA := "res://shaders/zone_aura.gdshader"
const SHADER_ZONE_VIGNETTE := "res://shaders/zone_vignette.gdshader"
const SHADER_CEL_CHARACTER := "res://shaders/cel_character.gdshader"
const SHADER_CHARACTER_OUTLINE := "res://shaders/character_outline.gdshader"
const SHADER_COURT_FLOOR := "res://shaders/court_floor.gdshader"
const SHADER_MOTION_TRAIL := "res://shaders/motion_trail.gdshader"
const SHADER_IMPACT_FRAME := "res://shaders/impact_frame.gdshader"
const SHADER_SPEED_LINES := "res://shaders/speed_lines.gdshader"

const SHADER_PATHS: Array[String] = [
	SHADER_ZONE_AURA,
	SHADER_ZONE_VIGNETTE,
	SHADER_CEL_CHARACTER,
	SHADER_CHARACTER_OUTLINE,
	SHADER_COURT_FLOOR,
	SHADER_MOTION_TRAIL,
	SHADER_IMPACT_FRAME,
	SHADER_SPEED_LINES,
]

const VIGNETTE_SHADER_PATH := SHADER_ZONE_VIGNETTE
const DEFAULT_ZONE_COLOR := Color(0.15, 0.90, 1.0, 1.0)
const DEFAULT_OUTLINE_COLOR := Color(0.039, 0.051, 0.086, 1.0)
const ZONE_BANNER_TITLE := "ZONE AWAKENED"
const BURST_POOL_SIZE: int = 12

# Phase 5 Zone overlay state
var _zone_ui_active: bool = false
var _active_zone_player_id: int = -1
var _active_zone_players: Dictionary = {} # player_id: int -> {duration, remaining, color}
var _attached_auras: Dictionary = {} # player_id: int -> AuraController

var _vignette_intensity: float = 0.0
var _pulse_phase: float = 0.0
var _banner_pop_timer: float = 0.0
var _accent_color: Color = DEFAULT_ZONE_COLOR

# Phase 12 VFX / Cinematic / Burst / Trail state
var _screen_shake: ScreenShake = null
var _cinematic_director: CinematicDirector = null
var _trails_by_target: Dictionary = {} # target_instance_id: int -> RibbonTrail3D
var _burst_pool_root: Node3D = null
var _burst_pool: Array[CPUParticles3D] = []
var _burst_cursor: int = 0
var _burst_count: int = 0
var _last_burst_kind: String = ""
var _dunk_flash_timer: float = 0.0
var _dunk_flash_duration: float = 0.35

# Overlay UI nodes
var _overlay_layer: CanvasLayer = null
var _overlay_root: Control = null
var _vignette_rect: ColorRect = null
var _vignette_material: ShaderMaterial = null
var _speed_lines_rect: ColorRect = null
var _speed_lines_material: ShaderMaterial = null
var _impact_frame_rect: ColorRect = null
var _impact_frame_material: ShaderMaterial = null
var _banner_panel: PanelContainer = null
var _banner_style: StyleBoxFlat = null
var _title_label: Label = null
var _subtitle_label: Label = null
var _timer_bar: ProgressBar = null
var _timer_fill_style: StyleBoxFlat = null
var _ui_built: bool = false
var _fx_built: bool = false


func _enter_tree() -> void:
	_connect_event_bus()


func _ready() -> void:
	add_to_group("vfx_manager")
	_ensure_fx_built()
	_ensure_ui_built()
	_connect_event_bus()
	_refresh_overlay_state()


func _exit_tree() -> void:
	_disconnect_event_bus()
	if _cinematic_director != null and is_instance_valid(_cinematic_director):
		_cinematic_director.reset()


func _process(delta: float) -> void:
	if delta > 0.0:
		var unscaled_dt: float = delta / maxf(Engine.time_scale, 0.05)
		step_vfx(unscaled_dt)


# ==============================================================================
# Phase 12 Shader & Material Factory Helpers
# ==============================================================================

func get_shader_paths() -> Array[String]:
	var out: Array[String] = []
	for p in SHADER_PATHS:
		out.append(p)
	return out


static func create_cel_character_material(
	albedo: Color,
	rim_color: Color = Color(0.35, 0.92, 1.0, 1.0),
	outline_color: Color = DEFAULT_OUTLINE_COLOR,
	outline_width: float = 0.018,
	shadow_tint: Color = Color(0.24, 0.26, 0.40, 1.0)
) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	if ResourceLoader.exists(SHADER_CEL_CHARACTER):
		var cel_shader := load(SHADER_CEL_CHARACTER) as Shader
		if cel_shader != null:
			mat.shader = cel_shader
	mat.set_shader_parameter("albedo_color", albedo)
	mat.set_shader_parameter("rim_color", rim_color)
	mat.set_shader_parameter("rim_strength", 0.72)
	mat.set_shader_parameter("shadow_tint", shadow_tint)

	var outline_mat := ShaderMaterial.new()
	if ResourceLoader.exists(SHADER_CHARACTER_OUTLINE):
		var out_shader := load(SHADER_CHARACTER_OUTLINE) as Shader
		if out_shader != null:
			outline_mat.shader = out_shader
	outline_mat.set_shader_parameter("outline_width", maxf(0.0, outline_width))
	outline_mat.set_shader_parameter("outline_color", outline_color)
	mat.next_pass = outline_mat
	return mat


static func create_court_floor_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	if ResourceLoader.exists(SHADER_COURT_FLOOR):
		var floor_shader := load(SHADER_COURT_FLOOR) as Shader
		if floor_shader != null:
			mat.shader = floor_shader
	return mat


# ==============================================================================
# Phase 5 & Phase 12 Public Getters & Attachment APIs
# ==============================================================================

func is_zone_ui_active() -> bool:
	return _zone_ui_active


func get_active_zone_player_id() -> int:
	return _active_zone_player_id


func get_zone_overlay_layer() -> CanvasLayer:
	_ensure_ui_built()
	return _overlay_layer


func get_zone_vignette_intensity() -> float:
	return _vignette_intensity


func get_zone_pulse_phase() -> float:
	return _pulse_phase


func get_zone_banner_text() -> String:
	_ensure_ui_built()
	return _title_label.text if _title_label != null else ZONE_BANNER_TITLE


func get_screen_shake() -> ScreenShake:
	_ensure_fx_built()
	return _screen_shake


func get_cinematic_director() -> CinematicDirector:
	_ensure_fx_built()
	return _cinematic_director


func get_burst_count() -> int:
	return _burst_count


func get_last_burst_kind() -> String:
	return _last_burst_kind


func get_active_trails() -> Array[RibbonTrail3D]:
	var active: Array[RibbonTrail3D] = []
	var dead_keys: Array = []
	for key in _trails_by_target.keys():
		var candidate: Variant = _trails_by_target[key]
		if is_instance_valid(candidate) and candidate is RibbonTrail3D:
			active.append(candidate as RibbonTrail3D)
		else:
			dead_keys.append(key)
	for dk in dead_keys:
		_trails_by_target.erase(dk)
	return active


func get_camera_fx_frame() -> Dictionary:
	_ensure_fx_built()
	var shake: Dictionary = _screen_shake.get_last_shake() if _screen_shake != null else {"offset": Vector3.ZERO, "roll_rad": 0.0, "trauma": 0.0}
	var cine: Dictionary = _cinematic_director.get_cinematic_camera_override() if _cinematic_director != null else {"active": false, "fov_delta": 0.0, "offset": Vector3.ZERO, "time_left": 0.0}
	return {
		"shake_offset": shake.get("offset", Vector3.ZERO),
		"shake_roll_rad": float(shake.get("roll_rad", 0.0)),
		"shake_trauma": float(shake.get("trauma", 0.0)),
		"cinematic_active": bool(cine.get("active", false)),
		"cinematic_fov_delta": float(cine.get("fov_delta", 0.0)),
		"cinematic_offset": cine.get("offset", Vector3.ZERO),
	}


func get_aura_for_player(player_id: int) -> AuraController:
	if _attached_auras.has(player_id):
		var candidate: Variant = _attached_auras[player_id]
		if is_instance_valid(candidate) and candidate is AuraController:
			return candidate as AuraController
		_attached_auras.erase(player_id)
	return null


func set_zone_accent_color(color: Color) -> void:
	_accent_color = Color(color.r, color.g, color.b, 1.0)
	_ensure_ui_built()
	_apply_accent_color(_accent_color)


func attach_aura_to_player(player: Node) -> AuraController:
	if player == null or not is_instance_valid(player):
		return null

	var pid: int = _extract_player_id(player)
	var color: Color = _extract_player_aura_color(player)

	var existing: AuraController = player.get_node_or_null("AuraController") as AuraController
	if existing == null:
		for child in player.get_children():
			if child is AuraController:
				existing = child as AuraController
				break

	var aura: AuraController = existing
	if aura == null:
		aura = AuraController.new()
		aura.name = "AuraController"
		player.add_child(aura)

	aura.setup(pid, color)

	var rig_scale_val: Variant = player.get("rig_scale")
	if rig_scale_val is Vector3 and (rig_scale_val as Vector3).length_squared() > 0.01:
		aura.scale = rig_scale_val as Vector3

	_attached_auras[pid] = aura

	if _active_zone_players.has(pid):
		var entry: Dictionary = _active_zone_players[pid]
		entry["color"] = color
		aura.activate(float(entry.get("remaining", 12.0)))
		if pid == _active_zone_player_id:
			set_zone_accent_color(color)

	return aura


func attach_trail_to_node(
	target_node: Node3D,
	color: Color = Color(0.0, 0.92, 1.0, 1.0),
	width: float = 0.24
) -> RibbonTrail3D:
	if target_node == null or not is_instance_valid(target_node):
		return null

	var tid: int = target_node.get_instance_id()
	var trail: RibbonTrail3D = null
	if _trails_by_target.has(tid):
		var existing: Variant = _trails_by_target[tid]
		if is_instance_valid(existing) and existing is RibbonTrail3D:
			trail = existing as RibbonTrail3D
	if trail == null:
		trail = target_node.get_node_or_null("RibbonTrail3D") as RibbonTrail3D
	if trail == null:
		trail = RibbonTrail3D.new()
		trail.name = "RibbonTrail3D"
		target_node.add_child(trail)

	trail.set_target_node(target_node)
	trail.set_trail_color(color)
	trail.set_width(width)
	_trails_by_target[tid] = trail
	return trail


func spawn_burst(
	kind: String,
	world_pos: Vector3,
	color: Color = Color(0.0, 0.92, 1.0, 1.0),
	scale_mult: float = 1.0
) -> CPUParticles3D:
	_ensure_fx_built()
	if _burst_pool.is_empty():
		return null

	var emitter: CPUParticles3D = _burst_pool[_burst_cursor % _burst_pool.size()]
	_burst_cursor = (_burst_cursor + 1) % _burst_pool.size()
	if emitter == null or not is_instance_valid(emitter):
		return null

	var norm_kind: String = kind.strip_edges().to_lower()
	var s: float = clampf(scale_mult, 0.5, 2.5)
	emitter.position = world_pos

	match norm_kind:
		"dunk_shockwave":
			emitter.amount = 36
			emitter.lifetime = 0.62
			emitter.direction = Vector3(0.0, 0.35, 0.0)
			emitter.spread = 180.0
			emitter.gravity = Vector3(0.0, -3.5, 0.0)
			emitter.initial_velocity_min = 4.2 * s
			emitter.initial_velocity_max = 8.4 * s
			emitter.scale_amount_min = 0.9 * s
			emitter.scale_amount_max = 1.8 * s
		"ankle_break":
			emitter.amount = 28
			emitter.lifetime = 0.50
			emitter.direction = Vector3(0.0, 0.8, 0.0)
			emitter.spread = 95.0
			emitter.gravity = Vector3(0.0, -2.0, 0.0)
			emitter.initial_velocity_min = 3.2 * s
			emitter.initial_velocity_max = 6.5 * s
			emitter.scale_amount_min = 0.7 * s
			emitter.scale_amount_max = 1.45 * s
		"block_swat":
			emitter.amount = 24
			emitter.lifetime = 0.42
			emitter.direction = Vector3(0.0, 0.4, 0.0)
			emitter.spread = 140.0
			emitter.gravity = Vector3(0.0, -4.2, 0.0)
			emitter.initial_velocity_min = 3.5 * s
			emitter.initial_velocity_max = 7.2 * s
			emitter.scale_amount_min = 0.65 * s
			emitter.scale_amount_max = 1.35 * s
		"swish":
			emitter.amount = 30
			emitter.lifetime = 0.75
			emitter.direction = Vector3(0.0, 1.0, 0.0)
			emitter.spread = 58.0
			emitter.gravity = Vector3(0.0, -4.8, 0.0)
			emitter.initial_velocity_min = 2.4 * s
			emitter.initial_velocity_max = 5.2 * s
			emitter.scale_amount_min = 0.6 * s
			emitter.scale_amount_max = 1.2 * s
		_:
			# crossover / combo burst
			emitter.amount = 20
			emitter.lifetime = 0.38
			emitter.direction = Vector3(0.0, 0.7, 0.0)
			emitter.spread = 80.0
			emitter.gravity = Vector3(0.0, 0.8, 0.0)
			emitter.initial_velocity_min = 2.2 * s
			emitter.initial_velocity_max = 4.6 * s
			emitter.scale_amount_min = 0.55 * s
			emitter.scale_amount_max = 1.15 * s

	emitter.color_ramp = _build_burst_gradient(color)
	if emitter.mesh is PrimitiveMesh:
		var pm := emitter.mesh as PrimitiveMesh
		if pm.material is StandardMaterial3D:
			(pm.material as StandardMaterial3D).emission = color
	emitter.restart()
	emitter.emitting = true

	_burst_count += 1
	_last_burst_kind = norm_kind
	return emitter


func reset_vfx() -> void:
	_active_zone_players.clear()
	_zone_ui_active = false
	_active_zone_player_id = -1
	_vignette_intensity = 0.0
	_pulse_phase = 0.0
	_banner_pop_timer = 0.0
	_dunk_flash_timer = 0.0

	if _screen_shake != null:
		_screen_shake.reset()
	if _cinematic_director != null:
		_cinematic_director.reset()
		_cinematic_director.update_arena_lighting(_find_arena_root(), false, 0.0, _accent_color)

	for pid in _attached_auras.keys():
		var aura: AuraController = get_aura_for_player(int(pid))
		if aura != null:
			aura.deactivate()

	for trail in get_active_trails():
		trail.clear_trail()

	for emitter in _burst_pool:
		if is_instance_valid(emitter):
			emitter.emitting = false

	_refresh_overlay_state()


func step_vfx(dt: float) -> void:
	if dt <= 0.0:
		return
	_ensure_fx_built()
	_ensure_ui_built()

	# 1. Step ScreenShake & CinematicDirector deterministically
	if _screen_shake != null:
		_screen_shake.step_shake(dt)
	if _cinematic_director != null:
		_cinematic_director.step_director(dt)

	# 2. Step Dunk Flash lighting decay
	if _dunk_flash_timer > 0.0:
		_dunk_flash_timer = maxf(0.0, _dunk_flash_timer - dt)
		var flash_ratio: float = clampf(_dunk_flash_timer / maxf(0.01, _dunk_flash_duration), 0.0, 1.0)
		if _cinematic_director != null:
			_cinematic_director.update_arena_lighting(_find_arena_root(), _zone_ui_active, flash_ratio, _accent_color)

	# 3. Step Zone UI pulse & active timers
	if _zone_ui_active:
		_pulse_phase += dt * 4.5
		_banner_pop_timer = maxf(0.0, _banner_pop_timer - dt * 2.8)

		var expired_ids: Array[int] = []
		for pid_key in _active_zone_players.keys():
			var entry: Dictionary = _active_zone_players[pid_key]
			var dur: float = float(entry.get("duration", 12.0))
			if dur > 0.0:
				var rem: float = maxf(0.0, float(entry.get("remaining", 0.0)) - dt)
				entry["remaining"] = rem
				if rem <= 0.0:
					expired_ids.append(int(pid_key))

		for expired_id in expired_ids:
			_active_zone_players.erase(expired_id)

		if _active_zone_players.is_empty():
			_zone_ui_active = false
			_active_zone_player_id = -1
			_vignette_intensity = 0.0
			if _cinematic_director != null:
				_cinematic_director.update_arena_lighting(_find_arena_root(), false, 0.0, _accent_color)
		else:
			if not _active_zone_players.has(_active_zone_player_id):
				_select_primary_active_player()
			var pop_boost: float = _banner_pop_timer * 0.45
			_vignette_intensity = clampf(0.95 + 0.18 * sin(_pulse_phase) + pop_boost, 0.65, 1.55)
	elif _vignette_intensity > 0.0:
		_vignette_intensity = 0.0

	_refresh_overlay_state()


# ==============================================================================
# Internal FX & Overlay Builders
# ==============================================================================

func _ensure_fx_built() -> void:
	if _fx_built:
		return
	_fx_built = true

	_screen_shake = get_node_or_null("ScreenShake") as ScreenShake
	if _screen_shake == null:
		_screen_shake = ScreenShake.new()
		_screen_shake.name = "ScreenShake"
		_screen_shake.auto_process = false
		add_child(_screen_shake)

	_cinematic_director = get_node_or_null("CinematicDirector") as CinematicDirector
	if _cinematic_director == null:
		_cinematic_director = CinematicDirector.new()
		_cinematic_director.name = "CinematicDirector"
		_cinematic_director.auto_process = false
		add_child(_cinematic_director)

	_burst_pool_root = get_node_or_null("BurstPool") as Node3D
	if _burst_pool_root == null:
		_burst_pool_root = Node3D.new()
		_burst_pool_root.name = "BurstPool"
		add_child(_burst_pool_root)

	if _burst_pool.is_empty():
		for i in range(BURST_POOL_SIZE):
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.vertex_color_use_as_albedo = true
			mat.albedo_color = Color.WHITE
			mat.emission_enabled = true
			mat.emission = DEFAULT_ZONE_COLOR
			mat.emission_energy_multiplier = 2.6

			var mesh := PrismMesh.new()
			mesh.size = Vector3(0.06, 0.20, 0.06)
			mesh.material = mat

			var cp := CPUParticles3D.new()
			cp.name = "BurstEmitter_%d" % i
			cp.mesh = mesh
			cp.one_shot = true
			cp.explosiveness = 0.90
			cp.randomness = 0.25
			cp.local_coords = false
			cp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			cp.emitting = false
			_burst_pool_root.add_child(cp)
			_burst_pool.append(cp)


func _ensure_ui_built() -> void:
	if _ui_built:
		return
	_ui_built = true

	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "ZoneOverlayLayer"
	_overlay_layer.layer = 20
	add_child(_overlay_layer)

	# 1. Screen-Edge Radial Speed Lines Overlay (active during sprinting/combos/dunks)
	_speed_lines_material = ShaderMaterial.new()
	if ResourceLoader.exists(SHADER_SPEED_LINES):
		var sl_shader := load(SHADER_SPEED_LINES) as Shader
		if sl_shader != null:
			_speed_lines_material.shader = sl_shader
	_speed_lines_material.set_shader_parameter("intensity", 0.0)
	_speed_lines_material.set_shader_parameter("line_color", Color(0.90, 0.98, 1.0, 1.0))

	_speed_lines_rect = ColorRect.new()
	_speed_lines_rect.name = "SpeedLinesRect"
	_speed_lines_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_speed_lines_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_speed_lines_rect.color = Color.WHITE
	_speed_lines_rect.material = _speed_lines_material
	_speed_lines_rect.visible = false
	_overlay_layer.add_child(_speed_lines_rect)

	# 2. Zone Awakening Overlay Root (Vignette + Reactive "ZONE AWAKENED" Banner)
	_overlay_root = Control.new()
	_overlay_root.name = "ZoneOverlayRoot"
	_overlay_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_root.visible = false
	_overlay_layer.add_child(_overlay_root)

	_vignette_material = ShaderMaterial.new()
	if ResourceLoader.exists(VIGNETTE_SHADER_PATH):
		var shader_res := load(VIGNETTE_SHADER_PATH) as Shader
		if shader_res != null:
			_vignette_material.shader = shader_res

	_vignette_rect = ColorRect.new()
	_vignette_rect.name = "ZoneVignette"
	_vignette_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette_rect.color = Color(1.0, 1.0, 1.0, 1.0)
	_vignette_rect.material = _vignette_material
	_overlay_root.add_child(_vignette_rect)

	_banner_panel = PanelContainer.new()
	_banner_panel.name = "ZoneAwakenedBanner"
	_banner_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_panel.anchor_left = 0.5
	_banner_panel.anchor_right = 0.5
	_banner_panel.anchor_top = 0.0
	_banner_panel.anchor_bottom = 0.0
	_banner_panel.offset_left = -190.0
	_banner_panel.offset_right = 190.0
	_banner_panel.offset_top = 74.0
	_banner_panel.offset_bottom = 148.0
	_banner_panel.pivot_offset = Vector2(190.0, 37.0)

	_banner_style = StyleBoxFlat.new()
	_banner_style.bg_color = Color(0.04, 0.07, 0.14, 0.78)
	_banner_style.border_color = _accent_color
	_banner_style.set_border_width_all(2)
	_banner_style.set_corner_radius_all(8)
	_banner_style.content_margin_left = 18.0
	_banner_style.content_margin_right = 18.0
	_banner_style.content_margin_top = 8.0
	_banner_style.content_margin_bottom = 8.0
	_banner_panel.add_theme_stylebox_override("panel", _banner_style)
	_overlay_root.add_child(_banner_panel)

	var vbox := VBoxContainer.new()
	vbox.name = "BannerVBox"
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 4)
	_banner_panel.add_child(vbox)

	_title_label = Label.new()
	_title_label.name = "ZoneTitleLabel"
	_title_label.text = ZONE_BANNER_TITLE
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	_title_label.add_theme_color_override("font_outline_color", _accent_color)
	_title_label.add_theme_constant_override("outline_size", 4)
	vbox.add_child(_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.name = "ZoneSubtitleLabel"
	_subtitle_label.text = "PLAYER 1 • UNLEASHED"
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_subtitle_label.add_theme_font_size_override("font_size", 12)
	_subtitle_label.add_theme_color_override("font_color", _accent_color)
	vbox.add_child(_subtitle_label)

	_timer_bar = ProgressBar.new()
	_timer_bar.name = "ZoneTimerBar"
	_timer_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_bar.min_value = 0.0
	_timer_bar.max_value = 1.0
	_timer_bar.value = 1.0
	_timer_bar.show_percentage = false
	_timer_bar.custom_minimum_size = Vector2(280.0, 6.0)

	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.10, 0.14, 0.24, 0.85)
	bar_bg.set_corner_radius_all(3)
	_timer_bar.add_theme_stylebox_override("background", bar_bg)

	_timer_fill_style = StyleBoxFlat.new()
	_timer_fill_style.bg_color = _accent_color
	_timer_fill_style.set_corner_radius_all(3)
	_timer_bar.add_theme_stylebox_override("fill", _timer_fill_style)
	vbox.add_child(_timer_bar)

	# 3. High-Contrast Anime Impact Frame Flash Overlay (topmost in VFX layer)
	_impact_frame_material = ShaderMaterial.new()
	if ResourceLoader.exists(SHADER_IMPACT_FRAME):
		var imp_shader := load(SHADER_IMPACT_FRAME) as Shader
		if imp_shader != null:
			_impact_frame_material.shader = imp_shader
	_impact_frame_material.set_shader_parameter("flash_strength", 0.0)
	_impact_frame_material.set_shader_parameter("flash_color", Color.WHITE)

	_impact_frame_rect = ColorRect.new()
	_impact_frame_rect.name = "ImpactFrameRect"
	_impact_frame_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_impact_frame_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_impact_frame_rect.color = Color.WHITE
	_impact_frame_rect.material = _impact_frame_material
	_impact_frame_rect.visible = false
	_overlay_layer.add_child(_impact_frame_rect)

	_apply_accent_color(_accent_color)


func _build_burst_gradient(base_color: Color) -> Gradient:
	var grad := Gradient.new()
	var hot := base_color.lerp(Color.WHITE, 0.65)
	hot.a = 1.0
	var mid := Color(base_color.r, base_color.g, base_color.b, 0.92)
	var tail := Color(base_color.r, base_color.g, base_color.b, 0.0)
	grad.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	grad.colors = PackedColorArray([hot, mid, tail])
	return grad


func _apply_accent_color(color: Color) -> void:
	if _vignette_material != null:
		_vignette_material.set_shader_parameter("vignette_color", color)
	if _banner_style != null:
		_banner_style.border_color = color
	if _title_label != null:
		_title_label.add_theme_color_override("font_outline_color", color)
	if _subtitle_label != null:
		_subtitle_label.add_theme_color_override("font_color", color.lerp(Color.WHITE, 0.25))
	if _timer_fill_style != null:
		_timer_fill_style.bg_color = color


func _refresh_overlay_state() -> void:
	_ensure_ui_built()

	# Zone vignette & banner
	if _overlay_root != null:
		_overlay_root.visible = _zone_ui_active
	if _vignette_material != null:
		_vignette_material.set_shader_parameter("intensity", _vignette_intensity if _zone_ui_active else 0.0)
	if _banner_panel != null and _zone_ui_active:
		var pop_scale: float = 1.0 + _banner_pop_timer * 0.22 + 0.025 * sin(_pulse_phase * 1.4)
		_banner_panel.scale = Vector2(pop_scale, pop_scale)
		if _active_zone_players.has(_active_zone_player_id):
			var entry: Dictionary = _active_zone_players[_active_zone_player_id]
			var dur: float = maxf(0.01, float(entry.get("duration", 12.0)))
			var rem: float = clampf(float(entry.get("remaining", dur)), 0.0, dur)
			if _subtitle_label != null:
				_subtitle_label.text = "PLAYER %d • LIMIT BREAK %.1fs" % [_active_zone_player_id, rem]
			if _timer_bar != null:
				_timer_bar.value = clampf(rem / dur, 0.0, 1.0)
	elif _banner_panel != null:
		_banner_panel.scale = Vector2.ONE

	# Speed lines shader overlay
	var speed_int: float = _cinematic_director.get_speed_lines_intensity() if _cinematic_director != null else 0.0
	if _speed_lines_rect != null:
		_speed_lines_rect.visible = speed_int > 0.005
	if _speed_lines_material != null:
		_speed_lines_material.set_shader_parameter("intensity", speed_int)

	# Impact frame flash shader overlay
	var flash_str: float = _cinematic_director.get_impact_flash_strength() if _cinematic_director != null else 0.0
	if _impact_frame_rect != null:
		_impact_frame_rect.visible = flash_str > 0.005
	if _impact_frame_material != null:
		_impact_frame_material.set_shader_parameter("flash_strength", flash_str)
		if _cinematic_director != null:
			_impact_frame_material.set_shader_parameter("flash_color", _cinematic_director.get_impact_flash_color())


# ==============================================================================
# Scene & Autoload Lookup Helpers
# ==============================================================================

func _get_autoload(autoload_name: String) -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null(autoload_name)
	return null


func _find_arena_root() -> Node:
	if get_parent() != null and get_parent().get_node_or_null("StadiumSpotlights") != null:
		return get_parent()
	if is_inside_tree() and get_tree() != null:
		var arenas: Array[Node] = get_tree().get_nodes_in_group("arena")
		if not arenas.is_empty() and is_instance_valid(arenas[0]):
			return arenas[0]
	return null


func _find_player_node(player_id: int) -> Node3D:
	if is_inside_tree() and get_tree() != null:
		for node in get_tree().get_nodes_in_group("players"):
			if is_instance_valid(node) and node is Node3D and _extract_player_id(node) == player_id:
				return node as Node3D
	return null


func _find_basketball_node() -> Node3D:
	if is_inside_tree() and get_tree() != null:
		var balls: Array[Node] = get_tree().get_nodes_in_group("basketball")
		for b in balls:
			if is_instance_valid(b) and b is Node3D:
				return b as Node3D
		var arena: Node = _find_arena_root()
		if arena != null:
			var direct_ball: Node = arena.get_node_or_null("Basketball")
			if direct_ball is Node3D:
				return direct_ball as Node3D
	return null


func _select_primary_active_player() -> void:
	if _active_zone_players.is_empty():
		_active_zone_player_id = -1
		return
	var gs: Node = _get_autoload("GameState")
	if gs != null and _active_zone_players.has(int(gs.get("local_player_id"))):
		_active_zone_player_id = int(gs.get("local_player_id"))
	else:
		var keys: Array = _active_zone_players.keys()
		_active_zone_player_id = int(keys[keys.size() - 1])
	var entry: Dictionary = _active_zone_players[_active_zone_player_id]
	var col: Variant = entry.get("color", DEFAULT_ZONE_COLOR)
	if col is Color:
		set_zone_accent_color(col as Color)


func _resolve_color_for_player_id(player_id: int) -> Color:
	var aura: AuraController = get_aura_for_player(player_id)
	if aura != null:
		return aura.get_aura_color()
	var pnode: Node3D = _find_player_node(player_id)
	if pnode != null:
		return _extract_player_aura_color(pnode)
	return DEFAULT_ZONE_COLOR


func _extract_player_id(player: Node) -> int:
	var raw: Variant = player.get("player_id")
	if raw != null:
		return int(raw)
	return 1


func _extract_player_aura_color(player: Node) -> Color:
	var raw_col: Variant = player.get("aura_color")
	if raw_col is Color and (raw_col as Color).a > 0.01:
		return raw_col as Color
	var anim: Node = player.get_node_or_null("CharacterAnimator")
	if anim != null:
		var anim_col: Variant = anim.get("aura_color")
		if anim_col is Color and (anim_col as Color).a > 0.01:
			return anim_col as Color
	var tid: Variant = player.get("team_id")
	if tid != null and int(tid) == 1:
		return Color(1.0, 0.35, 0.40, 1.0)
	return DEFAULT_ZONE_COLOR


# ==============================================================================
# EventBus Signal Wiring & Reactions (Phases 5 + 12)
# ==============================================================================

func _connect_event_bus() -> void:
	var eb: Node = _get_autoload("EventBus")
	if eb == null:
		return
	var signals_map: Array = [
		["zone_activated", _on_zone_activated],
		["zone_ended", _on_zone_ended],
		["match_restarted", _on_match_restarted],
		["dunk_impact", _on_dunk_impact],
		["combo_triggered", _on_combo_triggered],
		["ankle_broken", _on_ankle_broken],
		["block_performed", _on_block_performed],
		["score_changed", _on_score_changed],
		["shot_released", _on_shot_released],
	]
	for pair in signals_map:
		var sig_name: String = pair[0]
		var cb: Callable = pair[1]
		if eb.has_signal(sig_name) and not eb.is_connected(sig_name, cb):
			eb.connect(sig_name, cb)


func _disconnect_event_bus() -> void:
	var eb: Node = _get_autoload("EventBus")
	if eb == null:
		return
	var signals_map: Array = [
		["zone_activated", _on_zone_activated],
		["zone_ended", _on_zone_ended],
		["match_restarted", _on_match_restarted],
		["dunk_impact", _on_dunk_impact],
		["combo_triggered", _on_combo_triggered],
		["ankle_broken", _on_ankle_broken],
		["block_performed", _on_block_performed],
		["score_changed", _on_score_changed],
		["shot_released", _on_shot_released],
	]
	for pair in signals_map:
		var sig_name: String = pair[0]
		var cb: Callable = pair[1]
		if eb.has_signal(sig_name) and eb.is_connected(sig_name, cb):
			eb.disconnect(sig_name, cb)


func _on_zone_activated(player_id: int, duration: float) -> void:
	_ensure_fx_built()
	var color: Color = _resolve_color_for_player_id(player_id)
	var dur: float = maxf(0.1, duration)
	_active_zone_players[player_id] = {
		"duration": dur,
		"remaining": dur,
		"color": color,
	}
	_zone_ui_active = true
	_active_zone_player_id = player_id
	var gs: Node = _get_autoload("GameState")
	if gs != null:
		var local_pid: int = int(gs.get("local_player_id"))
		if _active_zone_players.has(local_pid):
			_active_zone_player_id = local_pid
			color = _active_zone_players[_active_zone_player_id].get("color", color)
	_banner_pop_timer = 1.0
	_vignette_intensity = 1.25
	set_zone_accent_color(color)
	if _cinematic_director != null:
		_cinematic_director.pulse_speed_lines(0.55, 0.45)
		_cinematic_director.update_arena_lighting(_find_arena_root(), true, 0.0, color)
	_refresh_overlay_state()


func _on_zone_ended(player_id: int) -> void:
	_active_zone_players.erase(player_id)
	if _active_zone_players.is_empty():
		_zone_ui_active = false
		_active_zone_player_id = -1
		_vignette_intensity = 0.0
		if _cinematic_director != null:
			_cinematic_director.update_arena_lighting(_find_arena_root(), false, 0.0, _accent_color)
	else:
		_select_primary_active_player()
	_refresh_overlay_state()


func _on_match_restarted() -> void:
	reset_vfx()


func _on_dunk_impact(player_id: int, rim_pos: Vector3, power: float) -> void:
	_ensure_fx_built()
	var col: Color = _resolve_color_for_player_id(player_id)
	spawn_burst("dunk_shockwave", rim_pos, col, clampf(power, 0.9, 2.0))

	if _screen_shake != null:
		_screen_shake.add_trauma(clampf(0.45 + power * 0.30, 0.65, 1.0))

	if _cinematic_director != null:
		_cinematic_director.trigger_impact_frame(3, Color.WHITE)
		_cinematic_director.trigger_cinematic_dunk(rim_pos, power)
		_cinematic_director.pulse_speed_lines(0.85, 0.42)
		if power >= 1.4:
			_cinematic_director.trigger_hit_stop(0.18, 0.25)
		_dunk_flash_timer = _dunk_flash_duration
		_cinematic_director.update_arena_lighting(_find_arena_root(), _zone_ui_active, 1.0, col)

	_refresh_overlay_state()


func _on_combo_triggered(player_id: int, _combo_id: String, _combo_tier: int, is_perfect: bool) -> void:
	_ensure_fx_built()
	var col: Color = Color(1.0, 0.84, 0.24, 1.0) if is_perfect else _resolve_color_for_player_id(player_id)
	var pnode: Node3D = _find_player_node(player_id)
	var pos: Vector3 = (pnode.global_position + Vector3(0.0, 0.95, 0.0)) if pnode != null else Vector3(0.0, 1.0, 0.0)
	spawn_burst("combo", pos, col, 1.25 if is_perfect else 0.95)

	if _cinematic_director != null:
		_cinematic_director.pulse_speed_lines(0.68 if is_perfect else 0.44, 0.32)

	if pnode != null:
		var trail: RibbonTrail3D = attach_trail_to_node(pnode, col, 0.32 if is_perfect else 0.24)
		if trail != null:
			trail.set_emitting(true)
			trail.set_intensity(1.85 if is_perfect else 1.35)

	_refresh_overlay_state()


func _on_ankle_broken(_victim_id: int, attacker_id: int, world_pos: Vector3) -> void:
	_ensure_fx_built()
	var col: Color = _resolve_color_for_player_id(attacker_id)
	spawn_burst("ankle_break", world_pos + Vector3(0.0, 0.45, 0.0), col, 1.25)

	if _screen_shake != null:
		_screen_shake.add_trauma(0.45)
	if _cinematic_director != null:
		_cinematic_director.trigger_impact_frame(2, Color(0.0, 0.94, 1.0, 1.0))

	_refresh_overlay_state()


func _on_block_performed(_blocker_id: int, _shooter_id: int, world_pos: Vector3) -> void:
	_ensure_fx_built()
	spawn_burst("block_swat", world_pos, Color(1.0, 0.92, 0.55, 1.0), 1.30)

	if _screen_shake != null:
		_screen_shake.add_trauma(0.55)
	if _cinematic_director != null:
		_cinematic_director.trigger_impact_frame(2, Color.WHITE)

	_refresh_overlay_state()


func _on_score_changed(team_id: int, _new_score: int, delta: int, is_three: bool, _scorer_id: int) -> void:
	if delta <= 0:
		return
	_ensure_fx_built()
	var rim_pos := Vector3(0.0, 3.05, -12.425) if team_id == 0 else Vector3(0.0, 3.05, 12.425)
	var col := Color(1.0, 0.84, 0.24, 1.0) if is_three else Color(0.15, 0.92, 1.0, 1.0)
	spawn_burst("swish", rim_pos, col, 1.35 if is_three else 1.0)


func _on_shot_released(_player_id: int, release_pos: Vector3, _target_rim: Vector3, is_three: bool, timing_quality: float) -> void:
	_ensure_fx_built()
	var ball: Node3D = _find_basketball_node()
	if ball == null:
		return
	var trail_col: Color
	if timing_quality >= 0.88:
		trail_col = Color(1.0, 0.84, 0.24, 1.0) # Golden Perfect release trail
	elif is_three:
		trail_col = Color(0.0, 0.94, 1.0, 1.0) # Electric Cyan 3pt arc trail
	else:
		trail_col = Color(1.0, 0.54, 0.16, 1.0) # Fiery Orange 2pt trail

	var trail: RibbonTrail3D = attach_trail_to_node(ball, trail_col, 0.20)
	if trail != null:
		trail.clear_trail()
		trail.set_emitting(true)
		trail.set_intensity(1.75 if timing_quality >= 0.88 else 1.30)
		trail.sample_point(release_pos, 0.0)
