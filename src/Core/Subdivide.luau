--!strict
--[[
	Hammer's Subdivide: a Catmull-Clark style smoothing of the selected displacements' flat base
	quads, written into the per-vertex offsets and offset normals. The painted displacement
	(normal * distance) is kept and rides on top of the smoothed base.

	Following Hammer:
	- Each displacement adds one quad from its flat corners; the displaced surface is ignored.
	- Edges shared by two selected displacements are smooth; the rest are sharp, so the outline
	  of the selection never moves. A single displacement on its own stays flat.
	- Always 4 passes, whatever the powers; each displacement reads the level equal to its power.
	- The vertex rules are Hammer's variant (new edge points instead of neighbor vertices), and a
	  point keeps the normal it was created with.
	Interpretation: the face point used when a quad is split is its centroid at split time, after
	that pass moved the vertices.

	Normals here point out of the surface like Displacement.faceNormal, which uses the opposite
	cross product order to Hammer's because the corner winding is mirrored.
]]

local Displacement = require(script.Parent.Displacement)
local TerrainInstance = require(script.Parent.TerrainInstance)
local Units = require(script.Parent.Units)

type Opened = TerrainInstance.Opened

-- Hammer's tolerances, in Hammer units: corners sharing a normal, and merging mesh points.
local NORMAL_MATCH = Units.studs(0.01)
local POINT_MATCH = Units.studs(0.1)
local PASSES = 4

type Point = { pos: Vector3, nrm: Vector3 }

type Target = {
	opened: Opened,
	pivot: CFrame,
	corners: { Vector3 },
	normal: Vector3,
}

type Quad = {
	owner: Target,
	level: number,
	-- Point ids of corners 0 to 3.
	corners: { number },
	-- Grid (row, col) of each corner in the owner's grid.
	grid: { Vector2 },
	-- Edge k joins corners k and k + 1.
	edges: { Edge },
	split: boolean,
}

type Edge = {
	a: number,
	b: number,
	faces: { Quad },
	sharp: number,
	active: boolean,
	-- The new edge point of the current pass.
	pos: Vector3,
	nrm: Vector3,
}

type Mesh = {
	points: { Point },
	-- Spatial hash for merging points: cell key -> point ids.
	cells: { [string]: { number } },
	edges: { Edge },
	edgesByKey: { [string]: { Edge } },
	quads: { Quad },
}

local Subdivide = {}

local function normalize(v: Vector3): Vector3
	return v / math.sqrt(v:Dot(v) + 1e-10)
end

local function within(a: Vector3, b: Vector3, tolerance: number): boolean
	return math.abs(a.X - b.X) <= tolerance and math.abs(a.Y - b.Y) <= tolerance and math.abs(a.Z - b.Z) <= tolerance
end

local function cellOf(pos: Vector3): Vector3
	return Vector3.new(math.floor(pos.X / POINT_MATCH), math.floor(pos.Y / POINT_MATCH), math.floor(pos.Z / POINT_MATCH))
end

local function cellKey(x: number, y: number, z: number): string
	return `{x},{y},{z}`
end

-- Reuses a point within the merge tolerance (it keeps its own position and normal), or adds one.
local function addPoint(mesh: Mesh, pos: Vector3, nrm: Vector3): number
	local cell = cellOf(pos)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local ids: { number } = mesh.cells[cellKey(cell.X + dx, cell.Y + dy, cell.Z + dz)] or {}
				for _, id in ids do
					if within(mesh.points[id].pos, pos, POINT_MATCH) then
						return id
					end
				end
			end
		end
	end
	table.insert(mesh.points, { pos = pos, nrm = nrm })
	local id = #mesh.points
	local key = cellKey(cell.X, cell.Y, cell.Z)
	local list = mesh.cells[key]
	if list then
		table.insert(list, id)
	else
		mesh.cells[key] = { id }
	end
	return id
end

-- Finds the edge between two points with a free second face (which makes it smooth), or adds a
-- new sharp one.
local function addEdge(mesh: Mesh, a: number, b: number, quad: Quad): Edge
	local key = if a < b then `{a},{b}` else `{b},{a}`
	local list = mesh.edgesByKey[key]
	if list then
		for _, edge in list do
			if #edge.faces == 1 then
				table.insert(edge.faces, quad)
				edge.sharp = 0
				return edge
			end
		end
	else
		list = {}
		mesh.edgesByKey[key] = list
	end
	local edge: Edge = {
		a = a,
		b = b,
		faces = { quad },
		sharp = 1,
		active = true,
		pos = Vector3.zero,
		nrm = Vector3.zero,
	}
	table.insert(list, edge)
	table.insert(mesh.edges, edge)
	return edge
