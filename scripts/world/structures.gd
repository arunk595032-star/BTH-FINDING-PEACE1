extends RefCounted
## Historical architecture: Thornbury village, Tarnwatch Keep, the hamlet,
## stone arch bridges, ruins, watchtower, camp and cave.
##
## Everything is built from the same small mesh grammar (stone plinth, timber
## frame, plaster infill, tiled roof) so the settlement reads as one culture
## built over time.  Geometry is merged per material and collisions are box
## approximations, which keeps the physics and draw calls cheap.

const Config = preload("res://scripts/core/world_config.gd")
const Mats = preload("res://scripts/core/material_library.gd")
const MeshKit = preload("res://scripts/world/mesh_kit.gd")
const Assets = preload("res://scripts/core/asset_library.gd")


var field
var kit
var root: Node3D
var stats := {"houses": 0, "bridges": 0, "landmarks": 0, "props": 0}
var build_timings := {}

var _mat_stone: StandardMaterial3D
var _mat_brick: StandardMaterial3D
var _mat_plaster: StandardMaterial3D
var _mat_timber: StandardMaterial3D
var _mat_wood: StandardMaterial3D
var _mat_roof: StandardMaterial3D
var _mat_cobble: StandardMaterial3D
var _mat_dark: StandardMaterial3D
var _mat_canvas: StandardMaterial3D
var _mat_soil: StandardMaterial3D
var _mat_metal: StandardMaterial3D

var _rng := RandomNumberGenerator.new()


func setup(p_field: RefCounted) -> void:
	field = p_field
	_mat_stone = Mats.stone()
	_mat_brick = Mats.brick()
	_mat_plaster = Mats.plaster()
	_mat_timber = Mats.timber()
	_mat_wood = Mats.wood()
	_mat_roof = Mats.roof()
	_mat_cobble = Mats.cobble()
	_mat_dark = Mats.plain(Color(0.055, 0.06, 0.06), 0.6)
	_mat_canvas = Mats.plain(Color(0.66, 0.58, 0.44), 0.95)
	_mat_soil = Mats.ground()
	_mat_metal = Mats.plain(Color(0.22, 0.22, 0.2), 0.45)


func build(parent: Node3D) -> void:
	var build_started := Time.get_ticks_usec()
	kit = MeshKit.new()
	root = Node3D.new()
	root.name = "Settlements"
	parent.add_child(root)
	_measure_stage("village_ms", Callable(self, "_build_village"))
	_measure_stage("farmland_ms", Callable(self, "_build_farmland"))
	_measure_stage("castle_ms", Callable(self, "_build_castle"))
	_measure_stage("hamlet_ms", Callable(self, "_build_hamlet"))
	_measure_stage("watchtower_ms", Callable(self, "_build_watchtower"))
	_measure_stage("ruins_ms", Callable(self, "_build_ruins"))
	_measure_stage("camp_ms", Callable(self, "_build_camp"))
	_measure_stage("cave_ms", Callable(self, "_build_cave"))
	_measure_stage("bridges_ms", Callable(self, "_build_bridges"))
	_measure_stage("hero_props_ms", Callable(self, "_spawn_hero_props"))
	var commit_started := Time.get_ticks_usec()
	kit.commit(root)
	build_timings["mesh_commit_ms"] = float(Time.get_ticks_usec() - commit_started) / 1000.0
	var collision_started := Time.get_ticks_usec()
	kit.build_collision(root)
	build_timings["collision_build_ms"] = float(Time.get_ticks_usec() - collision_started) / 1000.0
	build_timings["total_ms"] = float(Time.get_ticks_usec() - build_started) / 1000.0
	build_timings["geometry_batches"] = kit._surfaces.size()
	build_timings["collision_boxes"] = kit.box_colliders.size()


func _measure_stage(label: String, action: Callable) -> void:
	var started := Time.get_ticks_usec()
	action.call()
	build_timings[label] = float(Time.get_ticks_usec() - started) / 1000.0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _ground(x: float, z: float) -> float:
	return field.height(x, z)


func _xform(pos: Vector3, yaw := 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw), pos)


func _box(key: String, mat: Material, base: Transform3D, local: Vector3, size: Vector3,
		yaw := 0.0, roll := 0.0, collide := true, uv := 0.7) -> void:
	var basis := base.basis * Basis(Vector3.UP, yaw)
	if roll != 0.0:
		basis = basis * Basis(Vector3.RIGHT, roll)
	kit.add_box(key, mat, Transform3D(basis, base * local), size, uv, collide)


func _collide(base: Transform3D, local: Vector3, size: Vector3, yaw := 0.0) -> void:
	kit.box_colliders.append({
		"transform": Transform3D(base.basis * Basis(Vector3.UP, yaw), base * local),
		"size": size,
	})


func _cyl(key: String, mat: Material, base: Transform3D, local: Vector3, radius: float,
		height: float, segments := 18, collide := false) -> void:
	kit.add_cylinder(key, mat, Transform3D(base.basis, base * local), radius, height, segments, 0.6, true)
	if collide:
		_collide(base, local, Vector3(radius * 1.7, height, radius * 1.7))


