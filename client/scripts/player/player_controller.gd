class_name PlayerController
extends CharacterBody3D
## Canonical 60 Hz Third-Person Basketball Character Controller (Phases 1–5).
## Integrates ARCHITECTURE.md Section 5 & Section 7 contracts, Advanced Basketball,
## Fighting-Game ComboEngine, 5 Character Archetypes, and Phase 5 Zone Awakening + EX Skills.

const BTN_SPRINT: int  = 1    # 1 << 0
const BTN_JUMP: int    = 2    # 1 << 1
const BTN_SHOOT: int   = 4    # 1 << 2
const BTN_PASS: int    = 8    # 1 << 3
const BTN_SKILL_Q: int = 16   # 1 << 4
const BTN_SKILL_E: int = 32   # 1 << 5
const BTN_SKILL_R: int = 64   # 1 << 6
const BTN_STEAL: int   = 128  # 1 << 7
const BTN_ZONE: int    = 256  # 1 << 8
const BTN_STANCE: int  = 512  # 1 << 9

const DEFAULT_RUN_SPEED: float = 6.2
const DEFAULT_SPRINT_SPEED: float = 8.8
const DEFAULT_STANCE_SPEED: float = 4.4
const DEFAULT_JUMP_VELOCITY: float = 6.8
const DEFAULT_GRAVITY: float = 15.0
const LANDING_RECOVERY_TICKS: int = 8
const ANKLE_BREAK_RECOVERY_FRAMES: int = 66
const ANKLE_BREAK_DURATION_SEC: float = 1.10

const AURA_SCRIPT_PATH := "res://scripts/vfx/aura_controller.gd"

@export var player_id: int = 1
@export var team_id: int = 0
@export var is_local_human: bool = true
@export var archetype_id: String = "phantom_pg"

# Tunable movement, balance & archetype stats
var run_speed: float = DEFAULT_RUN_SPEED
var sprint_speed: float = DEFAULT_SPRINT_SPEED
var stance_speed: float = DEFAULT_STANCE_SPEED
var acceleration: float = 38.0
var deceleration: float = 44.0
var air_acceleration: float = 11.0
var jump_velocity: float = DEFAULT_JUMP_VELOCITY
var gravity: float = DEFAULT_GRAVITY
var facing_yaw: float = 0.0
var aim_yaw: float = 0.0

# Phase 4/5 Archetype & Zone modifiers
var dribble_stamina_mult: float = 1.0
var ankle_break_mult: float = 1.0
var balance_resistance: float = 1.0
var cancel_window_bonus: int = 0
var aura_color: Color = Color(0.20, 0.92, 1.0, 1.0)
var rig_scale: Vector3 = Vector3.ONE
var anim_variation: Dictionary = {}
var last_executed_was_ex: bool = false

var max_balance: float = 100.0
var balance: float = 100.0
var momentum_vec: Vector2 = Vector2.ZERO
var ankle_break_frames_left: int = 0

# Runtime simulation state
var _external_input_provider: Variant = null
var _input_seq: int = 0
var _local_tick_counter: int = 0
var _prev_buttons: int = 0
var _is_sprinting: bool = false
var _in_defensive_stance: bool = false
var _was_on_floor: bool = true
var _landing_frames_left: int = 0
var _ankle_broken_stun: float = 0.0
var _strip_flinch_timer: float = 0.0
var _phantom_phase_timer: float = 0.0
var _reset_bvh_guard_ticks: int = 0
var _combo_burst_vel: Vector3 = Vector3.ZERO
var _combo_burst_timer: float = 0.0
var _footstep_accum: float = 0.0
var _back_tap_timer: float = 0.0
var _was_holding_back: bool = false
var _prev_touch_explicit_sprint: bool = false
var _touch_sprint_retrigger_pending: bool = false
var _recent_normal_spends: Array[Dictionary] = []
var _spawn_transform: Transform3D = Transform3D.IDENTITY
var _archetype_data: Dictionary = {}
var aura_controller: Node3D = null
var ribbon_trail: RibbonTrail3D = null
var _trail_registered_with_vfx: bool = false

@onready var camera_rig: CameraRig = get_node_or_null("CameraRig") as CameraRig
@onready var animator: CharacterAnimator = get_node_or_null("CharacterAnimator") as CharacterAnimator
@onready var dribble_system: DribbleSystem = get_node_or_null("DribbleSystem") as DribbleSystem
@onready var shooting_system: ShootingSystem = get_node_or_null("ShootingSystem") as ShootingSystem
@onready var defense_system: DefenseSystem = get_node_or_null("DefenseSystem") as DefenseSystem
@onready var stamina: StaminaComponent = get_node_or_null("StaminaComponent") as StaminaComponent
@onready var zone: ZoneComponent = get_node_or_null("ZoneComponent") as ZoneComponent
@onready var combo_engine: ComboEngine = get_node_or_null("ComboEngine") as ComboEngine


func _ready() -> void:
	add_to_group("players")
	collision_layer = 2
	collision_mask = 1 | 2
	floor_snap_length = 0.18
	_spawn_transform = global_transform

	var fwd: Vector3 = -global_transform.basis.z
	if Vector2(fwd.x, fwd.z).length_squared() > 0.0001:
		facing_yaw = atan2(-fwd.x, -fwd.z)
		aim_yaw = facing_yaw

	_ensure_subcomponents()
	_was_on_floor = global_position.y <= 0.08

	if ArchetypeRegistry.has_archetype(archetype_id):
		apply_archetype(ArchetypeRegistry.get_archetype_dict(archetype_id))
	elif is_local_human and GameState != null and ArchetypeRegistry.has_archetype(GameState.selected_archetype):
		apply_archetype(ArchetypeRegistry.get_archetype_dict(GameState.selected_archetype))


func _ensure_subcomponents() -> void:
	if animator == null:
		animator = CharacterAnimator.new()
		animator.name = "CharacterAnimator"
		add_child(animator)
	animator.set_team_palette(team_id)
	aura_color = animator.aura_color

	if camera_rig == null:
		camera_rig = CameraRig.new()
		camera_rig.name = "CameraRig"
		camera_rig.position = Vector3(0.0, 1.55, 0.0)
		add_child(camera_rig)
	camera_rig.set_active_camera(is_local_human and _external_input_provider == null)
	camera_rig.set_yaw(aim_yaw)

	if stamina == null:
		stamina = StaminaComponent.new()
		stamina.name = "StaminaComponent"
		add_child(stamina)
	stamina.setup(player_id, 100.0, 20.0)

	if zone == null:
		zone = ZoneComponent.new()
		zone.name = "ZoneComponent"
		add_child(zone)
	zone.setup(player_id, 100.0, 1.0)

	if dribble_system == null:
		dribble_system = DribbleSystem.new()
		dribble_system.name = "DribbleSystem"
		add_child(dribble_system)
	dribble_system.setup(self, animator)

	if shooting_system == null:
		shooting_system = ShootingSystem.new()
		shooting_system.name = "ShootingSystem"
		add_child(shooting_system)
	shooting_system.setup(self, animator, stamina, dribble_system)

	if defense_system == null:
		defense_system = DefenseSystem.new()
		defense_system.name = "DefenseSystem"
		add_child(defense_system)
	defense_system.setup(self, animator, stamina)

	if combo_engine == null:
		combo_engine = ComboEngine.new()
		combo_engine.name = "ComboEngine"
		add_child(combo_engine)
	combo_engine.setup(player_id, null, archetype_id)

	_ensure_optional_aura_controller()
	_ensure_optional_ribbon_trail()


func get_ribbon_trail() -> RibbonTrail3D:
	_ensure_optional_ribbon_trail()
	return ribbon_trail


func _ensure_optional_ribbon_trail() -> void:
	if ribbon_trail == null or not is_instance_valid(ribbon_trail):
		ribbon_trail = get_node_or_null("RibbonTrail3D") as RibbonTrail3D
	if is_inside_tree() and get_tree() != null:
		var vfx := get_tree().get_first_node_in_group("vfx_manager") as VFXManager
		if vfx != null:
			ribbon_trail = vfx.attach_trail_to_node(self, aura_color, 0.24)
			ribbon_trail.set_target_node(self, Vector3(0.0, 0.92, 0.0))
			_trail_registered_with_vfx = true
	if ribbon_trail == null:
		ribbon_trail = RibbonTrail3D.new()
		ribbon_trail.name = "RibbonTrail3D"
		add_child(ribbon_trail)
		ribbon_trail.set_target_node(self, Vector3(0.0, 0.92, 0.0))
		ribbon_trail.set_trail_color(aura_color)
		ribbon_trail.set_width(0.24)
		ribbon_trail.set_emitting(false)
	else:
		ribbon_trail.set_trail_color(aura_color)


func _ensure_optional_aura_controller() -> void:
	if aura_controller != null and is_instance_valid(aura_controller):
		if aura_controller.has_method("setup"):
			aura_controller.call("setup", player_id, aura_color)
		elif aura_controller.has_method("set_aura_color"):
			aura_controller.call("set_aura_color", aura_color)
		return

	var existing: Node = get_node_or_null("AuraController")
	if existing == null and animator != null:
		existing = animator.get_node_or_null("AuraController")
	if existing is Node3D:
		aura_controller = existing as Node3D
		if aura_controller.has_method("setup"):
			aura_controller.call("setup", player_id, aura_color)
		return

	if ResourceLoader.exists(AURA_SCRIPT_PATH):
		var aura_scr := load(AURA_SCRIPT_PATH) as GDScript
		if aura_scr != null and aura_scr.can_instantiate():
			var inst: Variant = aura_scr.new()
			if inst is Node3D:
				aura_controller = inst as Node3D
				aura_controller.name = "AuraController"
				add_child(aura_controller)
				if aura_controller.has_method("setup"):
					aura_controller.call("setup", player_id, aura_color)


# ==============================================================================
# Phase 5 Zone Awakening & Effective Stat Getters
# ==============================================================================

func is_in_zone() -> bool:
	return zone != null and zone.is_active


func activate_zone() -> bool:
	return zone.activate_zone() if zone != null else false


func get_effective_run_speed() -> float:
	var z_mult: float = zone.get_speed_multiplier() if zone != null else 1.0
	var s_mult: float = (stamina.get_speed_multiplier() if (stamina != null and has_ball()) else 1.0)
	return run_speed * z_mult * s_mult


func get_effective_sprint_speed() -> float:
	var z_mult: float = zone.get_speed_multiplier() if zone != null else 1.0
	var s_mult: float = stamina.get_speed_multiplier() if stamina != null else 1.0
	return sprint_speed * z_mult * s_mult


func get_effective_jump_velocity() -> float:
	var z_mult: float = zone.get_jump_multiplier() if zone != null else 1.0
	return jump_velocity * z_mult


