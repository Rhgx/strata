--!strict
-- Copyright (C) 2026 Rocks
-- Copyright (c) 2025 sircfenner (portions from StudioComponents)
-- SPDX-License-Identifier: GPL-3.0-or-later AND MIT
--[[
	Studio-style dropdown modeled on Qt combo boxes. Built on StudioComponents' Dropdown (MIT
	license below) with added keyboard navigation:

	- Type-ahead search: typing jumps to the first matching prefix (keys within 1 second form one
	  query; repeating a letter cycles items starting with it). Up/Down step by one; Home/End
	  jump to the ends.
	- When closed, keyboard selections preview immediately and commit after a short debounce so
	  stepping through options produces one undo step.
	- When open, keys move the highlight and scroll it into view; Enter or Space commits, Esc
	  closes the list. Space or F4 opens the list.
	- Clicking anywhere outside the dropdown releases keyboard focus.

	Because UserInputService does not receive input inside plugin widgets, a non-Active
	transparent overlay over the widget reads keyboard events and outside clicks without blocking
	clicks on underlying controls.

	StudioComponents is MIT licensed:

	Copyright (c) 2025 sircfenner

	Permission is hereby granted, free of charge, to any person obtaining a copy of this software
	and associated documentation files (the "Software"), to deal in the Software without
	restriction, including without limitation the rights to use, copy, modify, merge, publish,
	distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
	Software is furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all copies or
	substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
	BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
	NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
	DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]]

local UserInputService = game:GetService("UserInputService")

local UI = script.Parent
local Plugin = UI.Parent
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)
local StudioComponents = require(Packages.StudioComponents)

local KeyCapture = require(Plugin.State.KeyCapture)

local Icons = require(UI.Icons)

local Constants = StudioComponents.Constants
local e = React.createElement

local LEFT_TEXT_PAD = 5
local ARROW_WIDTH = 17
local ICON_GAP = 4
local SCROLLBAR = 8
local DEFAULT_MAX_ROWS = 8
local DEFAULT_TEXT = "Select..."
-- Keys typed within this window append to one type-ahead query (matching Qt's ~1 second timeout).
local TYPE_AHEAD_SECONDS = 1
-- Debounce before committing a closed-dropdown keyboard change.
local COMMIT_DELAY = 0.35

local CLICKS: { [Enum.UserInputType]: true } = {
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.UserInputType.MouseButton2] = true,
	[Enum.UserInputType.MouseButton3] = true,
}

export type Item = {
	Id: string,
	Text: string,
	Icon: Icons.Icon?,
}

export type Props = {
	Items: { Item },
	SelectedItem: string?,
	DefaultText: string?,
	Disabled: boolean?,
	RowHeight: number?,
	MaxVisibleRows: number?,
	-- Defaults to filling the parent container.
	Size: UDim2?,
	OnItemSelected: (id: string) -> (),
}

local function indexOf(items: { Item }, id: string?): number?
	for i, item in items do
		if item.Id == id then
			return i
		end
	end

	return nil
end

-- Finds the next item after `from` (wrapping around) whose label starts with `prefix`.
local function findPrefix(items: { Item }, prefix: string, from: number): number?
	local count = #items

	for step = 1, count do
		local i = (from + step - 1) % count + 1

		if items[i].Text:lower():sub(1, #prefix) == prefix then
			return i
		end
	end

	return nil
end

-- Returns the lowercased alphanumeric character for `key`, or nil for non-character keys.
local function characterOf(key: Enum.KeyCode): string?
	local text = UserInputService:GetStringForKeyCode(key)

	if #text ~= 1 and #key.Name == 1 then
		text = key.Name
	end

	if #text == 1 and text:match("%w") then
		return text:lower()
	end

	return nil
end

local function isInside(object: GuiObject?, position: Vector3): boolean
	if not object then
		return false
	end

	local offset = Vector2.new(position.X, position.Y) - object.AbsolutePosition
	local size = object.AbsoluteSize

	return offset.X >= 0 and offset.Y >= 0 and offset.X <= size.X and offset.Y <= size.Y
end

local function itemIcon(icon: Icons.Icon, color: Color3)
	return e("ImageLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(icon.Size.X, icon.Size.Y),
		BackgroundTransparency = 1,
		Image = icon.Image,
		ImageRectOffset = icon.RectOffset,
		ImageRectSize = icon.RectSize,
		ImageColor3 = color,
	})
