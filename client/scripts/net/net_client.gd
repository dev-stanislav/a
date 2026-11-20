class_name NetClientNode
extends Node
## Authoritative UDP Multiplayer Client + HTTP REST Helper for PHANTOM COURT ONLINE.
## Registered as the `NetClient` Autoload (`res://scripts/net/net_client.gd`), and also
## instantiable in headless E2E tests via `NetClientNode.new()`.

signal welcome_received(session_info: Dictionary)
signal snapshot_received(snapshot: Dictionary)
signal reliable_event_received(event: Dictionary)
signal pong_received(rtt_ms: float, server_tick: int)
signal health_check_completed(ok: bool, data: Dictionary)
signal lobby_state_changed(lobby_state: Dictionary)

const MAX_REDUNDANT_INPUTS: int = 4
const PING_INTERVAL_SEC: float = 0.50
const HELLO_RETRY_INTERVAL_SEC: float = 0.25
const METRICS_EMIT_INTERVAL_SEC: float = 0.50

var host: String = "127.0.0.1"
var udp_port: int = 7777
var http_port: int = 8080

var is_connected_to_server: bool = false
var is_connecting: bool = false
var is_spectator: bool = false

var local_player_id: int = 0
var local_team_id: int = 0
var assigned_slot: int = 0
var session_token: int = 0
var server_tick: int = 0
var server_tick_rate: int = 60
var server_snapshot_rate: int = 30
var room_id: String = "default"
var current_member_id: String = ""
var current_lobby_state: Dictionary = {}
var current_profile_data: Dictionary = {}
var last_leaderboard: Array = []
var username: String = "PhantomPlayer"
var archetype_id: String = "all_rounder"
var preferred_team: int = 255

var reconciler: PredictionReconciler = PredictionReconciler.new()
var interpolator: EntityInterpolator = EntityInterpolator.new()

var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _socket_open: bool = false
var _local_packet_seq: int = 0
var _remote_packet_seq: int = 0
var _remote_ack_bits: int = 0

var _recent_inputs: Array[Dictionary] = []
var _highest_event_id: int = 0
var _event_ack_mask: int = 0
var _processed_event_ids: Dictionary = {}

var _reconnecting: bool = false
var _hello_retry_timer: float = 0.0
var _ping_timer: float = 0.0
var _metrics_timer: float = 0.0

# Live telemetry metrics
var rtt_ms: float = 0.0
var packet_loss_pct: float = 0.0
var bytes_per_sec: float = 0.0
var packets_sent: int = 0
var packets_received: int = 0
var _bytes_window_rx: int = 0
var _bytes_window_tx: int = 0
var _expected_remote_packets: int = 0
var _received_remote_packets: int = 0
var _last_snapshot: Dictionary = {}


func _get_autoload(node_name: String) -> Node:
	if not is_inside_tree():
		return null
	var tree: SceneTree = get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(node_name))


func _ready() -> void:
	var cfg: Node = _get_autoload("ConfigManager")
	if cfg != null and cfg.has_method("get_setting"):
		host = str(cfg.call("get_setting", "network", "default_host", host))
		udp_port = int(cfg.call("get_setting", "network", "default_udp_port", udp_port))
		http_port = int(cfg.call("get_setting", "network", "default_http_port", http_port))
		username = str(cfg.call("get_setting", "network", "player_name", username))

	var gs: Node = _get_autoload("GameState")
	if gs != null:
		if gs.get("server_host") != null:
			host = str(gs.get("server_host"))
		if gs.get("server_udp_port") != null:
			udp_port = int(gs.get("server_udp_port"))
		if gs.get("server_http_port") != null:
			http_port = int(gs.get("server_http_port"))
		if gs.get("player_name") != null:
			username = str(gs.get("player_name"))
		if gs.get("selected_archetype") != null:
			archetype_id = str(gs.get("selected_archetype"))


func _exit_tree() -> void:
	if _socket_open:
		_udp.close()
		_socket_open = false


