# BTH V1 - performance audit and optimization record

Baseline commit: `7e7a62db9d6a8483d4ad42e205e5ecc0f33c2059` (also pushed as the
`perf-baseline` branch and tagged `bth-v1-baseline`).
This document records what was measured, what was changed, and what is still
unverified. All numbers come from `tests/perf_bench.tscn`, run headless on the
same host for both commits (`docs/perf_baseline.json`, `docs/perf_after.json`).

## Test host - read this before quoting any number

| Item | Value |
|---|---|
| CPU | AMD EPYC 7003 (Milan), 2 vCPU visible in the container |
| GPU | **none** - `/dev/dri` and Vulkan ICD absent, no display |
| Engine | Godot 4.7.stable.official.5b4e0cb0f, Forward+ project settings |
| Renderer used for tests | **headless dummy renderer** (`--headless`) |
| OS | Ubuntu 24.04 container (cloud workspace) |

Consequences, stated plainly:

* **No FPS, GPU frame time, VRAM, real draw-call count or 1% low was measured.**
  The dummy renderer reports `RENDER_TOTAL_DRAW_CALLS_IN_FRAME = 0` and
  `RENDER_VIDEO_MEM_USED = 0`. Those fields are recorded as 0 in both JSON files.
* Every timing below is **CPU-side, headless**: GDScript, physics, MultiMesh
  setup, mesh arrays, node churn, worker-thread terrain sampling.
* "Surface draw proxy" = sum of mesh surfaces across MeshInstance3D and
  MultiMeshInstance3D nodes. It is the CPU-side upper bound for draw calls, not
  a measured GPU draw count (frustum culling and automatic batching change it).
* Visual quality was **not visually verified** - there is no GPU in this
  environment. Distance-based changes are listed under "Visual changes" so they
  can be reviewed on real hardware.

Run the harness yourself:

```bash
# baseline commit (separate worktree)
git worktree add /tmp/bth-base perf-baseline
cd /tmp/bth-base
godot --headless --path . --import
godot --headless --path . res://tests/perf_bench.tscn -- --label=baseline

# optimized build
godot --headless --path . res://tests/perf_bench.tscn -- --label=after
```

## Before / after (same harness, same host)

| Metric | Baseline | Optimized | Change |
|---|---|---|---|
| World build total | 4 674 ms | 4 033 ms | -14% |
| Far-terrain mesh build | 1 179 ms | 436 ms | **-63%** |
| Splat mask bake | 1 030 ms | 888 ms | -14% |
| Settlement build | 1 526 ms | 1 643 ms | run variance |
| Terrain chunk mesh build | **45.19 ms** | **2.80 ms** | **-94% (16x)** |
| Vegetation scatter per chunk | 16.18 ms | 3.19 ms | **-80% (5.1x)** |
| Fresh chunk load (`_load_chunk`) | **67.33 ms** | **0.66 ms** | **-99% main-thread** |
| Height lattice (worker thread) | n/a (was inside build) | 23.8 ms | off the render thread |
| Revisit of an unloaded chunk | **64.31 ms** | **0.89 ms** | **-99%** |
| Streaming frame, 95th percentile | 206.86 ms | 11.78 ms | **-94%** |
| Streaming frame, worst | **212.03 ms** | **12.15 ms** | **-94%** |
| Frames over 16 ms (30 simulated frames) | 27 | **0** | eliminated |
| Idle frame CPU, headless | 6.90 ms | 6.91 ms | unchanged |
| Terrain triangles loaded (40 chunks) | 184 320 | 74 624 | **-60%** |
| Shadow-casting nodes | 366 | 200 | **-45%** |
| Surface draw proxy | 1 257 | 1 209 | -4% |
| MultiMesh instances | 17 406 | 17 052 | -2% |
| Static memory after streaming | 414.7 MB | 355.3 MB | **-59 MB (-14%)** |
| Terrain collision shapes (full radius) | 40 | 3-12 | only near the player |

Interpretation:

* The 67.33 ms chunk load was the single worst stutter: a streaming frame that
  loaded three chunks took ~200 ms. Terrain height sampling (an analytic field,
  not a bitmap) and SurfaceTool-per-vertex meshing were the cause.
* After the change, height sampling runs on `WorkerThreadPool` tasks (~24 ms
  per chunk of wall time, off the render thread), and the main thread only
  writes mesh arrays and MultiMeshes (~6 ms). The worst simulated streaming
  frame dropped to 12.2 ms; p95 ranged 7.3-11.8 ms across runs.
