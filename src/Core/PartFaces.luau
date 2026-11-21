--!strict
--[[
	The four-sided faces of a part that can become displacements, like the quad faces of a
	Hammer brush. Block Parts have 6. Wedges (a WedgePart, or a Part with the Wedge shape) have
	3: bottom, back and slope; their triangular sides are skipped, as Hammer skips non-quad faces.
	Other shapes have none.

	Each face comes with a pivot whose +Y is the outward normal and whose X and Z run along the
	face's edges, so a displacement built on it uses the same flat corner layout as the top face.
	Faces are named in part-local terms; "which face is on top" is decided in world space (see
	`select`), because builders rotate parts and Studio does not show local axes.
]]

export type FaceId = "Top" | "Bottom" | "Left" | "Right" | "Front" | "Back" | "Slope"
export type Mode = "Top" | "TopSides" | "All"

export type Face = {
	id: FaceId,
	-- World pivot: +Y is the outward normal, X and Z run along the edges.
	pivot: CFrame,
	-- Size along the pivot's X and Z.
	width: number,
	depth: number,
}

local PartFaces = {}

-- Faces thinner than this are skipped: wedges are 0.2 studs thick, and unions of slivers fail.
PartFaces.MIN_FACE_SIZE = 0.5
-- Faces thinner than this still work but waste parts, so the Create page warns about them.
PartFaces.THIN_FACE_SIZE = 4

function PartFaces.isWedge(inst: Instance): boolean
	return inst:IsA("WedgePart") or (inst:IsA("Part") and inst.Shape == Enum.PartType.Wedge)
end

function PartFaces.isEligible(inst: Instance): boolean
	return (inst:IsA("Part") and inst.Shape == Enum.PartType.Block) or PartFaces.isWedge(inst)
end

-- Every quad face of the part, or none for other shapes.
function PartFaces.faces(part: BasePart): { Face }
	local cf, size = part.CFrame, part.Size
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local faces: { Face } = {}
	local function add(id: FaceId, center: Vector3, xAxis: Vector3, normal: Vector3, width: number, depth: number)
		local x = cf:VectorToWorldSpace(xAxis)
		local y = cf:VectorToWorldSpace(normal)
		-- fromMatrix derives Z = X x Y, which lies along the face's other edge.
		table.insert(faces, {
			id = id,
			pivot = CFrame.fromMatrix(cf * center, x, y),
			width = width,
			depth = depth,
		})
	end

	if PartFaces.isWedge(part) then
		-- Roblox wedges are full at the back (+Z) and slope up from the bottom front edge.
		add("Bottom", Vector3.new(0, -hy, 0), Vector3.xAxis, -Vector3.yAxis, size.X, size.Z)
		add("Back", Vector3.new(0, 0, hz), Vector3.xAxis, Vector3.zAxis, size.X, size.Y)
		local slopeNormal = Vector3.new(0, size.Z, -size.Y).Unit
		add("Slope", Vector3.zero, Vector3.xAxis, slopeNormal, size.X, math.sqrt(size.Y ^ 2 + size.Z ^ 2))
	elseif PartFaces.isEligible(part) then
		add("Top", Vector3.new(0, hy, 0), Vector3.xAxis, Vector3.yAxis, size.X, size.Z)
		add("Bottom", Vector3.new(0, -hy, 0), Vector3.xAxis, -Vector3.yAxis, size.X, size.Z)
		add("Right", Vector3.new(hx, 0, 0), Vector3.zAxis, Vector3.xAxis, size.Z, size.Y)
		add("Left", Vector3.new(-hx, 0, 0), Vector3.zAxis, -Vector3.xAxis, size.Z, size.Y)
		add("Back", Vector3.new(0, 0, hz), Vector3.xAxis, Vector3.zAxis, size.X, size.Y)
		add("Front", Vector3.new(0, 0, -hz), Vector3.xAxis, -Vector3.zAxis, size.X, size.Y)
	end
	return faces
end

function PartFaces.find(part: BasePart, id: FaceId): Face?
	for _, face in PartFaces.faces(part) do
		if face.id == id then
			return face
		end
	end
	return nil
end

-- The face whose outward normal matches a world normal (for example a raycast hit), if any.
function PartFaces.faceAt(part: BasePart, worldNormal: Vector3): Face?
	local best: Face? = nil
	local bestDot = 0.95
	for _, face in PartFaces.faces(part) do
		local dot = face.pivot.UpVector:Dot(worldNormal)
		if dot > bestDot then
			best, bestDot = face, dot
		end
	end
	return best
end

-- The faces a Create mode converts, chosen by world orientation: Top is the face pointing most
-- upward, Top + sides is everything except the face pointing most downward.
function PartFaces.select(part: BasePart, mode: Mode): { Face }
	local faces = PartFaces.faces(part)
	if mode == "All" or #faces == 0 then
		return faces
	end
	local top, bottom = faces[1], faces[1]
	for _, face in faces do
		if face.pivot.UpVector.Y > top.pivot.UpVector.Y then
			top = face
		end
		if face.pivot.UpVector.Y < bottom.pivot.UpVector.Y then
			bottom = face
		end
	end
	if mode == "Top" then
		return { top }
	end
	local result = {}
	for _, face in faces do
		if face ~= bottom then
			table.insert(result, face)
		end
	end
	return result
end

-- Tiles along the face's X and Z. Faces sharing an edge use the same part dimension for it, so
-- their tile counts match and the tiles line up across the edge.
function PartFaces.tileCounts(face: Face, tileSize: number): (number, number)
	return math.max(1, math.round(face.width / tileSize)), math.max(1, math.round(face.depth / tileSize))
end

return PartFaces
