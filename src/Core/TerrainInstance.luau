--!strict
--[[
	Instance layout of a Strata displacement Model:

		<Model>  tagged StrataDisplacement, pivot = displacement origin
		├─ DispData (Configuration)  editable source data stored as attributes
		├─ Tris (Folder)             generated WedgeParts while editing
		├─ Surface (UnionOperation)  merged wedges for the tile's base look when baked
		└─ Surface_1, Surface_2 ...  one union per painted look (1, 2, ...) when baked

	Each displacement is either editing (wedges) or baked (unions). Baking merges wedges so
	Roblox projects material textures continuously across the surface instead of rotating them per
	triangle. Because a UnionOperation holds only one material, painted looks bake into separate
	unions; `Surface` is omitted if paint covers the entire tile. Deleted triangles (holes) retain
	hidden wedges while editing and are excluded from all unions. Editing a baked tile rebuilds
	its wedges from DispData.

	Because models contain only standard instances and attributes, they can be published,
	inserted, and reopened for editing in any Studio session.
]]

local HttpService = game:GetService("HttpService")
local GeometryService = game:GetService("GeometryService")
local CollectionService = game:GetService("CollectionService")

local Core = script.Parent

local Simplify = require(Core.Simplify)
local Displacement = require(Core.Displacement)
local WedgeBuilder = require(Core.WedgeBuilder)

local DATA_NAME = "DispData"
local TRIS_NAME = "Tris"
local SURFACE_NAME = "Surface"
-- Unique per-save revision stamped on DispData so Session can detect which tiles actually
-- changed across undo/redo instead of dropping the whole cache. Prefixed with a per-session
-- GUID so a reloaded session or Team Create editor never collides with an already-saved Rev.
local REV_ATTR = "Rev"
local SESSION_ID = HttpService:GenerateGUID(false)
local nextRev = 0
-- Tracks DispData Configurations currently inside a synchronous Strata write (for Immediate
-- SignalBehavior). Deferred SignalBehavior is handled by comparing live attributes against
-- `opened.attrs` rather than relying on deferred callback ordering.
local internalWriting: { [Configuration]: true } = {}

-- Size and clearance depth of the temporary anchor cube used to align union texture axes
-- (sits well below the wedges, which extend WedgeBuilder.THICKNESS below the surface).
local ANCHOR_SIZE = 0.05
local ANCHOR_DEPTH = 1

-- Threshold below which a field vector or offset counts as flat (zero vectors store length 1e-5;
-- see Displacement.normalizeWithLength).
local FLAT_EPSILON = 1e-4

export type Opened = {
	model: Model,
	config: Configuration,
	disp: Displacement.Displacement,
	wedges: WedgeBuilder.Wedges,
	-- Local-space AABB of the current surface for fast spatial culling.
	boundsMin: Vector3,
	boundsMax: Vector3,
	-- Last Rev attribute read from or written to `config` (nil on tiles never saved with Rev).
	rev: string?,
	-- Snapshot of `config:GetAttributes()` from the last open/save so Session can tell Strata's
	-- own writes apart from direct Studio Properties edits or undo/redo under any SignalBehavior.
	attrs: { [string]: unknown },
}

export type BakeOptions = {
	-- UnionOperation.SmoothingAngle applied to baked unions.
	smoothingAngle: number,
	-- Simplify angle in degrees (0 = off): omit points on ground flatter than this.
	simplifyAngle: number,
	-- Height tolerance in studs (0 = off): also omit points within this distance of surrounding surface.
	tolerance: number,
	-- Omit tile edge points lying on straight stretches.
	simplifyEdges: boolean,
	-- Bake flat, single-look rectangular tiles to a plain Part instead of a union.
	flatPart: boolean,
	-- Disable CastShadow on flat baked tiles.
	flatNoShadow: boolean,
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

local function readRev(config: Configuration): string?
	local value = config:GetAttribute(REV_ATTR)

	return if typeof(value) == "string" then value else nil
end

-- Returns the displacement Model that is or contains `inst`, if any.
function TerrainInstance.of(inst: Instance): Model?
	local node: Instance? = inst

	while node do
		if node:IsA("Model") and CollectionService:HasTag(node, TerrainInstance.TAG) then
			return node
		end

		node = node.Parent
	end

	return nil
end

-- Creates a displacement Model. Pass `skipWedges = true` when baking immediately (ensureWedges
-- builds wedges on demand if edited later).
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
		rev = readRev(config),
		attrs = config:GetAttributes(),
	}
