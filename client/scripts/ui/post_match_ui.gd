class_name PostMatchUI
extends CanvasLayer
## Phase 14 — Post-Match Victory Banner, Per-Player Box Score, Glicko-2 Rating Delta
## & Rematch Screen for PHANTOM COURT ONLINE.

signal navigate_requested(route: String, params: Dictionary)
signal rematch_requested()

var _ui_built: bool = false
var _is_visible_state: bool = false
var _winner_text: String = ""
var _final_score_text: String = "0 — 0"
var _rating_delta_text: String = ""
var _box_rows_count: int = 0
var _last_summary: Dictionary = {}

var _root_overlay: Control = null
var _winner_label: Label = null
var _final_score_label: Label = null
var _rating_card: PanelContainer = null
var _rating_delta_label: Label = null
var _box_rows_vb: VBoxContainer = null
var _rematch_btn: Button = null
var _lobby_btn: Button = null
var _menu_btn: Button = null


func _enter_tree() -> void:
	_connect_event_bus()


func _ready() -> void:
	layer = 25
	add_to_group("post_match_ui")
	_ensure_ui_built()
	_connect_event_bus()
	hide_results()


func _exit_tree() -> void:
	_disconnect_event_bus()


func is_results_visible() -> bool:
	return _is_visible_state


func get_displayed_winner_text() -> String:
	return _winner_text


func get_displayed_final_score() -> String:
	return _final_score_text


func get_displayed_rating_delta_text() -> String:
	return _rating_delta_text


func get_box_score_row_count() -> int:
	return _box_rows_count


func hide_results() -> void:
	_ensure_ui_built()
	_is_visible_state = false
	_root_overlay.visible = false


func populate_results(match_summary: Dictionary) -> void:
	_ensure_ui_built()
	_last_summary = match_summary.duplicate(true)
	_is_visible_state = true
	_root_overlay.visible = true

	var scores: Array = match_summary.get("final_scores", [0, 0]) as Array
	var sa: int = int(scores[0]) if scores.size() > 0 else 0
	var sb: int = int(scores[1]) if scores.size() > 1 else 0
	var winner: int = int(match_summary.get("winner_team", 0 if sa > sb else (1 if sb > sa else -1)))

	if winner == 0:
		_winner_text = "TEAM A VICTORY"
		_winner_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	elif winner == 1:
		_winner_text = "TEAM B VICTORY"
		_winner_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CRIMSON)
	else:
		_winner_text = "OVERTIME DRAW"
		_winner_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)

	_winner_label.text = _winner_text
	_final_score_text = "%d  —  %d" % [sa, sb]
	_final_score_label.text = _final_score_text

	# Online & Offline Local Career Glicko-2 Rating Delta Card
	var rating_info: Dictionary = {}
	if match_summary.has("rating_update") and match_summary["rating_update"] is Dictionary:
		rating_info = match_summary["rating_update"] as Dictionary
	elif match_summary.has("rating_delta") and match_summary["rating_delta"] is Dictionary:
		rating_info = match_summary["rating_delta"] as Dictionary
	elif match_summary.has("ranked_update") and match_summary["ranked_update"] is Dictionary:
		rating_info = match_summary["ranked_update"] as Dictionary

	if not rating_info.is_empty():
		var r_before: float = float(rating_info.get("rating_before", rating_info.get("old_rating", 1500.0)))
		var r_after: float = float(rating_info.get("rating_after", rating_info.get("new_rating", r_before)))
		var r_delta: float = float(rating_info.get("rating_delta", rating_info.get("delta", r_after - r_before)))
		var div: String = str(rating_info.get("division", "Gold")).to_upper()
		var div_col: Color = UIThemeBuilder.get_division_color(div)
		var mode_tag: String = "GLICKO-2 RANKED" if bool(match_summary.get("is_online", _is_online_match())) else "LOCAL CAREER GLICKO-2"
		_rating_delta_text = "%s:  %.0f  →  %.0f  (%+.1f)  •  %s" % [mode_tag, r_before, r_after, r_delta, div]
		_rating_delta_label.text = _rating_delta_text
		_rating_delta_label.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD if r_delta >= 0.0 else UIThemeBuilder.COL_CRIMSON)
		_rating_card.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(div_col, 0.24))
		_rating_card.visible = true
	else:
		_rating_delta_text = ""
		_rating_card.visible = false

	# Per-Player Box Score Grid
	var players_arr: Array = match_summary.get("players", []) as Array
	_rebuild_box_score(players_arr)

	var is_online: bool = bool(match_summary.get("is_online", _is_online_match()))
	_lobby_btn.visible = is_online

	if DisplayServer.get_name() != "headless":
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _rebuild_box_score(players: Array) -> void:
	for child in _box_rows_vb.get_children():
		_box_rows_vb.remove_child(child)
		child.free()
	_box_rows_count = 0

	if players.is_empty():
		var note := Label.new()
		note.text = "Match complete! Check scoreboard totals above."
		note.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
		_box_rows_vb.add_child(note)
		return

	for raw in players:
		if not (raw is Dictionary):
			continue
		var p: Dictionary = raw as Dictionary
		var team: int = int(p.get("team_id", p.get("team", 0)))
		var pname: String = str(p.get("username", p.get("name", "Player %d" % int(p.get("player_id", _box_rows_count + 1)))))
		var arch: String = str(p.get("archetype", p.get("archetype_id", "all_rounder"))).to_upper()
		var pts: int = int(p.get("points", p.get("pts", 0)))
		var tpm: int = int(p.get("three_pointers_made", p.get("three_pm", p.get("3pm", 0))))
		var ast: int = int(p.get("assists", p.get("ast", 0)))
		var reb: int = int(p.get("rebounds", p.get("reb", 0)))
		var stl: int = int(p.get("steals", p.get("stl", 0)))
		var blk: int = int(p.get("blocks", p.get("blk", 0)))
		var combos: int = int(p.get("combos", p.get("combos_landed", 0)))
		var zones: int = int(p.get("zone_activations", p.get("zone", 0)))

		var rp := PanelContainer.new()
		var border_col: Color = UIThemeBuilder.COL_CYAN if team == 0 else UIThemeBuilder.COL_CRIMSON
		rp.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL_DARK, border_col, 1, 5, 10.0, 5.0))
		_box_rows_vb.add_child(rp)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		rp.add_child(row)

		_add_box_col(row, pname, 150.0, UIThemeBuilder.COL_TEXT_PRIMARY, true)
		_add_box_col(row, arch, 105.0, border_col)
		_add_box_col(row, str(pts), 48.0, UIThemeBuilder.COL_GOLD)
		_add_box_col(row, str(tpm), 48.0, UIThemeBuilder.COL_TEXT_PRIMARY)
		_add_box_col(row, str(ast), 48.0, UIThemeBuilder.COL_TEXT_PRIMARY)
		_add_box_col(row, str(reb), 48.0, UIThemeBuilder.COL_TEXT_PRIMARY)
		_add_box_col(row, str(stl), 48.0, UIThemeBuilder.COL_TEXT_PRIMARY)
		_add_box_col(row, str(blk), 48.0, UIThemeBuilder.COL_TEXT_PRIMARY)
		_add_box_col(row, str(combos), 64.0, UIThemeBuilder.COL_CYAN)
		_add_box_col(row, str(zones), 52.0, UIThemeBuilder.COL_EMERALD)
		_box_rows_count += 1


