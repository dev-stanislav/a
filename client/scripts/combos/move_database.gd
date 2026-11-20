class_name MoveDatabase
extends RefCounted
## Canonical fighting-game move & frame-data registry for PHANTOM COURT ONLINE.
## Registers all 4 mandatory signature combos (Phantom Drive, Meteor Dunk,
## Ankle Breaker, Mirror Step), all 5 cancelable basic dribble normals
## (crossover, behind_the_back, spin, stepback, hesitation), and supports
## dynamic registration of Phase 4 archetype-specific signature skills.

const MOVE_PHANTOM_DRIVE := "phantom_drive"
const MOVE_METEOR_DUNK := "meteor_dunk"
const MOVE_ANKLE_BREAKER := "ankle_breaker"
const MOVE_MIRROR_STEP := "mirror_step"

# Phase 4 Archetype-Scoped Unique Class Skills
const MOVE_VOLT_DASH := "volt_dash"
const MOVE_STARLIGHT_HIGH_ARC := "starlight_high_arc"
const MOVE_MIRAGE_THREAD := "mirage_thread"
const MOVE_TECTONIC_SLAM := "tectonic_slam"
const MOVE_ECLIPSE_COUNTER := "eclipse_counter"

const MOVE_CROSSOVER := "crossover"
const MOVE_BEHIND_THE_BACK := "behind_the_back"
const MOVE_SPIN := "spin"
const MOVE_STEPBACK := "stepback"
const MOVE_HESITATION := "hesitation"

var _moves: Dictionary = {} # move_id: String -> FrameData
var _sorted_combo_cache: Array[FrameData] = []
var _cache_dirty: bool = true


func _init(register_defaults: bool = true) -> void:
	if register_defaults:
		register_default_moves()


func clear() -> void:
	_moves.clear()
	_sorted_combo_cache.clear()
	_cache_dirty = true


