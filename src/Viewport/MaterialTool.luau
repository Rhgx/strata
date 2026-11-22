--!strict
--[[
	The Material tool: paints a look (material, color and material variant) into tiles, for a road
	through grass or a rock patch on a slope. One stroke (mouse down to mouse up) is one undo step;
	when the tool stops, everything painted is baked as its own undo step.

	Viewport controls:
		Left drag          paint the look
		Ctrl               erase (back to each tile's own look); paints instead in Erase mode
		Alt + right click  pick up the look of any part or tile under the cursor
		Ctrl + scroll      resize the brush ([ and ] too, on layouts that have them)
		Esc                stop

	What gets painted is decided by TriangleBrush. Nothing moves, so unlike the sculpt brushes
	there is no strength, falloff or sewing. Painting and erasing never fill a hole (the Mesh
	tool's Cut holes mode owns those).
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local Displacement = require(script.Parent.Parent.Core.Displacement)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Settings = require(script.Parent.Parent.State.Settings)
local Format = require(script.Parent.Parent.State.Format)
local Status = require(script.Parent.Parent.State.Status)
local Session = require(script.Parent.Parent.Scene.Session)
local Query = require(script.Parent.Parent.Scene.Query)
local Bake = require(script.Parent.Parent.Actions.Bake)
local VisibleHit = require(script.Parent.VisibleHit)
local Input = require(script.Parent.Input)
local Cursor = require(script.Parent.Cursor)
local KeyStrip = require(script.Parent.KeyStrip)
local Lines = require(script.Parent.Lines)
local RadiusPreview = require(script.Parent.RadiusPreview)
local TileHit = require(script.Parent.TileHit)
local TriangleBrush = require(script.Parent.TriangleBrush)
local TriangleOutline = require(script.Parent.TriangleOutline)

type Opened = TerrainInstance.Opened

-- Each look bakes into its own union, so past this many looks on one tile the user is told.
local LOOK_WARNING = 4
local ERASE_COLOR = Color3.fromRGB(230, 96, 80)
-- The cursor outline: a fixed, high-contrast blue (the paint color itself can vanish, like dark
-- asphalt in shadow).
local PAINT_COLOR = Color3.fromRGB(70, 175, 255)
local MAX_OUTLINE_LINES = 300
-- The outline is rebuilt when the cursor moves at least this far (or anything else changes).
local OUTLINE_MOVE = 0.25
local SEPARATOR = KeyStrip.SEPARATOR

local function describe(look: Displacement.Look): string
	local name = (look.material.Name:gsub("(%l)(%u)", "%1 %2"))
	if look.variant ~= "" then
		name = `{name} ({look.variant})`
	end
	return `{name}, #{look.color:ToHex():upper()}`
end

-- Whether a stroke now erases: Erase mode, or Paint mode with Ctrl held (Ctrl swaps them).
local function erasing(settings: Settings.State): boolean
	return settings.paintErase ~= Input.ctrl()
end

-- Starts the tool and returns a function that stops it.
return function(plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local connections: { RBXScriptConnection } = {}

	-- Per stroke.
	local recording: string? = nil
	local touched: { [Opened]: true } = {}
	-- Shown triangle centers (world) per tile: nothing moves while painting, so they are kept
	-- across frames until the tile moves or the tool stops.
	local centers: { [Opened]: { pivot: CFrame, list: { Vector3 } } } = {}
	local warned: { [Opened]: true } = {}
	local lastCenter: Vector3? = nil
	local wasColoring = false
	-- Whether this stroke painted the paint look (not only erased), so it joins the recent looks.
	local paintedLook = false

	-- The cursor is the outline of the triangles a click would paint. The ring only shows the
	-- size during a radius preview with no terrain in the middle of the view.
	local ring = RadiusPreview.newRing("StrataMaterialPreview", true, 0.5)
	local keyStrip = KeyStrip.new("StrataMaterialHints")
	local outline = Lines.new("StrataMaterialOutline", MAX_OUTLINE_LINES)
	local outlined: { opened: Opened, triangle: number?, position: Vector3, radius: number, fine: boolean, erase: boolean }? = nil

	local function hideCursor()
		ring.Visible = false
		outline.clear()
		outlined = nil
		RadiusPreview.label(nil)
	end

	local function centersOf(opened: Opened): { Vector3 }
		local pivot = opened.model:GetPivot()
		local cached = centers[opened]
		if cached and cached.pivot == pivot then
			return cached.list
		end
		local computed = TileHit.centers(opened)
		centers[opened] = { pivot = pivot, list = computed }
		return computed
	end

	-- Outlines what a click at hit would paint (skipped while nothing that matters changed).
	local function drawOutline(models: { Model }, hit: TileHit.Hit, settings: Settings.State, erase: boolean)
		local last = outlined
		if
			last
			and last.opened == hit.opened
			and last.triangle == hit.triangle
			and last.radius == settings.radius
			and last.fine == settings.paintFine
			and last.erase == erase
			and (last.position - hit.position).Magnitude < OUTLINE_MOVE
		then
			return
		end
		outlined = { opened = hit.opened, triangle = hit.triangle, position = hit.position, radius = settings.radius, fine = settings.paintFine, erase = erase }
		local covered: { TriangleOutline.Covered } = {}
		for _, opened in TriangleBrush.tilesInReach(models, hit, settings.radius, 0) do
			local grids = TriangleBrush.gridTriangles(opened, hit, { hit.position }, settings.radius, settings.paintFine, centersOf(opened))
			table.insert(covered, { opened = opened, grids = grids })
		end
		TriangleOutline.draw(outline, covered, if erase then ERASE_COLOR else PAINT_COLOR)
	end

	local function paintAt(models: { Model }, hit: TileHit.Hit)
		local settings = Settings.get()
		local radius = settings.radius
		local erase = erasing(settings)
		local look: Displacement.Look = { material = settings.paintMaterial, color = settings.paintColor, variant = settings.paintVariant }
		local samples, travel = TriangleBrush.samples(lastCenter, hit.position, radius)
		lastCenter = hit.position

		for _, opened in TriangleBrush.tilesInReach(models, hit, radius, travel) do
			local disp = opened.disp
			local target = 0
			if not erase then
				local index = Displacement.lookIndex(disp, look)
				if not index then
					if not warned[opened] then
						warned[opened] = true
						Status.post("warning", `{opened.model.Name} already has {Displacement.MAX_LOOKS} painted looks.`)
					end
					continue
				end
				target = index
			end
			local grids = TriangleBrush.gridTriangles(opened, hit, samples, radius, settings.paintFine, centersOf(opened))
			local changed = TriangleBrush.write(opened, grids, target, function(g: number): boolean
				return disp.triLooks[g] ~= Displacement.HOLE
			end)
			if #changed > 0 then
				touched[opened] = true
				if not erase then
					paintedLook = true
				end
				local count = Displacement.lookCount(disp)
				if count > LOOK_WARNING and not warned[opened] then
					warned[opened] = true
					Status.post("warning", `{opened.model.Name} now shows {count} looks; each one adds bake time.`)
				end
			end
		end
	end

	-- The visible part under the mouse (tiles included), looking through invisible ones.
	local function partUnderMouse(): BasePart?
		local hit = VisibleHit.cast(mouse.UnitRay, { workspace.Terrain })
		return if hit then hit.Instance else nil

	end

	-- Takes the paint look from the part or tile under the cursor (a tile's wedges and unions
	-- show exactly the look of the spot clicked).
	local function pickLook()
		local part = partUnderMouse()
		Settings.update(function(s)
			s.pickingLook = false
			if part then
				s.paintMaterial = part.Material
				s.paintColor = part.Color
				s.paintVariant = part.MaterialVariant
				-- Picking a look means painting with it next.
				s.paintErase = false
			end
		end)
		if part then
			Settings.rememberPaintLook()
			Status.post(
				"success",
				`Picked {describe({ material = part.Material, color = part.Color, variant = part.MaterialVariant })} from {part.Name}.`
			)
		else
			Status.post("warning", "No part under the cursor to pick a look from.")
		end
	end

	local endStroke: () -> ()
	-- Set while Alt + dragging to resize; the outline stays where the drag started.
	local resize: Input.DragResize? = nil

	local function beginStroke()
		local settings = Settings.get()
		-- A new press ends anything a missed button release left behind.
		resize = nil
		if recording then
			endStroke()
		end
		if not settings.coloring then
			return
		end
		if Session.isBaking() then
			-- Say so instead of ignoring the click.
			Status.post("warning", "Still baking the last edits. Try again in a moment.")
			return
		end
		if settings.pickingLook then
			pickLook()
			return
		end
		-- Alt + drag resizes instead of painting (it would otherwise orbit the camera).
		local drag = Input.beginDragResize(mouse, settings.radius)
		if drag then
			resize = drag
			return
		end
		recording = ChangeHistoryService:TryBeginRecording("Strata paint material")
		if not recording then
			Status.post("warning", "Studio is busy recording another change. Stroke skipped.")
			return
		end
		lastCenter = nil
		local models = Query.workingModels()
		local hit = TileHit.find(mouse, models)
		if hit then
			paintAt(models, hit)
		end
	end

	function endStroke()
		resize = nil
		local current = recording
		if not current then
			return
		end
		recording = nil
		local edited = 0
		for opened in touched do
			TerrainInstance.save(opened)
			edited += 1
		end
		table.clear(touched)
		table.clear(warned)
		lastCenter = nil
		ChangeHistoryService:FinishRecording(
			current,
			if edited > 0 then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
		if paintedLook then
			Settings.rememberPaintLook()
		end
		paintedLook = false
	end

	local function onSettingsChanged(state: Settings.State)
		if state.coloring == wasColoring then
			return
		end
		wasColoring = state.coloring
		if not state.coloring then
			endStroke()
			hideCursor()
			table.clear(centers)
			keyStrip.show(nil)
			-- Not when switching to another editing tool (see Settings.editing).
			if state.autoBake and not Settings.editing(state) then
				task.spawn(Bake.bakeEdited)
			end
		end
	end

	table.insert(connections, mouse.Button1Down:Connect(beginStroke))
	table.insert(connections, mouse.Button1Up:Connect(function()
		endStroke()
	end))
	table.insert(
		connections,
		mouse.Button2Down:Connect(function()
			if Settings.get().coloring and not recording and Input.alt() then
				pickLook()
			end
		end)
	)
	for _, connection in Input.connectResize(mouse, function()
		return Settings.get().coloring
	end, Settings.stepRadius) do
		table.insert(connections, connection)
	end
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function()
			local settings = Settings.get()
			if not settings.coloring then
				return
			end
			local erase = erasing(settings)
			local hints: { string }
			if settings.pickingLook then
				hints = { "<b>Pick a look</b>", "Click any part or tile", "Esc: Stop" }
			else
				hints = {
					`<b>Material</b> ({describe({ material = settings.paintMaterial, color = settings.paintColor, variant = settings.paintVariant })})`,
					if erase then "Left Drag: Erase" else "Left Drag: Paint",
					if settings.paintErase then "Ctrl: Paint" else "Ctrl: Erase",
					"Alt + Right Click: Pick look",
					`Ctrl + Scroll: Size ({Format.studs(settings.radius)})`,
					"Esc: Stop",
				}
			end
			keyStrip.show(if settings.showKeyHints then table.concat(hints, SEPARATOR) else nil)

			if settings.pickingLook then
				hideCursor()
				Cursor.set(if partUnderMouse() then "valid" else "invalid")
				return
			end
			local resizing = resize
			if resizing then
				local radius = Input.dragRadius(mouse, resizing)
				if radius ~= settings.radius then
					Settings.update(function(s)
						s.radius = radius
					end)
				end
			end
			local models = Query.workingModels()
			Cursor.set(if resizing then "resize" elseif #models == 0 then "empty" else nil)
			local previewing = RadiusPreview.active()
			local ray = if resizing then resizing.ray elseif previewing then RadiusPreview.ray() else mouse.UnitRay
			local hit = if ray then TileHit.findAlong(ray, models) else nil
			if not hit then
				hideCursor()
				local position, facing = nil, nil
				if previewing then
					position, facing = RadiusPreview.fallback(settings.radius)
				end
				if position and facing then
					-- No terrain in the middle of the view: show the size as a plain ring.
					ring.CFrame = CFrame.lookAt(position, position + facing)
					ring.Radius = settings.radius
					ring.InnerRadius = settings.radius - math.max(0.15, settings.radius * 0.04)
					ring.Color3 = PAINT_COLOR
					ring.Visible = true
					RadiusPreview.label(position, `Radius {Format.studs(settings.radius)} st`)
				end
				return
			end
			ring.Visible = false
			drawOutline(models, hit, settings, erase)
			RadiusPreview.label(if previewing or resizing then hit.position else nil, `Radius {Format.studs(settings.radius)} st`)

			if recording then
				paintAt(models, hit)
			end
		end)
	)

	local unsubscribe = Settings.subscribe(onSettingsChanged)

	return function()
		unsubscribe()
		endStroke()
		for _, connection in connections do
			connection:Disconnect()
		end
		ring:Destroy()
		outline.destroy()
		keyStrip.destroy()
	end
end
