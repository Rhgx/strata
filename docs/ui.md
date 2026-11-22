# Panel UI

Strata's dock panel (`src/UI/`) is built with React-Lua, `StudioComponents`, and Lucide icons (`latte-soft/lucide-icons`, configured in `src/UI/Icons.luau`). It follows Roblox Studio's Properties window aesthetic and stays usable down to the widget's 220 px minimum width (~190 px inner content width).

## Panel layout (`src/UI/App.luau`)

The panel is split into three vertical regions:

1. **Tool strip (`src/UI/ToolStrip.luau`)**: a 30 px pinned bar at the top holding all eight viewport tools as 24x24 icon buttons (`Raise`, `Lower`, `Smooth`, `Raise To`, `Material`, `Mesh`, a vertical divider, then `Pick faces` and `Stitch`). Drawn by hand (`ToolButton`) so brush buttons can tint with tool accent colors. Hidden while `Settings` or `Help` is open.
2. **Context page (`src/UI/Pages/`)**: occupies the middle area, keyed by page name so switching contexts always resets scroll position to the top. Pages are chosen in this priority order:
   1. **Overlays (`SettingsPage`, `HelpPage`)**: shown when `settings.overlay` is `"settings"` or `"help"`. `Settings` pins three tabs (`Edges`, `Baking`, `Interface`) below its header; only the active tab's rows scroll, and the last opened tab persists for the Studio session. `Rebake all (N)` on `Baking` requires a second confirmation click within 4 seconds when a place has more than 20 tiles.
   2. **Active viewport tool**: `BrushPage` (`painting`), `MaterialPage` (`coloring`), `MeshPage` (`meshing`), `CreatePage` in pick mode (`picking`), or `StitchPage` (`stitching`). Every tool page opens with `Rows.title`: the tool's name plus an icon-only Stop button (`Esc`). In `MeshPage`'s `Simplify` mode, the `Result` row (`768 to 12 tris`) and `Apply` / `Clear` buttons appear below `Auto-simplify` only while points are staged so `Select flat` never shifts under the cursor.
   3. **Edit points (`PointsPage`)**: shown while `editingPoints` is on, since selecting point handles deselects the tiles. Shows `N of M selected` points, the edited tile count, how to move points with Studio's tools, `Select all points`, and `Done` (which selects the tiles again and bakes them when `Bake automatically` is on). Started from `Edit points` on `TilesPage` or its `PluginAction`.
   4. **Studio selection**: `TilesPage` when any tile is selected (even alongside normal parts, since `Sew tiles` uses them), or `CreatePage` when eligible block/wedge parts are selected.
   5. **Fallback (`OverviewPage`)**: shows total and baked tile counts (unbaked counts in `WarningText`), `Select all`, `Pick faces`, and `Bake all (N)` as the primary button when unbaked tiles exist (or getting-started steps in an empty place).
3. **Status bar (`src/UI/StatusBar.luau`)**: a 24 px pinned footer showing the latest `State/Status` message (green for success, `WarningText` for warnings, `ErrorText` for errors, `MainText` for progress like `Baking 3 of 12...`; click to dismiss; hover for full text) or a context-aware idle hint, plus the Settings gear and Help `?` overlay buttons on the right.

### Reactive hooks and helpers

- `src/UI/useSettings.luau`: subscribes components to `State/Settings`.
- `src/UI/useRefresh.luau`: re-renders on `Selection.SelectionChanged`, `ChangeHistoryService.OnUndo`/`OnRedo`, and `State/Status` updates.
- `src/UI/Icons.luau`: wraps `Lucide.GetAsset(name, 48)` with theme tinting (`16x16` in the tool strip and status bar; `14x14` in page buttons and dropdown items).
- `src/State/Format.luau`: comma-grouped counts, plurals, stud lengths (`Format.studs`), and hex / `"R, G, B"` color formatting shared across UI, status messages, and 3D labels.

## Viewport shortcuts and tools

All eight tools and Edit points register bindable `PluginAction`s under `File > Advanced > Customize Shortcuts` (`src/Viewport/Toolbar.luau`). While a tool runs, `KeyStrip` shows active shortcuts along the bottom of the 3D view (toggleable under `Settings > Interface > Show viewport key hints`).

### Shared shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl + Scroll` or `[` / `]` | Resize brush `Radius` or `Stitch` `Reach` |
| `Alt + Drag` | Resize brush `Radius` horizontally |
| `Esc` | Close overlay, cancel Material pipette, clear staged Mesh marks or Pick faces picks, or stop the active tool (in that order) |
| `Ctrl + Z` | Undo last step |

### Tool-specific shortcuts