func register_default_moves() -> void:
	# ==========================================================================
	# 1. Four Mandatory Universal Signature Combos (Phase 3)
	# ==========================================================================

	# Phantom Drive: Q -> E -> Q -> Shift
	register_move(FrameData.new({
		"id": MOVE_PHANTOM_DRIVE,
		"display_name": "Phantom Drive",
		"sequence": ["Q", "E", "Q", "Shift"],
		"startup_frames": 4,
		"active_frames": 18,
		"recovery_frames": 10,
		"cancel_window_start": 12,
		"cancel_window_end": 22,
		"cooldown_frames": 180, # 3.0s @ 60 Hz
		"priority": FrameData.PRIORITY_SPECIAL, # 40
		"step_window_frames": 14,
		"perfect_gap_min": 4,
		"perfect_gap_max": 9,
		"stamina_cost": 16.0,
		"zone_gain": 12.0,
		"requires_ball": true,
		"requires_grounded": false,
		"can_chain_from": [
			MOVE_CROSSOVER,
			MOVE_BEHIND_THE_BACK,
			MOVE_SPIN,
			MOVE_STEPBACK,
			MOVE_HESITATION,
			MOVE_ANKLE_BREAKER,
			MOVE_MIRROR_STEP,
		],
		"archetype_id": "",
		"gameplay_params": {
			"dash_speed": 13.5,
			"duration": 0.30,
			"steal_immune": true,
			"pass_through_defender": true,
		},
	}))

	# Meteor Dunk: Shift -> W -> Space -> R (Ultimate)
	register_move(FrameData.new({
		"id": MOVE_METEOR_DUNK,
		"display_name": "Meteor Dunk",
		"sequence": ["Shift", "W", "Space", "R"],
		"startup_frames": 6,
		"active_frames": 28,
		"recovery_frames": 16,
		"cancel_window_start": 0,
		"cancel_window_end": 0,
		"cooldown_frames": 300, # 5.0s @ 60 Hz
		"priority": FrameData.PRIORITY_ULTIMATE, # 70
		"step_window_frames": 14,
		"perfect_gap_min": 4,
		"perfect_gap_max": 9,
		"stamina_cost": 24.0,
		"zone_gain": 18.0,
		"requires_ball": true,
		"requires_grounded": false,
		"max_rim_distance": 5.5,
		"can_chain_from": [
			MOVE_CROSSOVER,
			MOVE_BEHIND_THE_BACK,
			MOVE_SPIN,
			MOVE_STEPBACK,
			MOVE_HESITATION,
			MOVE_PHANTOM_DRIVE,
			MOVE_ANKLE_BREAKER,
			MOVE_MIRROR_STEP,
		],
		"archetype_id": "",
		"gameplay_params": {
			"max_rim_dist": 5.5,
			"apex_height": 4.15,
			"shockwave_radius": 3.5,
			"dunk_power": 1.5,
		},
	}))

	# Ankle Breaker: E -> Q -> E -> LMB
	register_move(FrameData.new({
		"id": MOVE_ANKLE_BREAKER,
		"display_name": "Ankle Breaker",
		"sequence": ["E", "Q", "E", "LMB"],
		"startup_frames": 5,
		"active_frames": 14,
		"recovery_frames": 12,
		"cancel_window_start": 10,
		"cancel_window_end": 19,
		"cooldown_frames": 210, # 3.5s @ 60 Hz
		"priority": 45,
		"step_window_frames": 14,
		"perfect_gap_min": 4,
		"perfect_gap_max": 9,
		"stamina_cost": 14.0,
		"zone_gain": 14.0,
		"requires_ball": true,
		"requires_grounded": false,
		"can_chain_from": [
			MOVE_CROSSOVER,
			MOVE_BEHIND_THE_BACK,
			MOVE_SPIN,
			MOVE_STEPBACK,
			MOVE_HESITATION,
			MOVE_PHANTOM_DRIVE,
			MOVE_MIRROR_STEP,
		],
		"archetype_id": "",
		"gameplay_params": {
			"balance_damage": 110.0,
			"cone_range": 2.8,
			"gather_shot_bonus": 0.14,
		},
	}))

	# Mirror Step: Q -> Q -> E -> R
	register_move(FrameData.new({
		"id": MOVE_MIRROR_STEP,
		"display_name": "Mirror Step",
		"sequence": ["Q", "Q", "E", "R"],
		"startup_frames": 4,
		"active_frames": 16,
		"recovery_frames": 10,
		"cancel_window_start": 12,
		"cancel_window_end": 20,
		"cooldown_frames": 180, # 3.0s @ 60 Hz
		"priority": 50,
		"step_window_frames": 14,
		"perfect_gap_min": 4,
		"perfect_gap_max": 9,
		"stamina_cost": 14.0,
		"zone_gain": 12.0,
		"requires_ball": true,
		"requires_grounded": false,
		"can_chain_from": [
			MOVE_CROSSOVER,
			MOVE_BEHIND_THE_BACK,
			MOVE_SPIN,
			MOVE_STEPBACK,
			MOVE_HESITATION,
			MOVE_PHANTOM_DRIVE,
			MOVE_ANKLE_BREAKER,
		],
		"archetype_id": "",
		"gameplay_params": {
			"feint_forward": 0.65,
			"stepback_dist": 3.2,
			"lateral_offset": 1.1,
			"shot_window_bonus": 0.15,
		},
	}))

	# ==========================================================================
	# 2. Five Cancelable Basic Dribble Normals (Context-Triggered Frame Windows)
	# ==========================================================================

	var normal_chain_sources: Array[String] = [
		MOVE_CROSSOVER,
		MOVE_BEHIND_THE_BACK,
		MOVE_SPIN,
		MOVE_STEPBACK,
		MOVE_HESITATION,
		MOVE_MIRROR_STEP,
	]

	register_move(FrameData.new({
		"id": MOVE_CROSSOVER,
		"display_name": "Crossover",
		"sequence": [],
		"startup_frames": 3,
		"active_frames": 10,
		"recovery_frames": 7,
		"cancel_window_start": 5,
		"cancel_window_end": 14,
		"cooldown_frames": 12,
		"priority": FrameData.PRIORITY_DRIBBLE, # 20
		"stamina_cost": 9.0,
		"zone_gain": 6.0,
		"requires_ball": true,
		"can_chain_from": normal_chain_sources,
		"archetype_id": "",
		"gameplay_params": {
			"burst_speed": 10.6,
			"duration": 0.22,
		},
	}))

	register_move(FrameData.new({
		"id": MOVE_BEHIND_THE_BACK,
		"display_name": "Behind-the-Back",
		"sequence": [],
		"startup_frames": 4,
		"active_frames": 10,
		"recovery_frames": 8,
		"cancel_window_start": 6,
		"cancel_window_end": 15,
		"cooldown_frames": 13,
		"priority": FrameData.PRIORITY_DRIBBLE, # 20
		"stamina_cost": 9.0,
		"zone_gain": 6.0,
		"requires_ball": true,
		"can_chain_from": normal_chain_sources,
		"archetype_id": "",
		"gameplay_params": {
			"burst_speed": 10.2,
			"duration": 0.23,
			"steal_shield": 0.38,
		},
	}))

	register_move(FrameData.new({
		"id": MOVE_SPIN,
		"display_name": "Spin Move",
		"sequence": [],
		"startup_frames": 4,
		"active_frames": 12,
		"recovery_frames": 8,
		"cancel_window_start": 8,
		"cancel_window_end": 17,
		"cooldown_frames": 16,
		"priority": FrameData.PRIORITY_DRIBBLE, # 20
		"stamina_cost": 9.0,
		"zone_gain": 6.0,
		"requires_ball": true,
		"can_chain_from": normal_chain_sources,
		"archetype_id": "",
		"gameplay_params": {
			"burst_speed": 10.4,
			"duration": 0.26,
			"steal_shield": 0.34,
		},
	}))

	register_move(FrameData.new({
		"id": MOVE_STEPBACK,
		"display_name": "Stepback",
		"sequence": [],
		"startup_frames": 3,
		"active_frames": 10,
		"recovery_frames": 7,
		"cancel_window_start": 6,
		"cancel_window_end": 14,
		"cooldown_frames": 14,
		"priority": FrameData.PRIORITY_DRIBBLE, # 20
		"stamina_cost": 9.0,
		"zone_gain": 6.0,
		"requires_ball": true,
		"can_chain_from": [
			MOVE_CROSSOVER,
			MOVE_BEHIND_THE_BACK,
			MOVE_SPIN,
			MOVE_STEPBACK,
			MOVE_HESITATION,
			MOVE_ANKLE_BREAKER,
			MOVE_MIRROR_STEP,
		],
		"archetype_id": "",
		"gameplay_params": {
			"burst_speed": 9.6,
			"duration": 0.21,
			"gather_window": 0.75,
		},
	}))

	register_move(FrameData.new({
		"id": MOVE_HESITATION,
		"display_name": "Hesitation",
		"sequence": [],
		"startup_frames": 4,
		"active_frames": 12,
		"recovery_frames": 8,
		"cancel_window_start": 6,
		"cancel_window_end": 17,
		"cooldown_frames": 16,
		"priority": FrameData.PRIORITY_DRIBBLE, # 20
		"stamina_cost": 9.0,
		"zone_gain": 6.0,
		"requires_ball": true,
		"can_chain_from": normal_chain_sources,
		"archetype_id": "",
		"gameplay_params": {
			"stutter_speed": 1.8,
			"burst_speed": 11.4,
			"duration": 0.28,
		},
	}))

	# ==========================================================================
	# 3. Five Archetype-Scoped Unique Class Skills (Phase 4)
	# ==========================================================================
	var universal_chain_sources: Array[String] = [
		MOVE_CROSSOVER,
		MOVE_BEHIND_THE_BACK,
		MOVE_SPIN,
		MOVE_STEPBACK,
		MOVE_HESITATION,
		MOVE_PHANTOM_DRIVE,
		MOVE_ANKLE_BREAKER,
		MOVE_MIRROR_STEP,
	]

	# Speedster (Kaelen "Volt" Arashi): Volt Dash — Q, Shift, Q
	register_move(FrameData.new({
		"id": MOVE_VOLT_DASH,
		"display_name": "Volt Dash",
		"sequence": ["Q", "Shift", "Q"],
		"startup_frames": 3,
		"active_frames": 15,
		"recovery_frames": 8,
		"cancel_window_start": 9,
		"cancel_window_end": 18,
		"cooldown_frames": 150, # 2.5s @ 60 Hz
		"priority": FrameData.PRIORITY_CHAIN_FINISHER, # 55
		"step_window_frames": 14,
		"perfect_gap_min": 4,
		"perfect_gap_max": 9,
		"stamina_cost": 10.0,
		"zone_gain": 12.0,
		"requires_ball": true,
		"requires_grounded": false,
		"can_chain_from": universal_chain_sources,
		"archetype_id": "speedster",
		"gameplay_params": {
			"dash_speed": 15.0,
			"duration": 0.24,
			"zigzag_split_ratio": 0.45,
			"lateral_cut_weight": 0.62,
			"steal_immune": true,
			"pass_through_defender": true,
			"anim_action": "volt_dash",
		},
	}))

	# Sharpshooter (Sora "Deadeye" Hoshino): Starlight High Arc — E, S, LMB
	register_move(FrameData.new({
		"id": MOVE_STARLIGHT_HIGH_ARC,
		"display_name": "Starlight High Arc",
		"sequence": ["E", "S", "LMB"],
		"startup_frames": 4,
		"active_frames": 20,
		"recovery_frames": 10,
		"cancel_window_start": 0,
		"cancel_window_end": 0,
		"cooldown_frames": 210, # 3.5s @ 60 Hz
		"priority": 60,
		"step_window_frames": 14,
		"perfect_gap_min": 4,
		"perfect_gap_max": 9,
		"stamina_cost": 15.0,
		"zone_gain": 14.0,
		"requires_ball": true,
		"requires_grounded": false,
		"max_rim_distance": 9.8,
		"can_chain_from": universal_chain_sources,
		"archetype_id": "sharpshooter",
		"gameplay_params": {
			"max_rim_dist": 9.8,
			"arc_height": 5.8,
			"fade_dist": 1.35,
			"fade_duration": 0.16,
			"quality_bonus": 0.18,
			"block_resistance": 0.18,
			"spin_rate": 20.0,
			"anim_action": "starlight_high_arc",
		},
	}))

	# Playmaker (Ren "Mirage" Kisaragi): Mirage Thread — Q, E, RMB
	register_move(FrameData.new({
		"id": MOVE_MIRAGE_THREAD,
		"display_name": "Mirage Thread",
		"sequence": ["Q", "E", "RMB"],
		"startup_frames": 4,
		"active_frames": 14,
		"recovery_frames": 10,
		"cancel_window_start": 10,
		"cancel_window_end": 18,
		"cooldown_frames": 180, # 3.0s @ 60 Hz
		"priority": FrameData.PRIORITY_CHAIN_FINISHER, # 55
		"step_window_frames": 14,
		"perfect_gap_min": 4,
		"perfect_gap_max": 9,
		"stamina_cost": 12.0,
		"zone_gain": 14.0,
		"requires_ball": true,
		"requires_grounded": false,
		"can_chain_from": universal_chain_sources,
		"archetype_id": "playmaker",
		"gameplay_params": {
			"pass_speed_mult": 1.35,
			"base_pass_speed": 15.0,
			"teammate_zone_grant": 12.0,
			"teammate_shot_bonus": 0.15,
			"teammate_shot_bonus_duration": 1.5,
			"solo_dash_speed": 12.8,
			"solo_dash_duration": 0.26,
			"steal_immune": true,
			"anim_action": "mirage_thread",
		},
	}))

	# Powerhouse (Daisuke "Titan" Kurogane): Tectonic Slam — Shift, Space, LMB
	register_move(FrameData.new({
		"id": MOVE_TECTONIC_SLAM,
		"display_name": "Tectonic Slam",
		"sequence": ["Shift", "Space", "LMB"],
		"startup_frames": 5,
		"active_frames": 26,
		"recovery_frames": 15,
		"cancel_window_start": 0,
		"cancel_window_end": 0,
		"cooldown_frames": 270, # 4.5s @ 60 Hz
		"priority": 68,
		"step_window_frames": 14,
		"perfect_gap_min": 4,
		"perfect_gap_max": 9,
		"stamina_cost": 22.0,
		"zone_gain": 16.0,
		"requires_ball": true,
		"requires_grounded": false,
		"max_rim_distance": 4.2,
		"can_chain_from": universal_chain_sources,
		"archetype_id": "powerhouse",
		"gameplay_params": {
			"max_rim_dist": 4.2,
			"apex_height": 3.85,
			"shockwave_radius": 4.2,
			"balance_damage": 135.0,
			"dunk_power": 1.65,
			"armored": true,
			"dunk_duration_frames": 24,
			"anim_action": "tectonic_slam",
		},
	}))

	# All-Rounder (Akira "Eclipse" Shinohara): Eclipse Counter — C, Q, E, Shift (on-ball OR off-ball!)
	register_move(FrameData.new({
		"id": MOVE_ECLIPSE_COUNTER,
		"display_name": "Eclipse Counter",
		"sequence": ["C", "Q", "E", "Shift"],
		"startup_frames": 4,
		"active_frames": 18,
		"recovery_frames": 10,
		"cancel_window_start": 10,
		"cancel_window_end": 22,
		"cooldown_frames": 180, # 3.0s @ 60 Hz
		"priority": 58,
		"step_window_frames": 14,
		"perfect_gap_min": 4,
		"perfect_gap_max": 9,
		"stamina_cost": 13.0,
		"zone_gain": 14.0,
		"requires_ball": false,
		"requires_grounded": false,
		"can_chain_from": universal_chain_sources,
		"archetype_id": "all_rounder",
		"gameplay_params": {
			"offense_dash_speed": 12.6,
			"offense_duration": 0.28,
			"offense_steal_shield": 0.45,
			"offense_shot_bonus": 0.12,
			"defense_closeout_speed": 13.2,
			"defense_duration": 0.24,
			"defense_steal_radius_bonus": 0.65,
			"defense_contest_bonus": 0.30,
			"defense_window_duration": 0.90,
			"anim_action": "eclipse_counter",
		},
	}))


