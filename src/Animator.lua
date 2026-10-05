--!nonstrict
--[[
	King Bradley boss - Animator (ModuleScript "Animator", used by BossClient).

	Pure math: it never touches the DataModel, so the very same file runs under the Luau CLI for the
	offline previews and tests in tools/luau. BossClient feeds it one frame of inputs and writes the
	returned Transform of every bone to Bone.Transform.

	Spaces
	  * "root space" is the HumanoidRootPart frame: X = his right, Y = up, -Z = where he faces.
	    Every pose, offset and IK target is written in root space (studs * U).
	  * each bone's rest frame is measured once (desc.bones[i].rest, the Bone.CFrame), so the rig can
	    come in from the importer in any orientation: authored rotations are converted per bone.
	  * U = the rig's height / 9: one unit is one stud on a 9-stud-tall Bradley, whatever the scale.

	Layers, every frame
	  1. stance (guard / at ease) + gait (walk / run cycle with planted feet, heel-toe roll)
	  2. actions (keyframed poses with per-body-part lag, procedural accents) blended by weight
	  3. look-at, breathing, hit flinch, tremble
	  4. leg IK (feet on their targets), arm IK (reaches), foot and toe orientation
	  5. secondary motion: cape cloth (Verlet + body collisions), scabbard pendulums, eyepatch follow
]]

local Animator = {}
Animator.__index = Animator

local noise = math.noise
local TAU = math.pi * 2
local RAD = math.pi / 180
local V0 = Vector3.zero
local I = CFrame.identity
local UP = Vector3.new(0, 1, 0)

-- =============================================================================================
-- Math
-- =============================================================================================
local function clamp01(x)
	return if x < 0 then 0 elseif x > 1 then 1 else x
end
local function lerp(a, b, t)
	return a + (b - a) * t
end
local function progress(a, b, x)
	if b <= a then
		return if x >= b then 1 else 0
	end
	return clamp01((x - a) / (b - a))
end
local function smooth(t)
	t = clamp01(t)
	return t * t * (3 - 2 * t)
end
local function smoother(t)
	t = clamp01(t)
	return t * t * t * (t * (t * 6 - 15) + 10)
end
local function easeOut(t, p)
	return 1 - (1 - clamp01(t)) ^ (p or 3)
end
local function easeIn(t, p)
	return clamp01(t) ^ (p or 3)
end
-- ease out with a small overshoot (strikes land, overshoot, settle)
local function easeOutBack(t, k)
	t = clamp01(t)
	k = k or 1.4
	local u = t - 1
	return 1 + (k + 1) * u * u * u + k * u * u
end
local function envelope(t, a, b, c, d)
	return smooth(progress(a, b, t)) * (1 - smooth(progress(c, d, t)))
end
local function approach(cur, target, rate, dt)
	return target + (cur - target) * math.exp(-rate * dt)
end
local function nz(t, seed)
	return math.clamp(noise(t, seed, 0.37) * 2, -1, 1)
end
local function blendCF(a, b, t)
	if t <= 0 then
		return a
	elseif t >= 1 then
		return b
	end
	return a:Lerp(b, t)
end
local function frameFrom(x, y)
	x = x.Unit
	local z = x:Cross(y)
	if z.Magnitude < 1e-5 then
		z = x:Cross(if math.abs(x.Y) < 0.9 then UP else Vector3.new(1, 0, 0))
	end
	z = z.Unit
	y = z:Cross(x)
	return CFrame.fromMatrix(V0, x, y, z)
end
local function rotOnly(cf)
	return cf.Rotation
end

Animator.math = {
	clamp01 = clamp01, lerp = lerp, progress = progress, smooth = smooth, smoother = smoother, easeOut = easeOut,
	easeIn = easeIn, envelope = envelope, approach = approach, noise = nz,
}

