class_name HUDController
extends CanvasLayer
## Phase 14 — Broadcast Cyber-Anime In-Match HUD for PHANTOM COURT ONLINE.
## Displays top broadcast scoreboard & 24s shot clock, slanted Stamina & THE ZONE meters,
## shot timing release feedback, kinetic combo feed callouts, online telemetry pill, and
## Spectator Mode indicator. Automatically reacts to all canonical EventBus signals.

const CLUTCH_SHOT_CLOCK_SEC: float = 5.0
const EXHAUSTED_STAMINA_PCT: float = 20.0

var _ui_built: bool = false
var _tracked_player_id: int = 1

var _score_a: int = 0
var _score_b: int = 0
var _clock_text: String = "03:00"
var _shot_clock_text: String = "24.0"
var _possession_team: int = 0
var _stamina_pct: float = 100.0
var _zone_pct: float = 0.0
var _zone_active: bool = false
var _zone_time_left: float = 0.0
var _combo_callout_text: String = ""
var _combo_callout_timer: float = 0.0
var _shot_feedback_text: String = ""
var _shot_feedback_timer: float = 0.0
var _net_pill_text: String = ""
var _spectator_mode: bool = false
var _pulse_time: float = 0.0

var _hud_root: Control = null
var _score_a_label: Label = null
var _score_b_label: Label = null
var _clock_label: Label = null
var _shot_clock_label: Label = null
var _possession_label: Label = null
var _stamina_bar: ProgressBar = null
var _stamina_fill: StyleBoxFlat = null
var _stamina_val_label: Label = null
var _zone_bar: ProgressBar = null
var _zone_fill: StyleBoxFlat = null
var _zone_status_label: Label = null
var _shot_feedback_panel: PanelContainer = null
var _shot_feedback_label: Label = null
var _combo_feed_panel: PanelContainer = null
var _combo_feed_label: Label = null
var _net_pill_panel: PanelContainer = null
var _net_pill_label: Label = null
var _spectator_panel: PanelContainer = null
var _spectator_label: Label = null


func _enter_tree() -> void:
	_connect_event_bus()


func _ready() -> void:
	layer = 10
	add_to_group("full_hud")
	add_to_group("match_hud")
	_ensure_ui_built()
	_connect_event_bus()
	_sync_initial_state()


func _exit_tree() -> void:
	_disconnect_event_bus()


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	_pulse_time += delta

	if _zone_active and _zone_time_left > 0.0:
		_zone_time_left = maxf(0.0, _zone_time_left - delta)
		if _zone_status_label != null:
			_zone_status_label.text = "ZONE AWAKENED  •  %.1fs" % _zone_time_left

	if _combo_callout_timer > 0.0:
		_combo_callout_timer = maxf(0.0, _combo_callout_timer - delta)
		if _combo_callout_timer <= 0.0 and _combo_feed_panel != null:
			_combo_feed_panel.visible = false

	if _shot_feedback_timer > 0.0:
		_shot_feedback_timer = maxf(0.0, _shot_feedback_timer - delta)
		if _shot_feedback_timer <= 0.0 and _shot_feedback_panel != null:
			_shot_feedback_panel.visible = false

	# Pulse exhausted stamina bar & Zone ready/active label
	if _stamina_fill != null and _stamina_pct < EXHAUSTED_STAMINA_PCT:
		var pulse: float = 0.5 + 0.5 * sin(_pulse_time * 9.0)
		_stamina_fill.bg_color = UIThemeBuilder.COL_GOLD.lerp(UIThemeBuilder.COL_CRIMSON, pulse)
	if _zone_fill != null and (_zone_active or _zone_pct >= 99.5):
		var z_pulse: float = 0.5 + 0.5 * sin(_pulse_time * 7.5)
		_zone_fill.bg_color = UIThemeBuilder.COL_CYAN.lerp(UIThemeBuilder.COL_GOLD, z_pulse * 0.65)


# ==============================================================================
# Public Configuration & QA Inspection Getters
# ==============================================================================

func set_tracked_player_id(player_id: int) -> void:
	_tracked_player_id = player_id


func set_spectator_mode(enabled: bool) -> void:
	_ensure_ui_built()
	_spectator_mode = enabled
	if _spectator_panel != null:
		_spectator_panel.visible = enabled


func is_spectator_banner_visible() -> bool:
	_ensure_ui_built()
	return _spectator_panel != null and _spectator_panel.visible


