class_name CharacterSelectUI
extends Control
## Phase 14 — Anime Roster & Match Setup Screen for PHANTOM COURT ONLINE.
## Populates all 5 original ArchetypeRegistry ballers with a live rotating 3D SubViewport
## CharacterAnimator turntable, 6 stat bars, strengths/weaknesses, unique signature skill card,
## Match Mode (1v1/2v2/3v3), and AI Difficulty (Rookie/Pro/All-Star/Phantom) selectors.

signal navigate_requested(route: String, params: Dictionary)

const MODE_OPTIONS: Array[String] = ["1v1", "2v2", "3v3"]
const DIFFICULTY_OPTIONS: Array[String] = ["Rookie", "Pro", "All-Star", "Phantom"]
const STAT_KEYS: Array[Dictionary] = [
	{"key": "speed", "label": "SPEED"},
	{"key": "shooting", "label": "SHOOTING"},
	{"key": "dunk", "label": "DUNK"},
	{"key": "playmaking", "label": "PLAYMAKING"},
	{"key": "defense", "label": "DEFENSE"},
	{"key": "stamina", "label": "STAMINA"},
]

var _ui_built: bool = false
var _selected_archetype_id: String = "speedster"
var _selected_mode: String = "3v3"
var _selected_difficulty_tier: int = 1 # Pro
var _move_db: MoveDatabase = MoveDatabase.new()

var _roster_buttons: Dictionary = {} # arch_id -> Button
var _preview_viewport: SubViewport = null
var _preview_turntable: Node3D = null
var _preview_animator: CharacterAnimator = null

var _char_name_label: Label = null
var _char_class_label: Label = null
var _tagline_label: Label = null
var _stat_bars: Dictionary = {} # key -> {bar: ProgressBar, val: Label}
var _strengths_label: Label = null
var _weaknesses_label: Label = null
var _skill_title_label: Label = null
var _skill_seq_label: Label = null
var _skill_card_panel: PanelContainer = null
var _mode_option: OptionButton = null
var _diff_option: OptionButton = null
var _start_btn: Button = null
var _back_btn: Button = null


func _ready() -> void:
	_ensure_ui_built()
	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null and gs.get("selected_archetype") != null:
		var resolved: String = ArchetypeRegistry.resolve_id(str(gs.get("selected_archetype")))
		if ArchetypeRegistry.has_archetype(resolved):
			_selected_archetype_id = resolved
	select_archetype(_selected_archetype_id)


func _process(delta: float) -> void:
	if delta > 0.0 and _preview_turntable != null and is_instance_valid(_preview_turntable):
		_preview_turntable.rotation.y = wrapf(_preview_turntable.rotation.y + delta * 0.72, -PI, PI)


func get_selected_archetype_id() -> String:
	return _selected_archetype_id


func get_selected_mode() -> String:
	return _selected_mode


func get_selected_difficulty_tier() -> int:
	return _selected_difficulty_tier


func get_preview_animator() -> CharacterAnimator:
	_ensure_ui_built()
	return _preview_animator


func get_roster_count() -> int:
	return _roster_buttons.size()


