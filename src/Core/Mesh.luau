--!strict
--[[
	The triangles a displacement shows once some of its grid points are removed (the Mesh tool's
	Simplify mode): a Delaunay triangulation of the kept points, worked out on the flat grid.

	The 4 corners can never be removed, so the kept points always span the whole square and the
	triangles cover the tile exactly, whatever shape the removed area has. Where Delaunay has a
	free choice (the 4 corners of an untouched grid cell lie on one circle), the diagonal joining
	the two "even" points ((row + col) % 2 == 0) wins: that is the diagonal of Hammer's
	checkerboard, so cells away from removed points keep exactly the triangles they had.

	The geometry runs on grid units scaled by the tile's cell size along each side, so a long thin
	tile gets triangles that are well shaped in studs, not in grid units. Side tests use the
	integer grid units, which are exact.

	Everything here depends only on which points are removed, never on heights, so a tile builds
	its mesh once and keeps it while it is sculpted.
]]

local Mesh = {}

export type Mesh = {
	-- Shown triangles as vertex index triples, counter-clockwise in (row, col).
	triangles: { { number } },
	-- The shown triangles using each vertex.
	vertexTriangles: { [number]: { number } },
	-- Per shown triangle: the grid triangles whose centers lie inside it.
	cover: { { number } },
	-- Per grid triangle: the shown triangle covering its center.
	shownOf: { number },
	-- Per removed vertex: the shown triangle it lies on and its weights on that triangle's
	-- vertices, so it can be kept on the surface.
	removedOn: { [number]: { triangle: number, w1: number, w2: number, w3: number } },
}

type Point = { row: number, col: number, x: number, y: number, even: boolean }

-- Cells this many grid units (scaled) or more across count as cocircular below this, relative to
-- the size of the numbers involved.
local TIE_TOLERANCE = 1e-9
local MAX_FLIP_PASSES = 64

-- Twice the signed area of abc in grid units: positive when counter-clockwise. Exact.
local function orient(a: Point, b: Point, c: Point): number
	return (b.row - a.row) * (c.col - a.col) - (b.col - a.col) * (c.row - a.row)
end

-- Positive when d lies inside the circle through the counter-clockwise triangle abc.
local function inCircle(a: Point, b: Point, c: Point, d: Point): number
	local adx, ady = a.x - d.x, a.y - d.y
	local bdx, bdy = b.x - d.x, b.y - d.y
	local cdx, cdy = c.x - d.x, c.y - d.y
	local ad = adx * adx + ady * ady
	local bd = bdx * bdx + bdy * bdy
	local cd = cdx * cdx + cdy * cdy
	return adx * (bdy * cd - bd * cdy) - ady * (bdx * cd - bd * cdx) + ad * (bdx * cdy - bdy * cdx)
end

local function edgeKey(a: number, b: number): number
	return if a < b then a * 65536 + b else b * 65536 + a
end

