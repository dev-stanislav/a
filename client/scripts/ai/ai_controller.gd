class_name AIController
extends Node
## Deterministic 60 Hz AI Opponent Controller for PHANTOM COURT ONLINE (Phase 7).
## Implements the canonical PlayerController external input provider contract:
##   sample_input(tick: int, dt: float) -> Dictionary (PlayerInputFrame)
## Never cheats or teleports: drives real jump-shot charge/release timings with
## difficulty-scaled jitter, genuine frame-paced multi-step combo sequences through
## ComboEngine, defensive rim-line stance containment, disciplined steals/blocks,
## and 2v2/3v3 floor spacing & pass-lane vision.

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

const OPTIMAL_JUMP_CHARGE_SEC: float = 0.26
const OPTIMAL_LAYUP_CHARGE_SEC: float = 0.18

@export var difficulty_tier: int = AIDifficulty.Tier.PRO
@export var rng_seed: int = 1337

var owner_player: Node = null
var perception: AIPerception
var move_db: MoveDatabase

var _profile: Dictionary = {}
var _rng: RandomNumberGenerator
var _input_seq: int = 0
var _internal_tick: int = -1
var _last_external_tick: int = -1
var _ticks_since_decision: int = 999
var _prev_emitted_buttons: int = 0

# Active intent / plan state
var _current_intent: Dictionary = {}

# Active shot charge/release state
var _shot_plan_active: bool = false
var _shot_is_layup: bool = false
var _shot_hold_elapsed: float = 0.0
var _shot_target_hold_sec: float = OPTIMAL_JUMP_CHARGE_SEC
var _shot_cooldown_ticks: int = 0

# Active frame-paced multi-step combo execution state
var _active_combo_id: String = ""
var _active_combo_sequence: Array[String] = []
var _active_combo_requires_ball: bool = true
var _active_combo_step: int = 0
var _active_combo_gap_timer: int = 0
var _active_combo_step_gap: int = 6
var _combo_lockout_ticks: int = 0

# Pulse cooldowns so discrete actions trigger clean rising edges
var _steal_pulse_cooldown: int = 0
var _jump_pulse_cooldown: int = 0
var _pass_pulse_cooldown: int = 0
var _dribble_pulse_cooldown: int = 0


func _init() -> void:
	perception = AIPerception.new()
	move_db = MoveDatabase.new(true)
	_rng = RandomNumberGenerator.new()
	_rng.seed = rng_seed
	_profile = AIDifficulty.get_profile(difficulty_tier)


func setup(
	target_player: Node,
	tier: int = AIDifficulty.Tier.PRO,
	seed_val: int = 1337
) -> void:
	owner_player = target_player
	difficulty_tier = AIDifficulty.clamp_tier(tier)
	_profile = AIDifficulty.get_profile(difficulty_tier)
	rng_seed = seed_val
	reset()


func set_difficulty(tier: int) -> void:
	difficulty_tier = AIDifficulty.clamp_tier(tier)
	_profile = AIDifficulty.get_profile(difficulty_tier)


func get_difficulty() -> int:
	return difficulty_tier


func get_difficulty_profile() -> Dictionary:
	return _profile.duplicate(true)


func set_seed(seed_val: int) -> void:
	rng_seed = seed_val
	_rng.seed = rng_seed


func get_seed() -> int:
	return rng_seed


func reset() -> void:
	perception.clear()
	_rng.seed = rng_seed
	_input_seq = 0
	_internal_tick = -1
	_last_external_tick = -1
	_ticks_since_decision = 999
	_prev_emitted_buttons = 0
	_current_intent.clear()
	_clear_shot_plan()
	_clear_combo_plan()
	_shot_cooldown_ticks = 0
	_combo_lockout_ticks = 0
	_steal_pulse_cooldown = 0
	_jump_pulse_cooldown = 0
	_pass_pulse_cooldown = 0
	_dribble_pulse_cooldown = 0