end

-- Opens an existing displacement Model without mutating the place (if Tris is missing, an
-- unparented Folder is held until ensureTris/ensureWedges runs inside a recording).
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
	end

	local boundsMin, boundsMax = computeBounds(disp)

	return {
		model = model,
		config = config,
		disp = disp,
		wedges = WedgeBuilder.attach(folder),
		boundsMin = boundsMin,
		boundsMax = boundsMax,
		rev = readRev(config),
		attrs = config:GetAttributes(),
	}
end

-- Runs `writer` against `config` while marking it as an internal Strata write, then stamps a
-- session-unique Rev and snapshots `opened.attrs` synchronously. Works under both Immediate
-- and Deferred SignalBehavior without relying on deferred callback ordering.
function TerrainInstance.writeConfig(config: Configuration, opened: Opened?, writer: () -> ())
	internalWriting[config] = true

	local ok, err = pcall(function ()
		writer()
		nextRev += 1

		local rev = `{SESSION_ID}:{nextRev}`
		config:SetAttribute(REV_ATTR, rev)

		if opened then
			opened.rev = rev
			opened.attrs = config:GetAttributes()
		end
	end)

	internalWriting[config] = nil

	if not ok then
		error(err, 0)
	end
end

function TerrainInstance.isInternalWrite(config: Configuration): boolean
	return internalWriting[config] == true
end

function TerrainInstance.currentRev(config: Configuration): string?
	return readRev(config)
end

-- Ensures `opened.wedges.folder` is parented under `opened.model` before writing wedges.
function TerrainInstance.ensureTris(opened: Opened)
	local existing = opened.model:FindFirstChild(TRIS_NAME)

	if existing and existing:IsA("Folder") then
		if opened.wedges.folder ~= existing then
			opened.wedges = WedgeBuilder.attach(existing)
		end

		return
	end

	opened.wedges.folder.Parent = opened.model
end

-- Re-indexes existing wedges after undo/redo when a tile's DispData did not change (for example,
-- undoing a Bake brings WedgeParts back into Tris without touching DispData).
function TerrainInstance.reattachWedges(opened: Opened)
	local existing = opened.model:FindFirstChild(TRIS_NAME)

	if existing and existing:IsA("Folder") then
		opened.wedges = WedgeBuilder.attach(existing)
	else
		table.clear(opened.wedges.parts)
	end
end

-- Baked surfaces are UnionOperations, or plain Parts when flatPart is enabled.
local function isSurfacePart(inst: Instance): boolean
	return inst:IsA("UnionOperation") or inst:IsA("Part")
end

-- Returns the baked surface for the tile's base look, if baked and at least one triangle uses it.
function TerrainInstance.surface(model: Model): BasePart?
	local surface = model:FindFirstChild(SURFACE_NAME)

	if surface and isSurfacePart(surface) and surface:IsA("BasePart") then
		return surface
	end

	return nil
end

-- Parses the look index of a baked surface (0 for "Surface", k for "Surface_k"), or nil.
function TerrainInstance.surfaceLook(inst: Instance): number?
	if not isSurfacePart(inst) then
		return nil
	end

	if inst.Name == SURFACE_NAME then
		return 0
	end

	local k = string.match(inst.Name, "^" .. SURFACE_NAME .. "_(%d+)$")

	return if k then tonumber(k) else nil
end

-- Returns all baked surface parts of `model` (base look and every painted look).
function TerrainInstance.surfaces(model: Model): { BasePart }
	local result: { BasePart } = {}

	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and TerrainInstance.surfaceLook(child) ~= nil then
			table.insert(result, child)
		end
	end

	return result
