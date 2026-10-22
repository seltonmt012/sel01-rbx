--[[ stoneskipping.lua - "+1 Stone Skipping" (place 111543903102439, Meow Labs)

  The loop the game actually runs:

      stand on a TRAINING STAND -> the server skims stones by itself -> SKILL
      SKILL -> LEVEL (GameBalance.Progression, the server's own curve)
      LEVEL -> how far a THROW flies -> the zone it lands in pays WINS
      WINS  -> STONES (skill multiplier), EGGS (pets), TRAILS (wins multiplier)
      level >= NextRebirthLevel -> REBIRTH: level and skill reset, wins and stones stay

  Everything below was measured against the server before it was written down.
  The oracle is the client's own copy of the profile, an upvalue of the
  controller's canThrow - it is REPLACED on every State packet, so it is read
  fresh every time and never cached.

  * A THROW IS ONE REQUEST AND THE SERVER FLIES IT. Request("Throw", requestId),
    from inside the LaunchZone. The server sends ThrowStarted with the whole plan,
    one Bounce per hop and ThrowFinished with Distance and Wins. Level 22 flew 376
    studs into PALM BEACH: 12 bounces x 6 skill, 5 wins, ~6.4 s. The throw goes
    through the controller's own BeginThrow - firing the request by hand makes the
    client's ThrowStarted handler answer CancelThrow, because it has no record of it.

  * TRAINING IS STANDING ON A STAND. The server starts Practice by itself and keeps
    restarting it; nothing is fired. 48 skill/s on the basic stand, 94 on RareJade
    at the same multipliers. A stand is only entered FRESH: teleporting straight from
    one stand onto another started nothing, stepping beside it first did.

  * THE ZONE GATES ARE REAL. RareJade before 2 rebirths answers "Requires 2
    rebirths to train here", the pass stands (Hacker, Golden, Koi) never start
    without the gamepass.

  * WINS ARE A STEP FUNCTION OF SKILL. Each world turns TotalSkill into its own
    THROW level (World.Throw.Progression: World 1 quadratic, World 2 1M skill per
    level) - not the level on screen, which only gates the rebirth. The throw level
    is interpolated between the world's DistanceMilestones and the zone under it
    pays 1 / 5 / 20 / 75 / 200 / 500 / 1.25K / 3K / 10K / 25K in World 1. Measured:
    screen level 150, throw level 1655, 4,640 studs. So the Smart mode asks every
    cycle: is it faster to throw now, or to train to the next milestone first and
    throw there? Training is ~2x the skill of throwing, but only a throw pays wins.

  * THE PORTAL OPENS WITH ONE THROW. A throw that reaches the last milestone (here
    a Secret/Colossus roll to 4,640 studs) unlocks the next world, TravelWorld moves
    there - done by the farm itself on the test account, World 1 -> World 2.

  * STONES ARE THE MULTIPLIER. Buy("jade") charged exactly 10 wins, equipped the
    Ammonite Fossil and moved TrainingRate 21.9 -> 36.5 (x5 / x3). They come first;
    a trail (wins multiplier) jumps the egg queue while it costs at most 10 minutes
    of throwing, because the eggs would otherwise starve it for good.

  * REBIRTH KEEPS WINS AND STONES. Rebirth(rebirths) at level 40: level 40 -> 1,
    skill -> 0, wins 15 -> 15, multiplier x2 -> x3. Wins are therefore collected at
    the top of a rebirth cycle, where a throw pays the most.

  * EGGS ARE POSITION GATED, INVENTORY EGGS ARE NOT. HatchEgg from the launch zone
    answered "Move closer to the egg."; next to the display it charged 50 wins and
    hatched a pet, with no reveal animation in the way. HatchInventoryEgg works from
    anywhere, even while training. A new pet is seated by itself while a slot is
    free; PetEquipment Best is refused while training or throwing. Inventory eggs
    and fusion claims queue a reveal that waits for a click and blocks every throw
    behind it ("throw not ready" for minutes); EggShopController's own reveal
    object is reset until the queue is empty.

  * PET POWER IS THE GAME'S OWN PetCatalog.Power. The pass's Trick Bat reads 1.3
    in the catalog but is the best fixed pet x (1 + BestPetBonusPercent) - the
    strongest pet worn, which is why the server's Best keeps it. Fusion is free:
    three of a kind -> Golden x1.5 -> Diamond x2 -> Void x3.

  * THE HALLOWEEN PASS IS FREE MONEY. ClaimHalloweenPass(nil) claimed 11 free tiers
    at once: wins 15 -> 265, skill to 65K, a pet and potions. Candy is not spent -
    the tiers follow the candy EARNED. Ghosts pay 300 candy each and are position
    gated (Success=false from the launch zone, true next to the ghost).

  * AURAS LIVE IN A CHAMBER. AuraOpen(token) moves the body there, and only then
    do AuraQuest (the three daily quests, one roll each), AuraRoll(slot) and
    AuraEquip(slot) work - outside it the server answers "Open the aura chamber
    first." A roll replaces the slot it is fired at, a repeat adds a star (three
    stars double the bonus), and after a roll everything is refused for the reveal
    (2.2 - 4 s). Measured: 4 rolls -> Blossom, Ripple, Wrath, then Celestial over
    the weakest slot; AuraClose put the body back on the spot it left.

  * Codes: HALLOWEEN worked (+15 wins, +3.94K skill, 2 potions, an egg). WELCOME,
    5KCCU, 10KCCU, WORLD3, WORLD4 and SECRET from other scripts are all expired.

  * NO HOOKS. Nothing in this file hooks anything; the only listener is
    Event.OnClientEvent, which changes nothing.

  Never spends Robux: the pass stands, Robux eggs (no Wins price), Robux stones,
  skip-rebirth, potion and aura products, auto-wins / auto-rebirth passes and the
  admin actions are never touched.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local MarketplaceService = game:GetService("MarketplaceService")

local plr = Players.LocalPlayer

local GEN = (_G.__STONESKIP or 0) + 1
_G.__STONESKIP = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,

	mode = "Smart",      -- Smart = throw or train, whichever reaches the next purchase first
	rebirth = true,      -- as soon as the level reaches NextRebirthLevel
	rebirthWindow = 60,  -- seconds of throwing allowed at the top to finish a purchase first
	buyStones = true,    -- the best stone of the world, cheapest first
	hatch = true,        -- the best wins egg of the world until its top pet is worn
	trails = true,       -- wins trails, only with twice the price on hand
	winKeep = 0,         -- wins never spent
	equipPets = true,    -- PetEquipment Best whenever a pet arrived
	fuse = true,         -- three of a kind -> Golden -> Diamond -> Void
	deletePets = true,   -- free storage: drops the weakest spares when it is nearly full
	travel = true,       -- unlock the next world with a throw and move there
	invEggs = true,      -- hatch eggs from codes, pass and rewards
	potions = true,      -- drink skill / win / luck / candy potions as they come
	auras = true,        -- daily quests -> aura rolls, roll over the weakest slot, wear the best
	rewards = true,      -- playtime gifts, daily reward, offline skill, pet index
	codes = true,
	halloween = true,    -- free pass tiers and the five ghosts of each world
	antiAfk = true,
}

local CODES = { "HALLOWEEN" }

local STATE = {
	phase = "idle", note = "",
	wins = 0, skill = 0, level = 0, rebirths = 0, needLevel = 0, world = "World1",
	stone = "-", stoneMult = 1, rate = 0, zone = "-", zoneBonus = 0,
	target = "-", targetPrice = 0, plan = "-",
	winMult = 1, throwSecs = 7, lastDistance = 0, lastWins = 0,
	throws = 0, winsGot = 0, rebirthsDone = 0, stonesBought = 0, eggsHatched = 0,
	fused = 0, deleted = 0, ghosts = 0, trailsBought = 0, potionsUsed = 0,
	auraRolls = 0, quests = 0, aura = "-",
	candy = 0, pets = 0, petCap = 0,
	lastNotice = "-",
	petsDirty = true,
}

local function note(t) STATE.note = tostring(t) end

--------------------------------------------------------------------------------
-- references. Every wait carries a timeout: in the wrong place an endless
-- WaitForChild parks whatever loaded this file.
--------------------------------------------------------------------------------

local function wfc(parent, name)
	return parent and parent:WaitForChild(name, 10)
end

-- A require can yield forever; run it behind a wall clock so a hung module
-- costs its own feature and nothing else.
local function safeRequire(mod)
	if not mod then return nil end
	local done, res = false, nil
	task.spawn(function()
		pcall(function() res = require(mod) end)
		done = true
	end)
	local t = 0
	while not done and t < 8 do task.wait(0.1); t = t + 0.1 end
	return res
end

local Net = wfc(ReplicatedStorage, "SkippingNetwork")
local Request = wfc(Net, "Request")
local Event = wfc(Net, "Event")
local Shared = wfc(ReplicatedStorage, "Shared")
local SharedConfig = wfc(Shared, "Config")
local SharedUtil = wfc(Shared, "Util")

local Balance = safeRequire(wfc(SharedConfig, "GameBalance"))
local Worlds = safeRequire(wfc(SharedConfig, "Worlds"))
local HalloweenCfg = safeRequire(SharedConfig and SharedConfig:FindFirstChild("Halloween"))
local Progression = safeRequire(wfc(SharedUtil, "Progression"))
local LaunchZone = safeRequire(wfc(SharedUtil, "LaunchZone"))
local PetCatalog = safeRequire(SharedUtil and SharedUtil:FindFirstChild("PetCatalog"))
local AuraRollCfg = safeRequire(SharedConfig and SharedConfig:FindFirstChild("AuraRoll"))
local AuraInv = safeRequire(SharedUtil and SharedUtil:FindFirstChild("AuraInventory"))
local DailyQuests = safeRequire(SharedUtil and SharedUtil:FindFirstChild("DailyQuests"))

local function fire(action, payload)
	if not Request then return false end
	return pcall(function() Request:FireServer(action, payload) end)
end

--------------------------------------------------------------------------------
-- the game's controller and its profile. Found by CONTENT, never by upvalue
-- index: the table that owns both BeginThrow and RedeemCode, the function
-- upvalue of BeginThrow that is canThrow, the table upvalue of canThrow that
-- holds TotalSkill.
--------------------------------------------------------------------------------

local CTRL, CAN, HUD, PROF_I

local function findCtrl()
	if CTRL and type(rawget(CTRL, "BeginThrow")) == "function" and CAN and PROF_I then return CTRL end
	CTRL, CAN, HUD, PROF_I = nil, nil, nil, nil
	if not getgc or not debug or not debug.getupvalue then return nil end
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and type(rawget(t, "BeginThrow")) == "function"
			and type(rawget(t, "RedeemCode")) == "function" then
			CTRL = t
			break
		end
	end
	if not CTRL then return nil end
	for i = 1, 16 do
		local ok, v = pcall(debug.getupvalue, CTRL.BeginThrow, i)
		if not ok then break end
		if type(v) == "function" and not CAN then CAN = v end
		if type(v) == "table" and not HUD then
			local okM, m = pcall(function() return v.IsModalOpen end)
			if okM and type(m) == "function" then HUD = v end
		end
	end
	if CAN then
		for i = 1, 16 do
			local ok, v = pcall(debug.getupvalue, CAN, i)
			if not ok then break end
			if type(v) == "table" and v.TotalSkill ~= nil and v.Rebirths ~= nil then PROF_I = i break end
		end
	end
	if not (CAN and PROF_I) then CTRL = nil end
	return CTRL
end

local function prof()
	if not findCtrl() then return nil end
	local ok, p = pcall(debug.getupvalue, CAN, PROF_I)
	if ok and type(p) == "table" and p.TotalSkill ~= nil then return p end
	CTRL = nil
	return nil
end

local function activity()
	return plr:GetAttribute("SkippingActivity") or "Idle"
end

local function serverNow()
	local ok, t = pcall(function() return Workspace:GetServerTimeNow() end)
	return ok and t or os.time()
end

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function short(n)
	n = tonumber(n) or 0
	local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 1
	while math.abs(n) >= 1000 and i < #units do
		n = n / 1000
		i = i + 1
	end
	if i == 1 then return tostring(math.floor(n + 0.5)) end
	return string.format("%.2f%s", n, units[i])
end

local function body()
	local c = plr.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if not (hrp and hum and hum.Health > 0) then return nil end
	return hrp, hum, c
end

local function moveTo(pos)
	local hrp = body()
	if not hrp then return false end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = CFrame.new(pos)
	return true
end

local function worldId()
	return plr:GetAttribute("SkippingWorld") or "World1"
end

local function worldDef()
	return Worlds and Worlds.ById and Worlds.ById[worldId()]
end

local function worldModel()
	local f = Workspace:FindFirstChild("SkippingWorlds")
	return f and f:FindFirstChild(worldId())
end

local function stopPractice()
	if activity() ~= "Practice" then return end
	fire("StopPractice", nil)
	local t = 0
	while activity() == "Practice" and t < 2 do task.wait(0.1); t = t + 0.1 end
	STATE.zone = "-"
end

local StoneById = {}
for _, s in ipairs(Balance and Balance.Stones or {}) do StoneById[s.Id] = s end

local catalog
local function petInfo(petId)
	if catalog == nil and PetCatalog and Balance then
		local ok, c = pcall(function()
			return PetCatalog.Read(ReplicatedStorage.Assets.Pets, Balance.PetFusion)
		end)
		catalog = ok and c or false
	end
	return catalog and catalog.ById and catalog.ById[petId]
end

-- The game's own valuation. A "relative" pet (the pass's Trick Bat) has no
-- power of its own: it is the best fixed pet x (1 + BestPetBonusPercent), so
-- its 1.3 in the catalog makes it the STRONGEST pet worn, not the weakest.
local function powerOf(P)
	local best = 1
	if PetCatalog and PetCatalog.BestFixedPower and catalog and catalog.ById then
		pcall(function() best = PetCatalog.BestFixedPower(P.Pets or {}, catalog.ById) end)
	end
	return function(pet)
		local info = pet and petInfo(pet.PetId)
		if not info then return 0 end
		if PetCatalog and PetCatalog.Power then
			local ok, v = pcall(PetCatalog.Power, info, best, pet)
			if ok and tonumber(v) then return tonumber(v) end
		end
		return tonumber(info.SkillMultiplier) or 0
	end
