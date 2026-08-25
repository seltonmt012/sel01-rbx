--!nocheck
--[[
    spingun.lua - "[*] Spin a Gun"  place 76769602972434  (Dayroom Studios)
    ------------------------------------------------------------------------
    A case-opening gacha bolted onto a plot income game. Buy a case, open it,
    get a gun, seat the gun on one of your tycoon slots, and it shoots the
    walls in front of it for money. Money buys more cases and gun levels;
    rebirths buy slots and unlock the better cases.

    The whole loop, measured through the bridge on 2026-08-25:

        RequestCollectMoney("Slot_N")  -> bank that slot's pad
        RequestBuyCase(<case>)         -> OwnedCases[<case>] + 1
        RequestOpenCase(<case>)        -> returns the GUN NAME, +1 OwnedGuns
        RequestEquipBest()             -> the server seats and ranks them itself
        RequestUpgradeGun(<uuid>)      -> +1 level on that gun

    Verified facts this script is built on (do not re-derive):

      * *** RequestClaimForeverGift HAS NO OnServerInvoke AND HANGS FOREVER.
        Every RemoteFunction here goes through rf(), which invokes inside a
        task.spawn behind a wall clock cap. Without that a single call parks
        the caller for good - in the bridge that means the poll loop dies and
        only a manual re-inject brings it back. It is also on a hard blocklist
        below and is never called at all.
      * Functions.GetData:InvokeServer() is the state oracle and answers in
        ~0.25s: Money, Ruby, Spins, RebirthLevel, Tycoon (per slot Owned /
        Gun uuid / MoneyGained), OwnedGuns (uuid -> Name, Rarity, Level,
        Mutations, Skins, Float, Serial), Upgrades, Totals, Rewards, Battles.
        The game's own DataController already calls it once a second, so our
        calls are ordinary traffic. It is cached here for CONFIG.dataTtl.
      * COLLECTING IS NOT POSITION GATED. RequestCollectMoney("Slot_1") banked
        $15,084 with the character never moving. The argument is the slot NAME
        as a string; passing the slot Instance returns false.
      * GUN UPGRADE COST GROWS x1.3 PER LEVEL AND INCOME ONLY x1.033.
        Measured on one USP: levels 12->13->14->15->16 cost 3937, 5118, 6654,
        8650, 11245 (exactly x1.3), and the slot's measured rate went
        607.18/s at level 12 -> 693.61/s at 16 -> 961.39/s at 26. That is
        +3.3% income per level against +30% price, so PAYBACK MULTIPLIES BY
        ~1.26 EVERY LEVEL: 140s for levels 12-16, already 888s for 16-26.
        Upgrading past ~level 20 is a money hole - the money belongs in cases,
        where a better gun's base income is 10-100x higher. Hence maxPayback.
      * INCOME IS WALL THROUGHPUT, NOT A FLAT Money_Per_Sec. Two identical
        USP r1 level 1 measured 138.2/s and 52.3/s in different slots
        (Chromatic x3 vs Frozen x1.5 mutation, plus the slot's own state).
        Ranking guns by hand is therefore guesswork - RequestEquipBest() is
        the server's own ranking and it seats them for you. Measured: it went
        from 2 filled slots to 4 in one call.
      * THE RATE LABEL LIES. Utilities.PlayerInfo.RateLabel read "$145/s"
        immediately after a reshuffle when the real measured rate was 364/s,
        and "$401/s" a moment before. Every number this script trusts comes
        from GetData MoneyGained deltas, never from a label.
      * FindFirstChild(name, true) ON A SLOT IS USELESS. A slot holds dozens
        of same-named labels at different depths, so a deep search returns a
        different one each call and the readings contradict each other. The
        exact paths are:
            Slot_N.UpgradeBoard.SurfaceGui.UpgradeButton.Holder.AmountLabel
            Slot_N.UpgradeBoard.SurfaceGui.UpgradeButton.Holder.LevelLabel
            Slot_N.GunPlatform.GunBillboard.Container.InfoHolder.MoneyLabel
      * CASES HAVE LIMITED STOCK. GetStockInfo() answers a per-case count
        (Bronze 831, Gold 24, Amethyst 3, everything above Virtuoso 0) and it
        refills on StockInterval. Buying a case with 0 stock is refused, so
        the picker filters on it. RequestRestock is a Robux product and is
        never touched.
      * CASE ACCESS IS GATED ON REBIRTH LEVEL. RebirthData.CaseUnlocks:
        Diamond 1, Ruby 2, Steadfast 3 ... Nexshard 42.
      * EV PER DOLLAR FALLS MONOTONICALLY WITH CASE PRICE - Bronze pays 0.241
        expected Money_Per_Sec per dollar, Nexshard 1.67e-11. That does NOT
        make Bronze the right buy: slots are the scarce thing, and a case is
        only worth opening if it can beat the WORST GUN ALREADY SEATED.
        Bronze is 75% rarity 1 and becomes worthless the moment the plot is
        half decent. So the picker buys the most expensive case it can afford
        whose expected value still beats the weakest slot, and otherwise
        SAVES - see the starvation note below.
      * RequestAutoSell(rarity) IS A TOGGLE WHOSE RETURN VALUE IS THE NEW
        STATE, and GetData().AutoSell DOES NOT REFLECT IT. Four toggles in
        both directions all left the field reading {5=true} while the return
        alternated true/false. Anything that wants to know the state has to
        drive it through the return value, which is what syncAutoSell does.
        It is OFF by default: whether the server refuses to auto-sell a gun
        that is currently seated on a slot was never verified, and being
        wrong there sells the plot.
      * Player upgrades (DamageLevel / MoneyLevel / MutationLevel /
        MaxStorageLevel) cost RUBY, not money - the UI code reads RubyHolder
        and RubyLabel. Ruby comes from RequestSpin() (measured 3 -> 21 for
        one spin) and from battles. Storage is 200 at MaxStorageLevel 1 and
        was 5/200 in the session this was written, so it is not a near-term
        constraint.
      * Slots 7..10 are gated on rebirth level and say so on the plot
        ("Rebirth 3" ... "Rebirth 6"). Rebirth rewards are +50% money, +1 gun
        slot and a case unlock, and it KEEPS the guns and their levels -
        measured across a 0 -> 1 rebirth with five guns at levels 1..26.
      * RequestPlaceGun(uuid, "Slot_5") returns false and stayed UNPROVEN.
        The slot's PlacePrompt is 10-stud gated and only opens the inventory
        UI; the real placement call was never captured. RequestEquipBest
        covers the job, so nothing here depends on placing by hand.
      * RequestAutoBuy(<case>) returns false in every argument shape tried
        and is likewise unproven. This script buys its cases itself.

    Robux, never touched: Lucky_Block / Super_Lucky_Block /
    Ultimate_Lucky_Block / Dark_Lucky_Block (RobuxOnly = true in CaseData),
    RequestBuyRubyCase, RequestRubyGamepass, RequestRestock,
    RequestSkipCooldown, and the four gamepass pads on the plot
    (AutoEquipBest 69 R$, AutoCollect 49 R$, NoWallReset).

    Panel: RightShift.  Console handle: _G.__SPINGUN_DBG
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

-- ---------------------------------------------------------------- generation
-- Re-running in the executor does not restart the Lua VM, so every loop below
-- captures this number and exits the moment it stops matching.
_G.__SPINGUN = (_G.__SPINGUN or 0) + 1
local GEN = _G.__SPINGUN

-- ------------------------------------------------------------------- remotes
-- Every WaitForChild carries a timeout: pcall catches errors, not endless
-- waits, so an untimed one in the wrong game yields forever and takes the
-- caller with it.
local Remotes   = ReplicatedStorage:WaitForChild("Remotes", 10)
local FUNCS     = Remotes and Remotes:WaitForChild("Functions", 10)
local Shared    = ReplicatedStorage:WaitForChild("Shared", 10)

-- Named and never called. RequestClaimForeverGift has no OnServerInvoke bound
-- and parks its caller permanently; the others are Robux paths.
local BLOCKED = {
    RequestClaimForeverGift  = true,
    RequestBuyRubyCase       = true,
    RequestRubyGamepass      = true,
    RequestRestock           = true,
    RequestSkipCooldown      = true,
    RequestSkipSkinMachineTimer = true,
}

-- ------------------------------------------------------------------- configs
local GunData, CaseData, RebirthData, MutationData, RarityData, SkinsData
pcall(function() GunData      = require(Shared:WaitForChild("GunData", 10)) end)
pcall(function() CaseData     = require(Shared:WaitForChild("CaseData", 10)) end)
pcall(function() RebirthData  = require(Shared:WaitForChild("RebirthData", 10)) end)
pcall(function() MutationData = require(Shared:WaitForChild("MutationData", 10)) end)
pcall(function() RarityData   = require(Shared:WaitForChild("RarityData", 10)) end)
pcall(function() SkinsData    = require(Shared:WaitForChild("SkinsData", 10)) end)

local GUNS    = (GunData and GunData.List) or {}
local CASES   = (CaseData and CaseData.List) or {}
local UNLOCK  = (RebirthData and RebirthData.CaseUnlocks) or {}
local RCOST   = (RebirthData and RebirthData.Cost) or {}
local RREQ    = (RebirthData and RebirthData.Requirements) or {}
local MUTS    = (MutationData and MutationData.Mutations) or {}
local RARITY  = (RarityData and RarityData.Rarity) or {}
local SKINS   = (SkinsData and SkinsData.List) or {}

-- An unknown mutation is priced HIGH on purpose. Valuing one at 1 is how a
-- Galaxy earning 540M/s got ranked as junk and thrown away in wingsbrainrots.
local UNKNOWN_MUT = 6

-- avg Money_Per_Sec per rarity bucket, straight out of GunData. This is what
-- turns a case's RarityChances into an expected value.
local AVG_MPS = {}
do
    local sum, cnt = {}, {}
    for _, g in pairs(GUNS) do
        local r = g.Rarity
        if r then
            sum[r] = (sum[r] or 0) + (g.Money_Per_Sec or 0)
            cnt[r] = (cnt[r] or 0) + 1
        end
    end
    for r, s in pairs(sum) do AVG_MPS[r] = s / cnt[r] end
end

-- expected Money_Per_Sec of one open, per case
local CASE_EV = {}
for name, c in pairs(CASES) do
    if c.Price and not c.RobuxOnly then
        local ev = 0
        for r, chance in pairs(c.RarityChances or {}) do
            if chance > 0 and AVG_MPS[r] then ev = ev + (chance / 100) * AVG_MPS[r] end
        end
        CASE_EV[name] = ev
    end
end

-- -------------------------------------------------------------------- config
local CONFIG = {
    -- the money loop
    autoCollect   = true,   -- bank every owned slot, not position gated
    autoOpen      = true,   -- buy a case and open it
    autoEquipBest = true,   -- let the server seat and rank the guns

    -- spending
    autoUpgrade   = true,   -- gun levels, but only while they pay back fast
    maxPayback    = 300,    -- seconds; cost x1.3 and income x1.033 per level
    caseReserve   = 3,      -- only buy a case with this many times its price
    storageFloor  = 0.1,    -- stop opening with less than this fraction of
                            -- storage left, so a burst cannot hit the cap
    beatFactor    = 1.0,    -- a case must expect to beat the weakest slot by this

    -- skins: the biggest multiplier in the game and it costs nothing but time
    autoSkin      = true,   -- keep every owned skin machine loaded
    skinPlaced    = false,  -- allow taking a gun OFF the plot to skin it

    -- ruby
    autoRuby      = true,   -- spend ruby on the income upgrades
    rubyOrder     = "Money, Damage",

    -- free stuff
    autoSpin      = true,   -- RequestSpin burns a spin and pays ruby
    autoClaim     = true,   -- index, offline, daily and playtime rewards

    -- progression
    autoRebirth   = true,   -- +50% money, +1 slot, a case unlock; keeps the guns
    huntRebirth   = true,   -- when no case can improve the plot, roll for the
                            -- gun the next rebirth names instead of idling

    -- The game's own auto-sell, which is what keeps storage from filling up.
    -- Storage is 200 and one unattended hour of case opening put 120 guns in
    -- it, at which point RequestOpenCase simply stops answering - "Inventory
    -- full, sell some guns!". This is ON, but it never enables a rarity that
    -- has a gun standing on the plot, so it cannot eat the farm.
    autoSell      = true,
    sellAdaptive  = true,   -- threshold follows the weakest rarity on the plot
    sellBelow     = 4,      -- fixed threshold when sellAdaptive is off

    -- tuning
    openGap       = 0.6,    -- seconds between buy/open pairs
    dataTtl       = 1.0,    -- GetData cache lifetime
    stockTtl      = 20,     -- GetStockInfo cache lifetime
    rfTimeout     = 8,      -- wall clock cap on any single InvokeServer
}

local STATE = {
    note        = "-",
    phase       = "idle",
    collects    = 0, opens = 0, upgrades = 0, spins = 0, claims = 0, rebirths = 0,
    banked      = 0,
    lastGun     = "-",
    caseNote    = "-",
    upgradeNote = "-",
    sellNote    = "-",
    rebirthNote = "-",
    skinNote    = "-",
    rubyNote    = "-",
    skinsApplied = 0, skinsCollected = 0, rubyBuys = 0,
    parked      = {},   -- remote name -> true, anything that ever hit the cap
    rate        = 0,    -- measured $/s, from the banked counter
    slotRate    = {},   -- slot name -> measured $/s, from its own collects
    collectedAt = {},   -- slot name -> os.clock() of its last successful collect
}

-- ------------------------------------------------------------------- helpers
local function fmt(n)
    n = tonumber(n) or 0
    local neg = n < 0
    n = math.abs(n)
    local units = { "", "K", "M", "B", "T", "Qd", "Qn", "Sx", "Sp", "Oc", "No", "Dc" }
    local i = 1
    while n >= 1000 and i < #units do n = n / 1000; i = i + 1 end
    local s
    if i == 1 then s = string.format("%d", n)
    elseif n < 10 then s = string.format("%.2f%s", n, units[i])
    elseif n < 100 then s = string.format("%.1f%s", n, units[i])
    else s = string.format("%.0f%s", n, units[i]) end
    return (neg and "-" or "") .. s
end

local function secs(n)
    n = tonumber(n) or 0
    if n <= 0 then return "-" end
    if n < 90 then return string.format("%.0fs", n) end
    if n < 5400 then return string.format("%.0fm", n / 60) end
    return string.format("%.1fh", n / 3600)
end

-- The one rule that keeps this script and the bridge alive: an InvokeServer
-- that never returns must not be able to park the caller. RequestClaimForeverGift
-- does exactly that. The spawned thread is allowed to leak - one parked thread
-- is a far smaller price than a dead script.
local function rf(name, ...)
    if BLOCKED[name] then
        STATE.note = name .. " is blocked"
        return nil, "blocked"
    end
    local remote = FUNCS and FUNCS:FindFirstChild(name)
    if not remote then return nil, "missing" end

    local args = table.pack(...)
    local done, ok, res = false, false, nil
    task.spawn(function()
        ok, res = pcall(function()
            return remote:InvokeServer(table.unpack(args, 1, args.n))
        end)
        done = true
    end)

    local waited = 0
    while not done and waited < CONFIG.rfTimeout do
        task.wait(0.1)
        waited = waited + 0.1
    end
    if not done then
        STATE.parked[name] = true
        STATE.note = name .. " parked (" .. CONFIG.rfTimeout .. "s cap)"
        return nil, "timeout"
    end
    if not ok then return nil, tostring(res) end
    return res
end

-- ------------------------------------------------------------------- oracles
local dataCache, dataAt = nil, 0
local function data(force)
    local now = os.clock()
    if not force and dataCache and (now - dataAt) < CONFIG.dataTtl then return dataCache end
    local d = rf("GetData")
    if type(d) == "table" then dataCache, dataAt = d, now end
    return dataCache
end

local stockCache, stockAt = nil, 0
local function stock(force)
    local now = os.clock()
    if not force and stockCache and (now - stockAt) < CONFIG.stockTtl then return stockCache end
    local s = rf("GetStockInfo")
    if type(s) == "table" then stockCache, stockAt = s, now end
    return stockCache or {}
end

-- The live NumberValues beat GetData for money: they are replicated and free.
local function money()
    local v = plr:FindFirstChild("CurrentMoney")
    if v then return v.Value end
    local d = data()
    return (d and d.Money) or 0
end
local function ruby()
    local v = plr:FindFirstChild("CurrentRuby")
    if v then return v.Value end
    local d = data()
    return (d and d.Ruby) or 0
end
local function spins()
    local v = plr:FindFirstChild("CurrentRolls")
    if v then return v.Value end
    local d = data()
    return (d and d.Spins) or 0
end
-- STICKY, and that is a fix rather than a nicety. A single GetData that comes
-- back nil used to make this answer 0, which locks every case above Bronze /
-- Silver / Gold behind "not unlocked yet" - and with the weakest slot already
-- worth more than Gold's expected value, the picker then decided that NO case
-- was worth buying and quietly stopped spending while the balance piled up.
-- The rebirth level never decreases in this game, so a missing read keeps the
-- last known value instead of pretending the account is fresh.
local rebirthSeen = 0
local function rebirth()
    local d = data()
    local v = d and d.RebirthLevel
    if type(v) == "number" and v > rebirthSeen then rebirthSeen = v end
    return rebirthSeen
end

local function platform()
    local id = plr:FindFirstChild("PlatformID")
    if not id then return nil end
    local plats = workspace:FindFirstChild("Map")
    plats = plats and plats:FindFirstChild("Platforms")
    return plats and plats:FindFirstChild(id.Value)
end

-- ------------------------------------------------------------- gun valuation
local function mutMult(g)
    local m = 1
    for name in pairs(g.Mutations or {}) do
        local entry = MUTS[name]
        m = m * ((entry and entry.Multiplier) or UNKNOWN_MUT)
    end
    return m
end

local function skinMult(g)
    local m = 1
    for name in pairs(g.Skins or {}) do
        local entry = SKINS[name]
        local mult = entry and (entry.Multiplier or entry.Mult)
        m = m * (tonumber(mult) or 1)
    end
    return m
end

-- TWO INCOME SCALES LIVE IN THIS SCRIPT AND MIXING THEM BREAKS BOTH DECISIONS.
--   * gunValue / CASE_EV are in CONFIG units - GunData's Money_Per_Sec, before
--     the wall throughput the server actually pays out. They are only ever
--     compared against each other, which is what the case picker does.
--   * STATE.slotRate is in REAL DOLLARS PER SECOND, measured off the server's
--     own MoneyGained. It ran about 5x the config value, and it is only ever
--     compared against a price, which is what the upgrade payback does.
-- Feeding a measured rate into the case picker would make every case look
-- hopeless and stop all buying; feeding a config value into the payback makes
-- every upgrade look 5x worse than it is. Keep them apart.
--
-- Raw comparable value. The level term uses the MEASURED 1.033 per level, not
-- the x1.1 the plot billboard prints - the billboard number does not survive a
-- before/after measurement.
local function gunValue(g)
    if not g then return 0 end
    local base = (GUNS[g.Name] and GUNS[g.Name].Money_Per_Sec) or 0
    local lvl  = tonumber(g.Level) or 1
    return base * mutMult(g) * skinMult(g) * (1.033 ^ (lvl - 1))
end

-- Everything the plot looks like right now, in one pass.
local function census()
    local d = data()
    local out = { owned = 0, used = 0, slots = {}, weakest = nil, free = {} }
    if not d then return out end
    for name, t in pairs(d.Tycoon or {}) do
        if t.Owned then
            out.owned = out.owned + 1
            local g = t.Gun and d.OwnedGuns and d.OwnedGuns[t.Gun]
            if g then
                out.used = out.used + 1
                local entry = { slot = name, gun = g, uuid = t.Gun, value = gunValue(g) }
                out.slots[#out.slots + 1] = entry
                if not out.weakest or entry.value < out.weakest.value then out.weakest = entry end
            else
                out.free[#out.free + 1] = name
            end
        end
    end
    table.sort(out.slots, function(a, b) return a.value > b.value end)
    return out
end

-- --------------------------------------------------------------- collecting
-- STATE.banked is summed from the server's own per-slot MoneyGained rather than
-- from a money() before/after pair. The case loop buys in parallel, so a
-- before/after on the balance silently subtracts whatever was spent in between
-- and the income meter reads low. This counter only ever goes up, which is what
-- makes it usable as the rate source below.
local function collectAll()
    local d = data(true)
    if not d then return 0 end
    local now = os.clock()
    local n, sum = 0, 0
    for name, t in pairs(d.Tycoon or {}) do
        local pending = t.MoneyGained or 0
        if t.Owned and pending > 0 then
            if rf("RequestCollectMoney", name) == true then
                n = n + 1
                sum = sum + pending
                -- What that slot earned since its own last successful collect.
                -- This is the only per-slot income figure in the game that is
                -- both server-side and free, and the spend decisions below run
                -- on it rather than on the config's Money_Per_Sec, which
                -- understates the real throughput about fivefold.
                local prev = STATE.collectedAt[name]
                if prev and now > prev then
                    local sample = pending / (now - prev)
                    local old = STATE.slotRate[name]
                    STATE.slotRate[name] = old and (old * 0.5 + sample * 0.5) or sample
                end
                STATE.collectedAt[name] = now
            end
        end
        if _G.__SPINGUN ~= GEN then break end
    end
    if n > 0 then
        STATE.banked = STATE.banked + sum
        STATE.collects = STATE.collects + n
        dataCache = nil
    end
    return n
end

-- What the next rebirth still wants, and which rarities have to be rolled to
-- get it. The rebirth ladder does not only cost money: every step names one or
-- two SPECIFIC guns plus a couple of "any gun of rarity N", so a plot that has
-- outgrown every case it can buy is not stuck - it just has to go hunting.
-- Without this the balance simply piles up: measured at R1 with $10.4M sitting
-- idle, Diamond sold out, Ruby locked behind R2, and R2 waiting on a Glock_17
-- that costs about eight Bronze cases to find.
--
-- The "Any" entries are treated as "rarity at least N" because a better gun is
-- never worse, and the SERVER is the authority anyway - rebirthStep fires and
-- reports whatever it answers, so a wrong guess here shows up as a refusal in
-- the panel rather than as a silent stall.
local function rebirthPlan()
    local d = data()
    local next_ = rebirth() + 1
    local plan = { level = next_, cost = RCOST[next_], missingGuns = {}, missingRarity = {}, ready = false }
    local req = RREQ[next_]
    if not req or not d then return plan end

    local pool = {}
    for uuid, g in pairs(d.OwnedGuns or {}) do pool[uuid] = g end

    local function takeNamed(name)
        for uuid, g in pairs(pool) do
            if g.Name == name then pool[uuid] = nil; return true end
        end
        return false
    end
    local function takeRarity(r)
        local pickUuid, pickRarity
        for uuid, g in pairs(pool) do
            local gr = tonumber(g.Rarity) or 0
            if gr >= r and (not pickRarity or gr < pickRarity) then pickUuid, pickRarity = uuid, gr end
        end
        if pickUuid then pool[pickUuid] = nil; return true end
        return false
    end

    -- named first: an "any" entry must not eat the one gun a named entry needs
    local anyWanted = {}
    for _, e in pairs(req) do
        if e.Type == "Gun" then
            if not takeNamed(e.Key) then plan.missingGuns[#plan.missingGuns + 1] = e.Key end
        else
            anyWanted[#anyWanted + 1] = tonumber(e.Key) or 1
        end
    end
    table.sort(anyWanted, function(a, b) return a > b end)
    for _, r in ipairs(anyWanted) do
        if not takeRarity(r) then plan.missingRarity[#plan.missingRarity + 1] = r end
    end

    plan.ready = (#plan.missingGuns == 0 and #plan.missingRarity == 0)
    return plan
end

-- The rarities that still have to be rolled, as a set, so the case picker can
-- ask "can this case even drop what I am missing?".
local function huntRarities()
    local plan = rebirthPlan()
    local want = {}
    for _, name in ipairs(plan.missingGuns) do
        local g = GUNS[name]
        if g and g.Rarity then want[g.Rarity] = true end
    end
    for _, r in ipairs(plan.missingRarity) do want[r] = true end
    return want, plan
end

-- --------------------------------------------------------------- case picker
-- Returns every case that is unlocked at this rebirth level and actually has
-- stock, richest first.
local function candidates()
    local rb = rebirth()
    local st = stock()
    local list = {}
    for name, c in pairs(CASES) do
        if c.Price and not c.RobuxOnly then
            local need = UNLOCK[name] or 0
            local have = st[name]
            if rb >= need and (have == nil or have > 0) then
                list[#list + 1] = {
                    name  = name,
                    price = c.Price,
                    ev    = CASE_EV[name] or 0,
                    stock = have,
                }
            end
        end
    end
    table.sort(list, function(a, b) return a.price > b.price end)
    return list
end

-- The starvation guard, in the shape that finally worked in Sell Ores: reserve
-- for the BEST-VALUE target rather than the cheapest, and let a trivially cheap
-- step through rather than blocking a 6,000 purchase to save for a million.
local function pickCase()
    local c = census()
    local floorValue = (c.weakest and c.weakest.value or 0) * CONFIG.beatFactor
    -- an empty slot has nothing to beat
    if #c.free > 0 then floorValue = 0 end

    local list = candidates()
    if #list == 0 then return nil, "no case unlocked and in stock" end

    local m = money()
    local best, goal
    for _, e in ipairs(list) do
        if e.ev >= floorValue then
            if not goal or e.price < goal.price then goal = e end
            if m >= e.price * CONFIG.caseReserve and not best then best = e end
        end
    end

    if best then return best, nil end

    -- Nothing on the shelf can improve the plot. That is not a dead end: the
    -- next rebirth is worth +50% money, another slot and the next case tier,
    -- and it is usually waiting on one NAMED gun. Roll the cheapest case that
    -- can actually drop the rarity that gun sits at, rather than letting the
    -- balance pile up doing nothing.
    if not goal and CONFIG.huntRebirth then
        local want, plan = huntRarities()
        if next(want) then
            local cheapest
            for _, e in ipairs(list) do
                local c = CASES[e.name]
                local canDrop = false
                for r in pairs(want) do
                    if (c.RarityChances and c.RarityChances[r] or 0) > 0 then canDrop = true break end
                end
                if canDrop and m >= e.price * CONFIG.caseReserve then
                    if not cheapest or e.price < cheapest.price then cheapest = e end
                end
            end
            if cheapest then
                cheapest = {
                    name = cheapest.name, price = cheapest.price,
                    ev = cheapest.ev, stock = cheapest.stock, hunting = true,
                }
                local target = plan.missingGuns[1]
                    or ("any r" .. tostring(plan.missingRarity[1] or "?"))
                return cheapest, nil, ("hunting %s for R%d"):format(target, plan.level)
            end
        end
    end

    if goal then
        -- trivially cheap steps bypass the reserve entirely
        for _, e in ipairs(list) do
            if e.ev >= floorValue and e.price <= m * 0.001 then return e, nil end
        end
        return nil, ("saving for %s ($%s)"):format(goal.name, fmt(goal.price))
    end
    return nil, ("no case beats the weakest slot ($%s/s) - rebirth for a better one")
        :format(fmt(c.weakest and c.weakest.value or 0))
end

-- A case already sitting in OwnedCases is paid for, so it is opened before any
-- money is spent and WITHOUT asking the picker whether it beats the plot - the
-- money is gone either way and a sunk case can only add. This was found the
-- hard way: the account had 55 Diamond, 30 Gold, 3 Amethyst and 1 Ruby case
-- unopened (68 Diamond bought against 25 total rolls) while the script sat
-- there deciding that no case was worth BUYING. Richest first, by expected
-- value, so the good ones are not left behind if the inventory cap ever bites.
local function openOwned()
    local d = data()
    local owned = d and d.OwnedCases
    if not owned then return false end
    local best
    for name, count in pairs(owned) do
        if (tonumber(count) or 0) > 0 and CASES[name] and not CASES[name].RobuxOnly then
            local ev = CASE_EV[name] or 0
            if not best or ev > best.ev then best = { name = name, ev = ev, count = count } end
        end
    end
    if not best then return false end
    local got = rf("RequestOpenCase", best.name)
    if type(got) == "string" then
        STATE.opens = STATE.opens + 1
        local r = GUNS[got] and GUNS[got].Rarity
        STATE.lastGun = ("%s (%s)"):format(got,
            (r and RARITY[r] and RARITY[r].RarityName) or ("r" .. tostring(r or "?")))
        STATE.caseNote = ("opening owned %s  x%s left"):format(best.name, tostring(best.count))
        dataCache = nil
        return true
    end
    return false
end

-- Storage is a hard wall, not a soft one: at the cap RequestOpenCase simply
-- stops answering ("Inventory full, sell some guns!") and every later open is
-- wasted. Auto-sell clears the junk, but it only fires on what DROPS, so a burst
-- of opening still outruns it - measured climbing 5 -> 158 of 200 in one
-- session. Opening pauses near the cap and lets the selling catch up rather than
-- hammering a remote that has stopped replying.
local function storageRoom()
    local d = data()
    if not d then return 1, 0, 0 end
    local n = 0
    for _ in pairs(d.OwnedGuns or {}) do n = n + 1 end
    local cap = 200 + 5 * (((d.Upgrades and d.Upgrades.MaxStorageLevel) or 1) - 1)
    return 1 - (n / cap), n, cap
end

local function openOnce()
    local room, used, cap = storageRoom()
    if room <= CONFIG.storageFloor then
        STATE.caseNote = ("storage %d/%d - waiting for auto-sell"):format(used, cap)
        return false
    end
    if openOwned() then return true end
    local pick, why, hunt = pickCase()
    if not pick then
        STATE.caseNote = why or "-"
        return false
    end
    STATE.caseNote = ("%s $%s  ev %s/s%s%s"):format(
        pick.name, fmt(pick.price), fmt(pick.ev),
        pick.stock and ("  stock " .. tostring(pick.stock)) or "",
        hunt and ("   " .. hunt) or "")

    if rf("RequestBuyCase", pick.name) ~= true then
        stockCache = nil  -- a refusal is usually stock, so re-read it
        return false
    end
    local got = rf("RequestOpenCase", pick.name)
    if type(got) == "string" then
        STATE.opens = STATE.opens + 1
        local r = GUNS[got] and GUNS[got].Rarity
        STATE.lastGun = ("%s (%s)"):format(got, (r and RARITY[r] and RARITY[r].RarityName) or ("r" .. tostring(r or "?")))
        dataCache = nil
        return true
    end
    return false
end

-- --------------------------------------------------------------- upgrading
-- The upgrade price is only ever printed, never returned by a remote, and above
-- a million it is printed ABBREVIATED: "$5.5M" next to "$1,142". Reading just
-- the digits turns 5,500,000 into 5, which made a level 23 gun look like the
-- cheapest upgrade on the plot with a 0s payback, put it at the top of the
-- ranking every pass, and then had the server refuse it forever.
--
-- The suffix ladder is NOT hand-written - a hand-written one is how the Drill
-- Farm "Q" bug happened. It is calibrated from the game's own FormatCompact by
-- asking it to render 1e3, 1e6, 1e9 ... and keeping whatever letters it uses,
-- so the table matches the labels by construction. If the module is missing the
-- parser simply refuses abbreviated text instead of guessing.
local SUFFIX = {}
do
    local FN
    pcall(function() FN = require(ReplicatedStorage.Library.FormatNumber) end)
    local compact = FN and (FN.FormatCompact or FN.FormatNumber)
    if compact then
        for exp = 3, 63, 3 do
            local ok, text = pcall(compact, 10 ^ exp)
            if ok and type(text) == "string" then
                local suffix = text:match("^[%d%.,%$]*(%a+)")
                if suffix and not SUFFIX[suffix:lower()] then
                    SUFFIX[suffix:lower()] = 10 ^ exp
                end
            end
        end
    end
end

local function parsePrice(text)
    if type(text) ~= "string" then return nil end
    local num, suffix = text:match("([%d%.,]+)%s*(%a*)")
    if not num then return nil end
    local value = tonumber((num:gsub(",", "")))
    if not value then return nil end
    if suffix and suffix ~= "" then
        local mult = SUFFIX[suffix:lower()]
        if not mult then return nil end   -- refuse rather than read 5.5M as 5
        value = value * mult
    end
    return value
end

-- The exact label paths. A deep FindFirstChild on a slot returns a different
-- label every call and the readings contradict each other.
local function boardPrice(slotName)
    local p = platform()
    local slot = p and p:FindFirstChild("Slots")
    slot = slot and slot:FindFirstChild(slotName)
    local holder = slot and slot:FindFirstChild("UpgradeBoard")
    holder = holder and holder:FindFirstChild("SurfaceGui")
    holder = holder and holder:FindFirstChild("UpgradeButton")
    holder = holder and holder:FindFirstChild("Holder")
    local label = holder and holder:FindFirstChild("AmountLabel")
    if not label then return nil end
    return parsePrice(label.Text or "")
end

-- Income rises 1.033 per level and the price 1.3, so payback multiplies by
-- about 1.26 every level. Ranking on payback and capping it is what stops the
-- money disappearing into a level 40 gun instead of into the next case tier.
local function upgradePass()
    local c = census()
    if #c.slots == 0 then STATE.upgradeNote = "nothing seated"; return 0 end

    local best, bestPay, waiting = nil, nil, 0
    for _, e in ipairs(c.slots) do
        local lvl = tonumber(e.gun.Level) or 1
        local max = tonumber(e.gun.MaxLevel) or 50
        -- The measured rate, never the config value: Money_Per_Sec is a base
        -- number and the real throughput ran about five times higher, which
        -- makes every payback look five times worse than it is. A slot that has
        -- not been collected twice yet has no measurement, so it is skipped
        -- rather than guessed at - one more collect cycle and it joins in.
        local rate = STATE.slotRate[e.slot]
        if lvl < max and rate and rate > 0 then
            local price = boardPrice(e.slot)
            if price and price > 0 then
                local gain = rate * 0.033              -- measured, per level
                local pay  = price / gain
                if pay <= CONFIG.maxPayback then
                    if not bestPay or pay < bestPay then best, bestPay = e, pay end
                end
            end
        elseif lvl < max then
            waiting = waiting + 1
        end
    end

    if not best then
        STATE.upgradeNote = ("nothing under %s payback%s"):format(secs(CONFIG.maxPayback),
            waiting > 0 and (" (%d slot(s) not measured yet)"):format(waiting) or "")
        return 0
    end
    local price = boardPrice(best.slot) or 0
    if money() < price then
        STATE.upgradeNote = ("%s needs $%s (payback %s)"):format(best.slot, fmt(price), secs(bestPay))
        return 0
    end
    if rf("RequestUpgradeGun", best.uuid) == true then
        STATE.upgrades = STATE.upgrades + 1
        STATE.upgradeNote = ("%s %s -> lvl %d  $%s  payback %s"):format(
            best.slot, best.gun.Name, (tonumber(best.gun.Level) or 1) + 1, fmt(price), secs(bestPay))
        dataCache = nil
        return 1
    end
    STATE.upgradeNote = best.slot .. " refused"
    return 0
end

-- ------------------------------------------------------------------- claims
local function claimPass()
    local n = 0
    -- RequestClaimForeverGift is deliberately absent: it never returns.
    if rf("RequestClaimAllIndex") == true then n = n + 1 end
    if rf("RequestClaimOfflineReward") == true then n = n + 1 end
    if rf("RequestClaimDailyReward") == true then n = n + 1 end
    -- A claim remote can want an index; the bare call answers nil here.
    local d = data()
    local coll = d and d.Rewards and d.Rewards.CollectedPlaytimeRewards
    if coll then
        for idx, taken in pairs(coll) do
            if taken == false then
                if rf("RequestClaimPlaytimeReward", tonumber(idx) or idx) == true then n = n + 1 end
            end
            if _G.__SPINGUN ~= GEN then break end
        end
    end
    if n > 0 then STATE.claims = STATE.claims + n; dataCache = nil end
    return n
end

local function spinPass()
    if spins() <= 0 then return 0 end
    local before = ruby()
    local r = rf("RequestSpin")
    if r ~= nil then
        STATE.spins = STATE.spins + 1
        task.wait(0.4)
        STATE.note = ("spin -> +%d ruby"):format(math.max(0, ruby() - before))
        dataCache = nil
        return 1
    end
    return 0
end

-- --------------------------------------------------------------- auto-sell
-- RequestSellGuns was never solved: every argument shape tried ({uuid}, uuid,
-- {[uuid]=true}) was refused, and the sell shop's list is only built when the
-- pad opens it, so no real call could be captured. It does not matter, because
-- the game's OWN auto-sell does the job server side and that one is proven.
--
-- Its state cannot be read. GetData().AutoSell showed {5=true} through four
-- toggles in both directions while the RETURN VALUE alternated correctly, so
-- the return is the only truth available and reaching a wanted state means
-- toggle, read the answer, toggle again if it went the wrong way.
--
-- TWO GUARDS, and the second one is what makes this safe to have on:
--   * a rarity with a gun STANDING ON THE PLOT is never enabled, whatever the
--     threshold says. Whether the server spares a seated gun was never
--     verified, and being wrong there sells the farm - so the question is
--     avoided instead of gambled on.
--   * adaptive mode takes the threshold from the weakest rarity actually
--     placed, so it tightens by itself as the plot improves. Measured on a
--     developed plot: r4/r5/r6/r9 seated, 102 spare guns at r1-r3 doing
--     nothing but filling storage.
local function placedRarities()
    local d = data()
    local set = {}
    if not d then return set end
    for _, t in pairs(d.Tycoon or {}) do
        local g = t.Gun and d.OwnedGuns and d.OwnedGuns[t.Gun]
        if g and g.Rarity then set[g.Rarity] = true end
    end
    return set
end

local function sellThreshold()
    if not CONFIG.sellAdaptive then return CONFIG.sellBelow end
    local placed = placedRarities()
    local lowest
    for r in pairs(placed) do
        if not lowest or r < lowest then lowest = r end
    end
    return lowest or CONFIG.sellBelow
end

local function syncAutoSell()
    if not CONFIG.autoSell then STATE.sellNote = "off"; return end
    local threshold = sellThreshold()
    local placed = placedRarities()
    local changed, blocked = 0, 0
    for r = 1, 24 do
        local want = (r < threshold) and not placed[r]
        if placed[r] and r < threshold then blocked = blocked + 1 end
        local now = rf("RequestAutoSell", r)
        if type(now) == "boolean" then
            if now ~= want then
                local again = rf("RequestAutoSell", r)
                if type(again) == "boolean" and again ~= want then
                    STATE.sellNote = ("rarity %d would not settle"):format(r)
                    return
                end
                changed = changed + 1
            end
        else
            STATE.sellNote = "toggle refused"
            return
        end
        if _G.__SPINGUN ~= GEN then return end
        task.wait(0.05)
    end
    local d = data(true)
    local n = 0
    for _ in pairs((d and d.OwnedGuns) or {}) do n = n + 1 end
    STATE.sellNote = ("selling below r%d%s   %d changed   storage %d/%d"):format(
        threshold, CONFIG.sellAdaptive and " (adaptive)" or "", changed,
        n, 200 + 5 * (((d and d.Upgrades and d.Upgrades.MaxStorageLevel) or 1) - 1))
    if blocked > 0 then
        STATE.sellNote = STATE.sellNote .. ("   %d rarity kept (on the plot)"):format(blocked)
    end
end

-- ------------------------------------------------------------------ rebirth
local function reqText(n)
    local req = RREQ[n]
    if not req then return "-" end
    local parts = {}
    for _, e in pairs(req) do
        if e.Type == "Gun" then parts[#parts + 1] = tostring(e.Key)
        else parts[#parts + 1] = "any r" .. tostring(e.Key) end
    end
    table.sort(parts)
    return table.concat(parts, " + ")
end

local function rebirthStep()
    local plan = rebirthPlan()
    local next_, cost = plan.level, plan.cost
    if not cost then STATE.rebirthNote = "max"; return false end
    if money() < cost then
        STATE.rebirthNote = ("R%d needs $%s + %s"):format(next_, fmt(cost), reqText(next_))
        return false
    end
    -- Only fire once the requirement guns are actually owned. Firing every 20s
    -- against a requirement that cannot be met is a refusal loop that tells
    -- nobody anything; the note below names the missing piece instead, and the
    -- case picker goes and rolls for it.
    if not plan.ready then
        local miss = {}
        for _, n in ipairs(plan.missingGuns) do miss[#miss + 1] = n end
        for _, r in ipairs(plan.missingRarity) do miss[#miss + 1] = "any r" .. tostring(r) end
        STATE.rebirthNote = ("R%d affordable, still missing %s"):format(next_, table.concat(miss, " + "))
        return false
    end
    if rf("RequestRebirth") == true then
        STATE.rebirths = STATE.rebirths + 1
        STATE.rebirthNote = "rebirthed into R" .. tostring(next_)
        dataCache, stockCache = nil, nil
        return true
    end
    STATE.rebirthNote = ("R%d refused - needs %s"):format(next_, reqText(next_))
    return false
end

-- ------------------------------------------------------------------- skins
-- A skin machine takes a gun, holds it for a time set by that gun's RARITY, and
-- hands it back wearing a skin whose Multiplier goes straight into its income.
-- The ladder runs 1.25x (Paper) to 36x (Neon_Moss) and the rarity roll is
-- 55.11 / 27.53 / 10.08 / 4.54 / 1.94 / 0.75 / 0.05 percent, which comes out at
-- about 4.3x expected. It is the largest multiplier in the game and the only one
-- that costs nothing but waiting.
--
-- THE MACHINE TAKES THE GUN OFF THE PLOT - the record loses CurrentSlot the
-- moment it goes in. So the default feeds it SPARE guns only: a Kriss Vector
-- earning 8K/s parked in a machine for its 12 hour rarity-9 timer loses more
-- than the skin returns for most of a day, while a spare costs nothing and
-- RequestEquipBest seats it by itself once it comes back worth more than the
-- weakest slot. skinPlaced lifts that restriction for anybody who wants it.
--
-- Machine time is the scarce resource, so the pick maximises value gained per
-- SECOND OF MACHINE TIME rather than raw value - the timer is 300s at rarity 1
-- and 604,800s (a full week) at rarity 24, so mid rarities win.
--
-- The ready check is StartTime + GunRarityBasedTime[rarity], both server side.
-- Verified against the machine's own TimerLabel: 90s elapsed of 300 showed
-- "3m 31s" left. No label is parsed here.
local SKIN_TIME = (SkinsData and SkinsData.GunRarityBasedTime) or {}
local SKIN_EV = 1
do
    local chances = (SkinsData and SkinsData.RarityChances) or {}
    local sum, count = {}, {}
    for _, sk in pairs(SKINS) do
        local r = sk.Rarity
        if r then
            sum[r] = (sum[r] or 0) + (sk.Multiplier or 1)
            count[r] = (count[r] or 0) + 1
        end
    end
    local ev, total = 0, 0
    for r, chance in pairs(chances) do
        if count[r] then
            ev = ev + (chance / 100) * (sum[r] / count[r])
            total = total + chance
        end
    end
    if total > 0 then SKIN_EV = ev * (100 / total) end
end

local function skinPass()
    local d = data()
    if not d then return end
    local now = os.time()
    local collected = 0

    -- 1. hand back anything whose timer has run out
    for name, m in pairs(d.SkinsMachines or {}) do
        if m.Owned and m.Gun and m.StartTime then
            local g = d.OwnedGuns and d.OwnedGuns[m.Gun]
            local need = SKIN_TIME[g and g.Rarity or 1] or math.huge
            if (now - m.StartTime) >= need then
                if rf("RequestCollectGunSkinMachine", name) == true then
                    collected = collected + 1
                    dataCache = nil
                end
            end
        end
        if _G.__SPINGUN ~= GEN then return end
    end

    -- 2. load every free machine with the best candidate
    d = data(true)
    if not d then return end

    -- A gun sitting INSIDE a machine still has no skin and no slot, so it passes
    -- the candidate filter and - being the best of the spares, which is exactly
    -- why it was loaded in the first place - it wins the ranking every pass. The
    -- server then refuses it, nothing is recorded against it, and the next pass
    -- picks it again: the free machines never got filled and the note read
    -- "applied 0" forever. Every uuid already in a machine is excluded up front.
    local taken = {}
    for _, m in pairs(d.SkinsMachines or {}) do
        if m.Gun then taken[m.Gun] = true end
    end

    for name, m in pairs(d.SkinsMachines or {}) do
        if m.Owned and not m.Gun then
            local best, bestScore
            for uuid, g in pairs(d.OwnedGuns or {}) do
                local time = SKIN_TIME[g.Rarity or 1]
                if time and time > 0
                   and not taken[uuid]
                   and next(g.Skins or {}) == nil
                   and not g.Locked
                   and (CONFIG.skinPlaced or g.CurrentSlot == nil) then
                    local score = gunValue(g) * (SKIN_EV - 1) / time
                    if not bestScore or score > bestScore then best, bestScore = uuid, score end
                end
            end
            if best and rf("RequestApplySkinMachine", best, name) == true then
                taken[best] = true
                STATE.skinsApplied = STATE.skinsApplied + 1
                dataCache = nil
            end
        end
        if _G.__SPINGUN ~= GEN then return end
    end

    STATE.skinsCollected = STATE.skinsCollected + collected
    local busy, own = 0, 0
    for _, m in pairs((data() or {}).SkinsMachines or {}) do
        if m.Owned then
            own = own + 1
            if m.Gun then busy = busy + 1 end
        end
    end
    STATE.skinNote = ("%d/%d loaded   applied %d, collected %d   ~%.1fx expected"):format(
        busy, own, STATE.skinsApplied, STATE.skinsCollected, SKIN_EV)
end

-- --------------------------------------------------------------------- ruby
-- Money Boost and Gun Damage are +10% each per level and both land on income.
-- The shop PRINTS "100" ruby and the server charged 25, so the price label is
-- not trusted for anything: the call is made and the reply is what counts.
-- ROUND ROBIN, not a priority list. A fixed order starves everything below the
-- first entry that keeps succeeding: "Money, Damage" bought Money five times in
-- a row and Damage never once, because Money was always affordable. Both are
-- +10% income per level, so they are meant to climb together - the cursor moves
-- on after every successful buy.
local rubyCursor = 0
local function rubyPass()
    local order = {}
    for word in tostring(CONFIG.rubyOrder):gmatch("[%a_]+") do order[#order + 1] = word end
    if #order == 0 then order = { "Money", "Damage" } end

    local before = ruby()
    for step = 1, #order do
        local key = order[((rubyCursor + step - 1) % #order) + 1]
        if rf("RequestPlayerUpgrade", key) == true then
            rubyCursor = rubyCursor + step
            STATE.rubyBuys = STATE.rubyBuys + 1
            dataCache = nil
            task.wait(0.3)
            STATE.rubyNote = ("bought %s   ruby %d -> %d   (%d total)"):format(
                key, before, ruby(), STATE.rubyBuys)
            return 1
        end
        if _G.__SPINGUN ~= GEN then return 0 end
    end
    local u = (data() or {}).Upgrades
    STATE.rubyNote = ("ruby %d - nothing affordable (money lvl %s, damage lvl %s)"):format(
        before, tostring(u and u.MoneyLevel), tostring(u and u.DamageLevel))
    return 0
end

-- --------------------------------------------------------------------- loops
local function loop(period, key, fn)
    task.spawn(function()
        while _G.__SPINGUN == GEN do
            if CONFIG[key] then
                local ok, err = pcall(fn)
                if not ok then STATE.note = tostring(err) end
            end
            task.wait(period)
        end
    end)
end

loop(5,  "autoCollect", function() STATE.phase = "collect"; collectAll() end)
loop(CONFIG.openGap, "autoOpen", function()
    STATE.phase = "case"
    if openOnce() and CONFIG.autoEquipBest then rf("RequestEquipBest") end
end)
loop(8,  "autoUpgrade", function() STATE.phase = "upgrade"; upgradePass() end)
loop(20, "autoSkin",    function() STATE.phase = "skins"; skinPass() end)
-- Re-synced rather than set once: the threshold follows the plot, and the plot
-- changes every time RequestEquipBest seats something better.
loop(120, "autoSell",   function() syncAutoSell() end)
loop(30, "autoRuby",    function() rubyPass() end)
loop(45, "autoSpin",    function() spinPass() end)
loop(90, "autoClaim",   function() claimPass() end)
loop(20, "autoRebirth", function() rebirthStep() end)

-- Seat anything loose even when nothing was opened this pass.
task.spawn(function()
    while _G.__SPINGUN == GEN do
        if CONFIG.autoEquipBest then
            local c = census()
            if #c.free > 0 then pcall(function() rf("RequestEquipBest") end) end
        end
        task.wait(12)
    end
end)

-- The income meter. It reads STATE.banked, not the per-slot MoneyGained: the
-- collect loop zeroes MoneyGained every few seconds, so a delta taken across a
-- collect measures the leftovers rather than the income. The first version did
-- exactly that and reported 59/s while the plot was really earning several
-- hundred. banked only ever grows, so the delta is always the money actually
-- taken in over the window. Collects are lumpy, hence the 12s window and the
-- exponential smoothing on top.
task.spawn(function()
    local last, lastAt = STATE.banked, os.clock()
    while _G.__SPINGUN == GEN do
        task.wait(12)
        local now = os.clock()
        local dt = now - lastAt
        if dt > 0 then
            local sample = (STATE.banked - last) / dt
            STATE.rate = (STATE.rate > 0) and (STATE.rate * 0.4 + sample * 0.6) or sample
        end
        last, lastAt = STATE.banked, now
    end
end)

-- --------------------------------------------------------------------- panel
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__SPINGUN_WIN then pcall(function() _G.__SPINGUN_WIN:Destroy() end) end
for _, parent in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui"), plr:FindFirstChild("PlayerGui") }) do
    pcall(function()
        for _, g in ipairs(parent:GetChildren()) do
            if g.Name == "SPINGUN_PANEL" then g:Destroy() end
        end
    end)
end

-- Merges the saved file into CONFIG before the panel is built, so every control
-- comes up on its saved state by itself.
UI.config("spingun", CONFIG)

local win = UI.Window({
    title = "SPIN", accentTitle = "A GUN", subtitle = "seltonmt",
    badge = "*", width = 820, height = 582, name = "SPINGUN_PANEL",
})
_G.__SPINGUN_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local cMoney = farm:Card("PLOT", 1):Accent()
cMoney:Toggle("Auto collect", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
    "banks every slot - not position gated, works from anywhere", UI.theme.good)
cMoney:Toggle("Auto equip best", CONFIG.autoEquipBest, function(v) CONFIG.autoEquipBest = v end,
    "the server ranks and seats the guns itself", UI.theme.good)

local cCase = farm:Card("CASES", 2)
cCase:Toggle("Buy and open", CONFIG.autoOpen, function(v) CONFIG.autoOpen = v end,
    "richest case that is unlocked, in stock and beats the weakest slot")
cCase:Slider("Keep x price", 1, 20, CONFIG.caseReserve, function(v)
    CONFIG.caseReserve = math.floor(v)
end)
cCase:Slider("Beat weakest by", 1, 5, CONFIG.beatFactor, function(v)
    CONFIG.beatFactor = v
end)

local spend = win:Page("SPEND", UI.icon.coin)

local cUp = spend:Card("GUN LEVELS", 1):Accent()
cUp:Toggle("Auto upgrade", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
    "cost x1.3 per level, income only x1.033 - payback capped on purpose")
cUp:Slider("Max payback", 30, 1800, CONFIG.maxPayback, function(v)
    CONFIG.maxPayback = math.floor(v)
end)

local cSkin = spend:Card("SKINS", 2):Accent()
cSkin:Toggle("Keep the machines loaded", CONFIG.autoSkin, function(v) CONFIG.autoSkin = v end,
    "skins multiply income 1.25x to 36x, about 4.3x expected, and cost only time",
    UI.theme.good)
cSkin:Toggle("Allow taking guns off the plot", CONFIG.skinPlaced, function(v) CONFIG.skinPlaced = v end,
    "a machine holds the gun for its whole timer - 12h at rarity 9", UI.theme.bad)
cSkin:Toggle("Spend ruby", CONFIG.autoRuby, function(v) CONFIG.autoRuby = v end,
    "Money Boost and Gun Damage are +10% income each per level")

local cFree = spend:Card("FREE", 0)
cFree:Toggle("Spin for ruby", CONFIG.autoSpin, function(v) CONFIG.autoSpin = v end,
    "one spin paid +18 ruby; ruby buys the player upgrades", UI.theme.good)
cFree:Toggle("Claim rewards", CONFIG.autoClaim, function(v) CONFIG.autoClaim = v end,
    "index, offline, daily and playtime")
cFree:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "+50% money, +1 slot, a case unlock - keeps the guns", UI.theme.warn)

local cSell = spend:Card("AUTO SELL", 0)
cSell:Toggle("Use the game's auto sell", CONFIG.autoSell, function(v)
    CONFIG.autoSell = v
    task.spawn(syncAutoSell)
end, "keeps storage under the 200 cap - a full inventory stops every case",
    UI.theme.good)
cSell:Toggle("Follow the plot", CONFIG.sellAdaptive, function(v)
    CONFIG.sellAdaptive = v
    if CONFIG.autoSell then task.spawn(syncAutoSell) end
end, "threshold tracks the weakest rarity seated; a seated rarity is never sold")
cSell:Slider("Sell below rarity", 1, 12, CONFIG.sellBelow, function(v)
    CONFIG.sellBelow = math.floor(v)
    if CONFIG.autoSell then task.spawn(syncAutoSell) end
end)

local cOut = farm:Card("STATUS", 0)
local out = cOut:Readout(12)

task.spawn(function()
    while _G.__SPINGUN == GEN do
        local c = census()
        local parked = {}
        for name in pairs(STATE.parked) do parked[#parked + 1] = name end

        win:SetStatus(("$%s   %s/s   slots %d/%d   R%d   %d spins"):format(
            fmt(money()), fmt(STATE.rate), c.used, c.owned, rebirth(), spins()))
        pcall(function()
            win:SetStat(1, fmt(money()), "money")
            win:SetStat(2, fmt(STATE.rate), "per second")
            win:SetStat(3, tostring(rebirth()), "rebirths")
        end)

        out:set({
            "PLOT",
            ("  %d of %d slots used   banked $%s in %d collects"):format(
                c.used, c.owned, fmt(STATE.banked), STATE.collects),
            ("  weakest %s   measured %s/s"):format(
                c.weakest and ("%s lvl %d"):format(c.weakest.gun.Name, c.weakest.gun.Level or 1) or "-",
                c.weakest and fmt(STATE.slotRate[c.weakest.slot] or 0) or "0"),
            "CASES",
            "  " .. STATE.caseNote,
            ("  %d opened   last %s"):format(STATE.opens, STATE.lastGun),
            "SPENDING",
            "  " .. STATE.upgradeNote,
            ("  %d upgrades   %d spins   %d claims   ruby %s"):format(
                STATE.upgrades, STATE.spins, STATE.claims, fmt(ruby())),
            "SKINS + RUBY",
            "  " .. STATE.skinNote,
            "  " .. STATE.rubyNote,
            "PROGRESSION",
            "  " .. STATE.rebirthNote,
            ("  sell: %s%s"):format(STATE.sellNote,
                #parked > 0 and ("   PARKED: " .. table.concat(parked, ", ")) or ""),
        })
        win:Refresh()
        task.wait(0.5)
    end
end)

pcall(function()
    win:SetMaster(CONFIG.autoOpen, "Auto Farm running")
    win:OnMaster(function(on)
        CONFIG.autoOpen    = on
        CONFIG.autoCollect = on or CONFIG.autoCollect
    end)
end)

-- ---------------------------------------------------------------- debug hook
_G.__SPINGUN_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    rf = rf, data = data, stock = stock, census = census,
    money = money, ruby = ruby, spins = spins, rebirth = rebirth,
    gunValue = gunValue, mutMult = mutMult, skinMult = skinMult,
    candidates = candidates, pickCase = pickCase, openOnce = openOnce,
    collectAll = collectAll, upgradePass = upgradePass, boardPrice = boardPrice,
    openOwned = openOwned, storageRoom = storageRoom,
    claimPass = claimPass, spinPass = spinPass, syncAutoSell = syncAutoSell,
    slotRate = function() return STATE.slotRate end,
    rebirthStep = rebirthStep, reqText = reqText, platform = platform,
    sellThreshold = sellThreshold, placedRarities = placedRarities,
    rebirthPlan = rebirthPlan, huntRarities = huntRarities,
    skinPass = skinPass, rubyPass = rubyPass,
    SKIN_TIME = SKIN_TIME, skinEV = function() return SKIN_EV end,
    fmt = fmt, secs = secs, parsePrice = parsePrice, SUFFIX = SUFFIX,
    CASES = CASES, CASE_EV = CASE_EV, AVG_MPS = AVG_MPS, UNLOCK = UNLOCK,
    GUNS = GUNS, MUTS = MUTS, RARITY = RARITY, BLOCKED = BLOCKED,
}

pcall(function() win:Home() end)

print("[spingun] loaded - gen " .. GEN .. ", RightShift for the panel")