func get_effective_block_radius() -> float:
	var base_blk: float = defense_system.block_radius if defense_system != null else 1.70
	var z_mult: float = zone.get_block_reach_multiplier() if zone != null else 1.0
	return base_blk * z_mult


func get_stamina_cost_multiplier() -> float:
	return zone.get_stamina_cost_multiplier() if zone != null else 1.0


func get_effective_acceleration() -> float:
	var lat_mult: float = defense_system.get_lateral_accel_multiplier() if defense_system != null else (1.25 if _in_defensive_stance else 1.0)
	return acceleration * lat_mult


func get_effective_balance_resistance() -> float:
	var stance_mult: float = defense_system.get_stance_balance_resistance() if defense_system != null else (1.40 if _in_defensive_stance else 1.0)
	return maxf(0.2, balance_resistance * stance_mult)


func get_momentum_vector() -> Vector2:
	return momentum_vec


func get_ankle_break_frames_remaining() -> int:
	return ankle_break_frames_left


func compute_defensive_positioning_score(ball_handler: Node3D = null) -> float:
	var handler: Node3D = ball_handler
	if handler == null:
		var b: Basketball = _find_basketball()
		if b != null and b.carrier != null and b.carrier != self and b.carrier_team_id != team_id:
			handler = b.carrier
		else:
			handler = _find_primary_opponent()
	if handler == null:
		return 0.0
	return DefenseSystem.compute_defensive_positioning(self, handler, _get_defended_rim_position())


# ==============================================================================
# Canonical Integration API (ARCHITECTURE.md Section 7) + Phase 2–5 Helpers
# ==============================================================================

func set_external_input_provider(provider) -> void:
	_external_input_provider = provider
	if camera_rig != null:
		camera_rig.set_active_camera(is_local_human and _external_input_provider == null)


func apply_archetype_by_id(arch_id: String) -> bool:
	var arch_dict: Dictionary = ArchetypeRegistry.get_archetype_dict(arch_id)
	if arch_dict.is_empty():
		return false
	apply_archetype(arch_dict)
	return true


func get_archetype_data() -> Dictionary:
	return _archetype_data.duplicate(true)


func apply_archetype(archetype_dict: Dictionary) -> void:
	_archetype_data = archetype_dict.duplicate(true)
	archetype_id = str(archetype_dict.get("id", archetype_dict.get("archetype_id", archetype_id)))

	var stats: Dictionary = (
		archetype_dict["stats"] as Dictionary
		if (archetype_dict.has("stats") and archetype_dict["stats"] is Dictionary)
		else archetype_dict
	)

	run_speed = float(stats.get("run_speed", archetype_dict.get("run_speed", DEFAULT_RUN_SPEED)))
	sprint_speed = float(stats.get("sprint_speed", archetype_dict.get("sprint_speed", DEFAULT_SPRINT_SPEED)))
	acceleration = float(stats.get("acceleration", archetype_dict.get("acceleration", 38.0)))
	jump_velocity = float(stats.get("jump_velocity", archetype_dict.get("jump_velocity", DEFAULT_JUMP_VELOCITY)))

	var max_stam: float = float(stats.get("max_stamina", archetype_dict.get("stamina_max", archetype_dict.get("max_stamina", 100.0))))
	var stam_regen: float = float(stats.get("stamina_regen", archetype_dict.get("stamina_regen", 20.0)))
	dribble_stamina_mult = maxf(0.2, float(stats.get("dribble_stamina_mult", archetype_dict.get("dribble_stamina_mult", 1.0))))
	if stamina != null:
		stamina.setup(player_id, max_stam, stam_regen)

	if shooting_system != null:
		if stats.has("perfect_window_bonus"):
			shooting_system.timing_window_scale = maxf(0.5, 1.0 + float(stats["perfect_window_bonus"]))
		else:
			shooting_system.timing_window_scale = maxf(0.5, float(archetype_dict.get("shot_timing_window", 1.0)))

		if stats.has("shot_arc_bonus"):
			shooting_system.shot_arc_bonus = 1.35 + float(stats["shot_arc_bonus"])
		else:
			shooting_system.shot_arc_bonus = float(archetype_dict.get("shot_arc", 1.35))

		shooting_system.dunk_range_xz = float(stats.get("dunk_radius", archetype_dict.get("dunk_radius", ShootingSystem.DUNK_RANGE_XZ)))
		shooting_system.three_point_range = float(stats.get("three_point_range", archetype_dict.get("three_point_range", 8.20)))
		shooting_system.pass_speed_mult = maxf(0.5, float(stats.get("pass_speed_mult", archetype_dict.get("pass_speed_mult", 1.0))))

	cancel_window_bonus = int(stats.get("cancel_window_bonus", archetype_dict.get("cancel_window_bonus", 0)))
	ankle_break_mult = maxf(0.2, float(stats.get("ankle_break_mult", archetype_dict.get("ankle_break_mult", 1.0))))
	balance_resistance = maxf(0.2, float(stats.get("balance_resistance", archetype_dict.get("balance_resistance", 1.0))))

	if defense_system != null:
		defense_system.steal_radius = float(stats.get("steal_radius", archetype_dict.get("steal_radius", 1.75)))
		defense_system.block_radius = float(stats.get("block_radius", archetype_dict.get("block_radius", 1.70)))

	if zone != null:
		var z_mult: float = float(stats.get("zone_gain_mult", archetype_dict.get("zone_gain_rate", archetype_dict.get("zone_gain_mult", 1.0))))
		zone.setup(player_id, float(archetype_dict.get("zone_max", 100.0)), z_mult)

	if combo_engine != null:
		combo_engine.setup(player_id, null, archetype_id)
		combo_engine.set_extra_cancel_frames(cancel_window_bonus)

	var colors_dict: Dictionary = {}
	if archetype_dict.has("colors") and archetype_dict["colors"] is Dictionary:
		colors_dict = (archetype_dict["colors"] as Dictionary).duplicate(true)
	else:
		if archetype_dict.has("jersey_color") and archetype_dict["jersey_color"] is Color:
			colors_dict["primary"] = archetype_dict["jersey_color"]
		if archetype_dict.has("secondary_color") and archetype_dict["secondary_color"] is Color:
			colors_dict["secondary"] = archetype_dict["secondary_color"]
		if archetype_dict.has("accent_color") and archetype_dict["accent_color"] is Color:
			colors_dict["accent"] = archetype_dict["accent_color"]
		if archetype_dict.has("aura_color") and archetype_dict["aura_color"] is Color:
			colors_dict["aura"] = archetype_dict["aura_color"]
		if archetype_dict.has("hair_color") and archetype_dict["hair_color"] is Color:
			colors_dict["hair"] = archetype_dict["hair_color"]

	if colors_dict.has("aura") and colors_dict["aura"] is Color:
		aura_color = colors_dict["aura"]

	if archetype_dict.has("rig_scale") and archetype_dict["rig_scale"] is Vector3:
		rig_scale = archetype_dict["rig_scale"]
	else:
		rig_scale = Vector3.ONE

	if archetype_dict.has("anim_variation") and archetype_dict["anim_variation"] is Dictionary:
		anim_variation = (archetype_dict["anim_variation"] as Dictionary).duplicate(true)
	else:
		anim_variation = {}

	if dribble_system != null:
		dribble_system.dribble_speed_scale = float(anim_variation.get("dribble_speed_scale", 1.0))
	if shooting_system != null:
		shooting_system.shot_release_height_offset = float(anim_variation.get("shot_release_height", 0.0))

	if animator != null:
		if not colors_dict.is_empty() or rig_scale != Vector3.ONE or not anim_variation.is_empty():
			animator.apply_archetype_visuals(colors_dict, rig_scale, anim_variation)
		else:
			animator.set_team_palette(team_id)
		aura_color = animator.aura_color

	_ensure_optional_aura_controller()
	_ensure_optional_ribbon_trail()


func perform_dribble_move(move_name: String, is_perfect: bool = false) -> bool:
	return execute_combo_move({"id": move_name, "tier": 1}, is_perfect)


