class_name TouchControlsUI
extends CanvasLayer
## Phase 15+ iOS Local Offline Edition — Ergonomic Multi-Touch Controls Overlay.
## Handles independent multi-touch fingers simultaneously: Left Virtual Analog Stick
## (deadzone 0.12, outer 0.85 auto-sprint ring), Right-Half Camera Swipe Zone,
## Cyber-Anime Action Buttons (>= 64px) + Combo Skill Arc (Q/E/R) + Pulsing ZONE (V)
## + Safe-Area Pause button. Works on iOS touchscreens, PC testing ("on"), and --headless QA.

signal pause_pressed()

# Canonical PlayerInputFrame button bitmasks (ARCHITECTURE.md Section 5.2)
const BTN_SPRINT: int  = 1    # 1 << 0
const BTN_JUMP: int    = 2    # 1 << 1
const BTN_SHOOT: int   = 4    # 1 << 2
const BTN_PASS: int    = 8    # 1 << 3
const BTN_SKILL_Q: int = 16   # 1 << 4
const BTN_SKILL_E: int = 32   # 1 << 5
const BTN_SKILL_R: int = 64   # 1 << 6
const BTN_STEAL: int   = 128  # 1 << 7
const BTN_ZONE: int    = 256  # 1 << 8
const BTN_STANCE: int  = 512  # 1 << 9

const STICK_DEADZONE: float = 0.12
const STICK_SPRINT_THRESHOLD: float = 0.85
const STICK_MAX_RADIUS: float = 72.0

@export var camera_swipe_sensitivity: float = 1.0

var _ui_built: bool = false
var _override_enabled: Variant = null # null = auto from ConfigManager; bool = explicit override
var _enabled: bool = false
var _tracked_player_id: int = 1

# Live multi-touch finger state
var _stick_finger_id: int = -1
var _stick_origin: Vector2 = Vector2.ZERO
var _stick_local_vec: Vector2 = Vector2.ZERO
var _stick_auto_sprint: bool = false

var _camera_finger_id: int = -1
var _camera_last_pos: Vector2 = Vector2.ZERO
var _camera_delta_accum: Vector2 = Vector2.ZERO

var _button_fingers: Dictionary = {} # finger_idx: int -> btn_key: String
var _touch_buttons_mask: int = 0

# Programmatic QA simulation state
var _sim_active: bool = false
var _sim_stick_vec: Vector2 = Vector2.ZERO
var _sim_stick_sprint: bool = false
var _sim_buttons_mask: int = 0

# Zone ready pulse state
var _zone_ready: bool = false
var _zone_active: bool = false
var _pulse_time: float = 0.0

# UI nodes
var _touch_root: Control = null
var _stick_base: Panel = null
var _stick_sprint_ring: Panel = null
var _stick_knob: Panel = null
var _pause_btn: Button = null
var _last_touch_pause_frame: int = -1
var _action_buttons: Dictionary = {} # key: String -> {control: PanelContainer, label: Label, bit: int, base_style: StyleBoxFlat, pressed_style: StyleBoxFlat, accent: Color, size: Vector2}


func _enter_tree() -> void:
	_connect_event_bus()


func _ready() -> void:
	layer = 22
	add_to_group("touch_controls")
	_ensure_ui_built()
	_connect_event_bus()

	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null and gs.get("local_player_id") != null:
		_tracked_player_id = int(gs.get("local_player_id"))

	refresh_visibility_from_config()


func _exit_tree() -> void:
	_disconnect_event_bus()


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	_pulse_time += delta
	_animate_zone_button()


func _input(event: InputEvent) -> void:
	if not _enabled or _touch_root == null or not _touch_root.visible:
		return
	if get_tree() != null and get_tree().paused:
		return

	if event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event as InputEventScreenDrag)


# ==============================================================================
# Public API for PlayerController, CameraRig, SettingsMenu & QA
# ==============================================================================

func set_touch_enabled(enabled: bool) -> void:
	_ensure_ui_built()
	_override_enabled = enabled
	_apply_enabled_state(enabled)


