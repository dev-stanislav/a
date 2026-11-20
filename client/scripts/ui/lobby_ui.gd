class_name LobbyUI
extends Control
## Phase 14 — Multiplayer Match Room Lobby UI for PHANTOM COURT ONLINE.
## Displays Room Mode, 6-Char Room Code, State (Lobby/Countdown/InMatch), Team A vs Team B
## rosters, Archetype/Team/AI-Bots controls, Ready toggle, and live Enter Court transition.

signal navigate_requested(route: String, params: Dictionary)

var _ui_built: bool = false
var _lobby_state: Dictionary = {}
var _room_id: int = 0
var _room_code: String = "------"
var _state_text: String = "Lobby"
var _local_ready: bool = false
var _team_a_count: int = 0
var _team_b_count: int = 0
var _poll_accum: float = 0.0
var _suppress_callbacks: bool = false

var _mode_badge: Label = null
var _code_badge: Label = null
var _state_badge: Label = null
var _team_a_list: VBoxContainer = null
var _team_b_list: VBoxContainer = null
var _archetype_opt: OptionButton = null
var _team_a_btn: Button = null
var _team_b_btn: Button = null
var _fill_bots_cb: CheckBox = null
var _ready_btn: Button = null
var _enter_court_btn: Button = null
var _leave_btn: Button = null


func _enter_tree() -> void:
	_connect_event_bus()


func _ready() -> void:
	_ensure_ui_built()
	_connect_event_bus()
	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null and gs.get("lobby_state") is Dictionary and not (gs.get("lobby_state") as Dictionary).is_empty():
		apply_lobby_state(gs.get("lobby_state") as Dictionary)
	else:
		var nc: Node = UIThemeBuilder.get_autoload("NetClient")
		if nc != null and nc.get("current_lobby_state") is Dictionary and not (nc.get("current_lobby_state") as Dictionary).is_empty():
			apply_lobby_state(nc.get("current_lobby_state") as Dictionary)


func _exit_tree() -> void:
	_disconnect_event_bus()


func _process(delta: float) -> void:
	if _room_id <= 0 or delta <= 0.0:
		return
	_poll_accum += delta
	if _poll_accum >= 1.5:
		_poll_accum = 0.0
		var nc: Node = UIThemeBuilder.get_autoload("NetClient")
		if nc != null and nc.has_method("get_room_state"):
			nc.call("get_room_state", _room_id, func(_ok: bool, _c: int, _d: Dictionary) -> void: pass)


func get_displayed_room_code() -> String:
	return _room_code


func get_displayed_state() -> String:
	return _state_text


func get_team_a_count() -> int:
	return _team_a_count


func get_team_b_count() -> int:
	return _team_b_count


func apply_lobby_state(state: Dictionary) -> void:
	_ensure_ui_built()
	_lobby_state = state.duplicate(true)
	_room_id = int(state.get("room_id", _room_id))
	_room_code = str(state.get("room_code", "------"))
	_state_text = str(state.get("state", "Lobby"))
	var mode_str: String = str(state.get("mode", "3v3")).to_upper()

	_mode_badge.text = "MODE: %s" % mode_str
	_code_badge.text = "CODE: %s" % _room_code
	_state_badge.text = "STATE: %s" % _state_text.to_upper()

	_suppress_callbacks = true
	if state.has("fill_bots") and _fill_bots_cb != null:
		_fill_bots_cb.button_pressed = bool(state["fill_bots"])
	_suppress_callbacks = false

	_rebuild_team_rosters(state.get("members", []) as Array)

	var is_in_match: bool = (_state_text == "InMatch")
	_enter_court_btn.disabled = not is_in_match
	_ready_btn.text = "UNREADY" if _local_ready else "READY UP"


func _rebuild_team_rosters(members: Array) -> void:
	for child in _team_a_list.get_children():
		_team_a_list.remove_child(child)
		child.free()
	for child in _team_b_list.get_children():
		_team_b_list.remove_child(child)
		child.free()

	_team_a_count = 0
	_team_b_count = 0
	var local_mid: String = _get_local_member_id()

	for m_raw in members:
		if not (m_raw is Dictionary):
			continue
		var m: Dictionary = m_raw as Dictionary
		var team: int = int(m.get("team", 0))
		var uname: String = str(m.get("username", "Player"))
		var arch: String = str(m.get("archetype", "all_rounder"))
		var is_ready: bool = bool(m.get("ready", false))
		var is_bot: bool = bool(m.get("is_bot", false))
		var mid: String = str(m.get("member_id", ""))
		if not local_mid.is_empty() and mid == local_mid:
			_local_ready = is_ready

		var card := PanelContainer.new()
		var border_col: Color = UIThemeBuilder.COL_EMERALD if is_ready else UIThemeBuilder.COL_BORDER_SUBTLE
		card.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL_DARK, border_col, 2, 6, 10.0, 6.0))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		card.add_child(row)

		var name_lbl := Label.new()
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.text = "%s%s  [%s]" % [uname, " (BOT)" if is_bot else "", arch.to_upper()]
		row.add_child(name_lbl)

		var ready_lbl := Label.new()
		ready_lbl.text = "READY" if is_ready else "WAITING"
		ready_lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD if is_ready else UIThemeBuilder.COL_GOLD)
		row.add_child(ready_lbl)

		if team == 0:
			_team_a_list.add_child(card)
			_team_a_count += 1
		else:
			_team_b_list.add_child(card)
			_team_b_count += 1


