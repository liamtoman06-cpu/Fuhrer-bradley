--[[
	King Bradley boss - shared settings (ModuleScript "Config", required by BossServer and BossClient).
	Every time below is in seconds from the start of the action (at normal speed).

	Fight flow
	  Phase 1  on first sight he levels a saber at you (Challenge). Lunge, Cross Cut, Saber Throw,
	           Tank Cleaver.
	           At CapeHealth he tears off his cape ("Remove Cape").
	  Phase 2  at EyeHealth he tears off the eyepatch and opens the Ultimate Eye ("Remove Eyepatch").
	           Straight after, once per fight, Piercing Gaze: a close-up on the eye, then a saber
	           hurled at one player's chest (dodgeable). A hit starts the Execution cutscene.
	           Basic attacks run EyeSpeedBoost times faster and two eye abilities unlock:
	           Thousand Cuts (a 3x speed flurry that ends in a cross-shaped slash wave) and
	           Phantom Step (reads the target's movement, cuts a pentagram of slashes around them,
	           then every cut detonates at once).
]]

local Config = {
	DisplayName = "KING BRADLEY",
	Subtitle = "Wrath  ·  Führer of Amestris",
	EyeSubtitle = "Wrath  ·  The Ultimate Eye",

	TargetHeight = 9, -- the imported model is scaled to this many studs tall (nil = keep its size)
	MaxHealth = 9000,
	WalkSpeed = 12, -- walking pace (close range, returning home)
	RunSpeed = 26, -- sprint toward targets farther than RunDistance
	EyeRunSpeed = 32, -- sprint speed once the Ultimate Eye is open
	RunDistance = 26,

	CapeHealth = 0.8, -- health fraction where he throws off his cape
	EyeHealth = 0.5, -- health fraction where he removes the eyepatch (phase 2)
	EyeSpeedBoost = 1.4, -- basic attacks play this much faster in phase 2
	EyeCooldownScale = 0.65, -- basic attack cooldowns are multiplied by this in phase 2

	AggroRange = 140, -- he hunts players closer than this
	LeashRange = 240, -- he gives up and walks home past this
	BossBarRange = 170, -- players this close see the boss health bar

	TestPhase2 = false, -- true: 3 s after Play he drops to 49% and tears off the cape, then the eyepatch
	RespawnTime = 30, -- seconds after death before he comes back (nil = never)

	-- Sound ids. The defaults are sounds that ship with Roblox; replace or clear ("") as you like.
	Sounds = {
		Unsheathe = "rbxasset://sounds/unsheath.wav",
		Slash = "rbxasset://sounds/swordslash.wav",
		Lunge = "rbxasset://sounds/swordlunge.wav",
		Throw = "rbxasset://sounds/swordlunge.wav",
		Impact = "",
		CapeTear = "",
		PatchTear = "",
		EyeOpen = "",
		Detonate = "",
		Wave = "",
		Death = "",
		Voice = "", -- a line played when the Ultimate Eye opens (optional)
	},

	Cooldowns = {
		Lunge = 6,
		CrossCut = 3.2,
		SaberThrow = 7,
		Cleave = 9,
		ThousandCuts = 13,
		PhantomStep = 19,
	},

	Actions = {
		Challenge = {
			-- first sight: levels the right saber at the target's throat, the cape stirs
			Duration = 2.2,
		},
		RemoveCape = {
			-- grabs the cape at the left shoulder, rips it off and flings it aside
			Duration = 2.4,
			Grab = { 0.0, 0.6 },
			Rip = { 0.6, 0.95 },
			ReleaseAt = 0.95,
			Fling = { 0.9, 1.4 },
			Settle = { 1.4, 2.4 },
		},
		RemoveEyepatch = {
			-- left hand to the patch, tears it off, flicks it away; the Ultimate Eye opens
			Duration = 4.0,
			Raise = { 0.0, 0.7 },
			Grip = { 0.7, 0.95 },
			TearAt = 1.05,
			Toss = { 1.05, 1.5 },
			Open = { 1.8, 2.3 },
			OpenAt = 2.15,
			Aura = { 2.15, 3.4 },
			Settle = { 3.4, 4.0 },
			ShockRadius = 26,
			ShockDamage = 10,
			Knockback = 65,
		},

		-- ---------------------------------------------------------------- basic attacks
		Lunge = {
			-- crouches with the right blade drawn back, then crosses the distance in a blink
			Duration = 1.75,
			WindUp = { 0.0, 0.6 },
			Dash = { 0.6, 0.82 },
			Recover = { 0.82, 1.75 },
			Range = 32, -- maximum dash distance
			MinRange = 9, -- he prefers it when the target is farther than this
			Overshoot = 6, -- he ends this far past the target
			HitRadius = 4.5,
			Damage = 28,
		},
		CrossCut = {
			-- right diagonal, left diagonal, then both blades together in an X
			Duration = 1.9,
			Hits = { 0.32, 0.68, 1.12 },
			Step = 1.6, -- studs he advances with every cut
			Range = 10, -- reach of each cut (the drawn slashes match it; a player's width is added)
			Arc = 80, -- half-angle in front of him
			Damage = 13,
			FinalDamage = 20,
		},
		SaberThrow = {
			-- hurls the left saber like a javelin, then draws a spare from his back
			Duration = 1.9,
			WindUp = { 0.0, 0.5 },
			ReleaseAt = 0.52,
			Redraw = { 0.85, 1.45 },
			Speed = 150,
			Range = 90,
			HitRadius = 3,
			Damage = 24,
			SplashRadius = 6,
			SplashDamage = 10,
			MinRange = 16,
		},
		Cleave = {
			-- "the tank cleaver": leaps high and splits the ground with both blades
			Duration = 2.45,
			Crouch = { 0.0, 0.4 },
			Leap = { 0.4, 1.05 },
			ImpactAt = 1.05,
			Recover = { 1.2, 2.45 },
			LeapHeight = 14,
			MaxLeap = 34,
			Radius = 10,
			Damage = 34,
			FissureLength = 30,
			FissureWidth = 6,
			FissureDamage = 22,
			Knockback = 75,
		},

		-- ---------------------------------------------------------------- Ultimate Eye abilities
		ThousandCuts = {
			-- the eye locks on, time seems to stop, then he cuts three times faster than the eye
			-- can follow; it ends in a cross-shaped wave of force that tears down the arena
			Duration = 3.8,
			Focus = { 0.0, 0.75 },
			Flurry = { 0.75, 2.3 },
			Slashes = 12,
			Advance = 9,
			Range = 10,
			Arc = 85,
			TickDamage = 8,
			Final = { 2.3, 2.95 },
			FinalAt = 2.62,
			WaveSpeed = 130,
			WaveLength = 80,
			WaveWidth = 9,
			WaveDamage = 42,
			Recover = { 2.95, 3.8 },
		},
		PhantomStep = {
			-- reads where the target is going, then dashes a pentagram of cuts through that spot.
			-- The cuts hang in the air for a moment and then all detonate: get out of the lines!
			Duration = 4.8,
			Lock = { 0.0, 1.1 },
			Steps = { 1.1, 2.35 },
			Points = 5,
			Radius = 13,
			Lead = 0.45, -- seconds of the target's movement he predicts
			Pause = { 2.35, 3.2 }, -- sheathe-like pose with his back turned; the lines glow
			DetonateAt = 3.2,
			LineRadius = 3.6,
			LineDamage = 22, -- per line a player stands in (at most 3 lines count)
			CoreRadius = 7,
			CoreDamage = 30,
			Recover = { 3.35, 4.8 },
		},

		PiercingGaze = {
			-- once per fight, right after the Ultimate Eye opens: the camera closes in on his eye, a red
			-- sight line follows the target, locks (turns white) and he hurls a saber at their chest.
			-- Step off the line to dodge it. If it hits, the Execution cutscene plays.
			Duration = 3.7, -- when the throw misses
			Gaze = { 0.1, 1.35 }, -- the close-up on his eye (players within GazeRange see it)
			GazeRange = 140,
			LockAt = 1.85, -- the aim stops following the target here
			ReleaseAt = 2.1,
			Speed = 240,
			Range = 110,
			HitRadius = 2.2,
			Damage = 15,
			Redraw = { 2.75, 3.25 }, -- after a miss he draws a spare saber
		},
		Execution = {
			-- the pinned victim: he blitzes in, grips the hilt and kicks them off the blade
			Duration = 2.7,
			DashStart = 0.6,
			DashEnd = 0.98,
			StandOff = 3.6, -- he stops this far from the victim
			GrabAt = 1.04,
			KickAt = 1.32,
			KickDamage = 35,
			Knockback = 125, -- the victim's launch speed (studs/s)
			KnockUp = 55,
		},

		Death = {
			Duration = 6.5,
		},
	},
}

-- Colours of the imported meshes, by the material at the end of each mesh name (Body_Skin -> Skin).
-- { r, g, b, material?, reflectance? }
Config.Colors = {
	Skin = { 214, 166, 132 },
	SkinShade = { 168, 116, 88 },
	Lips = { 176, 112, 92 },
	Crease = { 112, 66, 50 },
	EyeWhite = { 236, 232, 222 },
	Iris = { 64, 96, 134 },
	IrisRim = { 18, 24, 34 },
	Pupil = { 8, 8, 10 },
	EyeGlint = { 255, 255, 255, "Neon" },
	LashLine = { 14, 10, 8 },
	OuroSclera = { 238, 206, 200 },
	OuroSigil = { 200, 14, 28 },
	Hair = { 16, 14, 14 },
	Eyepatch = { 14, 14, 16 },
	Shirt = { 26, 26, 32, "Fabric" },
	ShirtRib = { 20, 20, 26, "Fabric" },
	LeatherDark = { 58, 32, 20 },
	LeatherBelt = { 110, 48, 22 },
	Iron = { 168, 174, 184, "Metal" },
	Brass = { 208, 156, 58, "Metal" },
	Trousers = { 44, 86, 168, "Fabric" },
	Glove = { 98, 56, 32 },
	Boot = { 14, 14, 16, "SmoothPlastic", 0.05 },
	Sole = { 36, 28, 22 },
	Grip = { 22, 16, 12 },
	Steel = { 224, 230, 238, "Metal", 0.2 },
	Scabbard = { 18, 14, 12, "SmoothPlastic", 0.04 },
	CoatBlue = { 30, 52, 128, "Fabric" },
	CoatLining = { 20, 30, 74, "Fabric" },
	Piping = { 234, 226, 204, "Fabric" },
	Gold = { 214, 168, 58, "Metal" },
}

return Config
