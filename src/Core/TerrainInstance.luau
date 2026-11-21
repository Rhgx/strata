--!strict
--[[
	The instance layout of one displacement:

		<Model>  tagged StrataDisplacement, pivot = displacement origin
		├─ DispData (Configuration)  the editable source data, as attributes
		├─ Tris (Folder)             generated WedgeParts, while editing
		└─ Surface (UnionOperation)  the wedges merged into one part, once baked

	A displacement is either editing (wedges) or baked (one union). Baking exists because
	Roblox projects a material separately on every part: on wedges the texture is rotated
	per triangle, while a union gets one continuous projection. Editing a baked displacement
	brings the wedges back from DispData.

	The model only holds parts and attributes, so it can be published and inserted like any
	other model, then reopened by the plugin for editing.
]]

local CollectionService = game:GetService("CollectionService")
local GeometryService = game:GetService("GeometryService")

local Displacement = require(script.Parent.Displacement)
local WedgeBuilder = require(script.Parent.WedgeBuilder)

local DATA_NAME = "DispData"
local TRIS_NAME = "Tris"
local SURFACE_NAME = "Surface"
-- The bake helper cube: its size, and how far below the surface it sits (well clear of the
-- wedges, which reach WedgeBuilder.THICKNESS below the surface).
local ANCHOR_SIZE = 0.05
local ANCHOR_DEPTH = 1

export type Opened = {
	model: Model,
	config: Configuration,
	disp: Displacement.Displacement,
	wedges: WedgeBuilder.Wedges,
	-- Local-space bounds of the current surface, used to skip far-away displacements cheaply.
	boundsMin: Vector3,
	boundsMax: Vector3,
}

local TerrainInstance = {}

TerrainInstance.TAG = "StrataDisplacement"

local function computeBounds(disp: Displacement.Displacement, known: { Vector3 }?): (Vector3, Vector3)
	local positions: { Vector3 } = known or Displacement.positions(disp)
	local min, max = positions[1], positions[1]
	for _, position in positions do
		min = min:Min(position)
		max = max:Max(position)
	end
	return min, max
end

-- Creates a displacement model. `skipWedges` leaves the wedges out, for a displacement that is
-- baked right away (ensureWedges builds them whenever it is edited).
function TerrainInstance.create(
	disp: Displacement.Displacement,
	pivot: CFrame,
	parent: Instance,
	name: string,
	skipWedges: boolean?
): Opened
	local model = Instance.new("Model")
	model.Name = name

	local config = Instance.new("Configuration")
	config.Name = DATA_NAME
	Displacement.save(disp, config)
	config.Parent = model

	local folder = Instance.new("Folder")
	folder.Name = TRIS_NAME
	folder.Parent = model

	local wedges = WedgeBuilder.attach(folder)
	if not skipWedges then
		WedgeBuilder.rebuild(disp, wedges, pivot)
	end

	model.WorldPivot = pivot
	CollectionService:AddTag(model, TerrainInstance.TAG)
	model.Parent = parent

	local boundsMin, boundsMax = computeBounds(disp)
	return {
		model = model,
		config = config,
		disp = disp,
		wedges = wedges,
		boundsMin = boundsMin,
		boundsMax = boundsMax,
	}
end

-- Loads a displacement model's data. Does not change any instances except creating an empty
-- Tris folder if it was deleted; call `ensureWedges` before editing.
function TerrainInstance.open(model: Model): Opened
	local config = model:FindFirstChild(DATA_NAME)
	if not config or not config:IsA("Configuration") then
		error(`{model:GetFullName()} has no {DATA_NAME} Configuration`)
	end
	local disp = Displacement.load(config)

	local existing = model:FindFirstChild(TRIS_NAME)
	local folder: Folder
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		folder = Instance.new("Folder")
		folder.Name = TRIS_NAME
		folder.Parent = model
	end

	local boundsMin, boundsMax = computeBounds(disp)
	return {
		model = model,
		config = config,
		disp = disp,
		wedges = WedgeBuilder.attach(folder),
		boundsMin = boundsMin,
		boundsMax = boundsMax,
	}
end

function TerrainInstance.surface(model: Model): UnionOperation?
	local surface = model:FindFirstChild(SURFACE_NAME)
	if surface and surface:IsA("UnionOperation") then
		return surface
	end
	return nil
end

function TerrainInstance.isBaked(model: Model): boolean
	return TerrainInstance.surface(model) ~= nil
end

-- Prepares a displacement for editing: removes the baked union if there is one and
-- regenerates any missing or extra wedges (for example after a power change, or if parts were
-- deleted by hand). Instances are unparented rather than destroyed so undo can restore them.
-- The part that shows the tile right now: the baked union, or its first wedge.
local function shownPart(opened: Opened): BasePart?
	local surface = TerrainInstance.surface(opened.model)
	if surface then
		return surface
	end
	local wedge = opened.wedges.parts[1]
	return if wedge and wedge.Parent == opened.wedges.folder then wedge else nil
