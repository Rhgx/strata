--!strict
-- Actions on the selected tiles: shape, appearance, edges, baking and noise.
local Packages = script.Parent.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(script.Parent.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.Parent.State.Status)
local Session = require(script.Parent.Parent.Parent.Scene.Session)
local Query = require(script.Parent.Parent.Parent.Scene.Query)
local Edges = require(script.Parent.Parent.Parent.Actions.Edges)
local Shape = require(script.Parent.Parent.Parent.Actions.Shape)
local Bake = require(script.Parent.Parent.Parent.Actions.Bake)
local Appearance = require(script.Parent.Parent.Parent.Actions.Appearance)
local ColorField = require(script.Parent.Parent.ColorField)
local Format = require(script.Parent.Parent.Format)
local Icons = require(script.Parent.Parent.Icons)
local Rows = require(script.Parent.Parent.Rows)
local Dropdown = require(script.Parent.Parent.Dropdown)

local e = React.createElement

-- Hammer powers 2, 3 and 4.
local DETAIL_ITEMS = {
	{ Id = "2", Text = "Low (5x5)" },
	{ Id = "3", Text = "Medium (9x9)" },
	{ Id = "4", Text = "High (17x17)" },
}
local DETAIL_NAMES = { [2] = "Low", [3] = "Medium", [4] = "High" }

-- Runs an action that posts its own result; errors are reported in the status bar.
local function run(action: () -> ())
	xpcall(action, function(message)
		Status.post("error", tostring(message))
	end)
end

-- Material choices, by display name.
local MATERIAL_ITEMS = {}
for _, material in Appearance.materials() do
	table.insert(MATERIAL_ITEMS, { Id = material.Name, Text = Appearance.label(material) })
end

-- Dropdown id for "no variant" (an empty id would be an empty React key).
local DEFAULT_VARIANT = "__default__"

local function reportAppearance(count: number, what: string)
	if count == 0 then
		Status.post("warning", `The selected tiles already use {what}.`)
	else
		Status.post("success", `Changed {Format.plural(count, "tile")} to {what}.`)
	end
end

-- The Variant row: shown when the material has variants in MaterialService, or a selected tile
-- uses one (so it can be cleared). Disabled while the selected tiles use different materials.
local function variantRow(info: Query.SelectionInfo)
	local material = info.material
	local names: { string } = if material then Appearance.variants(material) else {}
	if #names == 0 and not info.anyVariant then
		return nil
	end
	local items = { { Id = DEFAULT_VARIANT, Text = "Default" } }
	for _, name in names do
		table.insert(items, { Id = name, Text = name })
	end
	local current = info.variant
	if current and current ~= "" and not table.find(names, current) then
		-- A variant this place does not have (for example from an inserted model).
		table.insert(items, { Id = current, Text = `{current} (missing)` })
	end
	local selected = if current == nil then nil elseif current == "" then DEFAULT_VARIANT else current
	return Rows.property(
		4,
		"Variant",
		e(Dropdown, {
			Items = items,
			MaxVisibleRows = 8,
			SelectedItem = selected,
			DefaultText = "Mixed",
			Disabled = material == nil,
			OnItemSelected = function(id: string?)
				if not id then
					return
				end
				local variant = if id == DEFAULT_VARIANT then "" else id
				run(function()
					reportAppearance(
						Appearance.apply({ variant = variant }, "Strata change variant"),
						if variant == "" then "the default look" else variant
					)
				end)
			end,
		}),
		if material
			then "**Custom material variant** from the Material Manager.\n\nLists variants made from this `Material`."
			else "**Custom material variant** from the Material Manager.\n\n> Select tiles with the same `Material` to choose one."
	)
end
-- A button for the action grid, with a 14 px icon and a tooltip. Labels name what they act on
-- ("Sew tiles"), since Sew and Stitch alone read as synonyms.
local function actionButton(
	layoutOrder: number,
	text: string,
	icon: Icons.Icon,
	disabled: boolean,
	onActivated: () -> (),
	tooltip: string
)
	return Rows.withTooltip(
		tooltip,
		e(StudioComponents.Button, {
			Size = UDim2.fromScale(1, 1),
			Text = text,
			Icon = icon,
			Disabled = disabled,
			OnActivated = onActivated,
		}),
		layoutOrder
	)
end

local function noiseInput(value: number, onChanged: (number) -> ())
	return e(StudioComponents.NumericInput, {
		Value = value,
		Min = Settings.NOISE_MIN,
		Max = Settings.NOISE_MAX,
		Step = 0.25,
		Arrows = true,
		OnValidChanged = onChanged,
	})
end

local function reportBake(result: Session.BakeResult)
	if result.failed > 0 then
		Status.post("error", `Baked {result.baked}, {result.failed} failed: {result.firstError}`)
	elseif result.baked == 0 then
		Status.post("warning", "Those tiles are already baked.")
	else
		Status.post("success", `Baked {Format.plural(result.baked, "tile")} into unions.`)
	end
