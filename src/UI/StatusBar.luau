--!strict
--[[
	The pinned bottom line of the panel: the latest operation result (from State/Status), or a
	short message for the current page when there is none. The full text is in a tooltip, since
	the line truncates in a narrow panel. On the right, the Settings gear and the ? help button.
]]

local Packages = script.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(script.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.State.Status)
local Icons = require(script.Parent.Icons)
local Tooltip = require(script.Parent.Tooltip)

local e = React.createElement

local HEIGHT = 24
local BUTTON_SIZE = 22
local BUTTON_GAP = 4

local KIND_COLORS: { [Status.Kind]: Enum.StudioStyleGuideColor } = {
	success = Enum.StudioStyleGuideColor.MainText,
	warning = Enum.StudioStyleGuideColor.WarningText,
	error = Enum.StudioStyleGuideColor.ErrorText,
}

local function useStatus(): Status.Message?
	local message, setMessage = React.useState(Status.get())
	React.useEffect(function()
		return Status.subscribe(function(next: Status.Message?)
			setMessage(next)
		end)
	end, {})
	return message
end

type Props = {
	idle: string,
	overlay: Settings.Overlay,
}

-- A square icon button at `slot` from the right edge (0 is the rightmost).
local function overlayButton(slot: number, icon: Icons.Icon, overlay: Settings.Overlay, current: Settings.Overlay, openTip: string, closeTip: string)
	local open = current == overlay
	return e(
		Tooltip,
		{
			Text = if open then closeTip else openTip,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -2 - slot * (BUTTON_SIZE + BUTTON_GAP), 0.5, 1),
			Size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE),
		},
		e(StudioComponents.Button, {
			Size = UDim2.fromScale(1, 1),
			Icon = icon,
			Selected = open,
			OnActivated = function()
				Settings.setOverlay(if open then "none" else overlay)
			end,
		})
	)
end

local function StatusBar(props: Props)
	local theme = StudioComponents.useTheme()
	local message = useStatus()
	local text = if message then message.text else props.idle
	local color = if message then KIND_COLORS[message.kind] else Enum.StudioStyleGuideColor.DimmedText

	return e("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, HEIGHT),
		BackgroundTransparency = 1,
	}, {
		Line = e("Frame", {
			Size = UDim2.new(1, 0, 0, 1),
			BorderSizePixel = 0,
			BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border),
		}),
		-- The tooltip takes a single element child (a frame); React-Lua cannot render a nested
		-- keyed table there.
		Message = e(
			Tooltip,
			{
				Text = if message then `{text}\n\n> Click to dismiss.` else text,
				Size = UDim2.new(1, -(BUTTON_SIZE * 2 + BUTTON_GAP + 12), 1, -1),
			},
			e("Frame", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
			}, {
				Label = e(StudioComponents.Label, {
					Position = UDim2.fromOffset(7, 1),
					Size = UDim2.new(1, -7, 1, 0),
					Text = text,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					TextColorStyle = color,
				}),
				-- Clicking a result dismisses it (errors otherwise stay until the next action).
				Dismiss = if message
					then e("TextButton", {
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						Text = "",
						[React.Event.Activated] = function()
							Status.clear()
						end,
					})
					else nil,
			})
		),
		Settings = overlayButton(1, Icons.Settings, "settings", props.overlay, "**Settings**", "**Close settings** (`Esc`)."),
		Help = overlayButton(0, Icons.Help, "help", props.overlay, "**Help** and shortcuts", "**Close help** (`Esc`)."),
	})
end

return StatusBar
