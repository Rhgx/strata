--!strict
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
}

type Listener = (Message?) -> ()

local EXPIRE_SECONDS = 6

local current: Message? = nil
local nextId = 0
local listeners: { [Listener]: true } = {}

local Status = {}

local function notify()
	for listener in listeners do
		listener(current)
	end
end

function Status.get(): Message?
	return current
end

function Status.post(kind: Kind, text: string)
	nextId += 1

	local message: Message = { kind = kind, text = text, id = nextId }
	current = message
	notify()

	-- Progress stays until replaced or cleared via clearProgress; errors stay until the next message.
	if kind ~= "error" and kind ~= "progress" then
		task.delay(EXPIRE_SECONDS, function ()
			if current == message then
				current = nil
				notify()
			end
		end)
	end
end

-- Clears a progress message when an operation finishes without posting a replacement result.
function Status.clearProgress()
	if current and current.kind == "progress" then
		current = nil
		notify()
	end
end

function Status.clear()
	if current then
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
