--[[
    beflash.lua - "[Galaxy] Be Flash For Brainrots!"  place 136066387156306
    ---------------------------------------------------------------------------
    Loop, as measured through the bridge:

      stand in the charge zone -> dash -> the run breaks blocks along the lane
      -> brainrots arrive as TOOLS -> seat them on the plot's ModelStands
      -> each stand earns Money per second -> collect -> spend on stamina,
         stand levels and more stands -> rebirth

    Verified, and each one cost a measurement (do not re-derive):

      * THE DASH HAS THREE GATES, and all three have to hold or the run is
        silently refused - no error, no movement, nothing:
          1. the character must be inside Map.Plot.ChargeZoneGroup.ChargeZoneTrigger
          2. Humanoid.WalkSpeed must be <= 35. Ours idles at 287.45, which is
             why every early attempt did nothing at all.
          3. it must be triggered by a real LeftShift through VirtualInputManager.
        Replaying the remote by hand does NOT work: the published script's
        DashEvent:FireServer("StartCharge"/3/"EndWarp"/"ClearDash") at 10 Hz
        moved nothing - no Warping, no IsDashing, no blocks, no stamina.
      * Brainrots arrive as Tools in the Backpack. workspace.Carrys stays empty
        and workspace.Blocks is ALWAYS 0 - the block is resolved server side and
        OpenBlockEffect is only the receipt. Count that event, not the folder.
      * Collecting is firetouchinterest on each stand's StandClaimHitbox and is
        NOT position gated: measured 722 collected from 730 studs away. The
        StandClaim part itself carries no TouchInterest - only the Hitbox does.
      * Placing is the stand's EquipPrompt ("Place here"), 8 studs.
      * Steering into the Slipstreams at x = +-25 did NOT extend the run at low
        stamina: straight 587 studs / 1 block, steered-to-25 587 / 1, wide-steer
        395 / 1. Distance is a stamina function, not a steering function. Writing
        the CFrame during the flight CANCELS the dash outright (0 studs).
      * TrainTreadmillEvent credits Stamina only, needs the Treadmill equipped,
        and is hard throttled to exactly 1 credit per second - 30 extra calls in
        the same 6s window still gave +6. Spamming is worthless.
      * leaderstats.Money is a StringValue (display only). RawMoney is the number.
      * SpeedWall_<n> carries ReqSpeed as an attribute: 100, 1000, 15000, 225000,
        3.375M, 50M, 750M, 11.25B ... - that ladder is the whole progression.

    Panel: RightShift.  Console handle: _G.__BEFLASH_DBG
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local RunService          = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local plr = Players.LocalPlayer

local Remotes   = ReplicatedStorage:WaitForChild("Remotes", 10)
local Events    = ReplicatedStorage:WaitForChild("Events", 10)
local RemoteGUI = ReplicatedStorage:WaitForChild("RemoteGUI", 10)
local Functions = ReplicatedStorage:WaitForChild("Functions", 10)
local DashEvent = ReplicatedStorage:WaitForChild("DashEvent", 10)

-- ---------------------------------------------------------------- generation
_G.__BEFLASH = (_G.__BEFLASH or 0) + 1
local GEN = _G.__BEFLASH

-- ------------------------------------------------------------------- config
local CONFIG = {
    autoDash      = false,  -- the acquisition loop
    autoPlace     = true,   -- seat brainrot tools on free stands
    autoCollect   = true,   -- drain every stand, works from anywhere
    autoTrain     = true,   -- hold the treadmill for stamina (1/s, throttled)
    autoBuyRank   = true,   -- climb the treadmill rank ladder
    autoLevel     = true,   -- level placed brainrots
    autoPlot      = true,   -- buy more stands
    autoOffline   = true,   -- claim offline earnings
    autoRebirth   = false,  -- wipes stamina, so opt-in

    chargeHold    = 2.2,    -- seconds to hold LeftShift
    flightWait    = 6.5,    -- seconds to let the run finish
    maxLevel      = 12,     -- stop levelling here; cost doubles, revenue +20%
    levelsPerPass = 4,
    keepMoney     = 0,      -- floor never spent
}

-- -------------------------------------------------------------------- state
local STATE = {
    running    = false,
    phase      = "off",
    note       = "",
    dashes     = 0,
    blocks     = 0,
    placed     = 0,
    collected  = 0,
    levels     = 0,
    ranksBought= 0,
    lastReward = "-",
    maxZ       = 0,
    pinTarget  = nil,
    busy       = false,
    moneyStart = nil,
    moneyEarned= 0,
}

-- --------------------------------------------------------------- small util
local function attr(n, d) local v = plr:GetAttribute(n); if v == nil then return d end; return v end
local function num(n) return tonumber(attr(n, 0)) or 0 end
local function money() return num("RawMoney") end
local function stamina() return num("Stamina") end

local SUF = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function fmt(n)
    n = tonumber(n) or 0
    if n < 1000 then return (n % 1 == 0) and tostring(math.floor(n)) or string.format("%.1f", n) end
    local i = 1
    while n >= 1000 and i < #SUF do n = n / 1000; i = i + 1 end
    return string.format("%.2f%s", n, SUF[i])
end

local function note(s) STATE.note = s end

-- Every RemoteFunction goes through here. Functions.GetStaminaFunc never
-- returns (it wants an argument the client never supplies) and would park the
-- whole script inside the bridge poll loop.
local function safeInvoke(remote, timeout, ...)
    if not (remote and remote:IsA("RemoteFunction")) then return nil end
    local args = table.pack(...)
    local done, res = false, nil
    task.spawn(function()
        local ok, r = pcall(function() return remote:InvokeServer(table.unpack(args, 1, args.n)) end)
        res = ok and r or nil
        done = true
    end)
    local t = 0
    timeout = timeout or 8
    while not done and t < timeout do task.wait(0.1); t = t + 0.1 end
    return done and res or nil
end

local function fire(remote, ...)
    if remote and remote:IsA("RemoteEvent") then
        local a = table.pack(...)
        pcall(function() remote:FireServer(table.unpack(a, 1, a.n)) end)
        return true
    end
    return false
end

-- ------------------------------------------------------------ world lookups
local function character() local c = plr.Character; return (c and c.Parent) and c or nil end
local function rootPart() local c = character(); return c and c:FindFirstChild("HumanoidRootPart") or nil end
local function humanoid() local c = character(); return c and c:FindFirstChildOfClass("Humanoid") or nil end

local function myPlot()
    local plots = workspace:FindFirstChild("Plots")
    if not plots then return nil end
    for _, b in ipairs(plots:GetChildren()) do
        if b:GetAttribute("Owner") == plr.UserId then return b end
    end
    -- the player attribute names it directly as a fallback
    local named = attr("Plot")
    return named and plots:FindFirstChild(named) or nil
end

local function chargeTrigger()
    local map = workspace:FindFirstChild("Map")
    local plot = map and map:FindFirstChild("Plot")
    local grp = plot and plot:FindFirstChild("ChargeZoneGroup")
    return grp and grp:FindFirstChild("ChargeZoneTrigger") or nil
end

local function stands()
    local lot = myPlot()
    local ms = lot and lot:FindFirstChild("ModelStands")
    return ms and ms:GetChildren() or {}
end

-- Brainrots are Tools, everywhere except the Treadmill.
local function brainrotTools()
    local out = {}
    local ch = character()
    if ch then for _, c in ipairs(ch:GetChildren()) do
        if c:IsA("Tool") and c.Name ~= "Treadmill" then out[#out + 1] = c end
    end end
    for _, c in ipairs(plr.Backpack:GetChildren()) do
        if c:IsA("Tool") and c.Name ~= "Treadmill" then out[#out + 1] = c end
    end
    return out
end

local function myBrainrots()
    local out = {}
    local wb = workspace:FindFirstChild("WorkingBrainrots")
    if not wb then return out end
    for _, m in ipairs(wb:GetChildren()) do
        if m:GetAttribute("OwnerId") == plr.UserId then out[#out + 1] = m end
    end
    return out
end

-- ------------------------------------------------------------------ the pin
-- One shared Heartbeat. It also holds WalkSpeed down, which is gate 2 of the
-- dash and the single reason the early attempts did nothing.
task.spawn(function()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if _G.__BEFLASH ~= GEN then conn:Disconnect(); return end
        local t = STATE.pinTarget
        if not t then return end
        local hrp, hum = rootPart(), humanoid()
        if hrp then hrp.CFrame = CFrame.new(t) end
        if hum then hum.WalkSpeed = 16 end
    end)
end)

-- --------------------------------------------------------------- the tools
local function equipTreadmill()
    local ch, hum = character(), humanoid()
    if not (ch and hum) then return false end
    if ch:FindFirstChild("Treadmill") then return true end
    local t = plr.Backpack:FindFirstChild("Treadmill")
    if t then pcall(function() hum:EquipTool(t) end); return true end
    return false
end

-- ---------------------------------------------------------------- the dash
local OpenBlockEffect = Remotes:FindFirstChild("OpenBlockEffect")

local function doDash()
    local trig, hrp = chargeTrigger(), rootPart()
    if not (trig and hrp) then note("no charge zone / no character"); return false end

    local got = 0
    local conn
    if OpenBlockEffect then
        conn = OpenBlockEffect.OnClientEvent:Connect(function(_, rarity, mutation)
            got = got + 1
            STATE.lastReward = tostring(rarity or "?") .. "/" .. tostring(mutation or "?")
        end)
    end

    -- gates 1 and 2: inside the trigger, WalkSpeed clamped
    STATE.phase = "charging"
    STATE.pinTarget = trig.Position
    task.wait(1.0)

    -- gate 3: a real key event. The remote replay does nothing.
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
    task.wait(CONFIG.chargeHold)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)

    -- let go of the character, the server drives the run. Writing the CFrame
    -- here cancels the dash outright.
    STATE.pinTarget = nil
    STATE.phase = "dashing"

    local far, t0 = 0, os.clock()
    while os.clock() - t0 < CONFIG.flightWait do
        if _G.__BEFLASH ~= GEN then break end
        local h = rootPart()
        if h then local z = -h.Position.Z; if z > far then far = z end end
        task.wait(0.15)
    end
    if conn then conn:Disconnect() end

    STATE.dashes = STATE.dashes + 1
    STATE.blocks = STATE.blocks + got
    if far > STATE.maxZ then STATE.maxZ = math.floor(far) end
    note(("dash %d studs -> %d brainrot%s"):format(math.floor(far), got, got == 1 and "" or "s"))
    return got > 0
end

-- --------------------------------------------------------------- placement
local function placeAll()
    local tools = brainrotTools()
    if #tools == 0 then return false end
    local hum, hrp = humanoid(), rootPart()
    if not (hum and hrp) then return false end

    local n = 0
    for _, tool in ipairs(tools) do
        if _G.__BEFLASH ~= GEN then break end
        -- find a free stand by its EquipPrompt
        local target, prompt
        for _, s in ipairs(stands()) do
            for _, d in ipairs(s:GetDescendants()) do
                if d:IsA("ProximityPrompt") and d.Name == "EquipPrompt" and d.Enabled then
                    target, prompt = s, d
                    break
                end
            end
            if prompt then break end
        end
        if not prompt then note("plot full - no free stand"); break end

        pcall(function() hum:EquipTool(tool) end)
        task.wait(0.3)
        local pp = target:FindFirstChild("PlacePoint")
        STATE.pinTarget = (pp and pp.Position or target:GetPivot().Position) + Vector3.new(0, 3, 0)
        task.wait(0.8)
        pcall(fireproximityprompt, prompt)
        task.wait(1.0)
        STATE.pinTarget = nil
        n = n + 1
    end
    if n > 0 then
        STATE.placed = STATE.placed + n
        note(("seated %d brainrot%s"):format(n, n == 1 and "" or "s"))
    end
    return n > 0
end

-- -------------------------------------------------------------- collection
-- firetouchinterest on StandClaimHitbox. NOT position gated - 722 collected
-- from 730 studs. The StandClaim part itself has no TouchInterest.
local function collectAll()
    local hrp = rootPart()
    if not hrp then return 0 end
    local pending = 0
    for _, m in ipairs(myBrainrots()) do
        pending = pending + (tonumber(m:GetAttribute("SavedRevenue")) or 0)
    end
    local fired = 0
    for _, s in ipairs(stands()) do
        for _, d in ipairs(s:GetDescendants()) do
            if d.Name == "StandClaimHitbox" and d:IsA("BasePart") then
                pcall(firetouchinterest, hrp, d, 0)
                pcall(firetouchinterest, hrp, d, 1)
                fired = fired + 1
            end
        end
    end
    if pending > 0 then
        STATE.collected = STATE.collected + pending
        note(("collected %s from %d stands"):format(fmt(pending), fired))
    end
    return pending
end

-- ------------------------------------------------------------- the treadmill
-- Credits Stamina only, requires the tool EQUIPPED, and is throttled to exactly
-- 1 per second server side. One call per second is the entire budget.
local TrainTreadmillEvent = Events:FindFirstChild("TrainTreadmillEvent")
local SendTreadmillEvent  = Events:FindFirstChild("SendTreadmillEvent")

local RANKS = {
    { id = "Uncommon",  cost = 1e4 },   { id = "Rare",      cost = 5e4 },
    { id = "Epic",      cost = 5e5 },   { id = "Legendary", cost = 7.5e6 },
    { id = "Mythic",    cost = 1.5e8 }, { id = "Secret",    cost = 5.25e9 },
    { id = "Cosmic",    cost = 2.3625e11 }, { id = "Celestial", cost = 1.299e13 },
    { id = "Divine",    cost = 8.446e14 },  { id = "Godly",     cost = 6.33e16 },
    { id = "Admin",     cost = 5.7e18 },    { id = "Infinity",  cost = 5.99e20 },
    { id = "Trinity",   cost = 7.18e22 },   { id = "Almighty",  cost = 9.70e24 },
    { id = "Galaxy",    cost = 1.45e27 },
}

local function treadmillData()
    return safeInvoke(SendTreadmillEvent, 8, "GetData")
end

local function buyBestRank()
    local data = treadmillData()
    local owned = {}
    if type(data) == "table" and type(data.Owned) == "table" then
        for _, v in ipairs(data.Owned) do owned[v] = true end
    end
    -- best affordable rank we do not own yet, cheapest first so nothing is skipped
    for _, r in ipairs(RANKS) do
        if not owned[r.id] then
            if money() - CONFIG.keepMoney < r.cost then
                note(("saving %s for the %s treadmill"):format(fmt(r.cost), r.id))
                return false
            end
            local before = money()
            safeInvoke(SendTreadmillEvent, 8, "Buy", r.id)
            task.wait(0.6)
            if money() < before then           -- charged -> it worked
                safeInvoke(SendTreadmillEvent, 8, "Equip", r.id)
                STATE.ranksBought = STATE.ranksBought + 1
                note(("treadmill -> %s for %s"):format(r.id, fmt(before - money())))
                return true
            end
            return false
        end
    end
    return false
end

-- --------------------------------------------------------- stand levelling
-- cost doubles per level while revenue only grows 20%, so payback is
-- 7.5 / mutation * 1.6667^(level-1) seconds: level 1->2 pays back in 7.5s,
-- level 15 in 2.7 hours. maxLevel exists for exactly that reason.
local UpgradeBrainrotRemote = Remotes:FindFirstChild("UpgradeBrainrotRemote")
local UpgradePlotRemote     = Remotes:FindFirstChild("UpgradePlotRemote")

local function levelStands(budget)
    local lot = myPlot()
    if not (lot and UpgradeBrainrotRemote) then return false end
    local list = myBrainrots()
    -- cheapest next level first
    table.sort(list, function(a, b)
        return (tonumber(a:GetAttribute("Level")) or 1) < (tonumber(b:GetAttribute("Level")) or 1)
    end)

    local done, spent = 0, 0
    for _, m in ipairs(list) do
        if done >= CONFIG.levelsPerPass then break end
        local lvl = tonumber(m:GetAttribute("Level")) or 1
        local place = m:GetAttribute("Place")
        local stand = place and lot.ModelStands:FindFirstChild(place)
        if stand and lvl < CONFIG.maxLevel then
            local before = money()
            if before - CONFIG.keepMoney <= 0 then break end
            fire(UpgradeBrainrotRemote, lot, stand)
            task.wait(0.4)
            local after = money()
            if after < before then
                spent = spent + (before - after)
                done = done + 1
                if spent > budget then break end
            end
        end
    end
    if done > 0 then
        STATE.levels = STATE.levels + done
        note(("levelled %d stand%s for %s"):format(done, done == 1 and "" or "s", fmt(spent)))
    end
    return done > 0
end

-- price is 100,000 * 3^level, max 30 upgrades, each adding one stand (10 -> 40)
local function buyStand(budget)
    local lot = myPlot()
    if not (lot and UpgradePlotRemote) then return false end
    local lvl = num("PlotLevel")
    if lvl >= 30 then return false end
    local cost = 100000 * (3 ^ lvl)
    if cost > budget then return false end
    local before = money()
    fire(UpgradePlotRemote, lot)
    task.wait(1.0)
    if money() < before then
        note(("bought stand %d for %s"):format(#stands(), fmt(before - money())))
        return true
    end
    return false
end

-- ---------------------------------------------------------------- freebies
local function claimOffline()
    local r = RemoteGUI:FindFirstChild("UOfflineRewardEvent")
    if not r then return false end
    local before = money()
    fire(r, "Claim")
    task.wait(1.5)
    if money() > before then note("offline +" .. fmt(money() - before)); return true end
    return false
end

local function rebirth()
    local r = RemoteGUI:FindFirstChild("URebirth")
    if not r then return false end
    fire(r)
    task.wait(1.5)
    note("rebirth fired - stamina reset")
    return true
end

-- ------------------------------------------------------------- loop driver
local function loop(period, key, fn)
    task.spawn(function()
        while _G.__BEFLASH == GEN do
            if CONFIG[key] and STATE.running then
                local ok, err = pcall(fn)
                if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
            end
            task.wait(period)
        end
    end)
end

-- the treadmill: one call per second, tool held. Skipped while a dash owns the
-- character, because the dash needs its own equipment state.
loop(1.0, "autoTrain", function()
    if STATE.busy then return end
    if equipTreadmill() then fire(TrainTreadmillEvent, false) end
end)

-- the farm
task.spawn(function()
    while _G.__BEFLASH == GEN do
        if STATE.running and CONFIG.autoDash and not STATE.busy then
            STATE.busy = true
            local ok, err = pcall(doDash)
            if not ok then note("dash failed: " .. tostring(err)) end
            if CONFIG.autoPlace then pcall(placeAll) end
            STATE.busy = false
        else
            if not STATE.running then STATE.phase = "off"
            elseif not CONFIG.autoDash then STATE.phase = "idle" end
            task.wait(0.5)
        end
        task.wait(0.2)
    end
    STATE.pinTarget = nil
end)

loop(6,  "autoCollect", function() collectAll() end)
loop(10, "autoPlace",   function() if not STATE.busy then placeAll() end end)

loop(12, "autoBuyRank", function()
    -- stamina is the gate on every zone, so the rank ladder outranks the plot
    if buyBestRank() then return end
    local spare = money() - CONFIG.keepMoney
    if spare <= 0 then return end
    if CONFIG.autoLevel then levelStands(spare) end
    if CONFIG.autoPlot  then buyStand(money() - CONFIG.keepMoney) end
end)

loop(120, "autoOffline", function() claimOffline() end)

task.spawn(function()
    while _G.__BEFLASH == GEN do
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
            if g.Name == "BEFLASH_PANEL" then g:Destroy() end
        end
    end)
end

local win = UI.Window({
    title = "BE", accentTitle = "FLASH", subtitle = "seltonmt",
    badge = "*", width = 920, height = 580, name = "BEFLASH_PANEL",
})
_G.__BEFLASH_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local cDash = farm:Card("DASH", 1)
cDash:Toggle("Auto dash", CONFIG.autoDash, function(v) CONFIG.autoDash = v; STATE.running = STATE.running or v end,
    "charge zone + WalkSpeed 16 + real LeftShift - all three or nothing happens")
cDash:Toggle("Keep training", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
    "treadmill held, 1 stamina/s - the server throttle, not ours")
cDash:Slider("Charge hold (s)", 1.0, 4.0, CONFIG.chargeHold, function(v) CONFIG.chargeHold = v end)
cDash:Slider("Flight wait (s)", 3, 12, CONFIG.flightWait, function(v) CONFIG.flightWait = v end)
cDash:Button("Dash once", function() task.spawn(function()
    if STATE.busy then return end
    STATE.busy = true; pcall(doDash); pcall(placeAll); STATE.busy = false
end) end)

local cPlot = farm:Card("PLOT", 2)
cPlot:Toggle("Auto place", CONFIG.autoPlace, function(v) CONFIG.autoPlace = v end, "EquipPrompt on a free stand")
cPlot:Toggle("Auto collect", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
    "touch each StandClaimHitbox - works from any distance")
cPlot:Button("Collect now", function() task.spawn(function() note("collected " .. fmt(collectAll())) end) end)

local spend = win:Page("SPEND", UI.icon.coin)
local cSpend = spend:Card("SPENDING", 1)
cSpend:Toggle("Buy treadmill ranks", CONFIG.autoBuyRank, function(v) CONFIG.autoBuyRank = v end,
    "stamina gates every zone, so this outranks everything", UI.theme.warn)
cSpend:Toggle("Level stands", CONFIG.autoLevel, function(v) CONFIG.autoLevel = v end,
    "payback 7.5s at level 1, 2.7h at level 15", UI.theme.good)
cSpend:Toggle("Buy more stands", CONFIG.autoPlot, function(v) CONFIG.autoPlot = v end, "100K x 3^level, max 40 stands")
cSpend:Stepper("Max stand level", function() return tostring(CONFIG.maxLevel) end,
    function(d) CONFIG.maxLevel = math.clamp(CONFIG.maxLevel + d, 1, 30) end,
    "cost doubles per level, revenue only +20%")

local cFree = spend:Card("FREE", 2)
cFree:Toggle("Offline rewards", CONFIG.autoOffline, function(v) CONFIG.autoOffline = v end)
cFree:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "resets stamina - opt in", UI.theme.warn)
cFree:Button("Rebirth now", function() task.spawn(rebirth) end, UI.theme.warn)

local cOut = farm:Card("STATUS", 0)
local out = cOut:Readout(10)

task.spawn(function()
    while _G.__BEFLASH == GEN do
        local occ, total = 0, #stands()
        for _, m in ipairs(myBrainrots()) do occ = occ + 1 end
        local rate = 0
        for _, m in ipairs(myBrainrots()) do rate = rate + (tonumber(m:GetAttribute("RevenuePerSecond")) or 0) end

        win:SetStatus(("%s cash   %s/s   stamina %s   %d/%d stands   %d dashes"):format(
            fmt(money()), fmt(rate), fmt(stamina()), occ, total, STATE.dashes))

        out:set({
            "FARM",
            ("  phase %s   dashes %d   brainrots %d   best %d studs"):format(
                STATE.phase, STATE.dashes, STATE.blocks, STATE.maxZ),
            ("  last drop %s   carrying %d"):format(STATE.lastReward, #brainrotTools()),
            "PLOT",
            ("  %d/%d stands used   %s/s   levelled %d"):format(occ, total, fmt(rate), STATE.levels),
            ("  earned %s   collected %s"):format(fmt(STATE.moneyEarned), fmt(STATE.collected)),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        win:Refresh()
        task.wait(0.5)
    end
end)

STATE.running = true

_G.__BEFLASH_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    doDash = doDash, placeAll = placeAll, collectAll = collectAll,
    equipTreadmill = equipTreadmill, treadmillData = treadmillData, buyBestRank = buyBestRank,
    levelStands = levelStands, buyStand = buyStand, claimOffline = claimOffline, rebirth = rebirth,
    myPlot = myPlot, stands = stands, myBrainrots = myBrainrots, brainrotTools = brainrotTools,
    chargeTrigger = chargeTrigger, safeInvoke = safeInvoke, fmt = fmt, RANKS = RANKS,
}

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste.
pcall(function() win:Home() end)

print("[beflash] loaded - gen " .. GEN .. ", RightShift for the panel")
