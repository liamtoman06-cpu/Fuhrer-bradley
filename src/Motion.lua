--[[
	King Bradley boss - scripted root motion (ModuleScript "Motion", shared by BossServer and BossClient).

	Dashes and leaps are far too fast for Humanoid walking, so the server moves the root along a path
	(anchored, one CFrame per Heartbeat) and publishes the path as the model attribute ActionPath.
	Every client samples the same path at the same server time and draws the body exactly there, so
	a 0.2 s dash looks smooth on every screen whatever the network does.

	A path is a list of keys { t, pos, yaw, ease, arc }:
	  t     seconds after ActionStart (increasing)
	  pos   HumanoidRootPart position at t
	  yaw   facing at t (radians, Roblox convention: LookVector = (-sin yaw, 0, -cos yaw))
	  ease  how the segment that ENDS at this key is travelled: "l" linear, "o" ease out (dash),
	        "i" ease in, "s" smooth, "h" hold (stays at the previous key until t)
	  arc   height of a parabolic hop added over the segment (0 = none)
]]

local Motion = {}

export type Key = { t: number, pos: Vector3, yaw: number, ease: string, arc: number }

local function ease(kind: string, u: number): number
	if kind == "o" then
		return 1 - (1 - u) ^ 3
	elseif kind == "i" then
		return u * u
	elseif kind == "s" then
		return u * u * (3 - 2 * u)
	elseif kind == "h" then
		return if u >= 1 then 1 else 0
	end
	return u
end

local function lerpAngle(a: number, b: number, u: number): number
	local d = math.atan2(math.sin(b - a), math.cos(b - a))
	return a + d * u
end

function Motion.key(t: number, pos: Vector3, yaw: number, easeKind: string?, arc: number?): Key
	return { t = t, pos = pos, yaw = yaw, ease = easeKind or "l", arc = arc or 0 }
end

function Motion.encode(path: { Key }): string
	local parts = table.create(#path)
	for i, k in path do
		parts[i] = string.format("%.3f,%.3f,%.3f,%.3f,%.4f,%s,%.2f", k.t, k.pos.X, k.pos.Y, k.pos.Z, k.yaw, k.ease, k.arc)
	end
	return table.concat(parts, ";")
end

function Motion.decode(s: string?): { Key }?
	if type(s) ~= "string" or s == "" then
		return nil
	end
	local path = {}
	for chunk in string.gmatch(s, "[^;]+") do
		local t, x, y, z, yaw, e, arc = string.match(chunk, "^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),(%a),([^,]+)$")
		if not t then
			return nil
		end
		table.insert(path, {
			t = tonumber(t) :: number,
			pos = Vector3.new(tonumber(x) :: number, tonumber(y) :: number, tonumber(z) :: number),
			yaw = tonumber(yaw) :: number,
			ease = e,
			arc = tonumber(arc) :: number,
		})
	end
	return if #path >= 1 then path else nil
end

-- Position and yaw at time t. Before the first key it holds the first, after the last the last.
function Motion.sample(path: { Key }, t: number): (Vector3, number)
	local n = #path
	if t <= path[1].t or n == 1 then
		return path[1].pos, path[1].yaw
	end
	if t >= path[n].t then
		return path[n].pos, path[n].yaw
	end
	local i = 2
	while path[i].t < t do
		i += 1
	end
	local a, b = path[i - 1], path[i]
	local span = math.max(b.t - a.t, 1e-4)
	local raw = math.clamp((t - a.t) / span, 0, 1)
	local u = ease(b.ease, raw)
	local pos = a.pos:Lerp(b.pos, u)
	if b.arc ~= 0 then
		pos += Vector3.new(0, 4 * b.arc * raw * (1 - raw), 0)
	end
	-- turns are quick: the facing reaches the new heading in the first third of the segment
	local yu = if b.ease == "h" then u else math.clamp(raw * 3, 0, 1)
	return pos, lerpAngle(a.yaw, b.yaw, yu)
end

function Motion.cframe(path: { Key }, t: number): CFrame
	local pos, yaw = Motion.sample(path, t)
	return CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

function Motion.endTime(path: { Key }): number
	return path[#path].t
end

-- Yaw whose LookVector points along the flat part of dir (nil for a vertical/zero vector).
function Motion.yawOf(dir: Vector3): number?
	if dir.X * dir.X + dir.Z * dir.Z < 1e-6 then
		return nil
	end
	return math.atan2(-dir.X, -dir.Z)
end

return Motion
