--!strict
--[[
	The panel: the tool strip on top, one page in the middle, the status bar at the bottom.

	The page follows what the user is doing, like Studio's Properties window, in this order:
	Settings or Help when open, the running tool's options, then the Studio selection (tiles to
	edit, parts to create), and otherwise an overview of the place.
]]

local Packages = script.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(script.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.State.Status)
local Query = require(script.Parent.Parent.Scene.Query)
local Format = require(script.Parent.Format)
local StatusBar = require(script.Parent.StatusBar)
local ToolStrip = require(script.Parent.ToolStrip)
local useRefresh = require(script.Parent.useRefresh)
local useSettings = require(script.Parent.useSettings)
local Pages = script.Parent.Pages
local BrushPage = require(Pages.BrushPage)
local CreatePage = require(Pages.CreatePage)
local HelpPage = require(Pages.HelpPage)
local MaterialPage = require(Pages.MaterialPage)
local MeshPage = require(Pages.MeshPage)
local OverviewPage = require(Pages.OverviewPage)
local SettingsPage = require(Pages.SettingsPage)
local StitchPage = require(Pages.StitchPage)
local TilesPage = require(Pages.TilesPage)

local e = React.createElement

local STATUS_HEIGHT = 24
local STRIP_HEIGHT = 30

type Page = "settings" | "help" | "brush" | "material" | "mesh" | "pick" | "stitch" | "tiles" | "parts" | "overview"

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
	elseif info.count > 0 then
		-- With parts selected too, the tile page uses them for Sew tiles.
		page = "tiles"
	elseif parts > 0 then
		page = "parts"
	end
	return { page = page, info = info, parts = parts, place = place }
end

-- The status bar's message when no operation result is showing.
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
		return "Painting materials. Ctrl erases."
	elseif page == "mesh" then
		if not hasTiles then
			return "No terrain yet."
		elseif settings.paintSelectedOnly and ctx.info.count == 0 then
			return "Select tiles to edit."
		end
		return if settings.meshMode == "Holes" then "Cutting holes. Ctrl restores." else "Removing points. Ctrl restores."
	elseif page == "pick" then
		return "Pick faces, then Create."
	elseif page == "stitch" then
		return if hasTiles then "Click a part to stitch." else "No terrain yet."
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

	-- A result from one tool is noise in the next, so starting a tool clears it. Selection-driven
	-- page changes keep it: Create selects the new tiles right after posting its result.
	React.useEffect(function()
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
			-- Keyed by page so each page starts scrolled to the top.
			[ctx.page] = body(settings, ctx),
		}),
		Status = e(StatusBar, {
			idle = idleText(settings, ctx),
			overlay = settings.overlay,
		}),
	})
end

return App
