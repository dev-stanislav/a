extends Node
## Phase 9 Automated Verification Suite — Online Game Modes (PHANTOM COURT ONLINE)
## Verifies end-to-end against compiled Rust dedicated server (ephemeral ports + guaranteed OS.kill):
## 1. GET /health rooms_count & supported_modes + EventBus.lobby_state_updated signal.
## 2. Online 1v1 Matchmaking queue (enqueue, status, cancel, 2-player auto-match) +
##    strict Ready Check gate + live UDP room join & isolated snapshots.
## 3. Private Room (6-char room code, hidden from public list_rooms, 404 on bad code,
##    join by code, team/archetype/fill_bots config) + 2v2 server bot fill (4 players) +
##    PostMatch & Rematch Voting resetting scores/clock in the same room (match_number 1 -> 2).
## 4. Public Online 3v3 with fill_bots=true spawning 6 authoritative players + multi-room
##    isolation vs 1v1 room + Live Read-Only Spectator Mode (HTTP ticket + UDP SpectatorJoin
##    streaming 30 Hz snapshots with 0 added bodies and ignoring forged spectator inputs).


func run(runner: SceneTree) -> void:
	await _test_phase9_online_modes_e2e(runner)


func _pick_free_tcp_port(start_port: int) -> int:
	for p in range(start_port, start_port + 200):
		var srv := TCPServer.new()
		if srv.listen(p, "127.0.0.1") == OK:
			srv.stop()
			return p
	return start_port


func _pick_free_udp_port(start_port: int) -> int:
	for p in range(start_port, start_port + 200):
		var udp := PacketPeerUDP.new()
		if udp.bind(p, "127.0.0.1") == OK:
			udp.close()
			return p
	return start_port


func _test_phase9_online_modes_e2e(runner: SceneTree) -> void:
	await runner.clear_stage()

	var server_exe: String = ProjectSettings.globalize_path("res://../server/target/debug/phantom-court-server.exe")
	if not runner.assert_true(FileAccess.file_exists(server_exe), "Compiled Rust server exists for Phase 9 E2E"):
		return

	var offset: int = int(Time.get_ticks_msec() % 400)
	var http_port: int = _pick_free_tcp_port(29100 + offset)
	var udp_port: int = _pick_free_udp_port(28700 + offset)

	var args := PackedStringArray([
		"--bind", "127.0.0.1",
		"--udp-port", str(udp_port),
		"--http-port", str(http_port),
		"--tick-rate", "60",
		"--ephemeral-db",
	])
	var server_pid: int = OS.create_process(server_exe, args, false)
	if not runner.assert_gt(float(server_pid), 0.0, "Spawned Phase 9 Rust server (pid=%d, udp=%d, http=%d)" % [server_pid, udp_port, http_port]):
		return

	var clients: Array[NetClientNode] = []
	for i in range(4):
		var c := NetClientNode.new()
		c.name = "P9Client%d" % (i + 1)
		runner.get_stage().add_child(c)
		# Set ephemeral endpoints AFTER add_child() so _ready() does not reset them to ConfigManager/GameState defaults
		c.host = "127.0.0.1"
		c.http_port = http_port
		c.udp_port = udp_port
		clients.append(c)

	await _run_online_modes_checks(runner, clients, udp_port, http_port)

	# Guaranteed teardown: disconnect all clients, clear stage, kill server!
	for c in clients:
		c.disconnect_from_server("phase9_test_complete")
	await runner.clear_stage()

	if server_pid > 0:
		OS.kill(server_pid)
		OS.delay_msec(120)
		runner.assert_false(OS.is_process_running(server_pid), "Phase 9 Rust server (pid=%d) terminated cleanly on teardown" % server_pid)


