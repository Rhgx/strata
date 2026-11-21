--!strict
--[[
	Source-style displacement data and surface math.

	A displacement turns a 4-sided face into a square grid with (2^power + 1) vertices per side.
	Each vertex stores a normal (the field vector: a direction, usually unit length but zero on
	untouched vertices and non-unit after some sews), a distance along it, an offset vector, an
	offset normal and an alpha (the VMF normals, distances, offsets, offset_normals and alphas).
	The `subdiv` flag is set by Subdivide (VMF subdiv). Surface positions follow Source's
	CCoreDispInfo::GenerateDispSurf:

		flat     = bilinear position across the 4 corners
		position = flat + normal * distance + offset + faceNormal * elevation

	All positions are local to the owning model's pivot, so moving the model in Studio does not
	invalidate the data.

	Corner order follows Source's surface points: rows walk from corners[1] to corners[2] (and
	from corners[4] to corners[3] on the opposite edge); within a row, columns walk from the
	corners[1]/corners[2] edge to the corners[4]/corners[3] edge. Vertex indices are 1-based and
	row-major: index = row * size + col + 1.
]]

local Displacement = {}

export type Displacement = {
	power: number,
	-- Vertices per side.
	size: number,
	corners: { Vector3 },
	elevation: number,
	normals: { Vector3 },
	distances: { number },
	offsets: { Vector3 },
	-- Per-vertex subdivision normal: a paint axis and the Noise fallback direction.
	offsetNormals: { Vector3 },
	alphas: { number },
	-- Set once Subdivide has written offsets.
	subdiv: boolean,
	material: Enum.Material,
	color: Color3,
	-- A MaterialVariant name from MaterialService (custom materials), or empty for the base material.
	materialVariant: string,
}

-- Bump when saved data changes in a way old loaders cannot read (none yet: pre-release data is
-- converted by hand instead of kept loadable).
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

	-- Hammer's defaults for a new displacement: no field vector, no distance, no offset, the face
	-- normal as offset normal, alpha 0.
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
	}
end

function Displacement.faceNormal(disp: Displacement): Vector3
	return computeFaceNormal(disp.corners)
end

--[[
	Hammer's start corner rule (GenerateSurfPointStartIndex): the corner closest to the
	componentwise minimum of the 4 points, first one wins on ties. `points` should be in Hammer
	axes (Units.toHammer) so the same corner is chosen as in Hammer. Returns 1 to 4.
]]
function Displacement.startCorner(points: { Vector3 }): number
	-- Hammer starts from 99999, which is past any Hammer map but only about 6,250 studs in
	-- Roblox; math.huge gives the same result inside that range and keeps working beyond it.
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

-- The corners rotated so `start` becomes corner 1, keeping the winding.
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

-- Moves a vertex to a local position by rewriting its displacement vector, keeping the offset
-- and elevation. Same as CCoreDispInfo::Position_Update in the Source SDK.
function Displacement.setPosition(disp: Displacement, index: number, position: Vector3, faceNormal: Vector3?)
	local up = faceNormal or computeFaceNormal(disp.corners)
	local vector = position - Displacement.flatPosition(disp, index) - disp.offsets[index] - up * disp.elevation
	Displacement.setFieldVector(disp, index, vector)
end

-- The combined displacement vector (normal * distance), which is what Hammer's paint tools edit.
function Displacement.fieldVector(disp: Displacement, index: number): Vector3
	return disp.normals[index] * disp.distances[index]
end

-- Source's VectorNormalize: the 1e-10 keeps a zero vector finite, so it comes back as direction
-- (0, 0, 0) with length 1e-5 instead of dividing by zero.
function Displacement.normalizeWithLength(vector: Vector3): (Vector3, number)
	local lengthSquared = vector:Dot(vector) + 1e-10
	local inverse = 1 / math.sqrt(lengthSquared)
	return vector * inverse, lengthSquared * inverse
end

-- Stores a displacement vector back as a unit normal plus a non-negative distance, the same
-- split Hammer writes to the VMF.
function Displacement.setFieldVector(disp: Displacement, index: number, vector: Vector3)
	disp.normals[index], disp.distances[index] = Displacement.normalizeWithLength(vector)
end

function Displacement.triangleCount(disp: Displacement): number
	local quads = disp.size - 1
	return quads * quads * 2
end

--[[
	Returns the 3 vertex indices of triangle `t` (1-based). Each grid quad holds triangles
	2q + 1 and 2q + 2. The split diagonal alternates in a checkerboard (the diamond pattern);
	parity, diagonal and vertex order match CCoreDispInfo::BuildTriBLtoTR / BuildTriTLtoBR in
	the Source SDK (even quads split 00-11, odd quads split 01-10).
]]
function Displacement.triangle(disp: Displacement, t: number): (number, number, number)
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

