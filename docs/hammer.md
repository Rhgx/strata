# Hammer Mapping and Deviations

Strata's terrain model and core algorithms follow Valve Hammer's displacement system, adapted for Roblox Studio's coordinate system, part types, and interactive sculpting workflow.

## Units and coordinate mapping

Defined in `src/Core/Units.luau`:

- **Scale**: `HAMMER_UNITS_PER_STUD = 16`. A 72-unit Source player becomes 4.5 studs, close to a Roblox character. Every absolute size taken from Hammer (sewing tolerance, subdivide merge tolerances, start-corner calculation, and noise lattice spacing) derives from this single constant.
- **Axes**: Hammer is Z-up and Roblox is Y-up. Both are right-handed, so a Roblox world point `(x, y, z)` converts to Hammer `(x * 16, -z * 16, y * 16)`.

## Concept mapping

| Valve Hammer | Strata | Module |
| --- | --- | --- |
| Brush quad faces | Block `Part` (6 faces) and wedges (3 faces: `Bottom`, `Back`, `Slope`; triangular sides skipped) | `src/Core/PartFaces.luau` |
| Power (`2`, `3`, `4`) | `Detail`: `Low (5x5)`, `Medium (9x9)`, `High (17x17)` | `src/Core/Displacement.luau` |
| VMF fields (`normals`, `distances`, `offsets`, `offset_normals`, `alphas`, `subdiv`, `elevation`) | Same fields and `GenerateDispSurf` surface formula (`flat + normal * distance + offset + faceNormal * elevation`) | `src/Core/Displacement.luau` |
| Start corner (`GenerateSurfPointStartIndex`) | `Displacement.startCorner` evaluated in Hammer axes | `src/Core/Displacement.luau` |
| Checkerboard triangulation (`BuildTriBLtoTR` / `BuildTriTLtoBR`) | `Displacement.triangle` (even quads `00-11`, odd quads `01-10`) | `src/Core/Displacement.luau` |
| Paint Geometry (`Raise/Lower`, `Raise To`, `Smooth`) | `Raise`, `Lower`, `Smooth`, `Raise To` brushes with `Face normal`, `Up (Y)` (Hammer's Z-up default), `X`, `Z`, `Picked` (`Alt + Right Click`), and `Curved (Round)` (`offsetNormals`) axes | `src/Core/Paint.luau`, `src/Viewport/BrushTool.luau` |
| Subdivide | `Round`: 4-pass Catmull-Clark style smoothing on selected flat base quads; shared edges smooth, outer outline stays sharp; each tile reads the level matching its power while painted displacement rides on top | `src/Core/Subdivide.luau` |
| Sew | `Sew` and `Auto-sew after edits`: corners (up to 16 faces), 2:1 T-junctions (up to 8 faces), and full/half edges (up to 3 faces) matched within 1 Hammer unit per axis | `src/Core/Sew.luau` |
| Noise | `Noise`: deterministic 3-octave value noise (persistence 1, 1 Hammer unit lattice, C-style 32-bit integer hash and truncation toward zero) applied along each vertex's field vector (or `offsetNormal` when untouched) | `src/Core/Noise.luau` |
| Paint Alpha | Replaced by per-triangle painted looks: Roblox parts cannot blend two textures by per-vertex alpha, so the `Material` tool assigns a whole look (material, color, variant) to each triangle and each look bakes into its own union. `Alphas` is still preserved in `DispData`, power resampling, and `Sew` for parity. | `src/Viewport/MaterialTool.luau`, `src/Core/Displacement.luau` |

### Strata additions

- **Stitching (`src/Core/Stitch.luau`, `src/Viewport/StitchTool.luau`, `src/Actions/Edges.luau`)**: snaps tile edges onto nearby block/wedge parts (roads, walls, ramps) and optionally pins stitched edges across later edits (`Keep edges stitched`).
- **Split 2x2 (`Displacement.split`, `src/Actions/Shape.luau`)**: losslessly splits a power 3 or 4 tile into four tiles one power lower (each quarter of a `2^p + 1` grid is an exact `2^(p-1) + 1` grid with matching checkerboard parity).
- **CSG baking (`src/Core/TerrainInstance.luau`)**: merges wedges into a single `UnionOperation` for continuous texture projection (see [Baking](baking.md)).

## Deliberate deviations from Hammer

Each deviation below is documented in its source module header:

### 1. Start corner search bound (`src/Core/Displacement.luau`)

Hammer initializes its minimum-corner search at `99999` (only about 6,250 studs in Roblox). Strata initializes from `math.huge`, producing the exact same corner inside Hammer's range while continuing to work at larger coordinates.

### 2. Power downsampling precision (`src/Core/Displacement.luau`)

Strata matches Hammer's power transitions (stepping one power at a time, averaging each stored field independently without renormalizing normals, anti-diagonal averaging on upsample, and 3x3 mean filtering on downsample), except it keeps downsampled `distances` as floats instead of accumulating through an integer as Hammer does, avoiding unnecessary truncation loss.

### 3. Brush timing, falloff, centering, and reach (`src/Core/Paint.luau`, `src/Viewport/BrushTool.luau`)

- **Frame-rate independent strokes**: `Raise` and `Lower` apply `strength` studs per second integrated over `dt` across every sample along the frame's cursor path (with an initial `0.08` s tap dab on mouse down), rather than adding a fixed distance per mouse event.
- **Soft falloff**: Strata uses `(1 - d^2/R^2)^1.5` instead of Hammer's `1 - d^2/R^2`. Hammer's quadratic curve meets the rim at a non-zero slope and leaves a ring crease; Strata's curve flattens at the rim (half strength at `0.61 * R`).
- **Cursor centering**: the brush centers on the exact surface point under the cursor using snapshotted triangles (`src/Core/SurfaceRay.luau`) rather than snapping to the nearest grid vertex.
- **Grid-minimum reach and axial weighting**: a brush smaller than the grid always reaches at least `1.0` grid step (`Soft`/`Smooth`) or `0.75` grid steps (`Hard`) so it never sits idly between vertices. Vertex distance along the tile's face normal is weighted down (`AXIAL_SHARE = 0.75`) so vertices rising under a held brush stay inside it.
- **Soft `Raise To`**: `Hard` falloff matches Hammer's immediate absolute placement (dropping offset and elevation), while `Soft` falloff eases exponentially toward the target height feathered at the rim.

### 4. Smooth neighborhood (`src/Core/Paint.luau`)

Hammer's smoothing neighborhood shrinks to zero toward the brush edge and weighs neighbors lightly (`0.5 / Distance`), which on Roblox-scale grids (vertices 2 to 8 studs apart) leaves most of the brush untouched. Strata keeps a neighborhood radius of at least `1.5` grid steps everywhere inside the brush (or `0.25 * radius` for large brushes), weights neighbors by `(1 - u^2)^2`, and approaches the neighbor average exponentially (capped at `MAX_STEP = 0.5` per tick so it cannot overshoot).

### 5. Sewing fixes (`src/Core/Sew.luau`)

- **Direction-aware pairing**: Hammer pairs vertices of two full edges as if they always run in opposite directions, which twists seams when edges run the same way. Strata compares endpoints and pairs vertices by actual direction.
- **No "allowed vertex" pass**: Hammer first projects unmatched vertices onto coarse neighbor triangles to compensate for vertices dropped during Source map compilation. Strata builds every vertex, so that pass is skipped.
- **2:1 T-edge half isolation**: when the long edge is denser than an adjacent half edge, Hammer re-interpolates the entire long edge, reopening any seam already sewn on the other half. Strata interpolates only the half being sewn.
- **3-face edge guard**: a 3-face edge group whose second entry is not a full edge match is skipped instead of running Hammer's undefined path.

### 6. Stitching instead of exact brush-face sewing (`src/Core/Stitch.luau`)

Hammer only flattens displacement edges that already lie directly on a brush face. Because Roblox parts rarely align that closely, Strata matches block and wedge edges within a configurable `Reach` (default `2` studs) as long as the part edge runs within roughly 31 degrees (`MIN_PARALLEL = 0.85`) of the tile edge in the tile plane and is not nearly vertical out of it (`MIN_IN_PLANE = 0.25`). With `extend` enabled, matching edges follow ramps and walls sideways at any height once at least two vertices are in reach. Snapped vertices are propagated to coincident neighbor edges rather than averaged with `Sew`, so the part edge always wins at shared corners.

### 7. Subdivide winding and centroid timing (`src/Core/Subdivide.luau`)

Vertex normals use the opposite cross-product order to Hammer because Strata's corner winding is mirrored (`Displacement.faceNormal`). When splitting a quad, the face point is taken as the quad's centroid at split time (after that pass has moved vertices).

### 8. Noise precision and default range (`src/Core/Noise.luau`, `src/State/Settings.luau`)

Noise math runs in Luau doubles rather than 32-bit floats (values can differ in the last bits, while 32-bit unsigned integer wraparound in the lattice hash is reproduced with 16-bit split multiplication). Default noise bounds in `State/Settings` are `-1` to `1` studs rather than Hammer's `0` to `0` (which does nothing).
