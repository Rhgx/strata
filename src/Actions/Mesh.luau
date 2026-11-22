--!strict
--[[
	Mesh simplification actions. Simplify operates in two phases (see Scene/MeshStage): points
	are staged first with a live preview, and `applyMarks` commits all changes in one undo step.
	`selectFlat` marks points removable within a surface bend threshold (coarsening flat areas
	while keeping detail on slopes), `markRestoreAll` stages all removed points for restoration,
	and `restorePoints` (used by the Tiles page) restores them immediately.
]]

local Plugin = script.Parent.Parent
local Core = Plugin.Core
local Scene = Plugin.Scene

local Simplify = require(Core.Simplify)
local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Settings = require(Plugin.State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)
local MeshStage = require(Scene.MeshStage)

local Edges = require(script.Parent.Edges)
local Recording = require(script.Parent.Recording)

type Opened = TerrainInstance.Opened

local MeshActions = {}

-- Reprojects removed vertices, saves modified tiles, and closes any seam cracks opened along
-- simplified edges. Call inside a recording.
function MeshActions.finish(tiles: { Opened })
	for _, opened in tiles do
		Displacement.reproject(opened.disp)
		TerrainInstance.save(opened)
	end

	for _, opened in Edges.closeRemovedSeams(tiles) do
		TerrainInstance.save(opened)
	end
end

-- Returns the tiles operated on by Select flat and Restore all: selected tiles if any are
-- selected (or always when Selected only is enabled), otherwise every tile in the workspace
-- since the active Mesh tool consumes viewport clicks.
function MeshActions.scope(): { Opened }
	local selected = Query.selectedTiles()

	if #selected > 0 or Settings.get().paintSelectedOnly then
		return selected
	end

	return Session.getAll(Session.models())
end

-- Stages points removable within `maxAngle` degrees on scoped tiles (replacing prior marks) for
-- preview before Apply. Yields between tiles and aborts cleanly (leaving no stale marks) if the
-- Mesh tool exits Simplify mode or undo/redo invalidates the session. Returns (tiles, points, aborted).
function MeshActions.selectFlat(maxAngle: number): (number, number, boolean)
	local tiles, points = 0, 0
	local generation = Session.generation()

	for _, opened in MeshActions.scope() do
		local found = Simplify.flatPoints(opened.disp, maxAngle)
		local settings = Settings.get()

		-- Abort if the tool switched modes or an undo/redo replaced the opened tiles while yielding.
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

-- Stages all removed points on scoped tiles for restoration. Returns the number of affected tiles.
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

-- Mirrors edge marks onto twin seam vertices of neighboring tiles so both sides of a seam share
-- the same kept vertices. Without mirroring, two simplified neighbors pulling each other's kept
-- points via closeRemovedSeams would fight and leave cracks. Corners are never removed, so a
-- neighbor's corner stays and is pulled onto the straight edge instead.
local function mirrorAcrossSeams(marked: { [Opened]: { [number]: MeshStage.Mark } }, twinsOf: (Opened, number) -> { Edges.Twin })
	local extra: { [Opened]: { [number]: MeshStage.Mark } } = {}
	-- Preserve points pinned by a neighbor's painted borders or hole outlines (matching Select flat);
	-- those seam vertices are pulled onto the straight edge instead.
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

--[[
	Applies point marks (remove or restore) and keeps seams consistent: marks on edge points are
	mirrored onto neighboring tiles, then removed seam points of every changed tile are removed
	on its neighbors too (repairing seams mismatched before). Rebuilds, saves and closes seams.
	Returns how many of the given tiles changed and how many of their points did (mirrored
	neighbors are not counted). Call inside a recording.
]]
local function applyPointMarks(marked: { [Opened]: { [number]: MeshStage.Mark } }): (number, number)
	local tiles, points = 0, 0
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

	-- Propagate existing removed seam points on changed tiles to their neighbors as well,
	-- repairing any seams that were mismatched prior to this edit.
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

	return tiles, points
end

-- Commits every marked point as one undo step and clears the marks. Returns how many tiles and
-- points changed (points counted on the marked tiles, not their mirrored neighbors).
function MeshActions.applyMarks(): (number, number)
	if MeshStage.isEmpty() then
		return 0, 0
	end

	local tiles, points = 0, 0

	Recording.run("Strata simplify", function ()
		local marked: { [Opened]: { [number]: MeshStage.Mark } } = {}

		for model, marks in MeshStage.entries() do
			local opened = Session.get(model)

			if opened then
				marked[opened] = table.clone(marks)
			end
		end

		tiles, points = applyPointMarks(marked)
		Recording.autoBake()
	end)

	MeshStage.clear()
	return tiles, points
end

-- Removes `points` right away as one undo step (deleting handles in Edit points), mirrored across
-- seams like Apply. Corners always stay and are skipped. Returns how many points were removed on
-- the given tiles.
function MeshActions.removePoints(points: { [Opened]: { number } }): number
	local marked: { [Opened]: { [number]: MeshStage.Mark } } = {}

	for opened, list in points do
		local marks: { [number]: MeshStage.Mark } = {}

		for _, v in list do
			if not Displacement.isCorner(opened.disp, v) and not opened.disp.removed[v] then
				marks[v] = "remove"
			end
		end

		if next(marks) ~= nil then
			marked[opened] = marks
		end
	end

	if next(marked) == nil then
		return 0
	end

	local removed = 0

	Recording.run("Strata remove points", function ()
		local _, count = applyPointMarks(marked)
		removed = count
		Recording.autoBake()
	end)

	return removed
end

-- Restores every removed point on selected tiles immediately as one undo step, mirrored across
-- seams like Apply, so a restored edge never meets a neighbor's straight simplified edge.
-- Returns the number of modified tiles.
function MeshActions.restorePoints(): number
	local marked: { [Opened]: { [number]: MeshStage.Mark } } = {}
	local count = 0

	for _, opened in Query.selectedTiles() do
		if next(opened.disp.removed) ~= nil then
			local marks: { [number]: MeshStage.Mark } = {}

			for v in opened.disp.removed do
				marks[v] = "restore"
			end

			marked[opened] = marks
			count += 1
		end
	end

	if count == 0 then
		return 0
	end

	Recording.run("Strata restore points", function ()
		-- Reproject first so restored points land on the currently displayed surface.
		for opened in marked do
			Displacement.reproject(opened.disp)
		end

		applyPointMarks(marked)
		Recording.autoBake()
	end)

	return count
end
return MeshActions
