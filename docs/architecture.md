# Architecture

Strata is organized into six one-way layers under `src/`. Each layer only requires modules from layers before it, keeping dependencies acyclic and separating pure geometry math from Studio state and React UI.

```text
Core -> State -> Scene -> Actions -> Viewport -> UI
```

`default.project.json` builds the plugin as a root `Folder` named `Strata` containing `Plugin` (`src/`) and `Packages` (`Packages/`, managed by Wally: `React`, `ReactRoblox`, `StudioComponents`, and `Lucide`).

## Plugin lifecycle (`src/init.server.luau`)

1. Calls `restoreSettings()` to load `plugin:GetSetting("StrataSettings")` into `State/Settings`. Viewport tools always start off; `pickedAxis` is stored as a 3-number JSON array `{ x, y, z }`.
2. Creates the `StrataPanel` dock widget (`Enum.InitialDockState.Right`, 280x360 initial size, 220x200 minimum size, `ZIndexBehavior.Sibling`).
3. Starts the background controllers: `Viewport/Toolbar`, `Scene/Session`, `Viewport/Activation`, `Viewport/BrushTool`, `Viewport/MaterialTool`, `Viewport/MeshTool`, `Viewport/RadiusPreview`, `Viewport/Input`, `Viewport/PickFaceTool`, `Viewport/StitchTool`, `Viewport/SampleTool`, and `Viewport/PointEditor`.
4. Mounts `UI/App` into the dock widget via `ReactRoblox.createRoot` and `createPortal` only while `widget.Enabled` is true, so a closed panel does no work on Studio selection changes.
5. Persisted settings are debounced (`0.3` s) on change, merging only modified keys into `plugin:GetSetting("StrataSettings")` so untouched tabs or Play sessions never clobber saved values. When the widget closes, stops any active viewport tool and Edit points, closes any open overlay, and flushes pending setting writes. On `plugin.Unloading`, flushes pending setting writes, unmounts the React root, and runs every controller's cleanup callback.

## Layers and modules

### `src/Core`

Plain Luau geometry, math, and instance serialization. No React and no Studio UI.

