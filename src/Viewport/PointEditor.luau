--!strict
--[[
	Edit points: puts a small handle Part on every editable point of the chosen tiles, so points
	can be picked and moved with Studio's own Select, Move, Rotate, and Scale tools (box select,
	increments, local or world axes, the Properties window).

	Handles live in a workspace folder and are never saved: folder and handles are not Archivable,
	which also keeps them out of undo history. Each handle sits on the surface with its pivot
	exactly on its point (PivotOffset), and the point follows the pivot. Studio's freeform drag
	rests a part's bounds on the surface under the cursor, so a handle centered on its point would
	climb a little with every mouse move over its own tile; resting on the point it cannot. Exact
	coordinates are in Properties under Pivot > Origin.

	Handles keep a locked frame (their tile's normal and grid direction), so Local-space gizmos
	stay meaningful. Rotating a group still swings its points around the group's center; once a
	handle is still, its rotation, size, and pivot are put back. A rotation that moved nothing (a
	single handle) is rejected with a brief flash and a status hint.

	Undo: Studio's draggers do not record; they set a waypoint when a drag ends. Handles are
	untracked, so those waypoints stay empty, and every change to the terrain is made here inside
	our own recording: one per frame at most, the first of a burst committed as a new step and the
	rest appended to it, so a whole drag (or one Properties edit) undoes in one step. After an
	undo or redo the terrain is authoritative and the handles move back to match it.

	One handle per point position: points shared by edited tiles (seams, corners) share a handle,
	and neighbors outside the edit follow through Edges.movePoints, which keeps seams closed.
	Points with nothing to move get no handle: points removed by Simplify (they follow the
	surface), points whose every triangle is a hole, and the middle points of a denser tile along
	a coarser neighbor's 2:1 edge (they must stay on that straight edge).

	Deleting handles (Delete, Cut) removes their points like the Mesh tool's Simplify, as one undo
	step; the surface fills in with larger triangles. Tile corners always stay, so their handles
	come back.
]]

local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Viewport = script.Parent
local Plugin = Viewport.Parent
local Core = Plugin.Core
local State = Plugin.State
local Scene = Plugin.Scene
local Actions = Plugin.Actions

local Stitch = require(Core.Stitch)
local Displacement = require(Core.Displacement)
local TerrainInstance = require(Core.TerrainInstance)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)

local Bake = require(Actions.Bake)
local Edges = require(Actions.Edges)
local MeshActions = require(Actions.Mesh)

type Opened = TerrainInstance.Opened

type Member = { model: Model, index: number }

type Handle = {
	part: Part,
	-- Every edited tile point at this position; the first one is the reference.
	members: { Member },
	-- Ball diameter, restored after Studio's Scale tool resizes the handle.
	size: number,
	-- The handle's locked frame: `up` is the direction it rests along (its tiles' face normal,
	-- averaged where tiles meet) and `right` follows its tile's grid, so Local-space gizmos move
	-- along the tile normal and grid axes.
	up: Vector3,
	right: Vector3,
}

-- A handle whose CFrame, Size, or PivotOffset changed, until it has been still for QUIET.
type Change = {
	at: number,
	-- Whether its point moved during the change; a rotation that moved nothing was rejected.
	moved: boolean,
}

