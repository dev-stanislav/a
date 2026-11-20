class_name DefensiveDummy
extends Node
## Programmable Practice Arena Defensive Dummy implementing the canonical PlayerController
## external input provider contract: sample_input(tick: int, dt: float) -> Dictionary.
## Supports 6 modes: IDLE, STANCE_CONTEST, JUMP_BLOCK, STEAL_INTERVAL, MIRROR_GUARD, LIVE_PHANTOM_AI.

enum Mode {
	IDLE = 0,
	STANCE_CONTEST = 1,
	JUMP_BLOCK = 2,
	STEAL_INTERVAL = 3,
	MIRROR_GUARD = 4,
	LIVE_PHANTOM_AI = 5,
}

const MODE_NAMES: Array[String] = [
	"Idle",
	"Stance Contest",
	"Jump Block",
	"Steal Interval",
	"Mirror Guard",
	"Live Phantom AI",
]

const BTN_SPRINT: int = 1
const BTN_JUMP: int   = 2
const BTN_STEAL: int  = 128
const BTN_STANCE: int = 512

const STEAL_INTERVAL_FRAMES: int = 90 # 1.5s @ 60 Hz
const DEFENDED_RIM_DEFAULT := Vector3(0.0, 3.05, -12.425) # Dummy is Team 1 defending HoopB

@export var mode: int = Mode.IDLE

var dummy_player: Node3D = null
var target_player: Node3D = null
var defended_rim: Vector3 = DEFENDED_RIM_DEFAULT

var _phantom_ai: AIController = null
var _phantom_seed: int = 404
var _input_seq: int = 0
var _mode_ticks: int = 0
var _jump_cooldown_ticks: int = 0
var _steal_pulsed_this_interval: bool = false


func setup(
	owner_dummy_player: Node3D,
	offense_player: Node3D,
	initial_mode: int = Mode.IDLE,
	seed_val: int = 404,
	rim_pos: Vector3 = DEFENDED_RIM_DEFAULT
) -> void:
	dummy_player = owner_dummy_player
	target_player = offense_player
	defended_rim = rim_pos
	_phantom_seed = seed_val
	_ensure_phantom_ai()
	set_mode(initial_mode)


func set_mode(new_mode: int) -> void:
	mode = clampi(new_mode, Mode.IDLE, Mode.LIVE_PHANTOM_AI)
	_mode_ticks = 0
	_jump_cooldown_ticks = 0
	_steal_pulsed_this_interval = false
	if mode == Mode.LIVE_PHANTOM_AI:
		_ensure_phantom_ai()
		if _phantom_ai != null:
			_phantom_ai.reset()


func get_mode() -> int:
	return mode


func get_mode_name(query_mode: int = -1) -> String:
	var m: int = clampi(mode if query_mode < 0 else query_mode, Mode.IDLE, Mode.LIVE_PHANTOM_AI)
	return MODE_NAMES[m]


static func mode_from_name(name_str: String) -> int:
	var key: String = name_str.strip_edges().to_upper().replace("-", "_").replace(" ", "_")
	match key:
		"IDLE", "0":
			return Mode.IDLE
		"STANCE_CONTEST", "STANCE", "1":
			return Mode.STANCE_CONTEST
		"JUMP_BLOCK", "BLOCK", "2":
			return Mode.JUMP_BLOCK
		"STEAL_INTERVAL", "STEAL", "3":
			return Mode.STEAL_INTERVAL
		"MIRROR_GUARD", "MIRROR", "4":
			return Mode.MIRROR_GUARD
		"LIVE_PHANTOM_AI", "PHANTOM_AI", "PHANTOM", "5":
			return Mode.LIVE_PHANTOM_AI
		_:
			return Mode.IDLE


func reset() -> void:
	_input_seq = 0
	_mode_ticks = 0
	_jump_cooldown_ticks = 0
	_steal_pulsed_this_interval = false
	if _phantom_ai != null:
		_phantom_ai.reset()


