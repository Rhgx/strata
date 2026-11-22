--!strict

local Root = script.Parent.Parent.Parent

local JestGlobals = require(Root.DevPackages.JestGlobals)
local PartFaces = require(Root.Plugin.Core.PartFaces)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

describe("PartFaces", function ()
	it("finds 6 faces on a block", function ()
		local part = Instance.new("Part")
		part.Size = Vector3.new(8, 2, 8)

		expect(#PartFaces.faces(part)).toBe(6)
		part:Destroy()
	end)

	it("finds the 3 quad faces of a wedge", function ()
		local wedge = Instance.new("WedgePart")
		wedge.Size = Vector3.new(8, 4, 8)

		expect(#PartFaces.faces(wedge)).toBe(3)
		wedge:Destroy()
	end)

	it("finds no faces on a ball", function ()
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball

		expect(#PartFaces.faces(ball)).toBe(0)
		ball:Destroy()
	end)

	it("selects only the upward face of an upright block in Top mode", function ()
		local part = Instance.new("Part")
		part.Size = Vector3.new(8, 2, 8)

		local faces = PartFaces.select(part, "Top")

		expect(#faces).toBe(1)
		part:Destroy()
	end)
end)
