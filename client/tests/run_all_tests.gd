extends SceneTree
## Reusable cumulative headless Godot test runner for Phantom Court Online.
## Usage:
##   tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path client -s res://tests/run_all_tests.gd
## Optional user args (after `--`):
##   --filter <substring>   Run only test_phase*.gd files matching substring
##   --timeout <seconds>    Override global wall-clock safety timeout (default 120s)

const TESTS_DIR := "res://tests"
const DEFAULT_TIMEOUT_SEC := 240.0

var total_passed: int = 0
var total_failed: int = 0
var total_errors: int = 0
var suite_results: Array[Dictionary] = []

var current_suite_name: String = ""
var _suite_passed: int = 0
var _suite_failed: int = 0
var _suite_failures: Array[String] = []

var _suite_host: Node = null
var _stage: Node = null
var _temp_signal_connections: Array[Dictionary] = []
var _started: bool = false
var _finished: bool = false
var _start_msec: int = 0
var _timeout_sec: float = DEFAULT_TIMEOUT_SEC
var _suite_filter: String = ""


func _initialize() -> void:
	_start_msec = Time.get_ticks_msec()
	_parse_runner_args()

	_suite_host = Node.new()
	_suite_host.name = "TestSuiteHost"
	root.add_child(_suite_host)

	_stage = Node.new()
	_stage.name = "TestStage"
	root.add_child(_stage)

	print("========================================================================")
	print(" PHANTOM COURT ONLINE — Headless Automated Test Runner")
	print(" Godot: %s | Physics TPS: %d | Timeout: %.1fs" % [
		Engine.get_version_info().get("string", "unknown"),
		Engine.physics_ticks_per_second,
		_timeout_sec,
	])
	if not _suite_filter.is_empty():
		print(" Filter: '%s'" % _suite_filter)
	print("========================================================================")


func _process(_delta: float) -> bool:
	if _finished:
		return true

	var elapsed_sec: float = float(Time.get_ticks_msec() - _start_msec) / 1000.0
	if elapsed_sec > _timeout_sec:
		_finished = true
		total_errors += 1
		printerr("[FATAL TIMEOUT] Test runner exceeded %.1fs safety timeout (active suite: %s)" % [
			_timeout_sec,
			current_suite_name if not current_suite_name.is_empty() else "<initializing>",
		])
		_print_summary(elapsed_sec)
		quit(1)
		return true

	if not _started:
		_started = true
		_execute_all_suites()

	return false


func _parse_runner_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		var arg: String = args[i]
		match arg:
			"--filter", "--suite":
				if i + 1 < args.size():
					_suite_filter = args[i + 1].strip_edges()
					i += 1
			"--timeout":
				if i + 1 < args.size():
					_timeout_sec = maxf(5.0, float(args[i + 1]))
					i += 1
		i += 1


func _discover_suites() -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(TESTS_DIR)
	if dir == null:
		total_errors += 1
		printerr("[RUNNER ERROR] Unable to open tests directory: %s" % TESTS_DIR)
		return found

	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname.is_empty():
			break
		if dir.current_is_dir():
			continue
		if fname.ends_with(".gd.remap"):
			fname = fname.trim_suffix(".remap")
		if fname.begins_with("test_phase") and fname.ends_with(".gd"):
			if _suite_filter.is_empty() or fname.contains(_suite_filter):
				var full_path := "%s/%s" % [TESTS_DIR, fname]
				if not found.has(full_path):
					found.append(full_path)
	dir.list_dir_end()

	found.sort_custom(_compare_suite_paths)
	return found


static func _extract_phase_number(path: String) -> int:
	var base: String = path.get_file().trim_prefix("test_phase")
	var digits := ""
	for i in range(base.length()):
		var ch: String = base.substr(i, 1)
		if ch >= "0" and ch <= "9":
			digits += ch
		else:
			break
	if digits.is_empty():
		return 999999
	return int(digits)


