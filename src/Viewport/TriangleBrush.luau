--!strict
--[[
	Shared coverage and write logic for triangle-based brushes (Material tool and Mesh Cut holes).

	Coverage includes the shown triangle directly under the pointer plus every shown triangle
	whose centroid falls within the brush radius at any path sample. Because looks and holes live
	on grid triangles, each covered shown triangle expands to all grid triangles it covers (a
	large simplified triangle affects its full footprint). When `fine` is false, both triangles
	of each touched grid cell are selected so painted edges form clean steps rather than sawteeth.
]]

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Core = Plugin.Core

local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Session = require(Plugin.Scene.Session)

local TileHit = require(Viewport.TileHit)

type Opened = TerrainInstance.Opened

-- Skip tiles facing away from the hit surface beyond this dot product (matching BrushTool).
local BACK_FACE_DOT = -0.25
-- Path subsampling spacing: roughly half a radius apart, capped at MAX_STEPS per frame.
local STEP_SHARE = 0.5
local MIN_STEP = 0.5
local MAX_STEPS = 16

local TriangleBrush = {}

-- Generates interpolated brush samples from `previous` to `position` and returns total travel distance.
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

-- Returns opened tiles in `models` within reach of `hit` and facing the same general direction.
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

-- Collects grid triangle indices covered by `samples` on `opened`, using cached shown centroids.
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
					-- Include the paired grid triangle in the same quad cell.
					choose(if g % 2 == 1 then g + 1 else g - 1)
				end
			end
		end
	end

	return result
end

-- Writes look index `target` to every grid triangle in `grids` passing `eligible`, updates the
-- affected wedges, and returns the modified shown triangle indices.
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
