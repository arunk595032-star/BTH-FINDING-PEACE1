extends Node3D
## Builds and streams the BTH open world.
##
## Performance architecture (see docs/PERFORMANCE.md):
##   * full-resolution chunk lattices are cached (LRU) so revisits never
##     re-evaluate the terrain field;
##   * chunk meshes have three distance LODs and rebuild in-place in a few ms;
##   * collision trimeshes are cached separately and only attached inside a
##     collision radius, so distant chunks cost nothing in physics;
##   * streaming uses a time budget (microseconds per frame) and a predictive
##     queue that prioritises chunks in front of the player's velocity.

const Config = preload("res://scripts/core/world_config.gd")
const TerrainField = preload("res://scripts/world/terrain_field.gd")
const TerrainChunk = preload("res://scripts/world/terrain_chunk.gd")
const Vegetation = preload("res://scripts/world/vegetation.gd")
const WaterBuilder = preload("res://scripts/world/water_builder.gd")
const Structures = preload("res://scripts/world/structures.gd")

const FAR_SEGMENTS := 192
const FAR_HIDE := 430.0
const LATTICE_CACHE_LIMIT := 140
const SHAPE_CACHE_LIMIT := 96
const INITIAL_IMMEDIATE_RADIUS := 160.0
const COLLISION_HYSTERESIS := 48.0
const DETAIL_INTERVAL := 0.35
const STREAM_INTERVAL := 0.5
## Worker-thread lattice build. Written by the thread, read by the main thread
## only after wait_for_task_completion().
class LatticeTask:
	var coord := Vector2i.ZERO
	var data: Dictionary = {}
	var task_id := -1


## One chunk height lattice demanded by streaming.
class LatticeJob:
	var coord := Vector2i.ZERO
	var heights := PackedFloat32Array()
	var normals := PackedVector3Array()
	var hrow := 0
	var nrow := 0
	var dist := 0.0

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
var perf := {
	"chunk_loads": 0,
	"lattice_generated": 0,
	"lattice_cache_hits": 0,
	"shape_built": 0,
	"shape_cache_hits": 0,
	"lod_swaps": 0,
	"collision_enabled": 0,
	"collision_disabled": 0,
	"pump_count": 0,
	"pump_max_ms": 0.0,
	"pump_spikes_16ms": 0,
	"chunk_build_ms": 0.0,
	"chunk_build_count": 0,
	"ms_lattice": 0.0,
	"ms_mesh": 0.0,
	"ms_vegetation": 0.0,
	"ms_collision": 0.0,
	"lattice_jobs": 0,
}

var _stream_accum := 0.0
var _detail_accum := 0.0
var _chunk_root: Node3D
var _pending: Array = []
var _pending_set: Dictionary = {}
var _pending_dirty := false
var _last_player_pos := Vector3.ZERO
var _forward := Vector3.ZERO

var _stream_radius := Config.STREAM_RADIUS
var _unload_radius := Config.UNLOAD_RADIUS
var _collision_radius := 232.0
var _lod_near := 208.0
var _lod_mid := 352.0
var _budget_us := 4000
var _chunk_budget := 3
var _record_pump_metrics := true

var _lattice_cache: Dictionary = {}
var _lattice_order: Array[Vector2i] = []
var _jobs: Array = []
var _job_set: Dictionary = {}
var _tasks: Array = []
var _thread_count := 3
var _shape_cache: Dictionary = {}
var _shape_order: Array[Vector2i] = []


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
		"structures_detail": structures.build_timings.duplicate(true),
		"structures_counts": structures.stats.duplicate(true),
		"total_ms": generation_ms,
		"world_size": Config.WORLD_SIZE,
		"seed": Config.SEED,
	}
	print("[BTH] World built in %d ms  %s" % [generation_ms, JSON.stringify(build_report)])


