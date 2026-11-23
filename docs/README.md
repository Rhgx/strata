# Strata documentation

User guide and technical reference for the Strata Roblox Studio plugin.

## Using Strata

- [Using Strata](usage.md): workflow, viewport shortcuts, sculpt axes, cursors, Edit points, and settings.

## How it works

- [Architecture](architecture.md): layer order (`Core -> State -> Scene -> Actions -> Viewport -> UI`), module map, lifecycle, and Edit points internals.
- [Data format](data-format.md): tile instance layout, `StrataDisplacement` tag, vertex math, `DispData` attributes, looks, holes, and simplification.
- [Baking](baking.md): CSG union pipeline, flat slab fast path, anchor cube alignment, and bake optimizations.
- [Hammer mapping](hammer.md): unit scale, coordinate conversion, Valve Hammer equivalents, and deliberate deviations.
- [Panel UI](ui.md): dock widget layout, accent colors, `Rows` helpers, tooltip markup, `Dropdown`, and `ColorPicker`.

## Contributing

- [Testing](testing.md): building `tests.rbxm`, running Jest-Lua in Studio, and writing specs.

## Brand and icon assets

Brand icons live in `assets/logo/`:

- `strata-dark.svg` and `strata-light.svg`: theme-matched source icons, used directly by the README.
- `strata-dark-32.png`, `strata-dark-64.png`, `strata-light-32.png`, `strata-light-64.png`: raster exports uploaded as the Plugins ribbon icons (`LOGO` in `src/Viewport/Toolbar.luau`).
- `strata-store.png` and `strata-store.svg`: 512 px store icon.

The 1280x640 GitHub social preview banner lives at `assets/social-preview.png` (`assets/social-preview.svg` source).

Panel UI icons come from `latte-soft/lucide-icons` (`src/UI/Icons.luau`). Optional Plugins ribbon tool buttons use Studio's built-in `rbxasset://studio_svg_textures/` icons.
