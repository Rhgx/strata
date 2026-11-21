# Architecture

Strata is organized into six one-way layers under `src/`. Each folder only requires modules from folders listed above it, keeping dependencies acyclic and separating pure geometry math from Studio state and React UI.

```text
Core -> State -> Scene -> Actions -> Viewport -> UI
```

`default.project.json` builds the plugin as a root `Folder` named `Strata` containing `Plugin` (`src/`) and `Packages` (`Packages/`, managed by Wally: `React`, `ReactRoblox`, `StudioComponents`, and `Lucide`).

## Plugin entry

`src/init.server.luau` bootstraps and tears down the plugin:

1. Calls `restoreSettings()` to read `plugin:GetSetting("StrataSettings")` into `State/Settings` (viewport tools always start off; `pickedAxis` is stored as a 3-number JSON array `{ x, y, z }`).
2. Creates the `StrataPanel` dock widget (`Enum.InitialDockState.Right`, 280x360 initial size, 220x200 minimum size, `ZIndexBehavior.Sibling`).
3. Starts the background controllers: `Viewport/Toolbar`, `Scene/Session`, `Viewport/Activation`, `Viewport/BrushTool`, `Viewport/MaterialTool`, `Viewport/PickFaceTool`, `Viewport/StitchTool`, and `Viewport/SampleTool`.
4. Mounts `UI/App` into the dock widget via `ReactRoblox.createRoot` and `createPortal` only while `widget.Enabled` is true, so a closed panel does no work on Studio selection changes.
5. When the widget closes, stops any active viewport tool, clears any open overlay, and saves settings. On `plugin.Unloading`, saves settings, unmounts the React root, and calls every controller's stop function.

## Layers and modules

### `src/Core`

Plain Luau geometry, math, and instance serialization. No React and no Studio UI.