func set_player(node: Node3D) -> void:
	player = node
	_last_player_pos = node.global_position
	var t0 := Time.get_ticks_msec()
	stream_around(player.global_position, true)
	_pump_queue(_chunk_budget)
	# Spawn safety: attach collision to the few chunks around the player now;
	# the rest of the streaming radius gets physics on the detail tick.
	for coord in chunks.keys():
		var chunk = chunks[coord]
		var c: Vector3 = chunk.world_center()
		if Vector2(c.x - node.global_position.x, c.z - node.global_position.z).length() <= 100.0:
			chunk.enable_collision(_shape_for(coord))
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
# Far terrain (shared-vertex lattice, no SurfaceTool)
# ---------------------------------------------------------------------------
func _build_far_terrain() -> void:
	var count := FAR_SEGMENTS + 1
	var step := Config.WORLD_SIZE / float(FAR_SEGMENTS)
	var heights := PackedFloat32Array()
	heights.resize(count * count)
	for z in count:
		var wz := -Config.WORLD_HALF + float(z) * step
		var base := z * count
		for x in count:
			heights[base + x] = field.height(-Config.WORLD_HALF + float(x) * step, wz) - 0.9

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	verts.resize(count * count)
	norms.resize(count * count)
	uvs.resize(count * count)
	tangents.resize(count * count * 4)
	for z in count:
		var wz := -Config.WORLD_HALF + float(z) * step
		var base := z * count
		var zd := maxi(z - 1, 0) * count
		var zu := mini(z + 1, FAR_SEGMENTS) * count
		for x in count:
			var wx := -Config.WORLD_HALF + float(x) * step
			var i := base + x
			verts[i] = Vector3(wx, heights[i], wz)
			var hl := heights[base + maxi(x - 1, 0)]
			var hr := heights[base + mini(x + 1, FAR_SEGMENTS)]
			var hd := heights[zd + x]
			var hu := heights[zu + x]
			norms[i] = Vector3(hl - hr, 2.0 * step, hd - hu).normalized()
			uvs[i] = Vector2(wx / 12.0, wz / 12.0)
			var tx := Vector3(2.0 * step, hr - hl, 0.0).normalized()
			tangents[i * 4] = tx.x
			tangents[i * 4 + 1] = tx.y
			tangents[i * 4 + 2] = tx.z
			tangents[i * 4 + 3] = 1.0

	var indices := PackedInt32Array()
	indices.resize(FAR_SEGMENTS * FAR_SEGMENTS * 6)
	var w := 0
	for z in FAR_SEGMENTS:
		var row := z * count
		var nrow := row + count
		for x in FAR_SEGMENTS:
			var i00 := row + x
			var i10 := i00 + 1
			var i01 := nrow + x
			var i11 := i01 + 1
			indices[w] = i00
			indices[w + 1] = i10
			indices[w + 2] = i11
			indices[w + 3] = i00
			indices[w + 4] = i11
			indices[w + 5] = i01
			w += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

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
	_pump_lattice()
	_pump_queue(_chunk_budget)

	_stream_accum += delta
	if _stream_accum >= STREAM_INTERVAL:
		_stream_accum = 0.0
		stream_around(player.global_position)

	_detail_accum += delta
	if _detail_accum >= DETAIL_INTERVAL:
		_detail_accum = 0.0
		_update_chunk_detail()


func chunk_coord(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor((pos.x + Config.WORLD_HALF) / Config.CHUNK_SIZE)),
		int(floor((pos.z + Config.WORLD_HALF) / Config.CHUNK_SIZE)))


func _forward_dir() -> Vector3:
	if player != null:
		if player is CharacterBody3D:
			var v: Vector3 = (player as CharacterBody3D).velocity
			var flat := Vector3(v.x, 0.0, v.z)
			if flat.length() > 1.0:
				return flat.normalized()
		var moved := player.global_position - _last_player_pos
		moved.y = 0.0
		if moved.length() > 0.05:
			return moved.normalized()
	return _forward


