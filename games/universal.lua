--[[ universal.lua - the fallback for a shooter this hub does not know

  Loaded by hub/loader.lua when nothing in index.json matches the place. It is
  deliberately the SMALLEST thing that still works everywhere:

    * ESP drawn with the Drawing library
    * a camera-side aim assist with TWO delivery paths and runtime detection of
      which one this game accepts

  Neither needs a remote, a module or any reverse engineering. They read
  Instances and they move the view, and that part of Roblox is the same in every
  shooter. Everything that needs per-game knowledge - firing, recoil patterns,
  silent aim, NPC enemies, round state - is deliberately NOT here, because a
  universal version of it would be a universal lie.

  ============================================================================
  WHAT "SAFE" MEANS HERE, because the two halves are not comparable
  ============================================================================

  ESP is genuinely unseeable. Drawing objects live in the executor's overlay and
  never enter the DataModel, so there is no Instance for a client script to find
  with one GetDescendants() call, nothing replicates and the server is never
  contacted. That is why this file contains no Highlight, no BillboardGui and no
  recoloured parts - a Highlight you create IS findable, and repainting real
  parts is visible to other players in some games.

  The aim assist cannot be hidden by any client-side trick, and pretending
  otherwise would be the dangerous lie. A shooter that records view angles
  server-side - BloxStrike does it at 128 Hz - holds a replayable recording of
  where the crosshair was, tick by tick. A snap onto a head, a superhuman turn
  rate or tracking through a wall is computable after the fact no matter what
  the client does. So the assist's safety is ENTIRELY the shape of its motion:
  the reaction delay, the wind-up, the degrees-per-second ceiling, the deadzone
  and the wander. Those defaults are the safety feature; the presets exist so
  they are not forty unlabelled sliders.

  For the same reason the default delivery is the MOUSE where the game accepts
  it: `mousemoverel` goes through the real input path, so the game's own camera
  controller authors the movement. A CFrame write is a camera teleport that the
  controller did not author.

  ============================================================================
  THE FOUR THINGS THIS FILE EXISTS TO SURVIVE, each measured in a real game
  ============================================================================

  1. TEAMS THAT ARE PRESENT BUT EMPTY. "DoW: WWII - Mobile 2" has Allies and
     Axis in Teams, zero players in either and the local player Neutral; a plain
     `p.Team ~= plr.Team` marks nobody and the script sits silent in exactly the
     game it was written for. BloxStrike is the other shape: Teams is empty and
     the team is an ATTRIBUTE. teamsLookReal() decides whether the field can be
     believed at all and otherwise treats everyone as a target.

  2. RIGS THAT ARE NOT R15, AND HITBOXES THAT ARE NOT THE HEAD. R6 has Torso and
     no UpperTorso. Plenty of games ship their own aim hitboxes - DoW carries
     AutoAimAreaHead / AutoAimAreaBody, which are BETTER targets than the visible
     head because they are what the game itself shoots at. Counter Blox has
     HeadHB for the same reason. resolveParts() looks for those first.

  3. A BOX FROM Model:GetBoundingBox() THAT IS NONSENSE. Measured in Counter
     Blox: 30 x 77 x 32 studs for a character whose real extent is 2.3 x 6.5 x
     2.5 - boxes covering half the screen that barely shrink with distance.
     Measured in DoW the same call is almost exact (5.0 x 7.0 x 5.5 against
     5.0 x 7.0 x 5.0). So it is not always wrong, it is UNRELIABLE, and when it
     is wrong it is wrong by a factor of ten. The head-to-foot projection is
     used wherever the parts exist and the bounding box is only a sanity-checked
     last resort for a rig nothing else recognises.

  4. A CAMERA THE GAME FIGHTS FOR. BloxStrike rebuilds camera.CFrame every frame
     from angles it keeps itself: the write is thrown away on the next frame,
     measured at ~220 px of error across 2183 frames that never once converged,
     and it reads to the user as "it shakes and gets worse the further off I am".
     DoW, measured with the same probe, keeps 395 of 478 writes inside 0.1 deg.
     Both are normal. So the script PROBES instead of assuming, and switches to
     the mouse path when the camera path is being overwritten.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Teams             = game:GetService("Teams")

local plr    = Players.LocalPlayer
local camera = workspace.CurrentCamera

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then camera = workspace.CurrentCamera end
end)

--------------------------------------------------------------------------------
-- generation guard
--------------------------------------------------------------------------------
--
-- Re-executing does not restart the Lua VM, so every loop and render bind has to
-- be able to tell "I am the current run" from "I am last run's ghost".

_G.__SELUNI = (_G.__SELUNI or 0) + 1
local GEN = _G.__SELUNI

--------------------------------------------------------------------------------
-- executor capabilities, resolved once
--------------------------------------------------------------------------------

local HAS_DRAWING = (Drawing ~= nil and Drawing.new ~= nil)
local moveMouse = rawget(getfenv(), "mousemoverel")
if type(moveMouse) ~= "function" then moveMouse = nil end

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	-- who counts as a target -----------------------------------------------------
	-- Auto runs the whole chain and takes the first link that holds up. The named
	-- values force one link and skip the sanity gates, for when the CHECK page
	-- shows the right answer being rejected.
	teamMode   = "Auto",      -- Auto | Player.Team | Team attribute | TeamColor | Nameplate | Off
	teamInvert = false,       -- the chain found the split but picked the wrong side
	maxDist    = 2000,

	-- esp ------------------------------------------------------------------------
	esp        = true,
	espBox     = true,
	espBoxFill = false,
	espName    = true,
	espInfo    = true,        -- distance and health under the box
	espHealth  = true,        -- the bar beside it
	espTracer  = false,
	espHeadDot = false,
	espVisOnly = false,
	espDimHidden = true,
	espTextSize = 13,
	espFont    = 1,           -- 1 = the OS face, the only one hinted for small sizes

	-- aim assist -----------------------------------------------------------------
	aim        = false,       -- OFF by default. ESP is information, this is input.
	aimActive  = "Hotkey",
	aimKey     = "MouseButton2",
	aimPart    = "Head",
	aimPick    = "Crosshair",
	aimDeliver = "Auto",      -- Auto | Mouse | Camera
	aimFov     = 110,
	aimSmoothH = 24,
	aimSmoothV = 28,
	aimSticky  = true,
	aimVisible = true,
	aimMaxDist = 1500,
	aimCircle  = true,

	-- humanisation - THIS is the safety, see the header ---------------------------
	hum        = true,
	humReactMin = 90,
	humReactMax = 190,
	humRampMs  = 220,
	humNoise   = 0.4,
	humNoiseHz = 1.6,
	humDeadPx  = 3,
	humMaxDegS = 360,
	humPanelOff = true,
	panicKey   = "F1",

	-- colours --------------------------------------------------------------------
	colEnemy   = Color3.fromRGB(255, 86, 86),
	colVisible = Color3.fromRGB(120, 235, 140),
	colText    = Color3.fromRGB(240, 240, 240),
	colFov     = Color3.fromRGB(255, 255, 255),
}

