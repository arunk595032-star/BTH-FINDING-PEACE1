extends RefCounted
## Analytical terrain description of the BTH world.
##
## The landscape is not a painted heightmap: it is a deterministic function of
## region noise, plateau pads, carved river channels and road corridors.  Both
## the terrain mesh and every gameplay query (spawn height, vegetation rules,
## water depth) use this one source of truth, so they can never disagree.
##
## Called "field" because `height(x, z)` can be evaluated anywhere.

const Config = preload("res://scripts/core/world_config.gd")

const GRID_RES := 768                       # 2.67 m per cell over the world
const GRID_STEP := Config.WORLD_SIZE / GRID_RES
const RIVER_BANK := 17.0                    # metres of carved bank either side
const ROAD_SHOULDER := 8.0

var _noise_base: FastNoiseLite
var _noise_detail: FastNoiseLite
var _noise_ridge: FastNoiseLite
var _noise_micro: FastNoiseLite
var _noise_warp: FastNoiseLite

var _river_dist: PackedFloat32Array
var _river_level: PackedFloat32Array
var _river_width: PackedFloat32Array
var _river_depth: PackedFloat32Array

var _road_dist: PackedFloat32Array
var _road_level: PackedFloat32Array
var _road_width: PackedFloat32Array
var _road_surface: PackedFloat32Array

var _pads: Array = []          # {center:Vector2, radius:float, blend:float, height:float, flat:float}
var water_paths: Array = []    # prepared point lists for the water mesh builder
var castle_pad_height := 0.0


func _init() -> void:
	_setup_noise()
	_setup_pads()
	_setup_water_paths()
	_rasterise_rivers()
	_setup_roads()


# ---------------------------------------------------------------------------
# Noise / base shape
# ---------------------------------------------------------------------------
func _setup_noise() -> void:
	_noise_base = FastNoiseLite.new()
	_noise_base.seed = Config.SEED
	_noise_base.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise_base.frequency = 0.0018
	_noise_base.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_base.fractal_octaves = 5
	_noise_base.fractal_gain = 0.48

	_noise_detail = FastNoiseLite.new()
	_noise_detail.seed = Config.SEED + 17
	_noise_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_detail.frequency = 0.012
	_noise_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise_detail.fractal_octaves = 3

	_noise_ridge = FastNoiseLite.new()
	_noise_ridge.seed = Config.SEED + 91
	_noise_ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_ridge.frequency = 0.0024
	_noise_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_noise_ridge.fractal_octaves = 6
	_noise_ridge.fractal_gain = 0.52

	_noise_micro = FastNoiseLite.new()
	_noise_micro.seed = Config.SEED + 233
	_noise_micro.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_micro.frequency = 0.09
	_noise_micro.fractal_octaves = 2

	_noise_warp = FastNoiseLite.new()
	_noise_warp.seed = Config.SEED + 441
	_noise_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise_warp.frequency = 0.0035


