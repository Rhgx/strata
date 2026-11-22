--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
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
-- With `append`, the changes join the previous undo step instead of starting their own.
function Recording.run(name: string, action: () -> (), append: boolean?)
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
		if not ok
			then Enum.FinishRecordingOperation.Cancel
			elseif append then Enum.FinishRecordingOperation.Append
			else Enum.FinishRecordingOperation.Commit
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
