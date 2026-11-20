extends SceneTree
## Phase 15 — Real Hardware 60 FPS GPU Profiling Benchmark for PHANTOM COURT ONLINE.
## Runs WINDOWED (NOT --headless!) on real GPU hardware:
##   tools\godot\Godot_v4.7.2-stable_win64_console.exe --path client -s res://tests/fps_benchmark.gd
## Optional args (after `--`):
##   --warmup <frames>   Warmup rendered frames (default 120)
##   --frames <frames>   Measured consecutive rendered frames (default 600)
##   --timeout <sec>     Safety wall-clock timeout (default 90.0)
##   --json-out <path>   Optional absolute path to dump JSON telemetry

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"

var _warmup_frames: int = 120
var _sample_frames: int = 600
var _timeout_sec: float = 90.0
var _json_out_path: String = ""

var _start_usec: int = 0
var _prev_usec: int = 0
var _frame_idx: int = 0
var _setup_done: bool = false
var _finished: bool = false

var _arena: Node = null
var _zone_players: Array[Node] = []

var _frame_times_ms: PackedFloat64Array = PackedFloat64Array()
var _process_ms_samples: PackedFloat64Array = PackedFloat64Array()
var _physics_ms_samples: PackedFloat64Array = PackedFloat64Array()
var _draw_calls_samples: PackedFloat64Array = PackedFloat64Array()
var _primitives_samples: PackedFloat64Array = PackedFloat64Array()
var _vram_mb_samples: PackedFloat64Array = PackedFloat64Array()
var _static_ram_mb_samples: PackedFloat64Array = PackedFloat64Array()
var _peak_draw_calls: float = 0.0
var _peak_primitives: float = 0.0
var _peak_vram_mb: float = 0.0
var _peak_static_ram_mb: float = 0.0


func _initialize() -> void:
	_start_usec = Time.get_ticks_usec()
	_parse_args()

	# Disable VSync and frame cap in memory ONLY (never persists to user://settings.cfg)
	Engine.max_fps = 0
	Engine.time_scale = 1.0
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title("PHANTOM COURT ONLINE — Phase 15 Hardware GPU Benchmark")
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	print("========================================================================")
	print(" PHANTOM COURT ONLINE — Real Hardware 60 FPS GPU Profiling Benchmark")
	print(" Godot: %s | Display: %s | Renderer: %s" % [
		Engine.get_version_info().get("string", "unknown"),
		DisplayServer.get_name(),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")),
	])
	print(" GPU Adapter: %s (%s) | API: %s" % [
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_video_adapter_vendor(),
		RenderingServer.get_video_adapter_api_version(),
	])
	print(" CPU: %s (%d threads) | Window: %s | VSync: DISABLED" % [
		OS.get_processor_name(),
		OS.get_processor_count(),
		str(DisplayServer.window_get_size()),
	])
	print(" Workload: Full 3v3 Phantom AI Scrimmage (6 cel-shaded+ink players,")
	print("           court_floor.gdshader, Verlet nets, RibbonTrail3D, HUD,")
	print("           SoundManager, VFXManager, 2x Zone Awakening active!)")
	print(" Sampling: %d warmup frames -> %d measured consecutive frames" % [_warmup_frames, _sample_frames])
	print("========================================================================")
	# Defer workload mount to first _process() frame so SceneTree & autoloads are 100% live.


func _parse_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		match args[i]:
			"--warmup":
				if i + 1 < args.size():
					_warmup_frames = maxi(10, int(args[i + 1]))
					i += 1
			"--frames":
				if i + 1 < args.size():
					_sample_frames = maxi(60, int(args[i + 1]))
					i += 1
			"--timeout":
				if i + 1 < args.size():
					_timeout_sec = maxf(15.0, float(args[i + 1]))
					i += 1
			"--json-out":
				if i + 1 < args.size():
					_json_out_path = args[i + 1]
					i += 1
		i += 1


