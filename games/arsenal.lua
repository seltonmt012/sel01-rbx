--[[ arsenal.lua - "Arsenal" by ROLVe (place 286090429)

  Second shooter in this collection, and the genre file
  (.claude/docs/games-shooters.md) carries everything that transfers from
  counterblox. What follows is only what ARSENAL does differently, all of it
  measured through the bridge before a line of this was written.

  * **Enemy positions replicate in full.** Every player's
    `Character.HumanoidRootPart.Position` reads correctly at any range, through
    any wall - ten players, ten live positions, including the ones sitting in
    the lobby at y = -403. No server-side culling, so the ESP is honest.
  * **The character is R15 and carries the same hitbox trio as Counter Blox:**
    `Head` (1.25, CanCollide, invisible), `FakeHead` (0.625, the visible one)
    and **`HeadHB`** (1.45 x 1.30 x 1.30) - HeadHB is the headshot box. On top
    of those Arsenal has a fourth part the other game does not: **`Hitbox`**,
    4.5 x 4 x 4 studs, transparent, CanQuery true. That is the body hitbox and
    it is what the hitbox page below resizes.
  * **`Character.EquippedWep` is a StringValue that is EMPTY for everybody.**
    Measured on nine players in a live round: not one of them had a value in
    it, so it is set locally and never replicates. The enemy's weapon is NOT
    readable from the character.
  * **...but in the default mode it is derivable exactly.** `Player.Status.Level`
    replicates for every player, and `ReplicatedStorage.Levels[<level>]` is a
    StringValue naming the gun for that level - 1 = M4A1 up to 32 = Golden Gun.
    Arsenal's standard mode is a gun game, so level IS weapon, and the ESP
    prints it without guessing.
  * **`Player.Status` is the per-player oracle** and it replicates for everyone:
    `Level`, `Alive`, `Team` (the string "TRC"/"TBC"/"Spectator"), `SessionKills`.
    `Player.ScoreFolder` adds `Kills`, `Deaths`, `Streak`, `Headshots`,
    `Backstabs`, `Damage`, `Captures`. `Player.Ping` is there too.
  * **`Player.Status.Team` and `Player.Team` DISAGREE.** IndianaJulian2 read as
    `TRC` through the Teams service and `TBC` through `Status.Team` in the same
    second. The Teams object is not the enforced one, so nothing here uses it -
    and because the standard mode is a free-for-all anyway, the default target
    rule is "everybody but me" with a dropdown for the team modes.
  * **`workspace.Map.Clips`** - the same invisible movement brushes as Counter
    Blox, collision group `Clips`, transparent, CanQuery true. Left in the
    raycast filter every enemy reads as "behind a wall". Filtered here.
  * **`workspace.Ray_Ignore`** exists and is the game's own ignore folder.
  * **`workspace.HWRAP_<name>`** is the third-person WEAPON model, not a hitbox -
    every part in it is CanQuery false, so it can neither block a ray nor be
    shot. It is only used here as "this player currently holds a gun".
  * The round HUD is plain text: `GUI.Timer.GM` (mode), `.Sub`, `.R` / `.B`
    (the two team scores), `.NW` (next weapon), and `GUI.PlayersAlive.Num`.
    `ReplicatedStorage.WinnerScore` holds the leader's NAME.

  The aim assist moves the CAMERA and nothing else, exactly as in counterblox:
  no remote is fired, no hit is fabricated. The HUMANISE page is the part that
  is new here - reaction delay, wind-up, a smooth noise walk, an overshoot, a
  deadzone, a degrees-per-second ceiling and a break-off chance, all on top of
  the two smoothing divisors. A perfect tracker is what an aimbot looks like;
  every one of those knobs exists to take a piece of that away.

  The hitbox page is the one feature here that is NOT camera-only: it resizes
  the enemy's own `Hitbox` part on this client. Whether Arsenal grades a hit
  against the client's copy of that part is not something this session could
  measure (the account was in the lobby the whole time), so it ships with a
  readout that says so and it restores every part it touched when switched off.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui           = game:GetService("CoreGui")

local plr    = Players.LocalPlayer
local camera = workspace.CurrentCamera

local GEN = (_G.__ARSENAL or 0) + 1
_G.__ARSENAL = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	-- ESP ----------------------------------------------------------------------
	esp        = true,
	box        = true,
	boxFilled  = false,
	name       = true,
	health     = true,
	hpText     = true,
	weapon     = true,     -- derived from Status.Level, see the header
	level      = true,     -- the gun-game level itself
	kills      = false,    -- kills / streak in the info line
	distance   = true,
	tracer     = false,
	headDot    = true,
	skeleton   = false,
	chams      = false,
	teamESP    = false,
	visCheck   = true,
	offScreen  = true,     -- arrow at the screen edge for enemies behind you
	maxDist    = 1500,
	textSize   = 14,
	textFont   = "System",
	textOutline = true,
	textShrink = false,

	colEnemy   = Color3.fromRGB(255, 72, 88),
	colMate    = Color3.fromRGB(80, 190, 255),
	colCham    = Color3.fromRGB(255, 72, 88),
	colChamOwn = false,
	colFov     = Color3.fromRGB(255, 255, 255),
	colLeader  = Color3.fromRGB(255, 200, 70),
	markLeader = true,     -- the player closest to the last level gets his own colour

	chamStyle  = "Fill",
	chamRainbow = false,
	chamByHealth = false,

	-- who counts as a target ---------------------------------------------------
	-- Arsenal's standard mode is a free-for-all, so "everybody" is the honest
	-- default. Auto reads the mode name out of the HUD and only switches to a
	-- team check when the mode actually says so.
	teamMode   = "Auto",   -- Auto | Everyone (FFA) | Team check

	-- aim assist ---------------------------------------------------------------
	aim        = false,
	aimActive  = "Hotkey", -- Hotkey | Always | While firing
	aimKey     = "MouseButton2",
	aimPart    = "Head",   -- Head | Torso | Hitbox | Nearest
	aimPick    = "Crosshair", -- Crosshair | Closest | Lowest HP | Lowest level
	aimSticky  = true,
	aimVisible = true,
	aimMaxDist = 1500,
	aimOnlyGun = true,
	aimAir     = "Always", -- Always | Only grounded | Only airborne

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

	aimPredict = false,    -- lead a moving target
	aimPredictAmt = 0.12,  -- seconds of velocity added to the aim point

	aimCircle  = true,
	aimCircle2 = true,

	-- humanisation -------------------------------------------------------------
	hum        = true,
	humReactMin = 90,      -- ms before the aim engages on a NEW target
	humReactMax = 180,
	humSwitchMs = 350,     -- cooldown before it may switch target at all
	humRampMs  = 220,      -- wind-up: the first frames are slower than the setting
	humOffset  = 35,       -- % of the target part's own size, as a random offset
	humOffsetMs = 700,     -- how often that offset is re-rolled
	humNoise   = 0.45,     -- degrees of continuous smooth wander
	humNoiseHz = 1.6,      -- how fast the wander moves
	humOvershoot = 0,      -- % past the target before settling back
	humDeadPx  = 3,        -- do not correct at all inside this many pixels
	humMoveFov = 100,      -- % of the FOV while the player is moving
	humMaxDegS = 420,      -- hard ceiling on correction speed, degrees per second
	humBreakPct = 0,       -- % chance per second to let go for a moment
	humBreakMs = 160,
	humFatigue = 8,        -- ms added to the trigger delay per shot in a burst
	humPanelOff = true,    -- everything pauses while the panel is open
	humPanicKey = "F1",    -- one key that switches aim, trigger and rcs off

	-- trigger ------------------------------------------------------------------
	trig       = false,
	trigActive = "Hotkey", -- Hotkey | Always
	trigKey    = "C",
	trigMode   = "Click",  -- Click | Hold
	trigHoldMs = 120,
	trigDelayMin = 40,
	trigDelayMax = 110,
	trigRefireMs = 90,
	trigHitPct = 100,
	trigHeadOnly = false,
	trigMaxDist = 1500,
	trigFov    = 0,
	trigOnlyGun = true,
	trigBurst  = 0,

	-- recoil -------------------------------------------------------------------
	rcs        = false,
	rcsPitch   = 70,
	rcsYaw     = 70,
	rcsAfter   = 1,
	rcsMaxDeg  = 4,

	-- hitbox -------------------------------------------------------------------
	hb         = false,
	hbSize     = 8,
	hbPart     = "Hitbox", -- Hitbox | HeadHB | Head | Hitbox + HeadHB
	hbTrans    = 100,      -- % transparency; 100 = fully invisible
	hbEnemy    = true,     -- enemies only
	hbEvery    = 0.5,      -- seconds between refreshes
}

local STATE = {
	note      = "",
	targets   = 0,
	target    = "-",
	weapon    = "-",
	level     = 0,
	shots     = 0,
	trigHits  = 0,
	trigOn    = false,
	sensY     = 0, sensP = 0, calibN = 0,
	kickY     = 0, kickP = 0, kickPeak = 0,
	underCross = "-",
	lastKey   = "-",
	mode      = "-",
	sub       = "-",
	scoreR    = 0, scoreB = 0,
	aliveN    = 0,
	leader    = "-",
	nextWep   = "-",
	ffa       = true,
	engaged   = false,     -- the aim actually moved the camera this frame
	waitMs    = 0,         -- reaction delay still to run on the current target
	breaking  = false,
	hbCount   = 0,
	panelOpen = false,
}

local COLOUR = {
	hpGood   = Color3.fromRGB(90, 220, 120),
	hpBad    = Color3.fromRGB(230, 80, 60),
	text     = Color3.fromRGB(235, 235, 240),
	black    = Color3.fromRGB(0, 0, 0),
	fov      = Color3.fromRGB(255, 255, 255),
}

local function note(text)
	STATE.note = tostring(text)
end

local function dimmed(colour)
	local h, s, v = Color3.toHSV(colour)
	return Color3.fromHSV(h, s * 0.9, v * 0.55)
end

--------------------------------------------------------------------------------
-- game state
--------------------------------------------------------------------------------

-- Everything about another player that this script needs is in Player.Status and
-- Player.ScoreFolder, both of which replicate in full. Read through one helper so
-- a missing child during a respawn is a fallback rather than an error.
local function pv(p, folder, child, fallback)
	local f = p:FindFirstChild(folder)
	if not f then return fallback end
	local v = f:FindFirstChild(child)
	if not v then return fallback end
	local ok, value = pcall(function() return v.Value end)
	if not ok then return fallback end
	return value
end

local function statusTeam(p)
	return tostring(pv(p, "Status", "Team", ""))
end

local function levelOf(p)
	return tonumber(pv(p, "Status", "Level", 0)) or 0
end

-- The gun-game ladder. ReplicatedStorage.Levels holds one StringValue per level,
-- named "1".."32", and the value is the weapon that level hands out. In the
-- default mode that makes an enemy's weapon exactly knowable from a number that
-- replicates, which is the one thing EquippedWep refuses to tell anybody.
-- NOT cached, and that is deliberate. The first build cached level -> weapon
-- once, and then the server changed the mode from "Automatics" to "Legacy
-- Competitive" and REWROTE the whole folder underneath it: level 1 was M4A1
-- before the switch and SCAR-L after it, while the panel still printed M4A1.
-- The ladder is per mode, so it is read fresh every time - a FindFirstChild on
-- a 32 entry folder is a hash lookup and costs nothing at ten players a frame.
local LevelsFolder = ReplicatedStorage:FindFirstChild("Levels")

local function weaponForLevel(lvl)
	if lvl <= 0 then return "" end
	if not LevelsFolder or not LevelsFolder.Parent then
		LevelsFolder = ReplicatedStorage:FindFirstChild("Levels")
	end
	local v = LevelsFolder and LevelsFolder:FindFirstChild(tostring(lvl))
	return (v and tostring(v.Value)) or ""
end

local MAXLEVEL = 0
if LevelsFolder then
	for _, c in ipairs(LevelsFolder:GetChildren()) do
		local n = tonumber(c.Name)
		if n and n > MAXLEVEL then MAXLEVEL = n end
	end
end

-- A dead body is cleaned up in this game, but a character can also exist for a
-- second before the Humanoid is ready, so both halves are checked - and
-- Status.Alive is checked on top because a player sitting in the lobby menu
-- still has a character parented at y = -403.
local function alive(p)
	local char = p.Character
	if not char or not char.Parent then return nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	if pv(p, "Status", "Alive", true) == false then return nil end
	return char, hum, root
end

-- Free-for-all is the default mode, and in a free-for-all a team check would
-- simply hide half the enemies. Auto only turns the check on when the HUD says
-- the mode is a team one.
local Gui = plr:WaitForChild("PlayerGui")

local function hudText(path, fallback)
	local node = Gui:FindFirstChild("GUI")
	if not node then return fallback end
	for _, step in ipairs(path) do
		node = node:FindFirstChild(step)
		if not node then return fallback end
	end
	local ok, value = pcall(function() return node.Text end)
	if not ok or value == nil then return fallback end
	return tostring(value)
end

-- Auto is a NAME LIST, not a measurement, and it is worth being honest about
-- why. Everything that could have been measured turned out not to separate the
-- two cases: `Player.Status.Team` reads TRC/TBC for every deployed player in a
-- gun game as well as in a round mode, `ReplicatedStorage.NoTeam` was false in
-- both, and `Player.FriendlyFire` was false in both. So the mode caption in the
-- HUD is what is left, and the dropdown next to it exists precisely because a
-- name list will eventually meet a mode nobody wrote down.
local TEAM_MODE_WORDS = {
	"team", "tdm", "competitive", "capture", "flag", "domination",
	"king", "control", "payload", "escort", "siege",
}

local function ffaNow()
	if CONFIG.teamMode == "Everyone (FFA)" then return true end
	if CONFIG.teamMode == "Team check" then return false end
	local mode = string.lower(STATE.mode or "")
	for _, word in ipairs(TEAM_MODE_WORDS) do
		if mode:find(word, 1, true) then return false end
	end
	return true
end

local function isEnemy(p)
	if p == plr then return false end
	if STATE.ffa then return true end
	local mine, theirs = statusTeam(plr), statusTeam(p)
	if mine == "" or theirs == "" then return true end
	return mine ~= theirs
end

--------------------------------------------------------------------------------
-- line of sight
--------------------------------------------------------------------------------
--
-- The filter is "everything a BULLET would not stop on", which is not the same
-- as "everything you cannot see", and on this map that distinction is worth 72
-- parts. Two families of them, both found by measurement:
--
--  * `Map.Clips` - the movement clip brushes, collision group Clips, fully
--    transparent, CanQuery true. Solid to a player, invisible, and bullets pass
--    straight through. The same trap as Counter Blox.
--  * `Map.Ignore` - a folder whose NAME says ignore but whose contents are
--    mixed: 256 opaque collidable parts (real geometry, must stay) sitting next
--    to 37 `Floors`, 8 literally named `RAYCAST`, 4 `MainSt` and 2 `Glass`,
--    every one of them transparency 1, CanCollide FALSE and CanQuery TRUE.
--    Dropping the whole folder would make real walls transparent to the wall
--    check; keeping it whole made an enemy at 49 m read as blocked by
--    `Map.Ignore.Floors.RAYCAST`. Measured on Standard.
--
-- So the rule is a PROPERTY test rather than a name list: a part that is fully
-- transparent AND not collidable is neither visible nor solid, so nothing a
-- bullet can stop on - whatever it happens to be called. The scan is 8.4 ms
-- over 12257 descendants, so it runs on a timer in its own thread, never per
-- frame.

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local trigParams = RaycastParams.new()
trigParams.FilterType = Enum.RaycastFilterType.Exclude
trigParams.IgnoreWater = true

-- Every part in the map that is invisible AND not collidable. Rebuilt on a
-- timer and whenever the Map model itself is replaced, which is what a map
-- change looks like from here.
local ghosts = {}
local ghostMap = nil

local function scanGhosts()
	local map = workspace:FindFirstChild("Map")
	if not map then ghosts = {} ghostMap = nil return 0 end
	local list = {}
	for _, c in ipairs(map:GetDescendants()) do
		if c:IsA("BasePart") and c.Transparency >= 1 and not c.CanCollide then
			table.insert(list, c)
		end
	end
	ghosts = list
	ghostMap = map
	return #list
end

local function ignoreList()
	local list = {}
	for _, name in ipairs({ "Ray_Ignore", "Debris", "Sounds", "Destructable" }) do
		local f = workspace:FindFirstChild(name)
		if f then table.insert(list, f) end
	end
	local map = workspace:FindFirstChild("Map")
	if map then
		local clips = map:FindFirstChild("Clips")
		if clips then table.insert(list, clips) end
	end
	for _, part in ipairs(ghosts) do
		if part.Parent then table.insert(list, part) end
	end
	-- The third-person weapon models. Every part in them is CanQuery false
	-- already, so this is belt and braces, but it costs one table insert.
	for _, c in ipairs(workspace:GetChildren()) do
		if c.Name:sub(1, 6) == "HWRAP_" then table.insert(list, c) end
	end
	return list
end

local function refreshFilter()
	local base = ignoreList()

	local espList = {}
	for _, v in ipairs(base) do table.insert(espList, v) end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then table.insert(espList, p.Character) end
	end
	rayParams.FilterDescendantsInstances = espList

	-- The trigger's ray must NOT exclude the other characters: the enemy's body
	-- is exactly what it is looking for.
	local trigList = {}
	for _, v in ipairs(base) do table.insert(trigList, v) end
	if plr.Character then table.insert(trigList, plr.Character) end
	trigParams.FilterDescendantsInstances = trigList
end

local function visible(worldPos)
	local origin = camera.CFrame.Position
	local hit = workspace:Raycast(origin, worldPos - origin, rayParams)
	return hit == nil
end

STATE.ghosts = 0
task.spawn(function()
	while _G.__ARSENAL == GEN do
		local ok, err = pcall(function()
			local map = workspace:FindFirstChild("Map")
			if map ~= ghostMap then
				STATE.ghosts = scanGhosts()
				refreshFilter()
				note("map scan: " .. STATE.ghosts .. " see-through parts filtered")
			end
		end)
		if not ok then note("ghosts: " .. tostring(err)) end
		task.wait(3)
	end
end)

--------------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------------

local FONTS = { UI = 0, System = 1, Plex = 2, Monospace = 3 }
local FONTLIST = { "System", "UI", "Plex", "Monospace" }

local function fontId()
	local id = FONTS[CONFIG.textFont]
	if id == nil then return 1 end
	if Drawing.Fonts then
		local named = Drawing.Fonts[CONFIG.textFont]
		if named ~= nil then return named end
	end
	return id
end

local drawn = {}
local pool  = {}

if _G.__ARSENAL_POOL then
	for _, obj in ipairs(_G.__ARSENAL_POOL) do pcall(function() obj:Remove() end) end
end
_G.__ARSENAL_POOL = pool

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
		outline  = make("Square", { Thickness = 3, Filled = false, ZIndex = 1,
			Color = COLOUR.black, Transparency = 0.6 }),
		box      = make("Square", { Thickness = 1, Filled = false, ZIndex = 2 }),
		fill     = make("Square", { Filled = true, ZIndex = 0, Transparency = 0.18 }),
		hpBg     = make("Square", { Filled = true, ZIndex = 1, Color = COLOUR.black,
			Transparency = 0.6 }),
		hp       = make("Square", { Filled = true, ZIndex = 2 }),
		name     = make("Text", { Size = 13, Center = true, Outline = true,
			Font = 1, Color = COLOUR.text, ZIndex = 3 }),
		info     = make("Text", { Size = 12, Center = true, Outline = true,
			Font = 1, Color = COLOUR.text, ZIndex = 3 }),
		tracer   = make("Line", { Thickness = 1, ZIndex = 1 }),
		head     = make("Circle", { Thickness = 1, Filled = false, NumSides = 14,
			ZIndex = 3 }),
		arrow    = make("Triangle", { Thickness = 1, Filled = true, ZIndex = 2,
			Transparency = 0.75 }),
		bones    = {},
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
	set.tracer.Visible  = false
	set.head.Visible    = false
	set.arrow.Visible   = false
	for _, line in ipairs(set.bones) do line.Visible = false end
end

local function hideAll()
	for _, set in pairs(drawn) do hideSet(set) end
end

--------------------------------------------------------------------------------
-- chams
--------------------------------------------------------------------------------

local hlRoot = (gethui and gethui()) or CoreGui
local chamsFolder = hlRoot:FindFirstChild("SeluxArsenalChams")
if chamsFolder then pcall(function() chamsFolder:Destroy() end) end
chamsFolder = Instance.new("Folder")
chamsFolder.Name = "SeluxArsenalChams"
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

local function chamColour(base, hum)
	if CONFIG.chamRainbow then
		return Color3.fromHSV((os.clock() * 0.25) % 1, 0.85, 1)
	end
	if CONFIG.chamByHealth and hum then
		local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
		return COLOUR.hpBad:Lerp(COLOUR.hpGood, frac)
	end
	if CONFIG.colChamOwn then return CONFIG.colCham end
	return base
end

local function applyCham(hl, base, hum)
	local style = CHAM_STYLES[CONFIG.chamStyle] or CHAM_STYLES["Fill"]
	local col = chamColour(base, hum)
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
-- the render pass
--------------------------------------------------------------------------------

local fovCircle = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Color = COLOUR.fov, Transparency = 0.5, ZIndex = 1 })
local fovCircle2 = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Color = COLOUR.fov, Transparency = 0.28, ZIndex = 1 })
local trigCircle = make("Circle", { Thickness = 1, NumSides = 32, Filled = false,
	Color = Color3.fromRGB(255, 210, 90), Transparency = 0.45, ZIndex = 1 })