-- Written as whole sets so the sliders have a reference point. Forty numbers with
-- no starting position is not a feature.
local PRESETS = {
	Legit = { aimSmoothH = 34, aimSmoothV = 40, aimFov = 70, humReactMin = 140,
		humReactMax = 260, humRampMs = 300, humNoise = 0.5, humDeadPx = 5,
		humMaxDegS = 200, hum = true },
	Normal = { aimSmoothH = 24, aimSmoothV = 28, aimFov = 110, humReactMin = 90,
		humReactMax = 190, humRampMs = 220, humNoise = 0.4, humDeadPx = 3,
		humMaxDegS = 360, hum = true },
	Raw = { aimSmoothH = 8, aimSmoothV = 9, aimFov = 200, humReactMin = 0,
		humReactMax = 0, humRampMs = 0, humNoise = 0, humDeadPx = 0,
		humMaxDegS = 1200, hum = false },
}

local STATE = {
	targets   = 0,
	teamsReal = false,
	teamNote  = "-",
	chain     = {},       -- one line per method: what it found and why it was kept
	                      -- or dropped. The CHECK page prints it verbatim.
	target    = "-",
	engaged   = false,
	waitMs    = 0,
	aimErr    = 0,
	deliver   = "-",      -- which path is actually being used right now
	stickPct  = -1,       -- how much of a camera write survives to the next frame
	mouseSens = 0,
	rigNote   = "-",
	panelOpen = false,
	note      = "",
}

local function note(s) STATE.note = tostring(s) end

--------------------------------------------------------------------------------
-- who is a target
--------------------------------------------------------------------------------
--
-- The team field is only worth reading when the game is using it. Two teams each
-- holding a player, and us in one of them, is the cheapest test that is true in a
-- real team shooter and false in every broken shape seen so far: teams declared
-- but unused, everyone Neutral, or a free-for-all.

local function quantise(c)
	return math.floor(c.R * 8 + 0.5) .. "/" .. math.floor(c.G * 8 + 0.5)
		.. "/" .. math.floor(c.B * 8 + 0.5)
end