func _run_online_modes_checks(
	runner: SceneTree,
	clients: Array[NetClientNode],
	udp_port: int,
	_http_port: int
) -> void:
	var c1: NetClientNode = clients[0]
	var c2: NetClientNode = clients[1]
	var c3: NetClientNode = clients[2]
	var c_spec: NetClientNode = clients[3]

	var eb: Node = runner.get_event_bus()
	var lobby_event_count := [0]
	runner.connect_temp_signal(eb.lobby_state_updated, func(_lobby: Dictionary) -> void:
		lobby_event_count[0] += 1
	)

	# ==========================================================================
	# 1. Health Endpoint & Supported Online Modes
	# ==========================================================================
	var h_res: Dictionary = {}
	for _i in range(30):
		h_res = c1.http_request_sync(HTTPClient.METHOD_GET, "/health", {}, 0.4)
		if bool(h_res.get("ok", false)) and int(h_res.get("status_code", 0)) == 200:
			break
		OS.delay_msec(50)
	# Also verify high-level fetch_health() wrapper once server is ready
	if bool(h_res.get("ok", false)):
		h_res = c1.fetch_health()

	if not runner.assert_true(bool(h_res.get("ok", false)), "Phase 9 GET /health returns 200 OK"):
		return
	var hdata: Dictionary = h_res.get("data", {})
	runner.assert_eq(String(hdata.get("status", "")), "ok", "/health status == 'ok'")
	runner.assert_ge(int(hdata.get("rooms_count", 0)), 1, "/health reports >= 1 default arena room")
	var modes: Array = hdata.get("supported_modes", [])
	for req_mode in ["1v1", "2v2", "3v3", "private", "spectator"]:
		runner.assert_true(modes.has(req_mode), "/health supported_modes includes '%s'" % req_mode)

	# ==========================================================================
	# 2. Online 1v1 Matchmaking Queue, Cancel, Ready Check Gate & UDP Sync
	# ==========================================================================
	# 2A. Enqueue & cancel probe ticket
	var q_cancel: Dictionary = c1.enqueue_matchmaking("1v1", "TempProbe", "speedster", false, 1200)
	runner.assert_true(bool(q_cancel.get("ok", false)), "Matchmaking enqueue succeeds for probe player")
	var probe_tid: String = String((q_cancel.get("data", {}) as Dictionary).get("ticket_id", ""))
	runner.assert_eq(String((q_cancel.get("data", {}) as Dictionary).get("status", "")), "queued", "Single 1v1 enqueue enters 'queued' state")

	var st_probe: Dictionary = c1.get_matchmaking_status(probe_tid)
	runner.assert_true(bool(st_probe.get("ok", false)) and String((st_probe.get("data", {}) as Dictionary).get("status", "")) == "queued", "GET /api/matchmaking/status confirms 'queued'")

	var cancel_res: Dictionary = c1.cancel_matchmaking(probe_tid)
	runner.assert_true(bool(cancel_res.get("ok", false)) and bool((cancel_res.get("data", {}) as Dictionary).get("cancelled", false)), "POST /api/matchmaking/cancel cleanly cancels ticket")

	# 2B. Match 2 players into Online 1v1 Lobby
	var q_a: Dictionary = c1.enqueue_matchmaking("1v1", "Alpha1v1", "speedster", false, 1050)
	var qa_data: Dictionary = q_a.get("data", {})
	var tid_a: String = String(qa_data.get("ticket_id", ""))
	runner.assert_eq(String(qa_data.get("status", "")), "queued", "1v1 Player A waits in queue")

	var q_b: Dictionary = c2.enqueue_matchmaking("1v1", "Beta1v1", "powerhouse", false, 1060)
	var qb_data: Dictionary = q_b.get("data", {})
	runner.assert_eq(String(qb_data.get("status", "")), "matched", "1v1 Player B immediately pops match")

	var st_a: Dictionary = c1.get_matchmaking_status(tid_a)
	var sta_data: Dictionary = st_a.get("data", {})
	var room_1v1_id: int = int(qb_data.get("room_id", 0))
	var mid_a: String = String(sta_data.get("member_id", ""))
	var mid_b: String = String(qb_data.get("member_id", ""))
	runner.assert_gt(float(room_1v1_id), 0.0, "Matchmaker created dedicated room_id >= 1 (got %d)" % room_1v1_id)
	runner.assert_eq(int(sta_data.get("room_id", -1)), room_1v1_id, "Player A status reflects exact matched room_id")
	runner.assert_eq(String(sta_data.get("status", "")), "matched", "Player A status transitioned to 'matched'")
	runner.assert_eq(String((qb_data.get("lobby_state", {}) as Dictionary).get("state", "")), "Lobby", "Matched 1v1 room begins in 'Lobby' state")
	runner.assert_gt(float(lobby_event_count[0]), 0.0, "EventBus.lobby_state_updated emitted on lobby sync")

	# 2C. Strict Ready Check Gate: must NOT start until BOTH human members ready up
	var rdy_a: Dictionary = c1.set_ready(room_1v1_id, mid_a, true)
	var rdya_data: Dictionary = rdy_a.get("data", {})
	runner.assert_false(bool(rdya_data.get("started", true)), "1v1 room refuses to start with only 1 of 2 players ready")
	runner.assert_eq(String(rdya_data.get("state", "")), "Lobby", "1v1 room remains in 'Lobby' until opponent readies")

	var rdy_b: Dictionary = c2.set_ready(room_1v1_id, mid_b, true)
	var rdyb_data: Dictionary = rdy_b.get("data", {})
	runner.assert_true(bool(rdyb_data.get("started", false)), "1v1 room starts immediately when both players are ready")
	runner.assert_eq(String(rdyb_data.get("state", "")), "InMatch", "1v1 room transitions cleanly Lobby -> InMatch")

	# 2D. Connect both clients via UDP to their matched 1v1 room
	var c1_snaps := [0]
	var c2_snaps := [0]
	c1.snapshot_received.connect(func(_s: Dictionary) -> void: c1_snaps[0] += 1)
	c2.snapshot_received.connect(func(_s: Dictionary) -> void: c2_snaps[0] += 1)

	runner.assert_eq(c1.connect_to_room_udp("127.0.0.1", udp_port, room_1v1_id, "Alpha1v1", "speedster", 0), OK, "1v1 Client A opens UDP to room")
	runner.assert_eq(c2.connect_to_room_udp("127.0.0.1", udp_port, room_1v1_id, "Beta1v1", "powerhouse", 1), OK, "1v1 Client B opens UDP to room")
	for _w in range(50):
		await runner.wait_physics_frames(1)
		if c1.is_connected_to_server and c2.is_connected_to_server and c1_snaps[0] >= 2 and c2_snaps[0] >= 2:
			break
	runner.assert_true(c1.is_connected_to_server and c2.is_connected_to_server, "Both 1v1 players join matched room over UDP")
	runner.assert_eq((c1.get_last_snapshot().get("players", []) as Array).size(), 2, "1v1 room snapshot contains exact 2 players")

	# ==========================================================================
	# 3. Private Room (6-Char Code, 404 Reject, Config, 2v2 fill_bots, Rematch)
	# ==========================================================================
	var priv_res: Dictionary = c1.create_room("2v2", true, false, "PrivHost", "sharpshooter")
	runner.assert_true(bool(priv_res.get("ok", false)), "POST /api/rooms creates private 2v2 room")
	var pd: Dictionary = priv_res.get("data", {})
	var priv_room_id: int = int(pd.get("room_id", 0))
	var priv_code: String = String(pd.get("room_code", ""))
	var host_mid: String = String(pd.get("member_id", ""))
	runner.assert_gt(float(priv_room_id), float(room_1v1_id), "Private room receives unique room_id")
	runner.assert_eq(priv_code.length(), 6, "Private room generates 6-char alphanumeric code ('%s')" % priv_code)

	# Private Lobby room must NOT appear in public list_rooms()
	var list_priv_check: Dictionary = c2.list_rooms()
	var found_private_in_public := false
	for r_entry in (list_priv_check.get("data", {}) as Dictionary).get("rooms", []):
		if int((r_entry as Dictionary).get("room_id", -1)) == priv_room_id:
			found_private_in_public = true
	runner.assert_false(found_private_in_public, "Private Lobby room is hidden from GET /api/rooms public listing")

	# Invalid 6-char room code must be rejected with 404
	var bad_join: Dictionary = c2.join_room_by_code("ZZZZZZ", "LostGuest", "all_rounder")
	runner.assert_false(bool(bad_join.get("ok", true)), "Invalid room code rejected")
	runner.assert_eq(int(bad_join.get("status_code", 0)), 404, "Invalid room code returns HTTP 404")

	# Valid room code joins cleanly
	var good_join: Dictionary = c2.join_room_by_code(priv_code, "PrivGuest", "speedster")
	runner.assert_true(bool(good_join.get("ok", false)), "Guest joins private room via 6-char code")
	var guest_mid: String = String((good_join.get("data", {}) as Dictionary).get("member_id", ""))
	runner.assert_eq(int((good_join.get("data", {}) as Dictionary).get("room_id", 0)), priv_room_id, "Code join resolves exact private room_id")

	# Team switch (Team 0), archetype update ('playmaker'), and enable fill_bots=true for 2v2!
	var cfg_res: Dictionary = c2.update_lobby_member(priv_room_id, guest_mid, 0, "playmaker", true)
	runner.assert_true(bool(cfg_res.get("ok", false)), "POST /api/rooms/:id/config updates team, archetype & fill_bots")
	var cfg_lobby: Dictionary = (cfg_res.get("data", {}) as Dictionary).get("lobby_state", {})
	runner.assert_true(bool(cfg_lobby.get("fill_bots", false)), "Lobby fill_bots flag updated to true")

	# Verify guest member now on team 0 with playmaker archetype
	var guest_updated_ok := false
	for m in cfg_lobby.get("members", []):
		if String((m as Dictionary).get("member_id", "")) == guest_mid:
			guest_updated_ok = (int((m as Dictionary).get("team_id", -1)) == 0 and String((m as Dictionary).get("archetype", "")) == "playmaker")
	runner.assert_true(guest_updated_ok, "Lobby config switched guest to Team 0 + Playmaker archetype")

	# Both humans ready up -> 2v2 with fill_bots=true starts InMatch with 4 authoritative players!
	c1.set_ready(priv_room_id, host_mid, true)
	var priv_start: Dictionary = c2.set_ready(priv_room_id, guest_mid, true)
	var pstart_d: Dictionary = priv_start.get("data", {})
	var pstart_lobby: Dictionary = pstart_d.get("lobby_state", {})
	runner.assert_true(bool(pstart_d.get("started", false)), "Private 2v2 room starts when both humans ready with fill_bots=true")
	runner.assert_eq(String(pstart_d.get("state", "")), "InMatch", "Private 2v2 room state == 'InMatch'")
	runner.assert_eq(int(pstart_lobby.get("world_player_count", 0)), 4, "2v2 fill_bots spawns exact 4 authoritative players (2 human + 2 bots)")
	runner.assert_eq(int(pstart_lobby.get("match_number", 0)), 1, "Initial match_number == 1")

	# Finish match -> PostMatch -> Rematch Voting!
	var fin_res: Dictionary = c1.finish_room_match(priv_room_id, 21, 17)
	var fin_d: Dictionary = fin_res.get("data", {})
	runner.assert_true(bool(fin_res.get("ok", false)), "POST /api/rooms/:id/finish ends match cleanly")
	runner.assert_eq(String(fin_d.get("state", "")), "PostMatch", "Finished room transitions to 'PostMatch'")

	# 1 of 2 rematch votes -> stays PostMatch
	var rm1: Dictionary = c1.vote_rematch(priv_room_id, host_mid, true)
	var rm1_d: Dictionary = rm1.get("data", {})
	runner.assert_false(bool(rm1_d.get("rematch_started", true)), "Rematch does NOT start until all humans vote")
	runner.assert_eq(String(rm1_d.get("state", "")), "PostMatch", "Room stays PostMatch after partial rematch vote")

	# 2 of 2 rematch votes -> resets scores to [0, 0] & starts match_number == 2 in SAME room!
	var rm2: Dictionary = c2.vote_rematch(priv_room_id, guest_mid, true)
	var rm2_d: Dictionary = rm2.get("data", {})
	var rm2_lobby: Dictionary = rm2_d.get("lobby_state", {})
	var rm2_scores: Array = rm2_lobby.get("scores", [-1, -1])
	runner.assert_true(bool(rm2_d.get("rematch_started", false)), "Unanimous rematch vote restarts match in same room")
	runner.assert_eq(String(rm2_d.get("state", "")), "InMatch", "Rematch transitions cleanly back to 'InMatch'")
	runner.assert_eq(int(rm2_d.get("match_number", 0)), 2, "Rematch increments match_number to 2")
	runner.assert_true(rm2_scores.size() == 2 and int(rm2_scores[0]) == 0 and int(rm2_scores[1]) == 0, "Rematch resets authoritative scores to [0, 0]")
	runner.assert_eq(int(rm2_lobby.get("world_player_count", 0)), 4, "Rematch preserves exact 2v2 4-player roster")

	# ==========================================================================
	# 4. Online 3v3 (fill_bots=true -> 6 Players), Room Isolation & Spectator Mode
	# ==========================================================================
	var r3_res: Dictionary = c3.create_room("3v3", false, true, "Captain3v3", "all_rounder")
	runner.assert_true(bool(r3_res.get("ok", false)), "POST /api/rooms creates public 3v3 fill_bots room")
	var r3_d: Dictionary = r3_res.get("data", {})
	var room_3v3_id: int = int(r3_d.get("room_id", 0))
	var cap_mid: String = String(r3_d.get("member_id", ""))

	# Public 3v3 room MUST appear in list_rooms()
	var pub_list: Dictionary = c_spec.list_rooms()
	var found_3v3 := false
	for r_entry in (pub_list.get("data", {}) as Dictionary).get("rooms", []):
		if int((r_entry as Dictionary).get("room_id", -1)) == room_3v3_id:
			found_3v3 = true
	runner.assert_true(found_3v3, "Public 3v3 room appears in GET /api/rooms listing")

	# Host readies up -> 3v3 fill_bots spawns 6 total authoritative players!
	var r3_start: Dictionary = c3.set_ready(room_3v3_id, cap_mid, true)
	var r3s_d: Dictionary = r3_start.get("data", {})
	var r3s_lobby: Dictionary = r3s_d.get("lobby_state", {})
	runner.assert_true(bool(r3s_d.get("started", false)), "Public 3v3 fill_bots room starts cleanly")
	runner.assert_eq(int(r3s_lobby.get("world_player_count", 0)), 6, "3v3 fill_bots spawns exact 6 authoritative players (1 human + 5 server bots)")

	# Connect 3v3 human over UDP & verify multi-room isolation against still-active 1v1 room!
	var c3_snaps := [0]
	c3.snapshot_received.connect(func(_s: Dictionary) -> void: c3_snaps[0] += 1)
	runner.assert_eq(c3.connect_to_room_udp("127.0.0.1", udp_port, room_3v3_id, "Captain3v3", "all_rounder", 0), OK, "3v3 captain opens UDP to 3v3 room")
	for _w in range(50):
		await runner.wait_physics_frames(1)
		if c3.is_connected_to_server and c3_snaps[0] >= 2:
			break
	runner.assert_true(c3.is_connected_to_server, "3v3 captain connected over UDP")
	runner.assert_eq((c3.get_last_snapshot().get("players", []) as Array).size(), 6, "3v3 UDP snapshot streams all 6 players")
	runner.assert_eq((c1.get_last_snapshot().get("players", []) as Array).size(), 2, "Multi-room isolation: 1v1 room snapshot STILL has exact 2 players")

	# Live Read-Only Spectator Mode on the active 3v3 room!
	var spec_http: Dictionary = c_spec.request_spectate(room_3v3_id, "PhantomCam")
	var spec_d: Dictionary = spec_http.get("data", {})
	runner.assert_true(bool(spec_http.get("ok", false)), "POST /api/rooms/:id/spectate issues spectator ticket")
	runner.assert_eq(int(spec_d.get("room_id", 0)), room_3v3_id, "Spectator ticket targets exact 3v3 room_id")
	runner.assert_true(spec_d.has("snapshot_preview") and spec_d["snapshot_preview"] is Dictionary, "Spectator ticket includes live snapshot_preview")

	var spec_snaps := [0]
	c_spec.snapshot_received.connect(func(_s: Dictionary) -> void: spec_snaps[0] += 1)
	runner.assert_eq(c_spec.connect_as_spectator_udp("127.0.0.1", udp_port, room_3v3_id, "PhantomCam"), OK, "Spectator opens UDP & sends SpectatorJoin")
	for _w in range(50):
		await runner.wait_physics_frames(1)
		if c_spec.is_connected_to_server and spec_snaps[0] >= 3:
			break

	runner.assert_true(c_spec.is_connected_to_server, "Spectator completes WelcomeJoined handshake")
	runner.assert_eq(c_spec.local_player_id, 0, "Spectator assigned player_id == 0 (no body spawned)")
	runner.assert_eq(c_spec.local_team_id, 255, "Spectator assigned team_id == 255 (read-only)")
	runner.assert_ge(spec_snaps[0], 3, "Spectator streams live 30 Hz ServerWorldSnapshots (received=%d)" % spec_snaps[0])
	runner.assert_eq((c_spec.get_last_snapshot().get("players", []) as Array).size(), 6, "Spectator adds ZERO player bodies (snapshot stays exact 6 players)")

	# Forged ClientInputBatch sent directly from spectator socket MUST be ignored!
	var forged_spec_input: PackedByteArray = ProtocolSerializer.encode_client_input_batch(
		c_spec.session_token,
		[{
			"seq": 1,
			"tick": c_spec.server_tick + 1,
			"move_world_xz": Vector2(1.0, 0.0),
			"local_dir": Vector2(1.0, 0.0),
			"buttons": 1 | 4 | 256,
			"aim_yaw": 0.0,
		}],
		99
	)
	c_spec.call("_send_raw", forged_spec_input)
	await runner.wait_physics_frames(12)

	var post_spec_room: Dictionary = c3.get_room_state(room_3v3_id)
	var psr_d: Dictionary = post_spec_room.get("data", {})
	runner.assert_eq(int(psr_d.get("world_player_count", 0)), 6, "Forged spectator input spawns 0 bodies (world_player_count stays 6)")
	runner.assert_ge(int(psr_d.get("spectator_count", 0)), 1, "Room state tracks >= 1 active spectator")
