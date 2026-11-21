--!strict
--[[
	Every action is one ChangeHistoryService recording, so Ctrl + Z undoes it in one step,
	including the sewing and baking it triggers. A failed action is cancelled, which restores the
	instances, and the in-memory displacement cache is dropped with it.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Session = require(script.Parent.Parent.Scene.Session)
local Settings = require(script.Parent.Parent.State.Settings)

local Recording = {}

-- Runs `action` as one undo step named `name`. Errors are raised again after the cancel.
function Recording.run(name: string, action: () -> ())
	local recording = ChangeHistoryService:TryBeginRecording(name)
	if not recording then
		error("Studio is already recording another change; try again", 0)
	end
	local err = ""
	local ok = xpcall(action, function(message)
		err = tostring(message)
	end)
	ChangeHistoryService:FinishRecording(
		recording,
		if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
	if not ok then
		-- Cancel restored the instances; drop the in-memory copies that may hold the failed edit.
		Session.clear()
		error(err, 0)
	end
end

-- Bakes everything the current action edited when Bake automatically is on and no viewport
-- tool is running (painting and Stitch bake when they stop instead). Call inside `run`.
function Recording.autoBake()
	local settings = Settings.get()
	if settings.autoBake and not settings.painting and not settings.stitching then
		Session.bakeDirty(settings.smoothingAngle)
	end
end

return Recording
