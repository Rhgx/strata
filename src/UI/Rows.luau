--!strict
--[[
	Shared layout helpers modeled on Studio's Properties window and sized for a narrow dock
	widget (~190 px usable width at minimum size): section headings, label/control rows with
	full-row tooltips, button grids, checkboxes, wrapping text, and collapsible sections.
]]

local UI = script.Parent
local Plugin = UI.Parent
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Icons = require(UI.Icons)
local Tooltip = require(UI.Tooltip)

local e = React.createElement

local LABEL_WIDTH = 66
local ROW_HEIGHT = 22
local GAP = 4
local HEADING_HEIGHT = 16
-- Extra vertical margin above section headings so sections separate visually.
local HEADING_TOP = 6

-- Secondary text tone: dimmed for empty states, warning for actionable issues.
export type Tone = "dimmed" | "warning"

type CollapsibleProps = {
	LayoutOrder: number,
	Id: string,
	Title: string,
	Tooltip: string,
	-- Expanded rows passed as a prop rather than children because they nest inside another table.
	Content: { [string]: unknown },
}

-- Session-scoped open/closed state per collapsible ID so switching tabs preserves state.
local openSections: { [string]: boolean } = {}

local Rows = {}

Rows.BUTTON_HEIGHT = 24

local function toneColor(tone: Tone?): Enum.StudioStyleGuideColor?
	if tone == "dimmed" then
		return Enum.StudioStyleGuideColor.DimmedText
	elseif tone == "warning" then
		return Enum.StudioStyleGuideColor.WarningText
	end

	return nil
end

-- Scrollable page body, expanded by 1 px on each side so the parent panel clips its outer border
-- (the tool strip and status bar draw their own dividers).
function Rows.page(children: { [string]: unknown })
	return e(StudioComponents.ScrollFrame, {
		Size = UDim2.new(1, 2, 1, 2),
		Position = UDim2.fromOffset(-1, -1),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 7),
		PaddingRight = UDim.new(0, 7),
		Layout = {
			ClassName = "UIListLayout",
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, GAP),
		},
	}, children)
end

-- Bold section heading. Pass `first = true` to omit the top spacer.
function Rows.section(layoutOrder: number, title: string, first: boolean?)
	local top = if first then 0 else HEADING_TOP

	return e("Frame", {
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, HEADING_HEIGHT + top),
		BackgroundTransparency = 1,
	}, {
		Title = e(StudioComponents.Label, {
			Position = UDim2.fromOffset(0, top),
			Size = UDim2.new(1, 0, 0, HEADING_HEIGHT),
			Text = `<b>{title}</b>`,
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColorStyle = Enum.StudioStyleGuideColor.DimmedText,
		}),
	})
end

-- Tool page title row: bold tool name with an inline Stop button on the right (the active tool's
-- accent color already highlights its button on the tool strip).
function Rows.title(layoutOrder: number, text: string, onStop: () -> (), stopTip: string)
	return e("Frame", {
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
	}, {
		Label = e(StudioComponents.Label, {
			Size = UDim2.new(1, -(ROW_HEIGHT + GAP), 1, 0),
			Text = `<b>{text}</b>`,
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),

		Stop = e("Frame", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromOffset(ROW_HEIGHT, ROW_HEIGHT),
			BackgroundTransparency = 1,
		}, {
			Tip = Rows.withTooltip(
				stopTip,
				e(StudioComponents.Button, {
					Size = UDim2.fromScale(1, 1),
					Icon = Icons.StopTool,
					OnActivated = onStop,
				})
			),
		}),
	})
end