-- =============================================================================================
-- Rig
-- =============================================================================================
--[[
	desc = {
		bones = { { name = "B_Hips", parent = nil | "B_x", rest = CFrame }, ... }  -- rest = Bone.CFrame
		holder = CFrame  -- root space CFrame of the part the top-level bones hang from
	}
]]
function Animator.new(desc, poses, config)
	local self = setmetatable({}, Animator)
	self.poses = poses or {}
	self.config = config or {}
	self.bones = {}
	self.list = {}
	local byName = {}
	for _, b in desc.bones do
		byName[b.name] = b
	end
	local function add(b)
		if self.bones[b.name] then
			return self.bones[b.name]
		end
		local parent = nil
		if b.parent and byName[b.parent] then
			parent = add(byName[b.parent])
		end
		local rec = {
			name = b.name,
			parent = parent,
			C0 = b.rest,
			C0inv = b.rest:Inverse(),
			restRel = (if parent then parent.restRel else desc.holder) * b.rest,
			rel = nil,
			T = I,
			rot = V0,
			pos = V0,
		}
		rec.rel = rec.restRel
		-- conversion between root-space axes and the bone's own axes
		rec.M = rec.restRel.Rotation:Inverse()
		rec.Minv = rec.restRel.Rotation
		self.bones[b.name] = rec
		table.insert(self.list, rec)
		return rec
	end
	for _, b in desc.bones do
		add(b)
	end
	self.holder = desc.holder
	local B = self.bones

	-- size: one unit = one stud on a 9-stud Bradley
	local top, bottom = -math.huge, math.huge
	for _, rec in self.list do
		top = math.max(top, rec.restRel.Position.Y)
		bottom = math.min(bottom, rec.restRel.Position.Y)
	end
	local headH = if B.B_Head then B.B_Head.restRel.Position.Y else top
	local toeH = if B.B_ToeR then B.B_ToeR.restRel.Position.Y else bottom
	-- head bone ~ 86% of full height, toe joint ~ 1.6%
	self.U = math.max((headH - toeH) / (9 * 0.845), 1e-3)
	self.groundY = toeH - 0.15 * self.U

	-- chains
	self.legs = {}
	self.arms = {}
	for _, s in { { "R", 1 }, { "L", -1 } } do
		local n, side = s[1], s[2]
		local th, sh, ft, toe = B["B_Thigh" .. n], B["B_Shin" .. n], B["B_Foot" .. n], B["B_Toe" .. n]
		if th and sh and ft then
			self.legs[side] = { side = side, upper = th, lower = sh, finish = ft, toe = toe, restAnkle = ft.restRel.Position, bend = Vector3.new(0, 0, 1) }
		end
		local cl, ua, fa, ha, sb = B["B_Clavicle" .. n], B["B_UpperArm" .. n], B["B_Forearm" .. n], B["B_Hand" .. n], B["B_Saber" .. n]
		if ua and fa and ha then
			self.arms[side] = { side = side, clav = cl, upper = ua, lower = fa, finish = ha, saber = sb, tip = B["B_SaberTip" .. n], bend = Vector3.new(0, 0, -1) }
		end
	end

	-- cape grid: B_Cape<col>_<row>, rows top -> hem
	self.cape = nil
	local cols = {}
	for c = 1, 9 do
		local col = {}
		for r = 1, 9 do
			local rec = B[("B_Cape%d_%d"):format(c, r)]
			if not rec then
				break
			end
			col[r] = rec
		end
		if #col == 0 then
			break
		end
		cols[c] = col
	end
	if #cols >= 2 then
		local nr = #cols[1]
		local cape = { cols = cols, nc = #cols, nr = nr, p = {}, q = {}, rest = {}, len = {}, wlen = {}, alive = false, lastVR = nil }
		for c = 1, cape.nc do
			cape.rest[c] = {}
			for r = 1, nr do
				cape.rest[c][r] = cols[c][r].restRel.Position
			end
			-- hem point: continue the last segment
			local a, b = cape.rest[c][nr - 1], cape.rest[c][nr]
			cape.rest[c][nr + 1] = b + (b - a).Unit * ((b - a).Magnitude * 0.85)
		end
		for c = 1, cape.nc do
			cape.len[c] = {}
			for r = 1, nr do
				cape.len[c][r] = (cape.rest[c][r + 1] - cape.rest[c][r]).Magnitude
			end
		end
		for c = 1, cape.nc - 1 do
			cape.wlen[c] = {}
			for r = 1, nr + 1 do
				cape.wlen[c][r] = (cape.rest[c + 1][r] - cape.rest[c][r]).Magnitude
			end
		end
		self.cape = cape
	end

	self.scab = {}
	for _, n in { "L", "R" } do
		local rec = B["B_Scab" .. n]
		if rec then
			self.scab[n] = { rec = rec, a = V0, v = V0 }
		end
	end

	-- state
	self.gait = { phase = 0, walkW = 0, run = 0, speed = 0, dir = Vector3.new(0, 0, -1), lastVel = V0, acc = V0, turn = 0, plant = { [1] = 0, [-1] = 0 } }
	self.look = { yaw = 0, pitch = 0 }
	self.spring = {
		body = { x = V0, v = V0, f = 3.2, z = 0.35 },
		chest = { x = V0, v = V0, f = 3.0, z = 0.32 },
		head = { x = V0, v = V0, f = 2.6, z = 0.35 },
		armR = { x = V0, v = V0, f = 1.8, z = 0.45 },
		armL = { x = V0, v = V0, f = 1.8, z = 0.45 },
	}
	self.patchGrab = nil
	self.out = {}
	self.events = {}
	self.acc = {}
	for _, rec in self.list do
		self.acc[rec.name] = { r = V0, p = V0 }
	end
	return self
end

-- =============================================================================================
-- Spring helper
-- =============================================================================================
local function stepSpring(s, target, dt)
	local w = TAU * s.f
	local k, c = w * w, 2 * s.z * w
	local n = math.max(1, math.ceil(dt * 240))
	local h = dt / n
	local x, v = s.x, s.v
	for _ = 1, n do
		v += ((target - x) * k - v * c) * h
		x += v * h
	end
	s.x, s.v = x, v
	return x
end

-- =============================================================================================
-- Pose accumulation (root-space degrees / units)
-- =============================================================================================
local ARMN = { [1] = "R", [-1] = "L" }

function Animator:rot(name, rx, ry, rz, w)
	local a = self.acc[name]
	if a then
		a.r += Vector3.new(rx, ry, rz) * (RAD * w)
	end
end

function Animator:move(name, x, y, z, w)
	local a = self.acc[name]
	if a then
		a.p += Vector3.new(x, y, z) * (self.U * w)
	end
end

local function g(a, i)
	return if a and a[i] then a[i] else 0
end

-- lag: seconds this body part trails the keyframes (overlapping action)
local LAG = { hips = 0, spine = 0.012, chest = 0.025, neck = 0.04, head = 0.05, clav = 0.03, sh = 0.035, el = 0.05, wr = 0.065, sb = 0.07, feet = 0 }
Animator.LAG = LAG

-- Adds pose p (see Poses) with weight w. `part` limits it to one group (used by lagged evaluation).
function Animator:applyPose(p, w, part)
	if not p or w == 0 then
		return
	end
	local F = self.F
	local function want(k)
		return part == nil or part == k
	end
	if want("hips") and p.hips then
		local h = p.hips
		self:rot("B_Hips", g(h, 1), g(h, 2), g(h, 3), w)
		self:move("B_Hips", g(h, 4), g(h, 5), g(h, 6), w)
	end
	for key, bone in { spine = "B_Spine", chest = "B_Chest", neck = "B_Neck", head = "B_Head" } do
		local r = p[key]
		if r and want(key) then
			self:rot(bone, g(r, 1), g(r, 2), g(r, 3), w)
		end
	end
	for _, side in { 1, -1 } do
		local n = ARMN[side]
		local a = p[n]
		if a then
			if a.cl and want("clav") then
				self:rot("B_Clavicle" .. n, g(a.cl, 1), g(a.cl, 2) * side, g(a.cl, 3) * side, w)
			end
			if a.sh and want("sh") then
				self:rot("B_UpperArm" .. n, g(a.sh, 1), g(a.sh, 2) * side, g(a.sh, 3) * side, w)
			end
			if a.el and want("el") then
				self:rot("B_Forearm" .. n, a.el, 0, 0, w)
			end
			if a.wr and want("wr") then
				self:rot("B_Hand" .. n, g(a.wr, 1), g(a.wr, 2) * side, g(a.wr, 3) * side, w)
			end
			if a.sb and want("sb") then
				self:rot("B_Saber" .. n, g(a.sb, 1), g(a.sb, 2) * side, g(a.sb, 3) * side, w)
			end
			if a.aim and want("wr") then
				-- blade direction in root space (x mirrored: + is always outward)
				F.aim[side] += Vector3.new(g(a.aim, 1) * side, g(a.aim, 2), g(a.aim, 3)) * w
				F.aimW[side] += w
			end
		end
		local f = p["f" .. n]
		if f and want("feet") then
			F.feet[side] += Vector3.new(g(f, 1) * side, g(f, 2), g(f, 3)) * (self.U * w)
			F.footPitch[side] += g(f, 4) * RAD * w
			F.footYaw[side] += g(f, 5) * side * RAD * w
		end
	end
end

local PARTS = { "hips", "spine", "chest", "neck", "head", "clav", "sh", "el", "wr", "sb", "feet" }

-- Keyframes { {time, pose, ease}, ... }; ease of the segment ENDING at that key:
-- nil smooth, "out" snap, "back" snap with overshoot, "in" accelerate (impacts), "lin" linear.
local function keyAt(keys, t)
	local n = #keys
	if t <= keys[1][1] then
		return keys[1][2], keys[1][2], 0
	end
	if t >= keys[n][1] then
		return keys[n][2], keys[n][2], 1
	end
	local i = 2
	while keys[i][1] < t do
		i += 1
	end
	local a, b = keys[i - 1], keys[i]
	local u = progress(a[1], b[1], t)
	local e = b[3]
	if e == "out" then
		u = easeOut(u, 3)
	elseif e == "back" then
		u = easeOutBack(u, 1.6)
	elseif e == "in" then
		u = easeIn(u, 2.2)
	elseif e ~= "lin" then
		u = smoother(u)
	end
	return a[2], b[2], u
end

-- Plays keys with each body part trailing by its LAG (scaled by `lagScale`, 0 = no lag).
function Animator:playKeys(keys, t, w, lagScale)
	if #keys == 0 or w <= 0 then
		return
	end
	local P = self.poses
	local ls = lagScale or 1
	for _, part in PARTS do
		local pa, pb, u = keyAt(keys, t - LAG[part] * ls)
		local A, Bp = P[pa], P[pb]
		if pa == pb then
			self:applyPose(A, w, part)
		else
			-- u may overshoot past 1 ("back"): extrapolate linearly in pose space
			self:applyPose(A, w * (1 - u), part)
			self:applyPose(Bp, w * u, part)
		end
	end
end

function Animator:pose(name, w, part)
	self:applyPose(self.poses[name], w, part)
end

-- =============================================================================================
-- IK
-- =============================================================================================
-- Two-bone IK: the end bone's joint reaches `target` (root space), the middle joint bends toward
-- `pole`. bendCanon is the canonical direction the lower segment folds toward.
function Animator:twoBone(chain, target, pole, w)
	local up, lo, fin = chain.upper, chain.lower, chain.finish
	local Sframe = up.parent.rel * up.C0
	local Sp = Sframe.Position
	local L1 = lo.C0.Position.Magnitude
	local L2 = fin.C0.Position.Magnitude
	local toT = target - Sp
	local dist = toT.Magnitude
	if dist < 1e-4 or L1 < 1e-4 or L2 < 1e-4 then
		return
	end
	local u = toT / dist
	local d = math.clamp(dist, math.abs(L1 - L2) + 0.02 * self.U, (L1 + L2) * 0.9995)
	local pd = pole - u * pole:Dot(u)
	if pd.Magnitude < 1e-4 then
		pd = Vector3.new(0, 0, -1) - u * (-u.Z)
	end
	pd = pd.Unit
	local along = (L1 * L1 - L2 * L2 + d * d) / (2 * d)
	local h = math.sqrt(math.max(L1 * L1 - along * along, 0))
	local E = Sp + u * along + pd * h
	local P = Sp + u * d
	-- upper: rest (segment direction, fold direction) -> desired, in the upper bone's own axes
	local upLocal = lo.C0.Position.Unit
	local bendLocal = up.M * chain.bend
	bendLocal = bendLocal - upLocal * bendLocal:Dot(upLocal)
	local upDes = (E - Sp).Unit
	local fore = P - E
	local bendDes = fore - upDes * fore:Dot(upDes)
	if bendDes.Magnitude < 1e-4 * self.U then
		bendDes = -pd
	end
	local Mloc = frameFrom(upLocal, bendLocal)
	local Mdes = frameFrom(upDes, bendDes.Unit)
	local Tup = Sframe.Rotation:Inverse() * Mdes * Mloc:Inverse()
	local Ef = Sframe * Tup * lo.C0
	local foreLocal = fin.C0.Position.Unit
	local want = Ef:VectorToObjectSpace(fore.Unit)
	local axis = foreLocal:Cross(want)
	local ang = math.acos(math.clamp(foreLocal:Dot(want), -1, 1))
	local Tlo = if axis.Magnitude > 1e-6 then CFrame.fromAxisAngle(axis.Unit, ang) else I
	w = clamp01(w)
	up.T = blendCF(up.T, Tup, w)
	lo.T = blendCF(lo.T, Tlo, w)
end

-- Gives `rec` the root-space rotation `want` (its parent's rel must be current).
function Animator:setWorldRot(rec, want, w)
	local base = rec.parent and rec.parent.rel or self.holder
	local T = (base * rec.C0).Rotation:Inverse() * want
	rec.T = blendCF(rec.T, T, w or 1)
end

function Animator:fk()
	for _, rec in self.list do
		local base = if rec.parent then rec.parent.rel else self.holder
		rec.rel = base * rec.C0 * rec.T
	end
end

-- =============================================================================================
-- Frame
-- =============================================================================================
--[[
	inp = {
		dt, clock,
		vel           velocity of the drawn body, root space (studs/s)
		yawRate       radians/s
		vr            CFrame: where the body is drawn in the world (root CFrame * corr)
		corr          CFrame or nil: root-space correction (scripted paths)
		actions       { { name, t, real, w, cfg, data, target (root space) }, ... } oldest first
		state         { combat = bool, eyeOpen, capeOff, enraged, dead }
		look          { target = root-space Vector3, w = 0..1 } or nil
		gravity       studs/s^2 (default 196.2 * U / 1)
	}
]]
function Animator:step(inp)
	local dt = math.clamp(inp.dt, 1 / 240, 1 / 20)
	local clock = inp.clock
	self.dt = dt
	self.clock = clock
	self.inp = inp
	table.clear(self.events)
	local F = {
		feet = { [1] = V0, [-1] = V0 },
		footPitch = { [1] = 0, [-1] = 0 },
		footYaw = { [1] = 0, [-1] = 0 },
		reach = {},
		aim = { [1] = V0, [-1] = V0 },
		aimW = { [1] = 0, [-1] = 0 },
		capeBoost = V0,
		tremble = 0,
		look = nil,
		lookW = 0,
		patch = nil,
		stride = 0,
	}
	self.F = F
	for _, a in self.acc do
		a.r = V0
		a.p = V0
	end

	-- 1. stance + gait
	local suppress = 0
	for _, rec in inp.actions do
		suppress = math.max(suppress, rec.w * (rec.suppress or 1))
	end
	self.suppress = suppress
	self:baseLayer(inp, 1 - suppress)

	-- 2. actions
	local defs = Animator.ACTIONS
	for _, rec in inp.actions do
		local def = defs[rec.name]
		if def then
			if not rec.animSetup then
				rec.animSetup = true
				rec.adata = {}
				if def.setup then
					def.setup(self, rec)
				end
			end
			if rec.w > 0 and def.eval then
				def.eval(self, rec, rec.t, rec.w)
			end
		end
	end

	-- 3. look, breathing, flinch, tremble
	self:lookLayer(inp)
	self:secondaryLayer(inp)

	-- compose FK rotations (authored in root axes -> each bone's axes)
	local corr = inp.corr
	for _, rec in self.list do
		local a = self.acc[rec.name]
		local T
		if a.r ~= V0 then
			T = rec.M * CFrame.Angles(a.r.X, a.r.Y, a.r.Z) * rec.Minv
		else
			T = I
		end
		if a.p ~= V0 then
			T = CFrame.new(rec.M * a.p) * T
		end
		rec.T = T
	end
	local hips = self.bones.B_Hips
	if hips and corr then
		local base = (hips.parent and hips.parent.rel or self.holder) * hips.C0
		hips.T = base:Inverse() * corr * base * hips.T
	end
	self:fk()

	-- 4. legs, arms (IK)
	self:legLayer(inp)
	for side, req in F.reach do
		local chain = self.arms[side]
		if chain and req.w > 0.001 then
			self:twoBone(chain, req.target, req.pole or Vector3.new(side * 0.7, -0.6, 0.6), req.w)
		end
	end
	self:fk()
	self:aimLayer()

	-- 5. secondary: eyepatch follow, scabbards, cape
	self:patchLayer()
	self:scabbardLayer(inp)
	self:fk()
	self:clothLayer(inp)

	local out = self.out
	for _, rec in self.list do
		out[rec.name] = rec.T
	end
	return out
end

-- Turns each hand so its blade points where the poses ask (after the arm IK).
function Animator:aimLayer()
	local F = self.F
	local any = false
	for side, chain in self.arms do
		local wsum = F.aimW[side]
		local dirv = F.aim[side]
		if chain.saber and chain.tip and wsum > 0.02 and dirv.Magnitude > 1e-4 then
			local cur = chain.tip.rel.Position - chain.saber.rel.Position
			if cur.Magnitude > 1e-5 then
				cur = cur.Unit
				local want = dirv.Unit
				local axis = cur:Cross(want)
				local ang = math.acos(math.clamp(cur:Dot(want), -1, 1))
				if axis.Magnitude > 1e-6 and ang > 1e-4 then
					local hand = chain.finish
					local Rm = CFrame.fromAxisAngle(axis.Unit, ang)
					self:setWorldRot(hand, Rm * hand.rel.Rotation, math.min(1, wsum))
					any = true
				end
			end
		end
	end
	if any then
		self:fk()
	end
end

-- Root-space position of a bone (this frame).
function Animator:pos(name)
	local rec = self.bones[name]
	return if rec then rec.rel.Position else V0
end

function Animator:relOf(name)
	local rec = self.bones[name]
	return if rec then rec.rel else I
end

function Animator:emit(name, data)
	table.insert(self.events, { name = name, data = data })
end

-- =============================================================================================
-- 1. Stances and gait
-- =============================================================================================
function Animator:baseLayer(inp, baseW)
	local G = self.gait
	local F = self.F
	local U = self.U
	local dt = self.dt
	local clock = self.clock
	local dead = inp.state.dead
	local lv = inp.vel or V0
	local flat = Vector3.new(lv.X, 0, lv.Z)
	local speed = flat.Magnitude / U
	local turn = math.abs(inp.yawRate or 0)
	G.turn = approach(G.turn, turn, 6, dt)
	local acc = (lv - G.lastVel) / dt
	G.lastVel = lv
	G.acc = G.acc:Lerp(acc, math.min(1, dt * 8))

	local moving = clamp01((speed - 0.8) / 4)
	local turning = clamp01((G.turn - 1.2) / 2) * 0.5
	local want = if dead then 0 else math.max(moving, turning)
	G.walkW = approach(G.walkW, want, if want > G.walkW then 9 else 5, dt)
	G.run = approach(G.run, clamp01((speed - 14) / 8), 5, dt)
	if speed > 0.8 then
		G.dir = G.dir:Lerp(flat.Unit, math.min(1, dt * 10))
		if G.dir.Magnitude > 1e-3 then
			G.dir = G.dir.Unit
		end
	end
	local run = G.run
	-- stride: long military steps, much longer bounds when sprinting
	local stepLen = lerp(2.5, 5.2, run) * U
	local cadence = math.clamp(speed * U / (2 * stepLen), 0, 3.4)
	if turning > moving then
		cadence = math.max(cadence, 1.5)
	end
	if G.walkW > 0.01 then
		G.phase = (G.phase + dt * cadence) % 1
	end
	G.speed = speed

	local w = G.walkW * baseW
	local half = if cadence > 0.05 then math.min(speed * U / (4 * cadence), stepLen * 0.5) else 0
	half *= moving
	local p = G.phase
	local s1, c1 = math.sin(TAU * p), math.cos(TAU * p)
	local s2, c2 = math.sin(2 * TAU * p), math.cos(2 * TAU * p)

	-- feet: stance slides back under the body; swing tucks the heel up, then reaches forward
	local stanceFrac = lerp(0.58, 0.36, run)
	for _, side in { 1, -1 } do
		local q = (p + (if side == 1 then 0 else 0.5)) % 1
		local along, lift, pitch, back
		if q < stanceFrac then
			local u = q / stanceFrac
			along = lerp(1, -1, u)
			lift = 0
			-- heel strike (toes up) -> flat -> push off (heel up)
			pitch = (12 * (1 - smooth(u * 4)) - 22 * smooth((u - 0.7) / 0.3)) * RAD * (0.6 + 0.6 * run)
			back = 0
		else
			local u = (q - stanceFrac) / (1 - stanceFrac)
			along = lerp(-1, 1, smoother(u))
			local arc = math.sin(math.pi * u)
			lift = (arc * (0.35 + 0.55 * run) + math.sin(math.pi * clamp01(u * 1.6)) * 0.9 * run) * U
			back = math.sin(math.pi * clamp01(u * 1.4)) * 1.1 * run * U -- heel kicks up behind when running
			pitch = (-30 * math.sin(math.pi * clamp01(u * 1.5)) + 14 * smooth((u - 0.7) / 0.3)) * RAD * (0.5 + 0.7 * run)
		end
		F.feet[side] += G.dir * (along * half * w) + Vector3.new(0, lift * w, 0) - G.dir * (back * w)
		F.footPitch[side] += pitch * w
		if q < 0.05 and clock - G.plant[side] > 0.22 and w > 0.4 then
			G.plant[side] = clock
			self.spring.body.v += Vector3.new(0, -(0.7 + 1.5 * run) * w * U, 0)
			self:emit("footstep", { side = side, run = run })
		end
	end

	-- pelvis: drops at contact, rises at passing; turns and rolls with the stride
	local bob = (-0.06 - 0.05 * c2) * (1 + 1.4 * run)
	self:move("B_Hips", s1 * 0.05 * (1 - run), bob, 0, w)
	self:rot("B_Hips", 0, c1 * (7 + 3 * run), -s1 * (3 - run), w)
	self:rot("B_Spine", 0, -c1 * 3, s1 * 1.5, w)
	self:rot("B_Chest", -2 * c2 * run, -c1 * (6 + 6 * run), s1 * 1.5, w)
	self:rot("B_Head", 1.5 * c2, c1 * 4, 0, w)

	-- stances
	local idleW = baseW * (1 - G.walkW)
	local walkW = w * (1 - run)
	local runW = w * run
	local combat = inp.state.combat
	if combat then
		self:pose("guard", idleW)
		-- weight shift from foot to foot while he waits
		local sway = nz(clock * 0.25, 4.2)
		self:move("B_Hips", sway * 0.08, -0.02 * math.abs(sway), 0, idleW)
		self:rot("B_Hips", 0, 0, -sway * 2, idleW)
	else
		self:pose("atEase", idleW)
	end
	self:pose(if combat then "walkCombat" else "walk", walkW)
	self:pose("run", runW)

	-- arms swing against the legs through a heavy spring
	local amp = lerp(14, 26, run)
	local swing = -c1 * amp
	local ar = stepSpring(self.spring.armR, Vector3.new(swing, 0, 0) * w, dt)
	local al = stepSpring(self.spring.armL, Vector3.new(-swing, 0, 0) * w, dt)
	self:rot("B_UpperArmR", ar.X, 0, 0, 1)
	self:rot("B_UpperArmL", al.X, 0, 0, 1)
	self:rot("B_ForearmR", math.max(0, ar.X) * 0.5, 0, 0, 1)
	self:rot("B_ForearmL", math.max(0, al.X) * 0.5, 0, 0, 1)
	self:rot("B_ClavicleR", 0, ar.X * 0.15, 0, 1)
	self:rot("B_ClavicleL", 0, -al.X * 0.15, 0, 1)

	-- breathing (faster with the Ultimate Eye open)
	local rate = (1 / 4.2) * (if inp.state.enraged then 1.45 else 1)
	local b = math.sin(clock * TAU * rate)
	local bw = baseW * (1 - 0.6 * G.walkW)
	self:rot("B_Chest", -1.2 * b, 0, 0, bw)
	self:move("B_Chest", 0, 0.025 * b, 0, bw)
	self:rot("B_ClavicleR", 0, 0, 1.5 * b, bw)
	self:rot("B_ClavicleL", 0, 0, 1.5 * b, bw)
	self:rot("B_Head", 0.6 * b, 0, 0, bw)
	-- idle life: he is utterly composed; the blades turn a little in his fists
	self:rot("B_Head", nz(clock * 0.13, 1.3) * 2, nz(clock * 0.1, 2.1) * 4, 0, idleW)
	self:rot("B_HandR", nz(clock * 0.31, 4.1) * 3, 0, nz(clock * 0.27, 4.7) * 5, idleW)
	self:rot("B_HandL", nz(clock * 0.29, 5.1) * 3, 0, nz(clock * 0.23, 5.7) * 5, idleW)
end

-- =============================================================================================
-- 3. Look-at and secondary springs
-- =============================================================================================
function Animator:lookLayer(inp)
	local F = self.F
	local L = self.look
	local target, w = F.look, F.lookW
	if (not target or w < 0.05) and inp.look then
		target, w = inp.look.target, inp.look.w * (1 - self.suppress)
	end
	local ty, tp = 0, 0
	local head = self.bones.B_Head
	if target and w > 0.01 and head then
		local dir = target - head.restRel.Position
		if dir.Z < 2 * self.U then
			local horiz = math.sqrt(dir.X * dir.X + dir.Z * dir.Z)
			ty = math.clamp(math.atan2(-dir.X, -dir.Z), -60 * RAD, 60 * RAD) * w
			tp = math.clamp(math.atan2(dir.Y, horiz), -25 * RAD, 22 * RAD) * w
		end
	end
	L.yaw = approach(L.yaw, ty, 7, self.dt)
	L.pitch = approach(L.pitch, tp, 7, self.dt)
	local A = self.acc
	A.B_Head.r += Vector3.new(L.pitch * 0.55, L.yaw * 0.55, 0)
	if A.B_Neck then
		A.B_Neck.r += Vector3.new(L.pitch * 0.3, L.yaw * 0.25, 0)
	end
	A.B_Chest.r += Vector3.new(0, L.yaw * 0.18, 0)
end

function Animator:secondaryLayer(inp)
	local A = self.acc
	local dt = self.dt
	local S = self.spring
	local drop = stepSpring(S.body, V0, dt)
	A.B_Hips.p += Vector3.new(0, math.clamp(drop.Y, -1.2 * self.U, 0.5 * self.U), 0)
	if A.B_Spine then
		A.B_Spine.r += Vector3.new(drop.Y * 0.08 / self.U, 0, 0)
	end
	A.B_Chest.r += stepSpring(S.chest, V0, dt)
	A.B_Head.r += stepSpring(S.head, V0, dt)
	local tr = self.F.tremble
	if tr > 0 then
		local tt = self.clock * 21
		A.B_Chest.r += Vector3.new(nz(tt, 21), nz(tt, 22), nz(tt, 23)) * (1.3 * RAD * tr)
		A.B_Head.r += Vector3.new(nz(tt, 24), nz(tt, 25), nz(tt, 26)) * (1.8 * RAD * tr)
		A.B_HandR.r += Vector3.new(nz(tt, 27), 0, nz(tt, 28)) * (4 * RAD * tr)
		A.B_HandL.r += Vector3.new(nz(tt, 29), 0, nz(tt, 30)) * (4 * RAD * tr)
	end
end

-- Hit flinch (called by the client when he takes damage).
function Animator:flinch(strength)
	local s = strength or 1
	self.spring.chest.v += Vector3.new(-0.5, (math.random() - 0.5) * 0.6, (math.random() - 0.5) * 0.4) * s
	self.spring.head.v += Vector3.new(-0.6, (math.random() - 0.5) * 0.8, 0) * s
end

function Animator:impact(down)
	self.spring.body.v += Vector3.new(0, -down * self.U, 0)
end

-- =============================================================================================
-- 4. Legs
-- =============================================================================================
function Animator:legLayer(inp)
	local F = self.F
	local corr = inp.corr
	local hipsYaw = self.acc.B_Hips.r.Y
	for side, leg in self.legs do
		local pitch = F.footPitch[side]
		local toeLen = if leg.toe then (leg.toe.restRel.Position - leg.finish.restRel.Position).Magnitude else 0.9 * self.U
		local roll = if pitch < 0 then toeLen * math.sin(-pitch) * 0.95 else toeLen * 0.42 * math.sin(pitch)
		local target = leg.restAnkle + F.feet[side] + Vector3.new(0, roll, 0)
		if corr then
			target = corr * target
		end
		local pole = Vector3.new(side * 0.12, 0.1, -1)
		pole = CFrame.Angles(0, hipsYaw * 0.6, 0) * pole
		if corr then
			pole = corr:VectorToWorldSpace(pole)
		end
		self:twoBone(leg, target, pole, 1)
		local base = leg.lower.parent.rel * leg.lower.C0 * leg.lower.T
		-- foot: level with the ground, turned with the hips, pitched by the gait / pose
		local yaw = hipsYaw * 0.8 + F.footYaw[side]
		local want = CFrame.Angles(0, yaw, 0) * CFrame.Angles(F.footPitch[side], 0, 0) * leg.finish.restRel.Rotation
		if corr then
			want = corr.Rotation * want
		end
		leg.finish.T = (base * leg.finish.C0).Rotation:Inverse() * want
		-- toes bend up as the heel lifts
		if leg.toe then
			local bend = math.max(0, -F.footPitch[side]) * 0.7
			leg.toe.T = leg.toe.M * CFrame.Angles(bend, 0, 0) * leg.toe.Minv
		end
	end
end

-- =============================================================================================
-- 5. Eyepatch follow, scabbards, cape cloth
-- =============================================================================================
function Animator:patchLayer()
	local patch = self.bones.B_Patch
	local hand = self.bones.B_HandL
	local req = self.F.patch
	if not patch or not hand then
		return
	end
	if not req or req.w <= 0 then
		self.patchGrab = nil
		return
	end
	if not self.patchGrab then
		self.patchGrab = hand.rel:Inverse() * patch.rel
	end
	local want = hand.rel * self.patchGrab
	local base = patch.parent.rel * patch.C0
	patch.T = blendCF(I, base:Inverse() * want, req.w)
end

function Animator:scabbardLayer(inp)
	local dt = self.dt
	local accl = self.gait.acc / self.U
	for n, sc in self.scab do
		local side = if n == "R" then 1 else -1
		local thigh = self.acc["B_Thigh" .. n]
		local push = 0
		local leg = self.legs[side]
		if leg then
			local hip, knee = leg.upper.rel.Position, leg.lower.rel.Position
			local fwd = math.atan2(-(knee.Z - hip.Z), -(knee.Y - hip.Y))
			local hipsPitch = self.acc.B_Hips.r.X
			push = math.max(0, fwd + hipsPitch) * 0.95
		end
		local run = self.gait.run * self.gait.walkW
		push *= 1 - 0.85 * run
		local free = Vector3.new(math.clamp(accl.Z * 0.012, -0.5, 0.5), 0, math.clamp(-accl.X * 0.01, -0.4, 0.4) * side)
		local target = free + Vector3.new(push - 0.62 * run, 0, 0.42 * run * side)
		local w = TAU * 1.4
		local n_ = math.max(1, math.ceil(dt * 240))
		local h = dt / n_
		for _ = 1, n_ do
			sc.v += ((target - sc.a) * w * w - sc.v * 2 * 0.25 * w) * h
			sc.a += sc.v * h
		end
		-- the leg pushes hard: never let the scabbard swing back through the thigh
		if sc.a.X < push then
			sc.a = Vector3.new(push, sc.a.Y, sc.a.Z)
			sc.v = Vector3.new(math.max(sc.v.X, 0), sc.v.Y, sc.v.Z)
		end
		sc.rec.T = sc.rec.M * CFrame.Angles(sc.a.X, 0, sc.a.Z) * sc.rec.Minv
		local _ = thigh
	end
end

-- The cape: a Verlet cloth over the cape bone grid, simulated in world space so it trails behind
-- every dash, leap and spin; it collides with the torso and the legs.
function Animator:clothLayer(inp)
	local cape = self.cape
	if not cape then
		return
	end
	local U = self.U
	local vr = inp.vr or I
	local nc, nr = cape.nc, cape.nr
	local chest = self.bones.B_Chest
	if not chest then
		return
	end
	if inp.state.capeOff then
		cape.alive = false
		return
	end
	-- pinned top row follows the chest
	local chestDelta = chest.rel * chest.restRel:Inverse()
	local tops = {}
	for c = 1, nc do
		tops[c] = vr * (chestDelta * cape.rest[c][1])
	end
	local teleport = cape.lastVR and (cape.lastVR.Position - vr.Position).Magnitude > 12 * U
	if not cape.alive or teleport then
		cape.alive = true
		for c = 1, nc do
			cape.p[c] = {}
			cape.q[c] = {}
			for r = 1, nr + 1 do
				local w = vr * (chestDelta * cape.rest[c][r])
				cape.p[c][r] = w
				cape.q[c][r] = w
			end
		end
	end
	-- the cloth inherits most of the body's own movement (dashes and leaps would otherwise fling it
	-- around like a flag in a hurricane); what is left over is the trailing motion you see
	if cape.lastVR then
		local D = vr * cape.lastVR:Inverse()
		local inherit = 0.8
		for c = 1, nc do
			for r = 2, nr + 1 do
				local p = cape.p[c][r]
				local moved = D * p
				local dp = (moved - p) * inherit
				cape.p[c][r] = p + dp
				cape.q[c][r] = cape.q[c][r] + dp
			end
		end
	end
	cape.lastVR = vr
	local dt = self.dt
	local steps = 2
	local h = dt / steps
	local grav = Vector3.new(0, -(inp.gravity or 196.2) * U * 0.6, 0)
	local windT = self.clock * 0.7
	local wind = (vr.LookVector * -1) * (nz(windT, 3.3) * 0.5 + 0.5) * 4 * U + vr.RightVector * nz(windT, 7.7) * 3 * U
	local boost = self.F.capeBoost
	local boostW = vr:VectorToWorldSpace(Vector3.new(0, boost.Y, boost.Z)) * U
	-- collision capsules (world): spine, thighs, shins
	local caps = {}
	local function cap(a, b, r)
		local A, Bb = self.bones[a], self.bones[b]
		if A and Bb then
			table.insert(caps, { vr * A.rel.Position, vr * Bb.rel.Position, r * U })
		end
	end
	cap("B_Hips", "B_Chest", 1.05)
	cap("B_Chest", "B_Neck", 1.0)
	cap("B_ThighR", "B_ShinR", 0.62)
	cap("B_ThighL", "B_ShinL", 0.62)
	cap("B_ShinR", "B_FootR", 0.5)
	cap("B_ShinL", "B_FootL", 0.5)
	for _ = 1, steps do
		for c = 1, nc do
			cape.p[c][1] = tops[c]
			cape.q[c][1] = tops[c]
			for r = 2, nr + 1 do
				local p, q = cape.p[c][r], cape.q[c][r]
				local f = r / (nr + 1)
				local vel = (p - q) * 0.975
				local vm = vel.Magnitude
				local maxStep = 1.6 * U * (dt / steps) * 30
				if vm > maxStep then
					vel = vel * (maxStep / vm)
				end
				cape.q[c][r] = p
				cape.p[c][r] = p + vel + (grav + wind * f + boostW * f) * (h * h)
			end
		end
		for _ = 1, 6 do
			-- structural (down the cape): keep the rest length
			for c = 1, nc do
				for r = 1, nr do
					local a, b = cape.p[c][r], cape.p[c][r + 1]
					local d = b - a
					local len = d.Magnitude
					if len > 1e-6 then
						local diff = (len - cape.len[c][r]) / len
						if r == 1 then
							cape.p[c][r + 1] = b - d * diff
						else
							cape.p[c][r] = a + d * (diff * 0.5)
							cape.p[c][r + 1] = b - d * (diff * 0.5)
						end
					end
				end
			end
			-- across the cape: no stretching, gentle resistance to bunching
			for c = 1, nc - 1 do
				for r = 2, nr + 1 do
					local a, b = cape.p[c][r], cape.p[c + 1][r]
					local d = b - a
					local len = d.Magnitude
					local rest = cape.wlen[c][r]
					if len > 1e-6 and (len > rest or len < rest * 0.7) then
						local k = if len > rest then 0.5 else 0.15
						local diff = (len - rest) / len * k
						cape.p[c][r] = a + d * diff
						cape.p[c + 1][r] = b - d * diff
					end
				end
			end
			-- body collisions (capsules), plus "stay behind the back plane" for the top rows
			for c = 1, nc do
				for r = 2, nr + 1 do
					local p = cape.p[c][r]
					for _, k in caps do
						local a, b, rad = k[1], k[2], k[3]
						local ab = b - a
						local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), 1e-9), 0, 1)
						local cpt = a + ab * t
						local off = p - cpt
						local dist = off.Magnitude
						if dist < rad then
							p = cpt + (if dist > 1e-6 then off / dist else vr.LookVector * -1) * rad
						end
					end
					cape.p[c][r] = p
				end
			end
		end
	end
	-- bones from the simulated points (top down, so each parent is current)
	local vrInv = vr:Inverse()
	for c = 1, nc do
		for r = 1, nr do
			local rec = cape.cols[c][r]
			local a = vrInv * cape.p[c][r]
			local b = vrInv * cape.p[c][r + 1]
			local cl, cr = math.max(1, c - 1), math.min(nc, c + 1)
			local across = (vrInv * cape.p[cr][r]) - (vrInv * cape.p[cl][r])
			local d0 = cape.rest[c][r + 1] - cape.rest[c][r]
			local a0 = cape.rest[cr][r] - cape.rest[cl][r]
			local Fnow = frameFrom((b - a), across)
			local Frest = frameFrom(d0, a0)
			local want = Fnow * Frest:Inverse() * rec.restRel.Rotation
			local base = (rec.parent and rec.parent.rel or self.holder) * rec.C0
			rec.T = base.Rotation:Inverse() * want
			rec.rel = base * rec.T
		end
	end