## Canonical PlayerController external input provider method.
func sample_input(tick: int, dt: float = 1.0 / 60.0) -> Dictionary:
	var step_dt: float = dt if (dt > 0.0 and dt <= 0.05) else (1.0 / 60.0)
	var sim_tick: int = _advance_internal_tick(tick)
	var live_snap: Dictionary = AIPerception.build_snapshot(owner_player, sim_tick)
	return _step_internal(live_snap, tick, sim_tick, step_dt)


## Deterministic test hook: feeds an explicit WorldSnapshot directly without requiring
## a live scene tree, exercising the exact same perception delay, brain, and plan execution!
func step_with_snapshot(
	snapshot: Dictionary,
	tick: int,
	dt: float = 1.0 / 60.0
) -> Dictionary:
	var step_dt: float = dt if (dt > 0.0 and dt <= 0.05) else (1.0 / 60.0)
	var sim_tick: int = _advance_internal_tick(tick)
	var stamped: Dictionary = snapshot.duplicate(true)
	stamped["tick"] = sim_tick
	return _step_internal(stamped, tick, sim_tick, step_dt)


func get_current_intent() -> Dictionary:
	return {
		"role": str(_current_intent.get("role", AIUtilityBrain.ROLE_LOOSE_BALL_CHASE)),
		"action": str(_current_intent.get("action", AIUtilityBrain.ACT_CHASE_BALL)),
		"target_pos": _current_intent.get("target_pos", Vector3.ZERO),
		"aim_target": _current_intent.get("aim_target", Vector3.ZERO),
		"utility_scores": (_current_intent.get("utility_scores", {}) as Dictionary).duplicate(true),
		"reaction_delay_frames": int(_profile.get("reaction_delay_frames", 12)),
		"queued_combo_id": _active_combo_id if not _active_combo_id.is_empty() else str(_current_intent.get("queued_combo_id", "")),
		"queued_combo_step": _active_combo_step,
		"difficulty_tier": difficulty_tier,
		"difficulty_name": AIDifficulty.get_tier_name(difficulty_tier),
		"target_teammate_id": int(_current_intent.get("target_teammate_id", -1)),
		"shot_plan_active": _shot_plan_active,
		"shot_charge_target_sec": _shot_target_hold_sec,
	}


## Deterministic rollback snapshot export (includes exact PCG32 RNG state & perception queue).
func export_state() -> Dictionary:
	var seq_copy: Array[String] = []
	for s in _active_combo_sequence:
		seq_copy.append(s)

	return {
		"difficulty_tier": difficulty_tier,
		"rng_seed": rng_seed,
		"rng_state": _rng.state,
		"input_seq": _input_seq,
		"internal_tick": _internal_tick,
		"last_external_tick": _last_external_tick,
		"ticks_since_decision": _ticks_since_decision,
		"prev_emitted_buttons": _prev_emitted_buttons,
		"current_intent": _current_intent.duplicate(true),
		"shot_plan_active": _shot_plan_active,
		"shot_is_layup": _shot_is_layup,
		"shot_hold_elapsed": _shot_hold_elapsed,
		"shot_target_hold_sec": _shot_target_hold_sec,
		"shot_cooldown_ticks": _shot_cooldown_ticks,
		"active_combo_id": _active_combo_id,
		"active_combo_sequence": seq_copy,
		"active_combo_requires_ball": _active_combo_requires_ball,
		"active_combo_step": _active_combo_step,
		"active_combo_gap_timer": _active_combo_gap_timer,
		"active_combo_step_gap": _active_combo_step_gap,
		"combo_lockout_ticks": _combo_lockout_ticks,
		"steal_pulse_cooldown": _steal_pulse_cooldown,
		"jump_pulse_cooldown": _jump_pulse_cooldown,
		"pass_pulse_cooldown": _pass_pulse_cooldown,
		"dribble_pulse_cooldown": _dribble_pulse_cooldown,
		"perception": perception.export_state(),
	}


