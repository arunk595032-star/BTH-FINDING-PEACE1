extends Node3D
## Builds and streams the BTH open world.
##
## Layered approach:
##   * one coarse "far terrain" mesh (8 m lattice) drawn only beyond ~520 m so
##     the mountain skyline is always present;
##   * 128 m detailed chunks with distance-based Trimesh collision, streamed around
##     the player;
##   * vegetation MultiMeshes per chunk with per-layer distance culling;
##   * water, settlements and bridges built once.

const Config = preload("res://scripts/core/world_config.gd")
const TerrainField = preload("res://scripts/world/terrain_field.gd")
const TerrainChunk = preload("res://scripts/world/terrain_chunk.gd")
const Vegetation = preload("res://scripts/world/vegetation.gd")
const WaterBuilder = preload("res://scripts/world/water_builder.gd")
const Structures = preload("res://scripts/world/structures.gd")

const FAR_SEGMENTS := 256
const FAR_HIDE := 430.0
const CHUNK_BUDGET_PER_FRAME := 3
const PREDICT_SECONDS := 1.6
const PREDICT_MAX_DIST := 200.0
const HIGH_DETAIL_COLLISION_DIST := 160.0

var field
var vegetation
var water
var structures

var chunks: Dictionary = {}
var player: Node3D
var terrain_material: ShaderMaterial
var world_mask_texture: ImageTexture
var far_terrain: MeshInstance3D

var generation_ms := 0
var build_report := {}
var _stream_accum := 0.0
var _chunk_root: Node3D
var _pending: Array = []
var _pending_set: Dictionary = {}
var _last_player_pos := Vector3.ZERO
var _player_velocity := Vector3.ZERO


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	_chunk_root = Node3D.new()
	_chunk_root.name = "TerrainChunks"
	add_child(_chunk_root)

	field = TerrainField.new()
	var mask_t := Time.get_ticks_msec()
	_build_terrain_material()
	var mask_ms := Time.get_ticks_msec() - mask_t

	var far_t := Time.get_ticks_msec()
	_build_far_terrain()
	var far_ms := Time.get_ticks_msec() - far_t

	var veg_t := Time.get_ticks_msec()
	vegetation = Vegetation.new()
	vegetation.setup(field)
	var veg_ms := Time.get_ticks_msec() - veg_t

	var wat_t := Time.get_ticks_msec()
	water = WaterBuilder.new()
	water.setup(field)
	water.build(self)
	var wat_ms := Time.get_ticks_msec() - wat_t

	var str_t := Time.get_ticks_msec()
	structures = Structures.new()
	structures.setup(field)
	structures.build(self)
	var str_ms := Time.get_ticks_msec() - str_t

	generation_ms = Time.get_ticks_msec() - t0
	build_report = {
		"mask_ms": mask_ms,
		"field_ms": far_ms,
		"far_terrain_ms": far_ms,
		"vegetation_prep_ms": veg_ms,
		"water_ms": wat_ms,
		"structures_ms": str_ms,
		"total_ms": generation_ms,
		"world_size": Config.WORLD_SIZE,
		"seed": Config.SEED,
	}
	print("[BTH] World built in %d ms  %s" % [generation_ms, JSON.stringify(build_report)])


func set_player(node: Node3D) -> void:
	player = node
	_last_player_pos = player.global_position
	var t0 := Time.get_ticks_msec()
	stream_around(player.global_position, true)
	_pump_queue(4)
	build_report["initial_stream_ms"] = Time.get_ticks_msec() - t0
	build_report["initial_chunks"] = chunks.size()


func get_spawn_point() -> Vector3:
	var p := Config.PLAYER_SPAWN
	var h: float = field.height(p.x, p.z)
	return Vector3(p.x, h + 1.2, p.z)


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------
func _tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null


