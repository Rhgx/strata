--!strict
--[[
	Identifies displacement vertices that can be removed without distorting the surface beyond a
	configured tolerance. Used by both Auto-simplify (which stages vertices for user review) and
	baking (which simplifies the baked union only, keeping full detail on the editable tile).
]]

local Core = script.Parent

local Mesh = require(Core.Mesh)
local Displacement = require(Core.Displacement)

-- Candidates tested between yields so Studio stays responsive on dense tiles.
local CANDIDATES_PER_YIELD = 20
-- Floor on maxAngle so 0 degrees still absorbs floating-point noise on flat ground.
local MIN_ANGLE = 0.1
-- Maximum repair iterations before aborting fast bake simplification on a tile.
local MAX_REPAIR_PASSES = 24
-- Maximum deviation (in studs) allowed when dropping collinear edge points during baking:
-- small enough to prevent visible cracks even at 2:1 T-junctions.
local EDGE_TOLERANCE = 0.005

export type BakeShape = {
	-- Maximum angle in degrees between a new triangle and underlying grid triangles (0 = off).
	angle: number,
	-- Maximum distance in studs between the simplified surface and original vertices (0 = off).
	tolerance: number,
	-- Drop tile edge vertices lying on straight stretches within EDGE_TOLERANCE.
	edges: boolean,
}

local Simplify = {}

-- Returns vertices bordering grid triangles with differing looks (or holes) so painted material
-- boundaries and hole outlines keep their exact shapes.
function Simplify.pinnedPoints(disp: Displacement.Displacement): { [number]: true }
	local lookAt: { [number]: number } = {}
	local pinned: { [number]: true } = {}

	for g = 1, Displacement.gridTriangleCount(disp) do
		local look = disp.triLooks[g]

		for _, v in { Displacement.gridTriangle(disp, g) } do
			local seen = lookAt[v]

			if seen == nil then
				lookAt[v] = look
			elseif seen ~= look then
				pinned[v] = true
			end
		end
	end

	return pinned
end

-- Canonical sorted key for a triangle's vertex triple to detect already-existing triangles.
local function triangleKey(tri: { number }): string
	local a, b, c = tri[1], tri[2], tri[3]

	if a > b then
		a, b = b, a
	end

	if b > c then
		b, c = c, b
	end

	if a > b then
		a, b = b, a
	end

	return `{a},{b},{c}`
end

-- Keys of triangles currently displayed on `disp` so triangles created by prior manual removals
-- are not re-evaluated when searching for additional removable points.
local function shownTriangles(disp: Displacement.Displacement): { [string]: true }
	local keys: { [string]: true } = {}
	local start = Displacement.mesh(disp)

	if start then
		for _, tri in start.triangles do
			keys[triangleKey(tri)] = true
		end
	else
		for g = 1, Displacement.gridTriangleCount(disp) do
			keys[triangleKey({ Displacement.gridTriangle(disp, g) })] = true
		end
	end

	return keys
end

-- Unit normal of triangle abc oriented toward `up`, or nil for degenerate triangles.
local function normalOf(a: Vector3, b: Vector3, c: Vector3, up: Vector3): Vector3?
	local cross = (b - a):Cross(c - a)

	if cross.Magnitude < 1e-9 then
		return nil
	end

	local n = cross.Unit

	return if n:Dot(up) < 0 then -n else n
end