end

local function maxFusionMult()
	local m = 1
	for _, v in pairs((Balance and Balance.PetFusion and Balance.PetFusion.PowerMultipliers) or {}) do
		m = math.max(m, tonumber(v) or 1)
	end
	return m
end

--------------------------------------------------------------------------------
-- the numbers the Smart mode plans with
--------------------------------------------------------------------------------

local function milestones()
	local wd = worldDef()
	return (wd and wd.Throw and wd.Throw.DistanceMilestones)
		or (Balance and Balance.Throw.DistanceMilestones) or {}
end

-- THE DISTANCE DOES NOT FOLLOW THE LEVEL ON SCREEN. Each world turns TotalSkill
-- into its own THROW level through World.Throw.Progression (World 1 quadratic
-- 0.09, World 2 linear 1M per level), and the milestones are in those levels.
-- Measured: level 150 on screen, throw level 1655, 4,640 studs (the portal) -
-- interpolating the screen level gave 1,674. Level 22 only matched because
-- both curves happen to sit near 22 at 334 skill.
local function throwProg()
	local wd = worldDef()
	return (wd and wd.Throw and wd.Throw.Progression) or (Balance and Balance.Throw.Progression)
end

local function throwLevelAt(skill)
	local prog = throwProg()
	if not (Progression and prog) then return 1 end
	local ok, L = pcall(Progression.Get, skill, prog)
	return ok and tonumber(L) or 1
end

local function skillForThrowLevel(level)
	local prog = throwProg()
	if not (Progression and prog) then return math.huge end
	local ok, v = pcall(Progression.Threshold, level, prog)
	return ok and tonumber(v) or math.huge
end

