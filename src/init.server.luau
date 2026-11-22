--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later

local Packages = script.Parent.Packages
local Viewport = script.Viewport

local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local Settings = require(script.State.Settings)
local Session = require(script.Scene.Session)

local Input = require(Viewport.Input)
local startToolbar = require(Viewport.Toolbar)
local startMeshTool = require(Viewport.MeshTool)
local startBrushTool = require(Viewport.BrushTool)
local PickFaceTool = require(Viewport.PickFaceTool)
local PointEditor = require(Viewport.PointEditor)
local startSampleTool = require(Viewport.SampleTool)
local startStitchTool = require(Viewport.StitchTool)
local startActivation = require(Viewport.Activation)
local RadiusPreview = require(Viewport.RadiusPreview)
local startMaterialTool = require(Viewport.MaterialTool)

local App = require(script.UI.App)

local SETTINGS_KEY = "StrataSettings"
-- Wait briefly after a setting changes before writing, so slider drags batch into one write.
local SAVE_DEBOUNCE = 0.3

-- Restores persisted settings from the previous session. Tools always start off.
local function restoreSettings()
	local saved = plugin:GetSetting(SETTINGS_KEY)

	if typeof(saved) ~= "table" then
		return
	end

	Settings.update(function (s)
		if typeof(saved.stitchParts) == "boolean" then
			s.stitchParts = saved.stitchParts
		end

		if saved.faces == "Top" or saved.faces == "TopSides" or saved.faces == "All" then
			s.faces = saved.faces
		end

		if typeof(saved.autoBake) == "boolean" then
			s.autoBake = saved.autoBake
		end

		if typeof(saved.smoothingAngle) == "number" then
			s.smoothingAngle = saved.smoothingAngle
		end

		if typeof(saved.showKeyHints) == "boolean" then
			s.showKeyHints = saved.showKeyHints
		end

		if typeof(saved.showBrushDots) == "boolean" then
			s.showBrushDots = saved.showBrushDots
		end

		if typeof(saved.showTooltips) == "boolean" then
			s.showTooltips = saved.showTooltips
		end

		if typeof(saved.radius) == "number" then
			s.radius = saved.radius
		end

		if typeof(saved.strength) == "number" then
			s.strength = saved.strength
		end

		if saved.power == 2 or saved.power == 3 or saved.power == 4 then
			s.power = saved.power
		end

		for _, mode: Settings.BrushMode in Settings.modes() do
			if saved.mode == mode then
				s.mode = mode
			end
		end

		for _, axis: Settings.Axis in Settings.axes() do
			if saved.axis == axis then
				s.axis = axis
			end
		end

		if saved.falloff == "Soft" or saved.falloff == "Hard" then
			s.falloff = saved.falloff
		end

		if typeof(saved.height) == "number" then
			s.height = saved.height
		end

		if typeof(saved.raiseToWorld) == "boolean" then
			s.raiseToWorld = saved.raiseToWorld
		end

		if typeof(saved.otherHeight) == "number" then
			s.otherHeight = saved.otherHeight
		end

		-- Plugin settings serialize to JSON, so the picked axis is stored as { x, y, z }.
		local picked = saved.pickedAxis

		if typeof(picked) == "table" then
			local x, y, z = picked[1], picked[2], picked[3]

			if typeof(x) == "number" and typeof(y) == "number" and typeof(z) == "number" then
				local axis = Vector3.new(x, y, z)

				if axis.Magnitude > 1e-6 then
					s.pickedAxis = axis.Unit
				end
			end
		end

		if typeof(saved.paintSelectedOnly) == "boolean" then
			s.paintSelectedOnly = saved.paintSelectedOnly
		end

		if typeof(saved.noiseMin) == "number" then
			s.noiseMin = saved.noiseMin
		end

		if typeof(saved.noiseMax) == "number" then
			s.noiseMax = saved.noiseMax
		end

		if typeof(saved.tileSize) == "number" then
			s.tileSize = saved.tileSize
		end

		if typeof(saved.autosew) == "boolean" then
			s.autosew = saved.autosew
		end

		if typeof(saved.stitchReach) == "number" then
			s.stitchReach = saved.stitchReach
		end

		local material = if typeof(saved.paintMaterial) == "string" then Enum.Material:FromName(saved.paintMaterial) else nil

		if material then
			s.paintMaterial = material
		end

		if typeof(saved.paintColor) == "string" then
			local ok, color = pcall(Color3.fromHex, saved.paintColor)

			if ok then
				s.paintColor = color
			end
		end

		if typeof(saved.paintVariant) == "string" then
			s.paintVariant = saved.paintVariant
		end

		if typeof(saved.paintFine) == "boolean" then
			s.paintFine = saved.paintFine
		end

		if typeof(saved.paintErase) == "boolean" then
			s.paintErase = saved.paintErase
		end

		-- Stored as { m = material name, c = hex color, v = variant }; invalid entries are skipped.
		if typeof(saved.recentLooks) == "table" then
			local looks: { Settings.RecentLook } = {}

			for _, entry in saved.recentLooks do
				if typeof(entry) ~= "table" or typeof(entry.m) ~= "string" or typeof(entry.c) ~= "string" then
					continue
				end

				local lookMaterial = Enum.Material:FromName(entry.m)
				local ok, color = pcall(Color3.fromHex, entry.c)

				if lookMaterial and ok and #looks < Settings.RECENT_LOOKS then
					table.insert(looks, { material = lookMaterial, color = color, variant = if typeof(entry.v) == "string" then entry.v else "" })
				end
			end

			s.recentLooks = looks
		end

		if typeof(saved.bakeSimplifyAngle) == "number" then
			s.bakeSimplifyAngle = saved.bakeSimplifyAngle
		end

		if typeof(saved.bakeHeightTolerance) == "number" then
			s.bakeHeightTolerance = saved.bakeHeightTolerance
		end

		if typeof(saved.bakeSimplifyEdges) == "boolean" then
			s.bakeSimplifyEdges = saved.bakeSimplifyEdges
		end

		if typeof(saved.bakeFlatPart) == "boolean" then
			s.bakeFlatPart = saved.bakeFlatPart
		end

		if typeof(saved.bakeFlatNoShadow) == "boolean" then
			s.bakeFlatNoShadow = saved.bakeFlatNoShadow
		end

		if typeof(saved.simplifyAngle) == "number" then
			s.simplifyAngle = saved.simplifyAngle
		end

		if saved.meshMode == "Simplify" or saved.meshMode == "Holes" then
			s.meshMode = saved.meshMode
		end

		if typeof(saved.ribbonTools) == "boolean" then
			s.ribbonTools = saved.ribbonTools
		end
	end)
