--!strict
--[[
	Stitching snaps displacement edges onto the edges of normal parts (roads, floors, walls,
	wedge ramps), so terrain meets them without a gap or a step. Hammer only flattens edges that
	already lie exactly on a brush face; Roblox builds rarely line up that well, so this matches
	within a reach instead.

	For each tile edge and each part edge:
	1. The part edge, projected onto the tile's flat plane, must run roughly along the tile edge
	   (within about 31 degrees), and must not stand straight up out of the plane.
	2. Each tile edge vertex maps to the point on the part edge at its flat position, measured in
	   the tile plane. On a wedge ramp that point climbs the ramp instead of pulling the vertex
	   backward. Vertices past either end of the part edge are left alone, so a short part
	   (a doorway, a narrow road) only moves the stretch of edge beside it.
	3. The part edge matches when at least 2 vertices are within reach. With `extend`, the rest
	   of the stretch beside the part follows as long as it stays within reach sideways, at any
	   height, so a tile edge follows a whole ramp once its low end is in reach.
	4. Among edges of one part: the edge on the tile's side wins (the near face of a thin wall),
	   then an edge of a face that looks the same way as the tile (a road's top edge beats its
	   bottom edge when both are in reach, so terrain rises to meet the road surface), then the
	   closest. Across parts, each vertex goes to the closest match.

	Stitched vertices are not sewn afterwards: averaging a snapped corner with an unsnapped
	neighbor would pull it back off the part. Instead `propagate` moves the coincident edge
	vertices of neighboring tiles to the same spot, so the part wins and seams stay closed.
]]

local Displacement = require(script.Parent.Displacement)
local PartFaces = require(script.Parent.PartFaces)
local TerrainInstance = require(script.Parent.TerrainInstance)
local Units = require(script.Parent.Units)

type Opened = TerrainInstance.Opened

export type Changes = { [Opened]: { [number]: true } }
-- World-space targets per displacement vertex.
export type Moves = { [Opened]: { [number]: Vector3 } }

-- One part edge and the outward normals of the two faces that meet along it.
type PartEdge = {
	part: BasePart,
	a: Vector3,
	b: Vector3,
	n1: Vector3,
	n2: Vector3,
}

-- A matched stretch of one tile edge against one part edge.
export type Match = {
	opened: Opened,
	-- Tile edge 1 to 4 (Displacement.edges order).
	edge: number,
	part: BasePart,
	-- The vertices that go to this part edge, in order along the tile edge.
	vertices: { number },
}

export type Result = {
	moves: Moves,
	matches: { Match },
}

type Hit = {
	vertex: number,
	-- Step along the tile edge, for ordering.
	step: number,
	target: Vector3,
	distance: number,
}

type Candidate = {
	part: BasePart,
	edge: number,
	hits: { Hit },
	-- Mean distance of the vertices within reach.
	average: number,
	-- In-plane distance from the tile center to the part edge's line.
	centerDistance: number,
	-- Borders a part face that looks the same way as the tile.
	facing: boolean,
	won: { Hit },
}

-- A part edge must run within about 31 degrees of the tile edge, in the tile plane.
local MIN_PARALLEL = 0.85
-- Part edges shorter than this fraction in the tile plane stand up out of it (a wall's corner
-- against a floor) and are skipped.
local MIN_IN_PLANE = 0.25
-- Lets vertices exactly at a part edge's ends match despite rounding.
local END_MARGIN = 0.05
-- How much closer to the tile center one edge must be to count as the near side.
local NEAR_SIDE_MARGIN = 0.05
local FACING_DOT = 0.3
-- Targets closer than this to the current position are not written.
local SAME = 1e-4
-- Neighbor vertices at the same flat spot; Sew's tolerance (1 Hammer unit per axis).
local TOLERANCE = Units.studs(1)
local MAX_INTERPOLATED_RUN = 3

local Stitch = {}

