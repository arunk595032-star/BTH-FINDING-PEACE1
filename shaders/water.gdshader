// River / lake water.
// Depth-aware colour ramp, shoreline foam, sky radiance reflections, screen
// space refraction and two scrolling normal layers.  The water mesh carries
// the river's flow direction in vertex colour.rg encoded as 0..1.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D ripple_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D sky_equirect : source_color, filter_linear_mipmap, repeat_enable;

uniform vec3 shallow_color : source_color = vec3(0.10, 0.26, 0.24);
uniform vec3 mid_color : source_color = vec3(0.035, 0.13, 0.15);
uniform vec3 deep_color : source_color = vec3(0.012, 0.035, 0.045);
uniform float flow_speed = 0.55;
uniform float wave_strength = 0.08;
uniform float foam_amount = 0.75;
uniform float clarity = 0.9;
uniform float reflection_strength = 0.85;
uniform float alpha_min = 0.72;
// Distant water keeps the depth colour, sky reflection and fresnel, but skips
// the screen-space refraction sample, the second ripple layer and the foam
// noise sample.  Near water is unchanged.
uniform float detail_distance = 110.0;

varying vec3 v_wpos;
varying vec2 v_flow;
varying float v_shore;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_flow = COLOR.rg * 2.0 - 1.0;
	v_shore = COLOR.b;
	// Gentle swell, stronger away from the banks.
	float swell = sin(v_wpos.x * 0.12 + TIME * 0.9) * cos(v_wpos.z * 0.15 - TIME * 0.7);
	VERTEX.y += swell * wave_strength * (1.0 - v_shore);
}

void fragment() {
	float scene_depth = 0.0;
	{
		float raw = texture(depth_tex, SCREEN_UV).r;
		vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
		vec4 view = INV_PROJECTION_MATRIX * ndc;
		view.xyz /= view.w;
		scene_depth = -view.z;
	}
	float water_depth = -VERTEX.z;
	float depth = clamp(scene_depth - water_depth, 0.0, 40.0);

	float cam_dist = length(v_wpos - INV_VIEW_MATRIX[3].xyz);
	vec2 flow = normalize(v_flow + vec2(0.0001));
	vec2 uv1 = v_wpos.xz * 0.055 + flow * TIME * flow_speed * 0.12;
	vec2 uv2 = v_wpos.xz * 0.16 - flow * TIME * flow_speed * 0.2;
	vec3 n1 = texture(ripple_tex, uv1).rgb * 2.0 - 1.0;
	vec3 n2 = n1;
	if (cam_dist < detail_distance) {
		n2 = texture(ripple_tex, uv2).rgb * 2.0 - 1.0;
	}
	vec3 rn = normalize(vec3((n1.x + n2.x * 0.6) * 0.55, 1.0, (n1.y + n2.y * 0.6) * 0.55));
	NORMAL = normalize((VIEW_MATRIX * vec4(rn, 0.0)).xyz);

	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	fres = mix(0.02, 1.0, fres);

	vec3 refracted = vec3(0.0);
	if (cam_dist < detail_distance) {
		vec2 refr_uv = SCREEN_UV + rn.xz * 0.035 * clamp(depth * 0.5, 0.0, 1.0);
		refracted = textureLod(screen_tex, refr_uv, 0.0).rgb;
	}
	// Sky reflection sampled from the same HDRI the world uses (equirectangular).
	vec3 refl_dir = reflect(-VIEW, NORMAL);
	vec2 sky_uv = vec2(atan(refl_dir.z, refl_dir.x) / 6.2831853 + 0.5,
		acos(clamp(refl_dir.y, -1.0, 1.0)) / 3.1415926);
	vec3 reflected = textureLod(sky_equirect, sky_uv, 2.0).rgb;

	vec3 body = mix(shallow_color, mid_color, smoothstep(0.15, 1.5, depth));
	body = mix(body, deep_color, smoothstep(1.5, 5.0, depth));
	body *= 0.9 + n1.x * 0.15;

	if (cam_dist >= detail_distance) {
		refracted = body;
	}
	vec3 water_col = mix(refracted * 0.55 + body, reflected, fres * reflection_strength);
	water_col = mix(water_col, reflected, fres * 0.35);

	// Foam: shoreline band plus streak noise on faster water.
	float foam_noise = 0.55;
	if (cam_dist < detail_distance) {
		foam_noise = texture(ripple_tex, v_wpos.xz * 0.22 + flow * TIME * 0.15).b;
	}
	float shore = 1.0 - smoothstep(0.0, 0.55, depth);
	float foam = shore * (0.55 + 0.45 * foam_noise) * foam_amount;
	foam += smoothstep(0.72, 0.95, foam_noise) * 0.25 * foam_amount * (1.0 - smoothstep(0.4, 3.0, depth));
	foam = clamp(foam, 0.0, 1.0);

	ALBEDO = mix(water_col, vec3(0.94, 0.97, 0.98), foam * 0.9);
	ROUGHNESS = mix(0.035, 0.55, foam);
	SPECULAR = 0.85;
	METALLIC = 0.0;
	EMISSION = body * 0.03 + foam * 0.02;

	float a = mix(alpha_min, 0.96, clamp(fres, 0.0, 1.0));
	a = mix(a, 0.97, foam);
	ALPHA = clamp(a * smoothstep(0.0, 0.08, depth + foam * 0.12), 0.0, 0.98);
}
