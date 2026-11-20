class_name StaminaComponent
extends Node
## Manages player stamina pool (0..max_stamina), action drain (sprint, dribble moves, jumps,
## steals, blocks, dunks), Zone +25% stamina efficiency (0.75x cost_multiplier),
## walking/idle regeneration, exhaustion (< 20.0) speed/shot penalties, and telemetry at 60 Hz.

const EXHAUSTED_THRESHOLD: float = 20.0

const COST_DRIBBLE_MOVE: float = 9.0
const COST_JUMP: float = 7.0
const COST_STEAL: float = 7.0
const COST_BLOCK: float = 9.0
const COST_DUNK: float = 18.0

var owner_player_id: int = 1
var max_stamina: float = 100.0
var current_stamina: float = 100.0
var sprint_drain_per_sec: float = 15.0
var regen_per_sec: float = 20.0
var regen_delay_sec: float = 0.50
var cost_multiplier: float = 1.0 # 0.75 while in Zone (+25% stamina efficiency), 1.0 baseline

var _regen_cooldown: float = 0.0
var _zero_depleted_lock: bool = false
var _last_emitted_stamina: float = -1.0


func setup(player_id: int, max_val: float = 100.0, regen_rate: float = 20.0) -> void:
	owner_player_id = player_id
	max_stamina = maxf(10.0, max_val)
	regen_per_sec = maxf(1.0, regen_rate)
	current_stamina = max_stamina
	cost_multiplier = 1.0
	_zero_depleted_lock = false
	_regen_cooldown = 0.0
	_emit_if_needed(true)


func set_cost_multiplier(mult: float) -> void:
	cost_multiplier = clampf(mult, 0.1, 2.0)


func is_exhausted() -> bool:
	return current_stamina < EXHAUSTED_THRESHOLD


func can_sprint() -> bool:
	if _zero_depleted_lock:
		return false
	return current_stamina > 1.0


func has_stamina(amount: float, apply_cost_mult: bool = true) -> bool:
	var eff: float = amount * (cost_multiplier if apply_cost_mult else 1.0)
	return current_stamina >= eff


func get_speed_multiplier() -> float:
	if is_exhausted():
		return 0.78
	return 1.0


func get_shot_variance_penalty() -> float:
	if is_exhausted():
		var severity: float = clampf((EXHAUSTED_THRESHOLD - current_stamina) / EXHAUSTED_THRESHOLD, 0.25, 1.0)
		return 0.18 * severity
	return 0.0


func consume(amount: float, allow_partial: bool = false, already_discounted: bool = false) -> bool:
	if amount <= 0.0:
		return true
	var eff_amount: float = amount if already_discounted else (amount * cost_multiplier)
	if current_stamina < eff_amount and not allow_partial:
		return false
	current_stamina = maxf(0.0, current_stamina - eff_amount)
	_regen_cooldown = regen_delay_sec
	if current_stamina <= 0.5:
		_zero_depleted_lock = true
	_emit_if_needed(true)
	return true


func set_stamina(value: float) -> void:
	current_stamina = clampf(value, 0.0, max_stamina)
	if current_stamina <= 0.5:
		_zero_depleted_lock = true
	elif current_stamina >= EXHAUSTED_THRESHOLD:
		_zero_depleted_lock = false
	_emit_if_needed(true)


func step_stamina(dt: float, is_sprinting: bool) -> void:
	if is_sprinting and can_sprint():
		var eff_drain: float = sprint_drain_per_sec * cost_multiplier
		current_stamina = maxf(0.0, current_stamina - eff_drain * dt)
		_regen_cooldown = regen_delay_sec
		if current_stamina <= 0.5:
			_zero_depleted_lock = true
	else:
		if _regen_cooldown > 0.0:
			_regen_cooldown = maxf(0.0, _regen_cooldown - dt)
		else:
			current_stamina = minf(max_stamina, current_stamina + regen_per_sec * dt)
			if _zero_depleted_lock and current_stamina >= 12.0:
				_zero_depleted_lock = false

	_emit_if_needed(false)


func reset_stamina() -> void:
	current_stamina = max_stamina
	cost_multiplier = 1.0
	_regen_cooldown = 0.0
	_zero_depleted_lock = false
	_emit_if_needed(true)


func export_state() -> Dictionary:
	return {
		"current": current_stamina,
		"max": max_stamina,
		"cost_multiplier": cost_multiplier,
		"regen_cooldown": _regen_cooldown,
		"zero_depleted_lock": _zero_depleted_lock,
	}


func import_state(state: Dictionary) -> void:
	max_stamina = float(state.get("max", max_stamina))
	current_stamina = clampf(float(state.get("current", current_stamina)), 0.0, max_stamina)
	cost_multiplier = clampf(float(state.get("cost_multiplier", 1.0)), 0.1, 2.0)
	_regen_cooldown = float(state.get("regen_cooldown", 0.0))
	_zero_depleted_lock = bool(state.get("zero_depleted_lock", state.get("exhausted", false)))
	_emit_if_needed(true)


func _emit_if_needed(force: bool) -> void:
	if force or absf(current_stamina - _last_emitted_stamina) >= 0.4:
		_last_emitted_stamina = current_stamina
		EventBus.stamina_updated.emit(owner_player_id, current_stamina, max_stamina)
