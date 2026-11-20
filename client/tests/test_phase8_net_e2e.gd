extends Node
## Phase 8 Automated Verification Suite — Multiplayer Networking & Rust E2E
## (PHANTOM COURT ONLINE)
## Verifies:
## 1. NetClient autoload registration + ProtocolSerializer byte-exact binary LE roundtrips
##    for all message types (0x01..0x0A), 221-byte 3v3 snapshot size (< 260 B -> < 8 KB/s @ 30 Hz),
##    and corrupted packet rejection.
## 2. PredictionReconciler 128-tick ring buffer, tolerance threshold (<= 0.05m ignored,
##    > 0.05m triggers rollback + input replay), critical state-flag mismatch reconciliation,
##    4-frame smooth visual offset decay, and PlayerController integration.
## 3. EntityInterpolator 100ms buffered interpolation, capped 80ms velocity dead-reckoning,
##    and court-bounds clamping.
## 4. Live E2E against compiled Rust dedicated server (server/target/debug/phantom-court-server.exe)
##    on ephemeral ports with guaranteed OS.kill(pid) teardown:
##    - TCP GET /health 200 OK
##    - 2 headless NetClientNode instances (HelloJoin -> WelcomeJoined)
##    - Ping / Pong RTT & server tick sync
##    - ClientInputBatch 4-frame movement & authoritative ServerWorldSnapshot convergence
##    - Anti-cheat rejection of client-forged score/snapshot packets
##    - Mid-match disconnect + ReconnectRequest(session_token) from fresh UDP socket preserving
##      player entity, token, and live snapshot resumption.

const ARENA_SCENE_PATH := "res://scenes/court/arena.tscn"


func run(runner: SceneTree) -> void:
	await _test_autoload_and_protocol_serializer(runner)
	await _test_prediction_reconciler(runner)
	await _test_entity_interpolator(runner)
	await _test_live_rust_server_e2e(runner)


