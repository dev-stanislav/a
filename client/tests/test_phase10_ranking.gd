extends Node
## Phase 10 Automated Verification Suite — Ranking System & PostgreSQL 16 Persistence
## (PHANTOM COURT ONLINE)
## Verifies end-to-end against compiled Rust server + REAL local PostgreSQL 16.4:
## 1. Real PostgreSQL 16 connection (GET /health reports db_backend == "postgres", ephemeral_db == false).
## 2. Profile creation / idempotent reload / UUID & case-insensitive username lookup / 404 unknown +
##    EventBus.profile_loaded & GameState.account_id / profile_data sync.
## 3. Glicko-2 rating updates & Ranked Divisions (Bronze/Silver/Gold/Platinum/Diamond/Phantom):
##    - Starting R=1500, RD=350, sigma=0.06, Gold division
##    - Winner rises, loser drops, RD shrinks with games played
##    - Beating higher-rated opponent yields strictly larger rating delta than beating equal opponent
##    - Seasonal stats accumulation, chronological match history, and sorted global leaderboard
##      (+ EventBus.leaderboard_loaded).
## 4. Automatic ranked match recording on online room match finish (POST /api/rooms/:id/finish).
## 5. TRUE disk durability across full server process shutdown & restart (kill Server #1 -> spawn
##    fresh Server #2 -> exact profiles, Glicko-2 ratings, seasonal stats, history & leaderboard persist!).


func run(runner: SceneTree) -> void:
	await _test_phase10_ranking_and_postgres_persistence(runner)


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


func _is_tcp_port_open(target_host: String, port: int, timeout_ms: int = 350) -> bool:
	var tcp := StreamPeerTCP.new()
	if tcp.connect_to_host(target_host, port) != OK:
		return false
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		tcp.poll()
		var st: int = tcp.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			tcp.disconnect_from_host()
			return true
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			return false
		OS.delay_msec(10)
	tcp.disconnect_from_host()
	return false


func _spawn_pg_server(server_exe: String, udp_port: int, http_port: int) -> int:
	# Omit --ephemeral-db so server connects to real PostgreSQL 16 (postgres://postgres@127.0.0.1:15432/phantom_court)
	var args := PackedStringArray([
		"--bind", "127.0.0.1",
		"--udp-port", str(udp_port),
		"--http-port", str(http_port),
		"--tick-rate", "60",
	])
	return OS.create_process(server_exe, args, false)


func _wait_for_server_health(client: NetClientNode) -> Dictionary:
	var res: Dictionary = {}
	for _attempt in range(50):
		res = client.http_request_sync(HTTPClient.METHOD_GET, "/health", {}, 0.4)
		if bool(res.get("ok", false)) and int(res.get("status_code", 0)) == 200:
			return res
		OS.delay_msec(60)
	return res


func _expected_division_for_rating(r: float) -> String:
	if r < 1300.0:
		return "Bronze"
	if r < 1500.0:
		return "Silver"
	if r < 1700.0:
		return "Gold"
	if r < 1900.0:
		return "Platinum"
	if r < 2100.0:
		return "Diamond"
	return "Phantom"