-- When the Player object gives nothing away, the game usually still does: it
-- COLOURS ITS OWN NAMEPLATES, because the human at the keyboard has to tell
-- friend from foe too. Measured in DoW, where Teams holds Allies and Axis with
-- zero players in either and every TeamColor reads White:
--
--     sonyvi      nameplate 1, 1, 1      -> teammate
--     Willi_ms0   nameplate 1, 0.2, 0.2  -> enemy
--
-- The label is found by its TEXT matching the player's name, and that is what
-- makes this general rather than a DoW special case: every character in that
-- game ALSO carries an unfilled template label reading "Player Name" in a third
-- colour, so a "take the first TextLabel" rule would have read the same value on
-- everybody and looked like a working split.
--
-- (Those characters also carry a Highlight called `EnemyHighlight`, which looks
-- like the whole answer. It is not: every player has one, and the only one
-- ENABLED was the local player's own. Checked before it was trusted.)
local function nameplateColour(p, char)
	for _, d in ipairs(char:GetChildren()) do
		if d:IsA("BillboardGui") then
			for _, l in ipairs(d:GetDescendants()) do
				if l:IsA("TextLabel")
					and (l.Text == p.Name or (p.DisplayName ~= "" and l.Text == p.DisplayName)) then
					return l.TextColor3
				end
			end
		end
	end
	return nil
end

-- Red is the enemy in practically every shooter ever shipped. "Practically
-- every" is not "every", which is what the invert toggle is for.
local function reddness(c) return c.R - math.max(c.G, c.B) end

--------------------------------------------------------------------------------
-- team detection is a CHAIN, and every link has to justify itself
--------------------------------------------------------------------------------
--
-- No two of these games agree on where the team lives, so there is no single
-- right accessor to choose - there is only a list of the places it has been
-- found, tried in order of how trustworthy each is WHEN IT WORKS. The point is
-- that a link is never used merely because it returned something. It is used
-- only if what it returned makes sense, and otherwise the next one is tried.
--
-- "Makes sense" is three tests and a link has to pass all three:
--
--   SPLIT     it puts the other players into at least two different sides. A
--             method that answers the same thing for everybody has not found a
--             team, it has found nothing - which is exactly what TeamColor does
--             in DoW, where it reads White for all fifteen players.
--   COVERAGE  it answers for more than half the live players. One lucky hit
--             among eleven blanks is noise wearing a result's clothes.
--   ANCHOR    it can say which side is MINE - either because it answers for me
--             too, or because the method knows on its own which side is hostile.
--             The nameplate method is the only one that does, by colour.
--
-- The chain is re-run every 1.5s rather than settled once, because a round change
-- reassigns teams: a method that is useless in the lobby starts working the
-- moment the match begins, and one that worked last round can stop.

local METHODS = {
	{
		name = "Player.Team",
		side = function(p) return (p.Team and not p.Neutral) and p.Team.Name or nil end,
	},
	{
		name = "Team attribute",
		side = function(p)
			local a = p:GetAttribute("Team")
			if a ~= nil then return tostring(a) end
			local ch = p.Character
			local ca = ch and ch:GetAttribute("Team")
			return (ca ~= nil) and tostring(ca) or nil
		end,
	},
	{
		name = "TeamColor",
		side = function(p)
			local ok, c = pcall(function() return p.TeamColor end)
			return (ok and c) and tostring(c.Name) or nil
		end,
	},
	{
		name = "Nameplate",
		side = function(p)
			local ch = p.Character
			local c = ch and nameplateColour(p, ch)
			return c and quantise(c) or nil
		end,
		colourOf = function(p)
			local ch = p.Character
			return ch and nameplateColour(p, ch) or nil
		end,
		-- This is the only method whose answer is ABSOLUTE rather than relative,
		-- so it needs neither an anchor nor a split: red means hostile on its own.
		--
		-- Measured in DoW with five enemies alive and no teammate in sight: every
		-- plate read 1.00, 0.20, 0.20. Under the split rule that is "one side, no
		-- information" and the chain falls through to marking everyone - the same
		-- answer, but reached by accident instead of on purpose, and it would have
		-- thrown away a perfectly good reading. A minute earlier the same server
		-- had sonyvi at 1,1,1 and Willi_ms0 at 1,0.2,0.2, which the same rule
		-- separates correctly.
		absolute = function(p)
			local ch = p.Character
			local c = ch and nameplateColour(p, ch)
			if not c then return nil end
			return reddness(c) > 0.25
		end,
	},
}

local chosen = nil          -- { m, mySide, hostile }
local chainAt = 0

local function methodByName(n)
	for _, m in ipairs(METHODS) do if m.name == n then return m end end
	return nil
end

-- Tries one link and reports what it found, without deciding anything.
local function assess(m, live, forced)
	if #live == 0 then return nil, "nobody live to test against" end

	-- An absolute method is judged on COVERAGE alone - there is no split to
	-- require and no side of ours to anchor against.
	if m.absolute then
		local answered, hostile = 0, 0
		for _, p in ipairs(live) do
			local ok, v = pcall(m.absolute, p)
			if ok and v ~= nil then
				answered = answered + 1
				if v then hostile = hostile + 1 end
			end
		end
		if answered * 2 <= #live and not forced then
			return nil, "covers only " .. answered .. " of " .. #live
		end
		return { m = m, absolute = true },
			"OK - " .. hostile .. " hostile of " .. answered .. " read"
	end

	local sides, answered = {}, 0
	for _, p in ipairs(live) do
		local ok, s = pcall(m.side, p)
		if ok and s then
			answered = answered + 1
			if not sides[s] then
				local col = nil
				if m.colourOf then local ok2, c = pcall(m.colourOf, p) col = ok2 and c or nil end
				sides[s] = { n = 0, colour = col }
			end
			sides[s].n = sides[s].n + 1
		end
	end
	local distinct = 0
	for _ in pairs(sides) do distinct = distinct + 1 end

	if distinct < 2 and not forced then
		return nil, "no split - " .. distinct .. " side for " .. #live .. " players"
	end
	if answered * 2 <= #live and not forced then
		return nil, "covers only " .. answered .. " of " .. #live
	end

	local okMine, mySide = pcall(m.side, plr)
	mySide = okMine and mySide or nil
	if mySide then
		return { m = m, mySide = mySide, hostile = nil },
			"OK - you are '" .. tostring(mySide) .. "', " .. distinct .. " sides"
	end
	if m.hostileOf then
		local h = m.hostileOf(sides)
		if h then
			return { m = m, mySide = nil, hostile = h },
				"OK - no side for you, hostile picked by colour"
		end
	end
	return nil, "split found but it cannot tell which side is yours"
end

local function evaluateChain()
	local now = os.clock()
	if now - chainAt < 1.5 then return end
	chainAt = now

	if CONFIG.teamMode == "Off" then
		chosen = nil
		STATE.chain = { "team filter off - everyone is a target" }
		STATE.teamNote = "off"
		STATE.teamsReal = false
		return
	end

	local live = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= plr and p.Character then table.insert(live, p) end
	end

	-- A forced method skips the sanity gates on purpose: the user has looked at
	-- the CHECK page and knows better than the heuristic.
	if CONFIG.teamMode ~= "Auto" then
		local m = methodByName(CONFIG.teamMode)
		if m then
			local pick, why = assess(m, live, true)
			chosen = pick
			STATE.chain = { m.name .. " (forced): " .. why }
			STATE.teamNote = pick and (m.name .. " forced") or ("forced " .. m.name .. " failed")
			STATE.teamsReal = pick ~= nil
			return
		end
	end

	local report = {}
	chosen = nil
	for _, m in ipairs(METHODS) do
		local pick, why = assess(m, live, false)
		table.insert(report, m.name .. ": " .. why)
		if pick then chosen = pick break end
	end
	if not chosen then table.insert(report, "-> nothing held up, everyone is a target") end

	STATE.chain = report
	STATE.teamNote = chosen and chosen.m.name or "none worked"
	STATE.teamsReal = chosen ~= nil
end

local function isTarget(p)
	if p == plr then return false end
	-- Nothing in the chain held up, so there is no basis for calling anyone a
	-- teammate. Showing too much is recoverable; going silent in a game the whole
	-- script exists for is not.
	if not chosen then return true end

	local hostile
	if chosen.absolute then
		local ok, v = pcall(chosen.m.absolute, p)
		-- No answer YET - just spawned, character still replicating. Same rule.
		if not ok or v == nil then return true end
		hostile = v
	else
		local ok, s = pcall(chosen.m.side, p)
		if not ok or not s then return true end
		if chosen.mySide then hostile = (s ~= chosen.mySide)
		else hostile = (s == chosen.hostile) end
	end

	if CONFIG.teamInvert then hostile = not hostile end
	return hostile
end

-- Health lives on a Humanoid in most games and on an attribute in the ones that
-- ship their own engine. Both are read; neither is assumed.
local function healthOf(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then return hum.Health, hum.MaxHealth, hum end
	local h = char:GetAttribute("Health")
	if h ~= nil then
		return tonumber(h) or 0, tonumber(char:GetAttribute("MaxHealth")) or 100, nil
	end
	return nil
end

local function alive(p)
	local char = p.Character
	if not char or not char.Parent then return nil end
	local hp, maxHp, hum = healthOf(char)
	if not hp or hp <= 0 then return nil end
	local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
		or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")
	if not root then return nil end
	return char, hp, maxHp, root, hum
end

--------------------------------------------------------------------------------
-- which part to aim at
--------------------------------------------------------------------------------
--
-- Ordered, first hit wins, and a game's OWN aim hitbox outranks the visible head
-- because it is what the server grades a hit against. Found by hint rather than
-- by name, so AutoAimAreaHead and HeadHB are both caught without a per-game list.

local HEAD_HINTS = { "hb", "hitbox", "box", "area", "aim" }

local function looksLikeHeadHitbox(name)
	local l = name:lower()
	if not l:find("head", 1, true) then return false end
	for _, h in ipairs(HEAD_HINTS) do
		if l:find(h, 1, true) then return true end
	end
	return false
end

-- Weak keys: a character destroyed on death drops out by itself, so a long
-- session cannot pin dead models in memory.
local partCache = setmetatable({}, { __mode = "k" })

local function resolveParts(char)
	local hit = partCache[char]
	if hit then return hit end

	local head, torso, lFoot, rFoot
	for _, d in ipairs(char:GetChildren()) do
		if d:IsA("BasePart") then
			if not head and looksLikeHeadHitbox(d.Name) then head = d end
		end
	end
	head = head or char:FindFirstChild("Head")
	for _, n in ipairs({ "UpperTorso", "Torso", "HumanoidRootPart" }) do
		local p = char:FindFirstChild(n)
		if p and p:IsA("BasePart") then torso = p break end
	end
	lFoot = char:FindFirstChild("LeftFoot")  or char:FindFirstChild("Left Leg")
	rFoot = char:FindFirstChild("RightFoot") or char:FindFirstChild("Right Leg")

	if not (head or torso) then return nil end
	local set = { head = head, torso = torso, lFoot = lFoot, rFoot = rFoot,
		visHead = char:FindFirstChild("Head") or head }
	partCache[char] = set
	STATE.rigNote = (head and head.Name or "?") .. " / "
		.. (torso and torso.Name or "?") .. (lFoot and " / feet" or " / no feet")
	return set
end

local function centre()
	local vp = camera.ViewportSize
	return Vector2.new(vp.X / 2, vp.Y / 2)
end

local function targetPart(char)
	local set = resolveParts(char)
	if not set then return nil end
	if CONFIG.aimPart == "Torso" then return set.torso or set.head end
	if CONFIG.aimPart == "Nearest" then
		local mid = centre()
		local best, bestD
		for _, p in ipairs({ set.head, set.torso }) do
			if p then
				local sp = camera:WorldToViewportPoint(p.Position)
				if sp.Z > 0 then
					local d = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
					if not bestD or d < bestD then best, bestD = p, d end
				end
			end
		end
		return best or set.head or set.torso
	end
	return set.head or set.torso
end

--------------------------------------------------------------------------------
-- line of sight
--------------------------------------------------------------------------------

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local filterAt = 0

local function refreshFilter()
	local now = os.clock()
	if now - filterAt < 1 then return end
	filterAt = now
	local list = {}
	-- Every character, ours included: our own arms sit in front of the camera in
	-- first person and would mark every target as blocked.
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then table.insert(list, p.Character) end
	end
	local chars = workspace:FindFirstChild("Characters")
	if chars then table.insert(list, chars) end
	-- Buckets that are a debris/effect folder in a large share of games. Missing
	-- ones are simply not added.
	for _, name in ipairs({ "Debris", "Ray_Ignore", "Ignore", "Effects", "Bullets",
		"Projectiles", "Viewmodel" }) do
		local f = workspace:FindFirstChild(name)
		if f then table.insert(list, f) end
	end
	rayParams.FilterDescendantsInstances = list
end

local function visible(worldPos)
	local origin = camera.CFrame.Position
	return workspace:Raycast(origin, worldPos - origin, rayParams) == nil
end

--------------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------------
--
-- One set per player, created once and then only moved, coloured and hidden.
-- Drawing.new is a C-side allocation; doing it per frame is what makes a naive
-- ESP stutter at twenty players.

local drawn, pool = {}, {}

-- Last run's objects are still on screen after a re-execute with nothing driving
-- them. The generation guard stops the LOOP; only this clears the PIXELS.
if _G.__SELUNI_POOL then
	for _, obj in ipairs(_G.__SELUNI_POOL) do pcall(function() obj:Remove() end) end
end
_G.__SELUNI_POOL = pool

local function make(kind, props)
	if not HAS_DRAWING then return nil end
	local ok, obj = pcall(function() return Drawing.new(kind) end)
	if not ok or not obj then return nil end
	obj.Visible = false
	for k, v in pairs(props or {}) do pcall(function() obj[k] = v end) end
	table.insert(pool, obj)
	return obj
end

local function objectsFor(p)
	local set = drawn[p]
	if set then return set end
	set = {
		outline = make("Square", { Thickness = 3, Filled = false, ZIndex = 1,
			Color = Color3.new(0, 0, 0), Transparency = 0.6 }),
		box     = make("Square", { Thickness = 1, Filled = false, ZIndex = 2 }),
		fill    = make("Square", { Filled = true, ZIndex = 0, Transparency = 0.15 }),
		hpBg    = make("Square", { Filled = true, ZIndex = 1, Color = Color3.new(0, 0, 0),
			Transparency = 0.6 }),
		hp      = make("Square", { Filled = true, ZIndex = 2 }),
		name    = make("Text", { Size = 13, Center = true, Outline = true, ZIndex = 3 }),
		info    = make("Text", { Size = 12, Center = true, Outline = true, ZIndex = 3 }),
		tracer  = make("Line", { Thickness = 1, ZIndex = 1 }),
		head    = make("Circle", { Thickness = 1, Filled = false, NumSides = 14, ZIndex = 3 }),
	}
	drawn[p] = set
	return set
end

local function hideSet(set)
	for _, obj in pairs(set) do
		if obj and obj.Visible ~= nil then obj.Visible = false end
	end
end

local function hideAll()
	for _, set in pairs(drawn) do hideSet(set) end
end

local fovCircle = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Transparency = 0.5, ZIndex = 1 })