func import_state(state: Dictionary) -> void:
	difficulty_tier = AIDifficulty.clamp_tier(int(state.get("difficulty_tier", difficulty_tier)))
	_profile = AIDifficulty.get_profile(difficulty_tier)
	rng_seed = int(state.get("rng_seed", rng_seed))
	_rng.seed = rng_seed
	if state.has("rng_state"):
		_rng.state = int(state["rng_state"])

	_input_seq = int(state.get("input_seq", 0))
	_internal_tick = int(state.get("internal_tick", -1))
	_last_external_tick = int(state.get("last_external_tick", -1))
	_ticks_since_decision = int(state.get("ticks_since_decision", 999))
	_prev_emitted_buttons = int(state.get("prev_emitted_buttons", 0))

	if state.has("current_intent") and state["current_intent"] is Dictionary:
		_current_intent = (state["current_intent"] as Dictionary).duplicate(true)
	else:
		_current_intent.clear()

	_shot_plan_active = bool(state.get("shot_plan_active", false))
	_shot_is_layup = bool(state.get("shot_is_layup", false))
	_shot_hold_elapsed = float(state.get("shot_hold_elapsed", 0.0))
	_shot_target_hold_sec = float(state.get("shot_target_hold_sec", OPTIMAL_JUMP_CHARGE_SEC))
	_shot_cooldown_ticks = int(state.get("shot_cooldown_ticks", 0))

	_active_combo_id = str(state.get("active_combo_id", ""))
	_active_combo_sequence.clear()
	if state.has("active_combo_sequence") and state["active_combo_sequence"] is Array:
		for item in (state["active_combo_sequence"] as Array):
			_active_combo_sequence.append(str(item))
	_active_combo_requires_ball = bool(state.get("active_combo_requires_ball", true))
	_active_combo_step = int(state.get("active_combo_step", 0))
	_active_combo_gap_timer = int(state.get("active_combo_gap_timer", 0))
	_active_combo_step_gap = int(state.get("active_combo_step_gap", 6))
	_combo_lockout_ticks = int(state.get("combo_lockout_ticks", 0))

	_steal_pulse_cooldown = int(state.get("steal_pulse_cooldown", 0))
	_jump_pulse_cooldown = int(state.get("jump_pulse_cooldown", 0))
	_pass_pulse_cooldown = int(state.get("pass_pulse_cooldown", 0))
	_dribble_pulse_cooldown = int(state.get("dribble_pulse_cooldown", 0))

	if state.has("perception") and state["perception"] is Dictionary:
		perception.import_state(state["perception"])


# ==============================================================================
# Core 60 Hz Decision & Input Generation Pipeline
# ==============================================================================

