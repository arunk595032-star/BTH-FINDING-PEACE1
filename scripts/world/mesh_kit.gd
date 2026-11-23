extends RefCounted
## Small procedural mesh toolkit used for terrain, water, buildings and props.
##
## Geometry is accumulated per material so a whole village or castle is a
## handful of draw calls instead of hundreds of separate box meshes.

var _surfaces: Dictionary = {}      # key -> SurfaceTool
var _materials: Dictionary = {}     # key -> Material
var box_colliders: Array = []       # {transform: Transform3D, size: Vector3}


func _st(key: String, mat: Material) -> SurfaceTool:
	if not _surfaces.has(key):
		var s := SurfaceTool.new()
		s.begin(Mesh.PRIMITIVE_TRIANGLES)
		_surfaces[key] = s
		_materials[key] = mat
	return _surfaces[key]


static func _uv_size(a: Vector3, b: Vector3, uv_per_m: float) -> Vector2:
	return Vector2(maxf(a.distance_to(b), 0.001), maxf(a.distance_to(b), 0.001)) * uv_per_m


func add_quad(key: String, mat: Material, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		uv_scale := 1.0) -> void:
	var s := _st(key, mat)
	var n := (b - a).cross(c - a).normalized()
	var width := a.distance_to(b) * uv_scale
	var height := a.distance_to(d) * uv_scale
	s.set_normal(n)
	s.set_uv(Vector2(0, height))
	s.add_vertex(a)
	s.set_uv(Vector2(width, height))
	s.add_vertex(b)
	s.set_uv(Vector2(width, 0))
	s.add_vertex(c)
	s.set_uv(Vector2(0, 0))
	s.add_vertex(d)
	# The quad is stored as a strip triangle pair.
	s.set_normal(n)
	s.set_uv(Vector2(0, height))
	s.add_vertex(a)
	s.set_uv(Vector2(width, 0))
	s.add_vertex(c)
	s.set_uv(Vector2(0, 0))
	s.add_vertex(d)


func add_box(key: String, mat: Material, xform: Transform3D, size: Vector3,
		uv_per_m := 0.6, collide := true) -> void:
	var s := _st(key, mat)
	var h := size * 0.5
	var faces := [
		[Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(0, 0, 1)],
		[Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(0, 0, -1)],
		[Vector3(h.x, -h.y, h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(1, 0, 0)],
		[Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, h.y, -h.z), Vector3(-1, 0, 0)],
		[Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(0, 1, 0)],
		[Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z), Vector3(0, -1, 0)],
	]
	for face in faces:
		var p0: Vector3 = xform * (face[0] as Vector3)
		var p1: Vector3 = xform * (face[1] as Vector3)
		var p2: Vector3 = xform * (face[2] as Vector3)
		var p3: Vector3 = xform * (face[3] as Vector3)
		var n: Vector3 = (xform.basis * (face[4] as Vector3)).normalized()
		var w: float = p0.distance_to(p1) * uv_per_m
		var ht: float = p0.distance_to(p3) * uv_per_m
		for v in [[p0, Vector2(0, ht)], [p1, Vector2(w, ht)], [p2, Vector2(w, 0)],
				[p0, Vector2(0, ht)], [p2, Vector2(w, 0)], [p3, Vector2(0, 0)]]:
			s.set_normal(n)
			s.set_uv(v[1])
			s.add_vertex(v[0])
	if collide:
		box_colliders.append({"transform": xform, "size": size})


func add_cylinder(key: String, mat: Material, xform: Transform3D, radius: float,
		height: float, segments := 16, uv_per_m := 0.5, cap := true) -> void:
	var s := _st(key, mat)
	var half := height * 0.5
	for i in segments:
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var p0: Vector3 = xform * (d0 * radius + Vector3(0, -half, 0))
		var p1: Vector3 = xform * (d1 * radius + Vector3(0, -half, 0))
		var p2: Vector3 = xform * (d1 * radius + Vector3(0, half, 0))
		var p3: Vector3 = xform * (d0 * radius + Vector3(0, half, 0))
		var n0: Vector3 = (xform.basis * d0).normalized()
		var n1: Vector3 = (xform.basis * d1).normalized()
		var u0 := a0 * radius * uv_per_m
		var u1 := a1 * radius * uv_per_m
		var v1 := height * uv_per_m
		var verts := [[p0, n0, Vector2(u0, v1)], [p1, n1, Vector2(u1, v1)],
			[p2, n1, Vector2(u1, 0)], [p0, n0, Vector2(u0, v1)],
			[p2, n1, Vector2(u1, 0)], [p3, n0, Vector2(u0, 0)]]
		for v in verts:
			s.set_normal(v[1])
			s.set_uv(v[2])
			s.add_vertex(v[0])
		if cap:
			var top_n: Vector3 = (xform.basis * Vector3.UP).normalized()
			var bot_n: Vector3 = (xform.basis * Vector3.DOWN).normalized()
			var top_c: Vector3 = xform * Vector3(0, half, 0)
			var bot_c: Vector3 = xform * Vector3(0, -half, 0)
			for tri in [[p0, p1, top_c, top_n], [p2, p3, bot_c, bot_n]]:
				for pv in [tri[0], tri[1], tri[2]]:
					s.set_normal(tri[3])
					s.set_uv(Vector2(pv.x, pv.z) * uv_per_m)
					s.add_vertex(pv)


