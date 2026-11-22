--!strict
--[[
	Shared coverage and write logic for triangle-based brushes (Material tool and Mesh Cut holes).

	Coverage includes the shown triangle directly under the pointer plus every shown triangle
	whose centroid falls within the brush radius at any path sample. Because looks and holes live
	on grid triangles, each covered shown triangle expands to all grid triangles it covers (a
	large simplified triangle affects its full footprint). When `fine` is false, both triangles
	of each touched grid cell are selected so painted edges form clean steps rather than sawteeth.
	On a tile with points removed, any shown triangle reached that way is then taken whole, so no
	shown triangle is ever left with a mix of looks it cannot display.
]]

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Core = Plugin.Core

local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Settings = require(Plugin.State.Settings)

local Session = require(Plugin.Scene.Session)

local TileHit = require(Viewport.TileHit)

type Opened = TerrainInstance.Opened

-- Skip tiles facing away from the hit surface beyond this dot product (matching BrushTool).
local BACK_FACE_DOT = -0.25
-- Path subsampling spacing: roughly half a radius apart, capped at MAX_STEPS per frame.
local STEP_SHARE = 0.5
local MIN_STEP = 0.5
local MAX_STEPS = 16

-- Share of the brush radius within which a shown triangle's surface (not only its centroid)
-- selects it; see gridTriangles.
local SURFACE_REACH_SHARE = 0.5

local TriangleBrush = {}

-- The point of triangle abc closest to `p` (Ericson, Real-Time Collision Detection 5.1.5).
local function closestOnTriangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3): Vector3
	local ab, ac, ap = b - a, c - a, p - a
	local d1, d2 = ab:Dot(ap), ac:Dot(ap)

	if d1 <= 0 and d2 <= 0 then
		return a
	end

	local bp = p - b
	local d3, d4 = ab:Dot(bp), ac:Dot(bp)

	if d3 >= 0 and d4 <= d3 then
		return b
	end

	local vc = d1 * d4 - d3 * d2

	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		return a + ab * (d1 / (d1 - d3))
	end

	local cp = p - c
	local d5, d6 = ab:Dot(cp), ac:Dot(cp)

	if d6 >= 0 and d5 <= d6 then
		return c
	end

	local vb = d5 * d2 - d1 * d6

	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		return a + ac * (d2 / (d2 - d6))
	end

	local va = d3 * d6 - d5 * d4

	if va <= 0 and d4 - d3 >= 0 and d5 - d6 >= 0 then
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	end

	local denominator = va + vb + vc

	if denominator == 0 then
		return a
	end

	local v, w = vb / denominator, vc / denominator

	return a + ab * v + ac * w
end

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
	local allowed = if Settings.get().paintSelectedOnly then models else nil
	local reach = radius + travel
	local result = { hit.opened }
	local seen: { [Opened]: true } = { [hit.opened] = true }

	for _, opened in Session.nearRadius(hit.position, reach, allowed) do
		if seen[opened] then
			continue
		end

		local pivot = opened.model:GetPivot()
		local faceNormal = pivot:VectorToWorldSpace(Displacement.faceNormal(opened.disp))
		local nearest = pivot:PointToObjectSpace(hit.position)
		local gap = (nearest - nearest:Max(opened.boundsMin):Min(opened.boundsMax)).Magnitude

		if faceNormal:Dot(hitFace) < BACK_FACE_DOT or gap > reach then
			continue
		end

		seen[opened] = true
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

	local simplified = Displacement.mesh(disp) ~= nil
	-- World vertex positions, computed only if a triangle needs the surface test below.
	local world: { Vector3 }? = nil
	local reach = radius * SURFACE_REACH_SHARE

	local function surfaceWithinReach(t: number): boolean
		if not world then
			local pivot = opened.model:GetPivot()
			local positions = Displacement.positions(disp)
			local list = table.create(#positions)

			for i, position in positions do
				list[i] = pivot * position
			end

			world = list
		end

		local points = world :: { Vector3 }
		local i1, i2, i3 = Displacement.triangle(disp, t)
		local a, b, c = points[i1], points[i2], points[i3]
		local center = centers[t]
		-- No vertex is farther from the centroid than this, so a sample beyond it plus the reach
		-- cannot touch the triangle.
		local extent = math.max((a - center).Magnitude, (b - center).Magnitude, (c - center).Magnitude)

		-- Only triangles larger than the brush can be missed by the centroid test.
		if extent <= radius then
			return false
		end

		for _, sample in samples do
			if (sample - center).Magnitude <= extent + reach and (closestOnTriangle(sample, a, b, c) - sample).Magnitude <= reach then
				return true
			end
		end

		return false
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

		-- A large shown triangle (points removed) can have its centroid far outside the brush
		-- while the brush is over it: when the cursor is on the neighbor across a seam, when no
		-- exact triangle was resolved (a wedge's side, a baked union), or when a fast drag crosses
		-- it between frames. It counts once the inner part of the brush reaches its surface. Whole
		-- grids keep the centroid test alone, so their footprint is unchanged.
		if not inside and simplified then
			inside = surfaceWithinReach(t)
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

	-- With points removed, a shown triangle displays the majority look of the grid triangles it
	-- covers, so writing only some of them (a quad cell's partner can belong to the next shown
	-- triangle) changes data the user cannot see, and the triangle seems to refuse the paint.
	-- Every shown triangle that gets any grid triangle gets all of them.
	local mesh = Displacement.mesh(disp)

	if mesh then
		for _, g in table.clone(result) do
			local owner = mesh.shownOf[g]

			if owner then
				for _, other in mesh.cover[owner] do
					choose(other)
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
	local writtenGrids: { [number]: true } = {}

	for _, g in grids do
		if disp.triLooks[g] ~= target and eligible(g) then
			disp.triLooks[g] = target
			writtenGrids[g] = true

			local t = Displacement.shownOf(disp, g)

			if not shown[t] then
				shown[t] = true
				table.insert(changed, t)
			end
		end
	end

	-- A thin shown triangle that covers no grid triangle takes its look from the grid triangle
	-- under its center (see Displacement.coverOf), which belongs to another shown triangle, so it
	-- is refreshed too when that grid triangle changes. Otherwise it keeps showing its old look.
	local mesh = Displacement.mesh(disp)

	if mesh and next(writtenGrids) ~= nil then
		for t, cover in mesh.cover do
			if #cover == 0 and not shown[t] and writtenGrids[Displacement.coverOf(disp, t)[1]] then
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
