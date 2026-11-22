--!strict
--[[
	Selected tiles inspector and action page: detail level, base appearance, cleanup, shape and
	edge actions, baking, and displacement noise.
]]

local UI = script.Parent.Parent
local Plugin = UI.Parent
local State = Plugin.State
local Actions = Plugin.Actions
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Plugin.Scene.Query)

local Bake = require(Actions.Bake)
local Edges = require(Actions.Edges)
local Shape = require(Actions.Shape)
local Appearance = require(Actions.Appearance)
local MeshActions = require(Actions.Mesh)

local Rows = require(UI.Rows)
local Icons = require(UI.Icons)
local Dropdown = require(UI.Dropdown)
local ColorField = require(UI.ColorField)

local e = React.createElement

-- Hammer displacement powers 2, 3, and 4.
local DETAIL_ITEMS = {
	{ Id = "2", Text = "Low (5x5)" },
	{ Id = "3", Text = "Medium (9x9)" },
	{ Id = "4", Text = "High (17x17)" },
}
local DETAIL_NAMES = { [2] = "Low", [3] = "Medium", [4] = "High" }
-- Sentinel dropdown ID for "no variant" so React never receives an empty key.
local DEFAULT_VARIANT = "__default__"

local MATERIAL_ITEMS = {}

for _, material in Appearance.materials() do
	table.insert(MATERIAL_ITEMS, { Id = material.Name, Text = Appearance.label(material) })
end

-- Executes an action and surfaces any raised error in the status bar.
local function run(action: () -> ())
	xpcall(action, function (message)
		Status.post("error", tostring(message))
	end)
end

local function reportAppearance(count: number, hidden: number, what: string)
	if count == 0 then
		Status.post("warning", `The selected tiles already use {what}.`)
	elseif hidden == count then
		-- Saved, but paint covers every triangle, so nothing visible changed.
		Status.post("warning", `Changed {Format.plural(count, "tile")} to {what}, but paint covers all of it. Clear paint to show it.`)
	else
		Status.post("success", `Changed {Format.plural(count, "tile")} to {what}.`)
	end
end

-- Renders the Variant dropdown when the selected material has MaterialService variants or any
-- selected tile uses a variant. Disabled while the selection mixes base materials.
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
		-- Variant referenced by an imported model that is absent from this place.
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

			OnItemSelected = function (id: string?)
				if not id then
					return
				end

				local variant = if id == DEFAULT_VARIANT then "" else id

				run(function ()
					local count, hidden = Appearance.apply({ variant = variant }, "Strata change variant")

					reportAppearance(count, hidden, if variant == "" then "the default look" else variant)
				end)
			end,
		}),
		if material
			then "**Custom material variant** from the Material Manager.\n\nLists variants made from this `Material`."
			else "**Custom material variant** from the Material Manager.\n\n> Select tiles with the same `Material` to choose one."
	)
end

