--!strict
--[[
	Sewing welds the shared edges and corners of neighboring displacements, following Hammer's
	Sew. Like Hammer it works in displacement space: it edits the stored fields (field vector
	and distance, offset, offset normal, alpha) and never the corners or the elevation, so a
	seam closes when both sides share their flat edge and elevation.

	Matching uses the flat (undisplaced) world-space corners with Hammer's per-axis tolerance of
	1 Hammer unit, so displacements in different models with different pivots sew together.
	Vectors are compared and averaged in world space and stored back in each model's space.

	Order, as in Hammer:
	1. Corners shared by 2 to 16 displacements: every field becomes the plain mean (the field
	   vector and distance are averaged separately, so the vector can end up non-unit). Alpha is
	   averaged only when all materials match.
	2. T-junction points (the midpoint of one edge on a corner of others, 2:1 only): the same
	   mean, alpha always averaged.
	3. Edges. Full edges: vertices at the same spot on both sides are averaged in pairs (the
	   displacement vectors are averaged, the offset normal renormalized, alpha copied from the
	   lower-power side when materials match), then the in-between vertices of the denser side
	   are interpolated along those pairs. Endpoints belong to the corner pass. Half edges along
	   a long edge (2:1) work the same way per half.

	Deliberate deviations from Hammer:
	- Hammer always pairs the vertices of two edges as if they run in opposite directions, which
	  twists the seam when they run the same way. Here vertices are paired by actual direction.
	- Hammer first moves the vertices a lower-power neighbor does not have onto the coarse
	  triangles (its "allowed vertex" pass). That compensates for vertices Source drops when it
	  compiles a map; this plugin builds every vertex, so the pass is skipped.
	- On a 2:1 edge where the long side is denser than a half, Hammer re-interpolates the whole
	  long edge, reopening the other half's seam. Here only the half being sewn is interpolated.
	- A 3-face edge group whose second entry is not a full edge match is left alone (Hammer's
	  result there is undefined).
]]

local Displacement = require(script.Parent.Displacement)
local TerrainInstance = require(script.Parent.TerrainInstance)
local Units = require(script.Parent.Units)

type Opened = TerrainInstance.Opened
export type Changes = { [Opened]: { [number]: true } }

-- Hammer's point match tolerance: 1 Hammer unit per axis.
local TOLERANCE = Units.studs(1)
local MAX_CORNER_FACES = 16
local MAX_T_FACES = 8
local MAX_EDGE_FACES = 3
-- Differences below this do not count as a change, so re-sewing a sewn seam does not unbake.
local SAME = 1e-5

-- One vertex's stored fields. Vectors are in whichever space the caller says.
type Value = {
	vector: Vector3,
	distance: number,
	offset: Vector3,
	offsetNormal: Vector3,
	alpha: number,
}

type Face = {
	opened: Opened,
	disp: Displacement.Displacement,
	pivot: CFrame,
	-- Grid quads per side (2^power).
	n: number,
	-- Flat world corners; points[1] is Hammer's surface point 0.
	points: { Vector3 },
	boundsMin: Vector3,
	boundsMax: Vector3,
	faceNormal: Vector3,
	-- Values before the first write, to report only real changes.
	original: { [number]: Value },
}

type Entry = { face: Face, vertex: number, point: Vector3 }

-- Edge roles from compareEdges: 0 full edge, 3 long edge, 1 and 2 the half edge on the long
-- edge's first or second half.
type EdgeEntry = { face: Face, edge: number, role: number }

local Sew = {}

local function samePoint(a: Vector3, b: Vector3): boolean
	return math.abs(a.X - b.X) <= TOLERANCE and math.abs(a.Y - b.Y) <= TOLERANCE and math.abs(a.Z - b.Z) <= TOLERANCE
end

local function buildFace(opened: Opened): Face
	local pivot = opened.model:GetPivot()
	local points = table.create(4)
	local min, max = Vector3.one * math.huge, -Vector3.one * math.huge
	for k = 1, 4 do
		local point = pivot * opened.disp.corners[k]
		points[k] = point
		min = min:Min(point)
		max = max:Max(point)
	end
	return {
		opened = opened,
		disp = opened.disp,
		pivot = pivot,
		n = opened.disp.size - 1,
		points = points,
		boundsMin = min,
		boundsMax = max,
		faceNormal = Displacement.faceNormal(opened.disp),
		original = {},
	}