-- Greedily finds vertices removable while keeping every newly formed triangle within `maxAngle`
-- degrees of all underlying original grid triangles (comparing against the full-detail grid
-- prevents gradual drift on gentle curves). Tests flattest vertices first, preserves existing
-- removals, and yields periodically.
function Simplify.flatPoints(disp: Displacement.Displacement, maxAngle: number): { [number]: true }
	local up = Displacement.faceNormal(disp)
	Displacement.reproject(disp, up)

	local positions = Displacement.positions(disp, up)
	local size = disp.size
	local cosLimit = math.cos(math.rad(math.max(maxAngle, MIN_ANGLE)))

	local gridNormals: { [number]: Vector3 } = {}
	local touching: { [number]: { number } } = {}

	for g = 1, Displacement.gridTriangleCount(disp) do
		local a, b, c = Displacement.gridTriangle(disp, g)
		local n = normalOf(positions[a], positions[b], positions[c], up)

		if n then
			gridNormals[g] = n
		end

		for _, v in { a, b, c } do
			local list = touching[v]

			if list then
				table.insert(list, g)
			else
				touching[v] = { g }
			end
		end
	end

	local pinned = Simplify.pinnedPoints(disp)
	type Candidate = { v: number, bend: number }
	local candidates: { Candidate } = {}

	for v = 1, size * size do
		if disp.removed[v] or pinned[v] or Displacement.isCorner(disp, v) then
			continue
		end

		-- Measure local curvature by the widest dihedral angle among incident grid triangles.
		local lowest = 1
		local list = touching[v] or {}

		for i = 1, #list do
			local ni = gridNormals[list[i]]

			for j = i + 1, #list do
				local nj = gridNormals[list[j]]

				if ni and nj then
					lowest = math.min(lowest, ni:Dot(nj))
				end
			end
		end

		table.insert(candidates, { v = v, bend = -lowest })
	end

	table.sort(candidates, function (x: Candidate, y: Candidate)
		if x.bend ~= y.bend then
			return x.bend < y.bend
		end

		return x.v < y.v
	end)

	local c = disp.corners
	local n = size - 1
	local rowStep, colStep = (c[2] - c[1]).Magnitude / n, (c[4] - c[1]).Magnitude / n
	local removed = table.clone(disp.removed)
	local result: { [number]: true } = {}
	-- Track existing triangles so only newly introduced triangles are checked after each candidate
	-- removal, preventing pre-existing manual simplifications from blocking unrelated vertices.
	local key = triangleKey
	local existing = shownTriangles(disp)

	for i, candidate in candidates do
		removed[candidate.v] = true

		local mesh = Mesh.build(size, removed, rowStep, colStep)
		local fits = true

		for t, tri in mesh.triangles do
			if existing[key(tri)] then
				continue
			end

			local shown = normalOf(positions[tri[1]], positions[tri[2]], positions[tri[3]], up)

			if not shown then
				continue
			end

			for _, g in mesh.cover[t] do
				local original = gridNormals[g]

				if original and original:Dot(shown) < cosLimit then
					fits = false
					break
				end
			end

			if not fits then
				break
			end
		end

		if fits then
			result[candidate.v] = true
			table.clear(existing)

			for _, tri in mesh.triangles do
				existing[key(tri)] = true
			end
		else
			removed[candidate.v] = nil
		end

		if i % CANDIDATES_PER_YIELD == 0 then
			task.wait()
		end
	end

	return result
end

