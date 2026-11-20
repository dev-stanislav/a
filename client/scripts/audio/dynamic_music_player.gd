class_name DynamicMusicPlayer
extends Node
## Adaptive Dual-Stem Basketball Court Music Player (Phases 5 + 13).
## Plays the procedural base court loop and smoothly crossfades in the high-intensity
## Zone Awakening layer on EventBus.zone_activated (decaying cleanly on zone_ended),
## plus clutch final-30s & match-momentum intensity modulation.

const MUSIC_BUS_NAME := "Music"
const BASE_NORMAL_DB: float = -6.0
const BASE_ZONE_DB: float = -9.5
const ZONE_SILENT_DB: float = -60.0
const ZONE_FULL_DB: float = -2.5
const CLUTCH_FLOOR_INTENSITY: float = 0.42

@export var auto_start: bool = true
@export var ramp_up_rate: float = 2.6
@export var decay_rate: float = 1.5

var _intensity: float = 0.0
var _target_intensity: float = 0.0
var _manual_target_intensity: float = 0.0
var _clutch_mode: bool = false
var _momentum_boost: float = 0.0
var _active_zone_players: Dictionary = {} # player_id: int -> true

var _base_player: AudioStreamPlayer = null
var _zone_player: AudioStreamPlayer = null
var _base_stream: AudioStreamWAV = null
var _zone_stream: AudioStreamWAV = null
var _initialized: bool = false


func _enter_tree() -> void:
	_connect_event_bus()


func _ready() -> void:
	_ensure_initialized()
	_connect_event_bus()
	if auto_start:
		start_music()


func _exit_tree() -> void:
	stop_music()
	if _base_player != null and is_instance_valid(_base_player):
		_base_player.stream = null
	if _zone_player != null and is_instance_valid(_zone_player):
		_zone_player.stream = null
	_disconnect_event_bus()


func _process(delta: float) -> void:
	if delta > 0.0:
		step_music(delta)


func start_music() -> void:
	_ensure_initialized()
	if _base_player != null and _base_player.stream == null:
		_base_player.stream = _base_stream
	if _zone_player != null and _zone_player.stream == null:
		_zone_player.stream = _zone_stream
	_refresh_bus_assignment()
	_apply_mix()
	if _base_player != null and not _base_player.playing:
		_base_player.play()
	if _zone_player != null and not _zone_player.playing:
		_zone_player.play()


func stop_music() -> void:
	if _base_player != null and _base_player.playing:
		_base_player.stop()
	if _zone_player != null and _zone_player.playing:
		_zone_player.stop()


func set_target_intensity(target: float, immediate: bool = false) -> void:
	_ensure_initialized()
	_manual_target_intensity = clampf(target, 0.0, 1.0)
	_target_intensity = _compute_effective_target()
	if immediate:
		_intensity = _target_intensity
	_apply_mix()


func set_clutch_mode(enabled: bool) -> void:
	_ensure_initialized()
	if _clutch_mode == enabled:
		return
	_clutch_mode = enabled
	_target_intensity = _compute_effective_target()
	_apply_mix()


func is_clutch_mode() -> bool:
	return _clutch_mode


func set_momentum_boost(val: float) -> void:
	_ensure_initialized()
	_momentum_boost = clampf(val, 0.0, 0.35)
	_target_intensity = _compute_effective_target()
	_apply_mix()


func get_intensity() -> float:
	return _intensity


func get_target_intensity() -> float:
	return _target_intensity


func is_zone_music_active() -> bool:
	return not _active_zone_players.is_empty() or _target_intensity > 0.01


func is_playing() -> bool:
	return _base_player != null and _base_player.playing


func get_base_player() -> AudioStreamPlayer:
	_ensure_initialized()
	return _base_player


func get_zone_player() -> AudioStreamPlayer:
	_ensure_initialized()
	return _zone_player


func get_base_stream() -> AudioStreamWAV:
	_ensure_initialized()
	return _base_stream


func get_zone_stream() -> AudioStreamWAV:
	_ensure_initialized()
	return _zone_stream


func step_music(dt: float) -> void:
	if dt <= 0.0:
		return
	_ensure_initialized()
	if _momentum_boost > 0.0:
		_momentum_boost = maxf(0.0, _momentum_boost - dt * 0.35)
		_target_intensity = _compute_effective_target()

	var prev: float = _intensity
	if _intensity < _target_intensity:
		_intensity = minf(_target_intensity, _intensity + ramp_up_rate * dt)
	elif _intensity > _target_intensity:
		_intensity = maxf(_target_intensity, _intensity - decay_rate * dt)
	if absf(_intensity - prev) > 1e-6:
		_apply_mix()


func reset_intensity() -> void:
	_active_zone_players.clear()
	_clutch_mode = false
	_momentum_boost = 0.0
	_manual_target_intensity = 0.0
	_target_intensity = 0.0
	_intensity = 0.0
	_apply_mix()


func _compute_effective_target() -> float:
	if not _active_zone_players.is_empty():
		return 1.0
	var floor_val: float = CLUTCH_FLOOR_INTENSITY if _clutch_mode else 0.0
	return clampf(maxf(_manual_target_intensity, floor_val + _momentum_boost), 0.0, 1.0)


func _ensure_initialized() -> void:
	if _initialized:
		return
	_initialized = true

	_base_stream = ProceduralSfxSynth.generate_base_music_loop()
	_zone_stream = ProceduralSfxSynth.generate_zone_intense_music_layer()

	_base_player = AudioStreamPlayer.new()
	_base_player.name = "BaseMusicPlayer"
	_base_player.stream = _base_stream
	_base_player.volume_db = BASE_NORMAL_DB
	add_child(_base_player)

	_zone_player = AudioStreamPlayer.new()
	_zone_player.name = "ZoneMusicPlayer"
	_zone_player.stream = _zone_stream
	_zone_player.volume_db = ZONE_SILENT_DB
	add_child(_zone_player)

	_refresh_bus_assignment()
	_apply_mix()


func _refresh_bus_assignment() -> void:
	var bus_name: StringName = StringName(MUSIC_BUS_NAME) if AudioServer.get_bus_index(MUSIC_BUS_NAME) >= 0 else &"Master"
	if _base_player != null:
		_base_player.bus = bus_name
	if _zone_player != null:
		_zone_player.bus = bus_name


func _apply_mix() -> void:
	var clamped: float = clampf(_intensity, 0.0, 1.0)
	var clutch_lift: float = 0.015 if _clutch_mode else 0.0
	var pitch: float = lerpf(1.0 + clutch_lift, 1.035, clamped)
	if _base_player != null:
		_base_player.volume_db = lerpf(BASE_NORMAL_DB, BASE_ZONE_DB, clamped)
		_base_player.pitch_scale = pitch
	if _zone_player != null:
		if clamped <= 0.001:
			_zone_player.volume_db = ZONE_SILENT_DB
		else:
			var smooth_gain: float = sqrt(clamped)
			_zone_player.volume_db = lerpf(-28.0, ZONE_FULL_DB, smooth_gain)
		_zone_player.pitch_scale = pitch


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


func _on_zone_activated(player_id: int, _duration: float) -> void:
	_ensure_initialized()
	_active_zone_players[player_id] = true
	_target_intensity = 1.0
	_intensity = maxf(_intensity, 0.35)
	if not is_playing() and auto_start:
		start_music()
	_apply_mix()


func _on_zone_ended(player_id: int) -> void:
	_active_zone_players.erase(player_id)
	if _active_zone_players.is_empty():
		_momentum_boost = 0.0
	_target_intensity = _compute_effective_target()


func _on_match_restarted() -> void:
	reset_intensity()
