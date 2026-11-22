--!strict
--[[
	Mesh actions. Simplify works in two steps (see Scene/MeshStage): points are marked first, with
	a preview, and `applyMarks` commits them as one undo step. `selectFlat` marks every point that
	can go while the surface bends no more than an angle (flat ground gets a few big triangles,
	detail stays where the terrain bends), and `markRestoreAll` marks every removed point to come
	back. `restorePoints` (the Tiles page) restores right away.
]]

local Displacement = require(script.Parent.Parent.Core.Displacement)
local Simplify = require(script.Parent.Parent.Core.Simplify)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local MeshStage = require(script.Parent.Parent.Scene.MeshStage)
local Query = require(script.Parent.Parent.Scene.Query)
local Session = require(script.Parent.Parent.Scene.Session)
local Settings = require(script.Parent.Parent.State.Settings)
local Edges = require(script.Parent.Edges)
local Recording = require(script.Parent.Recording)

type Opened = TerrainInstance.Opened

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

--[[
	The tiles Select flat and Restore all work on: the selected tiles, or with none selected,
	every tile (none with Selected only on). The running Mesh tool takes clicks in the 3D view,
	so selecting first is not always handy.
]]
function MeshActions.scope(): { Opened }
	local selected = Query.selectedTiles()
	if #selected > 0 or Settings.get().paintSelectedOnly then
		return selected
	end
	return Session.getAll(Session.models())
end

--[[
	Marks the points of the tiles in scope that can go within `maxAngle` degrees (replacing their
	earlier marks), so the result can be previewed before Apply. Returns how many tiles got marks
	and how many points were marked, and whether it stopped early: it yields, and stops (keeping
	no stale marks) if the Mesh tool stops or leaves Simplify, or an undo replaces the tiles.
]]
function MeshActions.selectFlat(maxAngle: number): (number, number, boolean)
	local tiles, points = 0, 0
	local generation = Session.generation()
	for _, opened in MeshActions.scope() do
		local found = Simplify.flatPoints(opened.disp, maxAngle)
		local settings = Settings.get()
		-- An undo or redo meanwhile replaced the tiles (and cleared the marks): stop.
		if not (settings.meshing and settings.meshMode == "Simplify") or Session.generation() ~= generation then
			return 0, 0, true
		end
		local marks: { [number]: MeshStage.Mark } = {}
		local count = 0
		for v in found do
			marks[v] = "remove"
			count += 1
		end
		MeshStage.replace(opened.model, marks)
		if count > 0 then
			tiles += 1
			points += count
		end
	end
	return tiles, points, false
end

-- Marks every removed point of the tiles in scope to come back. Returns how many tiles.
function MeshActions.markRestoreAll(): number
	local tiles = 0
	for _, opened in MeshActions.scope() do
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

local function isEdgePoint(disp: Displacement.Displacement, v: number): boolean
	local n = disp.size - 1
	local row, col = (v - 1) // disp.size, (v - 1) % disp.size
	return row == 0 or col == 0 or row == n or col == n
end

--[[
	Seams must show the same edge on both tiles: a seam point removed on one tile but kept on its
	neighbor makes each tile's straight edge pull the other's kept points (closeRemovedSeams),
	and when both tiles have such points the pulls fight and a crack opens. So a mark on an edge
	point also applies to the same point on neighboring tiles (`marked` gains those marks), and
	afterwards every removed seam point of the changed tiles is removed on its neighbors too,
	which also repairs seams left mismatched before. Corners never go, so a neighbor's corner at
	that spot stays and is pulled onto the straight edge instead.
]]
local function mirrorAcrossSeams(marked: { [Opened]: { [number]: MeshStage.Mark } }, twinsOf: (Opened, number) -> { Edges.Twin })
	local extra: { [Opened]: { [number]: MeshStage.Mark } } = {}
	-- A neighbor's painted borders and hole outlines keep their points (as Select flat keeps
	-- them); the seam there is pulled onto the straight edge instead.
	local pinnedOf: { [Opened]: { [number]: true } } = {}
	local function isPinned(opened: Opened, v: number): boolean
		local pinned = pinnedOf[opened]
		if not pinned then
			pinned = Simplify.pinnedPoints(opened.disp)
			pinnedOf[opened] = pinned
		end
		return pinned[v] == true
	end
	for opened, marks in marked do
		for v, mark: MeshStage.Mark in marks do
			if not isEdgePoint(opened.disp, v) then
				continue
			end
			for _, twin in twinsOf(opened, v) do
				local own = marked[twin.opened]
				if (own and own[twin.index]) or Displacement.isCorner(twin.opened.disp, twin.index) then
					continue
				end
				if mark == "remove" and isPinned(twin.opened, twin.index) then
					continue
				end
				local list = extra[twin.opened]
				if not list then
					list = {}
					extra[twin.opened] = list
				end
				list[twin.index] = mark
			end
		end
	end
	for opened, marks in extra do
		local list = marked[opened]
		if not list then
			list = {}
			marked[opened] = list
		end
		for v, mark: MeshStage.Mark in marks do
			list[v] = mark
		end
	end
end

-- Commits every marked point as one undo step and clears the marks. Returns how many tiles and
-- points changed (points counted on the marked tiles, not their mirrored neighbors).
function MeshActions.applyMarks(): (number, number)
	if MeshStage.isEmpty() then
		return 0, 0
	end
	local tiles, points = 0, 0
	Recording.run("Strata simplify", function()
		local marked: { [Opened]: { [number]: MeshStage.Mark } } = {}
		for model, marks in MeshStage.entries() do
			local opened = Session.get(model)
			if opened then
				marked[opened] = table.clone(marks)
			end
		end
		local userTiles: { [Opened]: true } = {}
		for opened in marked do
			userTiles[opened] = true
		end
		local twinsOf = Edges.seamTwins(Session.getAll(Session.models()))
		mirrorAcrossSeams(marked, twinsOf)

		local changedSet: { [Opened]: true } = {}
		for opened, marks in marked do
			for v, mark: MeshStage.Mark in marks do
				if Displacement.setRemoved(opened.disp, v, mark == "remove") then
					changedSet[opened] = true
					if userTiles[opened] then
						points += 1
					end
				end
			end
		end
		-- Removed seam points of the changed tiles go on their neighbors too (see above).
		local repairs: { [Opened]: { [number]: MeshStage.Mark } } = {}
		for opened in changedSet do
			local disp = opened.disp
			local list: { [number]: MeshStage.Mark } = {}
			for v in disp.removed do
				if isEdgePoint(disp, v) then
					list[v] = "remove"
				end
			end
			repairs[opened] = list
		end
		mirrorAcrossSeams(repairs, twinsOf)
		for opened, marks in repairs do
			for v, mark: MeshStage.Mark in marks do
				if Displacement.setRemoved(opened.disp, v, mark == "remove") then
					changedSet[opened] = true
				end
			end
		end

		local changed: { Opened } = {}
		for opened in changedSet do
			Session.updateTopology(opened)
			table.insert(changed, opened)
			if userTiles[opened] then
				tiles += 1
			end
		end
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
