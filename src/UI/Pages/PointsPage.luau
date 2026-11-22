--!strict
--[[
	Page shown while Edit points is on: point counts, how to move points with Studio's tools, and
	the way back. Studio's selection drives everything here, so the page only reads it.
]]

local UI = script.Parent.Parent
local Plugin = UI.Parent
local State = Plugin.State

local Format = require(State.Format)
local Settings = require(State.Settings)

local PointEditor = require(Plugin.Viewport.PointEditor)

local Rows = require(UI.Rows)
local Icons = require(UI.Icons)

local function stop()
	Settings.setEditingPoints(false)
end

local function PointsPage()
	local info = PointEditor.info()

	return Rows.page({
		Title = Rows.title(
			1,
			"Edit points",
			stop,
			"**Finish editing points** and select the tiles again.\n\n"
				.. "Bakes edited tiles if `Bake automatically` is on."
		),

		Points = Rows.value(
			2,
			"Points",
			`{Format.count(info.selected)} of {Format.count(info.points)} selected`,
			nil,
			"**Point handles** on these tiles.\n\n"
				.. "- **Select**: click, `Ctrl + Click`, or drag a box.\n"
				.. "- **Move**: use `Move`, `Rotate`, or `Scale`.\n"
				.. "- **Remove**: press `Delete` (tile corners stay).\n\n"
				.. "> Exact coordinates: `Pivot > Origin` in Properties."
		),

		Tiles = Rows.value(3, "Tiles", Format.plural(info.tiles, "tile"), nil, "**Tiles being edited.**\n\n> `Done` selects them again."),

		Usage = Rows.paragraph(4, "Select handles in 3D, then use Move, Rotate, Scale, or Delete.", "dimmed"),

		Simplified = if info.simplified > 0
			then Rows.paragraph(5, "Points removed by Simplify have no handle.", "dimmed")
			else nil,

		SelectAll = Rows.button(
			6,
			"Select all points",
			PointEditor.selectAll,
			"**Select every handle** on these tiles.\n\n"
				.. "`Move` shifts the group, `Rotate` swings it around its center, and `Scale` spreads or gathers it.",
			info.points == 0,
			Icons.Select
		),

		Done = Rows.button(
			7,
			"Done",
			stop,
			"**Finish editing points** and select the tiles again.\n\n"
				.. "Bakes edited tiles if `Bake automatically` is on.\n\n"
				.. "> Each move or delete undoes with `Ctrl + Z`.",
			false,
			Icons.ApplyMarks,
			true
		),
	})
end

return PointsPage