local function centre()
	local vp = camera.ViewportSize
	return Vector2.new(vp.X / 2, vp.Y / 2)
end

local filterAt = 0
local aimFovNow = CONFIG.aimFov      -- filled in by aimNumbers(), drawn here

local function renderPass()
	if _G.__ARSENAL ~= GEN then return end

	local mid = centre()
	fovCircle.Visible = CONFIG.aim and CONFIG.aimCircle
	if fovCircle.Visible then
		fovCircle.Position = mid
		fovCircle.Radius = aimFovNow
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

	if not CONFIG.esp then
		hideAll()
		clearChams()
		STATE.targets = 0
		return
	end

	local now = os.clock()
	if now - filterAt > 1 then
		filterAt = now
		refreshFilter()
	end

	local vp = camera.ViewportSize
	local camPos = camera.CFrame.Position
	local count = 0

	-- Who is closest to the last level. In a gun game that is the only piece of
	-- information that decides the match, and the HUD only shows it as a small
	-- number in a corner.
	local leaderName, leaderLvl = nil, -1
	if CONFIG.markLeader then
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= plr then
				local lvl = levelOf(p)
				if lvl > leaderLvl then leaderName, leaderLvl = p.Name, lvl end
			end
		end
	end

	for _, p in ipairs(Players:GetPlayers()) do
		local set = objectsFor(p)
		local char, hum, root = alive(p)
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
				local head = char:FindFirstChild("HeadHB") or char:FindFirstChild("Head")
				local seen = true
				if CONFIG.visCheck then
					seen = visible((head or root).Position)
				end

				local base = enemy and CONFIG.colEnemy or CONFIG.colMate
				if CONFIG.markLeader and leaderName == p.Name and leaderLvl > 0 then
					base = CONFIG.colLeader
				end
				local col = seen and base or dimmed(base)

				-- Never Model:GetBoundingBox() - see the genre file. The projected
				-- distance between the top of the head and the lower foot IS the
				-- on-screen height, so it scales with range for free.
				local headPart = char:FindFirstChild("Head")
				local lf, rf = char:FindFirstChild("LeftFoot"), char:FindFirstChild("RightFoot")

				local topPos = headPart
					and (headPart.Position + Vector3.new(0, headPart.Size.Y / 2 + 0.35, 0))
					or (root.Position + Vector3.new(0, 3, 0))

				local botPos
				local low = lf
				if lf and rf then low = (lf.Position.Y <= rf.Position.Y) and lf or rf
				elseif rf then low = rf end
				if low then
					botPos = low.Position - Vector3.new(0, low.Size.Y / 2, 0)
				else
					botPos = root.Position - Vector3.new(0, 3, 0)
				end

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
					-- An off-screen enemy still gets an edge marker if that is on -
					-- in a free-for-all the shot that kills you almost always comes
					-- from a direction you are not looking at.
					if CONFIG.offScreen and not (dist > CONFIG.maxDist) then
						local rel = camera.CFrame:PointToObjectSpace(root.Position)
						local ang = math.atan2(rel.X, -rel.Z)
						if behind then ang = math.atan2(rel.X, math.abs(rel.Z)) end
						local r = math.min(vp.X, vp.Y) * 0.34
						local px = mid.X + math.sin(ang) * r
						local py = mid.Y - math.cos(ang) * r * 0.35
						local dir = Vector2.new(px - mid.X, py - mid.Y)
						if dir.Magnitude < 1 then dir = Vector2.new(0, -1) end
						dir = dir.Unit
						local side = Vector2.new(-dir.Y, dir.X)
						set.arrow.Visible = true
						set.arrow.PointA = Vector2.new(px, py) + dir * 9
						set.arrow.PointB = Vector2.new(px, py) - dir * 6 + side * 6
						set.arrow.PointC = Vector2.new(px, py) - dir * 6 - side * 6
						set.arrow.Color = col
					end
					local hl = highlights[p]
					if hl and not CONFIG.chams then hl.Enabled = false end
				else
					count = count + 1
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
						local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
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
					local face = fontId()

					set.name.Visible = CONFIG.name
					if CONFIG.name then
						set.name.Size = ts
						set.name.Font = face
						set.name.Outline = CONFIG.textOutline
						set.name.Position = Vector2.new(minX + w / 2, minY - (ts + 3))
						set.name.Text = p.Name
						set.name.Color = col
					end

					local bits = {}
					local lvl = levelOf(p)
					if CONFIG.level and lvl > 0 then
						table.insert(bits, "L" .. tostring(lvl))
					end
					if CONFIG.weapon then
						local wep = weaponForLevel(lvl)
						if wep ~= "" then table.insert(bits, wep) end
					end
					if CONFIG.distance then
						table.insert(bits, string.format("%dm", math.floor(dist)))
					end
					if CONFIG.hpText then
						table.insert(bits, string.format("%d", math.floor(hum.Health)))
					end
					if CONFIG.kills then
						local k = tonumber(pv(p, "ScoreFolder", "Kills", 0)) or 0
						local s = tonumber(pv(p, "ScoreFolder", "Streak", 0)) or 0
						table.insert(bits, string.format("%d/%d", k, s))
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
					set.arrow.Visible = false

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
						applyCham(hl, base, hum)
					else
						local hl = highlights[p]
						if hl then hl.Enabled = false hl.Adornee = nil end
					end
				end
			end
		end
	end

	STATE.targets = count
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

