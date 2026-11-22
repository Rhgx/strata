--!strict
--[[
	Lucide icons (https://lucide.dev) from the latte-soft/lucide-icons sprite sheets. 16 px for the
	tool strip and status bar; 14 px for buttons inside pages and dropdown items, so labels fit
	two columns at the minimum panel width. Tinted with the Studio theme's text color.
]]

local Lucide = require(script.Parent.Parent.Parent.Packages.Lucide)

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
	-- Tool strip and status bar (16 px).
	Raise = icon("arrow-up-from-line"),
	Lower = icon("arrow-down-to-line"),
	Smooth = icon("waves"),
	RaiseTo = icon("arrow-up-to-line"),
	Material = icon("paintbrush"),
	Mesh = icon("triangle"),
	PickFaces = icon("mouse-pointer-click"),
	Stitch = icon("magnet"),
	Help = icon("circle-help"),
	Settings = icon("settings"),
	ChevronRight = icon("chevron-right"),
	ChevronDown = icon("chevron-down"),

	-- Buttons inside pages (14 px).
	StopTool = item("circle-stop"),
	Noise = item("audio-waveform"),
	CreateArea = item("grid-3x3"),
	StartPickFaces = item("mouse-pointer-click"),
	Clear = item("x"),
	ClearPaint = item("eraser"),
	SimplifyMode = item("triangle"),
	CutMode = item("scissors"),
	RestoreHoles = item("rotate-ccw"),
	RestorePoints = item("rotate-ccw"),
	AutoSimplify = item("wand"),
	ApplyMarks = item("check"),
	ClearMarks = item("x"),
	CopyAppearance = item("pipette"),
	BakeAll = item("layers"),
	SelectAll = item("box-select"),
	Back = item("arrow-left"),
	RoundFolds = item("radius"),
	SplitTiles = item("grid-2x2"),
	SewTiles = item("link-2"),
	StitchTiles = item("magnet"),
	BakeTiles = item("group"),
	UnbakeTiles = item("ungroup"),

	-- Dropdown items.
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
