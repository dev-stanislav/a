class_name InputBuffer
extends RefCounted
## 60 Hz circular frame-stamped input buffer (capacity 90 frames) for PHANTOM COURT ONLINE.
## Converts canonical PlayerInputFrame rising button edges and directional snaps into
## timestamped tokens {symbol, frame, gap_frames, local_dir, token_id, is_direction}.
## Supports BOTH tapped directional inputs AND continuously held directional inputs
## during button sequences (e.g., Meteor Dunk: Shift, W, Space, R).

const CAPACITY_FRAMES: int = 90
const DIR_DEADZONE: float = 0.45

# Canonical PlayerInputFrame button bitmasks (ARCHITECTURE.md Section 5.2)
const BTN_SPRINT: int  = 1    # 1 << 0 -> "Shift"
const BTN_JUMP: int    = 2    # 1 << 1 -> "Space"
const BTN_SHOOT: int   = 4    # 1 << 2 -> "LMB"
const BTN_PASS: int    = 8    # 1 << 3 -> "RMB"
const BTN_SKILL_Q: int = 16   # 1 << 4 -> "Q"
const BTN_SKILL_E: int = 32   # 1 << 5 -> "E"
const BTN_SKILL_R: int = 64   # 1 << 6 -> "R"
const BTN_STEAL: int   = 128  # 1 << 7 -> "F"
const BTN_ZONE: int    = 256  # 1 << 8 -> "V"
const BTN_STANCE: int  = 512  # 1 << 9 -> "C"

# Deterministic scan order for simultaneous button rising edges on the same frame
const BUTTON_DEFINITIONS: Array[Dictionary] = [
	{"bit": BTN_SPRINT,  "symbol": "Shift"},
	{"bit": BTN_SKILL_Q, "symbol": "Q"},
	{"bit": BTN_SKILL_E, "symbol": "E"},
	{"bit": BTN_SKILL_R, "symbol": "R"},
	{"bit": BTN_JUMP,    "symbol": "Space"},
	{"bit": BTN_SHOOT,   "symbol": "LMB"},
	{"bit": BTN_PASS,    "symbol": "RMB"},
	{"bit": BTN_STEAL,   "symbol": "F"},
	{"bit": BTN_STANCE,  "symbol": "C"},
	{"bit": BTN_ZONE,    "symbol": "V"},
]

const DIRECTION_SYMBOLS: Array[String] = ["W", "S", "A", "D"]

var _current_frame: int = -1
var _last_input_tick: int = -1
var _prev_buttons: int = 0
var _prev_dir_symbol: String = ""
var _prev_local_dir: Vector2 = Vector2.ZERO
var _next_token_id: int = 1

var _tokens: Array[Dictionary] = []
var _frame_ring: Array[Dictionary] = []


func _init() -> void:
	_init_ring()


func _init_ring() -> void:
	_frame_ring.clear()
	_frame_ring.resize(CAPACITY_FRAMES)
	for i in range(CAPACITY_FRAMES):
		_frame_ring[i] = {
			"valid": false,
			"frame": -1,
			"buttons": 0,
			"local_dir": Vector2.ZERO,
			"dir_symbol": "",
		}


func clear() -> void:
	_current_frame = -1
	_last_input_tick = -1
	_prev_buttons = 0
	_prev_dir_symbol = ""
	_prev_local_dir = Vector2.ZERO
	_next_token_id = 1
	_tokens.clear()
	_init_ring()


func get_current_frame() -> int:
	return _current_frame


func get_token_count() -> int:
	return _tokens.size()


func get_latest_token_id() -> int:
	if _tokens.is_empty():
		return 0
	return int(_tokens[_tokens.size() - 1]["token_id"])


static func is_direction_symbol(symbol: String) -> bool:
	var canon: String = normalize_symbol(symbol)
	return canon == "W" or canon == "S" or canon == "A" or canon == "D"


