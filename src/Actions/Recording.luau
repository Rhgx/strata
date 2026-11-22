--!strict
--[[
	Wraps every plugin action in a single ChangeHistoryService recording so Ctrl+Z undoes the
	action, its sewing, and its baking together. Failed actions cancel the recording (restoring
	instances) and clear the in-memory displacement cache.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Plugin = script.Parent.Parent

local Settings = require(Plugin.State.Settings)
local Session = require(Plugin.Scene.Session)

local Recording = {}

-- Executes `action` inside a single undo step named `name`, re-raising any error after cancelling.
function Recording.run(name: string, action: () -> ())
	local recording = ChangeHistoryService:TryBeginRecording(name)

	if not recording then
		error("Studio is already recording another change; try again", 0)
	end

	local err = ""
	local ok = xpcall(action, function (message)
		err = tostring(message)
	end)

	ChangeHistoryService:FinishRecording(
		recording,
		if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)

	if not ok then
		-- Cancelling reverted the instances; drop cached handles that may hold partial edits.
		Session.clear()
		error(err, 0)
	end
end

-- Bakes tiles modified by the current action when auto-bake is enabled and no editing tool is
-- active (editing tools defer baking until the last one stops). Call inside `Recording.run`.
function Recording.autoBake()
	local settings = Settings.get()

	if settings.autoBake and not Settings.editing(settings) then
		Session.bakeDirty(settings.smoothingAngle)
	end
end

return Recording
