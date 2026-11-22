--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Converts faces of block Parts and wedges into displacements, analogous to Hammer's brush-face
	displacement creation (see Core/PartFaces). Accepts either selected parts with a face mode
	(Top, Top + sides, All faces) or faces chosen interactively in Pick faces mode.

	Each face is subdivided according to the tile size; adjacent faces on the same part receive
	matching tile counts along shared edges so every tile starts sewn, including around corners.
	Multi-face parts or multi-tile faces are grouped in a Model inheriting the source part's custom
	name (or the next free "TerrainArea" / "TerrainTile" when generic). Source parts are parented
	to nil so Ctrl+Z restores them. Faces thinner than PartFaces.MIN_FACE_SIZE are skipped.
]]

local Selection = game:GetService("Selection")

local Plugin = script.Parent.Parent
local Core = Plugin.Core
local State = Plugin.State
local Scene = Plugin.Scene

local Units = require(Core.Units)
local PartFaces = require(Core.PartFaces)
local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Recording = require(script.Parent.Recording)

type Face = PartFaces.Face

export type Result = {
	-- Number of displacement tiles created and source parts converted.
	created: number,
	parts: number,
	-- Selected instances that are neither block Parts nor wedges.
	skipped: number,
	-- Faces skipped for being thinner than PartFaces.MIN_FACE_SIZE.
	skippedFaces: number,
	-- Tiles baked into unions and tiles whose bake failed (left as wedges).
	baked: number,
	bakeFailed: number,
	bakeError: string?,
}

