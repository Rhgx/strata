--!strict
--[[
	The tile surface under the mouse, with the exact shown triangle, for the tools that work on
	triangles and points (Material, Mesh). A live raycast finds the tile, then the tile's data
	tells which triangle it is (the wedges and unions follow the data exactly). With
	`includeHoles`, the tiles' data alone is searched, so deleted triangles, which have no parts
	to hit, are found too.
]]

local Displacement = require(script.Parent.Parent.Core.Displacement)
local SurfaceRay = require(script.Parent.Parent.Core.SurfaceRay)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Session = require(script.Parent.Parent.Scene.Session)
local Query = require(script.Parent.Parent.Scene.Query)

type Opened = TerrainInstance.Opened

export type Hit = {
	position: Vector3,
	normal: Vector3,
	opened: Opened,
	-- The shown triangle under the cursor, when it could be found.
	triangle: number?,
}

local RAY_LENGTH = 10000

local TileHit = {}

local function fromData(ray: Ray, models: { Model }): Hit?
	local direction = ray.Direction.Unit
	local snapshots: { SurfaceRay.Snapshot } = {}
	for _, opened in Session.getAll(models) do
		if SurfaceRay.mayHit(opened, ray.Origin, direction, RAY_LENGTH) then
			table.insert(snapshots, SurfaceRay.snapshot(opened))
		end
	end
	local exact = SurfaceRay.cast(ray.Origin, direction, RAY_LENGTH, snapshots, true)
	if not exact then
		return nil
	end
	return {
		position = ray.Origin + direction * exact.distance,
		normal = exact.normal,
		opened = exact.snapshot.opened,
		triangle = exact.triangle,
	}
end

function TileHit.find(mouse: PluginMouse, models: { Model }, includeHoles: boolean?): Hit?
	return TileHit.findAlong(mouse.UnitRay, models, includeHoles)
end

-- The same along any ray (the radius preview aims from the middle of the view).
function TileHit.findAlong(ray: Ray, models: { Model }, includeHoles: boolean?): Hit?
	if #models == 0 then
		return nil
	end
	if includeHoles then
		return fromData(ray, models)
	end
	local direction = ray.Direction.Unit
	local filter: { Instance } = table.create(#models)
	for i, model in models do
		filter[i] = model
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = filter
	local live = workspace:Raycast(ray.Origin, direction * RAY_LENGTH, params)
	if not live then
		return nil
	end
	local model = Query.displacementOf(live.Instance)
	local opened = if model then Session.get(model) else nil
	if not opened then
		return nil
	end
	local exact = SurfaceRay.cast(ray.Origin, direction, RAY_LENGTH, { SurfaceRay.snapshot(opened) })
	if exact then
		return {
			position = ray.Origin + direction * exact.distance,
			normal = exact.normal,
			opened = opened,
			triangle = exact.triangle,
		}
	end
	return { position = live.Position, normal = live.Normal, opened = opened, triangle = nil }
end

-- World centers of every shown triangle of a tile.
function TileHit.centers(opened: Opened): { Vector3 }
	local disp = opened.disp
	local pivot = opened.model:GetPivot()
	local positions = Displacement.positions(disp)
	local result = table.create(Displacement.triangleCount(disp))
	for t = 1, Displacement.triangleCount(disp) do
		local i1, i2, i3 = Displacement.triangle(disp, t)
		result[t] = pivot * ((positions[i1] + positions[i2] + positions[i3]) / 3)
	end
	return result
end

return TileHit
