class_name ZoneComponent
extends Node
## Balanced Time-Limited Zone Awakening System (Phase 5).
## - Meter: 0.0 .. 100.0 (activation_threshold = 100.0, duration = 12.0s)
## - Zero passive regeneration & STRICTLY zero energy gain while is_active == true
## - Positive-play accrual scaled by archetype zone_gain_mult
## - Buffs while active: +15% speed (1.15x), +20% jump/block reach (1.20x), +25% stamina efficiency (0.75x cost)
## - Clean baseline restoration & EventBus.zone_ended emission when timer expires.

const MAX_ENERGY: float = 100.0
const ACTIVATION_THRESHOLD: float = 100.0
const DEFAULT_DURATION: float = 12.0

# Canonical positive-play base accrual awards
const GAIN_2PT_BASKET: float = 18.0
const GAIN_3PT_BASKET: float = 24.0
const GAIN_PERFECT_TIMING: float = 10.0
const GAIN_BLOCK: float = 22.0
const GAIN_STEAL: float = 22.0
const GAIN_ANKLE_BREAK: float = 20.0
const GAIN_ASSIST: float = 15.0

# Canonical Phase 5 Zone gameplay buff multipliers
const ZONE_SPEED_MULT: float = 1.15
const ZONE_JUMP_MULT: float = 1.20
const ZONE_BLOCK_REACH_MULT: float = 1.20
const ZONE_STAMINA_COST_MULT: float = 0.75

var owner_player_id: int = 1
var max_energy: float = MAX_ENERGY
var activation_threshold: float = ACTIVATION_THRESHOLD
var current_energy: float = 0.0
var zone_duration: float = DEFAULT_DURATION
var time_remaining: float = 0.0
var gain_rate_mult: float = 1.0
var is_active: bool = false
var activations_count: int = 0

# Backward-compatible property aliases used by Phases 1–4
var max_zone: float:
	get:
		return max_energy
	set(val):
		max_energy = maxf(10.0, val)

var current_zone: float:
	get:
		return current_energy
	set(val):
		current_energy = clampf(val, 0.0, max_energy)

var zone_time_left: float:
	get:
		return time_remaining
	set(val):
		time_remaining = maxf(0.0, val)

var _last_emitted_energy: float = -1.0


func setup(player_id: int, max_val: float = MAX_ENERGY, gain_mult: float = 1.0) -> void:
	owner_player_id = player_id
	max_energy = maxf(10.0, max_val)
	activation_threshold = max_energy
	gain_rate_mult = maxf(0.1, gain_mult)
	current_energy = 0.0
	time_remaining = 0.0
	is_active = false
	activations_count = 0
	_emit_if_needed(true)


## Accrues Zone energy from positive plays ONLY when NOT currently in Zone.
## Returns the actual energy delta added (strictly 0.0 while is_active == true).
func add_charge(amount: float) -> float:
	if is_active or amount <= 0.0:
		return 0.0
	var prev: float = current_energy
	current_energy = clampf(current_energy + amount * gain_rate_mult, 0.0, max_energy)
	var added: float = current_energy - prev
	if added > 0.0:
		_emit_if_needed(false)
	return added


func add_energy(amount: float) -> float:
	return add_charge(amount)


func award_positive_play(play_type: String) -> float:
	if is_active:
		return 0.0
	var base_amount: float = 0.0
	match play_type.strip_edges().to_lower():
		"basket_2pt", "2pt":
			base_amount = GAIN_2PT_BASKET
		"basket_3pt", "3pt":
			base_amount = GAIN_3PT_BASKET
		"perfect_shot", "perfect_combo", "perfect_timing":
			base_amount = GAIN_PERFECT_TIMING
		"block":
			base_amount = GAIN_BLOCK
		"steal":
			base_amount = GAIN_STEAL
		"ankle_break":
			base_amount = GAIN_ANKLE_BREAK
		"assist", "mirage_pass":
			base_amount = GAIN_ASSIST
		_:
			return 0.0
	return add_charge(base_amount)


