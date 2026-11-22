--!strict
--[[
	Default overview page shown when no tool is running and no convertible parts or tiles are
	selected: displays onboarding guidance when the place has no terrain, or tile counts and
	place-wide actions otherwise.
]]

local Selection = game:GetService("Selection")

local UI = script.Parent.Parent
local Plugin = UI.Parent
local State = Plugin.State
local Scene = Plugin.Scene
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Format = require(State.Format)
local Settings = require(State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Bake = require(Plugin.Actions.Bake)

local Rows = require(UI.Rows)
local Icons = require(UI.Icons)

local e = React.createElement

local function bakeAllButton(layoutOrder: number, info: Query.PlaceInfo)
	local unbaked = info.total - info.baked

	return Rows.button(
		layoutOrder,
		`Bake all ({unbaked})`,
		function ()
			local ok, result = pcall(Bake.bakeAll)
			Bake.report(ok, result, "Baked")
		end,
		"**Bake every unbaked tile** in this place.\n\n"
			.. "Merges each tile into a single union.\n\n"
			.. "> Run before publishing if `Bake automatically` is off.",
		nil,
		Icons.BakeTiles,
		true
	)
end

local function OverviewPage()
	local info = Query.placeInfo()
	-- Selection is non-empty but contains no usable tiles or convertible parts.
	local unsupported = #Selection:Get() > 0

	if info.total == 0 then
		return Rows.page({
			Notice = if unsupported
				then Rows.paragraph(1, "The selection has no block or wedge parts.", "dimmed")
				else nil,

			-- Add top spacing only when the notice paragraph precedes the heading.
			Heading = Rows.section(2, "Get started", not unsupported),
			Hint = Rows.paragraph(3, "Select block or wedge parts to turn them into terrain, or pick faces in the 3D view.", "dimmed"),
			Divider = Rows.divider(4),

			Pick = Rows.button(
				5,
				"Pick faces",
				function ()
					Settings.toggleTool("PickFaces")
				end,
				"**Pick part faces** in the 3D view.\n\n"
					.. "Click faces to collect them, then click `Create`.",
				nil,
				Icons.StartPickFaces
			),
		})
	end

	local unbaked = info.total - info.baked

	return Rows.page({
		Hint = Rows.paragraph(
			1,
			if unsupported
				then "Select terrain tiles to edit, or block and wedge parts to create."
				else "Select tiles to edit, select parts to create, or pick a tool above.",
			"dimmed"
		),

		Heading = Rows.section(2, "Place"),
		Tiles = Rows.value(3, "Tiles", Format.plural(info.total, "tile"), nil, "**Total terrain tiles** in this place."),

		Baked = Rows.value(
			4,
			"Baked",
			if unbaked == 0 then "All baked" else `{info.baked} of {info.total}`,
			-- Highlight unbaked tiles as a reminder before publishing.
			if unbaked == 0 then nil else "warning",
			"**Tiles merged into unions.**\n\n"
				.. "> Unbaked tiles are still editable wedges."
		),

		ActionsHeading = Rows.section(5, "Actions"),

		Actions = Rows.grid(6, 2, {
			SelectAll = Rows.withTooltip(
				"**Select every tile** in this place, to edit them together on the tile page.",
				e(StudioComponents.Button, {
					Size = UDim2.fromScale(1, 1),
					Text = "Select all",
					Icon = Icons.Select,

					OnActivated = function ()
						local models: { Instance } = {}

						for _, model in Session.models() do
							table.insert(models, model)
						end

						Selection:Set(models)
					end,
				}),
				1
			),

			Pick = Rows.withTooltip(
				"**Pick part faces** in the 3D view to turn into more terrain.",
				e(StudioComponents.Button, {
					Size = UDim2.fromScale(1, 1),
					Text = "Pick faces",
					Icon = Icons.StartPickFaces,

					OnActivated = function ()
						Settings.toggleTool("PickFaces")
					end,
				}),
				2
			),
		}),

		-- Show Bake all only when unbaked tiles exist.
		BakeAll = if unbaked > 0 then bakeAllButton(7, info) else nil,
	})
end

return OverviewPage
