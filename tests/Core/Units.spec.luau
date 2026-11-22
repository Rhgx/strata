--!strict

local Root = script.Parent.Parent.Parent

local JestGlobals = require(Root.DevPackages.JestGlobals)
local Units = require(Root.Plugin.Core.Units)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

describe("Units", function ()
	it("converts Hammer units to studs at 16 per stud", function ()
		expect(Units.studs(16)).toBe(1)
	end)
end)