# ==============================================================================
# 1. NetClient Autoload & ProtocolSerializer Binary Wire Codec Roundtrips
# ==============================================================================
func _test_autoload_and_protocol_serializer(runner: SceneTree) -> void:
	var net_autoload: Node = runner.root.get_node_or_null("NetClient")
	runner.assert_not_null(net_autoload, "NetClient autoload singleton mounted on /root")
	if net_autoload != null:
		runner.assert_true(net_autoload is NetClientNode, "NetClient autoload is instance of NetClientNode")
		runner.assert_not_null(net_autoload.get("reconciler"), "NetClient exposes PredictionReconciler")
		runner.assert_not_null(net_autoload.get("interpolator"), "NetClient exposes EntityInterpolator")

	var eb: Node = runner.get_event_bus()
	runner.assert_true(eb.has_signal("net_connected"), "EventBus exposes net_connected signal")
	runner.assert_true(eb.has_signal("net_disconnected"), "EventBus exposes net_disconnected signal")
	runner.assert_true(eb.has_signal("net_metrics_updated"), "EventBus exposes net_metrics_updated signal")

	# 1A. HelloJoin (0x01)
	var hello_bytes: PackedByteArray = ProtocolSerializer.encode_hello_join(
		"KaelenVolt", "speedster", "court_alpha", "tok_abc", 0, 11, 3, 0x0F
	)
	var hello_dec: Dictionary = ProtocolSerializer.decode_packet(hello_bytes)
	runner.assert_true(bool(hello_dec.get("ok", false)), "HelloJoin decodes cleanly")
	runner.assert_eq(int(hello_dec.get("msg_type", 0)), ProtocolSerializer.MSG_HELLO_JOIN, "HelloJoin opcode == 0x01")
	runner.assert_eq(int(hello_dec.get("seq", 0)), 11, "HelloJoin header seq == 11")
	var hp: Dictionary = hello_dec.get("payload", {})
	runner.assert_eq(String(hp.get("username", "")), "KaelenVolt", "HelloJoin username roundtrip")
	runner.assert_eq(String(hp.get("archetype_id", "")), "speedster", "HelloJoin archetype roundtrip")
	runner.assert_eq(String(hp.get("room_id", "")), "court_alpha", "HelloJoin room_id roundtrip")
	runner.assert_eq(int(hp.get("preferred_team", 255)), 0, "HelloJoin preferred_team roundtrip")

	# 1B. WelcomeJoined (0x02) wire decode check
	var w_peer := StreamPeerBuffer.new()
	w_peer.big_endian = false
	w_peer.put_u16(ProtocolSerializer.MAGIC)
	w_peer.put_u8(ProtocolSerializer.PROTOCOL_VERSION)
	w_peer.put_u8(ProtocolSerializer.MSG_WELCOME_JOINED)
	w_peer.put_u32(2)
	w_peer.put_u32(1)
	w_peer.put_u32(0)
	w_peer.put_u32(42)         # player_id
	w_peer.put_u8(1)           # team_id
	w_peer.put_u8(3)           # assigned_slot
	w_peer.put_u8(2)           # playmaker
	w_peer.put_u8(0)           # reserved
	w_peer.put_u64(9876543210) # session_token
	w_peer.put_u32(1200)       # server_tick
	w_peer.put_u16(60)         # tick_rate
	w_peer.put_u16(30)         # snapshot_rate
	var w_dec: Dictionary = ProtocolSerializer.decode_packet(w_peer.data_array)
	runner.assert_true(bool(w_dec.get("ok", false)), "WelcomeJoined decodes cleanly")
	var wp: Dictionary = w_dec.get("payload", {})
	runner.assert_eq(int(wp.get("player_id", 0)), 42, "WelcomeJoined player_id == 42")
	runner.assert_eq(int(wp.get("team_id", 0)), 1, "WelcomeJoined team_id == 1")
	runner.assert_eq(String(wp.get("archetype_id", "")), "playmaker", "WelcomeJoined archetype == playmaker")
	runner.assert_eq(int(wp.get("session_token", 0)), 9876543210, "WelcomeJoined session_token roundtrip")
	runner.assert_eq(int(wp.get("tick_rate", 0)), 60, "WelcomeJoined tick_rate == 60")

	# 1C. ClientInputBatch (0x03) with 4 redundant frames
	var batch_frames := []
	for i in range(4):
		batch_frames.append({
			"seq": 100 + i,
			"tick": 500 + i,
			"move_world_xz": Vector2(0.5 - 0.1 * i, -0.75),
			"local_dir": Vector2(0.0, 1.0),
			"buttons": 1 | 16,
			"aim_yaw": -1.25 + 0.1 * i,
		})
	var ib_bytes: PackedByteArray = ProtocolSerializer.encode_client_input_batch(123456789, batch_frames, 77)
	var ib_dec: Dictionary = ProtocolSerializer.decode_packet(ib_bytes)
	runner.assert_true(bool(ib_dec.get("ok", false)), "ClientInputBatch decodes cleanly")
	var ibp: Dictionary = ib_dec.get("payload", {})
	runner.assert_eq(int(ibp.get("session_token", 0)), 123456789, "ClientInputBatch session_token roundtrip")
	var dec_frames: Array = ibp.get("frames", [])
	runner.assert_eq(dec_frames.size(), 4, "ClientInputBatch preserves all 4 redundant frames")
	runner.assert_eq(int(dec_frames[3]["seq"]), 103, "ClientInputBatch frame[3] seq == 103")
	runner.assert_approx((dec_frames[0]["move_world_xz"] as Vector2).x, 0.5, 0.0005, "ClientInputBatch move_x quantization accuracy")
	runner.assert_approx(float(dec_frames[0]["aim_yaw"]), -1.25, 0.0005, "ClientInputBatch aim_yaw quantization accuracy")

	# 1D. ServerWorldSnapshot (0x04) full 6-player 3v3 packet size & fidelity check (< 260 bytes!)
	var snap_players := []
	for idx in range(6):
		snap_players.append({
			"player_id": idx + 1,
			"last_processed_input_seq": 200 + idx,
			"position": Vector3(-3.0 + idx * 1.1, 0.25, -8.5 + idx * 2.5),
			"velocity": Vector3(1.5, 0.0, -4.2),
			"yaw": 0.45 * idx - 1.0,
			"stamina": 82.5,
			"zone": 45.0,
			"balance": 95.5,
			"team_id": idx % 2,
			"slot": idx,
			"archetype_id": ProtocolSerializer.ARCHETYPE_NAMES[idx % 5],
			"state_flags": ProtocolSerializer.STATE_GROUNDED | ProtocolSerializer.STATE_DEFENSIVE_STANCE,
			"cooldown_flags": ProtocolSerializer.CD_METEOR_DUNK,
			"active_move_id": 2,
		})
	var snap_in := {
		"server_tick": 3600,
		"match_clock_ms": 142500,
		"shot_clock_ms": 18250,
		"score_a": 14,
		"score_b": 11,
		"possession_team": 0,
		"carrier_id": 1,
		"ball_pos": Vector3(1.25, 2.85, -9.40),
		"ball_vel": Vector3(-0.30, 3.10, -5.80),
		"ball_state": 4,
		"players": snap_players,
	}
	var snap_bytes: PackedByteArray = ProtocolSerializer.encode_world_snapshot(snap_in, 555)
	runner.assert_lt(float(snap_bytes.size()), 260.0, "Full 6-player 3v3 ServerWorldSnapshot is compact < 260 bytes (actual=%d B)" % snap_bytes.size())
	runner.assert_lt(float(snap_bytes.size() * 30), 8000.0, "3v3 snapshot bandwidth at 30 Hz < 8 KB/s (actual=%d B/s)" % (snap_bytes.size() * 30))

	var snap_dec: Dictionary = ProtocolSerializer.decode_packet(snap_bytes)
	runner.assert_true(bool(snap_dec.get("ok", false)), "ServerWorldSnapshot decodes cleanly")
	var sp: Dictionary = snap_dec.get("payload", {})
	runner.assert_eq(int(sp.get("server_tick", 0)), 3600, "Snapshot server_tick == 3600")
	runner.assert_eq(int(sp.get("score_a", 0)), 14, "Snapshot score_a == 14")
	runner.assert_eq(int(sp.get("score_b", 0)), 11, "Snapshot score_b == 11")
	runner.assert_approx((sp.get("ball_pos", Vector3.ZERO) as Vector3).y, 2.85, 0.02, "Snapshot ball_pos.y quantized to 1 cm")
	var dec_players: Array = sp.get("players", [])
	runner.assert_eq(dec_players.size(), 6, "Snapshot decodes all 6 players")
	runner.assert_eq(String(dec_players[0]["active_move_name"]), "meteor_dunk", "Snapshot active_move_id maps to 'meteor_dunk'")
	runner.assert_approx(float(dec_players[0]["stamina"]), 82.5, 0.51, "Snapshot stamina 0.5-step roundtrip")

	# 1E. ReliableMatchEvent (0x05 — Score event) + EventAck (0x06) + Ping/Pong + Reconnect + Spectator
	var ev_peer := StreamPeerBuffer.new()
	ev_peer.big_endian = false
	ev_peer.put_u16(ProtocolSerializer.MAGIC)
	ev_peer.put_u8(ProtocolSerializer.PROTOCOL_VERSION)
	ev_peer.put_u8(ProtocolSerializer.MSG_RELIABLE_MATCH_EVENT)
	ev_peer.put_u32(9)
	ev_peer.put_u32(0)
	ev_peer.put_u32(0)
	ev_peer.put_u32(7) # event_id
	ev_peer.put_u32(900) # server_tick
	ev_peer.put_u8(ProtocolSerializer.EVENT_SCORE)
	ev_peer.put_u8(0)  # team_id
	ev_peer.put_u8(3)  # delta
	ev_peer.put_u8(1)  # is_three
	ev_peer.put_u16(15) # new_score
	ev_peer.put_u16(2)  # scorer_id
	var ev_dec: Dictionary = ProtocolSerializer.decode_packet(ev_peer.data_array)
	runner.assert_true(bool(ev_dec.get("ok", false)), "ReliableMatchEvent (Score) decodes cleanly")
	var evp: Dictionary = ev_dec.get("payload", {})
	runner.assert_eq(int(evp.get("event_id", 0)), 7, "ReliableMatchEvent event_id == 7")
	runner.assert_eq(int(evp.get("delta", 0)), 3, "ReliableMatchEvent score delta == 3")
	runner.assert_true(bool(evp.get("is_three", false)), "ReliableMatchEvent is_three == true")

	var ack_dec: Dictionary = ProtocolSerializer.decode_packet(ProtocolSerializer.encode_event_ack(777, 7, 0x03))
	runner.assert_true(bool(ack_dec.get("ok", false)) and int(ack_dec["payload"]["event_id"]) == 7, "EventAck roundtrip")

	var ping_dec: Dictionary = ProtocolSerializer.decode_packet(ProtocolSerializer.encode_ping(777, 54321))
	runner.assert_true(bool(ping_dec.get("ok", false)) and int(ping_dec["payload"]["client_time_ms"]) == 54321, "Ping roundtrip")

	var pong_peer := StreamPeerBuffer.new()
	pong_peer.big_endian = false
	pong_peer.put_u16(ProtocolSerializer.MAGIC)
	pong_peer.put_u8(ProtocolSerializer.PROTOCOL_VERSION)
	pong_peer.put_u8(ProtocolSerializer.MSG_PONG)
	pong_peer.put_u32(1)
	pong_peer.put_u32(0)
	pong_peer.put_u32(0)
	pong_peer.put_u64(54321)
	pong_peer.put_u32(600)
	pong_peer.put_u64(99999)
	var pong_dec: Dictionary = ProtocolSerializer.decode_packet(pong_peer.data_array)
	runner.assert_true(bool(pong_dec.get("ok", false)) and int(pong_dec["payload"]["server_tick"]) == 600, "Pong decodes cleanly")

	var rec_dec: Dictionary = ProtocolSerializer.decode_packet(ProtocolSerializer.encode_reconnect_request(888999, 12))
	runner.assert_true(bool(rec_dec.get("ok", false)) and int(rec_dec["payload"]["session_token"]) == 888999 and int(rec_dec["payload"]["last_acked_event_id"]) == 12, "ReconnectRequest roundtrip")

	var spec_dec: Dictionary = ProtocolSerializer.decode_packet(ProtocolSerializer.encode_spectator_join("finals", "CameraOne"))
	runner.assert_true(bool(spec_dec.get("ok", false)) and String(spec_dec["payload"]["room_id"]) == "finals" and String(spec_dec["payload"]["spectator_name"]) == "CameraOne", "SpectatorJoin roundtrip")

	# 1F. Corrupted / malformed packet rejection
	runner.assert_false(bool(ProtocolSerializer.decode_packet(PackedByteArray([1, 2, 3])).get("ok", true)), "Rejects truncated packet < 16 bytes")
	var bad_magic: PackedByteArray = hello_bytes.duplicate()
	bad_magic[0] = 0xFF
	runner.assert_false(bool(ProtocolSerializer.decode_packet(bad_magic).get("ok", true)), "Rejects invalid magic bytes")
	var bad_ver: PackedByteArray = hello_bytes.duplicate()
	bad_ver[2] = 99
	runner.assert_false(bool(ProtocolSerializer.decode_packet(bad_ver).get("ok", true)), "Rejects unsupported protocol version")


