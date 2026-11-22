--!strict
--[[
	The few colors the panel adds to Studio's theme. Each brush tool has one color, the same hue
	as its cursor in the 3D view, so the tool strip, the tool page and the viewport read as one.
	Success messages are green. Everything else stays in Studio's own theme colors. Light theme
	values are darker, so they keep their contrast on a light background.
]]

local Settings = require(script.Parent.Parent.State.Settings)

type Tool = Settings.Tool

local DARK: { [Tool]: Color3 } = {
	Raise = Color3.fromRGB(96, 200, 96),
	Lower = Color3.fromRGB(230, 96, 80),
	Smooth = Color3.fromRGB(80, 160, 255),
	RaiseTo = Color3.fromRGB(230, 190, 70),
	Material = Color3.fromRGB(56, 200, 185),
	Mesh = Color3.fromRGB(255, 150, 40),
}

local LIGHT: { [Tool]: Color3 } = {
	Raise = Color3.fromRGB(30, 128, 46),
	Lower = Color3.fromRGB(196, 52, 42),
	Smooth = Color3.fromRGB(30, 108, 214),
	RaiseTo = Color3.fromRGB(158, 108, 0),
	Material = Color3.fromRGB(14, 126, 118),
	Mesh = Color3.fromRGB(188, 86, 12),
}

local SUCCESS_DARK = Color3.fromRGB(96, 200, 110)
local SUCCESS_LIGHT = Color3.fromRGB(24, 122, 44)

local Accent = {}

-- By the background's brightness rather than the theme's name, so custom themes work too.
local function isLight(theme: StudioTheme): boolean
	local background = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
	return background.R + background.G + background.B > 1.5
end

-- The tool's color, or nil for the click tools (Pick faces, Stitch), which stay neutral.
function Accent.tool(tool: Tool, theme: StudioTheme): Color3?
	return (if isLight(theme) then LIGHT else DARK)[tool]
end

function Accent.success(theme: StudioTheme): Color3
	return if isLight(theme) then SUCCESS_LIGHT else SUCCESS_DARK
end

return Accent