static func normalize_symbol(raw_symbol: String, prefer_direction_alias: bool = false) -> String:
	var cleaned: String = raw_symbol.strip_edges()
	var lower: String = cleaned.to_lower()
	if prefer_direction_alias:
		match lower:
			"f", "fwd", "forward", "up", "w":
				return "W"
			"b", "back", "backward", "down", "s":
				return "S"
			"l", "left", "a":
				return "A"
			"r", "right", "d":
				return "D"
	match lower:
		"w", "up", "forward", "fwd", "dir_f", "dir_w":
			return "W"
		"s", "down", "back", "backward", "b", "dir_b", "dir_s":
			return "S"
		"a", "left", "l", "dir_l", "dir_a":
			return "A"
		"d", "right", "dir_r", "dir_d":
			return "D"
		"shift", "sprint", "btn_sprint":
			return "Shift"
		"space", "jump", "btn_jump":
			return "Space"
		"lmb", "shoot", "j", "btn_shoot":
			return "LMB"
		"rmb", "pass", "pass_ball", "k", "btn_pass":
			return "RMB"
		"q", "skill_q", "btn_skill_q":
			return "Q"
		"e", "skill_e", "btn_skill_e":
			return "E"
		"r", "skill_r", "btn_skill_r":
			return "R"
		"f", "steal", "btn_steal":
			return "F"
		"c", "stance", "defensive_stance", "btn_stance":
			return "C"
		"v", "zone", "zone_activate", "btn_zone":
			return "V"
		_:
			return cleaned


static func local_dir_to_cardinal(local_dir: Vector2) -> String:
	if local_dir.length_squared() < (DIR_DEADZONE * DIR_DEADZONE):
		return ""
	if absf(local_dir.y) >= absf(local_dir.x):
		return "W" if local_dir.y > 0.0 else "S"
	return "D" if local_dir.x > 0.0 else "A"


static func is_direction_held_in_vector(local_dir: Vector2, dir_symbol: String) -> bool:
	var canon: String = normalize_symbol(dir_symbol, true)
	match canon:
		"W":
			return local_dir.y >= DIR_DEADZONE
		"S":
			return local_dir.y <= -DIR_DEADZONE
		"A":
			return local_dir.x <= -DIR_DEADZONE
		"D":
			return local_dir.x >= DIR_DEADZONE
		_:
			return false


## Records one 60 Hz PlayerInputFrame and returns all new tokens emitted on this tick.
func push_frame(input_frame: Dictionary, frame_index: int = -1) -> Array[Dictionary]:
	var prev_frame: int = _current_frame
	var resolved_frame: int = _advance_frame_counter(input_frame, frame_index)

	# If caller skipped intermediate ticks (e.g. direct tick jumps in unit tests),
	# carry previous held state across skipped slots inside the 90-frame ring.
	if prev_frame >= 0 and resolved_frame > prev_frame + 1:
		var fill_start: int = maxi(prev_frame + 1, resolved_frame - CAPACITY_FRAMES)
		for f in range(fill_start, resolved_frame):
			_write_ring_slot(f, _prev_buttons, _prev_local_dir, _prev_dir_symbol)

	var buttons: int = int(input_frame.get("buttons", 0))
	var local_dir: Vector2 = Vector2.ZERO
	if input_frame.has("local_dir") and input_frame["local_dir"] is Vector2:
		local_dir = input_frame["local_dir"]

	var dir_sym: String = local_dir_to_cardinal(local_dir)
	var just_pressed: int = buttons & (~_prev_buttons)

	_write_ring_slot(resolved_frame, buttons, local_dir, dir_sym)

	var emitted: Array[Dictionary] = []

	# Emit modifier/sprint rising edge first so simultaneous Shift+W preserves Shift -> W order
	if (just_pressed & BTN_SPRINT) != 0:
		emitted.append(_append_token("Shift", resolved_frame, local_dir, false))

	# Emit directional snap on edge from neutral OR cardinal direction change
	if not dir_sym.is_empty() and dir_sym != _prev_dir_symbol:
		emitted.append(_append_token(dir_sym, resolved_frame, local_dir, true))

	# Emit remaining button rising edges in deterministic canonical order
	for def in BUTTON_DEFINITIONS:
		var bit: int = int(def["bit"])
		if bit == BTN_SPRINT:
			continue
		if (just_pressed & bit) != 0:
			emitted.append(_append_token(str(def["symbol"]), resolved_frame, local_dir, false))

	_prev_buttons = buttons
	_prev_dir_symbol = dir_sym
	_prev_local_dir = local_dir

	_prune_expired_tokens()
	return emitted


