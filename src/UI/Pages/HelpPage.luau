--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Read-only reference overlay opened from the status bar's ? button, organized into Guide,
	Keys, and About tabs matching SettingsPage's pinned overlay shell.
]]

local UI = script.Parent.Parent
local Plugin = UI.Parent
local State = Plugin.State
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Version = require(Plugin.Version)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Rows = require(UI.Rows)
local Icons = require(UI.Icons)
local Accent = require(UI.Accent)

local e = React.createElement

type Tab = "guide" | "keys" | "about"

type Entry = {
	key: string,
	action: string,
	icon: Icons.Icon?,
}

type WorkflowStep = {
	verb: string,
	text: string,
	icon: Icons.Icon,
	tool: Settings.Tool?,
}

local TABS: { Rows.Tab<Tab> } = {
	{ id = "guide", label = "Guide", tip = "**Workflow and tile actions**: how Strata fits together." },
	{ id = "keys", label = "Keys", tip = "**Keyboard and mouse shortcuts** for every tool." },
	{ id = "about", label = "About", tip = "**Version**, license, and author." },
}

-- Leaves ~102 px for action labels at the minimum panel width, fitting every entry cleanly.
local KEY_WIDTH = 88
local KEY_GAP = 6
local KEY_ROW_HEIGHT = 18
local AVATAR_SIZE = 32
local AUTHOR_USER_ID = 1552585752
local AUTHOR_AVATAR = `rbxthumb://type=AvatarHeadShot&id={AUTHOR_USER_ID}&w=100&h=100`
local SOURCE_URL = "github.com/Rhgx/strata"

-- Persists the active Help tab for the current Studio session.
local lastTab: Tab = "guide"

local WORKFLOW_STEPS: { WorkflowStep } = {
	{ verb = "Create", text = "Select block or wedge parts and click Create, or use Pick faces.", icon = Icons.CreateArea },
	{ verb = "Sculpt", text = "Use Raise, Lower, Smooth or Raise To, then drag on terrain.", icon = Icons.Raise, tool = "Raise" },
	{ verb = "Paint", text = "Paint materials and colors onto tiles with Material.", icon = Icons.Material, tool = "Material" },
	{ verb = "Mesh", text = "Simplify flat ground or cut holes with the Mesh tool.", icon = Icons.Mesh, tool = "Mesh" },
	{ verb = "Edit", text = "Select tiles to change Detail, Material and the actions below.", icon = Icons.EditTiles },
	{ verb = "Stitch", text = "Snap tile edges onto roads, floors or walls.", icon = Icons.StitchTiles },
	{ verb = "Bake", text = "Tiles merge into unions when a tool stops, or click Bake.", icon = Icons.BakeTiles },
}

local TILE_ACTIONS: { Entry } = {
	{ key = "Add nearby", action = "Grow selection", icon = Icons.Select },
	{ key = "Edit points", action = "Move or delete", icon = Icons.EditPoints },
	{ key = "Round folds", action = "Round sharp folds", icon = Icons.RoundFolds },
	{ key = "Split 2x2", action = "4 tiles, same shape", icon = Icons.SplitTiles },
	{ key = "Sew tiles", action = "Close seams", icon = Icons.SewTiles },
	{ key = "Stitch parts", action = "Snap edges to parts", icon = Icons.StitchTiles },
	{ key = "Noise", action = "Random bumps", icon = Icons.Noise },
	{ key = "Reset shape", action = "Flatten selected tiles", icon = Icons.ResetShape },
	{ key = "Bake", action = "Merge into unions", icon = Icons.BakeTiles },
}

-- Shortcuts shared across all tools.
local COMMON_KEYS: { Entry } = {
	{ key = "Ctrl + Scroll", action = "Resize or Reach" },
	{ key = "[ and ]", action = "Resize or Reach" },
	{ key = "Alt + Drag", action = "Resize brush" },
	{ key = "Esc", action = "Stop tool or clear" },
	{ key = "Ctrl + Z", action = "Undo a step" },
}

local SCULPT_KEYS: { Entry } = {
	{ key = "Left Drag", action = "Paint" },
	{ key = "Ctrl", action = "Invert brush" },
	{ key = "Shift", action = "Smooth" },
	{ key = "Ctrl + Click", action = "Pick height" },
	{ key = "Alt + Right Click", action = "Pick axis" },
}

local MATERIAL_KEYS: { Entry } = {
	{ key = "Left Drag", action = "Paint look" },
	{ key = "Ctrl", action = "Erase or paint" },
	{ key = "Alt + Right Click", action = "Pick look" },
}

local MESH_KEYS: { Entry } = {
	{ key = "Left Drag", action = "Mark or cut" },
	{ key = "Ctrl", action = "Restore" },
	{ key = "Click", action = "Toggle a point" },
	{ key = "Enter or X", action = "Apply marks" },
	{ key = "Esc", action = "Clear marks" },
}

