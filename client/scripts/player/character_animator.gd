class_name CharacterAnimator
extends Node3D
## Procedural articulated 3D anime basketball character rig driven by AnimationPlayer
## + real AnimationTree (AnimationNodeStateMachine) with states:
##   idle, run, sprint, jump_start, fall, land
## plus upper-body, combo, and archetype unique skill states/hooks.

const LOCOMOTION_STATES: Array[StringName] = [
	&"idle",
	&"run",
	&"sprint",
	&"jump_start",
	&"fall",
	&"land",
	&"defensive_stance",
	&"ankle_stumble",
]

const ACTION_STATES: Array[StringName] = [
	&"shoot",
	&"layup",
	&"dribble",
	&"crossover",
	&"behind_the_back",
	&"spin",
	&"stepback",
	&"hesitation",
	&"phantom_drive",
	&"ankle_breaker",
	&"mirror_step",
	&"meteor_dunk",
	&"volt_dash",
	&"starlight_high_arc",
	&"mirage_thread",
	&"tectonic_slam",
	&"eclipse_counter",
	&"dunk",
	&"steal",
	&"block",
]

var jersey_color: Color = Color(0.10, 0.45, 0.92, 1.0)
var secondary_color: Color = Color(0.10, 0.12, 0.19, 1.0)
var accent_color: Color = Color(0.20, 0.92, 1.0, 1.0)
var aura_color: Color = Color(0.20, 0.92, 1.0, 1.0)
var hair_color: Color = Color(0.32, 0.78, 1.0, 1.0)

var rig_scale: Vector3 = Vector3.ONE
var anim_variation: Dictionary = {
	"run_speed_scale": 1.0,
	"dribble_speed_scale": 1.0,
	"shot_release_height": 0.0,
	"stance_crouch_offset": 0.0,
	"posture_style": "balanced_two_way",
}

var pelvis: Node3D = null
var torso: Node3D = null
var head_pivot: Node3D = null
var shoulder_l: Node3D = null
var shoulder_r: Node3D = null
var hip_l: Node3D = null
var hip_r: Node3D = null
var shin_l: Node3D = null
var shin_r: Node3D = null
var ball_hand_marker_l: Marker3D = null
var ball_hand_marker_r: Marker3D = null
var ball_hand_marker: Marker3D = null

var animation_player: AnimationPlayer = null
var animation_tree: AnimationTree = null
var _playback: AnimationNodeStateMachinePlayback = null

var _current_locomotion: StringName = &"idle"
var _active_action: StringName = &""
var _action_timer: float = 0.0
var _active_dribble_right: bool = true

var _spin_timer: float = 0.0
var _spin_duration: float = 0.28
var _spin_direction: float = 1.0
var _anim_elapsed_sec: float = 0.0

var _jersey_mat: ShaderMaterial = null
var _shorts_mat: ShaderMaterial = null
var _accent_mat: ShaderMaterial = null
var _hair_mat: ShaderMaterial = null
var _skin_mat: ShaderMaterial = null
var _shoe_mat: ShaderMaterial = null


func _ready() -> void:
	_build_articulated_rig()
	_build_animations_and_tree()
	scale = rig_scale


func set_team_palette(
	team_id: int,
	custom_jersey: Color = Color(0, 0, 0, 0),
	custom_accent: Color = Color(0, 0, 0, 0),
	custom_secondary: Color = Color(0, 0, 0, 0),
	custom_hair: Color = Color(0, 0, 0, 0),
	custom_aura: Color = Color(0, 0, 0, 0)
) -> void:
	if team_id == 0:
		jersey_color = Color(0.09, 0.40, 0.88, 1.0)
		secondary_color = Color(0.10, 0.12, 0.19, 1.0)
		accent_color = Color(0.22, 0.92, 1.0, 1.0)
		aura_color = Color(0.22, 0.92, 1.0, 1.0)
		hair_color = Color(0.38, 0.82, 1.0, 1.0)
	else:
		jersey_color = Color(0.84, 0.14, 0.22, 1.0)
		secondary_color = Color(0.14, 0.11, 0.16, 1.0)
		accent_color = Color(1.0, 0.78, 0.18, 1.0)
		aura_color = Color(1.0, 0.35, 0.40, 1.0)
		hair_color = Color(0.96, 0.26, 0.32, 1.0)

	if custom_jersey.a > 0.01:
		jersey_color = custom_jersey
	if custom_secondary.a > 0.01:
		secondary_color = custom_secondary
	if custom_accent.a > 0.01:
		accent_color = custom_accent
	if custom_hair.a > 0.01:
		hair_color = custom_hair
	if custom_aura.a > 0.01:
		aura_color = custom_aura

	_refresh_materials()


func apply_archetype_visuals(
	colors_dict: Dictionary,
	new_rig_scale: Vector3 = Vector3.ONE,
	new_anim_variation: Dictionary = {}
) -> void:
	if colors_dict.has("primary") and colors_dict["primary"] is Color:
		jersey_color = colors_dict["primary"]
	if colors_dict.has("secondary") and colors_dict["secondary"] is Color:
		secondary_color = colors_dict["secondary"]
	if colors_dict.has("accent") and colors_dict["accent"] is Color:
		accent_color = colors_dict["accent"]
	if colors_dict.has("aura") and colors_dict["aura"] is Color:
		aura_color = colors_dict["aura"]
	if colors_dict.has("hair") and colors_dict["hair"] is Color:
		hair_color = colors_dict["hair"]

	if new_rig_scale.length_squared() > 0.01:
		rig_scale = new_rig_scale
		scale = rig_scale

	if not new_anim_variation.is_empty():
		for k in new_anim_variation.keys():
			anim_variation[str(k)] = new_anim_variation[k]

	_refresh_materials()


