--!strict
--[[
	Changing the look of existing tiles: material, color and material variant (custom materials
	from the Material Manager). One material per tile, since parts cannot blend materials the
	way Hammer's alpha painting does.

	Changes go straight onto the parts that show the tile (the baked union, or the wedges) and
	into its saved data. Nothing is unbaked, rebaked or rebuilt, and tiles that are not open are
	not opened, so changing 100 tiles stays quick.
]]

local MaterialService = game:GetService("MaterialService")

local Displacement = require(script.Parent.Parent.Core.Displacement)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Query = require(script.Parent.Parent.Scene.Query)
local Session = require(script.Parent.Parent.Scene.Session)
local Recording = require(script.Parent.Recording)

type Opened = TerrainInstance.Opened

export type Change = {
	material: Enum.Material?,
	color: Color3?,
	-- Empty for the base material.
	variant: string?,
}

-- Yield every this many parts on big unbaked selections, so Studio stays responsive.
local PARTS_PER_YIELD = 2000

local Appearance = {}

local materials: { Enum.Material }? = nil

-- Terrain-only materials, which a part accepts but cannot really use.
local TERRAIN_ONLY: { [Enum.Material]: true } = {
	[Enum.Material.Air] = true,
	[Enum.Material.Water] = true,
}

-- Materials a part can use, sorted by display name.
function Appearance.materials(): { Enum.Material }
	local cached = materials
	if cached then
		return cached
	end
	local list: { Enum.Material } = {}
	local probe = Instance.new("Part")
	for _, item in Enum.Material:GetEnumItems() do
		if TERRAIN_ONLY[item] then
			continue
		end
		if pcall(function()
			probe.Material = item
		end) and probe.Material == item then
			table.insert(list, item)
		end
	end
	probe:Destroy()
	table.sort(list, function(a: Enum.Material, b: Enum.Material)
		return Appearance.label(a) < Appearance.label(b)
	end)
	materials = list
	return list
end

-- "SmoothPlastic" -> "Smooth Plastic".
function Appearance.label(material: Enum.Material): string
	return (material.Name:gsub("(%l)(%u)", "%1 %2"))
end

-- Names of the material variants in MaterialService (including folders) for `material`.
function Appearance.variants(material: Enum.Material): { string }
	local seen: { [string]: true } = {}
	local names: { string } = {}
	for _, inst in MaterialService:GetDescendants() do
		if inst:IsA("MaterialVariant") and inst.BaseMaterial == material and not seen[inst.Name] then
			seen[inst.Name] = true
			table.insert(names, inst.Name)
		end
	end
	table.sort(names)
	return names
end

-- The parts showing a tile's own look: its baked union and the wedges of unpainted triangles
-- (painted ones keep their looks). Hidden hole wedges are included, so a restored triangle
-- shows the tile's look.
local function partsOf(model: Model): { BasePart }
	local parts: { BasePart } = {}
	local surface = model:FindFirstChild("Surface")
	if surface and surface:IsA("BasePart") then
		table.insert(parts, surface)
	end
	local config = model:FindFirstChild("DispData")
	local triLooks = if config then config:GetAttribute("TriLooks") else nil
	-- With points removed, wedges follow the shown triangles, not the saved grid.
	local opened = if config and config:GetAttribute("Removed") ~= nil then Session.get(model) else nil
	local tris = model:FindFirstChild("Tris")
	if tris then
		for _, child in tris:GetChildren() do
			local n = tonumber(child.Name)
			if not child:IsA("BasePart") or not n then
				continue
			end
			local t = (n + 1) // 2
			local own
			if opened then
				own = t <= Displacement.triangleCount(opened.disp) and Displacement.shownLookIndex(opened.disp, t) <= 0
			else
				local digit = if typeof(triLooks) == "string" then string.sub(triLooks, t, t) else "0"
				own = digit == "0" or digit == "-"
			end
			if own then
				table.insert(parts, child)
			end
		end
	end
	return parts
