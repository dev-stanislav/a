class_name SettingsMenuUI
extends Control
## Phase 14 — Comprehensive Settings Menu bound directly to ConfigManager & SoundManager.
## Supports Graphics, live Audio bus sliders, Gameplay camera/sensitivity, Server defaults,
## Controls Reference, Save / Reset Defaults, and works standalone or embedded in PauseMenu.

signal navigate_requested(route: String, params: Dictionary)
signal back_requested()
signal settings_saved()

const QUALITY_OPTIONS: Array[String] = ["low", "medium", "high"]
const TOUCH_MODE_OPTIONS: Array[String] = ["auto", "on", "off"]

@export var embedded_mode: bool = false

var _ui_built: bool = false
var _loading_values: bool = false

var _fullscreen_cb: CheckBox = null
var _vsync_cb: CheckBox = null
var _shadows_cb: CheckBox = null
var _quality_opt: OptionButton = null

var _master_slider: HSlider = null
var _sfx_slider: HSlider = null
var _music_slider: HSlider = null
var _ambience_slider: HSlider = null
var _master_val_lbl: Label = null
var _sfx_val_lbl: Label = null
var _music_val_lbl: Label = null
var _ambience_val_lbl: Label = null

var _sens_slider: HSlider = null
var _fov_slider: HSlider = null
var _shake_slider: HSlider = null
var _touch_mode_opt: OptionButton = null
var _sens_val_lbl: Label = null
var _fov_val_lbl: Label = null
var _shake_val_lbl: Label = null

var _host_edit: LineEdit = null
var _udp_port_spin: SpinBox = null
var _http_port_spin: SpinBox = null
var _status_label: Label = null
var _save_btn: Button = null
var _reset_btn: Button = null
var _back_btn: Button = null


func _ready() -> void:
	_ensure_ui_built()
	load_from_config()


func load_from_config() -> void:
	_ensure_ui_built()
	_loading_values = true
	var cm: Node = UIThemeBuilder.get_autoload("ConfigManager")

	var fullscreen: bool = false
	var vsync: bool = true
	var shadows: bool = true
	var quality: String = "high"
	var master_v: float = 0.85
	var sfx_v: float = 0.90
	var music_v: float = 0.70
	var amb_v: float = 0.65
	var sens: float = 0.0028
	var fov: float = 72.0
	var shake: float = 1.0
	var touch_mode: String = "auto"
	var host: String = "127.0.0.1"
	var udp_p: int = 7777
	var http_p: int = 8080

	if cm != null and cm.has_method("get_setting"):
		fullscreen = bool(cm.call("get_setting", "graphics", "fullscreen", false))
		vsync = bool(cm.call("get_setting", "graphics", "vsync", true))
		shadows = bool(cm.call("get_setting", "graphics", "shadows_enabled", true))
		quality = str(cm.call("get_setting", "graphics", "quality", "high")).to_lower()
		master_v = float(cm.call("get_setting", "audio", "master_volume", 0.85))
		sfx_v = float(cm.call("get_setting", "audio", "sfx_volume", 0.90))
		music_v = float(cm.call("get_setting", "audio", "music_volume", 0.70))
		amb_v = float(cm.call("get_setting", "audio", "ambience_volume", 0.65))
		sens = float(cm.call("get_setting", "gameplay", "mouse_sensitivity", 0.0028))
		fov = float(cm.call("get_setting", "gameplay", "camera_fov", 72.0))
		shake = float(cm.call("get_setting", "gameplay", "camera_shake_scale", 1.0))
		touch_mode = str(cm.call("get_setting", "gameplay", "touch_controls_mode", "auto")).to_lower()
		host = str(cm.call("get_setting", "network", "default_host", "127.0.0.1"))
		udp_p = int(cm.call("get_setting", "network", "default_udp_port", 7777))
		http_p = int(cm.call("get_setting", "network", "default_http_port", 8080))

	_fullscreen_cb.button_pressed = fullscreen
	_vsync_cb.button_pressed = vsync
	_shadows_cb.button_pressed = shadows
	var q_idx: int = QUALITY_OPTIONS.find(quality)
	_quality_opt.select(q_idx if q_idx >= 0 else 2)

	_master_slider.value = clampf(master_v, 0.0, 1.0)
	_sfx_slider.value = clampf(sfx_v, 0.0, 1.0)
	_music_slider.value = clampf(music_v, 0.0, 1.0)
	_ambience_slider.value = clampf(amb_v, 0.0, 1.0)

	_sens_slider.value = clampf(sens, 0.0005, 0.010)
	_fov_slider.value = clampf(fov, 60.0, 95.0)
	_shake_slider.value = clampf(shake, 0.0, 2.0)
	var tm_idx: int = TOUCH_MODE_OPTIONS.find(touch_mode)
	if _touch_mode_opt != null:
		_touch_mode_opt.select(tm_idx if tm_idx >= 0 else 0)

	_host_edit.text = host
	_udp_port_spin.value = clampi(udp_p, 1, 65535)
	_http_port_spin.value = clampi(http_p, 1, 65535)

	_loading_values = false
	_refresh_value_labels()


