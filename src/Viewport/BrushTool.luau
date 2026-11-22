--!strict
--[[
	Viewport side of paint geometry: mouse input, raycasting onto displacements, the brush
	cursor, the key strip, per-frame strokes and undo. One stroke (mouse down to mouse up) is
	one undo step, including the autosew that runs when the stroke ends. When painting stops,
	everything edited is baked back into unions as its own undo step.

	Viewport controls while painting (Ctrl and Shift follow Studio's terrain editor):
		Left drag          paint with the selected tool
		Ctrl               invert (Raise <-> Lower)
		Ctrl + click       Raise To: pick the height from the terrain under the cursor
		Shift              smooth
		Ctrl + scroll      resize the brush (the camera is held still meanwhile, see Input)
		Alt + drag         resize the brush too (right grows, left shrinks), like Hammer
		Alt + right click  pick the paint axis from the face under the cursor, like Hammer
		[ and ]            shrink and grow the brush, on layouts that have these keys
		Esc                stop painting

	How a stroke feels:
	- The brush aims at each tile's surface as it was when the stroke first reached it, then
	  follows the live surface at that spot (Core/SurfaceRay). Holding still while raising builds
	  a centered hill instead of one walking toward the camera, and rays never slip through the
	  seams between wedges.
	- Every frame covers the whole path the cursor moved, so fast drags leave no gaps; the first
	  frame applies a small dab, so a quick click does something.
	- Paint, sewing and pinned edges edit vertex data first; wedges move once per frame.

	The brush centers on the surface point under the cursor. Hammer snaps it to the nearest grid
	vertex instead; the surface point follows the mouse more smoothly in Studio.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Displacement = require(script.Parent.Parent.Core.Displacement)
local Paint = require(script.Parent.Parent.Core.Paint)
local Sew = require(script.Parent.Parent.Core.Sew)
local Stitch = require(script.Parent.Parent.Core.Stitch)
local SurfaceRay = require(script.Parent.Parent.Core.SurfaceRay)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Settings = require(script.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.State.Status)
local Session = require(script.Parent.Parent.Scene.Session)
local Query = require(script.Parent.Parent.Scene.Query)
local Edges = require(script.Parent.Parent.Actions.Edges)
local Bake = require(script.Parent.Parent.Actions.Bake)
local Input = require(script.Parent.Input)
local RadiusPreview = require(script.Parent.RadiusPreview)
local KeyStrip = require(script.Parent.KeyStrip)

type Opened = TerrainInstance.Opened
type Changes = { [Opened]: { [number]: true } }

-- What the cursor is over: a surface point, its normal (world) and the tile, if known.
type Hit = {
	position: Vector3,
	normal: Vector3,
	opened: Opened?,
}

local RAY_LENGTH = 10000
-- Caps one tick so a frame hitch does not turn into a huge jump.
local MAX_DT = 0.05
-- The dab applied the moment the button goes down, so a quick click always does something.
local TAP_DT = 0.08
-- Displacements facing away from the hit surface by more than this are skipped, so a brush on
-- one side of a thin wall does not push the far side. 90 degree corners (dot 0) still paint.
local BACK_FACE_DOT = -0.25
-- Brush samples along a frame's path: about a quarter radius apart, at most this many.
local STEP_SHARE = 0.25
local MIN_STEP = 0.5
local MAX_STEPS = 16
-- When a ray slips through a seam, keep the last hit for up to this many frames.
local SEAM_FRAMES = 2
-- How quickly the ring's tilt follows the surface (higher is snappier).
local NORMAL_FOLLOW = 24
-- Alt+drag resize speed: the radius doubles for about every 70 pixels dragged right.
local RESIZE_RATE = 0.01
local SEPARATOR = KeyStrip.SEPARATOR

local MODE_COLORS: { [Paint.Effect]: Color3 } = {
	Raise = Color3.fromRGB(96, 200, 96),
	Lower = Color3.fromRGB(230, 96, 80),
	Smooth = Color3.fromRGB(80, 160, 255),
	RaiseTo = Color3.fromRGB(230, 190, 70),
}

local function formatStuds(value: number): string
	return if value == math.floor(value) then tostring(value) else string.format("%.1f", value)
end

-- The viewport key strip for the active brush: only keys that do something with it.
local function keyHints(mode: Paint.Effect, settings: Settings.State, effective: number): string
	local parts: { string }
	if mode == "Raise" or mode == "Lower" then
		parts = {
			`<b>{mode}</b>`,
			"Left Drag: Paint",
			if mode == "Raise" then "Ctrl: Lower" else "Ctrl: Raise",
			"Shift: Smooth",
		}
	elseif mode == "Smooth" then
		parts = { "<b>Smooth</b>", "Left Drag: Smooth" }
	else
		parts = {
			`<b>Raise To ({formatStuds(settings.height)})</b>`,
			"Left Drag: Set height",
			"Ctrl + Click: Pick height",
			"Shift: Smooth",
		}
	end
	local size = if effective > settings.radius + 1e-3
		then `{formatStuds(settings.radius)}, grid min {formatStuds(math.round(effective * 10) / 10)}`
		else formatStuds(settings.radius)
	table.insert(parts, `Ctrl + Scroll: Size ({size})`)
	table.insert(parts, "Alt + Right Click: Axis")
	table.insert(parts, "Esc: Stop")
	return table.concat(parts, SEPARATOR)
end

-- The tool after applying held modifier keys.
local function effectiveMode(mode: Paint.Effect): Paint.Effect
	if Input.shift() then
		return "Smooth"
	end
	if Input.ctrl() then
		if mode == "Raise" then
			return "Lower"
		elseif mode == "Lower" then
			return "Raise"
		end
	end
	return mode
end

local function isEdgeVertex(disp: Displacement.Displacement, v: number): boolean
	local k = v - 1
	local size = disp.size
	local row, col = k // size, k % size
	return row == 0 or col == 0 or row == size - 1 or col == size - 1
end

local function newRing(name: string, alwaysOnTop: boolean, transparency: number): CylinderHandleAdornment
	local ring = Instance.new("CylinderHandleAdornment")
	ring.Name = name
	ring.Adornee = workspace.Terrain
	ring.Height = 0.06
	ring.AlwaysOnTop = alwaysOnTop
	ring.Transparency = transparency
	ring.Visible = false
	ring.Parent = CoreGui
	return ring
end

-- Starts the brush tool and returns a function that stops it.
return function(plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local connections: { RBXScriptConnection } = {}

	-- Per stroke.
	local recording: string? = nil
	local touched: { [Opened]: true } = {}
	-- Keep edges stitched: edges touching a part when the stroke first reached their tile, which
	-- tiles have been checked, and the pins spread to neighbor corners (recomputed only when
	-- new pins are added, not every frame).
	local pins: Stitch.Moves = {}
	local pinChecked: { [Opened]: true } = {}
	local propagated: Stitch.Moves = {}
	-- The surface of each tile as the stroke first reached it.
	local snapshots: { [Opened]: SurfaceRay.Snapshot } = {}
	local snapshotList: { SurfaceRay.Snapshot } = {}
	local lastCenter: Vector3? = nil
	-- Set when a tile's wedges were just built, so the next frame's (long) dt is clamped.
	local clampNext = false

	-- Hover.
	local lastHit: Hit? = nil
	local missFrames = 0
	local displayNormal: Vector3? = nil
	-- Set while Alt+dragging to resize; the ring stays where the drag started.
	local resize: { startX: number, startRadius: number }? = nil
	local wasPainting = false

	-- The ring is depth tested (true 3D occlusion); the faint ghost copy draws on top so the
	-- brush stays readable inside valleys. Both sit on the same circle, so they read as one.
	local ring = newRing("StrataBrushCursor", false, 0.2)
	local ghost = newRing("StrataBrushGhost", true, 0.78)
	local keyStrip = KeyStrip.new("StrataKeyHints")

	local function hideCursor()
		ring.Visible = false
		ghost.Visible = false
		RadiusPreview.label(nil)
	end

	-- The displacements the brush works on: the selected ones (Hammer's behavior) or all.
	local function workingModels(): { Model }
		if Settings.get().paintSelectedOnly then
			return Query.selectedModels()
		end
		return Session.models()
	end

	-- The surface under the mouse: snapshots for tiles this stroke already reached, live wedges
	-- for the rest, whichever is closer.
	local function findHit(models: { Model }, aim: Ray?): Hit?
		local ray = aim or mouse.UnitRay
		local direction = ray.Direction.Unit
		local filter: { Instance } = {}
		for _, model in models do
			local opened = Session.get(model)
			if not (opened and snapshots[opened]) then
				table.insert(filter, model)
			end
		end
		local live: RaycastResult? = nil
		if #filter > 0 then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = filter
			live = workspace:Raycast(ray.Origin, direction * RAY_LENGTH, params)
		end
		local snapped = if #snapshotList > 0 then SurfaceRay.cast(ray.Origin, direction, RAY_LENGTH, snapshotList) else nil
		local liveDistance = if live then live.Distance else math.huge
		if snapped and snapped.distance < liveDistance then
			missFrames = 0
			return { position = SurfaceRay.livePoint(snapped), normal = snapped.normal, opened = snapped.snapshot.opened }
		elseif live then
			missFrames = 0
			local model = Query.displacementOf(live.Instance)
			return { position = live.Position, normal = live.Normal, opened = if model then Session.get(model) else nil }
		end
		-- A ray through a hairline seam: stay on the last surface for a couple of frames.
		local previous = lastHit
		if previous and missFrames < SEAM_FRAMES then
			local along = direction:Dot(previous.normal)
			if math.abs(along) > 1e-6 then
				local t = (previous.position - ray.Origin):Dot(previous.normal) / along
				local point = ray.Origin + direction * t
				if t > 0 and (point - previous.position).Magnitude <= math.min(Settings.get().radius * 0.5, 2) then
					missFrames += 1
					return { position = point, normal = previous.normal, opened = previous.opened }
				end
			end
		end
		return nil
	end

	local function brushFor(mode: Paint.Effect, settings: Settings.State): Paint.Brush
		return {
			effect = mode,
			falloff = settings.falloff,
			axis = settings.axis,
			pickedAxis = settings.pickedAxis,
			radius = settings.radius,
			strength = settings.strength,
			height = settings.height,
		}
	end

	local function applyBrush(models: { Model }, hit: Hit, mode: Paint.Effect, dt: number)
		local settings = Settings.get()
		local center = hit.position
		-- Compare against the hit tile's base face, not the triangle under the cursor, so steep
		-- sculpted slopes and overhangs never cull their own tile.
		local hitOpened = hit.opened
		local hitFace = if hitOpened
			then hitOpened.model:GetPivot():VectorToWorldSpace(Displacement.faceNormal(hitOpened.disp))
			else hit.normal
		local brush = brushFor(mode, settings)
		local effective = if hitOpened then Paint.effectiveRadius(hitOpened, brush) else settings.radius
		-- Wide enough for the effective radius and for Smooth's neighbors across tile seams.
		local reach = effective * 2.5 + (if lastCenter then (center - lastCenter).Magnitude else 0)
		local targets: { Opened } = {}
		for _, opened in Session.getAll(models) do
			local pivot = opened.model:GetPivot()
			local faceNormal = pivot:VectorToWorldSpace(Displacement.faceNormal(opened.disp))
			local nearest = pivot:PointToObjectSpace(center)
			local gap = (nearest - nearest:Max(opened.boundsMin):Min(opened.boundsMax)).Magnitude
			if opened == hitOpened or (faceNormal:Dot(hitFace) >= BACK_FACE_DOT and gap <= reach) then
				table.insert(targets, opened)
			end
		end

		-- Before the brush first moves a tile: remember its surface (for aiming) and its
		-- stitched edges (to restore them below).
		local unchecked: { Opened } = {}
		for _, opened in targets do
			if not snapshots[opened] then
				local snapshot = SurfaceRay.snapshot(opened)
				snapshots[opened] = snapshot
				table.insert(snapshotList, snapshot)
			end
			if settings.stitchParts and not pinChecked[opened] then
				pinChecked[opened] = true
				table.insert(unchecked, opened)
			end
		end
		if #unchecked > 0 then
			local added = false
			for opened, targetsOf in Edges.pinsFor(unchecked) do
				pins[opened] = targetsOf
				added = true
			end
			if added then
				propagated = Edges.propagatePins(pins)
			end
		end

		-- Samples along the path since the last frame, so fast drags leave no gaps.
		local centers = { center }
		local previous = lastCenter
		if previous then
			local distance = (center - previous).Magnitude
			local step = math.max(effective * STEP_SHARE, MIN_STEP)
			local steps = math.clamp(math.ceil(distance / step), 1, MAX_STEPS)
			if steps > 1 then
				centers = table.create(steps)
				for k = 1, steps do
					centers[k] = previous:Lerp(center, k / steps)
				end
			end
		end
		lastCenter = center

		local changed = Paint.apply(targets, centers, brush, dt)
		if next(changed) == nil then
			return
		end
		local moved: Changes = {}
		local function collect(changes: Changes)
			for opened, vertices in changes do
				local set = moved[opened]
				if not set then
					set = {}
					moved[opened] = set
				end
				for v in vertices do
					set[v] = true
				end
			end
		end
		collect(changed)
		-- Sew the edited displacements to their neighbors every tick while autosew is on, so
		-- edges (especially 90 degree cliff edges, where faces move apart) do not tear open
		-- during the drag. Only needed when an edge vertex moved. The full autosew with part
		-- stitching still runs when the stroke ends.
		if settings.autosew then
			local focus: { [Opened]: true } = {}
			for opened, vertices in changed do
				for v in vertices do
					if isEdgeVertex(opened.disp, v) then
						focus[opened] = true
						break
					end
				end
			end
			if next(focus) ~= nil then
				collect((Sew.sew(targets, focus)))
			end
		end
		if settings.stitchParts and next(propagated) ~= nil then
			collect(Stitch.write(propagated))
		end
		for opened, vertices in moved do
			if Session.updateWedges(opened, vertices) then
				clampNext = true
			end
			touched[opened] = true
		end
	end

	-- Alt + right click: use the clicked face's normal as the paint axis. On a displacement that
	-- is its flat base face (Hammer picks the brush face plane). A miss resets to Up, as Hammer
	-- resets to its Z axis.
	local function pickAxis()
		local ray = mouse.UnitRay
		local hit = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH)
		local axis = Vector3.yAxis
		if hit then
			axis = hit.Normal
			local model = Query.displacementOf(hit.Instance)
			local opened = if model then Session.get(model) else nil
			if opened then
				axis = opened.model:GetPivot():VectorToWorldSpace(Displacement.faceNormal(opened.disp))
			end
		end
		Settings.update(function(s)
			s.axis = "Picked"
			s.pickedAxis = axis
		end)
		if hit then
			Status.post("success", string.format("Paint axis set to (%.2f, %.2f, %.2f).", axis.X, axis.Y, axis.Z))
		else
			Status.post("warning", "No face under the cursor. Picked axis reset to Up (Y).")
		end
	end

	-- Ctrl + click with Raise To: take the height from the terrain under the cursor.
	local function pickHeight()
		local settings = Settings.get()
		local hit = findHit(workingModels())
		local opened = if hit then hit.opened else nil
		if not hit or not opened then
			Status.post("warning", "No terrain under the cursor to pick a height from.")
			return
		end
		local height = math.round(Paint.heightAt(opened, hit.position, brushFor("RaiseTo", settings)) * 10) / 10
		Settings.update(function(s)
			s.height = height
		end)
		Status.post("success", `Raise To height set to {formatStuds(height)} studs.`)
	end

	-- Declared ahead: beginStroke ends a stroke whose button release was missed.
	local endStroke: () -> ()

	local function beginStroke()
		local settings = Settings.get()
		-- A stroke whose Button1Up was missed (released over another window) ends here, so the
		-- next press always starts fresh.
		if recording then
			endStroke()
		end
		if resize or not settings.painting or Session.isBaking() then
			return
		end
		-- Alt+drag resizes the brush instead of painting.
		if Input.alt() then
			resize = { startX = mouse.X, startRadius = settings.radius }
			return
		end
		if
			settings.mode == "RaiseTo"
			and Input.ctrl()
			and not Input.shift()
		then
			pickHeight()
			return
		end
		recording = ChangeHistoryService:TryBeginRecording("Strata paint")
		if not recording then
			Status.post("warning", "Studio is busy recording another change. Stroke skipped.")
			return
		end
		lastCenter = nil
		-- Dab right away, so a quick click always does something (waiting for the next frame
		-- could miss a click released before it).
		local models = workingModels()
		local hit = findHit(models)
		if hit then
			lastHit = hit
			applyBrush(models, hit, effectiveMode(settings.mode), TAP_DT)
		end
	end

	function endStroke()
		resize = nil
		local current = recording
		if not current then
			return
		end
		recording = nil

		local edited: { Opened } = {}
		for opened in touched do
			TerrainInstance.save(opened)
			table.insert(edited, opened)
		end
		table.clear(touched)
		local strokePins = pins
		pins = {}
		propagated = {}
		table.clear(pinChecked)
		table.clear(snapshots)
		table.clear(snapshotList)
		lastCenter = nil

		if #edited == 0 then
			-- A click that changed nothing leaves no empty undo step.
			ChangeHistoryService:FinishRecording(current, Enum.FinishRecordingOperation.Cancel)
			return
		end
		local ok, err = true, nil
		if Settings.get().autosew then
			ok, err = pcall(Edges.autosew, edited, strokePins)
		end
		ChangeHistoryService:FinishRecording(current, Enum.FinishRecordingOperation.Commit)
		if not ok then
			Status.post("error", `Auto-sew failed: {err}`)
		end
	end

	-- Activation (plugin:Activate, the mouse icon, Studio taking the mouse back) is handled by
	-- Viewport/Activation, shared with the other viewport tools.
	local function onSettingsChanged(state: Settings.State)
		if state.painting == wasPainting then
			return
		end
		wasPainting = state.painting
		if not state.painting then
			endStroke()
			hideCursor()
			keyStrip.show(nil)
			lastHit = nil
			displayNormal = nil
			if state.autoBake then
				task.spawn(Bake.bakeEdited)
			end
		end
	end

	table.insert(connections, mouse.Button1Down:Connect(beginStroke))
	table.insert(connections, mouse.Button1Up:Connect(endStroke))
	table.insert(
		connections,
		mouse.Button2Down:Connect(function()
			if Settings.get().painting and not recording and Input.alt() then
				pickAxis()
			end
		end)
	)

	-- Ctrl + scroll resizes (Input holds Studio's camera still for it). Plain scroll is left to
	-- the camera.
	for _, connection in Input.connectResize(mouse, function()
		return Settings.get().painting
	end, Settings.stepRadius) do
		table.insert(connections, connection)
	end

	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input)
			if not Settings.get().painting or UserInputService:GetFocusedTextBox() then
				return
			end
			if input.KeyCode == Enum.KeyCode.LeftBracket then
				Settings.stepRadius(-1)
			elseif input.KeyCode == Enum.KeyCode.RightBracket then
				Settings.stepRadius(1)
			end
		end)
	)

	-- The radius the brush really affects at `hit` (the grid may widen a small brush).
	local function effectiveAt(hit: Hit?, mode: Paint.Effect, settings: Settings.State): number
		local opened = if hit then hit.opened else nil
		return if opened then Paint.effectiveRadius(opened, brushFor(mode, settings)) else settings.radius
	end

	local function placeCursor(position: Vector3, normal: Vector3, settings: Settings.State, mode: Paint.Effect, radius: number)
		local up = if math.abs(normal.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
		local frame = CFrame.lookAt(position + normal * 0.05, position + normal * 2, up)
		-- Ring width scales with the brush so it stays readable at any size.
		local width = math.max(0.15, radius * 0.04)
		local color = MODE_COLORS[mode]
		for _, adornment in { ring, ghost } do
			adornment.CFrame = frame
			adornment.Radius = radius
			adornment.InnerRadius = radius - width
			adornment.Color3 = color
			adornment.Visible = true
		end
		-- Dimmer while dragging so it does not hide the terrain changing under it, and a little
		-- dimmer when the grid widened the brush beyond its Radius.
		local widened = radius > settings.radius + 1e-3
		ring.Transparency = if recording then 0.45 elseif widened then 0.38 else 0.2
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(dt)
			local settings = Settings.get()
			if not settings.painting then
				return
			end
			local mode: Paint.Effect = effectiveMode(settings.mode)
			keyStrip.show(if settings.showKeyHints then keyHints(mode, settings, effectiveAt(lastHit, mode, settings)) else nil)

			local resizing = resize
			if resizing then
				-- Alt + drag is also Studio's camera orbit; keep the camera still while resizing.
				Input.holdCamera()
				-- Exponential so small and large brushes resize at a comfortable speed.
				local radius = resizing.startRadius * math.exp((mouse.X - resizing.startX) * RESIZE_RATE)
				radius = math.round(radius * 2) / 2
				if radius ~= settings.radius then
					Settings.update(function(s)
						s.radius = radius
					end)
				end
				local held = lastHit
				if held then
					local current = Settings.get()
					placeCursor(held.position, displayNormal or held.normal, current, mode, effectiveAt(held, mode, current))
				end
				return
			end

			local models = workingModels()
			-- After a Radius change in the panel, show the brush in the middle of the view.
			if RadiusPreview.active() and not recording then
				local ray = RadiusPreview.ray()
				local previewHit = if ray then findHit(models, ray) else nil
				local text = `Radius {formatStuds(settings.radius)} st`
				if previewHit then
					placeCursor(previewHit.position, previewHit.normal, settings, mode, effectiveAt(previewHit, mode, settings))
					RadiusPreview.label(previewHit.position, text)
				else
					local position, facing = RadiusPreview.fallback(settings.radius)
					if position and facing then
						placeCursor(position, facing, settings, mode, settings.radius)
						RadiusPreview.label(position, text)
					end
				end
				return
			end
			RadiusPreview.label(nil)
			local hit = findHit(models)
			if not hit then
				hideCursor()
				lastHit = nil
				return
			end
			lastHit = hit
			-- Smooth the ring's tilt only (the position stays exact), so it glides over facets.
			local follow = 1 - math.exp(-NORMAL_FOLLOW * dt)
			local previousNormal = displayNormal
			local shown: Vector3 = if previousNormal then previousNormal:Lerp(hit.normal, follow) else hit.normal
			if shown.Magnitude < 1e-6 then
				shown = hit.normal
			end
			displayNormal = shown.Unit
			placeCursor(hit.position, displayNormal or hit.normal, settings, mode, effectiveAt(hit, mode, settings))

			if recording then
				local stepDt = math.min(dt, MAX_DT)
				if clampNext then
					-- The last frame built wedges for a baked tile; do not turn that pause into a bump.
					stepDt = math.min(stepDt, 1 / 60)
					clampNext = false
				end
				applyBrush(models, hit, mode, stepDt)
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
		ghost:Destroy()
		keyStrip.destroy()
	end
end
