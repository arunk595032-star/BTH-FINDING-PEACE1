extends SceneTree
## Renders the actual generated world data to a shaded relief map.
##
## This is a data visualisation of the same TerrainField the game uses - it is
## not an in-engine screenshot.  It is the honest way to show the whole map
## layout without a GPU.
##
## Run: godot --headless --path . --script res://tools/export_world_map.gd

const Config = preload("res://scripts/core/world_config.gd")
const TerrainField = preload("res://scripts/world/terrain_field.gd")

const RES := 900


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	var field = TerrainField.new()
	var res := RES
	var step := Config.WORLD_SIZE / float(res - 1)

	var heights := PackedFloat32Array()
	heights.resize(res * res)
	var h_min := 1e9
	var h_max := -1e9
	for y in res:
		for x in res:
			var wx := -Config.WORLD_HALF + float(x) * step
			var wz := -Config.WORLD_HALF + float(y) * step
			var h: float = field.height(wx, wz)
			heights[y * res + x] = h
			h_min = minf(h_min, h)
			h_max = maxf(h_max, h)

	var img := Image.create(res, res, false, Image.FORMAT_RGB8)
	var sun := Vector3(-0.55, 0.72, -0.42).normalized()
	var river_len := 0.0
	for y in res:
		for x in res:
			var i := y * res + x
			var h := heights[i]
			var wx := -Config.WORLD_HALF + float(x) * step
			var wz := -Config.WORLD_HALF + float(y) * step

			var hl := heights[y * res + maxi(x - 1, 0)]
			var hr := heights[y * res + mini(x + 1, res - 1)]
			var hu := heights[maxi(y - 1, 0) * res + x]
			var hd := heights[mini(y + 1, res - 1) * res + x]
			var n := Vector3(hl - hr, 2.0 * step, hu - hd).normalized()
			var shade := clampf(n.dot(sun) * 0.9 + 0.35, 0.0, 1.35)

			# Height driven palette: valley grass, forest green, rock, snow.
			var t := clampf((h - 4.0) / 250.0, 0.0, 1.0)
			var col := Color(0.36, 0.45, 0.24).lerp(Color(0.22, 0.30, 0.17), smoothstep(0.05, 0.4, t))
			col = col.lerp(Color(0.44, 0.42, 0.38), smoothstep(0.32, 0.72, t))
			col = col.lerp(Color(0.86, 0.88, 0.9), smoothstep(0.82, 0.98, t))
			if 1.0 - n.y > 0.42:
				col = col.lerp(Color(0.35, 0.33, 0.31), 0.6)

			# Water.
			var info: Vector3 = field.river_info(wx, wz)
			if info.x < info.z * 0.5:
				col = Color(0.10, 0.25, 0.33)
				shade = 1.0
			elif info.x < info.z * 0.5 + 4.0:
				col = col.lerp(Color(0.45, 0.42, 0.33), 0.5)

			# Lake.
			if h < 5.35 and Vector2(wx - 6.0, wz - 966.0).length() < 194.0:
				col = Color(0.10, 0.25, 0.33)
				shade = 1.0

			# Roads.
			var road_d: float = field.distance_to_road(wx, wz)
			if road_d < 5.0:
				col = Color(0.62, 0.53, 0.38)
				shade = maxf(shade, 0.85)
			elif road_d < 8.0:
				col = col.lerp(Color(0.55, 0.47, 0.34), 0.5)

			col = Color(col.r * shade, col.g * shade, col.b * shade)
			img.set_pixel(x, y, col)

	# Settlement + landmark markers (small cross markers).
	var markers := [
		[Config.VILLAGE_CENTER, Color(0.95, 0.83, 0.4)],
		[Config.CASTLE_CENTER, Color(0.92, 0.35, 0.28)],
		[Config.HAMLET_CENTER, Color(0.95, 0.83, 0.4)],
		[Config.RUINS_SITE, Color(0.75, 0.7, 0.9)],
		[Config.WATCHTOWER_SITE, Color(0.75, 0.7, 0.9)],
		[Config.CAMP_SITE, Color(0.9, 0.6, 0.3)],
		[Config.CAVE_SITE, Color(0.8, 0.8, 0.8)],
		[Config.WATERFALL_SITE, Color(0.45, 0.8, 0.95)],
	]
	for m in markers:
		var p: Vector2 = m[0]
		var mx := int((p.x + Config.WORLD_HALF) / step)
		var my := int((p.y + Config.WORLD_HALF) / step)
		for dy in range(-4, 5):
			for dx in range(-4, 5):
				if absf(dx) + absf(dy) > 4:
					continue
				var px := clampi(mx + dx, 0, res - 1)
				var py := clampi(my + dy, 0, res - 1)
				var base := img.get_pixel(px, py)
				img.set_pixel(px, py, base.lerp(m[1] as Color, 0.85))

	var out_path := ProjectSettings.globalize_path("res://docs/world_map.png")
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(img.save_png_to_buffer())
		f.close()
	print("[BTH] wrote ", out_path)

	var total := (Time.get_ticks_msec() - t0) / 1000.0
	var stats := {
		"world_size_m": Config.WORLD_SIZE,
		"map_pixels": res,
		"metres_per_pixel": step,
		"height_min_m": snappedf(h_min, 0.1),
		"height_max_m": snappedf(h_max, 0.1),
		"field_stats": field.stats(),
		"render_seconds": snappedf(total, 0.01),
		"note": "Shaded relief computed from TerrainField.height(); not an engine screenshot.",
	}
	var js := FileAccess.open(ProjectSettings.globalize_path("res://docs/world_extents.json"),
		FileAccess.WRITE)
	if js != null:
		js.store_string(JSON.stringify(stats, "  "))
		js.close()
	print(JSON.stringify(stats))
	quit()
