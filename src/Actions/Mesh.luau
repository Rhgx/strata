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
	and how many points were marked. Yields; stops early (keeping no stale marks) if the Mesh
	tool stops or leaves Simplify meanwhile, since that clears the marks.
]]
function MeshActions.selectFlat(maxAngle: number): (number, number)
	local tiles, points = 0, 0
	for _, opened in MeshActions.scope() do
		local found = Simplify.flatPoints(opened.disp, maxAngle)
		local settings = Settings.get()
		if not (settings.meshing and settings.meshMode == "Simplify") then
			return 0, 0
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
	return tiles, points
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
