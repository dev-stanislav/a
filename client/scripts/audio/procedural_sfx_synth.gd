class_name ProceduralSfxSynth
extends RefCounted
## Pure GDScript 44.1 kHz 16-bit PCM AudioStreamWAV Procedural Synthesizer (Phases 5 + 13).
## Synthesizes and caches 24 non-silent original basketball court SFX, stadium crowd layers,
## Zone Awakening audio, and beat-synchronized Dynamic Music loops.

const SAMPLE_RATE: int = 44100
const MUSIC_BPM: float = 120.0
const MUSIC_BARS: int = 2
const MUSIC_LOOP_SECONDS: float = 4.0 # 2 bars at 120 BPM = 8 beats = 4.0s exact

const ALL_SFX_NAMES: Array[String] = [
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

static var _pcm_cache: Dictionary = {} # key: String -> {bytes: PackedByteArray, samples: int, loop: bool}


# ==============================================================================
# Unified Catalog & Lookup API (Phase 13)
# ==============================================================================

static func get_all_sfx_names() -> Array[String]:
	var out: Array[String] = []
	for s in ALL_SFX_NAMES:
		out.append(s)
	return out


static func get_sfx_by_name(sfx_name: String) -> AudioStreamWAV:
	match sfx_name.strip_edges().to_lower():
		"ball_bounce":
			return generate_ball_bounce_sfx()
		"rim_clang":
			return generate_rim_clang_sfx()
		"backboard_thud":
			return generate_backboard_thud_sfx()
		"footstep":
			return generate_footstep_sfx()
		"shoe_squeak":
			return generate_shoe_squeak_sfx()
		"crowd_ambiance", "crowd_ambience":
			return generate_crowd_ambiance_loop()
		"crowd_cheer":
			return generate_crowd_cheer_sfx()
		"crowd_gasp":
			return generate_crowd_gasp_sfx()
		"net_swish":
			return generate_net_swish_sfx()
		"score_chime":
			return generate_score_chime_sfx()
		"score_three_chime":
			return generate_score_three_chime_sfx()
		"buzzer":
			return generate_buzzer_sfx()
		"dunk_impact":
			return generate_dunk_impact_sfx()
		"meteor_dunk_impact":
			return generate_meteor_dunk_impact_sfx()
		"dribble_whoosh":
			return generate_dribble_whoosh_sfx()
		"combo_chime":
			return generate_combo_chime_sfx()
		"perfect_timing_bell":
			return generate_perfect_timing_bell_sfx()
		"block_swat":
			return generate_block_swat_sfx()
		"steal_snap":
			return generate_steal_snap_sfx()
		"zone_activate":
			return generate_zone_activate_sfx()
		"zone_end":
			return generate_zone_end_sfx()
		"zone_aura_hum":
			return generate_zone_aura_hum_loop()
		"base_music", "base_music_loop":
			return generate_base_music_loop()
		"zone_music", "zone_intense_music_layer":
			return generate_zone_intense_music_layer()
		_:
			return null


# ==============================================================================
# Basketball Court, Impact & Reaction SFX Generators (Phase 13)
# ==============================================================================

static func generate_ball_bounce_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("ball_bounce"):
		return _build_stream_from_cache("ball_bounce")

	var duration: float = 0.22
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var p_fund: float = 0.0
	var p_cav: float = 0.0
	var p_ping: float = 0.0
	var rng: int = 104729

	for i in range(count):
		var t: float = float(i) * dt
		# Taut inflated leather bounce: pitch-dropping fundamental (~115 Hz) + hollow air cavity (~242 Hz) + slap
		var f_fund: float = 96.0 + 38.0 * exp(-t * 36.0)
		var f_cav: float = 238.0 + 30.0 * exp(-t * 28.0)
		p_fund += TAU * f_fund * dt
		p_cav += TAU * f_cav * dt
		p_ping += TAU * 378.0 * dt

		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		var att: float = minf(t / 0.0025, 1.0)
		var thump: float = sin(p_fund) * exp(-t * 17.0) * 0.72
		var hollow: float = (sin(p_cav) * 0.42 + sin(p_ping) * 0.18) * exp(-t * 22.0)
		var slap: float = white * exp(-t * 110.0) * 0.48
		var s: float = (thump + hollow + slap) * att
		if i > count - 441:
			s *= float(count - i) / 441.0
		samples[i] = s

	_normalize_samples(samples, 0.86)
	return _cache_and_build("ball_bounce", samples, false)


static func generate_rim_clang_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("rim_clang"):
		return _build_stream_from_cache("rim_clang")

	var duration: float = 0.40
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 339911

	for i in range(count):
		var t: float = float(i) * dt
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		# Metallic steel rim inharmonic partial modes: 410 Hz + 780 Hz + 1290 Hz + 1945 Hz
		var m1: float = sin(TAU * 410.0 * t) * exp(-t * 8.5) * 0.52
		var m2: float = sin(TAU * 780.0 * t + 0.4) * exp(-t * 11.5) * 0.40
		var m3: float = sin(TAU * 1290.0 * t + 1.1) * exp(-t * 15.0) * 0.30
		var m4: float = sin(TAU * 1945.0 * t) * exp(-t * 22.0) * 0.18
		var strike: float = white * exp(-t * 95.0) * 0.38
		var rattle: float = sin(TAU * 92.0 * t) * exp(-t * 18.0) * 0.25

		var s: float = (m1 + m2 + m3 + m4 + strike + rattle) * minf(t / 0.0015, 1.0)
		if i > count - 661:
			s *= float(count - i) / 661.0
		samples[i] = s

	_normalize_samples(samples, 0.84)
	return _cache_and_build("rim_clang", samples, false)


static func generate_backboard_thud_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("backboard_thud"):
		return _build_stream_from_cache("backboard_thud")

	var duration: float = 0.26
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 515253
	var lp: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0
		lp = lp * 0.78 + white * 0.22

		# Tempered glass / acrylic backboard boom (~95 Hz) + damped structural ping (~590 Hz)
		var boom: float = (sin(TAU * 95.0 * t) * 0.72 + sin(TAU * 152.0 * t) * 0.32) * exp(-t * 16.0)
		var glass_ping: float = (sin(TAU * 590.0 * t) * 0.24 + sin(TAU * 1140.0 * t) * 0.12) * exp(-t * 32.0)
		var thump_noise: float = lp * exp(-t * 55.0) * 0.45

		var s: float = (boom + glass_ping + thump_noise) * minf(t / 0.002, 1.0)
		if i > count - 441:
			s *= float(count - i) / 441.0
		samples[i] = s

	_normalize_samples(samples, 0.84)
	return _cache_and_build("backboard_thud", samples, false)


static func generate_footstep_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("footstep"):
		return _build_stream_from_cache("footstep")

	var duration: float = 0.10
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 771123
	var lp: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0
		lp = lp * 0.65 + white * 0.35

		var heel: float = sin(TAU * 138.0 * t) * exp(-t * 34.0) * 0.62
		var wood_knock: float = sin(TAU * 365.0 * t) * exp(-t * 48.0) * 0.28
		var scuff: float = lp * exp(-t * 45.0) * 0.50
		var s: float = (heel + wood_knock + scuff) * minf(t / 0.002, 1.0)
		if i > count - 300:
			s *= float(count - i) / 300.0
		samples[i] = s

	_normalize_samples(samples, 0.78)
	return _cache_and_build("footstep", samples, false)


static func generate_shoe_squeak_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("shoe_squeak"):
		return _build_stream_from_cache("shoe_squeak")

	var duration: float = 0.20
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var phase: float = 0.0
	var mod_phase: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		var u: float = t / duration
		# Classic high-pitched rubber court squeak FM chirp sweeping 2.4 -> 3.9 -> 2.8 kHz
		var carrier_f: float = 2450.0 + 1450.0 * sin(u * PI * 0.92) + 220.0 * sin(u * TAU * 2.5)
		phase += TAU * carrier_f * dt
		mod_phase += TAU * 72.0 * dt

		var stick_slip: float = 0.70 + 0.30 * sin(mod_phase)
		var env: float = smoothstep_f(0.0, 0.14, u) * (1.0 - smoothstep_f(0.68, 1.0, u))
		var chirp: float = (sin(phase + 0.45 * sin(mod_phase)) * 0.75 + sin(phase * 2.0) * 0.25)
		samples[i] = chirp * stick_slip * env

	_normalize_samples(samples, 0.76)
	return _cache_and_build("shoe_squeak", samples, false)


static func generate_crowd_ambiance_loop() -> AudioStreamWAV:
	if _pcm_cache.has("crowd_ambiance"):
		return _build_stream_from_cache("crowd_ambiance")

	var duration: float = 2.0
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 884422
	# 3-stage pink-ish low-pass state for warm stadium chatter murmur
	var b0: float = 0.0
	var b1: float = 0.0
	var b2: float = 0.0
	var prev_lp: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		b0 = 0.996 * b0 + white * 0.055
		b1 = 0.980 * b1 + white * 0.085
		b2 = 0.920 * b2 + white * 0.110
		var pink: float = b0 + b1 + b2
		# Gentle band-shaping for natural gymnasium vocal crowd warmth
		var murmur: float = pink - prev_lp * 0.45
		prev_lp = pink

		# Seamless periodic stadium rumble & gentle crowd wave (integer cycles over 2.0s)
		var swell: float = 0.84 + 0.16 * sin(TAU * 0.5 * t) * cos(TAU * 1.0 * t + 0.5)
		var rumble: float = (sin(TAU * 68.0 * t) * 0.10 + sin(TAU * 102.0 * t) * 0.07)
		samples[i] = murmur * swell + rumble

	# Cross-fade loop boundary (last 2048 samples blended smoothly into first 2048)
	var xfade: int = 2048
	for j in range(xfade):
		var alpha: float = float(j) / float(xfade)
		samples[j] = samples[j] * alpha + samples[count - xfade + j] * (1.0 - alpha)

	_normalize_samples(samples, 0.55)
	return _cache_and_build("crowd_ambiance", samples, true)


static func generate_crowd_cheer_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("crowd_cheer"):
		return _build_stream_from_cache("crowd_cheer")

	var duration: float = 0.90
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 993311
	var b0: float = 0.0
	var b1: float = 0.0
	var b2: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		var u: float = t / duration
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		b0 = 0.992 * b0 + white * 0.08
		b1 = 0.945 * b1 + white * 0.14
		b2 = 0.800 * b2 + white * 0.20
		var roar_noise: float = b0 + b1 + b2

		var env: float = smoothstep_f(0.0, 0.16, u) * (1.0 - smoothstep_f(0.45, 1.0, u))
		var cheer_harm: float = (
			sin(TAU * (410.0 + 95.0 * u) * t) * 0.16
			+ sin(TAU * (615.0 + 130.0 * u) * t) * 0.12
		) * (0.6 + 0.4 * white)
		samples[i] = (roar_noise * 0.88 + cheer_harm) * env

	_normalize_samples(samples, 0.84)
	return _cache_and_build("crowd_cheer", samples, false)


static func generate_crowd_gasp_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("crowd_gasp"):
		return _build_stream_from_cache("crowd_gasp")

	var duration: float = 0.50
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 414243
	var lp: float = 0.0
	var hp_prev: float = 0.0
	var voice_p: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		var u: float = t / duration
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		lp = lp * 0.86 + white * 0.14
		var breath: float = lp - hp_prev * 0.65
		hp_prev = lp

		# Sharp crowd "OHHH!" rising-then-falling vocal formant swell
		var formant_f: float = 440.0 + 380.0 * sin(u * PI)
		voice_p += TAU * formant_f * dt
		var env: float = smoothstep_f(0.0, 0.12, u) * exp(-maxf(0.0, u - 0.12) * 3.8)
		var vocal: float = sin(voice_p) * (0.35 + 0.65 * absf(breath))
		samples[i] = (breath * 0.95 + vocal * 0.45) * env

	_normalize_samples(samples, 0.82)
	return _cache_and_build("crowd_gasp", samples, false)


static func generate_net_swish_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("net_swish"):
		return _build_stream_from_cache("net_swish")

	var duration: float = 0.30
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 626364
	# Crisp 2-pole state-variable bandpass filter sweeping across nylon frequencies
	var bp_low: float = 0.0
	var bp_band: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		var u: float = t / duration
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		var center_f: float = 1800.0 + 1850.0 * sin(u * PI)
		var f_coeff: float = clampf(2.0 * sin(PI * center_f * dt), 0.05, 0.85)
		var q_damp: float = 0.52
		var high: float = white - bp_low - q_damp * bp_band
		bp_band += f_coeff * high
		bp_low += f_coeff * bp_band

		# Two-stage nylon whip envelope (entry + tail snap)
		var env1: float = smoothstep_f(0.0, 0.14, u) * exp(-maxf(0.0, u - 0.12) * 5.2)
		var env2: float = smoothstep_f(0.28, 0.42, u) * exp(-maxf(0.0, u - 0.42) * 8.0) * 0.72
		samples[i] = bp_band * (env1 + env2)

	_normalize_samples(samples, 0.82)
	return _cache_and_build("net_swish", samples, false)


static func generate_score_chime_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("score_chime"):
		return _build_stream_from_cache("score_chime")

	var duration: float = 0.44
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	for i in range(count):
		var t: float = float(i) * dt
		# Upbeat 2-note broadcast stinger: E5 (659.25 Hz) -> B5 (987.77 Hz)
		var n1_env: float = minf(t / 0.005, 1.0) * exp(-t * 9.0)
		var n1: float = (sin(TAU * 659.25 * t) * 0.7 + sin(TAU * 1318.5 * t) * 0.3) * n1_env

		var n2: float = 0.0
		if t >= 0.09:
			var t2: float = t - 0.09
			var n2_env: float = minf(t2 / 0.005, 1.0) * exp(-t2 * 7.5)
			n2 = (sin(TAU * 987.77 * t2) * 0.65 + sin(TAU * 1975.5 * t2) * 0.25 + sin(TAU * 1479.98 * t2) * 0.20) * n2_env

		var s: float = n1 * 0.65 + n2 * 0.85
		if i > count - 661:
			s *= float(count - i) / 661.0
		samples[i] = s

	_normalize_samples(samples, 0.82)
	return _cache_and_build("score_chime", samples, false)


static func generate_score_three_chime_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("score_three_chime"):
		return _build_stream_from_cache("score_three_chime")

	var duration: float = 0.66
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var freqs: PackedFloat32Array = PackedFloat32Array([523.25, 659.25, 783.99, 1046.50, 1318.51])
	var starts: PackedFloat32Array = PackedFloat32Array([0.0, 0.065, 0.13, 0.195, 0.26])

	for i in range(count):
		var t: float = float(i) * dt
		var acc: float = 0.0
		for n in range(5):
			var st: float = starts[n]
			if t >= st:
				var nt: float = t - st
				var f: float = freqs[n]
				var env: float = minf(nt / 0.004, 1.0) * exp(-nt * 7.2)
				acc += (sin(TAU * f * nt) * 0.68 + sin(TAU * f * 2.0 * nt) * 0.24 + sin(TAU * f * 3.0 * nt) * 0.08) * env
		if i > count - 882:
			acc *= float(count - i) / 882.0
		samples[i] = acc

	_normalize_samples(samples, 0.85)
	return _cache_and_build("score_three_chime", samples, false)


static func generate_buzzer_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("buzzer"):
		return _build_stream_from_cache("buzzer")

	var duration: float = 0.80
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	for i in range(count):
		var t: float = float(i) * dt
		var u: float = t / duration
		# Authentic dual-reed basketball arena buzzer horn (148 Hz + 151.5 Hz beating harmonics)
		var f1: float = 148.0
		var f2: float = 151.5
		var horn: float = (
			sin(TAU * f1 * t) * 0.45
			+ sin(TAU * f2 * t) * 0.40
			+ sin(TAU * f1 * 2.0 * t) * 0.35
			+ sin(TAU * f1 * 3.0 * t) * 0.28
			+ sin(TAU * f2 * 4.0 * t) * 0.22
			+ sin(TAU * f1 * 5.0 * t) * 0.15
		)
		var env: float = minf(t / 0.012, 1.0) * (1.0 - smoothstep_f(0.86, 1.0, u))
		samples[i] = tanh(horn * 1.75) * env

	_normalize_samples(samples, 0.86)
	return _cache_and_build("buzzer", samples, false)


static func generate_dunk_impact_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("dunk_impact"):
		return _build_stream_from_cache("dunk_impact")

	var duration: float = 0.58
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var sub_p: float = 0.0
	var rng: int = 246810

	for i in range(count):
		var t: float = float(i) * dt
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		# Thunderous sub-bass slam (135 Hz -> 52 Hz) + steel rim rattle
		var f_sub: float = 52.0 + 83.0 * exp(-t * 14.0)
		sub_p += TAU * f_sub * dt
		var sub: float = tanh(sin(sub_p) * 1.9) * exp(-t * 5.8) * 0.78
		var rim_ring: float = (
			sin(TAU * 425.0 * t) * 0.30
			+ sin(TAU * 815.0 * t) * 0.22
			+ sin(TAU * 1340.0 * t) * 0.14
		) * exp(-t * 9.5)
		var slam_crack: float = white * exp(-t * 42.0) * 0.45

		var s: float = (sub + rim_ring + slam_crack) * minf(t / 0.003, 1.0)
		if i > count - 882:
			s *= float(count - i) / 882.0
		samples[i] = s

	_normalize_samples(samples, 0.90)
	return _cache_and_build("dunk_impact", samples, false)


static func generate_meteor_dunk_impact_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("meteor_dunk_impact"):
		return _build_stream_from_cache("meteor_dunk_impact")

	var duration: float = 0.88
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var sub_p: float = 0.0
	var shimmer_p: float = 0.0
	var rng: int = 999111

	for i in range(count):
		var t: float = float(i) * dt
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		# Earth-shaking anime super-dunk shockwave (170 Hz -> 36 Hz) + metallic chain rattle + sonic boom
		var f_sub: float = 36.0 + 134.0 * exp(-t * 9.5)
		sub_p += TAU * f_sub * dt
		var sub: float = tanh((sin(sub_p) + sin(sub_p * 2.0) * 0.35) * 2.1) * exp(-t * 3.6) * 0.85

		var f_sh: float = 280.0 + 620.0 * exp(-t * 4.5)
		shimmer_p += TAU * f_sh * dt
		var boom_shimmer: float = sin(shimmer_p + 1.1 * sin(TAU * 28.0 * t)) * exp(-t * 4.8) * 0.32

		var rim_chain: float = (
			sin(TAU * 412.0 * t) * 0.28
			+ sin(TAU * 792.0 * t) * 0.24
			+ sin(TAU * 1310.0 * t) * 0.18
			+ white * 0.35
		) * exp(-t * 11.5)

		var s: float = (sub + boom_shimmer + rim_chain) * minf(t / 0.0025, 1.0)
		if i > count - 1100:
			s *= float(count - i) / 1100.0
		samples[i] = s

	_normalize_samples(samples, 0.92)
	return _cache_and_build("meteor_dunk_impact", samples, false)


static func generate_dribble_whoosh_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("dribble_whoosh"):
		return _build_stream_from_cache("dribble_whoosh")

	var duration: float = 0.18
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 553311
	var bp_low: float = 0.0
	var bp_band: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		var u: float = t / duration
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		var f_cut: float = 420.0 + 1580.0 * sin(u * PI)
		var f_c: float = clampf(2.0 * sin(PI * f_cut * dt), 0.03, 0.72)
		var high: float = white - bp_low - 0.58 * bp_band
		bp_band += f_c * high
		bp_low += f_c * bp_band

		var env: float = smoothstep_f(0.0, 0.22, u) * (1.0 - smoothstep_f(0.55, 1.0, u))
		samples[i] = bp_band * env

	_normalize_samples(samples, 0.80)
	return _cache_and_build("dribble_whoosh", samples, false)


static func generate_combo_chime_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("combo_chime"):
		return _build_stream_from_cache("combo_chime")

	var duration: float = 0.32
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	for i in range(count):
		var t: float = float(i) * dt
		# Crisp anime synth combo chime (A5 + E6 FM bell)
		var fm: float = 0.65 * sin(TAU * 1760.0 * t) * exp(-t * 16.0)
		var env: float = minf(t / 0.003, 1.0) * exp(-t * 10.5)
		var tone: float = (
			sin(TAU * 880.0 * t + fm) * 0.58
			+ sin(TAU * 1318.5 * t) * 0.34
			+ sin(TAU * 1760.0 * t) * 0.20
		) * env
		if i > count - 441:
			tone *= float(count - i) / 441.0
		samples[i] = tone

	_normalize_samples(samples, 0.84)
	return _cache_and_build("combo_chime", samples, false)


static func generate_perfect_timing_bell_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("perfect_timing_bell"):
		return _build_stream_from_cache("perfect_timing_bell")

	var duration: float = 0.46
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	for i in range(count):
		var t: float = float(i) * dt
		# Sparkling crystal bell on Perfect timing (C6 + G6 + C7 shimmer)
		var att: float = minf(t / 0.002, 1.0)
		var b1: float = sin(TAU * 1046.50 * t) * exp(-t * 6.8) * 0.52
		var b2: float = sin(TAU * 1567.98 * t) * exp(-t * 8.5) * 0.36
		var b3: float = sin(TAU * 2093.00 * t) * exp(-t * 11.0) * 0.28
		var sparkle: float = sin(TAU * 3135.96 * t) * (0.7 + 0.3 * sin(TAU * 22.0 * t)) * exp(-t * 14.0) * 0.18
		var s: float = (b1 + b2 + b3 + sparkle) * att
		if i > count - 661:
			s *= float(count - i) / 661.0
		samples[i] = s

	_normalize_samples(samples, 0.85)
	return _cache_and_build("perfect_timing_bell", samples, false)


static func generate_block_swat_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("block_swat"):
		return _build_stream_from_cache("block_swat")

	var duration: float = 0.22
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 818283

	for i in range(count):
		var t: float = float(i) * dt
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0

		# Explosive palm-on-ball swat slap + hollow punch
		var slap: float = white * exp(-t * 44.0) * 0.72
		var punch: float = sin(TAU * (175.0 - 75.0 * minf(t * 12.0, 1.0)) * t) * exp(-t * 22.0) * 0.65
		var crack: float = sin(TAU * 980.0 * t) * exp(-t * 68.0) * 0.30
		var s: float = tanh((slap + punch + crack) * 1.35) * minf(t / 0.0015, 1.0)
		if i > count - 441:
			s *= float(count - i) / 441.0
		samples[i] = s

	_normalize_samples(samples, 0.88)
	return _cache_and_build("block_swat", samples, false)


static func generate_steal_snap_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("steal_snap"):
		return _build_stream_from_cache("steal_snap")

	var duration: float = 0.14
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 314159
	var prev_w: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0
		var hp: float = white - prev_w * 0.75
		prev_w = white

		var snap: float = hp * exp(-t * 52.0) * 0.75
		var pop: float = sin(TAU * 310.0 * t) * exp(-t * 36.0) * 0.55
		var zip_tone: float = sin(TAU * (1450.0 + 900.0 * t / duration) * t) * exp(-t * 34.0) * 0.28
		var s: float = (snap + pop + zip_tone) * minf(t / 0.0015, 1.0)
		if i > count - 300:
			s *= float(count - i) / 300.0
		samples[i] = s

	_normalize_samples(samples, 0.84)
	return _cache_and_build("steal_snap", samples, false)


static func generate_zone_aura_hum_loop() -> AudioStreamWAV:
	if _pcm_cache.has("zone_aura_hum"):
		return _build_stream_from_cache("zone_aura_hum")

	var duration: float = 1.50
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var rng: int = 271828
	var prev_n: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		rng = (rng * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng) / 1073741824.0) - 1.0
		var hp: float = white - prev_n * 0.82
		prev_n = white

		# Seamless periodic electric Zone hum (integer cycles over 1.5s: 110, 220, 330, 4 Hz pulse)
		var pulse: float = 0.78 + 0.22 * sin(TAU * 4.0 * t)
		var fm: float = 0.55 * sin(TAU * 16.0 * t)
		var hum: float = (
			sin(TAU * 110.0 * t) * 0.45
			+ sin(TAU * 220.0 * t + fm) * 0.34
			+ sin(TAU * 330.0 * t) * 0.20
			+ hp * 0.14 * (0.5 + 0.5 * sin(TAU * 12.0 * t))
		) * pulse
		samples[i] = hum

	var xfade: int = 1024
	for j in range(xfade):
		var alpha: float = float(j) / float(xfade)
		samples[j] = samples[j] * alpha + samples[count - xfade + j] * (1.0 - alpha)

	_normalize_samples(samples, 0.58)
	return _cache_and_build("zone_aura_hum", samples, true)


