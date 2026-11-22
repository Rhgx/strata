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
			"**Finish editing points**.\n\nBakes edited tiles if `Bake automatically` is on."
		),

		Points = Rows.value(
			2,
			"Points",
			`{Format.count(info.selected)} of {Format.count(info.points)} selected`,
			nil,
			"**Point handles** on the edited tiles.\n\n"
				.. "Points shared by tiles have one handle, so seams stay closed."
		),

		Tiles = Rows.value(3, "Tiles", Format.plural(info.tiles, "tile"), nil, "**Tiles being edited**.\n\n> Done selects them again."),

		Usage = Rows.paragraph(
			4,
			"Select points in 3D (click, Ctrl + click, or drag a box), then move them with Studio's Move, Rotate, or Scale tools. "
				.. "For exact coordinates, edit Pivot > Origin in Properties."
		),

		Simplified = if info.simplified > 0
			then Rows.paragraph(5, "Points removed by Simplify have no handle; they follow the surface.")
			else nil,

		SelectAll = Rows.button(
			6,
			"Select all points",
			PointEditor.selectAll,
			"**Select every point** on the edited tiles.\n\n> Then Move or Rotate them together.",
			info.points == 0,
			Icons.SelectAll
		),

		Done = Rows.button(
			7,
			"Done",
			stop,
			"**Finish editing points** and select the tiles again.\n\n> Each move undoes on its own with `Ctrl + Z`.",
			false,
			Icons.ApplyMarks,
			true
		),
	})
end

return PointsPage