end

local function addQuad(mesh: Mesh, owner: Target, level: number, corners: { number }, grid: { Vector2 }): Quad
	local quad: Quad = { owner = owner, level = level, corners = corners, grid = grid, edges = {}, split = false }
	for k = 1, 4 do
		quad.edges[k] = addEdge(mesh, corners[k], corners[k % 4 + 1], quad)
	end
	table.insert(mesh.quads, quad)
	return quad
end

local function centroid(mesh: Mesh, quad: Quad): Vector3
	local p = mesh.points
	local c = quad.corners
	return (p[c[1]].pos + p[c[2]].pos + p[c[3]].pos + p[c[4]].pos) / 4
end

local function quadNormal(mesh: Mesh, quad: Quad): Vector3
	local p = mesh.points
	local c = quad.corners
	local c0 = p[c[1]].pos
	return normalize((p[c[2]].pos - c0):Cross(p[c[3]].pos - c0))
end

-- (a) New edge points: the midpoint on sharp edges, the average with both face centroids on
-- smooth ones.
local function computeEdgePoints(mesh: Mesh)
	for _, edge in mesh.edges do
		if not edge.active then
			continue
		end
		local a, b = mesh.points[edge.a], mesh.points[edge.b]
		if #edge.faces < 2 or edge.sharp == 1 then
			edge.sharp = 1
			edge.pos = (a.pos + b.pos) / 2
			edge.nrm = normalize(a.nrm + b.nrm)
		else
			local f0, f1 = edge.faces[1], edge.faces[2]
			edge.pos = (a.pos + b.pos + centroid(mesh, f0) + centroid(mesh, f1)) / 4
			edge.nrm = normalize(a.nrm + b.nrm + quadNormal(mesh, f0) + quadNormal(mesh, f1))
		end
	end
end

-- (b) and (c) New vertex positions, committed together. Normals never change.
local function moveVertices(mesh: Mesh)
	local incident: { [number]: { Edge } } = {}
	for _, edge in mesh.edges do
		if edge.active then
			for _, id in { edge.a, edge.b } do
				local list = incident[id]
				if not list then
					list = {}
					incident[id] = list
				end
				-- Hammer tracks at most 16 edges per point.
				if #list < 16 then
					table.insert(list, edge)
				end
			end
		end
	end

	local moved: { [number]: Vector3 } = {}
	for id, edges in incident do
		local valence = #edges
		local sharpCount = 0
		local hasInterior = false
		for _, edge in edges do
			if edge.sharp > 0 then
				sharpCount += 1
			end
			if #edge.faces == 2 then
				hasInterior = true
			end
		end
		if not hasInterior or sharpCount >= valence - 1 then
			continue -- Fixed.
		end
		local v = mesh.points[id].pos
		if sharpCount > 1 then
			-- Crease.
			local sum = Vector3.zero
			for _, edge in edges do
				if edge.sharp > 0 then
					sum += edge.pos
				end
			end
			moved[id] = (v * 6 + sum) / 8
		else
			-- Smooth.
			local sumE, sumF = Vector3.zero, Vector3.zero
			local seen: { [Quad]: true } = {}
			for _, edge in edges do
				sumE += edge.pos
				for _, quad in edge.faces do
					if not seen[quad] then
						seen[quad] = true
						sumF += centroid(mesh, quad)
					end
				end
			end
			local n = valence
			moved[id] = v * ((n - 2) / n) + (sumE + sumF) / (n * n)
		end
	end
	for id, pos in moved do
		mesh.points[id].pos = pos
	end
end

local function midGrid(a: Vector2, b: Vector2): Vector2
	return (a + b) / 2
end

