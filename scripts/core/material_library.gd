extends RefCounted
## Material factory.  Every material points at a real, license-checked file in
## assets/; if an optional asset has not been installed the factory falls back
## to a tuned flat colour so the world still builds.

const STONE_ALBEDO := "res://assets/materials/ambientcg/Rock064/Rock064_1K-JPG_Color.jpg"
const STONE_NORMAL := "res://assets/materials/ambientcg/Rock064/Rock064_1K-JPG_NormalGL.jpg"
const STONE_ROUGH := "res://assets/materials/ambientcg/Rock064/Rock064_1K-JPG_Roughness.jpg"

const BRICK_ALBEDO := "res://assets/materials/ambientcg/Bricks105/Bricks105_1K-JPG_Color.jpg"
const BRICK_NORMAL := "res://assets/materials/ambientcg/Bricks105/Bricks105_1K-JPG_NormalGL.jpg"
const BRICK_ROUGH := "res://assets/materials/ambientcg/Bricks105/Bricks105_1K-JPG_Roughness.jpg"

const PLASTER_ALBEDO := "res://assets/materials/ambientcg/Plaster001/Plaster001_1K-JPG_Color.jpg"
const PLASTER_NORMAL := "res://assets/materials/ambientcg/Plaster001/Plaster001_1K-JPG_NormalGL.jpg"

const TIMBER_ALBEDO := "res://assets/materials/ambientcg/Planks040/Planks040_1K-JPG_Color.jpg"
const TIMBER_NORMAL := "res://assets/materials/ambientcg/Planks040/Planks040_1K-JPG_NormalGL.jpg"
const TIMBER_ROUGH := "res://assets/materials/ambientcg/Planks040/Planks040_1K-JPG_Roughness.jpg"

const ROOF_ALBEDO := "res://assets/materials/ambientcg/RoofingTiles013A/RoofingTiles013A_1K-JPG_Color.jpg"
const ROOF_NORMAL := "res://assets/materials/ambientcg/RoofingTiles013A/RoofingTiles013A_1K-JPG_NormalGL.jpg"

const GROUND_ALBEDO := "res://assets/materials/ambientcg/Ground037/Ground037_1K-JPG_Color.jpg"
const GROUND_NORMAL := "res://assets/materials/ambientcg/Ground037/Ground037_1K-JPG_NormalGL.jpg"

const BARK_ALBEDO := "res://assets/textures/terrain/bark_brown_02_diff.jpg"
const BARK_NORMAL := "res://assets/textures/terrain/bark_brown_02_nor.jpg"
const WOOD_ALBEDO := "res://assets/textures/terrain/medieval_wood_diff.jpg"
const WOOD_NORMAL := "res://assets/textures/terrain/medieval_wood_nor.jpg"

static var _cache: Dictionary = {}


static func _tex(path: String, normal := false) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	var t = load(path)
	return t as Texture2D


static func _std(albedo_path: String, normal_path := "", rough_path := "",
		fallback := Color(0.5, 0.5, 0.5), uv_scale := 1.0) -> StandardMaterial3D:
	var key := albedo_path + "|" + normal_path + "|" + rough_path + "|" + str(uv_scale) + "|" + fallback.to_html()
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = fallback
	var alb := _tex(albedo_path)
	if alb != null:
		m.albedo_texture = alb
		m.albedo_color = Color.WHITE
		m.uv1_scale = Vector3(uv_scale, uv_scale, 1.0)
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var nrm := _tex(normal_path)
	if nrm != null:
		m.normal_enabled = true
		m.normal_texture = nrm
		m.normal_scale = 1.0
	var rgh := _tex(rough_path)
	if rgh != null:
		m.roughness_texture = rgh
		m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	else:
		m.roughness = 0.85
	_cache[key] = m
	return m


static func stone() -> StandardMaterial3D:
	return _std(STONE_ALBEDO, STONE_NORMAL, STONE_ROUGH, Color(0.46, 0.45, 0.42), 1.0)


static func brick() -> StandardMaterial3D:
	return _std(BRICK_ALBEDO, BRICK_NORMAL, BRICK_ROUGH, Color(0.44, 0.42, 0.38), 1.0)


static func plaster() -> StandardMaterial3D:
	return _std(PLASTER_ALBEDO, PLASTER_NORMAL, "", Color(0.72, 0.68, 0.58), 1.0)


static func timber() -> StandardMaterial3D:
	return _std(TIMBER_ALBEDO, TIMBER_NORMAL, TIMBER_ROUGH, Color(0.30, 0.21, 0.14), 1.0)


static func wood() -> StandardMaterial3D:
	return _std(WOOD_ALBEDO, WOOD_NORMAL, "", Color(0.35, 0.25, 0.17), 1.0)


static func bark() -> StandardMaterial3D:
	return _std(BARK_ALBEDO, BARK_NORMAL, "", Color(0.30, 0.24, 0.19), 1.0)


static func roof() -> StandardMaterial3D:
	return _std(ROOF_ALBEDO, ROOF_NORMAL, "", Color(0.33, 0.20, 0.16), 1.0)


static func ground() -> StandardMaterial3D:
	return _std(GROUND_ALBEDO, GROUND_NORMAL, "", Color(0.33, 0.27, 0.20), 2.0)


static func cobble() -> StandardMaterial3D:
	return _std("res://assets/textures/terrain/gravel_diff.jpg",
		"res://assets/textures/terrain/gravel_nor.jpg",
		"res://assets/textures/terrain/gravel_arm.jpg", Color(0.34, 0.33, 0.31), 1.6)


static func plain(color: Color, roughness := 0.9) -> StandardMaterial3D:
	var key := "plain|" + color.to_html() + "|" + str(roughness)
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	_cache[key] = m
	return m
