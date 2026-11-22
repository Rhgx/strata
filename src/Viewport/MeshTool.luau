--!strict
--[[
	Viewport Mesh tool: controls triangle density (Simplify mode) and triangle deletion (Cut
	holes mode).

	Simplify mode stages edits before committing (like Blender's select-then-dissolve) so
	sweeping never mutates terrain unintentionally:
	- Drag marks points for removal (orange); Ctrl + Drag marks removed points for restoration
	  (green), and either drag unmarks opposite marks.
	- Click without dragging toggles the single nearest vertex.
	- Marked tiles draw bright preview edges for the resulting triangulation while the panel
	  shows before/after triangle counts.
	- Apply (Enter or X) commits all marked tiles as one undo step; Clear (or first Esc) drops
	  marks. Undo, redo, mode switches, and tool exit also drop unapplied marks.

	Cut holes mode deletes triangles while dragging (Ctrl restores them) with one undo step per
	stroke. Existing holes are outlined on the hovered tile and raycastable for restoration.

	Viewport controls:
		Left drag       mark points to remove / delete triangles
		Ctrl + drag     mark points to restore / restore triangles
		Click           toggle nearest point mark (Simplify)
		Enter or X      apply staged marks (Simplify)
		Ctrl + scroll   resize brush ([ and ] also resize)
		Esc             clear staged marks first, then stop
]]

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Core = Plugin.Core
local State = Plugin.State
local Scene = Plugin.Scene
local Actions = Plugin.Actions

local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)
local MeshStage = require(Scene.MeshStage)

local Bake = require(Actions.Bake)
local MeshActions = require(Actions.Mesh)

local Input = require(Viewport.Input)
local Lines = require(Viewport.Lines)
local Cursor = require(Viewport.Cursor)
local TileHit = require(Viewport.TileHit)
local KeyStrip = require(Viewport.KeyStrip)
local RadiusPreview = require(Viewport.RadiusPreview)
local TriangleBrush = require(Viewport.TriangleBrush)
local TriangleOutline = require(Viewport.TriangleOutline)

type Opened = TerrainInstance.Opened

local REMOVE_COLOR = Color3.fromRGB(230, 96, 80)
local RESTORE_COLOR = Color3.fromRGB(96, 200, 120)
local MARK_COLOR = Color3.fromRGB(255, 150, 40)
local WIRE_COLOR = Color3.fromRGB(235, 235, 235)
local KEPT_COLOR = Color3.fromRGB(235, 235, 235)

local WIRE_THICKNESS = 0.04
local PREVIEW_THICKNESS = 0.08
-- Keep existing hole outlines subtle so the active brush outline reads clearly over them.
local HOLE_LINE_THICKNESS = 0.04
local MAX_OUTLINE_LINES = 300
local MAX_LINES = 1600
local MAX_PREVIEW_LINES = 1200
-- Draw vertex dots up to this many studs past the brush radius for surrounding context.
local DOT_MARGIN = 6
local MAX_DOTS = 300
-- Pointer travel threshold in pixels separating a single-point click from a drag stroke.
local DRAG_PIXELS = 4
-- A Simplify drag always reaches this share of a grid step (see markReach).
local MIN_MARK_STEPS = 0.75
local SEPARATOR = KeyStrip.SEPARATOR

local function edgeKey(a: number, b: number, count: number): number
	return math.min(a, b) * (count + 1) + math.max(a, b)
end

