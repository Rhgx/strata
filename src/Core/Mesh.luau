--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Delaunay triangulation of kept displacement vertices when grid points are removed (Simplify
	mode), computed in the flat 2D grid plane.

	Because the 4 corners cannot be removed, the triangulation always spans the entire square
	without gaps regardless of the removed region's shape. On cocircular ties (such as the 4
	corners of an intact grid cell), the diagonal connecting the two even vertices
	((row + col) % 2 == 0) is chosen, matching Hammer's checkerboard so untouched cells keep
	their original triangles.

	Circumcircle tests scale grid indices by the tile's cell dimensions so elongated tiles produce
	well-shaped triangles in studs rather than grid units. Orientation tests use exact integer
	grid coordinates.

	Because the triangulation depends only on which vertices are removed (not their heights), a
	tile builds its mesh once and reuses it across sculpting edits.
]]

local Mesh = {}

export type Mesh = {
	-- Shown triangles as vertex index triples, wound counter-clockwise in (row, col).
	triangles: { { number } },
	-- Shown triangle indices incident to each vertex.
	vertexTriangles: { [number]: { number } },
	-- Per shown triangle: grid triangles whose centroids lie inside it.
	cover: { { number } },
	-- Per grid triangle: the shown triangle covering its centroid.
	shownOf: { number },
	-- Per removed vertex: containing shown triangle and barycentric weights for surface reprojection.
	removedOn: { [number]: { triangle: number, w1: number, w2: number, w3: number } },
}

type Point = { row: number, col: number, x: number, y: number, even: boolean }

-- Relative threshold below which four points count as cocircular.
local TIE_TOLERANCE = 1e-9
local MAX_FLIP_PASSES = 64

-- Twice the signed area of triangle abc in integer grid units (positive when counter-clockwise).
local function orient(a: Point, b: Point, c: Point): number
	return (b.row - a.row) * (c.col - a.col) - (b.col - a.col) * (c.row - a.row)
end

-- Positive when d lies strictly inside the circumcircle of counter-clockwise triangle abc.
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

-- Builds the Delaunay mesh for a (size x size) grid with `removed` vertices, where `rowStep` and
-- `colStep` are the cell lengths in studs along rows and columns.
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

	-- Active triangles as counter-clockwise { a, b, c } vertex triples; replaced indices go in `dead`.
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

	-- Bowyer-Watson insertion of kept vertices in deterministic index order.
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

		-- Expand the cavity until every boundary edge faces `p` positively (cocircular ties can
		-- otherwise leave the cavity non-star-shaped).
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
						-- Pull the adjacent triangle across this inverted boundary edge into the cavity.
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

					-- Skip collinear border edges containing `p` to avoid zero-area sliver triangles.
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

	-- Break cocircular ties toward Hammer's checkerboard diagonal (connecting two even vertices).
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
			-- Shared edge (a, b) and opposite vertices c (in t1) and d (in t2).
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

			-- Require a strictly convex quad before flipping.
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

	-- Bucket shown triangles by overlapping grid cells for fast point-in-triangle lookups.
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

	-- Locates the shown triangle containing a point scaled by 3 in grid units (exact for centroids).
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
		-- Two grid triangles of the cell, ordered identically to Displacement.gridTriangle.
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
