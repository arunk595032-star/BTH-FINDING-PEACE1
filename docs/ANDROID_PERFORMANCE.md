# Android Performance Path

## Goal

Improve frame pacing and input responsiveness on Android without changing the desktop Forward+ renderer or the PC Ultra profile.

## Current repository findings

- The project currently selects Forward+ globally.
- The Android/mobile renderer override was previously unset.
- The Phone graphics mode is a quality preset selector; it does not itself select a renderer.
- The Low preset still has real rendering costs (including shadows, glow, terrain shading, and vegetation).
- The HUD's existing `TIME_PROCESS` value is process CPU time, not GPU frame time or complete displayed-frame latency.
- Existing CI performance artifacts are headless CPU measurements. They are not Android GPU benchmarks.

## Renderer split

The project now keeps `renderer/rendering_method=forward_plus` for desktop and sets `renderer/rendering_method.mobile=mobile` for mobile platforms.

This is an isolated Android-path change. It does not change PC's renderer or Ultra profile.

The Mobile renderer has a different feature set. In particular, Forward+-only effects such as SSIL, volumetric fog, SSAO, TAA, and FSR2 are not available in the same way. The scene must be visually checked on actual Android hardware; unsupported environment effects may be omitted by the renderer. The Mobile renderer is not automatically faster for every scene, so device testing remains mandatory.

## Temporary Android touch layout

The first Android control layout is intentionally functional and replaceable:

- Left virtual joystick drives the existing move actions.
- Right-side touch drag controls the third-person camera.
- Hold RUN to use the existing sprint action.
- JUMP and USE trigger the existing jump and interaction actions.
- The legacy keyboard help panel is hidden on mobile; the existing settings entry remains available.

The touch layer is instantiated only on Android/iOS. Desktop keyboard and mouse input remain unchanged. The touch overlay is kept separate from player movement logic so a later visual redesign can replace it without rewriting gameplay controls.

## Current mobile pacing implementation

- Android is capped at 45 native rendered FPS for a consistent initial pacing target on the Vivo T4x test device.
- A mobile-only adaptive-resolution controller samples frame intervals with an EMA and hysteresis.
- When sustained frame time exceeds the 45 FPS budget, it reduces only the 3D viewport scale in 0.05 steps, down to 0.62.
- When frame pacing stays comfortably below budget for several seconds, it recovers resolution slowly in 0.025 steps, up to the selected profile's scale.
- The 2D HUD remains at the native viewport resolution.
- Mobile directional shadow atlas is 2048 instead of desktop 4096; mobile shadow filtering and anisotropic filtering are reduced through platform overrides.
- Mobile lighting uses lower HDRI energy, ambient energy and exposure, reduced fog scattering, and no glow bloom; desktop lighting values remain unchanged.
- Mobile sun uses a lower-energy neutral-warm light and two shadow splits instead of four, with a shorter shadow distance.
- Mobile foliage receives subtle fill light to keep back-facing leaf cards readable; tree MultiMeshes do not cast shadows on mobile. Desktop foliage and tree shadows remain unchanged.
- The village clearing radius is slightly smaller on mobile so a few more trees appear around the settlement edge without placing trees inside building pads.
- These are conservative controls. Dynamic resolution helps GPU-bound scenes; it cannot fix CPU-bound streaming or physics stalls.

## Frame generation / "AI frames"

There is no generic, safe AI frame-generation switch for Godot's Mobile renderer on Mali-G615-class Android devices. DLSS is not available on this Android GPU, and a shader-only frame interpolator would lack reliable engine motion/depth integration and could add latency or visual artifacts. No fake/interpolated FPS counter is added.

The current implementation prioritizes stable native frame pacing and adaptive 3D resolution. A real frame-generation integration remains a separate research task and must be evaluated on-device with latency and artifact measurements before shipping.

## Smoothness strategy

1. Establish a real-device baseline: renderer, GPU/driver, resolution, average FPS, frame-time percentiles, thermal state, memory, draw calls, and streaming spikes.
2. Keep a stable native render rate and frame pacing before considering interpolation.
3. Tune mobile shadows, vegetation density/LOD, terrain shader cost, water, and texture bandwidth based on measured bottlenecks.
4. Evaluate spatial upscaling only after confirming which scaling modes are supported by the selected renderer and device.
5. Treat frame generation as a later, optional experiment. It needs engine-level render-pipeline integration, motion/depth data, correct UI composition, and frame pacing. It is not a generic checkbox and can increase latency or artifacts when the source frame rate is low.

## Validation requirements

- Godot headless CI can validate project import, scripts, and smoke tests, but cannot validate Android GPU speed, visual parity, thermal throttling, or touch latency.
- Verify that desktop still starts with Forward+ and PC Ultra.
- Verify Android starts with the Mobile renderer and inspect the full scene for shader/effect differences.
- Compare identical routes and camera views on the same Android device before and after each optimization.
- Report native rendered FPS separately from any interpolated/displayed FPS.

## Acceptance targets (goals, not measured results)

- Stable 30 FPS floor on supported entry-level hardware.
- Stable 45 FPS target on mid-range hardware.
- 60 FPS target on capable devices.
- No claim of success until measured on physical devices over a sustained session.