func get_selected_touch_controls_mode() -> String:
	_ensure_ui_built()
	if _touch_mode_opt == null:
		return "auto"
	return TOUCH_MODE_OPTIONS[clampi(_touch_mode_opt.selected, 0, TOUCH_MODE_OPTIONS.size() - 1)]


func save_settings_to_config(persist: bool = true) -> void:
	_ensure_ui_built()
	var cm: Node = UIThemeBuilder.get_autoload("ConfigManager")
	var q_str: String = QUALITY_OPTIONS[clampi(_quality_opt.selected, 0, QUALITY_OPTIONS.size() - 1)]
	var touch_str: String = get_selected_touch_controls_mode()
	var host_val: String = _host_edit.text.strip_edges()
	if host_val.is_empty():
		host_val = "127.0.0.1"

	if cm != null and cm.has_method("set_setting"):
		cm.call("set_setting", "graphics", "fullscreen", _fullscreen_cb.button_pressed, false)
		cm.call("set_setting", "graphics", "vsync", _vsync_cb.button_pressed, false)
		cm.call("set_setting", "graphics", "shadows_enabled", _shadows_cb.button_pressed, false)
		cm.call("set_setting", "graphics", "quality", q_str, false)

		cm.call("set_setting", "audio", "master_volume", _master_slider.value, false)
		cm.call("set_setting", "audio", "sfx_volume", _sfx_slider.value, false)
		cm.call("set_setting", "audio", "music_volume", _music_slider.value, false)
		cm.call("set_setting", "audio", "ambience_volume", _ambience_slider.value, false)

		cm.call("set_setting", "gameplay", "mouse_sensitivity", _sens_slider.value, false)
		cm.call("set_setting", "gameplay", "camera_fov", _fov_slider.value, false)
		cm.call("set_setting", "gameplay", "camera_shake_scale", _shake_slider.value, false)
		cm.call("set_setting", "gameplay", "touch_controls_mode", touch_str, false)

		cm.call("set_setting", "network", "default_host", host_val, false)
		cm.call("set_setting", "network", "default_udp_port", int(_udp_port_spin.value), false)
		cm.call("set_setting", "network", "default_http_port", int(_http_port_spin.value), false)
		if persist and cm.has_method("save_settings"):
			cm.call("save_settings")

	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null:
		gs.set("server_host", host_val)
		gs.set("server_udp_port", int(_udp_port_spin.value))
		gs.set("server_http_port", int(_http_port_spin.value))

	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc != null:
		nc.set("host", host_val)
		nc.set("udp_port", int(_udp_port_spin.value))
		nc.set("http_port", int(_http_port_spin.value))

	_apply_live_audio_volumes()
	_notify_touch_controls_changed()
	if _status_label != null:
		_status_label.text = "Settings saved cleanly."
		_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD)
	settings_saved.emit()


func reset_defaults(persist: bool = false) -> void:
	_ensure_ui_built()
	_loading_values = true
	_fullscreen_cb.button_pressed = false
	_vsync_cb.button_pressed = true
	_shadows_cb.button_pressed = true
	_quality_opt.select(2)
	_master_slider.value = 0.85
	_sfx_slider.value = 0.90
	_music_slider.value = 0.70
	_ambience_slider.value = 0.65
	_sens_slider.value = 0.0028
	_fov_slider.value = 72.0
	_shake_slider.value = 1.0
	if _touch_mode_opt != null:
		_touch_mode_opt.select(0)
	_host_edit.text = "127.0.0.1"
	_udp_port_spin.value = 7777
	_http_port_spin.value = 8080
	_loading_values = false
	_refresh_value_labels()
	save_settings_to_config(persist)
	if _status_label != null:
		_status_label.text = "Default settings restored."
		_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)


