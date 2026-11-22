--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Manages Strata's Plugins ribbon buttons and Studio PluginActions: always creates the Strata
	panel toggle button, registers bindable PluginActions for toggling the panel, all 8 tools, and
	Edit points (File > Customize Shortcuts), and optionally creates a "Strata Tools" ribbon group
	when `ribbonTools` is enabled.

	Studio does not support removing ribbon buttons at runtime (destroying a toolbar has no
	effect, and recreating a button with the same ID errors). Optional tool buttons are therefore
	created once per session and disabled (grayed out) if turned off until Studio restarts.

	The panel toolbar intentionally avoids the name "Strata" (the plugin's own name), because
	Studio hides a toolbar whose name matches the plugin name. Tool icons reference Studio's
	built-in 32 px SVG texture paths per theme; if Studio moves them in a future update, buttons
	degrade cleanly to their text labels.
]]

local Plugin = script.Parent.Parent
local State = Plugin.State

local Status = require(State.Status)
local Settings = require(State.Settings)

local PointEditor = require(script.Parent.PointEditor)

type Tool = Settings.Tool

local LOGO = {
	Dark = "rbxassetid://115216591542258",
	Light = "rbxassetid://115704515500929",
}
local ICON_ROOT = "rbxasset://studio_svg_textures/"

local TOOL_ICONS: { [Tool]: string } = {
	Raise = "Lua/Terrain/%s/Large/Terrain_Grow.png",
	Lower = "Lua/Terrain/%s/Large/Terrain_Erode.png",
	Smooth = "Lua/Terrain/%s/Large/Terrain_Smooth.png",
	RaiseTo = "Lua/Terrain/%s/Large/Terrain_Flatten.png",
	Material = "Lua/Terrain/%s/Large/Terrain_Paint.png",
	Mesh = "Lua/Terrain/%s/Large/Terrain_Subtract.png",
	PickFaces = "Lua/TerrainEditor/%s/Large/Select.png",
	-- AlignTool icon (parts aligned to a line) reads cleanly as snapping edges to parts.
	Stitch = "Shared/WidgetIcons/%s/Large/AlignTool.png",
}

local TOOL_TIPS: { [Tool]: string } = {
	Raise = "Push terrain outward along the paint axis. Hold Ctrl to lower, Shift to smooth.",
	Lower = "Push terrain inward along the paint axis. Hold Ctrl to raise, Shift to smooth.",
	Smooth = "Even out bumps and blend across tile seams.",
	RaiseTo = "Flatten terrain to an exact Height from each tile's flat base. Hold Shift to smooth.",
	Material = "Paint a material and color into parts of a tile, such as a road through grass. Hold Ctrl to erase.",
	Mesh = "Remove points so an area has fewer, larger triangles, or cut holes. Hold Ctrl to restore.",
	PickFaces = "Click part faces in the 3D view, then click Create to turn them into terrain.",
	Stitch = "Click a block or wedge part in the 3D view to snap nearby tile edges onto it.",
}

local studio = settings().Studio

local function isLight(): boolean
	return studio.Theme.Name == "Light"
end

local function iconFor(path: string): string
	return ICON_ROOT .. string.format(path, if isLight() then "Light" else "Dark")
end

local function logo(): string
	return if isLight() then LOGO.Light else LOGO.Dark
end

-- Creates ribbon toolbars and PluginActions; returns a cleanup callback.
return function (plugin: Plugin, widget: DockWidgetPluginGui): () -> ()
	local toolbar = plugin:CreateToolbar("Strata Terrain")
	local panelButton = toolbar:CreateButton("StrataToggle", "Open or close the Strata panel.", logo(), "Strata")
	panelButton.ClickableWhenViewportHidden = true

	local connections: { RBXScriptConnection } = {}
	-- Lazily created optional ribbon tool buttons (retained for the remainder of the session).
	local buttons: { [Tool]: PluginToolbarButton } = {}

	local function toggle(tool: Tool)
		widget.Enabled = true
		Settings.toggleTool(tool)
	end

	-- Ribbon buttons cannot be bound in Customize Shortcuts, so expose a matching PluginAction.
	local togglePanel = plugin:CreatePluginAction(
		"StrataTogglePanel",
		"Strata: Toggle panel",
		"Open or close the Strata panel",
		"",
		true
	)

	table.insert(
		connections,
		togglePanel.Triggered:Connect(function ()
			widget.Enabled = not widget.Enabled
		end)
	)

	for _, tool: Tool in Settings.tools() do
		local label = Settings.toolLabel(tool)
		-- Unbound by default; users can assign shortcuts in File > Advanced > Customize Shortcuts.
		local action = plugin:CreatePluginAction(
			`Strata{tool}`,
			`Strata: {label}`,
			`Start or stop the Strata {label} tool`,
			"",
			true
		)

		table.insert(
			connections,
			action.Triggered:Connect(function ()
				toggle(tool)
			end)
		)
	end

	-- Edit points is not a viewport tool (it never takes the mouse), so it has an action but no
	-- ribbon button.
	local editPoints = plugin:CreatePluginAction(
		"StrataEditPoints",
		"Strata: Edit points",
		"Start or stop editing Strata tile points",
		"",
		true
	)

	table.insert(
		connections,
		editPoints.Triggered:Connect(function ()
			widget.Enabled = true

			if Settings.get().editingPoints then
				Settings.setEditingPoints(false)
			else
				PointEditor.enter()
			end
		end)
	)

	local function syncButtons(state: Settings.State)
		local active = Settings.activeTool(state)

		for tool: Tool, button in buttons do
			button:SetActive(tool == active)
		end

		panelButton:SetActive(widget.Enabled)
	end

	local function showTools()
		if next(buttons) ~= nil then
			-- Re-enabled in the same session: dismiss the grayed-out warning.
			Status.clear()
		else
			local group = plugin:CreateToolbar("Strata Tools")

			for _, tool: Tool in Settings.tools() do
				local button = group:CreateButton(`Strata{tool}`, TOOL_TIPS[tool], iconFor(TOOL_ICONS[tool]), Settings.toolLabel(tool))
				buttons[tool] = button

				table.insert(
					connections,
					button.Click:Connect(function ()
						if Settings.get().ribbonTools then
							toggle(tool)
						end
					end)
				)
			end
		end

		for _, button in buttons do
			button.Enabled = true
		end
	end

	local function hideTools()
		if next(buttons) == nil then
			return
		end

		for _, button in buttons do
			button.Enabled = false
		end

		Status.post("warning", "The ribbon tool buttons are greyed out and go away when Studio restarts.")
	end

	local shown = false

	local function sync(state: Settings.State)
		if state.ribbonTools ~= shown then
			shown = state.ribbonTools

			local ok, err = pcall(if shown then showTools else hideTools)

			if not ok then
				Status.post("error", `Could not update the ribbon buttons: {err}`)
			end
		end

		syncButtons(state)
	end

	sync(Settings.get())

	local unsubscribe = Settings.subscribe(sync)

	table.insert(
		connections,
		panelButton.Click:Connect(function ()
			widget.Enabled = not widget.Enabled
		end)
	)

	table.insert(
		connections,
		widget:GetPropertyChangedSignal("Enabled"):Connect(function ()
			syncButtons(Settings.get())
		end)
	)

	table.insert(
		connections,
		studio.ThemeChanged:Connect(function ()
			panelButton.Icon = logo()

			for tool: Tool, button in buttons do
				button.Icon = iconFor(TOOL_ICONS[tool])
			end
		end)
	)

	return function ()
		unsubscribe()

		for _, connection in connections do
			connection:Disconnect()
		end
	end
end
