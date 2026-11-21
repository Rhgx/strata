--!strict
--[[
	Conversion between studs and Hammer units, for the places where Hammer's behavior depends
	on absolute sizes (sewing tolerance, the start corner rule, the noise lattice).

	HAMMER_UNITS_PER_STUD is the one shared scale. 16 units per stud makes a Source player
	(72 units tall) 4.5 studs, close to a Roblox character. Change it here only; every
	tolerance and the noise pattern follow it.

	Hammer is Z-up and Roblox is Y-up. Both are right-handed, so Hammer (x, y, z) maps to
	Roblox (x, -z, y) scaled by the constant above.
]]

local Units = {}

Units.HAMMER_UNITS_PER_STUD = 16

-- A Roblox world point in Hammer units and axes.
function Units.toHammer(point: Vector3): Vector3
	local scale = Units.HAMMER_UNITS_PER_STUD
	return Vector3.new(point.X * scale, -point.Z * scale, point.Y * scale)
end

-- A length in Hammer units, in studs.
function Units.studs(hammerUnits: number): number
	return hammerUnits / Units.HAMMER_UNITS_PER_STUD
end

return Units