# ==============================================================================
# 2. PredictionReconciler (128-Tick Ring, >0.05m Rollback/Replay, 4f Decay)
# ==============================================================================
func _test_prediction_reconciler(runner: SceneTree) -> void:
	var rec := PredictionReconciler.new()
	runner.assert_eq(PredictionReconciler.RING_CAPACITY, 128, "PredictionReconciler ring capacity == 128 ticks")

	# Ring buffer wrap check (140 ticks -> seq 1..12 overwritten, seq 13..140 retained)
	for s in range(1, 141):
		rec.record_prediction(s, {"seq": s, "tick": s}, {"position": Vector3(float(s) * 0.1, 0.0, 0.0)})
	runner.assert_true(rec.get_prediction(1).is_empty(), "Ring buffer overwrites oldest entry seq 1 after 140 writes")
	runner.assert_eq(int(rec.get_prediction(13).get("seq", 0)), 13, "Ring buffer retains exact oldest valid entry seq 13")
	runner.assert_eq(int(rec.get_prediction(140).get("seq", 0)), 140, "Ring buffer retains newest entry seq 140")

	# Fresh deterministic rollback & 4-frame smooth visual offset decay test
	rec.clear()
	var sim_pos := [Vector3.ZERO]
	var sim_vel := [Vector3(9.0, 0.0, 0.0)]
	var step_dx: float = 0.15

	for s in range(1, 11):
		sim_pos[0] = sim_pos[0] + Vector3(step_dx, 0.0, 0.0)
		rec.record_prediction(
			s,
			{"seq": s, "tick": s, "dx": step_dx},
			{"position": sim_pos[0], "velocity": sim_vel[0], "state_flags": ProtocolSerializer.STATE_GROUNDED}
		)

	var apply_fn := func(auth: Dictionary) -> void:
		sim_pos[0] = auth["position"]
		sim_vel[0] = auth["velocity"]
	var replay_fn := func(frame: Dictionary) -> Dictionary:
		sim_pos[0] = sim_pos[0] + Vector3(float(frame["dx"]), 0.0, 0.0)
		return {"position": sim_pos[0], "velocity": sim_vel[0], "state_flags": ProtocolSerializer.STATE_GROUNDED}
	var pos_fn := func() -> Vector3:
		return sim_pos[0]

	# Small error (0.02m <= 0.05m threshold) at seq 5 -> NO rollback!
	var small_res: Dictionary = rec.reconcile({
		"last_processed_input_seq": 5,
		"position": Vector3(0.75 - 0.02, 0.0, 0.0),
		"velocity": sim_vel[0],
		"state_flags": ProtocolSerializer.STATE_GROUNDED,
	}, apply_fn, replay_fn, pos_fn)
	runner.assert_false(bool(small_res["corrected"]), "Small error (0.02m <= 0.05m) does NOT trigger rollback")
	runner.assert_eq(rec.get_reconciliation_count(), 0, "Reconciliation count remains 0 on tiny error")
	runner.assert_eq(rec.get_pending_inputs_after(5).size(), 5, "Pending inputs 6..10 retained after seq 5 ack")

	# Large error (0.30m > 0.05m threshold) at seq 6 -> rewind to 0.60 + replay 4 pending frames (7..10 -> 1.20)!
	var big_res: Dictionary = rec.reconcile({
		"last_processed_input_seq": 6,
		"position": Vector3(0.60, 0.0, 0.0), # predicted was 0.90 -> 0.30m error!
		"velocity": sim_vel[0],
		"state_flags": ProtocolSerializer.STATE_GROUNDED,
	}, apply_fn, replay_fn, pos_fn)
	runner.assert_true(bool(big_res["corrected"]), "Error 0.30m (> 0.05m) triggers rollback & input replay")
	runner.assert_eq(int(big_res["replayed_count"]), 4, "Replays exact 4 unacknowledged inputs (seq 7..10)")
	runner.assert_eq(rec.get_reconciliation_count(), 1, "Reconciliation count increments to 1")
	runner.assert_approx(sim_pos[0].x, 1.20, 0.001, "Replayed simulation converges cleanly to 0.60 + 4*0.15 = 1.20m")

	# 4-frame smooth visual offset decay: pre (1.50) - post (1.20) = +0.30 -> 0.225 -> 0.15 -> 0.075 -> 0.0!
	runner.assert_approx(rec.get_visual_offset().x, 0.30, 0.001, "Initial visual offset captures pre - post delta (+0.30m)")
	runner.assert_approx(rec.step_visual_decay().x, 0.225, 0.001, "Visual decay frame 1 == 3/4 (+0.225m)")
	runner.assert_approx(rec.step_visual_decay().x, 0.150, 0.001, "Visual decay frame 2 == 2/4 (+0.150m)")
	runner.assert_approx(rec.step_visual_decay().x, 0.075, 0.001, "Visual decay frame 3 == 1/4 (+0.075m)")
	runner.assert_approx(rec.step_visual_decay().x, 0.000, 0.001, "Visual decay frame 4 completes smoothly to 0.0")

	# Critical state-flag mismatch (STATE_ANKLE_BROKEN) triggers reconciliation even at 0.0m position error
	var flag_res: Dictionary = rec.reconcile({
		"last_processed_input_seq": 8,
		"position": Vector3(0.90, 0.0, 0.0), # exact match with replayed seq 8!
		"velocity": sim_vel[0],
		"state_flags": ProtocolSerializer.STATE_GROUNDED | ProtocolSerializer.STATE_ANKLE_BROKEN,
	}, apply_fn, replay_fn, pos_fn)
	runner.assert_true(bool(flag_res["corrected"]) and bool(flag_res["state_mismatch"]), "Critical state flag mismatch (ANKLE_BROKEN) forces reconciliation")