* Idle CPU is unchanged because in headless mode the per-frame cost is dominated
  by the dummy renderer syncing ~1 200 surfaces / 17 000 MultiMesh instances,
  not by game scripts. That number is **not** a GPU frame time.

## What was implemented

### Terrain streaming (scripts/world/world_generator.gd, terrain_chunk.gd)

* **Height lattice cache** (LRU, 140 chunks): revisiting an area never
  re-evaluates `TerrainField.height()`.
* **Worker-thread lattice generation** (3 tasks in flight): the field is
  immutable after construction and only read by workers; results are read on the
  main thread only after `wait_for_task_completion()`.
* **Array-based meshing**: direct `PackedVector3Array` / `PackedVector2Array` /
  `PackedInt32Array` writes instead of three SurfaceTool calls per vertex
  (13 824 vertices per chunk), with analytic tangents.
* **Distance LODs** 48 / 24 / 16 quads per 128 m chunk (2.7 m / 5.3 m / 8 m) with
  a 6 m downward **skirt** so LOD boundaries cannot show gaps; collision always
  uses the full 2.7 m lattice, independent of render LOD.
* **Separate collision trimesh cache** (LRU, 96 shapes) built from the lattice
  without normals/UVs. Collision is attached only within 232 m and removed beyond
  280 m (hysteresis), one chunk per detail tick so physics never spikes.
* **Predictive, soft time-budgeted queue**: chunks within 448 m are queued,
  sorted by `distance - forward_alignment * 140`, and instantiated with a
  4 ms target and a 3-chunk cap. A chunk build is atomic: the first chunk in a
  pump is allowed to finish even if it exceeds 4 ms, after which the pump stops.
  The budget is therefore a soft target, not a hard frame-time guarantee.
* **No duplicate generation**: pending set + cache checks; unload is
  farthest-first.

### Vegetation (scripts/world/vegetation.gd)

* Per-chunk **scatter cache** (LRU, 140 chunks) storing transform arrays and
  built MultiMesh resources; a revisit rebuilds 17 MultiMesh instances but does
  not re-run placement noise.
* Slope and height come from the chunk's cached lattice instead of four extra
  analytic field evaluations per candidate.
* **Far tree LODs**: conifer/broadleaf meshes drop from ~64 cards to 9/7 cards
  plus a 5-sided trunk beyond 260 m, and stop casting shadows at that distance.
* Bushes no longer cast shadows; grass/fern/undergrowth visibility ranges are
  quality-profile driven (Ultra keeps the shipped 120/150 m).
* Per-chunk visibility ranges and fades unchanged in behaviour.

### Water and shaders (shaders/water.gdshader, terrain.gdshader, water_builder.gd)

* Water beyond 110 m keeps depth colour, sky reflection and fresnel, but skips
  the screen-space refraction sample, the second ripple layer and the foam noise
  sample. Near water is untouched.
* Terrain beyond 110 m skips the three normal-map and three ARM texture samples
  (roughness falls back to per-material constants). Albedo blending, snow, wet
  banks and roads are unchanged.
* Waterfall mist particle count and visibility range follow the quality profile;
  Ultra keeps 90 particles.

### Lighting, shadows, physics, CPU

* Terrain shadow casting kept; far-tree and bush shadow casting removed.
* Physics bodies for terrain only exist near the player (collision radius per
  profile), so distant chunks cost no broadphase work.
* HUD text rebuilds at 10 Hz instead of every frame; landmark probing at 10 Hz;
  player input uses one `Input.get_vector()` call instead of four action queries.
* Static settlement geometry was already merged per material (11 draw calls), so
  it was left untouched.

### Startup

* Far-terrain mesh: 256 -> 192 segments (8.0 m -> 10.7 m at 430+ m distance),
  built with shared-vertex arrays instead of SurfaceTool (1 179 -> 435 ms).
* Splat mask: sampled directly from the 768² rasterised grids (the mask is baked
  at exactly grid resolution, so bilinear lookups were redundant).
* Spawn loads only 5 chunks synchronously (was 13), then streams.

### Quality profiles (scripts/core/quality.gd)

F1 cycles profiles at runtime; the choice is stored in `user://bth_settings.cfg`
and can be forced with `--quality=ultra|high|medium|low`.

