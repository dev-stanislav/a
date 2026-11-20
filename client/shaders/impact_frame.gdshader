shader_type canvas_item;
render_mode blend_mix, unshaded;

// 2-3 frame high-contrast anime monochrome impact-frame flash shader.
// Combines radial manga ink-burst lines with thresholded screen luminance inversion.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float flash_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 flash_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 ink_color : source_color = vec4(0.04, 0.05, 0.09, 1.0);
uniform float invert_mix : hint_range(0.0, 1.0) = 0.65;

void fragment() {
	float strength = clamp(flash_strength, 0.0, 1.0);
	vec2 centered = UV - vec2(0.5, 0.5);
	float dist = length(centered);
	float angle = dist > 1e-5 ? atan(centered.y, centered.x) : 0.0;

	// High-contrast radial anime manga ink burst
	float burst_wave = sin(angle * 34.0) * cos(angle * 19.0 + 0.7);
	float ink_rays = smoothstep(0.18, 0.62, burst_wave) * smoothstep(0.18, 0.65, dist);

	// Thresholded monochrome luminance invert flash of the rendered viewport
	vec3 screen_rgb = texture(screen_texture, SCREEN_UV).rgb;
	float luma = dot(screen_rgb, vec3(0.299, 0.587, 0.114));
	float inverted_bw = step(0.42, 1.0 - luma);
	vec3 bw_col = mix(ink_color.rgb, flash_color.rgb, inverted_bw);

	// Crisp white core flash framed by bold radial ink spikes
	vec3 burst_col = mix(flash_color.rgb, ink_color.rgb, ink_rays * 0.85);
	vec3 final_rgb = mix(burst_col, bw_col, invert_mix * 0.55);

	float alpha = clamp((0.68 + ink_rays * 0.27) * strength, 0.0, 0.92);
	COLOR = vec4(final_rgb, alpha);
}