end

-- =============================================================================================
-- Actions (poses only; sounds and effects live in BossClient)
-- =============================================================================================
Animator.ACTIONS = {}
local ACT = Animator.ACTIONS

local function cfgv(rec, key, default)
	local v = rec.cfg and rec.cfg[key]
	return if v == nil then default else v
end

-- Challenge: first sight. Levels the right saber at the target, the left sweeps back.
ACT.Challenge = {
	setup = function(A, rec)
		local D = cfgv(rec, "Duration", 2.2)
		rec.keys = { { 0, "guard" }, { 0.35, "challengeWind" }, { 0.75, "challengePoint", "back" }, { D - 0.55, "challengePoint" }, { D, "guard" } }
	end,
	eval = function(A, rec, t, w)
		A:playKeys(rec.keys, t, w)
		A.F.look, A.F.lookW = rec.rootTarget, w
		A.F.capeBoost = Vector3.new(0, 0, 0)
	end,
}

ACT.RemoveCape = {
	setup = function(A, rec)
		local D = cfgv(rec, "Duration", 2.4)
		local rel = cfgv(rec, "ReleaseAt", 0.95)
		rec.keys = { { 0, "guard" }, { rel - 0.45, "capeGrab" }, { rel - 0.28, "capeGrab" }, { rel + 0.05, "capeRip", "back" }, { rel + 0.45, "capeFling" }, { D, "guard" } }
	end,
	eval = function(A, rec, t, w)
		local rel = cfgv(rec, "ReleaseAt", 0.95)
		A:playKeys(rec.keys, t, w)
		-- left hand (with its saber) grabs the cape at the right shoulder clasp
		local clasp = A.bones.B_ClavicleR
		if clasp then
			local target = clasp.rel.Position + Vector3.new(0.35, 0.55, -0.55) * A.U
			A.F.reach[-1] = { target = target, w = envelope(t, 0.12, rel - 0.38, rel - 0.2, rel - 0.02) * w, pole = Vector3.new(-1, -0.3, 0.4) }
		end
		-- the cape is dragged up and across before he lets go
		local pull = envelope(t, rel - 0.32, rel - 0.06, rel - 0.02, rel + 0.02)
		A.F.capeBoost = Vector3.new(0, 30, 26) * pull
		A.F.look, A.F.lookW = rec.rootTarget, w * 0.6
	end,
}