func get_displayed_score_a() -> int:
	return _score_a


func get_displayed_score_b() -> int:
	return _score_b


func get_displayed_clock() -> String:
	return _clock_text


func get_displayed_shot_clock() -> String:
	return _shot_clock_text


func get_displayed_combo_callout() -> String:
	return _combo_callout_text


func get_displayed_shot_feedback() -> String:
	return _shot_feedback_text


func get_zone_percent() -> float:
	return _zone_pct


func get_stamina_percent() -> float:
	return _stamina_pct


func get_net_pill_text() -> String:
	return _net_pill_text


func is_zone_ready_displayed() -> bool:
	return (not _zone_active) and _zone_pct >= 99.5


func is_zone_active_displayed() -> bool:
	return _zone_active


# ==============================================================================
# EventBus Signal Handlers
# ==============================================================================

func _on_score_changed(team_id: int, new_score: int, delta: int, is_three: bool, _scorer_id: int) -> void:
	_ensure_ui_built()
	if team_id == 0:
		_score_a = maxi(0, new_score)
		_score_a_label.text = str(_score_a)
	elif team_id == 1:
		_score_b = maxi(0, new_score)
		_score_b_label.text = str(_score_b)
	if delta > 0:
		_show_combo_callout("SPLASH! +3 POINTS!" if is_three else "BUCKET! +%d PTS!" % delta, UIThemeBuilder.COL_GOLD if is_three else UIThemeBuilder.COL_EMERALD)


func _on_timer_updated(match_seconds_left: float, shot_clock_left: float) -> void:
	_ensure_ui_built()
	_clock_text = UIThemeBuilder.format_clock(match_seconds_left)
	_shot_clock_text = "%.1f" % maxf(0.0, shot_clock_left)
	_clock_label.text = _clock_text
	_shot_clock_label.text = _shot_clock_text
	var is_clutch: bool = shot_clock_left < CLUTCH_SHOT_CLOCK_SEC
	_shot_clock_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CRIMSON if is_clutch else UIThemeBuilder.COL_GOLD)


func _on_possession_changed(team_id: int, _carrier_id: int) -> void:
	_ensure_ui_built()
	_possession_team = team_id
	if team_id == 0:
		_possession_label.text = "◀ TEAM A POSSESSION"
		_possession_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	elif team_id == 1:
		_possession_label.text = "TEAM B POSSESSION ▶"
		_possession_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CRIMSON)
	else:
		_possession_label.text = "LOOSE BALL"
		_possession_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)


func _on_stamina_updated(player_id: int, current: float, maximum: float) -> void:
	if player_id != _tracked_player_id:
		return
	_ensure_ui_built()
	var pct: float = clampf((current / maxf(1.0, maximum)) * 100.0, 0.0, 100.0)
	_stamina_pct = pct
	_stamina_bar.value = pct
	_stamina_val_label.text = "%d%%" % int(round(pct))
	if pct >= EXHAUSTED_STAMINA_PCT:
		_stamina_fill.bg_color = UIThemeBuilder.COL_EMERALD


func _on_zone_meter_updated(player_id: int, current: float, maximum: float) -> void:
	if player_id != _tracked_player_id:
		return
	_ensure_ui_built()
	var pct: float = clampf((current / maxf(1.0, maximum)) * 100.0, 0.0, 100.0)
	_zone_pct = pct
	_zone_bar.value = pct
	_refresh_zone_label()


func _on_zone_activated(player_id: int, duration: float) -> void:
	if player_id != _tracked_player_id:
		return
	_ensure_ui_built()
	_zone_active = true
	_zone_time_left = maxf(0.0, duration)
	_zone_pct = 100.0
	_zone_bar.value = 100.0
	_refresh_zone_label()
	_show_combo_callout("THE ZONE AWAKENED!", UIThemeBuilder.COL_CYAN)


func _on_zone_ended(player_id: int) -> void:
	if player_id != _tracked_player_id:
		return
	_ensure_ui_built()
	_zone_active = false
	_zone_time_left = 0.0
	_zone_pct = 0.0
	_zone_bar.value = 0.0
	_zone_fill.bg_color = UIThemeBuilder.COL_CYAN
	_refresh_zone_label()


