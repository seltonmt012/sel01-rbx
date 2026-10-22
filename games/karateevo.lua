--[[
    karateevo.lua - "[W4] +1 Karate Evolution"  (Taynx Games)
    world 1 = place 137626413669175, worlds 2-4 = 138352221662770,
    116479409623658, 75301713034794 (separate places, separate saves)

    Measured against server-side values on 2026-10-22, account Lumo_Studios.
    Every remote is named (ReplicatedStorage.Remotes) and the whole economy is
    ReplicatedStorage.Shared.GameConfig, require-able from the client, together
    with the game's own maths: Economy, StrikeState, DuelCore, TrainingZone.

    The loop the game wants:  strike -> Spirit,  Spirit beats the next Master in
    a tug-of-war duel,  the stage's win pad pays Wins,  Wins buy Gis / belts /
    eggs,  a rebirth resets Spirit and Level and unlocks a better dojo.

    What was measured, and what this script therefore does:

    * StrikeBatch:FireServer(n) is the engine.  The server credits at most 20
      strikes per batch and ~20-27 strikes/s overall whatever the send rate
      (300 sent in 3s -> 78 credited, 600 sent -> 81, 120 sent -> 65): a token
      bucket.  So one StrikeBatch(20) every 0.2s is the whole budget.  A strike
      pays exactly StrikeState.value(attributes) - predicted 17, measured 170
      per 10 - and XP is the Spirit earned.
    * A dojo station pays passive Spirit while the body stands inside its zone
      (OnStation attribute), ~32/s on station 1 at x2 strike value, and manual
      strikes ADD to it (86/s combined).  Stations unlock by rebirths; 8, 9 and
      the VIP dojo are Robux passes and the VIP one prompts a purchase on step,
      so only stations without a PassKey are ever stood on.
    * A Master duel is ChallengePrompt (server-side ProximityPrompt in the
      Master's root, 12 studs) -> 3s countdown -> "fight" -> won/lost.  Push per
      strike is DuelCore.pushPerStrike(mySpirit, masterSpirit) against the
      Master's 8 strikes/s.  Stage 2 (500) fell to one batch at 2,104 Spirit,
      stage 3 (2,400) in 0.6s at 2,666.  Spirit is NOT spent by a duel.
    * WINS COME FROM THE FREE WIN PAD, and it pays EVERY touch.  Stage 1 paid
      12 of 12 touches in a row, +Stages[N].Wins each, and the server returns
      the body to spawn after each pay.  The pad of the NEXT stage pays too
      (HighestStageCleared 1 -> stage 2 pad +5): what blocks the deeper pads is
      the barrier, and the server snaps a body that crosses an uncleared one
      back behind it.  So the deepest pad is always HighestStageCleared + 1.
    * The pad has a server-side travel-time check.  Measured as the wait after
      the previous pay before a touch is accepted: stage 1 (77 studs from
      spawn) ~0.9s, stage 2 (108) ~1.2-1.5s, stage 3 (136) ~1.8-2.0s at walk
      speed 16, stage 4 (165) ~2.4s at 17, stage 10 (336) 3.0-3.5s at 25.  It
      fits distance / (3.5 x Economy.walkSpeed) - 0.6, and the x1.5 trail does
      NOT move it (stage 10 measured identical with and without).  A touch
      inside the window pays 0 and leaves the body standing on the pad, where
      no new Touched ever fires.  So the farm waits per stage on the model plus
      a learned correction, and waits ON THE DOJO, which keeps the passive
      Spirit running (station 2: +1,050 Spirit in 2.4s).
    * Gi (BuyGi, wins, auto-equips), belt (Grade, wins) and the eggs are the
      multipliers.  Rebirth (Rebirth, needs LevelCapped) resets ONLY Spirit,
      Level and XP - Wins, Gis, belt, pets and HighestStageCleared all stay.
    * Eggs: HatchEgg(id, "Single"|"Multi") within 16 studs of the egg ("far"
      otherwise).  PetsEquipBest() equips.  Pet mult = 1 + sum(Power) / 100.
    * Codes sit in GameConfig.Codes.  All five redeemed on the first try.
    * Dragon fight (every 30 min, ReplicatedStorage NextArenaEventAt): hit
      detection is CLIENT side - the game's own judge() decides a hit and the
      client reports it with ArenaHit, dodges with ArenaDodge.  Net is a plain
      unfrozen module table, so the script wraps Net.fireServer and drops
      ArenaHit instead of hooking a metamethod.  ArenaJoin teleports the body
      in; the strikes are the damage.  First fight: dragon dead in 26s, top
      damage 535 vs 139, +380 Dragon Spirit (first of the day doubles it).
      Dragon Spirit only buys trails.

    Never touched:  Paid win pads ("robux wins stage N", Paid = true), stations
    with a PassKey, BuyTrailRobux, Purchase, ArenaSkip, every DevProduct,
    AdminAction, DevReset / DevTutorial / DevArenaStart / DevDragonSpirit.
    ClaimTimed never answers (no handler bound) and is only ever fired from a
    guarded thread so it cannot park anything.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

local Shared  = ReplicatedStorage:WaitForChild("Shared", 10)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not (Shared and Remotes and Shared:FindFirstChild("GameConfig") and Remotes:FindFirstChild("StrikeBatch")) then
    warn("[karateevo] GameConfig / StrikeBatch missing - wrong game?")
    return
end

local GameConfig   = require(Shared.GameConfig)
local Economy      = require(Shared.Economy)
local StrikeState  = require(Shared.StrikeState)
local DuelCore     = require(Shared.DuelCore)
local TrainingZone = require(Shared.TrainingZone)
local Net          = require(Shared.Net)

local function remote(name)
    return Remotes:FindFirstChild(name)
end

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    autoStrike   = true,   -- StrikeBatch(20) every strikeGap, the Spirit engine
    autoTrain    = true,   -- stand on the best dojo the rebirths allow
    autoDuel     = true,   -- challenge the next Master once the push maths wins
    autoPads     = true,   -- farm the deepest win pad, waiting on the dojo
    autoGi       = true,   -- next Gi for wins, auto-equipped by the server
    autoBelt     = true,   -- next belt grade for wins
    autoEggs     = true,   -- hatch the best wins egg with a share of the wins
    autoPets     = true,   -- PetsEquipBest after hatching and on a timer
    autoRebirth  = true,   -- resets only Spirit and Level, keeps everything bought
    holdRebirth  = true,   -- finish a Master that is close before rebirthing
    autoRewards  = true,   -- codes, playtime gifts, leave reward
    autoArena    = true,   -- join the dragon fight every 30 minutes
    arenaNoHit   = true,   -- drop the client's own ArenaHit report
    arenaDodge   = true,   -- report a dodge for every attack instead
    autoTrail    = true,   -- fastest trail the Dragon Spirit buys, equipped
    autoWorld    = false,  -- spend 2.5B wins on the next world and move there
    antiAfk      = true,
    strikeGap    = 0.2,    -- seconds between batches
    duelMargin   = 1.3,    -- my push rate must beat the Master's by this
    holdFactor   = 3,      -- hold the rebirth while spirit >= need / this
    eggShare     = 0.25,   -- share of wins an egg batch may use
    padWait      = 0.8,    -- how long a touch is given to pay
}

local STATE = {
    spirit = 0, wins = 0, rebirths = 0, level = 1, levelGate = 10, capped = false,
    hsc = 0, stages = #GameConfig.Stages, padStage = 0, perStrike = 0, passive = 0,
    station = 0, stationLabel = 0, petMult = 1,
    claims = 0, misses = 0, earned = 0, duelsWon = 0, duelsLost = 0,
    rebirthsDone = 0, gis = 0, belts = 0, hatched = 0, codes = 0,
    arenaFights = 0, hitsBlocked = 0, dodges = 0,
    lastPay = 0, home = Vector3.new(0, 4, 0), padAdj = {}, duelPenalty = {},
    saving = 0, startClock = os.clock(), startWins = nil,
    phase = "starting", note = "starting", running = true,
}

_G.__KARATEEVO = (_G.__KARATEEVO or 0) + 1
local GEN = _G.__KARATEEVO
local function alive() return _G.__KARATEEVO == GEN end

-- the learned per-stage corrections to the pad window survive a re-execute;
-- they are a property of the map, not of the run
_G.__KARATEEVO_PADADJ = _G.__KARATEEVO_PADADJ or {}
STATE.padAdj = _G.__KARATEEVO_PADADJ

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

local function abbreviate(n)
    n = tonumber(n) or 0
    local units = { { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
    for _, u in ipairs(units) do
        if n >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
    end
    return string.format("%.0f", n)
end

----------------------------------------------------------------------------
-- oracles.  everything the server knows about the player is an attribute.
----------------------------------------------------------------------------

local function attr(name, fallback)
    local v = LocalPlayer:GetAttribute(name)
    if v == nil then return fallback end
    return v
end

local function spirit()   return tonumber(attr("Spirit", 0)) or 0 end
local function wins()     return tonumber(attr("Wins", 0)) or 0 end
local function rebirths() return tonumber(attr("Rebirths", 0)) or 0 end
local function hsc()      return tonumber(attr("HighestStageCleared", 0)) or 0 end
local function duelPhase() return attr("DuelPhase", "") or "" end
local function inArena()  return attr("ArenaFighting", false) == true end
local function loaded()   return attr("DataLoaded", false) == true end

local function character()
    local char = LocalPlayer.Character
    if not char then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return char, root, hum
end

local function warp(cf)
    local _, root = character()
    if not root then return false end
    if typeof(cf) == "Vector3" then cf = CFrame.new(cf) end
    root.CFrame = cf
    root.AssemblyLinearVelocity = Vector3.zero
    return true
end

-- InvokeServer with a wall-clock cap.  ClaimTimed has no handler on the server
-- and yields forever - a bare invoke of it parked the bridge.  Every call goes
-- through here so a silent remote costs one thread, never the loop.
local function invoke(name, ...)
    local r = remote(name)
    if not r then return false, "missing" end
    local args = table.pack(...)
    local done, result = false, nil
    task.spawn(function()
        result = table.pack(pcall(r.InvokeServer, r, table.unpack(args, 1, args.n)))
        done = true
    end)
    local deadline = os.clock() + 6
    while not done and os.clock() < deadline do task.wait(0.05) end
    if not done then return false, "timeout" end
    if not result[1] then return false, tostring(result[2]) end
    return table.unpack(result, 2, result.n)
end

local function fire(name, ...)
    local r = remote(name)
    if r then r:FireServer(...) end
end

----------------------------------------------------------------------------
-- the map.  everything is tagged, and the whole world 1 map is loaded at once.
----------------------------------------------------------------------------

local function tagged(tag)
    return CollectionService:GetTagged(tag)
end

local function stationSpec(id)
    for _, s in ipairs(GameConfig.Stations) do
        if s.Id == id then return s end
    end
    return nil
end

-- The best dojo the server will let us stand on.  A PassKey means Robux, and
-- the VIP dojo prompts a purchase the moment it is stepped on - so they are
-- filtered by the config, not by a name.
local function bestStation()
    local have = rebirths()
    local best, bestLabel, bestId
    for _, model in ipairs(tagged("Station")) do
        local id = model:GetAttribute("StationId")
        local spec = id and stationSpec(id)
        if spec and not spec.PassKey and (spec.RebirthsRequired or math.huge) <= have then
            local label = spec.Label or 1
            if not bestLabel or label > bestLabel then best, bestLabel, bestId = model, label, id end
        end
    end
    return best, bestLabel or 0, bestId or 0
end

local zoneCache = {}
local function stationCFrame(model)
    local z = zoneCache[model]
    if not z then
        z = TrainingZone.fromModel(model)
        zoneCache[model] = z
    end
    return z and z.CFrame
end

local function goStation()
    if not CONFIG.autoTrain then return false end
    local model = bestStation()
    local cf = model and stationCFrame(model)
    if not cf then return false end
    local _, root = character()
    if not root then return false end
    -- already inside: do not keep re-warping, a fresh warp resets nothing but
    -- it does fight the physics settling on the pad
    if attr("OnStation", 0) ~= 0 and (root.Position - cf.Position).Magnitude < 8 then return true end
    return warp(cf)
end

local function freePads()
    local pads = {}
    for _, model in ipairs(tagged("ClaimPlinth")) do
        local stage = model:GetAttribute("Stage")
        -- Paid = true is the Robux plinth right next to every free one; the name
        -- check is a second lock in case an update renames the attribute.
        if stage and model:GetAttribute("Paid") == false and not model.Name:lower():find("robux") then
            pads[stage] = model
        end
    end
    return pads
end

local function masterModel(stage)
    for _, model in ipairs(tagged("Master")) do
        if model:GetAttribute("Stage") == stage then return model end
    end
    return nil
end

-- the pad of the next stage pays as well; only the barrier behind it blocks
local function targetPadStage()
    return math.min(hsc() + 1, #GameConfig.Stages)
end

----------------------------------------------------------------------------
-- strikes.  one loop, independent of where the body is.
----------------------------------------------------------------------------

task.spawn(function()
    while alive() do
        if CONFIG.autoStrike and STATE.running and loaded() then
            -- the countdown is the one moment strikes are worth holding back:
            -- the server's bucket fills and the first batch of the fight lands
            -- whole instead of the tail end of a spirit batch
            if duelPhase() ~= "countdown" then
                pcall(fire, "StrikeBatch", 20)
            end
        end
        task.wait(CONFIG.strikeGap)
    end
end)

----------------------------------------------------------------------------
-- duels
----------------------------------------------------------------------------

local STRIKE_RATE = 22   -- sustained credited strikes/s, measured 21.7 - 27

local function duelOdds(stage)
    local spec = GameConfig.Stages[stage]
    if not spec then return 0 end
    local me, him = spirit(), spec.Spirit or math.huge
    local mine = STRIKE_RATE * DuelCore.pushPerStrike(me, him)
    local theirs = (GameConfig.Duel.MasterStrikesPerSecond or 8) * DuelCore.pushPerStrike(him, me)
    if theirs <= 0 then return math.huge end
    return mine / theirs
end

local function duelReady()
    local stage = hsc() + 1
    if stage > #GameConfig.Stages then return nil end
    local need = CONFIG.duelMargin + (STATE.duelPenalty[stage] or 0)
    if duelOdds(stage) >= need then return stage end
    return nil
end

local function duel(stage)
    local model = masterModel(stage)
    local root = model and model:FindFirstChild("HumanoidRootPart")
    local prompt = root and root:FindFirstChild("ChallengePrompt")
    if not prompt then note("master %d has no challenge prompt", stage) return false end

    STATE.phase = "duel stage " .. stage
    warp(root.CFrame * CFrame.new(0, 0, -6))
    task.wait(0.45)
    if not prompt.Enabled then
        note("master %d prompt is off (duel already running?)", stage)
        return false
    end
    pcall(fireproximityprompt, prompt)

    local t0 = os.clock()
    while alive() and duelPhase() == "" and os.clock() - t0 < 3 do task.wait(0.1) end
    if duelPhase() == "" then
        note("master %d did not accept the challenge", stage)
        STATE.duelPenalty[stage] = (STATE.duelPenalty[stage] or 0) + 0.2
        return false
    end

    local before = hsc()
    local last = ""
    while alive() and duelPhase() ~= "" and os.clock() - t0 < 100 do
        last = duelPhase()
        task.wait(0.1)
    end

    if hsc() > before then
        STATE.duelsWon = STATE.duelsWon + 1
        STATE.duelPenalty[stage] = nil
        note("beat master %d (%s) in %.1fs", stage, GameConfig.Stages[stage].Master or "?", os.clock() - t0)
        return true
    end
    STATE.duelsLost = STATE.duelsLost + 1
    STATE.duelPenalty[stage] = (STATE.duelPenalty[stage] or 0) + 0.5
    note("lost to master %d (%s) - waiting for more spirit", stage, last)
    return false
end

----------------------------------------------------------------------------
-- win pads
----------------------------------------------------------------------------

-- The server returns the body to the SpawnLocation after every pay, and the
-- window is measured from there.  The first version measured "home" 0.25s
-- after a pay - by then the loop had already warped onto the dojo, the
-- estimate for pad 6 came out at 1.0s instead of ~3.7s and every touch missed.
local function spawnPoint()
    local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
    return spawn and spawn.Position + Vector3.new(0, 3, 0) or STATE.home
end

-- The window is a travel time at the SERVER's walk speed, Economy.walkSpeed
-- (16 + 1 per rebirth) - the trail is ignored.  Six measured points fit
-- T = distance / (3.5 x walkSpeed) - 0.6 (time after the client sees the pay):
-- 77 studs at 16 -> 0.75s, 136 at 16 -> 1.8s, 165 at 17 -> 2.3s, 336 at 25 ->
-- 3.0-3.5s with AND without the x1.5 trail.  So the model carries the rebirths
-- and only a per-stage correction is learned.
local function padDelay(stage, pad)
    local dist = (pad:GetPivot().Position - spawnPoint()).Magnitude
    local ok, ws = pcall(Economy.walkSpeed, rebirths())
    ws = ok and ws or 16
    local adj = STATE.padAdj[stage] or 0.15
    STATE.padAdj[stage] = adj
    return math.max(0.35, dist / (3.5 * ws) - 0.6 + adj)
end

local function padCycle()
    local stage = targetPadStage()
    local pad = freePads()[stage]
    if not pad then
        note("stage %d has no free pad", stage)
        goStation()
        task.wait(0.5)
        return
    end
    STATE.padStage = stage

    local delay = padDelay(stage, pad)
    goStation()
    STATE.phase = string.format("dojo, pad %d in %.1fs", stage,
        math.max(0, STATE.lastPay + delay - os.clock()))
    while alive() and STATE.running and os.clock() < STATE.lastPay + delay do
        task.wait(0.05)
    end
    if not (alive() and STATE.running) then return end

    STATE.phase = "claiming pad " .. stage
    local before = wins()
    warp(pad:GetPivot() + Vector3.new(0, 3, 0))
    local t = os.clock()
    while alive() and wins() <= before and os.clock() - t < CONFIG.padWait do task.wait(0.03) end

    local gained = wins() - before
    if gained > 0 then
        STATE.lastPay = os.clock()
        STATE.claims = STATE.claims + 1
        STATE.earned = STATE.earned + gained
        -- probe the window downward slowly; a miss pushes it back up
        STATE.padAdj[stage] = math.max(-0.5, (STATE.padAdj[stage] or 0) - 0.03)
        note("pad %d +%s wins", stage, abbreviate(gained))
    else
        STATE.misses = STATE.misses + 1
        STATE.padAdj[stage] = (STATE.padAdj[stage] or 0) + 0.3
        note("pad %d paid nothing, window now %.2fs", stage, padDelay(stage, pad))
        -- a touch only fires on a NEW contact: step off before the next try
        goStation()
        task.wait(0.25)
    end
end

----------------------------------------------------------------------------
-- spending.  every multiplier here is a Spirit multiplier; the score is the
-- log of the factor per win, so a x2 Gi and a x1.18 belt compare honestly.
----------------------------------------------------------------------------

local function ownedGis()
    local set = {}
    for n in string.gmatch(tostring(attr("OwnedGis", "")), "%d+") do set[n] = true end
    return set
end

local function nextGi()
    local owned = ownedGis()
    local current = Economy.bestOwnedGiMult(owned)
    local best
    for _, g in ipairs(GameConfig.Gis) do
        if g.Currency == "Wins" and not g.Exclusive and not g.Daily
           and not owned[tostring(g.Tier)] and (g.Mult or 0) > current then
            if not best or g.Cost < best.Cost then best = g end
        end
    end
    if not best then return nil end
    return { kind = "gi", tier = best.Tier, cost = best.Cost, factor = best.Mult / current, name = best.Name }
end

local function nextBelt()
    local tier = tonumber(attr("BeltTier", 0)) or 0
    local ok, cost = pcall(Economy.gradingCost, tier)
    if not ok or not cost then return nil end
    local okA, a = pcall(Economy.beltMult, tier)
    local okB, b = pcall(Economy.beltMult, tier + 1)
    if not (okA and okB) then return nil end
    local belt = GameConfig.Grading.Belts[tier + 1]
    return { kind = "belt", tier = tier + 1, cost = cost, factor = b / a, name = belt and belt.Name or ("belt " .. (tier + 1)) }
end

local function score(item)
    return math.log(item.factor) / math.max(item.cost, 1)
end

-- the Gi a player WEARS can be worse than one owned (a daily Gi, or a buy
-- that did not equip); the game's own giMult ranks them
local function equipBestGi()
    local owned = ownedGis()
    local worn = tonumber(attr("EquippedGi", 1)) or 1
    local best, bestMult
    for _, g in ipairs(GameConfig.Gis) do
        if owned[tostring(g.Tier)] then
            local ok, m = pcall(Economy.giMult, g.Tier, owned)
            if ok and m and (not bestMult or m > bestMult) then best, bestMult = g.Tier, m end
        end
    end
    if best and best ~= worn then
        local okW, wornMult = pcall(Economy.giMult, worn, owned)
        if not okW or (wornMult or 0) < bestMult then
            invoke("EquipGi", best)
        end
    end
end

local function buyUpgrades()
    for _ = 1, 6 do
        local options = {}
        if CONFIG.autoGi then local g = nextGi() if g then options[#options + 1] = g end end
        if CONFIG.autoBelt then local b = nextBelt() if b then options[#options + 1] = b end end
        if #options == 0 then STATE.saving = 0 return end
        table.sort(options, function(x, y) return score(x) > score(y) end)

        local balance = wins()
        local pick = options[1]
        if pick.cost > balance then
            -- the better buy is out of reach: only take the other one when the
            -- better one is far away, or the cheap one starves it forever
            local other = options[2]
            if other and other.cost <= balance and pick.cost > balance * 4 then
                pick = other
            else
                STATE.saving = pick.cost
                return
            end
        end
        STATE.saving = 0

        local ok, err
        if pick.kind == "gi" then
            ok, err = invoke("BuyGi", pick.tier)
            if ok then STATE.gis = STATE.gis + 1 end
        else
            ok, err = invoke("Grade")
            if ok then STATE.belts = STATE.belts + 1 end
        end
        if ok then
            note("bought %s for %s wins", pick.name, abbreviate(pick.cost))
        else
            note("%s refused: %s", pick.name, tostring(err))
            return
        end
        task.wait(0.6)
    end
end

-- eggs ------------------------------------------------------------------

local function petPower(name)
    local def = GameConfig.Pets and GameConfig.Pets.Defs and GameConfig.Pets.Defs[name]
    return def and (def.Power or 0) or 0
end

local function equippedPowers()
    local list = {}
    for name in string.gmatch(tostring(attr("EquippedPets", "")), "[^,]+") do
        list[#list + 1] = petPower(name)
    end
    table.sort(list)
    return list
end

local function eggModel(id)
    local folder = workspace:FindFirstChild("PetEggs")
    if not folder then return nil end
    for _, m in ipairs(folder:GetChildren()) do
        if m:GetAttribute("EggId") == id or m.Name == id then return m end
    end
    return nil
end

-- Expected power gained over the weakest slot, per hatch.  An egg whose
-- every pet is at or below the weakest slot scores 0 and is finished.
local function eggGain(egg, floor)
    local total, gain = 0, 0
    for _, p in ipairs(egg.Pets) do total = total + (p[2] or 0) end
    if total <= 0 then return 0 end
    for _, p in ipairs(egg.Pets) do
        gain = gain + (p[2] or 0) / total * math.max(0, petPower(p[1]) - floor)
    end
    return gain
end

-- Which egg.  While wins are short the cheap Dojo egg (10 wins, top pet 30)
-- wins by a mile per win spent.  Once the budget covers a whole batch of the
-- dear egg the limit is the hatch TIME (a second of body time per call), and
-- Bamboo's 2% of a 50 beats the Dojo egg's 2% of a 30 - the first version kept
-- hatching Dojo eggs with 3.4B wins in the bank.
local function pickEgg(budget)
    local slots = tonumber(attr("PetSlots", 3)) or 3
    local powers = equippedPowers()
    local floor = (#powers >= slots) and (powers[1] or 0) or 0
    local multi = tonumber(attr("HatchMulti", 2)) or 2
    local best, bestScore
    for _, egg in ipairs(GameConfig.Eggs or {}) do
        if egg.Currency == "Wins" and egg.Price and egg.Pets and egg.Price <= budget and eggModel(egg.Id) then
            local gain = eggGain(egg, floor)
            if gain > 0 then
                local rich = budget >= egg.Price * multi * 4
                local s = rich and gain * 1e9 or gain / egg.Price
                if not bestScore or s > bestScore then best, bestScore = egg, s end
            end
        end
    end
    return best
end

local function hatchEggs()
    if not CONFIG.autoEggs then return end
    -- the starvation pattern: an egg must not take the money the next Gi or
    -- belt is being saved for
    if STATE.saving > 0 and STATE.saving <= wins() * 20 then return end

    local budget = wins() * CONFIG.eggShare
    local egg = pickEgg(budget)
    if not egg then return end

    local multi = tonumber(attr("HatchMulti", 2)) or 2
    local perCall = egg.Price * multi
    local mode = "Multi"
    if perCall > budget then mode, perCall = "Single", egg.Price end
    -- every call is a second of body time the win pad does not get
    local calls = math.clamp(math.floor(budget / perCall), 1, 4)

    local model = eggModel(egg.Id)
    local base = model and model:GetPivot()
    if not base then return end

    STATE.phase = "hatching " .. (egg.Name or egg.Id)
    local hatched = 0
    for _ = 1, calls do
        if not (alive() and STATE.running) then break end
        warp(base * CFrame.new(0, 3, -7))
        task.wait(0.15)
        local ok, res = invoke("HatchEgg", egg.Id, mode)
        if ok and type(res) == "table" then
            hatched = hatched + #res
        else
            if res ~= "far" then break end
        end
        task.wait(1.05)   -- HatchCooldown is 1s
    end
    if hatched > 0 then
        STATE.hatched = STATE.hatched + hatched
        note("hatched %d from %s", hatched, egg.Name or egg.Id)
        if CONFIG.autoPets then invoke("PetsEquipBest") end
    end
end

-- trails ----------------------------------------------------------------

-- Bought with Dragon Spirit, not wins ("funds" at 1,105 wins and 0 Dragon
-- Spirit).  The Ki trail took WalkSpeed 25 -> 37.5, but the win pad window
-- measured the same with and without it, so this is walking speed for the
-- player and nothing the farm itself gains from.
local function ownedTrails()
    local set = {}
    for id in string.gmatch(tostring(attr("OwnedTrails", "")), "[%w_]+") do set[id] = true end
    return set
end

local function buyTrails()
    if not CONFIG.autoTrail then return end
    local trails = GameConfig.TrailShop and GameConfig.TrailShop.Trails or {}
    local owned = ownedTrails()
    local balance = tonumber(attr("DragonSpirit", 0)) or 0

    local bestSpeed, bestId = 0, nil
    for _, t in ipairs(trails) do
        if owned[t.Id] and (t.Speed or 0) > bestSpeed then bestSpeed, bestId = t.Speed, t.Id end
    end

    local pick
    for _, t in ipairs(trails) do
        if not owned[t.Id] and t.Price and t.Price <= balance and (t.Speed or 0) > bestSpeed then
            if not pick or t.Speed > pick.Speed then pick = t end
        end
    end
    if pick then
        local ok, err = invoke("BuyTrail", pick.Id)
        if ok then
            note("bought %s (x%.1f speed) for %d Dragon Spirit", pick.Name or pick.Id, pick.Speed, pick.Price)
            bestId = pick.Id
        else
            note("trail %s refused: %s", pick.Id, tostring(err))
        end
    end
    if bestId and attr("EquippedTrail", "") ~= bestId then
        invoke("EquipTrail", bestId)
    end
end

----------------------------------------------------------------------------
-- rebirth / worlds
----------------------------------------------------------------------------

local function shouldHoldRebirth()
    if not CONFIG.holdRebirth then return false end
    local stage = hsc() + 1
    local spec = GameConfig.Stages[stage]
    if not spec then return false end
    -- the Master is within reach: finishing it is faster than earning the
    -- whole spirit back after a reset
    return spirit() * CONFIG.holdFactor >= (spec.Spirit or math.huge) * 0.7
end

local function doRebirth()
    if attr("LevelCapped", false) ~= true then return false end
    if shouldHoldRebirth() then return false end
    local before = rebirths()
    local ok, err = invoke("Rebirth")
    if ok and rebirths() > before then
        STATE.rebirthsDone = STATE.rebirthsDone + 1
        note("rebirth %d - dojo label now x%d", rebirths(), select(2, bestStation()))
        return true
    end
    if not ok then note("rebirth refused: %s", tostring(err)) end
    return false
end

local function checkWorld()
    if not CONFIG.autoWorld then return end
    local here = GameConfig.World and GameConfig.World.Number or 1
    local nxt = GameConfig.Worlds and GameConfig.Worlds[here + 1]
    if not nxt then return end
    local flag = "World" .. (here + 1) .. "Unlocked"
    if attr(flag, false) ~= true then
        if wins() < (nxt.UnlockWins or math.huge) then return end
        local ok, err = invoke("WorldUnlock", here + 1)
        note("world %d unlock: %s", here + 1, ok and "ok" or tostring(err))
        task.wait(1)
    end
    if attr(flag, false) == true then
        note("teleporting to world %d", here + 1)
        fire("WorldTeleport", here + 1)
        task.wait(10)
    end
end

----------------------------------------------------------------------------
-- free rewards
----------------------------------------------------------------------------

_G.__KARATEEVO_CODES = _G.__KARATEEVO_CODES or {}

local function redeemCodes()
    for _, entry in ipairs(GameConfig.Codes or {}) do
        local code = entry.Code
        if code and not _G.__KARATEEVO_CODES[code] then
            local ok, msg = invoke("RedeemCode", code)
            _G.__KARATEEVO_CODES[code] = true
            if ok then
                STATE.codes = STATE.codes + 1
                note("code %s: %s", code, tostring(msg))
            end
            task.wait(1.1)
        end
    end
end

local timedPending = false
local function claimRewards()
    if not CONFIG.autoRewards then return end
    pcall(redeemCodes)

    local started = tonumber(attr("PlaytimeStart", 0)) or 0
    local minutes = (workspace:GetServerTimeNow() - started) / 60
    local claimed = {}
    for n in string.gmatch(tostring(attr("PlaytimeClaimed", "")), "%d+") do claimed[tonumber(n)] = true end
    for i, r in ipairs(GameConfig.PlaytimeRewards or {}) do
        if not claimed[i] and minutes >= (r.Minutes or math.huge) then
            invoke("ClaimPlaytime", i)
            task.wait(0.6)
        end
    end

    invoke("ClaimLeaveReward")
    if GameConfig.Halloween and GameConfig.Halloween.Pass and GameConfig.Halloween.Pass.Enabled then
        invoke("HalloweenPassClaimAll")
    end

    -- no handler is bound to ClaimTimed on the server: one thread may wait on
    -- it at a time, never more
    if not timedPending and remote("ClaimTimed") then
        timedPending = true
        task.spawn(function()
            pcall(function() remote("ClaimTimed"):InvokeServer() end)
            timedPending = false
        end)
    end
end

----------------------------------------------------------------------------
-- the dragon fight
----------------------------------------------------------------------------

-- Net.fireServer is looked up on the module table at call time by every
-- controller, so replacing the field is a clean hook.  Installed once per VM;
-- each run only swaps the filter.
if not _G.__KARATEEVO_NETORIG then
    _G.__KARATEEVO_NETORIG = Net.fireServer
    local orig = Net.fireServer
    Net.fireServer = function(name, ...)
        local filter = _G.__KARATEEVO_NETFILTER
        if filter then
            local ok, verdict = pcall(filter, name, ...)
            if ok and verdict == false then return end
        end
        return orig(name, ...)
    end
end

_G.__KARATEEVO_NETFILTER = function(name, id)
    if not alive() then return true end
    if name == "ArenaHit" and CONFIG.arenaNoHit then
        STATE.hitsBlocked = STATE.hitsBlocked + 1
        -- the game marks the attack hitMe locally and so never reports the
        -- dodge for it: report it ourselves once the attack has resolved
        if CONFIG.arenaDodge and id ~= nil then
            task.delay(0.8, function()
                if alive() and inArena() then
                    pcall(fire, "ArenaDodge", id)
                    STATE.dodges = STATE.dodges + 1
                end
            end)
        end
        return false
    end
    if name == "ArenaDodge" then STATE.dodges = STATE.dodges + 1 end
    return true
end

local function arenaOpen()
    local phase = ReplicatedStorage:GetAttribute("LiveArenaEventPhase") or ""
    if phase ~= "gather" and phase ~= "fight" then return false end
    return workspace:GetServerTimeNow() <= (ReplicatedStorage:GetAttribute("ArenaJoinUntil") or 0)
end

local arenaRetryAt = 0

local function arenaWanted()
    return CONFIG.autoArena and arenaOpen() and os.clock() >= arenaRetryAt
end

local function arenaFight()
    if not CONFIG.autoArena then return false end
    if not inArena() then
        if not arenaOpen() or duelPhase() ~= "" then return false end
        fire("ArenaJoin")
        local t = os.clock()
        while alive() and not inArena() and os.clock() - t < 4 do task.wait(0.1) end
        if not inArena() then
            arenaRetryAt = os.clock() + 6
            note("dragon fight did not take the join")
            return false
        end
        STATE.arenaFights = STATE.arenaFights + 1
        note("joined the dragon fight")
    end
    -- the arena owns the body until the server lets go; strikes keep going
    STATE.phase = "dragon fight"
    local t0 = os.clock()
    while alive() and inArena() and os.clock() - t0 < 180 do task.wait(0.25) end
    note("dragon fight over (%d hits dropped, %d dodges)", STATE.hitsBlocked, STATE.dodges)
    return true
end

----------------------------------------------------------------------------
-- the body routine.  one owner: duel, dragon, pad, egg and dojo all move the
-- character, so they run in sequence inside this loop and never in parallel.
----------------------------------------------------------------------------

local lastSpend, lastRewards, lastPets, lastEggs = 0, 0, 0, 0

task.spawn(function()
    while alive() do
        if not STATE.running or not loaded() then
            STATE.phase = STATE.running and "waiting for data" or "paused"
            task.wait(0.5)
        elseif inArena() or arenaWanted() then
            pcall(arenaFight)
            task.wait(0.5)
        elseif duelPhase() ~= "" then
            STATE.phase = "duel " .. duelPhase()
            task.wait(0.2)
        else
            local stage = CONFIG.autoDuel and duelReady()
            if stage then
                local ok, err = pcall(duel, stage)
                if not ok then note("duel failed: %s", tostring(err)) end
                STATE.lastPay = 0
            end

            if CONFIG.autoRebirth then pcall(doRebirth) end

            if os.clock() - lastSpend > 5 then
                lastSpend = os.clock()
                pcall(buyUpgrades)
                pcall(equipBestGi)
                pcall(buyTrails)
                pcall(checkWorld)
            end
            if os.clock() - lastEggs > 20 then
                lastEggs = os.clock()
                pcall(hatchEggs)
            end
            if CONFIG.autoPets and os.clock() - lastPets > 60 then
                lastPets = os.clock()
                task.spawn(invoke, "PetsEquipBest")
            end
            if os.clock() - lastRewards > 90 then
                lastRewards = os.clock()
                task.spawn(claimRewards)
            end

            if CONFIG.autoPads then
                local ok, err = pcall(padCycle)
                if not ok then note("pad failed: %s", tostring(err)) task.wait(0.5) end
            else
                STATE.phase = CONFIG.autoTrain and "training on the dojo" or "idle"
                pcall(goStation)
                task.wait(0.5)
            end
        end
    end
end)

task.spawn(function()
    while alive() do
        pcall(function()
            STATE.spirit, STATE.wins, STATE.rebirths = spirit(), wins(), rebirths()
            STATE.startWins = STATE.startWins or STATE.wins
            STATE.level = tonumber(attr("Level", 1)) or 1
            STATE.capped = attr("LevelCapped", false) == true
            STATE.levelGate = Economy.levelGate(STATE.rebirths)
            STATE.hsc = hsc()
            STATE.petMult = tonumber(attr("PetMult", 1)) or 1
            local attrs = LocalPlayer:GetAttributes()
            STATE.perStrike = StrikeState.value(attrs)
            local _, label, id = bestStation()
            STATE.station, STATE.stationLabel = id, label
            STATE.passive = label > 0 and Economy.passivePerSecond(StrikeState.from(attrs), label) or 0
        end)
        task.wait(0.5)
    end
end)

pcall(function()
    if _G.__KARATEEVO_IDLE then _G.__KARATEEVO_IDLE:Disconnect() end
    local VirtualUser = game:GetService("VirtualUser")
    _G.__KARATEEVO_IDLE = LocalPlayer.Idled:Connect(function()
        if not CONFIG.antiAfk then return end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end)
end)

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__KARATEEVO_WIN then pcall(function() _G.__KARATEEVO_WIN:Destroy() end) end
if UI.sweep then pcall(UI.sweep, "KARATEEVO") end

UI.config("karateevo", CONFIG)

local win = UI.Window({
    title = "KARATE", accentTitle = "EVO", subtitle = "seltonmt",
})
_G.__KARATEEVO_WIN = win

local farmPage = win:Page("FARMING", UI.icon.sword)

local train = farmPage:Card("TRAINING", 1):Accent()
train:Toggle("Auto strike", CONFIG.autoStrike, function(v) CONFIG.autoStrike = v end,
    "20 strikes every 0.2s - the server credits ~22/s, faster is wasted")
train:Toggle("Train on the best dojo", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
    "Passive spirit on top of the strikes. Robux dojos are never stepped on")
train:Toggle("Beat the next Master", CONFIG.autoDuel, function(v) CONFIG.autoDuel = v end,
    "Challenges as soon as the push maths wins. A duel costs no spirit")
train:Toggle("Farm the win pad", CONFIG.autoPads, function(v) CONFIG.autoPads = v end,
    "Deepest free pad, every touch pays. Waits out the server timer on the dojo")
train:Slider("Duel margin x10", 10, 30, CONFIG.duelMargin * 10, function(v)
    CONFIG.duelMargin = v / 10
end, "How far my push must beat the Master's before a challenge")

local spend = farmPage:Card("SPENDING", 2)
spend:Toggle("Buy Gis", CONFIG.autoGi, function(v) CONFIG.autoGi = v end,
    "Wins tiers only, x2 spirit each, equipped by the server")
spend:Toggle("Grade belts", CONFIG.autoBelt, function(v) CONFIG.autoBelt = v end,
    "Ranked against the Gi by spirit gained per win")
spend:Toggle("Hatch eggs", CONFIG.autoEggs, function(v) CONFIG.autoEggs = v end,
    "Best egg for the weakest slot - per win while poor, per hatch once rich")
spend:Toggle("Equip best pets", CONFIG.autoPets, function(v) CONFIG.autoPets = v end,
    "The game's own Equip Best, after every hatch and once a minute")
spend:Toggle("Rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "Resets only spirit and level. Wins, Gis, belts and stages stay", UI.theme.warn)
spend:Toggle("Finish a close Master first", CONFIG.holdRebirth, function(v) CONFIG.holdRebirth = v end,
    "Holds the rebirth while the next Master is within reach")
spend:Slider("Egg budget %", 5, 80, CONFIG.eggShare * 100, function(v)
    CONFIG.eggShare = v / 100
end)

local readout = farmPage:Card("STATUS", 0)
local out = readout:Readout(10)

local eventPage = win:Page("EVENTS", UI.icon.star)

local arena = eventPage:Card("DRAGON FIGHT", 1):Accent()
arena:Toggle("Join the dragon fight", CONFIG.autoArena, function(v) CONFIG.autoArena = v end,
    "Every 30 minutes. Pays Dragon Spirit for the trail shop")
arena:Toggle("Ignore dragon hits", CONFIG.arenaNoHit, function(v) CONFIG.arenaNoHit = v end,
    "The client reports its own hits - this one never does")
arena:Toggle("Report dodges", CONFIG.arenaDodge, function(v) CONFIG.arenaDodge = v end,
    "Every attack counts as dodged, for the dodge streak bonus")
arena:Toggle("Buy trails", CONFIG.autoTrail, function(v) CONFIG.autoTrail = v end,
    "Fastest trail the Dragon Spirit pays for. Walk speed only - the pad timer ignores it")

local extras = eventPage:Card("REWARDS", 2)
extras:Toggle("Free rewards", CONFIG.autoRewards, function(v) CONFIG.autoRewards = v end,
    "All codes, the playtime gifts and the leave reward")
extras:Toggle("Next world", CONFIG.autoWorld, function(v) CONFIG.autoWorld = v end,
    "Spends 2.5B wins on the next world and moves there. Every world is a fresh save", UI.theme.warn)
extras:Toggle("Anti AFK", CONFIG.antiAfk, function(v) CONFIG.antiAfk = v end)
extras:Button("Redeem all codes now", function()
    _G.__KARATEEVO_CODES = {}
    task.spawn(redeemCodes)
end, UI.theme.good)
extras:Button("Rebirth now", function()
    task.spawn(function()
        local hold = CONFIG.holdRebirth
        CONFIG.holdRebirth = false
        doRebirth()
        CONFIG.holdRebirth = hold
    end)
end)

task.spawn(function()
    while alive() do
        pcall(function()
            local mins = math.max((os.clock() - STATE.startClock) / 60, 0.1)
            local nxt = GameConfig.Stages[STATE.hsc + 1]
            out:set({
                "PROGRESS",
                string.format("  stage %d/%d cleared   next master %s   odds x%.2f",
                    STATE.hsc, STATE.stages, nxt and abbreviate(nxt.Spirit) or "-",
                    nxt and duelOdds(STATE.hsc + 1) or 0),
                string.format("  level %d/%d%s   rebirths %d   dojo #%d (x%d)",
                    STATE.level, STATE.levelGate, STATE.capped and " capped" or "",
                    STATE.rebirths, STATE.station, STATE.stationLabel),
                string.format("  spirit %s   +%s/strike   dojo +%s/s   pets x%.2f",
                    abbreviate(STATE.spirit), abbreviate(STATE.perStrike),
                    abbreviate(STATE.passive), STATE.petMult),
                "WINS",
                string.format("  pad %d   claims %d   misses %d   earned %s (%s/min)",
                    STATE.padStage, STATE.claims, STATE.misses, abbreviate(STATE.earned),
                    abbreviate(STATE.earned / mins)),
                string.format("  bought %d Gis   %d belts   %d pets hatched%s",
                    STATE.gis, STATE.belts, STATE.hatched,
                    STATE.saving > 0 and ("   saving " .. abbreviate(STATE.saving)) or ""),
                string.format("  duels %d won / %d lost   dragon fights %d   phase: %s",
                    STATE.duelsWon, STATE.duelsLost, STATE.arenaFights, STATE.phase),
                "NOTE",
                "  " .. tostring(STATE.note),
            })
            win:SetStat(1, abbreviate(STATE.wins), "wins")
            win:SetStat(2, abbreviate(STATE.spirit), "spirit")
            win:SetStat(3, string.format("%d/%d", STATE.hsc, STATE.stages), "stage")
            win:SetStatus(string.format("%s wins   %s spirit   r%d   stage %d",
                abbreviate(STATE.wins), abbreviate(STATE.spirit), STATE.rebirths, STATE.hsc))
        end)
        task.wait(0.5)
    end
end)

pcall(function()
    win:SetMaster(STATE.running, "Auto Farm running")
    win:OnMaster(function(on) STATE.running = on end)
end)

pcall(function() win:Home() end)

_G.__KARATEEVO_DBG = {
    CONFIG = CONFIG, STATE = STATE, GameConfig = GameConfig,
    bestStation = bestStation, goStation = goStation, freePads = freePads,
    targetPadStage = targetPadStage, padCycle = padCycle, padDelay = padDelay,
    duelOdds = duelOdds, duelReady = duelReady, duel = duel,
    nextGi = nextGi, nextBelt = nextBelt, buyUpgrades = buyUpgrades, buyTrails = buyTrails,
    equipBestGi = equipBestGi, pickEgg = pickEgg, hatchEggs = hatchEggs,
    doRebirth = doRebirth, checkWorld = checkWorld, claimRewards = claimRewards,
    redeemCodes = redeemCodes, arenaOpen = arenaOpen, arenaFight = arenaFight,
    invoke = invoke, warp = warp,
}

note("ready - stage %d cleared, pad %d is the target", hsc(), targetPadStage())