end

local function boundsTouch(a: Face, b: Face): boolean
	local pad = Vector3.one * TOLERANCE
	local min = a.boundsMin:Max(b.boundsMin)
	local max = a.boundsMax:Min(b.boundsMax)
	local gap = min - max - pad
	return gap.X <= 0 and gap.Y <= 0 and gap.Z <= 0
end

-- Grid helpers, with Hammer's 0-based corners (0 to 3), edges (corner e to e + 1) and steps
-- along an edge (0 to n), returning 1-based vertex indices.
local function cornerVertex(face: Face, corner: number): number
	return Displacement.cornerVertex(face.disp, corner + 1)
end

local function edgeVertex(face: Face, edge: number, i: number): number
	local n = face.n
	local w = n + 1
	if edge == 0 then
		return i * w + 1
	elseif edge == 1 then
		return n * w + i + 1
	elseif edge == 2 then
		return (w - i) * w
	end
	return n - i + 1
end

local function edgeStart(face: Face, edge: number): Vector3
	return face.points[edge + 1]
end

local function edgeEnd(face: Face, edge: number): Vector3
	return face.points[(edge + 1) % 4 + 1]
end

local function edgeMid(face: Face, edge: number): Vector3
	return (edgeStart(face, edge) + edgeEnd(face, edge)) * 0.5
end

-- Reading and writing vertex values ---------------------------------------------------------

local function readLocal(face: Face, v: number): Value
	local disp = face.disp
	return {
		vector = disp.normals[v],
		distance = disp.distances[v],
		offset = disp.offsets[v],
		offsetNormal = disp.offsetNormals[v],
		alpha = disp.alphas[v],
	}
end

local function readWorld(face: Face, v: number): Value
	local value = readLocal(face, v)
	value.vector = face.pivot:VectorToWorldSpace(value.vector)
	value.offset = face.pivot:VectorToWorldSpace(value.offset)
	value.offsetNormal = face.pivot:VectorToWorldSpace(value.offsetNormal)
	return value
end

local function writeLocal(face: Face, v: number, value: Value)
	if not face.original[v] then
		face.original[v] = readLocal(face, v)
	end
	local disp = face.disp
	disp.normals[v] = value.vector
	disp.distances[v] = value.distance
	disp.offsets[v] = value.offset
	disp.offsetNormals[v] = value.offsetNormal
	disp.alphas[v] = value.alpha
end

local function writeWorld(face: Face, v: number, value: Value)
	writeLocal(face, v, {
		vector = face.pivot:VectorToObjectSpace(value.vector),
		distance = value.distance,
		offset = face.pivot:VectorToObjectSpace(value.offset),
		offsetNormal = face.pivot:VectorToObjectSpace(value.offsetNormal),
		alpha = value.alpha,
	})
end

local function differs(a: Value, b: Value): boolean
	return (a.vector * a.distance - b.vector * b.distance).Magnitude > SAME
		or (a.vector - b.vector).Magnitude > SAME
		or (a.offset - b.offset).Magnitude > SAME
		or (a.offsetNormal - b.offsetNormal).Magnitude > SAME
		or math.abs(a.alpha - b.alpha) > SAME
end

-- Collects the vertices that really changed. Vertices that ended up where they started are
-- restored exactly, so no rounding noise is saved either.
local function collectChanges(faces: { Face }): Changes
	local result: Changes = {}
	for _, face in faces do
		local changed: { [number]: true } = {}
		for v, before in face.original do
			if differs(before, readLocal(face, v)) then
				changed[v] = true
			else
				local disp = face.disp
				disp.normals[v] = before.vector
				disp.distances[v] = before.distance
				disp.offsets[v] = before.offset
				disp.offsetNormals[v] = before.offsetNormal
				disp.alphas[v] = before.alpha
			end
		end
		if next(changed) ~= nil then
			result[face.opened] = changed
		end
	end
	return result
end

-- Sew primitives -----------------------------------------------------------------------------