| Setting | Ultra (default) | High | Medium | Low / mobile-class |
|---|---|---|---|---|
| 3D render scale | 1.0 | 1.0 | 0.85 | 0.75 |
| MSAA | 2x | 2x | off | off |
| Shadow distance | 420 m | 340 m | 240 m | 150 m |
| SSAO / SSIL | on / on | on / off | on / off | off / off |
| Volumetric fog | on | on | off | off |
| Stream radius | 448 m | 400 m | 320 m | 256 m |
| Terrain LOD near/mid | 208/352 m | 184/312 m | 152/256 m | 120/208 m |
| Collision radius | 232 m | 208 m | 176 m | 144 m |
| Vegetation distance scale | 1.0 | 0.9 | 0.75 | 0.55 |
| Tree LOD distance | 260 m | 220 m | 160 m | 110 m |
| Water detail distance | 110 m | 95 m | 70 m | 50 m |

Ultra reproduces the shipped BTH V1 settings (shadow distance, vegetation
distances, SSAO/SSIL, volumetric fog, render scale). Only 3D resolution scaling
and shader detail distances are new knobs.

**Mobile is not claimed.** The project is Forward+ with volumetric fog and SSAO;
the Low profile is a scalable desktop setting, not a tested Android/iOS build.
No mobile export template, renderer switch or touch input was added.

## Visual changes (must be reviewed on a GPU)

1. Terrain beyond 208 m / 352 m uses 24 / 16 quads per chunk instead of 48.
   Skirts prevent holes, but distant ridgelines are slightly coarser.
2. Trees beyond 260 m use simplified card meshes and stop casting shadows.
3. Bushes no longer cast shadows.
4. Terrain/water beyond 110 m skip normal-map/refraction detail.
5. Far-terrain skyline mesh is 10.7 m instead of 8 m per quad.

Near-field look (player to ~100 m: terrain detail, tree silhouettes, water,
shadows, village and castle materials) is unchanged in settings.

## Remaining bottlenecks

* **Startup 4.0 s**: structures 1.64 s (GDScript box/roof generation through
  SurfaceTool), splat mask 0.89 s, far terrain 0.44 s, procedural vegetation
  meshes/props 0.73 s. All one-time; no streaming hitch.
* **Surface draw proxy ~1 200** at full 40-chunk radius (~17 000 vegetation
  instances). MultiMesh layers are per species because instances of different
  meshes cannot share one MultiMesh without changing silhouettes. Frustum
  culling reduces what is actually submitted.
* **GPU cost unmeasured**: terrain splat shader (5 albedo + 6 detail samples
  near), water shader, 4-split 4096 shadow atlas, SSAO/SSIL/volumetric fog at
  Ultra. These are the likely GPU limits on real hardware.
* **Shader compilation stutter** is unaddressed: no pre-warm pass, and it cannot
  be measured without a GPU.
* **No occlusion culling data**: Godot's occlusion culling is enabled in project
  settings but no occluder instances were baked; frustum + distance culling only.
* **Collision activation latency**: chunks get physics on the detail tick
  (0.35 s); the 232 m radius makes this invisible in normal play, but a
  teleport into a far chunk has up to 0.35 s without terrain collision (the
  spawn path and `force_detail_update()` are synchronous).
* **Soft streaming budget**: the queue checks its 4 ms target between chunks.
  A single atomic chunk instantiation (mesh + vegetation) can exceed that target;
  the target limits additional work in the same pump but cannot pre-empt a build.
* **Idle headless CPU 6.9 ms** is dummy-renderer scene sync, not script cost;
  a GPU run is required to know the real frame budget.

## Not implemented

* GPU profiling (RenderDoc, Godot profiler GPU timings), real FPS/1% lows, VRAM
  measurement.
* Texture compression changes (textures remain imported at their authored
  resolution/mip settings; no blanket downscale was applied).
* Mesh simplification of Poly Haven scanned props (they are already only ~20
  hero props; the 457-905 MB tree scans were never used).
* Occluder baking, GPU instancing beyond MultiMesh, visibility buffers.
* Mobile export, renderer switch, or touch controls.

## Test status

```
godot --headless --path . res://tests/smoke_test.tscn
    -> === 40 checks, 0 failed ===   (exit 0)

godot --headless --path . res://tests/perf_bench.tscn -- --label=after
    -> PERF_BENCH_DONE (exit 0)

godot --headless --path . --quit-after 300
    -> exit 0, no script/shader/error lines
```

The smoke test now also asserts: lattice cache identity and hit counting, LOD
agreement with distance, collision only inside the activation radius, far tree
LOD meshes exist, quality profiles apply to the live world, no recorded normal
streaming pump over 16 ms, and a 30+ chunk streaming radius. Forced bulk-drain
helpers used by tests are excluded from runtime pump telemetry. The 4 ms queue
budget is a soft target because an individual chunk build is atomic.