-- Every triangle that uses at least one of the given vertices.
function Displacement.trianglesTouching(disp: Displacement, vertices: { [number]: true }): { number }
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

-- Edges, corners and resampling --------------------------------------------------------------

export type Edge = {
	-- Corner numbers (1 to 4) at each end.
	from: number,
	to: number,
	-- Vertex indices along the edge, ordered from `from` to `to`.
	indices: { number },
}

-- Vertex index of corner 1, 2, 3 or 4.
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

-- Power changes ---------------------------------------------------------------------------------
-- Hammer resamples every stored field on its own (normal, distance, offset, offset normal,
-- alpha), so the normal is averaged as a plain vector and not renormalized.

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

-- One level up: old vertices stay, edge midpoints average their 2 neighbors, and each cell
-- center averages only the old right and below neighbors (the anti-diagonal), like Hammer.
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

-- One level down: each new vertex is the plain mean of the 3x3 old block around its old
-- position, clipped to the grid, so lowering the power smooths rather than decimates.
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
	}
end

local function powerUp(disp: Displacement): Displacement
	local size = disp.size
	local result = withPower(disp, disp.power + 1)
	result.normals = upsample(disp.normals, size, averageVectors)
	result.distances = upsample(disp.distances, size, averageNumbers)
	result.offsets = upsample(disp.offsets, size, averageVectors)
	result.offsetNormals = upsample(disp.offsetNormals, size, averageVectors)
	result.alphas = upsample(disp.alphas, size, averageNumbers)
	return result
end

-- Hammer accumulates distances through an integer (dropping fractions); this keeps them as
-- floats on purpose, since that truncation only loses detail.
local function powerDown(disp: Displacement): Displacement
	local size = disp.size
	local result = withPower(disp, disp.power - 1)
	result.normals = downsample(disp.normals, size, addVectors, scaleVector)
	result.distances = downsample(disp.distances, size, addNumbers, scaleNumber)
	result.offsets = downsample(disp.offsets, size, addVectors, scaleVector)
	result.offsetNormals = downsample(disp.offsetNormals, size, addVectors, scaleVector)
	result.alphas = downsample(disp.alphas, size, addNumbers, scaleNumber)
	return result
end

-- Returns a copy at another power, stepping one level at a time like Hammer (so 4 -> 2 filters
-- twice). Returns `disp` itself when the power is already `power`.
function Displacement.changePower(disp: Displacement, power: number): Displacement
	if not isValidPower(power) then
		error(`displacement power must be 2, 3 or 4 (got {power})`)
	end
	local result = disp
	while result.power < power do
		result = powerUp(result)
	end
	while result.power > power do
		result = powerDown(result)
	end
	return result
end

-- Splitting --------------------------------------------------------------------------------------

export type Quarter = {
	disp: Displacement,
	-- Center of the quarter's flat face, in the parent's local space; the quarter's corners are
	-- relative to it.
	center: Vector3,
	-- 1 or 2 along the rows (corner 1 to corner 2) and along the columns.
	row: number,
	col: number,
}

-- Splits a displacement into 2x2 quarters one power lower. Lossless: each quarter of a
-- (2^p + 1) grid is exactly a (2^(p-1) + 1) grid, so every vertex is copied unchanged, and the
-- quarter offsets are even, so the checkerboard triangle split stays the same. Needs power 3 or
-- 4 (a power 2 quarter would be power 1, below Hammer's minimum).
function Displacement.split(disp: Displacement): { Quarter }
	if disp.power < 3 then
		error("only power 3 and 4 displacements can be split")
	end
	local half = (disp.size - 1) // 2
	local childSize = half + 1
	local c = disp.corners
	-- The flat face's bilinear map, the same one flatPosition uses (u along rows, v along columns).
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
				end
			end
			table.insert(quarters, { disp = child, center = center, row = qi + 1, col = qj + 1 })
		end
	end
	return quarters
end

-- Serialization to attributes on a Configuration ------------------------------------------

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

-- Writes a list, or removes it when every value is the default (the data ships with the place,
-- so this keeps flat and unsubdivided tiles small).
local function saveNumbers(config: Configuration, name: string, values: { number }, default: number)
	config:SetAttribute(name, if allNumbers(values, default) then nil else encodeNumbers(values))
end

local function saveVectors(config: Configuration, name: string, values: { Vector3 }, default: Vector3)
	config:SetAttribute(name, if allVectors(values, default) then nil else encodeVectors(values))
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
	-- A missing list means every value is the default (see saveNumbers).
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
		-- Left out for the base material.
		materialVariant = if typeof(variant) == "string" then variant else "",
	}
end

return Displacement