-- Indexing a Roblox Enum with a name it does not have THROWS instead of
-- returning nil, so both lookups are wrapped and the answer is cached.
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

UserInputService.InputBegan:Connect(function(input, typing)
	if _G.__ARSENAL ~= GEN then return end
	if capturing and not armedGuard
		and input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode == Enum.KeyCode.Escape then capture(nil) return end
		if input.KeyCode == Enum.KeyCode.Unknown then return end
		capture(input.KeyCode.Name)
		return
	end
	-- The panic key. One press and every input-touching feature is off - the
	-- ESP stays, because a drawing has never had to be panicked away.
	if typing or capturing then return end
	if input.UserInputType == Enum.UserInputType.Keyboard
		and CONFIG.humPanicKey ~= "" then
		local spec = resolveKey(CONFIG.humPanicKey)
		if spec and spec.key and input.KeyCode == spec.key then
			CONFIG.aim, CONFIG.trig, CONFIG.rcs, CONFIG.aimFire = false, false, false, false
			note("PANIC - aim, trigger, rcs and auto fire off")
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if _G.__ARSENAL ~= GEN or not capturing or armedGuard then return end
	local name = input.UserInputType.Name
	if name:sub(1, 11) ~= "MouseButton" then return end
	capture(name)
end)

local function firing()
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
end

--------------------------------------------------------------------------------
-- the weapon in hand
--------------------------------------------------------------------------------
--
-- Arsenal keeps no Tool on the character, so the local weapon comes from the
-- same ladder the ESP uses for everybody else: Status.Level -> Levels[level] ->
-- ReplicatedStorage.Weapons[name]. The stat block is the whole thing: DMG,
-- FireRate, Ammo, StoredAmmo, Auto, Range, MaxSpread, Bullets, Falloff,
-- RecoilControl, ReloadTime and Speed%.
--
-- "Is this thing a gun" comes from CONTENT: a Weapons folder entry with an Ammo
-- above one and a FireRate shoots. The 173 entries in ReplicatedStorage.Melees
-- have a `Type` of Knife and no Ammo at all, so they answer no without a single
-- name being matched.

local WeaponsFolder = ReplicatedStorage:FindFirstChild("Weapons")
local MeleesFolder  = ReplicatedStorage:FindFirstChild("Melees")

local weaponCache = {}

local function weaponInfo()
	local name = weaponForLevel(levelOf(plr))
	if name == "" then return nil, "" end
	local cached = weaponCache[name]
	if cached ~= nil then return cached or nil, name end

	local folder = WeaponsFolder and WeaponsFolder:FindFirstChild(name)
	if not folder then
		if MeleesFolder and MeleesFolder:FindFirstChild(name) then
			local melee = { name = name, gun = false, melee = true, rate = 0.5,
				dmg = 0, ammo = 0, auto = false, range = 0, spread = 0,
				bullets = 1, reload = 0, stored = 0, speed = 0, falloff = 0,
				recoil = 0 }
			weaponCache[name] = melee
			return melee, name
		end
		weaponCache[name] = false
		return nil, name
	end

	local function num(child, fallback)
		local v = folder:FindFirstChild(child)
		return (v and tonumber(v.Value)) or fallback
	end
	local autoValue = folder:FindFirstChild("Auto")
	local info = {
		name    = name,
		dmg     = num("DMG", 0),
		rate    = num("FireRate", 0.1),
		ammo    = num("Ammo", 0),
		stored  = num("StoredAmmo", 0),
		spread  = num("MaxSpread", 0),
		bullets = num("Bullets", 1),
		range   = num("Range", 0),
		falloff = num("Falloff", 0),
		recoil  = num("RecoilControl", 0),
		reload  = num("ReloadTime", 0),
		speed   = num("Speed%", 0),
		auto    = autoValue ~= nil and autoValue.Value == true,
		melee   = false,
	}
	info.gun = info.ammo > 1 and info.rate > 0
	weaponCache[name] = info
	return info, name
end

local HEADPARTS = { Head = true, HeadHB = true, FakeHead = true }

local function gunGate(needGun)
	if not needGun then return true end
	local info = weaponInfo()
	return info ~= nil and info.gun
end

-- Arsenal has no scope BoolValue on the character, but it does have a very
-- Arsenal-shaped condition instead: half the kills in this game are taken in
-- mid-air, so the gate here is grounded/airborne rather than scoped.
local function airGate(mode)
	if mode == "Always" then return true end
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return true end
	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	if mode == "Only grounded" then return grounded end
	return not grounded
end

--------------------------------------------------------------------------------
-- humanisation
--------------------------------------------------------------------------------
--
-- Everything in this block exists to take a piece of "perfect" away from the
-- aim, because perfect is exactly what a machine looks like. Each knob removes
-- one specific tell:
--
--   reaction    a human does not start turning on the same frame the enemy
--               becomes visible
--   switch      ...and does not swap target between two frames either
--   ramp        the first part of a flick is slower than the middle of it
--   offset      nobody puts the crosshair on the same millimetre of the head
--               twice; re-rolled on a timer so it drifts during a hold
--   noise       the hand never stops moving, even on a still target
--   overshoot   a fast flick goes past and comes back
--   deadzone    once it is close enough, stop correcting - a permanently
--               pixel-perfect crosshair is the loudest tell of all
--   move FOV    a moving player tracks worse than a standing one
--   deg/s cap   the single most important one: no hand turns 3000 deg/s, and
--               an uncapped smoothing divisor will at close range
--   break       occasionally just let go for a moment
--   fatigue     the trigger gets slower deeper into a burst
--
-- The noise is a smooth random walk rather than per-frame randomness: white
-- noise on the camera reads as a stutter, a walk reads as a hand.

local noiseX, noiseY = 0, 0
local noiseTX, noiseTY = 0, 0
local noiseAt = 0