-- (d) Splits every quad that existed at the start of the pass into 4.
local function splitQuads(mesh: Mesh)
	local leaves = {}
	for _, quad in mesh.quads do
		if not quad.split then
			table.insert(leaves, quad)
		end
	end
	for _, quad in leaves do
		quad.split = true
		local edgeIds = table.create(4)
		for k = 1, 4 do
			local edge = quad.edges[k]
			edgeIds[k] = addPoint(mesh, edge.pos, edge.nrm)
		end
		local center = addPoint(mesh, centroid(mesh, quad), quadNormal(mesh, quad))
		local g = quad.grid
		local centerGrid = midGrid(g[1], g[3])
		for k = 1, 4 do
			local prev = (k + 2) % 4 + 1
			local child = addQuad(mesh, quad.owner, quad.level + 1, {
				quad.corners[k],
				edgeIds[k],
				center,
				edgeIds[prev],
			}, {
				g[k],
				midGrid(g[k], g[k % 4 + 1]),
				centerGrid,
				midGrid(g[k], g[prev]),
			})
			-- Child edges along a parent edge keep its sharpness; inner ones are smooth.
			child.edges[1].sharp = quad.edges[k].sharp
			child.edges[2].sharp = 0
			child.edges[3].sharp = 0
			child.edges[4].sharp = quad.edges[prev].sharp
		end
		for k = 1, 4 do
			quad.edges[k].active = false
		end
	end
end

--[[
	Subdivides `targets` together and writes their offsets, offset normals and subdiv flag.
	Returns the changed vertices per displacement; every target's subdiv flag is set, so the
	caller should save all of them.
]]
function Subdivide.apply(targets: { Opened }): { [Opened]: { [number]: true } }
	local items: { Target } = {}
	for _, opened in targets do
		local pivot = opened.model:GetPivot()
		local corners = table.create(4)
		for k = 1, 4 do
			corners[k] = pivot * opened.disp.corners[k]
		end
		table.insert(items, {
			opened = opened,
			pivot = pivot,
			corners = corners,
			normal = pivot:VectorToWorldSpace(Displacement.faceNormal(opened.disp)),
		})
	end

	local mesh: Mesh = { points = {}, cells = {}, edges = {}, edgesByKey = {}, quads = {} }
	for _, item in items do
		local ids = table.create(4)
		for k = 1, 4 do
			-- Corner normal: this face's normal plus every other selected face sharing the corner.
			local normal = item.normal
			for _, other in items do
				if other ~= item then
					for _, corner in other.corners do
						if within(corner, item.corners[k], NORMAL_MATCH) then
							normal += other.normal
						end
					end
				end
			end
			ids[k] = addPoint(mesh, item.corners[k], normalize(normal))
		end
		local n = item.opened.disp.size - 1
		addQuad(mesh, item, 0, ids, {
			Vector2.new(0, 0),
			Vector2.new(n, 0),
			Vector2.new(n, n),
			Vector2.new(0, n),
		})
	end

	for _ = 1, PASSES do
		computeEdgePoints(mesh)
		moveVertices(mesh)
		splitQuads(mesh)
	end

	-- Write back the level matching each displacement's power.
	local result: { [Opened]: { [number]: true } } = {}
	for _, item in items do
		item.opened.disp.subdiv = true
	end
	for _, quad in mesh.quads do
		local item = quad.owner
		local disp = item.opened.disp
		if quad.level ~= disp.power then
			continue
		end
		for k = 1, 4 do
			local point = mesh.points[quad.corners[k]]
			local grid = quad.grid[k]
			local index = grid.X * disp.size + grid.Y + 1
			local flat = item.pivot * Displacement.flatPosition(disp, index)
			local offset = item.pivot:VectorToObjectSpace(point.pos - flat)
			local offsetNormal = item.pivot:VectorToObjectSpace(point.nrm)
			local normal, distance = Displacement.normalizeWithLength(Displacement.fieldVector(disp, index))
			local changed = (disp.offsets[index] - offset).Magnitude > 1e-6
				or (disp.offsetNormals[index] - offsetNormal).Magnitude > 1e-6
				or (disp.normals[index] - normal).Magnitude > 1e-6
				or math.abs(disp.distances[index] - distance) > 1e-6
			if changed then
				disp.offsets[index] = offset
				disp.offsetNormals[index] = offsetNormal
				disp.normals[index] = normal
				disp.distances[index] = distance
				local set = result[item.opened]
				if not set then
					set = {}
					result[item.opened] = set
				end
				set[index] = true
			end
		end
	end
	return result
end

return Subdivide