func select_archetype(arch_id: String) -> void:
	_ensure_ui_built()
	var resolved: String = ArchetypeRegistry.resolve_id(arch_id)
	var arch_dict: Dictionary = ArchetypeRegistry.get_archetype_dict(resolved)
	if arch_dict.is_empty():
		return

	_selected_archetype_id = resolved
	var colors: Dictionary = arch_dict.get("colors", {})
	var accent: Color = colors.get("aura", UIThemeBuilder.COL_CYAN) as Color

	for id_key in _roster_buttons.keys():
		var btn: Button = _roster_buttons[id_key] as Button
		if id_key == resolved:
			UIThemeBuilder.apply_primary_cta_button(btn, accent)
		else:
			var sb: StyleBoxFlat = UIThemeBuilder.make_button_style(UIThemeBuilder.COL_PANEL_DARK, UIThemeBuilder.COL_BORDER_SUBTLE, 1, 3, 6)
			btn.add_theme_stylebox_override("normal", sb)

	_char_name_label.text = str(arch_dict.get("character_name", resolved.capitalize()))
	_char_class_label.text = str(arch_dict.get("class_name_display", "")).to_upper()
	_char_class_label.add_theme_color_override("font_color", accent)
	_tagline_label.text = str(arch_dict.get("tagline", ""))

	# Update 6 stat progress bars
	var ratings: Dictionary = arch_dict.get("rating_bars", {})
	for spec in STAT_KEYS:
		var k: String = str(spec["key"])
		var score: float = clampf(float(ratings.get(k, 75.0)), 0.0, 100.0)
		var entry: Dictionary = _stat_bars[k]
		var bar: ProgressBar = entry["bar"] as ProgressBar
		var v_lbl: Label = entry["val"] as Label
		bar.value = score
		bar.add_theme_stylebox_override("fill", UIThemeBuilder.make_bar_style(accent, 4))
		v_lbl.text = "%d" % int(round(score))

	# Strengths & Weaknesses
	var str_lines: PackedStringArray = PackedStringArray()
	for s in arch_dict.get("strengths", []):
		str_lines.append("+ %s" % str(s))
	_strengths_label.text = "\n".join(str_lines)

	var weak_lines: PackedStringArray = PackedStringArray()
	for w in arch_dict.get("weaknesses", []):
		weak_lines.append("- %s" % str(w))
	_weaknesses_label.text = "\n".join(weak_lines)

	# Unique signature combo card
	var skill_id: String = str(arch_dict.get("unique_skill_id", ""))
	var move_fd: FrameData = _move_db.get_move(skill_id)
	if move_fd != null:
		_skill_title_label.text = "SIGNATURE SKILL: %s" % move_fd.display_name.to_upper()
		_skill_seq_label.text = "INPUT: [ %s ]  •  STAMINA: %.0f  •  ZONE GAIN: +%.0f" % [
			" → ".join(move_fd.sequence),
			move_fd.stamina_cost,
			move_fd.zone_gain,
		]
	else:
		_skill_title_label.text = "SIGNATURE SKILL: %s" % skill_id.to_upper()
		_skill_seq_label.text = ""
	_skill_card_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_accent_badge_style(accent, 0.22))

	# Update live 3D CharacterAnimator preview rig
	if _preview_animator != null and is_instance_valid(_preview_animator):
		var rscale: Vector3 = arch_dict.get("rig_scale", Vector3.ONE) as Vector3
		var anim_var: Dictionary = arch_dict.get("anim_variation", {})
		_preview_animator.apply_archetype_visuals(colors, rscale, anim_var)