func _on_touch_mode_selected(_index: int) -> void:
	if _loading_values:
		return
	var cm: Node = UIThemeBuilder.get_autoload("ConfigManager")
	if cm != null and cm.has_method("set_setting"):
		cm.call("set_setting", "gameplay", "touch_controls_mode", get_selected_touch_controls_mode(), false)
	_notify_touch_controls_changed()


func _notify_touch_controls_changed() -> void:
	if is_inside_tree() and get_tree() != null:
		get_tree().call_group("touch_controls", "refresh_visibility_from_config")


func _on_audio_slider_changed(_val: float) -> void:
	if _loading_values:
		return
	_refresh_value_labels()
	_apply_live_audio_volumes()


func _on_gameplay_slider_changed(_val: float) -> void:
	if _loading_values:
		return
	_refresh_value_labels()


func _apply_live_audio_volumes() -> void:
	var sm: Node = null
	if is_inside_tree() and get_tree() != null:
		sm = get_tree().get_first_node_in_group("sound_manager")
	if sm != null and sm.has_method("set_bus_volume_linear"):
		sm.call("set_bus_volume_linear", "Master", _master_slider.value)
		sm.call("set_bus_volume_linear", "SFX", _sfx_slider.value)
		sm.call("set_bus_volume_linear", "Music", _music_slider.value)
		sm.call("set_bus_volume_linear", "Ambience", _ambience_slider.value)
	else:
		_set_bus_direct("Master", _master_slider.value)
		_set_bus_direct("SFX", _sfx_slider.value)
		_set_bus_direct("Music", _music_slider.value)
		_set_bus_direct("Ambience", _ambience_slider.value)


func _set_bus_direct(bus_name: String, lin: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	if lin <= 0.0001:
		AudioServer.set_bus_volume_db(idx, -80.0)
		AudioServer.set_bus_mute(idx, true)
	else:
		AudioServer.set_bus_mute(idx, false)
		AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(lin, 0.0001, 1.5)))


func _refresh_value_labels() -> void:
	if _master_val_lbl != null:
		_master_val_lbl.text = "%d%%" % int(round(_master_slider.value * 100.0))
	if _sfx_val_lbl != null:
		_sfx_val_lbl.text = "%d%%" % int(round(_sfx_slider.value * 100.0))
	if _music_val_lbl != null:
		_music_val_lbl.text = "%d%%" % int(round(_music_slider.value * 100.0))
	if _ambience_val_lbl != null:
		_ambience_val_lbl.text = "%d%%" % int(round(_ambience_slider.value * 100.0))
	if _sens_val_lbl != null:
		_sens_val_lbl.text = "%.4f" % _sens_slider.value
	if _fov_val_lbl != null:
		_fov_val_lbl.text = "%.0f°" % _fov_slider.value
	if _shake_val_lbl != null:
		_shake_val_lbl.text = "%.2fx" % _shake_slider.value


func _on_back_pressed() -> void:
	back_requested.emit()
	if not embedded_mode:
		UIThemeBuilder.route_navigate(self, "main_menu")


