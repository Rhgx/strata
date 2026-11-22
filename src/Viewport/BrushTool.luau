--!strict
--[[
	Viewport sculpt brush tool: handles mouse input, raycasting onto displacements, the 3D ring
	cursor, key hints, continuous per-frame strokes, and undo recordings. Each drag (mouse down
	to mouse up) commits as one undo step including autosew; stopping the tool auto-bakes edited
	tiles in a separate undo step.

	Viewport controls (Ctrl and Shift follow Studio's terrain editor):
		Left drag          paint with the selected brush
		Ctrl               invert (Raise <-> Lower)
		Ctrl + click       Raise To: sample height from the surface under the cursor
		Shift              smooth
		Ctrl + scroll      resize the brush (holds camera steady via Input)
		Alt + drag         resize the brush horizontally (right grows, left shrinks), like Hammer
		Alt + right click  pick paint axis from the face under the cursor, like Hammer
		[ and ]            shrink and grow the brush
		Esc                stop painting

	Stroke feel:
	- Aims against each tile's snapshot from when the stroke first touched it, then resolves onto
	  the live surface via Core/SurfaceRay so stationary raising builds a centered hill instead
	  of walking toward the camera and rays never slip through wedge seams.
	- Subsamples the full pointer path each frame for gap-free fast drags and applies an initial
	  dab on mouse-down so quick clicks register.
	- Paint, live sewing, and pinned part edges mutate vertex data first, updating wedges once
	  per frame.

	Centers on the exact surface point under the cursor (unlike Hammer's nearest-vertex snap) for
	smoother tracking in Studio.
]]

local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Core = Plugin.Core
local State = Plugin.State
local Scene = Plugin.Scene
local Actions = Plugin.Actions

local Sew = require(Core.Sew)
local Paint = require(Core.Paint)
local Stitch = require(Core.Stitch)
local SurfaceRay = require(Core.SurfaceRay)
local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Bake = require(Actions.Bake)
local Edges = require(Actions.Edges)

local Input = require(Viewport.Input)
local Cursor = require(Viewport.Cursor)
local KeyStrip = require(Viewport.KeyStrip)
local VisibleHit = require(Viewport.VisibleHit)
local RadiusPreview = require(Viewport.RadiusPreview)

type Opened = TerrainInstance.Opened
type Changes = { [Opened]: { [number]: true } }

type Hit = {
	position: Vector3,
	normal: Vector3,
	opened: Opened?,
}

local RAY_LENGTH = 10000
-- Cap per-frame delta so frame hitches never produce sudden terrain spikes.
local MAX_DT = 0.05
-- Initial dab duration applied immediately on mouse-down so quick clicks register.
local TAP_DT = 0.08
-- Skip back-facing tiles beyond this dot product so brushing one side of a thin wall never
-- pushes the far side, while 90-degree corners (dot 0) still paint together.
local BACK_FACE_DOT = -0.25
-- Path subsampling spacing: roughly one-quarter radius apart, capped at MAX_STEPS per frame.
local STEP_SHARE = 0.25
local MIN_STEP = 0.5
local MAX_STEPS = 16
-- Keep projecting onto the previous hit plane for a couple frames if a ray slips through a seam.
local SEAM_FRAMES = 2
-- Exponential smoothing speed for cursor ring orientation (higher is snappier).
local NORMAL_FOLLOW = 24

local SEPARATOR = KeyStrip.SEPARATOR

local MODE_COLORS: { [Paint.Effect]: Color3 } = {
	Raise = Color3.fromRGB(96, 200, 96),
	Lower = Color3.fromRGB(230, 96, 80),
	Smooth = Color3.fromRGB(80, 160, 255),
	RaiseTo = Color3.fromRGB(230, 190, 70),
}

-- The brush size label. The brush always reaches one grid step (Paint.effectiveRadius), so a
-- smaller Radius says how far it really reaches instead of leaving a larger ring unexplained.
local function sizeText(radius: number, effective: number): string
	if effective > radius + 1e-3 then
		return `Radius {Format.studs(radius)} st (reaches {Format.studs(effective)} at this Detail)`
	end

	return `Radius {Format.studs(radius)} st`
end

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
			`<b>Raise To ({Format.studs(settings.height)})</b>`,
			"Left Drag: Set height",
			"Ctrl + Click: Pick height",
			"Shift: Smooth",
		}
	end

	local size = if effective > settings.radius + 1e-3
		then `{Format.studs(settings.radius)}, grid min {Format.studs(math.round(effective * 10) / 10)}`
		else Format.studs(settings.radius)

	table.insert(parts, `Ctrl + Scroll: Size ({size})`)
	table.insert(parts, "Alt + Right Click: Axis")
	table.insert(parts, "Esc: Stop")
	return table.concat(parts, SEPARATOR)
end

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

-- Starts the sculpt brush tool and returns a cleanup callback.
return function (plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local connections: { RBXScriptConnection } = {}

	-- Stroke state.
	local recording: string? = nil
	local touched: { [Opened]: true } = {}
	-- Keep edges stitched: edges pinned when a stroke first enters their tile, tiles checked so
	-- far, and pins propagated to neighbor corners (rebuilt only when new pins are added).
	local pins: Stitch.Moves = {}
	local pinChecked: { [Opened]: true } = {}
	local propagated: Stitch.Moves = {}
	-- Snapshots captured when a stroke first reaches each tile.
	local snapshots: { [Opened]: SurfaceRay.Snapshot } = {}
	local snapshotList: { SurfaceRay.Snapshot } = {}
	local lastCenter: Vector3? = nil
	-- Clamps the next frame's dt after rebuilding wedges for a baked tile.
	local clampNext = false

	-- Hover and resize state.
	local lastHit: Hit? = nil
	local missFrames = 0
	local displayNormal: Vector3? = nil
	local resize: Input.DragResize? = nil
	-- Whether the current stroke reached points removed by the Mesh tool (see endStroke).
	local strokeReachedRemoved = false
	local wasPainting = false

	-- Depth-tested primary ring plus a faint always-on-top ghost ring so the cursor stays
	-- legible inside valleys while reading as a single circle.
	local ring = RadiusPreview.newRing("StrataBrushCursor", false, 0.2)
	local ghost = RadiusPreview.newRing("StrataBrushGhost", true, 0.78)
	local keyStrip = KeyStrip.new("StrataKeyHints")

	local function hideCursor()
		ring.Visible = false
		ghost.Visible = false
		RadiusPreview.label(nil)
	end

	-- Raycasts against stroke snapshots for reached tiles and live parts for unreached tiles,
	-- returning whichever hit is closer.
	local function findHit(models: { Model }, aim: Ray?): Hit?
		local ray = aim or mouse.UnitRay
		local direction = ray.Direction.Unit
		local filter: { Instance } = {}

		for _, model in models do
			-- Peek rather than get so hovering does not open every tile in the place.
			local opened = Session.peek(model)

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

		-- Bridge brief rays slipping through hairline seams by intersecting the previous hit plane.
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
			raiseToWorld = settings.raiseToWorld,
		}
	end

	local function applyBrush(models: { Model }, hit: Hit, mode: Paint.Effect, dt: number)
		local settings = Settings.get()
		local center = hit.position
		-- Compare against the hit tile's base face normal rather than the sculpted triangle normal
		-- so steep cliffs and overhangs never cull their own tile.
		local hitOpened = hit.opened
		local hitFace = if hitOpened
			then hitOpened.model:GetPivot():VectorToWorldSpace(Displacement.faceNormal(hitOpened.disp))
			else hit.normal
		local brush = brushFor(mode, settings)
		local effective = if hitOpened then Paint.effectiveRadius(hitOpened, brush) else settings.radius
		-- Margin covers the effective radius and Smooth's neighbor neighborhood across seams.
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

		-- Snapshot newly reached tiles for stable aiming and capture any stitched part-edge pins.
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

		-- Interpolate samples along the frame's drag path so fast drags stay continuous.
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

		local changed, reachedRemoved = Paint.apply(targets, centers, brush, dt)

		if reachedRemoved then
			strokeReachedRemoved = true
		end

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

		-- Sew touched edge vertices live each frame when autosew is enabled so 90-degree cliff
		-- edges do not visibly tear apart mid-drag (full autosew with pins runs on stroke end).
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

	-- Alt + Right Click: samples the clicked face's normal as the Picked axis (using the base
	-- face normal on displacements, matching Hammer). Clicking sky resets to Up (Y).
	local function pickAxis()
		-- Invisible parts (triggers, hitboxes) are looked through, like the other pick tools.
		local hit = VisibleHit.cast(mouse.UnitRay)
		local axis = Vector3.yAxis

		if hit then
			axis = hit.Normal

			local model = Query.displacementOf(hit.Instance)
			local opened = if model then Session.get(model) else nil

			if opened then
				axis = opened.model:GetPivot():VectorToWorldSpace(Displacement.faceNormal(opened.disp))
			end
		end

		Settings.update(function (s)
			s.axis = "Picked"
			s.pickedAxis = axis
		end)

		if hit then
			Status.post("success", string.format("Paint axis set to (%.2f, %.2f, %.2f).", axis.X, axis.Y, axis.Z))
		else
			Status.post("warning", "No face under the cursor. Picked axis reset to Up (Y).")
		end
	end

	-- Ctrl + Click in Raise To mode: samples the target height under the cursor.
	local function pickHeight()
		local settings = Settings.get()
		-- In World mode with a world axis, any visible part (such as a road or pad) can be sampled.
		local axis = if settings.raiseToWorld then Paint.worldAxisOf(brushFor("RaiseTo", settings)) else nil
		local partHit = if axis then VisibleHit.cast(mouse.UnitRay) else nil

		if axis and partHit then
			local height = math.round(partHit.Position:Dot(axis) * 10) / 10

			Settings.update(function (s)
				s.height = height
			end)

			Status.post("success", `Raise To height set to {Format.studs(height)} studs from {partHit.Instance.Name}.`)
			return
		end

		local hit = findHit(Query.workingModels())
		local opened = if hit then hit.opened else nil

		if not hit or not opened then
			Status.post("warning", "No terrain under the cursor to pick a height from.")
			return
		end

		local height = math.round(Paint.heightAt(opened, hit.position, brushFor("RaiseTo", settings)) * 10) / 10

		Settings.update(function (s)
			s.height = height
		end)

		Status.post("success", `Raise To height set to {Format.studs(height)} studs.`)
	end

	-- Forward declaration so beginStroke can clean up a stroke whose Button1Up was missed.
	local endStroke: () -> ()

	local function beginStroke()
		local settings = Settings.get()

		-- Close any prior stroke or resize whose mouse-up happened outside the viewport.
		if recording then
			endStroke()
		end

		resize = nil

		if not settings.painting then
			return
		end

		if Session.isBaking() then
			Status.post("warning", "Still baking the last edits. Try again in a moment.")
			return
		end

		-- Alt + Drag resizes the brush instead of painting.
		local drag = Input.beginDragResize(mouse, settings.radius)

		if drag then
			resize = drag
			return
		end

		if settings.mode == "RaiseTo" and Input.ctrl() and not Input.shift() then
			pickHeight()
			return
		end

		recording = ChangeHistoryService:TryBeginRecording("Strata paint")

		if not recording then
			Status.post("warning", "Studio is busy recording another change. Stroke skipped.")
			return
		end

		lastCenter = nil

		-- Apply an immediate dab on mouse-down so quick clicks always take effect.
		local models = Query.workingModels()
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

		local reachedRemoved = strokeReachedRemoved
		strokeReachedRemoved = false

		if #edited == 0 then
			-- Cancel untouched clicks so no empty undo entry is created.
			ChangeHistoryService:FinishRecording(current, Enum.FinishRecordingOperation.Cancel)

			-- Say why nothing moved instead of failing silently.
			if reachedRemoved then
				Status.post("warning", "No points to move here: this area was simplified. Restore points with the Mesh tool (Ctrl) to sculpt it.")
			end

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

	-- Viewport/Activation manages plugin:Activate and cursor icons across all tools.
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

			-- Defer auto-bake when switching directly to another editing tool (see Settings.editing).
			if state.autoBake and not Settings.editing(state) then
				task.spawn(Bake.bakeEdited)
			end
		end
	end

	table.insert(connections, mouse.Button1Down:Connect(beginStroke))
	table.insert(connections, mouse.Button1Up:Connect(endStroke))
	table.insert(
		connections,
		mouse.Button2Down:Connect(function ()
			if Settings.get().painting and not recording and Input.alt() then
				pickAxis()
			end
		end)
	)

	-- Ctrl + Scroll and [ / ] resize the brush; plain scroll stays free for Studio's camera.
	for _, connection in Input.connectResize(mouse, function ()
		return Settings.get().painting
	end, Settings.stepRadius) do
		table.insert(connections, connection)
	end

	local function effectiveAt(hit: Hit?, mode: Paint.Effect, settings: Settings.State): number
		local opened = if hit then hit.opened else nil

		return if opened then Paint.effectiveRadius(opened, brushFor(mode, settings)) else settings.radius
	end

	local function placeCursor(position: Vector3, normal: Vector3, settings: Settings.State, mode: Paint.Effect, radius: number)
		local up = if math.abs(normal.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
		local frame = CFrame.lookAt(position + normal * 0.05, position + normal * 2, up)
		-- Scale ring thickness with radius so it remains visible at every brush size.
		local width = math.max(0.15, radius * 0.04)
		local color = MODE_COLORS[mode]

		for _, adornment in { ring, ghost } do
			adornment.CFrame = frame
			adornment.Radius = radius
			adornment.InnerRadius = radius - width
			adornment.Color3 = color
			adornment.Visible = true
		end

		-- Dim slightly while dragging or when clamped up to grid minimum so terrain stays clear.
		local widened = radius > settings.radius + 1e-3
		ring.Transparency = if recording then 0.45 elseif widened then 0.38 else 0.2
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function (dt)
			local settings = Settings.get()

			if not settings.painting then
				return
			end

			local mode: Paint.Effect = effectiveMode(settings.mode)
			keyStrip.show(if settings.showKeyHints then keyHints(mode, settings, effectiveAt(lastHit, mode, settings)) else nil)

			local resizing = resize

			if resizing then
				Cursor.set("resize")

				local radius = Input.dragRadius(mouse, resizing)

				if radius ~= settings.radius then
					Settings.update(function (s)
						s.radius = radius
					end)
				end

				-- Anchor the preview ring where the resize drag began with a live size readout.
				local held = lastHit or findHit(Query.workingModels(), resizing.ray)

				if held then
					local current = Settings.get()
					placeCursor(held.position, displayNormal or held.normal, current, mode, effectiveAt(held, mode, current))
					RadiusPreview.label(held.position, sizeText(current.radius, effectiveAt(held, mode, current)))
				end

				return
			end

			local models = Query.workingModels()
			Cursor.set(if #models == 0 then "empty" else nil)

			-- Preview brush size in the viewport center right after adjusting the panel slider.
			if RadiusPreview.active() and not recording then
				local ray = RadiusPreview.ray()
				local previewHit = if ray then findHit(models, ray) else nil
				local text = `Radius {Format.studs(settings.radius)} st`

				if previewHit then
					local effective = effectiveAt(previewHit, mode, settings)
					placeCursor(previewHit.position, previewHit.normal, settings, mode, effective)
					RadiusPreview.label(previewHit.position, sizeText(settings.radius, effective))
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

			-- Smooth only the ring orientation (position stays exact) so it glides across facets.
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
					-- Avoid turning an unbake wedge-rebuild hitch into a single large sculpt jump.
					stepDt = math.min(stepDt, 1 / 60)
					clampNext = false
				end

				applyBrush(models, hit, mode, stepDt)
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
		ghost:Destroy()
		keyStrip.destroy()
	end
end