# ==============================================================================
# 3. EntityInterpolator (100ms Buffered Interpolation & Capped 80ms Extrapolation)
# ==============================================================================
func _test_entity_interpolator(runner: SceneTree) -> void:
	var interp := EntityInterpolator.new()
	runner.assert_approx(interp.get_effective_delay_ms(), 100.0, 0.01, "Default interpolation delay == 100.0ms")
	runner.assert_approx(interp.max_extrapolation_ms, 80.0, 0.01, "Default max extrapolation cap == 80.0ms")

	# Push 4 snapshots at 0, 100, 200, 300ms (remote player moving at +10.0 m/s along X)
	for i in range(4):
		var t_ms: float = float(i) * 100.0
		var x_val: float = float(i) * 1.0
		interp.push_world_snapshot({
			"server_tick": i * 6,
			"ball_pos": Vector3(x_val, 1.0, -2.0),
			"ball_vel": Vector3(10.0, 0.0, 0.0),
			"ball_state": 2,
			"carrier_id": 2,
			"players": [{
				"player_id": 2,
				"position": Vector3(x_val, 0.0, -2.0),
				"velocity": Vector3(10.0, 0.0, 0.0),
				"yaw": 0.0,
				"stamina": 100.0 - float(i) * 10.0,
				"zone": float(i) * 20.0,
				"balance": 100.0,
			}],
		}, t_ms)

	# Interpolate at render_time = 250ms -> target_time = 250 - 100 = 150ms (exact midpoint between 100ms and 200ms!)
	var mid_p: Dictionary = interp.sample_player(2, 250.0)
	var mid_b: Dictionary = interp.sample_ball(250.0)
	runner.assert_false(bool(mid_p.get("extrapolated", true)), "Buffered sample at 250ms interpolates (extrapolated == false)")
	runner.assert_approx((mid_p["position"] as Vector3).x, 1.50, 0.005, "Remote player 100ms buffered interpolation hits exact midpoint x=1.50m")
	runner.assert_approx(float(mid_p["stamina"]), 85.0, 0.05, "Remote player stamina interpolates smoothly (85.0)")
	runner.assert_approx((mid_b["position"] as Vector3).x, 1.50, 0.005, "Ball 100ms buffered interpolation hits exact midpoint x=1.50m")

	# Mild packet burst loss: render_time = 440ms -> target_time = 340ms (40ms past latest 300ms) -> dead-reckons +0.40m
	runner.assert_true(interp.is_extrapolating(2, 440.0), "is_extrapolating() == true when target_ms > latest snapshot")
	var ext40: Dictionary = interp.sample_player(2, 440.0)
	runner.assert_true(bool(ext40.get("extrapolated", false)), "Extrapolation flag set during packet burst loss")
	runner.assert_approx(float(ext40.get("extrapolation_ms", 0.0)), 40.0, 0.01, "Extrapolation duration == 40.0ms")
	runner.assert_approx((ext40["position"] as Vector3).x, 3.40, 0.005, "40ms velocity dead-reckoning advances x=3.0 -> 3.40m")

	# Severe packet loss: render_time = 650ms -> target_time = 550ms (250ms past 300ms) -> strictly capped at 80ms!
	var ext_cap: Dictionary = interp.sample_player(2, 650.0)
	runner.assert_approx(float(ext_cap.get("extrapolation_ms", 0.0)), 80.0, 0.01, "Extrapolation strictly capped at 80.0ms max")
	runner.assert_approx((ext_cap["position"] as Vector3).x, 3.80, 0.005, "Capped 80ms dead-reckoning stops cleanly at x=3.80m (never overshoots)")