--------------------------------------------------------------------------------
-- the box
--------------------------------------------------------------------------------
--
-- Top of the head to the bottom of the lower foot, both projected. The projected
-- distance between those two points IS the on-screen height, so it scales with
-- range for free and follows a crouch exactly - no assumed rig height, no
-- constant to tune. Every other element is then sized off `h`, which keeps the
-- whole overlay in proportion at every distance.
--
-- GetBoundingBox is the fallback for a rig with no recognisable head or feet, and
-- it is sanity-checked before use: measured in Counter Blox it reported 77 studs
-- of height for a 6.5 stud character.

local function screenBox(char, set)
	local top, bot

	if set and set.visHead and (set.lFoot or set.rFoot) then
		local head = set.visHead
		top = head.Position + Vector3.new(0, head.Size.Y / 2 + 0.35, 0)
		local low = set.lFoot or set.rFoot
		if set.lFoot and set.rFoot then
			low = (set.lFoot.Position.Y <= set.rFoot.Position.Y) and set.lFoot or set.rFoot
		end
		bot = low.Position - Vector3.new(0, low.Size.Y / 2, 0)
	elseif set and set.visHead and set.torso then
		-- no feet: mirror the head height below the torso, which is close enough
		local head = set.visHead
		top = head.Position + Vector3.new(0, head.Size.Y / 2 + 0.35, 0)
		local drop = (head.Position.Y - set.torso.Position.Y) * 2 + 1.5
		bot = Vector3.new(head.Position.X, head.Position.Y - drop, head.Position.Z)
	else
		local ok, cf, size = pcall(function()
			local a, b = char:GetBoundingBox()
			return a, b
		end)
		-- a person is not forty studs tall; anything that says so is the broken case
		if not ok or not cf or size.Y > 20 or size.Y < 1 then return nil end
		top = (cf * CFrame.new(0,  size.Y / 2, 0)).Position
		bot = (cf * CFrame.new(0, -size.Y / 2, 0)).Position
	end

	local sTop = camera:WorldToViewportPoint(top)
	local sBot = camera:WorldToViewportPoint(bot)
	-- Z <= 0 is BEHIND the camera; the X/Y reported there is mirrored nonsense and
	-- drawing it puts a box on the wrong side of the screen for somebody standing
	-- behind you.
	if sTop.Z <= 0 or sBot.Z <= 0 then return nil end

	local h = math.abs(sBot.Y - sTop.Y)
	if h < 1 then return nil end
	local w = h * 0.52
	local cx = (sTop.X + sBot.X) / 2
	return cx - w / 2, math.min(sTop.Y, sBot.Y), w, h
end

--------------------------------------------------------------------------------
-- the render pass
--------------------------------------------------------------------------------

