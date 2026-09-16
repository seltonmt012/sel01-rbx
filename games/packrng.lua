--[[
    packrng.lua - "[🍀X4] Roll A Pack!"  (place 117752943664280, Treat Games)

    Known on rscripts.net as "[🚜FARM] Pack RNG" - the game was renamed, the
    place id did not change.

    Everything below was READ out of the game's own client (Potassium's
    decompiler works on every LocalScript here) and then verified against
    server-side values on 2026-09-16, account Lumo_Studios, bridge 1.

    The loop: roll a pack, the pack drops a cube, the best cubes get equipped,
    and the equipped cubes pay Coins per second.  Coins buy luck, more cubes
    per roll, more equip slots, ranks, better packs and the areas that open the
    game's side economies.

    What decides the design:

    * **THE ROLL RATE IS A HARD SERVER CAP AND IT CANNOT BE BEATEN.**
      `Modules.RollTiming` is shipped to the client and the server enforces it:
          Cooldown = (ReelTime 0.84 + RevealTime 0.55 + CloseTime 0.2)
                     * Speed(fastRollsGamepass ? 0.625 : 1.25) * Tolerance 0.99
      = **1.9676 s** normally, 0.9838 s with the FastRolls gamepass.  Measured:
      60 calls fired in three bursts (0.1 s gaps, 0.02 s gaps, one per frame)
      credited **3 rolls total**, while 8 calls spaced at `Cooldown + 0.05`
      credited **8 of 8**.  So flooding is pure waste and this script paces
      itself to the cooldown exactly.
    * **What it CAN beat is the game's own auto-roll.**  `PackRollHandler`'s
      auto loop is CLIENT side and waits for the reel animation to finish
      before the next roll - `ReelTime + (dramatic ? 0.9 : 0.55) + CloseTime`,
      which on a rare drop is **2.43 s against the 1.97 s cooldown**, ~19%
      slower.  This script never plays an animation, so it holds the cap
      whatever drops.  The game's own toggle is therefore switched OFF when
      ours runs, or the two simply share the same cap and both get refused.
      (That toggle also wants group 14444762; ours does not.)
    * **The oracle is a replicated Value tree under the Player** - no
      RemoteFunction is needed anywhere (the place has exactly two, and neither
      is a state getter).  `Data` (69 values), `Upgrades`, `Inventory`,
      `Equipped`, `Packs`, `Areas`, `Index`, `TechTree`, `leaderstats` and
      `UnsavedData`.  **`UnsavedData.Income` and `UnsavedData.Luck` are the
      game's own live figures** - never rebuild them from a rolling average,
      the CLAUDE.md rule about `DroneEarningsPerMinute` applies verbatim.
    * **Income = SUM(cube value x Count) over the EQUIPPED entries**, verified
      to the unit: Yellow 125 x3 + Orange 25 + Pink 840 = 1240, which is
      exactly what `UnsavedData.Income` read.  `Data.MaxEquip` counts the total
      Count, not the number of entries - 3 Yellow + 1 Orange + 1 Pink is 5 of 5.
    * Cube value is `Modules.Variants.Coins`:
      `Cubes[name].Coins * SizeMultipliers[size] * ShinyMultipliers[shiny]`
      with both multiplier tables `{5, 25}`, so a Shiny is x5 and a Mystic x25.
      A cube carrying a `Percentage` field is worth that percentage of
      `PetAverage.Get()` instead - those have to go through `Variants.Coins`
      or they price as zero.
    * **`SetAutoEquipBest:FireServer(true)` is free and server side**, and it
      makes ranking cubes by hand pointless.  Verified: income 1240 -> 2180 the
      moment it was switched on.  There is no gamepass on it.
    * **`SetAutoBuy:FireServer(<pack>)` makes the SERVER keep the pack stack
      topped up**, buying exactly the `1 + PackUpgrade` packs a roll consumes.
      Measured: rolling with AutoBuy on left `Packs.Pack1` at 1 forever while
      coins fell by exactly the 25 the pack cost.  So this script never has to
      run a buy loop of its own.
    * **REBIRTH IS FREE TO SPEND AGAINST, and that is the single most useful
      thing in this file.**  The payout is computed from `CoinsSinceRebirth`,
      which is coins *EARNED* since the last rebirth - not the balance.
      Measured: balance 425,747 with `CoinsSinceRebirth` 898,997 after roughly
      470K had been spent on a rank and an upgrade.  So spending never costs a
      single rebirth and there is no reserve-versus-prestige conflict to
      design around.  Spend continuously.
      The formula, straight out of `RebirthHandler`:
          reward = (digits(c) - 5) * 10 + round(c / 10^floor(log10(c)))   (0 below 10,000)
          granted = floor(reward * sessionMulti * techMulti), min 1 if reward >= 1
      `sessionMulti` is the product of `Cubes[x].RebirthMulti` over the cube
      types discovered THIS RUN (`Index.SessionCubes`, wiped by the rebirth),
      `techMulti` is the tech tree's `RebirthsMultiplier`.
      Measured end to end: `CoinsSinceRebirth` 898,997 and 6 session cubes
      granted **21 rebirths**, income 2398 -> 2902 (x1.21, i.e. +1% each), and
      it kept the inventory, the equipped cubes, the pack stacks, the rank, the
      upgrades and the permanent cube index.  Only the coin BALANCE is wiped,
      and the cooldown is 30 s.
      Because the payout is logarithmic in earned coins (every x10 is worth
      only +10), banking is nearly pointless - the script rebirths on a
      threshold and otherwise keeps spending.
    * **`BuyUpgradeMax:FireServer(name)` buys every level the balance covers in
      one call** and is the only upgrade path used here.  Verified: Luck 2 -> 5
      for 262,500.  `BuyUpgradeRobux` is the paid twin and is never fired.
    * Verified write remotes, all with a server value moving:
      `Roll(id)`, `SelectPack(name)`, `SetAutoBuy(name)`, `SetAutoEquipBest(bool)`,
      `BuyPack(name, "Buy1"|"Buy5"|"Buy25"|"Buy200"|"Buy1K"|"Buy10K"|"BuyMax")`,
      `BuyUpgrade(name)`, `BuyUpgradeMax(name)`, `RankUp()`, `Rebirth()`,
      `BuyArea(name)`, `OfflineClaim()`, `ToggleEquip(key, bool)`.
    * **No anti-cheat.**  `strings` over ~10,300 loaded functions found no
      `AntiCheat`, no `Suspicious`, no honeypot vocabulary and no detection
      remotes - the only rate-limit strings in the place are the clan invite
      ones.  That is the client side only, but it is the opposite of Cut Grass.
    * `Data.CompletedTutorial` gates the pack BUY AMOUNT at 10 per call while
      it is false.  It does not gate rolling, and AutoBuy only ever needs a
      handful, so it costs nothing here - the panel just says so.

    Never touched: `BuyUpgradeRobux`, `OfflineTriple` (3606741442), the paid
    rebirth (3606498856), the paid rank-up, every pack's `DevProduct`, and the
    five gamepasses (`Lucky`, `ShinyLuck`, `RelicLuck2`, `FastRolls`,
    `FishLuck2`).  The gamepasses are only read, to pace the roll loop
    correctly when FastRolls happens to be owned.

    NOT IN THIS BUILD, deliberately: the side economies behind the areas -
    ores/gems, the farm (seeds, plants, fruit), fishing, the volcano, lucky
    blocks, relic dice, gemstones, the gem fuzer, clans, trading and the
    marketplace.  Each has its own currency and its own upgrade ladder, none of
    them is measured yet, and shipping an unverified loop is how this project
    got into trouble before.  The areas themselves ARE bought, so the account
    is ready for them.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------------------
-- modules and remotes
--
-- Every module here is a plain ModuleScript and `require` works at the
-- executor's identity - measured, no `setthreadidentity` needed.  They are
-- still loaded behind a wall-clock cap, because a module-level yield in a
-- shipped script parks the bridge's poll loop and that has cost an afternoon
-- before (see traps.md, Mrbeast Island Escape).
----------------------------------------------------------------------------

local function requireCapped(inst, seconds)
    if not inst then return nil end
    local done, ok, res = false, false, nil
    task.spawn(function()
        ok, res = pcall(require, inst)
        done = true
    end)
    local waited = 0
    while not done and waited < (seconds or 8) do
        task.wait(0.05)
        waited = waited + 0.05
    end
    if not done or not ok then return nil end
    return res
end

local Modules = ReplicatedStorage:WaitForChild("Modules", 15)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
if not Modules or not Remotes then
    error("[packrng] this is not Roll A Pack - Modules/Remotes missing", 0)
end

local PackConfig     = requireCapped(Modules:WaitForChild("PackConfig", 10))
local Cubes          = requireCapped(Modules:WaitForChild("Cubes", 10))
local Variants       = requireCapped(Modules:WaitForChild("Variants", 10))
local PetAverage     = requireCapped(Modules:WaitForChild("PetAverage", 10))
local UpgradesCfg    = requireCapped(Modules:WaitForChild("Upgrades", 10))
local RanksCfg       = requireCapped(Modules:WaitForChild("Ranks", 10))
local TechTreeCfg    = requireCapped(Modules:WaitForChild("TechTree", 10))
local RollTiming     = requireCapped(Modules:WaitForChild("RollTiming", 10))
local WorldsCfg      = requireCapped(Modules:WaitForChild("Worlds", 10))
local CurrencyConfig = requireCapped(Modules:WaitForChild("CurrencyConfig", 10))

if not (PackConfig and Cubes and Variants and UpgradesCfg and RollTiming) then
    error("[packrng] required config modules did not load", 0)
end

local function remote(name)
    return Remotes:FindFirstChild(name)
end

----------------------------------------------------------------------------
-- config
----------------------------------------------------------------------------

local CONFIG = {
    auto = true,

    autoRoll       = true,
    autoPack       = true,   -- keep the best sustainable pack selected + auto-bought
    autoEquipBest  = true,   -- the server's own "equip best", switched on once
    autoUpgrades   = true,
    autoRank       = true,
    autoAreas      = true,
    autoRebirth    = false,  -- wipes the coin BALANCE, so it is opt-in
    autoCircle     = true,   -- stand in a Lucky Circle while one is up
    autoLuckOther  = true,   -- spend Gems / Cash / LuckyCoins / Tokens on luck
    claimOffline   = true,
    antiAfk        = true,

    -- The share of income per second the pack stream is allowed to cost.  A
    -- pack is bought per roll, so cost/s is price * packsPerRoll / cooldown.
    packSpend      = 0.35,
    -- How far ahead a purchase may be reserved for, in seconds of income.
    reserveWindow  = 120,
    -- Anything repaying inside this many seconds of income bypasses the guard.
    trivialSeconds = 5,
    -- Rebirth once the granted count reaches this.
    rebirthMin     = 20,

    manualPack     = "",     -- non-empty pins the pack and disables autoPack
}

-- `ItemUpgrade` is deliberately absent: it only widens the item shop, which
-- this build does not use, and at 100K it slips past the trivial-cost bypass
-- and quietly buys itself. Add it back when the item shop is farmed.
local UPGRADE_ORDER = {
    "EquipUpgrade",   -- +1 equipped cube; income is a straight sum, so a slot is a slot
    "PackUpgrade",    -- +1 pack per roll; the rate is capped, this is the only throughput lever
    "LuckUpgrade",    -- +luck% on every roll
    "ShinyUpgrade",   -- +shiny chance; a Shiny is x5 and a Mystic x25
    "HugeUpgrade",    -- +size chance; same multipliers
    "EquipUpgrade2",
}

-- The luck and shiny ladders priced in the OTHER currencies.  They feed the
-- pack loop exactly like the Coins ones, and nothing else in this build spends
-- these currencies, so there is no ranking to do and no reserve to respect -
-- they are simply bought whenever the balance covers the next level.  Reserves
-- are never shared across currencies; that is the "never sum reserves" rule
-- from CLAUDE.md applied one level up.
local OTHER_LUCK_ORDER = {
    "LuckUpgrade2",      -- Gems       "Luck II"
    "LuckUpgrade3",      -- Cash       "Luck III"
    "LuckUpgrade4",      -- LuckyCoins "Luck IV"
    "TokenLuckUpgrade",  -- Tokens     "Luck!"
    "TokenShinyUpgrade", -- Tokens     shiny chance
}

local STATE = {
    note = "starting", phase = "idle",
    coins = 0, income = 0, luck = 0, rolls = 0, bestRoll = "-",
    rank = 0, rebirths = 0, pack = "-", packStock = 0, packsPerRoll = 1,
    equipped = 0, maxEquip = 0, cubeKinds = 0, cubesOwned = 0,
    rollsDone = 0, rollsRefused = 0, cubesGained = 0, lastCube = "-",
    upgradesBought = 0, ranksBought = 0, rebirthsDone = 0, areasBought = 0,
    rebirthReward = 0, sessionCubes = 0, cooldown = 0,
    reserveName = "-", reserveCost = 0, spent = 0,
    fastRolls = false, tutorial = false, rollGap = 2,
    circle = "-", circleMult = 1, circlesUsed = 0, otherBought = 0,
}

_G.__PACKRNG = (_G.__PACKRNG or 0) + 1
local GEN = _G.__PACKRNG
local function alive() return _G.__PACKRNG == GEN end

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
end

----------------------------------------------------------------------------
-- number formatting
--
-- The game ships `Modules.Abbreviator` / `Short`, but the panel only needs a
-- display string and the template already owns its own layout, so this is a
-- local one.  Prices in this game are plain numbers, never abbreviated
-- strings, so nothing has to be parsed back - the Drill Farm `Q` trap does not
-- apply here.
----------------------------------------------------------------------------

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc",
                 "UDc", "DDc", "TDc", "QaDc", "QiDc", "SxDc", "SpDc", "OcDc", "NoDc", "Vg" }

