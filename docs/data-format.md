# Data format

Tile instance layout, surface math, `DispData` attributes, painted looks, holes, and mesh simplification.

## Contents

[Instance layout](#instance-layout) | [Grid math](#grid-math) | [DispData attributes](#dispdata-attributes) | [Painted looks and holes](#painted-looks-and-holes) | [Mesh simplification](#mesh-simplification) | [Studio appearance sync](#studio-appearance-sync)

## Instance layout

Source: `src/Core/TerrainInstance.luau`

Strata stores terrain using standard Roblox instances, attributes, and one `CollectionService` tag. Tiles need no external assets or plugin state, so they publish, export as `.rbxm`, and reopen in any Studio session.

```text
<Model>  tagged StrataDisplacement, WorldPivot = displacement origin
├─ DispData (Configuration)   editable source data, stored as attributes
├─ Tris (Folder)              generated WedgeParts ("1", "2", ...), while editing
├─ Surface (UnionOperation)   merged wedges in the tile's base look, once baked
└─ Surface_1, Surface_2, ...  one union per painted look (look 1, 2, ...), once baked
```

- **Editing vs. baked**: a tile is either **editing** (`Tris` populated, no surface parts) or **baked** (`Surface` / `Surface_<k>` unions, or a plain `Part` when **Plain Part for flat tiles** is on, with `Tris` empty).
- **One union per look**: Roblox unions hold one material, so each painted look gets its own `Surface_<k>`. `Surface` is omitted when paint covers every triangle.
- **Discovery tag**: every tile `Model` carries the tag `StrataDisplacement` (`TerrainInstance.TAG`). `Session.models()` finds all tagged models under `workspace`.
- **Containers and naming**: `Create` keeps custom source part names verbatim. Generic parts (`Part`, `Wedge`, `WedgePart`, or blank) are numbered per parent as `TerrainArea`, `TerrainArea 2`, ... (multi-tile) or `TerrainTile`, `TerrainTile 2`, ... (single tile). Inner tiles are named `Tile_<ix>_<iz>` (single face) or `<FaceId>_<ix>_<iz>` (multi-face).

## Grid math

Source: `src/Core/Displacement.luau`

A tile maps a 4-sided quad onto a vertex grid sized by `Power`:

| Power | UI label | Grid vertices | Quads | Grid triangles | Editing wedges |
| --- | --- | --- | --- | --- | --- |
| `2` | Low (5x5) | 5x5 (25) | 16 | 32 | 64 |
| `3` | Medium (9x9) | 9x9 (81) | 64 | 128 | 256 |
| `4` | High (17x17) | 17x17 (289) | 256 | 512 | 1,024 |

- **Dimensions**: vertices per side `size = 2^power + 1`, total vertices `size^2`, grid triangles `2 * (size - 1)^2`.
- **Local space**: `Corner1`..`Corner4`, `Normals`, `Offsets`, and `OffsetNormals` are relative to `model:GetPivot()`, so moving or rotating a tile in Studio keeps its data valid.
- **Indexing**: 1-based row-major (`index = row * size + col + 1`). Rows run `Corner1 -> Corner2` (and `Corner4 -> Corner3`); columns run from the `Corner1/Corner2` edge to `Corner4/Corner3`.
- **Checkerboard triangulation**: even quads `(row + col) % 2 == 0` split along `v00-v11`; odd quads split along `v01-v10`.

Surface position (matching Source's `CCoreDispInfo::GenerateDispSurf`):

```text
flat     = bilinear interpolation across Corner1..Corner4
position = flat + normal * distance + offset + faceNormal * elevation
```

where `faceNormal = ((Corner2 - Corner1):Cross(Corner4 - Corner1)).Unit`.

## `DispData` attributes

Source: `Displacement.save` and `Displacement.load` in `src/Core/Displacement.luau`

> [!IMPORTANT]
> `Version` (`Displacement.FORMAT_VERSION`, currently `1`) tracks the serialized data format independently of the plugin release version. Loading rejects any other format version rather than misreading it.

### Required attributes

| Attribute | Type | Description |
| --- | --- | --- |
| `Version` | `number` | Data format version (currently `1`) |
| `Power` | `number` | Grid power (`2`, `3`, or `4`) |
| `Elevation` | `number` | Uniform offset along `faceNormal` in studs |
| `Corner1`..`Corner4` | `Vector3` | Flat base corners in model-local space |
| `Material` | `string` | Base `Enum.Material` name (e.g. `"Grass"`) |
| `Color` | `Color3` | Tile base color |
| `Subdiv` | `boolean` | `true` once **Round folds** has written offsets |

### Optional attributes

Omitted (cleared with `SetAttribute(name, nil)`) whenever every entry matches its default, keeping flat tiles compact in the place file.

| Attribute | Type | Description |
| --- | --- | --- |
| `MaterialVariant` | `string` | `MaterialService` variant name (omitted when empty) |
| `Normals` | `string` | Per-vertex field directions (`3 * size^2` floats) |
| `Distances` | `string` | Per-vertex field distances (`size^2` floats) |
| `Offsets` | `string` | Per-vertex subdivision offsets (`3 * size^2` floats) |
| `OffsetNormals` | `string` | Per-vertex subdivision normals (`3 * size^2` floats) |
| `Alphas` | `string` | Per-vertex blend alphas (`size^2` floats, Hammer parity) |
| `Looks` | `string` | Painted look palette as JSON |
| `TriLooks` | `string` | Per-grid-triangle look and hole map |
| `Removed` | `string` | Per-vertex removal flags (`1` removed, `0` kept) |
| `Rev` | `string` | Session-unique save token for per-tile cache validation |

### Encoding details

- **Scalar lists** (`Distances`, `Alphas`): comma-separated floats formatted with `%.6g`.
- **Vector lists** (`Normals`, `Offsets`, `OffsetNormals`): flat comma-separated `x,y,z` triplets formatted with `%.6g`.
- **`Looks`**: JSON array of `{ "m": material, "c": hexColor, "v": variant }`. Omitted on unpainted tiles without holes; saved as `[]` when a tile has holes and no paint.
- **`TriLooks`**: one character per grid triangle (`0` base look, `1`..`9` and `a`..`z` for looks 1..35, `-` for a hole).
- **`Removed`**: one character per vertex (`size^2`). Corners are never removed.

> [!NOTE]
> `TriLooks` is always indexed by the full grid triangle count, even when points have been removed by **Simplify**.

## Painted looks and holes

### Painted looks

Because Roblox parts cannot blend two textures by vertex alpha like Hammer, the **Material** tool assigns a whole **look** (`material`, `color`, `variant`) per grid triangle.

- **Palette compaction**: `Displacement.compactLooks` drops unused looks on save and renumbers the remaining entries so baked `Surface_<k>` unions match the saved palette.
- **Detail changes and splitting**: `changePower` resamples looks at each new grid triangle's center; **Split 2x2** copies looks triangle for triangle.

### Holes

Deleted triangles are stored as `Displacement.HOLE` (`-1`) and serialized as `-` in `TriLooks`.

- **Lossless hiding**: vertices stay intact, so sewing, stitching, and sculpt brushes treat the tile as continuous and **Fill holes** restores the exact surface.
- **Editing vs. baked**: editing keeps hidden hole wedges (`Transparency = 1`, collision/query/shadow off) for stable wedge numbering; baking omits holes completely.
- **Detail changes and splitting**: lowering detail keeps a coarse triangle solid if any covered fine triangle is solid. **Split 2x2** omits all-hole quarters.

## Mesh simplification

Source: `src/Core/Mesh.luau`, `src/Core/Simplify.luau`

Removing vertices with **Mesh > Simplify** lowers triangle count without losing vertex data. Normals, distances, and offsets remain stored so restoring a point recovers the surface.

### Delaunay triangulation

Shown triangles come from a deterministic Bowyer-Watson Delaunay triangulation of kept vertices on the flat grid. The 4 corners always remain, and circumcircle ties favor Hammer's checkerboard diagonal so untouched cells keep their original split. Triangulations are cached across sculpt strokes.

### Shown vs. grid triangles

- **Geometry vs. paint**: wedges, baking, raycasts, and sculpt brushes operate on **shown triangles**; looks and holes remain indexed by **grid triangle**.
- **Look resolution**: each shown triangle displays the majority look of the grid triangles it covers (falling back to the grid triangle under its center for thin triangles).
- **Whole-triangle writes**: `TriangleBrush` writes every grid triangle under an affected shown triangle so hidden paint never accumulates, and includes large shown triangles whose surface enters the inner half of the brush.

### Re-projection and seams

- **Re-projection**: after kept vertices move, `Displacement.reproject` projects removed vertices onto the shown surface so restoring them lands cleanly and smoothing never reads stale heights.
- **Exact edits**: **Stitch** and **Round folds** restore any removed vertex they move (`Session.updateMoved`) so it does not snap back.
- **Seam closing**: `Edges.closeRemovedSeams` pulls neighboring edge vertices onto a simplified tile's straight edge. `Actions/Mesh.applyMarks` and **Unsimplify** mirror edge marks across `Edges.seamTwins`. Corners, painted borders, and hole outlines are never removed.
- **Two-phase staging**: **Simplify** previews new edges and triangle counts in `Scene/MeshStage` before committing in one undo step on **Apply** (<kbd>Enter</kbd> or <kbd>X</kbd>).
- **Auto-simplify**: `Actions/Mesh.selectFlat` greedily removes vertices from flattest to steepest while keeping every shown triangle within **Max angle** of every original grid triangle underneath.

## Studio appearance sync

`TerrainInstance.adoptAppearance` runs before rebuilding wedges or baking. Direct `Material`, `Color`, or `MaterialVariant` edits made through Studio's Properties window or Material Manager on `Surface`, `Surface_<k>`, or an unpainted wedge are detected and saved back into `DispData`.
