--!strict
--[[
	A pool of line adornments drawn in world space (on top of everything), for previews: stitch
	targets, the Mesh tool's triangle wireframe and hole outlines. Lines are reused between
	frames; `clear` hides them all, `line` shows the next one.
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
		-- The Terrain adornee sits at the origin, so this CFrame is world space.
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
