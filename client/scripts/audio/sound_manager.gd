class_name SoundManager
extends Node
## Central Audio Bus, 2D + Spatial 3D Procedural SFX, Crowd Ambience & Dynamic Music Manager.
## Ensures AudioServer buses (`Master`, `SFX`, `Music`, `Ambience`), drives all Phase 13
## EventBus court/combo/crowd/Zone/buzzer SFX, and owns DynamicMusicPlayer.

const BUS_MASTER := "Master"
const BUS_SFX := "SFX"
const BUS_MUSIC := "Music"
const BUS_AMBIENCE := "Ambience"
const REQUIRED_BUSES: PackedStringArray = [BUS_SFX, BUS_MUSIC, BUS_AMBIENCE]

const SFX_2D_POOL_SIZE: int = 12
const SFX_3D_POOL_SIZE: int = 10
const AMBIENCE_BASE_DB: float = -16.0
const AMBIENCE_EXCITED_DB: float = -5.5
const CROWD_EXCITEMENT_DECAY: float = 0.28

@export var auto_start_music: bool = true
@export var auto_start_ambience: bool = true

var music_player: DynamicMusicPlayer = null

var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_pool_cursor: int = 0
var _spatial_pool_root: Node3D = null
var _sfx_3d_pool: Array[AudioStreamPlayer3D] = []
var _sfx_3d_cursor: int = 0
var _crowd_ambience_player: AudioStreamPlayer = null
var _zone_hum_player: AudioStreamPlayer = null

var _streams: Dictionary = {} # name: String -> AudioStreamWAV
var _play_counts: Dictionary = {} # tag: String -> int
var _total_plays: int = 0
var _last_played_sfx: String = ""
var _last_3d_play_position: Vector3 = Vector3.ZERO
var _last_combo_pitch: float = 1.0
var _crowd_excitement: float = 0.0
var _active_zone_players: Dictionary = {} # player_id: int -> true
var _sprint_step_counters: Dictionary = {} # player_id: int -> int
var _shot_clock_buzzer_fired: bool = false
var _initialized: bool = false


func _enter_tree() -> void:
	ensure_audio_buses()
	_connect_event_bus()


func _ready() -> void:
	add_to_group("sound_manager")
	_ensure_initialized()
	_connect_event_bus()


func _exit_tree() -> void:
	for sp in _sfx_pool:
		if is_instance_valid(sp):
			if sp.playing:
				sp.stop()
			sp.stream = null
	for sp3 in _sfx_3d_pool:
		if is_instance_valid(sp3):
			if sp3.playing:
				sp3.stop()
			sp3.stream = null
	if _crowd_ambience_player != null and is_instance_valid(_crowd_ambience_player):
		if _crowd_ambience_player.playing:
			_crowd_ambience_player.stop()
		_crowd_ambience_player.stream = null
	if _zone_hum_player != null and is_instance_valid(_zone_hum_player):
		if _zone_hum_player.playing:
			_zone_hum_player.stop()
		_zone_hum_player.stream = null
	if music_player != null and is_instance_valid(music_player):
		music_player.stop_music()
	_disconnect_event_bus()


func _process(delta: float) -> void:
	if delta > 0.0:
		step_audio(delta)


# ==============================================================================
# AudioServer Bus & Volume Control API
# ==============================================================================

func ensure_audio_buses() -> void:
	for bus_name in REQUIRED_BUSES:
		if AudioServer.get_bus_index(bus_name) == -1:
			var new_idx: int = AudioServer.bus_count
			AudioServer.add_bus(new_idx)
			AudioServer.set_bus_name(new_idx, bus_name)
			AudioServer.set_bus_send(new_idx, BUS_MASTER)


