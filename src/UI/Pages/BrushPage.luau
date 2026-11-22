--!strict
--[[
	Options page for the active sculpt brush (Raise, Lower, Smooth, or Raise To).
]]

local UI = script.Parent.Parent
local Plugin = UI.Parent
local Scene = Plugin.Scene
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(Plugin.State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local RadiusPreview = require(Plugin.Viewport.RadiusPreview)

local Rows = require(UI.Rows)
local Icons = require(UI.Icons)
local Dropdown = require(UI.Dropdown)

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

-- Raise To reference frame: each tile's flat base face, or the world origin.
local FROM_ITEMS = {
	{ Id = "Tile", Text = "Tile base" },
	{ Id = "World", Text = "World" },
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
		Title = Rows.title(
			1,
			Settings.modeLabel(mode),
			Settings.stopViewportTool,
			"**Stop painting** (`Esc`).\n\nBakes edited tiles if `Bake automatically` is on."
		),

		Radius = Rows.property(
			3,
			"Radius",
			slider(settings.radius, Settings.RADIUS_MIN, Settings.RADIUS_MAX, function (value: number)
				Settings.update(function (s)
					s.radius = value
				end)
				RadiusPreview.pulse()
			end),
			"**Brush size** in studs.\n\n"
				.. "The brush always reaches at least one grid step (set by `Detail`). Below that, a smaller radius pushes more gently.\n\n"
				.. "> Resize in 3D: `Ctrl + Scroll` or `Alt + Drag`."
		),

		DirectionHeading = Rows.section(9, "Direction"),

		Axis = Rows.property(
			10,
			"Axis",
			e(Dropdown, {
				Items = AXIS_ITEMS,
				RowHeight = 20,
				SelectedItem = settings.axis,

				OnItemSelected = function (id: string?)
					for _, axis: Settings.Axis in Settings.axes() do
						if id == axis then
							Settings.update(function (s)
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

		-- Controls brush targeting rather than axis direction, so it sits above the Direction section.
		SelectedOnly = Rows.checkbox(
			8,
			"Selected only",
			settings.paintSelectedOnly,
			function ()
				Settings.update(function (s)
					s.paintSelectedOnly = not s.paintSelectedOnly
				end)
			end,
			"**Limit brush** to selected tiles.\n\n"
				.. "When off, paints any terrain under the cursor."
		),
	}

	-- Raise To targets a Height. Hard falloff snaps directly (Hammer's absolute mode) and hides
	-- Strength; Soft falloff eases toward Height at Strength speed.
	local raiseTo = mode == "RaiseTo"

	if raiseTo then
		children.From = Rows.property(
			4,
			"From",
			e(Dropdown, {
				Items = FROM_ITEMS,
				RowHeight = 20,
				SelectedItem = if settings.raiseToWorld then "World" else "Tile",

				OnItemSelected = function (id: string?)
					if id == "World" or id == "Tile" then
						Settings.update(function (s)
							s.raiseToWorld = id == "World"

							-- World heights require a world axis; default to Up if currently per-tile.
							if id == "World" and (s.axis == "Face" or s.axis == "Subdiv") then
								s.axis = "Up"
							end
						end)
					end
				end,
			}),
			"**Where Height is measured from.**\n\n"
				.. "- **Tile base**: each tile's own flat face (0 flattens hills back).\n"
				.. "- **World**: the world origin, so one Height lines up across tiles at different levels, such as a road over stepped ground. Use with the `Up (Y)` axis for a world Y height."
		)

		children.Height = Rows.property(
			5,
			"Height",
			e(StudioComponents.NumericInput, {
				Value = settings.height,
				Min = Settings.HEIGHT_MIN,
				Max = Settings.HEIGHT_MAX,
				Step = 0.5,
				Arrows = true,

				OnValidChanged = function (value: number)
					Settings.update(function (s)
						s.height = value
					end)
				end,
			}),
			"**Target height** in studs along the axis.\n\n"
				.. "From each tile's flat face, or from the world origin with `From: World`. Negative values carve inward.\n\n"
				.. "> `Ctrl + Click` terrain in 3D to pick its height. From `Tile base`, 0 resets hills to flat."
		)
	end

	if not raiseTo or settings.falloff == "Soft" then
		children.Strength = Rows.property(
			6,
			"Strength",
			slider(settings.strength, Settings.STRENGTH_MIN, Settings.STRENGTH_MAX, function (value: number)
				Settings.update(function (s)
					s.strength = value
				end)
			end),
			"**Brush speed.**\n\n"
				.. "- **Raise and Lower**: studs per second at the brush center.\n"
				.. "- **Smooth** and soft **Raise To**: how fast the surface settles."
		)
	end

	-- Falloff applies to Raise, Lower, and Raise To (Smooth always uses Soft falloff).
	if mode ~= "Smooth" then
		children.Falloff = Rows.property(
			7,
			"Falloff",
			e(Dropdown, {
				Items = FALLOFF_ITEMS,
				RowHeight = 20,
				SelectedItem = settings.falloff,

				OnItemSelected = function (id: string?)
					if id == "Soft" or id == "Hard" then
						Settings.update(function (s)
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
			11,
			"Picked",
			string.format("%.2f, %.2f, %.2f", v.X, v.Y, v.Z),
			nil,
			"**Stored world axis** for `Picked`.\n\n"
				.. "Set with `Alt + Right Click` on any face.\n\n"
				.. "> Click empty sky to reset to `Up (Y)`."
		)
	end

	-- Warn explicitly when dragging would have no targets instead of doing nothing silently.
	if #Session.models() == 0 then
		children.Warning = Rows.paragraph(2, "No terrain yet. Select parts or use Pick faces.", "warning")
	elseif settings.paintSelectedOnly and #Query.selectedModels() == 0 then
		children.Warning = Rows.paragraph(2, "No tiles selected. Select tiles or turn off Selected only.", "warning")
	end

	return Rows.page(children)
end

return BrushPage
