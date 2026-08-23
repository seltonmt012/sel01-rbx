--[[ bloxstrike.lua - "BloxStrike" (place 114234929420007)

  The second SHOOTER in this collection. It is a 5v5 bomb-defusal game in the
  Counter Strike mould, so the shape of the deliverable is the same as
  counterblox - information plus input assistance, drawn every frame - but almost
  every detail underneath is different, and every one of those differences was
  measured through the bridge before a line of this was written.

  * **There is no Humanoid anywhere.** Characters are custom rigs parented into
    `workspace.Characters.<PlayerName>`, built from R15-named MeshParts with an
    AnimationController instead of a Humanoid. `Humanoid.Health` does not exist,
    so every health test in this file reads the character ATTRIBUTE `Health` /
    `MaxHealth` / `Dead`.
  * **Roblox Teams is empty and `Player.Team` is nil for everybody.** The team is
    the player ATTRIBUTE `Team`, holding "Terrorists" or "Counter-Terrorists".
  * **The player attributes are the whole scoreboard, for EVERY player.** `Money`,
    `Kills`, `Deaths`, `Assists`, `ADR`, `Score`, `Ping`, `HasDefuseKit`,
    `Armor` (JSON: Health + Type, so the helmet is knowable), `Slot1`..`Slot5`
    (the full loadout) and `CurrentEquipped` - which carries the weapon name AND
    the live `Rounds` / `Capacity`, i.e. **every enemy's current magazine**.
  * **The character attribute `CameraCFrame` replicates**, so where an enemy is
    LOOKING is readable. That is what the "aiming at you" warning is built on and
    it is the one piece of information this genre normally cannot have.
  * **`workspace` itself carries the round**: `GameState`, `Timer`, `CTScore`,
    `TScore`, `Map`, `Gamemode`, `BuyTimerRemaining`, plus the Source-engine
    movement cvars the game runs on (`sv_maxspeed` 18.75, `sv_gravity` 60,
    `sv_airaccelerate`, stamina costs, `MovementTickRate` 128).
  * **The recoil pattern is not a table, it is the game's own function.**
    `require(Database.Custom.Weapons["AK-47"]).Recoil.Pattern(cfg, shotIndex)`
    returns a `function(t) -> Vector2` - the exact curve the client itself uses.
    `Database.Custom.Weapons.SprayPatterns.<weapon>` additionally holds the spray
    as 30 Attachments named "1".."30". Both are read here, neither is guessed.
  * **`workspace.Map.Barriers` is 741 parts, every one of them invisible AND
    CanCollide, in collision group "Barriers"** - the CS clip brushes, exactly the
    trap counterblox hit. The answer here is cleaner than a filter list: the game
    shoots on collision group **"Bullet"**, and Bullet is registered as NOT
    collidable with Barriers, Viewmodel, WeaponModel, the grenade groups or Charm.
    So every ray in this file sets `RaycastParams.CollisionGroup = "Bullet"` and
    hits exactly what a bullet would hit. Verified against
    `PhysicsService:CollisionGroupsAreCollidable`.

  ** Nothing in this file hooks anything of the game. ** That is not caution for
  its own sake: `ReplicatedStorage.Shared.Raycast` was dumped with
  `debug.getconstants` and its constant pool contains `debug`, `info`, `getfenv`,
  `getgenv` and `hookfunction`. The game checks whether its own functions have
  been replaced. So this script reads attributes, listens on RemoteEvents it never
  fires, draws with the Drawing library (which lives outside the DataModel) and
  moves the camera. It fires no remote and fabricates no hit.

  The HUMAN page is the part that is new to this collection. Everything an assist
  does that looks machine-made - a fixed reaction delay, a perfectly centred aim
  point, a 100% headshot rate, an instant lock, staying glued to a corpse - has a
  knob there, plus two things this game hands over for free: it publishes how many
  people are SPECTATING you (`Spectators`) and it has a vote-kick system whose
  remotes can be listened to. Both can switch the assists off by themselves.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CoreGui           = game:GetService("CoreGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")

local plr    = Players.LocalPlayer
local camera = workspace.CurrentCamera

local GEN = (_G.__BSTRIKE or 0) + 1
_G.__BSTRIKE = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	-- ESP ----------------------------------------------------------------------
	box        = true,
	boxFilled  = false,
	name       = true,
	health     = true,
	hpText     = true,
	weapon     = true,
	ammo       = true,     -- the enemy's live magazine, from CurrentEquipped
	money      = false,    -- their cash, above the box
	armorIcon  = true,     -- + for kevlar, ! for kevlar + helmet
	distance   = true,
	tracer     = false,
	headDot    = true,
	skeleton   = false,
	viewLine   = false,    -- short line showing where that player is looking
	lookWarn   = true,     -- mark enemies whose crosshair is on you
	lookDeg    = 12,       -- how tight "on you" has to be, degrees
	chams      = false,
	teamESP    = false,
	deadESP    = false,    -- keep drawing dead players (they stay parented)
	visCheck   = true,
	maxDist    = 1200,
	textSize   = 14,
	textFont   = "System",
	textOutline = true,
	textShrink = false,

	colEnemy   = Color3.fromRGB(255, 72, 88),
	colMate    = Color3.fromRGB(80, 190, 255),
	colCham    = Color3.fromRGB(255, 72, 88),
	colChamOwn = false,
	colFov     = Color3.fromRGB(255, 255, 255),
	colLook    = Color3.fromRGB(255, 205, 60),

	chamStyle  = "Fill",
	chamRainbow = false,
	chamByHealth = false,

	-- visuals ------------------------------------------------------------------
	crosshair  = false,
	crossSize  = 8,
	crossGap   = 3,
	crossDot   = true,
	crossThick = 1,
	colCross   = Color3.fromRGB(90, 255, 140),
	sprayDraw  = false,    -- overlay the weapon's own spray curve on screen
	spraySize  = 90,       -- pixels for the full 30-shot pattern
	fovChange  = false,
	fovValue   = 90,
	bombTimer  = true,     -- big centred bomb countdown once it is planted

	-- aim assist ---------------------------------------------------------------
	aim        = false,
	aimActive  = "Hotkey",
	aimKey     = "MouseButton2",
	aimPart    = "Head",
	aimPick    = "Crosshair",
	aimSticky  = true,
	aimVisible = true,
	aimMaxDist = 1200,
	aimOnlyGun = true,
	aimAds     = "Always",
	aimCurve   = "Ease out",

	aimFov     = 120,
	aimSmoothH = 25,
	aimSmoothV = 25,
	aimSameAll = true,
	aimFov2    = 60,
	aimSmoothH2 = 50,
	aimSmoothV2 = 50,

	aimFire    = false,
	aimHitPct  = 100,
	aimKillMs  = 250,
	aimFirstMs = 0,

	aimCircle  = true,
	aimCircle2 = true,

	-- trigger ------------------------------------------------------------------
	trig       = false,
	trigActive = "Hotkey",
	trigKey    = "C",
	trigMode   = "Click",
	trigHoldMs = 120,
	trigDelayMin = 40,
	trigDelayMax = 90,
	trigRefireMs = 90,
	trigHitPct = 100,
	trigHeadOnly = false,
	trigMaxDist = 1200,
	trigFov    = 0,
	trigOnlyGun = true,
	trigAds    = "Always",
	trigBurst  = 0,

	-- recoil -------------------------------------------------------------------
	rcs        = false,
	rcsMode    = "Measured",  -- Measured | Pattern | Both
	rcsPitch   = 70,
	rcsYaw     = 70,
	rcsAfter   = 1,
	rcsMaxDeg  = 4,
	rcsPatAuto = true,        -- learn the pattern-to-camera scale on its own
	rcsPatScale = 1.0,

	-- humaniser ----------------------------------------------------------------
	hum          = true,
	humWindupMin = 40,     -- ms of nothing after a target is acquired
	humWindupMax = 130,
	humOffsetPct = 35,     -- aim point offset inside the hitbox, % of its size
	humJitter    = 0.9,    -- continuous drift on the aim point, studs at 100m
	humJitterHz  = 1.4,
	humOvershoot = 30,     -- % of engagements that overshoot and settle back
	humOverDeg   = 1.8,
	humHeadPct   = 65,     -- % of engagements allowed to go for the head
	humMissPct   = 0,      -- deliberate misses, % of shots
	humBreakPct  = 6,      -- % chance per second to drop the lock for a moment
	humBreakMs   = 180,
	humFatigue   = 25,     -- % slower per extra second of a held engagement
	humCooldown  = 120,    -- ms of forced pause between two engagements
	humReactSd   = 22,     -- spread of the trigger reaction time, ms
	humPanelPause = true,  -- nothing assists while the panel is open
	-- Measured on a live round: `Spectators` is how many people are watching THAT
	-- player, and only the players still alive carry a number - six dead people
	-- split three and three across the last two alive. So late in a round an alive
	-- player is ALWAYS being watched, and a hard switch-off would remove the assist
	-- exactly when it matters. Hence three steps rather than a boolean, defaulting
	-- to the middle one.
	humSpecMode  = "Soften", -- Ignore | Soften | Disable
	humSpecMin   = 1,
	humVoteOff   = true,   -- a vote kick switches everything off
	humRoundMs   = 800,    -- no assist for this long after the round flips

	-- The degrees-per-second cap is the single most important number on this page.
	-- A smoothing divisor is a FRACTION OF THE REMAINING ANGLE, so at point blank
	-- the remaining angle is huge and even a slow-looking divisor turns the camera
	-- at a few thousand degrees a second. Capping the per-frame move against
	-- rad(cap) * dt - applied to yaw and pitch TOGETHER so a diagonal flick is
	-- capped the same as a flat one - is what makes it read as a hand rather than
	-- a servo. A fast human flick is roughly 400-900 deg/s.
	humTurnCap   = 260,
	humDeadzone  = 2,      -- px; inside this the camera is simply left alone
	humMoveFov   = 70,     -- % of the FOV that still applies while you are moving
	humSwitchMs  = 350,    -- minimum time on one target before another can take over
	humRerollMs  = 900,    -- re-roll the aim point offset this often
	humTrigFat   = 8,      -- ms added per shot within one burst

	panicKey     = "End",  -- one press switches aim, trigger, auto fire and RCS off
}

-- There is no master switch on this panel and there deliberately is not one:
-- every drawing has its own row, so a second switch above them could only ever
-- mean "the row you just moved does nothing", which is what it was reported as.
-- The render pass still wants a cheap way out when the whole list is off, and
-- this is it - the flags themselves rather than a flag about the flags.
local DRAWINGS = {
	"box",
	"boxFilled",
	"name",
	"armorIcon",
	"health",
	"hpText",
	"weapon",
	"ammo",
	"money",
	"distance",
	"headDot",
	"skeleton",
	"tracer",
	"viewLine",
	"lookWarn",
	"teamESP",
	"deadESP",
	"chams",
}

local function anyDrawing()
	for _, key in ipairs(DRAWINGS) do
		if CONFIG[key] then return true end
	end
	return false
end


-- Three presets that write the whole set at once. Forty sliders with no reference
-- point is not a feature - the presets are the reference point, and every one of
-- them is still editable afterwards.
local PRESETS = {
	["Legit"] = {
		aimFov = 45, aimSmoothH = 40, aimSmoothV = 55, aimPart = "Torso",
		aimFire = false, aimVisible = true, aimCurve = "Human",
		trigDelayMin = 90, trigDelayMax = 190, trigRefireMs = 220, trigHitPct = 85,
		hum = true, humTurnCap = 160, humDeadzone = 4, humWindupMin = 90,
		humWindupMax = 240, humOffsetPct = 55, humHeadPct = 25, humOvershoot = 45,
		humBreakPct = 12, humMissPct = 8, humFatigue = 40, humCooldown = 260,
		humMoveFov = 45, humSpecMode = "Disable", rcsPitch = 45, rcsYaw = 35,
	},
	["Normal"] = {
		aimFov = 120, aimSmoothH = 25, aimSmoothV = 25, aimPart = "Head",
		aimFire = false, aimVisible = true, aimCurve = "Ease out",
		trigDelayMin = 40, trigDelayMax = 90, trigRefireMs = 90, trigHitPct = 100,
		hum = true, humTurnCap = 260, humDeadzone = 2, humWindupMin = 40,
		humWindupMax = 130, humOffsetPct = 35, humHeadPct = 65, humOvershoot = 30,
		humBreakPct = 6, humMissPct = 0, humFatigue = 25, humCooldown = 120,
		humMoveFov = 70, humSpecMode = "Soften", rcsPitch = 70, rcsYaw = 70,
	},
	["Raw"] = {
		aimFov = 400, aimSmoothH = 2, aimSmoothV = 2, aimPart = "Head",
		aimFire = true, aimVisible = true, aimCurve = "Linear",
		trigDelayMin = 0, trigDelayMax = 10, trigRefireMs = 40, trigHitPct = 100,
		hum = false, humTurnCap = 3000, humDeadzone = 0, humWindupMin = 0,
		humWindupMax = 0, humOffsetPct = 0, humHeadPct = 100, humOvershoot = 0,
		humBreakPct = 0, humMissPct = 0, humFatigue = 0, humCooldown = 0,
		humMoveFov = 100, humSpecMode = "Ignore", rcsPitch = 100, rcsYaw = 100,
	},
}

local STATE = {
	note       = "",
	targets    = 0,
	target     = "-",
	weapon     = "-",
	shots      = 0,
	rounds     = 0, capacity = 0,
	trigHits   = 0,
	trigOn     = false,
	sensY      = 0, sensP = 0, calibN = 0,
	kickY      = 0, kickP = 0, kickPeak = 0,
	patY       = 0, patP = 0, patScale = 0, patN = 0,
	underCross = "-",
	aimDps     = 0, aimDpsPeak = 0,
	lastKey    = "-",
	map        = "-", gamemode = "-", gamestate = "-",
	timer      = 0, buyTimer = 0,
	ctScore    = 0, tScore = 0,
	bombCarrier = "-", bombPlanted = false, bombAt = 0, bombSite = "-",
	alive      = { ct = 0, t = 0 },
	spectators = 0,
	voteAgainst = false, voteNote = "-",
	bacEvents  = 0, bacLast = "-",
	paused     = "",
	lookAt     = 0,
	speed      = 0,
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

local function teamColour(enemy)
	local base = enemy and CONFIG.colEnemy or CONFIG.colMate
	return base, dimmed(base)
end

--------------------------------------------------------------------------------
-- the game's own data
--------------------------------------------------------------------------------
--
-- Nothing in this game is a ValueBase and nothing is a Humanoid. Round state is
-- attributes on `workspace`, player state is attributes on the Player, and body
-- state is attributes on the character model. All three are read through these.

local charFolder = workspace:FindFirstChild("Characters")

local function wsAttr(name, fallback)
	local v = workspace:GetAttribute(name)
	if v == nil then return fallback end
	return v
end

-- CurrentEquipped, Armor and the five loadout slots are JSON STRINGS on the
-- attribute, not tables. Decoding one per player per frame is wasteful and they
-- barely change, so the result is cached against the exact string that produced
-- it - which also means a changed attribute invalidates itself for free.
local jsonCache, jsonCount = {}, 0

local function decode(text)
	if type(text) ~= "string" or text == "" then return nil end
	local hit = jsonCache[text]
	if hit ~= nil then return hit or nil end
	local ok, value = pcall(function() return HttpService:JSONDecode(text) end)
	if jsonCount > 400 then jsonCache, jsonCount = {}, 0 end
	jsonCache[text] = ok and value or false
	jsonCount = jsonCount + 1
	return ok and value or nil
end

-- ONLY the folder, never `Player.Character`. Measured on a live server: a player
-- sitting in the MENU still has a `Player.Character`, an ordinary Roblox avatar
-- parented straight into `Workspace`, and it carries none of the game's
-- attributes. Falling back to it counted three players standing in the lobby as
-- live enemies. Membership of `workspace.Characters` is what "is in the round"
-- actually means.
--
-- The other half of the same measurement: a body that has just died is REPARENTED
-- into `workspace.Debris` with Health 0, so it leaves this folder by itself.
local function charOf(p)
	if not charFolder or not charFolder.Parent then
		charFolder = workspace:FindFirstChild("Characters")
	end
	local c = charFolder and charFolder:FindFirstChild(p.Name)
	if c and c:FindFirstChild("HumanoidRootPart") then return c end
	return nil
end

-- There is no Humanoid to ask, so the state comes from attributes. Health may be
-- absent for a frame right after the model appears; that is fine here BECAUSE the
-- folder membership above has already ruled out everyone who is not in the round.
local function alive(p)
	local char = charOf(p)
	if not char then return nil end
	if char:GetAttribute("Dead") == true then return nil end
	if p:GetAttribute("Dead") == true then return nil end
	local hp = tonumber(char:GetAttribute("Health"))
	if hp == nil then hp = tonumber(p:GetAttribute("Health")) end
	if hp == nil then hp = 100 end
	if hp <= 0 then return nil end
	local maxHp = tonumber(char:GetAttribute("MaxHealth")) or 100
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	return char, hp, maxHp, root
end

local function teamOf(p) return p:GetAttribute("Team") end

local function isEnemy(p)
	if p == plr then return false end
	local mine, theirs = teamOf(plr), teamOf(p)
	if mine == nil or theirs == nil then return true end
	return mine ~= theirs
end

local function equippedOf(p)
	local info = decode(p:GetAttribute("CurrentEquipped"))
	if type(info) ~= "table" then return nil end
	return info
end

local function armorOf(p)
	local a = decode(p:GetAttribute("Armor"))
	if type(a) ~= "table" then return nil end
	return a
end

--------------------------------------------------------------------------------
-- weapon database
--------------------------------------------------------------------------------
--
-- Database.Custom.Weapons holds one ModuleScript per weapon with the whole stat
-- block: DamagePerPart {Head, Torso, Arms, Legs}, Recoil (with the Pattern
-- FUNCTION), Spread, Penetration, ArmorPenetration, WallbangMultiplier,
-- RangeModifier, WalkSpeed, Cost, Rounds, Capacity, FireRate, Automatic.
--
-- "Is this a firearm" comes from CONTENT, never from the name - 51 entries
-- including knives, gloves, four grenades, the C4 and the Zeus taser. The taser
-- is the one that makes a name list fail quietly: it is Class "Weapon" with a
-- FireRate, and only `Rounds > 1` separates it from a rifle.

local WeaponDB = ReplicatedStorage:FindFirstChild("Database")
WeaponDB = WeaponDB and WeaponDB:FindFirstChild("Custom")
WeaponDB = WeaponDB and WeaponDB:FindFirstChild("Weapons")

local SprayFolder = WeaponDB and WeaponDB:FindFirstChild("SprayPatterns")

local cfgCache = {}

local function weaponCfg(name)
	if not name or name == "" or not WeaponDB then return nil end
	local hit = cfgCache[name]
	if hit ~= nil then return hit or nil end
	local module = WeaponDB:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		cfgCache[name] = false
		return nil
	end
	local ok, cfg = pcall(require, module)
	if not ok or type(cfg) ~= "table" then
		cfgCache[name] = false
		return nil
	end
	cfgCache[name] = cfg
	return cfg
end

local function isGun(cfg)
	if type(cfg) ~= "table" then return false end
	if cfg.Class ~= "Weapon" then return false end
	local rounds = tonumber(cfg.Rounds) or 0
	return rounds > 1 and (tonumber(cfg.FireRate) or 0) > 0
end

-- The spray as 30 Attachment positions, cached per weapon. Only used to DRAW the
-- curve; the recoil correction uses the Pattern function instead.
local sprayCache = {}

local function sprayPoints(name)
	if not SprayFolder or not name then return nil end
	local hit = sprayCache[name]
	if hit ~= nil then return hit or nil end
	local part = SprayFolder:FindFirstChild(name)
	if not part then sprayCache[name] = false return nil end
	local pts = {}
	for i = 1, 40 do
		local a = part:FindFirstChild(tostring(i))
		if not a then break end
		pts[i] = Vector2.new(a.Position.X, a.Position.Y)
	end
	if #pts == 0 then sprayCache[name] = false return nil end
	sprayCache[name] = pts
	return pts
end

local function myWeapon()
	local info = equippedOf(plr)
	local name = info and info.Name or ""
	local cfg = weaponCfg(name)
	return cfg, name, info
end

--------------------------------------------------------------------------------
-- line of sight
--------------------------------------------------------------------------------
--
-- Collision group "Bullet" instead of a hand-maintained ignore list. Measured
-- with PhysicsService:CollisionGroupsAreCollidable: Bullet does NOT collide with
-- Barriers (the 741 invisible clip brushes), Viewmodel, WeaponModel, TGrenade,
-- CTGrenade or Charm, and DOES collide with Default, WeaponDropped, Debris,
-- RayBarrier and both character groups. That is precisely "what stops a bullet",
-- so this ray answers the same question the server's does.

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
pcall(function() rayParams.CollisionGroup = "Bullet" end)

local trigParams = RaycastParams.new()
trigParams.FilterType = Enum.RaycastFilterType.Exclude
trigParams.IgnoreWater = true
pcall(function() trigParams.CollisionGroup = "Bullet" end)

-- Two different filters. The ESP's visibility test has to exclude EVERY
-- character or a target's own body is the wall that hides it; the trigger must
-- exclude only the local character, because the enemy's body IS the hit.
local function refreshFilters()
	local all, mine = {}, {}
	local debris = workspace:FindFirstChild("Debris")
	if debris then table.insert(all, debris) table.insert(mine, debris) end
	if charFolder then table.insert(all, charFolder) end
	local own = charOf(plr)
	if own then table.insert(mine, own) end
	rayParams.FilterDescendantsInstances = all
	trigParams.FilterDescendantsInstances = mine
end

local function visible(worldPos)
	local origin = camera.CFrame.Position
	local dir = worldPos - origin
	if dir.Magnitude < 0.05 then return true end
	return workspace:Raycast(origin, dir, rayParams) == nil
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
if _G.__BSTRIKE_POOL then
	for _, obj in ipairs(_G.__BSTRIKE_POOL) do pcall(function() obj:Remove() end) end
end
_G.__BSTRIKE_POOL = pool

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

local function objectsFor(p)
	local set = drawn[p]
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
		cash    = make("Text", { Size = 12, Center = true, Outline = true,
			Font = 1, Color = COLOUR.text, ZIndex = 3 }),
		tracer  = make("Line", { Thickness = 1, ZIndex = 1 }),
		head    = make("Circle", { Thickness = 1, Filled = false, NumSides = 14,
			ZIndex = 3 }),
		view    = make("Line", { Thickness = 1, ZIndex = 2 }),
		bones   = {},
	}
	for i = 1, #BONES do
		set.bones[i] = make("Line", { Thickness = 1, ZIndex = 2 })
	end
	drawn[p] = set
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
	set.cash.Visible    = false
	set.tracer.Visible  = false
	set.head.Visible    = false
	set.view.Visible    = false
	for _, line in ipairs(set.bones) do line.Visible = false end
end

local function hideAll()
	for _, set in pairs(drawn) do hideSet(set) end
end

--------------------------------------------------------------------------------
-- chams
--------------------------------------------------------------------------------
--
-- The game already puts a `Highlight` on every character itself, so an extra one
-- parented into the model would be indistinguishable from the game's own and sit
-- in the tree where a client script can walk onto it. Ours goes to
-- gethui()/CoreGui with an Adornee instead: identical rendering, not in the tree.

local hlRoot = (gethui and gethui()) or CoreGui
local chamsFolder = hlRoot:FindFirstChild("SeluxBStrikeChams")
if chamsFolder then pcall(function() chamsFolder:Destroy() end) end
chamsFolder = Instance.new("Folder")
chamsFolder.Name = "SeluxBStrikeChams"
chamsFolder.Parent = hlRoot

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

local function chamFor(p)
	local hl = highlights[p]
	if hl and hl.Parent then return hl end
	hl = Instance.new("Highlight")
	hl.FillTransparency = 0.35
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Parent = chamsFolder
	highlights[p] = hl
	return hl
end

local function chamColour(base, hp, maxHp)
	if CONFIG.chamRainbow then
		return Color3.fromHSV((os.clock() * 0.25) % 1, 0.85, 1)
	end
	if CONFIG.chamByHealth then
		local frac = math.clamp((hp or 100) / math.max(maxHp or 100, 1), 0, 1)
		return COLOUR.hpBad:Lerp(COLOUR.hpGood, frac)
	end
	if CONFIG.colChamOwn then return CONFIG.colCham end
	return base
end

local function applyCham(hl, base, hp, maxHp)
	local style = CHAM_STYLES[CONFIG.chamStyle] or CHAM_STYLES["Fill"]
	local col = chamColour(base, hp, maxHp)
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
		if hl and hl.Parent then hl.Adornee = nil hl.Enabled = false end
	end
end

--------------------------------------------------------------------------------
-- static overlays
--------------------------------------------------------------------------------

local fovCircle  = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Transparency = 0.5, ZIndex = 1 })
local fovCircle2 = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Transparency = 0.28, ZIndex = 1 })
local trigCircle = make("Circle", { Thickness = 1, NumSides = 32, Filled = false,
	Color = Color3.fromRGB(255, 210, 90), Transparency = 0.45, ZIndex = 1 })

