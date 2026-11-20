class_name UIThemeBuilder
extends RefCounted
## Shared Cyber-Anime Sports UI Theme & Style Factory for PHANTOM COURT ONLINE (Phase 14).
## Provides consistent high-contrast Obsidian/Cyan/Crimson/Gold styling and canonical
## `/root/Main` navigation helpers across all menus, HUDs, lobbies, and rankings screens.

const COL_OBSIDIAN := Color("#0B0E17")
const COL_PANEL := Color("#121829")
const COL_PANEL_DARK := Color("#0D1220")
const COL_PANEL_LIGHT := Color("#1B2540")
const COL_CYAN := Color("#00F0FF")
const COL_CRIMSON := Color("#FF2A6D")
const COL_GOLD := Color("#FFD166")
const COL_EMERALD := Color("#00E5A3")
const COL_SLATE := Color("#8EA0C2")
const COL_BORDER_SUBTLE := Color(0.24, 0.34, 0.54, 0.72)
const COL_TEXT_PRIMARY := Color(0.96, 0.98, 1.0, 1.0)
const COL_TEXT_MUTED := Color("#8EA0C2")

const MAIN_MENU_ROUTES: Array[String] = [
	"main_menu",
	"character_select",
	"settings",
	"training",
	"matchmaking",
	"lobby",
	"profile_rankings",
	"play_offline",
	"play_online",
	"spectate",
	"quit",
]

const DIVISION_THRESHOLDS: Array[Dictionary] = [
	{"name": "Bronze",   "min": 0.0,    "max": 1200.0, "color": Color("#CD7F32")},
	{"name": "Silver",   "min": 1200.0, "max": 1400.0, "color": Color("#CBD5E1")},
	{"name": "Gold",     "min": 1400.0, "max": 1600.0, "color": Color("#FFD166")},
	{"name": "Platinum", "min": 1600.0, "max": 1800.0, "color": Color("#38BDF8")},
	{"name": "Diamond",  "min": 1800.0, "max": 2000.0, "color": Color("#A855F7")},
	{"name": "Master",   "min": 2000.0, "max": 2200.0, "color": Color("#FF2A6D")},
	{"name": "Phantom",  "min": 2200.0, "max": 2600.0, "color": Color("#00F0FF")},
]


