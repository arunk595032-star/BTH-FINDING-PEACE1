extends RefCounted
## Builds the river network, lake, ponds and waterfalls.
##
## Rivers are ribbon meshes that follow the authored water level of each
## centreline point, so a river genuinely descends through the valley.  Where
## the level drops sharply the ribbon is split and a vertical waterfall sheet
## plus mist is inserted instead of a stretched quad.

const Config = preload("res://scripts/core/world_config.gd")
const WATER_SHADER := "res://shaders/water.gdshader"
const WATERFALL_SHADER := "res://shaders/waterfall.gdshader"
const RIPPLE_TEX := "res://assets/textures/procedural/water/ripple_nrm.png"
const STREAK_TEX := "res://assets/textures/procedural/water/water_streak.png"

var field
var material: ShaderMaterial
var waterfall_material: ShaderMaterial
var waterfalls: Array = []
var _river_index := 0
var _waterfall_index := 0
var stats := {"river_km": 0.0, "waterfalls": 0, "lake": false}


func setup(p_field: RefCounted) -> void:
	field = p_field
	material = ShaderMaterial.new()
	material.shader = load(WATER_SHADER)
	if ResourceLoader.exists(RIPPLE_TEX):
		material.set_shader_parameter("ripple_tex", load(RIPPLE_TEX))
	if ResourceLoader.exists("res://assets/hdri/belfast_sunset_puresky_2k.hdr"):
		material.set_shader_parameter("sky_equirect",
			load("res://assets/hdri/belfast_sunset_puresky_2k.hdr"))
	waterfall_material = ShaderMaterial.new()
	waterfall_material.shader = load(WATERFALL_SHADER)
	if ResourceLoader.exists(STREAK_TEX):
		waterfall_material.set_shader_parameter("streak_tex", load(STREAK_TEX))


func build(parent: Node3D) -> void:
	var root := Node3D.new()
	root.name = "Water"
	parent.add_child(root)
	for path in field.water_paths:
		_build_water_path(root, path)
	_build_lake(root)
	for wf in waterfalls:
		_build_waterfall(root, wf)