# ---------------------------------------------------------------------------
# Buildings
# ---------------------------------------------------------------------------
func _house(center: Vector2, yaw: float, width: float, depth: float, floors: int,
		style: int) -> void:
	_rng.seed = int(center.x * 13.0 + center.y * 7.0) ^ Config.SEED
	var ground := _ground(center.x, center.y) - 0.1
	var base := _xform(Vector3(center.x, ground, center.y), yaw)
	var wall_h := 3.0 * float(floors)
	var rise := 2.1 + width * 0.055
	var plinth_h := 1.3
	var plaster := _mat_plaster if style != 1 else _mat_brick
	var roof_mat := _mat_roof if style != 2 else _mat_wood
	var w := width
	var d := depth

	# Stone plinth, sunk into the pad so no gap shows on a slope.
	_box("stone", _mat_stone, base, Vector3(0, plinth_h * 0.5, 0),
		Vector3(w + 0.4, plinth_h, d + 0.4), 0.0, 0.0, true, 0.65)
	# Main walls.
	_box("wall", plaster, base, Vector3(0, plinth_h + wall_h * 0.5, 0),
		Vector3(w, wall_h, d), 0.0, 0.0, true, 0.55)
	# Upper jetty on taller houses.
	if floors >= 2 and style == 0:
		_box("wall", _mat_timber, base,
			Vector3(0, plinth_h + wall_h - 0.15, 0), Vector3(w + 0.7, 0.35, d + 0.7),
			0.0, 0.0, false, 0.6)

	# Timber frame: corner posts, sills, braces.
	var post_h := wall_h
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box("timber", _mat_timber, base,
				Vector3(sx * (w * 0.5 - 0.1), plinth_h + post_h * 0.5, sz * (d * 0.5 - 0.1)),
				Vector3(0.24, post_h, 0.24), 0.0, 0.0, false, 0.9)
	# Horizontal beams.
	for level in floors:
		var y := plinth_h + 0.25 + float(level) * 3.0
		_box("timber", _mat_timber, base, Vector3(0, y, d * 0.5 + 0.02),
			Vector3(w, 0.22, 0.12), 0.0, 0.0, false, 0.9)
		_box("timber", _mat_timber, base, Vector3(0, y, -d * 0.5 - 0.02),
			Vector3(w, 0.22, 0.12), 0.0, 0.0, false, 0.9)
	# Diagonal braces on the front face.
	for bx in [-1.0, 1.0]:
		for level in floors:
			var y := plinth_h + 1.6 + float(level) * 3.0
			_box("timber", _mat_timber, base,
				Vector3(bx * w * 0.32, y, d * 0.5 + 0.05),
				Vector3(0.16, 2.4, 0.1), 0.0, bx * 0.55, false, 0.9)

	# Roof.
	var roof_y := plinth_h + wall_h + rise * 0.5
	kit.add_gable_roof("roof", roof_mat,
		Transform3D(base.basis, base * Vector3(0, roof_y, 0)), w, d, rise, 0.55, 0.55)

	# Door (front face, +Z).
	var door_w := 1.15
	_box("timber", _mat_wood, base, Vector3(-w * 0.18, plinth_h + 1.05, d * 0.5 + 0.06),
		Vector3(door_w, 2.1, 0.14), 0.0, 0.0, false, 1.0)
	# Windows.
	var window_rows := floors
	for level in window_rows:
		for wx in [-1.0, 1.0]:
			_box("dark", _mat_dark, base,
				Vector3(wx * w * 0.26, plinth_h + 1.75 + level * 3.0, d * 0.5 + 0.05),
				Vector3(0.85, 1.0, 0.1), 0.0, 0.0, false, 1.0)
			_box("timber", _mat_timber, base,
				Vector3(wx * w * 0.26, plinth_h + 2.3 + level * 3.0, d * 0.5 + 0.07),
				Vector3(1.0, 0.14, 0.14), 0.0, 0.0, false, 1.0)
	# Back windows.
	for level in window_rows:
		_box("dark", _mat_dark, base,
			Vector3(w * 0.2, plinth_h + 1.75 + level * 3.0, -d * 0.5 - 0.05),
			Vector3(0.8, 0.95, 0.1), 0.0, 0.0, false, 1.0)

	# Chimney.
	var chimney_x := w * 0.32
	_box("stone", _mat_brick, base,
		Vector3(chimney_x, plinth_h + wall_h * 0.7, -d * 0.22),
		Vector3(0.75, wall_h * 1.3 + rise, 0.75), 0.0, 0.0, false, 0.9)
	stats["houses"] += 1


func _well(center: Vector2) -> void:
	var base := _xform(Vector3(center.x, _ground(center.x, center.y), center.y), 0.4)
	_cyl("stone", _mat_stone, base, Vector3(0, 0.55, 0), 1.5, 1.1, 16, true)
	_cyl("dark", _mat_dark, base, Vector3(0, 1.12, 0), 1.15, 0.05, 16, false)
	for sx in [-1.0, 1.0]:
		_box("timber", _mat_timber, base, Vector3(sx * 1.25, 1.6, 0),
			Vector3(0.2, 2.2, 0.2), 0.0, 0.0, true, 1.0)
	_box("timber", _mat_timber, base, Vector3(0, 2.6, 0), Vector3(2.9, 0.18, 0.18), 0.0, 0.0, false, 1.0)
	kit.add_gable_roof("roof", _mat_roof,
		Transform3D(base.basis, base * Vector3(0, 2.9, 0)), 3.2, 2.0, 0.9, 0.25, 0.6)
	_box("metal", _mat_metal, base, Vector3(0, 1.9, 0), Vector3(0.08, 1.4, 0.08), 0.0, 0.0, false)


