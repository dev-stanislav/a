class_name AIDifficulty
extends RefCounted
## Canonical 4-tier deterministic AI difficulty profiles for PHANTOM COURT ONLINE (Phase 7).
## Controls reaction delay (60 Hz frames), shot release jitter, combo execution probability,
## steal discipline, block timing accuracy, pass vision, decision cadence, and Zone IQ.

enum Tier {
	ROOKIE = 0,
	PRO = 1,
	ALL_STAR = 2,
	PHANTOM = 3,
}

const PROFILES: Dictionary = {
	Tier.ROOKIE: {
		"tier": Tier.ROOKIE,
		"name": "ROOKIE",
		"reaction_delay_frames": 24,
		"shot_timing_jitter_sec": 0.095,
		"combo_probability": 0.08,
		"steal_discipline": 0.30,
		"block_timing_accuracy": 0.35,
		"pass_vision": 0.45,
		"decision_interval_frames": 14,
		"zone_iq": 0.35,
		"combo_step_gap_frames": 11,
		"decision_noise": 0.14,
	},
	Tier.PRO: {
		"tier": Tier.PRO,
		"name": "PRO",
		"reaction_delay_frames": 12,
		"shot_timing_jitter_sec": 0.055,
		"combo_probability": 0.28,
		"steal_discipline": 0.58,
		"block_timing_accuracy": 0.62,
		"pass_vision": 0.70,
		"decision_interval_frames": 8,
		"zone_iq": 0.65,
		"combo_step_gap_frames": 9,
		"decision_noise": 0.08,
	},
	Tier.ALL_STAR: {
		"tier": Tier.ALL_STAR,
		"name": "ALL_STAR",
		"reaction_delay_frames": 6,
		"shot_timing_jitter_sec": 0.025,
		"combo_probability": 0.55,
		"steal_discipline": 0.80,
		"block_timing_accuracy": 0.82,
		"pass_vision": 0.88,
		"decision_interval_frames": 4,
		"zone_iq": 0.88,
		"combo_step_gap_frames": 7,
		"decision_noise": 0.035,
	},
	Tier.PHANTOM: {
		"tier": Tier.PHANTOM,
		"name": "PHANTOM",
		"reaction_delay_frames": 3,
		"shot_timing_jitter_sec": 0.008,
		"combo_probability": 0.82,
		"steal_discipline": 0.94,
		"block_timing_accuracy": 0.95,
		"pass_vision": 0.96,
		"decision_interval_frames": 2,
		"zone_iq": 0.98,
		"combo_step_gap_frames": 6,
		"decision_noise": 0.012,
	},
}


static func get_all_tiers() -> Array[int]:
	return [Tier.ROOKIE, Tier.PRO, Tier.ALL_STAR, Tier.PHANTOM]


static func clamp_tier(tier: int) -> int:
	return clampi(tier, Tier.ROOKIE, Tier.PHANTOM)


static func get_profile(tier: int) -> Dictionary:
	var clamped: int = clamp_tier(tier)
	return (PROFILES[clamped] as Dictionary).duplicate(true)


static func get_tier_name(tier: int) -> String:
	var clamped: int = clamp_tier(tier)
	return str((PROFILES[clamped] as Dictionary)["name"])


static func from_name(name_str: String) -> int:
	var key: String = name_str.strip_edges().to_upper().replace("-", "_").replace(" ", "_")
	match key:
		"ROOKIE", "EASY", "0":
			return Tier.ROOKIE
		"PRO", "MEDIUM", "NORMAL", "1":
			return Tier.PRO
		"ALL_STAR", "ALLSTAR", "HARD", "2":
			return Tier.ALL_STAR
		"PHANTOM", "EXPERT", "LEGEND", "3":
			return Tier.PHANTOM
		_:
			return Tier.PRO
