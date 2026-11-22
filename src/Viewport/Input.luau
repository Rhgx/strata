--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Shared viewport input layer: tracks modifier keys across both the 3D viewport and the Strata
	panel, dispatches unified keyboard shortcuts, and suppresses Studio camera zoom during
	Ctrl + Scroll resizes.

	Modifiers: UserInputService reports keys only while the 3D viewport has focus. Clicking a
	panel control leaves focus on the panel even after moving the pointer back into 3D, which
	caused Ctrl to read as up and Ctrl + Scroll to zoom the camera. A non-Active transparent
	frame over the panel also tracks modifier state; a modifier counts as held when either source
	reports it. Panel state clears on key-up, window focus loss, or any viewport key event.

	Camera hold: Studio's native edit camera zooms on every wheel event with no plugin API to
	sink it. While any viewport tool runs, the camera CFrame and Focus are recorded each frame
	and restored briefly after Ctrl + Scroll (since native zoom can arrive before or after Lua
	and animate over several frames). Pressing a camera movement key or mouse button releases
	the hold immediately so intentional camera movement is never fought.

	Limitation: if focus is inside another Studio dock (Explorer, Properties, Output), no Lua
	API can read Ctrl, so the camera zooms until the viewport or panel is clicked; [ ] and panel
	sliders still work.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Plugin = script.Parent.Parent

local KeyCapture = require(Plugin.State.KeyCapture)

