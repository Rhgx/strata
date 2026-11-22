--!strict
--[[
	Turning parts into terrain. Two forms: the selected block and wedge parts (with a Faces
	choice), or the faces collected by the Pick faces tool.
]]
local Packages = script.Parent.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local PartFaces = require(script.Parent.Parent.Parent.Core.PartFaces)
local Settings = require(script.Parent.Parent.Parent.State.Settings)

local Query = require(script.Parent.Parent.Parent.Scene.Query)
local Create = require(script.Parent.Parent.Parent.Actions.Create)
local PickFaceTool = require(script.Parent.Parent.Parent.Viewport.PickFaceTool)
local Format = require(script.Parent.Parent.Format)
local Icons = require(script.Parent.Parent.Icons)
local Rows = require(script.Parent.Parent.Rows)
local Dropdown = require(script.Parent.Parent.Dropdown)

local e = React.createElement

-- Hammer powers 2, 3 and 4.
local DETAIL_ITEMS = {
	{ Id = "2", Text = "Low (5x5)" },
	{ Id = "3", Text = "Medium (9x9)" },
	{ Id = "4", Text = "High (17x17)" },
}

-- The Clear button at the end of the Picked row (the height of a property row).
local CLEAR_SIZE = 22

local FACE_ITEMS = {
	{ Id = "Top", Text = "Top", Icon = Icons.FacesTop },
	{ Id = "TopSides", Text = "Top + sides", Icon = Icons.FacesTopSides },
	{ Id = "All", Text = "All faces", Icon = Icons.FacesAll },
}

-- Re-renders when faces are picked or unpicked.
local function usePicks(): { PickFaceTool.Pick }
	local _, setVersion = React.useState(0)
	React.useEffect(function()
		return PickFaceTool.subscribe(function()
			setVersion(function(v: number)
				return v + 1
			end)
		end)
	end, {})
	return PickFaceTool.picks()
end


export type Props = {
	settings: Settings.State,
	-- From the Pick faces tool instead of the selected parts.
	picking: boolean,
}

