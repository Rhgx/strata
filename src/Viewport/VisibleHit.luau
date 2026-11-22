--!strict
--[[
	The first visible thing along a ray, looking through invisible parts (triggers and hitboxes,
	Transparency 0.99 or more) up to a few deep. Shared by the tools that click parts: the
	Material pipette, Sample, Stitch, Pick faces and Raise To's height pick.
]]

local RAY_LENGTH = 10000
-- How many invisible parts a ray looks through before giving up.
local MAX_SKIPS = 8

local VisibleHit = {}

-- Casts `ray` (its direction a unit vector, like PluginMouse.UnitRay), ignoring `exclude` and
-- their descendants. Returns nil when nothing visible is hit.
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
