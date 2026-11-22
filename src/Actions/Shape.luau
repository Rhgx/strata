--!strict
--[[
	Geometry actions on selected displacements: Detail (Hammer power resampling), Round (Hammer
	Subdivide), Noise, and lossless Split 2x2.
]]

local Selection = game:GetService("Selection")
local CollectionService = game:GetService("CollectionService")

local Plugin = script.Parent.Parent
local Core = Plugin.Core
local Scene = Plugin.Scene

local Noise = require(Core.Noise)
local Stitch = require(Core.Stitch)
local Subdivide = require(Core.Subdivide)
local Displacement = require(Core.Displacement)
local WedgeBuilder = require(Core.WedgeBuilder)
local TerrainInstance = require(Core.TerrainInstance)

local Settings = require(Plugin.State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Edges = require(script.Parent.Edges)
local Recording = require(script.Parent.Recording)

type Opened = TerrainInstance.Opened

local Shape = {}

local function pointKey(point: Vector3): string
	return string.format("%.3f,%.3f,%.3f", point.X, point.Y, point.Z)
end

-- Remaps vertex-indexed part-edge pins across a power change, since changing power renumbers the
-- grid. Surviving vertices keep their exact pin targets; newly inserted edge vertices between
-- two pinned vertices are linearly interpolated along the part edge so they do not sag.
local function remapPins(pins: Stitch.Moves, before: { [Opened]: Displacement.Displacement }): Stitch.Moves
	local result: Stitch.Moves = {}

	for opened, targets in pins do
		local old = before[opened]

		if not old then
			result[opened] = targets
			continue
		end

		local byPoint: { [string]: Vector3 } = {}

		for v, target in targets do
			byPoint[pointKey(Displacement.flatPosition(old, v))] = target
		end

		-- Raising power inserts vertices between existing edge vertices; lowering inserts none,
		-- so unpinned old vertices stay unpinned.
		local raised = opened.disp.power > old.power
		local oldPoints: { [string]: true } = {}

		if raised then
			for _, oldEdge in Displacement.edges(old) do
				for _, v in oldEdge.indices do
					oldPoints[pointKey(Displacement.flatPosition(old, v))] = true
				end
			end
		end

		local remapped: { [number]: Vector3 } = {}

		for _, edge in Displacement.edges(opened.disp) do
			local indices = edge.indices

			for _, v in indices do
				local target = byPoint[pointKey(Displacement.flatPosition(opened.disp, v))]

				if target then
					remapped[v] = target
				end
			end

			if not raised then
				continue
			end

			-- Interpolate any uninterrupted run of newly added vertices between two pinned endpoints.
			local lastPinned: number? = nil

			for i, v in indices do
				if not remapped[v] then
					continue
				end

				local from = lastPinned

				if from and i - from > 1 then
					local allNew = true

					for j = from + 1, i - 1 do
						if oldPoints[pointKey(Displacement.flatPosition(opened.disp, indices[j]))] then
							allNew = false
							break
						end
					end

					if allNew then
						local a, b = remapped[indices[from]], remapped[v]

						for j = from + 1, i - 1 do
							remapped[indices[j]] = a:Lerp(b, (j - from) / (i - from))
						end
					end
				end

				lastPinned = i
			end
		end

		result[opened] = remapped
	end

	return result
end

-- Resamples selected displacements to `power` one level at a time (matching Hammer), keeping
-- stitched edges aligned to their parts. Returns how many tiles changed.
function Shape.setDetail(power: number): number
	local targets = Query.selectedTiles()
	local changed: { Opened } = {}

	Recording.run("Strata change detail", function ()
		local settings = Settings.get()
		local pins = if settings.stitchParts then Edges.pinsFor(targets) else {}
		local before: { [Opened]: Displacement.Displacement } = {}

		for _, opened in targets do
			if opened.disp.power == power then
				continue
			end

			-- Preserve appearance edits made with Studio tools before removing the union.
			TerrainInstance.adoptAppearance(opened)
			TerrainInstance.removeSurfaces(opened.model)

			before[opened] = opened.disp
			opened.disp = Displacement.changePower(opened.disp, power)

			WedgeBuilder.rebuild(opened.disp, opened.wedges, opened.model:GetPivot())
			TerrainInstance.refreshBounds(opened)
			TerrainInstance.save(opened)
			Session.markDirty(opened)
			table.insert(changed, opened)
		end

		pins = remapPins(pins, before)

		if settings.autosew then
			Edges.autosew(changed, pins)
		elseif next(pins) ~= nil then
			for _, opened in Edges.restorePins(pins) do
				TerrainInstance.save(opened)
			end
		end

		Recording.autoBake()
	end)

	return #changed
end

-- Applies Hammer's Subdivide smoothing across selected displacements together. Returns how many
-- tiles changed shape.
function Shape.round(): number
	local targets = Query.selectedTiles()

	if #targets == 0 then
		return 0
	end

	local count = 0

	Recording.run("Strata round", function ()
		local settings = Settings.get()
		local pins = if settings.stitchParts then Edges.pinsFor(targets) else {}
		local changed = Subdivide.apply(targets)
		local changedTiles: { Opened } = {}

		for _, opened in targets do
			local vertices = changed[opened]

			if vertices then
				-- Rounded points must stay where Round puts them, so removed ones come back.
				Session.updateMoved(opened, vertices)
				table.insert(changedTiles, opened)
				count += 1
			end

			-- Save every target because rounding sets the subdiv flag on all of them.
			TerrainInstance.save(opened)
		end

		-- Rounding shifts seam vertices shared with unselected neighbors and parts; re-sew and
		-- re-stitch just like other shape edits.
		if settings.autosew then
			Edges.autosew(changedTiles, pins)
		else
			for _, opened in Edges.restorePins(pins) do
				TerrainInstance.save(opened)
			end
		end

		Recording.autoBake()
	end)

	return count
end

-- Applies Hammer's random displacement noise in [min, max] studs to selected tiles while keeping
-- stitched edges pinned to their parts. Returns how many tiles changed.
function Shape.addNoise(min: number, max: number): number
	local targets = Query.selectedTiles()

	if #targets == 0 or min == max then
		return 0
	end

	local count = 0

	Recording.run("Strata noise", function ()
		local settings = Settings.get()
		local pins = if settings.stitchParts then Edges.pinsFor(targets) else {}
		local changedTiles: { Opened } = {}

		for _, opened in targets do
			local changed = Noise.apply(opened, min, max)

			if next(changed) ~= nil then
				Session.updateWedges(opened, changed)
				TerrainInstance.save(opened)
				table.insert(changedTiles, opened)
				count += 1
			end
		end

		-- Noise is per-tile and opens seams; re-sew and re-stitch afterwards.
		if settings.autosew then
			Edges.autosew(changedTiles, pins)
		else
			for _, opened in Edges.restorePins(pins) do
				TerrainInstance.save(opened)
			end
		end

		Recording.autoBake()
	end)

	return count
end

-- Losslessly splits each selected displacement into 2x2 displacements one power lower (see
-- Displacement.split). Quarters are placed in the source's TerrainArea (or a new container in
-- its place) and selected. Fully-deleted quarters are omitted. Returns (splitCount, skippedPower2).
function Shape.split(): (number, number)
	local splittable: { Opened } = {}
	local skipped = 0

	for _, opened in Query.selectedTiles() do
		if opened.disp.power >= 3 then
			table.insert(splittable, opened)
		else
			skipped += 1
		end
	end

	if #splittable == 0 then
		return 0, skipped
	end

	local quarters: { Opened } = {}

	Recording.run("Strata split", function ()
		for _, opened in splittable do
			local model = opened.model
			local pivot = model:GetPivot()
			local parent = model.Parent

			-- Carry over any appearance changes made with Studio tools into the quarters.
			TerrainInstance.adoptAppearance(opened)

			if not parent then
				continue
			end

			-- Reuse an enclosing TerrainArea; otherwise create one where the split tile sat.
			local container: Instance = parent

			if not (parent:IsA("Model") and not CollectionService:HasTag(parent, TerrainInstance.TAG)) then
				local area = Instance.new("Model")
				area.Name = model.Name
				area.WorldPivot = pivot
				area.Parent = parent
				container = area
			end

			for _, quarter in Displacement.split(opened.disp) do
				-- Omit quarters whose triangles are all deleted so no invisible tile is created.
				-- Both counts use the grid, since shown triangles differ when points are removed.
				if Displacement.holeCount(quarter.disp) == Displacement.gridTriangleCount(quarter.disp) then
					continue
				end

				local child = TerrainInstance.create(
					quarter.disp,
					pivot * CFrame.new(quarter.center),
					container,
					`{model.Name}_{quarter.row}_{quarter.col}`
				)
				table.insert(quarters, child)
			end

			model.Parent = nil
		end

		-- Track the new quarters (removing the parent models evicts them), then auto-bake.
		for _, child in quarters do
			Session.track(child)
			Session.markDirty(child)
		end

		Recording.autoBake()
	end)

	local models: { Instance } = {}

	for _, child in quarters do
		table.insert(models, child.model)
	end

	Selection:Set(models)
	return #splittable, skipped
end

return Shape
