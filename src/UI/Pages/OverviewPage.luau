--!strict
-- Shown when no tool runs and nothing usable is selected: how to start, and the place's tiles.
local Selection = game:GetService("Selection")

local Settings = require(script.Parent.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.Parent.State.Status)
local Query = require(script.Parent.Parent.Parent.Scene.Query)
local Bake = require(script.Parent.Parent.Parent.Actions.Bake)
local Format = require(script.Parent.Parent.Format)
local Icons = require(script.Parent.Parent.Icons)
local Rows = require(script.Parent.Parent.Rows)

local function bakeAllButton(layoutOrder: number, info: Query.PlaceInfo)
	local unbaked = info.total - info.baked
	return Rows.button(
		layoutOrder,
		`Bake all ({unbaked})`,
		function()
			local ok, result = pcall(Bake.bakeAll)
			if not ok then
				Status.post("error", `Bake failed: {result}`)
			elseif result.failed > 0 then
				Status.post("error", `Baked {result.baked}, {result.failed} failed: {result.firstError}`)
			else
				Status.post("success", `Baked {Format.plural(result.baked, "tile")} into unions.`)
			end
		end,
		"**Bake every unbaked tile** in this place.\n\n"
			.. "Merges each tile into a single union.\n\n"
			.. "> Run before publishing if `Bake automatically` is off.",
		nil,
		Icons.BakeAll
	)
end

local function OverviewPage()
	local info = Query.placeInfo()
	-- Something is selected, but nothing the plugin can use.
	local unsupported = #Selection:Get() > 0

	if info.total == 0 then
		return Rows.page({
			Notice = if unsupported
				then Rows.paragraph(1, "The selection has no block or wedge parts.", "dimmed")
				else nil,
			-- Spaced from the notice when there is one.
			Heading = Rows.section(2, "Get started", not unsupported),
			Hint = Rows.paragraph(3, "Select block or wedge parts to turn them into terrain, or pick faces in the 3D view.", "dimmed"),
			Divider = Rows.divider(4),
			Pick = Rows.button(
				5,
				"Pick faces",
				function()
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
			nil,
			"**Tiles merged into unions.**\n\n"
				.. "> Unbaked tiles are still editable wedges."
		),
		-- Only when there is something to bake; the Baked row already says "All baked".
		BakeDivider = if unbaked > 0 then Rows.divider(5) else nil,
		BakeAll = if unbaked > 0 then bakeAllButton(6, info) else nil,
	})
end

return OverviewPage
