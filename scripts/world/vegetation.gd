extends RefCounted
## Vegetation and scatter system.
##
## Trees are built procedurally as two-surface meshes (bark trunk + alpha
## foliage cards) so a dense forest stays cheap, while Poly Haven CC0 models
## provide the hero undergrowth and rocks.  Placement is terrain-aware:
## height, slope, water, roads and settlement pads are all respected, so
## nothing floats and nothing grows in the river.

const Config = preload("res://scripts/core/world_config.gd")
const Terrain = preload("res://scripts/world/terrain_field.gd")
const Mats = preload("res://scripts/core/material_library.gd")
const Assets = preload("res://scripts/core/asset_library.gd")
const MeshKit = preload("res://scripts/world/mesh_kit.gd")

const FOLIAGE_SHADER := "res://shaders/foliage.gdshader"
const CONIFER_TEX := "res://assets/textures/procedural/foliage/conifer_branch.png"
const LEAF_TEX := "res://assets/textures/procedural/foliage/leaf_cluster.png"
const GRASS_TEX := "res://assets/textures/procedural/foliage/grass_tuft.png"

var field
var meshes: Dictionary = {}
var materials: Dictionary = {}
var stats := {"trees": 0, "grass": 0, "rocks": 0, "props": 0, "chunks": 0}

var _rng := RandomNumberGenerator.new()
var _conifer_mat: ShaderMaterial
var _leaf_mat: ShaderMaterial
var _grass_mat: ShaderMaterial
var _bark_mat: StandardMaterial3D
var _rock_mat: StandardMaterial3D
var _asset_meshes: Dictionary = {}


func setup(p_field: RefCounted) -> void:
	field = p_field
	_mobile_mode = OS.has_feature("android") or OS.has_feature("ios")
	_build_materials()
	meshes["conifer_a"] = _build_conifer(0, 13.0)
	meshes["conifer_b"] = _build_conifer(1, 17.5)
	meshes["conifer_c"] = _build_conifer(2, 9.5)
	meshes["broadleaf"] = _build_broadleaf(0)
	meshes["broadleaf_b"] = _build_broadleaf(1)
	meshes["snag"] = _build_snag()
	meshes["bush"] = _build_bush()
	meshes["rock_a"] = _build_rock(1.0, 9)
	meshes["rock_b"] = _build_rock(1.6, 4)
	meshes["pebble"] = _build_rock(0.32, 21)
	meshes["grass"] = _build_grass_card()
	meshes["fern"] = _build_fern_card()
	# Far LODs: same silhouette from a fraction of the cards, no shadow cast.
	meshes["conifer_a_far"] = _build_conifer_far(13.0)
	meshes["conifer_b_far"] = _build_conifer_far(17.5)
	meshes["conifer_c_far"] = _build_conifer_far(9.5)
	meshes["broadleaf_far"] = _build_broadleaf_far(0)
	meshes["broadleaf_b_far"] = _build_broadleaf_far(1)

	# Poly Haven CC0 undergrowth (real scans, used at low density near the
	# player where their polygon budget is affordable).
	_asset_meshes = {
		"fern": Assets.load_mesh("res://assets/vegetation/polyhaven_fern_02/fern_02_1k.gltf"),
		"weed": Assets.load_mesh("res://assets/vegetation/polyhaven_weed_plant_02/weed_plant_02_1k.gltf"),
		"nettle": Assets.load_mesh("res://assets/vegetation/polyhaven_nettle_plant/nettle_plant_1k.gltf"),
		"rooibos": Assets.load_mesh("res://assets/vegetation/polyhaven_wild_rooibos_bush/wild_rooibos_bush_1k.gltf"),
		"trunk": Assets.load_mesh("res://assets/vegetation/polyhaven_dead_tree_trunk/dead_tree_trunk_1k.gltf"),
		"stones": Assets.load_mesh("res://assets/rocks/polyhaven_namaqualand_stones_01/namaqualand_stones_01_1k.gltf"),
	}


func stats_summary() -> String:
	return "trees %d, grass %d, rocks %d, props %d in %d chunks" % [
		stats["trees"], stats["grass"], stats["rocks"], stats["props"], stats["chunks"]]


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------
func _build_materials() -> void:
	_bark_mat = Mats.bark()
	_rock_mat = _make_rock_material()
	_conifer_mat = _foliage_material(CONIFER_TEX, 0.30, 0.9, Color(0.82, 0.95, 0.80))
	_leaf_mat = _foliage_material(LEAF_TEX, 0.55, 0.82, Color(0.92, 1.0, 0.86))
	_grass_mat = _foliage_material(GRASS_TEX, 0.22, 0.9, Color(0.95, 1.0, 0.82))
	materials["conifer"] = _conifer_mat
	materials["leaf"] = _leaf_mat
	materials["grass"] = _grass_mat
	materials["bark"] = _bark_mat
	materials["rock"] = _rock_mat


