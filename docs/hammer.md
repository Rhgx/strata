# Hammer Mapping and Deviations

Strata's terrain model and core algorithms follow Valve Hammer's displacement system, adapted for Roblox Studio's coordinate system, part types, and interactive sculpting workflow.

## Units and coordinate mapping

Defined in `src/Core/Units.luau`:

- **Scale**: `HAMMER_UNITS_PER_STUD = 16`. A 72-unit Source player maps to 4.5 studs, close to a Roblox character. Every absolute constant taken from Hammer (sewing tolerance, subdivide merge tolerances, start-corner search, noise lattice spacing) derives from this single scale.
- **Axes**: Hammer is Z-up and Roblox is Y-up. Both are right-handed, so a Roblox world point `(x, y, z)` converts to Hammer `(x * 16, -z * 16, y * 16)`.

## Concept mapping

| Valve Hammer | Strata | Module |
| --- | --- | --- |
| Brush quad faces | Block `Part` (6 faces) and wedges (3 faces: `Bottom`, `Back`, `Slope`; triangular sides skipped) | `src/Core/PartFaces.luau` |
| Power (`2`, `3`, `4`) | `Detail`: `Low (5x5)`, `Medium (9x9)`, `High (17x17)` | `src/Core/Displacement.luau` |
| VMF fields (`normals`, `distances`, `offsets`, `offset_normals`, `alphas`, `subdiv`, `elevation`) | Same fields and `GenerateDispSurf` formula (`flat + normal * distance + offset + faceNormal * elevation`) | `src/Core/Displacement.luau` |
| Start corner (`GenerateSurfPointStartIndex`) | `Displacement.startCorner` evaluated in Hammer axes | `src/Core/Displacement.luau` |
| Checkerboard triangulation (`BuildTriBLtoTR` / `BuildTriTLtoBR`) | `Displacement.gridTriangle` (even quads `00-11`, odd quads `01-10`) | `src/Core/Displacement.luau` |
| Paint Geometry (`Raise/Lower`, `Raise To`, `Smooth`) | `Raise`, `Lower`, `Smooth`, `Raise To` brushes with six axes: `Face normal`, `Up (Y)` (Hammer's Z-up default), `X`, `Z`, `Picked` (`Alt + Right Click`), and `Curved (Round)` (`offsetNormals`) | `src/Core/Paint.luau`, `src/Viewport/BrushTool.luau` |
| Subdivide | `Round`: 4-pass Catmull-Clark style smoothing on selected flat base quads; shared edges smooth while outer outlines stay sharp, and sculpted displacement rides on top | `src/Core/Subdivide.luau` |
| Sew | `Sew tiles` and `Auto-sew after edits`: corners (up to 16 faces), 2:1 T-junctions (up to 8 faces), and full/half edges (up to 3 faces) matched within 1 Hammer unit per axis | `src/Core/Sew.luau` |
| Noise | `Noise`: deterministic 3-octave value noise (persistence 1, 1 Hammer unit lattice, C-style 32-bit integer hash and truncation toward zero) applied along each vertex's field vector (or `offsetNormal` when untouched) | `src/Core/Noise.luau` |
| Paint Alpha | Per-triangle painted looks via the `Material` tool: Roblox parts cannot blend textures by vertex alpha, so each look bakes into its own union. `Alphas` is still preserved in `DispData`, resampling, and `Sew` for parity. | `src/Viewport/MaterialTool.luau`, `src/Core/Displacement.luau` |

## Strata additions

Features beyond Valve Hammer's displacement toolset:

- **Stitching (`Core/Stitch`, `Viewport/StitchTool`, `Actions/Edges`)**: snaps tile edges onto nearby block and wedge parts (roads, walls, ramps, wedge floors) within a configurable `Reach` and optionally pins stitched edges across edits (`Keep edges stitched`).
- **Mesh density and holes (`Core/Mesh`, `Core/Simplify`, `Viewport/MeshTool`, `Actions/Mesh`)**: removes individual vertices to coarsen flat areas via a Delaunay triangulation (manually or with `Auto-simplify`) and cuts holes by deleting triangles, all losslessly. See [Data format](data-format.md).
- **Edit points (`Viewport/PointEditor`, `Actions/Edges`)**: places a handle on each point of the selected tiles so single points can be moved with Studio's own Select, Move, Rotate, and Scale tools, keeping seams closed. Hammer edits single vertices only through its paint tools. See [Architecture](architecture.md#edit-points).
- **Split 2x2 (`Displacement.split`, `Actions/Shape`)**: losslessly splits a `Medium` (power 3) or `High` (power 4) tile into four tiles one power lower, since each quarter of a `2^p + 1` grid is an exact `2^(p-1) + 1` grid with matching checkerboard parity.
- **CSG baking (`Core/TerrainInstance`)**: merges wedges into `UnionOperation` parts (one per look) for continuous texture projection. See [Baking](baking.md).

## Deliberate deviations from Hammer

Each deviation below is also documented in its source module header.

### 1. Start corner search bound (`src/Core/Displacement.luau`)

Hammer initializes its minimum-corner search at `99999` (about 6,250 studs in Roblox). Strata initializes from `math.huge`, matching Hammer inside its range while continuing to work at larger world coordinates.

### 2. Power downsampling precision (`src/Core/Displacement.luau`)

Strata mirrors Hammer's power transitions (stepping one power at a time, averaging each field independently without renormalizing normals, anti-diagonal averaging on upsample, and 3x3 mean filtering on downsample), but keeps downsampled `distances` as floats instead of accumulating through an integer, avoiding unnecessary truncation loss.

### 3. Brush timing, falloff, centering, and reach (`src/Core/Paint.luau`, `src/Viewport/BrushTool.luau`)

- **Frame-rate independent strokes**: `Raise` and `Lower` apply `strength` studs per second integrated over `dt` along the cursor path (plus a `0.08` s tap dab on mouse down) instead of adding a fixed distance per mouse event.
- **Soft falloff**: Strata uses `(1 - d^2/R^2)^1.5` instead of Hammer's `1 - d^2/R^2`. Hammer's quadratic curve meets the rim at a non-zero slope and leaves a crease; Strata's curve flattens at the rim (half strength at `0.61 * R`).
- **Surface-centered cursor**: the brush centers on the exact raycast surface hit on snapshotted triangles (`src/Core/SurfaceRay.luau`) rather than snapping to the nearest vertex.
- **Grid-minimum reach and axial weighting**: a brush smaller than the grid always reaches at least `1.0` grid step (`Soft` / `Smooth`) or `0.75` grid steps (`Hard`) so it never sits idly between vertices. Distance along the tile's face normal is weighted by `AXIAL_SHARE = 0.75` so rising vertices stay inside a held brush.
- **Soft `Raise To`**: `Hard` falloff matches Hammer's immediate absolute placement (clearing offset and elevation), while `Soft` falloff eases exponentially toward the target height feathered at the rim.
- **`Raise To` from `World`**: `From: World` (`Settings.raiseToWorld`) measures `Height` along the active axis from the world origin instead of each tile's flat base, so one height aligns across tiles at different elevations (such as a road over stepped ground). `Ctrl + Click` samples the world height of any visible part under the cursor, and switching to `World` changes a `Face normal` or `Curved (Round)` axis to `Up (Y)`. Each `From` mode keeps its own `Height` (`Settings.otherHeight` stores the inactive one).

### 4. Smooth neighborhood (`src/Core/Paint.luau`)

Hammer's smoothing neighborhood shrinks to zero at the brush rim and weights neighbors by `0.5 / Distance`, which leaves most of a Roblox-scale grid (2 to 8 studs between vertices) untouched. Strata keeps a neighborhood radius of at least `1.5` grid steps everywhere inside the brush (or `0.25 * radius` for large brushes), weights neighbors by `(1 - u^2)^2`, and eases toward the neighbor average exponentially (capped at `MAX_STEP = 0.5` per tick to prevent overshoot).

### 5. Sewing fixes (`src/Core/Sew.luau`)

- **Direction-aware pairing**: Hammer pairs vertices of two full edges assuming they always run in opposite directions, which twists seams when edges run the same way. Strata compares endpoints and pairs vertices by actual direction.
- **No "allowed vertex" pass**: Hammer projects unmatched vertices onto coarse neighbor triangles to handle vertices dropped during Source map compilation. Strata keeps every vertex, so this pass is unnecessary.
- **2:1 T-edge half isolation**: when a long edge is denser than an adjacent half edge, Hammer re-interpolates the entire long edge, reopening seams on the other half. Strata interpolates only the half being sewn.
- **3-face edge guard**: a 3-face edge group whose second entry is not a full edge match is skipped instead of taking Hammer's undefined branch.

### 6. Stitching instead of exact brush-face sewing (`src/Core/Stitch.luau`)

Hammer only flattens displacement edges that already lie directly on a brush face. Because Roblox parts rarely align that closely, Strata matches block and wedge edges within a configurable `Reach` (default `2` studs):

- **Shared interior edges dropped**: the stretches of edges shared by adjacent parts are excluded, so a floor made of wedges ("triangle terrain") matches as one outer outline. Only the shared stretch goes: a wall butting into the middle of a longer wall leaves the rest of the longer wall's edge matchable.
- **Orientation filtering**: a part edge qualifies when its side face points back toward the tile edge within about 75 degrees (`OUTWARD_DOT = 0.25`) and does not stand nearly vertical out of the tile plane (`MIN_IN_PLANE = 0.25`).
- **Bends and ramps**: where two candidate edges meet at a bend, vertices past one edge's end snap to the shared corner, avoiding V-shaped gaps. With `extend` enabled, matched edges follow ramps and walls sideways at any height once a vertex is within reach.
- **Inside corners**: a tile corner whose two edges match two different, non-parallel part edges (two walls meeting, an L-shaped floor) moves to where those edges cross, so it touches both instead of stopping short of one. Where the edges pass at different heights, the corner takes the height that still sits against both parts' side faces. Coincident corners of neighboring tiles make the same choice.
- **Propagation**: snapped positions propagate to coincident neighbor edges rather than averaging via `Sew`, so the part edge always wins at shared corners.

### 7. Subdivide winding and centroid timing (`src/Core/Subdivide.luau`)

Vertex normals use the opposite cross-product order to Hammer because Strata's corner winding is mirrored (`Displacement.faceNormal`). When splitting a quad, the face point uses the quad's centroid at split time (after that pass moves vertices).

### 8. Noise precision and default range (`src/Core/Noise.luau`, `src/State/Settings.luau`)

Noise evaluates in Luau double-precision floats rather than 32-bit floats (values can differ in the lowest bits, while 32-bit unsigned integer wraparound in the lattice hash is reproduced with 16-bit split multiplication). Default noise bounds in `State/Settings` are `-1` to `1` studs rather than Hammer's `0` to `0`.
