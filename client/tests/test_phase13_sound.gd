extends Node
## Phase 13 Automated Verification Suite — Sound & Dynamic Audio Suite
## (PHANTOM COURT ONLINE)
## Verifies:
## 1. ProceduralSfxSynth 24-sound 44.1 kHz 16-bit PCM WAV catalog (non-empty, RMS > 0.02,
##    peak > 0.20, LOOP_FORWARD on looping stems vs LOOP_DISABLED on one-shots, aliases, cache).
## 2. SoundManager AudioServer buses (Master/SFX/Music/Ambience), ConfigManager volume controls
##    (including 0.0 mute & clean restore), 2D + spatial 3D player pools, and crowd ambience.
## 3. All canonical EventBus gameplay audio triggers (ball bounces with speed-scaled pitch/vol,
##    rim clang, backboard thud, footsteps + sprint squeaks, dribble moves, escalating combo pitch
##    + perfect timing bell, 2pt/3pt scores, normal/meteor dunks, ankle breaks, blocks, steals,
##    multi-player Zone hum, debounced shot-clock & match buzzers, crowd excitement decay, restart).
## 4. DynamicMusicPlayer clutch final-30s mode & momentum boost + live physics court/hoop audio E2E.

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"


func run(runner: SceneTree) -> void:
	await _test_procedural_sfx_synth_catalog(runner)
	await _test_sound_manager_buses_volumes_and_pools(runner)
	await _test_event_bus_audio_routing_and_crowd_dynamics(runner)
	await _test_dynamic_music_clutch_and_live_physics_audio(runner)


