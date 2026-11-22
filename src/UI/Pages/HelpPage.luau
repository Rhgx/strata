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

-- Leaves about 96 px for the action at the minimum panel width; every action fits in that.
local KEY_WIDTH = 88
local KEY_GAP = 6
local KEY_ROW_HEIGHT = 18

type KeyHint = {
	key: string,
	action: string,
}

local QUICK_START = table.concat({
	"1. <b>Create</b>: select block or wedge parts and click Create, or use Pick faces.",
	"2. <b>Sculpt</b>: pick a brush in the strip above and drag on terrain. The Material tool paints roads and patches.",
	"3. <b>Edit</b>: select tiles to change detail, round, split, sew or bake.",
	"4. <b>Stitch</b>: snap terrain edges onto roads, floors or walls.",
}, "\n")

-- Keys that work the same in every tool, listed once.
local COMMON_KEYS: { KeyHint } = {
	{ key = "Ctrl + Scroll", action = "Resize or Reach" },
	{ key = "[ and ]", action = "Resize or Reach" },
	{ key = "Alt + Drag", action = "Resize brush" },
	{ key = "Esc", action = "Stop tool" },
	{ key = "Ctrl + Z", action = "Undo a step" },
}

local PAINT_KEYS: { KeyHint } = {
	{ key = "Left Drag", action = "Paint" },
	{ key = "Ctrl", action = "Invert brush" },
	{ key = "Shift", action = "Smooth" },
	{ key = "Ctrl + Click", action = "Pick height" },
	{ key = "Alt + Right Click", action = "Pick axis" },
}

local MATERIAL_KEYS: { KeyHint } = {
	{ key = "Left Drag", action = "Paint material" },
	{ key = "Ctrl", action = "Erase" },
	{ key = "Alt + Right Click", action = "Pick look" },
}

local MESH_KEYS: { KeyHint } = {
	{ key = "Left Drag", action = "Mark or cut" },
	{ key = "Ctrl", action = "Restore" },
	{ key = "Click", action = "Toggle a point" },
	{ key = "Enter or X", action = "Apply marks" },
	{ key = "Esc", action = "Clear marks first" },
}

local STITCH_KEYS: { KeyHint } = {
	{ key = "Click a part", action = "Stitch its edges" },
}

local PICK_KEYS: { KeyHint } = {
	{ key = "Click a face", action = "Pick or unpick" },
	{ key = "Enter", action = "Create" },
	{ key = "Esc", action = "Clear picks first" },
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
		CommonHeading = Rows.section(4, "Every tool"),
		CommonKeys = keyTable(5, COMMON_KEYS),
		PaintHeading = Rows.section(6, "Sculpt brushes"),
		PaintKeys = keyTable(7, PAINT_KEYS),
		MaterialHeading = Rows.section(8, "Material"),
		MaterialKeys = keyTable(9, MATERIAL_KEYS),
		MeshHeading = Rows.section(10, "Mesh"),
		MeshKeys = keyTable(11, MESH_KEYS),
		StitchHeading = Rows.section(12, "Stitch"),
		StitchKeys = keyTable(13, STITCH_KEYS),
		PickHeading = Rows.section(14, "Pick faces"),
		PickKeys = keyTable(15, PICK_KEYS),
		TipDivider = Rows.divider(16),
		Tip = Rows.paragraph(17, "Hover any control for details. The gear opens Settings.", "dimmed"),
	})
end

return HelpPage