local function renderPass()
	if _G.__SELUNI ~= GEN then return end
	refreshFilter()
	evaluateChain()     -- self-throttled to 1.5s; a round change reassigns teams

	local mid = centre()
	if fovCircle then
		fovCircle.Visible = CONFIG.aim and CONFIG.aimCircle
		if fovCircle.Visible then
			fovCircle.Position = mid
			fovCircle.Radius = CONFIG.aimFov
			fovCircle.Color = CONFIG.colFov
		end
	end

	if not CONFIG.esp or not HAS_DRAWING then
		hideAll()
		STATE.targets = 0
		return
	end

	local camPos = camera.CFrame.Position
	local seen = 0

	for _, p in ipairs(Players:GetPlayers()) do
		local set = objectsFor(p)
		local shown = false

		if set.box and isTarget(p) then
			local char, hp, maxHp, root = alive(p)
			if char then
				local dist = (camPos - root.Position).Magnitude
				if dist <= CONFIG.maxDist then
					local parts = resolveParts(char)
					local anchor = (parts and (parts.head or parts.torso)) or root
					local vis = visible(anchor.Position)
					if vis or not CONFIG.espVisOnly then
						local x, y, w, h = screenBox(char, parts)
						if x then
							seen = seen + 1
							shown = true
							local col = vis and CONFIG.colVisible or CONFIG.colEnemy
							local alpha = (vis or not CONFIG.espDimHidden) and 1 or 0.45
							-- everything sized off h, so the overlay stays in
							-- proportion at every range
							local txt = math.max(12, math.floor(CONFIG.espTextSize))

							if CONFIG.espBox then
								set.outline.Position = Vector2.new(x, y)
								set.outline.Size = Vector2.new(w, h)
								set.outline.Transparency = 0.6 * alpha
								set.outline.Visible = true
								set.box.Position = Vector2.new(x, y)
								set.box.Size = Vector2.new(w, h)
								set.box.Color = col
								set.box.Transparency = alpha
								set.box.Visible = true
							end
							if CONFIG.espBoxFill then
								set.fill.Position = Vector2.new(x, y)
								set.fill.Size = Vector2.new(w, h)
								set.fill.Color = col
								set.fill.Transparency = 0.15 * alpha
								set.fill.Visible = true
							end
							if CONFIG.espHealth then
								local frac = math.clamp(hp / math.max(maxHp, 1), 0, 1)
								set.hpBg.Position = Vector2.new(x - 6, y)
								set.hpBg.Size = Vector2.new(3, h)
								set.hpBg.Visible = true
								set.hp.Position = Vector2.new(x - 6, y + h * (1 - frac))
								set.hp.Size = Vector2.new(3, h * frac)
								set.hp.Color = Color3.fromRGB(255, 70, 70)
									:Lerp(Color3.fromRGB(90, 235, 110), frac)
								set.hp.Visible = true
							end
							if CONFIG.espName then
								set.name.Text = (p.DisplayName ~= "" and p.DisplayName) or p.Name
								set.name.Size = txt
								set.name.Font = CONFIG.espFont
								set.name.Position = Vector2.new(x + w / 2, y - txt - 2)
								set.name.Color = CONFIG.colText
								set.name.Transparency = alpha
								set.name.Visible = true
							end
							if CONFIG.espInfo then
								set.info.Text = string.format("%dm  %d", math.floor(dist),
									math.floor(hp))
								set.info.Size = math.max(12, txt - 1)
								set.info.Font = CONFIG.espFont
								set.info.Position = Vector2.new(x + w / 2, y + h + 1)
								set.info.Color = CONFIG.colText
								set.info.Transparency = alpha
								set.info.Visible = true
							end
							if CONFIG.espTracer then
								set.tracer.From = Vector2.new(mid.X, camera.ViewportSize.Y)
								set.tracer.To = Vector2.new(x + w / 2, y + h)
								set.tracer.Color = col
								set.tracer.Transparency = alpha
								set.tracer.Visible = true
							end
							if CONFIG.espHeadDot and parts and parts.visHead then
								local sp = camera:WorldToViewportPoint(parts.visHead.Position)
								if sp.Z > 0 then
									set.head.Position = Vector2.new(sp.X, sp.Y)
									set.head.Radius = math.max(2, h * 0.075)
									set.head.Color = col
									set.head.Transparency = alpha
									set.head.Visible = true
								end
							end
						end
					end
				end
			end
		end

		if not shown then hideSet(set) end
	end

	STATE.targets = seen
end

Players.PlayerRemoving:Connect(function(p)
	local set = drawn[p]
	if set then hideSet(set) drawn[p] = nil end
end)

--------------------------------------------------------------------------------
-- aim assist
--------------------------------------------------------------------------------

local function keyFromName(name)
	if type(name) ~= "string" then return nil end
	if name:sub(1, 11) == "MouseButton" then return Enum.UserInputType[name] end
	return Enum.KeyCode[name]
end

local function hotkeyHeld(name)
	local k = keyFromName(name)
	if not k then return false end
	local ok, held = pcall(function()
		if typeof(k) == "EnumItem" and k.EnumType == Enum.UserInputType then
			return UserInputService:IsMouseButtonPressed(k)
		end
		return UserInputService:IsKeyDown(k)
	end)
	return ok and held or false
end

local function firing()
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
end

local function aimActive()
	if not CONFIG.aim then return false end
	if CONFIG.hum and CONFIG.humPanelOff and STATE.panelOpen then return false end
	if CONFIG.aimActive == "Always" then return true end
	if CONFIG.aimActive == "While firing" then return firing() end
	return hotkeyHeld(CONFIG.aimKey)
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

-- A smooth random walk, not per-frame randomness: white noise on a camera reads
-- as a stutter, a walk reads as a hand.
local noiseX, noiseY, noiseTX, noiseTY, noiseAt = 0, 0, 0, 0, 0

local function noiseStep(dt)
	if not CONFIG.hum or CONFIG.humNoise <= 0 then
		noiseX, noiseY = 0, 0
		return 0, 0
	end
	local now = os.clock()
	local period = 1 / math.max(0.1, CONFIG.humNoiseHz)
	if now - noiseAt > period then
		noiseAt = now
		noiseTX, noiseTY = math.random() * 2 - 1, math.random() * 2 - 1
	end
	local k = math.clamp(dt / period, 0, 1) * 2
	noiseX = noiseX + (noiseTX - noiseX) * k
	noiseY = noiseY + (noiseTY - noiseY) * k
	local amp = math.rad(CONFIG.humNoise)
	return noiseX * amp, noiseY * amp
end

local function pickTarget()
	local mid = centre()
	local camPos = camera.CFrame.Position
	local best, bestScore

	for _, p in ipairs(Players:GetPlayers()) do
		if isTarget(p) then
			local char, hp, _, root = alive(p)
			if char then
				local part = targetPart(char)
				if part and (camPos - root.Position).Magnitude <= CONFIG.aimMaxDist then
					local sp = camera:WorldToViewportPoint(part.Position)
					if sp.Z > 0 then
						local px = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
						if px <= CONFIG.aimFov then
							if (not CONFIG.aimVisible) or visible(part.Position) then
								local score = px
								if CONFIG.aimPick == "Closest" then
									score = (camPos - root.Position).Magnitude
								elseif CONFIG.aimPick == "Lowest HP" then
									score = hp
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

