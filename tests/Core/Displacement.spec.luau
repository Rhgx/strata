--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later

local Root = script.Parent.Parent.Parent

local JestGlobals = require(Root.DevPackages.JestGlobals)
local Displacement = require(Root.Plugin.Core.Displacement)

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

describe("Displacement", function ()
	it("reads back a position it was set to", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 2)
		local target = Vector3.new(4, 3.5, 8)

		Tiles.move(tile, 7, target)

		expect((Tiles.world(tile, 7) - target).Magnitude).toBeLessThan(1e-4)
	end)

	it("never removes a corner point", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 2)

		for corner = 1, 4 do
			local v = Displacement.cornerVertex(tile.disp, corner)

			expect(Displacement.setRemoved(tile.disp, v, true)).toBe(false)
			expect(tile.disp.removed[v]).toBeNil()
		end
	end)

	it("saves and loads sculpted points, holes, and removed points unchanged", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 3)
		Tiles.move(tile, 20, Vector3.new(6, 2.25, 4))
		tile.disp.triLooks[5] = Displacement.HOLE
		Displacement.setRemoved(tile.disp, 41, true)

		local config = Instance.new("Configuration")
		Displacement.save(tile.disp, config)
		local loaded = Displacement.load(config)

		for v = 1, Displacement.vertexCount(tile.disp) do
			expect((Displacement.position(loaded, v) - Displacement.position(tile.disp, v)).Magnitude).toBeLessThan(1e-3)
		end

		expect(loaded.triLooks[5]).toBe(Displacement.HOLE)
		expect(loaded.removed[41]).toBe(true)
	end)

	it("splits into four quarters that keep every point exactly where it was", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 3)
		Tiles.move(tile, 32, Vector3.new(6, 3, 8))
		Tiles.move(tile, 50, Vector3.new(10, -1.5, 10))

		local quarters = Displacement.split(tile.disp)
		expect(#quarters).toBe(4)

		local pivot = tile.model:GetPivot()

		for _, quarter in quarters do
			local quarterPivot = pivot * CFrame.new(quarter.center)

			for v = 1, Displacement.vertexCount(quarter.disp) do
				local flat = quarterPivot * Displacement.flatPosition(quarter.disp, v)
				local parentV = Tiles.vertexAt(tile, flat)
				expect(parentV).never.toBeNil()

				local position = quarterPivot * Displacement.position(quarter.disp, v)
				expect((position - Tiles.world(tile, parentV :: number)).Magnitude).toBeLessThan(1e-4)
			end
		end
	end)

	it("refuses to split a Low detail tile", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 2)

		expect(function ()
			Displacement.split(tile.disp)
		end).toThrow()
	end)

	it("keeps existing points in place when raising detail", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 2)
		Tiles.move(tile, 7, Vector3.new(4, 2, 8))

		local raised = Displacement.changePower(tile.disp, 3)
		local pivot = tile.model:GetPivot()

		for v = 1, Displacement.vertexCount(tile.disp) do
			local flat = pivot * Displacement.flatPosition(tile.disp, v)

			for w = 1, Displacement.vertexCount(raised) do
				if (pivot * Displacement.flatPosition(raised, w) - flat).Magnitude < 1e-3 then
					local before = Tiles.world(tile, v)
					local after = pivot * Displacement.position(raised, w)
					expect((after - before).Magnitude).toBeLessThan(1e-3)
				end
			end
		end
	end)

	it("resets sculpted shape back to flat while keeping holes and removed points", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 3)
		Tiles.move(tile, 20, Vector3.new(6, 3.5, 4))
		tile.disp.offsets[25] = Vector3.new(0, 1.5, 0)
		tile.disp.elevation = 2
		tile.disp.subdiv = true
		tile.disp.triLooks[5] = Displacement.HOLE
		Displacement.setRemoved(tile.disp, 41, true)

		expect(Displacement.resetShape(tile.disp)).toBe(true)
		expect(tile.disp.elevation).toBe(0)
		expect(tile.disp.subdiv).toBe(false)
		expect(tile.disp.triLooks[5]).toBe(Displacement.HOLE)
		expect(tile.disp.removed[41]).toBe(true)

		for v = 1, Displacement.vertexCount(tile.disp) do
			expect((Displacement.position(tile.disp, v) - Displacement.flatPosition(tile.disp, v)).Magnitude).toBeLessThan(1e-4)
		end

		-- Resetting an already-flat tile is a no-op.
		expect(Displacement.resetShape(tile.disp)).toBe(false)
	end)
end)
