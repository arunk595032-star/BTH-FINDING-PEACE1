extends Node3D
## One streamed 128 m terrain chunk.
##
## Performance notes (see docs/PERFORMANCE.md):
##   * the height lattice is generated once and cached by the world generator,
##     so revisiting an area never re-evaluates the terrain field;
##   * meshes are written straight into PackedArrays instead of one
##     SurfaceTool call per vertex (46 ms -> ~5 ms per chunk on the audit box);
##   * three distance LODs (48 / 24 / 16 quads) with a downward skirt that hides
##     LOD seams without building stitching geometry;
##   * collision is a separate, cacheable full-resolution trimesh that is only
##     attached while the player is near the chunk.
##
## Heights are always sampled at full lattice resolution, so vegetation
## placement and physics agree with the visible surface at every LOD.

const Config = preload("res://scripts/core/world_config.gd")

const LOD_SEGMENTS := [48, 24, 16]
const LOD_STEP_MULT := [1, 2, 3]
const SKIRT_DROP := 6.0
const UV_SCALE := 12.0

var field
var coord := Vector2i.ZERO
var built := false
var lod := 0
var segments := 48
var triangles := 0
var collision_enabled := false
var build_us := 0

var _mesh_instance: MeshInstance3D
var _body: StaticBody3D
var _heights := PackedFloat32Array()
var _normals := PackedVector3Array()
var _step := 1.0
var _row := 0
var _mesh: ArrayMesh
var _shape: ConcavePolygonShape3D


func setup(p_field: RefCounted, p_coord: Vector2i, lattice: Dictionary = {}) -> void:
	field = p_field
	coord = p_coord
	name = "Chunk_%d_%d" % [coord.x, coord.y]
	position = Vector3(
		float(coord.x) * Config.CHUNK_SIZE - Config.WORLD_HALF, 0.0,
		float(coord.y) * Config.CHUNK_SIZE - Config.WORLD_HALF)
	if lattice.has("heights"):
		_heights = lattice["heights"]
		_normals = lattice["normals"]
		_row = Config.CHUNK_SEGMENTS + 1
		_step = Config.CHUNK_SIZE / float(Config.CHUNK_SEGMENTS)
	else:
		generate_lattice()


## Full-resolution height + normal lattice. Static so the world can cache it
## without keeping a chunk node alive.
static func make_lattice(p_field: RefCounted, p_coord: Vector2i) -> Dictionary:
	var segs: int = Config.CHUNK_SEGMENTS
	var row := segs + 1
	var step: float = Config.CHUNK_SIZE / float(segs)
	var ox := float(p_coord.x) * Config.CHUNK_SIZE - Config.WORLD_HALF
	var oz := float(p_coord.y) * Config.CHUNK_SIZE - Config.WORLD_HALF
	var heights := PackedFloat32Array()
	heights.resize(row * row)
	for gz in row:
		var wz := oz + float(gz) * step
		var base := gz * row
		for gx in row:
			heights[base + gx] = p_field.height(ox + float(gx) * step, wz)
	var normals := PackedVector3Array()
	normals.resize(row * row)
	for gz in row:
		var zd := maxi(gz - 1, 0) * row
		var zu := mini(gz + 1, segs) * row
		var base := gz * row
		for gx in row:
			var hl := heights[base + maxi(gx - 1, 0)]
			var hr := heights[base + mini(gx + 1, segs)]
			var hd := heights[zd + gx]
			var hu := heights[zu + gx]
			normals[base + gx] = Vector3(hl - hr, 2.0 * step, hd - hu).normalized()
	return {"heights": heights, "normals": normals}


func generate_lattice() -> void:
	var lattice := make_lattice(field, coord)
	_heights = lattice["heights"]
	_normals = lattice["normals"]
	_row = Config.CHUNK_SEGMENTS + 1
	_step = Config.CHUNK_SIZE / float(Config.CHUNK_SEGMENTS)


func lattice() -> Dictionary:
	return {"heights": _heights, "normals": _normals}