ACT.RemoveEyepatch = {
	setup = function(A, rec)
		local D = cfgv(rec, "Duration", 4)
		local tear = cfgv(rec, "TearAt", 1.05)
		local open = cfgv(rec, "OpenAt", 2.15)
		rec.keys = {
			{ 0, "guard" }, { tear - 0.45, "patchReach" }, { tear - 0.05, "patchReach" }, { tear + 0.12, "patchTear", "out" },
			{ tear + 0.4, "patchFling", "back" }, { open - 0.4, "eyeBow" }, { open, "eyeReveal", "out" }, { D - 0.6, "eyeReveal" }, { D, "guard" },
		}
	end,
	eval = function(A, rec, t, w)
		local tear = cfgv(rec, "TearAt", 1.05)
		local open = cfgv(rec, "OpenAt", 2.15)
		A:playKeys(rec.keys, t, w)
		local patch = A.bones.B_Patch
		local head = A.bones.B_Head
		if patch and head then
			-- the wrist stops a hand's length in front of the face, fist toward the patch
			local target = patch.rel.Position + head.rel:VectorToWorldSpace(head.M * Vector3.new(-0.2, -0.32, -0.42)) * A.U
			A.F.reach[-1] = { target = target, w = envelope(t, 0.12, tear - 0.4, tear - 0.02, tear + 0.18) * w, pole = Vector3.new(-1, -0.7, 0.2) }
		end
		local release = tear + 0.3
		if t >= tear - 0.16 and t < release then
			A.F.patch = { w = smooth(progress(tear - 0.16, tear - 0.06, t)) }
		end
		A.F.tremble = math.max(A.F.tremble, 0.7 * envelope(t, open - 0.85, open - 0.45, open - 0.04, open))
		A.F.look, A.F.lookW = rec.rootTarget, w * 0.5
	end,
}