--------------------------------------------------------------------------------
-- delivery: which way this game lets the view be moved
--------------------------------------------------------------------------------
--
-- CAMERA writes camera.CFrame directly. Exact, and thrown away by any game whose
-- own controller rebuilds the CFrame from angles it keeps itself.
--
-- MOUSE calls mousemoverel, so the game's own controller authors the movement -
-- it therefore works in both kinds of game and goes through the real input path.
-- The cost is that the player's sensitivity is unknowable from the client, so it
-- is LEARNED: ask for a movement, measure what the view actually did on the next
-- frame, fold it into a running estimate. Sub-pixel requests are skipped because
-- the OS rounds them away and the estimate would learn from a move that never
-- happened.
--
-- AUTO measures whether a camera write survives and picks. It starts on CAMERA,
-- because that needs no learning and is exact where it works.

local leftYaw, leftPitch = nil, nil      -- what the last written frame left behind
local stickHits, stickMiss = 0, 0
local mouseSensY, mouseSensP = 0, 0
local askedX, askedY = 0, 0
local preYaw, prePitch = nil, nil

local function deliverMode()
	if CONFIG.aimDeliver == "Mouse" then return moveMouse and "Mouse" or "Camera" end
	if CONFIG.aimDeliver == "Camera" then return "Camera" end
	-- Auto: stay on Camera until the probe says writes are not surviving
	if not moveMouse then return "Camera" end
	local n = stickHits + stickMiss
	if n < 90 then return "Camera" end
	STATE.stickPct = math.floor(stickHits / n * 100)
	return (STATE.stickPct >= 50) and "Camera" or "Mouse"
end

local stickyTarget, lockedAt, reactUntil = nil, 0, 0
local lastNX, lastNY = 0, 0

local function aimPass(dt)
	if _G.__SELUNI ~= GEN then return end
	STATE.engaged = false

	local cf = camera.CFrame
	local pitchNow, yawNow = cf:ToOrientation()

	-- Did last frame's camera write survive? Only counted on frames where we did
	-- not also move the mouse ourselves, so the probe measures the GAME and not us.
	if leftYaw ~= nil then
		local drift = math.abs(math.deg(angleDelta(leftYaw, yawNow)))
		if drift < 0.12 then stickHits = stickHits + 1 else stickMiss = stickMiss + 1 end
		if stickHits + stickMiss > 600 then
			stickHits, stickMiss = math.floor(stickHits / 2), math.floor(stickMiss / 2)
		end
		leftYaw = nil
	end

	-- Learn what one mouse unit is worth, from the request made last frame.
	if preYaw ~= nil and (math.abs(askedX) >= 1 or math.abs(askedY) >= 1) then
		if math.abs(askedX) >= 1 then
			local s = -angleDelta(preYaw, yawNow) / askedX
			if s == s and s > 0 and s < 0.1 then
				mouseSensY = (mouseSensY == 0) and s or (mouseSensY * 0.85 + s * 0.15)
			end
		end
		if math.abs(askedY) >= 1 then
			local s = -(pitchNow - prePitch) / askedY
			if s == s and s > 0 and s < 0.1 then
				mouseSensP = (mouseSensP == 0) and s or (mouseSensP * 0.85 + s * 0.15)
			end
		end
		STATE.mouseSens = mouseSensY
	end
	askedX, askedY = 0, 0
	preYaw, prePitch = nil, nil

	-- the wander is an OFFSET on the view, never a movement of it; see the note
	-- in the camera branch below
	local prevNX, prevNY = lastNX, lastNY
	lastNX, lastNY = 0, 0

	if not aimActive() then
		STATE.target, STATE.waitMs, stickyTarget = "-", 0, nil
		return
	end

	local nowMs = os.clock() * 1000
	local pick

	if CONFIG.aimSticky and stickyTarget then
		local char = alive(stickyTarget)
		if char then
			local part = targetPart(char)
			if part then
				local sp = camera:WorldToViewportPoint(part.Position)
				local px = (Vector2.new(sp.X, sp.Y) - centre()).Magnitude
				-- 1.35x: a target already being tracked may drift a little past the
				-- ring before the lock is dropped, or a strafing player is lost and
				-- re-acquired every few frames
				if sp.Z > 0 and px <= CONFIG.aimFov * 1.35
					and ((not CONFIG.aimVisible) or visible(part.Position)) then
					pick = { player = stickyTarget, part = part, px = px }
				end
			end
		end
	end

	if not pick then
		pick = pickTarget()
		if pick and pick.player ~= stickyTarget then
			local lo = math.min(CONFIG.humReactMin, CONFIG.humReactMax)
			local hi = math.max(CONFIG.humReactMin, CONFIG.humReactMax)
			reactUntil = (CONFIG.hum and hi > 0) and (nowMs + math.random(lo, hi)) or 0
			lockedAt = nowMs
		end
	end

	if not pick or not pick.part or not pick.part.Parent then
		STATE.target, STATE.waitMs, stickyTarget = "-", 0, nil
		return
	end
	stickyTarget = pick.player
	STATE.target = pick.player.Name

	if reactUntil > nowMs then
		STATE.waitMs = math.floor(reactUntil - nowMs)
		return
	end
	STATE.waitMs = 0

	local smoothH, smoothV = CONFIG.aimSmoothH, CONFIG.aimSmoothV
	if CONFIG.hum and CONFIG.humRampMs > 0 then
		local age = nowMs - lockedAt
		if age < CONFIG.humRampMs then
			local slow = 3 - 2 * (age / CONFIG.humRampMs)
			smoothH, smoothV = smoothH * slow, smoothV * slow
		end
	end

	local pos = cf.Position
	local curPitch, curYaw = pitchNow - prevNY, yawNow - prevNX
	local want = CFrame.lookAt(pos, pick.part.Position)
	local wantPitch, wantYaw = want:ToOrientation()

	local dYaw   = angleDelta(curYaw, wantYaw)
	local dPitch = angleDelta(curPitch, wantPitch)

	-- The honest self-measurement. A game that overrides the view leaves this high
	-- however the sliders are set, and the CHECK page prints it rather than
	-- claiming the assist works.
	local errDeg = math.deg(math.sqrt(dYaw * dYaw + dPitch * dPitch))
	STATE.aimErr = (STATE.aimErr == 0) and errDeg or (STATE.aimErr * 0.95 + errDeg * 0.05)

	if CONFIG.hum and CONFIG.humDeadPx > 0 and pick.px <= CONFIG.humDeadPx then
		dYaw, dPitch = 0, 0
	end

	local moveYaw   = dYaw   * approach(smoothH, dt)
	local movePitch = dPitch * approach(smoothV, dt)

	if CONFIG.hum and CONFIG.humMaxDegS > 0 then
		local cap = math.rad(CONFIG.humMaxDegS) * dt
		local mag = math.sqrt(moveYaw * moveYaw + movePitch * movePitch)
		if mag > cap and mag > 0 then
			local k = cap / mag
			moveYaw, movePitch = moveYaw * k, movePitch * k
		end
	end

	local nx, ny = noiseStep(dt)
	local mode = deliverMode()
	STATE.deliver = mode

	if mode == "Mouse" then
		-- Seeded rather than assumed: 0.007 rad per unit is what this project has
		-- measured on two games, and the estimate replaces it within a few frames.
		local sy = (mouseSensY ~= 0) and mouseSensY or 0.007
		local sp = (mouseSensP ~= 0) and mouseSensP or sy
		-- positive x turns right and LOWERS yaw; positive y looks down and LOWERS
		-- pitch - hence the minus on both
		local dx = -(moveYaw + nx) / sy
		local dy = -(movePitch + ny) / sp
		-- The OS rounds sub-pixel requests away. Sending them would teach the
		-- estimate from a movement that never happened, so they are dropped and
		-- the remainder is carried instead of lost.
		if math.abs(dx) >= 1 or math.abs(dy) >= 1 then
			askedX, askedY = math.floor(dx + 0.5), math.floor(dy + 0.5)
			preYaw, prePitch = yawNow, pitchNow
			pcall(function() moveMouse(askedX, askedY) end)
		end
		lastNX, lastNY = 0, 0     -- the wander went out through the mouse, not as
		                          -- an offset that has to be taken back
	else
		lastNX, lastNY = nx, ny
		camera.CFrame = CFrame.new(pos)
			* CFrame.fromOrientation(curPitch + movePitch + ny, curYaw + moveYaw + nx, 0)
		-- what this frame left behind, for next frame's survival probe
		leftYaw = curYaw + moveYaw + nx
	end

	STATE.engaged = true
