class_name AuraController
extends Node3D
## Procedural 3D Anime Zone Energy Aura Controller.
## Builds a translucent rising energy capsule shell using `zone_aura.gdshader`,
## floor energy ring, rising stylized CPUParticles3D sparks, activation burst,
## and soft OmniLight3D floor glow — safe across Vulkan, OpenGL3, and --headless.

const AURA_SHADER_PATH := "res://shaders/zone_aura.gdshader"
const DEFAULT_AURA_COLOR := Color(0.15, 0.90, 1.0, 1.0)

@export var owner_player_id: int = 1
@export var aura_color: Color = DEFAULT_AURA_COLOR

var _is_active: bool = false
var _intensity: float = 0.0
var _duration: float = 12.0
var _time_remaining: float = 0.0
var _elapsed: float = 0.0
var _activation_surge: float = 0.0
var _pulse_speed: float = 3.4

var _aura_shell: MeshInstance3D = null
var _floor_ring: MeshInstance3D = null
var _aura_material: ShaderMaterial = null
var _sparks: CPUParticles3D = null
var _burst: CPUParticles3D = null
var _spark_material: StandardMaterial3D = null
var _glow_light: OmniLight3D = null
var _visuals_built: bool = false


func _enter_tree() -> void:
	_connect_event_bus()


func _ready() -> void:
	_ensure_visuals_built()
	_connect_event_bus()
	_apply_color_to_visuals()
	_sync_visuals()


func _exit_tree() -> void:
	_disconnect_event_bus()


func _process(delta: float) -> void:
	if delta > 0.0:
		step_aura(delta)


func setup(p_owner_player_id: int, color: Color = DEFAULT_AURA_COLOR) -> void:
	owner_player_id = p_owner_player_id
	_ensure_visuals_built()
	_connect_event_bus()
	set_aura_color(color)
	_sync_visuals()


func set_aura_color(color: Color) -> void:
	aura_color = Color(color.r, color.g, color.b, 1.0)
	_ensure_visuals_built()
	_apply_color_to_visuals()


func activate(duration: float = 12.0) -> void:
	_ensure_visuals_built()
	_is_active = true
	_duration = maxf(0.0, duration)
	_time_remaining = _duration
	_elapsed = 0.0
	_activation_surge = 1.0
	_intensity = 1.65

	if _aura_shell != null:
		_aura_shell.visible = true
	if _floor_ring != null:
		_floor_ring.visible = true
	if _sparks != null:
		_sparks.emitting = true
	if _burst != null:
		_burst.restart()
		_burst.emitting = true
	if _glow_light != null:
		_glow_light.visible = true

	_sync_visuals()


func deactivate() -> void:
	_is_active = false
	_time_remaining = 0.0
	_activation_surge = 0.0
	_intensity = 0.0

	if _aura_shell != null:
		_aura_shell.visible = false
	if _floor_ring != null:
		_floor_ring.visible = false
	if _sparks != null:
		_sparks.emitting = false
	if _burst != null:
		_burst.emitting = false
	if _glow_light != null:
		_glow_light.visible = false
		_glow_light.light_energy = 0.0

	_sync_visuals()


func is_aura_active() -> bool:
	return _is_active


func get_intensity() -> float:
	return _intensity


func get_aura_color() -> Color:
	return aura_color


func get_owner_player_id() -> int:
	return owner_player_id


func get_remaining_duration() -> float:
	return _time_remaining


func get_aura_mesh() -> MeshInstance3D:
	_ensure_visuals_built()
	return _aura_shell


func get_aura_material() -> ShaderMaterial:
	_ensure_visuals_built()
	return _aura_material


func get_sparks_particles() -> CPUParticles3D:
	_ensure_visuals_built()
	return _sparks