func _get_local_member_id() -> String:
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc != null and nc.get("current_member_id") != null:
		return str(nc.get("current_member_id"))
	return ""


func _on_ready_toggled() -> void:
	_local_ready = not _local_ready
	_ready_btn.text = "UNREADY" if _local_ready else "READY UP"
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	var mid: String = _get_local_member_id()
	if nc != null and nc.has_method("set_ready") and _room_id > 0 and not mid.is_empty():
		nc.call("set_ready", _room_id, mid, _local_ready, func(_ok: bool, _c: int, _d: Dictionary) -> void: pass)


func _on_switch_team(team_id: int) -> void:
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	var mid: String = _get_local_member_id()
	if nc != null and nc.has_method("update_lobby_member") and _room_id > 0 and not mid.is_empty():
		nc.call("update_lobby_member", _room_id, mid, team_id, "", null, func(_ok: bool, _c: int, _d: Dictionary) -> void: pass)


func _on_archetype_selected(idx: int) -> void:
	if _suppress_callbacks or idx < 0:
		return
	var aid: String = str(_archetype_opt.get_item_metadata(idx))
	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null:
		gs.set("selected_archetype", aid)
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	var mid: String = _get_local_member_id()
	if nc != null and nc.has_method("update_lobby_member") and _room_id > 0 and not mid.is_empty():
		nc.call("update_lobby_member", _room_id, mid, -1, aid, null, func(_ok: bool, _c: int, _d: Dictionary) -> void: pass)


func _on_fill_bots_toggled(toggled: bool) -> void:
	if _suppress_callbacks:
		return
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	var mid: String = _get_local_member_id()
	if nc != null and nc.has_method("update_lobby_member") and _room_id > 0 and not mid.is_empty():
		nc.call("update_lobby_member", _room_id, mid, -1, "", toggled, func(_ok: bool, _c: int, _d: Dictionary) -> void: pass)


func _on_enter_court_pressed() -> void:
	UIThemeBuilder.route_navigate(self, "play_online", {
		"room_id": _room_id,
		"room_code": _room_code,
		"lobby_state": _lobby_state,
	})


func _on_leave_pressed() -> void:
	UIThemeBuilder.route_navigate(self, "matchmaking")


func _connect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb != null and eb.has_signal("lobby_state_updated") and not eb.is_connected("lobby_state_updated", apply_lobby_state):
		eb.connect("lobby_state_updated", apply_lobby_state)


func _disconnect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb != null and eb.has_signal("lobby_state_updated") and eb.is_connected("lobby_state_updated", apply_lobby_state):
		eb.disconnect("lobby_state_updated", apply_lobby_state)


