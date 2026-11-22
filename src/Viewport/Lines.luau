--!strict
--[[
	Reusable pool of always-on-top world-space BoxHandleAdornment line segments for viewport
	previews (stitch guides, Mesh wireframes, brush outlines, and hole outlines). Call `clear`
	to hide active segments and `line` to allocate the next segment from the pool.
]]

local CoreGui = game:GetService("CoreGui")

export type Pool = {
	line: (from: Vector3, to: Vector3, color: Color3, thickness: number, transparency: number) -> (),
	clear: () -> (),
	destroy: () -> (),
}

local Lines = {}

function Lines.new(name: string, limit: number): Pool
	local adornments: { BoxHandleAdornment } = {}
	local used = 0

	local function line(from: Vector3, to: Vector3, color: Color3, thickness: number, transparency: number)
		local length = (to - from).Magnitude

		if length < 1e-3 or used >= limit then
			return
		end

		used += 1

		if not adornments[used] then
			local created = Instance.new("BoxHandleAdornment")
			created.Name = name
			created.Adornee = workspace.Terrain
			created.AlwaysOnTop = true
			created.ZIndex = 2
			created.Parent = CoreGui
			adornments[used] = created
		end

		local adornment = adornments[used]
		-- Terrain is anchored at the world origin, so CFrame is directly in world space.
		adornment.CFrame = CFrame.lookAt((from + to) / 2, to)
		adornment.Size = Vector3.new(thickness, thickness, length)
		adornment.Color3 = color
		adornment.Transparency = transparency
		adornment.Visible = true
	end

	local function clear()
		for i = 1, used do
			adornments[i].Visible = false
		end

		used = 0
	end

	local function destroy()
		for _, adornment in adornments do
			adornment:Destroy()
		end

		table.clear(adornments)
		used = 0
	end

	return { line = line, clear = clear, destroy = destroy }
end

return Lines
