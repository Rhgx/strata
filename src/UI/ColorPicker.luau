--!strict
--[[
	A color picker laid out like the one in Studio's Properties window: a mode switch (RGB, HSV,
	Hex or Brick) with matching boxes, a saturation and brightness square and a hue bar, or in
	Brick mode the BrickColor palette as a hexagon of 127 colors over a row of 12 grays (Studio's
	colors, order and grid).

	Drags preview through `onPreview` and commit once on release; typed values commit when the box
	loses focus; a palette click commits at once. So each change is one undo step.

	UserInputService does not see input inside plugin widgets, so a drag is followed by a
	transparent button laid over the whole widget while the mouse is held.
]]

local AssetService = game:GetService("AssetService")

local Packages = script.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local ReactRoblox = require(Packages.ReactRoblox)
local StudioComponents = require(Packages.StudioComponents)

local Dropdown = require(script.Parent.Dropdown)
local Format = require(script.Parent.Format)

local e = React.createElement

export type Mode = "RGB" | "HSV" | "Hex" | "Brick"

export type Props = {
	LayoutOrder: number?,
	-- The color to show, or nil when the selected tiles differ.
	color: Color3?,
	onPreview: (Color3) -> (),
	onCommit: (Color3) -> (),
}

local ROW_HEIGHT = 22
local GAP = 4
local MODE_WIDTH = 64
local SQUARE_HEIGHT = 140
local HUE_HEIGHT = 12
local KNOB = 10