end

--------------------------------------------------------------------------------
-- panic key
--------------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, typing)
	if _G.__SELUNI ~= GEN or typing then return end
	local k = keyFromName(CONFIG.panicKey)
	if k and input.KeyCode == k then
		CONFIG.aim = false
		note("PANIC - aim off")
	end
end)

--------------------------------------------------------------------------------
-- render binds
--------------------------------------------------------------------------------
--
-- Camera + 1, so both run AFTER whatever the game does to the camera this frame.
-- Anything earlier is simply overwritten and the survival probe would read zero.

for _, name in ipairs({ "SeluxUniAim", "SeluxUniESP" }) do
	pcall(function() RunService:UnbindFromRenderStep(name) end)
end

RunService:BindToRenderStep("SeluxUniAim", Enum.RenderPriority.Camera.Value + 1,
	function(dt)
		if _G.__SELUNI ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxUniAim") end)
			return
		end
		local ok, err = pcall(function() aimPass(dt) end)
		if not ok then note("aim: " .. tostring(err)) end
	end)

RunService:BindToRenderStep("SeluxUniESP", Enum.RenderPriority.Camera.Value + 2,
	function()
		if _G.__SELUNI ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxUniESP") end)
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

-- The generation counter stops last run's LOOPS; it does not take last run's
-- PANEL off the screen, and a re-execute then leaves two of them stacked. Both
-- halves are needed: the stored handle covers the normal case, and the sweep by
-- name covers a window whose handle was lost (a run that errored before storing
-- it, or a stale cached template).
if _G.__SELUNI_WIN then pcall(function() _G.__SELUNI_WIN:Destroy() end) end
if UI.sweep then UI.sweep("SeluxUniversalPanel") end

-- Merged into CONFIG BEFORE the panel is built: the controls read their initial
-- value out of CONFIG as they are created, so they come up on the saved state by
-- themselves and nothing below has to know about it.
UI.config("universal", CONFIG)

local placeName = "place " .. tostring(game.PlaceId)
pcall(function()
	local info = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
	if info and info.Name then placeName = info.Name end
end)

local win = UI.Window({
	name = "SeluxUniversalPanel",
	title = "SELUX", accentTitle = "UNIVERSAL", subtitle = "seltonmt",
})
_G.__SELUNI_WIN = win

local KEYS = { "MouseButton2", "MouseButton1", "LeftShift", "LeftAlt", "LeftControl",
	"C", "E", "Q", "F", "V", "X", "CapsLock" }

--------------------------------------------------------------- ESP
local espPage = win:Page("ESP", UI.icon.eye or UI.icon.target)

local espCard = espPage:Card("DRAW", 1):Accent()
espCard:Toggle("ESP enabled", CONFIG.esp, function(v) CONFIG.esp = v end)
espCard:Toggle("Box", CONFIG.espBox, function(v) CONFIG.espBox = v end)
espCard:Toggle("Box fill", CONFIG.espBoxFill, function(v) CONFIG.espBoxFill = v end)
espCard:Toggle("Name", CONFIG.espName, function(v) CONFIG.espName = v end)
espCard:Toggle("Distance and health", CONFIG.espInfo, function(v) CONFIG.espInfo = v end)
espCard:Toggle("Health bar", CONFIG.espHealth, function(v) CONFIG.espHealth = v end)
espCard:Toggle("Tracer", CONFIG.espTracer, function(v) CONFIG.espTracer = v end)
espCard:Toggle("Head dot", CONFIG.espHeadDot, function(v) CONFIG.espHeadDot = v end)

local visCard = espPage:Card("VISIBILITY", 2)
visCard:Toggle("Visible only", CONFIG.espVisOnly, function(v) CONFIG.espVisOnly = v end,
	"hide anyone behind a wall completely", UI.theme.warn)
visCard:Toggle("Dim hidden targets", CONFIG.espDimHidden,
	function(v) CONFIG.espDimHidden = v end, "draw them faded instead", UI.theme.good)
visCard:Slider("Max distance", 100, 5000, CONFIG.maxDist, function(v) CONFIG.maxDist = v end)
visCard:Slider("Text size", 12, 20, CONFIG.espTextSize,
	function(v) CONFIG.espTextSize = v end, "floored at 12 - below that every "
	.. "Drawing face falls apart")

local teamCard = espPage:Card("TARGETS", 0)
teamCard:Dropdown("Team filter",
	{ "Auto", "Player.Team", "Team attribute", "TeamColor", "Nameplate", "Off" },
	CONFIG.teamMode, function(v) CONFIG.teamMode = v end,
	"Auto tries each in turn and keeps the first that makes sense")
teamCard:Toggle("Invert targets", CONFIG.teamInvert, function(v) CONFIG.teamInvert = v end,
	"use when the split is right but the sides are swapped", UI.theme.warn)
-- Readout takes a LINE COUNT, not a caption - one box, three lines.
local teamOut = teamCard:Readout(3)

--------------------------------------------------------------- AIM
local aimPage = win:Page("AIM", UI.icon.target)

local aimCard = aimPage:Card("ACTIVATION", 1):Accent()
aimCard:Toggle("Aim assist", CONFIG.aim, function(v) CONFIG.aim = v end)
aimCard:Dropdown("Trigger", { "Hotkey", "Always", "While firing" }, CONFIG.aimActive,
	function(v) CONFIG.aimActive = v end)
aimCard:Dropdown("Aim key", KEYS, CONFIG.aimKey, function(v) CONFIG.aimKey = v end)
aimCard:Dropdown("Aim at", { "Head", "Torso", "Nearest" }, CONFIG.aimPart,
	function(v) CONFIG.aimPart = v end)
aimCard:Dropdown("Pick target by", { "Crosshair", "Closest", "Lowest HP" }, CONFIG.aimPick,
	function(v) CONFIG.aimPick = v end)
aimCard:Dropdown("Delivery", { "Auto", "Mouse", "Camera" }, CONFIG.aimDeliver,
	function(v) CONFIG.aimDeliver = v end)
aimCard:Toggle("Sticky target", CONFIG.aimSticky, function(v) CONFIG.aimSticky = v end)
aimCard:Toggle("Visible only", CONFIG.aimVisible, function(v) CONFIG.aimVisible = v end,
	"never aim through a wall", UI.theme.good)
aimCard:Toggle("Show FOV circle", CONFIG.aimCircle, function(v) CONFIG.aimCircle = v end)

local tuneCard = aimPage:Card("TUNING", 2)
tuneCard:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov, function(v) CONFIG.aimFov = v end)
tuneCard:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH,
	function(v) CONFIG.aimSmoothH = v end, "higher is slower")
