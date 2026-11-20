class_name FrameData
extends RefCounted
## Frame-accurate fighting-game move definition for PHANTOM COURT ONLINE (60 Hz).
## Encapsulates startup/active/recovery phases, cancel windows, animation priority,
## input sequence timing windows, perfect-timing thresholds, resource costs,
## chain permissions, archetype scoping, and gameplay parameters.

enum Priority {
	NORMAL = 10,
	DRIBBLE = 20,
	SPECIAL = 40,
	CHAIN_FINISHER = 55,
	ULTIMATE = 70,
}

const NORMAL: int = Priority.NORMAL
const DRIBBLE: int = Priority.DRIBBLE
const SPECIAL: int = Priority.SPECIAL
const CHAIN_FINISHER: int = Priority.CHAIN_FINISHER
const ULTIMATE: int = Priority.ULTIMATE

const PRIORITY_NORMAL: int = Priority.NORMAL
const PRIORITY_DRIBBLE: int = Priority.DRIBBLE
const PRIORITY_SPECIAL: int = Priority.SPECIAL
const PRIORITY_CHAIN_FINISHER: int = Priority.CHAIN_FINISHER
const PRIORITY_ULTIMATE: int = Priority.ULTIMATE

var id: String = ""
var display_name: String = ""
var sequence: Array[String] = []

var startup_frames: int = 4
var active_frames: int = 12
var recovery_frames: int = 10
var cancel_window_start: int = 0
var cancel_window_end: int = 0
var cooldown_frames: int = 0

var priority: int = PRIORITY_NORMAL
var step_window_frames: int = 14
var perfect_gap_min: int = 4
var perfect_gap_max: int = 9

var stamina_cost: float = 0.0
var zone_gain: float = 0.0
var requires_ball: bool = true
var requires_grounded: bool = false
var max_rim_distance: float = 0.0

var can_chain_from: Array[String] = []
var archetype_id: String = ""
var tier: int = 1
var gameplay_params: Dictionary = {}


func _init(config: Dictionary = {}) -> void:
	if not config.is_empty():
		configure(config)


func configure(config: Dictionary) -> FrameData:
	id = str(config.get("id", id))
	display_name = str(config.get("display_name", display_name if not display_name.is_empty() else id))

	if config.has("sequence") and config["sequence"] is Array:
		sequence.clear()
		for item in (config["sequence"] as Array):
			sequence.append(str(item))

	startup_frames = maxi(0, int(config.get("startup_frames", startup_frames)))
	active_frames = maxi(0, int(config.get("active_frames", active_frames)))
	recovery_frames = maxi(0, int(config.get("recovery_frames", recovery_frames)))
	cancel_window_start = maxi(0, int(config.get("cancel_window_start", cancel_window_start)))
	cancel_window_end = maxi(0, int(config.get("cancel_window_end", cancel_window_end)))
	cooldown_frames = maxi(0, int(config.get("cooldown_frames", cooldown_frames)))

	priority = int(config.get("priority", priority))
	step_window_frames = maxi(1, int(config.get("step_window_frames", step_window_frames)))
	perfect_gap_min = maxi(0, int(config.get("perfect_gap_min", perfect_gap_min)))
	perfect_gap_max = maxi(perfect_gap_min, int(config.get("perfect_gap_max", perfect_gap_max)))

	stamina_cost = maxf(0.0, float(config.get("stamina_cost", stamina_cost)))
	zone_gain = maxf(0.0, float(config.get("zone_gain", zone_gain)))
	requires_ball = bool(config.get("requires_ball", requires_ball))
	requires_grounded = bool(config.get("requires_grounded", requires_grounded))

	if config.has("gameplay_params") and config["gameplay_params"] is Dictionary:
		gameplay_params = (config["gameplay_params"] as Dictionary).duplicate(true)

	if config.has("max_rim_distance"):
		max_rim_distance = maxf(0.0, float(config["max_rim_distance"]))
	elif gameplay_params.has("max_rim_dist"):
		max_rim_distance = maxf(0.0, float(gameplay_params["max_rim_dist"]))

	if config.has("can_chain_from") and config["can_chain_from"] is Array:
		can_chain_from.clear()
		for prev_id in (config["can_chain_from"] as Array):
			can_chain_from.append(str(prev_id))

	archetype_id = str(config.get("archetype_id", archetype_id))
	tier = int(config.get("tier", compute_default_tier(priority)))
	return self


static func from_dict(data: Dictionary) -> FrameData:
	return FrameData.new(data)


static func compute_default_tier(prio: int) -> int:
	if prio >= PRIORITY_ULTIMATE:
		return 4
	if prio >= PRIORITY_CHAIN_FINISHER:
		return 3
	if prio >= PRIORITY_SPECIAL:
		return 2
	return 1


func total_frames() -> int:
	return maxi(0, startup_frames) + maxi(0, active_frames) + maxi(0, recovery_frames)


func is_in_startup(frame: int) -> bool:
	return frame >= 0 and frame < startup_frames


func is_in_active(frame: int) -> bool:
	return frame >= startup_frames and frame < (startup_frames + active_frames)


func is_in_recovery(frame: int) -> bool:
	return frame >= (startup_frames + active_frames) and frame < total_frames()


func has_cancel_window() -> bool:
	return cancel_window_end > 0 and cancel_window_start >= 0 and cancel_window_end >= cancel_window_start


func is_in_cancel_window(frame: int, extra_cancel_frames: int = 0) -> bool:
	if not has_cancel_window():
		return false
	var total: int = total_frames()
	if total <= 0:
		return false
	var ext: int = maxi(0, extra_cancel_frames)
	var effective_end: int = mini(total - 1, cancel_window_end + ext)
	return frame >= cancel_window_start and frame <= effective_end


func get_phase(frame: int) -> String:
	if is_in_startup(frame):
		return "startup"
	if is_in_active(frame):
		return "active"
	if is_in_recovery(frame):
		return "recovery"
	return "idle"


func can_chain_after(previous_move_id: String) -> bool:
	if previous_move_id.is_empty():
		return false
	return can_chain_from.has(previous_move_id) or can_chain_from.has("*") or can_chain_from.has("any")


func is_valid_for_archetype(query_archetype_id: String) -> bool:
	return archetype_id.is_empty() or archetype_id == query_archetype_id


func get_param(key: String, default_val: Variant = null) -> Variant:
	return gameplay_params.get(key, default_val)


func to_dict() -> Dictionary:
	var seq_copy: Array[String] = []
	for s in sequence:
		seq_copy.append(s)

	var chain_copy: Array[String] = []
	for c in can_chain_from:
		chain_copy.append(c)

	return {
		"id": id,
		"display_name": display_name,
		"sequence": seq_copy,
		"startup_frames": startup_frames,
		"active_frames": active_frames,
		"recovery_frames": recovery_frames,
		"total_frames": total_frames(),
		"cancel_window_start": cancel_window_start,
		"cancel_window_end": cancel_window_end,
		"cooldown_frames": cooldown_frames,
		"priority": priority,
		"tier": tier,
		"step_window_frames": step_window_frames,
		"perfect_gap_min": perfect_gap_min,
		"perfect_gap_max": perfect_gap_max,
		"stamina_cost": stamina_cost,
		"zone_gain": zone_gain,
		"requires_ball": requires_ball,
		"requires_grounded": requires_grounded,
		"max_rim_distance": max_rim_distance,
		"can_chain_from": chain_copy,
		"archetype_id": archetype_id,
		"gameplay_params": gameplay_params.duplicate(true),
	}