func _build_terrain_material() -> void:
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = load("res://shaders/terrain.gdshader")
	var base := "res://assets/textures/terrain/"
	terrain_material.set_shader_parameter("tex_grass", _tex(base + "grass_diff.jpg"))
	terrain_material.set_shader_parameter("tex_forest", _tex(base + "forest_diff.jpg"))
	terrain_material.set_shader_parameter("tex_rock", _tex(base + "cliff_diff.jpg"))
	terrain_material.set_shader_parameter("tex_gravel", _tex(base + "gravel_diff.jpg"))
	terrain_material.set_shader_parameter("tex_mud",
		_tex("res://assets/materials/ambientcg/Ground037/Ground037_1K-JPG_Color.jpg"))
	terrain_material.set_shader_parameter("nrm_grass", _tex(base + "grass_nor.jpg"))
	terrain_material.set_shader_parameter("nrm_rock", _tex(base + "cliff_nor.jpg"))
	terrain_material.set_shader_parameter("nrm_gravel", _tex(base + "gravel_nor.jpg"))
	terrain_material.set_shader_parameter("arm_grass", _tex(base + "grass_arm.jpg"))
	terrain_material.set_shader_parameter("arm_rock", _tex(base + "cliff_arm.jpg"))
	terrain_material.set_shader_parameter("arm_gravel", _tex(base + "gravel_arm.jpg"))

	var mask_img: Image = field.write_world_mask()
	mask_img.generate_mipmaps()
	world_mask_texture = ImageTexture.create_from_image(mask_img)
	terrain_material.set_shader_parameter("world_mask", world_mask_texture)
	terrain_material.set_shader_parameter("mask_origin", Vector2(-Config.WORLD_HALF, -Config.WORLD_HALF))
	terrain_material.set_shader_parameter("mask_size", Config.WORLD_SIZE)


# ---------------------------------------------------------------------------
# Far terrain
# ---------------------------------------------------------------------------
func _build_far_terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := Config.WORLD_SIZE / float(FAR_SEGMENTS)
	var count := FAR_SEGMENTS + 1
	var heights := PackedFloat32Array()
	heights.resize(count * count)
	for z in count:
		for x in count:
			var wx := -Config.WORLD_HALF + float(x) * step
			var wz := -Config.WORLD_HALF + float(z) * step
			heights[z * count + x] = field.height(wx, wz) - 0.9
	for z in FAR_SEGMENTS:
		for x in FAR_SEGMENTS:
			var i00 := z * count + x
			var i10 := i00 + 1
			var i01 := i00 + count
			var i11 := i01 + 1
			var x0 := -Config.WORLD_HALF + float(x) * step
			var z0 := -Config.WORLD_HALF + float(z) * step
			var v00 := Vector3(x0, heights[i00], z0)
			var v10 := Vector3(x0 + step, heights[i10], z0)
			var v01 := Vector3(x0, heights[i01], z0 + step)
			var v11 := Vector3(x0 + step, heights[i11], z0 + step)
			var n := (v10 - v00).cross(v01 - v00).normalized()
			if n.y < 0.0:
				n = -n
			for v in [[v00, Vector2(x0, z0)], [v10, Vector2(x0 + step, z0)], [v11, Vector2(x0 + step, z0 + step)],
					[v00, Vector2(x0, z0)], [v11, Vector2(x0 + step, z0 + step)], [v01, Vector2(x0, z0 + step)]]:
				st.set_normal(n)
				st.set_uv(v[1] / 12.0)
				st.add_vertex(v[0])
	var mesh := st.commit()
	far_terrain = MeshInstance3D.new()
	far_terrain.name = "FarTerrain"
	far_terrain.mesh = mesh
	far_terrain.material_override = terrain_material
	far_terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	far_terrain.visibility_range_begin = FAR_HIDE
	far_terrain.visibility_range_begin_margin = 40.0
	far_terrain.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(far_terrain)


# ---------------------------------------------------------------------------
# Streaming
# ---------------------------------------------------------------------------
func _process(delta: float) -> void:
	if player == null:
		return
	var pos := player.global_position
	if delta > 0.0001:
		_player_velocity = (pos - _last_player_pos) / delta
	_last_player_pos = pos
	_pump_queue(CHUNK_BUDGET_PER_FRAME)
	_upgrade_near_collisions(pos)
	_stream_accum += delta
	if _stream_accum < 0.4:
		return
	_stream_accum = 0.0
	stream_around(pos)


func chunk_coord(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor((pos.x + Config.WORLD_HALF) / Config.CHUNK_SIZE)),
		int(floor((pos.z + Config.WORLD_HALF) / Config.CHUNK_SIZE)))