func _physics_process(delta: float) -> void:
	if not _socket_open:
		return

	poll_network()

	if is_connecting and not is_connected_to_server:
		_hello_retry_timer += delta
		if _hello_retry_timer >= HELLO_RETRY_INTERVAL_SEC:
			_hello_retry_timer = 0.0
			if _reconnecting and session_token != 0:
				_send_reconnect_packet()
			elif is_spectator:
				_send_spectator_join_packet()
			else:
				_send_hello_packet()

	if is_connected_to_server:
		_ping_timer += delta
		if _ping_timer >= PING_INTERVAL_SEC:
			_ping_timer = 0.0
			send_ping()

	_metrics_timer += delta
	if _metrics_timer >= METRICS_EMIT_INTERVAL_SEC:
		var elapsed: float = maxf(0.001, _metrics_timer)
		bytes_per_sec = float(_bytes_window_rx + _bytes_window_tx) / elapsed
		_bytes_window_rx = 0
		_bytes_window_tx = 0
		_metrics_timer = 0.0
		_emit_metrics()


func connect_to_server(
	target_host: String = "",
	target_udp_port: int = -1,
	player_username: String = "",
	player_archetype: String = "",
	target_room_id: String = "default",
	target_http_port: int = -1,
	team_pref: int = 255
) -> int:
	if not target_host.is_empty():
		host = target_host
	if target_udp_port > 0:
		udp_port = target_udp_port
	if target_http_port > 0:
		http_port = target_http_port
	if not player_username.is_empty():
		username = player_username
	if not player_archetype.is_empty():
		archetype_id = player_archetype
	room_id = target_room_id
	preferred_team = team_pref
	is_spectator = false
	_reconnecting = false

	_reset_transport_state(true)
	var err: int = _open_udp_socket()
	if err != OK:
		return err

	is_connecting = true
	_hello_retry_timer = 0.0
	_send_hello_packet()
	return OK


func connect_as_spectator(
	target_host: String,
	target_udp_port: int,
	target_room_id: String = "default",
	spectator_name: String = "Spectator"
) -> int:
	host = target_host
	udp_port = target_udp_port
	room_id = target_room_id
	username = spectator_name
	is_spectator = true
	_reconnecting = false

	_reset_transport_state(true)
	var err: int = _open_udp_socket()
	if err != OK:
		return err

	is_connecting = true
	_hello_retry_timer = 0.0
	_send_spectator_join_packet()
	return OK


## Closes the old UDP socket, binds a brand-new ephemeral UDP port, and sends ReconnectRequest(session_token).
func reconnect_session(new_host: String = "", new_udp_port: int = -1) -> int:
	if session_token == 0:
		return ERR_UNCONFIGURED
	if not new_host.is_empty():
		host = new_host
	if new_udp_port > 0:
		udp_port = new_udp_port

	_reset_transport_state(false)
	var err: int = _open_udp_socket()
	if err != OK:
		return err

	is_connected_to_server = false
	is_connecting = true
	_reconnecting = true
	_hello_retry_timer = 0.0
	_send_reconnect_packet()
	return OK


func disconnect_from_server(reason: String = "client_disconnect") -> void:
	var was_active: bool = is_connected_to_server or is_connecting
	if _socket_open:
		_udp.close()
		_socket_open = false
	is_connected_to_server = false
	is_connecting = false
	_reconnecting = false

	var gs: Node = _get_autoload("GameState")
	if gs != null:
		gs.set("is_online", false)

	if was_active:
		var eb: Node = _get_autoload("EventBus")
		if eb != null and eb.has_signal("net_disconnected"):
			eb.emit_signal("net_disconnected", reason)


## Records one 60 Hz PlayerInputFrame into the 4-frame redundant window and transmits ClientInputBatch.
func queue_local_input(input_frame: Dictionary) -> void:
	if not is_connected_to_server or is_spectator or session_token == 0:
		return
	_recent_inputs.append(input_frame.duplicate(true))
	while _recent_inputs.size() > MAX_REDUNDANT_INPUTS:
		_recent_inputs.pop_front()

	var pkt: PackedByteArray = ProtocolSerializer.encode_client_input_batch(
		session_token,
		_recent_inputs,
		_next_seq(),
		_remote_packet_seq,
		_remote_ack_bits
	)
	_send_raw(pkt)


func send_ping() -> void:
	if not _socket_open:
		return
	var now_ms: int = Time.get_ticks_msec()
	var pkt: PackedByteArray = ProtocolSerializer.encode_ping(
		session_token,
		now_ms,
		_next_seq(),
		_remote_packet_seq,
		_remote_ack_bits
	)
	_send_raw(pkt)


