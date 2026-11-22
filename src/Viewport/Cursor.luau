--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Cursor hint channel shared between viewport tools and Viewport/Activation. Tools report their
	per-frame state here; Activation owns mouse.Icon and combines the hint, active tool, and
	baking status into one icon. Activation clears the hint on every tool switch so a stopped
	tool never leaves stale cursor state behind.

	Hints:
	- "resize": an Alt + Drag resize is in progress.
	- "empty": the tool has no targets (no terrain, or Selected only with none selected).
	- "valid" / "invalid": a click tool (Pick faces, Stitch, Sample, Material pipette) is over
	  a usable or unusable target.
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