end

function TerrainInstance.isBaked(model: Model): boolean
	return #TerrainInstance.surfaces(model) > 0
end

-- Unparents baked surfaces rather than destroying them so ChangeHistoryService can undo cleanly.
function TerrainInstance.removeSurfaces(model: Model)
	for _, surface in TerrainInstance.surfaces(model) do
		surface.Parent = nil
	end
end

-- Returns a rendered part showing the tile's base look (baked Surface or first base-look wedge),
-- or nil when painted looks cover the entire tile.
local function shownPart(opened: Opened): BasePart?
	local surface = TerrainInstance.surface(opened.model)

	if surface then
		return surface
	end

	if TerrainInstance.isBaked(opened.model) then
		return nil
	end

	for t = 1, Displacement.triangleCount(opened.disp) do
		if Displacement.shownLookIndex(opened.disp, t) == 0 then
			local wedge = opened.wedges.parts[t * 2 - 1]

			return if wedge and wedge.Parent == opened.wedges.folder then wedge else nil
		end
	end

	return nil
end

-- Syncs material, color, and material variant changes made directly via Studio tools (Properties,
-- Material Manager) back into DispData before rebuilding or baking so they are not overwritten.
-- Returns whether any appearance field changed and was saved.
function TerrainInstance.adoptAppearance(opened: Opened): boolean
	local disp = opened.disp
	local changed = false
	local part = shownPart(opened)

	if
		part
		and not (part.Material == disp.material and part.Color == disp.color and part.MaterialVariant == disp.materialVariant)
	then
		disp.material = part.Material
		disp.color = part.Color
		disp.materialVariant = part.MaterialVariant
		changed = true
	end

	-- Sync painted looks from their baked unions (individual painted wedges are not checked).
	for _, surface in TerrainInstance.surfaces(opened.model) do
		local index = TerrainInstance.surfaceLook(surface)
		local look = if index and index > 0 then disp.looks[index] else nil

		if
			look
			and not (surface.Material == look.material and surface.Color == look.color and surface.MaterialVariant == look.variant)
		then
			disp.looks[index :: number] = { material = surface.Material, color = surface.Color, variant = surface.MaterialVariant }
			changed = true
		end
	end

	if changed then
		TerrainInstance.writeConfig(opened.config, opened, function ()
			Displacement.save(disp, opened.config)
		end)
	end

	return changed
end

-- Prepares a tile for editing: adopts Studio appearance edits, unparents baked surfaces, and
-- rebuilds wedges if missing or stale (for example after a power change or manual deletion).
-- Returns whether wedges had to be rebuilt.
function TerrainInstance.ensureWedges(opened: Opened): boolean
	TerrainInstance.adoptAppearance(opened)
	TerrainInstance.removeSurfaces(opened.model)
	TerrainInstance.ensureTris(opened)

	if not WedgeBuilder.isComplete(opened.disp, opened.wedges) then
		WedgeBuilder.rebuild(opened.disp, opened.wedges, opened.model:GetPivot())
		return true
	end

	return false
end

-- Computes a single-slab CFrame and size (local space) for flat rectangular tiles, or nil if
-- sculpted or non-rectangular. Unioning a single slab is ~70x faster than 64-1,024 wedges.
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
	-- Hang `thickness` below the surface to match WedgeBuilder's depth.
	local center = (c[1] + c[3]) / 2 + normal * (disp.elevation - thickness / 2)

	return CFrame.fromMatrix(center, across.Unit, normal), Vector3.new(across.Magnitude, thickness, along.Magnitude)
end