end

--[[
	Applies `change` to the selected tiles as one undo step named `name`. A new base material
	without a variant clears the variant (a variant belongs to one base material). Returns how
	many tiles changed; tiles that already look like that are skipped, and nothing is recorded
	when none would change.
]]
function Appearance.apply(change: Change, name: string): number
	type Plan = { model: Model, look: Query.Appearance }
	local plans: { Plan } = {}
	for _, model in Query.selectedModels() do
		local current = Query.appearanceOf(model)
		if not current then
			continue
		end
		local material = change.material or current.material
		local variant = change.variant or (if material ~= current.material then "" else current.variant)
		local color = change.color or current.color
		if material ~= current.material or variant ~= current.variant or color ~= current.color then
			table.insert(plans, { model = model, look = { material = material, color = color, variant = variant } })
		end
	end
	if #plans == 0 then
		return 0
	end

	Recording.run(name, function()
		local written = 0
		for _, plan in plans do
			local look = plan.look
			local config = plan.model:FindFirstChild("DispData")
			if config then
				config:SetAttribute("Material", look.material.Name)
				config:SetAttribute("Color", look.color)
				config:SetAttribute("MaterialVariant", if look.variant == "" then nil else look.variant)
			end
			-- Keep an open copy in step, so the next rebuild or bake uses the new look.
			local opened = Session.peek(plan.model)
			if opened then
				opened.disp.material = look.material
				opened.disp.color = look.color
				opened.disp.materialVariant = look.variant
			end
			for _, part in partsOf(plan.model) do
				part.Material = look.material
				part.Color = look.color
				part.MaterialVariant = look.variant
				written += 1
				if written % PARTS_PER_YIELD == 0 then
					task.wait()
				end
			end
		end
	end)
	return #plans
end

-- Removes painted materials from the selected tiles (back to each tile's own look), as one undo
-- step. Baked tiles show wedges until baked again. Returns how many tiles changed.
function Appearance.clearPaint(): number
	local targets: { Opened } = {}
	for _, opened in Query.selectedTiles() do
		if Displacement.isPainted(opened.disp) then
			table.insert(targets, opened)
		end
	end
	if #targets == 0 then
		return 0
	end
	Recording.run("Strata clear painted materials", function()
		for _, opened in targets do
			local disp = opened.disp
			local triangles: { number } = {}
			-- Holes stay deleted: they are not paint.
			for t, index in disp.triLooks do
				if index > 0 then
					disp.triLooks[t] = 0
					table.insert(triangles, t)
				end
			end
			Session.updateLooks(opened, triangles)
			TerrainInstance.save(opened)
		end
		Recording.autoBake()
	end)
	return #targets
end

-- Brings back the deleted triangles of the selected tiles (in each tile's own look), as one undo
-- step. Returns how many tiles changed.
function Appearance.restoreHoles(): number
	local targets: { Opened } = {}
	for _, opened in Query.selectedTiles() do
		if Displacement.holeCount(opened.disp) > 0 then
			table.insert(targets, opened)
		end
	end
	if #targets == 0 then
		return 0
	end
	Recording.run("Strata restore triangles", function()
		for _, opened in targets do
			local disp = opened.disp
			local triangles: { number } = {}
			for t, index in disp.triLooks do
				if index == Displacement.HOLE then
					disp.triLooks[t] = 0
					table.insert(triangles, t)
				end
			end
			Session.updateLooks(opened, triangles)
			TerrainInstance.save(opened)
		end
		Recording.autoBake()
	end)
	return #targets
end

-- Copies the material, color and variant of `part` onto the selected tiles.
function Appearance.copyFrom(part: BasePart): number
	return Appearance.apply(
		{ material = part.Material, color = part.Color, variant = part.MaterialVariant },
		"Strata copy appearance"
	)
end

return Appearance
