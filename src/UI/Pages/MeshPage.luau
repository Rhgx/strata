--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Options page for the active Mesh tool: Simplify mode (mark points, preview triangle count,
	apply or clear) and Cut holes mode. The staged commit block appears only while points are
	marked.
]]

local UI = script.Parent.Parent
local Plugin = UI.Parent
local State = Plugin.State
local Scene = Plugin.Scene
local Packages = Plugin.Parent.Packages

local React = require(Packages.React)
local StudioComponents = require(Packages.StudioComponents)

local Format = require(State.Format)
local Status = require(State.Status)
local Settings = require(State.Settings)

local Query = require(Scene.Query)
local Session = require(Scene.Session)
local MeshStage = require(Scene.MeshStage)

local MeshActions = require(Plugin.Actions.Mesh)

local RadiusPreview = require(Plugin.Viewport.RadiusPreview)

local Rows = require(UI.Rows)
local Icons = require(UI.Icons)

local e = React.createElement

local MODES: { Rows.Tab<Settings.MeshMode> } = {
	{
		id = "Simplify",
		label = "Simplify",
		icon = Icons.SimplifyMode,
		tip = "**Fewer triangles where you want them**: mark points, check the preview, then `Apply`.\n\n"
			.. "The area around removed points fills in with larger triangles.\n\n"
			.. "> Hold `Ctrl` to mark removed points to come back. Corners always stay.",
	},
	{
		id = "Holes",
		label = "Cut holes",
		icon = Icons.CutMode,
		tip = "**Delete triangles** from tiles, for paths and openings.\n\n"
			.. "Holes are outlined while you hover a tile.\n\n"
			.. "> Hold `Ctrl` to restore them. Turn on `Fine` for single triangles.",
	},
}

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
	local hasTiles = #Session.models() > 0

	-- Re-render when staged marks change from viewport interactions.
	local _, setStageVersion = React.useState(MeshStage.version())
	local busy, setBusy = React.useState(false)
	-- Guard async Select flat completion in case the page unmounts while yielding.
	local mounted = React.useRef(true)

	React.useEffect(function ()
		return MeshStage.subscribe(function ()
			setStageVersion(MeshStage.version())
		end)
	end, {})

	React.useEffect(function ()
		mounted.current = true

		return function ()
			mounted.current = false
		end
	end, {})

	local marked = not MeshStage.isEmpty()

	local children: { [string]: unknown } = {
		Mode = Rows.segmented(1, MODES, settings.meshMode, function (mode: Settings.MeshMode)
			Settings.update(function (s)
				s.meshMode = mode
			end)
		end),

		Radius = Rows.property(
			5,
			"Radius",
			e(StudioComponents.NumericInput, {
				Value = settings.radius,
				Min = Settings.RADIUS_MIN,
				Max = Settings.RADIUS_MAX,
				Step = 0.5,
				Slider = true,

				OnValidChanged = function (value: number)
					Settings.update(function (s)
						s.radius = value
					end)
					RadiusPreview.pulse()
				end,
			}),
			"**Brush size** in studs.\n\n"
				.. (if holes
					then "The triangle under the cursor is always included."
					else "Drag to mark points; a click without dragging marks just the nearest point.")
				.. "\n\n> Resize in 3D: `Ctrl + Scroll` or `[` and `]`."
		),

		Fine = if holes
			then Rows.checkbox(
				6,
				"Fine (triangles)",
				settings.paintFine,
				function ()
					Settings.update(function (s)
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
			function ()
				Settings.update(function (s)
					s.paintSelectedOnly = not s.paintSelectedOnly
				end)
			end,
			"**Limit the brush** to selected tiles."
		),
	}

	if not holes then
		-- Select flat and Restore all target selected tiles, or all tiles when nothing is selected.
		local scopeText = if selected > 0
			then `the {Format.plural(selected, "selected tile")}`
			elseif settings.paintSelectedOnly then "the selected tiles"
			else "every tile"
		local noScope = not hasTiles or (selected == 0 and settings.paintSelectedOnly)

		children.Auto = Rows.collapsible(10, "auto-simplify", "Auto-simplify", nil, {
				Angle = Rows.property(
					1,
					"Max angle",
					e(StudioComponents.NumericInput, {
						Value = settings.simplifyAngle,
						Min = Settings.SIMPLIFY_ANGLE_MIN,
						Max = Settings.SIMPLIFY_ANGLE_MAX,
						Step = 1,
						Slider = true,

						OnValidChanged = function (value: number)
							Settings.update(function (s)
								s.simplifyAngle = value
							end)
						end,
					}),
					"**How far the surface may bend**, in degrees, where points go.\n\n"
						.. "- **0**: perfectly flat ground only.\n"
						.. "- **5 to 15**: gentle slopes simplify too.\n\n"
						.. "> Painted borders and hole outlines keep their points."
				),

				Buttons = Rows.grid(2, 2, {
					Flat = Rows.withTooltip(
						`**Mark flat points** on {scopeText} within \`Max angle\`.\n\nCheck the preview, then \`Apply\`.`,
						e(StudioComponents.Button, {
							Size = UDim2.fromScale(1, 1),
							Text = if busy then "Working..." else "Select flat",
							Icon = Icons.Select,
							Disabled = noScope or busy,

							OnActivated = function ()
								-- Spawn because selectFlat yields periodically between candidate batches.
								setBusy(true)

								task.spawn(function ()
									run(function ()
										local tiles, points, stopped = MeshActions.selectFlat(settings.simplifyAngle)

										if not mounted.current or stopped then
											return
										elseif points == 0 then
											Status.post("warning", "No points are flat enough within that angle.")
										else
											Status.post(
												"success",
												`Marked {Format.plural(points, "point")} on {Format.plural(tiles, "tile")}. Apply to keep them.`
											)
										end
									end)

									if mounted.current then
										setBusy(false)
									end
								end)
							end,
						}),
						1
					),

					Restore = Rows.withTooltip(
						`**Mark every removed point** on {scopeText} to come back.\n\nCheck the preview, then \`Apply\`.`,
						e(StudioComponents.Button, {
							Size = UDim2.fromScale(1, 1),
							Text = "Restore all",
							Icon = Icons.Unsimplify,
							Disabled = noScope,

							OnActivated = function ()
								if MeshActions.markRestoreAll() == 0 then
									Status.post("warning", "No removed points to restore.")
								end
							end,
						}),
						2
					),
				}),
			}
		)

		-- Placed below Auto-simplify so Select flat does not shift under the pointer when marks appear.
		if marked then
			local before, after = MeshStage.counts()

			children.PendingDivider = Rows.divider(12)

			children.Result = Rows.value(
				13,
				"Result",
				`{Format.count(before)} to {Format.count(after)} tris`,
				nil,
				"**Triangles now and after Apply**, over every tile with marked points.\n\n"
					.. "The orange lines in 3D are the edges those tiles would gain."
			)

			children.Commit = Rows.grid(14, 2, {
				Apply = Rows.withTooltip(
					"**Apply the marked points** as one undo step.\n\n> Also `Enter` or `X` in 3D.",
					e(StudioComponents.MainButton, {
						Size = UDim2.fromScale(1, 1),
						Text = "Apply",
						Icon = Icons.ApplyMarks,

						OnActivated = function ()
							run(function ()
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
						Icon = Icons.Clear,
						OnActivated = MeshStage.clear,
					}),
					2
				),
			})
		end
	end

	-- Warn explicitly when dragging would have no targets instead of doing nothing silently.
	if not hasTiles then
		children.Warning = Rows.paragraph(3, "No terrain yet. Select parts or use Pick faces.", "warning")
	elseif settings.paintSelectedOnly and selected == 0 then
		children.Warning = Rows.paragraph(3, "No tiles selected. Select tiles or turn off Selected only.", "warning")
	end

	return Rows.tool(
		"Mesh",
		Settings.stopViewportTool,
		"**Stop the Mesh tool** (`Esc`).\n\n"
			.. "Marked points that were not applied are dropped. Bakes edited tiles if `Bake automatically` is on.",
		children
	)
end

return MeshPage