local function noiseStep(dt)
	if not CONFIG.hum or CONFIG.humNoise <= 0 then
		noiseX, noiseY = 0, 0
		return 0, 0
	end
	local now = os.clock()
	local period = 1 / math.max(0.1, CONFIG.humNoiseHz)
	if now - noiseAt > period then
		noiseAt = now
		noiseTX = (math.random() * 2 - 1)
		noiseTY = (math.random() * 2 - 1)
	end
	local k = math.clamp(dt / period, 0, 1) * 2
	noiseX = noiseX + (noiseTX - noiseX) * k
	noiseY = noiseY + (noiseTY - noiseY) * k
	local amp = math.rad(CONFIG.humNoise)
	return noiseX * amp, noiseY * amp
end

-- A per-target aim offset, in studs, re-rolled on a timer. Scaled by the size of
-- the part being aimed at so a head offset stays inside the head.
local offsetVec = Vector3.new()
local offsetAt = 0
local offsetFor = nil

local function aimOffset(part, targetPlayer)
	if not CONFIG.hum or CONFIG.humOffset <= 0 then return Vector3.new() end
	local now = os.clock() * 1000
	if offsetFor ~= targetPlayer or now - offsetAt > CONFIG.humOffsetMs then
		offsetAt = now
		offsetFor = targetPlayer
		offsetVec = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1,
			math.random() * 2 - 1)
	end
	local size = part.Size
	local f = CONFIG.humOffset / 100 * 0.5
	return Vector3.new(offsetVec.X * size.X * f, offsetVec.Y * size.Y * f,
		offsetVec.Z * size.Z * f)
end

local function movingNow()
	local char = plr.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	local v = root.AssemblyLinearVelocity
	return (Vector3.new(v.X, 0, v.Z)).Magnitude > 4
end

--------------------------------------------------------------------------------
-- aim assist
--------------------------------------------------------------------------------

local lastKillAt = 0
local stickyTarget = nil
local lockedAt = 0        -- when the current target was picked, ms
local switchedAt = 0      -- when the last switch happened, ms
local breakUntil = 0

local function aimActive()
	if not CONFIG.aim then return false end
	if CONFIG.hum and CONFIG.humPanelOff and STATE.panelOpen then return false end
	if CONFIG.aimActive == "Always" then return true end
	if CONFIG.aimActive == "While firing" then return firing() end
	return keyHeld(CONFIG.aimKey)
end

local function aimNumbers()
	local fov, sh, sv
	if CONFIG.aimSameAll or STATE.shots <= 1 then
		fov, sh, sv = CONFIG.aimFov, CONFIG.aimSmoothH, CONFIG.aimSmoothV
	else
		fov, sh, sv = CONFIG.aimFov2, CONFIG.aimSmoothH2, CONFIG.aimSmoothV2
	end
	if CONFIG.hum and CONFIG.humMoveFov < 100 and movingNow() then
		fov = fov * (CONFIG.humMoveFov / 100)
	end
	aimFovNow = fov
	return fov, sh, sv
end

local function targetPart(char)
	if CONFIG.aimPart == "Torso" then
		return char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart")
	end
	if CONFIG.aimPart == "Hitbox" then
		return char:FindFirstChild("Hitbox") or char:FindFirstChild("UpperTorso")
			or char:FindFirstChild("HumanoidRootPart")
	end
	if CONFIG.aimPart == "Nearest" then
		local mid = centre()
		local best, bestD
		for _, n in ipairs({ "HeadHB", "Head", "UpperTorso", "Hitbox", "HumanoidRootPart" }) do
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
	return char:FindFirstChild("HeadHB") or char:FindFirstChild("Head")
		or char:FindFirstChild("HumanoidRootPart")
end

-- Where the part will be, not where it is. Off by default: prediction that is
-- wrong is worse than none, and Arsenal's projectiles are hitscan for most
-- weapons, so this only earns its keep on the slow ones.
local function aimWorldPoint(part, targetPlayer)
	local point = part.Position + aimOffset(part, targetPlayer)
	if CONFIG.aimPredict and CONFIG.aimPredictAmt > 0 then
		local ok, vel = pcall(function() return part.AssemblyLinearVelocity end)
		if ok and vel then point = point + vel * CONFIG.aimPredictAmt end
	end
	return point
end

local function pickTarget()
	local fov = select(1, aimNumbers())
	local mid = centre()
	local camPos = camera.CFrame.Position
	local best, bestScore

	for _, p in ipairs(Players:GetPlayers()) do
		if isEnemy(p) then
			local char, hum, root = alive(p)
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
									score = hum.Health
								elseif CONFIG.aimPick == "Lowest level" then
									score = levelOf(p)
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

local function approach(smooth, dt)
	local base = 1 / math.max(1, smooth)
	return 1 - (1 - base) ^ math.max(dt * 60, 0.0001)
end

local function angleDelta(a, b)
	local d = (b - a) % (math.pi * 2)
	if d > math.pi then d = d - math.pi * 2 end
	return d
end

local aimWroteCamera = false
local reactUntil = 0

local function aimPass(dt)
	if _G.__ARSENAL ~= GEN then return end
	aimWroteCamera = false
	STATE.engaged = false

	if not aimActive() or not gunGate(CONFIG.aimOnlyGun) or not airGate(CONFIG.aimAir) then
		STATE.target = "-"
		STATE.waitMs = 0
		stickyTarget = nil
		reactUntil = 0
		return
	end

	local nowMs = os.clock() * 1000
	if nowMs - lastKillAt < CONFIG.aimKillMs then
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

	-- A switch is allowed only after the cooldown. Without it a free-for-all with
	-- five enemies in the FOV makes the camera twitch between them every frame,
	-- which is not a thing a hand can do.
	if not pick then
		if CONFIG.hum and CONFIG.humSwitchMs > 0
			and stickyTarget ~= nil and nowMs - switchedAt < CONFIG.humSwitchMs then
			STATE.target = "-"
			return
		end
		pick = pickTarget()
		if pick and pick.player ~= stickyTarget then
			switchedAt = nowMs
			-- reaction delay starts now, on the NEW target
			local lo = math.min(CONFIG.humReactMin, CONFIG.humReactMax)
			local hi = math.max(CONFIG.humReactMin, CONFIG.humReactMax)
			reactUntil = (CONFIG.hum and hi > 0) and (nowMs + math.random(lo, hi)) or 0
			lockedAt = nowMs
		end
	end

	if not pick or not pick.part or not pick.part.Parent then
		STATE.target = "-"
		STATE.waitMs = 0
		stickyTarget = nil
		return
	end
	stickyTarget = pick.player
	STATE.target = pick.player.Name

	-- reaction delay ----------------------------------------------------------
	if reactUntil > nowMs then
		STATE.waitMs = math.floor(reactUntil - nowMs)
		return
	end
	STATE.waitMs = 0

	-- break-off ---------------------------------------------------------------
	if CONFIG.hum and CONFIG.humBreakPct > 0 then
		if nowMs < breakUntil then
			STATE.breaking = true
			return
		end
		STATE.breaking = false
		-- the percentage is per SECOND, so it is scaled by the frame time
		if math.random() < (CONFIG.humBreakPct / 100) * dt then
			breakUntil = nowMs + CONFIG.humBreakMs
			return
		end
	else
		STATE.breaking = false
	end

	local _, smoothH, smoothV = aimNumbers()

	-- wind-up: for the first humRampMs of a lock the smoothing divisor is larger
	-- (slower) and eases back to the configured one.
	if CONFIG.hum and CONFIG.humRampMs > 0 then
		local age = nowMs - lockedAt
		if age < CONFIG.humRampMs then
			local k = age / CONFIG.humRampMs
			local slow = 3 - 2 * k        -- 3x slower at the start, 1x at the end
			smoothH = smoothH * slow
			smoothV = smoothV * slow
		end
	end

	local cf = camera.CFrame
	local pos = cf.Position
	local curPitch, curYaw = cf:ToOrientation()
	local want = CFrame.lookAt(pos, aimWorldPoint(pick.part, pick.player))
	local wantPitch, wantYaw = want:ToOrientation()

	local dYaw   = angleDelta(curYaw, wantYaw)
	local dPitch = angleDelta(curPitch, wantPitch)

	-- deadzone: close enough is close enough. pick.px is already the pixel
	-- distance from the crosshair to the target part.
	if CONFIG.hum and CONFIG.humDeadPx > 0 and pick.px <= CONFIG.humDeadPx then
		dYaw, dPitch = 0, 0
	end

	local stepH = approach(smoothH, dt)
	local stepV = approach(smoothV, dt)

	-- overshoot: aim a little past and let the next frames pull it back
	if CONFIG.hum and CONFIG.humOvershoot > 0 then
		local over = 1 + CONFIG.humOvershoot / 100
		stepH = math.min(stepH * over, 1.35)
		stepV = math.min(stepV * over, 1.35)
	end

	local moveYaw   = dYaw * stepH
	local movePitch = dPitch * stepV

	-- the degrees-per-second ceiling, applied to the two axes together so a
	-- diagonal flick is capped at the same speed as a flat one
	if CONFIG.hum and CONFIG.humMaxDegS > 0 then
		local cap = math.rad(CONFIG.humMaxDegS) * dt
		local mag = math.sqrt(moveYaw * moveYaw + movePitch * movePitch)
		if mag > cap and mag > 0 then
			local k = cap / mag
			moveYaw, movePitch = moveYaw * k, movePitch * k
		end
	end

	local nx, ny = noiseStep(dt)

	camera.CFrame = CFrame.new(pos)
		* CFrame.fromOrientation(curPitch + movePitch + ny, curYaw + moveYaw + nx, 0)
	aimWroteCamera = true
	STATE.engaged = true
end

--------------------------------------------------------------------------------
-- recoil control, measured rather than assumed
--------------------------------------------------------------------------------
--
-- Identical method to counterblox and for the same reason: the weapon folder
-- carries a RecoilControl number but nothing says what one unit of it is worth
-- on this camera. So the client measures its own effective sensitivity while
-- the player is NOT firing, and while firing treats whatever camera movement is
-- left after subtracting sensitivity x mouse delta as the recoil. Both numbers
-- are shown live in the panel so this can be checked rather than believed - and
-- if the kick reads near zero while spraying, Arsenal does not move the camera
-- on recoil at all and no camera-side compensation can work.

local mouseDX, mouseDY = 0, 0
UserInputService.InputChanged:Connect(function(input)
	if _G.__ARSENAL ~= GEN then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		mouseDX = mouseDX + input.Delta.X
		mouseDY = mouseDY + input.Delta.Y
	end
end)

local lastYaw, lastPitch = nil, nil
local sensYaw, sensPitch = 0, 0
local sprayAt = 0