end

--[[
	Takes over the material, color and material variant the tile shows, if someone changed them
	with Studio's own tools (Properties, the Model tab's material tool, the Material Manager).
	Called before rebuilding or baking, so those changes stick instead of being overwritten from
	the saved data. Returns whether anything changed (and was saved).
]]
function TerrainInstance.adoptAppearance(opened: Opened): boolean
	local part = shownPart(opened)
	local disp = opened.disp
	if
		not part
		or (part.Material == disp.material and part.Color == disp.color and part.MaterialVariant == disp.materialVariant)
	then
		return false
	end
	disp.material = part.Material
	disp.color = part.Color
	disp.materialVariant = part.MaterialVariant
	Displacement.save(disp, opened.config)
	return true
end

-- Gives the tile a new look: saves it and applies it to the wedges and the baked union.
function TerrainInstance.setAppearance(opened: Opened, material: Enum.Material, color: Color3, variant: string)
	local disp = opened.disp
	disp.material, disp.color, disp.materialVariant = material, color, variant
	Displacement.save(disp, opened.config)
	local parts: { BasePart } = {}
	for _, wedge in opened.wedges.parts do
		table.insert(parts, wedge)
	end
	local surface = TerrainInstance.surface(opened.model)
	if surface then
		table.insert(parts, surface)
	end
	for _, part in parts do
		part.Material = material
		part.Color = color
		part.MaterialVariant = variant
	end
end

-- Returns whether wedges had to be built (which can take a moment on dense tiles).
function TerrainInstance.ensureWedges(opened: Opened): boolean
	TerrainInstance.adoptAppearance(opened)
	local surface = TerrainInstance.surface(opened.model)
	if surface then
		surface.Parent = nil
	end
	if not WedgeBuilder.isComplete(opened.disp, opened.wedges) then
		WedgeBuilder.rebuild(opened.disp, opened.wedges, opened.model:GetPivot())
		return true
	end
	return false
end

-- Below this, a field vector or offset counts as zero (zero vectors are stored with length
-- 1e-5, see Displacement.normalizeWithLength).
local FLAT_EPSILON = 1e-4

-- The slab a flat rectangular displacement bakes to (model space), or nil when the
-- displacement is sculpted or not a rectangle. Every new tile from Create is flat, and one slab
-- unions about 70 times faster than its 64 to 1,024 wedges, with the same shape.
local function flatSlab(disp: Displacement.Displacement): (CFrame?, Vector3?)
	for v = 1, Displacement.vertexCount(disp) do
		if disp.distances[v] > FLAT_EPSILON or disp.offsets[v].Magnitude > FLAT_EPSILON then
			return nil, nil
		end
	end
	local c = disp.corners
	local across, along = c[4] - c[1], c[2] - c[1]
	local isRectangle = math.abs(across.Unit:Dot(along.Unit)) < 1e-4 and (c[3] - (c[1] + across + along)).Magnitude < 1e-3
	if not isRectangle then
		return nil, nil
	end
	local normal = Displacement.faceNormal(disp)
	local thickness = WedgeBuilder.THICKNESS
	-- The wedges hang `thickness` below the surface, so the slab does too.
	local center = (c[1] + c[3]) / 2 + normal * (disp.elevation - thickness / 2)
	return CFrame.fromMatrix(center, across.Unit, normal), Vector3.new(across.Magnitude, thickness, along.Magnitude)
end

local function union(anchor: BasePart, parts: { BasePart }, collision: Enum.CollisionFidelity): UnionOperation?
	local ok, result = pcall(function()
		return GeometryService:UnionAsync(anchor, parts, {
			CollisionFidelity = collision,
			RenderFidelity = Enum.RenderFidelity.Precise,
			SplitApart = false,
		})
	end)
	if not ok then
		error(result, 0)
	end
	local first = result[1]
	return if first and first:IsA("UnionOperation") then first else nil
end