local crossLines = {}
for i = 1, 4 do
	crossLines[i] = make("Line", { Thickness = 1, ZIndex = 4 })
end
local crossDot = make("Circle", { Filled = true, NumSides = 8, Radius = 1, ZIndex = 4 })

local sprayLines = {}
for i = 1, 32 do
	sprayLines[i] = make("Line", { Thickness = 1, ZIndex = 2, Transparency = 0.55 })
end

local bombText = make("Text", { Size = 22, Center = true, Outline = true, Font = 1,
	Color = Color3.fromRGB(255, 90, 70), ZIndex = 5 })

local function centre()
	local vp = camera.ViewportSize
	return Vector2.new(vp.X / 2, vp.Y / 2)
end

--------------------------------------------------------------------------------
-- the render pass
--------------------------------------------------------------------------------

local filterAt = 0

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

-- The spray overlay is the weapon's own 30 attachment positions, normalised to
-- the widest point of the curve and drawn downward from the crosshair, so it
-- reads the way the pattern is actually shot.
local function drawSpray(mid, weaponName)
	local pts = CONFIG.sprayDraw and sprayPoints(weaponName) or nil
	if not pts then
		for _, line in ipairs(sprayLines) do line.Visible = false end
		return
	end
	local maxMag = 0.001
	for _, v in ipairs(pts) do
		maxMag = math.max(maxMag, math.abs(v.X), math.abs(v.Y))
	end
	local scale = CONFIG.spraySize / maxMag
	local shot = math.max(STATE.shots, 0)
	for i = 1, #sprayLines do
		local line = sprayLines[i]
		local a, b = pts[i], pts[i + 1]
		if a and b then
			line.Visible = true
			line.From = mid + Vector2.new(a.X * scale, -a.Y * scale)
			line.To   = mid + Vector2.new(b.X * scale, -b.Y * scale)
			-- The shots already fired are emphasised through COLOUR and THICKNESS,
			-- not through Transparency: the Drawing library's Transparency is 0 =
			-- invisible on some executors and 1 = invisible on others, so a value
			-- that means "faint" on one machine means "solid" on the next. 0.85 is
			-- nearly opaque under either reading.
			line.Transparency = 0.85
			line.Thickness = (i <= shot) and 2 or 1
			line.Color = (i <= shot) and Color3.fromRGB(255, 200, 90)
				or Color3.fromRGB(150, 150, 165)
		else
			line.Visible = false
		end
	end
end

