class_name ProfileRankingsUI
extends Control
## Phase 14 — Player Profile, Ranked Division, Match History & Global Leaderboard UI.
## Queries `/health`, `/api/profile`, `/api/profile/:id/history`, and `/api/leaderboard`
## via `/root/NetClient`, displaying honest offline status + local MasteryTracker fallback.

signal navigate_requested(route: String, params: Dictionary)

const OFFLINE_BANNER_TEXT := "SERVER OFFLINE — Launch tools/start_server.ps1"
const LOCAL_OFFLINE_BANNER_TEXT := "LOCAL OFFLINE CAREER — Glicko-2 Progression & League Table (No Server Needed)"
const ARCHETYPE_IDS: Array[String] = ["speedster", "sharpshooter", "playmaker", "powerhouse", "all_rounder"]

@export var auto_check_server_on_ready: bool = true

var _ui_built: bool = false
var _server_online: bool = false
var _using_local_career: bool = false
var _server_status_text: String = OFFLINE_BANNER_TEXT
var _profile_username: String = "PhantomPlayer"
var _displayed_division: String = "Unranked"
var _leaderboard_entries: Array = []

var _health_panel: PanelContainer = null
var _health_label: Label = null
var _tabs: TabContainer = null

# Tab 1: Profile
var _username_edit: LineEdit = null
var _lookup_btn: Button = null
var _local_identity_row: HBoxContainer = null
var _fav_arch_opt: OptionButton = null
var _save_local_btn: Button = null
var _division_panel: PanelContainer = null
var _division_label: Label = null
var _rating_label: Label = null
var _division_progress: ProgressBar = null
var _record_label: Label = null
var _season_stats_label: Label = null
var _history_list_vb: VBoxContainer = null
var _offline_fallback_label: Label = null

# Tab 2: Global Leaderboard
var _season_spin: SpinBox = null
var _refresh_lb_btn: Button = null
var _lb_list_vb: VBoxContainer = null


func _enter_tree() -> void:
	_connect_event_bus()


func _ready() -> void:
	_ensure_ui_built()
	_connect_event_bus()
	var lc: Node = UIThemeBuilder.get_autoload("LocalCareer")
	if lc != null and lc.has_method("get_profile"):
		var lp: Dictionary = lc.call("get_profile") as Dictionary
		if not str(lp.get("username", "")).is_empty():
			_profile_username = str(lp.get("username"))
			_username_edit.text = _profile_username
	else:
		var gs: Node = UIThemeBuilder.get_autoload("GameState")
		if gs != null and gs.get("player_name") != null and not str(gs.get("player_name")).is_empty():
			_profile_username = str(gs.get("player_name"))
			_username_edit.text = _profile_username

	apply_health_result(false, {})
	if UIThemeBuilder.is_local_offline_build():
		return
	if auto_check_server_on_ready:
		refresh_server_health()


func _exit_tree() -> void:
	_disconnect_event_bus()


func is_server_online() -> bool:
	return _server_online


func is_using_local_career() -> bool:
	return _using_local_career


func get_server_status_text() -> String:
	_ensure_ui_built()
	return _health_label.text if _health_label != null else _server_status_text


func get_displayed_profile_username() -> String:
	return _profile_username


func get_displayed_division() -> String:
	return _displayed_division


func get_displayed_leaderboard_count() -> int:
	return _leaderboard_entries.size()


func refresh_local_career() -> void:
	_ensure_ui_built()
	_load_local_career_or_fallback()


func save_local_career_identity(username_override: String = "", fav_override: String = "") -> bool:
	_ensure_ui_built()
	var uname: String = username_override.strip_edges() if not username_override.strip_edges().is_empty() else _username_edit.text.strip_edges()
	if uname.is_empty():
		uname = "PhantomPlayer"
	var fav_arch: String = fav_override.strip_edges().to_lower()
	if fav_arch.is_empty() and _fav_arch_opt != null:
		fav_arch = ARCHETYPE_IDS[clampi(_fav_arch_opt.selected, 0, ARCHETYPE_IDS.size() - 1)]
	if fav_arch.is_empty():
		fav_arch = "all_rounder"

	_profile_username = uname
	_username_edit.text = uname

	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null:
		gs.set("player_name", uname)

	var lc: Node = UIThemeBuilder.get_autoload("LocalCareer")
	if lc != null and lc.has_method("set_player_identity"):
		lc.call("set_player_identity", uname, fav_arch)
		_load_local_career_or_fallback()
		return true
	return false


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
			_on_lookup_profile_pressed()
			_on_refresh_leaderboard_pressed()
	)