func _foliage_material(path: String, wind: float, rough: float, tint: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(FOLIAGE_SHADER)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("wind_strength", wind)
	mat.set_shader_parameter("roughness_value", rough)
	mat.set_shader_parameter("use_vertex_color", 1.0)
	mat.set_shader_parameter("mobile_fill", 0.22 if _mobile_mode else 0.0)
	if ResourceLoader.exists(path):
		mat.set_shader_parameter("albedo_tex", load(path))
	return mat


func _make_rock_material() -> StandardMaterial3D:
	var m: StandardMaterial3D = Mats.stone().duplicate()
	m.albedo_color = Color(0.92, 0.9, 0.86)
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(0.28, 0.28, 0.28)
	m.roughness = 0.92
	return m


# ---------------------------------------------------------------------------
# Mesh construction helpers
# ---------------------------------------------------------------------------
func _add_surface(am: ArrayMesh, st: SurfaceTool, mat: Material) -> void:
	st.index()
	st.generate_tangents()
	var m := st.commit()
	if m == null:
		return
	for i in m.get_surface_count():
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, m.surface_get_arrays(i))
		am.surface_set_material(am.get_surface_count() - 1, mat)


func _card(st: SurfaceTool, center: Vector3, size: Vector2, basis: Basis, color: Color) -> void:
	var right := basis.x.normalized() * size.x * 0.5
	var up := basis.y.normalized() * size.y * 0.5
	var n := basis.z.normalized()
	var a := center - right - up
	var b := center + right - up
	var c := center + right + up
	var d := center - right + up
	for v in [[a, Vector2(0, 1)], [b, Vector2(1, 1)], [c, Vector2(1, 0)],
			[a, Vector2(0, 1)], [c, Vector2(1, 0)], [d, Vector2(0, 0)]]:
		st.set_normal(n)
		st.set_uv(v[1])
		st.set_color(color)
		st.add_vertex(v[0])


func _card_basis(dir: Vector3, tilt: float) -> Basis:
	var up := (Vector3.UP + dir * tilt).normalized()
	var right := dir.cross(up)
	if right.length() < 0.01:
		right = Vector3.RIGHT
	right = right.normalized()
	var normal := right.cross(up).normalized()
	return Basis(right, up, normal)


func _trunk(st: SurfaceTool, height: float, r0: float, r1: float, bend: Vector2,
		segments := 7, rings := 6) -> void:
	for i in rings:
		var t0 := float(i) / float(rings)
		var t1 := float(i + 1) / float(rings)
		var y0 := t0 * height
		var y1 := t1 * height
		var rad0 := lerpf(r0, r1, pow(t0, 0.7))
		var rad1 := lerpf(r0, r1, pow(t1, 0.7))
		var off0 := bend * pow(t0, 1.7) * height * 0.06
		var off1 := bend * pow(t1, 1.7) * height * 0.06
		for s in segments:
			var a0 := TAU * float(s) / float(segments)
			var a1 := TAU * float(s + 1) / float(segments)
			var d0 := Vector3(cos(a0), 0, sin(a0))
			var d1 := Vector3(cos(a1), 0, sin(a1))
			var p0 := d0 * rad0 + Vector3(off0.x, y0, off0.y)
			var p1 := d1 * rad0 + Vector3(off0.x, y0, off0.y)
			var p2 := d1 * rad1 + Vector3(off1.x, y1, off1.y)
			var p3 := d0 * rad1 + Vector3(off1.x, y1, off1.y)
			var n0 := d0
			var n1 := d1
			for v in [[p0, n0, Vector2(a0 / TAU, t0 * 3.0)], [p1, n1, Vector2(a1 / TAU, t0 * 3.0)],
					[p2, n1, Vector2(a1 / TAU, t1 * 3.0)], [p0, n0, Vector2(a0 / TAU, t0 * 3.0)],
					[p2, n1, Vector2(a1 / TAU, t1 * 3.0)], [p3, n0, Vector2(a0 / TAU, t1 * 3.0)]]:
				st.set_normal(v[1])
				st.set_uv(v[2])
				st.add_vertex(v[0])