static func build_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 14

	# Panel & PanelContainer
	var panel_sb: StyleBoxFlat = make_panel_style(COL_PANEL, COL_BORDER_SUBTLE, 2, 8, 14.0, 12.0)
	theme.set_stylebox("panel", "PanelContainer", panel_sb)
	theme.set_stylebox("panel", "Panel", panel_sb)

	# Button states
	var btn_normal: StyleBoxFlat = make_button_style(COL_PANEL_LIGHT, COL_BORDER_SUBTLE, 2, 0, 6)
	var btn_hover: StyleBoxFlat = make_button_style(Color("#223257"), COL_CYAN, 2, 0, 6)
	var btn_pressed: StyleBoxFlat = make_button_style(Color("#0D2A3F"), COL_GOLD, 2, 0, 6)
	var btn_disabled: StyleBoxFlat = make_button_style(Color(0.10, 0.12, 0.18, 0.72), Color(0.24, 0.28, 0.36, 0.45), 1, 0, 6)

	theme.set_stylebox("normal", "Button", btn_normal)
	theme.set_stylebox("hover", "Button", btn_hover)
	theme.set_stylebox("pressed", "Button", btn_pressed)
	theme.set_stylebox("focus", "Button", btn_hover)
	theme.set_stylebox("disabled", "Button", btn_disabled)
	theme.set_color("font_color", "Button", COL_TEXT_PRIMARY)
	theme.set_color("font_hover_color", "Button", COL_CYAN)
	theme.set_color("font_pressed_color", "Button", COL_GOLD)
	theme.set_color("font_disabled_color", "Button", Color(0.46, 0.52, 0.64, 0.75))

	# OptionButton
	theme.set_stylebox("normal", "OptionButton", btn_normal)
	theme.set_stylebox("hover", "OptionButton", btn_hover)
	theme.set_stylebox("pressed", "OptionButton", btn_pressed)
	theme.set_stylebox("disabled", "OptionButton", btn_disabled)
	theme.set_color("font_color", "OptionButton", COL_TEXT_PRIMARY)
	theme.set_color("font_hover_color", "OptionButton", COL_CYAN)

	# LineEdit
	var edit_normal: StyleBoxFlat = make_panel_style(COL_PANEL_DARK, COL_BORDER_SUBTLE, 2, 6, 10.0, 6.0)
	var edit_focus: StyleBoxFlat = make_panel_style(COL_PANEL_DARK, COL_CYAN, 2, 6, 10.0, 6.0)
	theme.set_stylebox("normal", "LineEdit", edit_normal)
	theme.set_stylebox("focus", "LineEdit", edit_focus)
	theme.set_color("font_color", "LineEdit", COL_TEXT_PRIMARY)
	theme.set_color("font_placeholder_color", "LineEdit", COL_SLATE)
	theme.set_color("caret_color", "LineEdit", COL_CYAN)

	# ProgressBar
	var pb_bg: StyleBoxFlat = make_bar_style(COL_PANEL_DARK, 4)
	pb_bg.border_color = COL_BORDER_SUBTLE
	pb_bg.set_border_width_all(1)
	var pb_fill: StyleBoxFlat = make_bar_style(COL_CYAN, 4)
	theme.set_stylebox("background", "ProgressBar", pb_bg)
	theme.set_stylebox("fill", "ProgressBar", pb_fill)
	theme.set_color("font_color", "ProgressBar", COL_TEXT_PRIMARY)

	# TabContainer
	var tab_panel: StyleBoxFlat = make_panel_style(COL_PANEL, COL_BORDER_SUBTLE, 2, 8, 14.0, 12.0)
	var tab_sel: StyleBoxFlat = make_button_style(COL_PANEL_LIGHT, COL_CYAN, 2, 0, 5)
	var tab_unsel: StyleBoxFlat = make_button_style(COL_PANEL_DARK, COL_BORDER_SUBTLE, 1, 0, 5)
	theme.set_stylebox("panel", "TabContainer", tab_panel)
	theme.set_stylebox("tab_selected", "TabContainer", tab_sel)
	theme.set_stylebox("tab_unselected", "TabContainer", tab_unsel)
	theme.set_stylebox("tab_hovered", "TabContainer", btn_hover)
	theme.set_color("font_selected_color", "TabContainer", COL_CYAN)
	theme.set_color("font_unselected_color", "TabContainer", COL_SLATE)

	# CheckBox / CheckButton / Label
	theme.set_color("font_color", "Label", COL_TEXT_PRIMARY)
	theme.set_color("font_color", "CheckBox", COL_TEXT_PRIMARY)
	theme.set_color("font_hover_color", "CheckBox", COL_CYAN)
	theme.set_color("font_color", "CheckButton", COL_TEXT_PRIMARY)
	theme.set_color("font_hover_color", "CheckButton", COL_CYAN)

	return theme


static func make_panel_style(
	bg_color: Color = COL_PANEL,
	border_color: Color = COL_BORDER_SUBTLE,
	border_width: int = 2,
	corner_radius: int = 8,
	pad_h: float = 14.0,
	pad_v: float = 12.0
) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_color
	sb.border_color = border_color
	sb.set_border_width_all(maxi(0, border_width))
	sb.set_corner_radius_all(maxi(0, corner_radius))
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	return sb


static func make_button_style(
	bg_color: Color = COL_PANEL_LIGHT,
	border_color: Color = COL_CYAN,
	border_width: int = 2,
	accent_stripe_left: int = 4,
	corner_radius: int = 6
) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_color
	sb.border_color = border_color
	sb.set_border_width_all(maxi(0, border_width))
	if accent_stripe_left > border_width:
		sb.border_width_left = accent_stripe_left
	sb.set_corner_radius_all(maxi(0, corner_radius))
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