func apply_volume_settings() -> void:
	ensure_audio_buses()
	var master_vol: float = 0.85
	var sfx_vol: float = 0.90
	var music_vol: float = 0.70
	var ambience_vol: float = 0.65
	var cm: Node = _get_autoload("ConfigManager")
	if cm != null and cm.has_method("get_setting"):
		master_vol = float(cm.call("get_setting", "audio", "master_volume", 0.85))
		sfx_vol = float(cm.call("get_setting", "audio", "sfx_volume", 0.90))
		music_vol = float(cm.call("get_setting", "audio", "music_volume", 0.70))
		ambience_vol = float(cm.call("get_setting", "audio", "ambience_volume", 0.65))

	set_bus_volume_linear(BUS_MASTER, master_vol)
	set_bus_volume_linear(BUS_SFX, sfx_vol)
	set_bus_volume_linear(BUS_MUSIC, music_vol)
	set_bus_volume_linear(BUS_AMBIENCE, ambience_vol)


func set_bus_volume_linear(bus_name: String, vol_linear: float) -> void:
	ensure_audio_buses()
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	var clamped: float = clampf(vol_linear, 0.0, 1.5)
	if clamped <= 0.0001:
		AudioServer.set_bus_volume_db(idx, -80.0)
		AudioServer.set_bus_mute(idx, true)
	else:
		AudioServer.set_bus_mute(idx, false)
		AudioServer.set_bus_volume_db(idx, linear_to_db(clamped))


func get_bus_volume_linear(bus_name: String) -> float:
	ensure_audio_buses()
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return 0.0
	if AudioServer.is_bus_mute(idx):
		return 0.0
	var db: float = AudioServer.get_bus_volume_db(idx)
	if db <= -79.5:
		return 0.0
	return db_to_linear(db)


func get_bus_names() -> PackedStringArray:
	var names := PackedStringArray()
	for idx in range(AudioServer.bus_count):
		names.append(AudioServer.get_bus_name(idx))
	return names


# ==============================================================================
# Public Playback & Crowd Excitement API
# ==============================================================================

func play_sfx(
	stream: AudioStream,
	volume_db: float = 0.0,
	pitch_scale: float = 1.0,
	sfx_tag: String = ""
) -> AudioStreamPlayer:
	if stream == null:
		return null
	_ensure_initialized()
	var player: AudioStreamPlayer = _acquire_sfx_player()
	if player == null:
		return null

	var bus_name: StringName = StringName(BUS_SFX) if AudioServer.get_bus_index(BUS_SFX) >= 0 else &"Master"
	player.bus = bus_name
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = clampf(pitch_scale, 0.25, 4.0)
	player.play()

	if not sfx_tag.is_empty():
		_record_play(sfx_tag)
	return player


func play_sfx_by_name(
	sfx_name: String,
	volume_db: float = 0.0,
	pitch_scale: float = 1.0
) -> AudioStreamPlayer:
	_ensure_initialized()
	var stream: AudioStreamWAV = get_sfx_stream(sfx_name)
	if stream == null:
		return null
	return play_sfx(stream, volume_db, pitch_scale, sfx_name.strip_edges().to_lower())


func play_sfx_3d(
	sfx_name: String,
	world_pos: Vector3,
	pitch_scale: float = 1.0,
	volume_db: float = 0.0
) -> AudioStreamPlayer3D:
	_ensure_initialized()
	var key: String = sfx_name.strip_edges().to_lower()
	var stream: AudioStreamWAV = get_sfx_stream(key)
	if stream == null:
		return null

	var player3d: AudioStreamPlayer3D = _acquire_sfx_3d_player()
	if player3d == null:
		return null

	var bus_name: StringName = StringName(BUS_SFX) if AudioServer.get_bus_index(BUS_SFX) >= 0 else &"Master"
	player3d.bus = bus_name
	player3d.position = world_pos
	player3d.stream = stream
	player3d.volume_db = volume_db
	player3d.pitch_scale = clampf(pitch_scale, 0.25, 4.0)
	player3d.play()

	_last_3d_play_position = world_pos
	_record_play(key)
	return player3d


func play_zone_activate_sfx() -> AudioStreamPlayer:
	_ensure_initialized()
	return play_sfx(get_sfx_stream("zone_activate"), -1.5, 1.0, "zone_activate")


