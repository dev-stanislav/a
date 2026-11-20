class_name ArchetypeRegistry
extends RefCounted
## Canonical roster of all 5 playable anime basketball archetypes for PHANTOM COURT ONLINE:
##   1. speedster    — Kaelen "Volt" Arashi      (volt_dash:          Q, Shift, Q)
##   2. sharpshooter — Sora "Deadeye" Hoshino    (starlight_high_arc: E, S, LMB)
##   3. playmaker    — Ren "Mirage" Kisaragi     (mirage_thread:      Q, E, RMB)
##   4. powerhouse   — Daisuke "Titan" Kurogane  (tectonic_slam:      Shift, Space, LMB)
##   5. all_rounder  — Akira "Eclipse" Shinohara (eclipse_counter:    C, Q, E, Shift)

const ID_SPEEDSTER := "speedster"
const ID_SHARPSHOOTER := "sharpshooter"
const ID_PLAYMAKER := "playmaker"
const ID_POWERHOUSE := "powerhouse"
const ID_ALL_ROUNDER := "all_rounder"

const ORDERED_IDS: Array[String] = [
	ID_SPEEDSTER,
	ID_SHARPSHOOTER,
	ID_PLAYMAKER,
	ID_POWERHOUSE,
	ID_ALL_ROUNDER,
]

static var _archetypes: Dictionary = {} # id: String -> ArchetypeData
static var _initialized: bool = false