## Directly injects a single symbol token (useful for unit tests & training playback).
func push_symbol(symbol: String, frame_index: int = -1, local_dir: Vector2 = Vector2.ZERO) -> Dictionary:
	var resolved_frame: int = frame_index if frame_index >= 0 else (_current_frame + 1)
	_current_frame = resolved_frame
	var canon: String = normalize_symbol(symbol)
	var is_dir: bool = is_direction_symbol(canon)
	var dir_vec: Vector2 = local_dir
	if is_dir and dir_vec.length_squared() < 1e-6:
		dir_vec = _symbol_to_unit_dir(canon)
	_write_ring_slot(resolved_frame, 0, dir_vec, canon if is_dir else _prev_dir_symbol)
	var tok: Dictionary = _append_token(canon, resolved_frame, dir_vec, is_dir)
	_prune_expired_tokens()
	return tok


## Returns recent recorded input tokens (newest last, capped to max_count).
func get_history(max_count: int = CAPACITY_FRAMES) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _tokens.is_empty() or max_count <= 0:
		return result
	var count: int = mini(max_count, _tokens.size())
	var start_idx: int = _tokens.size() - count
	for i in range(start_idx, _tokens.size()):
		result.append((_tokens[i] as Dictionary).duplicate(true))
	return result


## Checks whether a cardinal direction was actively held on a specific buffered frame.
func is_direction_held_at(dir_symbol: String, frame: int) -> bool:
	var slot: Dictionary = _get_ring_slot(frame)
	if not bool(slot.get("valid", false)):
		return false
	return is_direction_held_in_vector(slot.get("local_dir", Vector2.ZERO), dir_symbol)


## Checks whether a cardinal direction was held on any frame within [start_frame..end_frame].
func was_direction_held_in_span(dir_symbol: String, start_frame: int, end_frame: int) -> bool:
	var lo: int = mini(start_frame, end_frame)
	var hi: int = maxi(start_frame, end_frame)
	var clamp_lo: int = maxi(lo, _current_frame - CAPACITY_FRAMES + 1)
	for f in range(hi, clamp_lo - 1, -1):
		if is_direction_held_at(dir_symbol, f):
			return true
	return false


func get_local_dir_at(frame: int) -> Vector2:
	var slot: Dictionary = _get_ring_slot(frame)
	if bool(slot.get("valid", false)) and slot.get("local_dir") is Vector2:
		return slot["local_dir"]
	return _prev_local_dir


