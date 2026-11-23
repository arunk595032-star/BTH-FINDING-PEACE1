extends Node3D
## One streamed 128 m terrain chunk: visual mesh + HeightMapShape3D collision.
## Chunks exist only while the player is near them, which keeps both draw
## calls and physics bodies bounded no matter how large the world becomes.

const Config = preload("res://scripts/core/world_config.gd")

var field
var coord := Vector2i.ZERO
var built := false
var triangles := 0

var _mesh_instance: MeshInstance3D
var _body: StaticBody3D
var _heights := PackedFloat32Array()
var _step := 1.0


func setup(p_field: RefCounted, p_coord: Vector2i) -> void:
	field = p_field
	coord = p_coord
	name = "Chunk_%d_%d" % [coord.x, coord.y]
	var ox := float(coord.x) * Config.CHUNK_SIZE - Config.WORLD_HALF
	var oz := float(coord.y) * Config.CHUNK_SIZE - Config.WORLD_HALF
	position = Vector3(ox, 0.0, oz)


func build(material: Material) -> void:
	if built:
		return
	built = true
	var segs := Config.CHUNK_SEGMENTS
	var step := Config.CHUNK_SIZE / float(segs)
	var ox := float(coord.x) * Config.CHUNK_SIZE - Config.WORLD_HALF
	var oz := float(coord.y) * Config.CHUNK_SIZE - Config.WORLD_HALF

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_step = step

	# Heights cached on a (segs+1)^2 lattice, used by both mesh and collision.
	var heights := PackedFloat32Array()
	heights.resize((segs + 1) * (segs + 1))
	for gz in segs + 1:
		for gx in segs + 1:
			var wx := ox + float(gx) * step
			var wz := oz + float(gz) * step
			heights[gz * (segs + 1) + gx] = field.height(wx, wz)

	# Normals are derived from the lattice itself (no extra field sampling).
	var normals := PackedVector3Array()
	normals.resize((segs + 1) * (segs + 1))
	var row := segs + 1
	for gz in segs + 1:
		for gx in segs + 1:
			var hl := heights[gz * row + maxi(gx - 1, 0)]
			var hr := heights[gz * row + mini(gx + 1, segs)]
			var hd := heights[maxi(gz - 1, 0) * row + gx]
			var hu := heights[mini(gz + 1, segs) * row + gx]
			normals[gz * row + gx] = Vector3(hl - hr, 2.0 * step, hd - hu).normalized()

	for gz in segs:
		for gx in segs:
			var i00 := gz * (segs + 1) + gx
			var i10 := i00 + 1
			var i01 := i00 + (segs + 1)
			var i11 := i01 + 1
			var x0 := float(gx) * step
			var x1 := x0 + step
			var z0 := float(gz) * step
			var z1 := z0 + step
			var v00 := Vector3(x0, heights[i00], z0)
			var v10 := Vector3(x1, heights[i10], z0)
			var v01 := Vector3(x0, heights[i01], z1)
			var v11 := Vector3(x1, heights[i11], z1)
			var n00: Vector3 = normals[i00]
			var n10: Vector3 = normals[i10]
			var n01: Vector3 = normals[i01]
			var n11: Vector3 = normals[i11]
			var uv00 := Vector2((ox + x0) / 12.0, (oz + z0) / 12.0)
			var uv10 := Vector2((ox + x1) / 12.0, (oz + z0) / 12.0)
			var uv01 := Vector2((ox + x0) / 12.0, (oz + z1) / 12.0)
			var uv11 := Vector2((ox + x1) / 12.0, (oz + z1) / 12.0)
			for v in [[v00, n00, uv00], [v10, n10, uv10], [v11, n11, uv11],
					[v00, n00, uv00], [v11, n11, uv11], [v01, n01, uv01]]:
				st.set_normal(v[1])
				st.set_uv(v[2])
				st.add_vertex(v[0])
			triangles += 2

	_heights = heights
	st.generate_tangents()
	var mesh := st.commit()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "Terrain"
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_mesh_instance)

	_body = StaticBody3D.new()
	_body.name = "TerrainCollision"
	var cs := CollisionShape3D.new()
	# Trimesh from the rendered mesh: collision can never disagree with the
	# visible surface, and Godot 4.7's HeightMapShape3D has no cell_size.
	cs.shape = mesh.create_trimesh_shape()
	_body.add_child(cs)
	add_child(_body)


func world_center() -> Vector3:
	return position + Vector3(Config.CHUNK_SIZE * 0.5, 0.0, Config.CHUNK_SIZE * 0.5)


## Height of the rendered triangle surface (not the raw field), so scattered
## props sit exactly on the terrain mesh instead of floating above it.
func sample_height(wx: float, wz: float) -> float:
	if _heights.is_empty():
		return field.height(wx, wz)
	var segs := Config.CHUNK_SEGMENTS
	var local_x := (wx - position.x) / _step
	var local_z := (wz - position.z) / _step
	var gx := clampf(local_x, 0.0, float(segs) - 0.001)
	var gz := clampf(local_z, 0.0, float(segs) - 0.001)
	var x0 := int(gx)
	var z0 := int(gz)
	var tx := gx - float(x0)
	var tz := gz - float(z0)
	var row := segs + 1
	var h00 := _heights[z0 * row + x0]
	var h10 := _heights[z0 * row + x0 + 1]
	var h01 := _heights[(z0 + 1) * row + x0]
	var h11 := _heights[(z0 + 1) * row + x0 + 1]
	# Match the mesh triangulation (00-10-11 / 00-11-01).
	if tx + tz <= 1.0:
		return h00 + (h10 - h00) * tx + (h01 - h00) * tz
	return h11 + (h01 - h11) * (1.0 - tx) + (h10 - h11) * (1.0 - tz)


func dispose() -> void:
	if _mesh_instance:
		_mesh_instance.queue_free()
		_mesh_instance = null
	if _body:
		_body.queue_free()
		_body = null
	queue_free()