func _fence_line(a: Vector2, b: Vector2, spacing := 3.0) -> void:
	var length := a.distance_to(b)
	var count := maxi(1, int(length / spacing))
	var dir := (b - a).normalized()
	var yaw := atan2(dir.x, dir.y)
	for i in count + 1:
		var p := a + dir * (length * float(i) / float(count))
		var g := _ground(p.x, p.y)
		var base := _xform(Vector3(p.x, g, p.y), yaw)
		_box("timber", _mat_timber, base, Vector3(0, 0.65, 0), Vector3(0.14, 1.3, 0.14), 0.0, 0.0, false, 1.0)
		if i < count:
			var next := a + dir * (length * float(i + 1) / float(count))
			var mid := (p + next) * 0.5
			var gm := (_ground(p.x, p.y) + _ground(next.x, next.y)) * 0.5
			var seg_len := p.distance_to(next)
			var fb := _xform(Vector3(mid.x, gm, mid.y), yaw)
			_box("timber", _mat_timber, fb, Vector3(0, 0.95, 0),
				Vector3(0.1, 0.12, seg_len), 0.0, 0.0, false, 1.0)
			_box("timber", _mat_timber, fb, Vector3(0, 0.55, 0),
				Vector3(0.09, 0.1, seg_len), 0.0, 0.0, false, 1.0)


func _plaza(center: Vector2, radius: float) -> void:
	var h := _ground(center.x, center.y)
	var base := _xform(Vector3(center.x, h, center.y), 0.0)
	kit.add_cylinder("cobble", _mat_cobble, Transform3D(base.basis, base * Vector3(0, 0.06, 0)),
		radius, 0.16, 26, 0.5, true)
	_collide(base, Vector3(0, 0.06, 0), Vector3(radius * 1.9, 0.2, radius * 1.9))


func _market_stall(center: Vector2, yaw: float) -> void:
	var base := _xform(Vector3(center.x, _ground(center.x, center.y), center.y), yaw)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box("timber", _mat_timber, base, Vector3(sx * 1.4, 1.1, sz * 1.0),
				Vector3(0.14, 2.2, 0.14), 0.0, 0.0, false, 1.0)
	_box("canvas", _mat_canvas, base, Vector3(0, 2.35, 0), Vector3(3.4, 0.08, 2.6), 0.0, 0.0, false)
	_box("timber", _mat_wood, base, Vector3(0, 0.9, 0), Vector3(2.8, 0.12, 1.6), 0.0, 0.0, true)
	_box("canvas", _mat_canvas, base, Vector3(0, 0.2, 1.0), Vector3(2.6, 1.4, 0.05), 0.0, 0.0, false)


func _cart(center: Vector2, yaw: float) -> void:
	var base := _xform(Vector3(center.x, _ground(center.x, center.y), center.y), yaw)
	_box("timber", _mat_wood, base, Vector3(0, 0.85, 0), Vector3(2.6, 0.5, 1.4), 0.0, 0.0, true)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_cyl("timber", _mat_wood, base, Vector3(sx * 0.9, 0.55, sz * 0.78), 0.55, 0.16, 12, false)
	_box("timber", _mat_timber, base, Vector3(-2.2, 0.7, 0), Vector3(2.0, 0.14, 0.14), 0.0, 0.05, false)


# ---------------------------------------------------------------------------
# Village
# ---------------------------------------------------------------------------
func _build_village() -> void:
	var c := Config.VILLAGE_CENTER
	_plaza(c, 11.0)
	_well(c + Vector2(-7.5, 6.0))
	_market_stall(c + Vector2(10.0, -8.0), -0.5)
	_market_stall(c + Vector2(13.5, 3.0), 0.3)
	_cart(c + Vector2(-12.0, -6.0), 1.1)

	# House rows along the main street and the back lanes.
	var lots := [
		[Vector2(-224, 148), PI * 0.5, 9.0, 7.0, 2, 0],
		[Vector2(-224, 182), PI * 0.5, 8.0, 6.5, 1, 1],
		[Vector2(-222, 296), PI * 0.5, 10.0, 7.5, 2, 0],
		[Vector2(-224, 330), PI * 0.5, 8.5, 7.0, 1, 2],
		[Vector2(-170, 166), -PI * 0.5, 9.5, 7.0, 2, 0],
		[Vector2(-168, 200), -PI * 0.5, 8.0, 6.0, 1, 1],
		[Vector2(-170, 306), -PI * 0.5, 9.0, 7.5, 2, 0],
		[Vector2(-168, 340), -PI * 0.5, 8.5, 6.5, 1, 2],
		[Vector2(-262, 172), PI * 0.5, 8.5, 6.5, 2, 1],
		[Vector2(-260, 252), PI * 0.5, 9.5, 7.0, 1, 0],
		[Vector2(-262, 316), PI * 0.5, 8.0, 6.0, 2, 0],
		[Vector2(-136, 186), -PI * 0.5, 9.0, 7.0, 1, 0],
		[Vector2(-134, 262), -PI * 0.5, 10.0, 7.5, 2, 2],
		[Vector2(-136, 320), -PI * 0.5, 8.0, 6.5, 1, 1],
		[Vector2(-300, 226), PI * 0.5, 8.5, 6.5, 1, 0],
	]
	for lot in lots:
		_house(lot[0], lot[1], lot[2], lot[3], lot[4], lot[5])

	# Garden fences behind the west row.
	_fence_line(Vector2(-238, 158), Vector2(-238, 196))
	_fence_line(Vector2(-238, 158), Vector2(-262, 158))
	_fence_line(Vector2(-238, 196), Vector2(-262, 196))
	_fence_line(Vector2(-156, 300), Vector2(-156, 336))
	_fence_line(Vector2(-156, 336), Vector2(-128, 336))
	# Village boundary markers.
	for i in 6:
		var ang := TAU * float(i) / 6.0
		var p := c + Vector2(cos(ang), sin(ang)) * 62.0
		var base := _xform(Vector3(p.x, _ground(p.x, p.y), p.y), ang)
		_box("stone", _mat_stone, base, Vector3(0, 0.75, 0), Vector3(0.5, 1.5, 0.5), 0.0, 0.0, true, 0.8)
	stats["landmarks"] += 1


