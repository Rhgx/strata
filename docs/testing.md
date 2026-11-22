# Testing

Strata's unit test suite uses Jest-Lua (`roblox/jest@3.21.0` and `roblox/jest-globals@3.21.0`) to test pure `src/Core` geometry, math, and serialization logic inside Roblox Studio Edit mode.

## Overview and layout

The suite is strictly dev-only and never ships in `Strata.rbxm`:

- `wally.toml` lists `Jest` and `JestGlobals` under `[dev-dependencies]`, which Wally installs into `DevPackages/` (gitignored).
- `default.project.json` includes only `Plugin` (`src/`) and `Packages` (`Packages/`), so `tests/` and `DevPackages/` are excluded from plugin builds.
- `test.project.json` builds a separate `Folder` named `StrataTests` containing `Plugin` (`src/`), `Packages` (`Packages/`), `DevPackages` (`DevPackages/`), and `Tests` (`tests/`).

```text
tests/
  jest.config.luau      # Jest configuration (testMatch = { "**/*.spec" })
  run.luau              # Entry point: runs Jest over Tests, prints report, returns (passed, failed)
  Helpers/
    Tiles.luau          # Unparented arena Folder, wedge-free tiles, blocks, and vertex helpers
  Core/
    Displacement.spec.luau
    Paint.spec.luau
    PartFaces.spec.luau
    Sew.spec.luau
    Stitch.spec.luau
    Units.spec.luau
```

`tests/run.luau` invokes `Jest.runCLI` over `Root.Tests` with `{ verbose = true, ci = false }`, prints Jest's report in Output, returns `(passed, failed)`, and raises an error if Jest fails to finish or any test or suite fails.

Tests never parent anything to `workspace` and leave the open place untouched.

## Running the suite

`debug.loadmodule` is available in Roblox Studio, so no FastFlag changes are needed.

1. Install dependencies once (and again after changing `wally.toml`):

   ```powershell
   wally install
   ```

2. Build the test model (any output path works; `*.rbxm` is gitignored):

   ```powershell
   rojo build test.project.json -o tests.rbxm
   ```

3. Open any place in Roblox Studio in Edit mode and insert `tests.rbxm` (for example, right-click `ServerStorage` and select **Insert from File...**).
4. Run the suite from the Command Bar:

   ```luau
   require(game.ServerStorage.StrataTests.Tests.run)()
   ```

   Jest's report prints in the **Output** window.

5. Before running again after editing source or spec files, delete the inserted `StrataTests` folder, rebuild `tests.rbxm`, and insert the fresh copy. Luau's `require` caches modules for the Studio session, so re-running against an already-required copy executes the old code.

## Adding a spec

### Location and naming

Place spec files under `tests/` mirroring `src/` (for example, `tests/Core/MyModule.spec.luau`). `tests/jest.config.luau` matches `**/*.spec`, and Rojo strips the `.luau` extension when building `StrataTests`.

Start each file with `--!strict`, resolve `Root` relative to `script`, require `JestGlobals` from `Root.DevPackages.JestGlobals`, and require the module under test from `Root.Plugin`.

### Using the `Tiles` helper and arena cleanup

`tests/Helpers/Tiles.luau` provides throwaway geometry helpers for specs that need tiles or parts:

| Helper | Behavior |
| --- | --- |
| `Tiles.arena()` | Creates a `Folder` named `StrataTestArena` with `Parent = nil` so specs never touch `workspace`. |
| `Tiles.flat(arena, origin, size, power)` | Creates a flat square tile `size` studs wide on the XZ plane facing up, with its first corner at `origin` and `skipWedges = true` (no `WedgePart`s are created; `Core` reads only `disp`, the pivot, and bounds). |
| `Tiles.block(arena, min, max)` | Creates an anchored block `Part` spanning world corners `min` and `max` inside `arena`. |
| `Tiles.world(opened, v)` | Returns the current world position of vertex `v`. |
| `Tiles.vertexAt(opened, point)` | Returns the vertex index whose undisplaced world position matches `point` (within `1e-3`), or `nil`. |
| `Tiles.move(opened, v, point)` | Moves vertex `v` to world position `point`. |

Create a fresh arena in `beforeEach` and destroy it in `afterEach` so instances never leak between tests:

```luau
--!strict

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

### Contract-first assertions

Write assertions from the module's intended contract, not by copying whatever the current implementation happens to return. Check geometric invariants, round-trip fidelity, edge cases, and boundary conditions (such as seams closing within tolerance, corners never being removed, or out-of-reach parts producing zero matches). When fixing a bug, add a regression test that fails against the broken code and passes with the fix.

## What not to do in unit tests

- **No CSG bakes.** Do not call `TerrainInstance.bake` or `GeometryService` (`UnionAsync`, `SubtractAsync`). CSG is slow, yields, and belongs to manual verification in Studio.
- **No `workspace`.** Never parent test tiles, parts, or folders to `workspace`. `Scene/Session` scans `workspace`, parenting triggers Studio rendering work, and tests must leave the open place untouched.
- **No `ChangeHistoryService`.** Do not open recordings, set waypoints, or mutate the place's undo stack in unit tests.
- **Keep tests synchronous.** Avoid `task.wait`, yielding loops, or event-timing dependencies; unit tests should run straight through without yielding.
