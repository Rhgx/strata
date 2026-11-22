--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Viewport Stitch tool: hover a block or wedge part to preview which displacement edges will
	snap onto it, and click to stitch them. Each click is one undo step while the tool stays
	active so chains of roads or walls can be stitched sequentially; auto-bake runs once the
	tool exits.

	Preview colors: blue selection box when tile edges match (gray when none are in reach),
	green target lines on the part edges, and amber source lines along moving tile edges.

	Viewport controls:
		Left click     stitch nearby tile edges to the hovered part
		Ctrl + scroll  adjust Reach ([ and ] also adjust Reach)
		Esc            stop
]]

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Core = Plugin.Core
local State = Plugin.State
local Actions = Plugin.Actions

local Stitch = require(Core.Stitch)
local TerrainInstance = require(Core.TerrainInstance)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Session = require(Plugin.Scene.Session)

local Bake = require(Actions.Bake)
local Edges = require(Actions.Edges)

local Input = require(Viewport.Input)
local Lines = require(Viewport.Lines)
local Cursor = require(Viewport.Cursor)
local KeyStrip = require(Viewport.KeyStrip)
local VisibleHit = require(Viewport.VisibleHit)

type Opened = TerrainInstance.Opened

type Preview = {
	part: BasePart,
	reach: number,
	result: Stitch.Result,
	-- Per-vertex snap distance for each matched tile.
	distances: { [Opened]: { [number]: number } },
	-- Counts of tile edges and tiles that would actually move.
	edges: number,
	tiles: number,
}

-- Periodically refresh hover preview on the same part so external edits reflect live.
local REFRESH_SECONDS = 0.25
-- Skip amber source lines for vertices moving less than this threshold.
local MOVE_SHOWN = 0.05
local MAX_LINES = 400

local MATCH_COLOR = Color3.fromRGB(80, 160, 255)
local NO_MATCH_COLOR = Color3.fromRGB(160, 160, 160)
local TARGET_COLOR = Color3.fromRGB(80, 220, 120)
local SOURCE_COLOR = Color3.fromRGB(255, 190, 64)
local TARGET_THICKNESS = 0.12
local SOURCE_THICKNESS = 0.06

local SEPARATOR = KeyStrip.SEPARATOR

