class_name MainMenuUI
extends Control
## Phase 14 — Cyber-Anime Sports Main Menu Screen for PHANTOM COURT ONLINE.
## Provides slanted primary navigation, live selected archetype pill, honest server
## health badge via /root/NetClient, and canonical `navigate_requested(route, params)`.

signal navigate_requested(route: String, params: Dictionary)

const LOCAL_OFFLINE_BADGE_TEXT := "LOCAL OFFLINE EDITION • NO SERVER NEEDED"

@export var auto_check_server_on_ready: bool = true

var _server_online: bool = false
var _server_status_text: String = "SERVER OFFLINE — Launch tools/start_server.ps1"
var _selected_char_text: String = ""
var _ui_built: bool = false

var _title_label: Label = null
var _subtitle_label: Label = null
var _char_pill_panel: PanelContainer = null
var _char_pill_label: Label = null
var _server_badge_panel: PanelContainer = null
var _server_status_label: Label = null
var _btn_play_ai: Button = null
var _btn_online: Button = null
var _btn_practice: Button = null
var _btn_rankings: Button = null
var _btn_settings: Button = null
var _btn_quit: Button = null


func _ready() -> void:
	_ensure_ui_built()
	refresh_selected_character()
	if UIThemeBuilder.is_local_offline_build():
		refresh_offline_mode_ui()
		return
	apply_health_status(false, {})
	if auto_check_server_on_ready:
		refresh_server_health()


func get_server_status_text() -> String:
	_ensure_ui_built()
	return _server_status_label.text if _server_status_label != null else _server_status_text


func is_server_online() -> bool:
	return _server_online


func get_selected_character_text() -> String:
	_ensure_ui_built()
	return _char_pill_label.text if _char_pill_label != null else _selected_char_text


func refresh_selected_character() -> void:
	_ensure_ui_built()
	var arch_id: String = "all_rounder"
	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null and gs.get("selected_archetype") != null:
		arch_id = str(gs.get("selected_archetype"))
	var resolved: String = ArchetypeRegistry.resolve_id(arch_id)
	var arch_dict: Dictionary = ArchetypeRegistry.get_archetype_dict(resolved)
	var cname: String = str(arch_dict.get("character_name", "Akira \"Eclipse\" Shinohara"))
	var cls_disp: String = str(arch_dict.get("class_name_display", "All-Rounder"))
	var colors: Dictionary = arch_dict.get("colors", {})
	var accent: Color = colors.get("aura", UIThemeBuilder.COL_CYAN) as Color

	_selected_char_text = "SELECTED BALLER: %s (%s)" % [cname, cls_disp.to_upper()]
	if _char_pill_label != null:
		_char_pill_label.text = _selected_char_text
	if _char_pill_panel != null:
		_char_pill_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(accent, 0.24))


func refresh_offline_mode_ui() -> void:
	_ensure_ui_built()
	if UIThemeBuilder.is_local_offline_build():
		_server_online = false
		_server_status_text = LOCAL_OFFLINE_BADGE_TEXT
		if _server_status_label != null:
			_server_status_label.text = _server_status_text
			_server_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
		if _server_badge_panel != null:
			_server_badge_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_GOLD, 0.22))
		if _btn_online != null:
			_btn_online.text = "ONLINE MULTIPLAYER (PC / SERVER REQUIRED)"
	else:
		if _btn_online != null:
			_btn_online.text = "ONLINE MULTIPLAYER"


func refresh_server_health() -> void:
	if UIThemeBuilder.is_local_offline_build():
		refresh_offline_mode_ui()
		return
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("check_server_health"):
		apply_health_status(false, {})
		return
	nc.call("check_server_health", func(ok: bool, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		apply_health_status(ok, data)
	)


func apply_health_status(ok: bool, data: Dictionary) -> void:
	_ensure_ui_built()
	_server_online = ok
	if ok:
		var backend: String = str(data.get("db_backend", "ephemeral" if bool(data.get("ephemeral_db", false)) else "postgres"))
		var players: int = int(data.get("active_players", 0))
		var rooms: int = int(data.get("rooms_count", 0))
		_server_status_text = "SERVER ONLINE (%s)  •  %d Players  •  %d Rooms" % [backend, players, rooms]
		if _server_status_label != null:
			_server_status_label.text = _server_status_text
			_server_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD)
		if _server_badge_panel != null:
			_server_badge_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_EMERALD, 0.20))
		if _btn_online != null:
			_btn_online.text = "ONLINE MULTIPLAYER"
	elif UIThemeBuilder.is_local_offline_build():
		refresh_offline_mode_ui()
	else:
		_server_status_text = "SERVER OFFLINE — Launch tools/start_server.ps1"
		if _server_status_label != null:
			_server_status_label.text = _server_status_text
			_server_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CRIMSON)
		if _server_badge_panel != null:
			_server_badge_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_CRIMSON, 0.18))
		if _btn_online != null:
			_btn_online.text = "ONLINE MULTIPLAYER"


