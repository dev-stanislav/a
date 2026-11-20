extends Node
## Canonical global EventBus autoload for Phantom Court Online.
## All cross-system signals follow ARCHITECTURE.md contracts.

# Match & Score
signal match_started(match_config: Dictionary)
signal score_changed(team_id: int, new_score: int, delta: int, is_three: bool, scorer_id: int)
signal timer_updated(match_seconds_left: float, shot_clock_left: float)
signal possession_changed(team_id: int, carrier_id: int)
signal match_ended(winner_team: int, final_scores: Array, stats: Dictionary)
signal match_restarted()

# Ball & Player Motion
signal ball_bounced(world_pos: Vector3, impact_speed: float, surface_type: String)
signal player_footstep(player_id: int, world_pos: Vector3, is_sprint: bool)
signal dribble_move_performed(player_id: int, move_name: String, world_pos: Vector3)
signal combo_triggered(player_id: int, combo_id: String, combo_tier: int, is_perfect: bool)

# Offense, Defense & Zone
signal shot_released(player_id: int, release_pos: Vector3, target_rim: Vector3, is_three: bool, timing_quality: float)
signal shot_timing_feedback(player_id: int, label: String, timing_error: float)
signal dunk_impact(player_id: int, rim_pos: Vector3, power: float)
signal ankle_broken(victim_id: int, attacker_id: int, world_pos: Vector3)
signal block_performed(blocker_id: int, shooter_id: int, world_pos: Vector3)
signal steal_performed(stealer_id: int, victim_id: int, world_pos: Vector3)
signal zone_activated(player_id: int, duration: float)
signal zone_ended(player_id: int)

# Meters & Input Telemetry
signal stamina_updated(player_id: int, current: float, maximum: float)
signal zone_meter_updated(player_id: int, current: float, maximum: float)
signal input_recorded(player_id: int, frame: Dictionary)

# Networking & Persistence
signal net_connected(session_info: Dictionary)
signal net_disconnected(reason: String)
signal lobby_state_updated(lobby_state: Dictionary)
signal net_metrics_updated(metrics: Dictionary)
signal profile_loaded(profile: Dictionary)
signal leaderboard_loaded(entries: Array)
