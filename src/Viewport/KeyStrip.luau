--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Click-through single-line shortcut bar pinned near the bottom of the 3D viewport, styled with
	Studio's active theme. Shared across viewport tools.
]]

local CoreGui = game:GetService("CoreGui")

export type KeyStrip = {
	-- Displays rich text `text`, or hides the strip when nil.
	show: (text: string?) -> (),
	destroy: () -> (),
}

local studio = settings().Studio

local KeyStrip = {}

KeyStrip.SEPARATOR = "   |   "

function KeyStrip.new(name: string): KeyStrip
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.DisplayOrder = 10
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -12)
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.fromOffset(0, 0)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 1
	frame.Active = false
	frame.Parent = gui

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = frame

	local label = Instance.new("TextLabel")
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.SourceSans
	label.TextSize = 14
	label.RichText = true
	label.Active = false
	label.Parent = frame

	local function applyTheme()
		local theme = studio.Theme
		frame.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
		frame.BorderColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Border)
		label.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	end

	applyTheme()

	local connection = studio.ThemeChanged:Connect(applyTheme)
	gui.Parent = CoreGui

	return {
		show = function (text: string?)
			if text then
				if label.Text ~= text then
					label.Text = text
				end

				gui.Enabled = true
			else
				gui.Enabled = false
			end
		end,

		destroy = function ()
			connection:Disconnect()
			gui:Destroy()
		end,
	}
end

return KeyStrip