| Tool | Shortcut | Action |
| --- | --- | --- |
| Sculpt (`Raise`, `Lower`, `Smooth`, `Raise To`) | `Left Drag` | Paint terrain |
| Sculpt (`Raise`, `Lower`) | `Ctrl` | Invert brush (`Raise` <-> `Lower`) |
| Sculpt (`Raise`, `Lower`, `Raise To`) | `Shift` | Temporarily switch to `Smooth` |
| Sculpt (`Raise To`) | `Ctrl + Click` | Sample target `Height` from terrain (or any visible part in `From: World`) |
| Sculpt (all) | `Alt + Right Click` | Pick world movement axis from hovered face (click sky to reset to `Up (Y)`) |
| `Material` | `Left Drag` | Paint look (or erase in `Erase` mode) |
| `Material` | `Ctrl` | Swap between `Paint` and `Erase` while held |
| `Material` | `Alt + Right Click` | Sample look from hovered part or tile |
| `Mesh` | `Left Drag` | Stage points (`Simplify`) or cut triangles (`Cut holes`) |
| `Mesh` | `Ctrl` | Restore points (`Simplify`) or restore holes (`Cut holes`) |
| `Mesh` (`Simplify`) | `Click` | Toggle nearest vertex |
| `Mesh` (`Simplify`) | `Enter` or `X` | Apply staged marks |
| `Pick faces` | `Click` | Pick or unpick a part face |
| `Pick faces` | `Enter` | Create tiles from picked faces |
| `Stitch` | `Click` | Stitch nearby tile edges onto the clicked part (and joined sheet) |
| Edit points | Studio's `Select`, `Move`, `Rotate`, `Scale` | Pick point handles (click, `Ctrl + Click`, drag a box) and move them; each drag or Properties edit is one undo step |
| Edit points | `Delete` | Remove the selected points (tile corners always stay) |

### Sculpt movement axes

`BrushPage` exposes six movement axes (`State/Settings`):

- **`Face normal`**: perpendicular to each tile's flat base.
- **`Up (Y)`**, **`X`**, **`Z`**: world coordinate axes.
- **`Picked`**: world-space unit vector sampled with `Alt + Right Click` (persisted in plugin settings).
- **`Curved (Round)`**: per-vertex `offsetNormals` written by `Round` (`Subdivide`).

## Color system (`src/UI/Accent.luau`)

The panel stays in Studio's neutral theme and uses color for three purposes only:

- **Tool identity**: each brush has one hue shared with its 3D cursor. Idle tool strip icons tint with that hue; the active brush fills its button with the hue and draws the icon in the normal button color.

