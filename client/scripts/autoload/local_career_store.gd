class_name LocalCareerStore
extends Node
## Local Offline Glicko-2 Career & Rival Ladder Store for PHANTOM COURT ONLINE.
## Registered as autoload `LocalCareer` (using `class_name LocalCareerStore` to avoid
## Godot 4 autoload/class_name collision). Persists to `user://local_career.json`.

signal career_updated(profile: Dictionary)

const DEFAULT_SAVE_PATH := "user://local_career.json"
const MAX_STORED_HISTORY: int = 100

# Mark Glickman Glicko-2 canonical constants
const DEFAULT_RATING: float = 1500.0
const DEFAULT_RD: float = 350.0
const MIN_RD: float = 30.0
const MAX_RD: float = 350.0
const DEFAULT_VOLATILITY: float = 0.06
const TAU: float = 0.5
const GLICKO2_SCALE: float = 173.7178
const CONVERGENCE_TOLERANCE: float = 0.000001
const AI_OPPONENT_RD: float = 65.0

const AI_DIFFICULTY_RATINGS: Dictionary = {
	0: 1150.0, # Rookie
	1: 1450.0, # Pro
	2: 1750.0, # All-Star
	3: 2050.0, # Phantom
}

const DIFFICULTY_LABELS: Array[String] = ["Rookie", "Pro", "All-Star", "Phantom"]

# Pre-seeded rival AI ladder across Bronze..Phantom tiers featuring all 5 original ballers
const RIVAL_AI_LADDER: Array[Dictionary] = [
	{
		"username": "Akira \"Eclipse\" Shinohara",
		"rating": 2140.0,
		"rating_deviation": 48.0,
		"peak_rating": 2165.0,
		"wins": 48,
		"losses": 6,
		"archetype_fav": "all_rounder",
		"is_ai_rival": true,
	},
	{
		"username": "Sora \"Deadeye\" Hoshino",
		"rating": 1945.0,
		"rating_deviation": 52.0,
		"peak_rating": 1970.0,
		"wins": 39,
		"losses": 11,
		"archetype_fav": "sharpshooter",
		"is_ai_rival": true,
	},
	{
		"username": "Ren \"Mirage\" Kisaragi",
		"rating": 1760.0,
		"rating_deviation": 55.0,
		"peak_rating": 1790.0,
		"wins": 31,
		"losses": 14,
		"archetype_fav": "playmaker",
		"is_ai_rival": true,
	},
	{
		"username": "Daisuke \"Titan\" Kurogane",
		"rating": 1565.0,
		"rating_deviation": 58.0,
		"peak_rating": 1605.0,
		"wins": 24,
		"losses": 18,
		"archetype_fav": "powerhouse",
		"is_ai_rival": true,
	},
	{
		"username": "Kaelen \"Volt\" Arashi",
		"rating": 1385.0,
		"rating_deviation": 62.0,
		"peak_rating": 1430.0,
		"wins": 18,
		"losses": 19,
		"archetype_fav": "speedster",
		"is_ai_rival": true,
	},
	{
		"username": "Riku \"Rookie\" Tanaka",
		"rating": 1190.0,
		"rating_deviation": 75.0,
		"peak_rating": 1240.0,
		"wins": 9,
		"losses": 21,
		"archetype_fav": "speedster",
		"is_ai_rival": true,
	},
]

var _save_path: String = DEFAULT_SAVE_PATH
var _profile: Dictionary = {}
var _match_history: Array[Dictionary] = []


func _ready() -> void:
	_init_default_state()
	load_from_disk()


func set_save_path(path: String, reload_now: bool = true) -> void:
	_save_path = path.strip_edges() if not path.strip_edges().is_empty() else DEFAULT_SAVE_PATH
	if reload_now:
		_init_default_state()
		load_from_disk()


func get_save_path() -> String:
	return _save_path


