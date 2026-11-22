--!strict
--[[
	React hook that triggers a re-render whenever the Studio selection changes, a status message
	is posted (including operation completions), or undo/redo runs, keeping derived selection and
	tile counts current.
]]

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Plugin = script.Parent.Parent
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)

local Status = require(Plugin.State.Status)

local function useRefresh()
	local _, setVersion = React.useState(0)

	React.useEffect(function ()
		local function bump()
			setVersion(function (v: number)
				return v + 1
			end)
		end

		local connections = {
			Selection.SelectionChanged:Connect(bump),
			ChangeHistoryService.OnUndo:Connect(bump),
			ChangeHistoryService.OnRedo:Connect(bump),
		}
		local unsubscribe = Status.subscribe(function ()
			bump()
		end)

		return function ()
			for _, connection in connections do
				connection:Disconnect()
			end

			unsubscribe()
		end
	end, {})
end

return useRefresh
