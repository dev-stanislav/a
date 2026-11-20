class_name ShotClock
extends Node
## Canonical 24-second Shot Clock component stepping deterministically at 60 Hz.

signal shot_clock_expired(offending_team: int)
signal shot_clock_reset(new_seconds: float)

const DEFAULT_SECONDS: float = 24.0
const OFFENSIVE_REBOUND_SECONDS: float = 14.0

@export var max_seconds: float = DEFAULT_SECONDS
var time_left: float = DEFAULT_SECONDS
var is_running: bool = true
var paused: bool = false


func _ready() -> void:
	time_left = max_seconds


func reset_clock(custom_seconds: float = -1.0) -> void:
	if custom_seconds > 0.0:
		time_left = custom_seconds
	else:
		time_left = max_seconds
	paused = false
	shot_clock_reset.emit(time_left)


func reset_offensive_rebound() -> void:
	time_left = maxf(time_left, OFFENSIVE_REBOUND_SECONDS)
	paused = false
	shot_clock_reset.emit(time_left)


func step_clock(dt: float, possessing_team: int = 0) -> bool:
	if not is_running or paused:
		return false
	if time_left <= 0.0:
		return false

	time_left = maxf(0.0, time_left - dt)
	if time_left <= 0.0:
		shot_clock_expired.emit(possessing_team)
		return true
	return false
