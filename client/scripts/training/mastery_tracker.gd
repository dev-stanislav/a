class_name MasteryTracker
extends RefCounted
## Persistent Skill Training Mastery Tracker for PHANTOM COURT ONLINE (Phase 11).
## Tracks per-move combo mastery (attempts, completions, perfects, streaks, challenge high score,
## Novice/Adept/Master/Phantom rank), per-shot-spot shooting accuracy & timing offsets,
## and per-archetype totals with JSON persistence (customizable save_path for isolated tests).

const DEFAULT_SAVE_PATH := "user://skill_mastery.json"

const RANK_NOVICE := "Novice"
const RANK_ADEPT := "Adept"
const RANK_MASTER := "Master"
const RANK_PHANTOM := "Phantom"

const GRADE_ORDER: Dictionary = {
	"": 0,
	"FAIL": 1,
	"C": 2,
	"B": 3,
	"A": 4,
	"S": 5,
}

var save_path: String = DEFAULT_SAVE_PATH

var _move_stats: Dictionary = {}       # move_id: String -> Dictionary
var _shot_spots: Dictionary = {}       # spot_id: String -> Dictionary
var _archetype_totals: Dictionary = {} # archetype_id: String -> Dictionary
var _shot_current_streak: int = 0
var _shot_best_streak: int = 0


func _init(custom_save_path: String = DEFAULT_SAVE_PATH) -> void:
	if not custom_save_path.strip_edges().is_empty():
		save_path = custom_save_path


func set_save_path(path: String) -> void:
	if not path.strip_edges().is_empty():
		save_path = path


func get_save_path() -> String:
	return save_path


func reset_stats() -> void:
	_move_stats.clear()
	_shot_spots.clear()
	_archetype_totals.clear()
	_shot_current_streak = 0
	_shot_best_streak = 0


# ==============================================================================
# Recording API
# ==============================================================================

func record_combo_attempt(move_id: String, archetype_id: String = "", failed: bool = false) -> Dictionary:
	var mid: String = move_id.strip_edges().to_lower()
	if mid.is_empty():
		return {}
	var entry: Dictionary = _ensure_move_entry(mid)
	entry["attempts"] = int(entry["attempts"]) + 1
	if failed:
		entry["current_streak"] = 0
	if not archetype_id.is_empty():
		var a_entry: Dictionary = _ensure_archetype_entry(archetype_id)
		a_entry["combo_attempts"] = int(a_entry["combo_attempts"]) + 1
	return entry.duplicate(true)


func record_combo_miss(move_id: String, archetype_id: String = "") -> Dictionary:
	return record_combo_attempt(move_id, archetype_id, true)


func record_combo_completion(move_id: String, is_perfect: bool, archetype_id: String = "") -> Dictionary:
	var mid: String = move_id.strip_edges().to_lower()
	if mid.is_empty():
		return {}
	var entry: Dictionary = _ensure_move_entry(mid)
	var new_completions: int = int(entry["completions"]) + 1
	entry["completions"] = new_completions
	entry["attempts"] = maxi(int(entry["attempts"]), new_completions)
	if is_perfect:
		entry["perfect_completions"] = int(entry["perfect_completions"]) + 1
	var next_streak: int = int(entry["current_streak"]) + 1
	entry["current_streak"] = next_streak
	entry["best_streak"] = maxi(int(entry["best_streak"]), next_streak)
	entry["mastery_rank"] = compute_mastery_rank(entry)

	if not archetype_id.is_empty():
		var a_entry: Dictionary = _ensure_archetype_entry(archetype_id)
		a_entry["combo_completions"] = int(a_entry["combo_completions"]) + 1
		a_entry["combo_attempts"] = maxi(int(a_entry["combo_attempts"]), int(a_entry["combo_completions"]))
		if is_perfect:
			a_entry["perfect_completions"] = int(a_entry["perfect_completions"]) + 1

	return entry.duplicate(true)