func _on_combo_triggered(player_id: int, combo_id: String, combo_tier: int, is_perfect: bool) -> void:
	if player_id != _tracked_player_id:
		return
	var pretty: String = combo_id.replace("_", " ").strip_edges().to_upper()
	var chain_txt: String = ("  •  x%d CHAIN" % combo_tier) if combo_tier > 1 else ""
	var perf_txt: String = "  ★ PERFECT!" if is_perfect else ""
	_show_combo_callout("%s!%s%s" % [pretty, chain_txt, perf_txt], UIThemeBuilder.COL_GOLD if is_perfect else UIThemeBuilder.COL_CYAN)


func _on_shot_timing_feedback(player_id: int, label: String, timing_error: float) -> void:
	if player_id != _tracked_player_id:
		return
	_ensure_ui_built()
	var upper: String = label.strip_edges().to_upper()
	var ms: float = timing_error * 1000.0
	_shot_feedback_text = (
		"★ PERFECT RELEASE! (%+.0fms) ★" % ms
		if upper == "PERFECT"
		else "%s RELEASE (%+.0fms)" % [upper, ms]
	)
	_shot_feedback_label.text = _shot_feedback_text
	var col: Color = UIThemeBuilder.COL_EMERALD if upper == "PERFECT" else (UIThemeBuilder.COL_CYAN if upper == "GOOD" else (UIThemeBuilder.COL_GOLD if upper == "EARLY" else UIThemeBuilder.COL_CRIMSON))
	_shot_feedback_label.add_theme_color_override("font_color", col)
	_shot_feedback_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(col, 0.28))
	_shot_feedback_panel.visible = true
	_shot_feedback_timer = 1.6


func _on_ankle_broken(_victim_id: int, _attacker_id: int, _world_pos: Vector3) -> void:
	_show_combo_callout("ANKLES BROKEN!", UIThemeBuilder.COL_GOLD)


func _on_block_performed(_blocker_id: int, _shooter_id: int, _world_pos: Vector3) -> void:
	_show_combo_callout("REJECTED! MONSTER BLOCK!", UIThemeBuilder.COL_CRIMSON)


func _on_steal_performed(_stealer_id: int, _victim_id: int, _world_pos: Vector3) -> void:
	_show_combo_callout("CLEAN STEAL!", UIThemeBuilder.COL_EMERALD)


func _on_net_metrics_updated(metrics: Dictionary) -> void:
	_ensure_ui_built()
	var rtt: float = float(metrics.get("rtt_ms", 0.0))
	var loss: float = float(metrics.get("packet_loss_pct", 0.0))
	var interp: float = float(metrics.get("interp_delay_ms", 0.0))
	_net_pill_text = "RTT %.0fms  |  Loss %.1f%%  |  Interp %.0fms" % [rtt, loss, interp]
	_net_pill_label.text = _net_pill_text
	_net_pill_panel.visible = true


func _on_match_restarted() -> void:
	_ensure_ui_built()
	_score_a = 0
	_score_b = 0
	_score_a_label.text = "0"
	_score_b_label.text = "0"
	_stamina_pct = 100.0
	_stamina_bar.value = 100.0
	_stamina_val_label.text = "100%"
	_zone_active = false
	_zone_time_left = 0.0
	_zone_pct = 0.0
	_zone_bar.value = 0.0
	_refresh_zone_label()
	_combo_callout_text = ""
	_combo_callout_timer = 0.0
	_combo_feed_panel.visible = false
	_shot_feedback_text = ""
	_shot_feedback_timer = 0.0
	_shot_feedback_panel.visible = false


func _show_combo_callout(text: String, accent: Color) -> void:
	_ensure_ui_built()
	_combo_callout_text = text
	_combo_feed_label.text = text
	_combo_feed_label.add_theme_color_override("font_color", accent)
	_combo_feed_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(accent, 0.28))
	_combo_feed_panel.visible = true
	_combo_callout_timer = 1.9


func _refresh_zone_label() -> void:
	if _zone_status_label == null:
		return
	if _zone_active:
		_zone_status_label.text = "ZONE AWAKENED  •  %.1fs" % _zone_time_left
		_zone_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	elif _zone_pct >= 99.5:
		_zone_status_label.text = "PRESS [V] — ZONE READY"
		_zone_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	else:
		_zone_status_label.text = "THE ZONE  %d%%" % int(round(_zone_pct))
		_zone_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)


