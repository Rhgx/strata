--!strict
--[[
	The plugin's buttons on Studio's Plugins ribbon tab: the panel toggle, and (only with the
	"Tools on Plugins ribbon" setting, off by default) the eight viewport tools in their own
	"Strata Tools" group, lit while running. The panel's tool strip already has every tool, so
	the ribbon stays uncluttered unless a user wants them there. Each tool also gets a plugin
	action either way, so users can bind keys in File > Customize Shortcuts.

	Studio cannot remove a plugin's ribbon buttons while it runs (destroying the group does nothing,
	and creating a button again with the same id errors), so the tool buttons are created once per
	session and reused; turning the setting off greys them out until Studio restarts.

	The panel button shows the Strata logo (uploaded images, one per Studio theme; sources in
	assets/logo). Its toolbar must not be named "Strata", the plugin's own name: Studio leaves such a
	toolbar off the ribbon (any other name works). While the panel is open the button shows as on,
	like Studio's own panel buttons.

	The tool icons are Studio's own icons (32 px ribbon size), referenced from Studio's content
	folder (not copied), in the folder matching the current theme. If a Studio update moves them,
	the buttons still work and show their text.
]]

local Settings = require(script.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.State.Status)

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
	-- The Align tool's icon (parts resting on one line) reads as snapping onto part edges.
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

-- Creates the toolbar; returns a function that stops syncing it.
return function(plugin: Plugin, widget: DockWidgetPluginGui): () -> ()
	local toolbar = plugin:CreateToolbar("Strata Terrain")
	local panelButton = toolbar:CreateButton("StrataToggle", "Open or close the Strata panel.", logo(), "Strata")
	panelButton.ClickableWhenViewportHidden = true

	local connections: { RBXScriptConnection } = {}
	-- The optional tool buttons, once created (they stay for the session, see the top).
	local buttons: { [Tool]: PluginToolbarButton } = {}

	-- Opens the panel and starts the tool (or stops it if it is running).
	local function toggle(tool: Tool)
		widget.Enabled = true
		Settings.toggleTool(tool)
	end

	for _, tool: Tool in Settings.tools() do
		local label = Settings.toolLabel(tool)
		-- Unbound by default; bind in File > Advanced > Customize Shortcuts.
		local action = plugin:CreatePluginAction(
			`Strata{tool}`,
			`Strata: {label}`,
			`Start or stop the Strata {label} tool`,
			"",
			true
		)
		table.insert(
			connections,
			action.Triggered:Connect(function()
				toggle(tool)
			end)
		)
	end

	local function syncButtons(state: Settings.State)
		local active = Settings.activeTool(state)
		for tool: Tool, button in buttons do
			button:SetActive(tool == active)
		end
		panelButton:SetActive(widget.Enabled)
	end

	local function showTools()
		if next(buttons) ~= nil then
			-- Back on in the same session: the greyed-out note no longer applies.
			Status.clear()
		else
			local group = plugin:CreateToolbar("Strata Tools")
			for _, tool: Tool in Settings.tools() do
				local button = group:CreateButton(`Strata{tool}`, TOOL_TIPS[tool], iconFor(TOOL_ICONS[tool]), Settings.toolLabel(tool))
				buttons[tool] = button
				table.insert(
					connections,
					button.Click:Connect(function()
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
		panelButton.Click:Connect(function()
			widget.Enabled = not widget.Enabled
		end)
	)
	table.insert(
		connections,
		widget:GetPropertyChangedSignal("Enabled"):Connect(function()
			syncButtons(Settings.get())
		end)
	)

	table.insert(
		connections,
		studio.ThemeChanged:Connect(function()
			panelButton.Icon = logo()
			for tool: Tool, button in buttons do
				button.Icon = iconFor(TOOL_ICONS[tool])
			end
		end)
	)

	return function()
		unsubscribe()
		for _, connection in connections do
			connection:Disconnect()
		end
	end
end