-- The one piece of information a CS player normally cannot have. Every character
-- carries its own `CameraCFrame` as an attribute, so the angle between where a
-- player is looking and the direction from them to us is computable exactly.
local function lookAngle(char, fromPos, toPos)
	local cf = char:GetAttribute("CameraCFrame")
	if typeof(cf) ~= "CFrame" then return nil end
	local look = cf.LookVector
	local toward = (toPos - fromPos)
	if toward.Magnitude < 0.01 then return nil end
	toward = toward.Unit
	local dot = math.clamp(look:Dot(toward), -1, 1)
	return math.deg(math.acos(dot)), cf
end

local function renderPass()
	if _G.__BSTRIKE ~= GEN then return end

	local mid = centre()
	local myCfg, myName = myWeapon()

	fovCircle.Visible = CONFIG.aim and CONFIG.aimCircle
	if fovCircle.Visible then
		fovCircle.Position = mid
		fovCircle.Radius = CONFIG.aimFov
		fovCircle.Color = CONFIG.colFov
	end
	fovCircle2.Visible = CONFIG.aim and CONFIG.aimCircle2 and not CONFIG.aimSameAll
	if fovCircle2.Visible then
		fovCircle2.Position = mid
		fovCircle2.Radius = CONFIG.aimFov2
		fovCircle2.Color = CONFIG.colFov
	end
	trigCircle.Visible = CONFIG.trig and CONFIG.trigFov > 0
	if trigCircle.Visible then
		trigCircle.Position = mid
		trigCircle.Radius = CONFIG.trigFov
	end

	drawCrosshair(mid)
	drawSpray(mid, myName)

	-- Counts UP, not down. The fuse length is not published anywhere that has been
	-- found, and inventing a 40 second countdown would put a number on screen that
	-- looks authoritative and is a guess. Time since the plant is exact.
	bombText.Visible = CONFIG.bombTimer and STATE.bombPlanted
	if bombText.Visible then
		bombText.Position = Vector2.new(mid.X, mid.Y * 0.35)
		bombText.Text = string.format("BOMB %s   +%.1fs", STATE.bombSite,
			os.clock() - STATE.bombAt)
	end

	if CONFIG.fovChange then
		pcall(function() camera.FieldOfView = CONFIG.fovValue end)
	end

	if not anyDrawing() then
		hideAll()
		clearChams()
		STATE.targets = 0
		return
	end

	local now = os.clock()
	if now - filterAt > 1 then
		filterAt = now
		refreshFilters()
	end

	local vp = camera.ViewportSize
	local camPos = camera.CFrame.Position
	local count, looking = 0, 0
	local face = fontId()

	for _, p in ipairs(Players:GetPlayers()) do
		local set = objectsFor(p)
		local char, hp, maxHp, root = alive(p)
		if not char and CONFIG.deadESP then
			local dead = charOf(p)
			if dead and dead:FindFirstChild("HumanoidRootPart") then
				char, hp, maxHp, root = dead, 0, 100, dead.HumanoidRootPart
			end
		end
		local enemy = isEnemy(p)
		local wanted = char and p ~= plr and (enemy or CONFIG.teamESP)

		if not wanted then
			hideSet(set)
			local hl = highlights[p]
			if hl then hl.Enabled = false hl.Adornee = nil end
		else
			local dist = (camPos - root.Position).Magnitude
			if dist > CONFIG.maxDist then
				hideSet(set)
				local hl = highlights[p]
				if hl then hl.Enabled = false hl.Adornee = nil end
			else
				local head = char:FindFirstChild("Head")
				local seen = true
				if CONFIG.visCheck then
					seen = visible((head or root).Position)
				end

				local base, dim = teamColour(enemy)
				local col = seen and base or dim

				-- Never Model:GetBoundingBox(). The honest measurement is the pair of
				-- points the box actually needs - the top of the head and the bottom
				-- of the lower foot. Projected, the distance between them IS the
				-- on-screen height, so it scales with range for free and follows a
				-- crouch exactly (and this game crouches a lot: `IsCrouching` is an
				-- attribute and the rig really does drop).
				local lf, rf = char:FindFirstChild("LeftFoot"), char:FindFirstChild("RightFoot")
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

				-- Z <= 0 is BEHIND the camera and the X/Y reported there is mirrored
				-- nonsense: drawing it puts a box on the wrong side of the screen for
				-- somebody standing behind you.
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
					local hl = highlights[p]
					if hl and not CONFIG.chams then hl.Enabled = false end
				else
					count = count + 1
					local pos = Vector2.new(minX, minY)
					local siz = Vector2.new(w, h)

					-- Is this player's crosshair on us? Computed from their replicated
					-- CameraCFrame, so it is their real view, not a guess from the body.
					local ang = nil
					if (CONFIG.lookWarn or CONFIG.viewLine) and enemy then
						ang = lookAngle(char, root.Position, camPos)
					end
					local onMe = ang ~= nil and ang <= CONFIG.lookDeg
					if onMe then looking = looking + 1 end
					if onMe and CONFIG.lookWarn then col = CONFIG.colLook end

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
						local label = p.Name
						if CONFIG.armorIcon then
							local ar = armorOf(p)
							if ar and (tonumber(ar.Health) or 0) > 0 then
								label = label .. ((tostring(ar.Type):find("Helmet")) and " !" or " +")
							end
						end
						if p:GetAttribute("HasDefuseKit") == true then label = label .. " K" end
						set.name.Size = ts
						set.name.Font = face
						set.name.Outline = CONFIG.textOutline
						set.name.Position = Vector2.new(minX + w / 2, minY - (ts + 3))
						set.name.Text = label
						set.name.Color = col
					end

					-- One line for everything numeric. Three stacked Text objects under
					-- a box is unreadable at range.
					local bits = {}
					local eq = equippedOf(p)
					if CONFIG.weapon then
						local wn = (eq and eq.Name) or "-"
						if p:GetAttribute("IsSniperScoped") == true then wn = wn .. "*" end
						if char:GetAttribute("IsCrouching") == true then wn = wn .. "_" end
						table.insert(bits, wn)
					end
					if CONFIG.ammo and eq and eq.Rounds then
						table.insert(bits, string.format("%d/%d",
							tonumber(eq.Rounds) or 0, tonumber(eq.Capacity) or 0))
					end
					if CONFIG.distance then
						table.insert(bits, string.format("%dm", math.floor(dist)))
					end
					if CONFIG.hpText then
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

					set.cash.Visible = CONFIG.money
					if set.cash.Visible then
						set.cash.Size = math.max(12, ts - 1)
						set.cash.Font = face
						set.cash.Outline = CONFIG.textOutline
						set.cash.Position = Vector2.new(minX + w / 2, minY - (ts * 2 + 5))
						set.cash.Text = "$" .. tostring(p:GetAttribute("Money") or 0)
						set.cash.Color = Color3.fromRGB(140, 220, 140)
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

					set.view.Visible = false
					if CONFIG.viewLine and head then
						local cf = char:GetAttribute("CameraCFrame")
						if typeof(cf) == "CFrame" then
							local a = camera:WorldToViewportPoint(head.Position)
							local b = camera:WorldToViewportPoint(head.Position + cf.LookVector * 6)
							if a.Z > 0 and b.Z > 0 then
								set.view.Visible = true
								set.view.From = Vector2.new(a.X, a.Y)
								set.view.To   = Vector2.new(b.X, b.Y)
								set.view.Color = onMe and CONFIG.colLook or col
							end
						end
					end

					if CONFIG.skeleton then
						for i, bone in ipairs(BONES) do
							local a = char:FindFirstChild(bone[1])
							local b = char:FindFirstChild(bone[2])
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

					if CONFIG.chams then
						local hl = chamFor(p)
						hl.Adornee = char
						applyCham(hl, base, hp, maxHp)
					else
						local hl = highlights[p]
						if hl then hl.Enabled = false hl.Adornee = nil end
					end
				end
			end
		end
	end

	STATE.targets = count
	STATE.lookAt = looking
end

--------------------------------------------------------------------------------
-- key binding
--------------------------------------------------------------------------------
--
-- Recorded, not picked from a list: a binding is a plain string resolved late, so
-- every key the client receives can be bound. The mouse SIDE buttons cannot -
-- Enum.UserInputType has exactly MouseButton1/2/3 and Roblox never delivers
-- XButton1/2 to a client. Map them onto a keyboard key in the mouse driver.

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
	if _G.__BSTRIKE ~= GEN or not capturing or armedGuard then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if input.KeyCode == Enum.KeyCode.Escape then capture(nil) return end
	if input.KeyCode == Enum.KeyCode.Unknown then return end
	capture(input.KeyCode.Name)
end)

UserInputService.InputEnded:Connect(function(input)
	if _G.__BSTRIKE ~= GEN or not capturing or armedGuard then return end
	local name = input.UserInputType.Name
	if name:sub(1, 11) ~= "MouseButton" then return end
	capture(name)
end)

local function firing()
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
end

-- The panic key. One press switches off every assist that touches input or the
-- camera - the ESP is left alone, because it is the part that cannot be seen from
-- outside. Hooked up further down, once CONFIG-driven UI handles exist.
local panicHandlers = {}

UserInputService.InputBegan:Connect(function(input, processed)
	if _G.__BSTRIKE ~= GEN or processed or capturing then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local spec = resolveKey(CONFIG.panicKey)
	if not spec or not spec.key or input.KeyCode ~= spec.key then return end
	CONFIG.aim, CONFIG.trig, CONFIG.aimFire, CONFIG.rcs = false, false, false, false
	for _, fn in ipairs(panicHandlers) do pcall(fn) end
	note("PANIC - aim, trigger, auto fire and RCS off")
end)

--------------------------------------------------------------------------------
-- the humaniser
--------------------------------------------------------------------------------
--
-- Every number an assist produces that a person could not produce is a tell, and
-- the list of them is short and well known: a fixed reaction delay, an aim point
-- exactly in the centre of a hitbox, a lock that arrives on the same frame the
-- target appears, a headshot rate of 100%, and a lock that never once slips.
-- Each of those has a knob here.
--
-- Two of them are specific to this game and are worth more than all the jitter
-- put together, because they are not cosmetic - they are the actual signal that
-- somebody is watching:
--
--   * `Player.Spectators` is published by the server for every player. If anyone
--     is spectating YOU, the assists switch themselves off.
--   * the vote-kick system runs over `NetworkRemotes.VoteKick`, and the client is
--     told when a vote starts. If it names us, everything switches off.

local PAUSE = { reason = "", until_ = 0 }

local function watched()
	return CONFIG.hum and STATE.spectators >= math.max(1, CONFIG.humSpecMin)
end

-- "Soften" does not stop the aim, it makes it worse on purpose: the smoothing is
-- multiplied, the head is off the table and nothing pulls the trigger by itself.
-- What is left is a slow drag that looks like a player with a steady hand, which
-- is the point - the thing being hidden from is a human watching the killcam.
local function softened()
	return watched() and CONFIG.humSpecMode == "Soften"
end

local function humanPaused()
	if PAUSE.until_ > os.clock() then return PAUSE.reason end
	if not CONFIG.hum then return nil end
	if watched() and CONFIG.humSpecMode == "Disable" then return "spectated" end
	if CONFIG.humVoteOff and STATE.voteAgainst then return "vote kick" end
	return nil
end

local function pauseFor(ms, reason)
	local until_ = os.clock() + ms / 1000
	if until_ > PAUSE.until_ then
		PAUSE.until_ = until_
		PAUSE.reason = reason
	end
end

-- Box-Muller. A uniform random reaction time is itself a pattern - real reaction
-- times are a bell around a mean with a long right tail, never a flat band.
local function gauss(mean, sd)
	local u1 = math.random()
	local u2 = math.random()
	if u1 < 1e-9 then u1 = 1e-9 end
	return mean + math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2) * sd
end

-- One engagement = one continuous lock on one player. Everything that must stay
-- STABLE for the duration of a lock lives here: the aim point offset (re-rolled
-- every frame it would be a wobble, not an offset), whether this engagement is
-- allowed to go for the head at all, and whether it overshoots.
local engagement = nil

local function newEngagement(p)
	-- Written as an if rather than `CONFIG.hum and roll or true`, which is the
	-- and/or trap: a failed roll is `false`, and `false or true` is true, so the
	-- head share would silently be 100% no matter where the slider sat.
	local head = true
	if CONFIG.hum then head = math.random(100) <= CONFIG.humHeadPct end
	engagement = {
		player   = p,
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
		-- Nothing else may take this target away for humSwitchMs. Without it the
		-- aim twitches between two enemies over a one-pixel difference, which is
		-- the most machine-like thing on the list and costs one timestamp to fix.
		lockUntil = os.clock() + CONFIG.humSwitchMs / 1000,
		rerollAt  = os.clock() + CONFIG.humRerollMs / 1000,
	}
	return engagement
end

-- The offset is stable for a while and then moves, rather than being stable for
-- the whole engagement: a lock that holds the exact same millimetre for six
-- seconds is as readable as one that hits dead centre.
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
-- engagement, plus a slow continuous drift. math.noise is used rather than
-- math.random so the drift is smooth - random per frame is a vibration, which
-- looks less human than no jitter at all.
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
local stickyTarget = nil
local aimWroteCamera = false

-- The template has no IsOpen(); what it does have is `window.root`, the frame the
-- RightShift hotkey flips. Reading its Visible is the open/closed state, and it
-- has to be read late because the window does not exist yet when this file is
-- first executed top to bottom.
local function panelOpen()
	local win = _G.__BSTRIKE_WIN
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

local function aimNumbers()
	if CONFIG.aimSameAll or STATE.shots <= 1 then
		return CONFIG.aimFov, CONFIG.aimSmoothH, CONFIG.aimSmoothV
	end
	return CONFIG.aimFov2, CONFIG.aimSmoothH2, CONFIG.aimSmoothV2
end

local HEADPARTS = { Head = true }