func _mount_workload() -> void:
	if not ResourceLoader.exists(ARENA_SCENE_PATH):
		printerr("[BENCH ERROR] Arena scene missing: %s" % ARENA_SCENE_PATH)
		_finished = true
		quit(1)
		return

	var packed := load(ARENA_SCENE_PATH) as PackedScene
	if packed == null:
		printerr("[BENCH ERROR] Failed to load PackedScene: %s" % ARENA_SCENE_PATH)
		_finished = true
		quit(1)
		return

	# Ensure clean offline defaults before mounting
	var gs: Node = root.get_node_or_null("GameState")
	if gs != null:
		gs.set("is_online", false)
		gs.set("is_spectator", false)
		gs.set("auto_spawn_roster", false)

	_arena = packed.instantiate()
	if _arena == null:
		printerr("[BENCH ERROR] Failed to instantiate Arena")
		_finished = true
		quit(1)
		return

	root.add_child(_arena)

	# Re-enforce VSync off AFTER ConfigManager / Arena ready
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	# Spawn full 3v3 Phantom AI vs AI scrimmage (6 active players with distinct archetypes)
	if _arena.has_method("spawn_ai_match_roster"):
		var roster: Variant = _arena.call("spawn_ai_match_roster", "3v3_ai_vs_ai", 3, 202605, false)
		if roster is Array:
			var r_arr: Array = roster as Array
			# Pick 1 Team 0 player and 1 Team 1 player for simultaneous Zone Awakening
			if r_arr.size() >= 4:
				_zone_players = [r_arr[0], r_arr[3]]
			elif r_arr.size() >= 2:
				_zone_players = [r_arr[0], r_arr[1]]
			print("[BENCH] Spawned 3v3 Phantom AI scrimmage: %d players active" % r_arr.size())

	# Wide broadcast court view ensures ALL 6 players, BOTH hoops + Verlet nets,
	# court_floor.gdshader, bleachers, trails, and both Zone auras render simultaneously!
	if _arena.has_method("set_spectator_mode"):
		_arena.call("set_spectator_mode", true)

	# Keep HUD visible in normal match telemetry style (hide spectator ribbon only or keep full HUD)
	# Leaving full HUD + Spectator banner enabled actually stresses full CanvasLayer UI too!

	_activate_peak_vfx()
	_setup_done = true
	_prev_usec = Time.get_ticks_usec()


func _activate_peak_vfx() -> void:
	for p in _zone_players:
		if p == null or not is_instance_valid(p):
			continue
		var zc: Variant = p.get("zone")
		if zc != null and zc.has_method("set_energy"):
			zc.call("set_energy", 100.0)
		if p.has_method("activate_zone"):
			p.call("activate_zone")


func _ensure_zone_stays_active() -> void:
	for p in _zone_players:
		if p == null or not is_instance_valid(p):
			continue
		var in_zone: bool = bool(p.call("is_in_zone")) if p.has_method("is_in_zone") else false
		if not in_zone:
			var zc: Variant = p.get("zone")
			if zc != null and zc.has_method("set_energy"):
				zc.call("set_energy", 100.0)
			if p.has_method("activate_zone"):
				p.call("activate_zone")


func _process(_delta: float) -> bool:
	if _finished:
		return true

	var now_usec: int = Time.get_ticks_usec()
	var elapsed_sec: float = float(now_usec - _start_usec) / 1000000.0
	if elapsed_sec > _timeout_sec:
		printerr("[BENCH TIMEOUT] Exceeded %.1fs timeout at frame %d" % [_timeout_sec, _frame_idx])
		_finished = true
		quit(1)
		return true

	if not _setup_done:
		_mount_workload()
		_prev_usec = Time.get_ticks_usec()
		return false

	# Keep Engine.time_scale == 1.0 during benchmark measurement so offline dunk slow-mo doesn't skew wall-clock test cadence
	if absf(Engine.time_scale - 1.0) > 0.001:
		Engine.time_scale = 1.0

	var dt_ms: float = float(now_usec - _prev_usec) / 1000.0
	_prev_usec = now_usec
	_frame_idx += 1

	# Re-trigger Zone cleanly right at the end of warmup so Zone stays active across all 600 measured frames
	if _frame_idx == _warmup_frames:
		_ensure_zone_stays_active()
		var vfx: Node = _arena.call("get_vfx_manager") if _arena != null and _arena.has_method("get_vfx_manager") else null
		if vfx != null and vfx.has_method("set_speed_lines_intensity"):
			vfx.call("set_speed_lines_intensity", 0.45)
		print("[BENCH] Warmup complete (%d frames). Measuring %d consecutive rendered frames..." % [_warmup_frames, _sample_frames])
		return false

	if _frame_idx < _warmup_frames:
		return false

	# Periodic Zone check during measurement
	if (_frame_idx % 120) == 0:
		_ensure_zone_stays_active()

	# Record real wall-clock frame delta & engine performance monitors
	_frame_times_ms.append(dt_ms)

	var proc_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var draw_calls: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var primitives: float = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var vram_mb: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var static_mb: float = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0

	_process_ms_samples.append(proc_ms)
	_physics_ms_samples.append(phys_ms)
	_draw_calls_samples.append(draw_calls)
	_primitives_samples.append(primitives)
	_vram_mb_samples.append(vram_mb)
	_static_ram_mb_samples.append(static_mb)

	if draw_calls > _peak_draw_calls:
		_peak_draw_calls = draw_calls
	if primitives > _peak_primitives:
		_peak_primitives = primitives
	if vram_mb > _peak_vram_mb:
		_peak_vram_mb = vram_mb
	if static_mb > _peak_static_ram_mb:
		_peak_static_ram_mb = static_mb

	if _frame_times_ms.size() >= _sample_frames:
		_finish_and_report()
		return true

	return false


