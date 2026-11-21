--!strict
--[[
	Edge actions: sewing tiles to each other (Hammer's Sew) and stitching tiles onto normal parts
	(Core/Stitch), plus the pins behind Keep edges stitched and the autosew that runs after
	edits.
]]

local Sew = require(script.Parent.Parent.Core.Sew)
local Stitch = require(script.Parent.Parent.Core.Stitch)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Query = require(script.Parent.Parent.Scene.Query)
local Session = require(script.Parent.Parent.Scene.Session)
local Settings = require(script.Parent.Parent.State.Settings)
local Recording = require(script.Parent.Recording)

type Opened = TerrainInstance.Opened

-- What a stitch did: part edges matched, and the tile edges, tiles and parts that moved.
export type StitchReport = {
	matched: number,
	edges: number,
	tiles: number,
	parts: number,
}

-- Edges within this distance of a part edge count as stitched to it (Keep edges stitched).
local PIN_REACH = 0.1

local Edges = {}

local function count<K>(set: { [K]: true }): number
	local n = 0
	for _ in set do
		n += 1
	end
	return n
end

-- Moves the wedges of sewn displacements and saves them.
local function applySew(result: Sew.Changes)
	for opened, changed in result do
		Session.updateWedges(opened, changed)
		TerrainInstance.save(opened)
	end
end

-- Writes stitch targets, plus the matching edge vertices of neighboring tiles so seams stay
-- closed, and moves the wedges. Returns the changes and the displacements that changed; the
-- caller saves them.
local function applyMoves(moves: Stitch.Moves): (Stitch.Changes, { Opened })
	local all = Stitch.propagate(moves, Session.getAll(Session.models()))
	local changes = Stitch.write(all)
	local changed: { Opened } = {}
	for opened, vertices in changes do
		Session.updateWedges(opened, vertices)
		table.insert(changed, opened)
	end
	return changes, changed
end

-- Applies a stitch match, saves, and reports what moved. Call inside a recording.
local function applyStitch(result: Stitch.Result): StitchReport
	local changes, changed = applyMoves(result.moves)
	for _, opened in changed do
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

-- The edges of `tiles` that touch a part edge now, to snap back onto it after an edit.
function Edges.pinsFor(tiles: { Opened }): Stitch.Moves
	if #tiles == 0 then
		return {}
	end
	return Stitch.match(tiles, Query.touchingParts(tiles, PIN_REACH), PIN_REACH, false).moves
end

-- Pins plus the matching edge vertices of neighboring tiles, ready for Stitch.write. The brush
-- computes this once per newly reached tile instead of every frame.
function Edges.propagatePins(pins: Stitch.Moves): Stitch.Moves
	if next(pins) == nil then
		return {}
	end
	return Stitch.propagate(pins, Session.getAll(Session.models()))
end

-- Snaps pinned edges back onto their parts and moves the wedges. Returns the displacements that
-- changed; the caller saves them.
function Edges.restorePins(pins: Stitch.Moves): { Opened }
	if next(pins) == nil then
		return {}
	end
	local _, changed = applyMoves(pins)
	return changed
end

-- Sews `focus` to every displacement in the place. With Keep edges stitched on, edges that
-- touched a part before the edit (`pins`, or found now) are snapped back onto it afterwards,
-- so the part wins at shared corners. Call inside a recording.
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
end

-- Sews the selected displacements to each other and stitches them to any selected normal parts
-- (like sewing to brush faces in Hammer, but within the stitch reach). Returns how many
-- displacements changed, and Sew's warning when some faces could not be sewn.
function Edges.sewSelected(): (number, string?)
	local targets = Query.selectedTiles()
	local parts = Query.selectedParts()
	if #targets == 0 or (#targets < 2 and #parts == 0) then
		return 0, nil
	end
	local changed: { [Opened]: true } = {}
	local warning: string? = nil
	Recording.run("Strata sew", function()
		local sewn, sewWarning = Sew.sew(targets)
		warning = sewWarning
		applySew(sewn)
		for opened in sewn do
			changed[opened] = true
		end
		-- Parts go last so they win at shared corners.
		if #parts > 0 then
			local stitched, stitchedList = applyMoves(Stitch.match(targets, parts, Settings.get().stitchReach, true).moves)
			for _, opened in stitchedList do
				TerrainInstance.save(opened)
			end
			for opened in stitched do
				changed[opened] = true
			end
		end
		Recording.autoBake()
	end)
	return count(changed), warning
end

-- Stitches the selected displacements to the block and wedge parts near their edges (found
-- automatically, plus any selected parts).
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
	Recording.run("Strata stitch to parts", function()
		report = applyStitch(Stitch.match(targets, parts, reach, true))
		Recording.autoBake()
	end)
	return report
end

-- What stitching nearby tiles to `part` would do, without changing anything.
function Edges.previewStitch(part: BasePart, reach: number): Stitch.Result
	return Stitch.match(Query.tilesNear(part, reach + 0.5), { part }, reach, true)
end

-- Stitches every tile near `part` to it (the Stitch tool). Baking waits until the tool stops.
function Edges.stitchToPart(part: BasePart, reach: number): StitchReport
	local report: StitchReport = { matched = 0, edges = 0, tiles = 0, parts = 0 }
	Recording.run("Strata stitch to part", function()
		report = applyStitch(Edges.previewStitch(part, reach))
		Recording.autoBake()
	end)
	return report
end

return Edges
