--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Shows a temporary 3D brush size preview when the user adjusts Radius in the panel (while the
	pointer is off the viewport and PluginMouse stops updating). Displays the active tool's
	cursor where the viewport center ray hits terrain (or at a fixed distance ahead of the camera
	as fallback) along with a floating "Radius X st" label. Moving the pointer back over the 3D
	viewport cancels the preview immediately.
]]

local CoreGui = game:GetService("CoreGui")

local SHOW_SECONDS = 1.2
-- Fallback distance bounds ahead of the camera when no terrain lies under the viewport center.
local MIN_DISTANCE, MAX_DISTANCE = 24, 120

local studio = settings().Studio

local showUntil = 0
local label: TextLabel? = nil

local RadiusPreview = {}

-- Creates a flat CylinderHandleAdornment ring for viewport brush cursors and size previews.
-- Starts hidden; the caller configures CFrame, Radius, InnerRadius, Color3, and destroys it.
function RadiusPreview.newRing(name: string, alwaysOnTop: boolean, transparency: number): CylinderHandleAdornment
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

-- Starts or extends the viewport radius preview after a panel Radius edit.
function RadiusPreview.pulse()
	showUntil = os.clock() + SHOW_SECONDS
end

function RadiusPreview.cancel()
	showUntil = 0
end

function RadiusPreview.active(): boolean
	return os.clock() < showUntil
end

-- Returns a ray cast through the center of the active viewport.
function RadiusPreview.ray(): Ray?
	local camera = workspace.CurrentCamera

	if not camera then
		return nil
	end

	local size = camera.ViewportSize

	return camera:ViewportPointToRay(size.X * 0.5, size.Y * 0.5)
end

-- Fallback preview position and camera-facing normal when no terrain is under the center ray.
function RadiusPreview.fallback(radius: number): (Vector3?, Vector3?)
	local ray = RadiusPreview.ray()

	if not ray then
		return nil
	end

	local distance = math.clamp(radius * 4, MIN_DISTANCE, MAX_DISTANCE)

	return ray.Origin + ray.Direction.Unit * distance, -ray.Direction.Unit
end

-- Positions the floating readout below `position` in screen space, or hides it when nil.
function RadiusPreview.label(position: Vector3?, text: string?)
	local current = label

	if not current then
		return
	end

	local gui = current.Parent and current.Parent.Parent
	local camera = workspace.CurrentCamera

	if not position or not text or not camera or not gui or not gui:IsA("ScreenGui") then
		if gui and gui:IsA("ScreenGui") then
			gui.Enabled = false
		end

		return
	end

	local point, visible = camera:WorldToViewportPoint(position)
	local size = camera.ViewportSize
	local frame = current.Parent :: Frame
	frame.Position = UDim2.fromOffset(math.clamp(point.X, 40, size.X - 40), math.clamp(point.Y + 16, 0, size.Y - 24))
	current.Text = text
	gui.Enabled = visible
end

-- Creates the floating label GUI and listens for mouse motion to dismiss previews. Returns cleanup.
function RadiusPreview.start(plugin: Plugin): () -> ()
	local gui = Instance.new("ScreenGui")
	gui.Name = "StrataRadiusPreview"
	gui.DisplayOrder = 11
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.fromOffset(0, 0)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 1
	frame.Active = false
	frame.Parent = gui

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 2)
	padding.PaddingBottom = UDim.new(0, 2)
	padding.PaddingLeft = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 6)
	padding.Parent = frame

	local text = Instance.new("TextLabel")
	text.AutomaticSize = Enum.AutomaticSize.XY
	text.Size = UDim2.fromOffset(0, 0)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.SourceSans
	text.TextSize = 14
	text.Active = false
	text.Parent = frame
	label = text

	local function applyTheme()
		local theme = studio.Theme
		frame.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
		frame.BorderColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border)
		text.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	end

	applyTheme()
	gui.Parent = CoreGui

	local connections = {
		studio.ThemeChanged:Connect(applyTheme),
		plugin:GetMouse().Move:Connect(RadiusPreview.cancel),
	}

	return function ()
		for _, connection in connections do
			connection:Disconnect()
		end

		label = nil
		gui:Destroy()
		showUntil = 0
	end
end

return RadiusPreview