func _on_match_ended(winner_team: int, final_scores: Array, stats: Dictionary) -> void:
	var summary: Dictionary = stats.duplicate(true)
	summary["winner_team"] = winner_team
	summary["final_scores"] = final_scores.duplicate()
	populate_results(summary)


func _on_rematch_pressed() -> void:
	rematch_requested.emit()
	if _is_online_match():
		var nc: Node = UIThemeBuilder.get_autoload("NetClient")
		if nc != null and nc.has_method("vote_rematch"):
			var rid: int = int(str(nc.get("room_id")))
			var mid: String = str(nc.get("current_member_id"))
			if rid > 0 and not mid.is_empty():
				nc.call("vote_rematch", rid, mid, true, func(_ok: bool, _c: int, _d: Dictionary) -> void: pass)
				_rematch_btn.text = "REMATCH VOTED ✓"
				_rematch_btn.disabled = true
	else:
		hide_results()
		if is_inside_tree() and get_tree() != null:
			var mc: Node = get_tree().get_first_node_in_group("match_controller")
			if mc != null and mc.has_method("restart_match"):
				mc.call("restart_match")


func _on_return_lobby_pressed() -> void:
	hide_results()
	UIThemeBuilder.route_navigate(self, "lobby")


func _on_main_menu_pressed() -> void:
	hide_results()
	if _is_online_match():
		var nc: Node = UIThemeBuilder.get_autoload("NetClient")
		if nc != null and nc.has_method("disconnect_from_server"):
			nc.call("disconnect_from_server", "post_match_exit")
	UIThemeBuilder.route_navigate(self, "main_menu")


func _is_online_match() -> bool:
	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	return gs != null and bool(gs.get("is_online"))


func _connect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb != null and eb.has_signal("match_ended") and not eb.is_connected("match_ended", _on_match_ended):
		eb.connect("match_ended", _on_match_ended)


func _disconnect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb != null and eb.has_signal("match_ended") and eb.is_connected("match_ended", _on_match_ended):
		eb.disconnect("match_ended", _on_match_ended)