func play_zone_end_sfx() -> AudioStreamPlayer:
	_ensure_initialized()
	return play_sfx(get_sfx_stream("zone_end"), -3.5, 1.0, "zone_end")


func add_crowd_excitement(amount: float) -> void:
	if amount <= 0.0:
		return
	_crowd_excitement = clampf(_crowd_excitement + amount, 0.0, 1.0)
	_apply_ambience_mix()


func step_audio(dt: float) -> void:
	if dt <= 0.0:
		return
	if _crowd_excitement > 0.0:
		_crowd_excitement = maxf(0.0, _crowd_excitement - CROWD_EXCITEMENT_DECAY * dt)
		_apply_ambience_mix()


# ==============================================================================
# QA Inspection Getters
# ==============================================================================

func get_music_player() -> DynamicMusicPlayer:
	_ensure_initialized()
	return music_player


func get_zone_intensity() -> float:
	_ensure_initialized()
	return music_player.get_intensity() if music_player != null else 0.0


func get_sfx_stream(sfx_name: String) -> AudioStreamWAV:
	_ensure_initialized()
	var key: String = sfx_name.strip_edges().to_lower()
	if _streams.has(key):
		return _streams[key] as AudioStreamWAV
	var generated: AudioStreamWAV = ProceduralSfxSynth.get_sfx_by_name(key)
	if generated != null:
		_streams[key] = generated
	return generated


func get_all_loaded_sfx_names() -> Array[String]:
	_ensure_initialized()
	return ProceduralSfxSynth.get_all_sfx_names()


func get_last_played_sfx() -> String:
	return _last_played_sfx


func get_last_3d_play_position() -> Vector3:
	return _last_3d_play_position


func get_last_combo_pitch() -> float:
	return _last_combo_pitch


func get_play_count(sfx_name: String) -> int:
	return int(_play_counts.get(sfx_name.strip_edges().to_lower(), 0))


func get_total_plays() -> int:
	return _total_plays


func get_crowd_excitement() -> float:
	return _crowd_excitement


func is_ambience_playing() -> bool:
	_ensure_initialized()
	return _crowd_ambience_player != null and _crowd_ambience_player.playing


func is_zone_hum_playing() -> bool:
	_ensure_initialized()
	return _zone_hum_player != null and _zone_hum_player.playing


func reset_stats() -> void:
	_play_counts.clear()
	_total_plays = 0
	_last_played_sfx = ""
	_last_3d_play_position = Vector3.ZERO
	_last_combo_pitch = 1.0
	_crowd_excitement = 0.0
	_sprint_step_counters.clear()
	_shot_clock_buzzer_fired = false
	_apply_ambience_mix()


# ==============================================================================
# Initialization & Pooling
# ==============================================================================

