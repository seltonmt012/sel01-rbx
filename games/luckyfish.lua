--[[
    luckyfish.lua - "Pull a Lucky Fish"  place 112781315318195
    ---------------------------------------------------------------------------
    Loop: cast into the fishing zone -> the server decides the fish at THROW time
    -> collect it -> place it on a base slot -> it earns cash per second ->
    collect, upgrade, sell the rest, train strength, climb the rods.

    The game runs on Red (all traffic multiplexed through two RemoteEvents),
    Reflex for state and ProfileService for saving. Nothing had to be captured:
    `shared.Remotes` enumerates ~170 events in plain text, each an object with
    :Fire(...) / :Call(...):Await().

    VERIFIED, and every one of these cost a measurement:

      * ORACLE: ClientPlayerData.serverProfile:getState() is the complete profile,
        locally, with no remote call. There is no leaderstats in this game.
      * ThrowData:Call(accuracy, limit) takes the CLIENT's accuracy as a 0..1
        number - the power bar is never needed. Measured: 0.05 -> 5.25 studs /
        luck 2.175, 0.50 -> 52.5 / 3.75, 1.00 -> 105 / 5.5. Distance is exactly
        105 * accuracy at 120 throw power. Sending 5.0 also gives 105, so the
        server clamps at 1.0 - there is no cheating past PERFECT, only skipping
        the minigame. `CustomThrowPowerLimit` is ignored.
      * THE CATCH IS ONE CALL, NOT A POLL. GetFishToRecive:Call() must be fired
        EXACTLY ONCE after the cast. Polling it every 2s returns nil forever and
        burns the pending catch - that cost the longest detour here. A single
        call at 8s, 14s and 20s each landed a fish; 8s is enough.
      * The reeling minigame (rapid clicking) and the power bar are both purely
        client side. The server wants the number and the one collect call.
      * DO NOT press the real FISH! button (ThrowFrame.KickButton) to start a
        cast. It opens the power bar and waits for input that never comes, which
        freezes the client with the bar stuck on screen. unstuck() below is the
        recovery: SetFishState(false) + the live ThrowSystem's own RecoverThrow.
      * Placing is RequestPlaceFish{ConfigName = "Tuna", BaseSlotIndexName = "9"};
        slot names are numeric STRINGS. Inventory keys are "Name@Level@Mutation"
        (e.g. "Tuna@1@Gold").
      * Train:Fire() takes no arguments and is the strength engine - the real
        client fires it 4-6 times per second while holding the training tool.

    Panel: RightShift.  Console handle: _G.__LUCKYFISH_DBG
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local plr = Players.LocalPlayer

local Remotes = require(ReplicatedStorage.shared.Remotes)
local CPD     = require(ReplicatedStorage.client.ClientPlayerData)
local config  = ReplicatedStorage.shared.config

-- ---------------------------------------------------------------- generation
_G.__LUCKYFISH = (_G.__LUCKYFISH or 0) + 1
local GEN = _G.__LUCKYFISH

-- ------------------------------------------------------------------- config
local CONFIG = {
    autoFish       = false,  -- the cast loop
    accuracy       = 1.0,    -- 1.0 = PERFECT, server clamps anything above
    collectDelay   = 8,      -- measured floor; 8/14/20 all landed a fish
    autoPlace      = true,   -- seat caught fish on free base slots
    autoCollect    = true,   -- collect each slot's earnings
    autoUpgrade    = true,   -- level placed fish
    autoSell       = false,  -- sell what does not fit (off: it is destructive)
    autoTrain      = true,   -- Train:Fire() strength engine
    autoSpeed      = true,   -- pull / throw / roll speed ladders
    autoRod        = true,   -- buy + equip the best affordable rod
    autoTool       = true,   -- buy + equip the best affordable training tool
    autoEquipBest  = true,   -- buy + use the game's own best-fish placer
    autoFreebies   = true,   -- free gift, daily login, offline money
    autoRebirth    = false,  -- opt in

    trainRate      = 8,      -- Train calls per second while holding the dumbbell
    trainSeconds   = 20,     -- training window before each cast (0 = never)
    keepMoney      = 0,
    keepBestFish   = 5,      -- surplus below this rank is sold
}

-- -------------------------------------------------------------------- state
local STATE = {
    running = false, phase = "off", note = "",
    casts = 0, caught = 0, placed = 0, collected = 0, upgrades = 0,
    lastFish = "-", lastDistance = 0, busy = false,
    moneyStart = nil, moneyEarned = 0, pinTarget = nil,
}

-- --------------------------------------------------------------- small util
local function state() return CPD.serverProfile:getState() end
local function money() return (state().money) or 0 end

local SUF = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
    n = tonumber(n) or 0
    if n < 1000 then return (n % 1 == 0) and tostring(math.floor(n)) or string.format("%.1f", n) end
    local i = 1
    while n >= 1000 and i < #SUF do n = n / 1000; i = i + 1 end
    return string.format("%.2f%s", n, SUF[i])
end

local function note(s) STATE.note = s end
local function count(t) local n = 0; if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end; return n end

-- Red :Call() can hang; never await one bare.
local function callGuarded(event, timeout, ...)
    local args = table.pack(...)
    local done, ok, res = false, nil, nil
    task.spawn(function()
        pcall(function() ok, res = event:Call(table.unpack(args, 1, args.n)):Await() end)
        done = true
    end)
    local t = 0
    timeout = timeout or 9
    while not done and t < timeout do task.wait(0.2); t = t + 0.2 end
    return done and ok or nil, res
end

local function fire(event, ...)
    if not event then return false end
    local a = table.pack(...)
    pcall(function() event:Fire(table.unpack(a, 1, a.n)) end)
    return true
end

-- ------------------------------------------------------------ world lookups
local function character() local c = plr.Character; return (c and c.Parent) and c or nil end
local function rootPart() local c = character(); return c and c:FindFirstChild("HumanoidRootPart") or nil end
local function throwZone() return workspace:FindFirstChild("ThrowZone") end

-- One shared Heartbeat pin.
task.spawn(function()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if _G.__LUCKYFISH ~= GEN then conn:Disconnect(); return end
        local t = STATE.pinTarget
        local hrp = rootPart()
        if t and hrp then hrp.CFrame = CFrame.new(t) end
    end)
end)

-- ----------------------------------------------------------------- unstuck
-- The power bar can be left open (this happens if the real FISH! button is
-- pressed programmatically). Recovery is the client's own RecoverThrow.
local function unstuck()
    fire(Remotes.SetFishState, false)
    local sys
    for _, v in ipairs(getgc(true)) do
        if type(v) == "table" and rawget(v, "RecoverThrow") and rawget(v, "_collectCastGeneration") ~= nil then
            sys = v; break
        end
    end
    if sys then pcall(function() sys:RecoverThrow("luckyfish unstuck") end) end
    pcall(function()
        local Satchel = require(ReplicatedStorage.client.Satchel)
        if Satchel and Satchel.SetEnabled then Satchel.SetEnabled(true) end
    end)
    pcall(function() game:GetService("StarterGui"):SetCore("ResetButtonCallback", true) end)
    pcall(function()
        local pm = plr.PlayerScripts:FindFirstChild("PlayerModule")
        if pm then require(pm):GetControls():Enable() end
    end)
    local ch = character()
    if ch then
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum then hum.PlatformStand = false; hum.AutoRotate = true end
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        if hrp then hrp.Anchored = false end
    end
    STATE.busy = false
    note("unstuck")
end

-- ----------------------------------------------------------------- training
-- Strength IS the throw power, and throw power is cast distance, which is what
-- decides the fish tier. Two things had to be right and neither is obvious:
--   1. The dumbbell must actually be HELD. Humanoid:EquipTool() fails silently
--      here - the character keeps holding nothing. Pressing hotbar key 1 through
--      VirtualInputManager works.
--   2. Train:Fire() only credits OUTSIDE the fishing zone.
-- Measured while holding it outside the zone: strength 138 -> 238 in one minute.
-- Firing Train without the dumbbell held credits exactly 0.
local function equipDumbbell()
    local ch = character()
    if not ch then return false end
    local want = state().trainingTool
    if want and ch:FindFirstChild(want) then return true end
    fire(Remotes.SetFishState, false)
    pcall(function()
        local S = require(ReplicatedStorage.client.Satchel)
        if S and S.SetEnabled then S.SetEnabled(true) end
    end)
    local VIM = game:GetService("VirtualInputManager")
    VIM:SendKeyEvent(true, Enum.KeyCode.One, false, game)
    task.wait(0.15)
    VIM:SendKeyEvent(false, Enum.KeyCode.One, false, game)
    task.wait(0.6)
    return ch:FindFirstChild(want or "") ~= nil
end

local function trainPhase(seconds)
    local zone = throwZone()
    if not zone then return false end
    if not equipDumbbell() then note("dumbbell would not equip"); return false end

    STATE.phase = "training"
    -- deliberately far outside the zone: in the zone Train credits nothing
    STATE.pinTarget = zone.Position + Vector3.new(0, 4, 150)
    task.wait(0.8)
    local before = state().strength
    local t0 = os.clock()
    while os.clock() - t0 < seconds do
        if _G.__LUCKYFISH ~= GEN or not STATE.running or not CONFIG.autoTrain then break end
        fire(Remotes.Train)
        task.wait(1 / math.max(1, CONFIG.trainRate))
    end
    STATE.pinTarget = nil
    local gained = state().strength - before
    STATE.trained = (STATE.trained or 0) + gained
    note(("trained +%s power (now %s)"):format(fmt(gained), fmt(state().strength)))
    return true
end

-- ------------------------------------------------------------------ fishing
-- The whole cast, exactly as measured. The power bar and the reel minigame are
-- client side only and are skipped.
local function castOnce()
    local zone, hrp = throwZone(), rootPart()
    if not (zone and hrp) then note("no throw zone"); return false end

    STATE.pinTarget = zone.Position + Vector3.new(0, 4, 0)
    STATE.phase = "casting"
    task.wait(1)

    fire(Remotes.SetFishState, true)
    task.wait(0.5)

    local ok, info = callGuarded(Remotes.ThrowData, 9, CONFIG.accuracy, nil)
    if not (ok and type(info) == "table") then
        fire(Remotes.SetFishState, false)
        STATE.pinTarget = nil
        note("throw refused")
        return false
    end
    STATE.casts = STATE.casts + 1
    STATE.lastDistance = (info.ThrowInfo and info.ThrowInfo.ThrowDistance) or 0
    note(("cast %s studs -> %s"):format(fmt(STATE.lastDistance), tostring(info.FishDropName)))

    -- ONE collect call. Polling returns nil forever and loses the fish.
    STATE.phase = "reeling"
    task.wait(CONFIG.collectDelay)

    local _, fish = callGuarded(Remotes.GetFishToRecive, 9)
    fire(Remotes.SetFishState, false)
    STATE.pinTarget = nil

    if type(fish) == "table" and fish.Fish then
        STATE.caught = STATE.caught + 1
        STATE.lastFish = tostring(fish.Fish)
        note("caught " .. STATE.lastFish)
        return true
    end
    note("cast produced no fish (try a longer collect delay)")
    return false
end

-- ---------------------------------------------------------------- placement
-- THERE ARE FIVE MODELS CALLED workspace.Map.Base AND FindFirstChild RETURNS A
-- STRANGER'S. Ours is identified by matching the fish it displays against our
-- own baseSlots. Working against the wrong plot is silent: every place call is
-- simply ignored, which cost a long detour here.
local function ourBase()
    if STATE.base and STATE.base.Parent then return STATE.base end
    local s = state()
    local mine = {}
    for _, v in pairs(s.baseSlots or {}) do
        if type(v) == "table" and v.FishPlaced then mine[v.FishPlaced] = true end
    end
    local map = workspace:FindFirstChild("Map")
    if not map then return nil end
    for _, b in ipairs(map:GetChildren()) do
        if b:IsA("Model") and b.Name == "Base" then
            for _, t in ipairs(b:GetDescendants()) do
                if t:IsA("TextLabel") and t.Name == "DisplayName" and mine[t.Text] then
                    STATE.base = b
                    return b
                end
            end
        end
    end
    return nil
end

-- Fish arrive as Tools literally named "Tool", tagged IsPlaceableFish.
local function fishTools()
    local out = {}
    for _, c in ipairs(plr.Backpack:GetChildren()) do
        if c:GetAttribute("IsPlaceableFish") then out[#out + 1] = c end
    end
    return out
end

-- RequestPlaceFish alone does nothing. The real path is the slot's own
-- ProximityPrompt - and those prompts DO NOT EXIST until a placeable fish is
-- equipped. Holding one makes "Place" appear on every free placement and
-- "Replace" on the occupied ones.
local function placeAll()
    local base = ourBase()
    if not base then note("our base not identified"); return false end
    local ch = character()
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if not hum then return false end

    local n = 0
    for _ = 1, 12 do
        if _G.__LUCKYFISH ~= GEN then break end
        local tools = fishTools()
        if #tools == 0 then break end
        pcall(function() hum:EquipTool(tools[1]) end)
        task.wait(0.4)

        local prompt
        for _, d in ipairs(base:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.ActionText == "Place" and d.Enabled then prompt = d; break end
        end
        if not prompt then note("no free slot - base full"); break end

        local parent = prompt.Parent
        local anchor = parent:IsA("BasePart") and parent.Position or parent:GetPivot().Position
        local before = count(state().baseSlots)
        STATE.pinTarget = anchor + Vector3.new(0, 3, 0)
        task.wait(0.7)
        pcall(fireproximityprompt, prompt)
        task.wait(1.0)
        STATE.pinTarget = nil
        if count(state().baseSlots) > before then n = n + 1 else break end
    end
    if n > 0 then
        STATE.placed = STATE.placed + n
        note(("placed %d fish"):format(n))
    end
    return n > 0
end

-- ------------------------------------------------------------------ selling
-- SellFish takes the INVENTORY KEY ("Tuna@1@Gold"), not the plain name. Only
-- ever runs when the base is full, and it keeps the most valuable entries.
local fishValues
local function fishValue(configName)
    if not fishValues then
        fishValues = {}
        local ok, FC = pcall(require, config.FishConfig)
        if ok and type(FC) == "table" then
            for name, data in pairs(FC) do
                if type(data) == "table" then
                    -- the field name is read out of the config, never assumed
                    local v = data.Price or data.Value or data.Cash or data.Earnings or data.SellPrice
                    fishValues[name] = tonumber(v) or 0
                end
            end
        end
    end
    return fishValues[configName] or 0
end

local function sellSurplus(keepBest)
    keepBest = keepBest or 5
    local s = state()
    local list = {}
    for key, entry in pairs(s.inventory or {}) do
        if type(entry) == "table" and entry.Category == "Fish" and entry.ConfigName then
            list[#list + 1] = { key = key, name = entry.ConfigName, value = fishValue(entry.ConfigName) }
        end
    end
    if #list <= keepBest then return false end
    table.sort(list, function(a, b) return a.value > b.value end)

    local sold, before = 0, money()
    for i = keepBest + 1, #list do
        if _G.__LUCKYFISH ~= GEN then break end
        fire(Remotes.SellFish, list[i].key)
        task.wait(0.25)
        sold = sold + 1
    end
    if sold > 0 then
        note(("sold %d surplus fish for %s (kept the best %d)"):format(sold, fmt(money() - before), keepBest))
    end
    return sold > 0
end

-- -------------------------------------------------------------- collect cash
local function collectCash()
    local s = state()
    local pending = 0
    for slot, data in pairs(s.baseSlots or {}) do
        pending = pending + ((type(data) == "table" and tonumber(data.Earnings)) or 0)
        fire(Remotes.RequestCollectCash, tostring(slot))
    end
    if pending > 0 then
        STATE.collected = STATE.collected + pending
        note("collected " .. fmt(pending))
    end
    return pending
end

-- -------------------------------------------------------------- fish levels
local function upgradeFish(budget)
    local s = state()
    local slots = {}
    for slot, data in pairs(s.baseSlots or {}) do
        slots[#slots + 1] = { slot = tostring(slot), level = (type(data) == "table" and tonumber(data.Level)) or 1 }
    end
    -- cheapest next level first
    table.sort(slots, function(a, b) return a.level < b.level end)
    local done, spent = 0, 0
    for _, e in ipairs(slots) do
        if done >= 4 then break end
        local before = money()
        if before - CONFIG.keepMoney <= 0 then break end
        fire(Remotes.RequestUpgradeFish, e.slot)
        task.wait(0.4)
        local after = money()
        if after < before then
            spent = spent + (before - after)
            done = done + 1
            if spent > budget then break end
        end
    end
    if done > 0 then
        STATE.upgrades = STATE.upgrades + done
        note(("upgraded %d fish for %s"):format(done, fmt(spent)))
    end
    return done > 0
end

-- ------------------------------------------------------------ speed ladders
-- Three tracks, all argument-free, all confirmed by the balance moving.
local SPEED = {
    { field = "pullSpeed",  remote = "RequestUpgradePullSpeed",  label = "swim" },
    { field = "throwSpeed", remote = "RequestUpgradeThrowSpeed", label = "throw" },
    { field = "rollSpeed",  remote = "RequestUpgradeRollSpeed",  label = "roll" },
}

local function buySpeed(budget)
    local bought, spent = 0, 0
    for _, up in ipairs(SPEED) do
        if bought >= 3 then break end
        local before = money()
        if before - CONFIG.keepMoney <= 0 then break end
        fire(Remotes[up.remote])
        task.wait(0.35)
        local after = money()
        if after < before then
            spent = spent + (before - after); bought = bought + 1
            if spent > budget then break end
        end
    end
    if bought > 0 then note(("speed upgrades x%d for %s"):format(bought, fmt(spent))) end
    return bought > 0
end

-- ------------------------------------------------------------ rods and tools
local function bestAffordable(cfgModule, ownedCheck)
    local ok, C = pcall(require, cfgModule)
    if not ok then return nil end
    local cash = money() - CONFIG.keepMoney
    local best, bestCost = nil, -1
    for id, data in pairs(C) do
        if type(data) == "table" then
            local cost = tonumber(data.Cost)
            -- Cost -1 means it is not purchasable with cash at all
            if cost and cost >= 0 and cost <= cash and cost > bestCost then
                best, bestCost = id, cost
            end
        end
    end
    return best, bestCost
end

local function buyRod()
    local s = state()
    local best, cost = bestAffordable(config.FishRodConfig)
    if not best or best == s.fishRod then return false end
    local before = money()
    fire(Remotes.BuyFishRod, best)
    task.wait(0.6)
    fire(Remotes.EquipFishRod, best)
    task.wait(0.4)
    if state().fishRod == best then
        note(("rod -> %s for %s"):format(best, fmt(before - money())))
        return true
    end
    return false
end

local function buyTool()
    local s = state()
    local best = bestAffordable(config.TrainToolConfig)
    if not best or best == s.trainingTool then return false end
    local before = money()
    fire(Remotes.BuyTrainingTool, best)
    task.wait(0.6)
    fire(Remotes.EquipTrainingTool, best)
    task.wait(0.4)
    if state().trainingTool == best then
        note(("training tool -> %s for %s"):format(best, fmt(before - money())))
        return true
    end
    return false
end

-- ---------------------------------------------------------------- freebies
local function freebies()
    local s = state()
    local before = money()
    if not s.freeGiftClaimed then fire(Remotes.RequestFreeGiftClaim) ; task.wait(0.4) end
    if (tonumber(s.dailyLoginLastClaim) or 0) == 0 then fire(Remotes.RequestClaimDailyLogin); task.wait(0.4) end
    if (tonumber(s.offlineMoney) or 0) > 0 then fire(Remotes.ClaimOfflineMoney); task.wait(0.4) end
    local gained = money() - before
    if gained > 0 then note("freebies +" .. fmt(gained)) end
    return gained > 0
end

local function redeemCode(code)
    fire(Remotes.RequestCodeRedeem, tostring(code))
    note("redeemed " .. tostring(code))
end

local function rebirth()
    fire(Remotes.RequestRebirth)
    task.wait(1.5)
    note("rebirth fired")
end

-- ------------------------------------------------------------- loop driver
local function loop(period, key, fn)
    task.spawn(function()
        while _G.__LUCKYFISH == GEN do
            if CONFIG[key] and STATE.running then
                local ok, err = pcall(fn)
                if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
            end
            task.wait(period)
        end
    end)
end

-- The main loop alternates training and fishing, because they need opposite
-- positions: Train only credits outside the zone, casting only works inside it.
task.spawn(function()
    while _G.__LUCKYFISH == GEN do
        if STATE.running and CONFIG.autoFish and not STATE.busy then
            STATE.busy = true
            if CONFIG.autoTrain and CONFIG.trainSeconds > 0 then
                local ok, err = pcall(trainPhase, CONFIG.trainSeconds)
                if not ok then note("train failed: " .. tostring(err)) end
            end
            local ok, err = pcall(castOnce)
            if not ok then note("cast failed: " .. tostring(err)); unstuck() end
            if CONFIG.autoPlace then pcall(placeAll) end
            STATE.busy = false
        else
            STATE.phase = STATE.running and (CONFIG.autoFish and "waiting" or "idle") or "off"
            task.wait(0.5)
        end
        task.wait(0.3)
    end
    STATE.pinTarget = nil
end)

loop(6,  "autoCollect", function() collectCash() end)
loop(30, "autoSell",    function() sellSurplus(CONFIG.keepBestFish) end)

-- The game's own "Equip Best" - 500,000 once, 10s cooldown - seats the best
-- fish by itself, which beats reimplementing the ranking. Bought automatically
-- when it is affordable, then used on its cooldown.
loop(12, "autoEquipBest", function()
    local s = state()
    if not s.hasEquipBest then
        if money() >= 500000 then
            local before = money()
            fire(Remotes.RequestBuyEquipBest)
            task.wait(2)
            if state().hasEquipBest then note(("unlocked Equip Best for %s"):format(fmt(before - money()))) end
        end
        return
    end
    fire(Remotes.RequestEquipBest)
end)
loop(15, "autoUpgrade", function() upgradeFish(money() - CONFIG.keepMoney) end)
loop(20, "autoSpeed",   function() buySpeed(money() - CONFIG.keepMoney) end)
loop(25, "autoRod",     function() buyRod() end)
loop(25, "autoTool",    function() buyTool() end)
loop(90, "autoFreebies", function() freebies() end)

task.spawn(function()
    while _G.__LUCKYFISH == GEN do
        local m = money()
        if STATE.moneyStart == nil then STATE.moneyStart = m end
        STATE.moneyEarned = m - STATE.moneyStart
        task.wait(1)
    end
end)

-- ------------------------------------------------------------------ panel
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

for _, parent in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui"), plr:FindFirstChild("PlayerGui") }) do
    pcall(function()
        for _, g in ipairs(parent:GetChildren()) do
            if g.Name == "LUCKYFISH_PANEL" then g:Destroy() end
        end
    end)
end

local win = UI.Window({
    title = "LUCKY", accentTitle = "FISH", subtitle = "seltonmt",
    badge = "*", width = 920, height = 580, name = "LUCKYFISH_PANEL",
})
_G.__LUCKYFISH_WIN = win

local farm = win:Page("FISHING", UI.icon.wave)

local cCast = farm:Card("CAST", 1)
cCast:Toggle("Auto fish", CONFIG.autoFish, function(v)
    CONFIG.autoFish = v; STATE.running = STATE.running or v
end, "full cast loop - no power bar, no reeling needed")
cCast:Slider("Accuracy", 0.1, 1.0, CONFIG.accuracy, function(v) CONFIG.accuracy = v end)
cCast:Slider("Collect delay (s)", 5, 30, CONFIG.collectDelay, function(v) CONFIG.collectDelay = v end)
cCast:Slider("Train before cast (s)", 0, 60, CONFIG.trainSeconds, function(v) CONFIG.trainSeconds = math.floor(v) end)
cCast:Button("Cast once", function() task.spawn(function()
    if STATE.busy then return end
    STATE.busy = true; pcall(castOnce); pcall(placeAll); STATE.busy = false
end) end)
cCast:Button("UNSTUCK", function() task.spawn(unstuck) end, UI.theme.bad)

local cBase = farm:Card("BASE", 2)
cBase:Toggle("Auto place", CONFIG.autoPlace, function(v) CONFIG.autoPlace = v end, "seat caught fish on a free slot")
cBase:Toggle("Auto collect", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end)
cBase:Toggle("Auto upgrade fish", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
    "levels placed fish, cheapest slot first", UI.theme.good)
cBase:Button("Collect now", function() task.spawn(function() note("collected " .. fmt(collectCash())) end) end)

local spend = win:Page("SPEND", UI.icon.coin)
local cSpend = spend:Card("UPGRADES", 1)
cSpend:Toggle("Speed ladders", CONFIG.autoSpeed, function(v) CONFIG.autoSpeed = v end, "swim / throw / roll")
cSpend:Toggle("Buy best rod", CONFIG.autoRod, function(v) CONFIG.autoRod = v end,
    "best affordable, Cost -1 entries are skipped", UI.theme.warn)
cSpend:Toggle("Buy training tool", CONFIG.autoTool, function(v) CONFIG.autoTool = v end,
    "best affordable dumbbell", UI.theme.warn)
cSpend:Toggle("Train strength", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end, "Train:Fire(), 5/s")

local cMisc = spend:Card("FREE / RESET", 2)
cMisc:Toggle("Freebies", CONFIG.autoFreebies, function(v) CONFIG.autoFreebies = v end, "gift, daily login, offline money")
cMisc:Toggle("Auto sell leftovers", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
    "off by default - selling is destructive", UI.theme.bad)
cMisc:Button("Rebirth now", function() task.spawn(rebirth) end, UI.theme.warn)

local cOut = farm:Card("STATUS", 0)
local out = cOut:Readout(10)

task.spawn(function()
    while _G.__LUCKYFISH == GEN do
        local s = state()
        local slots = count(s.baseSlots)
        local rate = 0
        for _, d in pairs(s.baseSlots or {}) do
            if type(d) == "table" then rate = rate + (tonumber(d.Earnings) or 0) end
        end
        win:SetStatus(("%s cash   %d fish placed   %s pending   rod %s   caught %d"):format(
            fmt(s.money), slots, fmt(rate), tostring(s.fishRod), s.stats and s.stats.fishCaught or 0))
        out:set({
            "FISHING",
            ("  phase %s   casts %d   caught %d   last %s"):format(STATE.phase, STATE.casts, STATE.caught, STATE.lastFish),
            ("  distance %s   inventory %d"):format(fmt(STATE.lastDistance), count(s.inventory)),
            "BASE",
            ("  %d slots used   placed %d   upgraded %d"):format(slots, STATE.placed, STATE.upgrades),
            ("  earned %s   collected %s"):format(fmt(STATE.moneyEarned), fmt(STATE.collected)),
            "STATS",
            ("  strength %s   throw %s   pull %s   roll %s   rebirth %s"):format(
                fmt(s.strength), fmt(s.throwSpeed), fmt(s.pullSpeed), fmt(s.rollSpeed), tostring(s.rebirthLevel)),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        win:Refresh()
        task.wait(0.5)
    end
end)

STATE.running = true

_G.__LUCKYFISH_DBG = {
    CONFIG = CONFIG, STATE = STATE, Remotes = Remotes,
    state = state, money = money, fmt = fmt,
    castOnce = castOnce, placeAll = placeAll, collectCash = collectCash,
    trainPhase = trainPhase, equipDumbbell = equipDumbbell,
    upgradeFish = upgradeFish, buySpeed = buySpeed, buyRod = buyRod, buyTool = buyTool,
    freebies = freebies, redeemCode = redeemCode, rebirth = rebirth,
    unstuck = unstuck, bestAffordable = bestAffordable,
    ourBase = ourBase, fishTools = fishTools, sellSurplus = sellSurplus, fishValue = fishValue,
}

print("[luckyfish] loaded - gen " .. GEN .. ", RightShift for the panel")