func _build_farmland() -> void:
	var fields := [
		[Vector2(-96, 424), 64.0, 40.0, 0.15],
		[Vector2(-286, 402), 46.0, 30.0, -0.4],
	]
	for f in fields:
		var center: Vector2 = f[0]
		var w: float = f[1]
		var d: float = f[2]
		var yaw: float = f[3]
		var h := _ground(center.x, center.y)
		var base := _xform(Vector3(center.x, h, center.y), yaw)
		# Tilled soil plate.
		_box("soil", _mat_soil, base, Vector3(0, 0.04, 0), Vector3(w, 0.12, d), 0.0, 0.0, false, 0.5)
		# Furrows.
		var rows := int(d / 3.0)
		for r in rows:
			var z := -d * 0.5 + 1.5 + float(r) * 3.0
			_box("soil", Mats.plain(Color(0.19, 0.15, 0.11), 1.0), base,
				Vector3(0, 0.12, z), Vector3(w - 2.0, 0.1, 0.7), 0.0, 0.0, false, 1.0)
		# Crop clumps.
		var cols := int(w / 4.0)
		for r in rows:
			for cc in cols:
				if _rng.randf() < 0.7:
					var px := -w * 0.5 + 2.0 + float(cc) * 4.0
					var pz := -d * 0.5 + 1.0 + float(r) * 3.0
					var wp := base * Vector3(px, 0.0, pz)
					_cyl("crop", Mats.plain(Color(0.42, 0.5, 0.24), 0.95), base,
						Vector3(px, 0.45, pz), 0.5, 0.8, 6, false)
		# Boundary fence.
		var corners := [
			base * Vector3(-w * 0.5, 0, -d * 0.5), base * Vector3(w * 0.5, 0, -d * 0.5),
			base * Vector3(w * 0.5, 0, d * 0.5), base * Vector3(-w * 0.5, 0, d * 0.5),
		]
		for i in 4:
			var a: Vector3 = corners[i]
			var b: Vector3 = corners[(i + 1) % 4]
			_fence_line(Vector2(a.x, a.z), Vector2(b.x, b.z), 3.2)
		# Scarecrow.
		var sc := center + Vector2(0.0, d * 0.2)
		var sb := _xform(Vector3(sc.x, _ground(sc.x, sc.y), sc.y), 0.2)
		_box("timber", _mat_timber, sb, Vector3(0, 1.3, 0), Vector3(0.12, 2.6, 0.12), 0.0, 0.0, false)
		_box("timber", _mat_timber, sb, Vector3(0, 2.0, 0), Vector3(1.8, 0.12, 0.12), 0.0, 0.0, false)
		_box("canvas", _mat_canvas, sb, Vector3(0, 1.85, 0), Vector3(0.9, 1.2, 0.35), 0.0, 0.0, false)
		_box("canvas", _mat_canvas, sb, Vector3(0, 2.65, 0), Vector3(0.45, 0.45, 0.45), 0.0, 0.0, false)


