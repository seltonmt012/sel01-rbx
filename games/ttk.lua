--[[ ttk.lua - "TTK Testing" by Sable Digital (place 120189115846709)

  The fifth SHOOTER in this collection and the first one that ships with a real
  ANTICHEAT. Everything below was measured through the bridge before a line of
  this was written; where a number appears in this file it came off the running
  client, not off a guess.

  ============================================================================
  THE ANTICHEAT, AND WHY THIS FILE IS SHAPED THE WAY IT IS
  ============================================================================

  `Modules.Client.Controllers.IntegrityController` was decompiled and read in
  full. It does not kick and it does not ban - it REPORTS, over
  `Remotes.Combat.SessionTelemetry:FireServer(reason, {device, locale, build})`,
  and each reason is sent exactly once per session (a dedupe table in `send`).
  What it watches, and how often:

    ENV_GLOBAL       42 executor globals looked up in getfenv(1..8)   6-12s
    FENV_SRC         debug.info(getfenv, "s") changed                 6-12s
    CANARY           a random key it planted in its own env           6-12s
    MM_INDEX         __index replaced                                 6-12s
    MM_NAMECALL      __namecall replaced                              6-12s
    MM_NOTC          either metamethod is no longer a C closure       6-12s
    FIRESERVER_HOOK  SessionTelemetry.FireServer is not a C closure   6-12s
    PCALL_HOOK       pcall no longer runs its argument                6-12s
    STACK_NAMECALL   197 nested coroutine.wrap overflows (DEX probe)  6-12s
    RECOIL_S_LOW     RecoilSpring.s < 6 on the controller or weapon   0.35s
    BODYMOVER        BodyVelocity/Gyro/Position/Thrust/AngularVelocity live
    LOG_SIG          LogService output matching a tool-name word list live

  MEASURED, and this is the fact the whole file rests on: with the bridge
  running for several minutes with `decompile`, `hookfunction` and `getgc` all
  resolvable, the dedupe table inside `send` was **EMPTY**. Potassium does not
  leak its globals into the game's environment, so `checkGlobals` never fires.
  We are clean - as long as the six rules below are kept:

    1. NOTHING here hooks a metamethod. No hookmetamethod, anywhere, ever.
    2. NOTHING here hooks FireServer.
    3. NOTHING here writes RecoilSpring. The recoil page CANCELS the residual on
       the camera instead, which is invisible to that check - and measured:
       GunController.RecoilSpring.s reads 6.3 against a threshold of 6, so it is
       not a value with room to be nudged even if we wanted to.
    4. NOTHING here parents a BodyMover to the character.
    5. NOTHING printed by this file contains a word from that log list.
    6. The panel says all of the above out loud, on its own page, so the user can
       check it rather than take it on faith.

  ============================================================================
  WHAT THE GAME LOOKS LIKE
  ============================================================================

  * **The character you can see is not the character Roblox thinks you have.**
    `Player.Character` is an R6 decoy - five parts, three of them named `Torso2`.
    The real body is `workspace.MercPlayers.MercHitboxes_<name>`, a 15-part R15
    rig, every part Transparency 1, CanQuery true, CanCollide false, collision
    group `Map`. `MercVisual_<name>` beside it is the model you see. Dead bodies
    are reparented as `MercHitboxes_<name>_Corpse`.

    This matters: the published silent-aim scripts for this game that read
    `player.Character.Head` are aiming at the decoy.

  * **...but the decoy carries the Humanoid, and that Humanoid is the health.**
    Measured over a 20s sample on a live round: `huso12sila` was caught at 13 HP
    in one frame of 125, and three players went 100 -> 0 exactly as their
    `RigState` went Alive -> Ragdolled. So health is real and replicates for
    everybody. The intermediate values are just rare, because the game is called
    TTK for a reason.

  * **Positions replicate in full, with no culling whatsoever.** Measured on five
    enemies at 120-383 studs, every one of them behind an opaque wall: exact head
    positions readable for all five.

  * **`RigState` has THREE values, not two**: Alive, Ragdolled, Dead. Ragdolled is
    a body on the floor, and it still has a full set of hitbox parts - so "the
    model exists" proves nothing and neither does "it has a Head".

  * **Teams exist even in the free-for-all.** `Hostility.TeamOf` answered `Alpha`
    for us and `Bravo` for another player in a mode whose `GameMode` attribute
    reads `FFA`, and `Hostility.IsHostile(a, b)` answered true. So this file never
    reconstructs hostility from a team name - it asks the game's own function,
    which is right in every mode by construction.

  * **THE HEAD IS WORTH EVERYTHING HERE**, which is the opposite of Deagle Arena
    and worth stating because it decides the default. Read out of
    `Registries.Weapons` against 100 max health:

        M18       37 x4 = 148      MK23     42 x4 = 168
        Rattler   34 x4 = 136      AUGA3    34 x4 = 136
        KH9       32 x4 = 128      UMP45    31 x4 = 124
        MP5A2     28 x4 = 112      M1ASOCOM 55 x2 = 110

    Every single firearm one-shots to the head. To the body the same guns need
    three hits. So `aimPart` defaults to Head, and the panel prints that table
    next to the dropdown rather than asserting it.

  * **Round state is attributes on `workspace` itself**, not a Status folder:
    `GamePhase`, `MatchState`, `GameMode`, `CurrentMapName`, `MapRoundEndsAt`,
    `ModeScoreLimit`, `DeployPolicy`, `Mode_Respawns`, plus the whole `Flow_*` set
    the outro screen runs on.

  * **The scoreboard is player attributes and it replicates for EVERYONE**:
    `Kills`, `Deaths`, `MatchXP`, `MatchIC`, `CurrentWeapon`, `SelectedSlot`,
    `Deployed`, `PlayerMode`, `InWorld`, `WeaponLaserOn`, `WeaponFlashlightOn`,
    `ThrowableAmmo_Flashbang`. `Kills` is the oracle every claim here is checked
    against, and `CurrentWeapon` means the ESP can print what each enemy holds.

  * **The clip-brush trap has a clean answer here, and the game supplies it.**
    91 `MapBarrier` parts plus `MapCeiling` are Transparency 1 and CanCollide
    true - exactly the Counter Blox brushes that made every enemy read as behind
    a wall - but they sit in collision group `Ignore`, and
    `Default x Ignore = false`. A plain default-group ray already skips them and
    no hand-built filter is needed. What DOES legitimately block is the 492
    `Collision` hulls, the 70 `shelf_hitbox` parts and corpses (`Default x Corpse
    = true`), and that is correct: the game's own `Discharge` sets no collision
    group either, so its bullet stops on exactly the same things.

  * **The client's exclude list is only the player characters.** Pulled out of
    `BulletController.Discharge`'s upvalues, `buildExcludeList` walks
    `Players:GetPlayers()` and inserts each `Character` - i.e. the R6 decoys. This
    file uses the same list plus its own POV rig, so the wall check answers the
    question the shot asks.

  * **THE CAMERA CONTROLLER IS AUTHORITATIVE. Camera writes do NOTHING here, and
    the first measurement of this said the opposite.** Worth writing down because
    the wrong test looks exactly like a right one:

        WRONG - write `want` every frame from a Camera+1 binding, then read the
        camera back and compare. It matches perfectly, because you are painting
        over the controller every single frame. This is what was measured first
        and it produced the claim "the write sticks".

        RIGHT - (a) write a small nudge each frame and compare what you LEFT
        against what the NEXT frame finds, and (b) write once, unbind, and see
        whether it survives.

    Measured properly: a 0.5 deg nudge came back **0.4977 deg** different on the
    next frame - a 100% revert, every frame, over 281 samples. A single 20 deg
    write read **19.94 deg away from the target** and **0.08 deg from where it
    started** five frames later. The controller rebuilds the CFrame from angles
    it keeps itself, exactly like BloxStrike.

    The symptom is the BloxStrike signature: the assist reports plenty of degrees
    per second of work while the view never moves, so the panel looks busy and
    nothing happens.

  * **So the view is moved with `mousemoverel`, and it persists.** Measured:
    `mousemoverel(60, 0)` turned **-2.47 deg** of yaw, `(-60, 0)` turned
    **+2.47**, `(200, 0)` turned **-8.08**, and `(0, 30)` turned **-1.05 deg** of
    pitch - about **0.041 deg per pixel**, still there a full second later.
    Positive x turns right and lowers yaw; positive y looks down. `aimPath`
    therefore defaults to Mouse; the Camera option is kept only so the difference
    can be demonstrated, and it is labelled as doing nothing.

  * **The shot state is published by the client and needs no inferring.**
    `GunController.Weapon` carries `MagAmmo`, `MaxMagSize`, `FireRate`,
    `FireMode`, `IsAiming`, `IsReloading`, `IsEquipped`, `CanFire`, `Name` and a
    live `ShotIndex`. So the spray position is READ, not counted off a fire rate
    the way counterblox had to.

  * **There are no Actor VMs.** `getactors()` returns 0, so everything is
    reachable from the main VM. Nothing in this file needs that, but it is why
    the recon above could be done at all.

  ============================================================================
  WHAT THIS FILE DOES NOT DO
  ============================================================================

  Nothing here fabricates a hit, fires a combat remote, or writes a damage value.
  The aim moves the VIEW and the trigger presses the REAL mouse button, so
  whatever the server validates, it validates an ordinary shot.

  There is deliberately NO silent-aim page. `BulletController._ClaimMercHit` fires
  `Remotes.Combat.MercHitClaim:FireServer(weapon, userId, partName, ...)` - the
  client names the part it hit, which is the shape where silent aim is normally
  possible - but whether the server re-checks the direction or the line of sight
  was NOT MEASURED, and this project does not ship an exploit on the strength of
  the shape alone. The RECOIL page says so in as many words. If the two shots that
  would settle it are ever fired against the `Kills` attribute, the page can be
  added then, off by default and in no preset, the way the genre file requires.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr    = Players.LocalPlayer
local camera = workspace.CurrentCamera

local GEN = (_G.__TTK or 0) + 1
_G.__TTK = GEN

-- A task.spawn runs its first pass SYNCHRONOUSLY, in whatever context executed
-- the file. Loaded through `bridge.py file` that is the poll loop's sandbox, and
-- an Instance touched from there throws "lacking capability Plugin" exactly once
-- per run before recovering by itself - which looks like a random startup error
-- and is not. One yield moves the first pass onto a normal scheduler frame.
local function claimIdentity()
	if setthreadidentity then pcall(setthreadidentity, 8) end
	task.wait()
end

-- Every WaitForChild here carries a timeout. `pcall` catches errors, not endless
-- waits, so an untimed WaitForChild in the wrong game parks the bridge forever.
local function waitFor(parent, name, timeout)
	if not parent then return nil end
	local ok, child = pcall(function() return parent:WaitForChild(name, timeout or 10) end)
	if ok then return child end
	return nil
end

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	-- ESP ----------------------------------------------------------------------
	box        = true,
	boxFilled  = false,
	name       = true,
	health     = true,
	weaponTag  = true,    -- what they are holding - the Player attribute replicates
	teamTag    = true,
	kdTag      = false,
	distance   = true,
	tracer     = false,
	headDot    = false,
	skeleton   = false,
	hitboxDraw = false,   -- the real 15-part rig, drawn as it is
	deadESP    = false,   -- Ragdolled bodies
	chams      = false,
	visCheck   = true,
	maxDist    = 1200,
	rangeTag   = true,    -- mark anybody past the equipped weapon's own Range
	textSize   = 14,
	textFont   = "System",
	textOutline = true,
	textShrink = false,

	colEnemy   = Color3.fromRGB(255, 72, 88),
	colFriend  = Color3.fromRGB(90, 190, 255),
	colDead    = Color3.fromRGB(120, 128, 140),
	colCham    = Color3.fromRGB(255, 72, 88),
	colChamOwn = false,
	colFov     = Color3.fromRGB(255, 255, 255),
	colHitbox  = Color3.fromRGB(120, 200, 255),
	colCross   = Color3.fromRGB(90, 255, 140),

	chamStyle  = "Fill",
	chamRainbow = false,

	drawFriendly = false,  -- in a team mode, draw your own side too

	-- visuals ------------------------------------------------------------------
	crosshair  = false,
	crossSize  = 8,
	crossGap   = 3,
	crossDot   = true,
	crossThick = 1,
	ammoBar    = true,    -- magazine under the crosshair, read from the weapon

	-- aim assist ---------------------------------------------------------------
	aim        = false,
	aimActive  = "Hotkey",
	aimKey     = "MouseButton2",
	aimPart    = "Head",   -- every firearm one-shots to the head here
	aimPick    = "Crosshair",
	aimSticky  = true,
	aimVisible = true,
	aimMaxDist = 400,
	aimReady   = true,     -- only assist while the gun can actually fire
	aimAds     = "Always",
	aimCurve   = "Ease out",
	aimPath    = "Mouse",  -- Mouse | Camera  (Camera does NOTHING here - see below)
	-- Weapon = drive the BULLET onto the target, Crosshair = the old, wrong way.
	aimAlign   = "Weapon",

	-- MEASURED over 18s on a live match, 340 target-frames: the MEDIAN enemy sits
	-- 597 px from the crosshair, and a 120 px circle passed only 39 of them while
	-- 143 fell outside it. Nothing was blocking the assist - the window was simply
	-- far smaller than the distances this game actually produces. 250 is the value
	-- that turns "it does nothing" into "it helps", without becoming a snap.
	aimFov     = 250,
	aimSmoothH = 14,
	aimSmoothV = 16,

	aimFire    = false,
	aimHitPct  = 100,
	aimKillMs  = 350,
	aimFirstMs = 0,

	aimCircle  = true,

	-- trigger ------------------------------------------------------------------
	trig       = false,
	trigActive = "Hotkey",
	trigKey    = "C",
	trigDelayMin = 40,
	trigDelayMax = 110,
	trigRefireMs = 60,
	trigHitPct = 100,
	trigHeadOnly = false,
	trigMaxDist = 400,
	trigFov    = 0,
	trigAds    = "Always",
	trigHold   = false,    -- hold the button down on an automatic
	trigHoldMs = 120,

	-- recoil control -----------------------------------------------------------
	--
	-- Camera side ONLY. This never touches RecoilSpring, which is the field the
	-- anticheat samples every 0.35s.
	rcs        = false,
	-- Predicted uses the game's OWN per-weapon formula (read out of FPSController
	-- line 1110). Measured is the generic residual method and is the fallback.
	rcsMode    = "Predicted",
	rcsPct     = 70,
	rcsMaxDeg  = 3,
	rcsHoriz   = true,
	rcsFirst   = 1,        -- leave the first N shots of a spray alone

	-- humaniser ----------------------------------------------------------------
	hum          = true,
	humWindupMin = 40,
	humWindupMax = 130,
	humOffsetPct = 35,
	humJitter    = 0.9,
	humJitterHz  = 1.4,
	humOvershoot = 30,
	humOverDeg   = 1.8,
	humHeadPct   = 100,    -- the head is the whole point in this game
	humMissPct   = 0,
	humBreakPct  = 6,
	humBreakMs   = 180,
	humFatigue   = 25,
	humCooldown  = 120,
	humReactSd   = 22,
	humPanelPause = true,
	humTurnCap   = 260,
	humDeadzone  = 2,
	humMoveFov   = 70,
	humSwitchMs  = 350,
	humRerollMs  = 900,
	humRoundMs   = 800,

	panicKey     = "End",
}

local DRAWINGS = {
	"box", "boxFilled", "name", "health", "weaponTag", "teamTag", "kdTag",
	"distance", "tracer", "headDot", "skeleton", "hitboxDraw", "deadESP", "chams",
}

local function anyDrawing()
	for _, key in ipairs(DRAWINGS) do
		if CONFIG[key] then return true end
	end
	return false
end

local PRESETS = {
	["Legit"] = {
		aimFov = 110, aimSmoothH = 30, aimSmoothV = 40, aimPart = "Head",
		aimFire = false, aimVisible = true, aimCurve = "Human",
		trigDelayMin = 110, trigDelayMax = 240, trigRefireMs = 200, trigHitPct = 85,
		rcs = true, rcsPct = 45, rcsFirst = 2,
		hum = true, humTurnCap = 160, humDeadzone = 4, humWindupMin = 90,
		humWindupMax = 240, humOffsetPct = 55, humHeadPct = 55, humOvershoot = 45,
		humBreakPct = 12, humMissPct = 8, humFatigue = 40, humCooldown = 260,
		humMoveFov = 45,
	},
	["Normal"] = {
		aimFov = 250, aimSmoothH = 14, aimSmoothV = 16, aimPart = "Head",
		aimFire = false, aimVisible = true, aimCurve = "Ease out",
		trigDelayMin = 40, trigDelayMax = 110, trigRefireMs = 60, trigHitPct = 100,
		rcs = true, rcsPct = 70, rcsFirst = 1,
		hum = true, humTurnCap = 260, humDeadzone = 2, humWindupMin = 40,
		humWindupMax = 130, humOffsetPct = 35, humHeadPct = 100, humOvershoot = 30,
		humBreakPct = 6, humMissPct = 0, humFatigue = 25, humCooldown = 120,
		humMoveFov = 70,
	},
	["Raw"] = {
		aimFov = 600, aimSmoothH = 2, aimSmoothV = 2, aimPart = "Head",
		aimFire = true, aimVisible = true, aimCurve = "Linear",
		trigDelayMin = 0, trigDelayMax = 10, trigRefireMs = 30, trigHitPct = 100,
		rcs = true, rcsPct = 100, rcsFirst = 0,
		hum = false, humTurnCap = 3000, humDeadzone = 0, humWindupMin = 0,
		humWindupMax = 0, humOffsetPct = 0, humHeadPct = 100, humOvershoot = 0,
		humBreakPct = 0, humMissPct = 0, humFatigue = 0, humCooldown = 0,
		humMoveFov = 100,
	},
}

local STATE = {
	note       = "",
	targets    = 0, enemies = 0, friends = 0,
	target     = "-", targetPart = "-",
	trigHits   = 0, trigOn = false,
	underCross = "-",
	aimDps     = 0, aimDpsPeak = 0, gunOffset = -1, aimError = 0, aimPending = 0,
	lastKey    = "-",
	paused     = "",
	deployed   = false,
	aiming     = false, reloading = false, firing = false,
	mag = 0, magMax = 0, weapon = "-", fireMode = "-", shotIndex = 0,
	kills = 0, deaths = 0, xp = 0, ic = 0,
	sessionKills = 0, sessionDeaths = 0,
	phase = "-", matchState = "-", mode = "-", map = "-", timer = "-",
	scoreLimit = 0,
	chams      = "-",
	kickPeak   = 0, kickNow = 0, kickN = 0, kickHoriz = 0,
	sens       = 0, sensYaw = 0,
	rcsApplied = 0, rcsUnit = 0, rcsUnitN = 0, rcsDebt = 0, rcsPredV = 0,
	dmgBody = 0, dmgHead = 0, shotsToBody = 0,
}

