--[[
    findegg.lua - "[🥚] Find the Egg for a Brainrot"  place 114507117535918
    ------------------------------------------------------------------------
    Carry-and-place plot income with the field replaced by an OPEN MAP that
    runs north out of the village, and the progression gate moved into
    Endurance rather than money.

    The loop, as measured through the bridge on 2026-08-28:

      read every egg out of workspace.HuntSlots.HuntSlot_<n> - RarityId,
      MutationId, EggSize and EggExpiresAt are plain readable ATTRIBUTES
        -> rank them, warp to the best one inside the reachable band
        -> pin the root part on it ~1.4s, fireproximityprompt (10 studs)
        -> the egg leaves the world and CanDropCarried flips true
        -> warp south past the village wall; ARRIVING IS THE DELIVERY, the
           egg lands in the inventory as {rarityId, mutationId, size}
        -> Cauldron "HATCH ALL" prompt (16 studs) turns eggs into brainrots
        -> plot "Place Brainrot" prompt (13 studs) seats one, TotalCps rises
        -> firetouchinterest over the plot's SlotPads banks the accrued money

    THIS GAME HAS NO NAMED REMOTES. It runs ZAP: two events, ZAP_RELIABLE and
    ZAP_UNRELIABLE_0, everything binary serialised. The whole API is readable
    anyway because ReplicatedStorage.Shared.Net.client can be required AND
    decompiled - 98 named events with exact argument shapes. Facts about that
    module that cost time to establish:

      * ZAP's On() is ADDITIVE, not replacing (InventoryState went from 7 to 8
        listeners). Registering our own listener is safe and does not unhook
        the game's own UI. But it also means a re-execute STACKS listeners, so
        the InventoryState hook below is guarded in _G and checks GEN.
      * The incoming event ids are 0-BASED, 0..35.
      * Nothing arriving is not proof of a broken listener. TrainingGain and
        QuestState only flow WHILE the player stands on a treadmill; a quiet
        window looked exactly like a dead hook for half an hour. Measured in
        one window afterwards: 10 packets, 10 callbacks.

    Verified facts this script is built on (do not re-derive):

      * PICKUP IS A PROXIMITYPROMPT, NOT A REMOTE. CarryEgg.Fire{rarityId,
        mutationId, size} names the egg by VALUE and the server ignores it
        when it was not solicited - fired standing exactly on an egg it did
        nothing at all, three times. fireproximityprompt on the egg works.
      * TRAINING BLOCKS EVERYTHING. plr Training stays true after warping off
        a treadmill, and while it is true the pickup prompt does nothing. This
        reads exactly like a broken prompt. StopTreadmill has to be fired
        first - it is the single most important line in farmCycle.
      * Banking is arriving in the village, not a pad. Standing on SafeZonePad,
        EntrySafePad or EndSafePad for 7s banked nothing; warping south of the
        village wall flipped CanDropCarried false and the egg appeared in the
        inventory.
      * RequestCollectAll IS DEAD. Fired on the plot and on CollectAllPad it
        moved money by exactly 0 while $17.4K sat accrued. Collecting is
        firetouchinterest over the plot's ten SlotPads: money 6,399 -> 23,892,
        +17,493.53 in one sweep.
      * Levels are the sink and they are absurdly cheap early. The upgrade is a
        ClickDetector on EvolvePancarte/Board at 50 studs, no pin needed:
        TotalCps 17.69 -> 18.09 for $1, a ~2.5 second payback. Yield is
        1.25^(level-1) to level 75 (x14,836,824 at the cap) while price grows
        1.5 per level, so payback degrades x1.2 per level - buy wide and low,
        never chase one brainrot up the ladder.
      * THE NORTH IS WALLED BY ENDURANCE, and a long warp does not get through.
        A chunked 1,316 stud run stalled 561 studs short and ended at z ~ 750,
        which is mapNorthZ(2). Every warp INSIDE the band (z 380..700) landed
        exactly, dz = 0. So the band is real geometry, not anti-cheat: single
        warps are accepted, the bridge is not.
      * Rarity is everything. Best baseRevenue per rarity: common 15.8,
        rare 162, epic 1,640, legendary 13,700, mythic 122,000, secret 4.07M,
        og 10M, abyssal 18.4M, celestial 32.7M, omega 64M - roughly x10 a step,
        multiplied by the mutation (default 1 ... yinyang 50).
      * Rebirth rank r gives multiplier r+1 and 10+r plot slots, 20 ranks.
        nextRank(0) is {moneyGate = 5000, objectiveBrainrotId = 1, xN = 2}.
        The Robux skip is never touched.

    Panel: RightShift.  Console handle: _G.__FINDEGG_DBG
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local plr = Players.LocalPlayer

-- ---------------------------------------------------------------- generation
-- Re-running in the executor does not restart the Lua VM, so every loop below
-- captures this number and exits the moment it stops matching.
_G.__FINDEGG = (_G.__FINDEGG or 0) + 1
local GEN = _G.__FINDEGG

-- ------------------------------------------------------------------ modules
local Shared = ReplicatedStorage:WaitForChild("Shared", 15)
local Net, Cfg, Rarities, Mutations, BrainrotData, RebirthsMod, OpenMap, ZoneGate

local function tryRequire(parent, name)
    local out
    pcall(function() out = require(parent:WaitForChild(name, 10)) end)
    return out
end

Net          = tryRequire(Shared:WaitForChild("Net", 10), "client")
local Mods   = Shared:WaitForChild("Modules", 10)
local Datas  = Shared:WaitForChild("Data", 10)
Cfg          = tryRequire(Mods, "Config")
Rarities     = tryRequire(Datas, "Rarities")
Mutations    = tryRequire(Datas, "Mutations")
BrainrotData = tryRequire(Datas, "Brainrots")
RebirthsMod  = tryRequire(Mods, "Rebirths")
OpenMap      = tryRequire(Mods, "OpenMap")
ZoneGate     = tryRequire(Mods, "HuntZoneGate")

-- ------------------------------------------------------------------- config
local CONFIG = {
    autoFarm      = false,   -- grab the best reachable egg and bring it home
    autoHatch     = true,    -- HATCH ALL once enough eggs are banked
    autoPlace     = true,    -- seat hatched brainrots on free slots
    autoCollect   = true,    -- sweep the SlotPads for accrued money
    autoUpgrade   = true,    -- the EvolvePancarte boards, ~2.5s payback early
    autoRebirth   = false,   -- gate is money + N copies of one brainrot
    autoSwap      = true,    -- on a full plot, evict the weakest BASE value
    swapMargin    = 1.5,     -- how much better the newcomer's base must be
    autoTrain     = true,    -- train when the reachable field cannot help
    stopTreadmill = true,    -- Training=true blocks every pickup, see header

    minRarity     = "common",-- skip anything below this on the ground
    hatchAt       = 3,       -- bank this many eggs before firing HATCH ALL
    upgradesPass  = 6,       -- board clicks per upgrade pass
    keepMoney     = 0,       -- never spend below this
    collectEvery  = 20,
    upgradeEvery  = 10,
    zMargin       = 20,      -- stay this far south of the walled bridge
}

local STATE = {
    running   = true,
    busy      = nil,         -- character mutex: only one routine may move us
    note      = "idle",
    grabbed   = 0,
    banked    = 0,
    hatched   = 0,
    placed    = 0,
    collected = 0,
    upgrades  = 0,
    swaps     = 0,
    mode      = "farm",
    target    = 0,
    weakSeat  = "-",
    lastEgg   = "-",
    bandZ     = 0,
    eggsSeen  = 0,
}

local function note(s)
    STATE.note = tostring(s)
end

-- ------------------------------------------------------------------ oracles
local function attr(k, d)
    local v = plr:GetAttribute(k)
    if v == nil then return d end
    return v
end

local function money()     return tonumber(attr("Money", 0)) or 0 end
local function cps()       return tonumber(attr("TotalCps", 0)) or 0 end
local function rebirths()  return tonumber(attr("Rebirths", 0)) or 0 end
local function endurance() return tonumber(attr("EnduranceMax", 0)) or 0 end
local function carrying()  return attr("CanDropCarried", false) == true end
local function training()  return attr("Training", false) == true end

local function char()
    local c = plr.Character
    if not c then return nil end
    return c, c:FindFirstChild("HumanoidRootPart")
end

-- The inventory is the state oracle and it only arrives as an event, so the
-- listener is installed ONCE - On() is additive, so a re-execute would
-- otherwise stack one hook per run and never drop the old ones.
local INV = _G.__FINDEGG_INV or { eggs = {}, brainrots = {}, tools = {}, apples = {} }
_G.__FINDEGG_INV = INV

if Net and not _G.__FINDEGG_INVHOOK then
    _G.__FINDEGG_INVHOOK = true
    pcall(function()
        Net.InventoryState.On(function(p)
            if type(p) ~= "table" then return end
            INV.eggs      = p.eggs      or {}
            INV.brainrots = p.brainrots or {}
            INV.tools     = p.tools     or {}
            INV.apples    = p.apples    or {}
            INV.at        = os.clock()
        end)
    end)
end

local function refreshInventory()
    if not Net then return end
    pcall(function()
        Net.InventoryRequest.Fire()
        if Net.SendEvents then Net.SendEvents() end
    end)
end

local function eggCount()
    local n = 0
    for _, e in ipairs(INV.eggs or {}) do n = n + (tonumber(e.count) or 1) end
    return n
end

local function brainrotCount()
    local n = 0
    for _, e in ipairs(INV.brainrots or {}) do n = n + (tonumber(e.count) or 1) end
    return n
end

-- --------------------------------------------------------------- valuation
-- Rank on the RARITY LADDER, not on anything the world model displays. These
-- are the best baseRevenue per rarity read out of Shared.Data.Brainrots, so a
-- score is "the ceiling this egg can roll" - roughly x10 a step.
local RARITY_WEIGHT = {
    common = 15.8, rare = 162, epic = 1640, legendary = 13700, mythic = 122000,
    secret = 4.07e6, og = 1e7, abyssal = 1.84e7, celestial = 3.27e7, omega = 6.4e7,
}
local RARITY_ORDER = {
    common = 1, rare = 2, epic = 3, legendary = 4, mythic = 5,
    secret = 6, og = 7, abyssal = 8, celestial = 9, omega = 10,
}

-- Read the real multipliers out of the game rather than trusting the table.
local MUT_MULT = {}
do
    local ok = pcall(function()
        for _, m in ipairs(Mutations or {}) do
            if m.id then MUT_MULT[m.id] = tonumber(m.revenueMultiplier) or 1 end
        end
    end)
    if not ok or next(MUT_MULT) == nil then
        MUT_MULT = {
            default = 1, gold = 2, diamond = 4, divine = 8, wet = 7, burning = 8,
            frozen = 10, shadow = 12, electric = 14, toxic = 12, plasma = 16,
            rainbow = 20, sanguine = 24, candy = 26, volcanic = 28, astral = 40,
            yinyang = 50,
        }
    end
end

-- Fill any rarity the data module knows about but the table above does not,
-- so an added rarity ranks somewhere sensible instead of at 1.
do
    pcall(function()
        for _, r in ipairs(Rarities or {}) do
            if r.id then
                RARITY_ORDER[r.id] = tonumber(r.order) or RARITY_ORDER[r.id] or 1
                RARITY_WEIGHT[r.id] = RARITY_WEIGHT[r.id] or (10 ^ ((tonumber(r.order) or 1)))
            end
        end
    end)
end

local function eggScore(rarityId, mutationId, size)
    local w = RARITY_WEIGHT[rarityId] or 1
    local m = MUT_MULT[mutationId] or 1
    -- Size only shifts the hatch chance a little; keep it as a tiebreak so a
    -- bigger common can never outrank a smaller rare.
    return w * m * (1 + 0.02 * ((tonumber(size) or 1) - 1))
end

-- ------------------------------------------------------------------ the map
-- The reachable band ends at the first bridge the player's endurance cannot
-- pay for. Take it from the game's own gate rather than from a constant: a
-- warp past it is simply refused and the farm would spin on an egg it can
-- never touch (measured: stalled 561 studs short at z ~ 750 = mapNorthZ(2)).
local function bandLimit()
    local best = 1
    if ZoneGate and ZoneGate.canReachMap then
        for i = 1, (OpenMap and OpenMap.MAP_COUNT or 10) do
            local ok, can = pcall(ZoneGate.canReachMap, plr, i)
            if ok and can then best = i end
        end
    end
    local z = 368
    if OpenMap and OpenMap.playNorthZ then
        local ok, v = pcall(OpenMap.playNorthZ, best)
        if ok and tonumber(v) then z = tonumber(v) end
    end
    STATE.bandZ = math.floor(z)
    return z - (CONFIG.zMargin or 20)
end

local function eggFolder()
    local hs = workspace:FindFirstChild("HuntSlots")
    if not hs then return nil end
    -- One slot holds the whole world's eggs for this session, not one per map.
    local best, bestN = nil, -1
    for _, s in ipairs(hs:GetChildren()) do
        local n = 0
        for _, d in ipairs(s:GetChildren()) do
            if d.Name == "Egg" then n = n + 1 end
        end
        if n > bestN then best, bestN = s, n end
    end
    return best
end

local function bestEgg()
    local folder = eggFolder()
    if not folder then return nil end
    local limit = bandLimit()
    local minOrder = RARITY_ORDER[CONFIG.minRarity] or 1
    local best, bestScore, seen = nil, -1, 0
    for _, d in ipairs(folder:GetDescendants()) do
        if d.Name == "Egg" and d:IsA("BasePart") then
            local r = d:GetAttribute("RarityId")
            local m = d:GetAttribute("MutationId")
            if r then
                local ok, pos = pcall(function() return d:GetPivot().Position end)
                if ok and pos.Z <= limit then
                    seen = seen + 1
                    if (RARITY_ORDER[r] or 1) >= minOrder then
                        local s = eggScore(r, m, d:GetAttribute("EggSize"))
                        if s > bestScore then best, bestScore = d, s end
                    end
                end
            end
        end
    end
    STATE.eggsSeen = seen
    return best, bestScore
end

-- ------------------------------------------------------------------ movement
-- Single warps inside the band land exactly (dz = 0 measured at 380..700), so
-- the chunking is only there to keep each hop under the acceptance window and
-- to notice a refusal instead of spinning on it.
local function warpTo(target, tolerance)
    tolerance = tolerance or 12
    local _, hrp = char()
    if not hrp then return false end
    local stall = 0
    for _ = 1, 25 do
        local here = hrp.Position
        local delta = target - here
        local dist = delta.Magnitude
        if dist <= tolerance then return true end
        hrp.CFrame = CFrame.new(here + delta.Unit * math.min(180, dist) + Vector3.new(0, 3, 0))
        task.wait(0.2)
        local moved = (hrp.Position - here).Magnitude
        if moved < 5 then
            stall = stall + 1
            if stall >= 3 then return false end   -- a wall, not a slow frame
        else
            stall = 0
        end
    end
    return (hrp.Position - target).Magnitude <= tolerance
end

local function pinAt(pos, seconds)
    local _, hrp = char()
    if not hrp then return end
    local cf = CFrame.new(pos + Vector3.new(0, 3, 0))
    local conn = RunService.Heartbeat:Connect(function()
        if hrp.Parent then hrp.CFrame = cf end
    end)
    task.wait(seconds)
    conn:Disconnect()
end

-- Only one routine may drive the character at a time. Two of them warping at
-- once is how a farm ends up hatching in the field and grabbing at home.
local function withChar(name, fn)
    if STATE.busy then return false end
    STATE.busy = name
    local ok, err = pcall(fn)
    STATE.busy = nil
    if not ok then note(name .. " failed: " .. tostring(err)) end
    return ok
end

-- --------------------------------------------------------------- the plot
local function myPlot()
    local v = workspace:FindFirstChild("Village")
    if not v then return nil end
    for _, p in ipairs(v:GetChildren()) do
        if p.Name:match("^VillagePlot_") and p:GetAttribute("OwnerUserId") == plr.UserId then
            return p
        end
    end
    return nil
end

local function villagePoint()
    local p = myPlot()
    if p then
        local ok, pos = pcall(function() return p:GetPivot().Position end)
        if ok then return pos + Vector3.new(0, 8, 0) end
    end
    return Vector3.new(0, 10, 60)
end

local function anchorPos(inst)
    if inst:IsA("Attachment") then return inst.WorldPosition end
    local ok, pos = pcall(function() return inst:GetPivot().Position end)
    if ok then return pos end
    return nil
end

local function slotPrompts()
    local free, taken = {}, {}
    local p = myPlot()
    if not p then return free, taken end
    for _, d in ipairs(p:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            -- An occupied slot reads "Pick Up", and only "Replace" while
            -- something is already in hand - so both mean taken.
            if d.ActionText == "Place Brainrot" then
                free[#free + 1] = d
            elseif d.ActionText == "Pick Up" or d.ActionText == "Replace" then
                taken[#taken + 1] = d
            end
        end
    end
    return free, taken
end

-- ------------------------------------------------------------------ actions
-- Forward declarations. farmCycle yields to a pending swap and therefore calls
-- the seat helpers, which are defined further down next to placeBrainrots -
-- and a Lua local is invisible above its definition, so without these the farm
-- died on "attempt to call a nil value" and quietly grabbed nothing at all.
local brainrotScore, bestInvBrainrot, seatList, weakestSeat
local function stopTreadmill()
    -- Training stays true after warping off the treadmill and silently blocks
    -- every pickup. This is the fix for "the prompt does nothing".
    if not (Net and CONFIG.stopTreadmill) then return end
    if not training() then return end
    pcall(function()
        Net.StopTreadmill.Fire()
        if Net.SendEvents then Net.SendEvents() end
    end)
    task.wait(0.4)
end

local function grabEgg(egg)
    local ok, pos = pcall(function() return egg:GetPivot().Position end)
    if not ok then return false end
    if not warpTo(pos) then
        note("egg out of reach - band ends at z " .. tostring(STATE.bandZ))
        return false
    end
    local prompt = egg:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then return false end

    -- A warp plus an immediate fire does nothing; the hold is the whole trick.
    local _, hrp = char()
    local cf = CFrame.new(pos + Vector3.new(0, 3, 0))
    local conn = RunService.Heartbeat:Connect(function()
        if hrp and hrp.Parent then hrp.CFrame = cf end
    end)
    task.wait(1.4)
    pcall(fireproximityprompt, prompt)
    task.wait(1.2)
    conn:Disconnect()

    if egg.Parent == nil or carrying() then
        STATE.grabbed = STATE.grabbed + 1
        return true
    end
    return false
end

local function carryHome()
    local target = villagePoint()
    warpTo(target, 25)
    -- Arriving IS the delivery, but the server needs a moment to see it.
    pinAt(target, 2.0)
    for _ = 1, 12 do
        if not carrying() then break end
        task.wait(0.25)
    end
    if not carrying() then
        STATE.banked = STATE.banked + 1
        refreshInventory()
        return true
    end
    return false
end

-- ---------------------------------------------------------------- training
-- The band ends at a bridge the endurance cannot pay for, so once the plot has
-- outgrown everything inside it the treadmill is worth more than another egg.
-- Measured on this account: the best in-band egg was rare/diamond with a
-- ceiling of 648 while the weakest seat already sat at base 940, and the first
-- mythic beyond the wall scores 488,000 - a factor of 753. Farming there is
-- not slow progress, it is no progress.
local function nextBridgeEndurance()
    local cur = endurance()
    local best
    if OpenMap and OpenMap.bridgeRequiredEndurance then
        for i = 1, (OpenMap.MAP_COUNT or 10) do
            local ok, v = pcall(OpenMap.bridgeRequiredEndurance, i)
            v = ok and tonumber(v) or nil
            if v and v > cur and ((not best) or v < best) then best = v end
        end
    end
    return best
end

local function shouldTrain()
    if not CONFIG.autoTrain then return false end
    local target = nextBridgeEndurance()
    STATE.target = target or 0
    if not target then return false end
    if endurance() >= target then return false end

    -- Both sides are "base revenue x mutation", so they compare directly: the
    -- egg's score is the CEILING its rarity can hatch into, the seat's base is
    -- what it actually is. If the best egg in reach cannot beat the worst seat,
    -- nothing in the band can improve the plot.
    local egg, score = bestEgg()
    if not egg then return true end
    local seat = weakestSeat()
    if seat and score and score <= seat.base then return true end
    return false
end

local function trainCycle()
    if not shouldTrain() then
        STATE.mode = "farm"
        return
    end
    STATE.mode = "train"
    if training() then
        note(("training %d / %d endurance"):format(endurance(), STATE.target))
        return
    end
    withChar("train", function()
        warpTo(villagePoint(), 25)
        task.wait(0.4)
        local _, hrp = char()
        if not hrp then return end
        pcall(function()
            Net.ToggleTreadmill.Fire({ rootCf = hrp.CFrame })
            if Net.SendEvents then Net.SendEvents() end
        end)
        task.wait(1.5)
    end)
end

local function farmCycle()
    -- Training outranks farming outright while the field is exhausted.
    if STATE.mode == "train" then return end
    if carrying() then
        withChar("deliver", carryHome)
        return
    end
    -- The farm runs every 0.5s and would otherwise hold the character mutex
    -- permanently, so hatching and placing never get a turn - measured: 8 eggs
    -- banked and 0 hatched. Pending plot work therefore outranks a new egg.
    if CONFIG.autoHatch and eggCount() >= (CONFIG.hatchAt or 3) then return end
    -- ...but only while that work can actually make progress. Yielding on
    -- "there are brainrots in the inventory" alone deadlocked the farm: once
    -- the plot was full, four spares worth less than the weakest seat sat
    -- there forever and 24s produced zero eggs.
    if CONFIG.autoPlace and brainrotCount() > 0 then
        local free = slotPrompts()
        if #free > 0 then return end
        -- A full plot still yields when the best spare genuinely beats the
        -- weakest seat on BASE value - that swap is worth more than one more
        -- egg. It does not yield otherwise, or spares nobody wants would
        -- deadlock the farm again.
        if CONFIG.autoSwap then
            local _, pickScore = bestInvBrainrot()
            local seat = weakestSeat()
            if seat and pickScore and pickScore > seat.base * (CONFIG.swapMargin or 1.5) then
                return
            end
        end
    end
    local egg = bestEgg()
    if not egg then
        note("no egg in the reachable band")
        return
    end
    withChar("farm", function()
        stopTreadmill()
        local r  = tostring(egg:GetAttribute("RarityId"))
        local m  = tostring(egg:GetAttribute("MutationId"))
        STATE.lastEgg = r .. (m ~= "default" and ("/" .. m) or "")
        note("grabbing " .. STATE.lastEgg)
        if grabEgg(egg) then
            carryHome()
        end
    end)
end

local function hatchAll()
    local v = workspace:FindFirstChild("Village")
    local cauldron = v and v:FindFirstChild("Cauldron")
    if not cauldron then return false end
    local water
    for _, d in ipairs(cauldron:GetDescendants()) do
        if d.Name == "CauldronWater" then water = d break end
    end
    if not water then return false end

    local prompt
    for _, d in ipairs(water:GetChildren()) do
        if d:IsA("ProximityPrompt") and d.ActionText
           and string.find(string.upper(d.ActionText), "HATCH ALL") then
            prompt = d
        end
    end
    if not prompt then return false end

    local pos = anchorPos(water)
    if not pos then return false end
    warpTo(pos, 12)
    local _, hrp = char()
    local cf = CFrame.new(pos + Vector3.new(0, 6, 6))
    local conn = RunService.Heartbeat:Connect(function()
        if hrp and hrp.Parent then hrp.CFrame = cf end
    end)
    task.wait(1.0)
    pcall(fireproximityprompt, prompt)
    -- The reveal is staggered and the brainrots arrive several seconds late;
    -- checking too early reports failure while the reward is still in flight.
    task.wait(math.min(9, 3 + 0.5 * eggCount()))
    conn:Disconnect()
    STATE.hatched = STATE.hatched + 1
    refreshInventory()
    return true
end

-- Rank the inventory so the best brainrot takes the first free slot. The
-- record only carries brainrotId/mutationId/level, so the value has to come
-- out of the data module - baseRevenue x the mutation multiplier.
function brainrotScore(e)
    local base = 1
    pcall(function()
        local rec = BrainrotData and BrainrotData[tonumber(e.brainrotId)]
        if rec and rec.baseRevenue then base = tonumber(rec.baseRevenue) or 1 end
    end)
    return base * (MUT_MULT[tostring(e.mutationId)] or 1)
end

function bestInvBrainrot()
    local best, bs = nil, -1
    for _, e in ipairs(INV.brainrots or {}) do
        local s = brainrotScore(e)
        if s > bs then best, bs = e, s end
    end
    return best, bs
end

-- ------------------------------------------------------------------- seats
-- A seat only tells us its NAME and its mutation as display text, so the value
-- has to be looked back up. Build the name index once.
local BY_NAME = {}
pcall(function()
    for _, rec in pairs(BrainrotData or {}) do
        if rec.name then BY_NAME[rec.name] = rec end
    end
end)

-- The label prints the mutation's display name ("Gold", "Toxic"), which is
-- sometimes the id and sometimes the aura, so match against both.
local MUT_BY_LABEL = {}
pcall(function()
    for _, m in ipairs(Mutations or {}) do
        local mult = tonumber(m.revenueMultiplier) or 1
        if m.id then MUT_BY_LABEL[string.lower(m.id)] = mult end
        if m.aura then MUT_BY_LABEL[string.lower(m.aura)] = mult end
    end
end)

local function mutMultFromLabel(label)
    label = string.lower(tostring(label or ""))
    if label == "" then return 1 end
    return MUT_BY_LABEL[label] or MUT_MULT[label] or 1
end

-- THE BASE VALUE IS THE RANKING, NOT THE REVENUE LABEL.
-- Measured on this plot: Salamino Penguino/Gold sits at base 266 and level 24
-- and shows $45K/s, while a plain Brr Brr Patapim at base 24.5 and level 36
-- shows $60.3K/s. Sorting on what the label prints keeps the brainrot that is
-- ELEVEN TIMES worse and evicts the good one, forever - the level is a few
-- purchases, the base is permanent.
function seatList()
    local out = {}
    local p = myPlot()
    if not p then return out end
    for _, d in ipairs(p:GetDescendants()) do
        if d.Name == "PlacedDisplay" then
            local podium = d.Parent
            local name, mut, lvl
            for _, c in ipairs(d:GetDescendants()) do
                if c:IsA("TextLabel") then
                    if c.Name == "NameLabel" then
                        name = c.Text
                    elseif c.Name == "MutationLabel" then
                        mut = c.Text
                    elseif c.Name == "Level" then
                        lvl = tonumber(string.match(tostring(c.Text), "Lvl%s*(%d+)"))
                    end
                end
            end
            local prompt
            if podium then
                for _, c in ipairs(podium:GetDescendants()) do
                    if c:IsA("ProximityPrompt") then prompt = c break end
                end
            end
            if name and name ~= "" and prompt then
                local rec = BY_NAME[name]
                out[#out + 1] = {
                    podium   = podium,
                    prompt   = prompt,
                    name     = name,
                    mutation = mut or "",
                    level    = lvl or 1,
                    base     = (rec and tonumber(rec.baseRevenue) or 0) * mutMultFromLabel(mut),
                }
            end
        end
    end
    -- Base decides, but among EQUAL bases evict the lowest level: two identical
    -- Pipi Potatos sat at level 28 and level 3, and a pure base sort offered
    -- the level 28 one up first, throwing away 1.25^27 for nothing.
    table.sort(out, function(a, b)
        if a.base ~= b.base then return a.base < b.base end
        return a.level < b.level
    end)
    return out
end

function weakestSeat()
    local s = seatList()
    return s[1], #s
end

local function placeBrainrots()
    -- No early return on a full plot: the swap pass below is exactly what has
    -- to run then.
    local free = slotPrompts()
    local placed = 0
    for _, prompt in ipairs(free) do
        if brainrotCount() <= 0 then break end
        -- THE SLOT PROMPT IS DISABLED UNTIL THE SERVER SEES ONE IN HAND.
        -- Firing it on its own does exactly nothing, which reads like a broken
        -- prompt: measured 13 fires, 6 slots, one placement. CarryBrainrot is
        -- the missing step and it takes the record by VALUE, not by a uid.
        local pick = bestInvBrainrot()
        if not pick then break end
        pcall(function()
            Net.CarryBrainrot.Fire({
                brainrotId = tonumber(pick.brainrotId),
                mutationId = tostring(pick.mutationId),
                level      = tonumber(pick.level) or 1,
            })
            if Net.SendEvents then Net.SendEvents() end
        end)
        task.wait(0.6)
        local pos = anchorPos(prompt.Parent)
        if pos then
            warpTo(pos, 10)
            local _, hrp = char()
            local cf = CFrame.new(pos + Vector3.new(0, 4, 0))
            local conn = RunService.Heartbeat:Connect(function()
                if hrp and hrp.Parent then hrp.CFrame = cf end
            end)
            task.wait(0.8)
            pcall(fireproximityprompt, prompt)
            task.wait(1.0)
            conn:Disconnect()
            placed = placed + 1
            refreshInventory()
            task.wait(0.4)
        end
    end
    STATE.placed = STATE.placed + placed

    -- ------------------------------------------------------------- swapping
    -- A full plot must not end the seating pass: without this the farm keeps
    -- producing and every better brainrot piles up in the inventory forever.
    -- The comparison is BASE against BASE - both sides raw, never one side's
    -- levelled RevenueLabel, which is the trap this whole ranking exists for.
    if CONFIG.autoSwap and #free == 0 then
        local pick, pickScore = bestInvBrainrot()
        local seat = weakestSeat()
        if pick and seat then
            STATE.weakSeat = ("%s base %.1f lv%d"):format(seat.name, seat.base, seat.level)
            -- A margin, because evicting a seat throws its LEVEL away and the
            -- level factor here is 1.25^(level-1) - steep enough that a
            -- marginally better base is not worth the reset.
            if pickScore > seat.base * (CONFIG.swapMargin or 1.5) then
                local pos = anchorPos(seat.podium)
                if pos then
                    pcall(function()
                        Net.CarryBrainrot.Fire({
                            brainrotId = tonumber(pick.brainrotId),
                            mutationId = tostring(pick.mutationId),
                            level      = tonumber(pick.level) or 1,
                        })
                        if Net.SendEvents then Net.SendEvents() end
                    end)
                    task.wait(0.6)
                    warpTo(pos, 10)
                    local _, hrp = char()
                    local cf = CFrame.new(pos + Vector3.new(0, 4, 0))
                    local conn = RunService.Heartbeat:Connect(function()
                        if hrp and hrp.Parent then hrp.CFrame = cf end
                    end)
                    task.wait(0.9)
                    pcall(fireproximityprompt, seat.prompt)
                    task.wait(1.2)
                    -- An occupied slot's prompt may only PICK UP rather than
                    -- swap (it did exactly that in Aura For Brainrots), which
                    -- would leave the slot empty and both brainrots loose. If
                    -- the seat went free while we still hold something, fire
                    -- once more to seat it.
                    if seat.prompt.ActionText == "Place Brainrot" then
                        pcall(fireproximityprompt, seat.prompt)
                        task.wait(1.0)
                    end
                    conn:Disconnect()
                    STATE.swaps = (STATE.swaps or 0) + 1
                    note(("swapped in over %s (base %.1f -> %.1f)"):format(
                        seat.name, seat.base, pickScore))
                    refreshInventory()
                end
            end
        end
    end

    -- Free, and the server does the ranking: on a full plot it seats a better
    -- spare and pushes the weakest out. Measured delta 0 against an idle drift
    -- of 0 - correct, because every spare was worth less than the weakest seat
    -- (1.6-19.7 raw against 24.5). So it is NOT proven as a swapper, only
    -- proven not to be dead; it costs nothing to keep firing.
    pcall(function()
        Net.EquipBest.Fire()
        if Net.SendEvents then Net.SendEvents() end
    end)
    return placed > 0
end

-- RequestCollectAll is dead - this is the only thing that moves money.
local function collectAll()
    local p = myPlot()
    if not p then return 0 end
    local _, hrp = char()
    if not hrp then return 0 end
    local before = money()
    for _, d in ipairs(p:GetDescendants()) do
        if d.Name == "SlotPad" and d:IsA("BasePart") then
            pcall(function()
                firetouchinterest(hrp, d, 0)
                firetouchinterest(hrp, d, 1)
            end)
        end
    end
    task.wait(1.0)
    local gained = money() - before
    if gained > 0 then STATE.collected = STATE.collected + gained end
    return gained
end

-- The boards are ClickDetectors at 50 studs, so this needs no pin and no warp.
local function upgradeLevels(budget, maxClicks)
    local p = myPlot()
    if not p then return 0 end
    local boards = {}
    for _, d in ipairs(p:GetDescendants()) do
        if d:IsA("ClickDetector") and d.Parent and d.Parent.Name == "Board" then
            boards[#boards + 1] = d
        end
    end
    if #boards == 0 then return 0 end

    local clicks = 0
    for _ = 1, (maxClicks or 6) do
        for _, cd in ipairs(boards) do
            if money() <= (CONFIG.keepMoney or 0) then return clicks end
            local before = cps()
            pcall(fireclickdetector, cd)
            task.wait(0.25)
            if cps() > before then clicks = clicks + 1 end
        end
    end
    STATE.upgrades = STATE.upgrades + clicks
    return clicks
end

-- Rank r gives multiplier r+1 and 10+r slots. The gate is money plus N copies
-- of one named brainrot; whether the copies must be PLACED or merely owned is
-- UNVERIFIED, so this only fires when the money gate is clear and then checks
-- the rebirth counter to decide whether it worked.
local function rebirthGate()
    if not (RebirthsMod and RebirthsMod.nextRank) then return nil end
    local ok, g = pcall(RebirthsMod.nextRank, rebirths())
    if not ok or type(g) ~= "table" then return nil end
    return g
end

local function tryRebirth()
    local g = rebirthGate()
    if not g then return false end
    local gate = tonumber(g.moneyGate) or math.huge
    if money() < gate then
        note(("rebirth needs $%d"):format(gate))
        return false
    end
    local before = rebirths()
    pcall(function()
        Net.RequestRebirth.Fire({})
        if Net.SendEvents then Net.SendEvents() end
    end)
    task.wait(2.5)
    if rebirths() > before then
        note("rebirth -> rank " .. rebirths())
        return true
    end
    note("rebirth refused (needs " .. tostring(g.xN) .. "x brainrot #" .. tostring(g.objectiveBrainrotId) .. ")")
    return false
end

-- ------------------------------------------------------------- loop driver
local function loop(period, key, fn)
    task.spawn(function()
        while _G.__FINDEGG == GEN do
            if CONFIG[key] and STATE.running then
                local ok, err = pcall(fn)
                if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
            end
            task.wait(period)
        end
    end)
end

-- Decide the mode BEFORE the farm gets its turn, so a farm that cannot help
-- never spends the character mutex it would deny the treadmill.
loop(5, "autoTrain", trainCycle)

loop(0.5, "autoFarm", farmCycle)

loop(6, "autoHatch", function()
    if eggCount() >= (CONFIG.hatchAt or 3) then
        withChar("hatch", hatchAll)
    end
end)

loop(8, "autoPlace", function()
    if brainrotCount() > 0 then
        withChar("place", placeBrainrots)
    end
end)

loop(CONFIG.collectEvery, "autoCollect", function()
    withChar("collect", collectAll)
end)

loop(CONFIG.upgradeEvery, "autoUpgrade", function()
    upgradeLevels(money(), CONFIG.upgradesPass)
end)

loop(30, "autoRebirth", tryRebirth)

-- Keep the oracle warm; everything else reads INV rather than asking.
task.spawn(function()
    while _G.__FINDEGG == GEN do
        pcall(refreshInventory)
        task.wait(5)
    end
end)

-- ------------------------------------------------------------------ panel
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

-- A run that errored early stores no handle, so sweep the named ScreenGui too.
if _G.__FINDEGG_WIN then pcall(function() _G.__FINDEGG_WIN:Destroy() end) end
pcall(function()
    local cg = game:GetService("CoreGui")
    for _, g in ipairs(cg:GetChildren()) do
        if g.Name == "FINDEGG_PANEL" then g:Destroy() end
    end
end)

-- Merges the saved file into CONFIG BEFORE the panel is built, so every
-- control comes up on its saved state by itself.
UI.config("findegg", CONFIG)

local win = UI.Window({
    title = "FIND", accentTitle = "EGG", subtitle = "seltonmt",
    badge = "*", width = 920, height = 580, name = "FINDEGG_PANEL",
})
_G.__FINDEGG_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local cFarm = farm:Card("EGG HUNT", 1):Accent()
cFarm:Toggle("Auto farm", CONFIG.autoFarm, function(v) CONFIG.autoFarm = v end,
    "Grab the best egg in reach and carry it home")
cFarm:Toggle("Leave the treadmill first", CONFIG.stopTreadmill, function(v) CONFIG.stopTreadmill = v end,
    "Training silently blocks every pickup", UI.theme.warn)
cFarm:Toggle("Train when the field is exhausted", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
    "Endurance opens the next bridge, and beyond it eggs are worth hundreds of times more",
    UI.theme.good)
cFarm:Dropdown("Minimum rarity", {
    "common", "rare", "epic", "legendary", "mythic", "secret", "og", "abyssal", "celestial", "omega",
}, CONFIG.minRarity, function(v) CONFIG.minRarity = v end,
    "Ignore anything below this on the ground")

local cBand = farm:Card("RANGE", 2)
cBand:Label("The north is walled by endurance; the bridge cannot be warped past.")
local outBand = cBand:Readout(3)

local plot = win:Page("PLOT", UI.icon.coin)

local cPlot = plot:Card("HATCH & PLACE", 1):Accent()
cPlot:Toggle("Hatch at the cauldron", CONFIG.autoHatch, function(v) CONFIG.autoHatch = v end)
cPlot:Stepper("Hatch from",
    function() return tostring(CONFIG.hatchAt) .. " eggs" end,
    function(dir) CONFIG.hatchAt = math.clamp((CONFIG.hatchAt or 3) + dir, 1, 12) end,
    "Eggs banked before HATCH ALL fires")
cPlot:Toggle("Place brainrots", CONFIG.autoPlace, function(v) CONFIG.autoPlace = v end)
cPlot:Toggle("Swap on base value", CONFIG.autoSwap, function(v) CONFIG.autoSwap = v end,
    "A full plot evicts its weakest BASE, not its lowest label", UI.theme.good)
cPlot:Stepper("Swap margin",
    function() return ("%.1fx base"):format(CONFIG.swapMargin or 1.5) end,
    function(dir) CONFIG.swapMargin = math.clamp((CONFIG.swapMargin or 1.5) + dir * 0.25, 1, 5) end,
    "Higher keeps levelled seats longer")

local cMoney = plot:Card("MONEY", 2)
cMoney:Toggle("Collect the slots", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
    "Touch sweep - the collect remote does nothing")
cMoney:Toggle("Upgrade levels", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
    "About a 2.5 second payback early on", UI.theme.good)
cMoney:Stepper("Clicks per pass",
    function() return tostring(CONFIG.upgradesPass) end,
    function(dir) CONFIG.upgradesPass = math.clamp((CONFIG.upgradesPass or 6) + dir, 1, 20) end)
cMoney:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "Needs money plus N copies of one brainrot", UI.theme.warn)

local cStats = plot:Card("RUN", 0)
local outRun = cStats:Readout(3)

local function fmt(n)
    n = tonumber(n) or 0
    local units = { "", "K", "M", "B", "T", "Qd", "Qn" }
    local i = 1
    while n >= 1000 and i < #units do n, i = n / 1000, i + 1 end
    return (i == 1 and ("%d"):format(n) or ("%.2f%s"):format(n, units[i]))
end

task.spawn(function()
    while _G.__FINDEGG == GEN do
        pcall(function()
            local free, taken = slotPrompts()
            -- One dictionary key per sentence, never fragments glued together -
            -- a concatenated line freezes the word order and is not a key.
            win:SetStatus(UI.tf("$%s   %s/s   slots %d/%d   R%d   endurance %s",
                fmt(money()), fmt(cps()), #taken, #free + #taken, rebirths(), fmt(endurance())))
            win:SetStat(1, fmt(money()), UI.t("money"))
            win:SetStat(2, fmt(cps()), UI.t("per second"))
            win:SetStat(3, tostring(rebirths()), UI.t("rebirths"))

            outBand:set({
                UI.tf("band ends at z %d", STATE.bandZ),
                UI.tf("%d eggs in reach   mode %s", STATE.eggsSeen, UI.t(tostring(STATE.mode))),
                UI.tf("last egg: %s", tostring(STATE.lastEgg)),
            })
            outRun:set({
                UI.tf("grabbed %d   banked %d   swaps %d", STATE.grabbed, STATE.banked, STATE.swaps),
                UI.tf("weakest seat: %s", tostring(STATE.weakSeat)),
                STATE.busy and (STATE.busy .. ": " .. STATE.note) or tostring(STATE.note),
            })
        end)
        task.wait(1)
    end
end)

pcall(function()
    win:SetMaster(CONFIG.autoFarm, "Auto Farm")
    win:OnMaster(function(on)
        CONFIG.autoFarm = on
        STATE.running = true
    end)
end)

-- Everything the bridge needs to drive this script without clicking anything.
_G.__FINDEGG_DBG = {
    CONFIG = CONFIG, STATE = STATE, INV = INV, Net = Net,
    bestEgg = bestEgg, bandLimit = bandLimit, eggScore = eggScore,
    grabEgg = grabEgg, carryHome = carryHome, farmCycle = farmCycle,
    hatchAll = hatchAll, placeBrainrots = placeBrainrots,
    collectAll = collectAll, upgradeLevels = upgradeLevels,
    seatList = seatList, weakestSeat = weakestSeat, brainrotScore = brainrotScore,
    shouldTrain = shouldTrain, trainCycle = trainCycle, nextBridgeEndurance = nextBridgeEndurance,
    bestInvBrainrot = bestInvBrainrot,
    tryRebirth = tryRebirth, rebirthGate = rebirthGate,
    refreshInventory = refreshInventory, myPlot = myPlot,
    eggCount = eggCount, brainrotCount = brainrotCount,
}

pcall(function() win:Home() end)

print("[findegg] loaded - gen " .. GEN .. ", RightShift for the panel")