-- the throw level interpolated between the milestones, as Trajectory.Plan does it
local function distanceAt(level)
	local wd = worldDef()
	local base = (wd and wd.Throw and wd.Throw.BaseDistance) or (Balance and Balance.Throw.BaseDistance) or 100
	local pl, pd = 1, base
	for _, m in ipairs(milestones()) do
		if level <= m.Level then
			return pd + (m.Distance - pd) * (level - pl) / math.max(1, m.Level - pl)
		end
		pl, pd = m.Level, m.Distance
	end
	return pd
end

local function zoneWinsAt(distance)
	local wd = worldDef()
	local zones = (wd and wd.Zones) or (Balance and Balance.Zones) or {}
	local last = 1
	for _, z in ipairs(zones) do
		if distance >= z.Start and distance < z.Finish then return z.Wins end
		last = z.Wins
	end
	return last
end

local function winsAtSkill(skill)
	return zoneWinsAt(distanceAt(throwLevelAt(skill))) * STATE.winMult
end

-- the skill the level on screen (rebirth gate) needs
local function threshold(level)
	if not (Progression and Balance) then return math.huge end
	local ok, v = pcall(Progression.Threshold, level, Balance.Progression)
	return ok and v or math.huge
end

local function levelAt(skill)
	if not (Progression and Balance) then return 0 end
	local ok, L = pcall(Progression.Get, skill, Balance.Progression)
	return ok and tonumber(L) or 0
end

-- TrainingRate is the server's figure for the best open stand; the stand loses
-- ~14% of it to the pause between two practice skims (48.3 of 54.7, 93.6 of 109).
local function trainRate(P)
	return math.max(1e-6, (tonumber(P.TrainingRate) or 1) * 0.86)
end

--------------------------------------------------------------------------------
-- what the wins are for. Strict order: stone, egg, trail - the stone is the
-- skill multiplier, and a cheap frequent purchase must never starve it.
--------------------------------------------------------------------------------

local function spendable(P)
	return (tonumber(P.Wins) or 0) - CONFIG.winKeep
end

local function nextStone(P)
	local wd = worldDef()
	if not (wd and wd.StoneIds) then return nil end
	local worn = StoneById[P.EquippedStone]
	local wornMult = worn and worn.Multiplier or 1
	local owned = P.OwnedStones or {}
	for _, id in ipairs(wd.StoneIds) do
		local s = StoneById[id]
		if s and not owned[id] and (tonumber(s.Price) or 0) > 0 and s.Multiplier > wornMult then
			return s
		end
	end
	return nil
end

local function bestOwnedStone(P)
	local best
	for id in pairs(P.OwnedStones or {}) do
		local s = StoneById[id]
		if s and (not best or s.Multiplier > best.Multiplier) then best = s end
	end
	return best
end

local function weakestWorn(P)
	local worn, weakest, n = {}, math.huge, 0
	local power = powerOf(P)
	for _, id in ipairs(P.EquippedPets or {}) do worn[id] = true end
	for _, pet in ipairs(P.Pets or {}) do
		if worn[pet.Id] then
			n = n + 1
			weakest = math.min(weakest, power(pet))
		end
	end
	local limit = tonumber(P.PetEquipLimit) or 3
	if n < limit then weakest = 0 end
	return weakest, worn, power
end