local function rcsPass(dt)
	if _G.__ARSENAL ~= GEN then return end
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
	STATE.sensY = sensYaw
	STATE.sensP = sensPitch

	if not shooting then
		STATE.kickY, STATE.kickP = 0, 0
		return
	end

	-- Vertical sensitivity is measured far less often than horizontal, so an
	-- unmeasured pitch falls back to the yaw one rather than to zero. With zero
	-- the residual is the player's whole vertical movement and the correction
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

	if not CONFIG.rcs or aimWroteCamera then return end
	if sensYaw == 0 and sp == 0 then return end
	if STATE.shots < CONFIG.rcsAfter then return end

	local cap = math.rad(CONFIG.rcsMaxDeg)
	local corrYaw   = math.clamp(-resYaw   * (CONFIG.rcsYaw   / 100), -cap, cap)
	local corrPitch = math.clamp(-resPitch * (CONFIG.rcsPitch / 100), -cap, cap)
	if math.abs(corrYaw) < 1e-5 and math.abs(corrPitch) < 1e-5 then return end

	camera.CFrame = CFrame.new(cf.Position)
		* CFrame.fromOrientation(pitch + corrPitch, yaw + corrYaw, 0)
	lastPitch, lastYaw = pitch + corrPitch, yaw + corrYaw
end

--------------------------------------------------------------------------------
-- shot counting
--------------------------------------------------------------------------------
--
-- Same problem as Counter Blox: nothing on the client holds a live ammo count
-- that this script can read, so the shot number is counted from the trigger
-- being down and the weapon's own FireRate, and reset after a 0.35s gap.

local nextShotAt = 0

local function shotClock()
	local now = os.clock()
	if not firing() then
		if now - sprayAt > 0.35 then STATE.shots = 0 end
		return
	end
	local info = weaponInfo()
	local rate = (info and info.rate) or 0.1
	if now >= nextShotAt then
		STATE.shots = STATE.shots + 1
		sprayAt = now
		nextShotAt = now + rate
		if info and not info.auto then
			nextShotAt = now + math.max(rate, 0.22)
		end
	end
end

--------------------------------------------------------------------------------
-- trigger
--------------------------------------------------------------------------------

local click = mouse1click
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
		local hit = workspace:Raycast(ray.Origin, ray.Direction * CONFIG.trigMaxDist, trigParams)
		if hit and hit.Instance then
			local model = hit.Instance:FindFirstAncestorOfClass("Model")
			if model then
				local p = Players:GetPlayerFromCharacter(model)
				if p and isEnemy(p) and alive(p) then
					if (not CONFIG.trigHeadOnly) or HEADPARTS[hit.Instance.Name] then
						return p, hit.Instance
					end
				end
			end
		end
	end
	return nil
end

local trigShots = 0
local trigWasHeld = false

local function trigActive()
	if not CONFIG.trig then return false end
	if CONFIG.hum and CONFIG.humPanelOff and STATE.panelOpen then return false end
	if CONFIG.trigActive == "Always" then return true end
	return keyHeld(CONFIG.trigKey)
end

task.spawn(function()
	local nextAt = 0
	while _G.__ARSENAL == GEN do
		local ok, err = pcall(function()
			-- Evaluated even when not armed, purely so the panel can show what is
			-- under the crosshair - without it "the key is not held" and "the ray
			-- never reaches the enemy" look identical.
			local seen = underCrosshair()
			STATE.underCross = seen and seen.Name or "-"

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

			if not gunGate(CONFIG.trigOnlyGun) then return end
			if CONFIG.trigBurst > 0 and trigShots >= CONFIG.trigBurst then return end

			local now = os.clock() * 1000
			if now < nextAt then return end
			if not seen then return end

			if math.random(100) > CONFIG.trigHitPct then
				nextAt = now + CONFIG.trigRefireMs
				return
			end

			local lo = math.min(CONFIG.trigDelayMin, CONFIG.trigDelayMax)
			local hi = math.max(CONFIG.trigDelayMin, CONFIG.trigDelayMax)
			-- fatigue: every shot deeper into the burst is a little slower, the
			-- way a real finger is
			local tired = (CONFIG.hum and CONFIG.humFatigue > 0)
				and (trigShots * CONFIG.humFatigue) or 0
			if hi > 0 then task.wait((math.random(lo, hi) + tired) / 1000) end

			-- Re-check AFTER the delay. Without this it fires at where the enemy
			-- was, which on a strafing player is a miss and a tell at once.
			if not underCrosshair() then return end

			pullTrigger()
			trigShots = trigShots + 1
			STATE.trigHits = STATE.trigHits + 1
			nextAt = os.clock() * 1000 + CONFIG.trigRefireMs
		end)
		if not ok then note("trigger: " .. tostring(err)) end
		task.wait(0.01)
	end
end)

-- Auto fire for the aim assist, kept apart from the trigger so both can run.
task.spawn(function()
	local nextAt = 0
	while _G.__ARSENAL == GEN do
		local ok, err = pcall(function()
			if not (CONFIG.aim and CONFIG.aimFire) then return end
			if STATE.target == "-" or not STATE.engaged then return end
			if not gunGate(CONFIG.aimOnlyGun) then return end
			local now = os.clock() * 1000
			if now < nextAt then return end
			if math.random(100) > CONFIG.aimHitPct then
				nextAt = now + 120
				return
			end
			if CONFIG.aimFirstMs > 0 and STATE.shots == 0 then
				task.wait(CONFIG.aimFirstMs / 1000)
				if STATE.target == "-" then return end
			end
			pullTrigger()
			local info = weaponInfo()
			nextAt = os.clock() * 1000 + math.max(((info and info.rate) or 0.1) * 1000, 60)
		end)
		if not ok then note("autofire: " .. tostring(err)) end
		task.wait(0.02)
	end
end)

-- A kill pauses the aim. Staying glued to a corpse and then flicking off it is
-- the single most obvious thing an aim assist does.
task.spawn(function()
	local seen = {}
	while _G.__ARSENAL == GEN do
		pcall(function()
			for _, p in ipairs(Players:GetPlayers()) do
				local char = p.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				local was = seen[p]
				local now = hum and hum.Health or 0
				if was and was > 0 and now <= 0 and p == stickyTarget then
					lastKillAt = os.clock() * 1000
					stickyTarget = nil
				end
				seen[p] = now
			end
		end)
		task.wait(0.1)
	end
end)

--------------------------------------------------------------------------------
-- hitbox
--------------------------------------------------------------------------------
--
-- Arsenal gives every character a dedicated `Hitbox` part, 4.5 x 4 x 4 studs,
-- fully transparent and CanQuery true, sitting on the torso. Resizing it on this
-- client is the classic Arsenal hitbox expander.
--
-- What this session could NOT measure is whether the SERVER grades a hit against
-- the client's copy of that part - the account was in the lobby throughout, so
-- no shot was ever fired. The feature therefore ships off, says so in its own
-- readout, and restores every part it touched the moment it is switched off or
-- the player leaves. Do not present it as verified until a before/after kill
-- confirms it.

local HB_PARTS = {
	["Hitbox"] = { "Hitbox" },
	["HeadHB"] = { "HeadHB" },
	["Head"]   = { "Head", "HeadHB" },
	["Hitbox + HeadHB"] = { "Hitbox", "HeadHB" },
}
local HB_LIST = { "Hitbox", "HeadHB", "Head", "Hitbox + HeadHB" }

-- The original size and transparency of everything ever touched, keyed by the
-- part itself so a respawned character simply never matches an old entry.
local hbSaved = _G.__ARSENAL_HBSAVED or {}
_G.__ARSENAL_HBSAVED = hbSaved

local function hbRestoreAll()
	for part, old in pairs(hbSaved) do
		pcall(function()
			if part and part.Parent then
				part.Size = old.size
				part.Transparency = old.trans
				part.CanCollide = old.collide
			end
		end)
		hbSaved[part] = nil
	end
	STATE.hbCount = 0
end

local function hbApply()
	local names = HB_PARTS[CONFIG.hbPart] or HB_PARTS["Hitbox"]
	local count = 0
	local size = CONFIG.hbSize
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local want = p ~= plr and char ~= nil
			and ((not CONFIG.hbEnemy) or isEnemy(p))
		if want then
			for _, n in ipairs(names) do
				local part = char:FindFirstChild(n)
				if part and part:IsA("BasePart") then
					if not hbSaved[part] then
						hbSaved[part] = { size = part.Size, trans = part.Transparency,
							collide = part.CanCollide }
					end
					-- CanCollide is forced OFF: an eight stud collidable box on
					-- every enemy turns the map into an obstacle course and is
					-- also the most visible thing this could possibly do.
					part.CanCollide = false
					part.Size = Vector3.new(size, size, size)
					part.Transparency = CONFIG.hbTrans / 100
					count = count + 1
				end
			end
		end
	end
	STATE.hbCount = count
end

task.spawn(function()
	local was = false
	while _G.__ARSENAL == GEN do
		local ok, err = pcall(function()
			if CONFIG.hb then
				hbApply()
				was = true
			elseif was then
				hbRestoreAll()
				was = false
			end
		end)
		if not ok then note("hitbox: " .. tostring(err)) end
		task.wait(math.max(0.1, CONFIG.hbEvery))
	end
	pcall(hbRestoreAll)
end)

Players.PlayerRemoving:Connect(function(p)
	local set = drawn[p]
	if set then hideSet(set) end
	local hl = highlights[p]
	if hl then pcall(function() hl:Destroy() end) highlights[p] = nil end
end)

--------------------------------------------------------------------------------
-- the frame bindings
--------------------------------------------------------------------------------

for _, name in ipairs({ "SeluxArsenalAim", "SeluxArsenalESP" }) do
	pcall(function() RunService:UnbindFromRenderStep(name) end)
end

RunService:BindToRenderStep("SeluxArsenalAim", Enum.RenderPriority.Camera.Value + 1,
	function(dt)
		if _G.__ARSENAL ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxArsenalAim") end)
			return
		end
		local ok, err = pcall(function()
			shotClock()
			aimPass(dt)
			rcsPass(dt)
		end)
		if not ok then note("aim: " .. tostring(err)) end
	end)