static func make_accent_badge_style(
	accent_color: Color = COL_CYAN,
	bg_alpha: float = 0.22
) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(accent_color.r * 0.28, accent_color.g * 0.28, accent_color.b * 0.28, clampf(bg_alpha + 0.55, 0.35, 0.95))
	sb.border_color = accent_color
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	return sb


static func make_bar_style(fill_color: Color = COL_CYAN, corner_radius: int = 4) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill_color
	sb.set_corner_radius_all(maxi(0, corner_radius))
	return sb


static func apply_primary_cta_button(btn: Button, accent: Color = COL_CYAN) -> void:
	if btn == null:
		return
	var norm := make_button_style(Color(accent.r * 0.16, accent.g * 0.20, accent.b * 0.26, 0.94), accent, 2, 6, 6)
	var hov := make_button_style(Color(accent.r * 0.28, accent.g * 0.32, accent.b * 0.38, 0.98), accent.lerp(Color.WHITE, 0.35), 2, 8, 6)
	var prs := make_button_style(Color(accent.r * 0.10, accent.g * 0.14, accent.b * 0.20, 1.0), COL_GOLD, 2, 8, 6)
	btn.add_theme_stylebox_override("normal", norm)
	btn.add_theme_stylebox_override("hover", hov)
	btn.add_theme_stylebox_override("focus", hov)
	btn.add_theme_stylebox_override("pressed", prs)
	btn.add_theme_color_override("font_color", COL_TEXT_PRIMARY)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)


static func get_division_color(division: String) -> Color:
	var lower: String = division.strip_edges().to_lower()
	for entry in DIVISION_THRESHOLDS:
		if str(entry["name"]).to_lower() == lower:
			return entry["color"] as Color
	return COL_SLATE


static func compute_division_progress(rating: float, division: String = "") -> Dictionary:
	var chosen: Dictionary = DIVISION_THRESHOLDS[0]
	var lower: String = division.strip_edges().to_lower()
	if not lower.is_empty():
		for entry in DIVISION_THRESHOLDS:
			if str(entry["name"]).to_lower() == lower:
				chosen = entry
				break
	else:
		for entry in DIVISION_THRESHOLDS:
			if rating >= float(entry["min"]):
				chosen = entry
	var span: float = maxf(1.0, float(chosen["max"]) - float(chosen["min"]))
	var pct: float = clampf((rating - float(chosen["min"])) / span, 0.0, 1.0)
	return {
		"name": str(chosen["name"]),
		"color": chosen["color"] as Color,
		"progress": pct,
		"next_threshold": float(chosen["max"]),
	}


static func format_clock(seconds: float) -> String:
	var clamped: int = maxi(0, int(ceil(seconds)))
	@warning_ignore("integer_division")
	var mins: int = clamped / 60
	var secs: int = clamped % 60
	return "%02d:%02d" % [mins, secs]


static func get_autoload(node_name: String) -> Node:
	var ml: MainLoop = Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root != null:
		return (ml as SceneTree).root.get_node_or_null(node_name)
	return null


static func route_navigate(emitter: Node, route: String, params: Dictionary = {}) -> void:
	if emitter != null and emitter.has_signal("navigate_requested"):
		emitter.emit_signal("navigate_requested", route, params)
	var main_node: Node = get_autoload("Main")
	if main_node != null and is_instance_valid(main_node):
		if main_node.has_method("navigate_to"):
			main_node.call("navigate_to", route, params)


static func is_local_offline_build() -> bool:
	var gs: Node = get_autoload("GameState")
	if gs != null:
		if gs.has_method("is_local_offline_build"):
			return bool(gs.call("is_local_offline_build"))
		var flag: Variant = gs.get("offline_local_mode")
		if flag is bool:
			return flag as bool
	return OS.has_feature("ios") or OS.has_feature("mobile")


static func should_show_touch_controls() -> bool:
	var cm: Node = get_autoload("ConfigManager")
	if cm != null:
		if cm.has_method("should_show_touch_controls"):
			return bool(cm.call("should_show_touch_controls"))
		if cm.has_method("get_setting"):
			var mode: String = str(cm.call("get_setting", "gameplay", "touch_controls_mode", "auto")).strip_edges().to_lower()
			if mode == "on":
				return true
			if mode == "off":
				return false
	return OS.has_feature("ios") or OS.has_feature("mobile")