func get_last_snapshot() -> Dictionary:
	return _last_snapshot


func get_metrics() -> Dictionary:
	return {
		"rtt_ms": rtt_ms,
		"packet_loss_pct": packet_loss_pct,
		"bytes_per_sec": bytes_per_sec,
		"interp_delay_ms": interpolator.get_effective_delay_ms(),
		"reconciliations": reconciler.get_reconciliation_count(),
		"packets_sent": packets_sent,
		"packets_received": packets_received,
		"connected": is_connected_to_server,
		"player_id": local_player_id,
		"team_id": local_team_id,
		"session_token": session_token,
		"server_tick": server_tick,
	}


## Polls all queued UDP packets from the socket (called every physics tick and manually in headless tests).
func poll_network() -> int:
	if not _socket_open:
		return 0
	var count: int = 0
	while _udp.get_available_packet_count() > 0:
		var raw: PackedByteArray = _udp.get_packet()
		if raw.is_empty():
			continue
		packets_received += 1
		_bytes_window_rx += raw.size()
		count += 1

		var decoded: Dictionary = ProtocolSerializer.decode_packet(raw)
		if not bool(decoded.get("ok", false)):
			continue
		_update_remote_seq(int(decoded["seq"]))
		_handle_packet(int(decoded["msg_type"]), decoded.get("payload", {}))
	return count


# ==============================================================================
# HTTP REST Helpers (/health & Phase 9/10 Lobby/Profile APIs)
# ==============================================================================

func get_http_base_url() -> String:
	return "http://%s:%d" % [host, http_port]


func check_server_health(callback: Callable = Callable()) -> void:
	http_get_json("/health", func(ok: bool, status_code: int, data: Dictionary) -> void:
		var healthy: bool = ok and status_code == 200 and str(data.get("status", "")) == "ok"
		health_check_completed.emit(healthy, data)
		if callback.is_valid():
			callback.call(healthy, data)
	)


func fetch_health(callback: Callable = Callable()) -> Dictionary:
	return _dispatch_rest_call(HTTPClient.METHOD_GET, "/health", {}, callback, false)


