--!strict
--[[
	The cursor of the triangle tools (Material, Mesh Cut holes): the outline of exactly the shown
	triangles a click would change, drawn as their outer edges only. A round ring would not match
	the stepped footprint of whole triangles and cells.
]]

local Displacement = require(script.Parent.Parent.Core.Displacement)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Lines = require(script.Parent.Lines)

type Opened = TerrainInstance.Opened

export type Covered = { opened: Opened, grids: { number } }

local THICKNESS = 0.09
local TRANSPARENCY = 0.1

local TriangleOutline = {}

-- Draws the outline of the shown triangles standing for `covered` grid triangles, per tile.
function TriangleOutline.draw(pool: Lines.Pool, covered: { Covered }, color: Color3)
	pool.clear()
	for _, entry in covered do
		local opened = entry.opened
		local disp = opened.disp
		local shown: { [number]: true } = {}
		for _, g in entry.grids do
			shown[Displacement.shownOf(disp, g)] = true
		end
		-- Edges used by one covered triangle are on the outline; shared ones are inside it.
		local count = Displacement.vertexCount(disp)
		local uses: { [number]: number } = {}
		local ends: { [number]: { number } } = {}
		for t in shown do
			local i1, i2, i3 = Displacement.triangle(disp, t)
			for _, pair in { { i1, i2 }, { i2, i3 }, { i3, i1 } } do
				local lo, hi = math.min(pair[1], pair[2]), math.max(pair[1], pair[2])
				local key = lo * (count + 1) + hi
				uses[key] = (uses[key] or 0) + 1
				ends[key] = { lo, hi }
			end
		end
		local pivot = opened.model:GetPivot()
		local normal = Displacement.faceNormal(disp)
		-- Lifted a hair off the surface so the outline is not buried in it.
		local lift = pivot:VectorToWorldSpace(normal) * 0.03
		for key, used in uses do
			if used == 1 then
				local pair = ends[key]
				pool.line(
					pivot * Displacement.position(disp, pair[1], normal) + lift,
					pivot * Displacement.position(disp, pair[2], normal) + lift,
					color,
					THICKNESS,
					TRANSPARENCY
				)
			end
		end
	end
end

return TriangleOutline
