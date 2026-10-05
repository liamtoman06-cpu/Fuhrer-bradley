--!nonstrict
--[[
	King Bradley boss - client: every animation, every visual effect, the local player's knockback,
	camera shake, screen effects, the anime outline and the boss health bar.

	A Script (RunContext = Client) that sits directly inside the KingBradley model, so every player
	runs their own copy (each respawned boss runs a fresh one).

	Contract with BossServer:
	  * the server builds a Motor6D per B_* bone (Part0 = parent bone, C0 = rest offset, C1 = identity)
	    and then sets the model attribute RigReady = true;
	  * Motor6D.Transform is set here every frame (RunService.PreSimulation) and is never replicated;
	  * actions arrive as attributes (Action, ActionId, ActionStart, ActionSpeed, ActionTarget,
	    ActionPath, ActionVictim). Time into an action = (GetServerTimeNow() - ActionStart) * ActionSpeed
	    and its phases come from Config.Actions, so every client shows the same moment of the same cut;
	  * dashes and leaps follow ActionPath (module Motion): the body is drawn exactly on the path,
	    which keeps them smooth whatever the network does;
	  * Drawn / CapeOff / EyeOpen / Enraged describe the persistent state (late joiners see it right).

	Layout of this file:
	   1. services, guards, config            7. visual effects library
	   2. pure math                           8. actions (one block per move)
	   3. rig discovery                       9. local player: knockback, shake, screen
	   4. poses, FK, leg IK, arm IK          10. outline, hit flash, boss bar
	   5. base layer: stances, walk, run     11. frame loop
	   6. cape cloth, eyelid, prop groups    12. lifecycle and cleanup
]]

-- =============================================================================================
-- 1. Services, guards, config
-- =============================================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local model = script.Parent
if not (model and model:IsA("Model")) then
	warn("[Bradley] BossClient must be a direct child of the boss Model")
	return
end

while not model:IsDescendantOf(workspace) do
	model.AncestryChanged:Wait()
end

local DEBUG = false
local function log(...)
	if DEBUG then
		print("[Bradley client]", ...)
	end
end

local function requireChild(name: string)
	local module = model:WaitForChild(name, 10)
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok then
			return result
		end
		warn("[Bradley] could not load " .. name .. ": " .. tostring(result))
	end
	return nil
end

local Config = requireChild("Config") or { Actions = {}, Sounds = {} }
local Motion = requireChild("Motion")
local Poses = requireChild("Poses") or {}
if not Motion then
	warn("[Bradley] BossClient needs the Motion module")
	return
end

local function cfgAction(name: string)
	local given = type(Config.Actions) == "table" and Config.Actions[name] or nil
	return if type(given) == "table" then given else {}
end

local localPlayer = Players.LocalPlayer

-- =============================================================================================
-- 2. Pure math
-- =============================================================================================
local TAU = math.pi * 2
local RAD = math.pi / 180
local V0 = Vector3.zero
local I = CFrame.identity

local function clamp01(x: number): number
	return if x < 0 then 0 elseif x > 1 then 1 else x
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function progress(a: number, b: number, x: number): number
	if b <= a then
		return if x >= b then 1 else 0
	end
	return clamp01((x - a) / (b - a))
end

local function smooth(t: number): number
	t = clamp01(t)
	return t * t * (3 - 2 * t)
end

local function smoother(t: number): number
	t = clamp01(t)
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function easeOut(t: number, p: number?): number
	return 1 - (1 - clamp01(t)) ^ (p or 3)
end

local function easeIn(t: number, p: number?): number
	return clamp01(t) ^ (p or 3)
end

-- Rises over [a, b], holds, falls over [c, d].
local function envelope(t: number, a: number, b: number, c: number, d: number): number
	return smooth(progress(a, b, t)) * (1 - smooth(progress(c, d, t)))
end

local function approach(current: number, target: number, rate: number, dt: number): number
	return target + (current - target) * math.exp(-rate * dt)
end

local function noise(t: number, seed: number): number
	return math.clamp(math.noise(t, seed, 0.37) * 2, -1, 1)
end

-- Pose interpolation (axis-angle, works for t outside [0, 1]).
local function blendPose(a: CFrame, b: CFrame, t: number): CFrame
	if t <= 0 then
		return a
	elseif t >= 1 then
		return b
	end
	local pos = a.Position + (b.Position - a.Position) * t
	local axis, angle = (a.Rotation:Inverse() * b.Rotation):ToAxisAngle()
	if angle ~= angle or math.abs(angle) < 1e-6 or axis.Magnitude < 1e-6 then
		return CFrame.new(pos) * a.Rotation
	end
	return CFrame.new(pos) * a.Rotation * CFrame.fromAxisAngle(axis, angle * t)
end

type Spring = { x: Vector3, v: Vector3, f: number, z: number }

local function newSpring(freq: number, zeta: number): Spring
	return { x = V0, v = V0, f = freq, z = zeta }
end

local function stepSpring(s: Spring, target: Vector3, dt: number): Vector3
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

-- Two-bone planar leg IK in the hips frame (knee hinge about X).
local function solveLegIK(leg, d: Vector3)
	local L1, L2 = leg.L1, leg.L2
	local dy, dz = d.Y, d.Z
	local D = math.sqrt(dy * dy + dz * dz)
	D = math.clamp(D, math.abs(L1 - L2) + 0.05, (L1 + L2) * 0.9995)
	local phiD = math.atan2(-dz, -dy)
	local alpha = math.acos(math.clamp((L1 * L1 + D * D - L2 * L2) / (2 * L1 * D), -1, 1))
	local beta = math.acos(math.clamp((L2 * L2 + D * D - L1 * L1) / (2 * L2 * D), -1, 1))
	local phi1 = phiD + alpha
	local phi2 = phiD - beta
	local thigh = phi1 - leg.a1
	local shin = phi2 - phi1 + leg.a1 - leg.a2
	local roll = math.clamp(math.atan2(d.X - leg.dx, D), -0.45, 0.45)
	return thigh, shin, roll, phi2 - leg.a2
end

