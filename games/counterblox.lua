--[[ counterblox.lua - "Counter Blox" (place 301549746)

  The first SHOOTER in this collection, so nothing from the clicker/idle scripts
  transfers: there is no economy to farm, no ladder to climb and no remote worth
  firing. What a 5v5 round needs is INFORMATION, and Counter Blox hands all of it
  to the client already - it just never draws it.

  Measured through the bridge before a line of this was written:

  * **Enemy positions replicate in full.** `Character.HumanoidRootPart.Position`
    reads correctly for every player on the other team, at any distance, through
    any wall - there is no server-side culling of the far team. That single fact
    is what makes an ESP possible at all; in a game with culling none of this
    would work.
  * **The character is R15** and carries its own hitbox parts: `HeadHB` is the
    head hitbox (the one the game grades a headshot against), `Head` and
    `FakeHead` are the visuals. Aim at `HeadHB` when it exists.
  * **The weapon is a string, not a Tool.** `Character.EquippedTool` is a
    StringValue holding "AWP" / "AK47" / …, and `Character.ADS` is a BoolValue
    that is true while that player is scoped. Both replicate.
  * **`workspace.Status` is the whole round.** `Timer`, `Armed` (bomb planted),
    `Defused`, `HasBomb` (the NAME of the carrier), `MapName`, `CTWins`/`TWins`,
    `Rounds`, `NumCT`/`NumT`. All plain ValueBase children, all readable.
  * **`Player.Cash` replicates for EVERY player**, not just the local one - so the
    enemy economy is knowable, which is the one piece of information a CS player
    would normally have to guess. Same for `Score`, `Damage` and `Ping`.
  * `BackC4` on a character is the defuse-kit/backpack accessory and appears on
    BOTH teams - it is NOT the bomb carrier. Read `Status.HasBomb` instead. That
    one cost a wrong first draft.

  Drawn with the executor's **Drawing** library, not a ScreenGui. Drawing objects
  live outside the DataModel entirely, so no client script of the game can walk
  the tree and find them - and there is no per-frame instance churn either. All
  seven shapes were verified present in Potassium. The optional chams use a real
  `Highlight`, which HAS to be an Instance, so it is parented to `gethui()` /
  `CoreGui` rather than into the character.

  The aim assist moves the CAMERA and nothing else - it fires no remote and
  fakes no hit. Whatever the server checks when the shot is taken, it sees a
  perfectly ordinary shot from a client that happens to be looking at a head.
  It is bound at `RenderPriority.Camera + 1` so it lands after the game's own
  camera step instead of being overwritten by it.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
-- NOT `game:GetService("CoreGui")`. On Volt the script runs on a thread without
-- the Plugin capability and that call THROWS ("The current thread cannot access
-- 'CoreGui'") instead of returning nil - at the top of the file it took the whole
-- script down before a single line of it ran.
local CoreGui
do
	local ok, svc = pcall(game.GetService, game, "CoreGui")
	CoreGui = ok and svc or nil
end

local plr    = Players.LocalPlayer
local camera = workspace.CurrentCamera

local GEN = (_G.__CBLOX or 0) + 1
_G.__CBLOX = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	box        = true,     -- 2D bounding box around the player
	boxFilled  = false,    -- tinted fill inside the box
	name       = true,     -- player name above the box
	health     = true,     -- vertical HP bar on the left of the box
	weapon     = true,     -- "AWP  32m" under the box
	distance   = true,
	tracer     = false,    -- line from the bottom of the screen to the feet
	headDot    = true,     -- circle on the head hitbox
	skeleton   = false,    -- R15 bone lines
	chams      = false,    -- Highlight through walls
	teamESP    = false,    -- draw team mates too (dimmed)
	visCheck   = true,     -- colour differently when a wall is in the way
	maxDist    = 1000,     -- studs; further away is not drawn
	textSize   = 14,       -- upper bound for the labels; they shrink under it
	textFont   = "System", -- UI | System | Plex | Monospace
	textOutline = true,    -- black outline behind the glyphs
	textShrink = false,    -- let distant labels shrink at all

	hpText     = true,     -- the bare health number in the info line

	colEnemy   = Color3.fromRGB(255, 72, 88),
	colMate    = Color3.fromRGB(80, 190, 255),
	colCham    = Color3.fromRGB(255, 72, 88),
	colChamOwn = false,    -- chams use colCham instead of the team colour
	colFov     = Color3.fromRGB(255, 255, 255),

	-- overlays ------------------------------------------------------------------
	crosshair  = false,    -- a static cross that ignores the game's own spread
	crossSize  = 8,
	crossGap   = 3,
	crossDot   = true,
	crossThick = 1,
	colCross   = Color3.fromRGB(90, 255, 140),
	sprayDraw  = false,    -- the weapon's own spray curve, drawn on screen
	spraySize  = 90,       -- pixels for the whole pattern
	fovChange  = false,    -- client-side field of view
	fovValue   = 90,
	bombTimer  = true,     -- big countdown once the C4 is armed

	chamStyle  = "Fill",   -- see CHAM_STYLES
	chamRainbow = false,   -- cycle the hue instead of using the team colour
	chamByHealth = false,  -- colour the highlight from the target's health

	-- aim assist ---------------------------------------------------------------
	aim        = false,
	aimActive  = "Hotkey", -- Hotkey | Always | While firing
	aimKey     = "MouseButton2",
	aimPart    = "Head",   -- Head | Torso | Nearest
	aimPick    = "Crosshair", -- Crosshair | Closest | Lowest HP
	aimSticky  = true,     -- keep the target until it dies or leaves the FOV
	aimVisible = true,     -- ignore targets behind a wall
	aimMaxDist = 1000,
	aimOnlyGun = true,     -- off while holding a knife or a grenade
	aimAds     = "Always", -- Always | Scoped only | Not scoped

	-- Counter Strike splits the spray in two: the first bullet is the accurate
	-- one and is aimed differently from the rest of the magazine. Same split as
	-- the reference menu - one set of numbers for shot one, one for the rest.
	-- Smooth is a DIVISOR, not a lerp alpha, and it is normalised to 60 FPS.
	-- The first build used camera:Lerp(want, alpha) once per frame: at the 214 FPS
	-- this machine runs, even alpha 0.1 is on target inside three frames, so every
	-- setting felt like a hard snap. 1 = instant, 50 = about a second of travel,
	-- and the same number behaves the same at 30 FPS as at 240.
	aimFov     = 120,      -- first bullet, pixels around the crosshair
	aimSmoothH = 25,       -- horizontal (yaw), higher = slower
	aimSmoothV = 25,       -- vertical (pitch)
	aimSameAll = true,     -- use the first-bullet numbers for the whole spray
	aimFov2    = 60,
	aimSmoothH2 = 50,
	aimSmoothV2 = 50,

	aimFire    = false,    -- pull the trigger once the target is centred
	aimHitPct  = 100,      -- ...this often, in percent
	aimKillMs  = 250,      -- pause after a kill, milliseconds
	aimFirstMs = 0,        -- delay before the first bullet of a burst

	aimCircle  = true,     -- draw the FOV circles
	aimCircle2 = true,     -- ...including the second, smaller one

	-- humanisation ---------------------------------------------------------------
	-- Every number an assist produces that a hand could not produce is a tell, and
	-- each knob below removes one specific tell. Defaults are the middle preset.
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
	humPanicKey = "F1",    -- one key that switches aim, trigger, rcs and autofire off

	-- trigger ------------------------------------------------------------------
	trig       = false,
	trigActive = "Hotkey", -- Hotkey | Always
	trigKey    = "C",
	trigMode   = "Click",  -- Click | Hold
	trigHoldMs = 120,      -- how long the button stays down in Hold mode
	trigDelayMin = 40,     -- reaction delay before firing, milliseconds
	trigDelayMax = 90,
	trigRefireMs = 90,     -- cooldown between two triggered shots
	trigHitPct = 100,
	trigHeadOnly = false,
	trigMaxDist = 1000,
	trigFov    = 0,        -- 0 = only the exact crosshair ray, >0 = pixel radius
	trigOnlyGun = true,
	trigAds    = "Always", -- Always | Scoped only | Not scoped
	trigBurst  = 0,        -- 0 = unlimited, else shots per activation

	-- recoil -------------------------------------------------------------------
	rcs        = false,
	-- Two independent sources, and the panel can run either or both.
	--
	--   Measured  every frame the camera's angle change is compared against the raw
	--             mouse movement for that frame; while NOT firing the ratio is the
	--             effective sensitivity, while firing the leftover is the recoil.
	--             Adapts on its own, needs no calibration step - but it carries the
	--             VERTICAL kick well and the sideways half hardly at all, because
	--             the player's own mouse is moving horizontally the whole time and
	--             drowns it.
	--   Pattern   the game hands over the real curve. Each weapon folder carries
	--             `Pattern`, a JSON array of {fMagnitude, fAngle} - the literal
	--             CS:GO spray table, one entry per bullet, in POLAR form and
	--             normalised so the largest magnitude is 1. That is where left and
	--             right actually come from. What one pattern unit is worth in
	--             camera radians is the only unknown, and rather than hard-coding a
	--             guess the script LEARNS it from the measured residual and puts
	--             the number on screen.
	rcsMode    = "Both",   -- Measured | Pattern | Both
	rcsPitch   = 70,       -- percent of the vertical kick to cancel
	rcsYaw     = 70,
	rcsAfter   = 1,        -- start compensating from this shot on
	rcsMaxDeg  = 4,        -- hard cap per frame, degrees
	rcsPatAuto = true,     -- learn the pattern-to-camera scale instead of setting it
	rcsPatScale = 100,     -- ...the manual value, in hundredths
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
	"health",
	"hpText",
	"weapon",
	"distance",
	"headDot",
	"skeleton",
	"tracer",
	"teamESP",
	"chams",
}

local function anyDrawing()
	for _, key in ipairs(DRAWINGS) do
		if CONFIG[key] then return true end
	end
	return false
end


local STATE = {
	note      = "",
	targets   = 0,
	target    = "-",
	weapon    = "-",
	shots     = 0,
	trigHits  = 0,
	trigOn    = false,
	sensY     = 0, sensP = 0, calibN = 0,
	kickY     = 0, kickP = 0, kickPeak = 0,
	patY      = 0, patP = 0, patScale = 0, patN = 0, patLen = 0,
	waitMs    = 0,       -- reaction delay still to run on the current target
	breaking  = false,   -- the humaniser has deliberately let go
	engaged   = false,   -- the aim moved the camera on the last frame
	panelOpen = false,
	underCross = "-",
	lastKey   = "-",
	clickHow  = "-",   -- which executor call actually delivers a shot, see pullTrigger
	touch     = false, -- this client has no mouse and no keyboard
	map       = "-",
	timer     = 0,
	ctWins    = 0, tWins = 0,
	bomb      = "-",
	armed     = false,
	alive     = { ct = 0, t = 0 },
}

local COLOUR = {
	enemy    = Color3.fromRGB(255, 72, 88),
	enemyDim = Color3.fromRGB(150, 45, 55),
	mate     = Color3.fromRGB(80, 190, 255),
	mateDim  = Color3.fromRGB(45, 110, 150),
	hpGood   = Color3.fromRGB(90, 220, 120),
	hpBad    = Color3.fromRGB(230, 80, 60),
	text     = Color3.fromRGB(235, 235, 240),
	fov      = Color3.fromRGB(255, 255, 255),
	black    = Color3.fromRGB(0, 0, 0),
}

local function note(text)
	STATE.note = tostring(text)
end

-- The "behind a wall" variant is DERIVED from the chosen colour rather than
-- being a second picker: two pickers per team is four colours to keep in
-- harmony, and dropping the brightness to 55% reads as "same enemy, no line of
-- sight" whatever hue was picked.
local function dimmed(colour)
	local h, s, v = Color3.toHSV(colour)
	return Color3.fromHSV(h, s * 0.9, v * 0.55)
end

local function teamColour(enemy)
	local base = enemy and CONFIG.colEnemy or CONFIG.colMate
	return base, dimmed(base)
end

--------------------------------------------------------------------------------
-- game state helpers
--------------------------------------------------------------------------------

local Status = workspace:FindFirstChild("Status")

local function statusValue(name, fallback)
	if not Status then return fallback end
	local v = Status:FindFirstChild(name)
	if not v then return fallback end
	local ok, value = pcall(function() return v.Value end)
	if not ok then return fallback end
	return value
end

-- The alive test every other function funnels through. A dead character is left
-- parented to the Workspace in this game (the ragdoll stays), so "the model
-- exists" proves nothing at all - only the Humanoid's health does.
local function alive(p)
	local char = p.Character
	if not char or not char.Parent then return nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	return char, hum, root
end

local function isEnemy(p)
	if p == plr then return false end
	if not p.Team or not plr.Team then return true end
	return p.Team ~= plr.Team
end

local function aimPoint(char)
	if CONFIG.aimPart == "Torso" then
		return char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart")
	end
	return char:FindFirstChild("HeadHB") or char:FindFirstChild("Head")
		or char:FindFirstChild("HumanoidRootPart")
end

-- Line of sight. Everything a bullet would not stop on has to be filtered out or
-- every target reads as blocked: the other characters, the local character, the
-- game's own Ray_Ignore folder (it maintains one for exactly this) and Debris.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

-- Everything a BULLET would not stop on. Two of these were found by measurement,
-- not by reading the map:
--
--  * `Workspace.Map.Clips` - 210 fully transparent parts named CLIP, collision
--    group "Clips". They are the CS movement clip brushes: solid to a player,
--    invisible, and bullets pass straight through them. Left in the filter every
--    single enemy on de_dust2 read as "behind a wall" - five out of five, at
--    every distance - because the ray stopped on an invisible brush the moment
--    it left the spawn. It would also have made the trigger literally never fire.
--  * `Ray_Ignore` is the game's OWN ignore list and holds the fire and smoke
--    volumes, so a smoke grenade does not count as cover for the ESP either.
local function ignoreList()
	local list = {}
	for _, name in ipairs({ "Ray_Ignore", "Debris", "FunFacts" }) do
		local f = workspace:FindFirstChild(name)
		if f then table.insert(list, f) end
	end
	local map = workspace:FindFirstChild("Map")
	local clips = map and map:FindFirstChild("Clips")
	if clips then table.insert(list, clips) end
	return list
end

local function refreshFilter()
	local list = ignoreList()
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then table.insert(list, p.Character) end
	end
	rayParams.FilterDescendantsInstances = list
end

local function visible(worldPos)
	local origin = camera.CFrame.Position
	local dir = worldPos - origin
	local hit = workspace:Raycast(origin, dir, rayParams)
	return hit == nil
end

--------------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------------
--
-- Every Drawing object is created ONCE per player and then only shown, hidden and
-- moved. Creating them per frame is what makes a naive ESP stutter: Drawing.new
-- is a C-side allocation and 200 of them a frame is felt immediately.

-- Four faces, and none of them is right for every setup, which is why this is a
-- setting rather than a constant:
--
--   0 UI         Roblox's own Source Sans. Vector, but THIN - at 10-12 px the
--                stems drop below one pixel and it goes grey and fuzzy.
--   1 System     the OS face. Hinted for small sizes, so it is the crispest of
--                the four at exactly the sizes an ESP uses. Default here.
--   2 Plex       IBM Plex. Heavier than UI, good at 13+.
--   3 Monospace  a BITMAP face. Sharp at 16+, mush below it.
--
-- Two things matter as much as the face itself: the size must be a WHOLE number
-- (a fractional size lands between pixels and smears), and shrinking the label
-- with distance - which the first version did - drives it straight into the size
-- range where every one of these faces falls apart. Shrinking is now off by
-- default and the floor is 12, not 9.
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

local FONT = 1

local drawn = {}          -- [player] = { objects }
local pool  = {}          -- flat list, for the cleanup on re-execute

-- A previous run's drawings survive a re-execute exactly like a loop does: the
-- Lua VM is not restarted, so the old objects are still on screen with nothing
-- updating them. The generation guard stops the LOOP; only this clears the pixels.
if _G.__CBLOX_POOL then
	for _, obj in ipairs(_G.__CBLOX_POOL) do pcall(function() obj:Remove() end) end
end
_G.__CBLOX_POOL = pool

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
			Font = FONT, Color = COLOUR.text, ZIndex = 3 }),
		info     = make("Text", { Size = 12, Center = true, Outline = true,
			Font = FONT, Color = COLOUR.text, ZIndex = 3 }),
		tracer   = make("Line", { Thickness = 1, ZIndex = 1 }),
		head     = make("Circle", { Thickness = 1, Filled = false, NumSides = 14,
			ZIndex = 3 }),
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
	for _, line in ipairs(set.bones) do line.Visible = false end
