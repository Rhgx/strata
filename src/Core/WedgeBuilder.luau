--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Builds and updates WedgeParts (2 per triangle) for a displacement. Wedges are named by their
	1-based index ("1", "2", ...) so reopened models can reuse existing parts in place and brush
	strokes only move affected wedges instead of recreating them.
]]

local Displacement = require(script.Parent.Displacement)

-- Wedge thickness in studs, extruded below the surface so top faces match displacement triangles exactly.
local THICKNESS = 0.2
local TINY = Vector3.new(0.001, 0.001, 0.001)

export type Wedges = {
	folder: Folder,
	parts: { [number]: WedgePart },
}

local WedgeBuilder = {}

WedgeBuilder.THICKNESS = THICKNESS

-- Splits triangle abc into two right triangles along the altitude to its longest edge and fits
-- one WedgePart to each half.
local function placeTriangle(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	outward: Vector3,
	pivot: CFrame,
	w1: WedgePart,
	w2: WedgePart
)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)

	-- Rotate vertices so bc is the longest edge.
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end

	ab, ac, bc = b - a, c - a, c - b

	local cross = ac:Cross(ab)

	if cross.Magnitude < 1e-9 then
		-- Collapse degenerate zero-area triangles to a tiny point.
		local collapsed = pivot * CFrame.new(a)
		w1.Size = TINY
		w1.CFrame = collapsed
		w2.Size = TINY
		w2.CFrame = collapsed
		return
	end

	local right = cross.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	local sink = (if right:Dot(outward) >= 0 then right else -right) * (-THICKNESS / 2)

	w1.Size = Vector3.new(THICKNESS, height, math.abs(ab:Dot(back)))
	w1.CFrame = pivot * CFrame.fromMatrix((a + b) / 2 + sink, right, up, back)
	w2.Size = Vector3.new(THICKNESS, height, math.abs(ac:Dot(back)))
	w2.CFrame = pivot * CFrame.fromMatrix((a + c) / 2 + sink, -right, up, -back)
end

-- Indexes existing numbered WedgeParts inside `folder`.
function WedgeBuilder.attach(folder: Folder): Wedges
	local parts: { [number]: WedgePart } = {}

	for _, child in folder:GetChildren() do
		if child:IsA("WedgePart") then
			local n = tonumber(child.Name)

			if n then
				parts[n] = child
			end
		end
	end

	return { folder = folder, parts = parts }
end

-- Checks that every required wedge exists in `wedges.folder` with no extras.
function WedgeBuilder.isComplete(disp: Displacement.Displacement, wedges: Wedges): boolean
	local count = Displacement.triangleCount(disp) * 2
	local found = 0

	for n, part in wedges.parts do
		if n > count or part.Parent ~= wedges.folder then
			return false
		end

		found += 1
	end

	return found == count
end

-- Repositions wedges for `triangles` and returns all local-space vertex positions for reuse.
function WedgeBuilder.updateTriangles(
	disp: Displacement.Displacement,
	wedges: Wedges,
	pivot: CFrame,
	triangles: { number }
): { Vector3 }
	local outward = Displacement.faceNormal(disp)
	local positions = Displacement.positions(disp, outward)

	for _, t in triangles do
		local i1, i2, i3 = Displacement.triangle(disp, t)
		placeTriangle(
			positions[i1],
			positions[i2],
			positions[i3],
			outward,
			pivot,
			wedges.parts[t * 2 - 1],
			wedges.parts[t * 2]
		)
	end

	return positions
end

-- Builds unparented wedges for `triangles` (used when baking a temporarily simplified copy).
-- Caller is responsible for destroying the returned parts.
function WedgeBuilder.temporary(disp: Displacement.Displacement, pivot: CFrame, triangles: { number }): { BasePart }
	local outward = Displacement.faceNormal(disp)
	local positions = Displacement.positions(disp, outward)
	local parts: { BasePart } = table.create(#triangles * 2)

	for _, t in triangles do
		local i1, i2, i3 = Displacement.triangle(disp, t)
		local w1, w2 = Instance.new("WedgePart"), Instance.new("WedgePart")
		w1.Anchored, w2.Anchored = true, true

		placeTriangle(positions[i1], positions[i2], positions[i3], outward, pivot, w1, w2)
		table.insert(parts, w1)
		table.insert(parts, w2)
	end

	return parts
end

-- Applies each triangle's look to its wedges. Holes retain their wedges (keeping numbering
-- stable) but are hidden, non-collidable, non-queryable, and shadowless.
function WedgeBuilder.applyLooks(disp: Displacement.Displacement, wedges: Wedges, triangles: { number })
	for _, t in triangles do
		local look = Displacement.lookOf(disp, t)
		local hole = Displacement.isHole(disp, t)

		for n = t * 2 - 1, t * 2 do
			local part = wedges.parts[n]

			if part then
				part.Material = look.material
				part.Color = look.color
				part.MaterialVariant = look.variant
				part.Transparency = if hole then 1 else 0
				part.CanCollide = not hole
				part.CanQuery = not hole
				part.CastShadow = not hole
			end
		end
	end
end

-- Reconciles wedge count, applies looks, and positions all wedges for `disp`.
function WedgeBuilder.rebuild(disp: Displacement.Displacement, wedges: Wedges, pivot: CFrame)
	local count = Displacement.triangleCount(disp) * 2

	for n, part in wedges.parts do
		if n > count or part.Parent ~= wedges.folder then
			-- Unparent instead of destroying so ChangeHistoryService can undo cleanly.
			part.Parent = nil
			wedges.parts[n] = nil
		end
	end

	local created: { WedgePart } = {}

	for n = 1, count do
		local existing = wedges.parts[n]
		local part: WedgePart

		if existing then
			part = existing
		else
			part = Instance.new("WedgePart")
			part.Name = tostring(n)
			part.Anchored = true
			wedges.parts[n] = part
			table.insert(created, part)
		end

		-- Terrain wedges do not need Touched events, avoiding unnecessary physics overhead.
		part.CanTouch = false
	end

	local all = table.create(Displacement.triangleCount(disp))

	for t = 1, Displacement.triangleCount(disp) do
		all[t] = t
	end

	WedgeBuilder.applyLooks(disp, wedges, all)
	WedgeBuilder.updateTriangles(disp, wedges, pivot, all)

	-- Parent new parts last so they enter the DataModel once at their final transform.
	for _, part in created do
		part.Parent = wedges.folder
	end
end

return WedgeBuilder