func execute_combo_move(move_def: Dictionary, is_perfect: bool) -> bool:
	if ankle_break_frames_left > 0 or _ankle_broken_stun > 0.0 or _strip_flinch_timer > 0.0:
		return false

	var move_id: String = str(move_def.get("id", move_def.get("name", "crossover"))).strip_edges().to_lower()
	var from_combo_engine: bool = bool(move_def.get("emitted_by_combo_engine", false))
	var zone_active: bool = is_in_zone()
	var is_zone_ex: bool = bool(move_def.get("is_zone_ex", false)) or zone_active

	var db_move: FrameData = combo_engine.move_db.get_move(move_id) if (combo_engine != null and combo_engine.move_db != null) else null
	var params: Dictionary = {}
	if db_move != null:
		params = db_move.gameplay_params.duplicate(true)
	if move_def.has("gameplay_params") and move_def["gameplay_params"] is Dictionary:
		var custom_p: Dictionary = move_def["gameplay_params"]
		for k in custom_p.keys():
			params[k] = custom_p[k]

	var is_archetype_unique: bool = SkillExecutor.is_archetype_skill(move_id)
	var is_signature_special: bool = (
		from_combo_engine
		or is_archetype_unique
		or move_id == MoveDatabase.MOVE_PHANTOM_DRIVE
		or move_id == MoveDatabase.MOVE_METEOR_DUNK
		or move_id == MoveDatabase.MOVE_ANKLE_BREAKER
		or move_id == MoveDatabase.MOVE_MIRROR_STEP
		or (db_move != null and db_move.priority >= FrameData.PRIORITY_SPECIAL)
	)

	if is_archetype_unique and db_move != null and not db_move.archetype_id.is_empty():
		if not db_move.is_valid_for_archetype(archetype_id):
			return false

	if not is_signature_special and not move_def.has("direction"):
		if dribble_system != null and not dribble_system.can_execute_move(move_id):
			return false

	var perf_mult: float = ComboEngine.PERFECT_POTENCY_MULT if is_perfect else 1.0
	var potency_mult: float = float(move_def.get("potency_mult", perf_mult * (1.15 if (is_zone_ex and is_signature_special) else 1.0)))
	var ball: Basketball = _find_basketball()
	var carrying_ball: bool = (ball != null and ball.carrier == self)
	var target_rim: Vector3 = _get_target_rim_position()
	var stam_mult: float = stamina.get_speed_multiplier() if stamina != null else 1.0
	var zone_mult: float = zone.get_speed_multiplier() if zone != null else 1.0

	var skill_plan: Dictionary = {}
	if is_archetype_unique:
		if db_move != null and db_move.requires_ball and not carrying_ball:
			return false
		var p_mult: float = shooting_system.pass_speed_mult if shooting_system != null else 1.0
		var actor_ctx: Dictionary = SkillExecutor.build_actor_context_from_player(
			self,
			target_rim,
			carrying_ball,
			potency_mult,
			zone_mult,
			p_mult,
			get_dribble_hand()
		)
		actor_ctx["is_zone_ex"] = is_zone_ex
		skill_plan = SkillExecutor.build_skill_plan(move_id, params, actor_ctx)
		if not bool(skill_plan.get("valid", false)):
			return false
		skill_plan["is_zone_ex"] = is_zone_ex

	# Compute net stamina cost (with Zone 0.75x efficiency applied exactly once!)
	var stamina_cost: float = 0.0
	var already_zone_discounted: bool = false
	if move_def.has("stamina_cost"):
		stamina_cost = float(move_def["stamina_cost"])
		if not is_signature_special:
			stamina_cost *= dribble_stamina_mult
		# If ComboEngine set move_def["is_zone_ex"] == true, it already applied 0.75x to stamina_cost
		already_zone_discounted = from_combo_engine and bool(move_def.get("is_zone_ex", false))
	elif db_move != null:
		var base_c: float = db_move.stamina_cost * (1.0 if is_signature_special else dribble_stamina_mult)
		stamina_cost = base_c * (1.0 - (ComboEngine.PERFECT_STAMINA_REFUND_RATIO if is_perfect else 0.0))
	elif move_id != DribbleSystem.MOVE_DRIBBLE_LEFT and move_id != DribbleSystem.MOVE_DRIBBLE_RIGHT:
		stamina_cost = (
			StaminaComponent.COST_DRIBBLE_MOVE
			* dribble_stamina_mult
			* (1.0 - (ComboEngine.PERFECT_STAMINA_REFUND_RATIO if is_perfect else 0.0))
		)

	if stamina != null:
		stamina.set_cost_multiplier(get_stamina_cost_multiplier())
		if stamina_cost > 0.0:
			if from_combo_engine:
				_refund_kara_startup_stamina()
			var pre_stam: float = stamina.current_stamina
			if not stamina.consume(stamina_cost, false, already_zone_discounted):
				return false
			if not is_signature_special:
				_record_normal_stamina_spend(pre_stam - stamina.current_stamina)
		elif from_combo_engine:
			_recent_normal_spends.clear()

	last_executed_was_ex = is_zone_ex and is_signature_special
	var tier: int = int(move_def.get("combo_chain_count", move_def.get("tier", 1)))

	# ==========================================================================
	# A. Execute Phase 4/5 Archetype Unique Class Skills (+ EX variants)
	# ==========================================================================
	if is_archetype_unique:
		if not _execute_archetype_skill_plan(move_id, skill_plan, ball, potency_mult):
			return false
	else:
		# ======================================================================
		# B. Execute Phase 3/5 Universal Signature Combos (+ EX variants) & Normals
		# ======================================================================
		match move_id:
			MoveDatabase.MOVE_PHANTOM_DRIVE:
				# Phantom Drive EX: 1.22x dash speed (~16.5 m/s) & extended phase burst
				var ex_spd_mult: float = 1.22 if is_zone_ex else 1.0
				var dash_spd: float = float(params.get("dash_speed", 13.5)) * ex_spd_mult * perf_mult
				var dur: float = maxf(0.12, float(params.get("duration", 0.30)) * (1.16 if is_zone_ex else 1.0))
				var dash_dir: Vector3 = BallTrajectory.safe_normalize_xz(target_rim - global_position)
				_face_position_xz(target_rim)

				if bool(params.get("pass_through_defender", true)):
					_enable_phantom_phase(dur + 0.06)

				if dribble_system != null:
					dribble_system.swap_hand()
					if bool(params.get("steal_immune", true)):
						dribble_system.steal_shield_timer = maxf(dribble_system.steal_shield_timer, dur + 0.16)
					dribble_system.start_signature_trajectory(move_id, dur, dash_dir * dash_spd)
				else:
					_combo_burst_vel = dash_dir * dash_spd
					_combo_burst_timer = dur
					velocity.x = _combo_burst_vel.x
					velocity.z = _combo_burst_vel.z

				if animator != null:
					animator.trigger_action(&"phantom_drive", dur + 0.06, get_dribble_hand() == 1)
				EventBus.dribble_move_performed.emit(player_id, move_id, global_position)

			MoveDatabase.MOVE_METEOR_DUNK:
				# Meteor Dunk EX: launch range up to 6.5m (vs 5.5m base), 1.25x shockwave radius (4.375m) & slam power
				var max_dist: float = 6.5 if is_zone_ex else float(params.get("max_rim_dist", 5.5))
				var cur_dist_xz: float = Vector2(global_position.x - target_rim.x, global_position.z - target_rim.z).length()
				if cur_dist_xz > max_dist + 0.15 or ball == null or ball.carrier != self:
					return false
				_face_position_xz(target_rim)
				_enable_phantom_phase(0.55 if is_zone_ex else 0.50)

				var dunk_params: Dictionary = params.duplicate(true)
				dunk_params["is_zone_ex"] = is_zone_ex
				if is_zone_ex:
					dunk_params["max_rim_dist"] = 6.5
					dunk_params["shockwave_radius"] = float(params.get("shockwave_radius", 3.5)) * 1.25
					dunk_params["dunk_power"] = float(params.get("dunk_power", 1.5)) * 1.25
					dunk_params["apex_height"] = maxf(float(params.get("apex_height", 4.15)), 4.55)
				if shooting_system != null:
					shooting_system.begin_meteor_dunk(ball, target_rim, player_id, team_id, dunk_params, perf_mult)
				EventBus.dribble_move_performed.emit(player_id, move_id, global_position)

			MoveDatabase.MOVE_ANKLE_BREAKER:
				# Ankle Breaker EX: wider 3.6m cone & +35% balance damage
				var base_cone: float = 3.6 if is_zone_ex else float(params.get("cone_range", 2.8))
				var base_bal_dmg: float = float(params.get("balance_damage", 110.0)) * (1.35 if is_zone_ex else 1.0)
				var cone_r: float = base_cone * perf_mult
				var bal_dmg: float = base_bal_dmg * perf_mult * ankle_break_mult
				var shot_bon: float = float(params.get("gather_shot_bonus", 0.14)) * (1.25 if is_zone_ex else 1.0) * perf_mult

				_face_position_xz(target_rim)
				var fwd: Vector3 = _get_facing_forward_xz()
				var right: Vector3 = fwd.cross(Vector3.UP).normalized()
				var ab_cut_dir: Vector3 = fwd

				if dribble_system != null:
					dribble_system.swap_hand()
					var side_sign: float = 1.0 if dribble_system.get_dribble_hand() == DribbleSystem.DribbleHand.RIGHT else -1.0
					ab_cut_dir = BallTrajectory.safe_normalize_xz(-fwd * 0.45 + right * (0.89 * side_sign))
					dribble_system.steal_shield_timer = maxf(dribble_system.steal_shield_timer, 0.38)
					dribble_system.grant_shot_bonus(shot_bon, 0.95)
					dribble_system.start_signature_trajectory(move_id, 0.20, ab_cut_dir * (10.2 * perf_mult * zone_mult))

				if animator != null:
					animator.trigger_action(&"ankle_breaker", 0.28, get_dribble_hand() == 1)

				var hit_ids: Dictionary = _apply_cone_ankle_breaker(cone_r, bal_dmg, ab_cut_dir)
				_evaluate_defender_momentum_misreads(move_id, ab_cut_dir, is_perfect, is_zone_ex, hit_ids)
				EventBus.dribble_move_performed.emit(player_id, move_id, global_position)

			MoveDatabase.MOVE_MIRROR_STEP:
				# Mirror Step EX: extended 3.8m separation & +0.22 shot window bonus
				var feint_fwd: float = float(params.get("feint_forward", 0.65))
				var base_stepback: float = 3.8 if is_zone_ex else float(params.get("stepback_dist", 3.2))
				var base_shot_bon: float = 0.22 if is_zone_ex else float(params.get("shot_window_bonus", 0.15))
				var stepback_d: float = base_stepback * perf_mult
				var lat_off: float = float(params.get("lateral_offset", 1.1)) * (1.15 if is_zone_ex else 1.0) * perf_mult
				var shot_win_bon: float = base_shot_bon * perf_mult

				_face_position_xz(target_rim)
				var fwd_m: Vector3 = _get_facing_forward_xz()
				var right_m: Vector3 = fwd_m.cross(Vector3.UP).normalized()

				var feint_dur: float = 4.0 / 60.0
				var vanish_dur: float = 16.0 / 60.0
				var total_dur: float = feint_dur + vanish_dur
				var ms_cut_dir: Vector3 = -fwd_m

				if dribble_system != null:
					dribble_system.swap_hand()
					var lat_sign: float = 1.0 if dribble_system.get_dribble_hand() == DribbleSystem.DribbleHand.RIGHT else -1.0
					var vel_feint: Vector3 = fwd_m * (feint_fwd / feint_dur)
					var vanish_disp: Vector3 = -fwd_m * stepback_d + right_m * (lat_off * lat_sign)
					var vel_vanish: Vector3 = vanish_disp / vanish_dur
					ms_cut_dir = BallTrajectory.safe_normalize_xz(vanish_disp)
					dribble_system.steal_shield_timer = maxf(dribble_system.steal_shield_timer, total_dur + 0.12)
					dribble_system.grant_shot_bonus(shot_win_bon, 1.05)
					dribble_system.start_signature_two_stage(move_id, feint_dur, vel_feint, total_dur, vel_vanish)

				if animator != null:
					animator.trigger_action(&"mirror_step", total_dur + 0.08, get_dribble_hand() == 1)
				_evaluate_defender_momentum_misreads(move_id, ms_cut_dir, is_perfect, is_zone_ex)
				EventBus.dribble_move_performed.emit(player_id, move_id, global_position)

			_:
				if move_def.has("direction") and move_def["direction"] is Vector3:
					var custom_dir: Vector3 = move_def["direction"]
					var flat := Vector3(custom_dir.x, 0.0, custom_dir.z)
					if flat.length_squared() > 0.0001:
						var d: Vector3 = flat.normalized()
						var b_spd: float = float(move_def.get("burst_speed", 9.8)) * perf_mult * stam_mult * zone_mult
						_combo_burst_vel = d * b_spd
						_combo_burst_timer = maxf(0.10, float(move_def.get("duration", 0.22)))
						velocity.x = _combo_burst_vel.x
						velocity.z = _combo_burst_vel.z
						if dribble_system != null:
							dribble_system.swap_hand()
						EventBus.dribble_move_performed.emit(player_id, move_id, global_position)
				elif dribble_system != null:
					if not dribble_system.execute_move(move_id, player_id, stam_mult * zone_mult, is_perfect):
						return false
					if (
						move_id == DribbleSystem.MOVE_CROSSOVER
						or move_id == "crossover_q"
						or move_id == "crossover_e"
						or move_id == DribbleSystem.MOVE_HESITATION
						or move_id == DribbleSystem.MOVE_STEPBACK
					):
						_evaluate_defender_momentum_misreads(
							move_id,
							dribble_system.get_last_cut_direction(),
							is_perfect,
							is_zone_ex
						)

				var ankle_radius: float = float(move_def.get("ankle_break_radius", 2.2 if (is_perfect and is_signature_special) else 0.0))
				if ankle_radius > 0.05:
					_apply_cone_ankle_breaker(ankle_radius, 110.0 * perf_mult * ankle_break_mult)

	# Zone meter gain (ZoneComponent.add_charge strictly ignores gain when zone.is_active == true!)
	if zone != null and not zone.is_active:
		var z_gain: float = 0.0
		if move_def.has("zone_gain"):
			z_gain = float(move_def["zone_gain"])
		elif db_move != null:
			z_gain = db_move.zone_gain + (ComboEngine.PERFECT_BONUS_ZONE if is_perfect else 0.0)
		else:
			z_gain = 10.0 if is_perfect else 6.0
		zone.add_charge(z_gain)

	if not from_combo_engine:
		EventBus.combo_triggered.emit(player_id, move_id, tier, is_perfect)
	return true


