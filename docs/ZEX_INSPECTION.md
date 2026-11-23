# ZEX Map Editor - inspection report

The editor shipped inside `new-game-project.zip` and is preserved at
`tools/zex_map_editor/` (with a `.gdignore` so the BTH project does not import it).
It is **MIT licensed** (`tools/zex_map_editor/LICENSE`, © 2026 Zex Interactive / Paras Sharma).

## What it is (source inspection)

| Property | Finding |
|---|---|
| Target engine | Godot **4.3** (`project.godot`: `config/features=PackedStringArray("4.3","Mobile")`) |
| Renderer | **Mobile**, touch-first, landscape, `emulate_touch_from_mouse` |
| Architecture | A *runtime* map editor: `scenes/editor.tscn`, no `@tool` plugin |
| Terrain | 50 x 50 m plates, up to 31 x 31, per-tile mesh with an 8-layer splat shader |
| Sculpt tools | raise / lower / smooth / flatten / rough / level-to-height, radius-strength-hardness |
| Paint | 8 layers in a `Texture2DArray`, splat tiles at ~1 px/m, smart slope brush |
| Water | lake (flood fill), ocean, pool; depth baked into vertex colour, GTA-style presets |
| Routes | road / rail / river / object lines on Catmull-Rom curves; "apply to terrain" levels + paints / carves |
| Vegetation | scatter brush with slope/height/water/road rules, spacing, remove brush |
| Export | GLB of terrain+objects, heightmap (r16), splat PNG, objects.json |
| Tests | `tools/selftest.gd` + `tools/shot*.gd`, run under `xvfb-run` with `gl_compatibility` |

## Why it is not used as the BTH world builder

1. **Version/renderer mismatch.** The editor is pinned to 4.3/Mobile and its own project; BTH is
   4.7/Forward+. Importing its scenes into the BTH project would drag a second `project.godot`
   and Mobile renderer assumptions into the game.
2. **Scale.** ZEX works on 50 m ground plates (max 31 x 31 = 1 550 m). BTH needs a 2 048 m
   continuous landscape with a mountain wall, a 3.5 km river system, road grading and
   settlement pads. Plate-based tiles would mean seams across the whole valley.
3. **Runtime editor, not a runtime world.** Using it would mean the deliverable is an editor
   map, not the playable BTH game. The task explicitly forbids replacing the game with the editor.
4. **No execution verification possible here.** Its documented test command requires
   `xvfb-run` + OpenGL, and this container has no display, no GPU and no permission to install
   X/Mesa. Only static inspection was possible, so I did not claim it works.

## What BTH borrowed from it (MIT, credited)

* The **8-layer splat-mask idea** is reproduced in `shaders/terrain.gdshader`, but instead of
  one material per 50 m plate it samples a single 768 px world-space mask
  (`TerrainField.write_world_mask()`), so the whole 2 km map shares one material and no seams.
* The **depth-baked, GTA-style water** idea (shallow/mid/deep ramp + shoreline foam) is
  reimplemented in `shaders/water.gdshader` with screen-space depth reconstruction and an
  equirectangular HDRI reflection instead of its vertex-colour depth.
* The **distance-based loading** idea is generalised into 128 m chunks with a per-frame
  budget (`world_generator.gd`: `STREAM_RADIUS`, `_pending`, `CHUNK_BUDGET_PER_FRAME`) plus a
  coarse far-terrain mesh for the skyline.

No ZEX source file is imported, executed or modified by the BTH project; the folder is
reference material only.
