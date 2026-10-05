--[[
	King Bradley boss - server brain.

	A Script (RunContext = Server) that sits directly inside the KingBradley model. It:
	  1. keeps a pristine copy of the boss in ServerStorage so he can respawn,
	  2. builds the runtime rig: a Motor6D per B_* bone, welds for every visual part, physics,
	  3. runs the AI: pick a target, walk or sprint after it (pathfinding + unsticking), leash home,
	  4. runs the attacks with the timings in Config.Actions and deals all damage,
	  5. moves the root along scripted paths for dashes and leaps (module Motion),
	  6. publishes what he is doing through model attributes so BossClient animates every client in
	     sync: Action, ActionId, ActionStart, ActionSpeed, ActionTarget, ActionPath, ActionVictim,
	     Drawn, CapeOff, EyeOpen, Enraged, RigReady,
	  7. handles the phase changes (cape at CapeHealth, Ultimate Eye at EyeHealth), death and respawn.

	Animation, VFX and the knockbacks are BossClient's job (players own their own physics).
	Only player characters are ever damaged, through Humanoid:TakeDamage (so ForceFields work).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local PathfindingService = game:GetService("PathfindingService")

local model = script.Parent
if not (model and model:IsA("Model")) then
	warn("[Bradley] BossServer must be a direct child of the boss Model")
	return
end

-- A copy kept in ReplicatedStorage (or similar) idles here until it is put in the Workspace.
while not model:IsDescendantOf(workspace) do
	model.AncestryChanged:Wait()
end

local Config = require(model:WaitForChild("Config"))
local Motion = require(model:WaitForChild("Motion"))
local Actions = Config.Actions
local Cooldowns = Config.Cooldowns

local humanoid = model:FindFirstChildOfClass("Humanoid")
local hrp = model:FindFirstChild("HumanoidRootPart")
if not humanoid or not (hrp and hrp:IsA("BasePart")) then
	warn("[Bradley] the boss model needs a Humanoid and a HumanoidRootPart")
	return
end

-- ---------------------------------------------------------------------------------------------
-- Tuning that is not in Config (studs are multiplied by the model scale)
-- ---------------------------------------------------------------------------------------------
local DEBUG = false
local TEMPLATE_FOLDER = "KingBradleyTemplates"
local WEAPON_HITBOXES = true -- invisible hitboxes parented to the model (player weapons find him)
local HIP_HEIGHT = 4 -- HumanoidRootPart bottom is 4 studs above the soles

local AI_TICK = 0.1
local MOVE_REFRESH = 0.25
local RETARGET_EVERY = 0.5
local CHASE_STOP = 5.5 -- stops this far (flat) from his target
local SEE_THROUGH_WALLS = 50
local LOST_TARGET_RESET = 6
local RETURN_TIMEOUT = 30
local HOME_RADIUS = 5
local FALL_LIMIT = 80
local ACTION_GAP = 0.45 -- breathing room between two actions (x0.6 in phase 2)
local PROVOKE_TIME = 8
local SHEATHE_AFTER = 8 -- seconds idle at home before he sheathes his sabers
local HAND_OFFSET = Vector3.new(1.3, 1.6, -0.6) -- right hand at shoulder height (throws)

local TURN = {
	chase = math.rad(300),
	windUp = math.rad(420),
	slow = math.rad(90),
	home = math.rad(160),
	lock = math.rad(600),
}

-- ---------------------------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------------------------
local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local yawOf = Motion.yawOf

local function angleBetween(a: number, b: number): number
	local d = a - b
	return math.abs(math.atan2(math.sin(d), math.cos(d)))
end

local function closestOnSegment(p: Vector3, a: Vector3, b: Vector3): Vector3
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-9 then
		return a
	end
	return a + ab * math.clamp((p - a):Dot(ab) / len2, 0, 1)
end

local function pointSegmentDistance(p: Vector3, a: Vector3, b: Vector3): number
	return (p - closestOnSegment(p, a, b)).Magnitude
end

-- Shortest distance between segments p1-q1 and p2-q2 (Ericson, Real-Time Collision Detection 5.1.9).
local function segmentDistance(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3): number
	local d1, d2, r = q1 - p1, q2 - p2, p1 - p2
	local a, e, f = d1:Dot(d1), d2:Dot(d2), d2:Dot(r)
	local s, t
	if a <= 1e-9 and e <= 1e-9 then
		return r.Magnitude
	elseif a <= 1e-9 then
		s, t = 0, math.clamp(f / e, 0, 1)
	else
		local c = d1:Dot(r)
		if e <= 1e-9 then
			s, t = math.clamp(-c / a, 0, 1), 0
		else
			local b = d1:Dot(d2)
			local denom = a * e - b * b
			s = if denom > 1e-9 then math.clamp((b * f - c * e) / denom, 0, 1) else 0
			t = (b * s + f) / e
			if t < 0 then
				s, t = math.clamp(-c / a, 0, 1), 0
			elseif t > 1 then
				s, t = math.clamp((b - c) / a, 0, 1), 1
			end
		end
	end
	return ((p1 + d1 * s) - (p2 + d2 * t)).Magnitude
end

local function log(...)
	if DEBUG then
		print("[Bradley]", ...)
	end
end

-- ---------------------------------------------------------------------------------------------
-- 1. Respawn template (taken before anything is changed)
-- ---------------------------------------------------------------------------------------------
local respawnTime = Config.RespawnTime
local canRespawn = type(respawnTime) == "number" and respawnTime >= 0
local template: Model? = nil

if canRespawn then
	local wasArchivable = model.Archivable
	model.Archivable = true
	template = model:Clone()
	model.Archivable = wasArchivable
	if template then
		local brain = template:FindFirstChild(script.Name)
		if brain and brain:IsA("BaseScript") then
			brain.Enabled = false
		end
		local folder = ServerStorage:FindFirstChild(TEMPLATE_FOLDER)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = TEMPLATE_FOLDER
			folder.Parent = ServerStorage
		end
		template.Parent = folder
	else
		warn("[Bradley] could not copy the boss for respawning (is part of it not Archivable?)")
	end
end

local homeCF = model:GetPivot()
local homePos = hrp.Position
local homeYaw = yawOf(hrp.CFrame.LookVector) or 0

local scale: number = 1
do
	local ok, s = pcall(function()
		return model:GetScale()
	end)
	if ok and type(s) == "number" and s > 0 then
		scale = s
	end
end

-- ---------------------------------------------------------------------------------------------
-- 2. Runtime rig
-- ---------------------------------------------------------------------------------------------
local rigParts: { BasePart } = {}
local hitParts: { { any } } = {}
local motorCount: number, weldCount: number = 0, 0

local function isBoneName(name: string): boolean
	return string.sub(name, 1, 2) == "B_"
end

local function weldTo(bone: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "BoneWeld"
	weld.Part0 = bone
	weld.Part1 = part
	weld.Parent = part
	weldCount += 1
end

local function buildBone(bone: BasePart, parentBone: BasePart?)
	table.insert(rigParts, bone)
	if parentBone then
		local old = bone:FindFirstChild(bone.Name)
		if old and old:IsA("JointInstance") then
			old:Destroy()
		end
		local motor = Instance.new("Motor6D")
		motor.Name = bone.Name
		motor.Part0 = parentBone
		motor.Part1 = bone
		motor.C0 = parentBone.CFrame:Inverse() * bone.CFrame
		motor.C1 = CFrame.identity
		motor.Parent = bone
		motorCount += 1
	end
	local function visit(container: Instance)
		for _, child in container:GetChildren() do
			if child:IsA("BasePart") then
				if isBoneName(child.Name) then
					buildBone(child, bone)
				else
					weldTo(bone, child)
					table.insert(rigParts, child)
					if child.CanQuery and child.CanTouch then
						table.insert(hitParts, { child, bone })
					end
					visit(child)
				end
			elseif child:IsA("Folder") or child:IsA("Model") then
				visit(child)
			end
		end
	end
	visit(bone)
end

-- Weapon hitboxes: invisible, slightly larger copies of the body parts, direct children of the
-- model (so `hit.Parent:FindFirstChildOfClass("Humanoid")` finds the boss), welded to the bone.
local function buildHitbox(part: BasePart, bone: BasePart)
	local size = part.Size
	local mesh = part:FindFirstChildOfClass("SpecialMesh")
	local shape = if part:IsA("Part") then part.Shape else Enum.PartType.Block
	local round = false
	if mesh then
		size = size * mesh.Scale
		round = mesh.MeshType == Enum.MeshType.Sphere
	elseif shape == Enum.PartType.Ball then
		round = true
	end

	local box = Instance.new("Part")
	box.Name = "Hitbox"
	box.Transparency = 1
	box.Anchored = true
	box.CanCollide = false
	box.CanTouch = true
	box.CanQuery = true
	box.CastShadow = false
	box.Massless = true
	box.TopSurface = Enum.SurfaceType.Smooth
	box.BottomSurface = Enum.SurfaceType.Smooth

	local pad = 1.06
	local cf = part.CFrame
	if round then
		local x, y, z = size.X, size.Y, size.Z
		local long, short = math.max(x, y, z), math.min(x, y, z)
		if long <= short * 1.3 then
			box.Shape = Enum.PartType.Ball
			box.Size = Vector3.one * (long * pad)
		else
			box.Shape = Enum.PartType.Cylinder
			if long == x then
				local d = math.max(y, z)
				box.Size = Vector3.new(x, d, d) * pad
			elseif long == y then
				local d = math.max(x, z)
				cf = cf * CFrame.Angles(0, 0, math.pi / 2)
				box.Size = Vector3.new(y, d, d) * pad
			else
				local d = math.max(x, y)
				cf = cf * CFrame.Angles(0, math.pi / 2, 0)
				box.Size = Vector3.new(z, d, d) * pad
			end
		end
	elseif shape == Enum.PartType.Cylinder then
		box.Shape = Enum.PartType.Cylinder
		box.Size = size * pad
	else
		box.Size = size * pad
	end
	box.CFrame = cf
	box:SetAttribute("Hitbox", true)
	box:SetAttribute("Bone", bone.Name)
	box.Parent = model
	weldTo(bone, box)
	table.insert(rigParts, box)
	part.CanTouch = false
end

local function claimNetworkOwnership()
	if hrp.Anchored or not hrp:IsDescendantOf(workspace) then
		return
	end
	local ok, canSet = pcall(hrp.CanSetNetworkOwnership, hrp)
	if ok and canSet then
		pcall(hrp.SetNetworkOwner, hrp, nil)
	end
end

local function removeAnimator(inst: Instance)
	if inst:IsA("Animator") then
		-- An Animator would overwrite Motor6D.Transform; BossClient animates the motors itself.
		task.defer(function()
			if inst.Parent then
				inst:Destroy()
			end
		end)
	end
end

buildBone(hrp, nil)
if WEAPON_HITBOXES then
	for _, entry in hitParts do
		buildHitbox(entry[1], entry[2])
	end
end

for _, part in rigParts do
	part.Anchored = false
	part.CanCollide = part == hrp
	part.Massless = part ~= hrp
end
hrp.RootPriority = 127
hrp.CustomPhysicalProperties = PhysicalProperties.new(4, 0.4, 0, 1, 1)

if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
	humanoid.RigType = Enum.HumanoidRigType.R15 -- R15 is the rig type that honours HipHeight
end
humanoid.AutomaticScalingEnabled = false
humanoid.HipHeight = HIP_HEIGHT * scale
humanoid.MaxHealth = Config.MaxHealth
humanoid.Health = Config.MaxHealth
humanoid.WalkSpeed = Config.WalkSpeed
humanoid.BreakJointsOnDeath = false
humanoid.RequiresNeck = false
humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
humanoid.AutoRotate = true
humanoid.UseJumpPower = true
humanoid.JumpPower = 55
humanoid.MaxSlopeAngle = 60

for _, d in model:GetDescendants() do
	removeAnimator(d)
end
model.DescendantAdded:Connect(removeAnimator)

-- Facing control: Humanoid.AutoRotate while walking, this AlignOrientation while standing/attacking.
local facingAttachment = Instance.new("Attachment")
facingAttachment.Name = "BossFacingAttachment"
facingAttachment.Parent = hrp
local align = Instance.new("AlignOrientation")
align.Name = "BossFacing"
align.Mode = Enum.OrientationAlignmentMode.OneAttachment
align.Attachment0 = facingAttachment
align.RigidityEnabled = false
align.MaxTorque = math.huge
align.Responsiveness = 40
align.MaxAngularVelocity = TURN.chase
align.CFrame = CFrame.Angles(0, homeYaw, 0)
align.Enabled = false
align.Parent = hrp

local actionId = 0
model:SetAttribute("Enraged", false)
model:SetAttribute("Drawn", false)
model:SetAttribute("CapeOff", false)
model:SetAttribute("EyeOpen", false)
model:SetAttribute("ActionPath", "")
model:SetAttribute("ActionVictim", 0)
model:SetAttribute("ActionSpeed", 1)
model:SetAttribute("ActionTarget", hrp.Position + flat(hrp.CFrame.LookVector) * 10)
model:SetAttribute("ActionStart", serverNow())
model:SetAttribute("Action", "Idle")
model:SetAttribute("ActionId", actionId)

claimNetworkOwnership()
for _, state in
	{
		Enum.HumanoidStateType.FallingDown,
		Enum.HumanoidStateType.Ragdoll,
		Enum.HumanoidStateType.GettingUp,
		Enum.HumanoidStateType.Seated,
		Enum.HumanoidStateType.Climbing,
		Enum.HumanoidStateType.PlatformStanding,
		Enum.HumanoidStateType.Swimming,
		Enum.HumanoidStateType.Flying,
		Enum.HumanoidStateType.StrafingNoPhysics,
	}
do
	pcall(humanoid.SetStateEnabled, humanoid, state, false)
end

model:SetAttribute("RigReady", true)
log(string.format("rig ready: %d motors, %d welds, %d hitboxes, scale %.2f", motorCount, weldCount, #hitParts, scale))

-- ---------------------------------------------------------------------------------------------
-- Players (the only things he ever hurts)
-- ---------------------------------------------------------------------------------------------
type Victim = { player: Player, character: Model, humanoid: Humanoid, root: BasePart }

local function victimOf(player: Player): Victim?
	if player.Parent ~= Players then
		return nil
	end
	local character = player.Character
	if not character or not character:IsDescendantOf(workspace) then
		return nil
	end
	if Players:GetPlayerFromCharacter(character) ~= player then
		return nil
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 or hum:GetState() == Enum.HumanoidStateType.Dead then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		root = character.PrimaryPart
	end
	if not root then
		return nil
	end
	return { player = player, character = character, humanoid = hum, root = root }
end

local function livingVictims(): { Victim }
	local list = {}
	for _, player in Players:GetPlayers() do
		local v = victimOf(player)
		if v then
			table.insert(list, v)
		end
	end
	return list
end

-- A player's body as a vertical segment, feet to head (works for R6, R15 and scaled avatars).
local function bodySegment(v: Victim): (Vector3, Vector3)
	local p = v.root.Position
	local half = v.root.Size.Y / 2
	local legs = math.max(v.humanoid.HipHeight, 2)
	return p - Vector3.new(0, half + legs, 0), p + Vector3.new(0, half + 1.6, 0)
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true

local function refreshRayFilter()
	local list: { Instance } = { model }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

local function worldHit(from: Vector3, to: Vector3): RaycastResult?
	local dir = to - from
	if dir.Magnitude < 0.05 then
		return nil
	end
	return workspace:Raycast(from, dir, rayParams)
end

-- ---------------------------------------------------------------------------------------------
-- AI state
-- ---------------------------------------------------------------------------------------------
local rng = Random.new()
local dead = false
local inAction = false
local eyeOpen = false -- phase 2 (the Ultimate Eye)
local capeOff = false
local drawn = false
local mode = "Idle" -- "Idle" (at home), "Combat", "Return"
local target: Victim? = nil
local lastSeenTarget = 0
local lastTargetPos: Vector3? = nil
local nextRetarget = 0
local combatStart = 0
local returnStart = 0
local nextActionAt = 0
local provokedUntil = 0
local idleSince = os.clock()
local pendingCape = false
local pendingEye = false
local cdUntil: { [string]: number } = {}
for name in Cooldowns do
	cdUntil[name] = 0
end

local function alive(): boolean
	return not dead and model.Parent ~= nil and hrp.Parent ~= nil
end

local function runSpeed(): number
	return if eyeOpen then Config.EyeRunSpeed else Config.RunSpeed
end

-- Basic attacks speed up in phase 2; transitions and eye abilities always play at 1x.
local function attackSpeed(): number
	return if eyeOpen then Config.EyeSpeedBoost else 1
end

local function cooldownScale(basic: boolean): number
	return if eyeOpen and basic then Config.EyeCooldownScale else 1
end

local function setCooldown(name: string, basic: boolean)
	cdUntil[name] = os.clock() + (Cooldowns[name] or 5) * cooldownScale(basic)
end

local function ready(name: string): boolean
	return os.clock() >= (cdUntil[name] or 0)
end

-- ---------------------------------------------------------------------------------------------
-- Facing (runs every frame; only writes constraint properties when they change)
-- ---------------------------------------------------------------------------------------------
local face = { mode = "none", point = nil :: Vector3?, yaw = 0, rate = TURN.chase }
local lastAlignYaw: number? = nil
local motion: { path: { any }, start: number }? = nil

local function setFacing(newMode: string, rate: number?, arg: any?)
	face.mode = newMode
	face.rate = rate or face.rate
	if newMode == "point" then
		face.point = arg
	elseif newMode == "yaw" then
		face.yaw = arg
	elseif newMode == "hold" then
		face.mode = "yaw"
		face.yaw = yawOf(hrp.CFrame.LookVector) or face.yaw
	end
end

local function stepFacing()
	if dead or motion then
		return
	end
	if face.mode == "none" then
		if align.Enabled then
			align.Enabled = false
		end
		if not humanoid.AutoRotate then
			humanoid.AutoRotate = true
		end
		lastAlignYaw = nil
		return
	end
	if humanoid.AutoRotate then
		humanoid.AutoRotate = false
	end
	local yaw: number? = nil
	if face.mode == "yaw" then
		yaw = face.yaw
	else
		local p = face.point
		if face.mode == "target" then
			local t = target
			if t and t.root.Parent then
				p = t.root.Position
			end
		end
		if p then
			yaw = yawOf(p - hrp.Position)
		end
	end
	yaw = yaw or lastAlignYaw or yawOf(hrp.CFrame.LookVector) or 0
	if align.MaxAngularVelocity ~= face.rate then
		align.MaxAngularVelocity = face.rate
	end
	if lastAlignYaw == nil or angleBetween(yaw :: number, lastAlignYaw :: number) > 0.005 then
		align.CFrame = CFrame.Angles(0, yaw :: number, 0)
		lastAlignYaw = yaw
	end
	if not align.Enabled then
		align.Enabled = true
	end
end

-- ---------------------------------------------------------------------------------------------
-- Scripted root motion (dashes, leaps): anchored root moved along a Motion path
-- ---------------------------------------------------------------------------------------------
local function stopMotion()
	local m = motion
	if not m then
		return
	end
	motion = nil
	if dead or not hrp.Parent then
		return
	end
	hrp.Anchored = false
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	claimNetworkOwnership()
	local _, yaw = Motion.sample(m.path, math.huge)
	setFacing("yaw", TURN.windUp, yaw)
	lastAlignYaw = nil
end

local function stepMotion()
	local m = motion
	if not m or dead then
		return
	end
	local t = serverNow() - m.start
	if t < m.path[1].t then
		return
	end
	if not hrp.Anchored then
		align.Enabled = false
		hrp.Anchored = true
	end
	hrp.CFrame = Motion.cframe(m.path, t)
	if t >= Motion.endTime(m.path) then
		stopMotion()
	end
end

local function startMotion(path: { any }, start: number)
	motion = { path = path, start = start }
	model:SetAttribute("ActionPath", Motion.encode(path))
end

RunService.Heartbeat:Connect(function()
	stepMotion()
	stepFacing()
end)

-- ---------------------------------------------------------------------------------------------
-- Ground and walls for the scripted paths
-- ---------------------------------------------------------------------------------------------
local function rootHeight(): number
	return humanoid.HipHeight + hrp.Size.Y / 2
end

local function feetY(): number
	return hrp.Position.Y - rootHeight()
end

-- Ground under p (searching from a little above). nil if there is none within reach.
local function groundAt(p: Vector3, up: number?, down: number?): number?
	local top = Vector3.new(p.X, p.Y + (up or 6) * scale, p.Z)
	local hit = workspace:Raycast(top, Vector3.new(0, -((up or 6) + (down or 30)) * scale, 0), rayParams)
	return if hit then hit.Position.Y else nil
end

-- Root position standing on the ground at p's X/Z (or at fallbackY when there is no ground).
local function rootOnGround(p: Vector3, fallbackY: number): (Vector3, boolean)
	local g = groundAt(Vector3.new(p.X, fallbackY, p.Z), 8, 30)
	if g then
		return Vector3.new(p.X, g + rootHeight(), p.Z), true
	end
	return Vector3.new(p.X, fallbackY, p.Z), false
end

-- Walks a straight line from a to b (root height) and stops `margin` before the first wall.
-- Also stops before a drop (no ground under the line).
local function clampTravel(a: Vector3, b: Vector3, margin: number): Vector3
	local dir = flat(b - a)
	local dist = dir.Magnitude
	if dist < 0.1 then
		return a
	end
	dir = dir / dist
	local reach = dist
	for _, h in { 0, -rootHeight() + 1.2 * scale } do
		local from = a + Vector3.new(0, h, 0)
		local hit = workspace:Raycast(from, dir * (dist + margin), rayParams)
		if hit and math.abs(hit.Normal.Y) < 0.6 then
			reach = math.min(reach, math.max(0, hit.Distance - margin))
		end
	end
	-- no walking off cliffs: step back until there is ground
	local step = 2 * scale
	local d = reach
	while d > 0 do
		local p = a + dir * d
		if groundAt(p, 4, rootHeight() / scale + 6) then
			break
		end
		d -= step
	end
	return a + dir * math.max(d, 0)
end

-- ---------------------------------------------------------------------------------------------
-- Movement: MoveTo refresh, pathfinding fallback, unsticking
-- ---------------------------------------------------------------------------------------------
local path = PathfindingService:CreatePath({
	AgentRadius = 2.5 * scale,
	AgentHeight = 9 * scale,
	AgentCanJump = true,
	AgentCanClimb = false,
	WaypointSpacing = 6,
	Costs = { Water = 20 },
})

local move = {
	moving = false,
	issued = nil :: Vector3?,
	lastIssue = 0,
	timedOut = false,
	waypoints = nil :: { PathWaypoint }?,
	wpIndex = 0,
	pathGoal = nil :: Vector3?,
	pathAt = -math.huge,
	computing = false,
	token = 0,
	usePathUntil = 0,
	blocked = false,
	blockedCheckAt = 0,
	lastPos = hrp.Position,
	progressAt = os.clock(),
	stuckFor = 0,
	lastJump = 0,
	sidestepGoal = nil :: Vector3?,
	sidestepUntil = 0,
	speed = Config.WalkSpeed,
}

humanoid.MoveToFinished:Connect(function(reached)
	if not reached then
		move.timedOut = true
	end
end)

local function stopMoving()
	if move.moving or move.issued then
		humanoid:Move(Vector3.zero, false)
		humanoid:MoveTo(hrp.Position)
	end
	move.moving = false
	move.issued = nil
	move.waypoints = nil
	move.sidestepGoal = nil
	move.stuckFor = 0
end

local function jump()
	local clock = os.clock()
	if clock - move.lastJump > 1.2 then
		move.lastJump = clock
		humanoid.Jump = true
	end
end

local function directBlocked(goal: Vector3, dist: number): boolean
	local base = Vector3.new(hrp.Position.X, feetY(), hrp.Position.Z)
	local dir = flat(goal - base)
	if dir.Magnitude < 1 then
		return false
	end
	dir = dir.Unit * math.min(dist, 25 * scale)
	for _, h in { 1.8, 5.5 } do
		local hit = workspace:Raycast(base + Vector3.new(0, h * scale, 0), dir, rayParams)
		if hit and math.abs(hit.Normal.Y) < 0.6 then
			return true
		end
	end
	return false
end

local function requestPath(goal: Vector3)
	if move.computing then
		return
	end
	local clock = os.clock()
	if move.pathGoal and (move.pathGoal - goal).Magnitude < 5 * scale and clock - move.pathAt < 2 then
		return
	end
	move.computing = true
	move.token += 1
	local token = move.token
	local start = hrp.Position
	task.spawn(function()
		local ok = pcall(function()
			path:ComputeAsync(start, goal)
		end)
		move.computing = false
		if dead or token ~= move.token then
			return
		end
		move.pathAt = os.clock()
		move.pathGoal = goal
		if ok and path.Status == Enum.PathStatus.Success then
			move.waypoints = path:GetWaypoints()
			move.wpIndex = 2
		else
			move.waypoints = nil
		end
	end)
end

local function nextWaypoint(): Vector3?
	local wps = move.waypoints
	if not wps then
		return nil
	end
	local pos = hrp.Position
	while move.wpIndex <= #wps do
		local wp = wps[move.wpIndex]
		local d = flatDist(wp.Position, pos)
		if d < 3 * scale then
			move.wpIndex += 1
		else
			if wp.Action == Enum.PathWaypointAction.Jump and d < 8 * scale then
				jump()
			end
			return wp.Position
		end
	end
	move.waypoints = nil
	return nil
end

-- Walks (or sprints) toward goal; returns true once within stopDist (flat).
local function drive(goal: Vector3, stopDist: number, speed: number): boolean
	local clock = os.clock()
	local pos = hrp.Position
	local toGoal = flat(goal - pos)
	local dist = toGoal.Magnitude
	if dist <= stopDist then
		stopMoving()
		return true
	end
	if humanoid.WalkSpeed ~= speed then
		humanoid.WalkSpeed = speed
	end
	if not move.moving then
		move.moving = true
		move.lastPos = pos
		move.progressAt = clock
		move.stuckFor = 0
	end

	local elapsed = clock - move.progressAt
	if elapsed >= 0.5 then
		local moved = flatDist(pos, move.lastPos)
		if moved < humanoid.WalkSpeed * elapsed * 0.2 then
			move.stuckFor += elapsed
		else
			move.stuckFor = 0
		end
		move.lastPos = pos
		move.progressAt = clock
		if move.stuckFor >= 0.9 then
			jump()
		end
		if move.stuckFor >= 2 then
			move.usePathUntil = clock + 6
		end
		if move.stuckFor >= 3.5 and clock >= move.sidestepUntil and dist > 0.1 then
			local dir = toGoal.Unit
			local side = Vector3.new(-dir.Z, 0, dir.X) * (if rng:NextNumber() < 0.5 then -1 else 1)
			move.sidestepGoal = pos + (side * 8 - dir * 2) * scale
			move.sidestepUntil = clock + 1
			move.stuckFor = 1
			move.pathAt = -math.huge
		end
	end

	if clock >= move.blockedCheckAt then
		move.blockedCheckAt = clock + 0.5
		move.blocked = directBlocked(goal, dist)
	end
	local dest = goal
	if move.blocked or clock < move.usePathUntil then
		requestPath(goal)
		dest = nextWaypoint() or goal
	else
		move.waypoints = nil
	end
	if move.sidestepGoal and clock < move.sidestepUntil then
		dest = move.sidestepGoal
	end

	if move.timedOut or not move.issued or clock - move.lastIssue >= MOVE_REFRESH or (move.issued - dest).Magnitude > 2 then
		move.timedOut = false
		move.issued = dest
		move.lastIssue = clock
		humanoid:MoveTo(dest)
	end
	return false
end

-- ---------------------------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------------------------
local function publish(action: string, actionTarget: Vector3?, speed: number?, victim: Player?): number
	actionId += 1
	local start = serverNow()
	if actionTarget then
		model:SetAttribute("ActionTarget", actionTarget)
	end
	model:SetAttribute("ActionPath", "")
	model:SetAttribute("ActionVictim", if victim then victim.UserId else 0)
	model:SetAttribute("ActionSpeed", speed or 1)
	model:SetAttribute("ActionStart", start)
	model:SetAttribute("Action", action)
	model:SetAttribute("ActionId", actionId)
	log(("action %s #%d x%.2f"):format(action, actionId, speed or 1))
	return start
end

local function beginAction(name: string, actionTarget: Vector3?, speed: number?, victim: Player?): number
	inAction = true
	stopMoving()
	humanoid.WalkSpeed = 0
	return publish(name, actionTarget, speed, victim)
end

local function endAction()
	stopMotion()
	inAction = false
	if dead then
		return
	end
	setFacing("hold")
	publish("Idle", nil, 1, nil)
	humanoid.WalkSpeed = Config.WalkSpeed
	nextActionAt = os.clock() + ACTION_GAP * (if eyeOpen then 0.6 else 1)
end

-- Action clock: `at(x)` is the server time of action-second x (x / speed after the start).
local function clockOf(start: number, speed: number)
	return function(x: number): number
		return start + x / speed
	end
end

local function waitUntil(t: number): boolean
	while alive() do
		local remaining = t - serverNow()
		if remaining <= 0 then
			return true
		end
		task.wait(math.min(remaining, 0.03))
	end
	return false
end

local function hurt(v: Victim, amount: number)
	local hum = v.humanoid
	if hum.Health <= 0 or not hum:IsDescendantOf(workspace) then
		return
	end
	if Players:GetPlayerFromCharacter(v.character) ~= v.player then
		return
	end
	hum:TakeDamage(amount)
end

local function refreshTarget()
	local t = target
	if t then
		target = victimOf(t.player)
	end
end

local function lookFlat(): Vector3
	local look = flat(hrp.CFrame.LookVector)
	return if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
end

local function frontPoint(): Vector3
	return hrp.Position + lookFlat() * (10 * scale)
end

-- Where a target will be in `lead` seconds (flat velocity; the Ultimate Eye reads movement).
local function predicted(v: Victim, lead: number): Vector3
	local vel = flat(v.root.AssemblyLinearVelocity)
	if vel.Magnitude > 40 then
		vel = vel.Unit * 40
	end
	return v.root.Position + vel * lead
end

-- Players in front of him (half-angle arcDeg) within range of the root at pos/look.
local function frontalHits(pos: Vector3, look: Vector3, range: number, arcDeg: number, fn: (Victim) -> ())
	local cosA = math.cos(math.rad(arcDeg))
	for _, v in livingVictims() do
		local a, b = bodySegment(v)
		local closest = closestOnSegment(pos, a, b)
		local off = closest - pos
		local d = flat(off).Magnitude
		if d <= range and math.abs(off.Y) <= 7 * scale then
			if d < 2.5 * scale or flat(off).Unit:Dot(look) >= cosA then
				fn(v)
			end
		end
	end
end

-- ---- Draw / Sheathe ---------------------------------------------------------------------------
local function doDraw()
	local cfg = Actions.Draw
	local t = target
	local start = beginAction("Draw", if t then t.root.Position else frontPoint(), 1)
	setFacing(if t then "target" else "hold", TURN.slow)
	if not waitUntil(start + cfg.DrawAt) then
		return
	end
	drawn = true
	model:SetAttribute("Drawn", true)
	if not waitUntil(start + cfg.Duration) then
		return
	end
	endAction()
end

local function doSheathe()
	local cfg = Actions.Sheathe
	local start = beginAction("Sheathe", frontPoint(), 1)
	setFacing("hold")
	if not waitUntil(start + cfg.SheatheAt) then
		return
	end
	drawn = false
	model:SetAttribute("Drawn", false)
	if not waitUntil(start + cfg.Duration) then
		return
	end
	endAction()
end

-- ---- Phase transitions ------------------------------------------------------------------------
local function doRemoveCape()
	local cfg = Actions.RemoveCape
	pendingCape = false
	local t = target
	local start = beginAction("RemoveCape", if t then t.root.Position else frontPoint(), 1)
	setFacing(if t then "target" else "hold", TURN.slow)
	if not waitUntil(start + cfg.ReleaseAt) then
		return
	end
	capeOff = true
	model:SetAttribute("CapeOff", true)
	if not waitUntil(start + cfg.Duration) then
		return
	end
	endAction()
end

local function doRemoveEyepatch()
	local cfg = Actions.RemoveEyepatch
	pendingEye = false
	local t = target
	local start = beginAction("RemoveEyepatch", if t then t.root.Position else frontPoint(), 1)
	setFacing(if t then "target" else "hold", TURN.slow)
	if not waitUntil(start + cfg.TearAt) then
		return
	end
	model:SetAttribute("EyeOpen", true)
	if not waitUntil(start + cfg.OpenAt) then
		return
	end
	eyeOpen = true
	model:SetAttribute("Enraged", true)
	model:SetAttribute("Subtitle", Config.EyeSubtitle)
	-- the eye opens with a pressure wave (knockback is applied by each client)
	local radius = cfg.ShockRadius * scale
	for _, v in livingVictims() do
		if flatDist(v.root.Position, hrp.Position) <= radius and math.abs(v.root.Position.Y - hrp.Position.Y) < 10 * scale then
			hurt(v, cfg.ShockDamage)
		end
	end
	-- the eye abilities are ready right away
	cdUntil.ThousandCuts = os.clock() + 1.5
	cdUntil.PhantomStep = os.clock() + 6
	if not waitUntil(start + cfg.Duration) then
		return
	end
	endAction()
end

-- ---- Lunge: crouch, then a straight dash through the target --------------------------------------
local function doLunge()
	local cfg = Actions.Lunge
	local spd = attackSpeed()
	setCooldown("Lunge", true)
	local t = target
	local start = beginAction("Lunge", if t then t.root.Position else frontPoint(), spd, if t then t.player else nil)
	local at = clockOf(start, spd)
	setFacing("target", TURN.windUp)
	-- the direction locks a beat before the dash (moving sideways during the wind-up dodges it)
	if not waitUntil(at(cfg.Dash[1]) - 0.12) then
		return
	end
	refreshTarget()
	t = target
	refreshRayFilter()
	local from = hrp.Position
	local aim = if t then (if eyeOpen then predicted(t, 0.15) else t.root.Position) else frontPoint()
	local dir = flat(aim - from)
	if dir.Magnitude < 0.5 then
		dir = lookFlat()
	end
	local dist = math.min(dir.Magnitude + cfg.Overshoot * scale, cfg.Range * scale)
	dir = dir.Unit
	local goal = clampTravel(from, from + dir * dist, 3 * scale)
	goal = rootOnGround(goal, from.Y)
	local yaw = yawOf(dir) or 0
	local t0 = (cfg.Dash[1]) / spd
	local t1 = (cfg.Dash[2]) / spd
	startMotion({ Motion.key(t0, from, yaw, "l"), Motion.key(t1, goal, yaw, "o") }, start)
	model:SetAttribute("ActionTarget", goal)

	-- hit everyone along the dash line (once), checked as he passes
	local hitSet: { [Player]: boolean } = {}
	local radius = cfg.HitRadius * scale
	while alive() and serverNow() < at(cfg.Dash[2]) + 0.05 do
		local tt = serverNow() - start
		local p = Motion.sample(motion and motion.path or { Motion.key(0, goal, yaw) }, tt)
		for _, v in livingVictims() do
			if not hitSet[v.player] then
				local a, b = bodySegment(v)
				if segmentDistance(from, p, a, b) <= radius then
					hitSet[v.player] = true
					hurt(v, cfg.Damage)
				end
			end
		end
		task.wait(1 / 30)
	end
	if not waitUntil(at(cfg.Duration)) then
		return
	end
	endAction()
end

-- ---- Cross Cut: three cuts with a step each ---------------------------------------------------------
local function doCrossCut()
	local cfg = Actions.CrossCut
	local spd = attackSpeed()
	setCooldown("CrossCut", true)
	local t = target
	local start = beginAction("CrossCut", if t then t.root.Position else frontPoint(), spd)
	local at = clockOf(start, spd)
	setFacing("target", TURN.windUp)
	refreshRayFilter()
	-- steps: built now (short, wall-clamped) so every client sees the same advance
	local pos = hrp.Position
	local look = lookFlat()
	if t then
		local d = flat(t.root.Position - pos)
		if d.Magnitude > 0.5 then
			look = d.Unit
		end
	end
	local yaw = yawOf(look) or 0
	local keys = { Motion.key(math.max(cfg.Hits[1] - 0.12, 0) / spd, pos, yaw, "l") }
	local p = pos
	for i, h in cfg.Hits do
		local nextP = clampTravel(p, p + look * (cfg.Step * scale), 2.5 * scale)
		nextP = rootOnGround(nextP, p.Y)
		table.insert(keys, Motion.key(h / spd, nextP, yaw, "o"))
		if i < #cfg.Hits then
			table.insert(keys, Motion.key((cfg.Hits[i + 1] - 0.12) / spd, nextP, yaw, "h"))
		end
		p = nextP
	end
	-- the facing still tracks the target until the first cut
	if not waitUntil(at(cfg.Hits[1]) - 0.14) then
		return
	end
	startMotion(keys, start)
	for i, h in cfg.Hits do
		if not waitUntil(at(h)) then
			return
		end
		local dmg = if i == #cfg.Hits then cfg.FinalDamage else cfg.Damage
		frontalHits(hrp.Position, lookFlat(), cfg.Range * scale, cfg.Arc, function(v)
			hurt(v, dmg)
		end)
	end
	if not waitUntil(at(cfg.Duration)) then
		return
	end
	endAction()
end

-- ---- Saber Throw: a javelin throw of the left saber --------------------------------------------------
local function doSaberThrow()
	local cfg = Actions.SaberThrow
	local spd = attackSpeed()
	setCooldown("SaberThrow", true)
	local t = target
	local start = beginAction("SaberThrow", if t then t.root.Position else frontPoint(), spd, if t then t.player else nil)
	local at = clockOf(start, spd)
	setFacing("target", TURN.windUp)
	if not waitUntil(at(cfg.ReleaseAt) - 0.05) then
		return
	end
	refreshTarget()
	t = target
	refreshRayFilter()
	local origin = hrp.CFrame:PointToWorldSpace(Vector3.new(-HAND_OFFSET.X, HAND_OFFSET.Y, HAND_OFFSET.Z) * scale)
	local speed = cfg.Speed * scale
	local aim
	if t then
		local travel = (t.root.Position - origin).Magnitude / speed
		aim = if eyeOpen then predicted(t, travel) else t.root.Position
	else
		aim = frontPoint()
	end
	local dir = aim - origin
	if dir.Magnitude < 0.5 then
		dir = lookFlat()
	end
	dir = dir.Unit
	local range = cfg.Range * scale
	local hit = workspace:Raycast(origin, dir * range, rayParams)
	local impact = if hit then hit.Position else origin + dir * range
	model:SetAttribute("ActionTarget", impact)
	setFacing("point", TURN.windUp, impact)

	local release = at(cfg.ReleaseAt)
	local total = (impact - origin).Magnitude / speed
	local hitSet: { [Player]: boolean } = {}
	local prev = origin
	local radius = cfg.HitRadius * scale
	if not waitUntil(release) then
		return
	end
	while alive() do
		local e = serverNow() - release
		local u = math.min(e / math.max(total, 1e-3), 1)
		local tip = origin:Lerp(impact, u)
		for _, v in livingVictims() do
			if not hitSet[v.player] then
				local a, b = bodySegment(v)
				if segmentDistance(prev, tip, a, b) <= radius then
					hitSet[v.player] = true
					hurt(v, cfg.Damage)
				end
			end
		end
		prev = tip
		if u >= 1 then
			break
		end
		task.wait(1 / 30)
	end
	local splash = cfg.SplashRadius * scale
	for _, v in livingVictims() do
		if not hitSet[v.player] then
			local a, b = bodySegment(v)
			if pointSegmentDistance(impact, a, b) <= splash then
				hurt(v, cfg.SplashDamage)
			end
		end
	end
	if not waitUntil(at(cfg.Duration)) then
		return
	end
	endAction()
end

-- ---- Tank Cleaver: leap and split the ground ----------------------------------------------------------
local function doCleave()
	local cfg = Actions.Cleave
	local spd = attackSpeed()
	setCooldown("Cleave", true)
	local t = target
	local start = beginAction("Cleave", if t then t.root.Position else frontPoint(), spd)
	local at = clockOf(start, spd)
	setFacing("target", TURN.windUp)
	if not waitUntil(at(cfg.Leap[1]) - 0.05) then
		return
	end
	refreshTarget()
	t = target
	refreshRayFilter()
	local from = hrp.Position
	local aim = if t then (if eyeOpen then predicted(t, 0.5) else t.root.Position) else frontPoint()
	local dir = flat(aim - from)
	local dist = dir.Magnitude
	if dist < 0.5 then
		dir, dist = lookFlat(), 0
	else
		dir = dir.Unit
	end
	-- he lands just short of the target so the blades come down on them
	dist = math.clamp(dist - 3 * scale, 0, cfg.MaxLeap * scale)
	local goal = from + dir * dist
	-- clear the arc: only land where there is ground and nothing solid in the way at mid height
	local top = from + Vector3.new(0, cfg.LeapHeight * 0.6 * scale, 0)
	local blocked = worldHit(top, goal + Vector3.new(0, cfg.LeapHeight * 0.6 * scale, 0))
	if blocked then
		goal = clampTravel(from, goal, 3 * scale)
	end
	local landed
	goal, landed = rootOnGround(goal, from.Y)
	if not landed then
		goal = from
	end
	local yaw = yawOf(dir) or (yawOf(hrp.CFrame.LookVector) or 0)
	startMotion({
		Motion.key(cfg.Leap[1] / spd, from, yaw, "l"),
		Motion.key(cfg.Leap[2] / spd, goal, yaw, "l", cfg.LeapHeight * scale),
	}, start)
	local groundY = goal.Y - rootHeight()
	local impact = Vector3.new(goal.X, groundY, goal.Z) + dir * (2.5 * scale)
	model:SetAttribute("ActionTarget", impact)
	if not waitUntil(at(cfg.ImpactAt)) then
		return
	end
	local radius = cfg.Radius * scale
	local fissureEnd = clampTravel(impact + Vector3.new(0, rootHeight(), 0), impact + Vector3.new(0, rootHeight(), 0) + dir * (cfg.FissureLength * scale), 1)
	fissureEnd -= Vector3.new(0, rootHeight(), 0)
	local half = cfg.FissureWidth * 0.5 * scale
	for _, v in livingVictims() do
		local a, b = bodySegment(v)
		local feetAbove = a.Y - impact.Y
		if feetAbove <= 5 * scale and b.Y >= impact.Y - 4 * scale then
			if flatDist(v.root.Position, impact) <= radius then
				hurt(v, cfg.Damage)
			elseif pointSegmentDistance(Vector3.new(v.root.Position.X, impact.Y, v.root.Position.Z), impact, Vector3.new(fissureEnd.X, impact.Y, fissureEnd.Z)) <= half then
				hurt(v, cfg.FissureDamage)
			end
		end
	end
	if not waitUntil(at(cfg.Duration)) then
		return
	end
	endAction()
end

-- ---- Ultimate Eye: Thousand Cuts ------------------------------------------------------------------------
local function doThousandCuts()
	local cfg = Actions.ThousandCuts
	setCooldown("ThousandCuts", false)
	local t = target
	local start = beginAction("ThousandCuts", if t then t.root.Position else frontPoint(), 1, if t then t.player else nil)
	setFacing("target", TURN.lock)
	if not waitUntil(start + cfg.Flurry[1] - 0.06) then
		return
	end
	refreshRayFilter()
	local from = hrp.Position
	local look = lookFlat()
	refreshTarget()
	t = target
	if t then
		local d = flat(t.root.Position - from)
		if d.Magnitude > 0.5 then
			look = d.Unit
		end
	end
	local yaw = yawOf(look) or 0
	local goal = rootOnGround(clampTravel(from, from + look * (cfg.Advance * scale), 3 * scale), from.Y)
	startMotion({ Motion.key(cfg.Flurry[1], from, yaw, "l"), Motion.key(cfg.Flurry[2], goal, yaw, "l") }, start)

	local n = math.max(1, cfg.Slashes)
	local span = cfg.Flurry[2] - cfg.Flurry[1]
	for i = 1, n do
		if not waitUntil(start + cfg.Flurry[1] + span * (i - 0.5) / n) then
			return
		end
		frontalHits(hrp.Position, lookFlat(), cfg.Range * scale, cfg.Arc, function(v)
			hurt(v, cfg.TickDamage)
		end)
	end
	if not waitUntil(start + cfg.FinalAt) then
		return
	end
	-- the cross-shaped wave tears forward along the floor
	refreshRayFilter()
	local origin = hrp.Position
	look = lookFlat()
	local waveEnd = clampTravel(origin, origin + look * (cfg.WaveLength * scale), 1)
	model:SetAttribute("ActionTarget", waveEnd)
	local speed = cfg.WaveSpeed * scale
	local total = (waveEnd - origin).Magnitude / speed
	local released = serverNow()
	local hitSet: { [Player]: boolean } = {}
	local half = cfg.WaveWidth * 0.5 * scale
	local prev = origin
	while alive() do
		local u = math.min((serverNow() - released) / math.max(total, 1e-3), 1)
		local front = origin:Lerp(waveEnd, u)
		for _, v in livingVictims() do
			if not hitSet[v.player] then
				local a, b = bodySegment(v)
				local lo = Vector3.new(prev.X, a.Y, prev.Z)
				local hi = Vector3.new(front.X, a.Y, front.Z)
				if pointSegmentDistance(Vector3.new(v.root.Position.X, a.Y, v.root.Position.Z), lo, hi) <= half and math.abs(v.root.Position.Y - origin.Y) <= 9 * scale then
					hitSet[v.player] = true
					hurt(v, cfg.WaveDamage)
				end
			end
		end
		prev = front
		if u >= 1 then
			break
		end
		task.wait(1 / 30)
	end
	if not waitUntil(start + cfg.Duration) then
		return
	end
	endAction()
end

-- ---- Ultimate Eye: Phantom Step -------------------------------------------------------------------------
local function doPhantomStep()
	local cfg = Actions.PhantomStep
	setCooldown("PhantomStep", false)
	local t = target
	if not t then
		return
	end
	local start = beginAction("PhantomStep", t.root.Position, 1, t.player)
	setFacing("target", TURN.lock)
	-- the lock-on: the eye follows the victim (clients show the reticle under them)
	while alive() and serverNow() < start + cfg.Lock[2] - 0.08 do
		refreshTarget()
		if target then
			model:SetAttribute("ActionTarget", target.root.Position)
		end
		task.wait(0.05)
	end
	if not alive() then
		return
	end
	refreshTarget()
	t = target
	refreshRayFilter()
	local from = hrp.Position
	local center = if t then predicted(t, cfg.Lead) else (model:GetAttribute("ActionTarget") :: Vector3? or frontPoint())
	-- the pentagram never reaches farther than a long dash from where he stands
	local off = flat(center - from)
	local maxReach = (cfg.Radius + 30) * scale
	if off.Magnitude > maxReach then
		center = from + off.Unit * maxReach
	end
	local centerRoot = rootOnGround(Vector3.new(center.X, from.Y, center.Z), from.Y)
	local R = cfg.Radius * scale
	local startAngle = math.atan2(from.X - centerRoot.X, from.Z - centerRoot.Z)
	local nPts = math.max(3, cfg.Points)
	local pts = {}
	for k = 0, nPts do
		-- star polygon {n/2}: every point skips one, so each cut crosses the middle
		local a = startAngle + (k * 2) * (2 * math.pi / nPts)
		local want = centerRoot + Vector3.new(math.sin(a), 0, math.cos(a)) * R
		local p = clampTravel(centerRoot, want, 2.5 * scale)
		p = rootOnGround(p, centerRoot.Y)
		pts[k + 1] = p
	end
	local keys = { Motion.key(cfg.Steps[1], from, yawOf(pts[1] - from) or 0, "l") }
	local segs = #pts -- approach + n cuts
	local span = cfg.Steps[2] - cfg.Steps[1]
	local prevP = from
	for i, p in pts do
		local yaw = yawOf(p - prevP) or keys[#keys].yaw
		table.insert(keys, Motion.key(cfg.Steps[1] + span * i / segs, p, yaw, "o"))
		prevP = p
	end
	-- he ends with his back to the middle
	local lastYaw = yawOf(pts[#pts] - centerRoot) or keys[#keys].yaw
	table.insert(keys, Motion.key(cfg.Pause[1] + 0.12, pts[#pts], lastYaw, "s"))
	startMotion(keys, start)
	model:SetAttribute("ActionTarget", centerRoot)

	if not waitUntil(start + cfg.DetonateAt) then
		return
	end
	local lines = {}
	for i = 1, #pts - 1 do
		table.insert(lines, { pts[i], pts[i + 1] })
	end
	local lineR = cfg.LineRadius * scale
	local coreR = cfg.CoreRadius * scale
	for _, v in livingVictims() do
		local feet = bodySegment(v)
		if math.abs(feet.Y - (centerRoot.Y - rootHeight())) <= 8 * scale then
			local p = Vector3.new(v.root.Position.X, 0, v.root.Position.Z)
			local count = 0
			for _, l in lines do
				local a = Vector3.new(l[1].X, 0, l[1].Z)
				local b = Vector3.new(l[2].X, 0, l[2].Z)
				if pointSegmentDistance(p, a, b) <= lineR then
					count += 1
				end
			end
			local dmg = math.min(count, 3) * cfg.LineDamage
			if flatDist(v.root.Position, centerRoot) <= coreR then
				dmg += cfg.CoreDamage
			end
			if dmg > 0 then
				hurt(v, dmg)
			end
		end
	end
	if not waitUntil(start + cfg.Duration) then
		return
	end
	endAction()
end

-- ---------------------------------------------------------------------------------------------
-- Health: phases, death and respawn
-- ---------------------------------------------------------------------------------------------
local lastHealth: number = humanoid.Health

local function resetBoss()
	humanoid.Health = humanoid.MaxHealth
	pendingCape = false
	pendingEye = false
	if capeOff or eyeOpen then
		capeOff = false
		eyeOpen = false
		model:SetAttribute("CapeOff", false)
		model:SetAttribute("EyeOpen", false)
		model:SetAttribute("Enraged", false)
		model:SetAttribute("Subtitle", nil)
	end
	log("reset")
end

humanoid.HealthChanged:Connect(function(health: number)
	local previous = lastHealth
	lastHealth = health
	if dead or health <= 0 then
		return
	end
	if health < previous and mode ~= "Return" then
		provokedUntil = os.clock() + PROVOKE_TIME
	end
	local max = humanoid.MaxHealth
	if max <= 0 or mode == "Return" then
		return
	end
	local frac = health / max
	if not capeOff and not pendingCape and frac <= Config.CapeHealth then
		pendingCape = true
	end
	if not eyeOpen and not pendingEye and frac <= Config.EyeHealth then
		pendingEye = true
	end
end)

local function deathSequence()
	local holdTime = Actions.Death.Duration
	task.wait(holdTime)
	local tpl = template
	if not canRespawn or not tpl or not tpl.Parent or not model.Parent then
		model:Destroy()
		return
	end
	model:SetAttribute("RigReady", false)
	for _, child in model:GetChildren() do
		if child ~= script and not child:IsA("BaseScript") and not child:IsA("ModuleScript") then
			child:Destroy()
		end
	end
	local remaining = (respawnTime :: number) - holdTime
	if remaining > 0 then
		task.wait(remaining)
	end
	local parent = model.Parent
	if not parent or not tpl.Parent then
		return
	end
	local fresh = tpl:Clone()
	tpl:Destroy()
	if fresh then
		local brain = fresh:FindFirstChild(script.Name)
		if brain and brain:IsA("BaseScript") then
			brain.Enabled = true
		end
		fresh:PivotTo(homeCF)
		fresh.Parent = parent
	end
	model:Destroy()
end

local function onDeath()
	if dead then
		return
	end
	dead = true
	inAction = false
	motion = nil
	log("died")
	publish("Death", nil, 1, nil)
	stopMoving()
	align.Enabled = false
	if hrp.Parent then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		hrp.Anchored = true
	end
	task.spawn(deathSequence)
end

humanoid.Died:Connect(onDeath)

-- ---------------------------------------------------------------------------------------------
-- The brain
-- ---------------------------------------------------------------------------------------------
local function teleportHome()
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	model:PivotTo(homeCF)
	claimNetworkOwnership()
end

local function startReturn()
	log("returning home")
	mode = "Return"
	returnStart = os.clock()
	target = nil
	setFacing("none")
	resetBoss()
end

local function pickTarget(): Victim?
	local pos = hrp.Position
	local eye = pos + Vector3.new(0, 3.3 * scale, 0)
	local current = if target then target.player else nil
	local provoked = os.clock() < provokedUntil
	local range = if provoked then math.max(Config.AggroRange, Config.LeashRange) else Config.AggroRange
	local best: Victim? = nil
	local bestScore = math.huge
	for _, player in Players:GetPlayers() do
		local v = victimOf(player)
		if v then
			local rp = v.root.Position
			local d = flatDist(pos, rp)
			if d <= range and flatDist(homePos, rp) <= Config.LeashRange and math.abs(rp.Y - pos.Y) <= range * 0.5 then
				local isCurrent = player == current
				if isCurrent or provoked or d <= SEE_THROUGH_WALLS * scale or not worldHit(eye, rp) then
					local score = if isCurrent then d * 0.75 - 6 else d
					if score < bestScore then
						best, bestScore = v, score
					end
				end
			end
		end
	end
	return best
end

-- Weighted pick among the attacks that make sense right now.
local function chooseAttack(v: Victim, dist: number): (() -> ())?
	local A = Actions
	local options: { { any } } = {}
	local function option(fn, weight)
		table.insert(options, { fn, weight })
	end
	local eyeLine = hrp.Position + Vector3.new(0, 1.5 * scale, 0)
	local clear = not worldHit(eyeLine, v.root.Position)
	if eyeOpen then
		if ready("PhantomStep") and dist <= (A.PhantomStep.Radius + 30) * scale and clear then
			option(doPhantomStep, 6)
		end
		if ready("ThousandCuts") and dist <= 15 * scale then
			option(doThousandCuts, 6)
		end
	end
	if ready("CrossCut") and dist <= A.CrossCut.Range * 0.85 * scale then
		option(doCrossCut, 4)
	end
	if ready("Cleave") and dist >= 7 * scale and dist <= A.Cleave.MaxLeap * scale then
		option(doCleave, if dist > 14 * scale then 3 else 1.5)
	end
	if ready("Lunge") and dist >= A.Lunge.MinRange * scale and dist <= (A.Lunge.Range - 2) * scale and clear then
		option(doLunge, 3)
	end
	if ready("SaberThrow") and dist >= A.SaberThrow.MinRange * scale and dist <= A.SaberThrow.Range * 0.8 * scale and clear then
		option(doSaberThrow, if dist > 30 * scale then 3 else 1.5)
	end
	if #options == 0 then
		return nil
	end
	local total = 0
	for _, o in options do
		total += o[2]
	end
	local r = rng:NextNumber() * total
	for _, o in options do
		r -= o[2]
		if r <= 0 then
			return o[1]
		end
	end
	return options[#options][1]
end

local function combatStep(v: Victim, clock: number)
	local rootPos = v.root.Position
	local dist = flatDist(hrp.Position, rootPos)

	if clock >= nextActionAt then
		if not drawn then
			doDraw()
			return
		end
		if pendingCape then
			doRemoveCape()
			return
		end
		if pendingEye then
			doRemoveEyepatch()
			return
		end
		local attack = chooseAttack(v, dist)
		if attack then
			attack()
			return
		end
	end

	local stop = CHASE_STOP * scale
	if dist > stop then
		setFacing("none")
		local speed = if dist > Config.RunDistance * scale then runSpeed() else Config.WalkSpeed
		drive(rootPos, stop, speed)
	else
		stopMoving()
		setFacing("target", TURN.chase)
	end
end

local function think()
	local clock = os.clock()
	refreshRayFilter()

	if hrp.Position.Y < homePos.Y - FALL_LIMIT * scale then
		teleportHome()
		startReturn()
	end

	if mode == "Return" then
		humanoid.Health = humanoid.MaxHealth
		local d = flatDist(hrp.Position, homePos)
		if d <= HOME_RADIUS * scale or clock - returnStart > RETURN_TIMEOUT then
			if d > HOME_RADIUS * scale then
				teleportHome()
			end
			stopMoving()
			resetBoss()
			mode = "Idle"
			idleSince = clock
			setFacing("yaw", TURN.home, homeYaw)
		else
			setFacing("none")
			drive(homePos, HOME_RADIUS * scale * 0.5, Config.WalkSpeed)
		end
		return
	end

	if flatDist(hrp.Position, homePos) > Config.LeashRange then
		startReturn()
		return
	end

	refreshTarget()
	if not target or clock >= nextRetarget then
		nextRetarget = clock + RETARGET_EVERY
		target = pickTarget()
	end

	local v = target
	if v then
		lastSeenTarget = clock
		lastTargetPos = v.root.Position
		if mode ~= "Combat" then
			mode = "Combat"
			combatStart = clock
			log("aggro", v.player.Name)
		end
		combatStep(v, clock)
		return
	end

	if mode == "Combat" then
		if clock - lastSeenTarget > LOST_TARGET_RESET then
			mode = "Idle"
			idleSince = clock
			if flatDist(hrp.Position, homePos) > HOME_RADIUS * scale then
				startReturn()
			else
				stopMoving()
				resetBoss()
			end
			return
		end
		local p = lastTargetPos
		if p and flatDist(hrp.Position, p) > CHASE_STOP * scale then
			setFacing("none")
			drive(p, CHASE_STOP * scale, Config.WalkSpeed)
		else
			stopMoving()
			setFacing("hold")
		end
		return
	end

	-- Idle at home: stands at attention; puts his sabers away after a while.
	if flatDist(hrp.Position, homePos) > HOME_RADIUS * scale then
		startReturn()
		return
	end
	stopMoving()
	if face.mode == "none" then
		setFacing("yaw", TURN.home, homeYaw)
	end
	if drawn and clock - idleSince > SHEATHE_AFTER and clock >= nextActionAt then
		doSheathe()
	end
end

task.spawn(function()
	local ownershipCheck = 0
	while not dead and model.Parent do
		task.wait(AI_TICK)
		if dead or not model.Parent then
			break
		end
		if not hrp:IsDescendantOf(workspace) or not humanoid:IsDescendantOf(workspace) then
			onDeath()
			break
		end
		local clock = os.clock()
		if clock >= ownershipCheck and not hrp.Anchored then
			ownershipCheck = clock + 3
			local ok, owner = pcall(hrp.GetNetworkOwner, hrp)
			if ok and owner ~= nil then
				claimNetworkOwnership()
			end
		end
		if inAction then
			continue
		end
		local ok, err = pcall(think)
		if not ok then
			warn("[Bradley] AI error: " .. tostring(err))
			if inAction then
				endAction()
			end
		end
	end
end)