-- Wins eggs of this world, cheapest first. An egg is FINISHED once every worn
-- pet beats the best pet it can still lead to: its top normal pet fused all the
-- way up (Void x3). Below that, every extra copy of the top pet is a fusion
-- input, so hatching on is real progress.
local function eggList()
	local list = {}
	local m = worldModel()
	local shop = m and m:FindFirstChild("EggShop")
	local disp = shop and shop:FindFirstChild("Displays")
	if not disp then return list end
	for _, egg in ipairs(disp:GetChildren()) do
		local price = tonumber(egg:GetAttribute("Wins"))
		if price and price > 0 then
			local top = 0
			local pool = catalog and catalog.Eggs and catalog.Eggs[egg.Name]
			for _, p in ipairs(type(pool) == "table" and pool or {}) do
				if (p.Variant or "Normal") == "Normal" then top = math.max(top, tonumber(p.SkillMultiplier) or 0) end
			end
			list[#list + 1] = { id = egg.Name, price = price, top = top, model = egg }
		end
	end
	table.sort(list, function(a, b) return a.price < b.price end)
	return list
end

local function nextEgg(P)
	petInfo("")
	local weakest = weakestWorn(P)
	local reach = maxFusionMult()
	local pick
	for _, e in ipairs(eggList()) do
		if e.top == 0 or e.top * reach > weakest then pick = e end
	end
	return pick
end

local function nextTrail(P)
	local owned = P.OwnedTrails or {}
	local worn
	for _, t in ipairs(Balance and Balance.Trails or {}) do
		if t.Id == P.EquippedTrail then worn = t end
	end
	local wornMult = worn and worn.WinsMultiplier or 1
	for _, t in ipairs(Balance and Balance.Trails or {}) do
		if (tonumber(t.ProductId) or 0) == 0 and (tonumber(t.Price) or 0) > 0
			and not owned[t.Id] and (t.WinsMultiplier or 1) > wornMult then
			return t
		end
	end
	return nil
end

-- A trail is a wins multiplier, so it jumps the egg queue while it costs at
-- most this many minutes of throwing at the top of the rebirth cycle. Without
-- that the eggs starve it for good: the Rare egg is only finished after
-- dozens of hatches. Under one minute it jumps the stones too - in World 2 the
-- 750K Red trail is a few seconds of throwing and waited behind every stone.
local TRAIL_MINUTES = 10

-- the purchase the next wins go to, with its price
local function target(P)
	local trail = CONFIG.trails and nextTrail(P)
	local trailSecs = math.huge
	if trail then
		local ref = tonumber(P.TotalSkill) or 0
		if CONFIG.rebirth then ref = math.max(ref, threshold(tonumber(P.NextRebirthLevel) or 0)) end
		local perSec = winsAtSkill(ref) / math.max(1, STATE.throwSecs)
		trailSecs = trail.Price / math.max(1e-9, perSec)
		if trailSecs <= 60 then
			return { kind = "trail", name = trail.Name, price = trail.Price, item = trail }
		end
	end
	if CONFIG.buyStones then
		local s = nextStone(P)
		if s then return { kind = "stone", name = s.Name, price = s.Price, item = s } end
	end
	if trail and trailSecs <= 60 * TRAIL_MINUTES then
		return { kind = "trail", name = trail.Name, price = trail.Price, item = trail }
	end
	if CONFIG.hatch then
		local e = nextEgg(P)
		if e then
			local count = math.max(1, tonumber(P.MultiHatchCount) or 1)
			return { kind = "egg", name = e.id .. " egg", price = e.price * count, item = e }
		end
	end
	if trail then return { kind = "trail", name = trail.Name, price = trail.Price, item = trail } end
	return nil
end

-- Throw now, or train to a distance milestone first and throw there? Both are
-- timed to the purchase; the cheaper one wins. Everything is in SKILL, because
-- the distance follows the world's throw level and the rebirth follows the
-- level on screen - two curves over the same number. With rebirth on, the skill
-- never passes what NextRebirthLevel needs, so the plan stops there.
local function plan(P, price)
	local skill = tonumber(P.TotalSkill) or 0
	local need = price - spendable(P)
	if need <= 0 then return "buy", skill, 0 end
	local T = STATE.throwSecs
	local r = trainRate(P)
	local best = need / math.max(1e-9, winsAtSkill(skill) / T)
	local choice, at = "throw", skill
	local cap = math.huge
	if CONFIG.rebirth then cap = threshold(tonumber(P.NextRebirthLevel) or math.huge) end
	local stops = {}
	local tl = throwLevelAt(skill)
	for _, m in ipairs(milestones()) do
		if m.Level > tl then
			local s = skillForThrowLevel(m.Level)
			if s <= cap then stops[#stops + 1] = s end
		end
	end
	if cap < math.huge and cap > skill then stops[#stops + 1] = cap end
	for _, s in ipairs(stops) do
		local t = (s - skill) / r + need / math.max(1e-9, winsAtSkill(s) / T)
		if t < best then best, choice, at = t, "train", s end
	end
	return choice, at, best
end

local function portalReachable(P)
	local wd = worldDef()
	if not (wd and wd.NextWorldId) or P[wd.NextWorldId .. "Unlocked"] then return false end
	local ms = milestones()
	local last = ms[#ms]
	return last ~= nil and throwLevelAt(tonumber(P.TotalSkill) or 0) >= last.Level
end

--------------------------------------------------------------------------------
-- server events: the only listener, it changes nothing
--------------------------------------------------------------------------------

local lastFinish = nil
local auraResult = nil -- the last AuraResult carrying our own chamber token
local special = {}   -- throw id -> true for the secret / colossus / rarest / knock rolls
STATE.throwLog = {}

local function onEvent(name, p)
	if type(p) ~= "table" then return end
	local mine = p.UserId == plr.UserId
	if name == "ThrowStarted" and mine and p.Id then
		special[p.Id] = (p.Secret or p.Colossus or p.Rarest or p.Knock) and true or nil
	elseif name == "ThrowFinished" and mine then
		lastFinish = p
		local d, w = tonumber(p.Distance) or 0, tonumber(p.Wins) or 0
		STATE.lastDistance, STATE.lastWins = d, w
		local base = zoneWinsAt(d)
		local rare = special[p.Id]
		special[p.Id] = nil
		table.insert(STATE.throwLog, 1, string.format("%d studs  %s wins  base %s%s", d, short(w), short(base), rare and "  (secret)" or ""))
		if #STATE.throwLog > 10 then table.remove(STATE.throwLog) end
		-- a secret throw carries its own wins multiplier and would inflate the plan
		if base > 0 and w > 0 and not rare then
			STATE.winMult = STATE.winMult * 0.6 + (w / base) * 0.4
		end
	elseif name == "Notice" and p.Message then
		STATE.lastNotice = tostring(p.Message)
	elseif name == "HalloweenPassResult" then
		if p.Success and p.Message then STATE.lastNotice = tostring(p.Message) end
	elseif (name == "CodeResult" or name == "HatchResult"
		or name == "PetEquipmentResult" or name == "GiftRewardResult") and p.Message then
		STATE.lastNotice = tostring(p.Message)
	elseif name == "GhostFound" and p.Success then
		STATE.ghosts = STATE.ghosts + 1
	elseif name == "AuraResult" and STATE.auraToken and p.Token == STATE.auraToken then
		auraResult = p
	end
end

if _G.__STONESKIP_EVT then pcall(function() _G.__STONESKIP_EVT:Disconnect() end) end
if Event then
	_G.__STONESKIP_EVT = Event.OnClientEvent:Connect(function(name, p)
		pcall(onEvent, name, p)
	end)
end

--------------------------------------------------------------------------------
-- throwing
--------------------------------------------------------------------------------

local function launchSpot()
	local m = worldModel()
	local lz = m and m:FindFirstChild("LaunchZone")
	if not (lz and lz:IsA("BasePart")) then return nil end
	return lz.Position + Vector3.new(0, lz.Size.Y / 2 + 3.2, 0)
end

local function inLaunchZone()
	local _, _, c = body()
	if not (c and LaunchZone) then return false end
	local ok, r = pcall(LaunchZone.Contains, c)
	return ok and r == true
end

-- the game's own gate: in the zone, no throw running, cooldown over, no page open
local function canThrow()
	if not (CAN and HUD) then return false end
	local ok, r = pcall(CAN)
	if not (ok and r) then return false end
	local okM, open = pcall(function() return HUD:IsModalOpen() end)
	return not (okM and open)
end

-- The egg reveal (inventory eggs, fusion claims) waits for a click and counts as
-- an open page, so no throw starts behind it. Its results queue up and the next
-- one opens as soon as one closes - EggShopController's own reveal object is
-- reset until the queue is empty. The pets are the server's already; this is
-- only the picture of them.
local EGG_VIEW
local function eggView()
	if EGG_VIEW then return EGG_VIEW end
	local ps = plr:FindFirstChild("PlayerScripts")
	local mod = ps and ps:FindFirstChild("EggShopController", true)
	local ctl = mod and safeRequire(mod)
	if type(ctl) ~= "table" then return nil end
	for _, fname in ipairs({ "BeginInventoryHatch", "RevealPet", "SetState" }) do
		local f = rawget(ctl, fname)
		for i = 1, 20 do
			if type(f) ~= "function" then break end
			local ok, v = pcall(debug.getupvalue, f, i)
			if not ok then break end
			if type(v) == "table" then
				local okR, r = pcall(function() return v.Reset end)
				local okV, rv = pcall(function() return v.Reveal end)
				if okR and type(r) == "function" and okV and type(rv) == "function" then
					EGG_VIEW = v
					return v
				end
			end
		end
	end
	return nil
end

local function endReveal()
	local gui = plr:FindFirstChild("PlayerGui")
	local hud = gui and gui:FindFirstChild("SkippingHUD")
	if not (hud and hud:GetAttribute("HatchActive")) then return end
	local v = eggView()
	if v then pcall(function() v:Reset() end) end
end

local function closePages()
	endReveal()
	pcall(function() HUD:ClosePages() end)
	-- the offline-earnings page has no close button; its free claim hides it
	local gui = plr:FindFirstChild("PlayerGui")
	local hud = gui and gui:FindFirstChild("SkippingHUD")
	local off = hud and hud:FindFirstChild("OfflineEarningsOverlay", true)
	if off and off:IsA("GuiObject") and off.Visible then fire("ClaimOffline", nil) end
end

local function throwOnce()
	if not findCtrl() then note("no game controller (needs getgc)"); task.wait(2); return false end
	stopPractice()
	if not inLaunchZone() then
		local spot = launchSpot()
		if not spot then note("no launch zone in this world"); task.wait(1); return false end
		moveTo(spot)
		task.wait(0.35)
	end
	local t0 = os.clock()
	while not canThrow() do
		if os.clock() - t0 > 8 then note("throw not ready"); return false end
		endReveal()
		if os.clock() - t0 > 1 then closePages() end
		if not inLaunchZone() then local s = launchSpot(); if s then moveTo(s) end end
		task.wait(0.2)
	end
	lastFinish = nil
	local started = os.clock()
	task.spawn(CTRL.BeginThrow)
	local t = 0
	while activity() ~= "Throw" and t < 3 do task.wait(0.1); t = t + 0.1 end
	if activity() ~= "Throw" then note("the server did not start the throw"); return false end
	t = 0
	while activity() == "Throw" and t < 30 and GEN == _G.__STONESKIP do task.wait(0.15); t = t + 0.15 end
	t = 0
	while not lastFinish and t < 1.5 do task.wait(0.1); t = t + 0.1 end
	STATE.throws = STATE.throws + 1
	if lastFinish then STATE.winsGot = STATE.winsGot + (tonumber(lastFinish.Wins) or 0) end
	-- the cycle as the next throw will see it: flight plus the 0.8 s cooldown
	local cycle = os.clock() - started + ((Balance and Balance.Throw.Cooldown) or 0.8)
	STATE.throwSecs = STATE.throwSecs * 0.7 + cycle * 0.3
	return true
end

--------------------------------------------------------------------------------
-- training
--------------------------------------------------------------------------------

local passOwned = {}
local function ownsPass(passId)
	if not passId then return true end
	if passOwned[passId] == nil then
		local ok, r = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(plr.UserId, passId)
		end)
		passOwned[passId] = ok and r == true
	end
	return passOwned[passId]
end

local benched = {}

local function zones(P)
	local wd = worldDef()
	local pr = (wd and wd.Practice) or (Balance and Balance.Practice)
	local m = worldModel()
	local folder = m and m:FindFirstChild("TrainingZones")
	local list = {}
	if not (pr and folder) then return list end
	local reb = tonumber(P.Rebirths) or 0
	local ownedZones = P.OwnedTrainingZones or {}
	for _, z in ipairs(folder:GetChildren()) do
		local stand = z:FindFirstChild("TrainingStand")
		local bonusOf = pr.EventZones and pr.EventZones[z.Name] and pr.EventZones[z.Name].BonusOf
		local bonus = pr.ZoneBonuses[z.Name] or (bonusOf and pr.ZoneBonuses[bonusOf])
		if stand and bonus then
			local need = pr.ZoneRequiredRebirths[z.Name] or 0
			local pass = (not bonusOf) and Balance.TrainingPasses and Balance.TrainingPasses[z.Name]
			local usable = reb >= need and (not pass or ownedZones[z.Name] or ownsPass(pass))
			if usable and (benched[z.Name] or 0) < os.clock() then
				list[#list + 1] = { name = z.Name, bonus = bonus, stand = stand }
			end
		end
	end
	table.sort(list, function(a, b) return a.bonus > b.bonus end)
	return list
end

-- Stand on the best open stand and wait until the server is practising there.
-- A stand that does not start in 4 s is benched for two minutes.
local function ensureTraining(P)
	local list = zones(P)
	local z = list[1]
	if not z then note("no training stand in this world"); return false end
	if activity() == "Practice" and STATE.zone == z.name then return true end
	stopPractice()
	local top = z.stand.Position + Vector3.new(0, z.stand.Size.Y / 2 + 3, 0)
	-- entered fresh: straight from one stand onto another starts nothing
	moveTo(top + Vector3.new(7, 0, 0))
	task.wait(0.35)
	moveTo(top)
	local t = 0
	while activity() ~= "Practice" and t < 4 do task.wait(0.1); t = t + 0.1 end
	if activity() ~= "Practice" then
		benched[z.name] = os.clock() + 120
		note("stand " .. z.name .. " did not start, benched 2 min")
		return false
	end
	STATE.zone = z.name
	STATE.zoneBonus = z.bonus
	return true
end

local function trainFor(secs)
	local P = prof()
	if not P then return end
	if not ensureTraining(P) then task.wait(1); return end
	local t = 0
	while t < secs and CONFIG.auto and GEN == _G.__STONESKIP do
		if activity() ~= "Practice" then
			STATE.zone = "-"
			return
		end
		task.wait(0.5)
		t = t + 0.5
	end
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

local hatchId = math.random(100000, 900000)

local function hatchShop(P, egg)
	local count = math.max(1, tonumber(P.MultiHatchCount) or 1)
	count = math.min(count, math.floor(spendable(P) / egg.price))
	if count < 1 then return false end
	local anchor = egg.model:FindFirstChild("PromptAnchor", true)
	local pos = (anchor and anchor:IsA("Attachment")) and anchor.WorldPosition or egg.model:GetPivot().Position
	stopPractice()
	moveTo(pos + Vector3.new(0, 2, 3))
	task.wait(0.4)
	hatchId = hatchId + 1
	local before = #(P.Pets or {})
	fire("HatchEgg", { EggId = egg.id, Count = count, RequestId = hatchId })
	local t = 0
	while t < 3 do
		task.wait(0.2); t = t + 0.2
		local Q = prof()
		if Q and #(Q.Pets or {}) > before then break end
	end
	STATE.eggsHatched = STATE.eggsHatched + count
	STATE.petsDirty = true
	-- the server's hatch cooldown runs per pet: back to back it answered
	-- "Please wait before hatching again."
	task.wait(((PetCatalog and PetCatalog.HatchCooldown) or 0.75) * count + 0.3)
	return true
end

-- Every purchase that is affordable right now, in the strict order.
local function buyPass()
	local bought = false
	for _ = 1, 6 do
		local P = prof()
		if not P then return bought end
		local best = bestOwnedStone(P)
		if best and best.Id ~= P.EquippedStone then
			fire("Equip", best.Id)
			task.wait(0.4)
		end
		local tg = target(P)
		if not tg or tg.price > spendable(P) then return bought end
		if tg.kind == "stone" then
			stopPractice()
			fire("Buy", tg.item.Id)
			task.wait(0.6)
			local Q = prof()
			if Q and (Q.OwnedStones or {})[tg.item.Id] then
				STATE.stonesBought = STATE.stonesBought + 1
				note("bought " .. tg.name)
			else
				note("stone refused: " .. STATE.lastNotice)
				return bought
			end
		elseif tg.kind == "egg" then
			if not hatchShop(P, tg.item) then return bought end
		elseif tg.kind == "trail" then
			stopPractice()
			fire("BuyTrail", { Id = tg.item.Id, Equipped = true })
			task.wait(0.8)
			local Q = prof()
			if Q and (Q.OwnedTrails or {})[tg.item.Id] then
				STATE.trailsBought = STATE.trailsBought + 1
				if Q.EquippedTrail ~= tg.item.Id then fire("SetTrail", { Id = tg.item.Id, Equipped = true }) end
				note("bought " .. tg.name)
			else
				note("trail refused: " .. STATE.lastNotice)
				return bought
			end
		end
		bought = true
	end
	return bought
end

--------------------------------------------------------------------------------
-- pets: seat the best, fuse spares, free storage
--------------------------------------------------------------------------------

local FUSE_NEXT = { Normal = "Golden", Golden = "Diamond", Diamond = "Void" }

local function fusePass()
	local P = prof()
	if not (P and catalog) then return end
	local now = serverNow()
	for variant, run in pairs(P.PetFusions or {}) do
		if type(run) == "table" and (tonumber(run.EndsAt) or math.huge) <= now then
			fire("PetEquipment", { Kind = "ClaimFusion", Variant = variant })
			STATE.petsDirty = true
			task.wait(0.6)
		end
	end
	P = prof()
	if not P then return end
	local running = P.PetFusions or {}
	local enabled = (Balance.PetFusion and Balance.PetFusion.EnabledVariants) or {}
	local need = (PetCatalog and PetCatalog.FusionPets) or 3
	local _, worn = weakestWorn(P)
	local groups = {}
	for _, pet in ipairs(P.Pets or {}) do
		local info = petInfo(pet.PetId)
		local tgt = info and FUSE_NEXT[info.Variant or "Normal"]
		if tgt and enabled[tgt] and not running[tgt] and not worn[pet.Id] and not pet.Locked
			and not (tgt == "Golden" and info.FusionEligible == false) then
			local key = pet.PetId
			groups[key] = groups[key] or { variant = tgt, ids = {} }
			if #groups[key].ids < need then table.insert(groups[key].ids, pet.Id) end
		end
	end
	local used = {}
	for _, g in pairs(groups) do
		if #g.ids >= need and not used[g.variant] then
			used[g.variant] = true
			fire("PetEquipment", { Kind = "Fuse", Variant = g.variant, Ids = g.ids })
			STATE.fused = STATE.fused + 1
			task.wait(0.8)
		end
	end
end

-- Only when storage is nearly full: drop spare NORMAL pets weaker than the
-- weakest worn one, but never one that still has fusion partners.
local function deletePass()
	local P = prof()
	if not (P and catalog) then return end
	local cap = tonumber(P.PetCapacity) or 200
	local pets = P.Pets or {}
	if #pets < cap - 10 then return end
	local weakest, worn, power = weakestWorn(P)
	local same = {}
	for _, pet in ipairs(pets) do same[pet.PetId] = (same[pet.PetId] or 0) + 1 end
	local drop = {}
	for _, pet in ipairs(pets) do
		local info = petInfo(pet.PetId)
		if info and (info.Variant or "Normal") == "Normal" and not info.BestPetBonusPercent
			and not worn[pet.Id] and not pet.Locked
			and power(pet) < weakest and (same[pet.PetId] or 0) < 3 then
			drop[#drop + 1] = pet.Id
			if #drop >= 40 then break end
		end
	end
	if #drop > 0 then
		fire("PetEquipment", { Kind = "DeleteSelected", Ids = drop })
		STATE.deleted = STATE.deleted + #drop
		task.wait(0.8)
	end
end

local function petPass()
	if CONFIG.fuse then pcall(fusePass) end
	if CONFIG.deletePets then pcall(deletePass) end
	if CONFIG.equipPets and STATE.petsDirty then
		stopPractice()
		if activity() == "Idle" then
			fire("PetEquipment", { Kind = "Best" })
			STATE.petsDirty = false
			task.wait(0.5)
		end
	end
end

--------------------------------------------------------------------------------
-- rewards that need no body
--------------------------------------------------------------------------------

local last = {}
local function every(key, secs)
	if os.clock() - (last[key] or -1e9) < secs then return false end
	last[key] = os.clock()
	return true
end

local codesDone = false

local function rewardPass()
	local P = prof()
	if not P then return end
	local now = serverNow()

	if CONFIG.codes and not codesDone then
		codesDone = true
		for _, c in ipairs(CODES) do fire("RedeemCode", c); task.wait(1.2) end
	end

	if CONFIG.rewards and every("gifts", 20) then
		local g = Balance.GiftRewards
		local claimed = P.GiftClaimed or {}
		local started = tonumber(P.GiftStartedAt) or now
		if now >= (tonumber(P.GiftCooldownUntil) or 0) then
			for i, unlock in ipairs(g.UnlockSeconds) do
				if not (claimed[i] or claimed[tostring(i)]) and now - started >= unlock then
					fire("ClaimGift", i)
					task.wait(0.4)
				end
			end
		end
		if now >= (tonumber(P.DailyNextClaimAt) or math.huge) then
			local n = #Balance.DailyRewards.Rewards
			fire("ClaimDaily", { Day = (tonumber(P.DailyClaimed) or 0) % n + 1, Cycle = P.DailyCycle or 0 })
		end
		if (tonumber(P.OfflineSkill) or 0) > 0 then fire("ClaimOffline", nil) end
		-- the pet index: reveal every new entry, then claim each 10-pet milestone
		-- mark 1 is found but not revealed, and only revealed entries count:
		-- claiming on the raw total answered "Reveal more pets to earn luck."
		local pending, count = {}, 0
		for petId, mark in pairs(P.PetIndex or {}) do
			if mark == 1 then pending[#pending + 1] = petId else count = count + 1 end
		end
		if #pending > 0 then fire("RevealPets", pending); task.wait(0.5) end
		local step = Balance.PetIndex and Balance.PetIndex.MilestoneStep or 10
		if math.floor(count / step) > (tonumber(P.PetIndexClaimed) or 0) then fire("ClaimPetIndex", nil) end
	end

	if CONFIG.invEggs and every("inv", 6) then
		for eggId, n in pairs(P.Eggs or {}) do
			if (tonumber(n) or 0) > 0 then
				fire("HatchInventoryEgg", eggId)
				STATE.eggsHatched = STATE.eggsHatched + 1
				STATE.petsDirty = true
				task.wait(1.2)
				break
			end
		end
	end

	if CONFIG.potions and every("potions", 15) then
		local active = P.BoostExpiresAt or {}
		local unix = os.time()
		for kind, n in pairs(P.Potions or {}) do
			if (tonumber(n) or 0) > 0 and (tonumber(active[kind]) or 0) <= unix then
				fire("UsePotion", kind)
				STATE.potionsUsed = STATE.potionsUsed + 1
				task.wait(0.4)
			end
		end
	end

	if CONFIG.halloween and HalloweenCfg and every("pass", 45) then
		local s = HalloweenCfg.Season
		local open = not s or now < (s.StartsAt + s.Days * 86400 + (s.ClaimSeconds or 0))
		if open then fire("ClaimHalloweenPass", nil) end
	end
end

-- The five ghosts of the current world: 300 candy each, only next to the ghost.
local function ghostPass()
	if not (CONFIG.halloween and HalloweenCfg and HalloweenCfg.Hunt) then return end
	local P = prof()
	if not P then return end
	local h = P.Halloween or {}
	local mask = (h.Ghosts or {})[worldId()] or 0
	local m = worldModel()
	local folder = m and m:FindFirstChild("Halloween") and m.Halloween:FindFirstChild("Ghosts")
	if not folder then return end
	local per = HalloweenCfg.Hunt.PerWorld or 5
	for i = 1, per do
		if (mask // (2 ^ (i - 1))) % 2 == 0 then
			local g = folder:FindFirstChild("Ghost" .. i)
			if g and g:IsA("BasePart") then
				stopPractice()
				moveTo(g.Position + Vector3.new(0, 1, 2))
				task.wait(0.5)
				fire("FindGhost", { World = worldId(), Index = i })
				task.wait(0.6)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- auras. Everything happens inside the aura chamber: AuraOpen(token) moves the
-- body there (Activity "Aura"), AuraQuest / AuraRoll / AuraEquip work only
-- while it is open ("Open the aura chamber first."), AuraClose(token) puts the
-- body back where it stood. The game's own page ignores a token it did not
-- send, so the camera is never touched.
--
-- A roll REPLACES the slot it is fired at; the same aura again adds a star
-- (three stars double its bonus). One slot is worn. So: empty slots first,
-- then always the weakest slot, never the best one, and wear the best. After a
-- roll the server refuses everything for the reveal (2.2 - 4 s, "Wait for your
-- aura to be revealed.") - the Duration it answers with is waited out.
--------------------------------------------------------------------------------

local auraToken = math.random(500000, 900000)

local function auraScore(a, id)
	if not (AuraInv and id and id ~= "") then return 0 end
	local ok, b = pcall(AuraInv.Bonuses, id, math.max(1, AuraInv.Stars(a, id)))
	if not ok then return 0 end
	-- skill flies the stone and wins buy everything; luck and speed barely count
	return b.Skill * b.Win * (1 + (b.Luck - 1) * 0.25) * (1 + (b.Speed - 1) * 0.1)
end

local function questsReady(P)
	if not (DailyQuests and DailyQuests.Quests and P.DailyQuests) then return {} end
	local state = P.DailyQuests
	local okC, cur = pcall(DailyQuests.Current, state, os.time())
	if okC and cur then state = cur end
	local out = {}
	for _, q in ipairs(DailyQuests.Quests) do
		if not (state.Claimed or {})[q.Id] and ((state.Counts or {})[q.Id] or 0) >= q.Goal then
			out[#out + 1] = q.Id
		end
	end
	return out
end

local function auraSlots(P)
	local a = P.Auras
	local best, bestScore, open = 0, -1, {}
	for i = 1, (AuraRollCfg and AuraRollCfg.Slots) or 6 do
		local okU, unlocked = pcall(AuraInv.IsUnlocked, a, i, P)
		if okU and unlocked then
			open[#open + 1] = i
			local s = auraScore(a, a.Slots[i])
			if (a.Slots[i] or "") ~= "" and s > bestScore then best, bestScore = i, s end
		end
	end
	return open, best
end

local function auraWork(P)
	if not (AuraInv and P and P.Auras) then return false end
	if #questsReady(P) > 0 then return true end
	local okR, canRoll = pcall(AuraInv.CanRoll, P.Auras)
	if okR and canRoll then return true end
	local _, best = auraSlots(P)
	return best > 0 and P.Auras.Equipped ~= best
end

local function auraSend(action, payload, timeout)
	auraResult = nil
	fire(action, payload)
	local t = 0
	while not (auraResult and auraResult.Action == action) and t < (timeout or 5) do
		task.wait(0.1); t = t + 0.1
	end
	return auraResult and auraResult.Action == action and auraResult or nil
end

local function auraPass()
	local P = prof()
	if not (CONFIG.auras and auraWork(P)) then return end
	stopPractice()
	local t = 0
	while activity() ~= "Idle" and t < 4 do task.wait(0.2); t = t + 0.2 end
	if activity() ~= "Idle" then return end
	auraToken = auraToken + 1
	STATE.auraToken = auraToken
	local r = auraSend("AuraOpen", auraToken, 6)
	if not (r and r.Success) then
		note("aura chamber refused: " .. tostring(r and r.Message or "no answer"))
		return
	end
	STATE.phase = "auras"
	for _, id in ipairs(questsReady(prof() or P)) do
		local q = auraSend("AuraQuest", id, 4)
		if q and q.Success then STATE.quests = STATE.quests + 1 end
	end
	for _ = 1, 30 do
		P = prof()
		if not P then break end
		local okR, canRoll = pcall(AuraInv.CanRoll, P.Auras)
		if not (okR and canRoll) then break end
		local open, best = auraSlots(P)
		local target, worst = nil, math.huge
		for _, i in ipairs(open) do
			local empty = (P.Auras.Slots[i] or "") == ""
			if empty or (i ~= best and not AuraInv.IsLocked(P.Auras, i)) then
				local s = empty and -1 or auraScore(P.Auras, P.Auras.Slots[i])
				if s < worst then target, worst = i, s end
			end
		end
		if not target then break end
		local res = auraSend("AuraRoll", target, 5)
		if res and res.Success then
			STATE.auraRolls = STATE.auraRolls + 1
			local roll = res.Roll or {}
			task.wait((tonumber(roll.Duration) or 4) + 0.6)
		elseif res and tostring(res.Message):find("revealed") then
			task.wait(1.5)
		else
			note("aura roll refused: " .. tostring(res and res.Message or "no answer"))
			break
		end
	end
	P = prof()
	if P then
		local _, best = auraSlots(P)
		if best > 0 and P.Auras.Equipped ~= best then
			for _ = 1, 4 do
				local res = auraSend("AuraEquip", best, 4)
				if res and res.Success then break end
				task.wait(1.5)
			end
		end
	end
	auraSend("AuraClose", auraToken, 6)
	t = 0
	while activity() == "Aura" and t < 5 do task.wait(0.2); t = t + 0.2 end
	STATE.auraToken = nil
	STATE.zone = "-"
end

--------------------------------------------------------------------------------
-- world travel and rebirth
--------------------------------------------------------------------------------

local function travelPass(P)
	local wd = worldDef()
	local nextId = wd and wd.NextWorldId
	if not (nextId and P[nextId .. "Unlocked"]) then return false end
	-- the next world's first zone already pays more than this world's last
	stopPractice()
	fire("TravelWorld", nextId)
	local t = 0
	while worldId() ~= nextId and t < 10 do task.wait(0.25); t = t + 0.25 end
	if worldId() == nextId then
		note("travelled to " .. nextId)
		STATE.zone = "-"
		task.wait(1)
		return true
	end
	note("travel to " .. nextId .. " refused: " .. STATE.lastNotice)
	return false
end

local function rebirthNow(P)
	stopPractice()
	local before = tonumber(P.Rebirths) or 0
	fire("Rebirth", before)
	local t = 0
	while t < 3 do
		task.wait(0.25); t = t + 0.25
		local Q = prof()
		if Q and (tonumber(Q.Rebirths) or 0) > before then
			STATE.rebirthsDone = STATE.rebirthsDone + 1
			note("rebirth " .. (before + 1))
			STATE.zone = "-"
			return true
		end
	end
	note("rebirth refused: " .. STATE.lastNotice)
	return false
end

--------------------------------------------------------------------------------
-- one cycle of the farm. One body, one owner.
--------------------------------------------------------------------------------

local function refresh()
	local P = prof()
	if not P then return nil end
	STATE.wins = tonumber(P.Wins) or 0
	STATE.skill = tonumber(P.TotalSkill) or 0
	STATE.level = tonumber(P.Level) or 0
	STATE.rebirths = tonumber(P.Rebirths) or 0
	STATE.needLevel = tonumber(P.NextRebirthLevel) or 0
	STATE.rate = tonumber(P.TrainingRate) or 0
	STATE.world = worldId()
	local s = StoneById[P.EquippedStone]
	STATE.stone = s and s.Name or tostring(P.EquippedStone)
	STATE.stoneMult = s and s.Multiplier or 1
	STATE.pets = #(P.Pets or {})
	STATE.petCap = tonumber(P.PetCapacity) or 0
	STATE.candy = (P.Halloween and tonumber(P.Halloween.Candy)) or 0
	local aura = plr:GetAttribute("SkippingAura")
	STATE.aura = (aura and aura ~= "") and aura or "-"
	local tg = target(P)
	STATE.target = tg and tg.name or "-"
	STATE.targetPrice = tg and tg.price or 0
	return P
end

local function cycle()
	local P = refresh()
	if not P then note("waiting for game data"); task.wait(2); return end

	pcall(rewardPass)

	if CONFIG.travel and travelPass(P) then return end

	if CONFIG.halloween and every("ghosts", 300) then pcall(ghostPass) end
	if CONFIG.auras and every("auras", 60) then pcall(auraPass) end

	pcall(buyPass)
	pcall(petPass)

	P = refresh()
	if not P then return end

	if CONFIG.travel and portalReachable(P) then
		STATE.phase = "throw to the portal"
		throwOnce()
		return
	end

	local tg = target(P)
	local maxReb = Balance and Balance.Rebirth and Balance.Rebirth.MaxRebirths or math.huge
	if CONFIG.rebirth and (tonumber(P.Rebirths) or 0) < maxReb
		and (tonumber(P.Level) or 0) >= (tonumber(P.NextRebirthLevel) or math.huge) then
		-- the top of the cycle pays the most per throw: finish a near purchase first
		if tg and CONFIG.mode ~= "Train" and tg.price > spendable(P) then
			local secs = (tg.price - spendable(P)) / math.max(1e-9, winsAtSkill(tonumber(P.TotalSkill) or 0) / STATE.throwSecs)
			if secs <= CONFIG.rebirthWindow then
				STATE.phase = "throw before rebirth"
				STATE.plan = string.format("%s in ~%ds, then rebirth", tg.name, math.floor(secs))
				throwOnce()
				return
			end
		end
		STATE.phase = "rebirth"
		rebirthNow(P)
		return
	end

	local act, at, secs = "train", P.Level, 0
	if CONFIG.mode == "Throw" then
		act = "throw"
	elseif CONFIG.mode == "Smart" and tg then
		act, at, secs = plan(P, tg.price)
	end

	if act == "throw" then
		STATE.phase = "throw"
		STATE.plan = tg and string.format("throw for %s, ~%ds", tg.name, math.floor(secs)) or "throw"
		throwOnce()
	else
		STATE.phase = "train"
		if tg and act == "train" and at > (tonumber(P.TotalSkill) or 0) then
			STATE.plan = string.format("train to L%d, then throw for %s (~%ds)", levelAt(at), tg.name, math.floor(secs))
		elseif tg and act == "buy" then
			STATE.plan = "buying " .. tg.name
		else
			STATE.plan = "train"
		end
		trainFor(8)
	end
end

--------------------------------------------------------------------------------
-- debug handle, published BEFORE the panel is built
--------------------------------------------------------------------------------

_G.__STONESKIP_DBG = {
	CONFIG = CONFIG, STATE = STATE, CODES = CODES,
	prof = prof, findCtrl = findCtrl, refresh = refresh, cycle = cycle,
	throwOnce = throwOnce, trainFor = trainFor, ensureTraining = ensureTraining, zones = zones,
	plan = plan, target = target, nextStone = nextStone, nextEgg = nextEgg, nextTrail = nextTrail,
	eggList = eggList, winsAtSkill = winsAtSkill, distanceAt = distanceAt, threshold = threshold,
	throwLevelAt = throwLevelAt, skillForThrowLevel = skillForThrowLevel, levelAt = levelAt,
	buyPass = buyPass, petPass = petPass, fusePass = fusePass, deletePass = deletePass,
	rewardPass = rewardPass, ghostPass = ghostPass, travelPass = travelPass, rebirthNow = rebirthNow,
	stopPractice = stopPractice, fire = fire, endReveal = endReveal, eggView = eggView,
	weakestWorn = weakestWorn, auraPass = auraPass, questsReady = questsReady, auraScore = auraScore,
}

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

task.spawn(function()
	while GEN == _G.__STONESKIP do
		pcall(refresh)
		task.wait(1)
	end
end)

task.spawn(function()
	while GEN == _G.__STONESKIP do
		if CONFIG.auto then
			local ok, err = pcall(cycle)
			if not ok then note("cycle failed: " .. tostring(err)); task.wait(1) end
		else
			STATE.phase = "idle"
			task.wait(0.5)
		end
	end
end)

-- anti-AFK: the farm runs for hours without input
pcall(function()
	if _G.__STONESKIP_IDLE then _G.__STONESKIP_IDLE:Disconnect() end
	local VirtualUser = game:GetService("VirtualUser")
	_G.__STONESKIP_IDLE = plr.Idled:Connect(function()
		if not CONFIG.antiAfk then return end
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

-- UI.sweep pcalls each container on its own; a hand written list has a nil hole
-- that stops ipairs, and on some executors CoreGui THROWS rather than returning.
if UI.sweep then pcall(function() UI.sweep("StoneSkippingPanel") end) end

UI.config("stoneskipping", CONFIG)

local win = UI.Window({
	name = "StoneSkippingPanel",
	title = "STONE",
	accentTitle = "SKIPPING",
	subtitle = "seltonmt",
})

local farm = win:Page("FARM", UI.icon.wave)

local loopCard = farm:Card("LOOP", 1):Accent()
loopCard:Dropdown("Farm mode", { "Smart", "Train", "Throw" }, CONFIG.mode, function(v) CONFIG.mode = v end)
loopCard:Label("Smart times both ways to the next purchase: throw now, or train to the next distance zone first and throw there.")
loopCard:Toggle("Rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"At the level the game asks for. Resets level and skill; wins and stones stay.")
loopCard:Slider("Throw before rebirth (s)", 0, 300, CONFIG.rebirthWindow, function(v) CONFIG.rebirthWindow = v end)
loopCard:Toggle("Travel to the next world", CONFIG.travel, function(v) CONFIG.travel = v end,
	"Throws into the portal once the level reaches the last zone, then travels. World 2 pays 30K wins in its first zone.")

local shopCard = farm:Card("WINS", 2):Accent()
shopCard:Toggle("Buy stones", CONFIG.buyStones, function(v) CONFIG.buyStones = v end,
	"The skill multiplier. Always first: nothing else gets wins while a better stone is on sale.")
shopCard:Toggle("Hatch eggs", CONFIG.hatch, function(v) CONFIG.hatch = v end,
	"The best wins egg of the world. Every extra copy of its top pet is fusion material.")
shopCard:Toggle("Buy trails", CONFIG.trails, function(v) CONFIG.trails = v end,
	"Wins multiplier. Under a minute of throwing it goes first, under ten minutes before the eggs.")
shopCard:Stepper("Wins to keep", function() return short(CONFIG.winKeep) end, function(dir)
	local steps = { 0, 100, 1000, 10000, 100000, 1e6, 1e7, 1e8, 1e9, 1e10, 1e12 }
	local i = 1
	for k, v in ipairs(steps) do if v <= CONFIG.winKeep then i = k end end
	i = math.clamp(i + dir, 1, #steps)
	CONFIG.winKeep = steps[i]
end)

local petCard = farm:Card("PETS", 1)
petCard:Toggle("Equip best pets", CONFIG.equipPets, function(v) CONFIG.equipPets = v end)
petCard:Toggle("Fuse pets", CONFIG.fuse, function(v) CONFIG.fuse = v end,
	"Three of a kind -> Golden x1.5 -> Diamond x2 -> Void x3. Worn and locked pets are never used.")
petCard:Toggle("Delete weak pets", CONFIG.deletePets, function(v) CONFIG.deletePets = v end,
	"Only when storage is nearly full: spare normal pets weaker than the weakest worn one.", UI.theme.warn)

local manual = farm:Card("MANUAL", 2)
manual:Button("Throw once", function() task.spawn(function() pcall(throwOnce) end) end)
manual:Button("Buy now", function() task.spawn(function() pcall(buyPass); pcall(petPass) end) end)
manual:Button("Stop training", function() task.spawn(stopPractice) end, UI.theme.bad)
manual:Toggle("Anti-AFK", CONFIG.antiAfk, function(v) CONFIG.antiAfk = v end)

local out = farm:Card("STATUS", 0):Readout(17)

local function standName()
	if STATE.zone == "-" then return "-" end
	local n = STATE.zone:gsub("^TrainingZone_?", "")
	return n == "" and "Basic" or n
end

local extra = win:Page("REWARDS", UI.icon.star)

local rewardCard = extra:Card("REWARDS", 1):Accent()
rewardCard:Toggle("Claim rewards", CONFIG.rewards, function(v) CONFIG.rewards = v end,
	"Playtime gifts, daily reward, offline skill and the pet index milestones.")
rewardCard:Toggle("Hatch reward eggs", CONFIG.invEggs, function(v) CONFIG.invEggs = v end,
	"Eggs from codes, the pass and rewards, straight from the inventory.")
rewardCard:Toggle("Drink potions", CONFIG.potions, function(v) CONFIG.potions = v end,
	"Skill, win, luck and candy potions as soon as the last one ran out.")
rewardCard:Toggle("Redeem codes", CONFIG.codes, function(v) CONFIG.codes = v end,
	"HALLOWEEN - the six codes other scripts list are all expired.")

local eventCard = extra:Card("HALLOWEEN", 2):Accent()
eventCard:Toggle("Halloween event", CONFIG.halloween, function(v) CONFIG.halloween = v end,
	"Claims every free pass tier (candy is not spent) and finds the five ghosts of each world, 300 candy each.")
eventCard:Button("Find ghosts now", function() task.spawn(function() pcall(ghostPass) end) end)
eventCard:Button("Claim pass now", function() fire("ClaimHalloweenPass", nil) end)

local auraCard = extra:Card("AURAS", 1):Accent()
auraCard:Toggle("Auras", CONFIG.auras, function(v) CONFIG.auras = v end,
	"Claims the three daily quests (one roll each), rolls into empty slots and then over the weakest one - never the best - and wears the best aura.")
auraCard:Button("Auras now", function() task.spawn(function() pcall(auraPass) end) end)

task.spawn(function()
	while GEN == _G.__STONESKIP do
		local ok = pcall(function()
			out:set({
				"STATE",
				string.format("  phase      %s", STATE.phase),
				string.format("  plan       %s", STATE.plan),
				string.format("  level      %d / %d for rebirth %d", STATE.level, STATE.needLevel, STATE.rebirths + 1),
				string.format("  world      %s   stand %s (+%s)", STATE.world, standName(), tostring(STATE.zoneBonus)),
				string.format("  skill/s    %s   stone %s x%s", short(STATE.rate), STATE.stone, short(STATE.stoneMult)),
				string.format("  next buy   %s   %s wins", STATE.target, short(STATE.targetPrice)),
				string.format("  per throw  %s wins (throw level %d)   cycle %.1fs   last %s @ %d studs",
					short(winsAtSkill(STATE.skill)), throwLevelAt(STATE.skill), STATE.throwSecs, short(STATE.lastWins), STATE.lastDistance),
				string.format("  pets       %d / %d   candy %s", STATE.pets, STATE.petCap, short(STATE.candy)),
				string.format("  aura       %s   rolled %d   quests %d", STATE.aura, STATE.auraRolls, STATE.quests),
				"SESSION",
				string.format("  throws %d  wins +%s  rebirths %d  stones %d  trails %d",
					STATE.throws, short(STATE.winsGot), STATE.rebirthsDone, STATE.stonesBought, STATE.trailsBought),
				string.format("  eggs %d  fused %d  deleted %d  ghosts %d  potions %d",
					STATE.eggsHatched, STATE.fused, STATE.deleted, STATE.ghosts, STATE.potionsUsed),
				"  last notice " .. STATE.lastNotice,
				STATE.note ~= "" and ("  " .. STATE.note) or "  -",
			})
			win:SetStatus(string.format("%s wins   lv%d   %d rebirths   %s skill/s",
				short(STATE.wins), STATE.level, STATE.rebirths, short(STATE.rate)))
			win:SetStat(1, short(STATE.wins), "wins")
			win:SetStat(2, tostring(STATE.level), "level")
			win:SetStat(3, tostring(STATE.rebirths), "rebirths")
		end)
		if not ok then task.wait(2) end
		task.wait(1)
	end
end)

pcall(function()
	win:SetMaster(CONFIG.auto, "Auto Farm")
	win:OnMaster(function(on)
		CONFIG.auto = on
		if not on then task.spawn(stopPractice) end
		note(on and "auto on" or "auto off")
	end)
end)

pcall(function() win:Home() end)

if not findCtrl() then note("game controller not found yet - it is looked up again every cycle") else note("ready") end
