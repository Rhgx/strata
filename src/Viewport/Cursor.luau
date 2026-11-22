--!strict
--[[
	What the running tool says about the mouse, for the cursor. Tools set a hint every frame;
	Activation owns mouse.Icon and turns the hint, the running tool and baking into one icon
	(see Activation for the order). The hint is cleared whenever the tool changes, so a tool that
	stopped can never leave its cursor behind.

	- "resize": an Alt + Drag resize is running.
	- "empty": the tool has nothing to act on (no terrain, or Selected only with none selected).
	- "valid" / "invalid": a click tool (Pick faces, Stitch, Sample, the Material pipette) is over
	  something it can or cannot use.
]]

export type Hint = "resize" | "empty" | "valid" | "invalid"

local hint: Hint? = nil

local Cursor = {}

function Cursor.set(value: Hint?)
	hint = value
end

function Cursor.get(): Hint?
	return hint
end

return Cursor