## Matches a move sequence backwards from the newest unconsumed token.
## Supports both discrete directional taps AND continuously held directions across buttons.
func match_sequence(
	sequence: Array[String],
	max_step_window: int = 14,
	min_token_id: int = -1,
	max_final_age_frames: int = 0
) -> Dictionary:
	var empty_res := {
		"matched": false,
		"matched_tokens": [] as Array[Dictionary],
		"step_gaps": [] as Array[int],
		"timing_gaps": [] as Array[int],
		"avg_gap": 0.0,
		"final_gap": 0,
		"min_gap": 0,
		"max_gap": 0,
		"last_token_id": -1,
		"used_held_direction": false,
	}

	var seq_len: int = sequence.size()
	if seq_len <= 0 or _tokens.is_empty():
		return empty_res

	var norm_seq: Array[String] = []
	for s in sequence:
		norm_seq.append(normalize_symbol(s))

	var final_sym: String = norm_seq[seq_len - 1]

	# Scan backwards for a fresh unconsumed anchor token matching the final symbol
	for idx in range(_tokens.size() - 1, -1, -1):
		var anchor: Dictionary = _tokens[idx]
		var anchor_frame: int = int(anchor["frame"])
		var anchor_age: int = _current_frame - anchor_frame
		if anchor_age > max_final_age_frames:
			break
		var anchor_id: int = int(anchor["token_id"])
		if anchor_id <= min_token_id:
			break
		if str(anchor["symbol"]) != final_sym:
			continue

		if seq_len == 1:
			return {
				"matched": true,
				"matched_tokens": [anchor.duplicate(true)],
				"step_gaps": [] as Array[int],
				"timing_gaps": [] as Array[int],
				"avg_gap": 0.0,
				"final_gap": 0,
				"min_gap": 0,
				"max_gap": 0,
				"last_token_id": anchor_id,
				"used_held_direction": false,
			}

		var used_ids: Dictionary = {anchor_id: true}
		var sub: Dictionary = _match_prefix(
			norm_seq,
			seq_len - 2,
			anchor_frame,
			max_step_window,
			min_token_id,
			used_ids
		)
		if bool(sub["matched"]):
			var matched_tokens: Array[Dictionary] = []
			for t in (sub["tokens"] as Array):
				matched_tokens.append((t as Dictionary).duplicate(true))
			matched_tokens.append(anchor.duplicate(true))
			return _finalize_match_result(matched_tokens, anchor_id, bool(sub["used_held"]))

	return empty_res


## Computes how many leading symbols of `sequence` the player has entered most recently
## within `max_step_window` (used by Phase 11 combo trainer HUD).
func measure_prefix_progress(
	sequence: Array[String],
	max_step_window: int = 14,
	min_token_id: int = -1
) -> int:
	var seq_len: int = sequence.size()
	if seq_len <= 0 or _tokens.is_empty():
		return 0
	for k in range(seq_len, 0, -1):
		var prefix: Array[String] = []
		for i in range(k):
			prefix.append(sequence[i])
		var res: Dictionary = match_sequence(prefix, max_step_window, min_token_id, max_step_window)
		if bool(res["matched"]):
			return k
	return 0


func export_state() -> Dictionary:
	var tokens_copy: Array[Dictionary] = []
	for tok in _tokens:
		tokens_copy.append((tok as Dictionary).duplicate(true))

	var ring_copy: Array[Dictionary] = []
	for slot in _frame_ring:
		ring_copy.append((slot as Dictionary).duplicate(true))

	return {
		"current_frame": _current_frame,
		"last_input_tick": _last_input_tick,
		"prev_buttons": _prev_buttons,
		"prev_dir_symbol": _prev_dir_symbol,
		"prev_local_dir": _prev_local_dir,
		"next_token_id": _next_token_id,
		"tokens": tokens_copy,
		"frame_ring": ring_copy,
	}


func import_state(state: Dictionary) -> void:
	clear()
	_current_frame = int(state.get("current_frame", -1))
	_last_input_tick = int(state.get("last_input_tick", -1))
	_prev_buttons = int(state.get("prev_buttons", 0))
	_prev_dir_symbol = str(state.get("prev_dir_symbol", ""))
	if state.get("prev_local_dir") is Vector2:
		_prev_local_dir = state["prev_local_dir"]
	_next_token_id = int(state.get("next_token_id", 1))

	if state.has("tokens") and state["tokens"] is Array:
		for tok in (state["tokens"] as Array):
			if tok is Dictionary:
				_tokens.append((tok as Dictionary).duplicate(true))

	if state.has("frame_ring") and state["frame_ring"] is Array:
		var src_ring: Array = state["frame_ring"]
		var count: int = mini(CAPACITY_FRAMES, src_ring.size())
		for i in range(count):
			if src_ring[i] is Dictionary:
				_frame_ring[i] = (src_ring[i] as Dictionary).duplicate(true)


