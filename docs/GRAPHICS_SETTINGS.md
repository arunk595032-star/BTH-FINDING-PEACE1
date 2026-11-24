# Graphics Settings

BTH exposes two platform modes in the in-game **GRAPHICS** panel:

- **PC** starts with the Ultra profile.
- **Phone** starts with the Medium profile and is intended as the Android-friendly baseline.

The player can still select Ultra, High, Medium, or Low in either mode. The mode selection is a starting profile, not a hardware lock. Manual changes are saved to `user://bth_settings.cfg` and restored on the next launch.

## Manual controls

- 3D resolution scale
- Shadow distance and shadow enable/disable
- Vegetation draw distance and density
- World streaming/view radius
- Terrain detail distance
- Water detail distance
- Tree LOD distance
- MSAA (Off, 2x, 4x, 8x)
- FPS cap
- SSAO, SSIL, volumetric fog, and glow

The existing PC Ultra profile retains its original values. The Phone profile reduces selected expensive effects and distances; it does not change the project's renderer at runtime.

## Validation notes

Godot 4.7.2 headless CI validates project import, smoke tests, and the performance benchmark. It does not measure Android GPU performance or guarantee a particular FPS. Final tuning must be checked on representative Android hardware because GPU capabilities, thermal limits, screen resolution, and driver behavior vary by device.