func stream_around(pos: Vector3, immediate := false) -> void:
	if player != null:
		_last_player_pos = player.global_position
	_forward = _forward_dir()
	var pc := chunk_coord(pos)
	var radius := int(ceil(_stream_radius / Config.CHUNK_SIZE))
	var max_chunk := int(Config.WORLD_SIZE / Config.CHUNK_SIZE) - 1
	var p2 := Vector2(pos.x, pos.z)
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var coord := pc + Vector2i(dx, dz)
			if coord.x < 0 or coord.y < 0 or coord.x > max_chunk or coord.y > max_chunk:
				continue
			var center := Vector2(
				(float(coord.x) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF,
				(float(coord.y) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF)
			var offset := center - p2
			var dist := offset.length()
			if dist > _stream_radius:
				continue
			if chunks.has(coord) or _pending_set.has(coord):
				continue
			if immediate and dist < INITIAL_IMMEDIATE_RADIUS:
				_get_lattice(coord)
				_load_chunk(coord)
			else:
				var ahead := 0.0
				if _forward.length_squared() > 0.0 and dist > 0.001:
					ahead = maxf(offset.normalized().dot(Vector2(_forward.x, _forward.z)), 0.0)
				_pending.append({
					"coord": coord,
					"dist": dist,
					"score": dist - ahead * 140.0,
				})
				_pending_set[coord] = true
				_pending_dirty = true

	# Unload far chunks in reverse distance order (farthest first).
	var to_unload: Array[Vector2i] = []
	for coord in chunks.keys():
		var center := Vector2(
			(float(coord.x) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF,
			(float(coord.y) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF)
		if center.distance_to(p2) > _unload_radius:
			to_unload.append(coord)
	for coord in to_unload:
		_unload_chunk(coord)


func _pump_queue(budget: int = 0) -> void:
	if _pending.is_empty():
		return
	if budget <= 0:
		budget = _chunk_budget
	if _pending_dirty:
		_pending.sort_custom(func(a, b): return float(a["score"]) < float(b["score"]))
		_pending_dirty = false
	var t0 := Time.get_ticks_usec()
	var loaded := 0
	while loaded < budget and not _pending.is_empty():
		# A frame may start one chunk even if it is expensive, then stop.
		if loaded > 0 and Time.get_ticks_usec() - t0 >= _budget_us:
			break
		var entry: Dictionary = _pending.pop_front()
		var coord: Vector2i = entry["coord"]
		_pending_set.erase(coord)
		if chunks.has(coord):
			continue
		if player != null:
			var center := Vector2(
				(float(coord.x) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF,
				(float(coord.y) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF)
			if center.distance_to(Vector2(player.global_position.x, player.global_position.z)) > _unload_radius:
				continue
		_load_chunk(coord)
		loaded += 1

	if _record_pump_metrics:
		var spent_ms := float(Time.get_ticks_usec() - t0) / 1000.0
		perf["pump_count"] += 1
		perf["pump_max_ms"] = maxf(float(perf["pump_max_ms"]), spent_ms)
		if spent_ms > 16.0:
			perf["pump_spikes_16ms"] += 1


func pending_chunks() -> int:
	return _pending.size() + _jobs.size() + _tasks.size()


# ---------------------------------------------------------------------------
# Chunk lifetime
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Incremental lattice generation
# ---------------------------------------------------------------------------
func _request_lattice(coord: Vector2i) -> bool:
	if _lattice_cache.has(coord) or _job_set.has(coord):
		return false
	var job := LatticeJob.new()
	job.coord = coord
	if player != null:
		job.dist = Vector2(
			(float(coord.x) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF - player.global_position.x,
			(float(coord.y) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF - player.global_position.z).length()
	_jobs.append(job)
	_job_set[coord] = true
	_jobs.sort_custom(func(a, b): return float(a.dist) < float(b.dist))
	perf["lattice_jobs"] = int(perf["lattice_jobs"]) + 1
	_start_lattice_tasks()
	return true


## Terrain height sampling dominates chunk cost, so lattices are built on
## worker threads (the field is immutable after construction).  The main thread
## only instantiates finished chunks, inside the streaming time budget.
func _start_lattice_tasks() -> void:
	while _tasks.size() < _thread_count and not _jobs.is_empty():
		var job: LatticeJob = _jobs.pop_front()
		var task := LatticeTask.new()
		task.coord = job.coord
		task.task_id = WorkerThreadPool.add_task(
			_lattice_task.bind(task), false, "BTH lattice")
		_tasks.append(task)


func _lattice_task(task: LatticeTask) -> void:
	task.data = TerrainChunk.make_lattice(field, task.coord)


func _pump_lattice(_budget_us := 3200) -> void:
	var completed: Array = []
	for task in _tasks:
		if WorkerThreadPool.is_task_completed(task.task_id):
			WorkerThreadPool.wait_for_task_completion(task.task_id)
			completed.append(task)
	for task in completed:
		_tasks.erase(task)
		var coord: Vector2i = task.coord
		_job_set.erase(coord)
		if task.data.is_empty():
			continue
		_lattice_cache[coord] = task.data
		_lattice_order.append(coord)
		while _lattice_order.size() > LATTICE_CACHE_LIMIT:
			var old: Vector2i = _lattice_order.pop_front()
			_lattice_cache.erase(old)
		perf["lattice_generated"] = int(perf["lattice_generated"]) + 1
		_enqueue_ready(coord)
	_start_lattice_tasks()


func _enqueue_ready(coord: Vector2i) -> void:
	if player == null:
		return
	var center := Vector2(
		(float(coord.x) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF,
		(float(coord.y) + 0.5) * Config.CHUNK_SIZE - Config.WORLD_HALF)
	var p2 := Vector2(player.global_position.x, player.global_position.z)
	var offset := center - p2
	var dist := offset.length()
	if dist > _unload_radius:
		return
	if chunks.has(coord) or _pending_set.has(coord):
		return
	var ahead := 0.0
	if _forward.length_squared() > 0.0 and dist > 0.001:
		ahead = maxf(offset.normalized().dot(Vector2(_forward.x, _forward.z)), 0.0)
	_pending.append({"coord": coord, "dist": dist, "score": dist - ahead * 140.0})
	_pending_set[coord] = true
	_pending_dirty = true


## Test/benchmark helper: completes all queued lattice work and instantiates
## every wanted chunk immediately, bypassing the per-frame slicing.
func force_stream_complete() -> void:
	# This test/helper path deliberately bypasses the per-frame chunk budget.
	# Keep its drain time out of runtime pump telemetry so benchmarks report
	# actual frame-sliced streaming work rather than an intentional bulk drain.
	var previous_recording := _record_pump_metrics
	_record_pump_metrics = false
	var guard := 0
	while guard < 40000:
		guard += 1
		_pump_lattice(100000000)
		_pump_queue(64)
		if _jobs.is_empty() and _tasks.is_empty() and _pending.is_empty():
			break
		OS.delay_usec(500)
	_record_pump_metrics = previous_recording


func _lod_index_for(distance: float) -> int:
	if distance <= _lod_near:
		return 0
	if distance <= _lod_mid:
		return 1
	return 2


func _get_lattice(coord: Vector2i) -> Dictionary:
	var cached = _lattice_cache.get(coord)
	if cached != null:
		perf["lattice_cache_hits"] += 1
		return cached
	var data := TerrainChunk.make_lattice(field, coord)
	perf["lattice_generated"] += 1
	_lattice_cache[coord] = data
	_lattice_order.append(coord)
	while _lattice_order.size() > LATTICE_CACHE_LIMIT:
		var old: Vector2i = _lattice_order.pop_front()
		_lattice_cache.erase(old)
	return data


func _shape_for(coord: Vector2i) -> ConcavePolygonShape3D:
	var cached = _shape_cache.get(coord)
	if cached != null:
		perf["shape_cache_hits"] += 1
		return cached
	var data := _get_lattice(coord)
	var shape := TerrainChunk.make_collision_shape_for(data["heights"], coord)
	perf["shape_built"] += 1
	_shape_cache[coord] = shape
	_shape_order.append(coord)
	while _shape_order.size() > SHAPE_CACHE_LIMIT:
		var old: Vector2i = _shape_order.pop_front()
		_shape_cache.erase(old)
	return shape


func _load_chunk(coord: Vector2i) -> void:
	var lattice = _lattice_cache.get(coord)
	if lattice == null:
		# Height sampling is the most expensive part of a chunk (the terrain is
		# an analytic field, not a bitmap), so it is generated incrementally in
		# _pump_lattice and the chunk is instantiated when it is ready.
		_request_lattice(coord)
		return
	var t0 := Time.get_ticks_usec()
	var t_mesh := Time.get_ticks_usec()
	var chunk := TerrainChunk.new()
	chunk.setup(field, coord, lattice)
	_chunk_root.add_child(chunk)
	var p := player.global_position if player != null else Vector3.ZERO
	var dist := Vector2(
		chunk.world_center().x - p.x, chunk.world_center().z - p.z).length()
	chunk.build(terrain_material, _lod_index_for(dist))
	var t_veg := Time.get_ticks_usec()
	vegetation.scatter_chunk(chunk, coord)
	vegetation.apply_lod(chunk, dist)
	var t_end := Time.get_ticks_usec()
	# Physics is attached by the detail tick (or synchronously at spawn), never
	# inside the streaming pump: a full-resolution shape build is ~5 ms and
	# would turn a chunk instantiation into a frame spike.
	chunks[coord] = chunk
	perf["chunk_loads"] += 1
	perf["ms_lattice"] = float(perf["ms_lattice"]) + float(t_mesh - t0) / 1000.0
	perf["ms_mesh"] = float(perf["ms_mesh"]) + float(t_veg - t_mesh) / 1000.0
	perf["ms_vegetation"] = float(perf["ms_vegetation"]) + float(t_end - t_veg) / 1000.0
	var spent := float(t_end - t0) / 1000.0
	perf["chunk_build_ms"] = float(perf["chunk_build_ms"]) + spent
	perf["chunk_build_count"] += 1


func _unload_chunk(coord: Vector2i) -> void:
	_pending_set.erase(coord)
	var chunk = chunks.get(coord)
	chunks.erase(coord)
	if chunk != null:
		chunk.dispose()


## Distance LOD + physics activation, staggered a couple of chunks per tick.
func _update_chunk_detail() -> void:
	if player == null:
		return
	var p := player.global_position
	var p2 := Vector2(p.x, p.z)
	var lod_budget := 2
	# Physics activation: one chunk per tick, nearest first, so shape building
	# never lands inside a streaming frame.
	var need_collision: Array = []
	for coord in chunks.keys():
		var chunk = chunks[coord]
		var center: Vector3 = chunk.world_center()
		var dist := Vector2(center.x - p2.x, center.z - p2.y).length()
		var want_lod := _lod_index_for(dist)
		if want_lod != chunk.lod and lod_budget > 0:
			chunk.build(terrain_material, want_lod)
			vegetation.apply_lod(chunk, dist)
			lod_budget -= 1
			perf["lod_swaps"] += 1
		if dist <= _collision_radius:
			if not chunk.collision_enabled:
				need_collision.append({"coord": coord, "dist": dist, "chunk": chunk})
		elif dist > _collision_radius + COLLISION_HYSTERESIS and chunk.collision_enabled:
			chunk.disable_collision()
			perf["collision_disabled"] += 1
	if not need_collision.is_empty():
		need_collision.sort_custom(func(a, b): return float(a["dist"]) < float(b["dist"]))
		var entry: Dictionary = need_collision[0]
		var t0 := Time.get_ticks_usec()
		(entry["chunk"] as Node).enable_collision(_shape_for(entry["coord"] as Vector2i))
		perf["ms_collision"] = float(perf["ms_collision"]) + float(Time.get_ticks_usec() - t0) / 1000.0
		perf["collision_enabled"] += 1


## Test helper: runs LOD/physics detail updates until the loaded set is stable.
func force_detail_update() -> void:
	var guard := 0
	while guard < 400:
		guard += 1
		var swaps := int(perf["lod_swaps"])
		var coll := int(perf["collision_enabled"])
		_update_chunk_detail()
		if swaps == int(perf["lod_swaps"]) and coll == int(perf["collision_enabled"]):
			break


func loaded_chunk_count() -> int:
	return chunks.size()


func apply_quality(profile: Dictionary) -> void:
	_stream_radius = float(profile.get("stream_radius", Config.STREAM_RADIUS))
	_unload_radius = _stream_radius + 128.0
	_budget_us = int(profile.get("stream_budget_us", 4000))
	_chunk_budget = int(profile.get("chunk_budget", 3))
	_collision_radius = float(profile.get("collision_radius", 232.0))
	_lod_near = float(profile.get("terrain_lod_near", 208.0))
	_lod_mid = float(profile.get("terrain_lod_mid", 352.0))
	if vegetation != null:
		vegetation.set_quality(profile)
	if terrain_material != null:
		terrain_material.set_shader_parameter("detail_distance",
			float(profile.get("terrain_detail_distance", 110.0)))


func report() -> Dictionary:
	var r := build_report.duplicate()
	r["chunks_loaded"] = chunks.size()
	r["chunks_pending"] = _pending.size()
	r["chunk_size"] = Config.CHUNK_SIZE
	r["stream_radius"] = _stream_radius
	r["collision_radius"] = _collision_radius
	r["chunks_with_collision"] = _count_collision_chunks()
	r["terrain_triangles_loaded"] = _terrain_triangles()
	r["perf"] = perf.duplicate()
	r["vegetation"] = vegetation.stats if vegetation else {}
	r["water"] = water.stats if water else {}
	r["structures"] = structures.stats if structures else {}
	return r


func _count_collision_chunks() -> int:
	var n := 0
	for c in chunks.values():
		if c.collision_enabled:
			n += 1
	return n


func _terrain_triangles() -> int:
	var n := 0
	for c in chunks.values():
		n += int(c.triangles)
	return n