func enqueue_matchmaking(
	mode: String,
	player_username: String = "",
	player_archetype: String = "",
	fill_bots: bool = false,
	rating: int = 1000,
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {
		"mode": mode,
		"username": player_username if not player_username.is_empty() else username,
		"archetype": player_archetype if not player_archetype.is_empty() else archetype_id,
		"fill_bots": fill_bots,
		"rating": rating,
	}
	return _dispatch_rest_call(HTTPClient.METHOD_POST, "/api/matchmaking/enqueue", body, callback, true)


func cancel_matchmaking(ticket_id: String, callback: Callable = Callable()) -> Dictionary:
	return _dispatch_rest_call(
		HTTPClient.METHOD_POST,
		"/api/matchmaking/cancel",
		{"ticket_id": ticket_id},
		callback,
		false
	)


func get_matchmaking_status(ticket_id: String, callback: Callable = Callable()) -> Dictionary:
	return _dispatch_rest_call(
		HTTPClient.METHOD_GET,
		"/api/matchmaking/status/" + ticket_id.uri_encode(),
		{},
		callback,
		true
	)


func create_room(
	mode: String,
	is_private: bool = true,
	fill_bots: bool = false,
	host_username: String = "",
	player_archetype: String = "",
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {
		"mode": mode,
		"is_private": is_private,
		"fill_bots": fill_bots,
		"host_username": host_username if not host_username.is_empty() else username,
		"archetype": player_archetype if not player_archetype.is_empty() else archetype_id,
	}
	return _dispatch_rest_call(HTTPClient.METHOD_POST, "/api/rooms", body, callback, true)


func join_room_by_code(
	code: String,
	player_username: String = "",
	player_archetype: String = "",
	as_spectator: bool = false,
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {
		"room_code": code.strip_edges().to_upper(),
		"username": player_username if not player_username.is_empty() else username,
		"archetype": player_archetype if not player_archetype.is_empty() else archetype_id,
		"as_spectator": as_spectator,
	}
	return _dispatch_rest_call(HTTPClient.METHOD_POST, "/api/rooms/join", body, callback, true)


func join_room_by_id(
	target_room_id: int,
	player_username: String = "",
	player_archetype: String = "",
	as_spectator: bool = false,
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {
		"room_id": target_room_id,
		"username": player_username if not player_username.is_empty() else username,
		"archetype": player_archetype if not player_archetype.is_empty() else archetype_id,
		"as_spectator": as_spectator,
	}
	return _dispatch_rest_call(HTTPClient.METHOD_POST, "/api/rooms/join", body, callback, true)


func list_rooms(callback: Callable = Callable()) -> Dictionary:
	return _dispatch_rest_call(HTTPClient.METHOD_GET, "/api/rooms", {}, callback, false)


func get_room_state(target_room_id: int, callback: Callable = Callable()) -> Dictionary:
	return _dispatch_rest_call(
		HTTPClient.METHOD_GET,
		"/api/rooms/%d" % target_room_id,
		{},
		callback,
		true
	)


func set_ready(
	target_room_id: int,
	member_id: String,
	ready: bool,
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {
		"member_id": member_id,
		"ready": ready,
	}
	return _dispatch_rest_call(
		HTTPClient.METHOD_POST,
		"/api/rooms/%d/ready" % target_room_id,
		body,
		callback,
		true
	)


func update_lobby_member(
	target_room_id: int,
	member_id: String,
	team: int = -1,
	player_archetype: String = "",
	fill_bots: Variant = null,
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {"member_id": member_id}
	if team >= 0:
		body["team"] = team
	if not player_archetype.is_empty():
		body["archetype"] = player_archetype
	if fill_bots is bool:
		body["fill_bots"] = bool(fill_bots)
	return _dispatch_rest_call(
		HTTPClient.METHOD_POST,
		"/api/rooms/%d/config" % target_room_id,
		body,
		callback,
		true
	)


func vote_rematch(
	target_room_id: int,
	member_id: String,
	vote: bool,
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {
		"member_id": member_id,
		"vote": vote,
	}
	return _dispatch_rest_call(
		HTTPClient.METHOD_POST,
		"/api/rooms/%d/rematch" % target_room_id,
		body,
		callback,
		true
	)


func finish_room_match(
	target_room_id: int,
	score_a: int = -1,
	score_b: int = -1,
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {}
	if score_a >= 0 and score_b >= 0:
		body["score_a"] = score_a
		body["score_b"] = score_b
	return _dispatch_rest_call(
		HTTPClient.METHOD_POST,
		"/api/rooms/%d/finish" % target_room_id,
		body,
		callback,
		true
	)


func request_spectate(
	target_room_id: int,
	spectator_name: String = "Spectator",
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {"username": spectator_name}
	return _dispatch_rest_call(
		HTTPClient.METHOD_POST,
		"/api/rooms/%d/spectate" % target_room_id,
		body,
		callback,
		true
	)


func connect_to_room_udp(
	target_host: String,
	target_udp_port: int,
	target_room_id: Variant,
	player_username: String = "",
	player_archetype: String = "",
	team_pref: int = 255
) -> int:
	return connect_to_server(
		target_host,
		target_udp_port,
		player_username,
		player_archetype,
		str(target_room_id),
		-1,
		team_pref
	)


func connect_as_spectator_udp(
	target_host: String,
	target_udp_port: int,
	target_room_id: Variant,
	spectator_name: String = "Spectator"
) -> int:
	return connect_as_spectator(
		target_host,
		target_udp_port,
		str(target_room_id),
		spectator_name
	)


func _dispatch_rest_call(
	method: int,
	path: String,
	body: Dictionary,
	callback: Callable,
	extract_lobby_state: bool
) -> Dictionary:
	if callback.is_valid():
		_http_request_async(method, path, body, func(ok: bool, status_code: int, data: Dictionary) -> void:
			if ok and extract_lobby_state:
				_handle_possible_lobby_update(data)
			callback.call(ok, status_code, data)
		)
		return {"pending": true}

	var res: Dictionary = http_request_sync(method, path, body, 3.0)
	if bool(res.get("ok", false)) and extract_lobby_state:
		_handle_possible_lobby_update(res.get("data", {}))
	return res


func _handle_possible_lobby_update(data: Variant) -> void:
	if not (data is Dictionary):
		return
	var d: Dictionary = data as Dictionary
	if d.has("member_id") and d["member_id"] != null:
		current_member_id = str(d["member_id"])

	var lobby_dict: Dictionary = {}
	if d.has("lobby_state") and d["lobby_state"] is Dictionary:
		lobby_dict = (d["lobby_state"] as Dictionary).duplicate(true)
	elif d.has("room_id") and d.has("members") and d.has("state"):
		lobby_dict = d.duplicate(true)

	if lobby_dict.is_empty():
		return

	current_lobby_state = lobby_dict
	if lobby_dict.has("room_id"):
		room_id = str(int(lobby_dict["room_id"]))

	var gs: Node = _get_autoload("GameState")
	if gs != null:
		gs.set("current_lobby_id", room_id)
		gs.set("lobby_state", lobby_dict)

	lobby_state_changed.emit(lobby_dict)
	var eb: Node = _get_autoload("EventBus")
	if eb != null and eb.has_signal("lobby_state_updated"):
		eb.emit_signal("lobby_state_updated", lobby_dict)


# ==============================================================================
# Phase 10 Ranking & Persistence REST Helpers (Profile, History, Leaderboard)
# ==============================================================================

func create_or_load_profile(
	player_username: String = "",
	archetype_fav: String = "",
	callback: Callable = Callable()
) -> Dictionary:
	var body: Dictionary = {
		"username": player_username if not player_username.is_empty() else username,
	}
	if not archetype_fav.is_empty():
		body["archetype_fav"] = archetype_fav
	return _dispatch_ranking_call(HTTPClient.METHOD_POST, "/api/profile", body, callback, "profile")


func fetch_profile(
	player_id_or_name: String,
	callback: Callable = Callable()
) -> Dictionary:
	var path: String = "/api/profile/" + player_id_or_name.uri_encode()
	return _dispatch_ranking_call(HTTPClient.METHOD_GET, path, {}, callback, "profile")


func fetch_match_history(
	player_id_or_name: String,
	limit: int = 20,
	callback: Callable = Callable()
) -> Dictionary:
	var clamped: int = clampi(limit, 1, 200)
	var path: String = "/api/profile/%s/history?limit=%d" % [player_id_or_name.uri_encode(), clamped]
	return _dispatch_ranking_call(HTTPClient.METHOD_GET, path, {}, callback, "")


func fetch_leaderboard(
	season_id: int = 1,
	limit: int = 50,
	callback: Callable = Callable()
) -> Dictionary:
	var s_id: int = maxi(1, season_id)
	var clamped: int = clampi(limit, 1, 200)
	var path: String = "/api/leaderboard?season=%d&limit=%d" % [s_id, clamped]
	return _dispatch_ranking_call(HTTPClient.METHOD_GET, path, {}, callback, "leaderboard")


func record_ranked_match(
	payload: Dictionary,
	callback: Callable = Callable()
) -> Dictionary:
	return _dispatch_ranking_call(HTTPClient.METHOD_POST, "/api/matches/record", payload, callback, "")


func _dispatch_ranking_call(
	method: int,
	path: String,
	body: Dictionary,
	callback: Callable,
	emit_kind: String
) -> Dictionary:
	if callback.is_valid():
		_http_request_async(method, path, body, func(ok: bool, status_code: int, data: Dictionary) -> void:
			if ok:
				_handle_ranking_response(emit_kind, data)
			callback.call(ok, status_code, data)
		)
		return {"pending": true}

	var res: Dictionary = http_request_sync(method, path, body, 3.0)
	if bool(res.get("ok", false)):
		_handle_ranking_response(emit_kind, res.get("data", {}))
	return res


func _handle_ranking_response(emit_kind: String, data: Variant) -> void:
	if not (data is Dictionary):
		return
	var d: Dictionary = data as Dictionary
	var eb: Node = _get_autoload("EventBus")

	if emit_kind == "profile" and d.has("username"):
		current_profile_data = d.duplicate(true)
		var gs: Node = _get_autoload("GameState")
		if gs != null:
			gs.set("profile_data", current_profile_data)
			if d.has("id"):
				gs.set("account_id", str(d["id"]))
		if eb != null and eb.has_signal("profile_loaded"):
			eb.emit_signal("profile_loaded", current_profile_data)
	elif emit_kind == "leaderboard" and d.has("entries") and d["entries"] is Array:
		last_leaderboard = (d["entries"] as Array).duplicate(true)
		if eb != null and eb.has_signal("leaderboard_loaded"):
			eb.emit_signal("leaderboard_loaded", last_leaderboard)


func http_get_json(path: String, callback: Callable = Callable()) -> void:
	_http_request_async(HTTPClient.METHOD_GET, path, {}, callback)


func http_post_json(path: String, body: Dictionary, callback: Callable = Callable()) -> void:
	_http_request_async(HTTPClient.METHOD_POST, path, body, callback)


func _http_request_async(
	method: int,
	path: String,
	body: Dictionary,
	callback: Callable
) -> void:
	if not is_inside_tree():
		var sync_res: Dictionary = http_request_sync(method, path, body, 3.0)
		if callback.is_valid():
			callback.call(bool(sync_res["ok"]), int(sync_res["status_code"]), sync_res["data"])
		return

	var req := HTTPRequest.new()
	req.timeout = 5.0
	add_child(req)
	req.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, resp_body: PackedByteArray) -> void:
		var parsed: Dictionary = {}
		var text: String = resp_body.get_string_from_utf8()
		if not text.is_empty():
			var json_val: Variant = JSON.parse_string(text)
			if json_val is Dictionary:
				parsed = json_val
		var ok: bool = (result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300)
		if callback.is_valid():
			callback.call(ok, response_code, parsed)
		req.queue_free()
	)

	var url: String = get_http_base_url() + path
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var payload_str: String = JSON.stringify(body) if method != HTTPClient.METHOD_GET else ""
	var err: int = req.request(url, headers, method, payload_str)
	if err != OK:
		req.queue_free()
		if callback.is_valid():
			callback.call(false, 0, {"error": "request_failed", "code": err})


## Blocking/pollable HTTP JSON request helper (handy for headless verification scripts).
func http_request_sync(
	method: int,
	path: String,
	body: Dictionary = {},
	timeout_sec: float = 3.0
) -> Dictionary:
	var client := HTTPClient.new()
	var err: int = client.connect_to_host(host, http_port)
	if err != OK:
		return {"ok": false, "status_code": 0, "data": {"error": "connect_failed"}}

	var deadline_ms: int = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		if Time.get_ticks_msec() > deadline_ms:
			return {"ok": false, "status_code": 0, "data": {"error": "connect_timeout"}}
		OS.delay_msec(5)

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"ok": false, "status_code": 0, "data": {"error": "not_connected"}}

	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	var payload_str: String = JSON.stringify(body) if method != HTTPClient.METHOD_GET else ""
	err = client.request(method, path, headers, payload_str)
	if err != OK:
		return {"ok": false, "status_code": 0, "data": {"error": "send_failed"}}

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if Time.get_ticks_msec() > deadline_ms:
			return {"ok": false, "status_code": 0, "data": {"error": "request_timeout"}}
		OS.delay_msec(5)

	var code: int = client.get_response_code()
	var chunks := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk: PackedByteArray = client.read_response_body_chunk()
		if chunk.size() > 0:
			chunks.append_array(chunk)
		else:
			OS.delay_msec(2)
		if Time.get_ticks_msec() > deadline_ms:
			break

	client.close()
	var parsed: Dictionary = {}
	var text: String = chunks.get_string_from_utf8()
	if not text.is_empty():
		var val: Variant = JSON.parse_string(text)
		if val is Dictionary:
			parsed = val
	return {
		"ok": code >= 200 and code < 300,
		"status_code": code,
		"data": parsed,
	}


# ==============================================================================
# Internal Transport & Packet Handlers
# ==============================================================================

func _open_udp_socket() -> int:
	if _socket_open:
		_udp.close()
		_socket_open = false
	_udp = PacketPeerUDP.new()
	var bind_err: int = _udp.bind(0, "0.0.0.0")
	if bind_err != OK:
		return bind_err
	var dest_err: int = _udp.set_dest_address(host, udp_port)
	if dest_err != OK:
		_udp.close()
		return dest_err
	_socket_open = true
	return OK


func _reset_transport_state(clear_session: bool) -> void:
	_local_packet_seq = 0
	_remote_packet_seq = 0
	_remote_ack_bits = 0
	_expected_remote_packets = 0
	_received_remote_packets = 0
	_recent_inputs.clear()
	if clear_session:
		is_connected_to_server = false
		local_player_id = 0
		local_team_id = 0
		assigned_slot = 0
		session_token = 0
		server_tick = 0
		_highest_event_id = 0
		_event_ack_mask = 0
		_processed_event_ids.clear()
		reconciler.clear()
		interpolator.clear()


func _next_seq() -> int:
	_local_packet_seq += 1
	return _local_packet_seq


func _send_raw(bytes: PackedByteArray) -> void:
	if not _socket_open or bytes.is_empty():
		return
	var err: int = _udp.put_packet(bytes)
	if err == OK:
		packets_sent += 1
		_bytes_window_tx += bytes.size()


func _send_hello_packet() -> void:
	var pkt: PackedByteArray = ProtocolSerializer.encode_hello_join(
		username,
		archetype_id,
		room_id,
		"",
		preferred_team,
		_next_seq(),
		_remote_packet_seq,
		_remote_ack_bits
	)
	_send_raw(pkt)


func _send_spectator_join_packet() -> void:
	var pkt: PackedByteArray = ProtocolSerializer.encode_spectator_join(
		room_id,
		username,
		_next_seq(),
		_remote_packet_seq,
		_remote_ack_bits
	)
	_send_raw(pkt)


func _send_reconnect_packet() -> void:
	var pkt: PackedByteArray = ProtocolSerializer.encode_reconnect_request(
		session_token,
		_highest_event_id,
		_next_seq(),
		_remote_packet_seq,
		_remote_ack_bits
	)
	_send_raw(pkt)


func _update_remote_seq(pkt_seq: int) -> void:
	if pkt_seq <= 0:
		return
	_received_remote_packets += 1
	if _remote_packet_seq == 0:
		_remote_packet_seq = pkt_seq
		_remote_ack_bits = 0
		_expected_remote_packets = 1
	elif pkt_seq > _remote_packet_seq:
		var shift: int = pkt_seq - _remote_packet_seq
		_expected_remote_packets += shift
		if shift < 32:
			_remote_ack_bits = ((_remote_ack_bits << shift) | (1 << (shift - 1))) & 0xFFFFFFFF
		else:
			_remote_ack_bits = 0
		_remote_packet_seq = pkt_seq
	elif pkt_seq < _remote_packet_seq:
		var diff: int = _remote_packet_seq - pkt_seq
		if diff <= 32:
			_remote_ack_bits |= (1 << (diff - 1))

	if _expected_remote_packets > 0:
		var lost: int = maxi(0, _expected_remote_packets - _received_remote_packets)
		packet_loss_pct = clampf((float(lost) / float(_expected_remote_packets)) * 100.0, 0.0, 100.0)


func _handle_packet(msg_type: int, payload: Dictionary) -> void:
	match msg_type:
		ProtocolSerializer.MSG_WELCOME_JOINED:
			local_player_id = int(payload.get("player_id", 0))
			local_team_id = int(payload.get("team_id", 0))
			assigned_slot = int(payload.get("assigned_slot", 0))
			session_token = int(payload.get("session_token", 0))
			server_tick = int(payload.get("server_tick", 0))
			server_tick_rate = int(payload.get("tick_rate", 60))
			server_snapshot_rate = int(payload.get("snapshot_rate", 30))
			is_connected_to_server = true
			is_connecting = false
			_reconnecting = false

			var gs: Node = _get_autoload("GameState")
			if gs != null:
				gs.set("is_online", true)
				if not is_spectator:
					gs.set("local_player_id", local_player_id)
					gs.set("local_team_id", local_team_id)

			welcome_received.emit(payload)
			var eb: Node = _get_autoload("EventBus")
			if eb != null and eb.has_signal("net_connected"):
				eb.emit_signal("net_connected", payload)

		ProtocolSerializer.MSG_SERVER_WORLD_SNAPSHOT:
			var tick: int = int(payload.get("server_tick", 0))
			if tick >= server_tick:
				server_tick = tick
				_last_snapshot = payload
			interpolator.push_world_snapshot(payload)
			snapshot_received.emit(payload)

		ProtocolSerializer.MSG_RELIABLE_MATCH_EVENT:
			var eid: int = int(payload.get("event_id", 0))
			if eid <= 0:
				return
			# Update ack tracking & always send EventAck (even for duplicates so server stops retrying!)
			if eid > _highest_event_id:
				var shift: int = eid - _highest_event_id
				if shift < 32 and _highest_event_id > 0:
					_event_ack_mask = ((_event_ack_mask << shift) | (1 << (shift - 1))) & 0xFFFFFFFF
				elif shift >= 32:
					_event_ack_mask = 0
				_highest_event_id = eid
			elif eid < _highest_event_id:
				var diff: int = _highest_event_id - eid
				if diff <= 32:
					_event_ack_mask |= (1 << (diff - 1))

			var ack_pkt: PackedByteArray = ProtocolSerializer.encode_event_ack(
				session_token,
				_highest_event_id,
				_event_ack_mask,
				_next_seq(),
				_remote_packet_seq,
				_remote_ack_bits
			)
			_send_raw(ack_pkt)

			# Deduplicate event dispatch
			if _processed_event_ids.has(eid):
				return
			_processed_event_ids[eid] = true
			reliable_event_received.emit(payload)
			_dispatch_event_to_bus(payload)

		ProtocolSerializer.MSG_PONG:
			var sent_ms: int = int(payload.get("client_time_ms", 0))
			var srv_tick: int = int(payload.get("server_tick", server_tick))
			var sample_rtt: float = maxf(0.0, float(Time.get_ticks_msec() - sent_ms))
			rtt_ms = sample_rtt if rtt_ms <= 0.01 else lerpf(rtt_ms, sample_rtt, 0.25)
			pong_received.emit(rtt_ms, srv_tick)


func _dispatch_event_to_bus(ev: Dictionary) -> void:
	var eb: Node = _get_autoload("EventBus")
	if eb == null:
		return
	var kind: int = int(ev.get("kind", 0))
	match kind:
		ProtocolSerializer.EVENT_SCORE:
			if eb.has_signal("score_changed"):
				eb.emit_signal(
					"score_changed",
					int(ev.get("team_id", 0)),
					int(ev.get("new_score", 0)),
					int(ev.get("delta", 2)),
					bool(ev.get("is_three", false)),
					int(ev.get("scorer_id", 0))
				)
		ProtocolSerializer.EVENT_POSSESSION:
			if eb.has_signal("possession_changed"):
				eb.emit_signal("possession_changed", int(ev.get("team_id", 0)), int(ev.get("carrier_id", 0)))
		ProtocolSerializer.EVENT_COMBO:
			if eb.has_signal("combo_triggered"):
				eb.emit_signal(
					"combo_triggered",
					int(ev.get("player_id", 0)),
					str(ev.get("combo_id", "")),
					int(ev.get("combo_tier", 1)),
					bool(ev.get("is_perfect", false))
				)
		ProtocolSerializer.EVENT_STEAL:
			if eb.has_signal("steal_performed"):
				eb.emit_signal(
					"steal_performed",
					int(ev.get("stealer_id", 0)),
					int(ev.get("victim_id", 0)),
					ev.get("world_pos", Vector3.ZERO)
				)
		ProtocolSerializer.EVENT_BLOCK:
			if eb.has_signal("block_performed"):
				eb.emit_signal(
					"block_performed",
					int(ev.get("blocker_id", 0)),
					int(ev.get("shooter_id", 0)),
					ev.get("world_pos", Vector3.ZERO)
				)
		ProtocolSerializer.EVENT_ANKLE_BREAK:
			if eb.has_signal("ankle_broken"):
				eb.emit_signal(
					"ankle_broken",
					int(ev.get("victim_id", 0)),
					int(ev.get("attacker_id", 0)),
					ev.get("world_pos", Vector3.ZERO)
				)
		ProtocolSerializer.EVENT_ZONE:
			if bool(ev.get("activated", false)):
				if eb.has_signal("zone_activated"):
					eb.emit_signal("zone_activated", int(ev.get("player_id", 0)), float(ev.get("duration_ms", 12000)) / 1000.0)
			else:
				if eb.has_signal("zone_ended"):
					eb.emit_signal("zone_ended", int(ev.get("player_id", 0)))
		ProtocolSerializer.EVENT_MATCH_END:
			if eb.has_signal("match_ended"):
				eb.emit_signal(
					"match_ended",
					int(ev.get("winner_team", 255)),
					[int(ev.get("score_a", 0)), int(ev.get("score_b", 0))],
					{}
				)


func _emit_metrics() -> void:
	var eb: Node = _get_autoload("EventBus")
	if eb != null and eb.has_signal("net_metrics_updated"):
		eb.emit_signal("net_metrics_updated", get_metrics())