static func catmull(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


## Densifies a polyline with Catmull-Rom interpolation so both the terrain
## carve and the water mesh follow the same smooth meander.
static func smooth_points(points: Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in points.size() - 1:
		var p0: Vector2 = points[maxi(i - 1, 0)]
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[i + 1]
		var p3: Vector2 = points[mini(i + 2, points.size() - 1)]
		var count := maxi(1, int(ceil(p1.distance_to(p2) / step)))
		for k in count:
			if i > 0 and k == 0:
				continue
			out.append(catmull(p0, p1, p2, p3, float(k) / float(count)))
	out.append(points[points.size() - 1])
	return out


## Same, but carrying the water level / width profile.
static func smooth_water(points: PackedVector2Array, levels: PackedFloat32Array,
		widths: PackedFloat32Array, step: float) -> Array:
	var out_pts := PackedVector2Array()
	var out_levels := PackedFloat32Array()
	var out_widths := PackedFloat32Array()
	for i in points.size() - 1:
		var p0: Vector2 = points[maxi(i - 1, 0)]
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[i + 1]
		var p3: Vector2 = points[mini(i + 2, points.size() - 1)]
		var count := maxi(1, int(ceil(p1.distance_to(p2) / step)))
		for k in count:
			if i > 0 and k == 0:
				continue
			var t := float(k) / float(count)
			out_pts.append(catmull(p0, p1, p2, p3, t))
			out_levels.append(lerpf(levels[i], levels[i + 1], t))
			out_widths.append(lerpf(widths[i], widths[i + 1], t))
	out_pts.append(points[points.size() - 1])
	out_levels.append(levels[levels.size() - 1])
	out_widths.append(widths[widths.size() - 1])
	return [out_pts, out_levels, out_widths]


static func smooth01(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Raw landscape before water channels and roads are stamped into it.
func base_height(x: float, z: float) -> float:
	var warp_x := _noise_warp.get_noise_2d(x, z) * 48.0
	var warp_z := _noise_warp.get_noise_2d(z + 311.0, x - 127.0) * 48.0
	var wx := x + warp_x
	var wz := z + warp_z

	var north := smooth01(-190.0, -820.0, z)
	var east := smooth01(300.0, 940.0, x)
	var west := smooth01(-120.0, -860.0, x)
	var south := smooth01(400.0, 1000.0, z)
	var valley := 1.0 - maxf(north, maxf(east * 0.85, south * 0.6))

	var h := 13.0
	h += _noise_base.get_noise_2d(wx, wz) * 11.0
	h += _noise_detail.get_noise_2d(wx * 0.7, wz * 0.7) * 1.6

	# Northern mountain wall: ridged peaks with a pass around x = -260.
	var ridge := _noise_ridge.get_noise_2d(wx, wz) * 0.5 + 0.5
	var pass_gap := smooth01(150.0, 420.0, absf(x + 280.0))
	var peaks := pow(ridge, 1.55) * (150.0 + north * 120.0)
	h += north * (46.0 + peaks * pass_gap)
	# Truly tall summits in the far north.
	h += smooth01(-640.0, -980.0, z) * pow(ridge, 2.2) * 105.0

	# Eastern highlands: terraced cliffs above the river valley.
	var east_ridge := _noise_ridge.get_noise_2d(wx * 1.9, wz * 1.9) * 0.5 + 0.5
	h += east * (28.0 + pow(east_ridge, 1.7) * 88.0)
	# Waterfall cliff notch by the eastern stream.
	var wf := Vector2(Config.WATERFALL_SITE.x, Config.WATERFALL_SITE.y)
	var wf_d := (Vector2(x, z) - wf).length()
	h += smooth01(210.0, 40.0, wf_d) * 9.0

	# Western forest hills.
	h += west * (10.0 + (_noise_base.get_noise_2d(wx * 2.3, wz * 2.3) * 0.5 + 0.5) * 26.0)

	# Southern rolling fields.
	var south_roll := _noise_base.get_noise_2d(wx * 1.4, wz * 1.4) * 0.5 + 0.5
	h += south * (4.0 + south_roll * 12.0)

	# River valley floor is broad and gentle.
	h -= valley * 3.2

	# Castle crag: a distinct hill under the keep.
	var castle := Vector2(Config.CASTLE_CENTER.x, Config.CASTLE_CENTER.y)
	var cd := (Vector2(x, z) - castle).length()
	h += exp(-pow(cd / 150.0, 2.0)) * 34.0

	# Lake basin in the south.
	var lake_d := (Vector2(x, z) - Vector2(6.0, 966.0)).length()
	h -= smooth01(320.0, 40.0, lake_d) * 7.0

	# World edge: rise into an unclimbable rim so the map reads as a valley
	# system rather than a floating plate.
	var edge := maxf(absf(x), absf(z))
	h += smooth01(880.0, 1030.0, edge) * (26.0 + (edge - 880.0) * 0.45)

	# Medium-scale rolling relief: keeps the valley and the southern fields
	# from reading as a flat plate while leaving the pads flat.
	var rolling := _noise_base.get_noise_2d(wx * 3.3, wz * 3.3)
	h += rolling * 5.5 * (1.0 - north * 0.7) * (1.0 - east * 0.5)
	h += _noise_micro.get_noise_2d(x * 1.7, z * 1.7) * 0.35
	return h


# ---------------------------------------------------------------------------
# Plateau pads (village square, castle crag, hamlet)
# ---------------------------------------------------------------------------
func _setup_pads() -> void:
	var v := Config.VILLAGE_CENTER
	var village_h := base_height(v.x, v.y) + 1.2
	_pads.append({
		"center": v, "radius": 108.0, "blend": 62.0, "height": village_h, "flat": 1.0,
	})
	var c := Config.CASTLE_CENTER
	castle_pad_height = base_height(c.x, c.y) + 12.0
	_pads.append({
		"center": c, "radius": 74.0, "blend": 58.0, "height": castle_pad_height, "flat": 1.0,
	})
	var hm := Config.HAMLET_CENTER
	_pads.append({
		"center": hm, "radius": 46.0, "blend": 34.0,
		"height": base_height(hm.x, hm.y) + 0.6, "flat": 1.0,
	})
	# Flat shelf at the waterfall lip so the fall reads as one clean drop.
	var wf := Config.WATERFALL_SITE
	_pads.append({
		"center": wf, "radius": 26.0, "blend": 30.0,
		"height": base_height(wf.x, wf.y) + 2.0, "flat": 1.0,
	})
	# Rock shelf that gives the eastern stream a clean 32 m drop.
	_pads.append({
		"center": Vector2(402.0, -380.0), "radius": 34.0, "blend": 14.0,
		"height": base_height(402.0, -380.0) + 16.0, "flat": 1.0,
	})
	# Southern lake basin.
	_pads.append({
		"center": Vector2(6.0, 966.0), "radius": 186.0, "blend": 96.0,
		"height": 1.8, "flat": 1.0,
	})
	# Courtyard pad at the ruins.
	var ru := Config.RUINS_SITE
	_pads.append({
		"center": ru, "radius": 44.0, "blend": 30.0,
		"height": base_height(ru.x, ru.y), "flat": 0.85,
	})


func _apply_pads(x: float, z: float, h: float) -> float:
	for pad in _pads:
		var d: float = (Vector2(x, z) - pad["center"]).length()
		var outer: float = pad["radius"] + pad["blend"]
		if d > outer:
			continue
		var w: float = 1.0 - smooth01(pad["radius"], outer, d)
		w *= pad["flat"]
		h = lerpf(h, pad["height"], w)
	return h


# ---------------------------------------------------------------------------
# Water paths
# ---------------------------------------------------------------------------
func _setup_water_paths() -> void:
	water_paths = []
	for spec in [Config.RIVER_POINTS, Config.STREAM_POINTS, Config.CREEK_POINTS]:
		var pts: PackedVector2Array = PackedVector2Array()
		var levels: PackedFloat32Array = PackedFloat32Array()
		var widths: PackedFloat32Array = PackedFloat32Array()
		for entry in spec:
			pts.append(entry["p"])
			levels.append(entry["level"])
			widths.append(entry["width"])
		water_paths.append({"points": pts, "levels": levels, "widths": widths})


func _rasterise_rivers() -> void:
	var n := (GRID_RES + 1) * (GRID_RES + 1)
	_river_dist.resize(n)
	_river_level.resize(n)
	_river_width.resize(n)
	_river_depth.resize(n)
	for i in n:
		_river_dist[i] = 100000.0
		_river_level[i] = 0.0
		_river_width[i] = 0.0
		_river_depth[i] = 1.0

	for path in water_paths:
		var pts: PackedVector2Array = path["points"]
		var levels: PackedFloat32Array = path["levels"]
		var widths: PackedFloat32Array = path["widths"]
		var smooth := smooth_water(pts, levels, widths, 4.0)
		var spts: PackedVector2Array = smooth[0]
		var slev: PackedFloat32Array = smooth[1]
		var swid: PackedFloat32Array = smooth[2]
		for s in spts.size() - 1:
			var reach: float = maxf(swid[s], swid[s + 1]) * 0.5 + RIVER_BANK + 6.0
			_stamp_river_segment(spts[s], spts[s + 1], slev[s], slev[s + 1],
				swid[s], swid[s + 1], reach)


func _stamp_river_segment(a: Vector2, b: Vector2, la: float, lb: float,
		wa: float, wb: float, reach: float) -> void:
	var min_x := int(floor((minf(a.x, b.x) - reach + Config.WORLD_HALF) / GRID_STEP))
	var max_x := int(ceil((maxf(a.x, b.x) + reach + Config.WORLD_HALF) / GRID_STEP))
	var min_z := int(floor((minf(a.y, b.y) - reach + Config.WORLD_HALF) / GRID_STEP))
	var max_z := int(ceil((maxf(a.y, b.y) + reach + Config.WORLD_HALF) / GRID_STEP))
	min_x = maxi(min_x, 0)
	min_z = maxi(min_z, 0)
	max_x = mini(max_x, GRID_RES)
	max_z = mini(max_z, GRID_RES)
	var ab := b - a
	var ab_len_sq := maxf(ab.length_squared(), 0.0001)
	for iz in range(min_z, max_z + 1):
		var wz := iz * GRID_STEP - Config.WORLD_HALF
		for ix in range(min_x, max_x + 1):
			var wx := ix * GRID_STEP - Config.WORLD_HALF
			var p := Vector2(wx, wz)
			var t := clampf((p - a).dot(ab) / ab_len_sq, 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			var idx := iz * (GRID_RES + 1) + ix
			if d < _river_dist[idx]:
				_river_dist[idx] = d
				_river_level[idx] = lerpf(la, lb, t)
				_river_width[idx] = lerpf(wa, wb, t)
				var w := lerpf(wa, wb, t)
				_river_depth[idx] = clampf(w * 0.11, 1.1, 3.6)


func _bilinear(grid: PackedFloat32Array, x: float, z: float) -> float:
	var fx := clampf((x + Config.WORLD_HALF) / GRID_STEP, 0.0, float(GRID_RES) - 0.001)
	var fz := clampf((z + Config.WORLD_HALF) / GRID_STEP, 0.0, float(GRID_RES) - 0.001)
	var x0 := int(fx)
	var z0 := int(fz)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var row := GRID_RES + 1
	var i00 := z0 * row + x0
	var v00 := grid[i00]
	var v10 := grid[i00 + 1]
	var v01 := grid[i00 + row]
	var v11 := grid[i00 + row + 1]
	return lerpf(lerpf(v00, v10, tx), lerpf(v01, v11, tx), tz)


## x = distance to nearest water centreline, y = water surface height,
## z = water width in metres. Returns a far distance when no water is near.
func river_info(x: float, z: float) -> Vector3:
	return Vector3(_bilinear(_river_dist, x, z), _bilinear(_river_level, x, z),
		_bilinear(_river_width, x, z))


func river_depth_at(x: float, z: float) -> float:
	return _bilinear(_river_depth, x, z)


func distance_to_water(x: float, z: float) -> float:
	return _bilinear(_river_dist, x, z)


func water_level_at(x: float, z: float) -> float:
	return _bilinear(_river_level, x, z)


func distance_to_road(x: float, z: float) -> float:
	return _bilinear(_road_dist, x, z)


# ---------------------------------------------------------------------------
# Roads
# ---------------------------------------------------------------------------
func _setup_roads() -> void:
	var n := (GRID_RES + 1) * (GRID_RES + 1)
	_road_dist.resize(n)
	_road_level.resize(n)
	_road_width.resize(n)
	_road_surface.resize(n)
	for i in n:
		_road_dist[i] = 100000.0
		_road_level[i] = 0.0
		_road_width[i] = 0.0
		_road_surface[i] = 0.0

	for road in Config.ROADS:
		var pts: Array = road["points"]
		# Resample the authored polyline, then smooth the elevation profile so
		# the road grades gently instead of following every bump.
		var samples := smooth_points(pts, 6.0)
		var heights := PackedFloat32Array()
		for p in samples:
			heights.append(pre_road_height(p.x, p.y))
		for _pass in 3:
			var smoothed := heights.duplicate()
			for i in range(1, heights.size() - 1):
				smoothed[i] = (heights[i - 1] + heights[i] * 2.0 + heights[i + 1]) * 0.25
			heights = smoothed
		var width: float = road["width"]
		var surface: float = road["surface"]
		var reach := width * 0.5 + ROAD_SHOULDER + 4.0
		for s in samples.size() - 1:
			_stamp_road_segment(samples[s], samples[s + 1], heights[s], heights[s + 1],
				width, surface, reach)


func _resample(points: Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in points.size() - 1:
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var seg := a.distance_to(b)
		var count := maxi(1, int(ceil(seg / step)))
		for k in count:
			if i > 0 and k == 0:
				continue
			out.append(a.lerp(b, float(k) / float(count)))
	out.append(points[points.size() - 1])
	return out


func _stamp_road_segment(a: Vector2, b: Vector2, la: float, lb: float,
		width: float, surface: float, reach: float) -> void:
	var min_x := int(floor((minf(a.x, b.x) - reach + Config.WORLD_HALF) / GRID_STEP))
	var max_x := int(ceil((maxf(a.x, b.x) + reach + Config.WORLD_HALF) / GRID_STEP))
	var min_z := int(floor((minf(a.y, b.y) - reach + Config.WORLD_HALF) / GRID_STEP))
	var max_z := int(ceil((maxf(a.y, b.y) + reach + Config.WORLD_HALF) / GRID_STEP))
	min_x = maxi(min_x, 0)
	min_z = maxi(min_z, 0)
	max_x = mini(max_x, GRID_RES)
	max_z = mini(max_z, GRID_RES)
	var ab := b - a
	var ab_len_sq := maxf(ab.length_squared(), 0.0001)
	for iz in range(min_z, max_z + 1):
		var wz := iz * GRID_STEP - Config.WORLD_HALF
		for ix in range(min_x, max_x + 1):
			var wx := ix * GRID_STEP - Config.WORLD_HALF
			var p := Vector2(wx, wz)
			var t := clampf((p - a).dot(ab) / ab_len_sq, 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			var idx := iz * (GRID_RES + 1) + ix
			if d < _road_dist[idx]:
				_road_dist[idx] = d
				_road_level[idx] = lerpf(la, lb, t)
				_road_width[idx] = width
				_road_surface[idx] = surface


func road_info(x: float, z: float) -> Vector3:
	return Vector3(_bilinear(_road_dist, x, z), _bilinear(_road_level, x, z),
		_bilinear(_road_width, x, z))


func road_surface_at(x: float, z: float) -> float:
	return _bilinear(_road_surface, x, z)


## Height with pads and channels but before road grading.
func pre_road_height(x: float, z: float) -> float:
	var h := base_height(x, z)
	h = _apply_pads(x, z, h)
	var info := river_info(x, z)
	var half_w := info.z * 0.5
	if info.x < half_w + RIVER_BANK:
		var depth := river_depth_at(x, z)
		var bed := info.y - depth
		if info.x <= half_w:
			h = bed + pow(info.x / maxf(half_w, 0.5), 2.0) * depth * 0.5
		else:
			var t := smooth01(half_w, half_w + RIVER_BANK, info.x)
			h = lerpf(info.y - 0.35, h, pow(t, 1.35))
	return h


## Final walkable terrain height.
func height(x: float, z: float) -> float:
	var h := pre_road_height(x, z)
	var rd := _bilinear(_road_dist, x, z)
	if rd < 40.0:
		# Do not grade the road through a river bed; bridges carry it over.
		var ri := river_info(x, z)
		if ri.x > ri.z * 0.5 + 4.0:
			var level := _bilinear(_road_level, x, z)
			var width := _bilinear(_road_width, x, z)
			var w := width * 0.5
			var t := smooth01(w, w + ROAD_SHOULDER, rd)
			# Limit how far a road can cut into a mountainside.
			var delta := level - h
			if absf(delta) > 9.0:
				level = h + signf(delta) * 9.0
			h = lerpf(level, h, t)
	return h


func normal(x: float, z: float) -> Vector3:
	var e := 1.4
	var hl := height(x - e, z)
	var hr := height(x + e, z)
	var hd := height(x, z - e)
	var hu := height(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


## 0 = flat, 1 = vertical rock.
func slope_at(x: float, z: float) -> float:
	return 1.0 - normal(x, z).y


func region_at(pos: Vector3) -> String:
	var p := Vector2(pos.x, pos.z)
	var best := "The Wilds of BTH"
	var best_score := INF
	for region in Config.REGIONS:
		var d: float = p.distance_to(region["center"])
		var score: float = d / float(region["radius"])
		if score < 1.0 and score < best_score:
			best_score = score
			best = region["name"]
	return best


func is_inside_world(pos: Vector3) -> bool:
	return absf(pos.x) < Config.WORLD_HALF - 12.0 and absf(pos.z) < Config.WORLD_HALF - 12.0


## Texture-space mask used by the terrain shader.
## r = road, g = wet bank, b = trail, a = forest floor.
## Built from the already rasterised distance grids; cells far from any road or
## river skip the bilinear lookups so this stays a startup cost of about a
## second rather than a minute.
func write_world_mask() -> Image:
	var res := 768
	var step := Config.WORLD_SIZE / float(res)
	var row := GRID_RES + 1
	var bytes := PackedByteArray()
	bytes.resize(res * res * 4)
	for y in res:
		var wz := -Config.WORLD_HALF + (float(y) + 0.5) * step
		var north := smooth01(-260.0, -620.0, wz)
		var gz := clampi(int((wz + Config.WORLD_HALF) / GRID_STEP), 0, GRID_RES)
		for x in res:
			var wx := -Config.WORLD_HALF + (float(x) + 0.5) * step
			var gi := gz * row + clampi(int((wx + Config.WORLD_HALF) / GRID_STEP), 0, GRID_RES)
			var road := 0.0
			var trail := 0.0
			var wet := 0.0
			if _road_dist[gi] < 60.0:
				var rd := _bilinear(_road_dist, wx, wz)
				var rw := _bilinear(_road_width, wx, wz)
				var surf := _bilinear(_road_surface, wx, wz)
				var edge := smooth01(rw * 0.5 + 3.2, rw * 0.5 - 0.5, rd)
				if surf > 0.5:
					trail = edge
				else:
					road = edge
			if _river_dist[gi] < 70.0:
				var ri := river_info(wx, wz)
				wet = smooth01(ri.z * 0.5 + 13.0, ri.z * 0.5 - 0.8, ri.x)
			var west := smooth01(-80.0, -430.0, wx)
			var forest := maxf(west, north * 0.85)
			forest *= 0.45 + 0.55 * (sin(wx * 0.0113) * cos(wz * 0.0137) * 0.5 + 0.5)
			forest *= 1.0 - wet
			var i := (y * res + x) * 4
			bytes[i] = int(clampf(road, 0.0, 1.0) * 255.0)
			bytes[i + 1] = int(clampf(wet, 0.0, 1.0) * 255.0)
			bytes[i + 2] = int(clampf(trail, 0.0, 1.0) * 255.0)
			bytes[i + 3] = int(clampf(forest, 0.0, 1.0) * 255.0)
	return Image.create_from_data(res, res, false, Image.FORMAT_RGBA8, bytes)


func stats() -> Dictionary:
	return {
		"world_size": Config.WORLD_SIZE,
		"chunk_size": Config.CHUNK_SIZE,
		"chunk_segments": Config.CHUNK_SEGMENTS,
		"chunks": int(Config.WORLD_SIZE / Config.CHUNK_SIZE),
		"grid_res": GRID_RES,
		"grid_step": GRID_STEP,
		"water_paths": water_paths.size(),
		"roads": Config.ROADS.size(),
		"seed": Config.SEED,
	}
