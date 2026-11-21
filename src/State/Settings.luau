--!strict
--[[
	Shared tool settings. The UI, the ribbon buttons, keyboard shortcuts and plugin actions write
	them; the viewport tools read them every frame. Kept outside React so painting never waits on
	a re-render.
]]

local Paint = require(script.Parent.Parent.Core.Paint)
local PartFaces = require(script.Parent.Parent.Core.PartFaces)

export type BrushMode = Paint.Effect
export type FaceMode = PartFaces.Mode
export type Falloff = Paint.Falloff
export type Axis = Paint.Axis
-- The viewport tools, in ribbon and tool strip order.
export type Tool = "Raise" | "Lower" | "Smooth" | "RaiseTo" | "PickFaces" | "Stitch"
-- A page shown over the panel instead of the current context.
export type Overlay = "none" | "settings" | "help"

export type State = {
	-- The viewport tools share the mouse, so at most one of painting, picking and stitching is on.
	painting: boolean,
	-- Pick faces mode.
	picking: boolean,
	-- Stitch to part mode.
	stitching: boolean,
	-- Copy appearance mode: the next click on a part copies its look onto the selected tiles.
	sampling: boolean,
	-- Session only: Settings or Help covering the panel.
	overlay: Overlay,
	-- Studs a tile edge may move to snap onto a part edge when stitching.
	stitchReach: number,
	-- Which faces of selected parts Create converts.
	faces: FaceMode,
	mode: BrushMode,
	radius: number,
	strength: number,
	-- Raise To: studs along the axis from the flat base face.
	height: number,
	falloff: Falloff,
	axis: Axis,
	-- World-space axis for "Picked", set with Alt + Right Click.
	pickedAxis: Vector3,
	-- Paint only the selected displacements (Hammer's behavior); otherwise everything.
	paintSelectedOnly: boolean,
	-- Noise range in studs.
	noiseMin: number,
	noiseMax: number,
	power: number,
	-- Studs per tile when creating an area; parts smaller than this become one displacement.
	tileSize: number,
	-- Sew edited displacements to their neighbors after every stroke or power change.
	autosew: boolean,
	-- Keep edges stitched: tile edges that touch a part edge before an edit are snapped back
	-- onto it afterwards (works with or without autosew).
	stitchParts: boolean,
	-- Merge edited displacements into unions when a viewport tool stops and after edit actions.
	autoBake: boolean,
	-- UnionOperation.SmoothingAngle for baked surfaces (0 = flat shaded).
	smoothingAngle: number,
	-- Show the key strip at the bottom of the viewport while a tool runs.
	showKeyHints: boolean,
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
Settings.HEIGHT_MIN = -256
Settings.HEIGHT_MAX = 256
Settings.NOISE_MIN = -64
Settings.NOISE_MAX = 64
Settings.STITCH_REACH_MIN = 0.5
Settings.STITCH_REACH_MAX = 16

local MODES: { BrushMode } = { "Raise", "Lower", "Smooth", "RaiseTo" }
local MODE_LABELS: { [BrushMode]: string } = {
	Raise = "Raise",
	Lower = "Lower",
	Smooth = "Smooth",
	RaiseTo = "Raise To",
}
local TOOLS: { Tool } = { "Raise", "Lower", "Smooth", "RaiseTo", "PickFaces", "Stitch" }
local TOOL_LABELS: { [Tool]: string } = {
	Raise = "Raise",
	Lower = "Lower",
	Smooth = "Smooth",
	RaiseTo = "Raise To",
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

-- Ordered choices and their display names. Functions keep the exact string types across
-- modules (table fields would widen them to string).
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
	picking = false,
	stitching = false,
	sampling = false,
	overlay = "none" :: Overlay,
	-- Covers road and curb thickness plus small gaps without grabbing parts across a path.
	stitchReach = 2,
	faces = "Top" :: FaceMode,
	mode = "Raise" :: BrushMode,
	radius = 8,
	strength = 6,
	height = 0,
	falloff = "Soft" :: Falloff,
	axis = "Face" :: Axis,
	pickedAxis = Vector3.yAxis,
	paintSelectedOnly = false,
	-- A usable range out of the box (Hammer starts at 0 and 0, which does nothing).
	noiseMin = -1,
	noiseMax = 1,
	power = 3,
	tileSize = 32,
	autosew = true,
	stitchParts = true,
	autoBake = true,
	smoothingAngle = 45,
	showKeyHints = true,
})

local listeners: { [Listener]: true } = {}

function Settings.get(): State
	return state
end

-- Applies `change` to a copy of the current state and notifies listeners.
function Settings.update(change: (State) -> ())
	local nextState = table.clone(state)
	change(nextState)
	nextState.radius = math.clamp(nextState.radius, Settings.RADIUS_MIN, Settings.RADIUS_MAX)
	nextState.strength = math.clamp(nextState.strength, Settings.STRENGTH_MIN, Settings.STRENGTH_MAX)
	nextState.tileSize = math.clamp(nextState.tileSize, Settings.TILE_SIZE_MIN, Settings.TILE_SIZE_MAX)
	nextState.smoothingAngle = math.clamp(nextState.smoothingAngle, Settings.SMOOTHING_MIN, Settings.SMOOTHING_MAX)
	nextState.height = math.clamp(nextState.height, Settings.HEIGHT_MIN, Settings.HEIGHT_MAX)
	nextState.noiseMin = math.clamp(nextState.noiseMin, Settings.NOISE_MIN, Settings.NOISE_MAX)
	nextState.noiseMax = math.clamp(nextState.noiseMax, Settings.NOISE_MIN, Settings.NOISE_MAX)
	nextState.stitchReach = math.clamp(nextState.stitchReach, Settings.STITCH_REACH_MIN, Settings.STITCH_REACH_MAX)
	-- The viewport tools share the mouse: turning one on turns the others off.
	if nextState.painting and not state.painting then
		nextState.picking = false
		nextState.stitching = false
		nextState.sampling = false
	elseif nextState.picking and not state.picking then
		nextState.painting = false
		nextState.stitching = false
		nextState.sampling = false
	elseif nextState.stitching and not state.stitching then
		nextState.painting = false
		nextState.picking = false
		nextState.sampling = false
	elseif nextState.sampling and not state.sampling then
		nextState.painting = false
		nextState.picking = false
		nextState.stitching = false
	end
	state = table.freeze(nextState)
	for listener in listeners do
		listener(state)
	end
end

-- Returns a function that unsubscribes.
function Settings.subscribe(listener: Listener): () -> ()
	listeners[listener] = true
	return function()
		listeners[listener] = nil
	end
end

-- The running viewport tool, if any.
function Settings.activeTool(s: State): Tool?
	if s.painting then
		return s.mode
	elseif s.picking then
		return "PickFaces"
	elseif s.stitching then
		return "Stitch"
	end
	return nil
end

-- Starts `tool`, or stops it when it is already running, like the tools in Studio's terrain
-- editor. Starting a tool closes Settings or Help so its options are visible.
function Settings.toggleTool(tool: Tool)
	Settings.update(function(s)
		if Settings.activeTool(s) == tool then
			s.painting = false
			s.picking = false
			s.stitching = false
			return
		end
		s.overlay = "none"
		if tool == "PickFaces" then
			s.picking = true
		elseif tool == "Stitch" then
			s.stitching = true
		else
			s.mode = tool
			s.painting = true
		end
	end)
end

-- Stops whichever viewport tool is running (painting, picking, stitching or sampling).
function Settings.stopViewportTool()
	if state.painting or state.picking or state.stitching or state.sampling then
		Settings.update(function(s)
			s.painting = false
			s.picking = false
			s.stitching = false
			s.sampling = false
		end)
	end
end

function Settings.setOverlay(overlay: Overlay)
	if state.overlay ~= overlay then
		Settings.update(function(s)
			s.overlay = overlay
		end)
	end
end

-- Grows or shrinks the brush by about 20% per step, snapped to half studs. Small brushes, where
-- 20% rounds back to the same half stud, step by half a stud instead.
function Settings.stepRadius(direction: number)
	Settings.update(function(s)
		local factor = if direction > 0 then 1.2 else 1 / 1.2
		local nextRadius = math.round(s.radius * factor * 2) / 2
		if nextRadius == s.radius then
			nextRadius += if direction > 0 then 0.5 else -0.5
		end
		s.radius = nextRadius
	end)
end

-- Grows or shrinks the stitch reach by half a stud.
function Settings.stepReach(direction: number)
	Settings.update(function(s)
		s.stitchReach += if direction > 0 then 0.5 else -0.5
	end)
end

return Settings
