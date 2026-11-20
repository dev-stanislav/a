shader_type spatial;
render_mode blend_add, depth_draw_opaque, cull_back, unshaded;

// Procedural anime Zone energy aura shader for PHANTOM COURT ONLINE.
// Features rising flame bands, sharp electric lightning streaks, Fresnel rim glow,
// and normal-directed vertex pulse displacement.

uniform vec4 aura_color : source_color = vec4(0.15, 0.90, 1.0, 1.0);
uniform float intensity : hint_range(0.0, 4.0) = 1.0;
uniform float pulse_speed : hint_range(0.1, 12.0) = 3.2;
uniform float fresnel_power : hint_range(0.5, 8.0) = 2.6;
uniform float displacement_strength : hint_range(0.0, 0.15) = 0.032;
uniform float lightning_strength : hint_range(0.0, 3.0) = 1.35;

varying vec3 v_local_pos;
varying float v_pulse;

float hash21(vec2 p) {
	vec2 q = fract(p * vec2(123.34, 456.21));
	q += dot(q, q + 45.32);
	return fract(q.x * q.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);

	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));

	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float total = 0.0;
	float amp = 0.55;
	vec2 shift = vec2(19.7, 37.3);
	for (int idx = 0; idx < 3; idx++) {
		total += value_noise(p) * amp;
		p = p * 2.05 + shift;
		amp *= 0.5;
	}
	return total;
}

float ridged_lightning(vec2 p) {
	float n = value_noise(p);
	float ridge = clamp(1.0 - abs(n * 2.0 - 1.0), 0.0, 1.0);
	return pow(max(ridge, 0.0001), 6.0);
}

void vertex() {
	float t = TIME * pulse_speed;
	float active_scale = clamp(intensity, 0.0, 2.5);
	float wave_a = sin(VERTEX.y * 8.5 - t * 2.8 + VERTEX.x * 5.0);
	float wave_b = cos(VERTEX.z * 7.5 - t * 3.6 + VERTEX.y * 4.2);
	float pulse_wave = 0.5 + 0.5 * (wave_a * 0.55 + wave_b * 0.45);
	float disp = (0.35 + 0.65 * pulse_wave) * active_scale * displacement_strength;
	vec3 n_dir = length(NORMAL) > 1e-5 ? normalize(NORMAL) : vec3(0.0, 1.0, 0.0);
	VERTEX += n_dir * disp;
	v_local_pos = VERTEX;
	v_pulse = 0.80 + 0.20 * sin(t * 2.2);
}

void fragment() {
	float clamped_intensity = max(intensity, 0.0);
	vec3 n = length(NORMAL) > 1e-5 ? normalize(NORMAL) : vec3(0.0, 1.0, 0.0);
	vec3 v = length(VIEW) > 1e-5 ? normalize(VIEW) : vec3(0.0, 0.0, 1.0);
	float ndotv = clamp(abs(dot(n, v)), 0.0, 1.0);
	float fresnel = pow(max(1.0 - ndotv, 0.0001), fresnel_power);

	float t = TIME * pulse_speed;
	float horiz_len = length(v_local_pos.xz);
	float angle = horiz_len > 1e-5 ? atan(v_local_pos.x, v_local_pos.z) : 0.0;

	// Seam-free periodic cylindrical domain for rising flame bands
	vec2 flame_uv_a = vec2(sin(angle) * 1.65 + cos(angle) * 0.85, v_local_pos.y * 2.35 - t * 1.35);
	vec2 flame_uv_b = vec2(cos(angle) * 2.10 - sin(angle) * 0.95, v_local_pos.y * 3.80 - t * 2.05);
	float flame_raw = fbm(flame_uv_a) * 0.65 + fbm(flame_uv_b) * 0.35;
	float flame_bands = smoothstep(0.28, 0.78, flame_raw);

	// Sharp animated lightning veins surging upward
	vec2 bolt_uv_a = vec2(sin(angle * 2.0) * 2.4 + floor(t * 6.0) * 0.17, v_local_pos.y * 4.2 - t * 2.9);
	vec2 bolt_uv_b = vec2(cos(angle * 3.0) * 2.8 - floor(t * 5.0) * 0.23, v_local_pos.y * 5.6 - t * 3.7);
	float lightning = max(ridged_lightning(bolt_uv_a), ridged_lightning(bolt_uv_b) * 0.85);
	lightning *= (0.35 + 0.65 * fresnel);

	// Soft capsule vertical envelope: grounded glow at feet, fiery tongues near crown
	float h_norm = clamp((v_local_pos.y + 1.0) * 0.5, 0.0, 1.0);
	float bottom_fade = smoothstep(0.0, 0.14, h_norm);
	float top_licks = 1.0 - smoothstep(0.70, 1.0, h_norm - flame_bands * 0.22);
	float vertical_mask = clamp(bottom_fade * top_licks, 0.0, 1.0);

	// Hot white-core anime tint on lightning bolts & crisp Fresnel edges
	float hot_mix = clamp(lightning * 0.78 + fresnel * 0.34, 0.0, 0.88);
	vec3 final_color = mix(aura_color.rgb, vec3(1.0, 1.0, 1.0), hot_mix);

	float rim_contrib = fresnel * (0.90 + 0.55 * flame_bands);
	float body_contrib = flame_bands * 0.28;
	float energy = (rim_contrib + body_contrib + lightning * lightning_strength) * vertical_mask * v_pulse * clamped_intensity;

	ALBEDO = final_color * energy;
	ALPHA = clamp(energy * 0.85, 0.0, 1.0);
}
