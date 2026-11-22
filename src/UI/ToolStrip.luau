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
		local selected = props.active == tool
		-- Brushes show their color; the running tool keeps the theme's text color on its
		-- highlighted button.
		local icon = ICONS[tool]
		local accent = if selected then nil else Accent.tool(tool, theme)
		if accent then
			icon = table.clone(icon)
			icon.Color = accent
		end
		children[tool] = e(Tooltip, {
			Text = TIPS[tool],
			Position = UDim2.fromOffset(x, 1),
			Size = UDim2.fromOffset(BUTTON, BUTTON),
		}, e(StudioComponents.Button, {
			Size = UDim2.fromScale(1, 1),
			Icon = icon,
			Selected = selected,
			OnActivated = function()
				Settings.toggleTool(tool)
			end,
		}))
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
