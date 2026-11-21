--!strict
--[[
	Turns faces of parts into displacements, like creating displacements on brush faces in
	Hammer. Works on block Parts and wedges (see Core/PartFaces). Either the selected parts are
	converted with a face mode (Top, Top + sides, All faces), or the faces picked in Pick faces
	mode are.

	Each face is split into tiles by the tile size; faces of one part that share an edge get the
	same tile count along it, so all tiles start out sewn, including around corners. Faces of one
	part (or a face with several tiles) are grouped in a "TerrainArea" model. The source part is
	removed; Ctrl+Z restores it. Faces thinner than PartFaces.MIN_FACE_SIZE are skipped.
]]

local Selection = game:GetService("Selection")

local Displacement = require(script.Parent.Parent.Core.Displacement)
local PartFaces = require(script.Parent.Parent.Core.PartFaces)
local TerrainInstance = require(script.Parent.Parent.Core.TerrainInstance)
local Units = require(script.Parent.Parent.Core.Units)
local Query = require(script.Parent.Parent.Scene.Query)
local Session = require(script.Parent.Parent.Scene.Session)
local Settings = require(script.Parent.Parent.State.Settings)
local Recording = require(script.Parent.Recording)

type Face = PartFaces.Face

export type Result = {
	-- Displacements (tiles) created, and the parts they were made from.
	created: number,
	parts: number,
	-- Selected objects that are not block Parts or wedges.
	skipped: number,
	-- Faces skipped for being thinner than PartFaces.MIN_FACE_SIZE.
	skippedFaces: number,
	-- Tiles baked into unions, and tiles whose bake failed (they stay as wedges).
	baked: number,
	bakeFailed: number,
	bakeError: string?,
}

export type Plan = {
	parts: number,
	faces: number,
	tiles: number,
	wedges: number,
	-- Faces that will be converted but are thinner than PartFaces.THIN_FACE_SIZE.
	thinFaces: number,
	-- Faces that will be skipped (thinner than PartFaces.MIN_FACE_SIZE).
	skippedFaces: number,
	-- The most tiles any one part would make; Create refuses parts above MAX_TILES_PER_PART.
	largestPart: number,
}

export type Pick = {
	part: BasePart,
	face: PartFaces.FaceId,
}

type Job = {
	part: BasePart,
	faces: { Face },
}

-- Keeps one click from freezing Studio for a long time.
local MAX_TILES_PER_PART = 400
-- Yield every few tiles so Studio stays responsive while building large areas.
local TILES_PER_YIELD = 8

local Create = {}

Create.MAX_TILES_PER_PART = MAX_TILES_PER_PART

function Create.wedgesPerTile(power: number): number
	local quads = bit32.lshift(1, power)
	return quads * quads * 4
end

-- Splits faces into usable and too thin to convert.
local function usable(faces: { Face }): ({ Face }, number)
	local result = {}
	local skipped = 0
	for _, face in faces do
		if math.min(face.width, face.depth) >= PartFaces.MIN_FACE_SIZE then
			table.insert(result, face)
		else
			skipped += 1
		end
	end
	return result, skipped
end

-- The work for the current selection and face mode.
local function selectionJobs(mode: PartFaces.Mode): ({ Job }, number)
	local jobs: { Job } = {}
	local skippedFaces = 0
	for _, part in Query.selectedParts() do
		local faces, skipped = usable(PartFaces.select(part, mode))
		skippedFaces += skipped
		if #faces > 0 then
			table.insert(jobs, { part = part, faces = faces })
		end
	end
	return jobs, skippedFaces
end

-- The work for picked faces, grouped per part.
local function pickJobs(picks: { Pick }): ({ Job }, number)
	local byPart: { [BasePart]: { Face } } = {}
	local order: { BasePart } = {}
	local skippedFaces = 0
	for _, pick in picks do
		local face = if pick.part.Parent then PartFaces.find(pick.part, pick.face) else nil
		if face then
			local faces, skipped = usable({ face })
			skippedFaces += skipped
			if #faces > 0 then
				if not byPart[pick.part] then
					byPart[pick.part] = {}
					table.insert(order, pick.part)
				end
				table.insert(byPart[pick.part], faces[1])
			end
		end
	end
	local jobs: { Job } = {}
	for _, part in order do
		table.insert(jobs, { part = part, faces = byPart[part] })
	end
	return jobs, skippedFaces
end

local function planJobs(jobs: { Job }, skippedFaces: number, power: number, tileSize: number): Plan
	local faces, tiles, thin, largest = 0, 0, 0, 0
	for _, job in jobs do
		local partTiles = 0
		for _, face in job.faces do
			local nx, nz = PartFaces.tileCounts(face, tileSize)
			faces += 1
			partTiles += nx * nz
			if math.min(face.width, face.depth) < PartFaces.THIN_FACE_SIZE then
				thin += 1
			end
		end
		tiles += partTiles
		largest = math.max(largest, partTiles)
	end
	return {
		parts = #jobs,
		faces = faces,
		tiles = tiles,
		wedges = tiles * Create.wedgesPerTile(power),
		thinFaces = thin,
		skippedFaces = skippedFaces,
		largestPart = largest,
	}
end

-- What creating from the current selection would produce.
function Create.plan(power: number, tileSize: number, mode: PartFaces.Mode): Plan
	local jobs, skippedFaces = selectionJobs(mode)
	return planJobs(jobs, skippedFaces, power, tileSize)
end