func _step_internal(
	live_snap: Dictionary,
	output_tick: int,
	sim_tick: int,
	dt: float
) -> Dictionary:
	_input_seq += 1

	# Tick down pulse cooldowns
	if _shot_cooldown_ticks > 0:
		_shot_cooldown_ticks -= 1
	if _combo_lockout_ticks > 0:
		_combo_lockout_ticks -= 1
	if _steal_pulse_cooldown > 0:
		_steal_pulse_cooldown -= 1
	if _jump_pulse_cooldown > 0:
		_jump_pulse_cooldown -= 1
	if _pass_pulse_cooldown > 0:
		_pass_pulse_cooldown -= 1
	if _dribble_pulse_cooldown > 0:
		_dribble_pulse_cooldown -= 1

	if live_snap.is_empty():
		return _build_input_frame(output_tick, Vector2.ZERO, Vector2.ZERO, 0, 0.0)

	# 1. Push live observation into reaction-delay ring queue & read delayed perception
	perception.push_observation(sim_tick, live_snap)
	var delay_frames: int = int(_profile.get("reaction_delay_frames", 12))
	var perceived: Dictionary = perception.get_perceived_snapshot(sim_tick, delay_frames)

	var p_me: Dictionary = perceived.get("self", {})
	var live_me: Dictionary = live_snap.get("self", {})
	var my_pos: Vector3 = live_me.get("position", p_me.get("position", Vector3.ZERO))
	var has_ball_now: bool = bool(live_me.get("has_ball", p_me.get("has_ball", false)))
	var ankle_broken_now: bool = bool(live_me.get("is_ankle_broken", false))
	var target_rim: Vector3 = perceived.get("target_rim", AIPerception.HOOP_B_RIM)

	# Abort active multi-tick plans cleanly if stunned or ball ownership changed unexpectedly
	if ankle_broken_now:
		_clear_shot_plan()
		_clear_combo_plan()
	if _shot_plan_active and not has_ball_now:
		_clear_shot_plan()
	if not _active_combo_id.is_empty() and _active_combo_requires_ball and not has_ball_now:
		_clear_combo_plan()

	# 2. Periodic Utility Brain Re-Evaluation (governed by decision_interval_frames on perceived world)
	_ticks_since_decision += 1
	var dec_interval: int = maxi(1, int(_profile.get("decision_interval_frames", 8)))
	var perceived_role: String = AIUtilityBrain.classify_role(perceived)
	var role_changed: bool = _current_intent.is_empty() or (str(_current_intent.get("role", "")) != perceived_role)
	var can_redecide: bool = (not _shot_plan_active) and _active_combo_id.is_empty()

	if can_redecide and (role_changed or _ticks_since_decision >= dec_interval):
		_current_intent = AIUtilityBrain.evaluate(perceived, _profile, _rng)
		_ticks_since_decision = 0
		_maybe_start_multi_tick_plan(perceived)

	# 3. Compute canonical aim_yaw toward current aim_target (guarded against zero vectors)
	var aim_target: Vector3 = _current_intent.get("aim_target", target_rim)
	if _shot_plan_active or (not _active_combo_id.is_empty() and _active_combo_requires_ball):
		aim_target = target_rim
	var aim_yaw: float = _compute_yaw_toward(my_pos, aim_target, float(live_me.get("facing_yaw", 0.0)))

	# 4. Priority Execution A: Active Timed Jump Shot / Layup Release Plan
	if _shot_plan_active:
		return _step_shot_plan(output_tick, dt, aim_yaw)

	# 5. Priority Execution B: Active Frame-Paced Multi-Step Combo Input Plan
	if not _active_combo_id.is_empty():
		return _step_combo_plan(output_tick, my_pos, aim_yaw, target_rim)

	# 6. Standard Locomotion & Single-Tick Action Execution from Current Intent
	var action: String = str(_current_intent.get("action", AIUtilityBrain.ACT_CHASE_BALL))
	var target_pos: Vector3 = _current_intent.get("target_pos", my_pos)
	var move_world_xz: Vector2 = _compute_move_toward_xz(my_pos, target_pos, 0.22)
	var local_dir: Vector2 = _world_to_local_dir(move_world_xz, aim_yaw)
	var buttons: int = 0

	if bool(_current_intent.get("wants_sprint", false)) and move_world_xz.length_squared() > 0.01:
		buttons |= BTN_SPRINT
	if bool(_current_intent.get("wants_stance", false)) and not has_ball_now:
		buttons |= BTN_STANCE

	match action:
		AIUtilityBrain.ACT_ACTIVATE_ZONE:
			if (_prev_emitted_buttons & BTN_ZONE) == 0:
				buttons |= BTN_ZONE

		AIUtilityBrain.ACT_SHOOT_DUNK:
			# Drive with sprint + pulse shoot inside dunk range so ShootingSystem initiates real slam dunk
			var to_rim: Vector2 = _compute_move_toward_xz(my_pos, target_rim, 0.10)
			move_world_xz = to_rim
			local_dir = _world_to_local_dir(move_world_xz, aim_yaw)
			buttons |= BTN_SPRINT
			if _shot_cooldown_ticks <= 0 and (_prev_emitted_buttons & BTN_SHOOT) == 0:
				buttons |= BTN_SHOOT
				_shot_cooldown_ticks = 22

		AIUtilityBrain.ACT_PASS_TEAMMATE:
			if has_ball_now and _pass_pulse_cooldown <= 0 and (_prev_emitted_buttons & BTN_PASS) == 0:
				buttons |= BTN_PASS
				_pass_pulse_cooldown = 18

		AIUtilityBrain.ACT_DRIBBLE_MOVE:
			if has_ball_now and _dribble_pulse_cooldown <= 0:
				var drib_id: String = str(_current_intent.get("dribble_move_id", "crossover"))
				if drib_id == "stepback":
					local_dir = Vector2(0.0, -1.0)
					move_world_xz = _local_to_world_xz(local_dir, aim_yaw)
					if (_prev_emitted_buttons & BTN_SKILL_R) == 0:
						buttons |= BTN_SKILL_R
				elif drib_id == "behind_the_back":
					local_dir = Vector2(0.0, -0.8)
					move_world_xz = _local_to_world_xz(local_dir, aim_yaw)
					if (_prev_emitted_buttons & BTN_SKILL_Q) == 0:
						buttons |= BTN_SKILL_Q
				else:
					var hand: int = int(live_me.get("dribble_hand", 1))
					var btn: int = BTN_SKILL_Q if hand == 1 else BTN_SKILL_E
					if (_prev_emitted_buttons & btn) == 0:
						buttons |= btn
				_dribble_pulse_cooldown = 16

		AIUtilityBrain.ACT_CONTEST_BLOCK:
			if not has_ball_now and _jump_pulse_cooldown <= 0 and (_prev_emitted_buttons & BTN_JUMP) == 0:
				buttons |= BTN_JUMP
				_jump_pulse_cooldown = 28

		AIUtilityBrain.ACT_ATTEMPT_STEAL:
			if not has_ball_now and _steal_pulse_cooldown <= 0 and (_prev_emitted_buttons & BTN_STEAL) == 0:
				buttons |= BTN_STEAL
				_steal_pulse_cooldown = 24

		_:
			if bool(_current_intent.get("wants_jump", false)) and _jump_pulse_cooldown <= 0 and (_prev_emitted_buttons & BTN_JUMP) == 0:
				buttons |= BTN_JUMP
				_jump_pulse_cooldown = 24
			if bool(_current_intent.get("wants_steal", false)) and not has_ball_now and _steal_pulse_cooldown <= 0 and (_prev_emitted_buttons & BTN_STEAL) == 0:
				buttons |= BTN_STEAL
				_steal_pulse_cooldown = 18

	return _build_input_frame(output_tick, move_world_xz, local_dir, buttons, aim_yaw)