# ==============================================================================
# Zone Awakening & Adaptive Music Loop Generators (Phase 5 + 13)
# ==============================================================================

static func generate_zone_activate_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("zone_activate"):
		return _build_stream_from_cache("zone_activate")

	var duration: float = 1.10
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var bass_phase: float = 0.0
	var shimmer1_phase: float = 0.0
	var shimmer2_phase: float = 0.0
	var shimmer3_phase: float = 0.0
	var fm_phase: float = 0.0
	var rng_state: int = 133742

	for i in range(count):
		var t: float = float(i) * dt
		var u: float = t / duration

		var bass_freq: float = 38.0 + 117.0 * exp(-t * 6.2)
		bass_phase += TAU * bass_freq * dt
		var bass_env: float = minf(t / 0.008, 1.0) * exp(-t * 2.55)
		var bass_raw: float = sin(bass_phase) * 0.85 + sin(bass_phase * 2.0) * 0.25
		var bass: float = tanh(bass_raw * 1.65) * bass_env * 0.68

		rng_state = (rng_state * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng_state) / 1073741824.0) - 1.0
		var impact_env: float = exp(-t * 48.0)
		var impact: float = (white * 0.55 + sin(TAU * 240.0 * t) * 0.45) * impact_env * 0.42

		var rise: float = u * u
		var f1: float = 220.0 + 660.0 * rise
		var f2: float = 329.63 + 988.88 * rise
		var f3: float = 440.0 + 1320.0 * rise
		shimmer1_phase += TAU * f1 * dt
		shimmer2_phase += TAU * f2 * dt
		shimmer3_phase += TAU * f3 * dt
		fm_phase += TAU * (18.0 + 26.0 * u) * dt

		var fm_mod: float = 0.85 * sin(fm_phase)
		var shimmer_wave: float = (
			sin(shimmer1_phase + fm_mod) * 0.42
			+ sin(shimmer2_phase + fm_mod * 0.7) * 0.34
			+ sin(shimmer3_phase) * 0.24
		)
		var shimmer_env: float = smoothstep_f(0.02, 0.28, u) * (1.0 - smoothstep_f(0.62, 1.0, u))
		var tremolo: float = 0.78 + 0.22 * sin(TAU * 16.0 * t)
		var shimmer: float = shimmer_wave * shimmer_env * tremolo * 0.52

		var mixed: float = bass + impact + shimmer
		if i > count - 882:
			mixed *= float(count - i) / 882.0
		samples[i] = clampf(mixed, -0.98, 0.98)

	_normalize_samples(samples, 0.86)
	return _cache_and_build("zone_activate", samples, false)


