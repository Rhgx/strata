--!strict
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
}

local cache: { [Model]: Opened } = {}
-- Models that failed to open, tracked so each warning is logged once.
local failed: { [Model]: true } = {}
-- Models edited (showing wedges) since their last bake. Keyed by Model so the set survives
-- `clear`: an undo must not cause earlier edits to skip baking.
local dirty: { [Model]: true } = {}
local baking = false
local generation = 0

local Session = {}

function Session.emptyResult(): BakeResult
	return { baked = 0, failed = 0, firstError = nil, triangles = 0, bakedTriangles = 0 }
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

function Session.get(model: Model): Opened?
	local cached = cache[model]

	if cached or failed[model] then
		return cached
	end

	local ok, result = pcall(TerrainInstance.open, model)

	if not ok then
		warn(`[Strata] could not open {model:GetFullName()}: {result}`)
		failed[model] = true
		return nil
	end

	cache[model] = result
	return result
end

-- Returns the cached handle for `model` without opening it if uncached.
function Session.peek(model: Model): Opened?
	return cache[model]
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

-- Drops opened handles after undo, redo, or a cancelled action that mutates instances and
-- attributes directly. Preserves `dirty` so pending bakes are not lost.
function Session.clear()
	table.clear(cache)
	table.clear(failed)
	generation += 1
end

-- Increments whenever opened handles are dropped so yielding work can detect stale tiles.
function Session.generation(): number
	return generation
end

-- Registers a newly created displacement in the cache to avoid re-reading its attributes.
function Session.track(opened: Opened)
	cache[opened.model] = opened
	failed[opened.model] = nil
end

function Session.markDirty(opened: Opened)
	dirty[opened.model] = true
end

function Session.isBaking(): boolean
	return baking
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
	dirty[opened.model] = true
	return rebuilt
end

-- Rebuilds all wedges after vertices are removed or restored and the triangulation changes,
-- restoring wedges first if the displacement was baked.
function Session.updateTopology(opened: Opened)
	TerrainInstance.ensureWedges(opened)
	WedgeBuilder.rebuild(opened.disp, opened.wedges, opened.model:GetPivot())
	TerrainInstance.refreshBounds(opened)
	dirty[opened.model] = true
end

-- Applies updated material looks to wedges of `triangles` without recomputing vertex positions
-- or sewing, restoring wedges first if baked. Returns whether wedges had to be rebuilt first.
function Session.updateLooks(opened: Opened, triangles: { number }): boolean
	local rebuilt = TerrainInstance.ensureWedges(opened)

	WedgeBuilder.applyLooks(opened.disp, opened.wedges, triangles)
	dirty[opened.model] = true
	return rebuilt
end

-- Bakes `targets` into unions using the optimization options from Settings. Yields and must run
-- inside a ChangeHistoryService recording.
function Session.bake(targets: { Opened }, smoothingAngle: number): BakeResult
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

	-- Each tile bake is wrapped in xpcall so `baking` is always cleared even on errors.
	for i, opened in targets do
		if not opened.model:IsDescendantOf(workspace) or TerrainInstance.isBaked(opened.model) then
			dirty[opened.model] = nil
			continue
		end

		-- Union operations yield, so report progress on multi-tile bakes.
		if #targets > 1 then
			Status.post("progress", `Baking {i} of {#targets}...`)
		end

		local err = ""
		local ok, before, after = xpcall(TerrainInstance.bake, function (message)
			err = tostring(message)
		end, opened, options)

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
	Status.clearProgress()
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

	return Session.bake(Session.getAll(models), smoothingAngle)
end

-- Starts listening for undo, redo, and tag removal; returns a cleanup function.
function Session.start(): () -> ()
	local connections = {
		ChangeHistoryService.OnUndo:Connect(Session.clear),
		ChangeHistoryService.OnRedo:Connect(Session.clear),

		-- Drop deleted displacements so their data is not retained. Undoing a delete re-adds
		-- the tag and the model opens fresh on next access.
		CollectionService:GetInstanceRemovedSignal(TerrainInstance.TAG):Connect(function (inst)
			if inst:IsA("Model") then
				cache[inst] = nil
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