local function distanceToSegment(p: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local length2 = ab:Dot(ab)
	local t = if length2 > 0 then math.clamp((p - a):Dot(ab) / length2, 0, 1) else 0

	return (p - (a + ab * t)).Magnitude
end

-- Ramer-Douglas-Peucker simplification along an edge vertex run: adds interior vertices between
-- `first` and `last` to `out` when the polyline stays within EDGE_TOLERANCE.
local function simplifyRun(run: { number }, positions: { Vector3 }, first: number, last: number, out: { [number]: true })
	if last - first < 2 then
		return
	end

	local a, b = positions[run[first]], positions[run[last]]
	local worst, worstIndex = 0, first

	for i = first + 1, last - 1 do
		local d = distanceToSegment(positions[run[i]], a, b)

		if d > worst then
			worst, worstIndex = d, i
		end
	end

	if worst <= EDGE_TOLERANCE then
		for i = first + 1, last - 1 do
			out[run[i]] = true
		end

		return
	end

	simplifyRun(run, positions, first, worstIndex, out)
	simplifyRun(run, positions, worstIndex, last, out)
end

-- Batch simplification used during baking where speed matters: removes all locally flat interior
-- vertices (by `shape.angle` or `shape.tolerance`) and optionally straight edge vertices (within
-- EDGE_TOLERANCE) in one step, then iteratively restores the farthest-deviating vertex under any
-- newly formed triangle that fails both angle and height checks against the original surface.
-- Preserves painted borders, hole outlines, and pre-existing manual triangles. Returns the extra
-- removed vertices and the resulting Mesh (nil when nothing was removed).
function Simplify.flatPointsQuick(disp: Displacement.Displacement, shape: BakeShape): ({ [number]: true }, Mesh.Mesh?)
	local result: { [number]: true } = {}

	if shape.angle <= 0 and shape.tolerance <= 0 and not shape.edges then
		return result, nil
	end

	local up = Displacement.faceNormal(disp)
	Displacement.reproject(disp, up)

	local positions = Displacement.positions(disp, up)
	local size = disp.size
	local useAngle = shape.angle > 0
	local cosLimit = math.cos(math.rad(math.max(shape.angle, MIN_ANGLE)))
	local tolerance = shape.tolerance
	-- Maximum height error allowed for a triangle that failed the angle test (or when angle test is off).
	local allowance = math.max(tolerance, if shape.edges then EDGE_TOLERANCE else 1e-6)

	local gridNormals: { [number]: Vector3 } = {}
	local touching: { [number]: { number } } = {}

	for g = 1, Displacement.gridTriangleCount(disp) do
		local a, b, c = Displacement.gridTriangle(disp, g)
		local n = normalOf(positions[a], positions[b], positions[c], up)

		if n then
			gridNormals[g] = n
		end

		for _, v in { a, b, c } do
			local list = touching[v]

			if list then
				table.insert(list, g)
			else
				touching[v] = { g }
			end
		end
	end

	local pinned = Simplify.pinnedPoints(disp)
	local border: { [number]: true } = {}

	for _, edge in Displacement.edges(disp) do
		for _, v in edge.indices do
			border[v] = true
		end
	end

	-- Remove interior vertices that pass either the local dihedral angle or neighbor-plane height test.
	local removed = table.clone(disp.removed)

	for v = 1, size * size do
		if removed[v] or pinned[v] or border[v] then
			continue
		end

		local flat = false

		if useAngle then
			flat = true

			local list = touching[v] or {}

			for i = 1, #list do
				local ni = gridNormals[list[i]]

				for j = i + 1, #list do
					local nj = gridNormals[list[j]]

					if not (ni and nj) or ni:Dot(nj) < cosLimit then
						flat = false
						break
					end
				end

				if not flat then
					break
				end
			end
		end

		if not flat and tolerance > 0 then
			local row, col = (v - 1) // size, (v - 1) % size
			local north, south = positions[(row - 1) * size + col + 1], positions[(row + 1) * size + col + 1]
			local west, east = positions[row * size + col], positions[row * size + col + 2]
			local planeNormal = (east - west):Cross(south - north)

			if planeNormal.Magnitude > 1e-9 then
				local middle = (north + south + east + west) / 4
				flat = math.abs((positions[v] - middle):Dot(planeNormal.Unit)) <= tolerance
			end
		end

		if flat then
			result[v] = true
			removed[v] = true
		end
	end

	-- Remove collinear edge points; runs terminate at corners and pinned points so both stay fixed.
	if shape.edges then
		for _, edge in Displacement.edges(disp) do
			local run: { number } = {}

			for _, v in edge.indices do
				if not disp.removed[v] then
					table.insert(run, v)
				end
			end

			local runStart = 1

			for i = 2, #run do
				if i == #run or pinned[run[i]] then
					local out: { [number]: true } = {}
					simplifyRun(run, positions, runStart, i, out)

					for v in out do
						result[v] = true
						removed[v] = true
					end

					runStart = i
				end
			end
		end
	end

	if next(result) == nil then
		return result, nil
	end

	local c = disp.corners
	local n = size - 1
	local rowStep, colStep = (c[2] - c[1]).Magnitude / n, (c[4] - c[1]).Magnitude / n
	local existing = shownTriangles(disp)

	for _ = 1, MAX_REPAIR_PASSES do
		local mesh = Mesh.build(size, removed, rowStep, colStep)
		local restore: { [number]: true } = {}

		for t, tri in mesh.triangles do
			if existing[triangleKey(tri)] then
				continue
			end

			local a, b, c3 = positions[tri[1]], positions[tri[2]], positions[tri[3]]
			local shown = normalOf(a, b, c3, up)

			if not shown then
				continue
			end

			local bendsTooFar = not useAngle

			if useAngle then
				for _, g in mesh.cover[t] do
					local original = gridNormals[g]

					if original and original:Dot(shown) < cosLimit then
						bendsTooFar = true
						break
					end
				end
			end

			if not bendsTooFar then
				continue
			end

			-- Angle test failed (or disabled): check height deviation of every underlying grid vertex.
			local worst, worstRemoved, worstPoint = 0, -1, nil

			for _, g in mesh.cover[t] do
				for _, v in { Displacement.gridTriangle(disp, g) } do
					local d = math.abs((positions[v] - a):Dot(shown))
					worst = math.max(worst, d)

					if result[v] and not restore[v] and d > worstRemoved then
						worstRemoved, worstPoint = d, v
					end
				end
			end

			if worst <= allowance then
				continue
			end

			if not worstPoint then
				-- Fall back to the removed vertex closest to this triangle's centroid.
				local center = (a + b + c3) / 3
				local bestDistance = math.huge

				for v in result do
					if not restore[v] then
						local distance = (positions[v] - center).Magnitude

						if distance < bestDistance then
							worstPoint, bestDistance = v, distance
						end
					end
				end
			end

			if worstPoint then
				restore[worstPoint] = true
			end
		end

		if next(restore) == nil then
			return result, mesh
		end

		for v in restore do
			result[v] = nil
			removed[v] = nil
		end

		if next(result) == nil then
			return result, nil
		end
	end

	-- Abort rather than risk visible artifacts if the repair loop did not converge.
	return {}, nil
end

return Simplify