tuneCard:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV, function(v) CONFIG.aimSmoothV = v end)
tuneCard:Slider("Max distance", 50, 5000, CONFIG.aimMaxDist,
	function(v) CONFIG.aimMaxDist = v end)

local humCard = aimPage:Card("HOW HUMAN IT LOOKS", 0)
humCard:Label("A shooter that records view angles server-side can replay where "
	.. "your crosshair was, tick by tick. Nothing in a client can hide that, so "
	.. "these numbers ARE the safety - not obscurity.")
humCard:Dropdown("Preset", { "Legit", "Normal", "Raw" }, "Normal", function(v)
	local set = PRESETS[v]
	if not set then return end
	for k, val in pairs(set) do CONFIG[k] = val end
	note("preset " .. v .. " applied - reopen the panel to see the sliders move")
end)
humCard:Toggle("Humanisation", CONFIG.hum, function(v) CONFIG.hum = v end,
	"reaction delay, wind-up, wander, deadzone and a speed ceiling", UI.theme.good)
humCard:Slider("Reaction min (ms)", 0, 500, CONFIG.humReactMin,
	function(v) CONFIG.humReactMin = v end)
humCard:Slider("Reaction max (ms)", 0, 500, CONFIG.humReactMax,
	function(v) CONFIG.humReactMax = v end)
humCard:Slider("Wind-up (ms)", 0, 800, CONFIG.humRampMs, function(v) CONFIG.humRampMs = v end)
humCard:Slider("Deadzone (px)", 0, 30, CONFIG.humDeadPx, function(v) CONFIG.humDeadPx = v end)
humCard:Slider("Speed ceiling (deg/s)", 30, 1200, CONFIG.humMaxDegS,
	function(v) CONFIG.humMaxDegS = v end, "the single most important number here",
	UI.theme.warn)
humCard:Dropdown("Panic key", { "F1", "F2", "F3", "F4" }, CONFIG.panicKey,
	function(v) CONFIG.panicKey = v end)

--------------------------------------------------------------- CHECK
local diagPage = win:Page("CHECK", UI.icon.info or UI.icon.list)
local diagCard = diagPage:Card("DOES THIS GAME WORK", 1):Accent()
local diagOut = diagCard:Label("-")
diagCard:Label("Nothing here is guessed. If the aim error stays high while a "
	.. "target is locked, this game rebuilds the camera itself - switch Delivery "
	.. "to Mouse. If that does not help either, the assist cannot work in this "
	.. "game and no slider will change it.")
diagCard:Button("Open the script picker", function()
	if _G.__SEL and _G.__SEL.picker then _G.__SEL.picker() end
end, UI.theme.warn)

win:Home()
win:SetMaster(CONFIG.esp, "ESP running")
win:OnMaster(function(on) CONFIG.esp = on end)
win:Refresh()

--------------------------------------------------------------------------------
-- panel refresh
--------------------------------------------------------------------------------

task.spawn(function()
	while _G.__SELUNI == GEN do
		local ok, err = pcall(function()
			STATE.panelOpen = win.open == true

			teamOut:set(table.concat({
				"using    " .. STATE.teamNote
					.. (STATE.teamsReal and "" or "  (everyone is a target)"),
				"targets  " .. STATE.targets .. " drawn",
				"rig      " .. STATE.rigNote,
			}, "\n"))

			local lines = {
				"  place    " .. placeName,
				"  drawing  " .. (HAS_DRAWING and "available" or "MISSING - no ESP"),
				"  mouse    " .. (moveMouse and "mousemoverel available"
					or "MISSING - camera path only"),
				"  targets  " .. STATE.targets .. " drawn",
				"  rig      " .. STATE.rigNote,
				"  TEAM DETECTION CHAIN",
				"  delivery " .. STATE.deliver
					.. (STATE.stickPct >= 0
						and ("   camera writes survive " .. STATE.stickPct .. "%") or ""),
				string.format("  aim err  %.2f deg", STATE.aimErr),
			}
			-- verbatim, because the point of the chain is that you can see WHY a
			-- method was dropped rather than only which one won
			for _, line in ipairs(STATE.chain) do
				table.insert(lines, "    " .. line)
			end
			if STATE.mouseSens > 0 then
				table.insert(lines, string.format("  mouse    %.5f rad per unit",
					STATE.mouseSens))
			end
			if STATE.note ~= "" then table.insert(lines, "  note     " .. STATE.note) end
			diagOut:set(table.concat(lines, "\n"))

			win:SetStat(1, tostring(STATE.targets), "targets")
			win:SetStat(2, string.format("%.1f", STATE.aimErr), "aim err")
			win:SetStat(3, STATE.deliver, "delivery")
			win:SetStatus(placeName .. "   " .. STATE.targets .. " targets   "
				.. (CONFIG.aim and ("aim " .. STATE.deliver) or "aim off"))
		end)
		if not ok then note("panel: " .. tostring(err)) end
		task.wait(0.35)
	end
end)

--------------------------------------------------------------------------------
-- debug handle
--------------------------------------------------------------------------------

_G.__SELUNI_DBG = {
	CONFIG = CONFIG, STATE = STATE, PRESETS = PRESETS,
	isTarget = isTarget, alive = alive, teamOf = teamOf, healthOf = healthOf,
	resolveParts = resolveParts, targetPart = targetPart, pickTarget = pickTarget,
	visible = visible, screenBox = screenBox, teamsLookReal = teamsLookReal,
	renderPass = renderPass, aimPass = aimPass, deliverMode = deliverMode,
	drawn = drawn,
}

print("[selux universal] gen " .. GEN .. " ready in " .. placeName
	.. " - RightShift for the panel")