| Module | Responsibility |
| --- | --- |
| `Units.luau` | Stud-to-Hammer scale (`16` Hammer units per stud) and Y-up to Z-up coordinate conversion ([Hammer mapping](hammer.md)). |
| `Displacement.luau` | Displacement data type, surface position math, checkerboard triangulation, edge/corner indexing, power resampling (`changePower`), lossless 2x2 `split`, and `DispData` serialization (`save`/`load`) ([Data format](data-format.md)). |
| `WedgeBuilder.luau` | Splits each shown triangle along the altitude to its longest edge into two `WedgePart`s (`THICKNESS = 0.2` studs below the surface). Names wedges `"1"`, `"2"`, ... so strokes reuse parts in place, and unparents extra wedges instead of destroying them for undo safety. |
| `TerrainInstance.luau` | Tile model lifecycle (`create`, `open`, `save`), `StrataDisplacement` tag, `adoptAppearance`, `ensureWedges`, `surfaces`, and CSG `bake` ([Baking](baking.md)). |
| `PartFaces.luau` | Extracts quad faces from block `Part`s (6 faces) and wedges (3 faces: `Bottom`, `Back`, `Slope`; triangular sides skipped), filters `Top`/`TopSides`/`All` in world space, enforces `MIN_FACE_SIZE = 0.5` and `THIN_FACE_SIZE = 4`, and computes aligned tile counts across shared edges. |
| `Paint.luau` | Spatial 3D sphere brushes (`Raise`, `Lower`, `Smooth`, `RaiseTo`), `Soft`/`Hard` falloff, six paint axes, `preview` (kept points inside the ring with falloff weights, or nearest kept points when empty), `gridSpacing`, spatial hash grid for neighbor smoothing, and `heightAt` height sampling. |
| `Simplify.luau` | Finds removable vertices that preserve surface shape: `flatPoints` (greedy, one triangulation per candidate; used by the Mesh tool's `Select flat`) and `flatPointsQuick` (batch removal by angle or height tolerance plus straight-edge reduction and repair loop; used during baking). |
| `Mesh.luau` | Builds a deterministic Delaunay triangulation of kept vertices on the flat grid (Bowyer-Watson from the 4 corners, ties broken toward Hammer's checkerboard diagonal), mapping each shown triangle to the grid triangles it covers and each removed point to its spot on the surface. |
| `SurfaceRay.luau` | Two-sided Moller-Trumbore raycasting against snapshotted vertex positions so strokes stay anchored on the initial surface without walking toward the camera or slipping through wedge seams. |
| `Sew.luau` | Welds shared corners (up to 16 faces), 2:1 T-junctions (up to 8 faces), and full or half edges (up to 3 faces) within 1 Hammer unit per axis. |
| `Stitch.luau` | Matches tile edges against nearby block/wedge part edges within reach: drops interior edges shared by adjacent parts (matching wedge floors as one outline), filters edges whose side face faces back at the tile edge, handles bends, picks per vertex, and propagates snapped positions to coincident neighbor edges (`propagate`). `sheet` finds connected parts from a clicked part. |
| `Subdivide.luau` | 4-pass Catmull-Clark style smoothing (Hammer's Subdivide, labeled `Round` in the UI) over selected flat base quads, writing `offsets`, `offsetNormals`, and `subdiv`. |
| `Noise.luau` | Deterministic 3-octave value noise sampled from world positions in Hammer units and axes, applied along each vertex's field vector (or `offsetNormal` on untouched vertices). |

### `src/State`

Shared stores outside React so per-frame viewport tools read tool state directly without waiting for React renders.

| Module | Responsibility |
| --- | --- |
| `Settings.luau` | Frozen `State` table with `get`, `update`, `subscribe`, `toggleTool`, `stopViewportTool`, `setEditingPoints`, `setOverlay`, `stepRadius`, and `stepReach`. Clamps numeric bounds and enforces mutual exclusion across the six mouse-owning modes (`painting`, `coloring`, `meshing`, `picking`, `stitching`, `sampling`) and `editingPoints`, which never takes the mouse and so is left running when Studio's own tools take it back. |
| `KeyCapture.luau` | Tracks panel keyboard focus (such as an open `Dropdown`). While held, `Input.onKey` yields keys to the panel so `Esc` closes a list without stopping the active tool and `Enter` picks an item without triggering a viewport action. |
| `Status.luau` | Latest operation status (`success`, `warning`, `error`, or progress) for the status bar. `success` and `warning` expire after 6 seconds; `error` stays until dismissed or replaced. |
| `Format.luau` | Shared formatting helpers for panel labels, status messages, and 3D overlays: comma-grouped counts, plurals, stud lengths (`Format.studs`), and color hex / `"R, G, B"` parsing. |

### `src/Scene`

Live place state and read-only scene queries.

| Module | Responsibility |
| --- | --- |
| `Session.luau` | Caches opened `TerrainInstance.Opened` handles per `Model`, tracks `dirty` tiles edited since their last bake, provides `updateWedges`, `updateMoved` (restores removed points moved by exact edits such as `Stitch` and `Round`), `bake`, and `bakeDirty`, and invalidates its cache on `ChangeHistoryService.OnUndo`, `OnRedo`, and `StrataDisplacement` tag removal. |
| `Query.luau` | Read-only selection and spatial queries: `workingModels` (selected tiles when `Selected only` is on, otherwise all tiles), `displacementOf`, `selectedModels`, `selectedTiles`, `selectedParts`, `touchingParts`, `tilesNear`, `appearanceOf`, `selectionInfo`, and `placeInfo`. Resolves selections from a `TerrainArea` container, a tile model, or any child wedge/union. |
| `MeshStage.luau` | Holds points staged in the Mesh tool's `Simplify` mode before `Apply`, with a cached preview triangulation per tile and before/after triangle counts. Clears on undo, redo, mode change, or tool stop. |

### `src/Actions`

Undoable operations. Every action runs inside a single `ChangeHistoryService` recording.

| Module | Responsibility |
| --- | --- |
| `Recording.luau` | Wraps actions in `ChangeHistoryService:TryBeginRecording` / `FinishRecording` (committing on success, cancelling and clearing `Session` on error) and runs `Recording.autoBake()` when `autoBake` is on and no tile-editing tool is active (`Settings.editing`: every tool except `Pick faces`, plus Edit points). Editing tools defer baking until the last one stops, avoiding bake/unbake churn when switching tools. |
| `Create.luau` | Converts selected parts or picked faces into tiles grouped in `TerrainArea` models (or a standalone `Displacement` model for one tile). Enforces `MAX_TILES_PER_PART = 400`, yields every 8 tiles, removes source parts inside the recording, and bakes flat slabs immediately when `autoBake` is on. |
| `Shape.luau` | Tile shape operations: `setDetail` (power change with pin remapping and optional autosew), `round` (`Subdivide`), `addNoise` (`Noise`), and `split` (lossless 2x2 split into four tiles one power lower). |
| `Appearance.luau` | Lists part-compatible `Enum.Material` values (excluding `Air` and `Water`) and `MaterialService` variants; applies `Material`, `Color`, and `MaterialVariant` straight to `DispData` and visible parts without unbaking or rebaking (yielding every 2,000 parts on large unbaked selections); provides `copyFrom`, `clearPaint`, and `restoreHoles`. |
| `Edges.luau` | `sewSelected`, `stitchSelected`, `previewStitch`, `stitchToPart`, `autosew`, `movePoints` (moves points to exact positions for Edit points, with coincident neighbor points following, 2:1 points interpolated, and simplified seams kept closed), `closeRemovedSeams` (pulls a neighbor's vertex onto a simplified tile's straight edge), `seamTwins`, and pin helpers (`pinsFor`, `propagatePins`, `restorePins` using `PIN_REACH = 0.1` studs) for `Keep edges stitched`. |
| `Mesh.luau` | Two-phase simplification and point restoration: `selectFlat` (stages flat points within `Max angle` with yielding and abort checks), `markRestoreAll`, `applyMarks` (mirrors seam marks across neighbors and commits in one undo step), `restorePoints` (immediate restore from the Tiles page), `removePoints` (immediate removal when Edit points handles are deleted), `finish`, and `scope`. |
| `Bake.luau` | `bakeSelected`, `bakeAll`, `rebakeAll` (rebakes every tile in one undo step so updated bake options apply), `unbakeSelected`, `applySmoothing` (updates `SmoothingAngle` on all baked unions in one undo step, skipping plain `Part` surfaces), and `bakeEdited` (auto-bakes dirty tiles when the last editing tool stops). Posts `Baking i of N...` progress, reports triangle savings via `report`, and refuses concurrent bakes. |

### `src/Viewport`

3D viewport interaction, adornments, keyboard shortcuts, and the Studio Plugins ribbon.

| Module | Responsibility |
| --- | --- |
| `Activation.luau` | Single owner of `plugin:Activate(true)` / `plugin:Deactivate()`, `mouse.Icon` updates, Studio tool-takeover sync (a `0.1` s grace window avoids stopping a newly clicked ribbon tool), and `Esc` handling via `Input.onKey`. |
| `Toolbar.luau` | Creates the `Strata Terrain` Plugins ribbon toolbar (using the theme-switched logo; Studio hides toolbars whose name matches the plugin name) and registers `PluginAction`s for all eight tools and Edit points under `File > Advanced > Customize Shortcuts`. When `ribbonTools` is on, creates a `Strata Tools` group once per session (turning it off disables the buttons until Studio restarts, since Studio cannot remove ribbon buttons at runtime). |
| `KeyStrip.luau` | Click-through Studio-themed `ScreenGui` in `CoreGui` showing active tool shortcuts at the bottom of the viewport. |
| `BrushTool.luau` | Per-frame sculpt loop, `SurfaceRay` snapshots, brush cursor rings with `Paint.preview` point dots (and dimmed empty-ring state with nearest-point dots), multi-sample stroke paths, modifier keys, single-stroke undo recording (cancelling strokes whose points are all pinned to parts), autosew/pin restoration on mouse up, and `Bake.bakeEdited()` on stop. |
| `MaterialTool.luau` | Paints looks into triangles under the brush (whole grid cells by default, single triangles with `Fine`), erases with `Ctrl`, picks looks with `Alt + Right Click` or the panel pipette, records one undo step per stroke, and calls `Bake.bakeEdited()` on stop. Never fills holes. |
| `MeshTool.luau` | Runs `Simplify` (drag to stage points, click to toggle nearest point, preview new edges, commit via `Actions/Mesh.applyMarks`) and `Cut holes` (drag to delete or `Ctrl` to restore triangles, aiming via `SurfaceRay` with holes included and outlining hovered holes). |
| `PickFaceTool.luau` | Raycasts eligible block/wedge faces, draws `BoxHandleAdornment` highlights (blue hover, amber picked), exposes `picks`/`clear`/`subscribe`, and creates tiles on `Enter` via `Create.createPicked`. |
| `StitchTool.luau` | Raycasts eligible parts, renders hover previews (`SelectionBox`, green target lines, amber source lines), stitches on click (one undo step per click), and bakes on stop. |
| `PointEditor.luau` | Edit points: one Ball handle per editable point of the chosen tiles (shared seam points share one; points removed by Simplify, all-hole points, and 2:1 midpoints get none), moved with Studio's own Select, Move, Rotate, and Scale tools. See [Edit points](#edit-points) below. |
| `SampleTool.luau` | Pipette mode for the Tiles page: highlights hovered visible parts or tiles, copies `Material`, `Color`, and `MaterialVariant` onto selected tiles in one undo step, then exits. |
| `Input.luau` | Shared viewport and panel input: modifier tracking while the panel has focus (transparent listener frame over the widget), unified `onKey` signal (skipping focused text boxes), `beginDragResize` / `dragRadius` for `Alt + Drag`, and `connectResize` for `Ctrl + Scroll` and `[` / `]` while holding Studio's edit camera still briefly. |
| `RadiusPreview.luau` | Draws a ~1 second brush ring and `Radius N st` label at the center of the 3D view whenever `Radius` changes in the panel; ends immediately on mouse movement over the viewport. Provides `newRing` for tool cursors. |
| `TriangleOutline.luau` | Draws the outer perimeter of the exact shown triangles a Material or Cut holes click will affect (blue to paint, red to erase or cut, green to restore). |
| `Cursor.luau` | Holds the running tool's per-frame cursor hint (`resize`, `empty`, `valid`, `invalid`), cleared on tool switches and mapped to `mouse.Icon` by `Activation`. |
| `TileHit.luau`, `TriangleBrush.luau`, `Lines.luau`, `VisibleHit.luau` | Shared viewport helpers: ray-to-tile/shown-triangle hit lookup, triangle brush coverage and look writes, pooled world-space line adornments, and first-visible-part raycasting (looking through invisible parts). |

### `src/UI`

React-Lua dock widget panel built on `StudioComponents` and Lucide icons. See [Panel UI](ui.md) for layout, shortcuts, `Rows` helpers, tooltips, `Dropdown`, and `ColorPicker`.

## Edit points

`Viewport/PointEditor` lets users move single points with Studio's own tools instead of a Strata brush. Its design follows from how Studio behaves (measured in Studio while building it):

- **Handles are never saved or undone.** They live in a `StrataPoints` folder in `workspace`; folder and handles are not `Archivable`, so they never save into the place, and Studio leaves non-archivable parts out of undo history. Each rebuild fills a new unparented `Handles` folder and inserts it at once, so Studio (the Explorer in particular) handles one insertion instead of thousands.
- **Every terrain change is our own recording.** Studio's draggers do not record; they call `ChangeHistoryService:SetWaypoint` when a drag ends, and plugin signals arrive deferred, so a drag's last frame can land after that waypoint. Writing unrecorded changes would therefore leak a frame into the next undo step, and a one-shot Properties edit would merge into the user's next action. Instead, handle `CFrame` changes mark handles dirty, and one `Heartbeat` flush per frame writes them inside `TryBeginRecording("Strata move points")`: the first flush of a burst commits a new step and later ones (within `0.35` s, while that step is still on top) append to it. With handles untracked, the dragger's own waypoint stays empty and adds no step. A busy recording (a bake, another action) leaves the handles dirty for the next frame.
- **The terrain is authoritative.** On undo or redo, `Session` reopens tiles from `DispData` and the handles move back onto their points; a changed point layout (undo past `Detail`, `Simplify`, or `Restore points`, or a deleted tile) rebuilds them, keeping selected points selected.
- **The pivot sits on the point.** Each Ball rests on the surface with `PivotOffset` putting its pivot on the point, and the point follows the pivot (always computed with the handle's own offset, so editing the pivot never moves a point). Studio's freeform drag rests a part's bounds on the surface under the cursor, so a handle centered on its point would climb with every mouse move over its own tile. Exact coordinates are under `Pivot > Origin` in Properties.
- **Orientation is locked.** Each handle keeps a frame built from its tile: `up` is the face normal (averaged over the tiles sharing the point, so a seam handle sits outside both) and `right` follows the tile's first grid edge, so Local-space gizmos move along the tile normal and grid. Rotating a group still swings its points around the group's center. A handle that changed (rotation, `Size`, or `PivotOffset`) is put back once it has been still for `0.12` s, never mid-drag, so Studio's Rotate and Scale tools are not fought. A rotation that moved no point (a single handle, or `Orientation` in Properties, which turns a part around its center) is rejected: the point stays, the handle flashes red, and the status bar explains.
- **Seams stay closed.** Points shared by edited tiles share a handle; neighbors outside the edit follow through `Edges.movePoints`, which reuses `Stitch.propagate` and `closeRemovedSeams`. Stitch pins and autosew are not applied, so a deliberate move is never snapped back.
- **Deleting handles removes points.** Handles deleted with `Delete` or `Cut` are collected and removed through `MeshActions.removePoints` (the Mesh tool's Simplify, mirrored across seams), then the handles rebuild. Studio's Delete is still recording when the handles go, so the removal waits for that recording to finish (up to `5` s) and then appends to Studio's `DeleteSelectedAction` step, which Studio adds even for untracked handles: one `Ctrl + Z` brings the points back. A point that is a corner of any tile always stays and gets its handle back.
- **The selection stays on handles.** A selection containing any handle is narrowed to handles only, so box selecting points never drags the terrain, a `TerrainArea`, or nearby parts with them. Grouping handles or moving them out of their folder rebuilds them; deleting the top folder ends Edit points. Removal events are matched against the current handles, never a flag, because deferred signals arrive after our own cleanup has finished.
- **Limits.** At most `2500` handles at once. Ball size follows the grid spacing (`0.3` of it, clamped to `0.15` to `0.8` studs). In Team Create, other editors can see the handle folder while someone edits points.