-- The edges of a block Part (12) or a wedge (9), in world space.
local function partEdges(part: BasePart): { PartEdge }
	local h = part.Size / 2
	local cf = part.CFrame
	local function p(x: number, y: number, z: number): Vector3
		return cf * Vector3.new(x * h.X, y * h.Y, z * h.Z)
	end
	local function n(x: number, y: number, z: number): Vector3
		return cf:VectorToWorldSpace(Vector3.new(x, y, z))
	end
	local edges: { PartEdge } = {}
	local function add(a: Vector3, b: Vector3, n1: Vector3, n2: Vector3)
		table.insert(edges, { part = part, a = a, b = b, n1 = n1, n2 = n2 })
	end
	if PartFaces.isWedge(part) then
		-- The slope rises from the bottom front edge to the top back edge.
		local slope = cf:VectorToWorldSpace(Vector3.new(0, part.Size.Z, -part.Size.Y).Unit)
		local bottom, back = n(0, -1, 0), n(0, 0, 1)
		for _, x in { -1, 1 } do
			local side = n(x, 0, 0)
			add(p(x, -1, -1), p(x, -1, 1), bottom, side)
			add(p(x, -1, 1), p(x, 1, 1), back, side)
			add(p(x, -1, -1), p(x, 1, 1), slope, side)
		end
		add(p(-1, -1, -1), p(1, -1, -1), bottom, slope)
		add(p(-1, -1, 1), p(1, -1, 1), bottom, back)
		add(p(-1, 1, 1), p(1, 1, 1), back, slope)
	else
		for _, a in { -1, 1 } do
			for _, b in { -1, 1 } do
				add(p(-1, a, b), p(1, a, b), n(0, a, 0), n(0, 0, b))
				add(p(a, -1, b), p(a, 1, b), n(a, 0, 0), n(0, 0, b))
				add(p(a, b, -1), p(a, b, 1), n(a, 0, 0), n(0, b, 0))
			end
		end
	end
	return edges
end

-- Parts that stitching can use: block Parts and wedges.
function Stitch.isStitchable(inst: Instance): boolean
	return PartFaces.isEligible(inst)
end

type Tile = {
	opened: Opened,
	pivot: CFrame,
	-- Face normal in model space (for Displacement.position) and in world space.
	localNormal: Vector3,
	normal: Vector3,
	center: Vector3,
	flat: { [number]: Vector3 },
	current: { [number]: Vector3 },
}

local function buildTile(opened: Opened): Tile
	local pivot = opened.model:GetPivot()
	local localNormal = Displacement.faceNormal(opened.disp)
	local center = Vector3.zero
	for _, corner in opened.disp.corners do
		center += corner
	end
	return {
		opened = opened,
		pivot = pivot,
		localNormal = localNormal,
		normal = pivot:VectorToWorldSpace(localNormal),
		center = pivot * (center / 4),
		flat = {},
		current = {},
	}
end

local function flatOf(tile: Tile, v: number): Vector3
	local point = tile.flat[v]
	if not point then
		point = tile.pivot * Displacement.flatPosition(tile.opened.disp, v)
		tile.flat[v] = point
	end
	return point
end

local function currentOf(tile: Tile, v: number): Vector3
	local point = tile.current[v]
	if not point then
		point = tile.pivot * Displacement.position(tile.opened.disp, v, tile.localNormal)
		tile.current[v] = point
	end
	return point
end

local function inPlane(vector: Vector3, normal: Vector3): Vector3
	return vector - normal * vector:Dot(normal)
end

