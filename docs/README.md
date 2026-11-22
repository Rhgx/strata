# Strata Documentation

Technical reference for the Strata Roblox Studio plugin.

## Pages

| Page | Summary |
| --- | --- |
| [Architecture](architecture.md) | Layer order (`Core -> State -> Scene -> Actions -> Viewport -> UI`), module map, Rojo project layout, and plugin lifecycle. |
| [Data format](data-format.md) | Instance layout, `StrataDisplacement` tag, vertex math, `DispData` attributes, painted looks, holes, and removed points. |
| [Baking](baking.md) | Why tiles bake, CSG pipeline, flat slab fast path, anchor cube alignment, bake optimizations, and smoothing angle. |
| [Hammer mapping](hammer.md) | Unit scale, coordinate conversion, Hammer feature mapping, Strata additions, and deliberate deviations. |
| [Panel UI](ui.md) | Dock widget layout, viewport shortcuts, accent colors, `Rows` helpers, tooltip markup, `Dropdown`, and `ColorPicker`. |
| [Testing](testing.md) | Jest-Lua unit test suite, building and running `tests.rbxm` in Studio, writing specs, and test boundaries. |

## Logo and icon assets

Brand assets live in `assets/logo/`:

- `strata-dark.svg` and `strata-light.svg`: 32 px icons for dark and light themes, used in the repository README and (via their 32 px and 64 px PNG renders uploaded to Roblox) on Studio's Plugins ribbon (`src/Viewport/Toolbar.luau`).
- `strata-store.png` and `strata-store.svg`: 512 px store icon.

Inside the panel, UI icons come from `latte-soft/lucide-icons` (`src/UI/Icons.luau`). Optional ribbon tool buttons use Studio's built-in `rbxasset://studio_svg_textures/` assets (`src/Viewport/Toolbar.luau`).