local function abbreviate(n)
    n = tonumber(n) or 0
    if n ~= n or n == math.huge then return "inf" end
    local sign = n < 0 and "-" or ""
    n = math.abs(n)
    if n < 1000 then
        return sign .. tostring(math.floor(n + 0.5))
    end
    local tier = math.floor(math.log(n, 10) / 3)
    tier = math.clamp(tier, 1, #SUFFIX - 1)
    local scaled = n / (10 ^ (tier * 3))
    return string.format("%s%.2f%s", sign, scaled, SUFFIX[tier + 1])
end

----------------------------------------------------------------------------
-- oracle
--
-- Everything is a replicated ValueBase under the Player.  Nothing is cached
-- across calls: the folders themselves persist, but a child can be added the
-- first time a currency is touched, so each read resolves again.
----------------------------------------------------------------------------

local function folder(name, timeout)
    return LocalPlayer:WaitForChild(name, timeout or 10)
end

local Data        = folder("Data")
local UpgradesVal = folder("Upgrades")
local Inventory   = folder("Inventory")
local Equipped    = folder("Equipped")
local PacksVal    = folder("Packs")
local AreasVal    = folder("Areas")
local IndexVal    = folder("Index")
local TechTreeVal = folder("TechTree")
local Unsaved     = folder("UnsavedData")
local Leaderstats = folder("leaderstats")

if not (Data and UpgradesVal and Inventory and Equipped and PacksVal and Unsaved) then
    error("[packrng] the player's data tree never replicated", 0)
end

local SessionCubes = IndexVal and IndexVal:WaitForChild("SessionCubes", 10)

local function dataValue(name, fallback)
    local v = Data:FindFirstChild(name)
    if v then return v.Value end
    return fallback
end

local function unsaved(name, fallback)
    local v = Unsaved:FindFirstChild(name)
    if v then return v.Value end
    return fallback
end

local function coins()
    local v = Leaderstats and Leaderstats:FindFirstChild("Coins")
    return v and v.Value or 0
end

local function income()
    return unsaved("Income", 0) or 0
end

-- Every currency in the game, resolved the way the game's own
-- `CurrencyConfig` resolves it: Coins live in leaderstats, everything else in
-- Data.  A currency the account has never earned simply reads 0.
local function currency(name)
    if not name or name == "Coins" then return coins() end
    if CurrencyConfig and CurrencyConfig.GetAmount then
        local ok, amount = pcall(CurrencyConfig.GetAmount, LocalPlayer, name)
        if ok then return amount or 0 end
    end
    return dataValue(name, 0) or 0
end

local function upgradeLevel(name)
    local v = UpgradesVal:FindFirstChild(name)
    return v and v.Value or 0
end

local function packStock(name)
    local v = PacksVal:FindFirstChild(name)
    return v and v.Value or 0
end

local function areaUnlocked(name)
    local v = AreasVal and AreasVal:FindFirstChild(name)
    if not v then return true end   -- an area with no entry is not gated
    return v.Value == true
end

-- `1 + PackUpgrade.Reward` packs open per roll, +3 with the pack-open
-- gamepass.  Copied from `PackRollHandler.GetOpenAmount`.
local function packsPerRoll()
    local entry = UpgradesCfg.PackUpgrade and UpgradesCfg.PackUpgrade.Data
        and UpgradesCfg.PackUpgrade.Data[upgradeLevel("PackUpgrade")]
    local amount = 1 + ((entry and entry.Reward) or 0)
    if LocalPlayer:GetAttribute("GamepassPackOpen") then amount = amount + 3 end
    return amount
end

local function fastRolls()
    return LocalPlayer:GetAttribute("GamepassFastRolls") == true
end

-- `Data.MaxEquip` is only the BASE; the real cap is that plus the EquipUpgrade
-- reward plus 3 for the gamepass, exactly as `CubesHandler.UpdateEquippedLabel`
-- computes it. Reading the Data value alone reports 6 equipped out of 5.
local function equipCap()
    local base = dataValue("MaxEquip", 0) or 0
    local cfg = UpgradesCfg.EquipUpgrade and UpgradesCfg.EquipUpgrade.Data
    local entry = cfg and cfg[upgradeLevel("EquipUpgrade")]
    local cap = base + ((entry and entry.Reward) or 0)
    if LocalPlayer:GetAttribute("GamepassEquips") then cap = cap + 3 end
    return cap
end

local function rollGap()
    local ok, gap = pcall(RollTiming.Cooldown, fastRolls())
    if not ok or type(gap) ~= "number" then gap = 1.97 end
    -- The server compares against its own clock, so a call that arrives a
    -- hair early is simply dropped.  50 ms of margin credited 8 of 8.
    return gap + 0.05
end

local function cubeValue(cube, size, shiny)
    local avg = 0
    if PetAverage and PetAverage.Get then
        local ok, value = pcall(PetAverage.Get)
        if ok then avg = value or 0 end
    end
    local ok, value = pcall(Variants.Coins, cube, size or 0, shiny or 0, avg)
    return ok and (value or 0) or 0
end

----------------------------------------------------------------------------
-- census
----------------------------------------------------------------------------

local function census()
    STATE.coins        = coins()
    STATE.income       = income()
    STATE.luck         = unsaved("Luck", 0) or 0
    STATE.rank         = dataValue("Ranks", 0) or 0
    STATE.rebirths     = dataValue("Rebirths", 0) or 0
    STATE.pack         = dataValue("CurrentPack", "") or ""
    STATE.maxEquip     = equipCap()
    STATE.cooldown     = dataValue("RebirthCooldown", 0) or 0
    STATE.tutorial     = dataValue("CompletedTutorial", false) == true
    STATE.packsPerRoll = packsPerRoll()
    STATE.fastRolls    = fastRolls()
    STATE.rollGap      = rollGap()
    STATE.packStock    = STATE.pack ~= "" and packStock(STATE.pack) or 0
    STATE.sessionCubes = SessionCubes and #SessionCubes:GetChildren() or 0

    local rollsStat = Leaderstats and Leaderstats:FindFirstChild("Rolls")
    STATE.rolls = rollsStat and rollsStat.Value or 0
    local bestStat = Leaderstats and Leaderstats:FindFirstChild("Best Roll")
    STATE.bestRoll = bestStat and tostring(bestStat.Value) or "-"

    local owned, kinds = 0, 0
    for _, entry in ipairs(Inventory:GetChildren()) do
        local count = entry:FindFirstChild("Count")
        owned = owned + (count and count.Value or 0)
        kinds = kinds + 1
    end
    STATE.cubesOwned = owned
    STATE.cubeKinds  = kinds

    local equippedCount = 0
    for _, entry in ipairs(Equipped:GetChildren()) do
        local count = entry:FindFirstChild("Count")
        equippedCount = equippedCount + (count and count.Value or 0)
    end
    STATE.equipped = equippedCount
end

----------------------------------------------------------------------------
-- the rebirth payout, exactly as the game computes it
----------------------------------------------------------------------------

local function rebirthBase(earned)
    earned = earned or 0
    if earned < 10000 then return 0 end
    local digits = math.floor(math.log10(math.abs(earned))) + 1
    local power  = 10 ^ math.floor(math.log10(earned))
    return (digits - 5) * 10 + math.round(earned / power)
end

-- The product of `RebirthMulti` over the cube TYPES discovered this run.  The
-- folder is wiped by the rebirth, which is why rebirthing twice in a row pays
-- far less the second time.
local function sessionMulti()
    if not SessionCubes then return 1 end
    local multi = 1
    for _, child in ipairs(SessionCubes:GetChildren()) do
        local cube = Cubes[child.Name]
        if cube and cube.RebirthMulti then multi = multi * cube.RebirthMulti end
    end
    return multi
end

local function techMulti()
    if not (TechTreeCfg and TechTreeCfg.GetBestEffect and TechTreeVal) then return 1 end
    local owned = {}
    for _, child in ipairs(TechTreeVal:GetChildren()) do owned[child.Name] = true end
    local ok, multi = pcall(TechTreeCfg.GetBestEffect, owned, "RebirthsMultiplier", 1)
    return (ok and multi) or 1
end

local function rebirthReward()
    local base = rebirthBase(dataValue("CoinsSinceRebirth", 0) or 0)
    if base <= 0 then return 0 end
    local granted = math.floor(base * (math.floor(sessionMulti() * techMulti() * 10000 + 0.5) / 10000))
    if base >= 1 and granted < 1 then granted = 1 end
    return granted
end

----------------------------------------------------------------------------
-- what is still worth buying, and the one shared spending guard
--
-- The starvation pattern from CLAUDE.md, applied: the reserve is for the
-- BEST-VALUE pending target rather than the cheapest, it engages on
-- reachability from income rather than on a share of the balance, reserves are
-- never summed, every spender asks the same function, and anything that repays
-- inside `trivialSeconds` walks straight past it.
----------------------------------------------------------------------------

local function upgradeNext(name)
    local cfg = UpgradesCfg[name]
    if not cfg or not cfg.Data then return nil end
    local level = upgradeLevel(name)
    local entry = cfg.Data[level + 1]
    if not entry then return nil end
    return { cost = entry.Cost, reward = entry.Reward, currency = cfg.Currency or "Coins" }
end

local function rankNext()
    if not RanksCfg then return nil end
    local next_ = RanksCfg[(dataValue("Ranks", 0) or 0) + 1]
    if not next_ then return nil end
    local price = next_.Price
    local cur = (type(next_.Currency) == "string" and next_.Currency ~= "") and next_.Currency or "Coins"
    -- The tech tree can discount ranks priced in Coins; the game applies it
    -- server side too, so reading it here only keeps the panel honest.
    if cur == "Coins" and TechTreeCfg and TechTreeCfg.GetBestEffect and TechTreeVal then
        local owned = {}
        for _, child in ipairs(TechTreeVal:GetChildren()) do owned[child.Name] = true end
        local ok, discount = pcall(TechTreeCfg.GetBestEffect, owned, "RanksDiscount", 0)
        if ok and discount and discount > 0 then
            price = math.floor(price * (1 - discount / 100))
        end
    end
    return { cost = price, currency = cur, luck = next_.Luck, coins = next_.Coins }
end

-- The cheapest unbought area IN ONE CURRENCY.  Ranking across currencies is
-- meaningless and it silently broke the whole area pass: `Farm #2` at 100,000
-- FarmCoins is numerically the cheapest of the eleven, so it came back as "the
-- next area" forever, the caller then dropped it for not being priced in Coins,
-- and a 1,000,000 Desert never got bought against a 76M balance.
local function nextArea(wantCurrency)
    if not WorldsCfg then return nil end
    wantCurrency = wantCurrency or "Coins"
    local best
    for name, entry in pairs(WorldsCfg) do
        if type(entry) == "table" and entry.Price and not areaUnlocked(name) then
            local cur = entry.Currency or "Coins"
            if cur == wantCurrency and (not best or entry.Price < best.cost) then
                best = { name = name, cost = entry.Price, currency = cur }
            end
        end
    end
    return best
end

-- Every pending Coins purchase, in priority order.  Only Coins entries take
-- part in the reserve: the other currencies come from side economies this
-- build does not farm, so holding coins back for them would freeze everything.
local function pendingCoinTargets()
    local list = {}
    for index, name in ipairs(UPGRADE_ORDER) do
        local next_ = upgradeNext(name)
        if next_ and next_.currency == "Coins" then
            list[#list + 1] = { kind = "upgrade", name = name, cost = next_.cost, rank = index }
        end
    end
    if CONFIG.autoRank then
        local rank = rankNext()
        if rank and rank.currency == "Coins" then
            list[#list + 1] = { kind = "rank", name = "RankUp", cost = rank.cost, rank = #UPGRADE_ORDER + 1 }
        end
    end
    if CONFIG.autoAreas then
        local area = nextArea("Coins")
        if area then
            list[#list + 1] = { kind = "area", name = area.name, cost = area.cost, rank = #UPGRADE_ORDER + 2 }
        end
    end
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.cost < b.cost
    end)
    return list
end

-- The single target the balance is being held for: the highest-priority entry
-- that cannot be paid for yet but IS reachable from income inside the window.
-- Anything already affordable needs no reserve, and anything out of reach must
-- not be allowed to freeze the cheaper rungs below it.
local function reserveTarget()
    local have, rate = coins(), income()
    local reach = have + rate * CONFIG.reserveWindow
    for _, entry in ipairs(pendingCoinTargets()) do
        if entry.cost > have and entry.cost <= reach then
            return entry
        end
    end
    return nil
end

local spendLock = false

local function spendable(cost, selfName)
    local have = coins()
    if cost > have then return false end
    -- Trivially cheap steps repay in seconds and blocking them to save for a
    -- distant target is backwards.
    local rate = income()
    if rate > 0 and cost <= rate * CONFIG.trivialSeconds then return true end
    local target = reserveTarget()
    if not target then return true end
    if selfName and target.name == selfName then return true end
    return cost <= have - target.cost
end

----------------------------------------------------------------------------
-- rolling
--
-- One persistent listener, stored in `_G` and DISCONNECTED before it is
-- replaced.  A boolean "already hooked" guard survives a re-execute and leaves
-- the new run writing into the old script's table - the Drill Farm trap.
----------------------------------------------------------------------------

local RollRemote = remote("Roll")
local pendingRolls = {}
local nextRollId = math.random(100000, 900000)

if _G.__PACKRNG_ROLLCONN then
    pcall(function() _G.__PACKRNG_ROLLCONN:Disconnect() end)
    _G.__PACKRNG_ROLLCONN = nil
end

if RollRemote then
    _G.__PACKRNG_ROLLCONN = RollRemote.OnClientEvent:Connect(function(results, id)
        local slot = pendingRolls[id]
        if not slot then return end          -- the game's own UI roll, not ours
        pendingRolls[id] = nil
        slot.results  = results
        slot.answered = true
    end)
end

-- Seeded to "now" rather than 0 on purpose: a re-execute resets this local
-- while the SERVER's cooldown from the previous generation's last roll is
-- still running, so an unseeded first roll is always refused. Starting a full
-- gap behind costs two seconds once and keeps the refusal counter honest.
local lastRollAt = os.clock()

local function rollOnce()
    if not RollRemote then return false, "no Roll remote" end
    if (dataValue("CurrentPack", "") or "") == "" then return false, "no pack selected" end

    -- Pace to the server's own cooldown.  Firing early is not merely wasted,
    -- it is the whole difference between 3 credited rolls and 8.
    local wait = STATE.rollGap - (os.clock() - lastRollAt)
    if wait > 0 then task.wait(wait) end

    nextRollId = nextRollId + 1
    local id = nextRollId
    local slot = { answered = false }
    pendingRolls[id] = slot

    lastRollAt = os.clock()
    RollRemote:FireServer(id)

    local deadline = os.clock() + 8
    while not slot.answered and os.clock() < deadline do task.wait() end
    pendingRolls[id] = nil

    if type(slot.results) ~= "table" or #slot.results == 0 then
        -- The server's cooldown runs from its last ACCEPTED roll, not from our
        -- last attempt, so a refusal means we were early and waiting another
        -- full gap would throw the difference away twice. Pull the clock back
        -- so the retry lands in a quarter second; the loop then re-syncs to the
        -- server's phase by itself instead of drifting against it.
        STATE.rollsRefused = STATE.rollsRefused + 1
        lastRollAt = os.clock() - STATE.rollGap + 0.25
        return false, "refused"
    end

    STATE.rollsDone   = STATE.rollsDone + 1
    STATE.cubesGained = STATE.cubesGained + #slot.results
    local last = slot.results[#slot.results]
    if last and last.Cube then
        local tags = {}
        if (last.Size or 0) > 0 then tags[#tags + 1] = Variants.SizeNames[last.Size] end
        if (last.Shiny or 0) > 0 then tags[#tags + 1] = Variants.ShinyNames[last.Shiny] end
        STATE.lastCube = #tags > 0
            and (table.concat(tags, " ") .. " " .. last.Cube)
            or last.Cube
    end
    return true
end

----------------------------------------------------------------------------
-- pack choice
--
-- Expected value of one cube out of a pack, using the game's own weights.  The
-- weights are a plain sum, not percentages - Pack1's add up to 97.45 and
-- Pack9's to 100.0 - so they are normalised here rather than assumed.
----------------------------------------------------------------------------

local packEVCache = {}

local function packEV(packName)
    local cached = packEVCache[packName]
    if cached then return cached end
    local pack = PackConfig.Packs[packName]
    if not pack or not pack.Cubes then return 0 end
    local total, weighted = 0, 0
    for cube, weight in pairs(pack.Cubes) do
        total = total + weight
        weighted = weighted + weight * cubeValue(cube, 0, 0)
    end
    local ev = total > 0 and (weighted / total) or 0
    packEVCache[packName] = ev
    return ev
end

-- What one pack costs per second of rolling: a roll eats `packsPerRoll` packs
-- every `rollGap` seconds.
local function packCostPerSecond(packName)
    local pack = PackConfig.Packs[packName]
    if not pack then return 0 end
    return pack.Price * math.max(1, STATE.packsPerRoll) / math.max(0.1, STATE.rollGap)
end

-- The best pack whose CONTINUOUS cost the income can carry.  A pack that
-- cannot be sustained drains the balance and starves every upgrade.
local function bestPack()
    if CONFIG.manualPack ~= "" and PackConfig.Packs[CONFIG.manualPack] then
        return CONFIG.manualPack
    end
    -- INCOME ONLY.  An earlier version also let a big BALANCE front a pack
    -- ("price * packsPerRoll * 5 <= coins"), and that is what made the picker
    -- oscillate: the balance crossed the line, it jumped to Pack5, rolling
    -- Pack5 at 20M x3 a roll drained the balance back under the line within
    -- seconds, and it fell to Pack4 again - watched live as
    -- Pack4 -> Pack5 -> Pack4 in one 14 s window.  A balance is a stock and the
    -- pack stream is a flow; only the flow may decide it.
    local rate = income()
    local sustainable = (rate * STATE.rollGap / math.max(1, STATE.packsPerRoll)) * CONFIG.packSpend
    local best, bestScore = nil, -1
    local cheapest, cheapestPrice = nil, math.huge
    for name, pack in pairs(PackConfig.Packs) do
        local removed = PackConfig.RemovedPacks and PackConfig.RemovedPacks[name]
        if not removed and (pack.Currency or "Coins") == "Coins" then
            if pack.Price < cheapestPrice then cheapest, cheapestPrice = name, pack.Price end
            if pack.Price <= sustainable then
                local score = packEV(name)
                if score > bestScore then best, bestScore = name, score end
            end
        end
    end
    -- A fresh account has no income yet, so nothing is sustainable and the
    -- loop would never start: fall back to the cheapest pack in the game.
    return best or cheapest or dataValue("CurrentPack", "Pack1")
end

----------------------------------------------------------------------------
-- actions
----------------------------------------------------------------------------

local function fire(name, ...)
    local r = remote(name)
    if not r then
        note("remote %s missing", name)
        return false
    end
    local ok, err = pcall(function(...) r:FireServer(...) end, ...)
    if not ok then note("%s: %s", name, tostring(err)) end
    return ok
end

local function ensureEquipBest()
    if not CONFIG.autoEquipBest then return end
    local flag = LocalPlayer:FindFirstChild("AutoEquipBest")
    if flag and flag.Value == true then return end
    fire("SetAutoEquipBest", true)
end

-- The game's own auto-roll loop lives in PackRollHandler and shares the same
-- server cooldown we do, so leaving it on means both loops fight over one
-- budget and half of each one's calls come back refused.  Ours holds the cap
-- on dramatic reveals and theirs does not, so theirs goes off.
local function disableGameAuto()
    if not CONFIG.autoRoll then return end
    if dataValue("Auto", false) ~= true then return end
    fire("Auto")
    note("turned the game's own auto-roll off - this loop is faster")
end

-- Hysteresis, and it is not cosmetic: without it the picker flipped Pack4 ->
-- Pack3 and back as income and the balance moved under it, and every flip pays
-- for a fresh five-pack stack it then abandons.  An UPGRADE is always taken;
-- a DOWNGRADE needs the current pack to be unaffordable by a clear margin.
local lastPackSwitch = 0
local PACK_SWITCH_COOLDOWN = 30

local function shouldSwitch(current, want)
    -- Nothing selected at all: take whatever was picked, immediately.
    if current == "" or not PackConfig.Packs[current] then return true end
    if want == current then return false end
    -- A floor under how often the pack may change at all.  Every switch pays
    -- for a fresh stack, so even a correct switch is not worth making twice a
    -- minute.
    if os.clock() - lastPackSwitch < PACK_SWITCH_COOLDOWN then return false end
    if packEV(want) > packEV(current) then return true end
    local ceiling = income() * CONFIG.packSpend * 1.5
    return packCostPerSecond(current) > ceiling
end

local function keepPack()
    if not CONFIG.autoPack then return end
    local want = bestPack()
    if not want or want == "" then return end

    if dataValue("CurrentPack", "") ~= want and shouldSwitch(dataValue("CurrentPack", "") or "", want) then
        -- A pack has to be OWNED before it can be selected, so front a small
        -- stack first.  BuyMax is capped at 10 per call while the tutorial is
        -- unfinished, which is plenty for a stack this size.
        if packStock(want) < 1 then
            local pack = PackConfig.Packs[want]
            if pack and spendable(pack.Price * 5, want) then
                fire("BuyPack", want, "Buy5")
                task.wait(0.4)
            end
        end
        if packStock(want) >= 1 then
            fire("SelectPack", want)
            lastPackSwitch = os.clock()
            note("pack -> %s", PackConfig.Packs[want] and PackConfig.Packs[want].DisplayName or want)
        end
    end

    -- AutoBuy makes the server top the stack back up to exactly what a roll
    -- consumes, which is why this script has no buy loop of its own.
    if dataValue("AutoBuyPack", "") ~= want then
        fire("SetAutoBuy", want)
    end
end

local function buyUpgrades()
    if not CONFIG.autoUpgrades then return end
    for _, name in ipairs(UPGRADE_ORDER) do
        if not alive() or not CONFIG.auto then return end
        local next_ = upgradeNext(name)
        if next_ and next_.currency == "Coins" and spendable(next_.cost, name) then
            local before = upgradeLevel(name)
            -- BuyUpgradeMax takes every level the balance covers in one call.
            fire("BuyUpgradeMax", name)
            task.wait(0.5)
            local after = upgradeLevel(name)
            if after > before then
                STATE.upgradesBought = STATE.upgradesBought + (after - before)
                note("%s %d -> %d", name, before, after)
            end
        end
    end
end

local function buyRank()
    if not CONFIG.autoRank then return end
    local next_ = rankNext()
    if not next_ then return end
    if next_.currency ~= "Coins" then return end
    if not spendable(next_.cost, "RankUp") then return end
    local before = dataValue("Ranks", 0) or 0
    fire("RankUp")
    task.wait(0.6)
    local after = dataValue("Ranks", 0) or 0
    if after > before then
        STATE.ranksBought = STATE.ranksBought + (after - before)
        note("rank %d -> %d  (+%s%% luck, +%s%% coins)",
            before, after, tostring(next_.luck), tostring(next_.coins))
    end
end

local function buyAreas()
    if not CONFIG.autoAreas then return end
    -- Only the Coins-priced areas: the Gems / FarmCoins / VolcanoCoins ones sit
    -- behind side economies this build does not farm.
    local area = nextArea("Coins")
    if not area then return end
    if not spendable(area.cost, area.name) then return end
    fire("BuyArea", area.name)
    task.wait(0.8)
    if areaUnlocked(area.name) then
        STATE.areasBought = STATE.areasBought + 1
        note("unlocked the %s area", area.name)
    end
end

local function doRebirth()
    if not CONFIG.autoRebirth then return end
    if (dataValue("RebirthCooldown", 0) or 0) > 0 then return end
    local reward = rebirthReward()
    if reward < CONFIG.rebirthMin then return end
    -- The payout comes off coins EARNED, so spending never costs anything -
    -- but the rebirth does wipe the BALANCE, so it waits while the reserve is
    -- most of the way to a target that would otherwise be lost.
    local target = reserveTarget()
    if target and coins() >= target.cost * 0.5 then
        note("holding the rebirth, %s is %d%% funded",
            target.name, math.floor(coins() / target.cost * 100))
        return
    end
    local before = dataValue("Rebirths", 0) or 0
    fire("Rebirth")
    task.wait(2)
    local after = dataValue("Rebirths", 0) or 0
    if after > before then
        STATE.rebirthsDone = STATE.rebirthsDone + 1
        note("rebirth +%d  (now %d, +%d%% coins)", after - before, after, after)
    end
end

local function claimOffline()
    if not CONFIG.claimOffline then return end
    fire("OfflineClaim")
end

-- The luck ladders priced in the side-economy currencies.  Bought whenever
-- affordable and never held back: Gems, Cash, LuckyCoins and Tokens have no
-- other spender in this build, so a reserve on them would only idle.
local function buyOtherLuck()
    if not CONFIG.autoLuckOther then return end
    for _, name in ipairs(OTHER_LUCK_ORDER) do
        if not alive() or not CONFIG.auto then return end
        local next_ = upgradeNext(name)
        if next_ and next_.currency ~= "Coins" and currency(next_.currency) >= next_.cost then
            local before = upgradeLevel(name)
            fire("BuyUpgradeMax", name)
            task.wait(0.4)
            local after = upgradeLevel(name)
            if after > before then
                STATE.otherBought = STATE.otherBought + (after - before)
                note("%s %d -> %d (%s)", name, before, after, next_.currency)
            end
        end
    end
end

----------------------------------------------------------------------------
-- lucky circles
--
-- The server spawns a `LuckyCircle<tier>` model into the Workspace every so
-- often and announces it in chat as "spawned! Stand inside for xN Luck. Lasts
-- ...". Standing in it multiplies `UnsavedData.Luck` by the player attribute
-- `CircleLuckMult` - measured, the attribute read 3 with the character inside
-- and 1 outside, and Luck moved 2060 -> 640 the moment the circle expired.
--
-- The body does nothing else in this game, so parking it in the circle is free
-- and it is one of the largest luck multipliers available. The position it
-- started from is remembered and restored afterwards, so a player who parked
-- somewhere on purpose gets their spot back.
----------------------------------------------------------------------------

local homeCFrame = nil

local function rootPart()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function liveCircle()
    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA("Model") and string.match(child.Name, "^LuckyCircle") then
            return child
        end
    end
    return nil
end

local function standInCircle()
    if not CONFIG.autoCircle then
        STATE.circle, STATE.circleMult = "-", 1
        return
    end
    STATE.circleMult = LocalPlayer:GetAttribute("CircleLuckMult") or 1

    local circle = liveCircle()
    local root = rootPart()
    if not root then return end

    if not circle then
        -- Gone: put the body back where it was found, once.
        if homeCFrame and STATE.circle ~= "-" then
            pcall(function() root.CFrame = homeCFrame end)
            note("lucky circle over, back to the spawn")
        end
        STATE.circle = "-"
        return
    end

    local ok, pivot = pcall(function() return circle:GetPivot() end)
    if not ok or not pivot then return end

    if STATE.circle ~= circle.Name then
        if not homeCFrame then homeCFrame = root.CFrame end
        STATE.circle = circle.Name
        STATE.circlesUsed = STATE.circlesUsed + 1
        note("standing in %s", circle.Name)
    end

    -- Re-assert rather than pin every frame: nothing pushes the body here and
    -- a Heartbeat pin would fight the game's own teleports for no gain.
    if (root.Position - pivot.Position).Magnitude > 4 then
        pcall(function()
            root.CFrame = CFrame.new(pivot.Position + Vector3.new(0, 3, 0))
        end)
    end
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

-- The roll loop paces itself inside rollOnce, so this one has no gap of its
-- own beyond a yield.
task.spawn(function()
    while alive() do
        if CONFIG.auto and CONFIG.autoRoll then
            STATE.phase = "rolling"
            local ok, err = pcall(rollOnce)
            if not ok then note("roll: %s", tostring(err)) end
        else
            STATE.phase = "idle"
            task.wait(0.5)
        end
        task.wait(0.05)
    end
end)

loop("spend", 4, function()
    if not CONFIG.auto then return end
    STATE.reserveName, STATE.reserveCost = "-", 0
    local target = reserveTarget()
    if target then
        STATE.reserveName, STATE.reserveCost = target.name, target.cost
    end
    buyUpgrades()
    buyOtherLuck()
    buyRank()
    buyAreas()
end)

loop("circle", 1, function()
    if not CONFIG.auto then return end
    standInCircle()
end)

loop("pack", 6, function()
    if not CONFIG.auto then return end
    keepPack()
end)

loop("upkeep", 10, function()
    if not CONFIG.auto then return end
    ensureEquipBest()
    disableGameAuto()
end)

loop("rebirth", 8, function()
    if not CONFIG.auto then return end
    STATE.rebirthReward = rebirthReward()
    doRebirth()
end)

loop("census", 1, census)

-- Anti-idle.  The game ships its own AFK handling but Roblox still kicks a
-- client that has had no input for 20 minutes, which ends an overnight run.
task.spawn(function()
    local VirtualUser = game:GetService("VirtualUser")
    LocalPlayer.Idled:Connect(function()
        if not alive() or not CONFIG.antiAfk then return end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end)
end)

task.spawn(function()
    task.wait(2)
    if not alive() then return end
    pcall(claimOffline)
    pcall(ensureEquipBest)
end)

----------------------------------------------------------------------------
-- debug handle
--
-- Published BEFORE the panel is built: anything that yields in the UI section
-- would otherwise leave the handle nil and the script reads as "failed to
-- load" from the bridge.
----------------------------------------------------------------------------

_G.__PACKRNG_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    coins = coins, income = income, currency = currency,
    upgradeLevel = upgradeLevel, upgradeNext = upgradeNext,
    packStock = packStock, packsPerRoll = packsPerRoll, rollGap = rollGap,
    cubeValue = cubeValue, packEV = packEV, bestPack = bestPack,
    rebirthBase = rebirthBase, rebirthReward = rebirthReward,
    sessionMulti = sessionMulti, techMulti = techMulti,
    pendingCoinTargets = pendingCoinTargets, reserveTarget = reserveTarget,
    spendable = spendable,
    rollOnce = rollOnce, keepPack = keepPack, buyUpgrades = buyUpgrades,
    buyRank = buyRank, buyAreas = buyAreas, doRebirth = doRebirth,
    ensureEquipBest = ensureEquipBest, disableGameAuto = disableGameAuto,
    claimOffline = claimOffline, census = census, fire = fire,
    buyOtherLuck = buyOtherLuck, standInCircle = standInCircle,
    liveCircle = liveCircle, packCostPerSecond = packCostPerSecond,
    rankNext = rankNext, nextArea = nextArea, abbreviate = abbreviate,
}

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__PACKRNG_WIN then pcall(function() _G.__PACKRNG_WIN:Destroy() end) end
if UI.sweep then UI.sweep("PACKRNG") end

UI.config("packrng", CONFIG)

local win = UI.Window({
    title = "PACK", accentTitle = "RNG", subtitle = "seltonmt",
    name = "PACKRNG", badge = "\240\159\141\128", width = 820, height = 582,
})
_G.__PACKRNG_WIN = win

local page = win:Page("ROLLING", UI.icon and UI.icon.spark or nil)

local rollCard = page:Card("ROLLS", 1):Accent()
rollCard:Toggle("Auto roll", CONFIG.autoRoll, function(v) CONFIG.autoRoll = v end,
    "paced to the server cooldown, no reel animation")
rollCard:Toggle("Auto pick pack", CONFIG.autoPack, function(v) CONFIG.autoPack = v end,
    "keeps the best pack the income can carry selected and auto-bought")
rollCard:Toggle("Auto equip best", CONFIG.autoEquipBest, function(v) CONFIG.autoEquipBest = v end,
    "switches on the game's own server-side equip best")
rollCard:Toggle("Stand in Lucky Circles", CONFIG.autoCircle, function(v) CONFIG.autoCircle = v end,
    "the circle multiplies your luck while you are inside it",
    UI.theme and UI.theme.good or nil)
rollCard:Slider("Pack spend share", 5, 100, math.floor(CONFIG.packSpend * 100), function(v)
    CONFIG.packSpend = v / 100
end)

local spendCard = page:Card("SPENDING", 2)
spendCard:Toggle("Auto upgrades", CONFIG.autoUpgrades, function(v) CONFIG.autoUpgrades = v end,
    "equips, packs per roll, luck, shiny and size, in that order")
spendCard:Toggle("Auto rank", CONFIG.autoRank, function(v) CONFIG.autoRank = v end,
    "ranks add luck and a permanent coin bonus")
spendCard:Toggle("Auto areas", CONFIG.autoAreas, function(v) CONFIG.autoAreas = v end,
    "unlocks the coin-priced areas as they come into reach")
spendCard:Toggle("Spend Gems and Cash on luck", CONFIG.autoLuckOther, function(v) CONFIG.autoLuckOther = v end,
    "Luck II to IV run on the side currencies and nothing else here spends them")
spendCard:Slider("Reserve window (s)", 30, 600, CONFIG.reserveWindow, function(v)
    CONFIG.reserveWindow = v
end)

local rebirthCard = page:Card("REBIRTH", 1)
rebirthCard:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "wipes the coin balance only, keeps cubes, packs, rank and upgrades",
    UI.theme and UI.theme.warn or nil)
local rebirthStep = rebirthCard:Stepper("Rebirth at",
    function() return tostring(CONFIG.rebirthMin) end,
    function(dir)
        CONFIG.rebirthMin = math.clamp(CONFIG.rebirthMin + dir * 5, 1, 500)
        return tostring(CONFIG.rebirthMin)
    end,
    "the payout is computed from coins EARNED, so spending never costs any")

local miscCard = page:Card("SESSION", 2)
miscCard:Toggle("Claim offline earnings", CONFIG.claimOffline, function(v) CONFIG.claimOffline = v end)
miscCard:Toggle("Anti AFK", CONFIG.antiAfk, function(v) CONFIG.antiAfk = v end)
miscCard:Button("Rebirth now", function()
    task.spawn(function()
        local before = dataValue("Rebirths", 0) or 0
        fire("Rebirth")
        task.wait(2)
        local after = dataValue("Rebirths", 0) or 0
        note(after > before and string.format("rebirth +%d", after - before) or "rebirth refused")
    end)
end)
miscCard:Button("Claim offline now", function() task.spawn(claimOffline) end)

local out = page:Card("STATUS", 0):Readout(14)

loop("panel", 0.5, function()
    local lines = {}
    lines[#lines + 1] = "ENGINE"
    lines[#lines + 1] = string.format("  %s   %s coins   %s/s",
        STATE.phase, abbreviate(STATE.coins), abbreviate(STATE.income))
    lines[#lines + 1] = string.format("  rolls %s   this session %d   cubes gained %d   refused %d",
        abbreviate(STATE.rolls), STATE.rollsDone, STATE.cubesGained, STATE.rollsRefused)
    lines[#lines + 1] = string.format("  gap %.2fs   %d pack%s per roll%s",
        STATE.rollGap, STATE.packsPerRoll, STATE.packsPerRoll == 1 and "" or "s",
        STATE.fastRolls and "   FastRolls gamepass" or "")
    local packCfg = PackConfig.Packs[STATE.pack]
    lines[#lines + 1] = string.format("  pack %s   stock %d   last %s",
        packCfg and packCfg.DisplayName or STATE.pack, STATE.packStock, STATE.lastCube)
    lines[#lines + 1] = "CUBES"
    lines[#lines + 1] = string.format("  equipped %d/%d   owned %d in %d kinds   best roll %s",
        STATE.equipped, STATE.maxEquip, STATE.cubesOwned, STATE.cubeKinds, STATE.bestRoll)
    lines[#lines + 1] = string.format("  luck %d%s   lucky circle: %s",
        math.floor(STATE.luck),
        STATE.circleMult > 1 and string.format(" (x%s from the circle)", tostring(STATE.circleMult)) or "",
        STATE.circle ~= "-" and (STATE.circle .. ", standing in it") or "none up right now")
    lines[#lines + 1] = "SPENDING"
    lines[#lines + 1] = string.format("  rank %d   upgrades bought %d (+%d on side currencies)   areas %d",
        STATE.rank, STATE.upgradesBought, STATE.otherBought, STATE.areasBought)
    if STATE.reserveName ~= "-" then
        lines[#lines + 1] = string.format("  saving for %s at %s   (%d%% there)",
            STATE.reserveName, abbreviate(STATE.reserveCost),
            STATE.reserveCost > 0 and math.floor(STATE.coins / STATE.reserveCost * 100) or 0)
    else
        lines[#lines + 1] = "  nothing held back"
    end
    lines[#lines + 1] = "REBIRTH"
    lines[#lines + 1] = string.format("  %d done   next pays %d   index multi x%.2f   %d cube types this run",
        STATE.rebirths, STATE.rebirthReward, sessionMulti(), STATE.sessionCubes)
    if STATE.cooldown > 0 then
        lines[#lines + 1] = string.format("  cooldown %ds", math.floor(STATE.cooldown))
    end
    if not STATE.tutorial then
        lines[#lines + 1] = "  note: the game's tutorial is unfinished, pack buys are capped at 10 per call"
    end
    lines[#lines + 1] = "NOTE"
    lines[#lines + 1] = "  " .. tostring(STATE.note)
    out:set(lines)

    pcall(function()
        win:SetStat(1, abbreviate(STATE.coins), "coins")
        win:SetStat(2, abbreviate(STATE.income) .. "/s", "income")
        win:SetStat(3, tostring(STATE.rebirths), "rebirths")
        win:SetStatus(string.format("%s coins   %s/s   rank %d   %d rebirths   %s",
            abbreviate(STATE.coins), abbreviate(STATE.income), STATE.rank, STATE.rebirths,
            packCfg and packCfg.DisplayName or STATE.pack))
    end)
end)

pcall(function()
    win:SetMaster(CONFIG.auto, "Auto farm running")
    win:OnMaster(function(on) CONFIG.auto = on end)
end)

pcall(function() win:Home() end)

print("[packrng] running - RightShift toggles the panel")