func _refresh_materials() -> void:
	if _jersey_mat != null:
		_jersey_mat.set_shader_parameter("albedo_color", jersey_color)
		_jersey_mat.set_shader_parameter("rim_color", accent_color)
	if _shorts_mat != null:
		_shorts_mat.set_shader_parameter("albedo_color", secondary_color)
		_shorts_mat.set_shader_parameter("rim_color", accent_color)
	if _accent_mat != null:
		_accent_mat.set_shader_parameter("albedo_color", accent_color)
		_accent_mat.set_shader_parameter("rim_color", Color.WHITE)
		_accent_mat.set_shader_parameter("emission_color", accent_color)
		_accent_mat.set_shader_parameter("emission_energy", 0.45)
	if _hair_mat != null:
		_hair_mat.set_shader_parameter("albedo_color", hair_color)
		_hair_mat.set_shader_parameter("rim_color", aura_color)
	if _shoe_mat != null:
		_shoe_mat.set_shader_parameter("rim_color", accent_color)


func get_jersey_material() -> ShaderMaterial:
	return _jersey_mat


func get_shorts_material() -> ShaderMaterial:
	return _shorts_mat


func get_accent_material() -> ShaderMaterial:
	return _accent_mat


func get_hair_material() -> ShaderMaterial:
	return _hair_mat


func uses_cel_shader() -> bool:
	return (
		_jersey_mat != null
		and _jersey_mat.shader != null
		and _jersey_mat.shader.resource_path == VFXManager.SHADER_CEL_CHARACTER
		and _jersey_mat.next_pass is ShaderMaterial
	)


func reset_animator() -> void:
	_current_locomotion = &"idle"
	_active_action = &""
	_action_timer = 0.0
	_active_dribble_right = true
	_spin_timer = 0.0
	_anim_elapsed_sec = 0.0
	if animation_tree != null:
		animation_tree.active = false
		animation_tree.active = true
		_playback = animation_tree.get("parameters/playback") as AnimationNodeStateMachinePlayback
	if _playback != null:
		_playback.start(&"idle")
	if animation_tree != null:
		animation_tree.advance(0.0)
	if pelvis != null:
		pelvis.position = Vector3(0.0, 0.92, 0.0)
		pelvis.rotation = Vector3.ZERO
	if torso != null:
		torso.rotation = Vector3(-0.05, 0.0, 0.0)
	if shoulder_l != null:
		shoulder_l.rotation = Vector3(-0.18, 0.0, -0.10)
	if shoulder_r != null:
		shoulder_r.rotation = Vector3(-0.22, 0.0, 0.10)
	if hip_l != null:
		hip_l.rotation = Vector3(0.08, 0.0, 0.0)
	if hip_r != null:
		hip_r.rotation = Vector3(-0.06, 0.0, 0.0)
	if shin_l != null:
		shin_l.rotation = Vector3(-0.12, 0.0, 0.0)
	if shin_r != null:
		shin_r.rotation = Vector3(-0.12, 0.0, 0.0)


func set_locomotion_state(next_state: StringName) -> void:
	if not LOCOMOTION_STATES.has(next_state):
		return
	_current_locomotion = next_state
	if _playback != null:
		if _playback.get_current_node() != next_state:
			_playback.travel(next_state)
			if animation_tree != null:
				animation_tree.advance(0.0)


func trigger_action(action_name: StringName, duration: float = 0.30, right_hand: bool = true) -> void:
	if not ACTION_STATES.has(action_name) and action_name != &"ankle_stumble":
		return
	_active_action = action_name
	_action_timer = maxf(0.08, duration)
	_active_dribble_right = right_hand


func start_spin_360(duration: float = 0.28, clockwise: bool = true) -> void:
	_spin_duration = maxf(0.12, duration)
	_spin_timer = _spin_duration
	_spin_direction = -1.0 if clockwise else 1.0
	trigger_action(&"spin", _spin_duration, _active_dribble_right)


func get_current_state() -> StringName:
	if _playback != null:
		var node_name: StringName = _playback.get_current_node()
		if not node_name.is_empty():
			return node_name
	return _current_locomotion


func get_active_action() -> StringName:
	return _active_action


func get_animation_tree() -> AnimationTree:
	return animation_tree


func get_animation_player() -> AnimationPlayer:
	return animation_player


func get_hand_world_position(is_right_hand: bool = true) -> Vector3:
	if is_right_hand and ball_hand_marker_r != null:
		return ball_hand_marker_r.global_position
	if not is_right_hand and ball_hand_marker_l != null:
		return ball_hand_marker_l.global_position
	return global_position + Vector3(0.28 if is_right_hand else -0.28, 1.02, -0.24)


func _physics_process(delta: float) -> void:
	var dt: float = delta if delta > 0.0 else (1.0 / 60.0)
	_anim_elapsed_sec += dt
	if _spin_timer > 0.0:
		_spin_timer = maxf(0.0, _spin_timer - dt)
		if pelvis != null:
			var progress: float = 1.0 - (_spin_timer / _spin_duration)
			pelvis.rotation.y = progress * TAU * _spin_direction
			if _spin_timer <= 0.0:
				pelvis.rotation.y = 0.0
	elif pelvis != null and absf(pelvis.rotation.y) > 0.001:
		pelvis.rotation.y = 0.0

	if _action_timer > 0.0:
		_action_timer = maxf(0.0, _action_timer - dt)
		_apply_upper_body_action_overlay()
		if _action_timer <= 0.0:
			_active_action = &""


