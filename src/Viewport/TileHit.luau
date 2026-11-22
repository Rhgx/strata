--!strict
--[[
	Resolves the displacement surface and exact shown triangle under a viewport ray for triangle
	and vertex tools (Material, Mesh). Uses a live physics raycast to locate the tile, then tests
	its geometry data via SurfaceRay to identify the exact triangle. With `includeHoles = true`,
	casts directly against displacement data so deleted triangles (which have no collidable parts)
	can also be hit.
]]

local Plugin = script.Parent.Parent
local Core = Plugin.Core
local Scene = Plugin.Scene

local SurfaceRay = require(Core.SurfaceRay)
local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

type Opened = TerrainInstance.Opened

export type Hit = {
	position: Vector3,
	normal: Vector3,
	opened: Opened,
	-- Shown triangle index under the ray, when resolved.
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

-- Casts `ray` against `models` (also used by RadiusPreview with the viewport center ray).
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

-- Computes world-space centroids for every shown triangle of `opened`.
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