func apply_health_result(ok: bool, data: Dictionary) -> void:
	_ensure_ui_built()
	_server_online = ok
	if ok:
		_using_local_career = false
		var backend: String = str(data.get("db_backend", "ephemeral" if bool(data.get("ephemeral_db", false)) else "postgres"))
		_server_status_text = "ONLINE (%s) — Ranked Profiles & Global Leaderboard Connected" % backend
		_health_label.text = _server_status_text
		_health_label.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD)
		_health_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_EMERALD, 0.20))
		_offline_fallback_label.visible = false
		if _local_identity_row != null:
			_local_identity_row.visible = false
	else:
		var is_local_build: bool = UIThemeBuilder.is_local_offline_build()
		if is_local_build:
			_server_status_text = LOCAL_OFFLINE_BANNER_TEXT
			_health_label.text = _server_status_text
			_health_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
			_health_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_GOLD, 0.22))
		else:
			_server_status_text = OFFLINE_BANNER_TEXT
			_health_label.text = _server_status_text
			_health_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CRIMSON)
			_health_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_CRIMSON, 0.20))
		if _local_identity_row != null:
			_local_identity_row.visible = true
		_load_local_career_or_fallback()

	_lookup_btn.disabled = not ok
	_refresh_lb_btn.disabled = not ok


func populate_profile(profile: Dictionary, history: Array = []) -> void:
	_ensure_ui_built()
	if profile.is_empty():
		return
	_profile_username = str(profile.get("username", _profile_username))
	var rating: float = float(profile.get("rating", 1500.0))
	var rd: float = float(profile.get("rating_deviation", profile.get("rd", 350.0)))
	var peak: float = float(profile.get("peak_rating", rating))
	var div: String = str(profile.get("division", "Gold"))
	var wins: int = int(profile.get("wins", 0))
	var losses: int = int(profile.get("losses", 0))
	var matches: int = int(profile.get("matches_played", wins + losses))
	var win_pct: float = (100.0 * float(wins) / float(maxi(1, wins + losses))) if (wins + losses) > 0 else 0.0

	var div_info: Dictionary = UIThemeBuilder.compute_division_progress(rating, div)
	_displayed_division = str(div_info["name"])
	var div_col: Color = div_info["color"] as Color

	_division_label.text = _displayed_division.to_upper()
	_division_label.add_theme_color_override("font_color", div_col)
	_division_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(div_col, 0.25))
	_rating_label.text = "GLICKO-2: %.0f  (RD ±%.0f)  •  PEAK: %.0f" % [rating, rd, peak]
	_division_progress.value = float(div_info["progress"]) * 100.0
	_division_progress.add_theme_stylebox_override("fill", UIThemeBuilder.make_bar_style(div_col, 4))
	_record_label.text = "RECORD: %dW - %dL  (%.1f%% Win Rate)  •  FAV CLASS: %s" % [
		wins,
		losses,
		win_pct,
		str(profile.get("archetype_fav", "all_rounder")).to_upper(),
	]

	var pts: int = int(profile.get("total_points", profile.get("points", 0)))
	var ast: int = int(profile.get("total_assists", profile.get("assists", 0)))
	var reb: int = int(profile.get("total_rebounds", profile.get("rebounds", 0)))
	var blk: int = int(profile.get("total_blocks", profile.get("blocks", 0)))
	var stl: int = int(profile.get("total_steals", profile.get("steals", 0)))
	var zone_act: int = int(profile.get("total_zone_activations", profile.get("zone_activations", 0)))

	_season_stats_label.text = (
		"Matches: %d   |   Points: %d   |   Assists: %d   |   Rebounds: %d\n"
		+ "Blocks: %d   |   Steals: %d   |   Zone Activations: %d   |   Peak Rating: %.0f"
	) % [matches, pts, ast, reb, blk, stl, zone_act, peak]

	_rebuild_history_rows(history)