static func generate_zone_end_sfx() -> AudioStreamWAV:
	if _pcm_cache.has("zone_end"):
		return _build_stream_from_cache("zone_end")

	var duration: float = 0.65
	var count: int = int(round(duration * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var p1: float = 0.0
	var p2: float = 0.0
	var p_sub: float = 0.0
	var rng_state: int = 987654
	var lp_noise: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		var u: float = t / duration

		var f1: float = 174.61 + 348.64 * exp(-t * 4.8)
		var f2: float = 220.0 + 439.25 * exp(-t * 5.2)
		var f_sub: float = 55.0 + 65.0 * exp(-t * 4.0)
		p1 += TAU * f1 * dt
		p2 += TAU * f2 * dt
		p_sub += TAU * f_sub * dt

		var env: float = minf(t / 0.010, 1.0) * exp(-t * 4.2) * (1.0 - smoothstep_f(0.80, 1.0, u))

		rng_state = (rng_state * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng_state) / 1073741824.0) - 1.0
		lp_noise = lp_noise * 0.92 + white * 0.08
		var exhale: float = lp_noise * exp(-t * 5.0) * 0.25

		var tone: float = (sin(p1) * 0.45 + sin(p2) * 0.30 + sin(p_sub) * 0.40) * env
		samples[i] = clampf(tone + exhale, -0.95, 0.95)

	_normalize_samples(samples, 0.78)
	return _cache_and_build("zone_end", samples, false)


static func generate_base_music_loop() -> AudioStreamWAV:
	if _pcm_cache.has("base_music"):
		return _build_stream_from_cache("base_music")

	var count: int = int(round(MUSIC_LOOP_SECONDS * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var beat_dur: float = 60.0 / MUSIC_BPM

	var bass_roots: PackedFloat32Array = PackedFloat32Array([110.0, 87.31, 98.0, 82.41])
	var chord_a: PackedFloat32Array = PackedFloat32Array([220.0, 174.61, 196.0, 164.81])
	var chord_b: PackedFloat32Array = PackedFloat32Array([261.63, 220.0, 246.94, 196.0])
	var chord_c: PackedFloat32Array = PackedFloat32Array([329.63, 261.63, 293.66, 246.94])

	var bass_phase: float = 0.0
	var ch1_phase: float = 0.0
	var ch2_phase: float = 0.0
	var ch3_phase: float = 0.0
	var rng_state: int = 202601
	var prev_noise: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		var beat_pos: float = t / beat_dur
		var beat_idx: int = int(floor(beat_pos)) % 8
		var beat_frac: float = beat_pos - floor(beat_pos)
		var chord_idx: int = (beat_idx >> 1) & 3

		var eighth_pos: float = beat_pos * 2.0
		var eighth_idx: int = int(floor(eighth_pos)) % 16
		var eighth_frac: float = eighth_pos - floor(eighth_pos)
		var bass_freq: float = bass_roots[chord_idx]
		if (eighth_idx & 3) == 3:
			bass_freq *= 2.0
		bass_phase += TAU * bass_freq * dt
		var bass_env: float = exp(-eighth_frac * 3.8)
		var bass: float = (sin(bass_phase) * 0.75 + sin(bass_phase * 2.0) * 0.25) * bass_env * 0.34

		var kick: float = 0.0
		var kick_t: float = -1.0
		if beat_idx == 0 or beat_idx == 2 or beat_idx == 4 or beat_idx == 6:
			if (beat_idx == 2 or beat_idx == 6) and beat_frac >= 0.5:
				kick_t = (beat_frac - 0.5) * beat_dur
			else:
				kick_t = beat_frac * beat_dur
		if kick_t >= 0.0 and kick_t < 0.14:
			var k_phase: float = TAU * (46.0 * kick_t + (86.0 / 34.0) * (1.0 - exp(-kick_t * 34.0)))
			kick = sin(k_phase) * exp(-kick_t * 24.0) * 0.44

		rng_state = (rng_state * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng_state) / 1073741824.0) - 1.0
		var hp_noise: float = white - prev_noise * 0.72
		prev_noise = white

		var snare: float = 0.0
		if (beat_idx & 1) == 1:
			var sn_t: float = beat_frac * beat_dur
			if sn_t < 0.11:
				var sn_body: float = sin(TAU * 195.0 * sn_t) * exp(-sn_t * 38.0)
				snare = (hp_noise * 0.65 + sn_body * 0.35) * exp(-sn_t * 28.0) * 0.28

		var hat_t: float = eighth_frac * (beat_dur * 0.5)
		var hat: float = hp_noise * exp(-hat_t * 95.0) * 0.09 if hat_t < 0.035 else 0.0

		ch1_phase += TAU * chord_a[chord_idx] * dt
		ch2_phase += TAU * chord_b[chord_idx] * dt
		ch3_phase += TAU * chord_c[chord_idx] * dt
		var stab_t: float = beat_frac - 0.5 if beat_frac >= 0.5 else beat_frac + 0.5
		var chord_env: float = exp(-stab_t * 5.2) * 0.18
		var chords: float = (sin(ch1_phase) + sin(ch2_phase) + sin(ch3_phase)) * 0.33 * chord_env

		var sample: float = bass + kick + snare + hat + chords
		if i < 132:
			sample *= float(i) / 132.0
		elif i > count - 132:
			sample *= float(count - i) / 132.0
		samples[i] = sample

	_normalize_samples(samples, 0.72)
	return _cache_and_build("base_music", samples, true)


static func generate_zone_intense_music_layer() -> AudioStreamWAV:
	if _pcm_cache.has("zone_music"):
		return _build_stream_from_cache("zone_music")

	var count: int = int(round(MUSIC_LOOP_SECONDS * float(SAMPLE_RATE)))
	var samples := PackedFloat32Array()
	samples.resize(count)

	var dt: float = 1.0 / float(SAMPLE_RATE)
	var beat_dur: float = 60.0 / MUSIC_BPM
	var step_dur: float = beat_dur * 0.25

	var arp_notes: PackedFloat32Array = PackedFloat32Array([
		440.0, 523.25, 659.25, 880.0, 659.25, 523.25, 783.99, 659.25,
		349.23, 440.0, 523.25, 698.46, 523.25, 440.0, 659.25, 523.25,
		392.00, 493.88, 587.33, 783.99, 587.33, 493.88, 659.25, 587.33,
		329.63, 415.30, 493.88, 659.25, 783.99, 659.25, 587.33, 493.88,
	])
	var power_roots: PackedFloat32Array = PackedFloat32Array([220.0, 174.61, 196.0, 164.81])

	var arp_phase: float = 0.0
	var pad1_phase: float = 0.0
	var pad2_phase: float = 0.0
	var sub_phase: float = 0.0
	var rng_state: int = 777555
	var prev_noise: float = 0.0

	for i in range(count):
		var t: float = float(i) * dt
		var beat_pos: float = t / beat_dur
		var beat_idx: int = int(floor(beat_pos)) % 8
		var beat_frac: float = beat_pos - floor(beat_pos)
		var chord_idx: int = (beat_idx >> 1) & 3

		var step_pos: float = t / step_dur
		var step_idx: int = int(floor(step_pos)) % 32
		var step_frac: float = step_pos - floor(step_pos)

		var arp_freq: float = arp_notes[step_idx]
		arp_phase += TAU * arp_freq * dt
		var arp_wave: float = (
			sin(arp_phase) * 0.55
			+ sin(arp_phase * 2.0) * 0.25
			+ sin(arp_phase * 3.0) * 0.14
			+ sin(arp_phase * 4.0) * 0.06
		)
		var arp_env: float = minf(step_frac * 14.0, 1.0) * exp(-step_frac * 3.2)
		var arp: float = tanh(arp_wave * 1.4) * arp_env * 0.42

		var p_root: float = power_roots[chord_idx]
		pad1_phase += TAU * p_root * dt
		pad2_phase += TAU * (p_root * 1.4983) * dt
		var pad_raw: float = (
			sin(pad1_phase) * 0.5 + sin(pad1_phase * 2.0) * 0.25 + sin(pad1_phase * 3.0) * 0.15
			+ sin(pad2_phase) * 0.45 + sin(pad2_phase * 2.0) * 0.20
		)
		var pump_env: float = 0.25 + 0.75 * sin(beat_frac * PI)
		var pad: float = tanh(pad_raw * 1.35) * pump_env * 0.30

		rng_state = (rng_state * 1103515245 + 12345) & 0x7fffffff
		var white: float = (float(rng_state) / 1073741824.0) - 1.0
		var hp_noise: float = white - prev_noise * 0.80
		prev_noise = white
		var hat_accent: float = 0.14 if (step_idx & 1) == 0 else 0.08
		var hat: float = hp_noise * exp(-step_frac * 10.5) * hat_accent

		sub_phase += TAU * (p_root * 0.5) * dt
		var sub: float = sin(sub_phase) * exp(-beat_frac * 3.4) * 0.24

		var sample: float = arp + pad + hat + sub
		if i < 132:
			sample *= float(i) / 132.0
		elif i > count - 132:
			sample *= float(count - i) / 132.0
		samples[i] = sample

	_normalize_samples(samples, 0.82)
	return _cache_and_build("zone_music", samples, true)


# ==============================================================================
# Shared PCM Utilities & Cache
# ==============================================================================

static func build_wav_from_samples(
	samples: PackedFloat32Array,
	loop: bool = false,
	sample_rate: int = SAMPLE_RATE
) -> AudioStreamWAV:
	var count: int = samples.size()
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i in range(count):
		var clamped: float = clampf(samples[i], -1.0, 1.0)
		var pcm: int = clampi(int(round(clamped * 32767.0)), -32768, 32767)
		bytes.encode_s16(i * 2, pcm)
	return _wrap_pcm_bytes(bytes, count, loop, sample_rate)


static func compute_rms(stream: AudioStreamWAV) -> float:
	if stream == null or stream.data.size() < 2:
		return 0.0
	var bytes: PackedByteArray = stream.data
	var sample_count: int = bytes.size() >> 1
	if sample_count <= 0:
		return 0.0
	var sum_sq: float = 0.0
	for i in range(sample_count):
		var v: float = float(bytes.decode_s16(i * 2)) / 32768.0
		sum_sq += v * v
	return sqrt(sum_sq / float(sample_count))


static func compute_peak(stream: AudioStreamWAV) -> float:
	if stream == null or stream.data.size() < 2:
		return 0.0
	var bytes: PackedByteArray = stream.data
	var sample_count: int = bytes.size() >> 1
	var peak: float = 0.0
	for i in range(sample_count):
		var v: float = absf(float(bytes.decode_s16(i * 2)) / 32768.0)
		if v > peak:
			peak = v
	return peak


static func clear_cache() -> void:
	_pcm_cache.clear()


static func _cache_and_build(cache_key: String, samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var count: int = samples.size()
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i in range(count):
		var clamped: float = clampf(samples[i], -1.0, 1.0)
		var pcm: int = clampi(int(round(clamped * 32767.0)), -32768, 32767)
		bytes.encode_s16(i * 2, pcm)
	_pcm_cache[cache_key] = {
		"bytes": bytes,
		"samples": count,
		"loop": loop,
	}
	return _wrap_pcm_bytes(bytes, count, loop, SAMPLE_RATE)


static func _build_stream_from_cache(cache_key: String) -> AudioStreamWAV:
	var entry: Dictionary = _pcm_cache[cache_key]
	return _wrap_pcm_bytes(
		entry["bytes"] as PackedByteArray,
		int(entry["samples"]),
		bool(entry["loop"]),
		SAMPLE_RATE
	)


static func _wrap_pcm_bytes(
	bytes: PackedByteArray,
	sample_count: int,
	loop: bool,
	sample_rate: int
) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = sample_count
	else:
		wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return wav


static func _normalize_samples(samples: PackedFloat32Array, target_peak: float) -> void:
	var peak: float = 0.0
	for i in range(samples.size()):
		var a: float = absf(samples[i])
		if a > peak:
			peak = a
	if peak <= 1e-6:
		return
	var gain: float = target_peak / peak
	for i in range(samples.size()):
		samples[i] = clampf(samples[i] * gain, -0.99, 0.99)


static func smoothstep_f(edge0: float, edge1: float, x: float) -> float:
	if absf(edge1 - edge0) <= 1e-6:
		return 1.0 if x >= edge1 else 0.0
	var t: float = clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
