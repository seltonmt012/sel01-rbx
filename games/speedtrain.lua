--[[
    speedtrain.lua - "Speed Training / Geschwindigkeitstraining" (place 105553804282308)

    Measured against server-side values on 2026-08-23, account hallowasgehtz2,
    from a completely fresh save (0 wins, 0 rebirths, Speed 100).

    THE GAME
    Two engines that do not run at the same time, because there is one body:

      * TRAINING - stand on a treadmill, Speed ticks up.  Speed is the rebirth
        currency AND the thing that sets how fast you may legally run in a race.
      * RACING - every ~120s a race window opens (`Values.RaceActive`, ~15s
        break between).  Running down the track pays Wins at 16 milestones.
        Wins buy shoes, trails, partners, eggs and unlock the eight worlds.
        Gems from the same milestones buy the upgrade ladder.

    HOW THE RACE IS SCORED, AND THE ONE THING THAT MATTERS
    `Modules.Shared.RaceLib.GetStudsTraveled` runs on the SERVER and reads the
    character's own position:

        studs = max(HumanoidRootPart.Position.Z - 114, 0) * DistanceNerf
                + Laps * finalMilestoneStuds

    so the distance is whatever the client's position says it is.  Two rules
    were paid for with a lot of dead races:

      1. **You have to come through the start line.**  `Join Race` is only
         accepted from the race proximity pad, which sits at Z ~= 105, i.e.
         BEHIND the gate at Z = 114, and the run only counts if the body then
         moves forward from there.  Teleporting straight to Z = 100120 (the
         end of the world-1 track, 600,036 studs) put a perfect 600,043 into
         `DistanceHighScores` and paid **nothing** - the milestones are only
         handed out for a run that started at the line.  This was the single
         biggest time sink in the whole session.
      2. **There is a speed ceiling and it is not a position check.**  With
         `TopSpeed` at 34.3 (a fresh account), moving Z at 300 studs/s - about
         7x the legitimate race speed - credited **every** milestone it passed,
         exactly at the listed value.  At 900 studs/s the server paid out
         milestone 5 and then stopped for the rest of the race.  So the boost
         is a MULTIPLE of what the game itself would run at, never a constant:
         `Humanoid.WalkSpeed * 3 / DistanceNerf` is the game's own forward
         speed and `CONFIG.boostFactor` is how much of it we take.  The factor
         tunes itself down whenever a milestone is passed and not paid.

    Measured, world 1, 120s race at 300 studs/s: milestones 1..12 = **+4,206
    wins in one race**, every single one credited at its listed value
    (25,000 studs -> +8, 37,500 -> +10, 50,000 -> +25, 70,000 -> +50, ...).
    The full track is 600,000 studs and worth 91,456 wins; world 8 pays 100x
    the same ladder.

    OTHER THINGS THAT ARE TRUE HERE
    * The whole game is the **Paper** library, same as Pickaxe Simulator: every
      action is `Paper.Network.FireServer(name, ...)` /
      `InvokeServer(name, ...)` with a plain English name, multiplexed through
      `ReplicatedStorage.Paper.Remotes.__remoteevent` / `__remotefunction`.
    * The state oracle is `Paper.Stats.GetValue(player, key)` - 160 fields,
      everything from `Wins` and `Speed` to `BoughtShoes` and `WorldsUnlocked`.
      Read it through the accessor every time; the underlying table is replaced
      by the server, not mutated.
    * **`FireServer("Use Treadmill", n)` needs no walking at all** - it warps
      the body onto treadmill n from anywhere, and it works even while a race
      is running.  `TreadmillLib.CanUse(plr, n)` is the honest gate (Speed
      requirement AND rebirth requirement).
    * Rebirth costs **Speed**, not wins: `500 * (rebirths + 1) * amount`
      (`Modules.Shared.Rebirths`).  It is linear, so banking and converting in
      one batch costs the same as converting one at a time and only pays the
      Speed reset once.  `InvokeServer("Rebirth", amount)`; the "Max" button in
      the game is gamepass-gated but the remote takes any amount.
    * Shoes are a flat purchase, not a ladder - `Buy Shoe` for "Striped
      Sandals" went through while "Blue Sneaker" was worn and charged exactly
      its 2,500 - and the fields mean: `WalkSpeed` raw race speed, `Wins` +%
      wins, `Luck` +% egg luck, `Acceleration` +% acceleration.
    * Worlds unlock themselves once total wins pass `Worlds[n].Req`
      (7,500 / 1M / 50M / 10B / 200B / 2.5T / 20T); `Set Current World` then
      answers for anything `WorldsUnlocked` covers.  Each world ships its own
      milestone table with the world multiplier already baked in.
    * Every upgrade is priced in **Gems**, and gems only come out of race
      milestones.  `More Wins` and `More Speed` start at 15 / 10 gems.
    * Free and verified: `Claim Free Reward`, `Claim Daily`,
      `Redeem Code("update6")` (gave 4 Win Potions, a Speed and a Luck Potion),
      `Claim Chest`, `Claim Achievement`, `Claim Group` (needs the group).
    * Robux, never touched: every `ProductId` shoe / trail / partner
      (Prismatic Boots, Rainbow trail, 1x1x1x1, ...), the exclusive eggs,
      `Revenue Metadata`, DoubleSpeed2Min, the max-rebirth and auto-rebirth
      gamepasses, `TwelveHatchProduct`.
--]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function waitFor(parent, name, timeout)
    local found = parent:FindFirstChild(name)
    if found then return found end
    local ok, child = pcall(function() return parent:WaitForChild(name, timeout or 10) end)
    if ok and child then return child end
    error(("speedtrain: %s.%s never appeared - wrong game?"):format(parent:GetFullName(), name), 0)
end

local Paper      = require(waitFor(ReplicatedStorage, "Paper"))
local TablesF    = waitFor(ReplicatedStorage, "Tables")
local ModulesF   = waitFor(ReplicatedStorage, "Modules")
local Race       = require(waitFor(TablesF, "Race"))
local Worlds     = require(waitFor(TablesF, "Worlds"))
local Shoes      = require(waitFor(TablesF, "Shoes"))
local Trails     = require(waitFor(TablesF, "Trails"))
local Partners   = require(waitFor(TablesF, "Partners"))
local Treadmills = require(waitFor(TablesF, "Treadmills"))
local Eggs       = require(waitFor(TablesF, "Eggs"))
local Upgrades   = require(waitFor(TablesF, "Upgrades"))
local RebirthTiers = require(waitFor(TablesF, "Rebirths"))
local SharedF    = waitFor(ModulesF, "Shared")
local TreadmillLib = require(waitFor(SharedF, "TreadmillLib"))
local RebirthLib   = require(waitFor(SharedF, "Rebirths"))
local PetLib       = require(waitFor(SharedF, "PetLib"))
local Achievements = require(waitFor(TablesF, "Achievements"))

local plr    = Players.LocalPlayer
local Values = waitFor(ReplicatedStorage, "Values")

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    auto          = false,   -- master

    -- race
    autoRace      = true,
    boostFactor   = 6.0,     -- multiples of the game's own forward speed
    minFactor     = 1.0,
    maxFactor     = 10.0,
    autoTune      = true,    -- back off whenever a milestone goes unpaid
    payGrace      = 3.0,     -- seconds a crossed milestone may stay unpaid

    -- training
    autoTrain     = true,    -- train in the gaps between races
    trainForRebirth = true,  -- skip racing while a rebirth batch is not affordable

    -- spending
    autoRebirth   = true,
    rebirthBatch  = 5,       -- convert only once this many rebirths are affordable
    autoShoe      = true,
    autoPartner   = true,
    autoTrail     = true,
    autoEgg       = true,
    eggShare      = 0.25,    -- share of the balance an egg batch may cost
    autoPets      = true,
    autoCraft     = true,    -- fuse four of a kind into golden / rainbow
    autoAchieve   = true,
    autoUpgrade   = true,
    autoWorld     = true,

    -- free stuff
    autoClaim     = true,
    autoCodes     = true,
    autoPotion    = false,   -- burn Win Potions while racing
}

