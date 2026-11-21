--!strict
--[[
	Quick reference, opened from the ? button in the status bar. Read only and kept brief so it
	fits on one screen alongside tooltips and the status line.
]]

local Packages = script.Parent.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(script.Parent.Parent.Parent.State.Settings)
local Rows = require(script.Parent.Parent.Rows)

local e = React.createElement

-- Leaves about 84 px for the action at the minimum panel width; every action fits in that.
local KEY_WIDTH = 100
local KEY_GAP = 6
local KEY_ROW_HEIGHT = 18

type KeyHint = {
	key: string,
	action: string,
}

local QUICK_START = table.concat({
	"1. <b>Create</b>: select block or wedge parts and click Create, or use Pick faces.",
	"2. <b>Sculpt</b>: pick a brush in the strip above and drag on terrain.",
	"3. <b>Edit</b>: select tiles to change detail, round, split, sew or bake.",
	"4. <b>Stitch</b>: snap terrain edges onto roads, floors or walls.",
}, "\n")

local PAINT_KEYS: { KeyHint } = {
	{ key = "Left Drag", action = "Paint" },
	{ key = "Ctrl", action = "Invert brush" },
	{ key = "Ctrl + Click", action = "Pick height (Raise To)" },
	{ key = "Shift", action = "Smooth" },
	{ key = "Ctrl + Scroll", action = "Resize brush" },
	{ key = "Alt + Drag", action = "Resize brush" },
	{ key = "Alt + Right Click", action = "Pick axis" },
	{ key = "Esc", action = "Stop tool" },
}

local STITCH_KEYS: { KeyHint } = {
	{ key = "Left Click", action = "Stitch part" },
	{ key = "Ctrl + Scroll", action = "Change reach" },
	{ key = "Esc", action = "Stop tool" },
}

local PICK_KEYS: { KeyHint } = {
	{ key = "Left Click", action = "Pick or unpick" },
	{ key = "Esc", action = "Stop tool" },
}

-- Single-line key/action row built from plain host Frames and Labels.
local function keyRow(layoutOrder: number, entry: KeyHint)
	return e("Frame", {
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, KEY_ROW_HEIGHT),
		BackgroundTransparency = 1,
	}, {
		Key = e(StudioComponents.Label, {
			Size = UDim2.new(0, KEY_WIDTH - KEY_GAP, 1, 0),
			Text = `<b>{entry.key}</b>`,
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),
		Action = e(StudioComponents.Label, {
			Position = UDim2.fromOffset(KEY_WIDTH, 0),
			Size = UDim2.new(1, -KEY_WIDTH, 1, 0),
			Text = entry.action,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),
	})
end

-- A list of key rows.
local function keyTable(layoutOrder: number, keys: { KeyHint })
	local rows: { [string]: unknown } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
	}
	for index, entry in keys do
		rows[`Row{index}`] = keyRow(index, entry)
	end
	return e("Frame", {
		LayoutOrder = layoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, rows)
end

local function HelpPage()
	return Rows.page({
		Header = Rows.header(1, "Help", function()
			Settings.setOverlay("none")
		end, "**Close help** (`Esc`)."),
		QuickStartHeading = Rows.section(2, "Quick start"),
		QuickStart = Rows.paragraph(3, QUICK_START),
		PaintHeading = Rows.section(4, "Paint shortcuts"),
		PaintKeys = keyTable(5, PAINT_KEYS),
		StitchHeading = Rows.section(6, "Stitch shortcuts"),
		StitchKeys = keyTable(7, STITCH_KEYS),
		PickHeading = Rows.section(8, "Pick faces shortcuts"),
		PickKeys = keyTable(9, PICK_KEYS),
		BracketNote = Rows.paragraph(10, "[ and ] also resize the brush or change reach.", "dimmed"),
		TipDivider = Rows.divider(11),
		Tip = Rows.paragraph(12, "Hover any control for details. Ctrl + Z undoes each step. The gear opens Settings.", "dimmed"),
	})
end

return HelpPage