func _sync_initial_state() -> void:
	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null:
		if gs.get("local_player_id") != null:
			_tracked_player_id = int(gs.get("local_player_id"))
		if gs.get("scores") is Array and (gs.get("scores") as Array).size() >= 2:
			_score_a = int((gs.get("scores") as Array)[0])
			_score_b = int((gs.get("scores") as Array)[1])
			_score_a_label.text = str(_score_a)
			_score_b_label.text = str(_score_b)
		if gs.get("match_seconds_left") != null and gs.get("shot_clock_left") != null:
			_on_timer_updated(float(gs.get("match_seconds_left")), float(gs.get("shot_clock_left")))
		var online: bool = bool(gs.get("is_online"))
		if _net_pill_panel != null:
			_net_pill_panel.visible = online
			if online and _net_pill_text.is_empty():
				_net_pill_text = "RTT --ms  |  Loss 0.0%  |  Interp --ms"
				_net_pill_label.text = _net_pill_text

	var nc: Node = UIThemeBuilder.get_autoload("NetClient")
	if nc != null and bool(nc.get("is_spectator")):
		set_spectator_mode(true)


# ==============================================================================
# UI Construction & EventBus Plumbing
# ==============================================================================

func _ensure_ui_built() -> void:
	if _ui_built:
		return
	_ui_built = true

	_hud_root = Control.new()
	_hud_root.name = "HUDRoot"
	_hud_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_root.theme = UIThemeBuilder.build_theme()
	add_child(_hud_root)
	UIThemeBuilder.apply_safe_area_margins(_hud_root, 0)

	# 1. Top-Center Broadcast Scoreboard
	var sb_panel := PanelContainer.new()
	sb_panel.name = "BroadcastScoreboard"
	sb_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sb_panel.anchor_left = 0.5
	sb_panel.anchor_right = 0.5
	sb_panel.offset_left = -250.0
	sb_panel.offset_right = 250.0
	sb_panel.offset_top = 12.0
	sb_panel.offset_bottom = 78.0
	sb_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(Color(0.04, 0.06, 0.12, 0.88), UIThemeBuilder.COL_CYAN, 2, 10, 16.0, 6.0))
	_hud_root.add_child(sb_panel)

	var sb_vb := VBoxContainer.new()
	sb_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sb_vb.add_theme_constant_override("separation", 2)
	sb_panel.add_child(sb_vb)

	var sb_row := HBoxContainer.new()
	sb_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sb_row.alignment = BoxContainer.ALIGNMENT_CENTER
	sb_row.add_theme_constant_override("separation", 14)
	sb_vb.add_child(sb_row)

	var ta_tag := Label.new()
	ta_tag.text = "TEAM A"
	ta_tag.add_theme_font_size_override("font_size", 13)
	ta_tag.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	sb_row.add_child(ta_tag)

	_score_a_label = Label.new()
	_score_a_label.name = "ScoreALabel"
	_score_a_label.text = "0"
	_score_a_label.custom_minimum_size = Vector2(44.0, 0.0)
	_score_a_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_a_label.add_theme_font_size_override("font_size", 28)
	sb_row.add_child(_score_a_label)

	var clk_vb := VBoxContainer.new()
	clk_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clk_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	sb_row.add_child(clk_vb)

	_clock_label = Label.new()
	_clock_label.name = "MatchClockLabel"
	_clock_label.text = "03:00"
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_label.add_theme_font_size_override("font_size", 18)
	clk_vb.add_child(_clock_label)

	var sc_row := HBoxContainer.new()
	sc_row.alignment = BoxContainer.ALIGNMENT_CENTER
	sc_row.add_theme_constant_override("separation", 4)
	clk_vb.add_child(sc_row)
	var sc_tag := Label.new()
	sc_tag.text = "SHOT"
	sc_tag.add_theme_font_size_override("font_size", 10)
	sc_tag.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	sc_row.add_child(sc_tag)

	_shot_clock_label = Label.new()
	_shot_clock_label.name = "ShotClockLabel"
	_shot_clock_label.text = "24.0"
	_shot_clock_label.add_theme_font_size_override("font_size", 13)
	_shot_clock_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	sc_row.add_child(_shot_clock_label)

	_score_b_label = Label.new()
	_score_b_label.name = "ScoreBLabel"
	_score_b_label.text = "0"
	_score_b_label.custom_minimum_size = Vector2(44.0, 0.0)
	_score_b_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_b_label.add_theme_font_size_override("font_size", 28)
	sb_row.add_child(_score_b_label)

	var tb_tag := Label.new()
	tb_tag.text = "TEAM B"
	tb_tag.add_theme_font_size_override("font_size", 13)
	tb_tag.add_theme_color_override("font_color", UIThemeBuilder.COL_CRIMSON)
	sb_row.add_child(tb_tag)

	_possession_label = Label.new()
	_possession_label.name = "PossessionLabel"
	_possession_label.text = "◀ TEAM A POSSESSION"
	_possession_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_possession_label.add_theme_font_size_override("font_size", 11)
	_possession_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	sb_vb.add_child(_possession_label)

	# 2. Bottom-Left Stamina & THE ZONE Meters
	var meters_panel := PanelContainer.new()
	meters_panel.name = "PlayerMetersPanel"
	meters_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meters_panel.anchor_top = 1.0
	meters_panel.anchor_bottom = 1.0
	meters_panel.offset_left = 20.0
	meters_panel.offset_right = 330.0
	meters_panel.offset_top = -124.0
	meters_panel.offset_bottom = -18.0
	meters_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(Color(0.04, 0.06, 0.12, 0.85), UIThemeBuilder.COL_BORDER_SUBTLE, 2, 8, 12.0, 10.0))
	_hud_root.add_child(meters_panel)

	var m_vb := VBoxContainer.new()
	m_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m_vb.add_theme_constant_override("separation", 6)
	meters_panel.add_child(m_vb)

	var st_hdr := HBoxContainer.new()
	m_vb.add_child(st_hdr)
	var st_lbl := Label.new()
	st_lbl.text = "STAMINA"
	st_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	st_lbl.add_theme_font_size_override("font_size", 11)
	st_lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	st_hdr.add_child(st_lbl)
	_stamina_val_label = Label.new()
	_stamina_val_label.text = "100%"
	_stamina_val_label.add_theme_font_size_override("font_size", 11)
	_stamina_val_label.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD)
	st_hdr.add_child(_stamina_val_label)

	_stamina_bar = ProgressBar.new()
	_stamina_bar.name = "StaminaBar"
	_stamina_bar.min_value = 0.0
	_stamina_bar.max_value = 100.0
	_stamina_bar.value = 100.0
	_stamina_bar.show_percentage = false
	_stamina_bar.custom_minimum_size = Vector2(0.0, 14.0)
	_stamina_fill = UIThemeBuilder.make_bar_style(UIThemeBuilder.COL_EMERALD, 4)
	_stamina_bar.add_theme_stylebox_override("fill", _stamina_fill)
	m_vb.add_child(_stamina_bar)

	_zone_status_label = Label.new()
	_zone_status_label.name = "ZoneStatusLabel"
	_zone_status_label.text = "THE ZONE  0%"
	_zone_status_label.add_theme_font_size_override("font_size", 12)
	_zone_status_label.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	m_vb.add_child(_zone_status_label)

	_zone_bar = ProgressBar.new()
	_zone_bar.name = "ZoneBar"
	_zone_bar.min_value = 0.0
	_zone_bar.max_value = 100.0
	_zone_bar.value = 0.0
	_zone_bar.show_percentage = false
	_zone_bar.custom_minimum_size = Vector2(0.0, 16.0)
	_zone_fill = UIThemeBuilder.make_bar_style(UIThemeBuilder.COL_CYAN, 4)
	_zone_bar.add_theme_stylebox_override("fill", _zone_fill)
	m_vb.add_child(_zone_bar)

	# 3. Center-Bottom Shot Timing & Kinetic Combo Feed
	_combo_feed_panel = PanelContainer.new()
	_combo_feed_panel.name = "ComboFeedBanner"
	_combo_feed_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_combo_feed_panel.anchor_left = 0.5
	_combo_feed_panel.anchor_right = 0.5
	_combo_feed_panel.anchor_top = 1.0
	_combo_feed_panel.anchor_bottom = 1.0
	_combo_feed_panel.offset_left = -220.0
	_combo_feed_panel.offset_right = 220.0
	_combo_feed_panel.offset_top = -132.0
	_combo_feed_panel.offset_bottom = -88.0
	_combo_feed_panel.visible = false
	_hud_root.add_child(_combo_feed_panel)

	_combo_feed_label = Label.new()
	_combo_feed_label.name = "ComboFeedLabel"
	_combo_feed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combo_feed_label.add_theme_font_size_override("font_size", 20)
	_combo_feed_panel.add_child(_combo_feed_label)

	_shot_feedback_panel = PanelContainer.new()
	_shot_feedback_panel.name = "ShotFeedbackBanner"
	_shot_feedback_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shot_feedback_panel.anchor_left = 0.5
	_shot_feedback_panel.anchor_right = 0.5
	_shot_feedback_panel.anchor_top = 1.0
	_shot_feedback_panel.anchor_bottom = 1.0
	_shot_feedback_panel.offset_left = -180.0
	_shot_feedback_panel.offset_right = 180.0
	_shot_feedback_panel.offset_top = -78.0
	_shot_feedback_panel.offset_bottom = -38.0
	_shot_feedback_panel.visible = false
	_hud_root.add_child(_shot_feedback_panel)

	_shot_feedback_label = Label.new()
	_shot_feedback_label.name = "ShotFeedbackLabel"
	_shot_feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shot_feedback_label.add_theme_font_size_override("font_size", 15)
	_shot_feedback_panel.add_child(_shot_feedback_label)

	# 4. Top-Right Online Telemetry Pill & Spectator Banner
	var tr_vb := VBoxContainer.new()
	tr_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr_vb.anchor_left = 1.0
	tr_vb.anchor_right = 1.0
	tr_vb.offset_left = -320.0
	tr_vb.offset_right = -16.0
	tr_vb.offset_top = 14.0
	tr_vb.offset_bottom = 100.0
	tr_vb.add_theme_constant_override("separation", 6)
	_hud_root.add_child(tr_vb)

	_net_pill_panel = PanelContainer.new()
	_net_pill_panel.name = "NetTelemetryPill"
	_net_pill_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_net_pill_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_CYAN, 0.18))
	_net_pill_panel.visible = false
	tr_vb.add_child(_net_pill_panel)

	_net_pill_label = Label.new()
	_net_pill_label.name = "NetTelemetryLabel"
	_net_pill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_net_pill_label.add_theme_font_size_override("font_size", 12)
	_net_pill_panel.add_child(_net_pill_label)

	_spectator_panel = PanelContainer.new()
	_spectator_panel.name = "SpectatorModeBanner"
	_spectator_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spectator_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(UIThemeBuilder.COL_GOLD, 0.25))
	_spectator_panel.visible = false
	tr_vb.add_child(_spectator_panel)

	_spectator_label = Label.new()
	_spectator_label.name = "SpectatorLabel"
	_spectator_label.text = "SPECTATOR MODE — LIVE BROADCAST"
	_spectator_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spectator_label.add_theme_font_size_override("font_size", 12)
	_spectator_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	_spectator_panel.add_child(_spectator_label)