func _build_conifer(variant: int, height: float) -> ArrayMesh:
	var am := ArrayMesh.new()
	var trunk := SurfaceTool.new()
	trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	_trunk(trunk, height * 0.94, 0.34 + variant * 0.035, 0.045,
		Vector2(sin(float(variant) * 2.1), cos(float(variant) * 1.7)), 9, 9)
	_add_surface(am, trunk, _bark_mat)

	# Layered spruce: visible trunk, upward/outward boughs and foliage at
	# every tier. Avoids the old skirt-like silhouette made by oversized,
	# steeply drooping cards.
	var branches := SurfaceTool.new()
	branches.begin(Mesh.PRIMITIVE_TRIANGLES)
	var foliage := SurfaceTool.new()
	foliage.begin(Mesh.PRIMITIVE_TRIANGLES)
	_rng.seed = 7717 + variant * 131
	var tiers := 11
	for tier in tiers:
		var t := 0.18 + 0.76 * float(tier) / float(tiers - 1)
		var y := t * height
		var radius := pow(1.0 - t, 0.82) * height * 0.31 + 0.16
		var count := 7 if tier < 8 else 5
		for c in count:
			var ang := TAU * (float(c) / float(count) + float(tier) * 0.173)
			ang += _rng.randf_range(-0.10, 0.10)
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			var start := Vector3(0.0, y, 0.0)
			var reach := radius * _rng.randf_range(0.78, 1.08)
			var tip := dir * reach + Vector3(0.0, radius * 0.12, 0.0)
			_branch(branches, start, tip, maxf(0.035, 0.095 * (1.0 - t * 0.55)))
			var leaf_dir := (dir + Vector3(0.0, 0.16, 0.0)).normalized()
			var leaf_center := tip + leaf_dir * 0.12
			var shade := _rng.randf_range(0.72, 1.02) * lerpf(0.82, 1.0, t)
			var leaf_size := Vector2(maxf(0.55, radius * 0.78), maxf(0.32, radius * 0.42))
			_card(foliage, leaf_center, leaf_size, _card_basis(leaf_dir, -0.18),
				Color(shade * 0.72, shade, shade * 0.76))
			# A smaller second cluster gives depth without creating a solid skirt.
			if c % 2 == 0:
				var side_dir := Vector3(-dir.z, 0.08, dir.x).normalized()
				_card(foliage, tip - dir * 0.16, leaf_size * 0.68,
					_card_basis(side_dir, -0.08), Color(shade * 0.68, shade * 0.94, shade * 0.72))
	_add_surface(am, branches, _bark_mat)
	_add_surface(am, foliage, _conifer_mat)
	return am

func _build_broadleaf(variant: int) -> ArrayMesh:
	var am := ArrayMesh.new()
	var h := 7.5 + variant * 2.4
	var trunk := SurfaceTool.new()
	trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	_trunk(trunk, h * 0.6, 0.38, 0.12, Vector2(0.4, -0.3), 8, 5)
	_add_surface(am, trunk, _bark_mat)

	# Two angled boughs.
	var bough := SurfaceTool.new()
	bough.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in 3:
		var ang := TAU * float(b) / 3.0 + 0.7
		var dir := Vector3(cos(ang), 0, sin(ang))
		var base := dir * 0.15 + Vector3(0, h * 0.42, 0)
		var tip := dir * h * 0.20 + Vector3(0, h * 0.66, 0)
		_branch(bough, base, tip, 0.14)
	_add_surface(am, bough, _bark_mat)

	var fol := SurfaceTool.new()
	fol.begin(Mesh.PRIMITIVE_TRIANGLES)
	_rng.seed = 3391 + variant * 77
	var crown_y := h * 0.74
	var radius := h * 0.34
	for i in 16:
		var ang := _rng.randf_range(0, TAU)
		var elev := _rng.randf_range(-0.5, 1.0)
		var pos := Vector3(cos(ang) * radius * _rng.randf_range(0.15, 0.95),
			crown_y + elev * radius * 0.55,
			sin(ang) * radius * _rng.randf_range(0.15, 0.95))
		var dir := Vector3(cos(ang), _rng.randf_range(-0.2, 0.35), sin(ang))
		var basis := _card_basis(dir, _rng.randf_range(-0.7, 0.2))
		var shade := _rng.randf_range(0.62, 1.0)
		var size := Vector2(radius * _rng.randf_range(1.1, 1.8), radius * _rng.randf_range(0.9, 1.4))
		_card(fol, pos, size, basis, Color(shade * 0.9, shade, shade * 0.72))
	_add_surface(am, fol, _leaf_mat)
	return am


