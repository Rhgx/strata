--!strict
--[[
	The Mesh tool: how many triangles each part of a tile has, and which triangles exist at all.

	Simplify mode marks first and acts second (like selecting in Blender, then dissolving), so
	sweeping the brush never changes the terrain by surprise. Drag over points to mark them for
	removal (orange); Ctrl + drag marks removed points to come back (green) and either drag
	unmarks the opposite kind. A click without dragging toggles the single nearest point. Marked
	tiles preview the result: the triangle edges the tile would gain are drawn, and the panel
	shows the triangle count before and after. Apply (or Enter, or X) commits every marked tile
	as one undo step; Clear (or the first Esc) drops the marks. Marks are also dropped on undo,
	redo, a mode change and when the tool stops (never applied by surprise).

	Cut holes mode: drag to delete triangles, Ctrl restores them, one undo step per stroke.
	Deleted triangles are outlined on the hovered tile, and the cursor lands on them too, so they
	can be found again.

	Viewport controls:
		Left drag       mark points to remove / delete triangles
		Ctrl + drag     mark points to restore / restore triangles
		Click           toggle the nearest point's mark (Simplify)
		Enter or X      apply the marks (Simplify)
		Ctrl + scroll   resize the brush ([ and ] too)
		Esc             clear the marks, then stop
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Displacement = require(script.Parent.Parent.Core.Displacement)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Settings = require(script.Parent.Parent.State.Settings)
local Format = require(script.Parent.Parent.State.Format)
local Status = require(script.Parent.Parent.State.Status)
local MeshStage = require(script.Parent.Parent.Scene.MeshStage)
local Session = require(script.Parent.Parent.Scene.Session)
local Query = require(script.Parent.Parent.Scene.Query)
local Bake = require(script.Parent.Parent.Actions.Bake)
local MeshActions = require(script.Parent.Parent.Actions.Mesh)
local Input = require(script.Parent.Input)
local Cursor = require(script.Parent.Cursor)
local KeyStrip = require(script.Parent.KeyStrip)
local Lines = require(script.Parent.Lines)
local RadiusPreview = require(script.Parent.RadiusPreview)
local TileHit = require(script.Parent.TileHit)
local TriangleBrush = require(script.Parent.TriangleBrush)
local TriangleOutline = require(script.Parent.TriangleOutline)

type Opened = TerrainInstance.Opened

local REMOVE_COLOR = Color3.fromRGB(230, 96, 80)
local RESTORE_COLOR = Color3.fromRGB(96, 200, 120)
local MARK_COLOR = Color3.fromRGB(255, 150, 40)
local WIRE_COLOR = Color3.fromRGB(235, 235, 235)
local WIRE_THICKNESS = 0.04
local PREVIEW_THICKNESS = 0.08
-- Existing holes are outlined faintly, so the brush outline stands out over them.
local HOLE_LINE_THICKNESS = 0.04
local MAX_OUTLINE_LINES = 300
local MAX_LINES = 1600
local MAX_PREVIEW_LINES = 1200
-- Points are drawn within this many studs beyond the brush.
local DOT_MARGIN = 6
local MAX_DOTS = 300
local KEPT_COLOR = Color3.fromRGB(235, 235, 235)
-- Pixels the mouse may move before a press counts as a drag instead of a click.
local DRAG_PIXELS = 4
local SEPARATOR = KeyStrip.SEPARATOR

local function edgeKey(a: number, b: number, count: number): number
	return math.min(a, b) * (count + 1) + math.max(a, b)
end

-- Starts the tool and returns a function that stops it.
return function(plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local connections: { RBXScriptConnection } = {}

	-- Cut holes stroke.
	local recording: string? = nil
	local touched: { [Opened]: true } = {}
	local warned: { [Opened]: true } = {}
	local lastCenter: Vector3? = nil
	-- Simplify press: where it started, whether it became a drag, and which kind it marks.
	local press: { x: number, y: number, dragging: boolean, restoring: boolean }? = nil
	local centers: { [Opened]: { pivot: CFrame, version: number, list: { Vector3 } } } = {}
	local wasMeshing = false
	local lastMode: Settings.MeshMode = Settings.get().meshMode

	-- No ring: Simplify's cursor is the highlighted points, Cut holes' is the outline of the
	-- triangles a click would delete. The faint ring only shows the size during a radius preview.
	local ring = RadiusPreview.newRing("StrataMeshPreview", true, 0.65)
	local keyStrip = KeyStrip.new("StrataMeshHints")
	local lines = Lines.new("StrataMeshLine", MAX_LINES)
	local outline = Lines.new("StrataMeshOutline", MAX_OUTLINE_LINES)
	local previewLines = Lines.new("StrataMeshResult", MAX_PREVIEW_LINES)

	-- Bumped whenever points or holes change, so the wireframe redraws.
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

	-- Hides what follows the cursor; the result preview of marked tiles stays.
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

	-- Shown triangle centers, kept across frames until the tile moves or its triangles change.
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

	-- The wireframe (Simplify) or hole outlines (Cut holes) of the hovered tile.
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

	-- The edges every marked tile would gain, drawn bright so the result (and any edge flips)
	-- shows before Apply. Redrawn only when the marks change.
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
				-- Every point restored: the full grid comes back.
				for g = 1, Displacement.gridTriangleCount(disp) do
					local a, b, c = Displacement.gridTriangle(disp, g)
					edge(a, b)
					edge(b, c)
					edge(c, a)
				end
			end
		end
	end

	-- Points near the cursor on every tile the brush reaches, colored by state: kept white,
	-- marked to remove orange, removed red, marked to restore green. The ones a drag would mark
	-- are drawn larger.
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

	-- Simplify drag: marks the points under the brush (or unmarks the opposite kind).
	local function markAt(models: { Model }, hit: TileHit.Hit, restoring: boolean)
		local radius = Settings.get().radius
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
					-- Ctrl: mark removed points to come back, drop removal marks.
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
	-- Simplify click: toggles the mark of the point nearest the cursor on the hovered tile.
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

	-- Cut holes: deletes (or restores) the triangles under the brush.
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
			local changed = TriangleBrush.write(opened, grids, target, function(g: number): boolean
				-- Restoring only touches holes; painted triangles keep their looks.
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
		-- Cut holes looks at the data, so deleted triangles can be found to restore them.
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
	-- Set while Alt + dragging to resize; the cursor stays where the drag started.
	local resize: Input.DragResize? = nil

	local function beginStroke()
		local settings = Settings.get()
		-- A new press ends anything a missed button release left behind.
		resize = nil
		if recording then
			endStroke()
		end
		if not settings.meshing then
			return
		end
		if Session.isBaking() then
			-- Say so instead of ignoring the click.
			Status.post("warning", "Still baking the last edits. Try again in a moment.")
			return
		end
		-- Alt + drag resizes instead (it would otherwise orbit the camera).
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
	for _, connection in Input.connectResize(mouse, function()
		return Settings.get().meshing
	end, Settings.stepRadius) do
		table.insert(connections, connection)
	end
	table.insert(
		connections,
		Input.onKey(function(input: Input.Key)
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
	-- Undo and redo change tiles behind the marks' back, and the wireframe must redraw.
	local function onHistory()
		version += 1
		MeshStage.clear()
	end
	table.insert(connections, ChangeHistoryService.OnUndo:Connect(onHistory))
	table.insert(connections, ChangeHistoryService.OnRedo:Connect(onHistory))
	-- Marks applied from the panel's Apply button change points too; clearing them is the cue.
	local unsubscribeStage = MeshStage.subscribe(function()
		if MeshStage.isEmpty() then
			version += 1
		end
	end)

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function()
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
					Settings.update(function(s)
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
					-- No terrain in the middle of the view: show the size as a plain ring.
					ring.CFrame = CFrame.lookAt(position, position + facing)
					ring.Radius = settings.radius
					ring.InnerRadius = settings.radius - math.max(0.15, settings.radius * 0.04)
					ring.Color3 = REMOVE_COLOR
					ring.Visible = true
					RadiusPreview.label(position, sizeText)
				end
				return
			end
			-- During a radius preview Simplify also shows a faint ring, since sparse points alone do
			-- not show the size changing smoothly.
			if previewing and not holes then
				local normal = hit.normal
				local up = if math.abs(normal.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
				ring.CFrame = CFrame.lookAt(hit.position + normal * 0.05, hit.position + normal * 2, up)
				ring.Radius = settings.radius
				ring.InnerRadius = settings.radius - math.max(0.15, settings.radius * 0.04)
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
				drawPoints(models, hit, settings.radius, restoring)
			end
		end)
	)
	local unsubscribe = Settings.subscribe(onSettingsChanged)

	return function()
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
