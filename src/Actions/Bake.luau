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
	local result: Session.BakeResult = { baked = 0, failed = 0, firstError = nil }
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
	local baked = Query.placeInfo().baked
	if baked == 0 then
		-- Nothing to change; skip the empty undo step.
		return 0
	end
	Recording.run("Strata smoothing", function()
		for _, model in Session.models() do
			for _, surface in TerrainInstance.surfaces(model) do
				surface.SmoothingAngle = angle
			end
		end
	end)
	return baked
end

-- Bakes everything edited since the last bake as its own undo step, and posts the result. Run
-- when painting or the Stitch tool stops. Never raises: a busy Studio only posts a warning.
function Bake.bakeEdited()
	local recording = ChangeHistoryService:TryBeginRecording("Strata bake")
	if not recording then
		Status.post("warning", "Could not bake: Studio is busy. Use Bake all in Settings.")
		return
	end
	-- Always finish the recording, even if something unexpected fails mid-bake, so Studio's undo
	-- history is never left open.
	local ok, result = pcall(Session.bakeDirty, Settings.get().smoothingAngle)
	ChangeHistoryService:FinishRecording(
		recording,
		if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
	if not ok then
		Session.clear()
		Status.post("error", `Bake failed: {result}`)
		return
	end
	if result.failed > 0 then
		Status.post("error", `Baked {result.baked}, {result.failed} failed: {result.firstError}`)
	elseif result.baked > 0 then
		Status.post("success", if result.baked == 1 then "Baked 1 tile." else `Baked {result.baked} tiles.`)
	end
end

return Bake
