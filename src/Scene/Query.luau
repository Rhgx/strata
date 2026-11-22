--!strict
--[[
	Read-only scene queries: selected displacements and parts, parts touching a displacement,
	displacements near a part, and aggregate counts for the panel.

	Selecting a TerrainArea (or any ancestor container) includes all displacements inside it, and
	selecting a wedge or union inside a displacement resolves to that displacement.
]]

local Selection = game:GetService("Selection")
local CollectionService = game:GetService("CollectionService")

local Plugin = script.Parent.Parent
local Core = Plugin.Core

local PartFaces = require(Core.PartFaces)
local TerrainInstance = require(Core.TerrainInstance)

local Settings = require(Plugin.State.Settings)

local Session = require(script.Parent.Session)

type Opened = TerrainInstance.Opened

export type SelectionInfo = {
	count: number,
	-- Shared power of the selection, or nil when empty or mixed.
	power: number?,
	baked: number,
	-- Selected displacements eligible for Split 2x2 (power 3 or 4).
	splittable: number,
	-- Selected block or wedge parts that can be converted into displacements or stitched to.
	parts: number,
	-- Shared appearance of the selected tiles; nil when mixed or nothing is selected.
	material: Enum.Material?,
	color: Color3?,
	variant: string?,
	-- Whether any selected tile uses a non-empty material variant.
	anyVariant: boolean,
	-- Selected tiles with painted materials.
	painted: number,
	-- Selected tiles with deleted triangles.
	holes: number,
	-- Selected tiles with removed points.
	simplified: number,
}

export type Appearance = {
	material: Enum.Material,
	color: Color3,
	variant: string,
}

export type PlaceInfo = {
	total: number,
	baked: number,
}

local Query = {}

-- Returns the displacement Model that is or contains `inst`, if any.
function Query.displacementOf(inst: Instance): Model?
	local node: Instance? = inst

	while node do
		if node:IsA("Model") and CollectionService:HasTag(node, TerrainInstance.TAG) then
			return node
		end

		node = node.Parent
	end

	return nil
end

function Query.selectedModels(): { Model }
	local selected: { [Instance]: true } = {}

	for _, inst in Selection:Get() do
		selected[inst] = true
	end

	local found: { [Model]: true } = {}

	-- Include displacements selected directly or nested inside a selected container.
	for _, model in Session.models() do
		local node: Instance? = model

		while node do
			if selected[node] then
				found[model] = true
				break
			end

			node = node.Parent
		end
	end

	-- Include displacements owning any selected descendant part.
	for inst in selected do
		local model = Query.displacementOf(inst)

		if model and model:IsDescendantOf(workspace) then
			found[model] = true
		end
	end

	local result = {}

	for model in found do
		table.insert(result, model)
	end

	return result
end

function Query.selectedTiles(): { Opened }
	return Session.getAll(Query.selectedModels())
end

-- Returns selected block and wedge parts outside displacements (eligible for Create and Sew).
function Query.selectedParts(): { BasePart }
	local parts = {}

	for _, inst in Selection:Get() do
		if inst:IsA("BasePart") and inst.Parent and PartFaces.isEligible(inst) and not Query.displacementOf(inst) then
			table.insert(parts, inst)
		end
	end

	return parts
end

-- Finds visible block and wedge parts within `pad` studs of `targets` (using sculpted bounds,
-- not just the flat base face) via a spatial query so the user does not need to select them.
function Query.touchingParts(targets: { Opened }, pad: number): { BasePart }
	local exclude: { Instance } = {}

	for _, model in Session.models() do
		table.insert(exclude, model)
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude

	local found: { [BasePart]: true } = {}

	for _, opened in targets do
		local min, max = opened.boundsMin, opened.boundsMax

		for _, corner in opened.disp.corners do
			min = min:Min(corner)
			max = max:Max(corner)
		end

		local boxCFrame = opened.model:GetPivot() * CFrame.new((min + max) / 2)

		for _, part in workspace:GetPartBoundsInBox(boxCFrame, max - min + Vector3.one * pad * 2, params) do
			if PartFaces.isEligible(part) and part.Transparency < 0.99 then
				found[part] = true
			end
		end
	end

	local result = {}

	for part in found do
		table.insert(result, part)
	end

	return result
end

-- Returns opened displacements within `pad` studs of `part`.
function Query.tilesNear(part: BasePart, pad: number): { Opened }
	local include: { Instance } = {}

	for _, model in Session.models() do
		table.insert(include, model)
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include

	local found: { [Model]: true } = {}

	for _, hit in workspace:GetPartBoundsInBox(part.CFrame, part.Size + Vector3.one * pad * 2, params) do
		local model = Query.displacementOf(hit)

		if model then
			found[model] = true
		end
	end

	local models = {}

	for model in found do
		table.insert(models, model)
	end

	return Session.getAll(models)
end

local function triLooksOf(model: Model): string?
	local config = model:FindFirstChild("DispData")
	local digits = if config then config:GetAttribute("TriLooks") else nil

	return if typeof(digits) == "string" then digits else nil
end

