# Verification record

Environment: Ubuntu 24.04 container, 2 vCPU, 3 GB RAM, **no GPU and no display**.
Engine: Godot **4.7.stable.official.5b4e0cb0f** (Linux editor build, headless mode).

Every status below is one of:

* **Implemented** - code and content exist in the repository.
* **Static-inspected** - verified by reading source/data only.
* **Import-tested** - Godot imported the resource without error.
* **Runtime-tested** - executed in a headless Godot process, with physics and scripts running.
* **Visually verified** - seen rendered. *Nothing in this project has this status yet* (no GPU).

## Commands run and actual results

```
godot --headless --path . --import
    -> 252-step asset import completed, 13 Poly Haven glTF scenes imported.

godot --headless --path . res://tests/smoke_test.tscn
    -> === 40 checks, 0 failed ===   (exit code 0)
    -> [BTH] World built in 3972 ms
       {"mask_ms":922,"far_terrain_ms":954,"vegetation_prep_ms":521,
        "water_ms":8,"structures_ms":1273,"total_ms":3972}
    -> height range 1.8 .. 439.7 m over 961 samples (the far rim reaches 528 m)
    -> streamed chunks: 40
    -> river meshes: 4, waterfalls: 1, lake: true
    -> structures: {"bridges":3,"houses":19,"landmarks":7,"props":23}
    -> vegetation: {"chunks":40,"grass":5678,"rocks":2160,"trees":5595}
    -> travelled 13.59 m in 3 s of simulated walking
    -> focus near well: 'Thornbury well'
    -> all 13 Poly Haven models import with mesh surfaces (13 ok)

godot --headless --path . --quit-after 420
    -> main scene ran 420 frames with the real HUD, player and streaming;
       no script errors, no missing resources.

godot --headless --path . --script res://tools/export_world_map.gd
    -> docs/world_map.png (900 x 900), render 10.9 s
    -> docs/world_extents.json: world 2048 m, height 0.3 .. 528.4 m,
       grid 768 (2.67 m), 3 water paths, 6 roads, seed 20260419
```

### What the 27 checks cover

Main scene load; world/player instantiation; terrain field; height range; river channel
carved at every authored river point; streamed chunk count; far-terrain skyline mesh;
river ribbons; waterfall; lake; house count; bridge count; landmark count; hero prop count;
tree/grass scatter; procedural conifer mesh; spawn placement; terrain collision body;
simulated WASD walking; player staying on the surface; interaction probe; all 13 glTF
assets importing with surfaces; terrain splat mask generation.

## Feature status matrix

| Requirement | Status | Evidence |
|---|---|---|
| Godot 4 project, Forward+ | Implemented + runtime-tested | `project.godot`, headless run |
| Real terrain (not flat) | Implemented + runtime-tested | height range in smoke test, `docs/world_map.png` |
| Mountains, valleys, plateaus | Implemented + visually inspected as *data render* | map |
| Chunked terrain + streaming | Implemented + runtime-tested | 40 chunks, queue budget 3/frame |
| River carved into terrain, descending | Implemented + runtime-tested | `river channel carved` check; 3.47 km |
| Waterfalls | Implemented + runtime-tested | 1 waterfall mesh + mist, 32 m drop |
| Lake | Implemented + runtime-tested | `lake: true` |
| Roads that follow terrain | Implemented + runtime-tested | road corridor grading, 6 routes |
| Bridges with collision | Implemented + runtime-tested | 3 bridges; deck colliders |
| Village + castle | Implemented + runtime-tested | 19 houses, keep/walls/towers |
| Landmarks | Implemented + runtime-tested | 7 landmark sites |
| Third-person controller | Implemented + runtime-tested | movement/collision checks |
| Vegetation with variation + culling | Implemented + runtime-tested | MultiMesh tiers, `visibility_range_end` |
| PBR material blending | Implemented, import-tested | 5-layer terrain shader, ARM/normal maps |
| HDRI lighting, fog, SSAO/SSIL | Implemented, shader syntax checked | `scripts/main.gd` |
| Shader compilation | Syntax-checked only | dummy renderer parsed all 4 shaders, no errors |
| In-engine screenshots | **Not possible here** | no GPU/display |
| FPS measurement | **Not measured** | no GPU; HUD shows live FPS at runtime for the user |
| Navmesh / NPCs / wildlife / combat | **Not implemented** | out of this milestone's scope |

## Honest gaps

1. **No rendered frame has been seen.** The container has no `/dev/dri`, no Vulkan ICD and
   no way to install Mesa (no root, no package candidate). Screenshots, FPS and visual
   polish (lighting balance, foam, foliage look) are therefore unverified. Godot's dummy
   renderer did compile/parse every shader and reported no errors after the water shader's
   removed `hint_radiance` was replaced with an equirectangular HDRI sample.
2. **The map image is a data render**, generated from `TerrainField.height()`, the river
   distance grid and the road grid. It is not a screenshot and does not show materials,
   lighting or models.
3. **Asset downloads are partial by design**: Poly Haven trees were rejected for their
   polygon count; Quaternius and Kenney were unreachable (see `ASSET_MANIFEST.md`).
4. Headless physics uses Jolt and the same collision geometry as the game, so the movement
   checks are meaningful, but they are not a substitute for playing it.

## How to verify locally (with a GPU)

```bash
godot --path .                     # F5: walk the valley
godot --headless --path . res://tests/smoke_test.tscn
```

Then check, in order: village spawn and street, river water at the bridge, castle gate
traversal, waterfall at (352, -372), forest tree density and wind, night-time is out of
scope (no day/night cycle yet).


## Performance optimization pass (BTH V1.1)

Baseline: `7e7a62db9d6a8483d4ad42e205e5ecc0f33c2059` (branch `perf-baseline`,
tag `bth-v1-baseline`). Full before/after evidence and limitations:
`docs/PERFORMANCE.md`; raw JSON: `docs/perf_baseline.json`, `docs/perf_after.json`.

```
godot --headless --path . res://tests/perf_bench.tscn -- --label=after
    -> === BTH performance benchmark ===
    -> chunks after 90 frames / forced: 31 / 40
    -> terrain mesh avg 2.80 ms  vegetation avg 3.19 ms
    -> revisit of an unloaded chunk 0.89 ms
    -> streaming frame max 12.15 ms, p95 11.78 ms, 0 frames over 16 ms
    -> terrain triangles 74 624 (was 184 320), shadow-casting nodes 200 (was 366)
    -> static memory 355.3 MB (was 414.7 MB)

godot --headless --path . --quit-after 300
    -> exit 0, no script/shader/error lines
```

Status of this pass: **runtime-tested headless (CPU-side)**, **implemented but
not hardware-verified** for all GPU effects (terrain LOD appearance, far-tree
impostors, water/terrain distance detail, shadow workload, quality profiles).
No FPS, GPU frame time, VRAM or real draw calls were measured: this host has no
GPU or display, and the headless dummy renderer reports zero for those monitors.