end

local function reportStitch(report: Edges.StitchReport, reach: number)
	if report.edges > 0 then
		Status.post(
			"success",
			`Stitched {Format.plural(report.edges, "edge")} on {Format.plural(report.tiles, "tile")} to `
				.. `{Format.plural(report.parts, "part")}.`
		)
	elseif report.matched > 0 then
		Status.post("warning", "Those edges are already stitched to nearby parts.")
	else
		Status.post("warning", `No tile edges within {reach} st of nearby parts. Try Stitch or raise Reach.`)
	end
end

-- How many of the selected tiles are baked.
local function selectedText(info: Query.SelectionInfo): string
	local tiles = Format.plural(info.count, "tile")
	local bake = if info.baked == info.count
		then (if info.count == 1 then "baked" else "all baked")
		elseif info.baked == 0 then "unbaked"
		else `{info.baked} baked`
	local parts = if info.parts > 0 then `, {Format.plural(info.parts, "part")}` else ""
	return `{tiles} ({bake}){parts}`
end

-- Bake and Unbake as one control: whichever applies, or both (with counts) for a mixed selection.
local function bakeRow(layoutOrder: number, info: Query.SelectionInfo)
	local function bake()
		local ok, result = pcall(Bake.bakeSelected)
		if ok then
			reportBake(result)
		else
			Status.post("error", `Bake failed: {result}`)
		end
	end
	local function unbake()
		local ok, result = pcall(Bake.unbakeSelected)
		if ok then
			Status.post("success", `Unbaked {Format.plural(result, "tile")} to editable wedges.`)
		else
			Status.post("error", `Unbake failed: {result}`)
		end
	end
	local bakeTip = "**Merge each tile** into 1 union.\n\n" .. "Materials and textures run smoothly across baked tiles."
	local unbakeTip = "**Unbake tiles** into editable wedges.\n\n" .. "> Painting a baked tile unbakes it automatically."

	local unbaked = info.count - info.baked
	if info.baked == 0 then
		return Rows.button(layoutOrder, "Bake", bake, bakeTip, false, Icons.BakeTiles)
	elseif unbaked == 0 then
		return Rows.button(layoutOrder, "Unbake", unbake, unbakeTip, false, Icons.UnbakeTiles)
	end
	return Rows.grid(layoutOrder, 2, {
		Bake = actionButton(1, `Bake ({unbaked})`, Icons.BakeTiles, false, bake, bakeTip),
		Unbake = actionButton(2, `Unbake ({info.baked})`, Icons.UnbakeTiles, false, unbake, unbakeTip),
	})
end