-- Checks saved attributes for any painted triangle look without opening the tile.
function Query.isPainted(model: Model): boolean
	local digits = triLooksOf(model)

	return digits ~= nil and string.find(digits, "[1-9a-z]") ~= nil
end

-- Checks saved attributes for any removed vertex without opening the tile.
function Query.isSimplified(model: Model): boolean
	local config = model:FindFirstChild("DispData")

	return config ~= nil and config:GetAttribute("Removed") ~= nil
end

-- Checks saved attributes for any deleted triangle without opening the tile.
function Query.hasHoles(model: Model): boolean
	local digits = triLooksOf(model)

	return digits ~= nil and string.find(digits, "-", 1, true) ~= nil
end

-- Returns whether every triangle of the tile is deleted. Such a tile has nothing to bake and
-- counts as baked for place totals.
function Query.isAllHoles(model: Model): boolean
	local digits = triLooksOf(model)

	return digits ~= nil and #digits > 0 and string.find(digits, "[^%-]") == nil
end

-- Reads the tile's base appearance (ignoring painted triangles) without opening it: checks the
-- baked Surface union or a wedge on an unpainted tile first so direct Studio property edits are
-- respected, then falls back to saved DispData attributes.
function Query.appearanceOf(model: Model): Appearance?
	local shown: Instance? = model:FindFirstChild("Surface")

	if not shown and not Query.isPainted(model) and not TerrainInstance.isBaked(model) then
		local tris = model:FindFirstChild("Tris")
		shown = if tris then tris:FindFirstChildWhichIsA("BasePart") else nil
	end

	if shown and shown:IsA("BasePart") then
		return { material = shown.Material, color = shown.Color, variant = shown.MaterialVariant }
	end

	local config = model:FindFirstChild("DispData")

	if not config then
		return nil
	end

	local materialName, color, variant = config:GetAttribute("Material"), config:GetAttribute("Color"), config:GetAttribute("MaterialVariant")
	local material = if typeof(materialName) == "string" then Enum.Material:FromName(materialName) else nil

	if not material or typeof(color) ~= "Color3" then
		return nil
	end

	return { material = material, color = color, variant = if typeof(variant) == "string" then variant else "" }
end

-- Compares colors at 8 bits per channel so floating-point noise never reads as "Mixed".
local function sameColor(a: Color3, b: Color3): boolean
	return math.round(a.R * 255) == math.round(b.R * 255)
		and math.round(a.G * 255) == math.round(b.G * 255)
		and math.round(a.B * 255) == math.round(b.B * 255)
end

function Query.selectionInfo(): SelectionInfo
	local models = Query.selectedModels()
	local power: number? = nil
	local mixed = false
	local baked = 0
	local splittable = 0
	local material: Enum.Material?, color: Color3?, variant: string? = nil, nil, nil
	local mixedMaterial, mixedColor, mixedVariant = false, false, false
	local anyVariant = false
	local painted = 0
	local holes = 0
	local simplified = 0

	for index, model in models do
		if Query.isPainted(model) then
			painted += 1
		end

		if Query.hasHoles(model) then
			holes += 1
		end

		if Query.isSimplified(model) then
			simplified += 1
		end

		local look = Query.appearanceOf(model)

		if look then
			if index == 1 then
				material, color, variant = look.material, look.color, look.variant
			else
				mixedMaterial = mixedMaterial or look.material ~= material
				mixedColor = mixedColor or not (color and sameColor(look.color, color))
				mixedVariant = mixedVariant or look.variant ~= variant
			end

			anyVariant = anyVariant or look.variant ~= ""
		end

		local config = model:FindFirstChild("DispData")
		local value = if config then config:GetAttribute("Power") else nil

		if typeof(value) ~= "number" or (power ~= nil and power ~= value) then
			mixed = true
		end

		if typeof(value) == "number" then
			power = value

			if value >= 3 then
				splittable += 1
			end
		end

		if TerrainInstance.isBaked(model) then
			baked += 1
		end
	end

	return {
		count = #models,
		power = if mixed then nil else power,
		baked = baked,
		splittable = splittable,
		parts = #Query.selectedParts(),
		material = if mixedMaterial then nil else material,
		color = if mixedColor then nil else color,
		variant = if mixedVariant then nil else variant,
		anyVariant = anyVariant,
		painted = painted,
		holes = holes,
		simplified = simplified,
	}
end

-- Returns the displacements a viewport tool operates on: selected tiles when Selected only is
-- enabled (Hammer's behavior), or all tiles in the workspace otherwise.
function Query.workingModels(): { Model }
	if Settings.get().paintSelectedOnly then
		return Query.selectedModels()
	end

	return Session.models()
end

-- Counts all displacements in the place and how many are baked. Fully-deleted tiles count as
-- baked here since they have nothing to bake; selectionInfo keeps exact counts so the Tiles
-- page's Bake and Unbake buttons match what they act on.
function Query.placeInfo(): PlaceInfo
	local models = Session.models()
	local baked = 0

	for _, model in models do
		if TerrainInstance.isBaked(model) or Query.isAllHoles(model) then
			baked += 1
		end
	end

	return { total = #models, baked = baked }
end

return Query