local function frameFrom(x: Vector3, y: Vector3): CFrame
	x = x.Unit
	local z = x:Cross(y)
	if z.Magnitude < 1e-5 then
		z = x:Cross(if math.abs(x.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis)
	end
	z = z.Unit
	y = z:Cross(x)
	return CFrame.fromMatrix(V0, x, y, z)
end

-- =============================================================================================
-- 3. Rig discovery
-- =============================================================================================
while not model:GetAttribute("RigReady") do
	if not model:IsDescendantOf(workspace) then
		return
	end
	task.wait(0.2)
end

local hrp = model:WaitForChild("HumanoidRootPart", 10)
if not (hrp and hrp:IsA("BasePart")) then
	warn("[Bradley] BossClient: the model has no HumanoidRootPart")
	return
end
local humanoid = model:FindFirstChildOfClass("Humanoid")

local S = 1
do
	local ok, s = pcall(function()
		return model:GetScale()
	end)
	if ok and type(s) == "number" and s > 0 then
		S = s
	end
end

type BoneRec = {
	name: string,
	part: BasePart,
	motor: Motor6D?,
	parent: any,
	C0: CFrame,
	C0inv: CFrame,
	restRel: CFrame,
	rel: CFrame,
	T: CFrame,
	dirty: boolean,
}

local bones: { [string]: BoneRec } = {}
local boneList: { BoneRec } = {}

local function isBoneName(name: string): boolean
	return string.sub(name, 1, 2) == "B_"
end

local function discoverBones(): number
	table.clear(bones)
	table.clear(boneList)
	bones.HumanoidRootPart = {
		name = "HumanoidRootPart",
		part = hrp,
		motor = nil,
		parent = nil,
		C0 = I,
		C0inv = I,
		restRel = I,
		rel = I,
		T = I,
		dirty = false,
	}
	local pending = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			local p0, p1 = d.Part0, d.Part1
			if p0 and p1 and p1.Name == d.Name and isBoneName(d.Name) then
				pending[d.Name] = d
			end
		end
	end
	local grew = true
	while grew do
		grew = false
		for name, motor in pending do
			local parent = bones[motor.Part0.Name]
			if parent and parent.part == motor.Part0 then
				local c0 = motor.C0
				bones[name] = {
					name = name,
					part = motor.Part1,
					motor = motor,
					parent = parent,
					C0 = c0,
					C0inv = c0:Inverse(),
					restRel = parent.restRel * c0,
					rel = parent.restRel * c0,
					T = I,
					dirty = false,
				}
				table.insert(boneList, bones[name])
				pending[name] = nil
				grew = true
			end
		end
	end
	return #boneList
end

do
	local expected = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and isBoneName(d.Name) then
			expected += 1
		end
	end
	local deadline = os.clock() + 6
	while discoverBones() < expected and os.clock() < deadline and model.Parent do
		task.wait(0.25)
	end
	log(("found %d/%d motors"):format(#boneList, expected))
end

if not bones.B_Hips then
	warn("[Bradley] BossClient: no B_Hips motor found, animation disabled")
	return
end

local function attachmentOn(rec: BoneRec?, name: string): CFrame?
	if not rec then
		return nil
	end
	local a = rec.part:FindFirstChild(name)
	if a and a:IsA("Attachment") then
		return a.CFrame
	end
	return nil
end

-- Legs
type Leg = { side: number, thigh: BoneRec, shin: BoneRec, foot: BoneRec, pivot: Vector3, L1: number, L2: number, a1: number, a2: number, dx: number, restAnkle: Vector3 }
local legs: { Leg } = {}
for _, info in { { "R", 1 }, { "L", -1 } } do
	local thigh, shin, foot = bones["B_Thigh" .. info[1]], bones["B_Shin" .. info[1]], bones["B_Foot" .. info[1]]
	if thigh and shin and foot and thigh.parent == bones.B_Hips then
		local v1 = thigh.C0:VectorToWorldSpace(shin.C0.Position)
		local v2 = (thigh.C0 * shin.C0):VectorToWorldSpace(foot.C0.Position)
		table.insert(legs, {
			side = info[2],
			thigh = thigh,
			shin = shin,
			foot = foot,
			pivot = thigh.C0.Position,
			L1 = math.max(math.sqrt(v1.Y * v1.Y + v1.Z * v1.Z), 0.1),
			L2 = math.max(math.sqrt(v2.Y * v2.Y + v2.Z * v2.Z), 0.1),
			a1 = math.atan2(-v1.Z, -v1.Y),
			a2 = math.atan2(-v2.Z, -v2.Y),
			dx = v1.X + v2.X,
			restAnkle = foot.restRel.Position,
		})
	end
end

-- Arms
local ARM = {
	[1] = { sh = bones.B_ShoulderR, el = bones.B_ElbowR, ha = bones.B_HandR, sb = bones.B_SaberR, n = "R" },
	[-1] = { sh = bones.B_ShoulderL, el = bones.B_ElbowL, ha = bones.B_HandL, sb = bones.B_SaberL, n = "L" },
}
local ARM_NAMES = {
	[1] = { "B_ShoulderR", "B_ElbowR", "B_HandR", "B_SaberR" },
	[-1] = { "B_ShoulderL", "B_ElbowL", "B_HandL", "B_SaberL" },
}

-- Cape rows (B_Cape1 = top .. B_CapeN = hem)
local capeRows: { BoneRec } = {}
for i = 1, 8 do
	local rec = bones["B_Cape" .. i]
	if not rec then
		break
	end
	capeRows[i] = rec
end

local headRec, chestRec, hipsRec = bones.B_Head, bones.B_Chest, bones.B_Hips
local patchRec, lidRec = bones.B_Patch, bones.B_UltLid

-- Points the scripts reach for (all fixed to a bone)
local POINTS = {
	hiltR = { hipsRec, attachmentOn(hipsRec, "HiltGripR") },
	hiltL = { hipsRec, attachmentOn(hipsRec, "HiltGripL") },
	spareL = { hipsRec, attachmentOn(hipsRec, "SpareGrip3") },
	eye = { headRec, attachmentOn(headRec, "UltimateEyeAttachment") },
	mouth = { headRec, attachmentOn(headRec, "MouthCenter") },
	chest = { chestRec, attachmentOn(chestRec, "ChestCenter") },
}
local function point(name: string): Vector3?
	local p = POINTS[name]
	if p and p[1] and p[2] then
		return (p[1].rel * p[2]).Position
	end
	return nil
end

-- The left cape clasp (what the right hand grabs) and the patch, in their bones' space.
local claspLocal: CFrame? = nil
do
	local clasp = model:FindFirstChild("Cape_ClaspL", true)
	if clasp and clasp:IsA("BasePart") and chestRec then
		claspLocal = chestRec.part.CFrame:ToObjectSpace(clasp.CFrame)
	end
end

-- Prop groups: parts whose name starts with Group_ (toggled with LocalTransparencyModifier).
local GROUP_NAMES = { "SaberR", "SaberL", "HiltR", "HiltL", "Spare1", "Spare2", "Spare3", "Spare4", "Cape", "Patch" }
local groupParts: { [string]: { BasePart } } = {}
for _, g in GROUP_NAMES do
	groupParts[g] = {}
end
local allVisualParts: { BasePart } = {}
for _, d in model:GetDescendants() do
	if d:IsA("BasePart") and d ~= hrp and not isBoneName(d.Name) and d.Name ~= "Hitbox" then
		table.insert(allVisualParts, d)
		local g = string.match(d.Name, "^(%a+%d?)_")
		if g and groupParts[g] then
			table.insert(groupParts[g], d)
			if (g == "HiltR" or g == "HiltL") and d.Transparency >= 0.99 then
				d.Transparency = 0 -- sheathed hilts ship hidden; this client shows them when sheathed
				d.LocalTransparencyModifier = 1
			end
		end
	end
end

-- =============================================================================================
-- 4. Poses, FK, leg IK, arm IK
-- =============================================================================================
local BODY = {
	"B_Hips", "B_Spine", "B_Chest", "B_Neck", "B_Head",
	"B_ShoulderR", "B_ElbowR", "B_HandR", "B_SaberR",
	"B_ShoulderL", "B_ElbowL", "B_HandL", "B_SaberL",
}
local rotAcc: { [string]: Vector3 } = {}
local posAcc: { [string]: Vector3 } = {}

-- Everything else one frame of animation decides.
local F = {
	feet = { [1] = V0, [-1] = V0 },
	footPitch = { [1] = 0, [-1] = 0 },
	look = nil :: Vector3?,
	lookW = 0,
	suppress = 0,
	reach = { [1] = nil :: any, [-1] = nil :: any }, -- { target = Vector3 (root space), w, pole }
	corr = I, -- visual root correction (scripted paths)
	patch = nil :: any, -- eyepatch follow { w }
	capeBoost = V0, -- extra cape swing (x = back flare, z = side)
	lid = 0, -- Ultimate Eye lid (0 closed, 1 open)
	trail = { [1] = 0, [-1] = 0 },
	tremble = 0,
	sustainShake = 0,
	vis = {} :: { [string]: boolean }, -- group visibility overrides for this frame
	dissolve = 0,
}

local function resetFrame()
	for _, n in BODY do
		rotAcc[n] = V0
		posAcc[n] = V0
	end
	F.feet[1], F.feet[-1] = V0, V0
	F.footPitch[1], F.footPitch[-1] = 0, 0
	F.look = nil
	F.lookW = 0
	F.reach[1], F.reach[-1] = nil, nil
	F.patch = nil
	F.capeBoost = V0
	F.trail[1], F.trail[-1] = 0, 0
	F.tremble = 0
	F.sustainShake = 0
	table.clear(F.vis)
end
resetFrame()

local function rot(name: string, rx: number, ry: number, rz: number, w: number)
	rotAcc[name] += Vector3.new(rx, ry, rz) * (RAD * w)
end

local function move(name: string, x: number, y: number, z: number, w: number)
	posAcc[name] += Vector3.new(x, y, z) * (S * w)
end

local function g3(a, i: number): number
	return if a and a[i] then a[i] else 0
end

-- Adds a pose (see Poses module) with weight w.
local function applyPose(p, w: number)
	if not p or w <= 0 then
		return
	end
	local hips = p.hips
	if hips then
		rot("B_Hips", g3(hips, 1), g3(hips, 2), g3(hips, 3), w)
		move("B_Hips", g3(hips, 4), g3(hips, 5), g3(hips, 6), w)
	end
	for key, bone in { spine = "B_Spine", chest = "B_Chest", neck = "B_Neck", head = "B_Head" } do
		local r = p[key]
		if r then
			rot(bone, g3(r, 1), g3(r, 2), g3(r, 3), w)
		end
	end
	for _, side in { 1, -1 } do
		local a = p[if side == 1 then "R" else "L"]
		if a then
			local names = ARM_NAMES[side]
			if a.sh then
				rot(names[1], g3(a.sh, 1), g3(a.sh, 2) * side, g3(a.sh, 3) * side, w)
			end
			if a.el then
				rot(names[2], a.el, 0, 0, w)
			end
			if a.wr then
				rot(names[3], g3(a.wr, 1), g3(a.wr, 2) * side, g3(a.wr, 3) * side, w)
			end
			if a.sb then
				rot(names[4], g3(a.sb, 1), g3(a.sb, 2) * side, g3(a.sb, 3) * side, w)
			end
		end
		local f = p[if side == 1 then "fR" else "fL"]
		if f then
			F.feet[side] += Vector3.new(g3(f, 1) * side, g3(f, 2), g3(f, 3)) * (S * w)
			F.footPitch[side] += g3(f, 4) * RAD * w
		end
	end
end

local function pose(name: string)
	return Poses[name]
end

-- Keyframes: { { time, poseName, ease? }, ... }. The ease belongs to the segment ENDING at that key:
-- nil smooth, "out" snaps out (cuts), "in" accelerates into the key (impacts), "lin" linear.
local function playKeys(keys, t: number, w: number)
	local n = #keys
	if n == 0 or w <= 0 then
		return
	end
	if t <= keys[1][1] then
		applyPose(pose(keys[1][2]), w)
		return
	end
	if t >= keys[n][1] then
		applyPose(pose(keys[n][2]), w)
		return
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
	elseif e == "in" then
		u = easeIn(u, 2.2)
	elseif e ~= "lin" then
		u = smoother(u)
	end
	applyPose(pose(a[2]), w * (1 - u))
	applyPose(pose(b[2]), w * u)
end

local function setT(rec: BoneRec?, T: CFrame)
	if rec then
		rec.T = T
		rec.dirty = true
	end
end

local function solveFK()
	for _, rec in boneList do
		rec.rel = rec.parent.rel * rec.C0 * rec.T
	end
end

local function composeBody()
	for _, n in BODY do
		local rec = bones[n]
		if rec then
			local r, p = rotAcc[n], posAcc[n]
			local T = CFrame.Angles(r.X, r.Y, r.Z)
			if p ~= V0 then
				T = CFrame.new(p) * T
			end
			if rec == hipsRec and F.corr ~= I then
				T = rec.C0inv * F.corr * rec.C0 * T
			end
			setT(rec, T)
		end
	end
end

local function solveLegs()
	local hipsRel = hipsRec.parent.rel * hipsRec.C0 * hipsRec.T
	local hr = rotAcc.B_Hips
	for _, leg in legs do
		local target = F.corr * (leg.restAnkle + F.feet[leg.side])
		local d = hipsRel:PointToObjectSpace(target) - leg.pivot
		local thigh, shin, roll, shinAbs = solveLegIK(leg, d)
		setT(leg.thigh, CFrame.Angles(thigh, 0, roll))
		setT(leg.shin, CFrame.Angles(shin, 0, 0))
		setT(leg.foot, CFrame.Angles(F.footPitch[leg.side] - shinAbs - hr.X, 0, -(hr.Z + roll)))
	end
end

-- Two-bone arm IK: the wrist reaches `target` (root space), the elbow bends toward `pole`.
local function solveArm(side: number, req)
	local a = ARM[side]
	local sh, el, ha = a.sh, a.el, a.ha
	if not (sh and el and ha) then
		return
	end
	local Sframe = sh.parent.rel * sh.C0
	local Sp = Sframe.Position
	local L1 = el.C0.Position.Magnitude
	local L2 = ha.C0.Position.Magnitude
	local toT = req.target - Sp
	local dist = toT.Magnitude
	if dist < 1e-3 then
		return
	end
	local u = toT / dist
	local d = math.clamp(dist, math.abs(L1 - L2) + 0.05, L1 + L2 - 0.02)
	local pole = req.pole or Vector3.new(side * 0.6, -1, 0.4)
	local pd = pole - u * pole:Dot(u)
	if pd.Magnitude < 1e-3 then
		pd = Vector3.new(0, -1, 0) - u * (-u.Y)
	end
	pd = pd.Unit
	local along = (L1 * L1 - L2 * L2 + d * d) / (2 * d)
	local h = math.sqrt(math.max(L1 * L1 - along * along, 0))
	local E = Sp + u * along + pd * h
	local P = Sp + u * d
	-- shoulder: rest (upper arm, bend direction) -> desired
	local upLocal = el.C0.Position.Unit
	local bendLocal = Vector3.new(0, 0, -1) - upLocal * (-upLocal.Z)
	local upDes = (E - Sp).Unit
	local fore = P - E
	local bendDes = fore - upDes * fore:Dot(upDes)
	if bendDes.Magnitude < 1e-3 then
		bendDes = pd
	end
	local Mloc = frameFrom(upLocal, bendLocal)
	local Mdes = frameFrom(upDes, bendDes.Unit)
	local Tsh = Sframe.Rotation:Inverse() * Mdes * Mloc:Inverse()
	-- elbow: swing the forearm onto the target
	local Ef = Sframe * Tsh * el.C0
	local foreLocal = ha.C0.Position.Unit
	local want = Ef:VectorToObjectSpace(fore.Unit)
	local axis = foreLocal:Cross(want)
	local angle = math.acos(math.clamp(foreLocal:Dot(want), -1, 1))
	local Tel = if axis.Magnitude > 1e-5 then CFrame.fromAxisAngle(axis.Unit, angle) else I
	local w = clamp01(req.w)
	setT(sh, blendPose(sh.T, Tsh, w))
	setT(el, blendPose(el.T, Tel, w))
end

-- =============================================================================================
-- 5. Base layer: stances, walk, run, breathing
-- =============================================================================================
local gait = {
	phase = 0,
	walkW = 0,
	run = 0,
	speed = 0,
	moveDir = Vector3.new(0, 0, -1),
	lastVel = V0,
	accel = V0,
	turn = 0,
	lastPlant = { [1] = 0, [-1] = 0 },
}
local springs = {
	armR = newSpring(1.9, 0.45),
	armL = newSpring(1.9, 0.45),
	body = newSpring(3.2, 0.35), -- body drop on landings
	chest = newSpring(3.0, 0.35), -- flinch when hit
	head = newSpring(2.6, 0.35),
}
local look = { yaw = 0, pitch = 0 }

local playSound -- forward declarations
local footDust: ((Vector3) -> ())? = nil
local enraged = false
local visualRoot = hrp.CFrame
local drawnVisual = false -- this frame's "sabers in hand" (attribute + action overrides)

local function impulse(spring: Spring, v: Vector3)
	spring.v += v
end

local function evalBase(dt: number, clock: number, baseW: number, dead: boolean)
	local cf = hrp.CFrame
	local lv = cf:VectorToObjectSpace(hrp.AssemblyLinearVelocity)
	if hrp.Anchored then
		lv = V0
	end
	local flatV = Vector3.new(lv.X, 0, lv.Z)
	local speed = flatV.Magnitude / S
	local turn = if hrp.Anchored then 0 else math.abs(hrp.AssemblyAngularVelocity.Y)
	local acc = (lv - gait.lastVel) / math.max(dt, 1 / 240)
	gait.lastVel = lv
	gait.accel = gait.accel:Lerp(acc, math.min(1, dt * 8))
	gait.turn = approach(gait.turn, turn, 6, dt)

	local moving = clamp01((speed - 0.8) / 4)
	local turning = clamp01((gait.turn - 1) / 2) * 0.5
	local want = if dead then 0 else math.max(moving, turning)
	gait.walkW = approach(gait.walkW, want, if want > gait.walkW then 8 else 5, dt)
	gait.run = approach(gait.run, clamp01((speed - 15) / 8), 4, dt)
	if speed > 0.8 then
		gait.moveDir = gait.moveDir:Lerp(flatV.Unit, math.min(1, dt * 10))
		if gait.moveDir.Magnitude > 1e-3 then
			gait.moveDir = gait.moveDir.Unit
		end
	end
	local run = gait.run
	local stepLen = lerp(2.3, 4.4, run) * S
	local cadence = math.clamp(speed * S / (2 * stepLen), 0, 3.2)
	if turning > moving then
		cadence = math.max(cadence, 1.6)
	end
	if gait.walkW > 0.01 then
		gait.phase = (gait.phase + dt * cadence) % 1
	end
	gait.speed = speed

	local w = gait.walkW * baseW
	local half = if cadence > 0.05 then math.min(speed * S / (4 * cadence), stepLen * 0.5) else 0
	half *= moving
	local p = gait.phase
	local s1, c1 = math.sin(TAU * p), math.cos(TAU * p)
	local c2 = math.cos(2 * TAU * p)

	-- feet: stance slides back under the body, swing lifts and carries forward
	local stanceFrac = lerp(0.55, 0.38, run)
	for _, side in { 1, -1 } do
		local q = (p + (if side == 1 then 0 else 0.5)) % 1
		local along, lift, pitch
		if q < stanceFrac then
			along = lerp(1, -1, q / stanceFrac)
			lift, pitch = 0, 0
		else
			local u = (q - stanceFrac) / (1 - stanceFrac)
			along = lerp(-1, 1, smooth(u))
			local arc = math.sin(math.pi * u)
			lift = arc * (0.4 + 0.9 * run) * S
			pitch = (arc * 16 - (1 - u) * 14 * (1 + run)) * RAD
		end
		F.feet[side] += gait.moveDir * (along * half * w) + Vector3.new(0, lift * w, 0)
		F.footPitch[side] += pitch * w
		if q < 0.05 and clock - gait.lastPlant[side] > 0.25 and w > 0.4 then
			gait.lastPlant[side] = clock
			impulse(springs.body, Vector3.new(0, -(0.6 + 1.2 * run) * w * S, 0))
			if footDust and run > 0.3 then
				for _, leg in legs do
					if leg.side == side then
						footDust(cf:PointToWorldSpace(leg.restAnkle + gait.moveDir * (half * w)))
					end
				end
			end
		end
	end

	-- hips and torso: a measured military walk, a hard forward lean when he sprints
	local bob = -(0.05 + 0.07 * (0.5 + 0.5 * c2)) * (1 + 1.6 * run)
	move("B_Hips", s1 * 0.06, bob, 0, w)
	rot("B_Hips", 0, c1 * (6 + 4 * run), -s1 * 3, w)
	rot("B_Chest", 0, -c1 * (7 + 5 * run), s1 * 1.5, w)
	rot("B_Head", 1.5 * c2, c1 * 3, 0, w)

	-- stances
	local idleW = baseW * (1 - gait.walkW)
	local walkW = w * (1 - run)
	local runW = w * run
	if drawnVisual then
		applyPose(pose("guard"), idleW)
		applyPose(pose("walkArms"), walkW)
	else
		applyPose(pose("attention"), idleW)
	end
	applyPose(pose("run"), runW)

	-- arm swing through a spring (smaller with sabers in hand)
	local amp = (if drawnVisual then 10 else 22) * (1 - run) + 26 * run
	local swing = -c1 * amp
	local ar = stepSpring(springs.armR, Vector3.new(swing, 0, 0) * w, dt)
	local al = stepSpring(springs.armL, Vector3.new(-swing, 0, 0) * w, dt)
	rot("B_ShoulderR", ar.X, 0, 0, 1)
	rot("B_ShoulderL", al.X, 0, 0, 1)
	rot("B_ElbowR", math.max(0, ar.X) * 0.6 + 10 * w * (1 - run), 0, 0, 1)
	rot("B_ElbowL", math.max(0, al.X) * 0.6 + 10 * w * (1 - run), 0, 0, 1)

	-- breathing, slow and controlled (faster in phase 2)
	local breathRate = 1 / 4.2 * (if enraged then 1.4 else 1)
	local b = math.sin(clock * TAU * breathRate)
	local bw = baseW * (1 - 0.6 * gait.walkW)
	move("B_Chest", 0, 0.03 * b, 0, bw)
	rot("B_Chest", 1.0 * b, 0, 0, bw)
	rot("B_Head", -0.6 * b, 0, 0, bw)

	-- idle life: almost nothing moves (he is utterly composed); the blades turn a little
	rot("B_Head", noise(clock * 0.15, 1.3) * 2, noise(clock * 0.11, 2.1) * 4, 0, idleW)
	if drawnVisual then
		rot("B_HandR", noise(clock * 0.3, 4.1) * 4, 0, noise(clock * 0.27, 4.7) * 6, idleW)
		rot("B_HandL", noise(clock * 0.3, 5.1) * 4, 0, noise(clock * 0.27, 5.7) * 6, idleW)
	end
end

local function applySecondary(dt: number)
	local drop = stepSpring(springs.body, V0, dt)
	posAcc.B_Hips += Vector3.new(0, math.clamp(drop.Y, -1.2 * S, 0.5 * S), 0)
	rotAcc.B_Spine += Vector3.new(drop.Y * 0.1 / S, 0, 0)
	rotAcc.B_Chest += stepSpring(springs.chest, V0, dt)
	rotAcc.B_Head += stepSpring(springs.head, V0, dt)
end

-- =============================================================================================
-- 6. Cape cloth, eyelid, eyepatch follow, prop groups
-- =============================================================================================
local cape = {
	state = {} :: { { a: number, va: number, s: number, vs: number } },
	lastPos = hrp.Position,
	lastYaw = 0,
	vel = V0,
	yawRate = 0,
}
for i = 1, #capeRows do
	cape.state[i] = { a = 0, va = 0, s = 0, vs = 0 }
end
local CAPE_SHARE = { 0.22, 0.3, 0.26, 0.22 }

local function solveCape(dt: number, clock: number)
	if #capeRows == 0 then
		return
	end
	-- velocity of the drawn body (follows scripted paths too)
	local vr = visualRoot
	local vel = (vr.Position - cape.lastPos) / math.max(dt, 1 / 240)
	cape.lastPos = vr.Position
	if vel.Magnitude > 200 then
		vel = V0
	end
	cape.vel = cape.vel:Lerp(vel, math.min(1, dt * 10))
	local _, yaw = vr:ToEulerAnglesYXZ()
	local dyaw = math.atan2(math.sin(yaw - cape.lastYaw), math.cos(yaw - cape.lastYaw))
	cape.lastYaw = yaw
	cape.yawRate = approach(cape.yawRate, dyaw / math.max(dt, 1 / 240), 8, dt)
	local lv = vr:VectorToObjectSpace(cape.vel) / S
	local fwd = -lv.Z
	local flare = math.clamp(fwd / 26, -0.25, 1.35) * 62 * RAD + math.clamp(-lv.Y / 30, -0.3, 0.8) * 40 * RAD
	flare += math.clamp(math.abs(lv.X) / 30, 0, 0.6) * 18 * RAD
	local side = math.clamp(-cape.yawRate * 0.1 + lv.X / 40, -0.7, 0.7)
	local flutter = 0.03 + 0.14 * clamp01(math.abs(fwd) / 20)
	-- keep the cape hanging under gravity whatever the torso does
	local up = chestRec.rel.UpVector
	local chestPitch = math.atan2(up.Z, up.Y)
	local chestRoll = math.atan2(-up.X, up.Y)
	local boost = F.capeBoost
	for i, rec in capeRows do
		local st = cape.state[i]
		local share = CAPE_SHARE[i] or 0.2
		local aT = flare * share + boost.X * share + noise(clock * (1.6 + 0.4 * i), 11 + i) * flutter * (0.5 + 0.3 * i)
		local sT = side * share + boost.Z * share + noise(clock * (1.3 + 0.3 * i), 21 + i) * flutter * 0.5
		if i == 1 then
			aT += chestPitch
			sT -= chestRoll
			aT = math.max(aT, chestPitch + 2 * RAD) -- never swings forward into his legs
		end
		-- damped springs, sub-stepped
		local f, z = 2.1 - 0.15 * i, 0.32
		local wN = TAU * f
		local n = math.max(1, math.ceil(dt * 240))
		local h = dt / n
		for _ = 1, n do
			st.va += ((aT - st.a) * wN * wN - st.va * 2 * z * wN) * h
			st.a += st.va * h
			st.vs += ((sT - st.s) * wN * wN - st.vs * 2 * z * wN) * h
			st.s += st.vs * h
		end
		st.a = math.clamp(st.a, -1.2, 1.9)
		st.s = math.clamp(st.s, -1.2, 1.2)
		setT(rec, CFrame.Angles(-st.a, 0, st.s))
	end
end

local lidOpen = 0
local function solveLid(dt: number)
	lidOpen = approach(lidOpen, F.lid, if F.lid > lidOpen then 14 else 10, dt)
	if lidRec then
		setT(lidRec, CFrame.Angles(lidOpen * 88 * RAD, 0, 0))
	end
end

-- The eyepatch rides the left hand while he tears it off.
local patchGrab: CFrame? = nil
local function solvePatch()
	if not patchRec then
		return
	end
	local req = F.patch
	local hand = ARM[-1].ha
	if not req or req.w <= 0 or not hand then
		patchGrab = nil
		setT(patchRec, I)
		return
	end
	if not patchGrab then
		patchGrab = hand.rel:Inverse() * patchRec.rel
	end
	local want = hand.rel * patchGrab
	local T = (patchRec.parent.rel * patchRec.C0):Inverse() * want
	setT(patchRec, blendPose(I, T, req.w))
end

local groupShown: { [string]: number } = {}
local function applyGroups(base: { [string]: boolean })
	for _, gname in GROUP_NAMES do
		local on = F.vis[gname]
		if on == nil then
			on = base[gname]
		end
		local ltm = if on then F.dissolve else 1
		if groupShown[gname] ~= ltm then
			groupShown[gname] = ltm
			for _, p in groupParts[gname] do
				p.LocalTransparencyModifier = ltm
			end
		end
	end
end

local lastDissolve = 0
local function applyDissolve()
	if F.dissolve == lastDissolve then
		return
	end
	lastDissolve = F.dissolve
	for _, p in allVisualParts do
		local g = string.match(p.Name, "^(%a+%d?)_")
		if not (g and groupParts[g]) then
			p.LocalTransparencyModifier = F.dissolve
		end
	end
end

-- =============================================================================================
-- 7. Visual effects library (built-in textures only)
-- =============================================================================================
local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"

local C_STEEL = Color3.fromRGB(226, 240, 255)
local C_SLASH = Color3.fromRGB(196, 228, 255)
local C_RED = Color3.fromRGB(255, 34, 46)
local C_DARKRED = Color3.fromRGB(90, 0, 10)
local C_DUST = Color3.fromRGB(150, 140, 126)
local C_GOLD = Color3.fromRGB(255, 214, 120)

local function slashColor(): Color3
	return if enraged then Color3.fromRGB(255, 70, 78) else C_SLASH
end

local vfxFolder = Instance.new("Folder")
vfxFolder.Name = "KingBradleyVFX"
vfxFolder.Parent = workspace

local function NS(...): NumberSequence
	local a = { ... }
	if #a == 1 then
		return NumberSequence.new(a[1])
	end
	local kps = {}
	for i = 1, #a, 2 do
		table.insert(kps, NumberSequenceKeypoint.new(a[i], a[i + 1]))
	end
	return NumberSequence.new(kps)
end

local function CS(...): ColorSequence
	local a = { ... }
	if #a == 1 then
		return ColorSequence.new(a[1])
	end
	local kps = {}
	for i = 1, #a, 2 do
		table.insert(kps, ColorSequenceKeypoint.new(a[i], a[i + 1]))
	end
	return ColorSequence.new(kps)
end

local function NR(a: number, b: number?): NumberRange
	return NumberRange.new(a, b or a)
end

local function assign(inst: Instance, props)
	for k, v in props do
		local ok = pcall(function()
			(inst :: any)[k] = v
		end)
		if not ok then
			log("skipped property", inst.ClassName, k)
		end
	end
end

local function fxPart(props): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	assign(p, props)
	p.Parent = vfxFolder
	return p
end

local function makeEmitter(parent: Instance, props): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.Rate = 0
	e.LightInfluence = 0
	assign(e, props)
	e.Parent = parent
	return e
end

type Fx = { age: number, life: number, inst: { Instance }, update: (number, number, number) -> () }
local liveFx: { Fx } = {}

local function addFx(life: number, inst: { Instance }, update)
	for _, i in inst do
		Debris:AddItem(i, life + 3)
	end
	table.insert(liveFx, { age = 0, life = life, inst = inst, update = update })
end

local function stepFx(dt: number)
	for i = #liveFx, 1, -1 do
		local fx = liveFx[i]
		fx.age += dt
		local done = fx.age >= fx.life
		if not done then
			local ok, err = pcall(fx.update, fx.age, fx.age / fx.life, dt)
			if not ok then
				warn("[Bradley] effect error: " .. tostring(err))
				done = true
			end
		end
		if done then
			for _, inst in fx.inst do
				inst:Destroy()
			end
			table.remove(liveFx, i)
		end
	end
end

local function burst(cf: CFrame, size: Vector3, count: number, props, life: number?)
	local p = fxPart({ Size = size, Transparency = 1, CFrame = cf })
	local e = makeEmitter(p, props)
	e:Emit(count)
	Debris:AddItem(p, life or 4)
	return p, e
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
pcall(function()
	rayParams.RespectCanCollide = true
end)
local function refreshRayFilter()
	local list: { Instance } = { model, vfxFolder }
	for _, plr in Players:GetPlayers() do
		if plr.Character then
			table.insert(list, plr.Character)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

local function groundAt(pos: Vector3, depth: number?): (Vector3, Color3, Enum.Material)
	refreshRayFilter()
	local hit = workspace:Raycast(pos + Vector3.new(0, 4 * S, 0), Vector3.new(0, -(depth or 30) * S, 0), rayParams)
	if not hit then
		return pos, C_DUST, Enum.Material.Slate
	end
	local color, material = C_DUST, Enum.Material.Slate
	local inst = hit.Instance
	if inst:IsA("Terrain") then
		material = hit.Material
		local ok, c = pcall(function()
			return (inst :: Terrain):GetMaterialColor(hit.Material)
		end)
		if ok and typeof(c) == "Color3" then
			color = c
		end
	elseif inst:IsA("BasePart") then
		color, material = inst.Color, inst.Material
	end
	return hit.Position, color, material
end

-- Expanding ring of segments. vertical = ring faces cf.LookVector; otherwise it lies flat.
local function shockRing(cf: CFrame, vertical: boolean, r0: number, r1: number, life: number, color: Color3, material: Enum.Material, thick: number, height: number, segs: number, tr0: number)
	local parts = {}
	for i = 1, segs do
		parts[i] = fxPart({ Color = color, Material = material, Size = Vector3.one * 0.2, Transparency = tr0 })
	end
	local function update(_age, u)
		local e = 1 - (1 - u) ^ 3
		local r = r0 + (r1 - r0) * e
		local seg = TAU * r / segs * 1.12
		local h = height * (1 - 0.65 * u)
		local th = thick * (1 - 0.4 * u)
		local tr = tr0 + (1 - tr0) * u ^ 1.6
		for i, p in parts do
			local a = (i - 1) / segs * TAU
			if vertical then
				p.Size = Vector3.new(th, seg, h)
				p.CFrame = cf * CFrame.Angles(0, 0, a) * CFrame.new(r, 0, 0)
			else
				p.Size = Vector3.new(th, h, seg)
				p.CFrame = cf * CFrame.Angles(0, a, 0) * CFrame.new(r, 0, 0)
			end
			p.Transparency = tr
		end
	end
	update(0, 0)
	addFx(life, parts, update)
end

local function dustBurst(pos: Vector3, color: Color3, count: number, speed: number, size: number)
	burst(CFrame.new(pos), Vector3.new(4, 0.5, 4) * S, count, {
		Texture = TEX_SMOKE,
		Color = CS(color),
		Size = NS(0, size * 0.5 * S, 0.4, size * S, 1, size * 1.6 * S),
		Transparency = NS(0, 0.35, 0.6, 0.6, 1, 1),
		Lifetime = NR(0.8, 1.6),
		Speed = NR(speed * 0.5 * S, speed * S),
		SpreadAngle = Vector2.new(82, 82),
		EmissionDirection = Enum.NormalId.Top,
		Drag = 3.5,
		Acceleration = Vector3.new(0, 2.5 * S, 0),
		Rotation = NR(0, 360),
		RotSpeed = NR(-40, 40),
		LightInfluence = 0.6,
	}, 4)
end

footDust = function(ankle: Vector3)
	local cam = workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - ankle).Magnitude > 110 * S then
		return
	end
	local g, color = groundAt(ankle, 10)
	burst(CFrame.new(g), Vector3.new(1.6, 0.3, 1.6) * S, 4, {
		Texture = TEX_SMOKE,
		Color = CS(color:Lerp(C_DUST, 0.6)),
		Size = NS(0, 0.6 * S, 1, 1.6 * S),
		Transparency = NS(0, 0.5, 1, 1),
		Lifetime = NR(0.4, 0.7),
		Speed = NR(2 * S, 4 * S),
		SpreadAngle = Vector2.new(85, 85),
		EmissionDirection = Enum.NormalId.Top,
		Drag = 4,
		LightInfluence = 0.6,
	}, 2)
end

local function sparks(pos: Vector3, color: Color3, count: number, speed: number)
	burst(CFrame.new(pos), Vector3.one * 0.5 * S, count, {
		Texture = TEX_SPARK,
		Color = CS(color),
		LightEmission = 1,
		Size = NS(0, 0.5 * S, 1, 0),
		Transparency = NS(0, 0, 1, 1),
		Lifetime = NR(0.2, 0.5),
		Speed = NR(speed * 0.4 * S, speed * S),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 5,
	}, 2)
end

local function debrisBurst(pos: Vector3, count: number, color: Color3, material: Enum.Material, power: number)
	local chunks, state = {}, {}
	for i = 1, count do
		local sz = (0.3 + math.random() * 0.7) * S
		chunks[i] = fxPart({
			Size = Vector3.new(sz, sz * (0.6 + math.random() * 0.5), sz * (0.7 + math.random() * 0.5)),
			Color = color:Lerp(Color3.new(0, 0, 0), math.random() * 0.35),
			Material = material,
		})
		local a = math.random() * TAU
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		state[i] = {
			pos = pos + out * (0.5 + math.random() * 1.5) * S,
			vel = out * (power * (0.4 + math.random() * 0.6)) + Vector3.new(0, power * (0.8 + math.random() * 0.8), 0),
			spin = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 16,
			rot = CFrame.Angles(math.random() * TAU, math.random() * TAU, 0),
			rest = false,
		}
	end
	local g = workspace.Gravity * 0.55
	addFx(2.2, chunks, function(_age, u, dt)
		for i, p in chunks do
			local st = state[i]
			if not st.rest then
				st.vel += Vector3.new(0, -g * dt, 0)
				st.pos += st.vel * dt
				st.rot = st.rot * CFrame.Angles(st.spin.X * dt, st.spin.Y * dt, st.spin.Z * dt)
				if st.pos.Y < pos.Y + p.Size.Y * 0.4 and st.vel.Y < 0 then
					st.pos = Vector3.new(st.pos.X, pos.Y + p.Size.Y * 0.4, st.pos.Z)
					st.vel = Vector3.new(st.vel.X * 0.45, -st.vel.Y * 0.3, st.vel.Z * 0.45)
					st.spin *= 0.5
					if st.vel.Magnitude < 3 then
						st.rest = true
					end
				end
			end
			p.CFrame = CFrame.new(st.pos) * st.rot
			p.Transparency = smooth(progress(0.7, 1, u))
		end
	end)
end

-- Dark cracks radiating from a point, flush with the ground.
local function crackMarks(pos: Vector3, radius: number, color: Color3)
	local parts = {}
	local n = 9
	for i = 1, n do
		local a = (i / n) * TAU + math.random() * 0.4
		local len = radius * (0.5 + math.random() * 0.5)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		parts[i] = fxPart({
			Size = Vector3.new(0.25 * S, 0.06 * S, len),
			Color = color:Lerp(Color3.new(0, 0, 0), 0.75),
			CFrame = CFrame.lookAt(pos + dir * len * 0.5 + Vector3.new(0, 0.03 * S, 0), pos + dir * len + Vector3.new(0, 0.03 * S, 0)),
		})
	end
	addFx(6, parts, function(_age, u)
		for _, p in parts do
			p.Transparency = smooth(progress(0.75, 1, u))
		end
	end)
end

-- Anime slash: a crescent in the XY plane of cf, swept from angle a0 to a1 (radians) about Z.
local function slashArc(cf: CFrame, radius: number, a0: number, a1: number, width: number, color: Color3, life: number, sweep: number?)
	local segs = 14
	local parts = {}
	for i = 1, segs do
		parts[i] = fxPart({ Color = color, Material = Enum.Material.Neon, Transparency = 1, Size = Vector3.one * 0.1 })
	end
	local sw = sweep or 0.07
	addFx(life, parts, function(age, u)
		local reveal = clamp01(age / sw)
		local fade = smooth(progress(0.25, 1, u))
		for i, p in parts do
			local k = (i - 0.5) / segs
			if k > reveal then
				p.Transparency = 1
			else
				local a = a0 + (a1 - a0) * k
				local thick = width * math.sin(math.pi * k) ^ 0.7 * (1 - 0.5 * fade)
				local len = math.abs(a1 - a0) * radius / segs * 1.25
				local r = radius * (1 + 0.15 * u)
				p.Size = Vector3.new(math.max(thick, 0.05), math.max(len, 0.05), 0.06 * S)
				p.CFrame = cf * CFrame.Angles(0, 0, a) * CFrame.new(r, 0, 0)
				p.Transparency = 0.05 + 0.95 * fade + (1 - k / math.max(reveal, 1e-3)) * 0.0
			end
		end
	end)
end

-- Thin straight cut hanging in the air between a and b.
local function slashLine(a: Vector3, b: Vector3, width: number, color: Color3, life: number, holdGlow: number?)
	local len = (b - a).Magnitude
	if len < 0.05 then
		return nil
	end
	local core = fxPart({ Color = Color3.new(1, 1, 1), Material = Enum.Material.Neon, Size = Vector3.new(width * 0.35, width * 0.35, len), CFrame = CFrame.lookAt((a + b) / 2, b) })
	local glow = fxPart({ Color = color, Material = Enum.Material.Neon, Transparency = 0.45, Size = Vector3.new(width, width, len * 1.02), CFrame = core.CFrame })
	local hold = holdGlow or 0
	addFx(life, { core, glow }, function(age, u)
		local f = if age < hold then 0 else smooth(progress(hold, life, age))
		core.Transparency = f
		glow.Transparency = 0.45 + 0.55 * f
		local pulse = 1 + 0.25 * math.sin(age * 30) * (if age < hold then 1 else 0)
		glow.Size = Vector3.new(width * pulse * (1 - 0.5 * f), width * pulse * (1 - 0.5 * f), len * 1.02)
	end)
	return core, glow
end

-- Bright four-point glint (blade gleam / eye flare), always facing the camera.
local function glint(pos: Vector3, size: number, color: Color3, life: number)
	local holder = fxPart({ Size = Vector3.one * 0.1, Transparency = 1, CFrame = CFrame.new(pos) })
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(size * S, size * S)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = true
	gui.Adornee = holder
	gui.Parent = holder
	local bars = {}
	for i, r in { 0, 90, 45, 135 } do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = if i <= 2 then UDim2.fromScale(1, 0.06) else UDim2.fromScale(0.5, 0.04)
		f.Rotation = r
		f.BorderSizePixel = 0
		f.BackgroundColor3 = if i <= 2 then Color3.new(1, 1, 1) else color
		f.Parent = gui
		bars[i] = f
	end
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromScale(0.18, 0.18)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = dot
	dot.Parent = gui
	addFx(life, { holder }, function(_age, u)
		local k = math.sin(math.pi * clamp01(u)) ^ 0.6
		gui.Size = UDim2.fromScale(size * S * (0.3 + 0.9 * k), size * S * (0.3 + 0.9 * k))
		for i, f in bars do
			f.BackgroundTransparency = 1 - k
			f.Rotation = (if i <= 2 then 0 else 45) + (if i % 2 == 0 then 90 else 0) + u * 40
		end
		dot.BackgroundTransparency = 1 - k
	end)
end

-- A neon silhouette of his body where it is right now (afterimages of his speed).
local GHOST_NAMES = {
	"Skull", "HairCap", "Neck", "Chest", "Back", "Abdomen", "Pelvis",
	"DeltoidR", "UpperArmR", "ForearmR", "PalmR", "DeltoidL", "UpperArmL", "ForearmL", "PalmL",
	"ThighR", "BlousedR", "BootFootR", "ThighL", "BlousedL", "BootFootL",
	"SaberR_Blade2", "SaberR_Blade4", "SaberR_Blade6", "SaberL_Blade2", "SaberL_Blade4", "SaberL_Blade6",
}
local ghostSources: { BasePart } = {}
for _, n in GHOST_NAMES do
	local p = model:FindFirstChild(n, true)
	if p and p:IsA("BasePart") then
		table.insert(ghostSources, p)
	end
end

local function copyShape(src: BasePart, props): BasePart
	local p = Instance.new(src.ClassName) :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = src.Size
	p.CFrame = src.CFrame
	if src:IsA("Part") and p:IsA("Part") then
		p.Shape = src.Shape
	end
	local mesh = src:FindFirstChildOfClass("SpecialMesh")
	if mesh then
		mesh:Clone().Parent = p
	end
	p.Color = src.Color
	p.Material = src.Material
	p.Reflectance = src.Reflectance
	assign(p, props or {})
	p.Parent = vfxFolder
	return p
end

local function afterimage(color: Color3, life: number, alpha: number)
	local cam = workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - hrp.Position).Magnitude > 200 * S then
		return
	end
	local parts = {}
	for _, src in ghostSources do
		if src.LocalTransparencyModifier < 0.5 then
			table.insert(parts, copyShape(src, { Color = color, Material = Enum.Material.Neon, Transparency = alpha }))
		end
	end
	addFx(life, parts, function(_age, u)
		for _, p in parts do
			p.Transparency = alpha + (1 - alpha) * u
		end
	end)
end

-- Copies of a prop group as free parts (thrown saber, the cape, the eyepatch). Returns the parts and
-- their offsets from `origin` so the copy can be moved as one rigid body.
local function propCopy(group: string, origin: CFrame): ({ BasePart }, { CFrame })
	local parts, offsets = {}, {}
	for _, src in groupParts[group] or {} do
		if src.Transparency < 0.99 then
			local p = copyShape(src)
			table.insert(parts, p)
			table.insert(offsets, origin:ToObjectSpace(src.CFrame))
		end
	end
	return parts, offsets
end

local function placeCopy(parts: { BasePart }, offsets: { CFrame }, cf: CFrame, transparency: number?)
	for i, p in parts do
		p.CFrame = cf * offsets[i]
		if transparency then
			p.Transparency = transparency
		end
	end
end

-- Camera shake (trauma), applied around the camera scripts so it never drifts.
local shake = { trauma = 0, sustain = 0, applied = I, seed = math.random() * 1000 }

local function addShake(amount: number, worldPos: Vector3, near: number, far: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local d = (cam.CFrame.Position - worldPos).Magnitude
	local f = 1 - progress(near * S, far * S, d)
	shake.trauma = math.min(1.3, shake.trauma + amount * f)
end

local SHAKE_KEY = "BradleyShake_" .. tostring(math.random(1, 1e9))
local function shakeUndo()
	local cam = workspace.CurrentCamera
	if cam and shake.applied ~= I then
		cam.CFrame = cam.CFrame * shake.applied:Inverse()
	end
	shake.applied = I
end
local function shakeApply(dt: number)
	shake.trauma = math.max(0, shake.trauma - dt * 1.5)
	local level = math.max(shake.trauma, shake.sustain)
	local cam = workspace.CurrentCamera
	if level < 0.002 or not cam then
		return
	end
	local k = level * level
	local tt = os.clock() * 24
	local sd = shake.seed
	local off = CFrame.new(noise(tt, sd) * 0.4 * k, noise(tt, sd + 1) * 0.4 * k, 0)
		* CFrame.Angles(noise(tt, sd + 2) * 2.4 * RAD * k, noise(tt, sd + 3) * 2.4 * RAD * k, noise(tt, sd + 4) * 3 * RAD * k)
	cam.CFrame = cam.CFrame * off
	shake.applied = off
end

local soundsCfg = Config.Sounds
playSound = function(key: string, volume: number?, pitch: number?, parent: Instance?): Sound?
	local id = type(soundsCfg) == "table" and soundsCfg[key] or nil
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = "Bradley" .. key
	s.SoundId = id
	s.Volume = volume or 1
	s.PlaybackSpeed = pitch or 1
	s.RollOffMinDistance = 15 * S
	s.RollOffMaxDistance = 240 * S
	s.Parent = parent or hrp
	s:Play()
	Debris:AddItem(s, 12)
	return s
end

-- Blade trails and the Ultimate Eye's light (created once, toggled every frame).
local trails: { [number]: Trail } = {}
for _, side in { 1, -1 } do
	local rec = ARM[side].sb
	if rec then
		local a0 = rec.part:FindFirstChild("BladeBase")
		local a1 = rec.part:FindFirstChild("BladeTip")
		if a0 and a1 then
			local tr = Instance.new("Trail")
			tr.Name = "BradleyBladeTrail"
			tr.Attachment0 = a0
			tr.Attachment1 = a1
			tr.Lifetime = 0.16
			tr.MinLength = 0.05
			tr.LightEmission = 0.8
			tr.LightInfluence = 0
			tr.FaceCamera = false
			tr.Transparency = NS(0, 0.15, 1, 1)
			tr.Color = CS(C_SLASH)
			tr.Enabled = false
			tr.Parent = rec.part
			trails[side] = tr
		end
	end
end

local eyeFx = { light = nil :: PointLight?, trail = nil :: Trail?, gui = nil :: SurfaceGui?, on = false }
do
	local a = headRec and headRec.part:FindFirstChild("UltimateEyeAttachment")
	local ta = headRec and headRec.part:FindFirstChild("UltimateEyeTrailA")
	local tb = headRec and headRec.part:FindFirstChild("UltimateEyeTrailB")
	if a then
		local light = Instance.new("PointLight")
		light.Color = C_RED
		light.Range = 5 * S
		light.Brightness = 3
		light.Shadows = false
		light.Enabled = false
		light.Parent = a
		eyeFx.light = light
	end
	if ta and tb then
		local tr = Instance.new("Trail")
		tr.Attachment0 = ta
		tr.Attachment1 = tb
		tr.Lifetime = 0.32
		tr.MinLength = 0.02
		tr.WidthScale = NS(0, 1, 1, 0.2)
		tr.LightEmission = 1
		tr.LightInfluence = 0
		tr.FaceCamera = true
		tr.Transparency = NS(0, 0, 1, 1)
		tr.Color = CS(Color3.fromRGB(255, 90, 90), C_RED)
		tr.Enabled = false
		tr.Parent = headRec.part
		eyeFx.trail = tr
	end
	local mark = model:FindFirstChild("UltimateMark", true)
	if mark then
		eyeFx.gui = mark:FindFirstChildOfClass("SurfaceGui")
	end
end

-- =============================================================================================
-- 8. Actions
-- =============================================================================================
type ActionRec = {
	name: string,
	id: any,
	start: number,
	speed: number,
	cfg: any,
	keys: any,
	fired: { [string]: boolean },
	w: number,
	t: number,
	real: number,
	endAt: number?,
	target: Vector3?,
	victim: number,
	pathStr: string?,
	path: any,
	data: any,
}
local actions: { ActionRec } = {}
local lastActionId: any = nil
local deathRec: ActionRec? = nil

local FADE = {
	Draw = { 0.2, 0.35 },
	Sheathe = { 0.2, 0.4 },
	RemoveCape = { 0.2, 0.4 },
	RemoveEyepatch = { 0.25, 0.45 },
	Lunge = { 0.1, 0.3 },
	CrossCut = { 0.1, 0.3 },
	SaberThrow = { 0.12, 0.3 },
	Cleave = { 0.1, 0.35 },
	ThousandCuts = { 0.15, 0.4 },
	PhantomStep = { 0.15, 0.4 },
	Death = { 0.15, 0 },
}
local SUPPRESS = {
	Draw = 0.9, Sheathe = 0.9, RemoveCape = 0.85, RemoveEyepatch = 0.9, Lunge = 1, CrossCut = 1,
	SaberThrow = 1, Cleave = 1, ThousandCuts = 1, PhantomStep = 1, Death = 1,
}
local SETUP, EVAL, STOP = {}, {}, {}

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

-- True once, when t passes `at`. Stale events (joined late) are only marked as done.
local function fire(rec: ActionRec, key: string, at: number, t: number): boolean
	if rec.fired[key] or t < at then
		return false
	end
	rec.fired[key] = true
	return t - at < 0.5
end

local function lookAt(p: Vector3?, w: number)
	if p and w > F.lookW then
		F.look = p
		F.lookW = w
	end
end

local function reach(side: number, target: Vector3?, w: number, pole: Vector3?)
	if target and w > 0.001 then
		F.reach[side] = { target = target, w = w, pole = pole }
	end
end

local function boneWorld(rec: BoneRec?): CFrame
	return hrp.CFrame * (if rec then rec.rel else I)
end

local function bladeWorld(side: number, along: number): Vector3
	local rec = ARM[side].sb
	if not rec then
		return hrp.Position
	end
	-- along: 0 = guard, 1 = tip (the blade runs down the saber bone's -Z)
	return (hrp.CFrame * rec.rel * CFrame.new(0, 0.03 * along, -(0.45 + 3.8 * along) * S)).Position
end

-- The visual root (path-corrected) and its flat look direction.
local function vrLook(): Vector3
	local l = visualRoot.LookVector
	local f = Vector3.new(l.X, 0, l.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

local function groundUnder(): number
	local feetY = visualRoot.Position.Y - (if humanoid then humanoid.HipHeight else 4 * S) - hrp.Size.Y / 2
	return feetY
end

local function victimRoot(rec: ActionRec): BasePart?
	if rec.victim and rec.victim ~= 0 then
		local plr = Players:GetPlayerByUserId(rec.victim)
		local ch = plr and plr.Character
		local root = ch and ch:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root
		end
	end
	return nil
end

-- A cut in front of him: a crescent in a plane tilted by `tilt` degrees (0 = horizontal sweep).
local function frontSlash(tilt: number, flip: boolean, radius: number, width: number, height: number?, color: Color3?)
	local base = CFrame.new(visualRoot.Position + Vector3.new(0, (height or 0.6) * S, 0)) * CFrame.Angles(0, select(2, visualRoot:ToEulerAnglesYXZ()), 0)
	local cf = base * CFrame.Angles(math.pi / 2, 0, 0) * CFrame.Angles(0, tilt * RAD, 0)
	local a0, a1 = -math.pi * 0.95, -math.pi * 0.05
	if flip then
		a0, a1 = a1, a0
	end
	slashArc(cf, radius * S, a0, a1, width * S, color or slashColor(), 0.32, 0.06)
end

-- ---------------------------------------------------------------------------------------------
-- Draw: right hand to the left hilt, left hand to the right hilt, both blades out, a flourish
-- ---------------------------------------------------------------------------------------------
SETUP.Draw = function(rec)
	local c = rec.cfg
	local D = c.Duration or 2.1
	local at = c.DrawAt or 0.5
	rec.keys = { { 0, "drawReach" }, { at - 0.05, "drawReach" }, { at + 0.22, "drawOut", "out" }, { at + 0.6, "flourish" }, { D - 0.45, "guard" }, { D, "guard" } }
end
EVAL.Draw = function(rec, t, w)
	local c = rec.cfg
	local at = c.DrawAt or 0.5
	playKeys(rec.keys, t, w)
	local rw = envelope(t, 0.05, at - 0.12, at, at + 0.12) * w
	reach(1, point("hiltL"), rw, Vector3.new(0.5, -1, -0.6))
	reach(-1, point("hiltR"), rw, Vector3.new(-0.5, -1, -0.6))
	local out = t >= at
	F.vis.SaberR, F.vis.SaberL = out, out
	F.vis.HiltR, F.vis.HiltL = not out, not out
	-- the right blade twirls once in the flourish
	local spin = smoother(progress(at + 0.35, at + 0.8, t))
	rot("B_SaberR", -360 * spin, 0, 0, w)
	F.trail[1] = envelope(t, at, at + 0.05, at + 0.9, at + 1.0)
	F.trail[-1] = envelope(t, at, at + 0.05, at + 0.35, at + 0.45)
	lookAt(rec.target, w)
	if fire(rec, "draw", at, t) then
		playSound("Unsheathe", 1)
		for _, side in { 1, -1 } do
			sparks(bladeWorld(side, 0.1), C_GOLD, 6, 10)
		end
	end
	if fire(rec, "gleam", at + 0.75, t) then
		glint(bladeWorld(1, 0.9), 3, C_STEEL, 0.35)
	end
end

SETUP.Sheathe = function(rec)
	local c = rec.cfg
	local D = c.Duration or 1.8
	local at = c.SheatheAt or 0.85
	rec.keys = { { 0, "guard" }, { at - 0.15, "drawReach" }, { at + 0.1, "drawReach" }, { D, "attention" } }
end
EVAL.Sheathe = function(rec, t, w)
	local c = rec.cfg
	local at = c.SheatheAt or 0.85
	playKeys(rec.keys, t, w)
	local rw = envelope(t, at - 0.45, at - 0.1, at + 0.05, at + 0.3) * w
	reach(1, point("hiltL"), rw, Vector3.new(0.5, -1, -0.6))
	reach(-1, point("hiltR"), rw, Vector3.new(-0.5, -1, -0.6))
	local inHand = t < at
	F.vis.SaberR, F.vis.SaberL = inHand, inHand
	F.vis.HiltR, F.vis.HiltL = not inHand, not inHand
	if fire(rec, "click", at, t) then
		playSound("Unsheathe", 0.7, 0.8)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Remove Cape: grabs it at the left shoulder, rips it off and flings it to his right
-- ---------------------------------------------------------------------------------------------
local function flingCape()
	local origin = chestRec and boneWorld(chestRec) or hrp.CFrame
	local parts, offsets = propCopy("Cape", origin)
	if #parts == 0 then
		return
	end
	local vr = visualRoot
	local state = {
		cf = origin,
		vel = vr.RightVector * (26 * S) + Vector3.new(0, 16 * S, 0) + vr.LookVector * (4 * S),
		spin = vr.LookVector * 3.2 + Vector3.new(0, 1.5, 0),
		landed = false,
	}
	local groundY = groundUnder()
	local life = 9
	addFx(life, parts, function(age, u, dt)
		if not state.landed then
			state.vel += Vector3.new(0, -workspace.Gravity * 0.32 * dt, 0)
			state.vel *= math.exp(-1.6 * dt)
			local pos = state.cf.Position + state.vel * dt
			local axis = state.spin
			local rotStep = if axis.Magnitude > 1e-3 then CFrame.fromAxisAngle(axis.Unit, axis.Magnitude * dt) else I
			local flutter = CFrame.Angles(math.sin(age * 9) * 0.04, 0, math.cos(age * 7) * 0.05)
			state.cf = CFrame.new(pos) * rotStep * state.cf.Rotation * flutter
			if pos.Y < groundY + 1.2 * S and age > 0.3 then
				state.landed = true
			end
		else
			-- settles flat on the floor
			local flat = CFrame.new(state.cf.Position.X, groundY + 0.6 * S, state.cf.Position.Z) * CFrame.Angles(-math.pi / 2, select(2, state.cf:ToEulerAnglesYXZ()), 0)
			state.cf = state.cf:Lerp(flat, math.min(1, dt * 3))
		end
		placeCopy(parts, offsets, state.cf, smooth(progress(life - 2, life, age)))
	end)
end

SETUP.RemoveCape = function(rec)
	local c = rec.cfg
	local D = c.Duration or 2.4
	local rel = c.ReleaseAt or 0.9
	rec.keys = { { 0, "guard" }, { rel - 0.4, "capeGrab" }, { rel - 0.3, "capeGrab" }, { rel + 0.08, "capeRip", "out" }, { rel + 0.45, "capeRip" }, { D, "guard" } }
end
EVAL.RemoveCape = function(rec, t, w)
	local c = rec.cfg
	local rel = c.ReleaseAt or 0.9
	playKeys(rec.keys, t, w)
	if claspLocal and chestRec then
		local target = (chestRec.rel * claspLocal).Position + Vector3.new(0.05, 0.25, -0.1) * S
		reach(1, target, envelope(t, 0.1, rel - 0.35, rel - 0.22, rel - 0.05) * w, Vector3.new(1, -0.6, 0.2))
	end
	-- the hand drags the cape up and out to his right before letting go
	local pull = envelope(t, rel - 0.32, rel - 0.08, rel - 0.02, rel + 0.02)
	F.capeBoost = Vector3.new(70 * RAD, 0, -55 * RAD) * pull
	F.vis.Cape = t < rel
	F.trail[1] = envelope(t, rel - 0.2, rel - 0.1, rel + 0.2, rel + 0.3) * 0.6
	lookAt(rec.target, w * 0.7)
	if fire(rec, "rip", rel, t) then
		playSound("CapeTear", 1)
		flingCape()
		dustBurst(visualRoot.Position - Vector3.new(0, 4 * S, 0) + visualRoot.RightVector * 3 * S, C_DUST, 8, 6, 2)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Remove Eyepatch: tears it off, flicks it away, the Ultimate Eye opens
-- ---------------------------------------------------------------------------------------------
local function tossPatch()
	if not patchRec then
		return
	end
	local origin = boneWorld(patchRec)
	local parts, offsets = propCopy("Patch", origin)
	if #parts == 0 then
		return
	end
	local vr = visualRoot
	local st = { cf = origin, vel = -vr.RightVector * (14 * S) + Vector3.new(0, 10 * S, 0) + vr.LookVector * (3 * S) }
	local groundY = groundUnder()
	addFx(5, parts, function(age, _u, dt)
		if st.cf.Position.Y > groundY + 0.05 * S then
			st.vel += Vector3.new(0, -workspace.Gravity * 0.5 * dt, 0)
			st.cf = CFrame.new(st.cf.Position + st.vel * dt) * st.cf.Rotation * CFrame.Angles(9 * dt, 5 * dt, 0)
		end
		placeCopy(parts, offsets, st.cf, smooth(progress(4, 5, age)))
	end)
end

local function eyeBurst(rec: ActionRec)
	local eye = point("eye")
	local eyeW = if eye then hrp.CFrame * eye else hrp.Position + Vector3.new(0, 3.3 * S, 0)
	glint(eyeW, 9, C_RED, 0.6)
	glint(eyeW, 4, Color3.new(1, 1, 1), 0.25)
	local base = CFrame.new(Vector3.new(visualRoot.Position.X, groundUnder() + 0.2 * S, visualRoot.Position.Z))
	shockRing(base, false, 2 * S, (rec.cfg.ShockRadius or 26) * S, 0.7, C_RED, Enum.Material.Neon, 0.35 * S, 0.5 * S, 30, 0.05)
	shockRing(base, false, 1 * S, 18 * S, 0.9, C_DARKRED, Enum.Material.SmoothPlastic, 0.6 * S, 1.6 * S, 26, 0.3)
	shockRing(CFrame.lookAt(eyeW, eyeW + visualRoot.LookVector), true, 0.3 * S, 9 * S, 0.45, C_RED, Enum.Material.Neon, 0.12 * S, 0.12 * S, 24, 0)
	local g, color = groundAt(visualRoot.Position, 12)
	dustBurst(g, color, 16, 14, 3)
	crackMarks(g, 9 * S, color)
	burst(CFrame.new(visualRoot.Position), Vector3.new(3, 6, 3) * S, 40, {
		Texture = TEX_FIRE,
		Color = CS(C_RED, C_DARKRED),
		LightEmission = 0.8,
		Size = NS(0, 1.2 * S, 1, 0),
		Transparency = NS(0, 0.2, 1, 1),
		Lifetime = NR(0.4, 0.9),
		Speed = NR(10 * S, 24 * S),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 3,
	}, 2)
	addShake(1.0, eyeW, 25, 110)
end

-- dark red aura that rises off him while the eye awakens
local function auraEmitter(life: number)
	if not chestRec then
		return
	end
	local p = fxPart({ Size = Vector3.new(2.6, 5, 1.6) * S, Transparency = 1, CFrame = boneWorld(chestRec) })
	local e = makeEmitter(p, {
		Texture = TEX_FIRE,
		Color = CS(C_RED, C_DARKRED),
		LightEmission = 0.6,
		Size = NS(0, 1.4 * S, 1, 0.2 * S),
		Transparency = NS(0, 0.4, 1, 1),
		Lifetime = NR(0.5, 0.9),
		Speed = NR(2 * S, 5 * S),
		Acceleration = Vector3.new(0, 10 * S, 0),
		SpreadAngle = Vector2.new(30, 30),
		Rate = 60,
		Enabled = true,
	})
	addFx(life, { p }, function(_age, u)
		p.CFrame = boneWorld(chestRec) * CFrame.new(0, -1 * S, 0)
		e.Rate = 60 * (1 - u)
	end)
end

SETUP.RemoveEyepatch = function(rec)
	local c = rec.cfg
	local D = c.Duration or 4
	local tear = c.TearAt or 1.05
	local open = c.OpenAt or 2.15
	rec.keys = {
		{ 0, "guard" },
		{ tear - 0.4, "patchRaise" },
		{ tear - 0.05, "patchRaise" },
		{ tear + 0.2, "patchTear", "out" },
		{ open - 0.4, "psLock" },
		{ open, "eyeOpen", "out" },
		{ D - 0.6, "eyeOpen" },
		{ D, "guard" },
	}
end
EVAL.RemoveEyepatch = function(rec, t, w)
	local c = rec.cfg
	local tear = c.TearAt or 1.05
	local open = c.OpenAt or 2.15
	playKeys(rec.keys, t, w)
	-- left hand to the patch (the wrist stops a little in front of the face)
	local eye = point("eye")
	if eye then
		local target = eye + headRec.rel:VectorToWorldSpace(Vector3.new(-0.1, -0.05, -0.32) * S)
		reach(-1, target, envelope(t, 0.15, tear - 0.4, tear - 0.02, tear + 0.15) * w, Vector3.new(-1, -0.8, 0.3))
	end
	-- the patch rides the hand from the grip until the flick
	local release = tear + 0.25
	if t >= tear - 0.18 and t < release then
		F.patch = { w = smooth(progress(tear - 0.18, tear - 0.08, t)) }
	end
	F.vis.Patch = t < release
	-- head bows while the eye is closed, then snaps up when it opens
	local bow = envelope(t, release, open - 0.5, open - 0.08, open + 0.05)
	rot("B_Head", -16 * bow, 0, 0, w)
	F.tremble = math.max(F.tremble, 0.6 * envelope(t, open - 0.8, open - 0.4, open - 0.05, open))
	F.lid = if t >= open then 1 else 0
	if fire(rec, "tear", tear, t) then
		playSound("PatchTear", 1)
	end
	if fire(rec, "toss", release, t) then
		tossPatch()
	end
	if fire(rec, "open", open, t) then
		playSound("EyeOpen", 1)
		playSound("Voice", 1)
		eyeBurst(rec)
		auraEmitter((c.Duration or 4) - open + 0.5)
	end
	lookAt(rec.target, w * 0.6)
end

-- ---------------------------------------------------------------------------------------------
-- Lunge
-- ---------------------------------------------------------------------------------------------
SETUP.Lunge = function(rec)
	local c = rec.cfg
	local d0, d1 = c.Dash[1], c.Dash[2]
	rec.keys = { { 0, "guard" }, { d0 - 0.15, "lungeWind" }, { d0 - 0.02, "lungeWind" }, { d0 + 0.08, "lungeThrust", "out" }, { d1, "lungeThrust" }, { d1 + 0.25, "lungeRecover" }, { c.Duration, "guard" } }
end
EVAL.Lunge = function(rec, t, w)
	local c = rec.cfg
	local d0, d1 = c.Dash[1], c.Dash[2]
	playKeys(rec.keys, t, w)
	F.trail[1] = envelope(t, d0 - 0.05, d0, d1 + 0.1, d1 + 0.2)
	F.trail[-1] = F.trail[1] * 0.5
	F.tremble = math.max(F.tremble, 0.25 * envelope(t, d0 - 0.4, d0 - 0.25, d0 - 0.05, d0))
	if t < d0 then
		lookAt(rec.target, w)
	end
	if fire(rec, "gleam", d0 - 0.3, t) then
		glint(bladeWorld(1, 0.95), 3.2, C_STEEL, 0.3)
	end
	if fire(rec, "dash", d0, t) then
		playSound("Lunge", 1)
		local g, color = groundAt(visualRoot.Position, 12)
		dustBurst(g, color, 10, 12, 2.2)
		rec.data.from = visualRoot.Position
	end
	if t >= d0 and t <= d1 + 0.05 and rec.data.from then
		local n = rec.data.ghosts or 0
		if t >= d0 + n * 0.06 and n < 4 then
			rec.data.ghosts = n + 1
			afterimage(slashColor(), 0.3, 0.55)
		end
	end
	if fire(rec, "line", d1, t) and rec.data.from then
		local a = rec.data.from + Vector3.new(0, 0.4 * S, 0)
		local b = visualRoot.Position + Vector3.new(0, 0.4 * S, 0)
		slashLine(a, b, 0.35 * S, slashColor(), 0.55, 0.12)
		local g, color = groundAt(visualRoot.Position, 12)
		dustBurst(g, color, 8, 9, 2)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Cross Cut
-- ---------------------------------------------------------------------------------------------
SETUP.CrossCut = function(rec)
	local h = rec.cfg.Hits
	local D = rec.cfg.Duration
	rec.keys = {
		{ 0, "guard" },
		{ h[1] - 0.12, "ccRaise" },
		{ h[1] + 0.02, "ccCut1", "out" },
		{ h[2] - 0.12, "ccCut1" },
		{ h[2] + 0.02, "ccCut2", "out" },
		{ h[3] - 0.14, "ccX" },
		{ h[3] + 0.03, "ccXCut", "out" },
		{ h[3] + 0.3, "ccXCut" },
		{ D, "guard" },
	}
end
EVAL.CrossCut = function(rec, t, w)
	local h = rec.cfg.Hits
	playKeys(rec.keys, t, w)
	F.trail[1] = envelope(t, h[1] - 0.06, h[1] - 0.02, h[1] + 0.06, h[1] + 0.12) + envelope(t, h[3] - 0.06, h[3] - 0.02, h[3] + 0.08, h[3] + 0.14)
	F.trail[-1] = envelope(t, h[2] - 0.06, h[2] - 0.02, h[2] + 0.06, h[2] + 0.12) + envelope(t, h[3] - 0.06, h[3] - 0.02, h[3] + 0.08, h[3] + 0.14)
	if t < h[1] then
		lookAt(rec.target, w)
	end
	if fire(rec, "h1", h[1], t) then
		playSound("Slash", 1, 1.05)
		frontSlash(-40, false, 5.5, 0.55)
	end
	if fire(rec, "h2", h[2], t) then
		playSound("Slash", 1, 0.95)
		frontSlash(40, true, 5.5, 0.55)
	end
	if fire(rec, "h3", h[3], t) then
		playSound("Slash", 1.2, 0.85)
		frontSlash(-48, false, 6.5, 0.7)
		frontSlash(48, true, 6.5, 0.7)
		sparks(visualRoot.Position + vrLook() * 4 * S, C_STEEL, 10, 16)
		addShake(0.25, visualRoot.Position, 15, 60)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Saber Throw
-- ---------------------------------------------------------------------------------------------
local spareHiddenUntil = 0
local function throwSaber(rec: ActionRec)
	local sb = ARM[-1].sb
	if not sb then
		return
	end
	local origin = boneWorld(sb)
	local parts, offsets = propCopy("SaberL", origin)
	if #parts == 0 then
		return
	end
	local impact = rec.target or (origin.Position + vrLook() * 40 * S)
	local start = origin.Position
	local dir = impact - start
	local dist = dir.Magnitude
	if dist < 0.5 then
		dir = vrLook()
		dist = 1
	else
		dir = dir.Unit
	end
	local speed = (rec.cfg.Speed or 150) * S
	local flight = dist / speed
	local stuckGrip = impact - dir * (3.6 * S)
	local life = flight + 6
	local landed = false
	addFx(life, parts, function(age)
		if age < flight then
			local p = start:Lerp(stuckGrip, age / flight)
			placeCopy(parts, offsets, CFrame.lookAt(p, p + dir) * CFrame.Angles(0, 0, age * 40))
		else
			if not landed then
				landed = true
				local g, color, material = groundAt(impact, 6)
				sparks(impact, C_STEEL, 12, 18)
				dustBurst(g, color, 8, 8, 1.8)
				debrisBurst(g, 6, color, material, 14 * S)
				shockRing(CFrame.new(g + Vector3.new(0, 0.1 * S, 0)), false, 0.5 * S, 6 * S, 0.35, Color3.new(1, 1, 1), Enum.Material.Neon, 0.15 * S, 0.2 * S, 18, 0.2)
				playSound("Impact", 0.6, 1.4, nil)
			end
			placeCopy(parts, offsets, CFrame.lookAt(stuckGrip, stuckGrip + dir), smooth(progress(life - 1.2, life, age)))
		end
	end)
	-- a streak behind it
	slashLine(start, impact, 0.12 * S, slashColor(), flight + 0.25, flight)
end

SETUP.SaberThrow = function(rec)
	local c = rec.cfg
	local rl = c.ReleaseAt
	local r0, r1 = c.Redraw[1], c.Redraw[2]
	rec.keys = { { 0, "guard" }, { rl - 0.12, "throwWind" }, { rl + 0.06, "throwRelease", "out" }, { r0, "throwRelease" }, { r0 + 0.2, "throwReachBack" }, { r1 - 0.1, "throwReachBack" }, { c.Duration, "guard" } }
end
EVAL.SaberThrow = function(rec, t, w)
	local c = rec.cfg
	local rl = c.ReleaseAt
	local r0, r1 = c.Redraw[1], c.Redraw[2]
	playKeys(rec.keys, t, w)
	local grabAt = (r0 + r1) / 2
	reach(-1, point("spareL"), envelope(t, r0, r0 + 0.2, grabAt + 0.05, r1) * w, Vector3.new(-1, -0.4, 0.8))
	F.vis.SaberL = t < rl or t >= grabAt
	F.trail[-1] = envelope(t, rl - 0.12, rl - 0.06, rl, rl + 0.02)
	if t < rl then
		lookAt(rec.target, w)
	end
	if fire(rec, "release", rl, t) then
		playSound("Throw", 1, 1.1)
		throwSaber(rec)
	end
	if fire(rec, "grab", grabAt, t) then
		spareHiddenUntil = os.clock() + 9
		playSound("Unsheathe", 0.7, 1.15)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Tank Cleaver
-- ---------------------------------------------------------------------------------------------
local function fissure(from: Vector3, to: Vector3, width: number)
	local dir = to - from
	local len = dir.Magnitude
	if len < 1 then
		return
	end
	dir = dir / len
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local n = math.max(3, math.floor(len / (2.2 * S)))
	local parts = {}
	local placed = {}
	local _, color, material = groundAt(from, 10)
	for i = 1, n do
		local u = (i - 0.5) / n
		local wob = side * (math.random() - 0.5) * width * 0.25
		local p = from + dir * (len * u) + wob
		local gp = groundAt(p, 10)
		local seg = fxPart({
			Size = Vector3.new(width * 0.22 * (1 - 0.6 * u), 0.08 * S, len / n * 1.3),
			Color = color:Lerp(Color3.new(0, 0, 0), 0.8),
			Material = Enum.Material.Slate,
			CFrame = CFrame.lookAt(gp + Vector3.new(0, 0.04 * S, 0), gp + dir + Vector3.new(0, 0.04 * S, 0)),
			Transparency = 1,
		})
		local glow = fxPart({
			Size = Vector3.new(width * 0.08 * (1 - 0.6 * u), 0.1 * S, len / n * 1.25),
			Color = slashColor(),
			Material = Enum.Material.Neon,
			CFrame = seg.CFrame,
			Transparency = 1,
		})
		table.insert(parts, seg)
		table.insert(parts, glow)
		placed[i] = { seg = seg, glow = glow, at = u * 0.25, pos = gp, done = false }
	end
	addFx(5.5, parts, function(age)
		for _, s in placed do
			if age >= s.at then
				s.seg.Transparency = smooth(progress(4.5, 5.5, age))
				s.glow.Transparency = 0.1 + 0.9 * smooth(progress(s.at, s.at + 0.6, age))
				if not s.done then
					s.done = true
					if math.random() < 0.6 then
						debrisBurst(s.pos, 3, color, material, 12 * S)
					end
					dustBurst(s.pos, color, 3, 6, 1.6)
				end
			end
		end
	end)
end

SETUP.Cleave = function(rec)
	local c = rec.cfg
	local l0, imp = c.Leap[1], c.ImpactAt
	rec.keys = { { 0, "guard" }, { l0 - 0.05, "cleaveCrouch" }, { l0 + 0.15, "cleaveAir", "out" }, { imp - 0.12, "cleaveAir" }, { imp, "cleaveImpact", "in" }, { imp + 0.45, "cleaveImpact" }, { c.Duration, "guard" } }
end
EVAL.Cleave = function(rec, t, w)
	local c = rec.cfg
	local l0, imp = c.Leap[1], c.ImpactAt
	playKeys(rec.keys, t, w)
	F.trail[1] = envelope(t, imp - 0.15, imp - 0.1, imp + 0.04, imp + 0.12)
	F.trail[-1] = F.trail[1]
	F.capeBoost = Vector3.new(-25 * RAD, 0, 0) * envelope(t, l0, l0 + 0.15, imp - 0.15, imp)
	if t < l0 + 0.2 then
		lookAt(rec.target, w)
	end
	if fire(rec, "jump", l0, t) then
		local g, color = groundAt(visualRoot.Position, 12)
		dustBurst(g, color, 10, 10, 2)
		shockRing(CFrame.new(g + Vector3.new(0, 0.1 * S, 0)), false, 1 * S, 7 * S, 0.4, color, Enum.Material.SmoothPlastic, 0.4 * S, 0.5 * S, 18, 0.3)
	end
	if fire(rec, "impact", imp, t) then
		playSound("Impact", 1.2)
		playSound("Slash", 1, 0.7)
		local target = rec.target or (visualRoot.Position + vrLook() * 3 * S)
		local g, color, material = groundAt(target, 14)
		impulse(springs.body, Vector3.new(0, -5 * S, 0))
		dustBurst(g, color, 22, 16, 3.4)
		debrisBurst(g, 14, color, material, 22 * S)
		crackMarks(g, (c.Radius or 10) * S * 0.8, color)
		shockRing(CFrame.new(g + Vector3.new(0, 0.15 * S, 0)), false, 1 * S, (c.Radius or 10) * S, 0.5, Color3.new(1, 1, 1), Enum.Material.Neon, 0.25 * S, 0.35 * S, 28, 0.1)
		local fl = (c.FissureLength or 30) * S
		fissure(g, g + vrLook() * fl, (c.FissureWidth or 6) * S)
		local up = CFrame.lookAt(g + Vector3.new(0, 3 * S, 0), g + Vector3.new(0, 3 * S, 0) + vrLook())
		slashArc(up * CFrame.Angles(0, 0, math.pi / 2), 5 * S, -1.2, 1.2, 0.9 * S, slashColor(), 0.35, 0.05)
		addShake(1.1, g, 20, 110)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Ultimate Eye: Thousand Cuts
-- ---------------------------------------------------------------------------------------------
SETUP.ThousandCuts = function(rec)
	local c = rec.cfg
	local f0, f1 = c.Flurry[1], c.Flurry[2]
	local n = math.max(1, c.Slashes or 12)
	local keys = { { 0, "guard" }, { f0 - 0.45, "tcFocus" }, { f0 - 0.04, "tcFocus" } }
	local names = { "tcA", "tcB", "tcC" }
	for i = 1, n do
		local at = f0 + (f1 - f0) * (i - 0.5) / n
		table.insert(keys, { at, names[(i - 1) % 3 + 1], "out" })
	end
	table.insert(keys, { c.FinalAt - 0.16, "tcCross" })
	table.insert(keys, { c.FinalAt, "tcRelease", "out" })
	table.insert(keys, { c.Recover[1] + 0.2, "tcRelease" })
	table.insert(keys, { c.Duration, "guard" })
	rec.keys = keys
	rec.data.n = n
end

local function crossWave(rec: ActionRec)
	local c = rec.cfg
	local origin = visualRoot.Position
	local finish = rec.target or (origin + vrLook() * (c.WaveLength or 80) * S)
	local dir = finish - origin
	dir = Vector3.new(dir.X, 0, dir.Z)
	local len = dir.Magnitude
	if len < 1 then
		return
	end
	dir = dir / len
	local speed = (c.WaveSpeed or 130) * S
	local travel = len / speed
	local width = (c.WaveWidth or 9) * S
	local gY = groundUnder()
	local parts = {}
	local arms = {}
	for k = 1, 2 do
		local list = {}
		for i = 1, 10 do
			local p = fxPart({ Color = if i % 2 == 0 then Color3.new(1, 1, 1) else slashColor(), Material = Enum.Material.Neon, Size = Vector3.one * 0.2, Transparency = 0.1 })
			table.insert(parts, p)
			list[i] = p
		end
		arms[k] = list
	end
	local lastCrack = 0
	local _, color = groundAt(origin, 12)
	addFx(travel + 0.35, parts, function(age, _u)
		local u = math.min(age / travel, 1)
		local center = origin + dir * (len * u)
		center = Vector3.new(center.X, gY + width * 0.55, center.Z)
		local face = CFrame.lookAt(center, center + dir)
		local fade = smooth(progress(travel, travel + 0.35, age))
		for k, list in arms do
			local tilt = if k == 1 then 45 else -45
			for i, p in list do
				local s = (i - 0.5) / #list
				local along = (s - 0.5) * width * 1.4
				local thick = 0.9 * S * math.sin(math.pi * s) ^ 0.6
				p.Size = Vector3.new(thick, width * 1.4 / #list * 1.2, 0.3 * S)
				p.CFrame = face * CFrame.Angles(0, 0, tilt * RAD) * CFrame.new(0, along, -0.2 * S * math.cos(math.pi * s))
				p.Transparency = 0.1 + 0.9 * fade
			end
		end
		if len * u - lastCrack > 5 * S and u < 1 then
			lastCrack = len * u
			local g = Vector3.new(center.X, gY, center.Z)
			dustBurst(g, color, 4, 8, 2)
			local seg = fxPart({ Size = Vector3.new(width * 0.3, 0.06 * S, 5.5 * S), Color = color:Lerp(Color3.new(0, 0, 0), 0.8), CFrame = CFrame.lookAt(g + Vector3.new(0, 0.03 * S, 0), g + dir + Vector3.new(0, 0.03 * S, 0)) })
			addFx(5, { seg }, function(a2)
				seg.Transparency = smooth(progress(4, 5, a2))
			end)
		end
	end)
end

EVAL.ThousandCuts = function(rec, t, w, dt)
	local c = rec.cfg
	local f0, f1 = c.Flurry[1], c.Flurry[2]
	local n = rec.data.n
	playKeys(rec.keys, t, w)
	F.lid = 1
	local flurry = envelope(t, f0 - 0.05, f0, f1, f1 + 0.05)
	F.trail[1] = math.max(flurry, envelope(t, c.FinalAt - 0.08, c.FinalAt - 0.03, c.FinalAt + 0.06, c.FinalAt + 0.12))
	F.trail[-1] = F.trail[1]
	F.capeBoost = Vector3.new(30 * RAD * flurry, 0, 18 * RAD * math.sin(t * 40) * flurry)
	if t < f0 then
		lookAt(rec.target, w)
	end
	if fire(rec, "focus", 0.12, t) then
		local eye = point("eye")
		glint(if eye then hrp.CFrame * eye else hrp.Position, 7, C_RED, 0.5)
		playSound("EyeOpen", 0.6, 1.3)
	end
	for i = 1, n do
		local at = f0 + (f1 - f0) * (i - 0.5) / n
		if fire(rec, "s" .. i, at, t) then
			playSound("Slash", 0.7, 0.9 + math.random() * 0.4)
			local tilt = math.random(-70, 70)
			frontSlash(tilt, i % 2 == 0, 4 + math.random() * 3, 0.5, 0.4 + math.random() * 1.6)
			if i % 2 == 0 then
				afterimage(slashColor(), 0.25, 0.6)
			end
			if i % 3 == 0 then
				sparks(visualRoot.Position + vrLook() * 4 * S + Vector3.new(0, 1 * S, 0), C_STEEL, 6, 14)
			end
		end
	end
	if fire(rec, "final", c.FinalAt, t) then
		playSound("Wave", 1)
		playSound("Slash", 1.2, 0.7)
		frontSlash(-45, false, 7, 1.0, 0.8)
		frontSlash(45, true, 7, 1.0, 0.8)
		crossWave(rec)
		addShake(0.9, visualRoot.Position, 20, 100)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Ultimate Eye: Phantom Step (lock-on, a pentagram of dashes, everything detonates)
-- ---------------------------------------------------------------------------------------------
local function reticle(rec: ActionRec, life: number)
	local parts = {}
	local rings = {}
	for k = 1, 3 do
		local list = {}
		for i = 1, 16 do
			local p = fxPart({ Color = C_RED, Material = Enum.Material.Neon, Size = Vector3.one * 0.1, Transparency = 0.3 })
			table.insert(parts, p)
			list[i] = p
		end
		rings[k] = list
	end
	local spokes = {}
	for i = 1, 6 do
		local p = fxPart({ Color = C_RED, Material = Enum.Material.Neon, Size = Vector3.one * 0.1, Transparency = 0.4 })
		table.insert(parts, p)
		spokes[i] = p
	end
	addFx(life, parts, function(age, u)
		local root = victimRoot(rec)
		local pos = if root then root.Position else (rec.target or visualRoot.Position)
		local g = groundAt(pos, 14)
		local fade = smooth(progress(0.85, 1, u))
		for k, list in rings do
			local r = (3 + 2.2 * k) * S * (1 - 0.35 * smooth(u)) * (1 + 0.04 * math.sin(age * 12))
			local spin = age * (if k % 2 == 0 then -2 else 1.6) * k
			for i, p in list do
				local a = (i - 1) / #list * TAU + spin
				p.Size = Vector3.new(0.12 * S, 0.06 * S, TAU * r / #list * (if k == 2 then 0.6 else 1.05))
				p.CFrame = CFrame.new(g + Vector3.new(0, 0.08 * S, 0)) * CFrame.Angles(0, a, 0) * CFrame.new(r, 0, 0)
				p.Transparency = 0.25 + 0.75 * fade
			end
		end
		for i, p in spokes do
			local a = (i - 1) / 6 * TAU - age * 0.8
			local r = 4.2 * S * (1 - 0.35 * smooth(u))
			p.Size = Vector3.new(0.1 * S, 0.06 * S, r * 0.8)
			p.CFrame = CFrame.new(g + Vector3.new(0, 0.08 * S, 0)) * CFrame.Angles(0, a, 0) * CFrame.new(0, 0, -r * 0.6)
			p.Transparency = 0.35 + 0.65 * fade
		end
	end)
end

SETUP.PhantomStep = function(rec)
	local c = rec.cfg
	local s0, s1 = c.Steps[1], c.Steps[2]
	rec.keys = { { 0, "guard" }, { 0.35, "psLock" }, { s0 - 0.04, "psLock" }, { s0 + 0.08, "psDash", "out" }, { s1 - 0.02, "psDash" }, { s1 + 0.25, "psPause" }, { c.DetonateAt + 0.15, "psPause" }, { c.Duration, "guard" } }
	rec.data.lines = {}
	rec.data.nextLine = 1
end
EVAL.PhantomStep = function(rec, t, w)
	local c = rec.cfg
	local s0, s1 = c.Steps[1], c.Steps[2]
	playKeys(rec.keys, t, w)
	F.lid = 1
	local dashing = envelope(t, s0, s0 + 0.03, s1, s1 + 0.05)
	F.trail[1] = dashing
	F.trail[-1] = dashing
	if t < s0 then
		local root = victimRoot(rec)
		lookAt(if root then root.Position else rec.target, w)
	end
	if fire(rec, "lock", 0.1, t) then
		reticle(rec, s0 + 0.2)
		local eye = point("eye")
		glint(if eye then hrp.CFrame * eye else hrp.Position, 8, C_RED, 0.55)
		playSound("EyeOpen", 0.8, 1.15)
	end
	-- the cut lines: one per chord, appearing as he finishes each dash
	local path = rec.path
	if path and t >= s0 then
		local real = rec.real
		while rec.data.nextLine + 1 <= #path - 1 do
			local i = rec.data.nextLine + 1 -- key i -> i + 1 is a cut (key 1 -> 2 is the approach)
			local a, b = path[i], path[i + 1]
			if real < b.t then
				break
			end
			rec.data.nextLine += 1
			if (b.pos - a.pos).Magnitude > 1 then
				local h = Vector3.new(0, -0.6 * S, 0)
				local core = slashLine(a.pos + h, b.pos + h, 0.3 * S, C_RED, math.max(c.DetonateAt - real + 0.5, 0.6), math.max(c.DetonateAt - real, 0))
				if core then
					table.insert(rec.data.lines, { a.pos + h, b.pos + h })
				end
				afterimage(C_RED, 0.4, 0.5)
				playSound("Slash", 0.8, 1.1 + math.random() * 0.2)
			end
		end
	end
	if fire(rec, "detonate", c.DetonateAt, t) then
		playSound("Detonate", 1.2)
		playSound("Slash", 1.2, 0.6)
		for _, l in rec.data.lines do
			local mid = (l[1] + l[2]) / 2
			slashLine(l[1], l[2], 1.2 * S, Color3.new(1, 1, 1), 0.25, 0)
			sparks(mid, C_RED, 10, 20)
			local dirv = (l[2] - l[1]).Unit
			slashArc(CFrame.lookAt(mid, mid + dirv) * CFrame.Angles(0, math.pi / 2, 0), 3 * S, -1.4, 1.4, 0.7 * S, C_RED, 0.3, 0.04)
		end
		local center = rec.target or visualRoot.Position
		local g, color = groundAt(center, 14)
		shockRing(CFrame.new(g + Vector3.new(0, 0.2 * S, 0)), false, 1 * S, (c.CoreRadius or 7) * S * 1.6, 0.5, C_RED, Enum.Material.Neon, 0.3 * S, 0.5 * S, 26, 0.05)
		dustBurst(g, color, 14, 12, 2.6)
		crackMarks(g, 8 * S, color)
		addShake(1.0, g, 20, 100)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Death: staggers, drops to one knee, lets go of his sabers, falls on his back. Then fades.
-- ---------------------------------------------------------------------------------------------
local function dropSaber(side: number)
	local sb = ARM[side].sb
	if not sb then
		return
	end
	local origin = boneWorld(sb)
	local parts, offsets = propCopy(if side == 1 then "SaberR" else "SaberL", origin)
	if #parts == 0 then
		return
	end
	local gY = groundUnder()
	local st = { cf = origin, vel = visualRoot.RightVector * side * 4 * S + Vector3.new(0, 4 * S, 0), spin = math.random() * 4 + 3 }
	addFx(7, parts, function(age, _u, dt)
		if st.cf.Position.Y > gY + 0.15 * S then
			st.vel += Vector3.new(0, -workspace.Gravity * 0.6 * dt, 0)
			st.cf = CFrame.new(st.cf.Position + st.vel * dt) * st.cf.Rotation * CFrame.Angles(st.spin * dt, 0, st.spin * 0.3 * dt)
		else
			local flat = CFrame.new(st.cf.Position.X, gY + 0.12 * S, st.cf.Position.Z) * CFrame.Angles(0, select(2, st.cf:ToEulerAnglesYXZ()), 0)
			st.cf = st.cf:Lerp(flat, math.min(1, dt * 12))
		end
		placeCopy(parts, offsets, st.cf, smooth(progress(6, 7, age)))
	end)
end

SETUP.Death = function(rec)
	rec.keys = { { 0, "guard" }, { 0.45, "deathStagger" }, { 1.3, "deathKneel", "in" }, { 2.6, "deathKneel" }, { 3.35, "deathLying", "in" }, { 99, "deathLying" } }
end
EVAL.Death = function(rec, t, w)
	playKeys(rec.keys, t, w)
	local dropped = t >= 1.25
	if dropped then
		F.vis.SaberR, F.vis.SaberL = false, false
	end
	F.lid = if enraged then 1 - smooth(progress(3.4, 4.2, t)) else 0
	if fire(rec, "voice", 0, t) then
		playSound("Death", 1)
	end
	if fire(rec, "drop", 1.25, t) then
		if drawnVisual then
			dropSaber(1)
			dropSaber(-1)
		end
		local g, color = groundAt(visualRoot.Position, 12)
		dustBurst(g, color, 8, 6, 2)
	end
	if fire(rec, "fall", 3.35, t) then
		local g, color = groundAt(visualRoot.Position + visualRoot.LookVector * -2 * S, 12)
		dustBurst(g, color, 14, 8, 2.6)
		impulse(springs.body, Vector3.new(0, -2 * S, 0))
	end
	F.dissolve = smooth(progress(5.0, 6.3, t))
end

-- =============================================================================================
-- 9. The local player: knockback, shake, screen
-- =============================================================================================
local function localCharacter(): (Model?, Humanoid?, BasePart?)
	local char = localPlayer and localPlayer.Character
	if not char then
		return nil, nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not (root and root:IsA("BasePart")) then
		return nil, nil, nil
	end
	return char, hum, root
end

local screen = { impact = 0, effect = nil :: ColorCorrectionEffect?, lines = nil :: ScreenGui?, linesOn = 0 }

local function knockFrom(center: Vector3, radius: number, power: number)
	local _c, hum, root = localCharacter()
	if not hum or not root or root.Anchored then
		return
	end
	local d = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
	local dist = d.Magnitude
	if dist > radius or math.abs(root.Position.Y - center.Y) > 10 * S then
		return
	end
	local dir = if dist > 0.1 then d / dist else vrLook()
	local f = 0.55 + 0.45 * (1 - dist / radius)
	pcall(function()
		hum:ChangeState(Enum.HumanoidStateType.Freefall)
	end)
	root.AssemblyLinearVelocity = dir * (power * f) + Vector3.new(0, 28 + 20 * f, 0)
	screen.impact = math.max(screen.impact, 0.7 * f)
end

-- Anime speed lines over the screen (built lazily, only while needed).
local function speedLines(): ScreenGui?
	if screen.lines and screen.lines.Parent then
		return screen.lines
	end
	local pg = localPlayer and localPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "BradleySpeedLines"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	for i = 1, 28 do
		local f = Instance.new("Frame")
		f.Name = "Line"
		f.AnchorPoint = Vector2.new(0, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		f.BackgroundTransparency = 1
		f.Rotation = (i / 28) * 360
		f.Size = UDim2.new(0.6, 0, 0, 2)
		f.Parent = gui
	end
	gui.Parent = pg
	screen.lines = gui
	return gui
end

local function updateSpeedLines(amount: number, color: Color3)
	screen.linesOn = approach(screen.linesOn, amount, 10, 1 / 60)
	if screen.linesOn < 0.02 then
		if screen.lines then
			screen.lines.Enabled = false
		end
		return
	end
	local gui = speedLines()
	if not gui then
		return
	end
	gui.Enabled = true
	for _, f in gui:GetChildren() do
		if f:IsA("Frame") then
			if math.random() < 0.3 then
				local inner = 0.18 + math.random() * 0.12
				f.Position = UDim2.fromScale(0.5 + math.cos(math.rad(f.Rotation)) * inner, 0.5 + math.sin(math.rad(f.Rotation)) * inner)
				f.Size = UDim2.new(0.4 + math.random() * 0.4, 0, 0, 1 + math.random() * 3)
			end
			f.BackgroundColor3 = color
			f.BackgroundTransparency = 1 - screen.linesOn * (0.35 + 0.5 * math.random())
		end
	end
end

local function localEffects(dt: number, now: number)
	local sustain = F.sustainShake
	F.sustainShake = 0
	local tint = 0
	local tintColor = Color3.fromRGB(255, 120, 130)
	local lines = 0
	local cam = workspace.CurrentCamera
	local _c, _h, myRoot = localCharacter()
	local near = 0
	if cam then
		near = 1 - progress(30 * S, 120 * S, (cam.CFrame.Position - hrp.Position).Magnitude)
	end
	for _, rec in actions do
		local t = (now - rec.start) * rec.speed
		local c = rec.cfg
		if rec.name == "Cleave" then
			if fire(rec, "knock", c.ImpactAt, t) then
				local center = rec.target or visualRoot.Position
				knockFrom(center, (c.Radius or 10) * S, c.Knockback or 75)
			end
		elseif rec.name == "RemoveEyepatch" then
			if fire(rec, "knock", c.OpenAt, t) then
				knockFrom(visualRoot.Position, (c.ShockRadius or 26) * S, c.Knockback or 65)
				screen.impact = math.max(screen.impact, near)
			end
			tint = math.max(tint, envelope(t, c.OpenAt - 0.05, c.OpenAt, c.Duration - 0.8, c.Duration) * near * 0.6)
		elseif rec.name == "ThousandCuts" then
			local focus = envelope(t, 0.05, 0.2, c.Flurry[2], c.Flurry[2] + 0.3) * rec.w
			tint = math.max(tint, focus * near)
			lines = math.max(lines, focus * near)
			if fire(rec, "impactFrame", c.FinalAt, t) then
				screen.impact = math.max(screen.impact, near)
			end
		elseif rec.name == "PhantomStep" then
			local mine = myRoot and rec.victim == (localPlayer and localPlayer.UserId)
			local lockW = envelope(t, 0.05, 0.3, c.Steps[1], c.Steps[2]) * rec.w
			tint = math.max(tint, lockW * (if mine then 1 else near * 0.6))
			if mine then
				lines = math.max(lines, lockW)
			end
			if fire(rec, "impactFrame", c.DetonateAt, t) then
				screen.impact = math.max(screen.impact, near)
			end
		elseif rec.name == "Lunge" then
			if fire(rec, "impactFrame", c.Dash[2], t) and near > 0.6 then
				screen.impact = math.max(screen.impact, 0.35)
			end
		end
	end
	shake.sustain = approach(shake.sustain, sustain, 6, dt)
	updateSpeedLines(lines, Color3.fromRGB(255, 220, 220))

	screen.impact = math.max(0, screen.impact - dt * 6)
	local imp = math.min(screen.impact, 1) ^ 2
	if (tint > 0.002 or imp > 0.002) and cam then
		local fx = screen.effect
		if not fx or fx.Parent ~= cam then
			if fx then
				fx:Destroy()
			end
			fx = Instance.new("ColorCorrectionEffect")
			fx.Name = "BradleyTint"
			fx.Parent = cam
			Debris:AddItem(fx, 15)
			screen.effect = fx
		end
		fx.TintColor = Color3.new(1, 1, 1):Lerp(tintColor, tint):Lerp(Color3.fromRGB(255, 60, 70), imp * 0.7)
		fx.Brightness = -0.06 * tint + 0.1 * imp
		fx.Contrast = 0.3 * tint + 1.0 * imp
		fx.Saturation = -0.6 * tint - 1.0 * imp
		fx.Enabled = true
	elseif screen.effect then
		screen.effect:Destroy()
		screen.effect = nil
	end
end

-- =============================================================================================
-- 10. Anime outline, hit flash, boss bar
-- =============================================================================================
local outline: Highlight? = Instance.new("Highlight")
outline.Name = "BradleyOutline"
outline.Adornee = model
outline.DepthMode = Enum.HighlightDepthMode.Occluded
outline.FillColor = Color3.new(1, 1, 1)
outline.FillTransparency = 1
outline.OutlineColor = Color3.new(0, 0, 0)
outline.OutlineTransparency = 0
outline.Parent = model

local hitFlash = 0
local OUTLINE_EYE = Color3.fromRGB(150, 0, 18)
local function stepHitFlash(dt: number)
	if not outline then
		return
	end
	local glow = if enraged and not deathRec then 0.45 + 0.4 * math.sin(os.clock() * TAU * 0.9) else 0
	outline.OutlineColor = Color3.new(0, 0, 0):Lerp(OUTLINE_EYE, glow)
	outline.OutlineTransparency = F.dissolve
	if hitFlash <= 0 then
		outline.FillTransparency = 1
		return
	end
	hitFlash = math.max(0, hitFlash - dt / 0.14)
	outline.FillTransparency = 1 - 0.65 * hitFlash
end

local function formatNumber(n: number): string
	local s = tostring(math.floor(n + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return out
end

local function new(className: string, props, parent: Instance?)
	local inst = Instance.new(className)
	assign(inst, props)
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function stroke(parent: Instance, thickness: number, color: Color3, border: boolean?)
	return new("UIStroke", {
		Thickness = thickness,
		Color = color,
		LineJoinMode = Enum.LineJoinMode.Miter,
		ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual,
	}, parent)
end

type Bar = { root: CanvasGroup, fill: Frame, trail: Frame, fillGradient: UIGradient, name: TextLabel, subtitle: TextLabel, hpText: TextLabel, tag: TextLabel, panel: Frame, eye: Frame, shown: number, hp: number, trailHp: number, hold: number, lastFrac: number }
local bar: Bar? = nil

local function buildBossBar(): Bar?
	if not localPlayer then
		return nil
	end
	local pg = localPlayer:FindFirstChildOfClass("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5)
	if not pg then
		return nil
	end
	local gui = pg:FindFirstChild("BradleyBossBars")
	if not (gui and gui:IsA("ScreenGui")) then
		gui = new("ScreenGui", { Name = "BradleyBossBars", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 8, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
		local holder = new("Frame", {
			Name = "Holder",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 58),
			Size = UDim2.new(0.62, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, gui)
		new("UIListLayout", { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, holder)
		new("UISizeConstraint", { MaxSize = Vector2.new(780, math.huge), MinSize = Vector2.new(300, 0) }, holder)
		gui.Parent = pg
	end
	local holder = gui:FindFirstChild("Holder") or gui
	for _, child in holder:GetChildren() do
		local link = child:FindFirstChild("Boss")
		if link and link:IsA("ObjectValue") and (link.Value == nil or not link.Value:IsDescendantOf(workspace)) then
			child:Destroy()
		end
	end

	local root = new("CanvasGroup", { Name = "BradleyBar", Size = UDim2.new(1, 0, 0, 100), BackgroundTransparency = 1, GroupTransparency = 1, Visible = false })
	new("ObjectValue", { Name = "Boss", Value = model }, root)

	-- name plate: Amestris navy with a gold edge
	local panel = new("Frame", { Name = "Plate", Position = UDim2.new(0, 6, 0, 6), Size = UDim2.new(0, 300, 0, 46), BackgroundColor3 = Color3.fromRGB(22, 30, 54), BorderSizePixel = 0, Rotation = -2 }, root)
	stroke(panel, 2.5, Color3.fromRGB(226, 178, 70), true)
	new("Frame", { Name = "Accent", Position = UDim2.new(0, 0, 1, -5), Size = UDim2.new(1, 0, 0, 5), BackgroundColor3 = Color3.fromRGB(176, 18, 30), BorderSizePixel = 0 }, panel)
	-- the Ouroboros mark on the plate (lights up in phase 2)
	local eye = new("Frame", { Name = "Ouroboros", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 26, 0.5, -1), Size = UDim2.new(0, 30, 0, 30), BackgroundColor3 = Color3.fromRGB(236, 226, 222), BackgroundTransparency = 0.8, BorderSizePixel = 0 }, panel)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, eye)
	stroke(eye, 3, Color3.fromRGB(176, 18, 30), true)
	for k = 0, 1 do
		for j = 0, 2 do
			local a = math.rad(-90 + 120 * j + 180 * k)
			new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5 + 0.22 * math.cos(a + math.rad(60)), 0, 0.5 + 0.22 * math.sin(a + math.rad(60)), 0), Size = UDim2.new(0.5, 0, 0, 2), Rotation = math.deg(a) + 150, BackgroundColor3 = Color3.fromRGB(200, 20, 30), BorderSizePixel = 0 }, eye)
		end
	end
	local name = new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 50, 0, -2),
		Size = UDim2.new(1, -56, 1, -2),
		Font = Enum.Font.Bangers,
		Text = tostring(Config.DisplayName or "KING BRADLEY"),
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 38,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, panel)
	stroke(name, 2.5, Color3.new(0, 0, 0))
	new("UIGradient", { Color = CS(0, Color3.new(1, 1, 1), 1, Color3.fromRGB(255, 226, 160)), Rotation = 90 }, name)
	local subtitle = new("TextLabel", {
		Name = "Subtitle",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 318, 0, 16),
		Size = UDim2.new(1, -326, 0, 22),
		Font = Enum.Font.Fondamento,
		Text = tostring(Config.Subtitle or ""),
		TextColor3 = Color3.fromRGB(236, 228, 214),
		TextSize = 19,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, root)
	stroke(subtitle, 1.6, Color3.new(0, 0, 0))
	local tag = new("TextLabel", {
		Name = "UltimateEye",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 0),
		Size = UDim2.new(0, 190, 0, 34),
		Font = Enum.Font.Bangers,
		Text = "ULTIMATE EYE",
		TextColor3 = Color3.fromRGB(255, 52, 60),
		TextSize = 30,
		Rotation = 5,
		Visible = false,
	}, root)
	stroke(tag, 2.5, Color3.new(0, 0, 0))

	local frame = new("Frame", { Name = "Bar", Position = UDim2.new(0, 4, 0, 62), Size = UDim2.new(1, -8, 0, 26), BackgroundColor3 = Color3.fromRGB(16, 12, 24), BorderSizePixel = 0, Rotation = -0.5, ClipsDescendants = true }, root)
	stroke(frame, 3, Color3.fromRGB(226, 178, 70), true)
	local trail = new("Frame", { Name = "Trail", Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = Color3.fromRGB(255, 236, 190), BorderSizePixel = 0 }, frame)
	local fill = new("Frame", { Name = "Fill", Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, frame)
	local fillGradient = new("UIGradient", { Color = CS(0, Color3.fromRGB(110, 140, 220), 0.5, Color3.fromRGB(46, 70, 150), 1, Color3.fromRGB(22, 32, 80)), Rotation = 90 }, fill)
	new("Frame", { Name = "Shine", Position = UDim2.new(0, 0, 0, 3), Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.6, BorderSizePixel = 0 }, fill)
	-- notches where he throws off the cape and opens the eye
	for _, th in { Config.CapeHealth, Config.EyeHealth } do
		if type(th) == "number" and th > 0 and th < 1 then
			new("Frame", { Name = "Notch", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(th, 0, 0, 0), Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = Color3.fromRGB(226, 178, 70), BackgroundTransparency = 0.1, BorderSizePixel = 0, ZIndex = 3 }, frame)
		end
	end
	local hpText = new("TextLabel", { Name = "HP", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0), Size = UDim2.new(0, 220, 1, 0), Font = Enum.Font.GothamBlack, Text = "", TextColor3 = Color3.new(1, 1, 1), TextSize = 15, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 4 }, frame)
	stroke(hpText, 1.6, Color3.new(0, 0, 0))

	root.Parent = holder
	return { root = root, fill = fill, trail = trail, fillGradient = fillGradient, name = name, subtitle = subtitle, hpText = hpText, tag = tag, panel = panel, eye = eye, shown = 0, hp = 1, trailHp = 1, hold = 0, lastFrac = 1 }
end

local function updateBossBar(dt: number)
	if not bar then
		return
	end
	local b = bar :: Bar
	if not b.root.Parent then
		return
	end
	local maxHp = if humanoid then math.max(humanoid.MaxHealth, 1) else 1
	local frac = if humanoid then clamp01(humanoid.Health / maxHp) else 0
	local _c, _h, root = localCharacter()
	local cam = workspace.CurrentCamera
	local from = if root then root.Position elseif cam then cam.CFrame.Position else nil
	local range = Config.BossBarRange
	local inRange = from ~= nil and (from - hrp.Position).Magnitude <= (if type(range) == "number" then range else 170)
	local want = if inRange and not deathRec and frac > 0 then 1 else 0
	b.shown = approach(b.shown, want, if want > b.shown then 7 else (if deathRec then 2.5 else 5), dt)
	b.root.Visible = b.shown > 0.01
	b.root.GroupTransparency = 1 - b.shown
	if not b.root.Visible then
		b.lastFrac = frac
		b.hp, b.trailHp = frac, frac
		return
	end
	if frac < b.lastFrac - 1e-4 then
		b.hold = 0.5
	end
	b.lastFrac = frac
	b.hp = approach(b.hp, frac, 16, dt)
	if b.hold > 0 then
		b.hold -= dt
	else
		b.trailHp = approach(b.trailHp, b.hp, 3, dt)
	end
	b.trailHp = math.max(b.trailHp, b.hp)
	b.fill.Size = UDim2.new(b.hp, 0, 1, 0)
	b.trail.Size = UDim2.new(b.trailHp, 0, 1, 0)
	b.hpText.Text = formatNumber(frac * maxHp) .. " / " .. formatNumber(maxHp)
	local sub = model:GetAttribute("Subtitle")
	b.subtitle.Text = if type(sub) == "string" then sub else tostring(Config.Subtitle or "")
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * TAU * 1.2)
	b.tag.Visible = enraged
	if enraged then
		b.tag.Rotation = 5 + math.sin(os.clock() * 20) * 1.2
		b.fillGradient.Color = CS(0, Color3.fromRGB(255, 90, 90), 0.5, Color3.fromRGB(200, 20, 36), 1, Color3.fromRGB(110, 6, 20))
		b.fillGradient.Offset = Vector2.new(0, -0.12 * pulse)
		b.eye.BackgroundTransparency = 0.1
		b.name.TextColor3 = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 130, 130), pulse * 0.6)
	else
		b.fillGradient.Color = CS(0, Color3.fromRGB(110, 140, 220), 0.5, Color3.fromRGB(46, 70, 150), 1, Color3.fromRGB(22, 32, 80))
		b.fillGradient.Offset = Vector2.zero
		b.eye.BackgroundTransparency = 0.8
		b.name.TextColor3 = Color3.new(1, 1, 1)
	end
	b.panel.Position = UDim2.new(0, 6 + (if hitFlash > 0 then (math.random() - 0.5) * 6 * hitFlash else 0), 0, 6)
end

-- =============================================================================================
-- 11. Frame loop
-- =============================================================================================
local CULL_DIST = 450
local alive = true

local function syncActions(now: number)
	local id = model:GetAttribute("ActionId")
	if id ~= lastActionId then
		lastActionId = id
		for _, rec in actions do
			if not rec.endAt then
				rec.endAt = now
			end
		end
		local name = model:GetAttribute("Action")
		if type(name) == "string" and EVAL[name] then
			local start = model:GetAttribute("ActionStart")
			if type(start) ~= "number" then
				start = now
			end
			local speed = model:GetAttribute("ActionSpeed")
			if type(speed) ~= "number" or speed <= 0 then
				speed = 1
			end
			local rec: ActionRec = {
				name = name,
				id = id,
				start = start,
				speed = speed,
				cfg = cfgAction(name),
				keys = {},
				fired = {},
				w = 0,
				t = (now - start) * speed,
				real = now - start,
				endAt = nil,
				target = nil,
				victim = 0,
				pathStr = nil,
				path = nil,
				data = {},
			}
			if SETUP[name] then
				local ok, err = pcall(SETUP[name], rec)
				if not ok then
					warn("[Bradley] setup " .. name .. ": " .. tostring(err))
				end
			end
			table.insert(actions, rec)
			if name == "Death" then
				deathRec = rec
			end
			log("action", name, id, speed)
		end
	end
	local newest = actions[#actions]
	if newest and not newest.endAt then
		local target = model:GetAttribute("ActionTarget")
		if typeof(target) == "Vector3" then
			newest.target = target
		end
		local victim = model:GetAttribute("ActionVictim")
		newest.victim = if type(victim) == "number" then victim else 0
		local ps = model:GetAttribute("ActionPath")
		if type(ps) == "string" and ps ~= newest.pathStr then
			newest.pathStr = ps
			newest.path = Motion.decode(ps)
		end
	end
	enraged = model:GetAttribute("Enraged") == true
end

local function updateActions(now: number)
	for i = #actions, 1, -1 do
		local rec = actions[i]
		rec.real = now - rec.start
		rec.t = rec.real * rec.speed
		local fade = FADE[rec.name] or { 0.2, 0.3 }
		local w = if fade[1] > 0 then smooth(rec.real / fade[1]) else (if rec.real >= 0 then 1 else 0)
		local over = false
		if rec ~= deathRec then
			local stopAt = math.min(rec.start + (rec.cfg.Duration or 2) / rec.speed, rec.endAt or math.huge)
			if now > stopAt then
				local f = smooth((now - stopAt) / math.max(fade[2], 1e-3))
				w *= 1 - f
				over = f >= 1
			end
		end
		rec.w = w
		if over then
			if STOP[rec.name] then
				STOP[rec.name](rec)
			end
			table.remove(actions, i)
		end
	end
end

-- Visual root: where the body is drawn (on the scripted path when there is one).
local corrState = { w = 0, cf = I }
local function updateRootCorrection(now: number, dt: number)
	local want: CFrame? = nil
	for i = #actions, 1, -1 do
		local rec = actions[i]
		local path = rec.path
		if path and #path >= 1 then
			local tp = now - rec.start
			local t0, t1 = path[1].t, Motion.endTime(path)
			if tp >= t0 - 0.02 and tp <= t1 + 0.6 then
				local desired = Motion.cframe(path, tp)
				local arrived = (hrp.Position - path[#path].pos).Magnitude < 0.35 * S
				if tp <= t1 or not arrived then
					want = hrp.CFrame:Inverse() * desired
				end
			end
			break
		end
	end
	if want then
		corrState.w = 1
		corrState.cf = want
	else
		corrState.w = approach(corrState.w, 0, 14, dt)
		if corrState.w < 0.01 then
			corrState.w = 0
		end
	end
	if corrState.w <= 0 then
		F.corr = I
	elseif corrState.w >= 1 then
		F.corr = corrState.cf
	else
		F.corr = blendPose(I, corrState.cf, corrState.w)
	end
	visualRoot = hrp.CFrame * F.corr
end

local function headLook(dt: number)
	local target, w = F.look, F.lookW
	if (not target or w < 0.05) and not deathRec then
		local _c, _h, root = localCharacter()
		if root then
			local d = (root.Position - hrp.Position).Magnitude
			target = root.Position + Vector3.new(0, 1.5, 0)
			w = (1 - progress(40 * S, 70 * S, d)) * (1 - F.suppress)
		end
	end
	local ty, tp = 0, 0
	if target and w > 0.01 then
		local headRest = if headRec then headRec.restRel.Position else Vector3.new(0, 3.2 * S, 0)
		local dir = visualRoot:PointToObjectSpace(target) - headRest
		if dir.Z < 2 * S then
			local horiz = math.sqrt(dir.X * dir.X + dir.Z * dir.Z)
			ty = math.clamp(math.atan2(-dir.X, -dir.Z), -55 * RAD, 55 * RAD) * w
			tp = math.clamp(math.atan2(dir.Y, horiz), -25 * RAD, 20 * RAD) * w
		end
	end
	look.yaw = approach(look.yaw, ty, 7, dt)
	look.pitch = approach(look.pitch, tp, 7, dt)
	rotAcc.B_Head += Vector3.new(look.pitch * 0.6, look.yaw * 0.65, 0)
	rotAcc.B_Neck += Vector3.new(look.pitch * 0.25, look.yaw * 0.2, 0)
	rotAcc.B_Chest += Vector3.new(0, look.yaw * 0.15, 0)
end

local function applyTremble(clock: number)
	local tr = F.tremble
	if tr <= 0 then
		return
	end
	local tt = clock * 21
	rotAcc.B_Chest += Vector3.new(noise(tt, 21), noise(tt, 22), noise(tt, 23)) * (1.4 * RAD * tr)
	rotAcc.B_Head += Vector3.new(noise(tt, 24), noise(tt, 25), noise(tt, 26)) * (2 * RAD * tr)
	rotAcc.B_HandR += Vector3.new(noise(tt, 27), 0, noise(tt, 28)) * (4 * RAD * tr)
	rotAcc.B_HandL += Vector3.new(noise(tt, 29), 0, noise(tt, 30)) * (4 * RAD * tr)
end

local function writeMotors()
	for _, rec in boneList do
		if rec.dirty then
			rec.dirty = false
			local motor = rec.motor
			if motor then
				motor.Transform = rec.T
			end
		end
	end
end

-- Persistent prop state from the attributes (actions override it frame by frame).
local function baseVisibility(clock: number): { [string]: boolean }
	local drawn = model:GetAttribute("Drawn") == true
	local capeOff = model:GetAttribute("CapeOff") == true
	local eyeOpenAttr = model:GetAttribute("EyeOpen") == true
	local spareBack = clock >= spareHiddenUntil
	return {
		SaberR = drawn,
		SaberL = drawn,
		HiltR = not drawn,
		HiltL = not drawn,
		Spare1 = true,
		Spare2 = true,
		Spare3 = spareBack,
		Spare4 = true,
		Cape = not capeOff,
		Patch = not eyeOpenAttr,
	}
end

local function animate(dt: number, now: number, clock: number)
	resetFrame()
	local suppress = 0
	for _, rec in actions do
		suppress = math.max(suppress, rec.w * (SUPPRESS[rec.name] or 0.8))
	end
	F.suppress = suppress
	F.lid = if model:GetAttribute("EyeOpen") == true and enraged then 1 else 0
	F.dissolve = 0
	local base = baseVisibility(clock)
	drawnVisual = base.SaberR
	-- the newest drawing/sheathing action decides whether the blades are in hand
	for _, rec in actions do
		if rec.name == "Draw" then
			drawnVisual = rec.t >= (rec.cfg.DrawAt or 0.5)
		elseif rec.name == "Sheathe" then
			drawnVisual = rec.t < (rec.cfg.SheatheAt or 0.85)
		end
	end
	updateRootCorrection(now, dt)
	evalBase(dt, clock, 1 - suppress, deathRec ~= nil)
	for _, rec in actions do
		if rec.w > 0 then
			EVAL[rec.name](rec, rec.t, rec.w, dt, now, clock)
		end
	end
	headLook(dt)
	applyTremble(clock)
	applySecondary(dt)
	composeBody()
	solveLegs()
	solveFK()
	if F.reach[1] or F.reach[-1] then
		for _, side in { 1, -1 } do
			local req = F.reach[side]
			if req then
				solveArm(side, req)
			end
		end
		solveFK()
	end
	solvePatch()
	solveLid(dt)
	solveCape(dt, clock)
	solveFK()
	writeMotors()

	-- props, trails, the eye
	if F.vis.SaberR == nil then
		F.vis.SaberR = drawnVisual
		F.vis.HiltR = not drawnVisual
	end
	if F.vis.SaberL == nil then
		F.vis.SaberL = drawnVisual
		F.vis.HiltL = not drawnVisual
	end
	applyGroups(base)
	applyDissolve()
	for side, tr in trails do
		local on = F.trail[side] > 0.05 and F.vis[if side == 1 then "SaberR" else "SaberL"] ~= false
		if tr.Enabled ~= on then
			tr.Enabled = on
			tr.Color = CS(slashColor())
		end
	end
	local eyeOn = lidOpen > 0.5 and F.dissolve < 0.5
	if eyeFx.on ~= eyeOn then
		eyeFx.on = eyeOn
		if eyeFx.light then
			eyeFx.light.Enabled = eyeOn
		end
		if eyeFx.trail then
			eyeFx.trail.Enabled = eyeOn
		end
	end
	if eyeOn and eyeFx.gui then
		eyeFx.gui.Brightness = 1.6 + 1.2 * (0.5 + 0.5 * math.sin(clock * TAU * 1.1))
	end
end

local errorCount = 0
local function onPreSimulation(dt: number)
	if not alive then
		return
	end
	dt = math.clamp(dt, 1 / 240, 1 / 15)
	local now = serverNow()
	local clock = os.clock()
	local ok, err = pcall(function()
		syncActions(now)
		updateActions(now)
		local cam = workspace.CurrentCamera
		local far = cam ~= nil and (cam.CFrame.Position - hrp.Position).Magnitude > CULL_DIST * S
		if not far then
			animate(dt, now, clock)
		end
		localEffects(dt, now)
		stepFx(dt)
		stepHitFlash(dt)
	end)
	if not ok then
		errorCount += 1
		if errorCount <= 5 then
			warn("[Bradley] client animation error: " .. tostring(err))
		end
	end
end

-- =============================================================================================
-- 12. Lifecycle and cleanup
-- =============================================================================================
local connections: { RBXScriptConnection } = {}

local function cleanup()
	if not alive then
		return
	end
	alive = false
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	pcall(function()
		RunService:UnbindFromRenderStep(SHAKE_KEY .. "Pre")
		RunService:UnbindFromRenderStep(SHAKE_KEY .. "Post")
	end)
	pcall(shakeUndo)
	for _, rec in actions do
		if STOP[rec.name] then
			pcall(STOP[rec.name], rec)
		end
	end
	for _, fx in liveFx do
		for _, inst in fx.inst do
			inst:Destroy()
		end
	end
	table.clear(liveFx)
	if screen.effect then
		screen.effect:Destroy()
		screen.effect = nil
	end
	if screen.lines then
		screen.lines:Destroy()
		screen.lines = nil
	end
	if bar then
		bar.root:Destroy()
		bar = nil
	end
	vfxFolder:Destroy()
	if outline then
		outline:Destroy()
		outline = nil
	end
	log("cleaned up")
end

local function watch(signal: RBXScriptSignal, fn)
	table.insert(connections, signal:Connect(fn))
end

watch(model.AncestryChanged, function()
	if not model:IsDescendantOf(workspace) then
		cleanup()
	end
end)
watch(hrp.AncestryChanged, function()
	if not hrp:IsDescendantOf(model) then
		cleanup()
	end
end)
watch(model:GetAttributeChangedSignal("RigReady"), function()
	if not model:GetAttribute("RigReady") then
		cleanup()
	end
end)
watch(model.Destroying, cleanup)
watch(script.AncestryChanged, function()
	if not script:IsDescendantOf(model) then
		cleanup()
	end
end)
if humanoid then
	local lastHealth = humanoid.Health
	watch(humanoid.HealthChanged, function(health: number)
		if health < lastHealth - 0.5 and not deathRec and health > 0 then
			hitFlash = 1
			impulse(springs.chest, Vector3.new(-0.5, (math.random() - 0.5) * 0.6, (math.random() - 0.5) * 0.4))
			impulse(springs.head, Vector3.new(-0.6, (math.random() - 0.5) * 0.8, 0))
		end
		lastHealth = health
	end)
end
watch(RunService.PreSimulation, onPreSimulation)
watch(RunService.Heartbeat, function(dt: number)
	if alive then
		local ok, err = pcall(updateBossBar, dt)
		if not ok and errorCount < 5 then
			errorCount += 1
			warn("[Bradley] boss bar error: " .. tostring(err))
		end
	end
end)
RunService:BindToRenderStep(SHAKE_KEY .. "Pre", Enum.RenderPriority.Camera.Value - 1, shakeUndo)
RunService:BindToRenderStep(SHAKE_KEY .. "Post", Enum.RenderPriority.Camera.Value + 1, shakeApply)

do
	local ok, result = pcall(buildBossBar)
	if ok then
		bar = result
	else
		warn("[Bradley] could not build the boss bar: " .. tostring(result))
	end
end
log("ready")
