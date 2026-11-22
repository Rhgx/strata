--!strict
--[[
	Source-style displacement data model and surface math.

	A displacement turns a 4-sided face into a square grid with (2^power + 1) vertices per side.
	Each vertex stores a normal (the field vector: a direction, usually unit length but zero on
	untouched vertices and non-unit after some sews), a distance along it, an offset vector, an
	offset normal, and an alpha (corresponding to VMF normals, distances, offsets, offset_normals,
	and alphas). The `subdiv` flag is set by Subdivide (VMF subdiv). Surface positions follow
	Source's CCoreDispInfo::GenerateDispSurf:

		flat     = bilinear position across the 4 corners
		position = flat + normal * distance + offset + faceNormal * elevation

	All positions are local to the owning model's pivot so moving the model in Studio does not
	invalidate stored data.

	Painted materials (a Strata addition for the Material tool) are stored per grid triangle:
	each triangle displays look 0 (the tile's base material, color, and variant), a painted look
	from `looks`, or a hole (deleted: neither shown nor baked, while vertices remain intact).
	Hammer instead blends two textures via per-vertex alpha; Roblox parts cannot blend textures
	and a triangle is the smallest renderable unit, so `alphas` remains unused.

	Corner order follows Source's surface points: rows run from corners[1] to corners[2] (and
	corners[4] to corners[3] on the opposite side), while columns run from the corners[1]/corners[2]
	edge to the corners[4]/corners[3] edge. Vertex indices are 1-based and row-major:
	index = row * size + col + 1.
]]

local HttpService = game:GetService("HttpService")

local Mesh = require(script.Parent.Mesh)

local Displacement = {}

-- A material, color, and material variant (empty string for the base material).
export type Look = {
	material: Enum.Material,
	color: Color3,
	variant: string,
}

export type Displacement = {
	power: number,
	-- Vertices per side (2^power + 1).
	size: number,
	corners: { Vector3 },
	elevation: number,
	normals: { Vector3 },
	distances: { number },
	offsets: { Vector3 },
	-- Per-vertex subdivision normal, used as the Curved paint axis and Noise fallback direction.
	offsetNormals: { Vector3 },
	alphas: { number },
	-- Set once Subdivide has written offsets.
	subdiv: boolean,
	material: Enum.Material,
	color: Color3,
	-- MaterialVariant name from MaterialService, or empty string for the base material.
	materialVariant: string,
	-- Painted look palette; triangle look k (>= 1) indexes `looks[k]`.
	looks: { Look },
	-- Per grid triangle: 0 for the tile's base look, HOLE for a deleted triangle, or an index into `looks`.
	triLooks: { number },
	-- Grid vertices removed in Simplify mode (never the 4 corners). Vertex data stays intact so
	-- restoring a vertex is lossless.
	removed: { [number]: true },
	-- Cached triangulation of kept vertices while points are removed, built lazily by `mesh`.
	meshCache: Mesh.Mesh?,
}

-- Maximum painted looks per tile (each encoded as one character in TriLooks).
Displacement.MAX_LOOKS = 35
-- Sentinel for a deleted triangle (neither rendered nor baked). Vertices stay intact so sewing,
-- stitching, and sculpt brushes continue to work and restoring recovers the exact geometry.
Displacement.HOLE = -1

local LOOK_DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local HOLE_DIGIT = "-"
-- Increment when serialized DispData changes incompatibly (pre-release data is migrated manually).
local FORMAT_VERSION = 1

local function sizeForPower(power: number): number
	return bit32.lshift(1, power) + 1
end

local function isValidPower(power: number): boolean
	return power == 2 or power == 3 or power == 4
end

local function computeFaceNormal(corners: { Vector3 }): Vector3
	local normal = (corners[2] - corners[1]):Cross(corners[4] - corners[1])

	if normal.Magnitude < 1e-9 then
		error("displacement corners are degenerate (zero-area face)")
	end

	return normal.Unit
end

function Displacement.new(corners: { Vector3 }, power: number, material: Enum.Material, color: Color3): Displacement
	if #corners ~= 4 then
		error("a displacement needs exactly 4 corners")
	end

	if not isValidPower(power) then
		error(`displacement power must be 2, 3 or 4 (got {power})`)
	end

	-- Match Hammer's defaults for a new displacement: zero field vector, zero distance, zero
	-- offset, face normal as offset normal, and zero alpha.
	local size = sizeForPower(power)
	local count = size * size

	return {
		power = power,
		size = size,
		corners = table.clone(corners),
		elevation = 0,
		normals = table.create(count, Vector3.zero),
		distances = table.create(count, 0),
		offsets = table.create(count, Vector3.zero),
		offsetNormals = table.create(count, computeFaceNormal(corners)),
		alphas = table.create(count, 0),
		subdiv = false,
		material = material,
		color = color,
		materialVariant = "",
		looks = {},
		triLooks = table.create((size - 1) * (size - 1) * 2, 0),
		removed = {},
		meshCache = nil,
	}
end

function Displacement.faceNormal(disp: Displacement): Vector3
	return computeFaceNormal(disp.corners)
end

