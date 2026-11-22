--!strict
--[[
	Persistent preferences overlay opened from the status bar gear icon, organized into Edges,
	Baking, and Interface tabs.
]]

local UI = script.Parent.Parent
local Plugin = UI.Parent
local State = Plugin.State
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Plugin.Scene.Query)

local Bake = require(Plugin.Actions.Bake)

local Rows = require(UI.Rows)
local Icons = require(UI.Icons)

local e = React.createElement

type ToggleKey =
	"autosew"
	| "stitchParts"
	| "autoBake"
	| "showKeyHints"
	| "showBrushDots"
	| "ribbonTools"
	| "bakeSimplifyEdges"
	| "bakeFlatPart"
	| "bakeFlatNoShadow"

type Tab = "edges" | "baking" | "interface"

local TABS: { { id: Tab, label: string, tip: string } } = {
	{ id = "edges", label = "Edges", tip = "**Edges and stitching**: sewing tile seams and snapping edges onto parts." },
	{ id = "baking", label = "Baking", tip = "**Baking**: merging tiles into unions, shading and bake optimizations." },
	{ id = "interface", label = "Interface", tip = "**Interface**: 3D view hints, brush dots and ribbon buttons." },
}

-- Combined height of the fixed top area (top padding, header row, gap, tab strip, bottom gap).
local TOP_HEIGHT = 6 + 22 + 4 + Rows.BUTTON_HEIGHT + 6
local TAB_GAP = 4
-- Require a second confirmation click for Rebake all above this tile count.
local CONFIRM_ABOVE = 20
local CONFIRM_SECONDS = 4

-- Persists the active Settings tab for the current Studio session.
local lastTab: Tab = "edges"

local function toggle(key: ToggleKey)
	return function ()
		Settings.update(function (s)
			if key == "autosew" then
				s.autosew = not s.autosew
			elseif key == "stitchParts" then
				s.stitchParts = not s.stitchParts
			elseif key == "autoBake" then
				s.autoBake = not s.autoBake
			elseif key == "showKeyHints" then
				s.showKeyHints = not s.showKeyHints
			elseif key == "showBrushDots" then
				s.showBrushDots = not s.showBrushDots
			elseif key == "bakeSimplifyEdges" then
				s.bakeSimplifyEdges = not s.bakeSimplifyEdges
			elseif key == "bakeFlatPart" then
				s.bakeFlatPart = not s.bakeFlatPart
			elseif key == "bakeFlatNoShadow" then
				s.bakeFlatNoShadow = not s.bakeFlatNoShadow
			else
				s.ribbonTools = not s.ribbonTools
			end
		end)
	end
end

local function edgesTab(settings: Settings.State)
	return {
		SewHeading = Rows.section(1, "Sewing", true),

		Autosew = Rows.checkbox(
			2,
			"Auto-sew after edits",
			settings.autosew,
			toggle("autosew"),
			"**Close tile seams automatically** after edits.\n\n"
				.. "Welds edited tiles to neighboring tiles after each brush stroke and `Detail` change.\n\n"
				.. "> Turn off to sculpt tiles apart, then use `Sew tiles` manually."
		),

		StitchHeading = Rows.section(3, "Stitching"),

		KeepStitched = Rows.checkbox(
			4,
			"Keep edges stitched",
			settings.stitchParts,
			toggle("stitchParts"),
			"**Lock tile edges** touching nearby parts.\n\n"
				.. "Holds edges against roads, curbs and walls while painting, changing `Detail` or adding noise.\n\n"
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

				OnValidChanged = function (value: number)
					Settings.update(function (s)
						s.stitchReach = value
					end)
				end,
			}),
			"**Max stitch distance** in studs.\n\n"
				.. "How far a tile edge may move to snap onto a part in the `Stitch` tool or tile `Stitch` button.\n\n"
				.. "> Example: 2 for roads and curbs, higher for wider gaps."
		),
	}
end

-- Rebakes every tile in the place so updated bake optimization settings apply retroactively.
local function RebakeButton(props: { LayoutOrder: number })
	local total = Query.placeInfo().total
	local confirming, setConfirming = React.useState(false)

	React.useEffect(function (): (() -> ())?
		if not confirming then
			return nil
		end

		local timer = task.delay(CONFIRM_SECONDS, function ()
			setConfirming(false)
		end)

		return function ()
			task.cancel(timer)
		end
	end, { confirming })

	local function rebake()
		setConfirming(false)

		local ok, result = pcall(Bake.rebakeAll)
		Bake.report(ok, result, "Rebaked")
	end

	return Rows.button(
		props.LayoutOrder,
		if confirming then `Confirm rebake ({total})` else `Rebake all ({total})`,
		function ()
			if total > CONFIRM_ABOVE and not confirming then
				setConfirming(true)
			else
				rebake()
			end
		end,
		"**Bake every tile again** with the settings above, as one undo step.\n\n"
			.. "Tiles baked before a change keep their old unions until rebaked.\n\n"
			.. `> Can take a few seconds on big places. Over {CONFIRM_ABOVE} tiles, click twice.`,
		total == 0,
		Icons.BakeAll
	)
