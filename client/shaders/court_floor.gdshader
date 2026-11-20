shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

// Stylized anime indoor gymnasium polished maple hardwood floor shader.
// Procedural staggered planks, fine wood grain, subtle varnish specular sheen,
// and crisp center-court Phantom ring accent with high ball/line readability.

uniform vec4 wood_light_color : source_color = vec4(0.84, 0.62, 0.37, 1.0);
uniform vec4 wood_dark_color : source_color = vec4(0.74, 0.52, 0.29, 1.0);
uniform vec4 seam_color : source_color = vec4(0.46, 0.31, 0.17, 1.0);
uniform vec4 accent_ring_color : source_color = vec4(0.08, 0.80, 0.98, 1.0);
uniform float plank_width : hint_range(0.08, 1.0) = 0.24;
uniform float plank_length : hint_range(0.5, 6.0) = 2.6;
uniform float varnish_roughness : hint_range(0.08, 0.75) = 0.24;
uniform float varnish_specular : hint_range(0.0, 1.0) = 0.68;
uniform float ring_glow_strength : hint_range(0.0, 2.0) = 0.32;

varying vec3 v_world_pos;

float hash12(vec2 p) {
	vec2 q = fract(p * vec2(234.34, 435.345));
	q += dot(q, q + 34.23);
	return fract(q.x * q.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float pw = max(plank_width, 0.05);
	float pl = max(plank_length, 0.25);

	float col_id = floor(v_world_pos.x / pw);
	float stagger = hash12(vec2(col_id, 13.7)) * pl;
	float row_id = floor((v_world_pos.z + stagger) / pl);

	float local_x = fract(v_world_pos.x / pw);
	float local_z = fract((v_world_pos.z + stagger) / pl);

	// Per-plank natural maple variation + alternating court lane depth
	float plank_seed = hash12(vec2(col_id, row_id));
	float lane_tint = 0.5 + 0.5 * sin(floor(v_world_pos.x) * 3.14159);
	vec3 base_wood = mix(wood_dark_color.rgb, wood_light_color.rgb, clamp(plank_seed * 0.72 + lane_tint * 0.28, 0.0, 1.0));

	// Subtle procedural wood grain lines running along court Z length
	float n_grain = value_noise(vec2(v_world_pos.x * 16.0 + plank_seed * 12.0, v_world_pos.z * 1.8));
	float grain_wave = 0.5 + 0.5 * sin(v_world_pos.x * 88.0 + n_grain * 4.2 + plank_seed * 6.28);
	base_wood *= (0.955 + 0.075 * grain_wave);

	// Crisp subtle plank seams
	float edge_x = min(local_x, 1.0 - local_x);
	float edge_z = min(local_z, 1.0 - local_z);
	float seam_mask = 1.0 - smoothstep(0.012, 0.032, edge_x) * smoothstep(0.004, 0.012, edge_z);
	base_wood = mix(base_wood, seam_color.rgb, seam_mask * 0.42);

	// Stylized anime center-court Phantom double-ring inlay at (0, 0)
	float center_dist = length(v_world_pos.xz);
	float outer_ring = 1.0 - smoothstep(0.035, 0.075, abs(center_dist - 1.62));
	float inner_ring = 1.0 - smoothstep(0.025, 0.055, abs(center_dist - 1.18));
	float inner_disc = (1.0 - smoothstep(1.12, 1.22, center_dist)) * 0.14;
	float ring_mask = clamp(max(outer_ring, inner_ring * 0.80), 0.0, 1.0);

	vec3 final_albedo = mix(base_wood, accent_ring_color.rgb * 0.85, clamp(ring_mask * 0.65 + inner_disc, 0.0, 0.75));

	// Subtle court-center varnish sheen
	float sheen_var = value_noise(v_world_pos.xz * 0.45);
	ALBEDO = final_albedo;
	ROUGHNESS = clamp(varnish_roughness + (1.0 - grain_wave) * 0.06 + seam_mask * 0.18 + sheen_var * 0.06, 0.10, 0.60);
	METALLIC = 0.06;
	SPECULAR = varnish_specular;
	EMISSION = accent_ring_color.rgb * (ring_mask * ring_glow_strength);
}
