--!strict
--[[
	Raycasts against displacement triangles from saved vertex positions instead of the live
	wedges. The brush uses it during a stroke: it aims at the surface as it was when the stroke
	first reached a tile, then reads the live position at the same spot on the same triangle. So
	holding still while raising builds a centered hill (aiming at the live, rising surface walks
	the hit point toward the camera), and rays never slip through the hairline seams between
	wedges.
]]

local Displacement = require(script.Parent.Displacement)
local TerrainInstance = require(script.Parent.TerrainInstance)

type Opened = TerrainInstance.Opened

export type Snapshot = {
	opened: Opened,
	-- World positions of every vertex when the snapshot was taken.
	world: { Vector3 },
	min: Vector3,
	max: Vector3,
}

export type Hit = {
	snapshot: Snapshot,
	distance: number,
	-- The triangle's vertices and the hit's barycentric weights on it.
	i1: number,
	i2: number,
	i3: number,
	w1: number,
	w2: number,
	w3: number,
	-- The triangle's normal in the snapshot (world), facing the ray.
	normal: Vector3,
}

-- Lets rays exactly on a shared edge hit one of the two triangles.
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

-- Narrows the ray's [near, far] range to one axis slab of a box; nil when it misses.
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

-- Whether the ray (origin, unit direction, length) passes through the box.
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

-- The nearest triangle hit along the ray across `snapshots`, or nil.
function SurfaceRay.cast(origin: Vector3, direction: Vector3, length: number, snapshots: { Snapshot }): Hit?
	local best: Hit? = nil
	local bestDistance = length
	for _, snapshot in snapshots do
		if not hitsBox(origin, direction, bestDistance, snapshot.min - Vector3.one * 0.01, snapshot.max + Vector3.one * 0.01) then
			continue
		end
		local disp = snapshot.opened.disp
		local world = snapshot.world
		for t = 1, Displacement.triangleCount(disp) do
			local i1, i2, i3 = Displacement.triangle(disp, t)
			local p1, p2, p3 = world[i1], world[i2], world[i3]
			-- Moller-Trumbore, two-sided.
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

-- Where a hit's spot on its triangle is now, after the vertices moved (world space).
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