-- Implements Hammer's start corner rule (GenerateSurfPointStartIndex): selects the corner
-- closest to the componentwise minimum of the 4 points, breaking ties by lowest index. Pass
-- `points` in Hammer axes (Units.toHammer) to match Hammer's grid orientation. Returns 1 to 4.
function Displacement.startCorner(points: { Vector3 }): number
	-- Hammer initializes its minimum at 99999, which is past any Hammer map (~6,250 studs in
	-- Roblox). Using math.huge matches Hammer inside that range and still works beyond it.
	local min = Vector3.new(math.huge, math.huge, math.huge)

	for _, point in points do
		min = min:Min(point)
	end

	local best, bestDistance = 1, math.huge

	for k, point in points do
		local offset = point - min
		local distance = offset:Dot(offset)

		if distance < bestDistance then
			best, bestDistance = k, distance
		end
	end

	return best
end

-- Rotates `corners` cyclically so `start` becomes index 1 while preserving winding order.
function Displacement.rotateCorners(corners: { Vector3 }, start: number): { Vector3 }
	local result = table.create(4)

	for k = 1, 4 do
		result[k] = corners[(k + start - 2) % 4 + 1]
	end

	return result
end

function Displacement.vertexCount(disp: Displacement): number
	return disp.size * disp.size
end

function Displacement.flatPosition(disp: Displacement, index: number): Vector3
	local k = index - 1
	local row = k // disp.size
	local col = k % disp.size
	local step = 1 / (disp.size - 1)
	local c = disp.corners
	local rowStart = c[1]:Lerp(c[2], row * step)
	local rowEnd = c[4]:Lerp(c[3], row * step)

	return rowStart:Lerp(rowEnd, col * step)
end

function Displacement.position(disp: Displacement, index: number, faceNormal: Vector3?): Vector3
	local up = faceNormal or computeFaceNormal(disp.corners)

	return Displacement.flatPosition(disp, index)
		+ disp.normals[index] * disp.distances[index]
		+ disp.offsets[index]
		+ up * disp.elevation
end

function Displacement.positions(disp: Displacement, faceNormal: Vector3?): { Vector3 }
	local up = faceNormal or computeFaceNormal(disp.corners)
	local count = disp.size * disp.size
	local result = table.create(count)

	for index = 1, count do
		result[index] = Displacement.position(disp, index, up)
	end

	return result
end

-- Moves a vertex to a local position by updating its displacement field vector while preserving
-- offset and elevation (matches Source SDK CCoreDispInfo::Position_Update).
function Displacement.setPosition(disp: Displacement, index: number, position: Vector3, faceNormal: Vector3?)
	local up = faceNormal or computeFaceNormal(disp.corners)
	local vector = position - Displacement.flatPosition(disp, index) - disp.offsets[index] - up * disp.elevation

	Displacement.setFieldVector(disp, index, vector)
end

-- Returns the combined displacement vector (normal * distance) edited by Hammer's paint tools.
function Displacement.fieldVector(disp: Displacement, index: number): Vector3
	return disp.normals[index] * disp.distances[index]
end

-- Matches Source's VectorNormalize: adding 1e-10 keeps zero vectors finite, returning direction
-- (0, 0, 0) with length 1e-5 instead of dividing by zero.
function Displacement.normalizeWithLength(vector: Vector3): (Vector3, number)
	local lengthSquared = vector:Dot(vector) + 1e-10
	local inverse = 1 / math.sqrt(lengthSquared)

	return vector * inverse, lengthSquared * inverse
end

-- Decomposes a displacement vector into a unit normal and non-negative distance, matching Hammer's VMF storage.
function Displacement.setFieldVector(disp: Displacement, index: number, vector: Vector3)
	disp.normals[index], disp.distances[index] = Displacement.normalizeWithLength(vector)
end

--[[
	Two triangle numberings exist:
	- Grid triangles: Hammer's fixed checkerboard where painted looks and holes are stored.
	- Shown triangles: the triangles actually rendered (grid triangles when intact, or the Mesh
	  Delaunay triangulation when points are removed). Wedges, baking, raycasts, and brush updates
	  all use shown triangles.
]]

function Displacement.gridTriangleCount(disp: Displacement): number
	local quads = disp.size - 1

	return quads * quads * 2
end

-- Returns the 3 vertex indices of 1-based grid triangle `t`. Each quad holds triangles 2q + 1
-- and 2q + 2 with alternating checkerboard diagonals matching Source SDK
-- CCoreDispInfo::BuildTriBLtoTR / BuildTriTLtoBR (even quads split 00-11; odd quads split 01-10).
function Displacement.gridTriangle(disp: Displacement, t: number): (number, number, number)
	local quadsPerSide = disp.size - 1
	local q = (t - 1) // 2
	local row = q // quadsPerSide
	local col = q % quadsPerSide
	local isFirst = (t - 1) % 2 == 0

	local v00 = row * disp.size + col + 1
	local v01 = v00 + 1
	local v10 = v00 + disp.size
	local v11 = v10 + 1

	if (row + col) % 2 == 0 then
		if isFirst then
			return v00, v10, v11
		end

		return v00, v11, v01
	end

	if isFirst then
		return v00, v10, v01
	end

	return v01, v10, v11
end

-- Removed points

function Displacement.isCorner(disp: Displacement, index: number): boolean
	local n = disp.size - 1

	return index == 1 or index == n + 1 or index == n * disp.size + 1 or index == n * disp.size + n + 1
end

function Displacement.isRemoved(disp: Displacement, index: number): boolean
	return disp.removed[index] == true
end