local COLOUR = {
	hpGood = Color3.fromRGB(90, 220, 120),
	hpBad  = Color3.fromRGB(230, 80, 60),
	text   = Color3.fromRGB(235, 235, 240),
	black  = Color3.fromRGB(0, 0, 0),
}

local function note(text) STATE.note = tostring(text) end

local function dimmed(colour)
	local h, s, v = Color3.toHSV(colour)
	return Color3.fromHSV(h, s * 0.9, v * 0.55)
end

--------------------------------------------------------------------------------
-- the game's own modules
--------------------------------------------------------------------------------
--
-- Every one of these is REQUIRED, never rebuilt. require() on a module the client
-- has already loaded returns the same cached table, so this reads live state
-- rather than building a second copy of it.
--
-- Not one of them is HOOKED. See the anticheat block at the top of the file.

local Modules    = waitFor(ReplicatedStorage, "Modules", 10)
local Shared     = Modules and waitFor(Modules, "Shared", 10)
local ClientMods = Modules and waitFor(Modules, "Client", 10)
local Registries = waitFor(ReplicatedStorage, "Registries", 10)

local function tryRequire(inst)
	if not inst then return nil end
	local ok, value = pcall(require, inst)
	if ok then return value end
	return nil
end

local Controllers = ClientMods and ClientMods:FindFirstChild("Controllers")

local GunCtl    = tryRequire(Controllers and Controllers:FindFirstChild("GunController"))
local CameraPOV = tryRequire(ClientMods and ClientMods:FindFirstChild("CameraPOV"))
local Hostility = tryRequire(Shared and Shared:FindFirstChild("Combat")
	and Shared.Combat:FindFirstChild("Hostility"))
local BodyDamage = tryRequire(Shared and Shared:FindFirstChild("BodyDamage"))
local WEAPONS    = tryRequire(Registries and Registries:FindFirstChild("Weapons")) or {}

if not GunCtl then
	note("GunController missing - ammo, ADS and the fire gate fall back to guesses")
end

-- "Is this a firearm" comes from CONTENT, never from the name. The 15 entries in
-- the registry include `AutoScanner` (Damage 0, no magazine), `M320` (a launcher,
-- one round) and `FireModes`, which is not a weapon at all but a shared sub-table
-- sitting in the same folder. A name list would need maintaining forever.
local function weaponDef(name)
	if type(name) ~= "string" then return nil end
	local def = WEAPONS[name]
	if type(def) ~= "table" then return nil end
	if type(def.Damage) ~= "number" or def.Damage <= 0 then return nil end
	if type(def.FireRate) ~= "number" or def.FireRate <= 0 then return nil end
	return def
end

--------------------------------------------------------------------------------
-- combatants
--------------------------------------------------------------------------------
--
-- Membership of `workspace.MercPlayers` is what "in the round" MEANS, exactly
-- like `workspace.Characters` in BloxStrike. A player sitting in the menu still
-- has a Player object and still has a `Player.Character` - the R6 decoy - and
-- counting that as a live enemy is the trap that put three lobby players on the
-- ESP in that game.
--
-- Rebuilt on a short timer rather than per frame: the render pass, the aim pass
-- and the trigger loop all want the same list and there is no reason to build it
-- three times in one frame.

local MercPlayers = workspace:FindFirstChild("MercPlayers")

local combatCache, combatAt = {}, 0

local function hostileTo(other)
	if not other then return true end
	if Hostility and Hostility.IsHostile then
		local ok, res = pcall(Hostility.IsHostile, plr, other)
		if ok then return res == true end
	end
	-- Only reached if the shared module could not be required. In a free-for-all
	-- everybody is hostile, which is the safe way round: it draws too much rather
	-- than hiding somebody who can kill you.
	return true
end

local function teamName(p)
	if Hostility and Hostility.TeamOf and p then
		local ok, t = pcall(Hostility.TeamOf, p)
		if ok and t then return tostring(t) end
	end
	return "-"
end

local function combatants()
	local now = os.clock()
	if now - combatAt < 0.2 then return combatCache end
	combatAt = now

	if not MercPlayers or not MercPlayers.Parent then
		MercPlayers = workspace:FindFirstChild("MercPlayers")
	end

	local list = {}
	if not MercPlayers then
		combatCache = list
		return list
	end

	for _, m in ipairs(MercPlayers:GetChildren()) do
		local name = m.Name
		if name:sub(1, 13) == "MercHitboxes_" then
			-- Corpses keep a full set of hitbox parts, so they have to be excluded by
			-- NAME as well as by RigState: a `_Corpse` rig reads Ragdolled and would
			-- otherwise be indistinguishable from a body that is about to get up.
			if name:sub(-7) ~= "_Corpse" then
				local owner  = m:GetAttribute("RigOwner")
				local userId = m:GetAttribute("OwnerUserId")
				if owner ~= plr.Name then
					local p = nil
					if type(userId) == "number" then
						local ok, found = pcall(Players.GetPlayerByUserId, Players, userId)
						if ok then p = found end
					end
					if not p and type(owner) == "string" then
						p = Players:FindFirstChild(owner)
					end
					if p ~= plr then
						local foe = hostileTo(p)
						if foe or CONFIG.drawFriendly then
							list[#list + 1] = {
								model  = m,
								name   = tostring(owner or (p and p.Name) or "?"),
								player = p,
								foe    = foe,
							}
						end
					end
				end
			end
		end
	end

	combatCache = list
	return list
end

-- THE MODEL YOU AIM AT AND THE MODEL YOU CAN SEE ARE TWO DIFFERENT MODELS, and
-- anything visual has to use this one. `MercHitboxes_<name>` is 15 parts and
-- every single one is Transparency 1 - measured - so a Highlight adorned there
-- renders nothing whatsoever, which is exactly what a broken cham looks like.
-- `MercVisual_<name>` is the body: 21 parts, 16 of them visible.
local function visualOf(entry)
	if not MercPlayers then return nil end
	local owner = entry.model:GetAttribute("RigOwner") or entry.name
	return MercPlayers:FindFirstChild("MercVisual_" .. tostring(owner))
end

-- The hitbox rig has NO HumanoidRootPart - that is on the R6 decoy, not here - so
-- anything reaching for one finds nil and quietly draws nothing. UpperTorso is
-- the root in this game.
local function rootOf(model)
	return model:FindFirstChild("UpperTorso")
		or model:FindFirstChild("LowerTorso")
		or model:FindFirstChild("Head")
end

-- Health lives on the Humanoid of the R6 decoy, which is the one thing that decoy
-- is good for. Measured: it moves (a live sample caught 13 HP mid-fight) and it
-- replicates for everybody.
local function healthOf(entry)
	local p = entry.player
	local char = p and p.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then return hum.Health, hum.MaxHealth end
	return nil, nil
end

-- The `RigState` attribute is gone as of the [NEW WEAPONS] update; this now
-- derives the same Alive/Dead word from the decoy Humanoid (and the InWorld flag)
-- so the status panel and the debug handle keep reading sensibly.
local function rigState(model)
	local uid = model:GetAttribute("OwnerUserId")
	local p
	if type(uid) == "number" then
		local ok, found = pcall(Players.GetPlayerByUserId, Players, uid)
		if ok then p = found end
	end
	local char = p and p.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		if hum.Health <= 0 or hum:GetState() == Enum.HumanoidStateType.Dead then
			return "Dead"
		end
		return "Alive"
	end
	if p and p:GetAttribute("InWorld") == false then return "Dead" end
	return "?"
end

-- Alive means the decoy agrees it is alive. The [NEW WEAPONS] update (2026-08-31)
-- REMOVED the `RigState` attribute this used to gate on - it now reads nil on
-- every rig, so the old `rigState(model) ~= "Alive"` check treated the whole
-- lobby as dead and killed aim, trigger and the ESP alive-filter in one go. The
-- live signal is now the R6 decoy's Humanoid (health + state) plus the owner's
-- `InWorld` flag, and on every body measured the three move together: a downed
-- merc reads HP 0 / state Dead / InWorld false, a live one HP>0 / Running / true.
-- Only an EXPLICIT dead signal hides a rig; a missing one still draws, which is
-- the safe way round (too much rather than hiding somebody who can kill you).
local function aliveOf(entry)
	local model = entry.model
	if not model or not model.Parent then return nil end
	local root = rootOf(model)
	if not root then return nil end
	local p = entry.player
	if p and p:GetAttribute("InWorld") == false then return nil end
	local hp, maxHp = healthOf(entry)
	if hp and hp <= 0 then return nil end
	local char = p and p.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum:GetState() == Enum.HumanoidStateType.Dead then return nil end
	return hp or 100, maxHp or 100, root
end

--------------------------------------------------------------------------------
-- hitboxes
--------------------------------------------------------------------------------
--
-- Measured on a live rig, all 15 parts Transparency 1 / CanQuery true /
-- CanCollide false / collision group `Map`:
--
--   Head          1.45 x 2.17 x 1.38      UpperTorso  2.73 x 3.01 x 2.13
--   LowerTorso    2.19 x 2.04 x 1.59      LeftUpperLeg 1.13 x 3.89 x 1.46
--   ...plus both arms, both hands, both lower legs and both feet.
--
-- The head is small - 1.45 wide against the torso's 2.73 - and it is still the
-- right default, because every firearm in the registry one-shots to it.

local HEAD_PARTS = { Head = true }

local function bodyPart(model)
	return model:FindFirstChild("UpperTorso")
		or model:FindFirstChild("LowerTorso")
		or model:FindFirstChild("Head")
end

local function headPart(model)
	return model:FindFirstChild("Head") or bodyPart(model)
end

local function centreOf()
	local vp = camera.ViewportSize
	return Vector2.new(vp.X / 2, vp.Y / 2)
end

local function targetPart(model)
	local want = CONFIG.aimPart
	if want == "Head" then return headPart(model) end
	if want == "Nearest" then
		local mid = centreOf()
		local best, bestD
		for _, part in ipairs({ headPart(model), bodyPart(model) }) do
			if part then
				local sp = camera:WorldToViewportPoint(part.Position)
				if sp.Z > 0 then
					local d = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
					if not bestD or d < bestD then best, bestD = part, d end
				end
			end
		end
		return best or bodyPart(model)
	end
	return bodyPart(model)
end

--------------------------------------------------------------------------------
-- line of sight
--------------------------------------------------------------------------------
--
-- The filter is the game's own, read out of `BulletController.Discharge`'s
-- upvalues: `buildExcludeList` walks Players:GetPlayers() and inserts each
-- Character - the R6 decoys - and nothing else. `Discharge` then sets NO
-- collision group on its RaycastParams, so the bullet runs on `Default`.
--
-- That single fact is what makes the clip-brush trap a non-issue here. The 91
-- `MapBarrier` parts and `MapCeiling` are Transparency 1 and CanCollide true -
-- textbook clip brushes - but they sit in collision group `Ignore`, and
-- `Default x Ignore` is FALSE. A default ray already walks through them.
--
-- What legitimately blocks: 492 `Collision` hulls, 70 `shelf_hitbox` parts, real
-- geometry, and corpses (`Default x Corpse` is true). All of those stop the
-- game's own bullet too, so the answer here is the answer a shot would get.

local excludeCache, excludeAt = {}, 0

