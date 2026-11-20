shader_type canvas_item;
render_mode blend_mix, unshaded;

// Screen-edge anime Zone Awakening vignette & radial speed-line pulse shader.

uniform vec4 vignette_color : source_color = vec4(0.15, 0.90, 1.0, 1.0);
uniform float intensity : hint_range(0.0, 2.0) = 0.0;
uniform float pulse_speed : hint_range(0.5, 10.0) = 3.8;

void fragment() {
	float clamped_intensity = max(intensity, 0.0);
	vec2 centered = UV - vec2(0.5, 0.5);
	float dist = length(centered * vec2(1.12, 1.32));
	float edge = smoothstep(0.36, 0.84, dist);

	float angle = length(centered) > 1e-5 ? atan(centered.y, centered.x) : 0.0;
	float t = TIME * pulse_speed;
	float wave_a = sin(angle * 26.0 + t * 2.1);
	float wave_b = cos(angle * 17.0 - t * 1.6);
	float streaks = pow(clamp(0.5 + 0.5 * wave_a * wave_b, 0.0, 1.0), 3.0);

	float pulse = 0.80 + 0.20 * sin(t * 2.5);
	float alpha = clamp((edge * 0.54 + edge * streaks * 0.34) * pulse * clamped_intensity, 0.0, 0.76);
	vec3 rgb = mix(vignette_color.rgb, vec3(1.0, 1.0, 1.0), clamp(edge * streaks * 0.48, 0.0, 0.65));

	COLOR = vec4(rgb, alpha);
}
