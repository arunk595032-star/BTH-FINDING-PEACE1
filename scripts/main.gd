extends Node3D
## Entry point: lighting/atmosphere, world generation, player and HUD.

const Config = preload("res://scripts/core/world_config.gd")
const WorldGen = preload("res://scripts/world/world_generator.gd")
const Player = preload("res://player/player.gd")
const HUD = preload("res://ui/hud.gd")

var world
var player
var hud: CanvasLayer
var environment: WorldEnvironment
var sun: DirectionalLight3D


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
	hud.bind(world, player)

	print("[BTH] %s" % JSON.stringify(world.report()))
	print("[BTH] spawn at %s  region %s" % [
		player.global_position, world.field.region_at(player.global_position)])


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