func _test_phase10_ranking_and_postgres_persistence(runner: SceneTree) -> void:
	await runner.clear_stage()

	var server_exe: String = ProjectSettings.globalize_path("res://../server/target/debug/phantom-court-server.exe")
	if not runner.assert_true(FileAccess.file_exists(server_exe), "Compiled Rust server exists for Phase 10 PostgreSQL E2E"):
		return

	# Ensure local PostgreSQL 16.4 on 127.0.0.1:15432 is running (start automatically if not already up)
	var started_pg_ourselves := false
	var start_pg_script: String = ProjectSettings.globalize_path("res://../tools/start_local_pg.ps1")
	var stop_pg_script: String = ProjectSettings.globalize_path("res://../tools/stop_local_pg.ps1")

	if not _is_tcp_port_open("127.0.0.1", 15432, 250):
		# Use OS.create_process (no stdout pipe capture!) so postgres.exe never holds an OS.execute pipe open on Windows
		var pg_start_pid: int = OS.create_process(
			"powershell.exe",
			PackedStringArray(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", start_pg_script]),
			false
		)
		started_pg_ourselves = (pg_start_pid > 0)
		for _w in range(60):
			if (pg_start_pid <= 0 or not OS.is_process_running(pg_start_pid)) and _is_tcp_port_open("127.0.0.1", 15432, 150):
				break
			OS.delay_msec(150)

	var pg_listening: bool = _is_tcp_port_open("127.0.0.1", 15432, 600)
	if not runner.assert_true(pg_listening, "Local PostgreSQL 16.4 is accepting connections on 127.0.0.1:15432"):
		return

	var pids: Array[int] = [0, 0] # [server1_pid, server2_pid]
	var c := NetClientNode.new()
	c.name = "P10RankingClient"
	runner.get_stage().add_child(c)

	await _run_ranking_and_durability_checks(runner, server_exe, c, pids)

	# Guaranteed teardown: kill any active server process & stop PG only if we started it
	c.disconnect_from_server("phase10_complete")
	await runner.clear_stage()

	for i in range(pids.size()):
		if pids[i] > 0:
			if OS.is_process_running(pids[i]):
				OS.kill(pids[i])
				OS.delay_msec(120)
			runner.assert_false(OS.is_process_running(pids[i]), "Phase 10 Rust server #%d (pid=%d) terminated cleanly" % [i + 1, pids[i]])

	if started_pg_ourselves:
		OS.create_process(
			"powershell.exe",
			PackedStringArray(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", stop_pg_script]),
			false
		)
		for _w in range(40):
			if not _is_tcp_port_open("127.0.0.1", 15432, 120):
				break
			OS.delay_msec(120)


func _run_ranking_and_durability_checks(
	runner: SceneTree,
	server_exe: String,
	c: NetClientNode,
	pids: Array[int]
) -> void:
	var eb: Node = runner.get_event_bus()
	var profile_events := [0]
	var lb_events := [0]
	runner.connect_temp_signal(eb.profile_loaded, func(_p: Dictionary) -> void:
		profile_events[0] += 1
	)
	runner.connect_temp_signal(eb.leaderboard_loaded, func(_e: Array) -> void:
		lb_events[0] += 1
	)

	var offset: int = int(Time.get_ticks_msec() % 400)
	var http1: int = _pick_free_tcp_port(30100 + offset)
	var udp1: int = _pick_free_udp_port(29700 + offset)
	pids[0] = _spawn_pg_server(server_exe, udp1, http1)
	if not runner.assert_gt(float(pids[0]), 0.0, "Spawned Rust Server #1 against PostgreSQL 16 (pid=%d, http=%d)" % [pids[0], http1]):
		return

	c.host = "127.0.0.1"
	c.http_port = http1
	c.udp_port = udp1

	# ==========================================================================
	# 1. Verify Server #1 Connected to REAL PostgreSQL 16 Backend
	# ==========================================================================
	var h1: Dictionary = _wait_for_server_health(c)
	if not runner.assert_true(bool(h1.get("ok", false)), "Server #1 GET /health returns 200 OK"):
		return
	var h1_data: Dictionary = h1.get("data", {})
	runner.assert_eq(String(h1_data.get("db_backend", "")), "postgres", "Server #1 /health confirms db_backend == 'postgres'")
	runner.assert_false(bool(h1_data.get("ephemeral_db", true)), "Server #1 /health confirms ephemeral_db == false")

	# ==========================================================================
	# 2. Profile Creation, Defaults, Idempotency, Lookup & Signals
	# ==========================================================================
	var tag: String = str(Time.get_ticks_msec()) + "_" + str(pids[0])
	var u_ace := "QA10_Ace_" + tag
	var u_rival := "QA10_Rival_" + tag
	var u_dog := "QA10_Underdog_" + tag

	var p_ace_res: Dictionary = c.create_or_load_profile(u_ace, "speedster")
	var p_rival_res: Dictionary = c.create_or_load_profile(u_rival, "powerhouse")
	var p_dog_res: Dictionary = c.create_or_load_profile(u_dog, "sharpshooter")

	runner.assert_true(bool(p_ace_res.get("ok", false)), "POST /api/profile creates Ace profile in PostgreSQL")
	runner.assert_true(bool(p_rival_res.get("ok", false)), "POST /api/profile creates Rival profile in PostgreSQL")
	runner.assert_true(bool(p_dog_res.get("ok", false)), "POST /api/profile creates Underdog profile in PostgreSQL")

	var ace: Dictionary = p_ace_res.get("data", {})
	var rival: Dictionary = p_rival_res.get("data", {})
	var dog: Dictionary = p_dog_res.get("data", {})
	var id_ace: String = String(ace.get("id", ""))
	var id_rival: String = String(rival.get("id", ""))
	var id_dog: String = String(dog.get("id", ""))

	runner.assert_true(not id_ace.is_empty() and id_ace != id_rival and id_rival != id_dog, "PostgreSQL assigns unique UUIDs to each player")
	runner.assert_approx(float(ace.get("rating", 0.0)), 1500.0, 0.01, "New player starts at Glicko-2 rating 1500.0")
	runner.assert_approx(float(ace.get("rd", 0.0)), 350.0, 0.01, "New player starts at Glicko-2 RD 350.0")
	runner.assert_approx(float(ace.get("volatility", 0.0)), 0.06, 0.0005, "New player starts at Glicko-2 volatility 0.06")
	runner.assert_eq(int(ace.get("wins", -1)), 0, "New player starts with 0 wins")
	runner.assert_eq(int(ace.get("losses", -1)), 0, "New player starts with 0 losses")
	runner.assert_eq(String((ace.get("division", {}) as Dictionary).get("name", "")), "Gold", "1500 rating maps to Gold division")
	runner.assert_eq(int((ace.get("division", {}) as Dictionary).get("tier_index", -1)), 2, "Gold division tier_index == 2")
	runner.assert_ge(profile_events[0], 3, "EventBus.profile_loaded emitted on profile creation/fetch")

	# Idempotent reload + case-insensitive username lookup + 404 unknown
	var ace_reload: Dictionary = c.create_or_load_profile(u_ace, "speedster")
	runner.assert_eq(String((ace_reload.get("data", {}) as Dictionary).get("id", "")), id_ace, "POST /api/profile is idempotent and returns exact existing UUID")
	var ace_by_uuid: Dictionary = c.fetch_profile(id_ace)
	var ace_by_lower: Dictionary = c.fetch_profile(u_ace.to_lower())
	runner.assert_true(bool(ace_by_uuid.get("ok", false)) and String((ace_by_uuid.get("data", {}) as Dictionary).get("username", "")) == u_ace, "GET /api/profile/:uuid resolves player")
	runner.assert_true(bool(ace_by_lower.get("ok", false)) and String((ace_by_lower.get("data", {}) as Dictionary).get("id", "")) == id_ace, "GET /api/profile/:username is case-insensitive")
	var missing_prof: Dictionary = c.fetch_profile("QA10_DoesNotExist_" + tag)
	runner.assert_eq(int(missing_prof.get("status_code", 0)), 404, "Unknown profile returns HTTP 404")

	# ==========================================================================
	# 3. Glicko-2 Ranked Matches, Invariants, History & Global Leaderboard
	# ==========================================================================
	# Match 1: Ace (1500) defeats Rival (1500) 21 - 15
	var m1_res: Dictionary = c.record_ranked_match({
		"mode": "1v1",
		"season_id": 1,
		"team_a_score": 21,
		"team_b_score": 15,
		"duration_sec": 180,
		"participants": [
			{
				"player_id": id_ace,
				"team": 0,
				"archetype": "speedster",
				"points": 21,
				"assists": 3,
				"rebounds": 4,
				"blocks": 1,
				"steals": 2,
				"zone_activations": 1,
			},
			{
				"player_id": id_rival,
				"team": 1,
				"archetype": "powerhouse",
				"points": 15,
				"assists": 1,
				"rebounds": 7,
				"blocks": 3,
				"steals": 0,
				"zone_activations": 1,
			},
		],
	})
	runner.assert_true(bool(m1_res.get("ok", false)), "POST /api/matches/record persists Match 1 in PostgreSQL")
	var m1_d: Dictionary = m1_res.get("data", {})
	runner.assert_eq(int(m1_d.get("winner_team", -1)), 0, "Match 1 winner_team == 0")

	var m1_ace_upd: Dictionary = _find_rating_update(m1_d.get("rating_updates", []), id_ace)
	var m1_riv_upd: Dictionary = _find_rating_update(m1_d.get("rating_updates", []), id_rival)
	var delta_equal: float = float(m1_ace_upd.get("rating_delta", 0.0))
	var ace_r1: float = float(m1_ace_upd.get("rating_after", 0.0))
	var riv_r1: float = float(m1_riv_upd.get("rating_after", 0.0))
	runner.assert_gt(delta_equal, 100.0, "Match 1 winner Ace gains significant Glicko-2 rating (+%.1f)" % delta_equal)
	runner.assert_lt(float(m1_riv_upd.get("rating_delta", 0.0)), -100.0, "Match 1 loser Rival drops significant Glicko-2 rating (%.1f)" % float(m1_riv_upd.get("rating_delta", 0.0)))
	runner.assert_lt(float(m1_ace_upd.get("rd_after", 999.0)), 350.0, "Winner RD shrinks after match (%.1f < 350.0)" % float(m1_ace_upd.get("rd_after", 999.0)))
	runner.assert_lt(float(m1_riv_upd.get("rd_after", 999.0)), 350.0, "Loser RD shrinks after match (%.1f < 350.0)" % float(m1_riv_upd.get("rd_after", 999.0)))
	runner.assert_eq(String((m1_ace_upd.get("division", {}) as Dictionary).get("name", "")), _expected_division_for_rating(ace_r1), "Winner division matches post-match rating threshold")
	runner.assert_eq(String((m1_riv_upd.get("division", {}) as Dictionary).get("name", "")), _expected_division_for_rating(riv_r1), "Loser division matches post-match rating threshold")

	# Match 2 (Upset): Fresh Underdog (1500, RD=350) defeats higher-rated Ace (~1662)!
	var m2_res: Dictionary = c.record_ranked_match({
		"mode": "1v1",
		"season_id": 1,
		"team_a_score": 12,
		"team_b_score": 21,
		"duration_sec": 175,
		"participants": [
			{
				"player_id": id_ace,
				"team": 0,
				"archetype": "speedster",
				"points": 12,
				"assists": 2,
				"rebounds": 2,
				"blocks": 0,
				"steals": 1,
				"zone_activations": 1,
			},
			{
				"player_id": id_dog,
				"team": 1,
				"archetype": "sharpshooter",
				"points": 21,
				"assists": 4,
				"rebounds": 3,
				"blocks": 0,
				"steals": 2,
				"zone_activations": 2,
			},
		],
	})
	runner.assert_true(bool(m2_res.get("ok", false)), "POST /api/matches/record persists Match 2 (upset)")
	var m2_dog_upd: Dictionary = _find_rating_update((m2_res.get("data", {}) as Dictionary).get("rating_updates", []), id_dog)
	var delta_upset: float = float(m2_dog_upd.get("rating_delta", 0.0))
	var dog_r1: float = float(m2_dog_upd.get("rating_after", 0.0))
	runner.assert_gt(delta_upset, delta_equal, "Glicko-2 invariant: beating higher-rated opponent grants larger gain (+%.1f > +%.1f)" % [delta_upset, delta_equal])

	# Verify seasonal stats & match history for Ace
	var ace_post2: Dictionary = (c.fetch_profile(id_ace).get("data", {}) as Dictionary)
	var ace_ss: Dictionary = ace_post2.get("seasonal_stats", {})
	runner.assert_eq(int(ace_post2.get("wins", -1)), 1, "Ace profile has 1 win")
	runner.assert_eq(int(ace_post2.get("losses", -1)), 1, "Ace profile has 1 loss")
	runner.assert_eq(int(ace_ss.get("matches_played", -1)), 2, "Ace seasonal_stats tracks 2 matches_played")
	runner.assert_eq(int(ace_ss.get("points_scored", -1)), 33, "Ace seasonal_stats accumulates 21+12=33 points_scored")
	runner.assert_eq(int(ace_ss.get("steals", -1)), 3, "Ace seasonal_stats accumulates 2+1=3 steals")
	runner.assert_eq(int(ace_ss.get("zone_activations", -1)), 2, "Ace seasonal_stats accumulates 1+1=2 zone_activations")
	runner.assert_ge(float(ace_ss.get("peak_rating", 0.0)), ace_r1 - 0.1, "Ace peak_rating preserves post-Match-1 peak")

	var hist2_res: Dictionary = c.fetch_match_history(id_ace, 10)
	var hist2: Array = (hist2_res.get("data", {}) as Dictionary).get("history", [])
	runner.assert_true(bool(hist2_res.get("ok", false)), "GET /api/profile/:id/history returns 200 OK")
	runner.assert_eq(hist2.size(), 2, "Ace match history contains exact 2 recorded matches")
	if hist2.size() >= 2:
		runner.assert_false(bool((hist2[0] as Dictionary).get("won", true)), "Most recent history entry is Match 2 (loss)")
		runner.assert_true(bool((hist2[1] as Dictionary).get("won", false)), "Older history entry is Match 1 (win)")

	# Verify global leaderboard ordering + EventBus.leaderboard_loaded
	var lb_res: Dictionary = c.fetch_leaderboard(1, 200)
	var lb_entries: Array = (lb_res.get("data", {}) as Dictionary).get("entries", [])
	runner.assert_true(bool(lb_res.get("ok", false)), "GET /api/leaderboard returns 200 OK")
	runner.assert_ge(lb_events[0], 1, "EventBus.leaderboard_loaded emitted")
	var rank_dog: int = _find_leaderboard_rank(lb_entries, id_dog)
	var rank_riv: int = _find_leaderboard_rank(lb_entries, id_rival)
	runner.assert_gt(float(rank_dog), 0.0, "Underdog appears on global leaderboard (rank=%d)" % rank_dog)
	runner.assert_gt(float(rank_riv), 0.0, "Rival appears on global leaderboard (rank=%d)" % rank_riv)
	runner.assert_lt(float(rank_dog), float(rank_riv), "Higher-rated Underdog ranks strictly above Rival on global leaderboard (%d < %d)" % [rank_dog, rank_riv])

	# ==========================================================================
	# 4. Auto-Record Ranked Match When Online Room Finishes
	# ==========================================================================
	var rm_create: Dictionary = c.create_room("1v1", true, false, u_ace, "speedster")
	var r_id: int = int((rm_create.get("data", {}) as Dictionary).get("room_id", 0))
	var r_code: String = String((rm_create.get("data", {}) as Dictionary).get("room_code", ""))
	var m_ace: String = String((rm_create.get("data", {}) as Dictionary).get("member_id", ""))
	var rm_join: Dictionary = c.join_room_by_code(r_code, u_rival, "powerhouse")
	var m_riv: String = String((rm_join.get("data", {}) as Dictionary).get("member_id", ""))
	c.set_ready(r_id, m_ace, true)
	c.set_ready(r_id, m_riv, true)
	var rm_fin: Dictionary = c.finish_room_match(r_id, 18, 12)
	var rm_fin_d: Dictionary = rm_fin.get("data", {})
	runner.assert_true(bool(rm_fin.get("ok", false)), "Online 1v1 room finishes cleanly")
	runner.assert_true(rm_fin_d.has("ranked_record") and rm_fin_d["ranked_record"] is Dictionary, "Room finish automatically records ranked Glicko-2 match in PostgreSQL")

	var ace_before_restart: Dictionary = (c.fetch_profile(id_ace).get("data", {}) as Dictionary)
	var ace_final_rating: float = float(ace_before_restart.get("rating", 0.0))
	var ace_final_rd: float = float(ace_before_restart.get("rd", 0.0))
	runner.assert_eq(int(ace_before_restart.get("wins", -1)), 2, "Online room finish auto-incremented Ace wins to 2")

	# ==========================================================================
	# 5. TRUE Disk Durability Across Full Server Shutdown & Fresh Restart!
	# ==========================================================================
	OS.kill(pids[0])
	OS.delay_msec(150)
	runner.assert_false(OS.is_process_running(pids[0]), "Server #1 killed cleanly before durability restart check")
	pids[0] = 0

	var http2: int = _pick_free_tcp_port(30600 + offset)
	var udp2: int = _pick_free_udp_port(30200 + offset)
	pids[1] = _spawn_pg_server(server_exe, udp2, http2)
	if not runner.assert_gt(float(pids[1]), 0.0, "Spawned fresh Rust Server #2 against same PostgreSQL 16 (pid=%d, http=%d)" % [pids[1], http2]):
		return

	c.http_port = http2
	c.udp_port = udp2
	var h2: Dictionary = _wait_for_server_health(c)
	if not runner.assert_true(bool(h2.get("ok", false)), "Fresh Server #2 GET /health returns 200 OK"):
		return
	runner.assert_eq(String((h2.get("data", {}) as Dictionary).get("db_backend", "")), "postgres", "Fresh Server #2 connected to PostgreSQL 16")

	# Re-query persisted Ace, Underdog, history & leaderboard from brand-new Server #2!
	var ace_after_restart: Dictionary = (c.fetch_profile(id_ace).get("data", {}) as Dictionary)
	var dog_after_restart: Dictionary = (c.fetch_profile(u_dog).get("data", {}) as Dictionary)
	var hist_after_restart: Array = ((c.fetch_match_history(id_ace, 10).get("data", {}) as Dictionary).get("history", []))
	var lb_after_restart: Array = ((c.fetch_leaderboard(1, 200).get("data", {}) as Dictionary).get("entries", []))

	runner.assert_eq(String(ace_after_restart.get("username", "")), u_ace, "PostgreSQL disk persistence: Ace profile survives full server restart")
	runner.assert_approx(float(ace_after_restart.get("rating", 0.0)), ace_final_rating, 0.05, "PostgreSQL disk persistence: exact Ace Glicko-2 rating survives restart")
	runner.assert_approx(float(ace_after_restart.get("rd", 0.0)), ace_final_rd, 0.05, "PostgreSQL disk persistence: exact Ace Glicko-2 RD survives restart")
	runner.assert_eq(int(ace_after_restart.get("wins", -1)), 2, "PostgreSQL disk persistence: Ace wins (2) survive restart")
	runner.assert_eq(int(ace_after_restart.get("losses", -1)), 1, "PostgreSQL disk persistence: Ace losses (1) survive restart")
	runner.assert_approx(float(dog_after_restart.get("rating", 0.0)), dog_r1, 0.05, "PostgreSQL disk persistence: Underdog rating survives restart")
	runner.assert_eq(hist_after_restart.size(), 3, "PostgreSQL disk persistence: all 3 chronological matches survive restart")
	runner.assert_gt(float(_find_leaderboard_rank(lb_after_restart, id_dog)), 0.0, "PostgreSQL disk persistence: Underdog persists on leaderboard after restart")


func _find_rating_update(updates: Array, player_id: String) -> Dictionary:
	for u in updates:
		if u is Dictionary and String((u as Dictionary).get("player_id", "")) == player_id:
			return u as Dictionary
	return {}


func _find_leaderboard_rank(entries: Array, player_id: String) -> int:
	for e in entries:
		if e is Dictionary and String((e as Dictionary).get("player_id", "")) == player_id:
			return int((e as Dictionary).get("rank", 0))
	return 0