func _branch(st: SurfaceTool, a: Vector3, b: Vector3, r: float) -> void:
	var dir := (b - a).normalized()
	var up := Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT
	var side := dir.cross(up).normalized()
	var other := dir.cross(side).normalized()
	var seg := 5
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var d0 := side * cos(a0) + other * sin(a0)
		var d1 := side * cos(a1) + other * sin(a1)
		var p0 := a + d0 * r
		var p1 := a + d1 * r
		var p2 := b + d1 * r * 0.35
		var p3 := b + d0 * r * 0.35
		for v in [[p0, d0], [p1, d1], [p2, d1], [p0, d0], [p2, d1], [p3, d0]]:
			st.set_normal(v[1])
			st.set_uv(Vector2(0, 0))
			st.add_vertex(v[0])


func _build_snag() -> ArrayMesh:
	var am := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_trunk(st, 9.0, 0.42, 0.06, Vector2(1.2, 0.4), 7, 5)
	for i in 4:
		var ang := TAU * float(i) / 4.0 + 0.4
		var base := Vector3(0, 3.6 + i * 1.1, 0)
		var tip := base + Vector3(cos(ang), 0.8, sin(ang)) * 2.4
		_branch(st, base, tip, 0.13)
	_add_surface(am, st, _bark_mat)
	return am


func _build_bush() -> ArrayMesh:
	var am := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_rng.seed = 5150
	for i in 9:
		var ang := _rng.randf_range(0, TAU)
		var dir := Vector3(cos(ang), 0, sin(ang))
		var pos := dir * _rng.randf_range(0.1, 0.65) + Vector3(0, _rng.randf_range(0.35, 1.0), 0)
		var basis := _card_basis(dir, _rng.randf_range(-0.8, 0.3))
		var shade := _rng.randf_range(0.55, 0.95)
		_card(st, pos, Vector2(_rng.randf_range(0.9, 1.6), _rng.randf_range(0.7, 1.1)),
			basis, Color(shade * 0.86, shade, shade * 0.7))
	_add_surface(am, st, _leaf_mat)
	return am


func _build_grass_card() -> ArrayMesh:
	var am := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_rng.seed = 9091
	for i in 3:
		var ang := PI * float(i) / 3.0
		var basis := Basis(Vector3.UP, ang) * Basis(Vector3.RIGHT, -PI * 0.5)
		_card(st, Vector3(0, 0.34, 0), Vector2(0.95, 0.68), basis, Color(1, 1, 1))
	_add_surface(am, st, _grass_mat)
	return am


func _build_fern_card() -> ArrayMesh:
	var am := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_rng.seed = 4242
	for i in 4:
		var ang := TAU * float(i) / 4.0
		var basis := Basis(Vector3.UP, ang) * Basis(Vector3.RIGHT, -PI * 0.5)
		_card(st, Vector3(0, 0.42, 0), Vector2(1.25, 0.85), basis,
			Color(0.75, 0.95, 0.7))
	_add_surface(am, st, _leaf_mat)
	return am


func _build_rock(scale: float, seed_base: int) -> ArrayMesh:
	var am := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_rng.seed = seed_base * 977
	var segs := 12
	var rings := 8
	var radius := scale
	var verts := []
	for r in rings + 1:
		var v := float(r) / float(rings)
		var phi := v * PI
		var row := []
		for s in segs:
			var theta := TAU * float(s) / float(segs)
			var n := Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
			var lump := 1.0 + sin(n.x * 4.1 + 1.2) * 0.16 + sin(n.y * 6.3 + 0.4) * 0.12 \
				+ sin(n.z * 5.2 + 2.1) * 0.14 + _rng.randf_range(-0.06, 0.06)
			var p := n * radius * lump
			p.y *= 0.72
			p.x *= 1.0 + (0.25 if seed_base % 2 == 0 else 0.0)
			row.append(p)
		verts.append(row)
	for r in rings:
		for s in segs:
			var s2 := (s + 1) % segs
			var a: Vector3 = verts[r][s]
			var b: Vector3 = verts[r][s2]
			var c: Vector3 = verts[r + 1][s2]
			var d: Vector3 = verts[r + 1][s]
			for tri in [[a, b, c], [a, c, d]]:
				var n: Vector3 = ((tri[1] - tri[0]).cross(tri[2] - tri[0])).normalized()
				if n.y < 0:
					n = -n
				for p: Vector3 in tri:
					st.set_normal(n)
					st.set_uv(Vector2(p.x, p.z) * 0.5)
					st.add_vertex(p)
	_add_surface(am, st, _rock_mat)
	return am