local function excludeList()
	local now = os.clock()
	if now - excludeAt < 1 then return excludeCache end
	excludeAt = now
	local t = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local c = p.Character
		if c then t[#t + 1] = c end
	end
	-- Our own first-person body, which every ray would otherwise start inside.
	local pov = workspace:FindFirstChild("MercPOV")
	if pov then t[#t + 1] = pov end
	if MercPlayers then
		local mine = MercPlayers:FindFirstChild("MercHitboxes_" .. plr.Name)
		if mine then t[#t + 1] = mine end
		local vis = MercPlayers:FindFirstChild("MercVisual_" .. plr.Name)
		if vis then t[#t + 1] = vis end
	end
	for _, folderName in ipairs({ "_CosmeticProjectiles", "_CosmeticBulletHoles",
		"Ignore" }) do
		local f = workspace:FindFirstChild(folderName)
		if f then t[#t + 1] = f end
	end
	excludeCache = t
	return t
end

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.IgnoreWater = true

local function bulletRay(toPos)
	local origin = camera.CFrame.Position
	if CameraPOV and CameraPOV.GetEyePosition then
		local ok, eye = pcall(CameraPOV.GetEyePosition)
		if ok and typeof(eye) == "Vector3" then origin = eye end
	end
	local dir = toPos - origin
	if dir.Magnitude < 0.05 then return nil, origin end
	losParams.FilterDescendantsInstances = excludeList()
	return workspace:Raycast(origin, dir, losParams), origin
end

local function rigFromHit(inst)
	if not inst then return nil end
	local node = inst
	while node and node ~= workspace do
		if node.Parent == MercPlayers then return node end
		node = node.Parent
	end
	return nil
end

local function visibleTo(model, part)
	if not part then return false end
	local hit = bulletRay(part.Position)
	if not hit or not hit.Instance then return false end
	return hit.Instance:IsDescendantOf(model)
end

--------------------------------------------------------------------------------
-- our own weapon
--------------------------------------------------------------------------------
--
-- All READ from GunController.Weapon, which the client publishes live. Nothing
-- here is inferred from a fire rate and nothing here is written back.

local function myWeapon()
	if not GunCtl then return nil end
	local w = GunCtl.Weapon
	if type(w) ~= "table" then return nil end
	return w
end

local function weaponName()
	local w = myWeapon()
	if w and type(w.Name) == "string" then return w.Name end
	local attr = plr:GetAttribute("CurrentWeapon")
	if type(attr) == "string" then return attr end
	return "-"
end

local function myDef()
	return weaponDef(weaponName())
end

local function deployed()
	if plr:GetAttribute("Deployed") ~= true then return false end
	if plr:GetAttribute("PlayerMode") ~= "InGame" then return false end
	return true
end

-- The gun can fire when the client says so. `CanFire` is the client's own gate,
-- and it is false through the whole reload and the whole weapon switch.
local function shotReady()
	local w = myWeapon()
	if not w then return true end
	if w.IsEquipped ~= true then return false end
	if w.IsReloading == true then return false end
	if w.IsSwitching == true then return false end
	if type(w.MagAmmo) == "number" and w.MagAmmo <= 0 then return false end
	if w.CanFire == false then return false end
	return true
end

local function adsOn()
	local w = myWeapon()
	if w and w.IsAiming ~= nil then return w.IsAiming == true end
	if GunCtl and GunCtl.AimHeld ~= nil then return GunCtl.AimHeld == true end
	return false
end

-- The effective range of what is actually in your hands, so a distance marker
-- means something rather than being a constant. Measured spread: 150 for the
-- BenelliM4 up to 600 for the M1ASOCOM.
local function weaponRange()
	local def = myDef()
	if def and type(def.Range) == "number" and def.Range > 0 then return def.Range end
	return 400
end

-- What a hit would actually do, from the game's own table. `BodyDamage.Multiplier`
-- is the function the shot uses, so the head figure here is the head figure the
-- server computes rather than an assumption about x4.
local function damageFor(partName, dist)
	local def = myDef()
	if not def then return nil, nil end
	local base = def.Damage
	if BodyDamage and BodyDamage.BaseDamageAtDistance then
		local ok, d = pcall(BodyDamage.BaseDamageAtDistance, def, dist or 0)
		if ok and type(d) == "number" then base = d end
	end
	local mult = 1
	if BodyDamage and BodyDamage.Multiplier then
		local ok, m = pcall(BodyDamage.Multiplier, def, partName)
		if ok and type(m) == "number" then mult = m end
	end
	if mult == 1 and partName == "Head" and type(def.HeadshotMult) == "number" then
		mult = def.HeadshotMult
	end
	return base * mult, base
end

--------------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------------

local FONTS = { UI = 0, System = 1, Plex = 2, Monospace = 3 }
local FONTLIST = { "System", "UI", "Plex", "Monospace" }

local function fontId()
	local id = FONTS[CONFIG.textFont]
	if id == nil then return 1 end
	if Drawing and Drawing.Fonts then
		local named = Drawing.Fonts[CONFIG.textFont]
		if named ~= nil then return named end
	end
	return id
end

local drawn = {}
local pool  = {}

-- A previous run's Drawing objects survive a re-execute exactly like a loop does.
-- The generation guard stops the LOOP; only walking the stored pool clears the
-- PIXELS.
if _G.__TTK_POOL then
	for _, obj in ipairs(_G.__TTK_POOL) do pcall(function() obj:Remove() end) end
end
_G.__TTK_POOL = pool

local function make(kind, props)
	local obj = Drawing.new(kind)
	obj.Visible = false
	for k, v in pairs(props or {}) do obj[k] = v end
	table.insert(pool, obj)
	return obj
end

-- The rig's own part names. There is no HumanoidRootPart and no Torso, so a
-- generic R15 bone list copied from another game draws about half of this.
local BONES = {
	{ "Head", "UpperTorso" },
	{ "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" },
	{ "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" },
	{ "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" },
	{ "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" },
	{ "RightLowerLeg", "RightFoot" },
}

local HITBOX_PARTS = { "Head", "UpperTorso", "LowerTorso",
	"LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
	"RightUpperLeg", "RightLowerLeg", "RightFoot" }

-- Keyed by the rig MODEL rather than by a Player. Rigs are created and destroyed
-- on every respawn while the Player object stays, so a Players-keyed pool would
-- keep drawing the last frame of a body that is gone.
--
-- ...and because they are destroyed on every respawn, a set that is merely
-- FORGOTTEN when its rig goes away leaks 37 C-side Drawing allocations per death.
-- Measured on a live match: 155 orphaned objects inside a few minutes, against 74
-- actually in use. So a dead set goes on a free list and the next rig to appear
-- takes it, which caps the pool at the peak number of simultaneous bodies instead
-- of the total number ever seen.
local spare = {}

local function objectsFor(model)
	local set = drawn[model]
	if set then return set end
	set = table.remove(spare)
	if set then
		drawn[model] = set
		return set
	end
	set = {
		outline = make("Square", { Thickness = 3, Filled = false, ZIndex = 1,
			Color = COLOUR.black, Transparency = 0.6 }),
		box     = make("Square", { Thickness = 1, Filled = false, ZIndex = 2 }),
		fill    = make("Square", { Filled = true, ZIndex = 0, Transparency = 0.18 }),
		hpBg    = make("Square", { Filled = true, ZIndex = 1, Color = COLOUR.black,
			Transparency = 0.6 }),
		hp      = make("Square", { Filled = true, ZIndex = 2 }),
		name    = make("Text", { Size = 13, Center = true, Outline = true,
			Font = 1, Color = COLOUR.text, ZIndex = 3 }),
		info    = make("Text", { Size = 12, Center = true, Outline = true,
			Font = 1, Color = COLOUR.text, ZIndex = 3 }),
		tracer  = make("Line", { Thickness = 1, ZIndex = 1 }),
		head    = make("Circle", { Thickness = 1, Filled = false, NumSides = 14,
			ZIndex = 3 }),
		bones   = {},
		hitbox  = {},
	}
	for i = 1, #BONES do
		set.bones[i] = make("Line", { Thickness = 1, ZIndex = 2 })
	end
	for i = 1, #HITBOX_PARTS do
		set.hitbox[i] = make("Square", { Thickness = 1, Filled = false, ZIndex = 2,
			Transparency = 0.5 })
	end
	drawn[model] = set
	return set
end

local function hideSet(set)
	set.outline.Visible = false
	set.box.Visible     = false
	set.fill.Visible    = false
	set.hpBg.Visible    = false
	set.hp.Visible      = false
	set.name.Visible    = false
	set.info.Visible    = false
	set.tracer.Visible  = false
	set.head.Visible    = false
	for _, line in ipairs(set.bones) do line.Visible = false end
	for _, sq in ipairs(set.hitbox) do sq.Visible = false end
end

local function hideAll()
	for _, set in pairs(drawn) do hideSet(set) end
end

--------------------------------------------------------------------------------
-- chams
--------------------------------------------------------------------------------
--
-- A Drawing lives outside the DataModel and cannot fail this way; a Highlight is
-- a real Instance and can. Deagle Arena lost its ENTIRE render pass to this - a
-- throw from the middle of the per-target loop stopped the box, the name and the
-- distance for every target after the first, and it was reported as "the ESP does
-- not find all players". So every instance touch below is guarded, including the
-- freshness checks, and a failure disables the chams and SAYS SO rather than
-- taking the drawings with it.
--
-- The candidate list is built by APPENDING: `{ (gethui and gethui()) or nil,
-- CoreGui }` is the nil-hole trap - on an executor with no gethui that table is
-- `{nil, CoreGui}` and ipairs stops at the hole, so CoreGui is never tried.

local chamsFolder = nil
local chamsBroken = nil     -- kept only so old reads stay valid; never set now
local chamsReason = nil     -- why the last attempt failed, for the panel
local chamsFails, chamsNextTry = 0, 0

-- NEVER LATCH THIS PERMANENTLY. That was two separate bugs, both reported.
--
-- First version gave up on the FIRST failure. The very first Instance touch of a
-- run throws "The current thread cannot access 'Instance' (lacking capability
-- Plugin)" - the known once-per-run identity hiccup - so the chams toggle sat
-- there doing nothing for the whole session while creating a Highlight by hand
-- seconds later worked every time. Reported as "chams do not work".
--
-- Second version allowed five tries and then latched. That is still wrong,
-- because a MAP OR LOBBY CHANGE throws on every Instance touch for as long as it
-- lasts: five failures inside a couple of seconds, and the chams were dead for
-- the rest of the session again. Reported as "in a new lobby the chams are gone
-- again".
--
-- So there is no permanent state any more. The failure reason is kept for the
-- panel to show, the retry backs off to a ten second ceiling, and it never stops
-- trying. One Instance.new attempt every ten seconds costs nothing, and an
-- executor that genuinely cannot do it simply keeps saying so.
local function chamsGiveUp(err)
	chamsFails = chamsFails + 1
	local wait = (chamsFails <= 2) and 0.35 or math.min(2 ^ (chamsFails - 2), 10)
	chamsNextTry = os.clock() + wait
	chamsReason = tostring(err):sub(1, 60)
end

-- A READ THAT THROWS IS NOT PROOF THE FOLDER IS GONE, and treating it as such is
-- what destroyed the chams over and over.
--
-- `.Parent` on an instance living under `gethui()` can throw on its own - the
-- comment two functions down already said so. The first version returned false
-- when the pcall failed, chamsRoot then took that as "rebuild", and rebuild
-- DESTROYED the folder every other frame together with every Highlight inside
-- it. From the outside: the chams keep disappearing, and the frame spikes from
-- tearing down and re-creating instances every frame made the aim feel worse
-- while it was happening. Both were the same defect.
--
-- So a throw means UNKNOWN, and unknown keeps what we have.
local function chamsAlive()
	if chamsFolder == nil then return false end
	local ok, alive = pcall(function() return chamsFolder.Parent ~= nil end)
	if not ok then return true end       -- cannot tell; do not tear anything down
	return alive == true
end

local function chamsRoot()
	if chamsAlive() then return chamsFolder end
	if os.clock() < chamsNextTry then return nil end

	local roots = {}
	local ok, hidden = pcall(function() return gethui and gethui() or nil end)
	if ok and hidden then roots[#roots + 1] = hidden end
	roots[#roots + 1] = CoreGui

	for _, root in ipairs(roots) do
		local made = nil
		pcall(function()
			-- REUSE, never rebuild. A stale folder from a PREVIOUS run is cleared
			-- once, at load, by the teardown block further up - not here, where
			-- doing it means throwing away the container the current run is using
			-- and every Highlight parented to it.
			local previous = root:FindFirstChild("SeluxTTKChams")
			if previous then made = previous return end
			local folder = Instance.new("Folder")
			folder.Name = "SeluxTTKChams"
			folder.Parent = root
			made = folder
		end)
		if made then
			chamsFolder = made
			chamsBroken = nil
			return chamsFolder
		end
	end

	chamsGiveUp("no container this executor will accept")
	return nil
end

-- Clear a PREVIOUS run's container exactly once, here, before anything uses one.
-- The old run's Highlights are orphaned - its render loop is dead - so they would
-- otherwise stay on screen with nothing updating them, which is the same class of
-- leak the Drawing pool has.
for _, root in ipairs({ (function()
	local ok, h = pcall(function() return gethui and gethui() or nil end)
	return ok and h or nil
end)(), CoreGui }) do
	if root then
		pcall(function()
			local previous = root:FindFirstChild("SeluxTTKChams")
			if previous then previous:Destroy() end
		end)
	end
end

pcall(chamsRoot)

local highlights = {}

local CHAM_STYLES = {
	["Fill"]         = { fill = 0.35, out = 0,    depth = "AlwaysOnTop" },
	["Solid"]        = { fill = 0,    out = 0,    depth = "AlwaysOnTop" },
	["Outline"]      = { fill = 1,    out = 0,    depth = "AlwaysOnTop" },
	["Glow"]         = { fill = 0.78, out = 0.15, depth = "AlwaysOnTop", boost = 1.6 },
	["Ghost"]        = { fill = 0.6,  out = 0.4,  depth = "AlwaysOnTop", boost = 0.55 },
	["Wall only"]    = { fill = 0.35, out = 0,    depth = "Occluded" },
	["Wall outline"] = { fill = 1,    out = 0,    depth = "Occluded" },
}
local CHAM_LIST = { "Fill", "Solid", "Outline", "Glow", "Ghost",
	"Wall only", "Wall outline" }

local function chamFor(model)
	local hl = highlights[model]
	if hl then
		local ok, alive = pcall(function() return hl.Parent ~= nil end)
		if ok and alive then return hl end
	end
	if chamsBroken then return nil end
	if os.clock() < chamsNextTry then return nil end
	local folder = chamsRoot()
	if not folder then return nil end
	local made = nil
	local ok, err = pcall(function()
		local h = Instance.new("Highlight")
		h.FillTransparency = 0.35
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Parent = folder
		made = h
	end)
	if not ok or not made then
		chamsGiveUp(err)
		return nil
	end
	chamsFails, chamsReason = 0, nil
	highlights[model] = made
	return made
end

local function applyCham(hl, base)
	local style = CHAM_STYLES[CONFIG.chamStyle] or CHAM_STYLES["Fill"]
	local col = base
	if CONFIG.chamRainbow then
		col = Color3.fromHSV((os.clock() * 0.25) % 1, 0.85, 1)
	elseif CONFIG.colChamOwn then
		col = CONFIG.colCham
	end
	if style.boost then
		local h, s, v = Color3.toHSV(col)
		col = Color3.fromHSV(h, math.clamp(s * (style.boost > 1 and 0.75 or 1), 0, 1),
			math.clamp(v * style.boost, 0, 1))
	end
	hl.FillTransparency = style.fill
	hl.OutlineTransparency = style.out
	hl.DepthMode = Enum.HighlightDepthMode[style.depth]
	hl.FillColor = col
	hl.OutlineColor = col
	hl.Enabled = true
end

local function clearChams()
	for _, hl in pairs(highlights) do
		pcall(function()
			if hl and hl.Parent then hl.Adornee = nil hl.Enabled = false end
		end)
	end
end

--------------------------------------------------------------------------------
-- static overlays
--------------------------------------------------------------------------------

local fovCircle = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Transparency = 0.5, ZIndex = 1 })
local trigCircle = make("Circle", { Thickness = 1, NumSides = 32, Filled = false,
	Color = Color3.fromRGB(255, 210, 90), Transparency = 0.45, ZIndex = 1 })

local crossLines = {}
for i = 1, 4 do
	crossLines[i] = make("Line", { Thickness = 1, ZIndex = 4 })
end
local crossDot = make("Circle", { Filled = true, NumSides = 8, Radius = 1, ZIndex = 4 })

local ammoBg = make("Square", { Filled = true, ZIndex = 4, Color = COLOUR.black,
	Transparency = 0.5 })
local ammoBar = make("Square", { Filled = true, ZIndex = 5 })

--------------------------------------------------------------------------------
-- the render pass
--------------------------------------------------------------------------------

local function drawCrosshair(mid)
	local on = CONFIG.crosshair
	for i = 1, 4 do crossLines[i].Visible = on end
	crossDot.Visible = on and CONFIG.crossDot
	if not on then return end
	local g, s, t = CONFIG.crossGap, CONFIG.crossSize, CONFIG.crossThick
	local dirs = {
		{ Vector2.new(0, -g), Vector2.new(0, -g - s) },
		{ Vector2.new(0,  g), Vector2.new(0,  g + s) },
		{ Vector2.new(-g, 0), Vector2.new(-g - s, 0) },
		{ Vector2.new( g, 0), Vector2.new( g + s, 0) },
	}
	for i = 1, 4 do
		local line = crossLines[i]
		line.From = mid + dirs[i][1]
		line.To   = mid + dirs[i][2]
		line.Thickness = t
		line.Color = CONFIG.colCross
	end
	if crossDot.Visible then
		crossDot.Position = mid
		crossDot.Radius = math.max(1, t)
		crossDot.Color = CONFIG.colCross
	end
end

-- The magazine, read off the weapon rather than counted. A reload shows as the
-- bar refilling because MagAmmo is the client's own live field.
local function drawAmmo(mid)
	local w = myWeapon()
	local show = CONFIG.ammoBar and w ~= nil and w.IsEquipped == true
		and type(w.MagAmmo) == "number" and type(w.MaxMagSize) == "number"
		and w.MaxMagSize > 0
	ammoBg.Visible = show
	ammoBar.Visible = show
	if not show then return end
	local frac = math.clamp(w.MagAmmo / w.MaxMagSize, 0, 1)
	local width, height = 120, 4
	local x, y = mid.X - width / 2, mid.Y + 26
	ammoBg.Position = Vector2.new(x, y)
	ammoBg.Size     = Vector2.new(width, height)
	ammoBar.Position = Vector2.new(x, y)
	ammoBar.Size     = Vector2.new(width * frac, height)
	if w.IsReloading == true then
		ammoBar.Color = Color3.fromRGB(255, 170, 60)
	else
		ammoBar.Color = COLOUR.hpBad:Lerp(COLOUR.hpGood, frac)
	end
end

local function screenRect(part)
	local size = part.Size
	local cf = part.CFrame
	local minX, minY, maxX, maxY
	local anyBehind = false
	for dx = -1, 1, 2 do
		for dy = -1, 1, 2 do
			for dz = -1, 1, 2 do
				local corner = cf * Vector3.new(size.X / 2 * dx, size.Y / 2 * dy,
					size.Z / 2 * dz)
				local sp = camera:WorldToViewportPoint(corner)
				if sp.Z <= 0 then anyBehind = true end
				minX = minX and math.min(minX, sp.X) or sp.X
				maxX = maxX and math.max(maxX, sp.X) or sp.X
				minY = minY and math.min(minY, sp.Y) or sp.Y
				maxY = maxY and math.max(maxY, sp.Y) or sp.Y
			end
		end
	end
	if anyBehind then return nil end
	return minX, minY, maxX - minX, maxY - minY
end

local function renderPass()
	if _G.__TTK ~= GEN then return end

	local mid = centreOf()

	fovCircle.Visible = CONFIG.aim and CONFIG.aimCircle
	if fovCircle.Visible then
		fovCircle.Position = mid
		fovCircle.Radius = CONFIG.aimFov
		fovCircle.Color = CONFIG.colFov
	end
	trigCircle.Visible = CONFIG.trig and CONFIG.trigFov > 0
	if trigCircle.Visible then
		trigCircle.Position = mid
		trigCircle.Radius = CONFIG.trigFov
	end

	drawCrosshair(mid)
	drawAmmo(mid)

	if not anyDrawing() then
		hideAll()
		clearChams()
		STATE.targets, STATE.enemies, STATE.friends = 0, 0, 0
		return
	end

	local vp = camera.ViewportSize
	local camPos = camera.CFrame.Position
	local count, foes, friends = 0, 0, 0
	local face = fontId()
	local seenModels = {}
	local range = weaponRange()

	for _, entry in ipairs(combatants()) do
		local model = entry.model
		seenModels[model] = true
		local set = objectsFor(model)
		local hp, maxHp, root = aliveOf(entry)
		local dead = hp == nil

		if dead and CONFIG.deadESP and model.Parent then
			local r = rootOf(model)
			if r then hp, maxHp, root = 0, 100, r end
		end

		if not root then
			hideSet(set)
			local hl = highlights[model]
			if hl then pcall(function() hl.Enabled = false hl.Adornee = nil end) end
		else
			local dist = (camPos - root.Position).Magnitude
			if dist > CONFIG.maxDist then
				hideSet(set)
				local hl = highlights[model]
				if hl then pcall(function() hl.Enabled = false hl.Adornee = nil end) end
			else
				local aimAt = bodyPart(model)
				local seen = true
				if CONFIG.visCheck then
					seen = visibleTo(model, headPart(model)) or visibleTo(model, aimAt)
				end

				local base = entry.foe and CONFIG.colEnemy or CONFIG.colFriend
				if dead then base = CONFIG.colDead end
				local col = seen and base or dimmed(base)
				local outOfRange = dist > range

				-- Never Model:GetBoundingBox(). The honest box is the pair of points
				-- it actually needs - the top of the head and the bottom of the lower
				-- foot. Projected, the distance between them IS the on-screen height,
				-- so it scales with range for free and follows a crouch exactly.
				local head = model:FindFirstChild("Head")
				local lf = model:FindFirstChild("LeftFoot")
				local rf = model:FindFirstChild("RightFoot")
				local topPos = head
					and (head.Position + Vector3.new(0, head.Size.Y / 2 + 0.35, 0))
					or (root.Position + Vector3.new(0, 3, 0))
				local low = lf
				if lf and rf then low = (lf.Position.Y <= rf.Position.Y) and lf or rf
				elseif rf then low = rf end
				local botPos = low
					and (low.Position - Vector3.new(0, low.Size.Y / 2, 0))
					or (root.Position - Vector3.new(0, 3, 0))

				local sTop = camera:WorldToViewportPoint(topPos)
				local sBot = camera:WorldToViewportPoint(botPos)
				-- sp.Z <= 0 means the point is BEHIND the camera; the X/Y reported
				-- there is mirrored nonsense and drawing it puts a box on the wrong
				-- side of the screen for somebody standing behind you.
				local behind = sTop.Z <= 0 or sBot.Z <= 0
				local h = math.max(math.abs(sBot.Y - sTop.Y), 4)
				local w = h * 0.52
				local cx = (sTop.X + sBot.X) / 2
				local minX, minY = cx - w / 2, math.min(sTop.Y, sBot.Y)
				local maxX, maxY = minX + w, minY + h

				local onScreen = not behind
					and maxX > 0 and minX < vp.X and maxY > 0 and minY < vp.Y

				if not onScreen then
					hideSet(set)
					local hl = highlights[model]
					if hl then
						if CONFIG.chams then
							-- MercVisual_<name> is replaced on every respawn while
							-- MercHitboxes_<name> survives, so an Adornee set once goes
							-- stale and the cham silently stops drawing for that player.
							local skin = visualOf(entry)
							if skin then pcall(function() hl.Adornee = skin end) end
						else
							pcall(function() hl.Enabled = false end)
						end
					end
				else
					count = count + 1
					if entry.foe then foes = foes + 1 else friends = friends + 1 end

					local pos = Vector2.new(minX, minY)
					local siz = Vector2.new(w, h)

					set.box.Visible = CONFIG.box
					set.outline.Visible = CONFIG.box
					if CONFIG.box then
						set.box.Position = pos      set.box.Size = siz
						set.box.Color = col
						set.outline.Position = pos  set.outline.Size = siz
					end

					set.fill.Visible = CONFIG.box and CONFIG.boxFilled
					if set.fill.Visible then
						set.fill.Position = pos  set.fill.Size = siz
						set.fill.Color = col
					end

					set.hpBg.Visible = CONFIG.health and hp ~= nil
					set.hp.Visible   = set.hpBg.Visible
					if set.hpBg.Visible then
						local frac = math.clamp(hp / math.max(maxHp or 100, 1), 0, 1)
						set.hpBg.Position = Vector2.new(minX - 6, minY)
						set.hpBg.Size     = Vector2.new(3, h)
						set.hp.Position   = Vector2.new(minX - 6, minY + h * (1 - frac))
						set.hp.Size       = Vector2.new(3, h * frac)
						set.hp.Color      = COLOUR.hpBad:Lerp(COLOUR.hpGood, frac)
					end

					local ts = CONFIG.textSize
					if CONFIG.textShrink then
						ts = math.clamp(h * 0.22, math.max(12, CONFIG.textSize - 2),
							CONFIG.textSize)
					end
					ts = math.floor(ts + 0.5)

					set.name.Visible = CONFIG.name
					if CONFIG.name then
						local label = entry.name
						if CONFIG.teamTag and entry.player then
							label = "[" .. teamName(entry.player):sub(1, 5) .. "] " .. label
						end
						if dead then label = label .. " +" end
						set.name.Size = ts
						set.name.Font = face
						set.name.Outline = CONFIG.textOutline
						set.name.Position = Vector2.new(minX + w / 2, minY - (ts + 3))
						set.name.Text = label
						set.name.Color = col
					end

					local bits = {}
					if CONFIG.weaponTag and entry.player then
						local wn = entry.player:GetAttribute("CurrentWeapon")
						if type(wn) == "string" and wn ~= "" then
							local def = WEAPONS[wn]
							local shown = (type(def) == "table" and type(def.DisplayName)
								== "string") and def.DisplayName or wn
							table.insert(bits, shown)
						end
					end
					if CONFIG.distance then
						table.insert(bits, string.format("%dm%s", math.floor(dist),
							(outOfRange and CONFIG.rangeTag) and " !" or ""))
					end
					if CONFIG.health and hp then
						table.insert(bits, string.format("%dhp", math.floor(hp)))
					end
					if CONFIG.kdTag and entry.player then
						table.insert(bits, string.format("%d/%d",
							tonumber(entry.player:GetAttribute("Kills")) or 0,
							tonumber(entry.player:GetAttribute("Deaths")) or 0))
					end
					set.info.Visible = #bits > 0
					if set.info.Visible then
						set.info.Size = math.max(12, ts - 1)
						set.info.Font = face
						set.info.Outline = CONFIG.textOutline
						set.info.Position = Vector2.new(minX + w / 2, maxY + 2)
						set.info.Text = table.concat(bits, "  ")
						set.info.Color = col
					end

					set.tracer.Visible = CONFIG.tracer
					if CONFIG.tracer then
						set.tracer.From = Vector2.new(vp.X / 2, vp.Y)
						set.tracer.To   = Vector2.new(minX + w / 2, maxY)
						set.tracer.Color = col
					end

					set.head.Visible = CONFIG.headDot and head ~= nil
					if set.head.Visible then
						local sp = camera:WorldToViewportPoint(head.Position)
						set.head.Position = Vector2.new(sp.X, sp.Y)
						set.head.Radius = math.max(1.5, h * 0.075)
						set.head.Color = col
					end

					-- The real rig, drawn as it is. Worth having on this game because
					-- the parts are invisible and their sizes are the whole reason the
					-- head is the right place to aim.
					for i, partName in ipairs(HITBOX_PARTS) do
						local sq = set.hitbox[i]
						sq.Visible = false
						if CONFIG.hitboxDraw then
							local part = model:FindFirstChild(partName)
							if part then
								local x, y, bw, bh = screenRect(part)
								if x then
									sq.Visible = true
									sq.Position = Vector2.new(x, y)
									sq.Size = Vector2.new(bw, bh)
									sq.Color = CONFIG.colHitbox
								end
							end
						end
					end

					if CONFIG.skeleton then
						for i, bone in ipairs(BONES) do
							local a = model:FindFirstChild(bone[1])
							local b = model:FindFirstChild(bone[2])
							local line = set.bones[i]
							if a and b then
								local pa = camera:WorldToViewportPoint(a.Position)
								local pb = camera:WorldToViewportPoint(b.Position)
								if pa.Z > 0 and pb.Z > 0 then
									line.Visible = true
									line.From = Vector2.new(pa.X, pa.Y)
									line.To   = Vector2.new(pb.X, pb.Y)
									line.Color = col
								else
									line.Visible = false
								end
							else
								line.Visible = false
							end
						end
					else
						for _, line in ipairs(set.bones) do line.Visible = false end
					end

					-- Guarded twice on purpose: chamFor already returns nil instead of
					-- throwing, and the property writes are wrapped as well, because an
					-- Adornee whose rig was destroyed between the two lines is a second
					-- way to lose the pass.
					-- Adorned to the VISUAL rig, never to the hitbox rig - see visualOf.
					-- A Highlight on 15 fully transparent parts draws nothing at all.
					if CONFIG.chams and not chamsBroken then
						local skin = visualOf(entry)
						local hl = skin and chamFor(model) or nil
						if hl then
							pcall(function()
								hl.Adornee = skin
								applyCham(hl, base)
							end)
						end
					else
						local hl = highlights[model]
						if hl then
							pcall(function() hl.Enabled = false hl.Adornee = nil end)
						end
					end
				end
			end
		end
	end

	-- Rigs are destroyed and rebuilt on every respawn, so a pool keyed by model
	-- would grow without bound and keep drawing a body that is gone. The set is
	-- handed to the free list rather than dropped - see objectsFor.
	for model, set in pairs(drawn) do
		if not seenModels[model] or not model.Parent then
			hideSet(set)
			if not model.Parent then
				local hl = highlights[model]
				if hl then pcall(function() hl:Destroy() end) highlights[model] = nil end
				drawn[model] = nil
				spare[#spare + 1] = set
			end
		end
	end

	STATE.targets, STATE.enemies, STATE.friends = count, foes, friends
end

--------------------------------------------------------------------------------
-- key binding
--------------------------------------------------------------------------------

local function keyDisplay(name)
	local n = tostring(name)
	local side = n:match("^MouseButton(%d)$")
	if side then return "MOUSE " .. side end
	return string.upper(n)
end

-- Indexing a Roblox Enum with a name it does not have THROWS rather than
-- returning nil, so both lookups are wrapped and the result cached.
local keyCache = {}

local function resolveKey(name)
	local hit = keyCache[name]
	if hit ~= nil then return hit end
	local entry = false
	if name:sub(1, 11) == "MouseButton" then
		local ok, value = pcall(function() return Enum.UserInputType[name] end)
		if ok and value then entry = { mouse = value } end
	else
		local ok, value = pcall(function() return Enum.KeyCode[name] end)
		if ok and value then entry = { key = value } end
	end
	keyCache[name] = entry
	return entry
end

local function keyHeld(name)
	if not name or name == "" then return false end
	local spec = resolveKey(name)
	if not spec then return false end
	if spec.mouse then return UserInputService:IsMouseButtonPressed(spec.mouse) end
	return UserInputService:IsKeyDown(spec.key)
end

local capturing = nil
local armedGuard = false

-- The click that ARMS the recorder must never become the binding. Roblox fires
-- MouseButton1Click on the RELEASE, so the recorder is armed one event before the
-- release of its own arming click arrives. The guard does not care about event
-- order: accept nothing until the left button is observed physically UP.
local function arm(fn)
	capturing = fn
	armedGuard = true
	task.spawn(function()
		while UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) do
			task.wait()
		end
		task.wait(0.06)
		armedGuard = false
	end)
end

local function capture(name)
	local fn = capturing
	if not fn then return end
	capturing = nil
	armedGuard = false
	STATE.lastKey = tostring(name)
	fn(name)
end

UserInputService.InputBegan:Connect(function(input)
	if _G.__TTK ~= GEN or not capturing or armedGuard then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if input.KeyCode == Enum.KeyCode.Escape then capture(nil) return end
	if input.KeyCode == Enum.KeyCode.Unknown then return end
	capture(input.KeyCode.Name)
end)

UserInputService.InputEnded:Connect(function(input)
	if _G.__TTK ~= GEN or not capturing or armedGuard then return end
	local name = input.UserInputType.Name
	if name:sub(1, 11) ~= "MouseButton" then return end
	capture(name)
end)

local function firing()
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
end

local panicHandlers = {}

UserInputService.InputBegan:Connect(function(input, processed)
	if _G.__TTK ~= GEN or processed or capturing then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local spec = resolveKey(CONFIG.panicKey)
	if not spec or not spec.key or input.KeyCode ~= spec.key then return end
	CONFIG.aim, CONFIG.trig, CONFIG.aimFire, CONFIG.rcs = false, false, false, false
	for _, fn in ipairs(panicHandlers) do pcall(fn) end
	note("PANIC - aim, trigger, auto fire and recoil control off")
end)

--------------------------------------------------------------------------------
-- the humaniser
--------------------------------------------------------------------------------

local PAUSE = { reason = "", until_ = 0 }

local function pauseFor(ms, reason)
	local until_ = os.clock() + ms / 1000
	if until_ > PAUSE.until_ then
		PAUSE.until_ = until_
		PAUSE.reason = reason
	end
end

local function humanPaused()
	if PAUSE.until_ > os.clock() then return PAUSE.reason end
	return nil
end

-- Box-Muller. A uniform random reaction time is itself a pattern - real reaction
-- times are a bell around a mean with a long right tail, never a flat band.
local function gauss(mean, sd)
	local u1 = math.random()
	local u2 = math.random()
	if u1 < 1e-9 then u1 = 1e-9 end
	return mean + math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2) * sd
end

local engagement = nil

local function newEngagement(model, name)
	-- Written as an if rather than `CONFIG.hum and roll or true`, which is the
	-- and/or trap: a failed roll is `false`, and `false or true` is true, so the
	-- head share would silently be 100% wherever the slider sat.
	local head = true
	if CONFIG.hum then head = math.random(100) <= CONFIG.humHeadPct end
	engagement = {
		model    = model,
		name     = name,
		t0       = os.clock(),
		seed     = math.random() * 1000,
		ox       = (math.random() - 0.5) * 2,
		oy       = (math.random() - 0.5) * 2,
		oz       = (math.random() - 0.5) * 2,
		windup   = CONFIG.hum
			and math.random(math.min(CONFIG.humWindupMin, CONFIG.humWindupMax),
				math.max(CONFIG.humWindupMin, CONFIG.humWindupMax)) / 1000
			or 0,
		head     = head,
		over     = CONFIG.hum and (math.random(100) <= CONFIG.humOvershoot),
		breakTil = 0,
		lockUntil = os.clock() + CONFIG.humSwitchMs / 1000,
		rerollAt  = os.clock() + CONFIG.humRerollMs / 1000,
	}
	return engagement
end

local function rerollOffset()
	if not engagement then return end
	if not CONFIG.hum or CONFIG.humRerollMs <= 0 then return end
	if os.clock() < engagement.rerollAt then return end
	engagement.ox = (math.random() - 0.5) * 2
	engagement.oy = (math.random() - 0.5) * 2
	engagement.oz = (math.random() - 0.5) * 2
	engagement.rerollAt = os.clock() + CONFIG.humRerollMs / 1000
end

local function endEngagement()
	if engagement and CONFIG.hum and CONFIG.humCooldown > 0 then
		pauseFor(CONFIG.humCooldown, "cooldown")
	end
	engagement = nil
end

-- The aim point. Not the centre of the part: an offset that is constant for this
-- engagement, plus a slow continuous drift. math.noise rather than math.random so
-- the drift is smooth - random per frame is a vibration, which reads as less
-- human than no jitter at all.
--
-- The head here is 1.45 x 2.17 x 1.38, which is small, so the offset percentage
-- is a much tighter box than it would be on a torso. That is the right behaviour:
-- it should never push the aim off the part it chose.
local function humanAimPoint(part, dist)
	local pos = part.Position
	if not CONFIG.hum or not engagement then return pos end

	local size = part.Size
	local k = CONFIG.humOffsetPct / 100 * 0.5
	pos = pos + Vector3.new(engagement.ox * size.X * k,
		engagement.oy * size.Y * k,
		engagement.oz * size.Z * k)

	if CONFIG.humJitter > 0 then
		local t = os.clock() * CONFIG.humJitterHz
		local s = engagement.seed
		local amp = CONFIG.humJitter * math.clamp(dist / 100, 0.25, 4)
		pos = pos + Vector3.new(
			math.noise(t, s) * amp,
			math.noise(t, s + 17.3) * amp * 0.6,
			math.noise(t, s + 41.7) * amp)
	end
	return pos
end

--------------------------------------------------------------------------------
-- aim assist
--------------------------------------------------------------------------------

local lastKillAt = 0
local stickyModel = nil
local aimWroteView = false

-- DEAD TIME, AND WHY THE ASSIST SHOOK.
--
-- `mousemoverel` does not move the view on the frame it is called - the game
-- consumes it on the next one. So the error measured this frame STILL CONTAINS
-- everything that was already requested last frame, and asking for it again puts
-- two or three copies of the same correction in flight. The view then sails past
-- the target, the error flips sign, and the whole thing oscillates. Reported as
-- "it jerks back and forth really hard without me doing anything".
--
-- The weapon path makes it worse, because the gun follows the camera through a
-- spring: that is a SECOND lag on top of the input one.
--
-- So: remember what has been asked for and not yet seen, subtract it from the
-- raw error, and only ask for the difference.
-- EXACTLY ONE FRAME, NOT AN ACCUMULATOR.
--
-- The first version banked every request and drew it down by however far the
-- camera was seen to move. That stalls: the observed movement carries the
-- PLAYER's mouse as well as ours, the pixel conversion is only an estimate, and
-- anything the game did not deliver stayed on the books forever - so the
-- correction was permanently reduced by a debt that could never be repaid, and
-- the aim sat several degrees off the target without ever closing.
--
-- What is actually in flight is one frame's request, because that is when
-- mousemoverel lands. Remembering just that is enough to stop the double-request
-- oscillation and cannot deadlock.
local pendYaw, pendPitch = 0, 0

local function clearPending()
	pendYaw, pendPitch = 0, 0
end

local function panelOpen()
	local win = _G.__TTK_WIN
	local root = win and win.root
	if not root or not root.Parent then return false end
	local ok, vis = pcall(function() return root.Visible end)
	return ok and vis == true
end

local function assistBlocked()
	local why = humanPaused()
	if why then return why end
	if CONFIG.hum and CONFIG.humPanelPause and panelOpen() then return "panel open" end
	return nil
end

local function aimActive()
	if not CONFIG.aim then return false end
	if CONFIG.aimActive == "Always" then return true end
	if CONFIG.aimActive == "While firing" then return firing() end
	return keyHeld(CONFIG.aimKey)
end

local function adsGate(mode)
	if mode == "Always" then return true end
	local on = adsOn()
	if mode == "Aiming only" then return on end
	return not on
end

local function movingFrac()
	local model = MercPlayers
		and MercPlayers:FindFirstChild("MercHitboxes_" .. plr.Name)
	local root = model and rootOf(model)
	if not root then
		local char = plr.Character
		root = char and char:FindFirstChild("HumanoidRootPart")
	end
	if not root then return 0 end
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	return math.clamp(speed / 20, 0, 1)
end

local function pickTarget()
	local fov = CONFIG.aimFov
	-- Tracking as well while sprinting as while standing still is a tell in its
	-- own right, so the window narrows with how fast you are actually moving.
	if CONFIG.hum and CONFIG.humMoveFov < 100 then
		local frac = movingFrac()
		fov = fov * (1 - frac * (1 - CONFIG.humMoveFov / 100))
	end
	local mid = centreOf()
	local camPos = camera.CFrame.Position
	local best, bestScore

	for _, entry in ipairs(combatants()) do
		if entry.foe then
			local hp, _, root = aliveOf(entry)
			if hp then
				local part = targetPart(entry.model)
				local dist = (camPos - root.Position).Magnitude
				if part and dist <= CONFIG.aimMaxDist then
					local sp = camera:WorldToViewportPoint(part.Position)
					if sp.Z > 0 then
						local px = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
						if px <= fov then
							if (not CONFIG.aimVisible) or visibleTo(entry.model, part) then
								local score
								if CONFIG.aimPick == "Closest" then score = dist
								elseif CONFIG.aimPick == "Lowest HP" then score = hp
								else score = px end
								if not bestScore or score < bestScore then
									best = { entry = entry, part = part, px = px }
									bestScore = score
								end
							end
						end
					end
				end
			end
		end
	end
	return best
end

-- Frame-rate independent approach factor. `smooth` is a DIVISOR: the step taken
-- in one 60 FPS frame is 1/smooth of the remaining angle, and the exponent puts
-- any other frame rate back onto the same curve. A plain per-frame Lerp(alpha) is
-- a hard snap at 200 FPS whatever the slider says.
local function approach(smooth, dt)
	local base = 1 / math.max(1, smooth)
	return 1 - (1 - base) ^ math.max(dt * 60, 0.0001)
end

-- A world direction expressed in the SAME yaw/pitch space `CFrame:ToOrientation`
-- uses, so a gun-space error can be applied straight to the camera.
-- LookVector for (pitch p, yaw y) is (-sin y cos p, sin p, -cos y cos p).
local function dirYawPitch(v)
	local u = v.Unit
	return math.atan2(-u.X, -u.Z), math.asin(math.clamp(u.Y, -1, 1))
end

local function angleDelta(a, b)
	local d = (b - a) % (math.pi * 2)
	if d > math.pi then d = d - math.pi * 2 end
	return d
end

local function curveFactor(progress)
	local mode = CONFIG.aimCurve
	if mode == "Linear" then return 1 end
	if mode == "Human" then
		local x = math.clamp(1 - progress, 0, 1)
		return 0.35 + 1.3 * math.sin(x * math.pi)
	end
	return 1
end

--------------------------------------------------------------------------------
-- moving the view
--------------------------------------------------------------------------------
--
-- MEASURED, and tested the right way round, which matters: at
-- RenderPriority.Camera + 1 a 15 deg yaw write held at 0.00 deg against the
-- wanted CFrame and 14.99 deg against the previous one, three frames later. The
-- SAME write issued outside a render step was reverted to 0.03 deg. Comparing
-- only the second case would have read as "the camera controller is
-- authoritative" and sent this down the mouse path for nothing.
--
-- The mouse path stays as a dropdown because it is what an update turning the
-- controller authoritative would need. It learns the player's sensitivity rather
-- than assuming it: each frame records what it asked for and the next measures
-- what happened.

local mouseMove = mousemoverel or (Input and Input.mousemoverel)
	or (syn and syn.mousemoverel)

-- Seeded from the measurement rather than a guess: mousemoverel(60,0) turned
-- -2.47 deg of yaw and (200,0) turned -8.08, i.e. 0.041 deg per pixel, and
-- (0,30) turned -1.05 deg of pitch. Positive x turns RIGHT and lowers yaw;
-- positive y looks DOWN. The estimate still learns from there, because the
-- player's own sensitivity setting moves it.
local look = {
	degPerPxX = 0.041, degPerPxY = 0.038,
	sentX = 0, sentY = 0, yaw = 0, pitch = 0,
}

local function learnSensitivity(curYaw, curPitch)
	if look.sentX ~= 0 and math.abs(look.sentX) >= 2 then
		local got = math.deg(angleDelta(look.yaw, curYaw))
		if got ~= 0 and (got < 0) == (look.sentX > 0) then
			local est = math.abs(got / look.sentX)
			if est > 0.005 and est < 1 then
				look.degPerPxX = look.degPerPxX + (est - look.degPerPxX) * 0.25
			end
		end
	end
	if look.sentY ~= 0 and math.abs(look.sentY) >= 2 then
		local got = math.deg(curPitch - look.pitch)
		if got ~= 0 and (got < 0) == (look.sentY > 0) then
			local est = math.abs(got / look.sentY)
			if est > 0.005 and est < 1 then
				look.degPerPxY = look.degPerPxY + (est - look.degPerPxY) * 0.25
			end
		end
	end
	look.sentX, look.sentY = 0, 0
end

local function moveLook(stepYaw, stepPitch, curYaw, curPitch, pos)
	if CONFIG.aimPath == "Mouse" and mouseMove then
		local dx = -math.deg(stepYaw) / math.max(look.degPerPxX, 0.002)
		local dy = -math.deg(stepPitch) / math.max(look.degPerPxY, 0.002)
		-- A sub-pixel request is rounded away by the OS, so sending it would teach
		-- the estimate from a move that never happened.
		if math.abs(dx) < 1 and math.abs(dy) < 1 then return false end
		dx, dy = math.floor(dx + 0.5), math.floor(dy + 0.5)
		look.sentX, look.sentY = dx, dy
		look.yaw, look.pitch = curYaw, curPitch
		if pcall(mouseMove, dx, dy) then return true end
		look.sentX, look.sentY = 0, 0
	end
	camera.CFrame = CFrame.new(pos)
		* CFrame.fromOrientation(curPitch + stepPitch, curYaw + stepYaw, 0)
	return true
end

local function aimPass(dt)
	if _G.__TTK ~= GEN then return end
	aimWroteView = false
	STATE.aimDps = 0

	local blocked = assistBlocked()
	STATE.paused = blocked or ""
	if blocked then
		STATE.target, STATE.targetPart = "-", "-"
		stickyModel = nil
		clearPending()
		endEngagement()
		return
	end

	-- Each gate names ITSELF in the readout. With one shared early return the
	-- panel shows an armed aim, a visible target 52 px off the crosshair and a
	-- camera that never moves, and nothing anywhere says which rule stopped it.
	if not aimActive() then
		STATE.target, STATE.targetPart = "-", "-"
		stickyModel = nil
		clearPending()
		if engagement then endEngagement() end
		return
	end
	if not deployed() then
		STATE.paused = "not deployed"
		STATE.target = "-"
		stickyModel = nil
		if engagement then endEngagement() end
		return
	end
	if CONFIG.aimReady and not shotReady() then
		local w = myWeapon()
		STATE.paused = (w and w.IsReloading == true) and "reloading" or "gun not ready"
		return
	end
	if not adsGate(CONFIG.aimAds) then
		STATE.paused = "aim condition"
		STATE.target = "-"
		stickyModel = nil
		if engagement then endEngagement() end
		return
	end
	if os.clock() * 1000 - lastKillAt < CONFIG.aimKillMs then
		STATE.paused = "after kill"
		STATE.target = "-"
		return
	end

	local pick
	if CONFIG.aimSticky and stickyModel then
		local held
		for _, e in ipairs(combatants()) do
			if e.model == stickyModel then held = e break end
		end
		if held and aliveOf(held) then
			local part = targetPart(stickyModel)
			if part then
				local sp = camera:WorldToViewportPoint(part.Position)
				local px = (Vector2.new(sp.X, sp.Y) - centreOf()).Magnitude
				-- A GENEROUS window on purpose. Aligning the WEAPON swings the camera
				-- away from the target by however far the gun is off - up to 32 deg
				-- in HighReady - so a tight screen-pixel check drops the lock the
				-- instant the correction starts working, and the assist oscillates
				-- between acquiring and losing the same player.
				local keepPx = CONFIG.aimFov * ((CONFIG.aimAlign == "Weapon") and 4 or 1.35)
				if sp.Z > 0 and px <= keepPx
					and ((not CONFIG.aimVisible) or visibleTo(stickyModel, part)) then
					pick = { entry = held, part = part, px = px }
				end
			end
		end
	end
	pick = pick or pickTarget()

	if not pick or not pick.part or not pick.part.Parent then
		STATE.target, STATE.targetPart = "-", "-"
		stickyModel = nil
		clearPending()
		if engagement then endEngagement() end
		return
	end

	-- The switch lock, checked BEFORE the engagement is replaced: a different
	-- target cannot take over until the current one has been held for
	-- humSwitchMs, unless it is gone.
	if engagement and engagement.model ~= pick.entry.model and CONFIG.hum
		and os.clock() < engagement.lockUntil then
		local stillThere
		for _, e in ipairs(combatants()) do
			if e.model == engagement.model and aliveOf(e) then stillThere = e break end
		end
		if stillThere then
			local heldPart = targetPart(engagement.model)
			if heldPart then
				pick = { entry = stillThere, part = heldPart, px = pick.px }
			end
		end
	end

	if not engagement or engagement.model ~= pick.entry.model then
		newEngagement(pick.entry.model, pick.entry.name)
	end
	rerollOffset()
	stickyModel = pick.entry.model
	STATE.target = pick.entry.name

	local now = os.clock()

	-- Wind-up: nothing moves for the first few dozen milliseconds of a lock. A
	-- camera that starts travelling on the exact frame an enemy became visible is
	-- the most machine-like thing an aim assist does, and it costs nothing to fix.
	if now - engagement.t0 < engagement.windup then
		STATE.paused = "wind-up"
		return
	end

	if CONFIG.hum and CONFIG.humBreakPct > 0 then
		if now < engagement.breakTil then STATE.paused = "break-off" return end
		-- Per SECOND, so it is scaled by dt - as a per-frame chance the same number
		-- behaves completely differently at 60 and at 240 FPS.
		if math.random() < (CONFIG.humBreakPct / 100) * dt then
			engagement.breakTil = now + CONFIG.humBreakMs / 1000
			return
		end
	end

	local smoothH, smoothV = CONFIG.aimSmoothH, CONFIG.aimSmoothV

	if CONFIG.hum and CONFIG.humFatigue > 0 then
		local held = math.max(0, now - engagement.t0 - 1)
		local mult = 1 + held * (CONFIG.humFatigue / 100)
		smoothH, smoothV = smoothH * mult, smoothV * mult
	end

	local cf = camera.CFrame
	local pos = cf.Position
	local part = pick.part
	-- Head share works downward here: the head one-shots, so the humaniser's job
	-- is to make sure it is NOT a flat hundred percent of engagements, not to let
	-- the odd one through.
	if CONFIG.hum and not engagement.head and CONFIG.aimPart == "Head" then
		part = bodyPart(pick.entry.model) or part
	end
	STATE.targetPart = part.Name
	local dist = (pos - part.Position).Magnitude
	local aimAt = humanAimPoint(part, dist)

	if CONFIG.hum and engagement.over
		and (now - engagement.t0) < engagement.windup + 0.09 then
		local side = (engagement.ox >= 0) and 1 or -1
		aimAt = aimAt + cf.RightVector * side * math.rad(CONFIG.humOverDeg) * dist
	end

	local curPitch, curYaw = cf:ToOrientation()
	learnSensitivity(curYaw, curPitch)

	-- THE BULLET DOES NOT LEAVE THE CROSSHAIR, AND THIS IS THE WHOLE FIX.
	--
	-- FPSController line 1110 is the shot:
	--     BulletController:Discharge(name, CameraPOV.GetEyePosition(),
	--                                GunController:GetFireDirection(),
	--                                GunController:GetActiveProjectileMuzzleWorldCFrame())
	-- so `GetFireDirection()` IS the bullet. Measured against the camera's own
	-- look vector over 180 samples, split by stance:
	--
	--     AimAmount 0.0 (HighReady, hip)   32.09 deg average
	--     AimAmount 0.9                     6.92 deg
	--     AimAmount 1.0 (full ADS)          6.39 deg   (min 1.54, max 8.74)
	--
	-- The gun is never aligned with the crosshair, not even fully aimed. So
	-- putting the CROSSHAIR on somebody puts the BULLET about six degrees off at
	-- best and thirty-two off at worst, high and to one side - which is exactly
	-- how it was reported: "mostly above it and to the right".
	--
	-- The correction is therefore the angle between where the gun points and
	-- where we want it to point, applied to the camera - the gun rides the camera,
	-- so closing the gun's error by turning the camera converges.
	local dYaw, dPitch
	local fireDir, muzzlePos
	if CONFIG.aimAlign == "Weapon" and GunCtl then
		local okD, fd = pcall(function() return GunCtl:GetFireDirection() end)
		local okM, mz = pcall(function()
			return GunCtl:GetActiveProjectileMuzzleWorldCFrame()
		end)
		if okD and typeof(fd) == "Vector3" and fd.Magnitude > 0.001 then
			fireDir = fd
			if okM and typeof(mz) == "CFrame" then muzzlePos = mz.Position end
		end
	end

	if fireDir then
		local wantDir = (aimAt - (muzzlePos or pos))
		if wantDir.Magnitude > 0.001 then
			local fy, fp = dirYawPitch(fireDir)
			local wy, wp = dirYawPitch(wantDir)
			dYaw   = angleDelta(fy, wy)
			dPitch = wp - fp
			STATE.gunOffset = math.deg(math.acos(math.clamp(
				fireDir.Unit:Dot(cf.LookVector), -1, 1)))
		end
	end

	if not dYaw then
		-- Crosshair mode, and the fallback when the controller cannot be read.
		local want = CFrame.lookAt(pos, aimAt)
		local wantPitch, wantYaw = want:ToOrientation()
		dYaw = angleDelta(curYaw, wantYaw)
		dPitch = angleDelta(curPitch, wantPitch)
		STATE.gunOffset = -1
	end
	STATE.aimError = math.deg(math.sqrt(dYaw * dYaw + dPitch * dPitch))

	-- what is already on its way
	dYaw   = dYaw - pendYaw
	dPitch = dPitch - pendPitch
	STATE.aimPending = math.deg(math.sqrt(pendYaw * pendYaw + pendPitch * pendPitch))

	local progress = math.clamp(math.max(math.abs(dYaw), math.abs(dPitch)) / 0.5, 0, 1)
	local shape = curveFactor(progress)

	local stepYaw   = dYaw   * math.clamp(approach(smoothH, dt) * shape, 0, 1)
	local stepPitch = dPitch * math.clamp(approach(smoothV, dt) * shape, 0, 1)

	if CONFIG.hum and CONFIG.humDeadzone > 0 and pick.px <= CONFIG.humDeadzone then
		STATE.paused = "deadzone"
		return
	end

	-- The degrees-per-second cap, applied to yaw and pitch TOGETHER so a diagonal
	-- flick is capped exactly like a flat one. A smoothing divisor is a FRACTION
	-- of the remaining angle, so at point blank even a slow-looking divisor turns
	-- the camera at servo speed; this is the number that stops it.
	if CONFIG.hum and CONFIG.humTurnCap > 0 then
		local mag = math.sqrt(stepYaw * stepYaw + stepPitch * stepPitch)
		local cap = math.rad(CONFIG.humTurnCap) * math.max(dt, 1e-4)
		if mag > cap and mag > 0 then
			local k = cap / mag
			stepYaw, stepPitch = stepYaw * k, stepPitch * k
		end
	end

	-- How fast the ASSIST is turning the view, and only the assist's own
	-- contribution. Measuring the camera as a whole cannot answer this - it
	-- carries the player's wrist too - so this is the step the script applied.
	local applied = math.deg(math.sqrt(stepYaw * stepYaw + stepPitch * stepPitch))
	STATE.aimDps = applied / math.max(dt, 1e-4)
	if STATE.aimDps > STATE.aimDpsPeak then STATE.aimDpsPeak = STATE.aimDps end

	aimWroteView = moveLook(stepYaw, stepPitch, curYaw, curPitch, pos)
	if aimWroteView then
		pendYaw, pendPitch = stepYaw, stepPitch
	else
		pendYaw, pendPitch = 0, 0
	end
end

--------------------------------------------------------------------------------
-- recoil: measured, then cancelled ON THE CAMERA
--------------------------------------------------------------------------------
--
-- READ THE ANTICHEAT BLOCK AT THE TOP BEFORE CHANGING ANYTHING HERE.
--
-- The obvious no-recoil for this game is `RecoilSpring.s`, and it is exactly what
-- `IntegrityController.checkRecoilSpring` samples every 0.35 seconds, on both the
-- controller and the weapon, reporting anything below 6. Measured live:
-- GunController.RecoilSpring.s is 6.3 and the equipped weapon's is 18. So the
-- controller value sits 0.3 above the threshold - there is not even room to nudge
-- it, and this file never writes either one.
--
-- What it does instead is the counterblox method, which that check cannot see
-- because it touches nothing the game owns:
--
--   * every frame, compare the camera's pitch/yaw change against the raw mouse
--     movement UserInputService reported for that same frame
--   * WHILE NOT FIRING, the ratio of the two IS the effective sensitivity -
--     averaged continuously, and only on frames the script did not write the
--     camera itself
--   * WHILE FIRING, whatever change is left after subtracting sensitivity x mouse
--     delta is not the player. That residual is the recoil, and a configurable
--     share of it is subtracted back off the camera.
--
-- It needs no calibration step, it adapts if the player changes their sensitivity
-- mid-game, and both numbers are on the panel so the whole thing can be checked
-- rather than believed.

-- THE GAME'S OWN RECOIL, REPRODUCED FROM ITS OWN SOURCE.
--
-- FPSController, in the same Fired handler that sends the shot:
--
--   scale      = CameraRecoilMult * aimScale * GetAttachmentRecoilMult()
--   aimScale   = CameraRecoilAimMult == 1 and 1
--                or 1 + AimAmount * (CameraRecoilAimMult - 1)
--   ramp       = clamp((ShotIndex - 1) / 8, 0, 1) * 0.85 + 0.45
--   vertical   = 1.55 * RecoilPitchMult * scale * ramp
--   horizontal = (random() - 0.5)
--                * (0.85 * (1 + bloom * 2 * (1 + AimAmount * 1.5)))
--                * scale * RecoilYawMult
--
-- So the VERTICAL kick is fully deterministic - weapon constants, the shot index
-- and how far you are aimed in, nothing else - and can be cancelled before it is
-- even measured. The HORIZONTAL one is a fresh `math.random()` per shot and is
-- therefore NOT predictable at all; only its envelope is. Anything claiming to
-- pre-empt horizontal recoil in this game is guessing.
--
-- What one of these units is worth in camera degrees is NOT documented, so it is
-- not hard-coded: the ratio of the measured pitch residual to the predicted
-- vertical is learned while firing and shown on the panel, exactly the way
-- BloxStrike's pattern scale was.
local function recoilModel()
	local w = myWeapon()
	local def = myDef()
	if not w or not def or not GunCtl then return 0, 0, 1 end
	local aim = tonumber(GunCtl.AimAmount) or 0
	local aimScale = 1
	local cra = tonumber(def.CameraRecoilAimMult)
	if cra and cra ~= 1 then aimScale = 1 + aim * (cra - 1) end
	local attMult = 1
	local okA, a = pcall(function() return GunCtl:GetAttachmentRecoilMult() end)
	if okA and type(a) == "number" and a > 0 then attMult = a end
	local scale = (tonumber(def.CameraRecoilMult) or 1) * aimScale * attMult
	local shot = tonumber(w.ShotIndex) or 1
	local ramp = math.clamp((shot - 1) / 8, 0, 1) * 0.85 + 0.45
	local vertical = 1.55 * (tonumber(def.RecoilPitchMult) or 1) * scale * ramp
	local bloom = 0
	local okB, b = pcall(function() return GunCtl:GetEffectiveBloomFraction() end)
	if okB and type(b) == "number" then bloom = b end
	-- the envelope, not a prediction: the sign and size are a coin flip per shot
	local horizEnv = 0.5 * (0.85 * (1 + bloom * 2 * (1 + aim * 1.5)))
		* scale * (tonumber(def.RecoilYawMult) or 1)
	return vertical, horizEnv, scale
end

-- degrees of camera pitch per unit of the formula above. Learned, never assumed.
local unitDeg, unitSamples = 0, 0

local mouseDX, mouseDY = 0, 0
UserInputService.InputChanged:Connect(function(input)
	if _G.__TTK ~= GEN then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		mouseDX = mouseDX + input.Delta.X
		mouseDY = mouseDY + input.Delta.Y
	end
end)

local lastYaw, lastPitch = nil, nil
local sensPitch, sensYaw = 0, 0
local rcsAccX, rcsAccY = 0, 0
local rcsWroteView = false
local lastMag, magDropAt, sprayShots = nil, 0, 0
local sprayPred, sprayRes, pitchDebt = 0, 0, 0

-- The shot counter is READ, not inferred. MagAmmo dropping by one is a shot and
-- rising is a reload, and `Weapon.ShotIndex` is the client's own spray position.
-- counterblox had to count shots off a fire rate because nothing published them;
-- here that would be strictly worse.
local function shotWatch()
	local w = myWeapon()
	if not w or type(w.MagAmmo) ~= "number" then
		lastMag = nil
		return
	end
	local mag = w.MagAmmo
	if lastMag ~= nil then
		if mag < lastMag then
			magDropAt = os.clock()
			local fired = lastMag - mag
			sprayShots = sprayShots + fired
			-- Book what the game is ABOUT to add, per shot, from its own formula.
			local predV = recoilModel()
			sprayPred = sprayPred + predV * fired
			if unitDeg > 0 then
				pitchDebt = pitchDebt + predV * unitDeg * fired
			end
		elseif mag > lastMag then
			sprayShots = 0
		end
	end
	lastMag = mag
	-- The same ~0.35s gap a real spray gets before it is treated as a new one.
	-- The end of a spray is also when the unit scale is learned: total measured
	-- pitch against total predicted units, which is far steadier than trying to
	-- match a single shot's impulse to a single frame's residual.
	if os.clock() - magDropAt > 0.35 then
		if sprayPred > 0.001 and sprayRes > 0.05 then
			local ratio = sprayRes / sprayPred
			if ratio > 0.001 and ratio < 20 then
				unitDeg = (unitDeg == 0) and ratio or (unitDeg * 0.75 + ratio * 0.25)
				unitSamples = unitSamples + 1
			end
		end
		sprayShots, sprayPred, sprayRes = 0, 0, 0
	end
	STATE.mag = mag
	STATE.magMax = tonumber(w.MaxMagSize) or 0
	STATE.shotIndex = tonumber(w.ShotIndex) or sprayShots
end

local function firedRecently(within)
	return magDropAt > 0 and (os.clock() - magDropAt) < (within or 0.3)
end

local function recoilPass(dt)
	if _G.__TTK ~= GEN then return end
	rcsWroteView = false
	local cf = camera.CFrame
	local pitch, yaw = cf:ToOrientation()
	local mx, my = mouseDX, mouseDY
	mouseDX, mouseDY = 0, 0

	if lastYaw == nil then lastYaw, lastPitch = yaw, pitch return end
	local dPitch = pitch - lastPitch
	local dYaw = angleDelta(lastYaw, yaw)
	lastYaw, lastPitch = yaw, pitch

	local recent = firedRecently(0.3)

	if not recent and not aimWroteView and not rcsWroteView then
		if math.abs(my) > 2 then
			local s = -dPitch / my
			sensPitch = sensPitch == 0 and s or (sensPitch * 0.9 + s * 0.1)
			STATE.sens = sensPitch
		end
		if math.abs(mx) > 2 then
			local s = -dYaw / mx
			sensYaw = sensYaw == 0 and s or (sensYaw * 0.9 + s * 0.1)
			STATE.sensYaw = sensYaw
		end
		STATE.kickNow, STATE.kickHoriz = 0, 0
		STATE.rcsApplied = 0
		return
	end

	if aimWroteView or sensPitch == 0 then
		STATE.rcsApplied = 0
		return
	end

	local resPitch = dPitch - (-sensPitch * my)
	local resYaw   = dYaw   - (-sensYaw * mx)
	STATE.kickNow = math.deg(resPitch)
	STATE.kickHoriz = math.deg(resYaw)
	STATE.kickN = STATE.kickN + 1
	if math.abs(STATE.kickNow) > math.abs(STATE.kickPeak) then
		STATE.kickPeak = STATE.kickNow
	end

	-- feed the learner: the pitch the kick actually produced this frame
	if resPitch > 0 then sprayRes = sprayRes + math.deg(resPitch) end
	STATE.rcsUnit = unitDeg
	STATE.rcsUnitN = unitSamples
	STATE.rcsDebt = pitchDebt

	if not CONFIG.rcs then STATE.rcsApplied = 0 pitchDebt = 0 return end
	if assistBlocked() then STATE.rcsApplied = 0 return end
	if not deployed() then STATE.rcsApplied = 0 return end
	-- The first shot of a spray has no pattern to walk down yet, and cancelling
	-- there just fights the player's own first-shot correction.
	if sprayShots <= CONFIG.rcsFirst then STATE.rcsApplied = 0 return end

	local share = CONFIG.rcsPct / 100
	local cap = math.rad(CONFIG.rcsMaxDeg)
	local fixPitch, fixYaw

	if CONFIG.rcsMode == "Predicted" and unitDeg > 0 then
		-- Pay off the booked kick. The debt is in DEGREES already, because it was
		-- booked through the learned unit scale, and it is paid down at whatever
		-- the per-frame clamp allows so a nine-shot burst does not arrive as one
		-- jerk.
		local want = math.rad(pitchDebt) * share
		fixPitch = -math.clamp(want, 0, cap)
		pitchDebt = math.max(0, pitchDebt + math.deg(fixPitch) / math.max(share, 0.01))
	else
		fixPitch = math.clamp(-resPitch * share, -cap, cap)
	end
	-- The horizontal component is a fresh math.random() per shot in this game, so
	-- there is nothing to predict - it can only be answered after the fact, from
	-- the measured residual, in either mode.
	fixYaw = CONFIG.rcsHoriz and math.clamp(-resYaw * share, -cap, cap) or 0
	if math.abs(fixPitch) < 1e-6 and math.abs(fixYaw) < 1e-6 then
		STATE.rcsApplied = 0
		return
	end

	-- THROUGH THE MOUSE, not the CFrame. A camera write here is reverted by the
	-- controller on the very next frame exactly like the aim's was - it would have
	-- reported a healthy "cancelling 0.8 deg" on the panel while doing precisely
	-- nothing to the recoil.
	--
	-- The corrections are small (a 0.05 deg fix is 1.2 px at the measured
	-- 0.041 deg/px) and the OS rounds a sub-pixel request away, so the fraction is
	-- carried instead of discarded. Without the accumulator every correction below
	-- about half a degree is silently lost, which is most of them.
	local dx = -math.deg(fixYaw) / math.max(look.degPerPxX, 0.002)
	local dy = -math.deg(fixPitch) / math.max(look.degPerPxY, 0.002)
	rcsAccX, rcsAccY = rcsAccX + dx, rcsAccY + dy
	local sendX = (rcsAccX >= 0) and math.floor(rcsAccX) or math.ceil(rcsAccX)
	local sendY = (rcsAccY >= 0) and math.floor(rcsAccY) or math.ceil(rcsAccY)
	if sendX == 0 and sendY == 0 then
		STATE.rcsApplied = 0
		return
	end
	rcsAccX, rcsAccY = rcsAccX - sendX, rcsAccY - sendY
	if not (mouseMove and pcall(mouseMove, sendX, sendY)) then
		STATE.rcsApplied = 0
		return
	end
	rcsWroteView = true
	STATE.rcsApplied = math.deg(math.sqrt(fixPitch * fixPitch + fixYaw * fixYaw))
end

--------------------------------------------------------------------------------
-- trigger
--------------------------------------------------------------------------------
--
-- Fires the REAL mouse button, so the game's own weapon code runs the shot
-- exactly as it would for a human. No remote is fired and no hit is fabricated.

local click = mouse1click or (Input and Input.LeftClick)
local press, release = mouse1press, mouse1release

local function pullTrigger()
	local w = myWeapon()
	local auto = w and tostring(w.FireMode or ""):lower() == "auto"
	if CONFIG.trigHold and auto and press and release then
		press()
		task.wait(math.max(0.02, CONFIG.trigHoldMs / 1000))
		release()
		return
	end
	if click then click()
	elseif press and release then press() task.wait(0.02) release() end
end

-- What the shot would hit, asked the way the shot asks it: from the eye position
-- the client uses, along the camera's own look direction, with the game's own
-- exclude list and no collision group - which is exactly how Discharge casts.
-- THE SHOT DOES NOT COME OUT OF THE CROSSHAIR, so neither does this ray.
--
-- FPSController fires
--   BulletController:Discharge(name, CameraPOV.GetEyePosition(),
--                              GunController:GetFireDirection(),
--                              GunController:GetActiveProjectileMuzzleWorldCFrame())
-- and Discharge starts the bullet at the MUZZLE, travelling along GetFireDirection.
-- The muzzle sits about 3.3 studs from the eye and the barrel is up to 32 degrees
-- off the camera, so a ray cast from the eye along the camera's look vector is a
-- different ray entirely - it answers a question the gun never asks. That is a
-- real defect and it was found by comparing the two side by side.
local function shotRay(dirOverride)
	if not GunCtl then return nil end
	local okD, fd = pcall(function() return GunCtl:GetFireDirection() end)
	local okM, mz = pcall(function()
		return GunCtl:GetActiveProjectileMuzzleWorldCFrame()
	end)
	if not (okD and okM) then return nil end
	if typeof(fd) ~= "Vector3" or typeof(mz) ~= "CFrame" then return nil end
	if fd.Magnitude < 0.001 then return nil end
	local dir = dirOverride or fd.Unit
	losParams.FilterDescendantsInstances = excludeList()
	local origin = mz.Position
	return workspace:Raycast(origin, dir * weaponRange(), losParams), origin, fd.Unit
end

local function underCrosshair()
	local range = weaponRange()
	local baseHit, origin, fireDir = shotRay()
	if not fireDir then
		-- No readable gun state: fall back to the camera so the panel still shows
		-- something rather than going blank, and say nothing stronger than that.
		local cf = camera.CFrame
		origin = cf.Position
		fireDir = cf.LookVector
	end

	local dirs = { fireDir }
	if CONFIG.trigFov > 0 then
		-- A single centre ray only ever works on a stationary target. The ring is
		-- built around the FIRE direction, in the plane perpendicular to it, sized
		-- from the pixel setting through the camera's own field of view.
		local vp = camera.ViewportSize
		local perPx = math.rad(camera.FieldOfView) / math.max(vp.Y, 1)
		local spread = CONFIG.trigFov * perPx
		local up = Vector3.new(0, 1, 0)
		local right = fireDir:Cross(up)
		if right.Magnitude < 0.001 then right = Vector3.new(1, 0, 0) end
		right = right.Unit
		local realUp = right:Cross(fireDir).Unit
		for i = 0, 5 do
			local a = math.rad(i * 60)
			dirs[#dirs + 1] = (fireDir
				+ right * math.sin(spread) * math.cos(a)
				+ realUp * math.sin(spread) * math.sin(a)).Unit
		end
	end

	for _, dir in ipairs(dirs) do
		local hit = select(1, shotRay(dir))
		if not hit and dir == fireDir then hit = baseHit end
		if hit and hit.Instance then
			local rig = rigFromHit(hit.Instance)
			if rig and rig.Name:sub(1, 13) == "MercHitboxes_"
				and rig.Name:sub(-7) ~= "_Corpse"
				and rig:GetAttribute("OwnerUserId") ~= plr.UserId then
				local entry
				for _, e in ipairs(combatants()) do
					if e.model == rig then entry = e break end
				end
				if entry and entry.foe and aliveOf(entry) then
					if (not CONFIG.trigHeadOnly) or HEAD_PARTS[hit.Instance.Name] then
						local dist = (origin - hit.Position).Magnitude
						if dist <= math.min(CONFIG.trigMaxDist, range) then
							return rig, hit.Instance, entry, dist
						end
					end
				end
			end
		end
	end
	return nil
end

local function trigActive()
	if not CONFIG.trig then return false end
	if CONFIG.trigActive == "Always" then return true end
	return keyHeld(CONFIG.trigKey)
end

task.spawn(function()
	claimIdentity()
	local nextAt = 0
	while _G.__TTK == GEN do
		local ok, err = pcall(function()
			-- Evaluated even when the trigger is not armed, purely so the panel can
			-- SHOW what is under the crosshair. Without it there is no way to tell
			-- "the key is not held" from "the ray never reaches the enemy".
			local rig, part, entry, dist = underCrosshair()
			if rig then
				local dmg = part and select(1, damageFor(part.Name, dist)) or nil
				STATE.underCross = tostring(entry and entry.name or rig.Name)
					.. "  " .. tostring(part and part.Name or "?")
					.. (dmg and string.format("  %.0f dmg", dmg) or "")
			else
				STATE.underCross = "-"
			end

			if assistBlocked() then STATE.trigOn = false return end

			local held = trigActive()
			if not held then
				STATE.trigOn = false
				return
			end
			STATE.trigOn = true

			if not deployed() then
				STATE.underCross = "-- not deployed"
				return
			end
			if not shotReady() then
				STATE.underCross = "-- gun not ready"
				return
			end
			if not adsGate(CONFIG.trigAds) then
				STATE.underCross = "-- aim condition"
				return
			end

			local now = os.clock() * 1000
			if now < nextAt then return end
			if not rig then return end

			local hitPct = CONFIG.trigHitPct
			if CONFIG.hum and CONFIG.humMissPct > 0 then
				hitPct = math.max(1, hitPct - CONFIG.humMissPct)
			end
			if math.random(100) > hitPct then
				nextAt = now + CONFIG.trigRefireMs
				return
			end

			local lo = math.min(CONFIG.trigDelayMin, CONFIG.trigDelayMax)
			local hi = math.max(CONFIG.trigDelayMin, CONFIG.trigDelayMax)
			local wait
			if CONFIG.hum then
				wait = gauss((lo + hi) / 2, math.max(1, CONFIG.humReactSd))
				wait = math.clamp(wait, math.max(0, lo - 20), hi + 60)
			else
				wait = (hi > 0) and math.random(lo, hi) or 0
			end
			if wait > 0 then task.wait(wait / 1000) end

			-- Re-check AFTER the delay. Without this the trigger fires at where the
			-- enemy was 90 ms ago, which on a strafing player is a miss and a
			-- give-away in equal measure.
			if not underCrosshair() then return end
			if not shotReady() then return end
			if assistBlocked() then return end

			pullTrigger()
			STATE.trigHits = STATE.trigHits + 1
			local refire = CONFIG.trigRefireMs
			if CONFIG.hum then refire = refire * (0.85 + math.random() * 0.35) end
			nextAt = os.clock() * 1000 + refire
		end)
		if not ok then note("trigger: " .. tostring(err)) end
		task.wait(0.01)
	end
end)

-- Auto fire for the aim assist, kept apart from the trigger so the two can run at
-- once without fighting over the mouse.
task.spawn(function()
	claimIdentity()
	local nextAt = 0
	while _G.__TTK == GEN do
		local ok, err = pcall(function()
			if not (CONFIG.aim and CONFIG.aimFire) then return end
			if STATE.target == "-" then return end
			if assistBlocked() then return end
			if not shotReady() then return end
			if engagement and os.clock() - engagement.t0 < engagement.windup then return end
			local now = os.clock() * 1000
			if now < nextAt then return end
			local pct = CONFIG.aimHitPct
			if CONFIG.hum and CONFIG.humMissPct > 0 then
				pct = math.max(1, pct - CONFIG.humMissPct)
			end
			if math.random(100) > pct then
				nextAt = now + 200
				return
			end
			if CONFIG.aimFirstMs > 0 then
				task.wait(CONFIG.aimFirstMs / 1000)
				if STATE.target == "-" or not shotReady() then return end
			end
			pullTrigger()
			local def = myDef()
			local rate = (def and def.FireRate) or 0.12
			nextAt = os.clock() * 1000 + math.max(rate * 1000, 40)
		end)
		if not ok then note("autofire: " .. tostring(err)) end
		task.wait(0.02)
	end
end)

-- A kill pauses the aim: staying glued to a corpse and then flicking off it is
-- the most obvious thing an assist can do. A rig going Ragdolled, losing its
-- health or being reparented as a corpse all count.
task.spawn(function()
	claimIdentity()
	local seen = setmetatable({}, { __mode = "k" })
	while _G.__TTK == GEN do
		pcall(function()
			for _, entry in ipairs(combatants()) do
				local hp = aliveOf(entry)
				local was = seen[entry.model]
				if was and was > 0 and not hp and entry.model == stickyModel then
					lastKillAt = os.clock() * 1000
					stickyModel = nil
					endEngagement()
				end
				seen[entry.model] = hp or 0
			end
			if stickyModel and not stickyModel.Parent then
				lastKillAt = os.clock() * 1000
				stickyModel = nil
				endEngagement()
			end
		end)
		task.wait(0.1)
	end
end)

--------------------------------------------------------------------------------
-- round watch
--------------------------------------------------------------------------------
--
-- Round state is attributes on `workspace` itself. A phase change is a reason to
-- sit still for a moment: everybody is respawning and nothing is worth assisting.

local function roundRead()
	STATE.phase      = tostring(workspace:GetAttribute("GamePhase") or "-")
	STATE.matchState = tostring(workspace:GetAttribute("MatchState") or "-")
	STATE.mode       = tostring(workspace:GetAttribute("Flow_Mode")
		or workspace:GetAttribute("GameMode") or "-")
	STATE.map        = tostring(workspace:GetAttribute("CurrentMapName") or "-")
	STATE.scoreLimit = tonumber(workspace:GetAttribute("ModeScoreLimit")) or 0
	local endsAt = tonumber(workspace:GetAttribute("MapRoundEndsAt"))
	if endsAt then
		local left = endsAt - workspace:GetServerTimeNow()
		if left >= 0 then
			STATE.timer = string.format("%d:%02d", math.floor(left / 60), math.floor(left % 60))
		else
			STATE.timer = "0:00"
		end
	else
		STATE.timer = "-"
	end
end

for _, attr in ipairs({ "GamePhase", "MatchState", "CurrentMapName" }) do
	workspace:GetAttributeChangedSignal(attr):Connect(function()
		if _G.__TTK ~= GEN then return end
		roundRead()
		if CONFIG.hum and CONFIG.humRoundMs > 0 then
			pauseFor(CONFIG.humRoundMs, "round change")
		end
		stickyModel = nil
		endEngagement()
	end)
end

--------------------------------------------------------------------------------
-- the frame bindings
--------------------------------------------------------------------------------
--
-- Two of them on purpose. The aim step has to run after the game's own camera
-- code or it is simply overwritten, and the ESP wants to run after the camera has
-- settled for this frame or the boxes trail the view by one frame.

for _, name in ipairs({ "SeluxTTKAim", "SeluxTTKESP" }) do
	pcall(function() RunService:UnbindFromRenderStep(name) end)
end

-- Bound from a thread that has already yielded, for the same reason every loop
-- above starts with claimIdentity(). A render-step callback registered from the
-- thread this file is executed on inherits that thread's context, and loaded
-- through the bridge that context may not touch an Instance.
task.spawn(function()
claimIdentity()
if _G.__TTK ~= GEN then return end

RunService:BindToRenderStep("SeluxTTKAim", Enum.RenderPriority.Camera.Value + 1,
	function(dt)
		if _G.__TTK ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxTTKAim") end)
			return
		end
		local ok, err = pcall(function()
			shotWatch()
			aimPass(dt)
			recoilPass(dt)
		end)
		if not ok then note("aim: " .. tostring(err)) end
	end)

RunService:BindToRenderStep("SeluxTTKESP", Enum.RenderPriority.Camera.Value + 2,
	function()
		if _G.__TTK ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxTTKESP") end)
			hideAll()
			return
		end
		local ok, err = pcall(renderPass)
		if not ok then note("esp: " .. tostring(err)) end
	end)

end)

-- The camera reference is replaced on every respawn, so a cached one silently
-- stops updating after the first death - which looks exactly like "the ESP broke
-- after I died".
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then camera = workspace.CurrentCamera end
end)

workspace.ChildAdded:Connect(function(child)
	if child.Name == "MercPlayers" then MercPlayers = child end
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__TTK_WIN then pcall(function() _G.__TTK_WIN:Destroy() end) end
for _, root in ipairs({ (gethui and gethui()) or nil, CoreGui }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "TTKPanel" then pcall(function() g:Destroy() end) end
		end
	end
end

-- Merges the saved file into CONFIG BEFORE the panel is built - the controls read
-- their initial value out of CONFIG when they are created, so they come up on the
-- saved state by themselves.
UI.config("ttk", CONFIG)

local win = UI.Window({
	name = "TTKPanel",
	title = "TTK", accentTitle = "TESTING", subtitle = "seltonmt",
	badge = "◎", width = 820, height = 582,
})
_G.__TTK_WIN = win

local CTL = {}
local function reg(key, handle)
	CTL[key] = handle
	return handle
end

local function applyPreset(name)
	local set = PRESETS[name]
	if not set then return end
	for key, value in pairs(set) do
		CONFIG[key] = value
		local handle = CTL[key]
		-- Every setter in this template is called with a COLON, so it receives the
		-- wrapper table first and the value second. Getting that wrong is silent.
		if handle then pcall(function() handle:set(value) end) end
	end
	stickyModel = nil
	endEngagement()
	note("preset: " .. name)
end

local TEXT_ATTR = "SxText"
local function setButton(button, text)
	pcall(function()
		button:SetAttribute(TEXT_ATTR, text)
		button.Text = UI.t(text)
	end)
end

local function bindButton(card, caption, get, set)
	local button
	local function paint()
		setButton(button, caption .. ": " .. keyDisplay(get()))
	end
	button = card:Button(caption .. ": " .. keyDisplay(get()), function()
		if capturing then return end
		setButton(button, "PRESS A KEY OR MOUSE BUTTON  -  ESC CANCELS")
		arm(function(name)
			if name then set(name) end
			paint()
		end)
	end, UI.theme.band)
	return paint
end

-- ESP --------------------------------------------------------------------------

do
local espPage = win:Page("ESP", UI.icon.eye)

local drawCard = espPage:Card("DRAWING", 1):Accent()
drawCard:Toggle("Box", CONFIG.box, function(v) CONFIG.box = v end,
	"projected head to feet, so it scales with range by itself", UI.theme.good)
drawCard:Toggle("Filled box", CONFIG.boxFilled, function(v) CONFIG.boxFilled = v end)
drawCard:Toggle("Name", CONFIG.name, function(v) CONFIG.name = v end)
drawCard:Toggle("Team tag", CONFIG.teamTag, function(v) CONFIG.teamTag = v end,
	"teams exist even in the free-for-all - Alpha against Bravo")
drawCard:Toggle("Weapon", CONFIG.weaponTag, function(v) CONFIG.weaponTag = v end,
	"the CurrentWeapon attribute replicates for every player", UI.theme.good)
drawCard:Toggle("Distance", CONFIG.distance, function(v) CONFIG.distance = v end)
drawCard:Toggle("Health bar", CONFIG.health, function(v) CONFIG.health = v end,
	"real and it moves - a live sample caught a player at 13 HP", UI.theme.good)
drawCard:Toggle("Kills / deaths", CONFIG.kdTag, function(v) CONFIG.kdTag = v end,
	"both attributes replicate, so the whole scoreboard is readable")
drawCard:Toggle("Head dot", CONFIG.headDot, function(v) CONFIG.headDot = v end)
drawCard:Toggle("Skeleton", CONFIG.skeleton, function(v) CONFIG.skeleton = v end)
drawCard:Toggle("Tracer", CONFIG.tracer, function(v) CONFIG.tracer = v end)

local modeCard = espPage:Card("RANGE & VIEW", 2)
modeCard:Toggle("Wall check", CONFIG.visCheck, function(v) CONFIG.visCheck = v end,
	"same exclude list and same collision group the game's own bullet uses",
	UI.theme.good)
modeCard:Label("The 91 MapBarrier clip brushes are invisible AND solid - the exact thing that made every enemy in Counter Blox read as behind a wall - but this game puts them in collision group Ignore, which a default ray already walks through. No hand-built filter is needed here.")
modeCard:Toggle("Draw the real hitboxes", CONFIG.hitboxDraw, function(v)
	CONFIG.hitboxDraw = v
end, "all 15 invisible parts - Head is 1.45 wide, UpperTorso 2.73", UI.theme.good)
modeCard:Toggle("Draw downed players", CONFIG.deadESP, function(v) CONFIG.deadESP = v end,
	"RigState has three values here: Alive, Ragdolled, Dead")
modeCard:Toggle("Draw your own team", CONFIG.drawFriendly, function(v)
	CONFIG.drawFriendly = v
end, "hostility comes from the game's own Hostility.IsHostile, not a team name")
modeCard:Slider("Max distance", 100, 2500, CONFIG.maxDist, function(v)
	CONFIG.maxDist = v
end, "how far the ESP DRAWS - not the weapon range, which is per gun")
modeCard:Toggle("Mark out of range", CONFIG.rangeTag, function(v) CONFIG.rangeTag = v end,
	"a ! means further than YOUR gun's Range - 150 on the shotgun, 600 on the M1A",
	UI.theme.good)
modeCard:Slider("Text size", 12, 26, CONFIG.textSize, function(v) CONFIG.textSize = v end,
	"whole pixels; below 12 every Drawing face turns to mush")
modeCard:Dropdown("Font", FONTLIST, CONFIG.textFont, function(v) CONFIG.textFont = v end)
modeCard:Toggle("Text outline", CONFIG.textOutline, function(v) CONFIG.textOutline = v end)
modeCard:Toggle("Shrink with distance", CONFIG.textShrink, function(v)
	CONFIG.textShrink = v
end)

local colCard = espPage:Card("COLOURS", 1)
colCard:Colour("Enemy", CONFIG.colEnemy, function(c) CONFIG.colEnemy = c end,
	"behind a wall the same colour is drawn at 55% brightness")
colCard:Colour("Own team", CONFIG.colFriend, function(c) CONFIG.colFriend = c end)
colCard:Colour("Downed", CONFIG.colDead, function(c) CONFIG.colDead = c end)
colCard:Colour("Hitboxes", CONFIG.colHitbox, function(c) CONFIG.colHitbox = c end)
colCard:Colour("FOV circle", CONFIG.colFov, function(c) CONFIG.colFov = c end)

local chamCard = espPage:Card("CHAMS", 2)
chamCard:Toggle("Chams", CONFIG.chams, function(v)
	CONFIG.chams = v
	if not v then clearChams() end
end, "lives outside the game tree, so no client script can walk onto it",
	UI.theme.warn)
chamCard:Label("If your executor refuses a Highlight outside the game tree, chams switch themselves off and the reason appears in the footer - the rest of the ESP keeps drawing.")
chamCard:Dropdown("Style", CHAM_LIST, CONFIG.chamStyle, function(v) CONFIG.chamStyle = v end)
chamCard:Toggle("Rainbow", CONFIG.chamRainbow, function(v) CONFIG.chamRainbow = v end)
chamCard:Toggle("Own cham colour", CONFIG.colChamOwn, function(v) CONFIG.colChamOwn = v end)
chamCard:Colour("Cham colour", CONFIG.colCham, function(c) CONFIG.colCham = c end)

local visCard = espPage:Card("CROSSHAIR & AMMO", 0)
visCard:Toggle("Magazine bar", CONFIG.ammoBar, function(v) CONFIG.ammoBar = v end,
	"MagAmmo read off the weapon - it goes amber during a reload", UI.theme.good)
visCard:Toggle("Custom crosshair", CONFIG.crosshair, function(v) CONFIG.crosshair = v end)
visCard:Slider("Length", 2, 30, CONFIG.crossSize, function(v) CONFIG.crossSize = v end)
visCard:Slider("Gap", 0, 20, CONFIG.crossGap, function(v) CONFIG.crossGap = v end)
visCard:Slider("Thickness", 1, 5, CONFIG.crossThick, function(v) CONFIG.crossThick = v end)
visCard:Toggle("Centre dot", CONFIG.crossDot, function(v) CONFIG.crossDot = v end)
visCard:Colour("Crosshair colour", CONFIG.colCross, function(c) CONFIG.colCross = c end)
end

-- AIM --------------------------------------------------------------------------

local aimOut, dmgOut

do
local aimPage = win:Page("AIM", UI.icon.target)

local aimCard = aimPage:Card("ACTIVATION", 1):Accent()
reg("aim", aimCard:Toggle("Aim enabled", CONFIG.aim, function(v)
	CONFIG.aim = v
	note(v and "aim on" or "aim off")
end, "moves the VIEW only - fires no remote and fakes no hit", UI.theme.warn))
aimCard:Dropdown("Trigger", { "Hotkey", "Always", "While firing" }, CONFIG.aimActive,
	function(v) CONFIG.aimActive = v end)
bindButton(aimCard, "AIM KEY", function() return CONFIG.aimKey end,
	function(v) CONFIG.aimKey = v end)
aimCard:Label("Every firearm in this game one-shots to the head against 100 HP: MK23 168, M18 148, Rattler and AUG 136, KH9 128, UMP 124, MP5 112, M1A SOCOM 110. To the body the same guns need three hits. That is why Head is the default here.")
reg("aimPart", aimCard:Dropdown("Aim at", { "Head", "Body", "Nearest" },
	CONFIG.aimPart, function(v) CONFIG.aimPart = v end))
aimCard:Dropdown("Pick target by", { "Crosshair", "Closest", "Lowest HP" },
	CONFIG.aimPick, function(v) CONFIG.aimPick = v end)
aimCard:Label("Align: this game's gun does not point where the crosshair points. Measured against the camera - 32.1 deg average in HighReady, and still 6.4 deg fully aimed down sights. Weapon drives the BULLET onto the target, which is the one that hits; Crosshair is the naive version and is kept only for comparison.")
reg("aimAlign", aimCard:Dropdown("Align", { "Weapon", "Crosshair" }, CONFIG.aimAlign,
	function(v) CONFIG.aimAlign = v end))
aimCard:Label("Travel curve: Human starts slow, is fastest mid-flick, settles slowly")
reg("aimCurve", aimCard:Dropdown("Travel curve", { "Ease out", "Linear", "Human" },
	CONFIG.aimCurve, function(v) CONFIG.aimCurve = v end))
aimCard:Label("View path: this game rebuilds the camera from angles it keeps itself, so writing camera.CFrame does NOTHING - measured, a 0.5 deg nudge is 100% reverted on the very next frame and a 20 deg write is gone in five. Mouse is the only path that works here: mousemoverel(60,0) turns 2.47 deg and it stays. Camera is kept only so you can see the difference.")
aimCard:Dropdown("View path", { "Mouse", "Camera" }, CONFIG.aimPath,
	function(v) CONFIG.aimPath = v end)

local tuneCard = aimPage:Card("TUNING", 2)
reg("aimFov", tuneCard:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov,
	function(v) CONFIG.aimFov = v end,
	"only targets inside this circle around the crosshair"))
reg("aimSmoothH", tuneCard:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH,
	function(v) CONFIG.aimSmoothH = v end,
	"horizontal; 1 = instant, 50 = about a second, frame rate independent"))
reg("aimSmoothV", tuneCard:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV,
	function(v) CONFIG.aimSmoothV = v end,
	"vertical - slower than H takes the give-away snap off the head"))
tuneCard:Slider("Max distance", 50, 800, CONFIG.aimMaxDist, function(v)
	CONFIG.aimMaxDist = v
end)
reg("aimVisible", tuneCard:Toggle("Visible only", CONFIG.aimVisible,
	function(v) CONFIG.aimVisible = v end,
	"never aims at somebody the bullet ray cannot reach", UI.theme.good))
tuneCard:Toggle("Sticky target", CONFIG.aimSticky, function(v)
	CONFIG.aimSticky = v
	stickyModel = nil
end, "holds one target instead of flicking to whoever is a pixel closer",
	UI.theme.good)
tuneCard:Toggle("Only while the gun can fire", CONFIG.aimReady, function(v)
	CONFIG.aimReady = v
end, "reads the weapon's own CanFire / IsReloading - no tracking during a reload")
tuneCard:Dropdown("Aim condition", { "Always", "Aiming only", "Not aiming" },
	CONFIG.aimAds, function(v) CONFIG.aimAds = v end)

local fireCard = aimPage:Card("AUTO FIRE", 1)
reg("aimFire", fireCard:Toggle("Auto fire", CONFIG.aimFire,
	function(v) CONFIG.aimFire = v end,
	"pulls the trigger itself once a target is held", UI.theme.warn))
reg("aimHitPct", fireCard:Slider("Hit chance %", 1, 100, CONFIG.aimHitPct, function(v)
	CONFIG.aimHitPct = v
end, "below 100 deliberately skips shots"))
fireCard:Slider("Delay after kill (ms)", 0, 1500, CONFIG.aimKillMs, function(v)
	CONFIG.aimKillMs = v
end, "do not stay glued to a corpse - the most obvious tell there is")
fireCard:Slider("First bullet delay (ms)", 0, 1000, CONFIG.aimFirstMs, function(v)
	CONFIG.aimFirstMs = v
end)
fireCard:Toggle("Draw FOV circle", CONFIG.aimCircle, function(v) CONFIG.aimCircle = v end)

aimOut = aimPage:Card("TARGET", 2):Readout(8)
dmgOut = aimPage:Card("YOUR WEAPON", 0):Readout(7)
end

-- TRIGGER ----------------------------------------------------------------------

local trigOut

do
local trigPage = win:Page("TRIGGER", UI.icon.bolt)

local trigCard = trigPage:Card("TRIGGERBOT", 1):Accent()
reg("trig", trigCard:Toggle("Trigger enabled", CONFIG.trig, function(v)
	CONFIG.trig = v
	note(v and "trigger on" or "trigger off")
end, "fires when a target is under the crosshair - a real mouse click",
	UI.theme.warn))
trigCard:Dropdown("Trigger", { "Hotkey", "Always" }, CONFIG.trigActive,
	function(v) CONFIG.trigActive = v end)
bindButton(trigCard, "TRIGGER KEY", function() return CONFIG.trigKey end,
	function(v) CONFIG.trigKey = v end)
trigCard:Toggle("Head only", CONFIG.trigHeadOnly, function(v) CONFIG.trigHeadOnly = v end,
	"the head one-shots here, so this costs far less than it does elsewhere",
	UI.theme.good)
trigCard:Toggle("Hold on automatics", CONFIG.trigHold, function(v) CONFIG.trigHold = v end,
	"presses and holds instead of a single click when FireMode is Auto")
trigCard:Slider("Hold time (ms)", 40, 600, CONFIG.trigHoldMs, function(v)
	CONFIG.trigHoldMs = v
end)
trigCard:Dropdown("Aim condition", { "Always", "Aiming only", "Not aiming" },
	CONFIG.trigAds, function(v) CONFIG.trigAds = v end)
trigCard:Label("The trigger reads the weapon's own CanFire, IsReloading and MagAmmo, so it never clicks into a reload or an empty magazine.")

local trigTime = trigPage:Card("TIMING", 2)
reg("trigDelayMin", trigTime:Slider("Reaction min (ms)", 0, 500, CONFIG.trigDelayMin,
	function(v) CONFIG.trigDelayMin = v end,
	"with the humaniser on this is a bell curve, not a flat band"))
reg("trigDelayMax", trigTime:Slider("Reaction max (ms)", 0, 500, CONFIG.trigDelayMax,
	function(v) CONFIG.trigDelayMax = v end))
reg("trigRefireMs", trigTime:Slider("Refire lockout (ms)", 20, 1000, CONFIG.trigRefireMs,
	function(v) CONFIG.trigRefireMs = v end))
reg("trigHitPct", trigTime:Slider("Hit chance %", 1, 100, CONFIG.trigHitPct,
	function(v) CONFIG.trigHitPct = v end))
trigTime:Slider("FOV (pixels)", 0, 60, CONFIG.trigFov, function(v) CONFIG.trigFov = v end,
	"0 = the exact centre ray only; above that a ring of six more")
trigTime:Slider("Max distance", 50, 800, CONFIG.trigMaxDist, function(v)
	CONFIG.trigMaxDist = v
end)

trigOut = trigPage:Card("STATUS", 1):Readout(7)
end

-- RECOIL -----------------------------------------------------------------------

local recOut, acOut

do
local recPage = win:Page("RECOIL", UI.icon.wave)

local rcsCard = recPage:Card("RECOIL CONTROL", 1):Accent()
rcsCard:Label("This does NOT touch the game's recoil spring - that field is what the anticheat samples every 0.35s. It measures your own sensitivity while you are not firing, subtracts it from the camera movement while you are, and pushes the leftover back through the MOUSE, because a camera write is reverted by this game on the next frame.")
reg("rcs", rcsCard:Toggle("Recoil control", CONFIG.rcs, function(v)
	CONFIG.rcs = v
	note(v and "recoil control on" or "recoil control off")
end, "camera side only", UI.theme.warn))
reg("rcsPct", rcsCard:Slider("Cancel %", 0, 100, CONFIG.rcsPct, function(v)
	CONFIG.rcsPct = v
end, "how much of the measured residual is pushed back"))
reg("rcsMaxDeg", rcsCard:Slider("Max per frame (deg)", 1, 10, CONFIG.rcsMaxDeg,
	function(v) CONFIG.rcsMaxDeg = v end,
	"a clamp, so nothing can oscillate"))
rcsCard:Toggle("Horizontal too", CONFIG.rcsHoriz, function(v) CONFIG.rcsHoriz = v end)
reg("rcsFirst", rcsCard:Slider("Leave the first N shots", 0, 5, CONFIG.rcsFirst,
	function(v) CONFIG.rcsFirst = v end,
	"the first shot of a spray has no pattern to walk down yet"))

acOut = recPage:Card("THE GAME'S ANTICHEAT - WHAT IT WATCHES", 2):Readout(14)
recOut = recPage:Card("MEASURED", 0):Readout(8)
end

-- HUMAN ------------------------------------------------------------------------

local humOut

do
local humPage = win:Page("HUMAN", UI.icon.shield)

local preCard = humPage:Card("PRESETS", 1):Accent()
preCard:Label("Three sets that write every number on this page at once. Everything stays editable afterwards.")
preCard:Button("LEGIT", function() applyPreset("Legit") end, UI.theme.good)
preCard:Button("NORMAL", function() applyPreset("Normal") end, UI.theme.band)
preCard:Button("RAW", function() applyPreset("Raw") end, UI.theme.bad)
reg("hum", preCard:Toggle("Humaniser", CONFIG.hum, function(v) CONFIG.hum = v end,
	"off means every number below is ignored", UI.theme.warn))

local tellCard = humPage:Card("TELLS", 2)
reg("humTurnCap", tellCard:Slider("Turn speed cap (deg/s)", 40, 3000, CONFIG.humTurnCap,
	function(v) CONFIG.humTurnCap = v end,
	"the big one - a fast human flick is roughly 400-900 deg/s"))
reg("humDeadzone", tellCard:Slider("Deadzone (px)", 0, 20, CONFIG.humDeadzone,
	function(v) CONFIG.humDeadzone = v end,
	"inside this the view is left completely alone"))
reg("humWindupMin", tellCard:Slider("Wind-up min (ms)", 0, 400, CONFIG.humWindupMin,
	function(v) CONFIG.humWindupMin = v end,
	"nothing moves for this long after a target is acquired"))
reg("humWindupMax", tellCard:Slider("Wind-up max (ms)", 0, 600, CONFIG.humWindupMax,
	function(v) CONFIG.humWindupMax = v end))
reg("humOffsetPct", tellCard:Slider("Aim offset (% of the part)", 0, 90,
	CONFIG.humOffsetPct, function(v) CONFIG.humOffsetPct = v end,
	"never the exact centre of the hitbox twice - the head is only 1.45 wide"))
reg("humRerollMs", tellCard:Slider("Re-roll the offset (ms)", 200, 4000,
	CONFIG.humRerollMs, function(v) CONFIG.humRerollMs = v end))
reg("humJitter", tellCard:Slider("Drift (studs at 100m)", 0, 4, CONFIG.humJitter,
	function(v) CONFIG.humJitter = v end,
	"a smooth random walk, not per-frame noise - noise reads as a stutter"))
reg("humOvershoot", tellCard:Slider("Overshoot %", 0, 100, CONFIG.humOvershoot,
	function(v) CONFIG.humOvershoot = v end,
	"a flick that stops dead on target is not a hand"))
reg("humHeadPct", tellCard:Slider("Head share %", 0, 100, CONFIG.humHeadPct,
	function(v) CONFIG.humHeadPct = v end,
	"a hundred percent headshots is the single loudest statistic there is"))
reg("humBreakPct", tellCard:Slider("Break off % per second", 0, 40, CONFIG.humBreakPct,
	function(v) CONFIG.humBreakPct = v end,
	"scaled by dt, so it behaves the same at 60 and at 240 FPS"))
reg("humFatigue", tellCard:Slider("Fatigue % per second", 0, 120, CONFIG.humFatigue,
	function(v) CONFIG.humFatigue = v end))
reg("humCooldown", tellCard:Slider("Pause between engagements (ms)", 0, 1200,
	CONFIG.humCooldown, function(v) CONFIG.humCooldown = v end))
reg("humSwitchMs", tellCard:Slider("Target switch lock (ms)", 0, 1500,
	CONFIG.humSwitchMs, function(v) CONFIG.humSwitchMs = v end,
	"stops the twitch between two targets a pixel apart"))
reg("humMoveFov", tellCard:Slider("FOV while moving %", 10, 100, CONFIG.humMoveFov,
	function(v) CONFIG.humMoveFov = v end))
reg("humMissPct", tellCard:Slider("Deliberate misses %", 0, 40, CONFIG.humMissPct,
	function(v) CONFIG.humMissPct = v end))
reg("humReactSd", tellCard:Slider("Reaction spread (ms)", 1, 120, CONFIG.humReactSd,
	function(v) CONFIG.humReactSd = v end))

local safeCard = humPage:Card("SAFETY", 1)
safeCard:Toggle("Off while the panel is open", CONFIG.humPanelPause, function(v)
	CONFIG.humPanelPause = v
end, "nothing should assist while you are clicking in here")
safeCard:Slider("Quiet after a phase change (ms)", 0, 3000, CONFIG.humRoundMs,
	function(v) CONFIG.humRoundMs = v end,
	"everybody is respawning and nothing is worth assisting")
safeCard:Label("Panic key: switches aim, trigger, auto fire and recoil control off at once")
bindButton(safeCard, "PANIC KEY", function() return CONFIG.panicKey end,
	function(v) CONFIG.panicKey = v end)
table.insert(panicHandlers, function()
	for _, key in ipairs({ "aim", "trig", "aimFire", "rcs" }) do
		local handle = CTL[key]
		if handle then pcall(function() handle:set(false) end) end
	end
end)

humOut = humPage:Card("STATUS", 1):Readout(7)
end

-- ROUND ------------------------------------------------------------------------

local roundOut, listOut, statOut

do
local infoPage = win:Page("ROUND", UI.icon.list)

roundOut = infoPage:Card("MATCH", 1):Readout(7)
statOut  = infoPage:Card("YOU", 2):Readout(7)
listOut  = infoPage:Card("PLAYERS", 0):Readout(11)
end

--------------------------------------------------------------------------------
-- the panel refresh
--------------------------------------------------------------------------------

local baseKills, baseDeaths = nil, nil

task.spawn(function()
	claimIdentity()
	while _G.__TTK == GEN do
		local ok, err = pcall(function()
			roundRead()

			local w = myWeapon()
			STATE.deployed  = deployed()
			STATE.aiming    = adsOn()
			STATE.reloading = w and w.IsReloading == true or false
			STATE.firing    = GunCtl and GunCtl.FireHeld == true or false
			STATE.weapon    = weaponName()
			STATE.fireMode  = w and tostring(w.FireMode or "-") or "-"

			STATE.kills  = tonumber(plr:GetAttribute("Kills")) or 0
			STATE.deaths = tonumber(plr:GetAttribute("Deaths")) or 0
			STATE.xp     = tonumber(plr:GetAttribute("MatchXP")) or 0
			STATE.ic     = tonumber(plr:GetAttribute("MatchIC")) or 0

			-- Session counters are DIFFERENCES against the server's own attributes,
			-- not something this script increments. A counter you increment yourself
			-- proves nothing; only a server value moving does.
			if baseKills == nil then
				baseKills, baseDeaths = STATE.kills, STATE.deaths
			end
			STATE.sessionKills  = STATE.kills - baseKills
			STATE.sessionDeaths = STATE.deaths - baseDeaths

			local def = myDef()
			local head, body = nil, nil
			if def then
				head = select(1, damageFor("Head", 0))
				body = select(1, damageFor("UpperTorso", 0))
			end
			STATE.dmgHead = head or 0
			STATE.dmgBody = body or 0
			STATE.shotsToBody = (body and body > 0) and math.ceil(100 / body) or 0

			local camPos = camera.CFrame.Position
			local range = weaponRange()

			local rows = {}
			for _, entry in ipairs(combatants()) do
				local hp, _, root = aliveOf(entry)
				local dist = root and math.floor((camPos - root.Position).Magnitude) or nil
				local wn = entry.player and entry.player:GetAttribute("CurrentWeapon")
				rows[#rows + 1] = {
					alive = hp ~= nil,
					dist = dist or 99999,
					line = string.format(" %-6s %-15s %-6s %-11s %-6s %s",
						entry.foe and "ENEMY" or "team",
						tostring(entry.name):sub(1, 15),
						hp and (math.floor(hp) .. "hp") or rigState(entry.model):sub(1, 6),
						tostring(wn or "-"):sub(1, 11),
						dist and (dist .. "m") or "-",
						string.format("%d/%d",
							tonumber(entry.player and entry.player:GetAttribute("Kills")) or 0,
							tonumber(entry.player and entry.player:GetAttribute("Deaths")) or 0)),
				}
			end
			table.sort(rows, function(a, b)
				if a.alive ~= b.alive then return a.alive end
				return a.dist < b.dist
			end)

			local lines = { " SIDE   NAME            HP     WEAPON      DIST   K/D" }
			for i = 1, math.min(#rows, 10) do lines[#lines + 1] = rows[i].line end
			if #rows == 0 then
				lines[#lines + 1] = "  nobody in MercPlayers - are you deployed?"
			end
			pcall(function() listOut:set(lines) end)

			pcall(function()
				roundOut:set({
					"  MATCH",
					"  mode       " .. STATE.mode .. "   map " .. STATE.map,
					"  phase      " .. STATE.phase .. "   state " .. STATE.matchState,
					"  timer      " .. STATE.timer .. "   score limit "
						.. tostring(STATE.scoreLimit),
					string.format("  drawn      %d   (%d enemies, %d own team)",
						STATE.targets, STATE.enemies, STATE.friends),
					"  deployed   " .. tostring(STATE.deployed)
						.. "   aiming " .. tostring(STATE.aiming),
					"  chams      " .. (CONFIG.chams
						and ((chamsFails > 0 and chamsReason)
							and string.format("retrying (%d fails) - %s", chamsFails, chamsReason)
							or "on")
						or "switched off"),
				})
			end)

			pcall(function()
				statOut:set({
					"  YOU",
					string.format("  kills %d   deaths %d   K/D %.2f", STATE.kills,
						STATE.deaths, STATE.kills / math.max(STATE.deaths, 1)),
					string.format("  match XP %d   IC %d", STATE.xp, STATE.ic),
					string.format("  session  +%d kills  +%d deaths",
						STATE.sessionKills, STATE.sessionDeaths),
					string.format("  weapon   %s   %s   %d/%d",
						STATE.weapon, STATE.fireMode, STATE.mag, STATE.magMax),
					string.format("  spray    shot %d   reloading %s",
						STATE.shotIndex, tostring(STATE.reloading)),
					string.format("  trigger clicks %d", STATE.trigHits),
				})
			end)

			pcall(function()
				aimOut:set({
					"  target   " .. tostring(STATE.target)
						.. "   at " .. tostring(STATE.targetPart),
					"  active   " .. (CONFIG.aim and CONFIG.aimActive or "off")
						.. (CONFIG.aimActive == "Hotkey"
							and ("  " .. keyDisplay(CONFIG.aimKey)) or ""),
					string.format("  now      FOV %dpx   H %d   V %d   at %s",
						CONFIG.aimFov, CONFIG.aimSmoothH, CONFIG.aimSmoothV,
						CONFIG.aimPart),
					"  path     " .. CONFIG.aimPath
						.. (CONFIG.aimPath == "Mouse"
							and string.format("   %.4f deg/px", look.degPerPxX) or ""),
					"  blocked  " .. ((STATE.paused ~= "") and STATE.paused or "no"),
					string.format("  turning  %.0f deg/s   peak %.0f   cap %d",
						STATE.aimDps, STATE.aimDpsPeak, CONFIG.humTurnCap),
					"  gun      " .. (shotReady() and "ready" or "not ready")
						.. string.format("   %d/%d", STATE.mag, STATE.magMax),
					string.format("  align    %s   barrel %s off crosshair   err %.2f  inflight %.2f",
						CONFIG.aimAlign,
						(STATE.gunOffset >= 0) and string.format("%.1f", STATE.gunOffset)
							or "n/a",
						STATE.aimError, STATE.aimPending),
				})
			end)

			pcall(function()
				dmgOut:set({
					"  " .. STATE.weapon .. (def and ("   " .. tostring(def.DisplayName or ""))
						or "   (not a firearm in the registry)"),
					def and string.format("  damage   body %.0f   head %.0f   x%s",
						STATE.dmgBody, STATE.dmgHead, tostring(def.HeadshotMult or "?"))
						or "  damage   -",
					def and string.format("  to kill  %d body shots   %s to the head",
						STATE.shotsToBody,
						(STATE.dmgHead >= 100) and "ONE" or
							tostring(math.ceil(100 / math.max(STATE.dmgHead, 1))))
						or "  to kill  -",
					def and string.format("  rate     %.3fs   mode %s   mag %s",
						def.FireRate, tostring(def.FireMode), tostring(def.MagSize))
						or "  rate     -",
					def and string.format("  range    %s studs   falloff %s",
						tostring(def.Range), tostring(def.DamageFalloff))
						or "  range    -",
					"  every one of these numbers is read from Registries.Weapons",
					"  and the damage through the game's own BodyDamage module",
				})
			end)

			pcall(function()
				trigOut:set({
					"  state    " .. (CONFIG.trig
						and (STATE.trigOn and "armed"
							or ("waiting for " .. keyDisplay(CONFIG.trigKey)))
						or "off"),
					"  crosshair " .. tostring(STATE.underCross),
					string.format("  clicks   %d   reaction %d-%dms",
						STATE.trigHits, CONFIG.trigDelayMin, CONFIG.trigDelayMax),
					"  window   " .. (CONFIG.trigFov > 0
						and (CONFIG.trigFov .. "px ring") or "single centre ray")
						.. (CONFIG.trigHeadOnly and "   head only" or ""),
					string.format("  gun      %s   %d/%d   %s",
						shotReady() and "ready" or "not ready",
						STATE.mag, STATE.magMax, STATE.fireMode),
					"  blocked  " .. ((STATE.paused ~= "") and STATE.paused or "no"),
					"  the ray uses the game's own exclude list and collision group",
				})
			end)

			pcall(function()
				recOut:set({
					"  MEASURED LIVE, NOTHING HERE IS ASSUMED",
					string.format("  sensitivity  pitch %.5f   yaw %.5f rad/px",
						STATE.sens, STATE.sensYaw),
					string.format("  residual     %.2f deg pitch   %.2f deg yaw",
						STATE.kickNow, STATE.kickHoriz),
					string.format("  peak         %.2f deg over %d sampled frames",
						STATE.kickPeak, STATE.kickN),
					string.format("  cancelling   %.2f deg this frame   (%d%% of residual)",
						STATE.rcsApplied, CONFIG.rcsPct),
					string.format("  spray        shot %d   leaving the first %d alone",
						STATE.shotIndex, CONFIG.rcsFirst),
					"  If the residual stays at zero while you fire, this game does",
					"  not move the camera on recoil and there is nothing to cancel.",
				})
			end)

			pcall(function()
				acOut:set({
					"  THE GAME SHIPS AN ANTICHEAT. IT REPORTS, IT DOES NOT KICK.",
					"  Modules.Client.Controllers.IntegrityController sends to",
					"  Remotes.Combat.SessionTelemetry, once per reason per session.",
					"",
					"  ENV_GLOBAL      42 executor globals in getfenv(1..8)   6-12s",
					"  MM_INDEX        __index or __namecall replaced         6-12s",
					"  FIRESERVER_HOOK FireServer is no longer a C closure    6-12s",
					"  RECOIL_S_LOW    RecoilSpring.s below 6                 0.35s",
					"  BODYMOVER       a BodyVelocity on your character       live",
					"  LOG_SIG         tool names in the console output       live",
					"",
					"  MEASURED: its dedupe table was EMPTY with the bridge running,",
					"  so none of these had fired. This script keeps it that way -",
					"  it hooks no metamethod, hooks no FireServer, and never writes",
					"  RecoilSpring (measured 6.3 against a threshold of 6).",
				})
			end)

			pcall(function()
				humOut:set({
					"  humaniser " .. (CONFIG.hum and "on" or "OFF"),
					"  blocked   " .. ((STATE.paused ~= "") and STATE.paused or "no"),
					"  engagement " .. (engagement
						and string.format("%s  %s  %.1fs", engagement.name,
							engagement.head and "head" or "body",
							os.clock() - engagement.t0)
						or "-"),
					string.format("  turning   %.0f deg/s   peak %.0f   cap %d",
						STATE.aimDps, STATE.aimDpsPeak, CONFIG.humTurnCap),
					"  panel     " .. (panelOpen() and "open" or "closed")
						.. "   panic " .. keyDisplay(CONFIG.panicKey),
					"  last key  " .. tostring(STATE.lastKey),
					string.format("  head share %d%%   switch lock %dms",
						CONFIG.humHeadPct, CONFIG.humSwitchMs),
				})
			end)

			pcall(function()
				win:SetStat(1, tostring(STATE.kills), "kills")
				win:SetStat(2, tostring(STATE.deaths), "deaths")
				win:SetStat(3, tostring(STATE.enemies), "enemies")
				win:SetNote(STATE.note ~= "" and STATE.note or "Ready")
				win:SetStatus(string.format("%s   %s   %s   %s   %d drawn",
					STATE.map, STATE.mode,
					STATE.deployed and "deployed" or STATE.phase,
					STATE.timer, STATE.targets))
			end)
		end)
		if not ok then note("ui: " .. tostring(err)) end
		task.wait(0.4)
	end
end)

-- "Auto fire" or a FOV circle switched on while the aim itself is off does
-- nothing, and from the outside that reads as a dead toggle rather than a gate.
-- Watched from ONE place instead of being wired into every callback: what matters
-- is the transition off -> on, and a poll sees that however the flag was changed.
-- Seeded from the current values, so a panel that starts with auto fire already
-- on does not arm itself.
local ARM_AIM = { "aimFire", "aimCircle" }

task.spawn(function()
	claimIdentity()
	local was = {}
	for _, key in ipairs(ARM_AIM) do was[key] = CONFIG[key] and true or false end
	while _G.__TTK == GEN do
		for _, key in ipairs(ARM_AIM) do
			local on = CONFIG[key] and true or false
			if on and not was[key] and not CONFIG.aim then
				CONFIG.aim = true
				local handle = CTL["aim"]
				if handle then pcall(function() handle:set(true) end) end
				note("Aim was off - switched on with it")
			end
			was[key] = on
		end
		task.wait(0.2)
	end
end)

pcall(function() win:Home() end)
win:Refresh()

--------------------------------------------------------------------------------

_G.__TTK_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	combatants = combatants, aliveOf = aliveOf, rigState = rigState,
	healthOf = healthOf, rootOf = rootOf, hostileTo = hostileTo, teamName = teamName,
	bodyPart = bodyPart, headPart = headPart, targetPart = targetPart,
	bulletRay = bulletRay, rigFromHit = rigFromHit, visibleTo = visibleTo,
	excludeList = excludeList,
	underCrosshair = underCrosshair, pickTarget = pickTarget,
	aimPass = aimPass, renderPass = renderPass, recoilPass = recoilPass,
	shotWatch = shotWatch, shotReady = shotReady, adsOn = adsOn,
	myWeapon = myWeapon, myDef = myDef, weaponName = weaponName,
	weaponRange = weaponRange, damageFor = damageFor, weaponDef = weaponDef,
	deployed = deployed, roundRead = roundRead,
	pullTrigger = pullTrigger, keyHeld = keyHeld,
	approach = approach, angleDelta = angleDelta, firing = firing, gauss = gauss,
	humanAimPoint = humanAimPoint, assistBlocked = assistBlocked, pauseFor = pauseFor,
	newEngagement = newEngagement, endEngagement = endEngagement,
	applyPreset = applyPreset, PRESETS = PRESETS, CTL = CTL,
	drawn = drawn, highlights = highlights, hideAll = hideAll, clearChams = clearChams,
	chamFor = chamFor, chamsRoot = chamsRoot, visualOf = visualOf,
	chamsState = function() return chamsReason, chamsFails, chamsNextTry end,
	note = note, panelOpen = panelOpen,
	GunCtl = GunCtl, Hostility = Hostility, BodyDamage = BodyDamage,
	WEAPONS = WEAPONS, CameraPOV = CameraPOV,
}

print("[ttk] gen " .. GEN .. " ready - RightShift for the panel")
