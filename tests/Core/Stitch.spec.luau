--!strict

local Root = script.Parent.Parent.Parent

local JestGlobals = require(Root.DevPackages.JestGlobals)
local Stitch = require(Root.Plugin.Core.Stitch)

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

local REACH = 2

describe("Stitch.match", function ()
	it("moves a tile corner to where two walls of an inside corner cross", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 2)
		-- Wall along X with its inner face at z = 16.4; wall along Z with its inner face at x = 16.5.
		local wallX = Tiles.block(arena, Vector3.new(-10, 0, 16.4), Vector3.new(20, 10, 18.4))
		local wallZ = Tiles.block(arena, Vector3.new(16.5, 0, -10), Vector3.new(18.5, 10, 20))
		local corner = Tiles.vertexAt(tile, Vector3.new(16, 0, 16)) :: number

		local moves = Stitch.match({ tile }, { wallX, wallZ }, REACH, true).moves[tile]

		local target = moves[corner]
		expect(target).never.toBeNil()
		expect(math.abs(target.X - 16.5)).toBeLessThan(1e-3)
		expect(math.abs(target.Z - 16.4)).toBeLessThan(1e-3)
	end)

	it("still matches a long wall that another wall butts into at its middle", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 2)
		-- Long wall centered on x = 8 with a short wall touching its inner face at that same middle.
		local long = Tiles.block(arena, Vector3.new(-12, 0, 16.4), Vector3.new(28, 10, 18.4))
		local stub = Tiles.block(arena, Vector3.new(7, 0, 10), Vector3.new(9, 10, 16.4))

		local moves = Stitch.match({ tile }, { long, stub }, REACH, true).moves[tile]

		for _, x in { 0, 16 } do
			local v = Tiles.vertexAt(tile, Vector3.new(x, 0, 16)) :: number
			local target = moves and moves[v]
			expect(target).never.toBeNil()
			expect(math.abs((target :: Vector3).Z - 16.4)).toBeLessThan(1e-3)
		end
	end)

	it("matches nothing when no part is within reach", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 2)
		local far = Tiles.block(arena, Vector3.new(0, 0, 30), Vector3.new(16, 10, 32))

		local result = Stitch.match({ tile }, { far }, REACH, true)

		expect(#result.matches).toBe(0)
	end)

	it("groups flush corner walls with Stitch.sheet along the floor normal and closes the corner", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 2)
		-- Two equal-height walls meeting flush at an inside corner (shared horizontal cap edge at z = 16.4).
		local wallX = Tiles.block(arena, Vector3.new(-10, 0, 16.4), Vector3.new(18.5, 10, 18.4))
		local wallZ = Tiles.block(arena, Vector3.new(16.5, 0, -10), Vector3.new(18.5, 10, 16.4))
		local corner = Tiles.vertexAt(tile, Vector3.new(16, 0, 16)) :: number

		local floorSheet = Stitch.sheet(wallZ, { wallX, wallZ }, Vector3.yAxis)
		expect(#floorSheet).toBe(2)

		local moves = Stitch.match({ tile }, floorSheet, REACH, true).moves[tile]
		local target = moves and moves[corner]
		expect(target).never.toBeNil()
		expect(math.abs((target :: Vector3).X - 16.5)).toBeLessThan(1e-3)
		expect(math.abs((target :: Vector3).Z - 16.4)).toBeLessThan(1e-3)
	end)
end)

describe("Stitch.propagate", function ()
	it("sends a moved point's twin on a denser neighbor to the same place and interpolates its 2:1 points", function ()
		local coarse = Tiles.flat(arena, Vector3.zero, 16, 2)
		local dense = Tiles.flat(arena, Vector3.new(16, 0, 0), 16, 3)
		local moved = Tiles.vertexAt(coarse, Vector3.new(16, 0, 8)) :: number

		local result = Stitch.propagate({ [coarse] = { [moved] = Vector3.new(16, 2, 8) } }, { coarse, dense })

		local twin = Tiles.vertexAt(dense, Vector3.new(16, 0, 8)) :: number
		local below = Tiles.vertexAt(dense, Vector3.new(16, 0, 6)) :: number
		local above = Tiles.vertexAt(dense, Vector3.new(16, 0, 10)) :: number
		expect(result[dense][twin].Y).toBeCloseTo(2, 3)
		expect(result[dense][below].Y).toBeCloseTo(1, 3)
		expect(result[dense][above].Y).toBeCloseTo(1, 3)
	end)

	it("leaves a point on a tile's open border alone between two moved points", function ()
		local tile = Tiles.flat(arena, Vector3.zero, 16, 3)
		local first = Tiles.vertexAt(tile, Vector3.new(0, 0, 2)) :: number
		local between = Tiles.vertexAt(tile, Vector3.new(0, 0, 4)) :: number
		local last = Tiles.vertexAt(tile, Vector3.new(0, 0, 6)) :: number

		local result = Stitch.propagate({
			[tile] = { [first] = Vector3.new(0, 1, 2), [last] = Vector3.new(0, 3, 6) },
		}, { tile })

		expect(result[tile][between]).toBeNil()
	end)
end)
