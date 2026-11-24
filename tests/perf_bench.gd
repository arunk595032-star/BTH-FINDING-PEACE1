extends Node
## Headless performance benchmark for BTH.
##
## Run:
##   godot --headless --path . res://tests/perf_bench.tscn -- --label=baseline
##
## Capability-aware: it also runs against the pre-optimisation baseline commit
## (which has no lattice cache / threaded streaming) so the before/after numbers
## come from one harness.  Measures:
##   * world build phases (ms)
##   * terrain mesh build, vegetation scatter, fresh chunk load, revisit cost
##   * per-simulated-frame streaming cost across a world tour (spikes)
##   * idle frame CPU time (headless dummy renderer)
##   * nodes / mesh instances / surfaces / materials / MultiMesh instances
##   * static memory + engine monitors
##
## GPU frame time, draw calls and VRAM cannot be measured on the dummy
## renderer; those fields are recorded as -1 / 0 and labelled as such.

const Config = preload("res://scripts/core/world_config.gd")

var results := {}
var main
var world
var player
var _has_lattice_cache := false
var _has_force := false
var _has_pump_lattice := false


func _ready() -> void:
	var guard := Timer.new()
	guard.wait_time = 240.0
	guard.one_shot = true
	guard.timeout.connect(func() -> void:
		print("PERF_BENCH_TIMEOUT")
		get_tree().quit(2))
	add_child(guard)
	guard.start()
	await _run()


func _label() -> String:
	var label := "run"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--label="):
			label = arg.substr(8)
	return label