-- Hexagons are 14 x 16, 8 px apart across alternating rows and 14 px apart down (Studio's grid).
local HEX_W, HEX_H = 14, 16
local STEP_X, STEP_Y = 8, 14
local OUTLINE = 4
-- Rows in the hexagon. The middle row holds 13 colors, the top and bottom rows 7: 127 in all.
local GRID_ROWS = 13

-- Studio's BrickColor palette, by BrickColor number in Studio's order.
local PALETTE = {
	141, 301, 107, 26, 1012, 303, 1011, 304, 28, 1018, 302, 305, 306, 307, 308, 1021,
	309, 310, 1019, 135, 102, 23, 1010, 312, 313, 37, 1022, 1020, 1027, 311, 315, 1023,
	1031, 316, 151, 317, 318, 319, 1024, 314, 1013, 1006, 321, 322, 104, 1008, 119, 323,
	324, 325, 320, 11, 1026, 1016, 1032, 1015, 327, 1005, 1009, 29, 328, 1028, 208, 45,
	329, 330, 331, 1004, 21, 332, 333, 24, 334, 226, 1029, 335, 336, 342, 343, 338,
	1007, 339, 133, 106, 340, 341, 1001, 1, 9, 1025, 337, 344, 345, 1014, 105, 346,
	347, 348, 349, 1030, 125, 101, 350, 192, 351, 352, 353, 354, 1002, 5, 18, 217,
	355, 356, 153, 357, 358, 359, 360, 38, 361, 362, 199, 194, 363, 364, 365,
}
local GRAYS = { 199, 194, 1002, 325, 348, 26, 302, 311, 320, 335, 1001, 1 }

type Cell = { brick: BrickColor, center: Vector2 }

-- Cell centers inside the hexagon grid, filled row by row like Studio's.
local cells: { Cell } = {}
do
	local midRow = math.floor(GRID_ROWS / 2)
	local midCol = GRID_ROWS - 1
	for row = 0, GRID_ROWS - 1 do
		for col = 0, 2 * GRID_ROWS - 2 do
			local inside = math.abs(midRow - row) + math.abs(midCol - col) < GRID_ROWS
			if inside and row % 2 == col % 2 and #cells < #PALETTE then
				table.insert(cells, {
					brick = BrickColor.new(PALETTE[#cells + 1]),
					center = Vector2.new(col * STEP_X + HEX_W / 2, row * STEP_Y + HEX_H / 2),
				})
			end
		end
	end
end
local GRID_SIZE = Vector2.new((2 * GRID_ROWS - 2) * STEP_X + HEX_W, (GRID_ROWS - 1) * STEP_Y + HEX_H)

local grayCells: { Cell } = {}
do
	local step = math.floor((GRID_SIZE.X - HEX_W) / (#GRAYS - 1))
	local start = math.floor((GRID_SIZE.X - step * (#GRAYS - 1)) / 2)
	for i, number in GRAYS do
		table.insert(grayCells, {
			brick = BrickColor.new(number),
			center = Vector2.new(start + step * (i - 1), HEX_H / 2),
		})
	end
end

local MODES: { Mode } = { "RGB", "HSV", "Hex", "Brick" }
local MODE_ITEMS: { Dropdown.Item } = {}
for _, mode in MODES do
	table.insert(MODE_ITEMS, { Id = mode, Text = mode })
end

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 1, 1)),
	ColorSequenceKeypoint.new(1 / 6, Color3.fromHSV(1 / 6, 1, 1)),
	ColorSequenceKeypoint.new(2 / 6, Color3.fromHSV(2 / 6, 1, 1)),
	ColorSequenceKeypoint.new(3 / 6, Color3.fromHSV(3 / 6, 1, 1)),
	ColorSequenceKeypoint.new(4 / 6, Color3.fromHSV(4 / 6, 1, 1)),
	ColorSequenceKeypoint.new(5 / 6, Color3.fromHSV(5 / 6, 1, 1)),
	ColorSequenceKeypoint.new(1, Color3.fromHSV(1, 1, 1)),
})

-- The mode the picker last used, so Brick stays chosen for the next color.
local lastMode: Mode = "RGB"

local toHex = Format.hex

--[[
	A white pointy-top hexagon drawn once into an EditableImage and tinted per swatch, so the
	palette needs no uploaded image. Nil if EditableImage is unavailable (square swatches then).
]]
local hexagon: { image: EditableImage, content: Content }? = nil
local hexagonTried = false
local function hexagonContent(): Content?
	if hexagonTried then
		return if hexagon then hexagon.content else nil
	end
	hexagonTried = true
	local width, height = HEX_W * 4, HEX_H * 4
	local ok, image = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
	end)
	if not ok or not image then
		return nil
	end
	local halfW, halfH = width / 2, height / 2
	local pixels = buffer.create(width * height * 4)
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			-- Coverage from 4 x 4 samples, for smooth edges.
			local covered = 0
			for sy = 0, 3 do
				for sx = 0, 3 do
					local dx = math.abs(x + (sx + 0.5) / 4 - halfW)
					local dy = math.abs(y + (sy + 0.5) / 4 - halfH)
					if dx <= halfW and dy <= halfH - halfH / 2 * dx / halfW then
						covered += 1
					end
				end
			end
			local offset = (y * width + x) * 4
			buffer.writeu8(pixels, offset, 255)
			buffer.writeu8(pixels, offset + 1, 255)
			buffer.writeu8(pixels, offset + 2, 255)
			buffer.writeu8(pixels, offset + 3, math.round(covered / 16 * 255))
		end
	end
	image:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), pixels)
	local content = Content.fromObject(image)
	hexagon = { image = image, content = content }
	return content
end

local function swatch(content: Content?, center: Vector2, size: Vector2, color: Color3)
	if content then
		return e("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(center.X, center.Y),
			Size = UDim2.fromOffset(size.X, size.Y),
			BackgroundTransparency = 1,
			ImageContent = content,
			ImageColor3 = color,
		})
	end
	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(center.X, center.Y),
		Size = UDim2.fromOffset(size.X - 2, size.X - 2),
		BorderSizePixel = 0,
		BackgroundColor3 = color,
	})
end

-- The cell nearest to `point`, if the point is on it.
local function cellAt(list: { Cell }, point: Vector2): Cell?
	local best: Cell? = nil
	local bestDistance = HEX_W * 0.6
	for _, cell in list do
		local distance = (cell.center - point).Magnitude
		if distance < bestDistance then
			best, bestDistance = cell, distance
		end
	end
	return best
