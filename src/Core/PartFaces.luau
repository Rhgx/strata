--!strict
--[[
	Extracts convertible quad faces from Roblox parts, matching Hammer's quad brush faces. Block
	Parts provide 6 faces and wedges (WedgePart or Part with Wedge shape) provide 3 (bottom, back,
	and slope; triangular sides are skipped, as in Hammer). Other shapes return no faces.

	Each face exposes a world pivot with +Y along its outward normal and X/Z along its edges so
	every displacement uses the same flat corner layout as a top face. Face IDs are part-local,
	while "Top" and "TopSides" selection operates in world space (see `select`) because builders
	rotate parts freely and Studio does not display local axes.
]]

export type FaceId = "Top" | "Bottom" | "Left" | "Right" | "Front" | "Back" | "Slope"
export type Mode = "Top" | "TopSides" | "All"

export type Face = {
	id: FaceId,
	-- World pivot: +Y is outward normal, X and Z align with face edges.
	pivot: CFrame,
	-- Dimensions along pivot X and Z.
	width: number,
	depth: number,
}

local PartFaces = {}

-- Faces narrower than this are skipped because wedges are 0.2 studs thick and sliver unions fail.
PartFaces.MIN_FACE_SIZE = 0.5
-- Faces narrower than this convert cleanly but waste parts, triggering a warning on the Create page.
PartFaces.THIN_FACE_SIZE = 4

function PartFaces.isWedge(inst: Instance): boolean
	return inst:IsA("WedgePart") or (inst:IsA("Part") and inst.Shape == Enum.PartType.Wedge)
end

function PartFaces.isEligible(inst: Instance): boolean
	return (inst:IsA("Part") and inst.Shape == Enum.PartType.Block) or PartFaces.isWedge(inst)
end

-- Returns all quad faces of `part`, or an empty list for unsupported shapes.
function PartFaces.faces(part: BasePart): { Face }
	local cf, size = part.CFrame, part.Size
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local faces: { Face } = {}

	local function add(id: FaceId, center: Vector3, xAxis: Vector3, normal: Vector3, width: number, depth: number)
		local x = cf:VectorToWorldSpace(xAxis)
		local y = cf:VectorToWorldSpace(normal)

		-- CFrame.fromMatrix computes Z = X x Y along the face's remaining edge.
		table.insert(faces, {
			id = id,
			pivot = CFrame.fromMatrix(cf * center, x, y),
			width = width,
			depth = depth,
		})
	end

	if PartFaces.isWedge(part) then
		-- Roblox wedges have their vertical back at +Z and slope up from the bottom front edge.
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

-- Finds the quad face whose outward normal aligns with `worldNormal` (e.g. from a raycast hit).
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

-- Selects faces according to world orientation: Top picks the most upward-facing face; TopSides
-- picks every face except the most downward-facing one.
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

-- Computes tile counts along a face's X and Z edges. Adjacent faces on the same part share the
-- same edge dimension, so their counts match and generated tiles align across corners.
function PartFaces.tileCounts(face: Face, tileSize: number): (number, number)
	return math.max(1, math.round(face.width / tileSize)), math.max(1, math.round(face.depth / tileSize))
end

return PartFaces
