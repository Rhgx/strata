--!strict
--[[
	Updates the base appearance of existing tiles: material, color, and material variant (custom
	materials from Material Manager). Each tile holds one base material, since Roblox parts cannot
	blend materials the way Hammer's alpha painting does.

	Edits apply directly to the rendered parts (baked union or wedges) and to saved DispData
	attributes. Nothing is unbaked, rebaked, or rebuilt, and closed tiles stay closed so updating
	100 tiles remains fast.
]]

local MaterialService = game:GetService("MaterialService")

local Plugin = script.Parent.Parent
local Core = Plugin.Core
local Scene = Plugin.Scene

local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Recording = require(script.Parent.Recording)

type Opened = TerrainInstance.Opened

export type Change = {
	material: Enum.Material?,
	color: Color3?,
	-- Empty string resets to the base material.
	variant: string?,
}

-- Yield periodically on large unbaked selections so Studio stays responsive.
local PARTS_PER_YIELD = 2000

-- Terrain-only materials that BasePart accepts without rendering properly.
local TERRAIN_ONLY: { [Enum.Material]: true } = {
	[Enum.Material.Air] = true,
	[Enum.Material.Water] = true,
}

local Appearance = {}

local materials: { Enum.Material }? = nil

-- Returns every Enum.Material supported on BaseParts, sorted by display label.
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

		if pcall(function ()
			probe.Material = item
		end) and probe.Material == item then
			table.insert(list, item)
		end
	end

	probe:Destroy()

	table.sort(list, function (a: Enum.Material, b: Enum.Material)
		return Appearance.label(a) < Appearance.label(b)
	end)

	materials = list
	return list
end

-- Inserts spaces between camel-case words (e.g. "SmoothPlastic" -> "Smooth Plastic").
function Appearance.label(material: Enum.Material): string
	return (material.Name:gsub("(%l)(%u)", "%1 %2"))
end

-- Returns sorted MaterialVariant names under MaterialService (including folders) for `material`.
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

-- Collects parts displaying a tile's base look: its baked Surface union and unpainted wedges
-- (painted triangles keep their own looks). Hidden hole wedges are included so restoring a
-- triangle shows the updated base look.
local function partsOf(model: Model): { BasePart }
	local parts: { BasePart } = {}
	local surface = model:FindFirstChild("Surface")

	if surface and surface:IsA("BasePart") then
		table.insert(parts, surface)
	end

	local config = model:FindFirstChild("DispData")
	local triLooks = if config then config:GetAttribute("TriLooks") else nil
	-- With removed points, wedges correspond to shown triangles rather than the saved grid.
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

-- Applies `change` to selected tiles as one undo step named `name`. Switching the base material
-- without specifying a variant clears the variant, since variants bind to one base material.
-- Skips tiles that already match and records nothing if zero tiles change.
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

	Recording.run(name, function ()
		local written = 0

		for _, plan in plans do
			local look = plan.look
			local config = plan.model:FindFirstChild("DispData")

			if config then
				config:SetAttribute("Material", look.material.Name)
				config:SetAttribute("Color", look.color)
				config:SetAttribute("MaterialVariant", if look.variant == "" then nil else look.variant)
			end

			-- Keep any cached in-memory copy synchronized for future rebuilds or bakes.
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

-- Maps modified grid triangles to the shown triangles whose wedges need refreshing. When points
-- are removed, every shown triangle is refreshed because thin triangles covering no grid cell
-- center sample the grid triangle beneath their centroid.
local function shownTriangles(disp: Displacement.Displacement, grid: { number }): { number }
	if Displacement.mesh(disp) then
		local all = table.create(Displacement.triangleCount(disp))

		for t = 1, Displacement.triangleCount(disp) do
			all[t] = t
		end

		return all
	end

	local seen: { [number]: true } = {}
	local result: { number } = {}

	for _, g in grid do
		local t = Displacement.shownOf(disp, g)

		if t and not seen[t] then
			seen[t] = true
			table.insert(result, t)
		end
	end

	return result
end

-- Clears painted materials from selected tiles (restoring each tile's base look) as one undo
-- step. Baked tiles display wedges until baked again. Returns the number of modified tiles.
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

	Recording.run("Strata clear painted materials", function ()
		for _, opened in targets do
			local disp = opened.disp
			local triangles: { number } = {}

			-- Preserve holes; deleted triangles are not paint.
			for g, index in disp.triLooks do
				if index > 0 then
					disp.triLooks[g] = 0
					table.insert(triangles, g)
				end
			end

			Session.updateLooks(opened, shownTriangles(disp, triangles))
			TerrainInstance.save(opened)
		end

		Recording.autoBake()
	end)

	return #targets
end

-- Restores deleted triangles on selected tiles (using each tile's base look) as one undo step.
-- Returns the number of modified tiles.
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

	Recording.run("Strata restore triangles", function ()
		for _, opened in targets do
			local disp = opened.disp
			local triangles: { number } = {}

			for g, index in disp.triLooks do
				if index == Displacement.HOLE then
					disp.triLooks[g] = 0
					table.insert(triangles, g)
				end
			end

			Session.updateLooks(opened, shownTriangles(disp, triangles))
			TerrainInstance.save(opened)
		end

		Recording.autoBake()
	end)

	return #targets
end

-- Copies `part`'s material, color, and material variant onto the selected tiles.
function Appearance.copyFrom(part: BasePart): number
	return Appearance.apply(
		{ material = part.Material, color = part.Color, variant = part.MaterialVariant },
		"Strata copy appearance"
	)
end

return Appearance
