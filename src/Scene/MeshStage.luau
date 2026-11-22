--!strict
--[[
	Staged point marks for the Mesh tool's Simplify mode: points marked for removal (shown in
	orange) or removed points marked for restoration (green). Marking does not modify tiles; the
	tool previews the resulting triangulation and triangle count, and Apply commits all marked
	tiles in a single undo step. This follows Blender's select-then-act workflow so sweeping the
	brush never alters terrain unintentionally.

	Keyed by Model so undo and redo (which drop opened tiles) cannot leave stale entries. The
	Mesh tool clears marks on undo, redo, mode changes, and tool exit.
]]

local Plugin = script.Parent.Parent
local Core = Plugin.Core

local Mesh = require(Core.Mesh)
local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Session = require(script.Parent.Session)

export type Mark = "remove" | "restore"
type Opened = TerrainInstance.Opened

type Preview = { version: number, removed: { [number]: true }, mesh: Mesh.Mesh? }

local MeshStage = {}

local version = 0
local marks: { [Model]: { [number]: Mark } } = {}
local previews: { [Model]: Preview } = {}
local listeners: { [() -> ()]: true } = {}

local function changed()
	version += 1

	for listener in listeners do
		task.spawn(listener)
	end
end

-- Increments whenever any staged mark changes.
function MeshStage.version(): number
	return version
end

function MeshStage.subscribe(listener: () -> ()): () -> ()
	listeners[listener] = true

	return function ()
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

-- Sets or clears (with nil) the staged mark on point `v`. Returns whether the mark changed.
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

-- Marks multiple points on a single tile with one change notification.
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

-- Replaces all staged marks for one tile (an empty table clears the tile).
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

function MeshStage.entries(): { [Model]: { [number]: Mark } }
	return marks
end

-- Computes the removed-point set `opened` would have once `tile` marks are applied.
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

-- Returns the removed-point set and preview triangulation (nil when no points would be removed)
-- that `opened` would have after applying its staged marks. Cached per marks version.
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

-- Returns total triangle counts before and after applying marks across all marked tiles.
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