func _run() -> void:
	print("=== BTH performance benchmark ===")
	results["label"] = _label()
	results["timestamp_unix"] = int(Time.get_unix_time_from_system())
	results["engine"] = Engine.get_version_info()
	results["os"] = OS.get_name()
	results["cpu"] = OS.get_processor_name()
	results["cpu_count"] = OS.get_processor_count()
	results["headless"] = DisplayServer.get_name() == "headless"
	results["renderer"] = RenderingServer.get_current_rendering_driver_name()
	results["renderer_method"] = RenderingServer.get_current_rendering_method()
	results["video_adapter"] = RenderingServer.get_video_adapter_name()

	var t_load := Time.get_ticks_usec()
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	for i in 10:
		await get_tree().physics_frame
	world = main.get("world")
	player = main.get("player")
	results["scene_load_ms"] = _ms(t_load)
	results["world_build"] = world.build_report.duplicate()
	results["quality"] = main.get("quality_name") if main.get("quality_name") != null else "n/a"
	_has_lattice_cache = world.has_method("_get_lattice")
	_has_force = world.has_method("force_stream_complete")
	_has_pump_lattice = world.has_method("_pump_lattice")
	results["capabilities"] = {
		"lattice_cache": _has_lattice_cache,
		"async_streaming": _has_force,
	}
	results["memory_static_mb"] = _mb(Performance.get_monitor(Performance.MEMORY_STATIC))
	results["memory_static_peak_mb"] = _mb(Performance.get_monitor(Performance.MEMORY_STATIC_MAX))

	# Let real streaming run for 90 frames (1.5 s of game time).
	for i in 90:
		await get_tree().process_frame
	results["chunks_after_settle"] = world.loaded_chunk_count()
	results["pending_after_settle"] = world.pending_chunks()
	if _has_force:
		world.force_stream_complete()
	results["chunks_after_force"] = world.loaded_chunk_count()
	results["pending_after_force"] = world.pending_chunks()

	results["inventory"] = _inventory()
	results["chunk_timing"] = await _chunk_timing()
	results["streaming"] = await _streaming_stress()
	results["idle_frame"] = await _idle_frame_time()
	results["inventory_after"] = _inventory()
	results["memory_static_after_mb"] = _mb(Performance.get_monitor(Performance.MEMORY_STATIC))
	results["monitor_draw_calls"] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	results["monitor_objects"] = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	results["monitor_vram_mb"] = _mb(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	results["world_perf"] = world.perf if world.get("perf") != null else {}

	_write_json()
	_print_summary()
	print("PERF_BENCH_DONE")
	get_tree().quit(0)


func _ms(usec: int) -> float:
	return float(usec) / 1000.0


func _mb(bytes: float) -> float:
	if bytes < 0.0:
		return -1.0
	return bytes / 1048576.0


# ---------------------------------------------------------------------------
# Scene inventory (draw-call pressure proxy)
# ---------------------------------------------------------------------------
func _inventory() -> Dictionary:
	var inv := {
		"nodes": 0, "mesh_instances": 0, "multimesh_instances": 0,
		"collision_shapes": 0, "static_bodies": 0, "particles": 0,
		"mesh_surfaces": 0, "multimesh_surfaces": 0,
		"multimesh_instances_total": 0, "lights": 0, "materials": 0,
		"terrain_triangles": 0, "chunk_collision_shapes": 0,
		"vegetation_nodes": 0, "shadow_casters": 0,
	}
	var materials := {}
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		inv["nodes"] += 1
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			inv["mesh_instances"] += 1
			var mi := n as MeshInstance3D
			if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				inv["shadow_casters"] += 1
			if mi.mesh != null:
				inv["mesh_surfaces"] += mi.mesh.get_surface_count()
				for s in mi.mesh.get_surface_count():
					var mat := mi.mesh.surface_get_material(s)
					if mat != null:
						materials[mat.get_instance_id()] = true
		elif n is MultiMeshInstance3D:
			inv["multimesh_instances"] += 1
			var mmi := n as MultiMeshInstance3D
			if mmi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				inv["shadow_casters"] += 1
			if n.get_parent() != null and String(n.get_parent().name).begins_with("Chunk_"):
				inv["vegetation_nodes"] += 1
			if mmi.multimesh != null:
				inv["multimesh_instances_total"] += mmi.multimesh.instance_count
				if mmi.multimesh.mesh != null:
					inv["multimesh_surfaces"] += mmi.multimesh.mesh.get_surface_count()
		elif n is CollisionShape3D:
			inv["collision_shapes"] += 1
			if n.get_parent() is StaticBody3D and String(n.get_parent().name) == "TerrainCollision":
				inv["chunk_collision_shapes"] += 1
		elif n is StaticBody3D:
			inv["static_bodies"] += 1
		elif n is CPUParticles3D or n is GPUParticles3D:
			inv["particles"] += 1
		elif n is Light3D:
			inv["lights"] += 1
	inv["materials"] = materials.size()
	inv["surface_draw_proxy"] = inv["mesh_surfaces"] + inv["multimesh_surfaces"]
	if world != null:
		inv["chunks_loaded"] = world.loaded_chunk_count()
		var tris := 0
		for c in world.chunks.values():
			tris += int(c.triangles)
		inv["terrain_triangles"] = tris
	return inv


# ---------------------------------------------------------------------------
# Chunk generation cost
# ---------------------------------------------------------------------------
func _chunk_timing() -> Dictionary:
	world.set_process(false)
	player.set_physics_process(false)
	var coords := [Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 3), Vector2i(5, 4), Vector2i(6, 3)]
	var lattice_ms: Array[float] = []
	var terrain_ms: Array[float] = []
	var veg_ms: Array[float] = []
	var instantiate_ms: Array[float] = []
	var revisit_ms: Array[float] = []

	# Cold: generate a lattice (worker path forced synchronously on baseline) and
	# build the renderable mesh.  Baseline has no lattice cache, so build()
	# includes height sampling there and its number covers both columns.
	for coord in coords:
		if world.chunks.has(coord):
			world._unload_chunk(coord)
		var t0 := Time.get_ticks_usec()
		var chunk = null
		if _has_lattice_cache:
			var lattice: Dictionary = world._get_lattice(coord)
			lattice_ms.append(_ms(Time.get_ticks_usec() - t0))
			var TerrainChunk = load("res://scripts/world/terrain_chunk.gd")
			chunk = TerrainChunk.new()
			chunk.setup(world.field, coord, lattice)
		else:
			var TerrainChunkB = load("res://scripts/world/terrain_chunk.gd")
			chunk = TerrainChunkB.new()
			chunk.setup(world.field, coord)
		world._chunk_root.add_child(chunk)
		var t1 := Time.get_ticks_usec()
		chunk.build(world.terrain_material)
		terrain_ms.append(_ms(Time.get_ticks_usec() - t1))
		var t2 := Time.get_ticks_usec()
		world.vegetation.scatter_chunk(chunk, coord)
		veg_ms.append(_ms(Time.get_ticks_usec() - t2))
		chunk.dispose()
		await get_tree().process_frame

	# Full streaming load through the world.
	for coord in coords:
		if world.chunks.has(coord):
			world._unload_chunk(coord)
		var t0 := Time.get_ticks_usec()
		world._load_chunk(coord)
		instantiate_ms.append(_ms(Time.get_ticks_usec() - t0))
		await get_tree().process_frame
	# Unload + reload the same chunks: cache hits in the optimised build.
	for coord in coords:
		world._unload_chunk(coord)
		await get_tree().process_frame
	for coord in coords:
		var t0 := Time.get_ticks_usec()
		world._load_chunk(coord)
		revisit_ms.append(_ms(Time.get_ticks_usec() - t0))
		await get_tree().process_frame

	return {
		"lattice_avg_ms": _avg(lattice_ms),
		"lattice_values_ms": lattice_ms,
		"terrain_build_avg_ms": _avg(terrain_ms),
		"terrain_build_max_ms": _max(terrain_ms),
		"terrain_build_values_ms": terrain_ms,
		"vegetation_avg_ms": _avg(veg_ms),
		"vegetation_max_ms": _max(veg_ms),
		"vegetation_values_ms": veg_ms,
		"full_chunk_avg_ms": _avg(instantiate_ms),
		"full_chunk_values_ms": instantiate_ms,
		"revisit_avg_ms": _avg(revisit_ms),
		"revisit_values_ms": revisit_ms,
		"note": "lattice only exists in the optimised build; baseline build() includes height sampling",
	}