func _ensure_ui_built() -> void:
	if _ui_built:
		return
	_ui_built = true

	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UIThemeBuilder.build_theme()

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = UIThemeBuilder.COL_OBSIDIAN
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_right", 36)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)
	UIThemeBuilder.apply_safe_area_margins(margin, 24)

	var root_vb := VBoxContainer.new()
	root_vb.add_theme_constant_override("separation", 14)
	margin.add_child(root_vb)

	# Room Header Row
	var hdr_panel := PanelContainer.new()
	hdr_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL, UIThemeBuilder.COL_CYAN, 2, 8, 16.0, 10.0))
	root_vb.add_child(hdr_panel)
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 18)
	hdr_panel.add_child(hdr_row)

	var title := Label.new()
	title.text = "MATCH LOBBY"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	hdr_row.add_child(title)

	_mode_badge = Label.new()
	_mode_badge.name = "ModeBadge"
	_mode_badge.text = "MODE: 3V3"
	_mode_badge.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	hdr_row.add_child(_mode_badge)

	_code_badge = Label.new()
	_code_badge.name = "RoomCodeBadge"
	_code_badge.text = "CODE: ------"
	_code_badge.add_theme_font_size_override("font_size", 18)
	_code_badge.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD)
	hdr_row.add_child(_code_badge)

	_state_badge = Label.new()
	_state_badge.name = "StateBadge"
	_state_badge.text = "STATE: LOBBY"
	_state_badge.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	hdr_row.add_child(_state_badge)

	# Team A vs Team B Columns
	var teams_row := HBoxContainer.new()
	teams_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	teams_row.add_theme_constant_override("separation", 18)
	root_vb.add_child(teams_row)

	var ta_panel := PanelContainer.new()
	ta_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ta_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL, UIThemeBuilder.COL_CYAN, 2, 8))
	teams_row.add_child(ta_panel)
	var ta_vb := VBoxContainer.new()
	ta_vb.add_theme_constant_override("separation", 8)
	ta_panel.add_child(ta_vb)
	var ta_hdr := Label.new()
	ta_hdr.text = "TEAM A // BLUE PHANTOMS"
	ta_hdr.add_theme_font_size_override("font_size", 16)
	ta_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	ta_vb.add_child(ta_hdr)
	_team_a_list = VBoxContainer.new()
	_team_a_list.name = "TeamAList"
	_team_a_list.add_theme_constant_override("separation", 6)
	ta_vb.add_child(_team_a_list)

	var tb_panel := PanelContainer.new()
	tb_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL, UIThemeBuilder.COL_CRIMSON, 2, 8))
	teams_row.add_child(tb_panel)
	var tb_vb := VBoxContainer.new()
	tb_vb.add_theme_constant_override("separation", 8)
	tb_panel.add_child(tb_vb)
	var tb_hdr := Label.new()
	tb_hdr.text = "TEAM B // CRIMSON REIGN"
	tb_hdr.add_theme_font_size_override("font_size", 16)
	tb_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CRIMSON)
	tb_vb.add_child(tb_hdr)
	_team_b_list = VBoxContainer.new()
	_team_b_list.name = "TeamBList"
	_team_b_list.add_theme_constant_override("separation", 6)
	tb_vb.add_child(_team_b_list)

	# Bottom Lobby Controls Bar
	var ctrl_panel := PanelContainer.new()
	root_vb.add_child(ctrl_panel)
	var ctrl_row := HBoxContainer.new()
	ctrl_row.add_theme_constant_override("separation", 10)
	ctrl_panel.add_child(ctrl_row)

	_archetype_opt = OptionButton.new()
	_archetype_opt.name = "LobbyArchetypeOption"
	for i in range(ArchetypeRegistry.ORDERED_IDS.size()):
		var aid: String = ArchetypeRegistry.ORDERED_IDS[i]
		var ad: Dictionary = ArchetypeRegistry.get_archetype_dict(aid)
		_archetype_opt.add_item("%s (%s)" % [str(ad.get("nickname", aid)), str(ad.get("class_name_display", ""))], i)
		_archetype_opt.set_item_metadata(i, aid)
	_archetype_opt.item_selected.connect(_on_archetype_selected)
	ctrl_row.add_child(_archetype_opt)

	_team_a_btn = Button.new()
	_team_a_btn.name = "SwitchTeamAButton"
	_team_a_btn.text = "TEAM A"
	_team_a_btn.pressed.connect(func() -> void: _on_switch_team(0))
	ctrl_row.add_child(_team_a_btn)

	_team_b_btn = Button.new()
	_team_b_btn.name = "SwitchTeamBButton"
	_team_b_btn.text = "TEAM B"
	_team_b_btn.pressed.connect(func() -> void: _on_switch_team(1))
	ctrl_row.add_child(_team_b_btn)

	_fill_bots_cb = CheckBox.new()
	_fill_bots_cb.name = "FillAIBotsCheck"
	_fill_bots_cb.text = "Fill AI Bots"
	_fill_bots_cb.toggled.connect(_on_fill_bots_toggled)
	ctrl_row.add_child(_fill_bots_cb)

	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctrl_row.add_child(sp)

	_leave_btn = Button.new()
	_leave_btn.name = "LeaveLobbyButton"
	_leave_btn.text = "LEAVE"
	_leave_btn.pressed.connect(_on_leave_pressed)
	ctrl_row.add_child(_leave_btn)

	_ready_btn = Button.new()
	_ready_btn.name = "ReadyToggleButton"
	_ready_btn.text = "READY UP"
	UIThemeBuilder.apply_primary_cta_button(_ready_btn, UIThemeBuilder.COL_EMERALD)
	_ready_btn.pressed.connect(_on_ready_toggled)
	ctrl_row.add_child(_ready_btn)

	_enter_court_btn = Button.new()
	_enter_court_btn.name = "EnterCourtButton"
	_enter_court_btn.text = "ENTER COURT"
	_enter_court_btn.disabled = true
	UIThemeBuilder.apply_primary_cta_button(_enter_court_btn, UIThemeBuilder.COL_GOLD)
	_enter_court_btn.pressed.connect(_on_enter_court_pressed)
	ctrl_row.add_child(_enter_court_btn)
