# Architecture

Strata's six-layer module structure, plugin lifecycle, and Edit points internals.

## Contents

[Plugin lifecycle](#plugin-lifecycle) | [Layers and modules](#layers-and-modules) | [Edit points](#edit-points)

## Layer order

Modules under `src/` form six one-way layers. Each layer only requires modules from earlier layers, keeping dependencies acyclic and separating pure math from Studio state and React UI.

```text
Core -> State -> Scene -> Actions -> Viewport -> UI
```

`default.project.json` builds a root `Folder` named `Strata` containing `Plugin` (`src/`) and `Packages` (`Packages/`, managed by Wally: React, ReactRoblox, StudioComponents, Lucide). `src/Version.luau` holds the plugin release version string.

## Plugin lifecycle

Source: `src/init.server.luau`

1. **Restore settings**: loads `plugin:GetSetting("StrataSettings")` into `State/Settings` (viewport tools always start off; `pickedAxis` deserializes from a 3-number JSON array).
2. **Create dock widget**: builds `StrataPanel` (`InitialDockState.Right`, 280x360 initial, 220x200 minimum, `ZIndexBehavior.Sibling`).
3. **Start controllers**: mounts `Viewport/Toolbar`, `Scene/Session`, `Viewport/Activation`, `BrushTool`, `MaterialTool`, `MeshTool`, `RadiusPreview`, `Input`, `PickFaceTool`, `StitchTool`, `SampleTool`, and `PointEditor`.
4. **Mount panel on demand**: mounts `UI/App` via `ReactRoblox.createRoot` and `createPortal` only while `widget.Enabled` is true, so a closed panel ignores selection changes.
5. **Persist settings**: debounces dirty setting keys (`0.3` s) and merges only changed keys into `StrataSettings`, so untouched tabs or Play sessions never clobber newer values.
6. **Shut down**: closing the widget stops active tools/overlays and flushes pending setting writes. `plugin.Unloading` flushes writes, unmounts React, and runs every controller cleanup callback.

## Layers and modules

### `src/Core`

Pure Luau geometry, math, and serialization. No React and no Studio UI.

| Module | Purpose |
| --- | --- |
| `Units.luau` | Stud-to-Hammer scale (`16` Hammer units/stud) and Y-up to Z-up conversion |
| `Displacement.luau` | Displacement data model, surface math, resampling, split, and `DispData` IO |
| `WedgeBuilder.luau` | Two-wedge triangle mesh builder (`THICKNESS = 0.2` studs below surface) |
| `TerrainInstance.luau` | Tile lifecycle (`create`, `open`, `save`), naming, `adoptAppearance`, and CSG `bake` |
| `PartFaces.luau` | Quad face extraction from blocks and wedges, filtering, and aligned tile counts |
| `Paint.luau` | 3D sphere sculpt brushes, falloff, six paint axes, preview, and height sampling |
| `Simplify.luau` | Flat-vertex removal (`flatPoints` for Mesh tool, `flatPointsQuick` for baking) |
| `Mesh.luau` | Deterministic Bowyer-Watson Delaunay triangulation of kept vertices |
| `SurfaceRay.luau` | Two-sided Moller-Trumbore raycasting against snapshotted triangles |
| `Sew.luau` | Seam welding for corners, 2:1 T-junctions, and shared edges |
| `Stitch.luau` | Part-edge matching, interior edge removal, inside-corner closing, and propagation |
| `Subdivide.luau` | 4-pass Catmull-Clark style smoothing (labeled **Round folds** in the UI) |
| `Noise.luau` | Deterministic 3-octave world-space value noise |

Notes:
- `WedgeBuilder` names wedges `"1"`, `"2"`, ... to reuse parts in place and unparents excess wedges instead of destroying them for undo safety.
- `PartFaces` enforces `MIN_FACE_SIZE = 0.5` and `THIN_FACE_SIZE = 4` studs; triangular wedge sides are skipped.
- `Sew` welds corners (up to 16 faces), 2:1 T-junctions (up to 8), and edges (up to 3) within 1 Hammer unit per axis.

### `src/State`

Shared stores outside React so per-frame viewport tools read state directly.

| Module | Purpose |
| --- | --- |
| `Settings.luau` | Frozen settings store, bounds clamping, and tool mutual exclusion |
| `KeyCapture.luau` | Tracks panel keyboard focus (e.g. open dropdowns) so viewport shortcuts yield |
| `Status.luau` | Timed status messages (`success`, `warning`, `error`, `progress` with cancel) |
| `Format.luau` | Shared formatting for counts, plurals, stud lengths, and hex/RGB colors |

Notes:
- `Settings` keeps the six mouse-owning modes (`painting`, `coloring`, `meshing`, `picking`, `stitching`, `sampling`) mutually exclusive while leaving `editingPoints` independent.
- `Status` expires `success` after 6 s and `warning` after 10 s (pausing on status-bar hover up to a 20 s ceiling); `error` stays until dismissed.

### `src/Scene`

Live place state and read-only scene queries.

| Module | Purpose |
| --- | --- |
| `Session.luau` | Tile cache, spatial lookups, dirty tracking, and cancellable bakes |
| `Query.luau` | Read-only selection, adjacency, touching-part, and aggregate panel queries |
| `MeshStage.luau` | Staged vertex marks and preview triangulation for **Mesh > Simplify** |

Notes:
- `Session` caches `TerrainInstance.Opened` per model and validates handles per model on undo/redo and direct Properties edits using `DispData`'s session-unique `Rev` attribute and attribute snapshot.
- `Session.nearRadius` uses `GetPartBoundsInRadius` with a displaced-bounds fallback for hole tiles (`CanQuery = false`). `Session.flatNeighbors` matches by flat `Corner1..4` bounds across open vertical seams.
- `Query` resolves selections from a terrain area container, a tile model, or any child wedge/union.

### `src/Actions`

Undoable operations, each wrapped in a single `ChangeHistoryService` recording.

| Module | Purpose |
| --- | --- |
| `Recording.luau` | `ChangeHistoryService` recording wrapper and deferred `autoBake` trigger |
| `Create.luau` | Converts selected parts or picked faces into named tile areas or single tiles |
| `Shape.luau` | Detail resampling, **Round folds**, **Noise**, **Reset shape**, and **Split 2x2** |
| `Appearance.luau` | Base material/color/variant edits (without unbaking), pipette copy, clear paint, fill holes |
| `Edges.luau` | **Sew tiles**, **Stitch**, part-edge pin helpers, seam twins, and **Edit points** moves |
| `Mesh.luau` | Staged simplification (`selectFlat`, `applyMarks`), point removal, and restore |
| `Bake.luau` | Selected/all/rebake/unbake actions, smoothing updates, and dirty-tile auto-bake |

Notes:
- `Recording.autoBake` defers baking while any editing tool is active, avoiding bake/unbake churn when switching tools.
- `Create` keeps custom part names verbatim, numbers generic conversions as `TerrainArea` / `TerrainTile` per parent, enforces `MAX_TILES_PER_PART = 400`, and yields every 8 tiles.
- `Edges.previewStitch` groups nearby tiles by face normal before calling `Stitch.sheet` so vertical tiles never break a floor corner's wall sheet.

### `src/Viewport`

3D viewport tools, adornments, keyboard shortcuts, and the Studio Plugins ribbon.

| Module | Purpose |
| --- | --- |
| `Activation.luau` | Owns `plugin:Activate`, `mouse.Icon`, tool takeover sync, and <kbd>Esc</kbd> handling |
| `Toolbar.luau` | `Strata Terrain` ribbon toolbar, optional ribbon tools, and bindable `PluginAction`s |
| `KeyStrip.luau` | Click-through viewport shortcut bar in `CoreGui` |
| `BrushTool.luau` | Sculpt stroke loop, `SurfaceRay` aiming, brush ring, axis arrow, and live pins |
| `MaterialTool.luau` | Grid-cell / triangle material painter, eraser, and look sampler |
| `MeshTool.luau` | **Simplify** point staging and **Cut holes** triangle brush |
| `PickFaceTool.luau` | Interactive part-face picker with hover and picked highlights |
| `StitchTool.luau` | Interactive part-stitch hover preview and single-click stitch |
| `PointEditor.luau` | **Edit points** handle lifecycle and Studio dragger sync |
| `SampleTool.luau` | Tiles page pipette mode for copying appearance from any visible part |
| `Input.luau` | Unified viewport and panel keyboard input, drag resize, and scroll resize |
| `RadiusPreview.luau` | Temporary centered brush ring and label when **Radius** changes in the panel |
| `TriangleOutline.luau` | Perimeter outline for triangles affected by **Material** or **Cut holes** |
| `Cursor.luau` | Per-frame cursor hint state read by `Activation` |
| `TileHit.luau`, `TriangleBrush.luau`, `Lines.luau`, `VisibleHit.luau` | Shared ray hit, triangle coverage, pooled line adornments, and visible-part raycast helpers |

### `src/UI`

React-Lua dock widget panel built on `StudioComponents` and Lucide icons. See [Panel UI](ui.md).

## Edit points

Source: `src/Viewport/PointEditor.luau`

**Edit points** lets builders move or delete single vertices with Studio's own Select, Move, Rotate, and Scale tools. Its design works around how Studio draggers and undo recordings behave.

### Handles are never saved or undone

Handles live in a `StrataPoints` folder in `workspace` with `Archivable = false`, so they never save into the place or enter undo history. Rebuilds populate an unparented `Handles` folder and parent it in one call so Explorer avoids per-handle churn.

> [!NOTE]
> In Team Create, other editors can see the temporary handle folder while someone is in **Edit points**.

### One undo step per drag

Studio's draggers do not open a recording; they call `ChangeHistoryService:SetWaypoint` on drag end, and plugin property signals arrive deferred. Strata instead:

1. Marks handles dirty when their `CFrame` changes.
2. Flushes dirty handles once per `Heartbeat` inside `TryBeginRecording("Strata move points")`.
3. Appends follow-up flushes within `0.35` s to the same step while it remains on top of the undo stack.

If another recording (such as a bake) is running, handles stay dirty until the next frame.

### Terrain is authoritative

On undo or redo, `Session` reopens tiles from `DispData` and repositions handles onto their vertices. If the point topology changed (undo past **Detail**, **Simplify**, **Unsimplify**, or a deleted tile), handles rebuild while preserving selection.

### Pivot placement and locked orientation

- **Pivot on the point**: each Ball handle sits on the surface with `PivotOffset` placing its pivot on the exact vertex, so Studio's freeform drag does not climb over the tile. Exact coordinates are editable under **Pivot > Origin**.
- **Orientation frame**: each handle stores a local frame (`up` = averaged face normal across shared tiles, `right` = first grid edge) so Local-space gizmos align with the surface.
- **Settle check**: after `0.12` s without motion, rotation, `Size`, and `PivotOffset` reset cleanly without fighting active Rotate/Scale drags. Pure rotations that move no vertex (such as a single handle or Properties `Orientation`) are rejected with a red flash and status hint.

### Seams and deleting points

- **Closed seams**: shared vertices share one handle; neighbor tiles outside the edit follow through `Edges.movePoints` (`Stitch.propagate` + `closeRemovedSeams`) without applying stitch pins or autosew.
- **Deleting handles**: <kbd>Delete</kbd> or <kbd>Cut</kbd> runs `MeshActions.removePoints` (mirrored across seams) after waiting up to `5` s for Studio's own `DeleteSelectedAction` recording to finish, then appends to it so one <kbd>Ctrl</kbd> + <kbd>Z</kbd> restores the points. Tile corners always stay.

### Selection guard

Any selection containing a handle is narrowed to handles only, preventing box selection from dragging terrain, a terrain area, or nearby parts. Grouping handles or moving them out of the folder triggers a rebuild; deleting the top folder exits **Edit points**.

### Limits

| Limit | Value |
| --- | --- |
| Maximum handles at once | `2,500` |
| Handle radius | `0.3` of grid spacing, clamped to `0.15` to `0.8` studs |
| Drag undo merge window | `0.35` s |
| Orientation settle delay | `0.12` s |
| Studio Delete recording wait | Up to `5` s |
