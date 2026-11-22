--!strict
--[[
	Finding the points of a tile that can go while its surface keeps its shape: used by the Mesh
	tool's Auto-simplify (which marks them for review) and by baking (which leaves them out of the
	union only, so the editable tile keeps full detail).
]]

local Displacement = require(script.Parent.Displacement)
local Mesh = require(script.Parent.Mesh)

-- Candidates tried between yields, so Studio stays responsive on big tiles.
local CANDIDATES_PER_YIELD = 20
-- A max angle of 0 still allows rounding noise on flat ground.
local MIN_ANGLE = 0.1

local Simplify = {}

-- Points that must stay so painted borders and hole outlines keep their shape: every point
-- where grid triangles with different looks meet.
local function pinnedPoints(disp: Displacement.Displacement): { [number]: true }
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

-- A triangle's vertices as a string in sorted order, to tell whether a triangulation already had
-- that triangle.
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

-- The triangles a tile shows now, by key: its points removed by hand already made them, so a
-- search for more points to remove must not judge them.
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

-- The unit normal of triangle abc, on the side of `up`.
local function normalOf(a: Vector3, b: Vector3, c: Vector3, up: Vector3): Vector3?
	local cross = (b - a):Cross(c - a)
	if cross.Magnitude < 1e-9 then
		return nil
	end
	local n = cross.Unit
	return if n:Dot(up) < 0 then -n else n
end

--[[
	The points of one tile that can be removed while every shown triangle stays within
	`maxAngle` degrees of the full-detail triangles under it (compared with each original grid
	triangle, not with its neighbors, so a gentle curve is never flattened step by step).
	Flattest points are tried first. Points already removed stay removed. Yields.
]]
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

	local pinned = pinnedPoints(disp)
	type Candidate = { v: number, bend: number }
	local candidates: { Candidate } = {}
	for v = 1, size * size do
		if disp.removed[v] or pinned[v] or Displacement.isCorner(disp, v) then
			continue
		end
		-- How much the grid bends at this point: the widest angle between its triangles.
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
	table.sort(candidates, function(x: Candidate, y: Candidate)
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
	-- Triangles of the current result, by sorted vertex triple. Only triangles a removal creates
	-- are checked, so a big triangle that was already there (from earlier, manual removals)
	-- never blocks every other point.
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

-- How many times the quick pass puts points back before giving up on a tile.
local MAX_REPAIR_PASSES = 24
-- Tile edge points may leave the straight edge by at most this much (studs): far below what
-- shows, even where a denser neighbor keeps the coincident point (a 2:1 T-junction).
local EDGE_TOLERANCE = 0.005

export type BakeShape = {
	-- Degrees a new triangle may bend from the grid triangles under it (0 = no angle test).
	angle: number,
	-- Studs the shown surface may leave the original points (0 = no height test).
	tolerance: number,
	-- Also drop tile edge points that lie on a straight line.
	edges: boolean,
}

-- Distance from `p` to the segment ab.
local function distanceToSegment(p: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local length2 = ab:Dot(ab)
	local t = if length2 > 0 then math.clamp((p - a):Dot(ab) / length2, 0, 1) else 0
	return (p - (a + ab * t)).Magnitude
end

-- Ramer-Douglas-Peucker along one run of edge points: marks the points between `first` and
-- `last` (indices into `run`) that can go while the polyline stays within EDGE_TOLERANCE.
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

--[[
	A quick version of `flatPoints` for baking, where the result is not reviewed and speed
	matters. Every interior point whose own triangles agree within `shape.angle`, or that sits
	within `shape.tolerance` of the plane through its four neighbors, is taken out at once; with
	`shape.edges`, so is every tile edge point on a straight stretch (within EDGE_TOLERANCE, so
	seams cannot visibly crack). Then, while a new triangle fails both tests (it bends past the
	angle from a grid triangle under it, and an original point under it is farther than the
	tolerance from it), the taken-out point under it that strays farthest comes back. All checks
	use the original surface, so small allowances never add up. A few triangulations per tile
	instead of one per point. Painted borders and hole outlines always stay. Triangles the tile
	already shows (from points removed by hand) are not judged, like in `flatPoints`.

	Also returns the triangulation it ended on (with the tile's removed points and the result
	removed), so a caller can reuse it; nil when the result is empty.
]]
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
	-- How far an original point may sit from a shown triangle that failed the angle test (or
	-- with the angle test off). Straight edges may stray as far as EDGE_TOLERANCE.
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

	local pinned = pinnedPoints(disp)
	local border: { [number]: true } = {}
	for _, edge in Displacement.edges(disp) do
		for _, v in edge.indices do
			border[v] = true
		end
	end

	-- Interior points that are flat by angle or by height.
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

	-- Edge points on straight stretches. Runs end at the corners and at pinned points, so both
	-- always stay; points the user already removed are not part of the shown edge.
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
			-- The angle test failed (or is off): the height test decides, over every original
			-- point of the grid triangles under this one.
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
				-- Fall back to the taken-out point nearest this triangle's center.
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
	-- Did not settle: leave the tile as it is rather than risk a visible change.
	return {}, nil
end
return Simplify
