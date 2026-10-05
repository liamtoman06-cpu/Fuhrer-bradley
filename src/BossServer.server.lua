--[[
	King Bradley boss - server brain.

	A Script (RunContext = Server). Drop the KingBradleyScripts folder anywhere in Workspace (or
	ServerScriptService): this script finds the imported King Bradley model (the Model holding the
	B_Hips bone), moves itself and the other scripts into it and puts him on the ground. Then it:
	  1. keeps a pristine copy of the boss in ServerStorage so he can respawn,
	  2. builds the runtime rig: a Motor6D per B_* bone, welds for every visual part, physics,
	  3. runs the AI: pick a target, walk or sprint after it (pathfinding + unsticking), leash home,
	  4. runs the attacks with the timings in Config.Actions and deals all damage,
	  5. moves the root along scripted paths for dashes and leaps (module Motion),
	  6. publishes what he is doing through model attributes so BossClient animates every client in
	     sync: Action, ActionId, ActionStart, ActionSpeed, ActionTarget, ActionPath, ActionVictim,
	     Combat, CapeOff, EyeOpen, Enraged, RigScale, RigReady,
	  7. handles the phase changes (cape at CapeHealth, Ultimate Eye at EyeHealth), death and respawn.

	Animation, VFX and the knockbacks are BossClient's job (players own their own physics).
	Only player characters are ever damaged, through Humanoid:TakeDamage (so ForceFields work).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local PathfindingService = game:GetService("PathfindingService")

-- ---------------------------------------------------------------------------------------------
-- 0. Find the boss and move in
-- ---------------------------------------------------------------------------------------------
local SCRIPT_NAMES = { "Config", "Motion", "Poses", "Animator", "BossClient" }
local ALL_NAMES = { "Config", "Motion", "Poses", "Animator", "BossClient", "BossServer" }
local MARKER = "KingBradleyV3" -- every script of this version carries a BoolValue child with this name

local function current(inst: Instance): boolean
	return inst:FindFirstChild(MARKER) ~= nil
end

local function meshCount(inst: Instance): number
	local n = 0
	for _, d in inst:GetDescendants() do
		if d:IsA("MeshPart") then
			n += 1
		end
	end
	return n
end

-- The boss is the innermost Model around the B_Hips bone that holds the meshes too (the importer
-- may nest models; an arena model around him must not be taken for him).
local function bossAround(hips: Instance): Model?
	local fallback: Model? = nil
	local p = hips.Parent
	while p and p ~= workspace and p ~= game do
		if p:IsA("Model") then
			fallback = fallback or p
			if meshCount(p) >= 20 then
				return p
			end
		end
		p = p.Parent
	end
	return fallback
end

local function hipsIn(inst: Instance): Bone?
	local b = inst:FindFirstChild("B_Hips", true)
	return if b and b:IsA("Bone") then b else nil
end

local function takenByAnother(m: Model): boolean
	for _, c in m:GetChildren() do
		if c ~= script and c.Name == "BossServer" and c:IsA("BaseScript") and current(c) then
			return true
		end
	end
	return false
end

local function findBoss(): Model?
	-- inside the boss already (the documented install, and every respawn)
	local p = script.Parent
	if p and p:IsA("Model") then
		local hips = hipsIn(p)
		if hips then
			return bossAround(hips) or p
		end
	end
	-- otherwise: the imported model somewhere in the Workspace
	for _, d in workspace:GetDescendants() do
		if d.Name == "B_Hips" and d:IsA("Bone") then
			local m = bossAround(d)
			if m and not takenByAnother(m) then
				return m
			end
		end
	end
	return nil
end

local function explainMissing()
	for _, d in workspace:GetDescendants() do
		if d.Name == "B_Hips" and d:IsA("Bone") then
			local m = bossAround(d)
			if m and takenByAnother(m) then
				warn("[Bradley] " .. m:GetFullName() .. " is already run by another copy of the King Bradley scripts; "
					.. "this copy (" .. script:GetFullName() .. ") does nothing. Delete one of the two KingBradleyScripts.")
				return
			end
		end
	end
	-- meshes named like ours but no skeleton: the import dropped the rig
	for _, d in workspace:GetDescendants() do
		if d:IsA("MeshPart") and (d.Name == "Body_Skin" or d.Name == "Shirt_Shirt") then
			warn("[Bradley] SETUP PROBLEM: found King Bradley's meshes (" .. d:GetFullName() .. ") but no bones. "
				.. "He was imported without his skeleton, so he cannot animate. Delete him and import "
				.. "model/KingBradley.fbx again with File > Import 3D, keeping the rig (Rig Type: Custom / "
				.. "'Import rig' on, NOT 'No Rig') and without 'Merge Meshes'.")
			return
		end
	end
	warn("[Bradley] SETUP PROBLEM: could not find King Bradley in the Workspace. Import model/KingBradley.fbx "
		.. "with File > Import 3D (keep the rig) so that a Model with the bones B_Hips, B_Chest, ... is in "
		.. "the Workspace. The scripts find him by themselves.")
end

local model = findBoss()
if not model then
	explainMissing()
	repeat
		task.wait(2)
		model = findBoss()
	until model
end

-- scripts from an older version left inside him are removed, with what they had built
do
	local removed = {}
	for _, c in model:GetChildren() do
		if c ~= script and table.find(ALL_NAMES, c.Name) and (c:IsA("LuaSourceContainer")) and not current(c) then
			table.insert(removed, c.Name)
			c:Destroy()
		end
	end
	if #removed > 0 then
		warn("[Bradley] removed old King Bradley scripts from inside " .. model:GetFullName() .. ": " .. table.concat(removed, ", "))
	end
	-- pieces a previous run built (a boss copied out of a Play session keeps them): rebuilt below.
	-- A HumanoidRootPart without the BradleyRoot mark is the importer's (it may hold the bones) and stays.
	for _, d in model:GetDescendants() do
		if (d.Name == "BossWeld" and d:IsA("WeldConstraint")) or (d.Name == "Hitbox" and d:IsA("BasePart"))
			or (d.Name == "HumanoidRootPart" and d:IsA("BasePart") and d:GetAttribute("BradleyRoot")) then
			d:Destroy()
		end
	end
	model:SetAttribute("RigReady", nil)
end

-- move in: the scripts live inside the boss (BossClient must be in his model to run for players,
-- and respawns clone the model with everything in it)
do
	local home = script.Parent
	if home ~= model then
		for _, name in SCRIPT_NAMES do
			local here = home and home:FindFirstChild(name)
			if here and (here:IsA("ModuleScript") or here:IsA("BaseScript")) and not model:FindFirstChild(name) then
				here.Parent = model
			elseif not model:FindFirstChild(name) then
				warn("[Bradley] SETUP PROBLEM: the " .. name .. " script is missing next to " .. script:GetFullName()
					.. ". Insert KingBradleyScripts.rbxmx again (all six scripts must stay together).")
			end
		end
		script.Parent = model
		if home and home:IsA("Folder") and #home:GetChildren() == 0 then
			home:Destroy()
		end
	end
end
model:SetAttribute("BradleyBoss", true) -- BossClient waits for this before it starts

-- The importer may name each MeshPart after its mesh data instead of its object ("Mesh_65" for
-- "Cape_CoatBlue"). Parts are found by these names (cape, eyepatch, sabers, colours): restore them.
do
	local MESH_NAMES = {
	["BodySkin"] = "Body_Skin",
	["BodySkin.002"] = "Shirt_Shirt",
	["Mesh_10"] = "Head_OuroSclera",
	["Mesh_11"] = "Head_OuroSigil",
	["Mesh_14"] = "Head_Lips",
	["Mesh_15"] = "Patch_Eyepatch",
	["Mesh_17"] = "Collar_ShirtRib",
	["Mesh_18"] = "Harness_LeatherDark",
	["Mesh_19"] = "Harness_LeatherBelt",
	["Mesh_2"] = "Head_SkinShade",
	["Mesh_20"] = "Harness_Iron",
	["Mesh_21"] = "Pelvis_Trousers",
	["Mesh_22"] = "Belt_LeatherBelt",
	["Mesh_23"] = "Belt_LeatherDark",
	["Mesh_24"] = "Belt_Brass",
	["Mesh_25"] = "Belt_Iron",
	["Mesh_3"] = "Head_EyeWhite",
	["Mesh_30"] = "ForearmL_Glove",
	["Mesh_31"] = "ForearmL_LeatherDark",
	["Mesh_32"] = "HandL_Glove",
	["Mesh_33"] = "HandL_LeatherDark",
	["Mesh_38"] = "ForearmR_Glove",
	["Mesh_39"] = "ForearmR_LeatherDark",
	["Mesh_4"] = "Head_Iris",
	["Mesh_40"] = "HandR_Glove",
	["Mesh_41"] = "HandR_LeatherDark",
	["Mesh_42"] = "ThighL_Trousers",
	["Mesh_43"] = "ShinL_Trousers",
	["Mesh_44"] = "ShinL_Boot",
	["Mesh_45"] = "ShinL_Iron",
	["Mesh_46"] = "FootL_Boot",
	["Mesh_47"] = "FootL_Sole",
	["Mesh_48"] = "ThighR_Trousers",
	["Mesh_49"] = "ShinR_Trousers",
	["Mesh_5"] = "Head_IrisRim",
	["Mesh_50"] = "ShinR_Boot",
	["Mesh_51"] = "ShinR_Iron",
	["Mesh_52"] = "FootR_Boot",
	["Mesh_53"] = "FootR_Sole",
	["Mesh_54"] = "SaberL_Brass",
	["Mesh_55"] = "SaberL_Grip",
	["Mesh_56"] = "SaberL_Steel",
	["Mesh_57"] = "SaberR_Brass",
	["Mesh_58"] = "SaberR_Grip",
	["Mesh_59"] = "SaberR_Steel",
	["Mesh_6"] = "Head_Pupil",
	["Mesh_65"] = "Cape_CoatBlue",
	["Mesh_66"] = "Cape_CoatLining",
	["Mesh_67"] = "Cape_Piping",
	["Mesh_68"] = "Cape_Gold",
	["Mesh_69"] = "Cape_Brass",
	["Mesh_7"] = "Head_EyeGlint",
	["Mesh_8"] = "Head_LashLine",
	["Mesh_9"] = "Head_Crease",
	["SleeveHem_ShirtRib.001"] = "SleeveHem_ShirtRib"
	}
	local renamed = 0
	for _, d in model:GetDescendants() do
		if d:IsA("MeshPart") then
			local proper = MESH_NAMES[d.Name] or MESH_NAMES[(string.gsub(d.Name, "%.%d+$", ""))]
			if proper and proper ~= d.Name then
				d.Name = proper
				renamed += 1
			end
		end
	end
	if renamed > 0 then
		print(("[Bradley] restored the names of %d imported meshes"):format(renamed))
	end
end
-- a boss must always be on every player's machine: never streamed out (StreamingEnabled places)
pcall(function()
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
end)

-- A copy kept in ReplicatedStorage (or similar) idles here until it is put in the Workspace.
while not model:IsDescendantOf(workspace) do
	model.AncestryChanged:Wait()
end

local function requireModule(name: string)
	local m = model:FindFirstChild(name) or model:WaitForChild(name, 10)
	if not (m and m:IsA("ModuleScript")) then
		error("[Bradley] SETUP PROBLEM: the " .. name .. " module is missing from " .. model:GetFullName()
			.. ". Insert KingBradleyScripts.rbxmx again (all six scripts must be together).")
	end
	return require(m)
end

local Config = requireModule("Config")
local Motion = requireModule("Motion")
local Actions = Config.Actions
local Cooldowns = Config.Cooldowns

local humanoid = model:FindFirstChildOfClass("Humanoid")
local hrp = model:FindFirstChild("HumanoidRootPart")

-- ---------------------------------------------------------------------------------------------
-- Tuning that is not in Config (studs are multiplied by the model scale)
-- ---------------------------------------------------------------------------------------------
local DEBUG = false
local TEMPLATE_FOLDER = "KingBradleyTemplates"
local WEAPON_HITBOXES = true -- invisible hitboxes parented to the model (player weapons find him)

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
-- where the left saber leaves his hand in the throws (root space, measured on the Animator's pose
-- at ReleaseAt); clients draw the locked line and launch the blade from the same published point
local THROW_RELEASE = Vector3.new(-2.97, 1.46, -2.2)

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
		for _, d in template:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true -- a respawned copy holds still until its own BossServer stands it up
			end
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

-- where he was placed (respawns go back exactly here, before any of the setup below)
local placedPivot = model:GetPivot()

-- ---------------------------------------------------------------------------------------------
-- 2. Model setup: the imported, skinned King Bradley (any importer layout, any size)
-- ---------------------------------------------------------------------------------------------
local function bone(name: string): Bone?
	local b = model:FindFirstChild(name, true)
	return if b and b:IsA("Bone") then b else nil
end

local function visualParts(): { BasePart }
	local list = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Name ~= "Hitbox" then
			table.insert(list, d)
		end
	end
	return list
end

local function heightRange(): (number, number)
	local lo, hi = math.huge, -math.huge
	local parts = {}
	for _, p in visualParts() do
		if p:IsA("MeshPart") then
			table.insert(parts, p) -- only the meshes: the importer's bone holder "RootPart" is not body
		end
	end
	if #parts == 0 then
		parts = visualParts()
	end
	for _, p in parts do
		local cf, h = p.CFrame, p.Size / 2
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local y = (cf * Vector3.new(h.X * sx, h.Y * sy, h.Z * sz)).Y
					lo = math.min(lo, y)
					hi = math.max(hi, y)
				end
			end
		end
	end
	return lo, hi
end

for _, p in visualParts() do
	p.Anchored = true -- held still while we measure and build
end
if hrp and hrp:IsA("BasePart") then
	hrp.Anchored = true
end
if type(Config.TargetHeight) == "number" and Config.TargetHeight > 0 then
	local lo, hi = heightRange()
	local h = hi - lo
	if h > 0.01 and math.abs(h - Config.TargetHeight) > 0.05 then
		local ok, err = pcall(function()
			model:ScaleTo(model:GetScale() * Config.TargetHeight / h)
		end)
		if not ok then
			warn("[Bradley] could not scale the model: " .. tostring(err))
		else
			-- ScaleTo scales about the pivot: put his feet back where they were placed
			local newLo = heightRange()
			model:PivotTo(model:GetPivot() + Vector3.new(0, lo - newLo, 0))
		end
	end
end
-- stand him on the floor below him (the importer drops models in mid-air in front of the camera).
-- The ray starts far above him and passes through roofs: the highest floor at or below his feet
-- wins; if he was imported under the floor, the lowest surface above his feet does.
local function findFloor(): number?
	local lo, hi = heightRange()
	if lo == math.huge then
		return nil
	end
	local height = math.max(hi - lo, 1)
	local box = model:GetBoundingBox()
	local ignore: { Instance } = { model }
	for _, plr in Players:GetPlayers() do
		if plr.Character then
			table.insert(ignore, plr.Character)
		end
	end
	for _, d in workspace:GetDescendants() do
		if d ~= model and d:IsA("Model") and d:GetAttribute("BradleyBoss") then
			table.insert(ignore, d) -- other bosses are not floors
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	params.RespectCanCollide = true
	-- a surface counts as his floor when it is below his chest (he may be imported sunk into it);
	-- anything higher is a roof he passes through; if he is buried, the lowest surface above him wins
	local below: number? = nil
	local above: number? = nil
	local reach = height * 0.2
	for _, off in { Vector3.zero, Vector3.new(reach, 0, 0), Vector3.new(-reach, 0, 0), Vector3.new(0, 0, reach), Vector3.new(0, 0, -reach) } do
		local from = Vector3.new(box.X + off.X, hi + height * 20 + 50, box.Z + off.Z)
		for _ = 1, 12 do
			local hit = workspace:Raycast(from, Vector3.new(0, -20000, 0), params)
			if not hit then
				break
			end
			local y = hit.Position.Y
			if y <= lo + height * 0.6 then
				below = math.max(below or -math.huge, y)
				break
			end
			above = math.min(above or math.huge, y)
			from = hit.Position - Vector3.new(0, 0.02, 0) -- continue through the roof (a ray starting inside a part ignores it)
		end
	end
	return below or above
end

local floorY = findFloor()
if not floorY then
	warn("[Bradley] SETUP PROBLEM: there is no floor under King Bradley (" .. model:GetFullName() .. "). Move him "
		.. "above a floor, terrain or the Baseplate and press Play again. He stays frozen in place until then.")
	return -- he stays anchored where he is, instead of falling forever
end
do
	local lo = heightRange()
	model:PivotTo(model:GetPivot() + Vector3.new(0, floorY - lo + 0.03, 0))
end
local groundY, topY = heightRange()
local scale: number = math.max((topY - groundY) / 9, 0.05) -- one unit = one stud on a 9-stud Bradley

local hipsBone = bone("B_Hips")
if not hipsBone then
	warn("[Bradley] SETUP PROBLEM: no B_Hips bone in " .. model:GetFullName() .. ": import KingBradley.fbx again with "
		.. "its rig (Rig Type: Custom) - see README")
end

-- his forward: from the heels to the toes (bones that every import keeps), else the facing marker
local function facingDir(): Vector3
	local fl, fr, tl, tr = bone("B_FootL"), bone("B_FootR"), bone("B_ToeL"), bone("B_ToeR")
	local fwd = Vector3.zero
	if fl and fr and tl and tr then
		fwd = (tl.WorldPosition + tr.WorldPosition) / 2 - (fl.WorldPosition + fr.WorldPosition) / 2
	end
	fwd = Vector3.new(fwd.X, 0, fwd.Z)
	if fwd.Magnitude < 1e-3 then
		local marker = bone("B_Facing")
		if marker and hipsBone then
			fwd = marker.WorldPosition - hipsBone.WorldPosition
			fwd = Vector3.new(fwd.X, 0, fwd.Z)
		end
	end
	if fwd.Magnitude < 1e-3 then
		fwd = Vector3.new(0, 0, -1)
	end
	return fwd.Unit
end
local forward = facingDir()

-- Bones that move no mesh are dropped by the importer unless "Keep Zero Influence Bones" is ticked:
-- the facing marker and the blade tips. Rebuild them at their rest place (rig.json, metres, +Z forward).
do
	local REST = {
		B_Facing = { "B_Hips", Vector3.new(0, 0.975, 0), Vector3.new(0, 0.975, 0.35) },
		B_SaberTipR = { "B_SaberR", Vector3.new(-0.427, 0.822, 0.031), Vector3.new(-0.9017, 0.3045, 0.6019) },
		B_SaberTipL = { "B_SaberL", Vector3.new(0.427, 0.822, 0.031), Vector3.new(0.9017, 0.3045, 0.6019) },
	}
	local head, toe = bone("B_Head"), bone("B_ToeR")
	local studsPerMetre = if head and toe then (head.WorldPosition.Y - toe.WorldPosition.Y) / (1.585 - 0.03) else scale * 9 / 1.836
	local frame = CFrame.lookAt(Vector3.zero, forward)
	for name, r in REST do
		local parent = bone(r[1])
		if parent and not bone(name) then
			local d = r[3] - r[2]
			-- rig axes: +X is his left, +Z his front; root axes: +X his right, -Z his front
			local offset = frame:VectorToWorldSpace(Vector3.new(-d.X, d.Y, -d.Z) * studsPerMetre)
			local b = Instance.new("Bone")
			b.Name = name
			b.CFrame = CFrame.new(parent.WorldCFrame:PointToObjectSpace(parent.WorldPosition + offset))
			b.Parent = parent
		end
	end
end

-- the root part is always built here, upright at the hips, facing his forward
do
	local imported = model:FindFirstChild("HumanoidRootPart")
	if imported and imported:IsA("BasePart") and not imported:GetAttribute("BradleyRoot") then
		imported.Name = "ImportedRootPart" -- an importer-made root is welded along like any other part
	end
	local hipsPos = if hipsBone then hipsBone.WorldPosition else model:GetBoundingBox().Position
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2.2, 2, 1.2) * scale
	root.CFrame = CFrame.lookAt(hipsPos, hipsPos + forward)
	root.Transparency = 1
	root.CanCollide = true
	root.Anchored = true
	root:SetAttribute("BradleyRoot", true)
	root.Parent = model
	hrp = root
end
model.PrimaryPart = hrp
if not humanoid then
	-- set up before it enters the model: an R15 Humanoid without a neck would otherwise die at once
	local h = Instance.new("Humanoid")
	h.RigType = Enum.HumanoidRigType.R15
	h.RequiresNeck = false
	h.BreakJointsOnDeath = false
	h.AutomaticScalingEnabled = false
	h.Parent = model
	humanoid = h
end
-- HipHeight: from the floor to the bottom of the root part (sane range: 30-60% of his height)
local height = topY - groundY
local hipHeight = math.clamp(hrp.Position.Y - hrp.Size.Y / 2 - groundY, height * 0.3, height * 0.6)
model:SetAttribute("RigScale", scale)

local homeCF = model:GetPivot()
local homePos = hrp.Position
local homeYaw = yawOf(hrp.CFrame.LookVector) or 0

-- colours and materials by the material at the end of each mesh name
local colors = Config.Colors or {}
for _, p in visualParts() do
	local key = string.match(p.Name, "_(%a+)%d*$") or string.match(p.Name, "_(%a+)%.%d+$")
	local c = key and colors[key]
	if c then
		p.Color = Color3.fromRGB(c[1], c[2], c[3])
		if c[4] then
			local ok = pcall(function()
				p.Material = Enum.Material[c[4]]
			end)
			if not ok then
				p.Material = Enum.Material.SmoothPlastic
			end
		else
			p.Material = Enum.Material.SmoothPlastic
		end
		p.Reflectance = c[5] or 0
	end
end

-- physics: one assembly on the root; only the root collides; hitboxes take the weapon hits
local rigParts: { BasePart } = {}
local weldCount = 0
local function weldTo(part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "BossWeld"
	weld.Part0 = hrp
	weld.Part1 = part
	weld.Parent = part
	weldCount += 1
end
for _, p in visualParts() do
	weldTo(p)
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Massless = true
	p.CastShadow = true
	table.insert(rigParts, p)
end

local function hitbox(name: string, cf: CFrame, size: Vector3, shape: Enum.PartType?)
	local box = Instance.new("Part")
	box.Name = "Hitbox"
	box.Shape = shape or Enum.PartType.Block
	box.Size = size
	box.CFrame = cf
	box.Transparency = 1
	box.Anchored = true
	box.CanCollide = false
	box.CanTouch = true
	box.CanQuery = true
	box.CastShadow = false
	box.Massless = true
	box:SetAttribute("Hitbox", true)
	box:SetAttribute("Region", name)
	box.Parent = model
	weldTo(box)
	table.insert(rigParts, box)
end
if WEAPON_HITBOXES then
	local up = hrp.CFrame.Rotation
	local function at(b: Bone?, fallback: Vector3): Vector3
		return if b then b.WorldPosition else hrp.CFrame:PointToWorldSpace(fallback * scale)
	end
	local hips, neck, head = at(hipsBone, Vector3.zero), at(bone("B_Neck"), Vector3.new(0, 2.7, 0)), at(bone("B_Head"), Vector3.new(0, 3.1, 0))
	hitbox("Torso", CFrame.new((hips + neck) / 2) * up, Vector3.new(2.0 * scale, (neck - hips).Magnitude + 0.6 * scale, 1.2 * scale))
	hitbox("Head", CFrame.new(head + Vector3.new(0, 0.45 * scale, 0)) * up, Vector3.one * 1.25 * scale, Enum.PartType.Ball)
	for _, n in { "L", "R" } do
		local a, b = at(bone("B_Thigh" .. n), Vector3.zero), at(bone("B_Foot" .. n), Vector3.new(0, -4, 0))
		hitbox("Leg" .. n, CFrame.new((a + b) / 2) * up, Vector3.new(0.85 * scale, (a - b).Magnitude + 0.4 * scale, 0.85 * scale))
		local s0, e0 = at(bone("B_UpperArm" .. n), Vector3.zero), at(bone("B_Hand" .. n), Vector3.zero)
		hitbox("Arm" .. n, CFrame.lookAt((s0 + e0) / 2, e0) , Vector3.new(0.7 * scale, 0.7 * scale, (s0 - e0).Magnitude))
	end
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
		-- An Animator would overwrite Bone.Transform; BossClient animates the bones itself.
		task.defer(function()
			if inst.Parent then
				inst:Destroy()
			end
		end)
	end
end

for _, part in rigParts do
	part.Anchored = false
end
hrp.Anchored = false
hrp.CanCollide = true
hrp.Massless = false
hrp.RootPriority = 127
hrp.CustomPhysicalProperties = PhysicalProperties.new(4, 0.4, 0, 1, 1)

if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
	humanoid.RigType = Enum.HumanoidRigType.R15 -- R15 is the rig type that honours HipHeight
end
humanoid.AutomaticScalingEnabled = false
humanoid.HipHeight = hipHeight
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
model:SetAttribute("Combat", false)
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
do
	local bones, missing = 0, {}
	for _, d in model:GetDescendants() do
		if d:IsA("Bone") then
			bones += 1
		end
	end
	for _, n in { "B_Hips", "B_Chest", "B_Head", "B_HandR", "B_HandL", "B_FootR", "B_FootL", "B_Cape3_1" } do
		if not bone(n) then
			table.insert(missing, n)
		end
	end
	local skinned = 0
	for _, d in model:GetDescendants() do
		if d:IsA("MeshPart") and d.HasSkinnedMesh then
			skinned += 1
		end
	end
	print(("[Bradley] ready: %s, %d meshes (%d skinned), %d bones, %.1f studs tall, hip height %.1f%s"):format(model:GetFullName(),
		meshCount(model), skinned, bones, topY - groundY, hipHeight,
		if #missing > 0 then " (missing bones: " .. table.concat(missing, ", ") .. ")" else ""))
	if skinned == 0 and meshCount(model) > 0 then
		warn("[Bradley] SETUP PROBLEM: none of his meshes are skinned, so the bones cannot move them. Import "
			.. "KingBradley.fbx again with the rig kept (Rig Type: Custom) and Merge Meshes off.")
	end
end
log(string.format("rig ready: %d welds, scale %.2f, hip height %.2f", weldCount, scale, hipHeight))

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

-- Hits are judged where each player is on their OWN screen as well as where the server last saw
-- them (the server hears about a player's movement about half a ping late). A hit counts only if it
-- lands at both places: a dodge made on the player's screen is honoured, and the correction can
-- never add a hit.
local LEAD_CAP = 3 -- studs (players are not scaled with the boss)

local function lead(v: Victim): number
	local ok, ping = pcall(function()
		return v.player:GetNetworkPing() -- round trip, seconds
	end)
	if not ok or type(ping) ~= "number" then
		return 0.05
	end
	return math.clamp(ping * 0.5 + 0.02, 0, 0.16)
end

-- where the player is on their own screen: half a ping of their horizontal movement further on
local function seenRoot(v: Victim): Vector3
	local vel = v.root.AssemblyLinearVelocity
	local shift = Vector3.new(vel.X, 0, vel.Z) * lead(v)
	if shift.Magnitude > LEAD_CAP then
		shift = shift.Unit * LEAD_CAP
	end
	return v.root.Position + shift
end

-- A player's body as a vertical segment, feet to head, around root position p (R6, R15, scaled).
local function bodyAt(v: Victim, p: Vector3): (Vector3, Vector3)
	local half = v.root.Size.Y / 2
	local legs = math.max(v.humanoid.HipHeight, 2)
	return p - Vector3.new(0, half + legs, 0), p + Vector3.new(0, half + 1.6, 0)
end

-- the replicated body (aiming and targeting)
local function bodySegment(v: Victim): (Vector3, Vector3)
	return bodyAt(v, v.root.Position)
end

-- test(rootPosition) must hold both where the server sees the player and where they see themselves
local function judged(v: Victim, test: (Vector3) -> boolean): boolean
	local raw = v.root.Position
	if not test(raw) then
		return false
	end
	local seen = seenRoot(v)
	return (seen - raw).Magnitude < 0.05 or test(seen)
end

-- the smaller of two damages (a hit has to land at both places to count fully)
local function judgedDamage(v: Victim, damageAt: (Vector3) -> number): number
	return math.min(damageAt(v.root.Position), damageAt(seenRoot(v)))
end

local BODY_RADIUS = 1.1 -- a player's half-width (their arms and shoulders count, not just the spine)

-- a throw's reach around its line: the blade's part grows with the boss, a player's width does not
local function throwRadius(hitRadius: number): number
	return math.max(hitRadius - BODY_RADIUS, 0.3) * scale + BODY_RADIUS
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
local challenged = false
local mode = "Idle" -- "Idle" (at home), "Combat", "Return"
local target: Victim? = nil
local lastSeenTarget = 0
local lastTargetPos: Vector3? = nil
local nextRetarget = 0
local combatStart = 0
local returnStart = 0
local nextActionAt = 0
local provokedUntil = 0
local pendingCape = false
local pendingEye = false
local pendingImpale = false -- Piercing Gaze plays right after the eye opens...
local impaleDone = false -- ...once per fight
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
	model:SetAttribute("ActionOrigin", nil)
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
		if judged(v, function(q)
			local a, b = bodyAt(v, q)
			local off = closestOnSegment(pos, a, b) - pos
			local d = flat(off).Magnitude
			return d <= range + BODY_RADIUS and math.abs(off.Y) <= 7 * scale and (d < 2.5 * scale or flat(off).Unit:Dot(look) >= cosA)
		end) then
			fn(v)
		end
	end
end

-- ---- Challenge: first sight, the blade levelled at the target ---------------------------------
local function doChallenge()
	local cfg = Actions.Challenge
	challenged = true
	local t = target
	local start = beginAction("Challenge", if t then t.root.Position else frontPoint(), 1, if t then t.player else nil)
	setFacing(if t then "target" else "hold", TURN.slow)
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
	pendingCape = false -- hits during the grab may have queued it again
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
	pendingEye = false -- hits during the tear may have queued it again
	if not impaleDone then
		pendingImpale = true
	end
	model:SetAttribute("Enraged", true)
	model:SetAttribute("Subtitle", Config.EyeSubtitle)
	-- the eye opens with a pressure wave (knockback is applied by each client)
	local radius = cfg.ShockRadius * scale
	for _, v in livingVictims() do
		if judged(v, function(q)
			return flatDist(q, hrp.Position) <= radius + BODY_RADIUS and math.abs(q.Y - hrp.Position.Y) < 10 * scale
		end) then
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
			if not hitSet[v.player] and judged(v, function(q)
				local a, b = bodyAt(v, q)
				return segmentDistance(from, p, a, b) <= radius
			end) then
				hitSet[v.player] = true
				hurt(v, cfg.Damage)
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
	-- aimed a little before the release so the impact point replicates before clients throw
	if not waitUntil(at(math.max(cfg.ReleaseAt - 0.2, 0))) then
		return
	end
	refreshTarget()
	t = target
	refreshRayFilter()
	local origin = hrp.CFrame:PointToWorldSpace(THROW_RELEASE * scale)
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
	model:SetAttribute("ActionOrigin", origin)
	model:SetAttribute("ActionTarget", impact)
	setFacing("point", TURN.windUp, impact)

	local release = at(cfg.ReleaseAt)
	local total = (impact - origin).Magnitude / speed
	local hitSet: { [Player]: boolean } = {}
	local prev = origin
	local radius = throwRadius(cfg.HitRadius)
	if not waitUntil(release) then
		return
	end
	while alive() do
		local e = serverNow() - release
		local u = math.min(e / math.max(total, 1e-3), 1)
		local tip = origin:Lerp(impact, u)
		for _, v in livingVictims() do
			if not hitSet[v.player] and judged(v, function(q)
				local a, b = bodyAt(v, q)
				return segmentDistance(prev, tip, a, b) <= radius
			end) then
				hitSet[v.player] = true
				hurt(v, cfg.Damage)
			end
		end
		prev = tip
		if u >= 1 then
			break
		end
		task.wait(1 / 30)
	end
	if not alive() then
		return
	end
	local splash = cfg.SplashRadius * scale
	for _, v in livingVictims() do
		if not hitSet[v.player] and judged(v, function(q)
			local a, b = bodyAt(v, q)
			return pointSegmentDistance(impact, a, b) <= splash + BODY_RADIUS * 0.5
		end) then
			hurt(v, cfg.SplashDamage)
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
		local dmg = judgedDamage(v, function(q)
			local a, b = bodyAt(v, q)
			if a.Y - impact.Y > 5 * scale or b.Y < impact.Y - 4 * scale then
				return 0
			end
			if flatDist(q, impact) <= radius + BODY_RADIUS then
				return cfg.Damage
			end
			if pointSegmentDistance(Vector3.new(q.X, impact.Y, q.Z), impact, Vector3.new(fissureEnd.X, impact.Y, fissureEnd.Z)) <= half + BODY_RADIUS * 0.5 then
				return cfg.FissureDamage
			end
			return 0
		end)
		if dmg > 0 then
			hurt(v, dmg)
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
	-- publish where the wave will go before the cut, so every client has it when the wave starts
	if not waitUntil(start + cfg.Final[1]) then
		return
	end
	refreshRayFilter()
	model:SetAttribute("ActionTarget", clampTravel(hrp.Position, hrp.Position + lookFlat() * (cfg.WaveLength * scale), 1))
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
			if not hitSet[v.player] and judged(v, function(q)
				local a = bodyAt(v, q)
				local lo = Vector3.new(prev.X, a.Y, prev.Z)
				local hi = Vector3.new(front.X, a.Y, front.Z)
				return pointSegmentDistance(Vector3.new(q.X, a.Y, q.Z), lo, hi) <= half + BODY_RADIUS * 0.5 and math.abs(q.Y - origin.Y) <= 9 * scale
			end) then
				hitSet[v.player] = true
				hurt(v, cfg.WaveDamage)
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
		local dmg = judgedDamage(v, function(q)
			local feet = bodyAt(v, q)
			if math.abs(feet.Y - (centerRoot.Y - rootHeight())) > 8 * scale then
				return 0
			end
			local p = Vector3.new(q.X, 0, q.Z)
			local count = 0
			for _, l in lines do
				local a = Vector3.new(l[1].X, 0, l[1].Z)
				local b = Vector3.new(l[2].X, 0, l[2].Z)
				if pointSegmentDistance(p, a, b) <= lineR then
					count += 1
				end
			end
			local d = math.min(count, 3) * cfg.LineDamage
			if flatDist(q, centerRoot) <= coreR then
				d += cfg.CoreDamage
			end
			return d
		end)
		if dmg > 0 then
			hurt(v, dmg)
		end
	end
	if not waitUntil(start + cfg.Duration) then
		return
	end
	endAction()
end

-- ---- Ultimate Eye: Piercing Gaze, then the Execution (once per fight) -------------------------------
local function chestOf(v: Victim): Vector3
	local feet, head = bodySegment(v)
	return feet:Lerp(head, 0.66)
end

-- The pinned victim: he blitzes in, grips the hilt and kicks them off the blade. The victim's own
-- client freezes them until the kick and then launches them (players own their physics).
-- Returns false (and does nothing) when he cannot reach the victim: a wall or a drop in between,
-- or the victim far above or below him.
local function runExecution(v: Victim): boolean
	local cfg = Actions.Execution
	refreshRayFilter()
	local from = hrp.Position
	local off = flat(v.root.Position - from)
	local dir = if off.Magnitude > 0.5 then off.Unit else lookFlat()
	local standDist = math.max(off.Magnitude - cfg.StandOff * scale, 0)
	local goal = rootOnGround(clampTravel(from, from + dir * standDist, 1.5 * scale), from.Y)
	if flatDist(goal, v.root.Position) > (cfg.StandOff + 3) * scale or math.abs(v.root.Position.Y - goal.Y) > 8 * scale then
		return false
	end
	local start = beginAction("Execution", v.root.Position, 1, v.player)
	local yaw = yawOf(dir) or (yawOf(hrp.CFrame.LookVector) or 0)
	startMotion({ Motion.key(cfg.DashStart, from, yaw, "l"), Motion.key(cfg.DashEnd, goal, yaw, "o") }, start)
	if not waitUntil(start + cfg.KickAt) then
		return true
	end
	local now = victimOf(v.player)
	if now and judged(now, function(q)
		return flatDist(q, hrp.Position) <= (cfg.StandOff + 7) * scale and math.abs(q.Y - hrp.Position.Y) <= 8 * scale
	end) then
		hurt(now, cfg.KickDamage)
	end
	if not waitUntil(start + cfg.Duration) then
		return true
	end
	endAction()
	return true
end

local function doPiercingGaze()
	local cfg = Actions.PiercingGaze
	pendingImpale = false
	local t = target
	if not t then
		return
	end
	impaleDone = true
	local start = beginAction("PiercingGaze", chestOf(t), 1, t.player)
	setFacing("target", TURN.lock)
	-- the eye reads the target: the sight line follows them until the lock
	while alive() and serverNow() < start + cfg.LockAt do
		refreshTarget()
		if target then
			model:SetAttribute("ActionTarget", chestOf(target))
		end
		task.wait(0.05)
	end
	if not alive() then
		return
	end
	refreshTarget()
	t = target
	refreshRayFilter()
	-- locked: the throw flies straight down this line (no homing), so stepping off it dodges
	local origin = hrp.CFrame:PointToWorldSpace(THROW_RELEASE * scale)
	local last = model:GetAttribute("ActionTarget")
	local aim = if t then chestOf(t) elseif typeof(last) == "Vector3" then last else frontPoint()
	local dir = aim - origin
	if dir.Magnitude < 0.5 then
		dir = lookFlat()
	end
	dir = dir.Unit
	local range = cfg.Range * scale
	local wall = workspace:Raycast(origin, dir * range, rayParams)
	local impact = if wall then wall.Position else origin + dir * range
	model:SetAttribute("ActionOrigin", origin)
	model:SetAttribute("ActionTarget", impact)
	setFacing("point", TURN.windUp, impact)

	local release = start + cfg.ReleaseAt
	if not waitUntil(release) then
		return
	end
	local speed = cfg.Speed * scale
	local total = (impact - origin).Magnitude / speed
	local radius = throwRadius(cfg.HitRadius)
	-- the sweep starts a little way out of his hand (someone beside the hand is not in the line)
	local sweep0 = math.min(1.5 * scale, (impact - origin).Magnitude)
	local prev = origin + dir * sweep0
	local struck: Victim? = nil
	while alive() do
		local u = math.min((serverNow() - release) / math.max(total, 1e-3), 1)
		local tip = origin:Lerp(impact, u)
		if (tip - origin):Dot(dir) > sweep0 then
			local best, bestS = nil, math.huge
			for _, v in livingVictims() do
				if judged(v, function(q)
					local a, b = bodyAt(v, q)
					return segmentDistance(prev, tip, a, b) <= radius
				end) then
					local along = (v.root.Position - origin):Dot(dir) -- the first body along the flight
					if along < bestS then
						best, bestS = v, along
					end
				end
			end
			if best then
				struck = best
				break
			end
			prev = tip
		end
		if u >= 1 then
			break
		end
		task.wait()
	end
	if not alive() then
		return
	end
	if struck then
		hurt(struck, cfg.Damage)
		local still = victimOf(struck.player)
		if still and runExecution(still) then
			return
		end
	end
	-- missed: he draws a spare saber and fights on
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
	pendingImpale = false
	impaleDone = false
	challenged = false
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
		model:SetAttribute("RigReady", false) -- clients tear down their effects before he goes
		task.wait(0.5)
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
		fresh:PivotTo(placedPivot)
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
	model:SetAttribute("Combat", false)
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
		if not challenged then
			doChallenge()
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
		if pendingImpale then
			-- the one Piercing Gaze of the fight waits until the throw can reach them
			local eyeLine = hrp.Position + Vector3.new(0, 1.5 * scale, 0)
			if dist <= Actions.PiercingGaze.Range * 0.7 * scale and not worldHit(eyeLine, v.root.Position) then
				doPiercingGaze()
				return
			end
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

local testDone = false
local startClock = os.clock()
local function think()
	local clock = os.clock()
	refreshRayFilter()

	if hrp.Position.Y < homePos.Y - FALL_LIMIT * scale then
		teleportHome()
		startReturn()
	end

	-- Config.TestPhase2: show the cape and eyepatch scenes right away (for testing in Studio)
	if Config.TestPhase2 and not testDone and os.clock() - startClock > 3 then
		testDone = true
		humanoid.Health = humanoid.MaxHealth * math.min(Config.EyeHealth, 0.49)
		lastHealth = humanoid.Health
		if not capeOff then
			doRemoveCape()
		end
		if not eyeOpen and alive() then
			doRemoveEyepatch()
		end
		return
	end
	-- a phase change that is due plays even if nobody is in range
	if mode ~= "Return" and not target and (pendingCape or pendingEye) then
		if pendingCape then
			doRemoveCape()
		else
			doRemoveEyepatch()
		end
		return
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
			model:SetAttribute("Combat", false)
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
			model:SetAttribute("Combat", true)
			log("aggro", v.player.Name)
		end
		combatStep(v, clock)
		return
	end

	if mode == "Combat" then
		if clock - lastSeenTarget > LOST_TARGET_RESET then
			mode = "Idle"
			model:SetAttribute("Combat", false)
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

	-- Idle at home: stands at ease.
	if flatDist(hrp.Position, homePos) > HOME_RADIUS * scale then
		startReturn()
		return
	end
	stopMoving()
	if face.mode == "none" then
		setFacing("yaw", TURN.home, homeYaw)
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
