# BTH world design - Thornbury Valley

Everything here is the actual data in `scripts/core/world_config.gd` and
`scripts/world/terrain_field.gd`. Dimensions are metres, world centre is (0, 0), **-Z is north**,
**+X is east**. Units are 1 unit = 1 m.

## Scale

| Property | Value |
|---|---|
| Playable extent | 2 048 x 2 048 m (4.19 km²) |
| Terrain chunk | 128 m, 48 x 48 quads (2.67 m vertices) |
| Chunks in world | 16 x 16 = 256 |
| Stream radius | 448 m (loaded chunks), unload at 576 m |
| Far terrain | one 256 x 256 mesh (8 m lattice), shown beyond 430 m, 0.9 m below detail chunks |
| Height range | 1.8 m valley floor to 528 m summit |
| River network | 3.47 km of centreline (river + highland stream + forest creek) |
| Roads | 6 routes, 6.5 m main road down to 2.4 m trails |
| Seed | 20260419 (deterministic) |

Streaming starts with 13 chunks (players' immediate area) and fills the rest from a
distance-sorted queue at 3 chunks/frame, so launching never hitches on 40 chunk builds.

## Regions and anchors

| Region | Anchor | Radius | Content |
|---|---|---|---|
| The Northern Peaks | (-40, -760) | 430 | Ridged mountains, pass at x ~ -280, cave mouth, pine line |
| Eastern Highlands | (730, -120) | 430 | Rocky plateau, highland trail, remote ruins |
| Whisperwood | (-560, 120) | 380 | Western forest hills, creek, watchtower |
| Golden Valley | (-40, 120) | 330 | Central river valley, farmland, copses |
| Thornbury Village | (-168, 236) | 190 | Main settlement |
| Tarnwatch Keep | (438, -132) | 210 | Castle crag |
| Ashenfall Ruins | (536, 292) | 220 | Broken walls, columns, altar, statue |
| The Southern Fields | (120, 760) | 430 | Rolling grass, hamlet, dirt roads |
| Silverwater Lake | (0, 980) | 260 | River-mouth lake |

Landmark sites: village well/market, castle gate/keep, Ashenfall altar, watchtower ruins,
old camp (-616, -196), cave mouth (-268, -706), Ashenfall falls (352, -372).

## Terrain construction

`base_height(x, z)` = five noise fields (domain-warped base, detail, ridged peaks, micro,
warp) shaped by smooth region weights:

* **North**: ridged peaks, amplitude grows to ~270 m, with a pass gap around x = -280 and a
  further summit boost beyond z = -640 (snow line above 260 m).
* **East**: terraced highland plateau, 28-116 m above the valley.
* **West**: forested hills, 10-36 m.
* **South**: rolling fields, 4-16 m plus medium-scale rolling noise.
* **Central valley**: broad, gently undulating floor.
* **Castle crag**: a Gaussian hill + plateau pad at 438, -132.
* **Lake basin**: flattened to 1.8 m inside a 186 m radius.
* **World rim**: rises 26 m+ beyond 880 m from centre - an unclimbable natural boundary,
  reinforced by the player's clamp at ±998 m.

Pads flatten building sites *before* the river carve and road grading, so a house never sits
on a slope: village (r 108, blend 62), castle (r 74, blend 58), hamlet (r 46, blend 34),
waterfall shelf (r 34, blend 14), ruins (r 44) and the lake basin.

The height field is the single source of truth: terrain mesh, chunk collision, building
placement, vegetation rules and water depth all sample it.

## River system

Three authored profiles (level + width per point), densified with Catmull-Rom at 4 m and
carved into the terrain. The bed is `level - depth` (depth 1.1-3.6 m scaled by width), banks
rise back to terrain over 17 m. Because the carve and the water ribbon use the same smoothed
centreline, water cannot clip the banks at bends.

* **Main river**: source at (-62, -948) 148 m, flows south through the valley, reaches the
  lake at (18, 1010) 5.2 m. Width 9 m at the source to 74 m at the mouth.
* **Highland stream** (east): (742, -430) 112 m → joins the river at (96, -150) 17 m.
  The authored segment (392, -378) 58 m → (352, -372) 26 m is steep (0.8 gradient) and is
  rendered as a **32 m waterfall** with a plunge pool and mist instead of a stretched quad.
* **Forest creek** (west): (-742, 372) 46 m → (-140, 380) 9.5 m.

Water rendering: depth-aware colour ramp, two scrolling normal layers, shoreline foam,
screen-space refraction and equirectangular HDRI reflections (`shaders/water.gdshader`).
The lake is a 186 m disc at 5.05 m, and the waterfall pool a flattened sphere at 25.4 m.

## Roads and bridges

Authored polylines (Kingsroad, South road, Mountain pass road, Forest trail, Highland trail,
Village lane) are smoothed at 6 m, their elevation profile is smoothed three times, then
stamped into a 768² corridor grid. `height()` grades the terrain toward the road profile
within 8 m of the centreline, limited to a 9 m cut so a road cannot trench through a
mountain. Road/trail/wet/forest weights are baked into the RGBA world mask used by the
terrain shader, which is why roads have no z-fighting ribbon and blend into the ground.

Bridges are found automatically: each road is sampled every 4 m and a crossing is where its
distance to a river centreline drops below half the water width. Three crossings produce
stone arch bridges (or timber trestle on trails): deck, parapets, abutments, an arch barrel
perpendicular to the road, all with box/deck colliders at the flattened road level.

## Settlements

**Thornbury** (19 houses across village + hamlet): stone plinth, plaster or brick walls,
timber corner posts/sills/diagonal braces, tiled gable roof with overhang, chimney, dark
window openings with timber lintels, timber doors. Plaza with cobbles, well with a small
roof, two market stalls, two carts, garden fences, boundary stones, two tilled fields with
furrows, crop rows, fences and a scarecrow.

**Tarnwatch Keep**: 112 x 88 m curtain walls (2.6 m thick, 10 m tall) with merlons, four
corner towers with conical roofs, a gatehouse with twin towers, timber gate leaves, stone
steps to the road, an enterable keep (four walls, paved ground floor, dais, interior stairs,
roofed stair turret), courtyard paving, carts, market stall and a Poly Haven gothic statue.

**Landmarks**: ruined watchtower with a broken rim and palisade, Ashenfall ruins with broken
curtain wall, five columns, altar and rubble, an old camp with tents/palisade/fire pit, and a
cave mouth built into the mountain flank.

## Vegetation rules

Each chunk samples 260 candidates. A candidate becomes a tree only if it is outside
settlement pads, at least 5 m from water, 4.5 m from a road and on a slope below 0.62.
Forest density comes from west/north/east region weights with a sine-patch clearing mask;
conifer bias increases with altitude and northness, broadleaf dominates the valley and south.
Trees are two-surface meshes (bark cylinder + 24 alpha foliage cards, 48 instances per chunk
average) so density stays affordable; Poly Haven ferns, weeds, nettles, rooibos bushes and
fallen trunks add scanned undergrowth at close range.

Distance culling: trees 900 m, snags 500 m, bushes 260 m, grass 120 m, ferns 150 m, Poly Haven
undergrowth 90-240 m, rocks 520 m.

## Expansion path

* `world/` is reserved for hand-authored overrides; chunk scenes can be swapped in without
  touching the generator.
* Increase `WORLD_SIZE` and region keys in `world_config.gd` - streaming scales because only
  chunks within `STREAM_RADIUS` exist.
* Add a region by appending to `REGIONS` and a settlement by adding a pad + builder call.
* The navigation foundation is the height field plus chunk collision; baking a navmesh per
  chunk and spawning NPCs is the next milestone.