end

local function Dropdown(props: Props)
	local theme = StudioComponents.useTheme()

	local opened, setOpened = React.useState(false)
	local focused, setFocused = React.useState(false)
	local hovered, setHovered = React.useState(false)
	-- Highlighted row index in the open popup list (driven by both keyboard and pointer).
	local highlight, setHighlight = React.useState(0)
	-- Pending choice made via keyboard while closed, shown until the debounce commits.
	local pending: string?, setPending = React.useState(nil :: string?)
	local window: LayerCollector?, setWindow = React.useState(nil :: LayerCollector?)

	local captureOwner = React.useRef({})
	local buttonRef = React.useRef(nil :: Frame?)
	local listRef = React.useRef(nil :: Frame?)
	local scrollRef = React.useRef(nil :: ScrollingFrame?)
	local typed = React.useRef({ text = "", at = 0 })
	local commitToken = React.useRef(0)

	-- Track button geometry in widget coordinates so the popup follows scrolling.
	local buttonPos, setButtonPos = React.useBinding(Vector2.zero)
	local buttonSize, setButtonSize = React.useBinding(Vector2.zero)

	local items = props.Items
	local selected = pending or props.SelectedItem
	local rowHeight = props.RowHeight or Constants.DefaultDropdownRowHeight
	local visibleRows = math.min(#items, props.MaxVisibleRows or DEFAULT_MAX_ROWS)
	local listHeight = visibleRows * rowHeight
	local disabled = props.Disabled == true

	-- Claim keyboard capture while focused or open so tool shortcuts do not intercept keys.
	React.useEffect(function (): (() -> ())?
		if focused or opened then
			return KeyCapture.hold(captureOwner)
		end

		return nil
	end, { focused, opened })

	React.useEffect(function ()
		local button = buttonRef.current

		if not button then
			return function () end
		end

		local function sync()
			setButtonPos(button.AbsolutePosition)
			setButtonSize(button.AbsoluteSize)
		end

		local function findWindow()
			setWindow(button:FindFirstAncestorWhichIsA("LayerCollector"))
		end

		local connections = {
			button:GetPropertyChangedSignal("AbsolutePosition"):Connect(sync),
			button:GetPropertyChangedSignal("AbsoluteSize"):Connect(sync),
			button.AncestryChanged:Connect(findWindow),
		}

		sync()
		findWindow()

		return function ()
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end, {})

	-- Drop focus when the plugin widget loses window focus.
	React.useEffect(function ()
		if not window or not window:IsA("PluginGui") then
			return function () end
		end

		local connection = window.WindowFocusReleased:Connect(function ()
			setOpened(false)
			setFocused(false)
		end)

		return function ()
			connection:Disconnect()
		end
	end, { window })

	React.useEffect(function ()
		if disabled then
			setOpened(false)
			setFocused(false)
		end
	end, { disabled })

	-- Clear any pending keyboard preview once an external value arrives.
	React.useEffect(function ()
		setPending(nil)
	end, { props.SelectedItem })

	-- Scroll the popup list to keep the highlighted row visible.
	React.useEffect(function ()
		local scroll = scrollRef.current

		if not opened or not scroll or highlight < 1 then
			return
		end

		local top = (highlight - 1) * rowHeight
		local y = scroll.CanvasPosition.Y

		if top < y then
			y = top
		elseif top + rowHeight > y + listHeight then
			y = top + rowHeight - listHeight
		end

		scroll.CanvasPosition = Vector2.new(0, y)
	end, { opened, highlight } :: { unknown })

	local function commitNow(id: string)
		commitToken.current += 1
		setPending(nil)

		if id ~= props.SelectedItem then
			props.OnItemSelected(id)
		end
	end

	local function commitLater(id: string)
		setPending(id)
		commitToken.current += 1

		local token = commitToken.current
		local onItemSelected = props.OnItemSelected

		task.delay(COMMIT_DELAY, function ()
			if commitToken.current == token then
				onItemSelected(id)
			end
		end)
	end

	local function openList()
		setHighlight(indexOf(items, selected) or 1)
		setOpened(true)
	end

	local function pick(id: string)
		setOpened(false)
		commitNow(id)
	end

	local function onKey(key: Enum.KeyCode)
		local count = #items

		if count == 0 then
			return
		end

		local current = if opened then highlight else (indexOf(items, selected) or 0)
		local character = characterOf(key)

		if not character then
			-- Non-character keys reset the active type-ahead query.
			typed.current.text = ""
		end

		local function moveTo(index: number)
			index = math.clamp(index, 1, count)

			if opened then
				setHighlight(index)
			elseif items[index].Id ~= selected then
				commitLater(items[index].Id)
			end
		end

		if key == Enum.KeyCode.Down then
			moveTo(current + 1)
		elseif key == Enum.KeyCode.Up then
			moveTo(math.max(current - 1, 1))
		elseif key == Enum.KeyCode.Home then
			moveTo(1)
		elseif key == Enum.KeyCode.End then
			moveTo(count)
		elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
			local item = items[highlight]

			if opened and item then
				pick(item.Id)
			end
		elseif key == Enum.KeyCode.Space or key == Enum.KeyCode.F4 then
			local item = items[highlight]

			if not opened then
				openList()
			elseif item then
				pick(item.Id)
			end
		elseif key == Enum.KeyCode.Escape then
			if opened then
				setOpened(false)
			else
				setFocused(false)
			end
		elseif character then
			local now = os.clock()
			local state = typed.current
			local text = if now - state.at <= TYPE_AHEAD_SECONDS then state.text .. character else character
			state.at = now
			state.text = text

			-- Pressing the same letter repeatedly cycles through items starting with that letter.
			local repeated = text == string.rep(character, #text)
			local search = if repeated then character else text
			local found = findPrefix(items, search, if repeated then current else math.max(current - 1, 0))

			if found then
				moveTo(found)
			end
		end
	end

	local overlay = nil

	if window and (focused or opened) and not disabled then
		local list = nil

		if opened then
			local drop = "Down"
			local spaceBelow = window.AbsoluteSize.Y - (buttonPos:getValue().Y + buttonSize:getValue().Y)
			local spaceAbove = buttonPos:getValue().Y

			if spaceBelow < listHeight and spaceAbove > spaceBelow then
				drop = "Up"
			end

			local rows: { [string]: unknown } = {
				Layout = e("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
			}

			for i, item in items do
				local modifier = if i == highlight
					then Enum.StudioStyleGuideModifier.Selected
					else Enum.StudioStyleGuideModifier.Default
				local textColor = theme:GetColor(Enum.StudioStyleGuideColor.MainText, modifier)
				local icon = item.Icon

				rows[`Item{i}`] = e("TextButton", {
					LayoutOrder = i,
					Size = UDim2.new(1, 0, 0, rowHeight),
					AutoButtonColor = false,
					BorderSizePixel = 0,
					BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Item, modifier),
					Text = "",

					-- Uniform handler signatures keep the React event table single-typed under strict mode.
					[React.Event.MouseEnter] = function (_: unknown, _arg: unknown)
						setHighlight(i)
					end,

					[React.Event.Activated] = function (_: unknown, _arg: unknown)
						pick(item.Id)
					end,
				}, {
					Padding = e("UIPadding", {
						PaddingLeft = UDim.new(0, LEFT_TEXT_PAD - 1),
						PaddingBottom = UDim.new(0, 1),
					}),

					Icon = if icon then itemIcon(icon, textColor) else nil,

					Label = e("TextLabel", {
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						Size = UDim2.new(1, if icon then -icon.Size.X - ICON_GAP else 0, 1, 0),
						BackgroundTransparency = 1,
						Font = Constants.DefaultFont,
						TextSize = Constants.DefaultTextSize,
						TextColor3 = textColor,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextTruncate = Enum.TextTruncate.AtEnd,
						Text = item.Text,
					}),
				})
			end

			local scrolls = #items > visibleRows

			list = e("Frame", {
				ref = listRef,
				AnchorPoint = Vector2.new(0, if drop == "Down" then 0 else 1),

				Position = React.joinBindings({ buttonPos, buttonSize }):map(function (values: { Vector2 })
					local position, size = values[1], values[2]
					local y = math.round(position.Y) + (if drop == "Down" then math.round(size.Y) else 0)

					return UDim2.fromOffset(math.round(position.X), y)
				end),

				Size = buttonSize:map(function (size: Vector2)
					return UDim2.fromOffset(math.round(size.X), listHeight)
				end),

				BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground),
				BorderColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border),
			}, {
				Scroll = e("ScrollingFrame", {
					ref = scrollRef,
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					CanvasSize = UDim2.fromOffset(0, #items * rowHeight),
					ScrollingDirection = Enum.ScrollingDirection.Y,
					ScrollBarThickness = if scrolls then SCROLLBAR else 0,
					VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
					ScrollBarImageColor3 = theme:GetColor(Enum.StudioStyleGuideColor.ScrollBar),
					TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
					MidImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
					BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
				}, rows),
			})
		end

		overlay = ReactRoblox.createPortal(
			e("Frame", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				ZIndex = 100,

				[React.Event.InputBegan] = function (_: unknown, input: InputObject)
					if input.UserInputType == Enum.UserInputType.Keyboard then
						onKey(input.KeyCode)
					elseif CLICKS[input.UserInputType] then
						-- Let the button and popup list handle clicks inside their own bounds.
						if isInside(buttonRef.current, input.Position) then
							return
						end

						if opened and isInside(listRef.current, input.Position) then
							return
						end

						setOpened(false)
						setFocused(false)
					end
				end,
			}, { List = list }),
			window
		)
	end

	local modifier = Enum.StudioStyleGuideModifier.Default

	if disabled then
		modifier = Enum.StudioStyleGuideModifier.Disabled
	elseif hovered then
		modifier = Enum.StudioStyleGuideModifier.Hover
	end

	local background = Enum.StudioStyleGuideColor.MainBackground

	if (hovered or opened) and not disabled then
		background = Enum.StudioStyleGuideColor.InputFieldBackground
	end

	local border = if focused and not disabled
		then theme:GetColor(Enum.StudioStyleGuideColor.InputFieldBorder, Enum.StudioStyleGuideModifier.Selected)
		else theme:GetColor(Enum.StudioStyleGuideColor.Border, modifier)

	local selectedText = props.DefaultText or DEFAULT_TEXT
	local selectedIndex = indexOf(items, selected)

	if selectedIndex then
		selectedText = items[selectedIndex].Text
	end

	return e("Frame", {
		ref = buttonRef,
		Size = props.Size or UDim2.fromScale(1, 1),
		BackgroundColor3 = theme:GetColor(background, modifier),
		BorderColor3 = border,

		[React.Event.InputBegan] = function (_: unknown, input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				setHovered(true)
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 and not disabled then
				setFocused(true)

				if opened then
					setOpened(false)
				else
					openList()
				end
			end
		end,

		[React.Event.InputEnded] = function (_: unknown, input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				setHovered(false)
			end
		end,
	}, {
		Overlay = overlay,

		Label = e("TextLabel", {
			Position = UDim2.fromOffset(LEFT_TEXT_PAD, 0),
			Size = UDim2.new(1, -LEFT_TEXT_PAD - ARROW_WIDTH - 2, 1, -1),
			BackgroundTransparency = 1,
			Text = selectedText,
			TextTransparency = if selectedIndex then 0 else 0.4,
			Font = Constants.DefaultFont,
			TextSize = Constants.DefaultTextSize,
			TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText, modifier),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),

		Arrow = e("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, -ARROW_WIDTH / 2, 0.5, 0),
			Size = UDim2.fromOffset(8, 4),
			BackgroundTransparency = 1,
			Image = "rbxassetid://7260137654",
			ImageColor3 = theme:GetColor(Enum.StudioStyleGuideColor.TitlebarText, modifier),
		}),
	})
end

return Dropdown
