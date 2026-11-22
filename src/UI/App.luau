--!strict
--[[
	Root panel layout: tool strip at the top, active page in the middle, status bar at the bottom.

	Page selection follows user context like Studio's Properties window, in priority order:
	Settings or Help overlay when open, the active viewport tool's page, Edit points, the current
	Studio selection (selected tiles to edit or parts to convert), and otherwise the place overview.
]]

local UI = script.Parent
local Pages = UI.Pages
local Plugin = UI.Parent
local State = Plugin.State
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Plugin.Scene.Query)

local StatusBar = require(UI.StatusBar)
local ToolStrip = require(UI.ToolStrip)
local useRefresh = require(UI.useRefresh)
local useSettings = require(UI.useSettings)

local HelpPage = require(Pages.HelpPage)
local MeshPage = require(Pages.MeshPage)
local BrushPage = require(Pages.BrushPage)
local TilesPage = require(Pages.TilesPage)
local CreatePage = require(Pages.CreatePage)
local StitchPage = require(Pages.StitchPage)
local MaterialPage = require(Pages.MaterialPage)
local PointsPage = require(Pages.PointsPage)
local OverviewPage = require(Pages.OverviewPage)
local SettingsPage = require(Pages.SettingsPage)

local e = React.createElement

local STATUS_HEIGHT = 24
local STRIP_HEIGHT = 30

type Page = "settings" | "help" | "brush" | "material" | "mesh" | "pick" | "stitch" | "points" | "tiles" | "parts" | "overview"

type Context = {
	page: Page,
	info: Query.SelectionInfo,
	parts: number,
	place: Query.PlaceInfo,
}

local function context(settings: Settings.State): Context
	local info = Query.selectionInfo()
	local parts = info.parts
	local place = Query.placeInfo()
	local page: Page = "overview"

	if settings.overlay == "settings" then
		page = "settings"
	elseif settings.overlay == "help" then
		page = "help"
	elseif settings.painting then
		page = "brush"
	elseif settings.coloring then
		page = "material"
	elseif settings.meshing then
		page = "mesh"
	elseif settings.picking then
		page = "pick"
	elseif settings.stitching then
		page = "stitch"
	elseif settings.editingPoints then
		-- Selecting point handles deselects the tiles, so this page cannot follow the selection.
		page = "points"
	elseif info.count > 0 then
		-- When both tiles and parts are selected, TilesPage uses the parts for Sew tiles.
		page = "tiles"
	elseif parts > 0 then
		page = "parts"
	end

	return { page = page, info = info, parts = parts, place = place }
end

-- Returns the fallback status bar text displayed when no operation result is active.
local function idleText(settings: Settings.State, ctx: Context): string
	local page = ctx.page
	local hasTiles = ctx.place.total > 0

	if page == "settings" then
		return "Saved between sessions."
	elseif page == "help" then
		return "Esc returns to the panel."
	elseif page == "brush" then
		if not hasTiles then
			return "No terrain yet."
		elseif settings.paintSelectedOnly and ctx.info.count == 0 then
			return "Select tiles to paint."
		end

		return `Painting: {Settings.modeLabel(settings.mode)}.`
	elseif page == "material" then
		if not hasTiles then
			return "No terrain yet."
		elseif settings.pickingLook then
			return "Click a part to pick up its look."
		elseif settings.paintSelectedOnly and ctx.info.count == 0 then
			return "Select tiles to paint."
		end

		return if settings.paintErase then "Erasing paint. Ctrl paints." else "Painting materials. Ctrl erases."
	elseif page == "mesh" then
		if not hasTiles then
			return "No terrain yet."
		elseif settings.paintSelectedOnly and ctx.info.count == 0 then
			return "Select tiles to edit."
		end

		return if settings.meshMode == "Holes" then "Cutting holes. Ctrl restores." else "Mark points, then Enter or Apply."
	elseif page == "pick" then
		return "Pick faces, then Create."
	elseif page == "stitch" then
		return if hasTiles then "Click a part to stitch." else "No terrain yet."
	elseif page == "points" then
		return "Move points with Studio's tools."
	elseif page == "tiles" then
		if settings.sampling then
			return "Click a part to copy its look (Esc cancels)."
		end

		return `{Format.plural(ctx.info.count, "tile")} selected.`
	elseif page == "parts" then
		return `{Format.plural(ctx.parts, "part")} ready to convert.`
	elseif not hasTiles then
		return "Select parts to create terrain."
	elseif ctx.place.baked == ctx.place.total then
		return `All {Format.plural(ctx.place.total, "tile")} baked.`
	end

	return `{ctx.place.baked} of {Format.plural(ctx.place.total, "tile")} baked.`
end

local function body(settings: Settings.State, ctx: Context)
	local page = ctx.page

	if page == "settings" then
		return e(SettingsPage, { settings = settings })
	elseif page == "help" then
		return e(HelpPage)
	elseif page == "brush" then
		return e(BrushPage, { settings = settings })
	elseif page == "material" then
		return e(MaterialPage, { settings = settings })
	elseif page == "mesh" then
		return e(MeshPage, { settings = settings })
	elseif page == "pick" then
		return e(CreatePage, { settings = settings, picking = true })
	elseif page == "stitch" then
		return e(StitchPage, { settings = settings })
	elseif page == "points" then
		return e(PointsPage)
	elseif page == "tiles" then
		return e(TilesPage, { settings = settings, info = ctx.info })
	elseif page == "parts" then
		return e(CreatePage, { settings = settings, picking = false })
	end

	return e(OverviewPage)
end

local function App()
	local settings = useSettings()
	useRefresh()

	local ctx = context(settings)
	local active = Settings.activeTool(settings)
	local overlayOpen = settings.overlay ~= "none"

	-- Clear prior status messages when starting a tool, while keeping them across selection-driven
	-- page transitions (for example, Create selects the newly built tiles right after reporting).
	React.useEffect(function ()
		if active then
			Status.clear()
		end
	end, { active })

	local stripHeight = if overlayOpen then 0 else STRIP_HEIGHT

	return e(StudioComponents.Background, {}, {
		Strip = if overlayOpen then nil else e(ToolStrip, { active = active }),

		Main = e("Frame", {
			Position = UDim2.fromOffset(0, stripHeight),
			Size = UDim2.new(1, 0, 1, -(STATUS_HEIGHT + stripHeight)),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
		}, {
			-- Key by page name so switching pages resets scroll position to the top.
			[ctx.page] = body(settings, ctx),
		}),

		Status = e(StatusBar, {
			idle = idleText(settings, ctx),
			overlay = settings.overlay,
		}),
	})
end

return App