func _connect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb == null:
		return
	var pairs: Array = [
		["score_changed", _on_score_changed],
		["timer_updated", _on_timer_updated],
		["possession_changed", _on_possession_changed],
		["stamina_updated", _on_stamina_updated],
		["zone_meter_updated", _on_zone_meter_updated],
		["zone_activated", _on_zone_activated],
		["zone_ended", _on_zone_ended],
		["combo_triggered", _on_combo_triggered],
		["shot_timing_feedback", _on_shot_timing_feedback],
		["ankle_broken", _on_ankle_broken],
		["block_performed", _on_block_performed],
		["steal_performed", _on_steal_performed],
		["net_metrics_updated", _on_net_metrics_updated],
		["match_restarted", _on_match_restarted],
	]
	for p in pairs:
		if eb.has_signal(p[0]) and not eb.is_connected(p[0], p[1]):
			eb.connect(p[0], p[1])


func _disconnect_event_bus() -> void:
	var eb: Node = UIThemeBuilder.get_autoload("EventBus")
	if eb == null:
		return
	var pairs: Array = [
		["score_changed", _on_score_changed],
		["timer_updated", _on_timer_updated],
		["possession_changed", _on_possession_changed],
		["stamina_updated", _on_stamina_updated],
		["zone_meter_updated", _on_zone_meter_updated],
		["zone_activated", _on_zone_activated],
		["zone_ended", _on_zone_ended],
		["combo_triggered", _on_combo_triggered],
		["shot_timing_feedback", _on_shot_timing_feedback],
		["ankle_broken", _on_ankle_broken],
		["block_performed", _on_block_performed],
		["steal_performed", _on_steal_performed],
		["net_metrics_updated", _on_net_metrics_updated],
		["match_restarted", _on_match_restarted],
	]
	for p in pairs:
		if eb.has_signal(p[0]) and eb.is_connected(p[0], p[1]):
			eb.disconnect(p[0], p[1])