static func _compare_suite_paths(a: String, b: String) -> bool:
	var pa: int = _extract_phase_number(a)
	var pb: int = _extract_phase_number(b)
	if pa != pb:
		return pa < pb
	return a < b


func _execute_all_suites() -> void:
	await process_frame
	await physics_frame

	_run_core_sanity_checks()

	var suites: Array[String] = _discover_suites()
	if suites.is_empty():
		if not _suite_filter.is_empty():
			total_errors += 1
			printerr("[RUNNER ERROR] No test_phase*.gd suite matched filter '%s'" % _suite_filter)
		else:
			print("[RUNNER] 0 test_phase*.gd suites registered yet (harness sanity checks complete).")
	else:
		print("[RUNNER] Discovered %d suite(s): %s" % [suites.size(), ", ".join(suites)])
		for suite_path in suites:
			if _finished:
				return
			await _run_single_suite(suite_path)

	if _finished:
		return

	_finished = true
	var elapsed_sec: float = float(Time.get_ticks_msec() - _start_msec) / 1000.0
	_print_summary(elapsed_sec)

	var exit_code: int = 0 if (total_failed == 0 and total_errors == 0) else 1
	quit(exit_code)


func _run_core_sanity_checks() -> void:
	_begin_suite("core_autoload_and_project_contracts")
	assert_eq(Engine.physics_ticks_per_second, 60, "Physics tick rate is 60 Hz")
	assert_not_null(root.get_node_or_null("EventBus"), "EventBus autoload mounted on /root")
	assert_not_null(root.get_node_or_null("GameState"), "GameState autoload mounted on /root")
	assert_not_null(root.get_node_or_null("ConfigManager"), "ConfigManager autoload mounted on /root")

	var required_actions: Array[String] = [
		"move_forward", "move_back", "move_left", "move_right",
		"sprint", "jump", "shoot", "pass_ball",
		"skill_q", "skill_e", "skill_r", "steal",
		"defensive_stance", "zone_activate", "pause",
	]
	for act in required_actions:
		assert_true(InputMap.has_action(act), "InputMap defines action '%s'" % act)
	_end_suite()


func _run_single_suite(suite_path: String) -> void:
	var suite_label: String = suite_path.get_file().trim_suffix(".gd")
	_begin_suite(suite_label)

	var script := load(suite_path) as GDScript
	if script == null or not script.can_instantiate():
		total_errors += 1
		_record_fail("Load & compile %s" % suite_path, "GDScript failed to load or compile")
		_end_suite()
		return

	var instance: Variant = script.new()
	if instance == null:
		total_errors += 1
		_record_fail("Instantiate %s" % suite_path, "script.new() returned null")
		_end_suite()
		return

	var suite_node: Node = null
	if instance is Node:
		suite_node = instance as Node
		suite_node.name = suite_label
		_suite_host.add_child(suite_node)
		await process_frame

	if instance.has_method("run"):
		await instance.run(self)
	elif instance.has_method("run_tests"):
		await instance.run_tests(self)
	else:
		var methods: Array[Dictionary] = instance.get_method_list()
		var test_methods: Array[String] = []
		for m in methods:
			var mname: String = str(m.get("name", ""))
			if mname.begins_with("test_"):
				test_methods.append(mname)
		test_methods.sort()
		if test_methods.is_empty():
			total_errors += 1
			_record_fail("Suite entry point in %s" % suite_path, "Expected func run(runner) or test_*() methods")
		else:
			for mname in test_methods:
				if _finished:
					return
				await instance.call(mname, self)

	disconnect_temp_signals()
	await clear_stage()
	if suite_node != null and is_instance_valid(suite_node):
		_suite_host.remove_child(suite_node)
		suite_node.queue_free()
		await process_frame
	_reset_global_autoload_state()
	_end_suite()


func _begin_suite(suite_name: String) -> void:
	current_suite_name = suite_name
	_suite_passed = 0
	_suite_failed = 0
	_suite_failures.clear()
	print("\n--- SUITE: %s ---" % suite_name)


