--!nonstrict
--[[
	King Bradley boss - client: animation (through the Animator module), visual effects, the local
	player's knockback, camera shake, screen effects, the anime outline and the boss health bar.

	A Script (RunContext = Client). BossServer moves it into the boss model (wherever the scripts were
	inserted) and marks the model with the BradleyBoss attribute; this script waits for that, so every
	player runs their own copy (each respawned boss runs a fresh one).

	Contract with BossServer:
	  * the boss is the imported, skinned model: Bone instances named B_* drive the meshes. The server
	    welds everything to the HumanoidRootPart and sets RigReady; this script writes Bone.Transform
	    every frame (PreSimulation). Transforms are local and never replicated: smooth and free.
	  * actions arrive as attributes (Action, ActionId, ActionStart, ActionSpeed, ActionTarget,
	    ActionPath, ActionVictim). Time into an action = (GetServerTimeNow() - ActionStart) * ActionSpeed
	    and its phases come from Config.Actions, so every client shows the same moment of the same cut.
	  * dashes and leaps follow ActionPath (module Motion): the body is drawn exactly on the path.
	  * Combat / CapeOff / EyeOpen / Enraged describe the persistent state (late joiners see it right).

	Layout: 1. setup  2. rig  3. effects library  4. action effects  5. local player
	        6. outline and boss bar  7. frame loop  8. lifecycle
]]

-- =============================================================================================
-- 1. Setup
-- =============================================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local function claimedModel(): Model?
	local p = script.Parent
	return if p and p:IsA("Model") and p:GetAttribute("BradleyBoss") == true then p else nil
end
local model = claimedModel()
while not model do
	-- still in the KingBradleyScripts folder: BossServer is about to move this script into the boss
	task.wait(0.25)
	model = claimedModel()
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
local Animator = requireChild("Animator")
local Poses = requireChild("Poses") or {}
if not (Motion and Animator) then
	warn("[Bradley] BossClient needs the Motion and Animator modules")
	return
end

local function cfgAction(name: string)
	local given = type(Config.Actions) == "table" and Config.Actions[name] or nil
	return if type(given) == "table" then given else {}
end

local localPlayer = Players.LocalPlayer
local AM = Animator.math
local clamp01, progress, smooth, smoother, easeOut, envelope, approach = AM.clamp01, AM.progress, AM.smooth, AM.smoother, AM.easeOut, AM.envelope, AM.approach
local function noise(t: number, seed: number): number
	return math.clamp(math.noise(t, seed, 0.37) * 2, -1, 1)
end
local TAU = math.pi * 2
local RAD = math.pi / 180
local V0 = Vector3.zero
local I = CFrame.identity

-- =============================================================================================
-- 2. Rig
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
local S = model:GetAttribute("RigScale")
S = if type(S) == "number" and S > 0 then S else 1