func _maybe_start_multi_tick_plan(perceived: Dictionary) -> void:
	var action: String = str(_current_intent.get("action", ""))
	var p_me: Dictionary = perceived.get("self", {})
	var has_ball_p: bool = bool(p_me.get("has_ball", false))

	if (action == AIUtilityBrain.ACT_SHOOT_JUMP or action == AIUtilityBrain.ACT_SHOOT_LAYUP) and has_ball_p and _shot_cooldown_ticks <= 0:
		var is_layup: bool = (action == AIUtilityBrain.ACT_SHOOT_LAYUP)
		var opt_sec: float = OPTIMAL_LAYUP_CHARGE_SEC if is_layup else OPTIMAL_JUMP_CHARGE_SEC
		var jitter_max: float = float(_profile.get("shot_timing_jitter_sec", 0.055))
		var jitter: float = _rng.randf_range(-jitter_max, jitter_max)
		_shot_plan_active = true
		_shot_is_layup = is_layup
		_shot_hold_elapsed = 0.0
		# Account for ShootingSystem incrementing charge_time by 1 tick on the release frame
		_shot_target_hold_sec = clampf(opt_sec + jitter - (1.0 / 60.0), 0.05, 0.44)
		return

	if action == AIUtilityBrain.ACT_EXECUTE_COMBO and _combo_lockout_ticks <= 0:
		var cid: String = str(_current_intent.get("queued_combo_id", ""))
		if cid.is_empty():
			return
		var move: FrameData = move_db.get_move(cid)
		if move == null or move.sequence.is_empty():
			return
		_active_combo_id = cid
		_active_combo_sequence.clear()
		for sym in move.sequence:
			_active_combo_sequence.append(sym)
		_active_combo_requires_ball = move.requires_ball
		_active_combo_step = 0
		_active_combo_step_gap = maxi(4, int(_profile.get("combo_step_gap_frames", 6)))
		# Insert 1 neutral release tick before Step 0 if Step 0's button (e.g. Shift or C)
		# was already held on the previous tick, guaranteeing a clean 0->1 rising edge!
		var first_sym: String = InputBuffer.normalize_symbol(_active_combo_sequence[0])
		var first_btn: int = _symbol_to_button_bit(first_sym)
		_active_combo_gap_timer = 1 if (first_btn != 0 and (_prev_emitted_buttons & first_btn) != 0) else 0