func clear_touch_override() -> void:
	_override_enabled = null
	refresh_visibility_from_config()


func refresh_visibility_from_config() -> void:
	_ensure_ui_built()
	var should_show: bool = (
		bool(_override_enabled)
		if _override_enabled is bool
		else UIThemeBuilder.should_show_touch_controls()
	)
	_apply_enabled_state(should_show)
	UIThemeBuilder.apply_safe_area_margins(_touch_root, 0)


func is_touch_active() -> bool:
	return _enabled or _sim_active


func get_active_buttons_mask() -> int:
	var mask: int = _touch_buttons_mask | _sim_buttons_mask
	if _stick_auto_sprint or _sim_stick_sprint:
		mask |= BTN_SPRINT
	return mask


func get_touch_input_overlay() -> Dictionary:
	var move_vec: Vector2 = _sim_stick_vec if _sim_stick_vec.length_squared() > 1e-6 else _stick_local_vec
	return {
		"active": is_touch_active(),
		"move_local": move_vec,
		"buttons": get_active_buttons_mask(),
		"camera_delta": _camera_delta_accum,
	}


func consume_camera_delta() -> Vector2:
	var out: Vector2 = _camera_delta_accum
	_camera_delta_accum = Vector2.ZERO
	return out


func is_zone_button_ready_glowing() -> bool:
	return _zone_ready or _zone_active


func get_button_size(btn_key: String) -> Vector2:
	_ensure_ui_built()
	if btn_key == "pause" and _pause_btn != null:
		return _pause_btn.custom_minimum_size
	if _action_buttons.has(btn_key):
		return _action_buttons[btn_key]["size"] as Vector2
	return Vector2.ZERO


# ==============================================================================
# Programmatic QA Simulation Helpers
# ==============================================================================

func simulate_stick(local_vec: Vector2) -> void:
	_ensure_ui_built()
	_sim_active = true
	var mag: float = local_vec.length()
	if mag < STICK_DEADZONE:
		_sim_stick_vec = Vector2.ZERO
		_sim_stick_sprint = false
	else:
		var clamped_mag: float = minf(1.0, mag)
		var norm_dir: Vector2 = local_vec / mag if mag > 1e-6 else Vector2.ZERO
		var rescaled: float = clampf((clamped_mag - STICK_DEADZONE) / (1.0 - STICK_DEADZONE), 0.0, 1.0)
		_sim_stick_vec = norm_dir * rescaled
		_sim_stick_sprint = (clamped_mag >= STICK_SPRINT_THRESHOLD)
	_update_stick_knob_visual(_sim_stick_vec)


func simulate_button(btn_bit: int, pressed: bool) -> void:
	_ensure_ui_built()
	_sim_active = true
	if pressed:
		_sim_buttons_mask |= btn_bit
	else:
		_sim_buttons_mask &= (~btn_bit)
	_refresh_button_visuals()


func simulate_camera_drag(delta: Vector2) -> void:
	_ensure_ui_built()
	_sim_active = true
	_camera_delta_accum += delta * camera_swipe_sensitivity


func clear_simulated_inputs() -> void:
	_sim_active = false
	_sim_stick_vec = Vector2.ZERO
	_sim_stick_sprint = false
	_sim_buttons_mask = 0
	_camera_delta_accum = Vector2.ZERO
	_update_stick_knob_visual(_stick_local_vec)
	_refresh_button_visuals()


# ==============================================================================
# Multi-Touch Event Handling
# ==============================================================================