# ==============================================================================
# 1. ProceduralSfxSynth — Complete 24-Sound 44.1 kHz 16-bit PCM Catalog
# ==============================================================================
func _test_procedural_sfx_synth_catalog(runner: SceneTree) -> void:
	await runner.clear_stage()

	var required_names: Array[String] = [
		"ball_bounce",
		"rim_clang",
		"backboard_thud",
		"footstep",
		"shoe_squeak",
		"crowd_ambiance",
		"crowd_cheer",
		"crowd_gasp",
		"net_swish",
		"score_chime",
		"score_three_chime",
		"buzzer",
		"dunk_impact",
		"meteor_dunk_impact",
		"dribble_whoosh",
		"combo_chime",
		"perfect_timing_bell",
		"block_swat",
		"steal_snap",
		"zone_activate",
		"zone_end",
		"zone_aura_hum",
		"base_music_loop",
		"zone_intense_music_layer",
	]
	var looping_names: Array[String] = [
		"crowd_ambiance",
		"zone_aura_hum",
		"base_music_loop",
		"zone_intense_music_layer",
	]

	var all_names: Array[String] = ProceduralSfxSynth.get_all_sfx_names()
	runner.assert_eq(all_names.size(), 24, "ProceduralSfxSynth registers all 24 canonical audio buffers")

	var all_non_silent: bool = true
	var all_format_valid: bool = true
	var all_loop_valid: bool = true
	var min_rms: float = 999.0
	var min_bytes: int = 999999999

	for sfx_name in required_names:
		runner.assert_true(all_names.has(sfx_name), "Catalog contains '%s'" % sfx_name)
		var wav: AudioStreamWAV = ProceduralSfxSynth.get_sfx_by_name(sfx_name)
		runner.assert_not_null(wav, "Synthesizes non-null AudioStreamWAV for '%s'" % sfx_name)
		if wav == null:
			all_non_silent = false
			all_format_valid = false
			all_loop_valid = false
			continue

		var bytes_len: int = wav.data.size()
		if bytes_len < min_bytes:
			min_bytes = bytes_len
		if wav.format != AudioStreamWAV.FORMAT_16_BITS or wav.mix_rate != 44100 or bytes_len < 4000 or (bytes_len % 2) != 0:
			all_format_valid = false
			runner.fail("Format check failed for '%s' (fmt=%d, rate=%d, bytes=%d)" % [sfx_name, wav.format, wav.mix_rate, bytes_len])

		var rms: float = ProceduralSfxSynth.compute_rms(wav)
		var peak: float = ProceduralSfxSynth.compute_peak(wav)
		if rms < min_rms:
			min_rms = rms
		if rms <= 0.02 or peak <= 0.20 or peak > 1.001:
			all_non_silent = false
			runner.fail("Amplitude check failed for '%s' (rms=%.4f, peak=%.4f)" % [sfx_name, rms, peak])

		var expect_loop: bool = looping_names.has(sfx_name)
		var expected_mode: int = AudioStreamWAV.LOOP_FORWARD if expect_loop else AudioStreamWAV.LOOP_DISABLED
		if wav.loop_mode != expected_mode:
			all_loop_valid = false
			runner.fail("Loop mode mismatch for '%s' (actual=%d, expected=%d)" % [sfx_name, wav.loop_mode, expected_mode])
		if expect_loop and wav.loop_end != (bytes_len >> 1):
			all_loop_valid = false
			runner.fail("Loop end mismatch for '%s' (loop_end=%d, samples=%d)" % [sfx_name, wav.loop_end, bytes_len >> 1])

	runner.assert_true(all_format_valid, "All 24 WAV buffers are valid 44.1 kHz 16-bit PCM (min_bytes=%d)" % min_bytes)
	runner.assert_true(all_non_silent, "All 24 WAV buffers are non-silent (min_rms=%.4f > 0.02)" % min_rms)
	runner.assert_true(all_loop_valid, "All 4 looping stems use LOOP_FORWARD and all 20 one-shots use LOOP_DISABLED")

	# Aliases, unknown fallback, and static cache determinism
	var alias_amb: AudioStreamWAV = ProceduralSfxSynth.get_sfx_by_name("crowd_ambience")
	var alias_base: AudioStreamWAV = ProceduralSfxSynth.get_sfx_by_name("base_music")
	var alias_zone: AudioStreamWAV = ProceduralSfxSynth.get_sfx_by_name("zone_music")
	var unknown_wav: AudioStreamWAV = ProceduralSfxSynth.get_sfx_by_name("nonexistent_sfx_xyz")
	runner.assert_not_null(alias_amb, "Alias 'crowd_ambience' resolves cleanly")
	runner.assert_not_null(alias_base, "Alias 'base_music' resolves cleanly")
	runner.assert_not_null(alias_zone, "Alias 'zone_music' resolves cleanly")
	runner.assert_true(unknown_wav == null, "Unknown SFX name returns null cleanly")

	var bounce_a: AudioStreamWAV = ProceduralSfxSynth.get_sfx_by_name("ball_bounce")
	var bounce_b: AudioStreamWAV = ProceduralSfxSynth.get_sfx_by_name("ball_bounce")
	runner.assert_eq(bounce_a.data.size(), bounce_b.data.size(), "Static PCM cache returns identical byte length on repeat lookup")
	runner.assert_eq(bounce_a.data.decode_s16(200), bounce_b.data.decode_s16(200), "Static PCM cache preserves identical sample data")