func _on_start_match_pressed() -> void:
	_selected_mode = MODE_OPTIONS[clampi(_mode_option.selected, 0, MODE_OPTIONS.size() - 1)]
	_selected_difficulty_tier = clampi(_diff_option.selected, 0, DIFFICULTY_OPTIONS.size() - 1)

	var gs: Node = UIThemeBuilder.get_autoload("GameState")
	if gs != null:
		gs.set("selected_archetype", _selected_archetype_id)
		gs.set("match_mode", "offline_" + _selected_mode)
		gs.set("is_online", false)

	UIThemeBuilder.route_navigate(self, "play_offline", {
		"archetype": _selected_archetype_id,
		"mode": _selected_mode,
		"difficulty_tier": _selected_difficulty_tier,
		"difficulty": DIFFICULTY_OPTIONS[_selected_difficulty_tier],
	})


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
	root_vb.add_theme_constant_override("separation", 14)
	margin.add_child(root_vb)

	# Header
	var hdr := Label.new()
	hdr.name = "HeaderLabel"
	hdr.text = "SELECT YOUR BALLER  //  OFFLINE EXHIBITION VS PHANTOM AI"
	hdr.add_theme_font_size_override("font_size", 24)
	hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CYAN)
	root_vb.add_child(hdr)

	# Roster Bar (5 characters)
	var roster_row := HBoxContainer.new()
	roster_row.name = "RosterBar"
	roster_row.add_theme_constant_override("separation", 10)
	root_vb.add_child(roster_row)

	for arch_id in ArchetypeRegistry.ORDERED_IDS:
		var d: Dictionary = ArchetypeRegistry.get_archetype_dict(arch_id)
		var btn := Button.new()
		btn.name = "RosterBtn_%s" % arch_id
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(0.0, 48.0)
		btn.text = "%s\n[%s]" % [str(d.get("nickname", arch_id)), str(d.get("class_name_display", ""))]
		var captured_id: String = arch_id
		btn.pressed.connect(func() -> void: select_archetype(captured_id))
		roster_row.add_child(btn)
		_roster_buttons[arch_id] = btn

	# Middle Split: 3D SubViewport Preview (Left) + Stats & Bio (Right)
	var mid_row := HBoxContainer.new()
	mid_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid_row.add_theme_constant_override("separation", 18)
	root_vb.add_child(mid_row)

	var preview_panel := PanelContainer.new()
	preview_panel.name = "PreviewPanel"
	preview_panel.custom_minimum_size = Vector2(360.0, 0.0)
	preview_panel.add_theme_stylebox_override("panel", UIThemeBuilder.make_panel_style(UIThemeBuilder.COL_PANEL_DARK, UIThemeBuilder.COL_CYAN, 2, 10, 6.0, 6.0))
	mid_row.add_child(preview_panel)

	var sv_container := SubViewportContainer.new()
	sv_container.name = "TurntableViewportContainer"
	sv_container.stretch = true
	sv_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sv_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_panel.add_child(sv_container)

	_preview_viewport = SubViewport.new()
	_preview_viewport.name = "TurntableSubViewport"
	_preview_viewport.size = Vector2i(360, 420)
	_preview_viewport.own_world_3d = true
	_preview_viewport.transparent_bg = false
	_preview_viewport.render_target_update_mode = (
		SubViewport.UPDATE_DISABLED
		if DisplayServer.get_name() == "headless"
		else SubViewport.UPDATE_ALWAYS
	)
	sv_container.add_child(_preview_viewport)
	_build_3d_turntable(_preview_viewport)

	# Right Info Card
	var info_panel := PanelContainer.new()
	info_panel.name = "ArchetypeInfoPanel"
	info_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_row.add_child(info_panel)

	var info_vb := VBoxContainer.new()
	info_vb.add_theme_constant_override("separation", 8)
	info_panel.add_child(info_vb)

	var name_row := HBoxContainer.new()
	info_vb.add_child(name_row)
	_char_name_label = Label.new()
	_char_name_label.name = "CharacterNameLabel"
	_char_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_char_name_label.add_theme_font_size_override("font_size", 24)
	name_row.add_child(_char_name_label)

	_char_class_label = Label.new()
	_char_class_label.name = "CharacterClassLabel"
	_char_class_label.add_theme_font_size_override("font_size", 18)
	name_row.add_child(_char_class_label)

	_tagline_label = Label.new()
	_tagline_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tagline_label.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	info_vb.add_child(_tagline_label)

	# 6 Stat Bars
	var stats_grid := GridContainer.new()
	stats_grid.name = "StatBarsGrid"
	stats_grid.columns = 2
	stats_grid.add_theme_constant_override("h_separation", 18)
	stats_grid.add_theme_constant_override("v_separation", 6)
	info_vb.add_child(stats_grid)

	for spec in STAT_KEYS:
		var k: String = str(spec["key"])
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 8)
		stats_grid.add_child(row)

		var lbl := Label.new()
		lbl.text = str(spec["label"])
		lbl.custom_minimum_size = Vector2(92.0, 0.0)
		lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(lbl)

		var bar := ProgressBar.new()
		bar.name = "StatBar_%s" % k
		bar.min_value = 0.0
		bar.max_value = 100.0
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(120.0, 14.0)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bar)

		var v_lbl := Label.new()
		v_lbl.custom_minimum_size = Vector2(28.0, 0.0)
		v_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		v_lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(v_lbl)

		_stat_bars[k] = {"bar": bar, "val": v_lbl}

	# Strengths & Weaknesses Split
	var sw_row := HBoxContainer.new()
	sw_row.add_theme_constant_override("separation", 16)
	info_vb.add_child(sw_row)

	var str_vb := VBoxContainer.new()
	str_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sw_row.add_child(str_vb)
	var str_hdr := Label.new()
	str_hdr.text = "STRENGTHS"
	str_hdr.add_theme_font_size_override("font_size", 12)
	str_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_EMERALD)
	str_vb.add_child(str_hdr)
	_strengths_label = Label.new()
	_strengths_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_strengths_label.add_theme_font_size_override("font_size", 12)
	str_vb.add_child(_strengths_label)

	var wk_vb := VBoxContainer.new()
	wk_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sw_row.add_child(wk_vb)
	var wk_hdr := Label.new()
	wk_hdr.text = "WEAKNESSES"
	wk_hdr.add_theme_font_size_override("font_size", 12)
	wk_hdr.add_theme_color_override("font_color", UIThemeBuilder.COL_CRIMSON)
	wk_vb.add_child(wk_hdr)
	_weaknesses_label = Label.new()
	_weaknesses_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_weaknesses_label.add_theme_font_size_override("font_size", 12)
	wk_vb.add_child(_weaknesses_label)

	# Unique Signature Skill Callout Card
	_skill_card_panel = PanelContainer.new()
	_skill_card_panel.name = "SignatureSkillCard"
	info_vb.add_child(_skill_card_panel)
	var sk_vb := VBoxContainer.new()
	sk_vb.add_theme_constant_override("separation", 3)
	_skill_card_panel.add_child(sk_vb)
	_skill_title_label = Label.new()
	_skill_title_label.add_theme_font_size_override("font_size", 14)
	_skill_title_label.add_theme_color_override("font_color", UIThemeBuilder.COL_GOLD)
	sk_vb.add_child(_skill_title_label)
	_skill_seq_label = Label.new()
	_skill_seq_label.add_theme_font_size_override("font_size", 12)
	sk_vb.add_child(_skill_seq_label)

	# Bottom Match Configuration & CTA Bar
	var foot := PanelContainer.new()
	root_vb.add_child(foot)
	var foot_row := HBoxContainer.new()
	foot_row.add_theme_constant_override("separation", 14)
	foot.add_child(foot_row)

	var m_lbl := Label.new()
	m_lbl.text = "MATCH MODE:"
	m_lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	foot_row.add_child(m_lbl)

	_mode_option = OptionButton.new()
	_mode_option.name = "ModeSelector"
	for i in range(MODE_OPTIONS.size()):
		_mode_option.add_item(MODE_OPTIONS[i], i)
	_mode_option.select(2) # 3v3 default
	_mode_option.item_selected.connect(func(idx: int) -> void: _selected_mode = MODE_OPTIONS[clampi(idx, 0, MODE_OPTIONS.size() - 1)])
	foot_row.add_child(_mode_option)

	var d_lbl := Label.new()
	d_lbl.text = "AI DIFFICULTY:"
	d_lbl.add_theme_color_override("font_color", UIThemeBuilder.COL_SLATE)
	foot_row.add_child(d_lbl)

	_diff_option = OptionButton.new()
	_diff_option.name = "DifficultySelector"
	for i in range(DIFFICULTY_OPTIONS.size()):
		_diff_option.add_item(DIFFICULTY_OPTIONS[i], i)
	_diff_option.select(1) # Pro default
	_diff_option.item_selected.connect(func(idx: int) -> void: _selected_difficulty_tier = clampi(idx, 0, DIFFICULTY_OPTIONS.size() - 1))
	foot_row.add_child(_diff_option)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot_row.add_child(spacer)

	_back_btn = Button.new()
	_back_btn.name = "BackButton"
	_back_btn.text = "BACK"
	_back_btn.pressed.connect(func() -> void: UIThemeBuilder.route_navigate(self, "main_menu"))
	foot_row.add_child(_back_btn)

	_start_btn = Button.new()
	_start_btn.name = "StartMatchButton"
	_start_btn.text = "TIP-OFF MATCH"
	_start_btn.custom_minimum_size = Vector2(210.0, 44.0)
	_start_btn.add_theme_font_size_override("font_size", 17)
	UIThemeBuilder.apply_primary_cta_button(_start_btn, UIThemeBuilder.COL_EMERALD)
	_start_btn.pressed.connect(_on_start_match_pressed)
	foot_row.add_child(_start_btn)