# ---------------------------------------------------------------------------
# Castle
# ---------------------------------------------------------------------------
func _build_castle() -> void:
	var c := Config.CASTLE_CENTER
	var h := _ground(c.x, c.y)
	var base := _xform(Vector3(c.x, h, c.y), 0.0)
	var hw := 56.0
	var hd := 44.0
	var wall_h := 10.0
	var thick := 2.6

	# Courtyard paving.
	_box("cobble", _mat_cobble, base, Vector3(0, 0.08, 0), Vector3(hw * 2.0 - 4.0, 0.16, hd * 2.0 - 4.0), 0.0, 0.0, true, 0.35)

	# Curtain walls (south wall split to leave the gate).
	_wall_strip(base, Vector3(0, wall_h * 0.5, -hd), Vector3(hw * 2.0, wall_h, thick))
	_wall_strip(base, Vector3(-hw, wall_h * 0.5, 0), Vector3(thick, wall_h, hd * 2.0))
	_wall_strip(base, Vector3(hw, wall_h * 0.5, 0), Vector3(thick, wall_h, hd * 2.0))
	_wall_strip(base, Vector3(-(hw * 0.5 + 8.0), wall_h * 0.5, hd), Vector3(hw - 16.0, wall_h, thick))
	_wall_strip(base, Vector3(hw * 0.5 + 8.0, wall_h * 0.5, hd), Vector3(hw - 16.0, wall_h, thick))

	# Crenellations.
	for x in range(-13, 14):
		var px := float(x) * 4.2
		_merlon(base, Vector3(px, wall_h, -hd), 0.0)
		if absf(px) > 15.0:
			_merlon(base, Vector3(px, wall_h, hd), 0.0)
	for z in range(-10, 11):
		var pz := float(z) * 4.2
		_merlon(base, Vector3(-hw, wall_h, pz), PI * 0.5)
		_merlon(base, Vector3(hw, wall_h, pz), PI * 0.5)

	# Corner towers with conical roofs.
	for corner in [Vector3(-hw, 0, -hd), Vector3(hw, 0, -hd), Vector3(-hw, 0, hd), Vector3(hw, 0, hd)]:
		var th := 17.0
		_cyl("brick", _mat_brick, base, corner + Vector3(0, th * 0.5, 0), 7.0, th, 20, true)
		kit.add_cone("roof", _mat_roof,
			Transform3D(base.basis, base * (corner + Vector3(0, th + 3.2, 0))), 7.8, 6.4, 20, 0.5)
		# Arrow slits.
		for k in 3:
			var ang := TAU * float(k) / 3.0
			_box("dark", _mat_dark, base,
				corner + Vector3(cos(ang) * 6.9, th * 0.55, sin(ang) * 6.9),
				Vector3(0.35, 2.0, 0.3), ang, 0.0, false)

	# Gatehouse (south wall).
	var gate := Vector3(0, 0, hd)
	for sx in [-1.0, 1.0]:
		_cyl("brick", _mat_brick, base, gate + Vector3(sx * 9.0, 8.0, 0), 5.0, 16.0, 18, true)
		kit.add_cone("roof", _mat_roof,
			Transform3D(base.basis, base * (gate + Vector3(sx * 9.0, 19.0, 0))), 5.6, 4.6, 18, 0.5)
	_box("brick", _mat_brick, base, gate + Vector3(0, 12.0, 0), Vector3(18.0, 6.0, 3.2), 0.0, 0.0, true, 0.6)
	# Gate doors, one leaf open.
	_box("timber", _mat_wood, base, gate + Vector3(-3.4, 3.6, 0.4),
		Vector3(4.2, 7.2, 0.35), -0.35, 0.0, true, 0.8)
	_box("timber", _mat_wood, base, gate + Vector3(3.8, 3.6, 0.9),
		Vector3(4.0, 7.2, 0.35), 0.6, 0.0, false, 0.8)
	# Gate steps down to the road.
	for i in 4:
		_box("stone", _mat_stone, base, gate + Vector3(0, 0.3 - float(i) * 0.55, 4.2 + float(i) * 1.5),
			Vector3(12.0, 0.6, 1.6), 0.0, 0.0, true, 0.7)

	# Keep: four walls + floor, open doorway so the interior is usable.
	var keep_w := 24.0
	var keep_d := 18.0
	var keep_h := 18.0
	_wall_strip(base, Vector3(0, keep_h * 0.5, -8.0), Vector3(keep_w, keep_h, 1.6))
	_wall_strip(base, Vector3(-11.2, keep_h * 0.5, 1.0), Vector3(1.6, keep_h, keep_d))
	_wall_strip(base, Vector3(11.2, keep_h * 0.5, 1.0), Vector3(1.6, keep_h, keep_d))
	_wall_strip(base, Vector3(-7.0, keep_h * 0.5, 10.0), Vector3(8.0, keep_h, 1.6))
	_wall_strip(base, Vector3(7.0, keep_h * 0.5, 10.0), Vector3(8.0, keep_h, 1.6))
	_box("stone", _mat_stone, base, Vector3(0, 0.12, 1.0), Vector3(22.0, 0.3, 19.0), 0.0, 0.0, true, 0.4)
	kit.add_gable_roof("roof", _mat_roof,
		Transform3D(base.basis, base * Vector3(0, keep_h + 3.0, 1.0)), keep_w + 1.5, keep_d + 1.5, 6.0, 0.5, 0.45)
	# Keep windows and door frames.
	for i in 4:
		_box("dark", _mat_dark, base, Vector3(-8.0 + float(i) * 5.4, 11.0, 10.9),
			Vector3(0.6, 1.8, 0.4), 0.0, 0.0, false)
		_box("dark", _mat_dark, base, Vector3(-8.0 + float(i) * 5.4, 15.0, 10.9),
			Vector3(0.6, 1.4, 0.4), 0.0, 0.0, false)
	_box("timber", _mat_wood, base, Vector3(0, 3.2, 10.9), Vector3(4.0, 6.4, 0.4), 0.0, 0.0, false, 0.8)
	# Interior expansion foundation: a raised dais and stairs.
	_box("stone", _mat_stone, base, Vector3(0, 1.0, -3.0), Vector3(10.0, 1.2, 5.0), 0.0, 0.0, true, 0.5)
	for i in 3:
		_box("stone", _mat_stone, base, Vector3(0, 0.25 + float(i) * 0.4, 1.6 + float(i) * 0.8),
			Vector3(5.0, 0.4, 0.9), 0.0, 0.0, true, 0.6)
	# Roofed stair turret.
	_cyl("brick", _mat_brick, base, Vector3(13.5, 7.0, 4.0), 3.0, 14.0, 16, true)
	kit.add_cone("roof", _mat_roof,
		Transform3D(base.basis, base * Vector3(13.5, 16.0, 4.0)), 3.5, 3.4, 16, 0.5)

	# Courtyard props.
	_cart(c + Vector2(20.0, -18.0), 0.8)
	_cart(c + Vector2(-18.0, 26.0), -1.4)
	_market_stall(c + Vector2(-26.0, -26.0), 0.9)
	for i in 5:
		var p := c + Vector2(-30.0 + float(i) * 6.0, 30.0)
		var g := _ground(p.x, p.y)
		_cyl("brick", _mat_brick, base, Vector3(p.x - c.x, 0.6, p.y - c.y), 0.7, 1.2, 10, true)
	stats["landmarks"] += 1