local function union(anchor: BasePart, parts: { BasePart }, collision: Enum.CollisionFidelity): UnionOperation?
	local ok, result = pcall(function ()
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

-- Unions `parts` onto the orientation anchor cube, then subtracts the cube away. Checks against
-- `extent` to detect unions that silently collapse to the anchor cube alone. Yields.
local function bakeGroup(anchor: BasePart, anchorCFrame: CFrame, parts: { BasePart }, extent: number): UnionOperation
	local function usable(result: UnionOperation?): boolean
		return result ~= nil and result.Size.Magnitude >= extent * 0.5
	end

	-- Use cheap Box collision for the intermediate union since SubtractAsync builds the final
	-- precise collision mesh, cutting bake time by 25-50%.
	local merged = union(anchor, parts, Enum.CollisionFidelity.Box)

	if not merged or not usable(merged) then
		if merged then
			merged:Destroy()
		end

		error("the union came out empty; the displacement was left as wedges", 0)
	end

	-- Subtract the anchor cube with a slightly larger cutter; the union keeps its original CFrame.
	local cutter = Instance.new("Part")
	cutter.Anchored = true
	cutter.Size = Vector3.new(ANCHOR_SIZE * 3, ANCHOR_SIZE * 3, ANCHOR_SIZE * 3)
	cutter.CFrame = anchorCFrame

	local cutOk, cutResult = pcall(function ()
		return GeometryService:SubtractAsync(merged, { cutter }, {
			CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition,
			RenderFidelity = Enum.RenderFidelity.Precise,
			SplitApart = false,
		})
	end)

	cutter:Destroy()

	local cut = if cutOk and cutResult[1] and cutResult[1]:IsA("UnionOperation") then cutResult[1] else nil

	if cut and usable(cut) then
		merged:Destroy()
		return cut
	end

	-- If subtraction failed, re-union with precise collision and leave the tiny buried anchor
	-- rather than shipping Box collision.
	merged:Destroy()

	local precise = union(anchor, parts, Enum.CollisionFidelity.PreciseConvexDecomposition)

	if not precise or not usable(precise) then
		if precise then
			precise:Destroy()
		end

		error("the union came out empty; the displacement was left as wedges", 0)
	end

	return precise
end

-- Checks whether all grid triangles stay within `angle` degrees of `faceNormal` and all vertices
-- lie within `height` studs along `faceNormal` (used to disable shadows on flat tiles).
local function isFlat(disp: Displacement.Displacement, positions: { Vector3 }, faceNormal: Vector3, angle: number, height: number): boolean
	local low, high = math.huge, -math.huge

	for _, position in positions do
		local h = position:Dot(faceNormal)
		low, high = math.min(low, h), math.max(high, h)
	end

	if high - low > height then
		return false
	end

	local cosLimit = math.cos(math.rad(angle))

	for g = 1, Displacement.gridTriangleCount(disp) do
		local a, b, c = Displacement.gridTriangle(disp, g)
		local cross = (positions[b] - positions[a]):Cross(positions[c] - positions[a])

		if cross.Magnitude > 1e-9 and math.abs(cross.Unit:Dot(faceNormal)) < cosLimit then
			return false
		end
	end

	return true
end

-- Converts a slab's CFrame and size to pivot-aligned rotation (permuting size components) when
-- axis-aligned with the pivot so a plain Part shares texture axes with baked unions.
local function alignedSlab(slabCFrame: CFrame, slabSize: Vector3): (CFrame, Vector3)
	local axes = { slabCFrame.RightVector, slabCFrame.UpVector, slabCFrame.LookVector }
	local extents = { slabSize.X, slabSize.Y, slabSize.Z }
	local size = Vector3.zero

	for i, axis in axes do
		local x, y, z = math.abs(axis.X), math.abs(axis.Y), math.abs(axis.Z)

		if math.max(x, y, z) < 1 - 1e-4 then
			return slabCFrame, slabSize
		end

		size += Vector3.new(x, y, z) * extents[i]
	end

	return CFrame.new(slabCFrame.Position), size
end

-- Bakes `opened` into one UnionOperation per look (or a plain Part for flat tiles when
-- `options.flatPart` is set). Optimizations affect only the baked geometry, leaving editable
-- DispData untouched:
--   - simplifyAngle / tolerance / simplifyEdges build unions from a temporarily simplified copy
--     while keeping painted borders, hole outlines, and straight seams (within 0.005 studs).
--   - flatPart keeps a flat single-look rectangular slab as a plain Part without calling CSG.
--   - flatNoShadow disables CastShadow on flat tiles.
-- Yields. On failure, discards all partial unions and ensures wedges remain visible. Returns
-- (beforeTriangles, afterTriangles) where a flat slab counts as 2, or (0, 0) if skipped.
function TerrainInstance.bake(opened: Opened, options: BakeOptions): (number, number)
	if TerrainInstance.isBaked(opened.model) then
		return 0, 0
	end

	TerrainInstance.adoptAppearance(opened)

	local pivot = opened.model:GetPivot()
	local disp = opened.disp
	local faceNormal = Displacement.faceNormal(disp)
	local positions = Displacement.positions(disp, faceNormal)

	-- Groups non-hole shown triangles by look index in ascending order (base look 0 first).
	local function grouped(shape: Displacement.Displacement): ({ [number]: { number } }, { number }, boolean)
		local groups: { [number]: { number } } = {}
		local order: { number } = {}
		local holes = false

		for t = 1, Displacement.triangleCount(shape) do
			local index = Displacement.shownLookIndex(shape, t)

			if index == Displacement.HOLE then
				holes = true
				continue
			end

			local group = groups[index]

			if not group then
				group = {}
				groups[index] = group
				table.insert(order, index)
			end

			table.insert(group, t)
		end

		table.sort(order)
		return groups, order, holes
	end

	local groups, order, holes = grouped(disp)

	if #order == 0 then
		-- All triangles are deleted; nothing to union and hidden wedges stay in place.
		return 0, 0
	end

	local before = 0

	for _, group in groups do
		before += #group
	end

	-- Flat single-look tiles with no holes can bake from a single slab instead of wedges.
	local slab: Part? = nil
	local slabCFrame, slabSize = nil, nil

	if #order == 1 and not holes then
		slabCFrame, slabSize = flatSlab(disp)
	end

	local noShadow = options.flatNoShadow
		and isFlat(disp, positions, faceNormal, math.max(options.simplifyAngle, 1), math.max(options.tolerance, 1e-3))

	-- Fast path: flat slab kept directly as a plain Part with no CSG union.
	if slabCFrame and slabSize and options.flatPart then
		local cframe, size = alignedSlab(slabCFrame, slabSize)
		local index = order[1]
		local look = if index == 0 then Displacement.baseLook(disp) else disp.looks[index]

		local part = Instance.new("Part")
		part.Name = if index == 0 then SURFACE_NAME else `{SURFACE_NAME}_{index}`
		part.Anchored = true
		part.CanTouch = false
		part.Size = size
		part.CFrame = pivot * cframe
		part.Material = look.material
		part.Color = look.color
		part.MaterialVariant = look.variant
		part.CastShadow = not noShadow
		part.Parent = opened.model

		for _, wedge in opened.wedges.parts do
			wedge.Parent = nil
		end

		table.clear(opened.wedges.parts)
		return before, 2
	end

	-- Determine geometry source: slab, simplified copy, or the tile's own wedges.
	local shape = disp

	if slabCFrame and slabSize then
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = slabSize
		part.CFrame = pivot * slabCFrame
		slab = part
	elseif options.simplifyAngle > 0 or options.tolerance > 0 or options.simplifyEdges then
		local extra, mesh = Simplify.flatPointsQuick(disp, {
			angle = options.simplifyAngle,
			tolerance = options.tolerance,
			edges = options.simplifyEdges,
		})

		if next(extra) ~= nil then
			local copy = table.clone(disp)
			local removed = table.clone(disp.removed)

			for v in extra do
				removed[v] = true
			end

			copy.removed = removed
			-- Reuse the final triangulation from Simplify instead of rebuilding it.
			copy.meshCache = mesh
			shape = copy
			groups, order, holes = grouped(shape)
		end
	end

	local temporary = shape ~= disp

	if not slab and not temporary then
		TerrainInstance.ensureWedges(opened)
	end

	-- A union inherits its CFrame (and thus its material texture projection space) from its first
	-- part. Anchoring every union to a tiny pivot-aligned cube placed below the lowest vertex
	-- aligns texture axes and origins across neighboring tiles and painted borders, while keeping
	-- the cube clear of the surface (overlapping cubes can cause UnionAsync to return only the
	-- cube). Helper parts stay unparented so they never enter the workspace or undo history.
	-- Use grid triangle 1 regardless of removed points so the texture origin stays invariant.
	local i1, i2, i3 = Displacement.gridTriangle(disp, 1)
	local centroid = (positions[i1] + positions[i2] + positions[i3]) / 3
	local lowest = math.huge

	for _, position in positions do
		lowest = math.min(lowest, position:Dot(faceNormal))
	end

	local depth = centroid:Dot(faceNormal) - lowest + WedgeBuilder.THICKNESS + ANCHOR_DEPTH
	local anchorCFrame = CFrame.new(pivot * (centroid - faceNormal * depth)) * pivot.Rotation
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.Size = Vector3.new(ANCHOR_SIZE, ANCHOR_SIZE, ANCHOR_SIZE)
	anchor.CFrame = anchorCFrame

	local results: { [number]: UnionOperation } = {}
	local helpers: { BasePart } = {}

	local ok, err = pcall(function ()
		for _, index in order do
			local triangles = groups[index]
			local parts: { BasePart } = {}
			local min, max = Vector3.one * math.huge, -Vector3.one * math.huge

			for _, t in triangles do
				local a, b, c = Displacement.triangle(shape, t)

				for _, v in { a, b, c } do
					min = min:Min(positions[v])
					max = max:Max(positions[v])
				end

				if not slab and not temporary then
					table.insert(parts, opened.wedges.parts[t * 2 - 1])
					table.insert(parts, opened.wedges.parts[t * 2])
				end
			end

			if slab then
				parts = { slab }
			elseif temporary then
				parts = WedgeBuilder.temporary(shape, pivot, triangles)
				table.move(parts, 1, #parts, #helpers + 1, helpers)
			end

			results[index] = bakeGroup(anchor, anchorCFrame, parts, (max - min).Magnitude)
		end
	end)

	for _, part in helpers do
		part:Destroy()
	end

	anchor:Destroy()

	if slab then
		slab:Destroy()
	end

	if not ok then
		for _, result in results do
			result:Destroy()
		end

		-- Ensure wedges exist so a tile whose slab, temporary copy, or rebake failed stays visible.
		TerrainInstance.ensureWedges(opened)
		error(err, 0)
	end

	for index, surface in results do
		local look = if index == 0 then Displacement.baseLook(disp) else disp.looks[index]
		surface.Name = if index == 0 then SURFACE_NAME else `{SURFACE_NAME}_{index}`
		surface.Anchored = true
		surface.CanTouch = false
		surface.UsePartColor = true
		surface.Material = look.material
		surface.Color = look.color
		surface.MaterialVariant = look.variant
		surface.SmoothingAngle = options.smoothingAngle
		surface.CastShadow = not noShadow
		surface.Parent = opened.model
	end

	-- Unparent wedges rather than destroying them so undo can restore them.
	for _, part in opened.wedges.parts do
		part.Parent = nil
	end

	table.clear(opened.wedges.parts)

	if slab then
		return before, 2
	end

	local after = 0

	for _, group in groups do
		after += #group
	end

	return before, after
end

-- Recomputes cached local bounds; pass `positions` when already available.
function TerrainInstance.refreshBounds(opened: Opened, positions: { Vector3 }?)
	opened.boundsMin, opened.boundsMax = computeBounds(opened.disp, positions)
end

function TerrainInstance.save(opened: Opened)
	TerrainInstance.writeConfig(opened.config, opened, function ()
		Displacement.save(opened.disp, opened.config)
	end)
end

return TerrainInstance