func record_shot(
	spot_id: String,
	made: bool,
	is_perfect: bool = false,
	offset_ms: float = 0.0,
	archetype_id: String = ""
) -> Dictionary:
	var sid: String = spot_id.strip_edges().to_lower()
	if sid.is_empty():
		sid = "free_court"
	var entry: Dictionary = _ensure_shot_spot_entry(sid)
	var attempts: int = int(entry["attempts"]) + 1
	var makes: int = int(entry["makes"]) + (1 if made else 0)
	var perfects: int = int(entry["perfect_releases"]) + (1 if is_perfect else 0)
	var total_abs_ms: float = float(entry["total_abs_offset_ms"]) + absf(offset_ms)

	entry["attempts"] = attempts
	entry["makes"] = makes
	entry["perfect_releases"] = perfects
	entry["total_abs_offset_ms"] = total_abs_ms
	entry["avg_abs_offset_ms"] = total_abs_ms / float(maxi(1, attempts))
	entry["make_pct"] = (float(makes) / float(maxi(1, attempts))) * 100.0

	if made:
		_shot_current_streak += 1
		_shot_best_streak = maxi(_shot_best_streak, _shot_current_streak)
	else:
		_shot_current_streak = 0

	if not archetype_id.is_empty():
		var a_entry: Dictionary = _ensure_archetype_entry(archetype_id)
		a_entry["shots_attempted"] = int(a_entry["shots_attempted"]) + 1
		if made:
			a_entry["shots_made"] = int(a_entry["shots_made"]) + 1

	return entry.duplicate(true)


func record_challenge_result(
	move_id: String,
	completions: int,
	perfects: int,
	score: int,
	grade: String,
	archetype_id: String = ""
) -> Dictionary:
	var mid: String = move_id.strip_edges().to_lower()
	if mid.is_empty():
		return {}
	var entry: Dictionary = _ensure_move_entry(mid)
	entry["challenge_attempts"] = int(entry["challenge_attempts"]) + 1
	entry["challenge_best_score"] = maxi(int(entry["challenge_best_score"]), maxi(0, score))

	var norm_grade: String = grade.strip_edges().to_upper()
	var prev_grade: String = str(entry.get("challenge_best_grade", ""))
	if int(GRADE_ORDER.get(norm_grade, 0)) > int(GRADE_ORDER.get(prev_grade, 0)):
		entry["challenge_best_grade"] = norm_grade

	entry["challenge_last_completions"] = maxi(0, completions)
	entry["challenge_last_perfects"] = maxi(0, perfects)
	entry["challenge_last_score"] = maxi(0, score)
	entry["challenge_last_grade"] = norm_grade
	entry["mastery_rank"] = compute_mastery_rank(entry)

	if not archetype_id.is_empty():
		var a_entry: Dictionary = _ensure_archetype_entry(archetype_id)
		a_entry["challenges_completed"] = int(a_entry["challenges_completed"]) + 1

	return entry.duplicate(true)


# ==============================================================================
# Query & Summary API
# ==============================================================================

static func compute_mastery_rank(entry: Dictionary) -> String:
	var completions: int = int(entry.get("completions", 0))
	var perfects: int = int(entry.get("perfect_completions", 0))
	var best_streak: int = int(entry.get("best_streak", 0))
	var best_grade: String = str(entry.get("challenge_best_grade", "")).to_upper()

	if (completions >= 15 and perfects >= 10) or (best_streak >= 8 and perfects >= 6) or best_grade == "S":
		return RANK_PHANTOM
	if (completions >= 8 and perfects >= 4) or best_grade == "A":
		return RANK_MASTER
	if completions >= 3 or perfects >= 2 or best_grade == "B":
		return RANK_ADEPT
	return RANK_NOVICE


func get_move_stats(move_id: String) -> Dictionary:
	var mid: String = move_id.strip_edges().to_lower()
	if not _move_stats.has(mid):
		return _default_move_entry(mid)
	return (_move_stats[mid] as Dictionary).duplicate(true)


func get_all_move_stats() -> Dictionary:
	var out: Dictionary = {}
	for k in _move_stats.keys():
		out[str(k)] = (_move_stats[k] as Dictionary).duplicate(true)
	return out


func get_shot_stats() -> Dictionary:
	var total_attempts: int = 0
	var total_makes: int = 0
	var total_perfects: int = 0
	var total_abs_ms: float = 0.0
	var spots_copy: Dictionary = {}

	for sid in _shot_spots.keys():
		var e: Dictionary = _shot_spots[sid]
		total_attempts += int(e["attempts"])
		total_makes += int(e["makes"])
		total_perfects += int(e["perfect_releases"])
		total_abs_ms += float(e["total_abs_offset_ms"])
		spots_copy[str(sid)] = e.duplicate(true)

	var make_pct: float = (float(total_makes) / float(total_attempts) * 100.0) if total_attempts > 0 else 0.0
	var perf_pct: float = (float(total_perfects) / float(total_attempts) * 100.0) if total_attempts > 0 else 0.0
	var avg_ms: float = (total_abs_ms / float(total_attempts)) if total_attempts > 0 else 0.0

	return {
		"total_attempts": total_attempts,
		"total_makes": total_makes,
		"total_perfect_releases": total_perfects,
		"make_pct": make_pct,
		"perfect_pct": perf_pct,
		"avg_abs_offset_ms": avg_ms,
		"current_streak": _shot_current_streak,
		"best_streak": _shot_best_streak,
		"spots": spots_copy,
	}