func step_aura(dt: float) -> void:
	if dt <= 0.0:
		return
	if not _is_active:
		if _intensity > 0.0:
			_intensity = 0.0
			_sync_visuals()
		return

	_elapsed += dt
	_activation_surge = maxf(0.0, _activation_surge - dt * 2.2)

	var base_pulse: float = 1.15 + 0.16 * sin(_elapsed * 5.2)
	var fade_factor: float = 1.0
	if _duration > 0.0:
		_time_remaining = maxf(0.0, _time_remaining - dt)
		if _time_remaining <= 0.0:
			deactivate()
			return
		if _time_remaining < 0.75:
			fade_factor = clampf(0.55 + 0.45 * (_time_remaining / 0.75), 0.55, 1.0)

	_intensity = (base_pulse + _activation_surge * 0.55) * fade_factor
	_sync_visuals()


func _ensure_visuals_built() -> void:
	if _visuals_built:
		return
	_visuals_built = true

	# 1. Procedural Zone Aura ShaderMaterial
	_aura_material = ShaderMaterial.new()
	if ResourceLoader.exists(AURA_SHADER_PATH):
		var shader_res := load(AURA_SHADER_PATH) as Shader
		if shader_res != null:
			_aura_material.shader = shader_res

	# 2. Translucent Energy Capsule Shell enveloping the CharacterAnimator rig
	_aura_shell = MeshInstance3D.new()
	_aura_shell.name = "AuraShell"
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.50
	capsule.height = 1.98
	capsule.radial_segments = 24
	capsule.rings = 8
	_aura_shell.mesh = capsule
	_aura_shell.material_override = _aura_material
	_aura_shell.position = Vector3(0.0, 0.98, 0.0)
	_aura_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aura_shell.visible = false
	add_child(_aura_shell)

	# 3. Ground Energy Halo Ring around player's sneakers
	_floor_ring = MeshInstance3D.new()
	_floor_ring.name = "ZoneFloorRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.48
	torus.outer_radius = 0.64
	torus.rings = 24
	torus.ring_segments = 10
	_floor_ring.mesh = torus
	_floor_ring.material_override = _aura_material
	_floor_ring.position = Vector3(0.0, 0.04, 0.0)
	_floor_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_floor_ring.visible = false
	add_child(_floor_ring)

	# 4. Stylized Rising Anime Energy Sparks (CPUParticles3D — Vulkan/GL3/Headless safe)
	_spark_material = StandardMaterial3D.new()
	_spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_spark_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_spark_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_spark_material.vertex_color_use_as_albedo = true
	_spark_material.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	_spark_material.emission_enabled = true
	_spark_material.emission = aura_color
	_spark_material.emission_energy_multiplier = 2.4

	var spark_mesh := PrismMesh.new()
	spark_mesh.size = Vector3(0.048, 0.22, 0.048)
	spark_mesh.material = _spark_material

	_sparks = CPUParticles3D.new()
	_sparks.name = "ZoneSparks"
	_sparks.position = Vector3(0.0, 0.75, 0.0)
	_sparks.mesh = spark_mesh
	_sparks.amount = 36
	_sparks.lifetime = 0.85
	_sparks.randomness = 0.35
	_sparks.local_coords = false
	_sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_sparks.emission_box_extents = Vector3(0.42, 0.68, 0.42)
	_sparks.direction = Vector3(0.0, 1.0, 0.0)
	_sparks.spread = 18.0
	_sparks.gravity = Vector3(0.0, 1.8, 0.0)
	_sparks.initial_velocity_min = 1.6
	_sparks.initial_velocity_max = 3.4
	_sparks.scale_amount_min = 0.55
	_sparks.scale_amount_max = 1.25
	_sparks.color_ramp = _build_spark_gradient(aura_color)
	_sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sparks.emitting = false
	add_child(_sparks)

	# 5. One-Shot Activation Energy Shockwave Burst
	_burst = CPUParticles3D.new()
	_burst.name = "ZoneActivationBurst"
	_burst.position = Vector3(0.0, 0.95, 0.0)
	_burst.mesh = spark_mesh
	_burst.amount = 24
	_burst.lifetime = 0.55
	_burst.one_shot = true
	_burst.explosiveness = 0.90
	_burst.randomness = 0.25
	_burst.local_coords = false
	_burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_burst.emission_sphere_radius = 0.30
	_burst.direction = Vector3(0.0, 1.0, 0.0)
	_burst.spread = 70.0
	_burst.gravity = Vector3(0.0, 0.8, 0.0)
	_burst.initial_velocity_min = 3.2
	_burst.initial_velocity_max = 5.8
	_burst.scale_amount_min = 0.8
	_burst.scale_amount_max = 1.6
	_burst.color_ramp = _build_spark_gradient(aura_color)
	_burst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_burst.emitting = false
	add_child(_burst)

	# 6. Soft Court-Floor Aura Glow Light
	_glow_light = OmniLight3D.new()
	_glow_light.name = "ZoneGlowLight"
	_glow_light.position = Vector3(0.0, 1.05, 0.0)
	_glow_light.light_color = aura_color
	_glow_light.omni_range = 3.4
	_glow_light.light_energy = 0.0
	_glow_light.shadow_enabled = false
	_glow_light.visible = false
	add_child(_glow_light)

	_apply_color_to_visuals()


