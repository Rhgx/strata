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

local function count(changes: Sew.Changes): number
	local n = 0

	for _, vertices in changes do
		for _ in vertices do
			n += 1
		end
	end

	return n
end

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

	it("changes nothing when the seams are already closed", function ()
		local a = Tiles.flat(arena, Vector3.zero, 16, 2)
		local b = Tiles.flat(arena, Vector3.new(16, 0, 0), 16, 2)
		Tiles.move(a, Tiles.vertexAt(a, Vector3.new(16, 0, 8)) :: number, Vector3.new(16, 2, 8))
		Sew.sew({ a, b })

		local again = Sew.sew({ a, b })

		expect(count(again)).toBe(0)
	end)

	it("puts a denser tile's 2:1 in-between point back on the coarser tile's edge", function ()
		local coarse = Tiles.flat(arena, Vector3.zero, 16, 2)
		local dense = Tiles.flat(arena, Vector3.new(16, 0, 0), 16, 3)
		local middle = Tiles.vertexAt(dense, Vector3.new(16, 0, 6)) :: number
		Tiles.move(dense, middle, Vector3.new(16, 3, 6))

		Sew.sew({ coarse, dense })

		-- The coarse edge is flat between (16, 0, 4) and (16, 0, 8), so the point lands at height 0.
		expect(math.abs(Tiles.world(dense, middle).Y)).toBeLessThan(1e-3)
	end)
end)