end

local function hideAll()
	for _, set in pairs(drawn) do hideSet(set) end
end

--------------------------------------------------------------------------------
-- chams
--------------------------------------------------------------------------------
--
-- A Highlight is a real Instance and cannot be avoided, so the only question is
-- where it lives. Parented into the character it sits in the Workspace where any
-- client script can walk onto it; parented to gethui()/CoreGui with an Adornee it
-- renders identically and is not in the game's tree at all.

-- gethui() can throw rather than return nil, and CoreGui is nil on an executor
-- that refuses it (Volt) - so PlayerGui is the last resort, where a Highlight
-- renders exactly the same.
local hlRoot
pcall(function() hlRoot = gethui and gethui() end)
hlRoot = hlRoot or CoreGui or plr:WaitForChild("PlayerGui", 10)
local chamsFolder = hlRoot:FindFirstChild("SeluxCBloxChams")
if chamsFolder then pcall(function() chamsFolder:Destroy() end) end
chamsFolder = Instance.new("Folder")
chamsFolder.Name = "SeluxCBloxChams"
chamsFolder.Parent = hlRoot

local highlights = {}

-- A Highlight only has four knobs - fill colour, fill transparency, outline
-- colour, outline transparency - plus DepthMode. Every look below is a
-- combination of those five and nothing more exotic is possible with this class.
--
-- `Occluded` is the interesting one: the highlight then draws ONLY where the
-- model is behind something. The player renders normally when in the open and
-- lights up the moment they step behind a wall, which reads far more naturally
-- than a permanently glowing body.
local CHAM_STYLES = {
	["Fill"]    = { fill = 0.35, out = 0,   depth = "AlwaysOnTop" },
	["Solid"]   = { fill = 0,    out = 0,   depth = "AlwaysOnTop" },
	["Outline"] = { fill = 1,    out = 0,   depth = "AlwaysOnTop" },
	["Glow"]    = { fill = 0.78, out = 0.15, depth = "AlwaysOnTop", boost = 1.6 },
	["Ghost"]   = { fill = 0.6,  out = 0.4, depth = "AlwaysOnTop", boost = 0.55 },
	["Wall only"] = { fill = 0.35, out = 0, depth = "Occluded" },
	["Wall outline"] = { fill = 1, out = 0, depth = "Occluded" },
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
		-- os.clock is fine here; the pattern only has to move, not to be in sync
		-- with anything, and a per-player phase keeps a team from strobing as one
		-- solid block.
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

-- FORWARD DECLARED, and this is not a style choice. Both are defined further down
-- (the weapon block and the recoil block), and a Lua local is invisible above its
-- own definition - so `drawSpray` would capture a nil and error on every frame,
-- inside a pcall, surfacing as one quiet line in the panel footer rather than as a
-- crash. Declaring them here and dropping the `local` at the definitions makes the
-- render pass see the real functions.
local weaponInfo, sprayCurve

-- The static overlays. All four are drawn BEFORE the anyDrawing() gate below,
-- because that gate asks "is any per-player drawing switched on" - a crosshair or
-- a bomb timer has nothing to do with players and must not disappear because the
-- ESP list happens to be empty.
local crossLines = {}
for i = 1, 4 do
	crossLines[i] = make("Line", { Thickness = 1, ZIndex = 4 })
end
local crossDot = make("Circle", { Filled = true, NumSides = 8, Radius = 1, ZIndex = 4 })

-- 40 rather than 32: the longest Pattern in this game is 31 entries and a rifle
-- with a bigger magazine skin would run past a 32-line pool silently.
local sprayLines = {}
for i = 1, 40 do
	sprayLines[i] = make("Line", { Thickness = 1, ZIndex = 2, Transparency = 0.55 })
end

local bombText = make("Text", { Size = 22, Center = true, Outline = true, Font = FONT,
	Color = Color3.fromRGB(255, 90, 70), ZIndex = 5 })

local function centre()
	local vp = camera.ViewportSize
	return Vector2.new(vp.X / 2, vp.Y / 2)
end

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

-- The overlay is the weapon's OWN pattern, the same table the recoil control
-- corrects against, normalised to its widest point and drawn downward from the
-- crosshair so it reads the way the spray is actually shot.
local function drawSpray(mid)
	local pts = nil
	if CONFIG.sprayDraw then
		local _, wname = weaponInfo()
		pts = sprayCurve(wname)
	end
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
			-- The shots already fired are marked with COLOUR and THICKNESS, never
			-- with Transparency: the Drawing library reads 0 as invisible on some
			-- executors and as opaque on others, so a "faint" value on one machine is
			-- solid on the next. 0.85 is nearly opaque under either reading.
			line.Transparency = 0.85
			line.Thickness = (i <= shot) and 2 or 1
			line.Color = (i <= shot) and Color3.fromRGB(255, 200, 90)
				or Color3.fromRGB(150, 150, 165)
		else
			line.Visible = false
		end
	end
end

local filterAt = 0
local fovSaved = nil     -- the FieldOfView the game had before the switch was on

local function renderPass()
	if _G.__CBLOX ~= GEN then return end

	local mid = centre()

	drawCrosshair(mid)
	drawSpray(mid)

	-- A real countdown rather than a count-up: unlike the game BloxStrike is built
	-- on, this one publishes the fuse itself - workspace.Status.Timer keeps running
	-- as the bomb timer once Armed is true.
	bombText.Visible = CONFIG.bombTimer and STATE.armed
	if bombText.Visible then
		bombText.Position = Vector2.new(mid.X, mid.Y * 0.35)
		bombText.Text = string.format("BOMB ARMED   %ds", STATE.timer)
	end

	-- Restoring to a hardcoded 70 was wrong: this client sits at 75 and the game
	-- also moves the FOV itself while scoped, so the number to put back is the one
	-- that was there before the switch was thrown, not a constant. Captured on the
	-- rising edge and used on the falling one.
	if CONFIG.fovChange then
		if not fovSaved then fovSaved = camera.FieldOfView end
		pcall(function() camera.FieldOfView = CONFIG.fovValue end)
	elseif fovSaved then
		pcall(function() camera.FieldOfView = fovSaved end)
		fovSaved = nil
	end

	fovCircle.Visible = CONFIG.aim and CONFIG.aimCircle
	if fovCircle.Visible then
		fovCircle.Position = mid
		fovCircle.Radius = CONFIG.aimFov
		fovCircle.Color = CONFIG.colFov
	end
	-- The second ring is the spray FOV. Drawn only when the split is actually in
	-- use, otherwise it is a circle that means nothing.
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

	if not anyDrawing() then
		hideAll()
		clearChams()
		STATE.targets = 0
		return
	end

	-- The exclude list only changes when somebody spawns or leaves; rebuilding it
	-- every frame costs more than the raycast it feeds.
	local now = os.clock()
	if now - filterAt > 1 then
		filterAt = now
		refreshFilter()
	end

	local vp = camera.ViewportSize
	local camPos = camera.CFrame.Position
	local count = 0

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

				local base, dim = teamColour(enemy)
				local col = seen and base or dim

				-- DO NOT use Model:GetBoundingBox() here. Measured on a live round:
				-- it reports 30 x 77 x 32 studs for a character whose real extent,
				-- computed by hand over all 33 parts, is 2.3 x 6.5 x 2.5. No part
				-- is oversized and none sits more than 4 studs off the root, so
				-- whatever it is measuring is not the body. The visible symptom was
				-- boxes covering half the screen and barely shrinking with range.
				--
				-- What is honest is the pair of points the box actually needs: the
				-- top of the head and the bottom of the lower foot. Projected, the
				-- distance between them IS the on-screen height, so the box scales
				-- with distance for free and follows a crouch exactly - measured at
				-- 166 studs it came out 31 px, which is what the player looks like.
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

				-- Z <= 0 means the point is BEHIND the camera; the X/Y it reports
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

					-- HP bar, left of the box, growing from the bottom.
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

					-- One whole-number size for both labels. With shrinking on it may
					-- drop two steps for a distant target, never below 12 - under
					-- that every Drawing face turns to mush regardless of which one
					-- is picked.
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

					-- One line for everything numeric; three separate Text objects
					-- stacked under a box is unreadable at range.
					local bits = {}
					if CONFIG.weapon then
						local tool = char:FindFirstChild("EquippedTool")
						local ads  = char:FindFirstChild("ADS")
						local name2 = (tool and tool.Value ~= "" and tool.Value) or "-"
						if ads and ads.Value then name2 = name2 .. "*" end
						table.insert(bits, name2)
					end
					if CONFIG.distance then
						table.insert(bits, string.format("%dm", math.floor(dist)))
					end
					-- This line used to be unconditional, which is why turning every
					-- ESP option off still left a bare health number floating in the
					-- air with nothing to switch it off.
					if CONFIG.hpText then
						table.insert(bits, string.format("%d", math.floor(hum.Health)))
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

					-- Sized off the BODY height, not off the box width: an R15 head is
					-- about a seventh of standing height, and deriving it from the
					-- same measurement that draws the box keeps the two in step at
					-- every range. Floored at 1.5 px so a 300 m target is still a dot
					-- and not a single pixel.
					set.head.Visible = CONFIG.headDot and head ~= nil
					if set.head.Visible then
						local sp = camera:WorldToViewportPoint(head.Position)
						set.head.Position = Vector2.new(sp.X, sp.Y)
						set.head.Radius = math.max(1.5, h * 0.075)
						set.head.Color = col
					end

					if CONFIG.skeleton then
						for i, bone in ipairs(BONES) do
							local a = char:FindFirstChild(bone[1])
							local b = char:FindFirstChild(bone[2])
							local line = set.bones[i]
							if a and b then
								local pa, va = camera:WorldToViewportPoint(a.Position)
								local pb, vb = camera:WorldToViewportPoint(b.Position)
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
-- aim assist
--------------------------------------------------------------------------------

-- Any key, recorded by pressing it -------------------------------------------
--
-- No fixed list any more: a binding is stored as a plain string and resolved
-- against Enum.KeyCode / Enum.UserInputType at the time it is checked, so
-- literally every key the client receives can be bound.
--
-- What the client does NOT receive is the mouse side buttons. Roblox's
-- Enum.UserInputType has exactly MouseButton1, MouseButton2 and MouseButton3 and
-- nothing else - checked on this executor, the full enum is 21 items and there
-- is no XButton1/XButton2 among them - and Potassium exposes no raw key-state
-- function either (getkeystate, iskeydown, getpressedkeys: all absent; only
-- keypress/keyrelease, which SEND input rather than read it). So a side button
-- cannot be bound from inside Roblox at all. The working answer is to map the
-- side button to a keyboard key in the mouse's own driver and bind that key
-- here; the recorder below will then pick it up like any other key.

local function keyDisplay(name)
	local n = tostring(name)
	local side = n:match("^MouseButton(%d)$")
	if side then return "MOUSE " .. side end
	return string.upper(n)
end

-- Indexing a Roblox Enum with a name it does not have THROWS ("C is not a valid
-- member of Enum.UserInputType") instead of returning nil, so neither lookup may
-- be attempted speculatively. Measured: the trigger loop was erroring on every
-- single iteration with the default key "C" bound, and the only visible sign was
-- one line in the panel footer.
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

local capturing = nil

local function keyHeld(name)
	if not name or name == "" then return false end
	local spec = resolveKey(name)
	if not spec then return false end
	if spec.mouse then return UserInputService:IsMouseButtonPressed(spec.mouse) end
	return UserInputService:IsKeyDown(spec.key)
end

-- The recorder. One at a time, and it swallows the input it captures so binding
-- a key does not also fire whatever that key does in the game.
local capturing = nil

-- The click that ARMS the recorder must never become the binding, and that is
-- harder than it looks because Roblox fires `MouseButton1Click` on the RELEASE.
-- The order is: InputBegan(M1) -> user lets go -> MouseButton1Click -> the
-- handler sets `capturing` -> InputEnded(M1). So the recorder is armed one event
-- before the release of its own arming click arrives, and binding on either edge
-- captures MOUSE 1 instantly. That is exactly what happened.
--
-- The fix is a guard that does not care about event order at all: after arming,
-- accept nothing until the left button is observed to be PHYSICALLY UP, plus a
-- short settle. From then on any key or mouse button binds, on press for the
-- keyboard and on release for the mouse.
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
	if _G.__CBLOX ~= GEN or not capturing or armedGuard then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if input.KeyCode == Enum.KeyCode.Escape then capture(nil) return end
	if input.KeyCode == Enum.KeyCode.Unknown then return end
	capture(input.KeyCode.Name)
end)

UserInputService.InputEnded:Connect(function(input)
	if _G.__CBLOX ~= GEN or not capturing or armedGuard then return end
	local name = input.UserInputType.Name
	if name:sub(1, 11) ~= "MouseButton" then return end
	capture(name)
end)

-- The panic key. One press and every input-touching feature is off - the ESP
-- stays, because a drawing has never had to be panicked away. Deliberately a
-- KeyCode comparison rather than keyHeld: this has to fire on the press, once.
UserInputService.InputBegan:Connect(function(input, typing)
	if _G.__CBLOX ~= GEN or typing or capturing then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if CONFIG.humPanicKey == "" then return end
	local spec = resolveKey(CONFIG.humPanicKey)
	if not spec or not spec.key or input.KeyCode ~= spec.key then return end
	CONFIG.aim, CONFIG.trig, CONFIG.rcs, CONFIG.aimFire = false, false, false, false
	note("PANIC - aim, trigger, rcs and auto fire off")
end)

--------------------------------------------------------------------------------
-- a client with no mouse and no keyboard
--------------------------------------------------------------------------------
--
-- Everything above this point is a mouse or a keyboard, and a phone has neither.
-- Read out of the code rather than guessed, and every one of the four is fatal on
-- its own:
--
--   * `keyHeld` ends in IsMouseButtonPressed / IsKeyDown. On a client with
--     MouseEnabled and KeyboardEnabled both false those return false forever, so
--     "Hotkey" - the DEFAULT for both the aim assist and the trigger - could never
--     become true. MouseButton2 and "C" are simply not reachable there.
--   * `firing()` read MouseButton1, so "While firing", the shot counter and the
--     whole recoil pass were dead as well.
--   * the recorder that rebinds a key takes Keyboard on InputBegan and
--     MouseButton on InputEnded and nothing else, so a phone could not even bind
--     its way out of it.
--   * Roblox does NOT synthesise MouseMovement on a touch client - a camera drag
--     arrives as UserInputType.Touch - so the sensitivity calibration never got a
--     single sample and the recoil correction bailed out at `sensYaw == 0`.
--
-- So on a phone the ESP drew and NOTHING else in this script could ever run, with
-- no error and no note to say why. Everything below is ADDITIVE: every mouse path
-- is left exactly as it was, so a desktop behaves identically.
local TOUCH = false
pcall(function()
	TOUCH = UserInputService.TouchEnabled
		and not UserInputService.MouseEnabled
		and not UserInputService.KeyboardEnabled
end)
-- Test hook, the same idea as _G.__SEL_VIEWPORT in the panel template: there is no
-- way to give a desktop client a phone's input, and a branch that cannot be run on
-- the machine it is written on is a branch that ships unverified. Never set in
-- normal use.
if _G.__CBLOX_FORCE_TOUCH then TOUCH = true end
STATE.touch = TOUCH

-- Counting fingers with a plain +1/-1 drifts the moment one InputEnded is missed
-- (a finger that leaves over the Roblox top bar does that), and a count stuck at 1
-- would leave "Screen held" permanently on. The set is keyed by the InputObject
-- and re-checked on every read, so a stale entry removes itself.
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
	if _G.__CBLOX ~= GEN then return end
	if input.UserInputType == Enum.UserInputType.Touch then touches[input] = true end
end)