func _build_3d_turntable(vp: SubViewport) -> void:
	var stage := Node3D.new()
	stage.name = "PreviewStage"
	vp.add_child(stage)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.055, 0.078, 0.145, 1.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.65, 0.78, 0.96, 1.0)
	env.ambient_light_energy = 0.85
	we.environment = env
	stage.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.45
	sun.rotation_degrees = Vector3(-35.0, 32.0, 0.0)
	stage.add_child(sun)

	var cam := Camera3D.new()
	cam.name = "PreviewCamera"
	cam.position = Vector3(0.0, 1.15, 2.75)
	cam.fov = 44.0
	cam.current = true
	stage.add_child(cam)
	var look_dir: Vector3 = Vector3(0.0, 0.96, 0.0) - cam.position
	if look_dir.length_squared() > 1e-6 and absf(look_dir.normalized().dot(Vector3.UP)) < 0.999:
		cam.look_at(Vector3(0.0, 0.96, 0.0), Vector3.UP)

	var pedestal := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.78
	cyl.bottom_radius = 0.86
	cyl.height = 0.10
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.10, 0.16, 0.28, 1.0)
	pmat.emission_enabled = true
	pmat.emission = UIThemeBuilder.COL_CYAN
	pmat.emission_energy_multiplier = 0.25
	cyl.material = pmat
	pedestal.mesh = cyl
	pedestal.position = Vector3(0.0, -0.05, 0.0)
	stage.add_child(pedestal)

	_preview_turntable = Node3D.new()
	_preview_turntable.name = "TurntablePivot"
	stage.add_child(_preview_turntable)

	_preview_animator = CharacterAnimator.new()
	_preview_animator.name = "PreviewCharacterAnimator"
	_preview_animator.rotation.y = PI # Face toward camera (+Z)
	_preview_turntable.add_child(_preview_animator)