end

local function bakingTab(settings: Settings.State)
	return {
		GeneralHeading = Rows.section(1, "General", true),

		AutoBake = Rows.checkbox(
			2,
			"Bake automatically",
			settings.autoBake,
			toggle("autoBake"),
			"**Merge edited tiles** into unions automatically.\n\n"
				.. "Runs when a tool stops, and after `Create` and edit actions. Baked textures run smoothly across triangles and tiles.\n\n"
				.. "> Turn off to keep tiles as editable wedges until you click `Bake`."
		),

		Smoothing = Rows.property(
			3,
			"Smoothing",
			e(StudioComponents.NumericInput, {
				Value = settings.smoothingAngle,
				Min = Settings.SMOOTHING_MIN,
				Max = Settings.SMOOTHING_MAX,
				Step = 5,
				Slider = true,

				OnValidChanged = function (value: number)
					Settings.update(function (s)
						s.smoothingAngle = value
					end)
				end,

				OnSubmitted = function (value: number)
					xpcall(function ()
						local count = Bake.applySmoothing(value)

						if count > 0 then
							Status.post("success", `Set smoothing to {value} deg on {Format.plural(count, "baked tile")}.`)
						end
					end, function (message)
						Status.post("error", tostring(message))
					end)
				end,
			}),
			"**Smooth shading angle** in degrees for baked unions.\n\n"
				.. "- **0**: sharp, flat-shaded facets.\n"
				.. "- **45 to 60**: smooth rolling hills.\n\n"
				.. "> Applies right away to every baked tile in this place."
		),

		OptimizationHeading = Rows.section(4, "Optimization"),

		OptimizationNote = Rows.paragraph(
			5,
			"Lighter unions with no visible change. Tiles keep full detail for editing. Applies to the next bake.",
			"dimmed"
		),

		Simplify = Rows.property(
			6,
			"Simplify",
			e(StudioComponents.NumericInput, {
				Value = settings.bakeSimplifyAngle,
				Min = Settings.BAKE_SIMPLIFY_MIN,
				Max = Settings.BAKE_SIMPLIFY_MAX,
				Step = 0.5,
				Slider = true,

				OnValidChanged = function (value: number)
					Settings.update(function (s)
						s.bakeSimplifyAngle = value
					end)
				end,
			}),
			"**Leave out points on flat ground**: points where the ground bends less than this many degrees are left out of the union.\n\n"
				.. "Flat areas bake from a few big triangles, so bakes are faster and unions cheaper to render.\n\n"
				.. "- **0**: off.\n"
				.. "- **1**: no visible change (default).\n\n"
				.. "> Painted borders and holes always keep their points."
		),

		Tolerance = Rows.property(
			7,
			"Tolerance",
			e(StudioComponents.NumericInput, {
				Value = settings.bakeHeightTolerance,
				Min = Settings.BAKE_TOLERANCE_MIN,
				Max = Settings.BAKE_TOLERANCE_MAX,
				Step = 0.01,
				Slider = true,

				OnValidChanged = function (value: number)
					Settings.update(function (s)
						s.bakeHeightTolerance = value
					end)
				end,
			}),
			"**Ignore tiny bumps** up to this many studs when leaving points out of the union.\n\n"
				.. "Catches noise and leftover brush wobble that `Simplify` sees as bends. The baked surface stays within about this distance of the tile.\n\n"
				.. "- **0**: off.\n"
				.. "- **0.05**: no visible change (default)."
		),

		SimplifyEdges = Rows.checkbox(
			8,
			"Simplify straight edges",
			settings.bakeSimplifyEdges,
			toggle("bakeSimplifyEdges"),
			"**Leave out tile edge points** on straight stretches of a tile's border.\n\n"
				.. "Points stay within 0.005 studs of the edge, so seams with neighboring tiles stay closed. Corners, painted borders and holes keep their points."
		),

		FlatPart = Rows.checkbox(
			9,
			"Plain Part for flat tiles",
			settings.bakeFlatPart,
			toggle("bakeFlatPart"),
			"**Bake flat tiles to a plain Part** instead of a union.\n\n"
				.. "Applies to flat rectangular tiles in one look with no holes. Parts cost less to store and render than unions.\n\n"
				.. "> Off by default: a Part's texture can line up differently from the unions next to it."
		),

		FlatNoShadow = Rows.checkbox(
			10,
			"No shadow on flat tiles",
			settings.bakeFlatNoShadow,
			toggle("bakeFlatNoShadow"),
			"**Turn off shadows** for baked tiles that are flat.\n\n"
				.. "Flat ground casts almost no visible shadow, and skipping it saves shadow rendering.\n\n"
				.. "> Off by default: things under a flat tile, such as a tunnel, are lit as if it were not there."
		),

		RebakeDivider = Rows.divider(11),
		Rebake = e(RebakeButton, { LayoutOrder = 12 }),
	}
