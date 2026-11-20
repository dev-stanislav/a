shader_type spatial;
render_mode cull_front, unshaded, depth_draw_opaque;

// Inverted-hull vertex-normal extruded anime ink outline shader.
// Attach cleanly as `next_pass` on `cel_character.gdshader` materials.

uniform float outline_width : hint_range(0.0, 0.08) = 0.018;
uniform vec4 outline_color : source_color = vec4(0.039, 0.051, 0.086, 1.0);

void vertex() {
	vec3 n_dir = length(NORMAL) > 1e-5 ? normalize(NORMAL) : vec3(0.0, 1.0, 0.0);
	VERTEX += n_dir * max(outline_width, 0.0);
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
