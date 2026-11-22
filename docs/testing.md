# Testing

Running and writing Strata's dev-only Jest-Lua unit test suite in Roblox Studio Edit mode.

## Overview

The suite uses `roblox/jest@3.21.0` and `roblox/jest-globals@3.21.0` to test pure `src/Core` geometry, math, and serialization logic. It never ships in `Strata.rbxm`:

- `wally.toml` lists Jest packages under `[dev-dependencies]` (installed into gitignored `DevPackages/`).
- `default.project.json` packages only `src/` and `Packages/`.
- `test.project.json` builds a separate `StrataTests` folder containing `Plugin`, `Packages`, `DevPackages`, and `Tests`.

```text
tests/
  jest.config.luau      # testMatch = { "**/*.spec" }
  run.luau              # Runs Jest over Tests, prints report, returns (passed, failed)
  Helpers/
    Tiles.luau          # Unparented arena, wedge-free tiles, blocks, vertex helpers
  Core/
    Displacement.spec.luau
    Paint.spec.luau
    PartFaces.spec.luau
    Sew.spec.luau
    Stitch.spec.luau
    Units.spec.luau
```

Specs never parent anything to `workspace` and leave the open place untouched.

## Running the suite

`debug.loadmodule` is available in Roblox Studio without FastFlag changes.

1. Install dependencies once (and after changing `wally.toml`):

   ```powershell
   wally install
   ```

2. Build the test model (`*.rbxm` is gitignored):

   ```powershell
   rojo build test.project.json -o tests.rbxm
   ```

3. Open any place in Studio Edit mode and insert `tests.rbxm` into `ServerStorage` (**Insert from File...**).
4. Run from the Command Bar:

   ```luau
   require(game.ServerStorage.StrataTests.Tests.run)()
   ```

   Jest prints its report in the **Output** window and raises an error if any test fails.

> [!IMPORTANT]
> Luau's `require` caches modules for the Studio session. After editing source or specs, delete `StrataTests`, rebuild `tests.rbxm`, and insert the fresh copy before running again.

## Adding a spec

### Location and structure

Place spec files under `tests/` mirroring `src/` (for example `tests/Core/MyModule.spec.luau`). Start with `--!strict`, include the standard copyright/SPDX header, resolve `Root` relative to `script`, and require `JestGlobals` from `Root.DevPackages.JestGlobals`.

### `Tiles` helper

Source: `tests/Helpers/Tiles.luau`

| Helper | Purpose |
| --- | --- |
| `Tiles.arena()` | Unparented `Folder` (`StrataTestArena`) that never touches `workspace` |
| `Tiles.flat(arena, origin, size, power)` | Flat upward square tile (`skipWedges = true`) |
| `Tiles.block(arena, min, max)` | Anchored block `Part` spanning world corners `min`..`max` |
| `Tiles.world(opened, v)` | Current world position of vertex `v` |
| `Tiles.vertexAt(opened, point)` | Vertex index matching flat world `point` (within `1e-3`) |
| `Tiles.move(opened, v, point)` | Moves vertex `v` to world position `point` |

Create a fresh arena in `beforeEach` and destroy it in `afterEach`:

```luau
--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later

local Root = script.Parent.Parent.Parent

local JestGlobals = require(Root.DevPackages.JestGlobals)
local Sew = require(Root.Plugin.Core.Sew)

local Tiles = require(Root.Tests.Helpers.Tiles)

local afterEach = JestGlobals.afterEach
local beforeEach = JestGlobals.beforeEach
local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local arena: Folder

beforeEach(function ()
	arena = Tiles.arena()
end)

afterEach(function ()
	arena:Destroy()
end)

describe("Sew", function ()
	it("closes an open seam between two tiles", function ()
		local a = Tiles.flat(arena, Vector3.zero, 16, 2)
		local b = Tiles.flat(arena, Vector3.new(16, 0, 0), 16, 2)
		local seam = Vector3.new(16, 0, 8)
		local va, vb = Tiles.vertexAt(a, seam) :: number, Tiles.vertexAt(b, seam) :: number
		Tiles.move(a, va, Vector3.new(16, 2, 8))

		Sew.sew({ a, b })

		expect((Tiles.world(a, va) - Tiles.world(b, vb)).Magnitude).toBeLessThan(1e-3)
	end)
end)
```

### Guidelines

- **Contract-first assertions**: test geometric invariants, round-trip fidelity, and boundary conditions rather than mirroring implementation details. Add a failing regression test for every bug fix.
- **No CSG bakes**: never call `TerrainInstance.bake` or `GeometryService`; CSG yields and belongs to manual Studio verification.
- **No `workspace` or `ChangeHistoryService`**: keep tests isolated from the live place and undo stack.
- **Keep tests synchronous**: avoid `task.wait` or yielding loops.
