# Baking

How Strata merges editing wedges into continuous `UnionOperation` surfaces, aligns textures across tiles, and optimizes baked geometry.

## Contents

[Why tiles bake](#why-tiles-bake) | [Pipeline at a glance](#pipeline-at-a-glance) | [Baking steps](#baking-steps) | [Bake optimizations](#bake-optimizations) | [Smoothing and triggers](#smoothing-and-triggers)

## Why tiles bake

While editing, each tile renders as 2 `WedgePart`s per shown triangle (64 at Low, 256 at Medium, 1,024 at High), `0.2` studs thick below the surface (`src/Core/WedgeBuilder.luau`). Because Roblox projects material textures in each part's local space, textures rotate and break across unbaked wedges.

Baking (`src/Core/TerrainInstance.luau`) merges each look on a tile into one union (`Surface` for the base look, `Surface_<k>` per painted look) for continuous texture projection and far fewer runtime instances. Editing a baked tile automatically restores wedges from `DispData`.

## Pipeline at a glance

1. **Sync Studio edits**: save any Properties or Material Manager edits back into `DispData`.
2. **Group by look**: split non-hole triangles by look and apply optional bake simplification to a temporary copy.
3. **Flat slab fast path**: replace flat rectangular single-look tiles with one temporary slab instead of wedges.
4. **Anchor cube alignment**: pass a tiny unparented pivot-aligned cube first so `UnionAsync` locks texture axes.
5. **Two-step CSG**: union with `Box` collision, check for collapse, then subtract the anchor with `PreciseConvexDecomposition`.
6. **Swap and save**: apply material/smoothing properties and unparent old wedges for undo safety.

## Baking steps

Source: `TerrainInstance.bake` in `src/Core/TerrainInstance.luau`

### 1. Sync Studio edits

`TerrainInstance.adoptAppearance` captures any `Material`, `Color`, or `MaterialVariant` edits made directly in Studio before CSG runs.

### 2. Group triangles by look

Triangles are grouped by displayed look (`0` for base look, `1..35` for painted looks):

- Holes belong to no group and are omitted. All-hole tiles bake nothing.
- When bake optimizations are enabled, flat points are removed on a temporary copy before building temporary CSG wedges.
- Every look group shares the same anchor cube so textures align across painted borders and neighboring tiles.
- If any group fails, unions already built for that tile are destroyed and wedges are restored.

### 3. Flat slab fast path

For a single-look tile with no holes, `flatSlab` checks that every vertex has `distance <= 1e-4` and `offset.Magnitude <= 1e-4` (`FLAT_EPSILON`) and that the four corners form a rectangle.

When true, Strata builds one unparented `Part` matching the rectangle and thickness (`0.2` studs). Unioning one slab runs ~70x faster than unioning 64 to 1,024 wedges. During **Create** with **Bake automatically** enabled, wedges are skipped entirely (`skipWedges = true`) unless baking fails.

### 4. Anchor cube alignment

`UnionOperation` inherits its `CFrame` (and texture projection axes) from the first part passed to `GeometryService:UnionAsync`. To lock alignment across tiles:

1. Find the lowest displaced vertex along `faceNormal` and triangle 1's centroid.
2. Create an unparented `0.05`-stud cube using `model:GetPivot().Rotation`, placed `1.2` studs (`THICKNESS + ANCHOR_DEPTH`) below the lowest vertex.
3. Pass the cube first to `UnionAsync`. Keeping it clear of the surface avoids a CSG collapse bug where an overlapping anchor returns only the cube.

All helper parts stay unparented so they never enter `workspace` or undo history.

### 5. Two-step CSG and collision fidelity

1. **Intermediate union (`Box`)**: runs `UnionAsync` with `CollisionFidelity.Box`, `RenderFidelity.Precise`, and `SplitApart = false`, saving ~25 to 50% of bake time on the discarded intermediate.
2. **Collapse check**: verifies `result.Size.Magnitude >= expectedExtent * 0.5`. If collapsed, wedges stay intact and an error is raised.
3. **Subtract anchor (`PreciseConvexDecomposition`)**: removes the anchor using a `0.15`-stud cutter at the same `CFrame` while keeping its texture alignment.
4. **Fallback**: if `SubtractAsync` fails or collapses, Strata runs `UnionAsync` directly with `PreciseConvexDecomposition` so a tile never ships with `Box` collision.

### 6. Final properties and undo safety

Each resulting `UnionOperation` gets `Name = "Surface"` (or `Surface_<k>`), `Anchored = true`, `CanTouch = false`, `UsePartColor = true`, its look's appearance, and `SmoothingAngle`. Old wedges are unparented (`Parent = nil`) rather than destroyed so <kbd>Ctrl</kbd> + <kbd>Z</kbd> restores them intact.

## Bake optimizations

Settings under **Settings > Baking > Optimization** are passed as `BakeOptions`.

> [!NOTE]
> Bake optimizations only simplify the baked surface geometry. Saved `DispData` always keeps full grid detail for future edits.

| Setting | State key | Default | Range | Effect |
| --- | --- | --- | --- | --- |
| **Simplify** | `bakeSimplifyAngle` | `1` deg | `0` to `10` | Omits interior points flatter than this angle |
| **Tolerance** | `bakeHeightTolerance` | `0.05` st | `0` to `0.5` | Omits interior points within this height of neighbors |
| **Simplify straight edges** | `bakeSimplifyEdges` | On | Boolean | Ramer-Douglas-Peucker (`0.005` st) along straight edges |
| **Plain Part for flat tiles** | `bakeFlatPart` | Off | Boolean | Keeps flat single-look slabs as a plain `Part` |
| **No shadow on flat tiles** | `bakeFlatNoShadow` | Off | Boolean | Sets `CastShadow = false` on flat baked tiles |

Defaults note:
- **Plain Part for flat tiles** is off by default because a plain `Part`'s texture origin can differ from adjacent unions (when aligned with the tile pivot, Strata matches rotation and permutes size to align axes).
- **No shadow on flat tiles** is off by default so tunnels or interiors beneath flat ground stay shaded.

### Repair loop and guarantees

After `Simplify.flatPointsQuick` marks candidates, a repair loop checks every resulting shown triangle against the original surface:

- A triangle passes if it stays within **Simplify** degrees of every covered grid triangle, or every covered vertex stays within **Tolerance** (at least `0.005` st with straight-edge simplification on).
- Failing triangles restore their farthest removed vertex. Comparing against the original surface prevents error accumulation.
- Corners, painted borders, and hole outlines are always preserved; manually simplified triangles are exempt.
- If the loop does not settle within 24 passes, the tile bakes at full detail.

### Measured savings

| Tile | Options | Triangles | Bake time |
| --- | --- | --- | --- |
| Half-flat High tile | **Simplify** alone | 512 -> 208 | > 2x faster |
| Noisy sloped tile | **Simplify** + **Tolerance** + straight edges | 128 -> 27 | 0.18 s -> 0.06 s |

Status messages report savings whenever optimizations reduce triangles. Use **Rebake all** in **Settings > Baking** to apply updated options to existing baked tiles in one undo step.

## Smoothing and triggers

- **Smoothing angle**: defaults to `45` deg (`0` to `180`, step `5`; `0` = flat shaded). Changing it calls `Bake.applySmoothing`, updating `SmoothingAngle` on every baked union in one undo step without re-running CSG (plain `Part` surfaces are skipped).
- **Auto-bake** (**Settings > Baking > Bake automatically**, on by default): **Create** and single-step actions bake inside their own recording. Interactive viewport tools mark tiles dirty and call `Bake.bakeEdited()` when the last editing tool stops.
- **Manual baking**: use **Bake** / **Unbake** on the Tiles page, **Bake all** on the Overview page, or **Rebake all** in **Settings > Baking**.
- **Progress and cancel**: multi-tile bakes display `Baking i of N...` with a cancel button in the status bar (cancelling keeps tiles already finished) and block concurrent bakes.