UserInputService.InputEnded:Connect(function(input)
	if _G.__CBLOX ~= GEN then return end
	if input.UserInputType == Enum.UserInputType.Touch then touches[input] = nil end
end)

-- Set by pullTrigger. It is the only thing a touch client can know for certain
-- about shooting, and both the shot counter and the recoil pass need exactly that.
local lastShotAt = -1e9

local function firing()
	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		return true
	end
	-- A raw screen touch is deliberately NOT counted as firing. On a touch client
	-- the camera is dragged with a finger, so "a finger is down" is true almost
	-- continuously: it would mis-count every spray AND starve the sensitivity
	-- calibration, which only samples while NOT firing. The script's own shots are
	-- the honest signal.
	if TOUCH and os.clock() - lastShotAt < 0.35 then return true end
	return false
end

-- Can this device produce that binding at all? A key it cannot press would leave
-- the feature off forever with nothing on screen to say why - which is exactly
-- what a phone got. An unreachable hotkey therefore falls back to holding the
-- screen, so an old saved config comes back working instead of dead.
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

--------------------------------------------------------------------------------
-- the weapon in hand
--------------------------------------------------------------------------------
--
-- ReplicatedStorage.Weapons holds one folder per weapon with the entire CS stat
-- block in it: DMG, FireRate, Spread, Penetration, ArmorPenetration, Ammo and
-- the literal CS:GO spray Pattern as a JSON string of {fMagnitude, fAngle} per
-- shot. Nothing here has to be guessed.
--
-- "Is this thing a gun" is answered from CONTENT, not from the name: a folder
-- with an Ammo above 1 and a FireRate shoots, everything else is a knife, a
-- grenade, the C4 or the defuse kit. Name matching would have to be maintained
-- for 67 entries and would break on the next knife skin.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WeaponsFolder = ReplicatedStorage:FindFirstChild("Weapons")