ACT.Lunge = {
	setup = function(A, rec)
		local c = rec.cfg
		local d0, d1 = c.Dash[1], c.Dash[2]
		rec.keys = { { 0, "guard" }, { d0 - 0.22, "lungeWind" }, { d0 - 0.02, "lungeWindDeep" }, { d0 + 0.07, "lungeThrust", "back" }, { d1, "lungeThrust" },
			{ d1 + 0.3, "lungeRecover" }, { c.Duration, "guard" } }
	end,
	eval = function(A, rec, t, w)
		local c = rec.cfg
		A:playKeys(rec.keys, t, w)
		A.F.tremble = math.max(A.F.tremble, 0.3 * envelope(t, c.Dash[1] - 0.35, c.Dash[1] - 0.2, c.Dash[1] - 0.04, c.Dash[1]))
		if t < c.Dash[1] then
			A.F.look, A.F.lookW = rec.rootTarget, w
		end
	end,
}

ACT.CrossCut = {
	setup = function(A, rec)
		local h, D = rec.cfg.Hits, rec.cfg.Duration
		rec.keys = {
			{ 0, "guard" }, { h[1] - 0.13, "ccRaise" }, { h[1] + 0.02, "ccCut1", "back" }, { h[2] - 0.13, "ccCut1Hold" }, { h[2] + 0.02, "ccCut2", "back" },
			{ h[3] - 0.16, "ccX" }, { h[3] + 0.03, "ccXCut", "back" }, { h[3] + 0.32, "ccXCut" }, { D, "guard" },
		}
	end,
	eval = function(A, rec, t, w)
		A:playKeys(rec.keys, t, w, 0.7)
		if t < rec.cfg.Hits[1] then
			A.F.look, A.F.lookW = rec.rootTarget, w
		end
	end,
}

