--!strict
--[[
	Shows the brush size in the 3D view while the panel's Radius control changes, since the mouse
	is over the panel then and the cursor is not on the terrain. For a moment after each change,
	the running tool draws its cursor where the middle of the 3D view meets the terrain (not where
	the mouse last was: the plugin mouse stops updating at the viewport border), with a small
	"Radius 8 st" label under it. Moving the mouse back over the 3D view ends it at once.
]]

local CoreGui = game:GetService("CoreGui")

local RadiusPreview = {}

local SHOW_SECONDS = 1.2
-- With no terrain in the middle of the view, the preview sits this far ahead of the camera
-- (scaled with the radius, so the ring fits on screen).
local MIN_DISTANCE, MAX_DISTANCE = 24, 120

local showUntil = 0
local label: TextLabel? = nil
local studio = settings().Studio

-- Starts the preview after the Radius changed in the panel.
function RadiusPreview.pulse()
	showUntil = os.clock() + SHOW_SECONDS
end

function RadiusPreview.cancel()
	showUntil = 0
end

function RadiusPreview.active(): boolean
	return os.clock() < showUntil
end

-- The ray through the middle of the 3D view.
function RadiusPreview.ray(): Ray?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local size = camera.ViewportSize
	return camera:ViewportPointToRay(size.X * 0.5, size.Y * 0.5)
end

-- Where the preview goes when the middle of the view shows no terrain: a point straight ahead,
-- facing the camera.
function RadiusPreview.fallback(radius: number): (Vector3?, Vector3?)
	local ray = RadiusPreview.ray()
	if not ray then
		return nil
	end
	local distance = math.clamp(radius * 4, MIN_DISTANCE, MAX_DISTANCE)
	return ray.Origin + ray.Direction.Unit * distance, -ray.Direction.Unit
end

-- Shows the label under `position`, or hides it when nil.
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

-- Creates the label and ends the preview when the mouse moves over the 3D view. Returns a
-- function that stops.
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
	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		label = nil
		gui:Destroy()
		showUntil = 0
	end
end

return RadiusPreview