# ==============================================================================
# 2. SoundManager Buses, ConfigManager Volume Controls & 2D/3D Pooling
# ==============================================================================
func _test_sound_manager_buses_volumes_and_pools(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var sm := arena.get_node_or_null("SoundManager") as SoundManager
	if not runner.assert_not_null(sm, "Arena mounts SoundManager"):
		return

	runner.assert_true(sm.is_in_group("sound_manager"), "SoundManager joins 'sound_manager' group")
	runner.assert_eq(sm.get_all_loaded_sfx_names().size(), 24, "SoundManager loads all 24 canonical SFX streams")
	runner.assert_true(sm.is_ambience_playing(), "CrowdAmbiencePlayer auto-starts looping stadium ambience")
	runner.assert_false(sm.is_zone_hum_playing(), "ZoneAuraHumPlayer starts inactive before Zone")

	# Verify AudioServer buses & send routing
	var bus_names: PackedStringArray = sm.get_bus_names()
	for req_bus in ["Master", "SFX", "Music", "Ambience"]:
		var bidx: int = AudioServer.get_bus_index(req_bus)
		runner.assert_ge(float(bidx), 0.0, "AudioServer bus '%s' exists (idx=%d)" % [req_bus, bidx])
		runner.assert_true(bus_names.has(req_bus), "get_bus_names() includes '%s'" % req_bus)
		if req_bus != "Master" and bidx >= 0:
			runner.assert_eq(String(AudioServer.get_bus_send(bidx)), "Master", "Bus '%s' routes to 'Master'" % req_bus)

	# Save prior ConfigManager audio settings so we leave zero side-effects
	var prev_master: float = float(ConfigManager.get_setting("audio", "master_volume", 0.85))
	var prev_sfx: float = float(ConfigManager.get_setting("audio", "sfx_volume", 0.90))
	var prev_music: float = float(ConfigManager.get_setting("audio", "music_volume", 0.70))
	var had_amb: bool = ConfigManager.settings.has("audio") and (ConfigManager.settings["audio"] as Dictionary).has("ambience_volume")
	var prev_amb: float = float(ConfigManager.get_setting("audio", "ambience_volume", 0.65))

	# Direct bus volume linear setter/getter + 0.0 mute check
	sm.set_bus_volume_linear("SFX", 0.50)
	runner.assert_approx(sm.get_bus_volume_linear("SFX"), 0.50, 0.02, "set_bus_volume_linear('SFX', 0.50) applies exact linear volume")
	sm.set_bus_volume_linear("Music", 0.0)
	runner.assert_approx(sm.get_bus_volume_linear("Music"), 0.0, 0.001, "set_bus_volume_linear('Music', 0.0) mutes bus cleanly")
	runner.assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")), "Volume 0.0 sets AudioServer bus mute flag")
	sm.set_bus_volume_linear("Music", 0.75)
	runner.assert_false(AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")), "Positive volume unmutes AudioServer bus")
	runner.assert_approx(sm.get_bus_volume_linear("Music"), 0.75, 0.02, "Music bus volume restored to 0.75")

	# ConfigManager volume sync via apply_volume_settings()
	ConfigManager.set_setting("audio", "master_volume", 0.60, false)
	ConfigManager.set_setting("audio", "sfx_volume", 0.40, false)
	ConfigManager.set_setting("audio", "music_volume", 0.30, false)
	ConfigManager.set_setting("audio", "ambience_volume", 0.55, false)
	sm.apply_volume_settings()

	runner.assert_approx(sm.get_bus_volume_linear("Master"), 0.60, 0.02, "apply_volume_settings syncs Master from ConfigManager")
	runner.assert_approx(sm.get_bus_volume_linear("SFX"), 0.40, 0.02, "apply_volume_settings syncs SFX from ConfigManager")
	runner.assert_approx(sm.get_bus_volume_linear("Music"), 0.30, 0.02, "apply_volume_settings syncs Music from ConfigManager")
	runner.assert_approx(sm.get_bus_volume_linear("Ambience"), 0.55, 0.02, "apply_volume_settings syncs Ambience from ConfigManager")

	# Restore ConfigManager audio settings immediately
	ConfigManager.set_setting("audio", "master_volume", prev_master, false)
	ConfigManager.set_setting("audio", "sfx_volume", prev_sfx, false)
	ConfigManager.set_setting("audio", "music_volume", prev_music, false)
	if had_amb:
		ConfigManager.set_setting("audio", "ambience_volume", prev_amb, false)
	elif ConfigManager.settings.has("audio"):
		(ConfigManager.settings["audio"] as Dictionary).erase("ambience_volume")
	sm.apply_volume_settings()

	# 2D & Spatial 3D Pool Playback + Channel Wraparound
	sm.reset_stats()
	var p2d: AudioStreamPlayer = sm.play_sfx_by_name("score_chime", -3.0, 1.10)
	runner.assert_not_null(p2d, "play_sfx_by_name returns active 2D AudioStreamPlayer")
	if p2d != null:
		runner.assert_eq(String(p2d.bus), "SFX", "2D SFX player routes to 'SFX' bus")
		runner.assert_approx(p2d.pitch_scale, 1.10, 0.001, "2D SFX player applies pitch_scale")
	runner.assert_eq(sm.get_play_count("score_chime"), 1, "2D play increments play_count('score_chime')")
	runner.assert_eq(sm.get_last_played_sfx(), "score_chime", "get_last_played_sfx() tracks 'score_chime'")

	var target_3d := Vector3(3.5, 2.2, -9.0)
	var p3d: AudioStreamPlayer3D = sm.play_sfx_3d("rim_clang", target_3d, 1.05, -2.0)
	runner.assert_not_null(p3d, "play_sfx_3d returns active AudioStreamPlayer3D")
	if p3d != null:
		runner.assert_eq(String(p3d.bus), "SFX", "Spatial 3D SFX player routes to 'SFX' bus")
		runner.assert_approx(p3d.position.distance_to(target_3d), 0.0, 0.001, "Spatial 3D SFX player moves to exact world_pos")
		runner.assert_approx(p3d.pitch_scale, 1.05, 0.001, "Spatial 3D SFX player applies pitch_scale")
	runner.assert_approx(sm.get_last_3d_play_position().distance_to(target_3d), 0.0, 0.001, "get_last_3d_play_position() matches target_3d")

	# Rapid 14-call burst exceeds 10-channel 3D pool -> wraps cleanly with zero nulls
	var burst_ok: bool = true
	for i in range(14):
		var sp := sm.play_sfx_3d("footstep", Vector3(float(i) * 0.4, 0.0, 0.0), 1.0, -8.0)
		if sp == null:
			burst_ok = false
	runner.assert_true(burst_ok, "14 rapid play_sfx_3d calls wrap 10-channel spatial pool cleanly")
	runner.assert_eq(sm.get_play_count("footstep"), 14, "All 14 rapid 3D plays accounted for")
	runner.assert_eq(sm.get_total_plays(), 16, "get_total_plays() sums 2D + 3D plays accurately")

	sm.reset_stats()
	runner.assert_eq(sm.get_total_plays(), 0, "reset_stats() clears total plays")
	runner.assert_eq(sm.get_last_played_sfx(), "", "reset_stats() clears last played sfx")


# ==============================================================================
# 3. Canonical EventBus Routing & Crowd Excitement Dynamics
# ==============================================================================
func _test_event_bus_audio_routing_and_crowd_dynamics(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var sm := arena.get_node_or_null("SoundManager") as SoundManager
	if not runner.assert_not_null(sm, "EventBus test: SoundManager mounted"):
		return
	var mp: DynamicMusicPlayer = sm.get_music_player()
	var spatial_root: Node3D = sm.get_node_or_null("SpatialSfxPool") as Node3D
	var amb_player: AudioStreamPlayer = sm.get_node_or_null("CrowdAmbiencePlayer") as AudioStreamPlayer

	sm.reset_stats()
	mp.reset_intensity()

	# 3A. ball_bounced -> court (speed-scaled vol & pitch), rim, backboard
	var soft_pos := Vector3(-2.0, 0.12, 1.0)
	var hard_pos := Vector3(2.0, 0.12, -1.0)
	EventBus.ball_bounced.emit(soft_pos, 2.0, "court")
	var soft_ch: AudioStreamPlayer3D = _find_3d_channel_at(spatial_root, soft_pos)
	var soft_vol: float = soft_ch.volume_db if soft_ch != null else -99.0
	var soft_pitch: float = soft_ch.pitch_scale if soft_ch != null else 0.0

	EventBus.ball_bounced.emit(hard_pos, 11.5, "court")
	var hard_ch: AudioStreamPlayer3D = _find_3d_channel_at(spatial_root, hard_pos)
	var hard_vol: float = hard_ch.volume_db if hard_ch != null else -99.0
	var hard_pitch: float = hard_ch.pitch_scale if hard_ch != null else 0.0

	runner.assert_eq(sm.get_play_count("ball_bounce"), 2, "ball_bounced('court') triggers ball_bounce SFX")
	runner.assert_gt(hard_vol, soft_vol + 4.0, "High-speed court bounce is louder than soft bounce (%.1fdB > %.1fdB)" % [hard_vol, soft_vol])
	runner.assert_gt(hard_pitch, soft_pitch + 0.10, "High-speed court bounce pitches higher than soft bounce (%.2f > %.2f)" % [hard_pitch, soft_pitch])

	var rim_pos := Vector3(0.0, 3.05, 12.425)
	EventBus.ball_bounced.emit(rim_pos, 7.5, "rim")
	runner.assert_eq(sm.get_play_count("rim_clang"), 1, "ball_bounced('rim') triggers rim_clang 3D SFX")
	runner.assert_approx(sm.get_last_3d_play_position().distance_to(rim_pos), 0.0, 0.001, "rim_clang positioned at rim_pos")

	var bb_pos := Vector3(0.0, 3.45, 12.80)
	EventBus.ball_bounced.emit(bb_pos, 8.0, "backboard")
	runner.assert_eq(sm.get_play_count("backboard_thud"), 1, "ball_bounced('backboard') triggers backboard_thud 3D SFX")
	runner.assert_approx(sm.get_last_3d_play_position().distance_to(bb_pos), 0.0, 0.001, "backboard_thud positioned at backboard")

	# 3B. player_footstep -> walk (footstep only) vs sprint (footstep + cadence shoe_squeak)
	EventBus.player_footstep.emit(1, Vector3(0.5, 0.0, 0.5), false)
	runner.assert_eq(sm.get_play_count("footstep"), 1, "Walk player_footstep plays footstep")
	runner.assert_eq(sm.get_play_count("shoe_squeak"), 0, "Walk player_footstep does not play shoe_squeak")

	for s in range(4):
		EventBus.player_footstep.emit(1, Vector3(1.0 + float(s) * 0.5, 0.0, 0.0), true)
	runner.assert_eq(sm.get_play_count("footstep"), 5, "4 sprint footsteps increment footstep count to 5")
	runner.assert_eq(sm.get_play_count("shoe_squeak"), 2, "Sprint cadence (steps 1 & 4) triggers 2 shoe_squeak plays")

	# 3C. dribble_move_performed -> dribble_whoosh + shoe_squeak
	var sq_before_drib: int = sm.get_play_count("shoe_squeak")
	EventBus.dribble_move_performed.emit(1, "crossover", Vector3(-1.5, 0.0, -3.0))
	runner.assert_eq(sm.get_play_count("dribble_whoosh"), 1, "dribble_move_performed triggers dribble_whoosh")
	runner.assert_eq(sm.get_play_count("shoe_squeak"), sq_before_drib + 1, "dribble_move_performed also triggers shoe_squeak")

	# 3D. combo_triggered -> escalating pitch + perfect_timing_bell on perfect only
	EventBus.combo_triggered.emit(1, "phantom_drive", 1, false)
	var pitch_t1: float = sm.get_last_combo_pitch()
	runner.assert_eq(sm.get_play_count("combo_chime"), 1, "Tier-1 combo plays combo_chime")
	runner.assert_approx(pitch_t1, 1.00, 0.005, "Tier-1 combo_chime pitch == 1.00")
	runner.assert_eq(sm.get_play_count("perfect_timing_bell"), 0, "Non-perfect combo skips perfect_timing_bell")

	EventBus.combo_triggered.emit(1, "ankle_breaker", 3, true)
	var pitch_t3: float = sm.get_last_combo_pitch()
	runner.assert_eq(sm.get_play_count("combo_chime"), 2, "Tier-3 combo plays combo_chime")
	runner.assert_approx(pitch_t3, 1.24, 0.005, "Tier-3 combo_chime pitch escalates to 1.24 (+0.12/tier)")
	runner.assert_gt(pitch_t3, pitch_t1, "Higher combo tier raises chime pitch")
	runner.assert_eq(sm.get_play_count("perfect_timing_bell"), 1, "Perfect combo plays sparkling perfect_timing_bell")
	runner.assert_gt(mp.get_target_intensity(), 0.15, "Perfect combo grants DynamicMusicPlayer momentum boost")

	# 3E. shot_timing_feedback -> Perfect bell only
	EventBus.shot_timing_feedback.emit(1, "Early", -0.14)
	runner.assert_eq(sm.get_play_count("perfect_timing_bell"), 1, "Non-Perfect shot feedback skips perfect_timing_bell")
	EventBus.shot_timing_feedback.emit(1, "Perfect", 0.005)
	runner.assert_eq(sm.get_play_count("perfect_timing_bell"), 2, "Perfect shot feedback triggers perfect_timing_bell")

	# 3F. score_changed -> delta==0 ignored; 2pt vs 3pt routing + 3D net_swish + crowd excitement
	EventBus.score_changed.emit(0, 0, 0, false, -1)
	runner.assert_eq(sm.get_play_count("net_swish"), 0, "score_changed with delta==0 (reset) triggers no score SFX")

	EventBus.score_changed.emit(0, 2, 2, false, 1)
	runner.assert_eq(sm.get_play_count("net_swish"), 1, "2pt score triggers net_swish")
	runner.assert_eq(sm.get_play_count("score_chime"), 1, "2pt score triggers score_chime")
	runner.assert_eq(sm.get_play_count("score_three_chime"), 0, "2pt score does not trigger score_three_chime")
	runner.assert_eq(sm.get_play_count("crowd_cheer"), 1, "2pt score triggers crowd_cheer")
	runner.assert_approx(sm.get_last_3d_play_position().distance_to(Vector3(0.0, 3.05, -12.425)), 0.0, 0.01, "Team 0 net_swish positioned at HoopB (-12.425)")
	var excite_after_2pt: float = sm.get_crowd_excitement()
	runner.assert_ge(excite_after_2pt, 0.30, "2pt score raises crowd excitement (actual=%.2f)" % excite_after_2pt)

	EventBus.score_changed.emit(1, 3, 3, true, 2)
	runner.assert_eq(sm.get_play_count("net_swish"), 2, "3pt score triggers net_swish")
	runner.assert_eq(sm.get_play_count("score_three_chime"), 1, "3pt score triggers score_three_chime arpeggio")
	runner.assert_eq(sm.get_play_count("crowd_cheer"), 2, "3pt score triggers crowd_cheer")
	runner.assert_approx(sm.get_last_3d_play_position().distance_to(Vector3(0.0, 3.05, 12.425)), 0.0, 0.01, "Team 1 net_swish positioned at HoopA (+12.425)")

	# 3G. dunk_impact -> normal vs meteor dunk (>= 1.4)
	var dunk_rim := Vector3(0.0, 3.05, -12.425)
	EventBus.dunk_impact.emit(1, dunk_rim, 1.0)
	runner.assert_eq(sm.get_play_count("dunk_impact"), 1, "Standard dunk (power=1.0) plays dunk_impact")
	runner.assert_eq(sm.get_play_count("meteor_dunk_impact"), 0, "Standard dunk does not play meteor_dunk_impact")
	runner.assert_eq(sm.get_play_count("crowd_cheer"), 3, "Standard dunk triggers crowd_cheer")

	EventBus.dunk_impact.emit(1, dunk_rim, 1.75)
	runner.assert_eq(sm.get_play_count("meteor_dunk_impact"), 1, "Monster dunk (power=1.75 >= 1.4) plays meteor_dunk_impact")
	runner.assert_eq(sm.get_play_count("crowd_cheer"), 4, "Meteor dunk triggers crowd_cheer")

	# 3H. ankle_broken, block_performed, steal_performed
	var sq_before_ank: int = sm.get_play_count("shoe_squeak")
	EventBus.ankle_broken.emit(2, 1, Vector3(1.2, 0.0, -4.0))
	runner.assert_eq(sm.get_play_count("shoe_squeak"), sq_before_ank + 1, "ankle_broken plays dramatic shoe_squeak")
	runner.assert_eq(sm.get_play_count("crowd_gasp"), 1, "ankle_broken triggers crowd_gasp")

	EventBus.block_performed.emit(2, 1, Vector3(0.2, 2.8, -10.5))
	runner.assert_eq(sm.get_play_count("block_swat"), 1, "block_performed plays block_swat 3D SFX")
	runner.assert_eq(sm.get_play_count("crowd_gasp"), 2, "block_performed triggers crowd_gasp")

	EventBus.steal_performed.emit(2, 1, Vector3(-0.8, 0.9, -2.0))
	runner.assert_eq(sm.get_play_count("steal_snap"), 1, "steal_performed plays steal_snap 3D SFX")

	# 3I. Zone multi-player aura hum refcounting + DynamicMusicPlayer intensity
	EventBus.zone_activated.emit(1, 12.0)
	runner.assert_eq(sm.get_play_count("zone_activate"), 1, "zone_activated plays zone_activate SFX")
	runner.assert_true(sm.is_zone_hum_playing(), "zone_activated starts looping zone_aura_hum")
	EventBus.zone_activated.emit(2, 12.0)
	EventBus.zone_ended.emit(1)
	runner.assert_eq(sm.get_play_count("zone_end"), 1, "zone_ended plays zone_end SFX")
	runner.assert_true(sm.is_zone_hum_playing(), "zone_aura_hum keeps playing while 2nd player remains in Zone")
	EventBus.zone_ended.emit(2)
	runner.assert_false(sm.is_zone_hum_playing(), "zone_aura_hum stops cleanly once last Zone player expires")

	# 3J. timer_updated -> clutch mode & debounced shot-clock buzzer; match_ended -> buzzer + cheer
	EventBus.timer_updated.emit(45.0, 12.0)
	runner.assert_false(mp.is_clutch_mode(), "Clutch mode inactive at 45s remaining")
	EventBus.timer_updated.emit(28.0, 10.0)
	runner.assert_true(mp.is_clutch_mode(), "Clutch mode activates automatically <= 30s remaining")
	runner.assert_eq(sm.get_play_count("buzzer"), 0, "No buzzer while shot clock > 0")

	EventBus.timer_updated.emit(25.0, 0.0)
	EventBus.timer_updated.emit(24.9, 0.0)
	EventBus.timer_updated.emit(24.8, 0.0)
	runner.assert_eq(sm.get_play_count("buzzer"), 1, "Shot-clock 0.0 buzzer is debounced (fires exactly once)")

	EventBus.timer_updated.emit(24.0, 24.0)
	EventBus.timer_updated.emit(18.0, 0.0)
	runner.assert_eq(sm.get_play_count("buzzer"), 2, "Shot-clock buzzer re-arms cleanly after shot clock resets")

	EventBus.match_ended.emit(0, [10, 6], {})
	runner.assert_eq(sm.get_play_count("buzzer"), 3, "match_ended fires arena buzzer")
	runner.assert_eq(sm.get_play_count("crowd_cheer"), 5, "match_ended triggers victory crowd_cheer")

	# 3K. Crowd ambience excitement swell & decay + match_restarted clean reset
	var excited_db: float = amb_player.volume_db if amb_player != null else -99.0
	runner.assert_gt(sm.get_crowd_excitement(), 0.70, "Crowd excitement high after big plays (actual=%.2f)" % sm.get_crowd_excitement())
	runner.assert_gt(excited_db, SoundManager.AMBIENCE_BASE_DB + 5.0, "Crowd ambience swells louder when excited (%.1fdB > %.1fdB)" % [excited_db, SoundManager.AMBIENCE_BASE_DB])

	for _i in range(45):
		sm.step_audio(0.1)
	runner.assert_approx(sm.get_crowd_excitement(), 0.0, 0.001, "Crowd excitement decays smoothly back to 0.0")
	if amb_player != null:
		runner.assert_approx(amb_player.volume_db, SoundManager.AMBIENCE_BASE_DB, 0.05, "Crowd ambience volume returns cleanly to AMBIENCE_BASE_DB")

	EventBus.zone_activated.emit(1, 12.0)
	EventBus.match_restarted.emit()
	runner.assert_false(sm.is_zone_hum_playing(), "match_restarted stops active zone_aura_hum")
	runner.assert_false(mp.is_clutch_mode(), "match_restarted clears DynamicMusicPlayer clutch mode")
	runner.assert_approx(mp.get_intensity(), 0.0, 0.001, "match_restarted resets DynamicMusicPlayer intensity to 0.0")


# ==============================================================================
# 4. DynamicMusicPlayer Clutch / Momentum & Live Physics Court/Hoop E2E Audio
# ==============================================================================
func _test_dynamic_music_clutch_and_live_physics_audio(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var sm := arena.get_node_or_null("SoundManager") as SoundManager
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var mc := arena.get_node_or_null("MatchController") as Node
	if not runner.assert_not_null(sm, "Live E2E: SoundManager present"):
		return
	if not runner.assert_not_null(ball, "Live E2E: Basketball present"):
		return

	var mp: DynamicMusicPlayer = sm.get_music_player()
	mp.reset_intensity()

	# 4A. DynamicMusicPlayer clutch floor & tempo lift
	var base_pitch_normal: float = mp.get_base_player().pitch_scale
	mp.set_clutch_mode(true)
	runner.assert_true(mp.is_clutch_mode(), "DynamicMusicPlayer.set_clutch_mode(true) enables clutch state")
	runner.assert_approx(mp.get_target_intensity(), DynamicMusicPlayer.CLUTCH_FLOOR_INTENSITY, 0.005, "Clutch mode sets target floor == 0.42")
	for _i in range(25):
		mp.step_music(0.05)
	runner.assert_approx(mp.get_intensity(), DynamicMusicPlayer.CLUTCH_FLOOR_INTENSITY, 0.02, "Clutch music intensity ramps smoothly to 0.42")
	runner.assert_gt(mp.get_base_player().pitch_scale, base_pitch_normal + 0.01, "Clutch mode adds subtle tempo lift to base stem")

	# Momentum boost stacks on clutch floor & decays back down
	mp.set_momentum_boost(0.25)
	runner.assert_approx(mp.get_target_intensity(), 0.67, 0.02, "Momentum boost (+0.25) stacks on clutch floor (0.42 -> 0.67)")
	mp.set_clutch_mode(false)
	for _i in range(40):
		mp.step_music(0.05)
	runner.assert_approx(mp.get_intensity(), 0.0, 0.01, "Disabling clutch + decaying momentum returns intensity cleanly to 0.0")

	# 4B. Live Physics Basketball Drop -> Real court bounce triggers ball_bounce SFX
	if mc != null:
		mc.call("restart_match")
	await runner.wait_physics_frames(2)
	sm.reset_stats()

	ball.call("reset_to_free", Vector3(2.5, 2.2, 2.0))
	await runner.wait_physics_frames(45)
	runner.assert_ge(float(sm.get_play_count("ball_bounce")), 1.0, "LIVE PHYSICS: Dropping Basketball onto court fires real ball_bounce SFX (count=%d)" % sm.get_play_count("ball_bounce"))

	# 4C. Live Physics HoopA Drop-Through -> Real basket triggers net_swish + score_chime + crowd_cheer
	sm.reset_stats()
	ball.call("reset_to_free", Vector3(0.0, 3.85, 12.425))
	await runner.wait_physics_frames(65)
	runner.assert_ge(float(sm.get_play_count("net_swish")), 1.0, "LIVE PHYSICS: Ball dropping through HoopA triggers real net_swish SFX")
	var score_chimes: int = sm.get_play_count("score_chime") + sm.get_play_count("score_three_chime")
	runner.assert_ge(float(score_chimes), 1.0, "LIVE PHYSICS: Ball dropping through HoopA triggers real score chime SFX")
	runner.assert_ge(float(sm.get_play_count("crowd_cheer")), 1.0, "LIVE PHYSICS: Ball dropping through HoopA triggers real crowd_cheer SFX")


func _find_3d_channel_at(spatial_root: Node3D, pos: Vector3) -> AudioStreamPlayer3D:
	if spatial_root == null:
		return null
	for child in spatial_root.get_children():
		if child is AudioStreamPlayer3D:
			var sp3 := child as AudioStreamPlayer3D
			if sp3.position.distance_to(pos) < 0.05:
				return sp3
	return null
