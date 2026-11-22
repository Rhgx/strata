--!strict
--[[
	The one owner of the plugin's viewport mouse. Painting, the Material tool, picking faces and stitching to parts
	all need plugin:Activate; doing it in one place means switching from one to another never
	deactivates the mouse in between, and Studio taking the mouse back (for example the user
	picks the Move tool) stops whichever tool was running. Clicking another tool's button
	switches to it; it never just turns every tool off.

	Also the one Esc handler, so a single press does one thing: close Settings or Help if open,
	otherwise clear the Mesh tool's marked points if there are any, otherwise stop the running tool.

	And the one writer of the mouse cursor, chosen every frame in this order: Wait while a bake
	runs (clicks are refused then), SizeEW during an Alt + Drag resize, Forbidden when the tool has
	nothing to act on, then the tool's own: Cross for the brushes, Material and Mesh, and for the
	click tools (Pick faces, Stitch, Sample, the Material pipette) PointingHand over something
	they can use, otherwise Arrow. Tools report what they know through Viewport/Cursor.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Settings = require(script.Parent.Parent.State.Settings)
local MeshStage = require(script.Parent.Parent.Scene.MeshStage)
local Session = require(script.Parent.Parent.Scene.Session)
local PickFaceTool = require(script.Parent.PickFaceTool)
local Cursor = require(script.Parent.Cursor)
local Input = require(script.Parent.Input)

local ICONS = {
	paint = "rbxasset://SystemCursors/Cross",
	point = "rbxasset://SystemCursors/PointingHand",
	arrow = "rbxasset://SystemCursors/Arrow",
	resize = "rbxasset://SystemCursors/SizeEW",
	forbidden = "rbxasset://SystemCursors/Forbidden",
	wait = "rbxasset://SystemCursors/Wait",
}

-- The cursor for the running tool (see the top), or "" with none.
local function iconFor(state: Settings.State): string
	local clicking = state.picking or state.stitching or state.sampling or (state.coloring and state.pickingLook)
	local brushing = state.painting or state.coloring or state.meshing
	if not (clicking or brushing) then
		return ""
	end
	local hint = Cursor.get()
	if Session.isBaking() then
		return ICONS.wait
	elseif hint == "resize" then
		return ICONS.resize
	elseif hint == "empty" then
		return ICONS.forbidden
	elseif clicking then
		return if hint == "valid" then ICONS.point else ICONS.arrow
	end
	return ICONS.paint
end
-- Seconds a Deactivation waits to see whether it came with a tool switch.
local SWITCH_GRACE = 0.1

-- Starts managing activation; returns a function that stops.
return function(plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local active = false
	-- Set while we deactivate ourselves, so our own Deactivation event is not treated as Studio
	-- taking the mouse away.
	local releasing = false
	-- When a tool was last started or switched to, and which one, so a Deactivation that comes
	-- with that click can be told apart from Studio taking the mouse back.
	local switchedAt = -math.huge
	local current: string? = nil

	local function toolOf(state: Settings.State): string?
		if state.sampling then
			return "Sample"
		end
		return Settings.activeTool(state)
	end

	local function sync(state: Settings.State)
		local wants = state.painting or state.coloring or state.meshing or state.picking or state.stitching or state.sampling
		local tool = toolOf(state)
		if tool and tool ~= current then
			switchedAt = os.clock()
		end
		if tool ~= current then
			-- The hint belonged to the tool that was running.
			Cursor.set(nil)
		end
		current = tool
		if wants and not active then
			active = true
			plugin:Activate(true)
		elseif not wants and active then
			active = false
			releasing = true
			plugin:Deactivate()
			releasing = false
		end
		mouse.Icon = iconFor(state)
	end

	local unsubscribe = Settings.subscribe(sync)
	local connections = {
		-- Hover, resizing and baking change between Settings updates; written only on a change.
		RunService.Heartbeat:Connect(function()
			if not active then
				return
			end
			local icon = iconFor(Settings.get())
			if mouse.Icon ~= icon then
				mouse.Icon = icon
			end
		end),
		plugin.Deactivation:Connect(function()
			if releasing then
				return
			end
			active = false
			-- Clicking a ribbon button can make Studio deactivate the plugin around the same
			-- click that switched tools, before or after it. Wait a moment, and if a tool was
			-- just started, take the mouse back for it instead of stopping everything.
			task.delay(SWITCH_GRACE, function()
				if active then
					-- The click that followed already started a tool (and activated it).
					return
				end
				local state = Settings.get()
				local wants = state.painting or state.coloring or state.meshing or state.picking or state.stitching or state.sampling
				if wants and os.clock() - switchedAt <= SWITCH_GRACE * 2 then
					active = true
					plugin:Activate(true)
				else
					Settings.stopViewportTool()
				end
			end)
		end),
		Input.onKey(function(input: Input.Key)
			if input.KeyCode ~= Enum.KeyCode.Escape or UserInputService:GetFocusedTextBox() then
				return
			end
			if Settings.get().overlay ~= "none" then
				Settings.setOverlay("none")
			elseif Settings.get().coloring and Settings.get().pickingLook then
				-- First Esc cancels the Material tool's pipette; the next one stops the tool.
				Settings.update(function(s)
					s.pickingLook = false
				end)
			elseif Settings.get().meshing and not MeshStage.isEmpty() then
				-- First Esc drops the Mesh tool's marked points; the next one stops the tool.
				MeshStage.clear()
			elseif Settings.get().picking and #PickFaceTool.picks() > 0 then
				-- Likewise for picked faces.
				PickFaceTool.clear()
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