end

local function asInput(value: unknown): InputObject?
	if typeof(value) == "Instance" and value:IsA("InputObject") then
		return value
	end
	return nil
end

local function asGui(value: unknown): GuiObject?
	if typeof(value) == "Instance" and value:IsA("GuiObject") then
		return value
	end
	return nil
end

--[[
	Follows a mouse drag that starts on a GuiObject. Returns the InputBegan handler for that
	object and the capture element to render while dragging. `onMove` gets the drag position
	relative to the object, from 0 to 1 on each axis.
]]
local function useDrag(onMove: (Vector2) -> (), onDone: () -> ())
	local drag: { target: GuiObject, window: LayerCollector }?, setDrag =
		React.useState(nil :: { target: GuiObject, window: LayerCollector }?)
	local onMoveRef = React.useRef(onMove)
	local onDoneRef = React.useRef(onDone)
	onMoveRef.current = onMove
	onDoneRef.current = onDone

	local function report(target: GuiObject, x: number, y: number)
		local relative = (Vector2.new(x, y) - target.AbsolutePosition) / target.AbsoluteSize
		onMoveRef.current(Vector2.new(math.clamp(relative.X, 0, 1), math.clamp(relative.Y, 0, 1)))
	end

	local function onInputBegan(rbx: unknown, value: unknown)
		local target, input = asGui(rbx), asInput(value)
		if not target or not input or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		local window = target:FindFirstAncestorWhichIsA("LayerCollector")
		if not window then
			return
		end
		setDrag({ target = target, window = window })
		report(target, input.Position.X, input.Position.Y)
	end

	local capture = nil
	if drag then
		local function finish(_: unknown, _x: unknown, _y: unknown)
			setDrag(nil)
			onDoneRef.current()
		end
		capture = ReactRoblox.createPortal(
			e("TextButton", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
				ZIndex = 1000,
				[React.Event.MouseMoved] = function(_: unknown, x: unknown, y: unknown)
					if typeof(x) == "number" and typeof(y) == "number" then
						report(drag.target, x, y)
					end
				end,
				[React.Event.MouseButton1Up] = finish,
				-- Leaving the widget ends the drag, since its release would go unseen.
				[React.Event.MouseLeave] = finish,
			}),
			drag.window
		)
	end
	return onInputBegan, capture
end