-- Matches one tile edge against one part edge (steps 1 to 3 of the module comment).
local function tryEdge(
	tile: Tile,
	edgeIndex: number,
	indices: { number },
	direction: Vector3,
	partEdge: PartEdge,
	reach: number,
	extend: boolean
): Candidate?
	local normal = tile.normal
	local ab = partEdge.b - partEdge.a
	local abPlane = inPlane(ab, normal)
	local planeLength = abPlane.Magnitude
	if planeLength < 1e-6 or planeLength < MIN_IN_PLANE * ab.Magnitude then
		return nil
	end
	if math.abs(direction:Dot(abPlane / planeLength)) < MIN_PARALLEL then
		return nil
	end

	local margin = END_MARGIN / planeLength
	local inReach: { Hit } = {}
	local sideways: { Hit } = {}
	for step, v in indices do
		local t = (flatOf(tile, v) - partEdge.a):Dot(abPlane) / (planeLength * planeLength)
		if t < -margin or t > 1 + margin then
			continue
		end
		local target = partEdge.a + ab * math.clamp(t, 0, 1)
		local offset = currentOf(tile, v) - target
		local hit = { vertex = v, step = step, target = target, distance = offset.Magnitude }
		if hit.distance <= reach then
			table.insert(inReach, hit)
		elseif extend and inPlane(offset, normal).Magnitude <= reach then
			table.insert(sideways, hit)
		end
	end
	if #inReach < 2 then
		return nil
	end

	local total = 0
	for _, hit in inReach do
		total += hit.distance
	end
	-- Sideways distance from the tile center to the part edge's line. Measured to the line, not
	-- to the matched stretch, so a ramp's slope edge (only partly in reach) and its bottom edge
	-- tie here and the facing rule decides.
	local axis = abPlane / planeLength
	local toCenter = inPlane(tile.center - partEdge.a, normal)
	local hits = inReach
	if #sideways > 0 then
		hits = table.clone(inReach)
		table.move(sideways, 1, #sideways, #hits + 1, hits)
	end
	return {
		part = partEdge.part,
		edge = edgeIndex,
		hits = hits,
		average = total / #inReach,
		centerDistance = (toCenter - axis * toCenter:Dot(axis)).Magnitude,
		facing = math.max(partEdge.n1:Dot(normal), partEdge.n2:Dot(normal)) > FACING_DOT,
		won = {},
	}
end

-- Step 4 of the module comment, between two edges of the same part.
local function better(a: Candidate, b: Candidate): boolean
	if a.centerDistance + NEAR_SIDE_MARGIN < b.centerDistance then
		return true
	elseif b.centerDistance + NEAR_SIDE_MARGIN < a.centerDistance then
		return false
	end
	if a.facing ~= b.facing then
		return a.facing
	end
	if math.abs(a.average - b.average) > 1e-6 then
		return a.average < b.average
	end
	return #a.hits > #b.hits
end

--[[
	Finds where the edges of `tiles` snap onto edges of `parts` within `reach` studs (see the
	module comment). Nothing is written; pass the moves to `propagate` and `write`.
]]
function Stitch.match(tiles: { Opened }, parts: { BasePart }, reach: number, extend: boolean): Result
	local edges: { PartEdge } = {}
	for _, part in parts do
		if Stitch.isStitchable(part) then
			local list = partEdges(part)
			table.move(list, 1, #list, #edges + 1, edges)
		end
	end

	local result: Result = { moves = {}, matches = {} }
	if #edges == 0 then
		return result
	end

	for _, opened in tiles do
		local tile = buildTile(opened)
		local candidates: { Candidate } = {}
		for edgeIndex, edge in Displacement.edges(opened.disp) do
			local indices = edge.indices
			local direction = flatOf(tile, indices[#indices]) - flatOf(tile, indices[1])
			if direction.Magnitude < 1e-6 then
				continue
			end
			direction = direction.Unit
			-- The best edge per part along this tile edge.
			local perPart: { [BasePart]: Candidate } = {}
			for _, partEdge in edges do
				local candidate = tryEdge(tile, edgeIndex, indices, direction, partEdge, reach, extend)
				if candidate then
					local current = perPart[partEdge.part]
					if not current or better(candidate, current) then
						perPart[partEdge.part] = candidate
					end
				end
			end
			for _, candidate in perPart do
				table.insert(candidates, candidate)
			end
		end

		-- Each vertex (corners sit on two tile edges) goes to its closest candidate.
		local best: { [number]: { hit: Hit, candidate: Candidate } } = {}
		for _, candidate in candidates do
			for _, hit in candidate.hits do
				local current = best[hit.vertex]
				if not current or hit.distance < current.hit.distance then
					best[hit.vertex] = { hit = hit, candidate = candidate }
				end
			end
		end
		if next(best) == nil then
			continue
		end
		local moves: { [number]: Vector3 } = {}
		for v, entry in best do
			moves[v] = entry.hit.target
			table.insert(entry.candidate.won, entry.hit)
		end
		result.moves[opened] = moves
		for _, candidate in candidates do
			if #candidate.won > 0 then
				table.sort(candidate.won, function(x: Hit, y: Hit)
					return x.step < y.step
				end)
				local vertices = table.create(#candidate.won)
				for i, hit in candidate.won do
					vertices[i] = hit.vertex
				end
				table.insert(result.matches, {
					opened = opened,
					edge = candidate.edge,
					part = candidate.part,
					vertices = vertices,
				})
			end
		end
	end
	return result
end

local function samePoint(a: Vector3, b: Vector3): boolean
	return math.abs(a.X - b.X) <= TOLERANCE and math.abs(a.Y - b.Y) <= TOLERANCE and math.abs(a.Z - b.Z) <= TOLERANCE
end

local function flatBounds(tile: Tile): (Vector3, Vector3)
	local min, max = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, corner in tile.opened.disp.corners do
		local point = tile.pivot * corner
		min = min:Min(point)
		max = max:Max(point)
	end
	return min, max
end

--[[
	Returns `moves` plus the edge vertices of `neighbors` that sit at the same flat spot as a
	moved vertex, sent to the same target. Where a denser neighbor has vertices in between (a
	2:1 edge), those are placed along the line between the moved ones. `moves` is not changed.
]]
function Stitch.propagate(moves: Moves, neighbors: { Opened }): Moves
	type Point = { flat: Vector3, target: Vector3 }
	local points: { Point } = {}
	local min, max = Vector3.one * math.huge, -Vector3.one * math.huge
	local result: Moves = {}
	for opened, targets in moves do
		result[opened] = table.clone(targets)
		local tile = buildTile(opened)
		for v, target in targets do
			local flat = flatOf(tile, v)
			table.insert(points, { flat = flat, target = target })
			min = min:Min(flat)
			max = max:Max(flat)
		end
	end
	if #points == 0 then
		return result
	end
	local pad = Vector3.one * TOLERANCE
	min -= pad
	max += pad

	for _, opened in neighbors do
		local tile = buildTile(opened)
		local tileMin, tileMax = flatBounds(tile)
		if tileMin.X > max.X or tileMin.Y > max.Y or tileMin.Z > max.Z then
			continue
		end
		if tileMax.X < min.X or tileMax.Y < min.Y or tileMax.Z < min.Z then
			continue
		end
		local own = moves[opened]
		local added: { [number]: Vector3 } = {}
		local any = false
		for _, edge in Displacement.edges(opened.disp) do
			local indices = edge.indices
			local placed: { [number]: Vector3 } = {}
			for step, v in indices do
				if own and own[v] then
					continue
				end
				local flat = flatOf(tile, v)
				for _, point in points do
					if samePoint(flat, point.flat) then
						placed[step] = point.target
						added[v] = point.target
						any = true
						break
					end
				end
			end
			-- Fill short runs between two placed vertices (the in-between vertices of a denser
			-- neighbor along a 2:1 edge).
			local last: number? = nil
			for step = 1, #indices do
				if placed[step] then
					local from = last
					if from and step - from > 1 and step - from - 1 <= MAX_INTERPOLATED_RUN then
						local a, b = placed[from], placed[step]
						for k = from + 1, step - 1 do
							local v = indices[k]
							if not (own and own[v]) and not added[v] then
								added[v] = a:Lerp(b, (k - from) / (step - from))
							end
						end
					end
					last = step
				end
			end
		end
		if any then
			local targets = result[opened] or {}
			for v, target in added do
				targets[v] = target
			end
			result[opened] = targets
		end
	end
	return result
end

-- Writes the targets that differ from the current positions. Returns the changed vertices;
-- wedges and attributes are left to the caller.
function Stitch.write(moves: Moves): Changes
	local changes: Changes = {}
	for opened, targets in moves do
		local tile = buildTile(opened)
		local changed: { [number]: true } = {}
		for v, target in targets do
			if (currentOf(tile, v) - target).Magnitude > SAME then
				Displacement.setPosition(opened.disp, v, tile.pivot:PointToObjectSpace(target), tile.localNormal)
				changed[v] = true
			end
		end
		if next(changed) ~= nil then
			changes[opened] = changed
		end
	end
	return changes
end

-- How far each target is from its vertex now, for previews.
function Stitch.distances(moves: Moves): { [Opened]: { [number]: number } }
	local result = {}
	for opened, targets in moves do
		local tile = buildTile(opened)
		local distances: { [number]: number } = {}
		for v, target in targets do
			distances[v] = (currentOf(tile, v) - target).Magnitude
		end
		result[opened] = distances
	end
	return result
end

-- The current world position of a displacement vertex.
function Stitch.vertexPosition(opened: Opened, v: number): Vector3
	return currentOf(buildTile(opened), v)
end

return Stitch
