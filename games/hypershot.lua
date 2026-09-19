--[[ hypershot.lua - "Hypershot!" (Frosted Studio)

  Places, out of the game's own Modules.GetPlaceType: Main 17516596118, Mobile
  131008473296170, GunGame 122181485177067, MainForNewPlayers 100040622766961,
  Duels 108428559529058, Beginner 86696142930150, GoldenOne / TwitchGauntlet
  103420430505525, DuelHub 134474332601640, SniperOnly 92980558919575. The hub
  entry lists them all and also detects by content.

  Everything below was measured on a live server (Beginner place, CTF and TDM,
  2026-09-19) before a line of it was written.

  * TARGETS ARE TWO LISTS. Real players are ordinary R15 characters in the
    Workspace; bots are Models in `workspace.Mobs` carrying `Bot = true` and a
    `__Bot` name suffix (`GlobalStuff:RemoveBotSuffix` strips it - on screen they
    are indistinguishable from real players). A dead body is moved into
    `workspace.IgnoreThese`. 200 HP for everybody.
  * THE TEAM IS AN ATTRIBUTE, not Player.Team: `Team` on the Player and on the
    character, -1 meaning free-for-all. `GlobalStuff:SameTeam` is the game's own
    check and this script calls it rather than re-implementing it.
  * THE CAMERA IS THE GAME'S OWN. CameraType is Scriptable and the controller
    rebuilds the view every frame out of angles it keeps in
    `ActionHandler:GetCamRot()`. Measured: a direct camera.CFrame write kept
    0.11 deg of 10 after two frames, `ActionHandler:UpdateCamRot` kept 14.96 of
    15 - so the aim writes the game's angles, exactly the way the game's own
    console/mobile aim assist (CameraController.AA) does. No hook, no mouse
    calibration. The mouse path is a dropdown; its scale is `Shared.CurrSens`,
    read, not learned.
  * THE CLIENT REPORTS ITS OWN HITS. Gun.Shoot raycasts from the camera towards
    `GameUIMod:GetMousePos()`, then sends `Shoot(aimPoints, origin, ..., camCF)`
    and `Damage(index, time, origin, {{part, pos}}, gen)`. Measured against a
    target's Humanoid.Health (server owned):
      - an aimed shot                                 200 -> 152
      - the SAME shot bent 35.7 deg off the camera    200 -> 152   (silent aim)
      - three Shoot() calls with no gap at all        200 -> 65 = 3 x 45
    So the server checks neither the angle between the camera and the shot nor
    the fire rate of a three-shot burst.
  * THE GAME HAS ITS OWN CLICK PATH. `Shared.MouseDown = true` +
    `Controller:LeftClick()` is exactly what the mouse handler and the game's
    own auto fire do. Measured: 0.3s held -> 3 shots, 200 -> 56. It has to run
    at thread identity 2 - from a higher one a lazy require inside throws
    "Cannot require a non-RobloxScript module from a RobloxScript".

  WHAT THIS SCRIPT DELIBERATELY DOES NOT DO, AND WHY
  * No hookmetamethod, no hookfunction, no getgc. ReplicatedFirst.LocalScript is
    a Luraph-protected anticheat answering the server through the
    `Aishiteru` RemoteFunction; its string table carries
    `_______ is not a valid member of DataModel`, `:(%d+)[:`, `(internal)`,
    `stack overflow` and `hb_hook_internal` - the metamethod-hook probe - and
    `VirtualInputManager`. So nothing here hooks a metamethod and nothing sends
    input through VirtualInputManager.
  * Duels are RECORDED. ControllerStuff.KeyframeBuffer writes camera angles,
    every shot and every hit at a fixed rate while `DuelID` is set, and the
    server pulls it with `KeyframePull`. A bent shot is a shot whose hit does
    not match the recorded view, so silent aim and rapid fire switch themselves
    off in a duel unless told otherwise.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui
do
	local ok, svc = pcall(game.GetService, game, "CoreGui")
	CoreGui = ok and svc or nil
end

local plr    = Players.LocalPlayer
local camera = workspace.CurrentCamera

local GEN = (_G.__HYPER or 0) + 1
_G.__HYPER = GEN

local function claimIdentity()
	if setthreadidentity then pcall(setthreadidentity, 8) end
	task.wait()
end

-- The game's own code has to be called the way a LocalScript would call it.
local function gameIdentity()
	if setthreadidentity then pcall(setthreadidentity, 2) end
end

local function waitFor(parent, name, timeout)
	if not parent then return nil end
	local ok, child = pcall(function() return parent:WaitForChild(name, timeout or 10) end)
	if ok then return child end
	return nil
end

-- Resolved through getgenv first: a loadstring'd chunk's env hands the executor
-- globals through __index, and a raw read misses them (phantomforces.lua).
local function execFn(name)
	local ok, fn = pcall(function()
		local g = getgenv and getgenv()
		return (g and g[name]) or getfenv()[name]
	end)
	if ok and type(fn) == "function" then return fn end
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
	botTag     = true,
	weaponTag  = true,
	protTag    = true,
	distance   = true,
	tracer     = false,
	headDot    = false,
	skeleton   = false,
	chams      = false,
	showTeam   = false,
	visCheck   = true,
	maxDist    = 1500,
	textSize   = 14,
	textFont   = "System",
	textOutline = true,
	textShrink = false,

	colEnemy   = Color3.fromRGB(255, 72, 88),
	colBot     = Color3.fromRGB(255, 176, 60),
	colTeam    = Color3.fromRGB(80, 170, 255),
	colProt    = Color3.fromRGB(120, 140, 165),
	colCham    = Color3.fromRGB(255, 72, 88),
	colChamOwn = false,
	colFov     = Color3.fromRGB(255, 255, 255),
	colSilent  = Color3.fromRGB(255, 90, 200),

	chamStyle  = "Fill",
	chamRainbow = false,

	-- visuals ------------------------------------------------------------------
	crosshair  = false,
	crossSize  = 8,
	crossGap   = 3,
	crossDot   = true,
	crossThick = 1,
	colCross   = Color3.fromRGB(90, 255, 140),

	-- aim assist ---------------------------------------------------------------
	aim        = false,
	aimActive  = "Hotkey",
	aimKey     = "MouseButton2",
	aimPart    = "Head",
	aimPick    = "Crosshair",
	aimSticky  = true,
	aimVisible = true,
	aimSkipProt = true,
	aimMaxDist = 500,
	aimReady   = true,
	aimAds     = "Always",
	aimCurve   = "Ease out",
	aimPath    = "Game camera",
	aimFov     = 120,
	aimSmoothH = 20,
	aimSmoothV = 24,
	aimFire    = false,
	aimHitPct  = 100,
	aimKillMs  = 300,
	aimFirstMs = 0,
	aimCircle  = true,

	-- trigger ------------------------------------------------------------------
	trig       = false,
	trigActive = "Hotkey",
	trigKey    = "C",
	trigDelayMin = 40,
	trigDelayMax = 110,
	trigHoldMs = 180,
	trigHitPct = 100,
	trigHeadOnly = false,
	trigSkipProt = true,
	trigMaxDist = 500,
	trigAds    = "Always",

	-- silent aim ---------------------------------------------------------------
	silent       = false,
	silentActive = "Hotkey",
	silentKey    = "F",
	silentPart   = "Head",
	silentPick   = "Crosshair",
	silentFov    = 90,
	silentCircle = true,
	silentSkipProt = true,
	silentMaxDist = 500,
	silentDuel   = false,   -- also in a duel, where every shot is recorded

	-- gun mods -----------------------------------------------------------------
	noRecoil   = false,
	noKick     = false,
	noSpread   = false,
	rapid      = false,
	rapidMult  = 1.3,
	modsDuel   = false,

	-- movement -----------------------------------------------------------------
	speed      = false,
	speedAdd   = 8,       -- studs/s on top of the game's own speed (16, +9 sprinting)
	fly        = false,
	flySpeed   = 50,
	flyKey     = "X",     -- toggles fly while playing
	moveDuel   = false,

	-- humaniser ----------------------------------------------------------------
	hum          = true,
	humWindupMin = 40,
	humWindupMax = 130,
	humOffsetPct = 30,
	humJitter    = 0.8,
	humJitterHz  = 1.4,
	humOvershoot = 25,
	humOverDeg   = 1.6,
	humHeadPct   = 55,
	humMissPct   = 0,
	humBreakPct  = 6,
	humBreakMs   = 180,
	humFatigue   = 20,
	humCooldown  = 120,
	humReactSd   = 22,
	humPanelPause = true,
	humBotOnly   = false,
	humTurnCap   = 320,
	humDeadzone  = 2,
	humMoveFov   = 75,
	humSwitchMs  = 350,
	humRerollMs  = 900,
	specPause    = false,

	panicKey     = "End",
}

local DRAWINGS = {
	"box", "boxFilled", "name", "health", "botTag", "weaponTag", "protTag",
	"distance", "tracer", "headDot", "skeleton", "chams",
}

local function anyDrawing()
	for _, key in ipairs(DRAWINGS) do
		if CONFIG[key] then return true end
	end
	return false
end

local PRESETS = {
	["Legit"] = {
		aimFov = 50, aimSmoothH = 34, aimSmoothV = 46, aimPart = "Body",
		aimFire = false, aimVisible = true, aimCurve = "Human",
		trigDelayMin = 110, trigDelayMax = 240, trigHitPct = 85,
		hum = true, humTurnCap = 180, humDeadzone = 4, humWindupMin = 90,
		humWindupMax = 240, humOffsetPct = 50, humHeadPct = 25, humOvershoot = 45,
		humBreakPct = 12, humMissPct = 8, humFatigue = 40, humCooldown = 260,
		humMoveFov = 45,
	},
	["Normal"] = {
		aimFov = 120, aimSmoothH = 20, aimSmoothV = 24, aimPart = "Head",
		aimFire = false, aimVisible = true, aimCurve = "Ease out",
		trigDelayMin = 40, trigDelayMax = 110, trigHitPct = 100,
		hum = true, humTurnCap = 320, humDeadzone = 2, humWindupMin = 40,
		humWindupMax = 130, humOffsetPct = 30, humHeadPct = 55, humOvershoot = 25,
		humBreakPct = 6, humMissPct = 0, humFatigue = 20, humCooldown = 120,
		humMoveFov = 75,
	},
	["Raw"] = {
		aimFov = 400, aimSmoothH = 2, aimSmoothV = 2, aimPart = "Head",
		aimFire = true, aimVisible = true, aimCurve = "Linear",
		trigDelayMin = 0, trigDelayMax = 10, trigHitPct = 100,
		hum = false, humTurnCap = 3000, humDeadzone = 0, humWindupMin = 0,
		humWindupMax = 0, humOffsetPct = 0, humHeadPct = 100, humOvershoot = 0,
		humBreakPct = 0, humMissPct = 0, humFatigue = 0, humCooldown = 0,
		humMoveFov = 100,
	},
}

local STATE = {
	note       = "",
	targets    = 0, bots = 0, humans = 0,
	target     = "-", targetKind = "-",
	paused     = "",
	aimDps     = 0, aimDpsPeak = 0,
	trigOn     = false, underCross = "-", trigShots = 0,
	lastKey    = "-",
	touch      = false,
	deployed   = false,
	duel       = false,
	spectators = 0,
	silentOn   = false, silentTarget = "-", silentNote = "-", silentBent = 0,
	silentSeen = 0,
	mods       = "-",
	weapon     = "-",
	chams      = "-",
	kills = 0, deaths = 0, assists = 0, damage = 0,
	sessionKills = 0, sessionDeaths = 0,
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

local function tryRequire(inst)
	if not inst then return nil end
	local ok, value = pcall(require, inst)
	if ok then return value end
	return nil
end

local Modules  = waitFor(ReplicatedStorage, "Modules", 10)
local GS       = tryRequire(Modules and Modules:FindFirstChild("GlobalStuff"))
local CC       = tryRequire(Modules and Modules:FindFirstChild("ClientCharacters"))
local GameInfo = ReplicatedStorage:FindFirstChild("GameInfo")
local StatsDir = ReplicatedStorage:FindFirstChild("PlayerStats")

if not GS then note("GlobalStuff missing - team and alive checks fall back to attributes") end

-- The in-match controller lives in PlayerGui.ControllerGUI, which is only there
-- while deployed and is replaced on every respawn. It is resolved lazily and
-- only required once it has existed for a moment: the game requires these
-- modules itself on spawn, and requiring one before it did would run it in THIS
-- thread's context instead of the game's.
local CTL = { gui = nil, at = 0, ready = false }

local function ctl()
	local pg = plr:FindFirstChildOfClass("PlayerGui")
	local cg = pg and pg:FindFirstChild("ControllerGUI")
	local root = cg and cg:FindFirstChild("NewMainLocal")
	if root ~= CTL.gui then CTL = { gui = root, at = os.clock(), ready = false } end
	if not root then return nil end
	if CTL.ready then return CTL end
	if os.clock() - CTL.at < 1.5 then return nil end
	CTL.Shared     = tryRequire(root:FindFirstChild("Shared"))
	CTL.Controller = tryRequire(root:FindFirstChild("Controller"))
	local tools = root:FindFirstChild("Tools")
	local tool  = tools and tools:FindFirstChild("Tool")
	CTL.Gun     = tryRequire(tool and tool:FindFirstChild("Gun"))
	CTL.ready   = CTL.Shared ~= nil
	return CTL.ready and CTL or nil
end

local AHC = { inst = nil, mod = nil }
local function actionHandler()
	local pg = plr:FindFirstChildOfClass("PlayerGui")
	local fp = pg and pg:FindFirstChild("FirstPersonGUI")
	local m  = fp and fp:FindFirstChild("ActionHandler")
	if m ~= AHC.inst then AHC = { inst = m, mod = tryRequire(m) } end
	return AHC.mod
end

local UIMC = { inst = nil, mod = nil }
local function gameUIMod()
	local pg = plr:FindFirstChildOfClass("PlayerGui")
	local g  = pg and pg:FindFirstChild("GameUI")
	local m  = g and g:FindFirstChild("GameUIMod")
	if m ~= UIMC.inst then UIMC = { inst = m, mod = tryRequire(m) } end
	return UIMC.mod
end

local function currentTool()
	local c = ctl()
	return c and c.Shared and c.Shared.CurrTool or nil, c
end

local function inDuel() return plr:GetAttribute("DuelID") ~= nil end

--------------------------------------------------------------------------------
-- combatants
--------------------------------------------------------------------------------

local function sameTeam(a, b)
	if GS then
		local ok, same = pcall(GS.SameTeam, GS, a, b)
		if ok then return same == true end
	end
	local ta = a and a:GetAttribute("Team")
	local tb = b and b:GetAttribute("Team")
	if ta == nil or tb == nil or ta == -1 or tb == -1 then return false end
	return ta == tb
end

local function charOf(p)
	if CC then
		local ok, c = pcall(CC.GetCharacter, CC, p)
		if ok and c then return c end
	end
	return p.Character
end

local combatCache, combatAt = {}, 0

local function combatants()
	local now = os.clock()
	if now - combatAt < 0.2 then return combatCache end
	combatAt = now
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= plr then
			local char = charOf(p)
			if char and char.Parent then
				list[#list + 1] = { model = char, name = p.Name, player = p, bot = false,
					team = sameTeam(plr, p) }
			end
		end
	end
	local mobs = workspace:FindFirstChild("Mobs")
	if mobs then
		for _, m in ipairs(mobs:GetChildren()) do
			if m:IsA("Model") then
				local shown = m.Name
				if GS then
					local ok, n = pcall(GS.RemoveBotSuffix, GS, m.Name)
					if ok and n then shown = n end
				end
				list[#list + 1] = { model = m, name = shown, player = nil,
					bot = m:GetAttribute("Bot") == true, mob = m:GetAttribute("Bot") ~= true,
					team = sameTeam(plr, m) }
			end
		end
	end
	combatCache = list
	return list
end

local function aliveOf(model)
	if not model or not model.Parent then return nil end
	if model:GetAttribute("LobbyCharacter") == true then return nil end
	local hum = model:FindFirstChildWhichIsA("Humanoid")
	if not hum or hum.Health <= 0 then return nil end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not model:FindFirstChild("Head") then return nil end
	return hum.Health, hum.MaxHealth, root, hum
end

-- GlobalStuff:CanHit returns nothing for a character carrying a ForceField, so
-- that is what spawn protection is here: the game's own shot ignores them.
local function protectedOf(model)
	return model ~= nil and model:FindFirstChild("ForceField") ~= nil
end

local function weaponOf(model)
	local w = model:GetAttribute("Weapon")
	if w then return tostring(w) end
	local slot = model:GetAttribute("CurrentTool")
	if slot then
		local name = model:GetAttribute("Weapon" .. tostring(slot))
		if name then return tostring(name) end
	end
	return nil
end

local function headPart(model)
	return model:FindFirstChild("HeadHB") or model:FindFirstChild("Head")
end

local function bodyPart(model)
	return model:FindFirstChild("UpperTorso") or model:FindFirstChild("HumanoidRootPart")
end

--------------------------------------------------------------------------------
-- the crosshair and the bullet
--------------------------------------------------------------------------------

local function crosshairPos()
	local vp = camera.ViewportSize
	local ok, locked = pcall(function()
		return UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	end)
	if (ok and locked) or STATE.touch then return Vector2.new(vp.X / 2, vp.Y / 2) end
	local ok2, pos = pcall(function() return UserInputService:GetMouseLocation() end)
	if ok2 and pos then return pos end
	return Vector2.new(vp.X / 2, vp.Y / 2)
end

-- Hitscan's own reach: `WSettings.MaxDist or 500`.
local function weaponRange()
	local tool = currentTool()
	local w = tool and tool.WSettings
	return (w and tonumber(w.MaxDist)) or 500
end

-- The bullet's own filter, rebuilt from GExtra.SetUp: IgnoreThese (bodies,
-- effects, the viewmodel), our character, and every mob on our side.
local ignoreList, ignoreAt = {}, 0
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function bulletIgnore()
	local now = os.clock()
	if now - ignoreAt < 1 and #ignoreList > 0 then return ignoreList end
	ignoreAt = now
	local list = {}
	local ig = workspace:FindFirstChild("IgnoreThese")
	if ig then list[#list + 1] = ig end
	if plr.Character then list[#list + 1] = plr.Character end
	local mobs = workspace:FindFirstChild("Mobs")
	if mobs then
		for _, m in ipairs(mobs:GetChildren()) do
			if sameTeam(plr, m) then list[#list + 1] = m end
		end
	end
	ignoreList = list
	return list
end

local function castTo(toPos, extra)
	local origin = camera.CFrame.Position
	local dir = toPos - origin
	if dir.Magnitude < 0.05 then return nil end
	local list = bulletIgnore()
	if extra then
		list = table.clone(list)
		list[#list + 1] = extra
	end
	rayParams.FilterDescendantsInstances = list
	return workspace:Raycast(origin, dir, rayParams)
end

-- Clear line to the part: a ray that also ignores the target reaches its end.
local function visibleTo(model, part)
	if not part then return false end
	return castTo(part.Position, model) == nil
end

local function modelFromPart(inst)
	local node = inst
	while node and node ~= workspace do
		if node:IsA("Model") and node:FindFirstChildWhichIsA("Humanoid") then return node end
		node = node.Parent
	end
	return nil
end

-- What the next shot would hit, asked the way Hitscan asks it.
local function underCrosshair()
	local origin = camera.CFrame.Position
	local aimPt
	local U = gameUIMod()
	local orig = U and ((_G.__HYPER_MP or {})[U] or U.GetMousePos)
	if orig then
		local ok, pos = pcall(orig, U)
		if ok and typeof(pos) == "Vector3" then aimPt = pos end
	end
	aimPt = aimPt or (origin + camera.CFrame.LookVector * 1000)
	local dir = aimPt - origin
	if dir.Magnitude < 0.05 then return nil end
	local range = math.min(CONFIG.trigMaxDist, weaponRange())
	rayParams.FilterDescendantsInstances = bulletIgnore()
	local hit = workspace:Raycast(origin, dir.Unit * range, rayParams)
	if not hit or not hit.Instance then return nil end
	local model = modelFromPart(hit.Instance)
	if not model or model == plr.Character then return nil end
	if GS then
		local ok, can = pcall(GS.CanHit, GS, plr, hit.Instance)
		if not ok or not can then return nil end
	elseif not aliveOf(model) then
		return nil
	end
	return model, hit.Instance
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

if _G.__HYPER_POOL then
	for _, obj in ipairs(_G.__HYPER_POOL) do pcall(function() obj:Remove() end) end
end
_G.__HYPER_POOL = pool

local function make(kind, props)
	local obj = Drawing.new(kind)
	obj.Visible = false
	for k, v in pairs(props or {}) do obj[k] = v end
	table.insert(pool, obj)
	return obj
end

local BONES = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" },
	{ "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" },
	{ "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" },
	{ "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" },
	{ "RightLowerLeg", "RightFoot" },
}

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
	for _, line in ipairs(set.bones) do line.Visible = false end
end

local function hideAll()
	for _, set in pairs(drawn) do hideSet(set) end
end

--------------------------------------------------------------------------------
-- chams
--------------------------------------------------------------------------------
--
-- Every character already carries the game's own `PlayerOutline` Highlight. Ours
-- lives under gethui()/CoreGui with an Adornee instead, outside the game tree,
-- and every instance touch is guarded - one throwing Highlight must never take
-- the render pass with it (the Deagle Arena lesson).

local chamsFolder = nil
local chamsBroken = nil

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
	if CoreGui then roots[#roots + 1] = CoreGui end
	local pg = plr and plr:FindFirstChildOfClass("PlayerGui")
	if pg then roots[#roots + 1] = pg end
	for _, root in ipairs(roots) do
		local made = nil
		pcall(function()
			local previous = root:FindFirstChild("SeluxHyperChams")
			if previous then previous:Destroy() end
			local folder = Instance.new("Folder")
			folder.Name = "SeluxHyperChams"
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

pcall(chamsRoot)

local highlights = {}

local CHAM_STYLES = {
	["Fill"]         = { fill = 0.35, out = 0,    depth = "AlwaysOnTop" },
	["Solid"]        = { fill = 0,    out = 0,    depth = "AlwaysOnTop" },
	["Outline"]      = { fill = 1,    out = 0,    depth = "AlwaysOnTop" },
	["Glow"]         = { fill = 0.78, out = 0.15, depth = "AlwaysOnTop", boost = 1.6 },
	["Ghost"]        = { fill = 0.6,  out = 0.4,  depth = "AlwaysOnTop", boost = 0.55 },
	["Wall only"]    = { fill = 0.35, out = 0,    depth = "Occluded" },
}
local CHAM_LIST = { "Fill", "Solid", "Outline", "Glow", "Ghost", "Wall only" }

local function chamFor(model)
	local hl = highlights[model]
	if hl then
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

local function chamOff(model)
	local hl = highlights[model]
	if hl then pcall(function() hl.Enabled = false hl.Adornee = nil end) end
end

local function clearChams()
	for model in pairs(highlights) do chamOff(model) end
end

--------------------------------------------------------------------------------
-- static overlays
--------------------------------------------------------------------------------

local fovCircle = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Transparency = 0.5, ZIndex = 1 })
local silentCircle = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Transparency = 0.55, ZIndex = 1 })

local crossLines = {}
for i = 1, 4 do crossLines[i] = make("Line", { Thickness = 1, ZIndex = 4 }) end
local crossDot = make("Circle", { Filled = true, NumSides = 8, Radius = 1, ZIndex = 4 })

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

--------------------------------------------------------------------------------
-- the render pass
--------------------------------------------------------------------------------

local function renderPass()
	if _G.__HYPER ~= GEN then return end
	local mid = crosshairPos()

	fovCircle.Visible = CONFIG.aim and CONFIG.aimCircle
	if fovCircle.Visible then
		fovCircle.Position = mid
		fovCircle.Radius = CONFIG.aimFov
		fovCircle.Color = CONFIG.colFov
	end
	silentCircle.Visible = CONFIG.silent and CONFIG.silentCircle
	if silentCircle.Visible then
		silentCircle.Position = mid
		silentCircle.Radius = CONFIG.silentFov
		silentCircle.Color = CONFIG.colSilent
	end
	drawCrosshair(mid)

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
		local wanted = root and (not entry.team or CONFIG.showTeam)

		if not wanted then
			hideSet(set)
			chamOff(model)
		else
			local dist = (camPos - root.Position).Magnitude
			if dist > CONFIG.maxDist then
				hideSet(set)
				chamOff(model)
			else
				local prot = protectedOf(model)
				local seen = true
				if CONFIG.visCheck and not entry.team then
					seen = visibleTo(model, headPart(model)) or visibleTo(model, bodyPart(model))
				end
				local base
				if entry.team then base = CONFIG.colTeam
				elseif entry.bot or entry.mob then base = CONFIG.colBot
				else base = CONFIG.colEnemy end
				if prot and CONFIG.protTag and not entry.team then base = CONFIG.colProt end
				local col = seen and base or dimmed(base)

				-- A Highlight is 3D and works off-screen and through walls, so it is
				-- applied before the on-screen gate (the mvsd lesson).
				if CONFIG.chams and not chamsBroken then
					local hl = chamFor(model)
					if hl then
						pcall(function()
							hl.Adornee = model
							applyCham(hl, base)
						end)
					end
				else
					chamOff(model)
				end

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
				else
					count = count + 1
					if entry.bot or entry.mob then bots = bots + 1 else humans = humans + 1 end
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
							local tag = entry.mob and "[MOB] " or (entry.bot and "[BOT] " or "[P] ")
							label = tag .. label
						end
						set.name.Size = ts
						set.name.Font = face
						set.name.Outline = CONFIG.textOutline
						set.name.Position = Vector2.new(minX + w / 2, minY - (ts + 3))
						set.name.Text = label
						set.name.Color = col
					end

					local bits = {}
					if CONFIG.weaponTag then
						local wpn = weaponOf(model)
						if wpn then bits[#bits + 1] = wpn end
					end
					if CONFIG.health then bits[#bits + 1] = string.format("%d", math.floor(hp)) end
					if CONFIG.distance then bits[#bits + 1] = string.format("%dm", math.floor(dist)) end
					if CONFIG.protTag and prot then bits[#bits + 1] = "PROT" end
					if model:GetAttribute("HasHelmet") then bits[#bits + 1] = "HELM" end
					if model:GetAttribute("Shield") then bits[#bits + 1] = "SHIELD" end
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
				end
			end
		end
	end

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
	if _G.__HYPER ~= GEN or not capturing or armedGuard then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if input.KeyCode == Enum.KeyCode.Escape then capture(nil) return end
	if input.KeyCode == Enum.KeyCode.Unknown then return end
	capture(input.KeyCode.Name)
end)

UserInputService.InputEnded:Connect(function(input)
	if _G.__HYPER ~= GEN or not capturing or armedGuard then return end
	local name = input.UserInputType.Name
	if name:sub(1, 11) ~= "MouseButton" then return end
	capture(name)
end)

--------------------------------------------------------------------------------
-- a client with no mouse and no keyboard
--------------------------------------------------------------------------------
--
-- Hypershot is played on phones (the `IsPhone` attribute is on everybody). A
-- hotkey a phone cannot press falls back to holding the screen, so a saved
-- desktop config comes back working. Firing needs no executor click function at
-- all here - it goes through the game's own click path - so the trigger works
-- on a phone as it is.

local TOUCH = false
pcall(function()
	TOUCH = UserInputService.TouchEnabled
		and not UserInputService.MouseEnabled
		and not UserInputService.KeyboardEnabled
end)
if _G.__HYPER_FORCE_TOUCH then TOUCH = true end
STATE.touch = TOUCH

local touches = setmetatable({}, { __mode = "k" })

local function screenHeld()
	local n = 0
	for input in pairs(touches) do
		local ok, state = pcall(function() return input.UserInputState end)
		if ok and state ~= Enum.UserInputState.End
			and state ~= Enum.UserInputState.Cancel then
			n = n + 1
		else
			touches[input] = nil
		end
	end
	return n > 0
end

UserInputService.InputBegan:Connect(function(input)
	if _G.__HYPER ~= GEN then return end
	if input.UserInputType == Enum.UserInputType.Touch then touches[input] = true end
end)

UserInputService.InputEnded:Connect(function(input)
	if _G.__HYPER ~= GEN then return end
	if input.UserInputType == Enum.UserInputType.Touch then touches[input] = nil end
end)

local function reachable(name)
	if not name or name == "" then return false end
	local spec = resolveKey(name)
	if not spec then return false end
	local ok, enabled = pcall(function()
		if spec.mouse then return UserInputService.MouseEnabled end
		return UserInputService.KeyboardEnabled
	end)
	return ok and enabled and true or false
end

local function hotkeyHeld(name)
	if TOUCH and not reachable(name) then return screenHeld() end
	return keyHeld(name)
end

-- "Is the player shooting" is the game's own flag, so it is right for a mouse,
-- a phone and a controller alike.
local function firing()
	local c = ctl()
	return c ~= nil and c.Shared.MouseDown == true
end

local panicHandlers = {}

UserInputService.InputBegan:Connect(function(input, processed)
	if _G.__HYPER ~= GEN or processed or capturing then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local spec = resolveKey(CONFIG.panicKey)
	if not spec or not spec.key or input.KeyCode ~= spec.key then return end
	CONFIG.aim, CONFIG.trig, CONFIG.aimFire, CONFIG.silent = false, false, false, false
	CONFIG.rapid, CONFIG.fly, CONFIG.speed = false, false, false
	for _, fn in ipairs(panicHandlers) do pcall(fn) end
	note("PANIC - aim, trigger, silent aim, rapid fire, fly and speed off")
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

local function gauss(mean, sd)
	local u1 = math.random()
	local u2 = math.random()
	if u1 < 1e-9 then u1 = 1e-9 end
	return mean + math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2) * sd
end

local engagement = nil

local function newEngagement(model, name)
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

local function panelOpen()
	local win = _G.__HYPER_WIN
	local root = win and win.root
	if not root or not root.Parent then return false end
	local ok, vis = pcall(function() return root.Visible end)
	return ok and vis == true
end

-- `SpectatorCount` is on every player and counts who is watching them. Late in a
-- round everybody alive is watched, so this is a switch, not a default.
local function spectated()
	return (tonumber(plr:GetAttribute("SpectatorCount")) or 0) > 0
end

local function assistBlocked()
	local why = humanPaused()
	if why then return why end
	if CONFIG.hum and CONFIG.humPanelPause and panelOpen() then return "panel open" end
	if CONFIG.specPause and spectated() then return "spectated" end
	return nil
end

--------------------------------------------------------------------------------
-- aim assist
--------------------------------------------------------------------------------

local lastKillAt = 0
local stickyModel = nil

local function aimActive()
	if not CONFIG.aim then return false end
	if CONFIG.aimActive == "Always" then return true end
	if CONFIG.aimActive == "Screen held" then return screenHeld() end
	if CONFIG.aimActive == "While firing" then return firing() end
	return hotkeyHeld(CONFIG.aimKey)
end

local function adsGate(mode)
	if mode == "Always" then return true end
	local c = ctl()
	local on = c ~= nil and c.Shared.Scoping == true
	if mode == "Scoped only" then return on end
	return not on
end

-- Knives, projectile launchers and an empty or reloading gun: nothing to assist.
local function gunReady()
	local tool, c = currentTool()
	if not tool or not tool.WSettings then return false, "no gun" end
	local w = tool.WSettings
	if w.IsMelee then return false, "melee in hand" end
	if c.Shared.Reloading then return false, "reloading" end
	if (tonumber(tool.Ammo) or 0) <= 0 then return false, "empty" end
	if c.Shared.Dead then return false, "dead" end
	return true
end

local function movingFrac()
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return 0 end
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local hum = char:FindFirstChildWhichIsA("Humanoid")
	local maxSpeed = (hum and hum.WalkSpeed) or 16
	return math.clamp(speed / math.max(maxSpeed, 1), 0, 1)
end

local function targetPart(model, want)
	want = want or CONFIG.aimPart
	if want == "Head" then return headPart(model) or bodyPart(model) end
	if want == "Nearest" then
		local mid = crosshairPos()
		local best, bestD
		for _, part in ipairs({ headPart(model), bodyPart(model) }) do
			local sp = camera:WorldToViewportPoint(part.Position)
			if sp.Z > 0 then
				local d = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
				if not bestD or d < bestD then best, bestD = part, d end
			end
		end
		return best or bodyPart(model)
	end
	return bodyPart(model)
end

local function eligible(entry)
	if entry.team then return false end
	if CONFIG.humBotOnly and not (entry.bot or entry.mob) then return false end
	return true
end

-- One candidate walk for the aim and the silent aim, which differ only in their
-- window, their part and their range.
local function bestTarget(fov, part, maxDist, needVisible, skipProt, pickBy)
	local mid = crosshairPos()
	local camPos = camera.CFrame.Position
	local range = math.min(maxDist, weaponRange())
	local best, bestScore
	for _, entry in ipairs(combatants()) do
		if eligible(entry) then
			local hp, _, root = aliveOf(entry.model)
			if hp and not (skipProt and protectedOf(entry.model)) then
				local p = targetPart(entry.model, part)
				local dist = (camPos - root.Position).Magnitude
				if p and dist <= range then
					local sp = camera:WorldToViewportPoint(p.Position)
					if sp.Z > 0 then
						local px = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
						if px <= fov and ((not needVisible) or visibleTo(entry.model, p)) then
							local score
							if pickBy == "Closest" then score = dist
							elseif pickBy == "Lowest HP" then score = hp
							else score = px end
							if not bestScore or score < bestScore then
								best = { entry = entry, part = p, px = px }
								bestScore = score
							end
						end
					end
				end
			end
		end
	end
	return best
end

local function pickTarget()
	local fov = CONFIG.aimFov
	if CONFIG.hum and CONFIG.humMoveFov < 100 then
		fov = fov * (1 - movingFrac() * (1 - CONFIG.humMoveFov / 100))
	end
	return bestTarget(fov, CONFIG.aimPart, CONFIG.aimMaxDist, CONFIG.aimVisible,
		CONFIG.aimSkipProt, CONFIG.aimPick)
end

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
	if CONFIG.aimCurve == "Linear" then return 1 end
	if CONFIG.aimCurve == "Human" then
		local x = math.clamp(1 - progress, 0, 1)
		return 0.35 + 1.3 * math.sin(x * math.pi)
	end
	return 1
end

-- The view the game keeps, in the game's own convention (CameraController.AA):
-- yaw = atan2(dx, dz) + pi, pitch = atan2(dy, horizontal) minus the recoil
-- spring's current pitch, because the spring is added on top of these angles.
local function wantAngles(from, to, A)
	local v = to - from
	local yaw = math.atan2(v.X, v.Z) + math.pi
	local pitch = math.atan2(v.Y, Vector3.new(v.X, 0, v.Z).Magnitude)
	local ok, spring = pcall(function() return A:GetCamRecoilSpring() end)
	if ok and spring then pitch = pitch - spring.Position.Y end
	return yaw, math.clamp(pitch, -1.55, 1.55)
end

local mouseMove = execFn("mousemoverel")

local function moveView(A, curYaw, curPitch, stepYaw, stepPitch)
	if CONFIG.aimPath == "Mouse" and mouseMove then
		local c = ctl()
		local sens = c and tonumber(c.Shared.CurrSens) or 0
		if sens > 0 then
			-- UpdateCamRot(dx*sens, dy*sens) SUBTRACTS both, so a positive x turns
			-- yaw down and a positive y lowers the pitch.
			local dx = -stepYaw / sens
			local dy = -stepPitch / sens
			local settings = c.Shared.MenuCoreData and c.Shared.MenuCoreData.Settings
			if settings and settings["Invert Camera X"] then dx = -dx end
			if settings and settings["Invert Camera Y"] then dy = -dy end
			if math.abs(dx) < 1 and math.abs(dy) < 1 then return end
			pcall(mouseMove, math.floor(dx + 0.5), math.floor(dy + 0.5))
			return
		end
	end
	pcall(function()
		A:UpdateCamRot(Vector2.new(curYaw + stepYaw, curPitch + stepPitch), 0, 0)
	end)
end

local function aimPass(dt)
	if _G.__HYPER ~= GEN then return end
	STATE.aimDps = 0

	local blocked = assistBlocked()
	STATE.paused = blocked or ""
	if blocked then
		STATE.target, STATE.targetKind = "-", "-"
		stickyModel = nil
		endEngagement()
		return
	end
	if not aimActive() then
		STATE.target, STATE.targetKind = "-", "-"
		stickyModel = nil
		if engagement then endEngagement() end
		return
	end
	local c = ctl()
	local A = actionHandler()
	if not c or not A then
		STATE.paused = "not deployed"
		STATE.target = "-"
		stickyModel = nil
		return
	end
	if CONFIG.aimReady then
		local ok, why = gunReady()
		if not ok then STATE.paused = why return end
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
				local px = (Vector2.new(sp.X, sp.Y) - crosshairPos()).Magnitude
				if sp.Z > 0 and px <= CONFIG.aimFov * 1.35
					and ((not CONFIG.aimVisible) or visibleTo(stickyModel, part)) then
					pick = { entry = { model = stickyModel, name = stickyModel.Name,
						bot = stickyModel:GetAttribute("Bot") == true }, part = part, px = px }
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

	if engagement and engagement.model ~= pick.entry.model and CONFIG.hum
		and os.clock() < engagement.lockUntil and aliveOf(engagement.model) then
		local heldPart = targetPart(engagement.model)
		if heldPart then
			pick = { entry = { model = engagement.model, name = engagement.name,
				bot = engagement.model:GetAttribute("Bot") == true }, part = heldPart, px = pick.px }
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
	if CONFIG.hum and CONFIG.humDeadzone > 0 and pick.px <= CONFIG.humDeadzone then
		STATE.paused = "deadzone"
		return
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
	-- The humaniser's head share: an engagement goes for the head only some of
	-- the time, so the headshot count is not a flat hundred (or a flat zero).
	if CONFIG.hum and CONFIG.aimPart ~= "Nearest" then
		part = engagement.head and (headPart(pick.entry.model) or part)
			or (bodyPart(pick.entry.model) or part)
	end
	local dist = (pos - part.Position).Magnitude
	local aimAt = humanAimPoint(part, dist)
	if CONFIG.hum and engagement.over
		and (now - engagement.t0) < engagement.windup + 0.09 then
		local side = (engagement.ox >= 0) and 1 or -1
		aimAt = aimAt + cf.RightVector * side * math.rad(CONFIG.humOverDeg) * dist
	end

	local ok, rot = pcall(function() return A:GetCamRot() end)
	if not ok or typeof(rot) ~= "Vector2" then STATE.paused = "no camera angles" return end
	local curYaw, curPitch = rot.X, rot.Y
	local wantYaw, wantPitch = wantAngles(pos, aimAt, A)
	local dYaw = angleDelta(curYaw, wantYaw)
	local dPitch = wantPitch - curPitch

	local progress = math.clamp(math.max(math.abs(dYaw), math.abs(dPitch)) / 0.5, 0, 1)
	local shape = curveFactor(progress)
	local stepYaw   = dYaw   * math.clamp(approach(smoothH, dt) * shape, 0, 1)
	local stepPitch = dPitch * math.clamp(approach(smoothV, dt) * shape, 0, 1)

	if CONFIG.hum and CONFIG.humTurnCap > 0 then
		local mag = math.sqrt(stepYaw * stepYaw + stepPitch * stepPitch)
		local cap = math.rad(CONFIG.humTurnCap) * math.max(dt, 1e-4)
		if mag > cap and mag > 0 then
			local k = cap / mag
			stepYaw, stepPitch = stepYaw * k, stepPitch * k
		end
	end

	local applied = math.deg(math.sqrt(stepYaw * stepYaw + stepPitch * stepPitch))
	STATE.aimDps = applied / math.max(dt, 1e-4)
	if STATE.aimDps > STATE.aimDpsPeak then STATE.aimDpsPeak = STATE.aimDps end

	moveView(A, curYaw, curPitch, stepYaw, stepPitch)
end

--------------------------------------------------------------------------------
-- silent aim - bend the shot, never claim it
--------------------------------------------------------------------------------
--
-- Gun.Shoot asks `GameUIMod:GetMousePos()` where the crosshair points and
-- raycasts there from the camera. While armed, that one call - and only when
-- Shoot is the caller - answers the target's position instead. The game then
-- does its own ray, its own hit and its own two packets; nothing is forged. The
-- ray still has to reach the target, so a wall stops a bent shot exactly like a
-- straight one.
--
-- It is a plain table field, not a hook, and it is only in place while the key
-- is held: armed off means the game's own function is back. The original is kept
-- in _G per GameUIMod table, so a re-execute restores the real one instead of
-- mistaking the previous run's replacement for it.

local MP = _G.__HYPER_MP or setmetatable({}, { __mode = "k" })
_G.__HYPER_MP = MP
for U, orig in pairs(MP) do
	pcall(function() U.GetMousePos = orig end)
	MP[U] = nil
end

local SIL = { point = nil, installedOn = nil }

local function silentUninstall()
	for U, orig in pairs(MP) do
		pcall(function() U.GetMousePos = orig end)
		MP[U] = nil
	end
	SIL.installedOn = nil
end

local function silentInstall()
	local U = gameUIMod()
	if not U or type(U.GetMousePos) ~= "function" then return false end
	if MP[U] then return true end
	local c = ctl()
	if not (c and c.Gun and type(c.Gun.Shoot) == "function") then return false end
	local orig = U.GetMousePos
	MP[U] = orig
	U.GetMousePos = function(...)
		local pt = SIL.point
		-- Gun.Shoot is looked up LIVE: a respawn rebuilds the controller and with
		-- it the Shoot function, and a captured one would never match again.
		local gun = CTL.Gun
		if pt and gun and _G.__HYPER == GEN and debug.info(2, "f") == gun.Shoot then
			STATE.silentBent = STATE.silentBent + 1
			return pt
		end
		return orig(...)
	end
	SIL.installedOn = U
	return true
end

-- Would a bullet aimed at `pos` land on `model`? Asked with the bullet's OWN
-- filter, target included - which is the whole point: hats and accessories are
-- not in the game's ignore list, Hitscan stops on them, CanHit answers no (an
-- Accessory has no Humanoid) and the shot is spent. That is what made a
-- head-aimed silent shot look like it "sometimes does nothing".
local function shotLands(model, pos)
	local origin = camera.CFrame.Position
	local dir = pos - origin
	if dir.Magnitude < 0.05 then return false end
	rayParams.FilterDescendantsInstances = bulletIgnore()
	local hit = workspace:Raycast(origin, dir.Unit * (dir.Magnitude + 2), rayParams)
	if not hit or modelFromPart(hit.Instance) ~= model then return false end
	if GS then
		local ok, can = pcall(GS.CanHit, GS, plr, hit.Instance)
		return ok and can == true, hit.Instance.Name
	end
	return true, hit.Instance.Name
end

-- The first point on the wanted part that a bullet really reaches, then the
-- rest of the body. A face-height point under the hat brim first, because the
-- centre of the head is exactly where a hat sits.
local function landingPoint(model, want)
	local head = model:FindFirstChild("Head")
	local body = model:FindFirstChild("UpperTorso")
	local root = model:FindFirstChild("HumanoidRootPart")
	local low  = model:FindFirstChild("LowerTorso")
	local points = {}
	local function add(part, offsetY)
		if part then points[#points + 1] = part.Position + Vector3.new(0, offsetY or 0, 0) end
	end
	if want == "Head" then
		add(head, head and -head.Size.Y * 0.2) add(head) add(body) add(root) add(low)
	else
		add(body) add(root) add(low) add(head, head and -head.Size.Y * 0.2)
	end
	for _, pos in ipairs(points) do
		local ok, name = shotLands(model, pos)
		if ok then return pos, name end
	end
	return nil
end

local function silentArmed()
	if not CONFIG.silent then return false, "off" end
	if inDuel() and not CONFIG.silentDuel then return false, "duel - every shot is recorded" end
	local blocked = assistBlocked()
	if blocked then return false, blocked end
	if CONFIG.silentActive == "Always" then return true end
	if CONFIG.silentActive == "Screen held" then return screenHeld(), "waiting for a finger" end
	local held = hotkeyHeld(CONFIG.silentKey)
	return held, "waiting for " .. keyDisplay(CONFIG.silentKey)
end

local function silentPass()
	local armed, why = silentArmed()
	local c = ctl()
	if not armed or not c then
		SIL.point = nil
		STATE.silentOn = false
		STATE.silentTarget = "-"
		STATE.silentNote = armed and "not deployed" or tostring(why or "-")
		if SIL.installedOn or next(MP) then silentUninstall() end
		return
	end
	if not silentInstall() then
		SIL.point = nil
		STATE.silentOn = false
		STATE.silentNote = "GameUIMod / Gun.Shoot not found"
		return
	end
	STATE.silentOn = true
	local pick = bestTarget(CONFIG.silentFov, CONFIG.silentPart, CONFIG.silentMaxDist,
		true, CONFIG.silentSkipProt, CONFIG.silentPick)
	if not pick then
		SIL.point = nil
		STATE.silentTarget = "-"
		STATE.silentNote = "nobody visible in the circle"
		STATE.silentSeen = 0
		return
	end
	STATE.silentSeen = 1
	local point, partName = landingPoint(pick.entry.model, CONFIG.silentPart)
	if not point then
		SIL.point = nil
		STATE.silentTarget = pick.entry.name
		STATE.silentNote = "a hat or an accessory covers every point - holding fire"
		return
	end
	SIL.point = point
	STATE.silentTarget = pick.entry.name .. (pick.entry.bot and "  (bot)" or "  (player)")
	STATE.silentNote = "shots go to " .. partName
end

--------------------------------------------------------------------------------
-- gun mods - the weapon's own numbers
--------------------------------------------------------------------------------
--
-- Recoil, spread and fire rate are all read out of the tool's WSettings table
-- every shot (ViewModel.Recoil and GExtra), so each mod is a field write with
-- the original kept aside and put back when it is switched off. The originals
-- live in _G so a re-execute never records an already-zeroed value as original.
--
--   camera recoil    MinCamRecoil / MaxCamRecoil  - the spring on the VIEW
--   viewmodel kick   Min/Max RotRecoil, TransRecoil - the gun model only
--   spread           Spread, BaseSpread - the cone in ConeOfFire
--   fire rate        Debounce - the gap GetDebounce() hands the Auto loop
--
-- All four act on where the CLIENT'S own ray goes, and the client reports the
-- hit - so a tighter cone is a real hit. The fire rate was measured once: three
-- shots with no gap all counted.

local NILV = "__selux_nil"
local ORIG = _G.__HYPER_ORIG or setmetatable({}, { __mode = "k" })
_G.__HYPER_ORIG = ORIG

local function setField(W, key, value)
	local o = ORIG[W]
	if not o then o = {} ORIG[W] = o end
	if o[key] == nil then
		local cur = W[key]
		o[key] = (cur == nil) and NILV or cur
	end
	W[key] = value
end

local function restoreField(W, key)
	local o = ORIG[W]
	if not o or o[key] == nil then return end
	local v = o[key]
	W[key] = (v ~= NILV) and v or nil
	o[key] = nil
end

local function original(W, key)
	local o = ORIG[W]
	if o and o[key] ~= nil then
		local v = o[key]
		return (v ~= NILV) and v or nil
	end
	return W[key]
end

local ZERO = Vector3.new(0, 0, 0)
local MOD_FIELDS = {
	noRecoil = { "MinCamRecoil", "MaxCamRecoil" },
	noKick   = { "MinRotRecoil", "MaxRotRecoil", "MinTransRecoil", "MaxTransRecoil" },
	noSpread = { "Spread", "BaseSpread" },
	rapid    = { "Debounce" },
}

local function modsAllowed()
	return (not inDuel()) or CONFIG.modsDuel
end

-- WalkSpeed is the game's own sum (MovementController.UpdateWS):
--   BaseWS (16) + CurrTool.WSettings.WSDelta + 9 sprinting + passives/coils
-- so the boost is added to WSDelta of EVERY tool, the knife included, and the
-- game recomputes the speed itself. Nothing fights its controller that way, and
-- the sprint/slide/slow rules all keep working on top of it.
local lastSpeed = nil

local function moveAllowed()
	return (not inDuel()) or CONFIG.moveDuel
end

local function applySpeed(c)
	local want = (CONFIG.speed and moveAllowed()) and CONFIG.speedAdd or 0
	for _, tool in pairs(c.Shared.Tools) do
		local W = type(tool) == "table" and tool.WSettings
		if type(W) == "table" then
			if want ~= 0 then
				local base = tonumber(original(W, "WSDelta")) or 0
				if W.WSDelta ~= base + want then setField(W, "WSDelta", base + want) end
			else
				restoreField(W, "WSDelta")
			end
		end
	end
	if want ~= lastSpeed then
		lastSpeed = want
		-- UpdateWS runs on the game's own events (sprint, equip); nudge it once so
		-- the change shows up now rather than on the next sprint.
		task.spawn(function()
			gameIdentity()
			pcall(function() c.Controller:UpdateWS() end)
		end)
	end
end

local function applyMods()
	local c = ctl()
	if not c or type(c.Shared.Tools) ~= "table" then return end
	pcall(applySpeed, c)
	local allowed = modsAllowed()
	local active = {}
	for _, tool in pairs(c.Shared.Tools) do
		local W = type(tool) == "table" and tool.WSettings
		if type(W) == "table" and not W.IsMelee then
			for mod, fields in pairs(MOD_FIELDS) do
				-- While silent aim is armed the cone is closed too: Hitscan spreads the
				-- bent point exactly like a straight one, and at 200+ studs even two
				-- degrees of cone put the shot a head's width off.
				local on = (CONFIG[mod] or (mod == "noSpread" and STATE.silentOn)) and allowed
				for _, key in ipairs(fields) do
					if on then
						local base = original(W, key)
						if base ~= nil then
							if mod == "rapid" then
								local want = tonumber(base) and (base / math.max(1, CONFIG.rapidMult))
								if want and W[key] ~= want then setField(W, key, want) end
							elseif typeof(base) == "Vector3" then
								if W[key] ~= ZERO then setField(W, key, ZERO) end
							elseif type(base) == "number" then
								if W[key] ~= 0 then setField(W, key, 0) end
							end
							active[mod] = true
						end
					else
						restoreField(W, key)
					end
				end
			end
		end
	end
	local names = {}
	if active.noRecoil then names[#names + 1] = "no recoil" end
	if active.noKick then names[#names + 1] = "no kick" end
	if active.noSpread then names[#names + 1] = "no spread" end
	if active.rapid then names[#names + 1] = string.format("rapid x%.2f", CONFIG.rapidMult) end
	if not allowed and (CONFIG.noRecoil or CONFIG.noKick or CONFIG.noSpread or CONFIG.rapid) then
		names = { "paused - duel" }
	end
	STATE.mods = (#names > 0) and table.concat(names, ", ") or "none"
end

local function restoreAllMods()
	for W, fields in pairs(ORIG) do
		for key in pairs(fields) do restoreField(W, key) end
	end
end

--------------------------------------------------------------------------------
-- fly
--------------------------------------------------------------------------------
--
-- The root part's velocity is written every Heartbeat - no BodyMover, no
-- LinearVelocity, no instance of any kind: GlobalStuff has a
-- CreateProtectedBodyMover, which says the game keeps track of its own movers.
-- Heartbeat runs after the physics step, so the step before the next write still
-- applies one frame of gravity; that frame is paid back in advance.
--
-- Direction: forward/back and strafe come from Humanoid.MoveDirection (so WASD,
-- a gamepad stick and the phone joystick all work), taken along the CAMERA's
-- look so pointing the view up flies up. Space / LeftControl add straight up and
-- down on a keyboard.

local flyWas = false

local function flyStep(dt)
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildWhichIsA("Humanoid")
	local on = CONFIG.fly and moveAllowed() and root and hum and hum.Health > 0
		and char:GetAttribute("LobbyCharacter") ~= true
	if not on then
		if flyWas and root then
			pcall(function() root.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
		end
		flyWas = false
		return
	end
	flyWas = true
	local cf = camera.CFrame
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = flat.Magnitude > 1e-3 and flat.Unit or Vector3.new(0, 0, -1)
	local rightFlat = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
	rightFlat = rightFlat.Magnitude > 1e-3 and rightFlat.Unit or Vector3.new(1, 0, 0)
	local md = hum.MoveDirection
	local fwd = md:Dot(flat)
	local side = md:Dot(rightFlat)
	local dir = look * fwd + rightFlat * side
	if not TOUCH then
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.new(0, 1, 0) end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir - Vector3.new(0, 1, 0) end
	end
	local vel = (dir.Magnitude > 1e-3) and dir.Unit * CONFIG.flySpeed or Vector3.new(0, 0, 0)
	vel = vel + Vector3.new(0, workspace.Gravity * math.max(dt, 1 / 240), 0)
	pcall(function() root.AssemblyLinearVelocity = vel end)
end

-- The panel is built further down; its fly switch is handed in here so the
-- hotkey can move it too (a local declared below this line would be invisible).
local FLY_UI = {}

UserInputService.InputBegan:Connect(function(input, processed)
	if _G.__HYPER ~= GEN or processed or capturing then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local spec = resolveKey(CONFIG.flyKey or "")
	if not spec or not spec.key or input.KeyCode ~= spec.key then return end
	CONFIG.fly = not CONFIG.fly
	if FLY_UI.handle then pcall(function() FLY_UI.handle:set(CONFIG.fly) end) end
	note(CONFIG.fly and "fly on" or "fly off")
end)

--------------------------------------------------------------------------------
-- trigger and auto fire - the game's own click
--------------------------------------------------------------------------------
--
-- `Shared.MouseDown = true` + `Controller:LeftClick()` is what the game's mouse
-- handler does on MouseButton1 and what its own console auto fire does. A semi
-- auto fires once per click; an automatic keeps firing while MouseDown stays true.
-- No executor click function, no VirtualInputManager - the anticheat names that
-- one - and it works on a phone as it is.

local weHold = false

-- LeftClick -> ToolLeftClick -> Activate is SYNCHRONOUS, and for an automatic
-- Activate is the whole Auto.ShootLogic loop: it only returns once MouseDown goes
-- false again. Called inline it would park this thread until the button is
-- released - which only this thread does. The game's own mouse handler calls it
-- from an input event thread for the same reason; this spawns one, and the
-- spawned thread inherits identity 2.
local function pressFire(c)
	if not c.Controller then return false end
	c.Shared.MouseDown = true
	weHold = true
	task.spawn(function()
		local ok, err = pcall(function() c.Controller:LeftClick() end)
		if not ok then note("click: " .. tostring(err)) end
	end)
	STATE.trigShots = STATE.trigShots + 1
	return true
end

local function releaseFire(c)
	if not weHold then return end
	weHold = false
	-- Never let go of a button the player is physically holding.
	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then return end
	if c then c.Shared.MouseDown = false end
end

local function trigActive()
	if not CONFIG.trig then return false end
	if CONFIG.trigActive == "Always" then return true end
	if CONFIG.trigActive == "Screen held" then return screenHeld() end
	return hotkeyHeld(CONFIG.trigKey)
end

local function trigWants(model, part)
	if not model then return false end
	if CONFIG.humBotOnly and model:GetAttribute("Bot") ~= true then return false end
	if CONFIG.trigSkipProt and protectedOf(model) then return false end
	if CONFIG.trigHeadOnly and not (part and (part.Name == "Head" or part.Name == "HeadHB")) then
		return false
	end
	return true
end

task.spawn(function()
	claimIdentity()
	gameIdentity()
	local nextAt, holdUntil = 0, 0
	while _G.__HYPER == GEN do
		local ok, err = pcall(function()
			local c = ctl()
			local model, part = nil, nil
			if c then model, part = underCrosshair() end
			STATE.underCross = model and (model.Name .. "  " .. (part and part.Name or "")) or "-"

			local wantTrig = trigActive() and not assistBlocked()
			local wantAuto = CONFIG.aim and CONFIG.aimFire and STATE.target ~= "-"
				and not assistBlocked()
				and not (engagement and os.clock() - engagement.t0 < engagement.windup)
			STATE.trigOn = wantTrig

			if not c or not (wantTrig or wantAuto) then
				if weHold then releaseFire(c) end
				return
			end
			local ready = gunReady()
			if not ready or not adsGate(CONFIG.trigAds) or not trigWants(model, part) then
				if weHold and os.clock() > holdUntil then releaseFire(c) end
				return
			end
			local tool = c.Shared.CurrTool
			local auto = tool and tool.IsAuto == true

			if weHold and auto then
				holdUntil = os.clock() + CONFIG.trigHoldMs / 1000
				return
			end
			local now = os.clock() * 1000
			if now < nextAt then return end

			local pct = CONFIG.trigHitPct
			if CONFIG.hum and CONFIG.humMissPct > 0 then pct = math.max(1, pct - CONFIG.humMissPct) end
			if math.random(100) > pct then
				nextAt = now + 250
				return
			end

			local lo = math.min(CONFIG.trigDelayMin, CONFIG.trigDelayMax)
			local hi = math.max(CONFIG.trigDelayMin, CONFIG.trigDelayMax)
			local wait
			if CONFIG.hum then
				wait = math.clamp(gauss((lo + hi) / 2, math.max(1, CONFIG.humReactSd)),
					math.max(0, lo - 20), hi + 60)
			else
				wait = (hi > 0) and math.random(lo, hi) or 0
			end
			if wait > 0 then task.wait(wait / 1000) end

			-- Re-check after the reaction delay, or the shot goes where the enemy
			-- was a moment ago.
			local again, againPart = underCrosshair()
			if not trigWants(again, againPart) or not gunReady() then return end

			if pressFire(c) then
				if auto then
					holdUntil = os.clock() + CONFIG.trigHoldMs / 1000
				else
					task.wait(0.03)
					releaseFire(c)
					local deb = tonumber(tool and tool.WSettings and tool.WSettings.Debounce) or 0.2
					nextAt = os.clock() * 1000 + deb * 1000 * (CONFIG.hum and (1 + math.random() * 0.35) or 1)
				end
			end
		end)
		if not ok then note("trigger: " .. tostring(err)) end
		task.wait(0.01)
	end
	pcall(function() releaseFire(ctl()) end)
end)

-- A kill pauses the aim; a model that vanished while it was the target counts.
task.spawn(function()
	claimIdentity()
	local seen = setmetatable({}, { __mode = "k" })
	while _G.__HYPER == GEN do
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

-- Gun mods are re-applied on a timer: a respawn hands out fresh tool objects.
task.spawn(function()
	claimIdentity()
	while _G.__HYPER == GEN do
		local ok, err = pcall(applyMods)
		if not ok then note("mods: " .. tostring(err)) end
		task.wait(0.25)
	end
	pcall(restoreAllMods)
end)

--------------------------------------------------------------------------------
-- the frame bindings
--------------------------------------------------------------------------------

for _, name in ipairs({ "SeluxHyperAim", "SeluxHyperESP" }) do
	pcall(function() RunService:UnbindFromRenderStep(name) end)
end

task.spawn(function()
claimIdentity()
if _G.__HYPER ~= GEN then return end

RunService:BindToRenderStep("SeluxHyperAim", Enum.RenderPriority.Camera.Value - 1,
	function(dt)
		if _G.__HYPER ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxHyperAim") end)
			pcall(silentUninstall)
			return
		end
		local ok, err = pcall(function()
			aimPass(dt)
			silentPass()
		end)
		if not ok then note("aim: " .. tostring(err)) end
	end)

RunService:BindToRenderStep("SeluxHyperESP", Enum.RenderPriority.Camera.Value + 2,
	function()
		if _G.__HYPER ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxHyperESP") end)
			hideAll()
			return
		end
		local ok, err = pcall(renderPass)
		if not ok then note("esp: " .. tostring(err)) end
	end)
end)

-- A position jump the velocity cannot explain is the server putting the root part
-- back. Counted, so the readout says whether speed and fly are being pulled back
-- rather than leaving it to a feeling. Respawns (a jump of hundreds of studs
-- together with a new character) are not counted.
local snap = { pos = nil, char = nil, count = 0, last = 0 }

local function snapWatch(dt)
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then snap.pos = nil return end
	local pos = root.Position
	if snap.pos and snap.char == char then
		local expected = snap.pos + root.AssemblyLinearVelocity * dt
		local off = (pos - expected).Magnitude
		if off > 6 and off < 300 then
			snap.count = snap.count + 1
			snap.last = os.clock()
		end
	end
	snap.pos, snap.char = pos, char
end

local flyConn
flyConn = RunService.Heartbeat:Connect(function(dt)
	if _G.__HYPER ~= GEN then
		if flyConn then flyConn:Disconnect() end
		return
	end
	local ok, err = pcall(flyStep, dt)
	if not ok then note("fly: " .. tostring(err)) end
	pcall(snapWatch, dt)
end)

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then camera = workspace.CurrentCamera end
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__HYPER_WIN then pcall(function() _G.__HYPER_WIN:Destroy() end) end
if UI.sweep then UI.sweep("HypershotPanel") end

UI.config("hypershot", CONFIG)

local win = UI.Window({
	name = "HypershotPanel",
	title = "HYPER", accentTitle = "SHOT", subtitle = "seltonmt",
	badge = "◎", width = 820, height = 582,
})
_G.__HYPER_WIN = win

local CTLS = {}
local function reg(key, handle)
	CTLS[key] = handle
	return handle
end

local function applyPreset(name)
	local set = PRESETS[name]
	if not set then return end
	for key, value in pairs(set) do
		CONFIG[key] = value
		local handle = CTLS[key]
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
		if TOUCH then
			setButton(button, caption .. ": no keyboard on this device")
			task.delay(2.5, paint)
			return
		end
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
drawCard:Toggle("Bot marker", CONFIG.botTag, function(v) CONFIG.botTag = v end,
	"[BOT] or [P] - bots carry real-looking names and the HUD never says which is which",
	UI.theme.good)
drawCard:Toggle("Weapon", CONFIG.weaponTag, function(v) CONFIG.weaponTag = v end,
	"what they are holding, read from their own character")
drawCard:Toggle("Health bar", CONFIG.health, function(v) CONFIG.health = v end,
	"200 HP for everybody")
drawCard:Toggle("Distance", CONFIG.distance, function(v) CONFIG.distance = v end)
drawCard:Toggle("Spawn protection", CONFIG.protTag, function(v) CONFIG.protTag = v end,
	"greys them out - the game's own shot ignores a ForceField", UI.theme.warn)
drawCard:Toggle("Head dot", CONFIG.headDot, function(v) CONFIG.headDot = v end)
drawCard:Toggle("Skeleton", CONFIG.skeleton, function(v) CONFIG.skeleton = v end)
drawCard:Toggle("Tracer", CONFIG.tracer, function(v) CONFIG.tracer = v end)

local modeCard = espPage:Card("RANGE & VIEW", 2)
modeCard:Toggle("Wall check", CONFIG.visCheck, function(v) CONFIG.visCheck = v end,
	"the bullet's own filter: dead bodies, effects and your own team do not count as walls",
	UI.theme.good)
modeCard:Toggle("Show teammates", CONFIG.showTeam, function(v) CONFIG.showTeam = v end,
	"in their own colour; the aim and the trigger never touch them")
modeCard:Slider("Max distance", 100, 3000, CONFIG.maxDist, function(v)
	CONFIG.maxDist = v
end, "how far the ESP draws - the guns reach 500 studs")
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
colCard:Colour("Teammates", CONFIG.colTeam, function(c) CONFIG.colTeam = c end)
colCard:Colour("Spawn protected", CONFIG.colProt, function(c) CONFIG.colProt = c end)
colCard:Colour("FOV circle", CONFIG.colFov, function(c) CONFIG.colFov = c end)

local chamCard = espPage:Card("CHAMS", 2)
chamCard:Toggle("Chams", CONFIG.chams, function(v)
	CONFIG.chams = v
	if not v then clearChams() end
end, "every character already carries the game's own outline, so ours lives outside the game tree",
	UI.theme.warn)
chamCard:Dropdown("Style", CHAM_LIST, CONFIG.chamStyle, function(v) CONFIG.chamStyle = v end)
chamCard:Toggle("Rainbow", CONFIG.chamRainbow, function(v) CONFIG.chamRainbow = v end)
chamCard:Toggle("Own cham colour", CONFIG.colChamOwn, function(v) CONFIG.colChamOwn = v end)
chamCard:Colour("Cham colour", CONFIG.colCham, function(c) CONFIG.colCham = c end)

local visCard = espPage:Card("CROSSHAIR", 0)
visCard:Toggle("Custom crosshair", CONFIG.crosshair, function(v) CONFIG.crosshair = v end)
visCard:Slider("Length", 2, 30, CONFIG.crossSize, function(v) CONFIG.crossSize = v end)
visCard:Slider("Gap", 0, 20, CONFIG.crossGap, function(v) CONFIG.crossGap = v end)
visCard:Slider("Thickness", 1, 5, CONFIG.crossThick, function(v) CONFIG.crossThick = v end)
visCard:Toggle("Centre dot", CONFIG.crossDot, function(v) CONFIG.crossDot = v end)
visCard:Colour("Crosshair colour", CONFIG.colCross, function(c) CONFIG.colCross = c end)
end

-- AIM --------------------------------------------------------------------------

local aimOut

do
local aimPage = win:Page("AIM", UI.icon.target)

local aimCard = aimPage:Card("ACTIVATION", 1):Accent()
reg("aim", aimCard:Toggle("Aim enabled", CONFIG.aim, function(v)
	CONFIG.aim = v
	note(v and "aim on" or "aim off")
end, "turns the game's own camera angles - the same call its console aim assist makes",
	UI.theme.warn))
aimCard:Dropdown("Trigger", { "Hotkey", "Always", "While firing", "Screen held" },
	CONFIG.aimActive, function(v) CONFIG.aimActive = v end)
bindButton(aimCard, "AIM KEY", function() return CONFIG.aimKey end,
	function(v) CONFIG.aimKey = v end)
if TOUCH then
	aimCard:Label("This device has no keyboard and no mouse - a hotkey it cannot press falls back to holding the screen.")
end
reg("aimPart", aimCard:Dropdown("Aim at", { "Head", "Body", "Nearest" },
	CONFIG.aimPart, function(v) CONFIG.aimPart = v end))
aimCard:Dropdown("Pick target by", { "Crosshair", "Closest", "Lowest HP" },
	CONFIG.aimPick, function(v) CONFIG.aimPick = v end)
reg("aimCurve", aimCard:Dropdown("Travel curve", { "Ease out", "Linear", "Human" },
	CONFIG.aimCurve, function(v) CONFIG.aimCurve = v end))
aimCard:Label("View path: a camera write is thrown away here (0.11 of 10 deg kept), the game's own angles hold (14.96 of 15). Mouse moves the real cursor instead, scaled by the game's own sensitivity.")
aimCard:Dropdown("View path", { "Game camera", "Mouse" }, CONFIG.aimPath,
	function(v) CONFIG.aimPath = v end)

local tuneCard = aimPage:Card("TUNING", 2)
reg("aimFov", tuneCard:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov,
	function(v) CONFIG.aimFov = v end, "only targets inside this circle around the crosshair"))
reg("aimSmoothH", tuneCard:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH,
	function(v) CONFIG.aimSmoothH = v end,
	"horizontal; 1 = instant, 50 = about a second, frame rate independent"))
reg("aimSmoothV", tuneCard:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV,
	function(v) CONFIG.aimSmoothV = v end,
	"vertical - slower than H takes the give-away snap off the head"))
tuneCard:Slider("Max distance", 50, 500, CONFIG.aimMaxDist, function(v)
	CONFIG.aimMaxDist = v
end, "a gun's own ray stops at its MaxDist, 500 unless the weapon says otherwise")
reg("aimVisible", tuneCard:Toggle("Visible only", CONFIG.aimVisible,
	function(v) CONFIG.aimVisible = v end,
	"never aims at somebody the bullet ray cannot reach", UI.theme.good))
tuneCard:Toggle("Sticky target", CONFIG.aimSticky, function(v)
	CONFIG.aimSticky = v
	stickyModel = nil
end, "holds one target instead of flicking to whoever is a pixel closer", UI.theme.good)
tuneCard:Toggle("Skip spawn protected", CONFIG.aimSkipProt, function(v)
	CONFIG.aimSkipProt = v
end, "the game's own shot ignores a ForceField", UI.theme.good)
tuneCard:Toggle("Only while the gun can fire", CONFIG.aimReady, function(v)
	CONFIG.aimReady = v
end, "no tracking with a knife, an empty magazine or during a reload")
tuneCard:Dropdown("Scope condition", { "Always", "Scoped only", "Not scoped" },
	CONFIG.aimAds, function(v) CONFIG.aimAds = v end)

local fireCard = aimPage:Card("AUTO FIRE", 1)
reg("aimFire", fireCard:Toggle("Auto fire", CONFIG.aimFire,
	function(v) CONFIG.aimFire = v end,
	"fires through the game's own click while a target is on the crosshair", UI.theme.warn))
reg("aimHitPct", fireCard:Slider("Hit chance %", 1, 100, CONFIG.aimHitPct, function(v)
	CONFIG.aimHitPct = v
end, "below 100 deliberately skips shots"))
fireCard:Slider("Delay after kill (ms)", 0, 1500, CONFIG.aimKillMs, function(v)
	CONFIG.aimKillMs = v
end, "do not stay glued to a corpse - the most obvious tell there is")
fireCard:Toggle("Draw FOV circle", CONFIG.aimCircle, function(v) CONFIG.aimCircle = v end)

aimOut = aimPage:Card("TARGET", 2):Readout(7)
end

-- TRIGGER ----------------------------------------------------------------------

local trigOut

do
local trigPage = win:Page("TRIGGER", UI.icon.bolt)

local trigCard = trigPage:Card("TRIGGERBOT", 1):Accent()
reg("trig", trigCard:Toggle("Trigger enabled", CONFIG.trig, function(v)
	CONFIG.trig = v
	note(v and "trigger on" or "trigger off")
end, "fires when an enemy is under the crosshair - through the game's own click",
	UI.theme.warn))
trigCard:Dropdown("Trigger", { "Hotkey", "Always", "Screen held" }, CONFIG.trigActive,
	function(v) CONFIG.trigActive = v end)
bindButton(trigCard, "TRIGGER KEY", function() return CONFIG.trigKey end,
	function(v) CONFIG.trigKey = v end)
trigCard:Toggle("Head only", CONFIG.trigHeadOnly, function(v) CONFIG.trigHeadOnly = v end,
	"fires only when the ray lands on the head")
trigCard:Toggle("Skip spawn protected", CONFIG.trigSkipProt, function(v)
	CONFIG.trigSkipProt = v
end, "a shot at a ForceField does nothing", UI.theme.good)
trigCard:Dropdown("Scope condition", { "Always", "Scoped only", "Not scoped" },
	CONFIG.trigAds, function(v) CONFIG.trigAds = v end)
trigCard:Label("The trigger asks the game's own CanHit, so a teammate, a ForceField or a dead body can never set it off. Measured: 0.3s held on an automatic = 3 shots, 200 -> 56 HP.")

local trigTime = trigPage:Card("TIMING", 2)
reg("trigDelayMin", trigTime:Slider("Reaction min (ms)", 0, 500, CONFIG.trigDelayMin,
	function(v) CONFIG.trigDelayMin = v end,
	"with the humaniser on this is a bell curve, not a flat band"))
reg("trigDelayMax", trigTime:Slider("Reaction max (ms)", 0, 500, CONFIG.trigDelayMax,
	function(v) CONFIG.trigDelayMax = v end))
trigTime:Slider("Keep firing (ms)", 0, 800, CONFIG.trigHoldMs, function(v)
	CONFIG.trigHoldMs = v
end, "automatics: how long the button stays down after the target leaves the crosshair")
reg("trigHitPct", trigTime:Slider("Hit chance %", 1, 100, CONFIG.trigHitPct,
	function(v) CONFIG.trigHitPct = v end))
trigTime:Slider("Max distance", 50, 500, CONFIG.trigMaxDist, function(v)
	CONFIG.trigMaxDist = v
end)

trigOut = trigPage:Card("STATUS", 1):Readout(6)
end

-- SILENT -----------------------------------------------------------------------

local silentOut

do
local silentPage = win:Page("SILENT", UI.icon.sword)

local sCard = silentPage:Card("SILENT AIM", 1):Accent()
sCard:Label("Bends the shot instead of the view: the gun's own ray goes to the target, the game reports its own hit. Measured against the target's HP: an aimed shot 200 -> 152, the same shot 35.7 deg off the camera 200 -> 152. A wall still stops it. Off by default, in no preset.")
reg("silent", sCard:Toggle("Silent aim", CONFIG.silent, function(v)
	CONFIG.silent = v
	note(v and "silent aim ARMED" or "silent aim off")
end, "the loudest thing in this panel - the kill feed shows hits your view never pointed at",
	UI.theme.bad))
reg("silentFov", sCard:Slider("FOV (pixels)", 5, 600, CONFIG.silentFov, function(v)
	CONFIG.silentFov = v
end, "a target has to be inside this circle"))
sCard:Toggle("Draw the circle", CONFIG.silentCircle, function(v)
	CONFIG.silentCircle = v
end, "the circle IS the reach of this feature", UI.theme.good)
sCard:Colour("Circle colour", CONFIG.colSilent, function(c) CONFIG.colSilent = c end)
sCard:Dropdown("Trigger", { "Hotkey", "Always", "Screen held" }, CONFIG.silentActive,
	function(v) CONFIG.silentActive = v end)
bindButton(sCard, "SILENT KEY", function() return CONFIG.silentKey end,
	function(v) CONFIG.silentKey = v end)
sCard:Dropdown("Aim at", { "Head", "Body" }, CONFIG.silentPart,
	function(v) CONFIG.silentPart = v end)
sCard:Dropdown("Pick target by", { "Crosshair", "Closest", "Lowest HP" },
	CONFIG.silentPick, function(v) CONFIG.silentPick = v end)
sCard:Toggle("Skip spawn protected", CONFIG.silentSkipProt, function(v)
	CONFIG.silentSkipProt = v
end, "a ForceField absorbs the shot", UI.theme.good)
sCard:Slider("Max distance", 50, 500, CONFIG.silentMaxDist, function(v)
	CONFIG.silentMaxDist = v
end)
sCard:Toggle("Also in duels", CONFIG.silentDuel, function(v)
	CONFIG.silentDuel = v
end, "a duel records your camera and every shot for the server - off means silent aim sleeps there",
	UI.theme.bad)

silentOut = silentPage:Card("STATUS", 2):Readout(8)
end

-- GUN --------------------------------------------------------------------------

local gunOut

do
local gunPage = win:Page("GUN", UI.icon.wrench)

local modCard = gunPage:Card("GUN MODS", 1):Accent()
modCard:Label("Each one rewrites a number in your weapon's own settings table and puts the original back when switched off. The client reports its own hits, so a tighter cone lands as a real hit.")
reg("noRecoil", modCard:Toggle("No recoil", CONFIG.noRecoil, function(v)
	CONFIG.noRecoil = v
end, "zeroes MinCamRecoil / MaxCamRecoil - the spring that kicks your view", UI.theme.warn))
reg("noKick", modCard:Toggle("No viewmodel kick", CONFIG.noKick, function(v)
	CONFIG.noKick = v
end, "the gun model only - cosmetic, it does not move the shot"))
reg("noSpread", modCard:Toggle("No spread", CONFIG.noSpread, function(v)
	CONFIG.noSpread = v
end, "zeroes Spread / BaseSpread - every bullet goes exactly where you aim", UI.theme.warn))
reg("rapid", modCard:Toggle("Rapid fire", CONFIG.rapid, function(v)
	CONFIG.rapid = v
end, "shortens the gap between shots - three shots with no gap all counted when measured",
	UI.theme.bad))
modCard:Slider("Fire rate x", 1, 3, CONFIG.rapidMult, function(v)
	CONFIG.rapidMult = v
end, "1.3 = 30% faster; the server was only ever tested on a 3-shot burst")
modCard:Toggle("Also in duels", CONFIG.modsDuel, function(v)
	CONFIG.modsDuel = v
end, "duels are recorded; off means the mods pause there and the originals come back",
	UI.theme.bad)

gunOut = gunPage:Card("YOUR WEAPON", 2):Readout(9)
end

-- MOVE -------------------------------------------------------------------------

local moveOut

do
local movePage = win:Page("MOVE", UI.icon.wave)

local speedCard = movePage:Card("WALKSPEED", 1):Accent()
speedCard:Label("Added to the game's own speed rather than written over it: the game sums BaseWS 16 + your weapon's WSDelta + 9 while sprinting, and this raises the weapon part. Sprint, slide and slows keep working on top.")
reg("speed", speedCard:Toggle("Speed boost", CONFIG.speed, function(v)
	CONFIG.speed = v
end, "movement is client-driven in Roblox - whether the server pulls you back is on the readout",
	UI.theme.warn))
speedCard:Slider("Extra speed (studs/s)", 1, 40, CONFIG.speedAdd, function(v)
	CONFIG.speedAdd = v
end, "normal is 16 walking, 25 sprinting")

local flyCard = movePage:Card("FLY", 2)
FLY_UI.handle = reg("fly", flyCard:Toggle("Fly", CONFIG.fly, function(v)
	CONFIG.fly = v
end, "WASD along the view, Space up, Ctrl down - on a phone the joystick flies where you look",
	UI.theme.bad))
flyCard:Slider("Fly speed", 10, 150, CONFIG.flySpeed, function(v)
	CONFIG.flySpeed = v
end)
bindButton(flyCard, "FLY KEY", function() return CONFIG.flyKey end,
	function(v) CONFIG.flyKey = v end)
flyCard:Toggle("Also in duels", CONFIG.moveDuel, function(v)
	CONFIG.moveDuel = v
end, "duels are recorded - off means speed and fly pause there", UI.theme.bad)

moveOut = movePage:Card("STATUS", 0):Readout(5)
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
end, "aim, trigger and silent aim never touch a real player", UI.theme.good)

local tellCard = humPage:Card("TELLS", 2)
reg("humTurnCap", tellCard:Slider("Turn speed cap (deg/s)", 40, 3000, CONFIG.humTurnCap,
	function(v) CONFIG.humTurnCap = v end,
	"the big one - a fast human flick is roughly 400-900 deg/s"))
reg("humDeadzone", tellCard:Slider("Deadzone (px)", 0, 20, CONFIG.humDeadzone,
	function(v) CONFIG.humDeadzone = v end, "inside this the view is left completely alone"))
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
	function(v) CONFIG.humOvershoot = v end, "a flick that stops dead on target is not a hand"))
reg("humHeadPct", tellCard:Slider("Head share %", 0, 100, CONFIG.humHeadPct,
	function(v) CONFIG.humHeadPct = v end,
	"head every single time is its own pattern - the rest go to the body"))
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
safeCard:Toggle("Pause while spectated", CONFIG.specPause, function(v)
	CONFIG.specPause = v
end, "reads SpectatorCount - late in a round everybody alive is watched, so this is off by default")
safeCard:Label("Panic key: switches aim, trigger, auto fire, silent aim and rapid fire off at once")
bindButton(safeCard, "PANIC KEY", function() return CONFIG.panicKey end,
	function(v) CONFIG.panicKey = v end)
table.insert(panicHandlers, function()
	for _, key in ipairs({ "aim", "trig", "aimFire", "silent", "rapid", "fly", "speed" }) do
		local handle = CTLS[key]
		if handle then pcall(function() handle:set(false) end) end
	end
end)

humOut = humPage:Card("STATUS", 1):Readout(6)
end

-- ROUND ------------------------------------------------------------------------

local roundOut, listOut, statOut

do
local infoPage = win:Page("ROUND", UI.icon.list)
roundOut = infoPage:Card("ROUND", 1):Readout(7)
statOut  = infoPage:Card("YOU", 2):Readout(8)
listOut  = infoPage:Card("TARGETS", 0):Readout(11, function(text)
	if text:find("%[BOT%]") then return Color3.fromRGB(255, 176, 60) end
	if text:find("%[P%]") then return Color3.fromRGB(255, 110, 120) end
	return nil
end)
end

--------------------------------------------------------------------------------
-- the panel refresh
--------------------------------------------------------------------------------

local function statOf(name, key)
	local folder = StatsDir and StatsDir:FindFirstChild(name)
	local v = folder and folder:FindFirstChild(key)
	return v and tonumber(v.Value) or nil
end

local function gameMode()
	if not GameInfo then return "-" end
	local name = GameInfo:GetAttribute("GamemodeName")
	if name then return tostring(name) end
	for _, v in ipairs(GameInfo:GetChildren()) do
		if v:IsA("BoolValue") and v.Value then return v.Name end
	end
	return "-"
end

local function clock(sec)
	sec = math.max(0, math.floor(tonumber(sec) or 0))
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local baseKills, baseDeaths = nil, nil

task.spawn(function()
	claimIdentity()
	while _G.__HYPER == GEN do
		local ok, err = pcall(function()
			local c = ctl()
			local tool = c and c.Shared.CurrTool
			STATE.deployed = c ~= nil and not c.Shared.Dead
			STATE.duel = inDuel()
			STATE.spectators = tonumber(plr:GetAttribute("SpectatorCount")) or 0
			STATE.weapon = tool and tostring(tool.Name) or "-"

			STATE.kills   = statOf(plr.Name, "Kills") or 0
			STATE.deaths  = statOf(plr.Name, "Deaths") or 0
			STATE.assists = statOf(plr.Name, "Assists") or 0
			STATE.damage  = statOf(plr.Name, "DamageDealt") or 0
			if baseKills == nil then baseKills, baseDeaths = STATE.kills, STATE.deaths end
			-- PlayerStats is per MATCH: a new match resets it, and the session base
			-- follows it down rather than showing a negative count.
			if STATE.kills < baseKills or STATE.deaths < baseDeaths then
				baseKills, baseDeaths = STATE.kills, STATE.deaths
			end
			STATE.sessionKills = STATE.kills - baseKills
			STATE.sessionDeaths = STATE.deaths - baseDeaths

			local myTeam = plr:GetAttribute("Team")
			local s1 = GameInfo and GameInfo:FindFirstChild("TeamScores")
				and GameInfo.TeamScores:FindFirstChild("Team1")
			local s2 = GameInfo and GameInfo:FindFirstChild("TeamScores")
				and GameInfo.TeamScores:FindFirstChild("Team2")
			local mine, theirs = "-", "-"
			if s1 and s2 then
				if myTeam == 2 then mine, theirs = s2.Value, s1.Value
				else mine, theirs = s1.Value, s2.Value end
			end

			local camPos = camera.CFrame.Position
			local rows = {}
			for _, entry in ipairs(combatants()) do
				if not entry.team or CONFIG.showTeam then
					local hp, _, root = aliveOf(entry.model)
					local dist = root and math.floor((camPos - root.Position).Magnitude) or nil
					local kills = entry.player and statOf(entry.player.Name, "Kills")
						or statOf(entry.model.Name, "Kills")
					rows[#rows + 1] = {
						alive = hp ~= nil,
						dist = dist or 99999,
						line = string.format(" %-5s %-17s %-6s %-20s %-5s %-6s %s",
							entry.mob and "[MOB]" or (entry.bot and "[BOT]" or "[P]"),
							tostring(entry.name):sub(1, 17),
							hp and (math.floor(hp) .. "hp") or "DEAD",
							tostring(weaponOf(entry.model) or "-"):sub(1, 20),
							kills and tostring(kills) or "-",
							dist and (dist .. "m") or "-",
							entry.team and "TEAM" or (protectedOf(entry.model) and "PROT" or "")),
					}
				end
			end
			table.sort(rows, function(a, b)
				if a.alive ~= b.alive then return a.alive end
				return a.dist < b.dist
			end)
			local lines = { " KIND  NAME              HP     WEAPON               K     DIST   STATE" }
			for i = 1, math.min(#rows, 10) do lines[#lines + 1] = rows[i].line end
			if #rows == 0 then lines[#lines + 1] = "  nobody here - in the lobby?" end
			pcall(function() listOut:set(lines) end)

			pcall(function()
				roundOut:set({
					"  mode      " .. gameMode() .. "   map "
						.. tostring(GameInfo and GameInfo:GetAttribute("MapName") or "-"),
					"  score     " .. tostring(mine) .. " : " .. tostring(theirs)
						.. "   to " .. tostring(GameInfo and GameInfo:GetAttribute("ScoreLimit") or "-")
						.. "   time " .. clock(GameInfo and GameInfo:GetAttribute("Timer")),
					"  team      " .. tostring(myTeam or "-")
						.. ((myTeam == -1) and "  (free for all)" or ""),
					"  state     " .. (STATE.deployed and "deployed" or "lobby / dead")
						.. (STATE.duel and "   DUEL - recorded" or ""),
					string.format("  drawn     %d  (%d bots, %d players)", STATE.targets,
						STATE.bots, STATE.humans),
					"  watching  " .. tostring(STATE.spectators) .. " spectator(s)",
					"  chams     " .. (chamsBroken and ("OFF - " .. tostring(chamsBroken))
						or (CONFIG.chams and "on" or "available, switched off")),
				})
			end)

			pcall(function()
				statOut:set({
					string.format("  %s   level %s   %s RR", tostring(plr:GetAttribute("Rank") or "-"),
						tostring(plr:GetAttribute("Level") or "-"),
						tostring(plr:GetAttribute("RankRR") or "-")),
					string.format("  match     %d kills  %d deaths  %d assists", STATE.kills,
						STATE.deaths, STATE.assists),
					string.format("  damage    %d", STATE.damage),
					string.format("  session   +%d kills  +%d deaths", STATE.sessionKills,
						STATE.sessionDeaths),
					"  weapon    " .. STATE.weapon,
					"  flags     sss " .. tostring(plr:GetAttribute("sss") == true)
						.. "   (spread re-roll in the game's own Hitscan)",
					"  anticheat Luraph client check via Aishiteru - this script",
					"            hooks nothing and uses no VirtualInputManager",
				})
			end)

			pcall(function()
				aimOut:set({
					"  target   " .. tostring(STATE.target) .. "  (" .. tostring(STATE.targetKind) .. ")",
					"  active   " .. (CONFIG.aim and CONFIG.aimActive or "off")
						.. (CONFIG.aimActive == "Hotkey"
							and ("  " .. (reachable(CONFIG.aimKey) and keyDisplay(CONFIG.aimKey) or "screen")) or ""),
					string.format("  now      FOV %dpx   H %d   V %d   at %s",
						CONFIG.aimFov, CONFIG.aimSmoothH, CONFIG.aimSmoothV, CONFIG.aimPart),
					"  path     " .. CONFIG.aimPath .. ((CONFIG.aimPath == "Mouse" and not mouseMove)
						and "  (no mousemoverel - using the game camera)" or ""),
					"  blocked  " .. ((STATE.paused ~= "") and STATE.paused or "no"),
					string.format("  turning  %.0f deg/s   peak %.0f   cap %d",
						STATE.aimDps, STATE.aimDpsPeak, CONFIG.humTurnCap),
					"  weapon   " .. STATE.weapon,
				})
			end)

			pcall(function()
				trigOut:set({
					"  state     " .. (CONFIG.trig and (STATE.trigOn and "armed"
						or ("waiting for " .. (reachable(CONFIG.trigKey) and keyDisplay(CONFIG.trigKey)
							or "a finger on the screen"))) or "off"),
					"  crosshair " .. tostring(STATE.underCross),
					"  click     the game's own (MouseDown + Controller:LeftClick)",
					string.format("  clicks    %d   reaction %d-%dms", STATE.trigShots,
						CONFIG.trigDelayMin, CONFIG.trigDelayMax),
					"  weapon    " .. STATE.weapon .. ((tool and tool.IsAuto) and "  (automatic)" or ""),
					"  holding   " .. tostring(weHold),
				})
			end)

			pcall(function()
				silentOut:set({
					"  state     " .. (CONFIG.silent and (STATE.silentOn and "ARMED" or "idle") or "off"),
					"  target    " .. tostring(STATE.silentTarget),
					"  note      " .. tostring(STATE.silentNote),
					string.format("  bent      %d shots so far", STATE.silentBent),
					"  installed " .. tostring(SIL.installedOn ~= nil)
						.. "   (the game's own GetMousePos is back when idle)",
					"  MEASURED  aimed 200 -> 152   35.7 deg off camera 200 -> 152",
					"            the server does not compare the shot to your view",
					"  duels     " .. (CONFIG.silentDuel and "ON - every shot is recorded" or "sleeps there"),
				})
			end)

			pcall(function()
				local w = tool and tool.WSettings or {}
				local deb = tonumber(original(w, "Debounce")) or 0
				gunOut:set({
					"  weapon    " .. STATE.weapon .. "   " .. tostring(w.Type or ""),
					string.format("  damage    %s body   %s head", tostring(w.Damage or "-"),
						tostring(w.HeadDamage or "-")),
					string.format("  fire      %.3fs between shots  (%d rpm)%s", deb,
						deb > 0 and math.floor(60 / deb) or 0, (tool and tool.IsAuto) and "  auto" or ""),
					string.format("  spread    %s  base %s", tostring(original(w, "Spread") or "-"),
						tostring(original(w, "BaseSpread") or "-")),
					string.format("  ammo      %s / %s   range %s", tostring(tool and tool.Ammo or "-"),
						tostring(w.Ammo or "-"), tostring(w.MaxDist or 500)),
					"  active    " .. tostring(STATE.mods),
					"  MEASURED  3 shots, no gap, P90 45 dmg: 200 -> 65 = all 3 counted",
					"  recoil    camera = MinCamRecoil/MaxCamRecoil, the rest is",
					"            the viewmodel (ViewModel.Recoil)",
				})
			end)

			pcall(function()
				local char = plr.Character
				local hum = char and char:FindFirstChildWhichIsA("Humanoid")
				local root = char and char:FindFirstChild("HumanoidRootPart")
				local v = root and root.AssemblyLinearVelocity or Vector3.new()
				moveOut:set({
					string.format("  walkspeed %s   moving %.0f studs/s flat, %.0f vertical",
						hum and string.format("%.1f", hum.WalkSpeed) or "-",
						Vector3.new(v.X, 0, v.Z).Magnitude, v.Y),
					"  speed     " .. (CONFIG.speed and ("+" .. CONFIG.speedAdd) or "off")
						.. "   fly " .. (CONFIG.fly and ("on, " .. CONFIG.flySpeed .. " studs/s") or "off")
						.. "   key " .. keyDisplay(CONFIG.flyKey),
					string.format("  pulled back by the server  %d time(s)%s", snap.count,
						snap.count > 0 and string.format(", last %.0fs ago", os.clock() - snap.last) or ""),
					"  duel      " .. (STATE.duel and (CONFIG.moveDuel and "ON in this duel" or "paused - duel")
						or "not in a duel"),
					"  height    " .. (root and string.format("%.0f", root.Position.Y) or "-"),
				})
			end)

			pcall(function()
				humOut:set({
					"  humaniser " .. (CONFIG.hum and "on" or "OFF"),
					"  blocked   " .. ((STATE.paused ~= "") and STATE.paused or "no"),
					"  scope     " .. (CONFIG.humBotOnly and "bots only" or "everybody"),
					"  engagement " .. (engagement and string.format("%s  %s  %.1fs", engagement.name,
						engagement.head and "head" or "body", os.clock() - engagement.t0) or "-"),
					string.format("  turning   %.0f deg/s   peak %.0f   cap %d",
						STATE.aimDps, STATE.aimDpsPeak, CONFIG.humTurnCap),
					"  panel     " .. (panelOpen() and "open" or "closed")
						.. "   panic " .. keyDisplay(CONFIG.panicKey)
						.. "   spectators " .. tostring(STATE.spectators),
				})
			end)

			pcall(function()
				win:SetStat(1, tostring(STATE.kills), "kills")
				win:SetStat(2, tostring(STATE.deaths), "deaths")
				win:SetStat(3, tostring(STATE.targets), "drawn")
				win:SetNote(STATE.note ~= "" and STATE.note or "Ready")
				win:SetStatus(string.format("%s   %s   %s   %d bots / %d players",
					gameMode(),
					STATE.deployed and "deployed" or "lobby",
					STATE.duel and "DUEL" or clock(GameInfo and GameInfo:GetAttribute("Timer")),
					STATE.bots, STATE.humans))
			end)
		end)
		if not ok then note("ui: " .. tostring(err)) end
		task.wait(0.4)
	end
end)

-- A switch whose master is off reads as a dead toggle; flipping it on arms the
-- master with it and says so (the auto-arm rule from the shooter genre file).
local ARM_AIM = { "aimFire", "aimCircle" }

task.spawn(function()
	claimIdentity()
	local was = {}
	for _, key in ipairs(ARM_AIM) do was[key] = CONFIG[key] and true or false end
	while _G.__HYPER == GEN do
		for _, key in ipairs(ARM_AIM) do
			local on = CONFIG[key] and true or false
			if on and not was[key] and not CONFIG.aim then
				CONFIG.aim = true
				local handle = CTLS["aim"]
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

_G.__HYPER_DBG = {
	CONFIG = CONFIG, STATE = STATE, SIL = SIL, MP = MP, ORIG = ORIG,
	ctl = ctl, actionHandler = actionHandler, gameUIMod = gameUIMod,
	currentTool = currentTool, gunReady = gunReady, inDuel = inDuel,
	combatants = combatants, aliveOf = aliveOf, protectedOf = protectedOf,
	sameTeam = sameTeam, weaponOf = weaponOf, headPart = headPart, bodyPart = bodyPart,
	visibleTo = visibleTo, underCrosshair = underCrosshair, bulletIgnore = bulletIgnore,
	weaponRange = weaponRange, crosshairPos = crosshairPos,
	bestTarget = bestTarget, pickTarget = pickTarget, aimPass = aimPass,
	wantAngles = wantAngles, moveView = moveView,
	silentInstall = silentInstall, silentUninstall = silentUninstall, silentPass = silentPass,
	shotLands = shotLands, landingPoint = landingPoint,
	applyMods = applyMods, restoreAllMods = restoreAllMods, applySpeed = applySpeed,
	flyStep = flyStep, snap = snap, modelFromPart = modelFromPart,
	pressFire = pressFire, releaseFire = releaseFire,
	renderPass = renderPass, hideAll = hideAll, clearChams = clearChams,
	applyPreset = applyPreset, PRESETS = PRESETS, CTLS = CTLS,
	note = note, panelOpen = panelOpen, assistBlocked = assistBlocked,
	TOUCH = TOUCH, screenHeld = screenHeld, reachable = reachable, hotkeyHeld = hotkeyHeld,
	GS = GS, CC = CC,
}

if TOUCH then note("phone: hotkeys hold the screen instead") end

print("[hypershot] gen " .. GEN .. " ready - RightShift for the panel"
	.. (TOUCH and "  (touch client)" or ""))