func get_archetype_stats(archetype_id: String = "") -> Dictionary:
	if not archetype_id.is_empty():
		var aid: String = archetype_id.strip_edges().to_lower()
		if not _archetype_totals.has(aid):
			return _default_archetype_entry(aid)
		return (_archetype_totals[aid] as Dictionary).duplicate(true)
	var out: Dictionary = {}
	for k in _archetype_totals.keys():
		out[str(k)] = (_archetype_totals[k] as Dictionary).duplicate(true)
	return out


func get_overall_summary() -> Dictionary:
	var total_attempts: int = 0
	var total_completions: int = 0
	var total_perfects: int = 0
	var best_streak: int = 0
	var best_challenge_score: int = 0
	var best_grade: String = ""

	for mid in _move_stats.keys():
		var e: Dictionary = _move_stats[mid]
		total_attempts += int(e["attempts"])
		total_completions += int(e["completions"])
		total_perfects += int(e["perfect_completions"])
		best_streak = maxi(best_streak, int(e["best_streak"]))
		best_challenge_score = maxi(best_challenge_score, int(e["challenge_best_score"]))
		var g: String = str(e.get("challenge_best_grade", ""))
		if int(GRADE_ORDER.get(g, 0)) > int(GRADE_ORDER.get(best_grade, 0)):
			best_grade = g

	var shot_stats: Dictionary = get_shot_stats()
	var perfect_rate_pct: float = (
		(float(total_perfects) / float(total_completions) * 100.0)
		if total_completions > 0
		else 0.0
	)
	var overall_rank: String = compute_mastery_rank({
		"completions": total_completions,
		"perfect_completions": total_perfects,
		"best_streak": best_streak,
		"challenge_best_grade": best_grade,
	})

	return {
		"total_attempts": total_attempts,
		"total_completions": total_completions,
		"total_perfect_completions": total_perfects,
		"perfect_rate_pct": perfect_rate_pct,
		"best_streak": best_streak,
		"best_challenge_score": best_challenge_score,
		"best_challenge_grade": best_grade,
		"overall_rank": overall_rank,
		"mastery_rank": overall_rank,
		"shot_attempts": int(shot_stats["total_attempts"]),
		"shot_makes": int(shot_stats["total_makes"]),
		"shot_accuracy_pct": float(shot_stats["make_pct"]),
		"shot_best_streak": int(shot_stats["best_streak"]),
		"moves": get_all_move_stats(),
		"shots": shot_stats,
		"archetypes": get_archetype_stats(),
	}


# ==============================================================================
# JSON Persistence
# ==============================================================================

func export_dict() -> Dictionary:
	return {
		"version": 1,
		"shot_current_streak": _shot_current_streak,
		"shot_best_streak": _shot_best_streak,
		"moves": get_all_move_stats(),
		"shot_spots": _duplicate_nested_dict(_shot_spots),
		"archetypes": get_archetype_stats(),
	}


