# Baking

While a displacement is being sculpted or edited, it is rendered as `WedgePart`s (2 per triangle, from 64 wedges at power 2 up to 1,024 wedges at power 4, each `0.2` studs thick hanging below the surface; see `src/Core/WedgeBuilder.luau`). Baking merges a tile into a `UnionOperation` named `Surface` (`src/Core/TerrainInstance.luau`), plus one `Surface_<k>` union per painted look, since a Roblox union keeps per-part colors but only one material.

## Why tiles bake

Roblox projects material textures independently in each `BasePart`'s local coordinate space. Because each triangle's wedges have different orientations and dimensions, textures break and rotate from triangle to triangle while a tile is unbaked. Merging the tile into one `UnionOperation` gives the entire surface a single continuous texture projection and cuts the runtime instance count down to one part per tile.

Editing a baked tile automatically calls `TerrainInstance.ensureWedges`, which unparents every `Surface` union and regenerates the wedges (each with its triangle's look) from `DispData`.

## Baking pipeline (`TerrainInstance.bake`)

### 1. Sync Studio edits

`TerrainInstance.adoptAppearance` runs first so any `Material`, `Color`, or `MaterialVariant` changes made through Studio's own Properties window or Material Manager are written to `DispData` before CSG runs.

### 2. Grouping by look

Triangles are grouped by the look they show (`DispData` `TriLooks`): look `0` (the tile's own) and each painted look. Every group bakes into its own union, all sharing the same anchor cube (below), so textures line up across painted borders as well as across tiles. If any group fails, the unions already made are destroyed and the tile stays as wedges.

### 3. Flat slab fast path

Only a tile showing a single look can use the slab. Before touching wedges, `flatSlab` checks whether the tile is still flat and rectangular:

- Every vertex has `distance <= 1e-4` and `offset.Magnitude <= 1e-4` (`FLAT_EPSILON`, above the `1e-5` length that `Displacement.normalizeWithLength` produces for zero vectors).
- The four base corners form a rectangle within tight dot-product and corner-closure tolerances.

When both hold, Strata builds a single unparented temporary `Part` matching the rectangle's size and `WedgeBuilder.THICKNESS` (`0.2` studs) hanging below the surface. Every tile produced by `Create` starts flat, and unioning one slab runs roughly 70x faster than unioning 64 to 1,024 wedges while producing identical geometry. When `Bake automatically` is on during `Create` (`src/Actions/Create.luau`), wedges are skipped altogether (`skipWedges = true`) unless baking fails.

For sculpted or non-rectangular tiles, `ensureWedges` ensures every wedge exists and passes all wedges to CSG.

### 4. The anchor cube trick

A `UnionOperation` inherits its `CFrame` (and therefore its local texture projection axes and origin) from the first part passed to `GeometryService:UnionAsync`. If the first wedge determined the `CFrame`, neighboring tiles would project textures at different angles and offsets.

To align material projection across tiles:

1. Strata computes the centroid of triangle 1 and finds the lowest displaced vertex along `faceNormal`.
2. It creates a tiny unparented cube (`ANCHOR_SIZE = 0.05` studs) rotated to match `model:GetPivot().Rotation`, positioned below the centroid at `lowest - WedgeBuilder.THICKNESS - ANCHOR_DEPTH` (`1.2` studs below the lowest vertex along `faceNormal`).
3. Passing this cube as the first part to `UnionAsync` locks the union's `CFrame` to the tile's pivot rotation and corner-relative origin.
4. Placing the cube strictly clear of the surface avoids a Roblox CSG failure mode where an overlapping anchor part causes `UnionAsync` to silently collapse and return only the cube.

All temporary helper parts (`anchor`, `cutter`, and any `slab`) remain unparented so they never enter `workspace` or Studio's undo history.

### 5. Union then subtract, and collision fidelity

Each look group uses a two-step CSG sequence:

1. **Intermediate union (`Box` collision)**: calls `GeometryService:UnionAsync(anchor, parts, { CollisionFidelity = Enum.CollisionFidelity.Box, RenderFidelity = Enum.RenderFidelity.Precise, SplitApart = false })`. Because this union is discarded immediately after the subtract step, skipping convex decomposition here cuts roughly a quarter to half of total bake time.
2. **Collapse check**: verifies `result.Size.Magnitude >= expectedExtent * 0.5` (where `expectedExtent` is the diagonal of the group's vertex bounds, so small painted patches pass). If the union failed or collapsed, wedges are left untouched and an error is raised.
3. **Subtract anchor cube (`PreciseConvexDecomposition`)**: cuts the anchor cube away using `GeometryService:SubtractAsync` with a `3x` larger cube (`0.15` studs) at the same `CFrame`, with `CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition`, `RenderFidelity = Enum.RenderFidelity.Precise`, and `SplitApart = false`. The resulting union keeps the `CFrame` established by the anchor cube.
4. **Fallback**: if `SubtractAsync` fails or collapses, Strata re-runs `UnionAsync` directly with `PreciseConvexDecomposition` so the tile never ships with `Box` collision (leaving the harmless `0.05`-stud speck below the surface).

### 6. Final properties and undo safety

Each final `UnionOperation` is configured with:

- `Name = "Surface"` for the tile's own look, `Surface_<k>` for painted look `k`
- `Anchored = true`
- `CanTouch = false`
- `UsePartColor = true`
- `Material`, `Color`, and `MaterialVariant` from its look in `DispData`
- `SmoothingAngle = smoothingAngle`

Existing wedges are unparented (`part.Parent = nil`) rather than destroyed so `ChangeHistoryService` undo restores them intact.

## Smoothing angle

`Settings.smoothingAngle` (`src/State/Settings.luau`) defaults to `45` degrees (range `0` to `180`, step `5`; `0` gives flat shading). Submitting a new `Smoothing` value in Settings calls `Bake.applySmoothing` (`src/Actions/Bake.luau`), which updates `SmoothingAngle` on every baked `Surface` union in the place as a single undo step without re-running CSG.

## When baking runs

- **Auto-bake (`Settings.autoBake`, on by default)**:
  - `Create` and single-step `Shape` / `Edges` actions bake inside their own undo recording (`Recording.autoBake` in `src/Actions/Recording.luau`).
  - Interactive viewport tools (`BrushTool`, `MaterialTool` and `StitchTool`) keep edited tiles as wedges while active (`Session.markDirty`) and call `Bake.bakeEdited()` (`src/Actions/Bake.luau`) as its own undo step when the tool stops.
- **Manual baking**:
  - Select tiles and click `Bake` or `Unbake` on the `Tiles` page (`Bake.bakeSelected`, `Bake.unbakeSelected`).
  - Click `Bake all` on the `Overview` page (`Bake.bakeAll`) when unbaked tiles remain in the place.
