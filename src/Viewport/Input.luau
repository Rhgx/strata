--!strict
--[[
	Shared viewport input for the tools: modifier keys that work wherever keyboard focus is, and
	Ctrl + Scroll that resizes without Studio also zooming the camera.

	Modifiers. UserInputService only sees keys while the 3D view has focus. After a click in the
	Strata panel, focus stays on the panel while the mouse is back over the 3D view, so Ctrl reads
	as up and Ctrl + Scroll fell through to Studio's camera. A transparent frame over the panel
	(not Active, so clicks still reach the controls) also records modifier keys, and a key counts
	as down when either source says so. The panel's record clears when the key comes up, when the
	panel loses focus, and on any key the 3D view reports.

	Camera. Studio's edit camera is native and zooms on every scroll, Ctrl or not, and no plugin
	API can sink that. So the camera position is remembered every frame while a tool runs, and
	after a Ctrl + Scroll it is held there for a moment (the zoom can land before or after the
	scroll reaches Lua, and may animate over several frames). Pressing a mouse button or a camera
	key lets go at once, so moving the camera on purpose is never fought.

	Limits: when focus is in another Studio window (Explorer, Properties, Output), no Lua API can
	read Ctrl at all, so the camera zooms until the 3D view or the panel is clicked. `[` and `]`
	and the panel slider still resize.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local KeyCapture = require(script.Parent.Parent.State.KeyCapture)

local Input = {}

-- How long the camera is held after a Ctrl + Scroll.
local HOLD_SECONDS = 0.2
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

-- Modifier keys the panel saw go down.
local panelKeys: { [Enum.KeyCode]: true } = {}

-- Whether a tool wants the camera remembered; set by `track`.
local tracking: () -> boolean = function()
	return false
end
local savedCFrame: CFrame? = nil
local savedFocus: CFrame? = nil
local holdUntil = 0
local restoring = false

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

-- Holds the camera where it was before this frame's input, for a moment.
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

-- Alt + drag resize speed: the radius doubles for about every 70 pixels dragged right.
local RESIZE_RATE = 0.01

-- An Alt + drag resize in progress (the brush tools resize like Hammer).
export type DragResize = {
	startX: number,
	startRadius: number,
	-- The mouse ray when the drag started, so the cursor stays where the drag began.
	ray: Ray,
}

-- Starts an Alt + drag resize from the mouse, or nil when Alt is not held.
function Input.beginDragResize(mouse: PluginMouse, radius: number): DragResize?
	if not Input.alt() then
		return nil
	end
	return { startX = mouse.X, startRadius = radius, ray = mouse.UnitRay }
end

-- The radius for the mouse's position in a drag (right grows, left shrinks), in half studs.
-- Holds the camera still, since Alt + drag is also Studio's orbit. Call every frame of the drag.
function Input.dragRadius(mouse: PluginMouse, drag: DragResize): number
	Input.holdCamera()
	-- Exponential so small and large brushes resize at a comfortable speed.
	local radius = drag.startRadius * math.exp((mouse.X - drag.startX) * RESIZE_RATE)
	return math.round(radius * 2) / 2
end

--[[
	Calls `onStep(1)` or `onStep(-1)` while `active()` says so, on Ctrl + Scroll over the 3D view
	(holding the camera still for it) and on `]` and `[`. Returns the connections. Scrolling down
	(toward you) grows and scrolling up shrinks, which reads as pulling the brush out and pushing
	it in.
]]
function Input.connectResize(mouse: PluginMouse, active: () -> boolean, onStep: (number) -> ()): { RBXScriptConnection }
	local function onWheel(direction: number)
		if active() and Input.ctrl() then
			Input.holdCamera()
			restore()
			onStep(direction)
		end
	end
	return {
		mouse.WheelForward:Connect(function()
			onWheel(-1)
		end),
		mouse.WheelBackward:Connect(function()
			onWheel(1)
		end),
		Input.onKey(function(input: Key)
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

-- A key press, from the 3D view or the panel (see Input.onKey).
export type Key = { KeyCode: Enum.KeyCode }

local keyEvent = Instance.new("BindableEvent")
-- The same press can reach both sources; a repeat within this many seconds is dropped.
local KEY_REPEAT = 0.05
-- Keys right after a panel text field loses focus belong to that field (Enter commits it).
local TYPING_GRACE = 0.15
local lastKey: Enum.KeyCode? = nil
local lastKeyAt = 0

local function fireKey(keyCode: Enum.KeyCode)
	local now = os.clock()
	if keyCode == lastKey and now - lastKeyAt < KEY_REPEAT then
		return
	end
	lastKey, lastKeyAt = keyCode, now
	local key: Key = { KeyCode = keyCode }
	keyEvent:Fire(key)
end

--[[
	Calls `handler` on every key press while Studio's 3D view or the Strata panel has keyboard
	focus. UserInputService alone misses keys while the panel has focus (after clicking any panel
	button), which made Esc, Enter, X and [ ] seem to do nothing. Keys typed into a panel text
	field are left to it. Handlers still check `GetFocusedTextBox` for other Studio fields.
]]
function Input.onKey(handler: (Key) -> ()): RBXScriptConnection
	return keyEvent.Event:Connect(handler)
end

--[[
	Starts the shared input state. `isToolRunning` says whether any viewport tool is on (the
	camera is only remembered then). Returns a function that stops.
]]
function Input.start(widget: DockWidgetPluginGui, isToolRunning: () -> boolean): () -> ()
	tracking = isToolRunning

	-- Panel text fields with keyboard focus, so their typing is not taken for shortcuts.
	local typingIn: TextBox? = nil
	local typingEndedAt = 0
	local function watchTextBox(inst: Instance)
		if inst:IsA("TextBox") then
			inst.Focused:Connect(function()
				typingIn = inst
			end)
			inst.FocusLost:Connect(function()
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
		listener.InputBegan:Connect(function(input: InputObject)
			if MODIFIERS[input.KeyCode] then
				panelKeys[input.KeyCode] = true
			elseif
				input.UserInputType == Enum.UserInputType.Keyboard
				and not typingIn
				and os.clock() - typingEndedAt > TYPING_GRACE
				-- A dropdown under keyboard control takes these keys itself.
				and not KeyCapture.active()
			then
				fireKey(input.KeyCode)
			end
		end),
		widget.DescendantAdded:Connect(watchTextBox),
		listener.InputEnded:Connect(function(input: InputObject)
			panelKeys[input.KeyCode] = nil
		end),
		widget.WindowFocusReleased:Connect(function()
			table.clear(panelKeys)
			typingIn = nil
		end),
		-- Any key the 3D view reports means focus is back there, where IsKeyDown is accurate.
		UserInputService.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Keyboard then
				table.clear(panelKeys)
				if CAMERA_KEYS[input.KeyCode] then
					release()
				end
				-- Checked here, when the key arrives: by the time a handler runs (signals can be
				-- deferred), Enter or Esc may already have ended the text edit.
				if not UserInputService:GetFocusedTextBox() and not typingIn then
					fireKey(input.KeyCode)
				end
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.UserInputType == Enum.UserInputType.MouseButton3 then
				release()
			end
		end),
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Keyboard then
				table.clear(panelKeys)
			end
		end),
		RunService.Heartbeat:Connect(function()
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
	-- The zoom may land between frames; put the camera back as soon as it moves.
	local cameraConnection: RBXScriptConnection? = nil
	local function watchCamera()
		if cameraConnection then
			cameraConnection:Disconnect()
		end
		local camera = workspace.CurrentCamera
		cameraConnection = if camera
			then camera:GetPropertyChangedSignal("CFrame"):Connect(function()
				if os.clock() <= holdUntil then
					restore()
				end
			end)
			else nil
	end
	watchCamera()
	table.insert(connections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera))

	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		if cameraConnection then
			cameraConnection:Disconnect()
		end
		listener:Destroy()
		table.clear(panelKeys)
		tracking = function()
			return false
		end
	end
end

return Input
