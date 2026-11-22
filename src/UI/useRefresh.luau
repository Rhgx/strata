--!strict
--[[
	React hook that triggers a re-render whenever the Studio selection changes, a status message
	is posted (including operation completions), or undo/redo runs, keeping derived selection and
	tile counts current.
]]

local Selection = game:GetService("Selection")
local CollectionService = game:GetService("CollectionService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Plugin = script.Parent.Parent
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)

local TerrainInstance = require(Plugin.Core.TerrainInstance)
local Status = require(Plugin.State.Status)
local Session = require(Plugin.Scene.Session)

local function useRefresh(): number
	local version, setVersion = React.useState(0)

	React.useEffect(function ()
		local mounted = true

		local function bump()
			if not mounted then
				return
			end

			setVersion(function (v: number)
				return v + 1
			end)
		end

		local function onWorkspaceAdded(inst: Instance)
			if inst:IsA("Model") and CollectionService:HasTag(inst, TerrainInstance.TAG) then
				bump()
			end
		end

		local function onWorkspaceRemoving(inst: Instance)
			if inst:IsA("Model") and CollectionService:HasTag(inst, TerrainInstance.TAG) then
				-- DescendantRemoving fires before Parent changes; defer so IsDescendantOf(workspace) is updated.
				task.defer(bump)
			end
		end

		local connections = {
			Selection.SelectionChanged:Connect(bump),
			ChangeHistoryService.OnUndo:Connect(bump),
			ChangeHistoryService.OnRedo:Connect(bump),
			CollectionService:GetInstanceAddedSignal(TerrainInstance.TAG):Connect(bump),
			CollectionService:GetInstanceRemovedSignal(TerrainInstance.TAG):Connect(bump),
			workspace.DescendantAdded:Connect(onWorkspaceAdded),
			workspace.DescendantRemoving:Connect(onWorkspaceRemoving),
		}
		local unsubscribeStatus = Status.subscribe(function (message: Status.Message?)
			-- StatusBar listens to Status directly, so progress ticks do not need to re-scan the scene.
			if message and message.kind == "progress" then
				return
			end

			bump()
		end)
		local unsubscribeSession = Session.onChanged(bump)

		return function ()
			mounted = false

			for _, connection in connections do
				connection:Disconnect()
			end

			unsubscribeStatus()
			unsubscribeSession()
		end
	end, {})

	return version
end

return useRefresh
