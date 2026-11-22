--!strict
--[[
	Paint geometry brushes, following Hammer's spatial Paint Geometry with Studio-friendly
	timing. The brush is a 3D sphere around the center (world space) and affects every vertex
	inside it, across displacements.

	- Raise and Lower move vertices along the paint axis by `strength` studs per second at the
	  brush center, times the falloff: Soft is (1 - d^2/R^2)^1.5, Hard is 1. (Hammer adds its
	  Distance once per mouse event with 1 - d^2/R^2, which leaves a crease at the rim.)
	- A brush smaller than the grid reaches at least one grid step (see effectiveRadius), so it
	  never sits between vertices doing nothing. Distance counts a vertex's offset along its
	  tile's normal at half weight, so vertices rising under a held brush stay inside it.
	- Raise To with Hard falloff places vertices `height` studs along the axis from their flat
	  base point, dropping offset and elevation (Hammer's absolute mode). With Soft falloff it
	  eases toward that height, feathered at the rim.
	- Smooth moves each vertex in the brush along the axis toward the weighted height of its
	  neighbors (vertices of any displacement in the working set, so seams smooth too), scaled by
	  the Soft falloff, approaching it exponentially so it behaves the same at any frame rate.
	  Deliberate deviation from Hammer: Hammer's neighborhood shrinks to nothing toward the brush
	  edge and weighs neighbors at 0.5 / Distance (0.1) against the vertex itself, which on
	  Roblox-sized grids (vertices 2 to 8 studs apart) left most of the brush untouched and the
	  rest barely moving. Here the neighborhood is at least 1.5 grid steps everywhere in the brush
	  (a quarter of the radius for big brushes), like sculpting tools such as Blender.

	A tick takes every point the brush passed during the frame, so fast drags leave a continuous
	stroke instead of separate dabs.

	Moving a vertex re-derives its stored normal and distance from the new position, like
	Hammer's paint commit, so a vertex moved along X/Y/Z or a picked axis gets a rotated normal.
]]

local Displacement = require(script.Parent.Displacement)
local TerrainInstance = require(script.Parent.TerrainInstance)

type Opened = TerrainInstance.Opened

export type Effect = "Raise" | "Lower" | "Smooth" | "RaiseTo"
export type Falloff = "Soft" | "Hard"
-- Face: each displacement's base normal. Up: world +Y (Hammer's default Z-up axis).
-- Picked: a world vector set by clicking a face. Subdiv: each vertex's offset normal.
export type Axis = "Face" | "Up" | "X" | "Z" | "Picked" | "Subdiv"

export type Brush = {
	effect: Effect,
	falloff: Falloff,
	axis: Axis,
	-- World-space axis for "Picked".
	pickedAxis: Vector3,
	radius: number,
	strength: number,
	-- Studs along the axis for Raise To.
	height: number,
}

-- Smooth's neighborhood: at least this many grid steps, or this share of the brush radius.
local SMOOTH_STEPS = 1.5
local SMOOTH_RADIUS_SHARE = 0.25
-- Neighbors closer than this are the vertex itself or its twin on a neighboring tile.
local SAME_POINT2 = 1e-6
-- Moves smaller than this are skipped, so a settled Raise To or Smooth does not mark changes.
local MIN_MOVE = 1e-5

type Item = {
	opened: Opened,
	pivot: CFrame,
	faceNormal: Vector3,
	positions: { Vector3 },
	world: { Vector3 },
	-- Distance between neighboring grid vertices (the larger of the two directions).
	spacing: number,
}

type Move = { item: Item, index: number, vector: Vector3 }

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

-- The paint axis of one vertex, in the displacement's local space. Not normalized (Hammer uses
-- the axis as given; offset normals can be shorter than 1 after a sew).
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

-- The displacements whose surface comes within `reach` of `center`, with positions cached.
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

-- Every vertex position (world) within `reach` of `center`: the candidates for smoothing.
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

-- Smoothing candidates bucketed in a grid of `cell`-sized cubes, so each vertex only visits
-- the cells its smoothing radius overlaps instead of every candidate. With big brushes on
-- dense tiles that is the difference between thousands and millions of checks per frame.
type Grid = {
	cell: number,
	cells: { [number]: { [number]: { [number]: { Vector3 } } } },
}

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

-- How far vertex `p` (world) is below the weighted height of its neighbors within
-- `smoothRadius`, measured along `axis` (world). The vertex itself and its twins on
-- neighboring tiles are left out, so it moves toward its surroundings.
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
						-- (1 - u^2)^2 falls smoothly to zero at the edge, so a neighbor entering or
						-- leaving the neighborhood never makes the target jump.
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

-- Soft brush falloff at squared distance `d2` inside radius^2 `r2`: (1 - u^2)^1.5. Unlike
-- Hammer's 1 - u^2 it flattens out at the rim, so hills blend into the ground instead of
-- meeting it at a ring-shaped crease, while keeping most of the brush's body. Its
-- half-strength contour is at 0.61 of the radius.
local function softFalloff(d2: number, r2: number): number
	local t = math.max(1 - d2 / r2, 0)
	return t * math.sqrt(t)
end