func _step_shot_plan(output_tick: int, dt: float, aim_yaw: float) -> Dictionary:
	# Tick 0 begins charging shot (rising edge of BTN_SHOOT); hold until elapsed >= target_hold_sec, then release!
	if _shot_hold_elapsed < _shot_target_hold_sec:
		_shot_hold_elapsed += dt
		var move_xz := Vector2.ZERO
		var l_dir := Vector2.ZERO
		if _shot_is_layup:
			l_dir = Vector2(0.0, 1.0)
			move_xz = _local_to_world_xz(l_dir, aim_yaw)
		return _build_input_frame(output_tick, move_xz, l_dir, BTN_SHOOT, aim_yaw)

	# Release BTN_SHOOT cleanly on exact target frame!
	_clear_shot_plan()
	_shot_cooldown_ticks = 14
	return _build_input_frame(output_tick, Vector2.ZERO, Vector2.ZERO, 0, aim_yaw)


func _step_combo_plan(
	output_tick: int,
	my_pos: Vector3,
	aim_yaw: float,
	target_rim: Vector3
) -> Dictionary:
	if _active_combo_step >= _active_combo_sequence.size():
		_clear_combo_plan()
		_combo_lockout_ticks = 18
		return _build_input_frame(output_tick, Vector2.ZERO, Vector2.ZERO, 0, aim_yaw)

	var buttons: int = 0
	var local_dir: Vector2 = Vector2.ZERO
	var move_world_xz: Vector2 = Vector2.ZERO

	if _active_combo_gap_timer <= 0:
		var sym: String = InputBuffer.normalize_symbol(_active_combo_sequence[_active_combo_step])
		var step_btn: int = _symbol_to_button_bit(sym)
		if step_btn != 0:
			buttons |= step_btn
			# Maintain rim-facing forward bias for Meteor Dunk / drives without breaking directional steps
			if _active_combo_id == MoveDatabase.MOVE_METEOR_DUNK and _active_combo_step >= 1:
				local_dir = Vector2(0.0, 1.0)
				move_world_xz = _local_to_world_xz(local_dir, aim_yaw)
		else:
			local_dir = _symbol_to_local_dir(sym)
			move_world_xz = _local_to_world_xz(local_dir, aim_yaw)

		_active_combo_step += 1
		if _active_combo_step >= _active_combo_sequence.size():
			_clear_combo_plan()
			_combo_lockout_ticks = 22
		else:
			_active_combo_gap_timer = _active_combo_step_gap - 1
	else:
		_active_combo_gap_timer -= 1
		# Keep neutral buttons on gap frames so identical consecutive buttons (e.g., Q, Q) emit clean rising edges!
		# Also keep local_dir neutral right before a directional step so directional snaps edge-trigger cleanly.
		var next_sym: String = InputBuffer.normalize_symbol(_active_combo_sequence[_active_combo_step])
		if InputBuffer.is_direction_symbol(next_sym):
			local_dir = Vector2.ZERO
			move_world_xz = Vector2.ZERO
		elif _active_combo_id == MoveDatabase.MOVE_METEOR_DUNK and _active_combo_step >= 2:
			local_dir = Vector2(0.0, 1.0)
			move_world_xz = _compute_move_toward_xz(my_pos, target_rim, 0.1)

	return _build_input_frame(output_tick, move_world_xz, local_dir, buttons, aim_yaw)


func _clear_shot_plan() -> void:
	_shot_plan_active = false
	_shot_is_layup = false
	_shot_hold_elapsed = 0.0


func _clear_combo_plan() -> void:
	_active_combo_id = ""
	_active_combo_sequence.clear()
	_active_combo_requires_ball = true
	_active_combo_step = 0
	_active_combo_gap_timer = 0


