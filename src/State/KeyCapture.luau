--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Keyboard capture registry for panel controls that consume key presses directly (such as a
	keyboard-navigated Dropdown). While any capture is held, Input.onKey yields keys to the
	control so Esc closes the dropdown without stopping the active tool and Enter selects an
	item without triggering apply or create.
]]

local holders: { [unknown]: true } = {}

local KeyCapture = {}

-- Registers a capture for `owner` and returns a release callback.
function KeyCapture.hold(owner: unknown): () -> ()
	holders[owner] = true

	return function ()
		holders[owner] = nil
	end
end

function KeyCapture.active(): boolean
	return next(holders) ~= nil
end

return KeyCapture