func _build_conifer_far(height: float) -> ArrayMesh:
	# Far LOD retains a full tapered crown, but uses fewer tiers and boughs.
	var am := ArrayMesh.new()
	var trunk := SurfaceTool.new()
	trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	_trunk(trunk, height * 0.94, 0.34, 0.06, Vector2.ZERO, 6, 4)
	_add_surface(am, trunk, _bark_mat)
	var branches := SurfaceTool.new()
	branches.begin(Mesh.PRIMITIVE_TRIANGLES)
	var foliage := SurfaceTool.new()
	foliage.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tier in 6:
		var t := 0.20 + 0.72 * float(tier) / 5.0
		var y := t * height
		var radius := pow(1.0 - t, 0.84) * height * 0.30 + 0.18
		for c in 5:
			var ang := TAU * (float(c) / 5.0 + float(tier) * 0.19)
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			var tip := dir * radius * 0.92 + Vector3(0.0, radius * 0.1, 0.0)
			_branch(branches, Vector3(0.0, y, 0.0), tip, 0.055)
			var size := Vector2(maxf(0.5, radius * 0.72), maxf(0.28, radius * 0.38))
			_card(foliage, tip, size, _card_basis(dir, -0.15),
				Color(0.58, 0.76, 0.60))
	_add_surface(am, branches, _bark_mat)
	_add_surface(am, foliage, _conifer_mat)
	return am

func _build_broadleaf_far(variant: int) -> ArrayMesh:
	var am := ArrayMesh.new()
	var h := 7.5 + variant * 2.4
	var trunk := SurfaceTool.new()
	trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	_trunk(trunk, h * 0.6, 0.38, 0.13, Vector2(0.4, -0.3), 5, 3)
	_add_surface(am, trunk, _bark_mat)
	var fol := SurfaceTool.new()
	fol.begin(Mesh.PRIMITIVE_TRIANGLES)
	_rng.seed = 6607 + variant * 53
	var crown_y := h * 0.74
	var radius := h * 0.34
	for i in 7:
		var ang := _rng.randf_range(0, TAU)
		var elev := _rng.randf_range(-0.4, 1.0)
		var pos := Vector3(cos(ang) * radius * _rng.randf_range(0.2, 0.9),
			crown_y + elev * radius * 0.5,
			sin(ang) * radius * _rng.randf_range(0.2, 0.9))
		var dir := Vector3(cos(ang), _rng.randf_range(-0.2, 0.35), sin(ang))
		var basis := _card_basis(dir, _rng.randf_range(-0.7, 0.2))
		var shade := _rng.randf_range(0.62, 1.0)
		_card(fol, pos, Vector2(radius * _rng.randf_range(1.4, 2.0),
			radius * _rng.randf_range(1.1, 1.6)), basis,
			Color(shade * 0.9, shade, shade * 0.72))
	_add_surface(am, fol, _leaf_mat)
	return am


# ---------------------------------------------------------------------------
# Quality / LOD settings
# ---------------------------------------------------------------------------
const TREE_LAYERS := ["TreesA", "TreesB", "TreesC", "Broadleaf", "BroadleafB", "Snags"]
const CACHE_LIMIT := 140
## Mim radius per layer at the reference (Ultra) profile.
const LAYER_END := {
	"TreesA": 900.0, "TreesB": 900.0, "TreesC": 900.0, "Broadleaf": 900.0,
	"BroadleafB": 900.0, "Snags": 500.0, "Bushes": 260.0, "Grass": 120.0,
	"Ferns": 150.0, "Rocks": 520.0, "Pebbles": 200.0, "PHAFern": 120.0,
	"PHWeed": 100.0, "PHNettle": 90.0, "PHRooibos": 180.0, "PHTrunk": 240.0,
	"PHStones": 200.0,
}

var _cache: Dictionary = {}
var _cache_order: Array[Vector2i] = []
var _veg_scale := 1.0
var _tree_end := 900.0
var _tree_lod := 260.0
var _mobile_mode := false
var _pads: Array = []


func set_quality(profile: Dictionary) -> void:
	_veg_scale = float(profile.get("vegetation_scale", 1.0))
	_tree_end = float(profile.get("tree_end", 900.0))
	_tree_lod = float(profile.get("tree_lod", 260.0))


func _end_for(layer: String) -> float:
	var base: float = LAYER_END.get(layer, 150.0)
	if TREE_LAYERS.has(layer):
		return base * (_tree_end / 900.0)
	return base * _veg_scale


func _casts_shadows(layer: String) -> bool:
	if TREE_LAYERS.has(layer):
		return not _mobile_mode
	return layer == "Rocks" or layer == "PHRooibos" or layer == "PHTrunk" or layer == "PHStones"


# ---------------------------------------------------------------------------
# Scatter (cached per chunk)
# ---------------------------------------------------------------------------
func scatter_chunk(chunk: Node3D, coord: Vector2i) -> void:
	var entry = _cache.get(coord)
	if entry == null:
		entry = _generate_chunk(chunk, coord)
		_cache[coord] = entry
		_cache_order.append(coord)
		while _cache_order.size() > CACHE_LIMIT:
			var old: Vector2i = _cache_order.pop_front()
			_cache.erase(old)
	_instantiate(chunk, entry)


