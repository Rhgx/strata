--!strict
--[[
	Raycast helper that skips invisible BaseParts (triggers and hitboxes with Transparency >= 0.99)
	up to MAX_SKIPS layers deep. Shared by click tools: Material pipette, Sample, Stitch, Pick
	faces, and Raise To height sampling.
]]

local RAY_LENGTH = 10000
-- Maximum transparent parts to pierce before stopping.
local MAX_SKIPS = 8

local VisibleHit = {}

-- Casts unit-direction `ray` (such as PluginMouse.UnitRay), excluding `exclude` and its
-- descendants. Returns the first visible RaycastResult, or nil.
function VisibleHit.cast(ray: Ray, exclude: { Instance }?): RaycastResult?
	local skipped: { Instance } = if exclude then table.clone(exclude) else {}

	for _ = 1, MAX_SKIPS do
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = skipped

		local hit = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)

		if not hit then
			return nil
		end

		local part = hit.Instance

		if part:IsA("BasePart") and part.Transparency >= 0.99 then
			table.insert(skipped, part)
			continue
		end

		return hit
	end

	return nil
end

return VisibleHit