# ==============================================================================
# Internal Helpers
# ==============================================================================

func _advance_frame_counter(input_frame: Dictionary, frame_index: int) -> int:
	if frame_index >= 0:
		_current_frame = frame_index
		if input_frame.has("tick"):
			_last_input_tick = int(input_frame["tick"])
		return _current_frame

	if input_frame.has("tick"):
		var t: int = int(input_frame["tick"])
		if _current_frame < 0:
			_current_frame = maxi(0, t)
			_last_input_tick = t
		elif t > _last_input_tick:
			_current_frame += (t - _last_input_tick)
			_last_input_tick = t
		else:
			_current_frame += 1
			_last_input_tick = t
	else:
		_current_frame += 1
	return _current_frame


func _write_ring_slot(frame: int, buttons: int, local_dir: Vector2, dir_sym: String) -> void:
	if frame < 0:
		return
	var slot_idx: int = posmod(frame, CAPACITY_FRAMES)
	_frame_ring[slot_idx] = {
		"valid": true,
		"frame": frame,
		"buttons": buttons,
		"local_dir": local_dir,
		"dir_symbol": dir_sym,
	}


func _get_ring_slot(frame: int) -> Dictionary:
	if frame < 0:
		return {"valid": false}
	var slot: Dictionary = _frame_ring[posmod(frame, CAPACITY_FRAMES)]
	if bool(slot.get("valid", false)) and int(slot.get("frame", -1)) == frame:
		return slot
	return {"valid": false}


func _append_token(symbol: String, frame: int, local_dir: Vector2, is_dir: bool) -> Dictionary:
	var gap: int = 0
	if not _tokens.is_empty():
		var prev_tok: Dictionary = _tokens[_tokens.size() - 1]
		gap = maxi(0, frame - int(prev_tok["frame"]))

	var tok := {
		"symbol": symbol,
		"frame": frame,
		"gap_frames": gap,
		"local_dir": local_dir,
		"token_id": _next_token_id,
		"is_direction": is_dir,
	}
	_next_token_id += 1
	_tokens.append(tok)
	return tok


func _prune_expired_tokens() -> void:
	var min_frame: int = _current_frame - CAPACITY_FRAMES + 1
	while not _tokens.is_empty() and int(_tokens[0]["frame"]) < min_frame:
		_tokens.pop_front()
	while _tokens.size() > CAPACITY_FRAMES:
		_tokens.pop_front()


