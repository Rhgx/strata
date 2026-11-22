# Panel UI

Strata's panel (`src/UI/`) is built with React-Lua, `StudioComponents`, and Lucide icons (`latte-soft/lucide-icons`, configured in `src/UI/Icons.luau`). It is styled after Roblox Studio's Properties window and sized to remain usable down to the dock widget's 220 px minimum width (~190 px of inner content width).

## Panel layout (`src/UI/App.luau`)

The panel is divided into three vertical regions:

1. **Tool strip (`src/UI/ToolStrip.luau`)**: a 30 px pinned bar at the top with the eight viewport tools (also on the ribbon when `Tools on Plugins ribbon` is on in Settings) (`Raise`, `Lower`, `Smooth`, `Raise To`, `Material`, `Mesh`, a vertical divider, then `Pick faces` and `Stitch`) as 24x24 icon buttons so tools stay one click away even when Studio is not on the Plugins ribbon tab. Hidden while an overlay (`Settings` or `Help`) is open.
2. **Context page (`src/UI/Pages/`)**: occupies the middle area and switches automatically based on what the user is doing, in this priority order:
   - `SettingsPage` or `HelpPage` when `settings.overlay` is `"settings"` or `"help"`.
   - Active viewport tool: `BrushPage` (`painting`), `MaterialPage` (`coloring`), `CreatePage` in pick mode (`picking`), or `StitchPage` (`stitching`).
   - Studio selection: `TilesPage` when at least one displacement tile is selected (even if normal parts are also selected, since `Sew` uses them), or `CreatePage` when eligible block/wedge parts are selected.
   - Fallback: `OverviewPage` showing place tile and baked counts plus a `Bake all` button (or getting-started guidance if the place has no terrain yet).
   Each page is keyed by its page name so switching contexts always resets scroll position to the top.
3. **Status bar (`src/UI/StatusBar.luau`)**: a 24 px pinned bar at the bottom displaying the latest `State/Status` message (colored as `MainText` for success, `WarningText` for warnings, or `ErrorText` for errors; clickable to dismiss; full text shown in its tooltip) or a context-aware idle hint when no status message is active. The right side holds the Settings gear and Help `?` overlay toggle buttons.

### Reactive hooks and helpers

- `src/UI/useSettings.luau`: subscribes a component to `State/Settings`.
- `src/UI/useRefresh.luau`: triggers a re-render on `Selection.SelectionChanged`, `ChangeHistoryService.OnUndo`/`OnRedo`, and `State/Status` updates so selection info and tile counts stay current.
- `src/UI/Icons.luau`: wraps `Lucide.GetAsset(name, 48)` with theme tinting (`16x16` for the tool strip and status bar; `14x14` for page buttons and dropdown items).
- `src/UI/Format.luau`: comma-grouped counts (`12,345`), natural plurals (`1 tile` / `3 tiles`), and color hex / `"R, G, B"` parsing and formatting.

## Shared row helpers (`src/UI/Rows.luau`)

Pages are composed from layout helpers in `src/UI/Rows.luau` (`LABEL_WIDTH = 66`, `ROW_HEIGHT = 22`, `BUTTON_HEIGHT = 24`, `GAP = 4`):

- `Rows.page(children)`: `StudioComponents.ScrollFrame` oversized by 1 px on each side so the panel clips its outer border cleanly.
- `Rows.section`, `Rows.title`, `Rows.header`, `Rows.divider`: dimmed group headings, bold tool titles, overlay headers with a back button, and 1 px themed dividers.
- `Rows.property`, `Rows.value`: two-column label/control rows (66 px label column, control fills the remainder) wrapped in a whole-row hover tooltip when a tooltip is provided.
- `Rows.grid`: equal-width `UIGridLayout` rows (kept to at most 2 columns for icon buttons at minimum panel width).
- `Rows.button`, `Rows.checkbox`, `Rows.withTooltip`: full-width controls with hover tooltips.
- `Rows.paragraph`, `Rows.heading`: wrapping themed `TextLabel`s using `AutomaticSize.Y` (since `StudioComponents.Label` does not auto-size).
- `Rows.collapsible`: chevron-headed collapsible section whose open/closed state persists per section ID for the duration of the Studio session.