# ---------------------------------------------------------------------------
# Streaming stress: teleport along a route, time every simulated frame
# ---------------------------------------------------------------------------
func _streaming_stress() -> Dictionary:
	world.set_process(false)
	player.set_physics_process(false)
	if _has_force:
		world.force_stream_complete()
	var route := [
		Vector3(-196, 0, 300), Vector3(-100, 0, 200), Vector3(0, 0, 60),
		Vector3(200, 0, -80), Vector3(438, 0, -132), Vector3(536, 0, 292),
		Vector3(300, 0, 600), Vector3(-100, 0, 700), Vector3(-400, 0, 400),
		Vector3(-196, 0, 300),
	]
	var pump_ms: Array[float] = []
	var spikes_16 := 0
	var spikes_33 := 0
	var chunks_loaded_total := 0
	var t_all := Time.get_ticks_usec()
	for p in route:
		var pos: Vector3 = p
		pos.y = world.field.height(pos.x, pos.z) + 1.5
		player.global_position = pos
		world.stream_around(pos)
		for k in 3:
			var t0 := Time.get_ticks_usec()
			if _has_pump_lattice:
				world._pump_lattice()
			world._pump_queue(3)
			var ms := _ms(Time.get_ticks_usec() - t0)
			pump_ms.append(ms)
			if ms > 16.0:
				spikes_16 += 1
			if ms > 33.0:
				spikes_33 += 1
			await get_tree().process_frame
		chunks_loaded_total += world.loaded_chunk_count()
	var after: int = world.loaded_chunk_count()
	if _has_force:
		world.force_stream_complete()
	return {
		"route_steps": route.size(),
		"frames": pump_ms.size(),
		"total_ms": _ms(Time.get_ticks_usec() - t_all),
		"frame_avg_ms": _avg(pump_ms),
		"frame_p95_ms": _percentile(pump_ms, 0.95),
		"frame_max_ms": _max(pump_ms),
		"spikes_over_16ms": spikes_16,
		"spikes_over_33ms": spikes_33,
		"chunks_after_route": after,
		"chunks_after_force": world.loaded_chunk_count(),
		"avg_chunks_loaded": float(chunks_loaded_total) / float(route.size()),
	}


