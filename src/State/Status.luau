--!strict
--[[
	The latest operation result, shown in the panel's status bar. Success and warning messages
	expire after a few seconds; errors stay until the next message. Progress messages (a long
	bake) are replaced by the result when it is done.
]]

export type Kind = "success" | "warning" | "error" | "progress"

export type Message = {
	kind: Kind,
	text: string,
	-- Increments per message, so a timer can tell whether its message is still current.
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
	-- Progress stays until the result replaces it (see clearProgress); errors until the next
	-- message.
	if kind ~= "error" and kind ~= "progress" then
		task.delay(EXPIRE_SECONDS, function()
			if current == message then
				current = nil
				notify()
			end
		end)
	end
end

-- Drops a progress message that no result replaced (a bake that ended with nothing to say).
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
	return function()
		listeners[listener] = nil
	end
end

return Status