func _finish_and_report() -> void:
	_finished = true

	var n: int = _frame_times_ms.size()
	var sorted_ms: Array[float] = []
	sorted_ms.resize(n)
	var total_ms: float = 0.0
	for i in range(n):
		var v: float = _frame_times_ms[i]
		sorted_ms[i] = v
		total_ms += v
	sorted_ms.sort()

	var mean_ms: float = total_ms / float(maxi(1, n))
	var min_ms: float = sorted_ms[0]
	var p05_ms: float = _percentile(sorted_ms, 0.05)
	var p50_ms: float = _percentile(sorted_ms, 0.50)
	var p95_ms: float = _percentile(sorted_ms, 0.95)
	var p99_ms: float = _percentile(sorted_ms, 0.99)
	var max_ms: float = sorted_ms[n - 1]

	var mean_fps: float = 1000.0 / maxf(mean_ms, 0.001)
	var min_fps: float = 1000.0 / maxf(max_ms, 0.001)
	var p1_fps: float = 1000.0 / maxf(p99_ms, 0.001)
	var p5_fps: float = 1000.0 / maxf(p95_ms, 0.001)
	var p50_fps: float = 1000.0 / maxf(p50_ms, 0.001)
	var p95_fps: float = 1000.0 / maxf(p05_ms, 0.001)
	var max_fps: float = 1000.0 / maxf(min_ms, 0.001)

	var mean_proc_ms: float = _mean(_process_ms_samples)
	var mean_phys_ms: float = _mean(_physics_ms_samples)
	var mean_draw_calls: float = _mean(_draw_calls_samples)
	var mean_primitives: float = _mean(_primitives_samples)
	var mean_vram_mb: float = _mean(_vram_mb_samples)
	var mean_static_mb: float = _mean(_static_ram_mb_samples)
	var node_count: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var active_phys_3d: int = int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))

	var zone_active_count: int = 0
	for p in _zone_players:
		if p != null and is_instance_valid(p) and p.has_method("is_in_zone") and bool(p.call("is_in_zone")):
			zone_active_count += 1

	var vfx: Node = _arena.call("get_vfx_manager") if _arena != null and _arena.has_method("get_vfx_manager") else null
	var vignette_active: bool = bool(vfx.call("is_zone_ui_active")) if vfx != null and vfx.has_method("is_zone_ui_active") else false
	var sm: Node = _arena.get_node_or_null("SoundManager") if _arena != null else null
	var music_intensity: float = float(sm.call("get_zone_intensity")) if sm != null and sm.has_method("get_zone_intensity") else 0.0

	var target_met: bool = (mean_fps >= 60.0 and p5_fps >= 60.0)

	print("------------------------------------------------------------------------")
	print(" BENCHMARK RESULTS (%d frames, %.2fs measured)" % [n, total_ms / 1000.0])
	print("------------------------------------------------------------------------")
	print("  GPU Adapter       : %s (%s)" % [RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_vendor()])
	print("  Rendering API     : %s | Method: %s" % [
		RenderingServer.get_video_adapter_api_version(),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")),
	])
	print("  Window Resolution : %s | Display: %s" % [str(DisplayServer.window_get_size()), DisplayServer.get_name()])
	print("  Peak VFX Active   : Zone Auras=%d/%d | Zone Vignette=%s | DynamicMusic=%.2f" % [
		zone_active_count, _zone_players.size(), str(vignette_active), music_intensity
	])
	print("  FPS               : mean=%.2f | p50=%.2f | p95=%.2f | max=%.2f" % [mean_fps, p50_fps, p95_fps, max_fps])
	print("  FPS Lows          : p5(5%% low)=%.2f | p1(1%% low)=%.2f | min=%.2f" % [p5_fps, p1_fps, min_fps])
	print("  Frame Time (ms)   : mean=%.3f | p50=%.3f | p95=%.3f | p99=%.3f | max=%.3f" % [mean_ms, p50_ms, p95_ms, p99_ms, max_ms])
	print("  CPU Frame Work    : TIME_PROCESS=%.3f ms | TIME_PHYSICS_PROCESS=%.3f ms" % [mean_proc_ms, mean_phys_ms])
	print("  GPU Geometry      : draw_calls=%.1f (peak=%.0f) | primitives=%.0f (peak=%.0f)" % [
		mean_draw_calls, _peak_draw_calls, mean_primitives, _peak_primitives
	])
	print("  Memory            : VRAM=%.2f MB (peak=%.2f MB) | Static RAM=%.2f MB (peak=%.2f MB)" % [
		mean_vram_mb, _peak_vram_mb, mean_static_mb, _peak_static_ram_mb
	])
	print("  Scene Telemetry   : nodes=%d | physics_3d_active=%d" % [node_count, active_phys_3d])
	print("------------------------------------------------------------------------")
	print("  TARGET (>= 60 FPS mean & p5): %s" % ("PASS" if target_met else "FAIL"))
	print("========================================================================")

	if not _json_out_path.is_empty():
		var payload := {
			"godot_version": str(Engine.get_version_info().get("string", "unknown")),
			"display_driver": DisplayServer.get_name(),
			"rendering_method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")),
			"gpu_adapter": RenderingServer.get_video_adapter_name(),
			"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
			"gpu_api": RenderingServer.get_video_adapter_api_version(),
			"cpu": OS.get_processor_name(),
			"cpu_threads": OS.get_processor_count(),
			"window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
			"warmup_frames": _warmup_frames,
			"measured_frames": n,
			"measured_seconds": total_ms / 1000.0,
			"zone_active_count": zone_active_count,
			"fps": {
				"mean": mean_fps,
				"min": min_fps,
				"p1": p1_fps,
				"p5": p5_fps,
				"p50": p50_fps,
				"p95": p95_fps,
				"max": max_fps,
			},
			"frame_time_ms": {
				"mean": mean_ms,
				"min": min_ms,
				"p50": p50_ms,
				"p95": p95_ms,
				"p99": p99_ms,
				"max": max_ms,
			},
			"cpu_ms": {
				"time_process_mean": mean_proc_ms,
				"time_physics_process_mean": mean_phys_ms,
			},
			"render": {
				"draw_calls_mean": mean_draw_calls,
				"draw_calls_peak": _peak_draw_calls,
				"primitives_mean": mean_primitives,
				"primitives_peak": _peak_primitives,
				"vram_mb_mean": mean_vram_mb,
				"vram_mb_peak": _peak_vram_mb,
			},
			"memory": {
				"static_ram_mb_mean": mean_static_mb,
				"static_ram_mb_peak": _peak_static_ram_mb,
			},
			"scene": {
				"node_count": node_count,
				"physics_3d_active": active_phys_3d,
			},
			"target_met": target_met,
		}
		var f := FileAccess.open(_json_out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(payload, "\t"))
			f.close()
			print("[BENCH] Wrote JSON telemetry to: %s" % _json_out_path)

	# Clean teardown of mounted Arena before quitting
	if _arena != null and is_instance_valid(_arena):
		if _arena.get_parent() != null:
			_arena.get_parent().remove_child(_arena)
		_arena.free()
		_arena = null

	quit(0)


static func _percentile(sorted_vals: Array[float], q: float) -> float:
	if sorted_vals.is_empty():
		return 0.0
	var pos: float = clampf(q, 0.0, 1.0) * float(sorted_vals.size() - 1)
	var lo: int = int(floor(pos))
	var hi: int = mini(sorted_vals.size() - 1, lo + 1)
	var frac: float = pos - float(lo)
	return lerpf(sorted_vals[lo], sorted_vals[hi], frac)


static func _mean(arr: PackedFloat64Array) -> float:
	if arr.is_empty():
		return 0.0
	var s: float = 0.0
	for v in arr:
		s += v
	return s / float(arr.size())