RunService:BindToRenderStep("SeluxArsenalESP", Enum.RenderPriority.Camera.Value + 2,
	function()
		if _G.__ARSENAL ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxArsenalESP") end)
			hideAll()
			return
		end
		local ok, err = pcall(renderPass)
		if not ok then note("esp: " .. tostring(err)) end
	end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__ARSENAL_WIN then pcall(function() _G.__ARSENAL_WIN:Destroy() end) end
for _, root in ipairs({ (gethui and gethui()) or CoreGui, CoreGui }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "ArsenalPanel" then pcall(function() g:Destroy() end) end
		end
	end
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("arsenal", CONFIG)

local win = UI.Window({
	name = "ArsenalPanel",
	title = "ARS", accentTitle = "ENAL", subtitle = "seltonmt",
	badge = "◎", width = 940, height = 590,
})
_G.__ARSENAL_WIN = win

win:SetMaster(CONFIG.esp, "ESP running")
win:OnMaster(function(on)
	CONFIG.esp = on
	note(on and "ESP on" or "ESP off")
end)

-- Every caption below is written in ENGLISH on purpose: UI.t() looks a string up
-- by exactly the characters the script passed and tools/i18n/*.tsv is keyed in
-- English, so a German literal here is a key that is in no dictionary and the
-- language flags in the header would appear to do nothing.

--------------------------------------------------------------------------------
-- ESP page
--------------------------------------------------------------------------------

local espPage = win:Page("ESP", UI.icon.eye)

local drawCard = espPage:Card("DRAWING", 1):Accent()
drawCard:Toggle("Box", CONFIG.box, function(v) CONFIG.box = v end,
	"projected head to feet, follows crouching and range", UI.theme.good)
drawCard:Toggle("Filled box", CONFIG.boxFilled, function(v) CONFIG.boxFilled = v end)
drawCard:Toggle("Name", CONFIG.name, function(v) CONFIG.name = v end)
drawCard:Toggle("Health bar", CONFIG.health, function(v) CONFIG.health = v end,
	"left of the box, green to red")
drawCard:Toggle("Health number", CONFIG.hpText, function(v) CONFIG.hpText = v end)
drawCard:Toggle("Level", CONFIG.level, function(v) CONFIG.level = v end,
	"the gun game level - this is what decides the match", UI.theme.good)
drawCard:Toggle("Weapon", CONFIG.weapon, function(v) CONFIG.weapon = v end,
	"read from the level ladder; EquippedWep never replicates", UI.theme.good)
drawCard:Toggle("Distance", CONFIG.distance, function(v) CONFIG.distance = v end)
drawCard:Toggle("Kills / streak", CONFIG.kills, function(v) CONFIG.kills = v end)
drawCard:Toggle("Head dot", CONFIG.headDot, function(v) CONFIG.headDot = v end,
	"sits on HeadHB, the part a headshot is graded against")
drawCard:Toggle("Skeleton", CONFIG.skeleton, function(v) CONFIG.skeleton = v end)
drawCard:Toggle("Tracer", CONFIG.tracer, function(v) CONFIG.tracer = v end)
drawCard:Toggle("Off screen arrows", CONFIG.offScreen, function(v)
	CONFIG.offScreen = v
end, "a marker at the screen edge for enemies behind you", UI.theme.good)

local modeCard = espPage:Card("RANGE & TEXT", 2)
modeCard:Dropdown("Targets", { "Auto", "Everyone (FFA)", "Team check" },
	CONFIG.teamMode, function(v) CONFIG.teamMode = v end)
modeCard:Toggle("Wall check", CONFIG.visCheck, function(v) CONFIG.visCheck = v end,
	"behind a wall is drawn at 55% brightness instead of full", UI.theme.good)
modeCard:Toggle("Draw team mates", CONFIG.teamESP, function(v) CONFIG.teamESP = v end)
modeCard:Toggle("Mark the leader", CONFIG.markLeader, function(v)
	CONFIG.markLeader = v
end, "whoever is closest to the last level gets his own colour")
modeCard:Slider("Max distance", 100, 3000, CONFIG.maxDist, function(v)
	CONFIG.maxDist = v
end, "studs; nothing is drawn beyond this")
modeCard:Slider("Text size", 12, 26, CONFIG.textSize, function(v) CONFIG.textSize = v end,
	"whole pixels; below 12 every Drawing face turns to mush")
modeCard:Dropdown("Font", FONTLIST, CONFIG.textFont, function(v) CONFIG.textFont = v end)
modeCard:Toggle("Text outline", CONFIG.textOutline, function(v)
	CONFIG.textOutline = v
end)
modeCard:Toggle("Shrink with distance", CONFIG.textShrink, function(v)
	CONFIG.textShrink = v
end)

local colCard = espPage:Card("COLOURS", 1)
colCard:Colour("Enemies", CONFIG.colEnemy, function(c) CONFIG.colEnemy = c end,
	"behind a wall the same colour is drawn at 55% brightness")
colCard:Colour("Team mates", CONFIG.colMate, function(c) CONFIG.colMate = c end)
colCard:Colour("Leader", CONFIG.colLeader, function(c) CONFIG.colLeader = c end)
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

--------------------------------------------------------------------------------
-- AIM page
--------------------------------------------------------------------------------

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
aimCard:Toggle("Aim enabled", CONFIG.aim, function(v)
	CONFIG.aim = v
	note(v and "aim on" or "aim off")
end, "moves the CAMERA only - fires no remote and fakes no hit", UI.theme.warn)
aimCard:Dropdown("Trigger", { "Hotkey", "Always", "While firing" }, CONFIG.aimActive,
	function(v) CONFIG.aimActive = v end)
bindButton(aimCard, "AIM KEY", function() return CONFIG.aimKey end,
	function(v) CONFIG.aimKey = v end)
aimCard:Dropdown("Aim at", { "Head", "Torso", "Hitbox", "Nearest" }, CONFIG.aimPart,
	function(v) CONFIG.aimPart = v end)
aimCard:Dropdown("Pick target by",
	{ "Crosshair", "Closest", "Lowest HP", "Lowest level" },
	CONFIG.aimPick, function(v) CONFIG.aimPick = v end)
aimCard:Toggle("Sticky target", CONFIG.aimSticky, function(v)
	CONFIG.aimSticky = v
	stickyTarget = nil
end, "holds one enemy instead of flicking to whoever is a pixel closer", UI.theme.good)
aimCard:Toggle("Visible only", CONFIG.aimVisible, function(v) CONFIG.aimVisible = v end,
	"never aims at an enemy behind a wall", UI.theme.good)
aimCard:Toggle("Firearms only", CONFIG.aimOnlyGun, function(v) CONFIG.aimOnlyGun = v end,
	"off for the knives - detected from Ammo/FireRate, not from the name")
aimCard:Dropdown("Ground condition", { "Always", "Only grounded", "Only airborne" },
	CONFIG.aimAir, function(v) CONFIG.aimAir = v end)
aimCard:Slider("Max distance", 50, 3000, CONFIG.aimMaxDist, function(v)
	CONFIG.aimMaxDist = v
end)

local shotCard = aimPage:Card("FIRST BULLET", 2)
shotCard:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov, function(v) CONFIG.aimFov = v end,
	"only enemies inside this circle around the crosshair")
shotCard:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH, function(v) CONFIG.aimSmoothH = v end,
	"horizontal; 1 = instant, 50 = about a second, frame rate independent")
shotCard:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV, function(v) CONFIG.aimSmoothV = v end,
	"vertical - slower than H takes the give-away snap off the head")

local sprayCard = aimPage:Card("OTHER BULLETS", 2)
sprayCard:Toggle("Use first bullet settings", CONFIG.aimSameAll, function(v)
	CONFIG.aimSameAll = v
end, "off = separate numbers for the rest of the magazine", UI.theme.good)
sprayCard:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov2, function(v) CONFIG.aimFov2 = v end)
sprayCard:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH2, function(v) CONFIG.aimSmoothH2 = v end)
sprayCard:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV2, function(v) CONFIG.aimSmoothV2 = v end)

local fireCard = aimPage:Card("AUTO FIRE & LEAD", 1)
fireCard:Toggle("Auto fire", CONFIG.aimFire, function(v) CONFIG.aimFire = v end,
	"pulls the trigger itself once a target is actually being tracked", UI.theme.warn)
fireCard:Slider("Hit chance %", 1, 100, CONFIG.aimHitPct, function(v) CONFIG.aimHitPct = v end,
	"below 100 deliberately skips shots")
fireCard:Slider("Delay after kill (ms)", 0, 1000, CONFIG.aimKillMs, function(v)
	CONFIG.aimKillMs = v
end, "do not stay glued to a corpse - that is the loudest tell there is")
fireCard:Slider("First bullet delay (ms)", 0, 1000, CONFIG.aimFirstMs, function(v)
	CONFIG.aimFirstMs = v
end)
fireCard:Toggle("Lead moving targets", CONFIG.aimPredict, function(v)
	CONFIG.aimPredict = v
end, "adds velocity to the aim point - most Arsenal guns are hitscan, so off")
fireCard:Slider("Lead amount (ms)", 0, 400, math.floor(CONFIG.aimPredictAmt * 1000),
	function(v) CONFIG.aimPredictAmt = v / 1000 end)
fireCard:Toggle("Draw FOV", CONFIG.aimCircle, function(v) CONFIG.aimCircle = v end)
fireCard:Toggle("Draw second FOV", CONFIG.aimCircle2, function(v) CONFIG.aimCircle2 = v end)

local aimOut = aimPage:Card("TARGET", 1):Readout(5)

--------------------------------------------------------------------------------
-- HUMANISE page
--------------------------------------------------------------------------------

local humPage = win:Page("HUMANISE", UI.icon.wave)

local humCard = humPage:Card("REACTION", 1):Accent()
humCard:Toggle("Humanisation on", CONFIG.hum, function(v)
	CONFIG.hum = v
	note(v and "humanisation on" or "humanisation OFF - the aim is a machine now")
end, "everything on this page is ignored while this is off", UI.theme.good)
humCard:Slider("Reaction min (ms)", 0, 600, CONFIG.humReactMin, function(v)
	CONFIG.humReactMin = v
end, "the aim does not engage on the same frame the enemy appears")
humCard:Slider("Reaction max (ms)", 0, 600, CONFIG.humReactMax, function(v)
	CONFIG.humReactMax = v
end, "random between min and max - a fixed value is a pattern")
humCard:Slider("Target switch lock (ms)", 0, 1500, CONFIG.humSwitchMs, function(v)
	CONFIG.humSwitchMs = v
end, "no second target may be taken inside this window")
humCard:Slider("Wind up (ms)", 0, 800, CONFIG.humRampMs, function(v)
	CONFIG.humRampMs = v
end, "the first part of a flick is three times slower and eases in")

local aimNoiseCard = humPage:Card("HAND", 2)
aimNoiseCard:Slider("Aim offset %", 0, 100, CONFIG.humOffset, function(v)
	CONFIG.humOffset = v
end, "of the target part's own size - nobody hits the same millimetre twice")
aimNoiseCard:Slider("Offset re-roll (ms)", 100, 3000, CONFIG.humOffsetMs, function(v)
	CONFIG.humOffsetMs = v
end, "so the offset drifts during a long hold instead of standing still")
aimNoiseCard:Slider("Noise (1/10 deg)", 0, 30, math.floor(CONFIG.humNoise * 10),
	function(v) CONFIG.humNoise = v / 10 end,
	"a smooth wander, not per-frame randomness - white noise reads as a stutter")
aimNoiseCard:Slider("Noise speed (1/10 Hz)", 1, 60, math.floor(CONFIG.humNoiseHz * 10),
	function(v) CONFIG.humNoiseHz = v / 10 end)
aimNoiseCard:Slider("Overshoot %", 0, 60, CONFIG.humOvershoot, function(v)
	CONFIG.humOvershoot = v
end, "a fast flick goes past the target and comes back")

local limitCard = humPage:Card("LIMITS", 2)
limitCard:Slider("Turn speed cap (deg/s)", 60, 2000, CONFIG.humMaxDegS, function(v)
	CONFIG.humMaxDegS = v
end, "the most important one - no hand turns 3000 deg/s at point blank")
limitCard:Slider("Deadzone (px)", 0, 20, CONFIG.humDeadPx, function(v)
	CONFIG.humDeadPx = v
end, "stop correcting once it is this close; pixel-perfect forever is a tell")
limitCard:Slider("FOV while moving %", 20, 100, CONFIG.humMoveFov, function(v)
	CONFIG.humMoveFov = v
end, "a running player tracks worse than a standing one")
limitCard:Slider("Break off % per second", 0, 60, CONFIG.humBreakPct, function(v)
	CONFIG.humBreakPct = v
end, "chance to simply let go of the target for a moment")
limitCard:Slider("Break length (ms)", 40, 800, CONFIG.humBreakMs, function(v)
	CONFIG.humBreakMs = v
end)
limitCard:Slider("Trigger fatigue (ms/shot)", 0, 60, CONFIG.humFatigue, function(v)
	CONFIG.humFatigue = v
end, "each shot deeper into a burst reacts a little slower")

local safeCard = humPage:Card("SAFETY", 1)
safeCard:Toggle("Pause while the panel is open", CONFIG.humPanelOff, function(v)
	CONFIG.humPanelOff = v
end, "aim and trigger stop while this window is visible", UI.theme.good)
bindButton(safeCard, "PANIC KEY", function() return CONFIG.humPanicKey end,
	function(v) CONFIG.humPanicKey = v end)
safeCard:Label("One press turns aim, trigger, auto fire and recoil control off. "
	.. "The ESP stays - a drawing has never needed panicking away.")

-- Three starting points, because forty sliders with no reference is not a
-- feature. Each one writes the whole set, so switching between them is
-- reversible and nothing is left over from the previous choice.
local function preset(name)
	if name == "Legit" then
		CONFIG.aimFov, CONFIG.aimSmoothH, CONFIG.aimSmoothV = 45, 40, 55
		CONFIG.aimSameAll, CONFIG.aimFov2 = false, 30
		CONFIG.aimSmoothH2, CONFIG.aimSmoothV2 = 60, 70
		CONFIG.aimPart, CONFIG.aimVisible, CONFIG.aimSticky = "Torso", true, true
		CONFIG.aimFire = false
		CONFIG.hum = true
		CONFIG.humReactMin, CONFIG.humReactMax = 140, 260
		CONFIG.humSwitchMs, CONFIG.humRampMs = 500, 300
		CONFIG.humOffset, CONFIG.humOffsetMs = 55, 600
		CONFIG.humNoise, CONFIG.humNoiseHz = 0.7, 1.8
		CONFIG.humOvershoot, CONFIG.humDeadPx = 12, 5
		CONFIG.humMoveFov, CONFIG.humMaxDegS = 60, 260
		CONFIG.humBreakPct, CONFIG.humBreakMs = 12, 200
		CONFIG.humFatigue = 14
		CONFIG.trigDelayMin, CONFIG.trigDelayMax = 90, 190
		CONFIG.trigHitPct = 88
	elseif name == "Normal" then
		CONFIG.aimFov, CONFIG.aimSmoothH, CONFIG.aimSmoothV = 120, 25, 25
		CONFIG.aimSameAll = true
		CONFIG.aimPart, CONFIG.aimVisible, CONFIG.aimSticky = "Head", true, true
		CONFIG.hum = true
		CONFIG.humReactMin, CONFIG.humReactMax = 90, 180
		CONFIG.humSwitchMs, CONFIG.humRampMs = 350, 220
		CONFIG.humOffset, CONFIG.humOffsetMs = 35, 700
		CONFIG.humNoise, CONFIG.humNoiseHz = 0.45, 1.6
		CONFIG.humOvershoot, CONFIG.humDeadPx = 0, 3
		CONFIG.humMoveFov, CONFIG.humMaxDegS = 100, 420
		CONFIG.humBreakPct, CONFIG.humBreakMs = 0, 160
		CONFIG.humFatigue = 8
		CONFIG.trigDelayMin, CONFIG.trigDelayMax = 40, 110
		CONFIG.trigHitPct = 100
	else -- Raw
		CONFIG.aimFov, CONFIG.aimSmoothH, CONFIG.aimSmoothV = 250, 3, 3
		CONFIG.aimSameAll = true
		CONFIG.aimPart, CONFIG.aimVisible, CONFIG.aimSticky = "Head", true, true
		CONFIG.hum = false
		-- Written even though `hum` is off, so the numbers on the HUMANISE page
		-- match what is actually configured. Leaving the previous preset's values
		-- standing made the readout claim a 260 deg/s cap while nothing was
		-- capped at all.
		CONFIG.humReactMin, CONFIG.humReactMax = 0, 0
		CONFIG.humSwitchMs, CONFIG.humRampMs = 0, 0
		CONFIG.humOffset, CONFIG.humOffsetMs = 0, 700
		CONFIG.humNoise, CONFIG.humNoiseHz = 0, 1.6
		CONFIG.humOvershoot, CONFIG.humDeadPx = 0, 0
		CONFIG.humMoveFov, CONFIG.humMaxDegS = 100, 0
		CONFIG.humBreakPct, CONFIG.humBreakMs = 0, 160
		CONFIG.humFatigue = 0
		CONFIG.trigDelayMin, CONFIG.trigDelayMax = 0, 20
		CONFIG.trigHitPct = 100
	end
	note("preset: " .. name .. " - reopen the page to see the sliders move")
	pcall(function() win:Refresh() end)
end

local presetCard = humPage:Card("PRESETS", 1)
presetCard:Button("LEGIT", function() preset("Legit") end, UI.theme.good)
presetCard:Button("NORMAL", function() preset("Normal") end, UI.theme.band)
presetCard:Button("RAW - no humanisation at all", function() preset("Raw") end,
	UI.theme.bad)

local humOut = humPage:Card("LIVE", 2):Readout(6)

--------------------------------------------------------------------------------
-- TRIGGER page
--------------------------------------------------------------------------------

local trigPage = win:Page("TRIGGER", UI.icon.bolt)

local trigCard = trigPage:Card("TRIGGERBOT", 1):Accent()
trigCard:Toggle("Trigger enabled", CONFIG.trig, function(v)
	CONFIG.trig = v
	note(v and "trigger on" or "trigger off")
end, "fires when an enemy is under the crosshair - a real mouse click", UI.theme.warn)
trigCard:Dropdown("Trigger", { "Hotkey", "Always" }, CONFIG.trigActive,
	function(v) CONFIG.trigActive = v end)
bindButton(trigCard, "TRIGGER KEY", function() return CONFIG.trigKey end,
	function(v) CONFIG.trigKey = v end)
trigCard:Dropdown("Fire mode", { "Click", "Hold" }, CONFIG.trigMode,
	function(v) CONFIG.trigMode = v end)
trigCard:Slider("Hold time (ms)", 20, 600, CONFIG.trigHoldMs, function(v)
	CONFIG.trigHoldMs = v
end, "Hold mode only - for the full autos")
trigCard:Toggle("Head only", CONFIG.trigHeadOnly, function(v) CONFIG.trigHeadOnly = v end,
	"fires only when the ray lands on Head, HeadHB or FakeHead")
trigCard:Toggle("Firearms only", CONFIG.trigOnlyGun, function(v) CONFIG.trigOnlyGun = v end)

local trigTime = trigPage:Card("TIMING", 2)
trigTime:Slider("Reaction min (ms)", 0, 500, CONFIG.trigDelayMin, function(v)
	CONFIG.trigDelayMin = v
end, "random between min and max - a fixed value is a pattern")
trigTime:Slider("Reaction max (ms)", 0, 500, CONFIG.trigDelayMax, function(v)
	CONFIG.trigDelayMax = v
end)
trigTime:Slider("Refire lockout (ms)", 20, 1000, CONFIG.trigRefireMs, function(v)
	CONFIG.trigRefireMs = v
end)
trigTime:Slider("Hit chance %", 1, 100, CONFIG.trigHitPct, function(v)
	CONFIG.trigHitPct = v
end)
trigTime:Slider("Shots per hold", 0, 30, CONFIG.trigBurst, function(v)
	CONFIG.trigBurst = v
end, "0 = unlimited")

local trigAim = trigPage:Card("TARGET WINDOW", 2)
trigAim:Slider("FOV (pixels)", 0, 60, CONFIG.trigFov, function(v) CONFIG.trigFov = v end,
	"0 = the exact centre ray only; above that a ring of six more rays")
trigAim:Slider("Max distance", 50, 3000, CONFIG.trigMaxDist, function(v)
	CONFIG.trigMaxDist = v
end)

local trigOut = trigPage:Card("STATUS", 1):Readout(4)

--------------------------------------------------------------------------------
-- RECOIL page
--------------------------------------------------------------------------------

local rcsPage = win:Page("RECOIL", UI.icon.chart)

local rcsCard = rcsPage:Card("RECOIL CONTROL", 1):Accent()
rcsCard:Toggle("RCS enabled", CONFIG.rcs, function(v)
	CONFIG.rcs = v
	note(v and "rcs on" or "rcs off")
end, "measures itself against your own mouse - no calibration step", UI.theme.warn)
rcsCard:Slider("Pitch %", 0, 100, CONFIG.rcsPitch, function(v) CONFIG.rcsPitch = v end,
	"share of the measured vertical kick that is taken back out")
rcsCard:Slider("Yaw %", 0, 100, CONFIG.rcsYaw, function(v) CONFIG.rcsYaw = v end)
rcsCard:Slider("Start at shot", 1, 10, CONFIG.rcsAfter, function(v) CONFIG.rcsAfter = v end,
	"the first bullet has no recoil, so there is nothing to cancel")
rcsCard:Slider("Max correction (deg)", 1, 15, CONFIG.rcsMaxDeg, function(v)
	CONFIG.rcsMaxDeg = v
end, "hard per-frame cap so the correction cannot oscillate")

local rcsOut = rcsPage:Card("MEASUREMENT", 2):Readout(6)
local wpnOut = rcsPage:Card("WEAPON", 2):Readout(8)

--------------------------------------------------------------------------------
-- HITBOX page
--------------------------------------------------------------------------------

local hbPage = win:Page("HITBOX", UI.icon.shield)

local hbCard = hbPage:Card("HITBOX EXPANDER", 1):Accent()
hbCard:Toggle("Hitbox expander", CONFIG.hb, function(v)
	CONFIG.hb = v
	if not v then hbRestoreAll() end
	note(v and "hitbox expander on - UNVERIFIED, see the readout"
		or "hitbox expander off, sizes restored")
end, "resizes the enemy's own Hitbox part on THIS client", UI.theme.bad)
hbCard:Slider("Size (studs)", 4, 30, CONFIG.hbSize, function(v) CONFIG.hbSize = v end,
	"the part is 4.5 x 4 x 4 by default, so 4 changes nothing")
hbCard:Dropdown("Which part", HB_LIST, CONFIG.hbPart, function(v)
	hbRestoreAll()
	CONFIG.hbPart = v
end)
hbCard:Slider("Transparency %", 0, 100, CONFIG.hbTrans, function(v) CONFIG.hbTrans = v end,
	"below 100 draws the box - useful to see what is actually being changed")
hbCard:Toggle("Enemies only", CONFIG.hbEnemy, function(v)
	hbRestoreAll()
	CONFIG.hbEnemy = v
end)
hbCard:Button("RESTORE EVERY PART NOW", function()
	hbRestoreAll()
	note("all hitbox parts restored")
end, UI.theme.band)

local hbOut = hbPage:Card("WHAT THIS IS", 2):Readout(9)

--------------------------------------------------------------------------------
-- MATCH page
--------------------------------------------------------------------------------

local matchPage = win:Page("MATCH", UI.icon.list)
local roundOut = matchPage:Card("ROUND", 0):Readout(4)
local listOut = matchPage:Card("PLAYERS", 0):Readout(13, function(text)
	if text:find("<<") then return Color3.fromRGB(255, 200, 70) end
	return nil
end)

--------------------------------------------------------------------------------
-- the panel refresh
--------------------------------------------------------------------------------

task.spawn(function()
	while _G.__ARSENAL == GEN do
		local ok, err = pcall(function()
			STATE.mode   = hudText({ "Timer", "GM" }, "-")
			STATE.sub    = hudText({ "Timer", "Sub" }, "-")
			STATE.scoreR = tonumber(hudText({ "Timer", "R" }, "0")) or 0
			STATE.scoreB = tonumber(hudText({ "Timer", "B" }, "0")) or 0
			STATE.nextWep = hudText({ "Timer", "NW" }, "-")
			STATE.aliveN = tonumber(hudText({ "PlayersAlive", "Num" }, "0")) or 0
			STATE.ffa    = ffaNow()

			local ws = ReplicatedStorage:FindFirstChild("WinnerScore")
			STATE.leader = (ws and tostring(ws.Value)) or "-"

			STATE.level = levelOf(plr)

			-- The whole lobby, sorted by level: in a gun game that IS the
			-- scoreboard, and the HUD only shows the top few.
			local rows = {}
			local camPos = camera.CFrame.Position
			local topLvl = -1
			for _, p in ipairs(Players:GetPlayers()) do
				local lvl = levelOf(p)
				if lvl > topLvl then topLvl = lvl end
			end
			for _, p in ipairs(Players:GetPlayers()) do
				local char, hum, root = alive(p)
				local lvl = levelOf(p)
				local dist = root and math.floor((camPos - root.Position).Magnitude) or nil
				local kills = tonumber(pv(p, "ScoreFolder", "Kills", 0)) or 0
				local streak = tonumber(pv(p, "ScoreFolder", "Streak", 0)) or 0
				table.insert(rows, {
					lvl = lvl,
					me = p == plr,
					line = string.format(" %-2d %-15s %-4s %-9s %-5s %d/%d%s",
						lvl,
						p.Name:sub(1, 15),
						char and (math.floor(hum.Health) .. "") or "DEAD",
						weaponForLevel(lvl):sub(1, 9),
						dist and (dist .. "m") or "-",
						kills, streak,
						(lvl == topLvl and lvl > 0) and "  <<" or ""),
				})
			end
			table.sort(rows, function(a, b)
				if a.lvl ~= b.lvl then return a.lvl > b.lvl end
				return a.line < b.line
			end)

			local lines = { " LV NAME            HP   WEAPON    DIST  K/S" }
			for i = 1, math.min(#rows, 12) do table.insert(lines, rows[i].line) end
			pcall(function() listOut:set(lines) end)

			pcall(function()
				roundOut:set({
					string.format("  %s   %s", STATE.mode, STATE.sub),
					string.format("  score  R %d : %d B      %d alive",
						STATE.scoreR, STATE.scoreB, STATE.aliveN),
					string.format("  leader %s   targets %s   drawn %d   ghosts %d",
						STATE.leader, STATE.ffa and "everyone (FFA)" or "enemy team",
						STATE.targets, STATE.ghosts or 0),
					"  " .. tostring(STATE.note),
				})
			end)

			local info, wname = weaponInfo()
			STATE.weapon = wname ~= "" and wname or "-"

			pcall(function()
				local fov, sh, sv = aimNumbers()
				aimOut:set({
					"  target   " .. tostring(STATE.target)
						.. "   shot " .. tostring(STATE.shots),
					"  state    " .. (STATE.breaking and "broken off"
						or (STATE.waitMs > 0 and ("reacting " .. STATE.waitMs .. "ms")
						or (STATE.engaged and "tracking" or "idle"))),
					"  active   " .. (CONFIG.aim and CONFIG.aimActive or "off")
						.. (CONFIG.aimActive == "Hotkey"
							and ("  " .. keyDisplay(CONFIG.aimKey)) or ""),
					string.format("  now      FOV %dpx   H %d   V %d", fov, sh, sv),
					"  weapon   L" .. tostring(STATE.level) .. "  " .. STATE.weapon
						.. (info and (info.gun and "  (firearm)"
							or (info.melee and "  (melee)" or "  (no shots)")) or ""),
				})
			end)

			pcall(function()
				humOut:set({
					"  LIVE",
					"  " .. (CONFIG.hum and "humanisation ON" or "humanisation OFF"),
					string.format("  reaction %d-%dms   switch lock %dms",
						CONFIG.humReactMin, CONFIG.humReactMax, CONFIG.humSwitchMs),
					string.format("  cap %d deg/s   deadzone %dpx   noise %.1f deg",
						CONFIG.humMaxDegS, CONFIG.humDeadPx, CONFIG.humNoise),
					string.format("  offset %d%% of part   overshoot %d%%",
						CONFIG.humOffset, CONFIG.humOvershoot),
					"  panic key " .. keyDisplay(CONFIG.humPanicKey)
						.. (STATE.panelOpen and "   (panel open)" or ""),
				})
			end)

			pcall(function()
				trigOut:set({
					"  state    " .. (CONFIG.trig
						and (STATE.trigOn and "armed"
							or ("waiting for " .. keyDisplay(CONFIG.trigKey)))
						or "off"),
					"  crosshair " .. tostring(STATE.underCross),
					string.format("  shots    %d   reaction %d-%dms  fatigue %dms/shot",
						STATE.trigHits, CONFIG.trigDelayMin, CONFIG.trigDelayMax,
						CONFIG.hum and CONFIG.humFatigue or 0),
					"  window   " .. (CONFIG.trigFov > 0
						and (CONFIG.trigFov .. "px ring") or "centre ray only")
						.. (CONFIG.trigHeadOnly and "   head only" or ""),
				})
			end)

			pcall(function()
				rcsOut:set({
					"  MEASUREMENT",
					string.format("  sens H   %.5f   V %.5f", STATE.sensY, STATE.sensP),
					string.format("  samples  %d", STATE.calibN),
					string.format("  kick H   %.2f deg", STATE.kickY),
					string.format("  kick V   %.2f deg   peak %.2f",
						STATE.kickP, STATE.kickPeak),
					"  " .. (CONFIG.rcs
						and ((STATE.calibN > 0) and "active" or "waiting for mouse movement")
						or "off"),
				})
			end)

			pcall(function()
				if not info then
					wpnOut:set({ "  WEAPON", "  " .. STATE.weapon,
						"  no entry in ReplicatedStorage.Weapons",
						"  (the level ladder names it, the folder does not carry it)" })
				elseif info.melee then
					wpnOut:set({ "  WEAPON", "  " .. info.name .. "   melee",
						"  no ammo, no fire rate - the gun gates treat it as no weapon" })
				else
					wpnOut:set({
						"  WEAPON",
						"  " .. info.name .. (info.auto and "   full auto" or "   semi auto"),
						string.format("  damage   %d   x%d per shot", info.dmg, info.bullets),
						string.format("  rate     %.3fs   magazine %d (+%d)",
							info.rate, info.ammo, info.stored),
						string.format("  spread   max %d   falloff %.2f",
							info.spread, info.falloff),
						string.format("  range    %d   reload %.2fs", info.range, info.reload),
						string.format("  recoil   %.2f   speed %+d%%",
							info.recoil, info.speed),
					})
				end
			end)

			pcall(function()
				hbOut:set({
					"  WHAT THIS IS",
					"  Arsenal gives every character a Hitbox part,",
					"  4.5 x 4 x 4 studs, invisible, CanQuery true.",
					"  This resizes THAT part on your client only.",
					"",
					"  UNVERIFIED: whether the server grades a hit",
					"  against your copy was never measured here.",
					string.format("  parts changed right now: %d", STATE.hbCount),
					"  everything is restored when this is turned off.",
				})
			end)

			pcall(function()
				win:SetStat(1, "L" .. tostring(STATE.level), "level")
				win:SetStat(2, tostring(STATE.targets), "drawn")
				win:SetStat(3, tostring(STATE.aliveN), "alive")
				win:SetStatus(string.format("%s   %s   next: %s",
					STATE.mode, STATE.weapon, STATE.nextWep))
			end)
		end)
		if not ok then note("ui: " .. tostring(err)) end
		task.wait(0.4)
	end
end)

-- Is the panel on screen? The safety toggle needs to know, and the template
-- shows and hides the WINDOW FRAME (`window.root.Visible`) rather than the
-- ScreenGui - RightShift flips exactly that one property. Reading `gui.Enabled`
-- instead would have been true the whole time and the pause would never fire.
task.spawn(function()
	while _G.__ARSENAL == GEN do
		pcall(function()
			local root = win and win.root
			STATE.panelOpen = (root ~= nil) and root.Visible == true
		end)
		task.wait(0.25)
	end
end)

-- The camera reference is replaced on every respawn, so a cached one silently
-- stops updating after the first death - which looks exactly like "the ESP broke
-- when I died".
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then camera = workspace.CurrentCamera end
end)

pcall(function() win:Home() end)
win:Refresh()

--------------------------------------------------------------------------------

_G.__ARSENAL_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	alive = alive, isEnemy = isEnemy, visible = visible, pickTarget = pickTarget,
	renderPass = renderPass, aimPass = aimPass, rcsPass = rcsPass,
	shotClock = shotClock, aimNumbers = aimNumbers, targetPart = targetPart,
	underCrosshair = underCrosshair, pullTrigger = pullTrigger,
	weaponInfo = weaponInfo, weaponForLevel = weaponForLevel, levelOf = levelOf,
	statusTeam = statusTeam, gunGate = gunGate, airGate = airGate,
	keyHeld = keyHeld, approach = approach, angleDelta = angleDelta,
	firing = firing, hudText = hudText, ffaNow = ffaNow,
	hbApply = hbApply, hbRestoreAll = hbRestoreAll, hbSaved = hbSaved,
	noiseStep = noiseStep, aimOffset = aimOffset, movingNow = movingNow,
	preset = preset, refreshFilter = refreshFilter, scanGhosts = scanGhosts,
	drawn = drawn, highlights = highlights, hideAll = hideAll,
	clearChams = clearChams, note = note, pv = pv,
}

print("[arsenal] gen " .. GEN .. " ready - RightShift for the panel")