func _ensure_initialized() -> void:
	if _initialized:
		return
	_initialized = true

	ensure_audio_buses()
	apply_volume_settings()

	# Preload all 24 canonical procedural 44.1 kHz WAV streams (cached statically across scenes)
	for sfx_name in ProceduralSfxSynth.get_all_sfx_names():
		_streams[sfx_name] = ProceduralSfxSynth.get_sfx_by_name(sfx_name)
	# Phase 5 compatibility aliases
	_streams["base_music"] = _streams.get("base_music_loop")
	_streams["zone_music"] = _streams.get("zone_intense_music_layer")

	var sfx_bus: StringName = StringName(BUS_SFX) if AudioServer.get_bus_index(BUS_SFX) >= 0 else &"Master"
	var amb_bus: StringName = StringName(BUS_AMBIENCE) if AudioServer.get_bus_index(BUS_AMBIENCE) >= 0 else &"Master"

	# 1. 2D SFX Pool
	for i in range(SFX_2D_POOL_SIZE):
		var sp := AudioStreamPlayer.new()
		sp.name = "SfxChannel_%d" % i
		sp.bus = sfx_bus
		add_child(sp)
		_sfx_pool.append(sp)

	# 2. Spatial 3D Court SFX Pool
	_spatial_pool_root = Node3D.new()
	_spatial_pool_root.name = "SpatialSfxPool"
	add_child(_spatial_pool_root)
	for i in range(SFX_3D_POOL_SIZE):
		var sp3 := AudioStreamPlayer3D.new()
		sp3.name = "SpatialSfxChannel_%d" % i
		sp3.bus = sfx_bus
		sp3.unit_size = 8.0
		sp3.max_distance = 38.0
		sp3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		_spatial_pool_root.add_child(sp3)
		_sfx_3d_pool.append(sp3)

	# 3. Looping Stadium Crowd Ambience Player
	_crowd_ambience_player = AudioStreamPlayer.new()
	_crowd_ambience_player.name = "CrowdAmbiencePlayer"
	_crowd_ambience_player.bus = amb_bus
	_crowd_ambience_player.stream = _streams.get("crowd_ambiance") as AudioStream
	_crowd_ambience_player.volume_db = AMBIENCE_BASE_DB
	add_child(_crowd_ambience_player)
	if auto_start_ambience and _crowd_ambience_player.stream != null:
		_crowd_ambience_player.play()

	# 4. Looping Electric Zone Aura Hum Player (active while any player is in Zone)
	_zone_hum_player = AudioStreamPlayer.new()
	_zone_hum_player.name = "ZoneAuraHumPlayer"
	_zone_hum_player.bus = sfx_bus
	_zone_hum_player.stream = _streams.get("zone_aura_hum") as AudioStream
	_zone_hum_player.volume_db = -12.0
	add_child(_zone_hum_player)

	# 5. Adaptive Dual-Stem DynamicMusicPlayer
	music_player = get_node_or_null("DynamicMusicPlayer") as DynamicMusicPlayer
	if music_player == null:
		music_player = DynamicMusicPlayer.new()
		music_player.name = "DynamicMusicPlayer"
		music_player.auto_start = auto_start_music
		add_child(music_player)


func _acquire_sfx_player() -> AudioStreamPlayer:
	for sp in _sfx_pool:
		if is_instance_valid(sp) and not sp.playing:
			return sp
	if _sfx_pool.is_empty():
		return null
	var chosen: AudioStreamPlayer = _sfx_pool[_sfx_pool_cursor % _sfx_pool.size()]
	_sfx_pool_cursor = (_sfx_pool_cursor + 1) % _sfx_pool.size()
	return chosen


func _acquire_sfx_3d_player() -> AudioStreamPlayer3D:
	for sp3 in _sfx_3d_pool:
		if is_instance_valid(sp3) and not sp3.playing:
			return sp3
	if _sfx_3d_pool.is_empty():
		return null
	var chosen: AudioStreamPlayer3D = _sfx_3d_pool[_sfx_3d_cursor % _sfx_3d_pool.size()]
	_sfx_3d_cursor = (_sfx_3d_cursor + 1) % _sfx_3d_pool.size()
	return chosen


func _record_play(sfx_tag: String) -> void:
	_last_played_sfx = sfx_tag
	_play_counts[sfx_tag] = int(_play_counts.get(sfx_tag, 0)) + 1
	_total_plays += 1


func _apply_ambience_mix() -> void:
	if _crowd_ambience_player != null and is_instance_valid(_crowd_ambience_player):
		_crowd_ambience_player.volume_db = lerpf(AMBIENCE_BASE_DB, AMBIENCE_EXCITED_DB, _crowd_excitement)


# ==============================================================================
# EventBus Signal Wiring & Handlers (All Canonical Gameplay Audio Triggers)
# ==============================================================================

func _get_autoload(autoload_name: String) -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null(autoload_name)
	return null


