extends Node
## Phase 12 Automated Verification Suite — Visual Effects & Custom Shaders
## (PHANTOM COURT ONLINE)
## Verifies:
## 1. All 8 custom .gdshader shaders compile/load cleanly + CharacterAnimator cel-shading &
##    next_pass ink outline + ArenaBuilder stylized hardwood court_floor.gdshader material.
## 2. RibbonTrail3D procedural geometry generation + live Basketball (SHOT_FLIGHT / PASS_FLIGHT)
##    and PlayerController (sprint / dash / Zone) 3D ribbon trails + speed lines coupling.
## 3. ScreenShake quadratic trauma impulses, monotonic decay, and ConfigManager camera_shake_scale.
## 4. CinematicDirector offline slow-mo hit-stop & clean 1.0x restoration, STRICT online 1.0x
##    Engine.time_scale lock, 2-3 frame impact flash, radial speed lines, dunk camera override,
##    and dynamic arena spotlight shifts.
## 5. Full VFXManager EventBus reactions (combo_triggered, ankle_broken, block_performed,
##    score_changed, dunk_impact, shot_released) & CameraRig FX blending + clean restoration.

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"
const BTN_SPRINT: int = 1


func run(runner: SceneTree) -> void:
	await _test_eight_shaders_cel_rig_and_court_floor(runner)
	await _test_ribbon_trails_unit_and_live(runner)
	await _test_screen_shake_trauma_and_config(runner)
	await _test_cinematic_director_and_online_safety(runner)
	await _test_vfx_manager_event_reactions_and_camera_rig(runner)
	# Defensive guarantee: never leave Engine.time_scale or GameState.is_online modified
	Engine.time_scale = 1.0
	GameState.is_online = false


func _make_input_controller(player: Node3D) -> Dictionary:
	var ctrl := {
		"local_dir": Vector2.ZERO,
		"move_world_xz": Vector2.ZERO,
		"buttons": 0,
		"aim_yaw": 0.0,
		"seq": 0,
	}
	player.call("set_external_input_provider", func(tick: int, _dt: float) -> Dictionary:
		ctrl["seq"] = int(ctrl["seq"]) + 1
		return {
			"seq": int(ctrl["seq"]),
			"tick": tick,
			"move_world_xz": ctrl["move_world_xz"],
			"local_dir": ctrl["local_dir"],
			"buttons": int(ctrl["buttons"]),
			"aim_yaw": float(ctrl["aim_yaw"]),
		}
	)
	return ctrl