## Applies the tree LOD and refreshed visibility ranges to a chunk.
func apply_lod(chunk: Node3D, distance: float) -> void:
	var nodes = chunk.get_meta("veg_nodes", null)
	if nodes == null:
		return
	var entry = chunk.get_meta("veg_entry", null)
	var far: bool = distance > _tree_lod
	for layer in nodes.keys():
		var mmi: MultiMeshInstance3D = nodes[layer]
		var end := _end_for(layer)
		mmi.visibility_range_end = end
		mmi.visibility_range_end_margin = end * 0.12
		if not TREE_LAYERS.has(layer) or entry == null:
			continue
		if far:
			var far_mm = entry["mm_far"].get(layer)
			if far_mm == null:
				far_mm = _multimesh(entry["far_meshes"][layer], entry["layers"][layer])
				entry["mm_far"][layer] = far_mm
			mmi.multimesh = far_mm
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			var near_mm = entry["mm_near"].get(layer)
			if near_mm != null:
				mmi.multimesh = near_mm
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _casts_shadows(layer) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _multimesh(mesh: ArrayMesh, transforms: Array) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	return mm


func _instantiate(chunk: Node3D, entry: Dictionary) -> void:
	var nodes := {}
	var near_mm := {}
	for layer in entry["layers"].keys():
		var xf: Array = entry["layers"][layer]
		if xf.is_empty():
			continue
		var mm := _multimesh(entry["meshes"][layer], xf)
		near_mm[layer] = mm
		var mmi := MultiMeshInstance3D.new()
		mmi.name = layer
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if _casts_shadows(layer) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var end := _end_for(layer)
		mmi.visibility_range_end = end
		mmi.visibility_range_end_margin = end * 0.12
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		chunk.add_child(mmi)
		nodes[layer] = mmi
	entry["mm_near"] = near_mm
	chunk.set_meta("veg_nodes", nodes)
	chunk.set_meta("veg_entry", entry)


