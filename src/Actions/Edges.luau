--!strict
--[[
	Edge actions: sewing displacements to each other (Hammer's Sew), stitching tile edges onto
	standard parts (Core/Stitch), maintaining part-edge pins for Keep edges stitched, and running
	autosew after edits.
]]

local Plugin = script.Parent.Parent
local Core = Plugin.Core
local Scene = Plugin.Scene

local Sew = require(Core.Sew)
local Stitch = require(Core.Stitch)
local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Settings = require(Plugin.State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Recording = require(script.Parent.Recording)

type Opened = TerrainInstance.Opened

-- Summary of a stitch operation: matched part edges and the tile edges, tiles, and parts moved.
export type StitchReport = {
	matched: number,
	edges: number,
	tiles: number,
	parts: number,
}

export type Twin = { opened: Opened, index: number }

type Entry = { opened: Opened, index: number, flat: Vector3 }

-- Maximum distance from a part edge to count as already stitched (used by Keep edges stitched).
local PIN_REACH = 0.1
-- Seam points on neighboring tiles share their flat world position within 1/16 stud (matching
-- Sew's corner tolerance). Points are bucketed in 1-stud cells and checked across 3x3x3
-- neighboring cells so points near cell boundaries still find their twins.
local TWIN_DISTANCE = 1 / 16

local Edges = {}

local function count<K>(set: { [K]: true }): number
	local n = 0

	for _ in set do
		n += 1
	end

	return n
end

local function applySew(result: Sew.Changes)
	for opened, changed in result do
		Session.updateWedges(opened, changed)
		TerrainInstance.save(opened)
	end
end

-- Applies stitch target positions, propagates them to matching neighbor seam vertices so seams
-- stay closed, and updates wedges. Returns the vertex changes and modified tiles for saving.
-- `keepRemoved` is for closing seams, whose moves are removed points by design; every other
-- caller moves points onto parts, where a removed point must come back to stay put.
local function applyMoves(moves: Stitch.Moves, keepRemoved: boolean?): (Stitch.Changes, { Opened })
	local all = Stitch.propagate(moves, Session.getAll(Session.models()))
	local changes = Stitch.write(all)
	local changed: { Opened } = {}

	for opened, vertices in changes do
		if keepRemoved then
			Session.updateWedges(opened, vertices)
		else
			-- Points stitched onto a part must stay where they land, so removed ones come back.
			Session.updateMoved(opened, vertices)
		end

		table.insert(changed, opened)
	end

	return changes, changed
end

-- Applies a stitch result, saves modified tiles, and builds a StitchReport. Call inside a recording.
local function applyStitch(result: Stitch.Result): StitchReport
	local changes, changed = applyMoves(result.moves)

	for _, opened in changed do
		TerrainInstance.save(opened)
	end

	-- A stitched tile's edge can now differ from a simplified neighbor's straight edge.
	for _, opened in Edges.closeRemovedSeams(changed) do
		TerrainInstance.save(opened)
	end

	local edges = 0
	local tiles: { [Opened]: true } = {}
	local parts: { [BasePart]: true } = {}

	for _, match in result.matches do
		local vertices = changes[match.opened]

		if not vertices then
			continue
		end

		for _, v in match.vertices do
			if vertices[v] then
				edges += 1
				tiles[match.opened] = true
				parts[match.part] = true
				break
			end
		end
	end

	return { matched = #result.matches, edges = edges, tiles = count(tiles), parts = count(parts) }
end

-- Captures the edges of `tiles` currently touching a part edge so they can be re-snapped after an edit.
function Edges.pinsFor(tiles: { Opened }): Stitch.Moves
	if #tiles == 0 then
		return {}
	end

	return Stitch.match(tiles, Query.touchingParts(tiles, PIN_REACH), PIN_REACH, false).moves
end

-- Propagates `pins` to matching seam vertices on neighboring tiles, ready for Stitch.write.
-- Brushes compute this once per newly touched tile rather than every frame.
function Edges.propagatePins(pins: Stitch.Moves): Stitch.Moves
	if next(pins) == nil then
		return {}
	end

	return Stitch.propagate(pins, Session.getAll(Session.models()))
end

-- Re-snaps pinned edges onto their parts and updates wedges. Caller is responsible for saving.
function Edges.restorePins(pins: Stitch.Moves): { Opened }
	if next(pins) == nil then
		return {}
	end

	-- Pins hold kept edge points on their parts after an edit. A removed point among them only
	-- follows the straight edge between kept ones, so it is not restored (that would undo
	-- simplification on every edit near a part).
	local _, changed = applyMoves(pins, true)

	return changed
end

local function cellOf(point: Vector3): Vector3
	return Vector3.new(math.floor(point.X), math.floor(point.Y), math.floor(point.Z))
end

local function cellKey(cell: Vector3): string
	return `{cell.X},{cell.Y},{cell.Z}`
end

-- Builds a spatial lookup over `all` that maps any (tile, edgeVertex) pair to the edge vertices
-- on other tiles at the same flat world position. Intended to be built once for many queries.
function Edges.seamTwins(all: { Opened }): (Opened, number) -> { Twin }
	local cells: { [string]: { Entry } } = {}
	local flats: { [Opened]: { [number]: Vector3 } } = {}

	for _, opened in all do
		local pivot = opened.model:GetPivot()
		local own: { [number]: Vector3 } = {}

		for _, edge in Displacement.edges(opened.disp) do
			for _, v in edge.indices do
				if not own[v] then
					local flat = pivot * Displacement.flatPosition(opened.disp, v)
					own[v] = flat

					local key = cellKey(cellOf(flat))
					local list = cells[key]
					local entry: Entry = { opened = opened, index = v, flat = flat }

					if list then
						table.insert(list, entry)
					else
						cells[key] = { entry }
					end
				end
			end
		end

		flats[opened] = own
	end

	return function (opened: Opened, index: number): { Twin }
		local own = flats[opened]
		local flat = if own then own[index] else nil
		local result: { Twin } = {}

		if not flat then
			return result
		end

		local cell = cellOf(flat)

		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local list = cells[cellKey(cell + Vector3.new(dx, dy, dz))]

					if list then
						for _, entry in list do
							if entry.opened ~= opened and (entry.flat - flat).Magnitude <= TWIN_DISTANCE then
								table.insert(result, { opened = entry.opened, index = entry.index })
							end
						end
					end
				end
			end
		end

		return result
	end
end

-- Closes seam cracks caused by removed edge vertices: where `tiles` render a straight edge
-- between kept vertices, moves matching neighbor vertices (and intermediate vertices on denser
-- neighbors) onto that straight edge. Caller is responsible for saving the returned tiles.
function Edges.closeRemovedSeams(tiles: { Opened }): { Opened }
	local moves: Stitch.Moves = {}

	for _, opened in tiles do
		local disp = opened.disp

		if next(disp.removed) == nil then
			continue
		end

		Displacement.reproject(disp)

		local pivot = opened.model:GetPivot()
		local normal = Displacement.faceNormal(disp)
		local targets: { [number]: Vector3 } = {}

		for _, edge in Displacement.edges(disp) do
			for _, v in edge.indices do
				if disp.removed[v] then
					targets[v] = pivot * Displacement.position(disp, v, normal)
				end
			end
		end

		if next(targets) ~= nil then
			moves[opened] = targets
		end
	end

	if next(moves) == nil then
		return {}
	end

	local _, changed = applyMoves(moves, true)

	return changed
end

-- Sews `focus` tiles against every displacement in the place. When Keep edges stitched is on,
-- edges that touched a part beforehand (`pins`, or sampled now) are restored afterwards so part
-- edges take precedence at shared corners. Call inside a recording.
function Edges.autosew(focus: { Opened }, pins: Stitch.Moves?)
	if #focus == 0 then
		return
	end

	local pinned = if Settings.get().stitchParts then pins or Edges.pinsFor(focus) else nil
	local focusSet: { [Opened]: true } = {}

	for _, opened in focus do
		focusSet[opened] = true
	end

	applySew((Sew.sew(Session.getAll(Session.models()), focusSet)))

	if pinned then
		for _, opened in Edges.restorePins(pinned) do
			TerrainInstance.save(opened)
		end
	end

	-- Sewing averages seam vertices, which can pull a neighbor's vertex off an edge that a
	-- simplified tile renders straight.
	for _, opened in Edges.closeRemovedSeams(Session.getAll(Session.models())) do
		TerrainInstance.save(opened)
	end
end

-- Sews selected displacements to each other and stitches them to any selected normal parts
-- within stitch reach (analogous to sewing against brush faces in Hammer). Returns the number
-- of changed tiles and any Sew warning when faces could not be sewn.
function Edges.sewSelected(): (number, string?)
	local targets = Query.selectedTiles()
	local parts = Query.selectedParts()

	if #targets == 0 or (#targets < 2 and #parts == 0) then
		return 0, nil
	end

	local changed: { [Opened]: true } = {}
	local warning: string? = nil

	Recording.run("Strata sew", function ()
		local sewn, sewWarning = Sew.sew(targets)
		warning = sewWarning
		applySew(sewn)

		for opened in sewn do
			changed[opened] = true
		end

		-- Re-align simplified seams on the selected tiles after sew averaging.
		for _, opened in Edges.closeRemovedSeams(targets) do
			TerrainInstance.save(opened)
			changed[opened] = true
		end

		-- Stitch to parts last so part edges win at shared corners.
		if #parts > 0 then
			local stitched, stitchedList = applyMoves(Stitch.match(targets, parts, Settings.get().stitchReach, true).moves)

			for _, opened in stitchedList do
				TerrainInstance.save(opened)
			end

			for opened in stitched do
				changed[opened] = true
			end

			-- Stitching may restore and move edge points next to a simplified neighbor.
			for _, opened in Edges.closeRemovedSeams(stitchedList) do
				TerrainInstance.save(opened)
				changed[opened] = true
			end
		end

		Recording.autoBake()
	end)

	return count(changed), warning
end

-- Stitches selected displacements to nearby block and wedge parts (detected automatically, plus
-- any explicitly selected parts).
function Edges.stitchSelected(): StitchReport
	local targets = Query.selectedTiles()
	local report: StitchReport = { matched = 0, edges = 0, tiles = 0, parts = 0 }

	if #targets == 0 then
		return report
	end

	local reach = Settings.get().stitchReach
	local parts = Query.touchingParts(targets, reach + 0.5)

	for _, part in Query.selectedParts() do
		if not table.find(parts, part) then
			table.insert(parts, part)
		end
	end

	Recording.run("Strata stitch to parts", function ()
		report = applyStitch(Stitch.match(targets, parts, reach, true))
		Recording.autoBake()
	end)

	return report
end

-- Computes what stitching nearby tiles to `part` would change without mutating anything. Parts
-- joined to `part` along shared edges (such as multi-wedge floors) are merged into one outline.
function Edges.previewStitch(part: BasePart, reach: number): Stitch.Result
	local tiles = Query.tilesNear(part, reach + 0.5)

	if #tiles == 0 then
		return { moves = {}, matches = {} }
	end

	local normal = tiles[1].model:GetPivot():VectorToWorldSpace(Displacement.faceNormal(tiles[1].disp))
	local parts = Stitch.sheet(part, Query.touchingParts(tiles, reach + 0.5), normal)

	return Stitch.match(tiles, parts, reach, true)
end

-- Stitches every tile near `part` onto it (used by the Stitch tool; baking waits until tool exit).
function Edges.stitchToPart(part: BasePart, reach: number): StitchReport
	local report: StitchReport = { matched = 0, edges = 0, tiles = 0, parts = 0 }

	Recording.run("Strata stitch to part", function ()
		report = applyStitch(Edges.previewStitch(part, reach))
		Recording.autoBake()
	end)

	return report
end

return Edges
