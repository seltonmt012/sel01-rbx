--[[
    minemountain.lua - "[<E2><9B><B0>] Mine a Mountain"  (place 125927821145949)

    Verified against server-side values on 2026-08-21, account polpne.

    The loop the game wants: climb the mountain, mine crystals out of the rock,
    carry them down under a weight cap, sell them to the Crystal Buyer, spend
    the cash on carrying more.  A fresh mountain is generated every hour.

    How this game is wired, and why the script looks the way it does:

    * **A SMALL crystal does not have to be mined at all.**  Every crystal in
      `Workspace.Things.Crystals` carries its own ProximityPrompt, and for a
      `SizeClass` of "S" firing that prompt takes it straight out of the rock -
      no pickaxe swing, no terrain carving, whatever its tier.
    * **A MEDIUM or LARGE one is gated on the equipped pickaxe's RANK**, and
      this is the whole economy of the game.  See the long note above
      `pickaxeRank()`: rank must be >= the crystal's tier or the server refuses
      the break in silence.  Rank 1 leaves every crystal worth more than a few
      thousand dollars in the ground; rank 6 turned the exact two crystals that
      had refused everything into a $157M and a $27M pickup on a plain prompt.
      Swinging the pickaxe does NOT help - `DigRequest` carves terrain only.
    * **The server runs the hold timer itself.**  `fireproximityprompt(prompt)`
      opens the hold and the crystal lands in the inventory `HoldDuration`
      seconds later (1s for tier 1 up to 6.5s for tier 9).  There is no way to
      shorten it.  `Remotes.CrystalHoldComplete` looks exactly like the skip -
      the published rscripts autofarms all fire it - but it does NOTHING: a
      tier 1 crystal "succeeded" only because its hold is 1.0s and the test
      waited 1.4s, and the identical call against tier 2 (1.5s hold) was
      refused.  Do not re-add it.
    * **The body has to be pinned hard.**  The game runs a traction/ragdoll
      system that slides the character off any slope, so a plain CFrame write
      lands 8 studs from the target while reporting success and every pickup is
      then silently refused.  The pin writes CFrame **and** zeroes
      `AssemblyLinearVelocity` every Heartbeat, and the drift is checked before
      anything is fired.
    * **The base is a no-dig zone.**  `Modules.Tools.ZoneCheck.isInNoDiggingZone`
      is true for the whole shop area, which is where the decorative crystals
      around the stalls sit.  Digging there does nothing at all.
    * `SellRequest:FireServer("all")` sells the whole bag.  The bare call with
      no argument sells nothing and reports nothing.  Selling IS position gated
      - refused from 248 studs - so every trip has to come back down.
    * `UpgradeBuy:FireServer(key, index)` where the index is a BUNDLE, not a
      count: 1 buys one level, 2 buys five, 3 buys ten.  Any other number is
      ignored in silence.  `UpgradePrices:InvokeServer(key)` returns the three
      bundle prices for the current level.  Only "Weight" and "Air" exist.
    * **Backpacks do nothing, whatever the catalog says.**  Every entry in
      `ShopCatalog.Backpacks` advertises a `stats.WeightLimit` from 25 up to
      1700, which reads exactly like the carry ladder - it is not.  Measured:
      four of them bought for $3,900 and then equipped in turn (limit 25 ->
      75 -> 120) left `RealStats.CarryWeight` at 33 the whole time and the
      freeze threshold unchanged.  `CarryWeight` is the effective cap and the
      Weight upgrade is the only thing that moves it.  Never buy a backpack.
    * **The Gear category cannot be bought at all.**  `ShopCatalog.Gear` lists
      three jackets (`Warmth` 1-3) and three boots (`IceGrip` 1-3), but
      `ShopCatalog.getCategory` answers nil for every one of their ids and
      `ShopBuy` charges $0 and grants nothing.  There is no `Inventory.Gear`
      folder either.  It is unreleased content, so warmth is NOT purchasable
      and the altitude ceiling below is the only defence against freezing.
    * **Above the freeze line the character dies, and death is silent.**
      `FreezeThresholdStuds` (198.5 as measured, it moves) is where
      `IsFreezing` turns on.  A grab at y=563 came back with every prompt
      still Enabled, the crystal still in the world and `Humanoid.Health` at
      **0** - the body had frozen to death during the 5s hold and a corpse
      picks nothing up.  Nothing reports this; only the health does.
    * **Dying needs `ReviveBase`.**  The game does not auto-respawn; the
      corpse just lies there and every later action fails.
      `Remotes.ReviveBase:FireServer()` is the "Back to Base" button on the
      death panel and it puts the body at the shops with full health.
    * `PlayerData.RealStats` is the state oracle (Cash, CarryWeight, Height,
      AirCapacity, PlotCapacity, ...) and the carried crystals are RayValues
      under `PlayerData.Inventory.Crystals`, each with Value / WeightKg / Tier /
      UID as attributes.
    * Pickups produce **zero** outgoing remote traffic - prompts are handled
      server side and are invisible to a __namecall hook - so a pickup can only
      ever be confirmed by the inventory count moving.

    Never touched: every Robux product id in BombShopConfig / RadarShopConfig,
    the gamepass showcase, the ExtremeNuke offer and the gift shop.  Bombs and
    radars all have a real cashPrice as well, but radars only reveal crystals
    the script already reads straight out of the workspace, so they are worth
    nothing here.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 20)
local Modules = ReplicatedStorage:WaitForChild("Modules", 20)

local ZoneCheck    = require(Modules.Tools.ZoneCheck)
local ShopCatalog  = require(Modules.Shop.ShopCatalog)

local PlayerData = LocalPlayer:WaitForChild("PlayerData", 30)
local RealStats  = PlayerData:WaitForChild("RealStats", 20)
local Inventory  = PlayerData:WaitForChild("Inventory", 20)
local Carried    = Inventory:WaitForChild("Crystals", 20)

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    autoFarm      = false,  -- the master switch, off until the panel says so
    autoSell      = true,   -- SellRequest("all") at the buyer, position gated
    autoWeight    = true,   -- the Weight upgrade, the only real carry lever
    autoAir       = true,   -- dirt cheap: 10 -> 60 air measured for $10
    autoRevive    = true,   -- ReviveBase; nothing works again until it is fired
    autoRewards   = true,   -- group reward and the tutorial reward
    autoPickaxe   = true,   -- rank gates the whole M/L half of the field

    minValue      = 0,      -- ignore crystals worth less than this
    fillRatio     = 0.92,   -- head for the buyer once the bag is this full
    settle        = 1.2,    -- seconds pinned before firing anything
    holdMargin    = 0.9,    -- extra seconds allowed on top of HoldDuration
    pinHeight     = 3,      -- studs above the crystal to park the body
    maxDrift      = 2.5,    -- studs; over this the pin has failed, skip it
    scanEvery     = 4,      -- seconds between field rescans
    weightReserve = 0.5,    -- share of cash the Weight upgrade may spend
    freezeMargin  = 25,     -- studs of headroom kept under the freeze line
    ignoreFreeze  = false,  -- climb anyway and pay for it with deaths
    maxStrikes    = 2,      -- refusals before a crystal is given up on
    fitMargin     = 0.2,    -- kg kept free so a rounding error cannot refuse
    prizeFactor   = 3,      -- sell early when an empty bag unlocks this much more
}