local function ColorPicker(props: Props)
	local theme = StudioComponents.useTheme()
	local mode: Mode, setModeState = React.useState(lastMode)
	-- Hue, saturation and value (0 to 1). Kept here so a gray or black keeps its hue.
	local hsv, setHsv = React.useState(function()
		local h, s, v = (props.color or Color3.new(0.5, 0.5, 0.5)):ToHSV()
		return { h, s, v }
	end)
	local hsvRef = React.useRef(hsv)
	hsvRef.current = hsv
	local hoverBrick: BrickColor?, setHoverBrick = React.useState(nil :: BrickColor?)

	local current = Color3.fromHSV(hsv[1], hsv[2], hsv[3])
	local color = props.color

	-- Follow a color set from outside (another selection, undo), unless it is the one shown.
	local colorHex = if color then toHex(color) else ""
	React.useEffect(function()
		if color and toHex(Color3.fromHSV(hsv[1], hsv[2], hsv[3])) ~= colorHex then
			local h, s, v = color:ToHSV()
			setHsv({ h, s, v })
		end
	end, { colorHex })

	local function setMode(value: Mode)
		lastMode = value
		setModeState(value)
	end

	local function preview(values: { number })
		setHsv(values)
		hsvRef.current = values
		props.onPreview(Color3.fromHSV(values[1], values[2], values[3]))
	end
	local function commitShown()
		local values = hsvRef.current
		props.onCommit(Color3.fromHSV(values[1], values[2], values[3]))
	end
	local function commit(newColor: Color3)
		local h, s, v = newColor:ToHSV()
		-- A gray has no hue of its own; keep the current one.
		if s == 0 then
			h = hsv[1]
		end
		setHsv({ h, s, v })
		props.onCommit(newColor)
	end

	local squareInput, squareCapture = useDrag(function(point: Vector2)
		local values = hsvRef.current
		preview({ values[1], point.X, 1 - point.Y })
	end, commitShown)
	local hueInput, hueCapture = useDrag(function(point: Vector2)
		local values = hsvRef.current
		-- Stop just short of 1, which is red again.
		preview({ math.min(point.X, 0.999), values[2], values[3] })
	end, commitShown)

	local function numberBox(order: number, value: number, max: number, toColor: (number) -> Color3)
		return e(StudioComponents.NumericInput, {
			LayoutOrder = order,
			Size = UDim2.new(1 / 3, -GAP * 2 / 3, 1, 0),
			Value = value,
			Min = 0,
			Max = max,
			Step = 1,
			OnSubmitted = function(newValue: number)
				if newValue ~= value then
					commit(toColor(newValue))
				end
			end,
		})
	end

	local inputs: { [string]: unknown } = {
		Layout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, GAP),
		}),
	}
	if mode == "RGB" then
		local r, g, b = math.round(current.R * 255), math.round(current.G * 255), math.round(current.B * 255)
		inputs.R = numberBox(1, r, 255, function(n: number)
			return Color3.fromRGB(n, g, b)
		end)
		inputs.G = numberBox(2, g, 255, function(n: number)
			return Color3.fromRGB(r, n, b)
		end)
		inputs.B = numberBox(3, b, 255, function(n: number)
			return Color3.fromRGB(r, g, n)
		end)
	elseif mode == "HSV" then
		local h, s, v = math.round(hsv[1] * 360), math.round(hsv[2] * 100), math.round(hsv[3] * 100)
		inputs.H = numberBox(1, h, 360, function(n: number)
			return Color3.fromHSV((n % 360) / 360, s / 100, v / 100)
		end)
		inputs.S = numberBox(2, s, 100, function(n: number)
			return Color3.fromHSV(h / 360, n / 100, v / 100)
		end)
		inputs.V = numberBox(3, v, 100, function(n: number)
			return Color3.fromHSV(h / 360, s / 100, n / 100)
		end)
	elseif mode == "Hex" then
		local shown = toHex(current)
		inputs.Hex = e(StudioComponents.TextInput, {
			LayoutOrder = 1,
			Size = UDim2.fromScale(1, 1),
			Text = shown,
			OnChanged = function() end,
			OnFocusLost = function(text: string)
				local parsed = Format.parseColor(text)
				if parsed and toHex(parsed) ~= shown then
					commit(parsed)
				end
			end,
		})
	else
		-- The hovered color's name, or the nearest BrickColor to the current color.
		local brick = hoverBrick or BrickColor.new(current)
		inputs.Name = e(StudioComponents.Label, {
			LayoutOrder = 1,
			Size = UDim2.fromScale(1, 1),
			Text = if hoverBrick or not color or toHex(brick.Color) == toHex(current)
				then brick.Name
				else `{brick.Name} (nearest)`,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
	end

	local children: { [string]: unknown } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
		Inputs = e("Frame", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			BackgroundTransparency = 1,
		}, {
			Mode = e("Frame", {
				Size = UDim2.new(0, MODE_WIDTH, 1, 0),
				BackgroundTransparency = 1,
			}, {
				Dropdown = e(Dropdown, {
					Items = MODE_ITEMS,
					RowHeight = 20,
					SelectedItem = mode,
					OnItemSelected = function(id: string)
						for _, value: Mode in MODES do
							if value == id then
								setMode(value)
							end
						end
					end,
				}),
			}),
			Values = e("Frame", {
				Position = UDim2.fromOffset(MODE_WIDTH + GAP, 0),
				Size = UDim2.new(1, -MODE_WIDTH - GAP, 1, 0),
				BackgroundTransparency = 1,
			}, inputs),
		}),
	}

	if mode ~= "Brick" then
		local border = theme:GetColor(Enum.StudioStyleGuideColor.Border)
		children.Square = e("Frame", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, SQUARE_HEIGHT),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderColor3 = border,
			[React.Event.InputBegan] = squareInput,
		}, {
			-- White to the hue across, then transparent to black down.
			Hue = e("Frame", {
				Size = UDim2.fromScale(1, 1),
				BorderSizePixel = 0,
				BackgroundColor3 = Color3.fromHSV(hsv[1], 1, 1),
			}, {
				Gradient = e("UIGradient", {
					Transparency = NumberSequence.new(1, 0),
				}),
			}),
			Shade = e("Frame", {
				Size = UDim2.fromScale(1, 1),
				BorderSizePixel = 0,
				BackgroundColor3 = Color3.new(0, 0, 0),
			}, {
				Gradient = e("UIGradient", {
					Rotation = 90,
					Transparency = NumberSequence.new(1, 0),
				}),
			}),
			Knob = e("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(hsv[2], 1 - hsv[3]),
				Size = UDim2.fromOffset(KNOB, KNOB),
				BackgroundColor3 = current,
				ZIndex = 2,
			}, {
				Corner = e("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
				Stroke = e("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }),
			}),
			Capture = squareCapture,
		})
		children.HueBar = e("Frame", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, HUE_HEIGHT),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderColor3 = border,
			[React.Event.InputBegan] = hueInput,
		}, {
			Gradient = e("UIGradient", { Color = RAINBOW }),
			Marker = e("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(hsv[1], 0.5),
				Size = UDim2.new(0, 4, 1, 4),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BorderColor3 = Color3.new(0, 0, 0),
			}),
			Capture = hueCapture,
		})
	else
		local content = hexagonContent()
		local selectedHex = if color then toHex(current) else nil
		local outlineColor = theme:GetColor(Enum.StudioStyleGuideColor.DialogMainButton)
		local hexSize = Vector2.new(HEX_W, HEX_H)
		local outlineSize = Vector2.new(HEX_W + OUTLINE, HEX_H + OUTLINE)

		local function cellsElement(order: number, list: { Cell }, size: Vector2)
			local swatches: { [string]: unknown } = {}
			for i, cell in list do
				local brickColor = cell.brick.Color
				if selectedHex and toHex(brickColor) == selectedHex then
					swatches[`Outline{i}`] = swatch(content, cell.center, outlineSize, outlineColor)
				end
				swatches[`Cell{i}`] = swatch(content, cell.center, hexSize, brickColor)
			end
			-- One handler shape for all three events (the props table needs a single value type).
			return e("Frame", {
				LayoutOrder = order,
				Size = UDim2.fromOffset(size.X, size.Y),
				BackgroundTransparency = 1,
				[React.Event.InputBegan] = function(rbx: unknown, value: unknown)
					local frame, input = asGui(rbx), asInput(value)
					if frame and input and input.UserInputType == Enum.UserInputType.MouseButton1 then
						local cell = cellAt(list, Vector2.new(input.Position.X, input.Position.Y) - frame.AbsolutePosition)
						if cell then
							commit(cell.brick.Color)
						end
					end
				end,
				[React.Event.InputChanged] = function(rbx: unknown, value: unknown)
					local frame, input = asGui(rbx), asInput(value)
					if frame and input and input.UserInputType == Enum.UserInputType.MouseMovement then
						local cell = cellAt(list, Vector2.new(input.Position.X, input.Position.Y) - frame.AbsolutePosition)
						setHoverBrick(if cell then cell.brick else nil)
					end
				end,
				[React.Event.MouseLeave] = function(_: unknown, _value: unknown)
					setHoverBrick(nil)
				end,
			}, swatches)
		end

		children.Palette = cellsElement(2, cells, GRID_SIZE)
		children.Grays = cellsElement(3, grayCells, Vector2.new(GRID_SIZE.X, HEX_H))
	end

	return e("Frame", {
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, children)
end

return ColorPicker