## Tapered cone (tower roofs, tents).
func add_cone(key: String, mat: Material, xform: Transform3D, radius: float,
		height: float, segments := 16, uv_per_m := 0.5) -> void:
	var s := _st(key, mat)
	var apex: Vector3 = xform * Vector3(0, height, 0)
	var base_y := -height * 0.5
	for i in segments:
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var p0: Vector3 = xform * (Vector3(cos(a0), 0, sin(a0)) * radius + Vector3(0, base_y, 0))
		var p1: Vector3 = xform * (Vector3(cos(a1), 0, sin(a1)) * radius + Vector3(0, base_y, 0))
		var n := ((p1 - p0).cross(apex - p0)).normalized()
		if n.y < 0.0:
			n = -n
		var mid := (p0 + p1) * 0.5
		for v in [[p0, Vector2(a0 * radius * uv_per_m, 0)], [p1, Vector2(a1 * radius * uv_per_m, 0)],
				[apex, Vector2((a0 + a1) * 0.5 * radius * uv_per_m, height * uv_per_m)]]:
			s.set_normal(n)
			s.set_uv(v[1])
			s.add_vertex(v[0])


## Gabled roof: ridge runs along local X, slopes fall toward +/- Z.
func add_gable_roof(key: String, mat: Material, xform: Transform3D, width: float,
		depth: float, rise: float, overhang := 0.5, uv_per_m := 0.6) -> void:
	var s := _st(key, mat)
	var hw := width * 0.5 + overhang
	var hd := depth * 0.5 + overhang
	var eave_y := -rise * 0.5
	var ridge_y := rise * 0.5
	var ridge_a := xform * Vector3(-hw, ridge_y, 0)
	var ridge_b := xform * Vector3(hw, ridge_y, 0)
	var front_a := xform * Vector3(-hw, eave_y, hd)
	var front_b := xform * Vector3(hw, eave_y, hd)
	var back_a := xform * Vector3(-hw, eave_y, -hd)
	var back_b := xform * Vector3(hw, eave_y, -hd)
	_quad_mesh(s, ridge_a, ridge_b, front_b, front_a, uv_per_m)
	_quad_mesh(s, back_b, back_a, ridge_a, ridge_b, uv_per_m)
	# Gable ends (triangles) close the roof volume.
	_gable_tri(s, front_a, front_b, xform * Vector3(0, ridge_y, 0), uv_per_m)
	_gable_tri(s, back_a, back_b, xform * Vector3(0, ridge_y, 0), uv_per_m)


func _gable_tri(s: SurfaceTool, a: Vector3, b: Vector3, apex: Vector3, uv_per_m: float) -> void:
	var n := (b - a).cross(apex - a).normalized()
	for v in [[a, Vector2(0, 0)], [b, Vector2(a.distance_to(b) * uv_per_m, 0)],
			[apex, Vector2(a.distance_to(b) * 0.5 * uv_per_m, a.distance_to(apex) * uv_per_m)]]:
		s.set_normal(n)
		s.set_uv(v[1])
		s.add_vertex(v[0])


func _quad_mesh(s: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		uv_per_m: float) -> void:
	var n := (b - a).cross(c - a).normalized()
	var w := a.distance_to(b) * uv_per_m
	var h := a.distance_to(d) * uv_per_m
	for v in [[a, Vector2(0, 0)], [b, Vector2(w, 0)], [c, Vector2(w, h)],
			[a, Vector2(0, 0)], [c, Vector2(w, h)], [d, Vector2(0, h)]]:
		s.set_normal(n)
		s.set_uv(v[1])
		s.add_vertex(v[0])


## Free-standing two-sided card, used for tree foliage and grass.
func add_card(s: SurfaceTool, center: Vector3, size: Vector2, basis: Basis,
		uv_rect := Rect2(0, 0, 1, 1), color := Color(1, 1, 1)) -> void:
	var right := basis.x.normalized() * size.x * 0.5
	var up := basis.y.normalized() * size.y * 0.5
	var n := basis.z.normalized()
	var a := center - right - up
	var b := center + right - up
	var c := center + right + up
	var d := center - right + up
	for v in [[a, Vector2(uv_rect.position.x, uv_rect.end.y)], [b, Vector2(uv_rect.end.x, uv_rect.end.y)],
			[c, Vector2(uv_rect.end.x, uv_rect.position.y)], [a, Vector2(uv_rect.position.x, uv_rect.end.y)],
			[c, Vector2(uv_rect.end.x, uv_rect.position.y)], [d, Vector2(uv_rect.position.x, uv_rect.position.y)]]:
		s.set_normal(n)
		s.set_uv(v[1])
		s.set_color(color)
		s.add_vertex(v[0])


func commit(parent: Node3D, shadows := true) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for key in _surfaces.keys():
		var s: SurfaceTool = _surfaces[key]
		s.index()
		s.generate_tangents()
		var mesh := s.commit()
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Mesh_" + str(key)
		mi.mesh = mesh
		mi.material_override = _materials[key]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		out.append(mi)
	return out


func build_collision(parent: Node3D) -> StaticBody3D:
	if box_colliders.is_empty():
		return null
	var body := StaticBody3D.new()
	body.name = "Collision"
	parent.add_child(body)
	for c in box_colliders:
		var shape := BoxShape3D.new()
		shape.size = c["size"]
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.transform = c["transform"]
		body.add_child(cs)
	return body


func merge_to_mesh() -> ArrayMesh:
	var out := ArrayMesh.new()
	for key in _surfaces.keys():
		var s: SurfaceTool = _surfaces[key]
		s.index()
		s.generate_tangents()
		var m := s.commit()
		if m == null:
			continue
		for i in m.get_surface_count():
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, m.surface_get_arrays(i))
			out.surface_set_material(out.get_surface_count() - 1, _materials[key])
	return out