static func _ensure_initialized() -> void:
	if _initialized:
		return
	_initialized = true
	_archetypes.clear()

	# 1. Speedster — Kaelen "Volt" Arashi
	_register(ArchetypeData.new({
		"id": ID_SPEEDSTER,
		"character_name": "Kaelen \"Volt\" Arashi",
		"nickname": "Volt",
		"class_name_display": "Speedster",
		"tagline": "Lightning-fast perimeter blur who shatters containment before defenders blink.",
		"strengths": [
			"Fastest run & sprint speed on the court (6.9 / 9.8 m/s)",
			"Rapid 26/s stamina regen & 0.80x dribble stamina efficiency",
			"Volt Dash lightning zig-zag burst with steal immunity",
		],
		"weaknesses": [
			"Compact stamina pool (85 max) punishes careless over-sprinting",
			"Low shot-block reach (1.40m) in the paint",
			"Lower balance resistance (0.80x) against heavy shockwaves",
		],
		"colors": {
			"primary": Color("#00F0FF"),
			"secondary": Color("#FFFFFF"),
			"accent": Color("#38BDF8"),
			"aura": Color("#00F0FF"),
			"hair": Color("#7DF9FF"),
		},
		"rig_scale": Vector3(0.95, 0.96, 0.95),
		"anim_variation": {
			"run_speed_scale": 1.18,
			"dribble_speed_scale": 1.20,
			"shot_release_height": 0.0,
			"stance_crouch_offset": -0.06,
			"posture_style": "low_blitz",
		},
		"stats": {
			"run_speed": 6.9,
			"sprint_speed": 9.8,
			"acceleration": 46.0,
			"jump_velocity": 6.8,
			"max_stamina": 85.0,
			"stamina_regen": 26.0,
			"dribble_stamina_mult": 0.80,
			"three_point_range": 7.4,
			"perfect_window_bonus": 0.0,
			"shot_arc_bonus": 0.0,
			"dunk_radius": 2.75,
			"pass_speed_mult": 1.05,
			"cancel_window_bonus": 2,
			"ankle_break_mult": 1.10,
			"block_radius": 1.40,
			"steal_radius": 1.90,
			"balance_resistance": 0.80,
			"zone_gain_mult": 1.05,
		},
		"unique_skill_id": "volt_dash",
		"rating_bars": {
			"speed": 98,
			"shooting": 74,
			"dunk": 70,
			"playmaking": 82,
			"defense": 64,
			"stamina": 78,
		},
	}))

	# 2. Sharpshooter — Sora "Deadeye" Hoshino
	_register(ArchetypeData.new({
		"id": ID_SHARPSHOOTER,
		"character_name": "Sora \"Deadeye\" Hoshino",
		"nickname": "Deadeye",
		"class_name_display": "Sharpshooter",
		"tagline": "Deep-range marksman firing unblockable high-arc rainbow threes from anywhere past half-court.",
		"strengths": [
			"Deep 9.8m three-point effective range",
			"+35% wider Green Perfect shot timing window & +0.55m rainbow arc",
			"Starlight High Arc step-fade jumper resists shot blocks",
		],
		"weaknesses": [
			"Slower foot speed & recovery sprint (5.9 / 8.2 m/s)",
			"Limited rim dunk reach (2.35m)",
			"Narrower perimeter steal radius (1.55m)",
		],
		"colors": {
			"primary": Color("#FF2A6D"),
			"secondary": Color("#FFD166"),
			"accent": Color("#FFD166"),
			"aura": Color("#FF4D88"),
			"hair": Color("#FFE08A"),
		},
		"rig_scale": Vector3(0.97, 1.01, 0.97),
		"anim_variation": {
			"run_speed_scale": 0.94,
			"dribble_speed_scale": 0.95,
			"shot_release_height": 0.18,
			"stance_crouch_offset": 0.02,
			"posture_style": "poised_sniper",
		},
		"stats": {
			"run_speed": 5.9,
			"sprint_speed": 8.2,
			"acceleration": 34.0,
			"jump_velocity": 6.7,
			"max_stamina": 95.0,
			"stamina_regen": 21.0,
			"dribble_stamina_mult": 1.05,
			"three_point_range": 9.8,
			"perfect_window_bonus": 0.35,
			"shot_arc_bonus": 0.55,
			"dunk_radius": 2.35,
			"pass_speed_mult": 1.00,
			"cancel_window_bonus": 0,
			"ankle_break_mult": 0.90,
			"block_radius": 1.55,
			"steal_radius": 1.55,
			"balance_resistance": 0.90,
			"zone_gain_mult": 1.05,
		},
		"unique_skill_id": "starlight_high_arc",
		"rating_bars": {
			"speed": 68,
			"shooting": 99,
			"dunk": 56,
			"playmaking": 74,
			"defense": 62,
			"stamina": 80,
		},
	}))

	# 3. Playmaker — Ren "Mirage" Kisaragi
	_register(ArchetypeData.new({
		"id": ID_PLAYMAKER,
		"character_name": "Ren \"Mirage\" Kisaragi",
		"nickname": "Mirage",
		"class_name_display": "Playmaker",
		"tagline": "Phantom court general chaining fluid dribble cancels into razor-sharp laser assists.",
		"strengths": [
			"+4f extended combo cancel windows & 1.25x ankle-break power",
			"1.35x laser passes that boost teammate Zone & shot quality",
			"1.25x accelerated Zone meter buildup",
		],
		"weaknesses": [
			"Modest rim dunk reach (2.65m)",
			"Lighter interior block presence (1.55m)",
			"Depends on combo flow & spacing against paint bruisers",
		],
		"colors": {
			"primary": Color("#9D4EDD"),
			"secondary": Color("#E0E7FF"),
			"accent": Color("#C77DFF"),
			"aura": Color("#9D4EDD"),
			"hair": Color("#D8DCFF"),
		},
		"rig_scale": Vector3(0.99, 1.00, 0.99),
		"anim_variation": {
			"run_speed_scale": 1.05,
			"dribble_speed_scale": 1.15,
			"shot_release_height": 0.04,
			"stance_crouch_offset": -0.04,
			"posture_style": "fluid_maestro",
		},
		"stats": {
			"run_speed": 6.4,
			"sprint_speed": 9.0,
			"acceleration": 41.0,
			"jump_velocity": 6.75,
			"max_stamina": 100.0,
			"stamina_regen": 22.0,
			"dribble_stamina_mult": 0.90,
			"three_point_range": 7.8,
			"perfect_window_bonus": 0.10,
			"shot_arc_bonus": 0.10,
			"dunk_radius": 2.65,
			"pass_speed_mult": 1.35,
			"cancel_window_bonus": 4,
			"ankle_break_mult": 1.25,
			"block_radius": 1.55,
			"steal_radius": 1.85,
			"balance_resistance": 0.95,
			"zone_gain_mult": 1.25,
		},
		"unique_skill_id": "mirage_thread",
		"rating_bars": {
			"speed": 84,
			"shooting": 80,
			"dunk": 66,
			"playmaking": 98,
			"defense": 74,
			"stamina": 86,
		},
	}))

	# 4. Powerhouse — Daisuke "Titan" Kurogane
	_register(ArchetypeData.new({
		"id": ID_POWERHOUSE,
		"character_name": "Daisuke \"Titan\" Kurogane",
		"nickname": "Titan",
		"class_name_display": "Powerhouse",
		"tagline": "Unmovable paint juggernaut who crushes rims with seismic slams and swat-blocks every drive.",
		"strengths": [
			"Massive 4.20m dunk radius & armored Tectonic Slam shockwave",
			"Dominant 2.15m block radius & 2.0x ankle-break balance resistance",
			"Deep 115 max stamina tank for relentless paint battles",
		],
		"weaknesses": [
			"Heavy court speed (5.8 / 8.3 m/s) & slower acceleration",
			"High 1.30x dribble stamina drain discourages perimeter iso spam",
			"Limited 6.8m three-point shooting range",
		],
		"colors": {
			"primary": Color("#FF6B1A"),
			"secondary": Color("#141824"),
			"accent": Color("#FF9E00"),
			"aura": Color("#FF6B1A"),
			"hair": Color("#2A1B16"),
		},
		"rig_scale": Vector3(1.14, 1.08, 1.12),
		"anim_variation": {
			"run_speed_scale": 0.90,
			"dribble_speed_scale": 0.88,
			"shot_release_height": 0.12,
			"stance_crouch_offset": -0.02,
			"posture_style": "power_frame",
		},
		"stats": {
			"run_speed": 5.8,
			"sprint_speed": 8.3,
			"acceleration": 33.0,
			"jump_velocity": 7.35,
			"max_stamina": 115.0,
			"stamina_regen": 18.0,
			"dribble_stamina_mult": 1.30,
			"three_point_range": 6.8,
			"perfect_window_bonus": -0.05,
			"shot_arc_bonus": 0.0,
			"dunk_radius": 4.20,
			"pass_speed_mult": 0.95,
			"cancel_window_bonus": 0,
			"ankle_break_mult": 0.85,
			"block_radius": 2.15,
			"steal_radius": 1.50,
			"balance_resistance": 2.0,
			"zone_gain_mult": 1.00,
		},
		"unique_skill_id": "tectonic_slam",
		"rating_bars": {
			"speed": 64,
			"shooting": 58,
			"dunk": 99,
			"playmaking": 62,
			"defense": 94,
			"stamina": 92,
		},
	}))

	# 5. All-Rounder — Akira "Eclipse" Shinohara
	_register(ArchetypeData.new({
		"id": ID_ALL_ROUNDER,
		"character_name": "Akira \"Eclipse\" Shinohara",
		"nickname": "Eclipse",
		"class_name_display": "All-Rounder",
		"tagline": "Relentless two-way ace who shifts seamlessly from lockdown closeouts into lethal counter-drives.",
		"strengths": [
			"Elite two-way balance with zero glaring weaknesses",
			"Eclipse Counter works BOTH on-ball (drive) and off-ball (defense closeout)",
			"105 stamina, 22/s regen, 1.80m block, 1.85m steal & 1.20x balance stability",
		],
		"weaknesses": [
			"Out-sprinted in open court by Speedster",
			"Shorter deep range than Sharpshooter (8.0m vs 9.8m)",
			"Smaller rim dunk reach than Powerhouse (3.20m vs 4.20m)",
		],
		"colors": {
			"primary": Color("#00E5A3"),
			"secondary": Color("#0E1A2B"),
			"accent": Color("#5CE1E6"),
			"aura": Color("#00E5A3"),
			"hair": Color("#132A3E"),
		},
		"rig_scale": Vector3(1.02, 1.02, 1.02),
		"anim_variation": {
			"run_speed_scale": 1.03,
			"dribble_speed_scale": 1.04,
			"shot_release_height": 0.06,
			"stance_crouch_offset": -0.05,
			"posture_style": "balanced_two_way",
		},
		"stats": {
			"run_speed": 6.4,
			"sprint_speed": 9.0,
			"acceleration": 40.0,
			"jump_velocity": 7.0,
			"max_stamina": 105.0,
			"stamina_regen": 22.0,
			"dribble_stamina_mult": 0.95,
			"three_point_range": 8.0,
			"perfect_window_bonus": 0.12,
			"shot_arc_bonus": 0.18,
			"dunk_radius": 3.20,
			"pass_speed_mult": 1.10,
			"cancel_window_bonus": 2,
			"ankle_break_mult": 1.05,
			"block_radius": 1.80,
			"steal_radius": 1.85,
			"balance_resistance": 1.20,
			"zone_gain_mult": 1.10,
		},
		"unique_skill_id": "eclipse_counter",
		"rating_bars": {
			"speed": 84,
			"shooting": 84,
			"dunk": 82,
			"playmaking": 82,
			"defense": 88,
			"stamina": 88,
		},
	}))