# ---------------------------------------------------------------------------
# Mesh construction
# ---------------------------------------------------------------------------
func build(material: Material, lod_index := 0) -> void:
	var new_lod := clampi(lod_index, 0, LOD_SEGMENTS.size() - 1)
	if built and new_lod == lod and _mesh != null:
		return
	var t0 := Time.get_ticks_usec()
	if _heights.is_empty():
		generate_lattice()
	lod = new_lod
	segments = LOD_SEGMENTS[lod]
	var mult: int = LOD_STEP_MULT[lod]
	var segs := segments
	var grid := segs + 1
	var seg_step := Config.CHUNK_SIZE / float(segs)
	var big_step := Config.CHUNK_SIZE / float(Config.CHUNK_SEGMENTS)

	# --- sample the cached full lattice at this LOD -------------------------
	var hs := PackedFloat32Array()
	hs.resize(grid * grid)
	for gz in grid:
		var src_row := (gz * mult) * _row
		var dst_row := gz * grid
		for gx in grid:
			hs[dst_row + gx] = _heights[src_row + gx * mult]

	# --- finite-difference normals at LOD resolution ------------------------
	var ns := PackedVector3Array()
	ns.resize(grid * grid)
	for gz in grid:
		var zd := maxi(gz - 1, 0) * grid
		var zu := mini(gz + 1, segs) * grid
		var base := gz * grid
		for gx in grid:
			var hl := hs[base + maxi(gx - 1, 0)]
			var hr := hs[base + mini(gx + 1, segs)]
			var hd := hs[zd + gx]
			var hu := hs[zu + gx]
			ns[base + gx] = Vector3(hl - hr, 2.0 * seg_step, hd - hu).normalized()

	# --- geometry arrays (no SurfaceTool churn) ----------------------------
	var skirt_quads := segs * 4
	var vcount := grid * grid + skirt_quads * 4
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	verts.resize(vcount)
	norms.resize(vcount)
	uvs.resize(vcount)
	tangents.resize(vcount * 4)
	for gz in grid:
		var wz := float(gz) * seg_step
		var row := gz * grid
		for gx in grid:
			var i := row + gx
			var wx := float(gx) * seg_step
			var h := hs[i]
			verts[i] = Vector3(wx, h, wz)
			norms[i] = ns[i]
			uvs[i] = Vector2((position.x + wx) / UV_SCALE, (position.z + wz) / UV_SCALE)
			var hl := hs[row + maxi(gx - 1, 0)]
			var hr := hs[row + mini(gx + 1, segs)]
			var tx := Vector3(2.0 * seg_step, hr - hl, 0.0).normalized()
			tangents[i * 4] = tx.x
			tangents[i * 4 + 1] = tx.y
			tangents[i * 4 + 2] = tx.z
			tangents[i * 4 + 3] = 1.0

	var indices := PackedInt32Array()
	indices.resize(segs * segs * 6 + skirt_quads * 6)
	var w := 0
	for gz in segs:
		var row := gz * grid
		var nrow := row + grid
		for gx in segs:
			var i00 := row + gx
			var i10 := i00 + 1
			var i01 := nrow + gx
			var i11 := i01 + 1
			indices[w] = i00
			indices[w + 1] = i10
			indices[w + 2] = i11
			indices[w + 3] = i00
			indices[w + 4] = i11
			indices[w + 5] = i01
			w += 6

	# --- skirt: closes LOD seams, keeps the surface watertight --------------
	var vi := grid * grid
	var ii := segs * segs * 6
	vi = _add_skirt(verts, norms, uvs, tangents, indices, vi, ii, hs, grid, segs, seg_step)
	triangles = segs * segs * 2 + skirt_quads * 2

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "Terrain"
		add_child(_mesh_instance)
	_mesh_instance.mesh = _mesh
	_mesh_instance.material_override = material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	built = true
	build_us = Time.get_ticks_usec() - t0


## Appends the four skirt strips. Returns the next free vertex index.
func _add_skirt(verts: PackedVector3Array, norms: PackedVector3Array,
		uvs: PackedVector2Array, tangents: PackedFloat32Array, indices: PackedInt32Array,
		vstart: int, istart: int, hs: PackedFloat32Array, grid: int, segs: int,
		seg_step: float) -> int:
	var vi := vstart
	var ii := istart
	# Edge 0: z = 0 (inward +Z), 1: x = max (inward -X),
	# 2: z = max (inward -Z), 3: x = 0 (inward +X).
	for edge in 4:
		var inward := Vector3.ZERO
		match edge:
			0: inward = Vector3(0, 0, 1)
			1: inward = Vector3(-1, 0, 0)
			2: inward = Vector3(0, 0, -1)
			_: inward = Vector3(1, 0, 0)
		for k in segs:
			var a: int
			var b: int
			match edge:
				0:
					a = k
					b = k + 1
				1:
					a = k * grid + segs
					b = (k + 1) * grid + segs
				2:
					a = segs * grid + k
					b = segs * grid + k + 1
				_:
					a = k * grid
					b = (k + 1) * grid
			var pa := verts[a]
			var pb := verts[b]
			var na := norms[a]
			var nb := norms[b]
			var pa_b := pa - Vector3(0, SKIRT_DROP, 0)
			var pb_b := pb - Vector3(0, SKIRT_DROP, 0)
			for v in [[pa, na], [pb, nb], [pb_b, inward], [pa_b, inward]]:
				verts[vi] = v[0]
				norms[vi] = v[1]
				tangents[vi * 4] = 1.0
				tangents[vi * 4 + 1] = 0.0
				tangents[vi * 4 + 2] = 0.0
				tangents[vi * 4 + 3] = 1.0
				uvs[vi] = Vector2((pa.x + pb.x) * 0.5, pa.y)
				vi += 1
			# Winding chosen so the face points into the chunk.
			var n := (pb - pa).cross(pb_b - pa)
			if n.dot(inward) > 0.0:
				indices[ii] = vi - 4
				indices[ii + 1] = vi - 3
				indices[ii + 2] = vi - 2
				indices[ii + 3] = vi - 4
				indices[ii + 4] = vi - 2
				indices[ii + 5] = vi - 1
			else:
				indices[ii] = vi - 4
				indices[ii + 1] = vi - 2
				indices[ii + 2] = vi - 3
				indices[ii + 3] = vi - 4
				indices[ii + 4] = vi - 1
				indices[ii + 5] = vi - 2
			ii += 6
	return vi