# ==============================================================================
# 1. All 8 Custom Shaders, Cel-Shaded Character Rig & Court Floor Material
# ==============================================================================
func _test_eight_shaders_cel_rig_and_court_floor(runner: SceneTree) -> void:
	await runner.clear_stage()

	var expected_shaders := [
		["res://shaders/cel_character.gdshader", ["albedo_color", "rim_color", "shadow_tint", "void light("]],
		["res://shaders/character_outline.gdshader", ["cull_front", "outline_width", "outline_color"]],
		["res://shaders/court_floor.gdshader", ["wood_light_color", "wood_dark_color", "accent_ring_color"]],
		["res://shaders/motion_trail.gdshader", ["blend_add", "trail_color", "intensity"]],
		["res://shaders/impact_frame.gdshader", ["canvas_item", "flash_strength", "ink_color"]],
		["res://shaders/speed_lines.gdshader", ["canvas_item", "intensity", "inner_clear_radius"]],
		["res://shaders/zone_aura.gdshader", ["aura_color", "intensity"]],
		["res://shaders/zone_vignette.gdshader", ["vignette_color", "intensity"]],
	]
	runner.assert_eq(VFXManager.SHADER_PATHS.size(), 8, "VFXManager registers all 8 custom shaders")

	for entry in expected_shaders:
		var path: String = String(entry[0])
		var tokens: Array = entry[1]
		runner.assert_true(VFXManager.SHADER_PATHS.has(path), "VFXManager.SHADER_PATHS contains '%s'" % path.get_file())
		var sh := load(path) as Shader
		runner.assert_not_null(sh, "Shader loads cleanly: %s" % path.get_file())
		if sh != null:
			var tokens_ok := true
			for tok in tokens:
				if not sh.code.contains(String(tok)):
					tokens_ok = false
					break
			runner.assert_true(tokens_ok, "Shader '%s' defines required uniforms/modes" % path.get_file())

	# Mount Arena and inspect CourtFloor shader & CharacterAnimator cel+outline materials
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var vfx: VFXManager = arena.call("get_vfx_manager")
	runner.assert_not_null(vfx, "ArenaBuilder.get_vfx_manager() returns mounted VFXManager")
	if vfx != null:
		runner.assert_eq(vfx.get_shader_paths().size(), 8, "vfx.get_shader_paths() returns all 8 shaders")

	var floor_mat: ShaderMaterial = arena.call("get_court_floor_material")
	runner.assert_not_null(floor_mat, "ArenaBuilder applies ShaderMaterial to PlayableCourtSurface")
	if floor_mat != null and floor_mat.shader != null:
		runner.assert_eq(floor_mat.shader.resource_path, VFXManager.SHADER_COURT_FLOOR, "PlayableCourtSurface uses court_floor.gdshader")

	var anim: CharacterAnimator = player.animator
	runner.assert_true(anim.uses_cel_shader(), "CharacterAnimator uses cel_character.gdshader")
	var jersey_mat: ShaderMaterial = anim.get_jersey_material()
	runner.assert_not_null(jersey_mat, "CharacterAnimator exposes jersey ShaderMaterial")
	if jersey_mat != null:
		runner.assert_eq(jersey_mat.shader.resource_path, VFXManager.SHADER_CEL_CHARACTER, "Jersey material uses cel_character.gdshader")
		var outline_pass := jersey_mat.next_pass as ShaderMaterial
		runner.assert_not_null(outline_pass, "Jersey material attaches character_outline next_pass")
		if outline_pass != null and outline_pass.shader != null:
			runner.assert_eq(outline_pass.shader.resource_path, VFXManager.SHADER_CHARACTER_OUTLINE, "next_pass uses character_outline.gdshader")
			runner.assert_approx(float(outline_pass.get_shader_parameter("outline_width")), 0.018, 0.005, "Ink outline_width defaults near 0.018")

	# Archetype visual update dynamically updates cel shader albedo_color
	player.call("apply_archetype_by_id", "sharpshooter")
	if jersey_mat != null:
		var updated_col: Color = jersey_mat.get_shader_parameter("albedo_color")
		var sharp_colors: Dictionary = ArchetypeRegistry.get_archetype("sharpshooter").colors
		var sharp_primary: Color = sharp_colors["primary"]
		runner.assert_approx(updated_col.r, sharp_primary.r, 0.02, "Archetype switch dynamically updates cel_character albedo_color (R)")
		runner.assert_approx(updated_col.b, sharp_primary.b, 0.02, "Archetype switch dynamically updates cel_character albedo_color (B)")


