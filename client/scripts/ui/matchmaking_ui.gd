class_name MatchmakingUI
extends Control
## Phase 14 — Online Matchmaking, Private Room & Live Spectator Browser UI.
## Honestly queries `/health` via `/root/NetClient` and disables queue/online controls
## with clear `SERVER OFFLINE — Launch tools/start_server.ps1` feedback when unreachable.

signal navigate_requested(route: String, params: Dictionary)

const MODE_OPTIONS: Array[String] = ["1v1", "2v2", "3v3"]
const OFFLINE_BANNER_TEXT := "SERVER OFFLINE — Launch tools/start_server.ps1"
const LOCAL_OFFLINE_BANNER_TEXT := "LOCAL OFFLINE BUILD — Online queues require a dedicated server. Enjoy Vs AI (1v1/2v2/3v3), Practice Dojo & Local Ranked Career!"

@export var auto_check_server_on_ready: bool = true

var _ui_built: bool = false
var _server_online: bool = false
var _server_status_text: String = OFFLINE_BANNER_TEXT
var _active_ticket_id: String = ""
var _poll_accum: float = 0.0
var _rooms_cache: Array = []

var _status_panel: PanelContainer = null
var _status_label: Label = null
var _retry_health_btn: Button = null
var _username_edit: LineEdit = null
var _archetype_opt: OptionButton = null
var _fill_bots_cb: CheckBox = null

var _queue_buttons: Dictionary = {} # mode -> Button
var _queue_status_label: Label = null
var _cancel_queue_btn: Button = null

var _private_mode_opt: OptionButton = null
var _create_room_btn: Button = null
var _room_code_edit: LineEdit = null
var _join_code_btn: Button = null

var _refresh_rooms_btn: Button = null
var _rooms_list_vb: VBoxContainer = null
var _back_btn: Button = null


func _ready() -> void:
	_ensure_ui_built()
	_sync_identity_defaults()
	apply_health_result(false, {})
	if auto_check_server_on_ready and not UIThemeBuilder.is_local_offline_build():
		refresh_server_health()


func _process(delta: float) -> void:
	if _active_ticket_id.is_empty() or not _server_online or delta <= 0.0:
		return
	_poll_accum += delta
	if _poll_accum >= 1.25:
		_poll_accum = 0.0
		_poll_matchmaking_ticket()


func is_server_online() -> bool:
	return _server_online


func get_server_status_text() -> String:
	_ensure_ui_built()
	return _status_label.text if _status_label != null else _server_status_text


func are_queue_buttons_enabled() -> bool:
	_ensure_ui_built()
	for btn in _queue_buttons.values():
		if (btn as Button).disabled:
			return false
	return not _queue_buttons.is_empty()


func get_displayed_room_count() -> int:
	return _rooms_cache.size()


func refresh_server_health() -> void:
	if UIThemeBuilder.is_local_offline_build():
		apply_health_result(false, {})
		return
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("check_server_health"):
		apply_health_result(false, {})
		return
	nc.call("check_server_health", func(ok: bool, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		apply_health_result(ok, data)
		if ok:
			refresh_rooms()
	)


func apply_health_result(ok: bool, data: Dictionary) -> void:
	_ensure_ui_built()
	_server_online = ok
	if ok:
		var backend: String = str(data.get("db_backend", "ephemeral" if bool(data.get("ephemeral_db", false)) else "postgres"))
		var players: int = int(data.get("active_players", 0))
		var rooms_cnt: int = int(data.get("rooms_count", 0))
		_server_status_text = "ONLINE (%s)  •  %d Active Players  •  %d Live Rooms" % [backend, players, rooms_cnt]
		_status_label.text = _server_status_text
		_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD)
		_status_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_EMERALD, 0.20))
	else:
		_active_ticket_id = ""
		if UIThemeBuilder.is_local_offline_build():
			_server_status_text = LOCAL_OFFLINE_BANNER_TEXT
			_status_label.text = _server_status_text
			_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
			_status_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_GOLD, 0.20))
		else:
			_server_status_text = OFFLINE_BANNER_TEXT
			_status_label.text = _server_status_text
			_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CRIMSON)
			_status_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_CRIMSON, 0.22))
		populate_rooms([])

	_update_controls_enabled()


