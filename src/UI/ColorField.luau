--!strict
--[[
	A color row that fits a narrow panel: a swatch, a hex box and an optional pipette button on
	one line, and the color picker
	(laid out like Studio's, with the BrickColor palette) opening under it when the swatch is
	clicked.

	The hex box takes #RRGGBB, RRGGBB, #RGB or "R, G, B" (what Studio's Properties window copies).
	Picker drags preview here and commit once when released, so a drag is one undo step.
]]

local Packages = script.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local ColorPicker = require(script.Parent.ColorPicker)
local Format = require(script.Parent.Parent.State.Format)
local Icons = require(script.Parent.Icons)
local Tooltip = require(script.Parent.Tooltip)

local e = React.createElement

local LABEL_WIDTH = 66
local ROW_HEIGHT = 22
local SWATCH = 22
local GAP = 4

export type Props = {
	LayoutOrder: number,
	-- The shared color, or nil when the selected tiles differ.
	color: Color3?,
	tooltip: string,
	onCommit: (Color3) -> (),
	-- A pipette button at the end of the row (copy a part's look), lit while `sampling`.
	onSample: (() -> ())?,
	sampling: boolean?,
}

local toHex = Format.hex

local function ColorField(props: Props)
	local theme = StudioComponents.useTheme()
	local open, setOpen = React.useState(false)
	-- While dragging in the picker, the color being dragged (not yet committed).
	local draft: Color3?, setDraft = React.useState(nil :: Color3?)
	local text, setText = React.useState("")

	local onSample = props.onSample
	local shown = draft or props.color
	local committedHex = if props.color then toHex(props.color) else ""
	React.useEffect(function()
		setText(committedHex)
		setDraft(nil)
	end, { committedHex })

	local function commit(color: Color3)
		setDraft(nil)
		if toHex(color) == committedHex then
			setText(committedHex)
			return
		end
		props.onCommit(color)
	end

	local row = e("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Label = e(StudioComponents.Label, {
			Size = UDim2.new(0, LABEL_WIDTH - GAP, 1, 0),
			Text = "Color",
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Swatch = e("TextButton", {
			Position = UDim2.fromOffset(LABEL_WIDTH, 0),
			Size = UDim2.fromOffset(SWATCH, SWATCH),
			AutoButtonColor = false,
			BackgroundColor3 = shown or theme:GetColor(Enum.StudioStyleGuideColor.InputFieldBackground),
			BorderColor3 = theme:GetColor(
				if open then Enum.StudioStyleGuideColor.DialogMainButton else Enum.StudioStyleGuideColor.Border
			),
			BorderSizePixel = 1,
			Text = if shown then "" else "?",
			TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.DimmedText),
			Font = StudioComponents.Constants.DefaultFont,
			TextSize = StudioComponents.Constants.DefaultTextSize,
			[React.Event.Activated] = function()
				setOpen(not open)
			end,
		}),
		Pipette = if onSample
			then e(StudioComponents.Button, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.fromOffset(SWATCH, SWATCH),
				Icon = Icons.CopyAppearance,
				Selected = props.sampling,
				OnActivated = onSample,
			})
			else nil,
		Hex = e(StudioComponents.TextInput, {
			Position = UDim2.fromOffset(LABEL_WIDTH + SWATCH + GAP, 0),
			Size = UDim2.new(1, -(LABEL_WIDTH + SWATCH + GAP) - (if onSample then SWATCH + GAP else 0), 1, 0),
			Text = text,
			PlaceholderText = "Mixed",
			OnChanged = setText,
			OnFocusLost = function(value: string)
				local color = Format.parseColor(value)
				if color then
					commit(color)
				else
					setText(committedHex)
				end
			end,
		}),
	})

	return e("Frame", {
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
		Row = e(Tooltip, { Text = props.tooltip, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, ROW_HEIGHT) }, row),
		Picker = if open
			then e(ColorPicker, {
				LayoutOrder = 2,
				color = shown,
				onPreview = function(color: Color3)
					setDraft(color)
					setText(toHex(color))
				end,
				onCommit = commit,
			})
			else nil,
	})
end

return ColorField
