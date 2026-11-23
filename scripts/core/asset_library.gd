extends RefCounted
## Loads free CC0 models into engine meshes.
##
## Poly Haven ships glTF scenes with several mesh nodes; MultiMesh needs one
## ArrayMesh, so all surfaces are merged (preserving their materials and node
## transforms) and cached for the lifetime of the process.

static var _mesh_cache: Dictionary = {}


static func has_asset(path: String) -> bool:
	return ResourceLoader.exists(path)


## Returns { "mesh": ArrayMesh or null, "scale": float }.
static func load_mesh(path: String) -> ArrayMesh:
	if _mesh_cache.has(path):
		return _mesh_cache[path]
	if not ResourceLoader.exists(path):
		_mesh_cache[path] = null
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		_mesh_cache[path] = null
		return null
	var root := packed.instantiate()
	var out := ArrayMesh.new()
	_collect(root, Transform3D.IDENTITY, out)
	root.free()
	_mesh_cache[path] = out if out.get_surface_count() > 0 else null
	return _mesh_cache[path]


static func _collect(node: Node, xform: Transform3D, out: ArrayMesh) -> void:
	var child_xform := xform
	if node is Node3D:
		child_xform = xform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				var mats := mi.mesh.surface_get_material(s)
				if mats == null:
					mats = mi.material_override
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				st.append_from(mi.mesh, s, child_xform)
				st.index()
				var m := st.commit()
				if m == null:
					continue
				for k in m.get_surface_count():
					out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, m.surface_get_arrays(k))
					out.surface_set_material(out.get_surface_count() - 1, mats)
	for child in node.get_children():
		_collect(child, child_xform, out)


## Instanced single asset (with collision optional) for hero props.
static func spawn(parent: Node3D, path: String, xform: Transform3D,
		collision := false) -> Node3D:
	var mesh := load_mesh(path)
	var holder := Node3D.new()
	holder.transform = xform
	if mesh != null:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		holder.add_child(mi)
		if collision:
			var body := StaticBody3D.new()
			var cs := CollisionShape3D.new()
			var shape := ConvexPolygonShape3D.new()
			var pts := PackedVector3Array()
			var arrays := mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var stride := maxi(1, verts.size() / 400)
			for i in range(0, verts.size(), stride):
				pts.append(verts[i])
			if pts.size() >= 4:
				shape.points = pts
				cs.shape = shape
				body.add_child(cs)
				holder.add_child(body)
	parent.add_child(holder)
	return holder