func refresh_rooms() -> void:
	if not _server_online:
		populate_rooms([])
		return
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("list_rooms"):
		return
	nc.call("list_rooms", func(ok: bool, _code: int, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if ok and data.has("rooms") and data["rooms"] is Array:
			populate_rooms(data["rooms"] as Array)
		elif ok:
			populate_rooms([])
	)


func populate_rooms(rooms: Array) -> void:
	_ensure_ui_built()
	_rooms_cache = rooms.duplicate(true)
	for child in _rooms_list_vb.get_children():
		_rooms_list_vb.remove_child(child)
		child.free()

	if _rooms_cache.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = (
			"No live public rooms right now. Create a room or queue Ranked above!"
			if _server_online
			else "Server offline — start tools/start_server.ps1 to browse live rooms & spectate."
		)
		empty_lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
		_rooms_list_vb.add_child(empty_lbl)
		return

	for item in _rooms_cache:
		if not (item is Dictionary):
			continue
		var r: Dictionary = item as Dictionary
		var rid: int = int(r.get("room_id", 0))
		var rmode: String = str(r.get("mode", "3v3"))
		var rcode: String = str(r.get("room_code", "------"))
		var rstate: String = str(r.get("state", "Lobby"))
		var cur_p: int = int(r.get("player_count", r.get("members_count", 0)))
		var max_p: int = int(r.get("max_players", r.get("capacity", 6)))

		var row_panel := PanelContainer.new()
		row_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL_DARK, UIThemeBuilder.COL_BORDER_SUBTLE, 1, 6, 10.0, 6.0))
		_rooms_list_vb.add_child(row_panel)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 10)
		row_panel.add_child(hbox)

		var info := Label.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.text = "ROOM #%d  [%s]  •  CODE: %s  •  %s  •  %d/%d" % [rid, rmode.to_upper(), rcode, rstate, cur_p, max_p]
		hbox.add_child(info)

		var join_btn := Button.new()
		join_btn.text = "JOIN"
		join_btn.disabled = (not _server_online) or (rstate != "Lobby")
		join_btn.pressed.connect(func() -> void: _on_join_room_id(rid))
		hbox.add_child(join_btn)

		var spec_btn := Button.new()
		spec_btn.text = "SPECTATE LIVE"
		spec_btn.disabled = not _server_online
		UIThemeBuilder.apply_primary_cta_button(spec_btn, UIThemeBuilder.COL_GOLD)
		spec_btn.pressed.connect(func() -> void: _on_spectate_room_id(rid))
		hbox.add_child(spec_btn)


func _selected_username() -> String:
	var txt: String = _username_edit.text.strip_edges() if _username_edit != null else ""
	return txt if not txt.is_empty() else "PhantomPlayer"


func _selected_archetype() -> String:
	if _archetype_opt != null and _archetype_opt.selected >= 0:
		var meta: Variant = _archetype_opt.get_item_metadata(_archetype_opt.selected)
		if meta is String and not (meta as String).is_empty():
			return meta as String
	return "all_rounder"


func _persist_identity() -> void:
	var uname: String = _selected_username()
	var arch: String = _selected_archetype()
	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null:
		gs.set("player_name", uname)
		gs.set("selected_archetype", arch)
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc != null:
		nc.set("username", uname)
		nc.set("archetype_id", arch)


func _on_queue_pressed(mode: String) -> void:
	if not _server_online:
		return
	_persist_identity()
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("enqueue_matchmaking"):
		return
	_queue_status_label.text = "Queueing Ranked %s..." % mode.to_upper()
	nc.call(
		"enqueue_matchmaking",
		mode,
		_selected_username(),
		_selected_archetype(),
		_fill_bots_cb.button_pressed,
		1500,
		func(ok: bool, _code: int, data: Dictionary) -> void:
			if not is_instance_valid(self) or not is_inside_tree():
				return
			if not ok:
				_queue_status_label.text = "Queue failed: %s" % str(data.get("error", "server unreachable"))
				return
			_active_ticket_id = str(data.get("ticket_id", ""))
			if data.has("lobby_state") and data["lobby_state"] is Dictionary:
				_active_ticket_id = ""
				UIThemeBuilder.route_navigate(self, "lobby", {"lobby_state": data["lobby_state"]})
			else:
				_queue_status_label.text = "In Queue (%s) — Ticket %s..." % [mode.to_upper(), _active_ticket_id]
				_update_controls_enabled()
	)