func get_phantom_ai() -> AIController:
	_ensure_phantom_ai()
	return _phantom_ai


## Canonical PlayerController external input provider method.
func sample_input(tick: int, dt: float = 1.0 / 60.0) -> Dictionary:
	_input_seq += 1
	_mode_ticks += 1
	if _jump_cooldown_ticks > 0:
		_jump_cooldown_ticks -= 1

	if mode == Mode.LIVE_PHANTOM_AI:
		_ensure_phantom_ai()
		if _phantom_ai != null:
			return _phantom_ai.sample_input(tick, dt)

	if dummy_player == null or target_player == null:
		return _make_frame(tick, Vector2.ZERO, Vector2.ZERO, 0, 0.0)

	var my_pos: Vector3 = dummy_player.global_position
	var tgt_pos: Vector3 = target_player.global_position
	var aim_yaw: float = _yaw_toward(my_pos, tgt_pos)

	match mode:
		Mode.IDLE:
			return _make_frame(tick, Vector2.ZERO, Vector2.ZERO, 0, aim_yaw)

		Mode.STANCE_CONTEST:
			var spot: Vector3 = _rim_line_spot(tgt_pos, 1.80)
			var move_xz: Vector2 = _move_toward_xz(my_pos, spot, 0.16)
			var l_dir: Vector2 = _world_to_local(move_xz, aim_yaw)
			return _make_frame(tick, move_xz, l_dir, BTN_STANCE, aim_yaw)

		Mode.JUMP_BLOCK:
			var spot_b: Vector3 = _rim_line_spot(tgt_pos, 1.75)
			var move_b: Vector2 = _move_toward_xz(my_pos, spot_b, 0.18)
			var l_dir_b: Vector2 = _world_to_local(move_b, aim_yaw)
			var btns_b: int = BTN_STANCE
			if _is_target_shooting_or_airborne() and _jump_cooldown_ticks <= 0:
				var dist_p: float = Vector2(my_pos.x - tgt_pos.x, my_pos.z - tgt_pos.z).length()
				if dist_p <= 3.2:
					btns_b = BTN_JUMP
					_jump_cooldown_ticks = 32
			return _make_frame(tick, move_b, l_dir_b, btns_b, aim_yaw)

		Mode.STEAL_INTERVAL:
			var spot_s: Vector3 = _rim_line_spot(tgt_pos, 1.45)
			var move_s: Vector2 = _move_toward_xz(my_pos, spot_s, 0.16)
			var l_dir_s: Vector2 = _world_to_local(move_s, aim_yaw)
			var btns_s: int = BTN_STANCE
			if _mode_ticks % STEAL_INTERVAL_FRAMES == 0:
				btns_s = BTN_STEAL
			return _make_frame(tick, move_s, l_dir_s, btns_s, aim_yaw)

		Mode.MIRROR_GUARD:
			# Aggressively mirrors player's lateral velocity to build real momentum for ankle-break drills!
			var tgt_vel: Vector3 = (target_player as CharacterBody3D).velocity if target_player is CharacterBody3D else Vector3.ZERO
			var to_rim: Vector3 = _safe_norm_xz(defended_rim - tgt_pos)
			var right_axis: Vector3 = _safe_norm_xz(to_rim.cross(Vector3.UP), Vector3(1.0, 0.0, 0.0))
			var lat_speed: float = Vector3(tgt_vel.x, 0.0, tgt_vel.z).dot(right_axis)

			var mirror_spot: Vector3 = _rim_line_spot(tgt_pos, 1.65)
			var move_m: Vector2
			var btns_m: int = 0
			if absf(lat_speed) > 1.25:
				# Sprint laterally in sync with player's lateral cut so crossover counter breaks ankles!
				var lat_dir: Vector3 = right_axis * signf(lat_speed)
				var depth_corr: Vector3 = _safe_norm_xz(mirror_spot - my_pos, Vector3.ZERO)
				var blended: Vector3 = _safe_norm_xz(lat_dir * 0.85 + depth_corr * 0.25, lat_dir)
				move_m = Vector2(blended.x, blended.z)
				btns_m = BTN_SPRINT
			else:
				move_m = _move_toward_xz(my_pos, mirror_spot, 0.16)
				btns_m = BTN_STANCE
			var l_dir_m: Vector2 = _world_to_local(move_m, aim_yaw)
			return _make_frame(tick, move_m, l_dir_m, btns_m, aim_yaw)

	return _make_frame(tick, Vector2.ZERO, Vector2.ZERO, 0, aim_yaw)


