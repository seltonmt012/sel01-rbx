--[[
    spinjitsu.lua - "[UPD] +1 Spinjitsu Escape"  (place 131910189515331)

    Verified against server-side values on 2026-08-20, account Lumo_Studios.

    The loop: switch the Spinjitsu on, and it ticks Jitsu per second forever.
    Jitsu is the damage that eats the walls of a stage - five walls per stage -
    and the plate behind the last wall pays that stage's Wins, ONCE. Wins buy a
    stronger Spinjitsu variant off a pad, which ticks more Jitsu per second, and
    a rebirth multiplies the lot.

    What was measured, and what the script therefore does:

    * The player's ATTRIBUTES are the whole oracle: Jitsu, Wins, Rebirths,
      CurrentWorld / MaxWorld, SpinjitsuActive, SpinjitsuVariant, and every
      multiplier (JitsuMultiplier, WinsMultiplier, PetMultiplier, potions).
    * `Remotes.ToggleSpinjitsu` flips `SpinjitsuActive`. With it off nothing
      accrues at all; with it on the Jitsu ticks wherever the body stands - the
      tornado pads are NOT training spots, they are the variant shop.
    * Variants are a wins ladder out of `SpinjitsuConfig.Variants`:
      Basic 1 Jitsu/s free, Common 2 for 1 win, Uncommon 5 for 15 ... Secret7
      1500 for 1.5M. Buying one is a TOUCH on its pad in `Map.World<n>.Pads`,
      which charges the wins and equips it in one go (measured: wins 2 -> 1,
      variant Basic -> Common, tick rate 1/s -> 2/s).
    * A wall breaks by standing in it while spinning. `GetWallState` answers a
      map keyed `"<stage>:<wallIndex>"` with the remaining health, and
      `StageConfig.Stages[n].WallHealth` is what has to be out-damaged - stage 1
      is 50, stage 10 is 3,000,000, stage 45 is 2e20. With 108 Jitsu against a
      50 health wall it fell in under half a second.
    * The plate is `Stages.Stage<n>.Won.Win` and it pays exactly once - a second
      pass over it credited zero. So wins come from NEW stages, never from
      farming one.
    * Levels come out of the Jitsu total (`LevelConfig.Resolve`: 230 Jitsu was
      level 3) and a rebirth needs a level, not a currency:
      `RebirthConfig.GetRequiredLevel(0)` is 10, `(1)` is 20, and the multiplier
      at one rebirth is x2.
    * Worlds cost wins outright (`WorldConfig.Costs`: world 2 = 1,000,000,
      world 3 = 240,000,000,000) and there are 15 stages in each.

    Never touched: `PaidRebirthProductId`, the VIP pad and every gamepass
    variant, `DoubleOfflineGain`, and anything that opens a purchase prompt.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local Remotes   = ReplicatedStorage:WaitForChild("Remotes")
local Modules   = ReplicatedStorage:WaitForChild("Modules")
local SpinCfg   = require(Modules.Spinjitsu.SpinjitsuConfig)
local StageCfg  = require(Modules.Stages.StageConfig)
local WorldCfg  = require(Modules.World.WorldConfig)
local RebirthCfg= require(Modules.Rebirth.RebirthConfig)
local LevelCfg  = require(Modules.Level.LevelConfig)
local CodeCfg   = require(Modules.Codes.CodeConfig)

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    autoSpin    = true,   -- keep SpinjitsuActive on; nothing ticks without it
    autoStages  = true,   -- break walls, then take the win plate
    autoVariant = true,   -- buy the best pad the wins allow
    autoRebirth = true,   -- needs a level, costs no currency
    autoWorld   = true,   -- buy and move up when the wins cover it
    autoPets    = true,   -- hatch and keep the best team equipped
    autoRewards = true,   -- codes, playtime, streak, milestones, offline gain
    wallTimeout = 12,     -- give up on a wall that outgrew the Jitsu
    hopDelay    = 0.15,
}

local STATE = {
    jitsu = 0, wins = 0, rebirths = 0, level = 0, needLevel = 0,
    world = 1, variant = "-", perSecond = 0, stage = "-", phase = "starting",
    walls = 0, plates = 0, rebirthsDone = 0, hatched = 0, note = "",
}

_G.__SPINJITSU = (_G.__SPINJITSU or 0) + 1
local GEN = _G.__SPINJITSU
local function alive() return _G.__SPINJITSU == GEN end

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

local function attr(name, default)
    local value = LocalPlayer:GetAttribute(name)
    if value == nil then return default end
    return value
end

local function jitsu()    return attr("Jitsu", 0) end
local function wins()     return attr("Wins", 0) end
local function rebirths() return attr("Rebirths", 0) end
local function world()    return attr("CurrentWorld", 1) end

local function remote(name)
    return Remotes:FindFirstChild(name, true)
end

local function fire(name, ...)
    local object = remote(name)
    if not object then return false end
    local ok = pcall(function(...) object:FireServer(...) end, ...)
    return ok
end

local function invoke(name, ...)
    local object = remote(name)
    if not object then return nil end
    local results = { pcall(function(...) return object:InvokeServer(...) end, ...) }
    if not results[1] then return nil end
    return results[2], results[3]
end

local function abbreviate(n)
    if type(n) ~= "number" then return tostring(n) end
    local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do n = n / 1000 i = i + 1 end
    return string.format(i == 1 and "%.0f%s" or "%.2f%s", n, units[i])
end

local function root()
    local character = LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function partOf(instance)
    if not instance then return end
    if instance:IsA("BasePart") then return instance end
    return instance:FindFirstChildWhichIsA("BasePart", true)
end

-- Everything here is a Touched event on the server, and the server validates
-- against its own copy of the position - a single CFrame write is not enough,
-- the body has to be held there for a moment.
local function holdAt(position, seconds, stopWhen)
    local body = root()
    if not body then return false end
    local pin = RunService.Heartbeat:Connect(function()
        local current = root()
        if current then current.CFrame = CFrame.new(position) end
    end)
    local deadline = os.clock() + (seconds or 2)
    local hit = false
    while alive() and os.clock() < deadline do
        if stopWhen and stopWhen() then hit = true break end
        task.wait(0.1)
    end
    pin:Disconnect()
    return hit
end

local function worldFolder()
    local map = workspace:FindFirstChild("Map")
    return map and map:FindFirstChild("World" .. world())
end

----------------------------------------------------------------------------
-- spinjitsu
----------------------------------------------------------------------------

local function variantInfo(name)
    return SpinCfg.Variants and SpinCfg.Variants[name or ""] or nil
end

local function currentPerSecond()
    local info = variantInfo(attr("SpinjitsuVariant", SpinCfg.DefaultVariant))
    return info and info.JitsuPerSecond or 0
end

local function keepSpinning()
    if attr("SpinjitsuActive", false) then return end
    fire("ToggleSpinjitsu")
    task.wait(SpinCfg.ToggleCooldown or 0.5)
end

-- The pads are the shop. Skip the VIP / gamepass ones, take the best the
-- balance covers, and only if it actually ticks faster than what is worn.
local function buyVariant()
    local folder = worldFolder()
    local pads = folder and folder:FindFirstChild("Pads")
    if not pads then return end

    local best, bestRate, bestPad
    for _, pad in ipairs(pads:GetChildren()) do
        local nameValue = pad:FindFirstChild("TornadoName", true)
        local variant = nameValue and nameValue.Value
        local info = variantInfo(variant)
        if info and not info.GamepassId and not info.IsVIP then
            local cost = info.WinsCost or 0
            local rate = info.JitsuPerSecond or 0
            if cost <= wins() and rate > currentPerSecond() and rate > (bestRate or 0) then
                best, bestRate, bestPad = variant, rate, pad
            end
        end
    end
    if not bestPad then return end

    local touch = bestPad:FindFirstChild("TouchPart", true) or partOf(bestPad)
    if not touch then return end
    local before = attr("SpinjitsuVariant", "")
    holdAt(touch.Position + Vector3.new(0, 3, 0), 4, function()
        return attr("SpinjitsuVariant", "") ~= before
    end)
    if attr("SpinjitsuVariant", "") == best then
        note("spinjitsu %s (%s jitsu/s)", best, tostring(bestRate))
    end
end

----------------------------------------------------------------------------
-- stages
----------------------------------------------------------------------------

local function wallBroken(model)
    local part = partOf(model)
    if not part then return true end
    return part.Transparency > 0.5 or part.CanCollide == false
end

local function stageFolders()
    local folder = worldFolder()
    local stages = folder and folder:FindFirstChild("Stages")
    if not stages then return {} end

    local list = {}
    for _, child in ipairs(stages:GetChildren()) do
        local number = tonumber(child.Name:match("(%d+)$"))
        if number then list[#list + 1] = { number = number, folder = child } end
    end
    table.sort(list, function(a, b) return a.number < b.number end)
    return list
end

-- `Won` holds TWO plates: `Win` and `PaidWin`, and PaidWin is the Robux x2 one.
-- Taking "the first BasePart under Won" hands you PaidWin.Base - that is what
-- the script did on the first pass.  Always resolve the plate by name.
local function winPlate(stageFolder)
    local won = stageFolder:FindFirstChild("Won")
    local win = won and won:FindFirstChild("Win")
    return win and partOf(win) or nil
end

-- A plate pays exactly once, and the walls respawn afterwards, so "this stage
-- still has standing walls" is NOT a sign that there is anything left to earn.
-- Without remembering what was already collected the run walks stage 1 and 2
-- forever - measured: 92 walls broken for 23 plates, all of them shallow.
local CLAIMED = {}

local function runStage(stage)
    STATE.stage = "Stage" .. stage.number
    local walls = {}
    for _, child in ipairs(stage.folder:GetChildren()) do
        local index = tonumber(child.Name:match("^Wall(%d+)$"))
        if index then walls[#walls + 1] = { index = index, model = child } end
    end
    table.sort(walls, function(a, b) return a.index < b.index end)

    for _, wall in ipairs(walls) do
        if not alive() or not CONFIG.autoStages then return false end
        if not wallBroken(wall.model) then
            local part = partOf(wall.model)
            if part then
                STATE.phase = string.format("wall %d of stage %d", wall.index, stage.number)
                local broke = holdAt(part.Position, CONFIG.wallTimeout, function()
                    return wallBroken(wall.model)
                end)
                if broke then
                    STATE.walls = STATE.walls + 1
                else
                    -- Out-damaged: the wall health of this stage is above the
                    -- current Jitsu, so there is nothing to do but keep ticking.
                    local health = StageCfg.Stages[stage.number]
                    note("stage %d wall needs %s jitsu, holding at %s",
                        stage.number,
                        abbreviate(health and health.WallHealth or 0), abbreviate(jitsu()))
                    return false
                end
            end
        end
        task.wait(CONFIG.hopDelay)
    end

    local plate = winPlate(stage.folder)
    if plate then
        STATE.phase = "plate of stage " .. stage.number
        local before = wins()
        holdAt(plate.Position + Vector3.new(0, 3, 0), 4, function() return wins() > before end)
        if wins() > before then
            STATE.plates = STATE.plates + 1
            note("stage %d cleared (+%s wins)", stage.number, abbreviate(wins() - before))
        else
            note("stage %d already paid, moving on", stage.number)
        end
    end
    CLAIMED[stage.number] = true
    return true
end

----------------------------------------------------------------------------
-- progression
----------------------------------------------------------------------------

local function levelNow()
    local ok, level = pcall(LevelCfg.Resolve, jitsu())
    if not ok then return 0 end
    if type(level) == "table" then return level.Level or 0 end
    return level or 0
end

local function doRebirth()
    local ok, required = pcall(RebirthCfg.GetRequiredLevel, rebirths())
    required = ok and required or math.huge
    STATE.needLevel = required
    if levelNow() < required then return end
    fire("RequestRebirth")
    task.wait(1.5)
    STATE.rebirthsDone = STATE.rebirthsDone + 1
    note("rebirth %d (level %d needed)", rebirths(), required)
end

local function climbWorld()
    local current, max = world(), attr("MaxWorld", 1)
    local nextWorld = current + 1
    if nextWorld > (WorldCfg.Count or 3) then return end

    if nextWorld > max then
        local cost = WorldCfg.Costs and WorldCfg.Costs[nextWorld]
        if not cost or wins() < cost then return end
        fire("RequestWorldBuy", nextWorld)
        task.wait(1.5)
        if attr("MaxWorld", 1) < nextWorld then return end
        note("bought world %d for %s wins", nextWorld, abbreviate(cost))
    end
    fire("RequestWorldTeleport", nextWorld)
    task.wait(2)
    -- a new world is a fresh set of fifteen stages, all unclaimed
    for key in pairs(CLAIMED) do CLAIMED[key] = nil end
end

local function freeRewards()
    for code in pairs(CodeCfg.Codes or {}) do invoke("RedeemCode", code) end
    invoke("PlaytimeReward.Claim")
    invoke("ClaimStreak")
    invoke("ClaimMilestone")
    invoke("ClaimGifts")
    invoke("ClaimGroupReward")
    fire("ClaimOfflineGain")
end

local function pets()
    fire("PetSystem.SetAutoHatch", true)
    fire("PetSystem.SetAutoEquip", true)
    fire("PetSystem.EquipBest")
end

----------------------------------------------------------------------------
-- loops
----------------------------------------------------------------------------

local function loop(name, gap, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then note("%s failed: %s", name, tostring(err)) end
            task.wait(gap)
        end
    end)
end

loop("spin", 1, function()
    if CONFIG.autoSpin then keepSpinning() end
end)

loop("stats", 0.5, function()
    STATE.jitsu, STATE.wins = jitsu(), wins()
    STATE.rebirths, STATE.world = rebirths(), world()
    STATE.variant = attr("SpinjitsuVariant", "-")
    STATE.perSecond = currentPerSecond()
    STATE.level = levelNow()
end)

loop("shop", 8, function()
    if CONFIG.autoVariant then buyVariant() end
    if CONFIG.autoRebirth then doRebirth() end
    if CONFIG.autoWorld   then climbWorld() end
end)

loop("pets", 30, function()
    if CONFIG.autoPets then pets() end
end)

loop("rewards", 240, function()
    if CONFIG.autoRewards then freeRewards() end
end)

task.spawn(function()
    while alive() do
        if not CONFIG.autoStages then
            STATE.phase = "stages off"
            task.wait(1)
        else
            local progressed = false
            for _, stage in ipairs(stageFolders()) do
                if not alive() or not CONFIG.autoStages then break end
                if not CLAIMED[stage.number] then
                    progressed = runStage(stage) or progressed
                    break
                end
            end
            if not progressed then
                -- everything reachable is broken: sit still and let the Jitsu
                -- climb until the next wall is affordable
                STATE.phase = "waiting for jitsu"
                task.wait(3)
            end
        end
    end
end)

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__SPINJITSU_WIN then pcall(function() _G.__SPINJITSU_WIN:Destroy() end) end

local win = UI.Window({
    title = "SPIN", accentTitle = "JITSU", subtitle = "seltonmt",
    badge = "\226\154\161", width = 920, height = 580,
})
_G.__SPINJITSU_WIN = win

local page = win:Page("FARMING", UI.icon and UI.icon.pickaxe or nil)

local engine = page:Card("ENGINE", 1)
engine:Toggle("Keep spinjitsu on", CONFIG.autoSpin, function(v) CONFIG.autoSpin = v end,
    "nothing ticks while it is off - this is the whole engine")
engine:Toggle("Clear stages", CONFIG.autoStages, function(v) CONFIG.autoStages = v end,
    "stands in each wall, then takes the plate behind the last one")
engine:Slider("Wall timeout (s)", 4, 40, CONFIG.wallTimeout, function(v) CONFIG.wallTimeout = v end)

local spend = page:Card("SPENDING", 2)
spend:Toggle("Buy spinjitsu", CONFIG.autoVariant, function(v) CONFIG.autoVariant = v end,
    "the pads are the shop; buys the best the wins allow")
spend:Toggle("Rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "needs a level, costs no currency", UI.theme.warn)
spend:Toggle("Buy worlds", CONFIG.autoWorld, function(v) CONFIG.autoWorld = v end,
    "world 2 costs 1M wins, world 3 costs 240B")
spend:Toggle("Pets", CONFIG.autoPets, function(v) CONFIG.autoPets = v end,
    "auto hatch, auto equip and equip best")
spend:Toggle("Free rewards", CONFIG.autoRewards, function(v) CONFIG.autoRewards = v end,
    "codes, playtime, streak, milestones, gifts, offline gain")

local readout = page:Card("STATUS", 0)
local out = readout:Readout(9)

task.spawn(function()
    while alive() do
        out:set({
            "RUN",
            string.format("  world %d   %s   %s", STATE.world, STATE.stage, STATE.phase),
            string.format("  walls %d   plates %d   rebirths %d", STATE.walls, STATE.plates, STATE.rebirthsDone),
            "ECONOMY",
            string.format("  jitsu %s   wins %s", abbreviate(STATE.jitsu), abbreviate(STATE.wins)),
            string.format("  %s at %s jitsu/s", tostring(STATE.variant), tostring(STATE.perSecond)),
            string.format("  level %d / %s for the next rebirth", STATE.level, tostring(STATE.needLevel)),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        win:SetStatus(string.format("%s jitsu   %s wins   r%d   world %d   %s",
            abbreviate(STATE.jitsu), abbreviate(STATE.wins), STATE.rebirths, STATE.world, STATE.phase))
        task.wait(0.5)
    end
end)

_G.__SPINJITSU_DBG = {
    CONFIG = CONFIG, STATE = STATE, fire = fire, invoke = invoke,
    buyVariant = buyVariant, runStage = runStage, stageFolders = stageFolders,
    CLAIMED = CLAIMED, winPlate = winPlate,
    doRebirth = doRebirth, climbWorld = climbWorld, freeRewards = freeRewards,
    levelNow = levelNow, currentPerSecond = currentPerSecond, holdAt = holdAt,
}

print("[spinjitsu] running - RightShift toggles the panel")