# ---------------------------------------------------------------------------
# Idle frame CPU time (headless: no GPU work is included)
# ---------------------------------------------------------------------------
func _idle_frame_time() -> Dictionary:
	world.set_process(true)
	player.set_physics_process(true)
	player.global_position = Vector3(-520, 0, 140)
	player.global_position.y = world.field.height(-520, 140) + 1.5
	for i in 60:
		await get_tree().process_frame
	var frames: Array[float] = []
	var prev := Time.get_ticks_usec()
	for i in 150:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frames.append(_ms(now - prev))
		prev = now
	return {
		"frames": frames.size(),
		"avg_ms": _avg(frames),
		"p50_ms": _percentile(frames, 0.5),
		"p95_ms": _percentile(frames, 0.95),
		"max_ms": _max(frames),
		"pending_after": world.pending_chunks(),
		"note": "headless dummy renderer: CPU-side scene/script cost only",
	}


func _avg(values: Array) -> float:
	if values.is_empty():
		return -1.0
	var total := 0.0
	for v in values:
		total += float(v)
	return total / float(values.size())


func _max(values: Array) -> float:
	var m := -1.0
	for v in values:
		m = maxf(m, float(v))
	return m


func _percentile(values: Array, p: float) -> float:
	if values.is_empty():
		return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	var idx := clampi(int(round(p * float(sorted.size() - 1))), 0, sorted.size() - 1)
	return float(sorted[idx])


func _write_json() -> void:
	var path := "res://docs/perf_%s.json" % _label()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("      could not write ", path, " err=", FileAccess.get_open_error())
		return
	f.store_string(JSON.stringify(results, "  ", true))
	f.close()
	print("      wrote ", ProjectSettings.globalize_path(path))


func _print_summary() -> void:
	print("--- summary (%s) ---" % results["label"])
	print("  build total           %.1f ms" % float(results["world_build"].get("total_ms", 0)))
	print("  chunks after 90f/force %s / %s" % [
		results["chunks_after_settle"], results["chunks_after_force"]])
	print("  lattice avg           %.2f ms" % results["chunk_timing"]["lattice_avg_ms"])
	print("  terrain mesh avg/max  %.2f / %.2f ms" % [
		results["chunk_timing"]["terrain_build_avg_ms"], results["chunk_timing"]["terrain_build_max_ms"]])
	print("  vegetation avg/max    %.2f / %.2f ms" % [
		results["chunk_timing"]["vegetation_avg_ms"], results["chunk_timing"]["vegetation_max_ms"]])
	print("  full chunk avg        %.2f ms" % results["chunk_timing"]["full_chunk_avg_ms"])
	print("  revisit avg           %.2f ms" % results["chunk_timing"]["revisit_avg_ms"])
	print("  streaming frame max   %.2f ms  p95 %.2f ms  spikes>16ms %d" % [
		results["streaming"]["frame_max_ms"], results["streaming"]["frame_p95_ms"],
		results["streaming"]["spikes_over_16ms"]])
	print("  idle frame avg/p95    %.2f / %.2f ms" % [
		results["idle_frame"]["avg_ms"], results["idle_frame"]["p95_ms"]])
	print("  mesh %d  multimesh %d  surfaces %d  shadow casters %d" % [
		results["inventory"]["mesh_instances"], results["inventory"]["multimesh_instances"],
		results["inventory"]["surface_draw_proxy"], results["inventory"]["shadow_casters"]])
	print("  memory static %.1f MB" % results["memory_static_after_mb"])