func _handle_screen_touch(ev: InputEventScreenTouch) -> void:
	var pos: Vector2 = ev.position
	if ev.pressed:
		# 1. Pause button check (top-right safe area)
		if _pause_btn != null and _pause_btn.get_global_rect().grow(8.0).has_point(pos):
			_last_touch_pause_frame = Engine.get_process_frames()
			pause_pressed.emit()
			if get_viewport() != null:
				get_viewport().set_input_as_handled()
			return

		# 2. Action buttons hit test
		var hit_key: String = _hit_test_action_button(pos)
		if not hit_key.is_empty():
			_button_fingers[ev.index] = hit_key
			_recompute_touch_buttons_mask()
			if get_viewport() != null:
				get_viewport().set_input_as_handled()
			return

		# 3. Left virtual analog stick capture
		var vp_size: Vector2 = _get_viewport_size()
		if _stick_finger_id == -1 and pos.x <= vp_size.x * 0.44 and pos.y >= vp_size.y * 0.28:
			_stick_finger_id = ev.index
			_stick_origin = _stick_base.get_global_rect().get_center() if _stick_base != null else pos
			_update_stick_from_screen_pos(pos)
			if get_viewport() != null:
				get_viewport().set_input_as_handled()
			return

		# 4. Right-half camera swipe zone capture
		if _camera_finger_id == -1 and pos.x > vp_size.x * 0.44:
			_camera_finger_id = ev.index
			_camera_last_pos = pos
			return
	else:
		# Finger released
		if ev.index == _stick_finger_id:
			_stick_finger_id = -1
			_stick_local_vec = Vector2.ZERO
			_stick_auto_sprint = false
			_update_stick_knob_visual(Vector2.ZERO)
		elif ev.index == _camera_finger_id:
			_camera_finger_id = -1
		elif _button_fingers.has(ev.index):
			_button_fingers.erase(ev.index)
			_recompute_touch_buttons_mask()


func _handle_screen_drag(ev: InputEventScreenDrag) -> void:
	if ev.index == _stick_finger_id:
		_update_stick_from_screen_pos(ev.position)
		if get_viewport() != null:
			get_viewport().set_input_as_handled()
	elif ev.index == _camera_finger_id:
		var delta: Vector2 = ev.position - _camera_last_pos
		_camera_last_pos = ev.position
		_camera_delta_accum += delta * camera_swipe_sensitivity
		if get_viewport() != null:
			get_viewport().set_input_as_handled()


func _update_stick_from_screen_pos(screen_pos: Vector2) -> void:
	var raw_offset: Vector2 = screen_pos - _stick_origin
	var dist: float = raw_offset.length()
	var norm_mag: float = clampf(dist / STICK_MAX_RADIUS, 0.0, 1.0)
	if norm_mag < STICK_DEADZONE:
		_stick_local_vec = Vector2.ZERO
		_stick_auto_sprint = false
	else:
		var dir: Vector2 = raw_offset / dist if dist > 1e-5 else Vector2.ZERO
		var rescaled: float = clampf((norm_mag - STICK_DEADZONE) / (1.0 - STICK_DEADZONE), 0.0, 1.0)
		# Screen +X = right (+x), Screen -Y (up) = forward (+y)!
		_stick_local_vec = Vector2(dir.x * rescaled, -dir.y * rescaled)
		_stick_auto_sprint = (norm_mag >= STICK_SPRINT_THRESHOLD)
	_update_stick_knob_visual(_stick_local_vec)


func _hit_test_action_button(pos: Vector2) -> String:
	for key in _action_buttons.keys():
		var ctrl: Control = _action_buttons[key]["control"] as Control
		if ctrl != null and ctrl.visible:
			if ctrl.get_global_rect().grow(6.0).has_point(pos):
				return key
	return ""


func _recompute_touch_buttons_mask() -> void:
	var mask: int = 0
	for key in _button_fingers.values():
		if _action_buttons.has(key):
			mask |= int(_action_buttons[key]["bit"])
	_touch_buttons_mask = mask
	_refresh_button_visuals()


func _apply_enabled_state(enabled: bool) -> void:
	_enabled = enabled
	if _touch_root != null:
		_touch_root.visible = enabled
	if not enabled:
		_stick_finger_id = -1
		_camera_finger_id = -1
		_button_fingers.clear()
		_stick_local_vec = Vector2.ZERO
		_stick_auto_sprint = false
		_touch_buttons_mask = 0
		_update_stick_knob_visual(Vector2.ZERO)
		_refresh_button_visuals()