# ==============================================================================
# 4. Live E2E Against Real Rust Dedicated Server (Guaranteed Teardown!)
# ==============================================================================
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


func _test_live_rust_server_e2e(runner: SceneTree) -> void:
	await runner.clear_stage()

	var server_exe: String = ProjectSettings.globalize_path("res://../server/target/debug/phantom-court-server.exe")
	if not runner.assert_true(FileAccess.file_exists(server_exe), "Compiled Rust dedicated server exists at server/target/debug/phantom-court-server.exe"):
		return

	var base_offset: int = int(Time.get_ticks_msec() % 400)
	var http_port: int = _pick_free_tcp_port(28100 + base_offset)
	var udp_port: int = _pick_free_udp_port(27700 + base_offset)

	var args := PackedStringArray([
		"--bind", "127.0.0.1",
		"--udp-port", str(udp_port),
		"--http-port", str(http_port),
		"--tick-rate", "60",
		"--ephemeral-db",
	])
	var server_pid: int = OS.create_process(server_exe, args, false)
	if not runner.assert_gt(float(server_pid), 0.0, "Spawned real Rust dedicated server process (pid=%d, udp=%d, http=%d)" % [server_pid, udp_port, http_port]):
		return

	var c1 := NetClientNode.new()
	c1.name = "E2EClient1"
	var c2 := NetClientNode.new()
	c2.name = "E2EClient2"
	runner.get_stage().add_child(c1)
	runner.get_stage().add_child(c2)

	# Run all live checks inside helper so teardown ALWAYS kills server_pid cleanly!
	await _run_live_server_e2e_checks(runner, c1, c2, udp_port, http_port)

	# Guaranteed teardown: close both clients, kill Rust server, confirm process terminated!
	c1.disconnect_from_server("test_complete")
	c2.disconnect_from_server("test_complete")
	await runner.clear_stage()

	if server_pid > 0:
		OS.kill(server_pid)
		OS.delay_msec(120)
		runner.assert_false(OS.is_process_running(server_pid), "Rust dedicated server process (pid=%d) terminated cleanly on teardown" % server_pid)


