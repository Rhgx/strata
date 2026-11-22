--!strict
--[[
	Snaps displacement edges onto the edges of standard parts (roads, floors, walls, wedge ramps,
	and wedge-based triangle terrain) so terrain meets architecture cleanly without gaps or steps.
	Hammer only flattens edges already lying exactly on a brush face; Roblox builds rarely align
	that tightly, so Strata matches within a configurable reach.

	Per-tile matching algorithm:
	1. Drop interior edges. When two parts meet along a shared edge (road halves, paired wedges,
	   adjacent floor panels), that edge lies inside the combined surface rather than on its
	   border. Parts joined this way form a single group matched as one outline.
	2. Filter candidate part edges by facing: the part's side face along the edge must face back
	   toward the tile edge (within ~75 degrees in the tile's flat plane). This selects the near
	   edge of a road or wall while ignoring far edges and end caps at any reach, while still
	   following outlines that turn away. Vertical edges perpendicular to the tile plane are skipped.
	3. Project each tile edge vertex onto the closest point on the part edge measured in the tile
	   plane, so wedge ramps lift vertices smoothly instead of pulling them backward. Vertices
	   past an open end of a part edge are untouched (so narrow parts only move the adjacent span),
	   unless another candidate edge continues from that corner (snapping to the shared corner so
	   bending outlines never strand a vertex).
	4. Require at least 2 in-reach vertices per group along a tile edge (or 1 when the group's
	   candidate edges span less than two vertex spacings). With `extend` enabled, remaining
	   vertices alongside an edge with at least one in-reach hit follow as long as they stay
	   within reach laterally at any height, letting terrain follow a full ramp from its foot.
	5. Resolve conflicts per vertex: within one part, edges bordering a face oriented like the
	   tile win (road top beats bottom, ramp slope beats base), then closest distance; across
	   parts, closest distance wins.

	Stitched vertices are not sewn afterwards, because averaging a snapped corner with an
	unsnapped neighbor would pull it off the part. Instead, `propagate` copies target positions to
	coincident neighbor edge vertices so parts take precedence while keeping seams closed.
]]

local Core = script.Parent

local Units = require(Core.Units)
local PartFaces = require(Core.PartFaces)
local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

type Opened = TerrainInstance.Opened

export type Changes = { [Opened]: { [number]: true } }
-- World-space target positions indexed by displacement vertex.
export type Moves = { [Opened]: { [number]: Vector3 } }

-- A matched span of one tile edge snapped to one part edge.
export type Match = {
	opened: Opened,
	-- Tile edge index 1..4 in Displacement.edges order.
	edge: number,
	part: BasePart,
	-- Matched vertices ordered along the tile edge.
	vertices: { number },
}

export type Result = {
	moves: Moves,
	matches: { Match },
}

-- A part edge and the outward normals of its two adjacent faces.
type PartEdge = {
	part: BasePart,
	a: Vector3,
	b: Vector3,
	n1: Vector3,
	n2: Vector3,
	min: Vector3,
	max: Vector3,
}

type Hit = {
	vertex: number,
	-- Position along the tile edge, used to order matches.
	step: number,
	target: Vector3,
	distance: number,
	inReach: boolean,
}

type Candidate = {
	edge: PartEdge,
	tileEdge: number,
	-- Representative root part of the connected group from step 1.
	group: BasePart,
	-- Length of the part edge projected into the tile plane.
	length: number,
	-- Whether the edge borders a part face oriented with the tile normal.
	facing: boolean,
	hits: { Hit },
	inReach: number,
	won: { Hit },
}

type Tile = {
	opened: Opened,
	pivot: CFrame,
	-- Face normal in local space (for Displacement.position) and world space.
	localNormal: Vector3,
	normal: Vector3,
	center: Vector3,
	flat: { [number]: Vector3 },
	current: { [number]: Vector3 },
}

-- Minimum inward dot product (~75 degrees) for a part's side face to face back at a tile edge.
local OUTWARD_DOT = 0.25
-- Part edges with less than this fraction of their length in the tile plane are nearly vertical and skipped.
local MIN_IN_PLANE = 0.25
-- Endpoint margin in studs so vertices exactly at part corners still match despite rounding.
local END_MARGIN = 0.05
-- Minimum normal dot product for a part face to count as facing with (or opposite, for caps) the tile.
local FACING_DOT = 0.3
-- Parallelism and midpoint distance tolerances for identifying shared interior edges between parts.
local PARALLEL_DOT = 0.999
local COINCIDENT = 0.05
-- Minimum dot product for adjacent cap faces along a shared edge to form one continuous surface.
local SAME_FACE_DOT = 0.85
-- Ignore target moves smaller than this threshold.
local SAME = 1e-4
-- Flat-position tolerance for matching neighbor vertices, matching Sew (1 Hammer unit per axis).
local TOLERANCE = Units.studs(1)
local MAX_INTERPOLATED_RUN = 3

local Stitch = {}

-- Extracts all world-space edges of a block Part (12) or wedge (9).
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
		-- Wedge slope rises from the bottom-front edge to the top-back edge.
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

-- Checks whether two edges share an aligned top or bottom cap face relative to `normal`
-- (e.g. two halves of a road or two adjacent floor wedges).
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

-- Step 1: marks shared interior edges and unions parts joined across aligned cap faces into
-- groups (keeping walls on roads or corner-touching roads separate).
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

-- Returns all parts in `pool` (including `part`) connected to `part` via shared cap edges, so
-- clicking one wedge of a multi-part floor selects the entire continuous outline.
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

-- Computes the tile's world-space AABB (enclosing both flat corners and sculpted bounds), padded by `pad`.
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

-- Steps 2, 3, and 4 for one tile edge: filters facing candidate edges, projects vertices, and
-- drops groups with too few in-reach hits.
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

		-- Identify the more vertical of the two adjacent faces as the side face.
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

	-- Checks whether another candidate continues past endpoint `atB` (a joined outline corner
	-- rather than an open end). A ramp's slope and base share the foot corner but head in the
	-- same direction, so the foot remains an open end.
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

		-- Only extend vertically along edges that already have at least one vertex within reach.
		if candidate.inReach > 0 then
			table.move(sideways, 1, #sideways, #candidate.hits + 1, candidate.hits)
		end
	end

	-- Step 4: drop groups with fewer than the required in-reach vertices along this tile edge.
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

-- Step 5 tie-breaker between two candidate hits on the same part.
local function betterInPart(a: Hit, aCandidate: Candidate, b: Hit, bCandidate: Candidate): boolean
	if aCandidate.facing ~= bCandidate.facing then
		return aCandidate.facing
	end

	return a.distance < b.distance
end

-- Computes target moves snapping edges of `tiles` onto `parts` within `reach` studs without
-- mutating any tiles. Pass the returned moves to `Stitch.propagate` and `Stitch.write`.
function Stitch.match(tiles: { Opened }, parts: { BasePart }, reach: number, extend: boolean): Result
	local all = edgesOf(parts)
	local result: Result = { moves = {}, matches = {} }

	if #all == 0 then
		return result
	end

	for _, opened in tiles do
		local tile = buildTile(opened)
		-- Restrict step 1 classification to part edges overlapping this tile's padded bounds.
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

		-- Select the best hit per part for each vertex (including corners shared by two edges),
		-- then pick the closest part overall.
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
				table.sort(candidate.won, function (x: Hit, y: Hit)
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

-- Returns a copy of `moves` augmented with coincident edge vertices on `neighbors` sent to the
-- same targets. Intermediate vertices on a denser neighbor along a 2:1 edge are linearly
-- interpolated between moved endpoints, while vertices with an unmoved twin on a moving tile
-- remain untouched so equal-density seams stay sealed. Does not mutate `moves`.
function Stitch.propagate(moves: Moves, neighbors: { Opened }): Moves
	type Point = { opened: Opened, flat: Vector3, target: Vector3 }
	-- All edge vertices (moved or unmoved) of moving tiles with their current positions: used to
	-- distinguish twinless intermediate 2:1 vertices from vertices anchored by an unmoved twin.
	type EdgeFlat = { opened: Opened, flat: Vector3, current: Vector3 }

	local points: { Point } = {}
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

	-- Finds a twin of `flat` on a different moving tile (excluding `owner` itself so a denser
	-- moving neighbor can still interpolate its intermediate vertices).
	local function twinOf(flat: Vector3, owner: Opened): EdgeFlat?
		for _, other in edgeFlats do
			if other.opened ~= owner and samePoint(flat, other.flat) then
				return other
			end
		end

		return nil
	end

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
					-- Anchor interpolation spans on this tile's own moved vertices too.
					placed[step] = own[v]
				else
					-- Anchor interpolation spans on unmoved twins that stay put.
					local twin = twinOf(flat, opened)

					if twin then
						placed[step] = twin.current
					end
				end
			end

			-- Interpolate short runs of twinless intermediate vertices along denser 2:1 edges.
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

-- Writes target positions that differ by more than SAME from current positions. Returns changed
-- vertices per tile; wedges and attribute saving are left to the caller.
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

-- Computes per-vertex move distances for preview rendering.
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

-- Returns the current world-space position of vertex `v` on `opened`.
function Stitch.vertexPosition(opened: Opened, v: number): Vector3
	return currentOf(buildTile(opened), v)
end

return Stitch
