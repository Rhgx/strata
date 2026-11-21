--!strict
local React = require(script.Parent.Parent.Parent.Packages.React)

local Settings = require(script.Parent.Parent.State.Settings)

-- Re-renders the component whenever the shared tool settings change.
local function useSettings(): Settings.State
	local state, setState = React.useState(Settings.get())
	React.useEffect(function()
		return Settings.subscribe(function(nextState)
			setState(nextState)
		end)
	end, {})
	return state
end

return useSettings
