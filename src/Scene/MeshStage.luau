--!strict
--[[
	Points marked in the Mesh tool's Simplify mode but not applied yet: marked to remove (shown
	orange) or, for removed points, marked to restore (green). Marking never changes a tile; the
	tool previews the result (new triangle edges and a triangle count) and Apply commits every
	marked tile as one undo step. Like selecting first and acting second in Blender, so nothing
	happens to the terrain by accident while sweeping the brush.

	Keyed by model, so undo and redo (which drop the opened tiles) cannot leave stale entries; the
	Mesh tool clears the marks on undo, redo, mode changes and when it stops.
]]

local Displacement = require(script.Parent.Parent.Core.Displacement)
local Mesh = require(script.Parent.Parent.Core.Mesh)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Session = require(script.Parent.Session)

export type Mark = "remove" | "restore"
type Opened = TerrainInstance.Opened

type Preview = { version: number, removed: { [number]: true }, mesh: Mesh.Mesh? }

local MeshStage = {}

local marks: { [Model]: { [number]: Mark } } = {}
local version = 0
local previews: { [Model]: Preview } = {}
local listeners: { [() -> ()]: true } = {}

local function changed()
	version += 1
	for listener in listeners do
		task.spawn(listener)
	end
end

-- Bumps whenever the marks change.
function MeshStage.version(): number
	return version
end

function MeshStage.subscribe(listener: () -> ()): () -> ()
	listeners[listener] = true
	return function()
		listeners[listener] = nil
	end
end

function MeshStage.isEmpty(): boolean
	return next(marks) == nil
end

function MeshStage.markOf(model: Model, v: number): Mark?
	local tile = marks[model]
	return if tile then tile[v] else nil
end

-- Sets (or clears, with nil) the mark of point `v`. Returns whether anything changed.
function MeshStage.set(model: Model, v: number, mark: Mark?): boolean
	local tile = marks[model]
	if (tile and tile[v]) == mark then
		return false
	end
	if mark then
		if not tile then
			tile = {}
			marks[model] = tile
		end
		tile[v] = mark
	elseif tile then
		tile[v] = nil
		if next(tile) == nil then
			marks[model] = nil
		end
	end
	changed()
	return true
end

-- Marks many points of one tile at once (one change notification).
function MeshStage.setMany(model: Model, points: { [number]: Mark })
	local tile = marks[model]
	local any = false
	for v, mark: Mark in points do
		if not tile then
			tile = {}
			marks[model] = tile
		end
		local current = tile :: { [number]: Mark }
		if current[v] ~= mark then
			current[v] = mark
			any = true
		end
	end
	if any then
		changed()
	end
end
-- Replaces every mark of one tile (none clears the tile).
function MeshStage.replace(model: Model, points: { [number]: Mark })
	if next(points) == nil then
		if marks[model] == nil then
			return
		end
		marks[model] = nil
	else
		marks[model] = table.clone(points)
	end
	changed()
end

function MeshStage.clear()
	if next(marks) ~= nil then
		table.clear(marks)
		table.clear(previews)
		changed()
	end
end

-- The marked tiles and their marks.
function MeshStage.entries(): { [Model]: { [number]: Mark } }
	return marks
end

-- The removed points `opened` would have once its marks are applied.
local function removedAfter(opened: Opened, tile: { [number]: Mark }): { [number]: true }
	local removed = table.clone(opened.disp.removed)
	for v, mark in tile do
		if mark == "remove" and not Displacement.isCorner(opened.disp, v) then
			removed[v] = true
		else
			removed[v] = nil
		end
	end
	return removed
end

--[[
	The triangulation `opened` would show after its marks are applied (nil when no point would be
	removed), and the removed set it was built from. Cached per marks version.
]]
function MeshStage.preview(opened: Opened): ({ [number]: true }, Mesh.Mesh?)
	local model = opened.model
	local tile = marks[model]
	if not tile then
		return opened.disp.removed, Displacement.mesh(opened.disp)
	end
	local cached = previews[model]
	if cached and cached.version == version then
		return cached.removed, cached.mesh
	end
	local removed = removedAfter(opened, tile)
	local disp = opened.disp
	local mesh: Mesh.Mesh? = nil
	if next(removed) ~= nil then
		local c = disp.corners
		local n = disp.size - 1
		mesh = Mesh.build(disp.size, removed, (c[2] - c[1]).Magnitude / n, (c[4] - c[1]).Magnitude / n)
	end
	previews[model] = { version = version, removed = removed, mesh = mesh }
	return removed, mesh
end

-- Shown triangles now and after applying, over every marked tile.
function MeshStage.counts(): (number, number)
	local before, after = 0, 0
	for model in marks do
		local opened = Session.get(model)
		if opened then
			before += Displacement.triangleCount(opened.disp)
			local _, mesh = MeshStage.preview(opened)
			after += if mesh then #mesh.triangles else Displacement.gridTriangleCount(opened.disp)
		end
	end
	return before, after
end

return MeshStage
