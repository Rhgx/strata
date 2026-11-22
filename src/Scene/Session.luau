--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Shared cache of opened displacements used by brushes and edit actions so all tools operate on
	the same in-memory data. Also tracks displacements modified since their last bake. Because
	undo and redo mutate attributes and parts directly, the cache is cleared whenever either runs.
]]

local CollectionService = game:GetService("CollectionService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Plugin = script.Parent.Parent
local Core = Plugin.Core
local State = Plugin.State

local Displacement = require(Core.Displacement)
local WedgeBuilder = require(Core.WedgeBuilder)
local TerrainInstance = require(Core.TerrainInstance)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

type Opened = TerrainInstance.Opened

export type BakeResult = {
	baked: number,
	failed: number,
	firstError: string?,
	-- Triangle count before baking and in the resulting baked surfaces.
	triangles: number,
	bakedTriangles: number,
	-- True when the user cancelled a multi-tile bake before every tile finished.
	cancelled: boolean,
}

-- Small selections pass an Include OverlapParams; larger ones check an allowed set in Lua to
-- avoid copying big Instance arrays into C++ on every query.
local SMALL_FILTER_LIMIT = 32

local cache: { [Model]: Opened } = {}
-- AttributeChanged connections on cached DispData instances so direct Properties edits (and
-- their undo/redo) evict the stale handle even when Rev did not change.
local attrConnections: { [Model]: RBXScriptConnection } = {}
-- Last history generation at which each cached model's DispData revision and wedges were verified.
local checkedGen: { [Model]: number } = {}
-- Models that failed to open, tracked so each warning is logged once.
local failed: { [Model]: true } = {}
-- Models edited (showing wedges) since their last bake. Keyed by Model so the set survives
-- `clear`: an undo must not cause earlier edits to skip baking.
local dirty: { [Model]: true } = {}
local baking = false
local bakeCancellable = false
local cancelRequested = false
local generation = 0
local historyGen = 0
local changeListeners: { [() -> ()]: true } = {}

local Session = {}

local function evict(model: Model)
	cache[model] = nil
	checkedGen[model] = nil

	local conn = attrConnections[model]

	if conn then
		conn:Disconnect()
		attrConnections[model] = nil
	end
end

local function attrsMatch(config: Configuration, expected: { [string]: unknown }): boolean
	local live = config:GetAttributes()

	for k, v in live do
		if expected[k] ~= v then
			return false
		end
	end

	for k, v in expected do
		if live[k] ~= v then
			return false
		end
	end

	return true
end

local function storeCached(opened: Opened)
	local model = opened.model
	evict(model)
	cache[model] = opened
	checkedGen[model] = historyGen
	failed[model] = nil

	local config = opened.config
	attrConnections[model] = config.AttributeChanged:Connect(function (attr: string)
		if TerrainInstance.isInternalWrite(config) then
			return
		end

		-- Under Deferred SignalBehavior, Strata's own SetAttribute callbacks arrive after
		-- writeConfig finishes; compare against the saved attribute snapshot so internal writes
		-- never evict while external Properties edits and undo/redo evict immediately.
		if config:GetAttribute(attr) ~= opened.attrs[attr] then
			evict(model)
			generation += 1
		end
	end)
end

local function notifyChanged()
	for listener in changeListeners do
		listener()
	end
end

local function markModelDirty(model: Model)
	if not dirty[model] then
		dirty[model] = true
		notifyChanged()
	end
end

-- Subscribes to tile baked/dirty state transitions (fires once when a tile becomes dirty or
-- after a bake finishes, never per brush frame) so UI counts stay current after silent strokes.
function Session.onChanged(listener: () -> ()): () -> ()
	changeListeners[listener] = true

	return function ()
		changeListeners[listener] = nil
	end
end

function Session.emptyResult(): BakeResult
	return { baked = 0, failed = 0, firstError = nil, triangles = 0, bakedTriangles = 0, cancelled = false }
end

-- Formats triangle savings as " (768 to 24 triangles)" when bake optimization reduced the count.
function Session.savings(result: BakeResult): string
	if result.bakedTriangles >= result.triangles then
		return ""
	end

	return ` ({Format.count(result.triangles)} to {Format.count(result.bakedTriangles)} triangles)`
end

-- Returns every displacement Model currently under workspace.
function Session.models(): { Model }
	local models = {}

	for _, inst in CollectionService:GetTagged(TerrainInstance.TAG) do
		if inst:IsA("Model") and inst:IsDescendantOf(workspace) then
			table.insert(models, inst)
		end
	end

	return models
end

-- Verifies a cached handle after undo/redo: drops it if DispData changed (revision mismatch),
-- otherwise re-indexes Tris wedges so an undone Bake stays in sync without re-deserializing.
local function verifyCached(model: Model, cached: Opened): Opened?
	if checkedGen[model] == historyGen then
		return cached
	end

	if
		cached.config.Parent ~= model
		or TerrainInstance.currentRev(cached.config) ~= cached.rev
		or not attrsMatch(cached.config, cached.attrs)
	then
		evict(model)
		return nil
	end

	TerrainInstance.reattachWedges(cached)
	checkedGen[model] = historyGen
	return cached
end

function Session.get(model: Model): Opened?
	local cached = cache[model]

	if cached then
		local valid = verifyCached(model, cached)

		if valid then
			return valid
		end
	elseif failed[model] then
		return nil
	end

	local ok, result = pcall(TerrainInstance.open, model)

	if not ok then
		warn(`[Strata] could not open {model:GetFullName()}: {result}`)
		failed[model] = true
		return nil
	end

	storeCached(result)
	return result
end

-- Returns the cached handle for `model` without opening it if uncached.
function Session.peek(model: Model): Opened?
	local cached = cache[model]

	if not cached then
		return nil
	end

	return verifyCached(model, cached)
end

function Session.getAll(models: { Model }): { Opened }
	local result = {}

	for _, model in models do
		local opened = Session.get(model)

		if opened then
			table.insert(result, opened)
		end
	end

	return result
end

-- Reads a model's flat world-space AABB from DispData's Corner1..4 attributes without opening
-- the tile, or nil if attributes are missing.
local function flatWorldBounds(model: Model): (Vector3?, Vector3?)
	local config = model:FindFirstChild("DispData")

	if not config then
		return nil, nil
	end

	local c1 = config:GetAttribute("Corner1")
	local c2 = config:GetAttribute("Corner2")
	local c3 = config:GetAttribute("Corner3")
	local c4 = config:GetAttribute("Corner4")

	if typeof(c1) ~= "Vector3" or typeof(c2) ~= "Vector3" or typeof(c3) ~= "Vector3" or typeof(c4) ~= "Vector3" then
		return nil, nil
	end

	local pivot = model:GetPivot()
	local p1, p2, p3, p4 = pivot * c1, pivot * c2, pivot * c3, pivot * c4

	return p1:Min(p2):Min(p3):Min(p4), p1:Max(p2):Max(p3):Max(p4)
end

-- Checks whether `model` has any deleted triangles (hole wedges have CanQuery = false, so
-- GetPartBoundsInRadius skips them).
local function modelHasHoles(model: Model): boolean
	local config = model:FindFirstChild("DispData")
	local digits = if config then config:GetAttribute("TriLooks") else nil

	return typeof(digits) == "string" and string.find(digits, "-", 1, true) ~= nil
end

-- Returns opened displacements within `radius` studs of `center` via a spatial query so tools
-- never open or scan unrelated tiles across the map. Also checks tiles containing holes whose
-- wedges have CanQuery = false so cross-tile hole restores and sculpting never miss them.
-- When `allowed` is given, limits results to models in that list (for Selected only).
function Session.nearRadius(center: Vector3, radius: number, allowed: { Model }?): { Opened }
	if allowed and #allowed == 0 then
		return {}
	end

	local allowedSet: { [Model]: true }? = nil
	local params: OverlapParams? = nil

	if allowed then
		local set: { [Model]: true } = {}

		for _, model in allowed do
			set[model] = true
		end

		allowedSet = set

		if #allowed <= SMALL_FILTER_LIMIT then
			local filter: { Instance } = table.create(#allowed)

			for i, model in allowed do
				filter[i] = model
			end

			local p = OverlapParams.new()
			p.FilterType = Enum.RaycastFilterType.Include
			p.FilterDescendantsInstances = filter
			params = p
		end
	end

	local result: { Opened } = {}
	local seen: { [Model]: true } = {}

	for _, part in workspace:GetPartBoundsInRadius(center, radius, params) do
		local model = TerrainInstance.of(part)

		if not model or seen[model] or (allowedSet and not allowedSet[model]) then
			continue
		end

		seen[model] = true

		local opened = Session.get(model)

		if opened then
			table.insert(result, opened)
		end
	end

	-- Hole wedges have CanQuery = false (and baked tiles unparent hole wedges entirely), so
	-- GetPartBoundsInRadius misses regions covered only by holes (including raised holes outside
	-- both the baked Surface box and flat base quad). Open remaining hole tiles read-only once
	-- (cached thereafter) to test their exact displaced bounds.
	local holePool = allowed or Session.models()

	for _, model in holePool do
		if seen[model] or not modelHasHoles(model) then
			continue
		end

		local opened = Session.get(model)

		if not opened then
			continue
		end

		local pivot = model:GetPivot()
		local nearest = pivot:PointToObjectSpace(center)
		local gap = (nearest - nearest:Max(opened.boundsMin):Min(opened.boundsMax)).Magnitude

		if gap <= radius then
			seen[model] = true
			table.insert(result, opened)
		end
	end

	return result
end

-- Returns `tiles` plus every workspace displacement whose flat base quad comes within `pad`
-- studs of any tile's flat base quad. Matches by flat corners (never part bounds) so Sew,
-- Stitch propagation, and seamTwins still find neighbors across wide vertical cracks without
-- opening unrelated tiles.
function Session.flatNeighbors(tiles: { Opened }, pad: number): { Opened }
	if #tiles == 0 then
		return {}
	end

	type Box = { min: Vector3, max: Vector3 }
	local boxes: { Box } = table.create(#tiles)
	local result: { Opened } = {}
	local seen: { [Model]: true } = {}
	local padVector = Vector3.one * pad

	for _, opened in tiles do
		seen[opened.model] = true
		table.insert(result, opened)

		local pivot = opened.model:GetPivot()
		local c = opened.disp.corners
		local p1, p2, p3, p4 = pivot * c[1], pivot * c[2], pivot * c[3], pivot * c[4]
		table.insert(boxes, {
			min = p1:Min(p2):Min(p3):Min(p4) - padVector,
			max = p1:Max(p2):Max(p3):Max(p4) + padVector,
		})
	end

	for _, model in Session.models() do
		if seen[model] then
			continue
		end

		local bMin, bMax = flatWorldBounds(model)

		if not bMin or not bMax then
			continue
		end

		for _, box in boxes do
			if
				bMin.X <= box.max.X
				and bMax.X >= box.min.X
				and bMin.Y <= box.max.Y
				and bMax.Y >= box.min.Y
				and bMin.Z <= box.max.Z
				and bMax.Z >= box.min.Z
			then
				seen[model] = true

				local opened = Session.get(model)

				if opened then
					table.insert(result, opened)
				end

				break
			end
		end
	end

	return result
end

-- Drops all opened handles after a cancelled action or cleanup. Preserves `dirty` so pending
-- bakes are not lost.
function Session.clear()
	for _, conn in attrConnections do
		conn:Disconnect()
	end

	table.clear(attrConnections)
	table.clear(cache)
	table.clear(checkedGen)
	table.clear(failed)
	generation += 1
end

-- Increments whenever opened handles are invalidated so yielding work and cursor caches refresh.
function Session.generation(): number
	return generation
end

-- Registers a newly created displacement in the cache to avoid re-reading its attributes.
function Session.track(opened: Opened)
	storeCached(opened)
end

function Session.markDirty(opened: Opened)
	markModelDirty(opened.model)
end

function Session.isBaking(): boolean
	return baking
end

function Session.isCancellableBake(): boolean
	return baking and bakeCancellable and not cancelRequested
end

function Session.cancelBake()
	if baking and bakeCancellable then
		cancelRequested = true
		Status.post("progress", "Cancelling bake...")
	end
end

-- Updates wedges touching `changed` vertices (restoring wedges first if baked) and refreshes
-- cached bounds. Attributes are persisted separately via TerrainInstance.save once per action.
-- Returns whether the wedges had to be rebuilt first.
function Session.updateWedges(opened: Opened, changed: { [number]: true }): boolean
	local rebuilt = TerrainInstance.ensureWedges(opened)

	-- Removed points follow the surface defined by the kept points.
	Displacement.reproject(opened.disp)

	local triangles = Displacement.trianglesTouching(opened.disp, changed)
	local positions = WedgeBuilder.updateTriangles(opened.disp, opened.wedges, opened.model:GetPivot(), triangles)

	TerrainInstance.refreshBounds(opened, positions)
	markModelDirty(opened.model)
	return rebuilt
end

--[[
	Like updateWedges, for edits that move points to exact places (Stitch onto a part edge, Round
	folds): a removed point among `changed` is restored first, since a removed point follows the
	shown surface and would snap straight back, leaving the edit undone while it reported success.
	Corners are never removed, so they need nothing. Returns whether any point was restored.
]]
function Session.updateMoved(opened: Opened, changed: { [number]: true }): boolean
	local disp = opened.disp
	local restored = false

	for v in changed do
		if disp.removed[v] and Displacement.setRemoved(disp, v, false) then
			restored = true
		end
	end

	if not restored then
		Session.updateWedges(opened, changed)

		return false
	end

	Displacement.reproject(disp)
	Session.updateTopology(opened)

	return true
end

-- Rebuilds all wedges after vertices are removed or restored and the triangulation changes,
-- restoring wedges first if the displacement was baked.
function Session.updateTopology(opened: Opened)
	TerrainInstance.ensureWedges(opened)
	WedgeBuilder.rebuild(opened.disp, opened.wedges, opened.model:GetPivot())
	TerrainInstance.refreshBounds(opened)
	markModelDirty(opened.model)
end

-- Applies updated material looks to wedges of `triangles` without recomputing vertex positions
-- or sewing, restoring wedges first if baked. Returns whether wedges had to be rebuilt first.
function Session.updateLooks(opened: Opened, triangles: { number }): boolean
	local rebuilt = TerrainInstance.ensureWedges(opened)

	WedgeBuilder.applyLooks(opened.disp, opened.wedges, triangles)
	markModelDirty(opened.model)
	return rebuilt
end

-- Bakes `targets` into unions using the optimization options from Settings. When `rebake` is
-- true, replaces existing unions one tile at a time so cancelling midway leaves untouched tiles
-- intact. When `cancellable` is true, multi-tile progress posts a Cancel button. Yields and
-- must run inside a ChangeHistoryService recording.
function Session.bake(targets: { Opened }, smoothingAngle: number, rebake: boolean?, cancellable: boolean?): BakeResult
	local result = Session.emptyResult()
	local settings = Settings.get()
	local options: TerrainInstance.BakeOptions = {
		smoothingAngle = smoothingAngle,
		simplifyAngle = settings.bakeSimplifyAngle,
		tolerance = settings.bakeHeightTolerance,
		simplifyEdges = settings.bakeSimplifyEdges,
		flatPart = settings.bakeFlatPart,
		flatNoShadow = settings.bakeFlatNoShadow,
	}

	baking = true
	bakeCancellable = cancellable == true and #targets > 1
	cancelRequested = false

	local verb = if rebake then "Rebaking" else "Baking"
	local onCancel = if bakeCancellable then Session.cancelBake else nil

	-- Each tile bake is wrapped in xpcall so `baking` is always cleared even on errors.
	for i, opened in targets do
		if cancelRequested then
			result.cancelled = true
			break
		end

		if not opened.model:IsDescendantOf(workspace) or (not rebake and TerrainInstance.isBaked(opened.model)) then
			dirty[opened.model] = nil
			continue
		end

		-- Union operations yield, so report progress on multi-tile bakes.
		if #targets > 1 then
			Status.post("progress", `{verb} {i} of {#targets}...`, onCancel)
		end

		local err = ""
		local ok, before, after = xpcall(function ()
			if rebake then
				-- Preserve appearance edits made with Studio tools before removing this tile's old union.
				TerrainInstance.adoptAppearance(opened)
				TerrainInstance.removeSurfaces(opened.model)
			end

			return TerrainInstance.bake(opened, options)
		end, function (message)
			err = tostring(message)
		end)

		if ok then
			-- A tile whose triangles are all deleted has nothing to bake and is not counted.
			if before > 0 then
				result.baked += 1
			end

			result.triangles += before
			result.bakedTriangles += after
			dirty[opened.model] = nil
		else
			result.failed += 1
			result.firstError = result.firstError or tostring(err)
			warn(`[Strata] could not bake {opened.model:GetFullName()}: {err}`)
		end
	end

	baking = false
	bakeCancellable = false
	cancelRequested = false
	Status.clearProgress()

	if result.baked > 0 then
		notifyChanged()
	end

	return result
end

-- Bakes every displacement edited since its last bake, pruning models removed from workspace.
function Session.bakeDirty(smoothingAngle: number): BakeResult
	local models: { Model } = {}

	for model in dirty do
		if model:IsDescendantOf(workspace) then
			table.insert(models, model)
		else
			dirty[model] = nil
		end
	end

	return Session.bake(Session.getAll(models), smoothingAngle, false, true)
end

-- Starts listening for undo, redo, and tag removal; returns a cleanup function.
function Session.start(): () -> ()
	local function onHistory()
		historyGen += 1
		generation += 1
		table.clear(failed)
	end

	local connections = {
		ChangeHistoryService.OnUndo:Connect(onHistory),
		ChangeHistoryService.OnRedo:Connect(onHistory),

		-- Drop deleted displacements so their data is not retained. Undoing a delete re-adds
		-- the tag and the model opens fresh on next access.
		CollectionService:GetInstanceRemovedSignal(TerrainInstance.TAG):Connect(function (inst)
			if inst:IsA("Model") then
				evict(inst)
				failed[inst] = nil
			end
		end),
	}

	return function ()
		for _, connection in connections do
			connection:Disconnect()
		end

		Session.clear()
		table.clear(dirty)
	end
end

return Session