local function targetPart(char)
	local want = CONFIG.aimPart
	-- The head cap is what keeps a session from ending with a 95% headshot rate,
	-- which is the single statistic a review of a suspicious account looks at.
	if want == "Head" and CONFIG.hum and engagement and not engagement.head then
		want = "Torso"
	end
	if want == "Head" and softened() then want = "Torso" end
	if want == "Torso" then
		return char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart")
	end
	if want == "Nearest" then
		local mid = centre()
		local best, bestD
		for _, n in ipairs({ "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart" }) do
			local part = char:FindFirstChild(n)
			if part then
				local sp = camera:WorldToViewportPoint(part.Position)
				if sp.Z > 0 then
					local d = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
					if not bestD or d < bestD then best, bestD = part, d end
				end
			end
		end
		return best
	end
	return char:FindFirstChild("Head") or char:FindFirstChild("UpperTorso")
		or char:FindFirstChild("HumanoidRootPart")
end

local function gunGate(needGun)
	if not needGun then return true end
	local cfg = myWeapon()
	return isGun(cfg)
end

local function adsGate(mode)
	if mode == "Always" then return true end
	local on = plr:GetAttribute("IsSniperScoped") == true
	if mode == "Scoped only" then return on end
	return not on
end

-- Am I moving? There is no Humanoid, so this is the root's own velocity, flattened
-- - the same number the MOVEMENT readout shows. `IsWalking` only covers the walk
-- key, not running, so it is not enough on its own.
local function movingFrac()
	local char = charOf(plr)
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return 0 end
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local maxSpeed = tonumber(wsAttr("sv_maxspeed", 18.75)) or 18.75
	return math.clamp(speed / math.max(maxSpeed, 1), 0, 1)
end

local function pickTarget()
	local fov = select(1, aimNumbers())
	-- Tracking as well while sprinting as while standing still is a tell in its
	-- own right, so the window narrows with how fast you are actually moving.
	if CONFIG.hum and CONFIG.humMoveFov < 100 then
		local frac = movingFrac()
		fov = fov * (1 - frac * (1 - CONFIG.humMoveFov / 100))
	end
	local mid = centre()
	local camPos = camera.CFrame.Position
	local best, bestScore

	for _, p in ipairs(Players:GetPlayers()) do
		if isEnemy(p) then
			local char, hp, _, root = alive(p)
			if char then
				local part = targetPart(char)
				if part and (camPos - root.Position).Magnitude <= CONFIG.aimMaxDist then
					local sp = camera:WorldToViewportPoint(part.Position)
					if sp.Z > 0 then
						local px = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
						if px <= fov then
							if (not CONFIG.aimVisible) or visible(part.Position) then
								local score
								if CONFIG.aimPick == "Closest" then
									score = (camPos - root.Position).Magnitude
								elseif CONFIG.aimPick == "Lowest HP" then
									score = hp
								else
									score = px
								end
								if not bestScore or score < bestScore then
									best, bestScore = { player = p, part = part, px = px }, score
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
-- a hard snap at 200 FPS whatever the slider says - that was the first thing the
-- user noticed on counterblox.
local function approach(smooth, dt)
	local base = 1 / math.max(1, smooth)
	return 1 - (1 - base) ^ math.max(dt * 60, 0.0001)
end

local function angleDelta(a, b)
	local d = (b - a) % (math.pi * 2)
	if d > math.pi then d = d - math.pi * 2 end
	return d
end

-- The curve shapes how the remaining angle is eaten. Ease out is the exponential
-- above, which starts fast and creeps in at the end. "Human" is the opposite of
-- what a machine does: slow at the start (the hand has to get moving), fastest in
-- the middle, slow again as it settles.
local function curveFactor(progress)
	local mode = CONFIG.aimCurve
	if mode == "Linear" then return 1 end
	if mode == "Human" then
		-- progress: 1 = still far away, 0 = on target
		local x = math.clamp(1 - progress, 0, 1)
		return 0.35 + 1.3 * math.sin(x * math.pi)
	end
	return 1
end

local function aimPass(dt)
	if _G.__BSTRIKE ~= GEN then return end
	aimWroteCamera = false
	STATE.aimDps = 0

	local blocked = assistBlocked()
	STATE.paused = blocked or ""
	if blocked then
		STATE.target = "-"
		stickyTarget = nil
		endEngagement()
		return
	end

	-- Each gate names ITSELF in the readout. Between rounds this game clears
	-- `CurrentEquipped` and leaves you holding only a knife, so "Firearms only"
	-- correctly blocks - but with a single shared early return the panel showed an
	-- armed aim, a visible target 52 px from the crosshair and a camera that never
	-- moved, with nothing anywhere saying why. That is the exact "it does nothing
	-- and nothing says why" failure this genre keeps producing.
	if not aimActive() then
		STATE.target = "-"
		stickyTarget = nil
		if engagement then endEngagement() end
		return
	end
	if not gunGate(CONFIG.aimOnlyGun) then
		STATE.paused = "no firearm held"
		STATE.target = "-"
		stickyTarget = nil
		if engagement then endEngagement() end
		return
	end
	if not adsGate(CONFIG.aimAds) then
		STATE.paused = "scope condition"
		STATE.target = "-"
		stickyTarget = nil
		if engagement then endEngagement() end
		return
	end
	if os.clock() * 1000 - lastKillAt < CONFIG.aimKillMs then
		STATE.target = "-"
		return
	end

	local pick
	if CONFIG.aimSticky and stickyTarget then
		local char = alive(stickyTarget)
		if char then
			local part = targetPart(char)
			local fov = select(1, aimNumbers())
			if part then
				local sp = camera:WorldToViewportPoint(part.Position)
				local px = (Vector2.new(sp.X, sp.Y) - centre()).Magnitude
				if sp.Z > 0 and px <= fov * 1.35
					and ((not CONFIG.aimVisible) or visible(part.Position)) then
					pick = { player = stickyTarget, part = part, px = px }
				end
			end
		end
	end
	pick = pick or pickTarget()

	if not pick or not pick.part or not pick.part.Parent then
		STATE.target = "-"
		stickyTarget = nil
		if engagement then endEngagement() end
		return
	end

	-- The switch lock: a different player cannot take the engagement over until
	-- the current one has been held for humSwitchMs, unless the current one is
	-- gone. Checked BEFORE the engagement is replaced.
	if engagement and engagement.player ~= pick.player and CONFIG.hum
		and os.clock() < engagement.lockUntil and alive(engagement.player) then
		local heldChar = alive(engagement.player)
		local heldPart = heldChar and targetPart(heldChar)
		if heldPart then
			pick = { player = engagement.player, part = heldPart, px = pick.px }
		end
	end

	if not engagement or engagement.player ~= pick.player then
		newEngagement(pick.player)
	end
	rerollOffset()
	stickyTarget = pick.player
	STATE.target = pick.player.Name

	local now = os.clock()

	-- Wind-up: nothing moves for the first few dozen milliseconds of a lock. A
	-- camera that starts travelling on the exact frame an enemy became visible is
	-- the most machine-like thing an aim assist does, and it costs nothing to fix.
	if now - engagement.t0 < engagement.windup then return end

	-- A lock that never once slips is also a tell. This drops it briefly.
	if CONFIG.hum and CONFIG.humBreakPct > 0 then
		if now < engagement.breakTil then return end
		if math.random() < (CONFIG.humBreakPct / 100) * dt then
			engagement.breakTil = now + CONFIG.humBreakMs / 1000
			return
		end
	end

	local _, smoothH, smoothV = aimNumbers()

	if softened() then
		smoothH, smoothV = smoothH * 2.5, smoothV * 2.5
		STATE.paused = "softened (watched)"
	end

	-- Fatigue: a lock held for a long time gets slower, the way a hand does.
	if CONFIG.hum and CONFIG.humFatigue > 0 then
		local held = math.max(0, now - engagement.t0 - 1)
		local mult = 1 + held * (CONFIG.humFatigue / 100)
		smoothH, smoothV = smoothH * mult, smoothV * mult
	end

	local cf = camera.CFrame
	local pos = cf.Position
	local dist = (pos - pick.part.Position).Magnitude
	local aimAt = humanAimPoint(pick.part, dist)

	-- Overshoot: for the first stretch of the engagement the target point is
	-- pushed PAST the enemy, so the camera arrives, goes slightly too far and
	-- settles back - which is what a flick actually looks like.
	if CONFIG.hum and engagement.over and (now - engagement.t0) < engagement.windup + 0.09 then
		local side = (engagement.ox >= 0) and 1 or -1
		local right = cf.RightVector
		aimAt = aimAt + right * side * math.rad(CONFIG.humOverDeg) * dist
	end

	local curPitch, curYaw = cf:ToOrientation()
	local want = CFrame.lookAt(pos, aimAt)
	local wantPitch, wantYaw = want:ToOrientation()

	local dYaw = angleDelta(curYaw, wantYaw)
	local dPitch = angleDelta(curPitch, wantPitch)

	-- Yaw and pitch stepped SEPARATELY - that is the whole point of two sliders. A
	-- fast horizontal tracks a strafing player while a slow vertical takes the
	-- give-away snap off the head.
	local progress = math.clamp(math.max(math.abs(dYaw), math.abs(dPitch)) / 0.5, 0, 1)
	local shape = curveFactor(progress)

	local stepYaw   = dYaw   * math.clamp(approach(smoothH, dt) * shape, 0, 1)
	local stepPitch = dPitch * math.clamp(approach(smoothV, dt) * shape, 0, 1)

	-- Deadzone: inside a couple of pixels the camera is left completely alone.
	-- Permanent pixel-perfect tracking is a tell that no amount of smoothing
	-- hides, because a hand never sits exactly still on a target either.
	if CONFIG.hum and CONFIG.humDeadzone > 0 and pick.px <= CONFIG.humDeadzone then
		STATE.paused = "deadzone"
		return
	end

	-- The degrees-per-second cap, applied to yaw and pitch TOGETHER so a diagonal
	-- flick is capped exactly like a flat one. This is what stops a small
	-- smoothing number from turning the camera at servo speed when the target is
	-- close and the remaining angle is therefore large.
	if CONFIG.hum and CONFIG.humTurnCap > 0 then
		local mag = math.sqrt(stepYaw * stepYaw + stepPitch * stepPitch)
		local cap = math.rad(CONFIG.humTurnCap) * math.max(dt, 1e-4)
		if mag > cap and mag > 0 then
			local k = cap / mag
			stepYaw, stepPitch = stepYaw * k, stepPitch * k
		end
	end

	-- How fast the ASSIST is turning the camera, in degrees per second, and only
	-- the assist's own contribution. Measuring the camera as a whole cannot answer
	-- this: a test that did so read 216 deg/s against a 120 deg/s cap and the
	-- number was the player's wrist, not the script. This is the step the script
	-- actually applied, so it is the only honest way to check the cap - and it is
	-- worth having on screen anyway.
	local applied = math.deg(math.sqrt(stepYaw * stepYaw + stepPitch * stepPitch))
	STATE.aimDps = applied / math.max(dt, 1e-4)
	if STATE.aimDps > STATE.aimDpsPeak then STATE.aimDpsPeak = STATE.aimDps end

	camera.CFrame = CFrame.new(pos)
		* CFrame.fromOrientation(curPitch + stepPitch, curYaw + stepYaw, 0)
	aimWroteCamera = true
end

--------------------------------------------------------------------------------
-- shot counting
--------------------------------------------------------------------------------
--
-- counterblox had to COUNT shots from the trigger being down and the weapon's
-- FireRate, because it had no ammo value anywhere. This game publishes it:
-- `CurrentEquipped.Rounds` is the live magazine and it is on the player
-- attribute, so the shot number is read rather than inferred. A drop is a shot, a
-- rise is a reload, and a gap resets the spray the same way a real one resets.

local lastRounds, lastShotAt = nil, 0

local function shotClock()
	local cfg, name, info = myWeapon()
	STATE.weapon = (name ~= "" and name) or "-"
	local rounds = info and tonumber(info.Rounds) or nil
	STATE.rounds = rounds or 0
	STATE.capacity = (info and tonumber(info.Capacity)) or 0

	local now = os.clock()

	if rounds == nil then
		if now - lastShotAt > 0.35 then STATE.shots = 0 end
		lastRounds = nil
		return
	end

	if lastRounds == nil then lastRounds = rounds return end

	if rounds < lastRounds then
		STATE.shots = STATE.shots + (lastRounds - rounds)
		lastShotAt = now
	elseif rounds > lastRounds then
		STATE.shots = 0
	elseif now - lastShotAt > 0.35 then
		STATE.shots = 0
	end
	lastRounds = rounds
end

--------------------------------------------------------------------------------
-- recoil control
--------------------------------------------------------------------------------
--
-- Two independent sources, and the panel can run either or both:
--
--   Measured  - the approach from counterblox. Every frame the camera's angle
--               change is compared against the raw mouse movement for that same
--               frame. While NOT firing the ratio of the two IS the effective
--               sensitivity; while firing, whatever is left over after
--               subtracting sensitivity x mouse is the recoil. Needs no
--               calibration step and adapts if the player changes sensitivity.
--
--   Pattern   - this game hands over its OWN recoil curve.
--               cfg.Recoil.Pattern(cfg, shotIndex) returns function(t) -> Vector2,
--               which is exactly what the client itself uses. The one unknown is
--               what one unit of that Vector2 is worth in camera radians, and
--               rather than hard-coding a guess the script LEARNS it: while
--               firing it divides the measured residual by the pattern's own
--               predicted step and averages the ratio. That number is on screen
--               (RECOIL -> pattern scale), so it can be checked instead of
--               believed.

local mouseDX, mouseDY = 0, 0
UserInputService.InputChanged:Connect(function(input)
	if _G.__BSTRIKE ~= GEN then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		mouseDX = mouseDX + input.Delta.X
		mouseDY = mouseDY + input.Delta.Y
	end
end)

local lastYaw, lastPitch = nil, nil
local sensYaw, sensPitch = 0, 0
local patLast, patShot = nil, 0
local patScale = 0