| Module | Responsibility |
| --- | --- |
| `src/Core/Units.luau` | Shared stud-to-Hammer scale (`16` Hammer units per stud) and Y-up to Z-up axis conversion. |
| `src/Core/Displacement.luau` | Displacement data type, surface position math, checkerboard triangulation, edge/corner indexing, power resampling (`changePower`), lossless 2x2 `split`, and `DispData` attribute serialization (`save`/`load`). |
| `src/Core/WedgeBuilder.luau` | Splits each triangle along the altitude to its longest edge into two `WedgePart`s (`THICKNESS = 0.2` studs below the surface). Names wedges `"1"`, `"2"`, ... so strokes move existing parts instead of recreating them, and unparents extra wedges instead of destroying them for undo. |
| `src/Core/TerrainInstance.luau` | Model lifecycle (`create`, `open`, `save`), the `StrataDisplacement` tag, `adoptAppearance` (syncing edits made via Studio's Properties or Material Manager), `ensureWedges`, `surfaces` (the baked unions, one per look), and CSG `bake`. |
| `src/Core/PartFaces.luau` | Extracts eligible quad faces from block `Part`s (6 faces) and wedges (3 faces: `Bottom`, `Back`, `Slope`; triangular sides skipped), selects `Top`/`TopSides`/`All` in world space, enforces `MIN_FACE_SIZE = 0.5` and `THIN_FACE_SIZE = 4`, and computes aligned tile counts across shared edges. |
| `src/Core/Paint.luau` | Spatial 3D sphere brushes (`Raise`, `Lower`, `Smooth`, `RaiseTo`), Soft/Hard falloff, six paint axes, grid-minimum effective radius, spatial hash grid for neighbor smoothing, and `heightAt` height sampling. |
| `src/Core/SurfaceRay.luau` | Two-sided Moller-Trumbore raycasting against snapshotted vertex positions so brush strokes stay anchored on the initial surface without walking toward the camera or slipping through wedge seams. |
| `src/Core/Sew.luau` | Welds shared corners (up to 16 faces), 2:1 T-junctions (up to 8 faces), and full or half edges (up to 3 faces) within 1 Hammer unit tolerance. |
| `src/Core/Stitch.luau` | Matches tile edges against nearby block/wedge part edges within reach, chooses the winning edge per part (near side, same-facing face, closest), and propagates snapped positions to coincident neighbor edges (`propagate`). |
| `src/Core/Subdivide.luau` | 4-pass Catmull-Clark style smoothing (Hammer's Subdivide, called `Round` in the UI) over selected flat base quads, writing `offsets`, `offsetNormals`, and `subdiv`. |
| `src/Core/Noise.luau` | Deterministic 3-octave value noise sampled from world positions in Hammer units and axes, applied along each vertex's field vector (or `offsetNormal` on untouched vertices). |

### `src/State`

Shared stores outside React so per-frame viewport tools read tool state directly without waiting for React renders.

| Module | Responsibility |
| --- | --- |
| `src/State/Settings.luau` | Frozen `State` table with `get`, `update`, `subscribe`, `toggleTool`, `stopViewportTool`, `setOverlay`, `stepRadius`, and `stepReach`. Clamps numeric bounds and enforces mutual exclusion across the four mouse-owning modes (`painting`, `picking`, `stitching`, `sampling`). |
| `src/State/Status.luau` | Latest operation result (`success`, `warning`, or `error`) for the status bar. `success` and `warning` expire after 6 seconds; `error` stays until dismissed or replaced. |

### `src/Scene`

Live place state and read-only scene queries.

| Module | Responsibility |
| --- | --- |
| `src/Scene/Session.luau` | Caches opened `TerrainInstance.Opened` handles per `Model`, tracks `dirty` tiles edited since their last bake, provides `updateWedges`, `bake`, and `bakeDirty`, and clears the in-memory cache on `ChangeHistoryService.OnUndo`, `OnRedo`, and `StrataDisplacement` tag removal. |
| `src/Scene/Query.luau` | Read-only selection and spatial queries: `displacementOf`, `selectedModels`, `selectedTiles`, `selectedParts`, `touchingParts`, `tilesNear`, `appearanceOf`, `selectionInfo`, and `placeInfo`. Resolves selections whether the user clicks a `TerrainArea` container, a tile model, or a child wedge/union. |

### `src/Actions`

Undoable operations. Every action runs inside a single `ChangeHistoryService` recording.

| Module | Responsibility |
| --- | --- |
| `src/Actions/Recording.luau` | Wraps actions in `ChangeHistoryService:TryBeginRecording` / `FinishRecording` (committing on success, cancelling and clearing `Session` on error) and runs `Recording.autoBake()` when `autoBake` is enabled and no viewport tool is running. |
| `src/Actions/Create.luau` | Converts selected parts or picked faces into displacement tiles grouped in `TerrainArea` models (or a standalone `Displacement` model for a single tile). Enforces `MAX_TILES_PER_PART = 400`, yields every 8 tiles, removes source parts inside the recording, and bakes flat slabs immediately when `autoBake` is on. |
| `src/Actions/Shape.luau` | Tile shape operations: `setDetail` (power change with pin remapping and optional autosew), `round` (`Subdivide`), `addNoise` (`Noise`), and `split` (lossless 2x2 split into four tiles one power lower). |
| `src/Actions/Appearance.luau` | Lists part-compatible `Enum.Material` values (excluding `Air` and `Water`) and `MaterialService` variants; applies `Material`, `Color`, and `MaterialVariant` changes straight to `DispData` and visible parts without unbaking or rebaking (yielding every 2,000 parts on large unbaked selections); provides `copyFrom` and `clearPaint` (removes painted materials from the selected tiles). |
| `src/Actions/Edges.luau` | `sewSelected`, `stitchSelected`, `previewStitch`, `stitchToPart`, `autosew`, and pin helpers (`pinsFor`, `propagatePins`, `restorePins` using `PIN_REACH = 0.1` studs) for `Keep edges stitched`. |
| `src/Actions/Bake.luau` | `bakeSelected`, `bakeAll`, `unbakeSelected`, `applySmoothing` (updates `SmoothingAngle` on every baked `Surface` in one undo step), and `bakeEdited` (auto-bakes dirty tiles when a viewport tool stops). |

### `src/Viewport`

3D viewport interaction, adornments, keyboard shortcuts, and the Studio Plugins ribbon.

| Module | Responsibility |
| --- | --- |
| `src/Viewport/Activation.luau` | Single owner of `plugin:Activate(true)` / `plugin:Deactivate()`, mouse cursor icon (`Cross` for painting, `PointingHand` for picking, stitching, and sampling), Studio tool-takeover sync, and `Esc` handling (closes Settings/Help first, otherwise stops the running tool). |
| `src/Viewport/Toolbar.luau` | Builds the `Strata` toolbar on the Plugins ribbon tab (panel toggle with theme-switched Strata logo + seven viewport tool buttons using Studio's built-in icons) and registers `PluginAction`s for `File > Advanced > Customize Shortcuts`. |
| `src/Viewport/KeyStrip.luau` | Click-through Studio-themed `ScreenGui` in `CoreGui` displaying active tool shortcuts at the bottom of the viewport. |
| `src/Viewport/BrushTool.luau` | Per-frame painting loop, `SurfaceRay` snapshots, brush cursor rings, multi-sample stroke path, modifier keys (`Ctrl`, `Shift`, `Alt + Drag`, `Alt + Right Click`, `[` / `]`), single-stroke undo recording, autosew/pin restoration on mouse up, and `Bake.bakeEdited()` on stop. |
| `src/Viewport/PickFaceTool.luau` | Raycasts eligible block/wedge faces (looking through up to 8 transparent parts), draws `BoxHandleAdornment` highlights (blue hover, amber picked) so wedge slopes align cleanly, and exposes `picks`/`clear`/`subscribe`. |
| `src/Viewport/StitchTool.luau` | Raycasts eligible parts, renders hover previews (`SelectionBox`, green target lines, amber source lines), stitches on click (one undo step per click), and bakes on tool exit. |
| `src/Viewport/MaterialTool.luau` | The Material tool: paints the chosen look into triangles under the brush (whole grid cells by default, single triangles with `Fine`), `Ctrl` to erase, `Alt + Right Click` or the panel pipette to pick up a look, one undo step per stroke, and `Bake.bakeEdited()` on stop. |
| `src/Viewport/SampleTool.luau` | Pipette mode: highlights hovered visible parts or tiles, copies `Material`, `Color`, and `MaterialVariant` onto selected tiles in one undo step, then exits. |

### `src/UI`

React-Lua dock widget panel built on `StudioComponents` and Lucide icons. See [Panel UI](ui.md) for details on `App`, `Pages/`, `Rows`, `Tooltip`/`Markup`, `Dropdown`, `ColorField`, and `ColorPicker`.