-- every Bone of the imported rig (top-level bones are folded onto the root part's frame)
local boneObjs: { [string]: Bone } = {}
local allBones: { Bone } = {} -- every copy (an importer may give each mesh its own skeleton copy)
local desc = { bones = {}, holder = I }
do
	for _, d in model:GetDescendants() do
		if d:IsA("Bone") then
			table.insert(allBones, d)
			boneObjs[d.Name] = boneObjs[d.Name] or d
		end
	end
	for name, b in boneObjs do
		local parent = b.Parent
		if parent and parent:IsA("Bone") then
			table.insert(desc.bones, { name = name, parent = parent.Name, rest = b.CFrame })
		elseif parent and parent:IsA("BasePart") then
			table.insert(desc.bones, { name = name, rest = hrp.CFrame:ToObjectSpace(parent.CFrame) * b.CFrame })
		end
	end
end
if not boneObjs.B_Hips then
	warn("[Bradley] BossClient: no B_Hips bone; import KingBradley.fbx with its armature (see README)")
	return
end
local anim = Animator.new(desc, Poses, Config)
local animBones: { { Bone } } = {}
for _, b in allBones do
	table.insert(animBones, { b, b.Name })
end
log(("%d bones, unit %.2f"):format(#desc.bones, anim.U))

-- prop groups (MeshParts named Group_Material), hidden with LocalTransparencyModifier
local GROUP_NAMES = { "SaberR", "SaberL", "Spare1", "Spare2", "Spare3", "Spare4", "Cape", "Patch" }
local groupParts: { [string]: { BasePart } } = {}
for _, g in GROUP_NAMES do
	groupParts[g] = {}
end
local allVisualParts: { BasePart } = {}
for _, d in model:GetDescendants() do
	if d:IsA("BasePart") and d ~= hrp and d.Name ~= "Hitbox" then
		table.insert(allVisualParts, d)
		local g = string.match(d.Name, "^(%a+%d?)_")
		if g and groupParts[g] then
			table.insert(groupParts[g], d)
		end
	end
end
local spareNames = {}
for _, g in { "Spare1", "Spare2", "Spare3", "Spare4" } do
	if #groupParts[g] > 0 then
		table.insert(spareNames, g)
	end
end

-- world positions of bones this frame (the Animator's rels already include the path correction)
local function bonePos(name: string): Vector3
	return hrp.CFrame * anim:pos(name)
end
local function boneCF(name: string): CFrame
	return hrp.CFrame * anim:relOf(name)
end

-- =============================================================================================
-- 3. Effects library
-- =============================================================================================
local enraged = false
local visualRoot = hrp.CFrame
local footDust: ((Vector3) -> ())? = nil
local F = { sustainShake = 0, dissolve = 0, vis = {} :: { [string]: boolean }, trail = { [1] = 0, [-1] = 0 } }

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

local function vrLook(): Vector3
	local l = visualRoot.LookVector
	local f = Vector3.new(l.X, 0, l.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

local function groundUnder(): number
	return visualRoot.Position.Y - (if humanoid then humanoid.HipHeight else 4 * S) - hrp.Size.Y / 2
end

local function bladeWorld(side: number, along: number): Vector3
	local n = if side == 1 then "R" else "L"
	local a, b = bonePos("B_Saber" .. n), bonePos("B_SaberTip" .. n)
	return a:Lerp(b, 0.12 + 0.88 * along)
end

local function eyeWorld(): Vector3
	return bonePos("B_Head") + (boneCF("B_Head"):VectorToWorldSpace(anim.bones.B_Patch and (anim.bones.B_Head.restRel:Inverse() * anim.bones.B_Patch.restRel).Position or Vector3.new(0, 0.4 * S, -0.4 * S)))
end

-- Afterimage: a neon silhouette of his current pose, built from the bones (fades in `life`).
local GHOST = {
	{ "B_Hips", "B_Chest", 0.9 }, { "B_Chest", "B_Neck", 0.85 }, { "B_Neck", "B_Head", 0.5 },
	{ "B_UpperArmR", "B_ForearmR", 0.42 }, { "B_ForearmR", "B_HandR", 0.36 }, { "B_UpperArmL", "B_ForearmL", 0.42 }, { "B_ForearmL", "B_HandL", 0.36 },
	{ "B_ThighR", "B_ShinR", 0.5 }, { "B_ShinR", "B_FootR", 0.4 }, { "B_ThighL", "B_ShinL", 0.5 }, { "B_ShinL", "B_FootL", 0.4 },
	{ "B_SaberR", "B_SaberTipR", 0.1 }, { "B_SaberL", "B_SaberTipL", 0.1 },
}
local function afterimage(color: Color3, life: number, alpha: number)
	local cam = workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - hrp.Position).Magnitude > 200 * S then
		return
	end
	local parts = {}
	for _, g in GHOST do
		if anim.bones[g[1]] and anim.bones[g[2]] then
			local a, b = bonePos(g[1]), bonePos(g[2])
			local len = (b - a).Magnitude
			if len > 0.05 then
				local p = fxPart({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(len + g[3] * S, g[3] * 2 * S, g[3] * 2 * S), Color = color, Material = Enum.Material.Neon, Transparency = alpha })
				p.CFrame = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.pi / 2, 0)
				table.insert(parts, p)
			end
		end
	end
	local head = fxPart({ Shape = Enum.PartType.Ball, Size = Vector3.one * 1.25 * S, Color = color, Material = Enum.Material.Neon, Transparency = alpha, CFrame = CFrame.new(bonePos("B_Head") + Vector3.new(0, 0.45 * S, 0)) })
	table.insert(parts, head)
	addFx(life, parts, function(_age, u)
		for _, p in parts do
			p.Transparency = alpha + (1 - alpha) * u
		end
	end)
end

-- Free copies of a prop group (thrown saber, the cape, the eyepatch), moved as one rigid body.
-- Skinned meshes copied off the rig show their rest shape, placed where the bone has them now.
local function propCopy(group: string, boneName: string): ({ BasePart }, { CFrame }, CFrame)
	local parts, offsets = {}, {}
	local rec = anim.bones[boneName]
	local origin = boneCF(boneName)
	local restWorld = hrp.CFrame * (if rec then rec.restRel else I)
	for _, src in groupParts[group] or {} do
		if src.LocalTransparencyModifier < 0.99 then
			local ok, p = pcall(function()
				return src:Clone()
			end)
			if ok and p then
				for _, ch in p:GetChildren() do
					if not ch:IsA("DataModelMesh") and not ch:IsA("SurfaceAppearance") then
						ch:Destroy()
					end
				end
				p.Anchored = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				p.LocalTransparencyModifier = 0
				p.Parent = vfxFolder
				table.insert(parts, p)
				table.insert(offsets, restWorld:ToObjectSpace(src.CFrame))
			end
		end
	end
	return parts, offsets, origin
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
local function playSound(key: string, volume: number?, pitch: number?, parent: Instance?): Sound?
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

-- Blade trails (Trails between the saber bone and its tip bone; Bones are Attachments)
local trails: { [number]: Trail } = {}
for side, n in { [1] = "R", [-1] = "L" } do
	local a0, a1 = boneObjs["B_Saber" .. n], boneObjs["B_SaberTip" .. n]
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
		tr.Parent = a0
		trails[side] = tr
	end
end

-- The Ultimate Eye: a light and a red light-trail on a small bone at the left eye
local eyeFx = { light = nil :: PointLight?, trail = nil :: Trail?, sigil = {} :: { BasePart }, on = false }
do
	local head = boneObjs.B_Head
	local patchRec, headRec = anim.bones.B_Patch, anim.bones.B_Head
	if head and patchRec and headRec then
		local off = (headRec.restRel:Inverse() * patchRec.restRel).Position
		local function mk(name: string, dy: number): Bone
			local b = Instance.new("Bone")
			b.Name = name
			b.CFrame = CFrame.new(off + Vector3.new(0, dy, 0) + (headRec.restRel:Inverse()).Rotation * Vector3.new(0, 0, -0.03 * S))
			b.Parent = head
			return b
		end
		local glow = mk("BradleyEyeGlow", 0)
		local ta, tb = mk("BradleyEyeTrailA", 0.03 * S), mk("BradleyEyeTrailB", -0.03 * S)
		local light = Instance.new("PointLight")
		light.Color = C_RED
		light.Range = 5 * S
		light.Brightness = 3
		light.Shadows = false
		light.Enabled = false
		light.Parent = glow
		eyeFx.light = light
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
		tr.Parent = head
		eyeFx.trail = tr
	end
	for _, p in allVisualParts do
		if string.find(p.Name, "OuroSigil") then
			table.insert(eyeFx.sigil, p)
		end
	end
end

-- =============================================================================================
-- 4. Actions: bookkeeping and their effects (the poses are in the Animator)
-- =============================================================================================
type ActionRec = {
	name: string,
	id: any,
	start: number,
	speed: number,
	cfg: any,
	fired: { [string]: boolean },
	w: number,
	t: number,
	real: number,
	endAt: number?,
	target: Vector3?,
	rootTarget: Vector3?,
	victim: number,
	pathStr: string?,
	path: any,
	data: any,
	suppress: number,
}
local actions: { ActionRec } = {}
local lastActionId: any = nil
local deathRec: ActionRec? = nil

local FADE = {
	Challenge = { 0.2, 0.4 },
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
local SUPPRESS = { Challenge = 0.9, RemoveCape = 0.85, RemoveEyepatch = 0.9 }
local FX, STOP = {}, {}

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

FX.Challenge = function(rec, t)
	F.trail[1] = envelope(t, 0.4, 0.5, 0.85, 1.0)
	if fire(rec, "gleam", 0.95, t) then
		glint(bladeWorld(1, 0.95), 3.4, C_STEEL, 0.4)
		playSound("Unsheathe", 1, 1.05)
	end
end

local function flingCape()
	local parts, offsets, origin = propCopy("Cape", "B_Chest")
	if #parts == 0 then
		return
	end
	local vr = visualRoot
	local state = {
		cf = origin,
		vel = -vr.RightVector * (24 * S) + Vector3.new(0, 18 * S, 0) + vr.LookVector * (4 * S),
		spin = vr.LookVector * -2.8 + Vector3.new(0, 1.2, 0),
		landed = false,
	}
	local gY = groundUnder()
	local life = 9
	addFx(life, parts, function(age, _u, dt)
		if not state.landed then
			state.vel += Vector3.new(0, -workspace.Gravity * 0.3 * dt, 0)
			state.vel *= math.exp(-1.5 * dt)
			local pos = state.cf.Position + state.vel * dt
			local axis = state.spin
			local rotStep = if axis.Magnitude > 1e-3 then CFrame.fromAxisAngle(axis.Unit, axis.Magnitude * dt) else I
			local flutter = CFrame.Angles(math.sin(age * 9) * 0.04, 0, math.cos(age * 7) * 0.05)
			state.cf = CFrame.new(pos) * rotStep * state.cf.Rotation * flutter
			if pos.Y < gY + 1.4 * S and age > 0.3 then
				state.landed = true
			end
		else
			local flat = CFrame.new(state.cf.Position.X, gY + 0.5 * S, state.cf.Position.Z) * CFrame.Angles(-math.pi / 2, select(2, state.cf:ToEulerAnglesYXZ()), 0)
			state.cf = state.cf:Lerp(flat, math.min(1, dt * 3))
		end
		placeCopy(parts, offsets, state.cf, smooth(progress(life - 2, life, age)))
	end)
end

FX.RemoveCape = function(rec, t)
	local rel = rec.cfg.ReleaseAt or 0.95
	F.vis.Cape = t < rel
	F.trail[-1] = envelope(t, rel - 0.2, rel - 0.1, rel + 0.2, rel + 0.3) * 0.6
	if fire(rec, "rip", rel, t) then
		playSound("CapeTear", 1)
		flingCape()
		dustBurst(visualRoot.Position - Vector3.new(0, 4 * S, 0) - visualRoot.RightVector * 3 * S, C_DUST, 8, 6, 2)
	end
end

local function tossPatch()
	local parts, offsets, origin = propCopy("Patch", "B_Patch")
	if #parts == 0 then
		return
	end
	local vr = visualRoot
	local st = { cf = origin, vel = -vr.RightVector * (14 * S) + Vector3.new(0, 10 * S, 0) + vr.LookVector * (3 * S) }
	local gY = groundUnder()
	addFx(5, parts, function(age, _u, dt)
		if st.cf.Position.Y > gY + 0.05 * S then
			st.vel += Vector3.new(0, -workspace.Gravity * 0.5 * dt, 0)
			st.cf = CFrame.new(st.cf.Position + st.vel * dt) * st.cf.Rotation * CFrame.Angles(9 * dt, 5 * dt, 0)
		end
		placeCopy(parts, offsets, st.cf, smooth(progress(4, 5, age)))
	end)
end

local function eyeBurst(rec: ActionRec)
	local eyeW = eyeWorld()
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

local function auraEmitter(life: number)
	local p = fxPart({ Size = Vector3.new(2.6, 5, 1.6) * S, Transparency = 1, CFrame = boneCF("B_Chest") })
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
		p.CFrame = boneCF("B_Chest") * CFrame.new(0, -1 * S, 0)
		e.Rate = 60 * (1 - u)
	end)
end

FX.RemoveEyepatch = function(rec, t)
	local c = rec.cfg
	local tear = c.TearAt or 1.05
	local open = c.OpenAt or 2.15
	local release = tear + 0.3
	F.vis.Patch = t < release
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
end

FX.Lunge = function(rec, t)
	local c = rec.cfg
	local d0, d1 = c.Dash[1], c.Dash[2]
	F.trail[1] = envelope(t, d0 - 0.05, d0, d1 + 0.1, d1 + 0.2)
	F.trail[-1] = F.trail[1] * 0.5
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

FX.CrossCut = function(rec, t)
	local h = rec.cfg.Hits
	F.trail[1] = envelope(t, h[1] - 0.08, h[1] - 0.03, h[1] + 0.06, h[1] + 0.12) + envelope(t, h[3] - 0.08, h[3] - 0.03, h[3] + 0.08, h[3] + 0.14)
	F.trail[-1] = envelope(t, h[2] - 0.08, h[2] - 0.03, h[2] + 0.06, h[2] + 0.12) + envelope(t, h[3] - 0.08, h[3] - 0.03, h[3] + 0.08, h[3] + 0.14)
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

local spareHidden: { [string]: number } = {}
local function throwSaber(rec: ActionRec)
	local parts, offsets, origin = propCopy("SaberL", "B_SaberL")
	if #parts == 0 then
		return
	end
	local start = origin.Position
	local impact, dir, dist
	local function aimAt(goal: Vector3)
		impact = goal
		dir = impact - start
		dist = dir.Magnitude
		if dist < 0.5 then
			dir = vrLook()
			dist = 1
		else
			dir = dir.Unit
		end
	end
	local aimed = rec.target
	aimAt(rec.target or (start + vrLook() * 40 * S))
	-- the blade runs from the saber bone to the tip bone: turn the copy so that line points at the target
	local bladeLocal = (anim.bones.B_SaberTipL and anim.bones.B_SaberL) and (anim.bones.B_SaberL.restRel:Inverse() * anim.bones.B_SaberTipL.restRel).Position or Vector3.new(0, -1, 0)
	local bladeLen = bladeLocal.Magnitude
	local align = CFrame.lookAt(V0, bladeLocal):Inverse()
	local speed = (rec.cfg.Speed or 150) * S
	local flight = dist / speed
	local stuck = impact - dir * (bladeLen * 0.85)
	local life = flight + 6
	local landed = false
	addFx(life, parts, function(age)
		-- the server's raycast impact can replicate after the release: retarget the flight
		if not landed and rec.target and rec.target ~= aimed then
			aimed = rec.target
			aimAt(rec.target)
			flight = math.max(dist / speed, age + 0.05)
			stuck = impact - dir * (bladeLen * 0.85)
		end
		if age < flight then
			local p = start:Lerp(stuck, age / flight)
			placeCopy(parts, offsets, CFrame.lookAt(p, p + dir) * CFrame.Angles(0, 0, age * 30) * align)
		else
			if not landed then
				landed = true
				local g, color, material = groundAt(impact, 6)
				sparks(impact, C_STEEL, 12, 18)
				dustBurst(g, color, 8, 8, 1.8)
				debrisBurst(g, 6, color, material, 14 * S)
				shockRing(CFrame.new(g + Vector3.new(0, 0.1 * S, 0)), false, 0.5 * S, 6 * S, 0.35, Color3.new(1, 1, 1), Enum.Material.Neon, 0.15 * S, 0.2 * S, 18, 0.2)
				playSound("Impact", 0.6, 1.4)
			end
			placeCopy(parts, offsets, CFrame.lookAt(stuck, stuck + dir) * align, smooth(progress(life - 1.2, life, age)))
		end
	end)
	slashLine(start, impact, 0.12 * S, slashColor(), flight + 0.25, flight)
end

FX.SaberThrow = function(rec, t)
	local c = rec.cfg
	local rl = c.ReleaseAt
	local r0, r1 = c.Redraw[1], c.Redraw[2]
	local grabAt = (r0 + r1) / 2
	F.vis.SaberL = t < rl or t >= grabAt
	F.trail[-1] = envelope(t, rl - 0.12, rl - 0.06, rl, rl + 0.02)
	if fire(rec, "release", rl, t) then
		playSound("Throw", 1, 1.1)
		throwSaber(rec)
	end
	if fire(rec, "grab", grabAt, t) and #spareNames > 0 then
		-- the fresh blade comes out of a sheathed spare: its hilt leaves the scabbard for a while
		spareHidden[spareNames[1]] = os.clock() + 9
		playSound("Unsheathe", 0.7, 1.15)
	end
end

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

FX.Cleave = function(rec, t)
	local c = rec.cfg
	local l0, imp = c.Leap[1], c.ImpactAt
	F.trail[1] = envelope(t, imp - 0.15, imp - 0.1, imp + 0.04, imp + 0.12)
	F.trail[-1] = F.trail[1]
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
		anim:impact(5)
		dustBurst(g, color, 22, 16, 3.4)
		debrisBurst(g, 14, color, material, 22 * S)
		crackMarks(g, (c.Radius or 10) * S * 0.8, color)
		shockRing(CFrame.new(g + Vector3.new(0, 0.15 * S, 0)), false, 1 * S, (c.Radius or 10) * S, 0.5, Color3.new(1, 1, 1), Enum.Material.Neon, 0.25 * S, 0.35 * S, 28, 0.1)
		fissure(g, g + vrLook() * (c.FissureLength or 30) * S, (c.FissureWidth or 6) * S)
		local up = CFrame.lookAt(g + Vector3.new(0, 3 * S, 0), g + Vector3.new(0, 3 * S, 0) + vrLook())
		slashArc(up * CFrame.Angles(0, 0, math.pi / 2), 5 * S, -1.2, 1.2, 0.9 * S, slashColor(), 0.35, 0.05)
		addShake(1.1, g, 20, 110)
	end
end

local function crossWave(rec: ActionRec)
	local c = rec.cfg
	local origin = visualRoot.Position
	local finish = rec.target or (origin + vrLook() * (c.WaveLength or 80) * S)
	local dir = finish - origin
	dir = Vector3.new(dir.X, 0, dir.Z)
	local len = dir.Magnitude
	local look = vrLook()
	if len < 1 or (dir / math.max(len, 1e-3)):Dot(Vector3.new(look.X, 0, look.Z).Unit) < 0.3 then
		-- the wave's end point has not replicated yet: send it straight ahead
		dir = Vector3.new(look.X, 0, look.Z)
		len = (c.WaveLength or 80) * S
	end
	dir = dir.Unit
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

FX.ThousandCuts = function(rec, t)
	local c = rec.cfg
	local f0, f1 = c.Flurry[1], c.Flurry[2]
	local n = math.max(1, c.Slashes or 12)
	local flurry = envelope(t, f0 - 0.05, f0, f1, f1 + 0.05)
	F.trail[1] = math.max(flurry, envelope(t, c.FinalAt - 0.08, c.FinalAt - 0.03, c.FinalAt + 0.06, c.FinalAt + 0.12))
	F.trail[-1] = F.trail[1]
	if fire(rec, "focus", 0.12, t) then
		glint(eyeWorld(), 7, C_RED, 0.5)
		playSound("EyeOpen", 0.6, 1.3)
	end
	for i = 1, n do
		local at = f0 + (f1 - f0) * (i - 0.5) / n
		if fire(rec, "s" .. i, at, t) then
			playSound("Slash", 0.7, 0.9 + math.random() * 0.4)
			frontSlash(math.random(-70, 70), i % 2 == 0, 4 + math.random() * 3, 0.5, 0.4 + math.random() * 1.6)
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

FX.PhantomStep = function(rec, t)
	local c = rec.cfg
	local s0, s1 = c.Steps[1], c.Steps[2]
	rec.data.lines = rec.data.lines or {}
	rec.data.nextLine = rec.data.nextLine or 1
	local dashing = envelope(t, s0, s0 + 0.03, s1, s1 + 0.05)
	F.trail[1] = dashing
	F.trail[-1] = dashing
	if fire(rec, "lock", 0.1, t) then
		reticle(rec, s0 + 0.2)
		glint(eyeWorld(), 8, C_RED, 0.55)
		playSound("EyeOpen", 0.8, 1.15)
	end
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

local function dropSaber(side: number)
	local n = if side == 1 then "R" else "L"
	local parts, offsets, origin = propCopy("Saber" .. n, "B_Saber" .. n)
	if #parts == 0 then
		return
	end
	local gY = groundUnder()
	local st = { cf = origin, vel = visualRoot.RightVector * side * 4 * S + Vector3.new(0, 4 * S, 0), spin = math.random() * 4 + 3 }
	addFx(7, parts, function(age, _u, dt)
		if st.cf.Position.Y > gY + 0.4 * S then
			st.vel += Vector3.new(0, -workspace.Gravity * 0.6 * dt, 0)
			st.cf = CFrame.new(st.cf.Position + st.vel * dt) * st.cf.Rotation * CFrame.Angles(st.spin * dt, 0, st.spin * 0.3 * dt)
		end
		placeCopy(parts, offsets, st.cf, smooth(progress(6, 7, age)))
	end)
end

FX.Death = function(rec, t)
	if t >= 1.25 then
		F.vis.SaberR, F.vis.SaberL = false, false
	end
	if fire(rec, "voice", 0, t) then
		playSound("Death", 1)
	end
	if fire(rec, "drop", 1.25, t) then
		dropSaber(1)
		dropSaber(-1)
		local g, color = groundAt(visualRoot.Position, 12)
		dustBurst(g, color, 8, 6, 2)
	end
	if fire(rec, "fall", 3.4, t) then
		local g, color = groundAt(visualRoot.Position + visualRoot.LookVector * -2 * S, 12)
		dustBurst(g, color, 14, 8, 2.6)
		anim:impact(2)
	end
	F.dissolve = smooth(progress(5.0, 6.3, t))
end

-- =============================================================================================
-- 5. The local player: knockback, shake, screen
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
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		f.BackgroundTransparency = 1
		f.Rotation = (i / 28) * 360
		f.Size = UDim2.new(0.6, 0, 0, 2)
		f.Visible = false
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
				-- rotation pivots on the frame's centre, so the centre goes on the ray (in pixels, so
				-- the lines stay radial on any aspect ratio)
				local cam = workspace.CurrentCamera
				local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
				local half = math.max(vp.X, vp.Y) * 0.5
				local len = (0.4 + math.random() * 0.4) * half
				local r = (0.36 + math.random() * 0.24) * half + len * 0.5
				local a = math.rad(f.Rotation)
				f.Position = UDim2.new(0.5, math.cos(a) * r, 0.5, math.sin(a) * r)
				f.Size = UDim2.fromOffset(len, 1 + math.random() * 3)
				f.Visible = true
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
-- 6. Anime outline, hit flash, boss bar
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
-- 7. Frame loop
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
		if type(name) == "string" and name ~= "Idle" and (Animator.ACTIONS[name] or FX[name]) then
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
				fired = {},
				w = 0,
				t = (now - start) * speed,
				real = now - start,
				endAt = nil,
				target = nil,
				rootTarget = nil,
				victim = 0,
				pathStr = nil,
				path = nil,
				data = {},
				suppress = SUPPRESS[name] or 1,
			}
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
		if rec.target then
			rec.rootTarget = hrp.CFrame:PointToObjectSpace(rec.target)
		end
		local root = victimRoot(rec)
		if root and (rec.name == "PhantomStep" or rec.name == "Challenge") then
			rec.rootTarget = hrp.CFrame:PointToObjectSpace(root.Position)
		end
		if over then
			if STOP[rec.name] then
				STOP[rec.name](rec)
			end
			table.remove(actions, i)
		end
	end
end

-- Root correction for scripted paths: the body is drawn on the path, not on the replicated root.
local corrState = { w = 0, cf = I }
local function rootCorrection(now: number, dt: number): CFrame?
	local want: CFrame? = nil
	for i = #actions, 1, -1 do
		local rec = actions[i]
		local path = rec.path
		if path and #path >= 1 then
			local tp = math.min(now, rec.endAt or now) - rec.start
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
		return nil
	end
	return if corrState.w >= 1 then corrState.cf else I:Lerp(corrState.cf, corrState.w)
end

local spareShown: { [string]: number } = {}
local function applyGroups(clock: number)
	local base = {
		SaberR = true,
		SaberL = true,
		Cape = model:GetAttribute("CapeOff") ~= true,
		Patch = model:GetAttribute("EyeOpen") ~= true,
	}
	for _, g in spareNames do
		base[g] = clock >= (spareHidden[g] or 0)
	end
	for _, gname in GROUP_NAMES do
		local on = F.vis[gname]
		if on == nil then
			on = base[gname]
		end
		if on == nil then
			on = true
		end
		local ltm = if on then F.dissolve else 1
		if spareShown[gname] ~= ltm then
			spareShown[gname] = ltm
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

local lastVR: CFrame? = nil
local lastYaw = 0
local function animate(dt: number, now: number, clock: number)
	table.clear(F.vis)
	F.trail[1], F.trail[-1] = 0, 0
	F.dissolve = 0
	local corr = rootCorrection(now, dt)
	visualRoot = if corr then hrp.CFrame * corr else hrp.CFrame
	-- velocity and turn rate of the drawn body
	local vel = V0
	local yawRate = 0
	local _, yaw = visualRoot:ToEulerAnglesYXZ()
	if lastVR then
		local v = (visualRoot.Position - lastVR.Position) / dt
		if v.Magnitude < 400 * S then
			vel = hrp.CFrame:VectorToObjectSpace(v)
		end
		yawRate = math.atan2(math.sin(yaw - lastYaw), math.cos(yaw - lastYaw)) / dt
	end
	lastVR = visualRoot
	lastYaw = yaw
	-- the local player's head (he watches you when you come close)
	local look = nil
	local char = localPlayer and localPlayer.Character
	local head = char and char:FindFirstChild("Head")
	if head and head:IsA("BasePart") and not deathRec then
		local d = (head.Position - hrp.Position).Magnitude
		look = { target = hrp.CFrame:PointToObjectSpace(head.Position), w = 1 - progress(40 * S, 70 * S, d) }
	end
	local out = anim:step({
		dt = dt,
		clock = clock,
		vel = vel,
		yawRate = yawRate,
		vr = visualRoot,
		corr = corr,
		actions = actions,
		state = {
			combat = model:GetAttribute("Combat") == true,
			eyeOpen = model:GetAttribute("EyeOpen") == true,
			capeOff = model:GetAttribute("CapeOff") == true or F.vis.Cape == false,
			enraged = enraged,
			dead = deathRec ~= nil,
		},
		look = look,
		gravity = workspace.Gravity,
	})
	for _, e in animBones do
		local T = out[e[2]]
		if T then
			e[1].Transform = T
		end
	end
	for _, ev in anim.events do
		if ev.name == "footstep" and ev.data.run > 0.3 and footDust then
			local n = if ev.data.side == 1 then "R" else "L"
			footDust(bonePos("B_Toe" .. n))
		end
	end
	for _, rec in actions do
		local fx = FX[rec.name]
		if fx and rec.w > 0 then
			fx(rec, rec.t, rec.w)
		end
	end
	applyGroups(clock)
	applyDissolve()
	for side, tr in trails do
		local on = F.trail[side] > 0.05 and F.vis[if side == 1 then "SaberR" else "SaberL"] ~= false
		if tr.Enabled ~= on then
			tr.Enabled = on
			tr.Color = CS(slashColor())
		end
	end
	local eyeOn = model:GetAttribute("EyeOpen") == true and enraged and F.dissolve < 0.5
	if eyeFx.on ~= eyeOn then
		eyeFx.on = eyeOn
		if eyeFx.light then
			eyeFx.light.Enabled = eyeOn
		end
		if eyeFx.trail then
			eyeFx.trail.Enabled = eyeOn
		end
		for _, p in eyeFx.sigil do
			p.Material = if eyeOn then Enum.Material.Neon else Enum.Material.SmoothPlastic
		end
	end
	if eyeOn and eyeFx.light then
		eyeFx.light.Brightness = 2.5 + 1.5 * (0.5 + 0.5 * math.sin(clock * TAU * 1.1))
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
-- 8. Lifecycle and cleanup
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
			anim:flinch(1)
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
