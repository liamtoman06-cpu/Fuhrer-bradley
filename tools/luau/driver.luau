-- appended by make_harness.py: runs the clips of SCEN and prints JSON frames
-- glTF space: X = his left, +Z = forward. Root space: X = his right, -Z = forward.
local R180 = CFrame.Angles(0, math.pi, 0)
DESC.holder = R180:Inverse() * CFrame.new(-HIPS.X, -HIPS.Y, -HIPS.Z)

local function num(x)
	if x ~= x then return "0" end
	return string.format("%.5f", x)
end

Animator.ACTIONS.PoseTest = {
	eval = function(A, rec, t, w)
		A:pose(rec.cfg.pose, w)
	end,
}

local fps = SCEN.fps or 30
local dt = 1 / fps
local out = {}
table.insert(out, '{"clips":[')
for ci, clip in SCEN.clips do
	local A = Animator.new(DESC, Poses, Config)
	local U = A.U
	local frames = {}
	local actionCfg = clip.action and Config.Actions[clip.action] or nil
	local speedMul = clip.actionSpeed or 1
	local dur = clip.seconds or (actionCfg and (actionCfg.Duration / speedMul + 0.4)) or 2
	local warm = clip.warm or 1.0
	local total = warm + dur
	local n = math.floor(total * fps + 0.5)
	local pos = Vector3.new(0, 0, 0)
	local yaw = 0
	local rec = nil
	for f = 0, n do
		local time = f * dt
		local tt = time - warm
		local speed = clip.speed or 0
		local vel = Vector3.new(0, 0, -speed * U)
		-- scripted root motion (dashes / leaps): clip.path = { {t, dz, dy}, ... } in studs (relative)
		local vr
		if clip.path and tt >= 0 then
			local p = clip.path
			local z, y = 0, 0
			for k = 1, #p - 1 do
				local a, b = p[k], p[k + 1]
				if tt >= a[1] and tt <= b[1] then
					local u = (tt - a[1]) / math.max(b[1] - a[1], 1e-4)
					u = 1 - (1 - u) ^ 2
					z = a[2] + (b[2] - a[2]) * u
					y = (a[3] or 0) + ((b[3] or 0) - (a[3] or 0)) * u + 4 * (b[4] or 0) * u * (1 - u)
				elseif tt > b[1] then
					z, y = b[2], b[3] or 0
				end
			end
			local newPos = Vector3.new(0, y * U, -z * U)
			vel = (newPos - pos) / dt
			pos = newPos
		else
			pos += vel * dt
		end
		vr = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
		local actions = {}
		if (clip.action or clip.pose) and tt >= 0 then
			if not rec then
				rec = { name = clip.action or "PoseTest", cfg = actionCfg or { pose = clip.pose, Duration = 99 }, data = {}, suppress = 1 }
			end
			rec.real = tt
			rec.t = tt * speedMul
			local D = (rec.cfg.Duration or 2) / speedMul
			local fin, fout = 0.15, 0.35
			local w = math.clamp(tt / fin, 0, 1)
			w = w * w * (3 - 2 * w)
			if not clip.pose and clip.action ~= "Death" and tt > D then
				local k = math.clamp((tt - D) / fout, 0, 1)
				w *= 1 - k * k * (3 - 2 * k)
			end
			rec.w = w
			rec.rootTarget = Vector3.new(0, 0, -12 * U)
			table.insert(actions, rec)
		end
		local res = A:step({
			dt = dt, clock = time, vel = vel, yawRate = 0, vr = vr, corr = nil, actions = actions,
			state = { combat = clip.combat ~= false, enraged = clip.enraged == true, capeOff = clip.capeOff == true, dead = clip.action == "Death" },
			look = nil, gravity = 196.2,
		})
		if tt >= -0.001 and (f % (clip.every or 1) == 0) then
			local parts = {}
			for name, T in res do
				local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = T:GetComponents()
				table.insert(parts, '"' .. name .. '":[' .. table.concat({ num(x), num(y), num(z), num(r00), num(r01), num(r02), num(r10), num(r11), num(r12), num(r20), num(r21), num(r22) }, ",") .. "]")
			end
			local vx, vy, vz = vr:GetComponents()
			table.insert(frames, '{"t":' .. num(tt) .. ',"root":[' .. num(vx) .. "," .. num(vy) .. "," .. num(vz) .. "]," .. '"bones":{' .. table.concat(parts, ",") .. "}}")
		end
	end
	table.insert(out, (if ci > 1 then "," else "") .. '{"name":"' .. clip.name .. '","frames":[' .. table.concat(frames, ",") .. "]}")
end
table.insert(out, "]}")
print(table.concat(out))
