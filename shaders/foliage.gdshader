// Alpha-scissored vegetation cards (conifer branches, leaves, grass, ferns).
// Wind sway is applied per vertex in world space so MultiMesh forests move as
// one continuous canopy rather than rigid copies.
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float wind_strength = 0.35;
uniform float wind_speed = 1.1;
uniform float alpha_cutoff = 0.42;
uniform float translucency = 0.25;
uniform float roughness_value = 0.82;
uniform float use_vertex_color = 0.0;

void vertex() {
	vec3 world_origin = MODEL_MATRIX[3].xyz;
	float phase = world_origin.x * 0.12 + world_origin.z * 0.09;
	float sway = sin(TIME * wind_speed + phase) * 0.6 + sin(TIME * wind_speed * 2.3 + phase * 1.7) * 0.4;
	float height_factor = max(VERTEX.y, 0.0);
	VERTEX.x += sway * wind_strength * height_factor * 0.06;
	VERTEX.z += cos(TIME * wind_speed * 0.8 + phase) * wind_strength * height_factor * 0.04;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	if (tex.a < alpha_cutoff) {
		discard;
	}
	vec3 col = tex.rgb * tint.rgb;
	if (use_vertex_color > 0.5) {
		col *= COLOR.rgb;
	}
	ALBEDO = col;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.25;
	BACKLIGHT = col * translucency;
	ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
	ALPHA = tex.a;
}
