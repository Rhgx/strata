# Strata Documentation

Technical reference for the Strata Roblox Studio plugin.

## Pages

- [Architecture](architecture.md): layer order (`Core -> State -> Scene -> Actions -> Viewport -> UI`), module map, Rojo layout, and plugin lifecycle.
- [Data format and instance layout](data-format.md): `DispData` attributes, vertex indexing, model structure, `StrataDisplacement` tag, and model portability.
- [Baking](baking.md): texture projection, flat slab fast path, anchor cube alignment, union-then-subtract CSG, collision fidelity, and smoothing angle.
- [Hammer mapping and deviations](hammer.md): unit scale, coordinate mapping, feature equivalents, and intentional differences from Valve Hammer.
- [Panel UI](ui.md): dock widget structure, context page selection, `Rows` layout helpers, tooltip markup, custom `Dropdown`, and `ColorPicker`.

## Logo and icon assets

Brand assets live in `assets/logo/`:

- `strata-store.png` and `strata-store.svg`: 512 px store icon (used at the top of the repository README).
- `strata-dark.svg` and `strata-light.svg`: 32 px ribbon icons for Studio's dark and light themes, paired with 32 px and 64 px PNG renders (`strata-dark-32.png`, `strata-dark-64.png`, `strata-light-32.png`, `strata-light-64.png`). Their uploaded Roblox image asset IDs are referenced in `src/Viewport/Toolbar.luau`.

Inside the plugin panel, UI icons come from `latte-soft/lucide-icons` (`src/UI/Icons.luau`). Ribbon tool buttons reference Studio's built-in `rbxasset://studio_svg_textures/` assets (`src/Viewport/Toolbar.luau`).