-- Hammer's pair average: both vertices get the mean displacement vector, the mean offset and
-- the renormalized sum of offset normals. Alpha is copied from `a` when the materials match.
local function pairAverage(faceA: Face, a: number, faceB: Face, b: number)
	local va, vb = readWorld(faceA, a), readWorld(faceB, b)
	local vector, distance =
		Displacement.normalizeWithLength((va.vector * va.distance + vb.vector * vb.distance) * 0.5)
	local offsetNormal = Displacement.normalizeWithLength(va.offsetNormal + vb.offsetNormal)
	local offset = (va.offset + vb.offset) * 0.5
	local alphaB = if faceA.disp.material == faceB.disp.material then va.alpha else vb.alpha
	writeWorld(faceA, a, {
		vector = vector,
		distance = distance,
		offset = offset,
		offsetNormal = offsetNormal,
		alpha = va.alpha,
	})
	writeWorld(faceB, b, {
		vector = vector,
		distance = distance,
		offset = offset,
		offsetNormal = offsetNormal,
		alpha = alphaB,
	})
end

-- Writes vertex m of one displacement as the blend of its vertices s and e at t. Flat positions
-- and elevation are linear along an edge, so m lands on the line between them.
local function lerpInto(face: Face, s: number, e: number, m: number, t: number)
	local vs, ve = readLocal(face, s), readLocal(face, e)
	local vector, distance = Displacement.normalizeWithLength((vs.vector * vs.distance):Lerp(ve.vector * ve.distance, t))
	writeLocal(face, m, {
		vector = vector,
		distance = distance,
		offset = vs.offset:Lerp(ve.offset, t),
		-- Not renormalized, like Hammer.
		offsetNormal = vs.offsetNormal:Lerp(ve.offsetNormal, t),
		alpha = vs.alpha + (ve.alpha - vs.alpha) * t,
	})
end