## Tooltips and markup (`src/UI/Tooltip.luau`, `src/UI/Markup.luau`)

`Tooltip` wraps a single child element in a transparent frame. After hovering for `0.4` s, it converts the tooltip string through `Markup.toRichText`, measures the wrapped text with `TextService:GetTextBoundsAsync` (capped at `240` px or the window width), clamps the box inside the `PluginGui`, and renders it through `ReactRoblox.createPortal` directly into the `PluginGui` at `ZIndex = 1000` so scroll frames never clip it. Clicking inside the wrapped control hides the tooltip until the mouse leaves and re-enters.

`Markup.toRichText` (`src/UI/Markup.luau`) escapes `&`, `<`, and `>` and turns a small Markdown-like syntax into Roblox RichText:

| Syntax | RichText output |
| --- | --- |
| `**bold**` | `<b>bold</b>` |
| `` `Ctrl + Z` `` | `<b>Ctrl + Z</b>` (keys and UI labels) |
| `*italic*` | `<i>italic</i>` |
| `- item` | Bullet line (`\u{2022} item`) |
| `> note` | Dimmed line (`<font transparency="0.35">note</font>`) |
| Blank line | 6 px vertical spacer (`<font size="6"> </font>`) |

## Custom `Dropdown` (`src/UI/Dropdown.luau`)

`Dropdown` is adapted from `StudioComponents`' `Dropdown` (MIT licensed, Copyright (c) 2025 sircfenner; full MIT license notice is preserved in `src/UI/Dropdown.luau`) and adds Roblox Studio / Qt combo box keyboard behavior:

- **Type-ahead search**: clicking and typing jumps to the first item matching the typed prefix (keystrokes within `1` s form one search); repeating the same letter cycles through items starting with it.
- **Navigation**: `Up` and `Down` move one item; `Home` and `End` jump to the ends; `Space` or `F4` opens the list; `Enter` or `Space` commits the highlighted item; `Esc` closes the list.
- **Closed-list debounce**: stepping through options while the list is closed previews immediately and commits `0.35` s after the last key, so several keystrokes produce a single undo step.
- **Plugin widget input**: because `UserInputService` does not see input inside `PluginGui` widgets, a focused dropdown mounts a transparent, non-`Active` frame over the widget to read keyboard input and detect outside clicks without blocking clicks to controls underneath.

## Color editing (`src/UI/ColorField.luau`, `src/UI/ColorPicker.luau`)

`ColorField` packs a `22x22` swatch button, a text input, and an optional pipette button (`SampleTool`) onto one property row. The text input accepts `#RRGGBB`, `RRGGBB`, `#RGB`, or `"R, G, B"` (the format copied from Studio's Properties window).

Clicking the swatch opens `ColorPicker` inline below the row, laid out like Studio's Properties color picker with four modes (`RGB`, `HSV`, `Hex`, and `Brick`):

- **RGB, HSV, and Hex**: mode-specific text inputs alongside a 140 px saturation/brightness square and a 12 px hue bar.
- **Brick**: Studio's `BrickColor` palette rendered as a 13-row hexagon of 127 colors above a row of 12 grays, matching Studio's colors, ordering, and grid geometry.

Drags track pointer movement through a transparent full-widget overlay button (the same `PluginGui` input workaround used by `Dropdown`), calling `onPreview` during the drag and `onCommit` once on release so each drag is one undo step. Text inputs commit on focus loss and palette clicks commit immediately.

## Viewport cursors

Each tool's cursor shows what it acts on. The sculpt brushes show one ring (a faint always-on-top copy on the same circle keeps it readable in valleys). The Material tool and the Mesh tool's `Cut holes` mode outline exactly the triangles a click would change. The Mesh tool's `Simplify` mode has no ring: the points a click would remove (or restore) are highlighted over a wireframe of the hovered tile, including the nearest point a click always takes. Stitch and Pick faces highlight parts and faces.

Changing `Radius` in the panel previews the brush in the middle of the 3D view for about a second, with a `Radius 8 st` label (`src/Viewport/RadiusPreview.luau`).