func _apply_upper_body_action_overlay() -> void:
	if shoulder_r == null or shoulder_l == null:
		return
	var active_arm: Node3D = shoulder_r if _active_dribble_right else shoulder_l
	var off_arm: Node3D = shoulder_l if _active_dribble_right else shoulder_r
	match _active_action:
		&"shoot", &"starlight_high_arc":
			shoulder_r.rotation.x = -2.60 if _active_action == &"starlight_high_arc" else -2.45
			shoulder_l.rotation.x = -2.20 if _active_action == &"starlight_high_arc" else -2.05
		&"layup":
			active_arm.rotation.x = -2.65
			off_arm.rotation.x = -0.85
		&"dribble":
			var pulse: float = sin(_anim_elapsed_sec * 28.0)
			active_arm.rotation.x = -0.65 + pulse * 0.45
			off_arm.rotation.x = -0.25
		&"crossover":
			active_arm.rotation.x = -0.95
			active_arm.rotation.z = -0.35 if _active_dribble_right else 0.35
			if torso != null:
				torso.rotation.z = 0.16 if _active_dribble_right else -0.16
		&"behind_the_back":
			active_arm.rotation.x = 0.55
			off_arm.rotation.x = -0.45
		&"spin":
			active_arm.rotation.x = -0.80
			off_arm.rotation.x = -0.65
		&"stepback":
			shoulder_r.rotation.x = -1.35
			shoulder_l.rotation.x = -1.15
			if torso != null:
				torso.rotation.x = 0.14
		&"hesitation":
			active_arm.rotation.x = -1.05
			off_arm.rotation.x = -0.40
		&"phantom_drive", &"volt_dash":
			active_arm.rotation.x = -0.95
			off_arm.rotation.x = 0.62
			if torso != null:
				torso.rotation.x = -0.38
		&"ankle_breaker":
			active_arm.rotation.x = -1.15
			active_arm.rotation.z = -0.42 if _active_dribble_right else 0.42
			if torso != null:
				torso.rotation.z = 0.22 if _active_dribble_right else -0.22
		&"mirror_step":
			shoulder_r.rotation.x = -1.45
			shoulder_l.rotation.x = -1.25
			if torso != null:
				torso.rotation.x = 0.16
		&"mirage_thread":
			shoulder_r.rotation.x = -1.55
			shoulder_l.rotation.x = -1.35
			if torso != null:
				torso.rotation.y = -0.28
		&"eclipse_counter":
			active_arm.rotation.x = -1.25
			off_arm.rotation.x = -0.95
			if torso != null:
				torso.rotation.x = -0.26
		&"meteor_dunk", &"tectonic_slam", &"dunk":
			shoulder_r.rotation.x = -2.95
			shoulder_l.rotation.x = -1.65
		&"steal":
			shoulder_r.rotation.x = -1.45
			shoulder_r.rotation.y = 0.35
		&"block":
			shoulder_r.rotation.x = -2.95
			shoulder_l.rotation.x = -2.95
		&"ankle_stumble":
			shoulder_r.rotation.x = -1.15
			shoulder_r.rotation.z = 0.72
			shoulder_l.rotation.x = -1.35
			shoulder_l.rotation.z = -0.72
			if torso != null:
				torso.rotation.x = 0.28
				torso.rotation.z = -0.26


