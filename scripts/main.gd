extends Node3D
## Entry point: lighting/atmosphere, world generation, player and HUD.

const Config = preload("res://scripts/core/world_config.gd")
const Quality = preload("res://scripts/core/quality.gd")
const WorldGen = preload("res://scripts/world/world_generator.gd")
const Player = preload("res://player/player.gd")
const HUD = preload("res://ui/hud.gd")
const GraphicsSettings = preload("res://ui/graphics_settings.gd")

var world
var player
var hud: CanvasLayer
var environment: WorldEnvironment
var sun: DirectionalLight3D
var quality_name := "ultra"
var quality: Dictionary = Quality.PROFILES["ultra"].duplicate(true)
var platform_mode := "pc"
var graphics_settings


func _ready() -> void:
	_setup_environment()
	_setup_sun()

	world = WorldGen.new()
	world.name = "BTHWorld"
	add_child(world)

	player = Player.new()
	player.name = "Player"
	player.position = world.get_spawn_point()
	add_child(player)
	world.set_player(player)

	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	hud.bind(world, player, self)

	platform_mode = Quality.resolve_mode()
	apply_quality(Quality.resolve(), false)
	quality.merge(Quality.load_settings(), true)
	apply_graphics_settings(quality, false)
	graphics_settings = GraphicsSettings.new()
	graphics_settings.name = "GraphicsSettings"
	add_child(graphics_settings)
	graphics_settings.bind(self)

	print("[BTH] %s" % JSON.stringify(world.report()))
	print("[BTH] spawn at %s  region %s" % [
		player.global_position, world.field.region_at(player.global_position)])


# ---------------------------------------------------------------------------
# Quality profiles
# ---------------------------------------------------------------------------
func apply_quality(name: String, announce := true) -> void:
	if not Quality.has_profile(name):
		name = Quality.default_profile(platform_mode)
	quality_name = name
	quality = Quality.profile(name)
	quality_name = name

	var vp := get_viewport()
	if vp != null:
		vp.scaling_3d_scale = float(quality["render_scale"])
		vp.msaa_3d = int(quality["msaa"])

	if sun != null:
		sun.shadow_enabled = bool(quality.get("shadows", true))
		sun.directional_shadow_max_distance = float(quality["shadow_distance"])
		sun.shadow_blur = float(quality["shadow_blur"])

	if environment != null and environment.environment != null:
		var env := environment.environment
		env.ssao_enabled = bool(quality["ssao"])
		env.ssil_enabled = bool(quality["ssil"])
		env.volumetric_fog_enabled = bool(quality["volumetric_fog"])
		env.glow_enabled = bool(quality["glow"])

	Engine.max_fps = int(quality["max_fps"])

	if world != null:
		world.apply_quality(quality)
		if world.water != null:
			world.water.set_quality(quality)
		# Re-apply vegetation distances to already loaded chunks.
		if world.vegetation != null and world.player != null:
			for chunk in world.chunks.values():
				var c: Vector3 = chunk.world_center()
				var d := Vector2(c.x - world.player.global_position.x,
					c.z - world.player.global_position.z).length()
				world.vegetation.apply_lod(chunk, d)

	if hud != null:
		hud.set_quality(name, "%s / %s" % [platform_mode.to_upper(), str(quality["label"])])
	if announce:
		print("[BTH] quality -> %s (%s)" % [name, quality["label"]])
		Quality.save_state(platform_mode, name, quality)


func set_graphics_mode(mode: String) -> void:
	if mode not in ["pc", "phone"]:
		return
	platform_mode = mode
	Quality.save_mode(mode)
	apply_quality(Quality.default_profile(mode))

func apply_graphics_settings(values: Dictionary, persist := true) -> void:
	quality.merge(values, true)
	quality_name = "custom"
	_apply_quality_values()
	if persist:
		Quality.save_state(platform_mode, quality_name, quality)

func open_graphics_settings() -> void:
	if graphics_settings != null:
		graphics_settings.open_settings(platform_mode, quality_name, quality)

func _apply_quality_values() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.scaling_3d_scale = clampf(float(quality.get("render_scale", 1.0)), 0.5, 1.0)
		vp.msaa_3d = int(quality.get("msaa", 0))
	if sun != null:
		sun.shadow_enabled = bool(quality.get("shadows", true))
		sun.directional_shadow_max_distance = float(quality.get("shadow_distance", 240.0))
		sun.shadow_blur = float(quality.get("shadow_blur", 0.9))
	if environment != null and environment.environment != null:
		var env := environment.environment
		env.ssao_enabled = bool(quality.get("ssao", false))
		env.ssil_enabled = bool(quality.get("ssil", false))
		env.volumetric_fog_enabled = bool(quality.get("volumetric_fog", false))
		env.glow_enabled = bool(quality.get("glow", true))
	Engine.max_fps = int(quality.get("max_fps", 0))
	if world != null:
		world.apply_quality(quality)
		if world.water != null:
			world.water.set_quality(quality)
		if world.vegetation != null and world.player != null:
			for chunk in world.chunks.values():
				var center: Vector3 = chunk.world_center()
				var distance := Vector2(center.x - world.player.global_position.x, center.z - world.player.global_position.z).length()
				world.vegetation.apply_lod(chunk, distance)
	if hud != null:
		hud.set_quality(quality_name, "%s / %s" % [platform_mode.to_upper(), str(quality.get("label", "Custom"))])
	Quality.save_state(platform_mode, quality_name, quality)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo \
			and (event as InputEventKey).keycode == KEY_F1:
		apply_quality(Quality.next(quality_name))


func _setup_environment() -> void:
	environment = WorldEnvironment.new()
	environment.name = "Atmosphere"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	var panorama := PanoramaSkyMaterial.new()
	panorama.panorama = load("res://assets/hdri/belfast_sunset_puresky_2k.hdr")
	panorama.energy_multiplier = 0.95
	sky.sky_material = panorama
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.85
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.tonemap_white = 6.0

	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.9
	env.ssao_power = 1.6
	env.ssao_detail = 0.7
	env.ssil_enabled = true
	env.ssil_intensity = 0.7
	env.ssil_radius = 6.0
	env.ssil_normal_rejection = 1.2

	env.glow_enabled = true
	env.glow_intensity = 0.32
	env.glow_strength = 1.0
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.15

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color(0.78, 0.72, 0.60)
	env.fog_light_energy = 0.55
	env.fog_sun_scatter = 0.32
	env.fog_density = 0.0026
	env.fog_aerial_perspective = 0.55
	env.fog_sky_affect = 0.25

	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0075
	env.volumetric_fog_albedo = Color(0.92, 0.86, 0.76)
	env.volumetric_fog_emission = Color(0.06, 0.05, 0.04)
	env.volumetric_fog_length = 110.0
	env.volumetric_fog_detail_spread = 1.6
	env.volumetric_fog_anisotropy = 0.35
	env.volumetric_fog_ambient_inject = 0.4

	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.03
	env.adjustment_saturation = 1.04

	environment.environment = env
	add_child(environment)


func _setup_sun() -> void:
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.86, 0.69)
	sun.light_energy = 1.75
	sun.light_angular_distance = 0.7
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 420.0
	sun.directional_shadow_split_1 = 0.12
	sun.directional_shadow_split_2 = 0.28
	sun.directional_shadow_split_3 = 0.62
	sun.shadow_bias = 0.035
	sun.shadow_normal_bias = 1.4
	sun.shadow_blur = 1.2
	sun.rotation_degrees = Vector3(-31.0, -116.0, 0.0)
	add_child(sun)
