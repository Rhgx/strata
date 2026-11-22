--!strict
--[[
	Converts between Roblox studs and Hammer units where Hammer algorithms depend on absolute
	scale (sewing tolerance, start corner rule, and noise lattice).

	HAMMER_UNITS_PER_STUD is the single shared scale factor: 16 units per stud maps a 72-unit
	Source player to 4.5 studs, close to a Roblox character. Changing this constant updates every
	tolerance and the noise pattern consistently.

	Hammer is Z-up while Roblox is Y-up (both right-handed), so Hammer (x, y, z) corresponds to
	Roblox (x, -z, y) scaled by HAMMER_UNITS_PER_STUD.
]]

local Units = {}

Units.HAMMER_UNITS_PER_STUD = 16

-- Converts a Roblox world-space position into Hammer units and axes.
function Units.toHammer(point: Vector3): Vector3
	local scale = Units.HAMMER_UNITS_PER_STUD

	return Vector3.new(point.X * scale, -point.Z * scale, point.Y * scale)
end

-- Converts a distance from Hammer units to Roblox studs.
function Units.studs(hammerUnits: number): number
	return hammerUnits / Units.HAMMER_UNITS_PER_STUD
end

return Units
