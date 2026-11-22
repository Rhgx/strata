--!strict
--[[
	Mesh actions. Simplify works in two steps (see Scene/MeshStage): points are marked first, with
	a preview, and `applyMarks` commits them as one undo step. `selectFlat` marks every point that
	can go while the surface bends no more than an angle (flat ground gets a few big triangles,
	detail stays where the terrain bends), and `markRestoreAll` marks every removed point to come
	back. `restorePoints` (the Tiles page) restores right away.
]]

local Displacement = require(script.Parent.Parent.Core.Displacement)
local Mesh = require(script.Parent.Parent.Core.Mesh)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local MeshStage = require(script.Parent.Parent.Scene.MeshStage)
local Query = require(script.Parent.Parent.Scene.Query)
local Session = require(script.Parent.Parent.Scene.Session)
local Edges = require(script.Parent.Edges)
local Recording = require(script.Parent.Recording)

type Opened = TerrainInstance.Opened

-- Candidates tried between yields, so Studio stays responsive on big selections.
local CANDIDATES_PER_YIELD = 20
-- A max angle of 0 still allows rounding noise on flat ground.
local MIN_ANGLE = 0.1

local MeshActions = {}

-- Saves tiles whose points changed and closes the seams their removed edge points would open
-- against neighbors. Call inside a recording.
function MeshActions.finish(tiles: { Opened })
	for _, opened in tiles do
		Displacement.reproject(opened.disp)
		TerrainInstance.save(opened)
	end
	for _, opened in Edges.closeRemovedSeams(tiles) do
		TerrainInstance.save(opened)
	end
end

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
local function flatPoints(opened: Opened, maxAngle: number): { [number]: true }
	local disp = opened.disp
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
	local function key(tri: { number }): string
		local a, b, c3 = tri[1], tri[2], tri[3]
		if a > b then
			a, b = b, a
		end
		if b > c3 then
			b, c3 = c3, b
		end
		if a > b then
			a, b = b, a
		end
		return `{a},{b},{c3}`
	end
	local existing: { [string]: true } = {}
	local start = Displacement.mesh(disp)
	if start then
		for _, tri in start.triangles do
			existing[key(tri)] = true
		end
	else
		for g = 1, Displacement.gridTriangleCount(disp) do
			existing[key({ Displacement.gridTriangle(disp, g) })] = true
		end
	end
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

--[[
	Marks the points of the selected tiles that can go within `maxAngle` degrees (replacing their
	earlier marks), so the result can be previewed before Apply. Returns how many tiles got marks
	and how many points were marked. Yields.
]]
function MeshActions.selectFlat(maxAngle: number): (number, number)
	local tiles, points = 0, 0
	for _, opened in Query.selectedTiles() do
		local marks: { [number]: MeshStage.Mark } = {}
		local count = 0
		for v in flatPoints(opened, maxAngle) do
			marks[v] = "remove"
			count += 1
		end
		MeshStage.replace(opened.model, marks)
		if count > 0 then
			tiles += 1
			points += count
		end
	end
	return tiles, points
end

-- Marks every removed point of the selected tiles to come back. Returns how many tiles.
function MeshActions.markRestoreAll(): number
	local tiles = 0
	for _, opened in Query.selectedTiles() do
		local marks: { [number]: MeshStage.Mark } = {}
		for v in opened.disp.removed do
			marks[v] = "restore"
		end
		if next(marks) ~= nil then
			MeshStage.setMany(opened.model, marks)
			tiles += 1
		end
	end
	return tiles
end

-- Commits every marked point as one undo step and clears the marks. Returns how many tiles and
-- points changed.
function MeshActions.applyMarks(): (number, number)
	if MeshStage.isEmpty() then
		return 0, 0
	end
	local tiles, points = 0, 0
	Recording.run("Strata simplify", function()
		local changed: { Opened } = {}
		for model, marks in MeshStage.entries() do
			local opened = Session.get(model)
			if not opened then
				continue
			end
			local any = false
			for v, mark in marks do
				if Displacement.setRemoved(opened.disp, v, mark == "remove") then
					any = true
					points += 1
				end
			end
			if any then
				Session.updateTopology(opened)
				table.insert(changed, opened)
			end
		end
		tiles = #changed
		MeshActions.finish(changed)
		Recording.autoBake()
	end)
	MeshStage.clear()
	return tiles, points
end

-- Brings back every removed point on the selected tiles right away, as one undo step. Returns
-- how many tiles changed.
function MeshActions.restorePoints(): number
	local targets: { Opened } = {}
	for _, opened in Query.selectedTiles() do
		if next(opened.disp.removed) ~= nil then
			table.insert(targets, opened)
		end
	end
	if #targets == 0 then
		return 0
	end
	Recording.run("Strata restore points", function()
		for _, opened in targets do
			-- Removed points come back where the surface shows them now.
			Displacement.reproject(opened.disp)
			table.clear(opened.disp.removed)
			opened.disp.meshCache = nil
			Session.updateTopology(opened)
			TerrainInstance.save(opened)
		end
		Recording.autoBake()
	end)
	return #targets
end

return MeshActions