func _build_spark_gradient(base_color: Color) -> Gradient:
	var grad := Gradient.new()
	var hot_core := base_color.lerp(Color(1.0, 1.0, 1.0, 1.0), 0.65)
	hot_core.a = 1.0
	var mid_col := Color(base_color.r, base_color.g, base_color.b, 0.92)
	var fade_col := Color(base_color.r, base_color.g, base_color.b, 0.0)
	grad.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	grad.colors = PackedColorArray([hot_core, mid_col, fade_col])
	return grad


func _apply_color_to_visuals() -> void:
	if _aura_material != null:
		_aura_material.set_shader_parameter("aura_color", aura_color)
	if _spark_material != null:
		_spark_material.emission = aura_color
	var grad := _build_spark_gradient(aura_color)
	if _sparks != null:
		_sparks.color_ramp = grad
	if _burst != null:
		_burst.color_ramp = grad
	if _glow_light != null:
		_glow_light.light_color = aura_color


func _sync_visuals() -> void:
	if _aura_material != null:
		_aura_material.set_shader_parameter("intensity", _intensity)
		_aura_material.set_shader_parameter("pulse_speed", _pulse_speed + _activation_surge * 2.4)
	if _floor_ring != null and _is_active:
		var ring_scale: float = 1.0 + 0.08 * sin(_elapsed * 6.0) + _activation_surge * 0.25
		_floor_ring.scale = Vector3(ring_scale, 1.0, ring_scale)
	if _glow_light != null:
		_glow_light.light_energy = clampf(_intensity * 1.15, 0.0, 2.5) if _is_active else 0.0


func _get_event_bus() -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null("EventBus")
	return null


func _connect_event_bus() -> void:
	var eb: Node = _get_event_bus()
	if eb == null:
		return
	if not eb.is_connected("zone_activated", _on_zone_activated):
		eb.connect("zone_activated", _on_zone_activated)
	if not eb.is_connected("zone_ended", _on_zone_ended):
		eb.connect("zone_ended", _on_zone_ended)
	if not eb.is_connected("match_restarted", _on_match_restarted):
		eb.connect("match_restarted", _on_match_restarted)


func _disconnect_event_bus() -> void:
	var eb: Node = _get_event_bus()
	if eb == null:
		return
	if eb.is_connected("zone_activated", _on_zone_activated):
		eb.disconnect("zone_activated", _on_zone_activated)
	if eb.is_connected("zone_ended", _on_zone_ended):
		eb.disconnect("zone_ended", _on_zone_ended)
	if eb.is_connected("match_restarted", _on_match_restarted):
		eb.disconnect("match_restarted", _on_match_restarted)


func _on_zone_activated(player_id: int, duration: float) -> void:
	if player_id == owner_player_id:
		activate(duration)


func _on_zone_ended(player_id: int) -> void:
	if player_id == owner_player_id:
		deactivate()


func _on_match_restarted() -> void:
	deactivate()