-- Tags the handle folder so other code can recognize it.
local FOLDER_TAG = "StrataPoints"
local RECORDING = "Strata move points"
-- Edits closer together than this belong to one undo step (one drag, or a burst of nudges).
local BURST_GAP = 0.35
-- Handles within this distance of their point count as unmoved.
local SAME = 1e-4
-- Points of neighboring tiles at the same flat position within this distance are one point
-- (matching Edges.seamTwins and Sew).
local TWIN_DISTANCE = 1 / 16
-- How long deleted handles wait for another recording (Studio's own Delete) to finish.
local DELETE_WAIT = 5
-- Beyond this many handles Studio slows down and the points become an unreadable cloud.
local MAX_HANDLES = 2500
-- Handle diameter as a share of the grid spacing, clamped to stay clickable and not overlap.
local SIZE_SHARE = 0.3
local MIN_SIZE = 0.15
local MAX_SIZE = 0.8
local COLOR = Color3.fromRGB(255, 176, 32)
-- Handles snap back to their locked frame, size, and pivot once still this long, so Studio's
-- Rotate and Scale drags are never fought mid-drag.
local QUIET = 0.12
-- Rotation drift beyond this dot product (about 0.8 degrees) counts as rotated; well above the
-- rounding of our own writes, so restoring a handle never loops.
local ROTATED_DOT = 1 - 1e-4
-- A rejected rotation flashes the handle in this color, for this long.
local PULSE_COLOR = Color3.fromRGB(255, 80, 80)
local PULSE_TIME = 0.25
-- The rejected rotation message repeats at most this often.
local HINT_GAP = 3

local PointEditor = {}

local folder: Folder? = nil
-- The current handles' folder inside `folder`, replaced whole on every rebuild.
local container: Folder? = nil
local handles: { Handle } = {}
local byPart: { [BasePart]: Handle } = {}
-- Edited tiles, and a signature of each one's point layout to detect undo past a detail change,
-- Simplify, or Restore points.
local models: { Model } = {}
local layouts: { [Model]: string } = {}
local dirty: { [Handle]: true } = {}
local changes: { [Handle]: Change } = {}
local lastHint = -math.huge
local lastFlush = -math.huge
-- Set by undo and redo so the next edit always starts a new undo step.
local historyChanged = true
-- Guards against reacting to our own selection change (a second, deferred event finds a
-- handles-only selection and does nothing).
local filtering = false
local scheduled = false
local sessionConnections: { RBXScriptConnection } = {}
-- Tiles chosen by PointEditor.enter, picked up when the setting turns on.
local pending: { Model } = {}
-- Defers a resync to the end of the frame (defined below, after the functions it needs).
local scheduleResync: () -> ()

local function frameOf(handle: Handle, position: Vector3): CFrame
	return CFrame.fromMatrix(position, handle.right, handle.up)
end

-- Whether the handle's rotation has left its locked frame.
local function rotated(handle: Handle): boolean
	local cframe = handle.part.CFrame

	return cframe.UpVector:Dot(handle.up) < ROTATED_DOT or cframe.RightVector:Dot(handle.right) < ROTATED_DOT
end

-- Includes the tile's pivot, so moving or rotating a tile rebuilds its handles in the new frame.
local function layoutOf(opened: Opened): string
	local removed = 0

	for _ in opened.disp.removed do
		removed += 1
	end

	return `{opened.disp.power}:{removed}:{opened.model:GetPivot()}`
end

-- World position of a member's point, or nil when its tile is gone.
local function pointOf(member: Member): Vector3?
	local opened = Session.get(member.model)

	if not opened or member.index > Displacement.vertexCount(opened.disp) then
		return nil
	end

	return opened.model:GetPivot() * Displacement.position(opened.disp, member.index)
end

-- Puts the handle back in its locked frame, size, and pivot, resting on `point`.
local function place(handle: Handle, point: Vector3)
	local part = handle.part

	if math.abs(part.Size.X - handle.size) > SAME or math.abs(part.Size.Y - handle.size) > SAME or math.abs(part.Size.Z - handle.size) > SAME then
		part.Size = Vector3.one * handle.size
	end

	part.PivotOffset = CFrame.new(0, -handle.size / 2, 0)
	part:PivotTo(frameOf(handle, point))
end

-- Where a handle's point is according to the handle: its pivot with the handle's own offset,
-- so a pivot edited in Properties or with Edit Pivot never moves the point.
local function targetOf(handle: Handle): Vector3
	return (handle.part.CFrame * CFrame.new(0, -handle.size / 2, 0)).Position
end

-- Moves handles back onto their points (after undo, redo, a tile moving, or seams following an
-- edit), leaving `skip` alone so a handle Studio is dragging is not fought over.
local function reposition(skip: { [Handle]: true }?)
	for _, handle in handles do
		if skip and skip[handle] then
			continue
		end

		local point = pointOf(handle.members[1])

		if point and (targetOf(handle) - point).Magnitude > SAME then
			place(handle, point)
		end
	end
end

-- Whether flat point `flat` lies inside (not at the ends of) an edge of a tile in `others`.
local function onEdgeInterior(flat: Vector3, owner: Opened, others: { Opened }): boolean
	for _, other in others do
		if other == owner then
			continue
		end

		local pivot = other.model:GetPivot()

		for _, edge in Displacement.edges(other.disp) do
			local a = pivot * Displacement.flatPosition(other.disp, edge.indices[1])
			local b = pivot * Displacement.flatPosition(other.disp, edge.indices[#edge.indices])
			local ab = b - a
			local length2 = ab:Dot(ab)

			if length2 < 1e-9 then
				continue
			end

			local t = (flat - a):Dot(ab) / length2
			local along = math.sqrt(length2) * math.min(t, 1 - t)

			if along > TWIN_DISTANCE and (flat - (a + ab * t)).Magnitude <= TWIN_DISTANCE then
				return true
			end
		end
	end

	return false
end

local function allHoles(disp: Displacement.Displacement, index: number): boolean
	for _, t in Displacement.trianglesTouching(disp, { [index] = true }) do
		if not Displacement.isHole(disp, t) then
			return false
		end
	end

	return true
end

-- Collects one member list per handle for the edited tiles; returns nil when over MAX_HANDLES.
local function collect(edited: { Opened }): ({ { Member } }?, number)
	local all = Session.flatNeighbors(edited, 1)
	local twinsOf = Edges.seamTwins(all)
	local groups: { { Member } } = {}
	local groupOf: { [Opened]: { [number]: { Member } } } = {}
	local editedSet: { [Opened]: true } = {}

	for _, opened in edited do
		editedSet[opened] = true
		groupOf[opened] = {}
	end

	for _, opened in edited do
		local disp = opened.disp
		local pivot = opened.model:GetPivot()
		local onEdge: { [number]: true } = {}

		for _, edge in Displacement.edges(disp) do
			for _, v in edge.indices do
				onEdge[v] = true
			end
		end

		for v = 1, Displacement.vertexCount(disp) do
			if disp.removed[v] or groupOf[opened][v] or allHoles(disp, v) then
				continue
			end

			local group: { Member }? = nil

			if onEdge[v] then
				local twins = twinsOf(opened, v)

				if #twins == 0 and onEdgeInterior(pivot * Displacement.flatPosition(disp, v), opened, all) then
					continue
				end

				-- Join the handle of a twin on another edited tile, if it already has one.
				for _, twin in twins do
					local existing = if editedSet[twin.opened] then groupOf[twin.opened][twin.index] else nil

					if existing then
						group = existing
						break
					end
				end
			end

			local members: { Member } = group or {}

			if not group then
				table.insert(groups, members)

				if #groups > MAX_HANDLES then
					return nil, #groups
				end
			end

			table.insert(members, { model = opened.model, index = v })
			groupOf[opened][v] = members
		end
	end

	return groups, #groups
end

local function spacingOf(opened: Opened): number
	local c = opened.disp.corners
	local pivot = opened.model:GetPivot()
	local segments = 2 ^ opened.disp.power
	local a = (pivot * c[2] - pivot * c[1]).Magnitude
	local b = (pivot * c[4] - pivot * c[1]).Magnitude

	return math.min(a, b) / segments
end

-- Notes a change to a handle; a CFrame change may also have moved its point.
local function noteChange(handle: Handle, moved: boolean)
	if moved then
		dirty[handle] = true
	end

	local change = changes[handle]

	if change then
		change.at = os.clock()
	else
		changes[handle] = { at = os.clock(), moved = false }
	end
end

-- Handles deleted since the last removal pass, removed together as one undo step.
local deleted: { Handle } = {}
local deletedAt = 0
-- Whether a recording (Studio's own Delete) was open when the handles went. Studio still adds
-- that step even though handles are untracked, so the removal joins it: one Ctrl + Z restores.
local deletedInRecording = false

-- Removes the points of deleted handles, then rebuilds (bringing back any corner handle). Runs
-- from the Heartbeat flush: Studio's own Delete is still recording when the handles go, so this
-- waits for that recording (or a bake) to finish rather than failing to start its own.
local function removeDeleted()
	if Session.isBaking() or ChangeHistoryService:IsRecordingInProgress() then
		if os.clock() - deletedAt < DELETE_WAIT then
			return
		end

		Status.post("error", "Could not remove points while Studio is busy.")
		table.clear(deleted)
		table.clear(layouts)
		scheduleResync()
		return
	end

	local list = deleted
	deleted = {}

	local points: { [Opened]: { number } } = {}
	local removable, corners = 0, 0

	for _, handle in list do
		local found: { { tile: Opened, index: number } } = {}
		local corner = false

		for _, member in handle.members do
			local tile = Session.get(member.model)

			if tile then
				table.insert(found, { tile = tile, index = member.index })
				corner = corner or Displacement.isCorner(tile.disp, member.index)
			end
		end

		-- A point that is a corner of any tile stays on all of them, so seams keep matching.
		if corner then
			corners += 1
			continue
		end

		for _, entry in found do
			local own = points[entry.tile] or {}
			table.insert(own, entry.index)
			points[entry.tile] = own
		end

		removable += 1
	end

	local note = if corners > 0 then ` ({Format.plural(corners, "corner")} kept)` else ""
	local ok, err = pcall(MeshActions.removePoints, points, deletedInRecording)

	if not ok then
		Status.post("error", `Could not remove points: {err}`)
	elseif removable > 0 then
		Status.post("success", `Removed {Format.plural(removable, "point")}{note}.`)
	elseif corners > 0 then
		Status.post("warning", "Tile corners cannot be removed.")
	end

	-- A cleared layout forces a full rebuild, so every point that still exists gets its handle back.
	table.clear(layouts)
	scheduleResync()
end

-- Deleting handles (Delete, Cut) removes their points; grouping them or moving them out
-- (Ctrl+G, dragging in the Explorer) would strand points, so they are put back. Plugin signals
-- arrive deferred, after our own cleanup has finished, so a removal counts only when it is a
-- current handle or the current handle folder: everything we remove ourselves is forgotten first.
local function onRemoved(child: Instance)
	if child == container then
		Status.post("warning", "Cannot move or delete the handles folder; delete handles directly.")
		table.clear(layouts)
		scheduleResync()
		return
	end

	local handle = if child:IsA("BasePart") then byPart[child] else nil

	if not handle or child.Parent == container then
		return
	end

	if child.Parent == nil then
		if #deleted == 0 then
			deletedAt = os.clock()
			deletedInRecording = ChangeHistoryService:IsRecordingInProgress()
		end

		table.insert(deleted, handle)
	else
		Status.post("warning", "Handles cannot be grouped or moved out of their folder.")
		table.clear(layouts)
		scheduleResync()
	end
end

local function clearHandles()
	local old = container
	container = nil
	table.clear(handles)
	table.clear(byPart)
	table.clear(dirty)
	table.clear(changes)

	if old then
		old:Destroy()
	end
end

-- (Re)creates handles for the edited tiles, keeping the selected points selected. Returns false
-- (and posts why) when there is nothing to edit or too much.
local function build(): boolean
	local selectedKeys: { [string]: true } = {}

	for _, inst in Selection:Get() do
		local handle = if inst:IsA("BasePart") then byPart[inst] else nil

		if handle then
			local first = handle.members[1]
			selectedKeys[`{first.model:GetDebugId()}:{first.index}`] = true
		end
	end

	clearHandles()

	local live: { Model } = {}

	for _, model in models do
		if model:IsDescendantOf(workspace) and CollectionService:HasTag(model, TerrainInstance.TAG) then
			table.insert(live, model)
		end
	end

	models = live

	local edited = Session.getAll(models)

	if #edited == 0 then
		return false
	end

	local groups = collect(edited)

	if not groups then
		Status.post("error", `Over {Format.count(MAX_HANDLES)} points; select fewer tiles.`)
		return false
	end

	local root = folder

	if not root then
		return false
	end

	table.clear(layouts)

	for _, opened in edited do
		layouts[opened.model] = layoutOf(opened)
	end

	local reselect: { Instance } = {}
	local sizes: { [Model]: number } = {}
	local normals: { [Model]: Vector3 } = {}
	-- Each tile's first grid edge in world space, giving handles the tile's own grid direction.
	local edges: { [Model]: Vector3 } = {}

	for _, opened in edited do
		local pivot = opened.model:GetPivot()
		local corners = opened.disp.corners
		sizes[opened.model] = math.clamp(spacingOf(opened) * SIZE_SHARE, MIN_SIZE, MAX_SIZE)
		normals[opened.model] = pivot:VectorToWorldSpace(Displacement.faceNormal(opened.disp))
		edges[opened.model] = pivot:VectorToWorldSpace(corners[2] - corners[1])
	end

	-- A handle rests along its tiles' averaged normal, so where tiles meet at an angle the ball
	-- sits outside both, whichever tile comes first; it falls back to the first tile's normal
	-- when the normals cancel out.
	local function frameFor(members: { Member }): (Vector3, Vector3)
		local first = members[1].model
		local sum = Vector3.zero
		local seen: { [Model]: true } = {}

		for _, member in members do
			if not seen[member.model] then
				seen[member.model] = true
				sum += normals[member.model]
			end
		end

		local up = if sum.Magnitude > 1e-3 then sum.Unit else normals[first]
		local edge = edges[first]
		local right = edge - up * edge:Dot(up)

		if right.Magnitude < 1e-3 then
			right = up:Cross(if math.abs(up.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis)
		end

		return up, right.Unit
	end

	-- Filled while unparented, then added to the place at once: one insertion instead of one per
	-- handle keeps Studio (the Explorer especially) from handling thousands of separate events.
	local holder = Instance.new("Folder")
	holder.Name = "Handles"
	holder.Archivable = false

	for _, members in groups do
		local first = members[1]
		local point = pointOf(first)

		if not point then
			continue
		end

		local size = sizes[first.model]
		local part = Instance.new("Part")
		part.Name = "Point"
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.one * size
		part.Color = COLOR
		part.Material = Enum.Material.Neon
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CastShadow = false
		part.Archivable = false

		local up, right = frameFor(members)
		local handle: Handle = { part = part, members = members, size = size, up = up, right = right }
		place(handle, point)
		part.Parent = holder

		table.insert(handles, handle)
		byPart[part] = handle

		part:GetPropertyChangedSignal("CFrame"):Connect(function ()
			noteChange(handle, true)
		end)

		-- Resizing a single handle or editing its pivot (Edit Pivot, Properties) moves no point;
		-- the handle is just put back once still.
		part:GetPropertyChangedSignal("Size"):Connect(function ()
			noteChange(handle, false)
		end)

		part:GetPropertyChangedSignal("PivotOffset"):Connect(function ()
			noteChange(handle, false)
		end)

		if selectedKeys[`{first.model:GetDebugId()}:{first.index}`] then
			table.insert(reselect, part)
		end
	end

	holder.ChildRemoved:Connect(onRemoved)
	holder.Parent = root
	container = holder

	if #reselect > 0 then
		Selection:Set(reselect)
	end

	return true
end

local function deactivate()
	for _, connection in sessionConnections do
		connection:Disconnect()
	end

	table.clear(sessionConnections)

	-- Leave the panel on the edited tiles rather than an empty selection.
	local onlyHandles = true

	for _, inst in Selection:Get() do
		if not (inst:IsA("BasePart") and byPart[inst]) then
			onlyHandles = false
			break
		end
	end

	clearHandles()

	local root = folder
	folder = nil

	if root then
		root:Destroy()
	end

	if onlyHandles then
		local live: { Instance } = {}

		for _, model in models do
			if model:IsDescendantOf(workspace) then
				table.insert(live, model)
			end
		end

		Selection:Set(live)
	end

	table.clear(models)
	table.clear(layouts)
	table.clear(deleted)

	local state = Settings.get()

	if state.autoBake and not Settings.editing(state) then
		task.spawn(Bake.bakeEdited)
	end
end

-- Rebuilds when the point layout changed (undo past Detail, Simplify, Restore points, a tile
-- deleted), otherwise moves handles back onto their points.
local function resync()
	scheduled = false

	if not folder then
		return
	end

	local changed = false

	for _, model in models do
		local opened = if model:IsDescendantOf(workspace) then Session.get(model) else nil

		if not opened or layoutOf(opened) ~= layouts[model] then
			changed = true
			break
		end
	end

	if not changed then
		reposition()
	elseif not build() then
		Settings.setEditingPoints(false)
	end
end

scheduleResync = function ()
	if not scheduled then
		scheduled = true
		task.defer(resync)
	end
end

local function topIsOurs(): boolean
	local _, name = ChangeHistoryService:GetCanUndo()

	return name == RECORDING
end

-- Briefly flashes a handle whose rotation was rejected, right where the user is looking.
local function pulse(handle: Handle)
	local part = handle.part
	part.Color = PULSE_COLOR

	task.delay(PULSE_TIME, function ()
		if part.Parent then
			part.Color = COLOR
		end
	end)
end

-- Puts handles that have been still for QUIET back in their locked frame, size, and pivot.
-- Doing this only once a handle is still never fights Studio's Rotate or Scale tool mid-drag.
-- A rotation that moved no point (a single handle, or an Orientation edit in Properties) was
-- rejected: the handle flashes and the status bar says why.
local function restore()
	local now = os.clock()
	local rejected: { Handle } = {}
	local anyMoved = false

	for handle, change in changes do
		if now - change.at < QUIET or dirty[handle] then
			continue
		end

		changes[handle] = nil

		local part = handle.part
		local point = if part.Parent then pointOf(handle.members[1]) else nil

		if not point then
			continue
		end

		local wasRotated = rotated(handle)
		local off = wasRotated
			or math.abs(part.Size.X - handle.size) > SAME
			or math.abs(part.Size.Y - handle.size) > SAME
			or math.abs(part.Size.Z - handle.size) > SAME
			or (part.PivotOffset.Position - Vector3.new(0, -handle.size / 2, 0)).Magnitude > SAME
			or (part:GetPivot().Position - point).Magnitude > SAME

		if off then
			place(handle, point)
		end

		if change.moved then
			anyMoved = true
		elseif wasRotated then
			table.insert(rejected, handle)
		end
	end

	-- A group rotation can leave the point at its center unmoved; that is no rejection.
	if #rejected == 0 or anyMoved then
		return
	end

	for _, handle in rejected do
		pulse(handle)
	end

	if now - lastHint > HINT_GAP then
		lastHint = now
		Status.post("warning", "Single points cannot rotate. Select multiple points to rotate them as a group.")
	end
end

-- Writes moved handles to the terrain, at most once per frame, inside our own recording.
local function flush()
	if #deleted > 0 then
		removeDeleted()
	end

	if next(dirty) == nil then
		restore()
		return
	end

	-- A bake yields inside its own recording; keep the handles dirty and try again later.
	if Session.isBaking() then
		return
	end

	local moves: Stitch.Moves = {}
	local moved: { [Handle]: true } = {}
	local any = false

	for handle in dirty do
		local part = handle.part

		if not part.Parent then
			continue
		end

		local first = handle.members[1]
		local point = pointOf(first)
		local target = targetOf(handle)

		if not point or (point - target).Magnitude <= SAME then
			continue
		end

		-- Properties' Orientation (and Ctrl + R or Ctrl + T on some setups) turns a part around its
		-- center, not its pivot, which would swing the pivot off the point. A rotation that kept the
		-- ball's center is no move; restore() puts the handle back.
		if rotated(handle) and (part.Position - (point + handle.up * handle.size / 2)).Magnitude <= SAME then
			continue
		end

		for _, member in handle.members do
			local opened = Session.get(member.model)

			if opened then
				local targets = moves[opened] or {}
				targets[member.index] = target
				moves[opened] = targets
			end
		end

		moved[handle] = true
		any = true
	end

	if not any then
		table.clear(dirty)
		return
	end

	local recording = ChangeHistoryService:TryBeginRecording(RECORDING)

	-- Another recording is open (a Strata action, a Studio operation); try again next frame.
	if not recording then
		return
	end

	table.clear(dirty)

	local continuing = not historyChanged and os.clock() - lastFlush <= BURST_GAP and topIsOurs()
	local ok, err = pcall(function ()
		for _, opened in Edges.movePoints(moves) do
			TerrainInstance.save(opened)
		end
	end)

	ChangeHistoryService:FinishRecording(
		recording,
		if not ok
			then Enum.FinishRecordingOperation.Cancel
			elseif continuing then Enum.FinishRecordingOperation.Append
			else Enum.FinishRecordingOperation.Commit
	)

	if not ok then
		-- Cancelling reverted the terrain; drop cached tiles and put the handles back.
		Session.clear()
		Status.post("error", `Could not move points: {err}`)
		scheduleResync()
		return
	end

	lastFlush = os.clock()
	historyChanged = false

	for handle in moved do
		local change = changes[handle]

		if change then
			change.moved = true
		end
	end

	-- Seams may have pulled other edited points along; show them where they are now.
	reposition(moved)
	restore()
end

-- Keeps a selection that includes handles to handles only, so box selecting points does not
-- also grab (and drag) the terrain, a TerrainArea, or nearby architecture.
local function filterSelection()
	if filtering then
		return
	end

	local selected = Selection:Get()
	local points: { Instance } = {}

	for _, inst in selected do
		if inst:IsA("BasePart") and byPart[inst] then
			table.insert(points, inst)
		end
	end

	if #points > 0 and #points < #selected then
		filtering = true
		Selection:Set(points)
		filtering = false
	end
end

local function activate(chosen: { Model }): boolean
	models = table.clone(chosen)

	local root = Instance.new("Folder")
	root.Name = "StrataPoints"
	root.Archivable = false
	CollectionService:AddTag(root, FOLDER_TAG)
	folder = root

	if not build() then
		root:Destroy()
		folder = nil
		table.clear(models)
		return false
	end

	root.Parent = workspace
	historyChanged = true
	lastFlush = -math.huge

	local selected: { Instance } = {}

	-- Start with nothing selected among the points; the tiles stay remembered for Done.
	Selection:Set(selected)

	table.insert(sessionConnections, RunService.Heartbeat:Connect(flush))
	table.insert(sessionConnections, Selection.SelectionChanged:Connect(filterSelection))

	table.insert(sessionConnections, ChangeHistoryService.OnUndo:Connect(function ()
		historyChanged = true
		table.clear(dirty)
		scheduleResync()
	end))

	table.insert(sessionConnections, ChangeHistoryService.OnRedo:Connect(function ()
		historyChanged = true
		table.clear(dirty)
		scheduleResync()
	end))

	-- The handles' own folder deleted or grouped counts like deleting handles.
	table.insert(sessionConnections, root.ChildRemoved:Connect(onRemoved))

	-- Deleting the whole folder ends Edit points (our own removal clears `folder` first).
	table.insert(sessionConnections, root.AncestryChanged:Connect(function ()
		if folder == root and not root:IsDescendantOf(workspace) then
			Settings.setEditingPoints(false)
		end
	end))

	for _, model in models do
		table.insert(sessionConnections, model:GetPropertyChangedSignal("WorldPivot"):Connect(scheduleResync))
		table.insert(sessionConnections, model.AncestryChanged:Connect(scheduleResync))
	end

	return true
end

-- Starts Edit points on the selected tiles. Returns how many points got handles.
function PointEditor.enter(): number
	local chosen = Query.selectedModels()

	if #chosen == 0 then
		Status.post("warning", "Select tiles to edit their points.")
		return 0
	end

	pending = chosen
	Settings.setEditingPoints(true)

	return #handles
end

-- Selects every point handle.
function PointEditor.selectAll()
	local parts: { Instance } = table.create(#handles)

	for i, handle in handles do
		parts[i] = handle.part
	end

	Selection:Set(parts)
end

export type Info = {
	tiles: number,
	points: number,
	selected: number,
	-- Edited tiles with points removed by Simplify (those points have no handle).
	simplified: number,
}

function PointEditor.info(): Info
	local selected = 0

	for _, inst in Selection:Get() do
		if inst:IsA("BasePart") and byPart[inst] then
			selected += 1
		end
	end

	local simplified = 0

	for _, model in models do
		local opened = Session.peek(model)

		if opened and next(opened.disp.removed) ~= nil then
			simplified += 1
		end
	end

	return { tiles = #models, points = #handles, selected = selected, simplified = simplified }
end

-- Follows Settings.editingPoints; returns a cleanup callback.
function PointEditor.start(): () -> ()
	local active = false

	local function sync(state: Settings.State)
		if state.editingPoints and not active then
			local chosen = pending
			pending = {}

			if activate(chosen) then
				active = true
			else
				Settings.setEditingPoints(false)
			end
		elseif not state.editingPoints and active then
			active = false
			deactivate()
		end
	end

	local unsubscribe = Settings.subscribe(sync)

	return function ()
		unsubscribe()

		if active then
			active = false
			deactivate()
		end
	end
end

return PointEditor
