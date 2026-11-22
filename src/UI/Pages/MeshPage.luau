--!strict
-- Options of the running Mesh tool: Simplify (mark points, preview, apply) or Cut holes.
local Packages = script.Parent.Parent.Parent.Parent.Packages
local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Settings = require(script.Parent.Parent.Parent.State.Settings)
local RadiusPreview = require(script.Parent.Parent.Parent.Viewport.RadiusPreview)
local Status = require(script.Parent.Parent.Parent.State.Status)
local Session = require(script.Parent.Parent.Parent.Scene.Session)
local Query = require(script.Parent.Parent.Parent.Scene.Query)
local MeshStage = require(script.Parent.Parent.Parent.Scene.MeshStage)
local MeshActions = require(script.Parent.Parent.Parent.Actions.Mesh)
local Format = require(script.Parent.Parent.Format)
local Icons = require(script.Parent.Parent.Icons)
local Rows = require(script.Parent.Parent.Rows)

local e = React.createElement

-- Simplify or Cut holes, as two buttons so the mode is always visible.
local function modeRow(layoutOrder: number, settings: Settings.State)
	local function button(order: number, text: string, icon: Icons.Icon, mode: Settings.MeshMode, tooltip: string)
		return Rows.withTooltip(
			tooltip,
			e(StudioComponents.Button, {
				Size = UDim2.fromScale(1, 1),
				Text = text,
				Icon = icon,
				Selected = settings.meshMode == mode,
				OnActivated = function()
					Settings.update(function(s)
						s.meshMode = mode
					end)
				end,
			}),
			order
		)
	end
	return Rows.grid(layoutOrder, 2, {
		Simplify = button(
			1,
			"Simplify",
			Icons.SimplifyMode,
			"Simplify",
			"**Fewer triangles where you want them**: mark points, check the preview, then `Apply`.\n\n"
				.. "The area around removed points fills in with larger triangles.\n\n"
				.. "> Hold `Ctrl` to mark removed points to come back. Corners always stay."
		),
		Holes = button(
			2,
			"Cut holes",
			Icons.CutMode,
			"Holes",
			"**Delete triangles** from tiles, for paths and openings.\n\n"
				.. "Holes are outlined while you hover a tile.\n\n"
				.. "> Hold `Ctrl` to restore them. Turn on `Fine` for single triangles."
		),
	})
end

local function run(action: () -> ())
	local ok, err: unknown = pcall(action)
	if not ok then
		Status.post("error", tostring(err))
	end
end

