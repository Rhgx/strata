<img src="assets/logo/strata-store.png" alt="Strata logo" width="128">

# Strata

Strata is a Roblox Studio plugin by Rocks for Valve Hammer-style displacement terrain built from `WedgePart` geometry. Each tile stores its editable displacement data in a `DispData` `Configuration` and bakes its wedges into a single `UnionOperation` for seamless material projection, so terrain models can be published like any normal Roblox model and reopened for editing later. This repository is private.

## Features

- **Create terrain**: convert selected block `Part`s and wedges (`Top`, `Top + sides`, or `All faces`) into tiled displacements, or pick individual faces in the 3D view with the Pick faces tool.
- **Sculpt**: shape terrain with `Raise`, `Lower`, `Smooth`, and `Raise To` brushes across tile boundaries, with Soft or Hard falloff, six movement axes (`Face normal`, `Up (Y)`, `X`, `Z`, `Picked`, and `Curved (Round)`), and viewport shortcuts (`Ctrl`, `Shift`, `Ctrl + Scroll`, `Alt + Drag`, `Alt + Right Click`).
- **Stitch to parts**: snap tile edges onto nearby roads, floors, walls, and wedge ramps within a configurable reach, and keep stitched edges pinned across subsequent edits.
- **Sew**: weld shared corners, 2:1 T-junctions, and edges between neighboring tiles manually or automatically after edits.
- **Shape tiles**: change tile detail (power 2, 3, or 4: 5x5, 9x9, or 17x17 vertices), smooth base quads across seams with `Round` (Hammer's Subdivide), apply deterministic `Noise`, and `Split 2x2` losslessly into four smaller tiles one power lower.
- **Paint materials**: paint a material, color and variant into parts of a tile with the `Material` tool (a road through grass, a rock patch on a slope), in whole grid cells or single triangles; `Ctrl` erases. Each look bakes into its own union, so painted areas keep their own texture.
- **Appearance**: set tile `Material`, `Color` (RGB, HSV, Hex, and Studio's BrickColor palette), and `MaterialVariant`, or copy a look from any part or tile with the pipette tool.
- **Bake and reopen**: merge wedges into a `UnionOperation` (automatically or on demand) with configurable `SmoothingAngle`, and bring wedges back automatically whenever a baked tile is edited again.

## Quick start

### Installing the plugin

1. Build `Strata.rbxm` (see below) or copy a built `Strata.rbxm` into your local Roblox Studio Plugins folder.
2. Restart Roblox Studio.
3. Open the **Strata** panel from the **Plugins** ribbon tab, or launch any of the seven viewport tools directly from the ribbon (all seven also register plugin actions under `File > Advanced > Customize Shortcuts`).

### Developing and building

Strata uses [Aftman](https://github.com/LPGhatguy/aftman) for toolchain versions (`aftman.toml`: Rojo 7.7.1, Wally 0.3.2) and [Wally](https://wally.run) for Luau dependencies (`wally.toml`: React, ReactRoblox, StudioComponents, Lucide).

```powershell
aftman install
wally install
```

Build the plugin straight into your local Studio Plugins folder:

```powershell
# Build straight into the local Studio Plugins folder (Studio loads new plugin files on restart).
rojo build --plugin Strata.rbxm
```

## Documentation

Technical documentation for the codebase lives in [`docs/`](docs/README.md):

- [Documentation index](docs/README.md): overview of the docs and logo assets.
- [Architecture](docs/architecture.md): one-way layer structure (`Core -> State -> Scene -> Actions -> Viewport -> UI`), module responsibilities, and plugin lifecycle.
- [Data format and instance layout](docs/data-format.md): `DispData` attributes, vertex math, model hierarchy, and the `StrataDisplacement` tag.
- [Baking](docs/baking.md): why tiles bake, the flat slab fast path, the anchor cube trick, two-step CSG, collision fidelity, and smoothing angle.
- [Hammer mapping and deviations](docs/hammer.md): how Strata maps Valve Hammer displacement concepts and where it deliberately differs.
- [Panel UI](docs/ui.md): context-driven panel layout, `Rows` helpers, tooltip markup, custom `Dropdown`, and `ColorPicker`.