--[[
	Builds the mesh for a (size x size) grid with `removed` vertices. `rowStep` and `colStep` are
	the cell sizes in studs along the rows and columns.
]]
function Mesh.build(size: number, removed: { [number]: true }, rowStep: number, colStep: number): Mesh
	local unit = math.max(math.min(rowStep, colStep), 1e-6)
	local sx, sy = rowStep / unit, colStep / unit
	local points: { [number]: Point } = {}
	local function point(v: number): Point
		local existing = points[v]
		if existing then
			return existing
		end
		local row, col = (v - 1) // size, (v - 1) % size
		local created = { row = row, col = col, x = row * sx, y = col * sy, even = (row + col) % 2 == 0 }
		points[v] = created
		return created
	end
	local n = size - 1
	local largest = math.max(n * sx, n * sy)
	local tolerance = TIE_TOLERANCE * largest * largest * largest * largest

	-- Triangles as { a, b, c } vertex indices, counter-clockwise. Replaced ones go in dead.
	local triangles: { { number } } = {}
	local dead: { [number]: true } = {}
	local function add(a: number, b: number, c: number)
		if orient(point(a), point(b), point(c)) < 0 then
			b, c = c, b
		end
		table.insert(triangles, { a, b, c })
	end

	local v00, vn0, vnn, v0n = 1, n * size + 1, n * size + n + 1, n + 1
	add(v00, vn0, vnn)
	add(v00, vnn, v0n)

	-- Bowyer-Watson insertion of every kept point, in index order so the result never changes.
	for v = 1, size * size do
		if removed[v] or v == v00 or v == vn0 or v == vnn or v == v0n then
			continue
		end
		local p = point(v)
		local bad: { [number]: true } = {}
		for t, tri in triangles do
			if not dead[t] then
				local a, b, c = point(tri[1]), point(tri[2]), point(tri[3])
				local contains = orient(a, b, p) >= 0 and orient(b, c, p) >= 0 and orient(c, a, p) >= 0
				if contains or inCircle(a, b, c, p) > tolerance then
					bad[t] = true
				end
			end
		end
		-- Grow the cavity until every new triangle faces the right way (ties can leave it short).
		while true do
			local count: { [number]: number } = {}
			for t in bad do
				local tri = triangles[t]
				for k = 1, 3 do
					local key = edgeKey(tri[k], tri[k % 3 + 1])
					count[key] = (count[key] or 0) + 1
				end
			end
			local grow: number? = nil
			for t in bad do
				local tri = triangles[t]
				for k = 1, 3 do
					local a, b = tri[k], tri[k % 3 + 1]
					if count[edgeKey(a, b)] == 1 and orient(point(a), point(b), p) < 0 then
						-- The triangle across this edge must join the cavity.
						for other, otherTri in triangles do
							if not dead[other] and not bad[other] then
								for m = 1, 3 do
									if edgeKey(otherTri[m], otherTri[m % 3 + 1]) == edgeKey(a, b) then
										grow = other
									end
								end
							end
						end
					end
				end
			end
			if grow then
				bad[grow] = true
				continue
			end
			local edges: { { number } } = {}
			for t in bad do
				local tri = triangles[t]
				for k = 1, 3 do
					local a, b = tri[k], tri[k % 3 + 1]
					-- Edges with p on them (the tile border) get no sliver triangle.
					if count[edgeKey(a, b)] == 1 and orient(point(a), point(b), p) > 0 then
						table.insert(edges, { a, b })
					end
				end
				dead[t] = true
			end
			for _, edge in edges do
				add(edge[1], edge[2], v)
			end
			break
		end
	end

	local list: { { number } } = {}
	for t, tri in triangles do
		if not dead[t] then
			table.insert(list, tri)
		end
	end

	-- Ties go to the checkerboard diagonal: flip edges of cocircular cells whose other diagonal
	-- joins two even points.
	for _ = 1, MAX_FLIP_PASSES do
		local byEdge: { [number]: { number } } = {}
		for t, tri in list do
			for k = 1, 3 do
				local key = edgeKey(tri[k], tri[k % 3 + 1])
				local entry = byEdge[key]
				if entry then
					table.insert(entry, t)
				else
					byEdge[key] = { t }
				end
			end
		end
		local flipped = false
		local touched: { [number]: true } = {}
		for _, pair in byEdge do
			if #pair ~= 2 or touched[pair[1]] or touched[pair[2]] then
				continue
			end
			local t1, t2 = list[pair[1]], list[pair[2]]
			-- The shared edge (a, b) and the far corners c (of t1) and d (of t2).
			local a, b, c, d
			for k = 1, 3 do
				local x, y = t1[k], t1[k % 3 + 1]
				for m = 1, 3 do
					if t2[m] == y and t2[m % 3 + 1] == x then
						a, b, c = x, y, t1[(k + 1) % 3 + 1]
						d = t2[(m + 1) % 3 + 1]
					end
				end
			end
			if not (a and b and c and d) then
				continue
			end
			local pa, pb, pc, pd = point(a), point(b), point(c), point(d)
			-- Flipping needs a convex cell: c and d on opposite sides of each diagonal.
			if orient(pc, pd, pa) * orient(pc, pd, pb) >= 0 then
				continue
			end
			local test = inCircle(pa, pb, pc, pd)
			local tie = math.abs(test) <= tolerance
			if test > tolerance or (tie and not (pa.even and pb.even) and pc.even and pd.even) then
				list[pair[1]] = { c, a, d }
				list[pair[2]] = { d, b, c }
				for _, t in pair do
					local tri = list[t]
					if orient(point(tri[1]), point(tri[2]), point(tri[3])) < 0 then
						tri[2], tri[3] = tri[3], tri[2]
					end
					touched[t] = true
				end
				flipped = true
			end
		end
		if not flipped then
			break
		end
	end

	local vertexTriangles: { [number]: { number } } = {}
	for t, tri in list do
		for _, v in tri do
			local entry = vertexTriangles[v]
			if entry then
				table.insert(entry, t)
			else
				vertexTriangles[v] = { t }
			end
		end
	end

	-- Shown triangles by grid cell, to look up points quickly.
	local buckets: { [number]: { number } } = {}
	for t, tri in list do
		local a, b, c = point(tri[1]), point(tri[2]), point(tri[3])
		local r0 = math.min(a.row, b.row, c.row)
		local r1 = math.max(a.row, b.row, c.row)
		local c0 = math.min(a.col, b.col, c.col)
		local c1 = math.max(a.col, b.col, c.col)
		for r = r0, math.max(r0, r1 - 1) do
			for cc = c0, math.max(c0, c1 - 1) do
				local key = r * n + cc
				local entry = buckets[key]
				if entry then
					table.insert(entry, t)
				else
					buckets[key] = { t }
				end
			end
		end
	end
	-- The shown triangle containing a point given as grid units times 3 (exact for centers).
	local function locate(row3: number, col3: number): number?
		local p = { row = row3, col = col3, x = 0, y = 0, even = false }
		local r = math.clamp(row3 // 3, 0, n - 1)
		local cc = math.clamp(col3 // 3, 0, n - 1)
		for dr = 0, -1, -1 do
			for dc = 0, -1, -1 do
				local key = math.clamp(r + dr, 0, n - 1) * n + math.clamp(cc + dc, 0, n - 1)
				local bucket = buckets[key]
				if not bucket then
					continue
				end
				for _, t in bucket do
					local tri = list[t]
					local a, b, c = point(tri[1]), point(tri[2]), point(tri[3])
					local a3 = { row = a.row * 3, col = a.col * 3, x = 0, y = 0, even = false }
					local b3 = { row = b.row * 3, col = b.col * 3, x = 0, y = 0, even = false }
					local c3 = { row = c.row * 3, col = c.col * 3, x = 0, y = 0, even = false }
					if orient(a3, b3, p) >= 0 and orient(b3, c3, p) >= 0 and orient(c3, a3, p) >= 0 then
						return t
					end
				end
			end
		end
		return nil
	end

	local cover: { { number } } = table.create(#list)
	for t = 1, #list do
		cover[t] = {}
	end
	local shownOf: { number } = {}
	local quads = n * n
	for q = 0, quads - 1 do
		local row, col = q // n, q % n
		local v00g = row * size + col + 1
		local corners = { v00g, v00g + 1, v00g + size, v00g + size + 1 }
		local isEven = (row + col) % 2 == 0
		-- The two grid triangles of the cell, as Displacement.gridTriangle orders them.
		local halves: { { number } } = if isEven
			then { { corners[1], corners[3], corners[4] }, { corners[1], corners[4], corners[2] } }
			else { { corners[1], corners[3], corners[2] }, { corners[2], corners[3], corners[4] } }
		for k, tri in halves do
			local g = q * 2 + k
			local r3, c3 = 0, 0
			for _, v in tri do
				r3 += (v - 1) // size
				c3 += (v - 1) % size
			end
			local t = locate(r3, c3) or 1
			shownOf[g] = t
			table.insert(cover[t], g)
		end
	end

	local removedOn = {}
	for v in removed do
		local p = point(v)
		local t = locate(p.row * 3, p.col * 3)
		if t then
			local tri = list[t]
			local a, b, c = point(tri[1]), point(tri[2]), point(tri[3])
			local area = orient(a, b, c)
			local w1 = orient(b, c, p) / area
			local w2 = orient(c, a, p) / area
			removedOn[v] = { triangle = t, w1 = w1, w2 = w2, w3 = 1 - w1 - w2 }
		end
	end

	return {
		triangles = list,
		vertexTriangles = vertexTriangles,
		cover = cover,
		shownOf = shownOf,
		removedOn = removedOn,
	}
end

return Mesh
