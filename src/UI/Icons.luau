--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Lucide icons (https://lucide.dev) sourced from the latte-soft/lucide-icons sprite sheets.
	Uses 16 px icons for the tool strip and status bar, and 14 px icons for in-page buttons and
	dropdown items. All icons tint to Studio's theme text color.
]]

local Plugin = script.Parent.Parent
local Packages = Plugin.Parent.Packages

local Lucide = require(Packages.Lucide)

export type Icon = {
	Image: string,
	Size: Vector2,
	RectOffset: Vector2,
	RectSize: Vector2,
	UseThemeColor: boolean,
}

local BUTTON_SIZE = Vector2.new(16, 16)
local ITEM_SIZE = Vector2.new(14, 14)

local function icon(name: string, size: Vector2?): Icon
	local asset = Lucide.GetAsset(name, 48)

	return {
		Image = asset.Url,
		Size = size or BUTTON_SIZE,
		RectOffset = asset.ImageRectOffset,
		RectSize = asset.ImageRectSize,
		UseThemeColor = true,
	}
end

local function item(name: string): Icon
	return icon(name, ITEM_SIZE)
end

return table.freeze({
	-- Tool strip, chrome bands, and status bar (16 px).
	Raise = icon("arrow-up-from-line"),
	Lower = icon("arrow-down-to-line"),
	Smooth = icon("waves"),
	RaiseTo = icon("arrow-up-to-line"),
	Material = icon("paintbrush"),
	Mesh = icon("triangle"),
	PickFaces = icon("mouse-pointer-click"),
	Stitch = icon("magnet"),
	Back = icon("arrow-left"),
	Stop = icon("circle-stop"),
	Close = icon("x"),
	Help = icon("circle-help"),
	Settings = icon("settings"),
	ChevronRight = icon("chevron-right"),
	ChevronDown = icon("chevron-down"),

	-- In-page buttons (14 px).
	Clear = item("x"),
	CopyAppearance = item("pipette"),
	Select = item("box-select"),
	EditTiles = item("sliders-horizontal"),
	EditPoints = item("pen-tool"),
	RoundFolds = item("spline"),
	SplitTiles = item("grid-2x2"),
	SewTiles = item("link"),
	StitchTiles = item("magnet"),
	BakeTiles = item("package"),
	UnbakeTiles = item("package-open"),
	RebakeAll = item("refresh-cw"),
	Noise = item("dices"),
	ResetShape = item("fold-vertical"),
	ClearPaint = item("eraser"),
	FillHoles = item("puzzle"),
	Unsimplify = item("waypoints"),
	CreateArea = item("mountain"),
	StartPickFaces = item("mouse-pointer-click"),
	PaintMode = item("paintbrush"),
	EraseMode = item("eraser"),
	SimplifyMode = item("minimize-2"),
	CutMode = item("scissors"),
	ApplyMarks = item("check"),
	Warning = item("triangle-alert"),

	-- Dropdown items (14 px).
	FacesTop = item("arrow-up"),
	FacesTopSides = item("box"),
	FacesAll = item("boxes"),
	FalloffSoft = item("spline"),
	FalloffHard = item("square"),
	AxisFace = item("square-arrow-up"),
	AxisUp = item("arrow-up"),
	AxisX = item("move-horizontal"),
	AxisZ = item("move-diagonal"),
	AxisPicked = item("pipette"),
	AxisCurved = item("spline"),
})