func _init_default_state() -> void:
	var default_name := "PhantomPlayer"
	var default_arch := "all_rounder"
	var gs: Node = _get_autoload("GameState")
	if gs != null:
		if gs.get("player_name") != null and not str(gs.get("player_name")).strip_edges().is_empty():
			default_name = str(gs.get("player_name")).strip_edges()
		if gs.get("selected_archetype") != null and not str(gs.get("selected_archetype")).strip_edges().is_empty():
			default_arch = _normalize_archetype_id(str(gs.get("selected_archetype")))

	_profile = {
		"username": default_name,
		"archetype_fav": default_arch,
		"rating": DEFAULT_RATING,
		"rating_deviation": DEFAULT_RD,
		"rd": DEFAULT_RD,
		"volatility": DEFAULT_VOLATILITY,
		"peak_rating": DEFAULT_RATING,
		"division": division_for_rating(DEFAULT_RATING),
		"wins": 0,
		"losses": 0,
		"draws": 0,
		"matches_played": 0,
		"total_points": 0,
		"total_threes_made": 0,
		"total_assists": 0,
		"total_rebounds": 0,
		"total_steals": 0,
		"total_blocks": 0,
		"total_combos": 0,
		"total_zone_activations": 0,
	}
	_match_history.clear()


static func division_for_rating(rating: float) -> String:
	if rating < 1300.0:
		return "Bronze"
	elif rating < 1500.0:
		return "Silver"
	elif rating < 1700.0:
		return "Gold"
	elif rating < 1900.0:
		return "Platinum"
	elif rating < 2100.0:
		return "Diamond"
	return "Phantom"


static func get_ai_opponent_rating(difficulty_tier: Variant) -> float:
	var tier_idx: int = _resolve_difficulty_tier(difficulty_tier)
	return float(AI_DIFFICULTY_RATINGS.get(tier_idx, 1450.0))


static func _resolve_difficulty_tier(difficulty_tier: Variant) -> int:
	if difficulty_tier is int:
		return clampi(difficulty_tier as int, 0, 3)
	var s: String = str(difficulty_tier).strip_edges().to_lower()
	match s:
		"0", "rookie":
			return 0
		"1", "pro":
			return 1
		"2", "all-star", "all_star", "allstar":
			return 2
		"3", "phantom":
			return 3
	return 1


static func _normalize_archetype_id(arch_id: String) -> String:
	var cleaned: String = arch_id.strip_edges().to_lower()
	if cleaned == "phantom_pg" or cleaned.is_empty():
		return "speedster"
	if cleaned in ["speedster", "sharpshooter", "playmaker", "powerhouse", "all_rounder"]:
		return cleaned
	return "all_rounder"


func get_profile() -> Dictionary:
	if _profile.is_empty():
		_init_default_state()
	var out: Dictionary = _profile.duplicate(true)
	var r: float = float(out.get("rating", DEFAULT_RATING))
	var rd_val: float = float(out.get("rating_deviation", DEFAULT_RD))
	out["rd"] = rd_val
	out["division"] = division_for_rating(r)
	var w: int = int(out.get("wins", 0))
	var l: int = int(out.get("losses", 0))
	out["win_rate"] = (100.0 * float(w) / float(maxi(1, w + l))) if (w + l) > 0 else 0.0
	# Convenience aliases matching ProfileRankingsUI
	out["points"] = int(out.get("total_points", 0))
	out["assists"] = int(out.get("total_assists", 0))
	out["rebounds"] = int(out.get("total_rebounds", 0))
	out["blocks"] = int(out.get("total_blocks", 0))
	out["steals"] = int(out.get("total_steals", 0))
	out["zone_activations"] = int(out.get("total_zone_activations", 0))
	return out


func set_player_identity(username: String, archetype_fav: String = "") -> Dictionary:
	if _profile.is_empty():
		_init_default_state()
	var cleaned_name: String = username.strip_edges()
	if not cleaned_name.is_empty():
		_profile["username"] = cleaned_name
		var gs: Node = _get_autoload("GameState")
		if gs != null:
			gs.set("player_name", cleaned_name)
	if not archetype_fav.strip_edges().is_empty():
		_profile["archetype_fav"] = _normalize_archetype_id(archetype_fav)
	save_to_disk()
	var prof: Dictionary = get_profile()
	_emit_career_signals(prof)
	return prof