# ==============================================================================
# 2. RibbonTrail3D Procedural Geometry + Live Basketball & PlayerController Trails
# ==============================================================================
func _test_ribbon_trails_unit_and_live(runner: SceneTree) -> void:
	await runner.clear_stage()

	# 2A. Standalone RibbonTrail3D unit check (including duplicate zero-length point safety)
	var trail := RibbonTrail3D.new()
	runner.get_stage().add_child(trail)
	trail.set_width(0.28)
	trail.set_trail_color(Color(1.0, 0.85, 0.15, 1.0))
	trail.set_emitting(true)
	for i in range(8):
		trail.sample_point(Vector3(float(i) * 0.45, 1.2 + sin(float(i) * 0.4) * 0.25, -float(i) * 0.35), 1.0 / 60.0)
	# Feed duplicate point to guarantee zero-length cross/normalize guard never crashes or NaNs
	trail.sample_point(Vector3(7.0 * 0.45, 1.2 + sin(7.0 * 0.4) * 0.25, -7.0 * 0.35), 1.0 / 60.0)

	runner.assert_ge(trail.get_point_count(), 6, "RibbonTrail3D records smooth trajectory points (count=%d)" % trail.get_point_count())
	runner.assert_ge(trail.get_vertex_count(), 12, "RibbonTrail3D builds ImmediateMesh ribbon vertices (verts=%d)" % trail.get_vertex_count())
	trail.clear_trail()
	runner.assert_eq(trail.get_point_count(), 0, "RibbonTrail3D.clear_trail() empties point buffer")
	runner.assert_eq(trail.get_vertex_count(), 0, "RibbonTrail3D.clear_trail() clears mesh vertices")

	# 2B. Live Arena Basketball & PlayerController RibbonTrail3D integration
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var ball := arena.get_node_or_null("Basketball") as RigidBody3D
	var vfx: VFXManager = arena.call("get_vfx_manager")
	var cine: CinematicDirector = vfx.get_cinematic_director()

	var ball_trail: RibbonTrail3D = ball.call("get_ribbon_trail")
	var player_trail: RibbonTrail3D = player.call("get_ribbon_trail")
	runner.assert_not_null(ball_trail, "Basketball mounts RibbonTrail3D")
	runner.assert_not_null(player_trail, "PlayerController mounts RibbonTrail3D")
	runner.assert_ge(vfx.get_active_trails().size(), 2, "VFXManager tracks both ball & player RibbonTrail3D nodes")

	# Shot flight activates ball ribbon trail (Gold on Perfect release)
	var eb: Node = runner.get_event_bus()
	ball.call(
		"launch_shot",
		player, 1, 0,
		Vector3(0.0, 2.2, -5.0),
		Vector3(0.0, 0.0, -5.0),
		Vector3(0.0, 3.05, -12.425),
		Vector3(0.0, 6.4, -5.8),
		Vector3(-12.0, 0.0, 0.0),
		true
	)
	eb.emit_signal("shot_released", 1, Vector3(0.0, 2.2, -5.0), Vector3(0.0, 3.05, -12.425), 0.96, true)
	await runner.wait_physics_frames(12)

	runner.assert_true(ball_trail.is_emitting(), "Basketball RibbonTrail3D emits during SHOT_FLIGHT")
	runner.assert_ge(ball_trail.get_point_count(), 3, "Shot flight accumulates 3D ribbon points (count=%d)" % ball_trail.get_point_count())
	runner.assert_ge(ball_trail.get_vertex_count(), 6, "Shot flight builds live ribbon geometry (verts=%d)" % ball_trail.get_vertex_count())
	var perfect_col: Color = ball_trail.get_trail_color()
	runner.assert_true(perfect_col.r > 0.85 and perfect_col.g > 0.65, "Perfect shot tints ball ribbon trail Gold (r=%.2f, g=%.2f)" % [perfect_col.r, perfect_col.g])

	ball.call("reset_to_free", Vector3(6.0, 0.5, 10.0))
	runner.assert_false(ball_trail.is_emitting(), "Ball reset disables ribbon trail emission")
	runner.assert_eq(ball_trail.get_point_count(), 0, "Ball reset clears ribbon trail points")

	# Player sprinting activates player ribbon trail + anime radial speed lines!
	var ctrl := _make_input_controller(player)
	player.call("reset_for_match", Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 4.0)))
	ctrl["local_dir"] = Vector2(0.0, 1.0)
	ctrl["buttons"] = BTN_SPRINT
	await runner.wait_physics_frames(18)

	runner.assert_true(player_trail.is_emitting(), "Sprinting activates PlayerController RibbonTrail3D")
	runner.assert_ge(player_trail.get_point_count(), 3, "Sprinting accumulates player trail points (count=%d)" % player_trail.get_point_count())
	runner.assert_ge(cine.get_speed_lines_intensity(), 0.30, "Sprinting drives anime radial speed lines >= 0.30 (actual=%.2f)" % cine.get_speed_lines_intensity())

	ctrl["local_dir"] = Vector2.ZERO
	ctrl["buttons"] = 0
	await runner.wait_physics_frames(14)
	vfx.step_vfx(0.4)
	runner.assert_approx(cine.get_speed_lines_intensity(), 0.0, 0.05, "Stopping sprint clears speed lines back to 0.0")


