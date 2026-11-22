<h1><picture><source media="(prefers-color-scheme: dark)" srcset="assets/logo/strata-dark.svg"><source media="(prefers-color-scheme: light)" srcset="assets/logo/strata-light.svg"><img src="assets/logo/strata-light.svg" alt="" width="32" height="32" align="absmiddle"></picture> Strata</h1>

Strata is a Roblox Studio plugin by Rocks for Valve Hammer-style displacement terrain built from `WedgePart` geometry. Each tile stores its editable data in a `DispData` `Configuration` and bakes into `UnionOperation` parts (one per look) for seamless material projection, so terrain models publish and reopen like normal Roblox models. This repository is private.

## Features

- **Create terrain**: convert selected block and wedge parts into tiled displacements, or pick individual faces in 3D with `Pick faces`.
- **Sculpt**: shape terrain across tile seams with `Raise`, `Lower`, `Smooth`, and `Raise To` brushes, configurable falloff, and multiple movement axes ([Hammer mapping](docs/hammer.md), [Panel UI](docs/ui.md)).
- **Paint materials**: paint roads, paths, and surface patches onto tiles by grid cell or single triangle; each look bakes into its own union ([Data format](docs/data-format.md)).
- **Stitch and sew**: snap tile edges onto nearby block or wedge parts (including wedge floors) and keep them pinned across edits, or weld seams between neighboring tiles automatically or on demand ([Hammer mapping](docs/hammer.md)).
- **Shape tiles**: change tile detail (`Low 5x5`, `Medium 9x9`, `High 17x17`), smooth folded seams with `Round`, apply deterministic `Noise`, or `Split 2x2` losslessly into smaller tiles.
- **Mesh density and holes**: simplify flat areas into fewer, larger triangles (manually or with `Auto-simplify`) and cut holes for paths or openings, with lossless restore ([Data format](docs/data-format.md)).
- **Edit points**: put a handle on every point of the selected tiles and move single points with Studio's own Move, Rotate, and Scale tools (or delete them), with seams kept closed ([Architecture](docs/architecture.md#edit-points)).
- **Appearance**: change a tile's base `Material`, `Color`, or `MaterialVariant` without unbaking, or copy a look from any part or tile with the pipette ([Panel UI](docs/ui.md)).
- **Bake and reopen**: merge wedges into unions automatically or on demand with configurable smoothing and bake optimizations, and restore wedges automatically on the next edit ([Baking](docs/baking.md)).

## Quick start

### Install

1. Build `Strata.rbxm` (see below) or copy a built `Strata.rbxm` into your local Roblox Studio Plugins folder.
2. Restart Roblox Studio.
3. Open **Strata** from the **Plugins** ribbon tab. The panel's tool strip holds all eight viewport tools. Enable **Settings > Interface > Tools on Plugins ribbon** to mirror them on the ribbon (all eight also register actions under `File > Advanced > Customize Shortcuts`).

### Build from source

Strata uses [Aftman](https://github.com/LPGhatguy/aftman) for toolchain versions (`aftman.toml`: Rojo 7.7.1, Wally 0.3.2) and [Wally](https://wally.run) for Luau packages (`wally.toml`: React, ReactRoblox, StudioComponents, Lucide).

```powershell
aftman install
wally install
```

Build straight into your local Studio Plugins folder (Studio loads new plugin files on restart):

```powershell
rojo build --plugin Strata.rbxm
```

## Documentation

Technical documentation lives in [`docs/`](docs/README.md):

| Page | Covers |
| --- | --- |
| [Documentation index](docs/README.md) | Overview of pages and brand/icon assets |
| [Architecture](docs/architecture.md) | Six-layer structure (`Core -> State -> Scene -> Actions -> Viewport -> UI`), module map, and plugin lifecycle |
| [Data format](docs/data-format.md) | `DispData` attributes, vertex math, model layout, painted looks, holes, and mesh simplification |
| [Baking](docs/baking.md) | Texture projection, flat slab fast path, anchor cube alignment, two-step CSG, and bake optimizations |
| [Hammer mapping](docs/hammer.md) | Unit scale, Valve Hammer equivalents, Strata additions, and intentional deviations |
| [Panel UI](docs/ui.md) | Panel layout, viewport shortcuts, color system, `Rows` helpers, `Dropdown`, and `ColorPicker` |
