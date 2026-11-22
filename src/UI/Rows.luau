--!strict
--[[
	Layout helpers shared by the tabs, styled after Studio's Properties window and sized for a
	narrow dock widget (about 190 px of usable width at the minimum size): section headings,
	label/control rows with tooltips over the whole row, button grids, checkboxes, wrapping text
	and a collapsible section.
]]

local Packages = script.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Icons = require(script.Parent.Icons)
local Tooltip = require(script.Parent.Tooltip)

local e = React.createElement

local LABEL_WIDTH = 66
local ROW_HEIGHT = 22
local GAP = 4
local HEADING_HEIGHT = 16
-- Space above a section heading, so sections read as groups.
local HEADING_TOP = 6

-- How secondary text is colored: dimmed for empty states, warning for things to fix.
export type Tone = "dimmed" | "warning"

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

-- The scrolling body of a page. Oversized by 1 px on each side so the panel clips its border;
-- the tool strip and status bar draw their own dividers.
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

-- A small bold heading that starts a group of rows. `first` skips the space above it.
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

-- A tool page's heading: the tool's name in bold and a small Stop button on the right, so
-- stopping costs no row of its own. (The running tool's color shows on its tool strip button.)
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


-- The heading of a page opened over the panel (Settings, Help): a small back button and the
-- page's name in bold, like a tool page's title.
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

-- A thin divider line between groups of rows.
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

-- A label on the left and a control filling the rest of the row. The tooltip (if any) shows
-- when hovering anywhere on the row, and hides once the control is clicked.
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

-- A read-only value in the control column.
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

-- Equal-width cells in rows of `columns`. Icon buttons should use at most 2 columns at the
-- minimum panel width.
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

-- Wraps a control with a hover tooltip. The control should fill its parent (Size 1, 1).
function Rows.withTooltip(tooltip: string, control: unknown, layoutOrder: number?, size: UDim2?)
	return e(Tooltip, { Text = tooltip, LayoutOrder = layoutOrder, Size = size }, control)
end

-- A full-width button with a hover tooltip. `primary` makes it Studio's main (blue) button, for
-- the one action a page leads to; use it at most once per page.
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

-- A full-width checkbox with a hover tooltip.
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

-- StudioComponents.Label has no AutomaticSize, so wrapping text uses a themed TextLabel.
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


-- Open or closed per section id for this Studio session, so switching tabs does not snap a
-- section shut; every new session starts with the default.
local openSections: { [string]: boolean } = {}

type CollapsibleProps = {
	LayoutOrder: number,
	Id: string,
	Title: string,
	Tooltip: string,
	-- Rows shown when open. Passed as a prop (not React children) because it is nested inside
	-- another children table.
	Content: { [string]: unknown },
}

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
				[React.Event.Activated] = function()
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

-- A section that opens and closes when its heading is clicked (closed by default).
function Rows.collapsible(layoutOrder: number, id: string, title: string, tooltip: string, content: { [string]: unknown })
	return e(Collapsible, { LayoutOrder = layoutOrder, Id = id, Title = title, Tooltip = tooltip, Content = content })
end

return Rows