end

local function recentLooksToSave(looks: { Settings.RecentLook }): { { [string]: string } }
	local result = {}

	for _, look in looks do
		table.insert(result, { m = look.material.Name, c = look.color:ToHex(), v = look.variant })
	end

	return result
end

local function snapshotSettings(s: Settings.State): { [string]: unknown }
	return {
		radius = s.radius,
		strength = s.strength,
		power = s.power,
		mode = s.mode,
		height = s.height,
		raiseToWorld = s.raiseToWorld,
		otherHeight = s.otherHeight,
		falloff = s.falloff,
		axis = s.axis,
		pickedAxis = { s.pickedAxis.X, s.pickedAxis.Y, s.pickedAxis.Z },
		paintSelectedOnly = s.paintSelectedOnly,
		noiseMin = s.noiseMin,
		noiseMax = s.noiseMax,
		tileSize = s.tileSize,
		autosew = s.autosew,
		faces = s.faces,
		stitchParts = s.stitchParts,
		stitchReach = s.stitchReach,
		autoBake = s.autoBake,
		smoothingAngle = s.smoothingAngle,
		showKeyHints = s.showKeyHints,
		showBrushDots = s.showBrushDots,
		showTooltips = s.showTooltips,
		paintMaterial = s.paintMaterial.Name,
		paintColor = s.paintColor:ToHex(),
		paintVariant = s.paintVariant,
		paintFine = s.paintFine,
		paintErase = s.paintErase,
		recentLooks = recentLooksToSave(s.recentLooks),
		ribbonTools = s.ribbonTools,
		simplifyAngle = s.simplifyAngle,
		bakeSimplifyAngle = s.bakeSimplifyAngle,
		bakeHeightTolerance = s.bakeHeightTolerance,
		bakeSimplifyEdges = s.bakeSimplifyEdges,
		bakeFlatPart = s.bakeFlatPart,
		bakeFlatNoShadow = s.bakeFlatNoShadow,
		meshMode = s.meshMode,
	}