func _ensure_ui_built() -> void:
	if _ui_built:
		return
	_ui_built = true

	_root_overlay = Control.new()
	_root_overlay.name = "PostMatchOverlayRoot"
	_root_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_overlay.theme = UIThemeBuilder.build_theme()
	_root_overlay.visible = false
	add_child(_root_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.03, 0.04, 0.09, 0.86)
	_root_overlay.add_child(dim)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 64)
	margin.add_theme_constant_override("margin_right", 64)
	margin.add_theme_constant_override("margin_top", 36)
	margin.add_theme_constant_override("margin_bottom", 32)
	_root_overlay.add_child(margin)
	UIThemeBuilder.apply_safe_area_margins(margin, 32)

	var card := PanelContainer.new()
	card.name = "PostMatchCard"
	card.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL, UIThemeBuilder.COL_GOLD, 2, 12, 24.0, 20.0))
	margin.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	card.add_child(vb)

	_winner_label = Label.new()
	_winner_label.name = "WinnerBannerLabel"
	_winner_label.text = "TEAM A VICTORY"
	_winner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_winner_label.add_theme_font_size_override("font_size", 36)
	vb.add_child(_winner_label)

	_final_score_label = Label.new()
	_final_score_label.name = "FinalScoreLabel"
	_final_score_label.text = "0  —  0"
	_final_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_final_score_label.add_theme_font_size_override("font_size", 30)
	_final_score_label.add_theme_color_override("font_color", UIThemeBuilder.COL_TEXT_PRIMARY)
	vb.add_child(_final_score_label)

	_rating_card = PanelContainer.new()
	_rating_card.name = "RatingDeltaCard"
	_rating_card.visible = false
	vb.add_child(_rating_card)

	_rating_delta_label = Label.new()
	_rating_delta_label.name = "RatingDeltaLabel"
	_rating_delta_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rating_delta_label.add_theme_font_size_override("font_size", 16)
	_rating_card.add_child(_rating_delta_label)

	# Box Score Header
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 8)
	vb.add_child(hdr_row)
	_add_box_col(hdr_row, "PLAYER", 150.0, UIThemeBuilder.COL_SLATE, true)
	_add_box_col(hdr_row, "ARCHETYPE", 105.0, UIThemeBuilder.COL_SLATE)
	_add_box_col(hdr_row, "PTS", 48.0, UIThemeBuilder.COL_SLATE)
	_add_box_col(hdr_row, "3PM", 48.0, UIThemeBuilder.COL_SLATE)
	_add_box_col(hdr_row, "AST", 48.0, UIThemeBuilder.COL_SLATE)
	_add_box_col(hdr_row, "REB", 48.0, UIThemeBuilder.COL_SLATE)
	_add_box_col(hdr_row, "STL", 48.0, UIThemeBuilder.COL_SLATE)
	_add_box_col(hdr_row, "BLK", 48.0, UIThemeBuilder.COL_SLATE)
	_add_box_col(hdr_row, "COMBOS", 64.0, UIThemeBuilder.COL_SLATE)
	_add_box_col(hdr_row, "ZONE", 52.0, UIThemeBuilder.COL_SLATE)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(scroll)

	_box_rows_vb = VBoxContainer.new()
	_box_rows_vb.name = "BoxScoreRows"
	_box_rows_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box_rows_vb.add_theme_constant_override("separation", 5)
	scroll.add_child(_box_rows_vb)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 14)
	vb.add_child(btn_row)

	_rematch_btn = Button.new()
	_rematch_btn.name = "RematchButton"
	_rematch_btn.text = "REMATCH"
	_rematch_btn.custom_minimum_size = Vector2(180.0, 44.0)
	UIThemeBuilder.apply_primary_cta_button(_rematch_btn, UIThemeBuilder.COL_EMERALD)
	_rematch_btn.pressed.connect(_on_rematch_pressed)
	btn_row.add_child(_rematch_btn)

	_lobby_btn = Button.new()
	_lobby_btn.name = "ReturnLobbyButton"
	_lobby_btn.text = "RETURN TO LOBBY"
	_lobby_btn.custom_minimum_size = Vector2(180.0, 44.0)
	_lobby_btn.visible = false
	_lobby_btn.pressed.connect(_on_return_lobby_pressed)
	btn_row.add_child(_lobby_btn)

	_menu_btn = Button.new()
	_menu_btn.name = "ReturnMainMenuButton"
	_menu_btn.text = "MAIN MENU"
	_menu_btn.custom_minimum_size = Vector2(180.0, 44.0)
	UIThemeBuilder.apply_primary_cta_button(_menu_btn, UIThemeBuilder.COL_CYAN)
	_menu_btn.pressed.connect(_on_main_menu_pressed)
	btn_row.add_child(_menu_btn)


func _add_box_col(parent: HBoxContainer, txt: String, min_w: float, col: Color, expand: bool = false) -> void:
	var lbl := Label.new()
	lbl.text = txt
	lbl.custom_minimum_size = Vector2(min_w, 0.0)
	if expand:
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", 13)
	parent.add_child(lbl)