local function CreatePage(props: Props)
	local settings = props.settings
	local picking = props.picking
	local picks = usePicks()
	local plan = if picking
		then Create.planPicks(settings.power, settings.tileSize, picks)
		else Create.plan(settings.power, settings.tileSize, settings.faces)
	-- Create refuses parts that would make too many tiles; say so before the click.
	local tooMany = plan.largestPart > Create.MAX_TILES_PER_PART

	local createText = if plan.faces == 0
		then "Create"
		elseif picking then `Create ({Format.plural(#picks, "face")})`
		elseif plan.tiles == 1 then "Create tile"
		else `Create area ({Format.plural(plan.tiles, "tile")})`

	local children: { [string]: unknown } = {
		Detail = Rows.property(
			6,
			"Detail",
			e(Dropdown, {
				Items = DETAIL_ITEMS,
				SelectedItem = tostring(settings.power),
				OnItemSelected = function(id: string?)
					local power = if id then tonumber(id) else nil
					if power then
						Settings.update(function(s)
							s.power = power
						end)
					end
				end,
			}),
			"**Grid density** per tile while editing.\n\n"
				.. "- **Low**: 64 wedges.\n"
				.. "- **Medium**: 256 wedges (rolling hills).\n"
				.. "- **High**: 1,024 wedges (sharp paths).\n\n"
				.. "> Hammer: Power 2, 3 or 4."
		),
		TileSize = Rows.property(
			7,
			"Tile size",
			e(StudioComponents.NumericInput, {
				Value = settings.tileSize,
				Min = Settings.TILE_SIZE_MIN,
				Max = Settings.TILE_SIZE_MAX,
				Step = 1,
				Arrows = true,
				OnValidChanged = function(value: number)
					Settings.update(function(s)
						s.tileSize = value
					end)
				end,
			}),
			"**Target tile width** in studs.\n\n"
				.. "Larger faces split into a seamless grid inside a `TerrainArea` model.\n\n"
				.. "> Example: 32 for general ground, or match a texture repeat."
		),
		CreateDivider = Rows.divider(8),
		Create = Rows.withTooltip(
			if picking
				then "**Replace picked faces** with terrain.\n\n"
					.. "Builds editable tiles in one step.\n\n"
					.. "> `Ctrl + Z` restores the original parts."
				else "**Replace chosen faces** with terrain.\n\n"
					.. "Builds editable tiles from selected parts.\n\n"
					.. "> `Ctrl + Z` restores the original parts.",
			e(StudioComponents.MainButton, {
				Size = UDim2.fromScale(1, 1),
				Text = createText,
				Icon = Icons.CreateArea,
				Disabled = plan.faces == 0 or tooMany,
				OnActivated = function()
					if picking then
						Create.createPicked(settings.power, settings.tileSize, picks, Settings.stopViewportTool)
					else
						Create.report(pcall(Create.fromSelection, settings.power, settings.tileSize, settings.faces))
					end
				end,
			}),
			11,
			UDim2.new(1, 0, 0, Rows.BUTTON_HEIGHT)
		),
	}

	if picking then
		children.Title = Rows.title(
			1,
			"Pick faces",
			nil,
			Settings.stopViewportTool,
			"**Stop picking** (`Esc`).\n\nClears any picked faces."
		)
		if #picks > 0 then
			-- The Picked row ends in a Clear button. Its tooltip is a sibling of the row's, not
			-- nested inside it, since nested tooltips would both show.
			children.Picked = e("Frame", {
				LayoutOrder = 3,
				Size = UDim2.new(1, 0, 0, CLEAR_SIZE),
				BackgroundTransparency = 1,
			}, {
				Value = e("Frame", {
					Size = UDim2.new(1, -(CLEAR_SIZE + 4), 1, 0),
					BackgroundTransparency = 1,
				}, {
					Row = Rows.value(
						1,
						"Picked",
						`{Format.plural(#picks, "face")} ({Format.plural(plan.parts, "part")})`,
						nil,
						"**Picked faces**, highlighted in 3D.\n\n"
							.. "> Click a picked face again to unpick it."
					),
				}),
				Clear = e("Frame", {
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.fromOffset(CLEAR_SIZE, CLEAR_SIZE),
					BackgroundTransparency = 1,
				}, {
					Tip = Rows.withTooltip(
						"**Clear** all picked faces.",
						e(StudioComponents.Button, {
							Size = UDim2.fromScale(1, 1),
							Icon = Icons.Clear,
							OnActivated = PickFaceTool.clear,
						})
					),
				}),
			})
		end
	else
		children.Selected = Rows.value(
			1,
			"Selected",
			Format.plural(#Query.selectedParts(), "part"),
			nil,
			"**Selected parts** that `Create` will convert.\n\n"
				.. "> Supports block and wedge parts."
		)
		children.Faces = Rows.property(
			3,
			"Faces",
			e(Dropdown, {
				Items = FACE_ITEMS,
				RowHeight = 20,
				SelectedItem = settings.faces,
				OnItemSelected = function(id: string?)
					Settings.update(function(s)
						-- Literal assignments keep the FaceMode type exact.
						if id == "Top" then
							s.faces = "Top"
						elseif id == "TopSides" then
							s.faces = "TopSides"
						elseif id == "All" then
							s.faces = "All"
						end
					end)
				end,
			}),
			"**Which part faces** to turn into terrain.\n\n"
				.. "- **Top**: most upward face (floors).\n"
				.. "- **Top + sides**: skips the bottom (cliffs).\n"
				.. "- **All faces**: every face.\n\n"
				.. "> Wedges have 3 faces: bottom, back and slope."
		)
	end

	-- What Create will make, right above the button.
	if plan.faces > 0 then
		children.Result = Rows.value(
			9,
			"Result",
			`{Format.plural(plan.tiles, "tile")}, {Format.count(plan.wedges)} wedges`,
			nil,
			"**Preview** of tiles and wedges to build.\n\n"
				.. "> With `Bake automatically` on, each tile becomes 1 union."
		)
	elseif not picking then
		children.Result = Rows.paragraph(9, "The selected faces are under 0.5 studs and cannot be converted.", "dimmed")
	end

	if tooMany then
		children.Warning = Rows.value(
			10,
			"Warning",
			`Over {Create.MAX_TILES_PER_PART} tiles`,
			"warning",
			`**Too many tiles** on one part ({Format.count(plan.largestPart)}).\n\n`
				.. `Limit is {Create.MAX_TILES_PER_PART} per part so Studio does not freeze.\n\n`
				.. "> Raise `Tile size` or choose fewer `Faces`."
		)
	elseif plan.thinFaces > 0 then
		children.Warning = Rows.value(
			10,
			"Warning",
			Format.plural(plan.thinFaces, "thin face"),
			"warning",
			"**Thin faces** make costly narrow strips.\n\n"
				.. `Faces under {PartFaces.THIN_FACE_SIZE} studs cost as many wedges as a full tile.\n\n`
				.. "> Set `Faces` to `Top` if you only meant the top."
		)
	end

	return Rows.page(children)
end

return CreatePage