-- Starts the Mesh tool and returns a cleanup callback.
return function (plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local connections: { RBXScriptConnection } = {}

	-- Cut holes stroke state.
	local recording: string? = nil
	local touched: { [Opened]: true } = {}
	local warned: { [Opened]: true } = {}
	local lastCenter: Vector3? = nil

	-- Simplify press/drag state.
	local press: { x: number, y: number, dragging: boolean, restoring: boolean }? = nil
	local resize: Input.DragResize? = nil
	local centers: { [Opened]: { pivot: CFrame, version: number, list: { Vector3 } } } = {}
	local wasMeshing = false
	local lastMode: Settings.MeshMode = Settings.get().meshMode

	-- Simplify highlights vertices directly and Cut holes outlines triangles; the faint ring
	-- appears only during radius previews (and as a fallback when no terrain is under center).
	local ring = RadiusPreview.newRing("StrataMeshPreview", true, 0.65)
	local keyStrip = KeyStrip.new("StrataMeshHints")
	local lines = Lines.new("StrataMeshLine", MAX_LINES)
	local outline = Lines.new("StrataMeshOutline", MAX_OUTLINE_LINES)
	local previewLines = Lines.new("StrataMeshResult", MAX_PREVIEW_LINES)

	-- Increments when topology or holes change so cached wireframes and centers invalidate.
	local version = 0
	local drawn: { opened: Opened, version: number, pivot: CFrame, mode: Settings.MeshMode }? = nil
	local previewDrawn = -1

	local dots: { SphereHandleAdornment } = {}
	local usedDots = 0

	local function dot(position: Vector3, color: Color3, radius: number, transparency: number)
		if usedDots >= MAX_DOTS then
			return
		end

		usedDots += 1

		if not dots[usedDots] then
			local created = Instance.new("SphereHandleAdornment")
			created.Name = "StrataMeshPoint"
			created.Adornee = workspace.Terrain
			created.AlwaysOnTop = true
			created.ZIndex = 3
			created.Parent = CoreGui
			dots[usedDots] = created
		end

		local adornment = dots[usedDots]
		adornment.CFrame = CFrame.new(position)
		adornment.Radius = radius
		adornment.Color3 = color
		adornment.Transparency = transparency
		adornment.Visible = true
	end

	local function clearDots()
		for i = 1, usedDots do
			dots[i].Visible = false
		end

		usedDots = 0
	end

	-- Hides pointer-tracking adornments while keeping staged result preview edges visible.
	local function hideCursor()
		ring.Visible = false
		lines.clear()
		outline.clear()
		clearDots()
		drawn = nil
		RadiusPreview.label(nil)
	end

	local function hideAll()
		hideCursor()
		previewLines.clear()
		previewDrawn = -1
	end

	local function centersOf(opened: Opened): { Vector3 }
		local pivot = opened.model:GetPivot()
		local cached = centers[opened]

		if cached and cached.pivot == pivot and cached.version == version then
			return cached.list
		end

		local computed = TileHit.centers(opened)
		centers[opened] = { pivot = pivot, version = version, list = computed }
		return computed
	end

	-- Renders the hovered tile's wireframe (Simplify) or existing hole outlines (Cut holes).
	local function drawTile(opened: Opened, mode: Settings.MeshMode)
		local pivot = opened.model:GetPivot()
		local current = drawn

		if current and current.opened == opened and current.version == version and current.pivot == pivot and current.mode == mode then
			return
		end

		lines.clear()
		drawn = { opened = opened, version = version, pivot = pivot, mode = mode }

		local disp = opened.disp
		local positions = Displacement.positions(disp)
		local seen: { [number]: true } = {}
		local count = #positions

		for t = 1, Displacement.triangleCount(disp) do
			if mode == "Holes" and not Displacement.isHole(disp, t) then
				continue
			end

			local i1, i2, i3 = Displacement.triangle(disp, t)

			for _, pair in { { i1, i2 }, { i2, i3 }, { i3, i1 } } do
				local key = edgeKey(pair[1], pair[2], count)

				if not seen[key] then
					seen[key] = true

					if mode == "Holes" then
						lines.line(pivot * positions[pair[1]], pivot * positions[pair[2]], REMOVE_COLOR, HOLE_LINE_THICKNESS, 0.55)
					else
						lines.line(pivot * positions[pair[1]], pivot * positions[pair[2]], WIRE_COLOR, WIRE_THICKNESS, 0.55)
					end
				end
			end
		end
	end

	-- Draws bright orange preview edges for every new triangle edge staged marks would introduce.
	-- Rebuilds only when MeshStage.version() changes.
	local function drawResult()
		local stageVersion = MeshStage.version()

		if previewDrawn == stageVersion then
			return
		end

		previewDrawn = stageVersion
		previewLines.clear()

		for model in MeshStage.entries() do
			local opened = Session.get(model)

			if not opened then
				continue
			end

			local disp = opened.disp
			local count = Displacement.vertexCount(disp)
			local now: { [number]: true } = {}

			for t = 1, Displacement.triangleCount(disp) do
				local i1, i2, i3 = Displacement.triangle(disp, t)
				now[edgeKey(i1, i2, count)] = true
				now[edgeKey(i2, i3, count)] = true
				now[edgeKey(i3, i1, count)] = true
			end

			local _, mesh = MeshStage.preview(opened)
			local pivot = opened.model:GetPivot()
			local normal = Displacement.faceNormal(disp)
			local lift = pivot:VectorToWorldSpace(normal) * 0.03
			local drawnEdges: { [number]: true } = {}

			local function edge(a: number, b: number)
				local key = edgeKey(a, b, count)

				if now[key] or drawnEdges[key] then
					return
				end

				drawnEdges[key] = true
				previewLines.line(
					pivot * Displacement.position(disp, a, normal) + lift,
					pivot * Displacement.position(disp, b, normal) + lift,
					MARK_COLOR,
					PREVIEW_THICKNESS,
					0.05
				)
			end

			if mesh then
				for _, tri in mesh.triangles do
					edge(tri[1], tri[2])
					edge(tri[2], tri[3])
					edge(tri[3], tri[1])
				end
			else
				-- All points restored: preview the full grid edges returning.
				for g = 1, Displacement.gridTriangleCount(disp) do
					local a, b, c = Displacement.gridTriangle(disp, g)
					edge(a, b)
					edge(b, c)
					edge(c, a)
				end
			end
		end
	end

	-- How far a Simplify drag reaches: the Radius, but at least most of a grid step, so a drag
	-- with a small radius still marks the nearest point instead of nothing (like the sculpt
	-- brushes, which always reach one grid step).
	local function markReach(opened: Opened, radius: number): number
		local c = opened.disp.corners
		local spacing = math.max((c[4] - c[1]).Magnitude, (c[2] - c[1]).Magnitude) / (opened.disp.size - 1)

		return math.max(radius, spacing * MIN_MARK_STEPS)
	end

	-- Draws vertex dots near the cursor colored by state (white kept, orange remove-marked, red
	-- removed, green restore-marked), enlarging vertices that a drag would affect.
	local function drawPoints(models: { Model }, hit: TileHit.Hit, radius: number, restoring: boolean)
		clearDots()

		local size = math.max(0.12, math.min(0.35, radius * 0.03))

		for _, opened in TriangleBrush.tilesInReach(models, hit, radius + DOT_MARGIN, 0) do
			local disp = opened.disp
			local pivot = opened.model:GetPivot()
			local normal = Displacement.faceNormal(disp)

			for v = 1, Displacement.vertexCount(disp) do
				local position = pivot * Displacement.position(disp, v, normal)
				local distance = (position - hit.position).Magnitude

				if distance > radius + DOT_MARGIN then
					continue
				end

				local removed = disp.removed[v] == true
				local mark = MeshStage.markOf(opened.model, v)
				local under = distance <= radius and not Displacement.isCorner(disp, v) and removed == restoring
				local scale = if under then 1.4 else 1

				if mark == "remove" then
					dot(position, MARK_COLOR, size * 1.2 * scale, 0)
				elseif mark == "restore" then
					dot(position, RESTORE_COLOR, size * 1.2 * scale, 0)
				elseif removed then
					dot(position, REMOVE_COLOR, size * 0.8 * scale, if under then 0.1 else 0.45)
				else
					dot(position, KEPT_COLOR, size * scale, if under then 0 else 0.25)
				end
			end
		end
	end

	-- Simplify drag: marks vertices inside the brush (or clears opposing marks).
	local function markAt(models: { Model }, hit: TileHit.Hit, restoring: boolean)
		local radius = markReach(hit.opened, Settings.get().radius)
		local samples, travel = TriangleBrush.samples(lastCenter, hit.position, radius)
		lastCenter = hit.position

		for _, opened in TriangleBrush.tilesInReach(models, hit, radius, travel) do
			local disp = opened.disp
			local pivot = opened.model:GetPivot()
			local normal = Displacement.faceNormal(disp)
			local current = MeshStage.entries()[opened.model]
			local marks: { [number]: MeshStage.Mark } = if current then table.clone(current) else {}
			local changed = false

			for v = 1, Displacement.vertexCount(disp) do
				if Displacement.isCorner(disp, v) then
					continue
				end

				local position = pivot * Displacement.position(disp, v, normal)
				local inside = false

				for _, sample in samples do
					if (position - sample).Magnitude <= radius then
						inside = true
						break
					end
				end

				if not inside then
					continue
				end

				local removed = disp.removed[v] == true
				local mark = marks[v]

				if restoring then
					if removed and mark == nil then
						marks[v] = "restore"
						changed = true
					elseif mark == "remove" then
						marks[v] = nil
						changed = true
					end
				elseif not removed and mark == nil then
					marks[v] = "remove"
					changed = true
				elseif mark == "restore" then
					marks[v] = nil
					changed = true
				end
			end

			if changed then
				MeshStage.replace(opened.model, marks)
			end
		end
	end

	-- Simplify click: toggles the staged mark on the single non-corner vertex nearest `hit`.
	local function toggleNearest(hit: TileHit.Hit)
		local opened = hit.opened
		local disp = opened.disp
		local pivot = opened.model:GetPivot()
		local normal = Displacement.faceNormal(disp)
		local nearest, nearestDistance = nil, math.huge

		for v = 1, Displacement.vertexCount(disp) do
			if Displacement.isCorner(disp, v) then
				continue
			end

			local distance = (pivot * Displacement.position(disp, v, normal) - hit.position).Magnitude

			if distance < nearestDistance then
				nearest, nearestDistance = v, distance
			end
		end

		if not nearest then
			return
		end

		local mark = MeshStage.markOf(opened.model, nearest)

		if mark then
			MeshStage.set(opened.model, nearest, nil)
		else
			MeshStage.set(opened.model, nearest, if disp.removed[nearest] then "restore" else "remove")
		end
	end

	-- Cut holes stroke: deletes (or restores with Ctrl) grid triangles under the brush.
	local function cutAt(models: { Model }, hit: TileHit.Hit)
		local settings = Settings.get()
		local radius = settings.radius
		local restoring = Input.ctrl()
		local samples, travel = TriangleBrush.samples(lastCenter, hit.position, radius)
		lastCenter = hit.position

		for _, opened in TriangleBrush.tilesInReach(models, hit, radius, travel) do
			local disp = opened.disp
			local grids = TriangleBrush.gridTriangles(opened, hit, samples, radius, settings.paintFine, centersOf(opened))
			local target = if restoring then 0 else Displacement.HOLE
			local changed = TriangleBrush.write(opened, grids, target, function (g: number): boolean
				-- Restoring only fills holes and leaves painted triangles untouched.
				return not restoring or disp.triLooks[g] == Displacement.HOLE
			end)

			if #changed > 0 then
				touched[opened] = true
				version += 1

				if not restoring and Displacement.holeCount(disp) == Displacement.gridTriangleCount(disp) and not warned[opened] then
					warned[opened] = true
					Status.post("warning", `{opened.model.Name} has no triangles left. Hold Ctrl to restore them, or delete the tile.`)
				end
			end
		end
	end

	local function findHit(models: { Model }): TileHit.Hit?
		-- Cut holes raycasts against geometry data so deleted triangles can be targeted for restoration.
		return TileHit.find(mouse, models, Settings.get().meshMode == "Holes")
	end

	local function applyMarks()
		if MeshStage.isEmpty() then
			return
		end

		if Session.isBaking() then
			Status.post("warning", "Still baking the last edits. Try again in a moment.")
			return
		end

		local ok, tiles, points = pcall(MeshActions.applyMarks)

		if not ok then
			Status.post("error", `Simplify failed: {tiles}`)
		elseif points > 0 then
			version += 1
			Status.post("success", `Changed {points} point{if points == 1 then "" else "s"} on {tiles} tile{if tiles == 1 then "" else "s"}.`)
		end
	end

	local endStroke: () -> ()

	local function beginStroke()
		local settings = Settings.get()
		resize = nil

		if recording then
			endStroke()
		end

		if not settings.meshing then
			return
		end

		if Session.isBaking() then
			Status.post("warning", "Still baking the last edits. Try again in a moment.")
			return
		end

		local drag = Input.beginDragResize(mouse, settings.radius)

		if drag then
			resize = drag
			return
		end

		lastCenter = nil

		if settings.meshMode == "Simplify" then
			press = { x = mouse.X, y = mouse.Y, dragging = false, restoring = Input.ctrl() }
			return
		end

		local restoring = Input.ctrl()
		recording = ChangeHistoryService:TryBeginRecording(if restoring then "Strata restore triangles" else "Strata delete triangles")

		if not recording then
			Status.post("warning", "Studio is busy recording another change. Stroke skipped.")
			return
		end

		local models = Query.workingModels()
		local hit = findHit(models)

		if hit then
			cutAt(models, hit)
		end
	end

	function endStroke()
		resize = nil

		local current = press
		press = nil

		if current and not current.dragging and Settings.get().meshing then
			local hit = findHit(Query.workingModels())

			if hit then
				toggleNearest(hit)
			end
		end

		lastCenter = nil

		local recordingId = recording

		if not recordingId then
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

		ChangeHistoryService:FinishRecording(
			recordingId,
			if edited > 0 then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end

	local function onSettingsChanged(state: Settings.State)
		if state.meshMode ~= lastMode then
			lastMode = state.meshMode
			MeshStage.clear()
		end

		if state.meshing == wasMeshing then
			return
		end

		wasMeshing = state.meshing

		if not state.meshing then
			press = nil
			endStroke()
			MeshStage.clear()
			hideAll()
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

	for _, connection in Input.connectResize(mouse, function ()
		return Settings.get().meshing
	end, Settings.stepRadius) do
		table.insert(connections, connection)
	end

	table.insert(
		connections,
		Input.onKey(function (input: Input.Key)
			local settings = Settings.get()

			if not settings.meshing or UserInputService:GetFocusedTextBox() then
				return
			end

			if
				settings.meshMode == "Simplify"
				and (input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter or input.KeyCode == Enum.KeyCode.X)
				and not Input.ctrl()
			then
				task.spawn(applyMarks)
			end
		end)
	)

	-- Undo and redo invalidate staged marks and require redrawing the wireframe.
	local function onHistory()
		version += 1
		MeshStage.clear()
	end

	table.insert(connections, ChangeHistoryService.OnUndo:Connect(onHistory))
	table.insert(connections, ChangeHistoryService.OnRedo:Connect(onHistory))

	-- Applying marks from the panel clears MeshStage; bump version so the wireframe redraws.
	local unsubscribeStage = MeshStage.subscribe(function ()
		if MeshStage.isEmpty() then
			version += 1
		end
	end)

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function ()
			local settings = Settings.get()

			if not settings.meshing then
				return
			end

			local holes = settings.meshMode == "Holes"
			local current = press
			local restoring = if current then current.restoring else Input.ctrl()
			local marked = not MeshStage.isEmpty()

			local hints = if holes
				then {
					"<b>Cut holes</b>",
					if restoring then "Left Drag: Restore triangles" else "Left Drag: Delete triangles",
					"Ctrl: Restore",
					`Ctrl + Scroll: Size ({Format.studs(settings.radius)})`,
					"Esc: Stop",
				}
				else {
					"<b>Simplify</b>",
					if restoring then "Drag: Mark to restore" else "Drag: Mark to remove",
					"Click: Toggle point",
					"Ctrl: Restore",
					if marked then "Enter: Apply" else `Ctrl + Scroll: Size ({Format.studs(settings.radius)})`,
					if marked then "Esc: Clear marks" else "Esc: Stop",
				}

			keyStrip.show(if settings.showKeyHints then table.concat(hints, SEPARATOR) else nil)

			if not holes then
				drawResult()
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

			local previewing = RadiusPreview.active() or resizing ~= nil
			local ray = if resizing then resizing.ray elseif RadiusPreview.active() then RadiusPreview.ray() else mouse.UnitRay
			local hit = if ray then TileHit.findAlong(ray, models, holes) else nil
			local sizeText = `Radius {Format.studs(settings.radius)} st`

			if not hit then
				hideCursor()

				local position, facing = nil, nil

				if previewing then
					position, facing = RadiusPreview.fallback(settings.radius)
				end

				if position and facing then
					ring.CFrame = CFrame.lookAt(position, position + facing)
					ring.Radius = settings.radius
					ring.InnerRadius = settings.radius - math.max(0.15, settings.radius * 0.04)
					ring.Color3 = REMOVE_COLOR
					ring.Visible = true
					RadiusPreview.label(position, sizeText)
				end

				return
			end

			-- Show a faint ring during Simplify radius previews because sparse dots alone do not
			-- convey continuous radius adjustments clearly.
			if previewing and not holes then
				local normal = hit.normal
				local up = if math.abs(normal.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
				-- The ring shows how far a drag reaches, which is at least most of a grid step.
				local reach = markReach(hit.opened, settings.radius)
				ring.CFrame = CFrame.lookAt(hit.position + normal * 0.05, hit.position + normal * 2, up)
				ring.Radius = reach
				ring.InnerRadius = reach - math.max(0.15, reach * 0.04)
				ring.Color3 = if restoring then RESTORE_COLOR else MARK_COLOR
				ring.Visible = true
			else
				ring.Visible = false
			end

			RadiusPreview.label(if previewing then hit.position else nil, sizeText)

			if recording then
				cutAt(models, hit)
			end

			if current and not holes then
				if not current.dragging and math.abs(mouse.X - current.x) + math.abs(mouse.Y - current.y) > DRAG_PIXELS then
					current.dragging = true
				end

				if current.dragging then
					markAt(models, hit, current.restoring)
				end
			end

			drawTile(hit.opened, settings.meshMode)

			if holes then
				clearDots()

				local covered: { TriangleOutline.Covered } = {}

				for _, opened in TriangleBrush.tilesInReach(models, hit, settings.radius, 0) do
					local grids = TriangleBrush.gridTriangles(opened, hit, { hit.position }, settings.radius, settings.paintFine, centersOf(opened))
					table.insert(covered, { opened = opened, grids = grids })
				end

				TriangleOutline.draw(outline, covered, if restoring then RESTORE_COLOR else REMOVE_COLOR)
			else
				outline.clear()
				drawPoints(models, hit, markReach(hit.opened, settings.radius), restoring)
			end
		end)
	)

	local unsubscribe = Settings.subscribe(onSettingsChanged)

	return function ()
		unsubscribe()
		unsubscribeStage()
		endStroke()

		for _, connection in connections do
			connection:Disconnect()
		end

		MeshStage.clear()
		ring:Destroy()
		lines.destroy()
		outline.destroy()
		previewLines.destroy()

		for _, adornment in dots do
			adornment:Destroy()
		end

		keyStrip.destroy()
	end
end
