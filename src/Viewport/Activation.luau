--!strict
--[[
	The one owner of the plugin's viewport mouse. Painting, picking faces and stitching to parts
	all need plugin:Activate; doing it in one place means switching from one to another never
	deactivates the mouse in between, and Studio taking the mouse back (for example the user
	picks the Move tool) stops whichever tool was running.

	Also the one Esc handler, so a single press does one thing: close Settings or Help if open,
	otherwise stop the running tool.
]]

local UserInputService = game:GetService("UserInputService")

local Settings = require(script.Parent.Parent.State.Settings)

local ICONS = {
	paint = "rbxasset://SystemCursors/Cross",
	pick = "rbxasset://SystemCursors/PointingHand",
}

-- Starts managing activation; returns a function that stops.
return function(plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local active = false
	-- Set while we deactivate ourselves, so our own Deactivation event is not treated as Studio
	-- taking the mouse away.
	local releasing = false

	local function sync(state: Settings.State)
		local wants = state.painting or state.picking or state.stitching or state.sampling
		if wants and not active then
			active = true
			plugin:Activate(true)
		elseif not wants and active then
			active = false
			releasing = true
			plugin:Deactivate()
			releasing = false
		end
		mouse.Icon = if state.painting then ICONS.paint elseif state.picking or state.stitching or state.sampling then ICONS.pick else ""
	end

	local unsubscribe = Settings.subscribe(sync)
	local connections = {
		plugin.Deactivation:Connect(function()
			if releasing then
				return
			end
			active = false
			Settings.stopViewportTool()
		end),
		UserInputService.InputBegan:Connect(function(input)
			if input.KeyCode ~= Enum.KeyCode.Escape or UserInputService:GetFocusedTextBox() then
				return
			end
			if Settings.get().overlay ~= "none" then
				Settings.setOverlay("none")
			else
				Settings.stopViewportTool()
			end
		end),
	}

	return function()
		unsubscribe()
		for _, connection in connections do
			connection:Disconnect()
		end
		if active then
			releasing = true
			plugin:Deactivate()
			releasing = false
		end
	end
end
