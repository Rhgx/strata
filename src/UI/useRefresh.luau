--!strict
--[[
	Re-renders the component when the Studio selection changes, a new status message is posted
	(operations post one when they finish), or the user undoes or redoes, so derived values such
	as selection and tile counts stay current.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

local React = require(script.Parent.Parent.Parent.Packages.React)

local Status = require(script.Parent.Parent.State.Status)

local function useRefresh()
	local _, setVersion = React.useState(0)
	React.useEffect(function()
		local function bump()
			setVersion(function(v: number)
				return v + 1
			end)
		end
		local connections = {
			Selection.SelectionChanged:Connect(bump),
			ChangeHistoryService.OnUndo:Connect(bump),
			ChangeHistoryService.OnRedo:Connect(bump),
		}
		local unsubscribe = Status.subscribe(function()
			bump()
		end)
		return function()
			for _, connection in connections do
				connection:Disconnect()
			end
			unsubscribe()
		end
	end, {})
end

return useRefresh
