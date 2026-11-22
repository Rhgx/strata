--!strict
--[[
	The row of tool buttons pinned to the top of the panel. It mirrors the ribbon buttons, which
	live on the Plugins tab where builders rarely are, so tools stay one click away from the
	panel. Icon only, with the full name and keys in tooltips.
]]

local Packages = script.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(script.Parent.Parent.State.Settings)
local Accent = require(script.Parent.Accent)
local Icons = require(script.Parent.Icons)
local Tooltip = require(script.Parent.Tooltip)

local e = React.createElement

local BUTTON = 24
-- 8 buttons, 7 gaps and the divider fit the panel's minimum width (220 px, 206 inside).
local GAP = 1
-- Space for the divider between the brushes and the click tools.
local DIVIDER = 5
-- The brushes before the divider (Raise, Lower, Smooth, Raise To, Material, Mesh).
local BRUSHES = 6

local TIPS: { [Settings.Tool]: string } = {
	Raise = "**Raise**: push terrain outward.\n\n> Hold `Ctrl` to lower, `Shift` to smooth.",
	Lower = "**Lower**: push terrain inward.\n\n> Hold `Ctrl` to raise, `Shift` to smooth.",
	Smooth = "**Smooth**: even out bumps.\n\n> Blends across tile seams.",
	RaiseTo = "**Raise To**: flatten to an exact `Height`.\n\n> Hold `Shift` to smooth.",
	Material = "**Material**: paint a material into tiles (a road through grass).\n\n> Hold `Ctrl` to erase, `Alt + Right Click` to pick a look.",
	Mesh = "**Mesh**: fewer triangles where you want them, or cut holes.\n\n> Drag to mark points, then `Enter` applies. `Ctrl` restores.",
	PickFaces = "**Pick faces**: click part faces in 3D.\n\n> Click `Create` when ready.",
	Stitch = "**Stitch**: snap tile edges to a part.\n\n> Click a part in 3D to stitch nearby edges.",
}

local ICONS: { [Settings.Tool]: Icons.Icon } = {
	Raise = Icons.Raise,
	Lower = Icons.Lower,
	Smooth = Icons.Smooth,
	RaiseTo = Icons.RaiseTo,
	Material = Icons.Material,
	Mesh = Icons.Mesh,
	PickFaces = Icons.PickFaces,
	Stitch = Icons.Stitch,
}

export type Props = {
	active: Settings.Tool?,
}

local ICON_SIZE = 16

--[[
	One tool button, drawn by hand because StudioComponents buttons only take theme colors. Idle
	brushes show their icon in the tool's color on the normal button; the running brush swaps
	the two, filling the button with its color and drawing the icon in the normal button color,
	so the running tool is told by color alone. Pick faces and Stitch have no color and use
	Studio's own selected style.
]]
local function ToolButton(props: { tool: Settings.Tool, selected: boolean })
	local theme = StudioComponents.useTheme()
	local hovered, setHovered = React.useState(false)
	local pressed, setPressed = React.useState(false)
	local accent = Accent.tool(props.tool, theme)
	local icon = ICONS[props.tool]

	local modifier = Enum.StudioStyleGuideModifier.Default
	if props.selected then
		modifier = Enum.StudioStyleGuideModifier.Selected
	elseif pressed and hovered then
		modifier = Enum.StudioStyleGuideModifier.Pressed
	elseif hovered then
		modifier = Enum.StudioStyleGuideModifier.Hover
	end

	local background, border, iconColor
	if accent and props.selected then
		-- A touch lighter on hover, like Studio's buttons.
		background = if hovered then accent:Lerp(Color3.new(1, 1, 1), 0.12) else accent
		border = background
		iconColor = theme:GetColor(Enum.StudioStyleGuideColor.Button)
	else
		background = theme:GetColor(Enum.StudioStyleGuideColor.Button, modifier)
		border = theme:GetColor(Enum.StudioStyleGuideColor.ButtonBorder, modifier)
		iconColor = accent or theme:GetColor(Enum.StudioStyleGuideColor.ButtonText, modifier)
	end

	return e("TextButton", {
		Size = UDim2.fromScale(1, 1),
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = background,
		BorderColor3 = border,
		[React.Event.InputBegan] = function(_, input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				setHovered(true)
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
				setPressed(true)
			end
		end,
		[React.Event.InputEnded] = function(_, input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				-- Leaving also ends a press, in case the release happens outside.
				setHovered(false)
				setPressed(false)
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
				setPressed(false)
			end
		end,
		[React.Event.Activated] = function()
			Settings.toggleTool(props.tool)
		end,
	}, {
		Icon = e("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE),
			BackgroundTransparency = 1,
			Image = icon.Image,
			ImageRectOffset = icon.RectOffset,
			ImageRectSize = icon.RectSize,
			ImageColor3 = iconColor,
		}),
	})
end

local function ToolStrip(props: Props)
	local theme = StudioComponents.useTheme()
	local children: { [string]: unknown } = {
		Divider = e("Frame", {
			Position = UDim2.fromOffset(BRUSHES * (BUTTON + GAP) + (DIVIDER - GAP) // 2 - 1, 5),
			Size = UDim2.new(0, 1, 0, BUTTON - 6),
			BorderSizePixel = 0,
			BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border),
		}),
		Line = e("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, -7, 1, 0),
			Size = UDim2.new(1, 14, 0, 1),
			BorderSizePixel = 0,
			BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border),
		}),
	}
	for index, tool: Settings.Tool in Settings.tools() do
		local x = (index - 1) * (BUTTON + GAP) + (if index > BRUSHES then DIVIDER else 0)
		children[tool] = e(Tooltip, {
			Text = TIPS[tool],
			Position = UDim2.fromOffset(x, 1),
			Size = UDim2.fromOffset(BUTTON, BUTTON),
		}, e(ToolButton, { tool = tool, selected = props.active == tool }))
	end
	return e("Frame", {
		Size = UDim2.new(1, 0, 0, BUTTON + 4),
		BackgroundTransparency = 1,
	}, {
		Padding = e("UIPadding", { PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7), PaddingTop = UDim.new(0, 1) }),
		Content = e("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, children),
	})
end

return ToolStrip