# ==============================================================================
# 3. ScreenShake Quadratic Trauma & ConfigManager Scaling
# ==============================================================================
func _test_screen_shake_trauma_and_config(runner: SceneTree) -> void:
	await runner.clear_stage()

	var shake := ScreenShake.new()
	shake.auto_process = false
	runner.get_stage().add_child(shake)

	var cm: Node = runner.root.get_node_or_null("ConfigManager")
	var orig_scale: float = float(cm.call("get_setting", "gameplay", "camera_shake_scale", 1.0)) if cm != null else 1.0
	if cm != null:
		cm.call("set_setting", "gameplay", "camera_shake_scale", 1.0)

	shake.add_trauma(0.80)
	runner.assert_approx(shake.get_trauma(), 0.80, 0.01, "ScreenShake.add_trauma(0.80) sets trauma")
	var f1: Dictionary = shake.step_shake(1.0 / 60.0)
	runner.assert_gt((f1["offset"] as Vector3).length(), 0.005, "High trauma produces non-zero camera shake offset")
	runner.assert_gt(absf(float(f1["roll_rad"])), 0.001, "High trauma produces non-zero camera shake roll")

	# Monotonic decay to 0.0 over 1.0s
	for _i in range(60):
		shake.step_shake(1.0 / 60.0)
	runner.assert_approx(shake.get_trauma(), 0.0, 0.001, "ScreenShake trauma decays cleanly to 0.0")
	runner.assert_approx((shake.get_last_shake()["offset"] as Vector3).length(), 0.0, 0.001, "Zero trauma yields zero shake offset")

	# Respects ConfigManager camera_shake_scale == 0.0
	if cm != null:
		cm.call("set_setting", "gameplay", "camera_shake_scale", 0.0)
		shake.add_trauma(0.90)
		var f_zero: Dictionary = shake.step_shake(1.0 / 60.0)
		runner.assert_approx(shake.get_trauma(), 0.0, 0.001, "camera_shake_scale == 0.0 disables screen shake trauma")
		runner.assert_approx((f_zero["offset"] as Vector3).length(), 0.0, 0.001, "camera_shake_scale == 0.0 produces zero offset")
		cm.call("set_setting", "gameplay", "camera_shake_scale", orig_scale)