static func _register(arch: ArchetypeData) -> void:
	_archetypes[arch.id] = arch


static func get_all_ids() -> Array[String]:
	_ensure_initialized()
	var ids: Array[String] = []
	for arch_id in ORDERED_IDS:
		if _archetypes.has(arch_id):
			ids.append(arch_id)
	return ids


static func get_all_archetypes() -> Array[ArchetypeData]:
	_ensure_initialized()
	var list: Array[ArchetypeData] = []
	for arch_id in ORDERED_IDS:
		if _archetypes.has(arch_id):
			list.append(_archetypes[arch_id] as ArchetypeData)
	return list


static func has_archetype(archetype_id: String) -> bool:
	_ensure_initialized()
	return _archetypes.has(archetype_id.strip_edges().to_lower())


static func get_archetype(archetype_id: String) -> ArchetypeData:
	_ensure_initialized()
	var key: String = archetype_id.strip_edges().to_lower()
	if not _archetypes.has(key):
		return null
	return _archetypes[key] as ArchetypeData


static func get_archetype_dict(archetype_id: String) -> Dictionary:
	var arch: ArchetypeData = get_archetype(archetype_id)
	if arch == null:
		return {}
	return arch.to_dict()


static func get_archetype_or_default(archetype_id: String) -> ArchetypeData:
	var resolved: String = resolve_id(archetype_id)
	var arch: ArchetypeData = get_archetype(resolved)
	if arch != null:
		return arch
	return get_archetype(ID_ALL_ROUNDER)


static func get_unique_skill_id(archetype_id: String) -> String:
	var arch: ArchetypeData = get_archetype(archetype_id)
	return arch.unique_skill_id if arch != null else ""


static func resolve_id(raw_id: String) -> String:
	var key: String = raw_id.strip_edges().to_lower()
	if has_archetype(key):
		return key
	match key:
		"phantom_pg", "volt", "pg":
			return ID_SPEEDSTER
		"deadeye", "sg":
			return ID_SHARPSHOOTER
		"mirage", "sf":
			return ID_PLAYMAKER
		"titan", "pf", "c", "rim_titan":
			return ID_POWERHOUSE
		"eclipse", "balanced":
			return ID_ALL_ROUNDER
		_:
			return ID_ALL_ROUNDER