# ---------------------------------------------------------------------------
# River ribbons
# ---------------------------------------------------------------------------
func _catmull(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


func _build_water_path(root: Node3D, path: Dictionary) -> void:
	var pts: PackedVector2Array = path["points"]
	var levels: PackedFloat32Array = path["levels"]
	var widths: PackedFloat32Array = path["widths"]
	if pts.size() < 2:
		return

	# Walk the authored polyline segment by segment.  A segment that drops
	# steeply becomes a waterfall instead of a stretched ribbon quad.
	var current: Array = []
	for seg in pts.size() - 1:
		var a := pts[seg]
		var b := pts[seg + 1]
		var drop: float = levels[seg] - levels[seg + 1]
		var dist: float = maxf(a.distance_to(b), 0.001)
		var steep: bool = drop > 6.0 and drop / dist > 0.32
		if steep:
			if current.size() > 1:
				_commit_ribbon(root, current)
			current = []
			waterfalls.append({
				"pos": (a + b) * 0.5,
				"top": levels[seg],
				"bottom": levels[seg + 1],
				"width": (widths[seg] + widths[seg + 1]) * 0.5,
				"dir": (b - a).normalized(),
			})
			stats["river_km"] += dist / 1000.0
			continue

		var p0 := pts[maxi(seg - 1, 0)]
		var p3 := pts[mini(seg + 2, pts.size() - 1)]
		var steps := 10
		for s in steps:
			if s == 0 and not current.is_empty():
				continue
			var t := float(s) / float(steps)
			current.append({
				"p": _catmull(p0, a, b, p3, t),
				"level": lerpf(levels[seg], levels[seg + 1], t),
				"width": lerpf(widths[seg], widths[seg + 1], t),
			})
		stats["river_km"] += dist / 1000.0
	if current.size() > 1:
		current.append({
			"p": pts[pts.size() - 1],
			"level": levels[levels.size() - 1],
			"width": widths[widths.size() - 1],
		})
		_commit_ribbon(root, current)


func _path_length(samples: Array) -> float:
	var total := 0.0
	for i in samples.size() - 1:
		total += (samples[i]["p"] as Vector2).distance_to(samples[i + 1]["p"])
	return total


func _commit_ribbon(root: Node3D, samples: Array) -> void:
	if samples.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var accum := 0.0
	var prev_left := Vector3.ZERO
	var prev_right := Vector3.ZERO
	var prev_v := 0.0
	for i in samples.size():
		var s: Dictionary = samples[i]
		var p: Vector2 = s["p"]
		var level: float = s["level"]
		var width: float = s["width"]
		var tangent: Vector2
		if i == 0:
			tangent = (samples[1]["p"] as Vector2) - p
		elif i == samples.size() - 1:
			tangent = p - (samples[i - 1]["p"] as Vector2)
		else:
			tangent = (samples[i + 1]["p"] as Vector2) - (samples[i - 1]["p"] as Vector2)
		if tangent.length() < 0.001:
			tangent = Vector2(0, 1)
		tangent = tangent.normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		if i > 0:
			accum += p.distance_to(samples[i - 1]["p"])
		var half := width * 0.5 + 0.4
		var left := Vector3(p.x + normal.x * half, level, p.y + normal.y * half)
		var right := Vector3(p.x - normal.x * half, level, p.y - normal.y * half)
		var v := accum / 12.0
		if i > 0:
			var flow_col := Color(tangent.x * 0.5 + 0.5, tangent.y * 0.5 + 0.5, 0.0)
			for vert in [[prev_left, Vector2(0, prev_v), flow_col], [prev_right, Vector2(1, prev_v), flow_col],
					[right, Vector2(1, v), flow_col], [prev_left, Vector2(0, prev_v), flow_col],
					[right, Vector2(1, v), flow_col], [left, Vector2(0, v), flow_col]]:
				st.set_normal(Vector3.UP)
				st.set_uv(vert[1])
				st.set_color(vert[2])
				st.add_vertex(vert[0])
		prev_left = left
		prev_right = right
		prev_v = v

	var mesh := st.commit()
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "River_%d" % _river_index
	_river_index += 1
	mi.mesh = mesh
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 4.0
	root.add_child(mi)


# ---------------------------------------------------------------------------
# Lake and ponds
# ---------------------------------------------------------------------------
func _build_lake(root: Node3D) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3(6.0, 5.05, 966.0)
	var radius := 186.0
	var segs := 72
	var prev := Vector3.ZERO
	var flow_col := Color(0.5, 1.0, 0.0)
	for i in segs + 1:
		var a := TAU * float(i) / float(segs)
		var p := center + Vector3(cos(a) * radius, 0, sin(a) * radius)
		if i > 0:
			for v in [[center, Vector2(0.5, 0.5)], [prev, Vector2(0.5 + cos(a - TAU / segs) * 0.5, 0.5 + sin(a - TAU / segs) * 0.5)],
					[p, Vector2(0.5 + cos(a) * 0.5, 0.5 + sin(a) * 0.5)]]:
				st.set_normal(Vector3.UP)
				st.set_uv(v[1])
				st.set_color(flow_col)
				st.add_vertex(v[0])
		prev = p
	var mesh := st.commit()
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "SilverwaterLake"
	mi.mesh = mesh
	mi.material_override = material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	stats["lake"] = true

	# Pool at the waterfall base.
	var pond := MeshInstance3D.new()
	pond.name = "WaterfallPool"
	var sphere := SphereMesh.new()
	sphere.radius = 26.0
	sphere.height = 2.0
	sphere.radial_segments = 32
	sphere.rings = 6
	pond.mesh = sphere
	pond.scale = Vector3(1.0, 0.04, 1.0)
	pond.position = Vector3(Config.WATERFALL_SITE.x + 4.0, 25.4, Config.WATERFALL_SITE.y + 6.0)
	pond.material_override = material
	pond.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(pond)


# ---------------------------------------------------------------------------
# Waterfalls
# ---------------------------------------------------------------------------
func _build_waterfall(root: Node3D, wf: Dictionary) -> void:
	var pos: Vector2 = wf["pos"]
	var top: float = wf["top"]
	var bottom: float = wf["bottom"]
	var width: float = wf["width"]
	var dir: Vector2 = wf["dir"]
	var normal := Vector2(-dir.y, dir.x)
	var height := top - bottom
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cols := 8
	var rows := 12
	var verts: Array = []
	for r in rows + 1:
		var v := float(r) / float(rows)
		var row: Array = []
		for c in cols + 1:
			var u := float(c) / float(cols)
			var across := (u - 0.5) * width
			var bulge := sin(v * PI) * 1.4 * (0.35 + 0.65 * absf(u - 0.5))
			var xz := pos + normal * across + dir * bulge
			var y := lerpf(top, bottom, v) + sin(v * PI) * 0.6
			row.append(Vector3(xz.x, y, xz.y))
		verts.append(row)
	for r in rows:
		for c in cols:
			var a: Vector3 = verts[r][c]
			var b: Vector3 = verts[r][c + 1]
			var cc: Vector3 = verts[r + 1][c + 1]
			var d: Vector3 = verts[r + 1][c]
			var uv0 := Vector2(float(c) / cols, float(r) / rows)
			var uv1 := Vector2(float(c + 1) / cols, float(r) / rows)
			var uv2 := Vector2(float(c + 1) / cols, float(r + 1) / rows)
			var uv3 := Vector2(float(c) / cols, float(r + 1) / rows)
			for v in [[a, uv0], [b, uv1], [cc, uv2], [a, uv0], [cc, uv2], [d, uv3]]:
				st.set_normal(Vector3(-dir.x, 0, -dir.y))
				st.set_uv(v[1])
				st.add_vertex(v[0])
	var mesh := st.commit()
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "Waterfall_%d" % _waterfall_index
	_waterfall_index += 1
	mi.mesh = mesh
	mi.material_override = waterfall_material
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)

	# Mist at the plunge pool.
	var mist := CPUParticles3D.new()
	mist.name = "WaterfallMist"
	mist.amount = 90
	mist.lifetime = 3.2
	mist.position = Vector3(pos.x + dir.x * 2.0, bottom + 1.0, pos.y + dir.y * 2.0)
	mist.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	mist.emission_sphere_radius = width * 0.55
	mist.direction = Vector3(0, 1, 0)
	mist.spread = 55.0
	mist.gravity = Vector3(0, -1.6, 0)
	mist.initial_velocity_min = 1.2
	mist.initial_velocity_max = 3.6
	mist.scale_amount_min = 1.0
	mist.scale_amount_max = 3.0
	var quad := QuadMesh.new()
	quad.size = Vector2(2.4, 2.4)
	var mmat := StandardMaterial3D.new()
	mmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mmat.albedo_color = Color(0.92, 0.95, 0.96, 0.16)
	quad.material = mmat
	mist.mesh = quad
	root.add_child(mist)
	stats["waterfalls"] += 1