func _update_stick_knob_visual(local_vec: Vector2) -> void:
	if _stick_base == null or _stick_knob == null:
		return
	var base_sz: Vector2 = _stick_base.size if _stick_base.size.x > 1.0 else Vector2(168.0, 168.0)
	var knob_sz: Vector2 = _stick_knob.size if _stick_knob.size.x > 1.0 else Vector2(64.0, 64.0)
	var center: Vector2 = base_sz * 0.5
	var screen_off := Vector2(local_vec.x, -local_vec.y) * (STICK_MAX_RADIUS * 0.78)
	_stick_knob.position = center - (knob_sz * 0.5) + screen_off


func _refresh_button_visuals() -> void:
	var active_mask: int = get_active_buttons_mask()
	for key in _action_buttons.keys():
		var entry: Dictionary = _action_buttons[key]
		var ctrl: PanelContainer = entry["control"] as PanelContainer
		var bit: int = int(entry["bit"])
		var is_down: bool = (active_mask & bit) != 0
		ctrl.add_theme_stylebox_override("panel", entry["pressed_style"] if is_down else entry["base_style"])


func _animate_zone_button() -> void:
	if not _action_buttons.has("zone"):
		return
	var entry: Dictionary = _action_buttons["zone"]
	var base_sb: StyleBoxFlat = entry["base_style"] as StyleBoxFlat
	var lbl: Label = entry["label"] as Label
	if _zone_ready or _zone_active:
		var p: float = 0.5 + 0.5 * sin(_pulse_time * 8.0)
		base_sb.border_color = UIThemeBuilder.COL_CYAN.lerp(UIThemeBuilder.COL_GOLD, p)
		base_sb.bg_color = Color(0.05, 0.28 + 0.16 * p, 0.36, 0.90)
		if lbl != null:
			lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD if p > 0.5 else Color.WHITE)
	else:
		base_sb.border_color = Color(0.24, 0.44, 0.58, 0.65)
		base_sb.bg_color = Color(0.05, 0.08, 0.15, 0.68)
		if lbl != null:
			lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)


func _get_viewport_size() -> Vector2:
	if is_inside_tree() and get_viewport() != null:
		var vr: Rect2 = get_viewport().get_visible_rect()
		if vr.size.x > 1.0 and vr.size.y > 1.0:
			return vr.size
	return Vector2(1280.0, 720.0)


# ==============================================================================
# EventBus Zone Telemetry
# ==============================================================================

func _connect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb != null:
		if eb.has_signal("zone_meter_updated") and not eb.is_connected("zone_meter_updated", _on_zone_meter_updated):
			eb.connect("zone_meter_updated", _on_zone_meter_updated)
		if eb.has_signal("zone_activated") and not eb.is_connected("zone_activated", _on_zone_activated):
			eb.connect("zone_activated", _on_zone_activated)
		if eb.has_signal("zone_ended") and not eb.is_connected("zone_ended", _on_zone_ended):
			eb.connect("zone_ended", _on_zone_ended)
	var cm: Node = UIThemeBuilder.get_autoload("ConfigManager")
	if cm != null and cm.has_signal("settings_changed") and not cm.is_connected("settings_changed", _on_config_setting_changed):
		cm.connect("settings_changed", _on_config_setting_changed)


func _disconnect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb != null:
		if eb.has_signal("zone_meter_updated") and eb.is_connected("zone_meter_updated", _on_zone_meter_updated):
			eb.disconnect("zone_meter_updated", _on_zone_meter_updated)
		if eb.has_signal("zone_activated") and eb.is_connected("zone_activated", _on_zone_activated):
			eb.disconnect("zone_activated", _on_zone_activated)
		if eb.has_signal("zone_ended") and eb.is_connected("zone_ended", _on_zone_ended):
			eb.disconnect("zone_ended", _on_zone_ended)
	var cm: Node = UIThemeBuilder.get_autoload("ConfigManager")
	if cm != null and cm.has_signal("settings_changed") and cm.is_connected("settings_changed", _on_config_setting_changed):
		cm.disconnect("settings_changed", _on_config_setting_changed)


func _on_config_setting_changed(section: String, key: String, _value: Variant) -> void:
	if section == "gameplay" and key == "touch_controls_mode":
		refresh_visibility_from_config()