func populate_leaderboard(entries: Array) -> void:
	_ensure_ui_built()
	_leaderboard_entries = entries.duplicate(true)
	for child in _lb_list_vb.get_children():
		_lb_list_vb.remove_child(child)
		child.free()

	if _leaderboard_entries.is_empty():
		var empty := Label.new()
		empty.text = "No ranked leaderboard entries yet." if _server_online else "Server offline — launch tools/start_server.ps1 to load global rankings."
		empty.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
		_lb_list_vb.add_child(empty)
		return

	for i in range(_leaderboard_entries.size()):
		var raw: Variant = _leaderboard_entries[i]
		if not (raw is Dictionary):
			continue
		var e: Dictionary = raw as Dictionary
		var rank_num: int = int(e.get("rank", i + 1))
		var uname: String = str(e.get("username", "Player"))
		var div: String = str(e.get("division", "Gold"))
		var rating: float = float(e.get("rating", 1500.0))
		var wins: int = int(e.get("wins", 0))
		var losses: int = int(e.get("losses", 0))
		var wpct: float = float(e.get("win_rate", (100.0 * float(wins) / float(maxi(1, wins + losses))) if (wins + losses) > 0 else 0.0))
		var peak: float = float(e.get("peak_rating", rating))
		var fav: String = str(e.get("archetype_fav", "all_rounder"))

		var row_panel := PanelContainer.new()
		row_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL_DARK, UIThemeBuilder.COL_BORDER_SUBTLE, 1, 5, 10.0, 5.0))
		_lb_list_vb.add_child(row_panel)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row_panel.add_child(row)

		_add_col_label(row, "#%d" % rank_num, 46.0, UIThemeBuilder.COL_GOLD if rank_num <= 3 else UIThemeBuilder.COL_TEXT_PRIMARY)
		_add_col_label(row, uname, 180.0, UIThemeBuilder.COL_TEXT_PRIMARY, true)
		_add_col_label(row, div.to_upper(), 105.0, UIThemeBuilder.get_division_color(div))
		_add_col_label(row, "%.0f" % rating, 74.0, UIThemeBuilder.COL_CYAN)
		_add_col_label(row, "%d-%d" % [wins, losses], 74.0, UIThemeBuilder.COL_TEXT_PRIMARY)
		_add_col_label(row, "%.1f%%" % wpct, 74.0, UIThemeBuilder.COL_EMERALD)
		_add_col_label(row, "%.0f" % peak, 74.0, UIThemeBuilder.COL_SLATE)
		_add_col_label(row, fav.to_upper(), 110.0, UIThemeBuilder.COL_SLATE)


func _rebuild_history_rows(history: Array) -> void:
	for child in _history_list_vb.get_children():
		_history_list_vb.remove_child(child)
		child.free()

	if history.is_empty():
		var empty := Label.new()
		empty.text = "No local career matches played yet — finish a Vs AI match to record Glicko-2 history!" if _using_local_career else "No recent online ranked matches recorded yet."
		empty.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
		_history_list_vb.add_child(empty)
		return

	for item in history:
		if not (item is Dictionary):
			continue
		var h: Dictionary = item as Dictionary
		var res_str: String = "WIN" if bool(h.get("won", false)) else "LOSS"
		var mode: String = str(h.get("mode", "3v3")).to_upper()
		var sa: int = int(h.get("score_a", h.get("team_score", 0)))
		var sb: int = int(h.get("score_b", h.get("opp_score", 0)))
		var delta: float = float(h.get("rating_delta", 0.0))
		var pts: int = int(h.get("points", 0))
		var lbl := Label.new()
		lbl.text = "%s [%s]  %d-%d  •  PTS: %d  •  Rating: %+.1f" % [res_str, mode, sa, sb, pts, delta]
		lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD if res_str == "WIN" else UIThemeBuilder.COL_CRIMSON)
		_history_list_vb.add_child(lbl)


func _load_local_career_or_fallback() -> void:
	var lc: Node = UIThemeBuilder.get_autoload("LocalCareer")
	if lc != null and lc.has_method("get_profile"):
		_using_local_career = true
		var prof: Dictionary = lc.call("get_profile") as Dictionary
		var hist: Array = lc.call("get_match_history", 20) as Array if lc.has_method("get_match_history") else []
		var lb: Array = lc.call("get_leaderboard") as Array if lc.has_method("get_leaderboard") else []
		if not prof.is_empty():
			var uname: String = str(prof.get("username", _profile_username))
			if not uname.is_empty():
				_profile_username = uname
				if _username_edit != null:
					_username_edit.text = uname
			var fav: String = str(prof.get("archetype_fav", "all_rounder")).to_lower()
			if _fav_arch_opt != null:
				var f_idx: int = ARCHETYPE_IDS.find(fav)
				_fav_arch_opt.select(f_idx if f_idx >= 0 else 4)
			populate_profile(prof, hist)
		populate_leaderboard(lb)
		_offline_fallback_label.visible = true
		if UIThemeBuilder.is_local_offline_build():
			_offline_fallback_label.text = "Local Offline Glicko-2 Career active — play Vs AI matches to earn rating, climb divisions, and rise on the Local League Table!"
		else:
			_offline_fallback_label.text = "Showing Local Offline Glicko-2 Career (server offline). Launch tools/start_server.ps1 for global online rankings."
		return

	_using_local_career = false
	_load_local_mastery_fallback()


