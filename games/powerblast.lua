--[[
    powerblast.lua - "Power Blast Lucky Blocks! [SEASON 1]"  place 119822977170203
    ------------------------------------------------------------------------------
    Loop, as measured through the bridge:

      hold the Aura tool  ->  Power ticks server side at the aura's Rate (Power == Strength, 1:1)
      blast from BlastCourse.BlastZone  ->  Power decides distance decides zone decides rarity
      claim the reward token            ->  brainrot arrives as a Tool in the Backpack
      RequestEquipBestBrainrots()       ->  server seats the best ones on the lot by itself
      CollectSlot(index)                ->  cash, from anywhere

    Verified facts this script is built on (do not re-derive):

      * RequestBlastRelease takes the CLIENT's charge time as a bare float. Sending
        CHARGE_FULL_SECONDS after ~0.35s of real charge returns chargeAlpha = 1,
        isPerfect = true, qualityName = "Perfect", luckMultiplier = 2 (the max).
        The 2.67s charge and the 2.2s windup are both skipped.
      * A blast does NOT consume Power.
      * Interrupting the client's own blast sequence kills its auto-grant, so the
        reward token has to be claimed explicitly. It is accepted immediately -
        there is no need to wait out the ~9s flight. 3 blasts in 8.73s -> 4 brainrots.
      * RequestEquipBestBrainrots() takes no arguments and is NOT position gated.
        Measured from the blast zone: placed 8, PassiveRate 1,470 -> 20,504.
      * CollectSlot(index) is NOT position gated. Measured 1,532,781 collected from
        186 studs away. Bare CollectAllSlots() does nothing at all - do not use it.
      * Rebirth keeps cash, placed brainrots, backpack brainrots and auras, and
        raises CashMultiplier by 1 (PassiveRate 735 -> 1,470). It only zeroes
        Power/Strength. Its real cost is therefore the blast distance, not money.
      * leaderstats.Cash is a StringValue ("31.7K") - display only. Use CashRaw.
      * Remotes.GetPlayerData:InvokeServer() NEVER RETURNS. Every RemoteFunction
        here goes through safeInvoke() so a hang can never park the script.
      * Blasting unequips the Aura tool, which stops Power. It is re-equipped every
        cycle - that one line is the difference between farming and standing still.

    Panel: RightShift.  Console handle: _G.__POWERBLAST_DBG
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local plr = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Events  = ReplicatedStorage:WaitForChild("Events")
local Modules = ReplicatedStorage:WaitForChild("Modules")

-- ---------------------------------------------------------------- generation
-- Re-running in the executor does not restart the Lua VM, so every loop below
-- captures this number and exits the moment it stops matching.
_G.__POWERBLAST = (_G.__POWERBLAST or 0) + 1
local GEN = _G.__POWERBLAST

-- ------------------------------------------------------------------- config
local CONFIG = {
    -- farming
    autoBlast        = false,   -- pin in the blast zone and cycle blasts
    perfectCharge    = true,    -- send the full charge time -> Perfect + max luck
    autoEquipBest    = true,    -- let the server seat the best brainrots
    autoCollect      = true,    -- drain every slot's pooled cash
    keepAuraEquipped = true,    -- re-equip the aura (blasting drops it)

    -- spending
    autoAura         = true,    -- climb the aura ladder (the whole progression)
    autoUpgrades     = true,    -- Strength / Inventory / TeleportSpeed ladders
    autoBaseFloors   = true,    -- 100M / 1T / 10Q floors, +10 slots each
    autoRebirth      = false,   -- resets Power, so it is opt-in

    -- freebies
    autoDaily        = true,
    autoSpin         = true,
    autoOffline      = true,

    -- tuning
    blastGap         = 2.9,     -- measured floor; COOLDOWN is 2.5
    burstBlasts      = 6,       -- blasts per charge cycle
    maxChargeSeconds = 90,      -- never charge longer than this before blasting
    preRebirthBlasts = 10,      -- harvest at peak power before zeroing it
    collectEvery     = 8,
    equipEvery       = 12,
    spendEvery       = 15,
}

-- -------------------------------------------------------------------- state
local STATE = {
    running       = false,
    phase         = "idle",
    note          = "",
    blasts        = 0,
    granted       = 0,
    lastReward    = "-",
    lastMutation  = "-",
    cashStart     = nil,
    cashEarned    = 0,
    collected     = 0,
    rebirthsDone  = 0,
    aurasBought   = 0,
    pinTarget     = nil,      -- Vector3 or nil; one shared Heartbeat honours it
    blastBusy     = false,    -- only one routine may drive blasts at a time
    zoneName      = "-",
    lastDistance  = 0,
    chargeTarget  = 0,
    uiOwner       = nil,
}

-- --------------------------------------------------------------- small util
local function attr(name, fallback)
    local v = plr:GetAttribute(name)
    if v == nil then return fallback end
    return v
end

local function num(name) return tonumber(attr(name, 0)) or 0 end

local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
    n = tonumber(n) or 0
    if n < 1000 then
        return (n % 1 == 0) and tostring(math.floor(n)) or string.format("%.1f", n)
    end
    local i = 1
    while n >= 1000 and i < #SUFFIX do n = n / 1000; i = i + 1 end
    return string.format("%.2f%s", n, SUFFIX[i])
end

local function note(s)
    STATE.note = s
end

-- Every RemoteFunction in this game goes through here. GetPlayerData never
-- returns; without the wall-clock cap a single call parks the whole script.
local function safeInvoke(remote, timeout, ...)
    if not remote or not remote:IsA("RemoteFunction") then return nil, "not a RemoteFunction" end
    local args = table.pack(...)
    local done, result, err = false, nil, nil
    task.spawn(function()
        local ok, r = pcall(function()
            return remote:InvokeServer(table.unpack(args, 1, args.n))
        end)
        if ok then result = r else err = tostring(r) end
        done = true
    end)
    local waited = 0
    timeout = timeout or 8
    while not done and waited < timeout do
        task.wait(0.1); waited = waited + 0.1
    end
    if not done then return nil, "timeout" end
    return result, err
end

local function fire(remote, ...)
    if remote and remote:IsA("RemoteEvent") then
        pcall(function(...) remote:FireServer(...) end, ...)
        return true
    end
    return false
end

-- ------------------------------------------------------------ world lookups
local function character()
    local ch = plr.Character
    if not ch or not ch.Parent then return nil end
    return ch
end

local function rootPart()
    local ch = character()
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function humanoid()
    local ch = character()
    return ch and ch:FindFirstChildOfClass("Humanoid") or nil
end

local function blastZone()
    local course = workspace:FindFirstChild("BlastCourse")
    return course and course:FindFirstChild("BlastZone") or nil
end

local function myLot()
    local lots = workspace:FindFirstChild("Lots")
    if not lots then return nil end
    for _, lot in ipairs(lots:GetChildren()) do
        if lot:GetAttribute("OwnerId") == plr.UserId then return lot end
    end
    return nil
end

-- Slots live in PlacementGrid on floor 1 and in each Floor<n>.PlacementGrid.
local function allSlots()
    local lot = myLot()
    local out = {}
    if not lot then return out end
    local function harvest(folder)
        if not folder then return end
        for _, s in ipairs(folder:GetChildren()) do
            if s.Name:match("^Slot_%d+$") then out[#out + 1] = s end
        end
    end
    harvest(lot:FindFirstChild("PlacementGrid"))
    for _, f in ipairs(lot:GetChildren()) do
        if f.Name:match("^Floor%d+$") then harvest(f:FindFirstChild("PlacementGrid")) end
    end
    return out
end

-- Every floor's grid exists in the workspace from the start, locked or not, so
-- "the grid has children" is NOT an unlock test. SlotUnlocked is. SlotIndex is
-- globally unique across floors (1-10, 201-210, 301-310, 401-410).
local function unlockedSlots()
    local out = {}
    for _, s in ipairs(allSlots()) do
        if s:GetAttribute("SlotUnlocked") then out[#out + 1] = s end
    end
    return out
end

local function floorUnlocked(floor)
    local lot = myLot()
    if not lot then return false end
    local folder = (floor == 1) and lot:FindFirstChild("PlacementGrid")
        or (lot:FindFirstChild("Floor" .. floor) and lot["Floor" .. floor]:FindFirstChild("PlacementGrid"))
    if not folder then return false end
    for _, s in ipairs(folder:GetChildren()) do
        if s:GetAttribute("SlotUnlocked") then return true end
    end
    return false
end

local function backpackBrainrots()
    local out = {}
    for _, c in ipairs(plr.Backpack:GetChildren()) do
        if c:GetAttribute("BrainrotId") then out[#out + 1] = c end
    end
    return out
end

-- --------------------------------------------------------------- the pin
-- One shared Heartbeat. A RunService connection per routine is what turns a
-- Roblox script into a stutter, and two of them fight over the CFrame.
task.spawn(function()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if _G.__POWERBLAST ~= GEN then conn:Disconnect(); return end
        local target = STATE.pinTarget
        if not target then return end
        local hrp = rootPart()
        if not hrp then return end
        hrp.CFrame = CFrame.new(target)
        hrp.AssemblyLinearVelocity = Vector3.zero
    end)
end)

-- ----------------------------------------------------------------- the aura
local function equipAura()
    local ch, hum = character(), humanoid()
    if not ch or not hum then return false end
    for _, c in ipairs(ch:GetChildren()) do
        if c:IsA("Tool") and not c:GetAttribute("BrainrotId") then return true end
    end
    for _, c in ipairs(plr.Backpack:GetChildren()) do
        if c:IsA("Tool") and not c:GetAttribute("BrainrotId") then
            pcall(function() hum:EquipTool(c) end)
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------- the blast
local BlastConfig = nil
pcall(function() BlastConfig = require(Modules:WaitForChild("BlastConfig")) end)

local function chargeSeconds()
    local full = 2.67
    if BlastConfig and tonumber(BlastConfig.CHARGE_FULL_SECONDS) then
        full = tonumber(BlastConfig.CHARGE_FULL_SECONDS)
    end
    if not CONFIG.perfectCharge then return 1.0 end
    return full
end

local function zoneForPower(power)
    if not (BlastConfig and BlastConfig.Zones) then return "-" end
    local best = "-"
    for _, z in ipairs(BlastConfig.Zones) do
        local minp = tonumber(z.MinPower) or 0
        if power >= minp then best = z.DisplayName or z.Name or best end
    end
    return best
end

-- One blast cycle. Returns true when a reward token was claimed.
local function doBlast()
    local bz = blastZone()
    local hrp = rootPart()
    if not bz or not hrp then note("no blast zone / no character"); return false end

    STATE.pinTarget = bz.Position + Vector3.new(0, 5, 0)

    local fired = nil
    local conn = Remotes.BlastSequence.OnClientEvent:Connect(function(data)
        if type(data) == "table" and data.state == "fire" then fired = data end
    end)

    fire(Remotes.RequestBlastStart)
    task.wait(0.35)
    fire(Remotes.RequestBlastRelease, chargeSeconds())

    local waited = 0
    while not fired and waited < 3 do task.wait(0.1); waited = waited + 0.1 end
    conn:Disconnect()

    if not fired then
        note("blast did not fire (cooldown?)")
        return false
    end

    STATE.blasts       = STATE.blasts + 1
    STATE.lastDistance = tonumber(fired.distance) or 0
    if fired.rewardZone and fired.rewardZone.Name then STATE.zoneName = fired.rewardZone.Name end

    local reward = fired.reward
    if reward and reward.rewardToken then
        fire(Remotes.RequestBlastRewardGrant, { rewardToken = reward.rewardToken })
        STATE.granted      = STATE.granted + 1
        STATE.lastReward   = tostring(reward.displayName or reward.id or "?")
        STATE.lastMutation = tostring(reward.mutation or "Normal")
        local q = fired.qualityName and (" " .. tostring(fired.qualityName)) or ""
        note(("blast %s%s -> %s%s"):format(
            STATE.zoneName, q, STATE.lastReward,
            STATE.lastMutation ~= "Normal" and (" [" .. STATE.lastMutation .. "]") or ""))
        return true
    end

    note("blast fired but carried no reward token")
    return false
end

-- ------------------------------------------------------------- lot handling
local function equipBest()
    local reply = safeInvoke(Remotes:FindFirstChild("RequestEquipBestBrainrots"), 8)
    if type(reply) == "table" and reply.success then
        if (tonumber(reply.changed) or 0) > 0 then
            note(("seated best %d brainrots (%d changed)"):format(
                tonumber(reply.placed) or 0, tonumber(reply.changed) or 0))
        end
        return true
    end
    return false
end

local function collectAll()
    -- CollectSlot takes the globally unique slot index and works from anywhere.
    -- Bare CollectAllSlots() pays nothing, so it is deliberately not used.
    -- Only slots actually holding cash are fired at - 40 blind fires per pass is
    -- pure noise once three floors exist.
    local pooled, seen = 0, {}
    for _, s in ipairs(allSlots()) do
        local cash = tonumber(s:GetAttribute("SlotCash")) or 0
        local idx  = tonumber(s:GetAttribute("SlotIndex"))
        if cash > 0 and idx and not seen[idx] then
            seen[idx] = true
            pooled = pooled + cash
            fire(Remotes.CollectSlot, idx)
        end
    end
    if pooled <= 0 then return 0 end
    STATE.collected = STATE.collected + pooled
    return pooled
end

-- ------------------------------------------------------------------ auras
-- The aura tier IS the progression: each step is x10 power rate, gated by cash
-- AND by rebirths. Every tier has a cashCost - the Robux product is only the
-- other way to pay for the same thing, so it is ignored here.
local auraCache = { at = 0, data = nil }

local function auraData(force)
    if not force and auraCache.data and (os.clock() - auraCache.at) < 10 then
        return auraCache.data
    end
    local reply = safeInvoke(Remotes:FindFirstChild("GetAuraUpgradeData"), 8)
    if type(reply) == "table" and reply.catalog then
        auraCache = { at = os.clock(), data = reply }
        return reply
    end
    return auraCache.data
end

-- The next aura worth having: affordable-or-not, but always the best one whose
-- rebirth gate we already pass and whose rate beats what is equipped.
local function nextAura()
    local d = auraData()
    if not d then return nil end
    local rebirths = tonumber(d.rebirths) or num("Rebirths")
    local owned    = d.owned or {}
    local curRate  = 0
    for _, e in ipairs(d.catalog) do
        if e.id == d.equipped then curRate = tonumber(e.rate) or 0 end
    end
    local best = nil
    for _, e in ipairs(d.catalog) do
        local cost = tonumber(e.cashCost) or 0
        local rate = tonumber(e.rate) or 0
        local req  = tonumber(e.requiredRebirths) or 0
        if not owned[e.id] and rate > curRate and req <= rebirths and cost > 0 then
            if (not best) or cost < (tonumber(best.cashCost) or math.huge) then best = e end
        end
    end
    return best, d
end

local function buyAura()
    local target, d = nextAura()
    if not target then return false end
    local cash = num("CashRaw")
    if cash < (tonumber(target.cashCost) or math.huge) then
        note(("saving %s for %s (x%s rate)"):format(
            fmt(target.cashCost), target.displayName or target.id, fmt(target.rate)))
        return false
    end
    local reply = safeInvoke(Remotes:FindFirstChild("RequestAuraPurchase"), 8, target.id)
    if type(reply) == "table" and reply.success then
        STATE.aurasBought = STATE.aurasBought + 1
        auraCache.data = nil
        equipAura()
        note(("aura -> %s (%s/s)"):format(target.displayName or target.id, fmt(target.rate)))
        return true
    end
    return false
end

-- --------------------------------------------------------------- upgrades
-- BaseCost * CostMult^level, read out of the game's own UpgradeConfig.
local UpgradeConfig = nil
pcall(function() UpgradeConfig = require(Modules:WaitForChild("UpgradeConfig")) end)

local UPGRADE_ORDER = { "Inventory", "Strength", "TeleportSpeed", "LotCapacity" }

local function upgradeCost(cat)
    if not (UpgradeConfig and UpgradeConfig[cat]) then return nil end
    local c = UpgradeConfig[cat]
    local base, mult = tonumber(c.BaseCost), tonumber(c.CostMult)
    if not (base and mult) then return nil end
    local lvl = num(cat .. "Level")
    local maxL = tonumber(c.MaxLevel) or 0
    if lvl >= maxL then return nil end
    return base * (mult ^ lvl), lvl, maxL
end

local function buyUpgrades(budget)
    if not UpgradeConfig then return false end
    local bought = false
    for _, cat in ipairs(UPGRADE_ORDER) do
        -- LotCapacity is a capacity number, not slots. Bought at 10 unlocked
        -- slots it changed nothing (measured: 12,100 spent, slot count still 10).
        -- It only earns its price once a floor has been unlocked.
        local skip = (cat == "LotCapacity") and (#unlockedSlots() <= 10)
        local cost = upgradeCost(cat)
        if (not skip) and cost and cost <= budget then
            fire(Remotes.PurchaseUpgrade, cat)
            task.wait(0.35)
            budget = budget - cost
            bought = true
        end
    end
    return bought
end

-- ------------------------------------------------------------- base floors
local BaseExpansionConfig = nil
pcall(function() BaseExpansionConfig = require(Modules:WaitForChild("BaseExpansionConfig")) end)

local function buyBaseFloor(budget)
    if not (BaseExpansionConfig and BaseExpansionConfig.FloorUpgradeCosts) then return false end
    local lot = myLot()
    if not lot then return false end
    for floor = 2, 4 do
        if not floorUnlocked(floor) then
            local cost = tonumber(BaseExpansionConfig.FloorUpgradeCosts[floor])
            if cost and cost <= budget then
                fire(Remotes.PurchaseBaseUpgrade, "Floor" .. floor)
                note(("bought Floor%d for %s"):format(floor, fmt(cost)))
                return true
            end
            return false -- do not skip past a floor we cannot afford yet
        end
    end
    return false
end

-- ---------------------------------------------------------------- rebirth
local RebirthConfig = nil
pcall(function() RebirthConfig = require(Modules:WaitForChild("RebirthConfig")) end)

local function rebirthRequirement()
    local r = num("Rebirths")
    if RebirthConfig and RebirthConfig.GetStrengthRequirement then
        local ok, v = pcall(RebirthConfig.GetStrengthRequirement, r)
        if ok and tonumber(v) then return tonumber(v) end
    end
    return 1000 * (15 ^ r)
end

local function maxRebirths()
    if RebirthConfig and RebirthConfig.GetMaxRebirths then
        local ok, v = pcall(RebirthConfig.GetMaxRebirths)
        if ok and tonumber(v) then return tonumber(v) end
    end
    return tonumber(RebirthConfig and RebirthConfig.MAX_REBIRTHS) or 12
end

-- Rebirth keeps cash, brainrots and auras and adds +1 CashMultiplier. Its only
-- cost is Power, which is also blast distance - so harvest a burst of blasts at
-- peak power first, then reset.
local function tryRebirth()
    if num("Rebirths") >= maxRebirths() then return false end
    local need = rebirthRequirement()
    if num("Strength") < need then return false end

    -- The farm loop drives blasts too. Two routines firing RequestBlastStart at
    -- once just eat each other's cooldown, so the harvest takes the lock.
    if STATE.blastBusy then return false end
    STATE.blastBusy = true

    note(("rebirth ready - harvesting %d blasts at peak power"):format(CONFIG.preRebirthBlasts))
    for _ = 1, CONFIG.preRebirthBlasts do
        if _G.__POWERBLAST ~= GEN or not CONFIG.autoRebirth then break end
        doBlast()
        equipAura()
        task.wait(CONFIG.blastGap)
    end
    equipBest()
    collectAll()

    fire(Events.RequestRebirth)
    task.wait(2)
    STATE.rebirthsDone = STATE.rebirthsDone + 1
    auraCache.data = nil
    STATE.blastBusy = false
    note(("rebirth %d done - cash x%d"):format(num("Rebirths"), num("CashMultiplier")))
    return true
end

-- ---------------------------------------------------------------- freebies
local function claimDaily()
    local state = safeInvoke(Remotes:FindFirstChild("GetDailyRewards"), 8)
    if type(state) ~= "table" or not state.canClaim then return false end
    -- The server refuses out-of-order claims ("Claim your daily rewards in
    -- order."), so walk the days upward and stop at the first refusal.
    local claimed = state.claimedDays or {}
    for day = 1, 7 do
        if not claimed[tostring(day)] then
            local reply = safeInvoke(Remotes:FindFirstChild("ClaimDailyReward"), 8, day)
            if type(reply) == "table" and reply.success then
                note("daily reward day " .. day .. " claimed")
                return true
            end
            return false
        end
    end
    return false
end

local function claimSpin()
    if num("AvailableSpins") <= 0 then return false end
    local reply = safeInvoke(Events:FindFirstChild("RequestSpin"), 8)
    if type(reply) == "table" and reply.success then
        local r = reply.Reward or {}
        note("spin -> " .. tostring(r.DisplayName or r.Type or "reward"))
        return true
    end
    return false
end

local function claimOffline()
    if not attr("OfflineEarningsReady", false) then return false end
    local reply = safeInvoke(Remotes:FindFirstChild("OfflineEarnings"), 8)
    if type(reply) == "table" and (tonumber(reply.amount) or 0) > 0 then
        note("offline earnings +" .. fmt(reply.amount))
        return true
    end
    return false
end

-- ------------------------------------------------------------- loop driver
local function loop(period, key, fn)
    task.spawn(function()
        while _G.__POWERBLAST == GEN do
            if CONFIG[key] and STATE.running then
                local ok, err = pcall(fn)
                if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
            end
            task.wait(period)
        end
    end)
end

-- keep the aura in hand - blasting drops it and Power stops dead
loop(1.0, "keepAuraEquipped", function() equipAura() end)

-- The next zone worth reaching. Power only ever grows, so the target is the
-- cheapest zone threshold still above us.
local function nextZoneTarget()
    local power = num("Power")
    if not (BlastConfig and BlastConfig.Zones) then return power end
    local best = nil
    for _, z in ipairs(BlastConfig.Zones) do
        local minp = tonumber(z.MinPower) or 0
        if minp > power and ((not best) or minp < best) then best = minp end
    end
    return best or power
end

-- The farm alternates two phases, and that is not a nicety.
--
-- Blasting UNEQUIPS the aura, and the aura in hand is the only thing that makes
-- Power. Cycling blasts back to back therefore farms brainrots while Power sits
-- frozen: measured over 20s of continuous blasting, 6 brainrots arrived and
-- Power moved by exactly 0 (the character held no tool at any sample). Since
-- Power is blast distance is zone is rarity, that farm can never climb a tier.
-- So: charge with the aura in hand until the next zone threshold, then spend a
-- short burst of blasts at the higher power, then charge again.
task.spawn(function()
    while _G.__POWERBLAST == GEN do
        if not (STATE.running and CONFIG.autoBlast) then
            STATE.phase = STATE.running and "idle" or "off"
            STATE.pinTarget = nil
            task.wait(0.5)
        else
            -- ---- charge ----
            local target   = nextZoneTarget()
            local deadline = os.clock() + CONFIG.maxChargeSeconds
            STATE.chargeTarget = target
            while _G.__POWERBLAST == GEN and STATE.running and CONFIG.autoBlast
                  and num("Power") < target and os.clock() < deadline do
                STATE.phase = "charging"
                equipAura()
                note(("charging %s / %s for the next zone"):format(fmt(num("Power")), fmt(target)))
                task.wait(0.5)
            end

            -- ---- burst ----
            if not STATE.blastBusy then
                STATE.blastBusy = true
                for i = 1, CONFIG.burstBlasts do
                    if _G.__POWERBLAST ~= GEN or not (STATE.running and CONFIG.autoBlast) then break end
                    STATE.phase = "blasting"
                    local ok, err = pcall(doBlast)
                    if not ok then note("blast failed: " .. tostring(err)) end
                    task.wait(CONFIG.blastGap)
                end
                STATE.blastBusy = false
            end
            equipAura()
        end
    end
    STATE.pinTarget = nil
end)

loop(CONFIG.equipEvery,   "autoEquipBest", function() equipBest() end)
loop(CONFIG.collectEvery, "autoCollect",   function() collectAll() end)

-- spending, in the order the user asked for: power first, then capacity
loop(CONFIG.spendEvery, "autoAura", function()
    local cash = num("CashRaw")
    if not buyAura() then
        -- Only spend on anything else with what the next aura does not need.
        local target = nextAura()
        local reserve = target and (tonumber(target.cashCost) or 0) or 0
        local spare = cash - reserve
        if spare > 0 then
            if CONFIG.autoBaseFloors and buyBaseFloor(spare) then return end
            if CONFIG.autoUpgrades then buyUpgrades(spare) end
        end
    end
end)

loop(10, "autoRebirth", function() tryRebirth() end)

loop(90, "autoDaily",   function() claimDaily() end)
loop(90, "autoSpin",    function() claimSpin() end)
loop(120, "autoOffline", function() claimOffline() end)

-- cash bookkeeping for the header
task.spawn(function()
    while _G.__POWERBLAST == GEN do
        local c = num("CashRaw")
        if STATE.cashStart == nil then STATE.cashStart = c end
        STATE.cashEarned = c - STATE.cashStart
        task.wait(1)
    end
end)

-- ------------------------------------------------------------------ panel
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

-- A run that errored early stores no handle, so sweep the named ScreenGui too.
if _G.__POWERBLAST_WIN then pcall(function() _G.__POWERBLAST_WIN:Destroy() end) end
-- The template parents to gethui() when it exists, CoreGui otherwise, so both
-- have to be swept or a re-execute stacks panels.
for _, parent in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui"), plr:FindFirstChild("PlayerGui") }) do
    pcall(function()
        for _, g in ipairs(parent:GetChildren()) do
            if g.Name == "POWERBLAST_PANEL" then g:Destroy() end
        end
    end)
end

local win = UI.Window({
    title = "POWER", accentTitle = "BLAST", subtitle = "seltonmt",
    badge = "*", width = 920, height = 580, name = "POWERBLAST_PANEL",
})
_G.__POWERBLAST_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local cMain = farm:Card("BLAST", 1)
cMain:Toggle("Auto farm", CONFIG.autoBlast, function(v)
    CONFIG.autoBlast = v
    STATE.running = v or STATE.running
end, "pin in the blast zone and cycle blasts")

cMain:Toggle("Perfect charge", CONFIG.perfectCharge, function(v) CONFIG.perfectCharge = v end,
    "send the full charge time: Perfect quality + max mutation luck", UI.theme.good)

cMain:Toggle("Keep aura equipped", CONFIG.keepAuraEquipped, function(v) CONFIG.keepAuraEquipped = v end,
    "blasting drops the aura and Power stops")

cMain:Slider("Blast gap (s)", 2.5, 6, CONFIG.blastGap, function(v) CONFIG.blastGap = v end)
cMain:Slider("Blasts per burst", 1, 20, CONFIG.burstBlasts, function(v) CONFIG.burstBlasts = math.floor(v) end)
cMain:Slider("Max charge (s)", 15, 300, CONFIG.maxChargeSeconds, function(v) CONFIG.maxChargeSeconds = math.floor(v) end)

local cLot = farm:Card("LOT", 2)
cLot:Toggle("Auto seat best", CONFIG.autoEquipBest, function(v) CONFIG.autoEquipBest = v end,
    "server places the best brainrots itself, from anywhere")
cLot:Toggle("Auto collect", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
    "CollectSlot per slot, works at any distance")
cLot:Button("Seat + collect now", function()
    task.spawn(function() equipBest(); local got = collectAll(); note("collected " .. fmt(got)) end)
end)

local spend = win:Page("SPEND", UI.icon.coin)

local cAura = spend:Card("AURA LADDER", 1)
cAura:Toggle("Auto buy auras", CONFIG.autoAura, function(v) CONFIG.autoAura = v end,
    "x10 power rate per tier - the entire progression", UI.theme.warn)
cAura:Toggle("Auto upgrades", CONFIG.autoUpgrades, function(v) CONFIG.autoUpgrades = v end,
    "only with cash the next aura does not need")
cAura:Toggle("Auto base floors", CONFIG.autoBaseFloors, function(v) CONFIG.autoBaseFloors = v end,
    "100M / 1T / 10Q, +10 slots each", UI.theme.warn)

local cReb = spend:Card("REBIRTH", 2)
cReb:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "keeps cash, brainrots and auras; only zeroes Power", UI.theme.warn)
cReb:Stepper("Harvest blasts first", function() return tostring(CONFIG.preRebirthBlasts) end,
    function(d)
        CONFIG.preRebirthBlasts = math.clamp(CONFIG.preRebirthBlasts + d, 0, 50)
    end, "blasts at peak power before the reset")
cReb:Button("Rebirth now", function() task.spawn(tryRebirth) end, UI.theme.warn)

local cFree = spend:Card("FREE", 0)
cFree:Toggle("Daily reward", CONFIG.autoDaily, function(v) CONFIG.autoDaily = v end,
    "day 3 pays 10M, day 5 pays 1B - claimed in order")
cFree:Toggle("Daily spin", CONFIG.autoSpin, function(v) CONFIG.autoSpin = v end)
cFree:Toggle("Offline earnings", CONFIG.autoOffline, function(v) CONFIG.autoOffline = v end)

-- Readout lives on a card, never on a page.
local cStatus = farm:Card("STATUS", 0)
local out = cStatus:Readout(10)

task.spawn(function()
    while _G.__POWERBLAST == GEN do
        local power    = num("Power")
        local rate     = num("AuraPowerRate")
        local rebirths = num("Rebirths")
        local need     = rebirthRequirement()

        win:SetStatus(("%s cash   %s/s   power %s (%s/s)   %s   R%d"):format(
            fmt(num("CashRaw")), fmt(num("PassiveRate")),
            fmt(power), fmt(rate), zoneForPower(power), rebirths))

        local target = nextAura()
        out:set({
            "FARM",
            ("  phase %s   blasts %d   claimed %d   charge %s/%s"):format(
                STATE.phase, STATE.blasts, STATE.granted, fmt(power), fmt(STATE.chargeTarget)),
            ("  last %s [%s]  zone %s  dist %d"):format(
                STATE.lastReward, STATE.lastMutation, STATE.zoneName, STATE.lastDistance),
            "ECONOMY",
            ("  earned %s   collected %s   aura %s"):format(
                fmt(STATE.cashEarned), fmt(STATE.collected), tostring(attr("EquippedAura", "-"))),
            ("  next aura %s for %s"):format(
                target and (target.displayName or target.id) or "-",
                target and fmt(target.cashCost) or "-"),
            ("  rebirth %d/%d  strength %s / %s"):format(
                rebirths, maxRebirths(), fmt(num("Strength")), fmt(need)),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        win:Refresh()
        task.wait(0.5)
    end
end)

STATE.running = true

-- --------------------------------------------------------------- debug hook
_G.__POWERBLAST_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    doBlast = doBlast, equipBest = equipBest, collectAll = collectAll,
    buyAura = buyAura, nextAura = nextAura, auraData = auraData,
    buyUpgrades = buyUpgrades, buyBaseFloor = buyBaseFloor,
    tryRebirth = tryRebirth, rebirthRequirement = rebirthRequirement,
    nextZoneTarget = nextZoneTarget, zoneForPower = zoneForPower,
    claimDaily = claimDaily, claimSpin = claimSpin, claimOffline = claimOffline,
    equipAura = equipAura, allSlots = allSlots, unlockedSlots = unlockedSlots,
    floorUnlocked = floorUnlocked, myLot = myLot,
    safeInvoke = safeInvoke, fmt = fmt,
}

print("[powerblast] loaded - gen " .. GEN .. ", RightShift for the panel")
