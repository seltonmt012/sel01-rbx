--[[ deaglearena.lua - "[EVENT] Deagle Arena" (public place 84556640895285)

  The fourth SHOOTER in this collection and the first one that is a FFA duel game
  rather than a team round game. Everything below was measured through the bridge
  before a line of this was written; where a number appears in this file it came
  off the running client, not off a guess.

  * **ONE SHOT IS ONE KILL.** `Modules.Shared.Config.Deagle` reads
    `Damage = 100`, `HitFireRate = 0.9`, `MissFireRate = 1.1`, and every
    character has `MaxHealth = 100`. So no body part does more damage than any
    other, health is a binary, and the resource that actually matters is the
    COOLDOWN - a miss costs 1.1s, a hit 0.9s.
  * **Therefore the head is the WRONG place to aim.** The hitboxes are
    `HeadHitbox` 3.23 x 3.25 x 3.23 and `BodyHitbox` 4.77 x 4.59 x 2.20, both
    invisible, both CanQuery. The body is the larger target and pays exactly the
    same 100 damage, so "Body" is the default here and the panel says why. Every
    published script for this game aims at the head.
  * **The lobby is full of BOTS and `Players:GetPlayers()` does not list them.**
    Measured on a live server: `#Players:GetPlayers()` is 1 while eight character
    models sit in the Workspace. Bots are plain Models parented straight into
    `workspace` carrying `IsBot = true`, `BotLevel`, `BotUserId`, `BotAiming`,
    `Elo`. `Matchmaking.NoBotsElo` is 1250, so above that rank they stop
    appearing. Any target list built from the Players service alone finds nobody
    at all, which is why the ESP here walks BOTH.
  * **The bullet ray is a shared module and this script uses the game's own.**
    `Modules.Shared.DeagleShared.Raycast(character, from, to)` casts 600 studs in
    up to 8 penetration passes, filtering the shooter, every Accessory of every
    living character, all dead bodies and anything tagged / named `InvisiblePart`.
    Calling it is exact rather than approximate: there is no ignore list to
    maintain and no clip-brush trap to fall into, because this IS the function the
    shot uses. 600 studs is also a hard weapon range - a target further away
    cannot be hit at all, so it is the ceiling on every distance slider here.
  * **The shot state is published by the client's own controller.**
    `PlayerScripts.ModuleLoader.DeagleController` carries `InGame`, `CanShoot`,
    `ShootCooldownUntil` and `IsAiming` as live fields. The trigger reads them, so
    it never clicks into a cooldown and never fires while you are in the menu, and
    the ADS gate is the real scope flag rather than a guess.
  * **Spawn protection is a real gate and it is readable.**
    `EffectsController.ProtectedPlayers[character]` is the exact table the game's
    own shot checks before it reports a hit, and the character attribute
    `SpawnProtection` mirrors it. Shooting a protected player does nothing but
    start your 1.1s miss cooldown, so both the aim and the trigger skip them.
  * **The state oracle is `ClientData.Data`** - Kills, Deaths, Elo, Rank, Streak,
    HighestStreak, Headshots, Level, Cash, Gems, Wins, Matches. It is mutated in
    place by the `UpdateData` client event, so the table stays valid; every
    before/after claim about this script is checked against it.
  * **The lobby and the match are DIFFERENT PLACES and the match place varies.**
    `Config.Matchmaking` holds `PublicPlaceId 84556640895285` and
    `RankedPlaceId 112087763192016`, and ranked additionally reserves servers. So
    the hub entry for this script must not be a place-id list: detection is
    content based (`Modules.Shared.DeagleShared` + `Modules.Shared.Config`), which
    matches in every place this game can throw you into.
  * **The camera write STICKS here.** Measured at `RenderPriority.Camera + 1`
    with `CameraType.Custom`: a 15 deg yaw write read 0.00 deg against the wanted
    CFrame and 15.00 deg against the previous one two frames later. So unlike
    BloxStrike the aim does not have to go through `mousemoverel` - but it still
    can, and the mouse path is kept as a dropdown because it is the one that
    survives a game update turning the camera controller authoritative.
  * **Recoil is a single spring impulse, not a spray pattern.**
    `CameraController.Shoot` does `spring:AddVelocity(0.017)` on a
    `Spring.new(4, 12, 300, ...)` and applies the offset as pitch, which then
    settles back to zero by itself. With one shot per ~1s there is no spray to
    control, so this script ships NO recoil-control page. What it does ship is the
    measurement, on the AIM page, so the claim can be checked rather than believed.

  Nothing here hooks anything of the game and nothing fabricates a hit. The shot
  path is `Network:FireServer("Shoot", origin, aimPoint, hitInstance, hitPosition)`
  - the client reports which part it hit - and this script deliberately does not
  touch it. The aim moves the view and the trigger presses the real mouse button,
  so whatever the server validates it validates an ordinary shot.

  The ONE remote this file fires is `RedeemCode`, behind a button the user
  presses, with the same payload the game's own Claim button sends.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr    = Players.LocalPlayer
local camera = workspace.CurrentCamera

local GEN = (_G.__DEAGLE or 0) + 1
_G.__DEAGLE = GEN

-- Every long-lived loop below starts with this. A task.spawn inherits the
-- identity of the thread that created it, and the thread this file is first
-- executed on is not always one that may touch an Instance: loaded through the
-- bridge, the first iteration of the trigger loop died with "The current thread
-- cannot access 'Instance' (lacking capability Plugin)" while the same call ran
-- fine a second later. It is transient, it is once per run, and it costs one
-- guarded call to remove.
-- ...and every loop yields ONCE before its first pass. task.spawn does not defer:
-- the body runs synchronously up to its first yield, which means the first
-- iteration of every loop here executes while the main chunk is still running -
-- inside whatever context executed the file. Loaded through the bridge that is
-- the poll loop's sandbox, and `Mouse.GetMousePos()` reached from there threw
-- "lacking capability Plugin" exactly once per run before recovering by itself.
-- One task.wait() moves the first pass onto a normal scheduler frame and the
-- error goes away entirely rather than being caught and displayed.
local function claimIdentity()
	if setthreadidentity then pcall(setthreadidentity, 8) end
	task.wait()
end

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
	health     = false,   -- one shot is one kill, so a health bar is nearly always full
	botTag     = true,    -- BOT vs a real player - the thing the HUD never tells you
	levelTag   = true,    -- their level (bots) or elo
	streakTag  = true,    -- who is on a kill streak
	protTag    = true,    -- spawn protection: shooting them only costs you 1.1s
	distance   = true,
	tracer     = false,
	headDot    = false,
	hitboxDraw = false,   -- draw the real BodyHitbox / HeadHitbox rectangles
	skeleton   = false,
	aimingWarn = true,    -- bots publish BotAiming; mark the ones aiming
	chams      = false,
	deadESP    = false,
	visCheck   = true,
	-- NOT the weapon's 600 stud range. Hiding an enemy because a bullet could not
	-- reach him is the ESP answering a question nobody asked - in the lobby every
	-- opponent sits 680-960 studs away on the arena map, and a 600 cap drew
	-- exactly nothing while seven people were plainly visible. Out of weapon range
	-- is INFORMATION and gets a marker, not a deletion.
	maxDist    = 1400,
	rangeTag   = true,    -- mark anybody past the 600 stud bullet range
	textSize   = 14,
	textFont   = "System",
	textOutline = true,
	textShrink = false,

	colEnemy   = Color3.fromRGB(255, 72, 88),
	colBot     = Color3.fromRGB(255, 176, 60),
	colProt    = Color3.fromRGB(120, 140, 165),
	colCham    = Color3.fromRGB(255, 72, 88),
	colChamOwn = false,
	colFov     = Color3.fromRGB(255, 255, 255),
	colSilent  = Color3.fromRGB(255, 90, 200),
	colHitbox  = Color3.fromRGB(120, 200, 255),

	chamStyle  = "Fill",
	chamRainbow = false,

	-- visuals ------------------------------------------------------------------
	crosshair  = false,
	crossSize  = 8,
	crossGap   = 3,
	crossDot   = true,
	crossThick = 1,
	colCross   = Color3.fromRGB(90, 255, 140),
	cooldownBar = true,   -- the 0.9 / 1.1s shot cooldown, drawn under the crosshair
	fovChange  = false,
	fovValue   = 90,

	-- aim assist ---------------------------------------------------------------
	aim        = false,
	aimActive  = "Hotkey",
	aimKey     = "MouseButton2",
	aimPart    = "Body",
	aimPick    = "Crosshair",
	aimSticky  = true,
	aimVisible = true,
	aimSkipProt = true,
	aimMaxDist = 600,
	aimReady   = true,    -- only assist while the gun can actually fire
	aimAds     = "Always",
	aimCurve   = "Ease out",
	aimPath    = "Camera",  -- Camera | Mouse

	aimFov     = 120,
	aimSmoothH = 25,
	aimSmoothV = 25,

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
	trigSkipProt = true,
	trigMaxDist = 600,
	trigFov    = 0,
	trigAds    = "Always",

	-- silent shot --------------------------------------------------------------
	--
	-- MEASURED on a live round, against ClientData.Data.Kills as the oracle:
	--   * a target 64.6 deg off the crosshair, 70 studs away  -> kill, 109 -> 110
	--   * a target 164 studs away BEHIND A WALL               -> kill, 135 -> 136
	--   * three shots fired 0.15s apart at three targets      -> ONE kill
	-- So the server validates neither the direction nor the line of sight, and the
	-- only thing it does enforce is the gun's own fire rate. "Kill everyone at
	-- once" is therefore not possible here at all; one kill per cooldown is.
	--
	-- TWO MODES, and the default is the narrow one. "FOV" is what silent aim
	-- normally means and what a player expects from the name: the same pixel
	-- circle around the crosshair an aim assist uses, and anybody inside it dies -
	-- so it plays exactly like an aimbot, minus the camera actually moving. "Any
	-- target" is the wide version measured above: no circle, no line of sight, no
	-- angle, anybody on the map inside the range slider. It stays available
	-- because it works, but it is not the default and it is not what most people
	-- want to be seen using.
	silentMode   = "FOV",
	silentFov    = 120,
	silentCircle = true,
	silent       = false,
	silentActive = "Hotkey",
	silentKey    = "F",
	silentPart   = "Body",
	silentPick   = "Crosshair",
	silentVisible = false,
	silentSkipProt = true,
	silentMaxDist = 600,
	silentCycle  = false,
	silentGapMs  = 980,
	silentDelayMin = 0,
	silentDelayMax = 60,
	silentHitPct = 100,

	-- humaniser ----------------------------------------------------------------
	hum          = true,
	humWindupMin = 40,
	humWindupMax = 130,
	humOffsetPct = 35,
	humJitter    = 0.9,
	humJitterHz  = 1.4,
	humOvershoot = 30,
	humOverDeg   = 1.8,
	humHeadPct   = 40,     -- the head pays nothing extra here, so this stays low
	humMissPct   = 0,
	humBreakPct  = 6,
	humBreakMs   = 180,
	humFatigue   = 25,
	humCooldown  = 120,
	humReactSd   = 22,
	humPanelPause = true,
	humBotOnly   = false,  -- assist against bots only, never against a real player
	humTurnCap   = 260,
	humDeadzone  = 2,
	humMoveFov   = 70,
	humSwitchMs  = 350,
	humRerollMs  = 900,
	humRoundMs   = 800,

	panicKey     = "End",
}

-- No master switch, for the reason bloxstrike wrote down: every drawing has its
-- own row, so a switch above them can only ever mean "the row you just moved does
-- nothing", which is what it gets reported as. The render pass still wants a
-- cheap way out when the whole list is off - this is it.
local DRAWINGS = {
	"box", "boxFilled", "name", "health", "botTag", "levelTag", "streakTag",
	"protTag", "rangeTag", "distance", "tracer", "headDot", "hitboxDraw",
	"skeleton", "aimingWarn", "deadESP", "chams",
}

local function anyDrawing()
	for _, key in ipairs(DRAWINGS) do
		if CONFIG[key] then return true end
	end
	return false
end

local PRESETS = {
	["Legit"] = {
		aimFov = 45, aimSmoothH = 40, aimSmoothV = 55, aimPart = "Body",
		aimFire = false, aimVisible = true, aimCurve = "Human",
		trigDelayMin = 110, trigDelayMax = 240, trigRefireMs = 200, trigHitPct = 85,
		hum = true, humTurnCap = 160, humDeadzone = 4, humWindupMin = 90,
		humWindupMax = 240, humOffsetPct = 55, humHeadPct = 15, humOvershoot = 45,
		humBreakPct = 12, humMissPct = 8, humFatigue = 40, humCooldown = 260,
		humMoveFov = 45,
	},
	["Normal"] = {
		aimFov = 120, aimSmoothH = 25, aimSmoothV = 25, aimPart = "Body",
		aimFire = false, aimVisible = true, aimCurve = "Ease out",
		trigDelayMin = 40, trigDelayMax = 110, trigRefireMs = 60, trigHitPct = 100,
		hum = true, humTurnCap = 260, humDeadzone = 2, humWindupMin = 40,
		humWindupMax = 130, humOffsetPct = 35, humHeadPct = 40, humOvershoot = 30,
		humBreakPct = 6, humMissPct = 0, humFatigue = 25, humCooldown = 120,
		humMoveFov = 70,
	},
	["Raw"] = {
		aimFov = 400, aimSmoothH = 2, aimSmoothV = 2, aimPart = "Body",
		aimFire = true, aimVisible = true, aimCurve = "Linear",
		trigDelayMin = 0, trigDelayMax = 10, trigRefireMs = 30, trigHitPct = 100,
		hum = false, humTurnCap = 3000, humDeadzone = 0, humWindupMin = 0,
		humWindupMax = 0, humOffsetPct = 0, humHeadPct = 100, humOvershoot = 0,
		humBreakPct = 0, humMissPct = 0, humFatigue = 0, humCooldown = 0,
		humMoveFov = 100,
	},
}

local STATE = {
	note       = "",
	targets    = 0,
	bots       = 0,
	humans     = 0,
	target     = "-",
	targetKind = "-",
	trigHits   = 0,
	trigOn     = false,
	underCross = "-",
	aimDps     = 0, aimDpsPeak = 0,
	lastKey    = "-",
	paused     = "",
	inRound    = false,
	inGame     = false,
	canShoot   = false,
	cooldown   = 0,
	aiming     = false,
	roundOn    = false,
	timer      = "-",
	kills = 0, deaths = 0, elo = 0, rank = "-", streak = 0, level = 0,
	cash = 0, gems = 0, headshots = 0, wins = 0, matches = 0,
	sessionKills = 0, sessionDeaths = 0,
	hits = 0, misses = 0, lastShotMs = 0,
	silentOn = false, silentShots = 0, silentKills = 0, silentSeen = 0,
	silentTarget = "-", silentNote = "-",
	chams = "-",
	kickPeak   = 0, kickNow = 0, kickN = 0,
	sens       = 0,
	codeNote   = "-",
	serverMode = "-",
	shots      = 0,
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
-- has already loaded returns the same cached table, so this is a read of live
-- state rather than a second copy of it - and it is the difference between
-- knowing the shot cooldown and estimating it.

local Modules  = waitFor(ReplicatedStorage, "Modules", 10)
local Shared   = Modules and waitFor(Modules, "Shared", 10)
local Packages = Modules and waitFor(Modules, "Packages", 10)

local function tryRequire(inst)
	if not inst then return nil end
	local ok, value = pcall(require, inst)
	if ok then return value end
	return nil
end

local DS       = tryRequire(Shared and Shared:FindFirstChild("DeagleShared"))
local Config   = tryRequire(Shared and Shared:FindFirstChild("Config"))
local Skins    = tryRequire(Shared and Shared:FindFirstChild("Config")
	and Shared.Config:FindFirstChild("Skins"))
local MousePkg = tryRequire(Packages and Packages:FindFirstChild("Mouse"))
local Network  = tryRequire(Packages and Packages:FindFirstChild("Network"))

local ML = waitFor(waitFor(plr, "PlayerScripts", 10), "ModuleLoader", 10)
local DeagleCtl = tryRequire(ML and ML:FindFirstChild("DeagleController"))
local EffectsCtl = tryRequire(ML and ML:FindFirstChild("EffectsController"))
local ClientData = tryRequire(ML and ML:FindFirstChild("ClientData"))

local DEAGLE = (Config and Config.Deagle) or { Damage = 100, HitFireRate = 0.9,
	MissFireRate = 1.1 }
local ROUNDCFG = (Config and Config.Round) or {}
local CODES = (Config and Config.Codes) or {}
local MATCH = (Config and Config.Matchmaking) or {}

if not DS then
	note("DeagleShared missing - wall check falls back to a plain ray")
end

--------------------------------------------------------------------------------
-- combatants
--------------------------------------------------------------------------------
--
-- The list is built from TWO sources and neither one alone is enough. Real
-- players come from the Players service; bots do not appear there at all and are
-- direct children of workspace carrying `IsBot`. Measured on a live server:
-- 1 player object, 8 character models.
--
-- Rebuilt on a short timer rather than per frame. workspace has ~20 direct
-- children so the walk is cheap, but the render pass, the aim pass and the
-- trigger loop all want the same list and there is no reason to build it three
-- times in one frame.

local combatCache, combatAt = {}, 0

local function combatants()
	local now = os.clock()
	if now - combatAt < 0.2 then return combatCache end
	combatAt = now

	local list = {}
	local mine = plr.Character

	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= plr then
			local char = p.Character
			if char and char.Parent then
				list[#list + 1] = { model = char, name = p.Name, player = p, bot = false }
			end
		end
	end

	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and m ~= mine and m:GetAttribute("IsBot") == true then
			list[#list + 1] = { model = m, name = m.Name, player = nil, bot = true }
		end
	end

	combatCache = list
	return list
end

-- `Alive` is the game's own attribute and `DeagleShared` checks it before the
-- Humanoid, so this checks it in the same order. A body whose Alive is false is
-- filtered out of the bullet ray entirely, which means it is not cover either.
local function aliveOf(model)
	if not model or not model.Parent then return nil end
	if model:GetAttribute("Alive") == false then return nil end
	local hum = model:FindFirstChildWhichIsA("Humanoid")
	if not hum or hum.Health <= 0 then return nil end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	return hum.Health, hum.MaxHealth, root, hum
end

-- Spawn protection. `EffectsController.ProtectedPlayers` is the exact table the
-- client's own Shoot() consults before it reports a hit, so it is the truth; the
-- character attribute is the same thing replicated and is the fallback. Firing at
-- a protected player is not a miss you get away with - it starts the full 1.1s
-- MissFireRate cooldown for nothing.
local function protectedOf(model)
	if not model then return false end
	if model:GetAttribute("SpawnProtection") == true then return true end
	local tbl = EffectsCtl and EffectsCtl.ProtectedPlayers
	if type(tbl) == "table" and tbl[model] == true then return true end
	return false
end

local function ragdolled(model)
	return model and model:GetAttribute("Ragdolled") == true
end

--------------------------------------------------------------------------------
-- hitboxes
--------------------------------------------------------------------------------
--
-- The game's own valid-hit list, read out of DeagleController's constant pool:
--   { "HeadHitbox", "BodyHitbox", "Head", "UpperTorso", "Torso", "HumanoidRootPart" }
--
-- Measured sizes on a live bot: HeadHitbox 3.234 x 3.247 x 3.234 (a cube around
-- the visual head, which is itself only 1.17), BodyHitbox 4.771 x 4.590 x 2.203.
-- Both are Transparency 1, CanCollide false, CanQuery TRUE, so both stop the ray.
--
-- Damage is a flat 100 either way, so the body is simply the bigger target for
-- the same payoff. That is not an opinion about playstyle, it is the config.

local HIT_PARTS = { "HeadHitbox", "BodyHitbox", "Head", "UpperTorso", "Torso",
	"HumanoidRootPart" }
local HEAD_PARTS = { HeadHitbox = true, Head = true }

local function bodyPart(model)
	return model:FindFirstChild("BodyHitbox")
		or model:FindFirstChild("UpperTorso")
		or model:FindFirstChild("HumanoidRootPart")
end

local function headPart(model)
	return model:FindFirstChild("HeadHitbox")
		or model:FindFirstChild("Head")
		or bodyPart(model)
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
-- line of sight - the game's own bullet
--------------------------------------------------------------------------------
--
-- DeagleShared.Raycast(shooter, from, to) is what the shot itself calls. It casts
-- 600 studs along the direction, in up to 8 passes, skipping the shooter, every
-- Accessory of every living character, every dead body and everything tagged or
-- named InvisiblePart. So this answers "would a bullet get there" exactly, with
-- no ignore list of our own and no clip-brush trap - the failure mode that made
-- every enemy in Counter Blox read as behind a wall.
--
-- 600 is also the hard range: past it the ray simply returns nothing, so no
-- target beyond 600 studs is hittable at all.

local RANGE = 600

local fallbackParams = RaycastParams.new()
fallbackParams.FilterType = Enum.RaycastFilterType.Exclude
fallbackParams.IgnoreWater = true

local function bulletRay(toPos)
	local origin = camera.CFrame.Position
	if DS then
		local ok, hit = pcall(DS.Raycast, plr.Character, origin, toPos)
		if ok then return hit end
	end
	-- Only reached if the shared module could not be required. Worse, and it says
	-- so in the panel rather than pretending otherwise.
	fallbackParams.FilterDescendantsInstances = { plr.Character }
	local dir = toPos - origin
	if dir.Magnitude < 0.05 then return nil end
	return workspace:Raycast(origin, dir.Unit * RANGE, fallbackParams)
end

local function charFromHit(inst)
	if not inst then return nil end
	if DS then
		local ok, model = pcall(DS.GetCharacterFromHit, inst)
		if ok then return model end
	end
	local node = inst
	while node and node ~= workspace do
		if node:IsA("Model") and node:FindFirstChildWhichIsA("Humanoid") then return node end
		node = node.Parent
	end
	return nil
end

local function visibleTo(model, part)
	if not part then return false end
	local hit = bulletRay(part.Position)
	if not hit then return false end
	return charFromHit(hit.Instance) == model
end

-- Where the shot actually goes. The client aims at Mouse.GetMousePos(), which is
-- a WORLD point rather than a screen one - verified: camera at (-70, 13, 654),
-- mouse point at (-37, 8, 630), i.e. the surface under the cursor. Testing the
-- centre of the screen instead would answer a different question on any frame the
-- cursor is not locked dead centre.
local function aimWorldPoint()
	if MousePkg and MousePkg.GetMousePos then
		local ok, pos = pcall(MousePkg.GetMousePos)
		if ok and typeof(pos) == "Vector3" then return pos end
	end
	local cf = camera.CFrame
	return cf.Position + cf.LookVector * 1000
end

--------------------------------------------------------------------------------
-- shot state
--------------------------------------------------------------------------------
--
-- Read from DeagleController rather than counted. `CanShoot` is false for the
-- whole reload, `ShootCooldownUntil` is an os.clock() stamp, `InGame` is false in
-- the menu and between rounds, `IsAiming` is the real ADS flag. Counting shots
-- from a fire rate - which counterblox had to do - would be strictly worse here.

-- The real cooldown for this account, not the config default. Skins carry a
-- ReloadMultiplier and the round modifier `RoundFastReload` halves it.
local function reloadTimes()
	local mult = 1
	local char = plr.Character
	local deagle = char and char:FindFirstChild("Deagle")
	local skinName = deagle and deagle:GetAttribute("DeagleSkinName")
	if skinName and type(Skins) == "table" then
		local skin = Skins[skinName]
		if type(skin) == "table" and tonumber(skin.ReloadMultiplier) then
			mult = tonumber(skin.ReloadMultiplier)
		end
	end
	if plr:GetAttribute("RoundFastReload") == true then mult = mult * 0.5 end
	local hit  = (tonumber(DEAGLE.HitFireRate) or 0.9) * mult
	local miss = (tonumber(DEAGLE.MissFireRate) or 1.1) * mult
	return hit, miss, mult
end

-- THE SHOT WATCHER, and it does more than count.
--
-- `ShootCooldownUntil` looks like the field to read and it is NOT: the client
-- only stamps it in RecoverAfterInterruption (+0.1s), while a normal shot clears
-- `CanShoot`, waits the reload out in its own thread and sets it back. So the
-- stamp reads 0 almost all of the time and a cooldown built on it would report
-- "ready" through the entire reload.
--
-- What CanShoot going true -> false does give is the exact instant of every shot,
-- including the ones the player fires by hand. And the LENGTH of that false
-- window is HitFireRate (0.9s) after a hit and MissFireRate (1.1s) after a miss -
-- two values 200ms apart with nothing else able to produce them. So timing the
-- window is a hit/miss detector that needs no server value at all, and the panel
-- can show a real accuracy figure rather than a count of mouse clicks.
local shotAt, shotArmed = 0, false

local function shotWatch()
	if not DeagleCtl then return end
	local can = DeagleCtl.CanShoot == true
	if shotArmed and not can then
		-- fired
		shotAt = os.clock()
		shotArmed = false
		STATE.shots = STATE.shots + 1
	elseif can and not shotArmed then
		if shotAt > 0 then
			local took = os.clock() - shotAt
			local hit, miss = reloadTimes()
			-- Halfway between the two is the only sensible cut, and anything wildly
			-- outside both is a respawn or a weapon swap rather than a shot.
			if took < (hit + miss) / 2 then
				STATE.hits = STATE.hits + 1
			elseif took <= miss * 1.6 then
				STATE.misses = STATE.misses + 1
			end
			STATE.lastShotMs = took * 1000
		end
		shotArmed = true
	end
end

local function shotReady()
	if not DeagleCtl then return true end
	if DeagleCtl.InGame ~= true then return false end
	if DeagleCtl.CanShoot == false then return false end
	local until_ = tonumber(DeagleCtl.ShootCooldownUntil) or 0
	return os.clock() >= until_
end

-- Seconds until the gun can fire again. Derived from the shot instant and the
-- account's own reload length, because the field that looks authoritative is not.
local function cooldownLeft()
	if not DeagleCtl then return 0 end
	if DeagleCtl.CanShoot == false then
		local _, miss = reloadTimes()
		if shotAt <= 0 then return miss end
		return math.max(0, miss - (os.clock() - shotAt))
	end
	local until_ = tonumber(DeagleCtl.ShootCooldownUntil) or 0
	return math.max(0, until_ - os.clock())
end

local function firedRecently(within)
	return shotAt > 0 and (os.clock() - shotAt) < (within or 0.35)
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
if _G.__DEAGLE_POOL then
	for _, obj in ipairs(_G.__DEAGLE_POOL) do pcall(function() obj:Remove() end) end
end
_G.__DEAGLE_POOL = pool

local function make(kind, props)
	local obj = Drawing.new(kind)
	obj.Visible = false
	for k, v in pairs(props or {}) do obj[k] = v end
	table.insert(pool, obj)
	return obj
end

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

-- Keyed by the character MODEL, not by a Player: bots have no Player object at
-- all, so a Players-keyed pool would draw nothing for seven of the eight targets
-- on a normal server.
local function objectsFor(model)
	local set = drawn[model]
	if set then return set end
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
		hbBody  = make("Square", { Thickness = 1, Filled = false, ZIndex = 2,
			Transparency = 0.55 }),
		hbHead  = make("Square", { Thickness = 1, Filled = false, ZIndex = 2,
			Transparency = 0.55 }),
		bones   = {},
	}
	for i = 1, #BONES do
		set.bones[i] = make("Line", { Thickness = 1, ZIndex = 2 })
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
	set.hbBody.Visible  = false
	set.hbHead.Visible  = false
	for _, line in ipairs(set.bones) do line.Visible = false end
end

local function hideAll()
	for _, set in pairs(drawn) do hideSet(set) end
end

--------------------------------------------------------------------------------
-- chams
--------------------------------------------------------------------------------
--
-- This game already parents a Highlight into every character itself, so an extra
-- one in the model would be indistinguishable from the game's own AND would sit
-- in the tree where a client script can walk onto it. Ours goes to
-- gethui()/CoreGui with an Adornee: identical rendering, not in the game tree.

-- WHERE the Highlight lives is not a detail, and getting it wrong took the whole
-- ESP down rather than just the chams.
--
-- Parenting into gethui() is the right answer when it is allowed: the instance is
-- then outside the game tree where no client script can walk onto it. But it is
-- not always allowed. Loaded through `bridge.py file` the chunk runs with reduced
-- capabilities, and `hl.Parent = <folder under gethui()>` threw
-- "The current thread cannot access 'Instance' (lacking capability Plugin)".
--
-- The bug that made that expensive was not the throw, it was WHERE it was caught:
-- nowhere. chamFor is called from the middle of the per-target loop in
-- renderPass, so one failing Highlight aborted the entire render pass and the
-- box, the name, the distance and everything else stopped drawing with it. That
-- is exactly what it looked like from the outside - reported as "after switching
-- from the lobby into a round the ESP stops working and you have to toggle it off
-- and on again", because switching in brings new characters, which is the first
-- time chamFor is called for them, and toggling chams off is what let the pass
-- finish again.
--
-- So: the container is resolved once with fallbacks, every instance touch is
-- guarded, and a failure disables the chams and SAYS SO on the panel instead of
-- taking the drawings with it.
local chamsFolder = nil
local chamsBroken = nil     -- nil = untried, string = why it is off

-- EVERY instance touch in here is inside a pcall, including the ones that look
-- harmless. Reading `.Parent` of a Folder that lives under gethui() throws
-- exactly like parenting into it does, and `gethui()` itself can throw - so a
-- guard that only wraps the create call still lets the error out through its own
-- freshness check. That is how the first version of this fix still took the
-- render pass down.
--
-- The candidate list is built by APPENDING rather than as a table literal:
-- `{ (gethui and gethui()) or nil, CoreGui }` is the nil-hole trap - on an
-- executor with no gethui the table is `{nil, CoreGui}` and ipairs stops at the
-- hole, so CoreGui would never be tried.
local function chamsAlive()
	local ok, alive = pcall(function()
		return chamsFolder ~= nil and chamsFolder.Parent ~= nil
	end)
	return ok and alive == true
end

local function chamsRoot()
	if chamsAlive() then return chamsFolder end
	if chamsBroken then return nil end

	local roots = {}
	local ok, hidden = pcall(function() return gethui and gethui() or nil end)
	if ok and hidden then roots[#roots + 1] = hidden end
	roots[#roots + 1] = CoreGui

	for _, root in ipairs(roots) do
		local made = nil
		pcall(function()
			local previous = root:FindFirstChild("SeluxDeagleChams")
			if previous then previous:Destroy() end
			local folder = Instance.new("Folder")
			folder.Name = "SeluxDeagleChams"
			folder.Parent = root
			made = folder
		end)
		if made then
			chamsFolder = made
			chamsBroken = nil
			return chamsFolder
		end
	end

	chamsBroken = "no container this executor will accept"
	return nil
end

pcall(chamsRoot)   -- eager, so a broken executor is known before the first frame

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

-- Returns nil rather than throwing. Every caller has to cope with nil, which is
-- the whole point: no cham is worth losing the box over.
local function chamFor(model)
	local hl = highlights[model]
	if hl then
		-- same trap as chamsAlive: this read can throw on its own
		local ok, alive = pcall(function() return hl.Parent ~= nil end)
		if ok and alive then return hl end
	end
	if chamsBroken then return nil end
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
		chamsBroken = tostring(err):sub(1, 60)
		note("chams off: " .. tostring(chamsBroken))
		return nil
	end
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
local silentCircle = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Transparency = 0.55, ZIndex = 1 })

local crossLines = {}
for i = 1, 4 do
	crossLines[i] = make("Line", { Thickness = 1, ZIndex = 4 })
end
local crossDot = make("Circle", { Filled = true, NumSides = 8, Radius = 1, ZIndex = 4 })

local cdBg = make("Square", { Filled = true, ZIndex = 4, Color = COLOUR.black,
	Transparency = 0.5 })
local cdBar = make("Square", { Filled = true, ZIndex = 5 })

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

-- The one number this game is actually played on. A miss costs 1.1s and a hit
-- 0.9s, so "can I shoot yet" is the whole tempo of a duel and the HUD shows it
-- only as a reload animation on the viewmodel.
local function drawCooldown(mid)
	local show = CONFIG.cooldownBar and DeagleCtl ~= nil and DeagleCtl.InGame == true
	cdBg.Visible = show
	cdBar.Visible = show
	if not show then return end
	local hit, miss = reloadTimes()
	local span = math.max(hit, miss)
	local frac = math.clamp(cooldownLeft() / span, 0, 1)
	local w, h = 120, 4
	local x, y = mid.X - w / 2, mid.Y + 26
	cdBg.Position = Vector2.new(x, y)
	cdBg.Size     = Vector2.new(w, h)
	cdBar.Position = Vector2.new(x, y)
	cdBar.Size     = Vector2.new(w * (1 - frac), h)
	cdBar.Color = (frac <= 0) and COLOUR.hpGood or Color3.fromRGB(255, 170, 60)
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
	if _G.__DEAGLE ~= GEN then return end

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
	-- Drawn whenever the silent shot is armed in FOV mode, because the circle IS
	-- the feature there - it is the only thing on screen that says how wide the
	-- thing currently reaches.
	silentCircle.Visible = CONFIG.silent and CONFIG.silentCircle
		and CONFIG.silentMode == "FOV"
	if silentCircle.Visible then
		silentCircle.Position = mid
		silentCircle.Radius = CONFIG.silentFov
		silentCircle.Color = CONFIG.colSilent
	end

	drawCrosshair(mid)
	drawCooldown(mid)

	if CONFIG.fovChange then
		pcall(function() camera.FieldOfView = CONFIG.fovValue end)
	end

	if not anyDrawing() then
		hideAll()
		clearChams()
		STATE.targets, STATE.bots, STATE.humans = 0, 0, 0
		return
	end

	local vp = camera.ViewportSize
	local camPos = camera.CFrame.Position
	local count, bots, humans = 0, 0, 0
	local face = fontId()
	local seenModels = {}

	for _, entry in ipairs(combatants()) do
		local model = entry.model
		seenModels[model] = true
		local set = objectsFor(model)
		local hp, maxHp, root = aliveOf(model)

		if not hp and CONFIG.deadESP and model.Parent then
			local r = model:FindFirstChild("HumanoidRootPart")
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
				local prot = protectedOf(model)
				local aimPart = bodyPart(model)
				local seen = true
				if CONFIG.visCheck then
					seen = visibleTo(model, headPart(model)) or visibleTo(model, aimPart)
				end

				local base = entry.bot and CONFIG.colBot or CONFIG.colEnemy
				if prot and CONFIG.protTag then base = CONFIG.colProt end
				local col = seen and base or dimmed(base)
				local outOfRange = dist > RANGE

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
					if hl and not CONFIG.chams then
						pcall(function() hl.Enabled = false end)
					end
				else
					count = count + 1
					if entry.bot then bots = bots + 1 else humans = humans + 1 end

					local pos = Vector2.new(minX, minY)
					local siz = Vector2.new(w, h)

					if CONFIG.aimingWarn and model:GetAttribute("BotAiming") == true then
						col = Color3.fromRGB(255, 225, 90)
					end

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

					set.hpBg.Visible = CONFIG.health
					set.hp.Visible   = CONFIG.health
					if CONFIG.health then
						local frac = math.clamp(hp / math.max(maxHp, 1), 0, 1)
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
						if CONFIG.botTag then
							label = (entry.bot and "[BOT] " or "[P] ") .. label
						end
						if CONFIG.streakTag and model:GetAttribute("HasStreak") == true then
							label = label .. " *"
						end
						set.name.Size = ts
						set.name.Font = face
						set.name.Outline = CONFIG.textOutline
						set.name.Position = Vector2.new(minX + w / 2, minY - (ts + 3))
						set.name.Text = label
						set.name.Color = col
					end

					local bits = {}
					if CONFIG.levelTag then
						local lvl = model:GetAttribute("BotLevel")
						local elo = model:GetAttribute("Elo")
						if lvl then table.insert(bits, "lv" .. tostring(lvl))
						elseif elo then table.insert(bits, tostring(elo) .. "elo") end
					end
					if CONFIG.distance then
						-- The marker is the point of drawing him at all: 700 studs away is
						-- worth knowing about and is not worth shooting at.
						table.insert(bits, string.format("%dm%s", math.floor(dist),
							(outOfRange and CONFIG.rangeTag) and " !" or ""))
					end
					if CONFIG.protTag and prot then table.insert(bits, "PROT") end
					if CONFIG.health and hp then
						table.insert(bits, string.format("%d", math.floor(hp)))
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

					-- The real hitboxes, drawn as they are. Worth having on this game
					-- specifically: the body box is wider than the model and the head
					-- box is nearly three times the visual head, and seeing that once
					-- explains every "how did that hit" in the game.
					set.hbBody.Visible = false
					set.hbHead.Visible = false
					if CONFIG.hitboxDraw then
						local bh = model:FindFirstChild("BodyHitbox")
						if bh then
							local x, y, bw, bhh = screenRect(bh)
							if x then
								set.hbBody.Visible = true
								set.hbBody.Position = Vector2.new(x, y)
								set.hbBody.Size = Vector2.new(bw, bhh)
								set.hbBody.Color = CONFIG.colHitbox
							end
						end
						local hh = model:FindFirstChild("HeadHitbox")
						if hh then
							local x, y, hw, hhh = screenRect(hh)
							if x then
								set.hbHead.Visible = true
								set.hbHead.Position = Vector2.new(x, y)
								set.hbHead.Size = Vector2.new(hw, hhh)
								set.hbHead.Color = CONFIG.colHitbox
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

					-- Guarded twice on purpose: chamFor already returns nil instead
					-- of throwing, and the property writes are wrapped as well, because
					-- an Adornee whose model was destroyed between the two lines is a
					-- second way to lose the pass.
					if CONFIG.chams and not chamsBroken then
						local hl = chamFor(model)
						if hl then
							pcall(function()
								hl.Adornee = model
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

	-- Bots are created and destroyed constantly, so a pool keyed by model would
	-- grow without bound and keep drawing the last frame of a model that is gone.
	for model, set in pairs(drawn) do
		if not seenModels[model] or not model.Parent then
			hideSet(set)
			if not model.Parent then
				local hl = highlights[model]
				if hl then pcall(function() hl:Destroy() end) highlights[model] = nil end
				drawn[model] = nil
			end
		end
	end

	STATE.targets, STATE.bots, STATE.humans = count, bots, humans
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
	if _G.__DEAGLE ~= GEN or not capturing or armedGuard then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if input.KeyCode == Enum.KeyCode.Escape then capture(nil) return end
	if input.KeyCode == Enum.KeyCode.Unknown then return end
	capture(input.KeyCode.Name)
end)

UserInputService.InputEnded:Connect(function(input)
	if _G.__DEAGLE ~= GEN or not capturing or armedGuard then return end
	local name = input.UserInputType.Name
	if name:sub(1, 11) ~= "MouseButton" then return end
	capture(name)
end)

local function firing()
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
end

local panicHandlers = {}

UserInputService.InputBegan:Connect(function(input, processed)
	if _G.__DEAGLE ~= GEN or processed or capturing then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local spec = resolveKey(CONFIG.panicKey)
	if not spec or not spec.key or input.KeyCode ~= spec.key then return end
	CONFIG.aim, CONFIG.trig, CONFIG.aimFire = false, false, false
	for _, fn in ipairs(panicHandlers) do pcall(fn) end
	note("PANIC - aim, trigger and auto fire off")
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
-- the drift is smooth - random per frame is a vibration, which looks less human
-- than no jitter at all.
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

local function panelOpen()
	local win = _G.__DEAGLE_WIN
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
	local on = DeagleCtl and DeagleCtl.IsAiming == true
	if mode == "Scoped only" then return on end
	return not on
end

local function movingFrac()
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return 0 end
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local hum = char:FindFirstChildWhichIsA("Humanoid")
	local maxSpeed = (hum and hum.WalkSpeed) or 25
	return math.clamp(speed / math.max(maxSpeed, 1), 0, 1)
end

local function eligible(entry)
	if CONFIG.humBotOnly and not entry.bot then return false end
	if ragdolled(entry.model) then return false end
	return true
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
		if eligible(entry) then
			local hp, _, root = aliveOf(entry.model)
			if hp then
				local prot = protectedOf(entry.model)
				if not (CONFIG.aimSkipProt and prot) then
					local part = targetPart(entry.model)
					local dist = (camPos - root.Position).Magnitude
					if part and dist <= math.min(CONFIG.aimMaxDist, RANGE) then
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
-- MEASURED HERE, and it is the opposite of BloxStrike. At
-- RenderPriority.Camera + 1 with CameraType.Custom, a 15 deg yaw write read
-- 0.00 deg against the wanted CFrame and 15.00 deg against the previous one two
-- RenderStepped later. The game's camera controller does not rebuild the CFrame
-- out of angles it keeps itself, so a write is not thrown away.
--
-- The mouse path is still here as a dropdown, for two reasons: it is what a
-- future update turning the controller authoritative would need, and it is the
-- path that produces a real hardware-shaped input trace. It learns the player's
-- sensitivity rather than assuming it - each frame records what it asked for and
-- the next one measures what happened.

local mouseMove = mousemoverel or (Input and Input.mousemoverel)
	or (syn and syn.mousemoverel)

local look = {
	degPerPxX = 0.06, degPerPxY = 0.05,
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
	if _G.__DEAGLE ~= GEN then return end
	aimWroteView = false
	STATE.aimDps = 0

	local blocked = assistBlocked()
	STATE.paused = blocked or ""
	if blocked then
		STATE.target, STATE.targetKind = "-", "-"
		stickyModel = nil
		endEngagement()
		return
	end

	-- Each gate names ITSELF in the readout. With one shared early return the
	-- panel shows an armed aim, a visible target 52 px off the crosshair and a
	-- camera that never moves, and nothing anywhere says which rule stopped it.
	if not aimActive() then
		STATE.target, STATE.targetKind = "-", "-"
		stickyModel = nil
		if engagement then endEngagement() end
		return
	end
	if DeagleCtl and DeagleCtl.InGame ~= true then
		STATE.paused = "not deployed"
		STATE.target = "-"
		stickyModel = nil
		if engagement then endEngagement() end
		return
	end
	if CONFIG.aimReady and not shotReady() then
		STATE.paused = "reloading"
		return
	end
	if not adsGate(CONFIG.aimAds) then
		STATE.paused = "scope condition"
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
		local hp = aliveOf(stickyModel)
		if hp and not (CONFIG.aimSkipProt and protectedOf(stickyModel)) then
			local part = targetPart(stickyModel)
			if part then
				local sp = camera:WorldToViewportPoint(part.Position)
				local px = (Vector2.new(sp.X, sp.Y) - centreOf()).Magnitude
				if sp.Z > 0 and px <= CONFIG.aimFov * 1.35
					and ((not CONFIG.aimVisible) or visibleTo(stickyModel, part)) then
					pick = {
						entry = { model = stickyModel, name = stickyModel.Name,
							bot = stickyModel:GetAttribute("IsBot") == true },
						part = part, px = px,
					}
				end
			end
		end
	end
	pick = pick or pickTarget()

	if not pick or not pick.part or not pick.part.Parent then
		STATE.target, STATE.targetKind = "-", "-"
		stickyModel = nil
		if engagement then endEngagement() end
		return
	end

	-- The switch lock, checked BEFORE the engagement is replaced: a different
	-- target cannot take over until the current one has been held for
	-- humSwitchMs, unless it is gone.
	if engagement and engagement.model ~= pick.entry.model and CONFIG.hum
		and os.clock() < engagement.lockUntil and aliveOf(engagement.model) then
		local heldPart = targetPart(engagement.model)
		if heldPart then
			pick = {
				entry = { model = engagement.model, name = engagement.name,
					bot = engagement.model:GetAttribute("IsBot") == true },
				part = heldPart, px = pick.px,
			}
		end
	end

	if not engagement or engagement.model ~= pick.entry.model then
		newEngagement(pick.entry.model, pick.entry.name)
	end
	rerollOffset()
	stickyModel = pick.entry.model
	STATE.target = pick.entry.name
	STATE.targetKind = pick.entry.bot and "bot" or "player"

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
	-- The head is not worth more damage in this game, so the humaniser's head
	-- share works the other way round from the other shooters here: it lets an
	-- engagement go for the head sometimes so the headshot count is not a flat
	-- zero, rather than capping it so it is not a flat hundred.
	local part = pick.part
	if CONFIG.hum and engagement.head and CONFIG.aimPart == "Body" then
		part = headPart(pick.entry.model) or part
	end
	local dist = (pos - part.Position).Magnitude
	local aimAt = humanAimPoint(part, dist)

	if CONFIG.hum and engagement.over
		and (now - engagement.t0) < engagement.windup + 0.09 then
		local side = (engagement.ox >= 0) and 1 or -1
		aimAt = aimAt + cf.RightVector * side * math.rad(CONFIG.humOverDeg) * dist
	end

	local curPitch, curYaw = cf:ToOrientation()
	learnSensitivity(curYaw, curPitch)
	local want = CFrame.lookAt(pos, aimAt)
	local wantPitch, wantYaw = want:ToOrientation()

	local dYaw = angleDelta(curYaw, wantYaw)
	local dPitch = angleDelta(curPitch, wantPitch)

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
end

--------------------------------------------------------------------------------
-- recoil, measured only
--------------------------------------------------------------------------------
--
-- There is deliberately NO recoil-control feature here, and this is the
-- measurement that says why rather than an assumption.
--
-- CameraController.Shoot does exactly one thing: `spring:AddVelocity(0.017)` on a
-- Spring.new(4, 12, 300, 0, 0, 0), whose Offset is then applied as pitch every
-- frame until it settles back to zero. There is no pattern table, no per-shot
-- index and no horizontal component at all, and with a 0.9-1.1s cooldown there is
-- no spray to walk down. So this pass only MEASURES: while not firing, the ratio
-- of camera movement to raw mouse movement is the effective sensitivity; while
-- firing, whatever is left after subtracting it is the kick. Both numbers are on
-- the AIM page so the claim can be checked instead of believed.

local mouseDX, mouseDY = 0, 0
UserInputService.InputChanged:Connect(function(input)
	if _G.__DEAGLE ~= GEN then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		mouseDX = mouseDX + input.Delta.X
		mouseDY = mouseDY + input.Delta.Y
	end
end)

local lastYaw, lastPitch = nil, nil
local sensPitch = 0

local function recoilWatch()
	if _G.__DEAGLE ~= GEN then return end
	local cf = camera.CFrame
	local pitch, yaw = cf:ToOrientation()
	local my = mouseDY
	mouseDX, mouseDY = 0, 0

	if lastYaw == nil then lastYaw, lastPitch = yaw, pitch return end
	local dPitch = pitch - lastPitch
	lastYaw, lastPitch = yaw, pitch

	-- "did we just fire" comes from the shot watcher, not from ShootCooldownUntil:
	-- that field is 0 for a normal shot, so a test against it never fires and the
	-- kick would read a flat zero forever.
	local recent = firedRecently(0.35)

	if not recent and not aimWroteView then
		if math.abs(my) > 2 then
			local s = -dPitch / my
			sensPitch = sensPitch == 0 and s or (sensPitch * 0.9 + s * 0.1)
			STATE.sens = sensPitch
		end
		STATE.kickNow = 0
		return
	end

	if aimWroteView or sensPitch == 0 then return end
	local residual = dPitch - (-sensPitch * my)
	STATE.kickNow = math.deg(residual)
	STATE.kickN = STATE.kickN + 1
	if math.abs(STATE.kickNow) > math.abs(STATE.kickPeak) then
		STATE.kickPeak = STATE.kickNow
	end
end

--------------------------------------------------------------------------------
-- silent shot
--------------------------------------------------------------------------------
--
-- This is the one place in the file that fires the shot remote instead of
-- pressing the mouse, and it is here because it was MEASURED to work rather than
-- assumed to.
--
-- What the client normally sends is
--   Network:FireServer("Shoot", cameraPosition, mouseWorldPoint, hitInstance, hitPosition)
-- where hitInstance and hitPosition come from the client's OWN raycast. The
-- server takes the reported part at face value: a shot naming a hitbox 64.6 deg
-- behind the camera killed, and so did one naming a hitbox 164 studs away behind
-- a wall - both confirmed on ClientData.Data.Kills, which is the server's total,
-- rather than on a client-side effect.
--
-- Three consequences worth being plain about:
--
--   * The camera is never touched, so there is nothing to see on a killcam as
--     camera movement - but the shot itself is as loud as any other, and a
--     server-side look at who died from where would find it at once. It ships
--     OFF and it is in none of the presets.
--   * The client's own DeagleController is not involved, so `CanShoot` never
--     goes false and `shotReady()` cannot pace this. The loop keeps its own
--     timer, and it has to: three shots 0.15s apart produced exactly one kill.
--   * Firing while the player also clicks WASTES shots - both land inside the
--     same cooldown and the server keeps one. The panel says so next to the
--     switch rather than leaving it to be discovered.

local silentNext = 0
local silentCursor = 0
local silentKillBase = nil

local function silentCandidates()
	local list = {}
	local camPos = camera.CFrame.Position
	local mid = centreOf()
	for _, e in ipairs(combatants()) do
		if eligible(e) then
			local hp = aliveOf(e.model)
			if hp and not (CONFIG.silentSkipProt and protectedOf(e.model)) then
				local part = (CONFIG.silentPart == "Head") and headPart(e.model)
					or bodyPart(e.model)
				if part then
					local dist = (camPos - part.Position).Magnitude
					if dist <= math.min(CONFIG.silentMaxDist, RANGE) then
						if (not CONFIG.silentVisible) or visibleTo(e.model, part) then
							local sp = camera:WorldToViewportPoint(part.Position)
							local px = 1e9
							if sp.Z > 0 then
								px = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
							end
							-- THE FOV GATE. In FOV mode a target has to be inside the
							-- circle on screen, exactly like an aim assist's window, and
							-- being behind the camera (sp.Z <= 0, px left at 1e9) fails it
							-- by itself. In "Any target" mode there is no gate at all.
							local passes = true
							if CONFIG.silentMode == "FOV" then
								passes = px <= CONFIG.silentFov
							end
							if passes then
								list[#list + 1] = { entry = e, part = part, dist = dist,
									px = px, hp = hp }
							end
						end
					end
				end
			end
		end
	end
	return list
end

local function silentPickOne(list)
	if #list == 0 then return nil end
	-- Cycling spreads the shots over everybody instead of emptying every cooldown
	-- into whoever happens to be nearest. A cursor rather than a shuffle, so
	-- nobody is skipped and nobody is shot twice while somebody else is untouched.
	if CONFIG.silentCycle then
		silentCursor = (silentCursor % #list) + 1
		return list[silentCursor]
	end
	local best, bestScore
	for _, c in ipairs(list) do
		local score
		if CONFIG.silentPick == "Closest" then score = c.dist
		elseif CONFIG.silentPick == "Lowest HP" then score = c.hp
		else score = c.px end
		if not bestScore or score < bestScore then best, bestScore = c, score end
	end
	return best
end

local function silentFire(part)
	if not Network then
		STATE.silentNote = "Network module missing"
		return false
	end
	local origin = camera.CFrame.Position
	local ok = pcall(function()
		Network:FireServer("Shoot", origin, part.Position, part, part.Position)
	end)
	return ok
end

task.spawn(function()
	claimIdentity()
	while _G.__DEAGLE == GEN do
		local ok, err = pcall(function()
			if not CONFIG.silent then
				STATE.silentOn = false
				STATE.silentTarget = "-"
				silentKillBase = nil
				return
			end
			local blocked = assistBlocked()
			if blocked then
				STATE.silentOn = false
				STATE.silentNote = blocked
				return
			end
			if DeagleCtl and DeagleCtl.InGame ~= true then
				STATE.silentOn = false
				STATE.silentNote = "not deployed"
				return
			end
			local armed = (CONFIG.silentActive == "Always") or keyHeld(CONFIG.silentKey)
			if not armed then
				STATE.silentOn = false
				STATE.silentTarget = "-"
				STATE.silentNote = "waiting for " .. keyDisplay(CONFIG.silentKey)
				return
			end
			STATE.silentOn = true

			-- Kills gained while this was armed. Not a counter the script increments
			-- for itself: it is the server's own total read through the oracle, so it
			-- cannot report a kill that did not happen.
			if silentKillBase == nil then
				local n = ClientData and ClientData.Data and ClientData.Data.Kills
				silentKillBase = tonumber(n) or 0
			end

			local now = os.clock() * 1000
			if now < silentNext then
				STATE.silentNote = string.format("%.0fms to go", silentNext - now)
				return
			end

			local list = silentCandidates()
			STATE.silentSeen = #list
			local pick = silentPickOne(list)
			if not pick then
				STATE.silentTarget = "-"
				STATE.silentNote = "no target in range"
				return
			end
			STATE.silentTarget = pick.entry.name
				.. (pick.entry.bot and "  (bot)" or "  (player)")

			if math.random(100) > CONFIG.silentHitPct then
				silentNext = now + CONFIG.silentGapMs
				STATE.silentNote = "skipped on purpose"
				return
			end

			local lo = math.min(CONFIG.silentDelayMin, CONFIG.silentDelayMax)
			local hi = math.max(CONFIG.silentDelayMin, CONFIG.silentDelayMax)
			if hi > 0 then
				local wait
				if CONFIG.hum then
					wait = gauss((lo + hi) / 2, math.max(1, CONFIG.humReactSd))
					wait = math.clamp(wait, 0, hi + 60)
				else
					wait = math.random(lo, hi)
				end
				if wait > 0 then task.wait(wait / 1000) end
			end

			-- Re-check after the delay, exactly like the trigger: somebody else may
			-- have killed the target in the meantime, and naming a destroyed part
			-- spends the whole cooldown on nothing.
			if not pick.part.Parent or not aliveOf(pick.entry.model) then
				STATE.silentNote = "target gone before the shot"
				return
			end
			if CONFIG.silentSkipProt and protectedOf(pick.entry.model) then
				STATE.silentNote = "target became protected"
				return
			end

			if silentFire(pick.part) then
				STATE.silentShots = STATE.silentShots + 1
				STATE.silentNote = "fired at " .. pick.entry.name
			end
			silentNext = os.clock() * 1000 + CONFIG.silentGapMs
		end)
		if not ok then note("silent: " .. tostring(err)) end
		task.wait(0.03)
	end
end)

local function silentKillsSoFar()
	if silentKillBase == nil then return 0 end
	local n = ClientData and ClientData.Data and ClientData.Data.Kills
	return math.max(0, (tonumber(n) or 0) - silentKillBase)
end

--------------------------------------------------------------------------------
-- trigger
--------------------------------------------------------------------------------
--
-- Fires the REAL mouse button, so the game's own weapon code runs the shot
-- exactly as it would for a human. No remote is fired and no hit is fabricated.
--
-- The important gate here is not a delay, it is the COOLDOWN: clicking while
-- CanShoot is false does nothing at all, and clicking at a spawn-protected player
-- costs the full 1.1s miss cooldown for no possible reward.

local click = mouse1click or (Input and Input.LeftClick)
local press, release = mouse1press, mouse1release

local function pullTrigger()
	if click then click()
	elseif press and release then press() task.wait(0.02) release() end
end

-- What the shot would hit, asked the way the shot asks it: the game's own ray,
-- from the camera, towards the game's own aim point.
local function underCrosshair()
	local origin = camera.CFrame.Position
	local aimPt = aimWorldPoint()
	local dir = aimPt - origin
	if dir.Magnitude < 0.05 then return nil end

	local points = { aimPt }
	if CONFIG.trigFov > 0 then
		-- A single centre ray only ever works on a stationary target. The ring is
		-- built in SCREEN space and converted back, so the spacing is what the user
		-- set in pixels rather than a distance-dependent world offset.
		local mid = centreOf()
		local r = CONFIG.trigFov
		for i = 0, 5 do
			local a = math.rad(i * 60)
			local ray = camera:ViewportPointToRay(mid.X + math.cos(a) * r,
				mid.Y + math.sin(a) * r)
			table.insert(points, ray.Origin + ray.Direction * RANGE)
		end
	end

	for _, pt in ipairs(points) do
		local hit = bulletRay(pt)
		if hit and hit.Instance then
			local model = charFromHit(hit.Instance)
			if model and model ~= plr.Character then
				local hp = aliveOf(model)
				if hp and not ragdolled(model) then
					local isBot = model:GetAttribute("IsBot") == true
					if not (CONFIG.humBotOnly and not isBot) then
						if not (CONFIG.trigSkipProt and protectedOf(model)) then
							if (not CONFIG.trigHeadOnly) or HEAD_PARTS[hit.Instance.Name] then
								local dist = (origin - hit.Position).Magnitude
								if dist <= math.min(CONFIG.trigMaxDist, RANGE) then
									return model, hit.Instance, isBot
								end
							end
						end
					end
				end
			end
		end
	end
	return nil
end

local trigWasHeld = false

local function trigActive()
	if not CONFIG.trig then return false end
	if CONFIG.trigActive == "Always" then return true end
	return keyHeld(CONFIG.trigKey)
end

task.spawn(function()
	claimIdentity()
	local nextAt = 0
	while _G.__DEAGLE == GEN do
		local ok, err = pcall(function()
			-- Evaluated even when the trigger is not armed, purely so the panel can
			-- SHOW what is under the crosshair. Without it there is no way to tell
			-- "the key is not held" from "the ray never reaches the enemy".
			local seen, part = underCrosshair()
			if seen then
				STATE.underCross = seen.Name .. (part and ("  " .. part.Name) or "")
			else
				STATE.underCross = "-"
			end

			if assistBlocked() then STATE.trigOn = false return end

			local held = trigActive()
			if not held then
				trigWasHeld = false
				STATE.trigOn = false
				return
			end
			trigWasHeld = true
			STATE.trigOn = true

			if DeagleCtl and DeagleCtl.InGame ~= true then
				STATE.underCross = "-- not deployed"
				return
			end
			if not shotReady() then
				STATE.underCross = "-- cooldown"
				return
			end
			if not adsGate(CONFIG.trigAds) then
				STATE.underCross = "-- scope condition"
				return
			end

			local now = os.clock() * 1000
			if now < nextAt then return end
			if not seen then return end

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
			-- enemy was 90 ms ago, which on a strafing player is a miss - and a miss
			-- here is the expensive outcome, 1.1s against 0.9s.
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
	while _G.__DEAGLE == GEN do
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
			local hit = select(1, reloadTimes())
			nextAt = os.clock() * 1000 + hit * 1000 * 0.6
		end)
		if not ok then note("autofire: " .. tostring(err)) end
		task.wait(0.02)
	end
end)

-- A kill pauses the aim: staying glued to a corpse and then flicking off it is
-- the most obvious thing an assist can do. Health is the Humanoid here, and a
-- dying bot is destroyed rather than left lying, so a model going away while it
-- was the target counts as a kill too.
task.spawn(function()
	claimIdentity()
	local seen = setmetatable({}, { __mode = "k" })
	while _G.__DEAGLE == GEN do
		pcall(function()
			for _, entry in ipairs(combatants()) do
				local hp = aliveOf(entry.model) or 0
				local was = seen[entry.model]
				if was and was > 0 and hp <= 0 and entry.model == stickyModel then
					lastKillAt = os.clock() * 1000
					stickyModel = nil
					endEngagement()
				end
				seen[entry.model] = hp
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
-- Round state is the player attribute `InRound` plus `ClientData.RoundOnGoing`;
-- the countdown itself is only in the HUD label. The round flipping is a reason
-- to sit still for a moment - everybody is spawning and spawn protection is on
-- for 2.2s anyway (3s for a new player, 2s for a bot), so nothing is worth
-- assisting.

plr:GetAttributeChangedSignal("InRound"):Connect(function()
	if _G.__DEAGLE ~= GEN then return end
	STATE.inRound = plr:GetAttribute("InRound") == true
	if CONFIG.hum and CONFIG.humRoundMs > 0 then
		pauseFor(CONFIG.humRoundMs, "round change")
	end
	stickyModel = nil
	endEngagement()
end)

local timerLabel = nil

local function readTimer()
	if timerLabel and timerLabel.Parent then return timerLabel.Text end
	local gui = plr:FindFirstChild("PlayerGui")
	local main = gui and gui:FindFirstChild("MainGui")
	local tg = main and main:FindFirstChild("TimerGui")
	timerLabel = tg and tg:FindFirstChild("TimerText")
	return timerLabel and timerLabel.Text or "-"
end

--------------------------------------------------------------------------------
-- the frame bindings
--------------------------------------------------------------------------------
--
-- Two of them on purpose. The aim step has to run after the game's own camera
-- code or it is simply overwritten, and the ESP wants to run after the camera has
-- settled for this frame or the boxes trail the view by one frame.

for _, name in ipairs({ "SeluxDeagleAim", "SeluxDeagleESP" }) do
	pcall(function() RunService:UnbindFromRenderStep(name) end)
end

-- Bound from a thread that has already yielded, for the same reason every loop
-- above starts with claimIdentity(). A render-step callback registered from the
-- thread this file is executed on inherits that thread's context, and loaded
-- through the bridge that context may not touch an Instance: the ESP pass died
-- every frame with "lacking capability Plugin" and drew nothing, while the same
-- code called by hand a second later worked. One task.spawn + one yield before
-- the two Bind calls removes it.
task.spawn(function()
claimIdentity()
if _G.__DEAGLE ~= GEN then return end

RunService:BindToRenderStep("SeluxDeagleAim", Enum.RenderPriority.Camera.Value + 1,
	function(dt)
		if _G.__DEAGLE ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxDeagleAim") end)
			return
		end
		local ok, err = pcall(function()
			shotWatch()
			aimPass(dt)
			recoilWatch()
		end)
		if not ok then note("aim: " .. tostring(err)) end
	end)

RunService:BindToRenderStep("SeluxDeagleESP", Enum.RenderPriority.Camera.Value + 2,
	function()
		if _G.__DEAGLE ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxDeagleESP") end)
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

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__DEAGLE_WIN then pcall(function() _G.__DEAGLE_WIN:Destroy() end) end
for _, root in ipairs({ (gethui and gethui()) or nil, CoreGui }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "DeagleArenaPanel" then pcall(function() g:Destroy() end) end
		end
	end
end

-- Merges the saved file into CONFIG BEFORE the panel is built - the controls read
-- their initial value out of CONFIG when they are created, so they come up on the
-- saved state by themselves.
UI.config("deaglearena", CONFIG)

local win = UI.Window({
	name = "DeagleArenaPanel",
	title = "DEAGLE", accentTitle = "ARENA", subtitle = "seltonmt",
	badge = "◎", width = 820, height = 582,
})
_G.__DEAGLE_WIN = win

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

local espPage = win:Page("ESP", UI.icon.eye)

do
local drawCard = espPage:Card("DRAWING", 1):Accent()
drawCard:Toggle("Box", CONFIG.box, function(v) CONFIG.box = v end,
	"projected head to feet, so it scales with range by itself", UI.theme.good)
drawCard:Toggle("Filled box", CONFIG.boxFilled, function(v) CONFIG.boxFilled = v end)
drawCard:Toggle("Name", CONFIG.name, function(v) CONFIG.name = v end)
drawCard:Toggle("Bot marker", CONFIG.botTag, function(v) CONFIG.botTag = v end,
	"[BOT] or [P] - this server fills up with bots and the HUD never says so",
	UI.theme.good)
drawCard:Toggle("Level / elo", CONFIG.levelTag, function(v) CONFIG.levelTag = v end,
	"bots publish BotLevel, players publish Elo")
drawCard:Toggle("Kill streak", CONFIG.streakTag, function(v) CONFIG.streakTag = v end,
	"a * after the name means they are on a streak")
drawCard:Toggle("Spawn protection", CONFIG.protTag, function(v) CONFIG.protTag = v end,
	"greys them out - shooting them only costs you 1.1s", UI.theme.warn)
drawCard:Toggle("Aiming at you", CONFIG.aimingWarn, function(v) CONFIG.aimingWarn = v end,
	"bots publish BotAiming while they are lining a shot up", UI.theme.warn)
drawCard:Toggle("Distance", CONFIG.distance, function(v) CONFIG.distance = v end)
drawCard:Toggle("Health bar", CONFIG.health, function(v) CONFIG.health = v end,
	"one shot is one kill here, so this is nearly always full")
drawCard:Toggle("Head dot", CONFIG.headDot, function(v) CONFIG.headDot = v end)
drawCard:Toggle("Skeleton", CONFIG.skeleton, function(v) CONFIG.skeleton = v end)
drawCard:Toggle("Tracer", CONFIG.tracer, function(v) CONFIG.tracer = v end)

local modeCard = espPage:Card("RANGE & VIEW", 2)
modeCard:Toggle("Wall check", CONFIG.visCheck, function(v) CONFIG.visCheck = v end,
	"uses the game's OWN bullet ray, so it answers exactly what a shot would do",
	UI.theme.good)
modeCard:Toggle("Draw the real hitboxes", CONFIG.hitboxDraw, function(v)
	CONFIG.hitboxDraw = v
end, "BodyHitbox 4.8x4.6x2.2 and HeadHitbox 3.2 cubed - both far bigger than the model",
	UI.theme.good)
modeCard:Toggle("Draw dead players", CONFIG.deadESP, function(v) CONFIG.deadESP = v end)
modeCard:Slider("Max distance", 100, 2500, CONFIG.maxDist, function(v)
	CONFIG.maxDist = v
end, "how far the ESP DRAWS - not the weapon range, which is 600")
modeCard:Toggle("Mark out of range", CONFIG.rangeTag, function(v) CONFIG.rangeTag = v end,
	"a ! after the distance means further than 600 studs, so unhittable",
	UI.theme.good)
modeCard:Slider("Text size", 12, 26, CONFIG.textSize, function(v) CONFIG.textSize = v end,
	"whole pixels; below 12 every Drawing face turns to mush")
modeCard:Dropdown("Font", FONTLIST, CONFIG.textFont, function(v) CONFIG.textFont = v end)
modeCard:Toggle("Text outline", CONFIG.textOutline, function(v) CONFIG.textOutline = v end)
modeCard:Toggle("Shrink with distance", CONFIG.textShrink, function(v)
	CONFIG.textShrink = v
end)

local colCard = espPage:Card("COLOURS", 1)
colCard:Colour("Real players", CONFIG.colEnemy, function(c) CONFIG.colEnemy = c end,
	"behind a wall the same colour is drawn at 55% brightness")
colCard:Colour("Bots", CONFIG.colBot, function(c) CONFIG.colBot = c end)
colCard:Colour("Spawn protected", CONFIG.colProt, function(c) CONFIG.colProt = c end)
colCard:Colour("Hitboxes", CONFIG.colHitbox, function(c) CONFIG.colHitbox = c end)
colCard:Colour("FOV circle", CONFIG.colFov, function(c) CONFIG.colFov = c end)

local chamCard = espPage:Card("CHAMS", 2)
chamCard:Toggle("Chams", CONFIG.chams, function(v)
	CONFIG.chams = v
	if not v then clearChams() end
end, "the game highlights everybody itself, so ours lives outside the game tree",
	UI.theme.warn)
chamCard:Label("If your executor refuses a Highlight outside the game tree, chams switch themselves off and the reason appears in the footer - the rest of the ESP keeps drawing.")
chamCard:Dropdown("Style", CHAM_LIST, CONFIG.chamStyle, function(v) CONFIG.chamStyle = v end)
chamCard:Toggle("Rainbow", CONFIG.chamRainbow, function(v) CONFIG.chamRainbow = v end)
chamCard:Toggle("Own cham colour", CONFIG.colChamOwn, function(v) CONFIG.colChamOwn = v end)
chamCard:Colour("Cham colour", CONFIG.colCham, function(c) CONFIG.colCham = c end)

local visCard = espPage:Card("CROSSHAIR & CAMERA", 0)
visCard:Toggle("Cooldown bar", CONFIG.cooldownBar, function(v) CONFIG.cooldownBar = v end,
	"the 0.9s / 1.1s shot timer under the crosshair - the tempo of the whole game",
	UI.theme.good)
visCard:Toggle("Custom crosshair", CONFIG.crosshair, function(v) CONFIG.crosshair = v end)
visCard:Slider("Length", 2, 30, CONFIG.crossSize, function(v) CONFIG.crossSize = v end)
visCard:Slider("Gap", 0, 20, CONFIG.crossGap, function(v) CONFIG.crossGap = v end)
visCard:Slider("Thickness", 1, 5, CONFIG.crossThick, function(v) CONFIG.crossThick = v end)
visCard:Toggle("Centre dot", CONFIG.crossDot, function(v) CONFIG.crossDot = v end)
visCard:Colour("Crosshair colour", CONFIG.colCross, function(c) CONFIG.colCross = c end)
visCard:Toggle("Field of view", CONFIG.fovChange, function(v)
	CONFIG.fovChange = v
	if not v then pcall(function() camera.FieldOfView = 76 end) end
end, "client side only - it changes what YOU see, nothing else", UI.theme.warn)
visCard:Slider("FOV", 60, 120, CONFIG.fovValue, function(v) CONFIG.fovValue = v end)
end

-- AIM --------------------------------------------------------------------------

local aimOut, recOut

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
aimCard:Label("Damage is a flat 100 and every character has 100 HP, so the head pays nothing extra. BodyHitbox is 4.8x4.6x2.2 against the head's 3.2 cube - the body is simply the bigger target for the same kill.")
reg("aimPart", aimCard:Dropdown("Aim at", { "Body", "Head", "Nearest" },
	CONFIG.aimPart, function(v) CONFIG.aimPart = v end))
aimCard:Dropdown("Pick target by", { "Crosshair", "Closest", "Lowest HP" },
	CONFIG.aimPick, function(v) CONFIG.aimPick = v end)
aimCard:Label("Travel curve: Human starts slow, is fastest mid-flick, settles slowly")
reg("aimCurve", aimCard:Dropdown("Travel curve", { "Ease out", "Linear", "Human" },
	CONFIG.aimCurve, function(v) CONFIG.aimCurve = v end))
aimCard:Label("View path: the camera write was measured to STICK in this game. Mouse is the fallback if an update ever changes that.")
aimCard:Dropdown("View path", { "Camera", "Mouse" }, CONFIG.aimPath,
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
tuneCard:Slider("Max distance", 50, 600, CONFIG.aimMaxDist, function(v)
	CONFIG.aimMaxDist = v
end, "the bullet ray stops at 600 studs whatever this says")
reg("aimVisible", tuneCard:Toggle("Visible only", CONFIG.aimVisible,
	function(v) CONFIG.aimVisible = v end,
	"never aims at somebody the bullet ray cannot reach", UI.theme.good))
tuneCard:Toggle("Sticky target", CONFIG.aimSticky, function(v)
	CONFIG.aimSticky = v
	stickyModel = nil
end, "holds one target instead of flicking to whoever is a pixel closer",
	UI.theme.good)
tuneCard:Toggle("Skip spawn protected", CONFIG.aimSkipProt, function(v)
	CONFIG.aimSkipProt = v
end, "the game's own shot ignores them, so aiming there is a wasted 1.1s",
	UI.theme.good)
tuneCard:Toggle("Only while the gun can fire", CONFIG.aimReady, function(v)
	CONFIG.aimReady = v
end, "reads DeagleController.CanShoot - no tracking during the reload")
tuneCard:Dropdown("Scope condition", { "Always", "Scoped only", "Not scoped" },
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

aimOut = aimPage:Card("TARGET", 2):Readout(7)
recOut = aimPage:Card("RECOIL - MEASURED ONLY", 0):Readout(7)
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
	"fires only on HeadHitbox or Head - costs kills, pays nothing extra here")
trigCard:Toggle("Skip spawn protected", CONFIG.trigSkipProt, function(v)
	CONFIG.trigSkipProt = v
end, "a shot at a protected player is a guaranteed 1.1s of nothing", UI.theme.good)
trigCard:Dropdown("Scope condition", { "Always", "Scoped only", "Not scoped" },
	CONFIG.trigAds, function(v) CONFIG.trigAds = v end)
trigCard:Label("The trigger reads DeagleController.CanShoot and ShootCooldownUntil, so it never clicks into a reload.")

local trigTime = trigPage:Card("TIMING", 2)
reg("trigDelayMin", trigTime:Slider("Reaction min (ms)", 0, 500, CONFIG.trigDelayMin,
	function(v) CONFIG.trigDelayMin = v end,
	"with the humaniser on this is a bell curve, not a flat band"))
reg("trigDelayMax", trigTime:Slider("Reaction max (ms)", 0, 500, CONFIG.trigDelayMax,
	function(v) CONFIG.trigDelayMax = v end))
reg("trigRefireMs", trigTime:Slider("Refire lockout (ms)", 20, 1000, CONFIG.trigRefireMs,
	function(v) CONFIG.trigRefireMs = v end,
	"the gun's own cooldown is 900-1100ms, so this only matters for the retry"))
reg("trigHitPct", trigTime:Slider("Hit chance %", 1, 100, CONFIG.trigHitPct,
	function(v) CONFIG.trigHitPct = v end))
trigTime:Slider("FOV (pixels)", 0, 60, CONFIG.trigFov, function(v) CONFIG.trigFov = v end,
	"0 = the exact aim ray only; above that a ring of six more")
trigTime:Slider("Max distance", 50, 600, CONFIG.trigMaxDist, function(v)
	CONFIG.trigMaxDist = v
end)

trigOut = trigPage:Card("STATUS", 1):Readout(6)
end

-- SILENT -----------------------------------------------------------------------

local silentOut, silentMeasOut

do
local silentPage = win:Page("SILENT", UI.icon.sword)

local sCard = silentPage:Card("SILENT SHOT", 1):Accent()
sCard:Label("This is the only feature in the panel that sends the shot itself instead of pressing the mouse. It was measured against the server's own kill counter, not assumed - the card on the right has the numbers. It ships off and no preset switches it on.")
reg("silent", sCard:Toggle("Silent shot", CONFIG.silent, function(v)
	CONFIG.silent = v
	note(v and "silent shot ARMED" or "silent shot off")
end, "kills without moving your view - the loudest thing in this panel",
	UI.theme.bad))
sCard:Label("FOV mode is the one most people mean by silent aim: the same pixel circle an aim assist uses, and whoever is inside it dies - it plays like an aimbot without the camera moving. Any target drops the circle, the angle and the wall check entirely.")
reg("silentMode", sCard:Dropdown("Mode", { "FOV", "Any target" }, CONFIG.silentMode,
	function(v) CONFIG.silentMode = v end))
reg("silentFov", sCard:Slider("FOV (pixels)", 5, 600, CONFIG.silentFov, function(v)
	CONFIG.silentFov = v
end, "FOV mode only - the circle around the crosshair a target has to be inside"))
sCard:Toggle("Draw the circle", CONFIG.silentCircle, function(v)
	CONFIG.silentCircle = v
end, "the circle IS the feature in FOV mode - it is the only thing that shows its reach",
	UI.theme.good)
sCard:Colour("Circle colour", CONFIG.colSilent, function(c) CONFIG.colSilent = c end)
sCard:Dropdown("Trigger", { "Hotkey", "Always" }, CONFIG.silentActive,
	function(v) CONFIG.silentActive = v end)
bindButton(sCard, "SILENT KEY", function() return CONFIG.silentKey end,
	function(v) CONFIG.silentKey = v end)
sCard:Label("Do not click while this is running: your own shot and its shot land inside the same cooldown and the server keeps one of them.")
sCard:Dropdown("Aim at", { "Body", "Head" }, CONFIG.silentPart,
	function(v) CONFIG.silentPart = v end)
sCard:Dropdown("Pick target by", { "Crosshair", "Closest", "Lowest HP" },
	CONFIG.silentPick, function(v) CONFIG.silentPick = v end)
sCard:Toggle("Cycle through everybody", CONFIG.silentCycle, function(v)
	CONFIG.silentCycle = v
end, "one shot each in turn instead of every shot at the nearest", UI.theme.warn)
sCard:Toggle("Skip spawn protected", CONFIG.silentSkipProt, function(v)
	CONFIG.silentSkipProt = v
end, "a protected target absorbs the shot and the cooldown with it", UI.theme.good)
sCard:Toggle("Visible only", CONFIG.silentVisible, function(v)
	CONFIG.silentVisible = v
end, "off by default because walls were measured NOT to matter to the server")
sCard:Toggle("Bots only", CONFIG.humBotOnly, function(v)
	CONFIG.humBotOnly = v
end, "the same switch as on the HUMAN page - never touches a real player",
	UI.theme.good)

local tCard = silentPage:Card("TIMING", 2)
tCard:Slider("Shot interval (ms)", 800, 3000, CONFIG.silentGapMs, function(v)
	CONFIG.silentGapMs = v
end, "the server enforces the gun's own 0.9s - three shots 0.15s apart gave one kill")
tCard:Slider("Delay min (ms)", 0, 400, CONFIG.silentDelayMin, function(v)
	CONFIG.silentDelayMin = v
end)
tCard:Slider("Delay max (ms)", 0, 600, CONFIG.silentDelayMax, function(v)
	CONFIG.silentDelayMax = v
end)
tCard:Slider("Hit chance %", 1, 100, CONFIG.silentHitPct, function(v)
	CONFIG.silentHitPct = v
end, "below 100 deliberately lets a cooldown pass without firing")
tCard:Slider("Max distance", 50, 600, CONFIG.silentMaxDist, function(v)
	CONFIG.silentMaxDist = v
end, "whether the server caps range beyond 600 was NOT measured - no target on this map was that far")

silentOut = silentPage:Card("STATUS", 1):Readout(8)
silentMeasOut = silentPage:Card("WHAT WAS MEASURED", 2):Readout(9)
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
preCard:Toggle("Bots only", CONFIG.humBotOnly, function(v)
	CONFIG.humBotOnly = v
	stickyModel = nil
end, "never assists against a real player - only against IsBot targets",
	UI.theme.good)

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
	"never the exact centre of the hitbox twice"))
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
	"aiming at the body every single time is its own pattern"))
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
safeCard:Slider("Quiet after round change (ms)", 0, 3000, CONFIG.humRoundMs,
	function(v) CONFIG.humRoundMs = v end,
	"everybody is spawning and protected for the first 2.2s anyway")
safeCard:Label("Panic key: switches aim, trigger and auto fire off at once")
bindButton(safeCard, "PANIC KEY", function() return CONFIG.panicKey end,
	function(v) CONFIG.panicKey = v end)
table.insert(panicHandlers, function()
	for _, key in ipairs({ "aim", "trig", "aimFire" }) do
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

roundOut = infoPage:Card("ROUND", 1):Readout(7)
statOut  = infoPage:Card("YOUR ACCOUNT", 2):Readout(8)
listOut  = infoPage:Card("TARGETS", 0):Readout(10, function(text)
	if text:find("%[BOT%]") then return Color3.fromRGB(255, 176, 60) end
	if text:find("%[P%]") then return Color3.fromRGB(255, 110, 120) end
	return nil
end)

local codeCard = infoPage:Card("CODES", 0)
codeCard:Label("The only remote this script ever fires, with the payload the game's own Claim button sends. Read out of Modules.Shared.Config.Codes - press once per code.")
for code, info in pairs(CODES) do
	local reward = ""
	if type(info) == "table" and type(info.Reward) == "table" then
		for k, v in pairs(info.Reward) do
			reward = reward .. (reward ~= "" and ", " or "") .. tostring(v) .. " " .. tostring(k)
		end
	end
	codeCard:Button(code .. (reward ~= "" and ("  -  " .. reward) or ""), function()
		if not Network then STATE.codeNote = "Network module missing" return end
		local ok = pcall(function() Network:FireServer("RedeemCode", code) end)
		STATE.codeNote = ok and (code .. " sent") or (code .. " failed")
		note(STATE.codeNote)
	end, UI.theme.band)
end
end

--------------------------------------------------------------------------------
-- the panel refresh
--------------------------------------------------------------------------------

local baseKills, baseDeaths = nil, nil

task.spawn(function()
	claimIdentity()
	while _G.__DEAGLE == GEN do
		local ok, err = pcall(function()
			STATE.inRound  = plr:GetAttribute("InRound") == true
			STATE.serverMode = tostring(plr:GetAttribute("ServerMode") or "-")
			STATE.inGame   = DeagleCtl and DeagleCtl.InGame == true or false
			STATE.canShoot = shotReady()
			STATE.cooldown = cooldownLeft()
			STATE.aiming   = DeagleCtl and DeagleCtl.IsAiming == true or false
			STATE.roundOn  = ClientData and ClientData.RoundOnGoing == true or false
			STATE.timer    = readTimer()

			local data = (ClientData and ClientData.Data) or {}
			STATE.kills     = tonumber(data.Kills) or 0
			STATE.deaths    = tonumber(data.Deaths) or 0
			STATE.elo       = tonumber(data.Elo) or 0
			STATE.rank      = tostring(data.Rank or "-")
			STATE.streak    = tonumber(data.Streak) or 0
			STATE.level     = tonumber(data.Level) or 0
			STATE.cash      = tonumber(data.Cash) or 0
			STATE.gems      = tonumber(data.Gems) or 0
			STATE.headshots = tonumber(data.Headshots) or 0
			STATE.wins      = tonumber(data.Wins) or 0
			STATE.matches   = tonumber(data.Matches) or 0

			-- The session counters are DIFFERENCES against the server's own totals,
			-- not something this script increments. A counter you increment yourself
			-- proves nothing; only a server value moving does.
			if baseKills == nil and STATE.kills > 0 then
				baseKills, baseDeaths = STATE.kills, STATE.deaths
			end
			if baseKills then
				STATE.sessionKills = STATE.kills - baseKills
				STATE.sessionDeaths = STATE.deaths - baseDeaths
			end


			local hit, miss, mult = reloadTimes()
			local camPos = camera.CFrame.Position

			local rows = {}
			for _, entry in ipairs(combatants()) do
				local hp, _, root = aliveOf(entry.model)
				local dist = root and math.floor((camPos - root.Position).Magnitude) or nil
				local lvl = entry.model:GetAttribute("BotLevel")
					or entry.model:GetAttribute("Elo") or "-"
				rows[#rows + 1] = {
					alive = hp ~= nil,
					dist = dist or 99999,
					line = string.format(" %-5s %-16s %-6s %-6s %-5s %s",
						entry.bot and "[BOT]" or "[P]",
						tostring(entry.name):sub(1, 16),
						hp and (math.floor(hp) .. "hp") or "DEAD",
						tostring(lvl),
						dist and (dist .. "m") or "-",
						protectedOf(entry.model) and "PROT" or
							(entry.model:GetAttribute("BotAiming") == true and "aiming" or "")),
				}
			end
			table.sort(rows, function(a, b)
				if a.alive ~= b.alive then return a.alive end
				return a.dist < b.dist
			end)

			local lines = { " KIND  NAME             HP     LEVEL  DIST  STATE" }
			for i = 1, math.min(#rows, 9) do lines[#lines + 1] = rows[i].line end
			if #rows == 0 then lines[#lines + 1] = "  nobody in range - are you deployed?" end
			pcall(function() listOut:set(lines) end)

			pcall(function()
				roundOut:set({
					"  ROUND",
					"  in round   " .. tostring(STATE.inRound)
						.. "   ongoing " .. tostring(STATE.roundOn),
					"  timer      " .. tostring(STATE.timer)
						.. "   round length " .. tostring(ROUNDCFG.RoundTime or "-") .. "s",
					"  deployed   " .. tostring(STATE.inGame)
						.. "   scoped " .. tostring(STATE.aiming),
					string.format("  cooldown   %.2fs   hit %.2fs  miss %.2fs%s",
						STATE.cooldown, hit, miss,
						(mult ~= 1) and string.format("  (x%.2f)", mult) or ""),
					string.format("  server     %s   drawn %d  (%d bots, %d players)",
						STATE.serverMode, STATE.targets, STATE.bots, STATE.humans),
					"  chams      " .. (chamsBroken and ("OFF - " .. tostring(chamsBroken))
						or (CONFIG.chams and "on" or "available, switched off")),
				})
			end)

			pcall(function()
				statOut:set({
					"  ACCOUNT",
					string.format("  %s   elo %d   level %d", STATE.rank, STATE.elo,
						STATE.level),
					string.format("  kills %d   deaths %d   K/D %.2f", STATE.kills,
						STATE.deaths, STATE.kills / math.max(STATE.deaths, 1)),
					string.format("  streak %d   headshots %d", STATE.streak,
						STATE.headshots),
					string.format("  wins %d / %d matches", STATE.wins, STATE.matches),
					string.format("  cash %d   gems %d", STATE.cash, STATE.gems),
					string.format("  session  +%d kills  +%d deaths   codes: %s",
						STATE.sessionKills, STATE.sessionDeaths, STATE.codeNote),
					string.format("  measured %d shots   %d hit   %d missed",
						STATE.shots, STATE.hits, STATE.misses),
				})
			end)

			pcall(function()
				aimOut:set({
					"  target   " .. tostring(STATE.target)
						.. "  (" .. tostring(STATE.targetKind) .. ")",
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
					"  ready    " .. tostring(STATE.canShoot),
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
						and (CONFIG.trigFov .. "px ring") or "single aim ray")
						.. (CONFIG.trigHeadOnly and "   head only" or ""),
					string.format("  shots    %d   hits %d   misses %d   %.0f%%",
						STATE.shots, STATE.hits, STATE.misses,
						(STATE.hits + STATE.misses) > 0
							and (STATE.hits / (STATE.hits + STATE.misses) * 100) or 0),
					string.format("  last shot %.0fms window   cooldown %.2fs left",
						STATE.lastShotMs, STATE.cooldown),
				})
			end)

			pcall(function()
				recOut:set({
					"  RECOIL - THERE IS NOTHING TO CANCEL, AND THIS IS THE MEASUREMENT",
					"  CameraController.Shoot adds ONE spring impulse of 0.017 rad/s",
					"  as pitch, on a Spring.new(4, 12, 300), which settles back to 0.",
					"  There is no pattern table, no shot index and no horizontal part,",
					"  and at one shot per ~1s there is no spray to walk down.",
					string.format("  measured   sens %.5f rad/px   kick now %.2f deg",
						STATE.sens, STATE.kickNow),
					string.format("  peak       %.2f deg over %d sampled frames",
						STATE.kickPeak, STATE.kickN),
				})
			end)

			pcall(function()
				silentOut:set({
					"  state     " .. (CONFIG.silent
						and (STATE.silentOn and "ARMED" or "off - " .. tostring(STATE.silentNote))
						or "disabled"),
					"  target    " .. tostring(STATE.silentTarget),
					"  mode      " .. CONFIG.silentMode
						.. (CONFIG.silentMode == "FOV"
							and ("  " .. CONFIG.silentFov .. "px") or "  no circle, no walls")
						.. "   pick " .. (CONFIG.silentCycle and "cycle" or CONFIG.silentPick),
					"  in reach  " .. tostring(STATE.silentSeen),
					string.format("  shots     %d   interval %dms",
						STATE.silentShots, CONFIG.silentGapMs),
					string.format("  kills while armed  %d", silentKillsSoFar()),
					"  note      " .. tostring(STATE.silentNote),
					"  the kill count above is the SERVER total, not a counter",
				})
			end)

			pcall(function()
				silentMeasOut:set({
					"  MEASURED ON A LIVE ROUND, ORACLE = ClientData.Data.Kills",
					"  64.6 deg off the crosshair, 70 studs   kill   109 -> 110",
					"  164 studs away, BEHIND A WALL          kill   135 -> 136",
					"  3 shots 0.15s apart at 3 targets       ONE kill",
					"  -> the server checks neither direction nor line of sight",
					"  -> the only rule it enforces is the gun's own fire rate",
					"  -> so killing everybody at once is NOT possible here;",
					"     one per cooldown is, which is what Cycle does",
					"  NOT measured: whether range past 600 studs is capped",
				})
			end)

			pcall(function()
				humOut:set({
					"  humaniser " .. (CONFIG.hum and "on" or "OFF"),
					"  blocked   " .. ((STATE.paused ~= "") and STATE.paused or "no"),
					"  scope     " .. (CONFIG.humBotOnly and "bots only" or "everybody"),
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
				})
			end)

			pcall(function()
				win:SetStat(1, tostring(STATE.kills), "kills")
				win:SetStat(2, tostring(STATE.elo), "elo")
				win:SetStat(3, tostring(STATE.targets), "drawn")
				win:SetNote(STATE.note ~= "" and STATE.note or "Ready")
				win:SetStatus(string.format("%s   %s   %s   %d bots / %d players",
					STATE.rank,
					STATE.inGame and "deployed" or (STATE.inRound and "in round" or "lobby"),
					tostring(STATE.timer),
					STATE.bots, STATE.humans))
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
	while _G.__DEAGLE == GEN do
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

_G.__DEAGLE_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	combatants = combatants, aliveOf = aliveOf, protectedOf = protectedOf,
	bodyPart = bodyPart, headPart = headPart, targetPart = targetPart,
	bulletRay = bulletRay, charFromHit = charFromHit, visibleTo = visibleTo,
	aimWorldPoint = aimWorldPoint, underCrosshair = underCrosshair,
	shotReady = shotReady, cooldownLeft = cooldownLeft, reloadTimes = reloadTimes,
	pickTarget = pickTarget, aimPass = aimPass, renderPass = renderPass,
	silentCandidates = silentCandidates, silentPickOne = silentPickOne,
	silentFire = silentFire, silentKillsSoFar = silentKillsSoFar,
	Network = Network,
	recoilWatch = recoilWatch, pullTrigger = pullTrigger, keyHeld = keyHeld,
	approach = approach, angleDelta = angleDelta, firing = firing, gauss = gauss,
	humanAimPoint = humanAimPoint, assistBlocked = assistBlocked, pauseFor = pauseFor,
	newEngagement = newEngagement, endEngagement = endEngagement,
	applyPreset = applyPreset, PRESETS = PRESETS, CTL = CTL,
	drawn = drawn, highlights = highlights, hideAll = hideAll, clearChams = clearChams,
	chamFor = chamFor, chamsRoot = chamsRoot,
	note = note, panelOpen = panelOpen, readTimer = readTimer,
	DS = DS, Config = Config, DeagleCtl = DeagleCtl, ClientData = ClientData,
	DEAGLE = DEAGLE, MATCH = MATCH, RANGE = RANGE,
}

print("[deaglearena] gen " .. GEN .. " ready - RightShift for the panel")
