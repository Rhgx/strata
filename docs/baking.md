# Baking

While a tile is being edited, Strata renders it as `WedgePart`s: 2 wedges per shown triangle (64 wedges at `Low`, 256 at `Medium`, 1,024 at `High`), each `0.2` studs thick hanging below the surface (`src/Core/WedgeBuilder.luau`). Baking merges a tile into a `UnionOperation` named `Surface`, plus one `Surface_<k>` union per painted look (`src/Core/TerrainInstance.luau`).

## Why tiles bake

Roblox projects material textures in each `BasePart`'s local coordinate space. Because each triangle's wedges have different sizes and orientations, textures break and rotate from triangle to triangle on unbaked tiles. Baking into one union per look gives each surface a single continuous texture projection and cuts the runtime instance count dramatically.

Whenever a baked tile is edited again, `TerrainInstance.ensureWedges` automatically unparents every `Surface` part and regenerates the wedges (with each triangle's look) from `DispData`.

## Baking pipeline (`TerrainInstance.bake`)

### 1. Sync Studio edits

`TerrainInstance.adoptAppearance` runs first so any `Material`, `Color`, or `MaterialVariant` edits made through Studio's Properties window or Material Manager are written into `DispData` before CSG runs.

### 2. Group triangles by look

Triangles are grouped by their displayed look (`DispData` `TriLooks`): look `0` (the tile's base look) and each painted look.

- Holes belong to no group and are omitted. A flat tile with holes skips the flat slab fast path, and a tile whose every triangle is a hole bakes nothing.
- If bake optimizations are enabled (see below), flat points are removed from a temporary copy before building temporary wedges for CSG; the tile's saved `DispData` always keeps full detail for future edits.
- Every look group bakes into its own union sharing the same anchor cube, so textures align across painted borders as well as across neighboring tiles.
- If any group fails, any unions already created are destroyed and the tile's wedges are restored.

### 3. Flat slab fast path

For a tile showing a single look with no holes, `flatSlab` checks whether the tile is still flat and rectangular before creating wedges:

- Every vertex has `distance <= 1e-4` and `offset.Magnitude <= 1e-4` (`FLAT_EPSILON`, above the `1e-5` length produced by `Displacement.normalizeWithLength` for zero vectors).
- The four base corners form a rectangle within tight dot-product and corner-closure tolerances.

When both hold, Strata builds one unparented temporary `Part` matching the rectangle's size and `WedgeBuilder.THICKNESS` (`0.2` studs) below the surface. Every newly created tile starts flat, and unioning one slab runs roughly 70x faster than unioning 64 to 1,024 wedges while producing identical geometry. During `Create` (`src/Actions/Create.luau`) with `Bake automatically` on, wedges are skipped completely (`skipWedges = true`) unless baking fails.

For sculpted, painted, or non-rectangular tiles, `ensureWedges` builds the needed wedges and passes them to CSG.

### 4. Anchor cube alignment

A `UnionOperation` inherits its `CFrame` (and local texture projection origin and axes) from the first part passed to `GeometryService:UnionAsync`. Passing the first wedge would project textures at different angles and offsets on neighboring tiles.

To lock texture alignment across tiles:

1. Strata computes the centroid of triangle 1 and finds the lowest displaced vertex along `faceNormal`.
2. It creates a tiny unparented cube (`ANCHOR_SIZE = 0.05` studs) with `model:GetPivot().Rotation`, placed at `lowest - WedgeBuilder.THICKNESS - ANCHOR_DEPTH` (`1.2` studs below the lowest vertex along `faceNormal`).
3. Passing this cube first to `UnionAsync` locks the union's `CFrame` to the tile's pivot rotation and corner-relative origin.
4. Keeping the cube strictly clear of the surface avoids a Roblox CSG failure mode where an overlapping anchor causes `UnionAsync` to collapse and return only the cube.

All helper parts (`anchor`, `cutter`, and any `slab`) stay unparented so they never enter `workspace` or Studio's undo history.

### 5. Two-step CSG and collision fidelity

Each look group runs a two-step CSG sequence:

1. **Intermediate union (`Box` collision)**: calls `GeometryService:UnionAsync(anchor, parts, { CollisionFidelity = Enum.CollisionFidelity.Box, RenderFidelity = Enum.RenderFidelity.Precise, SplitApart = false })`. Skipping convex decomposition on this discarded intermediate saves roughly a quarter to half of bake time.
2. **Collapse check**: verifies `result.Size.Magnitude >= expectedExtent * 0.5`, where `expectedExtent` is the diagonal of the group's vertex bounds (so small painted patches pass). If the union fails or collapses, wedges stay intact and an error is raised.
3. **Subtract anchor cube (`PreciseConvexDecomposition`)**: removes the anchor cube via `GeometryService:SubtractAsync` using a 3x larger cube (`0.15` studs) at the same `CFrame`, with `CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition`, `RenderFidelity = Enum.RenderFidelity.Precise`, and `SplitApart = false`. The result keeps the anchor cube's `CFrame`.
4. **Fallback**: if `SubtractAsync` fails or collapses, Strata re-runs `UnionAsync` directly with `PreciseConvexDecomposition` so the tile never ships with `Box` collision (leaving the harmless `0.05`-stud speck below the surface).

### 6. Final properties and undo safety

Each resulting `UnionOperation` receives:

- `Name = "Surface"` for the base look, or `Surface_<k>` for painted look `k`
- `Anchored = true`, `CanTouch = false`, `UsePartColor = true`
- `Material`, `Color`, and `MaterialVariant` from its look in `DispData`
- `SmoothingAngle = smoothingAngle`

Existing wedges are unparented (`part.Parent = nil`) rather than destroyed so `ChangeHistoryService` undo restores them intact. If a bake fails after a simplified copy, slab, or rebake left a tile without wedges, Strata regenerates its wedges before reporting the error.

## Bake optimizations (`Settings > Baking > Optimization`)

`Session.bake` passes these settings to `TerrainInstance.bake` as `BakeOptions`. All of them affect only the baked geometry; saved `DispData` always retains full edit detail.

| Setting | State key | Default | Range | Effect |
| --- | --- | --- | --- | --- |
| `Simplify` | `bakeSimplifyAngle` | `1` deg | `0` to `10` (`0` = off) | Removes interior vertices whose grid triangles agree within this angle (`Simplify.flatPointsQuick`). |
| `Tolerance` | `bakeHeightTolerance` | `0.05` st | `0` to `0.5` (`0` = off) | Also removes interior vertices within this distance of the plane through their four neighbors, catching noise and minor brush wobble. |
| `Simplify straight edges` | `bakeSimplifyEdges` | On | Boolean | Runs Ramer-Douglas-Peucker (`0.005` stud tolerance) along each tile edge, split at corners and painted borders, keeping T-junctions crack-free. |
| `Plain Part for flat tiles` | `bakeFlatPart` | Off | Boolean | Keeps a flat slab as a plain `Part` (`Surface` or `Surface_<k>`) instead of unioning it. Off by default because a `Part`'s texture origin can differ from neighboring unions. |
| `No shadow on flat tiles` | `bakeFlatNoShadow` | Off | Boolean | Sets `CastShadow = false` on baked surfaces whose grid triangles all lie within `max(Simplify, 1)` deg of the face and whose vertices stay within `max(Tolerance, 0.001)` st of one height. Off by default so tunnels or structures under flat ground stay shaded. |

### Repair loop and guarantees

After `Simplify.flatPointsQuick` removes candidate vertices, a repair loop builds the triangulation and checks every new shown triangle against the original surface:

- A triangle passes if it bends no more than `Simplify` degrees from every grid triangle under it, or if every original vertex under it lies within the height allowance (`Tolerance`, or at least `0.005` studs when straight-edge simplification is on).
- For each failing triangle, the removed vertex underneath it that strays farthest is restored. Because every check compares against the original surface, error never accumulates across passes.
- Triangles already shown due to manual Mesh tool simplification are exempt, so tiles simplified at a wider angle still benefit from bake optimizations.
- Corners, painted borders, and hole outlines are always preserved.
- If the loop does not settle within 24 passes, the tile bakes at full detail. Otherwise, its final triangulation is reused directly to build the temporary CSG wedges.

On a half-flat `High` tile, `Simplify` alone cuts 512 triangles to 208 and more than halves bake time; on a noisy sloped tile, `Simplify`, `Tolerance`, and `Simplify straight edges` together reduced 128 triangles to 27 and cut bake time from 0.18 s to 0.06 s.

When `Plain Part for flat tiles` is enabled and the slab aligns with the tile pivot's axes, the `Part` inherits the pivot's rotation (with its size permuted to match) so texture axes match neighboring unions. `TerrainInstance.surfaces` accepts both `Part` and `UnionOperation`, and `Bake.applySmoothing` skips plain `Part`s.

`TerrainInstance.bake` returns both shown and baked triangle counts (2 for a flat slab), and status reports show the savings when optimizations reduce triangles (for example `Rebaked 6 tiles (768 to 12 triangles).`). Use **Rebake all** in `Settings > Baking` to apply changed options to already-baked tiles in one undo step.

## Smoothing angle

`Settings.smoothingAngle` defaults to `45` degrees (range `0` to `180`, step `5`; `0` gives flat shading). Submitting a new value calls `Bake.applySmoothing` (`src/Actions/Bake.luau`), which updates `SmoothingAngle` on every baked `UnionOperation` in the place in one undo step without re-running CSG.

## When baking runs

- **Auto-bake (`Settings.autoBake`, on by default)**:
  - `Create` and single-step `Shape` / `Edges` / `Mesh` actions bake inside their own undo recording (`Recording.autoBake` in `src/Actions/Recording.luau`).
  - Interactive viewport tools (`BrushTool`, `MaterialTool`, `MeshTool`, `StitchTool`) keep edited tiles as wedges while active (`Session.markDirty`) and call `Bake.bakeEdited()` as a separate undo step when the last editing tool stops.
- **Manual baking**:
  - Select tiles and click `Bake` or `Unbake` on the `Tiles` page (`Bake.bakeSelected`, `Bake.unbakeSelected`).
  - Click `Bake all` on the `Overview` page (`Bake.bakeAll`), or `Rebake all` in `Settings > Baking` (`Bake.rebakeAll`).
- **Progress and re-entrancy**: multi-tile bakes post `Baking i of N...` to the status bar, and starting a second bake while one is running is refused.
