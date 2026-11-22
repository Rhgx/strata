--!strict
--[[
	Text formatting helpers for the panel, status messages, and 3D labels:
	natural plurals instead of "(s)", stud lengths, and color strings.
]]

local Format = {}

-- Formats a Color3 as "#RRGGBB".
function Format.hex(color: Color3): string
	return string.format("#%02X%02X%02X", math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255))
end

-- Parses #RRGGBB, RRGGBB, #RGB, or "R, G, B" (the format copied from Studio's Properties window).
-- Returns nil if the input does not match any supported format.
function Format.parseColor(text: string): Color3?
	local trimmed = text:gsub("%s", "")
	local r, g, b = trimmed:match("^(%d+),(%d+),(%d+)$")

	if r and g and b then
		local rn, gn, bn = tonumber(r), tonumber(g), tonumber(b)

		if rn and gn and bn and rn <= 255 and gn <= 255 and bn <= 255 then
			return Color3.fromRGB(rn, gn, bn)
		end

		return nil
	end

	local hex = trimmed:gsub("^#", "")

	if #hex == 3 then
		hex = hex:gsub(".", "%0%0")
	end

	if #hex == 6 and hex:match("^%x+$") then
		local value = tonumber(hex, 16)

		if value then
			return Color3.fromRGB(bit32.rshift(value, 16), bit32.band(bit32.rshift(value, 8), 255), bit32.band(value, 255))
		end
	end

	return nil
end

-- Formats an integer with thousands separators (e.g. 12345 -> "12,345").
function Format.count(n: number): string
	local formatted = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()

	return (formatted:gsub("^,", ""))
end

-- Formats a length in studs, showing one decimal place only for fractional values (8 -> "8", 2.25 -> "2.3").
function Format.studs(value: number): string
	return if value == math.floor(value) then tostring(value) else string.format("%.1f", value)
end

-- Formats a count with a singular or plural noun (e.g. (1, "tile") -> "1 tile", (3, "tile") -> "3 tiles").
function Format.plural(n: number, one: string, many: string?): string
	return `{Format.count(n)} {if n == 1 then one else (many or one .. "s")}`
end

return Format