func _load_local_mastery_fallback() -> void:
	var summary: Dictionary = {}
	if ResourceLoader.exists("res://scripts/training/mastery_tracker.gd"):
		var mt_scr := load("res://scripts/training/mastery_tracker.gd") as GDScript
		if mt_scr != null and mt_scr.can_instantiate():
			var mt: Variant = mt_scr.new()
			if mt != null and mt.has_method("load_from_disk") and mt.has_method("get_overall_summary"):
				mt.call("load_from_disk")
				summary = mt.call("get_overall_summary") as Dictionary

	var rank: String = str(summary.get("mastery_rank", "Novice"))
	var comps: int = int(summary.get("total_completions", 0))
	var perf_pct: float = float(summary.get("perfect_rate_pct", 0.0))
	var shot_acc: float = float(summary.get("shot_accuracy_pct", 0.0))
	var best_streak: int = int(summary.get("best_streak", 0))
	_displayed_division = "Offline (%s)" % rank
	_division_label.text = _displayed_division.to_upper()
	_rating_label.text = "LOCAL TRAINING DOJO FALLBACK (SERVER OFFLINE)"
	_division_progress.value = clampf(perf_pct, 0.0, 100.0)
	_record_label.text = "Local Combos Completed: %d  •  Perfect Rate: %.1f%%  •  Best Streak: %d" % [comps, perf_pct, best_streak]
	_season_stats_label.text = "Local Shot Practice Accuracy: %.1f%%  •  Mastery Rank: %s" % [shot_acc, rank]
	_offline_fallback_label.visible = true
	_offline_fallback_label.text = "Showing local offline MasteryTracker stats. Start tools/start_server.ps1 for Glicko-2 Ranked Profile & Global Leaderboard."