func _execute_archetype_skill_plan(
	move_id: String,
	plan: Dictionary,
	ball: Basketball,
	potency_mult: float
) -> bool:
	var kind: String = str(plan.get("kind", ""))
	if plan.has("face_target") and plan["face_target"] is Vector3:
		_face_position_xz(plan["face_target"])

	match kind:
		"two_stage_dash":
			var dur: float = float(plan.get("duration", 0.24))
			var split_t: float = float(plan.get("split_time", dur * 0.45))
			var v1: Vector3 = plan.get("stage1_vel", Vector3.ZERO)
			var v2: Vector3 = plan.get("stage2_vel", v1)
			var phase_dur: float = float(plan.get("phase_duration", 0.0))
			if phase_dur > 0.0:
				_enable_phantom_phase(phase_dur)
			if dribble_system != null:
				if bool(plan.get("swap_hand", true)):
					dribble_system.swap_hand()
				var shield_dur: float = float(plan.get("steal_shield_duration", 0.0))
				if shield_dur > 0.0:
					dribble_system.steal_shield_timer = maxf(dribble_system.steal_shield_timer, shield_dur)
				dribble_system.start_signature_two_stage(move_id, split_t, v1, dur, v2)
			if animator != null:
				animator.trigger_action(&"volt_dash", dur + 0.08, get_dribble_hand() == 1)
			EventBus.dribble_move_performed.emit(player_id, move_id, global_position)
			return true

		"high_arc_shot":
			if shooting_system == null or ball == null or ball.carrier != self:
				return false
			var fade_dur: float = float(plan.get("fade_duration", 0.16))
			var fade_vel: Vector3 = plan.get("fade_vel", Vector3.ZERO)
			_combo_burst_vel = fade_vel
			_combo_burst_timer = fade_dur
			if not shooting_system.execute_starlight_high_arc(ball, plan, player_id, team_id):
				return false
			EventBus.dribble_move_performed.emit(player_id, move_id, global_position)
			return true

		"laser_pass":
			if shooting_system == null or ball == null or ball.carrier != self:
				return false
			if not shooting_system.execute_mirage_laser_pass(ball, plan, player_id, team_id):
				return false
			EventBus.dribble_move_performed.emit(player_id, move_id, global_position)
			return true

		"solo_dash":
			var s_dur: float = float(plan.get("duration", 0.26))
			var s_vel: Vector3 = plan.get("dash_vel", Vector3.ZERO)
			if dribble_system != null:
				if bool(plan.get("swap_hand", true)):
					dribble_system.swap_hand()
				dribble_system.steal_shield_timer = maxf(dribble_system.steal_shield_timer, float(plan.get("steal_shield_duration", 0.42)))
				dribble_system.start_signature_trajectory(move_id, s_dur, s_vel)
			if animator != null:
				animator.trigger_action(&"mirage_thread", s_dur + 0.08, get_dribble_hand() == 1)
			EventBus.dribble_move_performed.emit(player_id, move_id, global_position)
			return true

		"armored_dunk":
			if shooting_system == null or ball == null or ball.carrier != self:
				return false
			var d_params: Dictionary = (plan.get("dunk_params", {}) as Dictionary).duplicate(true)
			d_params["is_zone_ex"] = bool(plan.get("is_zone_ex", false))
			var target_rim: Vector3 = plan.get("face_target", _get_target_rim_position())
			_enable_phantom_phase(float(plan.get("dunk_duration_sec", 0.40)) + 0.06)
			if not shooting_system.begin_meteor_dunk(ball, target_rim, player_id, team_id, d_params, potency_mult):
				return false
			EventBus.dribble_move_performed.emit(player_id, move_id, global_position)
			return true

		"offense_counter":
			var o_dur: float = float(plan.get("duration", 0.28))
			var o_vel: Vector3 = plan.get("dash_vel", Vector3.ZERO)
			if dribble_system != null:
				if bool(plan.get("swap_hand", true)):
					dribble_system.swap_hand()
				dribble_system.steal_shield_timer = maxf(dribble_system.steal_shield_timer, float(plan.get("steal_shield_duration", 0.45)))
				dribble_system.grant_shot_bonus(float(plan.get("shot_bonus", 0.12)), float(plan.get("shot_bonus_duration", 0.90)))
				dribble_system.start_signature_trajectory(move_id, o_dur, o_vel)
			if animator != null:
				animator.trigger_action(&"eclipse_counter", o_dur + 0.08, get_dribble_hand() == 1)
			EventBus.dribble_move_performed.emit(player_id, move_id, global_position)
			return true

		"defense_counter":
			var d_dur: float = float(plan.get("duration", 0.24))
			var c_vel: Vector3 = plan.get("closeout_vel", Vector3.ZERO)
			_combo_burst_vel = c_vel
			_combo_burst_timer = d_dur
			velocity.x = c_vel.x
			velocity.z = c_vel.z
			if defense_system != null:
				defense_system.grant_defense_buff(
					float(plan.get("steal_radius_bonus", 0.65)),
					float(plan.get("contest_bonus", 0.30)),
					float(plan.get("window_duration", 0.90))
				)
			if animator != null:
				animator.trigger_action(&"eclipse_counter", d_dur + 0.08, true)
			EventBus.dribble_move_performed.emit(player_id, move_id, global_position)
			return true

	return false


func export_sim_state() -> Dictionary:
	return {
		"player_id": player_id,
		"team_id": team_id,
		"archetype_id": archetype_id,
		"position": global_position,
		"velocity": velocity,
		"facing_yaw": facing_yaw,
		"aim_yaw": aim_yaw,
		"balance": balance,
		"momentum_vec": momentum_vec,
		"ankle_break_frames_left": ankle_break_frames_left,
		"input_seq": _input_seq,
		"local_tick_counter": _local_tick_counter,
		"prev_buttons": _prev_buttons,
		"is_sprinting": _is_sprinting,
		"in_defensive_stance": _in_defensive_stance,
		"was_on_floor": _was_on_floor,
		"landing_frames_left": _landing_frames_left,
		"ankle_broken_stun": _ankle_broken_stun,
		"strip_flinch_timer": _strip_flinch_timer,
		"phantom_phase_timer": _phantom_phase_timer,
		"combo_burst_vel": _combo_burst_vel,
		"combo_burst_timer": _combo_burst_timer,
		"anim_state": String(animator.get_current_state()) if animator != null else "idle",
		"dribble_hand": int(dribble_system.get_dribble_hand()) if dribble_system != null else 1,
		"dribble": dribble_system.export_state() if dribble_system != null else {},
		"shooting": shooting_system.export_state() if shooting_system != null else {},
		"defense": defense_system.export_state() if defense_system != null else {},
		"stamina": stamina.export_state() if stamina != null else {},
		"zone": zone.export_state() if zone != null else {},
		"combo": combo_engine.export_state() if combo_engine != null else {},
		"ai": _export_optional_ai_state(),
	}


func import_sim_state(state: Dictionary) -> void:
	global_position = state.get("position", global_position)
	velocity = state.get("velocity", velocity)
	facing_yaw = float(state.get("facing_yaw", facing_yaw))
	aim_yaw = float(state.get("aim_yaw", aim_yaw))
	balance = clampf(float(state.get("balance", max_balance)), 0.0, max_balance)
	momentum_vec = state.get("momentum_vec", Vector2.ZERO) if state.get("momentum_vec") is Vector2 else Vector2.ZERO
	_input_seq = int(state.get("input_seq", _input_seq))
	_local_tick_counter = int(state.get("local_tick_counter", _local_tick_counter))
	_prev_buttons = int(state.get("prev_buttons", _prev_buttons))
	_is_sprinting = bool(state.get("is_sprinting", false))
	_in_defensive_stance = bool(state.get("in_defensive_stance", false))
	_was_on_floor = bool(state.get("was_on_floor", true))
	_landing_frames_left = int(state.get("landing_frames_left", 0))
	_ankle_broken_stun = float(state.get("ankle_broken_stun", 0.0))
	if state.has("ankle_break_frames_left"):
		ankle_break_frames_left = int(state["ankle_break_frames_left"])
	else:
		ankle_break_frames_left = int(roundf(_ankle_broken_stun * 60.0))
	_strip_flinch_timer = float(state.get("strip_flinch_timer", 0.0))
	_phantom_phase_timer = float(state.get("phantom_phase_timer", 0.0))
	_update_phantom_collision_layers()
	_combo_burst_vel = state.get("combo_burst_vel", Vector3.ZERO)
	_combo_burst_timer = float(state.get("combo_burst_timer", 0.0))

	if animator != null:
		animator.rotation.y = facing_yaw
		if state.has("anim_state"):
			animator.set_locomotion_state(StringName(str(state["anim_state"])))
	if camera_rig != null and _external_input_provider == null and is_local_human:
		camera_rig.set_yaw(aim_yaw)
	if dribble_system != null:
		if state.has("dribble") and state["dribble"] is Dictionary and not (state["dribble"] as Dictionary).is_empty():
			dribble_system.import_state(state["dribble"])
		elif state.has("dribble_hand"):
			dribble_system.set_dribble_hand(int(state["dribble_hand"]))
	if shooting_system != null and state.has("shooting") and state["shooting"] is Dictionary:
		shooting_system.import_state(state["shooting"])
	if defense_system != null and state.has("defense") and state["defense"] is Dictionary:
		defense_system.import_state(state["defense"])
	if stamina != null and state.has("stamina") and state["stamina"] is Dictionary:
		stamina.import_state(state["stamina"])
	if zone != null and state.has("zone") and state["zone"] is Dictionary:
		zone.import_state(state["zone"])
	if combo_engine != null and state.has("combo") and state["combo"] is Dictionary:
		combo_engine.import_state(state["combo"])
	if state.has("ai") and state["ai"] is Dictionary and not (state["ai"] as Dictionary).is_empty():
		_import_optional_ai_state(state["ai"])
	if stamina != null:
		stamina.set_cost_multiplier(get_stamina_cost_multiplier())


