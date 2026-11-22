--!strict
--[[
	Shape actions on the selected displacements: Detail (Hammer power), Round (Hammer's
	Subdivide), Noise and Split 2x2.
]]

local CollectionService = game:GetService("CollectionService")
local Selection = game:GetService("Selection")

local Displacement = require(script.Parent.Parent.Core.Displacement)
local Noise = require(script.Parent.Parent.Core.Noise)
local Stitch = require(script.Parent.Parent.Core.Stitch)
local Subdivide = require(script.Parent.Parent.Core.Subdivide)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local WedgeBuilder = require(script.Parent.Parent.Core.WedgeBuilder)
local Query = require(script.Parent.Parent.Scene.Query)
local Session = require(script.Parent.Parent.Scene.Session)
local Settings = require(script.Parent.Parent.State.Settings)
local Edges = require(script.Parent.Edges)
local Recording = require(script.Parent.Recording)

type Opened = TerrainInstance.Opened

local Shape = {}

local function pointKey(point: Vector3): string
	return string.format("%.3f,%.3f,%.3f", point.X, point.Y, point.Z)
end

-- Pins are per vertex index, and changing power renumbers the grid. Moves each pin to the new
-- vertex at the same flat spot (edge vertices that survive the change keep their place; new
-- in-between ones are interpolated along the straight part edge, so they stay on it).
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
		local remapped: { [number]: Vector3 } = {}
		for _, edge in Displacement.edges(opened.disp) do
			for _, v in edge.indices do
				local target = byPoint[pointKey(Displacement.flatPosition(opened.disp, v))]
				if target then
					remapped[v] = target
				end
			end
		end
		result[opened] = remapped
	end
	return result
end

-- Changes the selected displacements to `power` with Hammer's resampling (one level at a time),
-- keeping stitched edges on their parts. Returns how many were changed.
function Shape.setDetail(power: number): number
	local targets = Query.selectedTiles()
	local changed: { Opened } = {}
	Recording.run("Strata change detail", function()
		local settings = Settings.get()
		local pins = if settings.stitchParts then Edges.pinsFor(targets) else {}
		local before: { [Opened]: Displacement.Displacement } = {}
		for _, opened in targets do
			if opened.disp.power == power then
				continue
			end
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

-- Rounds the selected displacements together (Hammer's Subdivide). Returns how many changed
-- shape.
function Shape.round(): number
	local targets = Query.selectedTiles()
	if #targets == 0 then
		return 0
	end
	local count = 0
	Recording.run("Strata round", function()
		local changed = Subdivide.apply(targets)
		for _, opened in targets do
			local vertices = changed[opened]
			if vertices then
				Session.updateWedges(opened, vertices)
				count += 1
			end
			-- Every target gets the subdiv flag, so save them all.
			TerrainInstance.save(opened)
		end
		Recording.autoBake()
	end)
	return count
end

-- Adds Hammer's noise between `min` and `max` studs to the selected displacements, keeping
-- stitched edges on their parts. Returns how many changed.
function Shape.addNoise(min: number, max: number): number
	local targets = Query.selectedTiles()
	if #targets == 0 or min == max then
		return 0
	end
	local count = 0
	Recording.run("Strata noise", function()
		local pins = if Settings.get().stitchParts then Edges.pinsFor(targets) else {}
		for _, opened in targets do
			local changed = Noise.apply(opened, min, max)
			if next(changed) ~= nil then
				Session.updateWedges(opened, changed)
				TerrainInstance.save(opened)
				count += 1
			end
		end
		for _, opened in Edges.restorePins(pins) do
			TerrainInstance.save(opened)
		end
		Recording.autoBake()
	end)
	return count
end

-- Splits each selected displacement into 2x2 displacements one power lower, losslessly (see
-- Displacement.split). Quarters go into the displacement's TerrainArea, or a new one in its
-- place, and become the selection. Quarters whose every triangle is deleted are left out.
-- Returns how many were split and how many were skipped for being power 2.
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
	Recording.run("Strata split", function()
		for _, opened in splittable do
			local model = opened.model
			local pivot = model:GetPivot()
			local parent = model.Parent
			if not parent then
				continue
			end
			-- Reuse the surrounding TerrainArea; otherwise make one in the displacement's place.
			local container: Instance = parent
			if not (parent:IsA("Model") and not CollectionService:HasTag(parent, TerrainInstance.TAG)) then
				local area = Instance.new("Model")
				area.Name = model.Name
				area.WorldPivot = pivot
				area.Parent = parent
				container = area
			end
			for _, quarter in Displacement.split(opened.disp) do
				-- A quarter with every triangle deleted would be an invisible tile.
				if Displacement.holeCount(quarter.disp) == Displacement.triangleCount(quarter.disp) then
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
		-- Track the quarters (the split displacements were removed, which evicts them), then
		-- bake them.
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
