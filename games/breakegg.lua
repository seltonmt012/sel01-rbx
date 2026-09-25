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
    teleports, and CFrame is written only for ROTATION, where the displacement
    is zero. WalkSpeed is raised empty-handed (tested to 50, no kick); while
    carrying, the server holds its own ~19.5 and pulls a faster carry back, so
    the carry speed is learned down from x1.2 (see the speed section).

    REVISED 2026-09-25 - several notes further down were wrong and are
    corrected where they stand:
      * the pen is NOT one-way: PenAction("Unequip", "<id>") takes an animal
        out, PenAction("EquipBest") seats the best from the hotbar;
      * animals not in the pen are Tools in the Backpack (the hotbar);
      * value is IncomeConfig.BaseRate (size, kg, mutation, trait), not
        base x mutation - that rating sold better animals than it kept;
      * the bosses only hunt a carrier, and the prize timer only runs inside
        Gameplay.Zones.CollectionZone.

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
      * THE PEN IS NOT ONE-WAY (this note once said it was, and that cost
        animals). The pen itself has no prompt, but the ActivePets panel
        ("14/14 Active") in ActivePetsController has an Unequip button per row
        and an Equip Best button - see placeCarried. A full pen swaps: a catch
        better than the weakest placed animal replaces it, the weakest is sold.
      * A FULL PEN IS NOT A DEAD END, it is a cash engine: keep breaking eggs
        and sell every catch that does not beat the pen, which funds the pen
        upgrade and its four slots.

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
    autoSwap        = true,      -- full pen: a better catch replaces the weakest
    autoPickaxe     = true,
    pickaxeReserve  = 0.0,       -- keep this fraction of the balance back
    autoPenUpgrade  = true,      -- verified: capacity 10 -> 14 for $1M
    autoDaily       = true,
    -- renamed from ghostEggs so a saved "true" from the first build is dropped
    eggNoclip       = false,     -- walk through egg shells - OFF: the server pulls you back
    speedBoost      = true,      -- WalkSpeed override, see the movement section
    walkSpeed       = 45,
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
    swapped   = 0,
    knocked   = 0,
    expired   = 0,
    snaps     = 0,     -- server pull-backs seen
    carryFactor = 1.2, -- carry speed over the game's own, learned down on pull-backs
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
--
-- THE BOSSES ARE WHAT LOSES THE ANIMAL, and walking in a straight line walked
-- right into them. Measured 2026-09-25: workspace.Gameplay.Bosses holds the big
-- rotation boss (Cerberus is 31x58 studs) plus two minis (Tiger, Fenrir, ~14
-- long). A hit is 50 knockback and 1.5s of Limp and the carried animal falls
-- off. They chase at 23 (minis 20); a carry walks near 19.5. What worked and
-- what did not is written up at steerAround - the short version is that they
-- only hunt a carrier, running away never wins, and only walking INTO one loses.
local BOSS_MARGIN = 16   -- studs of air kept between us and a boss's body
local BOSS_LEAD   = 0.8  -- seconds of boss movement to aim the avoidance at

local function flat(v) return Vector3.new(v.X, 0, v.Z) end

-- boss model -> {pos, t}, for the velocity estimate; weak so a rotated-out boss goes
local lastSeen = setmetatable({}, { __mode = "k" })

local function bosses()
    local out = {}
    local gp = workspace:FindFirstChild("Gameplay")
    local f  = gp and gp:FindFirstChild("Bosses")
    if not f then return out end
    local now = os.clock()
    for _, b in ipairs(f:GetChildren()) do
        if b:IsA("Model") then
            local ok, cf, size = pcall(function() return b:GetBoundingBox() end)
            if ok and cf and size then
                local pos, vel = cf.Position, Vector3.zero
                local prev = lastSeen[b]
                if prev and now - prev.t > 0.05 and now - prev.t < 1 then
                    vel = flat(pos - prev.pos) / (now - prev.t)
                    -- nothing here moves faster than the 45 stud/s retreat
                    if vel.Magnitude > 60 then vel = Vector3.zero end
                end
                if not prev or now - prev.t > 0.05 then lastSeen[b] = { pos = pos, t = now } end
                out[#out + 1] = {
                    name = b.Name, pos = pos, vel = vel,
                    ahead = pos + vel * BOSS_LEAD,
                    danger = math.max(size.X, size.Z) / 2 + BOSS_MARGIN,
                }
            end
        end
    end
    return out
