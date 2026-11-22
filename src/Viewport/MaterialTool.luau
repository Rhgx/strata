--!strict
--[[
	Viewport Material tool: paints a look (material, color, and material variant) onto tile
	triangles (for example, roads through grass or rock patches). Each stroke is one undo step;
	stopping the tool auto-bakes edited tiles in a separate undo step.

	Viewport controls:
		Left drag          paint the active look
		Ctrl               erase back to the tile's base look (or paint when in Erase mode)
		Alt + right click  sample the look of any part or tile under the cursor
		Ctrl + scroll      resize the brush ([ and ] also resize)
		Esc                stop (cancels pipette mode first if active)

	Coverage is determined by TriangleBrush. Because vertices do not move, there is no strength,
	falloff, or sewing. Painting and erasing never fill holes (owned by Mesh tool Cut holes).
]]

local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Core = Plugin.Core
local State = Plugin.State
local Scene = Plugin.Scene

local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Bake = require(Plugin.Actions.Bake)

local Input = require(Viewport.Input)
local Lines = require(Viewport.Lines)
local Cursor = require(Viewport.Cursor)
local TileHit = require(Viewport.TileHit)
local KeyStrip = require(Viewport.KeyStrip)
local VisibleHit = require(Viewport.VisibleHit)
local RadiusPreview = require(Viewport.RadiusPreview)
local TriangleBrush = require(Viewport.TriangleBrush)
local TriangleOutline = require(Viewport.TriangleOutline)

type Opened = TerrainInstance.Opened

-- Warn when a tile exceeds this many distinct looks since each look bakes to its own union.
local LOOK_WARNING = 4
local ERASE_COLOR = Color3.fromRGB(230, 96, 80)
-- High-contrast cursor outline color (the painted color itself may blend into dark surfaces).
local PAINT_COLOR = Color3.fromRGB(70, 175, 255)
local MAX_OUTLINE_LINES = 300
-- Rebuild the cursor outline once the pointer moves at least this far (or settings change).
local OUTLINE_MOVE = 0.25
local SEPARATOR = KeyStrip.SEPARATOR

local function describe(look: Displacement.Look): string
	local name = (look.material.Name:gsub("(%l)(%u)", "%1 %2"))

	if look.variant ~= "" then
		name = `{name} ({look.variant})`
	end

	return `{name}, #{look.color:ToHex():upper()}`
end

-- Returns whether the current stroke erases (Ctrl swaps Paint and Erase modes).
local function erasing(settings: Settings.State): boolean
	return settings.paintErase ~= Input.ctrl()
end

-- Starts the Material tool and returns a cleanup callback.
return function (plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local connections: { RBXScriptConnection } = {}

	-- Stroke state.
	local recording: string? = nil
	local touched: { [Opened]: true } = {}
	-- Cached world-space shown triangle centers per tile, valid while the tile keeps its pivot,
	-- its data (Detail replaces it) and its triangles (Restore points or the Mesh tool rebuild
	-- them while this tool stays on, and stale centers would point the brush at wrong triangles).
	type CenterCache = { pivot: CFrame, disp: Displacement.Displacement, mesh: unknown?, list: { Vector3 } }
	local centers: { [Opened]: CenterCache } = {}
	local warned: { [Opened]: true } = {}
	local lastCenter: Vector3? = nil
	local wasColoring = false
	-- Tracks whether this stroke actually painted (not just erased) so the look joins recentLooks.
	local paintedLook = false
	local resize: Input.DragResize? = nil

	-- Primary cursor is the outline of affected triangles; the ring displays only as a fallback
	-- during panel radius previews when no terrain sits in the center of the viewport.
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
		local mesh = Displacement.mesh(opened.disp)
		local cached = centers[opened]

		if cached and cached.pivot == pivot and cached.disp == opened.disp and cached.mesh == mesh then
			return cached.list
		end

		local computed = TileHit.centers(opened)
		centers[opened] = { pivot = pivot, disp = opened.disp, mesh = mesh, list = computed }

		return computed
	end

	-- Draws the affected-triangle outline at `hit`, skipping redraws when inputs are unchanged.
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

		outlined = {
			opened = hit.opened,
			triangle = hit.triangle,
			position = hit.position,
			radius = settings.radius,
			fine = settings.paintFine,
			erase = erase,
		}

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
			local changed = TriangleBrush.write(opened, grids, target, function (g: number): boolean
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

	local function partUnderMouse(): BasePart?
		local hit = VisibleHit.cast(mouse.UnitRay, { workspace.Terrain })

		return if hit then hit.Instance else nil
	end

	-- Samples the look directly from the clicked part, wedge, or baked union under the cursor.
	local function pickLook()
		local part = partUnderMouse()

		Settings.update(function (s)
			s.pickingLook = false

			if part then
				s.paintMaterial = part.Material
				s.paintColor = part.Color
				s.paintVariant = part.MaterialVariant
				-- Switch back to Paint mode so the user can paint with the sampled look right away.
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

	local function beginStroke()
		local settings = Settings.get()
		resize = nil

		if recording then
			endStroke()
		end

		if not settings.coloring then
			return
		end

		if Session.isBaking() then
			Status.post("warning", "Still baking the last edits. Try again in a moment.")
			return
		end

		if settings.pickingLook then
			pickLook()
			return
		end

		-- Alt + Drag resizes the brush rather than painting (or orbiting the camera).
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

		-- A save that throws must still finish the recording, or Studio stays "busy recording"
		-- and every later edit fails.
		local saved, saveErr = pcall(function ()
			for opened in touched do
				TerrainInstance.save(opened)
				edited += 1
			end
		end)

		table.clear(touched)
		table.clear(warned)
		lastCenter = nil

		if not saved then
			ChangeHistoryService:FinishRecording(current, Enum.FinishRecordingOperation.Cancel)
			Session.clear()
			Status.post("error", `Could not save the stroke: {saveErr}`)
			return
		end

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

			-- Defer auto-bake when switching directly to another editing tool (see Settings.editing).
			if state.autoBake and not Settings.editing(state) then
				task.spawn(Bake.bakeEdited)
			end
		end
	end

	table.insert(connections, mouse.Button1Down:Connect(beginStroke))
	table.insert(
		connections,
		mouse.Button1Up:Connect(function ()
			endStroke()
		end)
	)
	table.insert(
		connections,
		mouse.Button2Down:Connect(function ()
			if Settings.get().coloring and not recording and Input.alt() then
				pickLook()
			end
		end)
	)

	for _, connection in Input.connectResize(mouse, function ()
		return Settings.get().coloring
	end, Settings.stepRadius) do
		table.insert(connections, connection)
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function ()
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
					Settings.update(function (s)
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
					-- Fallback plain ring when no terrain sits in the center of the viewport.
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

	return function ()
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
