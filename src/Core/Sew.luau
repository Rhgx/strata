--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Welds shared edges and corners of neighboring displacements, following Hammer's Sew. Like
	Hammer, sewing operates in displacement space: it modifies stored fields (field vector,
	distance, offset, offsetNormal, alpha) and never touches corners or elevation, so seams close
	whenever both sides share a flat edge and elevation.

	Matching compares flat (undisplaced) world-space corners within Hammer's per-axis tolerance
	of 1 Hammer unit, allowing displacements under different models and pivots to sew together.
	Vectors are compared and averaged in world space and transformed back into each tile's local
	space.

	Pass order (matching Hammer):
	1. Corners shared by 2 to 16 displacements: plain mean of every field (field vector and
	   distance are averaged separately, so the resulting vector may be non-unit). Alpha is
	   averaged only when all materials match.
	2. T-junction points (edge midpoint meeting corners of other tiles, 2:1 only): same plain
	   mean, with alpha always averaged.
	3. Edges: on full edges, coincident vertices are pair-averaged (field vectors averaged,
	   offset normals renormalized, alpha copied from the lower-power side when materials match),
	   then intermediate vertices on the denser side are linearly interpolated between pairs.
	   Endpoints are handled by the corner pass. 2:1 half edges follow the same rule per half.

	Intentional deviations from Hammer:
	- Hammer always pairs edge vertices as if edges run in opposite directions, twisting seams
	  when edges run the same way. Here vertices are paired by actual geometric direction.
	- Hammer's "allowed vertex" pass projects finer vertices onto coarser triangles to compensate
	  for Source map-compile decimation. Strata renders every vertex, so that pass is omitted.
	- On 2:1 edges where the long side is denser than a half, Hammer re-interpolates the entire
	  long edge and reopens the opposite half. Here only the sewn half is interpolated.
	- A 3-face edge group whose second entry is not a full-edge match is skipped (Hammer's
	  behavior in that case is undefined).
]]

local Core = script.Parent

local Units = require(Core.Units)
local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

type Opened = TerrainInstance.Opened

export type Changes = { [Opened]: { [number]: true } }

-- Hammer's per-axis vertex match tolerance: 1 Hammer unit.
local TOLERANCE = Units.studs(1)
local MAX_CORNER_FACES = 16
local MAX_T_FACES = 8
local MAX_EDGE_FACES = 3
-- Threshold below which a vertex is treated as unchanged so re-sewing an already sewn seam does not unbake.
local SAME = 1e-5

-- Stored displacement fields for one vertex (vectors are in local or world space per caller).
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
	-- Flat world-space corners; points[1] corresponds to Hammer surface point 0.
	points: { Vector3 },
	boundsMin: Vector3,
	boundsMax: Vector3,
	faceNormal: Vector3,
	-- Snapshot of each vertex before its first write, used to detect real changes.
	original: { [number]: Value },
}

type Entry = { face: Face, vertex: number, point: Vector3 }

-- Edge roles from compareEdges: 0 = full edge, 3 = long edge, 1/2 = first/second half of long edge.
type EdgeEntry = { face: Face, edge: number, role: number }

type Groups = {
	corners: { { Entry } },
	tPoints: { { Entry } },
	edges: { { EdgeEntry } },
	tooMany: boolean,
}

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

-- Grid helpers using Hammer's 0-based corners (0..3), edges (corner e to e+1), and edge steps
-- (0..n), returning 1-based vertex indices.
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

-- Vertex field accessors

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

-- Collects vertices that actually moved and restores sub-threshold vertices verbatim so floating-
-- point noise is neither reported nor persisted.
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

-- Sew primitives

-- Hammer's pair average: writes the mean field vector, mean offset, and renormalized sum of
-- offset normals to both vertices. Copies alpha from `faceA` when both materials match.
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

