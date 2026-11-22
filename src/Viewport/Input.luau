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

--[[
	Calls `onStep(1)` or `onStep(-1)` on Ctrl + Scroll over the 3D view while `active()` says so,
	and holds the camera still for it. Returns the connections.
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
			onWheel(1)
		end),
		mouse.WheelBackward:Connect(function()
			onWheel(-1)
		end),
	}
end

--[[
	Starts the shared input state. `isToolRunning` says whether any viewport tool is on (the
	camera is only remembered then). Returns a function that stops.
]]
function Input.start(widget: DockWidgetPluginGui, isToolRunning: () -> boolean): () -> ()
	tracking = isToolRunning

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
			end
		end),
		listener.InputEnded:Connect(function(input: InputObject)
			panelKeys[input.KeyCode] = nil
		end),
		widget.WindowFocusReleased:Connect(function()
			table.clear(panelKeys)
		end),
		-- Any key the 3D view reports means focus is back there, where IsKeyDown is accurate.
		UserInputService.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.Keyboard then
				table.clear(panelKeys)
				if CAMERA_KEYS[input.KeyCode] then
					release()
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
