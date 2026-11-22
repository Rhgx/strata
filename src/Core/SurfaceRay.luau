--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Raycasts against displacement triangles using snapshotted vertex positions rather than live
	wedges. Brushes snapshot each tile when a stroke first reaches it, cast against the snapshot,
	and resolve the hit back onto the live surface via barycentric coordinates. This keeps a
	stationary Raise brush centered on its hill (aiming at live rising wedges walks the hit point
	toward the camera) and prevents rays from slipping through hairline wedge seams.
]]

local Core = script.Parent

local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

type Opened = TerrainInstance.Opened

export type Snapshot = {
	opened: Opened,
	-- World-space vertex positions captured when the snapshot was created.
	world: { Vector3 },
	min: Vector3,
	max: Vector3,
}

export type Hit = {
	snapshot: Snapshot,
	distance: number,
	-- Shown triangle index (Displacement.triangle numbering).
	triangle: number,
	-- Triangle vertex indices and barycentric weights of the intersection point.
	i1: number,
	i2: number,
	i3: number,
	w1: number,
	w2: number,
	w3: number,
	-- Snapshot triangle unit normal in world space, oriented toward the ray origin.
	normal: Vector3,
}

-- Small negative barycentric margin so rays on a shared edge hit one of the two triangles.
local EDGE_EPSILON = -1e-4

local SurfaceRay = {}

function SurfaceRay.snapshot(opened: Opened): Snapshot
	local pivot = opened.model:GetPivot()
	local positions = Displacement.positions(opened.disp)
	local world = table.create(#positions)
	local min, max = Vector3.one * math.huge, -Vector3.one * math.huge

	for i, position in positions do
		local point = pivot * position
		world[i] = point
		min = min:Min(point)
		max = max:Max(point)
	end

	return { opened = opened, world = world, min = min, max = max }
end

-- Clips ray interval [near, far] against one axis slab [lo, hi]; returns nil when disjoint.
local function clipSlab(o: number, d: number, lo: number, hi: number, near: number, far: number): (number?, number)
	if math.abs(d) < 1e-9 then
		if o < lo or o > hi then
			return nil, far
		end

		return near, far
	end

	local t1, t2 = (lo - o) / d, (hi - o) / d

	if t1 > t2 then
		t1, t2 = t2, t1
	end

	near, far = math.max(near, t1), math.min(far, t2)

	if near > far then
		return nil, far
	end

	return near, far
end

local function hitsBox(origin: Vector3, direction: Vector3, length: number, min: Vector3, max: Vector3): boolean
	local near, far = clipSlab(origin.X, direction.X, min.X, max.X, 0, length)

	if not near then
		return false
	end

	near, far = clipSlab(origin.Y, direction.Y, min.Y, max.Y, near, far)

	if not near then
		return false
	end

	near, far = clipSlab(origin.Z, direction.Z, min.Z, max.Z, near, far)

	return near ~= nil
end

-- Fast AABB check against the tile's cached bounds before taking a full vertex snapshot.
function SurfaceRay.mayHit(opened: Opened, origin: Vector3, direction: Vector3, length: number): boolean
	local pivot = opened.model:GetPivot()
	local pad = Vector3.one * 0.5

	return hitsBox(
		pivot:PointToObjectSpace(origin),
		pivot:VectorToObjectSpace(direction),
		length,
		opened.boundsMin - pad,
		opened.boundsMax + pad
	)
end

-- Returns the nearest triangle hit along the ray across `snapshots`, or nil. Skips deleted
-- triangles unless `includeHoles` is true (used when restoring holes).
function SurfaceRay.cast(
	origin: Vector3,
	direction: Vector3,
	length: number,
	snapshots: { Snapshot },
	includeHoles: boolean?
): Hit?
	local best: Hit? = nil
	local bestDistance = length

	for _, snapshot in snapshots do
		if not hitsBox(origin, direction, bestDistance, snapshot.min - Vector3.one * 0.01, snapshot.max + Vector3.one * 0.01) then
			continue
		end

		local disp = snapshot.opened.disp
		local world = snapshot.world

		for t = 1, Displacement.triangleCount(disp) do
			-- `t` indexes shown triangles, which differ from grid triangles when points are removed.
			if not includeHoles and Displacement.isHole(disp, t) then
				continue
			end

			local i1, i2, i3 = Displacement.triangle(disp, t)
			local p1, p2, p3 = world[i1], world[i2], world[i3]
			-- Two-sided Moller-Trumbore intersection.
			local e1, e2 = p2 - p1, p3 - p1
			local pvec = direction:Cross(e2)
			local det = e1:Dot(pvec)

			if math.abs(det) < 1e-12 then
				continue
			end

			local inverse = 1 / det
			local tvec = origin - p1
			local u = tvec:Dot(pvec) * inverse

			if u < EDGE_EPSILON or u > 1 - EDGE_EPSILON then
				continue
			end

			local qvec = tvec:Cross(e1)
			local v = direction:Dot(qvec) * inverse

			if v < EDGE_EPSILON or u + v > 1 - EDGE_EPSILON then
				continue
			end

			local distance = e2:Dot(qvec) * inverse

			if distance > 0 and distance < bestDistance then
				bestDistance = distance

				local normal = e1:Cross(e2).Unit

				if normal:Dot(direction) > 0 then
					normal = -normal
				end

				best = {
					snapshot = snapshot,
					distance = distance,
					triangle = t,
					i1 = i1,
					i2 = i2,
					i3 = i3,
					w1 = 1 - u - v,
					w2 = u,
					w3 = v,
					normal = normal,
				}
			end
		end
	end

	return best
end

-- Evaluates the current world-space position of `hit` after its vertices have moved.
function SurfaceRay.livePoint(hit: Hit): Vector3
	local opened = hit.snapshot.opened
	local pivot = opened.model:GetPivot()
	local disp = opened.disp
	local normal = Displacement.faceNormal(disp)
	local p1 = Displacement.position(disp, hit.i1, normal)
	local p2 = Displacement.position(disp, hit.i2, normal)
	local p3 = Displacement.position(disp, hit.i3, normal)

	return pivot * (p1 * hit.w1 + p2 * hit.w2 + p3 * hit.w3)
end

return SurfaceRay