local weaponCache = {}

function weaponInfo()
	local char = plr.Character
	local nameValue = char and char:FindFirstChild("EquippedTool")
	local name = (nameValue and nameValue.Value) or ""
	if name == "" then return nil, "" end
	local cached = weaponCache[name]
	if cached ~= nil then return cached or nil, name end

	local folder = WeaponsFolder and WeaponsFolder:FindFirstChild(name)
	if not folder then weaponCache[name] = false return nil, name end

	local function num(child, fallback)
		local v = folder:FindFirstChild(child)
		return (v and tonumber(v.Value)) or fallback
	end
	local info = {
		name  = name,
		dmg   = num("DMG", 0),
		rate  = num("FireRate", 0.1),
		ammo  = num("Ammo", 0),
		spread = num("Spread", 0),
		pen   = num("Penetration", 0),
		apen  = num("ArmorPenetration", 0),
		range = num("Range", 0),
		auto  = tostring((folder:FindFirstChild("Auto") or {}).Value) == "true",
	}
	info.gun = info.ammo > 1 and info.rate > 0
	weaponCache[name] = info
	return info, name
end

local HEADPARTS = { Head = true, HeadHB = true, FakeHead = true }

-- The two "off while holding the wrong thing" gates, shared by aim and trigger.
local function gunGate(needGun)
	local info = weaponInfo()
	if not needGun then return true end
	return info ~= nil and info.gun
end

local function adsGate(mode)
	if mode == "Always" then return true end
	local char = plr.Character
	local ads = char and char:FindFirstChild("ADS")
	local on = ads ~= nil and ads.Value == true
	if mode == "Scoped only" then return on end
	return not on
end

local burstAt, lastKillAt = 0, 0

--------------------------------------------------------------------------------
-- humanisation
--------------------------------------------------------------------------------
--
-- Everything in this block takes a piece of "perfect" away from the aim, because
-- perfect is exactly what a machine looks like. Each knob removes one tell:
--
--   reaction    a human does not start turning on the frame the enemy appears
--   switch      ...and does not swap target between two frames either
--   ramp        the first part of a flick is slower than the middle of it
--   offset      nobody puts the crosshair on the same millimetre of a head twice;
--               re-rolled on a timer so it drifts during a hold
--   noise       the hand never stops moving, even on a still target
--   overshoot   a fast flick goes past and comes back
--   deadzone    once it is close enough, STOP - a permanently pixel-perfect
--               crosshair is the loudest tell there is
--   move FOV    a moving player tracks worse than a standing one
--   deg/s cap   the most important one. A smoothing divisor is a fraction of the
--               REMAINING angle, so at point blank the remaining angle is huge and
--               even a slow-looking divisor turns the camera faster than any hand
--   break       occasionally just let go for a moment
--   fatigue     the trigger gets slower deeper into a burst
--
-- The noise is a smooth random walk, not per-frame randomness: white noise on the
-- camera reads as a stutter, a walk reads as a hand.

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

-- A per-target aim offset in studs, re-rolled on a timer and scaled by the size of
-- the part being aimed at, so a head offset stays inside the head. HeadHB is the
-- hitbox the game grades headshots against, so an offset scaled to it cannot walk
-- the aim off the head.
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

local function aimWorldPoint(part, targetPlayer)
	return part.Position + aimOffset(part, targetPlayer)
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

local stickyTarget = nil
local lockedAt = 0        -- when the current target was picked, ms
local switchedAt = 0      -- when the last switch happened, ms
local reactUntil = 0
local breakUntil = 0

local function aimActive()
	if not CONFIG.aim then return false end
	-- The panel is a window the player is looking at, not the game. An assist that
	-- keeps tracking while somebody is clicking through settings is a giveaway on a
	-- recording and helps nobody.
	if CONFIG.hum and CONFIG.humPanelOff and STATE.panelOpen then return false end
	if CONFIG.aimActive == "Always" then return true end
	if CONFIG.aimActive == "Screen held" then return screenHeld() end
	if CONFIG.aimActive == "While firing" then
		-- On a touch client firing() only knows about shots the SCRIPT pulled, and
		-- the aim has to be running before it can pull one - so on a phone the mode
		-- means "while a finger is on the screen", which is when you are playing.
		return firing() or (TOUCH and screenHeld())
	end
	return hotkeyHeld(CONFIG.aimKey)
end

-- Which numbers apply right now. The first bullet of a burst uses the wide,
-- fast set; everything after it uses the tighter one, unless that split is
-- switched off.
local function aimNumbers()
	if CONFIG.aimSameAll or STATE.shots <= 1 then
		return CONFIG.aimFov, CONFIG.aimSmoothH, CONFIG.aimSmoothV
	end
	return CONFIG.aimFov2, CONFIG.aimSmoothH2, CONFIG.aimSmoothV2
end

local function targetPart(char)
	if CONFIG.aimPart == "Torso" then
		return char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart")
	end
	if CONFIG.aimPart == "Nearest" then
		-- whichever of head and chest currently sits closer to the crosshair
		local mid = centre()
		local best, bestD
		for _, n in ipairs({ "HeadHB", "Head", "UpperTorso", "HumanoidRootPart" }) do
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

-- Closest to the CROSSHAIR by default, not closest in the world: a target three
-- metres away but ninety degrees off is not the one being shot at.
local function pickTarget()
	local fov = select(1, aimNumbers())
	-- A player who is running tracks worse than one standing still, so the window
	-- they can acquire in narrows while they move.
	if CONFIG.hum and CONFIG.humMoveFov < 100 and movingNow() then
		fov = fov * (CONFIG.humMoveFov / 100)
	end
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

-- Frame-rate independent approach factor. `smooth` is a divisor: the step taken
-- in one 60 FPS frame is 1/smooth of the remaining angle, and at any other frame
-- rate the exponent puts it back on the same curve.
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

local function aimPass(dt)
	if _G.__CBLOX ~= GEN then return end
	aimWroteCamera = false

	STATE.engaged = false

	if not aimActive() or not gunGate(CONFIG.aimOnlyGun) or not adsGate(CONFIG.aimAds) then
		STATE.target = "-"
		STATE.waitMs = 0
		stickyTarget = nil
		return
	end
	local nowMs = os.clock() * 1000
	if nowMs - lastKillAt < CONFIG.aimKillMs then
		STATE.target = "-"
		return
	end

	local pick
	-- Sticky keeps the lock on one player instead of flicking to whoever is
	-- momentarily a pixel closer to the crosshair, which is what makes an
	-- unsticky aim look like a machine.
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
	-- A switch is allowed only after the cooldown. Without it, five enemies inside
	-- the FOV make the camera twitch between them every frame, which is not
	-- something a hand can do.
	if not pick then
		if CONFIG.hum and CONFIG.humSwitchMs > 0
			and stickyTarget ~= nil and nowMs - switchedAt < CONFIG.humSwitchMs then
			STATE.target = "-"
			return
		end
		pick = pickTarget()
		if pick and pick.player ~= stickyTarget then
			switchedAt = nowMs
			-- the reaction delay starts now, on the NEW target
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

	-- reaction delay ------------------------------------------------------------
	if reactUntil > nowMs then
		STATE.waitMs = math.floor(reactUntil - nowMs)
		return
	end
	STATE.waitMs = 0

	-- break-off -----------------------------------------------------------------
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

	-- Yaw and pitch are stepped SEPARATELY, which is the whole point of two
	-- sliders: a slow vertical with a fast horizontal tracks a strafing player
	-- without the give-away vertical snap onto the head.
	local dYaw   = angleDelta(curYaw, wantYaw)
	local dPitch = angleDelta(curPitch, wantPitch)

	-- deadzone: close enough is close enough. pick.px is already the pixel distance
	-- from the crosshair to the target part.
	if CONFIG.hum and CONFIG.humDeadPx > 0 and pick.px and pick.px <= CONFIG.humDeadPx then
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

	-- The degrees-per-second ceiling, applied to both axes together so a diagonal
	-- flick is capped at the same speed as a flat one.
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
-- The weapon folders carry the exact spray pattern, but a pattern is in
-- magnitude units, not degrees, and nothing says what one unit is worth on this
-- camera. So the pattern is not used to drive the correction at all - it is only
-- shown. What drives it is a measurement the client can make on its own:
--
--   * every frame, the camera's yaw/pitch change is compared against the raw
--     mouse movement reported by UserInputService for that same frame
--   * while NOT firing, the ratio of the two is the effective sensitivity, and
--     it is averaged continuously
--   * while firing, whatever change is left over after subtracting
--     sensitivity x mouse movement is not the player - it is the recoil
--
-- That residual is what gets cancelled, by the configured percentage. It needs
-- no calibration step, adapts if the player changes their sensitivity mid-game,
-- and it is visible live in the panel (the two numbers under RUECKSTOSS), so it
-- can be checked rather than believed.

