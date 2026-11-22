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

type ToggleKey = "autosew" | "stitchParts" | "autoBake" | "showKeyHints" | "ribbonTools"

local function toggle(key: ToggleKey)
	return function()
		Settings.update(function(s)
			if key == "autosew" then
				s.autosew = not s.autosew
			elseif key == "stitchParts" then
				s.stitchParts = not s.stitchParts
			elseif key == "autoBake" then
				s.autoBake = not s.autoBake
			elseif key == "showKeyHints" then
				s.showKeyHints = not s.showKeyHints
			else
				s.ribbonTools = not s.ribbonTools
			end
		end)
	end
end

-- A 1 px divider with a bit of breathing room above it so categories read as separate groups.
local function CategoryDivider(props: { LayoutOrder: number })
	local theme = StudioComponents.useTheme()
	return e("Frame", {
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.new(1, 0, 0, 7),
		BackgroundTransparency = 1,
	}, {
		Line = e("Frame", {
			Position = UDim2.fromOffset(0, 4),
			Size = UDim2.new(1, 0, 0, 1),
			BorderSizePixel = 0,
			BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border),
		}),
	})
end

local function SettingsPage(props: { settings: Settings.State })
	local settings = props.settings
	return Rows.page({
		Header = Rows.header(1, "Settings", function()
			Settings.setOverlay("none")
		end, "**Close settings** (`Esc`)."),
		HeaderDivider = Rows.divider(2),

		EdgesHeading = Rows.section(3, "Edges and stitching", true),
		EdgesNote = Rows.paragraph(4, "Keep tile seams closed and edges snapped to nearby parts.", "dimmed"),
		Autosew = Rows.checkbox(
			5,
			"Auto-sew after edits",
			settings.autosew,
			toggle("autosew"),
			"**Close tile seams automatically** after edits.\n\n"
				.. "Welds edited tiles to neighboring tiles after each brush stroke and `Detail` change.\n\n"
				.. "> Turn off to sculpt tiles apart, then use `Sew tiles` manually."
		),
		KeepStitched = Rows.checkbox(
			6,
			"Keep edges stitched",
			settings.stitchParts,
			toggle("stitchParts"),
			"**Lock tile edges** touching nearby parts.\n\n"
				.. "Holds edges against roads, curbs and walls while painting, changing `Detail` or adding noise.\n\n"
				.. "> Turn off to sculpt freely next to parts."
		),
		Reach = Rows.property(
			7,
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
			"**Max stitch distance** in studs.\n\n"
				.. "How far a tile edge may move to snap onto a part in the `Stitch` tool or tile `Stitch` button.\n\n"
				.. "> Example: 2 for roads and curbs, higher for wider gaps."
		),

		BakingDivider = e(CategoryDivider, { LayoutOrder = 8 }),
		BakingHeading = Rows.section(9, "Baking and shading", true),
		BakingNote = Rows.paragraph(10, "Baked tiles merge into unions. Smoothing is their shading angle in degrees.", "dimmed"),
		AutoBake = Rows.checkbox(
			11,
			"Bake automatically",
			settings.autoBake,
			toggle("autoBake"),
			"**Merge edited tiles** into unions automatically.\n\n"
				.. "Runs when a tool stops, and after `Create` and edit actions. Baked textures run smoothly across triangles and tiles.\n\n"
				.. "> Turn off to keep tiles as editable wedges until you click `Bake`."
		),
		Smoothing = Rows.property(
			12,
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
			"**Smooth shading angle** in degrees for baked unions.\n\n"
				.. "- **0**: sharp, flat-shaded facets.\n"
				.. "- **45 to 60**: smooth rolling hills.\n\n"
				.. "> Applies right away to every baked tile in this place."
		),

		InterfaceDivider = e(CategoryDivider, { LayoutOrder = 13 }),
		InterfaceHeading = Rows.section(14, "Interface", true),
		KeyHints = Rows.checkbox(
			15,
			"Show viewport key hints",
			settings.showKeyHints,
			toggle("showKeyHints"),
			"**Show shortcut bar** in the 3D view.\n\n"
				.. "Displays active keys along the bottom of the viewport while a tool runs."
		),
		RibbonTools = Rows.checkbox(
			16,
			"Tools on Plugins ribbon",
			settings.ribbonTools,
			toggle("ribbonTools"),
			"**Add tool buttons** to Studio's `Plugins` ribbon tab.\n\n"
				.. "Adds a `Strata Tools` group with all 7 tools. The `Strata` panel button is always shown.\n\n"
				.. "> Off by default: the panel's tool strip already has every tool."
		),
	})
end

return SettingsPage
