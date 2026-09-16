--[[
    breakegg.lua - "Break an Egg"  place 128683790553857
    ------------------------------------------------------------------------
    Carry-and-place plot income with the field replaced by a mining step: you
    smash a Lucky Egg with a pickaxe, the animal that hatches is carried home
    and dropped in your pen, and it pays cash per second forever.

    READ THIS FIRST: THIS GAME HAS A SERVER-SIDE MOVEMENT CHECK AND IT KICKS.
    An earlier build of this script warped with CFrame for every leg of the loop
    and the account was disconnected with "Movement exploit detected. (Error
    Code: 267)". A client-side string sweep for kick/anti-cheat vocabulary had
    come back clean, and that was written up as "no anti-cheat" - which was
    simply wrong reasoning: a SERVER-side detector has no client code, so no
    sweep of the client VM could ever have found it. Nothing in this script
    teleports. The character walks at the speed the game gave it, and CFrame is
    written only for ROTATION, where the displacement is zero.

    The loop, as measured through the bridge on 2026-09-16:

      pick the richest egg lying in the four bands (all of them are visible
      and carry their SizeTier and Mutation as ATTRIBUTES before they break)
        -> WALK to it, stopping outside its shell, turn to FACE it, then
           PickaxeSwing:FireServer(egg) x ceil(hp/power)
        -> ~1.3s later the prize appears in Spawning.ItemSpawners.Prizes,
           tagged "PrizeTimer", with BrokenBy = our UserId
        -> walk onto it, fireproximityprompt("Pick Up", 10 studs)
        -> walk to the pen (the animal rides along the whole way)
        -> RequestPlaceItem:FireServer(x, z, rot) in PEN-LOCAL coordinates

    Verified facts this script is built on (do not re-derive):

      * THE SWING IS RAYCAST ALONG THE CHARACTER'S LOOKVECTOR. The pickaxe's
        own doRaycasts() picks the target, so standing next to an egg is not
        enough - the root part has to face it or nothing is ever sent.
        PickaxeSwing:FireServer(eggModel) is the damage call; a bare fire with
        no argument does nothing at all.
      * Egg HP is fixed per size and hits = ceil(hp / PickaxePower):
        Small 6, Medium 20, Large 70, Huge 500, Giant 3000, Colossal 12000,
        MEGA 45000. Verified twice: 6 swings at power 1 on a Small (1/6 per
        hit), 6 swings at power 16 on a Large (70 hp).
      * EggHit(egg, fraction, player) is a server -> client BROADCAST, including
        our own hits - it is the honest oracle for "did that land". A broadcast
        with no player argument is the egg HEALING: 4% per second after 8
        seconds without a hit, so a half-broken egg left alone comes back.
      * MoneyLog10 is the money oracle and it is exact - 10^4.768860 = 58,730
        against Stats.Money reading "58.73K". leaderstats has no money at all
        and Stats.Money is a StringValue for display.
      * The prize lives only 30 seconds (PRIZE_LINGER_FRONT), so breaking and
        grabbing have to be one pass. It carries OriginalName, Rarity,
        Mutation, Kg, SizeTier, Gender and Uid as attributes.
      * CARRYING IS ONE ANIMAL AT A TIME. Firing a second Pick Up prompt while
        holding one changes nothing - held stays 1.
      * ESCAPE FIRST, DECIDE LATER. The bosses roam this field and a hit is 50
        knockback plus 1.5s of Limp (BossConfig), which costs the animal. So the
        warp out is part of the GRAB, not of the delivery: the pin releases the
        frame the animal is in hand and the character leaves immediately, before
        the pen census, the value floor or a sale are even looked at. All three
        of those are position-free, so doing them on the spot bought nothing and
        left the character parked next to a boss with the prize in its hands -
        which is what it looked like in game, and releasing the pin earlier did
        not fix it on its own.
      * plr.CarryCount is a ZONE FLAG, not ownership. It drops to 0 the moment
        you leave the CollectionZone (a 315x528x456 volume covering the whole
        egg field out to z = +77) while the animal stays parented to the
        character the whole way home. Reading it as "the carry was lost" is
        what made the delivery look broken for half an hour.
      * BuyPickaxe:FireServer(name) SKIPS THE LADDER and charges that tier's
        price directly - Wood(1) -> Rainbow(16) for exactly 35,000, straight
        from Stone. It auto-equips. The tier list with prices and powers is
        PickaxeConfig.Tiers, 33 rungs from Wood 25/power 1 to Glory inf/275.
      * Placing is RequestPlaceItem:FireServer(x, z, rot) where x/z are
        PEN-LOCAL (penPart.CFrame:PointToObjectSpace) and clamped by
        PenConfig.ClampInsidePen. Verified: CashPerSecond 11.12 -> 20.21 on the
        first placement and 34.63 -> 93.61 on a Boston Terrier.
      * Pen capacity is BASE_CAPACITY 10 + CAPACITY_PER_LEVEL 4 per level to
        MAX_LEVEL 5, so 10/14/18/22/26. The "Upgrade Pen" sign reads $1M for
        level 2.

      * SELLING IS RequestSell:FireServer("Equipped") AND IT ONLY EVER TOUCHES
        WHAT IS IN YOUR HANDS. That string was read out of the game's own
        SellController rather than guessed: its prompt handler answers "Equip an
        animal to sell it!" when the hands are empty, which is why firing the
        vendor prompt while carrying nothing looks like a dead prompt, and its
        confirm button fires exactly that one constant. Verified: a Frog sold
        while the pen read 8/10 before AND after. There is no "Inventory"
        variant in this game, but the aurabrainrots rule still applies - never
        widen that argument on a hunch, the pen is the whole farm.
      * SELLING IS POSITION GATED AT THE VENDOR, and believing otherwise
        deadlocks the whole loop. Measured on one carry: fired from 46 studs
        nothing happened, fired from 6 studs it sold. The first reading said
        "not position gated" and was simply luck - that probe ran while the
        character still stood at the vendor from the step before it. With a full
        pen and no vendor warp the farm parks in the middle of the field holding
        the animal and retries the sale forever, which is exactly the boss food
        the escape rule above is trying to avoid.
      * RequestBaseUpgrade:FireServer() takes no arguments and works - verified
        on 2026-09-16, capacity 10 -> 14 for $1M with $2.0M banked.
      * THE PEN IS ONE-WAY AND THAT IS THE WHOLE STRATEGY. A placed animal
        cannot be taken back: there is no prompt anywhere on the pen, and the
        three client controllers that touch placements are all read-only -
        CreatureHoverController is a hover tooltip (a viewport raycast that
        fills in Kg and Gender), DropController only watches CarryCount and
        DropLockUntil for the throw-away button, and PenPlacementClient only
        ever places. So a slot spent is spent forever, and a loop that seats
        whatever it happens to catch first ends up holding 10/s Giant Isopods
        while it sells 186/s Shoebills for want of a slot - measured, that is
        exactly what the first build did. While the pen is mostly empty
        anything beats an empty slot; once `pickyBelow` slots are left, a catch
        has to beat the weakest animal already placed or it is sold instead.
      * A FULL PEN IS NOT A DEAD END, it is a cash engine: keep breaking eggs
        and sell every catch, which funds the pen upgrade and its four slots.

    Deliberately NOT automated, and why:

      * LuckMachine, potions, gear, the group reward and RequestTeleport are
        unmapped. None of them were probed, so none of them are fired.

    Panel: RightShift.  Console handle: _G.__BREAKEGG_DBG
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")

local plr = Players.LocalPlayer

local Events  = ReplicatedStorage:WaitForChild("Events", 10)
local Modules = ReplicatedStorage:WaitForChild("Modules", 10)

-- ---------------------------------------------------------------- generation
-- Re-running in the executor does not restart the Lua VM, so every loop below
-- captures this number and exits the moment it stops matching.
_G.__BREAKEGG = (_G.__BREAKEGG or 0) + 1
local GEN = _G.__BREAKEGG

-- ------------------------------------------------------------------ configs
local EggConfig, PickaxeConfig, PenConfig, ItemConfig, IncomeConfig, PenUtil
pcall(function() EggConfig     = require(Modules.EggConfig) end)
pcall(function() PickaxeConfig = require(Modules.PickaxeConfig) end)
pcall(function() PenConfig     = require(Modules.PenConfig) end)
pcall(function() ItemConfig    = require(Modules.ItemConfigurations) end)
pcall(function() IncomeConfig  = require(Modules.IncomeConfig) end)
pcall(function() PenUtil       = require(Modules.PenUtil) end)

-- Size ladder. The pool a size rolls from climbs steeply with it (Small draws
-- animals worth 14-18/s, Giant 1600+, MEGA a 105,000/s Hydra), but the roll is
-- luck-tilted and can UPSET into a neighbouring pool - a Large egg handed over
-- a Boston Terrier that sits in the Medium band. So the size is ranked as an
-- ordinal, never turned into a predicted income.
local SIZE_RANK = {
    Small = 1, Medium = 2, Large = 3, Huge = 4,
    Giant = 5, Colossal = 6, MEGA = 7,
}
local SIZE_ORDER = { "Small", "Medium", "Large", "Huge", "Giant", "Colossal", "MEGA" }

-- Measured off IncomeConfig.MUTATION_MULTIPLIERS.
local MUTATIONS = (IncomeConfig and IncomeConfig.MUTATION_MULTIPLIERS) or {
    Normal = 1, Golden = 1.5, Diamond = 2, Ruby = 2.5, Admin = 3,
    Neon = 5, Coral = 6, Pearl = 7, Abyssal = 8, Trident = 9, Leviathan = 10,
}

local function eggHp(size)
    local row = EggConfig and EggConfig.Rows and EggConfig.Rows[size]
    return (row and tonumber(row.HP)) or math.huge
end

-- What a size is worth on average, DERIVED FROM CONTENT rather than guessed.
-- Each size's Pool {Min,Max} indexes the animal roster sorted by Income - the
-- first Small egg opened here handed over roster entry 10 exactly, and the one
-- mismatch was flagged `Upset` on the prize itself, so the mapping holds and
-- upsets are the exception. Averaging the span gives a real expected income per
-- size, which is what lets a long walk be weighed against a big egg.
local SIZE_VALUE = {}
do
    local sorted = {}
    if ItemConfig and ItemConfig.Items then
        for name, cfg in pairs(ItemConfig.Items) do
            sorted[#sorted + 1] = { name = name, inc = tonumber(cfg.Income) or 0 }
        end
        table.sort(sorted, function(a, b)
            if a.inc == b.inc then return a.name < b.name end
            return a.inc < b.inc
        end)
    end
    for size, row in pairs((EggConfig and EggConfig.Rows) or {}) do
        local pool = row.Pool
        local sum, n = 0, 0
        if pool and pool.Min and #sorted > 0 then
            for i = pool.Min, math.min(pool.Max, #sorted) do
                sum = sum + sorted[i].inc
                n = n + 1
            end
        end
        SIZE_VALUE[size] = (n > 0) and (sum / n) or 1
    end
end

-- ------------------------------------------------------------------- config
local CONFIG = {
    autoFarm        = true,
    autoPlace       = true,

    minSize         = "Small",   -- lowest egg size worth walking to
    preferMutated   = true,      -- a mutation outranks one size step
    maxSwings       = 240,       -- skip anything that would take longer than this
    swingRate       = 0.30,      -- seconds between swings

    autoSell        = true,      -- on a full pen, sell the catch instead of stalling
    pickyBelow      = 3,         -- with this many slots left, only place an upgrade
    autoPickaxe     = true,
    pickaxeReserve  = 0.0,       -- keep this fraction of the balance back
    autoPenUpgrade  = true,      -- verified: capacity 10 -> 14 for $1M
    autoDaily       = true,
}

local STATE = {
    running   = false,
    phase     = "idle",
    broken    = 0,
    placed    = 0,
    sold      = 0,
    earned    = 0,
    stolen    = 0,
    failed    = 0,
    skipped   = 0,
    target    = "-",
    lastAnimal= "-",
    lastGain  = 0,
    note      = "loaded",
    uiOwner   = nil,
}

local function note(s) STATE.note = s end

local function fmt(n)
    n = tonumber(n) or 0
    local units = { "", "K", "M", "B", "T", "Qd", "Qn" }
    local i = 1
    while n >= 1000 and i < #units do n = n / 1000; i = i + 1 end
    if i == 1 then return string.format("%d", n) end
    return string.format("%.2f%s", n, units[i])
end

-- ------------------------------------------------------------------ oracles
-- Money is stored as a log. 10^MoneyLog10 matched Stats.Money to the unit.
local function money()
    local l = plr:GetAttribute("MoneyLog10")
    if not l then return 0 end
    return 10 ^ l
end

local function power()  return tonumber(plr:GetAttribute("PickaxePower")) or 1 end
local function cps()    return tonumber(plr:GetAttribute("CashPerSecond")) or 0 end

local function character()
    local ch = plr.Character
    if not ch then return nil end
    local hrp = ch:FindFirstChild("HumanoidRootPart")
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return nil end
    return ch, hrp, hum
end

local function alive()
    local _, _, hum = character()
    return hum and hum.Health > 0
end

-- ---------------------------------------------------------------- movement
-- THIS GAME HAS A SERVER-SIDE MOVEMENT CHECK AND IT KICKS. Measured the hard
-- way on 2026-09-16: an earlier build warped with CFrame for every leg of the
-- loop and the account was disconnected with "Movement exploit detected.
-- (Error Code: 267)". A client-side string sweep had come back clean, which
-- proves nothing at all - a server-side detector has no client code to find.
--
-- So nothing here teleports. The character WALKS at the speed the game gave it,
-- and CFrame is only ever written for ROTATION, where the displacement is zero
-- and there is nothing for a movement check to see.
local function walkTo(pos, arriveDist, timeout)
    local _, hrp, hum = character()
    if not (hrp and hum) then return false end
    arriveDist = arriveDist or 6
    timeout    = timeout or 30

    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        if _G.__BREAKEGG ~= GEN then return false end
        if not alive() then return false end
        local here = character() and hrp.Position
        if not here then return false end
        if (here - pos).Magnitude <= arriveDist then return true end
        hum:MoveTo(pos)
        task.wait(0.2)
    end
    return (hrp.Position - pos).Magnitude <= arriveDist
end

-- Turn on the spot. Same position, new look direction - which is all the
-- pickaxe's own raycast needs.
local function faceTowards(pos)
    local _, hrp = character()
    if not hrp then return end
    local from = hrp.Position
    local flat = Vector3.new(pos.X, from.Y, pos.Z)
    if (flat - from).Magnitude < 0.15 then return end
    hrp.CFrame = CFrame.lookAt(from, flat)
end

-- --------------------------------------------------------------- the pickaxe
-- The server rejects a swing that carries no target, and the tool has to be in
-- hand for the client's own raycast helper to exist at all.
local function equipPickaxe()
    local ch, _, hum = character()
    if not ch then return false end
    local held = ch:FindFirstChildOfClass("Tool")
    local want = plr:GetAttribute("EquippedPickaxe")
    if held and held.Name == want then return true end
    local t = plr.Backpack:FindFirstChild(want or "")
    if not t then
        -- fall back to whatever pickaxe is in the backpack
        for _, c in ipairs(plr.Backpack:GetChildren()) do
            if c:IsA("Tool") and c:FindFirstChild("Pickaxe") then t = c break end
        end
    end
    if not t then return held ~= nil end
    -- One attempt is not enough: right after a warp the humanoid is still in
    -- Freefall and the equip is dropped, which surfaced as a bare "no pickaxe"
    -- and skipped the whole cycle.
    for _ = 1, 3 do
        pcall(function() hum:EquipTool(t) end)
        task.wait(0.35)
        local now = ch:FindFirstChildOfClass("Tool")
        if now then return true end
    end
    return false
end

-- PickaxeConfig.Tiers is the full ladder; BuyPickaxe skips rungs, so the right
-- move is always the best tier the balance covers, not the next one up.
local function bestAffordablePickaxe()
    if not (PickaxeConfig and PickaxeConfig.Tiers) then return nil end
    local budget = money() * (1 - CONFIG.pickaxeReserve)
    local cur    = power()
    local best
    for _, tier in ipairs(PickaxeConfig.Tiers) do
        local price = tonumber(tier.Price)
        local pw    = tonumber(tier.Power) or 0
        if price and not tier.OffSale and pw > cur and price <= budget then
            if (not best) or pw > best.Power then best = tier end
        end
    end
    return best
end

local function buyPickaxe()
    local tier = bestAffordablePickaxe()
    if not tier then return false end
    local before = power()
    pcall(function() Events.BuyPickaxe:FireServer(tier.Name) end)
    task.wait(1.0)
    if power() > before then
        note(("pickaxe %s, power %d -> %d"):format(tier.Name, before, power()))
        equipPickaxe()
        return true
    end
    return false
end

-- ----------------------------------------------------------------- the eggs
local function eggFolder() return workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Eggs") end

local function swingsFor(egg)
    local size = egg:GetAttribute("SizeTier")
    local hp   = eggHp(size)
    return math.ceil(hp / math.max(1, power()))
end

-- Expected income times the mutation multiplier. Both are readable on the egg
-- BEFORE it is touched, which is what makes picking targets free.
local function eggScore(egg)
    local size = egg:GetAttribute("SizeTier")
    local rank = SIZE_RANK[size]
    if not rank then return nil end
    local mut  = egg:GetAttribute("Mutation")
    local mult = (mut and MUTATIONS[mut]) or 1
    if not CONFIG.preferMutated then mult = 1 end
    return (SIZE_VALUE[size] or 1) * mult, rank, mut, mult
end

-- Now that the character WALKS, a far egg costs real seconds and the ranking
-- has to be a rate, not a prize. Otherwise the loop crosses the whole field for
-- one more size step and earns less per minute than it would nearby.
local function eggRate(egg, fromPos)
    local score = eggScore(egg)
    if not score then return nil end
    local _, _, hum = character()
    local speed = (hum and hum.WalkSpeed > 0 and hum.WalkSpeed) or 16
    local dist  = (egg:GetPivot().Position - fromPos).Magnitude
    -- travel out, the swings themselves, and the walk home plus the handling
    local seconds = dist / speed + swingsFor(egg) * CONFIG.swingRate + 14
    return score / seconds, score, seconds, dist
end

local function bestEgg()
    local folder = eggFolder()
    local _, hrp = character()
    if not (folder and hrp) then return nil end

    local floor = SIZE_RANK[CONFIG.minSize] or 1
    local now   = os.time()
    local best, bestScore

    local from = hrp.Position
    for _, egg in ipairs(folder:GetChildren()) do
        if egg:GetAttribute("IsLuckyEgg") then
            local rate, score, seconds = eggRate(egg, from)
            local _, rank = eggScore(egg)
            local need = swingsFor(egg)
            local expires = egg:GetAttribute("ExpiresAt")
            -- An egg that dies before we can even walk there is wasted travel,
            -- and a half-broken egg heals back at 4%/s anyway.
            local doomed = expires and seconds and (expires - now) < seconds
            if rate and rank and rank >= floor and need <= CONFIG.maxSwings and not doomed then
                if (not bestScore) or rate > bestScore then
                    best, bestScore = egg, rate
                end
            end
        end
    end
    return best, bestScore
end

-- Warp so the root part LOOKS AT the egg - the client raycasts along LookVector
-- and a warp that lands facing the wrong way sends nothing at all.
--
-- THE STAND-OFF HAS TO SCALE WITH THE EGG. A Giant is 12 studs across with a
-- Radius attribute of 6.46, so a fixed 6-stud offset parks the character INSIDE
-- it, the ray starts past the surface and every swing misses. That reads as a
-- server gate and is not one - Small (1.57) and Large (3.34) both have room to
-- spare at 6 studs, which is exactly why those worked by hand and the big ones
-- silently did not. Aim at the body's middle too; the pivot sits near the base.
local function eggAim(egg)
    local ok, cf, size = pcall(function() return egg:GetBoundingBox() end)
    if ok and cf and size then
        return cf.Position, (tonumber(egg:GetAttribute("Radius")) or (size.X / 2)) + 5
    end
    local pos = egg:GetPivot().Position
    return pos + Vector3.new(0, 2, 0), (tonumber(egg:GetAttribute("Radius")) or 2) + 5
end

-- Walk up to the egg, stopping a body's length outside its shell, then turn to
-- face it. Approaching on foot also means the egg's parts have streamed in by
-- the time we are in range.
local function approachEgg(pos, standoff)
    local ok = walkTo(pos, standoff, 30)
    faceTowards(pos)
    return ok
end

local function breakEgg(egg)
    if not (egg and egg.Parent) then return false end
    if not equipPickaxe() then note("no pickaxe") return false end

    local size = egg:GetAttribute("SizeTier")
    local need = swingsFor(egg)
    STATE.target = ("%s%s (%d swings)"):format(
        size or "?", egg:GetAttribute("Mutation") and (" " .. egg:GetAttribute("Mutation")) or "", need)

    local pos, standoff = eggAim(egg)
    if not approachEgg(pos, standoff) then
        note("could not walk to the egg")
        STATE.failed = STATE.failed + 1
        return false
    end
    task.wait(0.2)

    -- Re-face every swing: a boss knockback turns the character and every
    -- swing after that raycasts into empty air.
    local budget = need + 8
    for _ = 1, budget do
        if _G.__BREAKEGG ~= GEN then return false end
        if not egg.Parent then
            STATE.broken = STATE.broken + 1
            return true
        end
        if not alive() then note("died while mining") return false end
        -- A boss knockback shoves the character off the egg AND turns it, so
        -- both have to be corrected - but by WALKING back, never by warping.
        local _, hrpNow = character()
        if not hrpNow then return false end
        if (hrpNow.Position - pos).Magnitude > standoff + 6 then
            walkTo(pos, standoff, 8)
        end
        faceTowards(pos)
        pcall(function() Events.PickaxeSwing:FireServer(egg) end)
        task.wait(CONFIG.swingRate)
    end

    if not egg.Parent then
        STATE.broken = STATE.broken + 1
        return true
    end
    STATE.failed = STATE.failed + 1
    return false
end

-- ---------------------------------------------------------------- the prize
-- Forward declaration: the escape has to happen inside the grab, and the pen
-- helpers are defined below it.
local goToPen

local function carriedAnimal()
    local ch = character()
    if not ch then return nil end
    for _, c in ipairs(ch:GetChildren()) do
        if c:IsA("Model") and c:GetAttribute("OriginalName") then return c end
    end
    return nil
end

-- Ours is the one whose BrokenBy matches, and it has to still be lying in the
-- world rather than already riding on somebody's back.
local function myPrize()
    local spawning = workspace.Gameplay and workspace.Gameplay:FindFirstChild("Spawning")
    for _, p in ipairs(CollectionService:GetTagged("PrizeTimer")) do
        if p:GetAttribute("BrokenBy") == plr.UserId
           and spawning and p:IsDescendantOf(spawning) then
            return p
        end
    end
    return nil
end

local function grabPrize(timeout)
    local deadline = os.clock() + (timeout or 6)
    local prize
    repeat
        prize = myPrize()
        if not prize then task.wait(0.2) end
    until prize or os.clock() > deadline
    if not prize then return nil end

    local pp = prize:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not pp then return nil end

    -- Position gated at 10 studs. The old build pinned the root part on the
    -- prize every Heartbeat, which is teleport spam on top of the warp that got
    -- it there - walking in is both safe and enough.
    local pos = prize:GetPivot().Position
    if not walkTo(pos, 5, 25) then
        note("could not walk to the prize")
        return nil
    end
    task.wait(0.3)
    pcall(function() fireproximityprompt(pp) end)

    -- STANDING AROUND AFTER THE GRAB IS WHAT LOSES THE ANIMAL. The bosses roam
    -- this field and a hit is 50 knockback plus 1.5s of Limp, so the pin has to
    -- release the FRAME the animal is in hand rather than after a flat wait -
    -- and the caller leaves for the pen immediately, in the same cycle.
    local held
    local deadline2 = os.clock() + 1.5
    repeat
        held = carriedAnimal()
        if not held then RunService.Heartbeat:Wait() end
    until held or os.clock() > deadline2

    if held then
        STATE.lastAnimal = tostring(held:GetAttribute("OriginalName"))
        -- LEAVE FIRST, DECIDE LATER. Everything that follows a grab - the pen
        -- census, the value floor, even the sale - is position-free, so none of
        -- it is worth doing while standing in a field the bosses patrol with
        -- the prize in your hands. The walk home is no longer instant, so it
        -- starts here rather than after the arithmetic.
        pcall(goToPen)
        return held
    end
    return nil
end

-- ------------------------------------------------------------------ the pen
local function myPen()
    if PenUtil and PenUtil.getPen then
        local ok, pen = pcall(PenUtil.getPen, plr)
        if ok and pen then return pen end
    end
    local active = workspace.Gameplay and workspace.Gameplay.Pens
        and workspace.Gameplay.Pens:FindFirstChild("ActivePens")
    return active and active:FindFirstChild("Pen_" .. plr.UserId) or nil
end

local function penPart()
    local pen = myPen()
    local enc = pen and pen:FindFirstChild("Enclosure")
    return enc and enc:FindFirstChild("PenPart"), enc, pen
end

-- Base income times the mutation multiplier, which is the RAW comparable figure
-- on both sides: a placed VisualItem and a carried one publish the same two
-- attributes, so a carried animal can be ranked against the pen directly. Never
-- compare this against plr.CashPerSecond, which is the multiplied total.
local function animalValue(model)
    if not model then return 0 end
    local nm  = model:GetAttribute("OriginalName")
    local cfg = nm and ItemConfig and ItemConfig.Items and ItemConfig.Items[nm]
    local base = cfg and tonumber(cfg.Income) or 0
    local mut = model:GetAttribute("Mutation")
    return base * ((mut and MUTATIONS[mut]) or 1)
end

local function penCensus()
    local _, enc = penPart()
    local items = enc and enc:FindFirstChild("Items")
    local used, cap = 0, (enc and enc:GetAttribute("Capacity")) or 0
    local list = {}
    if items then
        for _, slot in ipairs(items:GetChildren()) do
            local vi = slot:FindFirstChild("VisualItem")
            if vi then
                used = used + 1
                list[#list + 1] = {
                    slot = slot.Name,
                    name = vi:GetAttribute("OriginalName"),
                    rarity = vi:GetAttribute("Rarity"),
                    mutation = vi:GetAttribute("Mutation"),
                    x = slot:GetAttribute("X"), z = slot:GetAttribute("Z"),
                    radius = slot:GetAttribute("Radius"),
                    value = animalValue(vi),
                }
            end
        end
    end
    return used, cap, list
end

-- Existing placements publish X/Z/Radius, which is exactly what the game's own
-- overlap check reads. Walk a ring outwards from the middle until a spot clears.
local function freeSpot(radius)
    local part = penPart()
    if not part then return nil end
    radius = radius or (PenConfig and PenConfig.MIN_RADIUS) or 2

    local _, _, placed = penCensus()
    local spacing = (PenConfig and PenConfig.SPACING) or 0.5

    local function clashes(x, z)
        for _, p in ipairs(placed) do
            if p.x and p.z then
                local need = (p.radius or 2) + radius + spacing
                local dx, dz = x - p.x, z - p.z
                if (dx * dx + dz * dz) < (need * need) then return true end
            end
        end
        return false
    end

    local halfX = part.Size.X / 2
    local halfZ = part.Size.Z / 2
    local step  = math.max(3, radius * 2 + spacing)

    for z = -halfZ + step, halfZ - step, step do
        for x = -halfX + step, halfX - step, step do
            local cx, cz = x, z
            if PenConfig and PenConfig.ClampInsidePen then
                local ok, a, b = pcall(PenConfig.ClampInsidePen, part, x, z, radius)
                if ok and a and b then cx, cz = a, b end
            end
            if not clashes(cx, cz) then return cx, cz end
        end
    end
    return nil
end

-- Standing at the pen is enforced (PenConfig.StandsAtPen, 10 stud margin), so
-- the warp lands just outside the fence rather than in the middle of it.
function goToPen()
    local part = penPart()
    if not part then return false end
    -- Stand just outside the fence: PenConfig enforces a 10 stud margin for the
    -- placement, so arriving anywhere along the edge is close enough.
    local target = part.Position + Vector3.new(0, 0, -part.Size.Z / 2 - 5)
    return walkTo(target, 8, 45)
end

-- The sell vendor. SELLING IS POSITION GATED and that is easy to get wrong:
-- measured on one carry, a fire from 46 studs did nothing and the same fire
-- from 6 studs sold it. An earlier "it is not position gated" reading was a
-- coincidence - that test happened to run while the character was still parked
-- at the vendor from the previous probe.
local function vendorPos()
    local gp = workspace:FindFirstChild("Gameplay")
    local shops = gp and gp:FindFirstChild("Shops")
    local shop = shops and shops:FindFirstChild("SellShop")
    local vendor = shop and shop:FindFirstChild("Vendor")
    local head = vendor and vendor:FindFirstChild("Head")
    local anchor = head and head:FindFirstChild("PromptPoint")
    if anchor then
        if anchor:IsA("BasePart") then return anchor.Position end
        if anchor:IsA("Attachment") then return anchor.WorldPosition end
    end
    return shop and shop:GetPivot().Position or nil
end

local function goToVendor()
    local pos = vendorPos()
    if not pos then return false end
    return walkTo(pos, 8, 40)
end

-- "Equipped" is the only argument this game's own SellController ever sends,
-- and it reaches nothing but the animal in hand - the pen was byte-identical
-- across a verified sale. Do not widen it.
local function sellCarried()
    local held = carriedAnimal()
    if not held then return false end
    local name = tostring(held:GetAttribute("OriginalName"))

    -- Stand at the vendor first, or the remote is silently ignored and the loop
    -- retries forever WHILE HOLDING THE ANIMAL in the middle of the field.
    goToVendor()

    -- Income keeps ticking while we measure, so the balance alone cannot
    -- confirm a sale. The hands emptying is the honest signal.
    local before = money()
    pcall(function() Events.RequestSell:FireServer("Equipped") end)
    task.wait(1.0)

    if carriedAnimal() then return false end
    STATE.sold   = STATE.sold + 1
    STATE.earned = STATE.earned + math.max(0, money() - before - cps())
    note(("sold %s (pen is full)"):format(name))
    return true
end

local function placeCarried()
    local held = carriedAnimal()
    if not held then return false end

    local used, cap, placed = penCensus()
    if cap > 0 and used >= cap then
        -- Nothing can be pulled off a placement, so a full pen has exactly one
        -- productive move left: turn the catch into cash for the pen upgrade.
        if CONFIG.autoSell then return sellCarried() end
        note(("pen full (%d/%d) - turn on selling or upgrade the pen"):format(used, cap))
        return false
    end

    -- A SLOT IS PERMANENT, so the last few are worth being picky about. While
    -- the pen is mostly empty anything beats an empty slot, but once it is
    -- nearly full a slot spent on something worse than the current floor is
    -- spent forever - there is no evicting it later.
    local free = cap - used
    if cap > 0 and free <= CONFIG.pickyBelow and #placed > 0 then
        local weakest = math.huge
        for _, p in ipairs(placed) do
            if (p.value or 0) < weakest then weakest = p.value or 0 end
        end
        local mine = animalValue(held)
        if mine < weakest then
            note(("%s (%s/s raw) is below the pen floor %s - sold, %d slots left"):format(
                STATE.lastAnimal, fmt(mine), fmt(weakest), free))
            if CONFIG.autoSell then return sellCarried() end
            return false
        end
    end

    if not goToPen() then return false end

    local radius = (PenConfig and PenConfig.MIN_RADIUS) or 2
    local x, z = freeSpot(radius)
    if not x then note("no free spot in the pen") return false end

    local before = cps()
    pcall(function() Events.RequestPlaceItem:FireServer(x, z, 0) end)
    task.wait(1.2)

    if not carriedAnimal() then
        STATE.placed   = STATE.placed + 1
        STATE.lastGain = cps() - before
        note(("placed %s  +%s/s"):format(STATE.lastAnimal, fmt(STATE.lastGain)))
        return true
    end
    return false
end

-- --------------------------------------------------------------- farm cycle
local function farmCycle()
    if not alive() then STATE.phase = "dead" return end

    -- Deliver first. A carry left on the character blocks the next pickup, and
    -- the prize we would break for expires in 30 seconds either way.
    if carriedAnimal() then
        STATE.phase = "deliver"
        if CONFIG.autoPlace then placeCarried() end
        return
    end

    -- A prize already lying out there is free money - grab it before mining,
    -- then get straight out of the field with it.
    if myPrize() then
        STATE.phase = "grab"
        if grabPrize(2) then
            STATE.phase = "deliver"
            if CONFIG.autoPlace then placeCarried() end
        end
        return
    end

    -- A full pen no longer stops the farm: with selling on, every further catch
    -- becomes cash, and cash is what buys the next four slots.
    local used, cap = penCensus()
    if cap > 0 and used >= cap and not CONFIG.autoSell then
        STATE.phase = "pen full"
        note(("pen full (%d/%d) - turn on selling or upgrade the pen"):format(used, cap))
        return
    end

    local egg = bestEgg()
    if not egg then
        STATE.phase = "waiting"
        STATE.skipped = STATE.skipped + 1
        note("no egg matches the filter right now")
        return
    end

    STATE.phase = "mining"
    if breakEgg(egg) then
        STATE.phase = "grab"
        -- The egg can also have been finished off by another player standing on
        -- it, which looks identical from here - the egg is gone either way and
        -- only the missing prize tells the difference.
        if grabPrize(6) then
            -- Leave in the same cycle. Waiting for the next tick is ~0.4s of
            -- standing still in a field the bosses patrol, and a boss hit costs
            -- the animal.
            STATE.phase = "deliver"
            if CONFIG.autoPlace then placeCarried() end
        else
            STATE.stolen = STATE.stolen + 1
        end
    end
end

-- ------------------------------------------------------------- free pickups
local function claimDaily()
    if plr:GetAttribute("DailyRewardCanClaim") ~= true then return false end
    local day = plr:GetAttribute("DailyRewardRewardDay")
    pcall(function() Events.DailyRewardClaim:FireServer(day) end)
    task.wait(0.6)
    return plr:GetAttribute("DailyRewardCanClaim") ~= true
end

-- Verified 2026-09-16: capacity 10 -> 14 for $1M. Capacity is the confirmation,
-- never the balance - income keeps ticking while the call is in flight.
local function penUpgrade()
    local _, cap = penCensus()
    local before = money()
    pcall(function() Events.RequestBaseUpgrade:FireServer() end)
    task.wait(1.2)
    local _, capAfter = penCensus()
    if capAfter > cap then
        note(("pen upgraded, capacity %d -> %d"):format(cap, capAfter))
        return true
    end
    if money() < before * 0.9 then note("pen upgrade charged but capacity did not move") end
    return false
end

-- ------------------------------------------------------------- loop driver
local function loop(period, key, fn)
    task.spawn(function()
        while _G.__BREAKEGG == GEN do
            if CONFIG[key] and STATE.running then
                local ok, err = pcall(fn)
                if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
            end
            task.wait(period)
        end
    end)
end

loop(0.4, "autoFarm",      farmCycle)
loop(12,  "autoPickaxe",   function() buyPickaxe() end)
loop(30,  "autoPenUpgrade",function() penUpgrade() end)
loop(120, "autoDaily",     function() claimDaily() end)

-- ------------------------------------------------------------------ panel
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__BREAKEGG_WIN then pcall(function() _G.__BREAKEGG_WIN:Destroy() end) end
if UI.sweep then UI.sweep("BREAKEGG_PANEL") end

UI.config("breakegg", CONFIG)

local win = UI.Window({
    title = "BREAK", accentTitle = "AN EGG", subtitle = "seltonmt",
    badge = "*", width = 920, height = 580, name = "BREAKEGG_PANEL",
})
_G.__BREAKEGG_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local cFarm = farm:Card("EGG LOOP", 1):Accent()
cFarm:Toggle("Auto farm", CONFIG.autoFarm, function(v)
    CONFIG.autoFarm = v
    STATE.running = v or STATE.running
end, "break the best egg, carry the animal home, drop it in the pen")

cFarm:Toggle("Auto place", CONFIG.autoPlace, function(v) CONFIG.autoPlace = v end,
    "seat what was carried home")
cFarm:Toggle("Prefer mutated eggs", CONFIG.preferMutated, function(v) CONFIG.preferMutated = v end,
    "a mutation multiplies the payout up to 10x and is readable before breaking",
    UI.theme.good)

cFarm:Dropdown("Smallest egg", SIZE_ORDER, CONFIG.minSize, function(v) CONFIG.minSize = v end)
cFarm:Slider("Max swings", 10, 800, CONFIG.maxSwings, function(v) CONFIG.maxSwings = math.floor(v) end,
    "an egg that needs more than this is left alone")
-- In milliseconds: the slider hands back whole numbers, and a swing rate that
-- silently rounded to 0 would spin the loop.
cFarm:Slider("Swing rate (ms)", 150, 600, math.floor(CONFIG.swingRate * 1000),
    function(v) CONFIG.swingRate = math.floor(v) / 1000 end)

local cSpend = farm:Card("SPEND", 2)
cSpend:Toggle("Sell when the pen is full", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
    "RequestSell(\"Equipped\") - only ever the animal in hand, never the pen",
    UI.theme.good)
cSpend:Slider("Get picky with N slots left", 0, 8, CONFIG.pickyBelow,
    function(v) CONFIG.pickyBelow = math.floor(v) end,
    "a placed animal can never be taken back, so save the last slots for upgrades")
cSpend:Toggle("Buy pickaxes", CONFIG.autoPickaxe, function(v) CONFIG.autoPickaxe = v end,
    "buys the best affordable tier outright - the ladder can be skipped",
    UI.theme.good)
cSpend:Toggle("Upgrade the pen", CONFIG.autoPenUpgrade, function(v) CONFIG.autoPenUpgrade = v end,
    "$1M for +4 permanent slots, to a ceiling of 26 - the only way a full pen grows",
    UI.theme.good)
cSpend:Toggle("Daily reward", CONFIG.autoDaily, function(v) CONFIG.autoDaily = v end)

cSpend:Button("Buy best pickaxe now", function()
    task.spawn(function()
        if not buyPickaxe() then note("nothing better is affordable") end
    end)
end)
cSpend:Button("Place carried now", function()
    task.spawn(function()
        if not placeCarried() then note("nothing carried, or the pen is full") end
    end)
end)
cSpend:Button("Go to pen", function() task.spawn(goToPen) end)

local cStatus = farm:Card("STATUS", 0)
local out = cStatus:Readout(11)

task.spawn(function()
    while _G.__BREAKEGG == GEN do
        local used, cap, placed = penCensus()
        local egg, score = bestEgg()

        local weakest, weakestName = math.huge, "-"
        for _, p in ipairs(placed) do
            if (p.value or 0) < weakest then weakest, weakestName = p.value or 0, tostring(p.name) end
        end
        if weakest == math.huge then weakest, weakestName = 0, "-" end

        win:SetStatus(("%s$   %s/s   pen %d/%d   power %d"):format(
            fmt(money()), fmt(cps()), used, cap, power()))
        pcall(function()
            win:SetStat(1, fmt(money()), "money")
            win:SetStat(2, fmt(cps()), "per second")
            win:SetStat(3, tostring(power()), "pickaxe power")
        end)

        local nextTier = bestAffordablePickaxe()

        out:set({
            "FARM",
            ("  phase %s   broken %d   placed %d   sold %d   lost %d   failed %d"):format(
                STATE.phase, STATE.broken, STATE.placed, STATE.sold, STATE.stolen, STATE.failed),
            "  target " .. tostring(STATE.target),
            ("  last %s  (+%s/s)"):format(STATE.lastAnimal, fmt(STATE.lastGain)),
            "EGGS",
            (egg
                and ("  best now: %s%s, %d swings, %d studs away"):format(
                    tostring(egg:GetAttribute("SizeTier")),
                    egg:GetAttribute("Mutation") and (" " .. egg:GetAttribute("Mutation")) or "",
                    swingsFor(egg),
                    (function()
                        local _, hrp = character()
                        return hrp and math.floor((egg:GetPivot().Position - hrp.Position).Magnitude) or 0
                    end)())
                or  "  best now: none passes the filter"),
            ("  carrying %s"):format(carriedAnimal() and STATE.lastAnimal or "-"),
            "PEN",
            ("  %d of %d slots used%s"):format(used, cap,
                (cap > 0 and used >= cap) and "  - full, catches are being sold" or ""),
            ("  floor: %s at %s/s raw%s"):format(weakestName, fmt(weakest),
                (cap > 0 and (cap - used) <= CONFIG.pickyBelow)
                    and "  (picky: a catch must beat it)" or ""),
            (nextTier
                and ("  next pickaxe: %s, power %d, %s"):format(
                    nextTier.Name, nextTier.Power, fmt(nextTier.Price))
                or  "  next pickaxe: nothing better affordable"),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        win:Refresh()
        task.wait(0.5)
    end
end)

pcall(function()
    win:SetMaster(CONFIG.autoFarm, "Auto Farm läuft")
    win:OnMaster(function(on)
        CONFIG.autoFarm = on
        STATE.running = on or STATE.running
    end)
end)

STATE.running = true

-- --------------------------------------------------------------- debug hook
_G.__BREAKEGG_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    farmCycle = farmCycle, breakEgg = breakEgg, bestEgg = bestEgg,
    eggScore = eggScore, eggRate = eggRate, swingsFor = swingsFor, eggHp = eggHp,
    eggAim = eggAim, approachEgg = approachEgg,
    walkTo = walkTo, faceTowards = faceTowards, SIZE_VALUE = SIZE_VALUE,
    grabPrize = grabPrize, myPrize = myPrize, carriedAnimal = carriedAnimal,
    placeCarried = placeCarried, sellCarried = sellCarried,
    freeSpot = freeSpot, goToPen = goToPen,
    goToVendor = goToVendor, vendorPos = vendorPos,
    penCensus = penCensus, myPen = myPen, penPart = penPart,
    animalValue = animalValue,
    buyPickaxe = buyPickaxe, bestAffordablePickaxe = bestAffordablePickaxe,
    equipPickaxe = equipPickaxe, penUpgrade = penUpgrade, claimDaily = claimDaily,
    money = money, power = power, cps = cps, fmt = fmt,
    SIZE_RANK = SIZE_RANK, MUTATIONS = MUTATIONS,
}

pcall(function() win:Home() end)

print("[breakegg] loaded - gen " .. GEN .. ", RightShift for the panel")
