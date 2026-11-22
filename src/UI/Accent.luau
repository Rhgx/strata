--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Accent colors layered onto Studio's theme. Each brush tool uses a single hue shared with its
	3D viewport cursor so the tool strip, tool page, and viewport read cohesively. Success status
	messages use green; everything else defers to Studio's theme colors. Light theme values are
	darkened to preserve contrast on light backgrounds.
]]

local Plugin = script.Parent.Parent

local Settings = require(Plugin.State.Settings)

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

-- Detects light themes by background luminance rather than theme name so custom themes work too.
local function isLight(theme: StudioTheme): boolean
	local background = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)

	return background.R + background.G + background.B > 1.5
end

-- Returns the accent color for `tool`, or nil for neutral click tools (Pick faces, Stitch).
function Accent.tool(tool: Tool, theme: StudioTheme): Color3?
	return (if isLight(theme) then LIGHT else DARK)[tool]
end

function Accent.success(theme: StudioTheme): Color3
	return if isLight(theme) then SUCCESS_LIGHT else SUCCESS_DARK
end

return Accent