func record_offline_match(
	mode: String,
	difficulty_tier: Variant,
	team_a_score: int,
	team_b_score: int,
	player_stats: Dictionary = {},
	duration_sec: int = 180
) -> Dictionary:
	if _profile.is_empty():
		_init_default_state()

	var tier_idx: int = _resolve_difficulty_tier(difficulty_tier)
	var opp_rating: float = float(AI_DIFFICULTY_RATINGS.get(tier_idx, 1450.0))

	var r_before: float = float(_profile.get("rating", DEFAULT_RATING))
	var rd_before: float = float(_profile.get("rating_deviation", DEFAULT_RD))
	var vol_before: float = float(_profile.get("volatility", DEFAULT_VOLATILITY))

	var won: bool = team_a_score > team_b_score
	var drew: bool = team_a_score == team_b_score
	var outcome_s: float = 1.0 if won else (0.5 if drew else 0.0)

	var g2: Dictionary = compute_glicko2_step(
		r_before,
		rd_before,
		vol_before,
		opp_rating,
		AI_OPPONENT_RD,
		outcome_s
	)

	var r_after: float = float(g2["rating"])
	var rd_after: float = float(g2["rd"])
	var vol_after: float = float(g2["volatility"])
	var r_delta: float = r_after - r_before
	var new_div: String = division_for_rating(r_after)

	_profile["rating"] = r_after
	_profile["rating_deviation"] = rd_after
	_profile["rd"] = rd_after
	_profile["volatility"] = vol_after
	_profile["peak_rating"] = maxf(float(_profile.get("peak_rating", r_before)), r_after)
	_profile["division"] = new_div
	_profile["matches_played"] = int(_profile.get("matches_played", 0)) + 1
	if won:
		_profile["wins"] = int(_profile.get("wins", 0)) + 1
	elif drew:
		_profile["draws"] = int(_profile.get("draws", 0)) + 1
	else:
		_profile["losses"] = int(_profile.get("losses", 0)) + 1

	if player_stats.has("archetype") and not str(player_stats["archetype"]).strip_edges().is_empty():
		_profile["archetype_fav"] = _normalize_archetype_id(str(player_stats["archetype"]))
	elif player_stats.has("archetype_id") and not str(player_stats["archetype_id"]).strip_edges().is_empty():
		_profile["archetype_fav"] = _normalize_archetype_id(str(player_stats["archetype_id"]))

	var pts: int = int(player_stats.get("points", player_stats.get("pts", 0)))
	var threes: int = int(player_stats.get("three_pointers_made", player_stats.get("threes_made", player_stats.get("3pm", 0))))
	var ast: int = int(player_stats.get("assists", player_stats.get("ast", 0)))
	var reb: int = int(player_stats.get("rebounds", player_stats.get("reb", 0)))
	var stl: int = int(player_stats.get("steals", player_stats.get("stl", 0)))
	var blk: int = int(player_stats.get("blocks", player_stats.get("blk", 0)))
	var combos: int = int(player_stats.get("combos", player_stats.get("combos_landed", 0)))
	var zones: int = int(player_stats.get("zone_activations", player_stats.get("zone", 0)))

	_profile["total_points"] = int(_profile.get("total_points", 0)) + maxi(0, pts)
	_profile["total_threes_made"] = int(_profile.get("total_threes_made", 0)) + maxi(0, threes)
	_profile["total_assists"] = int(_profile.get("total_assists", 0)) + maxi(0, ast)
	_profile["total_rebounds"] = int(_profile.get("total_rebounds", 0)) + maxi(0, reb)
	_profile["total_steals"] = int(_profile.get("total_steals", 0)) + maxi(0, stl)
	_profile["total_blocks"] = int(_profile.get("total_blocks", 0)) + maxi(0, blk)
	_profile["total_combos"] = int(_profile.get("total_combos", 0)) + maxi(0, combos)
	_profile["total_zone_activations"] = int(_profile.get("total_zone_activations", 0)) + maxi(0, zones)

	var clean_mode: String = mode.strip_edges().trim_prefix("offline_").to_lower()
	if clean_mode.is_empty():
		clean_mode = "3v3"

	var match_entry: Dictionary = {
		"mode": clean_mode,
		"difficulty_tier": tier_idx,
		"difficulty": DIFFICULTY_LABELS[tier_idx],
		"opponent_rating": opp_rating,
		"score_a": team_a_score,
		"score_b": team_b_score,
		"team_score": team_a_score,
		"opp_score": team_b_score,
		"won": won,
		"drew": drew,
		"rating_before": r_before,
		"rating_after": r_after,
		"rating_delta": r_delta,
		"rd_after": rd_after,
		"division": new_div,
		"points": pts,
		"three_pointers_made": threes,
		"assists": ast,
		"rebounds": reb,
		"steals": stl,
		"blocks": blk,
		"combos": combos,
		"zone_activations": zones,
		"duration_sec": maxi(0, duration_sec),
		"timestamp": int(Time.get_unix_time_from_system()),
	}

	_match_history.push_front(match_entry)
	if _match_history.size() > MAX_STORED_HISTORY:
		_match_history.resize(MAX_STORED_HISTORY)

	save_to_disk()
	var prof: Dictionary = get_profile()
	_emit_career_signals(prof)

	return {
		"rating_before": r_before,
		"rating_after": r_after,
		"rating_delta": r_delta,
		"delta": r_delta,
		"rd_before": rd_before,
		"rd_after": rd_after,
		"volatility_after": vol_after,
		"division": new_div,
		"won": won,
		"drew": drew,
		"match_entry": match_entry.duplicate(true),
	}