static func compute_safe_area_insets(
	viewport_size: Vector2,
	safe_rect: Rect2i,
	display_size: Vector2i = Vector2i.ZERO
) -> Dictionary:
	var zero_insets := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		return zero_insets
	if safe_rect.size.x <= 0 or safe_rect.size.y <= 0:
		return zero_insets

	var sx: float = 1.0
	var sy: float = 1.0
	if display_size.x > 0 and display_size.y > 0:
		sx = viewport_size.x / float(display_size.x)
		sy = viewport_size.y / float(display_size.y)

	var left: float = float(safe_rect.position.x) * sx
	var top: float = float(safe_rect.position.y) * sy
	var right_edge: float = float(safe_rect.position.x + safe_rect.size.x) * sx
	var bottom_edge: float = float(safe_rect.position.y + safe_rect.size.y) * sy
	var right: float = viewport_size.x - right_edge
	var bottom: float = viewport_size.y - bottom_edge

	var max_x: float = viewport_size.x * 0.25
	var max_y: float = viewport_size.y * 0.25
	return {
		"left": clampf(left, 0.0, max_x),
		"top": clampf(top, 0.0, max_y),
		"right": clampf(right, 0.0, max_x),
		"bottom": clampf(bottom, 0.0, max_y),
	}


static func get_current_safe_area_insets(node: Node = null) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	var safe_rect: Rect2i = DisplayServer.get_display_safe_area()
	var win_sz: Vector2i = DisplayServer.window_get_size()
	var vp_sz := Vector2(1280.0, 720.0)
	if node != null and is_instance_valid(node) and node.is_inside_tree():
		var vp: Viewport = node.get_viewport()
		if vp != null:
			var vr: Rect2 = vp.get_visible_rect()
			if vr.size.x > 1.0 and vr.size.y > 1.0:
				vp_sz = vr.size
	return compute_safe_area_insets(vp_sz, safe_rect, win_sz)


static func apply_safe_area_margins(
	margin_container: Control,
	base_padding: int = 12,
	extra_insets: Dictionary = {}
) -> Dictionary:
	var insets: Dictionary = extra_insets if not extra_insets.is_empty() else get_current_safe_area_insets(margin_container)
	if margin_container == null or not is_instance_valid(margin_container):
		return insets

	var l: int = int(round(float(insets.get("left", 0.0))))
	var t: int = int(round(float(insets.get("top", 0.0))))
	var r: int = int(round(float(insets.get("right", 0.0))))
	var b: int = int(round(float(insets.get("bottom", 0.0))))

	if margin_container is MarginContainer:
		var mc := margin_container as MarginContainer
		var base_l: int = mc.get_theme_constant("margin_left") if mc.has_theme_constant_override("margin_left") else base_padding
		var base_t: int = mc.get_theme_constant("margin_top") if mc.has_theme_constant_override("margin_top") else base_padding
		var base_r: int = mc.get_theme_constant("margin_right") if mc.has_theme_constant_override("margin_right") else base_padding
		var base_b: int = mc.get_theme_constant("margin_bottom") if mc.has_theme_constant_override("margin_bottom") else base_padding
		if not mc.has_meta("_safe_base_margins"):
			mc.set_meta("_safe_base_margins", Vector4i(base_l, base_t, base_r, base_b))
		var stored: Vector4i = mc.get_meta("_safe_base_margins") as Vector4i
		mc.add_theme_constant_override("margin_left", stored.x + l)
		mc.add_theme_constant_override("margin_top", stored.y + t)
		mc.add_theme_constant_override("margin_right", stored.z + r)
		mc.add_theme_constant_override("margin_bottom", stored.w + b)
	else:
		margin_container.offset_left = float(l)
		margin_container.offset_top = float(t)
		margin_container.offset_right = -float(r)
		margin_container.offset_bottom = -float(b)
	return insets