-- Brush speeds. Raise and Lower move `strength` studs per second at the brush center, at any
-- radius (the brush applies over time, so a drag already deposits in proportion to its size).
-- Smooth and soft Raise To approach their target exponentially, so they behave the same at any
-- frame rate; one smoothing step never goes more than half way, so it cannot overshoot.
local MAX_STEP = 0.5
local SMOOTH_RATE = 1.5
local MAX_SMOOTH_RATE = 24
local RAISE_TO_RATE = 2.5
-- A brush smaller than the grid would sit between vertices and do nothing, so it always
-- reaches at least one grid step (three quarters of one with Hard falloff, which still moves
-- only the vertex under the cursor when aimed at one). Below that size the radius still matters:
-- the brush pushes more gently in proportion (see gentleness), so radius 1 and 3 differ.
local MIN_SOFT_STEPS = 1
local MIN_HARD_STEPS = 0.75
-- How much a vertex's offset along its tile's normal counts toward its distance from the
-- brush. Below 1, a vertex rising under a held brush stays inside it, and steep slopes do not
-- stretch the brush's reach.
local AXIAL_SHARE = 0.75

local function approach(rate: number, dt: number): number
	return math.min(1 - math.exp(-rate * dt), MAX_STEP)
end

local function spacingOf(opened: Opened): number
	local c = opened.disp.corners
	return math.max((c[4] - c[1]).Magnitude, (c[2] - c[1]).Magnitude) / (opened.disp.size - 1)
end

-- The radius the brush really affects on `opened`: the brush radius, but never less than the
-- grid allows (see MIN_SOFT_STEPS). The cursor ring shows this.
function Paint.effectiveRadius(opened: Opened, brush: Brush): number
	local soft = brush.effect == "Smooth" or brush.falloff == "Soft"
	return math.max(brush.radius, spacingOf(opened) * (if soft then MIN_SOFT_STEPS else MIN_HARD_STEPS))
end

-- Applies one brush tick along `centers` (world; the points the brush passed this frame, so a
-- fast drag leaves no gaps) to `targets`, and returns the changed vertices per displacement.
-- `dt` is the frame time for the per-second rates.
function Paint.apply(targets: { Opened }, centers: { Vector3 }, brush: Brush, dt: number): { [Opened]: { [number]: true } }
	if #centers == 0 then
		return {}
	end
	-- One gather around the whole path, wide enough for the largest effective radius.
	local first, last = centers[1], centers[#centers]
	local middle = (first + last) / 2
	local halfSpan = (last - first).Magnitude / 2
	local smoothing = brush.effect == "Smooth"
	local maxRadius, maxSpacing = brush.radius, 0
	for _, opened in targets do
		maxSpacing = math.max(maxSpacing, spacingOf(opened))
		maxRadius = math.max(maxRadius, Paint.effectiveRadius(opened, brush))
	end
	-- Smoothing also reads neighbors up to one neighborhood beyond the brush.
	local neighborReach = if smoothing then math.max(maxRadius * SMOOTH_RADIUS_SHARE, maxSpacing * SMOOTH_STEPS) else 0
	local reach = maxRadius + halfSpan + neighborReach
	local items = gather(targets, middle, reach)
	local grid: Grid? = nil
	if smoothing and #items > 0 then
		grid = buildGrid(nearbyPoints(items, middle, reach), math.max(neighborReach, 0.5))
	end

	local smoothRate = math.clamp(brush.strength * SMOOTH_RATE, 0.5, MAX_SMOOTH_RATE)

	-- Compute every move first, so smoothing reads only the pre-tick surface.
	local moves: { Move } = {}
	for _, item in items do
		local disp = item.opened.disp
		local radius = Paint.effectiveRadius(item.opened, brush)
		local r2 = radius * radius
		-- A radius smaller than the grid allows still reaches one grid step, but pushes as much
		-- less as it is smaller.
		local gentleness = math.min(1, brush.radius / radius)
		local worldNormal = item.pivot:VectorToWorldSpace(item.faceNormal)
		for index, p in item.world do
			-- Raise and Lower add up every sample along the path (their effect is additive);
			-- the others use the closest sample.
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
				local target = axis * brush.height - disp.offsets[index] - item.faceNormal * disp.elevation
				if brush.falloff == "Hard" then
					-- Hammer's absolute mode: straight to the height.
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

-- The Raise To height (studs along the brush axis from the flat base face) of the surface at
-- `point` (world) on `opened`, for picking a height from the terrain.
function Paint.heightAt(opened: Opened, point: Vector3, brush: Brush): number
	local pivot = opened.model:GetPivot()
	local disp = opened.disp
	local normal = Displacement.faceNormal(disp)
	local axis = if brush.axis == "Face" or brush.axis == "Subdiv"
		then normal
		else pivot:VectorToObjectSpace(worldAxis(brush.axis, brush.pickedAxis) or Vector3.yAxis)
	local along = axis:Dot(normal)
	if math.abs(along) < 1e-6 then
		return 0
	end
	-- The flat base point under `point` along the axis: base + axis * height = point.
	local offset = pivot:PointToObjectSpace(point) - disp.corners[1]
	return offset:Dot(normal) / along
end

return Paint
