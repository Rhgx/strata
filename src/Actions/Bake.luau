--!strict
--[[
	Baking actions: merges displacement wedges into unions for smooth textures and reduced part
	counts, and unbakes tiles back to wedges for editing. See Core/TerrainInstance.bake.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Plugin = script.Parent.Parent
local State = Plugin.State
local Scene = Plugin.Scene

local TerrainInstance = require(Plugin.Core.TerrainInstance)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Recording = require(script.Parent.Recording)

local Bake = {}

local function bakeModels(models: { Model }): Session.BakeResult
	local result = Session.emptyResult()

	if Session.isBaking() then
		-- Reject overlapping clicks while a long bake is still running.
		error("Already baking; wait for it to finish", 0)
	end

	Recording.run("Strata bake", function ()
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

-- Rebakes every tile in the place as one undo step so updated Settings > Baking options apply
-- to previously baked tiles. Tiles transition directly from their old union to the new one,
-- building wedges only when needed; any tile that fails remains as wedges.
function Bake.rebakeAll(): Session.BakeResult
	if Session.isBaking() then
		error("Already baking; wait for it to finish", 0)
	end

	local result = Session.emptyResult()

	Recording.run("Strata rebake", function ()
		local targets = Session.getAll(Session.models())

		for _, opened in targets do
			-- Preserve appearance edits made with Studio tools before removing the old union.
			TerrainInstance.adoptAppearance(opened)
			TerrainInstance.removeSurfaces(opened.model)
		end

		result = Session.bake(targets, Settings.get().smoothingAngle)
	end)

	return result
end

-- Restores wedges for selected displacements and returns how many were unbaked.
function Bake.unbakeSelected(): number
	local count = 0

	Recording.run("Strata unbake", function ()
		for _, opened in Query.selectedTiles() do
			if TerrainInstance.isBaked(opened.model) then
				TerrainInstance.ensureWedges(opened)
				count += 1
			end
		end
	end)

	return count
end

-- Applies `angle` to every baked UnionOperation immediately as one undo step. Returns how many
-- baked tiles were updated.
function Bake.applySmoothing(angle: number): number
	-- Plain Parts produced by the flat-part bake option do not have a SmoothingAngle property.
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
		-- Skip creating an empty undo step when no unions exist.
		return 0
	end

	Recording.run("Strata smoothing", function ()
		for _, union in unions do
			union.SmoothingAngle = angle
		end
	end)

	return tiles
end

-- Posts a bake result to the status bar. `ok` and `result` match pcall's return values, `verb`
-- is "Baked" or "Rebaked", and `nothing` is posted as a warning when zero tiles needed baking
-- (omit for automatic bakes).
function Bake.report(ok: boolean, result: Session.BakeResult | string, verb: string, nothing: string?)
	if not ok or typeof(result) == "string" then
		Status.post("error", `{if verb == "Rebaked" then "Rebake" else "Bake"} failed: {result}`)
	elseif result.failed > 0 then
		Status.post("error", `{verb} {result.baked}, {result.failed} failed: {result.firstError}`)
	elseif result.baked > 0 then
		Status.post("success", `{verb} {Format.plural(result.baked, "tile")}{Session.savings(result)}.`)
	elseif nothing then
		Status.post("warning", nothing)
	end
end

-- Bakes all tiles edited since the last bake in a dedicated undo step and posts the result.
-- Triggered when painting or stitching stops; never raises (a busy Studio posts a warning).
function Bake.bakeEdited()
	local recording = ChangeHistoryService:TryBeginRecording("Strata bake")

	if not recording then
		Status.post("warning", "Could not bake: Studio is busy. Bake from the panel later.")
		return
	end

	-- Always finish the recording, even if baking fails unexpectedly, so Studio's undo stack
	-- is never left open.
	local ok, result = pcall(Session.bakeDirty, Settings.get().smoothingAngle)
	-- Cancel when nothing baked or failed (for example, if edits were undone first) to avoid
	-- leaving an empty "Strata bake" step in undo history.
	local changed = ok and (result.baked > 0 or result.failed > 0)

	ChangeHistoryService:FinishRecording(
		recording,
		if changed then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)

	if not changed then
		-- Cancelling undoes any instances created while opening tiles (such as a missing Tris
		-- folder), so cached handles may reference removed instances.
		Session.clear()
	end

	Bake.report(ok, result, "Baked")
end

return Bake
