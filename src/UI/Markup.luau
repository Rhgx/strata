--!strict
--[[
	A small markdown-like markup for tooltips, turned into Roblox rich text:

		**bold**       bold
		*italic*       italic
		`Ctrl + Z`     a key or exact UI label, shown bold
		- item         a bullet line
		> note         a dimmed line (examples, Hammer names, side notes)
		(blank line)   a short gap between paragraphs

	Plain text passes through unchanged (with <, > and & escaped), so status messages and
	other unmarked strings are safe to show too.
]]

local Markup = {}

-- Height in pixels of the gap a blank line makes.
local GAP_SIZE = 6
local DIM_TRANSPARENCY = 0.35

local function escape(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function inline(text: string): string
	text = text:gsub("%*%*(.-)%*%*", "<b>%1</b>")
	text = text:gsub("`(.-)`", "<b>%1</b>")
	text = text:gsub("%*(.-)%*", "<i>%1</i>")
	return text
end

function Markup.toRichText(source: string): string
	local lines = {}
	for _, raw in source:split("\n") do
		local line = raw:gsub("%s+$", "")
		if line == "" then
			table.insert(lines, `<font size="{GAP_SIZE}"> </font>`)
		elseif line:sub(1, 2) == "> " then
			table.insert(lines, `<font transparency="{DIM_TRANSPARENCY}">{inline(escape(line:sub(3)))}</font>`)
		elseif line:sub(1, 2) == "- " then
			table.insert(lines, "\u{2022} " .. inline(escape(line:sub(3))))
		else
			table.insert(lines, inline(escape(line)))
		end
	end
	return table.concat(lines, "\n")
end

return Markup