-- Marks or unmarks a vertex as removed (corners cannot be removed). Returns whether state changed.
function Displacement.setRemoved(disp: Displacement, index: number, removed: boolean): boolean
	if removed == (disp.removed[index] == true) or (removed and Displacement.isCorner(disp, index)) then
		return false
	end

	if removed then
		disp.removed[index] = true
	else
		disp.removed[index] = nil
	end

	disp.meshCache = nil
	return true
end

-- Returns the cached triangulation of kept points, or nil when no points are removed.
function Displacement.mesh(disp: Displacement): Mesh.Mesh?
	if next(disp.removed) == nil then
		return nil
	end

	local cached = disp.meshCache

	if cached then
		return cached
	end

	local c = disp.corners
	local n = disp.size - 1
	local built = Mesh.build(disp.size, disp.removed, (c[2] - c[1]).Magnitude / n, (c[4] - c[1]).Magnitude / n)
	disp.meshCache = built

	return built
end

-- Projects every removed vertex onto the surface defined by the kept vertices so removed points
-- never hold stale heights: restoring a vertex after sculpting places it on the current surface
-- rather than creating a spike, and smoothing reads the displayed surface. Returns moved vertices.
function Displacement.reproject(disp: Displacement, faceNormal: Vector3?): { [number]: true }
	local moved: { [number]: true } = {}
	local mesh = Displacement.mesh(disp)

	if not mesh then
		return moved
	end

	local up = faceNormal or computeFaceNormal(disp.corners)

	for v, on in mesh.removedOn do
		local tri = mesh.triangles[on.triangle]
		local target = Displacement.position(disp, tri[1], up) * on.w1
			+ Displacement.position(disp, tri[2], up) * on.w2
			+ Displacement.position(disp, tri[3], up) * on.w3

		if (Displacement.position(disp, v, up) - target).Magnitude > 1e-5 then
			Displacement.setPosition(disp, v, target, up)
			moved[v] = true
		end
	end

	return moved
end

-- Shown triangles

function Displacement.triangleCount(disp: Displacement): number
	local mesh = Displacement.mesh(disp)

	return if mesh then #mesh.triangles else Displacement.gridTriangleCount(disp)
end

function Displacement.triangle(disp: Displacement, t: number): (number, number, number)
	local mesh = Displacement.mesh(disp)

	if mesh then
		local tri = mesh.triangles[t]

		return tri[1], tri[2], tri[3]
	end

	return Displacement.gridTriangle(disp, t)
end