local function patternStep(dt)
	local cfg = myWeapon()
	if not cfg or type(cfg.Recoil) ~= "table" or type(cfg.Recoil.Pattern) ~= "function" then
		patLast, patShot = nil, 0
		return nil
	end
	local shot = math.max(1, STATE.shots)
	local ok, fn = pcall(cfg.Recoil.Pattern, cfg, shot)
	if not ok or type(fn) ~= "function" then return nil end

	local t = os.clock() - lastShotAt
	local ok2, here = pcall(fn, t)
	if not ok2 or typeof(here) ~= "Vector2" then return nil end

	local step = nil
	if patLast and patShot == shot then
		step = here - patLast
	end
	patLast, patShot = here, shot
	return step, here
end

local function rcsPass(dt)
	if _G.__BSTRIKE ~= GEN then return end
	local cf = camera.CFrame
	local pitch, yaw = cf:ToOrientation()
	local mx, my = mouseDX, mouseDY
	mouseDX, mouseDY = 0, 0

	if lastYaw == nil then lastYaw, lastPitch = yaw, pitch return end

	local dYaw = angleDelta(lastYaw, yaw)
	local dPitch = pitch - lastPitch
	lastYaw, lastPitch = yaw, pitch

	local shooting = firing()

	if not shooting and not aimWroteCamera then
		if math.abs(mx) > 2 then
			local s = -dYaw / mx
			sensYaw = sensYaw == 0 and s or (sensYaw * 0.9 + s * 0.1)
			STATE.calibN = STATE.calibN + 1
		end
		if math.abs(my) > 2 then
			local s = -dPitch / my
			sensPitch = sensPitch == 0 and s or (sensPitch * 0.9 + s * 0.1)
		end
	end
	STATE.sensY, STATE.sensP = sensYaw, sensPitch

	local step = patternStep(dt)
	STATE.patY = step and step.X or 0
	STATE.patP = step and step.Y or 0

	if not shooting then
		STATE.kickY, STATE.kickP = 0, 0
		patLast = nil
		return
	end

	-- Vertical sensitivity is measured far less often than horizontal - people
	-- flick sideways constantly and up/down rarely - so an unmeasured pitch
	-- sensitivity falls back to the yaw one rather than to ZERO. With zero the
	-- residual is the player's entire vertical mouse movement and the correction
	-- fights the user instead of the recoil.
	local sp = sensPitch
	if sp == 0 then sp = sensYaw end

	local resYaw   = dYaw   - (-sensYaw * mx)
	local resPitch = dPitch - (-sp      * my)
	STATE.kickY = math.deg(resYaw)
	STATE.kickP = math.deg(resPitch)
	if math.abs(STATE.kickP) > math.abs(STATE.kickPeak) then
		STATE.kickPeak = STATE.kickP
	end

	-- Learn what one pattern unit is worth in radians, from frames where the
	-- script did not touch the camera itself.
	if step and CONFIG.rcsPatAuto and not aimWroteCamera then
		local predicted = step.Y
		if math.abs(predicted) > 0.02 then
			local ratio = resPitch / predicted
			if ratio == ratio and math.abs(ratio) < 1 then
				patScale = patScale == 0 and ratio or (patScale * 0.92 + ratio * 0.08)
				STATE.patN = STATE.patN + 1
			end
		end
	end
	STATE.patScale = patScale

	if not CONFIG.rcs or aimWroteCamera then return end
	if STATE.shots < CONFIG.rcsAfter then return end

	local corrYaw, corrPitch = 0, 0
	local mode = CONFIG.rcsMode

	if mode == "Measured" or mode == "Both" then
		if sensYaw ~= 0 or sp ~= 0 then
			corrYaw   = corrYaw   - resYaw   * (CONFIG.rcsYaw   / 100)
			corrPitch = corrPitch - resPitch * (CONFIG.rcsPitch / 100)
		end
	end

	if (mode == "Pattern" or mode == "Both") and step then
		local scale = CONFIG.rcsPatAuto and patScale or (CONFIG.rcsPatScale * 0.01)
		if scale ~= 0 then
			corrYaw   = corrYaw   - step.X * scale * (CONFIG.rcsYaw   / 100)
			corrPitch = corrPitch - step.Y * scale * (CONFIG.rcsPitch / 100)
		end
	end

	if mode == "Both" then
		corrYaw, corrPitch = corrYaw * 0.5, corrPitch * 0.5
	end

	local cap = math.rad(CONFIG.rcsMaxDeg)
	corrYaw   = math.clamp(corrYaw, -cap, cap)
	corrPitch = math.clamp(corrPitch, -cap, cap)
	if math.abs(corrYaw) < 1e-5 and math.abs(corrPitch) < 1e-5 then return end

	camera.CFrame = CFrame.new(cf.Position)
		* CFrame.fromOrientation(pitch + corrPitch, yaw + corrYaw, 0)
	lastPitch, lastYaw = pitch + corrPitch, yaw + corrYaw
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
	if CONFIG.trigMode == "Hold" and press and release then
		press()
		task.wait(CONFIG.trigHoldMs / 1000)
		release()
	elseif click then
		click()
	elseif press and release then
		press() task.wait(0.02) release()
	end
end

local function underCrosshair()
	local vp = camera.ViewportSize
	local mid = Vector2.new(vp.X / 2, vp.Y / 2)
	local offsets = { Vector2.new(0, 0) }
	if CONFIG.trigFov > 0 then
		local r = CONFIG.trigFov
		for i = 0, 5 do
			local a = math.rad(i * 60)
			table.insert(offsets, Vector2.new(math.cos(a) * r, math.sin(a) * r))
		end
	end

	for _, off in ipairs(offsets) do
		local ray = camera:ViewportPointToRay(mid.X + off.X, mid.Y + off.Y)
		local hit = workspace:Raycast(ray.Origin, ray.Direction * CONFIG.trigMaxDist,
			trigParams)
		if hit and hit.Instance then
			-- The character models live in workspace.Characters and are plain Models,
			-- so the owner is found by walking up to a model the folder knows.
			local node = hit.Instance
			for _ = 1, 6 do
				if not node or node == workspace then break end
				if node.Parent == charFolder then
					local p = Players:FindFirstChild(node.Name)
					if p and isEnemy(p) and alive(p) then
						if (not CONFIG.trigHeadOnly) or HEADPARTS[hit.Instance.Name] then
							return p, hit.Instance
						end
					end
					break
				end
				node = node.Parent
			end
		end
	end
	return nil
end

local trigShots = 0
local trigWasHeld = false

local function trigActive()
	if not CONFIG.trig then return false end
	if CONFIG.trigActive == "Always" then return true end
	return keyHeld(CONFIG.trigKey)
end

task.spawn(function()
	local nextAt = 0
	while _G.__BSTRIKE == GEN do
		local ok, err = pcall(function()
			-- Evaluated even when the trigger is not armed, purely so the panel can
			-- SHOW what is under the crosshair. Without it there is no way to tell
			-- "the key is not held" from "the ray never reaches the enemy" - both
			-- look identical, which is to say nothing happens.
			local seen = underCrosshair()
			STATE.underCross = seen and seen.Name or "-"

			local blocked = assistBlocked()
			if blocked then
				STATE.trigOn = false
				return
			end
			-- A triggerbot is the single most obvious thing on a killcam, so it is
			-- the first thing that goes while somebody is spectating.
			if softened() then
				STATE.trigOn = false
				return
			end

			local held = trigActive()
			if not held then
				trigWasHeld = false
				trigShots = 0
				STATE.trigOn = false
				return
			end
			if not trigWasHeld then trigShots = 0 end
			trigWasHeld = true
			STATE.trigOn = true

			-- Same rule as the aim: every gate says which one it was.
			if not gunGate(CONFIG.trigOnlyGun) then
				STATE.underCross = "-- no firearm held"
				return
			end
			if not adsGate(CONFIG.trigAds) then
				STATE.underCross = "-- scope condition"
				return
			end
			if CONFIG.trigBurst > 0 and trigShots >= CONFIG.trigBurst then return end

			local now = os.clock() * 1000
			if now < nextAt then return end

			local target = seen
			if not target then return end

			local hitPct = CONFIG.trigHitPct
			if CONFIG.hum and CONFIG.humMissPct > 0 then
				hitPct = math.max(1, hitPct - CONFIG.humMissPct)
			end
			if math.random(100) > hitPct then
				nextAt = now + CONFIG.trigRefireMs
				return
			end

			-- Gaussian around the middle of the min/max band rather than a flat
			-- uniform draw. A uniform delay is still a pattern, just a wider one.
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
			if assistBlocked() then return end

			pullTrigger()
			trigShots = trigShots + 1
			STATE.trigHits = STATE.trigHits + 1
			local refire = CONFIG.trigRefireMs
			if CONFIG.hum then
				refire = refire * (0.85 + math.random() * 0.35)
				-- Trigger fatigue: a burst whose every shot has identical timing is
				-- a pattern, so each shot within one hold costs a little more.
				refire = refire + CONFIG.humTrigFat * trigShots
			end
			nextAt = os.clock() * 1000 + refire
		end)
		if not ok then note("trigger: " .. tostring(err)) end
		task.wait(0.01)
	end
end)

-- Auto fire for the aim assist, kept apart from the trigger so the two can run at
-- once without fighting over the mouse.
task.spawn(function()
	local nextAt = 0
	while _G.__BSTRIKE == GEN do
		local ok, err = pcall(function()
			if not (CONFIG.aim and CONFIG.aimFire) then return end
			if STATE.target == "-" then return end
			if assistBlocked() then return end
			-- Nothing pulls the trigger by itself while somebody is watching.
			if softened() then return end
			if not gunGate(CONFIG.aimOnlyGun) then return end
			-- No firing during the wind-up either, or the wind-up is pointless.
			if engagement and os.clock() - engagement.t0 < engagement.windup then return end
			local now = os.clock() * 1000
			if now < nextAt then return end
			local pct = CONFIG.aimHitPct
			if CONFIG.hum and CONFIG.humMissPct > 0 then
				pct = math.max(1, pct - CONFIG.humMissPct)
			end
			if math.random(100) > pct then
				nextAt = now + 120
				return
			end
			if CONFIG.aimFirstMs > 0 and STATE.shots == 0 then
				task.wait(CONFIG.aimFirstMs / 1000)
				if STATE.target == "-" then return end
			end
			pullTrigger()
			local cfg = myWeapon()
			local rate = (cfg and tonumber(cfg.FireRate)) or 0.1
			nextAt = os.clock() * 1000 + math.max(rate * 1000, 60)
		end)
		if not ok then note("autofire: " .. tostring(err)) end
		task.wait(0.02)
	end
end)

-- A kill pauses the aim, the same way the reference menus do it: staying glued to
-- a corpse and then flicking off it is the most obvious thing an assist can do.
-- Health here is the character ATTRIBUTE, since there is no Humanoid.
task.spawn(function()
	local seen = {}
	while _G.__BSTRIKE == GEN do
		pcall(function()
			for _, p in ipairs(Players:GetPlayers()) do
				local char = charOf(p)
				local hp = char and tonumber(char:GetAttribute("Health")) or 0
				local was = seen[p]
				if was and was > 0 and hp <= 0 and p == stickyTarget then
					lastKillAt = os.clock() * 1000
					stickyTarget = nil
					endEngagement()
				end
				seen[p] = hp
			end
		end)
		task.wait(0.1)
	end
end)

--------------------------------------------------------------------------------
-- listeners: round, bomb, spectators, vote kick, anticheat
--------------------------------------------------------------------------------
--
-- Every one of these is a CONNECTION to a RemoteEvent, never a call. The script
-- learns what the server tells the client anyway and fires nothing back.

local NR = ReplicatedStorage:FindFirstChild("NetworkRemotes")

local function onRemote(folderName, eventName, fn)
	if not NR then return end
	local folder = NR:FindFirstChild(folderName)
	local remote = folder and folder:FindFirstChild(eventName)
	if not remote or not remote:IsA("RemoteEvent") then return end
	remote.OnClientEvent:Connect(function(...)
		if _G.__BSTRIKE ~= GEN then return end
		pcall(fn, ...)
	end)
end

onRemote("C4", "Planted", function(...)
	STATE.bombPlanted = true
	STATE.bombAt = os.clock()
	local args = { ... }
	for _, v in ipairs(args) do
		if typeof(v) == "Instance" then STATE.bombSite = v.Name end
		if type(v) == "string" then STATE.bombSite = v end
	end
	note("bomb planted")
end)
onRemote("C4", "Defused", function()
	STATE.bombPlanted = false
	note("bomb defused")
end)

-- The vote kick system. A vote that names us switches every assist off, and the
-- panel says so in words rather than just going quiet.
local function voteMentionsMe(...)
	for _, v in ipairs({ ... }) do
		if typeof(v) == "Instance" and v == plr then return true end
		if type(v) == "string" and v == plr.Name then return true end
		if type(v) == "table" then
			for _, vv in pairs(v) do
				if vv == plr or vv == plr.Name then return true end
			end
		end
	end
	return false
end

for _, name in ipairs({ "StartVote", "CallVote" }) do
	onRemote("VoteKick", name, function(...)
		if voteMentionsMe(...) then
			STATE.voteAgainst = true
			STATE.voteNote = "vote kick against you"
			note("VOTE KICK against you - assists off")
		else
			STATE.voteNote = "vote running (not you)"
		end
	end)
end
onRemote("VoteKick", "EndVote", function()
	STATE.voteAgainst = false
	STATE.voteNote = "-"
end)

-- The anticheat remote. Counted and shown, never answered.
do
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local bac = remotes and remotes:FindFirstChild("BAC")
	if bac and bac:IsA("RemoteEvent") then
		bac.OnClientEvent:Connect(function(...)
			if _G.__BSTRIKE ~= GEN then return end
			STATE.bacEvents = STATE.bacEvents + 1
			local first = ({ ... })[1]
			STATE.bacLast = tostring(first):sub(1, 40)
		end)
	end