func _end_suite() -> void:
	var status: String = "PASS" if _suite_failed == 0 else "FAIL"
	print("--- END SUITE: %s [%s] (passed=%d, failed=%d) ---" % [
		current_suite_name,
		status,
		_suite_passed,
		_suite_failed,
	])
	suite_results.append({
		"name": current_suite_name,
		"passed": _suite_passed,
		"failed": _suite_failed,
		"failures": _suite_failures.duplicate(),
	})
	current_suite_name = ""


func _reset_global_autoload_state() -> void:
	Engine.time_scale = 1.0
	paused = false
	var gs: Node = root.get_node_or_null("GameState")
	if gs != null and gs.has_method("reset_match_state"):
		gs.call("reset_match_state")
		gs.set("is_online", false)
		gs.set("match_phase", 0)
	for action_name in InputMap.get_actions():
		if Input.is_action_pressed(action_name):
			Input.action_release(action_name)


func _print_summary(elapsed_sec: float) -> void:
	print("\n========================================================================")
	print(" TEST SUMMARY (%.2fs)" % elapsed_sec)
	print("------------------------------------------------------------------------")
	for res in suite_results:
		var tag: String = "PASS" if int(res["failed"]) == 0 else "FAIL"
		print("  [%s] %-42s  %3d passed, %3d failed" % [
			tag,
			str(res["name"]),
			int(res["passed"]),
			int(res["failed"]),
		])
		var fails: Array = res["failures"]
		for f in fails:
			print("         -> %s" % str(f))
	print("------------------------------------------------------------------------")
	var overall: String = "ALL TESTS PASSED" if (total_failed == 0 and total_errors == 0) else "TESTS FAILED"
	print(" RESULT: %s | Passed: %d | Failed: %d | Errors: %d" % [
		overall,
		total_passed,
		total_failed,
		total_errors,
	])
	print("========================================================================")


# ==============================================================================
# Stage, Signal & Simulation Helpers for Test Suites
# ==============================================================================

func get_stage() -> Node:
	return _stage


func get_event_bus() -> Node:
	return root.get_node_or_null("EventBus")


func get_game_state() -> Node:
	return root.get_node_or_null("GameState")


func get_config_manager() -> Node:
	return root.get_node_or_null("ConfigManager")


func connect_temp_signal(sig: Signal, callable: Callable) -> void:
	if not sig.is_connected(callable):
		sig.connect(callable)
		_temp_signal_connections.append({"signal": sig, "callable": callable})


func disconnect_temp_signals() -> void:
	for entry in _temp_signal_connections:
		var sig: Signal = entry["signal"]
		var cb: Callable = entry["callable"]
		if is_instance_valid(sig.get_object()) and sig.is_connected(cb):
			sig.disconnect(cb)
	_temp_signal_connections.clear()


func mount_scene(scene_path: String) -> Node:
	if not ResourceLoader.exists(scene_path):
		_record_fail("mount_scene(%s)" % scene_path, "Resource does not exist")
		return null
	var packed := load(scene_path) as PackedScene
	if packed == null:
		_record_fail("mount_scene(%s)" % scene_path, "Failed to load PackedScene")
		return null
	var inst: Node = packed.instantiate()
	if inst == null:
		_record_fail("mount_scene(%s)" % scene_path, "PackedScene.instantiate() returned null")
		return null
	_stage.add_child(inst)
	await process_frame
	await physics_frame
	return inst


func mount_node(node: Node) -> Node:
	if node == null:
		_record_fail("mount_node", "Node is null")
		return null
	_stage.add_child(node)
	await process_frame
	await physics_frame
	return node


func clear_stage() -> void:
	disconnect_temp_signals()
	for action_name in InputMap.get_actions():
		if Input.is_action_pressed(action_name):
			Input.action_release(action_name)
	if _stage == null:
		return
	for child in _stage.get_children():
		_stage.remove_child(child)
		child.queue_free()
	await process_frame
	await physics_frame
	await physics_frame


func wait_physics_frames(count: int) -> void:
	var steps: int = maxi(1, count)
	for _i in range(steps):
		if _finished:
			return
		await physics_frame