end

local function interfaceTab(settings: Settings.State)
	return {
		ViewportHeading = Rows.section(1, "3D view", true),

		KeyHints = Rows.checkbox(
			2,
			"Show viewport key hints",
			settings.showKeyHints,
			toggle("showKeyHints"),
			"**Show shortcut bar** in the 3D view.\n\n" .. "Displays active keys along the bottom of the viewport while a tool runs."
		),

		BrushDots = Rows.checkbox(
			3,
			"Show brush dots",
			settings.showBrushDots,
			toggle("showBrushDots"),
			"**Show point dots** inside the sculpt brush.\n\n"
				.. "Marks which points `Raise`, `Lower`, `Smooth` and `Raise To` will move, and nearby points when the ring holds none.\n\n"
				.. "> Off by default: the brush ring alone still dims when it holds no point."
		),

		RibbonHeading = Rows.section(4, "Ribbon"),

		RibbonTools = Rows.checkbox(
			5,
			"Tools on Plugins ribbon",
			settings.ribbonTools,
			toggle("ribbonTools"),
			"**Add tool buttons** to Studio's `Plugins` ribbon tab.\n\n"
				.. "Adds a `Strata Tools` group with all 8 tools. The `Strata` panel button is always shown.\n\n"
				.. "> Off by default: the panel's tool strip already has every tool."
		),
	}
end

local function SettingsPage(props: { settings: Settings.State })
	local settings = props.settings
	local theme = StudioComponents.useTheme()
	local tab, setTab = React.useState(lastTab)

	-- Positioned manually instead of Rows.grid because UIGridLayout can wrap the third cell
	-- onto a second line when fractional widths round up.
	local tabButtons: { [string]: unknown } = {}
	local count = #TABS

	for i, item in TABS do
		tabButtons[item.id] = e("Frame", {
			Position = UDim2.new((i - 1) / count, math.floor(TAB_GAP * (i - 1) / count), 0, 0),
			Size = UDim2.new(1 / count, -math.ceil(TAB_GAP * (count - 1) / count), 1, 0),
			BackgroundTransparency = 1,
		}, {
			Tip = Rows.withTooltip(
				item.tip,
				e(StudioComponents.Button, {
					Size = UDim2.fromScale(1, 1),
					Text = item.label,
					Selected = tab == item.id,

					OnActivated = function ()
						lastTab = item.id
						setTab(item.id)
					end,
				})
			),
		})
	end

	local content = if tab == "edges" then edgesTab(settings) elseif tab == "baking" then bakingTab(settings) else interfaceTab(settings)

	return e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		-- Keep header and tab strip fixed while tab contents scroll underneath.
		Top = e("Frame", {
			Size = UDim2.new(1, 0, 0, TOP_HEIGHT),
			BackgroundTransparency = 1,
		}, {
			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, 7),
				PaddingRight = UDim.new(0, 7),
				PaddingTop = UDim.new(0, 6),
			}),

			Layout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),

			Header = Rows.header(1, "Settings", function ()
				Settings.setOverlay("none")
			end, "**Close settings** (`Esc`)."),

			Tabs = e("Frame", {
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, Rows.BUTTON_HEIGHT),
				BackgroundTransparency = 1,
			}, tabButtons),
		}),

		Divider = e("Frame", {
			Position = UDim2.fromOffset(0, TOP_HEIGHT),
			Size = UDim2.new(1, 0, 0, 1),
			BorderSizePixel = 0,
			BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border),
		}),

		Body = e("Frame", {
			Position = UDim2.fromOffset(0, TOP_HEIGHT + 1),
			Size = UDim2.new(1, 0, 1, -(TOP_HEIGHT + 1)),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
		}, {
			-- Key by tab name so switching tabs resets scroll position to the top.
			[tab] = Rows.page(content),
		}),
	})
end

return SettingsPage
