--!strict
--[[
	What a triangle brush (the Material tool, the Mesh tool's Cut holes) covers on each tile, and
	writing a look index into it.

	Covered: the shown triangle under the cursor, plus every shown triangle whose center is inside
	the brush at any sample along the drag. Looks are stored per grid triangle, so a covered shown
	triangle writes every grid triangle it stands for (on a simplified tile, a big triangle writes
	all the grid triangles under it). Without Fine, both grid triangles of each touched grid cell
	are written, so edges come out as clean steps instead of a sawtooth.
]]

local Displacement = require(script.Parent.Parent.Core.Displacement)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Session = require(script.Parent.Parent.Scene.Session)
local TileHit = require(script.Parent.TileHit)

type Opened = TerrainInstance.Opened

-- Tiles facing away from the hit surface by more than this are skipped (see BrushTool).
local BACK_FACE_DOT = -0.25
-- Samples along a frame's path: about half a radius apart, at most this many.
local STEP_SHARE = 0.5
local MIN_STEP = 0.5
local MAX_STEPS = 16

local TriangleBrush = {}

-- Brush centers along the drag from `previous` to `position`, and how far it moved.
function TriangleBrush.samples(previous: Vector3?, position: Vector3, radius: number): ({ Vector3 }, number)
	if not previous then
		return { position }, 0
	end
	local distance = (position - previous).Magnitude
	local steps = math.clamp(math.ceil(distance / math.max(radius * STEP_SHARE, MIN_STEP)), 1, MAX_STEPS)
	local samples = table.create(steps)
	for k = 1, steps do
		samples[k] = previous:Lerp(position, k / steps)
	end
	return samples, distance
end

-- The tiles of `models` the brush can reach this frame.
function TriangleBrush.tilesInReach(models: { Model }, hit: TileHit.Hit, radius: number, travel: number): { Opened }
	local hitFace = hit.opened.model:GetPivot():VectorToWorldSpace(Displacement.faceNormal(hit.opened.disp))
	local result = {}
	for _, opened in Session.getAll(models) do
		if opened ~= hit.opened then
			local pivot = opened.model:GetPivot()
			local faceNormal = pivot:VectorToWorldSpace(Displacement.faceNormal(opened.disp))
			local nearest = pivot:PointToObjectSpace(hit.position)
			local gap = (nearest - nearest:Max(opened.boundsMin):Min(opened.boundsMax)).Magnitude
			if faceNormal:Dot(hitFace) < BACK_FACE_DOT or gap > radius + travel then
				continue
			end
		end
		table.insert(result, opened)
	end
	return result
end

-- The grid triangles of `opened` under the brush. `centers` are the shown triangle centers.
function TriangleBrush.gridTriangles(
	opened: Opened,
	hit: TileHit.Hit,
	samples: { Vector3 },
	radius: number,
	fine: boolean,
	centers: { Vector3 }
): { number }
	local disp = opened.disp
	local chosen: { [number]: true } = {}
	local result: { number } = {}
	local function choose(g: number)
		if not chosen[g] then
			chosen[g] = true
			table.insert(result, g)
		end
	end
	for t = 1, Displacement.triangleCount(disp) do
		local inside = opened == hit.opened and t == hit.triangle
		if not inside then
			local center = centers[t]
			for _, sample in samples do
				if (center - sample).Magnitude <= radius then
					inside = true
					break
				end
			end
		end
		if inside then
			for _, g in Displacement.coverOf(disp, t) do
				choose(g)
				if not fine then
					-- The other grid triangle of the same cell.
					choose(if g % 2 == 1 then g + 1 else g - 1)
				end
			end
		end
	end
	return result
end

--[[
	Writes look index `target` into the grid triangles `grids` that `eligible` allows, and shows
	the change on the wedges. Returns the shown triangles that changed.
]]
function TriangleBrush.write(opened: Opened, grids: { number }, target: number, eligible: (number) -> boolean): { number }
	local disp = opened.disp
	local shown: { [number]: true } = {}
	local changed: { number } = {}
	for _, g in grids do
		if disp.triLooks[g] ~= target and eligible(g) then
			disp.triLooks[g] = target
			local t = Displacement.shownOf(disp, g)
			if not shown[t] then
				shown[t] = true
				table.insert(changed, t)
			end
		end
	end
	if #changed > 0 then
		Session.updateLooks(opened, changed)
	end
	return changed
end

return TriangleBrush