-- Overlay page header (Settings, Help): back button followed by a bold page title.
function Rows.header(layoutOrder: number, text: string, onBack: () -> (), backTooltip: string)
	return e("Frame", {
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
	}, {
		Back = e("Frame", {
			Size = UDim2.fromOffset(ROW_HEIGHT, ROW_HEIGHT),
			BackgroundTransparency = 1,
		}, {
			Tip = Rows.withTooltip(
				backTooltip,
				e(StudioComponents.Button, {
					Size = UDim2.fromScale(1, 1),
					Icon = Icons.Back,
					OnActivated = onBack,
				})
			),
		}),

		Title = e(StudioComponents.Label, {
			Position = UDim2.fromOffset(ROW_HEIGHT + 6, 0),
			Size = UDim2.new(1, -(ROW_HEIGHT + 6), 1, 0),
			Text = `<b>{text}</b>`,
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
	})
end

local function Divider(props: { LayoutOrder: number })
	local theme = StudioComponents.useTheme()

	return e("Frame", {
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.new(1, 0, 0, 1),
		BorderSizePixel = 0,
		BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border),
	})
end

function Rows.divider(layoutOrder: number)
	return e(Divider, { LayoutOrder = layoutOrder })
end

-- Label/control pair with an optional hover tooltip spanning the full row.
function Rows.property(layoutOrder: number, label: string, control: unknown, tooltip: string?)
	local row = e("Frame", {
		LayoutOrder = if tooltip then nil else layoutOrder,
		Size = if tooltip then UDim2.fromScale(1, 1) else UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
	}, {
		Label = e(StudioComponents.Label, {
			Size = UDim2.new(0, LABEL_WIDTH - GAP, 1, 0),
			Text = label,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),

		Control = e("Frame", {
			Position = UDim2.fromOffset(LABEL_WIDTH, 0),
			Size = UDim2.new(1, -LABEL_WIDTH, 1, 0),
			BackgroundTransparency = 1,
		}, { Control = control }),
	})

	if not tooltip then
		return row
	end

	return e(Tooltip, { Text = tooltip, LayoutOrder = layoutOrder, Size = UDim2.new(1, 0, 0, ROW_HEIGHT) }, row)
end

-- Read-only text value aligned with the control column.
function Rows.value(layoutOrder: number, label: string, text: string, tone: Tone?, tooltip: string?)
	return Rows.property(
		layoutOrder,
		label,
		e(StudioComponents.Label, {
			Size = UDim2.fromScale(1, 1),
			Text = text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColorStyle = toneColor(tone),
		}),
		tooltip
	)
end

-- Equal-width cell grid. Icon buttons should use at most 2 columns at the minimum panel width.
function Rows.grid(layoutOrder: number, columns: number, cells: { [string]: unknown })
	local content = table.clone(cells)
	content.Grid = e("UIGridLayout", {
		CellSize = UDim2.new(1 / columns, -GAP * (columns - 1) / columns, 0, Rows.BUTTON_HEIGHT),
		CellPadding = UDim2.fromOffset(GAP, GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	return e("Frame", {
		LayoutOrder = layoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, content)
end

-- Wraps a single control element (expected to fill its parent) with a hover tooltip.
function Rows.withTooltip(tooltip: string, control: unknown, layoutOrder: number?, size: UDim2?)
	return e(Tooltip, { Text = tooltip, LayoutOrder = layoutOrder, Size = size }, control)
end

-- Full-width button with a hover tooltip. Set `primary = true` for at most one main action per page.
function Rows.button(
	layoutOrder: number,
	text: string,
	onActivated: () -> (),
	tooltip: string,
	disabled: boolean?,
	icon: Icons.Icon?,
	primary: boolean?
)
	return Rows.withTooltip(
		tooltip,
		e(if primary and not disabled then StudioComponents.MainButton else StudioComponents.Button, {
			Size = UDim2.fromScale(1, 1),
			Text = text,
			Icon = icon,
			Disabled = disabled,
			OnActivated = onActivated,
		}),
		layoutOrder,
		UDim2.new(1, 0, 0, Rows.BUTTON_HEIGHT)
	)
end

function Rows.checkbox(
	layoutOrder: number,
	label: string,
	value: boolean,
	onChanged: () -> (),
	tooltip: string,
	disabled: boolean?
)
	return Rows.withTooltip(
		tooltip,
		e(StudioComponents.Checkbox, {
			Size = UDim2.fromScale(1, 1),
			Label = label,
			Value = value,
			Disabled = disabled,
			OnChanged = onChanged,
		}),
		layoutOrder,
		UDim2.new(1, 0, 0, StudioComponents.Constants.DefaultToggleHeight)
	)
end

-- StudioComponents.Label lacks AutomaticSize, so wrapping paragraphs use a themed TextLabel.
local function Paragraph(props: { LayoutOrder: number, Text: string, Tone: Tone? })
	local theme = StudioComponents.useTheme()

	return e("TextLabel", {
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = props.Text,
		RichText = true,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = StudioComponents.Constants.DefaultFont,
		TextSize = StudioComponents.Constants.DefaultTextSize,
		TextColor3 = theme:GetColor(toneColor(props.Tone) or Enum.StudioStyleGuideColor.MainText),
	})
end

function Rows.paragraph(layoutOrder: number, text: string, tone: Tone?)
	return e(Paragraph, { LayoutOrder = layoutOrder, Text = text, Tone = tone })
end

local function Collapsible(props: CollapsibleProps)
	local theme = StudioComponents.useTheme()
	local open, setOpen = React.useState(openSections[props.Id] == true)
	local icon = if open then Icons.ChevronDown else Icons.ChevronRight
	local body = nil

	if open then
		local content = table.clone(props.Content)
		content.Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, GAP),
		})

		body = e("Frame", {
			LayoutOrder = 2,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, content)
	end

	return e("Frame", {
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, GAP),
		}),

		Header = e(
			Tooltip,
			{ Text = props.Tooltip, LayoutOrder = 1, Size = UDim2.new(1, 0, 0, HEADING_HEIGHT + HEADING_TOP) },
			e("TextButton", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",

				[React.Event.Activated] = function ()
					local nextOpen = not open
					openSections[props.Id] = nextOpen
					setOpen(nextOpen)
				end,
			}, {
				Icon = e("ImageLabel", {
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 0, 1, -2),
					Size = UDim2.fromOffset(12, 12),
					BackgroundTransparency = 1,
					Image = icon.Image,
					ImageRectOffset = icon.RectOffset,
					ImageRectSize = icon.RectSize,
					ImageColor3 = theme:GetColor(Enum.StudioStyleGuideColor.DimmedText),
				}),

				Title = e(StudioComponents.Label, {
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 16, 1, 0),
					Size = UDim2.new(1, -16, 0, HEADING_HEIGHT),
					Text = `<b>{props.Title}</b>`,
					RichText = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextColorStyle = Enum.StudioStyleGuideColor.DimmedText,
				}),
			})
		),

		Body = body,
	})
end

-- Collapsible section toggled by clicking its header (closed by default).
function Rows.collapsible(layoutOrder: number, id: string, title: string, tooltip: string, content: { [string]: unknown })
	return e(Collapsible, { LayoutOrder = layoutOrder, Id = id, Title = title, Tooltip = tooltip, Content = content })
end

return Rows
