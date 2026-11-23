// BEYOND THE HORIZON - terrain material.
//
// Layer blend driven by a baked world mask (RGBA):
//   R = road (packed dirt / gravel carriageway)
//   G = wet river bank + river bed
//   B = foot trail
//   A = forest floor litter
// Height, slope and macro noise add grass / rock / scree variation so the
// valley never shows a visible material border.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D tex_grass : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_forest : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_rock : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_gravel : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_mud : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D nrm_grass : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D nrm_rock : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D nrm_gravel : hint_normal, filter_linear_mipmap, repeat_enable;

uniform sampler2D arm_grass : filter_linear_mipmap, repeat_enable;
uniform sampler2D arm_rock : filter_linear_mipmap, repeat_enable;
uniform sampler2D arm_gravel : filter_linear_mipmap, repeat_enable;

uniform sampler2D world_mask : filter_linear, repeat_disable;
uniform vec2 mask_origin = vec2(-1024.0, -1024.0);
uniform float mask_size = 2048.0;

uniform float detail_scale = 0.30;
uniform float macro_amount = 0.22;
uniform float snow_height = 260.0;
uniform float wet_darkening = 0.45;

varying vec3 v_wpos;
varying vec3 v_wnrm;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

vec3 layer(sampler2D tex, vec2 uv, vec2 dx, vec2 dy, float tile) {
	return textureGrad(tex, uv / tile, dx / tile, dy / tile).rgb;
}

vec3 blend_triplanar(sampler2D tex, vec2 uv_top, vec2 uv_side, vec2 dx, vec2 dy,
		vec2 dxs, vec2 dys, float tile, float steep) {
	vec3 top = textureGrad(tex, uv_top / tile, dx / tile, dy / tile).rgb;
	vec3 side = textureGrad(tex, uv_side / tile, dxs / tile, dys / tile).rgb;
	return mix(top, side * 0.94, steep);
}

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv = v_wpos.xz * detail_scale;
	vec2 dx = dFdx(v_wpos.xz) * detail_scale;
	vec2 dy = dFdy(v_wpos.xz) * detail_scale;
	vec2 muv = (v_wpos.xz - mask_origin) / mask_size;
	vec4 mask = texture(world_mask, muv);

	float slope = 1.0 - clamp(v_wnrm.y, 0.0, 1.0);
	float height = v_wpos.y;

	// Secondary slope sample projected on XY for cliff faces.
	vec2 uv_side = vec2(v_wpos.x + v_wpos.z, v_wpos.y * 1.6);
	vec2 dxs = dFdx(uv_side);
	vec2 dys = dFdy(uv_side);
	float steep = smoothstep(0.16, 0.52, slope);

	// --- weights -----------------------------------------------------------
	float w_road = clamp(mask.r, 0.0, 1.0);
	float w_trail = clamp(mask.b, 0.0, 1.0);
	float w_wet = clamp(mask.g, 0.0, 1.0);
	float w_forest = clamp(mask.a, 0.0, 1.0);

	float n_large = vnoise(v_wpos.xz * 0.013);
	float n_mid = vnoise(v_wpos.xz * 0.07);
	float n_small = vnoise(v_wpos.xz * 0.31);

	float w_rock = smoothstep(0.24, 0.62, slope + (n_large - 0.5) * 0.16);
	w_rock = max(w_rock, smoothstep(190.0, 245.0, height) * 0.85);
	w_rock = max(w_rock, smoothstep(0.75, 0.95, n_large) * smoothstep(60.0, 140.0, height) * 0.55);

	float w_grass = max(0.0, 1.0 - w_rock - w_road - w_trail - w_wet);
	float w_forest_final = w_forest * w_grass * 0.9;
	w_grass = max(0.0, w_grass - w_forest_final * 0.65);
	float total = max(w_grass + w_forest_final + w_rock + w_road + w_trail + w_wet, 0.001);
	w_grass /= total;
	w_forest_final /= total;
	w_rock /= total;
	w_road /= total;
	w_trail /= total;
	w_wet /= total;

	// --- albedo ------------------------------------------------------------
	vec3 grass = layer(tex_grass, uv, dx, dy, 3.2);
	vec3 forest = layer(tex_forest, uv + vec2(0.37), dx, dy, 4.0);
	vec3 rock = blend_triplanar(tex_rock, uv, uv_side, dx, dy, dxs, dys, 6.0, steep);
	vec3 gravel = layer(tex_gravel, uv, dx, dy, 2.2);
	vec3 mud = layer(tex_mud, uv + vec2(0.61), dx, dy, 3.4);

	// Fine moss / grass speckle on rock keeps cliffs from looking painted.
	rock = mix(rock, grass * 0.72, smoothstep(0.35, 0.8, n_mid) * 0.35 * (1.0 - steep));

	vec3 albedo = grass * w_grass + forest * w_forest_final + rock * w_rock
		+ gravel * (w_road + w_trail) + mud * w_wet;

	// Macro colour variation (breaks up tiling at distance).
	float macro = vnoise(v_wpos.xz * 0.0042) * 0.6 + vnoise(v_wpos.xz * 0.021) * 0.4;
	albedo *= 1.0 - macro_amount * 0.5 + macro_amount * macro;
	albedo *= mix(0.86, 1.06, n_mid);

	// Wet surfaces are darker and sheen.
	albedo *= 1.0 - w_wet * wet_darkening;
	// Snow dusting on the highest peaks.
	float snow = smoothstep(snow_height, snow_height + 40.0, height + (n_large - 0.5) * 24.0);
	snow *= smoothstep(0.2, 0.55, v_wnrm.y);
	albedo = mix(albedo, vec3(0.86, 0.89, 0.93), snow * 0.85);

	// --- normal / roughness ------------------------------------------------
	vec3 ng = texture(nrm_grass, uv / 3.2).rgb * 2.0 - 1.0;
	vec3 nr = texture(nrm_rock, uv / 6.0).rgb * 2.0 - 1.0;
	vec3 nv = texture(nrm_gravel, uv / 2.2).rgb * 2.0 - 1.0;
	vec3 nmix = normalize(mix(mix(ng, nv, clamp(w_road + w_trail, 0.0, 1.0)), nr, w_rock));
	NORMAL_MAP = nmix * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.85;

	float rough_grass = texture(arm_grass, uv / 3.2).g;
	float rough_rock = texture(arm_rock, uv / 6.0).g;
	float rough_gravel = texture(arm_gravel, uv / 2.2).g;
	float roughness = rough_grass * (w_grass + w_forest_final) + rough_rock * w_rock
		+ rough_gravel * (w_road + w_trail) + 0.55 * w_wet;
	ROUGHNESS = clamp(mix(roughness, 0.06, w_wet * 0.7), 0.05, 1.0);
	SPECULAR = mix(0.35, 0.9, w_wet);
	AO = mix(0.75 + n_small * 0.25, 1.0, 1.0 - slope);
	AO_LIGHT_AFFECT = 0.35;

	ALBEDO = albedo;
}
