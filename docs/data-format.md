# Data Format and Instance Layout

Strata stores terrain using standard Roblox instances, attributes, and a single `CollectionService` tag. Tiles depend on no external assets or plugin state, so they can be published to Roblox, saved as `.rbxm` files, inserted into another place, and reopened by Strata later.

## Instance layout

Defined in `src/Core/TerrainInstance.luau`:

```text
<Model>  tagged StrataDisplacement, WorldPivot = displacement origin
├─ DispData (Configuration)   editable source data, stored as attributes
├─ Tris (Folder)              generated WedgeParts ("1", "2", ...), while editing
├─ Surface (UnionOperation)   merged wedges in the tile's base look, once baked
└─ Surface_1, Surface_2, ...  one union per painted look (look 1, 2, ...), once baked
```

- **Editing vs. baked**: a tile is either **editing** (`Tris` populated, no surface parts) or **baked** (one or more `Surface` / `Surface_<k>` unions present, or a plain `Part` when `Plain Part for flat tiles` is enabled, with `Tris` empty). `TerrainInstance.surfaces` lists surface parts and `TerrainInstance.isBaked` checks whether any exist.
- **One union per look**: Roblox unions hold only one material, so each painted look bakes into its own `Surface_<k>`. `Surface` is omitted if paint covers every triangle on the tile.
- **Containers and naming**: `Create` (`src/Actions/Create.luau`) keeps custom source part names verbatim on the created area or tile `Model`. Generic part names (`Part`, `Wedge`, `WedgePart`, or blank) are numbered per parent as `TerrainArea`, `TerrainArea 2`, ... (multi-face or multi-tile) or `TerrainTile`, `TerrainTile 2`, ... (single tile). Tiles inside an area are named `Tile_<ix>_<iz>` (single face) or `<FaceId>_<ix>_<iz>` (multiple faces).
- **Discovery tag**: every tile `Model` carries the `CollectionService` tag `StrataDisplacement` (`TerrainInstance.TAG`). `Scene/Session.models()` finds all tagged `Model`s under `workspace`.

## Grid layout and surface math

Defined in `src/Core/Displacement.luau`.

A tile turns a 4-sided quad into a regular vertex grid sized by `Power`:

| Power | UI label | Grid vertices | Quads | Grid triangles | Wedges (editing) |
| --- | --- | --- | --- | --- | --- |
| `2` | Low (5x5) | 5x5 (25) | 16 | 32 | 64 |
| `3` | Medium (9x9) | 9x9 (81) | 64 | 128 | 256 |
| `4` | High (17x17) | 17x17 (289) | 256 | 512 | 1,024 |