func _build_articulated_rig() -> void:
	if pelvis != null:
		return

	_jersey_mat = VFXManager.create_cel_character_material(jersey_color, accent_color)
	_shorts_mat = VFXManager.create_cel_character_material(secondary_color, accent_color)
	_accent_mat = VFXManager.create_cel_character_material(accent_color, Color.WHITE)
	_accent_mat.set_shader_parameter("emission_color", accent_color)
	_accent_mat.set_shader_parameter("emission_energy", 0.45)
	_hair_mat = VFXManager.create_cel_character_material(hair_color, aura_color)
	_skin_mat = VFXManager.create_cel_character_material(Color(0.96, 0.80, 0.69, 1.0), Color(1.0, 0.92, 0.85, 1.0))
	_shoe_mat = VFXManager.create_cel_character_material(Color(0.95, 0.96, 0.99, 1.0), accent_color)

	var skin_mat: Material = _skin_mat
	var shoe_base_mat: Material = _shoe_mat

	pelvis = Node3D.new()
	pelvis.name = "Pelvis"
	pelvis.position = Vector3(0.0, 0.92, 0.0)
	add_child(pelvis)

	_add_box_part(pelvis, "ShortsMesh", Vector3(0.34, 0.20, 0.22), Vector3(0.0, 0.0, 0.0), _shorts_mat)

	torso = Node3D.new()
	torso.name = "Torso"
	torso.position = Vector3(0.0, 0.08, 0.0)
	pelvis.add_child(torso)

	_add_box_part(torso, "JerseyMesh", Vector3(0.38, 0.46, 0.22), Vector3(0.0, 0.23, 0.0), _jersey_mat)
	_add_box_part(torso, "JerseyStripeFront", Vector3(0.14, 0.22, 0.015), Vector3(0.0, 0.25, -0.115), _accent_mat)
	_add_box_part(torso, "JerseyStripeBack", Vector3(0.16, 0.22, 0.015), Vector3(0.0, 0.25, 0.115), _accent_mat)

	head_pivot = Node3D.new()
	head_pivot.name = "HeadPivot"
	head_pivot.position = Vector3(0.0, 0.48, 0.0)
	torso.add_child(head_pivot)

	var head_mesh_inst := MeshInstance3D.new()
	head_mesh_inst.name = "HeadMesh"
	var head_sphere := SphereMesh.new()
	head_sphere.radius = 0.135
	head_sphere.height = 0.27
	head_sphere.material = skin_mat
	head_mesh_inst.mesh = head_sphere
	head_mesh_inst.position = Vector3(0.0, 0.14, 0.0)
	head_pivot.add_child(head_mesh_inst)

	_add_box_part(head_pivot, "Visor", Vector3(0.25, 0.055, 0.08), Vector3(0.0, 0.155, -0.105), _accent_mat)
	_add_box_part(head_pivot, "HairCrown", Vector3(0.27, 0.10, 0.27), Vector3(0.0, 0.24, 0.01), _hair_mat)
	_add_box_part(head_pivot, "HairSpikeCenter", Vector3(0.09, 0.12, 0.16), Vector3(0.0, 0.30, -0.04), _hair_mat)
	_add_box_part(head_pivot, "HairSpikeLeft", Vector3(0.08, 0.10, 0.14), Vector3(-0.10, 0.28, 0.02), _hair_mat)
	_add_box_part(head_pivot, "HairSpikeRight", Vector3(0.08, 0.10, 0.14), Vector3(0.10, 0.28, 0.02), _hair_mat)

	shoulder_l = _build_arm("ShoulderL", Vector3(-0.25, 0.42, 0.0), skin_mat, _accent_mat, false)
	shoulder_r = _build_arm("ShoulderR", Vector3(0.25, 0.42, 0.0), skin_mat, _accent_mat, true)

	var leg_l_parts: Array[Node3D] = _build_leg("HipL", "ShinL", Vector3(-0.11, -0.06, 0.0), _shorts_mat, skin_mat, shoe_base_mat, _accent_mat)
	hip_l = leg_l_parts[0]
	shin_l = leg_l_parts[1]

	var leg_r_parts: Array[Node3D] = _build_leg("HipR", "ShinR", Vector3(0.11, -0.06, 0.0), _shorts_mat, skin_mat, shoe_base_mat, _accent_mat)
	hip_r = leg_r_parts[0]
	shin_r = leg_r_parts[1]


func _build_arm(node_name: String, shoulder_pos: Vector3, skin_mat: Material, trim_mat: Material, is_right: bool) -> Node3D:
	var shoulder := Node3D.new()
	shoulder.name = node_name
	shoulder.position = shoulder_pos
	torso.add_child(shoulder)

	_add_box_part(shoulder, "UpperArm", Vector3(0.095, 0.26, 0.095), Vector3(0.0, -0.13, 0.0), skin_mat)
	_add_box_part(shoulder, "Forearm", Vector3(0.085, 0.24, 0.085), Vector3(0.0, -0.36, 0.0), skin_mat)
	_add_box_part(shoulder, "Wristband", Vector3(0.098, 0.05, 0.098), Vector3(0.0, -0.43, 0.0), trim_mat)
	_add_box_part(shoulder, "Hand", Vector3(0.09, 0.09, 0.09), Vector3(0.0, -0.49, 0.0), skin_mat)

	var marker := Marker3D.new()
	marker.name = "BallHandMarker" if is_right else "BallHandMarkerL"
	marker.position = Vector3(0.04 if is_right else -0.04, -0.52, -0.16)
	shoulder.add_child(marker)

	if is_right:
		ball_hand_marker_r = marker
		ball_hand_marker = marker
	else:
		ball_hand_marker_l = marker

	return shoulder


func _build_leg(
	hip_name: String,
	shin_name: String,
	hip_pos: Vector3,
	shorts_mat: Material,
	skin_mat: Material,
	shoe_mat: Material,
	sole_mat: Material
) -> Array[Node3D]:
	var hip := Node3D.new()
	hip.name = hip_name
	hip.position = hip_pos
	pelvis.add_child(hip)

	_add_box_part(hip, "ShortLeg", Vector3(0.15, 0.20, 0.16), Vector3(0.0, -0.10, 0.0), shorts_mat)
	_add_box_part(hip, "Thigh", Vector3(0.115, 0.24, 0.115), Vector3(0.0, -0.28, 0.0), skin_mat)

	var shin := Node3D.new()
	shin.name = shin_name
	shin.position = Vector3(0.0, -0.42, 0.0)
	hip.add_child(shin)

	_add_box_part(shin, "Calf", Vector3(0.10, 0.34, 0.10), Vector3(0.0, -0.17, 0.0), skin_mat)
	_add_box_part(shin, "SneakerUpper", Vector3(0.13, 0.11, 0.25), Vector3(0.0, -0.37, -0.04), shoe_mat)
	_add_box_part(shin, "SneakerSole", Vector3(0.14, 0.035, 0.27), Vector3(0.0, -0.425, -0.04), sole_mat)

	return [hip, shin]


func _add_box_part(parent: Node3D, part_name: String, sz: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	var bm := BoxMesh.new()
	bm.size = sz
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)
	return mi


