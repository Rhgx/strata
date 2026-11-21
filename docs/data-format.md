# Data Format and Instance Layout

Strata stores terrain using standard Roblox instances, attributes, and a single `CollectionService` tag. A tile needs no external assets or plugin state to exist in a place, so it can be published to Roblox, saved as a `.rbxm` model, inserted into another place, and reopened by Strata for editing.

## Instance layout

Defined in `src/Core/TerrainInstance.luau`:

```text
<Model>  tagged StrataDisplacement, WorldPivot = displacement origin
├─ DispData (Configuration)   editable source data, stored as attributes
├─ Tris (Folder)              generated WedgeParts ("1", "2", ...), while editing
├─ Surface (UnionOperation)   merged wedges in the tile's own look, once baked
└─ Surface_1, Surface_2, ...  one union per painted look (look 1, 2, ...), once baked
```

- A tile is either **editing** (populated `Tris` folder, no unions) or **baked** (one or more `Surface` unions present, `Tris` empty). `TerrainInstance.surfaces` lists them and `TerrainInstance.isBaked` checks for any.
- A union can only have one material, so each painted look bakes into its own `Surface_<k>`. `Surface` is missing when paint covers every triangle of the tile.
- When `Create` (`src/Actions/Create.luau`) converts a part with multiple faces or multiple tiles, it groups the tiles inside a container `Model` named `TerrainArea` (individual tiles are named `Disp_<ix>_<iz>` for a single face or `<FaceId>_<ix>_<iz>` for multiple faces). A single-face, single-tile conversion creates a standalone `Model` named `Displacement`.
- Every tile `Model` carries the `CollectionService` tag `StrataDisplacement` (`TerrainInstance.TAG`). `Scene/Session.models()` discovers all tagged `Model`s under `workspace`.

## Grid layout and surface math

Defined in `src/Core/Displacement.luau`.

A displacement turns a 4-sided quad into a regular vertex grid controlled by `Power`:

| Power | UI label | Grid vertices | Quads | Triangles | Wedges (editing) |
| --- | --- | --- | --- | --- | --- |
| `2` | Low (5x5) | 5x5 (25) | 16 | 32 | 64 |
| `3` | Medium (9x9) | 9x9 (81) | 64 | 128 | 256 |
| `4` | High (17x17) | 17x17 (289) | 256 | 512 | 1,024 |

- Vertices per side: `size = 2^power + 1`. Total vertices: `size * size`.
- All stored geometry (`Corner1` through `Corner4`, `Normals`, `Offsets`, and `OffsetNormals`) is in the owning model's local space (relative to `model:GetPivot()`), so moving or rotating the model in Studio does not invalidate the data.
- Corner winding and row-major indexing follow Source's surface points:
  - Rows run from `Corner1` to `Corner2` (and `Corner4` to `Corner3` on the opposite edge).
  - Columns run from the `Corner1`/`Corner2` edge to the `Corner4`/`Corner3` edge.
  - Vertex indices are 1-based: `index = row * size + col + 1`.
- Each vertex's local position matches Source's `CCoreDispInfo::GenerateDispSurf`:

```text
flat     = bilinear interpolation across Corner1..Corner4
position = flat + normal * distance + offset + faceNormal * elevation
```

where `faceNormal = ((Corner2 - Corner1):Cross(Corner4 - Corner1)).Unit`.

- Each quad `(row, col)` splits into two triangles in a checkerboard (diamond) pattern: even quads `(row + col) % 2 == 0` split along `v00-v11`, and odd quads split along `v01-v10`.

## `DispData` attributes

Serialized and deserialized by `Displacement.save` and `Displacement.load` in `src/Core/Displacement.luau`:

| Attribute | Type | Required | Description |
| --- | --- | --- | --- |
| `Version` | `number` | Yes | Format version, currently `1`. Loading rejects other versions. |
| `Power` | `number` | Yes | Grid power: `2`, `3`, or `4`. |
| `Elevation` | `number` | Yes | Uniform offset along `faceNormal` in studs (default `0`). |
| `Corner1`..`Corner4` | `Vector3` | Yes | The four flat base corners in model-local space. |
| `Material` | `string` | Yes | `Enum.Material` name (for example `"Grass"`, `"Rock"`). |
| `Color` | `Color3` | Yes | Tile color. |
| `MaterialVariant` | `string` | No | `MaterialVariant` name from `MaterialService`. Omitted when empty (base material). |
| `Subdiv` | `boolean` | Yes | `true` once `Round` (`Subdivide`) has written offsets; `false` otherwise. |
| `Normals` | `string` | No | Per-vertex field direction vectors (`3 * size^2` floats). Omitted when all equal `Vector3.zero`. |
| `Distances` | `string` | No | Per-vertex field distances (`size^2` floats). Omitted when all equal `0`. |
| `Offsets` | `string` | No | Per-vertex subdivision offsets (`3 * size^2` floats). Omitted when all equal `Vector3.zero`. |
| `OffsetNormals` | `string` | No | Per-vertex subdivision normals (`3 * size^2` floats). Omitted when all equal `faceNormal`. |
| `Alphas` | `string` | No | Per-vertex blend alphas (`size^2` floats). Omitted when all equal `0`. Kept for Hammer parity; Roblox parts do not blend textures by vertex alpha. |
| `Looks` | `string` | No | Painted looks as a JSON array of `{ "m": material name, "c": hex color, "v": variant }`. Omitted on unpainted tiles. |
| `TriLooks` | `string` | No | One character per triangle (`2 * (size - 1)^2`): `0` for the tile's own look, `1` to `9` then `a` to `z` for painted looks 1 to 35. Omitted on unpainted tiles. |

### List encoding and omission

- Numeric lists (`Distances`, `Alphas`) are encoded as comma-separated floats formatted with `%.6g`.
- Vector lists (`Normals`, `Offsets`, `OffsetNormals`) are encoded as flat comma-separated `x,y,z` triplets formatted with `%.6g`.
- Any per-vertex list whose values all match its default is removed (`SetAttribute(name, nil)`) on save and reconstructed with default values on load. Because `DispData` ships inside the place file, omitting untouched lists keeps flat and unsubdivided tiles compact.

### Painted looks

The Material tool (`src/Viewport/MaterialTool.luau`) paints looks per triangle, the smallest piece a tile can show. Hammer blends two textures by vertex alpha instead, which Roblox parts cannot do, so `Alphas` stays unused. On save, `Displacement.compactLooks` drops looks no triangle uses and renumbers the rest, so the `Surface_<k>` unions created at bake time always match the saved palette. Detail changes resample looks by each new triangle's center (`resampleLooks`), and `Split 2x2` copies them triangle for triangle, since quarter quads line up exactly with parent quads.

## Syncing Studio appearance edits

`TerrainInstance.adoptAppearance` (`src/Core/TerrainInstance.luau`) runs before rebuilding wedges or baking. If a builder changes `Material`, `Color`, or `MaterialVariant` directly on the baked `Surface` or wedges using Studio's Properties window or Material Manager, Strata detects the mismatch against `DispData` and saves the part's current appearance back into `DispData` so those edits are preserved. Painted looks are adopted the same way from their `Surface_<k>` unions. The tile's own look is read from `Surface`, or from a wedge of an unpainted triangle, never from a painted one.
