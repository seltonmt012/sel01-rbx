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
local CoreGui           = game:GetService("CoreGui")

local plr    = Players.LocalPlayer
local camera = workspace.CurrentCamera

local GEN = (_G.__CBLOX or 0) + 1
_G.__CBLOX = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	esp        = true,     -- master switch for everything drawn in the world
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
	rcsPitch   = 70,       -- percent of the measured vertical kick to cancel
	rcsYaw     = 70,
	rcsAfter   = 1,        -- start compensating from this shot on
	rcsMaxDeg  = 4,        -- hard cap per frame, degrees
}

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
	underCross = "-",
	lastKey   = "-",
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

local hlRoot = (gethui and gethui()) or CoreGui
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

local function centre()
	local vp = camera.ViewportSize
	return Vector2.new(vp.X / 2, vp.Y / 2)
end

local filterAt = 0

local function renderPass()
	if _G.__CBLOX ~= GEN then return end

	local mid = centre()
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

	if not CONFIG.esp then
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

local function firing()
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
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

local function weaponInfo()
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

--------------------------------------------------------------------------------
-- aim assist
--------------------------------------------------------------------------------

local burstAt, lastKillAt = 0, 0
local stickyTarget = nil

local function aimActive()
	if not CONFIG.aim then return false end
	if CONFIG.aimActive == "Always" then return true end
	if CONFIG.aimActive == "While firing" then return firing() end
	return keyHeld(CONFIG.aimKey)
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

	if not aimActive() or not gunGate(CONFIG.aimOnlyGun) or not adsGate(CONFIG.aimAds) then
		STATE.target = "-"
		stickyTarget = nil
		return
	end
	if os.clock() * 1000 - lastKillAt < CONFIG.aimKillMs then
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
	pick = pick or pickTarget()

	if not pick or not pick.part or not pick.part.Parent then
		STATE.target = "-"
		stickyTarget = nil
		return
	end
	stickyTarget = pick.player
	STATE.target = pick.player.Name

	local _, smoothH, smoothV = aimNumbers()
	local cf = camera.CFrame
	local pos = cf.Position
	local curPitch, curYaw = cf:ToOrientation()
	local want = CFrame.lookAt(pos, pick.part.Position)
	local wantPitch, wantYaw = want:ToOrientation()

	-- Yaw and pitch are stepped SEPARATELY, which is the whole point of two
	-- sliders: a slow vertical with a fast horizontal tracks a strafing player
	-- without the give-away vertical snap onto the head.
	local newYaw   = curYaw   + angleDelta(curYaw, wantYaw)     * approach(smoothH, dt)
	local newPitch = curPitch + angleDelta(curPitch, wantPitch) * approach(smoothV, dt)

	camera.CFrame = CFrame.new(pos) * CFrame.fromOrientation(newPitch, newYaw, 0)
	aimWroteCamera = true
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
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		mouseDX = mouseDX + input.Delta.X
		mouseDY = mouseDY + input.Delta.Y
	end
end)

local lastYaw, lastPitch = nil, nil
local sensYaw, sensPitch = 0, 0
local sprayAt = 0

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

	if not shooting then
		STATE.kickY, STATE.kickP = 0, 0
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
-- Both the first/other-bullet split and the recoil step need to know WHICH shot
-- of the spray this is. There is no ammo value anywhere on the client to read
-- (searched: Player, Player.Status, Additionals, the character, PlayerGui), so
-- it is counted from the trigger being down and the weapon's own FireRate, and
-- reset after a gap - the same reset a real spray gets.

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
	if CONFIG.trigActive == "Always" then return true end
	return keyHeld(CONFIG.trigKey)
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
			if hi > 0 then task.wait(math.random(lo, hi) / 1000) end

			-- Re-check AFTER the reaction delay. Without this the trigger fires at
			-- where the enemy was 90 ms ago, which on a strafing player is a miss
			-- and a give-away in equal measure.
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
for _, root in ipairs({ (gethui and gethui()) or nil, CoreGui }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "CounterBloxPanel" then pcall(function() g:Destroy() end) end
		end
	end
end

local win = UI.Window({
	name = "CounterBloxPanel",
	title = "COUNTER", accentTitle = "BLOX", subtitle = "seltonmt",
	badge = "◎", width = 920, height = 580,
})
_G.__CBLOX_WIN = win

win:SetMaster(CONFIG.esp, "ESP running")
win:OnMaster(function(on)
	CONFIG.esp = on
	note(on and "ESP an" or "ESP aus")
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

-- TRIGGER -----------------------------------------------------------------------

local trigPage = win:Page("TRIGGER", UI.icon.bolt)

local trigCard = trigPage:Card("TRIGGERBOT", 1):Accent()
trigCard:Toggle("Trigger enabled", CONFIG.trig, function(v)
	CONFIG.trig = v
	note(v and "trigger on" or "trigger off")
end, "fires when an enemy is under the crosshair - a real mouse click",
	UI.theme.warn)
trigCard:Dropdown("Trigger", { "Hotkey", "Always" }, CONFIG.trigActive,
	function(v) CONFIG.trigActive = v end)
bindButton(trigCard, "TRIGGER KEY", function() return CONFIG.trigKey end,
	function(v) CONFIG.trigKey = v end)
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

local trigOut = trigPage:Card("STATUS", 1):Readout(4)

-- RECOIL ------------------------------------------------------------------------

local rcsPage = win:Page("RECOIL", UI.icon.wave)

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
							and ("  " .. keyDisplay(CONFIG.aimKey)) or ""),
					string.format("  now      FOV %dpx   H %d   V %d", fov, sh, sv),
					"  weapon   " .. STATE.weapon
						.. (info and (info.gun and "  (firearm)" or "  (no shots)") or ""),
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
				})
			end)

			pcall(function()
				rcsOut:set({
					"  MEASUREMENT",
					string.format("  sens H   %.5f   V %.5f", STATE.sensY, STATE.sensP),
					string.format("  samples  %d", STATE.calibN),
					string.format("  kick H   %.2f deg", STATE.kickY),
					string.format("  kick V   %.2f deg", STATE.kickP),
					"  " .. (CONFIG.rcs
						and ((STATE.calibN > 0) and "active" or "waiting for mouse movement")
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
				win:SetStatus(string.format("%s   %ds   %s",
					STATE.map, STATE.timer,
					STATE.armed and "BOMB ARMED" or ("bomb: " .. STATE.bomb)))
			end)
		end)
		if not ok then note("ui: " .. tostring(err)) end
		task.wait(0.4)
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
}

print("[counterblox] gen " .. GEN .. " ready - RightShift for the panel")