func _advance_internal_tick(external_tick: int) -> int:
	if _internal_tick < 0:
		_internal_tick = maxi(0, external_tick)
		_last_external_tick = external_tick
	elif external_tick > _last_external_tick:
		_internal_tick += (external_tick - _last_external_tick)
		_last_external_tick = external_tick
	else:
		_internal_tick += 1
		_last_external_tick = external_tick
	return _internal_tick


func _build_input_frame(
	tick: int,
	move_world_xz: Vector2,
	local_dir: Vector2,
	buttons: int,
	aim_yaw: float
) -> Dictionary:
	_prev_emitted_buttons = buttons
	var clamped_world: Vector2 = move_world_xz.normalized() if move_world_xz.length_squared() > 1.0001 else move_world_xz
	var clamped_local: Vector2 = local_dir.normalized() if local_dir.length_squared() > 1.0001 else local_dir
	return {
		"seq": _input_seq,
		"tick": tick,
		"move_world_xz": clamped_world,
		"local_dir": clamped_local,
		"buttons": buttons,
		"aim_yaw": aim_yaw,
	}


# ==============================================================================
# Coordinate & Symbol Helpers (Zero-Vector Safe)
# ==============================================================================

static func _compute_yaw_toward(origin: Vector3, target: Vector3, fallback_yaw: float) -> float:
	var dx: float = target.x - origin.x
	var dz: float = target.z - origin.z
	if (dx * dx + dz * dz) > 1e-6:
		return atan2(-dx, -dz)
	return fallback_yaw


static func _compute_move_toward_xz(origin: Vector3, target: Vector3, stop_radius: float = 0.22) -> Vector2:
	var delta := Vector2(target.x - origin.x, target.z - origin.z)
	var len_sq: float = delta.length_squared()
	if len_sq <= (stop_radius * stop_radius) or len_sq <= 1e-8:
		return Vector2.ZERO
	return delta / sqrt(len_sq)


static func _world_to_local_dir(world_xz: Vector2, ref_yaw: float) -> Vector2:
	if world_xz.length_squared() <= 1e-8:
		return Vector2.ZERO
	var fwd_xz := Vector2(-sin(ref_yaw), -cos(ref_yaw))
	var right_xz := Vector2(cos(ref_yaw), -sin(ref_yaw))
	var lx: float = world_xz.dot(right_xz)
	var ly: float = world_xz.dot(fwd_xz)
	var v := Vector2(lx, ly)
	if v.length_squared() > 1.0001:
		return v.normalized()
	return v


static func _local_to_world_xz(local_dir: Vector2, ref_yaw: float) -> Vector2:
	if local_dir.length_squared() <= 1e-8:
		return Vector2.ZERO
	var clamped: Vector2 = local_dir.normalized() if local_dir.length_squared() > 1.0 else local_dir
	var fwd_xz := Vector2(-sin(ref_yaw), -cos(ref_yaw))
	var right_xz := Vector2(cos(ref_yaw), -sin(ref_yaw))
	var w: Vector2 = right_xz * clamped.x + fwd_xz * clamped.y
	if w.length_squared() > 1.0001:
		return w.normalized()
	return w


static func _symbol_to_button_bit(sym: String) -> int:
	match sym:
		"Shift":
			return BTN_SPRINT
		"Space":
			return BTN_JUMP
		"LMB":
			return BTN_SHOOT
		"RMB":
			return BTN_PASS
		"Q":
			return BTN_SKILL_Q
		"E":
			return BTN_SKILL_E
		"R":
			return BTN_SKILL_R
		"F":
			return BTN_STEAL
		"V":
			return BTN_ZONE
		"C":
			return BTN_STANCE
		_:
			return 0


static func _symbol_to_local_dir(sym: String) -> Vector2:
	match sym:
		"W":
			return Vector2(0.0, 1.0)
		"S":
			return Vector2(0.0, -1.0)
		"A":
			return Vector2(-1.0, 0.0)
		"D":
			return Vector2(1.0, 0.0)
		_:
			return Vector2.ZERO
