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

### Startup profiling (Phase 5)

The world build report now includes `structures_detail`: per-stage CPU timings
for village, farmland, castle, hamlet, watchtower, ruins, camp, cave, bridges,
hero props, mesh commit, and collision construction. It also records the number
of geometry material batches and collision boxes, plus the existing settlement
counts. These values are diagnostic measurements from the current run; they do
not imply that any one stage is a bottleneck until measured on the target host.

### Startup asset profiling (Phase 6)

The Phase 5 Godot 4.7.2 CI artifact measured the settlement build at 958 ms;
the `hero_props_ms` stage accounted for 692.8 ms in that run. This is a
headless CPU measurement on the CI host, not a target-device or GPU result.
The likely repeated cost was rebuilding identical convex collision hulls for
multiple instances of the same prop asset. Phase 6 caches those immutable
collision-shape resources by asset path, alongside the existing mesh cache,
and reports mesh-load and collision-shape cache/build timings in
`asset_profile`. The world report also measures `field_ms` independently
instead of duplicating the far-terrain timing.

### Quality profiles (scripts/core/quality.gd)

F1 cycles profiles at runtime; the choice is stored in `user://bth_settings.cfg`
and can be forced with `--quality=ultra|high|medium|low`.

| Setting | Ultra (default) | High | Medium | Low / mobile-class |
|---|---|---|---|---|
| 3D render scale | 1.0 | 1.0 | 0.85 | 0.75 |
| MSAA | 4x | 2x | off | off |
| Shadow distance | 520 m | 340 m | 240 m | 150 m |
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

## Latest CI validation snapshot (2026-11-24)

A separate headless run on GitHub Actions using Godot 4.7.2 completed after the
telemetry-isolation changes. This is a cloud-runner snapshot, **not an apples-to-apples
comparison** with the earlier baseline host and not a real GPU/FPS result.

| Metric | CI result |
|---|---:|
| World build total | 2,427 ms |
| Terrain mesh build average / max | 1.96 / 1.99 ms |
| Vegetation scatter average / max | 2.04 / 2.21 ms |
| Full chunk average | 0.50 ms |
| Chunk revisit average | 0.54 ms |
| Route streaming frame max / p95 | 4.55 / 4.37 ms |
| Route frames over 16 ms | 0 |
| Idle headless frame average / p95 | 6.90 / 7.06 ms |
| Static memory after streaming | 355.2 MB |
| Surface draw proxy / shadow casters | 1,209 / 200 |

The expanded smoke suite passed **41 checks, 0 failed**. Full GitHub Actions run:
https://github.com/arunk595032-star/BTH-FINDING-PEACE1/actions/runs/45380178660

The workflow now uploads `docs/perf_ci.json` as the `bth-perf-ci-report` artifact
for 14 days on future successful runs. GPU frame time, FPS, 1% lows, VRAM and visual
quality remain unmeasured because the runner is headless.

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
    -> === 40 checks, 0 failed ===   (exit 0; previously recorded run)

godot --headless --path . res://tests/perf_bench.tscn -- --label=after
    -> PERF_BENCH_DONE (exit 0)

godot --headless --path . --quit-after 300
    -> exit 0, no script/shader/error lines
```

The previously recorded 40-check run predates the telemetry-isolation regression
check. The current branch contains 41 assertions; the added check verifies that
forced bulk drains do not pollute runtime pump telemetry. The updated branch also
reports normal route-pump counts/spikes separately. GitHub Actions must pass before
these changes are described as runtime-tested. The 4 ms queue budget is a soft
target because an individual chunk build is atomic.


## World visual rebuild (November 24, 2026)

The current visual-quality pass is tracked in PR #10. It improves conifer silhouettes, house wall readability and lot clearance, Silverwater lake outline and water reflection response, and desktop daylight/PC Ultra settings. See `docs/WORLD_VISUAL_REBUILD.md` for the exact scope and validation limits. The new PC Ultra profile uses 4x MSAA, 520 m directional shadows and 512 sky radiance resolution. These settings increase GPU cost; they are intended for capable desktop GPUs and do not change the Android-specific renderer path.