func import_dict(data: Dictionary) -> void:
	reset_stats()
	_shot_current_streak = int(data.get("shot_current_streak", 0))
	_shot_best_streak = int(data.get("shot_best_streak", 0))

	if data.has("moves") and data["moves"] is Dictionary:
		var m_src: Dictionary = data["moves"]
		for k in m_src.keys():
			if m_src[k] is Dictionary:
				var mid: String = str(k)
				var merged: Dictionary = _default_move_entry(mid)
				var src_e: Dictionary = m_src[k]
				for fk in src_e.keys():
					merged[str(fk)] = src_e[fk]
				merged["attempts"] = int(merged["attempts"])
				merged["completions"] = int(merged["completions"])
				merged["perfect_completions"] = int(merged["perfect_completions"])
				merged["current_streak"] = int(merged["current_streak"])
				merged["best_streak"] = int(merged["best_streak"])
				merged["challenge_attempts"] = int(merged["challenge_attempts"])
				merged["challenge_best_score"] = int(merged["challenge_best_score"])
				merged["mastery_rank"] = compute_mastery_rank(merged)
				_move_stats[mid] = merged

	if data.has("shot_spots") and data["shot_spots"] is Dictionary:
		var s_src: Dictionary = data["shot_spots"]
		for k in s_src.keys():
			if s_src[k] is Dictionary:
				var sid: String = str(k)
				var merged_s: Dictionary = _default_shot_spot_entry(sid)
				var src_s: Dictionary = s_src[k]
				for fk in src_s.keys():
					merged_s[str(fk)] = src_s[fk]
				merged_s["attempts"] = int(merged_s["attempts"])
				merged_s["makes"] = int(merged_s["makes"])
				merged_s["perfect_releases"] = int(merged_s["perfect_releases"])
				merged_s["total_abs_offset_ms"] = float(merged_s["total_abs_offset_ms"])
				merged_s["avg_abs_offset_ms"] = float(merged_s["avg_abs_offset_ms"])
				merged_s["make_pct"] = float(merged_s["make_pct"])
				_shot_spots[sid] = merged_s

	if data.has("archetypes") and data["archetypes"] is Dictionary:
		var a_src: Dictionary = data["archetypes"]
		for k in a_src.keys():
			if a_src[k] is Dictionary:
				var aid: String = str(k)
				var merged_a: Dictionary = _default_archetype_entry(aid)
				var src_a: Dictionary = a_src[k]
				for fk in src_a.keys():
					merged_a[str(fk)] = int(src_a[fk]) if fk != "archetype_id" else str(src_a[fk])
				_archetype_totals[aid] = merged_a


func save_to_disk() -> bool:
	var dir_path: String = save_path.get_base_dir()
	if not dir_path.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))

	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		return false
	var json_text: String = JSON.stringify(export_dict(), "\t")
	file.store_string(json_text)
	file.flush()
	file.close()
	return true


func load_from_disk() -> bool:
	if not FileAccess.file_exists(save_path):
		return false
	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		return false
	var raw_text: String = file.get_as_text()
	file.close()
	if raw_text.strip_edges().is_empty():
		return false
	var parser := JSON.new()
	if parser.parse(raw_text) != OK:
		return false
	if not (parser.data is Dictionary):
		return false
	import_dict(parser.data as Dictionary)
	return true


# ==============================================================================
# Internal Entry Builders
# ==============================================================================

func _ensure_move_entry(move_id: String) -> Dictionary:
	if not _move_stats.has(move_id):
		_move_stats[move_id] = _default_move_entry(move_id)
	return _move_stats[move_id] as Dictionary


func _ensure_shot_spot_entry(spot_id: String) -> Dictionary:
	if not _shot_spots.has(spot_id):
		_shot_spots[spot_id] = _default_shot_spot_entry(spot_id)
	return _shot_spots[spot_id] as Dictionary


func _ensure_archetype_entry(archetype_id: String) -> Dictionary:
	var aid: String = archetype_id.strip_edges().to_lower()
	if not _archetype_totals.has(aid):
		_archetype_totals[aid] = _default_archetype_entry(aid)
	return _archetype_totals[aid] as Dictionary


static func _default_move_entry(move_id: String) -> Dictionary:
	return {
		"move_id": move_id,
		"attempts": 0,
		"completions": 0,
		"perfect_completions": 0,
		"current_streak": 0,
		"best_streak": 0,
		"challenge_attempts": 0,
		"challenge_best_score": 0,
		"challenge_best_grade": "",
		"challenge_last_completions": 0,
		"challenge_last_perfects": 0,
		"challenge_last_score": 0,
		"challenge_last_grade": "",
		"mastery_rank": RANK_NOVICE,
	}


static func _default_shot_spot_entry(spot_id: String) -> Dictionary:
	return {
		"spot_id": spot_id,
		"attempts": 0,
		"makes": 0,
		"perfect_releases": 0,
		"total_abs_offset_ms": 0.0,
		"avg_abs_offset_ms": 0.0,
		"make_pct": 0.0,
	}


static func _default_archetype_entry(archetype_id: String) -> Dictionary:
	return {
		"archetype_id": archetype_id,
		"combo_attempts": 0,
		"combo_completions": 0,
		"perfect_completions": 0,
		"shots_attempted": 0,
		"shots_made": 0,
		"challenges_completed": 0,
	}


static func _duplicate_nested_dict(src: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in src.keys():
		if src[k] is Dictionary:
			out[str(k)] = (src[k] as Dictionary).duplicate(true)
		else:
			out[str(k)] = src[k]
	return out
