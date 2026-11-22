# Panel UI

Dock widget layout, accent color system, shared `Rows` helpers, tooltips, and custom controls.

For end-user shortcuts, sculpt axes, and viewport cursors, see [Using Strata](usage.md).

## Panel layout

Source: `src/UI/App.luau`

The panel is built with React-Lua, `StudioComponents`, and Lucide icons (`latte-soft/lucide-icons`) and stays usable down to the 220 px minimum dock width (~190 px inner content width). It has three vertical regions:

1. **Tool strip** (`src/UI/ToolStrip.luau`): 30 px pinned top bar holding all eight viewport tools as 24x24 icon buttons (`Raise`, `Lower`, `Smooth`, `Raise To`, `Material`, `Mesh`, divider, `Pick faces`, `Stitch`). Drawn by hand (`ToolButton`) for tool accent tinting; hidden while an overlay is open.
2. **Context page** (`src/UI/Pages/`): middle scrollable area keyed by page name so switching contexts resets scroll to the top.
3. **Status bar** (`src/UI/StatusBar.luau`): 24 px pinned footer showing `State/Status` messages (click to dismiss, hover to pause expiry and read full text) or an idle hint, plus cancel (during multi-tile bakes), Settings, and Help buttons.

### Page priority

| Priority | Shown when | Page |
| --- | --- | --- |
| 1 | **Settings** or **Help** overlay is open | `SettingsPage`, `HelpPage` |
| 2 | A viewport tool is active | `BrushPage`, `MaterialPage`, `MeshPage`, `CreatePage` (pick), `StitchPage` |
| 3 | **Edit points** is active | `PointsPage` |
| 4 | Any tile is selected (even with normal parts) | `TilesPage` |
| 5 | Eligible block/wedge parts are selected | `CreatePage` |
| 6 | Fallback (nothing relevant selected) | `OverviewPage` |

Notes:
- **Overlays**: `SettingsPage` (**Edges | Baking | Interface**) and `HelpPage` (**Guide | Keys | About**) both use `Rows.overlay` and remember their last tab per session. `HelpPage`'s **About** tab shows plugin version, license, click-to-select source link, and author.
- **Tool pages**: open with `Rows.title` (tool name + icon-only Stop button). In `MeshPage`'s **Simplify** mode, staged **Result** and **Apply / Clear** appear below **Auto-simplify** so **Select flat** never shifts under the cursor.
- **`TilesPage`**: flows top-to-bottom as Properties, 2x3 **Actions** grid (**Add nearby**, **Edit points**, **Round folds**, **Split 2x2**, **Sew tiles**, **Stitch parts**), collapsed **Noise**, collapsed **Reset (N)** (fixed 2x2 grid: **Reset shape**, **Clear paint**, **Fill holes**, **Unsimplify**), divider, and **Bake / Unbake**.

### Reactive hooks and helpers

- `src/UI/useSettings.luau`: subscribes components to `State/Settings`.
- `src/UI/useRefresh.luau`: refreshes panel queries on selection, undo/redo, non-progress status updates, `Session.onChanged`, and workspace/tag tile changes.
- `src/UI/Icons.luau`: theme-tinted Lucide sprites (`16x16` in tool strip and status bar; `14x14` in page buttons, collapsible headers, and dropdown items).

## Color system

Source: `src/UI/Accent.luau`

The panel uses Studio's neutral theme and reserves color for three roles:

- **Tool identity**: each brush shares one hue across its tool strip button, Help icon, and 3D cursor.
- **Primary actions**: Studio's `MainButton` blue (`Rows.button` with `primary = true`), at most once per page (**Create**, **Apply**, **Bake**, **Bake all**, **Done**).
- **Feedback**: green for success, `WarningText` for warnings, `ErrorText` for errors.

