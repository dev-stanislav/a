class_name ArchetypeData
extends RefCounted
## Structured character archetype definition for PHANTOM COURT ONLINE (Phase 4).
## Encapsulates identity, strengths/weaknesses, visual palette, rig proportions,
## animation variations, 18 gameplay stats, unique signature skill ID, and UI rating bars.
## Produces a dictionary via to_dict() directly consumable by PlayerController.apply_archetype().

const BASE_SHOT_ARC: float = 1.35

var id: String = ""
var character_name: String = ""
var nickname: String = ""
var class_name_display: String = ""
var tagline: String = ""

var strengths: Array[String] = []
var weaknesses: Array[String] = []

# Keys: primary, secondary, accent, aura, hair (all Color)
var colors: Dictionary = {
	"primary": Color(0.10, 0.45, 0.92, 1.0),
	"secondary": Color(0.95, 0.97, 1.0, 1.0),
	"accent": Color(0.20, 0.92, 1.0, 1.0),
	"aura": Color(0.20, 0.92, 1.0, 1.0),
	"hair": Color(0.32, 0.78, 1.0, 1.0),
}

var rig_scale: Vector3 = Vector3.ONE

# Keys: run_speed_scale, dribble_speed_scale, shot_release_height, stance_crouch_offset, posture_style
var anim_variation: Dictionary = {
	"run_speed_scale": 1.0,
	"dribble_speed_scale": 1.0,
	"shot_release_height": 0.0,
	"stance_crouch_offset": 0.0,
	"posture_style": "balanced_two_way",
}

# Canonical 18 gameplay stat keys
var stats: Dictionary = {
	"run_speed": 6.2,
	"sprint_speed": 8.8,
	"acceleration": 38.0,
	"jump_velocity": 6.8,
	"max_stamina": 100.0,
	"stamina_regen": 20.0,
	"dribble_stamina_mult": 1.0,
	"three_point_range": 7.5,
	"perfect_window_bonus": 0.0,
	"shot_arc_bonus": 0.0,
	"dunk_radius": 2.90,
	"pass_speed_mult": 1.0,
	"cancel_window_bonus": 0,
	"ankle_break_mult": 1.0,
	"block_radius": 1.70,
	"steal_radius": 1.75,
	"balance_resistance": 1.0,
	"zone_gain_mult": 1.0,
}

var unique_skill_id: String = ""

# 0-100 UI ratings: speed, shooting, dunk, playmaking, defense, stamina
var rating_bars: Dictionary = {
	"speed": 75,
	"shooting": 75,
	"dunk": 75,
	"playmaking": 75,
	"defense": 75,
	"stamina": 75,
}


func _init(config: Dictionary = {}) -> void:
	if not config.is_empty():
		configure(config)


func configure(config: Dictionary) -> ArchetypeData:
	id = str(config.get("id", config.get("archetype_id", id)))
	character_name = str(config.get("character_name", character_name))
	nickname = str(config.get("nickname", nickname))
	class_name_display = str(config.get("class_name_display", class_name_display))
	tagline = str(config.get("tagline", tagline))
	unique_skill_id = str(config.get("unique_skill_id", unique_skill_id))

	if config.has("strengths") and config["strengths"] is Array:
		strengths.clear()
		for item in (config["strengths"] as Array):
			strengths.append(str(item))

	if config.has("weaknesses") and config["weaknesses"] is Array:
		weaknesses.clear()
		for item in (config["weaknesses"] as Array):
			weaknesses.append(str(item))

	if config.has("colors") and config["colors"] is Dictionary:
		var src_cols: Dictionary = config["colors"]
		for k in src_cols.keys():
			colors[str(k)] = _parse_color(src_cols[k], colors.get(str(k), Color.WHITE))
	else:
		if config.has("jersey_color"):
			colors["primary"] = _parse_color(config["jersey_color"], colors["primary"])
		if config.has("secondary_color"):
			colors["secondary"] = _parse_color(config["secondary_color"], colors["secondary"])
		if config.has("accent_color"):
			colors["accent"] = _parse_color(config["accent_color"], colors["accent"])
		if config.has("aura_color"):
			colors["aura"] = _parse_color(config["aura_color"], colors["aura"])
		if config.has("hair_color"):
			colors["hair"] = _parse_color(config["hair_color"], colors["hair"])

	if not colors.has("hair"):
		colors["hair"] = colors.get("accent", Color.WHITE)

	if config.has("rig_scale"):
		rig_scale = _parse_vec3(config["rig_scale"], rig_scale)

	if config.has("anim_variation") and config["anim_variation"] is Dictionary:
		var src_anim: Dictionary = config["anim_variation"]
		for k in src_anim.keys():
			var key: String = str(k)
			if key == "posture_style":
				anim_variation[key] = str(src_anim[k])
			else:
				anim_variation[key] = float(src_anim[k])

	if config.has("stats") and config["stats"] is Dictionary:
		var src_stats: Dictionary = config["stats"]
		for k in src_stats.keys():
			var key: String = str(k)
			if key == "cancel_window_bonus":
				stats[key] = int(src_stats[k])
			else:
				stats[key] = float(src_stats[k])
	else:
		# Support flat legacy dicts as fallback
		for k in stats.keys():
			if config.has(k):
				if k == "cancel_window_bonus":
					stats[k] = int(config[k])
				else:
					stats[k] = float(config[k])
		if config.has("stamina_max"):
			stats["max_stamina"] = float(config["stamina_max"])
		if config.has("zone_gain_rate"):
			stats["zone_gain_mult"] = float(config["zone_gain_rate"])

	if config.has("rating_bars") and config["rating_bars"] is Dictionary:
		var src_bars: Dictionary = config["rating_bars"]
		for k in src_bars.keys():
			rating_bars[str(k)] = clampi(int(src_bars[k]), 0, 100)

	return self