# ==============================================================================
# Core 60 Hz Simulation Step
# ==============================================================================

func _physics_process(delta: float) -> void:
	var dt: float = 1.0 / 60.0
	if delta > 0.0 and delta <= 0.05:
		dt = delta

	var frame: Dictionary = _acquire_input_frame(GameState.current_tick, dt)
	step_with_input(frame, dt)


func step_with_input(frame: Dictionary, dt: float = 1.0 / 60.0) -> void:
	_local_tick_counter += 1
	_prune_old_normal_spends()

	var buttons: int = int(frame.get("buttons", 0))
	var just_pressed: int = buttons & (~_prev_buttons)
	aim_yaw = float(frame.get("aim_yaw", aim_yaw))

	var local_dir: Vector2 = frame.get("local_dir", Vector2.ZERO) if frame.get("local_dir") is Vector2 else Vector2.ZERO
	var move_xz: Vector2 = _resolve_world_move_xz(frame)
	var ball: Basketball = _find_basketball()
	var carrying_ball: bool = (ball != null and ball.carrier == self)

	if _phantom_phase_timer > 0.0:
		_phantom_phase_timer = maxf(0.0, _phantom_phase_timer - dt)
		_update_phantom_collision_layers()

	if dribble_system != null:
		dribble_system.step_timers(dt)
	if defense_system != null:
		defense_system.step_pre_move_frames()
	if _back_tap_timer > 0.0:
		_back_tap_timer = maxf(0.0, _back_tap_timer - dt)

	var holding_back_now: bool = local_dir.y < -0.55
	var double_tapped_back: bool = false
	if holding_back_now and not _was_holding_back:
		if _back_tap_timer > 0.0:
			double_tapped_back = true
			_back_tap_timer = 0.0
		else:
			_back_tap_timer = 0.28
	_was_holding_back = holding_back_now

	if ankle_break_frames_left > 0:
		move_xz = Vector2.ZERO
		ankle_break_frames_left -= 1
		_ankle_broken_stun = float(ankle_break_frames_left) / 60.0
		if ankle_break_frames_left <= 0:
			_ankle_broken_stun = 0.0
			balance = max_balance
	elif _ankle_broken_stun > 0.0:
		_ankle_broken_stun = maxf(0.0, _ankle_broken_stun - dt)
		move_xz = Vector2.ZERO
		if _ankle_broken_stun <= 0.0:
			balance = max_balance
	else:
		balance = minf(max_balance, balance + 24.0 * dt)

	if _strip_flinch_timer > 0.0:
		_strip_flinch_timer = maxf(0.0, _strip_flinch_timer - dt)
		move_xz = Vector2.ZERO

	var is_stunned_now: bool = ankle_break_frames_left > 0 or _ankle_broken_stun > 0.0 or _strip_flinch_timer > 0.0
	var grounded_pre: bool = is_on_floor() or (global_position.y <= 0.03 and absf(velocity.y) <= 0.05 and _was_on_floor)

	# Zone activation check (V / BTN_ZONE) & 60 Hz drain step
	if (just_pressed & BTN_ZONE) != 0 and zone != null:
		zone.activate_zone()
	if zone != null:
		zone.step_zone(dt)

	# Sync Stamina cost multiplier with Zone state (0.75x in Zone, 1.0x baseline)
	if stamina != null:
		stamina.set_cost_multiplier(get_stamina_cost_multiplier())

	# ==========================================================================
	# 1. Step 60 Hz ComboEngine FIRST (runs BOTH on-ball AND off-ball!)
	# ==========================================================================
	var suppress_default_actions: bool = false
	if combo_engine != null and not is_stunned_now:
		var target_rim_pre: Vector3 = _get_target_rim_position()
		var dist_to_rim_xz: float = Vector2(
			global_position.x - target_rim_pre.x,
			global_position.z - target_rim_pre.z
		).length()
		var avail_stamina: float = (
			(stamina.current_stamina + _sum_recent_normal_spends())
			if stamina != null
			else 100.0
		)
		var combo_res: Dictionary = combo_engine.step_frame(frame, {
			"has_ball": carrying_ball,
			"stamina": avail_stamina,
			"dist_to_rim": dist_to_rim_xz,
			"is_grounded": grounded_pre,
			"is_zone_active": is_in_zone(),
			"archetype_id": archetype_id,
		})
		if bool(combo_res.get("triggered", false)):
			var triggered_ok: bool = execute_combo_move(
				combo_res["move_def"],
				bool(combo_res.get("is_perfect", false))
			)
			if triggered_ok and bool(combo_res.get("suppress_default_action", true)):
				suppress_default_actions = true
				carrying_ball = (ball != null and ball.carrier == self)

	# 2. Normal Dribble Skill Inputs
	if (
		not suppress_default_actions
		and carrying_ball
		and (shooting_system == null or (not shooting_system.is_charging_shot and not shooting_system.is_dunking))
	):
		_process_dribble_skill_inputs(just_pressed, local_dir, double_tapped_back)

	# Movement speed, Defensive Stance (C / off-ball RMB), Whiff/Block Recovery & Zone +15% modifier
	var whiff_locked: bool = defense_system != null and defense_system.is_in_steal_whiff_recovery()
	var def_actions_locked: bool = (not carrying_ball) and defense_system != null and defense_system.are_defensive_actions_locked()
	var wants_stance: bool = (
		(not carrying_ball)
		and (((buttons & BTN_STANCE) != 0) or ((buttons & BTN_PASS) != 0))
	)
	_in_defensive_stance = wants_stance and (not whiff_locked) and (not is_stunned_now) and (not suppress_default_actions)
	if defense_system != null:
		defense_system.set_in_stance(_in_defensive_stance)

	var wants_sprint: bool = ((buttons & BTN_SPRINT) != 0) and (move_xz.length_squared() > 0.01)
	_is_sprinting = (
		wants_sprint
		and (not _in_defensive_stance)
		and (not whiff_locked)
		and (not is_stunned_now)
		and (stamina == null or stamina.can_sprint())
	)

	if stamina != null:
		stamina.step_stamina(dt, _is_sprinting and grounded_pre)

	var zone_speed_mult: float = zone.get_speed_multiplier() if zone != null else 1.0
	var stam_speed_mult: float = stamina.get_speed_multiplier() if stamina != null else 1.0
	var def_rec_speed_mult: float = (
		defense_system.get_movement_speed_multiplier()
		if (defense_system != null and not carrying_ball)
		else 1.0
	)

	var target_speed: float = run_speed
	if _is_sprinting:
		target_speed = sprint_speed * stam_speed_mult
	elif _in_defensive_stance:
		target_speed = stance_speed
	elif carrying_ball and stamina != null and stamina.is_exhausted():
		target_speed = run_speed * stam_speed_mult
	target_speed *= zone_speed_mult * def_rec_speed_mult

	if _landing_frames_left > 0 and not _in_defensive_stance:
		target_speed *= 0.78

	var locked_in_dunk: bool = (shooting_system != null and shooting_system.is_dunking)
	if not locked_in_dunk:
		if _combo_burst_timer > 0.0:
			_combo_burst_timer = maxf(0.0, _combo_burst_timer - dt)
			velocity.x = _combo_burst_vel.x
			velocity.z = _combo_burst_vel.z
		elif dribble_system != null and dribble_system.is_move_active():
			var m_vel: Vector3 = dribble_system.get_active_move_velocity()
			velocity.x = m_vel.x
			velocity.z = m_vel.z
		else:
			var target_vel_xz: Vector2 = move_xz * target_speed
			var cur_vel_xz := Vector2(velocity.x, velocity.z)
			var lat_accel_mult: float = (
				defense_system.get_lateral_accel_multiplier()
				if (defense_system != null and _in_defensive_stance)
				else 1.0
			)
			var ground_accel: float = acceleration * lat_accel_mult
			if _in_defensive_stance and move_xz.length_squared() > 0.001 and cur_vel_xz.dot(target_vel_xz) < 0.0:
				ground_accel = maxf(acceleration, deceleration) * lat_accel_mult
			var accel_rate: float = (
				(ground_accel if move_xz.length_squared() > 0.001 else deceleration * lat_accel_mult)
				if grounded_pre
				else air_acceleration
			)
			cur_vel_xz = cur_vel_xz.move_toward(target_vel_xz, accel_rate * dt)
			velocity.x = cur_vel_xz.x
			velocity.z = cur_vel_xz.y

	# Jumping / Vertical Block Jump (+20% velocity in Zone) & gravity
	var just_jumped: bool = false
	var on_floor_now: bool = grounded_pre
	if not locked_in_dunk:
		if on_floor_now:
			if velocity.y < 0.0:
				velocity.y = -0.1
			var wants_offball_block_jump: bool = (not carrying_ball) and ((just_pressed & BTN_SHOOT) != 0)
			var wants_jump_btn: bool = ((just_pressed & BTN_JUMP) != 0) or wants_offball_block_jump
			if (
				(not suppress_default_actions)
				and wants_jump_btn
				and (not is_stunned_now)
				and (not def_actions_locked)
			):
				velocity.y = get_effective_jump_velocity()
				_landing_frames_left = 0
				on_floor_now = false
				just_jumped = true
				if not carrying_ball:
					if defense_system != null:
						defense_system.on_defensive_jump_started()
					if wants_offball_block_jump and animator != null:
						animator.trigger_action(&"block", 0.34)
				if stamina != null:
					var pre_jump_stam: float = stamina.current_stamina
					stamina.consume(StaminaComponent.COST_JUMP, true)
					if carrying_ball:
						_record_normal_stamina_spend(pre_jump_stam - stamina.current_stamina)
		else:
			velocity.y -= gravity * dt

	# Step active shooting / dunking / passing
	if carrying_ball and not suppress_default_actions:
		if ((just_pressed & BTN_PASS) != 0) and shooting_system != null:
			shooting_system.execute_pass(ball, player_id, team_id, _get_aim_forward_xz())
			carrying_ball = false
		elif ((just_pressed & BTN_SHOOT) != 0) and shooting_system != null:
			var extra_cancel: int = _get_total_extra_cancel_frames()
			var can_shoot_now: bool = combo_engine == null or combo_engine.can_cancel_into_shot(extra_cancel)
			if can_shoot_now:
				if dribble_system != null and dribble_system.is_move_active():
					dribble_system.cancel_active_move()
				var target_rim: Vector3 = _get_target_rim_position()
				_face_position_xz(target_rim)
				var sprint_dunk_intent: bool = _is_sprinting or ((buttons & BTN_SPRINT) != 0)
				shooting_system.begin_shot_or_dunk(ball, target_rim, player_id, team_id, sprint_dunk_intent)

	if shooting_system != null:
		var z_bonus: float = zone.get_shot_quality_bonus() if zone != null else 0.0
		var c_bonus: float = combo_engine.get_active_shot_bonus() if combo_engine != null else 0.0
		var released: bool = shooting_system.step_shooting(
			dt,
			(buttons & BTN_SHOOT) != 0,
			ball,
			player_id,
			team_id,
			z_bonus,
			c_bonus
		)
		if released:
			carrying_ball = false

	if _reset_bvh_guard_ticks > 0 and _phantom_phase_timer <= 0.0:
		collision_mask = 1
	move_and_slide()
	if _reset_bvh_guard_ticks > 0:
		_reset_bvh_guard_ticks -= 1
		if _reset_bvh_guard_ticks <= 0:
			_update_phantom_collision_layers()

	# Track 60 Hz directional momentum inertia with decay
	var post_vel_xz := Vector2(velocity.x, velocity.z)
	if ankle_break_frames_left > 0 or _ankle_broken_stun > 0.0:
		momentum_vec = momentum_vec.move_toward(Vector2.ZERO, 26.0 * dt)
	elif post_vel_xz.length_squared() > 0.01 and post_vel_xz.length() >= momentum_vec.length():
		var build_rate: float = 28.0 if _is_sprinting else 22.0
		momentum_vec = momentum_vec.move_toward(post_vel_xz, build_rate * dt)
	else:
		var decay_rate: float = 32.0 if _in_defensive_stance else 18.0
		momentum_vec = momentum_vec.move_toward(post_vel_xz, decay_rate * dt)

	var grounded_after: bool = is_on_floor()
	if grounded_after and not _was_on_floor:
		_landing_frames_left = LANDING_RECOVERY_TICKS
		if defense_system != null:
			defense_system.on_landed_check_block_recovery()
	elif grounded_after and _landing_frames_left > 0:
		_landing_frames_left -= 1
	elif not grounded_after:
		_landing_frames_left = 0
	_was_on_floor = grounded_after

	_update_facing(dt, move_xz, carrying_ball, ball)

	var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
	if grounded_after and horiz_speed > 1.2:
		_footstep_accum += horiz_speed * dt
		var stride: float = 2.15 if _is_sprinting else 1.75
		if _footstep_accum >= stride:
			_footstep_accum = 0.0
			EventBus.player_footstep.emit(player_id, global_position, _is_sprinting)
	else:
		_footstep_accum = 0.0

	carrying_ball = (ball != null and ball.carrier == self)
	if carrying_ball and dribble_system != null:
		dribble_system.step_dribble(dt, ball, horiz_speed, grounded_after, _is_sprinting, player_id, team_id)
	elif not carrying_ball and defense_system != null and not suppress_default_actions:
		var steal_btn: bool = ((just_pressed & BTN_STEAL) != 0) and (not is_stunned_now)
		var loose_pickup_e: bool = ((just_pressed & BTN_SKILL_E) != 0) and (not is_stunned_now)
		var block_pressed: bool = (((just_pressed & BTN_SHOOT) != 0) or ((just_pressed & BTN_JUMP) != 0)) and (not is_stunned_now)
		var def_res: String = defense_system.step_defense(
			dt,
			ball,
			false,
			steal_btn,
			just_jumped,
			block_pressed,
			player_id,
			team_id,
			loose_pickup_e,
			is_in_zone(),
			_get_defended_rim_position()
		)
		if zone != null and not zone.is_active:
			if def_res == "stole_ball" or def_res == "intercepted_pass":
				zone.award_positive_play("steal")
			elif def_res == "blocked_shot":
				zone.award_positive_play("block")
			elif def_res == "rebounded":
				zone.add_charge(10.0)

	# Drive Phase 12 3D RibbonTrail3D + CinematicDirector anime speed lines
	_step_phase12_player_vfx(horiz_speed)

	# Drive Dramatic Zone Camera FOV + Dutch-angle lateral roll
	if camera_rig != null:
		var cam_right: Vector3 = camera_rig.get_right_xz()
		var lat_spd: float = velocity.x * cam_right.x + velocity.z * cam_right.z
		camera_rig.set_zone_mode(is_in_zone(), lat_spd)

	_update_animation_state(grounded_after, horiz_speed, move_xz)

	_prev_buttons = buttons
	if combo_engine == null:
		EventBus.input_recorded.emit(player_id, frame)


func _get_total_extra_cancel_frames() -> int:
	var extra: int = cancel_window_bonus
	if is_in_zone():
		extra += ComboEngine.ZONE_EXTRA_CANCEL_FRAMES
	return extra


func _process_dribble_skill_inputs(just_pressed: int, local_dir: Vector2, double_tapped_back: bool) -> void:
	if dribble_system == null:
		return

	var q_pressed: bool = (just_pressed & BTN_SKILL_Q) != 0
	var e_pressed: bool = (just_pressed & BTN_SKILL_E) != 0
	var r_pressed: bool = (just_pressed & BTN_SKILL_R) != 0
	var chosen_move: String = ""

	if q_pressed or e_pressed:
		var target_hand: int = DribbleSystem.DribbleHand.LEFT if q_pressed else DribbleSystem.DribbleHand.RIGHT
		if local_dir.y < -0.25:
			chosen_move = DribbleSystem.MOVE_BEHIND_THE_BACK
		elif target_hand != int(dribble_system.get_dribble_hand()):
			chosen_move = DribbleSystem.MOVE_CROSSOVER
		else:
			chosen_move = DribbleSystem.MOVE_HESITATION
	elif r_pressed:
		if local_dir.y < -0.20:
			chosen_move = DribbleSystem.MOVE_STEPBACK
		else:
			chosen_move = DribbleSystem.MOVE_SPIN
	elif double_tapped_back:
		chosen_move = DribbleSystem.MOVE_STEPBACK

	if chosen_move.is_empty():
		return

	var extra_cancel: int = _get_total_extra_cancel_frames()
	if combo_engine != null and not combo_engine.can_start_normal_move(chosen_move, extra_cancel):
		return

	if execute_combo_move({"id": chosen_move, "tier": 1}, false):
		if combo_engine != null:
			combo_engine.notify_normal_move(chosen_move, extra_cancel)


func has_ball() -> bool:
	var ball: Basketball = _find_basketball()
	return ball != null and ball.carrier == self


func is_in_defensive_stance() -> bool:
	return _in_defensive_stance


func is_ankle_broken() -> bool:
	return ankle_break_frames_left > 0 or _ankle_broken_stun > 0.0


func is_phantom_phasing() -> bool:
	return _phantom_phase_timer > 0.0


func is_armored() -> bool:
	return shooting_system != null and shooting_system.is_armored_dunk


func get_dribble_hand() -> int:
	return int(dribble_system.get_dribble_hand()) if dribble_system != null else 1


func get_active_hand_world_position() -> Vector3:
	if dribble_system != null:
		return dribble_system.get_active_hand_world_position()
	return global_position + Vector3(0.28, 1.05, -0.24)


func has_steal_protection() -> bool:
	return (
		(dribble_system != null and dribble_system.has_steal_protection())
		or _phantom_phase_timer > 0.0
		or is_armored()
	)


func compute_current_shot_contest() -> float:
	return DefenseSystem.compute_shot_contest(self, _get_target_rim_position())


func try_pass_lane_interception(ball: Basketball) -> bool:
	if defense_system == null or has_ball():
		return false
	var caught: bool = defense_system.try_intercept_pass(ball, player_id, team_id, is_in_zone())
	if caught and zone != null and not zone.is_active:
		zone.award_positive_play("steal")
	return caught


func on_ball_stolen() -> void:
	if is_armored():
		return
	if shooting_system != null:
		shooting_system.cancel_actions()
	_strip_flinch_timer = 0.22


func apply_balance_damage(amount: float, attacker_id: int, stumble_dir: Vector3 = Vector3.ZERO) -> bool:
	if amount <= 0.0 or is_armored():
		return false
	var mitigated: float = amount / get_effective_balance_resistance()
	balance = maxf(0.0, balance - mitigated)
	if balance <= 0.0:
		apply_ankle_break_stun(attacker_id, ANKLE_BREAK_DURATION_SEC, stumble_dir)
		return true
	return false


func apply_ankle_break_stun(
	attacker_id: int,
	stun_sec: float = ANKLE_BREAK_DURATION_SEC,
	stumble_dir: Vector3 = Vector3.ZERO
) -> void:
	if is_armored():
		return
	var was_already_broken: bool = is_ankle_broken()
	var target_frames: int = maxi(1, int(roundf(stun_sec * 60.0)))
	ankle_break_frames_left = maxi(ankle_break_frames_left, target_frames)
	_ankle_broken_stun = float(ankle_break_frames_left) / 60.0
	balance = 0.0
	_in_defensive_stance = false
	_is_sprinting = false
	if defense_system != null:
		defense_system.cancel_on_stun()

	if stumble_dir.length_squared() > 0.0001:
		var sd: Vector3 = BallTrajectory.safe_normalize_xz(stumble_dir)
		velocity.x = sd.x * 4.2
		velocity.z = sd.z * 4.2
	else:
		velocity.x *= 0.2
		velocity.z *= 0.2

	if animator != null:
		animator.set_locomotion_state(&"ankle_stumble")
		animator.trigger_action(&"ankle_stumble", stun_sec)

	# Credit attacker +20.0 Zone energy for inflicting an ankle break (strictly 0 if attacker is in Zone)
	if not was_already_broken and attacker_id >= 0 and get_tree() != null:
		for node in get_tree().get_nodes_in_group("players"):
			if node is PlayerController and (node as PlayerController).player_id == attacker_id:
				var atk := node as PlayerController
				if atk.zone != null:
					atk.zone.award_positive_play("ankle_break")
				break

	EventBus.ankle_broken.emit(player_id, attacker_id, global_position)


