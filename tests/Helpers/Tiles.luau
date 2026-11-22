--!strict
--[[
	Builds throwaway tiles and parts for specs. Everything goes into an arena Folder that is never
	parented to workspace, so specs cannot touch real terrain in the open place (Session scans
	workspace) and Studio does no rendering work. Tiles skip their wedges: Core logic reads only
	the displacement data, the pivot, and the bounds.
]]

local Root = script.Parent.Parent.Parent
local Core = Root.Plugin.Core

local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

export type Opened = TerrainInstance.Opened

local Tiles = {}

function Tiles.arena(): Folder
	local arena = Instance.new("Folder")
	arena.Name = "StrataTestArena"

	return arena
end

-- A flat square tile `size` studs wide on the XZ plane facing up, its first corner at `origin`.
function Tiles.flat(arena: Folder, origin: Vector3, size: number, power: number): Opened
	local corners = {
		Vector3.new(0, 0, 0),
		Vector3.new(0, 0, size),
		Vector3.new(size, 0, size),
		Vector3.new(size, 0, 0),
	}
	local disp = Displacement.new(corners, power, Enum.Material.Grass, Color3.fromRGB(80, 140, 80))

	return TerrainInstance.create(disp, CFrame.new(origin), arena, "Tile", true)
end

-- An anchored block Part spanning world corners `min` and `max`.
function Tiles.block(arena: Folder, min: Vector3, max: Vector3): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = max - min
	part.CFrame = CFrame.new((min + max) / 2)
	part.Parent = arena

	return part
end

-- World position of vertex `v` as the tile is now.
function Tiles.world(opened: Opened, v: number): Vector3
	return opened.model:GetPivot() * Displacement.position(opened.disp, v)
end

-- The vertex whose flat (undisplaced) world position is `point`, if any.
function Tiles.vertexAt(opened: Opened, point: Vector3): number?
	local pivot = opened.model:GetPivot()

	for v = 1, Displacement.vertexCount(opened.disp) do
		if (pivot * Displacement.flatPosition(opened.disp, v) - point).Magnitude < 1e-3 then
			return v
		end
	end

	return nil
end

-- Moves vertex `v` to world position `point`.
function Tiles.move(opened: Opened, v: number, point: Vector3)
	local localPoint = opened.model:GetPivot():PointToObjectSpace(point)
	Displacement.setPosition(opened.disp, v, localPoint)
end

return Tiles