func _connect_event_bus() -> void:
	var eb: Node = _get_autoload("EventBus")
	if eb == null:
		return
	var bindings: Array = [
		["ball_bounced", _on_ball_bounced],
		["player_footstep", _on_player_footstep],
		["dribble_move_performed", _on_dribble_move_performed],
		["combo_triggered", _on_combo_triggered],
		["shot_timing_feedback", _on_shot_timing_feedback],
		["score_changed", _on_score_changed],
		["dunk_impact", _on_dunk_impact],
		["ankle_broken", _on_ankle_broken],
		["block_performed", _on_block_performed],
		["steal_performed", _on_steal_performed],
		["zone_activated", _on_zone_activated],
		["zone_ended", _on_zone_ended],
		["match_ended", _on_match_ended],
		["timer_updated", _on_timer_updated],
		["match_restarted", _on_match_restarted],
	]
	for pair in bindings:
		var sig_name: String = pair[0]
		var cb: Callable = pair[1]
		if eb.has_signal(sig_name) and not eb.is_connected(sig_name, cb):
			eb.connect(sig_name, cb)


func _disconnect_event_bus() -> void:
	var eb: Node = _get_autoload("EventBus")
	if eb == null:
		return
	var bindings: Array = [
		["ball_bounced", _on_ball_bounced],
		["player_footstep", _on_player_footstep],
		["dribble_move_performed", _on_dribble_move_performed],
		["combo_triggered", _on_combo_triggered],
		["shot_timing_feedback", _on_shot_timing_feedback],
		["score_changed", _on_score_changed],
		["dunk_impact", _on_dunk_impact],
		["ankle_broken", _on_ankle_broken],
		["block_performed", _on_block_performed],
		["steal_performed", _on_steal_performed],
		["zone_activated", _on_zone_activated],
		["zone_ended", _on_zone_ended],
		["match_ended", _on_match_ended],
		["timer_updated", _on_timer_updated],
		["match_restarted", _on_match_restarted],
	]
	for pair in bindings:
		var sig_name: String = pair[0]
		var cb: Callable = pair[1]
		if eb.has_signal(sig_name) and eb.is_connected(sig_name, cb):
			eb.disconnect(sig_name, cb)


func _on_ball_bounced(world_pos: Vector3, impact_speed: float, surface_type: String) -> void:
	var speed_norm: float = clampf(impact_speed / 12.0, 0.10, 1.0)
	var vol_db: float = lerpf(-14.0, 1.5, speed_norm)
	var pitch: float = lerpf(0.88, 1.18, speed_norm)
	match surface_type.strip_edges().to_lower():
		"rim", "hoop":
			play_sfx_3d("rim_clang", world_pos, pitch, vol_db)
		"backboard", "glass":
			play_sfx_3d("backboard_thud", world_pos, pitch, vol_db)
		"wall":
			play_sfx_3d("backboard_thud", world_pos, pitch * 0.85, vol_db - 4.0)
		_:
			play_sfx_3d("ball_bounce", world_pos, pitch, vol_db)


func _on_player_footstep(player_id: int, world_pos: Vector3, is_sprint: bool) -> void:
	var step_pitch: float = 1.08 if is_sprint else 0.96
	var step_vol: float = -6.0 if is_sprint else -10.5
	play_sfx_3d("footstep", world_pos, step_pitch, step_vol)
	if is_sprint:
		var count: int = int(_sprint_step_counters.get(player_id, 0)) + 1
		_sprint_step_counters[player_id] = count
		if (count % 3) == 1:
			play_sfx_3d("shoe_squeak", world_pos, 1.02 + float(count % 4) * 0.03, -6.5)


func _on_dribble_move_performed(_player_id: int, _move_name: String, world_pos: Vector3) -> void:
	play_sfx_3d("dribble_whoosh", world_pos, 1.04, -2.5)
	play_sfx_3d("shoe_squeak", world_pos, 1.05, -5.0)


func _on_combo_triggered(_player_id: int, _combo_id: String, combo_tier: int, is_perfect: bool) -> void:
	var tier_pitch: float = clampf(1.0 + 0.12 * float(maxi(0, combo_tier - 1)), 0.85, 1.90)
	_last_combo_pitch = tier_pitch
	play_sfx_by_name("combo_chime", -2.0, tier_pitch)
	if is_perfect:
		play_sfx_by_name("perfect_timing_bell", -1.5, 1.0)
	if music_player != null:
		music_player.set_momentum_boost(0.22 if is_perfect else 0.12)