func trigger_dunk_shockwave(
	rim_pos: Vector3,
	radius: float,
	power: float,
	custom_balance_damage: float = -1.0
) -> void:
	var tree := get_tree()
	if tree == null or radius <= 0.05:
		return
	var r_sq: float = radius * radius
	var dmg: float = custom_balance_damage if custom_balance_damage >= 0.0 else (65.0 * power)
	for node in tree.get_nodes_in_group("players"):
		if node == self or not (node is PlayerController):
			continue
		var defender := node as PlayerController
		if defender.team_id == team_id:
			continue
		var dx: float = defender.global_position.x - rim_pos.x
		var dz: float = defender.global_position.z - rim_pos.z
		if (dx * dx + dz * dz) <= r_sq:
			var push_dir: Vector3 = BallTrajectory.safe_normalize_xz(Vector3(dx, 0.0, dz))
			defender.velocity.x = push_dir.x * (6.2 * power)
			defender.velocity.z = push_dir.z * (6.2 * power)
			defender.apply_balance_damage(dmg, player_id, push_dir)


func reset_for_match(spawn_xform: Transform3D = _spawn_transform) -> void:
	if shooting_system != null:
		shooting_system.cancel_actions()
	if dribble_system != null:
		dribble_system.reset_dribble()
	if defense_system != null:
		defense_system.reset_defense()
	if combo_engine != null:
		combo_engine.reset()
		combo_engine.set_extra_cancel_frames(cancel_window_bonus)
	var ai_node: Node = get_node_or_null("AIController")
	if ai_node != null and ai_node.has_method("reset"):
		ai_node.call("reset")

	global_transform = spawn_xform
	force_update_transform()
	velocity = Vector3.ZERO
	momentum_vec = Vector2.ZERO
	balance = max_balance
	ankle_break_frames_left = 0
	last_executed_was_ex = false
	_input_seq = 0
	_local_tick_counter = 0
	_footstep_accum = 0.0
	_prev_buttons = 0
	_is_sprinting = false
	_in_defensive_stance = false
	_landing_frames_left = 0
	_ankle_broken_stun = 0.0
	_strip_flinch_timer = 0.0
	_phantom_phase_timer = 0.0
	_reset_bvh_guard_ticks = 1
	_update_phantom_collision_layers()
	_combo_burst_timer = 0.0
	_combo_burst_vel = Vector3.ZERO
	_back_tap_timer = 0.0
	_was_holding_back = false
	_recent_normal_spends.clear()
	_was_on_floor = spawn_xform.origin.y <= 0.06

	var fwd: Vector3 = -spawn_xform.basis.z
	if Vector2(fwd.x, fwd.z).length_squared() > 0.0001:
		facing_yaw = atan2(-fwd.x, -fwd.z)
		aim_yaw = facing_yaw
	if animator != null:
		animator.rotation.y = facing_yaw
		animator.reset_animator()
	if zone != null:
		zone.reset_zone()
	if stamina != null:
		stamina.reset_stamina()
	if camera_rig != null:
		camera_rig.reset_zone_camera()
		camera_rig.set_yaw(aim_yaw)
	if ribbon_trail != null and is_instance_valid(ribbon_trail):
		ribbon_trail.set_emitting(false)
		ribbon_trail.clear_trail()
	_set_local_speed_lines_intensity(0.0)


func _step_phase12_player_vfx(horiz_speed: float) -> void:
	if not _trail_registered_with_vfx:
		_ensure_optional_ribbon_trail()

	var is_dashing_or_dunking: bool = (
		_phantom_phase_timer > 0.0
		or _combo_burst_timer > 0.0
		or (shooting_system != null and shooting_system.is_dunking)
	)
	var is_dribble_burst: bool = dribble_system != null and dribble_system.is_move_active()
	var trail_active: bool = is_in_zone() or _is_sprinting or is_dashing_or_dunking or is_dribble_burst or horiz_speed > 7.2

	if ribbon_trail != null and is_instance_valid(ribbon_trail):
		ribbon_trail.set_emitting(trail_active)
		if trail_active:
			ribbon_trail.sample_point(global_position + Vector3(0.0, 0.92, 0.0), 0.0)

	if is_local_human or (GameState != null and player_id == GameState.local_player_id):
		var sl_val: float = 0.0
		if _phantom_phase_timer > 0.0 or (shooting_system != null and shooting_system.is_dunking):
			sl_val = 0.78
		elif is_in_zone() and horiz_speed > 4.5:
			sl_val = 0.52
		elif _is_sprinting and horiz_speed > 7.2:
			sl_val = 0.34
		_set_local_speed_lines_intensity(sl_val)


func _set_local_speed_lines_intensity(val: float) -> void:
	if not is_inside_tree() or get_tree() == null:
		return
	var vfx := get_tree().get_first_node_in_group("vfx_manager") as VFXManager
	if vfx != null:
		var cine: CinematicDirector = vfx.get_cinematic_director()
		if cine != null:
			cine.set_speed_lines_intensity(val)


func get_animation_state() -> StringName:
	if animator != null:
		return animator.get_current_state()
	return &"idle"


func _enable_phantom_phase(duration: float) -> void:
	_phantom_phase_timer = maxf(_phantom_phase_timer, duration)
	_update_phantom_collision_layers()


func _update_phantom_collision_layers() -> void:
	if _phantom_phase_timer > 0.0:
		collision_layer = 0
		collision_mask = 1
	else:
		collision_layer = 2
		collision_mask = 1 | 2


func _record_normal_stamina_spend(amount: float) -> void:
	if amount <= 0.0:
		return
	_recent_normal_spends.append({
		"tick": _local_tick_counter,
		"amount": amount,
	})


func _prune_old_normal_spends() -> void:
	while not _recent_normal_spends.is_empty():
		var oldest: Dictionary = _recent_normal_spends[0]
		if (_local_tick_counter - int(oldest["tick"])) > 44:
			_recent_normal_spends.pop_front()
		else:
			break


func _sum_recent_normal_spends() -> float:
	var total: float = 0.0
	for entry in _recent_normal_spends:
		total += float(entry["amount"])
	return total


func _refund_kara_startup_stamina() -> void:
	if stamina == null or _recent_normal_spends.is_empty():
		_recent_normal_spends.clear()
		return
	var refund_total: float = _sum_recent_normal_spends()
	_recent_normal_spends.clear()
	stamina.set_stamina(stamina.current_stamina + refund_total)


func _apply_cone_ankle_breaker(
	cone_range: float,
	balance_dmg: float,
	cut_dir: Vector3 = Vector3.ZERO
) -> Dictionary:
	var hit_ids := {}
	var tree := get_tree()
	if tree == null or cone_range <= 0.05:
		return hit_ids
	var r_sq: float = cone_range * cone_range
	var fwd: Vector3 = _get_facing_forward_xz()
	var has_cut: bool = Vector2(cut_dir.x, cut_dir.z).length_squared() > 0.0001
	var opp_cut: Vector3 = -BallTrajectory.safe_normalize_xz(cut_dir) if has_cut else Vector3.ZERO

	for node in tree.get_nodes_in_group("players"):
		if node == self or not (node is PlayerController):
			continue
		var defender := node as PlayerController
		if defender.team_id == team_id:
			continue
		var delta := Vector3(
			defender.global_position.x - global_position.x,
			0.0,
			defender.global_position.z - global_position.z
		)
		var dist_sq: float = delta.length_squared()
		if dist_sq <= r_sq and dist_sq > 0.00001:
			var dir: Vector3 = delta.normalized()
			var dot_f: float = fwd.dot(dir)
			if dot_f >= -0.34 or dist_sq <= 2.56:
				var knock_dir: Vector3 = opp_cut if has_cut else dir
				defender.apply_balance_damage(balance_dmg, player_id, knock_dir)
				hit_ids[defender.player_id] = true
	return hit_ids


func _evaluate_defender_momentum_misreads(
	move_id: String,
	cut_dir_3d: Vector3,
	is_perfect: bool,
	is_zone_ex: bool,
	already_hit_ids: Dictionary = {}
) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var cut_xz := Vector2(cut_dir_3d.x, cut_dir_3d.z)
	if cut_xz.length_squared() <= 0.0001:
		return
	var cut_dir: Vector2 = cut_xz.normalized()
	var knock_dir := Vector3(-cut_dir.x, 0.0, -cut_dir.y)
	var target_rim: Vector3 = _get_target_rim_position()
	var max_range: float = 3.20 * (1.15 if is_zone_ex else 1.0)
	var max_range_sq: float = max_range * max_range

	var base_dmg: float = 118.0
	if move_id == MoveDatabase.MOVE_MIRROR_STEP:
		base_dmg = 130.0
	elif move_id == DribbleSystem.MOVE_STEPBACK:
		base_dmg = 122.0

	for node in tree.get_nodes_in_group("players"):
		if node == self or not (node is PlayerController):
			continue
		var defender := node as PlayerController
		if defender.team_id == team_id or already_hit_ids.has(defender.player_id):
			continue
		var dx: float = defender.global_position.x - global_position.x
		var dz: float = defender.global_position.z - global_position.z
		if (dx * dx + dz * dz) > max_range_sq:
			continue

		var def_mom: Vector2 = defender.momentum_vec
		var mom_speed: float = def_mom.length()
		if mom_speed <= 3.5:
			continue
		var mom_dir: Vector2 = def_mom / mom_speed
		var dot_align: float = cut_dir.dot(mom_dir)
		if dot_align >= -0.25:
			continue

		var oppose_strength: float = clampf(-dot_align, 0.25, 1.0)
		var pos_score: float = DefenseSystem.compute_defensive_positioning(defender, self, target_rim)
		var raw_dmg: float = 0.0
		if defender.is_in_defensive_stance():
			var stance_mom_factor: float = clampf(mom_speed / 6.2, 0.60, 1.0)
			var pos_protection: float = 1.0 + 0.50 * pos_score
			raw_dmg = (base_dmg + 38.0 * oppose_strength) * stance_mom_factor * 0.48 * ankle_break_mult / pos_protection
		else:
			var sprint_mom_factor: float = clampf(0.84 + (mom_speed - 3.5) * 0.12, 0.84, 1.45)
			var light_pos_prot: float = 1.0 + 0.12 * pos_score
			raw_dmg = (base_dmg + 38.0 * oppose_strength) * sprint_mom_factor * ankle_break_mult * (1.15 if is_perfect else 1.0) / light_pos_prot

		defender.apply_balance_damage(raw_dmg, player_id, knock_dir)


func _update_animation_state(grounded: bool, horiz_speed: float, move_xz: Vector2) -> void:
	if animator == null:
		return
	if is_ankle_broken():
		animator.set_locomotion_state(&"ankle_stumble")
		return
	if not grounded:
		if velocity.y > 0.25:
			animator.set_locomotion_state(&"jump_start")
		else:
			animator.set_locomotion_state(&"fall")
		return

	if _in_defensive_stance:
		animator.set_locomotion_state(&"defensive_stance")
		return

	if _landing_frames_left > 0:
		animator.set_locomotion_state(&"land")
		return

	var is_moving: bool = horiz_speed > 0.35 or move_xz.length_squared() > 0.02
	if not is_moving:
		animator.set_locomotion_state(&"idle")
	elif _is_sprinting:
		animator.set_locomotion_state(&"sprint")
	else:
		animator.set_locomotion_state(&"run")