ACT.SaberThrow = {
	setup = function(A, rec)
		local c = rec.cfg
		local rl, r0, r1 = c.ReleaseAt, c.Redraw[1], c.Redraw[2]
		rec.keys = { { 0, "guard" }, { rl - 0.14, "throwWind" }, { rl + 0.05, "throwRelease", "back" }, { r0, "throwFollow" }, { r0 + 0.22, "throwReach" },
			{ r1 - 0.08, "throwDraw" }, { c.Duration, "guard" } }
	end,
	eval = function(A, rec, t, w)
		local c = rec.cfg
		local r0, r1 = c.Redraw[1], c.Redraw[2]
		A:playKeys(rec.keys, t, w)
		-- left hand back to the spare hilt at his left hip
		local hip = A.bones.B_ScabL
		if hip then
			local target = hip.rel.Position + Vector3.new(-0.15, 0.55, 0.15) * A.U
			A.F.reach[-1] = { target = target, w = envelope(t, r0, r0 + 0.2, (r0 + r1) / 2 + 0.05, r1) * w, pole = Vector3.new(-1, -0.2, 0.9) }
		end
		if t < c.ReleaseAt then
			A.F.look, A.F.lookW = rec.rootTarget, w
		end
	end,
}

ACT.Cleave = {
	setup = function(A, rec)
		local c = rec.cfg
		local l0, imp = c.Leap[1], c.ImpactAt
		rec.keys = { { 0, "guard" }, { l0 - 0.04, "cleaveCrouch" }, { l0 + 0.16, "cleaveRise", "out" }, { imp - 0.14, "cleaveAir" }, { imp, "cleaveImpact", "in" },
			{ imp + 0.5, "cleaveImpact" }, { c.Duration, "guard" } }
	end,
	eval = function(A, rec, t, w)
		local c = rec.cfg
		A:playKeys(rec.keys, t, w)
		if t < c.Leap[1] + 0.2 then
			A.F.look, A.F.lookW = rec.rootTarget, w
		end
	end,
}