func _wall_strip(base: Transform3D, local: Vector3, size: Vector3) -> void:
	_box("brick", _mat_brick, base, local, size, 0.0, 0.0, true, 0.45)


func _merlon(base: Transform3D, local: Vector3, yaw: float) -> void:
	_box("brick", _mat_brick, base, local + Vector3(0, 0.8, 0), Vector3(1.9, 1.6, 0.9), yaw, 0.0, false, 0.8)


# ---------------------------------------------------------------------------
# Hamlet
# ---------------------------------------------------------------------------
func _build_hamlet() -> void:
	var c := Config.HAMLET_CENTER
	_plaza(c, 7.0)
	_well(c + Vector2(4.0, 4.0))
	var lots := [
		[Vector2(292, 726), PI * 0.5, 8.0, 6.0, 1, 1],
		[Vector2(352, 730), -PI * 0.5, 7.5, 6.0, 1, 2],
		[Vector2(300, 762), PI * 0.5, 8.5, 6.5, 2, 0],
		[Vector2(346, 766), -PI * 0.5, 8.0, 6.0, 1, 0],
	]
	for lot in lots:
		_house(lot[0], lot[1], lot[2], lot[3], lot[4], lot[5])
	_fence_line(Vector2(276, 700), Vector2(276, 786))
	_fence_line(Vector2(276, 700), Vector2(372, 700))
	stats["landmarks"] += 1


# ---------------------------------------------------------------------------
# Ruins, watchtower, camp, cave
# ---------------------------------------------------------------------------
func _build_watchtower() -> void:
	var site := Config.WATCHTOWER_SITE
	var h := _ground(site.x, site.y)
	var base := _xform(Vector3(site.x, h, site.y), 0.3)
	_cyl("stone", _mat_stone, base, Vector3(0, 3.0, 0), 4.6, 6.0, 16, true)
	# Broken upper storey: cylinders of decreasing height around the rim.
	for i in 10:
		var ang := TAU * float(i) / 10.0
		var hh := 3.0 + sin(float(i) * 1.9) * 2.2
		var local := Vector3(cos(ang) * 4.0, 7.0 + hh * 0.5, sin(ang) * 4.0)
		_box("stone", _mat_stone, base, local, Vector3(1.6, hh, 1.6), ang, 0.0, true, 0.9)
	# Fallen stones and a palisade.
	_rng.seed = 9911
	for i in 8:
		var ang := _rng.randf_range(0, TAU)
		var r := _rng.randf_range(6.0, 13.0)
		var p := site + Vector2(cos(ang), sin(ang)) * r
		var g := _ground(p.x, p.y)
		_box("stone", _mat_stone, _xform(Vector3(p.x, g, p.y), _rng.randf() * TAU),
			Vector3(0, 0.35, 0), Vector3(_rng.randf_range(0.8, 1.8), 0.7, _rng.randf_range(0.6, 1.4)),
			0.0, 0.0, true, 0.9)
	for i in 6:
		var ang := TAU * float(i) / 6.0
		var p := site + Vector2(cos(ang), sin(ang)) * 16.0
		var g := _ground(p.x, p.y)
		_box("timber", _mat_timber, _xform(Vector3(p.x, g, p.y), ang),
			Vector3(0, 1.2, 0), Vector3(0.22, 2.4, 0.22), 0.0, 0.0, true, 1.0)
	stats["landmarks"] += 1


func _build_ruins() -> void:
	var site := Config.RUINS_SITE
	var h := _ground(site.x, site.y)
	var base := _xform(Vector3(site.x, h, site.y), 0.2)
	# Broken curtain wall.
	for i in 7:
		var x := -15.0 + float(i) * 5.0
		var hh := 5.5 - absf(float(i) - 3.0) * 0.9 + sin(float(i) * 2.3) * 1.0
		_box("stone", _mat_stone, base, Vector3(x, hh * 0.5, -10.0), Vector3(5.0, hh, 1.4), 0.0, 0.0, true, 0.6)
	# Columns.
	for i in 5:
		var ang := TAU * float(i) / 5.0
		var pos := Vector3(cos(ang) * 9.0, 0, sin(ang) * 9.0)
		var hh := 6.0 if i % 2 == 0 else 4.0
		_cyl("stone", _mat_stone, base, pos + Vector3(0, hh * 0.5, 0), 0.75, hh, 12, true)
		_box("stone", _mat_stone, base, pos + Vector3(0, hh + 0.2, 0), Vector3(2.0, 0.4, 2.0), 0.0, 0.0, false, 0.7)
	# Altar and rubble.
	_box("stone", _mat_stone, base, Vector3(0, 0.6, 0), Vector3(5.0, 1.2, 3.0), 0.0, 0.0, true)
	_rng.seed = 551
	for i in 12:
		var ang := _rng.randf_range(0, TAU)
		var r := _rng.randf_range(2.0, 16.0)
		var p := site + Vector2(cos(ang), sin(ang)) * r
		var g := _ground(p.x, p.y)
		_box("stone", _mat_stone, _xform(Vector3(p.x, g, p.y), _rng.randf() * TAU),
			Vector3(0, 0.3, 0), Vector3(_rng.randf_range(0.7, 1.6), 0.6, _rng.randf_range(0.5, 1.2)),
			0.0, 0.0, false, 0.9)
	stats["landmarks"] += 1