-- Action grid button with a 14 px icon and tooltip. Labels name their target (e.g. "Sew tiles")
-- so Sew and Stitch stay clearly distinct.
local function actionButton(
	layoutOrder: number,
	text: string,
	icon: Icons.Icon,
	disabled: boolean,
	onActivated: () -> (),
	tooltip: string,
	primary: boolean?
)
	return Rows.withTooltip(
		tooltip,
		e(if primary and not disabled then StudioComponents.MainButton else StudioComponents.Button, {
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

local function selectedText(info: Query.SelectionInfo): string
	local tiles = Format.plural(info.count, "tile")
	local bake = if info.baked == info.count
		then (if info.count == 1 then "baked" else "all baked")
		elseif info.baked == 0 then "unbaked"
		else `{info.baked} baked`
	local parts = if info.parts > 0 then `, {Format.plural(info.parts, "part")}` else ""

	return `{tiles} ({bake}){parts}`
end

-- Shows Bake, Unbake, or both (with counts) depending on the selection's baked state.
local function bakeRow(layoutOrder: number, info: Query.SelectionInfo)
	local function bake()
		local ok, result = pcall(Bake.bakeSelected)
		Bake.report(ok, result, "Baked", "Those tiles are already baked.")
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
	-- Tiles with every triangle deleted have nothing to bake, so they are not counted.
	local unbaked = info.count - info.baked - info.empty

	if unbaked == 0 and info.baked == 0 then
		return Rows.button(
			layoutOrder,
			"Nothing to bake",
			bake,
			"**Every triangle of these tiles is deleted**, so there is nothing to bake.\n\n> Restore holes to bring triangles back.",
			true,
			Icons.BakeTiles
		)
	end

	-- Bake is the primary call to action for an unbaked or partially baked selection.
	if info.baked == 0 then
		return Rows.button(layoutOrder, "Bake", bake, bakeTip, false, Icons.BakeTiles, true)
	elseif unbaked == 0 then
		return Rows.button(layoutOrder, "Unbake", unbake, unbakeTip, false, Icons.UnbakeTiles)
	end

	return Rows.grid(layoutOrder, 2, {
		Bake = actionButton(1, `Bake ({unbaked})`, Icons.BakeTiles, false, bake, bakeTip, true),
		Unbake = actionButton(2, `Unbake ({info.baked})`, Icons.UnbakeTiles, false, unbake, unbakeTip),
	})
end

-- Renders applicable cleanup buttons (Clear paint, Restore holes, Restore points): a single
-- action spans full width with a descriptive label; multiple actions share a 2-column grid.
local function cleanupRow(layoutOrder: number, info: Query.SelectionInfo)
	local function clearPaint()
		run(function ()
			local count = Appearance.clearPaint()
			Status.post("success", `Cleared painted materials from {Format.plural(count, "tile")}.`)
		end)
	end

	local function restoreHoles()
		run(function ()
			local count = Appearance.restoreHoles()
			Status.post("success", `Restored deleted triangles on {Format.plural(count, "tile")}.`)
		end)
	end

	local function restorePoints()
		run(function ()
			local count = MeshActions.restorePoints()
			Status.post("success", `Restored removed points on {Format.plural(count, "tile")}.`)
		end)
	end

	local clearTip = "**Remove painted materials** from the selected tiles.\n\n"
		.. "Painted areas go back to each tile's own look. Holes stay.\n\n"
		.. "> Paint with the `Material` tool in the strip."
	local restoreTip = "**Bring back deleted triangles** on the selected tiles.\n\n"
		.. "They come back in each tile's own look.\n\n"
		.. "> Cut holes with the `Mesh` tool's `Cut holes` mode."
	local pointsTip = "**Bring back removed points** on the selected tiles.\n\n"
		.. "The full grid of triangles returns, on the surface as it is now.\n\n"
		.. "> Remove points with the `Mesh` tool's `Simplify` mode."

	type Action = { short: string, long: string, icon: Icons.Icon, run: () -> (), tip: string }
	local actions: { Action } = {}

	if info.painted > 0 then
		table.insert(actions, { short = "Clear paint", long = "Clear painted materials", icon = Icons.ClearPaint, run = clearPaint, tip = clearTip })
	end

	if info.holes > 0 then
		table.insert(actions, { short = "Restore holes", long = "Restore deleted triangles", icon = Icons.RestoreHoles, run = restoreHoles, tip = restoreTip })
	end

	if info.simplified > 0 then
		table.insert(actions, { short = "Restore points", long = "Restore removed points", icon = Icons.RestorePoints, run = restorePoints, tip = pointsTip })
	end

	if #actions == 0 then
		return nil
	elseif #actions == 1 then
		local only = actions[1]

		return Rows.button(layoutOrder, only.long, only.run, only.tip, nil, only.icon)
	end

	local cells: { [string]: unknown } = {}

	for i, action in actions do
		cells[action.short] = actionButton(i, action.short, action.icon, false, action.run, action.tip)
	end

	return Rows.grid(layoutOrder, 2, cells)
end

local function TilesPage(props: { settings: Settings.State, info: Query.SelectionInfo })
	local settings = props.settings
	local info = props.info

	-- Properties first (matching Studio's Properties window), followed by actions.
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

				OnItemSelected = function (id: string?)
					local power = if id then tonumber(id) else nil

					if not power then
						return
					end

					run(function ()
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

				OnItemSelected = function (id: string?)
					local material = if id then Enum.Material:FromName(id) else nil

					if not material then
						return
					end

					run(function ()
						local count, hidden = Appearance.apply({ material = material }, "Strata change material")

						reportAppearance(count, hidden, Appearance.label(material))
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

			onCommit = function (color: Color3)
				run(function ()
					local count, hidden = Appearance.apply({ color = color }, "Strata change color")

					reportAppearance(count, hidden, "the new color")
				end)
			end,

			sampling = settings.sampling,

			onSample = function ()
				Settings.update(function (s)
					s.sampling = not s.sampling
				end)
			end,
		}),

		-- Rendered only when selected tiles have paint, holes, or removed points.
		Cleanup = cleanupRow(6, info),

		ActionsHeading = Rows.section(7, "Actions"),

		Actions = Rows.grid(8, 2, {
			Round = actionButton(1, "Round folds", Icons.RoundFolds, info.count < 2, function ()
				run(function ()
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

			Split = actionButton(2, "Split 2x2", Icons.SplitTiles, info.splittable == 0, function ()
				run(function ()
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

			Sew = actionButton(3, "Sew tiles", Icons.SewTiles, info.count < 2 and info.parts == 0, function ()
				run(function ()
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

			Stitch = actionButton(4, "Stitch", Icons.StitchTiles, false, function ()
				run(function ()
					reportStitch(Edges.stitchSelected(), settings.stitchReach)
				end)
			end, "**Snap tile edges** onto nearby parts.\n\n"
				.. `Matches block or wedge parts within {settings.stitchReach} st.\n\n`
				.. "> Change `Reach` in the `Stitch` tool or `Settings`."),
		}),

		BakeDivider = Rows.divider(9),
		Bake = bakeRow(10, info),

		Noise = Rows.collapsible(
			11,
			"noise",
			"Noise",
			"**Add random bumps** to selected tiles.\n\n"
				.. "> Click to show or hide.",
			{
				Min = Rows.property(
					1,
					"Min",
					noiseInput(settings.noiseMin, function (value: number)
						Settings.update(function (s)
							s.noiseMin = value
						end)
					end),
					"**Lowest bump** in studs.\n\n"
						.. "> Negative values push inward."
				),

				Max = Rows.property(
					2,
					"Max",
					noiseInput(settings.noiseMax, function (value: number)
						Settings.update(function (s)
							s.noiseMax = value
						end)
					end),
					"**Highest bump** in studs.\n\n"
						.. "> `Min` and `Max` must differ."
				),

				Apply = Rows.button(
					3,
					"Apply noise",
					function ()
						run(function ()
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
