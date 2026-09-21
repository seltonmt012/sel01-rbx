--[[
    animeboss.lua - "[TRADE] Beat the Anime Boss!"   place 129216769649527
    ------------------------------------------------------------------------
    Roll a boss onto your plot, beat it, it drops an anime unit into your
    chest, you take the good ones out of the chest and place them on a slot
    where they deal damage to the NEXT boss and pay money per second forever.
    Money buys seven stat upgrades and per-unit levels.

    Plain vanilla Roblox: 59 named remotes under ReplicatedStorage.Remotes,
    nothing blanked, every config require-able from the client.

    The loop, as measured through the bridge on 2026-09-21:

      collect money (Claimer touch)  ->  boss dead? roll a new one
        ->  AttackBoss("Click") at the server's own pace
        ->  score every unit in the chest, take the keepers out
        ->  place a keeper on a free slot, or swap out a weaker one
        ->  spend money: stat upgrades by payback, then unit levels

    Verified facts this script is built on (do not re-derive):

      * ATTACKBOSS IS SERVER-CAPPED AT ABOUT ONE HIT PER SECOND, and the
        game's own AutoClickerController already saturates it. Measured: 50
        FireServer calls paced at 10/s over 5.9s produced FIVE DamageEffects
        echoes, against FOUR in a 5s window where this script fired nothing
        at all. Clicking faster is pure waste - the packrng lesson in a new
        game. The script paces itself at 1/s and never bursts.
      * THE DAMAGE COMES FROM THE PLACED UNITS, not from the click. Each
        placed unit ticks its own server-side attack (PlaySpecialAttackEffect
        then a DamageEffects echo), which is why unit quality is the only
        real lever on kill speed and therefore on the whole economy.
      * A UNIT'S TRUE VALUE IS COMPUTABLE BEFORE YOU TOUCH IT, and this is
        the heart of the script. CharacterConfig.GetInfo(id) gives
        AttackDamage / MoneyPerSecond / Rarity for all 163 characters,
        MutationConfig.GetInfo(m).DamageBoost gives the mutation factor
        (Normal 1, Golden 1.2, Diamond 1.5, Super 2.5, Ultra 4, Omega 8) and
        PetLevelConfig.GetDamageMultiplier / GetMoneyMultiplier give the
        level curve (1.08 and 1.1 per level). The game's OWN functions are
        called rather than the formula rebuilt.
        Validated against the live billboard: Dragon Slayer (Natsu, Epic,
        AttackDamage 1897) at Lv.21 -> 1897 x 4.6610 x 2.22 damage stat =
        19,625, the slot read "19K DMG"; money 1327.9 x 6.7275 = 8,935, the
        slot read "8.9K$/s". Exact.
      * RARITY BEATS LEVEL, WHICH IS THE WHOLE POINT. Measured on the live
        plot: Dragon Slayer, Epic, LEVEL 1 = 4.2K DMG against Star Stand
        User, Rare, LEVEL 24 = 1.3K DMG. A fresh Epic is three times the
        level-24 Rare. Ranking on level, or on "it is upgraded so it must be
        better", throws the better unit away - the user flagged this before
        the numbers did.
      * THE CHEST HAS A HARD CAP OF 25 AND A FULL CHEST STOPS THE GAME. No
        new unit can drop while it is full, so beating bosses stops paying
        anything at all. Keeping headroom outranks keeping a marginal unit,
        which is why pruneChest() runs before placement and not after.
      * Money is collected by firetouchinterest on Plot.Claimer.Hitbox and it
        is NOT position gated - verified from 41 studs, Money 505K -> 1.9M in
        one touch with five slots' takings pending.
      * Placing needs the body. Equip the Tool, pin the root part on
        Slot.Holder for ~1.5s, then fireproximityprompt(Holder.SlotProximity)
        (10 studs, hold 0). Verified: a Dragon Slayer went into Slot6.
        Unlike the wings-style games THE PLOT DOES NOT RE-SORT on placement,
        so a slot index is a stable handle here.
      * A PLACED UNIT'S UID lives on the slot's visual model:
        Slot.SlotVisual_<CharacterId>:GetAttribute("UID").
      * UPGRADING A UNIT IS A UI CALL, NOT A REMOTE.
        Remotes.UpgradePet:FireServer(uid) is a DEAD END - fired against a
        real uid with the money in hand it moved nothing: no level, no
        charge, no error. The working path is the slot's own SurfaceGui
        button, and it answers on MouseButton1Click (2 connections), NOT on
        Activated (0 connections - the handler lives in an Actor VM).
        Verified: Lv.21 -> Lv.22, 19K -> 21K DMG, Money 1.6M -> 1.5M against
        an 81K price label.
      * Remotes.BuyUpgrade:FireServer("<StatKey>") takes one string out of
        StatsConfig.Order - Summoner, Luck, Damage, AutoRoll, Slots,
        RespawnDelay, WalkSpeed. Verified: Damage Lv.15 -> Lv.16, Money
        597K -> 505K against a 91K price label.
      * Codes go through Remotes.Communication:FireServer("RedeemCode", CODE)
        - read out of CodesFrame.Main.CodesController's upvalues, not
        guessed. CodeConfig carries 17 of them including three money codes
        worth 7M total. Verified end to end (every one came back
        CodeRedeemFailed on an account that had already redeemed them).
      * The boss is the child of Plot.BossSpawn carrying Health / MaxHealth
        ATTRIBUTES, which is the kill oracle. Its Humanoid reads inf/inf and
        is worthless.
      * Rolling is fireproximityprompt(Plot.BossRoller.Hitbox.RollPrompt),
        15 studs. The AutoRoll stat maxes at level 2 and then the game rolls
        by itself, so this is a fallback, not the main path.

    THE TRAP THAT WILL COST YOU AN HOUR IF YOU DO NOT READ IT:

      * `bridge.py spy` BREAKS THIS GAME. With the FireServer/__namecall hook
        installed the game's OWN calls stop arriving - rolling does nothing
        and the chest collects nothing, silently, while the client looks
        perfectly healthy. Measured 2026-09-21: the user reported "I cannot
        roll or collect any more", `spy off` fixed it immediately and nothing
        else was changed. Capture incoming traffic with a plain
        OnClientEvent connection instead; never leave the spy on in this game.

    Deliberately NOT automated, and why:

      * Everything Robux-priced: the Autoclicker gamepass (59), x2 Super Luck
        (99), x2 Damage, x2 Offline Rewards, the Starter Pack, the LIMITED
        product podiums and every RobuxBuyButton on the upgrade cards.
      * Trading. A trade remote exists; nothing in this script touches it.
      * FuseUnits / AwakenUnit / RerollMutation / PlaceArtifact / JoinRaid are
        mapped in the recon but unimplemented - they are left out rather than
        shipped half-measured. The Infinity Castle IS implemented (castleStep,
        CONFIG.autoCastle) and is the strongest feature here.
      * Selling is ON, but it can only ever reach a unit that has already lost
        the contest for every slot - the ranking runs first, the sale second.

    Panel: RightShift.  Console handle: _G.__ANIMEBOSS_DBG
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local plr = Players.LocalPlayer

-- Generation counter: every loop below exits the moment this stops matching,
-- which is what keeps a re-execute from stacking a second set of loops.
_G.__ANIMEBOSS = (_G.__ANIMEBOSS or 0) + 1
local GEN = _G.__ANIMEBOSS

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Config  = ReplicatedStorage:WaitForChild("Config")

-- --------------------------------------------------------------- game config
-- The game's own tables. Everything about a unit's worth comes out of these
-- three, so the script never carries a hand-written price or damage table.
local CharCfg, MutCfg, PetLvl, StatsCfg, SummonerCfg, ArtifactCfg
do
    local function grab(name)
        local ok, m = pcall(require, Config:WaitForChild(name))
        return ok and m or nil
    end
    CharCfg  = grab("CharacterConfig")
    MutCfg   = grab("MutationConfig")
    PetLvl   = grab("PetLevelConfig")
    StatsCfg = grab("StatsConfig")
    SummonerCfg = grab("SummonerLuckConfig")
    ArtifactCfg = grab("ArtifactConfig")
end

local CODES = {}
do
    local ok, cc = pcall(require, Config:FindFirstChild("CodeConfig"))
    if ok and type(cc) == "table" then
        for code in pairs(cc) do CODES[#CODES + 1] = code end
        table.sort(CODES)
    end
end

-- Rarity rank, lowest first. Used only for the display and for the "never
-- throw away anything at or above this tier" floor - the numeric score is
-- what actually decides every swap.
local RARITY_ORDER = {}
do
    if CharCfg and type(CharCfg.Rarities) == "table" then
        for i, name in pairs(CharCfg.Rarities) do
            if type(i) == "number" then RARITY_ORDER[name] = i end
        end
    end
end

local STAT_KEYS = { "Damage", "Luck", "Summoner", "RespawnDelay", "Slots", "WalkSpeed", "AutoRoll" }

-- THE SPEND PLAN, in value order, with a level cap per stat.
--
-- This is not a guess. SummonerLuckConfig was read out of the game: each
-- Summoner level moves the CENTRE of the roll distribution up one whole rarity
-- tier (GetCenterTierIndex(L) = L-1), while the Luck stat's entire 80-level
-- ladder costs 7.4e17 and buys 0.35*log2(4.95) = +0.81 tiers. Summoner levels
-- 1->9 buy +8 tiers for 3.33e15 - roughly 2,200x more tier per dollar. The
-- first build of this ranked Damage first and left Summoner sitting at level 3
-- for 7.7M with 600M in the bank, which is the single worst call it made.
--
-- Caps exist because these ladders stop being worth it long before they max:
-- RespawnDelay is 1.19e7 for levels 1-10 (3.00s -> 2.28s) and 8.65e12 for the
-- rest, and Luck is only worth its early levels.
-- `share` overrides the per-buy spend cap for that entry. THE TWO BEST BUYS IN
-- THE GAME ARE ALSO THE TWO MOST EXPENSIVE, so a flat "never spend more than
-- half the balance" silently refuses exactly them: Unit Slots sat at 2B with a
-- 2B balance and was skipped every single cycle while the money went into
-- things that did not matter. Slots is allowed the whole balance because each
-- level is another unit both EARNING and FIGHTING - it raises income and kill
-- speed at once, which nothing else here does.
-- Roll Speed (RespawnDelay) sits second because it is THROUGHPUT: every second
-- shaved off the roll is another boss, another drop and another chance at a
-- rarity. It was capped at level 10 here on the strength of "levels 1-10 are
-- cheap, the rest costs 8.65e12 in total" - but that total is the whole ladder
-- to level 26, and the level-10 price is 11M against a billion-plus balance.
-- The cap would have stopped it dead exactly where it still pays. The price
-- growth (x2.37 a level) plus the spend share ends it on its own, which is the
-- right way to stop buying something: when it gets too expensive, not at a
-- number written down in advance.
-- ORDER MATTERS MORE THAN ANY SINGLE ENTRY, because this list starves whatever
-- sits at the bottom. Luck was sixth, behind RespawnDelay and Damage, and with
-- 2B in hand the cheap entries took the money every single cycle while Luck at
-- 919M was never reached - the project's own starvation trap, again.
--
-- Slots first: each level is another unit both EARNING and FIGHTING, the only
-- upgrade that raises income and kill speed at once. Luck second: it feeds the
-- same roll term as Summoner and is affordable far more often. Summoner is the
-- better deal per dollar (one whole rarity tier a level, against +0.81 tiers
-- for the Luck stat's entire 80-level ladder) but its price runs away into the
-- billions, so it is third and gets bought whenever it comes back into reach.
local STAT_PLAN = {
    { key = "Slots",        cap = 99,  share = 1.00 },
    { key = "Luck",         cap = 80,  share = 1.00 },
    { key = "Summoner",     cap = 16,  share = 1.00 },
    { key = "RespawnDelay", cap = 26,  share = 0.60 },
    { key = "AutoRoll",     cap = 2,   share = 1.00 },
    { key = "Damage",       cap = 999 },
    { key = "WalkSpeed",    cap = 50 },
}

-- ------------------------------------------------------------- the oracle
-- DataSync carries the server's own view of the player - Money, Stats, Items,
-- Crystals, SavedCastleRun, SummonerSettings, PlayerStatistics - but it
-- arrives in PARTIAL payloads, so they are merged rather than replaced.
-- It also LAGS 30-60 seconds behind writes: a single stale read is not a
-- refusal, and treating it as one wasted a measurement round.
local DATA = {}
do
    if _G.__ANIMEBOSS_DSCONN then
        pcall(function() _G.__ANIMEBOSS_DSCONN:Disconnect() end)
    end
    local ds = Remotes:FindFirstChild("DataSync")
    if ds then
        _G.__ANIMEBOSS_DSCONN = ds.OnClientEvent:Connect(function(payload)
            if type(payload) == "table" then
                for k, v in pairs(payload) do DATA[k] = v end
            end
        end)
    end
    pcall(function()
        local rs = Remotes:FindFirstChild("RequestSync")
        if rs then rs:FireServer() end
    end)
end

-- ------------------------------------------------------------------- config
local CONFIG = {
    -- boss loop
    autoRoll        = true,   -- roll a new boss the moment the old one dies
    autoClick       = true,   -- AttackBoss at the server's pace, never faster
    autoMoney       = true,   -- touch the claimer

    -- units - the part that matters
    autoChest       = true,   -- take keepers out of the chest
    autoPlace       = true,   -- fill free slots
    autoSwap        = true,   -- replace a placed unit with a strictly better one
    chestKeepFree   = 6,      -- empty the chest once fewer than this many spaces are left
    protectRarity   = "None", -- optional floor: never SELL at or above this tier
    dmgWeight       = 0.5,    -- 0 = rank purely on $/s, 1 = purely on damage
    swapMargin      = 1.10,   -- a challenger must beat the weakest by this factor

    -- money
    autoStats       = true,   -- buy the seven stat upgrades
    autoLevel       = true,   -- level the placed units
    moneyReserve    = 0,      -- never spend below this
    maxStatSpend    = 0.5,    -- fraction of the balance a single stat buy may cost
    levelBudget     = 0.4,    -- share of the balance one levelling pass may spend
    statOrder       = "Value order",

    -- extras
    autoCodes       = false,  -- fires all 17 known codes once
    autoClaims      = true,   -- offline / time / daily / quest rewards
    autoSell        = true,   -- sells only what could not earn a slot
    autoCastle      = true,   -- the Infinity Castle room walk
    autoItems       = true,   -- drink the potions instead of hoarding them
    autoFilter      = true,   -- stop rolling rarities the plot has outgrown
    autoRaid        = true,   -- join a boss raid when one opens - the ONLY artifact source
    raidJoinWindow  = 10,     -- only walk to the portal inside this many seconds of the start
    autoArtifacts   = true,   -- keep the three best artifacts in the plot slots

    -- stuck bosses
    autoReroll      = true,   -- reroll a boss that would take all night
    bossMaxSeconds  = 120,    -- projected time to kill, above which it is rerolled
    bossMinAge      = 90,     -- and it must have stood there this long first
    rollAfterEmpty  = 10,     -- only roll a spawn the server has left empty this long
}

local STATE = {
    running    = true,
    mode       = "idle",
    uiOwner    = nil,
    note       = "loaded",
    lastError  = nil,
    rolled     = 0,
    kills      = 0,
    taken      = 0,
    placed     = 0,
    swapped    = 0,
    sold       = 0,
    statBuys   = 0,
    lvlBuys    = 0,
    collected  = 0,
    bossName   = "-",
    bossPct    = 0,
    lastTake   = "-",
    castleRoom = 0,
    rerolled   = 0,
    bossEta    = nil,
    bossDps    = 0,
}

local function note(s)
    STATE.note = tostring(s)
end

-- ------------------------------------------------------------------ helpers
local function char()      return plr.Character end
local function hrp()
    local c = char()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local c = char()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function alive()
    local h = humanoid()
    return h ~= nil and h.Health > 0
end

-- leaderstats.Money is an abbreviated STRING ("1.9M$"), so it is only ever
-- used for the panel. Every spending decision reads the price label the game
-- itself renders and compares like against like.
local function moneyText()
    local ls = plr:FindFirstChild("leaderstats")
    local m  = ls and ls:FindFirstChild("Money")
    return m and tostring(m.Value) or "?"
end

-- The game writes prices as "81K$", "7.7M$", "1.2B$". One parser, used for
-- every price in the script - a hand-written suffix table is the classic way
-- to be wrong by three orders of magnitude.
local SUFFIX = {
    [""] = 1, K = 1e3, M = 1e6, B = 1e9, T = 1e12,
    Qa = 1e15, Qi = 1e18, Sx = 1e21, Sp = 1e24, Oc = 1e27, No = 1e30, Dc = 1e33,
}
local function parseAmount(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[%$,%s]", "")
    local num, suf = s:match("^(%-?%d+%.?%d*)(%a*)$")
    if not num then return nil end
    local mul = SUFFIX[suf] or SUFFIX[suf and suf:sub(1, 1):upper() .. (suf:sub(2) or "")]
    if not mul then return nil end
    return tonumber(num) * mul
end

local function money()
    return parseAmount(moneyText()) or 0
end

-- --------------------------------------------------------------- the plot
-- Plots carry an OwnerPlayerId attribute. Picking "the nearest plot" is how
-- you end up automating a neighbour's base.
local function myPlot()
    local plots = workspace:FindFirstChild("Plots")
    if not plots then return nil end
    for _, p in ipairs(plots:GetChildren()) do
        if p:GetAttribute("OwnerPlayerId") == plr.UserId then return p end
    end
    return nil
end

-- THERE IS MORE THAN ONE BOSS, and the big one is not on the tier this script
-- originally looked at. The plot ships BossSpawn/BossRoller at ground level
-- and a SECOND pair under BaseLevel2 that unlocks with the Unit Slots ladder.
-- Measured while the first tier sat empty: BaseLevel2.BossSpawn held a
-- One-Eyed Ghoul at 33,154,359,795 of 69,447,240,174 HP, so `boss()` returned
-- nil, the reroll never had anything to act on, and the monster the user was
-- looking at simply stayed there. Every spawn folder under the plot is
-- scanned now, and each boss is rerolled at ITS OWN roller - the sibling of
-- the spawn it came from, never the ground-level one.
local function bossSpawns()
    local p = myPlot()
    local out = {}
    if not p then return out end
    for _, d in ipairs(p:GetDescendants()) do
        if d.Name == "BossSpawn" then out[#out + 1] = d end
    end
    return out
end

local function bosses()
    local out = {}
    for _, sp in ipairs(bossSpawns()) do
        local tier = sp.Parent
        local roller = tier and tier:FindFirstChild("BossRoller")
        for _, c in ipairs(sp:GetChildren()) do
            if c:GetAttribute("MaxHealth") then
                out[#out + 1] = {
                    model = c,
                    spawn = sp,
                    roller = roller,
                    -- THE MODEL ITSELF IS THE KEY, never its name. Keying the
                    -- tracker on name+MaxHealth collided across generations:
                    -- a boss dies, an identical one spawns a second later,
                    -- and it inherits the dead one's start time - so it was
                    -- instantly "90 seconds old" with a nonsense damage rate
                    -- and got rerolled on its first frame. That is where the
                    -- constant rerolling came from.
                    key = c,
                }
            end
        end
    end
    return out
end

local function boss()
    local list = bosses()
    return list[1] and list[1].model or nil
end

local function bossHealth()
    local b = boss()
    if not b then return nil, nil end
    return b:GetAttribute("Health") or 0, b:GetAttribute("MaxHealth") or 0
end

-- ------------------------------------------------------------------ scoring
-- The whole point of the script. A unit is worth what its BASE stats, its
-- MUTATION and its LEVEL say it is worth - never what its level alone says.
local function charInfo(id)
    if not CharCfg or not id then return nil end
    local ok, info = pcall(CharCfg.GetInfo, id)
    if ok and type(info) == "table" then return info end
    return nil
end

local function mutationBoost(m)
    if not MutCfg or not m then return 1 end
    local ok, info = pcall(MutCfg.GetInfo, m)
    if ok and type(info) == "table" and tonumber(info.DamageBoost) then
        return tonumber(info.DamageBoost)
    end
    return 1
end

local function levelMuls(level)
    level = tonumber(level) or 1
    local d, m = 1, 1
    if PetLvl then
        local ok1, v1 = pcall(PetLvl.GetDamageMultiplier, level)
        if ok1 and tonumber(v1) then d = tonumber(v1) end
        local ok2, v2 = pcall(PetLvl.GetMoneyMultiplier, level)
        if ok2 and tonumber(v2) then m = tonumber(v2) end
    end
    return d, m
end

-- Returns damage, money-per-second and the blended score. The mutation boost
-- is a DAMAGE boost in this game's config - it is deliberately not applied to
-- the money term, because the config does not.
local function unitStats(charId, mutation, level)
    local info = charInfo(charId)
    if not info then return 0, 0, 0, nil end
    local dMul, mMul = levelMuls(level)
    local dmg   = (tonumber(info.AttackDamage) or 0) * mutationBoost(mutation) * dMul
    local cash  = (tonumber(info.MoneyPerSecond) or 0) * mMul
    local w     = math.clamp(tonumber(CONFIG.dmgWeight) or 0.5, 0, 1)
    -- Damage and money run near-proportional across the whole character table
    -- (roughly 1.4-1.8x), so this blend is stable whatever the weight is set
    -- to - which is exactly the robustness wanted from a ranking function.
    local score = dmg * w + cash * (1 - w)
    return dmg, cash, score, info
end

local function rarityRank(id)
    local info = charInfo(id)
    return info and (RARITY_ORDER[info.Rarity] or 0) or 0
end

-- "None" means no tier floor at all, which is the default: a unit that could
-- not earn one of the six slots has no other use, whatever its rarity says.
local function protectedTier()
    if CONFIG.protectRarity == "None" or CONFIG.protectRarity == nil then
        return math.huge
    end
    return RARITY_ORDER[CONFIG.protectRarity] or math.huge
end

-- --------------------------------------------------------------- the slots
-- A placed unit is read off its own visual model (the UID) plus the
-- billboard the game renders (name, rarity, mutation, level).
-- Slots grow with the game. The plot ships Slots.Slot1..6 and a SECOND TIER
-- under BaseLevel2.Slots.Slot7..12 that is built but locked, and the "Unit
-- Slots" upgrade (Lv.3 = 6 slots, 10M for the next) unlocks them one at a
-- time. So every slot folder on the plot is collected, ordered by the number
-- in the slot's name, and the unlocked COUNT is read from the upgrade card
-- itself - which means a slot bought later is picked up with no code change.
local function slotFolders()
    local p = myPlot()
    local out = {}
    if not p then return out end
    for _, d in ipairs(p:GetDescendants()) do
        if d.Name == "Slots" and d:IsA("Folder") then out[#out + 1] = d end
    end
    return out
end

-- "Lv.3 - 6 slots" -> 6. Falls back to counting what exists rather than
-- guessing a number, so a UI change degrades into "use them all" instead of
-- into "use none".
local function unlockedSlotCount()
    local gui = plr:FindFirstChild("PlayerGui")
    local main = gui and gui:FindFirstChild("Main")
    local uf = main and main:FindFirstChild("UpgradesFrame")
    local sf = uf and uf:FindFirstChild("Main") and uf.Main:FindFirstChild("ScrollingFrame")
    local card = sf and sf:FindFirstChild("SlotsCard")
    local val = card and card:FindFirstChild("Value")
    if val then
        local n = tostring(val.Text):match("(%d+)%s*slots?")
        if tonumber(n) then return tonumber(n) end
    end
    return nil
end

local function readSlot(slot)
    local entry = { slot = slot, name = slot.Name }
    for _, c in ipairs(slot:GetChildren()) do
        local id = c.Name:match("^SlotVisual_(.+)$")
        if id then
            entry.charId = id
            entry.uid    = c:GetAttribute("UID")
        end
    end
    for _, d in ipairs(slot:GetDescendants()) do
        local n = d.Name
        if n == "LevelLabel" then
            entry.level = tonumber(tostring(d.Text):match("(%d+)")) or 1
        elseif n == "MutationLabel" then
            entry.mutation = d.Text
        elseif n == "RarityLabel" then
            entry.rarity = d.Text
        elseif n == "BossName" then
            entry.display = d.Text
        elseif n == "UpgradeCost" then
            entry.upgradeCost = parseAmount(d.Text)
            entry.upgradeText = d.Text
        elseif n == "MainButton" then
            entry.button = d
        end
    end
    entry.occupied = entry.charId ~= nil
    if entry.occupied then
        entry.dmg, entry.cash, entry.score = unitStats(entry.charId, entry.mutation, entry.level)
    else
        entry.dmg, entry.cash, entry.score = 0, 0, 0
    end
    return entry
end

local function slots()
    local raw = {}
    for _, f in ipairs(slotFolders()) do
        for _, s in ipairs(f:GetChildren()) do
            if s:FindFirstChild("Holder") then
                raw[#raw + 1] = { inst = s, index = tonumber(s.Name:match("(%d+)")) or 99 }
            end
        end
    end
    -- Slot7 must sort after Slot6, so order on the NUMBER and never on the
    -- name - "Slot10" sorts before "Slot2" as a string.
    table.sort(raw, function(a, b) return a.index < b.index end)

    local limit = unlockedSlotCount() or #raw
    local out = {}
    for i, r in ipairs(raw) do
        if i > limit then break end
        local e = readSlot(r.inst)
        e.index = r.index
        out[#out + 1] = e
    end
    return out
end

local function freeSlot()
    for _, s in ipairs(slots()) do
        if not s.occupied then return s end
    end
    return nil
end

-- COMPARE AT THE SAME LEVEL, NOT AT THE CURRENT ONE.
--
-- A placed unit levelled 50 times out-scores a freshly dropped one of a far
-- better rarity, so comparing "as they stand" refuses every upgrade: measured
-- with a level 50 Demon Progenitor at 5.82e14 holding the weakest slot while
-- five MAGIC units sat in the chest at 1.08-1.73e14, all rejected - even
-- though a Magic at that same level is about 1.45e16, twenty times better.
-- The same mistake made the rarity filter switch off Fighter while the plot
-- was still full of the weaker Evil tier.
--
-- Levels are cheap and get rebought in seconds (541 in a single pass here),
-- while a rarity gap is permanent. RARITY IS THE PRIORITY; the level a unit
-- happens to be sitting at must not decide anything.
--
-- The reference is the HIGHEST level on the plot, computed from levels ALONE.
-- Deriving it from "the weakest unit" would be circular, because the weakest
-- unit is itself decided by a score taken at the reference level.
local function refLevel()
    local best = 1
    for _, s in ipairs(slots()) do
        if s.occupied then
            local lv = tonumber(s.level) or 1
            if lv > best then best = lv end
        end
    end
    return best
end

local function scoreAtLevel(charId, mutation, level)
    local _, _, s = unitStats(charId, mutation, level)
    return s or 0
end

-- What a candidate is worth once it has caught up with the plot. A unit
-- already past that level keeps its own, so nothing is ever undervalued.
local function refScoreOf(e)
    if not e or not e.charId then return 0 end
    return scoreAtLevel(e.charId, e.mutation, math.max(tonumber(e.level) or 1, refLevel()))
end

-- BOTH SIDES ARE VALUED THE SAME WAY OR THE FARM EATS ITSELF.
-- This used to rank the placed units by their CURRENT score while candidates
-- were valued at the plot's level. The moment a Magic was swapped in at level
-- 1 it became "the weakest slot" by its own low current score, so the next
-- pass ripped it straight back out for the next candidate - remove Evil, place
-- Magic, remove Magic, place Magic, forever. Same level on both sides, always.
local function weakestPlaced()
    local ref = refLevel()
    local worst
    for _, s in ipairs(slots()) do
        if s.occupied and s.charId then
            local sc = scoreAtLevel(s.charId, s.mutation,
                                    math.max(tonumber(s.level) or 1, ref))
            if not worst or sc < worst.refScore then
                worst = s
                worst.refScore = sc
            end
        end
    end
    return worst
end

local function totalIncome()
    local dmg, cash = 0, 0
    for _, s in ipairs(slots()) do
        dmg  = dmg + (s.dmg or 0)
        cash = cash + (s.cash or 0)
    end
    return dmg, cash
end

-- --------------------------------------------------------------- the chest
-- The chest UI names every entry Unit_<uid> and renders the display name,
-- the rarity and the mutation, so the whole chest is readable without firing
-- anything. The character ID has to be recovered from the display name,
-- because that is all the UI carries.
local DISPLAY_TO_ID = {}
do
    if CharCfg and type(CharCfg.Characters) == "table" then
        for id, info in pairs(CharCfg.Characters) do
            if type(info) == "table" and info.DisplayName then
                DISPLAY_TO_ID[info.DisplayName] = id
            end
        end
    end
end

local function chestFrame()
    local gui = plr:FindFirstChild("PlayerGui")
    local main = gui and gui:FindFirstChild("Main")
    local cf = main and main:FindFirstChild("ChestFrame")
    return cf and cf:FindFirstChild("Main") or nil
end

-- "4 / 25" -> 4, 25
local function chestCount()
    local m = chestFrame()
    local lbl = m and m:FindFirstChild("LimitFrame") and m.LimitFrame:FindFirstChild("PlayerName")
    if not lbl then return 0, 25 end
    local a, b = tostring(lbl.Text):match("(%d+)%s*/%s*(%d+)")
    return tonumber(a) or 0, tonumber(b) or 25
end

local function chestEntries()
    local m = chestFrame()
    local out = {}
    local sf = m and m:FindFirstChild("ScrollingFrame")
    if not sf then return out end
    for _, c in ipairs(sf:GetChildren()) do
        local uid = c.Name:match("^Unit_(.+)$")
        if uid then
            local nm = c:FindFirstChild("PlayerName")
            local ra = c:FindFirstChild("Rarity")
            local mu = c:FindFirstChild("Mutation")
            local display  = nm and nm.Text or "?"
            local charId   = DISPLAY_TO_ID[display]
            local mutation = mu and mu.Text or "Normal"
            -- Chest units are fresh drops, so level 1 unless the cache knows
            -- better. Guessing high here would make junk outrank the plot.
            local level = 1
            local cache = ReplicatedStorage:FindFirstChild("Modules")
            cache = cache and cache:FindFirstChild("Client")
            cache = cache and cache:FindFirstChild("OwnedPetsCache")
            if cache then
                local ok, mod = pcall(require, cache)
                if ok and mod and mod.GetLevel then
                    local ok2, lv = pcall(mod.GetLevel, uid)
                    if ok2 and tonumber(lv) then level = tonumber(lv) end
                end
            end
            local dmg, cash, score = unitStats(charId, mutation, level)
            out[#out + 1] = {
                uid = uid, display = display, charId = charId,
                rarity = ra and ra.Text or "?", mutation = mutation, level = level,
                dmg = dmg, cash = cash, score = score,
                locked = c:FindFirstChild("LockedFrame") and c.LockedFrame.Visible or false,
            }
        end
    end
    -- Ranked on what each is worth once levelled to the plot's level, not on
    -- the number it shows while still at level 1.
    table.sort(out, function(a, b) return refScoreOf(a) > refScoreOf(b) end)
    return out
end

-- ----------------------------------------------------------------- raids
-- A BOSS RAID AND THE BASE FARM CANNOT BOTH HAVE THE BODY. While a raid runs
-- the player is in the raid UI placing raid units, and the base loop was
-- happily warping the character onto the boss roller and pinning it on plot
-- slots underneath it - the user hit this at wave 51 of 70 and it read as the
-- script being "buggy", which it was.
--
-- The raid runs in the SAME place (PlaceId never changes, the arena is
-- workspace.RaidArena with its own BossSlot/Slots/Portal/KillBossPrompt), so
-- there is no teleport to follow and no second hub entry needed. The detector
-- is simply the raid UI being up.
local function raidActive()
    local gui = plr:FindFirstChild("PlayerGui")
    local main = gui and gui:FindFirstChild("Main")
    local f = main and main:FindFirstChild("BossRaidFrame")
    if not f then return false end
    local ok, vis = pcall(function() return f.Visible end)
    return ok and vis == true
end

-- --------------------------------------------------------------- UI mutex
-- One routine owns the character at a time. Placing pins the root part, and a
-- second routine pinning it somewhere else mid-placement loses the unit.
local function withUI(name, fn)
    if STATE.uiOwner then return false, "busy: " .. tostring(STATE.uiOwner) end
    STATE.uiOwner = name
    local ok, err = pcall(fn)
    STATE.uiOwner = nil
    if not ok then
        STATE.lastError = tostring(err)
        note(name .. " failed: " .. tostring(err))
    end
    return ok, err
end

local function pinAt(position, seconds, until_)
    local root = hrp()
    if not root then return false end
    local origin = root.CFrame
    local conn = RunService.Heartbeat:Connect(function()
        if root and root.Parent then
            root.CFrame = CFrame.new(position)
            root.AssemblyLinearVelocity = Vector3.zero
        end
    end)
    local t = 0
    while t < seconds do
        if until_ and until_() then break end
        task.wait(0.1)
        t = t + 0.1
    end
    conn:Disconnect()
    return origin
end

-- ------------------------------------------------------------- boss actions
-- THE ROLL PROMPT IS 15 STUDS AND THE BODY IS USUALLY NOWHERE NEAR IT.
-- Measured mid-run: the character sat 262 studs from its own BossRoller while
-- the reroll fired into empty air, over and over, and the boss simply stayed.
-- The prompt reads Enabled = true from any distance, so nothing about the
-- prompt says it is out of reach - it just silently does nothing. Every roll
-- therefore pins the root part on the roller first, exactly like placing does.
-- THE PROMPT HAS A 0.5s HOLD, AND fireproximityprompt WITHOUT IT DOES NOTHING.
-- Standing on the roller is not the same as pressing the key: the hold has to
-- be handed over, or the prompt is "triggered" and the server never sees a
-- roll. This is what kept the stuck boss alive through every earlier attempt.
local function fireRollPrompt(roller)
    local p = myPlot()
    roller = roller or (p and p:FindFirstChild("BossRoller"))
    local hitbox = roller and roller:FindFirstChild("Hitbox")
    local prompt = hitbox and hitbox:FindFirstChild("RollPrompt")
    local root = hrp()
    if not prompt or not root then return false end

    local hold = prompt.HoldDuration or 0
    local function press()
        -- Pass the hold duration; fall back to the bare call on executors whose
        -- fireproximityprompt only takes one argument.
        if not pcall(function() fireproximityprompt(prompt, hold) end) then
            pcall(function() fireproximityprompt(prompt) end)
        end
    end

    if (root.Position - hitbox.Position).Magnitude > 12 then
        local origin = pinAt(hitbox.Position + Vector3.new(0, 4, 0), 1.2)
        press()
        task.wait(hold + 0.6)
        if origin then pcall(function() root.CFrame = origin end) end
    else
        press()
        task.wait(hold + 0.6)
    end
    return true
end

-- THE SERVER ROLLS BY ITSELF and the script must not fight it for the body.
-- AutoRoll maxes at level 2 and then the server refills an empty spawn on its
-- own in about 3.5s (measured inter-roll gaps 3.48-3.78s). Rolling on every
-- empty spawn meant warping onto the roller within half a second of every
-- single kill and standing there - which is what the user saw, and it stole
-- the body from placing, swapping and selling for no gain at all.
--
-- So a spawn has to have been empty for a WHILE before the script touches it.
-- Below that it is simply the server taking its normal turn.
local _emptySince = {}

local function tierEmptyFor(sp)
    local occupied = false
    for _, c in ipairs(sp:GetChildren()) do
        if c:GetAttribute("MaxHealth") then occupied = true end
    end
    local key = sp:GetFullName()
    if occupied then
        _emptySince[key] = nil
        return nil
    end
    if not _emptySince[key] then
        _emptySince[key] = os.clock()
        return 0
    end
    return os.clock() - _emptySince[key]
end

-- Roll at EVERY tier that is standing empty, not just the first. With two
-- tiers a single roll left the other one idle, which is a whole boss ladder
-- producing nothing.
local function rollBoss()
    local rolled = false
    for _, sp in ipairs(bossSpawns()) do
        local empty = tierEmptyFor(sp)
        if empty and empty >= (tonumber(CONFIG.rollAfterEmpty) or 10) then
            _emptySince[sp:GetFullName()] = os.clock()
            local tier = sp.Parent
            local roller = tier and tier:FindFirstChild("BossRoller")
            if roller then
                withUI("roll", function() fireRollPrompt(roller) end)
                task.wait(0.4)
                for _, c in ipairs(sp:GetChildren()) do
                    if c:GetAttribute("MaxHealth") then
                        rolled = true
                        STATE.rolled = STATE.rolled + 1
                        STATE.bossName = c.Name
                        note("rolled " .. c.Name)
                    end
                end
            end
        end
    end
    return rolled
end

-- Paced at the measured server cap. Firing this in a burst is measurably
-- worthless and this is the one place it would be tempting.
-- "Punch" is the real client action (ClickAttackController); "Click" is what
-- the game's own AutoClickerController sends. MEASURED, one fire every 2.5s so
-- nothing was eaten by the cooldown: "Punch" landed 2,804,097 and 2,830,313
-- damage, while "Critical", "Special", "Ability" and "Ultimate" all landed
-- 1,402,048-1,415,156 - exactly half. The server accepts any string and echoes
-- it back at the 1x rate, so there is no hidden crit variant and "Punch" is
-- simply the ceiling, worth double for the same call.
local function clickBoss()
    if not boss() then return false end
    pcall(function() Remotes.AttackBoss:FireServer("Punch") end)
    return true
end

local function collectMoney()
    local p = myPlot()
    local claimer = p and p:FindFirstChild("Claimer")
    local hitbox = claimer and claimer:FindFirstChild("Hitbox")
    local root = hrp()
    if not hitbox or not root then return false end
    pcall(function()
        firetouchinterest(root, hitbox, 0)
        task.wait(0.12)
        firetouchinterest(root, hitbox, 1)
    end)
    STATE.collected = STATE.collected + 1
    return true
end

-- ------------------------------------------------------------ chest actions
local function takeFromChest(uid)
    pcall(function() Remotes.CollectChestPet:FireServer(uid) end)
    task.wait(0.35)
end

local function dropFromChest(uid)
    pcall(function() Remotes.DeleteChestPet:FireServer(uid) end)
    task.wait(0.25)
end

-- Headroom outranks a marginal unit: a FULL CHEST BLOCKS EVERY NEW DROP, so
-- beating bosses stops paying anything at all.
--
-- The first version of this deleted the surplus and filtered it by a rarity
-- guard, and that JAMMED THE GAME SOLID: the chest filled with 25 Epics and
-- Legendaries, every one of them above the guard, so nothing was droppable and
-- "Your chest is full!" spammed the screen while drops were being thrown away.
-- Nothing is deleted any more. Everything comes OUT into the backpack, the
-- good ones earn a slot and the rest are SOLD, which is both safe and paid.
local function drainChest()
    local used, cap = chestCount()
    if used == 0 then return 0 end

    local keepFree = tonumber(CONFIG.chestKeepFree) or 6
    if (cap - used) >= keepFree then
        -- Still roomy: only pull what is actually wanted, so the chest stays a
        -- useful buffer rather than a second inventory.
        local worst = weakestPlaced()
        local floor = worst and worst.refScore or 0
        local free  = freeSlot()
        local n = 0
        for _, e in ipairs(chestEntries()) do
            if e.charId and (free ~= nil or refScoreOf(e) > floor) then
                takeFromChest(e.uid)
                n = n + 1
                STATE.taken = STATE.taken + 1
                STATE.lastTake = e.display
                free = freeSlot()
            end
        end
        return n
    end

    -- Filling up: empty it. Two passes, because one call does not always take
    -- the whole chest.
    pcall(function() Remotes.CollectAllChestPets:FireServer() end)
    task.wait(1.0)
    pcall(function() Remotes.CollectAllChestPets:FireServer() end)
    task.wait(1.0)
    local after = select(1, chestCount())
    local moved = math.max(0, used - after)
    STATE.taken = STATE.taken + moved
    if moved > 0 then note(("emptied the chest, %d units out"):format(moved)) end
    return moved
end

-- ------------------------------------------------------------ placing units
local function backpackTools()
    local out = {}
    local bp = plr:FindFirstChild("Backpack")
    if not bp then return out end
    for _, t in ipairs(bp:GetChildren()) do
        if t:IsA("Tool") then
            local id  = t:GetAttribute("CharacterId")
            local mut = t:GetAttribute("MutationId") or "Normal"
            local lvl = t:GetAttribute("Level") or 1
            local dmg, cash, score = unitStats(id, mut, lvl)
            out[#out + 1] = {
                tool = t, charId = id, mutation = mut, level = lvl,
                uid = t:GetAttribute("UID"),
                dmg = dmg, cash = cash, score = score,
            }
        end
    end
    table.sort(out, function(a, b) return refScoreOf(a) > refScoreOf(b) end)
    return out
end

-- Equip, pin on the holder, fire once. The prompt is 10 studs and the server
-- validates against its own copy of the position, so the pin is not optional.
local function placeOn(slotEntry, toolEntry)
    local hum = humanoid()
    local holder = slotEntry.slot:FindFirstChild("Holder")
    local prompt = holder and holder:FindFirstChild("SlotProximity")
    if not hum or not prompt or not toolEntry.tool then return false end

    hum:EquipTool(toolEntry.tool)
    task.wait(0.4)

    local origin = pinAt(holder.Position + Vector3.new(0, 4, 0), 1.5)
    pcall(fireproximityprompt, prompt)
    task.wait(1.2)
    if origin then
        local root = hrp()
        if root then pcall(function() root.CFrame = origin end) end
    end
    task.wait(0.3)

    local after = readSlot(slotEntry.slot)
    return after.occupied and after.charId == toolEntry.charId
end

-- Taking a placed unit off: the same prompt, which reads "Remove" when the
-- slot is occupied. It comes back as a Backpack Tool.
local function removeFrom(slotEntry)
    local holder = slotEntry.slot:FindFirstChild("Holder")
    local prompt = holder and holder:FindFirstChild("SlotProximity")
    if not prompt then return false end
    local origin = pinAt(holder.Position + Vector3.new(0, 4, 0), 1.2)
    pcall(fireproximityprompt, prompt)
    task.wait(1.0)
    if origin then
        local root = hrp()
        if root then pcall(function() root.CFrame = origin end) end
    end
    return not readSlot(slotEntry.slot).occupied
end

-- Selling. Equip the Tool, fire, it is gone - measured NOT position gated, so
-- there is no walk to the Sell NPC in the loop (the NPC prompt at
-- Workspace.Center.SellShop.Rig is the manual path and is not needed).
local function sellTool(entry)
    local hum = humanoid()
    if not hum or not entry.tool or not entry.tool.Parent then return false end
    hum:EquipTool(entry.tool)
    task.wait(0.35)
    pcall(function() Remotes.SellHeldPet:FireServer() end)
    task.wait(0.45)
    return entry.tool.Parent == nil
end

-- Fill every free slot, then keep swapping for as long as something in hand
-- beats the weakest unit on the plot.
--
-- THE LOOP IS THE FIX: the first version did exactly ONE swap per cycle, so
-- with two Legendaries in the backpack and two Epics on the plot only one of
-- them ever went in and the other sat there. The user spotted that before the
-- counters did.
local function placeAndSwap()
    if CONFIG.autoPlace then
        local guard, busyTries = 0, 0
        while guard < 12 do
            guard = guard + 1
            local slot = freeSlot()
            if not slot then break end
            local best = backpackTools()[1]
            if not best or not best.charId then break end
            -- A busy mutex is not a failure, it is a "try again in a moment",
            -- and treating the two the same made one contended cycle abandon
            -- every remaining slot. Retries are counted separately from the
            -- guard so a permanently held lock cannot spin here.
            local ok = false
            local got = withUI("place", function() ok = placeOn(slot, best) end)
            if not got then
                busyTries = busyTries + 1
                if busyTries > 3 then break end
                task.wait(1.0)
            elseif not ok then
                break
            end
            STATE.placed = STATE.placed + 1
            note("placed " .. tostring(best.charId))
        end
    end

    if CONFIG.autoSwap then
        local margin = tonumber(CONFIG.swapMargin) or 1.1
        local guard = 0
        while guard < 10 do
            guard = guard + 1
            local best  = backpackTools()[1]
            local worst = weakestPlaced()
            if not (best and worst and best.charId) then break end
            -- The challenger is valued at the level the plot runs at, so a
            -- better rarity is not refused just because it dropped at level 1.
            -- RANK FIRST: a higher rarity never gives way to a lower one,
            -- whatever the numbers say. This is a hard floor on top of the
            -- score, so no combination of level and mutation can talk the
            -- farm into downgrading a tier.
            if rarityRank(best.charId) < rarityRank(worst.charId) then break end
            if refScoreOf(best) <= worst.refScore * margin then break end
            local done = false
            withUI("swap", function()
                if removeFrom(worst) then
                    local slot = freeSlot()
                    if slot and placeOn(slot, best) then done = true end
                end
            end)
            if not done then break end
            STATE.swapped = STATE.swapped + 1
            note(("swapped in %s over %s"):format(
                tostring(best.charId), tostring(worst.charId)))
        end
    end
end

-- Anything STILL in the backpack once every slot has been filled and every
-- worthwhile swap has been made is, by definition, not good enough for the
-- plot. That is what makes selling it safe, and it needs no rarity filter -
-- a rarity filter is precisely what jammed the chest at 25/25.
local function sellSpares()
    if not CONFIG.autoSell then return 0 end
    local worst = weakestPlaced()
    if not worst then return 0 end
    local guard = protectedTier()
    local sold = 0
    local tools = backpackTools()
    for i = #tools, 1, -1 do
        local t = tools[i]
        local keepTier = t.charId and rarityRank(t.charId) >= guard
        if t.charId and not keepTier and refScoreOf(t) < worst.refScore then
            if sellTool(t) then
                sold = sold + 1
                STATE.sold = STATE.sold + 1
            end
            if sold >= 20 then break end
        end
    end
    if sold > 0 then note(("sold %d spare units"):format(sold)) end
    return sold
end

-- ------------------------------------------------------- raids, artifacts
-- ARTIFACTS COME FROM RAIDS AND FROM NOWHERE ELSE. Proven on this account:
-- after 711 bosses defeated and 704 Infinity Castle rooms, OwnedArtifacts was
-- EMPTY; one raid joined at wave 1 and dead at wave 32 produced NINE, with
-- zero raid units placed. Being in the raid is the whole requirement - the
-- drop is rolled per wave, per player, and the other players carry the waves.
-- They are not in the castle table, not in the crate table, not in quest
-- rewards, and not tradeable.
--
-- Joining is a WORLD PROMPT, not a remote: JoinRaid:FireServer() was fired
-- mid-raid and again at the second a raid opened, and answered nothing both
-- times. The prompt is workspace.Center.BossRaids.Portal.Target.JoinPrompt.
--
-- !! THE SAME PROMPT IS ALSO A ROBUX BUTTON !!
-- Between raids its ActionText reads "Start Raid NOW - 49" and firing it opens
-- a 49 Robux purchase. So it is fired only when ALL of these hold: the portal
-- timer reads "NOW", the action text says "join", and it does NOT look like
-- the paid starter. When in doubt this does nothing at all - a missed raid
-- costs 35 minutes, a mis-fire costs the user's money.
local function raidPortalTarget()
    local c = workspace:FindFirstChild("Center")
    local br = c and c:FindFirstChild("BossRaids")
    local p = br and br:FindFirstChild("Portal")
    return p and p:FindFirstChild("Target")
end

local function raidTimerText()
    local t = raidPortalTarget()
    local bill = t and t:FindFirstChild("TimerBill")
    local lbl = bill and bill:FindFirstChild("TimerLabel")
    return lbl and tostring(lbl.Text) or ""
end

-- The portal billboard is the schedule oracle: it counts down, then reads
-- "NOW!" for the whole length of the raid, so a late join still works (one was
-- joined at wave 51 of 70). It restarts at about 24:00 the moment a raid ends.
local function raidOpen()
    return raidTimerText():upper():find("NOW") ~= nil
end

-- Seconds until the next raid, read off the portal billboard. "NOW!" means a
-- raid is running (late joining works), a "MM:SS" countdown means it is not.
-- nil means the label could not be read and nothing should be done.
local function raidSecondsLeft()
    local txt = raidTimerText()
    if txt:upper():find("NOW") then return 0 end
    local m, s = txt:match("(%d+)%s*:%s*(%d+)")
    if m and s then return tonumber(m) * 60 + tonumber(s) end
    return nil
end

local function joinRaid()
    if raidActive() then return false end

    -- THE COUNTDOWN DECIDES WHEN, NOT THE PROMPT TEXT. The prompt reads
    -- "Join Raid" all the time, including the twenty-odd minutes between
    -- raids, so keying on it alone sent the character walking to the portal
    -- every cycle for nothing. Reading the label is free; only the last few
    -- seconds before the start - or a raid already running - are worth moving
    -- for.
    local secs = raidSecondsLeft()
    if not secs or secs > (tonumber(CONFIG.raidJoinWindow) or 10) then return false end

    local t = raidPortalTarget()
    local prompt = t and t:FindFirstChild("JoinPrompt")
    if not prompt or not prompt.Enabled then return false end

    -- THE ACTION TEXT IS THE SIGNAL, not the countdown. The prompt itself
    -- switches between the free "Join Raid" and the paid "Start Raid NOW - 49",
    -- so it already says which one it is. Requiring the timer to read "NOW" as
    -- well was too strict and missed a real raid: the text read "Join Raid",
    -- the prompt was enabled, and the script sat it out.
    local action = tostring(prompt.ActionText)
    local low = action:lower()
    -- Refuse anything that smells of the paid starter: the wording, the word
    -- Robux, or a trailing price.
    if low:find("start raid") or low:find("robux") or action:match("%-%s*%d+%s*$") then
        return false
    end
    if not low:find("join") then return false end

    local root = hrp()
    if not root then return false end
    local origin
    withUI("raid", function()
        origin = pinAt(t.Position + Vector3.new(0, 4, 0), 1.2)
        if not pcall(function() fireproximityprompt(prompt, 0) end) then
            pcall(function() fireproximityprompt(prompt) end)
        end
        task.wait(1.2)
        if origin then pcall(function() root.CFrame = origin end) end
    end)

    task.wait(1.5)
    if raidActive() then
        STATE.raids = (STATE.raids or 0) + 1
        note("joined a boss raid")
        return true
    end
    return false
end

-- Three artifact slots, each a flat multiplier on Damage, Money or Luck.
-- Placing is a plain remote and is NOT position gated - fired from 52 studs it
-- still set Holder.PlacedArtifactId and OwnedArtifacts[..].PlacedSlot. The
-- ArtifactPrompt on the plot is only a UI opener and is never needed.
local function artifactInfo(id)
    if not ArtifactCfg or not id then return nil end
    local ok, info = pcall(ArtifactCfg.GetInfo, id)
    if ok and type(info) == "table" then return info end
    local a = ArtifactCfg.Artifacts
    return (type(a) == "table" and a[id]) or nil
end

local function placeArtifacts()
    local owned = DATA.OwnedArtifacts
    if type(owned) ~= "table" then
        pcall(function() Remotes.RequestSync:FireServer() end)
        return false
    end

    local list = {}
    for _, a in pairs(owned) do
        if type(a) == "table" and a.ArtifactId and a.UID then
            local info = artifactInfo(a.ArtifactId)
            list[#list + 1] = {
                uid = a.UID, id = a.ArtifactId,
                mult = (info and tonumber(info.Multiplier)) or 0,
                effect = (info and info.EffectType) or "?",
                slot = tonumber(a.PlacedSlot),
            }
        end
    end
    if #list == 0 then return false end
    table.sort(list, function(x, y) return x.mult > y.mult end)

    -- Best three by multiplier, never the same artifact twice - a duplicate id
    -- is not known to stack and would waste a slot on a certainty of nothing.
    local want, seen = {}, {}
    for _, a in ipairs(list) do
        if not seen[a.id] and #want < 3 then
            seen[a.id] = true
            want[#want + 1] = a
        end
    end

    local placed = 0
    for i, a in ipairs(want) do
        if a.slot ~= i then
            pcall(function() Remotes.PlaceArtifact:FireServer(a.uid, i) end)
            task.wait(0.5)
            placed = placed + 1
            note(("placed artifact %s (x%s %s)"):format(a.id, tostring(a.mult), a.effect))
        end
    end
    if placed > 0 then
        pcall(function() Remotes.RequestSync:FireServer() end)
        STATE.artifacts = (STATE.artifacts or 0) + placed
    end
    return placed > 0
end

-- ------------------------------------------------- summoner roll filter
-- Stop useless rarities at the SOURCE instead of shovelling them out of the
-- chest afterwards. The Summoner Settings panel carries an AutoDelete flag per
-- rarity, and the call shape had to be read out of the decompiled
-- SummonerSettingsController because it takes a FLOOR as well:
--
--     SetAutoDelete:FireServer(<floor>, <rarityName>, <boolean>)
--
-- Firing it with just (rarity, true) - the obvious two-argument guess - does
-- nothing at all and reports nothing, which is what made this look impossible
-- earlier. Verified end to end: AutoDeleteRarities came back from the server
-- with Uncommon = true after one call.
--
-- The rule: a rarity is switched off once even its STRONGEST member, rolled
-- with the BEST mutation in the game, could not beat the weakest unit already
-- on the plot. That is deliberately the most generous case for the rarity, so
-- nothing that could ever be useful is thrown away. It only ever switches
-- filters ON - a rarity the player turned off by hand is never turned back on
-- underneath them.
-- The ceiling is taken at the level the PLOT runs at, not at level 1. Judging
-- a rarity by a level-1 drop is what made this switch off Fighter while the
-- plot was still full of the weaker Evil tier: a fresh Fighter scored below a
-- level-50 Evil, even though the Fighter passes it within a few levels.
local function rarityCeiling(rarity, level)
    if not CharCfg or type(CharCfg.Characters) ~= "table" then return 0 end
    level = level or 1
    local best = 0
    for id, info in pairs(CharCfg.Characters) do
        if type(info) == "table" and info.Rarity == rarity
           and (tonumber(info.RollWeight) or 0) > 0 then
            local _, _, score = unitStats(id, "Omega", level)
            if score > best then best = score end
        end
    end
    return best
end

local function syncSummonerSettings()
    if raidActive() then return false end
    local worst = weakestPlaced()
    -- A free slot means ANY drop is still worth having, so the filter only
    -- starts once the plot is full and has something real on it.
    if not worst or (worst.refScore or 0) <= 0 or freeSlot() then return false end
    if not SummonerCfg or type(SummonerCfg.RarityTierIndex) ~= "table" then return false end

    local floors = DATA.SummonerSettings
    if type(floors) ~= "table" then
        pcall(function() Remotes.RequestSync:FireServer() end)
        return false
    end

    local ref = refLevel()
    local changed = 0
    for floor, cfg in pairs(floors) do
        local already = (type(cfg) == "table" and cfg.AutoDeleteRarities) or {}
        for rarity in pairs(SummonerCfg.RarityTierIndex) do
            local ceiling = rarityCeiling(rarity, ref)
            if ceiling > 0 and ceiling < worst.refScore and not already[rarity] then
                pcall(function() Remotes.SetAutoDelete:FireServer(floor, rarity, true) end)
                changed = changed + 1
                STATE.filtered = (STATE.filtered or 0) + 1
                note("stopped rolling " .. tostring(rarity))
                task.wait(0.35)
                if changed >= 6 then break end
            end
        end
        if changed >= 6 then break end
    end
    if changed > 0 then
        pcall(function() Remotes.RequestSync:FireServer() end)
    end
    return changed > 0
end

-- Is there unit work outstanding? This is what holds the roll back: a free
-- slot, a chest with anything in it, or a spare that beats the weakest placed
-- unit all mean the body is needed somewhere more valuable than the roller.
local function unitWorkPending()
    if freeSlot() then return true end
    if (select(1, chestCount()) or 0) > 0 then return true end
    local best  = backpackTools()[1]
    local worst = weakestPlaced()
    if best and worst and best.charId
       and refScoreOf(best) > worst.refScore * (tonumber(CONFIG.swapMargin) or 1.1) then
        return true
    end
    return false
end

-- The decision the whole script exists for, in the order the user asked for:
-- empty the chest so drops never stop, place and swap until the plot holds the
-- six best units in hand, and only THEN sell what is left over - so nothing
-- that could still earn a slot is ever sold.
local function manageUnits()
    if not alive() then return end
    -- Hands off the body while a raid is running.
    if raidActive() then STATE.mode = "raid"; return end
    if CONFIG.autoChest then drainChest() end
    placeAndSwap()
    sellSpares()
end

-- ----------------------------------------------------------------- spending
-- Stat cards carry their own price label, which is the only price that has
-- been seen to match what the server charges.
local function statCards()
    local gui = plr:FindFirstChild("PlayerGui")
    local main = gui and gui:FindFirstChild("Main")
    local uf = main and main:FindFirstChild("UpgradesFrame")
    local sf = uf and uf:FindFirstChild("Main") and uf.Main:FindFirstChild("ScrollingFrame")
    local out = {}
    if not sf then return out end
    for _, card in ipairs(sf:GetChildren()) do
        if card:IsA("Frame") and card:FindFirstChild("StatName") then
            local key = card.Name:gsub("Card$", "")
            local buy = card:FindFirstChild("BuyButton")
            local pl  = buy and buy:FindFirstChild("PriceLabel")
            local price = pl and parseAmount(pl.Text) or nil
            out[#out + 1] = {
                key = key,
                card = card,
                button = buy,
                display = card.StatName.Text,
                priceText = pl and pl.Text or "?",
                price = price,
                maxed = pl and tostring(pl.Text):upper():find("MAX") ~= nil,
                level = tonumber(tostring(card.Value.Text):match("Lv%.(%d+)")) or 0,
            }
        end
    end
    return out
end

local function buyStats()
    local bal = money()
    local reserve = tonumber(CONFIG.moneyReserve) or 0
    local spendable = math.max(0, bal - reserve)
    local cap = spendable * (tonumber(CONFIG.maxStatSpend) or 0.75)

    local byKey = {}
    for _, c in ipairs(statCards()) do byKey[c.key] = c end

    local best
    if CONFIG.statOrder == "Cheapest first" then
        for _, c in ipairs(statCards()) do
            if not c.maxed and c.price and c.price <= cap then
                if not best or c.price < best.card.price then best = { card = c } end
            end
        end
    else
        -- Value order: walk the plan and take the first affordable stat that is
        -- still under its cap. Falling through to the next entry is the point -
        -- when Summoner's next level is out of reach the money goes to slots
        -- rather than sitting there.
        for _, step in ipairs(STAT_PLAN) do
            local c = byKey[step.key]
            local limit = step.share and (spendable * step.share) or cap
            if c and not c.maxed and c.price and c.price <= limit
               and (c.level or 0) < step.cap then
                best = { card = c }
                break
            end
        end
    end
    if not best then return false end

    local c = best.card
    local levelBefore = c.level

    -- The UI path, for EVERY stat, because BuyUpgrade does not cover them all.
    -- Summoner in particular ignores both BuyUpgrade:FireServer("Summoner") and
    -- UpgradeSummoner:FireServer() - measured, level did not move either way -
    -- and instead opens a "Upgrade summoner to Lv.4 for 7.7M$?" confirmation
    -- that has to be answered. Firing the card's own BuyButton and then the
    -- dialog's Yes covers the plain stats and the gated ones with one path.
    local fired = false
    if c.button then
        local conns = {}
        pcall(function() conns = getconnections(c.button.MouseButton1Click) end)
        for _, conn in ipairs(conns) do
            pcall(function() conn:Fire() end)
            fired = true
        end
    end
    if not fired then
        pcall(function() Remotes.BuyUpgrade:FireServer(c.key) end)
    end
    task.wait(0.8)

    -- Answer the confirmation if one came up.
    local gui = plr:FindFirstChild("PlayerGui")
    local main = gui and gui:FindFirstChild("Main")
    local cf = main and main:FindFirstChild("ConfirmationFrame")
    if cf and cf.Visible then
        local yes
        for _, d in ipairs(cf:GetDescendants()) do
            if d.Name == "YesButton" then yes = d end
        end
        if yes then
            local conns = {}
            pcall(function() conns = getconnections(yes.MouseButton1Click) end)
            for _, conn in ipairs(conns) do pcall(function() conn:Fire() end) end
            task.wait(1.0)
        end
    end
    task.wait(0.6)

    -- Verified on the LEVEL, never on the money. leaderstats.Money is an
    -- abbreviated string, so a 7.7M purchase against a 1.4B balance leaves it
    -- reading "1.4B$" either way and every real purchase looked like a failure.
    local after
    for _, c2 in ipairs(statCards()) do
        if c2.key == c.key then after = c2.level end
    end
    if after and after > levelBefore then
        STATE.statBuys = STATE.statBuys + 1
        note(("bought %s Lv.%d for %s"):format(c.display, after, c.priceText))
        return true
    end
    return false
end

-- Levelling a placed unit goes through the slot's own SurfaceGui button.
-- UpgradePet:FireServer(uid) is a dead end and is deliberately not used.
-- LEVELLING RUNS ON A BUDGET, NOT ONE LEVEL AT A TIME.
-- The first version bought a single level per call on a 9 second loop, so a
-- plot earning trillions a second crawled along at Lv.3 and Lv.4 while the
-- money piled up. But spending freely here is the other failure: unit levels
-- are a cheap, constantly available purchase and they would eat exactly the
-- balance the stat upgrades need - the starvation pattern that already caught
-- Luck once in this script.
--
-- So each pass gets a fixed SHARE of the balance and spends it down, taking
-- the best value-per-dollar unit each time. The rest of the money is left
-- alone for the stats.
local function levelUnits()
    if raidActive() then return false end
    local bal = money()
    local reserve = tonumber(CONFIG.moneyReserve) or 0
    local budget = math.max(0, bal - reserve) * (tonumber(CONFIG.levelBudget) or 0.4)
    if budget <= 0 then return false end

    local spent, done = 0, 0
    for _ = 1, 15 do
        -- Best return per dollar. At equal cost that is the strongest unit,
        -- because its base value is what the level multiplies.
        local best
        for _, s in ipairs(slots()) do
            if s.occupied and s.button and s.upgradeCost
               and (spent + s.upgradeCost) <= budget then
                local ratio = (s.score or 0) / math.max(1, s.upgradeCost)
                if not best or ratio > best.ratio then best = { slot = s, ratio = ratio } end
            end
        end
        if not best then break end

        local levelBefore = best.slot.level or 0
        local conns = {}
        pcall(function() conns = getconnections(best.slot.button.MouseButton1Click) end)
        if #conns == 0 then break end
        for _, c in ipairs(conns) do pcall(function() c:Fire() end) end
        task.wait(0.6)

        -- Read the slot back rather than the balance: the abbreviated money
        -- string cannot see a purchase that is small against the balance.
        local after = readSlot(best.slot.slot)
        if (after.level or 0) <= levelBefore then break end
        spent = spent + best.slot.upgradeCost
        done = done + 1
        STATE.lvlBuys = STATE.lvlBuys + 1
    end

    if done > 0 then note(("levelled %d unit levels"):format(done)) end
    return done > 0
end

-- -------------------------------------------------------------- extra claims
local function claimRewards()
    local function fire(name, arg)
        local r = Remotes:FindFirstChild(name)
        if not r then return end
        if arg == nil then
            pcall(function() r:FireServer() end)
        else
            pcall(function() r:FireServer(arg) end)
        end
    end
    fire("ClaimOfflineRewards")
    fire("ClaimDailyReward")
    for i = 1, 8 do fire("ClaimTimeReward", i) end
    for i = 1, 12 do fire("ClaimQuest", i) end
    return true
end

local _codesDone = false
local function redeemCodes()
    if _codesDone then return false end
    _codesDone = true
    for _, code in ipairs(CODES) do
        pcall(function() Remotes.Communication:FireServer("RedeemCode", code) end)
        task.wait(0.7)
    end
    note(("tried %d codes"):format(#CODES))
    return true
end

-- ------------------------------------------------------- the Infinity Castle
-- The single biggest lever in the game, and it is a client-authority hole.
--
-- The whole castle battle runs in PlayerGui.Main.CastleStartFrame's own
-- controller: AdvanceRoom() increments a LOCAL counter and tells the server,
-- and the server pays out InfinityCastleRewardConfig for that room without
-- ever checking that a fight happened. Measured on a controlled run: room
-- 1 -> 26 in 10.2s with exactly 25 fires accepted and zero battles.
--
-- The rate limit is on the STEP, not the amount - room 250 asked for from
-- room 2 was refused, while +1 steps always land. Measured acceptance:
-- 0.40s spacing 100%, 0.35s about 75%, 0.06s about 1%. So it is paced at
-- 0.42s and never bursts.
--
-- Depth is what unlocks the rewards: MutationCrystal at 150, AwakeningGem at
-- 175, OniPotion (x3 luck AND money AND damage) at 250 and AngelicPotion (x5
-- on all three) at 300. Those two potions have no Robux path at all - the
-- castle is the only way to get them.
-- The team the castle run is started with. It has to come from the PLACED
-- units: the game's own "equip best" reads Backpack Tools, and with every unit
-- sitting on a slot the backpack is empty, which is why clicking the castle
-- button by hand starts an empty run that cannot clear anything.
local function castleUnits()
    local out = {}
    for _, s in ipairs(slots()) do
        if s.occupied and s.uid and s.charId then
            out[#out + 1] = {
                Uid = s.uid,
                CharacterId = s.charId,
                MutationId = s.mutation or "Normal",
                Fused = false,
            }
        end
        if #out >= 3 then break end
    end
    return out
end

local function castleRoom()
    local run = DATA.SavedCastleRun
    if type(run) == "table" then
        return tonumber(run.Room) or tonumber(run.room) or tonumber(run.CurrentRoom)
    end
    return nil
end

-- The room number is ABSOLUTE and the server only accepts stored+1, so once a
-- single declaration is refused the local counter runs ahead and every later
-- one reads as a jump and is refused too - the run looks capped when it is
-- merely desynced. DataSync lags 30-60s behind writes, so the oracle cannot be
-- polled every step either; it is only ever used to catch UP.
local _castleLocal = nil

local function castleStep()
    -- The castle run is declared with the placed units, and during a raid those
    -- are committed elsewhere - so it waits its turn too.
    if raidActive() then return false end
    local units = castleUnits()
    if #units == 0 then return false end

    local synced = castleRoom()
    if synced and (not _castleLocal or synced > _castleLocal) then
        _castleLocal = synced
    end

    local room = _castleLocal
    if not room then
        pcall(function() Remotes.Communication:FireServer("InfinityCastleStart", units) end)
        task.wait(1.0)
        pcall(function() Remotes.RequestSync:FireServer() end)
        task.wait(0.8)
        room = castleRoom() or 1
    end

    for _ = 1, 25 do
        if _G.__ANIMEBOSS ~= GEN or not CONFIG.autoCastle or not STATE.running then break end
        room = room + 1
        local r = room
        pcall(function()
            Remotes.Communication:FireServer("InfinityCastleRoomCleared", r, units, 1)
        end)
        _castleLocal = r
        STATE.castleRoom = r
        task.wait(0.42)
    end
    pcall(function() Remotes.RequestSync:FireServer() end)
    note(("castle room %d"):format(STATE.castleRoom or 0))
    return true
end

-- Potions are consumed one at a time and the server clamps the amount to what
-- is actually owned, so there is nothing to forge here - this just spends what
-- the castle brought in rather than letting it sit.
local function useBoosts()
    local items = DATA.Items
    if type(items) ~= "table" then return false end
    -- ONE OF EVERY TYPE, not one in total. They are separate buffs on separate
    -- timers and they stack, so stopping after the first left most of the
    -- stock sitting unused. The server clamps the amount to what is owned, so
    -- there is nothing to gain by asking for more than one at a time.
    local order = {
        "AngelicPotion", "OniPotion",
        "BigLuckPotion", "BigDamagePotion", "BigMoneyPotion",
        "LuckPotion", "DamagePotion", "MoneyPotion",
    }
    local used = 0
    for _, id in ipairs(order) do
        if (tonumber(items[id]) or 0) > 0 then
            pcall(function() Remotes.UseItem:FireServer(id, 1) end)
            used = used + 1
            task.wait(0.4)
        end
    end
    if used > 0 then
        note(("drank %d potions"):format(used))
        pcall(function() Remotes.RequestSync:FireServer() end)
    end
    return used > 0
end

-- ------------------------------------------------------------- the main loop
-- A boss that cannot be killed in reasonable time blocks the ENTIRE game: no
-- kill means no drop, no drop means no new unit, and the plot cannot grow its
-- way out because the thing blocking it is the thing it needs to beat. A Rage
-- boss at 69B against a few million damage a second is all night.
--
-- So the kill is PROJECTED rather than timed out: measure the health actually
-- coming off over the first seconds and divide the remainder by it. That
-- adapts by itself as the plot gets stronger, where a fixed "give up after two
-- minutes" would throw away bosses the plot has grown into.
-- One tracker per boss, keyed on the model, because the two tiers run their
-- own bosses side by side and a single tracker would keep resetting itself.
local _track = {}

local function bossEta(entry)
    if not entry or not entry.model or not entry.model.Parent then return nil end
    local hp = tonumber(entry.model:GetAttribute("Health")) or 0
    local now = os.clock()

    -- Drop trackers for bosses that no longer exist, so the table cannot grow
    -- and a dead boss's timing can never be handed to a live one.
    for k in pairs(_track) do
        if typeof(k) == "Instance" and k.Parent == nil then _track[k] = nil end
    end

    local t = _track[entry.key]
    if not t then
        _track[entry.key] = { t0 = now, hp0 = hp }
        return nil
    end
    -- MEASURING FOR ONLY A FEW SECONDS IS HOW A GOOD BOSS GETS THROWN AWAY.
    -- This projected after 8s, and 8s is easily a quiet patch: units tick on
    -- their own server timers and a fresh spawn has not been reached by all of
    -- them yet, so the damage rate reads low, the projection reads enormous,
    -- and a boss that would have died in half a minute is rerolled. A reroll
    -- throws the whole boss away, so the bias has to be towards patience.
    local age = now - t.t0
    if age < 20 then return nil, age end
    local done = t.hp0 - hp
    if done <= 0 then return math.huge, age end
    local dps = done / age
    if entry.key == (bosses()[1] and bosses()[1].key) then STATE.bossDps = dps end
    return hp / dps, age
end

local function rerollBoss(entry)
    entry = entry or bosses()[1]
    if not entry then return false end
    local target = entry.model
    local spawn  = entry.spawn
    local ok = false
    withUI("reroll", function() ok = fireRollPrompt(entry.roller) end)
    if not ok then return false end
    task.wait(1.0)
    _track[target] = nil

    -- Did the spawn actually change hands? The old check compared the model
    -- against ITSELF, which can never differ, and counted a boss that simply
    -- died of its own accord as a successful reroll - so the counter climbed
    -- even when nothing was rerolled at all.
    local nowHolds
    for _, c in ipairs(spawn:GetChildren()) do
        if c:GetAttribute("MaxHealth") then nowHolds = c end
    end
    if nowHolds ~= target then
        STATE.rerolled = STATE.rerolled + 1
        note("rerolled a boss that was going nowhere")
        return true
    end
    return false
end

local _lastClick = 0
local function farmCycle()
    if not alive() then STATE.mode = "dead"; return end
    -- The raid owns the player until it ends. Money collection is a touch and
    -- costs nothing, but nothing here may move or pin the character.
    if raidActive() then
        STATE.mode = "raid"
        if CONFIG.autoMoney then collectMoney() end
        return
    end

    local hp, maxHp = bossHealth()
    if hp then
        STATE.bossPct = maxHp > 0 and (hp / maxHp * 100) or 0
        local b = boss()
        STATE.bossName = b and b.Name or "-"
    end

    if CONFIG.autoMoney then collectMoney() end

    -- ROLLING IS LAST IN LINE, ALWAYS. Units come first (a better one sitting
    -- in the backpack is income and damage the plot is not getting), then the
    -- upgrades - which never touch the body at all, they are UI clicks - then
    -- placing, and only then a roll. Measured while this was the other way
    -- round: a Shigaraki worth 51,562,500 sat in the backpack against a
    -- weakest placed unit of 8,411,091, six times better, while the character
    -- stood on the roller holding the UI lock so every swap silently failed.
    if CONFIG.autoRoll and not unitWorkPending() then
        local stale = false
        for _, sp in ipairs(bossSpawns()) do
            local empty = tierEmptyFor(sp)
            if empty and empty >= (tonumber(CONFIG.rollAfterEmpty) or 10) then
                stale = true
            end
        end
        if stale then
            STATE.mode = "rolling"
            rollBoss()
        end
    end
    if not boss() then STATE.mode = "waiting"; return end

    STATE.mode = "fighting"
    -- One click a second, because that is all the server will take.
    if CONFIG.autoClick and (os.clock() - _lastClick) >= 1.0 then
        _lastClick = os.clock()
        clickBoss()
    end

    -- Every tier is checked, not just the first: the ground-level boss dies on
    -- its own while the BaseLevel2 one is the one that sits there for hours.
    -- TWO CONDITIONS, BOTH REQUIRED, and the age one is what stops a healthy
    -- boss being rerolled on a bad reading: the boss must have actually been
    -- standing there for `bossMinAge` seconds, AND still be projected to need
    -- more than `bossMaxSeconds` on top of that. A forced roll is the last
    -- resort, not the first reaction to a slow-looking few seconds.
    if CONFIG.autoReroll then
        local limit  = tonumber(CONFIG.bossMaxSeconds) or 120
        local minAge = tonumber(CONFIG.bossMinAge) or 90
        local worst
        for _, e in ipairs(bosses()) do
            local eta, age = bossEta(e)
            if eta and age and age >= minAge and eta > limit
               and (not worst or eta > worst.eta) then
                worst = { entry = e, eta = eta }
            end
            if e.key == (bosses()[1] and bosses()[1].key) then
                STATE.bossEta = eta
                STATE.bossAge = age
            end
        end
        if worst then rerollBoss(worst.entry) end
    end
end

local function loop(period, key, fn)
    task.spawn(function()
        while _G.__ANIMEBOSS == GEN do
            if (key == nil or CONFIG[key]) and STATE.running then
                local ok, err = pcall(fn)
                if not ok then note(tostring(key or "loop") .. " failed: " .. tostring(err)) end
            end
            task.wait(period)
        end
    end)
end

loop(0.5,  nil,           farmCycle)
loop(4,    "autoChest",   manageUnits)
loop(12,   "autoStats",   buyStats)
loop(5,    "autoLevel",   levelUnits)
loop(90,   "autoClaims",  claimRewards)
loop(30,   "autoCodes",   redeemCodes)
loop(2,    "autoCastle",  castleStep)
loop(25,   "autoItems",   useBoosts)
loop(45,   "autoFilter",  syncSummonerSettings)
-- Checked often, but it only READS a label until the countdown is nearly up -
-- the character is not moved unless a raid is actually about to start.
loop(3,    "autoRaid",    joinRaid)
loop(60,   "autoArtifacts", placeArtifacts)

-- Kill counter, read off the oracle rather than counted by us: a boss whose
-- health was above zero and is now gone was beaten.
task.spawn(function()
    local lastHp = nil
    while _G.__ANIMEBOSS == GEN do
        local hp = select(1, bossHealth())
        if lastHp and lastHp > 0 and (hp == nil or hp <= 0) then
            STATE.kills = STATE.kills + 1
        end
        lastHp = hp
        task.wait(1)
    end
end)

-- --------------------------------------------------------------- debug hook
_G.__ANIMEBOSS_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    myPlot = myPlot, boss = boss, bossHealth = bossHealth,
    bosses = bosses, bossSpawns = bossSpawns, fireRollPrompt = fireRollPrompt,
    slots = slots, readSlot = readSlot, freeSlot = freeSlot, weakestPlaced = weakestPlaced,
    slotFolders = slotFolders, unlockedSlotCount = unlockedSlotCount,
    chestEntries = chestEntries, chestCount = chestCount,
    unitStats = unitStats, charInfo = charInfo, rarityRank = rarityRank,
    refLevel = refLevel, refScoreOf = refScoreOf, scoreAtLevel = scoreAtLevel,
    backpackTools = backpackTools, placeOn = placeOn, removeFrom = removeFrom,
    manageUnits = manageUnits, drainChest = drainChest, placeAndSwap = placeAndSwap,
    sellSpares = sellSpares, sellTool = sellTool,
    takeFromChest = takeFromChest, dropFromChest = dropFromChest,
    rollBoss = rollBoss, clickBoss = clickBoss, collectMoney = collectMoney,
    statCards = statCards, buyStats = buyStats, levelUnits = levelUnits,
    claimRewards = claimRewards, redeemCodes = redeemCodes,
    castleStep = castleStep, castleUnits = castleUnits, castleRoom = castleRoom,
    useBoosts = useBoosts, bossEta = bossEta, rerollBoss = rerollBoss, DATA = DATA,
    raidActive = raidActive, syncSummonerSettings = syncSummonerSettings,
    joinRaid = joinRaid, raidOpen = raidOpen, raidTimerText = raidTimerText,
    raidSecondsLeft = raidSecondsLeft,
    placeArtifacts = placeArtifacts, artifactInfo = artifactInfo,
    rarityCeiling = rarityCeiling, unitWorkPending = unitWorkPending,
    money = money, parseAmount = parseAmount, totalIncome = totalIncome,
    CODES = CODES, RARITY_ORDER = RARITY_ORDER,
}

-- ------------------------------------------------------------------- panel
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__ANIMEBOSS_WIN then pcall(function() _G.__ANIMEBOSS_WIN:Destroy() end) end
if UI.sweep then UI.sweep("ANIMEBOSS_PANEL") end

UI.config("animeboss", CONFIG)

local win = UI.Window({
    title = "ANIME", accentTitle = "BOSS", subtitle = "seltonmt",
    badge = "*", width = 920, height = 580, name = "ANIMEBOSS_PANEL",
})
_G.__ANIMEBOSS_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local cBoss = farm:Card("BOSS LOOP", 1):Accent()
cBoss:Toggle("Auto roll", CONFIG.autoRoll, function(v) CONFIG.autoRoll = v end,
    "Rolls a new boss as soon as the old one dies")
cBoss:Toggle("Auto attack", CONFIG.autoClick, function(v) CONFIG.autoClick = v end,
    "Paced at one hit a second - the server refuses more")
cBoss:Toggle("Auto collect money", CONFIG.autoMoney, function(v) CONFIG.autoMoney = v end,
    "Touches the claimer, works from any distance", UI.theme.good)
cBoss:Toggle("Reroll stuck bosses", CONFIG.autoReroll, function(v) CONFIG.autoReroll = v end,
    "A boss too tough to kill blocks every drop - this rolls a new one", UI.theme.good)
cBoss:Slider("Give up after (s)", 30, 600, CONFIG.bossMaxSeconds,
    function(v) CONFIG.bossMaxSeconds = v end,
    "Projected from the damage actually landing, not a fixed timer")
cBoss:Slider("Watch it for at least (s)", 30, 300, CONFIG.bossMinAge,
    function(v) CONFIG.bossMinAge = v end,
    "A boss is never rerolled before this, however slow it looks")

local cSpend = farm:Card("SPENDING", 2)
cSpend:Toggle("Buy stat upgrades", CONFIG.autoStats, function(v) CONFIG.autoStats = v end,
    "Damage first, then luck and summoner")
cSpend:Toggle("Level up units", CONFIG.autoLevel, function(v) CONFIG.autoLevel = v end,
    "Levels the unit that returns the most per dollar")
cSpend:Dropdown("Stat order", { "Value order", "Cheapest first" }, CONFIG.statOrder,
    function(v) CONFIG.statOrder = v end)
cSpend:Label("Value order buys Summoner first: one level moves the roll centre a whole rarity tier, while the entire Luck ladder is worth less than one Summoner level.")
cSpend:Slider("Max share per buy", 10, 100, math.floor((CONFIG.maxStatSpend or 0.5) * 100),
    function(v) CONFIG.maxStatSpend = v / 100 end,
    "Never spend more than this share of the balance on one upgrade")
cSpend:Slider("Share for unit levels", 5, 80, math.floor((CONFIG.levelBudget or 0.4) * 100),
    function(v) CONFIG.levelBudget = v / 100 end,
    "How much of the balance one levelling pass may spend - the rest stays for stats")

local units = win:Page("UNITS", UI.icon.star)

local cRank = units:Card("RANKING", 1):Accent()
cRank:Label("A unit is ranked on base damage and money times its mutation and level - never on its level alone.")
cRank:Toggle("Take from chest", CONFIG.autoChest, function(v) CONFIG.autoChest = v end,
    "Pulls out anything that beats the plot")
cRank:Toggle("Fill free slots", CONFIG.autoPlace, function(v) CONFIG.autoPlace = v end,
    "Best unit first")
cRank:Toggle("Swap out the weakest", CONFIG.autoSwap, function(v) CONFIG.autoSwap = v end,
    "Only when the challenger clearly wins", UI.theme.good)
cRank:Slider("Damage vs money", 0, 100, math.floor((CONFIG.dmgWeight or 0.5) * 100),
    function(v) CONFIG.dmgWeight = v / 100 end,
    "0 ranks purely on income, 100 purely on damage")
cRank:Slider("Swap margin", 100, 200, math.floor((CONFIG.swapMargin or 1.1) * 100),
    function(v) CONFIG.swapMargin = v / 100 end,
    "How far a challenger must beat the weakest placed unit")

local cChest = units:Card("CHEST", 2)
cChest:Label("A full chest stops every new unit from dropping, so headroom comes first.")
cChest:Toggle("Sell the leftovers", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
    "Sells only what could not earn a slot, after every swap is done", UI.theme.good)
cChest:Stepper("Spaces to keep free",
    function() return tostring(CONFIG.chestKeepFree) end,
    function(dir)
        CONFIG.chestKeepFree = math.clamp((CONFIG.chestKeepFree or 6) + dir, 1, 20)
    end,
    "The chest is emptied once fewer than this many are left")
cChest:Dropdown("Never sell this tier or above",
    { "None", "Legendary", "Mythical", "Secret", "Celestial" }, CONFIG.protectRarity,
    function(v) CONFIG.protectRarity = v end)

local cExtra = units:Card("EXTRAS", 0)
cExtra:Toggle("Infinity Castle walk", CONFIG.autoCastle, function(v) CONFIG.autoCastle = v end,
    "Walks the castle for potions, crystals and gems - the strongest thing here",
    UI.theme.good)
cExtra:Toggle("Drink potions", CONFIG.autoItems, function(v) CONFIG.autoItems = v end,
    "Spends the potions the castle brings in instead of hoarding them")
cExtra:Toggle("Stop useless rarities", CONFIG.autoFilter, function(v) CONFIG.autoFilter = v end,
    "Turns a rarity off in the summoner settings once the plot has outgrown it",
    UI.theme.good)
cExtra:Toggle("Join boss raids", CONFIG.autoRaid, function(v) CONFIG.autoRaid = v end,
    "Raids are the only place artifacts come from - joining is enough, you need not fight",
    UI.theme.good)
cExtra:Toggle("Place best artifacts", CONFIG.autoArtifacts, function(v) CONFIG.autoArtifacts = v end,
    "Keeps the three strongest artifacts in the plot slots")
cExtra:Toggle("Claim rewards", CONFIG.autoClaims, function(v) CONFIG.autoClaims = v end,
    "Offline, daily, time and quest rewards")
cExtra:Toggle("Redeem codes once", CONFIG.autoCodes, function(v) CONFIG.autoCodes = v end,
    "17 known codes, three of them money", UI.theme.warn)

local info = win:Page("INFO", UI.icon.info)
local cInfo = info:Card("STATUS", 0)
local out = cInfo:Readout(11)

local cWarn = info:Card("READ THIS", 0)
cWarn:Label("Attacking is capped by the server at about one hit a second. Clicking faster does nothing at all.")
cWarn:Label("The damage that kills a boss comes from your placed units, so unit quality is the only real lever.")
cWarn:Label("Rarity beats level: a level 1 Epic was measured at three times a level 24 Rare.")
cWarn:Label("A full chest blocks every new drop. The script keeps spaces free before it places anything.")
cWarn:Label("Nothing here spends Robux, and no gamepass or limited podium is ever touched.")

task.spawn(function()
    while _G.__ANIMEBOSS == GEN do
        pcall(function()
            local used, cap = chestCount()
            local dmg, cash = totalIncome()
            local worst = weakestPlaced()
            local chest = chestEntries()
            local top = chest[1]
            local free = 0
            for _, s in ipairs(slots()) do if not s.occupied then free = free + 1 end end

            out:set({
                "LOOP",
                ("  state %s%s"):format(STATE.mode, STATE.uiOwner and ("  owner " .. STATE.uiOwner) or ""),
                ("  rolled %d   beaten %d   taken %d   placed %d   swapped %d"):format(
                    STATE.rolled, STATE.kills, STATE.taken, STATE.placed, STATE.swapped),
                ("  bought %d stats   %d unit levels   sold %d spares"):format(
                    STATE.statBuys, STATE.lvlBuys, STATE.sold),
                "BOSS",
                ("  %s at %.1f%%"):format(STATE.bossName, STATE.bossPct),
                "PLOT",
                ("  %d slots free   %.0f total DMG   %.0f $/s"):format(free, dmg, cash),
                ("  weakest placed %s"):format(worst and tostring(worst.display or worst.charId) or "-"),
                "CHEST",
                ("  %d / %d   best inside %s"):format(used, cap,
                    top and ("%s (%s)"):format(top.display, top.rarity) or "-"),
            })
            win:SetStat(1, moneyText(), "money")
            win:SetStat(2, ("%d/%d"):format(used, cap), "chest")
            win:SetStat(3, tostring(STATE.kills), "bosses")
            win:SetStatus(("%s   -   %s"):format(STATE.mode, STATE.note))
        end)
        task.wait(1)
    end
end)

pcall(function()
    win:SetMaster(STATE.running, "Auto Farm running")
    win:OnMaster(function(on) STATE.running = on end)
end)

pcall(function() win:Home() end)