static func compute_glicko2_step(
	r: float,
	rd: float,
	sigma: float,
	opp_r: float,
	opp_rd: float,
	score_s: float
) -> Dictionary:
	var mu: float = (r - 1500.0) / GLICKO2_SCALE
	var phi: float = clampf(rd, MIN_RD, MAX_RD) / GLICKO2_SCALE
	var vol: float = clampf(sigma, 0.01, 0.20)

	var mu_j: float = (opp_r - 1500.0) / GLICKO2_SCALE
	var phi_j: float = clampf(opp_rd, MIN_RD, MAX_RD) / GLICKO2_SCALE

	var g_j: float = 1.0 / sqrt(1.0 + (3.0 * phi_j * phi_j) / (PI * PI))
	var expected_e: float = 1.0 / (1.0 + exp(-g_j * (mu - mu_j)))
	expected_e = clampf(expected_e, 1e-6, 1.0 - 1e-6)

	var v: float = 1.0 / (g_j * g_j * expected_e * (1.0 - expected_e))
	var delta: float = v * g_j * (clampf(score_s, 0.0, 1.0) - expected_e)

	# Illinois volatility algorithm (Glickman Step 5)
	var a: float = log(vol * vol)
	var phi_sq: float = phi * phi
	var delta_sq: float = delta * delta
	var tau_sq: float = TAU * TAU

	var big_a: float = a
	var big_b: float = 0.0
	if delta_sq > phi_sq + v:
		big_b = log(delta_sq - phi_sq - v)
	else:
		var k: int = 1
		while k < 64 and _illinois_f(a - float(k) * TAU, delta_sq, phi_sq, v, a, tau_sq) < 0.0:
			k += 1
		big_b = a - float(k) * TAU

	var f_a: float = _illinois_f(big_a, delta_sq, phi_sq, v, a, tau_sq)
	var f_b: float = _illinois_f(big_b, delta_sq, phi_sq, v, a, tau_sq)

	var iter_count: int = 0
	while absf(big_b - big_a) > CONVERGENCE_TOLERANCE and iter_count < 100:
		iter_count += 1
		var denom: float = f_b - f_a
		if absf(denom) < 1e-12:
			break
		var big_c: float = big_a + (big_a - big_b) * f_a / denom
		var f_c: float = _illinois_f(big_c, delta_sq, phi_sq, v, a, tau_sq)
		if f_c * f_b <= 0.0:
			big_a = big_b
			f_a = f_b
		else:
			f_a *= 0.5
		big_b = big_c
		f_b = f_c

	var sigma_prime: float = clampf(exp(big_a * 0.5), 0.01, 0.20)
	var phi_star: float = sqrt(phi_sq + sigma_prime * sigma_prime)
	var phi_prime: float = 1.0 / sqrt((1.0 / (phi_star * phi_star)) + (1.0 / v))
	var mu_prime: float = mu + (phi_prime * phi_prime) * g_j * (clampf(score_s, 0.0, 1.0) - expected_e)

	var r_new: float = clampf(GLICKO2_SCALE * mu_prime + 1500.0, 100.0, 3500.0)
	var rd_new: float = clampf(GLICKO2_SCALE * phi_prime, MIN_RD, MAX_RD)

	return {
		"rating": r_new,
		"rd": rd_new,
		"volatility": sigma_prime,
	}


static func _illinois_f(
	x: float,
	delta_sq: float,
	phi_sq: float,
	v: float,
	a: float,
	tau_sq: float
) -> float:
	var ex: float = exp(x)
	var denom_base: float = phi_sq + v + ex
	var left: float = (ex * (delta_sq - phi_sq - v - ex)) / (2.0 * denom_base * denom_base)
	var right: float = (x - a) / tau_sq
	return left - right


