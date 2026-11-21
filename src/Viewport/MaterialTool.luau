--!strict
--[[
	The Material tool: paints a look (material, color and material variant) into tiles, for a road
	through grass or a rock patch on a slope. One stroke (mouse down to mouse up) is one undo step;
	when the tool stops, everything painted is baked as its own undo step.

	Viewport controls:
		Left drag          paint the look
		Ctrl               erase (back to each tile's own look)
		Alt + right click  pick up the look of any part or tile under the cursor
		Ctrl + scroll      resize the brush ([ and ] too, on layouts that have them)
		Esc                stop

	What gets painted: the triangle under the cursor, plus every triangle whose center is inside
	the brush. By default whole grid cells (both triangles of a quad) are painted together, so
	edges come out as clean steps instead of a sawtooth; Fine paints single triangles. Nothing
	moves, so unlike the sculpt brushes there is no strength, falloff or sewing.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Displacement = require(script.Parent.Parent.Core.Displacement)
local SurfaceRay = require(script.Parent.Parent.Core.SurfaceRay)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Settings = require(script.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.State.Status)
local Session = require(script.Parent.Parent.Scene.Session)
local Query = require(script.Parent.Parent.Scene.Query)
local Bake = require(script.Parent.Parent.Actions.Bake)
local KeyStrip = require(script.Parent.KeyStrip)

type Opened = TerrainInstance.Opened

type Hit = {
	position: Vector3,
	normal: Vector3,
	opened: Opened,
	-- The triangle under the cursor, when the exact triangle could be found.
	triangle: number?,
}

local RAY_LENGTH = 10000
-- Tiles facing away from the hit surface by more than this are skipped (see BrushTool).
local BACK_FACE_DOT = -0.25
-- Brush samples along a frame's path: about half a radius apart, at most this many.
local STEP_SHARE = 0.5
local MIN_STEP = 0.5
local MAX_STEPS = 16
-- Invisible parts are looked through when picking a look, up to this many.
local MAX_SKIPS = 8
-- Each look bakes into its own union, so past this many looks on one tile the user is told.
local LOOK_WARNING = 4
local ERASE_COLOR = Color3.fromRGB(230, 96, 80)
local SEPARATOR = KeyStrip.SEPARATOR

local function formatStuds(value: number): string
	return if value == math.floor(value) then tostring(value) else string.format("%.1f", value)
end

local function isDown(a: Enum.KeyCode, b: Enum.KeyCode): boolean
	return UserInputService:IsKeyDown(a) or UserInputService:IsKeyDown(b)
end

local function erasing(): boolean
	return isDown(Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl)
end

local function describe(look: Displacement.Look): string
	local name = (look.material.Name:gsub("(%l)(%u)", "%1 %2"))
	if look.variant ~= "" then
		name = `{name} ({look.variant})`
	end
	return `{name}, #{look.color:ToHex():upper()}`
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

-- Starts the tool and returns a function that stops it.
return function(plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local connections: { RBXScriptConnection } = {}

	-- Per stroke.
	local recording: string? = nil
	local touched: { [Opened]: true } = {}
	-- Triangle centers (world) per tile, computed once per stroke: nothing moves while painting.
	local centers: { [Opened]: { Vector3 } } = {}
	local warned: { [Opened]: true } = {}
	local lastCenter: Vector3? = nil
	local wasColoring = false

	local ring = newRing("StrataMaterialCursor", false, 0.2)
	local ghost = newRing("StrataMaterialGhost", true, 0.78)
	local keyStrip = KeyStrip.new("StrataMaterialHints")

	local function hideCursor()
		ring.Visible = false
		ghost.Visible = false
	end

	local function workingModels(): { Model }
		if Settings.get().paintSelectedOnly then
			return Query.selectedModels()
		end
		return Session.models()
	end

	-- The tile surface under the mouse, with the exact triangle when it can be found.
	local function findHit(models: { Model }): Hit?
		if #models == 0 then
			return nil
		end
		local ray = mouse.UnitRay
		local direction = ray.Direction.Unit
		local filter: { Instance } = table.create(#models)
		for i, model in models do
			filter[i] = model
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = filter
		local live = workspace:Raycast(ray.Origin, direction * RAY_LENGTH, params)
		if not live then
			return nil
		end
		local model = Query.displacementOf(live.Instance)
		local opened = if model then Session.get(model) else nil
		if not opened then
			return nil
		end
		-- The wedges and unions follow the data exactly, so the data tells which triangle it is.
		local exact = SurfaceRay.cast(ray.Origin, direction, RAY_LENGTH, { SurfaceRay.snapshot(opened) })
		if exact then
			return {
				position = ray.Origin + direction * exact.distance,
				normal = exact.normal,
				opened = opened,
				triangle = exact.triangle,
			}
		end
		return { position = live.Position, normal = live.Normal, opened = opened, triangle = nil }
	end

	local function centersOf(opened: Opened): { Vector3 }
		local cached = centers[opened]
		if cached then
			return cached
		end
		local disp = opened.disp
		local pivot = opened.model:GetPivot()
		local positions = Displacement.positions(disp)
		local result = table.create(Displacement.triangleCount(disp))
		for t = 1, Displacement.triangleCount(disp) do
			local i1, i2, i3 = Displacement.triangle(disp, t)
			result[t] = pivot * ((positions[i1] + positions[i2] + positions[i3]) / 3)
		end
		centers[opened] = result
		return result
	end

	local function paintAt(models: { Model }, hit: Hit)
		local settings = Settings.get()
		local radius = settings.radius
		local erase = erasing()
		local look: Displacement.Look = { material = settings.paintMaterial, color = settings.paintColor, variant = settings.paintVariant }

		-- Samples along the path since the last frame, so fast drags leave no gaps.
		local samples = { hit.position }
		local previous = lastCenter
		if previous then
			local distance = (hit.position - previous).Magnitude
			local steps = math.clamp(math.ceil(distance / math.max(radius * STEP_SHARE, MIN_STEP)), 1, MAX_STEPS)
			if steps > 1 then
				samples = table.create(steps)
				for k = 1, steps do
					samples[k] = previous:Lerp(hit.position, k / steps)
				end
			end
		end
		local travel = if previous then (hit.position - previous).Magnitude else 0
		lastCenter = hit.position

		local hitFace = hit.opened.model:GetPivot():VectorToWorldSpace(Displacement.faceNormal(hit.opened.disp))
		for _, opened in Session.getAll(models) do
			local pivot = opened.model:GetPivot()
			if opened ~= hit.opened then
				local faceNormal = pivot:VectorToWorldSpace(Displacement.faceNormal(opened.disp))
				local nearest = pivot:PointToObjectSpace(hit.position)
				local gap = (nearest - nearest:Max(opened.boundsMin):Min(opened.boundsMax)).Magnitude
				if faceNormal:Dot(hitFace) < BACK_FACE_DOT or gap > radius + travel then
					continue
				end
			end

			local disp = opened.disp
			local tileCenters = centersOf(opened)
			local function inside(t: number): boolean
				if opened == hit.opened and t == hit.triangle then
					return true
				end
				local center = tileCenters[t]
				for _, sample in samples do
					if (center - sample).Magnitude <= radius then
						return true
					end
				end
				return false
			end

			local index: number? = 0
			if not erase then
				index = Displacement.lookIndex(disp, look)
				if not index then
					if not warned[opened] then
						warned[opened] = true
						Status.post("warning", `{opened.model.Name} already has {Displacement.MAX_LOOKS} painted looks.`)
					end
					continue
				end
			end
			local target = index :: number

			local changed: { number } = {}
			for q = 0, Displacement.triangleCount(disp) // 2 - 1 do
				local a, b = q * 2 + 1, q * 2 + 2
				local inA, inB = inside(a), inside(b)
				if not settings.paintFine and (inA or inB) then
					inA, inB = true, true
				end
				if inA and disp.triLooks[a] ~= target then
					disp.triLooks[a] = target
					table.insert(changed, a)
				end
				if inB and disp.triLooks[b] ~= target then
					disp.triLooks[b] = target
					table.insert(changed, b)
				end
			end
			if #changed > 0 then
				Session.updateLooks(opened, changed)
				touched[opened] = true
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
		local exclude: { Instance } = { workspace.Terrain }
		local ray = mouse.UnitRay
		for _ = 1, MAX_SKIPS do
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = exclude
			local hit = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
			if not hit then
				return nil
			end
			if hit.Instance.Transparency >= 0.99 then
				table.insert(exclude, hit.Instance)
				continue
			end
			return hit.Instance
		end
		return nil
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
			end
		end)
		if part then
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
		if recording then
			endStroke()
		end
		if not settings.coloring or Session.isBaking() then
			return
		end
		if settings.pickingLook then
			pickLook()
			return
		end
		recording = ChangeHistoryService:TryBeginRecording("Strata paint material")
		if not recording then
			Status.post("warning", "Studio is busy recording another change. Stroke skipped.")
			return
		end
		lastCenter = nil
		local models = workingModels()
		local hit = findHit(models)
		if hit then
			paintAt(models, hit)
		end
	end

	function endStroke()
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
		table.clear(centers)
		table.clear(warned)
		lastCenter = nil
		ChangeHistoryService:FinishRecording(
			current,
			if edited > 0 then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end

	local function onSettingsChanged(state: Settings.State)
		if state.coloring == wasColoring then
			return
		end
		wasColoring = state.coloring
		if not state.coloring then
			endStroke()
			hideCursor()
			keyStrip.show(nil)
			if state.autoBake then
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
			if Settings.get().coloring and not recording and isDown(Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt) then
				pickLook()
			end
		end)
	)
	local function onWheel(direction: number)
		if Settings.get().coloring and erasing() then
			Settings.stepRadius(direction)
		end
	end
	table.insert(connections, mouse.WheelForward:Connect(function()
		onWheel(1)
	end))
	table.insert(connections, mouse.WheelBackward:Connect(function()
		onWheel(-1)
	end))
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input)
			if not Settings.get().coloring or UserInputService:GetFocusedTextBox() then
				return
			end
			if input.KeyCode == Enum.KeyCode.LeftBracket then
				Settings.stepRadius(-1)
			elseif input.KeyCode == Enum.KeyCode.RightBracket then
				Settings.stepRadius(1)
			end
		end)
	)

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function()
			local settings = Settings.get()
			if not settings.coloring then
				return
			end
			local erase = erasing()
			local hints: { string }
			if settings.pickingLook then
				hints = { "<b>Pick a look</b>", "Click any part or tile", "Esc: Stop" }
			else
				hints = {
					`<b>Material</b> ({describe({ material = settings.paintMaterial, color = settings.paintColor, variant = settings.paintVariant })})`,
					if erase then "Left Drag: Erase" else "Left Drag: Paint",
					"Ctrl: Erase",
					"Alt + Right Click: Pick look",
					`Ctrl + Scroll: Size ({formatStuds(settings.radius)})`,
					"Esc: Stop",
				}
			end
			keyStrip.show(if settings.showKeyHints then table.concat(hints, SEPARATOR) else nil)

			if settings.pickingLook then
				hideCursor()
				return
			end
			local models = workingModels()
			local hit = findHit(models)
			if not hit then
				hideCursor()
				return
			end
			local normal = hit.normal
			local up = if math.abs(normal.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
			local frame = CFrame.lookAt(hit.position + normal * 0.05, hit.position + normal * 2, up)
			local width = math.max(0.15, settings.radius * 0.04)
			for _, adornment in { ring, ghost } do
				adornment.CFrame = frame
				adornment.Radius = settings.radius
				adornment.InnerRadius = settings.radius - width
				adornment.Color3 = if erase then ERASE_COLOR else settings.paintColor
				adornment.Visible = true
			end
			ring.Transparency = if recording then 0.45 else 0.2

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
		ghost:Destroy()
		keyStrip.destroy()
	end
end
