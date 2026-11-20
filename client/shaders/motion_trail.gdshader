shader_type spatial;
render_mode blend_add, cull_disabled, unshaded, depth_draw_never;

// Stylized anime additive energy ribbon trail shader for ball arcs & player dash bursts.

uniform vec4 trail_color : source_color = vec4(0.0, 0.92, 1.0, 1.0);
uniform float intensity : hint_range(0.0, 4.0) = 1.35;
uniform float electric_speed : hint_range(0.0, 20.0) = 8.0;

void fragment() {
	float u_long = clamp(UV.x, 0.0, 1.0);
	float u_cross = abs(UV.y - 0.5) * 2.0; // 0 at ribbon spine, 1 at outer edges

	// Smooth tail-to-head fade with soft cap right at the leading edge
	float length_fade = pow(max(u_long, 0.0001), 1.45) * (1.0 - smoothstep(0.95, 1.0, u_long) * 0.25);

	// Bright anime core + glowing electric outer edge streaks
	float core_mask = 1.0 - smoothstep(0.0, 0.78, u_cross);
	float edge_mask = smoothstep(0.45, 0.82, u_cross) * (1.0 - smoothstep(0.86, 1.0, u_cross));

	float crackle = 0.72 + 0.28 * sin(u_long * 26.0 - TIME * electric_speed) * cos(UV.y * 14.0 + TIME * (electric_speed * 0.6));
	float energy = (core_mask * 0.85 + edge_mask * 1.10) * length_fade * crackle * max(intensity, 0.0);

	vec3 tinted = trail_color.rgb * COLOR.rgb;
	vec3 final_rgb = mix(tinted, vec3(1.0, 1.0, 1.0), clamp(core_mask * 0.45 + edge_mask * 0.25, 0.0, 0.70));

	ALBEDO = final_rgb * energy;
	ALPHA = clamp(energy * COLOR.a, 0.0, 1.0);
}