-- Starts the Stitch viewport tool and returns a cleanup callback.
return function (plugin: Plugin): () -> ()
	local mouse = plugin:GetMouse()
	local connections: { RBXScriptConnection } = {}
	local keyStrip = KeyStrip.new("StrataStitchHints")
	local wasStitching = false
	local preview: Preview? = nil
	local computedAt = 0

	local box = Instance.new("SelectionBox")
	box.Name = "StrataStitchHover"
	box.LineThickness = 0.04
	box.SurfaceTransparency = 1
	box.Parent = CoreGui

	local lines = Lines.new("StrataStitchLine", MAX_LINES)

	local function hide()
		box.Adornee = nil
		lines.clear()
		preview = nil
	end

	-- Finds the visible stitchable block or wedge under the pointer, ignoring Terrain and tiles.
	local function partUnderMouse(): BasePart?
		local exclude: { Instance } = { workspace.Terrain }

		for _, model in CollectionService:GetTagged(TerrainInstance.TAG) do
			table.insert(exclude, model)
		end

		local hit = VisibleHit.cast(mouse.UnitRay, exclude)
		local part = if hit then hit.Instance else nil

		return if part and Stitch.isStitchable(part) then part else nil
	end

	local function compute(part: BasePart, reach: number): Preview
		local result = Edges.previewStitch(part, reach)
		local distances = Stitch.distances(result.moves)
		local edges = 0
		local tiles: { [Opened]: true } = {}

		for _, match in result.matches do
			local tileDistances = distances[match.opened]

			for _, v in match.vertices do
				if tileDistances[v] > 1e-4 then
					edges += 1
					tiles[match.opened] = true
					break
				end
			end
		end

		local tileCount = 0

		for _ in tiles do
			tileCount += 1
		end

		return { part = part, reach = reach, result = result, distances = distances, edges = edges, tiles = tileCount }
	end

	local function draw(current: Preview)
		lines.clear()
		box.Adornee = current.part
		box.Color3 = if #current.result.matches > 0 then MATCH_COLOR else NO_MATCH_COLOR

		local moves = current.result.moves
		local distances = current.distances

		for _, match in current.result.matches do
			local targets = moves[match.opened]
			local tileDistances = distances[match.opened]
			local vertices = match.vertices

			-- Target span on the part edge.
			lines.line(targets[vertices[1]], targets[vertices[#vertices]], TARGET_COLOR, TARGET_THICKNESS, 0.15)

			-- Source tile-edge segments that will move.
			for i = 1, #vertices - 1 do
				local a, b = vertices[i], vertices[i + 1]

				if tileDistances[a] > MOVE_SHOWN or tileDistances[b] > MOVE_SHOWN then
					lines.line(
						Stitch.vertexPosition(match.opened, a),
						Stitch.vertexPosition(match.opened, b),
						SOURCE_COLOR,
						SOURCE_THICKNESS,
						0.35
					)
				end
			end
		end
	end

	local function hint(state: Settings.State): string
		local reach = Format.studs(state.stitchReach)
		local current = preview

		if not current then
			return table.concat({
				"<b>Stitch to part</b>",
				"Hover a part to preview",
				"Click: Stitch",
				`Ctrl + Scroll: Reach ({reach} st)`,
				"Esc: Stop",
			}, SEPARATOR)
		end

		local name = `<b>{current.part.Name}</b>`
		local action = if current.edges > 0
			then `Click to stitch {Format.plural(current.edges, "edge")} on {Format.plural(current.tiles, "tile")} (Reach: {reach} st)`
			elseif #current.result.matches > 0 then "Already stitched"
			else `No tile edges within {reach} st`

		return table.concat({ name, action, "Ctrl + Scroll: Reach", "Esc: Stop" }, SEPARATOR)
	end

	local function click()
		local state = Settings.get()

		if not state.stitching then
			return
		end

		local part = partUnderMouse()

		if not part then
			return
		end

		-- Reject clicks while a background bake still holds Studio's ChangeHistoryService recording.
		if Session.isBaking() then
			Status.post("warning", "Still baking the last edits. Try again in a moment.")
			return
		end

		local ok, result = pcall(Edges.stitchToPart, part, state.stitchReach)
		computedAt = 0

		if not ok then
			Status.post("error", `Stitch failed: {result}`)
		elseif result.edges > 0 then
			Status.post(
				"success",
				`Stitched {Format.plural(result.edges, "edge")} on {Format.plural(result.tiles, "tile")} to {part.Name}.`
			)
		elseif result.matched > 0 then
			Status.post("warning", `Nearby edges are already stitched to {part.Name}.`)
		else
			Status.post(
				"warning",
				`No tile edges within {Format.studs(state.stitchReach)} st of {part.Name}. Raise Reach or move closer.`
			)
		end
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function ()
			local state = Settings.get()

			if not state.stitching then
				return
			end

			local part = partUnderMouse()
			local current = preview

			if not part then
				if current then
					hide()
				end
			elseif
				not current
				or current.part ~= part
				or current.reach ~= state.stitchReach
				or os.clock() - computedAt > REFRESH_SECONDS
			then
				computedAt = os.clock()

				local ok, result = pcall(compute, part, state.stitchReach)

				if ok then
					preview = result
					draw(result)
				else
					hide()
				end
			end

			keyStrip.show(if state.showKeyHints then hint(state) else nil)

			-- Show PointingHand only when clicking would actually move at least one edge.
			local shown = preview
			Cursor.set(
				if #Session.models() == 0 then "empty" elseif shown and shown.edges > 0 then "valid" else "invalid"
			)
		end)
	)

	table.insert(connections, mouse.Button1Down:Connect(click))

	for _, connection in Input.connectResize(mouse, function ()
		return Settings.get().stitching
	end, Settings.stepReach) do
		table.insert(connections, connection)
	end

	local unsubscribe = Settings.subscribe(function (state)
		if state.stitching == wasStitching then
			return
		end

		wasStitching = state.stitching

		if not state.stitching then
			hide()
			keyStrip.show(nil)

			-- Defer auto-bake when switching to another editing tool; still bake on exit even if
			-- nothing was stitched here, since a prior tool may have left dirty tiles.
			if state.autoBake and not Settings.editing(state) then
				task.spawn(Bake.bakeEdited)
			end
		end
	end)

	return function ()
		unsubscribe()

		for _, connection in connections do
			connection:Disconnect()
		end

		box:Destroy()
		lines.destroy()
		keyStrip.destroy()
	end
end
