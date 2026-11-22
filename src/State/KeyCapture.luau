--!strict
--[[
	Panel controls that take keyboard input themselves (a Dropdown under keyboard control) hold a
	capture while they do, so Input.onKey leaves those keys to them: Esc closing a dropdown list
	must not also stop the running tool, and Enter picking an item must not also apply or create.
]]

local holders: { [unknown]: true } = {}

local KeyCapture = {}

-- Starts a capture for `owner`; returns a function that ends it.
function KeyCapture.hold(owner: unknown): () -> ()
	holders[owner] = true
	return function()
		holders[owner] = nil
	end
end

function KeyCapture.active(): boolean
	return next(holders) ~= nil
end

return KeyCapture