-- Interpolates vertex `m` between vertices `s` and `e` at parameter `t`. Because flat positions
-- and elevation vary linearly along an edge, `m` lands cleanly on the segment between them.
local function lerpInto(face: Face, s: number, e: number, m: number, t: number)
	local vs, ve = readLocal(face, s), readLocal(face, e)
	local vector, distance = Displacement.normalizeWithLength((vs.vector * vs.distance):Lerp(ve.vector * ve.distance, t))

	writeLocal(face, m, {
		vector = vector,
		distance = distance,
		offset = vs.offset:Lerp(ve.offset, t),
		-- Left unnormalized, matching Hammer.
		offsetNormal = vs.offsetNormal:Lerp(ve.offsetNormal, t),
		alpha = vs.alpha + (ve.alpha - vs.alpha) * t,
	})
end

-- Writes the plain mean of every field across `entries`. Vector and distance are averaged
-- independently without renormalizing, matching Hammer.
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

-- Edge and corner matching

-- Compares edges (a0, a1) and (b0, b1) by endpoints and midpoints, returning their EdgeEntry
-- roles or (nil, 0) if unrelated. Midpoint-to-midpoint is excluded so only full edges and 2:1
-- half edges match.
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

-- Indexes `group` under `face` so deduplication scans only groups involving nearby faces.
local function indexGroup<T>(byFace: { [Face]: { T } }, face: Face, group: T)
	local list = byFace[face]

	if list then
		table.insert(list, group)
	else
		byFace[face] = { group }
	end
end

-- Builds a corner or T-junction group around `point` on `face`.
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

-- Appends `group` unless an existing group already covers its first entry's point. Any such
-- group necessarily contains `group[1].face`, so checking `byFace[group[1].face]` suffices.
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

-- Builds Hammer's corner, T-junction, and edge groups across `faces` in order (first face to
-- visit a shared spot owns its group). `near[face]` lists touching neighbor faces in the same order.
local function buildGroups(faces: { Face }, near: { [Face]: { Face } }): Groups
	local groups: Groups = { corners = {}, tPoints = {}, edges = {}, tooMany = false }

	-- Shared corners.
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

	-- T-junctions: edge midpoints coinciding with corners of neighboring faces.
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

	-- Full edges and 2:1 T-edge groups (one long edge plus up to one half edge per side).
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
				-- Skip full edges already covered by an existing group on this or a nearby face.
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

				-- Merge into an existing T-edge group sharing the same long edge, if found.
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

-- Edge sewing

-- Interpolates edge vertices between multiples of `step` over [from, to] (defaulting to [0, n]).
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
	-- Lower-power side goes first so it supplies alpha; ties keep entry order.
	local low, high = x, y

	if y.face.n < x.face.n then
		low, high = y, x
	end

	local nLow, nHigh = low.face.n, high.face.n
	local ratio = nHigh // nLow
	-- Match by actual geometric edge direction (see module header).
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

-- Sews half edge `half` to either the first or second half of `long`.
local function sewTEdge(long: EdgeEntry, half: EdgeEntry, firstHalf: boolean)
	local nLong, nHalf = long.face.n, half.face.n
	local hLong = nLong // 2
	local base = if firstHalf then 0 else hLong
	local halfStart = if firstHalf then edgeStart(long.face, long.edge) else edgeMid(long.face, long.edge)
	local forward = samePoint(edgeStart(half.face, half.edge), halfStart)

	-- Maps a shared long-edge step `j` to the corresponding step on `half`.
	local function halfStep(j: number): number
		local k = (j - base) * nHalf // hLong

		return if forward then k else nHalf - k
	end

	if nHalf >= hLong then
		-- Half edge is equally dense or denser: pair along the long edge's interior vertices,
		-- then interpolate the half edge between them.
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
		-- Long edge is denser: pair every half-edge vertex from the far corner through the
		-- T-junction, then interpolate only this half of the long edge (avoiding Hammer's bug of
		-- re-interpolating the other half and reopening its seam).
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

-- Public API

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

-- Sews `targets` in order (determining group ownership, matching Hammer's selection order).
-- Updates vertex data in place and returns modified vertices per tile plus an optional warning
-- if any corner, T-junction, or edge exceeded Hammer's face limits. When `focus` is provided,
-- only groups touching a focused tile are sewn (used by autosew).
function Sew.sew(targets: { Opened }, focus: { [Opened]: true }?): (Changes, string?)
	local all: { Face } = table.create(#targets)

	for i, opened in targets do
		all[i] = buildFace(opened)
	end

	-- When focused, narrow to faces whose bounds touch at least one focused face.
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