func _on_lookup_profile_pressed() -> void:
	if not _server_online:
		return
	var uname: String = _username_edit.text.strip_edges()
	if uname.is_empty():
		uname = "PhantomPlayer"
	_profile_username = uname
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("create_or_load_profile"):
		return
	nc.call("create_or_load_profile", uname, "", func(ok: bool, _c: int, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if ok:
			populate_profile(data, [])
			if nc.has_method("fetch_match_history"):
				nc.call("fetch_match_history", uname, 15, func(h_ok: bool, _hc: int, h_data: Dictionary) -> void:
					if not is_instance_valid(self) or not is_inside_tree():
						return
					if h_ok and h_data.has("history") and h_data["history"] is Array:
						_rebuild_history_rows(h_data["history"] as Array)
				)
	)


func _on_refresh_leaderboard_pressed() -> void:
	if not _server_online:
		return
	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc == null or not nc.has_method("fetch_leaderboard"):
		return
	nc.call("fetch_leaderboard", int(_season_spin.value), 50, func(ok: bool, _c: int, data: Dictionary) -> void:
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if ok and data.has("entries") and data["entries"] is Array:
			populate_leaderboard(data["entries"] as Array)
	)


func _on_profile_loaded_event(profile: Dictionary) -> void:
	populate_profile(profile)


func _connect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb == null:
		return
	if eb.has_signal("profile_loaded") and not eb.is_connected("profile_loaded", _on_profile_loaded_event):
		eb.connect("profile_loaded", _on_profile_loaded_event)
	if eb.has_signal("leaderboard_loaded") and not eb.is_connected("leaderboard_loaded", populate_leaderboard):
		eb.connect("leaderboard_loaded", populate_leaderboard)


func _disconnect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb == null:
		return
	if eb.has_signal("profile_loaded") and eb.is_connected("profile_loaded", _on_profile_loaded_event):
		eb.disconnect("profile_loaded", _on_profile_loaded_event)
	if eb.has_signal("leaderboard_loaded") and eb.is_connected("leaderboard_loaded", populate_leaderboard):
		eb.disconnect("leaderboard_loaded", populate_leaderboard)


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

	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 12)
	root_vb.add_child(hdr_row)

	var hdr := Label.new()
	hdr.text = "PLAYER PROFILE & GLOBAL RANKINGS"
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_theme_font_size_override("font_size", 24)
	hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	hdr_row.add_child(hdr)

	var back_btn := Button.new()
	back_btn.name = "BackButton"
	back_btn.text = "MAIN MENU"
	back_btn.pressed.connect(func() -> void: UIThemeBuilder.route_navigate(self, "main_menu"))
	hdr_row.add_child(back_btn)

	_health_panel = PanelContainer.new()
	_health_panel.name = "ServerHealthBanner"
	root_vb.add_child(_health_panel)
	_health_label = Label.new()
	_health_label.name = "ServerHealthLabel"
	_health_label.text = OFFLINE_BANNER_TEXT
	_health_panel.add_child(_health_label)

	_tabs = TabContainer.new()
	_tabs.name = "ProfileRankingsTabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vb.add_child(_tabs)

	# TAB 1: Player Profile
	var tab1 := VBoxContainer.new()
	tab1.name = "Player Profile"
	tab1.add_theme_constant_override("separation", 10)
	_tabs.add_child(tab1)

	var lookup_row := HBoxContainer.new()
	lookup_row.add_theme_constant_override("separation", 10)
	tab1.add_child(lookup_row)

	_username_edit = LineEdit.new()
	_username_edit.name = "ProfileUsernameEdit"
	_username_edit.text = "PhantomPlayer"
	_username_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lookup_row.add_child(_username_edit)

	_lookup_btn = Button.new()
	_lookup_btn.name = "LookupProfileButton"
	_lookup_btn.text = "LOAD / CREATE PROFILE"
	UIThemeBuilder.apply_primary_cta_button(_lookup_btn, UIThemeBuilder.COL_CYAN)
	_lookup_btn.pressed.connect(_on_lookup_profile_pressed)
	lookup_row.add_child(_lookup_btn)

	_local_identity_row = HBoxContainer.new()
	_local_identity_row.name = "LocalCareerIdentityRow"
	_local_identity_row.add_theme_constant_override("separation", 10)
	tab1.add_child(_local_identity_row)

	var fav_lbl := Label.new()
	fav_lbl.text = "FAVORITE CLASS:"
	fav_lbl.add_theme_font_size_override("font_size", 12)
	fav_lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	_local_identity_row.add_child(fav_lbl)

	_fav_arch_opt = OptionButton.new()
	_fav_arch_opt.name = "FavArchetypeOption"
	_fav_arch_opt.add_item("Speedster (Volt)", 0)
	_fav_arch_opt.add_item("Sharpshooter (Deadeye)", 1)
	_fav_arch_opt.add_item("Playmaker (Mirage)", 2)
	_fav_arch_opt.add_item("Powerhouse (Titan)", 3)
	_fav_arch_opt.add_item("All-Rounder (Eclipse)", 4)
	_fav_arch_opt.select(4)
	_local_identity_row.add_child(_fav_arch_opt)

	_save_local_btn = Button.new()
	_save_local_btn.name = "SaveLocalProfileButton"
	_save_local_btn.text = "SAVE LOCAL PROFILE"
	UIThemeBuilder.apply_primary_cta_button(_save_local_btn, UIThemeBuilder.COL_GOLD)
	_save_local_btn.pressed.connect(func() -> void: save_local_career_identity())
	_local_identity_row.add_child(_save_local_btn)

	_offline_fallback_label = Label.new()
	_offline_fallback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_offline_fallback_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	_offline_fallback_label.visible = false
	tab1.add_child(_offline_fallback_label)

	var div_row := HBoxContainer.new()
	div_row.add_theme_constant_override("separation", 14)
	tab1.add_child(div_row)

	_division_panel = PanelContainer.new()
	_division_panel.custom_minimum_size = Vector2(180.0, 64.0)
	div_row.add_child(_division_panel)
	_division_label = Label.new()
	_division_label.name = "DivisionLabel"
	_division_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_division_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_division_label.add_theme_font_size_override("font_size", 20)
	_division_panel.add_child(_division_label)

	var rat_vb := VBoxContainer.new()
	rat_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rat_vb.add_theme_constant_override("separation", 4)
	div_row.add_child(rat_vb)

	_rating_label = Label.new()
	_rating_label.name = "RatingLabel"
	_rating_label.add_theme_font_size_override("font_size", 16)
	rat_vb.add_child(_rating_label)

	_division_progress = ProgressBar.new()
	_division_progress.name = "DivisionProgressBar"
	_division_progress.min_value = 0.0
	_division_progress.max_value = 100.0
	_division_progress.custom_minimum_size = Vector2(0.0, 14.0)
	_division_progress.show_percentage = false
	rat_vb.add_child(_division_progress)

	_record_label = Label.new()
	_record_label.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	rat_vb.add_child(_record_label)

	_season_stats_label = Label.new()
	_season_stats_label.name = "SeasonalStatsLabel"
	_season_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tab1.add_child(_season_stats_label)

	var hist_hdr := Label.new()
	hist_hdr.text = "RECENT MATCH HISTORY"
	hist_hdr.add_theme_font_size_override("font_size", 13)
	hist_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	tab1.add_child(hist_hdr)

	var hist_scroll := ScrollContainer.new()
	hist_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab1.add_child(hist_scroll)
	_history_list_vb = VBoxContainer.new()
	_history_list_vb.name = "MatchHistoryList"
	_history_list_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hist_scroll.add_child(_history_list_vb)

	# TAB 2: Global Rankings Leaderboard
	var tab2 := VBoxContainer.new()
	tab2.name = "Global Rankings"
	tab2.add_theme_constant_override("separation", 8)
	_tabs.add_child(tab2)

	var lb_ctrl := HBoxContainer.new()
	lb_ctrl.add_theme_constant_override("separation", 10)
	tab2.add_child(lb_ctrl)

	var s_lbl := Label.new()
	s_lbl.text = "SEASON:"
	lb_ctrl.add_child(s_lbl)
	_season_spin = SpinBox.new()
	_season_spin.name = "SeasonSpinBox"
	_season_spin.min_value = 1
	_season_spin.max_value = 99
	_season_spin.value = 1
	lb_ctrl.add_child(_season_spin)

	_refresh_lb_btn = Button.new()
	_refresh_lb_btn.name = "RefreshLeaderboardButton"
	_refresh_lb_btn.text = "REFRESH LEADERBOARD"
	UIThemeBuilder.apply_primary_cta_button(_refresh_lb_btn, UIThemeBuilder.COL_GOLD)
	_refresh_lb_btn.pressed.connect(_on_refresh_leaderboard_pressed)
	lb_ctrl.add_child(_refresh_lb_btn)

	# Leaderboard Header Row
	var lb_hdr := HBoxContainer.new()
	lb_hdr.add_theme_constant_override("separation", 10)
	tab2.add_child(lb_hdr)
	_add_col_label(lb_hdr, "#", 46.0, UIThemeBuilder.COL_SLATE)
	_add_col_label(lb_hdr, "PLAYER", 180.0, UIThemeBuilder.COL_SLATE, true)
	_add_col_label(lb_hdr, "DIVISION", 105.0, UIThemeBuilder.COL_SLATE)
	_add_col_label(lb_hdr, "RATING", 74.0, UIThemeBuilder.COL_SLATE)
	_add_col_label(lb_hdr, "W-L", 74.0, UIThemeBuilder.COL_SLATE)
	_add_col_label(lb_hdr, "WIN%", 74.0, UIThemeBuilder.COL_SLATE)
	_add_col_label(lb_hdr, "PEAK", 74.0, UIThemeBuilder.COL_SLATE)
	_add_col_label(lb_hdr, "FAV CLASS", 110.0, UIThemeBuilder.COL_SLATE)

	var lb_scroll := ScrollContainer.new()
	lb_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab2.add_child(lb_scroll)
	_lb_list_vb = VBoxContainer.new()
	_lb_list_vb.name = "LeaderboardList"
	_lb_list_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lb_list_vb.add_theme_constant_override("separation", 4)
	lb_scroll.add_child(_lb_list_vb)


func _add_col_label(parent: HBoxContainer, txt: String, min_w: float, col: Color, expand: bool = false) -> void:
	var lbl := Label.new()
	lbl.text = txt
	lbl.custom_minimum_size = Vector2(min_w, 0.0)
	if expand:
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", 13)
	parent.add_child(lbl)
