--!strict
--[[
	The Stitch tool: hover a block or wedge part to preview which tile edges will
	snap onto it, click to stitch them. Each click is one undo step, and the mode stays on so a
	chain of roads or walls can be clicked in a row. Baking waits until the mode stops (Esc,
	its button again, another tool), like painting.

	Preview: the hovered part gets a blue box when something will snap to it (gray when nothing
	is in reach), green lines where vertices land on its edges, and amber lines along the tile
	edges that will move.

	Viewport controls:
		Left click        stitch the hovered part
		Ctrl + scroll     change the reach ([ and ] too)
		Esc               stop
]]

local CollectionService = game:GetService("CollectionService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Stitch = require(script.Parent.Parent.Core.Stitch)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Settings = require(script.Parent.Parent.State.Settings)
local Status = require(script.Parent.Parent.State.Status)
local Session = require(script.Parent.Parent.Scene.Session)
local Edges = require(script.Parent.Parent.Actions.Edges)
local Bake = require(script.Parent.Parent.Actions.Bake)
local Input = require(script.Parent.Input)
local KeyStrip = require(script.Parent.KeyStrip)

type Opened = TerrainInstance.Opened

local RAY_LENGTH = 10000
-- Invisible parts (triggers, hitboxes) are looked through, up to this many.
local MAX_SKIPS = 8
-- The preview is recomputed this often while hovering the same part, so edits show up.
local REFRESH_SECONDS = 0.25
-- Vertices that move less than this get no amber line.
local MOVE_SHOWN = 0.05
local MAX_LINES = 400

local MATCH_COLOR = Color3.fromRGB(80, 160, 255)
local NO_MATCH_COLOR = Color3.fromRGB(160, 160, 160)
local TARGET_COLOR = Color3.fromRGB(80, 220, 120)
local SOURCE_COLOR = Color3.fromRGB(255, 190, 64)
local TARGET_THICKNESS = 0.12
local SOURCE_THICKNESS = 0.06

local SEPARATOR = KeyStrip.SEPARATOR

local function formatReach(reach: number): string
	return if reach == math.floor(reach) then tostring(reach) else string.format("%.1f", reach)
end

local function plural(n: number, word: string): string
	return if n == 1 then `1 {word}` else `{n} {word}s`
end

type Preview = {
	part: BasePart,
	reach: number,
	result: Stitch.Result,
	-- How far each matched vertex would move.
	distances: { [Opened]: { [number]: number } },
	-- Tile edges and tiles that would move.
	edges: number,
	tiles: number,
}

-- Starts the tool; returns a function that stops it.
return function(plugin: Plugin): () -> ()
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

	local lines: { BoxHandleAdornment } = {}
	local used = 0

	local function line(from: Vector3, to: Vector3, color: Color3, thickness: number, transparency: number)
		local length = (to - from).Magnitude
		if length < 1e-3 or used >= MAX_LINES then
			return
		end
		used += 1
		if not lines[used] then
			local created = Instance.new("BoxHandleAdornment")
			created.Name = "StrataStitchLine"
			created.Adornee = workspace.Terrain
			created.AlwaysOnTop = true
			created.ZIndex = 2
			created.Parent = CoreGui
			lines[used] = created
		end
		local adornment = lines[used]
		-- The Terrain adornee sits at the origin, so this CFrame is world space.
		adornment.CFrame = CFrame.lookAt((from + to) / 2, to)
		adornment.Size = Vector3.new(thickness, thickness, length)
		adornment.Color3 = color
		adornment.Transparency = transparency
		adornment.Visible = true
	end

	local function clearLines()
		for i = 1, #lines do
			lines[i].Visible = false
		end
		used = 0
	end

	local function hide()
		box.Adornee = nil
		clearLines()
		preview = nil
	end

	-- The block or wedge part under the mouse, looking through invisible parts. Tiles and
	-- Terrain are ignored.
	local function partUnderMouse(): BasePart?
		local exclude: { Instance } = { workspace.Terrain }
		for _, model in CollectionService:GetTagged(TerrainInstance.TAG) do
			table.insert(exclude, model)
		end
		local ray = mouse.UnitRay
		for _ = 1, MAX_SKIPS do
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = exclude
			local hit = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
			if not hit then
				return nil
			end
			local part = hit.Instance
			if part.Transparency >= 0.99 then
				table.insert(exclude, part)
				continue
			end
			return if Stitch.isStitchable(part) then part else nil
		end
		return nil
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
		clearLines()
		box.Adornee = current.part
		box.Color3 = if #current.result.matches > 0 then MATCH_COLOR else NO_MATCH_COLOR
		local moves = current.result.moves
		local distances = current.distances
		for _, match in current.result.matches do
			local targets = moves[match.opened]
			local tileDistances = distances[match.opened]
			local vertices = match.vertices
			-- Where the vertices land on the part edge.
			line(targets[vertices[1]], targets[vertices[#vertices]], TARGET_COLOR, TARGET_THICKNESS, 0.15)
			-- The tile edge that moves, segment by segment.
			for i = 1, #vertices - 1 do
				local a, b = vertices[i], vertices[i + 1]
				if tileDistances[a] > MOVE_SHOWN or tileDistances[b] > MOVE_SHOWN then
					line(
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
		local reach = formatReach(state.stitchReach)
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
			then `Click to stitch {plural(current.edges, "edge")} on {plural(current.tiles, "tile")} (Reach: {reach} st)`
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
		-- A bake from the previous tool may still be running (it holds Studio's undo recording).
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
				`Stitched {plural(result.edges, "edge")} on {plural(result.tiles, "tile")} to {part.Name}.`
			)
		elseif result.matched > 0 then
			Status.post("warning", `Nearby edges are already stitched to {part.Name}.`)
		else
			Status.post(
				"warning",
				`No tile edges within {formatReach(state.stitchReach)} st of {part.Name}. Raise Reach or move closer.`
			)
		end
	end

	table.insert(
		connections,
		RunService.Heartbeat:Connect(function()
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
		end)
	)

	table.insert(connections, mouse.Button1Down:Connect(click))

	for _, connection in Input.connectResize(mouse, function()
		return Settings.get().stitching
	end, Settings.stepReach) do
		table.insert(connections, connection)
	end

	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input)
			if not Settings.get().stitching or UserInputService:GetFocusedTextBox() then
				return
			end
			if input.KeyCode == Enum.KeyCode.LeftBracket then
				Settings.stepReach(-1)
			elseif input.KeyCode == Enum.KeyCode.RightBracket then
				Settings.stepReach(1)
			end
		end)
	)

	local unsubscribe = Settings.subscribe(function(state)
		if state.stitching == wasStitching then
			return
		end
		wasStitching = state.stitching
		if not state.stitching then
			hide()
			keyStrip.show(nil)
			-- Not when switching to another editing tool (see Settings.editing). Even with nothing
			-- stitched: an editing tool used before this one may have left tiles to bake.
			if state.autoBake and not Settings.editing(state) then
				task.spawn(Bake.bakeEdited)
			end
		end
	end)

	return function()
		unsubscribe()
		for _, connection in connections do
			connection:Disconnect()
		end
		box:Destroy()
		for _, adornment in lines do
			adornment:Destroy()
		end
		keyStrip.destroy()
	end
end
