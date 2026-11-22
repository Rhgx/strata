--!strict
--[[
	Copy appearance viewport mode (pipette on the Tiles page Color row): hover any visible part
	or terrain tile and click to copy its material, color, and material variant onto the selected
	tiles in a single undo step, then exit. Esc, switching tools, or clearing the tile selection
	cancels the mode.
]]

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local Viewport = script.Parent
local Plugin = Viewport.Parent
local State = Plugin.State
local Scene = Plugin.Scene

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Appearance = require(Plugin.Actions.Appearance)

local Cursor = require(Viewport.Cursor)
local KeyStrip = require(Viewport.KeyStrip)
local VisibleHit = require(Viewport.VisibleHit)

local HOVER_COLOR = Color3.fromRGB(80, 160, 255)
local SEPARATOR = KeyStrip.SEPARATOR

-- Starts the copy-appearance sampler and returns a cleanup callback.
return function (plugin: Plugin): () -> ()
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
		Settings.update(function (s)
			s.sampling = false
		end)
	end

	local function partUnderMouse(): BasePart?
		local hit = VisibleHit.cast(mouse.UnitRay, { workspace.Terrain })

		return if hit then hit.Instance else nil
	end

	local function describe(part: BasePart): string
		local label = Appearance.label(part.Material)

		return if part.MaterialVariant ~= "" then `{label} ({part.MaterialVariant})` else label
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function ()
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
			Cursor.set(if part then "valid" else "invalid")

			-- Highlight the owning displacement Model when hovering terrain, else the part itself.
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
		mouse.Button1Down:Connect(function ()
			local part = hovered

			if not Settings.get().sampling or not part then
				return
			end

			if Session.isBaking() then
				Status.post("warning", "Still baking the last edits. Try again in a moment.")
				return
			end

			local ok, result, hidden = pcall(Appearance.copyFrom, part)

			if not ok then
				Status.post("error", `Copy failed: {result}`)
			elseif result == 0 then
				Status.post("warning", `The selected tiles already look like {part.Name}.`)
			elseif hidden == result then
				Status.post("warning", `Copied {describe(part)} to {Format.plural(result, "tile")}, but paint covers all of it. Clear paint to show it.`)
			else
				Status.post("success", `Copied {describe(part)} from {part.Name} to {Format.plural(result, "tile")}.`)
			end

			stop()
		end)
	)

	local unsubscribe = Settings.subscribe(function (state)
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

	return function ()
		unsubscribe()

		for _, connection in connections do
			connection:Disconnect()
		end

		box:Destroy()
		keyStrip.destroy()
	end
end