func _on_zone_meter_updated(player_id: int, current: float, maximum: float) -> void:
	if player_id != _tracked_player_id:
		return
	var pct: float = (current / maxf(1.0, maximum)) * 100.0
	_zone_ready = (not _zone_active) and (pct >= 99.5)


func _on_zone_activated(player_id: int, _duration: float) -> void:
	if player_id != _tracked_player_id:
		return
	_zone_active = true
	_zone_ready = false


func _on_zone_ended(player_id: int) -> void:
	if player_id != _tracked_player_id:
		return
	_zone_active = false
	_zone_ready = false


# ==============================================================================
# Cyber-Anime Touch Layout Construction
# ==============================================================================

func _ensure_ui_built() -> void:
	if _ui_built:
		return
	_ui_built = true

	_touch_root = Control.new()
	_touch_root.name = "TouchRoot"
	_touch_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_touch_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_touch_root.theme = UIThemeBuilder.build_theme()
	_touch_root.visible = false
	add_child(_touch_root)

	# 1. Left Bottom: Virtual Analog Stick (168x168 base + 0.85 sprint ring + 64x64 knob)
	_stick_base = Panel.new()
	_stick_base.name = "VirtualStickBase"
	_stick_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick_base.anchor_top = 1.0
	_stick_base.anchor_bottom = 1.0
	_stick_base.offset_left = 44.0
	_stick_base.offset_top = -212.0
	_stick_base.offset_right = 212.0
	_stick_base.offset_bottom = -44.0
	var stick_sb := StyleBoxFlat.new()
	stick_sb.bg_color = Color(0.05, 0.09, 0.17, 0.56)
	stick_sb.border_color = Color(0.0, 0.94, 1.0, 0.72)
	stick_sb.set_border_width_all(3)
	stick_sb.set_corner_radius_all(84)
	_stick_base.add_theme_stylebox_override("panel", stick_sb)
	_touch_root.add_child(_stick_base)

	_stick_sprint_ring = Panel.new()
	_stick_sprint_ring.name = "SprintRing"
	_stick_sprint_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick_sprint_ring.position = Vector2(12.0, 12.0)
	_stick_sprint_ring.size = Vector2(144.0, 144.0)
	var ring_sb := StyleBoxFlat.new()
	ring_sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	ring_sb.border_color = Color(1.0, 0.82, 0.40, 0.35)
	ring_sb.set_border_width_all(2)
	ring_sb.set_corner_radius_all(72)
	_stick_sprint_ring.add_theme_stylebox_override("panel", ring_sb)
	_stick_base.add_child(_stick_sprint_ring)

	_stick_knob = Panel.new()
	_stick_knob.name = "VirtualStickKnob"
	_stick_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stick_knob.size = Vector2(64.0, 64.0)
	_stick_knob.position = Vector2(52.0, 52.0)
	var knob_sb := StyleBoxFlat.new()
	knob_sb.bg_color = Color(0.0, 0.94, 1.0, 0.78)
	knob_sb.border_color = Color.WHITE
	knob_sb.set_border_width_all(2)
	knob_sb.set_corner_radius_all(32)
	_stick_knob.add_theme_stylebox_override("panel", knob_sb)
	_stick_base.add_child(_stick_knob)

	# 2. Top-Right Safe Area Pause Button (64x64)
	_pause_btn = Button.new()
	_pause_btn.name = "PauseTouchButton"
	_pause_btn.text = "| |"
	_pause_btn.anchor_left = 1.0
	_pause_btn.anchor_right = 1.0
	_pause_btn.offset_left = -84.0
	_pause_btn.offset_right = -20.0
	_pause_btn.offset_top = 18.0
	_pause_btn.offset_bottom = 82.0
	_pause_btn.custom_minimum_size = Vector2(64.0, 64.0)
	_pause_btn.add_theme_font_size_override("font_size", 20)
	UIThemeBuilder.apply_primary_cta_button(_pause_btn, UIThemeBuilder.COL_SLATE)
	_pause_btn.pressed.connect(func() -> void:
		if Engine.get_process_frames() == _last_touch_pause_frame:
			return
		pause_pressed.emit()
	)
	_touch_root.add_child(_pause_btn)

	# 3. Right Thumb Ergonomic Action Cluster + Combo Skill Arc (all >= 64px!)
	# Primary actions
	_add_touch_button("shoot",  "SHOOT\n/ BLK", BTN_SHOOT,   Vector2(-112.0, -112.0), Vector2(86.0, 86.0), UIThemeBuilder.COL_CRIMSON)
	_add_touch_button("pass",   "PASS",        BTN_PASS,    Vector2(-206.0, -96.0),  Vector2(74.0, 74.0), UIThemeBuilder.COL_CYAN)
	_add_touch_button("jump",   "JUMP",        BTN_JUMP,    Vector2(-118.0, -206.0), Vector2(72.0, 72.0), UIThemeBuilder.COL_EMERALD)
	_add_touch_button("sprint", "SPRINT",      BTN_SPRINT,  Vector2(-294.0, -94.0),  Vector2(68.0, 68.0), UIThemeBuilder.COL_CYAN)
	_add_touch_button("steal",  "STEAL",       BTN_STEAL,   Vector2(-204.0, -184.0), Vector2(66.0, 66.0), UIThemeBuilder.COL_GOLD)
	_add_touch_button("stance", "STANCE",      BTN_STANCE,  Vector2(-286.0, -176.0), Vector2(66.0, 66.0), UIThemeBuilder.COL_SLATE)

	# Combo Skill Arc (Q, E, R) cleanly curved above primary cluster
	_add_touch_button("skill_q", "Q",          BTN_SKILL_Q, Vector2(-340.0, -264.0), Vector2(64.0, 64.0), UIThemeBuilder.COL_CYAN)
	_add_touch_button("skill_e", "E",          BTN_SKILL_E, Vector2(-264.0, -296.0), Vector2(64.0, 64.0), UIThemeBuilder.COL_CYAN)
	_add_touch_button("skill_r", "R",          BTN_SKILL_R, Vector2(-186.0, -296.0), Vector2(64.0, 64.0), UIThemeBuilder.COL_GOLD)

	# ZONE Awaken (V)
	_add_touch_button("zone",    "ZONE\n[V]",  BTN_ZONE,    Vector2(-106.0, -296.0), Vector2(72.0, 72.0), UIThemeBuilder.COL_GOLD)

	UIThemeBuilder.apply_safe_area_margins(_touch_root, 0)