func wait_seconds(seconds: float) -> void:
	var ticks: int = maxi(1, int(ceil(seconds * float(Engine.physics_ticks_per_second))))
	await wait_physics_frames(ticks)


func find_descendants_by_class(parent: Node, target_class: String) -> Array[Node]:
	var matches: Array[Node] = []
	if parent == null:
		return matches
	for child in parent.get_children():
		if child.is_class(target_class):
			matches.append(child)
		matches.append_array(find_descendants_by_class(child, target_class))
	return matches


# ==============================================================================
# Assertion Helpers
# ==============================================================================

func pass_check(label: String) -> bool:
	_suite_passed += 1
	total_passed += 1
	print("  [PASS] %s" % label)
	return true


func fail(label: String, details: String = "") -> bool:
	_record_fail(label, details)
	return false


func _record_fail(label: String, details: String = "") -> void:
	_suite_failed += 1
	total_failed += 1
	var msg: String = label if details.is_empty() else "%s — %s" % [label, details]
	_suite_failures.append(msg)
	printerr("  [FAIL] %s" % msg)


func assert_true(condition: bool, label: String, details: String = "") -> bool:
	if condition:
		return pass_check(label)
	return fail(label, details if not details.is_empty() else "expected true, got false")


func assert_false(condition: bool, label: String, details: String = "") -> bool:
	if not condition:
		return pass_check(label)
	return fail(label, details if not details.is_empty() else "expected false, got true")


func assert_not_null(value: Variant, label: String) -> bool:
	if value != null:
		return pass_check(label)
	return fail(label, "expected non-null value, got null")


func assert_null(value: Variant, label: String) -> bool:
	if value == null:
		return pass_check(label)
	return fail(label, "expected null, got %s" % str(value))


func assert_has_method(obj: Object, method_name: String, label: String = "") -> bool:
	var desc: String = label if not label.is_empty() else "Object has method '%s'" % method_name
	if obj != null and obj.has_method(method_name):
		return pass_check(desc)
	return fail(desc, "missing method '%s' on %s" % [method_name, str(obj)])


func assert_eq(actual: Variant, expected: Variant, label: String) -> bool:
	if actual == expected:
		return pass_check(label)
	return fail(label, "expected %s, got %s" % [str(expected), str(actual)])


func assert_ne(actual: Variant, unexpected: Variant, label: String) -> bool:
	if actual != unexpected:
		return pass_check(label)
	return fail(label, "expected value != %s" % str(unexpected))


func assert_approx(actual: float, expected: float, tolerance: float, label: String) -> bool:
	var diff: float = absf(actual - expected)
	if diff <= tolerance:
		return pass_check("%s (actual=%.4f, expected=%.4f, tol=±%.4f)" % [label, actual, expected, tolerance])
	return fail(label, "actual=%.5f, expected=%.5f (diff=%.5f > tol=%.5f)" % [actual, expected, diff, tolerance])


func assert_gt(actual: float, threshold: float, label: String) -> bool:
	if actual > threshold:
		return pass_check("%s (%.4f > %.4f)" % [label, actual, threshold])
	return fail(label, "expected > %.5f, got %.5f" % [threshold, actual])


func assert_ge(actual: float, threshold: float, label: String) -> bool:
	if actual >= threshold:
		return pass_check("%s (%.4f >= %.4f)" % [label, actual, threshold])
	return fail(label, "expected >= %.5f, got %.5f" % [threshold, actual])


func assert_lt(actual: float, threshold: float, label: String) -> bool:
	if actual < threshold:
		return pass_check("%s (%.4f < %.4f)" % [label, actual, threshold])
	return fail(label, "expected < %.5f, got %.5f" % [threshold, actual])


func assert_le(actual: float, threshold: float, label: String) -> bool:
	if actual <= threshold:
		return pass_check("%s (%.4f <= %.4f)" % [label, actual, threshold])
	return fail(label, "expected <= %.5f, got %.5f" % [threshold, actual])