func _ensure_ui_built() -> void:
	if _ui_built:
		return
	_ui_built = true

	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UIThemeBuilder.build_theme()

	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.043, 0.055, 0.090, 0.96)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 44)
	margin.add_theme_constant_override("margin_right", 44)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 26)
	add_child(margin)
	UIThemeBuilder.apply_safe_area_margins(margin, 26)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	margin.add_child(vbox)

	# Header
	var hdr := Label.new()
	hdr.name = "SettingsTitle"
	hdr.text = "SETTINGS // GRAPHICS, AUDIO, GAMEPLAY & NETWORK"
	hdr.add_theme_font_size_override("font_size", 26)
	hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	vbox.add_child(hdr)

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 18)
	vbox.add_child(cols)

	# Left Column: Graphics + Audio
	var left_panel := PanelContainer.new()
	left_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(left_panel)
	var left_vb := VBoxContainer.new()
	left_vb.add_theme_constant_override("separation", 10)
	left_panel.add_child(left_vb)

	_add_section_header(left_vb, "GRAPHICS")
	_fullscreen_cb = CheckBox.new()
	_fullscreen_cb.name = "FullscreenCheck"
	_fullscreen_cb.text = "Fullscreen Window"
	left_vb.add_child(_fullscreen_cb)

	_vsync_cb = CheckBox.new()
	_vsync_cb.name = "VSyncCheck"
	_vsync_cb.text = "VSync Enabled"
	left_vb.add_child(_vsync_cb)

	_shadows_cb = CheckBox.new()
	_shadows_cb.name = "ShadowsCheck"
	_shadows_cb.text = "Dynamic Arena Shadows"
	left_vb.add_child(_shadows_cb)

	var q_row := HBoxContainer.new()
	left_vb.add_child(q_row)
	var q_lbl := Label.new()
	q_lbl.text = "Graphics Quality"
	q_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	q_row.add_child(q_lbl)
	_quality_opt = OptionButton.new()
	_quality_opt.name = "QualityOption"
	_quality_opt.add_item("Low", 0)
	_quality_opt.add_item("Medium", 1)
	_quality_opt.add_item("High", 2)
	q_row.add_child(_quality_opt)

	_add_section_header(left_vb, "AUDIO MIXER (LIVE)")
	var m_pair: Array = _add_slider_row(left_vb, "MasterSlider", "Master Volume", 0.0, 1.0, 0.01)
	_master_slider = m_pair[0]
	_master_val_lbl = m_pair[1]
	_master_slider.value_changed.connect(_on_audio_slider_changed)

	var s_pair: Array = _add_slider_row(left_vb, "SfxSlider", "SFX Volume", 0.0, 1.0, 0.01)
	_sfx_slider = s_pair[0]
	_sfx_val_lbl = s_pair[1]
	_sfx_slider.value_changed.connect(_on_audio_slider_changed)

	var mu_pair: Array = _add_slider_row(left_vb, "MusicSlider", "Music Volume", 0.0, 1.0, 0.01)
	_music_slider = mu_pair[0]
	_music_val_lbl = mu_pair[1]
	_music_slider.value_changed.connect(_on_audio_slider_changed)

	var am_pair: Array = _add_slider_row(left_vb, "AmbienceSlider", "Crowd Ambience", 0.0, 1.0, 0.01)
	_ambience_slider = am_pair[0]
	_ambience_val_lbl = am_pair[1]
	_ambience_slider.value_changed.connect(_on_audio_slider_changed)

	# Right Column: Gameplay + Network + Controls Reference
	var right_panel := PanelContainer.new()
	right_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right_panel)
	var right_vb := VBoxContainer.new()
	right_vb.add_theme_constant_override("separation", 10)
	right_panel.add_child(right_vb)

	_add_section_header(right_vb, "GAMEPLAY & CAMERA")
	var se_pair: Array = _add_slider_row(right_vb, "SensitivitySlider", "Mouse Sensitivity", 0.0005, 0.010, 0.0001)
	_sens_slider = se_pair[0]
	_sens_val_lbl = se_pair[1]
	_sens_slider.value_changed.connect(_on_gameplay_slider_changed)

	var fv_pair: Array = _add_slider_row(right_vb, "FovSlider", "Base Camera FOV", 60.0, 95.0, 1.0)
	_fov_slider = fv_pair[0]
	_fov_val_lbl = fv_pair[1]
	_fov_slider.value_changed.connect(_on_gameplay_slider_changed)

	var sh_pair: Array = _add_slider_row(right_vb, "ShakeSlider", "Camera Shake Scale", 0.0, 2.0, 0.05)
	_shake_slider = sh_pair[0]
	_shake_val_lbl = sh_pair[1]
	_shake_slider.value_changed.connect(_on_gameplay_slider_changed)

	var tm_row := HBoxContainer.new()
	right_vb.add_child(tm_row)
	var tm_lbl := Label.new()
	tm_lbl.text = "Touch Controls"
	tm_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tm_row.add_child(tm_lbl)
	_touch_mode_opt = OptionButton.new()
	_touch_mode_opt.name = "TouchControlsOption"
	_touch_mode_opt.add_item("Auto (Mobile/iOS)", 0)
	_touch_mode_opt.add_item("On (Always Show)", 1)
	_touch_mode_opt.add_item("Off (Hidden)", 2)
	_touch_mode_opt.item_selected.connect(_on_touch_mode_selected)
	tm_row.add_child(_touch_mode_opt)

	_add_section_header(right_vb, "DEDICATED SERVER DEFAULTS")
	var host_row := HBoxContainer.new()
	right_vb.add_child(host_row)
	var h_lbl := Label.new()
	h_lbl.text = "Server Host"
	h_lbl.custom_minimum_size = Vector2(130.0, 0.0)
	host_row.add_child(h_lbl)
	_host_edit = LineEdit.new()
	_host_edit.name = "ServerHostEdit"
	_host_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_row.add_child(_host_edit)

	var ports_row := HBoxContainer.new()
	ports_row.add_theme_constant_override("separation", 12)
	right_vb.add_child(ports_row)
	var udp_lbl := Label.new()
	udp_lbl.text = "UDP Port"
	ports_row.add_child(udp_lbl)
	_udp_port_spin = SpinBox.new()
	_udp_port_spin.name = "UdpPortSpin"
	_udp_port_spin.min_value = 1
	_udp_port_spin.max_value = 65535
	ports_row.add_child(_udp_port_spin)

	var http_lbl := Label.new()
	http_lbl.text = "HTTP Port"
	ports_row.add_child(http_lbl)
	_http_port_spin = SpinBox.new()
	_http_port_spin.name = "HttpPortSpin"
	_http_port_spin.min_value = 1
	_http_port_spin.max_value = 65535
	ports_row.add_child(_http_port_spin)

	_add_section_header(right_vb, "CONTROLS REFERENCE")
	var ctrl_ref := Label.new()
	ctrl_ref.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ctrl_ref.add_theme_font_size_override("font_size", 12)
	ctrl_ref.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	ctrl_ref.text = (
		"Move: WASD   |   Sprint: Shift   |   Jump / Block: Space\n"
		+ "Shoot / Dunk: LMB or J   |   Pass / Lock-On: RMB or K\n"
		+ "Dribble & Combo Inputs: Q, E, R   |   Steal: F   |   Stance: C\n"
		+ "THE ZONE Awakening: V   |   Pause: Escape"
	)
	right_vb.add_child(ctrl_ref)

	# Bottom Actions Row
	var foot_row := HBoxContainer.new()
	foot_row.add_theme_constant_override("separation", 12)
	vbox.add_child(foot_row)

	_status_label = Label.new()
	_status_label.name = "SettingsStatusLabel"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.text = ""
	foot_row.add_child(_status_label)

	_reset_btn = Button.new()
	_reset_btn.name = "ResetDefaultsButton"
	_reset_btn.text = "RESET DEFAULTS"
	_reset_btn.pressed.connect(func() -> void: reset_defaults(true))
	foot_row.add_child(_reset_btn)

	_save_btn = Button.new()
	_save_btn.name = "SaveButton"
	_save_btn.text = "SAVE SETTINGS"
	UIThemeBuilder.apply_primary_cta_button(_save_btn, UIThemeBuilder.COL_EMERALD)
	_save_btn.pressed.connect(func() -> void: save_settings_to_config(true))
	foot_row.add_child(_save_btn)

	_back_btn = Button.new()
	_back_btn.name = "BackButton"
	_back_btn.text = "BACK"
	UIThemeBuilder.apply_primary_cta_button(_back_btn, UIThemeBuilder.COL_CYAN)
	_back_btn.pressed.connect(_on_back_pressed)
	foot_row.add_child(_back_btn)


func _add_section_header(parent: VBoxContainer, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	parent.add_child(lbl)


func _add_slider_row(parent: VBoxContainer, slider_name: String, label_text: String, min_v: float, max_v: float, step_v: float) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(150.0, 0.0)
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.name = slider_name
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step_v
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size = Vector2(64.0, 0.0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	row.add_child(val_lbl)

	return [slider, val_lbl]