func _on_shot_timing_feedback(_player_id: int, label: String, _timing_error: float) -> void:
	if label.strip_edges().to_lower() == "perfect":
		play_sfx_by_name("perfect_timing_bell", -2.0, 1.05)


func _on_score_changed(team_id: int, _new_score: int, delta: int, is_three: bool, _scorer_id: int) -> void:
	if delta <= 0:
		return
	var rim_pos := Vector3(0.0, 3.05, -12.425) if team_id == 0 else Vector3(0.0, 3.05, 12.425)
	play_sfx_3d("net_swish", rim_pos, 1.0, -1.0)
	play_sfx_by_name("score_three_chime" if is_three else "score_chime", -2.0, 1.0)
	play_sfx_by_name("crowd_cheer", -3.5 if is_three else -6.0, 1.02 if is_three else 0.98)
	add_crowd_excitement(0.55 if is_three else 0.35)


func _on_dunk_impact(_player_id: int, rim_pos: Vector3, power: float) -> void:
	var is_meteor: bool = power >= 1.4
	play_sfx_3d("meteor_dunk_impact" if is_meteor else "dunk_impact", rim_pos, 1.0, 0.5 if is_meteor else -1.0)
	play_sfx_by_name("crowd_cheer", -2.5, 1.05 if is_meteor else 1.0)
	add_crowd_excitement(0.80 if is_meteor else 0.60)


func _on_ankle_broken(_victim_id: int, _attacker_id: int, world_pos: Vector3) -> void:
	play_sfx_3d("shoe_squeak", world_pos, 1.16, -1.5)
	play_sfx_by_name("crowd_gasp", -3.0, 1.0)
	add_crowd_excitement(0.50)


func _on_block_performed(_blocker_id: int, _shooter_id: int, world_pos: Vector3) -> void:
	play_sfx_3d("block_swat", world_pos, 1.0, -0.5)
	play_sfx_by_name("crowd_gasp", -3.0, 0.96)
	add_crowd_excitement(0.50)


func _on_steal_performed(_stealer_id: int, _victim_id: int, world_pos: Vector3) -> void:
	play_sfx_3d("steal_snap", world_pos, 1.05, -2.0)
	add_crowd_excitement(0.20)


func _on_zone_activated(player_id: int, _duration: float) -> void:
	_ensure_initialized()
	_active_zone_players[player_id] = true
	play_zone_activate_sfx()
	if _zone_hum_player != null and _zone_hum_player.stream != null and not _zone_hum_player.playing:
		_zone_hum_player.play()
	add_crowd_excitement(0.60)


func _on_zone_ended(player_id: int) -> void:
	_active_zone_players.erase(player_id)
	if _active_zone_players.is_empty() and _zone_hum_player != null and _zone_hum_player.playing:
		_zone_hum_player.stop()
	play_zone_end_sfx()


func _on_match_ended(_winner_team: int, _final_scores: Array, _stats: Dictionary) -> void:
	play_sfx_by_name("buzzer", -1.0, 1.0)
	play_sfx_by_name("crowd_cheer", -3.0, 1.0)
	add_crowd_excitement(0.80)


func _on_timer_updated(match_seconds_left: float, shot_clock_left: float) -> void:
	if music_player != null:
		music_player.set_clutch_mode(match_seconds_left > 0.0 and match_seconds_left <= 30.0)
	if shot_clock_left <= 0.01:
		if not _shot_clock_buzzer_fired:
			_shot_clock_buzzer_fired = true
			play_sfx_by_name("buzzer", -2.5, 1.08)
	else:
		_shot_clock_buzzer_fired = false


func _on_match_restarted() -> void:
	_active_zone_players.clear()
	_sprint_step_counters.clear()
	_shot_clock_buzzer_fired = false
	if _zone_hum_player != null and _zone_hum_player.playing:
		_zone_hum_player.stop()
	_crowd_excitement = 0.0
	_apply_ambience_mix()
	if music_player != null:
		music_player.reset_intensity()
