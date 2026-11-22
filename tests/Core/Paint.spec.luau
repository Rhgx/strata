--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later

local Root = script.Parent.Parent.Parent

local JestGlobals = require(Root.DevPackages.JestGlobals)
local Paint = require(Root.Plugin.Core.Paint)
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

local function brush(effect: Paint.Effect, radius: number, falloff: Paint.Falloff?): Paint.Brush
	return {
		effect = effect,
		falloff = falloff or "Soft",
		axis = "Face",
		pickedAxis = Vector3.yAxis,
		radius = radius,
		strength = 6,
		height = 0,
		raiseToWorld = false,
	}
end

local function count(changed: { [Tiles.Opened]: { [number]: true } }): number
	local n = 0

	for _, vertices in changed do
		for _ in vertices do
			n += 1
		end
	end

	return n
end

-- A 32-stud Medium tile: points every 4 studs.
local function grid(): Tiles.Opened
	return Tiles.flat(arena, Vector3.zero, 32, 3)
end

describe("Paint", function ()
	it("moves exactly the points the preview shows", function ()
		local tile = grid()
		local center = Vector3.new(13, 0, 14)
		local soft = brush("Raise", 6)

		local preview = Paint.preview({ tile }, center, soft, 64, tile)
		local changed = Paint.apply({ tile }, { center }, soft, 0.5)

		expect(#preview.inside).toBeGreaterThan(1)
		expect(count(changed)).toBe(#preview.inside)
	end)

	it("moves nothing when the ring sits between points, and shows the nearest ones", function ()
		local tile = grid()
		local center = Vector3.new(10, 0, 10)

		local preview = Paint.preview({ tile }, center, brush("Raise", 1), 64, tile)
		local changed = Paint.apply({ tile }, { center }, brush("Raise", 1), 0.5)

		expect(#preview.inside).toBe(0)
		expect(#preview.nearby).toBe(4)
		expect(count(changed)).toBe(0)
	end)

	it("moves a single point a small ring is over, at full weight with Hard falloff", function ()
		local tile = grid()
		local center = Vector3.new(8.4, 0, 8)
		local v = Tiles.vertexAt(tile, Vector3.new(8, 0, 8)) :: number

		local preview = Paint.preview({ tile }, center, brush("Raise", 1, "Hard"), 64, tile)
		local changed = Paint.apply({ tile }, { center }, brush("Raise", 1, "Hard"), 0.5)

		expect(#preview.inside).toBe(1)
		expect(preview.inside[1].weight).toBe(1)
		expect(count(changed)).toBe(1)
		-- Raise at strength 6 for 0.5 s at full weight is 3 studs.
		expect(Tiles.world(tile, v).Y).toBeCloseTo(3, 3)
	end)

	it("reports a ring over a simplified area so the user can be told", function ()
		local tile = grid()

		for v = 1, Displacement.vertexCount(tile.disp) do
			if not Displacement.isCorner(tile.disp, v) then
				Displacement.setRemoved(tile.disp, v, true)
			end
		end

		local changed, simplified = Paint.apply({ tile }, { Vector3.new(16, 0, 16) }, brush("Raise", 1), 0.5)

		expect(count(changed)).toBe(0)
		expect(simplified).toBe(true)
	end)

	it("does not report a ring between kept points as simplified", function ()
		local tile = grid()

		local _, simplified = Paint.apply({ tile }, { Vector3.new(10, 0, 10) }, brush("Raise", 1), 0.5)

		expect(simplified).toBe(false)
	end)

	it("sets points to the Raise To height with Hard falloff", function ()
		local tile = grid()
		local raiseTo = brush("RaiseTo", 1, "Hard")
		raiseTo.height = 3

		Paint.apply({ tile }, { Vector3.new(8, 0, 8) }, raiseTo, 0.1)

		expect(Paint.heightAt(tile, Tiles.world(tile, Tiles.vertexAt(tile, Vector3.new(8, 0, 8)) :: number), raiseTo)).toBeCloseTo(3, 3)
	end)
end)