func stream_around(pos: Vector3, immediate := false) -> void:
	var pc := chunk_coord(pos)
	var predict_pos := pos
	if _player_velocity.length() > 1.5:
		var look := minf(_player_velocity.length() * PREDICT_SECONDS, PREDICT_MAX_DIST)
		predict_pos = pos + _player_velocity.normalized() * look
	var radius := int(ceil(Config.STREAM_RADIUS / Config.CHUNK_SIZE))
	var max_chunk := int(Config.WORLD_SIZE / Config.CHUNK_SIZE) - 1
	var wanted: Array[Vector2i] = []
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var coord := pc + Vector2i(dx, dz)
			if coord.x < 0 or coord.y < 0 or coord.x > max_chunk or coord.y > max_chunk:
				continue
			var center := Vector3(
				(float(coord.x) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF, 0.0,
				(float(coord.y) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF)
			var dist_now := center.distance_to(Vector3(pos.x, 0.0, pos.z))
			var dist_pred := center.distance_to(Vector3(predict_pos.x, 0.0, predict_pos.z))
			if dist_now > Config.STREAM_RADIUS and dist_pred > Config.STREAM_RADIUS * 0.9:
				continue
			wanted.append(coord)
			if not chunks.has(coord):
				var dist := dist_now
				if _player_velocity.length() > 1.0:
					var to_c := (center - Vector3(pos.x, 0.0, pos.z)).normalized()
					dist -= maxf(0.0, to_c.dot(_player_velocity.normalized())) * 60.0
				if immediate and dist_now < 220.0:
					_load_chunk(coord, _distance_to_chunk_xz(pos, coord) < HIGH_DETAIL_COLLISION_DIST)
				elif not _pending_set.has(coord):
					_pending.append({"coord": coord, "dist": dist})
					_pending_set[coord] = true
	for coord in chunks.keys():
		var center := Vector3(
			(float(coord.x) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF, 0.0,
			(float(coord.y) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF)
		if center.distance_to(Vector3(pos.x, 0.0, pos.z)) > Config.UNLOAD_RADIUS:
			_unload_chunk(coord)


func _pump_queue(budget: int) -> void:
	if _pending.is_empty():
		return
	_pending.sort_custom(func(a, b): return float(a["dist"]) < float(b["dist"]))
	var loaded := 0
	while loaded < budget and not _pending.is_empty():
		var entry: Dictionary = _pending.pop_front()
		var coord: Vector2i = entry["coord"]
		_pending_set.erase(coord)
		if chunks.has(coord):
			continue
		if player != null:
			var center := Vector3(
				(float(coord.x) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF, 0.0,
				(float(coord.y) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF)
			if center.distance_to(Vector3(player.global_position.x, 0.0, player.global_position.z)) > Config.UNLOAD_RADIUS:
				continue
		var high_detail := true
		if player != null:
			high_detail = _distance_to_chunk_xz(player.global_position, coord) < HIGH_DETAIL_COLLISION_DIST
		_load_chunk(coord, high_detail)
		loaded += 1


func pending_chunks() -> int:
	return _pending.size()


func _load_chunk(coord: Vector2i, high_detail_collision: bool = true) -> void:
	var chunk := TerrainChunk.new()
	chunk.setup(field, coord)
	_chunk_root.add_child(chunk)
	chunk.build(terrain_material, high_detail_collision)
	vegetation.scatter_chunk(chunk, coord)
	chunks[coord] = chunk


func _distance_to_chunk_xz(pos: Vector3, coord: Vector2i) -> float:
	var half := Config.CHUNK_SIZE * 0.5
	var center_x := (float(coord.x) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF
	var center_z := (float(coord.y) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF
	var dx := maxf(absf(pos.x - center_x) - half, 0.0)
	var dz := maxf(absf(pos.z - center_z) - half, 0.0)
	return Vector2(dx, dz).length()


func _upgrade_near_collisions(pos: Vector3) -> void:
	for coord in chunks.keys():
		var chunk = chunks[coord]
		if chunk == null or chunk.high_detail_collision:
			continue
		if _distance_to_chunk_xz(pos, coord) < HIGH_DETAIL_COLLISION_DIST:
			chunk.upgrade_collision()


func _unload_chunk(coord: Vector2i) -> void:
	_pending_set.erase(coord)
	var chunk = chunks.get(coord)
	chunks.erase(coord)
	if chunk != null:
		chunk.dispose()


func loaded_chunk_count() -> int:
	return chunks.size()


func report() -> Dictionary:
	var r := build_report.duplicate()
	r["chunks_loaded"] = chunks.size()
	r["chunks_pending"] = _pending.size()
	r["chunk_size"] = Config.CHUNK_SIZE
	r["stream_radius"] = Config.STREAM_RADIUS
	r["terrain_triangles_loaded"] = chunks.size() * Config.CHUNK_SEGMENTS * Config.CHUNK_SEGMENTS * 2
	r["vegetation"] = vegetation.stats if vegetation else {}
	r["water"] = water.stats if water else {}
	r["structures"] = structures.stats if structures else {}
	return r