end

-- The round flipping is a reason to sit still for a moment: everybody is in spawn
-- and nothing is worth assisting, while a camera that snaps during the freeze
-- time is watched by nine other people.
workspace:GetAttributeChangedSignal("GameState"):Connect(function()
	if _G.__BSTRIKE ~= GEN then return end
	STATE.gamestate = tostring(wsAttr("GameState", "-"))
	if CONFIG.hum and CONFIG.humRoundMs > 0 then
		pauseFor(CONFIG.humRoundMs, "round change")
	end
	if STATE.gamestate ~= "Round In Progress" then
		STATE.bombPlanted = false
	end
end)

--------------------------------------------------------------------------------
-- the frame bindings
--------------------------------------------------------------------------------
--
-- Two of them on purpose. The ESP wants to run AFTER the camera has settled for
-- this frame or the boxes trail the view by one frame, which reads as a wobble.
-- The aim step has to run after the game's own camera code or it is simply
-- overwritten - Camera + 1 is late enough for both.

for _, name in ipairs({ "SeluxBStrikeAim", "SeluxBStrikeESP" }) do
	pcall(function() RunService:UnbindFromRenderStep(name) end)
end

RunService:BindToRenderStep("SeluxBStrikeAim", Enum.RenderPriority.Camera.Value + 1,
	function(dt)
		if _G.__BSTRIKE ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxBStrikeAim") end)
			return
		end
		-- Order matters: count the shot first so the first/other-bullet split and
		-- the recoil step are both looking at the same shot number, then aim, then
		-- cancel recoil - the recoil pass has to see whether aim moved the camera
		-- this frame or it reads its own correction as player input.
		local ok, err = pcall(function()
			shotClock()
			aimPass(dt)
			rcsPass(dt)
		end)
		if not ok then note("aim: " .. tostring(err)) end
	end)

RunService:BindToRenderStep("SeluxBStrikeESP", Enum.RenderPriority.Camera.Value + 2,
	function()
		if _G.__BSTRIKE ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxBStrikeESP") end)
			hideAll()
			return
		end
		local ok, err = pcall(renderPass)
		if not ok then note("esp: " .. tostring(err)) end
	end)

