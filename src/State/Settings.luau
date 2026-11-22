--!strict
--[[
	Shared tool settings. The UI, ribbon buttons, keyboard shortcuts, and plugin actions write
	to this store while viewport tools read it every frame. Kept outside React so painting never
	waits on a re-render.
]]

local Plugin = script.Parent.Parent
local Core = Plugin.Core

local Paint = require(Core.Paint)
local PartFaces = require(Core.PartFaces)

export type BrushMode = Paint.Effect
export type FaceMode = PartFaces.Mode
export type Falloff = Paint.Falloff
export type Axis = Paint.Axis

-- Viewport tools in ribbon and tool strip order.
export type Tool = "Raise" | "Lower" | "Smooth" | "RaiseTo" | "Material" | "Mesh" | "PickFaces" | "Stitch"

-- Mesh tool modes: Simplify removes grid points (filling the area with fewer, larger triangles);
-- Holes deletes triangles outright.
export type MeshMode = "Simplify" | "Holes"

-- Full-panel overlay pages shown above the current context.
export type Overlay = "none" | "settings" | "help"

-- A look recently painted or picked with the Material tool.
export type RecentLook = {
	material: Enum.Material,
	color: Color3,
	variant: string,
}

export type State = {
	-- Viewport tools share the mouse, so at most one of painting, coloring, meshing, picking,
	-- stitching, or sampling is active at a time.
	painting: boolean,
	-- Material tool: paints looks onto tiles.
	coloring: boolean,
	-- Material tool: the next click samples a look instead of painting (panel pipette).
	pickingLook: boolean,
	-- Active look painted by the Material tool.
	paintMaterial: Enum.Material,
	paintColor: Color3,
	paintVariant: string,
	-- Recently painted or picked looks, newest first (up to RECENT_LOOKS), for quick switching.
	recentLooks: { RecentLook },
	-- Material tool: paint individual triangles instead of whole grid cells.
	paintFine: boolean,
	-- Material tool: erase painted looks back to each tile's base look (Ctrl swaps paint and erase).
	paintErase: boolean,
	-- Mesh tool: removes points or cuts holes.
	meshing: boolean,
	meshMode: MeshMode,
	-- Auto-simplify: maximum surface bend in degrees allowed when removing points.
	simplifyAngle: number,
	-- Pick faces tool.
	picking: boolean,
	-- Stitch to part tool.
	stitching: boolean,
	-- Copy appearance mode: the next click on a part copies its look onto selected tiles.
	sampling: boolean,
	-- Edit points: handles on the chosen tiles' points, moved with Studio's own Select, Move,
	-- Rotate, and Scale tools. It never takes the mouse, but it still excludes every viewport
	-- tool, since those would edit the same tiles underneath the handles.
	editingPoints: boolean,
	-- Session-only overlay (Settings or Help) covering the panel.
	overlay: Overlay,
	-- Maximum distance in studs a tile edge may move to snap onto a part edge when stitching.
	stitchReach: number,
	-- Which faces of selected parts Create converts into displacements.
	faces: FaceMode,
	mode: BrushMode,
	radius: number,
	strength: number,
	-- Raise To target distance in studs along the active axis from the flat base face.
	height: number,
	-- Raise To: interpret `height` as a world coordinate along the axis instead of an offset from each tile's base.
	raiseToWorld: boolean,
	-- Raise To: the Height of the other From mode, swapped in when From changes, so a world height
	-- (often far from 0) never carries over to Tile base and the reverse.
	otherHeight: number,
	falloff: Falloff,
	axis: Axis,
	-- World-space unit axis for "Picked" mode, set with Alt + Right Click.
	pickedAxis: Vector3,
	-- Restrict painting to selected displacements (Hammer's behavior); otherwise paint all tiles.
	paintSelectedOnly: boolean,
	-- Noise amplitude range in studs.
	noiseMin: number,
	noiseMax: number,
	power: number,
	-- Target tile size in studs when subdividing an area; smaller parts become a single displacement.
	tileSize: number,
	-- Automatically sew edited displacements to neighbors after every stroke or power change.
	autosew: boolean,
	-- Re-snap tile edges that touched a part edge before an edit back onto that edge afterwards
	-- (independent of autosew).
	stitchParts: boolean,
	-- Bake edited displacements into unions when a viewport tool stops and after edit actions.
	autoBake: boolean,
	-- UnionOperation.SmoothingAngle for baked surfaces (0 = flat shaded).
	smoothingAngle: number,
	-- Baking omits points on ground flatter than this angle in degrees (0 = off) for lighter unions.
	bakeSimplifyAngle: number,
	-- Baking ignores bumps smaller than this height in studs (0 = off) when simplifying.
	bakeHeightTolerance: number,
	-- Baking drops tile edge points that lie on a straight line without creating cracks.
	bakeSimplifyEdges: boolean,
	-- Bake flat, single-look tiles to a plain Part instead of a union.
	bakeFlatPart: boolean,
	-- Disable shadows on flat baked tiles.
	bakeFlatNoShadow: boolean,
	-- Display the key strip at the bottom of the viewport while a tool is active.
	showKeyHints: boolean,
	-- Display point dots inside the sculpt brush cursor (Raise, Lower, Smooth, Raise To).
	showBrushDots: boolean,
	-- Mirror tool buttons on Studio's Plugins ribbon tab (they always appear in the panel strip).
	ribbonTools: boolean,
}

type Listener = (State) -> ()

local Settings = {}

Settings.RADIUS_MIN = 1
Settings.RADIUS_MAX = 64
Settings.STRENGTH_MIN = 0.5
Settings.STRENGTH_MAX = 32
Settings.TILE_SIZE_MIN = 4
Settings.TILE_SIZE_MAX = 512
Settings.SMOOTHING_MIN = 0
Settings.SMOOTHING_MAX = 180
-- Wide enough for world-space heights (Raise To from World).
Settings.HEIGHT_MIN = -10000
Settings.HEIGHT_MAX = 10000
Settings.NOISE_MIN = -64
Settings.NOISE_MAX = 64
Settings.STITCH_REACH_MIN = 0.5
Settings.STITCH_REACH_MAX = 16
Settings.SIMPLIFY_ANGLE_MIN = 0
Settings.SIMPLIFY_ANGLE_MAX = 45
Settings.BAKE_SIMPLIFY_MIN = 0
Settings.BAKE_SIMPLIFY_MAX = 10
Settings.BAKE_TOLERANCE_MIN = 0
Settings.BAKE_TOLERANCE_MAX = 0.5
Settings.RECENT_LOOKS = 6

local MODES: { BrushMode } = { "Raise", "Lower", "Smooth", "RaiseTo" }
local MODE_LABELS: { [BrushMode]: string } = {
	Raise = "Raise",
	Lower = "Lower",
	Smooth = "Smooth",
	RaiseTo = "Raise To",
}

local TOOLS: { Tool } = { "Raise", "Lower", "Smooth", "RaiseTo", "Material", "Mesh", "PickFaces", "Stitch" }
local TOOL_LABELS: { [Tool]: string } = {
	Raise = "Raise",
	Lower = "Lower",
	Smooth = "Smooth",
	RaiseTo = "Raise To",
	Material = "Material",
	Mesh = "Mesh",
	PickFaces = "Pick faces",
	Stitch = "Stitch",
}

local AXES: { Axis } = { "Face", "Up", "X", "Z", "Picked", "Subdiv" }
local AXIS_LABELS: { [Axis]: string } = {
	Face = "Face normal",
	Up = "Up (Y)",
	X = "X",
	Z = "Z",
	Picked = "Picked",
	Subdiv = "Curved (Round)",
}

-- Accessors for ordered choices and display names. Functions preserve exact union types across
-- modules where table fields would widen them to string.
function Settings.modes(): { BrushMode }
	return MODES
end

function Settings.modeLabel(mode: BrushMode): string
	return MODE_LABELS[mode]
end

function Settings.tools(): { Tool }
	return TOOLS
end

function Settings.toolLabel(tool: Tool): string
	return TOOL_LABELS[tool]
end

function Settings.axes(): { Axis }
	return AXES
end

function Settings.axisLabel(axis: Axis): string
	return AXIS_LABELS[axis]
end

local state: State = table.freeze({
	painting = false,
	coloring = false,
	pickingLook = false,
	-- Default to a road look, since painting paths onto grass is the common workflow.
	paintMaterial = Enum.Material.Asphalt,
	paintColor = Color3.fromRGB(90, 90, 95),
	paintVariant = "",
	recentLooks = {},
	paintFine = false,
	paintErase = false,
	meshing = false,
	meshMode = "Simplify" :: MeshMode,
	simplifyAngle = 5,
	picking = false,
	stitching = false,
	sampling = false,
	editingPoints = false,
	overlay = "none" :: Overlay,
	-- Covers road and curb thickness plus small gaps without grabbing parts across a path.
	stitchReach = 2,
	faces = "Top" :: FaceMode,
	mode = "Raise" :: BrushMode,
	radius = 8,
	strength = 6,
	height = 0,
	raiseToWorld = false,
	otherHeight = 0,
	falloff = "Soft" :: Falloff,
	axis = "Face" :: Axis,
	pickedAxis = Vector3.yAxis,
	paintSelectedOnly = false,
	-- Usable default range (Hammer starts at 0..0, which produces no displacement).
	noiseMin = -1,
	noiseMax = 1,
	power = 3,
	tileSize = 32,
	autosew = true,
	stitchParts = true,
	autoBake = true,
	smoothingAngle = 45,
	-- Small enough to stay invisible while letting flat ground bake with fewer triangles.
	bakeSimplifyAngle = 1,
	-- Small enough to stay invisible while flattening minor brush wobble on level ground.
	bakeHeightTolerance = 0.05,
	bakeSimplifyEdges = true,
	-- Off until texture alignment with neighboring unions is verified in a place.
	bakeFlatPart = false,
	-- Off by default so flat bridges, roofs, and plateaus keep their shadows.
	bakeFlatNoShadow = false,
	showKeyHints = true,
	-- Off by default for a cleaner 3D view; the brush ring still dims when empty.
	showBrushDots = false,
	ribbonTools = false,
})

local listeners: { [Listener]: true } = {}

function Settings.get(): State
	return state
end

-- Checks whether `look` matches the active paint look in `s`. Colors compare by 8-bit hex so a
-- look restored from saved settings still matches.
function Settings.isPaintLook(s: State, look: RecentLook): boolean
	return look.material == s.paintMaterial and look.variant == s.paintVariant and look.color:ToHex() == s.paintColor:ToHex()
end

-- Inserts the active paint look at the front of `recentLooks`, moving it up if already present.
function Settings.rememberPaintLook()
	Settings.update(function (s)
		local list: { RecentLook } = { { material = s.paintMaterial, color = s.paintColor, variant = s.paintVariant } }

		for _, look in s.recentLooks do
			if not Settings.isPaintLook(s, look) and #list < Settings.RECENT_LOOKS then
				table.insert(list, look)
			end
		end

		s.recentLooks = list
	end)
end

-- Applies `change` to a cloned state, clamps numeric fields, enforces tool exclusivity, and notifies listeners.
function Settings.update(change: (State) -> ())
	local nextState = table.clone(state)
	change(nextState)

	nextState.radius = math.clamp(nextState.radius, Settings.RADIUS_MIN, Settings.RADIUS_MAX)
	nextState.strength = math.clamp(nextState.strength, Settings.STRENGTH_MIN, Settings.STRENGTH_MAX)
	nextState.tileSize = math.clamp(nextState.tileSize, Settings.TILE_SIZE_MIN, Settings.TILE_SIZE_MAX)
	nextState.smoothingAngle = math.clamp(nextState.smoothingAngle, Settings.SMOOTHING_MIN, Settings.SMOOTHING_MAX)
	nextState.height = math.clamp(nextState.height, Settings.HEIGHT_MIN, Settings.HEIGHT_MAX)
	nextState.otherHeight = math.clamp(nextState.otherHeight, Settings.HEIGHT_MIN, Settings.HEIGHT_MAX)
	nextState.noiseMin = math.clamp(nextState.noiseMin, Settings.NOISE_MIN, Settings.NOISE_MAX)
	nextState.noiseMax = math.clamp(nextState.noiseMax, Settings.NOISE_MIN, Settings.NOISE_MAX)
	nextState.stitchReach = math.clamp(nextState.stitchReach, Settings.STITCH_REACH_MIN, Settings.STITCH_REACH_MAX)
	nextState.simplifyAngle = math.clamp(nextState.simplifyAngle, Settings.SIMPLIFY_ANGLE_MIN, Settings.SIMPLIFY_ANGLE_MAX)
	nextState.bakeSimplifyAngle = math.clamp(nextState.bakeSimplifyAngle, Settings.BAKE_SIMPLIFY_MIN, Settings.BAKE_SIMPLIFY_MAX)
	nextState.bakeHeightTolerance = math.clamp(nextState.bakeHeightTolerance, Settings.BAKE_TOLERANCE_MIN, Settings.BAKE_TOLERANCE_MAX)

	-- Viewport tools share the mouse, so activating one disables all others.
	local turnedOn = if nextState.painting and not state.painting
		then "painting"
		elseif nextState.coloring and not state.coloring then "coloring"
		elseif nextState.meshing and not state.meshing then "meshing"
		elseif nextState.picking and not state.picking then "picking"
		elseif nextState.stitching and not state.stitching then "stitching"
		elseif nextState.sampling and not state.sampling then "sampling"
		else nil

	if turnedOn then
		nextState.painting = turnedOn == "painting"
		nextState.coloring = turnedOn == "coloring"
		nextState.meshing = turnedOn == "meshing"
		nextState.picking = turnedOn == "picking"
		nextState.stitching = turnedOn == "stitching"
		nextState.sampling = turnedOn == "sampling"
		nextState.editingPoints = false
	elseif nextState.editingPoints and not state.editingPoints then
		nextState.painting = false
		nextState.coloring = false
		nextState.meshing = false
		nextState.picking = false
		nextState.stitching = false
		nextState.sampling = false
	end

	if not nextState.coloring then
		nextState.pickingLook = false
	end

	state = table.freeze(nextState)

	for listener in listeners do
		listener(state)
	end
end

-- Subscribes `listener` to state changes and returns an unsubscribe callback.
function Settings.subscribe(listener: Listener): () -> ()
	listeners[listener] = true

	return function ()
		listeners[listener] = nil
	end
end

-- Returns the currently active viewport tool, if any.
function Settings.activeTool(s: State): Tool?
	if s.painting then
		return s.mode
	elseif s.coloring then
		return "Material"
	elseif s.meshing then
		return "Mesh"
	elseif s.picking then
		return "PickFaces"
	elseif s.stitching then
		return "Stitch"
	end

	return nil
end

-- Returns whether a tile-editing tool is active (every viewport tool except Pick faces, plus
-- Edit points). Auto-bake waits until all editing tools stop so switching between tools does not
-- bake tiles only to unbake them on the next stroke.
function Settings.editing(s: State): boolean
	return s.painting or s.coloring or s.meshing or s.stitching or s.editingPoints
end

-- Turns Edit points on or off. Kept apart from stopViewportTool, which runs whenever Studio takes
-- the mouse back: Edit points exists precisely to keep working while Studio's tools have it.
function Settings.setEditingPoints(on: boolean)
	if state.editingPoints ~= on then
		Settings.update(function (s)
			s.editingPoints = on
		end)
	end
end

-- Starts `tool`, or stops it when already active (matching Studio's terrain editor).
-- Starting a tool closes Settings or Help so the tool's options are visible.
function Settings.toggleTool(tool: Tool)
	Settings.update(function (s)
		if Settings.activeTool(s) == tool then
			s.painting = false
			s.coloring = false
			s.meshing = false
			s.picking = false
			s.stitching = false
			return
		end

		s.overlay = "none"

		if tool == "Material" then
			s.coloring = true
		elseif tool == "Mesh" then
			s.meshing = true
		elseif tool == "PickFaces" then
			s.picking = true
		elseif tool == "Stitch" then
			s.stitching = true
		else
			s.mode = tool
			s.painting = true
		end
	end)
end

-- Stops whichever viewport tool is currently active (painting, coloring, meshing, picking, stitching, or sampling).
function Settings.stopViewportTool()
	if not (state.painting or state.coloring or state.meshing or state.picking or state.stitching or state.sampling) then
		return
	end

	Settings.update(function (s)
		s.painting = false
		s.coloring = false
		s.meshing = false
		s.picking = false
		s.stitching = false
		s.sampling = false
	end)
end

function Settings.setOverlay(overlay: Overlay)
	if state.overlay ~= overlay then
		Settings.update(function (s)
			s.overlay = overlay
		end)
	end
end

-- Adjusts brush radius by about 20% per step, snapped to half studs. For small brushes where
-- 20% rounds back to the same half stud, steps by 0.5 studs instead.
function Settings.stepRadius(direction: number)
	Settings.update(function (s)
		local factor = if direction > 0 then 1.2 else 1 / 1.2
		local nextRadius = math.round(s.radius * factor * 2) / 2

		if nextRadius == s.radius then
			nextRadius += if direction > 0 then 0.5 else -0.5
		end

		s.radius = nextRadius
	end)
end

-- Adjusts stitch reach by half a stud in the given direction.
function Settings.stepReach(direction: number)
	Settings.update(function (s)
		s.stitchReach += if direction > 0 then 0.5 else -0.5
	end)
end

return Settings