local mouseDX, mouseDY = 0, 0
UserInputService.InputChanged:Connect(function(input)
	if _G.__CBLOX ~= GEN then return end
	local kind = input.UserInputType
	-- A touch client never sends MouseMovement; the camera drag arrives as Touch.
	-- Without this branch sensYaw stayed 0 on a phone and rcsPass returned at its
	-- `sensYaw == 0 and sp == 0` guard on every single frame.
	if kind == Enum.UserInputType.MouseMovement
		or (TOUCH and kind == Enum.UserInputType.Touch) then
		mouseDX = mouseDX + input.Delta.X
		mouseDY = mouseDY + input.Delta.Y
	end
end)

local lastYaw, lastPitch = nil, nil
local sensYaw, sensPitch = 0, 0
local sprayAt = 0

-- THE SPRAY CURVE, and it is the reason a measured-only correction can never pull
-- sideways: the residual carries the vertical kick cleanly and the horizontal half
-- is buried under the player's own aiming. The curve is where left and right come
-- from, and this game simply hands it over.
--
-- `Weapons.<name>.Pattern` is a JSON array of {fMagnitude, fAngle}, one entry per
-- bullet, POLAR and normalised so the largest magnitude is exactly 1. Decoded for
-- the AK47: 31 entries, straight up to shot 9, then out to x -0.14 by shot 8, back
-- across to +0.37 around 15, left again to -0.24 by 20 - the CS:GO table, exactly
-- as it reads in the game it is copied from.
--
-- Positions are CUMULATIVE, so the correction for one shot is the difference to
-- the entry before it, not the entry itself.
local HttpService = game:GetService("HttpService")
local sprayCache = {}

function sprayCurve(name)
	if not name or name == "" or not WeaponsFolder then return nil end
	local hit = sprayCache[name]
	if hit ~= nil then return hit or nil end

	local folder = WeaponsFolder:FindFirstChild(name)
	local value = folder and folder:FindFirstChild("Pattern")
	local raw = value and value.Value
	if type(raw) ~= "string" or raw == "" then
		sprayCache[name] = false
		return nil
	end
	local ok, list = pcall(function() return HttpService:JSONDecode(raw) end)
	if not ok or type(list) ~= "table" or #list < 2 then
		sprayCache[name] = false
		return nil
	end

	local curve = {}
	for i, entry in ipairs(list) do
		local m = tonumber(entry.fMagnitude) or 0
		local a = math.rad(tonumber(entry.fAngle) or 0)
		-- Screen convention: +y is UP, which is the direction the crosshair climbs.
		curve[i] = Vector2.new(m * math.cos(a), m * math.sin(a))
	end
	sprayCache[name] = curve
	return curve
end

local patLast, patShot = nil, 0
local patScale = 0

