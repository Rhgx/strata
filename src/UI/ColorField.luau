--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Compact color input row for narrow panels: a color swatch, a hex text box, and an optional
	pipette button on a single line, with an expandable ColorPicker (styled like Studio's with
	the BrickColor palette) opening beneath the row when the swatch is clicked.

	The text box accepts #RRGGBB, RRGGBB, #RGB, or "R, G, B" (matching Studio's Properties
	window). Picker drags preview live and commit once on release so each drag is one undo step.
]]

local UI = script.Parent
local Plugin = UI.Parent
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Format = require(Plugin.State.Format)

local Icons = require(UI.Icons)
local Tooltip = require(UI.Tooltip)
local ColorPicker = require(UI.ColorPicker)

local e = React.createElement
local toHex = Format.hex

local LABEL_WIDTH = 66
local ROW_HEIGHT = 22
local SWATCH = 22
local GAP = 4

export type Props = {
	LayoutOrder: number,
	-- Shared color across selected tiles, or nil when mixed.
	color: Color3?,
	tooltip: string,
	onCommit: (Color3) -> (),
	-- Optional pipette button at the right end of the row, highlighted while `sampling` is true.
	onSample: (() -> ())?,
	sampling: boolean?,
}

local function ColorField(props: Props)
	local theme = StudioComponents.useTheme()
	local open, setOpen = React.useState(false)
	-- Uncommitted color while dragging in the picker.
	local draft: Color3?, setDraft = React.useState(nil :: Color3?)
	local text, setText = React.useState("")

	local onSample = props.onSample
	local shown = draft or props.color
	local committedHex = if props.color then toHex(props.color) else ""

	React.useEffect(function ()
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

			[React.Event.Activated] = function ()
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

			OnFocusLost = function (value: string)
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

				onPreview = function (color: Color3)
					setDraft(color)
					setText(toHex(color))
				end,

				onCommit = commit,
			})
			else nil,
	})
end

return ColorField