local PICK_KEYS: { Entry } = {
	{ key = "Click a face", action = "Pick or unpick" },
	{ key = "Enter", action = "Create tiles" },
	{ key = "Esc", action = "Clear picks" },
}

local STITCH_KEYS: { Entry } = {
	{ key = "Click a part", action = "Stitch its edges" },
}

local POINTS_KEYS: { Entry } = {
	{ key = "Click or box", action = "Select points" },
	{ key = "Ctrl + Click", action = "Add or remove" },
	{ key = "Studio tools", action = "Move points" },
	{ key = "Delete", action = "Remove points" },
	{ key = "Pivot > Origin", action = "Exact position" },
}

local function iconImage(icon: Icons.Icon, color: Color3, position: UDim2, anchor: Vector2?)
	return e("ImageLabel", {
		AnchorPoint = anchor,
		Position = position,
		Size = UDim2.fromOffset(14, 14),
		BackgroundTransparency = 1,
		Image = icon.Image,
		ImageRectOffset = icon.RectOffset,
		ImageRectSize = icon.RectSize,
		ImageColor3 = color,
	})
end

local function stepRow(layoutOrder: number, step: WorkflowStep, theme: StudioTheme)
	local tint = if step.tool then Accent.tool(step.tool, theme) else nil
	local iconColor = tint or theme:GetColor(Enum.StudioStyleGuideColor.MainText)

	return e("Frame", {
		LayoutOrder = layoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, {
		Icon = iconImage(step.icon, iconColor, UDim2.fromOffset(0, 2)),

		Text = e("TextLabel", {
			Position = UDim2.fromOffset(20, 0),
			Size = UDim2.new(1, -20, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Text = `<b>{step.verb}</b>: {step.text}`,
			RichText = true,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Font = StudioComponents.Constants.DefaultFont,
			TextSize = StudioComponents.Constants.DefaultTextSize,
			TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText),
		}),
	})
end

local function entryRow(layoutOrder: number, entry: Entry, iconColor: Color3)
	local offset = if entry.icon then 18 else 0

	return e("Frame", {
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, KEY_ROW_HEIGHT),
		BackgroundTransparency = 1,
	}, {
		Icon = if entry.icon
			then iconImage(entry.icon, iconColor, UDim2.new(0, 0, 0.5, 0), Vector2.new(0, 0.5))
			else nil,

		Key = e(StudioComponents.Label, {
			Position = UDim2.fromOffset(offset, 0),
			Size = UDim2.new(0, KEY_WIDTH - KEY_GAP - offset, 1, 0),
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

local function entryTable(layoutOrder: number, entries: { Entry }, iconColor: Color3)
	local rows: { [string]: unknown } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 2),
		}),
	}

	for index, entry in entries do
		rows[`Row{index}`] = entryRow(index, entry, iconColor)
	end

	return e("Frame", {
		LayoutOrder = layoutOrder,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, rows)
end

-- Read-only selectable TextBox styled as a Studio link so clicking selects the URL for Ctrl + C.
local function CopyField(props: { text: string })
	local theme = StudioComponents.useTheme()

	return e("TextBox", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = props.text,
		TextEditable = false,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = StudioComponents.Constants.DefaultFont,
		TextSize = StudioComponents.Constants.DefaultTextSize,
		TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.LinkText),

		[React.Event.Focused] = function (box: TextBox)
			-- Defer so the click's own cursor placement does not clear the selection.
			task.defer(function ()
				if box.Parent then
					box.CursorPosition = #box.Text + 1
					box.SelectionStart = 1
				end
			end)
			Status.post("success", "Link selected. Press Ctrl + C to copy.")
		end,
	})
end

-- Compact author identity row with a circular Roblox avatar, online alias, and Roblox handle.
local function AuthorRow(props: { LayoutOrder: number })
	local theme = StudioComponents.useTheme()

	return e("Frame", {
		LayoutOrder = props.LayoutOrder,
		Size = UDim2.new(1, 0, 0, AVATAR_SIZE),
		BackgroundTransparency = 1,
	}, {
		Avatar = e("ImageLabel", {
			Size = UDim2.fromOffset(AVATAR_SIZE, AVATAR_SIZE),
			BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.InputFieldBackground),
			BorderSizePixel = 0,
			Image = AUTHOR_AVATAR,
		}, {
			Corner = e("UICorner", {
				CornerRadius = UDim.new(0.5, 0),
			}),
		}),

		Name = e(StudioComponents.Label, {
			Position = UDim2.fromOffset(AVATAR_SIZE + 8, 0),
			Size = UDim2.new(1, -(AVATAR_SIZE + 8), 0, 16),
			Text = "<b>Rocks</b>",
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),

		Handle = e(StudioComponents.Label, {
			Position = UDim2.fromOffset(AVATAR_SIZE + 8, 16),
			Size = UDim2.new(1, -(AVATAR_SIZE + 8), 0, 16),
			Text = "@Robloxian649857",
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColorStyle = Enum.StudioStyleGuideColor.DimmedText,
		}),
	})
