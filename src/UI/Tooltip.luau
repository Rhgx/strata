--!strict
--[[
	Hover tooltip in the Studio theme. Wraps its children in a transparent frame and, after a
	short delay, shows the text near the mouse. Drawn through a portal into the plugin window so
	tabs and scroll frames never clip it (the same approach StudioComponents uses for dropdowns).
	The box is sized to its text and kept inside the window, even in a narrow dock. Clicking
	hides it until the mouse leaves and comes back, so it never sits on top of an open dropdown.

	The text uses the small markup in UI/Markup (bold, keys, bullets, dimmed notes, gaps).
]]

local TextService = game:GetService("TextService")

local Packages = script.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)
local StudioComponents = require(Packages.StudioComponents)

local Markup = require(script.Parent.Markup)

local e = React.createElement

local DELAY_SECONDS = 0.4
local MAX_WIDTH = 240
local PADDING_X = 6
local PADDING_Y = 4
local MOUSE_OFFSET = Vector2.new(12, 18)
local EDGE = 4

type Props = {
	Text: string,
	LayoutOrder: number?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	-- Must be a single element: it is nested under another child table, which React-Lua only
	-- supports for elements (a keyed table here crashes with "createTextInstance").
	children: unknown?,
}

type Shown = {
	window: PluginGui,
	position: Vector2,
	rich: string,
	textSize: Vector2,
}

-- Measures rich text wrapped at `width`. Yields.
local function measure(rich: string, width: number): Vector2
	local params = Instance.new("GetTextBoundsParams")
	params.Text = rich
	params.RichText = true
	params.Font = Font.fromEnum(StudioComponents.Constants.DefaultFont)
	params.Size = StudioComponents.Constants.DefaultTextSize
	params.Width = width
	return TextService:GetTextBoundsAsync(params)
end

local function Tooltip(props: Props)
	local theme = StudioComponents.useTheme()
	local hovered, setHovered = React.useState(false)
	local shown: Shown?, setShown = React.useState(nil :: Shown?)
	local frameRef = React.useRef(nil :: Frame?)

	React.useEffect(function()
		local cancelled = false
		if hovered then
			task.delay(DELAY_SECONDS, function()
				local frame = frameRef.current
				if cancelled or not frame then
					return
				end
				local window = frame:FindFirstAncestorWhichIsA("PluginGui")
				if not window then
					return
				end
				local position = window:GetRelativeMousePosition()
				local rich = Markup.toRichText(props.Text)
				local maxWidth = math.max(60, math.min(MAX_WIDTH, window.AbsoluteSize.X - EDGE * 2) - PADDING_X * 2)
				local ok, size = pcall(measure, rich, maxWidth)
				-- Measuring yields; the mouse may have left meanwhile.
				if ok and not cancelled then
					setShown({ window = window, position = position, rich = rich, textSize = size })
				end
			end)
		else
			setShown(nil)
		end
		return function()
			cancelled = true
		end
	end, { hovered, props.Text } :: { unknown })

	local tip = nil
	if shown then
		local windowSize = shown.window.AbsoluteSize
		local textSize = shown.textSize
		local boxWidth = math.ceil(textSize.X) + PADDING_X * 2
		local boxHeight = math.ceil(textSize.Y) + PADDING_Y * 2
		-- Below and right of the mouse, pushed back inside the window; above it near the bottom.
		local x = math.clamp(shown.position.X + MOUSE_OFFSET.X, EDGE, math.max(EDGE, windowSize.X - boxWidth - EDGE))
		local y = shown.position.Y + MOUSE_OFFSET.Y
		if y + boxHeight > windowSize.Y - EDGE then
			y = shown.position.Y - boxHeight - 6
		end
		y = math.max(EDGE, y)
		tip = ReactRoblox.createPortal(
			e("Frame", {
				Position = UDim2.fromOffset(x, y),
				Size = UDim2.fromOffset(boxWidth, boxHeight),
				BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Tooltip),
				BorderColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border),
				BorderSizePixel = 1,
				ZIndex = 1000,
			}, {
				Text = e("TextLabel", {
					Position = UDim2.fromOffset(PADDING_X, PADDING_Y),
					Size = UDim2.new(1, -PADDING_X * 2, 1, -PADDING_Y * 2),
					BackgroundTransparency = 1,
					Text = shown.rich,
					RichText = true,
					TextWrapped = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
					Font = StudioComponents.Constants.DefaultFont,
					TextSize = StudioComponents.Constants.DefaultTextSize,
					TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText),
					ZIndex = 1001,
				}),
			}),
			shown.window
		)
	end

	return e("Frame", {
		ref = frameRef,
		LayoutOrder = props.LayoutOrder,
		Size = props.Size or UDim2.fromScale(1, 1),
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		BackgroundTransparency = 1,
		-- One handler shape for all three events (the props table needs a single value type).
		[React.Event.MouseEnter] = function(_: unknown, _arg: unknown)
			setHovered(true)
		end,
		[React.Event.MouseLeave] = function(_: unknown, _arg: unknown)
			setHovered(false)
		end,
		[React.Event.InputBegan] = function(_: unknown, input: unknown)
			if typeof(input) == "Instance" and input:IsA("InputObject") then
				local kind = input.UserInputType
				if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.MouseButton2 then
					setHovered(false)
				end
			end
		end,
	}, {
		Content = props.children,
		Tip = tip,
	})
end

return Tooltip