func _build_animations_and_tree() -> void:
	animation_player = get_node_or_null("AnimationPlayer") as AnimationPlayer
	if animation_player == null:
		animation_player = AnimationPlayer.new()
		animation_player.name = "AnimationPlayer"
		add_child(animation_player)
	animation_player.root_node = NodePath("..")

	var lib := AnimationLibrary.new()
	lib.add_animation(&"RESET", _make_pose_anim(0.1, false, Vector3(0, 0.92, 0), Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO))
	lib.add_animation(&"idle", _make_idle_anim())
	lib.add_animation(&"run", _make_cycle_anim(0.56, 0.62, 0.55, -0.10, 0.035))
	lib.add_animation(&"sprint", _make_cycle_anim(0.40, 0.98, 0.88, -0.22, 0.055))
	lib.add_animation(&"jump_start", _make_pose_anim(0.22, false, Vector3(0, 0.98, 0), Vector3(-0.10, 0, 0), Vector3(-2.15, 0, 0), Vector3(-2.15, 0, 0), Vector3(0.32, 0, 0), Vector3(-0.24, 0, 0), Vector3(-0.35, 0, 0)))
	lib.add_animation(&"fall", _make_pose_anim(0.40, true, Vector3(0, 0.95, 0), Vector3(0.06, 0, 0), Vector3(-1.35, 0, -0.22), Vector3(-1.35, 0, 0.22), Vector3(-0.22, 0, 0), Vector3(0.18, 0, 0), Vector3(-0.42, 0, 0)))
	lib.add_animation(&"land", _make_pose_anim(0.18, false, Vector3(0, 0.78, 0), Vector3(-0.18, 0, 0), Vector3(-0.45, 0, -0.15), Vector3(-0.45, 0, 0.15), Vector3(0.52, 0, 0), Vector3(0.52, 0, 0), Vector3(-0.68, 0, 0)))
	lib.add_animation(&"defensive_stance", _make_defensive_stance_anim())
	lib.add_animation(&"ankle_stumble", _make_ankle_stumble_anim())

	# Upper-body, signature combo, and archetype unique skill clips
	lib.add_animation(&"shoot", _make_pose_anim(0.32, false, Vector3(0, 0.96, 0), Vector3(-0.06, 0, 0), Vector3(-2.05, 0, 0), Vector3(-2.45, 0, 0), Vector3(0.12, 0, 0), Vector3(-0.10, 0, 0), Vector3(-0.15, 0, 0)))
	lib.add_animation(&"layup", _make_pose_anim(0.30, false, Vector3(0, 1.00, 0), Vector3(-0.08, 0, 0), Vector3(-0.85, 0, -0.15), Vector3(-2.65, 0, 0.08), Vector3(0.45, 0, 0), Vector3(-0.25, 0, 0), Vector3(-0.48, 0, 0)))
	lib.add_animation(&"dribble", _make_pose_anim(0.36, true, Vector3(0, 0.86, 0), Vector3(-0.16, 0, 0), Vector3(-0.35, 0, -0.18), Vector3(-0.85, 0, 0.10), Vector3(0.24, 0, 0), Vector3(-0.20, 0, 0), Vector3(-0.28, 0, 0)))
	lib.add_animation(&"crossover", _make_pose_anim(0.24, false, Vector3(0, 0.82, 0), Vector3(-0.22, 0, 0.15), Vector3(-0.85, 0, 0.25), Vector3(-0.85, 0, -0.25), Vector3(0.38, 0, -0.12), Vector3(-0.30, 0, 0.12), Vector3(-0.40, 0, 0)))
	lib.add_animation(&"behind_the_back", _make_pose_anim(0.24, false, Vector3(0, 0.83, 0), Vector3(-0.18, 0.18, 0), Vector3(0.45, 0, -0.15), Vector3(0.55, 0, 0.15), Vector3(0.32, 0, 0), Vector3(-0.28, 0, 0), Vector3(-0.36, 0, 0)))
	lib.add_animation(&"spin", _make_pose_anim(0.28, false, Vector3(0, 0.85, 0), Vector3(-0.16, 0, 0), Vector3(-0.65, 0, -0.22), Vector3(-0.80, 0, 0.22), Vector3(0.30, 0, 0), Vector3(-0.30, 0, 0), Vector3(-0.35, 0, 0)))
	lib.add_animation(&"stepback", _make_pose_anim(0.26, false, Vector3(0, 0.86, 0), Vector3(0.12, 0, 0), Vector3(-1.15, 0, -0.10), Vector3(-1.35, 0, 0.10), Vector3(-0.35, 0, 0), Vector3(0.42, 0, 0), Vector3(-0.42, 0, 0)))
	lib.add_animation(&"hesitation", _make_pose_anim(0.28, false, Vector3(0, 0.88, 0), Vector3(-0.12, 0, 0), Vector3(-0.40, 0, -0.15), Vector3(-1.05, 0, 0.12), Vector3(0.20, 0, 0), Vector3(-0.18, 0, 0), Vector3(-0.30, 0, 0)))
	lib.add_animation(&"phantom_drive", _make_pose_anim(0.30, false, Vector3(0, 0.78, 0), Vector3(-0.34, 0, 0), Vector3(0.55, 0, -0.18), Vector3(-0.90, 0, 0.18), Vector3(0.62, 0, 0), Vector3(-0.52, 0, 0), Vector3(-0.48, 0, 0)))
	lib.add_animation(&"ankle_breaker", _make_pose_anim(0.26, false, Vector3(0, 0.79, 0), Vector3(-0.24, 0, 0.20), Vector3(-0.95, 0, 0.30), Vector3(-1.15, 0, -0.30), Vector3(0.48, 0, -0.15), Vector3(-0.40, 0, 0.15), Vector3(-0.45, 0, 0)))
	lib.add_animation(&"mirror_step", _make_pose_anim(0.32, false, Vector3(0, 0.85, 0), Vector3(0.16, 0, 0), Vector3(-1.25, 0, -0.12), Vector3(-1.45, 0, 0.12), Vector3(-0.42, 0, 0), Vector3(0.48, 0, 0), Vector3(-0.44, 0, 0)))
	lib.add_animation(&"meteor_dunk", _make_pose_anim(0.46, false, Vector3(0, 1.06, 0), Vector3(-0.18, 0, 0), Vector3(-1.65, 0, -0.28), Vector3(-3.00, 0, 0.10), Vector3(0.52, 0, 0), Vector3(-0.40, 0, 0), Vector3(-0.62, 0, 0)))
	lib.add_animation(&"volt_dash", _make_pose_anim(0.24, false, Vector3(0, 0.76, 0), Vector3(-0.38, 0, 0.14), Vector3(0.62, 0, -0.20), Vector3(-0.95, 0, 0.20), Vector3(0.68, 0, 0), Vector3(-0.58, 0, 0), Vector3(-0.52, 0, 0)))
	lib.add_animation(&"starlight_high_arc", _make_pose_anim(0.34, false, Vector3(0, 0.99, 0), Vector3(0.10, 0, 0), Vector3(-2.20, 0, 0), Vector3(-2.60, 0, 0), Vector3(-0.22, 0, 0), Vector3(0.28, 0, 0), Vector3(-0.24, 0, 0)))
	lib.add_animation(&"mirage_thread", _make_pose_anim(0.26, false, Vector3(0, 0.86, 0), Vector3(-0.14, -0.28, 0), Vector3(-1.35, 0, -0.18), Vector3(-1.55, 0, 0.18), Vector3(0.30, 0, 0), Vector3(-0.26, 0, 0), Vector3(-0.32, 0, 0)))
	lib.add_animation(&"tectonic_slam", _make_pose_anim(0.42, false, Vector3(0, 1.04, 0), Vector3(-0.20, 0, 0), Vector3(-1.80, 0, -0.22), Vector3(-2.98, 0, 0.12), Vector3(0.50, 0, 0), Vector3(-0.42, 0, 0), Vector3(-0.60, 0, 0)))
	lib.add_animation(&"eclipse_counter", _make_pose_anim(0.28, false, Vector3(0, 0.80, 0), Vector3(-0.26, 0, 0), Vector3(-0.95, 0, -0.20), Vector3(-1.25, 0, 0.20), Vector3(0.55, 0, 0), Vector3(-0.46, 0, 0), Vector3(-0.44, 0, 0)))
	lib.add_animation(&"dunk", _make_pose_anim(0.38, false, Vector3(0, 1.02, 0), Vector3(-0.14, 0, 0), Vector3(-1.50, 0, -0.25), Vector3(-2.90, 0, 0.08), Vector3(0.42, 0, 0), Vector3(-0.32, 0, 0), Vector3(-0.55, 0, 0)))
	lib.add_animation(&"steal", _make_pose_anim(0.26, false, Vector3(0, 0.82, 0), Vector3(-0.26, -0.25, 0), Vector3(-0.30, 0, -0.20), Vector3(-1.45, 0.30, 0), Vector3(0.38, 0, 0), Vector3(-0.32, 0, 0), Vector3(-0.35, 0, 0)))
	lib.add_animation(&"block", _make_pose_anim(0.32, false, Vector3(0, 1.00, 0), Vector3(0.04, 0, 0), Vector3(-2.95, 0, -0.08), Vector3(-2.95, 0, 0.08), Vector3(-0.14, 0, 0), Vector3(0.14, 0, 0), Vector3(-0.20, 0, 0)))

	if animation_player.has_animation_library(&""):
		animation_player.remove_animation_library(&"")
	animation_player.add_animation_library(&"", lib)

	animation_tree = get_node_or_null("AnimationTree") as AnimationTree
	if animation_tree == null:
		animation_tree = AnimationTree.new()
		animation_tree.name = "AnimationTree"
		add_child(animation_tree)

	animation_tree.root_node = NodePath("..")
	animation_tree.anim_player = NodePath("../AnimationPlayer")
	animation_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS

	var sm := AnimationNodeStateMachine.new()
	var all_states: Array[StringName] = []
	all_states.append_array(LOCOMOTION_STATES)
	all_states.append_array(ACTION_STATES)

	for st in all_states:
		var anim_node := AnimationNodeAnimation.new()
		anim_node.animation = st
		sm.add_node(st, anim_node)

	var start_tr := AnimationNodeStateMachineTransition.new()
	start_tr.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	start_tr.xfade_time = 0.0
	sm.add_transition(&"Start", &"idle", start_tr)

	for a in LOCOMOTION_STATES:
		for b in LOCOMOTION_STATES:
			if a == b:
				continue
			var tr := AnimationNodeStateMachineTransition.new()
			tr.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
			tr.xfade_time = 0.05
			sm.add_transition(a, b, tr)

	for act in ACTION_STATES:
		var to_act := AnimationNodeStateMachineTransition.new()
		to_act.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		to_act.xfade_time = 0.04
		sm.add_transition(&"idle", act, to_act)

		var from_act := AnimationNodeStateMachineTransition.new()
		from_act.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
		from_act.xfade_time = 0.06
		sm.add_transition(act, &"idle", from_act)

	animation_tree.tree_root = sm
	animation_tree.active = true
	_playback = animation_tree.get("parameters/playback") as AnimationNodeStateMachinePlayback
	if _playback != null:
		_playback.start(&"idle")
		animation_tree.advance(0.0)


