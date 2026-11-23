// Vertical waterfall sheet: scrolling foam streaks, alpha edges, misty base.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled, shadows_disabled;

uniform sampler2D streak_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 water_color : source_color = vec3(0.62, 0.72, 0.74);
uniform float scroll_speed = 1.6;
uniform float foam_amount = 0.9;
uniform float edge_softness = 0.28;

void fragment() {
	vec2 uv = UV;
	float t = TIME * scroll_speed;
	vec2 s1 = texture(streak_tex, vec2(uv.x * 1.4, uv.y * 2.2 - t)).rg;
	vec2 s2 = texture(streak_tex, vec2(uv.x * 2.6 + 0.31, uv.y * 3.4 - t * 1.4)).gb;
	float streak = (s1.r + s2.g) * 0.5;
	float foam = smoothstep(0.25, 0.85, streak) * foam_amount;
	// Soften the outer edges of the sheet.
	float edge = smoothstep(0.0, edge_softness, uv.x) * smoothstep(1.0, 1.0 - edge_softness, uv.x);
	ALBEDO = mix(water_color * 0.75, vec3(0.96, 0.98, 1.0), foam);
	ROUGHNESS = mix(0.12, 0.8, foam);
	ALPHA = clamp(edge * (0.42 + foam * 0.58), 0.0, 1.0);
	EMISSION = vec3(0.02, 0.03, 0.035) * foam;
	NORMAL_MAP_DEPTH = 0.0;
}