func _generate_chunk(chunk: Node3D, coord: Vector2i) -> Dictionary:
	_rng.seed = int(hash(Vector2i(coord.x, coord.y))) ^ Config.SEED
	var ox := float(coord.x) * Config.CHUNK_SIZE - Config.WORLD_HALF
	var oz := float(coord.y) * Config.CHUNK_SIZE - Config.WORLD_HALF
	var layers := {}
	for layer in LAYER_END.keys():
		layers[layer] = []
	var bushes: Array = layers["Bushes"]
	var grass: Array = layers["Grass"]
	var ferns: Array = layers["Ferns"]
	var rocks: Array = layers["Rocks"]
	var pebbles: Array = layers["Pebbles"]
	var asset_fern: Array = layers["PHAFern"]
	var asset_weed: Array = layers["PHWeed"]
	var asset_nettle: Array = layers["PHNettle"]
	var asset_rooibos: Array = layers["PHRooibos"]
	var asset_trunk: Array = layers["PHTrunk"]
	var asset_stones: Array = layers["PHStones"]

	if _pads.is_empty():
		_pads = [
			[Config.VILLAGE_CENTER, 112.0 if _mobile_mode else 150.0],
			[Config.CASTLE_CENTER, 105.0],
			[Config.HAMLET_CENTER, 80.0],
			[Config.RUINS_SITE, 70.0],
			[Config.VILLAGE_CENTER + Vector2(24, 190), 92.0 if _mobile_mode else 110.0],
			# House footprints (each lot has a conservative 13-16 m tree-free apron).
			[Vector2(-224, 148), 14.0], [Vector2(-224, 182), 13.0],
			[Vector2(-222, 296), 15.0], [Vector2(-224, 330), 14.0],
			[Vector2(-170, 166), 15.0], [Vector2(-168, 200), 13.0],
			[Vector2(-170, 306), 14.0], [Vector2(-168, 340), 13.0],
			[Vector2(-262, 172), 14.0], [Vector2(-260, 252), 14.0],
			[Vector2(-262, 316), 13.0], [Vector2(-136, 186), 14.0],
			[Vector2(-134, 262), 15.0], [Vector2(-136, 320), 13.0],
			[Vector2(-300, 226), 14.0],
		]

	var candidates := 260
	for i in candidates:
		var lx := _rng.randf() * Config.CHUNK_SIZE
		var lz := _rng.randf() * Config.CHUNK_SIZE
		var wx := ox + lx
		var wz := oz + lz
		var h: float = chunk.sample_height(wx, wz)
		var water_info: Vector3 = field.river_info(wx, wz)
		var water := water_info.x
		var river_w := water_info.z
		var road: float = field.distance_to_road(wx, wz)

		var water_clear: float = river_w * 0.5 + 5.0
		if water < water_clear or road < 4.5:
			# Still allow shoreline rocks and pebbles in the wet band.
			if water < water_clear and water > river_w * 0.5 - 1.0 \
					and chunk.slope_at(wx, wz) < 0.5:
				if _rng.randf() < 0.35:
					rocks.append(_xform(Vector3(wx, h, wz), _rng.randf_range(0.5, 1.4), _rng.randf() * TAU))
			continue
		var slope: float = chunk.slope_at(wx, wz)
		if slope > 0.62:
			continue

		var forest := _forest_density(wx, wz, water, river_w)
		var meadow := _meadow_density(forest)
		var in_pad := _near_pad(wx, wz)

		if not in_pad and _rng.randf() < forest:
			var conifer_bias := _conifer_bias(wx, wz, h)
			var roll := _rng.randf()
			var species := "TreesA"
			if roll > conifer_bias:
				species = "Broadleaf" if _rng.randf() < 0.6 else "BroadleafB"
			elif roll < 0.16:
				species = "TreesB"
			elif roll < 0.34:
				species = "TreesC"
			var scale := _rng.randf_range(0.72, 1.35)
			var xf := _xform(Vector3(wx, h - 0.12, wz), scale, _rng.randf() * TAU)
			(layers[species] as Array).append(xf)
			# A second tree just behind the first thickens the canopy.
			if _rng.randf() < 0.38:
				var wx2 := wx + _rng.randf_range(-3.5, 3.5)
				var wz2 := wz + _rng.randf_range(-3.5, 3.5)
				var water2: Vector3 = field.river_info(wx2, wz2)
				var clear2 := water2.z * 0.5 + 6.0
				if not _near_pad(wx2, wz2) and field.distance_to_road(wx2, wz2) > 5.0 \
						and water2.x > clear2:
					var h2: float = chunk.sample_height(wx2, wz2)
					(layers[species] as Array).append(
						_xform(Vector3(wx2, h2 - 0.12, wz2), _rng.randf_range(0.65, 1.1), _rng.randf() * TAU))
			if slope > 0.45 and _rng.randf() < 0.10:
				(layers["Snags"] as Array).append(_xform(Vector3(wx, h, wz), 1.0, _rng.randf() * TAU))

		if _rng.randf() < meadow * 0.85:
			if _rng.randf() < 0.82:
				grass.append(_xform(Vector3(wx, h - 0.05, wz), _rng.randf_range(0.7, 1.5),
					_rng.randf() * TAU))
			else:
				ferns.append(_xform(Vector3(wx, h - 0.1, wz), _rng.randf_range(0.6, 1.3),
					_rng.randf() * TAU))
		if _rng.randf() < forest * 0.4:
			bushes.append(_xform(Vector3(wx, h - 0.15, wz), _rng.randf_range(0.7, 1.6),
				_rng.randf() * TAU))
		if _rng.randf() < 0.08 and slope < 0.55:
			rocks.append(_xform(Vector3(wx, h - 0.25, wz), _rng.randf_range(0.7, 2.2),
				_rng.randf() * TAU))
		if _rng.randf() < 0.14:
			pebbles.append(_xform(Vector3(wx, h - 0.08, wz), _rng.randf_range(0.6, 1.6),
				_rng.randf() * TAU))

		# Poly Haven undergrowth, only where it fits the biome.
		if forest > 0.35 and _rng.randf() < 0.16:
			asset_fern.append(_xform(Vector3(wx, h - 0.02, wz), _rng.randf_range(0.8, 1.4),
				_rng.randf() * TAU))
		if meadow > 0.45 and _rng.randf() < 0.12:
			asset_weed.append(_xform(Vector3(wx, h - 0.02, wz), _rng.randf_range(0.8, 1.5),
				_rng.randf() * TAU))
		if water < river_w * 0.5 + 14.0 and _rng.randf() < 0.30:
			asset_nettle.append(_xform(Vector3(wx, h - 0.02, wz), _rng.randf_range(0.7, 1.3),
				_rng.randf() * TAU))
		if h > 90.0 and slope < 0.45 and _rng.randf() < 0.10:
			asset_rooibos.append(_xform(Vector3(wx, h - 0.02, wz), _rng.randf_range(0.8, 1.5),
				_rng.randf() * TAU))
		if forest > 0.2 and forest < 0.55 and _rng.randf() < 0.04:
			asset_trunk.append(_xform(Vector3(wx, h - 0.15, wz), _rng.randf_range(0.7, 1.2),
				_rng.randf() * TAU))
		if slope > 0.25 and _rng.randf() < 0.05:
			asset_stones.append(_xform(Vector3(wx, h - 0.1, wz), _rng.randf_range(0.6, 1.4),
				_rng.randf() * TAU))

	stats["trees"] += _count_layers(layers, TREE_LAYERS)
	stats["grass"] += layers["Grass"].size() + layers["Ferns"].size()
	stats["rocks"] += layers["Rocks"].size() + layers["Pebbles"].size()
	stats["chunks"] += 1

	var meshes_for := {
		"TreesA": meshes["conifer_a"], "TreesB": meshes["conifer_b"],
		"TreesC": meshes["conifer_c"], "Broadleaf": meshes["broadleaf"],
		"BroadleafB": meshes["broadleaf_b"], "Snags": meshes["snag"],
		"Bushes": meshes["bush"], "Grass": meshes["grass"], "Ferns": meshes["fern"],
		"Rocks": meshes["rock_a"], "Pebbles": meshes["pebble"],
		"PHAFern": _asset_meshes.get("fern"), "PHWeed": _asset_meshes.get("weed"),
		"PHNettle": _asset_meshes.get("nettle"), "PHRooibos": _asset_meshes.get("rooibos"),
		"PHTrunk": _asset_meshes.get("trunk"), "PHStones": _asset_meshes.get("stones"),
	}
	var far_meshes := {
		"TreesA": meshes["conifer_a_far"], "TreesB": meshes["conifer_b_far"],
		"TreesC": meshes["conifer_c_far"], "Broadleaf": meshes["broadleaf_far"],
		"BroadleafB": meshes["broadleaf_b_far"], "Snags": meshes["snag"],
	}
	# Drop layers whose mesh failed to load so instantiation stays simple.
	for layer in layers.keys():
		if meshes_for.get(layer) == null or (layers[layer] as Array).is_empty():
			layers.erase(layer)
	return {
		"layers": layers,
		"meshes": meshes_for,
		"far_meshes": far_meshes,
		"mm_near": {},
		"mm_far": {},
	}


