--!strict
--[[
	Stitching snaps displacement edges onto the edges of normal parts (roads, floors, walls,
	wedge ramps, flat "triangle terrain" made of wedges), so terrain meets them without a gap or a
	step. Hammer only flattens edges that already lie exactly on a brush face; Roblox builds rarely
	line up that well, so this matches within a reach instead.

	For each tile:
	1. Interior edges are dropped. Where two parts lie side by side with a shared edge (two
	   halves of a road, the two wedges of one triangle, neighboring triangles), the edges they
	   share are inside the surface, not its border. Parts joined this way form a group, and the
	   group is matched as one outline.
	2. A part edge is a candidate for a tile edge when the part's side face along it looks back
	   at the tile edge (within about 75 degrees), measured in the tile's flat plane. That keeps
	   the near edge of a road or wall and drops its far edge and its end caps, at any reach,
	   and lets an outline that turns away from the tile edge still be followed. Edges that stand
	   straight up out of the plane (a wall's corner against a floor) are skipped.
	3. Each tile edge vertex maps to the point on the part edge closest to its flat position,
	   measured in the tile plane. On a wedge ramp that point climbs the ramp instead of pulling
	   the vertex backward. Vertices past the end of a part edge are left alone, so a short part
	   (a doorway, a narrow road) only moves the stretch of edge beside it, except where another
	   candidate edge continues from that end: there the vertex goes to the shared corner, so an
	   outline that bends never leaves a vertex behind.
	4. A group matches a tile edge when at least 2 of its vertices are within reach (1 when the
	   group's candidate edges are shorter than two vertex spacings). With `extend`, the rest of
	   the stretch beside a part edge with a vertex in reach follows as long as it stays within
	   reach sideways, at any height, so a tile edge follows a whole ramp once its low end is in
	   reach.
	5. Per vertex, within one part an edge of a face that looks the same way as the tile wins (a
	   road's top edge beats its bottom edge, a ramp's slope beats its base), then the closest.
	   Across parts the closest wins.

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
	min: Vector3,
	max: Vector3,
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
	inReach: boolean,
}

type Candidate = {
	edge: PartEdge,
	tileEdge: number,
	-- The group (step 1) the part belongs to.
	group: BasePart,
	-- In-plane length of the part edge.
	length: number,
	-- Borders a part face that looks the same way as the tile.
	facing: boolean,
	hits: { Hit },
	inReach: number,
	won: { Hit },
}

-- The side face along a part edge must look back at the tile edge within about 75 degrees.
local OUTWARD_DOT = 0.25
-- Part edges shorter than this fraction in the tile plane stand up out of it and are skipped.
local MIN_IN_PLANE = 0.25
-- Lets vertices exactly at a part edge's ends match despite rounding.
local END_MARGIN = 0.05
-- A face looks the same way as the tile (or the opposite way, for caps) past this.
local FACING_DOT = 0.3
-- Two part edges are the same edge when they are parallel within this and one's midpoint lies
-- within COINCIDENT studs of the other.
local PARALLEL_DOT = 0.999
local COINCIDENT = 0.05
-- Faces along a shared edge belong to one surface when their normals agree this well.
local SAME_FACE_DOT = 0.85
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
		table.insert(edges, { part = part, a = a, b = b, n1 = n1, n2 = n2, min = a:Min(b), max = a:Max(b) })
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

local function edgesOf(parts: { BasePart }): { PartEdge }
	local edges: { PartEdge } = {}
	for _, part in parts do
		if Stitch.isStitchable(part) then
			local list = partEdges(part)
			table.move(list, 1, #list, #edges + 1, edges)
		end
	end
	return edges
end

local function inPlane(vector: Vector3, normal: Vector3): Vector3
	return vector - normal * vector:Dot(normal)
end

local function distanceToSegment(point: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local length2 = ab:Dot(ab)
	local t = if length2 > 0 then math.clamp((point - a):Dot(ab) / length2, 0, 1) else 0
	return (point - (a + ab * t)).Magnitude
end

-- Whether two part edges share a face direction that faces along `normal` or against it (the
-- tops of two road halves, the bottoms of two wedges).
local function shareCap(x: PartEdge, y: PartEdge, normal: Vector3): boolean
	for _, n in { x.n1, x.n2 } do
		if math.abs(n:Dot(normal)) > FACING_DOT then
			for _, m in { y.n1, y.n2 } do
				if n:Dot(m) >= SAME_FACE_DOT then
					return true
				end
			end
		end
	end
	return false
end

--[[
	Step 1 of the module comment: which edges are interior, and the group of each part (the
	first part of its group stands for it). Two parts join when an edge of one lies along an edge
	of the other and the faces they cap (top or bottom, seen along `normal`) agree, so a wall
	standing on a road or two roads touching at a corner stay separate.
]]
local function classify(edges: { PartEdge }, normal: Vector3): ({ [PartEdge]: true }, (BasePart) -> BasePart)
	local parent: { [BasePart]: BasePart } = {}
	local function find(part: BasePart): BasePart
		local root = part
		while parent[root] and parent[root] ~= root do
			root = parent[root]
		end
		return root
	end

	local interior: { [PartEdge]: true } = {}
	for i = 1, #edges do
		local x = edges[i]
		local xDirection = (x.b - x.a).Unit
		local xMid = (x.a + x.b) / 2
		for j = i + 1, #edges do
			local y = edges[j]
			if y.part == x.part then
				continue
			end
			if x.min.X > y.max.X + COINCIDENT or y.min.X > x.max.X + COINCIDENT then
				continue
			end
			if x.min.Y > y.max.Y + COINCIDENT or y.min.Y > x.max.Y + COINCIDENT then
				continue
			end
			if x.min.Z > y.max.Z + COINCIDENT or y.min.Z > x.max.Z + COINCIDENT then
				continue
			end
			if math.abs(xDirection:Dot((y.b - y.a).Unit)) < PARALLEL_DOT or not shareCap(x, y, normal) then
				continue
			end
			local xInside = distanceToSegment(xMid, y.a, y.b) <= COINCIDENT
			local yInside = distanceToSegment((y.a + y.b) / 2, x.a, x.b) <= COINCIDENT
			if xInside then
				interior[x] = true
			end
			if yInside then
				interior[y] = true
			end
			if xInside or yInside then
				local rx, ry = find(x.part), find(y.part)
				if rx ~= ry then
					parent[ry] = rx
				end
			end
		end
	end
	return interior, find
end

--[[
	The parts in `pool` joined to `part` through shared edges (step 1 of the module comment),
	`part` included: the whole floor of triangle terrain when one of its wedges is clicked.
	`normal` is the tiles' face normal, which tells tops and bottoms from sides.
]]
function Stitch.sheet(part: BasePart, pool: { BasePart }, normal: Vector3): { BasePart }
	local parts: { BasePart } = { part }
	for _, other in pool do
		if other ~= part and Stitch.isStitchable(other) then
			table.insert(parts, other)
		end
	end
	local _, find = classify(edgesOf(parts), normal)
	local root = find(part)
	local result: { BasePart } = {}
	for _, other in parts do
		if find(other) == root then
			table.insert(result, other)
		end
	end
	return result
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

-- The tile's world bounds (flat face and current surface), grown by `pad`.
local function worldBounds(tile: Tile, pad: number): (Vector3, Vector3)
	local opened = tile.opened
	local lo, hi = opened.boundsMin, opened.boundsMax
	local min, max = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, corner in opened.disp.corners do
		local point = tile.pivot * corner
		min, max = min:Min(point), max:Max(point)
	end
	for _, x in { lo.X, hi.X } do
		for _, y in { lo.Y, hi.Y } do
			for _, z in { lo.Z, hi.Z } do
				local point = tile.pivot * Vector3.new(x, y, z)
				min, max = min:Min(point), max:Max(point)
			end
		end
	end
	return min - Vector3.one * pad, max + Vector3.one * pad
end

-- The candidates of one tile edge (steps 2 and 3 of the module comment), hits filled in.
local function tileEdgeCandidates(
	tile: Tile,
	tileEdge: number,
	indices: { number },
	edges: { PartEdge },
	groupOf: (BasePart) -> BasePart,
	reach: number,
	extend: boolean
): { Candidate }
	local normal = tile.normal
	local first, last = flatOf(tile, indices[1]), flatOf(tile, indices[#indices])
	local direction = last - first
	if direction.Magnitude < 1e-6 then
		return {}
	end
	local outward = normal:Cross(direction.Unit)
	if outward:Dot((first + last) / 2 - tile.center) < 0 then
		outward = -outward
	end

	local candidates: { Candidate } = {}
	for _, edge in edges do
		local ab = edge.b - edge.a
		local abPlane = inPlane(ab, normal)
		local length = abPlane.Magnitude
		if length < 1e-6 or length < MIN_IN_PLANE * ab.Magnitude then
			continue
		end
		-- The side face along the edge: of the two faces, the one that stands more upright.
		local side = if math.abs(edge.n1:Dot(normal)) < math.abs(edge.n2:Dot(normal)) then edge.n1 else edge.n2
		local sidePlane = inPlane(side, normal)
		if sidePlane.Magnitude < 1e-3 or sidePlane.Unit:Dot(outward) > -OUTWARD_DOT then
			continue
		end
		table.insert(candidates, {
			edge = edge,
			tileEdge = tileEdge,
			group = groupOf(edge.part),
			length = length,
			facing = math.max(edge.n1:Dot(normal), edge.n2:Dot(normal)) > FACING_DOT,
			hits = {},
			inReach = 0,
			won = {},
		})
	end

	-- An end where another candidate continues the outline past it is a corner, not an open end.
	-- (A ramp's slope and base edges share the foot corner but run the same way, so the foot
	-- stays an open end.)
	local function joined(own: Candidate, abPlane: Vector3, atB: boolean): boolean
		local point = if atB then own.edge.b else own.edge.a
		for _, other in candidates do
			if other == own then
				continue
			end
			local far: Vector3? = if (other.edge.a - point).Magnitude <= COINCIDENT
				then other.edge.b
				elseif (other.edge.b - point).Magnitude <= COINCIDENT then other.edge.a
				else nil
			if far then
				local t = (far - own.edge.a):Dot(abPlane) / (own.length * own.length)
				if (atB and t > 1) or (not atB and t < 0) then
					return true
				end
			end
		end
		return false
	end

	for _, candidate in candidates do
		local edge = candidate.edge
		local ab = edge.b - edge.a
		local abPlane = inPlane(ab, normal)
		local margin = END_MARGIN / candidate.length
		local joinedA, joinedB = joined(candidate, abPlane, false), joined(candidate, abPlane, true)
		local sideways: { Hit } = {}
		for step, v in indices do
			local t = (flatOf(tile, v) - edge.a):Dot(abPlane) / (candidate.length * candidate.length)
			if (t < -margin and not joinedA) or (t > 1 + margin and not joinedB) then
				continue
			end
			local target = edge.a + ab * math.clamp(t, 0, 1)
			local offset = currentOf(tile, v) - target
			local distance = offset.Magnitude
			if distance <= reach then
				table.insert(candidate.hits, { vertex = v, step = step, target = target, distance = distance, inReach = true })
				candidate.inReach += 1
			elseif extend and inPlane(offset, normal).Magnitude <= reach then
				table.insert(sideways, { vertex = v, step = step, target = target, distance = distance, inReach = false })
			end
		end
		-- Only an edge already holding a vertex in reach pulls the rest of the stretch along.
		if candidate.inReach > 0 then
			table.move(sideways, 1, #sideways, #candidate.hits + 1, candidate.hits)
		end
	end

	-- Step 4: drop groups with too few vertices in reach along this tile edge.
	local spacing = direction.Magnitude / (#indices - 1)
	type GroupCount = { vertices: { [number]: true }, count: number, length: number }
	local groups: { [BasePart]: GroupCount } = {}
	for _, candidate in candidates do
		local count = groups[candidate.group]
		if not count then
			count = { vertices = {}, count = 0, length = 0 }
			groups[candidate.group] = count
		end
		if #candidate.hits > 0 then
			count.length += candidate.length
		end
		for _, hit in candidate.hits do
			if hit.inReach and not count.vertices[hit.vertex] then
				count.vertices[hit.vertex] = true
				count.count += 1
			end
		end
	end
	local kept: { Candidate } = {}
	for _, candidate in candidates do
		local count = groups[candidate.group]
		local required = if count.length < spacing * 2 then 1 else 2
		if count.count >= required and #candidate.hits > 0 then
			table.insert(kept, candidate)
		end
	end
	return kept
end

-- Step 5 of the module comment, between two hits of the same part.
local function betterInPart(a: Hit, aCandidate: Candidate, b: Hit, bCandidate: Candidate): boolean
	if aCandidate.facing ~= bCandidate.facing then
		return aCandidate.facing
	end
	return a.distance < b.distance
end

--[[
	Finds where the edges of `tiles` snap onto edges of `parts` within `reach` studs (see the
	module comment). Nothing is written; pass the moves to `propagate` and `write`.
]]
function Stitch.match(tiles: { Opened }, parts: { BasePart }, reach: number, extend: boolean): Result
	local all = edgesOf(parts)
	local result: Result = { moves = {}, matches = {} }
	if #all == 0 then
		return result
	end

	for _, opened in tiles do
		local tile = buildTile(opened)
		-- Only part edges near this tile matter, which keeps step 1 cheap on big builds.
		local min, max = worldBounds(tile, reach + COINCIDENT)
		local nearby: { PartEdge } = {}
		for _, edge in all do
			if edge.max.X >= min.X and edge.min.X <= max.X and edge.max.Y >= min.Y and edge.min.Y <= max.Y and edge.max.Z >= min.Z and edge.min.Z <= max.Z then
				table.insert(nearby, edge)
			end
		end
		if #nearby == 0 then
			continue
		end
		local interior, groupOf = classify(nearby, tile.normal)
		local boundary: { PartEdge } = {}
		for _, edge in nearby do
			if not interior[edge] then
				table.insert(boundary, edge)
			end
		end

		local candidates: { Candidate } = {}
		for tileEdge, edge in Displacement.edges(opened.disp) do
			local list = tileEdgeCandidates(tile, tileEdge, edge.indices, boundary, groupOf, reach, extend)
			table.move(list, 1, #list, #candidates + 1, candidates)
		end

		-- Each vertex (corners sit on two tile edges): the best hit per part, then the closest
		-- part.
		type Entry = { hit: Hit, candidate: Candidate }
		local perPart: { [number]: { [BasePart]: Entry } } = {}
		for _, candidate in candidates do
			for _, hit in candidate.hits do
				local byPart = perPart[hit.vertex]
				if not byPart then
					byPart = {}
					perPart[hit.vertex] = byPart
				end
				local current = byPart[candidate.edge.part]
				if not current or betterInPart(hit, candidate, current.hit, current.candidate) then
					byPart[candidate.edge.part] = { hit = hit, candidate = candidate }
				end
			end
		end
		if next(perPart) == nil then
			continue
		end
		local moves: { [number]: Vector3 } = {}
		for v, entries in perPart do
			local best: Entry? = nil
			for _, entry in entries do
				if not best or entry.hit.distance < best.hit.distance then
					best = entry
				end
			end
			local chosen = best :: Entry
			moves[v] = chosen.hit.target
			table.insert(chosen.candidate.won, chosen.hit)
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
					edge = candidate.tileEdge,
					part = candidate.edge.part,
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
	2:1 edge), those are placed along the line between the moved ones. A vertex with a twin on a
	moving tile that did not move is left alone: on an edge of the same density, the points
	between two moved ones have their own twins, and moving them would open the seam against
	those. `moves` is not changed.
]]
function Stitch.propagate(moves: Moves, neighbors: { Opened }): Moves
	type Point = { opened: Opened, flat: Vector3, target: Vector3 }
	local points: { Point } = {}
	-- Every edge vertex of the moving tiles, moved or not, with where it is now: it tells a
	-- denser neighbor's in-between vertex (no twin) from one with a twin that stays, and an
	-- unmoved twin anchors the line those in-between vertices are placed along.
	type EdgeFlat = { opened: Opened, flat: Vector3, current: Vector3 }
	local edgeFlats: { EdgeFlat } = {}
	local min, max = Vector3.one * math.huge, -Vector3.one * math.huge
	local result: Moves = {}
	for opened, targets in moves do
		result[opened] = table.clone(targets)
		local tile = buildTile(opened)
		for v, target in targets do
			local flat = flatOf(tile, v)
			table.insert(points, { opened = opened, flat = flat, target = target })
			min = min:Min(flat)
			max = max:Max(flat)
		end
		for _, edge in Displacement.edges(opened.disp) do
			for _, v in edge.indices do
				table.insert(edgeFlats, { opened = opened, flat = flatOf(tile, v), current = currentOf(tile, v) })
			end
		end
	end
	-- The twin of `flat` (a vertex of `owner`) on another moving tile, if any; the tile's own edge
	-- does not count, or a denser neighbor that moves too would never fill in.
	local function twinOf(flat: Vector3, owner: Opened): EdgeFlat?
		for _, other in edgeFlats do
			if other.opened ~= owner and samePoint(flat, other.flat) then
				return other
			end
		end
		return nil
	end
	-- Where a moved vertex of another tile sends `flat`, if one sits there.
	local function targetOf(flat: Vector3, owner: Opened): Vector3?
		for _, point in points do
			if point.opened ~= owner and samePoint(flat, point.flat) then
				return point.target
			end
		end
		return nil
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
				local flat = flatOf(tile, v)
				local target = targetOf(flat, opened)
				if target then
					placed[step] = target
					if not (own and own[v]) then
						added[v] = target
						any = true
					end
				elseif own and own[v] then
					-- Its own move anchors the line too.
					placed[step] = own[v]
				else
					-- A twin that stays where it is anchors the line at its current spot.
					local twin = twinOf(flat, opened)
					if twin then
						placed[step] = twin.current
					end
				end
			end
			-- Fill short runs between two placed vertices (the in-between vertices of a denser
			-- neighbor along a 2:1 edge), only where they have no twin of their own.
			local last: number? = nil
			for step = 1, #indices do
				if placed[step] then
					local from = last
					if from and step - from > 1 and step - from - 1 <= MAX_INTERPOLATED_RUN then
						local a, b = placed[from], placed[step]
						for k = from + 1, step - 1 do
							local v = indices[k]
							if not (own and own[v]) and not added[v] and not twinOf(flatOf(tile, v), opened) then
								added[v] = a:Lerp(b, (k - from) / (step - from))
								any = true
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