func _add_touch_button(
	key: String,
	text: String,
	bit: int,
	bottom_right_offset: Vector2,
	sz: Vector2,
	accent: Color
) -> void:
	var panel := PanelContainer.new()
	panel.name = "TouchBtn_%s" % key
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = bottom_right_offset.x
	panel.offset_top = bottom_right_offset.y
	panel.offset_right = bottom_right_offset.x + sz.x
	panel.offset_bottom = bottom_right_offset.y + sz.y
	panel.custom_minimum_size = sz

	var radius: int = int(minf(sz.x, sz.y) * 0.5)
	var base_sb := StyleBoxFlat.new()
	base_sb.bg_color = Color(accent.r * 0.14, accent.g * 0.16, accent.b * 0.22, 0.72)
	base_sb.border_color = Color(accent.r, accent.g, accent.b, 0.88)
	base_sb.set_border_width_all(2)
	base_sb.set_corner_radius_all(radius)

	var pressed_sb := StyleBoxFlat.new()
	pressed_sb.bg_color = Color(accent.r * 0.55, accent.g * 0.58, accent.b * 0.65, 0.95)
	pressed_sb.border_color = Color.WHITE
	pressed_sb.set_border_width_all(3)
	pressed_sb.set_corner_radius_all(radius)

	panel.add_theme_stylebox_override("panel", base_sb)
	_touch_root.add_child(panel)

	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", 14 if text.length() <= 4 else 12)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	panel.add_child(lbl)

	_action_buttons[key] = {
		"control": panel,
		"label": lbl,
		"bit": bit,
		"base_style": base_sb,
		"pressed_style": pressed_sb,
		"accent": accent,
		"size": sz,
	}