func _run_live_server_e2e_checks(
	runner: SceneTree,
	c1: NetClientNode,
	c2: NetClientNode,
	udp_port: int,
	http_port: int
) -> void:
	# --- 4A. TCP GET /health readiness ---
	c1.host = "127.0.0.1"
	c1.http_port = http_port
	var health_res: Dictionary = {}
	for _attempt in range(30):
		health_res = c1.http_request_sync(HTTPClient.METHOD_GET, "/health", {}, 0.4)
		if bool(health_res.get("ok", false)) and int(health_res.get("status_code", 0)) == 200:
			break
		OS.delay_msec(50)

	var health_ok: bool = bool(health_res.get("ok", false)) and int(health_res.get("status_code", 0)) == 200
	if not runner.assert_true(health_ok, "Rust server TCP GET /health returns 200 OK"):
		return
	var hdata: Dictionary = health_res.get("data", {})
	runner.assert_eq(String(hdata.get("status", "")), "ok", "/health JSON status == 'ok'")
	runner.assert_eq(int(hdata.get("udp_port", 0)), udp_port, "/health reports exact ephemeral udp_port")
	runner.assert_eq(int(hdata.get("tick_rate", 0)), 60, "/health reports tick_rate == 60")

	# --- 4B. Connect 2 headless NetClientNode instances ---
	var eb: Node = runner.get_event_bus()
	var net_conn_count := [0]
	var c1_pongs := [0]
	var c2_pongs := [0]
	var c1_snaps := [0]
	var c2_snaps := [0]
	runner.connect_temp_signal(eb.net_connected, func(_info: Dictionary) -> void:
		net_conn_count[0] += 1
	)
	c1.pong_received.connect(func(_rtt: float, _tk: int) -> void:
		c1_pongs[0] += 1
	)
	c2.pong_received.connect(func(_rtt: float, _tk: int) -> void:
		c2_pongs[0] += 1
	)
	c1.snapshot_received.connect(func(_s: Dictionary) -> void:
		c1_snaps[0] += 1
	)
	c2.snapshot_received.connect(func(_s: Dictionary) -> void:
		c2_snaps[0] += 1
	)

	var e1: int = c1.connect_to_server("127.0.0.1", udp_port, "KaelenE2E", "speedster", "e2e_room", http_port, 0)
	var e2: int = c2.connect_to_server("127.0.0.1", udp_port, "TitanE2E", "powerhouse", "e2e_room", http_port, 1)
	runner.assert_eq(e1, OK, "Client 1 UDP socket opened & HelloJoin sent")
	runner.assert_eq(e2, OK, "Client 2 UDP socket opened & HelloJoin sent")

	for _w in range(50):
		await runner.wait_physics_frames(1)
		if c1.is_connected_to_server and c2.is_connected_to_server and c1_snaps[0] >= 2 and c2_snaps[0] >= 2:
			break

	if not runner.assert_true(c1.is_connected_to_server and c2.is_connected_to_server, "Both headless Godot clients complete WelcomeJoined handshake with Rust server"):
		return
	runner.assert_true(c1.local_player_id > 0 and c2.local_player_id > 0 and c1.local_player_id != c2.local_player_id, "Server assigns distinct player_ids (c1=%d, c2=%d)" % [c1.local_player_id, c2.local_player_id])
	runner.assert_true(c1.session_token != 0 and c2.session_token != 0 and c1.session_token != c2.session_token, "Server assigns unique non-zero session_tokens")
	runner.assert_eq(c1.local_team_id, 0, "Client 1 assigned preferred team 0")
	runner.assert_eq(c2.local_team_id, 1, "Client 2 assigned preferred team 1")
	runner.assert_ge(net_conn_count[0], 2, "EventBus.net_connected emitted for both clients")

	# --- 4C. Live Ping / Pong RTT ---
	c1.send_ping()
	c2.send_ping()
	for _w in range(30):
		await runner.wait_physics_frames(1)
		if c1_pongs[0] >= 1 and c2_pongs[0] >= 1:
			break
	runner.assert_ge(c1_pongs[0], 1, "Client 1 receives Pong from Rust server")
	runner.assert_ge(c2_pongs[0], 1, "Client 2 receives Pong from Rust server")
	runner.assert_true(c1.rtt_ms >= 0.0 and c1.rtt_ms < 250.0, "Client 1 measured localhost RTT valid (%.2fms)" % c1.rtt_ms)

	# --- 4D. ClientInputBatch Movement & Authoritative ServerWorldSnapshot Sync ---
	var init_p1: Dictionary = _find_player_in_snapshot(c1.get_last_snapshot(), c1.local_player_id)
	var init_p2: Dictionary = _find_player_in_snapshot(c2.get_last_snapshot(), c2.local_player_id)
	var init_p1_x: float = (init_p1.get("position", Vector3.ZERO) as Vector3).x
	var init_p2_x: float = (init_p2.get("position", Vector3.ZERO) as Vector3).x

	var seq1 := 0
	var seq2 := 0
	for tk in range(1, 31):
		seq1 += 1
		seq2 += 1
		c1.queue_local_input({
			"seq": seq1,
			"tick": c1.server_tick + tk,
			"move_world_xz": Vector2(1.0, 0.0), # Move +X
			"local_dir": Vector2(1.0, 0.0),
			"buttons": 1, # Sprint
			"aim_yaw": 0.0,
		})
		c2.queue_local_input({
			"seq": seq2,
			"tick": c2.server_tick + tk,
			"move_world_xz": Vector2(-1.0, 0.0), # Move -X
			"local_dir": Vector2(-1.0, 0.0),
			"buttons": 1, # Sprint
			"aim_yaw": PI,
		})
		await runner.wait_physics_frames(1)

	# Let final authoritative snapshots arrive
	await runner.wait_physics_frames(12)

	var snap1: Dictionary = c1.get_last_snapshot()
	var snap2: Dictionary = c2.get_last_snapshot()
	runner.assert_eq((snap1.get("players", []) as Array).size(), 2, "Client 1 authoritative snapshot includes both connected players")
	runner.assert_eq((snap2.get("players", []) as Array).size(), 2, "Client 2 authoritative snapshot includes both connected players")

	var post_p1: Dictionary = _find_player_in_snapshot(snap1, c1.local_player_id)
	var post_p2_seen_by_c1: Dictionary = _find_player_in_snapshot(snap1, c2.local_player_id)
	var post_p2: Dictionary = _find_player_in_snapshot(snap2, c2.local_player_id)
	var post_p1_x: float = (post_p1.get("position", Vector3.ZERO) as Vector3).x
	var post_p2_x: float = (post_p2.get("position", Vector3.ZERO) as Vector3).x

	runner.assert_ge(int(post_p1.get("last_processed_input_seq", 0)), 20, "Server processed Client 1 input batches (ack_seq=%d)" % int(post_p1.get("last_processed_input_seq", 0)))
	runner.assert_ge(int(post_p2.get("last_processed_input_seq", 0)), 20, "Server processed Client 2 input batches (ack_seq=%d)" % int(post_p2.get("last_processed_input_seq", 0)))
	runner.assert_gt(post_p1_x - init_p1_x, 0.5, "Authoritative server simulated Client 1 +X movement (dx=%.2fm)" % (post_p1_x - init_p1_x))
	runner.assert_lt(post_p2_x - init_p2_x, -0.5, "Authoritative server simulated Client 2 -X movement (dx=%.2fm)" % (post_p2_x - init_p2_x))
	runner.assert_approx((post_p2_seen_by_c1.get("position", Vector3.ZERO) as Vector3).x, post_p2_x, 0.5, "Client 1 snapshot mirrors Client 2 authoritative movement")
	runner.assert_true(c1.interpolator.get_tracked_player_ids().has(c2.local_player_id), "Client 1 EntityInterpolator tracks remote Client 2")

	# --- 4E. Anti-Cheat: Forged Client Snapshot/Score Packet Rejected by Authoritative Server ---
	var forged_snap: PackedByteArray = ProtocolSerializer.encode_world_snapshot({
		"server_tick": c1.server_tick + 999,
		"score_a": 999,
		"score_b": 777,
		"possession_team": 0,
		"carrier_id": c1.local_player_id,
		"ball_pos": Vector3(0.0, 3.05, -12.425),
		"ball_vel": Vector3.ZERO,
		"ball_state": 1,
		"players": [],
	}, 9999)
	c1.call("_send_raw", forged_snap)
	await runner.wait_physics_frames(15)
	var after_spoof: Dictionary = c1.get_last_snapshot()
	runner.assert_eq(int(after_spoof.get("score_a", -1)), 0, "Anti-cheat: server rejects client-forged score_a=999 (stays 0)")
	runner.assert_eq(int(after_spoof.get("score_b", -1)), 0, "Anti-cheat: server rejects client-forged score_b=777 (stays 0)")

	# --- 4F. Mid-Match Disconnect + ReconnectRequest(session_token) from Brand-New UDP Socket ---
	var saved_pid: int = c1.local_player_id
	var saved_team: int = c1.local_team_id
	var saved_token: int = c1.session_token
	var saved_pos: Vector3 = post_p1.get("position", Vector3.ZERO)
	var pre_reconn_snaps: int = c1_snaps[0]

	var rec_err: int = c1.reconnect_session("127.0.0.1", udp_port)
	runner.assert_eq(rec_err, OK, "Client 1 closed old socket, bound fresh UDP port & sent ReconnectRequest(session_token)")

	for _w in range(50):
		await runner.wait_physics_frames(1)
		if c1.is_connected_to_server and c1_snaps[0] >= pre_reconn_snaps + 2:
			break

	runner.assert_true(c1.is_connected_to_server, "Client 1 seamlessly reconnected from fresh UDP socket")
	runner.assert_eq(c1.local_player_id, saved_pid, "Reconnect preserves exact player_id (%d)" % saved_pid)
	runner.assert_eq(c1.local_team_id, saved_team, "Reconnect preserves exact team_id (%d)" % saved_team)
	runner.assert_eq(c1.session_token, saved_token, "Reconnect preserves exact session_token")
	var reconn_p1: Dictionary = _find_player_in_snapshot(c1.get_last_snapshot(), saved_pid)
	var reconn_pos: Vector3 = reconn_p1.get("position", Vector3.ZERO)
	runner.assert_lt(reconn_pos.distance_to(saved_pos), 1.5, "Reconnect preserves live player entity position (drift=%.2fm)" % reconn_pos.distance_to(saved_pos))

	# Verify rebound session continues processing fresh ClientInputBatches!
	var ack_before: int = int(reconn_p1.get("last_processed_input_seq", 0))
	for tk in range(1, 13):
		seq1 += 1
		c1.queue_local_input({
			"seq": seq1,
			"tick": c1.server_tick + tk,
			"move_world_xz": Vector2(0.0, -1.0),
			"local_dir": Vector2(0.0, 1.0),
			"buttons": 0,
			"aim_yaw": 0.0,
		})
		await runner.wait_physics_frames(1)
	await runner.wait_physics_frames(10)
	var post_reconn_p1: Dictionary = _find_player_in_snapshot(c1.get_last_snapshot(), saved_pid)
	runner.assert_gt(int(post_reconn_p1.get("last_processed_input_seq", 0)), ack_before, "Reconnected UDP session resumes authoritative input processing")


func _find_player_in_snapshot(snapshot: Dictionary, pid: int) -> Dictionary:
	var players: Array = snapshot.get("players", [])
	for p_var in players:
		if p_var is Dictionary and int((p_var as Dictionary).get("player_id", 0)) == pid:
			return p_var as Dictionary
	return {}