| Tool | Accent |
| --- | --- |
| **Raise** | Green |
| **Lower** | Red |
| **Smooth** | Blue |
| **Raise To** | Amber |
| **Material** | Teal |
| **Mesh** | Orange |
| **Pick faces**, **Stitch** | Neutral (Studio blue when active) |

Light themes automatically switch to darker variants based on `MainBackground` luminance so custom themes stay legible.

## Shared row helpers

Source: `src/UI/Rows.luau`

Layout constants: `LABEL_WIDTH = 66`, `ROW_HEIGHT = 22`, `BUTTON_HEIGHT = 24`, `GAP = 4`.

| Helper | Purpose |
| --- | --- |
| `Rows.page` | `ScrollFrame` oversized by 1 px per side so the panel clips its border cleanly |
| `Rows.section`, `Rows.divider` | Dimmed bold section headings and 1 px themed dividers |
| `Rows.title`, `Rows.header` | Tool header (name + Stop) and overlay header (Back + title) |
| `Rows.overlay` | Pinned overlay header, equal-width tab strip, divider, and tab-keyed scroll body |
| `Rows.property`, `Rows.value` | Two-column rows (66 px label + control/text) with full-row tooltips |
| `Rows.grid` | Equal-width `UIGridLayout` rows (2 columns fit cleanly at minimum width) |
| `Rows.button`, `Rows.checkbox` | Full-width controls with optional 14 px icon (`button`) and hover tooltips |
| `Rows.paragraph` | Wrapping themed `TextLabel` with `AutomaticSize.Y` |
| `Rows.collapsible` | Chevron-headed section (optional icon/tint) with session-persisted open state |

## Tooltips and markup

Source: `src/UI/Tooltip.luau`, `src/UI/Markup.luau`

`Tooltip` wraps one child in a transparent frame. After hovering `0.4` s, it converts the tooltip string via `Markup.toRichText`, measures bounds via `TextService:GetTextBoundsAsync` (max `240` px), clamps inside the `PluginGui`, and portals at `ZIndex = 1000`. Clicking hides the tooltip until re-entry.

| Syntax | RichText output |
| --- | --- |
| `**bold**` | `<b>bold</b>` |
| `` `Ctrl + Z` `` | `<b>Ctrl + Z</b>` (keys and UI labels) |
| `*italic*` | `<i>italic</i>` |
| `- item` | Bullet line (`\u{2022} item`) |
| `> note` | Dimmed line (`<font transparency="0.35">note</font>`) |
| Blank line | 6 px vertical spacer |

## Custom controls

### Dropdown

Source: `src/UI/Dropdown.luau` (adapted from `StudioComponents`, MIT licensed)

- **Type-ahead search**: typing jumps to the first matching prefix (`1` s query window); repeating a letter cycles matches.
- **Keyboard navigation**: <kbd>Up</kbd>/<kbd>Down</kbd> step, <kbd>Home</kbd>/<kbd>End</kbd> jump, <kbd>Space</kbd> or <kbd>F4</kbd> opens, <kbd>Enter</kbd> commits, <kbd>Esc</kbd> closes.
- **Closed-list debounce**: stepping while closed previews immediately and commits after `0.35` s so rapid keypresses stay one undo step.
- **PluginGui workaround**: because `UserInputService` ignores input inside plugin widgets, a focused dropdown mounts a transparent non-`Active` overlay frame to capture keys and outside clicks.

### Color editing

Source: `src/UI/ColorField.luau`, `src/UI/ColorPicker.luau`

- **`ColorField`**: combines a `22x22` swatch, hex/`"R, G, B"` text input, and optional pipette button in one row. On `MaterialPage`, a **Paint / Erase** toggle sits at the top and a **Recent** strip below **Color** holds up to 6 recent looks.
- **`ColorPicker`**: opens inline from the swatch with **RGB**, **HSV**, **Hex** (140 px SV square + 12 px hue bar), and **Brick** (Studio's 13-row 127-color BrickColor hexagon + 12 grays). Drags preview live via a full-widget overlay and commit once on release.