func register_move(move: FrameData) -> void:
	if move == null or move.id.is_empty():
		return
	_moves[move.id] = move
	_cache_dirty = true


func register_move_from_dict(data: Dictionary) -> FrameData:
	var move := FrameData.from_dict(data)
	register_move(move)
	return move


func unregister_move(move_id: String) -> bool:
	if not _moves.has(move_id):
		return false
	_moves.erase(move_id)
	_cache_dirty = true
	return true


func has_move(move_id: String) -> bool:
	return _moves.has(move_id)


func get_move(move_id: String) -> FrameData:
	if not _moves.has(move_id):
		return null
	return _moves[move_id] as FrameData


func get_move_ids() -> Array[String]:
	var ids: Array[String] = []
	for key in _moves.keys():
		ids.append(str(key))
	ids.sort()
	return ids


func get_all_moves() -> Array[FrameData]:
	var list: Array[FrameData] = []
	for mid in get_move_ids():
		list.append(_moves[mid] as FrameData)
	return list


func get_normal_moves() -> Array[FrameData]:
	var list: Array[FrameData] = []
	for mid in get_move_ids():
		var m := _moves[mid] as FrameData
		if m.sequence.is_empty() or m.priority <= FrameData.PRIORITY_DRIBBLE:
			list.append(m)
	return list


