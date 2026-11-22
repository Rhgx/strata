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
3. Starts the background controllers: `Viewport/Toolbar`, `Scene/Session`, `Viewport/Activation`, `Viewport/BrushTool`, `Viewport/MaterialTool`, `Viewport/MeshTool`, `Viewport/Input`, `Viewport/PickFaceTool`, `Viewport/StitchTool`, and `Viewport/SampleTool`.
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
| `src/Core/Simplify.luau` | Finding points that can go while the surface keeps its shape: `flatPoints` (greedy, one triangulation per candidate; the Mesh tool's `Select flat`) and `flatPointsQuick` (all locally flat points at once by angle or height tolerance, plus straight tile edge points, then repairs; baking). |
| `src/Core/Mesh.luau` | The triangles a tile shows while grid points are removed: a deterministic Delaunay triangulation of the kept points on the flat grid (Bowyer-Watson from the 4 corners, ties broken toward Hammer's checkerboard diagonal), with per shown triangle the grid triangles it covers and per removed point its spot on the surface. |
| `src/Core/SurfaceRay.luau` | Two-sided Moller-Trumbore raycasting against snapshotted vertex positions so brush strokes stay anchored on the initial surface without walking toward the camera or slipping through wedge seams. |
| `src/Core/Sew.luau` | Welds shared corners (up to 16 faces), 2:1 T-junctions (up to 8 faces), and full or half edges (up to 3 faces) within 1 Hammer unit tolerance. |
| `src/Core/Stitch.luau` | Matches tile edges against nearby block/wedge part edges within reach: drops interior edges shared by side-by-side parts (so a floor of wedges matches as one outline), keeps edges whose side face looks back at the tile edge, follows bends in the outline, picks per vertex (same-facing face within a part, then closest), and propagates snapped positions to coincident neighbor edges (`propagate`; a denser neighbor's in-between points follow along the line, points with their own twin on the moving tile stay). `sheet` finds the parts joined to a clicked part. |
| `src/Core/Subdivide.luau` | 4-pass Catmull-Clark style smoothing (Hammer's Subdivide, called `Round` in the UI) over selected flat base quads, writing `offsets`, `offsetNormals`, and `subdiv`. |
| `src/Core/Noise.luau` | Deterministic 3-octave value noise sampled from world positions in Hammer units and axes, applied along each vertex's field vector (or `offsetNormal` on untouched vertices). |

### `src/State`

Shared stores outside React so per-frame viewport tools read tool state directly without waiting for React renders.

| Module | Responsibility |
| --- | --- |
| `src/State/Settings.luau` | Frozen `State` table with `get`, `update`, `subscribe`, `toggleTool`, `stopViewportTool`, `setOverlay`, `stepRadius`, and `stepReach`. Clamps numeric bounds and enforces mutual exclusion across the four mouse-owning modes (`painting`, `picking`, `stitching`, `sampling`). |
| `src/State/KeyCapture.luau` | Holders of the panel's keyboard (a Dropdown under keyboard control); while one holds it, `Input.onKey` leaves the panel's keys to it, so Esc closing a list does not also stop the tool and Enter picking an item does not also apply or create. |
| `src/State/Status.luau` | Latest operation result (`success`, `warning`, or `error`) for the status bar. `success` and `warning` expire after 6 seconds; `error` stays until dismissed or replaced. |
| `src/State/Format.luau` | Text helpers shared by the panel, status messages and 3D labels: counts, plurals, stud lengths, colors. |

### `src/Scene`

Live place state and read-only scene queries.

| Module | Responsibility |
| --- | --- |
| `src/Scene/Session.luau` | Caches opened `TerrainInstance.Opened` handles per `Model`, tracks `dirty` tiles edited since their last bake, provides `updateWedges`, `bake`, and `bakeDirty`, and clears the in-memory cache on `ChangeHistoryService.OnUndo`, `OnRedo`, and `StrataDisplacement` tag removal. |
| `src/Scene/Query.luau` | Read-only selection and spatial queries: `workingModels` (the tiles a viewport tool works on: the selection with Selected only on, otherwise all), `displacementOf`, `selectedModels`, `selectedTiles`, `selectedParts`, `touchingParts`, `tilesNear`, `appearanceOf`, `selectionInfo`, and `placeInfo`. Resolves selections whether the user clicks a `TerrainArea` container, a tile model, or a child wedge/union. |
| `src/Scene/MeshStage.luau` | Points marked in the Mesh tool's `Simplify` mode but not applied yet (by model), with a cached preview triangulation per tile and the triangle counts before and after; cleared on undo, redo, mode changes and when the tool stops. |

### `src/Actions`

Undoable operations. Every action runs inside a single `ChangeHistoryService` recording.

| Module | Responsibility |
| --- | --- |
| `src/Actions/Recording.luau` | Wraps actions in `ChangeHistoryService:TryBeginRecording` / `FinishRecording` (committing on success, cancelling and clearing `Session` on error) and runs `Recording.autoBake()` when `autoBake` is enabled and no tile-editing tool is running (`Settings.editing`: every tool but Pick faces). Editing tools also bake only when the last of them stops, so switching straight from one to another does not bake tiles only to unbake them at the next stroke. |
| `src/Actions/Create.luau` | Converts selected parts or picked faces into displacement tiles grouped in `TerrainArea` models (or a standalone `Displacement` model for a single tile). Enforces `MAX_TILES_PER_PART = 400`, yields every 8 tiles, removes source parts inside the recording, and bakes flat slabs immediately when `autoBake` is on. |
| `src/Actions/Shape.luau` | Tile shape operations: `setDetail` (power change with pin remapping and optional autosew), `round` (`Subdivide`), `addNoise` (`Noise`), and `split` (lossless 2x2 split into four tiles one power lower). |
| `src/Actions/Appearance.luau` | Lists part-compatible `Enum.Material` values (excluding `Air` and `Water`) and `MaterialService` variants; applies `Material`, `Color`, and `MaterialVariant` changes straight to `DispData` and visible parts without unbaking or rebaking (yielding every 2,000 parts on large unbaked selections); provides `copyFrom` and `clearPaint` (removes painted materials from the selected tiles). |
| `src/Actions/Edges.luau` | `sewSelected`, `stitchSelected`, `previewStitch`, `stitchToPart`, `autosew`, `closeRemovedSeams` (pulls a neighbor's point onto an edge a simplified tile shows straight), and pin helpers (`pinsFor`, `propagatePins`, `restorePins` using `PIN_REACH = 0.1` studs) for `Keep edges stitched`. |
| `src/Actions/Bake.luau` | `bakeSelected`, `bakeAll`, `rebakeAll` (every tile again in one undo step, straight from old union to new, so changed bake options apply), `unbakeSelected`, `applySmoothing` (updates `SmoothingAngle` on every baked union in one undo step; plain Part surfaces are skipped), and `bakeEdited` (auto-bakes dirty tiles when the last editing tool stops). A bake of several tiles posts `Baking i of N...` progress (cleared when no result replaces it), results report triangles saved (`768 to 12 triangles`), and a second bake while one runs is refused. `report` posts any bake's result (shared by the panel and the automatic bake). |

### `src/Viewport`

3D viewport interaction, adornments, keyboard shortcuts, and the Studio Plugins ribbon.

| Module | Responsibility |
| --- | --- |
| `src/Viewport/Activation.luau` | Single owner of `plugin:Activate(true)` / `plugin:Deactivate()`, mouse cursor icon (`Cross` for painting, `PointingHand` for picking, stitching, and sampling), Studio tool-takeover sync (a `Deactivation` that arrives with a tool switch, as ribbon clicks can cause, keeps the new tool instead of stopping everything), and `Esc` handling through `Input.onKey`, so it also works while the panel has keyboard focus (closes Settings/Help first, then cancels the Material pipette, clears the Mesh tool's marks or Pick faces' picks, otherwise stops the running tool). |
| `src/Viewport/Toolbar.luau` | Builds the `Strata Terrain` toolbar on the Plugins ribbon tab (panel toggle with the theme-switched Strata logo; a toolbar named `Strata`, the plugin's own name, is left off the ribbon by Studio), plus, only with the `ribbonTools` setting (off by default), a `Strata Tools` group with the eight viewport tool buttons using Studio's built-in icons, created once per session (Studio cannot remove ribbon buttons while running, so turning the setting off greys them out until restart). Registers `PluginAction`s for `File > Advanced > Customize Shortcuts` either way. |
| `src/Viewport/KeyStrip.luau` | Click-through Studio-themed `ScreenGui` in `CoreGui` displaying active tool shortcuts at the bottom of the viewport. |
| `src/Viewport/BrushTool.luau` | Per-frame painting loop, `SurfaceRay` snapshots, brush cursor rings, multi-sample stroke path, modifier keys (`Ctrl`, `Shift`, `Alt + Drag` through the shared `Input.beginDragResize` / `Input.dragRadius`, also used by the Material and Mesh tools, `Alt + Right Click`, `[` / `]`), single-stroke undo recording, autosew/pin restoration on mouse up, and `Bake.bakeEdited()` on stop. |
| `src/Viewport/PickFaceTool.luau` | Raycasts eligible block/wedge faces (looking through up to 8 transparent parts), draws `BoxHandleAdornment` highlights (blue hover, amber picked) so wedge slopes align cleanly, and exposes `picks`/`clear`/`subscribe`. Shows a key strip; `Enter` creates from the picks (through `Create.createPicked`, shared with the panel's button: ignored while a Create runs, and a failure keeps the tool and its picks), and the first `Esc` clears the picks before the next one stops the tool. |
| `src/Viewport/StitchTool.luau` | Raycasts eligible parts, renders hover previews (`SelectionBox`, green target lines, amber source lines), stitches on click (one undo step per click), and bakes on tool exit. |
| `src/Viewport/MaterialTool.luau` | The Material tool: paints the chosen look into triangles under the brush (whole grid cells by default, single triangles with `Fine`), `Ctrl` to erase, `Alt + Right Click` or the panel pipette to pick up a look, one undo step per stroke, and `Bake.bakeEdited()` on stop. Covered triangles come from `TriangleBrush`; painting never fills a hole. |
| `src/Viewport/MeshTool.luau` | The Mesh tool. `Simplify` marks first and acts second: drag marks points to remove (`Ctrl` marks removed points to restore), a click toggles the nearest point, the edges marked tiles would gain are previewed, and `Apply` / `Enter` / `X` commits through `Actions/Mesh.applyMarks` (the first `Esc` clears the marks). `Cut holes`: drag deletes triangles (`Ctrl` restores), aiming with `SurfaceRay` with holes included and outlining the hovered tile's holes. |
| `src/Viewport/Input.luau` | Shared viewport input: Ctrl/Shift/Alt that also read while the panel has keyboard focus (a transparent listener frame over the widget), `onKey` (key presses from the 3D view and the panel, one signal; typing in a panel text field is left to it), and `connectResize` for Ctrl + Scroll (scroll down grows, up shrinks) and `[` / `]` that holds Studio's edit camera still for a moment (camera position remembered every frame, released on mouse buttons or camera keys). |
| `src/Viewport/RadiusPreview.luau` | After the panel's Radius changes, the running tool draws its cursor where the middle of the 3D view meets the terrain (a camera-facing ring when there is none) for about a second, with a `Radius 8 st` label; mouse movement over the 3D view ends it. `newRing` makes the flat radius ring the tools' cursors and previews use. |
| `src/Viewport/TriangleOutline.luau` | The triangle tools' cursor: the outer edges of exactly the shown triangles a click would change (blue to paint, red to erase or cut, green to restore). |
| `src/Viewport/TileHit.luau`, `src/Viewport/TriangleBrush.luau`, `src/Viewport/Lines.luau` | The tile and shown triangle under the mouse (holes optional), the grid triangles a triangle brush covers and writing a look into them, and a pool of world-space line adornments. |
| `src/Viewport/SampleTool.luau` | Pipette mode: highlights hovered visible parts or tiles, copies `Material`, `Color`, and `MaterialVariant` onto selected tiles in one undo step, then exits. |
| `src/Viewport/Cursor.luau` | The running tool's hint for the cursor (`resize`, `empty`, `valid`, `invalid`), set every frame and cleared on a tool switch. `Activation` turns it into `mouse.Icon`: Wait while baking, SizeEW during Alt + Drag, Forbidden with nothing to act on, Cross for the brushes, and PointingHand or Arrow for the click tools by hover. |
| `src/Viewport/VisibleHit.luau` | The first visible thing along a ray, looking through invisible parts; shared by the pipette, Sample, Stitch, Pick faces and Raise To's height pick. |

### `src/UI`

React-Lua dock widget panel built on `StudioComponents` and Lucide icons. See [Panel UI](ui.md) for details on `App`, `Pages/`, `Rows`, `Tooltip`/`Markup`, `Dropdown`, `ColorField`, and `ColorPicker`.
