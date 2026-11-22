--!strict
-- Options of the running Material tool: the look it paints and how.
local Packages = script.Parent.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(script.Parent.Parent.Parent.State.Settings)
local RadiusPreview = require(script.Parent.Parent.Parent.Viewport.RadiusPreview)
local Session = require(script.Parent.Parent.Parent.Scene.Session)
local Query = require(script.Parent.Parent.Parent.Scene.Query)
local Appearance = require(script.Parent.Parent.Parent.Actions.Appearance)
local ColorField = require(script.Parent.Parent.ColorField)
local Dropdown = require(script.Parent.Parent.Dropdown)
local Accent = require(script.Parent.Parent.Accent)
local Rows = require(script.Parent.Parent.Rows)

local e = React.createElement

local MATERIAL_ITEMS: { Dropdown.Item } = {}
for _, material in Appearance.materials() do
	table.insert(MATERIAL_ITEMS, { Id = material.Name, Text = Appearance.label(material) })
end

-- Dropdown id for "no variant" (an empty id would be an empty React key).
local DEFAULT_VARIANT = "__default__"

-- The Variant row: shown when the paint material has variants, or one is set (so it can be
-- cleared).
local function variantRow(settings: Settings.State)
	local names = Appearance.variants(settings.paintMaterial)
	local current = settings.paintVariant
	if #names == 0 and current == "" then
		return nil
	end
	local items: { Dropdown.Item } = { { Id = DEFAULT_VARIANT, Text = "Default" } }
	for _, name in names do
		table.insert(items, { Id = name, Text = name })
	end
	if current ~= "" and not table.find(names, current) then
		table.insert(items, { Id = current, Text = `{current} (missing)` })
	end
	return Rows.property(
		6,
		"Variant",
		e(Dropdown, {
			Items = items,
			MaxVisibleRows = 8,
			SelectedItem = if current == "" then DEFAULT_VARIANT else current,
			OnItemSelected = function(id: string)
				Settings.update(function(s)
					s.paintVariant = if id == DEFAULT_VARIANT then "" else id
				end)
			end,
		}),
		"**Custom material variant** to paint, from the Material Manager.\n\n"
			.. "Lists variants made from the paint `Material`."
	)
end

local function MaterialPage(props: { settings: Settings.State })
	local settings = props.settings
	local theme = StudioComponents.useTheme()

	local children: { [string]: unknown } = {
		Title = Rows.title(
			1,
			"Material",
			Accent.tool("Material", theme),
			Settings.stopViewportTool,
			"**Stop the Material tool** (`Esc`).\n\nBakes edited tiles if `Bake automatically` is on."
		),
		Material = Rows.property(
			5,
			"Material",
			e(Dropdown, {
				Items = MATERIAL_ITEMS,
				MaxVisibleRows = 8,
				SelectedItem = settings.paintMaterial.Name,
				OnItemSelected = function(id: string)
					local material = Enum.Material:FromName(id)
					if material then
						Settings.update(function(s)
							s.paintMaterial = material
							-- A variant belongs to one base material.
							s.paintVariant = ""
						end)
					end
				end,
			}),
			"**Material to paint** into tiles.\n\n"
				.. "Each look a tile shows bakes into its own union, so painted areas keep "
				.. "their own texture.\n\n"
				.. "> `Ctrl` erases back to the tile's own look."
		),
		Variant = variantRow(settings),
		Color = e(ColorField, {
			LayoutOrder = 7,
			color = settings.paintColor,
			tooltip = if settings.pickingLook
				then "**Click any part or tile** in 3D to pick up its look.\n\n> The pipette again cancels."
				else "**Color to paint.**\n\n"
					.. "- Click the swatch for the color picker and the BrickColor palette (`Brick`).\n"
					.. "- The **pipette** picks up the look of a part or tile you click in 3D.\n\n"
					.. "> Also `Alt + Right Click` in 3D.",
			onCommit = function(color: Color3)
				Settings.update(function(s)
					s.paintColor = color
				end)
			end,
			sampling = settings.pickingLook,
			onSample = function()
				Settings.update(function(s)
					s.pickingLook = not s.pickingLook
				end)
			end,
		}),
		Radius = Rows.property(
			8,
			"Radius",
			e(StudioComponents.NumericInput, {
				Value = settings.radius,
				Min = Settings.RADIUS_MIN,
				Max = Settings.RADIUS_MAX,
				Step = 0.5,
				Slider = true,
				OnValidChanged = function(value: number)
					Settings.update(function(s)
						s.radius = value
					end)
					RadiusPreview.pulse()
				end,
			}),
			"**Brush size** in studs.\n\n"
				.. "The cell under the cursor is always included, however small the brush.\n\n"
				.. "> Resize in 3D: `Ctrl + Scroll` or `[` and `]`."
		),
		Fine = Rows.checkbox(
			9,
			"Fine (triangles)",
			settings.paintFine,
			function()
				Settings.update(function(s)
					s.paintFine = not s.paintFine
				end)
			end,
			"**Paint single triangles** instead of whole grid cells.\n\n"
				.. "Off: clean, blocky edges (roads, plazas). On: finer diagonals.\n\n"
				.. "> Edges follow the tile grid; raise `Detail` for smoother borders."
		),
		SelectedOnly = Rows.checkbox(
			10,
			"Selected only",
			settings.paintSelectedOnly,
			function()
				Settings.update(function(s)
					s.paintSelectedOnly = not s.paintSelectedOnly
				end)
			end,
			"**Limit the brush** to selected tiles.\n\n"
				.. "When off, works on any terrain under the cursor."
		),
	}

	if settings.pickingLook then
		children.Hint = Rows.paragraph(4, "Click any part or tile in 3D to pick up its look.", "dimmed")
	end
	-- Say so when a drag would do nothing, instead of failing silently.
	if #Session.models() == 0 then
		children.Warning = Rows.paragraph(3, "No terrain yet. Select parts or use Pick faces.", "warning")
	elseif settings.paintSelectedOnly and #Query.selectedModels() == 0 then
		children.Warning = Rows.paragraph(3, "No tiles selected. Select tiles or turn off Selected only.", "warning")
	end

	return Rows.page(children)
end

return MaterialPage
