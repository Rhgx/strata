--!strict
local Packages = script.Parent.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)

local App = require(script.UI.App)
local PickFaceTool = require(script.Viewport.PickFaceTool)
local Session = require(script.Scene.Session)
local Settings = require(script.State.Settings)
local startActivation = require(script.Viewport.Activation)
local startBrushTool = require(script.Viewport.BrushTool)
local startSampleTool = require(script.Viewport.SampleTool)
local startStitchTool = require(script.Viewport.StitchTool)
local startToolbar = require(script.Viewport.Toolbar)

local SETTINGS_KEY = "StrataSettings"

-- Restores settings from the last session. Tools always start off.
local function restoreSettings()
	local saved = plugin:GetSetting(SETTINGS_KEY)
	if typeof(saved) ~= "table" then
		return
	end
	Settings.update(function(s)
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
		-- Plugin settings are JSON, so the picked axis is stored as { x, y, z }.
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
	end)
end

local function saveSettings()
	local s = Settings.get()
	plugin:SetSetting(SETTINGS_KEY, {
		radius = s.radius,
		strength = s.strength,
		power = s.power,
		mode = s.mode,
		height = s.height,
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
	})
end

restoreSettings()

local widget = plugin:CreateDockWidgetPluginGuiAsync(
	"StrataPanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 280, 360, 220, 200)
)
widget.Name = "Strata"
widget.Title = "Strata"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- Closing the panel stops any running tool, so no brush keeps the mouse while hidden.
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	if not widget.Enabled then
		Settings.stopViewportTool()
		Settings.setOverlay("none")
		saveSettings()
	end
end)

local stopToolbar = startToolbar(plugin, widget)
local stopSession = Session.start()
local stopActivation = startActivation(plugin)
local stopBrushTool = startBrushTool(plugin)
local stopPickFaceTool = PickFaceTool.start(plugin)
local stopStitchTool = startStitchTool(plugin)
local stopSampleTool = startSampleTool(plugin)

-- The panel is only mounted while it is open, so a closed panel does no work on every Studio
-- selection change.
local root = ReactRoblox.createRoot(Instance.new("Folder"))
local function renderPanel()
	root:render(if widget.Enabled then ReactRoblox.createPortal(React.createElement(App), widget) else nil)
end
widget:GetPropertyChangedSignal("Enabled"):Connect(renderPanel)
renderPanel()

plugin.Unloading:Connect(function()
	saveSettings()
	root:unmount()
	stopBrushTool()
	stopPickFaceTool()
	stopStitchTool()
	stopSampleTool()
	stopActivation()
	stopToolbar()
	stopSession()
end)
