# Hammer mapping

How Strata maps Valve Hammer's displacement system onto Roblox Studio, what it adds, and where it deliberately deviates.

## Contents

[Units and axes](#units-and-axes) | [Concept mapping](#concept-mapping) | [Strata additions](#strata-additions) | [Deliberate deviations](#deliberate-deviations)

## Units and axes

Source: `src/Core/Units.luau`

- **Scale**: `HAMMER_UNITS_PER_STUD = 16`. A 72-unit Source player maps to 4.5 studs, matching a Roblox character. Every Hammer tolerance derives from this scale.
- **Axes**: Hammer is Z-up and Roblox is Y-up (both right-handed), so Roblox `(x, y, z)` maps to Hammer `(x * 16, -z * 16, y * 16)`.

## Concept mapping

| Valve Hammer | Strata | Module |
| --- | --- | --- |
| Brush quad faces | Block `Part` (6 faces) and wedges (3 quad faces) | `Core/PartFaces` |
| Power (`2`, `3`, `4`) | **Detail**: Low (5x5), Medium (9x9), High (17x17) | `Core/Displacement` |
| VMF displacement fields | Same fields and `GenerateDispSurf` formula | `Core/Displacement` |
| `GenerateSurfPointStartIndex` | `Displacement.startCorner` in Hammer axes | `Core/Displacement` |
| Checkerboard diagonals | `Displacement.gridTriangle` (`00-11` / `01-10`) | `Core/Displacement` |
| Paint Geometry | **Raise**, **Lower**, **Smooth**, **Raise To** with 6 axes | `Core/Paint` |
| Subdivide | **Round folds** (4-pass Catmull-Clark on flat quads) | `Core/Subdivide` |
| Sew | **Sew tiles** and **Auto-sew after edits** | `Core/Sew` |
| Noise | **Noise** (3-octave deterministic world-space noise) | `Core/Noise` |
| Paint Alpha | Per-triangle **Material** looks (one union per look) | `Viewport/MaterialTool` |

`Alphas` is still preserved in `DispData`, resampling, and `Sew` for VMF parity even though Roblox parts cannot blend textures by vertex alpha.

## Strata additions

Features beyond Hammer's displacement toolset:

- **Stitching** (`Core/Stitch`, `Viewport/StitchTool`): snaps tile edges onto nearby block and wedge parts within **Reach** and optionally pins them across edits (**Keep edges stitched**).
- **Mesh simplification and holes** (`Core/Mesh`, `Core/Simplify`, `Viewport/MeshTool`): losslessly removes vertices via Delaunay triangulation and cuts holes. See [Data format](data-format.md#mesh-simplification).
- **Edit points** (`Viewport/PointEditor`): moves or deletes individual vertices using Studio's own Select, Move, Rotate, and Scale tools. See [Architecture: Edit points](architecture.md#edit-points).
- **Split 2x2** (`Displacement.split`, `Actions/Shape`): losslessly quarters a Medium or High tile into four tiles one power lower with matching checkerboard parity.
- **CSG baking** (`Core/TerrainInstance`): merges wedges into continuous unions. See [Baking](baking.md).

## Deliberate deviations

### 1. Start corner search bound

Source: `src/Core/Displacement.luau`

- **Hammer**: initializes its minimum-corner search at `99999` (~6,250 studs).
- **Strata**: initializes from `math.huge`.
- **Why**: matches Hammer inside its range while working at arbitrary Roblox world coordinates.

### 2. Power downsampling precision

Source: `src/Core/Displacement.luau`

- **Hammer**: accumulates downsampled distances through an integer.
- **Strata**: follows Hammer's one-step power transitions and 3x3 mean filter, but keeps `distances` as floats.
- **Why**: avoids unnecessary integer truncation loss.

### 3. Brush timing, falloff, ring, and Raise To

Source: `src/Core/Paint.luau`, `src/Viewport/BrushTool.luau`

- **Frame-rate independent strokes**: **Raise** and **Lower** integrate `strength` studs/second over `dt` along the cursor path (plus a `0.08` s tap dab) instead of adding a fixed step per mouse event.
- **Soft falloff**: uses `(1 - d^2/R^2)^1.5` instead of Hammer's `1 - d^2/R^2`, flattening the slope at the rim so strokes do not leave a crease.
- **Surface-centered cursor**: aims at the exact raycast hit on snapshotted triangles (`Core/SurfaceRay`) rather than snapping to the nearest vertex.
- **Exact ring**: the ring is always the real radius and only kept vertices inside it move.
- **Point preview**: `Paint.preview` returns kept vertices inside the ring with falloff weights (up to 64), or up to 4 nearest points within `1.35` cell radii when the ring is empty.
- **Axial weighting**: squared distance along `faceNormal` is discounted by `AXIAL_SHARE = 0.75` so rising points stay inside a held brush.
- **Pinned strokes**: a stroke whose moved points are all pinned to parts is cancelled with a warning instead of recording an empty undo step.
- **Soft Raise To**: **Hard** falloff snaps immediately like Hammer (clearing offset and elevation); **Soft** falloff eases exponentially toward **Height**.
- **Raise To from World**: **From: World** measures **Height** from the world origin so one height aligns across stepped tiles. <kbd>Ctrl</kbd> + Click samples any visible part, and switching to World swaps per-tile axes to **Up (Y)**. Each **From** mode stores its own **Height**.

### 4. Smooth neighborhood

Source: `src/Core/Paint.luau`

- **Hammer**: shrinks smoothing radius toward zero at the rim and weights by `0.5 / Distance`.
- **Strata**: keeps a radius of at least `1.5` grid steps (or `0.25 * radius`), weights by `(1 - u^2)^2`, and eases exponentially (capped at `MAX_STEP = 0.5` per tick).
- **Why**: Roblox-scale grids (2 to 8 studs between vertices) were barely touched by Hammer's shrinking neighborhood.

### 5. Sewing fixes

Source: `src/Core/Sew.luau`

- **Direction-aware pairing**: compares endpoints instead of assuming full edges always run in opposite directions (which twists seams).
- **No allowed-vertex pass**: Strata retains all vertices, so Hammer's compile-time projection pass is unnecessary.
- **2:1 T-edge isolation**: interpolates only the half edge being sewn so the other half does not reopen.
- **3-face edge guard**: skips malformed 3-face groups instead of taking Hammer's undefined branch.

### 6. Reach-based stitching

Source: `src/Core/Stitch.luau`

Hammer only flattens edges already lying directly on a brush face. Strata matches nearby block and wedge edges within **Reach** (default `2` studs):

- **Shared interior edges dropped**: removes only the shared stretch between adjacent parts, so multi-wedge floors match as one outline and T-junction walls keep their uncovered stretches.
- **Orientation filtering**: requires the part's side face to point toward the tile edge within ~75 degrees (`OUTWARD_DOT = 0.25`) and skips near-vertical edges (`MIN_IN_PLANE = 0.25`).
- **Bends and ramps**: vertices past a joined corner snap to that corner, and `extend` follows ramps and walls vertically once any vertex is in reach.
- **Inside corners**: a corner matched to two non-parallel part edges moves to their crossing at the height sitting against both side faces. Coincident neighbor corners join the same decision.
- **Propagation**: snapped vertices propagate directly to neighbor seams so parts always win over sew averaging.

### 7. Subdivide winding and centroid timing

Source: `src/Core/Subdivide.luau`

- **Hammer**: computes vertex normals with its native winding and quad centroids from pre-pass positions.
- **Strata**: reverses cross-product order for its mirrored winding and evaluates quad centroids at split time.
- **Why**: matches Strata's corner winding (`Displacement.faceNormal`) and produces smooth post-pass face centers.

### 8. Noise precision and default range

Source: `src/Core/Noise.luau`, `src/State/Settings.luau`

- **Hammer**: 32-bit floats with default range `0` to `0`.
- **Strata**: Luau double-precision floats (reproducing 32-bit integer lattice hash wraparound via 16-bit split multiplication) with default range `-1` to `1` studs.
- **Why**: Luau has no float32 type, and `-1` to `1` makes **Apply noise** immediately usable.
