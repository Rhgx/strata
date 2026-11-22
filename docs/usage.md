# Using Strata

Tools, viewport shortcuts, sculpt axes, cursors, Edit points, and settings reference.

## Contents

[Viewport shortcuts](#viewport-shortcuts) | [Sculpt axes](#sculpt-axes) | [Edit points](#edit-points) | [Viewport cursors](#viewport-cursors) | [Settings](#settings)

## Viewport shortcuts

All eight tools, **Edit points**, and **Toggle panel** register bindable actions under **File > Advanced > Customize Shortcuts** (search for `Strata`). While a tool runs, a shortcut strip appears along the bottom of the 3D view (toggle under **Settings > Interface > Show viewport key hints**).

### Shared shortcuts

| Shortcut | Action |
| --- | --- |
| <kbd>Ctrl</kbd> + Scroll or <kbd>[</kbd> / <kbd>]</kbd> | Resize brush **Radius** or Stitch **Reach** |
| <kbd>Alt</kbd> + Drag | Resize brush **Radius** horizontally |
| <kbd>Esc</kbd> | Close overlay, cancel pipette, clear staged marks/picks, or stop tool |
| <kbd>Ctrl</kbd> + <kbd>Z</kbd> | Undo last step |

### Tool shortcuts

| Tool | Shortcut | Action |
| --- | --- | --- |
| Sculpt (**Raise**, **Lower**, **Smooth**, **Raise To**) | Left Drag | Paint terrain |
| Sculpt (**Raise**, **Lower**) | <kbd>Ctrl</kbd> | Invert brush (**Raise** / **Lower**) |
| Sculpt (**Raise**, **Lower**, **Raise To**) | <kbd>Shift</kbd> | Temporarily switch to **Smooth** |
| Sculpt (**Raise To**) | <kbd>Ctrl</kbd> + Click | Sample target **Height** from terrain (or any part in **From: World**) |
| Sculpt (all) | <kbd>Alt</kbd> + Right Click | Pick world axis from hovered face (click sky for **Up (Y)**) |
| **Material** | Left Drag | Paint look (or erase in **Erase** mode) |
| **Material** | <kbd>Ctrl</kbd> | Swap between **Paint** and **Erase** while held |
| **Material** | <kbd>Alt</kbd> + Right Click | Sample look from hovered part or tile |
| **Mesh** | Left Drag | Stage points (**Simplify**) or cut triangles (**Cut holes**) |
| **Mesh** | <kbd>Ctrl</kbd> | Restore points (**Simplify**) or restore holes (**Cut holes**) |
| **Mesh** (**Simplify**) | Click | Toggle nearest vertex |
| **Mesh** (**Simplify**) | <kbd>Enter</kbd> or <kbd>X</kbd> | Apply staged marks |
| **Pick faces** | Click | Pick or unpick a part face |
| **Pick faces** | <kbd>Enter</kbd> | Create tiles from picked faces |
| **Stitch** | Click | Stitch nearby tile edges onto clicked part and joined sheet |

## Sculpt axes

The **Axis** dropdown on the brush page controls which direction sculpted vertices move:

| Axis | Direction |
| --- | --- |
| **Face normal** | Perpendicular to each tile's flat base |
| **Up (Y)**, **X**, **Z** | World coordinate axes |
| **Picked** | Custom world vector sampled with <kbd>Alt</kbd> + Right Click |
| **Curved (Round)** | Per-vertex smoothed normals written by **Round folds** |

## Edit points

Select one or more tiles and click **Edit points** on the Tiles page to place a handle on every editable vertex.

| Input | Action |
| --- | --- |
| Click, <kbd>Ctrl</kbd> + Click, or box drag | Select point handles in 3D |
| Studio **Move**, **Rotate**, **Scale** | Move points (each drag is one undo step; seams stay closed) |
| <kbd>Delete</kbd> | Remove selected points (tile corners always stay) |
| **Pivot > Origin** in Properties | Set exact world coordinates |

Click **Done** (or press the stop button) to return to the tile selection and bake edits if **Bake automatically** is enabled. For implementation details, see [Architecture: Edit points](architecture.md#edit-points).

## Viewport cursors

### Sculpt brushes

- **Radius ring**: drawn on the surface at the true radius, with a faint always-on-top copy so it stays readable in valleys.
- **Empty or pinned state**: the ring dims when it holds no kept point or when every hit point is pinned to a part, showing a `Pinned` label mid-stroke.
- **Modifier label**: holding <kbd>Ctrl</kbd> or <kbd>Shift</kbd> displays the active override mode next to the cursor.
- **Direction arrow**: **Raise** and **Lower** draw a 3D arrow for `X`, `Z`, `Picked`, and for `Up (Y)` on steep walls (tilted past ~45 degrees).
- **Point dots**: optional (**Settings > Interface > Show brush dots**, off by default). Marks kept points inside the ring weighted by falloff (hidden above 64 points), or up to 4 nearest points when the ring is empty.

### Other tools

- **Material** and **Mesh** (**Cut holes**): traces the outer perimeter of affected triangles (blue to paint or restore, red to erase or cut).
- **Mesh** (**Simplify**): highlights points a click or drag will remove or restore over a tile wireframe, including the nearest point.
- **Stitch** and **Pick faces**: highlights candidate parts, snap target lines, and picked faces.
- **Panel radius preview**: changing **Radius** in the panel shows a 1-second centered ring with a `Radius N st` label until the mouse moves over the viewport.

### Mouse cursor states

| State | Cursor |
| --- | --- |
| Baking in progress | Wait |
| <kbd>Alt</kbd> + Drag brush resize | Horizontal resize (`SizeEW`) |
| No terrain targets in place | Forbidden |
| Active brush tool | Crosshair |
| Click tool over valid / invalid target | Pointing hand / Arrow |

## Settings

Open **Settings** from the gear icon in the bottom status bar:

- **Edges**: **Auto-sew after edits**, **Keep edges stitched**, and default stitch **Reach**.
- **Baking**: **Bake automatically**, union **Smoothing** angle, bake **Optimization** options ([Baking](baking.md#bake-optimizations)), and **Rebake all**.
- **Interface**: **Show viewport key hints**, **Show brush dots**, **Show tooltips**, and **Tools on Plugins ribbon**.
