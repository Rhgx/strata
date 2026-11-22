--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Single owner of plugin viewport mouse activation, Esc handling, and cursor icons.

	Activation: painting, material painting, meshing, face picking, stitching, and sampling all
	require plugin:Activate. Centralizing it ensures switching tools never drops mouse capture in
	between, while Studio reclaiming the mouse (e.g. selecting the Move tool) stops the active
	tool cleanly.

	Escape order: closes Settings or Help if open, otherwise cancels the Material pipette, clears
	Mesh staged marks or Pick faces picks if present, and finally stops the active tool.

	Cursor priority (updated every frame): Wait while baking (clicks are blocked), SizeEW during
	Alt + Drag resize, Forbidden when no targets exist, then the tool default (Cross for brush
	tools; PointingHand or Arrow for click tools based on Viewport/Cursor hints).
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Scene = Plugin.Scene

local Settings = require(Plugin.State.Settings)

local Session = require(Scene.Session)
local MeshStage = require(Scene.MeshStage)

local Input = require(Viewport.Input)
local Cursor = require(Viewport.Cursor)
local PickFaceTool = require(Viewport.PickFaceTool)

local ICONS = {
	paint = "rbxasset://SystemCursors/Cross",
	point = "rbxasset://SystemCursors/PointingHand",
	arrow = "rbxasset://SystemCursors/Arrow",
	resize = "rbxasset://SystemCursors/SizeEW",
	forbidden = "rbxasset://SystemCursors/Forbidden",
	wait = "rbxasset://SystemCursors/Wait",
}

-- Grace window to distinguish a Studio deactivation fired during a ribbon tool switch from
-- Studio genuinely taking back the mouse.
local SWITCH_GRACE = 0.1

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

-- Starts managing plugin activation and cursor state; returns a cleanup callback.
return function (plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local active = false
	-- True while we call plugin:Deactivate ourselves so Deactivation ignores our own release.
	local releasing = false
	-- Tracks the most recent tool switch timestamp and identity to detect ribbon switch races.
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
			-- Clear cursor hints left by the previous tool.
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
		-- Hover, resize, and bake state can change outside Settings updates; write only on change.
		RunService.Heartbeat:Connect(function ()
			if not active then
				return
			end

			local icon = iconFor(Settings.get())

			if mouse.Icon ~= icon then
				mouse.Icon = icon
			end
		end),

		plugin.Deactivation:Connect(function ()
			if releasing then
				return
			end

			active = false

			-- Clicking a ribbon button can fire Deactivation right around a tool switch. Wait
			-- briefly, and re-activate if a tool was just chosen rather than stopping everything.
			task.delay(SWITCH_GRACE, function ()
				if active then
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

		Input.onKey(function (input: Input.Key)
			if input.KeyCode ~= Enum.KeyCode.Escape or UserInputService:GetFocusedTextBox() then
				return
			end

			local state = Settings.get()

			if state.overlay ~= "none" then
				Settings.setOverlay("none")
			elseif state.coloring and state.pickingLook then
				-- First Esc cancels the Material pipette; a second stops the Material tool.
				Settings.update(function (s)
					s.pickingLook = false
				end)
			elseif state.meshing and not MeshStage.isEmpty() then
				-- First Esc drops staged Mesh marks; a second stops the Mesh tool.
				MeshStage.clear()
			elseif state.picking and #PickFaceTool.picks() > 0 then
				-- First Esc clears picked faces; a second stops Pick faces.
				PickFaceTool.clear()
			else
				Settings.stopViewportTool()
			end
		end),
	}

	return function ()
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
