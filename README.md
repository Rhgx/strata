<h1><picture><source media="(prefers-color-scheme: dark)" srcset="assets/logo/strata-dark.svg"><source media="(prefers-color-scheme: light)" srcset="assets/logo/strata-light.svg"><img src="assets/logo/strata-light.svg" alt="" width="32" height="32" align="absmiddle"></picture> Strata</h1>

Hammer-style displacement terrain for Roblox Studio.

[![Release](https://img.shields.io/github/v/release/Rhgx/strata?include_prereleases&style=flat-square&label=release&labelColor=1b1f23&color=2f81f7)](https://github.com/Rhgx/strata/releases)
[![License](https://img.shields.io/github/license/Rhgx/strata?style=flat-square&labelColor=1b1f23&color=3fb950)](LICENSE)
[![Issues](https://img.shields.io/github/issues/Rhgx/strata?style=flat-square&labelColor=1b1f23&color=d29922)](https://github.com/Rhgx/strata/issues)

Turn block and wedge parts into editable displacement tiles, sculpt and paint them, then bake each tile into unions that publish and reopen like any Roblox model.

## Features

- **Create**: convert selected parts into tiled terrain, or pick single faces in 3D.
- **Sculpt**: Raise, Lower, Smooth, and Raise To brushes that work smoothly across seams.
- **Paint**: per-cell or per-triangle materials; each look bakes into its own union.
- **Stitch and sew**: snap tile edges onto roads, floors, and walls, and weld neighboring seams.
- **Shape**: change grid detail (`5x5`, `9x9`, `17x17`), **Round folds**, add **Noise**, or **Split 2x2**.
- **Mesh**: simplify flat ground and cut holes, both fully reversible.
- **Edit points**: move or delete individual vertices using Studio's Move, Rotate, and Scale tools ([Using Strata](docs/usage.md#edit-points)).
- **Appearance**: change material, color, or variant without unbaking, or sample from any part with the pipette.
- **Bake**: automatic or manual union baking with optional triangle optimization.

## Install

1. Get `Strata.rbxm` from a release, or [build it from source](#build-from-source).
2. Copy it into Studio's plugins folder (**Plugins > Plugins Folder**).
3. Restart Studio and open **Strata** from the **Plugins** tab.

> [!NOTE]
> Keep the filename `Strata.rbxm` when updating. Studio loads every `.rbxm` in the plugins folder, so a renamed file will run alongside the old copy.

## Quick workflow

1. Select block or wedge parts and click **Create**, or use **Pick faces** in the tool strip.
2. Sculpt with the brush tools. Hold <kbd>Ctrl</kbd> to invert and <kbd>Shift</kbd> to smooth.
3. Paint surfaces with **Material**; simplify flat areas or cut holes with **Mesh**.
4. Use **Stitch** to snap edges onto nearby parts and **Sew tiles** to close tile seams.
5. Stop the tool (<kbd>Esc</kbd>). Edited tiles bake automatically and unbake on the next edit.

> [!TIP]
> All eight tools, **Edit points**, and toggling the panel register bindable actions under **File > Advanced > Customize Shortcuts** (search for `Strata`).

## Build from source

Requires [Aftman](https://github.com/LPGhatguy/aftman) (`aftman.toml`: Rojo 7.7.1, Wally 0.3.2).

```powershell
aftman install
wally install
rojo build --plugin Strata.rbxm   # builds straight into Studio's plugins folder
```

Build a release copy into `dist/Strata.rbxm` (verifies `src/Version.luau` and `wally.toml` match):

```powershell
.\scripts\release.ps1
```

To run the dev-only Jest-Lua unit tests in Studio, see [Testing](docs/testing.md).

## Documentation

- [Using Strata](docs/usage.md): tools, shortcuts, sculpt axes, cursors, and settings
- [Architecture](docs/architecture.md): layer order, module map, lifecycle, and Edit points internals
- [Data format](docs/data-format.md): instance layout, `DispData` attributes, looks, holes, and simplification
- [Baking](docs/baking.md): CSG pipeline, texture alignment, and bake optimizations
- [Hammer mapping](docs/hammer.md): units, Valve Hammer equivalents, and deliberate deviations
- [Panel UI](docs/ui.md): overlay shell, color system, shared row helpers, and custom controls
- [Testing](docs/testing.md): running and writing Jest-Lua specs

## License

Copyright (C) 2026 Rocks. Licensed under the GNU General Public License v3.0 or later; see [LICENSE](LICENSE).

Terrain, models, and places you create with Strata are yours, under any license you choose. The GPL covers only Strata's own code.

Bundled packages keep their own licenses: React-Lua, StudioComponents, and `lucide-icons` (MIT), and Lucide icon art (ISC). `src/UI/Dropdown.luau` is adapted from StudioComponents (MIT); its notice is preserved in that file.