func set_energy(value: float) -> void:
	if is_active:
		return
	current_energy = clampf(value, 0.0, max_energy)
	_emit_if_needed(true)


func can_activate() -> bool:
	return (not is_active) and (current_energy >= activation_threshold - 0.001)


func activate_zone() -> bool:
	if not can_activate():
		return false
	is_active = true
	time_remaining = zone_duration
	current_energy = max_energy
	activations_count += 1
	EventBus.zone_activated.emit(owner_player_id, zone_duration)
	_emit_if_needed(true)
	return true


func try_activate() -> bool:
	return activate_zone()


func force_activate(duration: float = DEFAULT_DURATION) -> void:
	is_active = true
	zone_duration = maxf(0.5, duration)
	time_remaining = zone_duration
	current_energy = max_energy
	activations_count += 1
	EventBus.zone_activated.emit(owner_player_id, zone_duration)
	_emit_if_needed(true)


func deactivate_zone() -> void:
	if not is_active:
		return
	is_active = false
	time_remaining = 0.0
	current_energy = 0.0
	_emit_if_needed(true)
	EventBus.zone_ended.emit(owner_player_id)


func step_zone(dt: float) -> void:
	# Zero passive regeneration when inactive!
	if not is_active:
		return

	var drain_rate: float = max_energy / maxf(0.01, zone_duration)
	time_remaining = maxf(0.0, time_remaining - dt)
	current_energy = maxf(0.0, current_energy - drain_rate * dt)
	_emit_if_needed(false)

	if time_remaining <= 0.0 or current_energy <= 0.0001:
		deactivate_zone()


func reset_zone() -> void:
	var was_active: bool = is_active
	is_active = false
	time_remaining = 0.0
	current_energy = 0.0
	activations_count = 0
	_emit_if_needed(true)
	if was_active:
		EventBus.zone_ended.emit(owner_player_id)


func get_speed_multiplier() -> float:
	return ZONE_SPEED_MULT if is_active else 1.0


func get_jump_multiplier() -> float:
	return ZONE_JUMP_MULT if is_active else 1.0


func get_block_reach_multiplier() -> float:
	return ZONE_BLOCK_REACH_MULT if is_active else 1.0


func get_stamina_cost_multiplier() -> float:
	return ZONE_STAMINA_COST_MULT if is_active else 1.0


func get_shot_quality_bonus() -> float:
	return 0.12 if is_active else 0.0


func export_state() -> Dictionary:
	return {
		"current_energy": current_energy,
		"current": current_energy,
		"max_energy": max_energy,
		"max": max_energy,
		"activation_threshold": activation_threshold,
		"is_active": is_active,
		"time_remaining": time_remaining,
		"time_left": time_remaining,
		"duration": zone_duration,
		"gain_rate_mult": gain_rate_mult,
		"activations_count": activations_count,
	}


func import_state(state: Dictionary) -> void:
	max_energy = float(state.get("max_energy", state.get("max", max_energy)))
	activation_threshold = float(state.get("activation_threshold", max_energy))
	current_energy = clampf(float(state.get("current_energy", state.get("current", 0.0))), 0.0, max_energy)
	is_active = bool(state.get("is_active", false))
	time_remaining = maxf(0.0, float(state.get("time_remaining", state.get("time_left", 0.0))))
	zone_duration = maxf(0.5, float(state.get("duration", zone_duration)))
	gain_rate_mult = maxf(0.1, float(state.get("gain_rate_mult", gain_rate_mult)))
	activations_count = int(state.get("activations_count", activations_count))
	_emit_if_needed(true)


func _emit_if_needed(force: bool) -> void:
	if force or absf(current_energy - _last_emitted_energy) >= 0.4:
		_last_emitted_energy = current_energy
		EventBus.zone_meter_updated.emit(owner_player_id, current_energy, max_energy)
