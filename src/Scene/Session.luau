--!strict
--[[
	Shared cache of opened displacements, used by the brush and the edit actions so they always
	work on the same in-memory data. Also tracks which displacements were edited since they were
	last baked. Undo and redo change attributes and parts directly, so the cache is dropped
	whenever they happen.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")

local Displacement = require(script.Parent.Parent.Core.Displacement)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local WedgeBuilder = require(script.Parent.Parent.Core.WedgeBuilder)

type Opened = TerrainInstance.Opened

export type BakeResult = {
	baked: number,
	failed: number,
	firstError: string?,
}

local cache: { [Model]: Opened } = {}
-- Models that failed to load, so the warning is printed once.
local failed: { [Model]: true } = {}
-- Displacements edited (and therefore showing wedges) since they were last baked. Keyed by
-- model so it survives `clear`: an undo must not make earlier edits skip their bake.
local dirty: { [Model]: true } = {}
local baking = false

local Session = {}

-- Every displacement model in the workspace.
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

-- The cached copy of `model`, without opening it if it is not cached.
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

-- Drops the opened copies (after undo, redo or a cancelled action, which change instances and
-- attributes directly). Which models still need baking is kept.
function Session.clear()
	table.clear(cache)
	table.clear(failed)
end

-- Caches a displacement that was just created, so it is not opened again from attributes.
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

-- Moves the wedges touching `changed` vertices (bringing wedges back first if the displacement
-- was baked) and refreshes the cached bounds. Attributes are written separately with
-- TerrainInstance.save, once per operation.
-- Returns whether the wedges had to be built first.
function Session.updateWedges(opened: Opened, changed: { [number]: true }): boolean
	local rebuilt = TerrainInstance.ensureWedges(opened)
	local triangles = Displacement.trianglesTouching(opened.disp, changed)
	local positions = WedgeBuilder.updateTriangles(opened.disp, opened.wedges, opened.model:GetPivot(), triangles)
	TerrainInstance.refreshBounds(opened, positions)
	dirty[opened.model] = true
	return rebuilt
end

-- Bakes `targets` into unions. Yields; must run inside a ChangeHistoryService recording.
function Session.bake(targets: { Opened }, smoothingAngle: number): BakeResult
	local result: BakeResult = { baked = 0, failed = 0, firstError = nil }
	baking = true
	-- Each tile's bake is protected below, so `baking` is always reset.
	for _, opened in targets do
		if not opened.model:IsDescendantOf(workspace) or TerrainInstance.isBaked(opened.model) then
			dirty[opened.model] = nil
			continue
		end
		local err = ""
		local ok = xpcall(TerrainInstance.bake, function(message)
			err = tostring(message)
		end, opened, smoothingAngle)
		if ok then
			result.baked += 1
			dirty[opened.model] = nil
		else
			result.failed += 1
			result.firstError = result.firstError or tostring(err)
			warn(`[Strata] could not bake {opened.model:GetFullName()}: {err}`)
		end
	end
	baking = false
	return result
end

-- Bakes every displacement edited since its last bake. Models deleted since are dropped.
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

-- Starts listening for undo, redo and removed displacements; returns a function that stops.
function Session.start(): () -> ()
	local connections = {
		ChangeHistoryService.OnUndo:Connect(Session.clear),
		ChangeHistoryService.OnRedo:Connect(Session.clear),
		-- Forget deleted displacements so their data is not kept alive. Undoing the delete adds
		-- the tag back, and the model is simply opened again.
		CollectionService:GetInstanceRemovedSignal(TerrainInstance.TAG):Connect(function(inst)
			if inst:IsA("Model") then
				cache[inst] = nil
				failed[inst] = nil
			end
		end),
	}
	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		Session.clear()
		table.clear(dirty)
	end
end

return Session