func _make_idle_anim() -> Animation:
	var anim := Animation.new()
	anim.length = 1.2
	anim.loop_mode = Animation.LOOP_LINEAR

	var t_pelvis: int = anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(t_pelvis, NodePath("Pelvis"))
	anim.position_track_insert_key(t_pelvis, 0.0, Vector3(0.0, 0.92, 0.0))
	anim.position_track_insert_key(t_pelvis, 0.6, Vector3(0.0, 0.895, 0.0))
	anim.position_track_insert_key(t_pelvis, 1.2, Vector3(0.0, 0.92, 0.0))

	var t_torso: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t_torso, NodePath("Pelvis/Torso"))
	anim.rotation_track_insert_key(t_torso, 0.0, Quaternion.from_euler(Vector3(-0.05, 0.0, 0.0)))
	anim.rotation_track_insert_key(t_torso, 0.6, Quaternion.from_euler(Vector3(-0.08, 0.0, 0.0)))
	anim.rotation_track_insert_key(t_torso, 1.2, Quaternion.from_euler(Vector3(-0.05, 0.0, 0.0)))

	_insert_const_rot(anim, "Pelvis/Torso/ShoulderL", Vector3(-0.18, 0.0, -0.10), 1.2)
	_insert_const_rot(anim, "Pelvis/Torso/ShoulderR", Vector3(-0.22, 0.0, 0.10), 1.2)
	_insert_const_rot(anim, "Pelvis/HipL", Vector3(0.08, 0.0, 0.0), 1.2)
	_insert_const_rot(anim, "Pelvis/HipR", Vector3(-0.06, 0.0, 0.0), 1.2)
	_insert_const_rot(anim, "Pelvis/HipL/ShinL", Vector3(-0.12, 0.0, 0.0), 1.2)
	_insert_const_rot(anim, "Pelvis/HipR/ShinR", Vector3(-0.12, 0.0, 0.0), 1.2)
	return anim