end

-- The boss whose danger zone `pos` sits deepest inside (grown by `extra`).
local function bossNear(pos, extra)
    local worst, depth
    for _, b in ipairs(bosses()) do
        local r = b.danger + (extra or 0)
        local d = flat(pos - b.pos).Magnitude
        if d < r and ((not depth) or (r - d) > depth) then worst, depth = b, r - d end
    end
    return worst, depth
end

-- THE BOSSES ONLY HUNT A CARRIER. With empty hands they wander past and never
-- aggro (the user watched it, 2026-09-25), so every stud spent avoiding them on
-- the way OUT was wasted - the character circled and never reached its egg.
-- Steering therefore only happens while an animal is in hand.
local function holding()
    local ch = plr.Character
    if not ch then return false end
    for _, c in ipairs(ch:GetChildren()) do
        -- a catch from the field is a Model, one out of the hotbar a Tool
        if (c:IsA("Model") or c:IsA("Tool")) and c:GetAttribute("OriginalName") then return true end
    end
    return false
end

-- A sub-goal that takes the next stretch of the way home PAST every boss in
-- it, or nil when the way is clear.
--
-- NEVER AWAY FROM HOME. Every earlier version pushed the heading away from the
-- boss, and away from the boss was, often enough, away from the base: the user
-- watched the character get herded into corners and walls and lose the timer.
-- A carry is not faster than a boss (the server holds it near 19.5 against
-- their 23), so running away never wins anyway - only not walking INTO one
-- does. So:
--   * a boss (now, or where it will be in BOSS_LEAD) whose body comes within
--     10 studs of the next 60 studs of the line home is IN THE WAY;
--   * it is passed on the side that makes the shorter total trip - a point
--     beside it, danger + 25 out, perpendicular to the line home - and a side
--     with a wall in the way is not taken;
--   * a boss behind us is ignored: walking home is the best move there is.
local function blocked(here, heading, len)
    local ch = plr.Character
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local skip = { ch }
    local gp = workspace:FindFirstChild("Gameplay")
    if gp then
        for _, n in ipairs({ "Spawning", "Bosses" }) do
            local f = gp:FindFirstChild(n)
            if f then skip[#skip + 1] = f end
        end
    end
    params.FilterDescendantsInstances = skip
    params.RespectCanCollide = true
    return workspace:Raycast(here + Vector3.new(0, 0.5, 0), heading * len, params) ~= nil
end

local function steerAround(here, goal)
    if not holding() then return nil end
    local toGoal = flat(goal - here)
    local dist = toGoal.Magnitude
    if dist < 2 then return nil end
    local dir = toGoal.Unit
    local look = math.min(dist, 60)

    local worst, worstGap
    for _, b in ipairs(bosses()) do
        for _, c in ipairs({ b.pos, b.ahead }) do
            local rel = flat(c - here)
            if rel:Dot(dir) > -5 then                    -- not behind us
                local t = math.clamp(rel:Dot(dir), 0, look)
                local gap = (rel - dir * t).Magnitude - (b.danger + 10)
                if gap < 0 and ((not worstGap) or gap < worstGap) then
                    worst, worstGap = b, gap
                end
            end
        end
    end
    if not worst then return nil end

    local perp = Vector3.new(-dir.Z, 0, dir.X)
    local best, bestCost
    for _, s in ipairs({ 1, -1 }) do
        local c = worst.pos + perp * s * (worst.danger + 25)
        local leg = flat(c - here)
        local cost = leg.Magnitude + flat(goal - c).Magnitude
        if leg.Magnitude > 0.1 and blocked(here, leg.Unit, math.min(leg.Magnitude, 30)) then
            cost = cost + 1000
        end
        if (not bestCost) or cost < bestCost then best, bestCost = c, cost end
    end
    local leg = flat(best - here)
    if leg.Magnitude < 4 then return nil end
    return here + leg.Unit * math.min(leg.Magnitude, 16)
end

-- STUCK IS DETECTED, never waited out. The old loop re-issued MoveTo every
-- 0.2s for up to 45s, so a character pressed against an egg shell or a fence
-- just ran in place for the whole timeout - in the field, next to the bosses.
-- No progress for STUCK_AFTER seconds means jump and sidestep, alternating
-- sides; after STUCK_TRIES of those the walk gives up and the cycle moves on.
local STUCK_AFTER, STUCK_TRIES = 1.2, 5

-- A PATH, NOT A STRAIGHT LINE. The straight MoveTo walked into the sell booth
-- through its open side (the vendor's head was the target) and never found the
-- way out again - measured 2026-09-25, five cycles in a row of "could not walk
-- to the egg" from inside the booth. PathfindingService plans around booths,
-- fences and plants; the boss steering and the stuck check sit on top of it,
-- and either of them firing throws the plan away and asks for a new one.
local PathfindingService = game:GetService("PathfindingService")

local function planPath(from, to)
    local path = PathfindingService:CreatePath({
        AgentRadius = 2.5, AgentHeight = 5.5,
        AgentCanJump = true, AgentCanClimb = false, WaypointSpacing = 6,
    })
    local ok = pcall(function() path:ComputeAsync(from, to) end)
    if not ok then return nil end
    local st = path.Status
    if st == Enum.PathStatus.Success or st == Enum.PathStatus.ClosestNoPath then
        local wps = path:GetWaypoints()
        if #wps >= 2 then return wps end
    end
    return nil
end

local function walkTo(pos, arriveDist, timeout)
    local _, hrp, hum = character()
    if not (hrp and hum) then return false end
    arriveDist = arriveDist or 6
    timeout    = timeout or 30

    local t0 = os.clock()
    local bestDist, lastProgress = math.huge, os.clock()
    local unsticks, side = 0, 1
    local wps, wi, detoured
    local lastDetour, detourUntil
    -- A walk that began with an animal in hand ends the moment it is gone:
    -- that is a boss hit, the animal lies behind us as ours on its timer, and
    -- walking on to the pen empty-handed only wastes that timer.
    local carrying = holding()

    -- Targets are often a body's middle (an egg) or a head (a vendor); plan to
    -- the ground under them at our own height, the arrive check stays 3D.
    local function replan()
        local here = hrp.Position
        wps = planPath(here, Vector3.new(pos.X, here.Y, pos.Z))
        wi = 2
        bestDist, lastProgress = math.huge, os.clock()
    end
    replan()

    while os.clock() - t0 < timeout do
        if _G.__BREAKEGG ~= GEN then return false end
        if not alive() then return false end
        local here = character() and hrp.Position
        if not here then return false end
        if (here - pos).Magnitude <= arriveDist then return true end
        if carrying and not holding() then
            STATE.knocked = (STATE.knocked or 0) + 1
            note("hit - the animal fell, going back for it")
            return false
        end

        -- The next waypoint, skipping the ones already reached.
        local sub = pos
        if wps then
            while wps[wi] and flat(wps[wi].Position - here).Magnitude < 3.5 do
                wi = wi + 1
                bestDist = math.huge
            end
            local wp = wps[wi]
            if wp then
                sub = wp.Position
                if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
            end
        end

        -- HOLD A DETOUR FOR A MOMENT. Re-deciding every 0.2s flipped the
        -- heading back and forth whenever a boss sat on the edge of range,
        -- which read as the character turning round for no reason.
        local detour = steerAround(here, sub)
        if detour then
            lastDetour, detourUntil = detour - here, os.clock() + 0.7
        elseif detourUntil and os.clock() < detourUntil and lastDetour then
            detour = here + lastDetour
        end
        hum:MoveTo(detour or sub)

        local dist = flat(sub - here).Magnitude
        if detour then
            -- Holding off or circling a boss is not being stuck, but the old
            -- plan is stale once we have been pushed off it.
            detoured = true
            bestDist, lastProgress = dist, os.clock()
        elseif detoured then
            detoured = false
            replan()
        elseif dist < bestDist - 1 then
            bestDist, lastProgress = dist, os.clock()
        elseif os.clock() - lastProgress > STUCK_AFTER then
            unsticks = unsticks + 1
            if unsticks > STUCK_TRIES then
                note("stuck - gave up this walk")
                return false
            end
            local fwd = flat(sub - here)
            fwd = fwd.Magnitude > 0.1 and fwd.Unit or Vector3.new(1, 0, 0)
            hum.Jump = true
            hum:MoveTo(here + Vector3.new(-fwd.Z, 0, fwd.X) * side * 10 - fwd * 3)
            side = -side
            task.wait(0.6)
            replan()
        end
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

-- THE EGG FIELD IS THE OBSTACLE COURSE. 57 eggs lie around at any time and the
-- big ones are 12 studs across, so a straight walk home kept pressing into a
-- shell - that is where the character stood still while a boss walked up.
-- CanCollide is flipped on OUR client only: the character's physics is ours, so
-- it walks through, while nobody else's game changes. The pickaxe's raycast
-- reads CanQuery, not CanCollide, so mining is untouched. Walls, fences and the
-- floor are left alone - only children of Gameplay.Eggs.
--
-- AND IT IS OFF BY DEFAULT, because the server disagrees. The shells are
-- still solid on the server, the movement check reads walking through one as
-- noclip, and it pulled the character back to one fixed spot over and over
-- (measured 2026-09-25, 111 studs a time, a 22K/s Roc lost to its timer that
-- way). Pathfinding walks round the shells instead.
-- The prizes lying in the field (Spawning.ItemSpawners) are ghosted too, so a
-- dropped animal is no wall either.
local ghosted = setmetatable({}, { __mode = "k" })
local function ghostFolders()
    local out = { eggFolder() }
    local gp = workspace:FindFirstChild("Gameplay")
    local sp = gp and gp:FindFirstChild("Spawning")
    if sp then out[#out + 1] = sp end
    return out
end
local function ghostPart(p, on)
    if not p:IsA("BasePart") then return end
    if on and p.CanCollide then
        ghosted[p] = true
        p.CanCollide = false
    elseif not on and ghosted[p] then
        ghosted[p] = nil
        p.CanCollide = true
    end
end
local function ghostEggs(on)
    for _, folder in ipairs(ghostFolders()) do
        for _, p in ipairs(folder:GetDescendants()) do ghostPart(p, on) end
    end
end

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
local travelHome  -- seconds a carry needs from a point to the pen, set below

local function carriedAnimal()
    local ch = character()
    if not ch then return nil end
    for _, c in ipairs(ch:GetChildren()) do
        if (c:IsA("Model") or c:IsA("Tool")) and c:GetAttribute("OriginalName") then return c end
    end
    return nil
end

-- Ours is the one whose BrokenBy matches, and it has to still be lying in the
-- world rather than already riding on somebody's back.
-- A prize given up on (its timer cannot cover the walk out) is remembered by
-- Uid, or the next cycle picks the same one again and stands there until it
-- dies - which is exactly what the user watched beside a Giraffe.
local givenUp = {}
local function myPrize()
    local spawning = workspace.Gameplay and workspace.Gameplay:FindFirstChild("Spawning")
    for _, p in ipairs(CollectionService:GetTagged("PrizeTimer")) do
        if p:GetAttribute("BrokenBy") == plr.UserId
           and not givenUp[p:GetAttribute("Uid") or p]
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

    -- WALK TO THE PROMPT, NOT THE MODEL. A Giraffe's pivot sits 13 studs up in
    -- its neck, so "within 5 studs of the pivot" was never true while the
    -- character stood right beside it with the Pick Up prompt 4 studs away -
    -- 25 seconds of "could not walk to the prize" per try. The prompt hangs on
    -- a PickupAnchor attachment at body height and reaches its own
    -- MaxActivationDistance (13.15 on that Giraffe).
    local pos = prize:GetPivot().Position
    local anchor = pp.Parent
    local promptPos = (anchor and anchor:IsA("Attachment") and anchor.WorldPosition)
        or (anchor and anchor:IsA("BasePart") and anchor.Position) or pos
    local reach = math.clamp((pp.MaxActivationDistance or 10) - 3, 3, 10)

    -- PICKING UP IS WHAT AGGROS THEM. A prize lying next to a boss was grabbed
    -- anyway and the hit landed a second later (Cerberus, 2026-09-25, twice).
    -- Empty-handed we are ignored, and the prize waits until ExpiresAt (server
    -- time, ~50s out), so hold off beside it until the boss wanders away - and
    -- only take the chance anyway when the timer is nearly out. The same holds
    -- for a carry knocked out of our hands: it lies there as ours, on a timer.
    --
    -- THE TIMER KEEPS RUNNING IN YOUR HANDS - ExpiresAt is a delivery deadline,
    -- not a pickup one. A 22K/s Roc was waited on for 20s beside a Lion and then
    -- had 31s left for a 480-stud walk home; it died in hand. So the wait ends
    -- once the timer only just covers the walk home, and a prize that can no
    -- longer make it home at all is left alone.
    local expires = tonumber(prize:GetAttribute("ExpiresAt"))
    local function left()
        return expires and (expires - workspace:GetServerTimeNow()) or 60
    end
    local need = travelHome(pos)
    if left() < need then
        note(("%s cannot make it out of the zone (%ds left, ~%ds walk) - left it"):format(
            tostring(prize:GetAttribute("OriginalName")), math.floor(left()), math.floor(need)))
        STATE.expired = STATE.expired + 1
        givenUp[prize:GetAttribute("Uid") or prize] = true
        return nil
    end
    -- Walking past it while holding off picks it up by touch - then it is ours
    -- and the wait is over (it kept waiting with a Golden Giraffe in hand).
    while prize.Parent and not holding() do
        -- ~60 studs clear of its body: 41 still drew an instant charge
        local b = bossNear(pos, 45)
        if not b then break end
        if left() < need + 6 then break end
        note(("waiting for the %s to leave the prize (%ds left, ~%ds walk home)"):format(
            b.name, math.floor(left()), math.floor(need)))
        local away = flat(pos - b.pos)
        away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
        walkTo(b.pos + away * (b.danger + 55), 6, 1.5)
        task.wait(0.2)
        if _G.__BREAKEGG ~= GEN then return nil end
    end
    if not holding() then
        if not prize.Parent then return nil end
        if not walkTo(promptPos, reach, 25) then
            note("could not walk to the prize")
            return nil
        end
        task.wait(0.2)
        -- The prompt has a 0.4s hold; fireproximityprompt skips it, but a
        -- second try costs nothing if the first did not take.
        for _ = 1, 3 do
            pcall(function() fireproximityprompt(pp) end)
            local t0 = os.clock()
            while not holding() and os.clock() - t0 < 0.6 do task.wait(0.05) end
            if holding() or not pp.Parent then break end
        end
    end

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
--
-- SIZE AND WEIGHT ARE HALF THE VALUE, and leaving them out sold the better
-- animal: a Small Muscovy Duck pays 8.4/s and a Huge one 53/s, and base times
-- mutation rated them the same. IncomeConfig.BaseRate(name, mutation, size,
-- rate, kg, trait) is the game's own figure - it matched the ActivePets list
-- (PenListUpdate Rows.Income) on all 14 placements to the last decimal, on the
-- carried animal and the placed ones alike.
local function animalValue(model)
    if not model then return 0 end
    local a = model:GetAttributes()
    if IncomeConfig and IncomeConfig.BaseRate and a.OriginalName then
        local ok, v = pcall(IncomeConfig.BaseRate, a.OriginalName, a.Mutation,
            a.SizeTier, a.Rate, a.Kg, a.Trait)
        if ok and type(v) == "number" then return v end
    end
    local cfg = ItemConfig and ItemConfig.Items and ItemConfig.Items[a.OriginalName or ""]
    local base = cfg and tonumber(cfg.Income) or 0
    return base * ((a.Mutation and MUTATIONS[a.Mutation]) or 1)
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
                    -- Placement_<n>: <n> is the ActivePets row Id that
                    -- PenAction("Unequip", id) takes - as a STRING
                    id = slot.Name:match("(%d+)$"),
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
    -- a carry walks at the game's ~19.5, and the far end of the field is
    -- ~480 studs out, so 45s was not always enough
    return walkTo(target, 8, 75)
end

-- THE TIMER ONLY RUNS INSIDE THE COLLECTION ZONE. A carried Turtle lost its
-- ExpiresAt the moment it crossed the zone edge (z = +76.7) and was placed
-- 30s later; a Roc still inside the zone at z = +72 died at 0. So the deadline
-- is reaching the zone edge on the pen side, not the pen. Gameplay.Zones.
-- CollectionZone is the volume (315 x 528 x 456 studs). A carry walks at the
-- game's own speed (19.5 measured, heavier is slower) and a path is never the
-- straight line: 1.3x the distance plus the pickup.
travelHome = function(from)
    local part = penPart()
    local gp = workspace:FindFirstChild("Gameplay")
    local zones = gp and gp:FindFirstChild("Zones")
    local zone = zones and zones:FindFirstChild("CollectionZone")
    if not part then return 0 end
    local dist = flat(part.Position - from).Magnitude
    if zone then
        -- walk the straight line to the pen in 5-stud steps until outside
        local dir = flat(part.Position - from)
        dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.zero
        local d = 0
        while d < dist do
            local p = zone.CFrame:PointToObjectSpace(from + dir * d)
            local h = zone.Size / 2
            if math.abs(p.X) > h.X or math.abs(p.Z) > h.Z then break end
            d = d + 5
        end
        dist = d
    end
    local speed = 19.5 * STATE.carryFactor
    return dist * 1.3 / speed + 3
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

-- STAND IN FRONT OF THE COUNTER, never at the head. The vendor stands inside a
-- booth 8 studs behind its counter; walking at the head led into the booth
-- through its open side and the character was trapped there. The prompt
-- reaches 14 studs (SellShopPrompt.MaxActivationDistance), so 10 studs out
-- along the vendor's facing is outside the counter and still in range.
local function sellSpot()
    local pos = vendorPos()
    if not pos then return nil end
    local gp = workspace:FindFirstChild("Gameplay")
    local shop = gp and gp.Shops and gp.Shops:FindFirstChild("SellShop")
    local vendor = shop and shop:FindFirstChild("Vendor")
    local root = vendor and (vendor:FindFirstChild("HumanoidRootPart") or vendor:FindFirstChild("Head"))
    if not root then return pos end
    local look = flat(root.CFrame.LookVector)
    if look.Magnitude < 0.1 then return pos end
    return pos + look.Unit * 10, pos
end

local function goToVendor()
    local spot, head = sellSpot()
    if not spot then return false end
    if walkTo(spot, 4, 40) then return true end
    -- fall back to anywhere inside the prompt's reach
    return head and walkTo(head, 12, 10) or false
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

local function weakestPlaced(placed)
    local w
    for _, p in ipairs(placed) do
        if p.id and ((not w) or (p.value or 0) < (w.value or 0)) then w = p end
    end
    return w
end

-- THE PEN IS NOT ONE-WAY, AND THERE IS AN INVENTORY. The old notes said no
-- remote takes an animal back; both halves of that were wrong (2026-09-25):
--   * The ActivePets panel ("14/14 Active") has an Unequip button per row that
--     fires PenAction("Unequip", id) - id as a STRING, a number is silently
--     ignored, which is how it was missed. The animal comes off the pen.
--   * Animals that are not in the pen are TOOLS in the Backpack (the hotbar),
--     named "Turtle (522Kg)" and carrying the same attributes as a placed one.
--     Unequip while holding a catch puts the unequipped animal in your hand and
--     the catch in the Backpack - it looked like the catch was deleted, and the
--     user found it in slot 3.
--   * PenAction("EquipBest") is the game's own "Equip Best" button: it fills
--     the pen from the Backpack. Verified: Turtle out of the Backpack into the
--     free slot, CashPerSecond 8,263 -> 8,416.
--   * RequestDropItem is refused outside the field (CarryDroppable = false at
--     the pen), so dropping the catch there is not an option.
-- So the swap is: Unequip the weakest (catch -> Backpack, weakest -> hand),
-- EquipBest (the game seats the catch), then sell whatever animal is left in
-- the hand or the Backpack. The game decides the seating, we only decide what
-- is worth keeping.
local function petTools()
    local out = {}
    for _, holder in ipairs({ plr:FindFirstChild("Backpack"), plr.Character }) do
        if holder then
            for _, c in ipairs(holder:GetChildren()) do
                if c:IsA("Tool") and c:GetAttribute("OriginalName") then out[#out + 1] = c end
            end
        end
    end
    return out
end

local function equipBest()
    local before = cps()
    pcall(function() Events.PenAction:FireServer("EquipBest") end)
    task.wait(1.5)
    return cps() - before
end

-- Everything that is not in the pen gets sold, one at a time, at the vendor.
-- RequestSell("Equipped") sells the animal in hand, tool or carried.
local function sellInventory()
    local tools = petTools()
    if #tools == 0 then return 0 end
    goToVendor()
    local n = 0
    for _, t in ipairs(tools) do
        if _G.__BREAKEGG ~= GEN then break end
        local _, _, hum = character()
        if t.Parent and hum then
            if t.Parent ~= plr.Character then pcall(function() hum:EquipTool(t) end) task.wait(0.4) end
            local name, before = t.Name, money()
            pcall(function() Events.RequestSell:FireServer("Equipped") end)
            task.wait(0.9)
            if not t.Parent or t.Parent == nil or not t:IsDescendantOf(game) then
                n = n + 1
                STATE.sold = STATE.sold + 1
                STATE.earned = STATE.earned + math.max(0, money() - before - cps())
                note(("sold %s from the hotbar"):format(name))
            end
        end
    end
    return n
end

local function placeHere()
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

local function placeCarried()
    local held = carriedAnimal()
    if not held then return false end

    local used, cap, placed = penCensus()
    if cap > 0 and used >= cap then
        local mine = animalValue(held)
        local weak = weakestPlaced(placed)
        if CONFIG.autoSwap and weak and mine > (weak.value or 0) * 1.05 then
            if not goToPen() then return false end
            local newName = STATE.lastAnimal
            pcall(function() Events.PenAction:FireServer("Unequip", tostring(weak.id)) end)
            local t0 = os.clock()
            while penCensus() >= used and os.clock() - t0 < 3 do task.wait(0.1) end
            if penCensus() >= used then note("swap: unequip did nothing") return false end
            local gain = equipBest()
            STATE.swapped = STATE.swapped + 1
            note(("swapped %s %s/s in for %s %s/s (+%s/s)"):format(
                newName, fmt(mine), tostring(weak.name), fmt(weak.value or 0), fmt(gain)))
            if CONFIG.autoSell then sellInventory() end
            return true
        end
        if CONFIG.autoSell then
            note(("%s %s/s is not better than the weakest %s %s/s - sold"):format(
                STATE.lastAnimal, fmt(mine), tostring(weak and weak.name), fmt(weak and weak.value or 0)))
            return sellCarried()
        end
        note(("pen full (%d/%d) - turn on selling or upgrade the pen"):format(used, cap))
        return false
    end

    if not goToPen() then return false end
    return placeHere()
end

-- --------------------------------------------------------------- farm cycle
local function farmCycle()
    if not alive() then STATE.phase = "dead" return end

    -- Deliver first. A carry left on the character blocks the next pickup, and
    -- the prize we would break for expires in 30 seconds either way.
    local held = carriedAnimal()
    if held and held:IsA("Tool") then
        -- a hotbar animal in hand goes back to the Backpack; the hotbar step
        -- below seats it through Equip Best or sells it
        local _, _, hum = character()
        if hum then pcall(function() hum:UnequipTools() end) end
        task.wait(0.3)
    elseif held then
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

    -- Animals parked in the hotbar earn nothing. Let the game's Equip Best seat
    -- whatever beats the pen, then sell the rest - that is the hotbar the user
    -- kept finding animals in.
    if #petTools() > 0 then
        STATE.phase = "hotbar"
        if goToPen() then
            local gain = equipBest()
            if gain > 0 then note(("Equip Best from the hotbar  +%s/s"):format(fmt(gain))) end
        end
        if CONFIG.autoSell and #petTools() > 0 then sellInventory() end
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

-- Eggs keep spawning, so the ghosting is re-applied every second; switching it
-- off hands every shell we touched its collision back.
-- WALKSPEED: MEASURED BOTH WAYS, 2026-09-25.
--   * Empty-handed, 36 / 42 / 50 for 40s each against the game's 30: no kick.
--   * CARRYING, the SERVER sets 19.5 (it writes WalkSpeed itself - no client
--     script touches it - and a heavy animal is slower). Walking at 45 over
--     that got the character pulled back to one fixed spot again and again,
--     111 studs at a time, and finally set down at the base with the animal
--     gone. Most of that was the egg ghosting (see ghostEggs), but the server
--     clearly holds its own idea of our speed while carrying.
-- So empty-handed runs at walkSpeed, and a carry runs at the game's own value
-- times carryFactor, which starts a little above 1 and is LEARNED DOWN: every
-- pull-back seen while carrying costs 0.05 of it, never below 1.0.
-- The kick on record (Error Code 267) came from CFrame WARPS, so teleporting
-- stays out entirely.
local gameSpeed          -- the last value the GAME wrote
local writing = false
local function wantSpeed(hum)
    if not CONFIG.speedBoost then return gameSpeed end
    if holding() then
        local base = gameSpeed or hum.WalkSpeed
        return math.min(CONFIG.walkSpeed, base * STATE.carryFactor)
    end
    return CONFIG.walkSpeed
end
local function applySpeed(hum)
    if not hum then return end
    local want = wantSpeed(hum)
    if want and math.abs(hum.WalkSpeed - want) > 0.01 then
        writing = true
        hum.WalkSpeed = want
        writing = false
    end
end
task.spawn(function()
    local hooked
    while _G.__BREAKEGG == GEN do
        local _, _, hum = character()
        if hum and hum ~= hooked then
            hooked = hum
            gameSpeed = hum.WalkSpeed
            local conn
            conn = hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
                if _G.__BREAKEGG ~= GEN then conn:Disconnect() return end
                if writing then return end
                -- a write that is not ours is the game's: remember it, then
                -- answer in the same frame
                gameSpeed = hum.WalkSpeed
                applySpeed(hum)
            end)
        end
        applySpeed(hum)
        task.wait(0.1)
    end
    local _, _, hum = character()
    if hum and gameSpeed then hum.WalkSpeed = gameSpeed end
end)

-- PULL-BACK DETECTOR. A frame where the root part jumps more than 12 studs is
-- the server putting us back (nothing in this script moves the body by CFrame).
-- It is counted, shown on the panel, and while carrying it lowers carryFactor.
task.spawn(function()
    local last
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if _G.__BREAKEGG ~= GEN then conn:Disconnect() return end
        local _, hrp = character()
        if not hrp then last = nil return end
        local p = hrp.Position
        if last and flat(p - last).Magnitude > 12 then
            STATE.snaps = STATE.snaps + 1
            if holding() and STATE.carryFactor > 1 then
                STATE.carryFactor = math.max(1, STATE.carryFactor - 0.05)
                note(("pulled back by the server - carry speed x%.2f now"):format(STATE.carryFactor))
            end
        end
        last = p
    end)
end)

-- A fresh egg is ghosted the moment it appears, not up to a second later.
for _, folder in ipairs(ghostFolders()) do
    local conn
    conn = folder.DescendantAdded:Connect(function(p)
        if _G.__BREAKEGG ~= GEN then conn:Disconnect() return end
        if CONFIG.eggNoclip then
            task.defer(function() pcall(ghostPart, p, true) end)
        end
    end)
end
task.spawn(function()
    local was = false
    while _G.__BREAKEGG == GEN do
        local on = CONFIG.eggNoclip == true
        if on or was then pcall(ghostEggs, on) end
        was = on
        task.wait(1)
    end
    pcall(ghostEggs, false)
end)

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
cFarm:Toggle("Walk through eggs", CONFIG.eggNoclip, function(v) CONFIG.eggNoclip = v end,
    "risky: the server still sees the shells and pulls you back through them",
    UI.theme.bad)
cFarm:Toggle("Speed boost", CONFIG.speedBoost, function(v) CONFIG.speedBoost = v end,
    "walk faster than the bosses (they run 23) - tested to 50 without a kick",
    UI.theme.warn)
cFarm:Slider("Walk speed", 16, 60, CONFIG.walkSpeed, function(v) CONFIG.walkSpeed = math.floor(v) end)
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
cSpend:Toggle("Swap in better animals", CONFIG.autoSwap, function(v) CONFIG.autoSwap = v end,
    "full pen: the weakest comes out and is sold, the better catch goes in",
    UI.theme.good)
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
            ("  %d of %d slots used%s   swapped %d"):format(used, cap,
                (cap > 0 and used >= cap) and "  - full, a better catch swaps in" or "",
                STATE.swapped or 0),
            ("  weakest: %s at %s/s"):format(weakestName, fmt(weakest)),
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
    bosses = bosses, bossNear = bossNear, steerAround = steerAround, holding = holding,
    grabPrize = grabPrize, myPrize = myPrize, carriedAnimal = carriedAnimal,
    placeCarried = placeCarried, sellCarried = sellCarried,
    freeSpot = freeSpot, goToPen = goToPen,
    goToVendor = goToVendor, vendorPos = vendorPos, sellSpot = sellSpot,
    planPath = planPath, ghostEggs = ghostEggs,
    petTools = petTools, equipBest = equipBest, sellInventory = sellInventory,
    travelHome = travelHome, weakestPlaced = weakestPlaced,
    penCensus = penCensus, myPen = myPen, penPart = penPart,
    animalValue = animalValue,
    buyPickaxe = buyPickaxe, bestAffordablePickaxe = bestAffordablePickaxe,
    equipPickaxe = equipPickaxe, penUpgrade = penUpgrade, claimDaily = claimDaily,
    money = money, power = power, cps = cps, fmt = fmt,
    SIZE_RANK = SIZE_RANK, MUTATIONS = MUTATIONS,
}

pcall(function() win:Home() end)

print("[breakegg] loaded - gen " .. GEN .. ", RightShift for the panel")
