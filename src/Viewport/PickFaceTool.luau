--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Pick faces viewport tool: click part faces in 3D to collect them, then Create converts all
	picked faces in one undo step and bake (like Hammer's Face Edit selection). Clicking a picked
	face again unpicks it. Enter triggers creation from the viewport; first Esc clears picks and
	second Esc stops the tool (see Activation). Exiting the tool clears all picks.

	Uses thin BoxHandleAdornments instead of SurfaceSelection because SurfaceSelection only
	supports the 6 box normals and floats off wedge slopes.
]]

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Core = Plugin.Core

local PartFaces = require(Core.PartFaces)
local TerrainInstance = require(Core.TerrainInstance)

local Settings = require(Plugin.State.Settings)

local Create = require(Plugin.Actions.Create)

local Input = require(Viewport.Input)
local Cursor = require(Viewport.Cursor)
local KeyStrip = require(Viewport.KeyStrip)
local VisibleHit = require(Viewport.VisibleHit)

export type Pick = {
	part: BasePart,
	face: PartFaces.FaceId,
}

type Listener = () -> ()

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

-- Returns all currently picked faces whose owning parts are still parented.
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

	return function ()
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
	-- Terrain sits at the world origin so CFrame is world space; offset slightly to avoid z-fighting.
	box.CFrame = face.pivot * CFrame.new(0, HIGHLIGHT_THICKNESS / 2, 0)
	box.Size = Vector3.new(face.width, HIGHLIGHT_THICKNESS, face.depth)
	box.Visible = true
end

-- Starts the Pick faces tool and returns a cleanup callback.
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

	-- Finds the eligible quad face under the pointer, ignoring invisible parts, Terrain, and
	-- existing displacements.
	local function faceUnderMouse(): (BasePart?, PartFaces.Face?)
		local exclude: { Instance } = { workspace.Terrain }

		for _, model in CollectionService:GetTagged(TerrainInstance.TAG) do
			table.insert(exclude, model)
		end

		local hit = VisibleHit.cast(mouse.UnitRay, exclude)

		if not hit or not PartFaces.isEligible(hit.Instance) then
			return nil, nil
		end

		-- Wedge triangular sides match no quad face and return nil here.
		return hit.Instance, PartFaces.faceAt(hit.Instance, hit.Normal)
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function ()
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
				Cursor.set("valid")
			else
				hover.Visible = false
				hovered = nil
				Cursor.set("invalid")
			end
		end)
	)

	table.insert(
		connections,
		mouse.Button1Down:Connect(function ()
			local current = hovered

			if Settings.get().picking and current then
				toggle(current.part, current.face)
			end
		end)
	)

	table.insert(
		connections,
		Input.onKey(function (input: Input.Key)
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
	local unsubscribeSettings = Settings.subscribe(function (state)
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

	return function ()
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