func _build_camp() -> void:
	var site := Config.CAMP_SITE
	var h := _ground(site.x, site.y)
	var base := _xform(Vector3(site.x, h, site.y), 0.0)
	# Tents.
	for i in 3:
		var ang := TAU * float(i) / 3.0 + 0.4
		var p := Vector3(cos(ang) * 7.0, 0, sin(ang) * 7.0)
		kit.add_cone("canvas", _mat_canvas, Transform3D(base.basis * Basis(Vector3.UP, ang),
			base * (p + Vector3(0, 1.6, 0))), 2.8, 3.4, 4, 0.6)
		_box("canvas", _mat_canvas, base, p + Vector3(0, 0.05, 0), Vector3(3.4, 0.1, 3.4), ang, 0.0, false)
	# Log benches.
	for i in 4:
		var ang := TAU * float(i) / 4.0
		_box("timber", _mat_timber, base,
			Vector3(cos(ang) * 3.4, 0.35, sin(ang) * 3.4), Vector3(2.2, 0.5, 0.5), ang, 0.0, true, 0.8)
	# Palisade gap and fire ring.
	for i in 8:
		var ang := TAU * float(i) / 8.0
		if absf(ang - PI) < 0.4:
			continue
		var p := site + Vector2(cos(ang), sin(ang)) * 14.0
		var g := _ground(p.x, p.y)
		_box("timber", _mat_timber, _xform(Vector3(p.x, g, p.y), ang),
			Vector3(0, 1.3, 0), Vector3(0.24, 2.6, 0.24), 0.0, 0.0, true, 1.0)
	stats["landmarks"] += 1


func _build_cave() -> void:
	var site := Config.CAVE_SITE
	var h := _ground(site.x, site.y)
	var base := _xform(Vector3(site.x, h, site.y), 0.4)
	# A stone mouth built against the mountain flank.
	for sx in [-1.0, 1.0]:
		_box("stone", _mat_stone, base, Vector3(sx * 3.4, 2.4, 0), Vector3(3.0, 5.0, 6.0), 0.0, 0.0, true, 0.5)
	_box("stone", _mat_stone, base, Vector3(0, 5.2, 0), Vector3(9.0, 1.6, 6.0), 0.0, 0.0, true, 0.5)
	_box("dark", _mat_dark, base, Vector3(0, 2.2, 0.1), Vector3(4.4, 4.4, 0.4), 0.0, 0.0, false)
	# Rubble spill.
	_rng.seed = 4288
	for i in 7:
		var p := site + Vector2(_rng.randf_range(-9.0, 9.0), _rng.randf_range(2.0, 10.0))
		var g := _ground(p.x, p.y)
		_box("stone", _mat_stone, _xform(Vector3(p.x, g, p.y), _rng.randf() * TAU),
			Vector3(0, 0.3, 0), Vector3(_rng.randf_range(0.6, 1.4), 0.5, _rng.randf_range(0.6, 1.3)),
			0.0, 0.0, false, 0.9)
	stats["landmarks"] += 1


# ---------------------------------------------------------------------------
# Bridges
# ---------------------------------------------------------------------------
func _build_bridges() -> void:
	for road in Config.ROADS:
		var pts: Array = road["points"]
		var width: float = road["width"]
		var surface: float = road["surface"]
		var crossing := _find_crossing(pts)
		if crossing.is_empty():
			continue
		_build_bridge(crossing["pos"], crossing["dir"], crossing["water_width"] + 18.0,
			width, surface)


func _find_crossing(points: Array) -> Dictionary:
	var samples: Array = []
	for i in points.size() - 1:
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var seg := a.distance_to(b)
		var count := maxi(1, int(seg / 4.0))
		for k in count:
			samples.append(a.lerp(b, float(k) / float(count)))
	samples.append(points[points.size() - 1])
	var best := {}
	var best_dist := INF
	for i in samples.size():
		var p: Vector2 = samples[i]
		var info: Vector3 = field.river_info(p.x, p.y)
		if info.x < info.z * 0.5 + 3.0:
			var tangent: Vector2
			if i == 0:
				tangent = (samples[1] as Vector2) - p
			elif i == samples.size() - 1:
				tangent = p - (samples[i - 1] as Vector2)
			else:
				tangent = (samples[i + 1] as Vector2) - (samples[i - 1] as Vector2)
			tangent = tangent.normalized()
			# Prefer the crossing closest to the middle of the water.
			if info.x < best_dist:
				best_dist = info.x
				var level: float = field.road_info(p.x, p.y).y
				best = {"pos": p, "dir": tangent, "water_width": info.z, "deck": level}
	return best