static func from_dict(data: Dictionary) -> ArchetypeData:
	return ArchetypeData.new(data)


func get_stat(stat_name: String, default_val: Variant = 0.0) -> Variant:
	return stats.get(stat_name, default_val)


func get_color(color_key: String, default_col: Color = Color.WHITE) -> Color:
	var val: Variant = colors.get(color_key, default_col)
	return val as Color if val is Color else default_col


func get_anim_param(key: String, default_val: Variant = 0.0) -> Variant:
	return anim_variation.get(key, default_val)


func get_rating(key: String, default_val: int = 50) -> int:
	return int(rating_bars.get(key, default_val))


## Exports both the canonical structured Phase 4 fields AND flat PlayerController
## compatibility aliases so PlayerController.apply_archetype(archetype_dict) works directly.
func to_dict() -> Dictionary:
	var strengths_copy: Array[String] = []
	for s in strengths:
		strengths_copy.append(s)

	var weaknesses_copy: Array[String] = []
	for w in weaknesses:
		weaknesses_copy.append(w)

	var colors_copy: Dictionary = colors.duplicate(true)
	var anim_copy: Dictionary = anim_variation.duplicate(true)
	var stats_copy: Dictionary = stats.duplicate(true)
	var ratings_copy: Dictionary = rating_bars.duplicate(true)

	var perfect_bonus: float = float(stats_copy.get("perfect_window_bonus", 0.0))
	var arc_bonus: float = float(stats_copy.get("shot_arc_bonus", 0.0))
	var max_stam: float = float(stats_copy.get("max_stamina", 100.0))
	var zone_mult: float = float(stats_copy.get("zone_gain_mult", 1.0))

	return {
		# Canonical structured Phase 4 contract
		"id": id,
		"archetype_id": id,
		"character_name": character_name,
		"nickname": nickname,
		"class_name_display": class_name_display,
		"tagline": tagline,
		"strengths": strengths_copy,
		"weaknesses": weaknesses_copy,
		"colors": colors_copy,
		"rig_scale": rig_scale,
		"anim_variation": anim_copy,
		"stats": stats_copy,
		"unique_skill_id": unique_skill_id,
		"rating_bars": ratings_copy,

		# Flat compatibility aliases for PlayerController.apply_archetype()
		"run_speed": float(stats_copy.get("run_speed", 6.2)),
		"sprint_speed": float(stats_copy.get("sprint_speed", 8.8)),
		"acceleration": float(stats_copy.get("acceleration", 38.0)),
		"jump_velocity": float(stats_copy.get("jump_velocity", 6.8)),
		"max_stamina": max_stam,
		"stamina_max": max_stam,
		"stamina_regen": float(stats_copy.get("stamina_regen", 20.0)),
		"dribble_stamina_mult": float(stats_copy.get("dribble_stamina_mult", 1.0)),
		"three_point_range": float(stats_copy.get("three_point_range", 7.5)),
		"perfect_window_bonus": perfect_bonus,
		"shot_timing_window": maxf(0.5, 1.0 + perfect_bonus),
		"shot_arc_bonus": arc_bonus,
		"shot_arc": BASE_SHOT_ARC + arc_bonus,
		"dunk_radius": float(stats_copy.get("dunk_radius", 2.90)),
		"pass_speed_mult": float(stats_copy.get("pass_speed_mult", 1.0)),
		"cancel_window_bonus": int(stats_copy.get("cancel_window_bonus", 0)),
		"ankle_break_mult": float(stats_copy.get("ankle_break_mult", 1.0)),
		"block_radius": float(stats_copy.get("block_radius", 1.70)),
		"steal_radius": float(stats_copy.get("steal_radius", 1.75)),
		"balance_resistance": float(stats_copy.get("balance_resistance", 1.0)),
		"zone_gain_mult": zone_mult,
		"zone_gain_rate": zone_mult,
		"zone_max": 100.0,
		"jersey_color": colors_copy.get("primary", Color.WHITE),
		"secondary_color": colors_copy.get("secondary", Color.WHITE),
		"accent_color": colors_copy.get("accent", Color.WHITE),
		"aura_color": colors_copy.get("aura", Color.WHITE),
		"hair_color": colors_copy.get("hair", colors_copy.get("accent", Color.WHITE)),
	}


static func _parse_color(val: Variant, fallback: Color) -> Color:
	if val is Color:
		return val as Color
	if val is String:
		return Color.from_string(str(val), fallback)
	return fallback


static func _parse_vec3(val: Variant, fallback: Vector3) -> Vector3:
	if val is Vector3:
		return val as Vector3
	if val is Dictionary:
		var d := val as Dictionary
		return Vector3(
			float(d.get("x", fallback.x)),
			float(d.get("y", fallback.y)),
			float(d.get("z", fallback.z))
		)
	if val is Array and (val as Array).size() >= 3:
		var a := val as Array
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback
