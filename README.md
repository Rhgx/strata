# Strata

A Roblox Studio plugin for Hammer-style displacement terrain built from WedgeParts.
The output is plain parts plus a `DispData` Configuration, so a terrain model can be
published as a normal model and reopened for editing later.

## Setup

```powershell
aftman install
wally install
```

## Build

```powershell
# Build straight into the local Studio Plugins folder (Studio loads new plugin files on restart).
rojo build --plugin Strata.rbxm
```

## Layout

Each folder only requires folders listed above it, so dependencies point one way.

- `src/Core`: the terrain engine. Displacement data, math and power changes
  (`Displacement`), wedge generation (`WedgeBuilder`), the instance layout and baking
  (`TerrainInstance`), part faces (`PartFaces`), paint brushes (`Paint`), sewing (`Sew`),
  stitching to parts (`Stitch`), `Subdivide`, `Noise` and the stud to Hammer unit scale
  (`Units`). Plain Luau, no React. Behavior follows Valve Hammer; deviations are noted at the
  top of each module.
- `src/State`: shared stores outside React. `Settings` (tool options and which viewport tool
  runs) and `Status` (the latest operation result).
- `src/Scene`: what is in the place. `Session` caches opened displacements and tracks which
  need baking; `Query` answers selection and spatial questions.
- `src/Actions`: undoable operations, each one ChangeHistoryService step (`Recording`):
  `Create`, `Shape` (detail, round, noise, split), `Appearance` (material, color, variant),
  `Edges` (sew, stitch, autosew, pins) and
  `Bake`.
- `src/Viewport`: everything in the 3D view and the Studio ribbon. The viewport tools
  (`BrushTool`, `PickFaceTool`, `StitchTool`, `SampleTool` for copying a part's look), mouse
  ownership and Esc (`Activation`), the
  key hint strip (`KeyStrip`) and the ribbon buttons (`Toolbar`).
- `src/UI`: the React panel (StudioComponents, Lucide icons from `latte-soft/lucide-icons`).
  `App` picks a page from `Pages/` by the running tool and the selection; `Rows` holds the
  shared row layouts. `Dropdown` is StudioComponents' dropdown (MIT, notice in the file) with
  Studio's keyboard behavior added; `ColorPicker` follows the layout of Studio's own picker,
  including its BrickColor palette.
- `assets/logo`: the Strata logo. `strata-dark.svg` and `strata-light.svg` are the 32 px
  ribbon icons (uploaded as image assets, ids in `src/Viewport/Toolbar.luau`);
  `strata-store.svg` is the 512 px store icon. PNG renders sit next to them.
- `src/init.server.luau`: plugin entry. Restores settings, creates the dock widget and starts
  everything.