func _count_layers(layers: Dictionary, names: Array) -> int:
	var n := 0
	for layer in names:
		n += (layers[layer] as Array).size()
	return n


func _count(dict: Dictionary) -> int:
	var n := 0
	for k in dict.keys():
		n += (dict[k] as Array).size()
	return n


func _xform(pos: Vector3, scale: float, yaw: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale)), pos)


func _forest_density(wx: float, wz: float, water: float, river_w: float) -> float:
	var west := Terrain.smooth01(-120.0, -520.0, wx)
	var north := Terrain.smooth01(-280.0, -720.0, wz)
	var east := Terrain.smooth01(520.0, 860.0, wx) * 0.55
	var valley_copse := Terrain.smooth01(0.18, 0.55, _patch_noise(wx, wz))
	var south := Terrain.smooth01(520.0, 900.0, wz) * 0.25
	var density := maxf(maxf(west, north), maxf(east, valley_copse * 0.7))
	density = maxf(density, south)
	# Clearings and fields break the forest up.
	density *= 1.0 - Terrain.smooth01(0.48, 0.78, _patch_noise(wx + 311.0, wz - 97.0)) * 0.8
	if water < river_w * 0.5 + 8.0:
		density *= 0.25
	return clampf(density, 0.0, 1.0) * 0.85


func _meadow_density(forest: float) -> float:
	var open := 1.0 - forest * 0.75
	return clampf(open, 0.0, 1.0)


func _conifer_bias(wx: float, wz: float, h: float) -> float:
	var north := Terrain.smooth01(-100.0, -650.0, wz)
	var west := Terrain.smooth01(-100.0, -450.0, wx) * 0.7
	var height_bias := Terrain.smooth01(25.0, 110.0, h)
	var south := Terrain.smooth01(300.0, 800.0, wz)
	return clampf(0.35 + north * 0.55 + west * 0.3 + height_bias * 0.4 - south * 0.5, 0.05, 0.98)


func _patch_noise(x: float, z: float) -> float:
	return (sin(x * 0.0113) * cos(z * 0.0137) + sin(x * 0.0041 + 1.7) * cos(z * 0.0053 - 0.6)) * 0.25 + 0.5


func _near_pad(wx: float, wz: float) -> bool:
	for pad in _pads:
		var c: Vector2 = pad[0]
		var dx := wx - c.x
		var dz := wz - c.y
		if dx * dx + dz * dz < float(pad[1]) * float(pad[1]):
			return true
	return false
