shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_toon, specular_toon;

// Crisp 2-band anime cel-shading shader for PHANTOM COURT ONLINE characters.
// Preserves team jersey color readability with stepped shadow tinting,
// hard anime specular highlight, and Fresnel rim separation.

uniform vec4 albedo_color : source_color = vec4(0.12, 0.45, 0.92, 1.0);
uniform vec4 rim_color : source_color = vec4(0.35, 0.92, 1.0, 1.0);
uniform float rim_strength : hint_range(0.0, 2.5) = 0.72;
uniform vec4 shadow_tint : source_color = vec4(0.24, 0.26, 0.40, 1.0);
uniform float cel_threshold : hint_range(-0.5, 0.8) = 0.08;
uniform float cel_smoothness : hint_range(0.005, 0.25) = 0.045;
uniform float rim_power : hint_range(1.0, 8.0) = 3.2;
uniform float specular_strength : hint_range(0.0, 1.5) = 0.28;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy : hint_range(0.0, 4.0) = 0.0;

void fragment() {
	ALBEDO = albedo_color.rgb;
	ROUGHNESS = 0.52;
	METALLIC = 0.04;

	vec3 n = length(NORMAL) > 1e-5 ? normalize(NORMAL) : vec3(0.0, 1.0, 0.0);
	vec3 v = length(VIEW) > 1e-5 ? normalize(VIEW) : vec3(0.0, 0.0, 1.0);
	float ndotv = clamp(abs(dot(n, v)), 0.0, 1.0);
	float fresnel = pow(max(1.0 - ndotv, 0.0001), rim_power);
	float rim_step = smoothstep(0.42, 0.78, fresnel);

	EMISSION = emission_color.rgb * emission_energy + rim_color.rgb * (rim_step * rim_strength * 0.35);
}

void light() {
	vec3 n = length(NORMAL) > 1e-5 ? normalize(NORMAL) : vec3(0.0, 1.0, 0.0);
	vec3 l = length(LIGHT) > 1e-5 ? normalize(LIGHT) : vec3(0.0, 1.0, 0.0);
	vec3 v = length(VIEW) > 1e-5 ? normalize(VIEW) : vec3(0.0, 0.0, 1.0);

	float ndotl = dot(n, l);
	float lit_signal = ndotl * ATTENUATION;
	float cel_band = smoothstep(cel_threshold - cel_smoothness, cel_threshold + cel_smoothness, lit_signal);

	// 2-band anime shade: crisp shadow tint in shadow band, vibrant lit tone in light band
	vec3 shade_rgb = mix(shadow_tint.rgb, vec3(1.0), cel_band);
	DIFFUSE_LIGHT += ALBEDO * shade_rgb * LIGHT_COLOR * 0.85;

	// Hard stylized anime specular highlight
	vec3 half_raw = l + v;
	vec3 h = length(half_raw) > 1e-5 ? normalize(half_raw) : n;
	float ndoth = clamp(dot(n, h), 0.0, 1.0);
	float spec_band = smoothstep(0.86, 0.91, ndoth) * cel_band;

	// Light-facing Fresnel rim accent for strong silhouette readability
	float ndotv = clamp(abs(dot(n, v)), 0.0, 1.0);
	float rim = pow(max(1.0 - ndotv, 0.0001), rim_power);
	float rim_band = smoothstep(0.45, 0.80, rim) * smoothstep(-0.15, 0.25, ndotl);

	SPECULAR_LIGHT += (LIGHT_COLOR * (spec_band * specular_strength) + rim_color.rgb * (rim_band * rim_strength * 0.65)) * ATTENUATION;
}