-- Returns the grid triangle beneath the centroid of shown triangle `tri`.
local function gridUnderCenter(disp: Displacement, tri: { number }): number
	local size = disp.size
	local row = ((tri[1] - 1) // size + (tri[2] - 1) // size + (tri[3] - 1) // size) / 3
	local col = ((tri[1] - 1) % size + (tri[2] - 1) % size + (tri[3] - 1) % size) / 3

	return Displacement.triangleAt(disp, row, col)
end

-- Returns the grid triangles represented by shown triangle `t`: those whose centroids it covers,
-- or the single grid triangle beneath its own centroid when it covers none (a thin sliver).
function Displacement.coverOf(disp: Displacement, t: number): { number }
	local mesh = Displacement.mesh(disp)

	if not mesh then
		return { t }
	end

	local cover = mesh.cover[t]

	return if #cover > 0 then cover else { gridUnderCenter(disp, mesh.triangles[t]) }
end

-- Returns the shown triangle covering the centroid of grid triangle `g`.
function Displacement.shownOf(disp: Displacement, g: number): number
	local mesh = Displacement.mesh(disp)

	return if mesh then mesh.shownOf[g] else g
end

-- Returns every shown triangle incident to at least one vertex in `vertices`.
function Displacement.trianglesTouching(disp: Displacement, vertices: { [number]: true }): { number }
	local mesh = Displacement.mesh(disp)

	if mesh then
		local seen: { [number]: true } = {}
		local result = {}

		for index in vertices do
			local touching = mesh.vertexTriangles[index]

			if touching then
				for _, t in touching do
					if not seen[t] then
						seen[t] = true
						table.insert(result, t)
					end
				end
			end
		end

		return result
	end

	local size = disp.size
	local quadsPerSide = size - 1
	local seen: { [number]: true } = {}
	local result = {}

	for index in vertices do
		local k = index - 1
		local row = k // size
		local col = k % size

		for qr = math.max(row - 1, 0), math.min(row, quadsPerSide - 1) do
			for qc = math.max(col - 1, 0), math.min(col, quadsPerSide - 1) do
				local q = qr * quadsPerSide + qc

				if not seen[q] then
					seen[q] = true
					table.insert(result, q * 2 + 1)
					table.insert(result, q * 2 + 2)
				end
			end
		end
	end

	return result
end

-- Returns the grid triangle covering `(row, col)` in grid coordinates (0 to size - 1 along rows
-- and columns), matching the checkerboard diagonal split of `Displacement.gridTriangle`.
function Displacement.triangleAt(disp: Displacement, row: number, col: number): number
	local quadsPerSide = disp.size - 1
	local r = math.clamp(math.floor(row), 0, quadsPerSide - 1)
	local c = math.clamp(math.floor(col), 0, quadsPerSide - 1)
	local fr, fc = row - r, col - c
	local q = r * quadsPerSide + c
	local second

	if (r + c) % 2 == 0 then
		-- Split 00-11: first triangle (00, 10, 11) lies on the side toward the next row.
		second = fc > fr
	else
		-- Split 01-10: first triangle (00, 10, 01) lies on the side toward vertex 00.
		second = fr + fc > 1
	end

	return q * 2 + (if second then 2 else 1)
end

-- Painted materials

-- Compares colors at 8 bits per channel, matching Studio's display and serialization precision.
local function sameColor(a: Color3, b: Color3): boolean
	return math.round(a.R * 255) == math.round(b.R * 255)
		and math.round(a.G * 255) == math.round(b.G * 255)
		and math.round(a.B * 255) == math.round(b.B * 255)
end

function Displacement.sameLook(a: Look, b: Look): boolean
	return a.material == b.material and a.variant == b.variant and sameColor(a.color, b.color)
end

function Displacement.baseLook(disp: Displacement): Look
	return { material = disp.material, color = disp.color, variant = disp.materialVariant }
end

-- Returns the look index displayed by shown triangle `t`. When points are removed, a shown
-- triangle uses the majority look among the grid triangles it covers (ties prefer solid ground
-- over holes, then lower look indices), or the grid triangle under its centroid if it covers none.
function Displacement.shownLookIndex(disp: Displacement, t: number): number
	local mesh = Displacement.mesh(disp)

	if not mesh then
		return disp.triLooks[t]
	end

	local cover = mesh.cover[t]

	if #cover == 0 then
		return disp.triLooks[gridUnderCenter(disp, mesh.triangles[t])]
	end

	local counts: { [number]: number } = {}

	for _, g in cover do
		local index = disp.triLooks[g]
		counts[index] = (counts[index] or 0) + 1
	end

	local best, bestCount = 0, -1

	for index, count in counts do
		local better = count > bestCount
			or (count == bestCount and (best == Displacement.HOLE or (index ~= Displacement.HOLE and index < best)))

		if better then
			best, bestCount = index, count
		end
	end

	return best
end

-- Returns the Look for shown triangle `t` (falls back to baseLook for holes, which do not render).
function Displacement.lookOf(disp: Displacement, t: number): Look
	local index = Displacement.shownLookIndex(disp, t)

	if index > 0 then
		return disp.looks[index]
	end

	return Displacement.baseLook(disp)
end

function Displacement.isHole(disp: Displacement, t: number): boolean
	return Displacement.shownLookIndex(disp, t) == Displacement.HOLE
end

function Displacement.holeCount(disp: Displacement): number
	local count = 0

	for _, index in disp.triLooks do
		if index == Displacement.HOLE then
			count += 1
		end
	end

	return count
end

-- Finds or inserts `look` in `disp.looks`, returning 0 for the base look or nil if full (MAX_LOOKS).
function Displacement.lookIndex(disp: Displacement, look: Look): number?
	if Displacement.sameLook(look, Displacement.baseLook(disp)) then
		return 0
	end

	for index, existing in disp.looks do
		if Displacement.sameLook(existing, look) then
			return index
		end
	end

	if #disp.looks >= Displacement.MAX_LOOKS then
		return nil
	end

	table.insert(disp.looks, { material = look.material, color = look.color, variant = look.variant })
	return #disp.looks
end

-- Returns whether any grid triangle has a painted look (holes do not count as paint).
function Displacement.isPainted(disp: Displacement): boolean
	for _, index in disp.triLooks do
		if index > 0 then
			return true
		end
	end

	return false
end

-- Counts distinct rendered looks on the tile (base look counts once if used; holes do not count).
function Displacement.lookCount(disp: Displacement): number
	local used: { [number]: true } = { [Displacement.HOLE] = true }
	local count = 0

	for _, index in disp.triLooks do
		if not used[index] then
			used[index] = true
			count += 1
		end
	end

	return count
end

-- Removes unreferenced looks from `disp.looks` and renumbers `triLooks` in order of first use.
function Displacement.compactLooks(disp: Displacement)
	local remap: { [number]: number } = { [0] = 0, [Displacement.HOLE] = Displacement.HOLE }
	local looks: { Look } = {}

	for t, index in disp.triLooks do
		local mapped = remap[index]

		if not mapped then
			table.insert(looks, disp.looks[index])
			mapped = #looks
			remap[index] = mapped
		end

		disp.triLooks[t] = mapped
	end

	disp.looks = looks
end

-- Edges, corners, and resampling

export type Edge = {
	-- Corner indices (1 to 4) at each endpoint.
	from: number,
	to: number,
	-- Vertex indices ordered along the edge from `from` to `to`.
	indices: { number },
}

function Displacement.cornerVertex(disp: Displacement, corner: number): number
	local size = disp.size

	if corner == 1 then
		return 1
	elseif corner == 2 then
		return (size - 1) * size + 1
	elseif corner == 3 then
		return size * size
	end

	return size
end

function Displacement.edges(disp: Displacement): { Edge }
	local size = disp.size
	local e12, e43, e14, e23 = {}, {}, {}, {}

	for k = 0, size - 1 do
		e12[k + 1] = k * size + 1
		e43[k + 1] = k * size + size
		e14[k + 1] = k + 1
		e23[k + 1] = (size - 1) * size + k + 1
	end

	return {
		{ from = 1, to = 2, indices = e12 },
		{ from = 4, to = 3, indices = e43 },
		{ from = 1, to = 4, indices = e14 },
		{ from = 2, to = 3, indices = e23 },
	}
end

-- Power changes
-- Hammer resamples each stored channel independently (normal, distance, offset, offsetNormal,
-- alpha), averaging normals as plain vectors without renormalizing.

local function averageNumbers(a: number, b: number): number
	return (a + b) * 0.5
end

local function averageVectors(a: Vector3, b: Vector3): Vector3
	return (a + b) * 0.5
end

local function addNumbers(a: number, b: number): number
	return a + b
end

local function addVectors(a: Vector3, b: Vector3): Vector3
	return a + b
end

local function scaleNumber(a: number, s: number): number
	return a * s
end

local function scaleVector(a: Vector3, s: number): Vector3
	return a * s
end

-- Upsamples one power level: existing vertices remain, edge midpoints average their 2 neighbors,
-- and cell centers average only the right and below neighbors (anti-diagonal), matching Hammer.
local function upsample<T>(old: { T }, oldSize: number, average: (T, T) -> T): { T }
	local newSize = oldSize * 2 - 1
	local result: { T } = table.create(newSize * newSize)

	for r = 0, oldSize - 1 do
		for c = 0, oldSize - 1 do
			local here = old[r * oldSize + c + 1]
			local base = 2 * r * newSize + 2 * c + 1
			result[base] = here

			local hasRight, hasBelow = c + 1 < oldSize, r + 1 < oldSize

			if hasRight then
				result[base + 1] = average(here, old[r * oldSize + c + 2])
			end

			if hasBelow then
				result[base + newSize] = average(here, old[(r + 1) * oldSize + c + 1])
			end

			if hasRight and hasBelow then
				result[base + newSize + 1] = average(old[r * oldSize + c + 2], old[(r + 1) * oldSize + c + 1])
			end
		end
	end

	return result
end

-- Downsamples one power level: each coarse vertex takes the mean of the 3x3 fine neighborhood
-- clipped to grid bounds, smoothing rather than decimating.
local function downsample<T>(old: { T }, oldSize: number, add: (T, T) -> T, scale: (T, number) -> T): { T }
	local newSize = (oldSize + 1) // 2
	local result: { T } = table.create(newSize * newSize)

	for i = 0, newSize - 1 do
		for j = 0, newSize - 1 do
			local r, c = 2 * i, 2 * j
			local sum = old[r * oldSize + c + 1]
			local count = 1

			for dr = -1, 1 do
				for dc = -1, 1 do
					local rr, cc = r + dr, c + dc

					if (dr ~= 0 or dc ~= 0) and rr >= 0 and rr < oldSize and cc >= 0 and cc < oldSize then
						sum = add(sum, old[rr * oldSize + cc + 1])
						count += 1
					end
				end
			end

			result[i * newSize + j + 1] = scale(sum, 1 / count)
		end
	end

	return result
end

local function withPower(disp: Displacement, power: number): Displacement
	return {
		power = power,
		size = sizeForPower(power),
		corners = table.clone(disp.corners),
		elevation = disp.elevation,
		normals = disp.normals,
		distances = disp.distances,
		offsets = disp.offsets,
		offsetNormals = disp.offsetNormals,
		alphas = disp.alphas,
		subdiv = disp.subdiv,
		material = disp.material,
		color = disp.color,
		materialVariant = disp.materialVariant,
		looks = table.clone(disp.looks),
		triLooks = disp.triLooks,
		removed = {},
		meshCache = nil,
	}
end

-- Resamples removed vertices one power up or down. Upsampling preserves existing marks and marks
-- new intermediate points as removed whenever an adjacent old point is removed, keeping
-- simplified regions coarse. Downsampling keeps a point removed if its corresponding fine vertex
-- was removed. Corners are never removed.
local function resampleRemoved(old: Displacement, result: Displacement): { [number]: true }
	local removed: { [number]: true } = {}

	if next(old.removed) == nil then
		return removed
	end

	local oldSize, size = old.size, result.size

	for row = 0, size - 1 do
		for col = 0, size - 1 do
			local v = row * size + col + 1

			if Displacement.isCorner(result, v) then
				continue
			end

			local isRemoved = false

			if size > oldSize then
				-- Check the surrounding coarse vertices (or the exact aligned vertex).
				local r0, r1 = row // 2, (row + 1) // 2
				local c0, c1 = col // 2, (col + 1) // 2

				for r = r0, r1 do
					for c = c0, c1 do
						if old.removed[r * oldSize + c + 1] then
							isRemoved = true
						end
					end
				end
			else
				isRemoved = old.removed[(row * 2) * oldSize + col * 2 + 1] == true
			end

			if isRemoved then
				removed[v] = true
			end
		end
	end

	return removed
end

-- Resamples painted looks and holes to `result` by sampling the old grid triangle at each new
-- triangle's flat-space centroid.
local function resampleLooks(old: Displacement, result: Displacement): { number }
	local count = Displacement.gridTriangleCount(result)

	if not Displacement.isPainted(old) and Displacement.holeCount(old) == 0 then
		return table.create(count, 0)
	end

	local scale = (old.size - 1) / (result.size - 1)
	local coarser = result.size < old.size
	local looks = table.create(count, 0)

	for t = 1, count do
		local i1, i2, i3 = Displacement.gridTriangle(result, t)
		local rows = { (i1 - 1) // result.size, (i2 - 1) // result.size, (i3 - 1) // result.size }
		local cols = { (i1 - 1) % result.size, (i2 - 1) % result.size, (i3 - 1) % result.size }
		local row = (rows[1] + rows[2] + rows[3]) / 3
		local col = (cols[1] + cols[2] + cols[3]) / 3
		local index = old.triLooks[Displacement.triangleAt(old, row * scale, col * scale)]

		-- When downsampling, if the centroid hits a hole, check midpoints toward each corner so
		-- narrow strips of solid ground are not erased.
		if coarser and index == Displacement.HOLE then
			for k = 1, 3 do
				local r, c = (row + rows[k]) / 2, (col + cols[k]) / 2
				local other = old.triLooks[Displacement.triangleAt(old, r * scale, c * scale)]

				if other ~= Displacement.HOLE then
					index = other
					break
				end
			end
		end

		looks[t] = index
	end

	return looks
end

local function powerUp(disp: Displacement): Displacement
	local size = disp.size
	local result = withPower(disp, disp.power + 1)

	result.normals = upsample(disp.normals, size, averageVectors)
	result.distances = upsample(disp.distances, size, averageNumbers)
	result.offsets = upsample(disp.offsets, size, averageVectors)
	result.offsetNormals = upsample(disp.offsetNormals, size, averageVectors)
	result.alphas = upsample(disp.alphas, size, averageNumbers)
	result.triLooks = resampleLooks(disp, result)
	result.removed = resampleRemoved(disp, result)
	return result
end

-- Deliberately accumulates distances as floats rather than Hammer's truncating integer sum,
-- which only loses precision.
local function powerDown(disp: Displacement): Displacement
	local size = disp.size
	local result = withPower(disp, disp.power - 1)

	result.normals = downsample(disp.normals, size, addVectors, scaleVector)
	result.distances = downsample(disp.distances, size, addNumbers, scaleNumber)
	result.offsets = downsample(disp.offsets, size, addVectors, scaleVector)
	result.offsetNormals = downsample(disp.offsetNormals, size, addVectors, scaleVector)
	result.alphas = downsample(disp.alphas, size, addNumbers, scaleNumber)
	result.triLooks = resampleLooks(disp, result)
	result.removed = resampleRemoved(disp, result)
	return result
end

-- Returns a resampled copy at `power`, stepping one level at a time like Hammer (e.g. 4 -> 2
-- filters twice). Returns `disp` directly when already at `power`.
function Displacement.changePower(disp: Displacement, power: number): Displacement
	if not isValidPower(power) then
		error(`displacement power must be 2, 3 or 4 (got {power})`)
	end

	local result = disp

	if result.power ~= power then
		-- Reproject removed vertices so the displayed surface carries into the new grid.
		Displacement.reproject(disp)
	end

	while result.power < power do
		result = powerUp(result)
	end

	while result.power > power do
		result = powerDown(result)
	end

	return result
end

-- Splitting

export type Quarter = {
	disp: Displacement,
	-- Center of the quarter's flat face in the parent's local space; quarter corners are relative to it.
	center: Vector3,
	-- 1 or 2 along rows (corner 1 to corner 2) and along columns.
	row: number,
	col: number,
}

-- Losslessly splits a power 3 or 4 displacement into 2x2 quarters one power lower. Each quarter
-- of a (2^p + 1) grid is an exact (2^(p-1) + 1) subgrid with even origin offsets, preserving
-- every vertex and checkerboard diagonal. Power 2 cannot split (power 1 is below Hammer's minimum).
function Displacement.split(disp: Displacement): { Quarter }
	if disp.power < 3 then
		error("only power 3 and 4 displacements can be split")
	end

	-- Reproject removed points so any that become quarter corners land on the displayed surface.
	Displacement.reproject(disp)

	local half = (disp.size - 1) // 2
	local childSize = half + 1
	local c = disp.corners

	-- Same bilinear map as flatPosition (u along rows, v along columns).
	local function at(u: number, v: number): Vector3
		return c[1]:Lerp(c[2], u):Lerp(c[4]:Lerp(c[3], u), v)
	end

	local quarters: { Quarter } = {}

	for qi = 0, 1 do
		for qj = 0, 1 do
			local u0, u1, v0, v1 = qi * 0.5, (qi + 1) * 0.5, qj * 0.5, (qj + 1) * 0.5
			local corners = { at(u0, v0), at(u1, v0), at(u1, v1), at(u0, v1) }
			local center = (corners[1] + corners[2] + corners[3] + corners[4]) / 4

			for k = 1, 4 do
				corners[k] -= center
			end

			local child = Displacement.new(corners, disp.power - 1, disp.material, disp.color)
			child.elevation = disp.elevation
			child.subdiv = disp.subdiv
			child.materialVariant = disp.materialVariant

			for r = 0, half do
				for col = 0, half do
					local source = (qi * half + r) * disp.size + (qj * half + col) + 1
					local target = r * childSize + col + 1

					child.normals[target] = disp.normals[source]
					child.distances[target] = disp.distances[source]
					child.offsets[target] = disp.offsets[source]
					child.offsetNormals[target] = disp.offsetNormals[source]
					child.alphas[target] = disp.alphas[source]

					-- Preserve removed points except where they become a quarter corner.
					if disp.removed[source] and not Displacement.isCorner(child, target) then
						child.removed[target] = true
					end
				end
			end

			-- Each quarter quad aligns with a parent quad (identical checkerboard parity), so
			-- painted looks and holes copy triangle for triangle.
			child.looks = table.clone(disp.looks)

			for r = 0, half - 1 do
				for col = 0, half - 1 do
					local parentQuad = (qi * half + r) * (disp.size - 1) + (qj * half + col)
					local childQuad = r * half + col
					child.triLooks[childQuad * 2 + 1] = disp.triLooks[parentQuad * 2 + 1]
					child.triLooks[childQuad * 2 + 2] = disp.triLooks[parentQuad * 2 + 2]
				end
			end

			Displacement.compactLooks(child)
			table.insert(quarters, { disp = child, center = center, row = qi + 1, col = qj + 1 })
		end
	end

	return quarters
end

-- Serialization to Configuration attributes

local function formatNumber(value: number): string
	return string.format("%.6g", value)
end

local function encodeNumbers(values: { number }): string
	local parts = table.create(#values)

	for i, value in values do
		parts[i] = formatNumber(value)
	end

	return table.concat(parts, ",")
end

local function encodeVectors(values: { Vector3 }): string
	local parts = table.create(#values * 3)

	for i, value in values do
		parts[i * 3 - 2] = formatNumber(value.X)
		parts[i * 3 - 1] = formatNumber(value.Y)
		parts[i * 3] = formatNumber(value.Z)
	end

	return table.concat(parts, ",")
end

local function decodeNumbers(text: string, expected: number, name: string): { number }
	local items = string.split(text, ",")

	if #items ~= expected then
		error(`DispData.{name}: expected {expected} values, got {#items}`)
	end

	local values = table.create(expected)

	for i, item in items do
		local value = tonumber(item)

		if value == nil then
			error(`DispData.{name}: value {i} ("{item}") is not a number`)
		end

		values[i] = value
	end

	return values
end

local function decodeVectors(text: string, expected: number, name: string): { Vector3 }
	local numbers = decodeNumbers(text, expected * 3, name)
	local values = table.create(expected)

	for i = 1, expected do
		values[i] = Vector3.new(numbers[i * 3 - 2], numbers[i * 3 - 1], numbers[i * 3])
	end

	return values
end

local function readNumber(config: Configuration, name: string): number
	local value = config:GetAttribute(name)

	if typeof(value) ~= "number" then
		error(`DispData is missing number attribute "{name}"`)
	end

	return value
end

local function readString(config: Configuration, name: string): string
	local value = config:GetAttribute(name)

	if typeof(value) ~= "string" then
		error(`DispData is missing string attribute "{name}"`)
	end

	return value
end

local function readVector3(config: Configuration, name: string): Vector3
	local value = config:GetAttribute(name)

	if typeof(value) ~= "Vector3" then
		error(`DispData is missing Vector3 attribute "{name}"`)
	end

	return value
end

local function readColor3(config: Configuration, name: string): Color3
	local value = config:GetAttribute(name)

	if typeof(value) ~= "Color3" then
		error(`DispData is missing Color3 attribute "{name}"`)
	end

	return value
end

local function materialFromName(name: string): Enum.Material
	local item = Enum.Material:FromName(name)

	if not item then
		error(`DispData.Material: unknown material "{name}"`)
	end

	return item
end

local function allNumbers(values: { number }, default: number): boolean
	for _, value in values do
		if value ~= default then
			return false
		end
	end

	return true
end

local function allVectors(values: { Vector3 }, default: Vector3): boolean
	for _, value in values do
		if value ~= default then
			return false
		end
	end

	return true
end

-- Omits attributes whose values are all default so flat and unsubdivided tiles keep place files small.
local function saveNumbers(config: Configuration, name: string, values: { number }, default: number)
	config:SetAttribute(name, if allNumbers(values, default) then nil else encodeNumbers(values))
end

local function saveVectors(config: Configuration, name: string, values: { Vector3 }, default: Vector3)
	config:SetAttribute(name, if allVectors(values, default) then nil else encodeVectors(values))
end

-- Saves painted looks as JSON ("Looks") and one character per triangle ("TriLooks": 0 for base,
-- 1-9 and a-z for palette entries, "-" for holes). Both attributes are omitted on unpainted,
-- hole-free tiles; tiles with only holes save an empty palette. Compacts unused looks first so
-- baked union names (numbered by look index) always match the saved palette.
local function saveLooks(disp: Displacement, config: Configuration)
	Displacement.compactLooks(disp)

	if #disp.looks == 0 and Displacement.holeCount(disp) == 0 then
		config:SetAttribute("Looks", nil)
		config:SetAttribute("TriLooks", nil)
		return
	end

	local palette = table.create(#disp.looks)

	for i, look in disp.looks do
		palette[i] = { m = look.material.Name, c = look.color:ToHex(), v = look.variant }
	end

	local digits = table.create(#disp.triLooks)

	for t, index in disp.triLooks do
		digits[t] = if index == Displacement.HOLE then HOLE_DIGIT else string.sub(LOOK_DIGITS, index + 1, index + 1)
	end

	config:SetAttribute("Looks", HttpService:JSONEncode(palette))
	config:SetAttribute("TriLooks", table.concat(digits))
end

local function loadLooks(config: Configuration, triangleCount: number): ({ Look }, { number })
	local paletteText = config:GetAttribute("Looks")
	local digitsText = config:GetAttribute("TriLooks")

	if paletteText == nil and digitsText == nil then
		return {}, table.create(triangleCount, 0)
	end

	if typeof(paletteText) ~= "string" or typeof(digitsText) ~= "string" then
		error(`DispData needs both "Looks" and "TriLooks" as strings, or neither`)
	end

	local decoded: unknown = HttpService:JSONDecode(paletteText)

	if typeof(decoded) ~= "table" then
		error(`DispData.Looks is not a list`)
	end

	local looks: { Look } = {}

	for i, entry: unknown in decoded :: { unknown } do
		if typeof(entry) ~= "table" then
			error(`DispData.Looks entry {i} is not an object`)
		end

		local fields = entry :: { [string]: unknown }
		local name, hex, variant = fields.m, fields.c, fields.v

		if typeof(name) ~= "string" or typeof(hex) ~= "string" or typeof(variant) ~= "string" then
			error(`DispData.Looks entry {i} needs string fields m, c and v`)
		end

		local ok, color = pcall(Color3.fromHex, hex)

		if not ok then
			error(`DispData.Looks entry {i} has an invalid color "{hex}"`)
		end

		looks[i] = { material = materialFromName(name), color = color, variant = variant }
	end

	if #digitsText ~= triangleCount then
		error(`DispData.TriLooks: expected {triangleCount} characters, got {#digitsText}`)
	end

	local triLooks = table.create(triangleCount)

	for t = 1, triangleCount do
		local digit = string.sub(digitsText, t, t)

		if digit == HOLE_DIGIT then
			triLooks[t] = Displacement.HOLE
			continue
		end

		local index = (string.find(LOOK_DIGITS, digit, 1, true) or 0) - 1

		if index < 0 or index > #looks then
			error(`DispData.TriLooks: character {t} names a look that does not exist`)
		end

		triLooks[t] = index
	end

	return looks, triLooks
end

function Displacement.save(disp: Displacement, config: Configuration)
	config:SetAttribute("Version", FORMAT_VERSION)
	config:SetAttribute("Power", disp.power)
	config:SetAttribute("Elevation", disp.elevation)

	for k = 1, 4 do
		config:SetAttribute(`Corner{k}`, disp.corners[k])
	end

	config:SetAttribute("Material", disp.material.Name)
	config:SetAttribute("Color", disp.color)
	config:SetAttribute("MaterialVariant", if disp.materialVariant == "" then nil else disp.materialVariant)

	saveVectors(config, "Normals", disp.normals, Vector3.zero)
	saveNumbers(config, "Distances", disp.distances, 0)
	saveVectors(config, "Offsets", disp.offsets, Vector3.zero)
	saveVectors(config, "OffsetNormals", disp.offsetNormals, computeFaceNormal(disp.corners))
	saveNumbers(config, "Alphas", disp.alphas, 0)

	config:SetAttribute("Subdiv", disp.subdiv)
	saveLooks(disp, config)

	-- Encode removed vertices as one character per vertex ("1" = removed); omit when empty.
	if next(disp.removed) == nil then
		config:SetAttribute("Removed", nil)
	else
		local count = disp.size * disp.size
		local flags = table.create(count, "0")

		for v in disp.removed do
			flags[v] = "1"
		end

		config:SetAttribute("Removed", table.concat(flags))
	end
end

function Displacement.load(config: Configuration): Displacement
	local version = readNumber(config, "Version")

	if version ~= FORMAT_VERSION then
		error(`DispData version {version} is not supported (expected {FORMAT_VERSION})`)
	end

	local power = readNumber(config, "Power")

	if not isValidPower(power) then
		error(`DispData.Power must be 2, 3 or 4 (got {power})`)
	end

	local size = sizeForPower(power)
	local count = size * size
	local corners = table.create(4)

	for k = 1, 4 do
		corners[k] = readVector3(config, `Corner{k}`)
	end

	local faceNormal = computeFaceNormal(corners)
	local variant = config:GetAttribute("MaterialVariant")

	-- Missing array attributes expand to their uniform default values (see saveNumbers).
	local function numbers(name: string, default: number): { number }
		if config:GetAttribute(name) == nil then
			return table.create(count, default)
		end

		return decodeNumbers(readString(config, name), count, name)
	end

	local function vectors(name: string, default: Vector3): { Vector3 }
		if config:GetAttribute(name) == nil then
			return table.create(count, default)
		end

		return decodeVectors(readString(config, name), count, name)
	end

	local subdiv = config:GetAttribute("Subdiv")

	if typeof(subdiv) ~= "boolean" then
		error(`DispData is missing boolean attribute "Subdiv"`)
	end

	local looks, triLooks = loadLooks(config, (size - 1) * (size - 1) * 2)
	local removed: { [number]: true } = {}
	local flags = config:GetAttribute("Removed")

	if flags ~= nil then
		if typeof(flags) ~= "string" or #flags ~= count then
			error(`DispData.Removed must be a string of {count} characters`)
		end

		local n = size - 1

		for v = 1, count do
			local isCorner = v == 1 or v == n + 1 or v == n * size + 1 or v == count

			if string.sub(flags, v, v) == "1" and not isCorner then
				removed[v] = true
			end
		end
	end

	return {
		power = power,
		size = size,
		corners = corners,
		elevation = readNumber(config, "Elevation"),
		normals = vectors("Normals", Vector3.zero),
		distances = numbers("Distances", 0),
		offsets = vectors("Offsets", Vector3.zero),
		offsetNormals = vectors("OffsetNormals", faceNormal),
		alphas = numbers("Alphas", 0),
		subdiv = subdiv,
		material = materialFromName(readString(config, "Material")),
		color = readColor3(config, "Color"),
		-- Omitted when using the base material.
		materialVariant = if typeof(variant) == "string" then variant else "",
		looks = looks,
		triLooks = triLooks,
		removed = removed,
		meshCache = nil,
	}
end

return Displacement