end

local function valuesEqual(a: unknown, b: unknown): boolean
	if a == b then
		return true
	end

	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return false
	end

	local tableA = a :: { [unknown]: unknown }
	local tableB = b :: { [unknown]: unknown }

	for k, v in tableA do
		if not valuesEqual(v, tableB[k]) then
			return false
		end
	end

	for k in tableB do
		if tableA[k] == nil then
			return false
		end
	end

	return true
end

restoreSettings()

-- Track persisted changes and merge only modified keys into the saved table, so edits persist
-- immediately (even if Studio restarts or reloads without unloading cleanly), an untouched tab
-- or Play session never overwrites newer settings, and untouched fields pick up future defaults.
local lastSnapshot: { [string]: unknown } = snapshotSettings(Settings.get())
local dirtyKeys: { [string]: unknown } = {}
local saveTimer: thread? = nil

local function flushSettings()
	if saveTimer then
		task.cancel(saveTimer)
		saveTimer = nil
	end

	if next(dirtyKeys) == nil then
		return
	end

	local existing = plugin:GetSetting(SETTINGS_KEY)
	local merged: { [string]: unknown } = if typeof(existing) == "table" then table.clone(existing :: { [string]: unknown }) else {}

	for key, value in dirtyKeys do
		merged[key] = value
	end

	plugin:SetSetting(SETTINGS_KEY, merged)
	table.clear(dirtyKeys)
end

local stopSettingsSave = Settings.subscribe(function (s: Settings.State)
	local current = snapshotSettings(s)
	local changed = false

	for key, value in current do
		if not valuesEqual(value, lastSnapshot[key]) then
			lastSnapshot[key] = value
			dirtyKeys[key] = value
			changed = true
		end
	end

	if not changed then
		return
	end

	if saveTimer then
		task.cancel(saveTimer)
	end

	saveTimer = task.delay(SAVE_DEBOUNCE, function ()
		saveTimer = nil
		pcall(flushSettings)
	end)
end)

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"StrataPanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 280, 360, 220, 200)
)
widget.Name = "StrataPanel"
widget.Title = "Strata"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- Closing the panel stops any active tool so no brush holds the mouse while hidden, and ends
-- Edit points so no handles are left in the place without their panel.
widget:GetPropertyChangedSignal("Enabled"):Connect(function ()
	if not widget.Enabled then
		Settings.stopViewportTool()
		Settings.setEditingPoints(false)
		Settings.setOverlay("none")
		pcall(flushSettings)
	end
end)

local stopToolbar = startToolbar(plugin, widget)
local stopSession = Session.start()
local stopActivation = startActivation(plugin)
local stopBrushTool = startBrushTool(plugin)
local stopMaterialTool = startMaterialTool(plugin)
local stopMeshTool = startMeshTool(plugin)
local stopRadiusPreview = RadiusPreview.start(plugin)
local stopInput = Input.start(widget, function ()
	return Settings.activeTool(Settings.get()) ~= nil
end)
local stopPickFaceTool = PickFaceTool.start(plugin)
local stopStitchTool = startStitchTool(plugin)
local stopSampleTool = startSampleTool(plugin)
local stopPointEditor = PointEditor.start()

-- Mount the panel only while open so a closed panel does no work on Studio selection changes.
local root = ReactRoblox.createRoot(Instance.new("Folder"))

local function renderPanel()
	root:render(if widget.Enabled then ReactRoblox.createPortal(React.createElement(App), widget) else nil)
end

widget:GetPropertyChangedSignal("Enabled"):Connect(renderPanel)
renderPanel()

plugin.Unloading:Connect(function ()
	stopSettingsSave()
	pcall(flushSettings)
	root:unmount()
	stopBrushTool()
	stopMaterialTool()
	stopMeshTool()
	stopRadiusPreview()
	stopInput()
	stopPickFaceTool()
	stopStitchTool()
	stopSampleTool()
	stopPointEditor()
	stopActivation()
	stopToolbar()
	stopSession()
end)
