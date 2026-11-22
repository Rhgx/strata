--!strict
--[[
	Baking merges a displacement's wedges into one union (smooth textures, one part); unbaking
	brings the wedges back for editing. See TerrainInstance.bake.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Query = require(script.Parent.Parent.Scene.Query)
local Session = require(script.Parent.Parent.Scene.Session)
local Settings = require(script.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.State.Status)
local Recording = require(script.Parent.Recording)

local Bake = {}

local function bakeModels(models: { Model }): Session.BakeResult
	local result = Session.emptyResult()
	if Session.isBaking() then
		-- A second click while a long bake runs.
		error("Already baking; wait for it to finish", 0)
	end
	Recording.run("Strata bake", function()
		result = Session.bake(Session.getAll(models), Settings.get().smoothingAngle)
	end)
	return result
end

function Bake.bakeSelected(): Session.BakeResult
	return bakeModels(Query.selectedModels())
end

function Bake.bakeAll(): Session.BakeResult
	return bakeModels(Session.models())
end

-- Bakes every tile in the place again, as one undo step, so changed Settings > Baking options
-- reach tiles baked before. Tiles go straight from their old union to the new one: wedges are
-- built only for a tile that needs them. A tile that fails stays as wedges.
function Bake.rebakeAll(): Session.BakeResult
	if Session.isBaking() then
		error("Already baking; wait for it to finish", 0)
	end
	local result = Session.emptyResult()
	Recording.run("Strata rebake", function()
		local targets = Session.getAll(Session.models())
		for _, opened in targets do
			-- Keep looks changed with Studio's own tools before the old union goes.
			TerrainInstance.adoptAppearance(opened)
			TerrainInstance.removeSurfaces(opened.model)
		end
		result = Session.bake(targets, Settings.get().smoothingAngle)
	end)
	return result
end

-- Brings the wedges back for the selected displacements. Returns how many were unbaked.
function Bake.unbakeSelected(): number
	local count = 0
	Recording.run("Strata unbake", function()
		for _, opened in Query.selectedTiles() do
			if TerrainInstance.isBaked(opened.model) then
				TerrainInstance.ensureWedges(opened)
				count += 1
			end
		end
	end)
	return count
end

-- Applies the smoothing angle to every baked surface right away, as one undo step. Returns how
-- many baked tiles were updated.
function Bake.applySmoothing(angle: number): number
	-- Plain Parts (flat tiles baked with Plain Part for flat tiles) have no smoothing.
	local unions: { UnionOperation } = {}
	local tiles = 0
	for _, model in Session.models() do
		local any = false
		for _, surface in TerrainInstance.surfaces(model) do
			if surface:IsA("UnionOperation") then
				table.insert(unions, surface)
				any = true
			end
		end
		if any then
			tiles += 1
		end
	end
	if #unions == 0 then
		-- Nothing to change; skip the empty undo step.
		return 0
	end
	Recording.run("Strata smoothing", function()
		for _, union in unions do
			union.SmoothingAngle = angle
		end
	end)
	return tiles
end

-- Bakes everything edited since the last bake as its own undo step, and posts the result. Run
-- when painting or the Stitch tool stops. Never raises: a busy Studio only posts a warning.
function Bake.bakeEdited()
	local recording = ChangeHistoryService:TryBeginRecording("Strata bake")
	if not recording then
		Status.post("warning", "Could not bake: Studio is busy. Bake from the panel later.")
		return
	end
	-- Always finish the recording, even if something unexpected fails mid-bake, so Studio's undo
	-- history is never left open.
	local ok, result = pcall(Session.bakeDirty, Settings.get().smoothingAngle)
	-- Nothing baked or failed (for example everything was undone first): cancel, so no empty
	-- "Strata bake" step lands in the undo history.
	local changed = ok and (result.baked > 0 or result.failed > 0)
	ChangeHistoryService:FinishRecording(
		recording,
		if changed then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
	if not changed then
		-- Cancel undoes anything opening tiles created (such as a missing Tris folder), so the
		-- opened copies may point at removed instances.
		Session.clear()
	end
	if not ok then
		Status.post("error", `Bake failed: {result}`)
		return
	end
	if result.failed > 0 then
		Status.post("error", `Baked {result.baked}, {result.failed} failed: {result.firstError}`)
	elseif result.baked > 0 then
		local tiles = if result.baked == 1 then "1 tile" else `{result.baked} tiles`
		Status.post("success", `Baked {tiles}{Session.savings(result)}.`)
	end
end

return Bake
