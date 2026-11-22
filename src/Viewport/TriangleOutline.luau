--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Draws the outer boundary of shown triangles covered by triangle-based brushes (Material and
	Mesh Cut holes). Outlining only perimeter edges accurately previews stepped cell footprints
	where a circular ring would mislead.
]]

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Core = Plugin.Core

local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Lines = require(Viewport.Lines)

type Opened = TerrainInstance.Opened

export type Covered = { opened: Opened, grids: { number } }

local THICKNESS = 0.09
local TRANSPARENCY = 0.1

local TriangleOutline = {}

-- Clears `pool` and draws the perimeter edges of the shown triangles backing `covered`.
function TriangleOutline.draw(pool: Lines.Pool, covered: { Covered }, color: Color3)
	pool.clear()

	for _, entry in covered do
		local opened = entry.opened
		local disp = opened.disp
		local shown: { [number]: true } = {}

		for _, g in entry.grids do
			shown[Displacement.shownOf(disp, g)] = true
		end

		-- Edges referenced by only one covered triangle lie on the outer perimeter.
		local count = Displacement.vertexCount(disp)
		local uses: { [number]: number } = {}
		local ends: { [number]: { number } } = {}

		for t in shown do
			local i1, i2, i3 = Displacement.triangle(disp, t)

			for _, pair in { { i1, i2 }, { i2, i3 }, { i3, i1 } } do
				local lo, hi = math.min(pair[1], pair[2]), math.max(pair[1], pair[2])
				local key = lo * (count + 1) + hi
				uses[key] = (uses[key] or 0) + 1
				ends[key] = { lo, hi }
			end
		end

		local pivot = opened.model:GetPivot()
		local normal = Displacement.faceNormal(disp)
		-- Offset slightly along the tile normal so lines sit cleanly above the wedges.
		local lift = pivot:VectorToWorldSpace(normal) * 0.03

		for key, used in uses do
			if used == 1 then
				local pair = ends[key]
				pool.line(
					pivot * Displacement.position(disp, pair[1], normal) + lift,
					pivot * Displacement.position(disp, pair[2], normal) + lift,
					color,
					THICKNESS,
					TRANSPARENCY
				)
			end
		end
	end
end

return TriangleOutline
