# World rebuild: visual quality and placement rules

This change addresses the defects visible in the November 24 Android captures. It is a focused world-quality pass, not a claim that the complete world has been visually approved on a physical GPU.

## House construction and readability

- Keep the existing merged-material geometry and collision architecture.
- Tint plaster toward a warm stone/lime finish so the wall mass is visually distinct from the bright sky.
- Add visible side-wall window recesses and timber lintels, not only front/back openings.
- Keep the authored lot footprints clear of procedural tree placement.

## Vegetation

- Replace the old oversized, steeply drooping conifer cards with a tapered trunk and multiple radial branch tiers.
- Distribute branch tiers from the lower trunk through the crown, with smaller leaf clusters to preserve a full tree silhouette.
- Use a cheaper six-tier far conifer LOD that retains the same tapered silhouette.
- Prevent secondary tree clusters from bypassing road, river and building-clearance checks.
- Tree density is not increased blindly inside settlements; clear space around the authored buildings is intentional.

## Silverwater

- The old lake was a very large circular, flat disk. The new basin is a smaller, irregular ellipse to break the perfect-circle outline.
- Water shading now uses darker depth colours, lower HDRI reflection contribution, reduced white foam and higher roughness. The goal is readable water colour and a restrained reflection instead of a near-white mirror.

## Lighting and PC Ultra

- Desktop daylight is less orange and less washed out, with stronger colour separation.
- PC Ultra uses 4x MSAA, a longer directional-shadow distance and a higher sky radiance resolution.
- Android-specific renderer and performance settings remain separate; desktop Forward+ is unchanged.

## Validation limits

- Godot CI validates import, script parsing, smoke tests and CPU-side benchmark logic.
- Headless CI cannot prove 4K image quality, water appearance, wall visibility, GPU frame time or Android FPS.
- Review the same camera positions on a real PC GPU and the Vivo T4x Android device before treating visual acceptance or performance targets as achieved.