-- Merges the wedges into one union so the material maps continuously. Yields while the union
-- is computed. Does nothing if the displacement is already baked.
function TerrainInstance.bake(opened: Opened, smoothingAngle: number)
	if TerrainInstance.isBaked(opened.model) then
		return
	end
	TerrainInstance.adoptAppearance(opened)
	local pivot = opened.model:GetPivot()
	local disp = opened.disp
	local faceNormal = Displacement.faceNormal(disp)

	local parts: { BasePart } = {}
	local slabCFrame, slabSize = flatSlab(disp)
	local slab: Part? = nil
	if slabCFrame and slabSize then
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = slabSize
		part.CFrame = pivot * slabCFrame
		parts = { part }
		slab = part
	else
		TerrainInstance.ensureWedges(opened)
		for n = 1, Displacement.triangleCount(disp) * 2 do
			table.insert(parts, opened.wedges.parts[n])
		end
	end

	-- A union takes its CFrame from the first part, and Roblox projects the material in the
	-- union's local space. Starting with a tiny cube aligned to the model pivot gives every
	-- baked tile the same texture axes and the same origin relative to its corner, so patterns
	-- line up across neighboring tiles. The cube must not touch the surface: when it overlaps
	-- it, UnionAsync can silently return only the cube. So it sits below the lowest point of the
	-- surface (sculpted tiles can dip far below their flat face), and is cut away afterwards.
	-- The helper parts are never parented, so they stay out of the place and the undo history.
	local i1, i2, i3 = Displacement.triangle(disp, 1)
	local centroid = (
		Displacement.position(disp, i1, faceNormal)
		+ Displacement.position(disp, i2, faceNormal)
		+ Displacement.position(disp, i3, faceNormal)
	) / 3
	local lowest = math.huge
	for _, position in Displacement.positions(disp, faceNormal) do
		lowest = math.min(lowest, position:Dot(faceNormal))
	end
	local depth = centroid:Dot(faceNormal) - lowest + WedgeBuilder.THICKNESS + ANCHOR_DEPTH
	local anchorCFrame = CFrame.new(pivot * (centroid - faceNormal * depth)) * pivot.Rotation
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.Size = Vector3.new(ANCHOR_SIZE, ANCHOR_SIZE, ANCHOR_SIZE)
	anchor.CFrame = anchorCFrame

	local corners = disp.corners
	local expectedExtent = math.max((corners[3] - corners[1]).Magnitude, (corners[4] - corners[2]).Magnitude)
	local function usable(result: UnionOperation?): boolean
		return result ~= nil and result.Size.Magnitude >= expectedExtent * 0.5
	end

	-- The first union is only an intermediate (the cut below makes the final part), so it skips
	-- the expensive precise collision. That saves a quarter to half of the bake time.
	local merged = union(anchor, parts, Enum.CollisionFidelity.Box)
	-- Guard against a collapsed union (only the cube): keep the wedges and report it instead.
	if not merged or not usable(merged) then
		anchor:Destroy()
		if merged then
			merged:Destroy()
		end
		error("the union came out empty; the displacement was left as wedges", 0)
	end

	-- Cut the cube away with a slightly larger one. The result keeps the union's CFrame.
	local cutter = Instance.new("Part")
	cutter.Anchored = true
	cutter.Size = Vector3.new(ANCHOR_SIZE * 3, ANCHOR_SIZE * 3, ANCHOR_SIZE * 3)
	cutter.CFrame = anchorCFrame
	local cutOk, cutResult = pcall(function()
		return GeometryService:SubtractAsync(merged, { cutter }, {
			CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition,
			RenderFidelity = Enum.RenderFidelity.Precise,
			SplitApart = false,
		})
	end)
	cutter:Destroy()
	local cut = if cutOk and cutResult[1] and cutResult[1]:IsA("UnionOperation") then cutResult[1] else nil
	local result: UnionOperation
	if cut and usable(cut) then
		merged:Destroy()
		result = cut
	else
		-- The cut failed: redo the union with precise collision and keep the harmless speck
		-- under the surface, rather than shipping box collision.
		merged:Destroy()
		local precise = union(anchor, parts, Enum.CollisionFidelity.PreciseConvexDecomposition)
		if not precise or not usable(precise) then
			anchor:Destroy()
			error("the union came out empty; the displacement was left as wedges", 0)
		end
		result = precise
	end
	anchor:Destroy()
	if slab then
		slab:Destroy()
	end

	local surface = result
	surface.Name = SURFACE_NAME
	surface.Anchored = true
	surface.CanTouch = false
	surface.UsePartColor = true
	surface.Material = opened.disp.material
	surface.Color = opened.disp.color
	surface.MaterialVariant = opened.disp.materialVariant
	surface.SmoothingAngle = smoothingAngle
	surface.Parent = opened.model

	-- Unparented rather than destroyed, so undo can bring the wedges back.
	for _, part in opened.wedges.parts do
		part.Parent = nil
	end
	table.clear(opened.wedges.parts)
end

-- Recomputes the cached bounds; pass `positions` when they were just computed.
function TerrainInstance.refreshBounds(opened: Opened, positions: { Vector3 }?)
	opened.boundsMin, opened.boundsMax = computeBounds(opened.disp, positions)
end

function TerrainInstance.save(opened: Opened)
	Displacement.save(opened.disp, opened.config)
end

return TerrainInstance
