--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later

local Root = script.Parent.Parent.Parent

local JestGlobals = require(Root.DevPackages.JestGlobals)
local Markup = require(Root.Plugin.UI.Markup)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

describe("Markup.toRichText", function ()
	it("replaces spaces inside code spans with non-breaking spaces so shortcuts do not split", function ()
		local rich = Markup.toRichText("Press `Ctrl + C` or `Alt + Right Click`.")

		expect(rich).toBe("Press <b>Ctrl\u{00A0}+\u{00A0}C</b> or <b>Alt\u{00A0}+\u{00A0}Right\u{00A0}Click</b>.")
	end)

	it("keeps regular spaces inside bold phrases and escapes XML characters", function ()
		local rich = Markup.toRichText("**Source code** <test> & `Raise To`")

		expect(rich).toBe("<b>Source code</b> &lt;test&gt; &amp; <b>Raise\u{00A0}To</b>")
	end)
end)
