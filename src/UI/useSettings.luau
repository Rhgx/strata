--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	React hook that subscribes a component to shared tool settings in State/Settings.
]]

local Plugin = script.Parent.Parent
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)

local Settings = require(Plugin.State.Settings)

local function useSettings(): Settings.State
	local state, setState = React.useState(Settings.get())

	React.useEffect(function ()
		return Settings.subscribe(function (nextState)
			setState(nextState)
		end)
	end, {})

	return state
end

return useSettings