# ---------------------------------------------------------------------------
# Collision (separate full-resolution trimesh, cached by the world)
# ---------------------------------------------------------------------------
func make_collision_shape() -> ConcavePolygonShape3D:
	if _shape != null:
		return _shape
	if _heights.is_empty():
		generate_lattice()
	_shape = make_collision_shape_for(_heights, coord)
	return _shape


## Builds the full-resolution collision trimesh from a cached lattice.
static func make_collision_shape_for(p_heights: PackedFloat32Array,
		p_coord: Vector2i) -> ConcavePolygonShape3D:
	var segs: int = Config.CHUNK_SEGMENTS
	var row := segs + 1
	var step: float = Config.CHUNK_SIZE / float(segs)
	var faces := PackedVector3Array()
	faces.resize(segs * segs * 6)
	var w := 0
	for gz in segs:
		var z0 := float(gz) * step
		var z1 := z0 + step
		for gx in segs:
			var x0 := float(gx) * step
			var x1 := x0 + step
			var i00 := gz * row + gx
			var i10 := i00 + 1
			var i01 := i00 + row
			var i11 := i01 + 1
			var v00 := Vector3(x0, p_heights[i00], z0)
			var v10 := Vector3(x1, p_heights[i10], z0)
			var v11 := Vector3(x1, p_heights[i11], z1)
			var v01 := Vector3(x0, p_heights[i01], z1)
			faces[w] = v00
			faces[w + 1] = v10
			faces[w + 2] = v11
			faces[w + 3] = v00
			faces[w + 4] = v11
			faces[w + 5] = v01
			w += 6
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = false
	return shape


func enable_collision(shape: ConcavePolygonShape3D = null) -> void:
	if collision_enabled:
		return
	if shape == null:
		shape = make_collision_shape()
	_body = StaticBody3D.new()
	_body.name = "TerrainCollision"
	_body.collision_layer = 1
	var cs := CollisionShape3D.new()
	cs.shape = shape
	_body.add_child(cs)
	add_child(_body)
	collision_enabled = true


func disable_collision() -> void:
	if _body != null:
		_body.queue_free()
		_body = null
	collision_enabled = false


func has_free_collision_shape() -> bool:
	return _shape != null


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------
func world_center() -> Vector3:
	return position + Vector3(Config.CHUNK_SIZE * 0.5, 0.0, Config.CHUNK_SIZE * 0.5)


## Height of the full-resolution terrain surface (independent of render LOD),
## so scattered props never float or sink when a chunk changes LOD.
func sample_height(wx: float, wz: float) -> float:
	if _heights.is_empty():
		return field.height(wx, wz)
	var segs: int = Config.CHUNK_SEGMENTS
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


## Cheap slope from the cached lattice (0 = flat, 1 = vertical). Replaces four
## full terrain-field evaluations per vegetation candidate.
func slope_at(wx: float, wz: float) -> float:
	if _normals.is_empty():
		return field.slope_at(wx, wz)
	var segs: int = Config.CHUNK_SEGMENTS
	var gx := clampi(int((wx - position.x) / _step + 0.5), 0, segs)
	var gz := clampi(int((wz - position.z) / _step + 0.5), 0, segs)
	return 1.0 - clampf((_normals[gz * (segs + 1) + gx] as Vector3).y, 0.0, 1.0)


func dispose() -> void:
	if _mesh_instance != null:
		_mesh_instance.queue_free()
		_mesh_instance = null
	if _body != null:
		_body.queue_free()
		_body = null
	queue_free()