| Tool | Accent color |
| --- | --- |
| `Raise` | Green |
| `Lower` | Red |
| `Smooth` | Blue |
| `Raise To` | Amber |
| `Material` | Teal |
| `Mesh` | Orange |
| `Pick faces`, `Stitch` | Neutral (Studio's blue selected state) |

- **Primary actions**: Studio's `MainButton` blue (`Rows.button` with `primary = true`), used at most once per page (`Create`, `Apply`, `Bake`, `Bake all`).
- **Feedback**: green for success in the status bar, `WarningText` for warnings, and `ErrorText` for errors.

Light themes get darker variants for contrast, detected from `MainBackground` brightness so custom Studio themes work too. Section headings stay `DimmedText`, with no decorative gradients, glows, or colored panels.

## Shared row helpers (`src/UI/Rows.luau`)

Layout constants: `LABEL_WIDTH = 66`, `ROW_HEIGHT = 22`, `BUTTON_HEIGHT = 24`, `GAP = 4`.

- `Rows.page(children)`: `StudioComponents.ScrollFrame` oversized by 1 px per side so the widget clips its outer border cleanly.
- `Rows.section`, `Rows.title`, `Rows.header`, `Rows.divider`: dimmed headings, tool headers (name + Stop button), overlay headers (back button + title), and 1 px themed dividers.
- `Rows.property`, `Rows.value`: two-column rows (66 px label, remaining width for control) with whole-row hover tooltips.
- `Rows.grid`: equal-width `UIGridLayout` rows (at most 2 columns for icon buttons at minimum panel width).
- `Rows.button`, `Rows.checkbox`, `Rows.withTooltip`: full-width controls with hover tooltips.
- `Rows.paragraph`: wrapping themed `TextLabel` using `AutomaticSize.Y` (since `StudioComponents.Label` does not auto-size).
- `Rows.collapsible`: chevron-headed section whose open/closed state persists per section ID for the Studio session.

## Tooltips and markup (`src/UI/Tooltip.luau`, `src/UI/Markup.luau`)

`Tooltip` wraps one child in a transparent frame. After hovering `0.4` s, it converts the tooltip string through `Markup.toRichText`, measures wrapped bounds via `TextService:GetTextBoundsAsync` (max `240` px or widget width), clamps inside the `PluginGui`, and renders via `ReactRoblox.createPortal` at `ZIndex = 1000` so scroll frames never clip it. Clicking inside hides the tooltip until the mouse leaves and re-enters.

`Markup.toRichText` escapes `&`, `<`, and `>` and supports a compact RichText subset:

| Syntax | RichText output |
| --- | --- |
| `**bold**` | `<b>bold</b>` |
| `` `Ctrl + Z` `` | `<b>Ctrl + Z</b>` (keys and UI labels) |
| `*italic*` | `<i>italic</i>` |
| `- item` | Bullet line (`\u{2022} item`) |
| `> note` | Dimmed line (`<font transparency="0.35">note</font>`) |
| Blank line | 6 px vertical spacer (`<font size="6"> </font>`) |

## Custom `Dropdown` (`src/UI/Dropdown.luau`)

Adapted from `StudioComponents`' `Dropdown` (MIT licensed, Copyright (c) 2025 sircfenner; full license preserved in `src/UI/Dropdown.luau`) with Studio/Qt combo box keyboard behavior:

- **Type-ahead search**: typing jumps to the first matching prefix (keystrokes within `1` s form one query); repeating one letter cycles through items starting with it.
- **Keyboard navigation**: `Up`/`Down` step one item, `Home`/`End` jump to ends, `Space` or `F4` opens the list, `Enter` or `Space` commits, `Esc` closes.
- **Closed-list debounce**: stepping through options while closed previews immediately and commits `0.35` s after the last key, keeping multiple presses in one undo step.
- **Plugin widget input**: because `UserInputService` ignores input inside `PluginGui` widgets, a focused dropdown mounts a transparent, non-`Active` frame over the widget to capture keys and detect outside clicks without blocking underlying controls.

## Color editing (`src/UI/ColorField.luau`, `src/UI/ColorPicker.luau`)

`ColorField` combines a `22x22` swatch button, a text input, and an optional pipette button (`SampleTool` on `TilesPage`, look picker on `MaterialPage`) in one row. The text input accepts `#RRGGBB`, `RRGGBB`, `#RGB`, and `"R, G, B"` (matching Studio's Properties copy format).

On `MaterialPage`, a `Paint` / `Erase` toggle sits at the top (`Settings.paintErase`, persisted; `Ctrl` swaps them while held), and a `Recent` strip below the color row shows up to 6 recently painted or picked looks (`Settings.recentLooks`, persisted, newest first) with the active look outlined.

Clicking the swatch opens `ColorPicker` inline with four modes (`RGB`, `HSV`, `Hex`, `Brick`):

- **`RGB`, `HSV`, `Hex`**: mode-specific inputs beside a 140 px saturation/brightness square and a 12 px hue bar.
- **`Brick`**: Studio's `BrickColor` palette as a 13-row hexagon of 127 colors above 12 grays, matching Studio's colors, order, and layout.

Drags track pointer movement through a transparent full-widget overlay button (the same `PluginGui` workaround as `Dropdown`), calling `onPreview` during drags and `onCommit` once on release so each drag records one undo step.

## Viewport cursors and radius preview

- **Sculpt brushes**: a single radius ring on the surface at the real radius (paired with a faint always-on-top copy so it stays readable in valleys). When the ring holds no point (or every hit point is pinned during a drag), it dims and shows `Pinned` mid-stroke; holding `Ctrl` or `Shift` shows the overridden mode name next to the cursor; and `X`, `Z`, and `Picked` axes draw a 3D direction arrow at the cursor. Turning on `Settings > Interface > Show brush dots` (off by default) also draws always-on-top dots on every kept point inside the ring, more solid where the brush pushes harder (hidden above 64 points), and faint dots on up to 4 nearest points when the ring is empty.
- **`Material` and `Mesh` (`Cut holes`)**: `TriangleOutline` traces the outer edges of the exact shown triangles a click will modify (blue to paint or restore, red to erase or cut).
- **`Mesh` (`Simplify`)**: highlights the points a click or drag will remove or restore over a wireframe of the hovered tile, including the nearest point a click always toggles.
- **`Stitch` and `Pick faces`**: highlight candidate parts, edges, and faces.
- **Mouse icons (`Viewport/Cursor`, `Viewport/Activation`)**: `Wait` while baking, `SizeEW` during `Alt + Drag` resize, `Forbidden` when no targets exist, `Cross` for brush tools, and `PointingHand` / `Arrow` for click tools based on hover validity.
- **Panel radius preview (`Viewport/RadiusPreview`)**: changing `Radius` in the panel draws the brush ring at the center of the 3D view (or a camera-facing ring if no terrain is centered) with a `Radius N st` label for about a second, ending as soon as the mouse moves over the viewport.
