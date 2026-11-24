extends Node
## Headless runtime smoke test.
##
## Run:  godot --headless --path . res://tests/smoke_test.tscn
## Exits with code 0 when every check passes, 1 otherwise.

const Config = preload("res://scripts/core/world_config.gd")
const Assets = preload("res://scripts/core/asset_library.gd")

var failures: Array[String] = []
var checks := 0
var main
var world
var player


func _ready() -> void:
	await run_tests()


func check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("PASS  ", label)
	else:
		failures.append(label)
		print("FAIL  ", label)


func run_tests() -> void:
	print("=== BTH headless smoke test ===")
	var packed: PackedScene = load("res://scenes/main.tscn")
	check(packed != null, "main.tscn loads")
	if packed == null:
		finish()
		return
	main = packed.instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	for i in 6:
		await get_tree().physics_frame
	world = main.get("world")
	player = main.get("player")
	check(world != null, "world generator created")
	check(player != null, "player created")
	if world == null or player == null:
		finish()
		return

	# --- terrain -----------------------------------------------------------
	check(world.field != null, "terrain field built")
	var min_h := 10000.0
	var max_h := -10000.0
	var samples := 0
	for z in range(-960, 961, 64):
		for x in range(-960, 961, 64):
			var h: float = world.field.height(x, z)
			min_h = minf(min_h, h)
			max_h = maxf(max_h, h)
			samples += 1
	print("      height range %.1f .. %.1f m over %d samples" % [min_h, max_h, samples])
	check(min_h < 20.0, "valley lowlands near water level")
	check(max_h > 180.0, "mountain peaks exceed 180 m")
	check(max_h - min_h > 150.0, "terrain has real relief")

	var river_ok := true
	for pt in Config.RIVER_POINTS:
		var info: Vector3 = world.field.river_info(pt["p"].x, pt["p"].y)
		if info.x > info.z * 0.5 + 2.0:
			river_ok = false
	check(river_ok, "river channel carved along every authored point")

	# --- streaming ---------------------------------------------------------
	for i in 60:
		world._pump_queue(3)
		await get_tree().physics_frame
	# Lattice generation runs on worker threads at runtime; the test completes
	# the queue synchronously so streaming assertions are deterministic.
	world.force_stream_complete()
	var chunk_count: int = world.loaded_chunk_count()
	print("      streamed chunks: %d" % chunk_count)
	check(chunk_count >= 20, "terrain chunks streamed around the player")
	check(world.far_terrain != null, "far terrain mesh built for the skyline")

	# --- water / structures ------------------------------------------------
	var rivers := 0
	for child in world.get_children():
		if child.name == "Water":
			for c in child.get_children():
				if c is MeshInstance3D and c.name.begins_with("River"):
					rivers += 1
	print("      river meshes: %d  waterfalls: %d" % [rivers, world.water.stats["waterfalls"]])
	check(rivers >= 2, "river ribbons built")
	check(world.water.stats["waterfalls"] >= 1, "at least one waterfall built")
	check(world.water.stats["lake"], "lake water surface built")

	var s: Dictionary = world.structures.stats
	print("      structures: %s" % JSON.stringify(s))
	check(int(s["houses"]) >= 12, "village + hamlet houses built")
	check(int(s["bridges"]) >= 1, "at least one bridge crossing a river")
	check(int(s["landmarks"]) >= 5, "five or more landmark sites")
	check(int(s["props"]) >= 10, "Poly Haven hero props placed")

	# --- vegetation --------------------------------------------------------
	var veg: Dictionary = world.vegetation.stats
	print("      vegetation: %s" % JSON.stringify(veg))
	check(int(veg["trees"]) > 200, "trees scattered across loaded chunks")
	check(int(veg["grass"]) > 100, "ground cover scattered")
	check(world.vegetation.meshes["conifer_a"] != null, "procedural conifer mesh built")

	# --- collision + movement ---------------------------------------------
	var start: Vector3 = player.global_position
	print("      spawn %s" % start)
	check(start.y > world.field.height(start.x - 96, start.z), "player spawned on terrain")
	var query := PhysicsRayQueryParameters3D.create(
		start + Vector3(0, 12, 0), start - Vector3(0, 40, 0), 1)
	var hit := get_tree().root.get_world_3d().direct_space_state.intersect_ray(query)
	check(not hit.is_empty(), "terrain collision body under the player")
	if not hit.is_empty():
		print("      ground hit at y=%.2f" % (hit["position"] as Vector3).y)

	Input.action_press("move_forward")
	for i in 180:
		await get_tree().physics_frame
	Input.action_release("move_forward")
	var moved: float = Vector2(player.global_position.x - start.x,
		player.global_position.z - start.z).length()
	print("      travelled %.2f m in 3 s of simulated walking" % moved)
	check(moved > 3.0, "player walks with WASD input")
	var terrain_h: float = world.field.height(player.global_position.x, player.global_position.z)
	check(absf(player.global_position.y - terrain_h) < 5.0,
		"player stays on the terrain surface")

	# --- interaction -------------------------------------------------------
	player.global_position = Vector3(Config.VILLAGE_CENTER.x - 7.5,
		world.field.height(Config.VILLAGE_CENTER.x - 7.5, Config.VILLAGE_CENTER.y + 6.0) + 1.5,
		Config.VILLAGE_CENTER.y + 6.0)
	# Focus probing runs at 10 Hz, so allow a tenth of a second of physics.
	for i in 12:
		await get_tree().physics_frame
	print("      focus near well: '%s'" % player.current_focus)
	check(player.current_focus != "", "interaction probe finds nearby landmark")

	# --- performance regressions ------------------------------------------
	world.force_detail_update()
	var pumps_before_forced_drain := int(world.perf["pump_count"])
	world.force_stream_complete()
	check(int(world.perf["pump_count"]) == pumps_before_forced_drain,
		"forced bulk streaming drain excluded from runtime pump telemetry")
	var perf_stats: Dictionary = world.perf
	check(int(perf_stats["chunk_loads"]) > 0, "chunk loads tracked")
	var coord: Vector2i = world.chunk_coord(player.global_position)
	var hits_before := int(world.perf["lattice_cache_hits"])
	var lat_a: Dictionary = world._get_lattice(coord)
	var lat_b: Dictionary = world._get_lattice(coord)
	check(lat_a == lat_b, "chunk lattice cache returns identical data")
	check(int(world.perf["lattice_cache_hits"]) > hits_before, "lattice cache hits counted")

	var lod_ok := true
	var lods := {}
	var collision_chunks := 0
	var collision_far := 0
	for c in world.chunks.values():
		lods[c.lod] = true
		var d := Vector2(c.world_center().x - player.global_position.x,
			c.world_center().z - player.global_position.z).length()
		if d <= float(world._lod_near) and c.lod != 0:
			lod_ok = false
		if c.collision_enabled:
			collision_chunks += 1
			# Hysteresis keeps collision a little beyond the radius on purpose.
			if d > float(world._collision_radius) + 49.0:
				collision_far += 1
	check(lod_ok, "terrain LOD agrees with chunk distance")
	check(lods.has(0) and (lods.has(1) or lods.has(2)), "multiple terrain LODs active")
	check(collision_chunks > 0, "terrain collision attached near the player")
	check(collision_far == 0, "no terrain collision beyond the activation radius")
	check(int(perf_stats["shape_built"]) > 0, "collision shapes are built lazily")
	check(world.vegetation.meshes.get("conifer_a_far") != null, "far tree LOD meshes built")
	check(int(perf_stats["pump_spikes_16ms"]) == 0, "no streaming frame exceeded 16 ms")

	main.apply_quality("medium", false)
	check(is_equal_approx(float(world._stream_radius), 320.0)
		and is_equal_approx(float(world._collision_radius), 176.0),
		"medium quality profile applied to the live world")
	main.apply_quality("ultra", false)
	check(is_equal_approx(float(world._stream_radius), 448.0),
		"ultra quality profile restored")
	world.force_stream_complete()
	print("      loaded after force: %d chunks, perf %s" % [
		world.loaded_chunk_count(), JSON.stringify(world.perf)])
	check(world.loaded_chunk_count() >= 30, "streaming radius fills to 30+ chunks")

	# --- assets ------------------------------------------------------------
	var gltfs := [
		"res://assets/vegetation/polyhaven_fern_02/fern_02_1k.gltf",
		"res://assets/vegetation/polyhaven_weed_plant_02/weed_plant_02_1k.gltf",
		"res://assets/vegetation/polyhaven_nettle_plant/nettle_plant_1k.gltf",
		"res://assets/vegetation/polyhaven_wild_rooibos_bush/wild_rooibos_bush_1k.gltf",
		"res://assets/vegetation/polyhaven_dead_tree_trunk/dead_tree_trunk_1k.gltf",
		"res://assets/rocks/polyhaven_stone_01/stone_01_1k.gltf",
		"res://assets/rocks/polyhaven_coastal_cliff_01/coastal_cliff_01_1k.gltf",
		"res://assets/rocks/polyhaven_namaqualand_stones_01/namaqualand_stones_01_1k.gltf",
		"res://assets/props/polyhaven_wooden_barrels_01/wooden_barrels_01_1k.gltf",
		"res://assets/props/polyhaven_wooden_crate_01/wooden_crate_01_1k.gltf",
		"res://assets/props/polyhaven_stone_fire_pit/stone_fire_pit_1k.gltf",
		"res://assets/props/polyhaven_barrel_03/barrel_03_1k.gltf",
		"res://assets/props/polyhaven_gothic_statue/gothic_statue_1k.gltf",
	]
	var loaded_assets := 0
	for path in gltfs:
		var mesh: ArrayMesh = Assets.load_mesh(path)
		if mesh != null and mesh.get_surface_count() > 0:
			loaded_assets += 1
		else:
			print("      missing asset: ", path)
	check(loaded_assets == gltfs.size(),
		"all %d Poly Haven models import with mesh surfaces (%d ok)" % [gltfs.size(), loaded_assets])
	check(world.world_mask_texture != null, "terrain splat mask generated")

	print("=== %d checks, %d failed ===" % [checks, failures.size()])
	for f in failures:
		print("  FAILED: ", f)
	finish()


func finish() -> void:
	var code := 0 if failures.is_empty() else 1
	print("SMOKE_TEST_EXIT_%d" % code)
	get_tree().quit(code)