func _make_defensive_stance_anim() -> Animation:
	var anim := Animation.new()
	anim.length = 0.72
	anim.loop_mode = Animation.LOOP_LINEAR
	var crouch_off: float = float(anim_variation.get("stance_crouch_offset", 0.0))
	var base_y: float = clampf(0.75 + crouch_off, 0.68, 0.82)

	var t_pelvis: int = anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(t_pelvis, NodePath("Pelvis"))
	anim.position_track_insert_key(t_pelvis, 0.0, Vector3(0.0, base_y, 0.0))
	anim.position_track_insert_key(t_pelvis, 0.36, Vector3(0.0, base_y - 0.025, 0.0))
	anim.position_track_insert_key(t_pelvis, 0.72, Vector3(0.0, base_y, 0.0))

	_insert_const_rot(anim, "Pelvis/Torso", Vector3(-0.24, 0.0, 0.0), 0.72)
	_insert_const_rot(anim, "Pelvis/Torso/ShoulderL", Vector3(-0.95, 0.24, -0.52), 0.72)
	_insert_const_rot(anim, "Pelvis/Torso/ShoulderR", Vector3(-0.95, -0.24, 0.52), 0.72)
	_insert_const_rot(anim, "Pelvis/HipL", Vector3(0.46, 0.0, -0.18), 0.72)
	_insert_const_rot(anim, "Pelvis/HipR", Vector3(0.46, 0.0, 0.18), 0.72)
	_insert_const_rot(anim, "Pelvis/HipL/ShinL", Vector3(-0.62, 0.0, 0.0), 0.72)
	_insert_const_rot(anim, "Pelvis/HipR/ShinR", Vector3(-0.62, 0.0, 0.0), 0.72)
	return anim


func _make_ankle_stumble_anim() -> Animation:
	var anim := Animation.new()
	anim.length = 1.10
	anim.loop_mode = Animation.LOOP_NONE

	var t_pelvis: int = anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(t_pelvis, NodePath("Pelvis"))
	anim.position_track_insert_key(t_pelvis, 0.0, Vector3(0.0, 0.74, 0.0))
	anim.position_track_insert_key(t_pelvis, 0.30, Vector3(0.05, 0.67, 0.04))
	anim.position_track_insert_key(t_pelvis, 0.80, Vector3(-0.03, 0.71, 0.02))
	anim.position_track_insert_key(t_pelvis, 1.10, Vector3(0.0, 0.78, 0.0))

	var t_torso: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t_torso, NodePath("Pelvis/Torso"))
	anim.rotation_track_insert_key(t_torso, 0.0, Quaternion.from_euler(Vector3(0.24, 0.14, -0.24)))
	anim.rotation_track_insert_key(t_torso, 0.35, Quaternion.from_euler(Vector3(0.34, -0.18, -0.32)))
	anim.rotation_track_insert_key(t_torso, 1.10, Quaternion.from_euler(Vector3(0.10, 0.0, -0.08)))

	_insert_const_rot(anim, "Pelvis/Torso/ShoulderL", Vector3(-1.35, 0.30, -0.72), 1.10)
	_insert_const_rot(anim, "Pelvis/Torso/ShoulderR", Vector3(-1.15, -0.30, 0.72), 1.10)
	_insert_const_rot(anim, "Pelvis/HipL", Vector3(-0.38, 0.0, -0.22), 1.10)
	_insert_const_rot(anim, "Pelvis/HipR", Vector3(0.52, 0.0, 0.22), 1.10)
	_insert_const_rot(anim, "Pelvis/HipL/ShinL", Vector3(-0.64, 0.0, 0.0), 1.10)
	_insert_const_rot(anim, "Pelvis/HipR/ShinR", Vector3(-0.68, 0.0, 0.0), 1.10)
	return anim