local function patternStep()
	local _, wname = weaponInfo()
	local curve = sprayCurve(wname)
	if not curve then
		patLast, patShot = nil, 0
		STATE.patLen = 0
		return nil
	end
	STATE.patLen = #curve
	local shot = math.max(1, STATE.shots)
	-- Past the end of the table the spray is flat, so the last entry is HELD rather
	-- than wrapping round to the start - wrapping would send the correction back to
	-- the top of the curve mid-magazine.
	local here = curve[math.min(shot, #curve)]

	local step = nil
	if patLast and shot > patShot then step = here - patLast end
	patLast, patShot = here, shot
	return step
end

local function rcsPass(dt)
	if _G.__CBLOX ~= GEN then return end
	local cf = camera.CFrame
	local pitch, yaw = cf:ToOrientation()
	local mx, my = mouseDX, mouseDY
	mouseDX, mouseDY = 0, 0

	if lastYaw == nil then lastYaw, lastPitch = yaw, pitch return end

	local dYaw = angleDelta(lastYaw, yaw)
	local dPitch = pitch - lastPitch
	lastYaw, lastPitch = yaw, pitch

	local shooting = firing()

	-- Calibration only runs on frames the script did not touch the camera itself,
	-- and only on real mouse movement - a still mouse divides by nothing.
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

	local step = patternStep()
	STATE.patY = step and step.X or 0
	STATE.patP = step and step.Y or 0

	if not shooting then
		STATE.kickY, STATE.kickP = 0, 0
		patLast = nil
		return
	end

	-- Vertical sensitivity is measured far less often than horizontal - people
	-- flick sideways constantly and up/down rarely - so an unmeasured pitch
	-- sensitivity has to fall back to the yaw one rather than to ZERO. With zero
	-- the residual was the player's entire vertical mouse movement, so the
	-- correction fought the user instead of the recoil, which is exactly what
	-- "it does something but it does not pull down" looks like.
	local sp = sensPitch
	if sp == 0 then sp = sensYaw end

	local resYaw   = dYaw   - (-sensYaw * mx)
	local resPitch = dPitch - (-sp      * my)
	STATE.kickY = math.deg(resYaw)
	STATE.kickP = math.deg(resPitch)
	-- Kept so a spray can be judged after the fact: if this stays near zero while
	-- firing, this game does not move the camera on recoil at all and no
	-- camera-side compensation can work.
	if math.abs(STATE.kickP) > math.abs(STATE.kickPeak) then
		STATE.kickPeak = STATE.kickP
	end

	-- Learn what ONE pattern unit is worth in camera radians, from frames the script
	-- did not move the camera itself. Only steps with a real vertical component are
	-- used: near the top of the curve the predicted step is almost zero and the
	-- ratio is then noise divided by noise.
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
		local scale = CONFIG.rcsPatAuto and patScale or (CONFIG.rcsPatScale * 0.0001)
		if scale ~= 0 then
			corrYaw   = corrYaw   - step.X * scale * (CONFIG.rcsYaw   / 100)
			corrPitch = corrPitch - step.Y * scale * (CONFIG.rcsPitch / 100)
		end
	end

	-- Both means both halves are pulling at the same kick, so each contributes half
	-- - otherwise the correction is twice what either mode alone would apply.
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
-- shot counting
--------------------------------------------------------------------------------
--
-- Both the first/other-bullet split and the recoil step need to know WHICH shot
-- of the spray this is. There is no ammo value anywhere on the client to read
-- (searched: Player, Player.Status, Additionals, the character, PlayerGui), so
-- it is counted from the trigger being down and the weapon's own FireRate, and
-- reset after a gap - the same reset a real spray gets.

local nextShotAt = 0

local function shotClock()
	local now = os.clock()
	-- On a touch client there is no held button to run the clock off, so the count
	-- is incremented by pullTrigger itself - the one place that knows a shot really
	-- happened. Here only the spray reset is left.
	if TOUCH then
		if now - sprayAt > 0.35 then STATE.shots = 0 end
		return
	end
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
			-- a semi-auto cannot spray by holding, so one press is one shot
			nextShotAt = now + math.max(rate, 0.25)
		end
	end
end

--------------------------------------------------------------------------------
-- trigger
--------------------------------------------------------------------------------
--
-- Fires the real mouse button (mouse1click / mouse1press+release), so the game's
-- own weapon code runs the shot exactly as it would for a human. No remote is
-- fired and no hit is fabricated - whatever the server checks, it sees a normal
-- shot from a client that happened to click at the right moment.

local trigParams = RaycastParams.new()
trigParams.FilterType = Enum.RaycastFilterType.Exclude
trigParams.IgnoreWater = true

local function refreshTrigFilter()
	local list = ignoreList()
	if plr.Character then table.insert(list, plr.Character) end
	trigParams.FilterDescendantsInstances = list
end

-- HOW a click is delivered differs per executor, and the mobile ones usually ship
-- none of the mouse1* helpers at all. That was silent: `click`, `press` and
-- `release` were all nil, pullTrigger fell out of the bottom of its if-chain
-- doing nothing, and the trigger card cheerfully counted "shots" that were never
-- fired. VirtualInputManager is the fallback that exists almost everywhere,
-- including on phones, and whichever one is in use is now NAMED in the panel so a
-- report says which executor could not fire rather than "it does nothing".
local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)
if VIM then
	local ok = pcall(function() return VIM.SendMouseButtonEvent end)
	if not ok then VIM = nil end
end

local click = mouse1click or (Input and Input.LeftClick)
local press, release = mouse1press, mouse1release

local function vimButton(down)
	if not VIM then return false end
	local vp = camera.ViewportSize
	return (pcall(function()
		VIM:SendMouseButtonEvent(math.floor(vp.X / 2), math.floor(vp.Y / 2),
			0, down, game, 0)
	end))
end

STATE.clickHow = (click and "mouse1click")
	or ((press and release) and "mouse1press")
	or (VIM and "VirtualInputManager")
	or "none"

local function pullTrigger()
	local hold = CONFIG.trigMode == "Hold"
	if hold and press and release then
		press()
		task.wait(CONFIG.trigHoldMs / 1000)
		release()
	elseif click then
		click()
	elseif press and release then
		press() task.wait(0.02) release()
	elseif VIM then
		vimButton(true)
		task.wait(hold and (CONFIG.trigHoldMs / 1000) or 0.02)
		vimButton(false)
	else
		return false
	end
	-- The only moment a touch client can be sure a shot went out, so this is what
	-- firing() and the spray counter run off there.
	lastShotAt = os.clock()
	if TOUCH then
		STATE.shots = STATE.shots + 1
		sprayAt = lastShotAt
	end
	return true
end

-- What is under the crosshair right now, as a player. A pixel FOV above zero
-- widens that from the single centre ray to a small ring of rays, which is what
-- makes a trigger usable on a moving target instead of only on a perfectly
-- stationary one.
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
	if CONFIG.trigActive == "Screen held" then return screenHeld() end
	return hotkeyHeld(CONFIG.trigKey)
end

task.spawn(function()
	local nextAt = 0
	local filterAt2 = 0
	while _G.__CBLOX == GEN do
		local ok, err = pcall(function()
			local nowSec = os.clock()
			if nowSec - filterAt2 > 1 then
				filterAt2 = nowSec
				refreshTrigFilter()
			end

			-- Evaluated even when the trigger is not armed, purely so the panel can
			-- SHOW what is under the crosshair. Without that line there is no way to
			-- tell "the key is not held" from "the ray never reaches the enemy", and
			-- both look identical: nothing happens.
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
			if not adsGate(CONFIG.trigAds) then return end
			if CONFIG.trigBurst > 0 and trigShots >= CONFIG.trigBurst then return end

			local now = os.clock() * 1000
			if now < nextAt then return end

			local target = seen
			if not target then return end

			if math.random(100) > CONFIG.trigHitPct then
				nextAt = now + CONFIG.trigRefireMs
				return
			end

			local lo = math.min(CONFIG.trigDelayMin, CONFIG.trigDelayMax)
			local hi = math.max(CONFIG.trigDelayMin, CONFIG.trigDelayMax)
			-- fatigue: every shot deeper into the burst is a little slower, the way a
			-- real finger is
			local tired = (CONFIG.hum and CONFIG.humFatigue > 0)
				and (trigShots * CONFIG.humFatigue) or 0
			if hi > 0 then task.wait((math.random(lo, hi) + tired) / 1000) end

			-- Re-check AFTER the reaction delay. Without this the trigger fires at
			-- where the enemy was 90 ms ago, which on a strafing player is a miss
			-- and a give-away in equal measure.
			if not underCrosshair() then return end

			-- Counted only when a click was actually delivered, so the number in the
			-- panel is shots FIRED and not shots attempted.
			if pullTrigger() then
				trigShots = trigShots + 1
				STATE.trigHits = STATE.trigHits + 1
			end
			nextAt = os.clock() * 1000 + CONFIG.trigRefireMs
		end)
		if not ok then note("trigger: " .. tostring(err)) end
		task.wait(0.01)
	end
end)

-- Auto fire for the aim assist, kept apart from the trigger so the two can run
-- at once without fighting over the mouse.
task.spawn(function()
	local nextAt = 0
	while _G.__CBLOX == GEN do
		local ok, err = pcall(function()
			if not (CONFIG.aim and CONFIG.aimFire) then return end
			if STATE.target == "-" then return end
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

-- A kill pauses the aim for aimKillMs, the same way the reference menu does it:
-- staying glued to a corpse and then flicking off it is the single most obvious
-- thing an aim assist can do.
task.spawn(function()
	local seen = {}
	while _G.__CBLOX == GEN do
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
-- the frame binding
--------------------------------------------------------------------------------
--
-- Two separate bindings on purpose. The ESP wants to run AFTER the camera has
-- settled for this frame or the boxes trail the view by one frame, which reads as
-- a wobble. The aim step has to run after the game's own camera code or it is
-- simply overwritten - Camera + 1 is late enough for both.

for _, name in ipairs({ "SeluxCBloxAim", "SeluxCBloxESP" }) do
	pcall(function() RunService:UnbindFromRenderStep(name) end)
end

RunService:BindToRenderStep("SeluxCBloxAim", Enum.RenderPriority.Camera.Value + 1,
	function(dt)
		if _G.__CBLOX ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxCBloxAim") end)
			return
		end
		-- Order matters: count the shot first so the first/other-bullet split and
		-- the recoil step are both looking at the same shot number, then aim, then
		-- cancel recoil - the recoil pass has to see whether aim moved the camera
		-- this frame or it would read its own correction as player input.
		local ok, err = pcall(function()
			shotClock()
			aimPass(dt)
			rcsPass(dt)
		end)
		if not ok then note("aim: " .. tostring(err)) end
	end)

RunService:BindToRenderStep("SeluxCBloxESP", Enum.RenderPriority.Camera.Value + 2,
	function()
		if _G.__CBLOX ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxCBloxESP") end)
			hideAll()
			return
		end
		local ok, err = pcall(renderPass)
		if not ok then note("esp: " .. tostring(err)) end
	end)

-- A player leaving takes their drawings with them, otherwise the last box they
-- were inside stays frozen on screen forever.
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
if _G.__CBLOX_WIN then pcall(function() _G.__CBLOX_WIN:Destroy() end) end
-- UI.sweep() instead of a literal: it pcalls every container, skips the ones the
-- executor refuses, and leaves no nil hole for ipairs to stop at. The `if` only
-- guards against an older cached copy of the template.
if UI.sweep then UI.sweep("CounterBloxPanel") end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("counterblox", CONFIG)

local win = UI.Window({
	name = "CounterBloxPanel",
	title = "COUNTER", accentTitle = "BLOX", subtitle = "seltonmt",
	badge = "◎", width = 920, height = 580,
})
_G.__CBLOX_WIN = win



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
	while _G.__CBLOX == GEN do
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



-- ESP ---------------------------------------------------------------------------

-- Every caption and hint in this panel is written in ENGLISH, and that is not a
-- style choice: UI.t() looks a string up by exactly the characters the script
-- passed, and tools/i18n/*.tsv is keyed in English. A German literal here is a
-- key that is in no dictionary, so it falls through unchanged in all three
-- languages and the flags in the header appear to do nothing at all. That is
-- what the first build of this panel did.
local espPage = win:Page("ESP", UI.icon.eye)

local drawCard = espPage:Card("DRAWING", 1):Accent()
drawCard:Toggle("Box", CONFIG.box, function(v) CONFIG.box = v end,
	"projected from head to feet, follows crouching", UI.theme.good)
drawCard:Toggle("Filled box", CONFIG.boxFilled, function(v) CONFIG.boxFilled = v end,
	"tinted area inside the box")
drawCard:Toggle("Name", CONFIG.name, function(v) CONFIG.name = v end)
drawCard:Toggle("Health bar", CONFIG.health, function(v) CONFIG.health = v end,
	"left of the box, green to red")
drawCard:Toggle("Health number", CONFIG.hpText, function(v) CONFIG.hpText = v end,
	"the bare number in the info line")
drawCard:Toggle("Weapon", CONFIG.weapon, function(v) CONFIG.weapon = v end,
	"a * behind it means that enemy is scoped in", UI.theme.good)
drawCard:Toggle("Distance", CONFIG.distance, function(v) CONFIG.distance = v end)
drawCard:Toggle("Head dot", CONFIG.headDot, function(v) CONFIG.headDot = v end,
	"sits on HeadHB, the hitbox the game grades headshots against")
drawCard:Toggle("Skeleton", CONFIG.skeleton, function(v) CONFIG.skeleton = v end,
	"R15 bone lines - busy with many enemies on screen")
drawCard:Toggle("Tracer", CONFIG.tracer, function(v) CONFIG.tracer = v end,
	"line from the bottom of the screen to the feet")

local modeCard = espPage:Card("RANGE", 2)
modeCard:Toggle("Wall check", CONFIG.visCheck, function(v) CONFIG.visCheck = v end,
	"enemies behind a wall are dimmed instead of drawn full", UI.theme.good)
modeCard:Toggle("Draw team mates", CONFIG.teamESP, function(v) CONFIG.teamESP = v end,
	"own team in blue and dimmed")
modeCard:Slider("Max distance", 100, 3000, CONFIG.maxDist, function(v)
	CONFIG.maxDist = v
end, "studs; nothing is drawn beyond this")
modeCard:Slider("Text size", 12, 26, CONFIG.textSize, function(v)
	CONFIG.textSize = v
end, "whole pixels; below 12 every Drawing face turns to mush")
modeCard:Dropdown("Font", FONTLIST, CONFIG.textFont, function(v) CONFIG.textFont = v end)
modeCard:Toggle("Text outline", CONFIG.textOutline, function(v)
	CONFIG.textOutline = v
end, "black edge behind the glyphs - readable on bright walls")
modeCard:Toggle("Shrink with distance", CONFIG.textShrink, function(v)
	CONFIG.textShrink = v
end, "off keeps every label the same size, which stays the most readable")

local colCard = espPage:Card("COLOURS", 1)
colCard:Colour("Enemies", CONFIG.colEnemy, function(c) CONFIG.colEnemy = c end,
	"behind a wall the same colour is drawn at 55% brightness")
colCard:Colour("Team mates", CONFIG.colMate, function(c) CONFIG.colMate = c end)
colCard:Colour("FOV circle", CONFIG.colFov, function(c) CONFIG.colFov = c end)

local chamCard = espPage:Card("CHAMS", 2)
chamCard:Toggle("Chams", CONFIG.chams, function(v)
	CONFIG.chams = v
	if not v then clearChams() end
end, "Highlight through walls; lives in CoreGui, not in the game tree",
	UI.theme.warn)
chamCard:Dropdown("Style", CHAM_LIST, CONFIG.chamStyle, function(v)
	CONFIG.chamStyle = v
end)
chamCard:Toggle("Rainbow", CONFIG.chamRainbow, function(v) CONFIG.chamRainbow = v end,
	"cycles the hue instead of using the team colour")
chamCard:Toggle("Colour by health", CONFIG.chamByHealth, function(v)
	CONFIG.chamByHealth = v
end, "green at full health, red near death")
chamCard:Toggle("Own cham colour", CONFIG.colChamOwn, function(v)
	CONFIG.colChamOwn = v
end, "on = use the colour below instead of the team colour")
chamCard:Colour("Cham colour", CONFIG.colCham, function(c) CONFIG.colCham = c end)

-- VISUALS -----------------------------------------------------------------------
--
-- Everything on this page is drawn over YOUR screen and touches nothing the server
-- can see. It is on its own page rather than under ESP because none of it is about
-- other players.

local visPage = win:Page("VISUALS", UI.icon.chart)

local crossCard = visPage:Card("CROSSHAIR", 1):Accent()
crossCard:Toggle("Static crosshair", CONFIG.crosshair, function(v)
	CONFIG.crosshair = v
end, "a fixed cross that does not open up with the game's own spread", UI.theme.good)
crossCard:Slider("Length", 2, 30, CONFIG.crossSize, function(v) CONFIG.crossSize = v end)
crossCard:Slider("Gap", 0, 20, CONFIG.crossGap, function(v) CONFIG.crossGap = v end)
crossCard:Slider("Thickness", 1, 5, CONFIG.crossThick, function(v) CONFIG.crossThick = v end)
crossCard:Toggle("Centre dot", CONFIG.crossDot, function(v) CONFIG.crossDot = v end)
crossCard:Colour("Colour", CONFIG.colCross, function(c) CONFIG.colCross = c end)

local sprayCard = visPage:Card("SPRAY & SCREEN", 2)
sprayCard:Toggle("Spray overlay", CONFIG.sprayDraw, function(v) CONFIG.sprayDraw = v end,
	"the weapon's own pattern out of the game, bright up to the shot you are on",
	UI.theme.good)
sprayCard:Slider("Overlay size", 30, 260, CONFIG.spraySize, function(v)
	CONFIG.spraySize = v
end, "pixels for the whole pattern")
sprayCard:Toggle("Bomb countdown", CONFIG.bombTimer, function(v) CONFIG.bombTimer = v end,
	"large timer once the C4 is armed - the real fuse, read from the round state")
sprayCard:Toggle("Field of view", CONFIG.fovChange, function(v)
	-- The render pass puts the old value back by itself; setting one here as well
	-- would be a second, different guess at what the game had.
	CONFIG.fovChange = v
end, "client side only - it changes what YOU see and nothing else", UI.theme.warn)
sprayCard:Slider("FOV", 60, 120, CONFIG.fovValue, function(v) CONFIG.fovValue = v end)

-- AIM ---------------------------------------------------------------------------

local aimPage = win:Page("AIM", UI.icon.target)

-- Key binding by RECORDING rather than by picking from a list. The button shows
-- the current binding; clicking it arms the recorder and the next key or mouse
-- button pressed becomes the binding. Escape cancels. The button's own caption
-- has to be written through the SxText attribute as well as the Text property,
-- or the next language switch walks the tree and puts the old caption back.
local TEXT_ATTR = "SxText"
local function setButton(button, text)
	pcall(function()
		button:SetAttribute(TEXT_ATTR, text)
		button.Text = UI.t(text)
	end)
end

-- Click the button, then press what you want - any key, or MOUSE 1/2/3.
local function bindButton(card, caption, get, set)
	local button
	local function paint()
		setButton(button, caption .. ": " .. keyDisplay(get()))
	end
	button = card:Button(caption .. ": " .. keyDisplay(get()), function()
		if capturing then return end
		-- Arming the recorder on a phone is a one-way door: it accepts Keyboard on
		-- InputBegan and MouseButton on InputEnded, and Escape is the only way out -
		-- none of which a touch client has. So it is not armed at all there.
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

local aimCard = aimPage:Card("ACTIVATION", 1):Accent()
aimCard:Toggle("Aim enabled", CONFIG.aim, function(v)
	CONFIG.aim = v
	note(v and "aim on" or "aim off")
end, "moves the CAMERA only - fires no remote and fakes no hit", UI.theme.warn)
aimCard:Dropdown("Trigger", { "Hotkey", "Always", "While firing", "Screen held" },
	CONFIG.aimActive, function(v) CONFIG.aimActive = v end)
bindButton(aimCard, "AIM KEY", function() return CONFIG.aimKey end,
	function(v) CONFIG.aimKey = v end)
if TOUCH then
	aimCard:Label("This device has no keyboard and no mouse - a hotkey it cannot "
		.. "press falls back to holding the screen, and Screen held does the same "
		.. "on purpose.")
end
aimCard:Dropdown("Aim at", { "Head", "Torso", "Nearest" }, CONFIG.aimPart,
	function(v) CONFIG.aimPart = v end)
aimCard:Dropdown("Pick target by", { "Crosshair", "Closest", "Lowest HP" },
	CONFIG.aimPick, function(v) CONFIG.aimPick = v end)
aimCard:Toggle("Sticky target", CONFIG.aimSticky, function(v)
	CONFIG.aimSticky = v
	stickyTarget = nil
end, "holds one enemy instead of flicking to whoever is a pixel closer",
	UI.theme.good)
aimCard:Toggle("Visible only", CONFIG.aimVisible, function(v) CONFIG.aimVisible = v end,
	"never aims at an enemy behind a wall", UI.theme.good)
aimCard:Toggle("Firearms only", CONFIG.aimOnlyGun, function(v)
	CONFIG.aimOnlyGun = v
end, "off for knife, grenade and C4 - detected from Ammo/FireRate, not the name")
aimCard:Dropdown("Scope condition", { "Always", "Scoped only", "Not scoped" },
	CONFIG.aimAds, function(v) CONFIG.aimAds = v end)
aimCard:Slider("Max distance", 50, 3000, CONFIG.aimMaxDist, function(v)
	CONFIG.aimMaxDist = v
end)

local shotCard = aimPage:Card("FIRST BULLET", 2)
shotCard:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov, function(v) CONFIG.aimFov = v end,
	"only enemies inside this circle around the crosshair")
shotCard:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH, function(v)
	CONFIG.aimSmoothH = v
end, "horizontal; 1 = instant, 50 = about a second, frame rate independent")
shotCard:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV, function(v)
	CONFIG.aimSmoothV = v
end, "vertical - slower than H takes the give-away snap off the head")

local sprayCard = aimPage:Card("OTHER BULLETS", 2)
sprayCard:Toggle("Use first bullet settings", CONFIG.aimSameAll, function(v)
	CONFIG.aimSameAll = v
end, "off = separate numbers for the rest of the magazine", UI.theme.good)
sprayCard:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov2, function(v) CONFIG.aimFov2 = v end)
sprayCard:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH2, function(v)
	CONFIG.aimSmoothH2 = v
end)
sprayCard:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV2, function(v)
	CONFIG.aimSmoothV2 = v
end)

local fireCard = aimPage:Card("AUTO FIRE & DELAYS", 1)
fireCard:Toggle("Auto fire", CONFIG.aimFire, function(v) CONFIG.aimFire = v end,
	"pulls the trigger itself once a target is held", UI.theme.warn)
fireCard:Slider("Hit chance %", 1, 100, CONFIG.aimHitPct, function(v)
	CONFIG.aimHitPct = v
end, "below 100 deliberately skips shots")
fireCard:Slider("Delay after kill (ms)", 0, 1000, CONFIG.aimKillMs, function(v)
	CONFIG.aimKillMs = v
end, "do not stay glued to a corpse - that is the most obvious tell there is")
fireCard:Slider("First bullet delay (ms)", 0, 1000, CONFIG.aimFirstMs, function(v)
	CONFIG.aimFirstMs = v
end)
fireCard:Toggle("Draw FOV", CONFIG.aimCircle, function(v) CONFIG.aimCircle = v end)
fireCard:Toggle("Draw second FOV", CONFIG.aimCircle2, function(v) CONFIG.aimCircle2 = v end)

local aimOut = aimPage:Card("TARGET", 1):Readout(4)

-- HUMANISE ----------------------------------------------------------------------

local humPage = win:Page("HUMANISE", UI.icon.shield)

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

local handCard = humPage:Card("HAND", 2)
handCard:Slider("Aim offset %", 0, 100, CONFIG.humOffset, function(v)
	CONFIG.humOffset = v
end, "of the target part's own size - nobody hits the same millimetre twice")
handCard:Slider("Offset re-roll (ms)", 100, 3000, CONFIG.humOffsetMs, function(v)
	CONFIG.humOffsetMs = v
end, "so the offset drifts during a long hold instead of standing still")
handCard:Slider("Noise (1/10 deg)", 0, 30, math.floor(CONFIG.humNoise * 10),
	function(v) CONFIG.humNoise = v / 10 end,
	"a smooth wander, not per-frame randomness - white noise reads as a stutter")
handCard:Slider("Noise speed (1/10 Hz)", 1, 60, math.floor(CONFIG.humNoiseHz * 10),
	function(v) CONFIG.humNoiseHz = v / 10 end)
handCard:Slider("Overshoot %", 0, 60, CONFIG.humOvershoot, function(v)
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

-- Three starting points, because forty sliders with no reference is not a feature.
-- Each writes the WHOLE set, so switching between them is reversible and nothing
-- is left standing from the previous choice.
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
		CONFIG.trigDelayMin, CONFIG.trigDelayMax = 40, 90
		CONFIG.trigHitPct = 100
	else -- Raw
		CONFIG.aimFov, CONFIG.aimSmoothH, CONFIG.aimSmoothV = 250, 3, 3
		CONFIG.aimSameAll = true
		CONFIG.aimPart, CONFIG.aimVisible, CONFIG.aimSticky = "Head", true, true
		CONFIG.hum = false
		-- Written even though `hum` is off, so the numbers on this page match what
		-- is actually configured. Leaving the previous preset's values standing made
		-- the readout claim a 260 deg/s cap while nothing was capped at all.
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

local humOut = humPage:Card("LIVE", 2):Readout(7)

-- TRIGGER -----------------------------------------------------------------------

local trigPage = win:Page("TRIGGER", UI.icon.bolt)

local trigCard = trigPage:Card("TRIGGERBOT", 1):Accent()
trigCard:Toggle("Trigger enabled", CONFIG.trig, function(v)
	CONFIG.trig = v
	note(v and "trigger on" or "trigger off")
end, "fires when an enemy is under the crosshair - a real mouse click",
	UI.theme.warn)
trigCard:Dropdown("Trigger", { "Hotkey", "Always", "Screen held" }, CONFIG.trigActive,
	function(v) CONFIG.trigActive = v end)
bindButton(trigCard, "TRIGGER KEY", function() return CONFIG.trigKey end,
	function(v) CONFIG.trigKey = v end)
if STATE.clickHow == "none" then
	trigCard:Label("This executor offers no way to click - neither mouse1click nor "
		.. "VirtualInputManager. Trigger and auto fire cannot fire here.")
end
trigCard:Dropdown("Fire mode", { "Click", "Hold" }, CONFIG.trigMode,
	function(v) CONFIG.trigMode = v end)
trigCard:Slider("Hold time (ms)", 20, 600, CONFIG.trigHoldMs, function(v)
	CONFIG.trigHoldMs = v
end, "Hold mode only - for full auto weapons")
trigCard:Toggle("Head only", CONFIG.trigHeadOnly, function(v)
	CONFIG.trigHeadOnly = v
end, "fires only when the ray lands on HeadHB or Head")
trigCard:Toggle("Firearms only", CONFIG.trigOnlyGun, function(v)
	CONFIG.trigOnlyGun = v
end)
trigCard:Dropdown("Scope condition", { "Always", "Scoped only", "Not scoped" },
	CONFIG.trigAds, function(v) CONFIG.trigAds = v end)

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

local trigOut = trigPage:Card("STATUS", 1):Readout(5)

-- RECOIL ------------------------------------------------------------------------

local rcsPage = win:Page("RECOIL", UI.icon.wave)

local rcsCard = rcsPage:Card("RECOIL CONTROL", 1):Accent()
rcsCard:Toggle("RCS enabled", CONFIG.rcs, function(v)
	CONFIG.rcs = v
	note(v and "rcs on" or "rcs off")
end, "measures itself against your own mouse - no calibration step", UI.theme.warn)
rcsCard:Dropdown("Source", { "Both", "Measured", "Pattern" }, CONFIG.rcsMode,
	function(v) CONFIG.rcsMode = v end)
rcsCard:Label("Measured carries the vertical kick and almost none of the sideways "
	.. "one - your own aiming drowns it. Pattern is the weapon's real CS spray "
	.. "table out of the game, which is where left and right come from.")
rcsCard:Slider("Pitch %", 0, 100, CONFIG.rcsPitch, function(v) CONFIG.rcsPitch = v end,
	"share of the vertical kick that is taken back out")
rcsCard:Slider("Yaw %", 0, 100, CONFIG.rcsYaw, function(v) CONFIG.rcsYaw = v end)
rcsCard:Slider("Start at shot", 1, 10, CONFIG.rcsAfter, function(v) CONFIG.rcsAfter = v end,
	"the first bullet has no recoil, so there is nothing to cancel")
rcsCard:Slider("Max correction (deg)", 1, 15, CONFIG.rcsMaxDeg, function(v)
	CONFIG.rcsMaxDeg = v
end, "hard per-frame cap so the correction cannot oscillate")

local patCard = rcsPage:Card("SPRAY PATTERN", 1)
patCard:Toggle("Learn the scale", CONFIG.rcsPatAuto, function(v)
	CONFIG.rcsPatAuto = v
end, "works out what one pattern unit is worth in camera degrees while you spray",
	UI.theme.good)
patCard:Slider("Scale by hand", 1, 400, CONFIG.rcsPatScale, function(v)
	CONFIG.rcsPatScale = v
end, "hundredths, only used with Learn off - the readout shows what it learned")

local rcsOut = rcsPage:Card("MEASUREMENT", 2):Readout(9)
local wpnOut = rcsPage:Card("WEAPON", 2):Readout(6)

-- INFO --------------------------------------------------------------------------

local infoPage = win:Page("ROUND", UI.icon.list)
local roundOut = infoPage:Card("ROUND", 0):Readout(4, function(text)
	if text:find("BOMB ARMED") then return UI.theme.bad end
	return nil
end)
local listOut = infoPage:Card("PLAYERS", 0):Readout(13, function(text)
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

task.spawn(function()
	while _G.__CBLOX == GEN do
		local ok, err = pcall(function()
			STATE.map    = tostring(statusValue("MapName", "-"))
			STATE.timer  = tonumber(statusValue("Timer", 0)) or 0
			STATE.ctWins = tonumber(statusValue("CTWins", 0)) or 0
			STATE.tWins  = tonumber(statusValue("TWins", 0)) or 0
			STATE.bomb   = tostring(statusValue("HasBomb", "-"))
			STATE.armed  = statusValue("Armed", false) == true
				or tostring(statusValue("Armed", "false")) == "true"

			local aliveCT, aliveT = 0, 0
			local rows = {}
			local camPos = camera.CFrame.Position

			for _, p in ipairs(Players:GetPlayers()) do
				local char, hum, root = alive(p)
				local teamName = p.Team and p.Team.Name or ""
				local tag = teamName:sub(1, 1) == "C" and "CT" or "T "
				if char then
					if tag == "CT" then aliveCT = aliveCT + 1 else aliveT = aliveT + 1 end
				end
				local tool = char and char:FindFirstChild("EquippedTool")
				local cash = p:FindFirstChild("Cash")
				local dist = root and math.floor((camPos - root.Position).Magnitude) or nil
				table.insert(rows, {
					enemy = isEnemy(p),
					alive = char ~= nil,
					line = string.format(" %-2s %-16s %-5s %-6s %-5s $%s",
						tag,
						p.Name:sub(1, 16),
						char and (math.floor(hum.Health) .. "hp") or "TOT",
						(tool and tool.Value ~= "" and tool.Value:sub(1, 6)) or "-",
						dist and (dist .. "m") or "-",
						short(cash and cash.Value or 0)),
				})
			end

			-- Enemies first, then alive before dead: the two things that are looked
			-- at mid-round are "who is left" and "what are they holding".
			table.sort(rows, function(a, b)
				if a.enemy ~= b.enemy then return a.enemy end
				if a.alive ~= b.alive then return a.alive end
				return a.line < b.line
			end)

			STATE.alive.ct, STATE.alive.t = aliveCT, aliveT

			local lines = { " TE NAME             HP    WEAPON DIST  CASH" }
			for i = 1, math.min(#rows, 12) do table.insert(lines, rows[i].line) end
			pcall(function() listOut:set(lines) end)

			pcall(function()
				roundOut:set({
					string.format("  %s    CT %d : %d T    %ds left",
						STATE.map, STATE.ctWins, STATE.tWins, STATE.timer),
					STATE.armed and "  BOMB ARMED"
						or ("  bomb carried by: " .. STATE.bomb),
					string.format("  alive   CT %d   T %d      drawn %d",
						STATE.alive.ct, STATE.alive.t, STATE.targets),
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
					"  active   " .. (CONFIG.aim and CONFIG.aimActive or "off")
						.. (CONFIG.aimActive == "Hotkey"
							and ("  " .. (reachable(CONFIG.aimKey)
								and keyDisplay(CONFIG.aimKey) or "screen")) or ""),
					string.format("  now      FOV %dpx   H %d   V %d", fov, sh, sv),
					"  weapon   " .. STATE.weapon
						.. (info and (info.gun and "  (firearm)" or "  (no shots)") or ""),
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
					"  now      " .. (STATE.breaking and "broken off"
						or (STATE.waitMs > 0 and ("reacting, " .. STATE.waitMs .. "ms")
							or (STATE.engaged and "tracking" or "idle"))),
					"  panic key " .. keyDisplay(CONFIG.humPanicKey)
						.. (STATE.panelOpen and "   (panel open)" or ""),
				})
			end)

			pcall(function()
				trigOut:set({
					"  state    " .. (CONFIG.trig
						and (STATE.trigOn and "armed"
							or ("waiting for " .. (reachable(CONFIG.trigKey)
								and keyDisplay(CONFIG.trigKey) or "a finger on the screen")))
						or "off"),
					"  crosshair " .. tostring(STATE.underCross),
					-- Named because a trigger that never fires looks identical to one
					-- that is never armed, and on a phone it was always the former.
					"  click    " .. tostring(STATE.clickHow),
					string.format("  shots    %d   reaction %d-%dms",
						STATE.trigHits, CONFIG.trigDelayMin, CONFIG.trigDelayMax),
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
					string.format("  kick V   %.2f deg", STATE.kickP),
					"  PATTERN   " .. (STATE.patLen > 0
						and (STATE.patLen .. " shots from the game")
						or "no curve for this weapon"),
					string.format("  step     H %+.3f   V %+.3f", STATE.patY, STATE.patP),
					string.format("  scale    %.5f   (%d samples)",
						STATE.patScale, STATE.patN),
					"  " .. (CONFIG.rcs
						and (CONFIG.rcsMode .. "  " .. ((STATE.calibN > 0) and "active"
							or (TOUCH and "waiting for camera movement"
								or "waiting for mouse movement")))
						or "off"),
				})
			end)

			pcall(function()
				if not info then
					wpnOut:set({ "  WEAPON", "  " .. STATE.weapon,
						"  no entry in ReplicatedStorage.Weapons" })
				else
					wpnOut:set({
						"  WEAPON",
						"  " .. info.name .. (info.auto and "   full auto" or "   semi auto"),
						string.format("  damage   %d   armour pen %d%%", info.dmg, info.apen),
						string.format("  rate     %.2fs   magazine %d", info.rate, info.ammo),
						string.format("  spread   %.2f   penetration %d", info.spread, info.pen),
						string.format("  range    %d", info.range),
					})
				end
			end)

			pcall(function()
				win:SetStat(1, tostring(STATE.ctWins) .. ":" .. tostring(STATE.tWins), "rounds")
				win:SetStat(2, tostring(STATE.alive.ct) .. "v" .. tostring(STATE.alive.t), "alive")
				win:SetStat(3, tostring(STATE.targets), "drawn")
				-- The strip title used to be the master switch's caption. With the
				-- switch gone it carries what the script is actually doing.
				win:SetNote(STATE.note ~= "" and STATE.note or "Ready")
				win:SetStatus(string.format("%s   %ds   %s",
					STATE.map, STATE.timer,
					STATE.armed and "BOMB ARMED" or ("bomb: " .. STATE.bomb)))
			end)
		end)
		if not ok then note("ui: " .. tostring(err)) end
		task.wait(0.4)
	end
end)

-- Is the panel on screen? The safety toggle needs to know, and the template shows
-- and hides the WINDOW FRAME (`window.root.Visible`) rather than the ScreenGui -
-- RightShift flips exactly that one property. Reading `gui.Enabled` instead would
-- be true the whole time and the pause would never fire.
task.spawn(function()
	while _G.__CBLOX == GEN do
		pcall(function()
			local root = win and win.root
			STATE.panelOpen = (root ~= nil) and root.Visible == true
		end)
		task.wait(0.25)
	end
end)

-- The camera reference is replaced on every respawn, so a cached one silently
-- stops updating after the first death - which looked exactly like "the ESP broke
-- after I died".
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then camera = workspace.CurrentCamera end
end)

pcall(function() win:Home() end)
win:Refresh()

--------------------------------------------------------------------------------

_G.__CBLOX_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	alive = alive, isEnemy = isEnemy, visible = visible, aimPoint = aimPoint,
	pickTarget = pickTarget, renderPass = renderPass, aimPass = aimPass,
	rcsPass = rcsPass, shotClock = shotClock, aimNumbers = aimNumbers,
	targetPart = targetPart, underCrosshair = underCrosshair, pullTrigger = pullTrigger,
	weaponInfo = weaponInfo, gunGate = gunGate, adsGate = adsGate, keyHeld = keyHeld,
	approach = approach, angleDelta = angleDelta, firing = firing,
	statusValue = statusValue, drawn = drawn, highlights = highlights,
	hideAll = hideAll, clearChams = clearChams, note = note,
	TOUCH = TOUCH, screenHeld = screenHeld, reachable = reachable,
	hotkeyHeld = hotkeyHeld, aimActive = aimActive, trigActive = trigActive,
	sprayCurve = sprayCurve, patternStep = patternStep,
	noiseStep = noiseStep, aimOffset = aimOffset, aimWorldPoint = aimWorldPoint,
	movingNow = movingNow, preset = preset, drawCrosshair = drawCrosshair,
	drawSpray = drawSpray,
}

if TOUCH then
	note("phone: hotkeys hold the screen instead")
elseif STATE.clickHow == "none" then
	note("this executor cannot click - trigger and auto fire are off")
end

print("[counterblox] gen " .. GEN .. " ready - RightShift for the panel"
	.. (TOUCH and "  (touch client, click: " .. STATE.clickHow .. ")" or ""))
