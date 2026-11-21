--!strict
--[[
	Copy appearance mode (the pipette on the tile page's Color row): hover any visible part,
	including other terrain tiles, and click it to copy its material, color and material variant
	onto the selected tiles. One click, one undo step, then the mode ends. Esc, another tool or
	clearing the tile selection cancels it.
]]

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.State.Status)
local Query = require(script.Parent.Parent.Scene.Query)
local Session = require(script.Parent.Parent.Scene.Session)
local Appearance = require(script.Parent.Parent.Actions.Appearance)
local KeyStrip = require(script.Parent.KeyStrip)

local RAY_LENGTH = 10000
-- Invisible parts (triggers, hitboxes) are looked through, up to this many.
local MAX_SKIPS = 8
local HOVER_COLOR = Color3.fromRGB(80, 160, 255)
local SEPARATOR = KeyStrip.SEPARATOR

-- Starts the tool; returns a function that stops it.
return function(plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local connections: { RBXScriptConnection } = {}
	local keyStrip = KeyStrip.new("StrataSampleHints")
	local hovered: BasePart? = nil
	local wasSampling = false

	local box = Instance.new("SelectionBox")
	box.Name = "StrataSampleHover"
	box.LineThickness = 0.04
	box.SurfaceTransparency = 1
	box.Color3 = HOVER_COLOR
	box.Parent = CoreGui

	local function stop()
		Settings.update(function(s)
			s.sampling = false
		end)
	end

	-- The visible part under the mouse (terrain tiles included), looking through invisible ones.
	local function partUnderMouse(): BasePart?
		local exclude: { Instance } = { workspace.Terrain }
		local ray = mouse.UnitRay
		for _ = 1, MAX_SKIPS do
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = exclude
			local hit = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
			if not hit then
				return nil
			end
			if hit.Instance.Transparency >= 0.99 then
				table.insert(exclude, hit.Instance)
				continue
			end
			return hit.Instance
		end
		return nil
	end

	local function describe(part: BasePart): string
		local label = Appearance.label(part.Material)
		return if part.MaterialVariant ~= "" then `{label} ({part.MaterialVariant})` else label
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function()
			local state = Settings.get()
			if not state.sampling then
				return
			end
			local tiles = #Query.selectedModels()
			if tiles == 0 then
				stop()
				return
			end
			local part = partUnderMouse()
			hovered = part
			-- Highlight the whole tile when hovering terrain, otherwise the part.
			local tile = if part then Query.displacementOf(part) else nil
			box.Adornee = tile or part
			local text: string
			if part then
				local plural = if tiles == 1 then "1 tile" else `{tiles} tiles`
				text = table.concat({ `<b>{part.Name}</b>`, describe(part), `Click: Apply to {plural}`, "Esc: Cancel" }, SEPARATOR)
			else
				text = table.concat({ "<b>Copy appearance</b>", "Click any part or tile", "Esc: Cancel" }, SEPARATOR)
			end
			keyStrip.show(if state.showKeyHints then text else nil)
		end)
	)

	table.insert(
		connections,
		mouse.Button1Down:Connect(function()
			local part = hovered
			if not Settings.get().sampling or not part then
				return
			end
			if Session.isBaking() then
				Status.post("warning", "Still baking the last edits. Try again in a moment.")
				return
			end
			local ok, result = pcall(Appearance.copyFrom, part)
			if not ok then
				Status.post("error", `Copy failed: {result}`)
			elseif result == 0 then
				Status.post("warning", `The selected tiles already look like {part.Name}.`)
			else
				local plural = if result == 1 then "1 tile" else `{result} tiles`
				Status.post("success", `Copied {describe(part)} from {part.Name} to {plural}.`)
			end
			stop()
		end)
	)

	local unsubscribe = Settings.subscribe(function(state)
		if state.sampling == wasSampling then
			return
		end
		wasSampling = state.sampling
		if not state.sampling then
			hovered = nil
			box.Adornee = nil
			keyStrip.show(nil)
		end
	end)

	return function()
		unsubscribe()
		for _, connection in connections do
			connection:Disconnect()
		end
		box:Destroy()
		keyStrip.destroy()
	end
end
