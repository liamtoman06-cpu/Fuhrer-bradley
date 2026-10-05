--[[
	King Bradley boss - key poses (ModuleScript "Poses", used by BossClient).

	Every value is an offset from the rest pose, in degrees (rotations) or studs (offsets).
	  hips   = { rx, ry, rz, x, y, z }   the pelvis (x/y/z move it)
	  spine, chest, neck, head = { rx, ry, rz }
	           rx > 0 leans back / tips the head up, ry > 0 turns to his left, rz > 0 tilts to his left
	  R, L   = arms (L is mirrored, so the same numbers make a symmetric pose)
	           sh = { rx, ry, rz }  shoulder: rx > 0 raises the arm forward, rz > 0 raises it out to
	                                the side, ry > 0 turns the elbow so it bends inward
	           el = elbow bend (degrees, > 0 bends)
	           wr = { rx, ry, rz }  wrist: rx > 0 tips the blade up, ry > 0 turns it inward
	           sb = { rx, ry, rz }  the saber in the fist (spins / reverse grips)
	  fR, fL = { x, y, z, pitch } foot offsets in root space (x mirrored for the left foot); the legs
	           follow with IK. pitch > 0 lifts the toes.
	At rest the arms hang at his sides and both blades point straight forward.
]]

return {
	-- ------------------------------------------------------------------ stances
	attention = { -- out of combat, sabers sheathed: hands clasped behind his back, chest out
		hips = { 0, 0, 0, 0, 0, 0 },
		spine = { 3, 0, 0 },
		chest = { 4, 0, 0 },
		head = { 2, 0, 0 },
		R = { sh = { -32, 78, 10 }, el = 74, wr = { 0, 0, 30 } },
		L = { sh = { -32, 78, 10 }, el = 74, wr = { 0, 0, 30 } },
		fR = { 0.02, 0, 0, 0 },
		fL = { 0.02, 0, 0, 0 },
	},
	guard = { -- combat stance: loose, both blades low and forward
		hips = { 0, 14, 0, 0, -0.28, 0 },
		spine = { -4, -5, 0 },
		chest = { -4, -6, 0 },
		head = { 5, -4, 0 },
		R = { sh = { 22, 0, 14 }, el = 32, wr = { -82, 8, 0 } },
		L = { sh = { 6, 0, 22 }, el = 20, wr = { -95, -18, 0 } },
		fR = { 0.05, 0, -0.5, 0 },
		fL = { 0.12, 0, 0.45, 0 },
	},
	run = { -- sprint: hard forward lean, blades trailing low behind
		hips = { -10, 0, 0, 0, -0.2, 0 },
		spine = { -12, 0, 0 },
		chest = { -12, 0, 0 },
		head = { 26, 0, 0 },
		R = { sh = { -38, 0, 20 }, el = 24, wr = { -60, 0, 0 }, sb = { -40, 0, 0 } },
		L = { sh = { -38, 0, 20 }, el = 24, wr = { -60, 0, 0 }, sb = { -40, 0, 0 } },
	},
	walkArms = { -- arms while walking with drawn sabers
		R = { sh = { 8, 0, 12 }, el = 22, wr = { -80, 6, 0 } },
		L = { sh = { 8, 0, 12 }, el = 22, wr = { -80, 6, 0 } },
	},

	-- ------------------------------------------------------------------ Draw / Sheathe
	drawReach = { -- arms crossed in front of the belt, each hand on the opposite hilt (IK refines)
		hips = { 0, 0, 0, 0, -0.18, 0 },
		spine = { -6, 0, 0 },
		chest = { -8, 0, 0 },
		head = { -6, 0, 0 },
		R = { sh = { 30, 40, -10 }, el = 70, wr = { 0, 0, 0 } },
		L = { sh = { 30, 40, -10 }, el = 70, wr = { 0, 0, 0 } },
	},
	drawOut = { -- blades flung out to both sides
		hips = { 0, 0, 0, 0, -0.3, 0 },
		spine = { 0, 0, 0 },
		chest = { 6, 0, 0 },
		head = { 6, 0, 0 },
		R = { sh = { 30, 0, 72 }, el = 10, wr = { -30, 0, 0 } },
		L = { sh = { 30, 0, 72 }, el = 10, wr = { -30, 0, 0 } },
		fR = { 0.25, 0, -0.2, 0 },
		fL = { 0.25, 0, 0.2, 0 },
	},
	flourish = { -- right blade twirled up in front of the face, left low behind
		hips = { 0, 20, 0, 0, -0.3, 0 },
		spine = { 0, -8, 0 },
		chest = { 2, -10, 0 },
		head = { 4, -6, 0 },
		R = { sh = { 70, -20, 10 }, el = 60, wr = { -10, 0, 0 }, sb = { 0, 0, 0 } },
		L = { sh = { -20, 0, 30 }, el = 10, wr = { -110, 0, 0 } },
		fR = { 0.05, 0, -0.5, 0 },
		fL = { 0.12, 0, 0.45, 0 },
	},

	-- ------------------------------------------------------------------ Remove Cape
	capeGrab = { -- right hand across to the left shoulder clasp (IK refines)
		hips = { 0, -8, 0, 0, -0.1, 0 },
		chest = { -4, 18, 0 },
		head = { -4, 10, 0 },
		R = { sh = { 75, 55, 5 }, el = 120, wr = { 0, 0, 0 } },
		L = { sh = { 5, 0, 20 }, el = 15, wr = { -90, -15, 0 } },
	},
	capeRip = { -- the arm sweeps the cape off and out to his right
		hips = { 0, 25, 0, 0, -0.35, 0 },
		spine = { 0, -12, 0 },
		chest = { 4, -28, 6 },
		head = { 6, -16, 0 },
		R = { sh = { 40, -30, 95 }, el = 15, wr = { -20, 0, 0 } },
		L = { sh = { 10, 0, 30 }, el = 20, wr = { -95, -20, 0 } },
		fR = { 0.3, 0, -0.3, 0 },
		fL = { 0.1, 0, 0.4, 0 },
	},

	-- ------------------------------------------------------------------ Remove Eyepatch
	patchRaise = { -- left hand up to the eyepatch (IK refines)
		hips = { 0, 0, 0, 0, -0.1, 0 },
		chest = { -2, -6, 0 },
		head = { -8, -8, 6 },
		R = { sh = { 10, 0, 18 }, el = 25, wr = { -85, 8, 0 } },
		L = { sh = { 70, 70, 10 }, el = 135, wr = { 20, 0, 0 } },
	},
	patchTear = { -- rips it off and flicks it away
		hips = { 0, -10, 0, 0, -0.2, 0 },
		chest = { 2, 10, -4 },
		head = { -14, 14, -6 },
		R = { sh = { 10, 0, 22 }, el = 25, wr = { -85, 8, 0 } },
		L = { sh = { 35, -25, 85 }, el = 20, wr = { 10, 0, 0 } },
	},
	eyeOpen = { -- head snaps up, arms flare: the Ultimate Eye
		hips = { 0, 0, 0, 0, -0.4, 0 },
		spine = { 2, 0, 0 },
		chest = { 8, 0, 0 },
		head = { 10, 0, 0 },
		R = { sh = { 18, 0, 40 }, el = 15, wr = { -100, 0, 0 } },
		L = { sh = { 18, 0, 40 }, el = 15, wr = { -100, 0, 0 } },
		fR = { 0.3, 0, -0.1, 0 },
		fL = { 0.3, 0, 0.1, 0 },
	},

	-- ------------------------------------------------------------------ Lunge
	lungeWind = {
		hips = { -6, 32, 0, 0, -0.8, 0.1 },
		spine = { -10, -10, 0 },
		chest = { -10, -14, 0 },
		head = { 14, -14, 0 },
		R = { sh = { -30, 0, 22 }, el = 75, wr = { -40, 10, 0 } },
		L = { sh = { 55, -30, 10 }, el = 30, wr = { -75, -10, 0 } },
		fR = { 0.1, 0, -1.2, 0 },
		fL = { 0.2, 0, 1.15, 0 },
	},
	lungeThrust = {
		hips = { -10, -12, 0, 0, -0.65, -0.2 },
		spine = { -10, 8, 0 },
		chest = { -12, 14, 0 },
		head = { 18, 8, 0 },
		R = { sh = { 88, -6, 4 }, el = 4, wr = { -92, 0, 0 } },
		L = { sh = { -45, 0, 32 }, el = 10, wr = { -20, 0, 0 } },
		fR = { 0.05, 0, -1.7, 0 },
		fL = { 0.15, 0.1, 1.5, -10 },
	},
	lungeRecover = {
		hips = { -4, -30, 0, 0, -0.55, 0 },
		spine = { -4, 10, 0 },
		chest = { -6, 16, 0 },
		head = { 8, 14, 0 },
		R = { sh = { 30, -50, 60 }, el = 10, wr = { -30, 30, 0 } },
		L = { sh = { -10, 0, 30 }, el = 12, wr = { -100, -20, 0 } },
		fR = { 0.2, 0, -0.9, 0 },
		fL = { 0.1, 0, 0.9, 0 },
	},

	-- ------------------------------------------------------------------ Cross Cut
	ccRaise = { -- both blades cocked high on the right
		hips = { 0, -18, 0, 0, -0.3, 0 },
		spine = { 0, -10, 0 },
		chest = { 4, -18, 0 },
		head = { 4, 16, 0 },
		R = { sh = { 110, 0, 50 }, el = 40, wr = { 30, 0, 0 } },
		L = { sh = { 40, 30, -10 }, el = 60, wr = { -60, 0, 0 } },
		fR = { 0.1, 0, -0.5, 0 },
		fL = { 0.1, 0, 0.45, 0 },
	},
	ccCut1 = { -- right blade down across to the left
		hips = { -4, 20, 0, 0, -0.5, 0 },
		spine = { -6, 10, 0 },
		chest = { -10, 22, 0 },
		head = { 10, -14, 0 },
		R = { sh = { 30, 60, -30 }, el = 10, wr = { -40, 20, 0 } },
		L = { sh = { 80, 0, 60 }, el = 50, wr = { 20, 0, 0 } },
		fR = { 0.1, 0, -0.7, 0 },
		fL = { 0.1, 0, 0.5, 0 },
	},
	ccCut2 = { -- left blade down across to the right
		hips = { -4, -20, 0, 0, -0.5, 0 },
		spine = { -6, -10, 0 },
		chest = { -10, -22, 0 },
		head = { 10, 14, 0 },
		R = { sh = { 100, 0, 40 }, el = 70, wr = { 30, 0, 0 } },
		L = { sh = { 30, 60, -30 }, el = 10, wr = { -40, 20, 0 } },
		fR = { 0.1, 0, -0.7, 0 },
		fL = { 0.1, 0, 0.5, 0 },
	},
	ccX = { -- both blades crossed high in front
		hips = { 4, 0, 0, 0, -0.25, 0 },
		spine = { 4, 0, 0 },
		chest = { 8, 0, 0 },
		head = { 2, 0, 0 },
		R = { sh = { 140, 30, -10 }, el = 30, wr = { 20, 0, 0 } },
		L = { sh = { 140, 30, -10 }, el = 30, wr = { 20, 0, 0 } },
		fR = { 0.1, 0, -0.6, 0 },
		fL = { 0.1, 0, 0.5, 0 },
	},
	ccXCut = { -- both blades sweep down and apart: the X
		hips = { -8, 0, 0, 0, -0.75, -0.1 },
		spine = { -10, 0, 0 },
		chest = { -14, 0, 0 },
		head = { 18, 0, 0 },
		R = { sh = { 20, -20, 60 }, el = 6, wr = { -60, 0, 0 } },
		L = { sh = { 20, -20, 60 }, el = 6, wr = { -60, 0, 0 } },
		fR = { 0.2, 0, -0.9, 0 },
		fL = { 0.2, 0, 0.7, 0 },
	},

	-- ------------------------------------------------------------------ Saber Throw (left hand)
	throwWind = {
		hips = { 0, -40, 0, 0, -0.4, 0.15 },
		spine = { 4, -14, 0 },
		chest = { 6, -20, -4 },
		head = { -2, 36, 0 },
		R = { sh = { 45, 20, 20 }, el = 40, wr = { -60, 0, 0 } },
		L = { sh = { -10, -20, 120 }, el = 70, wr = { 10, 0, 0 } },
		fR = { 0.1, 0, 0.6, 0 },
		fL = { 0.2, 0, -0.7, 0 },
	},
	throwRelease = {
		hips = { -6, 28, 0, 0, -0.5, -0.2 },
		spine = { -6, 14, 0 },
		chest = { -10, 20, 0 },
		head = { 12, -18, 0 },
		R = { sh = { -20, 0, 30 }, el = 20, wr = { -80, 0, 0 } },
		L = { sh = { 105, 0, 8 }, el = 2, wr = { -98, 0, 0 } },
		fR = { 0.1, 0, 0.7, 0 },
		fL = { 0.1, 0, -1.0, 0 },
	},
	throwReachBack = { -- left hand behind the hip for a spare (IK refines)
		hips = { 0, -10, 0, 0, -0.3, 0 },
		chest = { 0, -16, 0 },
		head = { 4, 14, 0 },
		R = { sh = { 20, 0, 16 }, el = 30, wr = { -80, 8, 0 } },
		L = { sh = { -40, 0, 30 }, el = 50, wr = { 0, 0, 0 } },
	},

	-- ------------------------------------------------------------------ Tank Cleaver
	cleaveCrouch = {
		hips = { -12, 0, 0, 0, -1.0, 0.2 },
		spine = { -12, 0, 0 },
		chest = { -10, 0, 0 },
		head = { 26, 0, 0 },
		R = { sh = { -50, 0, 25 }, el = 20, wr = { -30, 0, 0 } },
		L = { sh = { -50, 0, 25 }, el = 20, wr = { -30, 0, 0 } },
		fR = { 0.2, 0, -0.4, 0 },
		fL = { 0.2, 0, 0.4, 0 },
	},
	cleaveAir = { -- both blades raised high behind the head, knees tucked
		hips = { 10, 0, 0, 0, 0.2, 0 },
		spine = { 10, 0, 0 },
		chest = { 12, 0, 0 },
		head = { -4, 0, 0 },
		R = { sh = { 170, 10, 20 }, el = 50, wr = { 40, 0, 0 } },
		L = { sh = { 170, 10, 20 }, el = 50, wr = { 40, 0, 0 } },
		fR = { 0.1, 1.6, 0.4, -20 },
		fL = { 0.1, 1.2, 0.7, -20 },
	},
	cleaveImpact = { -- blades buried in the ground in front, deep crouch
		hips = { -16, 0, 0, 0, -1.25, -0.1 },
		spine = { -18, 0, 0 },
		chest = { -18, 0, 0 },
		head = { 34, 0, 0 },
		R = { sh = { 60, 20, 8 }, el = 5, wr = { -120, 0, 0 } },
		L = { sh = { 60, 20, 8 }, el = 5, wr = { -120, 0, 0 } },
		fR = { 0.25, 0, -0.9, 0 },
		fL = { 0.25, 0, 0.8, 0 },
	},

	-- ------------------------------------------------------------------ Thousand Cuts
	tcFocus = { -- utterly still; the eye does the work
		hips = { 0, 0, 0, 0, -0.35, 0 },
		spine = { 0, 0, 0 },
		chest = { 2, 0, 0 },
		head = { -6, 0, 0 },
		R = { sh = { 0, 0, 30 }, el = 8, wr = { -115, 0, 0 } },
		L = { sh = { 0, 0, 30 }, el = 8, wr = { -115, 0, 0 } },
		fR = { 0.2, 0, -0.35, 0 },
		fL = { 0.2, 0, 0.35, 0 },
	},
	tcA = {
		hips = { -6, 22, 0, 0, -0.55, 0 },
		spine = { -6, 12, 0 },
		chest = { -10, 24, 0 },
		head = { 12, -20, 0 },
		R = { sh = { 40, 70, -40 }, el = 6, wr = { -20, 30, 0 } },
		L = { sh = { 120, -30, 50 }, el = 40, wr = { 30, 0, 0 } },
		fR = { 0.1, 0, -0.8, 0 },
		fL = { 0.1, 0, 0.6, 0 },
	},
	tcB = {
		hips = { -6, -22, 0, 0, -0.55, 0 },
		spine = { -6, -12, 0 },
		chest = { -10, -24, 0 },
		head = { 12, 20, 0 },
		R = { sh = { 120, -30, 50 }, el = 40, wr = { 30, 0, 0 } },
		L = { sh = { 40, 70, -40 }, el = 6, wr = { -20, 30, 0 } },
		fR = { 0.1, 0, -0.8, 0 },
		fL = { 0.1, 0, 0.6, 0 },
	},
	tcC = { -- low horizontal cut, both blades
		hips = { -10, 0, 0, 0, -0.85, 0 },
		spine = { -10, 0, 0 },
		chest = { -14, 0, 0 },
		head = { 24, 0, 0 },
		R = { sh = { 75, 20, 45 }, el = 8, wr = { -80, -30, 0 } },
		L = { sh = { 75, 20, 45 }, el = 8, wr = { -80, -30, 0 } },
		fR = { 0.25, 0, -0.9, 0 },
		fL = { 0.25, 0, 0.6, 0 },
	},
	tcCross = { -- blades crossed at the chest before the wave
		hips = { 2, 0, 0, 0, -0.45, 0.1 },
		spine = { 4, 0, 0 },
		chest = { 6, 0, 0 },
		head = { 0, 0, 0 },
		R = { sh = { 60, 70, 10 }, el = 90, wr = { 40, 0, 0 } },
		L = { sh = { 60, 70, 10 }, el = 90, wr = { 40, 0, 0 } },
		fR = { 0.15, 0, -0.5, 0 },
		fL = { 0.15, 0, 0.5, 0 },
	},
	tcRelease = { -- both blades flung apart: the cross-shaped wave
		hips = { -10, 0, 0, 0, -0.85, -0.15 },
		spine = { -8, 0, 0 },
		chest = { -10, 0, 0 },
		head = { 20, 0, 0 },
		R = { sh = { 85, -10, 75 }, el = 4, wr = { -90, -20, 0 } },
		L = { sh = { 85, -10, 75 }, el = 4, wr = { -90, -20, 0 } },
		fR = { 0.25, 0, -1.0, 0 },
		fL = { 0.25, 0, 0.8, 0 },
	},

	-- ------------------------------------------------------------------ Phantom Step
	psLock = { -- tall and still, head tilted, blades low; the eye locks on
		hips = { 0, 0, 0, 0, -0.1, 0 },
		spine = { 2, 0, 0 },
		chest = { 4, 0, 0 },
		head = { 2, 0, 10 },
		R = { sh = { 5, 0, 18 }, el = 10, wr = { -110, 0, 0 } },
		L = { sh = { 5, 0, 18 }, el = 10, wr = { -110, 0, 0 } },
	},
	psDash = { -- low cutting dash, both blades swept back
		hips = { -14, 0, 0, 0, -0.9, 0 },
		spine = { -14, 0, 0 },
		chest = { -12, 0, 0 },
		head = { 30, 0, 0 },
		R = { sh = { -55, 0, 40 }, el = 10, wr = { 30, 0, 0 } },
		L = { sh = { -55, 0, 40 }, el = 10, wr = { 30, 0, 0 } },
		fR = { 0.1, 0, -1.1, 0 },
		fL = { 0.1, 0.3, 1.1, -10 },
	},
	psPause = { -- back turned, right blade flicked down and out (chiburi), left held low
		hips = { 0, 0, 0, 0, -0.2, 0 },
		spine = { 2, 0, 0 },
		chest = { 4, 0, 0 },
		head = { -4, 0, 0 },
		R = { sh = { 30, 0, 45 }, el = 5, wr = { -125, 0, 0 } },
		L = { sh = { -5, 0, 14 }, el = 15, wr = { -100, 0, 0 } },
		fR = { 0.1, 0, -0.2, 0 },
		fL = { 0.1, 0, 0.2, 0 },
	},

	-- ------------------------------------------------------------------ Death
	deathStagger = {
		hips = { 8, 0, 0, 0, -0.3, 0.3 },
		spine = { 8, 0, 0 },
		chest = { 10, 0, 6 },
		head = { 16, 0, 10 },
		R = { sh = { 0, 0, 25 }, el = 20, wr = { -110, 0, 0 } },
		L = { sh = { 0, 0, 25 }, el = 20, wr = { -110, 0, 0 } },
		fR = { 0.1, 0, 0.3, 0 },
		fL = { 0.1, 0, 0.6, 0 },
	},
	deathKneel = { -- down on one knee, head bowed, blades dropped
		hips = { -6, 0, 0, 0, -1.7, 0.2 },
		spine = { -10, 0, 0 },
		chest = { -14, 0, 0 },
		head = { -20, 0, 0 },
		R = { sh = { 10, 0, 18 }, el = 25, wr = { -60, 0, 0 } },
		L = { sh = { 25, 0, 10 }, el = 40, wr = { -60, 0, 0 } },
		fR = { 0.05, 0.0, -0.9, 0 },
		fL = { 0.05, 0.0, 1.4, -40 },
	},
	deathLying = { -- on his back, looking at the sky
		hips = { 88, 0, 0, 0, -4.15, 0.6 },
		spine = { 0, 0, 0 },
		chest = { 0, 0, 0 },
		head = { 6, 18, 0 },
		R = { sh = { 0, 0, 40 }, el = 10, wr = { -60, 0, 0 } },
		L = { sh = { 0, 0, 30 }, el = 25, wr = { -60, 0, 0 } },
		fR = { 0.12, 0.08, -3.55, 75 },
		fL = { 0.3, 0.08, -3.35, 75 },
	},
}