export type Plan = {
	parts: number,
	faces: number,
	tiles: number,
	wedges: number,
	-- Faces that will convert but are narrower than PartFaces.THIN_FACE_SIZE.
	thinFaces: number,
	-- Non-thin faces whose generated tiles would have an aspect ratio above STRETCHED_ASPECT.
	stretchedFaces: number,
	-- Faces that will be skipped (narrower than PartFaces.MIN_FACE_SIZE).
	skippedFaces: number,
	-- Highest tile count any single part would produce; Create rejects parts over MAX_TILES_PER_PART.
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

-- Prevents a single click with a tiny tile size from freezing Studio.
local MAX_TILES_PER_PART = 400
-- Warn on Create when generated tiles are stretched past this aspect ratio (2:1).
local STRETCHED_ASPECT = 2
-- Yield periodically while building large areas so Studio remains responsive.
local TILES_PER_YIELD = 8

local Create = {}

Create.MAX_TILES_PER_PART = MAX_TILES_PER_PART

local creating = false

-- Creates terrain from faces picked in Pick faces mode (invoked by the panel Create button or
-- Enter in the 3D view), posts the result, and stops the tool on success. On failure (such as
-- exceeding the per-part tile limit), keeps the tool and picks active so the user can adjust
-- settings and retry. Ignored while another picked creation is already running. Yields.
function Create.createPicked(power: number, tileSize: number, picks: { Pick }, stopTool: () -> ())
	if creating or #picks == 0 then
		return
	end

	creating = true
	local ok, result = pcall(Create.fromPicks, power, tileSize, picks)
	creating = false

	Create.report(ok, result, #picks)

	if ok then
		stopTool()
	end
end

-- Posts a Create result to the status bar. Pass the picked face count for Pick faces mode, or
-- nil when creating from selected parts.
function Create.report(ok: boolean, result: Result | string, picked: number?)
	if not ok or typeof(result) == "string" then
		Status.post("error", `Create failed: {result}`)
		return
	end

	local notes = {}

	if result.skipped > 0 then
		table.insert(notes, "skipped " .. Format.plural(result.skipped, "unsupported part"))
	end

	if result.skippedFaces > 0 then
		table.insert(notes, "skipped " .. Format.plural(result.skippedFaces, "face") .. " under 0.5 studs")
	end

	local suffix = if #notes > 0 then " (" .. table.concat(notes, "; ") .. ")" else ""
	local source = if picked then Format.plural(picked, "face") else Format.plural(result.parts, "part")

	if result.created == 0 then
		Status.post("warning", `Nothing created{suffix}.`)
	elseif result.bakeFailed > 0 then
		Status.post("error", `Created {result.created}; {result.bakeFailed} failed to bake: {result.bakeError}`)
	else
		Status.post("success", `Created {Format.plural(result.created, "tile")} from {source}{suffix}.`)
	end
end

function Create.wedgesPerTile(power: number): number
	local quads = bit32.lshift(1, power)

	return quads * quads * 4
end

-- Partitions faces into convertible faces and the count skipped for being too narrow.
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

-- Groups picked faces by their owning part while preserving selection order.
local function pickJobs(picks: { Pick }): ({ Job }, number)
	local byPart: { [BasePart]: { Face } } = {}
	local order: { BasePart } = {}
	local skippedFaces = 0

	for _, pick in picks do
		local face = if pick.part.Parent then PartFaces.find(pick.part, pick.face) else nil

		if not face then
			continue
		end

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

	local jobs: { Job } = {}

	for _, part in order do
		table.insert(jobs, { part = part, faces = byPart[part] })
	end

	return jobs, skippedFaces
end

local function planJobs(jobs: { Job }, skippedFaces: number, power: number, tileSize: number): Plan
	local faces, tiles, thin, stretched, largest = 0, 0, 0, 0, 0

	for _, job in jobs do
		local partTiles = 0

		for _, face in job.faces do
			local nx, nz = PartFaces.tileCounts(face, tileSize)
			faces += 1
			partTiles += nx * nz

			if math.min(face.width, face.depth) < PartFaces.THIN_FACE_SIZE then
				thin += 1
			else
				local tileW, tileD = face.width / nx, face.depth / nz
				local short = math.min(tileW, tileD)

				if short > 1e-6 and math.max(tileW, tileD) / short > STRETCHED_ASPECT then
					stretched += 1
				end
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
		stretchedFaces = stretched,
		skippedFaces = skippedFaces,
		largestPart = largest,
	}
end

-- Estimates the output of converting the current selection under `mode`.
function Create.plan(power: number, tileSize: number, mode: PartFaces.Mode): Plan
	local jobs, skippedFaces = selectionJobs(mode)

	return planJobs(jobs, skippedFaces, power, tileSize)
end

-- Estimates the output of converting `picks`.
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
	-- Ordered so the face normal aligns with the pivot's +Y outward normal (see Displacement corner order).
	local corners = {
		Vector3.new(-hx, 0, -hz),
		Vector3.new(-hx, 0, hz),
		Vector3.new(hx, 0, hz),
		Vector3.new(hx, 0, -hz),
	}

	-- Rotate corners so corner 1 is closest to the world-space minimum in Hammer coordinates,
	-- fixing grid orientation identically to Hammer.
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

-- Default Studio names replaced by numbered TerrainArea / TerrainTile names on conversion.
local GENERIC_PART_NAMES: { [string]: true } = {
	Part = true,
	Wedge = true,
	WedgePart = true,
}

-- Keeps meaningful builder-assigned names verbatim; numbers generic or blank part names per parent.
local function resolveName(part: BasePart, parent: Instance, fallback: string): string
	local trimmed = string.match(part.Name, "^%s*(.-)%s*$") or ""

	if trimmed == "" or trimmed == part.ClassName or GENERIC_PART_NAMES[trimmed] then
		return TerrainInstance.nextName(parent, fallback)
	end

	return part.Name
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
		local name = resolveName(part, parent, TerrainInstance.TILE_NAME)
		local opened = createTile(face.pivot, Vector3.zero, face.width, face.depth, power, part, parent, name, skipWedges)

		table.insert(created, opened)
		part.Parent = nil
		return opened.model
	end

	local area = Instance.new("Model")
	area.Name = resolveName(part, parent, TerrainInstance.AREA_NAME)
	-- Single-face areas inherit the face pivot; multi-face areas use the source part's pivot.
	area.WorldPivot = if single then job.faces[1].pivot else part.CFrame
	area.Parent = parent

	local built = 0

	for _, face in job.faces do
		local nx, nz = PartFaces.tileCounts(face, tileSize)
		local tileX, tileZ = face.width / nx, face.depth / nz

		for ix = 1, nx do
			for iz = 1, nz do
				local center = Vector3.new(-face.width / 2 + (ix - 0.5) * tileX, 0, -face.depth / 2 + (iz - 0.5) * tileZ)
				local name = if single then `Tile_{ix}_{iz}` else `{face.id}_{ix}_{iz}`

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

	Recording.run("Strata create terrain", function ()
		local settings = Settings.get()
		-- Newly created tiles are flat and bake directly from a single slab, so wedges can be
		-- skipped when auto-bake runs immediately.
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

			-- Build wedges for any tile whose bake failed so it is not left invisible.
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

function Create.fromSelection(power: number, tileSize: number, mode: PartFaces.Mode): Result
	local jobs, skippedFaces = selectionJobs(mode)
	local skippedObjects = #Selection:Get() - #Query.selectedParts()

	return run(jobs, skippedObjects, skippedFaces, power, tileSize)
end

function Create.fromPicks(power: number, tileSize: number, picks: { Pick }): Result
	local jobs, skippedFaces = pickJobs(picks)

	return run(jobs, 0, skippedFaces, power, tileSize)
end

return Create