local STATE = {
    phase      = "idle",
    note       = "-",
    wins       = 0,
    gems       = 0,
    speed      = 0,
    rebirths   = 0,
    world      = 1,
    studs      = 0,
    races      = 0,
    racedWins  = 0,
    lastRace   = 0,
    milestones = 0,
    throttled  = 0,
    trained    = 0,
    spent      = {},
    uiOwner    = nil,
}

_G.__SPEEDTRAIN = (_G.__SPEEDTRAIN or 0) + 1
local GEN = _G.__SPEEDTRAIN
local function alive() return _G.__SPEEDTRAIN == GEN end

local function note(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    STATE.note = ok and msg or tostring(fmt)
end

local function abbrev(n)
    if type(n) ~= "number" then return tostring(n) end
    local ok, s = pcall(function() return Paper.Number.toSuffix(n) end)
    if ok and s then return s end
    return string.format("%.0f", n)
end

----------------------------------------------------------------------------
-- oracle
----------------------------------------------------------------------------

-- Always through the accessor: the server hands the client a fresh data table
-- on every update and a cached reference goes stale without any sign of it.
local function V(key)
    local ok, value = pcall(Paper.Stats.GetValue, plr, key)
    if ok then return value end
    return nil
end

local function num(key, fallback) local v = V(key) return type(v) == "number" and v or (fallback or 0) end

local function fire(...)  return pcall(Paper.Network.FireServer, ...) end
local function invoke(...)
    local packed = table.pack(pcall(Paper.Network.InvokeServer, ...))
    if not packed[1] then return false, packed[2] end
    return packed[2], packed[3]
end

local function refresh()
    STATE.wins     = num("Wins")
    STATE.gems     = num("Gems")
    STATE.speed    = num("Speed")
    STATE.rebirths = num("Rebirths")
    STATE.world    = num("CurrentWorld", 1)
end

----------------------------------------------------------------------------
-- body
----------------------------------------------------------------------------

local function character()
    local ch = plr.Character
    if not ch then return nil end
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if hrp and hum then return ch, hrp, hum end
    return nil
end

-- One pin at a time.  Everything that moves the body goes through here so the
-- race loop and the treadmill can never write the same CFrame in one frame.
local pinConn = nil
local function unpin()
    if pinConn then pinConn:Disconnect() pinConn = nil end
end

local function pinAt(cf)
    unpin()
    pinConn = RunService.Heartbeat:Connect(function()
        if not alive() then unpin() return end
        local _, hrp = character()
        if hrp then hrp.CFrame = cf end
    end)
end

----------------------------------------------------------------------------
-- race geometry
----------------------------------------------------------------------------

-- The gate the server measures from.  `GetStudsTraveled` subtracts a hard 114
-- before scaling, and the milestone parts the client builds are placed at
-- `Studs / DistanceNerf + 114`, so 114 is the start line in every world.
local START_Z = 114

local function raceInfo()
    local world = num("CurrentWorld", 1)
    local cfg   = Race[world]
    if not cfg then return nil end
    local entry = Worlds[world]
    local folder = entry and workspace:FindFirstChild("Worlds")
    folder = folder and folder:FindFirstChild(entry.WorldName)
    local prox
    local rp = folder and folder:FindFirstChild("RaceProximity")
    prox = rp and rp:FindFirstChild("Proximity")
    local centreX = (cfg.Bounds.RightSide + cfg.Bounds.LeftSide) / 2
    local last    = cfg.Milestones[#cfg.Milestones]
    return {
        world   = world,
        cfg     = cfg,
        nerf    = cfg.DistanceNerf,
        centreX = centreX,
        prox    = prox,
        finalStuds = last and last.Studs or 0,
        milestones = cfg.Milestones,
    }
end

local function studsNow(info)
    local _, hrp = character()
    if not hrp or not info then return 0 end
    local laps = plr:GetAttribute("Laps") or 0
    return math.max(hrp.Position.Z - START_Z, 0) * info.nerf + laps * info.finalStuds
end

----------------------------------------------------------------------------
-- the race
----------------------------------------------------------------------------

local raceBusy = false

local function runRace()
    if raceBusy then return end
    raceBusy = true

    local ok, err = pcall(function()
        local info = raceInfo()
        if not info or not info.prox then
            note("no race pad in world %d yet - map still streaming", info and info.world or 0)
            return
        end

        -- 1. Behind the start line.  The join is refused anywhere else and a
        --    run that did not come through the pad is never scored.
        STATE.phase = "lining up"
        local p = info.prox.Position
        pinAt(CFrame.new(p.X, p.Y + 1, p.Z))
        task.wait(0.8)
        if not alive() or not Values.RaceActive.Value then unpin() return end

        fire("Join Race")
        task.wait(0.8)
        unpin()

        local _, hrp, hum = character()
        if not hrp or not hum then return end

        -- 2. Forward from the line at a multiple of the game's own speed.
        STATE.phase = "racing"
        local z        = START_Z + 2
        local last     = os.clock()
        local nextIdx  = 1
        local pending  = nil
        local winsSeen = num("Wins")
        local gained   = 0
        local paid     = 0
        local missed   = false

        local conn = RunService.Heartbeat:Connect(function()
            if not alive() then return end
            local now = os.clock()
            local dt  = now - last
            last = now
            -- The client ramps WalkSpeed by itself over the first seconds of a
            -- race, so reading it live means the boost grows with the run and
            -- with every shoe, upgrade and rebirth without a constant anywhere.
            local legit = (hum.WalkSpeed * 3) / info.nerf
            z = z + legit * CONFIG.boostFactor * dt
            hrp.CFrame = CFrame.new(info.centreX, 25, z)
        end)

        while alive() and Values.RaceActive.Value and CONFIG.auto and CONFIG.autoRace do
            local studs = studsNow(info)
            STATE.studs = studs
            local wins  = num("Wins")

            -- The shops keep spending through the race, so the balance goes
            -- DOWN as well as up.  Only a rise counts as a payout, and the
            -- watermark is resynced on every pass - comparing against a stale
            -- pre-purchase high read seven paid milestones as unpaid and
            -- throttled the boost from 6x to 1x for nothing.
            if wins > winsSeen then
                gained = gained + (wins - winsSeen)
                paid = paid + 1
                STATE.milestones = STATE.milestones + 1
                pending  = nil
                nextIdx  = math.min(nextIdx + 1, #info.milestones + 1)
            end
            winsSeen = wins

            local target = info.milestones[nextIdx]
            if target then
                if studs >= target.Studs then
                    if not pending then
                        pending = os.clock()
                    elseif CONFIG.autoTune and paid > 0
                       and os.clock() - pending > CONFIG.payGrace then
                        -- `paid > 0` is the guard that makes this safe: a race
                        -- that was joined after the start line pays NOTHING at
                        -- all, and reading that as "too fast" cut the boost
                        -- from 6x to 1x five times in a row for no reason.
                        -- Passed and not paid: the server stopped crediting,
                        -- which is the only symptom the speed ceiling has.
                        CONFIG.boostFactor = math.max(CONFIG.minFactor, CONFIG.boostFactor * 0.65)
                        STATE.throttled = STATE.throttled + 1
                        missed = true
                        note("milestone %d went unpaid - boost down to %.1fx",
                            nextIdx, CONFIG.boostFactor)
                        pending = nil
                        nextIdx = nextIdx + 1
                    end
                end
            end

            task.wait(0.4)
        end

        conn:Disconnect()
        unpin()

        STATE.races     = STATE.races + 1
        STATE.lastRace  = gained
        STATE.racedWins = STATE.racedWins + gained
        STATE.studs     = 0

        -- A clean race with headroom left is allowed to creep back up; a race
        -- that lost a milestone already paid for itself with the cut above.
        if CONFIG.autoTune and not missed and paid > 0 then
            CONFIG.boostFactor = math.min(CONFIG.maxFactor, CONFIG.boostFactor * 1.05)
        end
        note("race #%d: +%s wins (%d milestones, boost %.1fx)",
            STATE.races, abbrev(STATE.lastRace), paid, CONFIG.boostFactor)
    end)

    unpin()
    raceBusy = false
    if not ok then note("race failed: %s", tostring(err)) end
end

----------------------------------------------------------------------------
-- training
----------------------------------------------------------------------------

local function bestTreadmill()
    local best = nil
    local folder = workspace:FindFirstChild("Treadmills")
    local count = folder and #folder:GetChildren() or 0
    for i = 1, math.max(count, 1) do
        if Treadmills[i] then
            local ok, can = pcall(TreadmillLib.CanUse, plr, i)
            if ok and can then best = i else break end
        end
    end
    return best
end

local function train()
    if not CONFIG.autoTrain then return end
    local best = bestTreadmill()
    if not best then return end
    if plr:GetAttribute("Treadmill") ~= best then
        unpin()
        fire("Use Treadmill", best)
        STATE.trained = STATE.trained + 1
        note("training on treadmill %d (+%s speed)", best, abbrev(Treadmills[best].Gives or 0))
    end
    STATE.phase = "training"
end

local function dismount()
    if plr:GetAttribute("Treadmill") then fire("Dismount Treadmill") task.wait(0.3) end
end

----------------------------------------------------------------------------
-- spending
----------------------------------------------------------------------------

local function bought(key, name)
    local t = V(key)
    return type(t) == "table" and t[name] == true
end

-- Rank a catalogue against what is WORN, never against the cheapest entry, and
-- drop everything carrying a ProductId - those are the Robux twins and they
-- have no wins price at all.
local function bestAffordable(catalogue, ownedKey, equippedKey, score)
    local wins    = num("Wins")
    local worn    = V(equippedKey)
    local wornScore = (worn and catalogue[worn]) and score(catalogue[worn]) or -1
    local pickName, pickScore, pickCost, ownedBest, ownedBestScore
    for name, entry in pairs(catalogue) do
        if type(entry) == "table" and not entry.ProductId and not entry.Exclusive
           and type(entry.Cost) == "number" then
            local s = score(entry)
            if bought(ownedKey, name) then
                if s > (ownedBestScore or -1) then ownedBest, ownedBestScore = name, s end
            elseif entry.Cost <= wins and s > wornScore and s > (pickScore or -1) then
                pickName, pickScore, pickCost = name, s, entry.Cost
            end
        end
    end
    return pickName, pickCost, ownedBest, ownedBestScore, wornScore
end

local function shopStep(catalogue, ownedKey, equippedKey, buyAction, equipAction, score, label)
    local pick, cost, ownedBest, ownedBestScore, wornScore =
        bestAffordable(catalogue, ownedKey, equippedKey, score)

    -- Something better is already owned but not worn (a rebirth or a reroll
    -- can leave it that way) - equipping costs nothing, so do that first.
    if ownedBest and ownedBestScore and ownedBestScore > wornScore then
        invoke(equipAction, ownedBest)
        note("%s: equipped %s", label, ownedBest)
        return true
    end

    if pick then
        local before = num("Wins")
        local ok, msg = invoke(buyAction, pick)
        task.wait(0.4)
        local after = num("Wins")
        if ok and after < before then
            invoke(equipAction, pick)
            STATE.spent[label] = (STATE.spent[label] or 0) + (before - after)
            note("%s: bought %s for %s", label, pick, abbrev(cost))
            return true
        end
        note("%s: %s refused (%s)", label, pick, tostring(msg))
    end
    return false
end

-- `InvokeServer("Rebirth", n)` takes the INDEX into `Tables.Rebirths`, not the
-- number of rebirths: index 1 is 1 rebirth, 2 is 5, 3 is 20 ... 25 is 1e15.
-- Passing the amount answers "Not unlocked" and looks exactly like a currency
-- refusal.  Which indices exist at all is `RebirthsSkipsUpgrade`, and only
-- `i <= RebirthsSkipsUpgrade` is accepted.
local function doRebirth()
    if not CONFIG.autoRebirth then return false end
    local rebirths = num("Rebirths")
    local speed    = num("Speed")
    local unlocked = math.max(1, num("RebirthsSkipsUpgrade", 1))

    local bestIdx, bestAmount, bestCost
    for i = 1, unlocked do
        local amount = RebirthTiers[i]
        if amount then
            local ok, cost = pcall(RebirthLib.GetRebirthCost, plr, amount, rebirths)
            if ok and type(cost) == "number" and cost <= speed
               and amount >= math.min(CONFIG.rebirthBatch, RebirthTiers[unlocked] or 1)
               and amount > (bestAmount or 0) then
                bestIdx, bestAmount, bestCost = i, amount, cost
            end
        end
    end
    if not bestIdx then return false end

    local before = num("Rebirths")
    local ok, msg = invoke("Rebirth", bestIdx)
    task.wait(0.6)
    local after = num("Rebirths")
    if after > before then
        note("rebirth +%s (now %s, %s speed)",
            abbrev(after - before), abbrev(after), abbrev(bestCost or 0))
        return true
    end
    if msg then note("rebirth refused: %s", tostring(msg)) end
    return false
end

local function doUpgrades()
    if not CONFIG.autoUpgrade then return false end
    -- Gems only come out of race milestones, so the order is the one that
    -- feeds the race back: more wins per milestone, then the speed cap, then
    -- the speed gain, then the gem faucet itself.
    -- "More Rebirth Skips" is first because it starts at ZERO gems and each
    -- level unlocks the next rebirth tier - without it only the 1-at-a-time
    -- button exists and a 71-rebirth bank has to be spent one call at a time.
    local order = { "More Rebirth Skips", "More Wins", "Top Speed", "More Speed",
                    "Gems Chance", "More Gems", "Egg Luck", "Critical Gems" }
    local gems = num("Gems")
    for _, name in ipairs(order) do
        local entry = Upgrades[name]
        if entry and entry.UpgradeCosts and entry.StatName then
            local level = num(entry.StatName)
            if not entry.Max or level < entry.Max then
                local okc, cost = pcall(entry.UpgradeCosts, level)
                if okc and type(cost) == "number" and cost <= gems then
                    local before = num("Gems")
                    invoke("Upgrade", name)
                    task.wait(0.3)
                    if num("Gems") < before then
                        STATE.spent.upgrades = (STATE.spent.upgrades or 0) + (before - num("Gems"))
                        note("upgrade %s -> %d (%s gems)", name, level + 1, abbrev(cost))
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function doEggs()
    if not CONFIG.autoEgg then return false end
    local wins  = num("Wins")
    local world = num("CurrentWorld", 1)
    local budget = wins * CONFIG.eggShare
    local best, bestCost
    for name, entry in pairs(Eggs) do
        if type(entry) == "table" and not entry.Exclusive
           and entry.Currency == "Wins" and type(entry.Cost) == "number"
           and (entry.WorldNumber or 1) <= world then
            if entry.Cost <= budget and entry.Cost > (bestCost or -1) then
                best, bestCost = name, entry.Cost
            end
        end
    end
    if not best then return false end
    local amount = math.max(1, math.min(num("MaxEggOpen", 1), math.floor(budget / bestCost)))
    local before = num("Wins")
    invoke("Hatch Egg", best, amount)
    task.wait(0.8)
    if num("Wins") < before then
        STATE.spent.eggs = (STATE.spent.eggs or 0) + (before - num("Wins"))
        if CONFIG.autoPets then invoke("Pet", { Action = "EquipBest" }) end
        note("hatched %dx %s", amount, best)
        return true
    end
    return false
end

local function doWorld()
    if not CONFIG.autoWorld then return false end
    local unlocked = num("WorldsUnlocked", 1)
    local current  = num("CurrentWorld", 1)
    if unlocked > current then
        invoke("Set Current World", unlocked)
        task.wait(0.5)
        if num("CurrentWorld", 1) > current then
            note("moved to world %d (%s)", unlocked, Worlds[unlocked] and Worlds[unlocked].WorldName or "?")
            return true
        end
    end
    return false
end

-- Ten achievement ladders, ten tiers each, and every tier is a permanent
-- percentage.  `Stat` is the counter the tier is measured against and
-- `AchievementStat` is how many tiers have already been taken, so the next
-- claimable tier is always `AchievementStat + 1` - the claim wants the
-- category NAME and that tier INDEX.
local function doAchievements()
    if not CONFIG.autoAchieve then return false end
    for name, cat in pairs(Achievements) do
        if type(cat) == "table" and cat.Rewards and cat.Stat and cat.AchievementStat then
            local have   = num(cat.Stat)
            local claimed = num(cat.AchievementStat)
            local tier   = cat.Rewards[claimed + 1]
            if tier and type(tier.Requirement) == "number" and have >= tier.Requirement then
                local ok = invoke("Claim Achievement", name, claimed + 1)
                task.wait(0.3)
                if num(cat.AchievementStat) > claimed then
                    note("achievement %s tier %d (%s)", name, claimed + 1,
                        tostring(tier.Boost or ""))
                    return true
                end
                if not ok then return false end
            end
        end
    end
    return false
end

-- Pets are a straight multiplier and the inventory caps at `PetStorage`;
-- hatching stops in silence once it is full, which reads exactly like an egg
-- that cannot be afforded.  Power comes from the game's own
-- `PetLib.CalculatePetPower`, never from a rarity guess.
local function petPower(id, entry)
    local ok, p = pcall(PetLib.CalculatePetPower, plr, id)
    if ok and type(p) == "number" then return p end
    -- Fallback while the lib is unhappy: the variant tier and the size are
    -- what the game itself multiplies by.
    return (entry and ((entry.Tier or 1) * 10 + (entry.Size or 1))) or 0
end

local function doPets()
    if not CONFIG.autoPets then return false end
    invoke("Pet", { Action = "EquipBest" })

    local pets = V("Pets")
    if type(pets) ~= "table" then return false end
    local count = 0
    local ranked = {}
    for id, entry in pairs(pets) do
        count = count + 1
        ranked[#ranked + 1] = { id = id, power = petPower(id, entry) }
    end
    local storage = num("PetStorage", 50)
    if count < storage - 3 then return false end

    table.sort(ranked, function(a, b) return a.power < b.power end)
    local cull = {}
    for i = 1, math.min(#ranked, math.max(1, math.floor(storage * 0.4))) do
        cull[#cull + 1] = ranked[i].id
    end
    if #cull == 0 then return false end
    invoke("Pet", { Action = "Delete", Pets = cull })
    task.wait(0.5)
    note("pet storage %d/%d - deleted %d of the weakest", count, storage, #cull)
    return true
end

local function craftPets()
    if not CONFIG.autoCraft then return end
    local pets = V("Pets")
    if type(pets) ~= "table" then return end
    local ids = {}
    for id in pairs(pets) do ids[#ids + 1] = id end
    if #ids < 4 then return end
    -- Both machines take the whole candidate list and work out the groups
    -- themselves; a refusal simply means nothing had four of a kind yet.
    invoke("Pet", { Action = "CraftAllGolden",  Pets = ids })
    invoke("Pet", { Action = "CraftAllRainbow", Pets = ids })
end

local claimedOnce = false
local function freebies()
    if not CONFIG.autoClaim then return end
    if not claimedOnce then
        claimedOnce = true
        if CONFIG.autoCodes then
            -- The only code the client knows about is the one in the place
            -- description; a constants sweep found no list on the client.
            for _, code in ipairs({ "update6" }) do invoke("Redeem Code", code) end
        end
        invoke("Claim Daily")
        invoke("Claim Group", "dont exploit me flis!")
    end
    invoke("Claim Free Reward")
end

local function usePotions()
    if not CONFIG.autoPotion then return end
    local items = V("Items")
    if type(items) ~= "table" then return end
    if (items["Win Potion"] or 0) > 0 and num("DoubleWinTimer") <= 0 then
        invoke("Use Item", "Win Potion", 1)
    end
    if (items["Speed Potion"] or 0) > 0 and num("DoubleSpeedTimer") <= 0 then
        invoke("Use Item", "Speed Potion", 1)
    end
end

----------------------------------------------------------------------------
-- loops
----------------------------------------------------------------------------

local function loop(period, fn)
    task.spawn(function()
        while alive() do
            if CONFIG.auto then pcall(fn) end
            task.wait(period)
        end
    end)
end

-- Racing and training both want the body, so one scheduler owns it.  While a
-- rebirth batch is out of reach the wins are worth less than the speed that
-- unlocks the next treadmill tier, so the race is skipped on purpose.
-- A race that was joined after the start line pays nothing, so only a race we
-- have watched START counts.  Loading the script mid-race used to run the
-- whole 120 seconds for zero wins.
local prevActive = Values.RaceActive.Value
local freshRace  = false

task.spawn(function()
    while alive() do
        -- Tracked whatever the master toggle says, or switching the script on
        -- mid-break would miss the edge and idle through the next race.
        local racing = Values.RaceActive.Value
        if racing and not prevActive then freshRace = true end
        if not racing then freshRace = false end
        prevActive = racing

        if CONFIG.auto then
            local wantRace = CONFIG.autoRace and racing and freshRace

            if wantRace and CONFIG.trainForRebirth and CONFIG.autoRebirth then
                local ok, amount = pcall(RebirthLib.GetMaxAmount, plr,
                    num("Rebirths"), num("Speed"))
                if ok and (amount or 0) < CONFIG.rebirthBatch then
                    local best = bestTreadmill()
                    -- Only worth skipping while a better treadmill is actually
                    -- waiting on rebirths; otherwise racing is strictly better.
                    local nextT = Treadmills[(best or 0) + 1]
                    if nextT and num("Speed") >= (nextT.Requirement or math.huge) then
                        wantRace = false
                    end
                end
            end

            if wantRace then
                dismount()
                usePotions()
                pcall(runRace)
            else
                -- `TreadmillLib.CanUse` answers "Cant trail while racing!" for
                -- every treadmill as long as the player is still in the race
                -- state, so a run we are not going to score has to be left or
                -- the body just stands there earning nothing.
                local ok, inRace = pcall(Paper.State.IsInState, plr, "Race")
                if ok and inRace then fire("Leave Race") task.wait(0.4) end
                STATE.phase = racing and (freshRace and "training (skipping race)"
                    or "waiting for the next race") or "training"
                pcall(train)
            end
        else
            STATE.phase = "off"
            unpin()
        end
        -- Fine grained on purpose: the line-up already costs 1.6s of a 120s
        -- race and a one second poll on top of it is distance thrown away.
        task.wait(0.25)
    end
end)

loop(4, function()
    refresh()
    -- Shops are pure remote calls and need no body, so they keep running
    -- through a race - a race is 120 of every 135 seconds and gating the
    -- spending on "not racing" left the balance sitting untouched.  The world
    -- switch is the one exception: it teleports, which would end the run.
    -- One purchase per pass, and every step re-reads the balance, so a four
    -- second old number can never decide a purchase.
    if not raceBusy and doRebirth() then return end
    if not raceBusy and doWorld() then return end
    if CONFIG.autoShoe and shopStep(Shoes, "BoughtShoes", "EquippedShoe",
        "Buy Shoe", "Equip Shoe",
        function(e) return (e.WalkSpeed or 0) * 1000 + (e.Wins or 0) end, "shoe") then return end
    if CONFIG.autoPartner and shopStep(Partners, "BoughtPartners", "EquippedPartner",
        "Buy Partner", "Equip Partner",
        function(e) return (e.TrainSpeed or 0) * 1000 + (e.Wins or 0) end, "partner") then return end
    if CONFIG.autoTrail and shopStep(Trails, "BoughtTrails", "EquippedTrail",
        "Buy Trail", "Equip Trail",
        function(e) return e.Cost or 0 end, "trail") then return end
    if doUpgrades() then return end
    if doAchievements() then return end
    if doEggs() then return end
end)

loop(30, freebies)

loop(15, function()
    doPets()
    craftPets()
end)

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__SPEEDTRAIN_WIN then pcall(function() _G.__SPEEDTRAIN_WIN:Destroy() end) end

local win = UI.Window({
    title = "SPEED", accentTitle = "TRAINING", subtitle = "seltonmt",
    width = 820, height = 582,
})
_G.__SPEEDTRAIN_WIN = win

local page = win:Page("FARMING", UI.icon and UI.icon.bolt or nil)

local race = page:Card("RACE", 1):Accent()
race:Toggle("Auto race", CONFIG.autoRace, function(v) CONFIG.autoRace = v end,
    "joins at the start pad and runs the track for the milestone wins")
race:Slider("Boost (x game speed)", 1, 10, math.floor(CONFIG.boostFactor),
    function(v) CONFIG.boostFactor = v end)
race:Toggle("Tune the boost automatically", CONFIG.autoTune,
    function(v) CONFIG.autoTune = v end,
    "cuts the boost whenever a milestone is passed without being paid")
race:Toggle("Use win potions", CONFIG.autoPotion, function(v) CONFIG.autoPotion = v end,
    "burns a Win Potion before each race", UI.theme and UI.theme.warn)

local train = page:Card("TRAINING", 2)
train:Toggle("Auto train", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
    "warps onto the best treadmill between races - no walking involved")
train:Toggle("Train instead of racing", CONFIG.trainForRebirth,
    function(v) CONFIG.trainForRebirth = v end,
    "skips a race while a treadmill is waiting only on rebirths")
train:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "rebirth costs speed: 500 x (rebirths + 1) each")
train:Slider("Rebirth batch", 1, 50, CONFIG.rebirthBatch,
    function(v) CONFIG.rebirthBatch = v end)

local spend = page:Card("SPENDING", 1)
spend:Toggle("Shoes", CONFIG.autoShoe, function(v) CONFIG.autoShoe = v end,
    "walk speed is the race distance - the biggest wins lever")
spend:Toggle("Partners", CONFIG.autoPartner, function(v) CONFIG.autoPartner = v end,
    "train speed and a wins bonus")
spend:Toggle("Trails", CONFIG.autoTrail, function(v) CONFIG.autoTrail = v end)
spend:Toggle("Eggs and pets", CONFIG.autoEgg, function(v) CONFIG.autoEgg = v end,
    "hatches the best egg this world allows and equips the best pets")
spend:Slider("Egg budget (% of wins)", 5, 75, math.floor(CONFIG.eggShare * 100),
    function(v) CONFIG.eggShare = v / 100 end)
spend:Toggle("Gem upgrades", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
    "more wins, top speed, more speed - in that order")
spend:Toggle("Craft golden and rainbow pets", CONFIG.autoCraft,
    function(v) CONFIG.autoCraft = v end,
    "fuses four of a kind and clears the weakest when storage fills up")
spend:Toggle("Claim achievements", CONFIG.autoAchieve, function(v) CONFIG.autoAchieve = v end,
    "ten ladders of permanent percentages, claimed tier by tier")
spend:Toggle("Follow world unlocks", CONFIG.autoWorld, function(v) CONFIG.autoWorld = v end,
    "each world multiplies the whole milestone ladder")
spend:Toggle("Free rewards and codes", CONFIG.autoClaim, function(v) CONFIG.autoClaim = v end)

local readout = page:Card("STATUS", 0)
local out = readout:Readout(10)

task.spawn(function()
    while alive() do
        pcall(function()
            local info = raceInfo()
            local studs = info and studsNow(info) or 0
            out:set({
                "RUN",
                string.format("  phase %s   world %d   boost %.1fx",
                    STATE.phase, STATE.world, CONFIG.boostFactor),
                string.format("  studs %s / %s   milestones %d   throttled %d",
                    abbrev(math.floor(studs)),
                    abbrev(info and info.finalStuds or 0),
                    STATE.milestones, STATE.throttled),
                string.format("  races %d   last race +%s   total raced %s",
                    STATE.races, abbrev(STATE.lastRace), abbrev(STATE.racedWins)),
                "ECONOMY",
                string.format("  wins %s   gems %s", abbrev(STATE.wins), abbrev(STATE.gems)),
                string.format("  speed %s   rebirths %s   treadmill %s",
                    abbrev(STATE.speed), abbrev(STATE.rebirths),
                    tostring(plr:GetAttribute("Treadmill") or "-")),
                string.format("  shoe %s   partner %s",
                    tostring(V("EquippedShoe")), tostring(V("EquippedPartner"))),
                "NOTE",
                "  " .. tostring(STATE.note),
            })
            win:SetStat(1, abbrev(STATE.wins), "wins")
            win:SetStat(2, abbrev(STATE.speed), "speed")
            win:SetStat(3, abbrev(STATE.rebirths), "rebirths")
            win:SetStatus(string.format("%s wins   %s speed   world %d   %s",
                abbrev(STATE.wins), abbrev(STATE.speed), STATE.world, STATE.phase))
        end)
        task.wait(0.5)
    end
end)

pcall(function()
    win:Home()
    win:SetMaster(CONFIG.auto, "Auto farm running")
    win:OnMaster(function(on) CONFIG.auto = on end)
end)

_G.__SPEEDTRAIN_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    V = V, fire = fire, invoke = invoke,
    raceInfo = raceInfo, studsNow = studsNow, runRace = runRace,
    train = train, dismount = dismount, bestTreadmill = bestTreadmill,
    doRebirth = doRebirth, doUpgrades = doUpgrades, doEggs = doEggs,
    doWorld = doWorld, freebies = freebies, shopStep = shopStep,
    doAchievements = doAchievements, doPets = doPets, craftPets = craftPets,
    pinAt = pinAt, unpin = unpin,
}

refresh()
note("ready - master toggle starts it")