-- Plain mean of every field over a group. Vector and distance are averaged separately and not
-- renormalized (Hammer's behavior).
local function groupMean(entries: { Entry }, averageAlpha: boolean)
	local vector, distance, offset, offsetNormal, alpha = Vector3.zero, 0, Vector3.zero, Vector3.zero, 0
	local values = table.create(#entries)
	for i, entry in entries do
		local value = readWorld(entry.face, entry.vertex)
		values[i] = value
		vector += value.vector
		distance += value.distance
		offset += value.offset
		offsetNormal += value.offsetNormal
		alpha += value.alpha
	end
	local count = #entries
	for i, entry in entries do
		writeWorld(entry.face, entry.vertex, {
			vector = vector / count,
			distance = distance / count,
			offset = offset / count,
			offsetNormal = offsetNormal / count,
			alpha = if averageAlpha then alpha / count else values[i].alpha,
		})
	end
end

-- Matching -----------------------------------------------------------------------------------

--[[
	Compares edge A (a0 to a1) and edge B by their endpoints and midpoints. Returns the roles of
	A and B (see EdgeEntry), or nil when they are not related. Midpoint against midpoint is never
	tested, so only full edges and 2:1 halves match.
]]
local function compareEdges(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3): (number?, number)
	local aMid, bMid = (a0 + a1) * 0.5, (b0 + b1) * 0.5
	local pb = { b0, bMid, b1 }
	local aHits: { number } = {}
	local bHits: { number } = {}
	local function try(aIndex: number, point: Vector3, allowMid: boolean)
		for j = 1, 3 do
			if (j ~= 2 or allowMid) and samePoint(point, pb[j]) then
				table.insert(aHits, aIndex)
				table.insert(bHits, j)
				return
			end
		end
	end
	try(1, a0, true)
	try(2, aMid, false)
	try(3, a1, true)
	if #aHits ~= 2 then
		return nil, 0
	end
	for k = 1, 2 do
		if aHits[k] == 2 then
			return 3, if aHits[3 - k] == 1 then 1 else 2
		end
	end
	for k = 1, 2 do
		if bHits[k] == 2 then
			return if bHits[3 - k] == 1 then 1 else 2, 3
		end
	end
	return 0, 0
end

local function compareEntries(a: EdgeEntry, b: EdgeEntry): (number?, number)
	return compareEdges(edgeStart(a.face, a.edge), edgeEnd(a.face, a.edge), edgeStart(b.face, b.edge), edgeEnd(b.face, b.edge))
end

type Groups = {
	corners: { { Entry } },
	tPoints: { { Entry } },
	edges: { { EdgeEntry } },
	tooMany: boolean,
}

-- Adds `group` to the lookup of groups per face, so duplicate checks only scan nearby groups.
local function indexGroup<T>(byFace: { [Face]: { T } }, face: Face, group: T)
	local list = byFace[face]
	if list then
		table.insert(list, group)
	else
		byFace[face] = { group }
	end
end

-- Corner or T-junction groups at `point` on `face`. Shared by both point passes.
local function buildPointGroup(
	groups: Groups,
	near: { [Face]: { Face } },
	face: Face,
	point: Vector3,
	own: Entry,
	limit: number
): { Entry }?
	local group: { Entry } = {}
	for _, other in near[face] do
		for k = 0, 3 do
			if samePoint(point, other.points[k + 1]) then
				if #group < limit then
					table.insert(group, { face = other, vertex = cornerVertex(other, k), point = other.points[k + 1] })
				else
					groups.tooMany = true
				end
			end
		end
	end
	if #group == 0 then
		return nil
	end
	if #group < limit then
		table.insert(group, own)
	else
		groups.tooMany = true
	end
	return group
end

-- Appends a point group unless an earlier one already covers its first entry's point. Such a
-- group always contains that entry's face, so only its groups are checked.
local function addPointGroup(list: { { Entry } }, byFace: { [Face]: { { Entry } } }, group: { Entry })
	local nearby: { { Entry } } = byFace[group[1].face] or {}
	for _, existing in nearby do
		if samePoint(existing[1].point, group[1].point) then
			return
		end
	end
	table.insert(list, group)
	for _, entry in group do
		indexGroup(byFace, entry.face, group)
	end
end

-- Builds Hammer's corner, T-junction and edge groups over `faces` in order (the first face to
-- see a shared spot owns its group). `near[face]` lists the other faces whose bounds touch it,
-- in the same order.
local function buildGroups(faces: { Face }, near: { [Face]: { Face } }): Groups
	local groups: Groups = { corners = {}, tPoints = {}, edges = {}, tooMany = false }

	-- Corners shared with other faces.
	local cornersByFace: { [Face]: { { Entry } } } = {}
	for _, face in faces do
		for c = 0, 3 do
			local point = face.points[c + 1]
			local own = { face = face, vertex = cornerVertex(face, c), point = point }
			local group = buildPointGroup(groups, near, face, point, own, MAX_CORNER_FACES)
			if group then
				addPointGroup(groups.corners, cornersByFace, group)
			end
		end
	end

	-- T-junction points: an edge midpoint on corners of other faces.
	local tByFace: { [Face]: { { Entry } } } = {}
	for _, face in faces do
		for e = 0, 3 do
			local mid = edgeMid(face, e)
			local own = { face = face, vertex = edgeVertex(face, e, face.n // 2), point = mid }
			local group = buildPointGroup(groups, near, face, mid, own, MAX_T_FACES)
			if group then
				addPointGroup(groups.tPoints, tByFace, group)
			end
		end
	end

	-- Edges: full edge groups, and T edge groups (one long edge plus up to one half per side).
	local edgesByFace: { [Face]: { { EdgeEntry } } } = {}
	local function addEdgeGroup(group: { EdgeEntry })
		table.insert(groups.edges, group)
		for _, entry in group do
			indexGroup(edgesByFace, entry.face, group)
		end
	end

	for _, face in faces do
		for e = 0, 3 do
			local own: EdgeEntry = { face = face, edge = e, role = 0 }
			local group: { EdgeEntry } = {}
			for _, other in near[face] do
				for k = 0, 3 do
					local entry: EdgeEntry = { face = other, edge = k, role = 0 }
					local roleOwn, roleOther = compareEntries(own, entry)
					if roleOwn then
						own.role = roleOwn
						entry.role = roleOther
						if #group < MAX_EDGE_FACES then
							table.insert(group, entry)
						else
							groups.tooMany = true
						end
					end
				end
			end
			if #group == 0 then
				continue
			end
			if #group < MAX_EDGE_FACES then
				table.insert(group, own)
			else
				groups.tooMany = true
			end

			local first = group[1]
			if first.role == 0 then
				-- A full edge is skipped when any existing group already involves it. Related
				-- edges belong to the same face or a nearby one.
				local related = false
				local candidates = table.clone(near[first.face])
				table.insert(candidates, first.face)
				for _, candidate in candidates do
					local nearby: { { EdgeEntry } } = edgesByFace[candidate] or {}
					for _, existing in nearby do
						for _, entry in existing do
							if compareEntries(first, entry) then
								related = true
								break
							end
						end
						if related then
							break
						end
					end
					if related then
						break
					end
				end
				if not related then
					addEdgeGroup(group)
				end
			else
				local long: EdgeEntry? = nil
				for _, entry in group do
					if entry.role == 3 then
						long = entry
						break
					end
				end
				if not long then
					continue
				end
				-- Merge into the group whose long edge is the same one, if there is one.
				local target: { EdgeEntry }? = nil
				local sameFace: { { EdgeEntry } } = edgesByFace[long.face] or {}
				for _, existing in sameFace do
					for _, entry in existing do
						if entry.role == 3 then
							if (entry.face == long.face and entry.edge == long.edge) or compareEntries(entry, long) == 0 then
								target = existing
							end
							break
						end
					end
					if target then
						break
					end
				end
				if target then
					for _, entry in group do
						if entry.role == 3 then
							continue
						end
						local hasRole = false
						for _, existing in target do
							if existing.role == entry.role then
								hasRole = true
							end
						end
						if not hasRole then
							if #target < MAX_EDGE_FACES then
								table.insert(target, entry)
								indexGroup(edgesByFace, entry.face, target)
							else
								groups.tooMany = true
							end
						end
					end
				else
					addEdgeGroup(group)
				end
			end
		end
	end

	return groups
end

-- Edge sewing --------------------------------------------------------------------------------

-- Interpolates the vertices of an edge between the ones at multiples of `step`, over steps
-- `from` to `to` (the whole edge by default).
local function interpolateEdge(face: Face, edge: number, step: number, from: number?, to: number?)
	if step <= 1 then
		return
	end
	for s = from or 0, (to or face.n) - step, step do
		for j = 1, step - 1 do
			lerpInto(face, edgeVertex(face, edge, s), edgeVertex(face, edge, s + step), edgeVertex(face, edge, s + j), j / step)
		end
	end
end

local function sewFullEdge(x: EdgeEntry, y: EdgeEntry)
	-- The lower-power side goes first (it gives its alpha); on a tie, the first entry.
	local low, high = x, y
	if y.face.n < x.face.n then
		low, high = y, x
	end
	local nLow, nHigh = low.face.n, high.face.n
	local ratio = nHigh // nLow
	-- Pair by actual direction (see the module comment).
	local reversed = not samePoint(edgeStart(low.face, low.edge), edgeStart(high.face, high.edge))
	for i = 1, nLow - 1 do
		local k = i * ratio
		pairAverage(
			low.face,
			edgeVertex(low.face, low.edge, i),
			high.face,
			edgeVertex(high.face, high.edge, if reversed then nHigh - k else k)
		)
	end
	interpolateEdge(high.face, high.edge, ratio)
end

-- Sews half edge `half` to the first or second half of long edge `long`.
local function sewTEdge(long: EdgeEntry, half: EdgeEntry, firstHalf: boolean)
	local nLong, nHalf = long.face.n, half.face.n
	local hLong = nLong // 2
	local base = if firstHalf then 0 else hLong
	-- Does the half edge start where its half of the long edge starts?
	local halfStart = if firstHalf then edgeStart(long.face, long.edge) else edgeMid(long.face, long.edge)
	local forward = samePoint(edgeStart(half.face, half.edge), halfStart)
	-- The half edge's step at long edge step j (only called where both have a vertex).
	local function halfStep(j: number): number
		local k = (j - base) * nHalf // hLong
		return if forward then k else nHalf - k
	end

	if nHalf >= hLong then
		-- The half face is as dense or denser: pair the long edge's interior vertices on this
		-- half, then interpolate the half edge between them.
		local ratio = nHalf // hLong
		for i = 1, hLong - 1 do
			local j = base + i
			pairAverage(
				half.face,
				edgeVertex(half.face, half.edge, halfStep(j)),
				long.face,
				edgeVertex(long.face, long.edge, j)
			)
		end
		interpolateEdge(half.face, half.edge, ratio)
	else
		-- The long face is denser: pair every half edge vertex from the far corner up to and
		-- including the T point, then interpolate the long edge along this half. Hammer
		-- interpolates both halves here, which reopens a seam already sewn to a half on the other
		-- side; this deliberately stays on the half being sewn.
		local ratio = hLong // nHalf
		for i = 1, nHalf do
			local j = if firstHalf then i * ratio else nLong - i * ratio
			pairAverage(
				half.face,
				edgeVertex(half.face, half.edge, halfStep(j)),
				long.face,
				edgeVertex(long.face, long.edge, j)
			)
		end
		interpolateEdge(long.face, long.edge, ratio, base, base + hLong)
	end
end

-- Public API ---------------------------------------------------------------------------------

local function involvesFocus(faces: { Face }, focus: { [Opened]: true }?): boolean
	if focus == nil then
		return true
	end
	for _, face in faces do
		if focus[face.opened] then
			return true
		end
	end
	return false
end

local function entryFaces(entries: { Entry }): { Face }
	local faces = table.create(#entries)
	for i, entry in entries do
		faces[i] = entry.face
	end
	return faces
end

local function edgeFaces(entries: { EdgeEntry }): { Face }
	local faces = table.create(#entries)
	for i, entry in entries do
		faces[i] = entry.face
	end
	return faces
end

--[[
	Sews `targets` together (in their order, which decides group ownership like Hammer's
	selection order) and returns the changed vertices per displacement, plus a warning when a
	corner, T point or edge had more faces than Hammer's limits. The vertex data is updated;
	wedges and attributes are left to the caller. When `focus` is given, only groups that
	involve a focused displacement are sewn (autosew uses this to touch just the neighbors of
	what was edited).
]]
function Sew.sew(targets: { Opened }, focus: { [Opened]: true }?): (Changes, string?)
	local all: { Face } = table.create(#targets)
	for i, opened in targets do
		all[i] = buildFace(opened)
	end

	-- With a focus, only faces near a focused one can share a group with it.
	local faces: { Face } = all
	if focus then
		local focused: { Face } = {}
		for _, face in all do
			if focus[face.opened] then
				table.insert(focused, face)
			end
		end
		faces = {}
		for _, face in all do
			for _, other in focused do
				if face == other or boundsTouch(face, other) then
					table.insert(faces, face)
					break
				end
			end
		end
	end

	local near: { [Face]: { Face } } = {}
	for _, face in faces do
		local list = {}
		for _, other in faces do
			if other ~= face and boundsTouch(face, other) then
				table.insert(list, other)
			end
		end
		near[face] = list
	end

	local groups = buildGroups(faces, near)

	for _, group in groups.corners do
		if involvesFocus(entryFaces(group), focus) then
			local sameMaterial = true
			for _, entry in group do
				if entry.face.disp.material ~= group[1].face.disp.material then
					sameMaterial = false
				end
			end
			groupMean(group, sameMaterial)
		end
	end

	for _, group in groups.tPoints do
		if involvesFocus(entryFaces(group), focus) then
			groupMean(group, true)
		end
	end

	for _, group in groups.edges do
		if not involvesFocus(edgeFaces(group), focus) then
			continue
		end
		if group[1].role == 0 then
			local second = group[2]
			if second and compareEntries(group[1], second) == 0 then
				sewFullEdge(group[1], second)
			end
		else
			local long, firstHalf, secondHalf = nil, nil, nil
			for _, entry in group do
				if entry.role == 3 then
					long = long or entry
				elseif entry.role == 1 then
					firstHalf = firstHalf or entry
				elseif entry.role == 2 then
					secondHalf = secondHalf or entry
				end
			end
			if long then
				if firstHalf then
					sewTEdge(long, firstHalf, true)
				end
				if secondHalf then
					sewTEdge(long, secondHalf, false)
				end
			end
		end
	end

	local warning = if groups.tooMany
		then "Not all faces could be sewn: too many displacements share a corner or an edge."
		else nil
	return collectChanges(faces), warning
end

return Sew