## Returns all sequence-driven combo moves valid for `archetype_id`,
## sorted deterministically by (priority DESC, sequence.size() DESC, id ASC).
func get_combo_moves(archetype_id: String = "") -> Array[FrameData]:
	if _cache_dirty:
		_rebuild_sorted_combo_cache()
	var filtered: Array[FrameData] = []
	for move in _sorted_combo_cache:
		if move.is_valid_for_archetype(archetype_id):
			filtered.append(move)
	return filtered


func get_moves_for_archetype(archetype_id: String) -> Array[FrameData]:
	var list: Array[FrameData] = []
	for mid in get_move_ids():
		var m := _moves[mid] as FrameData
		if m.is_valid_for_archetype(archetype_id):
			list.append(m)
	return list


func get_archetype_unique_moves() -> Array[FrameData]:
	var list: Array[FrameData] = []
	for mid in get_move_ids():
		var m := _moves[mid] as FrameData
		if not m.archetype_id.is_empty():
			list.append(m)
	return list


func get_unique_move_for_archetype(archetype_id: String) -> FrameData:
	var key: String = archetype_id.strip_edges().to_lower()
	if key.is_empty():
		return null
	for mid in get_move_ids():
		var m := _moves[mid] as FrameData
		if m.archetype_id == key:
			return m
	return null


func _rebuild_sorted_combo_cache() -> void:
	_sorted_combo_cache.clear()
	for key in _moves.keys():
		var m := _moves[key] as FrameData
		if not m.sequence.is_empty():
			_sorted_combo_cache.append(m)
	_sorted_combo_cache.sort_custom(_compare_combo_candidates)
	_cache_dirty = false


static func _compare_combo_candidates(a: FrameData, b: FrameData) -> bool:
	if a.priority != b.priority:
		return a.priority > b.priority
	if a.sequence.size() != b.sequence.size():
		return a.sequence.size() > b.sequence.size()
	return a.id < b.id