func _build_bridge(pos: Vector2, dir: Vector2, span: float, width: float,
		surface: float) -> void:
	var road_level: float = field.road_info(pos.x, pos.y).y
	var deck_y := road_level + 0.25
	var yaw := atan2(dir.x, dir.y)
	var base := _xform(Vector3(pos.x, deck_y, pos.y), yaw)
	var span_len := span + 12.0
	var wooden := surface > 0.5
	var deck_mat := _mat_cobble if not wooden else _mat_wood
	var key := "cobble" if not wooden else "timber"

	# Deck.
	_box(key, deck_mat, base, Vector3(0, 0.0, 0), Vector3(width + 1.6, 0.55, span_len), 0.0, 0.0, true, 0.6)
	# Parapets.
	for sx in [-1.0, 1.0]:
		_box(key, deck_mat, base, Vector3(sx * (width * 0.5 + 0.55), 0.5, 0),
			Vector3(0.5, 0.85, span_len), 0.0, 0.0, true, 0.8)
	# Stone arch barrel (axis perpendicular to the road).
	if not wooden:
		var axis := Vector3(dir.y, 0, -dir.x)
		var barrel := Transform3D(Basis(axis, PI * 0.5), base * Vector3(0, -span * 0.5, 0))
		barrel.basis = barrel.basis.scaled(Vector3(1.0, 1.0, 1.0))
		kit.add_cylinder("brick", _mat_brick, barrel, span * 0.5, width + 2.6, 22, 0.35, true)
	else:
		for i in 3:
			var z := -span_len * 0.3 + float(i) * span_len * 0.3
			for sx in [-1.0, 1.0]:
				_box("timber", _mat_timber, base, Vector3(sx * width * 0.35, -1.2, z),
					Vector3(0.35, 2.6, 0.35), 0.0, 0.0, false, 0.9)
	# Abutments.
	for sz in [-1.0, 1.0]:
		_box("stone", _mat_stone, base, Vector3(0, -0.8, sz * (span_len * 0.5 - 1.5)),
			Vector3(width + 2.4, 2.4, 3.2), 0.0, 0.0, true, 0.6)
	stats["bridges"] += 1


# ---------------------------------------------------------------------------
# Hero props (Poly Haven models)
# ---------------------------------------------------------------------------
func _spawn_hero_props() -> void:
	var c := Config.VILLAGE_CENTER
	var barrels := "res://assets/props/polyhaven_wooden_barrels_01/wooden_barrels_01_1k.gltf"
	var crate := "res://assets/props/polyhaven_wooden_crate_01/wooden_crate_01_1k.gltf"
	var firepit := "res://assets/props/polyhaven_stone_fire_pit/stone_fire_pit_1k.gltf"
	var statue := "res://assets/props/polyhaven_gothic_statue/gothic_statue_1k.gltf"
	var boulder := "res://assets/rocks/polyhaven_stone_01/stone_01_1k.gltf"
	var cliff := "res://assets/rocks/polyhaven_coastal_cliff_01/coastal_cliff_01_1k.gltf"
	var stones := "res://assets/rocks/polyhaven_namaqualand_stones_01/namaqualand_stones_01_1k.gltf"
	var trunk := "res://assets/vegetation/polyhaven_dead_tree_trunk/dead_tree_trunk_1k.gltf"

	# Village clutter.
	var village_props := [
		[barrels, Vector2(-206, 244), 0.4, 1.0],
		[barrels, Vector2(-184, 256), 1.9, 0.85],
		[crate, Vector2(-178, 228), 0.7, 1.0],
		[crate, Vector2(-190, 208), 2.4, 0.8],
		[firepit, Vector2(-200, 250), 0.0, 1.0],
	]
	for p in village_props:
		_spawn_at(p[0], p[1], p[2], p[3], true)
	# Castle courtyard statue and barrels.
	_spawn_at(statue, Config.CASTLE_CENTER + Vector2(0, 12), 0.0, 1.15, true)
	_spawn_at(barrels, Config.CASTLE_CENTER + Vector2(-14, 8), 0.8, 1.0, false)
	_spawn_at(crate, Config.CASTLE_CENTER + Vector2(16, -6), 1.4, 1.0, false)
	# Ruins statue.
	_spawn_at(statue, Config.RUINS_SITE + Vector2(-6, 4), -0.4, 0.9, true)
	# Camp fire and crates.
	_spawn_at(firepit, Config.CAMP_SITE, 0.0, 1.0, true)
	_spawn_at(crate, Config.CAMP_SITE + Vector2(4, -3), 0.9, 1.0, false)
	# Boulders around the valley and ruins.
	var spots := [
		[Vector2(120, 120), 1.6], [Vector2(-320, 60), 1.3], [Vector2(300, 320), 1.5],
		[Vector2(-60, -300), 1.8], [Vector2(180, 620), 1.4], [Vector2(-420, 420), 1.7],
	]
	for s in spots:
		_spawn_at(boulder, s[0], float(int(s[0].x) % 17) * 0.37, s[1], true)
	# Stone clusters and fallen trunks.
	_spawn_at(stones, Vector2(-240, 120), 0.4, 2.2, true)
	_spawn_at(stones, Config.RUINS_SITE + Vector2(10, -8), 1.1, 2.0, true)
	_spawn_at(stones, Config.CASTLE_CENTER + Vector2(-30, 30), 2.1, 1.8, true)
	_spawn_at(trunk, Vector2(-360, 210), 0.8, 1.0, true)
	_spawn_at(trunk, Vector2(90, 340), 2.3, 1.1, true)
	# Waterfall cliff outcrop.
	_spawn_at(cliff, Config.WATERFALL_SITE + Vector2(26, -12), 1.2, 0.55, true)


func _spawn_at(path: String, pos: Vector2, yaw: float, scale: float, collide: bool) -> void:
	if not Assets.has_asset(path):
		return
	var g := _ground(pos.x, pos.y)
	var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale)),
		Vector3(pos.x, g - 0.15, pos.y))
	Assets.spawn(root, path, xf, collide)
	stats["props"] += 1
