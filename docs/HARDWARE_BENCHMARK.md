# BTH hardware benchmark

The headless GitHub Actions benchmark validates project import, CPU-side world
construction, streaming, mesh generation, vegetation and memory. It cannot measure
real display FPS, 1% lows, GPU frame time or VRAM usage.

To capture a hardware run, use the project on a machine with a real display and GPU.
Run from the repository root, without `--headless`:

```bash
godot --path . res://tests/perf_bench.tscn -- --label=hardware
```

The benchmark waits for the world to settle, performs the same deterministic route
stress test, then samples **600 displayed process-frame intervals** by default.
The result is written to `docs/perf_hardware.json`.

For a longer sample:

```bash
godot --path . res://tests/perf_bench.tscn -- --label=hardware --frames=1200
```

## Metrics

- Average frame interval and p50 / p95 / p99 / maximum frame intervals.
- Estimated average FPS and estimated 1% low (reciprocal of p99 frame interval).
- Per-frame draw-call and render-object counts, plus video, texture and buffer memory monitors (average, p95 and maximum across the sample window).
- Video adapter, renderer, engine version, world startup, streaming and memory data.

The FPS and 1% low values are frame-pacing estimates, not isolated GPU timings. Render-monitor statistics are sampled across the same window rather than taken from one final frame. In headless mode these monitor statistics are marked unavailable and must not be interpreted as hardware measurements.
The headless runner deliberately writes `null` for FPS and 1% low rather than
presenting dummy-renderer timing as real performance. GPU frame time still needs a
GPU profiler such as RenderDoc or the vendor's profiling tools. The benchmark always reports `gpu_frame_time_available: false`; a non-headless run enables render-monitor sampling, not GPU-time measurement.

For a meaningful report, record the GPU model, driver version, CPU, resolution,
render scale, quality profile, and whether VSync is enabled. Compare runs at the
same resolution and quality profile. Keep the generated JSON with the report.