Players.PlayerRemoving:Connect(function(p)
	local set = drawn[p]
	if set then hideSet(set) end
	local hl = highlights[p]
	if hl then pcall(function() hl:Destroy() end) highlights[p] = nil end
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__BSTRIKE_WIN then pcall(function() _G.__BSTRIKE_WIN:Destroy() end) end
for _, root in ipairs({ (gethui and gethui()) or nil, CoreGui }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "BloxStrikePanel" then pcall(function() g:Destroy() end) end
		end
	end
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("bloxstrike", CONFIG)

local win = UI.Window({
	name = "BloxStrikePanel",
	title = "BLOX", accentTitle = "STRIKE", subtitle = "seltonmt",
	badge = "◎", width = 920, height = 580,
})
_G.__BSTRIKE_WIN = win



-- "Auto fire" switched on while the aim itself is off does nothing, and from the
-- outside that reads as a dead toggle rather than as a gate. Enabling one of
-- these arms the aim with it.
--
-- Watched from ONE place instead of being wired into every callback: what matters
-- is the transition off -> on, and a poll sees that however the flag was changed -
-- a toggle, a preset, or the console. Seeded from the current values, so a panel
-- that starts up with auto fire already on does not arm itself.
local ARM_AIM = { "aimFire", "aimCircle", "aimCircle2" }

task.spawn(function()
	local was = {}
	for _, key in ipairs(ARM_AIM) do was[key] = CONFIG[key] and true or false end
	while _G.__BSTRIKE == GEN do
		for _, key in ipairs(ARM_AIM) do
			local on = CONFIG[key] and true or false
			if on and not was[key] and not CONFIG.aim then
				CONFIG.aim = true
				note("Aim was off - switched on with it")
			end
			was[key] = on
		end
		task.wait(0.2)
	end
end)



-- Toggle, Slider and Dropdown all return a handle with a `set`, so a preset can
-- move the CONTROLS and not only the CONFIG behind them. Without this a preset
-- would change how the script behaves while every slider on screen kept showing
-- the old number, which is worse than having no presets at all.
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
	stickyTarget = nil
	endEngagement()
	note("preset: " .. name)
end

-- Every caption and hint here is written in ENGLISH, and that is not a style
-- choice: UI.t() looks a string up by exactly the characters the script passed and
-- tools/i18n/*.tsv is keyed in English. A German literal is a key that is in no
-- dictionary, so it falls through unchanged in all three languages and the flags
-- in the header appear to do nothing at all.

-- ESP -------------------------------------------------------------------------

local espPage = win:Page("ESP", UI.icon.eye)

local drawCard = espPage:Card("DRAWING", 1):Accent()
drawCard:Toggle("Box", CONFIG.box, function(v) CONFIG.box = v end,
	"projected from head to feet, follows crouching", UI.theme.good)
drawCard:Toggle("Filled box", CONFIG.boxFilled, function(v) CONFIG.boxFilled = v end,
	"tinted area inside the box")
drawCard:Toggle("Name", CONFIG.name, function(v) CONFIG.name = v end)
drawCard:Toggle("Armour marker", CONFIG.armorIcon, function(v) CONFIG.armorIcon = v end,
	"+ kevlar, ! kevlar and helmet, K defuse kit", UI.theme.good)
drawCard:Toggle("Health bar", CONFIG.health, function(v) CONFIG.health = v end)
drawCard:Toggle("Health number", CONFIG.hpText, function(v) CONFIG.hpText = v end)
drawCard:Toggle("Weapon", CONFIG.weapon, function(v) CONFIG.weapon = v end,
	"* means scoped, _ means crouching", UI.theme.good)
drawCard:Toggle("Ammo", CONFIG.ammo, function(v) CONFIG.ammo = v end,
	"the enemy's live magazine - the server publishes it for everyone",
	UI.theme.good)
drawCard:Toggle("Money", CONFIG.money, function(v) CONFIG.money = v end,
	"their cash, above the name")
drawCard:Toggle("Distance", CONFIG.distance, function(v) CONFIG.distance = v end)
drawCard:Toggle("Head dot", CONFIG.headDot, function(v) CONFIG.headDot = v end)
drawCard:Toggle("Skeleton", CONFIG.skeleton, function(v) CONFIG.skeleton = v end,
	"R15 bone lines - busy with many enemies on screen")
drawCard:Toggle("Tracer", CONFIG.tracer, function(v) CONFIG.tracer = v end)

local modeCard = espPage:Card("RANGE & VIEW", 2)
modeCard:Toggle("Wall check", CONFIG.visCheck, function(v) CONFIG.visCheck = v end,
	"rays run on collision group Bullet, so clip brushes do not count as walls",
	UI.theme.good)
modeCard:Toggle("View line", CONFIG.viewLine, function(v) CONFIG.viewLine = v end,
	"short line showing where that player is actually looking")
modeCard:Toggle("Aiming at you", CONFIG.lookWarn, function(v) CONFIG.lookWarn = v end,
	"recolours anybody whose crosshair is on you", UI.theme.warn)
modeCard:Slider("Aim cone (deg)", 3, 45, CONFIG.lookDeg, function(v) CONFIG.lookDeg = v end,
	"how tight 'on you' has to be")
modeCard:Toggle("Draw team mates", CONFIG.teamESP, function(v) CONFIG.teamESP = v end)
modeCard:Toggle("Draw dead players", CONFIG.deadESP, function(v) CONFIG.deadESP = v end,
	"bodies stay parented in this game")
modeCard:Slider("Max distance", 100, 3000, CONFIG.maxDist, function(v) CONFIG.maxDist = v end)
modeCard:Slider("Text size", 12, 26, CONFIG.textSize, function(v) CONFIG.textSize = v end,
	"whole pixels; below 12 every Drawing face turns to mush")
modeCard:Dropdown("Font", FONTLIST, CONFIG.textFont, function(v) CONFIG.textFont = v end)
modeCard:Toggle("Text outline", CONFIG.textOutline, function(v) CONFIG.textOutline = v end)
modeCard:Toggle("Shrink with distance", CONFIG.textShrink, function(v)
	CONFIG.textShrink = v
end)

local colCard = espPage:Card("COLOURS", 1)
colCard:Colour("Enemies", CONFIG.colEnemy, function(c) CONFIG.colEnemy = c end,
	"behind a wall the same colour is drawn at 55% brightness")
colCard:Colour("Team mates", CONFIG.colMate, function(c) CONFIG.colMate = c end)
colCard:Colour("Aiming at you", CONFIG.colLook, function(c) CONFIG.colLook = c end)
colCard:Colour("FOV circle", CONFIG.colFov, function(c) CONFIG.colFov = c end)

local chamCard = espPage:Card("CHAMS", 2)
chamCard:Toggle("Chams", CONFIG.chams, function(v)
	CONFIG.chams = v
	if not v then clearChams() end
end, "Highlight through walls; lives in CoreGui, not in the game tree", UI.theme.warn)
chamCard:Dropdown("Style", CHAM_LIST, CONFIG.chamStyle, function(v) CONFIG.chamStyle = v end)
chamCard:Toggle("Rainbow", CONFIG.chamRainbow, function(v) CONFIG.chamRainbow = v end)
chamCard:Toggle("Colour by health", CONFIG.chamByHealth, function(v)
	CONFIG.chamByHealth = v
end)
chamCard:Toggle("Own cham colour", CONFIG.colChamOwn, function(v) CONFIG.colChamOwn = v end)
chamCard:Colour("Cham colour", CONFIG.colCham, function(c) CONFIG.colCham = c end)

-- VISUALS ----------------------------------------------------------------------

local visPage = win:Page("VISUALS", UI.icon.chart)

local crossCard = visPage:Card("CROSSHAIR", 1):Accent()
crossCard:Toggle("Custom crosshair", CONFIG.crosshair, function(v) CONFIG.crosshair = v end,
	"drawn over the game's own, useful for weapons that hide theirs")
crossCard:Slider("Length", 2, 30, CONFIG.crossSize, function(v) CONFIG.crossSize = v end)
crossCard:Slider("Gap", 0, 20, CONFIG.crossGap, function(v) CONFIG.crossGap = v end)
crossCard:Slider("Thickness", 1, 5, CONFIG.crossThick, function(v) CONFIG.crossThick = v end)
crossCard:Toggle("Centre dot", CONFIG.crossDot, function(v) CONFIG.crossDot = v end)
crossCard:Colour("Colour", CONFIG.colCross, function(c) CONFIG.colCross = c end)

local sprayCard = visPage:Card("SPRAY & CAMERA", 2)
sprayCard:Toggle("Spray overlay", CONFIG.sprayDraw, function(v) CONFIG.sprayDraw = v end,
	"the weapon's own 30-point pattern, bright up to the shot you are on",
	UI.theme.good)
sprayCard:Slider("Overlay size", 30, 260, CONFIG.spraySize, function(v)
	CONFIG.spraySize = v
end, "pixels for the full pattern")
sprayCard:Toggle("Bomb countdown", CONFIG.bombTimer, function(v) CONFIG.bombTimer = v end,
	"large timer once the C4 is planted")
sprayCard:Toggle("Field of view", CONFIG.fovChange, function(v)
	CONFIG.fovChange = v
	if not v then pcall(function() camera.FieldOfView = 70 end) end
end, "client side only - it changes what YOU see, nothing else", UI.theme.warn)
sprayCard:Slider("FOV", 60, 120, CONFIG.fovValue, function(v) CONFIG.fovValue = v end)

local visOut = visPage:Card("MOVEMENT", 0):Readout(6)

-- AIM --------------------------------------------------------------------------

local aimPage = win:Page("AIM", UI.icon.target)

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

local aimCard = aimPage:Card("ACTIVATION", 1):Accent()
reg("aim", aimCard:Toggle("Aim enabled", CONFIG.aim, function(v)
	CONFIG.aim = v
	note(v and "aim on" or "aim off")
end, "moves the CAMERA only - fires no remote and fakes no hit", UI.theme.warn))
aimCard:Dropdown("Trigger", { "Hotkey", "Always", "While firing" }, CONFIG.aimActive,
	function(v) CONFIG.aimActive = v end)
bindButton(aimCard, "AIM KEY", function() return CONFIG.aimKey end,
	function(v) CONFIG.aimKey = v end)
reg("aimPart", aimCard:Dropdown("Aim at", { "Head", "Torso", "Nearest" },
	CONFIG.aimPart, function(v) CONFIG.aimPart = v end))
aimCard:Dropdown("Pick target by", { "Crosshair", "Closest", "Lowest HP" },
	CONFIG.aimPick, function(v) CONFIG.aimPick = v end)
-- Dropdown takes no hint line in the template, so anything that needs explaining
-- goes on the Label above it.
aimCard:Label("Travel curve: Human starts slow, is fastest mid-flick, settles slowly")
reg("aimCurve", aimCard:Dropdown("Travel curve", { "Ease out", "Linear", "Human" },
	CONFIG.aimCurve, function(v) CONFIG.aimCurve = v end))
aimCard:Toggle("Sticky target", CONFIG.aimSticky, function(v)
	CONFIG.aimSticky = v
	stickyTarget = nil
end, "holds one enemy instead of flicking to whoever is a pixel closer",
	UI.theme.good)
reg("aimVisible", aimCard:Toggle("Visible only", CONFIG.aimVisible,
	function(v) CONFIG.aimVisible = v end,
	"never aims at an enemy behind a wall", UI.theme.good))
aimCard:Toggle("Firearms only", CONFIG.aimOnlyGun, function(v) CONFIG.aimOnlyGun = v end,
	"off for knife, grenade, C4 and the taser - read from the config, not the name")
aimCard:Dropdown("Scope condition", { "Always", "Scoped only", "Not scoped" },
	CONFIG.aimAds, function(v) CONFIG.aimAds = v end)
aimCard:Slider("Max distance", 50, 3000, CONFIG.aimMaxDist, function(v)
	CONFIG.aimMaxDist = v
end)

local shotCard = aimPage:Card("FIRST BULLET", 2)
reg("aimFov", shotCard:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov,
	function(v) CONFIG.aimFov = v end,
	"only enemies inside this circle around the crosshair"))
reg("aimSmoothH", shotCard:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH,
	function(v) CONFIG.aimSmoothH = v end,
	"horizontal; 1 = instant, 50 = about a second, frame rate independent"))
reg("aimSmoothV", shotCard:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV,
	function(v) CONFIG.aimSmoothV = v end,
	"vertical - slower than H takes the give-away snap off the head"))

local spray2Card = aimPage:Card("OTHER BULLETS", 2)
spray2Card:Toggle("Use first bullet settings", CONFIG.aimSameAll, function(v)
	CONFIG.aimSameAll = v
end, "off = separate numbers for the rest of the magazine", UI.theme.good)
spray2Card:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov2, function(v) CONFIG.aimFov2 = v end)
spray2Card:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH2, function(v)
	CONFIG.aimSmoothH2 = v
end)
spray2Card:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV2, function(v)
	CONFIG.aimSmoothV2 = v
end)

local fireCard = aimPage:Card("AUTO FIRE & DELAYS", 1)
reg("aimFire", fireCard:Toggle("Auto fire", CONFIG.aimFire,
	function(v) CONFIG.aimFire = v end,
	"pulls the trigger itself once a target is held", UI.theme.warn))
reg("aimHitPct", fireCard:Slider("Hit chance %", 1, 100, CONFIG.aimHitPct, function(v)
	CONFIG.aimHitPct = v
end, "below 100 deliberately skips shots"))
fireCard:Slider("Delay after kill (ms)", 0, 1000, CONFIG.aimKillMs, function(v)
	CONFIG.aimKillMs = v
end, "do not stay glued to a corpse - the most obvious tell there is")
fireCard:Slider("First bullet delay (ms)", 0, 1000, CONFIG.aimFirstMs, function(v)
	CONFIG.aimFirstMs = v
end)
fireCard:Toggle("Draw FOV", CONFIG.aimCircle, function(v) CONFIG.aimCircle = v end)
fireCard:Toggle("Draw second FOV", CONFIG.aimCircle2, function(v) CONFIG.aimCircle2 = v end)

local aimOut = aimPage:Card("TARGET", 1):Readout(6)

-- TRIGGER ----------------------------------------------------------------------

local trigPage = win:Page("TRIGGER", UI.icon.bolt)

local trigCard = trigPage:Card("TRIGGERBOT", 1):Accent()
reg("trig", trigCard:Toggle("Trigger enabled", CONFIG.trig, function(v)
	CONFIG.trig = v
	note(v and "trigger on" or "trigger off")
end, "fires when an enemy is under the crosshair - a real mouse click",
	UI.theme.warn))
trigCard:Dropdown("Trigger", { "Hotkey", "Always" }, CONFIG.trigActive,
	function(v) CONFIG.trigActive = v end)
bindButton(trigCard, "TRIGGER KEY", function() return CONFIG.trigKey end,
	function(v) CONFIG.trigKey = v end)
trigCard:Dropdown("Fire mode", { "Click", "Hold" }, CONFIG.trigMode,
	function(v) CONFIG.trigMode = v end)
trigCard:Slider("Hold time (ms)", 20, 600, CONFIG.trigHoldMs, function(v)
	CONFIG.trigHoldMs = v
end, "Hold mode only - for full auto weapons")
trigCard:Toggle("Head only", CONFIG.trigHeadOnly, function(v) CONFIG.trigHeadOnly = v end,
	"fires only when the ray lands on the Head part")
trigCard:Toggle("Firearms only", CONFIG.trigOnlyGun, function(v) CONFIG.trigOnlyGun = v end)
trigCard:Dropdown("Scope condition", { "Always", "Scoped only", "Not scoped" },
	CONFIG.trigAds, function(v) CONFIG.trigAds = v end)

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
reg("humTrigFat", trigTime:Slider("Burst fatigue (ms/shot)", 0, 60, CONFIG.humTrigFat,
	function(v) CONFIG.humTrigFat = v end,
	"each shot inside one hold costs a little more - identical timing is a pattern"))
trigTime:Slider("Shots per hold", 0, 30, CONFIG.trigBurst, function(v)
	CONFIG.trigBurst = v
end, "0 = unlimited")

local trigAim = trigPage:Card("TARGET WINDOW", 2)
trigAim:Slider("FOV (pixels)", 0, 60, CONFIG.trigFov, function(v) CONFIG.trigFov = v end,
	"0 = the exact centre ray only; above that a ring of six more rays")
trigAim:Slider("Max distance", 50, 3000, CONFIG.trigMaxDist, function(v)
	CONFIG.trigMaxDist = v
end)

local trigOut = trigPage:Card("STATUS", 1):Readout(5)

-- RECOIL -----------------------------------------------------------------------

local rcsPage = win:Page("RECOIL", UI.icon.wave)

local rcsCard = rcsPage:Card("RECOIL CONTROL", 1):Accent()
reg("rcs", rcsCard:Toggle("RCS enabled", CONFIG.rcs, function(v)
	CONFIG.rcs = v
	note(v and "rcs on" or "rcs off")
end, "camera side only", UI.theme.warn))
rcsCard:Label("Measured learns from your own mouse, Pattern uses the game's own curve")
rcsCard:Dropdown("Source", { "Measured", "Pattern", "Both" }, CONFIG.rcsMode,
	function(v) CONFIG.rcsMode = v end)
reg("rcsPitch", rcsCard:Slider("Pitch %", 0, 100, CONFIG.rcsPitch,
	function(v) CONFIG.rcsPitch = v end,
	"share of the vertical kick that is taken back out"))
reg("rcsYaw", rcsCard:Slider("Yaw %", 0, 100, CONFIG.rcsYaw,
	function(v) CONFIG.rcsYaw = v end))
rcsCard:Slider("Start at shot", 1, 10, CONFIG.rcsAfter, function(v) CONFIG.rcsAfter = v end,
	"the first bullet has no recoil, so there is nothing to cancel")
rcsCard:Slider("Max correction (deg)", 1, 15, CONFIG.rcsMaxDeg, function(v)
	CONFIG.rcsMaxDeg = v
end, "hard per-frame cap so the correction cannot oscillate")
rcsCard:Toggle("Learn pattern scale", CONFIG.rcsPatAuto, function(v)
	CONFIG.rcsPatAuto = v
end, "one pattern unit in camera radians, measured while you spray",
	UI.theme.good)
rcsCard:Slider("Manual scale (x100)", 1, 100, CONFIG.rcsPatScale * 100, function(v)
	CONFIG.rcsPatScale = v / 100
end, "only used when the learning above is off")

local rcsOut = rcsPage:Card("MEASUREMENT", 2):Readout(8)
local wpnOut = rcsPage:Card("WEAPON", 2):Readout(9)

-- HUMANISER --------------------------------------------------------------------

local humPage = win:Page("HUMAN", UI.icon.shield)

local presetCard = humPage:Card("PRESETS", 1):Accent()
presetCard:Label("Each preset writes the whole page at once and stays editable")
presetCard:Button("LEGIT", function() applyPreset("Legit") end, UI.theme.good)
presetCard:Button("NORMAL", function() applyPreset("Normal") end, UI.theme.band)
presetCard:Button("RAW", function() applyPreset("Raw") end, UI.theme.bad)

local humCard = humPage:Card("HUMANISER", 1):Accent()
reg("hum", humCard:Toggle("Humaniser", CONFIG.hum, function(v)
	CONFIG.hum = v
	note(v and "humaniser on" or "humaniser OFF")
end, "everything below only applies while this is on", UI.theme.good))
-- The single most important number on this page: see the comment on humTurnCap.
reg("humTurnCap", humCard:Slider("Turn speed cap (deg/s)", 40, 3000, CONFIG.humTurnCap,
	function(v) CONFIG.humTurnCap = v end,
	"a fast human flick is 400-900; smoothing alone cannot cap this"))
reg("humDeadzone", humCard:Slider("Deadzone (px)", 0, 20, CONFIG.humDeadzone,
	function(v) CONFIG.humDeadzone = v end,
	"inside this the camera is left completely alone"))
reg("humWindupMin", humCard:Slider("Wind-up min (ms)", 0, 400, CONFIG.humWindupMin,
	function(v) CONFIG.humWindupMin = v end,
	"nothing moves for this long after a target is acquired"))
reg("humWindupMax", humCard:Slider("Wind-up max (ms)", 0, 400, CONFIG.humWindupMax,
	function(v) CONFIG.humWindupMax = v end))
reg("humOffsetPct", humCard:Slider("Aim point offset %", 0, 100, CONFIG.humOffsetPct,
	function(v) CONFIG.humOffsetPct = v end,
	"how far off the centre of the hitbox to sit, per engagement"))
reg("humRerollMs", humCard:Slider("Offset re-roll (ms)", 0, 4000, CONFIG.humRerollMs,
	function(v) CONFIG.humRerollMs = v end,
	"holding the same millimetre for six seconds is as readable as dead centre"))
humCard:Slider("Drift", 0, 40, CONFIG.humJitter * 10, function(v)
	CONFIG.humJitter = v / 10
end, "slow continuous wander of the aim point - smooth noise, not per-frame noise")
humCard:Slider("Drift speed", 1, 60, CONFIG.humJitterHz * 10, function(v)
	CONFIG.humJitterHz = v / 10
end)
reg("humHeadPct", humCard:Slider("Head share %", 0, 100, CONFIG.humHeadPct, function(v)
	CONFIG.humHeadPct = v
end, "the rest of the engagements go for the torso - a 100% headshot rate is the one number a review looks at"))

local humCard2 = humPage:Card("MOVEMENT & MISTAKES", 2)
reg("humOvershoot", humCard2:Slider("Overshoot %", 0, 100, CONFIG.humOvershoot,
	function(v) CONFIG.humOvershoot = v end,
	"share of engagements that go slightly past and settle back"))
reg("humOverDeg", humCard2:Slider("Overshoot size (deg)", 0, 8, CONFIG.humOverDeg,
	function(v) CONFIG.humOverDeg = v end))
reg("humMoveFov", humCard2:Slider("FOV while moving %", 10, 100, CONFIG.humMoveFov,
	function(v) CONFIG.humMoveFov = v end,
	"tracking as well while sprinting as while standing still is its own tell"))
reg("humSwitchMs", humCard2:Slider("Target switch lock (ms)", 0, 1500, CONFIG.humSwitchMs,
	function(v) CONFIG.humSwitchMs = v end,
	"nobody else can take the lock until the current target has been held this long"))
reg("humBreakPct", humCard2:Slider("Lock break %/s", 0, 40, CONFIG.humBreakPct,
	function(v) CONFIG.humBreakPct = v end,
	"chance per second that the lock simply slips for a moment"))
reg("humBreakMs", humCard2:Slider("Break length (ms)", 40, 600, CONFIG.humBreakMs,
	function(v) CONFIG.humBreakMs = v end))
reg("humFatigue", humCard2:Slider("Fatigue %/s", 0, 100, CONFIG.humFatigue,
	function(v) CONFIG.humFatigue = v end,
	"a long hold gets slower, the way a hand does"))
reg("humCooldown", humCard2:Slider("Cooldown (ms)", 0, 800, CONFIG.humCooldown,
	function(v) CONFIG.humCooldown = v end,
	"forced pause between two engagements"))
reg("humMissPct", humCard2:Slider("Deliberate miss %", 0, 40, CONFIG.humMissPct,
	function(v) CONFIG.humMissPct = v end,
	"subtracted from every hit chance"))
reg("humReactSd", humCard2:Slider("Reaction spread (ms)", 1, 120, CONFIG.humReactSd,
	function(v) CONFIG.humReactSd = v end,
	"width of the bell around the middle of the trigger's min/max"))

local safeCard = humPage:Card("WHEN TO STOP", 1)
safeCard:Label("Spectators: the server says how many people are watching YOU")
safeCard:Label("Soften = slower aim, torso only, no auto fire, no trigger")
reg("humSpecMode", safeCard:Dropdown("While spectated", { "Soften", "Disable", "Ignore" },
	CONFIG.humSpecMode, function(v) CONFIG.humSpecMode = v end))
safeCard:Slider("Spectators needed", 1, 5, CONFIG.humSpecMin, function(v)
	CONFIG.humSpecMin = v
end, "late in a round every living player is watched, so 1 is a low bar")
safeCard:Toggle("Off on vote kick", CONFIG.humVoteOff, function(v)
	CONFIG.humVoteOff = v
end, "a vote naming you switches every assist off", UI.theme.good)
safeCard:Toggle("Off while the panel is open", CONFIG.humPanelPause, function(v)
	CONFIG.humPanelPause = v
end, "nothing should assist while you are clicking in here")
safeCard:Slider("Quiet after round change (ms)", 0, 3000, CONFIG.humRoundMs,
	function(v) CONFIG.humRoundMs = v end,
	"freeze time is when nine other people are looking at you")

-- The panic key. Registered here rather than next to the InputBegan handler,
-- because it also has to put the four toggles back to OFF on screen - a script
-- that stops assisting while its own switches still read "on" is worse than one
-- that never stopped.
safeCard:Label("Panic key: switches aim, trigger, auto fire and RCS off at once")
local panicPaint = bindButton(safeCard, "PANIC KEY", function() return CONFIG.panicKey end,
	function(v) CONFIG.panicKey = v end)
table.insert(panicHandlers, function()
	for _, key in ipairs({ "aim", "trig", "aimFire", "rcs" }) do
		local handle = CTL[key]
		if handle then pcall(function() handle:set(false) end) end
	end
end)

local humOut = humPage:Card("STATUS", 1):Readout(7)

-- ROUND ------------------------------------------------------------------------

local infoPage = win:Page("ROUND", UI.icon.list)
local roundOut = infoPage:Card("ROUND", 0):Readout(5, function(text)
	if text:find("BOMB PLANTED") then return UI.theme.bad end
	return nil
end)
local listOut = infoPage:Card("PLAYERS", 0):Readout(12, function(text)
	if text:sub(1, 3) == " T " then return Color3.fromRGB(235, 190, 90) end
	if text:sub(1, 3) == " CT" then return Color3.fromRGB(110, 180, 255) end
	return nil
end)

--------------------------------------------------------------------------------
-- the panel refresh
--------------------------------------------------------------------------------

local function short(n)
	n = tonumber(n) or 0
	if n >= 1000 then return string.format("%.1fK", n / 1000) end
	return tostring(math.floor(n))
end

local function teamTag(p)
	local t = teamOf(p)
	if t == nil then return "- " end
	return (tostring(t):sub(1, 1) == "C") and "CT" or "T "
end

task.spawn(function()
	while _G.__BSTRIKE == GEN do
		local ok, err = pcall(function()
			STATE.map       = tostring(wsAttr("Map", "-"))
			STATE.gamemode  = tostring(wsAttr("Gamemode", "-"))
			STATE.gamestate = tostring(wsAttr("GameState", "-"))
			STATE.timer     = tonumber(wsAttr("Timer", 0)) or 0
			STATE.buyTimer  = tonumber(wsAttr("BuyTimerRemaining", 0)) or 0
			STATE.ctScore   = tonumber(wsAttr("CTScore", 0)) or 0
			STATE.tScore    = tonumber(wsAttr("TScore", 0)) or 0
			STATE.spectators = tonumber(plr:GetAttribute("Spectators")) or 0

			local ownChar = charOf(plr)
			local root = ownChar and ownChar:FindFirstChild("HumanoidRootPart")
			if root then
				local v = root.AssemblyLinearVelocity
				STATE.speed = Vector3.new(v.X, 0, v.Z).Magnitude
			else
				STATE.speed = 0
			end

			local aliveCT, aliveT = 0, 0
			local rows = {}
			local camPos = camera.CFrame.Position
			local carrier = "-"

			for _, p in ipairs(Players:GetPlayers()) do
				local char, hp, _, proot = alive(p)
				local tag = teamTag(p)
				-- Only a KNOWN team is counted. teamTag gives "- " for a player with
				-- no Team attribute, and an else-branch would have filed every one of
				-- those under T.
				if char then
					if tag == "CT" then aliveCT = aliveCT + 1
					elseif tag == "T " then aliveT = aliveT + 1 end
				end

				-- The bomb carrier is not a flag anywhere: it is whoever has the C4 in
				-- a loadout slot. Slot5 is where it sits, but the slots are read in
				-- full so a different slot layout cannot hide it.
				for i = 1, 5 do
					local slot = decode(p:GetAttribute("Slot" .. i))
					if type(slot) == "table" and slot.Weapon == "C4" then
						carrier = p.Name
						break
					end
				end

				local eq = equippedOf(p)
				local dist = proot and math.floor((camPos - proot.Position).Magnitude) or nil
				table.insert(rows, {
					enemy = isEnemy(p),
					alive = char ~= nil,
					line = string.format(" %-2s %-14s %-5s %-9s %-5s %-4s $%s",
						tag,
						p.Name:sub(1, 14),
						char and (math.floor(hp) .. "hp") or "DEAD",
						(eq and tostring(eq.Name):sub(1, 9)) or "-",
						(eq and eq.Rounds) and (tostring(eq.Rounds) .. "r") or "-",
						dist and (dist .. "m") or "-",
						short(p:GetAttribute("Money") or 0)),
				})
			end

			STATE.bombCarrier = carrier

			-- Enemies first, then alive before dead: the two things looked at
			-- mid-round are "who is left" and "what are they holding".
			table.sort(rows, function(a, b)
				if a.enemy ~= b.enemy then return a.enemy end
				if a.alive ~= b.alive then return a.alive end
				return a.line < b.line
			end)

			STATE.alive.ct, STATE.alive.t = aliveCT, aliveT

			local lines = { " TE NAME           HP    WEAPON    AMMO  DIST CASH" }
			for i = 1, math.min(#rows, 11) do table.insert(lines, rows[i].line) end
			pcall(function() listOut:set(lines) end)

			pcall(function()
				roundOut:set({
					string.format("  %s   %s   CT %d : %d T",
						STATE.map, STATE.gamemode, STATE.ctScore, STATE.tScore),
					string.format("  %s   %ds left%s", STATE.gamestate, STATE.timer,
						STATE.buyTimer > 0 and ("   buy " .. STATE.buyTimer .. "s") or ""),
					STATE.bombPlanted and "  BOMB PLANTED"
						or ("  C4 carried by: " .. STATE.bombCarrier),
					string.format("  alive   CT %d   T %d      drawn %d   aiming at you %d",
						STATE.alive.ct, STATE.alive.t, STATE.targets, STATE.lookAt),
					"  " .. tostring(STATE.note),
				})
			end)

			local cfg, wname, eqInfo = myWeapon()

			pcall(function()
				local fov, sh, sv = aimNumbers()
				aimOut:set({
					"  target   " .. tostring(STATE.target)
						.. "   shot " .. tostring(STATE.shots),
					"  active   " .. (CONFIG.aim and CONFIG.aimActive or "off")
						.. (CONFIG.aimActive == "Hotkey"
							and ("  " .. keyDisplay(CONFIG.aimKey)) or ""),
					string.format("  now      FOV %dpx   H %d   V %d", fov, sh, sv),
					"  weapon   " .. STATE.weapon
						.. (cfg and (isGun(cfg) and "  (firearm)" or "  (no shots)") or ""),
					"  blocked  " .. ((STATE.paused ~= "") and STATE.paused or "no"),
					string.format("  turning  %.0f deg/s   peak %.0f   cap %d",
						STATE.aimDps, STATE.aimDpsPeak, CONFIG.humTurnCap),
				})
			end)

			pcall(function()
				trigOut:set({
					"  state    " .. (CONFIG.trig
						and (STATE.trigOn and "armed"
							or ("waiting for " .. keyDisplay(CONFIG.trigKey)))
						or "off"),
					"  crosshair " .. tostring(STATE.underCross),
					string.format("  shots    %d   reaction %d-%dms",
						STATE.trigHits, CONFIG.trigDelayMin, CONFIG.trigDelayMax),
					"  window   " .. (CONFIG.trigFov > 0
						and (CONFIG.trigFov .. "px ring") or "centre ray only")
						.. (CONFIG.trigHeadOnly and "   head only" or ""),
					"  magazine " .. tostring(STATE.rounds) .. " / " .. tostring(STATE.capacity),
				})
			end)

			pcall(function()
				rcsOut:set({
					"  MEASUREMENT",
					string.format("  sens H   %.5f   V %.5f", STATE.sensY, STATE.sensP),
					string.format("  samples  %d", STATE.calibN),
					string.format("  kick H   %.2f deg   V %.2f deg", STATE.kickY, STATE.kickP),
					string.format("  peak V   %.2f deg", STATE.kickPeak),
					string.format("  pattern  dx %.3f  dy %.3f", STATE.patY, STATE.patP),
					string.format("  scale    %.5f   over %d samples",
						STATE.patScale, STATE.patN),
					"  " .. (CONFIG.rcs and (CONFIG.rcsMode .. " active") or "off"),
				})
			end)

			pcall(function()
				if not cfg then
					wpnOut:set({ "  WEAPON", "  " .. STATE.weapon,
						"  no entry in Database.Custom.Weapons" })
				else
					local dmg = cfg.DamagePerPart or {}
					local rec = cfg.Recoil or {}
					local spr = cfg.Spread or {}
					wpnOut:set({
						"  WEAPON",
						"  " .. tostring(wname)
							.. (cfg.Automatic and "   full auto" or "   semi auto")
							.. ((eqInfo and eqInfo.IsSuppressed) and "   suppressed" or ""),
						string.format("  damage   head %s  torso %s  arms %s  legs %s",
							tostring(dmg.Head), tostring(dmg.Torso),
							tostring(dmg.Arms), tostring(dmg.Legs)),
						string.format("  rate     %.2fs   mag %s / %s",
							tonumber(cfg.FireRate) or 0, tostring(cfg.Rounds),
							tostring(cfg.Capacity)),
						string.format("  armour   pen %.0f%%   wallbang %.0f%%",
							(tonumber(cfg.ArmorPenetration) or 0) * 100,
							(tonumber(cfg.WallbangMultiplier) or 0) * 100),
						string.format("  penetr.  %.2f   range %s   falloff %s",
							tonumber(cfg.Penetration) or 0, tostring(cfg.Range),
							tostring(cfg.RangeModifier)),
						string.format("  spread   per shot %s   recovery %s",
							tostring(spr.PerShot), tostring(spr.RecoverySpeed)),
						string.format("  recoil   scale %s  speed %s  camera %s",
							tostring(rec.Scale), tostring(rec.Speed),
							tostring(rec.CameraScale)),
						string.format("  walk     %s studs/s   cost $%s",
							tostring(cfg.WalkSpeed), tostring(cfg.Cost)),
					})
				end
			end)

			pcall(function()
				humOut:set({
					"  humaniser " .. (CONFIG.hum and "on" or "OFF"),
					"  blocked   " .. ((STATE.paused ~= "") and STATE.paused or "no"),
					"  spectators " .. tostring(STATE.spectators)
						.. "  -> " .. (softened() and "softened"
							or (watched() and CONFIG.humSpecMode == "Disable" and "disabled")
							or "no effect"),
					"  vote      " .. tostring(STATE.voteNote),
					"  anticheat " .. tostring(STATE.bacEvents) .. " events   "
						.. tostring(STATE.bacLast),
					"  engagement " .. (engagement
						and string.format("%s  %s  %.1fs", engagement.player.Name,
							engagement.head and "head" or "body",
							os.clock() - engagement.t0)
						or "-"),
					"  panel     " .. (panelOpen() and "open" or "closed")
						.. "   panic " .. keyDisplay(CONFIG.panicKey)
						.. "   cap " .. tostring(CONFIG.humTurnCap) .. " deg/s",
				})
			end)

			pcall(function()
				visOut:set({
					"  MOVEMENT",
					string.format("  speed    %.1f / %.1f studs/s", STATE.speed,
						tonumber(wsAttr("sv_maxspeed", 0)) or 0),
					string.format("  gravity  %s   jump %s",
						tostring(wsAttr("sv_gravity", "-")),
						tostring(wsAttr("sv_jumpspeed", "-"))),
					string.format("  air acc  %s   ground %s",
						tostring(wsAttr("sv_airaccelerate", "-")),
						tostring(wsAttr("sv_groundaccelerate", "-"))),
					string.format("  friction %s   stop %s",
						tostring(wsAttr("sv_friction", "-")),
						tostring(wsAttr("sv_stopspeed", "-"))),
					string.format("  tick     %s Hz   stamina max %s",
						tostring(wsAttr("MovementTickRate", "-")),
						tostring(wsAttr("sv_staminamax", "-"))),
				})
			end)

			pcall(function()
				win:SetStat(1, tostring(STATE.ctScore) .. ":" .. tostring(STATE.tScore),
					"rounds")
				win:SetStat(2, tostring(STATE.alive.ct) .. "v" .. tostring(STATE.alive.t),
					"alive")
				win:SetStat(3, tostring(STATE.targets), "drawn")
				-- The strip title used to be the master switch's caption. With the
				-- switch gone it carries what the script is actually doing.
				win:SetNote(STATE.note ~= "" and STATE.note or "Ready")
				win:SetStatus(string.format("%s   %s   %ds   %s",
					STATE.map, STATE.gamestate, STATE.timer,
					STATE.bombPlanted and "BOMB PLANTED"
						or ("C4: " .. STATE.bombCarrier)))
			end)
		end)
		if not ok then note("ui: " .. tostring(err)) end
		task.wait(0.4)
	end
end)

-- The camera reference is replaced on every respawn, so a cached one silently
-- stops updating after the first death - which looks exactly like "the ESP broke
-- after I died".
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then camera = workspace.CurrentCamera end
end)

workspace.ChildAdded:Connect(function(child)
	if child.Name == "Characters" then charFolder = child end
end)

pcall(function() win:Home() end)
win:Refresh()

--------------------------------------------------------------------------------

_G.__BSTRIKE_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	alive = alive, isEnemy = isEnemy, visible = visible, charOf = charOf,
	teamOf = teamOf, equippedOf = equippedOf, armorOf = armorOf, decode = decode,
	weaponCfg = weaponCfg, isGun = isGun, myWeapon = myWeapon,
	sprayPoints = sprayPoints, lookAngle = lookAngle,
	pickTarget = pickTarget, renderPass = renderPass, aimPass = aimPass,
	rcsPass = rcsPass, shotClock = shotClock, aimNumbers = aimNumbers,
	targetPart = targetPart, underCrosshair = underCrosshair, pullTrigger = pullTrigger,
	gunGate = gunGate, adsGate = adsGate, keyHeld = keyHeld,
	approach = approach, angleDelta = angleDelta, firing = firing,
	humanAimPoint = humanAimPoint, humanPaused = humanPaused, assistBlocked = assistBlocked,
	watched = watched, softened = softened, pauseFor = pauseFor,
	applyPreset = applyPreset, PRESETS = PRESETS, CTL = CTL, movingFrac = movingFrac,
	rerollOffset = rerollOffset,
	newEngagement = newEngagement, endEngagement = endEngagement, gauss = gauss,
	drawn = drawn, highlights = highlights, hideAll = hideAll, clearChams = clearChams,
	note = note, wsAttr = wsAttr, panelOpen = panelOpen,
}

print("[bloxstrike] gen " .. GEN .. " ready - RightShift for the panel")
