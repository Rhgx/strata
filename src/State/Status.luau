--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Latest operation status shown in the panel's status bar. Success and warning messages expire
	after a few seconds, errors persist until replaced, and progress messages (such as a long
	bake) stay until the final result replaces or clears them.
]]

export type Kind = "success" | "warning" | "error" | "progress"

export type Message = {
	kind: Kind,
	text: string,
	-- Monotonic ID so expiration timers can tell whether their message is still active.
	id: number,
	-- Optional cancel callback for long-running progress operations (such as multi-tile bakes).
	onCancel: (() -> ())?,
}

type Listener = (Message?) -> ()

local SUCCESS_SECONDS = 6
local WARNING_SECONDS = 10
-- Grace period after unhovering when a message's timer elapsed while the user was reading it.
local RESUME_SECONDS = 2
-- Hard cap so a missed MouseLeave from a fast DockWidget exit can never keep messages stuck forever.
local MAX_PAUSE_SECONDS = WARNING_SECONDS * 2

local current: Message? = nil
local currentPostedAt = 0
local nextId = 0
local paused = false
local pendingClear = false
local expireThread: thread? = nil
local listeners: { [Listener]: true } = {}

local Status = {}

local function notify()
	for listener in listeners do
		listener(current)
	end
end

local function cancelTimer()
	if expireThread then
		task.cancel(expireThread)
		expireThread = nil
	end
end

local function scheduleExpire(message: Message, delaySeconds: number)
	cancelTimer()
	expireThread = task.delay(delaySeconds, function ()
		expireThread = nil

		if current ~= message then
			return
		end

		local remaining = (currentPostedAt + MAX_PAUSE_SECONDS) - os.clock()

		if paused and remaining > 0 then
			pendingClear = true
			scheduleExpire(message, remaining)
			return
		end

		pendingClear = false
		current = nil
		notify()
	end)
end

function Status.get(): Message?
	return current
end

function Status.post(kind: Kind, text: string, onCancel: (() -> ())?)
	cancelTimer()
	pendingClear = false
	nextId += 1

	local message: Message = { kind = kind, text = text, id = nextId, onCancel = onCancel }
	current = message
	currentPostedAt = os.clock()
	notify()

	-- Progress stays until replaced or cleared via clearProgress; errors stay until the next message.
	if kind == "success" then
		scheduleExpire(message, SUCCESS_SECONDS)
	elseif kind == "warning" then
		scheduleExpire(message, WARNING_SECONDS)
	end
end

-- Pauses auto-expiration while the user hovers the status bar to read a truncated message.
function Status.setPaused(value: boolean)
	if paused == value then
		return
	end

	paused = value

	if not value and pendingClear and current then
		pendingClear = false
		scheduleExpire(current, RESUME_SECONDS)
	end
end

-- Clears a progress message when an operation finishes without posting a replacement result.
function Status.clearProgress()
	if current and current.kind == "progress" then
		cancelTimer()
		pendingClear = false
		current = nil
		notify()
	end
end

function Status.clear()
	if current then
		cancelTimer()
		pendingClear = false
		current = nil
		notify()
	end
end

function Status.subscribe(listener: Listener): () -> ()
	listeners[listener] = true

	return function ()
		listeners[listener] = nil
	end
end

return Status
