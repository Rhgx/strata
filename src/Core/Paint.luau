--!strict
--[[
	Geometry sculpt brushes, modeled after Hammer's spatial Paint Geometry with frame-rate-independent
	Studio timing. The brush acts as a world-space sphere affecting every vertex inside it across
	all target displacements.

	- Raise and Lower move vertices along the paint axis by `strength` studs/second at the center,
	  weighted by falloff: Soft uses (1 - d^2/R^2)^1.5 and Hard uses 1. (Hammer applies its
	  Distance once per mouse event with 1 - d^2/R^2, which leaves a visible crease at the rim.)
	- The brush is always the real radius. Below a tile's grid size (pointThreshold) a sphere could
	  sit dead between points, so each path sample there acts on the single nearest point instead
	  (point mode, see snapIn), at full strength. Distance down-weights offsets along the tile's
	  normal so vertices rising under a held brush remain inside it.
	- Raise To with Hard falloff snaps vertices to `height` studs along the axis from the flat
	  base face, clearing offset and elevation (Hammer's absolute mode). Soft falloff eases
	  toward that target with a feathered rim.
	- Smooth moves each vertex along the axis toward the weighted height of neighboring vertices
	  across the entire working set (smoothing across seams as well), scaled by Soft falloff and
	  approaching exponentially for frame-rate independence. Intentional deviation from Hammer:
	  Hammer shrinks its neighborhood to zero near the brush rim and weights neighbors at
	  0.5 / Distance (0.1) against the vertex itself, which barely moved vertices on Roblox-scale
	  grids (2 to 8 studs apart). Here the neighborhood is at least 1.5 grid steps throughout the
	  brush (or a quarter of the radius for large brushes), matching sculpt tools like Blender.

	Each tick accepts every sample along the brush's frame path so fast drags produce continuous
	strokes rather than discrete dabs. Updating a vertex re-derives its stored normal and distance
	from its new position (matching Hammer's paint commit), so painting along X/Y/Z or a picked
	axis rotates the stored normal.
]]

local Core = script.Parent

local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

type Opened = TerrainInstance.Opened

export type Effect = "Raise" | "Lower" | "Smooth" | "RaiseTo"
export type Falloff = "Soft" | "Hard"
-- Face: tile base normal. Up: world +Y (Hammer's default Z-up). Picked: user-sampled world
-- vector. Subdiv: per-vertex subdivision offset normal.
export type Axis = "Face" | "Up" | "X" | "Z" | "Picked" | "Subdiv"

-- A point-mode target: the nearest eligible point and its coincident seam twins, moved together.
export type Snap = {
	points: { { opened: Opened, index: number } },
	position: Vector3,
}

export type Brush = {
	effect: Effect,
	falloff: Falloff,
	axis: Axis,
	-- World-space unit vector for "Picked".
	pickedAxis: Vector3,
	radius: number,
	strength: number,
	-- Target distance in studs along the axis for Raise To.
	height: number,
	-- When true, Raise To measures `height` from the world origin (uniform across stepped tiles,
	-- such as a road) instead of each tile's flat base.
	raiseToWorld: boolean,
}

-- Smoothing neighborhood: at least this many grid steps or this fraction of the brush radius.
local SMOOTH_STEPS = 1.5
local SMOOTH_RADIUS_SHARE = 0.25
-- Squared distance below which a candidate is the vertex itself or its seam twin.
local SAME_POINT2 = 1e-6
-- Ignore tiny moves so a converged Raise To or Smooth does not mark vertices dirty.
local MIN_MOVE = 1e-5

-- Exponential approach rates. Smooth and soft Raise To converge independently of frame rate;
-- capping each step at 0.5 prevents overshoot.
local MAX_STEP = 0.5
local SMOOTH_RATE = 1.5
local MAX_SMOOTH_RATE = 24
local RAISE_TO_RATE = 2.5

-- Point mode starts below this share of a tile's RMS cell spacing (its cell size on a square
-- grid). Right above it, a sample at a cell's center still gives each corner a usable Soft
-- weight, so the switch to area mode never leaves a weak spot. One threshold for every effect
-- and falloff, so holding Shift for Smooth or switching falloff never flips modes mid-stroke.
local POINT_SHARE = 0.85
-- Point mode snaps to points within this many cell radii (center to corner), so every spot on
-- an unsimplified tile has a point while a simplified area never grabs a far-away corner.
local SNAP_SHARE = 1.35
-- Points of different tiles closer than this are the same point (matching Sew and Edges).
local TWIN_DISTANCE = 1 / 16

-- Fraction of squared distance removed along the tile normal. Keeping this below 1 keeps rising
-- vertices inside a held brush without over-extending reach on steep slopes.
local AXIAL_SHARE = 0.75

type Item = {
	opened: Opened,
	pivot: CFrame,
	faceNormal: Vector3,
	positions: { Vector3 },
	world: { Vector3 },
	-- Larger of the two grid spacing dimensions in studs.
	spacing: number,
	-- Distance from a grid cell's center to its corners, in studs.
	cellRadius: number,
	worldNormal: Vector3,
}

type Move = { item: Item, index: number, vector: Vector3 }

-- Per-vertex accumulation over a frame's path samples.
type Hit = {
	-- Raise/Lower weight summed over samples (falloff in area mode, 1 per point-mode sample).
	summed: number,
	-- Nearest area-mode squared distance, for Smooth and Raise To falloff.
	nearest2: number,
	-- Point-mode samples that snapped to this vertex.
	pointHits: number,
}

-- Spatial hash of smoothing candidates in `cell`-sized cubes so each vertex queries only
-- overlapping cells rather than scanning every candidate (thousands vs. millions of checks).
type Grid = {
	cell: number,
	cells: { [number]: { [number]: { [number]: { Vector3 } } } },
}

local Paint = {}

local function worldAxis(axis: Axis, picked: Vector3): Vector3?
	if axis == "Up" then
		return Vector3.yAxis
	elseif axis == "X" then
		return Vector3.xAxis
	elseif axis == "Z" then
		return Vector3.zAxis
	elseif axis == "Picked" then
		return picked
	end

	return nil
end

-- Returns the brush's world-space unit axis, or nil for per-tile axes (Face, Subdiv).
function Paint.worldAxisOf(brush: Brush): Vector3?
	local axis = worldAxis(brush.axis, brush.pickedAxis)

	return if axis and axis.Magnitude > 1e-6 then axis.Unit else nil
end

-- Returns a vertex's paint axis in tile-local space without normalizing (Hammer uses the stored
-- axis directly, and offset normals can be shorter than unit length after sewing).
local function localAxis(item: Item, brush: Brush, index: number): Vector3
	if brush.axis == "Face" then
		return item.faceNormal
	elseif brush.axis == "Subdiv" then
		return item.opened.disp.offsetNormals[index]
	end

	return item.pivot:VectorToObjectSpace(worldAxis(brush.axis, brush.pickedAxis) or Vector3.yAxis)
end

local function distanceToBounds(point: Vector3, min: Vector3, max: Vector3): number
	return (point - point:Max(min):Min(max)).Magnitude
end

-- Distance from a grid cell's center to its corners. Uses the longer of each pair of opposite
-- tile edges, so skewed tiles never understate their cells.
local function cellRadiusOf(opened: Opened): number
	local c = opened.disp.corners
	local steps = opened.disp.size - 1
	local su = math.max((c[4] - c[1]).Magnitude, (c[3] - c[2]).Magnitude) / steps
	local sv = math.max((c[2] - c[1]).Magnitude, (c[3] - c[4]).Magnitude) / steps

	return 0.5 * math.sqrt(su * su + sv * sv)
end

-- The radius below which the brush works in point mode on `opened`: POINT_SHARE of the cell's
-- RMS spacing (the cell size on a square grid, about 5.8 rather than 8 on an 8 x 2 cell).
function Paint.pointThreshold(opened: Opened): number
	return cellRadiusOf(opened) * math.sqrt(2) * POINT_SHARE
end

function Paint.isPointMode(opened: Opened, radius: number): boolean
	return radius < Paint.pointThreshold(opened) - 1e-3
end

-- Collects tiles whose bounding box comes within `reach` studs of `center`, caching world positions.
local function gather(targets: { Opened }, center: Vector3, reach: number): { Item }
	local items: { Item } = {}

	for _, opened in targets do
		local pivot = opened.model:GetPivot()

		if distanceToBounds(pivot:PointToObjectSpace(center), opened.boundsMin, opened.boundsMax) > reach then
			continue
		end

		local faceNormal = Displacement.faceNormal(opened.disp)
		local positions = Displacement.positions(opened.disp, faceNormal)
		local world = table.create(#positions)

		for i, position in positions do
			world[i] = pivot * position
		end

		local c = opened.disp.corners
		local steps = opened.disp.size - 1
		local spacing = math.max((c[4] - c[1]).Magnitude, (c[2] - c[1]).Magnitude) / steps

		table.insert(items, {
			opened = opened,
			pivot = pivot,
			faceNormal = faceNormal,
			positions = positions,
			world = world,
			spacing = spacing,
			cellRadius = cellRadiusOf(opened),
			worldNormal = pivot:VectorToWorldSpace(faceNormal),
		})
	end

	return items
end

-- Collects all world-space vertex positions within `reach` of `center` for smoothing.
local function nearbyPoints(items: { Item }, center: Vector3, reach: number): { Vector3 }
	local reach2 = reach * reach
	local points: { Vector3 } = {}

	for _, item in items do
		for _, q in item.world do
			local offset = q - center

			if offset:Dot(offset) < reach2 then
				table.insert(points, q)
			end
		end
	end

	return points
end

local function buildGrid(points: { Vector3 }, cell: number): Grid
	local cells: { [number]: { [number]: { [number]: { Vector3 } } } } = {}

	for _, q in points do
		local ix, iy, iz = math.floor(q.X / cell), math.floor(q.Y / cell), math.floor(q.Z / cell)
		local plane = cells[ix]

		if not plane then
			plane = {}
			cells[ix] = plane
		end

		local row = plane[iy]

		if not row then
			row = {}
			plane[iy] = row
		end

		local bucket = row[iz]

		if not bucket then
			bucket = {}
			row[iz] = bucket
		end

		table.insert(bucket, q)
	end

	return { cell = cell, cells = cells }
end

-- Computes the signed height delta along `axis` (world) from `p` to the weighted average of its
-- neighbors within `smoothRadius`, excluding `p` itself and any seam twins.
local function smoothHeight(grid: Grid, p: Vector3, axis: Vector3, smoothRadius: number): number
	local r2 = smoothRadius * smoothRadius
	local sumW, sumH = 0, 0
	local pHeight = p:Dot(axis)
	local cell = grid.cell
	local x0, x1 = math.floor((p.X - smoothRadius) / cell), math.floor((p.X + smoothRadius) / cell)
	local y0, y1 = math.floor((p.Y - smoothRadius) / cell), math.floor((p.Y + smoothRadius) / cell)
	local z0, z1 = math.floor((p.Z - smoothRadius) / cell), math.floor((p.Z + smoothRadius) / cell)

	for ix = x0, x1 do
		local plane = grid.cells[ix]

		if not plane then
			continue
		end

		for iy = y0, y1 do
			local row = plane[iy]

			if not row then
				continue
			end

			for iz = z0, z1 do
				local bucket = row[iz]

				if not bucket then
					continue
				end

				for _, q in bucket do
					local offset = q - p
					local d2 = offset:Dot(offset)

					if d2 < r2 and d2 > SAME_POINT2 then
						-- (1 - u^2)^2 tapers smoothly to zero at the boundary so neighbors
						-- entering or leaving the radius never cause discontinuities.
						local u = 1 - d2 / r2
						local w = u * u
						sumW += w
						sumH += w * (q:Dot(axis) - pHeight)
					end
				end
			end
		end
	end

	return if sumW > 0 then sumH / sumW else 0
end

-- Soft falloff (1 - u^2)^1.5 at squared distance `d2` within radius^2 `r2`. Flattens out at the
-- rim (unlike Hammer's 1 - u^2) so hills blend smoothly without a ring crease, with its
-- half-strength contour at 0.61 of the radius.
local function softFalloff(d2: number, r2: number): number
	local t = math.max(1 - d2 / r2, 0)

	return t * math.sqrt(t)
end

local function approach(rate: number, dt: number): number
	return math.min(1 - math.exp(-rate * dt), MAX_STEP)
end

local function spacingOf(opened: Opened): number
	local c = opened.disp.corners

	return math.max((c[4] - c[1]).Magnitude, (c[2] - c[1]).Magnitude) / (opened.disp.size - 1)
end

-- How far point mode looks for a point around a sample on `item`.
local function snapReach(item: Item, radius: number): number
	return math.max(radius, item.cellRadius * SNAP_SHARE)
end

-- The tile a sample belongs to: the one whose bounds it is inside (or nearest), preferring
-- `owner` (the tile under the cursor) on ties such as a seam.
local function ownerOf(items: { Item }, center: Vector3, owner: Opened?): Item?
	local best: Item? = nil
	local bestGap = math.huge

	for _, item in items do
		local gap = distanceToBounds(item.pivot:PointToObjectSpace(center), item.opened.boundsMin, item.opened.boundsMax)

		if item.opened == owner then
			gap -= 1e-3
		end

		if gap < bestGap then
			best, bestGap = item, gap
		end
	end

	return best
end

local function isEdgeIndex(disp: Displacement.Displacement, index: number): boolean
	local k = index - 1
	local size = disp.size
	local row, col = k // size, k % size

	return row == 0 or col == 0 or row == size - 1 or col == size - 1
end

-- Whether a point cannot be moved on its own: every triangle around it is a hole, or it is a
-- denser tile's in-between point along a coarser neighbor's 2:1 edge (no twin, but lying inside
-- the neighbor's edge), which live sewing would put straight back.
local function isFollower(items: { Item }, item: Item, index: number): boolean
	local disp = item.opened.disp
	local open = false

	for _, t in Displacement.trianglesTouching(disp, { [index] = true }) do
		if not Displacement.isHole(disp, t) then
			open = true
			break
		end
	end

	if not open then
		return true
	end

	if not isEdgeIndex(disp, index) then
		return false
	end

	local p = item.world[index]

	for _, other in items do
		if other ~= item then
			for _, q in other.world do
				if (q - p).Magnitude <= TWIN_DISTANCE then
					return false
				end
			end
		end
	end

	for _, other in items do
		if other == item then
			continue
		end

		for _, edge in Displacement.edges(other.opened.disp) do
			local indices = edge.indices

			for k = 1, #indices - 1 do
				local a, b = other.world[indices[k]], other.world[indices[k + 1]]
				local ab = b - a
				local length2 = ab:Dot(ab)

				if length2 < 1e-9 then
					continue
				end

				local t = (p - a):Dot(ab) / length2

				if math.sqrt(length2) * math.min(t, 1 - t) > TWIN_DISTANCE and (p - (a + ab * t)).Magnitude <= TWIN_DISTANCE then
					return true
				end
			end
		end
	end

	return false
end

-- Point mode for one sample: the nearest kept, movable point within reach (measured with the
-- owner tile's normal discounted, like area mode), plus its seam twins. Returns nil when no such
-- point is near, and whether a removed point was (for the simplified-area warning).
local function snapIn(items: { Item }, center: Vector3, owner: Item, radius: number): (Snap?, boolean)
	local reach = snapReach(owner, radius)
	local reach2 = reach * reach
	local normal = owner.worldNormal
	type Candidate = { item: Item, index: number, d2: number }
	local candidates: { Candidate } = {}
	local reachedRemoved = false

	for _, item in items do
		local removed = item.opened.disp.removed

		for index, p in item.world do
			local offset = p - center
			local axial = offset:Dot(normal)
			local d2 = offset:Dot(offset) - AXIAL_SHARE * axial * axial

			if d2 < reach2 then
				if removed[index] then
					reachedRemoved = true
				else
					table.insert(candidates, { item = item, index = index, d2 = d2 })
				end
			end
		end
	end

	table.sort(candidates, function (x: Candidate, y: Candidate)
		return x.d2 < y.d2
	end)

	for _, candidate in candidates do
		if isFollower(items, candidate.item, candidate.index) then
			continue
		end

		local position = candidate.item.world[candidate.index]
		local points = {}

		for _, item in items do
			local removed = item.opened.disp.removed

			for index, q in item.world do
				if not removed[index] and (q - position).Magnitude <= TWIN_DISTANCE then
					table.insert(points, { opened = item.opened, index = index })
				end
			end
		end

		return { points = points, position = position }, false
	end

	return nil, reachedRemoved
end

-- The point(s) the brush would move around `center` in point mode, or nil when `owner` is not in
-- point mode or no movable point is near. Used for the cursor marker and Raise To height picking,
-- through the same rules as Paint.apply.
function Paint.snap(targets: { Opened }, center: Vector3, brush: Brush, owner: Opened): Snap?
	if not Paint.isPointMode(owner, brush.radius) then
		return nil
	end

	local items = gather(targets, center, math.max(brush.radius, cellRadiusOf(owner) * SNAP_SHARE) + TWIN_DISTANCE)
	local ownerItem = ownerOf(items, center, owner)

	if not ownerItem then
		return nil
	end

	local snap = snapIn(items, center, ownerItem, brush.radius)
	return snap
end

-- Applies one brush tick along world-space path `centers` to `targets` over frame time `dt`,
-- returning modified vertex indices per tile, whether the brush reached only points that were
-- removed (the Mesh tool), and the point-mode target of the last sample. Removed points are
-- skipped: they follow the shown surface and would snap straight back, so a stroke over only
-- removed points changes nothing.
--
-- Each sample works in area mode (every point inside the real radius, weighted by falloff) or,
-- where the radius is below its tile's point threshold, point mode (the nearest point at full
-- weight). `owner` is the tile under the cursor, preferred where a sample sits on a seam. A
-- `held` target replaces point-mode snapping while the cursor holds still, so a point rising
-- under a held brush is never traded for a neighbor that now measures closer.
function Paint.apply(
	targets: { Opened },
	centers: { Vector3 },
	brush: Brush,
	dt: number,
	owner: Opened?,
	held: Snap?
): ({ [Opened]: { [number]: true } }, boolean, Snap?)
	if #centers == 0 then
		return {}, false, nil
	end

	-- Single gather covering the entire frame path, the radius, and point-mode snapping.
	local first, last = centers[1], centers[#centers]
	local middle = (first + last) / 2
	local halfSpan = (last - first).Magnitude / 2
	local smoothing = brush.effect == "Smooth"
	local maxRadius, maxSpacing = brush.radius, 0

	for _, opened in targets do
		maxSpacing = math.max(maxSpacing, spacingOf(opened))
		maxRadius = math.max(maxRadius, cellRadiusOf(opened) * SNAP_SHARE)
	end

	-- Smoothing also reads neighbors up to one smoothing neighborhood past the brush rim.
	local neighborReach = if smoothing then math.max(brush.radius * SMOOTH_RADIUS_SHARE, maxSpacing * SMOOTH_STEPS) else 0
	local reach = maxRadius + halfSpan + neighborReach + TWIN_DISTANCE
	local items = gather(targets, middle, reach)
	local grid: Grid? = nil

	if smoothing and #items > 0 then
		grid = buildGrid(nearbyPoints(items, middle, reach), math.max(neighborReach, 0.5))
	end

	local smoothRate = math.clamp(brush.strength * SMOOTH_RATE, 0.5, MAX_SMOOTH_RATE)

	-- Compute all vertex moves before writing so smoothing evaluates only the pre-tick surface.
	local moves: { Move } = {}
	local radius = brush.radius
	local r2 = radius * radius
	local hits: { [Item]: { [number]: Hit } } = {}
	local reachedRemoved, reachedKept = false, false
	local lastSnap: Snap? = nil

	local function hitOf(item: Item, index: number): Hit
		local list = hits[item]

		if not list then
			list = {}
			hits[item] = list
		end

		local hit = list[index]

		if not hit then
			hit = { summed = 0, nearest2 = math.huge, pointHits = 0 }
			list[index] = hit
		end

		return hit
	end

	local itemOf: { [Opened]: Item } = {}

	for _, item in items do
		itemOf[item.opened] = item
	end

	for _, center in centers do
		local ownerItem = ownerOf(items, center, owner)

		if ownerItem and Paint.isPointMode(ownerItem.opened, radius) then
			local snap = held

			if not snap then
				local found, removedNear = snapIn(items, center, ownerItem, radius)
				snap = found
				reachedRemoved = reachedRemoved or removedNear
			end

			if snap then
				reachedKept = true
				lastSnap = snap

				for _, point in snap.points do
					local item = itemOf[point.opened]

					if item then
						local hit = hitOf(item, point.index)
						hit.summed += 1
						hit.pointHits += 1
					end
				end
			end

			continue
		end

		for _, item in items do
			local removed = item.opened.disp.removed
			local worldNormal = item.worldNormal

			for index, p in item.world do
				local offset = p - center
				local axial = offset:Dot(worldNormal)
				local d2 = offset:Dot(offset) - AXIAL_SHARE * axial * axial

				if d2 >= r2 then
					continue
				end

				if removed[index] then
					reachedRemoved = true
					continue
				end

				reachedKept = true

				local hit = hitOf(item, index)
				hit.nearest2 = math.min(hit.nearest2, d2)
				hit.summed += if brush.falloff == "Soft" then softFalloff(d2, r2) else 1
			end
		end
	end

	for item, list in hits do
		local disp = item.opened.disp

		for index, hit in list do
			-- Smooth and Raise To ease by the nearest area sample's falloff or by the share of
			-- samples that snapped here, so a fast drag over several points splits the time.
			local weight = math.max(
				if hit.nearest2 < r2 then softFalloff(hit.nearest2, r2) else 0,
				hit.pointHits / #centers
			)
			local axis = localAxis(item, brush, index)
			local current = Displacement.fieldVector(disp, index)
			local p = item.world[index]
			local vector: Vector3

			if brush.effect == "RaiseTo" then
				local target: Vector3

				if brush.raiseToWorld then
					-- Measure height along the world axis (or face normal for Face/Subdiv,
					-- matching Paint.heightAt) and move along the vertex's own axis to reach it.
					local unitAxis = if axis.Magnitude > 1e-6 then axis.Unit else item.faceNormal
					local measure = item.pivot:VectorToWorldSpace(
						if brush.axis == "Face" or brush.axis == "Subdiv" then item.faceNormal else unitAxis
					)
					local along = item.pivot:VectorToWorldSpace(unitAxis):Dot(measure)

					if math.abs(along) < 0.15 then
						-- Skip vertices whose paint axis is nearly perpendicular to the height axis.
						continue
					end

					target = current + unitAxis * ((brush.height - p:Dot(measure)) / along)
				else
					target = axis * brush.height - disp.offsets[index] - item.faceNormal * disp.elevation
				end

				if brush.falloff == "Hard" then
					-- Hammer's absolute mode: jump directly to the target height.
					vector = target
				else
					local alpha = 1 - math.exp(-brush.strength * RAISE_TO_RATE * weight * dt)
					vector = current:Lerp(target, alpha)
				end
			elseif grid then
				local smoothRadius = math.max(radius * SMOOTH_RADIUS_SHARE, item.spacing * SMOOTH_STEPS)
				local unitAxis = if axis.Magnitude > 1e-6 then axis.Unit else item.faceNormal
				local h = smoothHeight(grid, p, item.pivot:VectorToWorldSpace(unitAxis), smoothRadius)
				vector = current + unitAxis * (h * approach(smoothRate, dt) * weight)
			else
				-- Raise/Lower sum all path samples (additive), averaged over the frame's samples.
				local sign = if brush.effect == "Raise" then 1 else -1
				vector = current + axis * (sign * brush.strength * (hit.summed / #centers) * dt)
			end

			if (vector - current).Magnitude > MIN_MOVE then
				table.insert(moves, { item = item, index = index, vector = vector })
			end
		end
	end

	local changed: { [Opened]: { [number]: true } } = {}

	for _, move in moves do
		local opened = move.item.opened
		Displacement.setFieldVector(opened.disp, move.index, move.vector)

		local set = changed[opened]

		if not set then
			set = {}
			changed[opened] = set
		end

		set[move.index] = true
	end

	return changed, reachedRemoved and not reachedKept, lastSnap
end

-- Samples the Raise To height of `point` (world space) on `opened`: studs along the brush axis
-- from the flat base face, or from the world origin when `brush.raiseToWorld` is true.
function Paint.heightAt(opened: Opened, point: Vector3, brush: Brush): number
	local pivot = opened.model:GetPivot()
	local disp = opened.disp
	local normal = Displacement.faceNormal(disp)

	if brush.raiseToWorld then
		local world = if brush.axis == "Face" or brush.axis == "Subdiv"
			then pivot:VectorToWorldSpace(normal)
			else worldAxis(brush.axis, brush.pickedAxis) or Vector3.yAxis

		return point:Dot(world.Unit)
	end

	local axis = if brush.axis == "Face" or brush.axis == "Subdiv"
		then normal
		else pivot:VectorToObjectSpace(worldAxis(brush.axis, brush.pickedAxis) or Vector3.yAxis)
	local along = axis:Dot(normal)

	if math.abs(along) < 1e-6 then
		return 0
	end

	-- Solve (base + axis * height) . normal = point . normal for `height`.
	local offset = pivot:PointToObjectSpace(point) - disp.corners[1]

	return offset:Dot(normal) / along
end

return Paint
