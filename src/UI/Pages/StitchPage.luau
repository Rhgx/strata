--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Options page for the active Stitch tool.
]]

local UI = script.Parent.Parent
local Plugin = UI.Parent
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(Plugin.State.Settings)

local Session = require(Plugin.Scene.Session)

local Rows = require(UI.Rows)

local e = React.createElement

local function StitchPage(props: { settings: Settings.State })
	local settings = props.settings
	local hasTiles = #Session.models() > 0

	return Rows.page({
		Title = Rows.title(
			1,
			"Stitch to part",
			Settings.stopViewportTool,
			"**Stop stitching** (`Esc`).\n\nBakes stitched tiles if `Bake automatically` is on."
		),

		Warning = if hasTiles then nil else Rows.paragraph(2, "No terrain yet. Select parts or use Pick faces.", "warning"),

		Reach = Rows.property(
			3,
			"Reach",
			e(StudioComponents.NumericInput, {
				Value = settings.stitchReach,
				Min = Settings.STITCH_REACH_MIN,
				Max = Settings.STITCH_REACH_MAX,
				Step = 0.5,
				Arrows = true,

				OnValidChanged = function (value: number)
					Settings.update(function (s)
						s.stitchReach = value
					end)
				end,
			}),
			"**Max snap distance** in studs.\n\n"
				.. "How far a tile edge may move to meet a part edge.\n\n"
				.. "> Example: 2 for roads and curbs, more for wider gaps.\n"
				.. "> Change in 3D: `Ctrl + Scroll` or `[` and `]`."
		),
	})
end

return StitchPage
