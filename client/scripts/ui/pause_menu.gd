class_name PauseMenuUI
extends CanvasLayer
## Phase 14 — In-Match Pause Menu Overlay (`Escape` / `pause` action).
## Pauses SceneTree ONLY in offline matches (never freezes tree during online matches!),
## disables/hides Restart online, and embeds SettingsMenuUI cleanly when requested.

signal navigate_requested(route: String, params: Dictionary)
signal resumed()
signal restart_requested()

const SETTINGS_SCENE_PATH := "res://scenes/ui/settings_menu.tscn"

var _ui_built: bool = false
var _is_open: bool = false
var _paused_tree: bool = false

var _root_overlay: Control = null
var _menu_card: PanelContainer = null
var _online_notice_label: Label = null
var _resume_btn: Button = null
var _restart_btn: Button = null
var _settings_btn: Button = null
var _main_menu_btn: Button = null
var _embedded_settings: Control = null


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("pause_menu")
	_ensure_ui_built()
	close_pause()


func _exit_tree() -> void:
	if _paused_tree and get_tree() != null:
		get_tree().paused = false
		_paused_tree = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		toggle_pause()
		if get_viewport() != null:
			get_viewport().set_input_as_handled()


func is_pause_open() -> bool:
	return _is_open


func is_restart_enabled() -> bool:
	_ensure_ui_built()
	return _restart_btn != null and _restart_btn.visible and not _restart_btn.disabled


func toggle_pause() -> void:
	if _is_open:
		close_pause()
	else:
		open_pause()


func open_pause() -> void:
	_ensure_ui_built()
	_is_open = true
	_root_overlay.visible = true
	_menu_card.visible = true
	_close_embedded_settings()

	var online: bool = _is_online_match()
	_restart_btn.visible = not online
	_restart_btn.disabled = online
	_online_notice_label.visible = online

	if not online and get_tree() != null:
		get_tree().paused = true
		_paused_tree = true
	else:
		_paused_tree = false

	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func close_pause() -> void:
	_ensure_ui_built()
	_is_open = false
	_close_embedded_settings()
	_root_overlay.visible = false
	if _paused_tree and get_tree() != null:
		get_tree().paused = false
		_paused_tree = false
	resumed.emit()


func _on_restart_pressed() -> void:
	if _is_online_match():
		return
	close_pause()
	restart_requested.emit()
	if is_inside_tree() and get_tree() != null:
		var mc: Node = get_tree().get_first_node_in_group("match_controller")
		if mc != null and mc.has_method("restart_match"):
			mc.call("restart_match")


func _on_settings_pressed() -> void:
	_ensure_ui_built()
	if _embedded_settings != null and is_instance_valid(_embedded_settings):
		return
	if ResourceLoader.exists(SETTINGS_SCENE_PATH):
		var packed := load(SETTINGS_SCENE_PATH) as PackedScene
		if packed != null:
			var inst := packed.instantiate() as Control
			if inst != null:
				inst.set("embedded_mode", true)
				if inst.has_signal("back_requested"):
					inst.connect("back_requested", _close_embedded_settings)
				_embedded_settings = inst
				_menu_card.visible = false
				_root_overlay.add_child(_embedded_settings)


func _close_embedded_settings() -> void:
	if _embedded_settings != null and is_instance_valid(_embedded_settings):
		_embedded_settings.get_parent().remove_child(_embedded_settings)
		_embedded_settings.free()
	_embedded_settings = null
	if _menu_card != null:
		_menu_card.visible = true


func _on_main_menu_pressed() -> void:
	close_pause()
	if _is_online_match():
		var nc: Node = UIThemeBuilder.get_autoload("NetClient")
		if nc != null and nc.has_method("disconnect_from_server"):
			nc.call("disconnect_from_server", "return_to_menu")
	UIThemeBuilder.route_navigate(self, "main_menu")


func _is_online_match() -> bool:
	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null and bool(gs.get("is_online")):
		return true
	return false


func _ensure_ui_built() -> void:
	if _ui_built:
		return
	_ui_built = true

	_root_overlay = Control.new()
	_root_overlay.name = "PauseOverlayRoot"
	_root_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_overlay.theme = UIThemeBuilder.build_theme()
	_root_overlay.visible = false
	add_child(_root_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.03, 0.04, 0.08, 0.72)
	_root_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_overlay.add_child(center)
	UIThemeBuilder.apply_safe_area_margins(center, 16)

	_menu_card = PanelContainer.new()
	_menu_card.name = "PauseMenuCard"
	_menu_card.custom_minimum_size = Vector2(360.0, 0.0)
	_menu_card.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL, UIThemeBuilder.COL_CYAN, 2, 10, 24.0, 22.0))
	center.add_child(_menu_card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	_menu_card.add_child(vb)

	var title := Label.new()
	title.text = "MATCH PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	vb.add_child(title)

	_online_notice_label = Label.new()
	_online_notice_label.text = "ONLINE MATCH ACTIVE — Simulation continues in real time."
	_online_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_online_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_online_notice_label.add_theme_font_size_override("font_size", 12)
	_online_notice_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	_online_notice_label.visible = false
	vb.add_child(_online_notice_label)

	_resume_btn = Button.new()
	_resume_btn.name = "ResumeButton"
	_resume_btn.text = "RESUME MATCH"
	_resume_btn.custom_minimum_size = Vector2(0.0, 44.0)
	UIThemeBuilder.apply_primary_cta_button(_resume_btn, UIThemeBuilder.COL_EMERALD)
	_resume_btn.pressed.connect(close_pause)
	vb.add_child(_resume_btn)

	_restart_btn = Button.new()
	_restart_btn.name = "RestartMatchButton"
	_restart_btn.text = "RESTART MATCH"
	_restart_btn.custom_minimum_size = Vector2(0.0, 42.0)
	_restart_btn.pressed.connect(_on_restart_pressed)
	vb.add_child(_restart_btn)

	_settings_btn = Button.new()
	_settings_btn.name = "SettingsButton"
	_settings_btn.text = "SETTINGS"
	_settings_btn.custom_minimum_size = Vector2(0.0, 42.0)
	_settings_btn.pressed.connect(_on_settings_pressed)
	vb.add_child(_settings_btn)

	_main_menu_btn = Button.new()
	_main_menu_btn.name = "ReturnMainMenuButton"
	_main_menu_btn.text = "RETURN TO MAIN MENU"
	_main_menu_btn.custom_minimum_size = Vector2(0.0, 42.0)
	UIThemeBuilder.apply_primary_cta_button(_main_menu_btn, UIThemeBuilder.COL_CRIMSON)
	_main_menu_btn.pressed.connect(_on_main_menu_pressed)
	vb.add_child(_main_menu_btn)