local function MeshPage(props: { settings: Settings.State })
	local settings = props.settings
	local holes = settings.meshMode == "Holes"
	local selected = #Query.selectedModels()

	-- Re-render when points are marked or cleared in the 3D view.
	local _, setStageVersion = React.useState(MeshStage.version())
	React.useEffect(function()
		return MeshStage.subscribe(function()
			setStageVersion(MeshStage.version())
		end)
	end, {})
	local marked = not MeshStage.isEmpty()
	local busy, setBusy = React.useState(false)

	local children: { [string]: unknown } = {
		Title = Rows.title(1, "Mesh"),
		Mode = modeRow(2, settings),
		Hint = Rows.paragraph(
			4,
			if holes
				then "Drag to delete triangles. Hold Ctrl to restore them."
				else "Drag to mark points, Ctrl to mark removed ones back. Click toggles one point.",
			"dimmed"
		),
		Radius = Rows.property(
			5,
			"Radius",
			e(StudioComponents.NumericInput, {
				Value = settings.radius,
				Min = Settings.RADIUS_MIN,
				Max = Settings.RADIUS_MAX,
				Step = 0.5,
				Slider = true,
				OnValidChanged = function(value: number)
					Settings.update(function(s)
						s.radius = value
					end)
					RadiusPreview.pulse()
				end,
			}),
			"**Brush size** in studs.\n\n"
				.. (if holes then "The triangle under the cursor is always included." else "A click without dragging marks just the nearest point.")
				.. "\n\n> Resize in 3D: `Ctrl + Scroll` or `[` and `]`."
		),
		Fine = if holes
			then Rows.checkbox(
				6,
				"Fine (triangles)",
				settings.paintFine,
				function()
					Settings.update(function(s)
						s.paintFine = not s.paintFine
					end)
				end,
				"**Cut single triangles** instead of whole grid cells."
			)
			else nil,
		SelectedOnly = Rows.checkbox(
			7,
			"Selected only",
			settings.paintSelectedOnly,
			function()
				Settings.update(function(s)
					s.paintSelectedOnly = not s.paintSelectedOnly
				end)
			end,
			"**Limit the brush** to selected tiles.\n\nWhen off, works on any terrain under the cursor."
		),
	}

	if not holes then
		local before, after = MeshStage.counts()
		children.Result = Rows.value(
			8,
			"Result",
			if marked then `{Format.count(before)} to {Format.count(after)} triangles` else "No points marked",
			if marked then nil else "dimmed",
			"**Triangles now and after Apply**, over every tile with marked points.\n\n"
				.. "The orange lines in 3D are the edges those tiles would gain."
		)
		children.Commit = Rows.grid(9, 2, {
			Apply = Rows.withTooltip(
				"**Apply the marked points** as one undo step.\n\n> Also `Enter` or `X` in 3D.",
				e(StudioComponents.Button, {
					Size = UDim2.fromScale(1, 1),
					Text = "Apply",
					Icon = Icons.ApplyMarks,
					Disabled = not marked,
					OnActivated = function()
						run(function()
							local tiles, points = MeshActions.applyMarks()
							if points > 0 then
								Status.post("success", `Changed {Format.plural(points, "point")} on {Format.plural(tiles, "tile")}.`)
							end
						end)
					end,
				}),
				1
			),
			Clear = Rows.withTooltip(
				"**Drop the marks** without changing anything.\n\n> Also `Esc` in 3D.",
				e(StudioComponents.Button, {
					Size = UDim2.fromScale(1, 1),
					Text = "Clear",
					Icon = Icons.ClearMarks,
					Disabled = not marked,
					OnActivated = MeshStage.clear,
				}),
				2
			),
		})
		children.AutoHeading = Rows.section(10, "Auto-simplify")
		children.AutoNote = Rows.paragraph(
			11,
			if selected > 0
				then `Marks the points of {Format.plural(selected, "selected tile")} that sit on flat enough ground.`
				else "Select tiles to mark the points that sit on flat enough ground.",
			"dimmed"
		)
		children.Angle = Rows.property(
			12,
			"Max angle",
			e(StudioComponents.NumericInput, {
				Value = settings.simplifyAngle,
				Min = Settings.SIMPLIFY_ANGLE_MIN,
				Max = Settings.SIMPLIFY_ANGLE_MAX,
				Step = 1,
				Slider = true,
				OnValidChanged = function(value: number)
					Settings.update(function(s)
						s.simplifyAngle = value
					end)
				end,
			}),
			"**How far the surface may bend**, in degrees, where points go.\n\n"
				.. "- **0**: perfectly flat ground only.\n"
				.. "- **5 to 15**: gentle slopes simplify too.\n\n"
				.. "> Painted borders and hole outlines keep their points."
		)
		children.Auto = Rows.grid(13, 2, {
			Flat = Rows.withTooltip(
				"**Mark flat points** on the selected tiles within `Max angle`.\n\nCheck the preview, then `Apply`.",
				e(StudioComponents.Button, {
					Size = UDim2.fromScale(1, 1),
					Text = if busy then "Working..." else "Select flat",
					Icon = Icons.AutoSimplify,
					Disabled = selected == 0 or busy,
					OnActivated = function()
						-- Marking yields between batches, so it runs outside the click handler.
						setBusy(true)
						task.spawn(function()
							run(function()
								local tiles, points = MeshActions.selectFlat(settings.simplifyAngle)
								if points == 0 then
									Status.post("warning", "No points are flat enough within that angle.")
								else
									Status.post("success", `Marked {Format.plural(points, "point")} on {Format.plural(tiles, "tile")}. Apply to keep them.`)
								end
							end)
							setBusy(false)
						end)
					end,
				}),
				1
			),
			Restore = Rows.withTooltip(
				"**Mark every removed point** of the selected tiles to come back.\n\nCheck the preview, then `Apply`.",
				e(StudioComponents.Button, {
					Size = UDim2.fromScale(1, 1),
					Text = "Restore all",
					Icon = Icons.RestorePoints,
					Disabled = selected == 0,
					OnActivated = function()
						if MeshActions.markRestoreAll() == 0 then
							Status.post("warning", "The selected tiles have no removed points.")
						end
					end,
				}),
				2
			),
		})
	end

	children.StopDivider = Rows.divider(14)
	children.Stop = Rows.button(
		15,
		"Stop",
		Settings.stopViewportTool,
		"**Stop the Mesh tool** and return to Studio.\n\n"
			.. "Marked points that were not applied are dropped. Bakes edited tiles if `Bake automatically` is on.\n\n"
			.. "> Shortcut: `Esc`.",
		nil,
		Icons.StopTool
	)

	-- Say so when a drag would do nothing, instead of failing silently.
	if #Session.models() == 0 then
		children.Warning = Rows.paragraph(3, "No terrain yet. Select parts or use Pick faces.", "warning")
	elseif settings.paintSelectedOnly and selected == 0 then
		children.Warning = Rows.paragraph(3, "No tiles selected. Select tiles or turn off Selected only.", "warning")
	end

	return Rows.page(children)
end

return MeshPage