func _match_prefix(
	norm_seq: Array[String],
	step_idx: int,
	next_frame: int,
	max_step_window: int,
	min_token_id: int,
	used_ids: Dictionary
) -> Dictionary:
	if step_idx < 0:
		return {"matched": true, "tokens": [], "used_held": false}

	var target: String = norm_seq[step_idx]
	var is_dir_target: bool = is_direction_symbol(target)

	# Path 1: Match an explicit discrete buffered token <= next_frame within max_step_window
	var scan_start: int = _tokens.size() - 1
	while scan_start >= 0 and int(_tokens[scan_start]["frame"]) > next_frame:
		scan_start -= 1

	var blocked_at_frame: int = -1
	for j in range(scan_start, -1, -1):
		var tok: Dictionary = _tokens[j]
		var tid: int = int(tok["token_id"])
		if used_ids.has(tid):
			continue
		if tid <= min_token_id:
			break

		var t_frame: int = int(tok["frame"])
		if blocked_at_frame >= 0 and t_frame < blocked_at_frame:
			break

		var gap: int = next_frame - t_frame
		if gap > max_step_window:
			break

		if str(tok["symbol"]) == target:
			used_ids[tid] = true
			var sub: Dictionary = _match_prefix(
				norm_seq,
				step_idx - 1,
				t_frame,
				max_step_window,
				min_token_id,
				used_ids
			)
			used_ids.erase(tid)
			if bool(sub["matched"]):
				var list: Array = sub["tokens"]
				list.append(tok)
				return {"matched": true, "tokens": list, "used_held": bool(sub["used_held"])}
		elif not bool(tok["is_direction"]) and t_frame < next_frame:
			# A non-matching button pressed strictly earlier breaks contiguity for frames < t_frame
			blocked_at_frame = maxi(blocked_at_frame, t_frame)

	# Path 2: If target is a directional input, support continuously held direction during sequence!
	if is_dir_target:
		if step_idx == 0:
			if is_direction_held_at(target, next_frame) or is_direction_held_at(target, next_frame - 1):
				var vtok := {
					"symbol": target,
					"frame": next_frame,
					"gap_frames": 0,
					"local_dir": get_local_dir_at(next_frame),
					"token_id": -1,
					"is_direction": true,
					"synthetic_held": true,
				}
				return {"matched": true, "tokens": [vtok], "used_held": true}
		else:
			# Match the preceding step directly against next_frame, then verify direction was held across the span
			var sub_held: Dictionary = _match_prefix(
				norm_seq,
				step_idx - 1,
				next_frame,
				max_step_window,
				min_token_id,
				used_ids
			)
			if bool(sub_held["matched"]):
				var prev_list: Array = sub_held["tokens"]
				if not prev_list.is_empty():
					var prev_tok: Dictionary = prev_list[prev_list.size() - 1]
					var prev_frame: int = int(prev_tok["frame"])
					if was_direction_held_in_span(target, prev_frame, next_frame):
						var mid_frame: int = int((prev_frame + next_frame) / 2)
						var vtok := {
							"symbol": target,
							"frame": mid_frame,
							"gap_frames": maxi(0, mid_frame - prev_frame),
							"local_dir": get_local_dir_at(next_frame),
							"token_id": -1,
							"is_direction": true,
							"synthetic_held": true,
						}
						prev_list.append(vtok)
						return {"matched": true, "tokens": prev_list, "used_held": true}

	return {"matched": false, "tokens": [], "used_held": false}


func _finalize_match_result(
	matched_tokens: Array[Dictionary],
	anchor_id: int,
	used_held: bool
) -> Dictionary:
	var step_gaps: Array[int] = []
	for i in range(1, matched_tokens.size()):
		var gap: int = maxi(0, int(matched_tokens[i]["frame"]) - int(matched_tokens[i - 1]["frame"]))
		step_gaps.append(gap)

	# Compute timing gaps from discrete real inputs so held directions don't distort rhythm grading
	var real_tokens: Array[Dictionary] = []
	for tok in matched_tokens:
		if not bool(tok.get("synthetic_held", false)):
			real_tokens.append(tok)

	var timing_gaps: Array[int] = []
	for i in range(1, real_tokens.size()):
		timing_gaps.append(maxi(0, int(real_tokens[i]["frame"]) - int(real_tokens[i - 1]["frame"])))

	var active_gaps: Array[int] = timing_gaps if not timing_gaps.is_empty() else step_gaps
	var avg_gap: float = 0.0
	var final_gap: int = 0
	var min_gap: int = 0
	var max_gap: int = 0

	if not active_gaps.is_empty():
		var total: int = 0
		min_gap = active_gaps[0]
		max_gap = active_gaps[0]
		for g in active_gaps:
			total += g
			if g < min_gap:
				min_gap = g
			if g > max_gap:
				max_gap = g
		avg_gap = float(total) / float(active_gaps.size())
		final_gap = active_gaps[active_gaps.size() - 1]

	return {
		"matched": true,
		"matched_tokens": matched_tokens,
		"step_gaps": step_gaps,
		"timing_gaps": timing_gaps,
		"avg_gap": avg_gap,
		"final_gap": final_gap,
		"min_gap": min_gap,
		"max_gap": max_gap,
		"last_token_id": anchor_id,
		"used_held_direction": used_held,
	}


static func _symbol_to_unit_dir(sym: String) -> Vector2:
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
