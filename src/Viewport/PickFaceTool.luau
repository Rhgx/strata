--!strict
--[[
	Pick faces mode: click faces of parts in the viewport to collect them, then Create converts
	all of them at once (one undo step, one bake), like selecting faces in Hammer's Face Edit
	before pressing Create. Clicking a picked face again removes it. Enter creates from the 3D
	view; the first Esc clears the picks and the next one stops the tool (see Activation).
	Leaving the mode (the Pick faces button, Esc, another Strata or Studio tool) clears the picks.

	Highlights are thin boxes rather than SurfaceSelection, which only knows the six box faces
	and would float off a wedge's slope.
]]

local CollectionService = game:GetService("CollectionService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PartFaces = require(script.Parent.Parent.Core.PartFaces)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Settings = require(script.Parent.Parent.State.Settings)
local Create = require(script.Parent.Parent.Actions.Create)
local KeyStrip = require(script.Parent.KeyStrip)

export type Pick = {
	part: BasePart,
	face: PartFaces.FaceId,
}

type Listener = () -> ()

local RAY_LENGTH = 10000
-- Invisible parts (triggers, hitboxes) are looked through, up to this many.
local MAX_SKIPS = 8
local HIGHLIGHT_THICKNESS = 0.06
local HOVER_COLOR = Color3.fromRGB(80, 160, 255)
local PICKED_COLOR = Color3.fromRGB(255, 196, 64)

local picks: { Pick } = {}
local listeners: { [Listener]: true } = {}

local PickFaceTool = {}

local function notify()
	for listener in listeners do
		listener()
	end
end

-- The faces picked so far (whose parts still exist).
function PickFaceTool.picks(): { Pick }
	local result = {}
	for _, pick in picks do
		if pick.part.Parent then
			table.insert(result, pick)
		end
	end
	return result
end

function PickFaceTool.clear()
	if #picks > 0 then
		table.clear(picks)
		notify()
	end
end

function PickFaceTool.subscribe(listener: Listener): () -> ()
	listeners[listener] = true
	return function()
		listeners[listener] = nil
	end
end

local function toggle(part: BasePart, face: PartFaces.FaceId)
	for i, pick in picks do
		if pick.part == part and pick.face == face then
			table.remove(picks, i)
			notify()
			return
		end
	end
	table.insert(picks, { part = part, face = face })
	notify()
end

local function newHighlight(color: Color3): BoxHandleAdornment
	local box = Instance.new("BoxHandleAdornment")
	box.Name = "StrataFaceHighlight"
	box.Adornee = workspace.Terrain
	box.Color3 = color
	box.Transparency = 0.45
	box.ZIndex = 1
	box.Visible = false
	box.Parent = CoreGui
	return box
end

local function place(box: BoxHandleAdornment, face: PartFaces.Face)
	-- The Terrain adornee sits at the origin, so this CFrame is world space. Lifted slightly so
	-- the highlight does not z-fight with the face.
	box.CFrame = face.pivot * CFrame.new(0, HIGHLIGHT_THICKNESS / 2, 0)
	box.Size = Vector3.new(face.width, HIGHLIGHT_THICKNESS, face.depth)
	box.Visible = true
end

-- Starts the tool; returns a function that stops it.
function PickFaceTool.start(plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local hover = newHighlight(HOVER_COLOR)
	local pickedBoxes: { BoxHandleAdornment } = {}
	local hovered: Pick? = nil
	local connections: { RBXScriptConnection } = {}
	local keyStrip = KeyStrip.new("StrataPickHints")
	local lastHints: string? = nil

	local function refreshPicked()
		for _, box in pickedBoxes do
			box:Destroy()
		end
		table.clear(pickedBoxes)
		if not Settings.get().picking then
			return
		end
		for _, pick in PickFaceTool.picks() do
			local face = PartFaces.find(pick.part, pick.face)
			if face then
				local box = newHighlight(PICKED_COLOR)
				place(box, face)
				table.insert(pickedBoxes, box)
			end
		end
	end

	-- The quad face under the mouse, looking through invisible parts. Existing displacements
	-- (their wedges and unions) and Terrain are ignored.
	local function faceUnderMouse(): (BasePart?, PartFaces.Face?)
		local exclude: { Instance } = { workspace.Terrain }
		for _, model in CollectionService:GetTagged(TerrainInstance.TAG) do
			table.insert(exclude, model)
		end
		local ray = mouse.UnitRay
		for _ = 1, MAX_SKIPS do
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = exclude
			local hit = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
			if not hit then
				return nil, nil
			end
			local part = hit.Instance
			if part.Transparency >= 0.99 then
				table.insert(exclude, part)
				continue
			end
			if not PartFaces.isEligible(part) then
				return nil, nil
			end
			-- A wedge's triangular sides match no quad face and are rejected here.
			return part, PartFaces.faceAt(part, hit.Normal)
		end
		return nil, nil
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function()
			local settings = Settings.get()
			if not settings.picking then
				hover.Visible = false
				hovered = nil
				return
			end
			local count = #PickFaceTool.picks()
			local hints = if settings.showKeyHints
				then table.concat({
					"<b>Pick faces</b>",
					"Click: Pick or unpick a face",
					if count > 0 then `Enter: Create ({count})` else "Enter: Create",
					if count > 0 then "Esc: Clear picks" else "Esc: Stop",
				}, KeyStrip.SEPARATOR)
				else nil
			if hints ~= lastHints then
				lastHints = hints
				keyStrip.show(hints)
			end
			local part, face = faceUnderMouse()
			if part and face then
				place(hover, face)
				hovered = { part = part, face = face.id }
			else
				hover.Visible = false
				hovered = nil
			end
		end)
	)

	table.insert(
		connections,
		mouse.Button1Down:Connect(function()
			local current = hovered
			if Settings.get().picking and current then
				toggle(current.part, current.face)
			end
		end)
	)

	-- Enter creates terrain from the picks, like the panel's Create button.
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input)
			if not Settings.get().picking or UserInputService:GetFocusedTextBox() then
				return
			end
			if input.KeyCode ~= Enum.KeyCode.Return and input.KeyCode ~= Enum.KeyCode.KeypadEnter then
				return
			end
			local settings = Settings.get()
			task.spawn(Create.createPicked, settings.power, settings.tileSize, PickFaceTool.picks(), Settings.stopViewportTool)
		end)
	)

	local wasPicking = false
	local unsubscribeSettings = Settings.subscribe(function(state)
		if state.picking ~= wasPicking then
			wasPicking = state.picking
			if not state.picking then
				PickFaceTool.clear()
				keyStrip.show(nil)
				lastHints = nil
			end
			refreshPicked()
		end
	end)
	local unsubscribePicks = PickFaceTool.subscribe(refreshPicked)

	return function()
		unsubscribeSettings()
		unsubscribePicks()
		for _, connection in connections do
			connection:Disconnect()
		end
		hover:Destroy()
		keyStrip.destroy()
		for _, box in pickedBoxes do
			box:Destroy()
		end
		PickFaceTool.clear()
	end
end

return PickFaceTool
