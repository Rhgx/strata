--!strict
--[[
	Geometry sculpt brushes, modeled after Hammer's spatial Paint Geometry with frame-rate-independent
	Studio timing. The brush acts as a world-space sphere affecting every vertex inside it across
	all target displacements.

	- Raise and Lower move vertices along the paint axis by `strength` studs/second at the center,
	  weighted by falloff: Soft uses (1 - d^2/R^2)^1.5 and Hard uses 1. (Hammer applies its
	  Distance once per mouse event with 1 - d^2/R^2, which leaves a visible crease at the rim.)
	- The brush is exactly its radius: only points inside it move, at any size. A brush smaller
	  than the grid can sit between points and move nothing; Paint.preview lists the points inside
	  (and, when there are none, the nearest ones to aim at) so the cursor can show them. Distance
	  down-weights offsets along the tile's normal so vertices rising under a held brush remain
	  inside it.
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

-- What the brush would move around a center, for the cursor to show.
export type Preview = {
	-- Kept points inside the brush, with the share of full strength each gets (0 to 1).
	inside: { { position: Vector3, weight: number } },
	-- More points are inside than `inside` lists (a large brush).
	more: boolean,
	-- When nothing is inside: the nearest kept points around the center, to aim at.
	nearby: { Vector3 },
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

-- An empty brush shows the points within this many cell radii (center to corner): on an
-- unsimplified tile that always includes the corners of the cell under the cursor.
local NEARBY_SHARE = 1.35
-- At most this many nearby points are shown.
local MAX_NEARBY = 4
-- Points of different tiles closer than this are the same point (matching Sew and Edges).
local TWIN_DISTANCE = 1 / 16

-- Fraction of squared distance removed along the tile normal. Keeping this below 1 keeps rising
-- vertices inside a held brush without over-extending reach on steep slopes.
local AXIAL_SHARE = 0.75
-- With that discount the brush reaches this many radii along a tile's normal, so tile gathering
-- (a plain distance check) must look this far to never miss a point inside the brush.
local AXIAL_REACH = 1 / math.sqrt(1 - AXIAL_SHARE)

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
	-- Raise/Lower weight summed over samples (falloff, or 1 per sample for Hard).
	summed: number,
	-- Nearest sample's squared distance, for Smooth and Raise To falloff.
	nearest2: number,
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

-- The larger grid spacing of opened in studs, from the longest tile edges so skewed tiles never
-- understate it.
local function spacingOf(opened: Opened): number
	local c = opened.disp.corners
	local longest = math.max((c[4] - c[1]).Magnitude, (c[3] - c[2]).Magnitude, (c[2] - c[1]).Magnitude, (c[3] - c[4]).Magnitude)

	return longest / (opened.disp.size - 1)
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

		table.insert(items, {
			opened = opened,
			pivot = pivot,
			faceNormal = faceNormal,
			positions = positions,
			world = world,
			spacing = spacingOf(opened),
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


-- The larger of `opened`'s two grid spacings in studs.
function Paint.gridSpacing(opened: Opened): number
	return spacingOf(opened)
end

-- Squared brush distance from `center` to `p` on `item`, discounting the offset along the tile's
-- normal (AXIAL_SHARE) exactly as Paint.apply does.
local function brushDistance2(item: Item, p: Vector3, center: Vector3): number
	local offset = p - center
	local axial = offset:Dot(item.worldNormal)

	return offset:Dot(offset) - AXIAL_SHARE * axial * axial
end

local function isEdgeIndex(disp: Displacement.Displacement, index: number): boolean
	local k = index - 1
	local size = disp.size
	local row, col = k // size, k % size

	return row == 0 or col == 0 or row == size - 1 or col == size - 1
end

-- Whether moving a point shows nothing: every triangle around it is a hole, or it is a denser
-- tile's in-between point along a coarser neighbor's 2:1 edge (no twin, but lying inside the
-- neighbor's edge), which sewing puts straight back. The preview leaves such points out.
local function isStuck(items: { Item }, item: Item, index: number): boolean
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

-- What a brush at `center` would move, by the same rules as Paint.apply: every kept point inside
-- it with its falloff weight (up to `limit` distinct points; seam twins count once), or, when
-- there are none, the nearest kept points around the center so the user can see where to aim.
-- `owner` (the tile under the cursor) sets how far that aiming search looks. Points whose move
-- would show nothing (see isStuck) are left out.
function Paint.preview(targets: { Opened }, center: Vector3, brush: Brush, limit: number, owner: Opened): Preview
	local nearbyReach = cellRadiusOf(owner) * NEARBY_SHARE
	local items = gather(targets, center, math.max(brush.radius, nearbyReach) * AXIAL_REACH)
	local r2 = brush.radius * brush.radius
	local nearby2 = nearbyReach * nearbyReach
	local soft = brush.falloff == "Soft" or brush.effect == "Smooth"
	local preview: Preview = { inside = {}, more = false, nearby = {} }
	type Near = { item: Item, index: number, d2: number }
	local near: { Near } = {}

	-- Index of an already listed point at `p` (a seam twin), if any.
	local function listed(list: { Vector3 }, p: Vector3): number?
		for i, shown in list do
			if (shown - p).Magnitude <= TWIN_DISTANCE then
				return i
			end
		end

		return nil
	end

	local insidePositions: { Vector3 } = {}

	for _, item in items do
		local removed = item.opened.disp.removed

		for index, p in item.world do
			if removed[index] then
				continue
			end

			local d2 = brushDistance2(item, p, center)

			if d2 < r2 then
				local weight = if soft then softFalloff(d2, r2) else 1
				local twin = listed(insidePositions, p)

				if twin then
					preview.inside[twin].weight = math.max(preview.inside[twin].weight, weight)
				elseif not isStuck(items, item, index) then
					if #preview.inside >= limit then
						preview.more = true
						return preview
					end

					table.insert(insidePositions, p)
					table.insert(preview.inside, { position = p, weight = weight })
				end
			elseif d2 < nearby2 then
				table.insert(near, { item = item, index = index, d2 = d2 })
			end
		end
	end

	if #preview.inside > 0 then
		return preview
	end

	table.sort(near, function (x: Near, y: Near)
		return x.d2 < y.d2
	end)

	for _, candidate in near do
		local p = candidate.item.world[candidate.index]

		if not listed(preview.nearby, p) and not isStuck(items, candidate.item, candidate.index) then
			table.insert(preview.nearby, p)

			if #preview.nearby >= MAX_NEARBY then
				break
			end
		end
	end

	return preview
end

-- Applies one brush tick along world-space path `centers` to `targets` over frame time `dt`,
-- returning modified vertex indices per tile, and whether the brush reached only points that
-- were removed (the Mesh tool). Removed points are skipped: they follow the shown surface and
-- would snap straight back, so a stroke over only removed points changes nothing.
function Paint.apply(
	targets: { Opened },
	centers: { Vector3 },
	brush: Brush,
	dt: number
): ({ [Opened]: { [number]: true } }, boolean)
	if #centers == 0 then
		return {}, false
	end

	-- Single gather covering the entire frame path and the radius.
	local first, last = centers[1], centers[#centers]
	local middle = (first + last) / 2
	local halfSpan = (last - first).Magnitude / 2
	local smoothing = brush.effect == "Smooth"
	local maxRadius, maxSpacing = brush.radius, 0

	for _, opened in targets do
		maxSpacing = math.max(maxSpacing, spacingOf(opened))
		-- Also cover the aiming area, to tell a ring between removed points (a simplified area)
		-- from a ring that just sits between kept points.
		maxRadius = math.max(maxRadius, cellRadiusOf(opened) * NEARBY_SHARE)
	end

	-- Smoothing also reads neighbors up to one smoothing neighborhood past the brush rim.
	local neighborReach = if smoothing then math.max(brush.radius * SMOOTH_RADIUS_SHARE, maxSpacing * SMOOTH_STEPS) else 0
	local reach = maxRadius * AXIAL_REACH + halfSpan + neighborReach
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

	local function hitOf(item: Item, index: number): Hit
		local list = hits[item]

		if not list then
			list = {}
			hits[item] = list
		end

		local hit = list[index]

		if not hit then
			hit = { summed = 0, nearest2 = math.huge }
			list[index] = hit
		end

		return hit
	end

	-- Points within the aiming area of an empty ring: removed ones only means simplified ground.
	local nearRemoved, nearKept = false, false

	for _, center in centers do
		for _, item in items do
			local removed = item.opened.disp.removed
			local nearby2 = (item.cellRadius * NEARBY_SHARE) ^ 2

			for index, p in item.world do
				local d2 = brushDistance2(item, p, center)

				if d2 >= r2 then
					if d2 < nearby2 then
						if removed[index] then
							nearRemoved = true
						else
							nearKept = true
						end
					end

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
			-- Smooth and Raise To ease by the nearest sample's falloff.
			local weight = softFalloff(hit.nearest2, r2)
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

	-- Only removed points reached: inside the ring, or (for a ring holding nothing) around it.
	local simplified = not reachedKept and (reachedRemoved or (nearRemoved and not nearKept))

	return changed, simplified
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