func _make_cycle_anim(length_sec: float, leg_amp: float, arm_amp: float, torso_lean: float, bounce_h: float) -> Animation:
	var anim := Animation.new()
	anim.length = length_sec
	anim.loop_mode = Animation.LOOP_LINEAR
	var q1: float = length_sec * 0.25
	var q2: float = length_sec * 0.50
	var q3: float = length_sec * 0.75

	var t_pelvis: int = anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(t_pelvis, NodePath("Pelvis"))
	anim.position_track_insert_key(t_pelvis, 0.0, Vector3(0.0, 0.90, 0.0))
	anim.position_track_insert_key(t_pelvis, q1, Vector3(0.0, 0.90 + bounce_h, 0.0))
	anim.position_track_insert_key(t_pelvis, q2, Vector3(0.0, 0.90, 0.0))
	anim.position_track_insert_key(t_pelvis, q3, Vector3(0.0, 0.90 + bounce_h, 0.0))
	anim.position_track_insert_key(t_pelvis, length_sec, Vector3(0.0, 0.90, 0.0))

	_insert_const_rot(anim, "Pelvis/Torso", Vector3(torso_lean, 0.0, 0.0), length_sec)

	var t_hl: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t_hl, NodePath("Pelvis/HipL"))
	anim.rotation_track_insert_key(t_hl, 0.0, Quaternion.from_euler(Vector3(leg_amp, 0.0, 0.0)))
	anim.rotation_track_insert_key(t_hl, q2, Quaternion.from_euler(Vector3(-leg_amp, 0.0, 0.0)))
	anim.rotation_track_insert_key(t_hl, length_sec, Quaternion.from_euler(Vector3(leg_amp, 0.0, 0.0)))

	var t_hr: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t_hr, NodePath("Pelvis/HipR"))
	anim.rotation_track_insert_key(t_hr, 0.0, Quaternion.from_euler(Vector3(-leg_amp, 0.0, 0.0)))
	anim.rotation_track_insert_key(t_hr, q2, Quaternion.from_euler(Vector3(leg_amp, 0.0, 0.0)))
	anim.rotation_track_insert_key(t_hr, length_sec, Quaternion.from_euler(Vector3(-leg_amp, 0.0, 0.0)))

	var t_sl: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t_sl, NodePath("Pelvis/Torso/ShoulderL"))
	anim.rotation_track_insert_key(t_sl, 0.0, Quaternion.from_euler(Vector3(-arm_amp, 0.0, -0.08)))
	anim.rotation_track_insert_key(t_sl, q2, Quaternion.from_euler(Vector3(arm_amp, 0.0, -0.08)))
	anim.rotation_track_insert_key(t_sl, length_sec, Quaternion.from_euler(Vector3(-arm_amp, 0.0, -0.08)))

	var t_sr: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(t_sr, NodePath("Pelvis/Torso/ShoulderR"))
	anim.rotation_track_insert_key(t_sr, 0.0, Quaternion.from_euler(Vector3(arm_amp, 0.0, 0.08)))
	anim.rotation_track_insert_key(t_sr, q2, Quaternion.from_euler(Vector3(-arm_amp, 0.0, 0.08)))
	anim.rotation_track_insert_key(t_sr, length_sec, Quaternion.from_euler(Vector3(arm_amp, 0.0, 0.08)))

	_insert_const_rot(anim, "Pelvis/HipL/ShinL", Vector3(-0.38, 0.0, 0.0), length_sec)
	_insert_const_rot(anim, "Pelvis/HipR/ShinR", Vector3(-0.38, 0.0, 0.0), length_sec)
	return anim


func _make_pose_anim(
	length_sec: float,
	looping: bool,
	pelvis_pos: Vector3,
	torso_rot: Vector3,
	arm_l_rot: Vector3,
	arm_r_rot: Vector3,
	hip_l_rot: Vector3,
	hip_r_rot: Vector3,
	shin_rot: Vector3
) -> Animation:
	var anim := Animation.new()
	anim.length = length_sec
	anim.loop_mode = Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE

	var tp: int = anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(tp, NodePath("Pelvis"))
	anim.position_track_insert_key(tp, 0.0, pelvis_pos)
	anim.position_track_insert_key(tp, length_sec, pelvis_pos)

	_insert_const_rot(anim, "Pelvis/Torso", torso_rot, length_sec)
	_insert_const_rot(anim, "Pelvis/Torso/ShoulderL", arm_l_rot, length_sec)
	_insert_const_rot(anim, "Pelvis/Torso/ShoulderR", arm_r_rot, length_sec)
	_insert_const_rot(anim, "Pelvis/HipL", hip_l_rot, length_sec)
	_insert_const_rot(anim, "Pelvis/HipR", hip_r_rot, length_sec)
	_insert_const_rot(anim, "Pelvis/HipL/ShinL", shin_rot, length_sec)
	_insert_const_rot(anim, "Pelvis/HipR/ShinR", shin_rot, length_sec)
	return anim


func _insert_const_rot(anim: Animation, path: String, euler: Vector3, length_sec: float) -> void:
	var idx: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(idx, NodePath(path))
	var q: Quaternion = Quaternion.from_euler(euler)
	anim.rotation_track_insert_key(idx, 0.0, q)
	anim.rotation_track_insert_key(idx, length_sec, q)