func _trigger_route(route: String, params: Dictionary = {}) -> void:
	UIThemeBuilder.route_navigate(self, route, params)


func _ensure_ui_built() -> void:
	if _ui_built:
		return
	_ui_built = true

	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UIThemeBuilder.build_theme()

	# Fullscreen cyber-obsidian stadium backdrop
	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = UIThemeBuilder.COL_OBSIDIAN
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Stylized diagonal/edge accent bars
	var top_stripe := ColorRect.new()
	top_stripe.name = "TopAccentStripe"
	top_stripe.anchor_left = 0.0
	top_stripe.anchor_right = 1.0
	top_stripe.offset_bottom = 5.0
	top_stripe.color = UIThemeBuilder.COL_CYAN
	top_stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top_stripe)

	var side_glow := ColorRect.new()
	side_glow.name = "SideAccentStripe"
	side_glow.anchor_top = 0.0
	side_glow.anchor_bottom = 1.0
	side_glow.offset_right = 6.0
	side_glow.color = UIThemeBuilder.COL_CRIMSON
	side_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(side_glow)

	# Main layout margin
	var margin := MarginContainer.new()
	margin.name = "MainMargin"
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 56)
	margin.add_theme_constant_override("margin_right", 56)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 34)
	add_child(margin)
	UIThemeBuilder.apply_safe_area_margins(margin, 38)

	var root_vbox := VBoxContainer.new()
	root_vbox.name = "RootVBox"
	root_vbox.add_theme_constant_override("separation", 22)
	margin.add_child(root_vbox)

	# Top Bar: Title + Live Status Badges
	var header_row := HBoxContainer.new()
	header_row.name = "HeaderRow"
	header_row.add_theme_constant_override("separation", 16)
	root_vbox.add_child(header_row)

	var brand_vbox := VBoxContainer.new()
	brand_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand_vbox.add_theme_constant_override("separation", 4)
	header_row.add_child(brand_vbox)

	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = "PHANTOM COURT ONLINE"
	_title_label.add_theme_font_size_override("font_size", 46)
	_title_label.add_theme_color_override("font_color", UIThemeBuilder.COL_TEXT_PRIMARY)
	_title_label.add_theme_color_override("font_outline_color", UIThemeBuilder.COL_CYAN)
	_title_label.add_theme_constant_override("outline_size", 5)
	brand_vbox.add_child(_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.name = "SubtitleLabel"
	_subtitle_label.text = "ANIME 3V3 BASKETBALL  •  FIGHTING-GAME COMBOS  •  ZONE AWAKENING"
	_subtitle_label.add_theme_font_size_override("font_size", 14)
	_subtitle_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	brand_vbox.add_child(_subtitle_label)

	var badges_vbox := VBoxContainer.new()
	badges_vbox.alignment = BoxContainer.ALIGNMENT_END
	badges_vbox.add_theme_constant_override("separation", 8)
	header_row.add_child(badges_vbox)

	_char_pill_panel = PanelContainer.new()
	_char_pill_panel.name = "SelectedCharacterPill"
	badges_vbox.add_child(_char_pill_panel)

	_char_pill_label = Label.new()
	_char_pill_label.name = "SelectedCharacterLabel"
	_char_pill_label.add_theme_font_size_override("font_size", 13)
	_char_pill_panel.add_child(_char_pill_label)

	_server_badge_panel = PanelContainer.new()
	_server_badge_panel.name = "ServerStatusBadge"
	badges_vbox.add_child(_server_badge_panel)

	_server_status_label = Label.new()
	_server_status_label.name = "ServerStatusLabel"
	_server_status_label.add_theme_font_size_override("font_size", 12)
	_server_badge_panel.add_child(_server_status_label)

	# Body Row: Slanted Left Nav + Right Feature Highlight Card
	var body_row := HBoxContainer.new()
	body_row.name = "BodyRow"
	body_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_row.add_theme_constant_override("separation", 36)
	root_vbox.add_child(body_row)

	var nav_panel := PanelContainer.new()
	nav_panel.name = "NavPanel"
	nav_panel.custom_minimum_size = Vector2(390.0, 0.0)
	nav_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL, UIThemeBuilder.COL_CYAN, 2, 10, 20.0, 20.0))
	body_row.add_child(nav_panel)

	var nav_vbox := VBoxContainer.new()
	nav_vbox.name = "NavButtons"
	nav_vbox.add_theme_constant_override("separation", 12)
	nav_panel.add_child(nav_vbox)

	var nav_hdr := Label.new()
	nav_hdr.text = "PLAY MODES & ARENA"
	nav_hdr.add_theme_font_size_override("font_size", 13)
	nav_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	nav_vbox.add_child(nav_hdr)

	_btn_play_ai = _add_nav_button(nav_vbox, "PlayAIButton", "PLAY VS AI", UIThemeBuilder.COL_CYAN, true)
	_btn_online = _add_nav_button(nav_vbox, "OnlineButton", "ONLINE MULTIPLAYER", UIThemeBuilder.COL_CRIMSON, true)
	_btn_practice = _add_nav_button(nav_vbox, "PracticeButton", "PRACTICE DOJO", UIThemeBuilder.COL_EMERALD, false)
	_btn_rankings = _add_nav_button(nav_vbox, "RankingsButton", "PROFILE & RANKINGS", UIThemeBuilder.COL_GOLD, false)
	_btn_settings = _add_nav_button(nav_vbox, "SettingsButton", "SETTINGS", UIThemeBuilder.COL_SLATE, false)
	_btn_quit = _add_nav_button(nav_vbox, "QuitButton", "QUIT", UIThemeBuilder.COL_CRIMSON, false)

	_btn_play_ai.pressed.connect(func() -> void: _trigger_route("character_select"))
	_btn_online.pressed.connect(func() -> void: _trigger_route("matchmaking"))
	_btn_practice.pressed.connect(func() -> void: _trigger_route("training"))
	_btn_rankings.pressed.connect(func() -> void: _trigger_route("profile_rankings"))
	_btn_settings.pressed.connect(func() -> void: _trigger_route("settings"))
	_btn_quit.pressed.connect(func() -> void: _trigger_route("quit"))

	# Right Court Showcase / Quick Guide Card
	var info_panel := PanelContainer.new()
	info_panel.name = "FeatureShowcasePanel"
	info_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL_DARK, UIThemeBuilder.COL_BORDER_SUBTLE, 2, 10, 24.0, 22.0))
	body_row.add_child(info_panel)

	var info_vbox := VBoxContainer.new()
	info_vbox.add_theme_constant_override("separation", 14)
	info_panel.add_child(info_vbox)

	var feat_hdr := Label.new()
	feat_hdr.text = "SEASON 1 // PHANTOM CIRCUIT"
	feat_hdr.add_theme_font_size_override("font_size", 20)
	feat_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	info_vbox.add_child(feat_hdr)

	var feat_body := Label.new()
	feat_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	feat_body.add_theme_font_size_override("font_size", 14)
	feat_body.add_theme_color_override("font_color", UIThemeBuilder.COL_TEXT_PRIMARY)
	feat_body.text = (
		"• 5 Playable Anime Archetypes — Volt, Deadeye, Mirage, Titan & Eclipse\n"
		+ "• Fighting-Game 60 Hz Combo Chains — Phantom Drive, Meteor Dunk, Ankle Breaker & Mirror Step\n"
		+ "• THE ZONE Awakening — Build 100% meter through clutch plays and unleash EX Skills\n"
		+ "• Skill Training Dojo — Frame-exact Input Tape, Timing Bar, 5-Spot Shooting & Programmable Dummy\n"
		+ "• Authoritative 60 Hz Online Multiplayer — Ranked 1v1/2v2/3v3, Private Room Codes & Live Spectator Mode"
	)
	info_vbox.add_child(feat_body)

	var controls_hint := Label.new()
	controls_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls_hint.add_theme_font_size_override("font_size", 12)
	controls_hint.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	controls_hint.text = "QUICK CONTROLS: WASD Move • Shift Sprint • Space Jump/Block • LMB/J Shoot • RMB/K Pass • Q/E/R Combos • F Steal • C Stance • V THE ZONE • Esc Pause"
	info_vbox.add_child(controls_hint)

	# Footer
	var footer := Label.new()
	footer.text = "PHANTOM COURT ONLINE  •  Godot 4.7.2 + Authoritative Rust 60 Hz Server"
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	footer.add_theme_font_size_override("font_size", 11)
	footer.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	root_vbox.add_child(footer)


func _add_nav_button(parent: VBoxContainer, btn_name: String, label_text: String, accent: Color, is_primary: bool) -> Button:
	var btn := Button.new()
	btn.name = btn_name
	btn.text = label_text
	btn.custom_minimum_size = Vector2(0.0, 50.0 if is_primary else 42.0)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_font_size_override("font_size", 18 if is_primary else 15)
	UIThemeBuilder.apply_primary_cta_button(btn, accent)
	parent.add_child(btn)
	return btn