func _acquire_input_frame(tick: int, dt: float) -> Dictionary:
	_input_seq += 1
	if _external_input_provider != null:
		if _external_input_provider is Callable:
			var c := _external_input_provider as Callable
			if c.is_valid():
				var f: Variant = c.call(tick, dt)
				if f is Dictionary:
					return f
		elif _external_input_provider is Object and _external_input_provider.has_method("sample_input"):
			var f_obj: Variant = _external_input_provider.call("sample_input", tick, dt)
			if f_obj is Dictionary:
				return f_obj

	if not is_local_human:
		return {
			"seq": _input_seq,
			"tick": tick,
			"move_world_xz": Vector2.ZERO,
			"local_dir": Vector2.ZERO,
			"buttons": 0,
			"aim_yaw": aim_yaw,
		}

	return _sample_local_human_input(tick)


func _sample_local_human_input(tick: int) -> Dictionary:
	if camera_rig != null:
		camera_rig.poll_touch_camera_input()

	var rx: float = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	var fy: float = Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	var local_dir := Vector2(rx, fy)
	if local_dir.length_squared() > 1.0:
		local_dir = local_dir.normalized()

	var btns: int = 0
	if Input.is_action_pressed("sprint"):
		btns |= BTN_SPRINT
	if Input.is_action_pressed("jump"):
		btns |= BTN_JUMP
	if Input.is_action_pressed("shoot"):
		btns |= BTN_SHOOT
	if Input.is_action_pressed("pass_ball"):
		btns |= BTN_PASS
	if Input.is_action_pressed("skill_q"):
		btns |= BTN_SKILL_Q
	if Input.is_action_pressed("skill_e"):
		btns |= BTN_SKILL_E
	if Input.is_action_pressed("skill_r"):
		btns |= BTN_SKILL_R
	if Input.is_action_pressed("steal"):
		btns |= BTN_STEAL
	if Input.is_action_pressed("zone_activate"):
		btns |= BTN_ZONE
	if Input.is_action_pressed("defensive_stance"):
		btns |= BTN_STANCE

	# Merge iOS / Mobile TouchControlsUI virtual stick & ergonomic action buttons when active
	var tc: Node = _find_touch_controls()
	if tc != null and tc.has_method("is_touch_active") and bool(tc.call("is_touch_active")):
		if tc.has_method("get_touch_input_overlay"):
			var raw_ov: Variant = tc.call("get_touch_input_overlay")
			if raw_ov is Dictionary:
				var ov := raw_ov as Dictionary
				if ov.get("move_local") is Vector2:
					var touch_move: Vector2 = ov["move_local"]
					if touch_move.length_squared() > 0.001:
						local_dir = touch_move.normalized() if touch_move.length_squared() > 1.0 else touch_move
				var touch_btns: int = int(ov.get("buttons", 0))
				# Ergonomic outer-stick auto-sprint retrigger: if left thumbstick outer ring already
				# holds BTN_SPRINT and the player taps the right-thumb SPRINT button (e.g. Q->E->Q->Sprint),
				# release BTN_SPRINT for 1 tick so ComboEngine sees a clean 0->1 rising edge on the next tick.
				var explicit_sprint_mask: int = (int(tc.get("_touch_buttons_mask")) | int(tc.get("_sim_buttons_mask"))) & BTN_SPRINT
				var explicit_sprint_now: bool = explicit_sprint_mask != 0
				if _touch_sprint_retrigger_pending:
					_touch_sprint_retrigger_pending = false
					touch_btns |= BTN_SPRINT
				elif explicit_sprint_now and not _prev_touch_explicit_sprint and ((_prev_buttons & BTN_SPRINT) != 0):
					touch_btns &= (~BTN_SPRINT)
					_touch_sprint_retrigger_pending = true
				_prev_touch_explicit_sprint = explicit_sprint_now
				btns |= touch_btns
	else:
		_prev_touch_explicit_sprint = false
		_touch_sprint_retrigger_pending = false

	var cam_yaw: float = camera_rig.get_yaw() if camera_rig != null else aim_yaw
	var world_xz := _local_dir_to_world_xz(local_dir, cam_yaw)

	return {
		"seq": _input_seq,
		"tick": tick,
		"move_world_xz": world_xz,
		"local_dir": local_dir,
		"buttons": btns,
		"aim_yaw": cam_yaw,
	}


func _find_touch_controls() -> Node:
	if is_inside_tree() and get_tree() != null:
		var tc: Node = get_tree().get_first_node_in_group("touch_controls")
		if tc != null:
			return tc
		var arena_node: Node = get_tree().get_first_node_in_group("arena")
		if arena_node != null and arena_node.has_method("get_touch_controls"):
			return arena_node.call("get_touch_controls")
	return null


func _resolve_world_move_xz(frame: Dictionary) -> Vector2:
	if frame.has("move_world_xz") and frame["move_world_xz"] is Vector2:
		var mw: Vector2 = frame["move_world_xz"]
		if mw.length_squared() > 0.0001:
			return mw.normalized() if mw.length_squared() > 1.0001 else mw

	if frame.has("local_dir") and frame["local_dir"] is Vector2:
		var ld: Vector2 = frame["local_dir"]
		if ld.length_squared() > 0.0001:
			var yaw_val: float = float(frame.get("aim_yaw", camera_rig.get_yaw() if camera_rig != null else aim_yaw))
			return _local_dir_to_world_xz(ld, yaw_val)

	return Vector2.ZERO


func _local_dir_to_world_xz(local_dir: Vector2, ref_yaw: float) -> Vector2:
	if local_dir.length_squared() <= 0.0001:
		return Vector2.ZERO
	var clamped_local: Vector2 = local_dir.normalized() if local_dir.length_squared() > 1.0 else local_dir
	var fwd_xz := Vector2(-sin(ref_yaw), -cos(ref_yaw))
	var right_xz := Vector2(cos(ref_yaw), -sin(ref_yaw))
	var world_vec: Vector2 = right_xz * clamped_local.x + fwd_xz * clamped_local.y
	if world_vec.length_squared() > 1.0001:
		return world_vec.normalized()
	return world_vec


func _update_facing(dt: float, move_xz: Vector2, carrying_ball: bool, ball: Basketball = null) -> void:
	if shooting_system != null and (shooting_system.is_charging_shot or shooting_system.is_dunking):
		_face_position_xz(_get_target_rim_position())
	elif dribble_system != null and dribble_system.has_stepback_gather_bonus():
		_face_position_xz(_get_target_rim_position())
	elif _in_defensive_stance:
		# Instant facing lock toward ball-handler / live pass-shot (zero turnaround lag!)
		if ball != null and ball.carrier != null and ball.carrier != self and ball.carrier_team_id != team_id:
			_face_position_xz(ball.carrier.global_position)
		elif ball != null and (
			ball.ball_state == Basketball.BallState.PASS_FLIGHT
			or ball.ball_state == Basketball.BallState.SHOT_FLIGHT
		):
			_face_position_xz(ball.global_position)
		else:
			var opp: Node3D = _find_primary_opponent()
			if opp != null:
				_face_position_xz(opp.global_position)
			else:
				facing_yaw = aim_yaw
	elif move_xz.length_squared() > 0.0025:
		var desired_yaw: float = atan2(-move_xz.x, -move_xz.y)
		facing_yaw = lerp_angle(facing_yaw, desired_yaw, clampf(dt * 16.0, 0.0, 1.0))
	elif carrying_ball:
		pass

	if animator != null:
		animator.rotation.y = facing_yaw


func _face_position_xz(target_pos: Vector3) -> void:
	var dx: float = target_pos.x - global_position.x
	var dz: float = target_pos.z - global_position.z
	if (dx * dx + dz * dz) > 0.0001:
		facing_yaw = atan2(-dx, -dz)
		if animator != null:
			animator.rotation.y = facing_yaw


func _get_facing_forward_xz() -> Vector3:
	var v := Vector3(-sin(facing_yaw), 0.0, -cos(facing_yaw))
	if v.length_squared() > 0.0001:
		return v.normalized()
	return Vector3(0.0, 0.0, -1.0)


func _get_aim_forward_xz() -> Vector3:
	if camera_rig != null and is_local_human and _external_input_provider == null:
		return camera_rig.get_forward_xz()
	var v := Vector3(-sin(aim_yaw), 0.0, -cos(aim_yaw))
	if v.length_squared() > 0.0001:
		return v.normalized()
	return _get_facing_forward_xz()


func _find_basketball() -> Basketball:
	var tree := get_tree()
	if tree == null:
		return null
	for node in tree.get_nodes_in_group("basketball"):
		if node is Basketball:
			return node as Basketball
	return null


func _get_target_rim_position() -> Vector3:
	var tree := get_tree()
	if tree != null:
		for node in tree.get_nodes_in_group("hoops"):
			if node is HoopController:
				var hc := node as HoopController
				if hc.get_attacking_team() == team_id:
					return hc.get_rim_center()
	var fallback_z: float = -12.425 if team_id == 0 else 12.425
	return Vector3(0.0, 3.05, fallback_z)


func _get_defended_rim_position() -> Vector3:
	var tree := get_tree()
	if tree != null:
		for node in tree.get_nodes_in_group("hoops"):
			if node is HoopController:
				var hc := node as HoopController
				if hc.defended_by_team == team_id:
					return hc.get_rim_center()
	var fallback_z: float = 12.425 if team_id == 0 else -12.425
	return Vector3(0.0, 3.05, fallback_z)


func _find_primary_opponent() -> Node3D:
	var tree := get_tree()
	if tree == null:
		return null
	var best: Node3D = null
	var best_d_sq: float = INF
	for node in tree.get_nodes_in_group("players"):
		if node == self or not (node is Node3D):
			continue
		if node.get("team_id") != null and int(node.get("team_id")) != team_id:
			var n3 := node as Node3D
			var d_sq: float = global_position.distance_squared_to(n3.global_position)
			if d_sq < best_d_sq:
				best_d_sq = d_sq
				best = n3
	return best


func get_ai_controller() -> Node:
	return get_node_or_null("AIController")


func _export_optional_ai_state() -> Dictionary:
	var ai_node: Node = get_node_or_null("AIController")
	if ai_node != null and ai_node.has_method("export_state"):
		var d: Variant = ai_node.call("export_state")
		if d is Dictionary:
			return d
	return {}


func _import_optional_ai_state(ai_state: Dictionary) -> void:
	var ai_node: Node = get_node_or_null("AIController")
	if ai_node != null and ai_node.has_method("import_state"):
		ai_node.call("import_state", ai_state)
