--!strict
-- Set-and-forget preferences, opened from the gear in the status bar.
local Packages = script.Parent.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(script.Parent.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.Parent.State.Status)
local Bake = require(script.Parent.Parent.Parent.Actions.Bake)
local Format = require(script.Parent.Parent.Format)
local Rows = require(script.Parent.Parent.Rows)

local e = React.createElement

local function toggle(key: "autosew" | "stitchParts" | "autoBake" | "showKeyHints")
	return function()
		Settings.update(function(s)
			if key == "autosew" then
				s.autosew = not s.autosew
			elseif key == "stitchParts" then
				s.stitchParts = not s.stitchParts
			elseif key == "autoBake" then
				s.autoBake = not s.autoBake
			else
				s.showKeyHints = not s.showKeyHints
			end
		end)
	end
end

local function SettingsPage(props: { settings: Settings.State })
	local settings = props.settings
	return Rows.page({
		Header = Rows.header(1, "Settings", function()
			Settings.setOverlay("none")
		end, "**Close settings** (`Esc`)."),

		EdgesHeading = Rows.section(2, "Edges"),
		Autosew = Rows.checkbox(
			3,
			"Auto-sew after edits",
			settings.autosew,
			toggle("autosew"),
			"**Close seams automatically** after edits.\n\n"
				.. "Sews edited tiles to neighbors after each paint stroke and `Detail` change."
		),
		KeepStitched = Rows.checkbox(
			4,
			"Keep edges stitched",
			settings.stitchParts,
			toggle("stitchParts"),
			"**Lock tile edges** touching nearby parts.\n\n"
				.. "Holds edges in place while painting, changing `Detail` or adding noise.\n\n"
				.. "> Turn off to sculpt freely next to parts."
		),
		Reach = Rows.property(
			5,
			"Reach",
			e(StudioComponents.NumericInput, {
				Value = settings.stitchReach,
				Min = Settings.STITCH_REACH_MIN,
				Max = Settings.STITCH_REACH_MAX,
				Step = 0.5,
				Arrows = true,
				OnValidChanged = function(value: number)
					Settings.update(function(s)
						s.stitchReach = value
					end)
				end,
			}),
			"**Max snap distance** in studs.\n\n"
				.. "Used by the `Stitch` tool and the tile page's `Stitch` button to snap tile edges to part edges.\n\n"
				.. "> Example: 2 for roads and curbs, more for wider gaps."
		),

		BakingHeading = Rows.section(6, "Baking"),
		AutoBake = Rows.checkbox(
			7,
			"Bake automatically",
			settings.autoBake,
			toggle("autoBake"),
			"**Auto-bake tiles** into unions.\n\n"
				.. "Runs when a tool stops, and after `Create` and edit actions."
		),
		Smoothing = Rows.property(
			8,
			"Smoothing",
			e(StudioComponents.NumericInput, {
				Value = settings.smoothingAngle,
				Min = Settings.SMOOTHING_MIN,
				Max = Settings.SMOOTHING_MAX,
				Step = 5,
				Slider = true,
				OnValidChanged = function(value: number)
					Settings.update(function(s)
						s.smoothingAngle = value
					end)
				end,
				OnSubmitted = function(value: number)
					xpcall(function()
						local count = Bake.applySmoothing(value)
						if count > 0 then
							Status.post("success", `Set smoothing to {value} deg on {Format.plural(count, "baked tile")}.`)
						end
					end, function(message)
						Status.post("error", tostring(message))
					end)
				end,
			}),
			"**Smooth shading angle** in degrees.\n\n"
				.. "- **0**: sharp low-poly facets.\n"
				.. "- **45 to 60**: smooth rolling hills.\n\n"
				.. "> Applies to every baked tile in the place."
		),

		ViewportHeading = Rows.section(10, "Viewport"),
		KeyHints = Rows.checkbox(
			11,
			"Show key hints",
			settings.showKeyHints,
			toggle("showKeyHints"),
			"**Show shortcut bar** in the 3D view.\n\n"
				.. "Displayed at the bottom while a tool runs."
		),
	})
end

return SettingsPage