# ==============================================================================
# 4. CinematicDirector (Offline Hit-Stop, Online 1.0x Lock, Impact Frames, Lights)
# ==============================================================================
func _test_cinematic_director_and_online_safety(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D

	var cine := CinematicDirector.new()
	cine.auto_process = false
	runner.get_stage().add_child(cine)

	# 4A. Offline Slow-Motion Hit-Stop & Exact 1.0x Restoration
	GameState.is_online = false
	var applied_offline: bool = cine.trigger_hit_stop(0.18, 0.25, true)
	runner.assert_true(applied_offline, "Offline trigger_hit_stop() modulates Engine.time_scale")
	runner.assert_approx(Engine.time_scale, 0.25, 0.001, "Offline hit-stop sets Engine.time_scale == 0.25")
	runner.assert_true(cine.is_time_scale_modified(), "is_time_scale_modified() == true during offline hit-stop")

	cine.step_director(0.10) # 0.08s unscaled remaining
	runner.assert_approx(Engine.time_scale, 0.25, 0.001, "Hit-stop stays active mid-duration")
	cine.step_director(0.10) # expires cleanly!
	runner.assert_approx(Engine.time_scale, 1.0, 0.001, "Hit-stop restores Engine.time_scale cleanly to 1.0")
	runner.assert_false(cine.is_time_scale_modified(), "is_time_scale_modified() == false after expiry")

	# 4B. STRICT Online Safety Lock: Engine.time_scale NEVER leaves 1.0 in online matches!
	GameState.is_online = true
	var applied_online: bool = cine.trigger_hit_stop(0.18, 0.25, true)
	runner.assert_false(applied_online, "Online trigger_hit_stop() refuses Engine.time_scale modification")
	runner.assert_approx(Engine.time_scale, 1.0, 0.0001, "ONLINE SAFETY: Engine.time_scale remains strictly locked at 1.0")
	runner.assert_true(cine.is_impact_frame_active(), "Online hit-stop still fires pure visual impact flash")
	runner.assert_true(bool(cine.get_cinematic_camera_override()["active"]), "Online hit-stop still fires pure visual camera FOV punch")
	GameState.is_online = false
	cine.reset()

	# 4C. 3-Frame Monochrome Impact Flash
	cine.trigger_impact_frame(3, Color.WHITE)
	runner.assert_true(cine.is_impact_frame_active(), "trigger_impact_frame(3) activates flash")
	runner.assert_eq(cine.get_impact_frames_left(), 3, "Impact flash starts with 3 frames remaining")
	runner.assert_gt(cine.get_impact_flash_strength(), 0.9, "Impact flash peak strength == 1.0")
	for _f in range(4):
		cine.step_director(1.0 / 60.0)
	runner.assert_false(cine.is_impact_frame_active(), "3-frame impact flash expires cleanly after 3-4 frames")
	runner.assert_approx(cine.get_impact_flash_strength(), 0.0, 0.001, "Impact flash strength clears to 0.0")

	# 4D. Dynamic Arena Lighting (Zone + Dunk Flash boosts spotlights & glow, restores baseline!)
	var base_light: Dictionary = cine.update_arena_lighting(arena, false, 0.0)
	var zone_light: Dictionary = cine.update_arena_lighting(arena, true, 0.85, Color(0.0, 0.94, 1.0))
	runner.assert_gt(float(zone_light["spotlight_energy"]), float(base_light["spotlight_energy"]) * 1.25, "Zone + dunk flash boosts stadium spotlight energy")
	runner.assert_gt(float(zone_light["glow_intensity"]), float(base_light["glow_intensity"]) + 0.15, "Zone + dunk flash boosts WorldEnvironment glow intensity")
	var restored_light: Dictionary = cine.update_arena_lighting(arena, false, 0.0)
	runner.assert_approx(float(restored_light["spotlight_energy"]), float(base_light["spotlight_energy"]), 0.05, "Arena spotlight energy restores cleanly to baseline")
	runner.assert_approx(float(restored_light["glow_intensity"]), float(base_light["glow_intensity"]), 0.02, "Arena glow intensity restores cleanly to baseline")


# ==============================================================================
# 5. Full VFXManager EventBus Reactions & CameraRig FX Blending
# ==============================================================================
func _test_vfx_manager_event_reactions_and_camera_rig(runner: SceneTree) -> void:
	await runner.clear_stage()
	var arena := await runner.mount_scene(ARENA_SCENE_PATH) as Node3D
	var player := arena.get_node_or_null("Players/LocalPlayer") as CharacterBody3D
	var vfx: VFXManager = arena.call("get_vfx_manager")
	var rig: Node3D = player.camera_rig
	var cine: CinematicDirector = vfx.get_cinematic_director()
	var shake: ScreenShake = vfx.get_screen_shake()
	var eb: Node = runner.get_event_bus()

	vfx.reset_vfx()
	var b0: int = vfx.get_burst_count()

	# Combo triggered -> burst + speed-lines spike
	eb.emit_signal("combo_triggered", 1, "phantom_drive", 1, true)
	runner.assert_gt(float(vfx.get_burst_count()), float(b0), "EventBus.combo_triggered spawns stylized particle burst")
	runner.assert_gt(cine.get_speed_lines_intensity(), 0.2, "EventBus.combo_triggered spikes anime speed lines")

	# Ankle broken -> lightning shatter burst + trauma + impact flash
	var b1: int = vfx.get_burst_count()
	eb.emit_signal("ankle_broken", 2, 1, Vector3(0.0, 0.0, -5.0))
	runner.assert_gt(float(vfx.get_burst_count()), float(b1), "EventBus.ankle_broken spawns shatter particle burst")
	runner.assert_gt(shake.get_trauma(), 0.30, "EventBus.ankle_broken injects camera trauma")
	runner.assert_true(cine.is_impact_frame_active(), "EventBus.ankle_broken triggers 2-frame impact flash")

	# Block performed -> swat burst + trauma + impact flash
	var b2: int = vfx.get_burst_count()
	eb.emit_signal("block_performed", 2, 1, Vector3(0.0, 2.6, -6.5))
	runner.assert_gt(float(vfx.get_burst_count()), float(b2), "EventBus.block_performed spawns swat spark burst")

	# Score changed -> swish burst
	var b3: int = vfx.get_burst_count()
	eb.emit_signal("score_changed", 0, 3, 3, true, 1)
	runner.assert_gt(float(vfx.get_burst_count()), float(b3), "EventBus.score_changed spawns net swish confetti burst")

	# Monster Meteor Dunk impact (power = 1.65 >= 1.4) -> shockwave + heavy trauma + 3f flash + cinematic camera + offline hit-stop!
	var b4: int = vfx.get_burst_count()
	GameState.is_online = false
	eb.emit_signal("dunk_impact", 1, Vector3(0.0, 3.05, -12.425), 1.65)
	runner.assert_gt(float(vfx.get_burst_count()), float(b4), "EventBus.dunk_impact spawns rim shockwave burst")
	runner.assert_ge(shake.get_trauma(), 0.65, "Monster dunk_impact drives heavy trauma >= 0.65")
	runner.assert_true(cine.is_impact_frame_active(), "Monster dunk_impact triggers impact frame flash")
	runner.assert_true(cine.is_time_scale_modified(), "Offline monster dunk triggers slow-mo hit-stop")
	runner.assert_true(bool(vfx.get_camera_fx_frame()["cinematic_active"]), "Monster dunk activates cinematic camera override")

	# CameraRig blends shake offset & cinematic FOV punch cleanly
	vfx.step_vfx(0.02)
	rig.call("step_camera_fx", 0.02)
	runner.assert_true(bool(rig.call("is_cinematic_override_active")), "CameraRig reflects active cinematic dunk override")
	runner.assert_lt(float(rig.call("get_applied_cinematic_fov_delta")), -2.0, "CameraRig applies dramatic negative cinematic FOV punch")
	runner.assert_gt((rig.call("get_applied_shake_offset") as Vector3).length(), 0.001, "CameraRig applies damped ScreenShake offset")

	# Settle over 1.2s unscaled -> Engine.time_scale, trauma, flash, cinematic override & FOV restore cleanly!
	for _s in range(12):
		vfx.step_vfx(0.10)
		rig.call("step_camera_fx", 0.10)
	runner.assert_approx(Engine.time_scale, 1.0, 0.001, "Engine.time_scale cleanly restored to 1.0 after dunk hit-stop")
	runner.assert_approx(shake.get_trauma(), 0.0, 0.001, "ScreenShake trauma fully decayed after dunk")
	runner.assert_false(cine.is_impact_frame_active(), "Impact flash fully cleared after dunk")
	runner.assert_false(bool(rig.call("is_cinematic_override_active")), "CameraRig cinematic override cleared after dunk")
	runner.assert_approx(float(rig.call("get_current_fov")), 72.0, 0.5, "CameraRig FOV cleanly returns to 72.0° baseline")