ACT.ThousandCuts = {
	setup = function(A, rec)
		local c = rec.cfg
		local f0, f1 = c.Flurry[1], c.Flurry[2]
		local n = math.max(1, c.Slashes or 12)
		local keys = { { 0, "guard" }, { f0 - 0.45, "tcFocus" }, { f0 - 0.04, "tcFocus" } }
		local names = { "tcA", "tcB", "tcC", "tcD" }
		for i = 1, n do
			table.insert(keys, { f0 + (f1 - f0) * (i - 0.5) / n, names[(i - 1) % #names + 1], "back" })
		end
		table.insert(keys, { c.FinalAt - 0.16, "tcCross" })
		table.insert(keys, { c.FinalAt, "tcRelease", "back" })
		table.insert(keys, { c.Recover[1] + 0.2, "tcRelease" })
		table.insert(keys, { c.Duration, "guard" })
		rec.keys = keys
	end,
	eval = function(A, rec, t, w)
		local c = rec.cfg
		-- the flurry is too fast for overlap: no lag while it lasts
		local lag = if t > c.Flurry[1] and t < c.Flurry[2] then 0.25 else 1
		A:playKeys(rec.keys, t, w, lag)
		if t < c.Flurry[1] then
			A.F.look, A.F.lookW = rec.rootTarget, w
		end
		local fl = envelope(t, c.Flurry[1], c.Flurry[1] + 0.05, c.Flurry[2], c.Flurry[2] + 0.05)
		A.F.capeBoost = Vector3.new(0, 10 * fl, 14 * math.sin(t * 40) * fl)
	end,
}

ACT.PhantomStep = {
	setup = function(A, rec)
		local c = rec.cfg
		local s0, s1 = c.Steps[1], c.Steps[2]
		rec.keys = { { 0, "guard" }, { 0.35, "psLock" }, { s0 - 0.04, "psLock" }, { s0 + 0.07, "psDash", "out" }, { s1 - 0.02, "psDash" }, { s1 + 0.25, "psPause", "back" },
			{ c.DetonateAt + 0.15, "psPause" }, { c.DetonateAt + 0.35, "psFlick", "out" }, { c.Duration, "guard" } }
	end,
	eval = function(A, rec, t, w)
		local c = rec.cfg
		local dash = t > c.Steps[1] and t < c.Steps[2]
		A:playKeys(rec.keys, t, w, if dash then 0.3 else 1)
		if t < c.Steps[1] then
			A.F.look, A.F.lookW = rec.rootTarget, w
		end
	end,
}

ACT.Death = {
	setup = function(A, rec)
		rec.keys = { { 0, "guard" }, { 0.45, "deathStagger", "out" }, { 1.35, "deathKneel", "in" }, { 2.6, "deathKneel" }, { 3.4, "deathLying", "in" }, { 99, "deathLying" } }
	end,
	eval = function(A, rec, t, w)
		A:playKeys(rec.keys, t, w)
	end,
}

ACT.Idle = nil

return Animator
