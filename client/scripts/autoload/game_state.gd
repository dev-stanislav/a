extends Node
## Canonical GameState autoload holding session, match, player, network, and mobile/offline state.

enum MatchPhase {
	IDLE,
	LOBBY,
	COUNTDOWN,
	LIVE,
	PAUSED,
	POST_MATCH,
}

# Match configuration & live state
var match_mode: String = "offline_3v3"
var selected_mode: String = "3v3"
var selected_difficulty: int = 1 # 0=Rookie, 1=Pro, 2=All-Star, 3=Phantom
var selected_difficulty_name: String = "Pro"
var auto_spawn_roster: bool = false
var match_phase: MatchPhase = MatchPhase.IDLE
var scores: Array[int] = [0, 0]
var match_duration_seconds: float = 180.0
var match_seconds_left: float = 180.0
var shot_clock_seconds: float = 24.0
var shot_clock_left: float = 24.0
var possession_team: int = 0
var ball_carrier_id: int = -1
var current_tick: int = 0

# Local player & profile identity
var local_player_id: int = 1
var local_team_id: int = 0
var player_name: String = "PhantomPlayer"
var selected_archetype: String = "phantom_pg"
var account_id: String = ""
var auth_token: String = ""
var profile_data: Dictionary = {}

# Mobile / iOS Local Offline Edition flag (auto-true on iOS/mobile, toggleable in tests)
var offline_local_mode: bool = false

# Network / Server endpoints (configurable via CLI or ConfigManager)
var server_host: String = "127.0.0.1"
var server_udp_port: int = 7777
var server_http_port: int = 8080
var is_online: bool = false
var is_spectator: bool = false
var current_lobby_id: String = ""
var current_room_id: int = 0
var current_room_code: String = ""
var lobby_state: Dictionary = {}
var spectate_ticket: Dictionary = {}
var auto_quickplay: bool = false


func _init() -> void:
	offline_local_mode = is_mobile_platform()


func _ready() -> void:
	offline_local_mode = offline_local_mode or is_mobile_platform()
	_parse_cmdline_args()


func is_mobile_platform() -> bool:
	return OS.has_feature("ios") or OS.has_feature("mobile")


func is_local_offline_build() -> bool:
	return offline_local_mode


func set_offline_local_mode(enabled: bool) -> void:
	offline_local_mode = enabled
	if enabled:
		is_online = false


func _parse_cmdline_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		var arg: String = args[i]
		match arg:
			"--host":
				if i + 1 < args.size():
					server_host = args[i + 1]
					i += 1
			"--port":
				if i + 1 < args.size():
					server_udp_port = maxi(1, int(args[i + 1]))
					i += 1
			"--http-port":
				if i + 1 < args.size():
					server_http_port = maxi(1, int(args[i + 1]))
					i += 1
			"--name":
				if i + 1 < args.size() and not args[i + 1].strip_edges().is_empty():
					player_name = args[i + 1].strip_edges()
					i += 1
			"--mode":
				if i + 1 < args.size():
					match_mode = args[i + 1]
					var cleaned: String = match_mode.trim_prefix("offline_").trim_prefix("online_").to_lower()
					if cleaned in ["1v1", "2v2", "3v3"]:
						selected_mode = cleaned
					i += 1
			"--archetype":
				if i + 1 < args.size():
					selected_archetype = args[i + 1]
					i += 1
			"--quickplay":
				auto_quickplay = true
			"--offline-edition":
				offline_local_mode = true
		i += 1


func reset_match_state(duration_sec: float = 180.0, shot_clock_sec: float = 24.0) -> void:
	scores = [0, 0]
	match_duration_seconds = duration_sec
	match_seconds_left = duration_sec
	shot_clock_seconds = shot_clock_sec
	shot_clock_left = shot_clock_sec
	possession_team = 0
	ball_carrier_id = -1
	current_tick = 0
	match_phase = MatchPhase.LIVE


func set_team_score(team_id: int, new_score: int, delta: int = 0, is_three: bool = false, scorer_id: int = -1) -> void:
	if team_id < 0 or team_id >= scores.size():
		return
	scores[team_id] = maxi(0, new_score)
	EventBus.score_changed.emit(team_id, scores[team_id], delta, is_three, scorer_id)


func add_team_score(team_id: int, delta: int, is_three: bool = false, scorer_id: int = -1) -> void:
	if team_id < 0 or team_id >= scores.size():
		return
	scores[team_id] = maxi(0, scores[team_id] + delta)
	EventBus.score_changed.emit(team_id, scores[team_id], delta, is_three, scorer_id)


func update_timers(new_match_seconds: float, new_shot_clock: float) -> void:
	match_seconds_left = maxf(0.0, new_match_seconds)
	shot_clock_left = maxf(0.0, new_shot_clock)
	EventBus.timer_updated.emit(match_seconds_left, shot_clock_left)


func set_possession(team_id: int, carrier_id: int) -> void:
	possession_team = team_id
	ball_carrier_id = carrier_id
	EventBus.possession_changed.emit(team_id, carrier_id)


func get_http_base_url() -> String:
	return "http://%s:%d" % [server_host, server_http_port]