func _on_cancel_queue_pressed() -> void:
	if _active_ticket_id.is_empty():
		return
	var ticket: String = _active_ticket_id
	_active_ticket_id = ""
	_queue_status_label.text = "Queue cancelled."
	_update_controls_enabled()
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc != null and nc.has_method("cancel_matchmaking"):
		nc.call("cancel_matchmaking", ticket, func(_ok: bool, _c: int, _d: Dictionary) -> void: pass)


func _poll_matchmaking_ticket() -> void:
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("get_matchmaking_status"):
		return
	nc.call("get_matchmaking_status", _active_ticket_id, func(ok: bool, _code: int, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if ok and data.has("lobby_state") and data["lobby_state"] is Dictionary:
			_active_ticket_id = ""
			UIThemeBuilder.route_navigate(self, "lobby", {"lobby_state": data["lobby_state"]})
	)


func _on_create_private_room_pressed() -> void:
	if not _server_online:
		return
	_persist_identity()
	var mode: String = MODE_OPTIONS[clampi(_private_mode_opt.selected, 0, MODE_OPTIONS.size() - 1)]
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("create_room"):
		return
	_queue_status_label.text = "Creating Private %s Room..." % mode.to_upper()
	nc.call("create_room", mode, true, _fill_bots_cb.button_pressed, _selected_username(), _selected_archetype(), func(ok: bool, _code: int, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if ok and data.has("lobby_state") and data["lobby_state"] is Dictionary:
			UIThemeBuilder.route_navigate(self, "lobby", {"lobby_state": data["lobby_state"]})
		else:
			_queue_status_label.text = "Create room failed: %s" % str(data.get("error", "error"))
	)


func _on_join_code_pressed() -> void:
	if not _server_online:
		return
	var code: String = _room_code_edit.text.strip_edges().to_upper()
	if code.length() < 4:
		_queue_status_label.text = "Enter a valid 6-character Room Code."
		return
	_persist_identity()
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("join_room_by_code"):
		return
	nc.call("join_room_by_code", code, _selected_username(), _selected_archetype(), false, func(ok: bool, _c: int, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if ok and data.has("lobby_state") and data["lobby_state"] is Dictionary:
			UIThemeBuilder.route_navigate(self, "lobby", {"lobby_state": data["lobby_state"]})
		else:
			_queue_status_label.text = "Join code failed: %s" % str(data.get("error", "room not found"))
	)


func _on_join_room_id(rid: int) -> void:
	if not _server_online:
		return
	_persist_identity()
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("join_room_by_id"):
		return
	nc.call("join_room_by_id", rid, _selected_username(), _selected_archetype(), false, func(ok: bool, _c: int, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if ok and data.has("lobby_state") and data["lobby_state"] is Dictionary:
			UIThemeBuilder.route_navigate(self, "lobby", {"lobby_state": data["lobby_state"]})
	)


func _on_spectate_room_id(rid: int) -> void:
	if not _server_online:
		return
	_persist_identity()
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("request_spectate"):
		return
	nc.call("request_spectate", rid, _selected_username(), func(ok: bool, _c: int, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if ok:
			UIThemeBuilder.route_navigate(self, "spectate", {"room_id": rid, "ticket": data})
	)


func _update_controls_enabled() -> void:
	var can_act: bool = _server_online and _active_ticket_id.is_empty()
	for btn in _queue_buttons.values():
		(btn as Button).disabled = not can_act
	if _cancel_queue_btn != null:
		_cancel_queue_btn.disabled = _active_ticket_id.is_empty()
	if _create_room_btn != null:
		_create_room_btn.disabled = not can_act
	if _join_code_btn != null:
		_join_code_btn.disabled = not can_act
	if _refresh_rooms_btn != null:
		_refresh_rooms_btn.disabled = not _server_online


func _sync_identity_defaults() -> void:
	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null:
		if gs.get("player_name") != null and not str(gs.get("player_name")).is_empty():
			_username_edit.text = str(gs.get("player_name"))
		if gs.get("selected_archetype") != null:
			var aid: String = ArchetypeRegistry.resolve_id(str(gs.get("selected_archetype")))
			for i in range(_archetype_opt.item_count):
				if str(_archetype_opt.get_item_metadata(i)) == aid:
					_archetype_opt.select(i)
					break


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
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	add_child(margin)
	UIThemeBuilder.apply_safe_area_margins(margin, 22)

	var root_vb := VBoxContainer.new()
	root_vb.add_theme_constant_override("separation", 12)
	margin.add_child(root_vb)

	# Header + Server Health Banner
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 12)
	root_vb.add_child(hdr_row)

	var hdr := Label.new()
	hdr.text = "ONLINE MULTIPLAYER // RANKED QUEUE, ROOMS & SPECTATOR"
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_theme_font_size_override("font_size", 22)
	hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	hdr_row.add_child(hdr)

	_retry_health_btn = Button.new()
	_retry_health_btn.name = "CheckHealthButton"
	_retry_health_btn.text = "CHECK SERVER"
	_retry_health_btn.pressed.connect(refresh_server_health)
	hdr_row.add_child(_retry_health_btn)

	_back_btn = Button.new()
	_back_btn.name = "BackButton"
	_back_btn.text = "MAIN MENU"
	_back_btn.pressed.connect(func() -> void: UIThemeBuilder.route_navigate(self, "main_menu"))
	hdr_row.add_child(_back_btn)

	_status_panel = PanelContainer.new()
	_status_panel.name = "ServerHealthBanner"
	root_vb.add_child(_status_panel)
	_status_label = Label.new()
	_status_label.name = "ServerHealthLabel"
	_status_label.text = OFFLINE_BANNER_TEXT
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_panel.add_child(_status_label)

	# Player Identity Bar
	var id_panel := PanelContainer.new()
	root_vb.add_child(id_panel)
	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override("separation", 14)
	id_panel.add_child(id_row)

	var u_lbl := Label.new()
	u_lbl.text = "USERNAME:"
	id_row.add_child(u_lbl)
	_username_edit = LineEdit.new()
	_username_edit.name = "UsernameEdit"
	_username_edit.text = "PhantomPlayer"
	_username_edit.custom_minimum_size = Vector2(210.0, 0.0)
	id_row.add_child(_username_edit)

	var a_lbl := Label.new()
	a_lbl.text = "ARCHETYPE:"
	id_row.add_child(a_lbl)
	_archetype_opt = OptionButton.new()
	_archetype_opt.name = "ArchetypeOption"
	for i in range(ArchetypeRegistry.ORDERED_IDS.size()):
		var aid: String = ArchetypeRegistry.ORDERED_IDS[i]
		var ad: Dictionary = ArchetypeRegistry.get_archetype_dict(aid)
		_archetype_opt.add_item("%s (%s)" % [str(ad.get("nickname", aid)), str(ad.get("class_name_display", ""))], i)
		_archetype_opt.set_item_metadata(i, aid)
	id_row.add_child(_archetype_opt)

	_fill_bots_cb = CheckBox.new()
	_fill_bots_cb.name = "FillBotsCheck"
	_fill_bots_cb.text = "Fill Empty Slots with Server AI"
	_fill_bots_cb.button_pressed = true
	id_row.add_child(_fill_bots_cb)

	# Split: Left Ranked Queue + Private Room, Right Live Room Browser
	var split := HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 16)
	root_vb.add_child(split)

	var left_vb := VBoxContainer.new()
	left_vb.custom_minimum_size = Vector2(460.0, 0.0)
	left_vb.add_theme_constant_override("separation", 12)
	split.add_child(left_vb)

	# Ranked Queue Card
	var q_panel := PanelContainer.new()
	left_vb.add_child(q_panel)
	var q_vb := VBoxContainer.new()
	q_vb.add_theme_constant_override("separation", 8)
	q_panel.add_child(q_vb)

	var q_hdr := Label.new()
	q_hdr.text = "QUICK RANKED MATCHMAKING"
	q_hdr.add_theme_font_size_override("font_size", 15)
	q_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	q_vb.add_child(q_hdr)

	var q_btn_row := HBoxContainer.new()
	q_btn_row.add_theme_constant_override("separation", 10)
	q_vb.add_child(q_btn_row)
	for mode in MODE_OPTIONS:
		var btn := Button.new()
		btn.name = "QueueBtn_%s" % mode
		btn.text = "QUEUE %s" % mode.to_upper()
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0.0, 44.0)
		UIThemeBuilder.apply_primary_cta_button(btn, UIThemeBuilder.COL_CYAN)
		var captured_mode: String = mode
		btn.pressed.connect(func() -> void: _on_queue_pressed(captured_mode))
		q_btn_row.add_child(btn)
		_queue_buttons[mode] = btn

	var q_stat_row := HBoxContainer.new()
	q_vb.add_child(q_stat_row)
	_queue_status_label = Label.new()
	_queue_status_label.name = "QueueStatusLabel"
	_queue_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_queue_status_label.text = "Idle"
	_queue_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	q_stat_row.add_child(_queue_status_label)

	_cancel_queue_btn = Button.new()
	_cancel_queue_btn.name = "CancelQueueButton"
	_cancel_queue_btn.text = "CANCEL QUEUE"
	_cancel_queue_btn.disabled = true
	_cancel_queue_btn.pressed.connect(_on_cancel_queue_pressed)
	q_stat_row.add_child(_cancel_queue_btn)

	# Private Room Card
	var p_panel := PanelContainer.new()
	left_vb.add_child(p_panel)
	var p_vb := VBoxContainer.new()
	p_vb.add_theme_constant_override("separation", 8)
	p_panel.add_child(p_vb)

	var p_hdr := Label.new()
	p_hdr.text = "PRIVATE ROOMS & INVITE CODE"
	p_hdr.add_theme_font_size_override("font_size", 15)
	p_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	p_vb.add_child(p_hdr)

	var cr_row := HBoxContainer.new()
	cr_row.add_theme_constant_override("separation", 8)
	p_vb.add_child(cr_row)
	_private_mode_opt = OptionButton.new()
	_private_mode_opt.name = "PrivateModeOption"
	for i in range(MODE_OPTIONS.size()):
		_private_mode_opt.add_item(MODE_OPTIONS[i].to_upper(), i)
	_private_mode_opt.select(2)
	cr_row.add_child(_private_mode_opt)

	_create_room_btn = Button.new()
	_create_room_btn.name = "CreatePrivateRoomButton"
	_create_room_btn.text = "CREATE PRIVATE ROOM"
	_create_room_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIThemeBuilder.apply_primary_cta_button(_create_room_btn, UIThemeBuilder.COL_EMERALD)
	_create_room_btn.pressed.connect(_on_create_private_room_pressed)
	cr_row.add_child(_create_room_btn)

	var jc_row := HBoxContainer.new()
	jc_row.add_theme_constant_override("separation", 8)
	p_vb.add_child(jc_row)
	_room_code_edit = LineEdit.new()
	_room_code_edit.name = "RoomCodeEdit"
	_room_code_edit.placeholder_text = "6-CHAR ROOM CODE"
	_room_code_edit.max_length = 6
	_room_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jc_row.add_child(_room_code_edit)

	_join_code_btn = Button.new()
	_join_code_btn.name = "JoinByCodeButton"
	_join_code_btn.text = "JOIN ROOM"
	_join_code_btn.pressed.connect(_on_join_code_pressed)
	jc_row.add_child(_join_code_btn)

	# Right: Live Public & Spectatable Rooms Browser
	var b_panel := PanelContainer.new()
	b_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(b_panel)
	var b_vb := VBoxContainer.new()
	b_vb.add_theme_constant_override("separation", 8)
	b_panel.add_child(b_vb)

	var b_hdr_row := HBoxContainer.new()
	b_vb.add_child(b_hdr_row)
	var b_hdr := Label.new()
	b_hdr.text = "LIVE PUBLIC & SPECTATABLE ROOMS"
	b_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b_hdr.add_theme_font_size_override("font_size", 15)
	b_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	b_hdr_row.add_child(b_hdr)

	_refresh_rooms_btn = Button.new()
	_refresh_rooms_btn.name = "RefreshRoomsButton"
	_refresh_rooms_btn.text = "REFRESH ROOMS"
	_refresh_rooms_btn.pressed.connect(refresh_rooms)
	b_hdr_row.add_child(_refresh_rooms_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b_vb.add_child(scroll)

	_rooms_list_vb = VBoxContainer.new()
	_rooms_list_vb.name = "RoomsList"
	_rooms_list_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rooms_list_vb.add_theme_constant_override("separation", 6)
	scroll.add_child(_rooms_list_vb)