-- Active Alt + Drag resize state (matching Hammer's horizontal brush resize).
export type DragResize = {
	startX: number,
	startRadius: number,
	-- Initial mouse ray captured on press so the preview stays anchored where the drag started.
	ray: Ray,
}

-- Unified key press event fired from either the 3D viewport or the Strata panel.
export type Key = { KeyCode: Enum.KeyCode }

-- Duration to hold the camera steady after Ctrl + Scroll.
local HOLD_SECONDS = 0.2
-- Horizontal drag resize rate: radius doubles roughly every 70 pixels dragged right.
local RESIZE_RATE = 0.01
-- Deduplication window when the same key event arrives from both panel and viewport sources.
local KEY_REPEAT = 0.05
-- Grace window after a panel TextBox loses focus so its committing Enter is not treated as a shortcut.
local TYPING_GRACE = 0.15

local CAMERA_KEYS: { [Enum.KeyCode]: true } = {
	[Enum.KeyCode.W] = true,
	[Enum.KeyCode.A] = true,
	[Enum.KeyCode.S] = true,
	[Enum.KeyCode.D] = true,
	[Enum.KeyCode.Q] = true,
	[Enum.KeyCode.E] = true,
	[Enum.KeyCode.F] = true,
}

local MODIFIERS: { [Enum.KeyCode]: true } = {
	[Enum.KeyCode.LeftControl] = true,
	[Enum.KeyCode.RightControl] = true,
	[Enum.KeyCode.LeftShift] = true,
	[Enum.KeyCode.RightShift] = true,
	[Enum.KeyCode.LeftAlt] = true,
	[Enum.KeyCode.RightAlt] = true,
}

local Input = {}

-- Modifier keys currently observed as pressed by the panel overlay.
local panelKeys: { [Enum.KeyCode]: true } = {}
local tracking: () -> boolean = function ()
	return false
end
local savedCFrame: CFrame? = nil
local savedFocus: CFrame? = nil
local holdUntil = 0
local restoring = false

local keyEvent = Instance.new("BindableEvent")
local lastKey: Enum.KeyCode? = nil
local lastKeyAt = 0

local function isDown(a: Enum.KeyCode, b: Enum.KeyCode): boolean
	return UserInputService:IsKeyDown(a)
		or UserInputService:IsKeyDown(b)
		or panelKeys[a] == true
		or panelKeys[b] == true
end

function Input.ctrl(): boolean
	return isDown(Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl)
end

function Input.shift(): boolean
	return isDown(Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)
end

function Input.alt(): boolean
	return isDown(Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt)
end

local function release()
	holdUntil = 0
end

-- Locks the camera to its pre-input transform for HOLD_SECONDS.
function Input.holdCamera()
	if savedCFrame then
		holdUntil = os.clock() + HOLD_SECONDS
	end
end

local function restore()
	local camera = workspace.CurrentCamera
	local cframe, focus = savedCFrame, savedFocus

	if restoring or not camera or not cframe or not focus or os.clock() > holdUntil then
		return
	end

	restoring = true

	if camera.CFrame ~= cframe then
		camera.CFrame = cframe
	end

	if camera.Focus ~= focus then
		camera.Focus = focus
	end

	restoring = false
end

-- Begins an Alt + Drag resize from `mouse`, or returns nil if Alt is not held.
function Input.beginDragResize(mouse: PluginMouse, radius: number): DragResize?
	if not Input.alt() then
		return nil
	end

	return { startX = mouse.X, startRadius = radius, ray = mouse.UnitRay }
end

-- Computes the resized radius (snapped to half studs) for an active Alt + Drag resize and holds
-- the camera steady so Alt + Drag does not orbit Studio's camera. Call every frame during drag.
function Input.dragRadius(mouse: PluginMouse, drag: DragResize): number
	Input.holdCamera()
	-- Exponential scaling keeps both small and large brushes comfortable to adjust.
	local radius = drag.startRadius * math.exp((mouse.X - drag.startX) * RESIZE_RATE)

	return math.round(radius * 2) / 2
end

-- Connects Ctrl + Scroll (holding the camera steady) and [ / ] to `onStep(-1 | 1)` while
-- `active()` is true. Scrolling down (toward the user) grows and scrolling up shrinks.
function Input.connectResize(mouse: PluginMouse, active: () -> boolean, onStep: (number) -> ()): { RBXScriptConnection }
	local function onWheel(direction: number)
		if active() and Input.ctrl() then
			Input.holdCamera()
			restore()
			onStep(direction)
		end
	end

	return {
		mouse.WheelForward:Connect(function ()
			onWheel(-1)
		end),

		mouse.WheelBackward:Connect(function ()
			onWheel(1)
		end),

		Input.onKey(function (input: Key)
			if not active() or UserInputService:GetFocusedTextBox() then
				return
			end

			if input.KeyCode == Enum.KeyCode.LeftBracket then
				onStep(-1)
			elseif input.KeyCode == Enum.KeyCode.RightBracket then
				onStep(1)
			end
		end),
	}
end

local function fireKey(keyCode: Enum.KeyCode)
	local now = os.clock()

	if keyCode == lastKey and now - lastKeyAt < KEY_REPEAT then
		return
	end

	lastKey, lastKeyAt = keyCode, now

	local key: Key = { KeyCode = keyCode }
	keyEvent:Fire(key)
end

-- Subscribes to key presses from both the 3D viewport and the Strata panel (working around
-- UserInputService missing keys when the panel owns focus). Skips keys typed into panel text
-- fields; callers should still check GetFocusedTextBox for other Studio windows.
function Input.onKey(handler: (Key) -> ()): RBXScriptConnection
	return keyEvent.Event:Connect(handler)
end

-- Starts shared input listeners on `widget` and camera tracking while `isToolRunning()` is true.
-- Returns a cleanup callback.
function Input.start(widget: DockWidgetPluginGui, isToolRunning: () -> boolean): () -> ()
	tracking = isToolRunning

	local typingIn: TextBox? = nil
	local typingEndedAt = 0

	local function watchTextBox(inst: Instance)
		if inst:IsA("TextBox") then
			inst.Focused:Connect(function ()
				typingIn = inst
			end)

			inst.FocusLost:Connect(function ()
				if typingIn == inst then
					typingIn = nil
				end

				typingEndedAt = os.clock()
			end)
		end
	end

	for _, inst in widget:GetDescendants() do
		watchTextBox(inst)
	end

	local listener = Instance.new("Frame")
	listener.Name = "StrataKeyListener"
	listener.BackgroundTransparency = 1
	listener.Size = UDim2.fromScale(1, 1)
	listener.Active = false
	listener.ZIndex = 0
	listener.Parent = widget

	local connections = {
		listener.InputBegan:Connect(function (input: InputObject)
			if MODIFIERS[input.KeyCode] then
				panelKeys[input.KeyCode] = true
			elseif
				input.UserInputType == Enum.UserInputType.Keyboard
				and not typingIn
				and os.clock() - typingEndedAt > TYPING_GRACE
				-- Yield keys to keyboard-captured controls (such as an open Dropdown).
				and not KeyCapture.active()
			then
				fireKey(input.KeyCode)
			end
		end),

		widget.DescendantAdded:Connect(watchTextBox),

		listener.InputEnded:Connect(function (input: InputObject)
			panelKeys[input.KeyCode] = nil
		end),

		widget.WindowFocusReleased:Connect(function ()
			table.clear(panelKeys)
			typingIn = nil
		end),

		-- Any viewport keyboard event confirms focus returned to 3D, where IsKeyDown is authoritative.
		UserInputService.InputBegan:Connect(function (input: InputObject)
			if input.UserInputType == Enum.UserInputType.Keyboard then
				table.clear(panelKeys)

				if CAMERA_KEYS[input.KeyCode] then
					release()
				end

				-- Check focused text boxes immediately before deferred listeners run, because
				-- Enter or Esc may end text editing before downstream callbacks execute.
				if not UserInputService:GetFocusedTextBox() and not typingIn then
					fireKey(input.KeyCode)
				end
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.UserInputType == Enum.UserInputType.MouseButton3 then
				release()
			end
		end),

		UserInputService.InputEnded:Connect(function (input: InputObject)
			if input.UserInputType == Enum.UserInputType.Keyboard then
				table.clear(panelKeys)
			end
		end),

		RunService.Heartbeat:Connect(function ()
			local camera = workspace.CurrentCamera

			if not camera then
				return
			end

			if os.clock() <= holdUntil then
				restore()
			elseif tracking() then
				savedCFrame, savedFocus = camera.CFrame, camera.Focus
			else
				savedCFrame, savedFocus = nil, nil
			end
		end),
	}

	-- Restore immediately if native wheel zoom mutates Camera.CFrame between Heartbeat steps.
	local cameraConnection: RBXScriptConnection? = nil

	local function watchCamera()
		if cameraConnection then
			cameraConnection:Disconnect()
		end

		local camera = workspace.CurrentCamera
		cameraConnection = if camera
			then camera:GetPropertyChangedSignal("CFrame"):Connect(function ()
				if os.clock() <= holdUntil then
					restore()
				end
			end)
			else nil
	end

	watchCamera()
	table.insert(connections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera))

	return function ()
		for _, connection in connections do
			connection:Disconnect()
		end

		if cameraConnection then
			cameraConnection:Disconnect()
		end

		listener:Destroy()
		table.clear(panelKeys)

		tracking = function ()
			return false
		end
	end
end

return Input
