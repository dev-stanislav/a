shader_type canvas_item;
render_mode blend_mix, unshaded;

// Procedural screen-edge anime radial speed lines shader.
// Leaves the center play viewport completely clear for crisp gameplay readability.

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec4 line_color : source_color = vec4(0.90, 0.98, 1.0, 1.0);
uniform float line_density : hint_range(12.0, 120.0) = 56.0;
uniform float inner_clear_radius : hint_range(0.25, 0.70) = 0.44;
uniform float animation_speed : hint_range(1.0, 30.0) = 16.0;

float hash11(float p) {
	float q = fract(p * 0.1031);
	q *= q + 33.33;
	q *= q + q;
	return fract(q);
}

void fragment() {
	float clamped_int = clamp(intensity, 0.0, 1.0);
	vec2 centered = UV - vec2(0.5, 0.5);
	// Slight elliptical stretch so speed lines hug 16:9 screen borders evenly
	float dist = length(centered * vec2(1.05, 1.28));
	float angle = length(centered) > 1e-5 ? atan(centered.y, centered.x) : 0.0;

	// Discrete radial spokes with rapid anime frame stepping
	float sector = floor((angle + 3.14159265) / 6.2831853 * line_density);
	float sector_frac = fract((angle + 3.14159265) / 6.2831853 * line_density);
	float step_t = floor(TIME * animation_speed);
	float rnd_len = hash11(sector * 13.7 + step_t * 3.1);
	float rnd_vis = hash11(sector * 29.3 + step_t * 7.7);

	// Keep center play viewport strictly clear
	float spoke_start = inner_clear_radius + rnd_len * 0.22;
	float radial_mask = smoothstep(spoke_start, spoke_start + 0.14, dist);

	// Sharp tapered needle width per sector
	float half_width = mix(0.06, 0.18, rnd_vis);
	float needle = 1.0 - smoothstep(half_width * 0.4, half_width, abs(sector_frac - 0.5));
	float active_spoke = step(0.32, rnd_vis);

	float alpha = clamp(radial_mask * needle * active_spoke * clamped_int * 0.78, 0.0, 0.80);
	COLOR = vec4(line_color.rgb, alpha);
}
