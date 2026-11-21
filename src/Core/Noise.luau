--!strict
--[[
	Hammer's displacement Noise: adds a deterministic value-noise amount between Min and Max to
	every vertex, along its field vector (or its offset normal where the field vector is exactly
	zero, as on untouched vertices). Same world position, same amount, so coincident vertices of
	neighboring displacements move together and no seed is involved.

	The noise is sampled from the vertex position in Hammer units and axes (see Units), with a
	lattice spacing of 1 Hammer unit, 3 octaves at persistence 1. Min and Max are in studs.
	Hammer does the math in 32-bit floats; this uses doubles, so values can differ in the last
	bits.
]]

local Displacement = require(script.Parent.Displacement)
local TerrainInstance = require(script.Parent.TerrainInstance)
local Units = require(script.Parent.Units)

type Opened = TerrainInstance.Opened

local TWO_32 = 4294967296

local Noise = {}

-- Unsigned 32-bit multiply with wraparound. Doubles hold 53 bits, so split one factor in 16-bit
-- halves to keep every partial product exact.
local function mul32(a: number, b: number): number
	local low = b % 65536
	local high = (b - low) / 65536
	return (a * low + ((a * high) % 65536) * 65536) % TWO_32
end

-- Integer lattice hash in [-1, 1], with C int32 wraparound.
local function lattice(x: number, y: number): number
	local n = (x + y * 57) % TWO_32
	n = bit32.bxor(bit32.lshift(n, 13), n)
	local inner = (mul32(mul32(n, n), 15731) + 789221) % TWO_32
	local m = bit32.band((mul32(n, inner) + 1376312589) % TWO_32, 0x7FFFFFFF)
	return 1 - m / 1073741824
end

local function smooth(x: number, y: number): number
	local corners = lattice(x - 1, y - 1) + lattice(x + 1, y - 1) + lattice(x - 1, y + 1) + lattice(x + 1, y + 1)
	local sides = lattice(x - 1, y) + lattice(x + 1, y) + lattice(x, y - 1) + lattice(x, y + 1)
	return corners / 16 + sides / 8 + lattice(x, y) / 4
end

-- Truncates toward zero like a C cast, so negative inputs extrapolate past the cell (Hammer's
-- behavior).
local function truncate(x: number): number
	return if x >= 0 then math.floor(x) else math.ceil(x)
end

local function interpolated(x: number, y: number): number
	local ix, iy = truncate(x), truncate(y)
	local fx, fy = x - ix, y - iy
	local a, b = smooth(ix, iy), smooth(ix + 1, iy)
	local c, d = smooth(ix, iy + 1), smooth(ix + 1, iy + 1)
	return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
end

-- 3 octaves; Hammer always passes persistence 1, so this is a plain sum in about [-3, 3].
local function perlinSum(x: number, y: number): number
	local total = 0
	for i = 0, 2 do
		local frequency = 2 ^ i
		total += interpolated(x * frequency, y * frequency)
	end
	return total
end

-- The noise amount in [min, max] for a world position.
function Noise.amount(worldPosition: Vector3, min: number, max: number): number
	local p = Units.toHammer(worldPosition)
	local value = math.clamp(perlinSum(p.X + p.Z, p.Y + p.Z), -1, 1)
	local half = (max - min) * 0.5
	return value * half + half + min
end

-- Applies noise to one displacement and returns the changed vertices. Equal Min and Max do
-- nothing, like Hammer.
function Noise.apply(opened: Opened, min: number, max: number): { [number]: true }
	local changed: { [number]: true } = {}
	if min == max then
		return changed
	end
	local disp = opened.disp
	local pivot = opened.model:GetPivot()
	local faceNormal = Displacement.faceNormal(disp)
	local positions = Displacement.positions(disp, faceNormal)
	for index, position in positions do
		local amount = Noise.amount(pivot * position, min, max)
		-- The direction is used as stored, not renormalized.
		local direction = disp.normals[index]
		if direction == Vector3.zero then
			direction = disp.offsetNormals[index]
		end
		if amount ~= 0 and direction ~= Vector3.zero then
			Displacement.setPosition(disp, index, position + direction * amount, faceNormal)
			changed[index] = true
		end
	end
	return changed
end

return Noise