local STATE = {
    cash = 0, carried = 0, capacity = 0, height = 0,
    field = 0, taken = 0, missed = 0, sold = 0, earned = 0,
    weightLevels = 0, revives = 0, phase = "starting", note = "",
    target = "-", lastSale = 0, ceiling = 0, tooHigh = 0,
    upgrades = 0, trips = 0, prices = {}, rank = 0, tooHard = 0, pickaxe = "-",
}

_G.__MINEMTN = (_G.__MINEMTN or 0) + 1
local GEN = _G.__MINEMTN
local function alive() return _G.__MINEMTN == GEN end

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

-- A crystal that refuses to be picked up twice is not tried again this run.
-- Nothing here reports a reason, so a blacklist is the only way to stop the
-- farm from parking on one unreachable crystal forever.
local refused = {}
local strikes = {}

local function abbreviate(n)
    n = tonumber(n) or 0
    local units = { "", "K", "M", "B", "T", "Qd", "Qn" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do n = n / 1000 i = i + 1 end
    if i == 1 then return string.format("%d", n) end
    return string.format("%.2f%s", n, units[i])
end

----------------------------------------------------------------------------
-- oracles
----------------------------------------------------------------------------

local function stat(name, default)
    local value = RealStats:FindFirstChild(name)
    if value then return value.Value end
    return default
end

local function cash()     return stat("Cash", 0) end
local function capacity() return stat("CarryWeight", 0) end

-- The carried weight is not published as a number anywhere; it is the sum of
-- the WeightKg attributes on the RayValues in the inventory folder.
local function carriedWeight()
    local total, count = 0, 0
    for _, item in ipairs(Carried:GetChildren()) do
        total = total + (item:GetAttribute("WeightKg") or 0)
        count = count + 1
    end
    return total, count
end

local function character()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    return char, root, char and char:FindFirstChildOfClass("Humanoid")
end

local function health()
    local _, _, humanoid = character()
    return humanoid and humanoid.Health or 0
end

-- Only one thing may own the body at a time.  Without this the spending loop
-- warped the character to the upgrade stall while the farm loop was half way
-- through a 4 second hold, and the pickup then failed for a reason that looks
-- exactly like a server refusal - two crystals were blacklisted that way
-- before the lock existed.
local busy = nil

local function withBody(name, fn)
    if busy then return false end
    busy = name
    STATE.phase = name
    local ok, err = pcall(fn)
    busy = nil
    if not ok then note("%s: %s", name, tostring(err)) end
    return ok
end

-- The freeze line moves (measured 160 on one mountain, 198.5 on the next), so
-- it is read live rather than hardcoded.  Everything above it kills the body
-- part-way through a hold, which looks exactly like a refused pickup.
--
-- FreezeThresholdStuds is an ALTITUDE, not a world Y: the base sits at y~29
-- and reads 9m on the HUD, so the threshold has to be measured from the base
-- rather than from zero or the ceiling lands ~20 studs too low.
local function baseHeight()
    local things = workspace:FindFirstChild("Things")
    local prox = things and things:FindFirstChild("SellProx")
    return prox and prox.Position.Y or 29
end

local function freezeCeiling()
    local threshold = LocalPlayer:GetAttribute("FreezeThresholdStuds") or 160
    return baseHeight() + threshold - CONFIG.freezeMargin
end

-- The game never respawns by itself: the corpse lies where it fell and every
-- prompt, sale and purchase after that silently does nothing.  This is the
-- "Back to Base" button on the death panel.
local function reviveIfDead()
    if health() > 0 then return false end
    if not CONFIG.autoRevive then
        note("dead - auto revive is off")
        return false
    end
    pcall(function() Remotes.ReviveBase:FireServer() end)
    local deadline = os.clock() + 8
    while alive() and os.clock() < deadline and health() <= 0 do
        task.wait(0.5)
    end
    if health() > 0 then
        STATE.revives = STATE.revives + 1
        note("died - revived at base (%d)", STATE.revives)
        return true
    end
    return false
end

----------------------------------------------------------------------------
-- the pin
----------------------------------------------------------------------------

-- Writing the CFrame once is not enough: the game's traction system pulls the
-- body back down the slope within a frame or two, and every prompt fired from
-- the wrong place is refused without a word.  Zeroing the velocity each
-- Heartbeat is what actually holds it - measured drift 8.0 studs before,
-- 0.05 after.
local function pinTo(position)
    local _, root, humanoid = character()
    if not root then return nil end
    local goal = CFrame.new(position)
    return RunService.Heartbeat:Connect(function()
        if not root.Parent then return end
        root.CFrame = goal
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        if humanoid and humanoid.Parent then humanoid.PlatformStand = false end
    end)
end

local function driftFrom(position)
    local _, root = character()
    if not root then return math.huge end
    return (root.Position - position).Magnitude
end

-- Park the body, wait for it to settle, and report whether it actually got
-- there.  Everything in this script goes through here.
local function travelTo(position, settle)
    local pin = pinTo(position)
    if not pin then return nil, math.huge end
    task.wait(settle or CONFIG.settle)
    return pin, driftFrom(position)
end

----------------------------------------------------------------------------
-- the field
----------------------------------------------------------------------------

-- THE gate on this game's income, and it is invisible until you measure it.
--
-- A Small crystal is picked up, and any pickaxe (or none) will do.  A Medium or
-- Large one has to be BROKEN first, and the server refuses the break unless the
-- EQUIPPED pickaxe outranks the crystal's tier.  It refuses in total silence:
-- the prompt is Enabled, in range, fires Triggered, and the crystal simply
-- never arrives - measured 17 seconds of holding on a 51.5kg Apexarch worth
-- $157M with 147kg free and full health.  The only trace of the rule anywhere
-- is BoulderConfig.Break.wrongPickaxeMsg, "You need %s or better to break %s!".
--
-- Swinging the pickaxe at one does nothing either; DigRequest carves terrain,
-- it does not damage crystals.  26 swings, no change.
--
-- Proof: the same two crystals that refused everything with a rank 1 Weathered
-- Wood were both TAKEN on a plain prompt the moment a rank 6 Obsidian Edge was
-- equipped.
local function pickaxeRank()
    local equipped = Inventory.Pickaxes:FindFirstChild("Equipped")
    local id = equipped and equipped.Value
    if not id then return 0 end
    return (ShopCatalog.PickaxeRarityRank or {})[id] or 0
end

local function canTake(sizeClass, tier, rank)
    if sizeClass == "S" or sizeClass == nil then return true end
    return tier <= rank
end

local function crystalFolders()
    local list = {}
    local things = workspace:FindFirstChild("Things")
    local wall = things and things:FindFirstChild("Crystals")
    if wall then list[#list + 1] = wall end
    local loot = workspace:FindFirstChild("DroppedCrystals")
    if loot then list[#list + 1] = loot end
    return list
end

-- Rank by value per kilo, not by value.  The bag is the constraint, so a
-- 0.7kg crystal worth $46,800 beats a 19.8kg one worth $62,000,000 that will
-- never fit in the first place - and the ones that do not fit are dropped here
-- rather than being chased and refused.
local function survey(freeWeight)
    local found, total, tooHigh, tooHard = {}, 0, 0, 0
    local ceiling = CONFIG.ignoreFreeze and math.huge or freezeCeiling()
    STATE.ceiling = CONFIG.ignoreFreeze and -1 or ceiling
    local rank = pickaxeRank()
    STATE.rank = rank
    for _, folder in ipairs(crystalFolders()) do
        for _, part in ipairs(folder:GetChildren()) do
            if part:IsA("BasePart") then
                local uid = part:GetAttribute("UID")
                local value = part:GetAttribute("Value")
                local kg = part:GetAttribute("WeightKg")
                if uid and value and kg then
                    total = total + 1
                    if part.Position.Y > ceiling then
                        -- Above the freeze line the hold outlives the body.
                        tooHigh = tooHigh + 1
                    elseif not canTake(part:GetAttribute("SizeClass"),
                                       part:GetAttribute("Tier") or 0, rank) then
                        -- Needs a stronger pickaxe than the one equipped.
                        tooHard = tooHard + 1
                    elseif not refused[uid] and value >= CONFIG.minValue
                           and kg <= freeWeight - CONFIG.fitMargin then
                        local prompt = part:FindFirstChildWhichIsA("ProximityPrompt")
                        if prompt then
                            found[#found + 1] = {
                                part = part, prompt = prompt, uid = uid,
                                value = value, kg = kg,
                                tier = part:GetAttribute("Tier") or 0,
                                name = part:GetAttribute("CrystalName") or part.Name,
                                -- A pickup costs the same ~7 seconds whether
                                -- the crystal weighs 0.5kg or 70kg, so the
                                -- real currency is value per TRIP, not per
                                -- kilo.  Density only matters while the bag is
                                -- the binding constraint; once the Weight
                                -- upgrade has outgrown the field, ranking by
                                -- density picks tiny gems and the bag takes
                                -- forever to fill.  Blend the two: value,
                                -- penalised only by how much of the REMAINING
                                -- space the crystal eats.
                                score = value / (1 + kg / math.max(freeWeight, 1)),
                            }
                        end
                    end
                end
            end
        end
    end
    STATE.field = total
    STATE.tooHigh = tooHigh
    STATE.tooHard = tooHard
    table.sort(found, function(a, b) return a.score > b.score end)
    return found
end

-- One crystal, start to finish.  The prompt opens the hold server side and the
-- crystal appears in the inventory when the hold elapses; nothing is reported
-- back, so the inventory count is the only evidence a pickup happened.
local function collect(entry)
    local weight0, count0 = carriedWeight()

    -- The bag cap is checked again here, right before the trip, and a crystal
    -- that no longer fits is NOT blacklisted.  An over-cap pickup is refused in
    -- total silence - no message, no event, the prompt still fires Triggered -
    -- and the first version read that as "this crystal is unobtainable" and
    -- blacklisted it.  Since the survey ranks by value per kilo, the crystals
    -- being thrown away were the best ones on the mountain: a 74.4kg Heartmyth
    -- worth $263M was discarded because 44.9kg was already in the bag.
    if entry.kg > capacity() - weight0 then
        note("%s (%.1fkg) does not fit %.1fkg free - leaving it",
            entry.name, entry.kg, capacity() - weight0)
        return false
    end

    local pin, drift = travelTo(entry.part.Position + Vector3.new(0, CONFIG.pinHeight, 0))
    if not pin then return false end

    -- What matters is not landing on the crystal, it is landing inside its
    -- prompt.  A fixed 2.5 stud tolerance rejected a crystal that sat 2.7
    -- studs away from a prompt with a 16 stud reach, and because a skip
    -- recorded no strike the farm then re-picked the same one forever - three
    -- measured windows in a row earned nothing at all.  Budget against the
    -- prompt's own range instead, and count the skip.
    local allowed = math.max(CONFIG.maxDrift,
        math.min(entry.prompt.MaxActivationDistance * 0.6, 8))
    if drift > allowed then
        pin:Disconnect()
        strikes[entry.uid] = (strikes[entry.uid] or 0) + 1
        if strikes[entry.uid] >= CONFIG.maxStrikes then refused[entry.uid] = true end
        note("pin drifted %.1f studs off %s (allowed %.1f)", drift, entry.name, allowed)
        return false
    end

    if not entry.part.Parent then pin:Disconnect() return false end

    pcall(fireproximityprompt, entry.prompt)

    local deadline = os.clock() + entry.prompt.HoldDuration + CONFIG.holdMargin
    local got, died = false, false
    while alive() and os.clock() < deadline do
        task.wait(0.2)
        local _, count = carriedWeight()
        if count > count0 then got = true break end
        -- A corpse never completes a hold, and the prompt stays Enabled the
        -- whole time, so without this check the loop waits out the full
        -- duration and blames the crystal.
        if health() <= 0 then died = true break end
    end
    pin:Disconnect()

    if got then
        STATE.taken = STATE.taken + 1
        note("took %s ($%s, %.1fkg)", entry.name, abbreviate(entry.value), entry.kg)
    elseif died then
        note("died on %s at y=%.0f", entry.name, entry.part.Position.Y)
        reviveIfDead()
    else
        -- Two strikes before giving up on a crystal.  A single refusal is
        -- usually a transient - another player took it, the bag was fuller
        -- than the survey thought, the mountain reset mid-hold - and a
        -- one-strike blacklist quietly emptied the top of the ranking.
        STATE.missed = STATE.missed + 1
        strikes[entry.uid] = (strikes[entry.uid] or 0) + 1
        if strikes[entry.uid] >= CONFIG.maxStrikes then
            refused[entry.uid] = true
            note("%s refused %dx - blacklisted", entry.name, strikes[entry.uid])
        else
            note("%s refused (strike %d)", entry.name, strikes[entry.uid])
        end
    end
    return got
end

----------------------------------------------------------------------------
-- selling
----------------------------------------------------------------------------

local function sellPoint()
    local things = workspace:FindFirstChild("Things")
    local prox = things and things:FindFirstChild("SellProx")
    return prox and prox.Position
end

-- Selling is position gated: the identical call from 248 studs up the mountain
-- moved nothing, from 3 studs it paid out in full.
local function sellBag()
    local _, count = carriedWeight()
    if count == 0 then return false end

    local point = sellPoint()
    if not point then note("no Crystal Buyer in the workspace") return false end

    STATE.phase = "selling"
    local before = cash()
    local pin = travelTo(point + Vector3.new(0, CONFIG.pinHeight, 0), CONFIG.settle + 0.4)
    if not pin then return false end

    Remotes.SellRequest:FireServer("all")
    task.wait(1.2)
    pin:Disconnect()

    local gained = cash() - before
    if gained > 0 then
        STATE.sold = STATE.sold + count
        STATE.earned = STATE.earned + gained
        STATE.lastSale = gained
        note("sold %d crystals for $%s", count, abbreviate(gained))
        return true
    end

    note("sell refused - still carrying %d", count)
    return false
end

----------------------------------------------------------------------------
-- spending
----------------------------------------------------------------------------

local function stallPoint(name)
    local things = workspace:FindFirstChild("Things")
    local prox = things and things:FindFirstChild(name)
    return prox and prox.Position
end

-- The three prices are the 1 / 5 / 10 level bundles for the CURRENT level, so
-- the ten-pack is always exactly ten times the single.  Take the biggest
-- bundle the reserve allows; buying ten at once is the same price as ten
-- singles and costs one call instead of ten.
local function bestBundle(key, budget)
    local ok, prices = pcall(function() return Remotes.UpgradePrices:InvokeServer(key) end)
    if not ok or type(prices) ~= "table" then return nil end
    for index = 3, 1, -1 do
        local price = prices[index]
        if price and price > 0 and price <= budget then return index, price end
    end
    return nil
end

-- There are exactly TWO upgrades in this game.  Probing UpgradePrices with
-- nineteen plausible key names (Luck, PlotCapacity, Speed, Warmth, Jetpack,
-- Reach, ...) returned a table for "Weight" and "Air" and nothing at all for
-- the other seventeen, so this list is complete rather than a starting point.
local UPGRADES = { "Weight", "Air" }

-- The live price board, refreshed on every visit so the panel can show what
-- the next rung costs instead of guessing.
local function priceBoard()
    local board = {}
    for _, key in ipairs(UPGRADES) do
        local ok, prices = pcall(function() return Remotes.UpgradePrices:InvokeServer(key) end)
        if ok and type(prices) == "table" and prices[1] then
            board[key] = { one = prices[1], five = prices[2], ten = prices[3] }
        end
    end
    STATE.prices = board
    return board
end

-- Called straight after a sale, which is the only moment the balance is at its
-- peak.  Weight goes first: it is the entire economy here, because every extra
-- kilo is more value carried per round trip, while Air only decides how long
-- the body survives inside a cave.
local function buyUpgrades()
    if not (CONFIG.autoWeight or CONFIG.autoAir) then return end
    local point = stallPoint("UpgradesProx")
    if not point then return end

    local pin = travelTo(point + Vector3.new(0, CONFIG.pinHeight, 0))
    if not pin then return end

    priceBoard()

    if CONFIG.autoWeight then
        for _ = 1, 6 do
            local budget = math.floor(cash() * CONFIG.weightReserve)
            local index = bestBundle("Weight", budget)
            if not index then break end
            local before = capacity()
            Remotes.UpgradeBuy:FireServer("Weight", index)
            task.wait(0.7)
            local after = capacity()
            if after <= before then break end
            STATE.weightLevels = stat("WeightUpgrades", 0)
            STATE.upgrades = STATE.upgrades + 1
            note("carry %d -> %d kg", before, after)
        end
    end

    -- Air only with what the Weight upgrade did not want, so it can never
    -- starve the one purchase that actually raises income.
    if CONFIG.autoAir then
        for _ = 1, 3 do
            local budget = math.floor(cash() * (1 - CONFIG.weightReserve))
            local index = bestBundle("Air", budget)
            if not index then break end
            local before = stat("AirCapacity", 0)
            Remotes.UpgradeBuy:FireServer("Air", index)
            task.wait(0.7)
            if stat("AirCapacity", 0) <= before then break end
            STATE.upgrades = STATE.upgrades + 1
        end
    end

    priceBoard()
    pin:Disconnect()
end

-- There is deliberately no gear buyer here.  ShopCatalog.Gear lists three
-- jackets and three boots with real prices, and buying any of them is a no-op:
-- getCategory answers nil for every id, ShopBuy charges $0 and grants nothing,
-- and no Inventory.Gear folder is ever created.  Unreleased content - if it
-- ships later, warmth is what lifts the altitude ceiling in survey().
--
-- There is no backpack buyer either; see the header.  They cost real money and
-- change nothing measurable.

-- The pickaxe is the single biggest lever in this game, not a side purchase.
-- Its rarity rank decides which crystals can be broken at all, and the jump is
-- brutal: with rank 1 the whole Medium and Large half of the field is
-- unobtainable, and those are the crystals worth $150M+ each while the Small
-- ones nearby are worth thousands.  So this climbs the entire affordable
-- ladder on every trip rather than buying one rung.
--
-- ShopBuy(id) equips what it buys, and the ladder is walked cheapest-first so
-- the most expensive affordable one ends up equipped.
local function buyPickaxe()
    if not CONFIG.autoPickaxe then return end
    local owned = Inventory.Pickaxes.Owned
    local point = stallPoint("ShopProx")
    if not point then return end

    local ladder = {}
    for _, entry in ipairs(ShopCatalog.Pickaxes or {}) do
        if not entry.adminOnly and (entry.price or 0) > 0
           and not owned:FindFirstChild(entry.id) then
            ladder[#ladder + 1] = entry
        end
    end
    if #ladder == 0 then return end
    table.sort(ladder, function(a, b) return a.price < b.price end)

    -- Anything affordable is worth owning: a rung we skip is a whole tier of
    -- the field left in the ground.
    local affordable = false
    for _, entry in ipairs(ladder) do
        if entry.price <= cash() then affordable = true break end
    end
    if not affordable then return end

    local pin = travelTo(point + Vector3.new(0, CONFIG.pinHeight, 0))
    if not pin then return end
    for _, entry in ipairs(ladder) do
        if entry.price <= cash() then
            local before = cash()
            Remotes.ShopBuy:FireServer(entry.id)
            task.wait(0.6)
            if cash() < before then
                STATE.pickaxe = entry.id
                note("pickaxe %s (rank %s)", entry.name or entry.id,
                    tostring((ShopCatalog.PickaxeRarityRank or {})[entry.id]))
            end
        end
    end
    pin:Disconnect()
end

local function freeRewards()
    if not CONFIG.autoRewards then return end
    pcall(function() Remotes.ClaimTutorialReward:FireServer() end)
    pcall(function() Remotes.ClaimGroupReward:FireServer() end)
end

----------------------------------------------------------------------------
-- loops
----------------------------------------------------------------------------

local function loop(name, gap, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then note("%s: %s", name, tostring(err)) end
            task.wait(gap)
        end
    end)
end

loop("stats", 0.5, function()
    STATE.cash = cash()
    STATE.capacity = capacity()
    STATE.carried = select(1, carriedWeight())
    STATE.height = stat("Height", 0)
    STATE.weightLevels = stat("WeightUpgrades", 0)
end)

-- A death anywhere - a fall, the freeze line, lava - stops the whole script
-- dead until it is undone, so this watches independently of the farm loop.
loop("revive", 2, function()
    if health() <= 0 then reviveIfDead() end
end)

loop("rewards", 300, freeRewards)

-- Nothing spends on a timer any more.  Buying is part of the round trip: the
-- balance is only ever at its peak in the seconds after a sale, and a timed
-- spender also warped the body out of a half-finished hold - two crystals were
-- blacklisted that way before this became one sequence.
local function sellTrip()
    local sold = sellBag()
    if not sold then return false end
    STATE.trips = STATE.trips + 1
    STATE.phase = "upgrading"
    -- Pickaxe first.  Rank decides WHAT is worth carrying; the Weight upgrade
    -- only decides how much of it fits, and a bag full of Small crystals is
    -- worth a fraction of one Large one the rank unlocks.
    buyPickaxe()
    buyUpgrades()
    return true
end

-- The farm itself.  Fill the bag with the densest crystals that fit, then take
-- one trip down.  A mountain reset wipes the field, so the survey is redone
-- every pass rather than cached.
task.spawn(function()
    while alive() do
        if not CONFIG.autoFarm then
            STATE.phase = "idle"
            task.wait(1)
        elseif health() <= 0 then
            STATE.phase = "dead"
            if not reviveIfDead() then task.wait(2) end
        else
            local cap = capacity()
            local weight = select(1, carriedWeight())
            local free = cap - weight

            if cap > 0 and weight >= cap * CONFIG.fillRatio then
                if CONFIG.autoSell then
                    if not withBody("selling", sellTrip) then task.wait(0.5) end
                else
                    task.wait(1)
                end
            else
                local candidates = survey(free)
                if #candidates == 0 then
                    -- Nothing fits or nothing is left: sell what is in the bag
                    -- and let the next pass work against the bigger free space.
                    if select(2, carriedWeight()) > 0 and CONFIG.autoSell then
                        if not withBody("selling", sellTrip) then task.wait(0.5) end
                    else
                        note("no reachable crystal fits %.1fkg of free space", free)
                        task.wait(CONFIG.scanEvery)
                    end
                else
                    local entry = candidates[1]

                    -- What would be reachable with an empty bag?  The single
                    -- best crystal on the mountain is routinely heavier than
                    -- the free space (a 74kg Heartmyth worth $263M against
                    -- 48kg free), and topping the bag up with small ones locks
                    -- it out for the whole trip.  When the prize is worth
                    -- several bags of scrap, go and empty the bag first.
                    local whole = survey(capacity())
                    local prize = whole[1]
                    if prize and weight > 0 and CONFIG.autoSell
                       and prize.value > entry.value * CONFIG.prizeFactor then
                        note("holding out for %s ($%s, %.1fkg) - selling first",
                            prize.name, abbreviate(prize.value), prize.kg)
                        if not withBody("selling", sellTrip) then task.wait(0.5) end
                    else
                        STATE.target = string.format("%s T%d $%s %.1fkg",
                            entry.name, entry.tier, abbreviate(entry.value), entry.kg)
                        if not withBody("hunting", function() collect(entry) end) then
                            task.wait(0.5)
                        end
                    end
                end
            end
        end
    end
end)

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__MINEMTN_WIN then pcall(function() _G.__MINEMTN_WIN:Destroy() end) end
for _, gui in ipairs(game:GetService("CoreGui"):GetChildren()) do
    if gui.Name == "MINEMOUNTAIN" then pcall(function() gui:Destroy() end) end
end

local win = UI.Window({
    title = "MINE A", accentTitle = "MOUNTAIN", subtitle = "seltonmt",
    badge = "\226\155\176", width = 920, height = 580,
})
_G.__MINEMTN_WIN = win

local page = win:Page("FARMING", UI.icon and UI.icon.pickaxe or nil)

local engine = page:Card("ENGINE", 1)
engine:Toggle("Auto farm", CONFIG.autoFarm, function(v) CONFIG.autoFarm = v end,
    "picks the best crystal that fits and waits out its hold")
engine:Toggle("Auto sell", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
    "walks down to the Crystal Buyer; selling is position gated")
engine:Slider("Fill before selling (%)", 50, 100, math.floor(CONFIG.fillRatio * 100),
    function(v) CONFIG.fillRatio = v / 100 end)
engine:Slider("Settle time (s x10)", 5, 30, math.floor(CONFIG.settle * 10),
    function(v) CONFIG.settle = v / 10 end)
engine:Slider("Minimum value", 0, 100000, CONFIG.minValue,
    function(v) CONFIG.minValue = v end)
engine:Slider("Freeze headroom (studs)", 0, 120, CONFIG.freezeMargin,
    function(v) CONFIG.freezeMargin = v end)
engine:Toggle("Climb past the freeze line", CONFIG.ignoreFreeze,
    function(v) CONFIG.ignoreFreeze = v end,
    "the richest crystals are up there and the body dies mid-hold",
    UI.theme and UI.theme.bad)

local spend = page:Card("SPENDING", 2)
spend:Toggle("Carry weight", CONFIG.autoWeight, function(v) CONFIG.autoWeight = v end,
    "the only thing that raises the bag; backpacks do nothing")
spend:Toggle("Air capacity", CONFIG.autoAir, function(v) CONFIG.autoAir = v end,
    "priced in single dollars; keeps you alive in the caves")
spend:Toggle("Revive at base", CONFIG.autoRevive, function(v) CONFIG.autoRevive = v end,
    "the game never respawns by itself and a corpse can do nothing")
spend:Toggle("Buy pickaxes", CONFIG.autoPickaxe, function(v) CONFIG.autoPickaxe = v end,
    "rank must beat a crystal's tier to break Medium and Large ones")
spend:Toggle("Free rewards", CONFIG.autoRewards, function(v) CONFIG.autoRewards = v end,
    "the group reward and the tutorial reward")
spend:Slider("Weight budget (%)", 10, 90, math.floor(CONFIG.weightReserve * 100),
    function(v) CONFIG.weightReserve = v / 100 end)

local readout = page:Card("STATUS", 0)
local out = readout:Readout(10)

task.spawn(function()
    while alive() do
        local weight, count = carriedWeight()
        out:set({
            "RUN",
            string.format("  phase %s   target %s", STATE.phase, tostring(STATE.target)),
            string.format("  taken %d   refused %d   sold %d", STATE.taken, STATE.missed, STATE.sold),
            string.format("  bag %.1f / %d kg  (%d crystals)", weight, STATE.capacity, count),
            "ECONOMY",
            string.format("  cash $%s   earned $%s   last sale $%s",
                abbreviate(STATE.cash), abbreviate(STATE.earned), abbreviate(STATE.lastSale)),
            string.format("  weight lvl %d   trips %d   upgrades %d   revives %d",
                STATE.weightLevels, STATE.trips, STATE.upgrades, STATE.revives),
            string.format("  next  weight $%s / $%s / $%s   air $%s",
                abbreviate((STATE.prices.Weight or {}).one or 0),
                abbreviate((STATE.prices.Weight or {}).five or 0),
                abbreviate((STATE.prices.Weight or {}).ten or 0),
                abbreviate((STATE.prices.Air or {}).one or 0)),
            string.format("  field %d   too high %d   needs a better pickaxe %d",
                STATE.field, STATE.tooHigh, STATE.tooHard),
            string.format("  pickaxe %s (rank %d)   ceiling y=%.0f",
                tostring(STATE.pickaxe), STATE.rank, STATE.ceiling),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        pcall(function()
            win:SetStat(1, abbreviate(STATE.cash), "cash")
            win:SetStat(2, string.format("%.0f/%d", weight, STATE.capacity), "kg")
            win:SetStat(3, tostring(STATE.taken), "taken")
            win:SetStatus(string.format("$%s   %.1f/%d kg   %s",
                abbreviate(STATE.cash), weight, STATE.capacity, STATE.phase))
        end)
        task.wait(0.5)
    end
end)

pcall(function()
    win:SetMaster(CONFIG.autoFarm, "Auto farm running")
    win:OnMaster(function(on) CONFIG.autoFarm = on end)
end)

_G.__MINEMTN_DBG = {
    CONFIG = CONFIG, STATE = STATE, refused = refused, strikes = strikes,
    survey = survey, collect = collect, sellBag = sellBag,
    buyUpgrades = buyUpgrades, buyPickaxe = buyPickaxe,
    freeRewards = freeRewards, bestBundle = bestBundle,
    reviveIfDead = reviveIfDead, freezeCeiling = freezeCeiling, health = health,
    sellTrip = sellTrip, priceBoard = priceBoard, UPGRADES = UPGRADES,
    pickaxeRank = pickaxeRank, canTake = canTake,
    pinTo = pinTo, travelTo = travelTo, carriedWeight = carriedWeight,
    Remotes = Remotes, ZoneCheck = ZoneCheck, ShopCatalog = ShopCatalog,
}

pcall(function() win:Home() end)

print("[minemountain] running - RightShift toggles the panel")