local function TilesPage(props: { settings: Settings.State, info: Query.SelectionInfo })
	local settings = props.settings
	local info = props.info

	-- Properties first (like Studio's Properties window), then one block of actions.
	return Rows.page({
		Selected = Rows.value(
			1,
			"Selected",
			selectedText(info),
			nil,
			"**Selected tiles** and how many are baked.\n\n"
				.. "Selecting a `TerrainArea` or inner part selects its tiles.\n\n"
				.. "> Extra parts in the selection are used by `Sew tiles`."
		),
		Detail = Rows.property(
			2,
			"Detail",
			e(Dropdown, {
				Items = DETAIL_ITEMS,
				SelectedItem = if info.power then tostring(info.power) else nil,
				DefaultText = "Mixed",
				OnItemSelected = function(id: string?)
					local power = if id then tonumber(id) else nil
					if not power then
						return
					end
					run(function()
						local count = Shape.setDetail(power)
						Status.post("success", `Set {Format.plural(count, "tile")} to {DETAIL_NAMES[power]} detail.`)
					end)
				end,
			}),
			"**Grid density** of the selected tiles.\n\n"
				.. "- **Raising**: keeps the current shape.\n"
				.. "- **Lowering**: softens fine bumps.\n\n"
				.. "> One step at a time (`Ctrl + Z` undoes).\n"
				.. "> Hammer: Power."
		),
		Material = Rows.property(
			3,
			"Material",
			e(Dropdown, {
				Items = MATERIAL_ITEMS,
				MaxVisibleRows = 8,
				SelectedItem = if info.material then info.material.Name else nil,
				DefaultText = "Mixed",
				OnItemSelected = function(id: string?)
					local material = if id then Enum.Material:FromName(id) else nil
					if not material then
						return
					end
					run(function()
						reportAppearance(Appearance.apply({ material = material }, "Strata change material"), Appearance.label(material))
					end)
				end,
			}),
			"**Surface material** of the selected tiles.\n\n"
				.. "Applies right away, without unbaking.\n\n"
				.. "> Resets `Variant` to `Default`. Changes made with Studio's own material tools are kept too."
		),
		Variant = variantRow(info),
		Color = e(ColorField, {
			LayoutOrder = 5,
			color = info.color,
			tooltip = if settings.sampling
				then "**Click any part or tile** in 3D to copy its look.\n\n> `Esc` or the pipette again cancels."
				else "**Surface color** of the selected tiles.\n\n"
					.. "- Click the swatch for the color picker and the BrickColor palette (`Brick`).\n"
					.. "- Type `#RRGGBB` or `R, G, B`.\n"
					.. "- The **pipette** copies `Material`, `Variant` and `Color` from a part you click in 3D.\n\n"
					.. "> Colors copied from Studio's Properties window paste in.",
			onCommit = function(color: Color3)
				run(function()
					reportAppearance(Appearance.apply({ color = color }, "Strata change color"), "the new color")
				end)
			end,
			sampling = settings.sampling,
			onSample = function()
				Settings.update(function(s)
					s.sampling = not s.sampling
				end)
			end,
		}),

		ActionsHeading = Rows.section(6, "Actions"),
		Actions = Rows.grid(7, 2, {
			Round = actionButton(1, "Round folds", Icons.RoundFolds, info.count < 2, function()
				run(function()
					local count = Shape.round()
					if count == 0 then
						Status.post("warning", "Nothing moved. Select 2 or more tiles that meet at an angle.")
					else
						Status.post("success", `Rounded corners across {Format.plural(count, "tile")}.`)
					end
				end)
			end, "**Round** sharp folds where tiles meet.\n\n"
				.. "Needs 2 or more selected tiles. Painted detail stays on top.\n\n"
				.. "> Example: select a cliff's top and side.\n"
				.. "> Hammer: Subdivide."),
			Split = actionButton(2, "Split 2x2", Icons.SplitTiles, info.splittable == 0, function()
				run(function()
					local count, skipped = Shape.split()
					local note = if skipped > 0 then ` Skipped {Format.plural(skipped, "Low detail tile")}.` else ""
					if count == 0 then
						Status.post("warning", `Nothing split: Low detail tiles cannot be split.{note}`)
					else
						Status.post("success", `Split {Format.plural(count, "tile")} into {count * 4}.{note}`)
					end
				end)
			end, "**Split into 4 tiles**, keeping exact shape.\n\n"
				.. "Medium or High tiles only; drops `Detail` one level.\n\n"
				.. "> Example: split, then raise `Detail` on one quarter for a path."),
			Sew = actionButton(3, "Sew tiles", Icons.SewTiles, info.count < 2 and info.parts == 0, function()
				run(function()
					local count, warning = Edges.sewSelected()
					if warning then
						Status.post("warning", `Sewed {Format.plural(count, "tile")}. {warning}`)
					elseif count == 0 then
						Status.post("warning", "No shared edges found between the selected tiles.")
					else
						Status.post("success", `Sewed {Format.plural(count, "tile")} together.`)
					end
				end)
			end, "**Close seams** between selected tiles.\n\n"
				.. "Welds shared edges and corners.\n\n"
				.. "> Also stitches to any selected normal parts."),
			Stitch = actionButton(4, "Stitch", Icons.StitchTiles, false, function()
				run(function()
					reportStitch(Edges.stitchSelected(), settings.stitchReach)
				end)
			end, "**Snap tile edges** onto nearby parts.\n\n"
				.. `Matches block or wedge parts within {settings.stitchReach} st.\n\n`
				.. "> Change `Reach` in the `Stitch` tool or `Settings`."),
		}),
		BakeDivider = Rows.divider(8),
		Bake = bakeRow(9, info),

		Noise = Rows.collapsible(
			10,
			"noise",
			"Noise",
			"**Add random bumps** to selected tiles.\n\n"
				.. "> Click to show or hide.",
			{
				Min = Rows.property(
					1,
					"Min",
					noiseInput(settings.noiseMin, function(value: number)
						Settings.update(function(s)
							s.noiseMin = value
						end)
					end),
					"**Lowest bump** in studs.\n\n"
						.. "> Negative values push inward."
				),
				Max = Rows.property(
					2,
					"Max",
					noiseInput(settings.noiseMax, function(value: number)
						Settings.update(function(s)
							s.noiseMax = value
						end)
					end),
					"**Highest bump** in studs.\n\n"
						.. "> `Min` and `Max` must differ."
				),
				Apply = Rows.button(
					3,
					"Apply noise",
					function()
						run(function()
							local count = Shape.addNoise(settings.noiseMin, settings.noiseMax)
							Status.post(
								"success",
								`Added noise ({settings.noiseMin} to {settings.noiseMax} st) to {Format.plural(count, "tile")}.`
							)
						end)
					end,
					"**Apply random bumps** between `Min` and `Max`.\n\n"
						.. "Displaces every vertex on selected tiles.\n\n"
						.. "> Follows world position so shared edges stay joined.",
					settings.noiseMin == settings.noiseMax,
					Icons.Noise
				),
			}
		),
	})
end

return TilesPage