func _ensure_phantom_ai() -> void:
	if dummy_player == null:
		return
	if _phantom_ai == null:
		_phantom_ai = AIController.new()
		_phantom_ai.name = "DummyPhantomAI"
		add_child(_phantom_ai)
	_phantom_ai.setup(dummy_player, AIDifficulty.Tier.PHANTOM, _phantom_seed)


func _is_target_shooting_or_airborne() -> bool:
	if target_player == null:
		return false
	var ss: Variant = target_player.get("shooting_system")
	if ss != null and ss is Object:
		if bool(ss.get("is_charging_shot")) or bool(ss.get("is_dunking")):
			return true
	if target_player.global_position.y > 0.28:
		return true
	return false


func _rim_line_spot(offense_pos: Vector3, cushion: float) -> Vector3:
	var to_rim: Vector3 = _safe_norm_xz(defended_rim - offense_pos)
	var spot: Vector3 = offense_pos + to_rim * cushion
	return Vector3(clampf(spot.x, -6.9, 6.9), 0.0, clampf(spot.z, -13.2, 13.2))


func _make_frame(
	tick: int,
	move_world_xz: Vector2,
	local_dir: Vector2,
	buttons: int,
	aim_yaw: float
) -> Dictionary:
	return {
		"seq": _input_seq,
		"tick": tick,
		"move_world_xz": move_world_xz.normalized() if move_world_xz.length_squared() > 1.0001 else move_world_xz,
		"local_dir": local_dir.normalized() if local_dir.length_squared() > 1.0001 else local_dir,
		"buttons": buttons,
		"aim_yaw": aim_yaw,
	}


static func _safe_norm_xz(v: Vector3, fallback: Vector3 = Vector3(0.0, 0.0, -1.0)) -> Vector3:
	var flat := Vector3(v.x, 0.0, v.z)
	if flat.length_squared() > 1e-8:
		return flat.normalized()
	var fb := Vector3(fallback.x, 0.0, fallback.z)
	if fb.length_squared() > 1e-8:
		return fb.normalized()
	return Vector3.ZERO


static func _yaw_toward(origin: Vector3, target: Vector3) -> float:
	var dx: float = target.x - origin.x
	var dz: float = target.z - origin.z
	if (dx * dx + dz * dz) > 1e-6:
		return atan2(-dx, -dz)
	return 0.0


static func _move_toward_xz(origin: Vector3, target: Vector3, stop_r: float) -> Vector2:
	var d := Vector2(target.x - origin.x, target.z - origin.z)
	var lsq: float = d.length_squared()
	if lsq <= (stop_r * stop_r) or lsq <= 1e-8:
		return Vector2.ZERO
	return d / sqrt(lsq)


static func _world_to_local(world_xz: Vector2, ref_yaw: float) -> Vector2:
	if world_xz.length_squared() <= 1e-8:
		return Vector2.ZERO
	var fwd := Vector2(-sin(ref_yaw), -cos(ref_yaw))
	var right := Vector2(cos(ref_yaw), -sin(ref_yaw))
	var v := Vector2(world_xz.dot(right), world_xz.dot(fwd))
	return v.normalized() if v.length_squared() > 1.0001 else v
