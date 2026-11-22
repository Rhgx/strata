--!strict
--[[
	Geometry sculpt brushes, modeled after Hammer's spatial Paint Geometry with frame-rate-independent
	Studio timing. The brush acts as a world-space sphere affecting every vertex inside it across
	all target displacements.

	- Raise and Lower move vertices along the paint axis by `strength` studs/second at the center,
	  weighted by falloff: Soft uses (1 - d^2/R^2)^1.5 and Hard uses 1. (Hammer applies its
	  Distance once per mouse event with 1 - d^2/R^2, which leaves a visible crease at the rim.)
	- Brushes smaller than the grid spacing expand to reach at least one grid step (see
	  effectiveRadius) so they never sit dead between vertices. Distance down-weights offsets
	  along the tile's normal so vertices rising under a held brush remain inside it.
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

-- Minimum effective reach in grid steps so small brushes never miss every vertex (0.75 for Hard
-- still isolates a single vertex under the cursor). Smaller user radii still scale gentleness
-- proportionally so radius 1 and radius 3 feel distinct.
local MIN_SOFT_STEPS = 1
local MIN_HARD_STEPS = 0.75

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
}

type Move = { item: Item, index: number, vector: Vector3 }

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

-- Effective brush radius on `opened`, clamped below by grid spacing (also displayed by the cursor ring).
function Paint.effectiveRadius(opened: Opened, brush: Brush): number
	local soft = brush.effect == "Smooth" or brush.falloff == "Soft"

	return math.max(brush.radius, spacingOf(opened) * (if soft then MIN_SOFT_STEPS else MIN_HARD_STEPS))
end

-- Applies one brush tick along world-space path `centers` to `targets` over frame time `dt`,
-- returning modified vertex indices per tile.
function Paint.apply(targets: { Opened }, centers: { Vector3 }, brush: Brush, dt: number): { [Opened]: { [number]: true } }
	if #centers == 0 then
		return {}
	end

	-- Single gather covering the entire frame path and widest effective radius.
	local first, last = centers[1], centers[#centers]
	local middle = (first + last) / 2
	local halfSpan = (last - first).Magnitude / 2
	local smoothing = brush.effect == "Smooth"
	local maxRadius, maxSpacing = brush.radius, 0

	for _, opened in targets do
		maxSpacing = math.max(maxSpacing, spacingOf(opened))
		maxRadius = math.max(maxRadius, Paint.effectiveRadius(opened, brush))
	end

	-- Smoothing also reads neighbors up to one smoothing neighborhood past the brush rim.
	local neighborReach = if smoothing then math.max(maxRadius * SMOOTH_RADIUS_SHARE, maxSpacing * SMOOTH_STEPS) else 0
	local reach = maxRadius + halfSpan + neighborReach
	local items = gather(targets, middle, reach)
	local grid: Grid? = nil

	if smoothing and #items > 0 then
		grid = buildGrid(nearbyPoints(items, middle, reach), math.max(neighborReach, 0.5))
	end

	local smoothRate = math.clamp(brush.strength * SMOOTH_RATE, 0.5, MAX_SMOOTH_RATE)

	-- Compute all vertex moves before writing so smoothing evaluates only the pre-tick surface.
	local moves: { Move } = {}

	for _, item in items do
		local disp = item.opened.disp
		local radius = Paint.effectiveRadius(item.opened, brush)
		local r2 = radius * radius
		-- Scale strength proportionally when effectiveRadius was clamped up to the grid step.
		local gentleness = math.min(1, brush.radius / radius)
		local worldNormal = item.pivot:VectorToWorldSpace(item.faceNormal)

		for index, p in item.world do
			-- Raise/Lower sum all path samples (additive); Smooth and Raise To use the nearest sample.
			local nearest2 = math.huge
			local summed = 0

			for _, center in centers do
				local offset = p - center
				local axial = offset:Dot(worldNormal)
				local d2 = offset:Dot(offset) - AXIAL_SHARE * axial * axial

				if d2 < r2 then
					nearest2 = math.min(nearest2, d2)
					summed += if brush.falloff == "Soft" then softFalloff(d2, r2) else 1
				end
			end

			if nearest2 >= r2 then
				continue
			end

			local axis = localAxis(item, brush, index)
			local current = Displacement.fieldVector(disp, index)
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
					local alpha = 1 - math.exp(-brush.strength * RAISE_TO_RATE * softFalloff(nearest2, r2) * gentleness * dt)
					vector = current:Lerp(target, alpha)
				end
			elseif grid then
				local smoothRadius = math.max(radius * SMOOTH_RADIUS_SHARE, item.spacing * SMOOTH_STEPS)
				local unitAxis = if axis.Magnitude > 1e-6 then axis.Unit else item.faceNormal
				local h = smoothHeight(grid, p, item.pivot:VectorToWorldSpace(unitAxis), smoothRadius)
				vector = current + unitAxis * (h * approach(smoothRate, dt) * softFalloff(nearest2, r2) * gentleness)
			else
				local sign = if brush.effect == "Raise" then 1 else -1
				local weight = summed / #centers
				vector = current + axis * (sign * brush.strength * weight * gentleness * dt)
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

	return changed
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