func get_match_history(limit: int = 20) -> Array:
	var count: int = mini(maxi(0, limit), _match_history.size())
	var result: Array = []
	for i in range(count):
		result.append(_match_history[i].duplicate(true))
	return result


func get_leaderboard() -> Array:
	var prof: Dictionary = get_profile()
	var entries: Array[Dictionary] = []

	for rival in RIVAL_AI_LADDER:
		var r_val: float = float(rival.get("rating", 1500.0))
		var rw: int = int(rival.get("wins", 0))
		var rl: int = int(rival.get("losses", 0))
		entries.append({
			"username": str(rival.get("username", "Rival")),
			"rating": r_val,
			"rating_deviation": float(rival.get("rating_deviation", 60.0)),
			"rd": float(rival.get("rating_deviation", 60.0)),
			"division": division_for_rating(r_val),
			"wins": rw,
			"losses": rl,
			"win_rate": (100.0 * float(rw) / float(maxi(1, rw + rl))) if (rw + rl) > 0 else 0.0,
			"peak_rating": float(rival.get("peak_rating", r_val)),
			"archetype_fav": str(rival.get("archetype_fav", "all_rounder")),
			"is_local_player": false,
			"is_ai_rival": true,
		})

	var lw: int = int(prof.get("wins", 0))
	var ll: int = int(prof.get("losses", 0))
	var lr: float = float(prof.get("rating", DEFAULT_RATING))
	entries.append({
		"username": str(prof.get("username", "PhantomPlayer")),
		"rating": lr,
		"rating_deviation": float(prof.get("rating_deviation", DEFAULT_RD)),
		"rd": float(prof.get("rating_deviation", DEFAULT_RD)),
		"division": division_for_rating(lr),
		"wins": lw,
		"losses": ll,
		"win_rate": (100.0 * float(lw) / float(maxi(1, lw + ll))) if (lw + ll) > 0 else 0.0,
		"peak_rating": float(prof.get("peak_rating", lr)),
		"archetype_fav": str(prof.get("archetype_fav", "all_rounder")),
		"is_local_player": true,
		"is_ai_rival": false,
	})

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: float = float(a.get("rating", 0.0))
		var rb: float = float(b.get("rating", 0.0))
		if not is_equal_approx(ra, rb):
			return ra > rb
		return bool(a.get("is_local_player", false)) and not bool(b.get("is_local_player", false))
	)

	var out: Array = []
	for i in range(entries.size()):
		var row: Dictionary = entries[i]
		row["rank"] = i + 1
		out.append(row)
	return out


func save_to_disk() -> int:
	var dir_path: String = _save_path.get_base_dir()
	if not dir_path.is_empty() and not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var payload: Dictionary = {
		"version": 1,
		"profile": _profile,
		"match_history": _match_history,
	}
	var file := FileAccess.open(_save_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return OK


func load_from_disk() -> bool:
	if not FileAccess.file_exists(_save_path):
		return false
	var file := FileAccess.open(_save_path, FileAccess.READ)
	if file == null:
		return false
	var raw: String = file.get_as_text()
	file.close()
	if raw.strip_edges().is_empty():
		return false

	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return false
	var data: Dictionary = parsed as Dictionary

	if data.has("profile") and data["profile"] is Dictionary:
		var loaded_prof: Dictionary = data["profile"] as Dictionary
		for key in loaded_prof.keys():
			_profile[key] = loaded_prof[key]
		var r: float = float(_profile.get("rating", DEFAULT_RATING))
		_profile["division"] = division_for_rating(r)
		_profile["rd"] = float(_profile.get("rating_deviation", DEFAULT_RD))

	_match_history.clear()
	if data.has("match_history") and data["match_history"] is Array:
		for item in data["match_history"]:
			if item is Dictionary:
				_match_history.append((item as Dictionary).duplicate(true))
	return true


func reset_career(persist: bool = true) -> Dictionary:
	_init_default_state()
	if persist:
		save_to_disk()
	var prof: Dictionary = get_profile()
	_emit_career_signals(prof)
	return prof


func _emit_career_signals(prof: Dictionary) -> void:
	career_updated.emit(prof)
	var eb: Node = _get_autoload("EventBus")
	if eb != null:
		if eb.has_signal("profile_loaded"):
			eb.emit_signal("profile_loaded", prof)
		if eb.has_signal("leaderboard_loaded"):
			eb.emit_signal("leaderboard_loaded", get_leaderboard())


static func _get_autoload(node_name: String) -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null(node_name)
	return null
