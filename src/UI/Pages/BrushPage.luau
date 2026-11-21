--!strict
-- Options of the running brush (Raise, Lower, Smooth or Raise To).
local Packages = script.Parent.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(script.Parent.Parent.Parent.State.Settings)
local Session = require(script.Parent.Parent.Parent.Scene.Session)
local Query = require(script.Parent.Parent.Parent.Scene.Query)
local Icons = require(script.Parent.Parent.Icons)
local Rows = require(script.Parent.Parent.Rows)
local Dropdown = require(script.Parent.Parent.Dropdown)

local e = React.createElement

local FALLOFF_ITEMS = {
	{ Id = "Soft", Text = "Soft", Icon = Icons.FalloffSoft },
	{ Id = "Hard", Text = "Hard", Icon = Icons.FalloffHard },
}

local AXIS_ICONS: { [Settings.Axis]: Icons.Icon } = {
	Face = Icons.AxisFace,
	Up = Icons.AxisUp,
	X = Icons.AxisX,
	Z = Icons.AxisZ,
	Picked = Icons.AxisPicked,
	Subdiv = Icons.AxisCurved,
}

local AXIS_ITEMS = {}
for _, axis: Settings.Axis in Settings.axes() do
	table.insert(AXIS_ITEMS, { Id = axis, Text = Settings.axisLabel(axis), Icon = AXIS_ICONS[axis] })
end

local function slider(value: number, min: number, max: number, onChanged: (number) -> ())
	return e(StudioComponents.NumericInput, {
		Value = value,
		Min = min,
		Max = max,
		Step = 0.5,
		Slider = true,
		OnValidChanged = onChanged,
	})
end

local function BrushPage(props: { settings: Settings.State })
	local settings = props.settings
	local mode: Settings.BrushMode = settings.mode

	local children: { [string]: unknown } = {
		Title = Rows.title(1, Settings.modeLabel(mode)),
		Radius = Rows.property(
			3,
			"Radius",
			slider(settings.radius, Settings.RADIUS_MIN, Settings.RADIUS_MAX, function(value: number)
				Settings.update(function(s)
					s.radius = value
				end)
			end),
			"**Brush size** in studs.\n\n"
				.. "> Resize in 3D: `Ctrl + Scroll` or `Alt + Drag`."
		),
		DirectionHeading = Rows.section(8, "Direction"),
		Axis = Rows.property(
			9,
			"Axis",
			e(Dropdown, {
				Items = AXIS_ITEMS,
				RowHeight = 20,
				SelectedItem = settings.axis,
				OnItemSelected = function(id: string?)
					for _, axis: Settings.Axis in Settings.axes() do
						if id == axis then
							Settings.update(function(s)
								s.axis = axis
							end)
						end
					end
				end,
			}),
			"**Move direction** for painted vertices.\n\n"
				.. "- **Face normal**: straight out of each tile.\n"
				.. "- **Up (Y), X, Z**: world directions.\n"
				.. "- **Picked**: face angle (`Alt + Right Click`).\n"
				.. "- **Curved (Round)**: follows `Round` curves."
		),
		-- Which tiles the brush affects, so it sits with the brush settings, not under Direction.
		SelectedOnly = Rows.checkbox(
			7,
			"Selected only",
			settings.paintSelectedOnly,
			function()
				Settings.update(function(s)
					s.paintSelectedOnly = not s.paintSelectedOnly
				end)
			end,
			"**Limit brush** to selected tiles.\n\n"
				.. "When off, paints any terrain under the cursor."
		),
		StopDivider = Rows.divider(12),
		Stop = Rows.button(
			13,
			"Stop painting",
			Settings.stopViewportTool,
			"**Stop painting** and return to Studio.\n\n"
				.. "Bakes edited tiles if `Bake automatically` is on.\n\n"
				.. "> Shortcut: `Esc`.",
			nil,
			Icons.StopTool
		),
	}

	-- Raise To sets a Height. With Hard falloff it jumps straight there (Hammer's absolute
	-- mode), so it has no Strength; with Soft falloff it eases there at Strength speed.
	local raiseTo = mode == "RaiseTo"
	if raiseTo then
		children.Height = Rows.property(
			4,
			"Height",
			e(StudioComponents.NumericInput, {
				Value = settings.height,
				Min = Settings.HEIGHT_MIN,
				Max = Settings.HEIGHT_MAX,
				Step = 0.5,
				Arrows = true,
				OnValidChanged = function(value: number)
					Settings.update(function(s)
						s.height = value
					end)
				end,
			}),
			"**Target offset** in studs along the axis.\n\n"
				.. "Measured from each tile's original flat face. Negative values carve inward.\n\n"
				.. "> `Ctrl + Click` terrain in 3D to pick its height. 0 resets hills to flat."
		)
	end
	if not raiseTo or settings.falloff == "Soft" then
		children.Strength = Rows.property(
			5,
			"Strength",
			slider(settings.strength, Settings.STRENGTH_MIN, Settings.STRENGTH_MAX, function(value: number)
				Settings.update(function(s)
					s.strength = value
				end)
			end),
			"**Brush speed.**\n\n"
				.. "- **Raise and Lower**: studs per second at the brush center.\n"
				.. "- **Smooth** and soft **Raise To**: how fast the surface settles."
		)
	end

	-- Falloff changes Raise, Lower and Raise To.
	if mode ~= "Smooth" then
		children.Falloff = Rows.property(
			6,
			"Falloff",
			e(Dropdown, {
				Items = FALLOFF_ITEMS,
				RowHeight = 20,
				SelectedItem = settings.falloff,
				OnItemSelected = function(id: string?)
					if id == "Soft" or id == "Hard" then
						Settings.update(function(s)
							s.falloff = id
						end)
					end
				end,
			}),
			"**Brush edge shape.**\n\n"
				.. "- **Soft**: tapers smoothly to nothing at the rim (natural hills).\n"
				.. "- **Hard**: moves everything inside equally (flat steps). With `Raise To`, jumps straight to the height."
		)
	end
	if settings.axis == "Picked" then
		local v = settings.pickedAxis
		children.Picked = Rows.value(
			10,
			"Picked",
			string.format("%.2f, %.2f, %.2f", v.X, v.Y, v.Z),
			nil,
			"**Stored world axis** for `Picked`.\n\n"
				.. "Set with `Alt + Right Click` on any face.\n\n"
				.. "> Click empty sky to reset to `Up (Y)`."
		)
	end

	-- Say so when a drag would do nothing, instead of failing silently.
	if #Session.models() == 0 then
		children.Warning = Rows.paragraph(2, "No terrain yet. Select parts or use Pick faces.", "warning")
	elseif settings.paintSelectedOnly and #Query.selectedModels() == 0 then
		children.Warning = Rows.paragraph(2, "No tiles selected. Select tiles or turn off Selected only.", "warning")
	end

	return Rows.page(children)
end

return BrushPage