- **Dimensions**: vertices per side `size = 2^power + 1`, total vertices `size * size`, total grid triangles `2 * (size - 1)^2`.
- **Local space**: `Corner1`..`Corner4`, `Normals`, `Offsets`, and `OffsetNormals` are stored relative to `model:GetPivot()`, so moving or rotating a tile in Studio keeps its data valid.
- **Indexing**: corner winding and 1-based row-major indexing follow Source's surface points. Rows run from `Corner1` to `Corner2` (and `Corner4` to `Corner3` on the opposite edge), columns run from the `Corner1`/`Corner2` edge to `Corner4`/`Corner3`, and `index = row * size + col + 1`.
- **Surface position** (matching Source's `CCoreDispInfo::GenerateDispSurf`):

```text
flat     = bilinear interpolation across Corner1..Corner4
position = flat + normal * distance + offset + faceNormal * elevation
```

where `faceNormal = ((Corner2 - Corner1):Cross(Corner4 - Corner1)).Unit`.

- **Checkerboard triangulation**: each quad `(row, col)` splits into two grid triangles in a diamond pattern: even quads `(row + col) % 2 == 0` split along `v00-v11`; odd quads split along `v01-v10`.

## `DispData` attributes

Serialized by `Displacement.save` and `Displacement.load` in `src/Core/Displacement.luau`:

| Attribute | Type | Required | Description |
| --- | --- | --- | --- |
| `Version` | `number` | Yes | Format version, currently `1`. Loading rejects other versions. |
| `Power` | `number` | Yes | Grid power: `2`, `3`, or `4`. |
| `Elevation` | `number` | Yes | Uniform offset along `faceNormal` in studs (default `0`). |
| `Corner1`..`Corner4` | `Vector3` | Yes | The four flat base corners in model-local space. |
| `Material` | `string` | Yes | `Enum.Material` name (for example `"Grass"`, `"Rock"`). |
| `Color` | `Color3` | Yes | Tile base color. |
| `MaterialVariant` | `string` | No | `MaterialVariant` name from `MaterialService`. Omitted when empty. |
| `Subdiv` | `boolean` | Yes | `true` once `Round` (`Subdivide`) has written offsets; `false` otherwise. |
| `Normals` | `string` | No | Per-vertex field direction vectors (`3 * size^2` floats). Omitted when all equal `Vector3.zero`. |
| `Distances` | `string` | No | Per-vertex field distances (`size^2` floats). Omitted when all equal `0`. |
| `Offsets` | `string` | No | Per-vertex subdivision offsets (`3 * size^2` floats). Omitted when all equal `Vector3.zero`. |
| `OffsetNormals` | `string` | No | Per-vertex subdivision normals (`3 * size^2` floats). Omitted when all equal `faceNormal`. |
| `Alphas` | `string` | No | Per-vertex blend alphas (`size^2` floats). Omitted when all equal `0`. Kept for Hammer parity; Roblox parts cannot blend textures by vertex alpha. |
| `Looks` | `string` | No | Painted looks as a JSON array of `{ "m": material, "c": hexColor, "v": variant }`. Omitted on unpainted tiles without holes; saved as `[]` on tiles with holes and no paint. |
| `TriLooks` | `string` | No | One character per grid triangle (`2 * (size - 1)^2`): `0` for base look, `1`..`9` then `a`..`z` for painted looks 1..35, and `-` for a hole. Omitted on tiles with no paint and no holes. Always indexed by grid triangle, even when points are removed. |
| `Removed` | `string` | No | One character per vertex (`size^2`): `1` for a point removed by `Simplify`, `0` otherwise. Corners are never removed. Omitted when no point is removed. |

### Encoding and omission

- Scalar lists (`Distances`, `Alphas`) are comma-separated floats formatted with `%.6g`.
- Vector lists (`Normals`, `Offsets`, `OffsetNormals`) are flat comma-separated `x,y,z` triplets formatted with `%.6g`.
- Any per-vertex list whose values all match its default is cleared (`SetAttribute(name, nil)`) on save and reconstructed on load, keeping flat and unsubdivided tiles compact in the place file.

## Painted looks and holes

### Painted looks

Because Roblox parts cannot blend two textures by per-vertex alpha like Valve Hammer, the `Material` tool (`src/Viewport/MaterialTool.luau`) assigns a whole **look** (material, color, variant) per grid triangle.

- **Palette compaction**: `Displacement.compactLooks` drops unused looks on save and renumbers the remaining entries so baked `Surface_<k>` unions always match the saved palette.
- **Detail changes and splitting**: `changePower` resamples looks by each new grid triangle's center (`resampleLooks`). `Split 2x2` copies looks triangle for triangle, since quarter quads line up with parent quads.

### Holes

Holes created by the Mesh tool's `Cut holes` mode are stored in memory as `Displacement.HOLE` (`-1`) and serialized as `-` in `TriLooks`.

- **Lossless hiding**: a hole only hides its triangle. Its vertices stay in place, so sewing, stitching, and sculpt brushes treat the tile as intact, and restoring a hole brings back the exact surface.
- **Unbaked vs. baked**: while editing, hole wedges stay parented with `Transparency = 1` and collision, queries, and shadows disabled so wedge numbering stays stable. Baking omits holes from every union.
- **Detail changes and splitting**: lowering detail keeps a coarse triangle solid if any finer triangle it covers is solid, preserving thin ground strips. `Split 2x2` skips quarters whose triangles are all holes.

## Removed points and mesh simplification

Removing vertices with the Mesh tool's `Simplify` mode reduces triangle count without deleting vertex data: every vertex keeps its normals, distances, and offsets, so restoring a point immediately is lossless.

### Delaunay triangulation (`src/Core/Mesh.luau`)

Shown triangles come from a deterministic Bowyer-Watson Delaunay triangulation of the kept vertices on the flat grid. The 4 corners always remain, so the triangulation covers the tile cleanly, and circumcircle ties favor Hammer's checkerboard diagonal so untouched cells keep their original split. Because the triangulation depends only on which vertices are removed, it is built once and cached across sculpt strokes.

### Shown triangles vs. grid triangles

- **Where each is used**: wedges, baking, raycasts, and sculpt updates operate on **shown triangles**. Painted looks and holes stay indexed by **grid triangle**, keeping the save format unchanged.
- **Look resolution**: each shown triangle displays the majority look of the grid triangles it covers, and painting a shown triangle writes all of them. A thin shown triangle covering no grid triangle centers displays the grid triangle under its center and redraws when that grid triangle changes.
- **Whole-triangle brush writes**: `TriangleBrush` (used by `Material` and `Cut holes`) never writes only part of a shown triangle: whenever a brush covers one grid triangle of a shown triangle (such as a quad cell's partner with `Fine` off), it writes all of that shown triangle's grid triangles so hidden paint cannot accumulate.
- **Large shown triangles**: if a shown triangle is larger than the brush, its centroid can lie outside the brush while the cursor sits on its surface (for instance across a seam, on a wedge side, on a baked union, or during a fast drag). `TriangleBrush` also selects any shown triangle whose surface enters the inner half of the brush.

### Re-projection and exact edits

- **Following the surface**: after any edit that moves kept vertices, `Displacement.reproject` projects removed vertices onto the shown triangles. Restoring a vertex after sculpting lands it cleanly on the new surface, and smoothing never reads stale heights.
- **Exact edits**: `Stitch` and `Round` restore any removed vertex they move (`Session.updateMoved`) before rebuilding, because a removed vertex would otherwise snap back to the shown surface; `Stitch` then closes seams against simplified neighbors.
- **Sculpt brushes**: sculpt strokes skip removed vertices and post a notice if a stroke hits only removed vertices.
- **Minimum drag reach**: a `Simplify` drag reaches at least `0.75` grid steps so a small radius still marks the nearest vertex.

### Seam consistency

- **Closing cracks**: removing an edge vertex makes that tile edge straight between its kept endpoints. `Edges.closeRemovedSeams` pulls a neighboring tile's vertex at the same spot onto that straight edge; `autosew` and `Sew tiles` run it after sewing.
- **Stitch propagation**: `Stitch.propagate` moves a denser neighbor's in-between vertices onto the straight edge anchored on the moving tile's vertices, but skips any vertex with its own twin on another moving tile (so equal-density seams stay closed).
- **Mirroring marks**: `Actions/Mesh.applyMarks` (and `Unsimplify` under `Reset` on the Tiles page) mirrors edge marks onto neighboring seam vertices (`Edges.seamTwins`) and propagates any existing removed seam vertices on changed tiles to their neighbors. Corners, painted-border vertices, and hole-outline vertices are never removed; a neighbor's vertex is pulled onto the straight edge instead.

### Detail changes, `Split 2x2`, and staging

- **Detail changes**: raising detail removes new midpoints if any surrounding parent vertex was removed; lowering detail keeps a coarse vertex removed if its finer twin was removed.
- **`Split 2x2`**: copies removed vertices into each quarter, except vertices that become a quarter's corners.
- **Two-phase editing**: `Simplify` stages marks in `Scene/MeshStage` while previewing new edges and before/after triangle counts; `Apply` (`Enter` or `X`) commits all marked tiles in one undo step.
- **`Auto-simplify` (`Actions/Mesh.selectFlat`)**: greedily marks vertices from flattest to steepest as long as every resulting shown triangle stays within `Max angle` degrees of every original grid triangle underneath it (comparing against the originals prevents gradual flattening across curves). Vertices where looks or holes meet are never marked.

## Syncing Studio appearance edits

`TerrainInstance.adoptAppearance` (`src/Core/TerrainInstance.luau`) runs before rebuilding wedges or baking. If a builder changes `Material`, `Color`, or `MaterialVariant` directly on a baked `Surface`, `Surface_<k>`, or wedge via Studio's Properties window or Material Manager, Strata detects the difference and saves it back into `DispData`. The tile's base look is read from `Surface` or an unpainted wedge, never from a painted triangle.