-- What creating from picked faces would produce.
function Create.planPicks(power: number, tileSize: number, picks: { Pick }): Plan
	local jobs, skippedFaces = pickJobs(picks)
	return planJobs(jobs, skippedFaces, power, tileSize)
end

local function createTile(
	facePivot: CFrame,
	center: Vector3,
	tileX: number,
	tileZ: number,
	power: number,
	part: BasePart,
	parent: Instance,
	name: string,
	skipWedges: boolean
): TerrainInstance.Opened
	local hx, hz = tileX / 2, tileZ / 2
	-- Ordered so the face normal points along the pivot's +Y, the face's outward normal (see
	-- Displacement corner order).
	local corners = {
		Vector3.new(-hx, 0, -hz),
		Vector3.new(-hx, 0, hz),
		Vector3.new(hx, 0, hz),
		Vector3.new(hx, 0, -hz),
	}
	-- Hammer's start corner: rotate so corner 1 is the one nearest the world-space minimum (in
	-- Hammer axes), which fixes the grid orientation the same way Hammer does.
	local pivot = facePivot * CFrame.new(center)
	local hammerPoints = table.create(4)
	for k, corner in corners do
		hammerPoints[k] = Units.toHammer(pivot * corner)
	end
	corners = Displacement.rotateCorners(corners, Displacement.startCorner(hammerPoints))
	local disp = Displacement.new(corners, power, part.Material, part.Color)
	disp.materialVariant = part.MaterialVariant
	return TerrainInstance.create(disp, pivot, parent, name, skipWedges)
end

local function createJob(
	job: Job,
	parent: Instance,
	power: number,
	tileSize: number,
	created: { TerrainInstance.Opened },
	skipWedges: boolean
): Model
	local part = job.part
	local total = 0
	for _, face in job.faces do
		local nx, nz = PartFaces.tileCounts(face, tileSize)
		total += nx * nz
	end
	if total > MAX_TILES_PER_PART then
		error(`{part.Name} would make {total} tiles (limit {MAX_TILES_PER_PART}); use a larger tile size`, 0)
	end

	local single = #job.faces == 1
	if single and total == 1 then
		local face = job.faces[1]
		local opened = createTile(face.pivot, Vector3.zero, face.width, face.depth, power, part, parent, "Displacement", skipWedges)
		table.insert(created, opened)
		part.Parent = nil
		return opened.model
	end

	local area = Instance.new("Model")
	area.Name = "TerrainArea"
	-- One face keeps the face pivot (as before); several faces use the part's own pivot.
	area.WorldPivot = if single then job.faces[1].pivot else part.CFrame
	area.Parent = parent

	local built = 0
	for _, face in job.faces do
		local nx, nz = PartFaces.tileCounts(face, tileSize)
		local tileX, tileZ = face.width / nx, face.depth / nz
		for ix = 1, nx do
			for iz = 1, nz do
				local center = Vector3.new(-face.width / 2 + (ix - 0.5) * tileX, 0, -face.depth / 2 + (iz - 0.5) * tileZ)
				local name = if single then `Disp_{ix}_{iz}` else `{face.id}_{ix}_{iz}`
				table.insert(created, createTile(face.pivot, center, tileX, tileZ, power, part, area, name, skipWedges))
				built += 1
				if built % TILES_PER_YIELD == 0 then
					task.wait()
				end
			end
		end
	end
	part.Parent = nil
	return area
end

local function run(jobs: { Job }, skippedObjects: number, skippedFaces: number, power: number, tileSize: number): Result
	if #jobs == 0 then
		return { created = 0, parts = 0, skipped = skippedObjects, skippedFaces = skippedFaces, baked = 0, bakeFailed = 0, bakeError = nil }
	end

	local models: { Instance } = {}
	local created: { TerrainInstance.Opened } = {}
	local bakeResult: Session.BakeResult? = nil
	Recording.run("Strata create terrain", function()
		local settings = Settings.get()
		-- New tiles are flat, and a flat tile bakes from a single slab, so when it is baked right
		-- away its wedges are never needed.
		local skipWedges = settings.autoBake
		for _, job in jobs do
			local parent = job.part.Parent
			if parent then
				table.insert(models, createJob(job, parent, power, tileSize, created, skipWedges))
			end
		end
		for _, opened in created do
			Session.track(opened)
		end
		if settings.autoBake then
			bakeResult = Session.bake(created, settings.smoothingAngle)
			-- A tile whose bake failed would have nothing to show; give it its wedges.
			for _, opened in created do
				if not TerrainInstance.isBaked(opened.model) then
					TerrainInstance.ensureWedges(opened)
				end
			end
		end
	end)

	Selection:Set(models)
	return {
		created = #created,
		parts = #models,
		skipped = skippedObjects,
		skippedFaces = skippedFaces,
		baked = if bakeResult then bakeResult.baked else 0,
		bakeFailed = if bakeResult then bakeResult.failed else 0,
		bakeError = if bakeResult then bakeResult.firstError else nil,
	}
end

-- Converts the selected parts' faces chosen by `mode`.
function Create.fromSelection(power: number, tileSize: number, mode: PartFaces.Mode): Result
	local jobs, skippedFaces = selectionJobs(mode)
	local skippedObjects = #Selection:Get() - #Query.selectedParts()
	return run(jobs, skippedObjects, skippedFaces, power, tileSize)
end

-- Converts picked faces.
function Create.fromPicks(power: number, tileSize: number, picks: { Pick }): Result
	local jobs, skippedFaces = pickJobs(picks)
	return run(jobs, 0, skippedFaces, power, tileSize)
end

return Create