end

local function guideTab(theme: StudioTheme)
	local mainColor = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	local steps: { [string]: unknown } = {
		Layout = e("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	}

	for index, step in WORKFLOW_STEPS do
		steps[`Step{index}`] = stepRow(index, step, theme)
	end

	return {
		WorkflowHeading = Rows.section(1, "Workflow", true),

		Workflow = e("Frame", {
			LayoutOrder = 2,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, steps),

		ActionsHeading = Rows.section(3, "Tile actions"),
		Actions = entryTable(4, TILE_ACTIONS, mainColor),
		TipDivider = Rows.divider(5),
		Tip = Rows.paragraph(6, "Hover any control for details. The gear opens Settings.", "dimmed"),
	}
end

local function keyGroup(
	layoutOrder: number,
	id: string,
	title: string,
	entries: { Entry },
	icon: Icons.Icon,
	iconColor: Color3?,
	mainColor: Color3,
	detail: string?
)
	local tooltip = if detail
		then `{detail}\n\n> Click to show or hide.`
		else `**{title} shortcuts.**\n\n> Click to show or hide.`

	return Rows.collapsible(layoutOrder, id, title, tooltip, {
		Table = entryTable(1, entries, mainColor),
	}, icon, iconColor)
end

local function keysTab(theme: StudioTheme)
	local mainColor = theme:GetColor(Enum.StudioStyleGuideColor.MainText)

	return {
		CommonHeading = Rows.section(1, "Every tool", true),
		CommonKeys = entryTable(2, COMMON_KEYS, mainColor),

		Sculpt = keyGroup(
			3,
			"help-sculpt",
			"Sculpt brushes",
			SCULPT_KEYS,
			Icons.Raise,
			Accent.tool("Raise", theme),
			mainColor,
			"`Ctrl + Click` is for `Raise To`; in `From: World` it reads any visible part. Click the sky with `Alt + Right Click` to reset to `Up (Y)`."
		),

		Material = keyGroup(
			4,
			"help-material",
			"Material",
			MATERIAL_KEYS,
			Icons.Material,
			Accent.tool("Material", theme),
			mainColor,
			"`Ctrl` swaps `Paint` and `Erase` while held."
		),

		Mesh = keyGroup(
			5,
			"help-mesh",
			"Mesh",
			MESH_KEYS,
			Icons.Mesh,
			Accent.tool("Mesh", theme),
			mainColor,
			"`Click`, `Enter` and `X` apply in `Simplify` mode."
		),

		Pick = keyGroup(6, "help-pick", "Pick faces", PICK_KEYS, Icons.PickFaces, nil, mainColor),
		Stitch = keyGroup(7, "help-stitch", "Stitch", STITCH_KEYS, Icons.Stitch, nil, mainColor, "Distance is `Reach`."),

		Points = keyGroup(
			8,
			"help-points",
			"Edit points",
			POINTS_KEYS,
			Icons.EditPoints,
			nil,
			mainColor,
			"Use Studio's `Move`, `Rotate` and `Scale`. Tile corners always stay. Each drag is one undo step."
		),

		CustomHeading = Rows.section(9, "Custom shortcuts"),
		Custom = Rows.paragraph(
			10,
			"Bind any tool or Edit points in File > Advanced > Customize Shortcuts. Search for Strata.",
			"dimmed"
		),
	}
end

local function aboutTab()
	return {
		StrataHeading = Rows.section(1, "Strata", true),
		Version = Rows.value(2, "Version", Version, nil, "**Installed plugin version.**"),

		License = Rows.value(
			3,
			"License",
			"GPL-3.0",
			nil,
			"**GNU General Public License v3 or later.**\n\nFree to use, modify and share under the same license."
		),

		Source = Rows.property(
			4,
			"Source",
			e(CopyField, { text = SOURCE_URL }),
			"**Source code.** Click to select, then press `Ctrl + C`."
		),

		BetaNote = Rows.paragraph(5, "Beta build: back up places before updating.", "dimmed"),
		AuthorHeading = Rows.section(6, "Author"),
		Author = e(AuthorRow, { LayoutOrder = 7 }),
	}
end

local function HelpPage()
	local theme = StudioComponents.useTheme()
	local tab, setTab = React.useState(lastTab)
	local content = if tab == "guide" then guideTab(theme) elseif tab == "keys" then keysTab(theme) else aboutTab()

	return Rows.overlay("Help", function ()
		Settings.setOverlay("none")
	end, "**Close help** (`Esc`).", TABS, tab, function (nextTab: Tab)
		lastTab = nextTab
		setTab(nextTab)
	end, content)
end

return HelpPage
