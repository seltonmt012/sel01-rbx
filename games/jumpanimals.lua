--[[
    jumpanimals.lua - "Jump for Animals!"  place 126870639873289
    ------------------------------------------------------------------------
    Carry-and-place plot income with the progression moved into JUMP POWER.
    Squat on the barbell to earn Jump XP, Jump XP raises Jump Power, Jump Power
    is what lets you enter the next area, you steal an egg from a guarded area,
    carry it home, place it in the pen, it hatches into an animal and pays cash
    per second forever.

    It is a near relative of stealegg: barbell -> treadmill, Jump Power ->
    Speed, animal index -> pet index. Unlike that game there is NO anti-cheat
    here - sweeps for AntiCheat / exploit / detector vocabulary over 5-7k live
    functions found nothing belonging to the game, so plain CFrame warping is
    used throughout.

    The loop, as measured through the bridge on 2026-09-16:

      stop squatting  ->  warp onto the best reachable egg, pin ~1.5s
        ->  fireproximityprompt(CollectPrompt)   CarriedEggCount 0 -> 1
        ->  warp onto the plot; arriving delivers by itself and the egg turns
            into a Backpack Tool "<Animal> Egg"
        ->  PlaceEggRequest:FireServer(tool.EggId, groundPosition)
        ->  resume squatting on the pad

    Verified facts this script is built on (do not re-derive):

      * TRAINING BLOCKS EVERY STEAL. While plr:GetAttribute("IsSquatting") is
        true the CollectPrompt does nothing at all - no error, no message, the
        prompt simply never pays out. StopSquattingRequest:FireServer() first,
        ALWAYS, and it works from any distance. This is the single easiest way
        to make the whole farm look broken and it cost a debugging round; the
        user spotted it before the numbers did. Same shape as the findegg
        "plr.Training stays true after warping off a treadmill" trap.
      * STARTING to squat is position gated, CONTINUING is not. Pinned on
        SquatZone.Floor.t the attribute flips within ~1s; fired from 605 studs
        with IsSquatting false it does nothing (0 XP in 6s). But once running,
        the server never revalidates position - measured 2.67 XP/s standing on
        a Winter egg 382 studs away against 2.50 XP/s on the pad itself. So the
        travel legs are free training; only the pickup needs the stop.
      * A CFrame warp alone does not start it. The character has to be PINNED
        on Heartbeat with AssemblyLinearVelocity zeroed - a warp that drifts a
        couple of studs leaves the server refusing while the client dutifully
        fires 4x/s, which reads exactly like a server gate and is not.
      * NEVER BURST SquatTrainingRequest. The client already fires it ~4 times
        a second by itself. An A/B over two 8s windows: client rate alone
        +20 XP (2.50/s), plus 16,920 extra FireServer calls +22 XP (2.75/s) -
        one tick of jitter. And the flood BACKFIRES: straight after it the
        server refused training entirely for ~40-60 seconds, silently, while
        the client kept firing. Training To Climb's flood trap in a new game.
      * A JUMP CANCELS THE SQUAT (Squats.JumpCancelEnabled, 0.5s grace), so the
        farm never jumps. There is no anchoring here, so there is also no
        stealegg-style "jump to release the root part" trick to want.
      * Eggs are completely readable without travelling. All ten areas
        replicate from the lobby; each model in Stages.<area>.SpawnedEggs is
        NAMED after its animal and carries Rarity, CPSMultiplier,
        SizeMultiplier, GrowthMultiplier, MutationList and NaturalSpawnPosition
        as plain attributes. So the global ranking is one GetChildren().
      * Delivery is ARRIVING ON THE PLOT, not a pad or a remote. Warping into
        the plot's Detector region took CarriedEggCount 1 -> 0 and put a Tool
        "Bunny Egg" in the Backpack. ReturnToBaseRequest is NOT used - it
        carries a ProductIdAttribute and costs TeleportCredits or Robux.
      * Placing is PlaceEggRequest:FireServer(eggId, groundPosition) where
        eggId is the TOOL'S OWN "EggId" attribute and groundPosition is a
        raycast hit inside the plot. Read out of EggPlacementController rather
        than guessed - its fire site reads Plot.Value, the Placement.RegionName
        child ("Detector"), and the tool's EggId. Verified: PlacedEggs 0 -> 1.
        Activating the tool instead sends NOTHING unless the real mouse happens
        to be pointing at ground, which is why :Activate() looks dead.
      * The egg then hatches on a server timer: the placed model carries
        PlacedAt and HatchAt (unix, compare against workspace:GetServerTimeNow)
        plus a HatchReady flag. A Common Meadow egg measured 20s.
      * ClaimAnimalIndexReward:FireServer(<animal name>) is NOT position gated
        and is the biggest lever in the game. Verified from the lobby:
        XP 39 -> 6 with a level crossing (+15) and Cash 881 -> 1085 (+200),
        matching Animals.List["Guienna Pig"].IndexReward exactly. Across the
        whole index that is 1,977,635 JumpXP and $161.5 TRILLION over 81
        animals - against a measured training rate of 2.5-2.8 XP/s at barbell
        level 1, where area 8 alone is ~115 hours of squatting. So a missing
        index entry outranks a merely richer duplicate, always.
      * leaderstats.Cash is a StringValue for display - the real number is its
        child Cash.V. Same for Level.V.
      * THE WHOLE MAP IS ON A TIMER. Areas.CaveCycle: every ~390s (min 300,
        +20s per extra player up to 5) the areas collapse, everyone is thrown
        back to their plot and all ~99 eggs are rerolled, with a 30s warning
        and a 10s evacuation. A carried egg has to be home before that.
      * GUARDS CANNOT BE SURVEYED FROM AFAR. workspace.ClientGuards is empty
        unless you are close (GuardDefaults.ClientSimulationDistanceStuds 200),
        so a guard census taken from the plot is a missing chunk, not "no
        guards". They aggro at 70 studs, fling at 95 power, ragdoll 3s and take
        the egg with a 35% chance per touch. The defence used here is simply
        not to dwell: the pin releases the frame the carry succeeds and the
        warp home is instant.

    Deliberately NOT automated, and why:

      * Everything with a ProductId. The player carries ~20 of them
        (Clone*ProductId x8, OfflineDoubleProductId, TeleportToBaseProductId,
        GrowAllEggsProductId, RobuxJumpXPProductId, the four CashTierProducts,
        ShopPackProducts) and Wheelspin is Robux-only AND Enabled = false.
      * autoBarbell, autoCode, autoOffline and autoEquipBest default OFF or are
        marked unverified in the panel - their remotes are read out of the
        client controllers but were never confirmed by a server value moving.
      * The Skeleton Fossils event (live until 2026-09-25, own Fragments
        currency, 500 Fragments -> a Fossiled Egg holding 8 index animals that
        are NOT gated behind Jump Power) is mapped but not automated yet.
      * Selling, the mutation machine, trails, coils and the pen upgrade are
        mapped in the recon doc and unimplemented here.

    Panel: RightShift.  Console handle: _G.__JUMPANIMALS_DBG
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")

local plr = Players.LocalPlayer

-- ---------------------------------------------------------------- generation
-- Re-running in the executor does not restart the Lua VM, so every loop below
-- captures this number and exits the moment it stops matching.
_G.__JUMPANIMALS = (_G.__JUMPANIMALS or 0) + 1
local GEN = _G.__JUMPANIMALS

local Remotes  = ReplicatedStorage:WaitForChild("Remotes", 10)
local Settings = ReplicatedStorage:WaitForChild("Settings", 10)

-- ------------------------------------------------------------------ configs
-- Every one of these is a plainly named, require-able ModuleScript. They are
-- pcall'd anyway: a game update that renames one must cost its own feature,
-- not the whole script.
local AnimalsCfg, AreasCfg, JumpLevels, BarbellCfg, MutationsCfg, EggsCfg
pcall(function() AnimalsCfg   = require(Settings.Animals) end)
pcall(function() AreasCfg     = require(Settings.Areas) end)
pcall(function() JumpLevels   = require(Settings.JumpLevels) end)
pcall(function() BarbellCfg   = require(Settings.BarbellUpgrades) end)
pcall(function() MutationsCfg = require(Settings.Mutations) end)
pcall(function() EggsCfg      = require(Settings.Eggs) end)

-- Area entry gates, read from the game rather than hardcoded. Falls back to
-- the measured ladder so a missing config does not stop the farm.
local AREA_GATES = (JumpLevels and JumpLevels.FirstWorldAreaRequirements) or {
    { JumpPower = 25 }, { JumpPower = 60 }, { JumpPower = 115 }, { JumpPower = 180 },
    { JumpPower = 210 }, { JumpPower = 245 }, { JumpPower = 285 }, { JumpPower = 325 },
    { JumpPower = 450 }, { JumpPower = 520 },
}

-- Area name -> index, from Areas.List.
local AREA_INDEX = {}
if AreasCfg and AreasCfg.List then
    for i, a in ipairs(AreasCfg.List) do AREA_INDEX[a.Name] = a.Index or i end
end

-- ------------------------------------------------------------------- config
local CONFIG = {
    autoTrain     = true,   -- squat on the barbell pad whenever nothing else is due
    autoSteal     = true,   -- steal the best reachable egg
    autoPlace     = true,   -- place every egg Tool sitting in the backpack
    autoIndex     = true,   -- claim animal index rewards (verified, free, huge)
    autoEquipBest = true,   -- PetInventory "EquipBest" (harmless, unproven as a swapper)

    autoBarbell   = false,  -- UNVERIFIED: upgrade prompt never confirmed by a charge
    autoOffline   = false,  -- UNVERIFIED: OfflineRewards "Claim"
    autoCode      = false,  -- UNVERIFIED: one-shot redeem of the one enabled code

    indexFirst    = true,   -- an animal missing from the index outranks a richer one
    maxAreaIndex  = 10,     -- never walk into an area above this
    areaMargin    = 0,      -- extra Jump Power required over an area's gate
    pinSeconds    = 1.5,    -- how long to sit on an egg before firing the prompt
    minPlotRoom   = 1,      -- stop stealing when fewer than this many egg slots are free
}

local STATE = {
    running    = false,
    note       = "idle",
    uiOwner    = nil,
    mode       = "boot",
    stolen     = 0,
    placed     = 0,
    claimed    = 0,
    trainSecs  = 0,
    lastEgg    = "-",
    lastError  = nil,
    codeDone   = false,
}

local function note(s)
    STATE.note = tostring(s)
end

-- ------------------------------------------------------------------ oracles
local function char()
    local c = plr.Character
    if not c then return nil end
    local hrp = c:FindFirstChild("HumanoidRootPart")
    local hum = c:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return nil end
    return c, hrp, hum
end

local function alive()
    local _, _, hum = char()
    return hum ~= nil and hum.Health > 0
end

local function money()
    local ls = plr:FindFirstChild("leaderstats")
    local cash = ls and ls:FindFirstChild("Cash")
    local v = cash and cash:FindFirstChild("V")
    return v and v.Value or 0
end

local function level()
    local ls = plr:FindFirstChild("leaderstats")
    local lv = ls and ls:FindFirstChild("Level")
    local v = lv and lv:FindFirstChild("V")
    return v and v.Value or 0
end

local function jumpPower()
    local j = plr:FindFirstChild("JumpPower")
    return j and j.Value or 0
end

local function carrying()
    return (plr:GetAttribute("CarriedEggCount") or 0) > 0
end

local function squatting()
    return plr:GetAttribute("IsSquatting") == true
end

local function serverNow()
    local ok, t = pcall(function() return workspace:GetServerTimeNow() end)
    return ok and t or os.time()
end

local function myPlot()
    local p = plr:FindFirstChild("Plot")
    return p and p.Value or nil
end

-- The squat pad. "t" is the little part carrying the TRAIN billboard and is
-- what the body has to sit on; Floor.Detector is the zone the client watches.
local function squatSpot()
    local plot = myPlot()
    local sz = plot and plot:FindFirstChild("SquatZone")
    local floor = sz and sz:FindFirstChild("Floor")
    local t = floor and floor:FindFirstChild("t")
    return t or (floor and floor:FindFirstChild("Detector"))
end

-- Placement is validated against Eggs.Placement.RegionName, which is
-- "Detector" - the same 59x15x59 volume as DefaultSize.
local function plotRegion()
    local plot = myPlot()
    if not plot then return nil end
    local name = (EggsCfg and EggsCfg.Placement and EggsCfg.Placement.RegionName) or "Detector"
    return plot:FindFirstChild(name) or plot:FindFirstChild("DefaultSize")
end

local function placedEggCount()
    local plot = myPlot()
    local f = plot and plot:FindFirstChild("PlacedEggs")
    return f and #f:GetChildren() or 0
end

local function placedAnimalCount()
    local plot = myPlot()
    local f = plot and plot:FindFirstChild("PlacedAnimals")
    return f and #f:GetChildren() or 0
end

local function plotRoom()
    local maxEggs = (EggsCfg and EggsCfg.Placement and EggsCfg.Placement.MaximumPlacedEggs) or 20
    return maxEggs - placedEggCount()
end

-- ------------------------------------------------------------- animal index
local function indexFolder(which)
    local f = plr:FindFirstChild("AnimalIndex")
    return f and f:FindFirstChild(which) or nil
end

local function indexHas(name)
    local d = indexFolder("Discovered")
    local b = d and d:FindFirstChild(name)
    return b ~= nil and b.Value == true
end

local function indexUnclaimed()
    local disc, claim = indexFolder("Discovered"), indexFolder("Claimed")
    local out = {}
    if not disc or not claim then return out end
    for _, b in ipairs(disc:GetChildren()) do
        local c = claim:FindFirstChild(b.Name)
        if b.Value == true and c and c.Value ~= true then out[#out + 1] = b.Name end
    end
    return out
end

-- ------------------------------------------------------------------ ranking
local function mutationMulti(list)
    if not list or list == "" then return 1 end
    local m = 1
    local defs = MutationsCfg and MutationsCfg.Definitions
    for word in tostring(list):gmatch("[^,%s]+") do
        local d = defs and defs[word]
        if d and d.CashPerSecondMultiplier then
            m = m * d.CashPerSecondMultiplier
        else
            -- An unknown mutation is priced HIGH, never at 1 - reading a good
            -- one as plain is how a swap throws the best animal away
            -- (wingsbrainrots' Galaxy). 2 is the low end of the known table.
            m = m * 2
        end
    end
    return m
end

-- Predicted income of an egg, from its own attributes. The ranking only ever
-- compares predictions against predictions, so what matters is that the same
-- formula is used on both sides - never a config value against a live label.
local function predictCPS(name, attrs)
    local entry = AnimalsCfg and AnimalsCfg.List and AnimalsCfg.List[name]
    local base = entry and entry.CashPerSecond or 0
    if base <= 0 then return 0 end
    local cps = attrs.CPSMultiplier or 1
    local size = attrs.SizeMultiplier or 1
    return base * cps * size * mutationMulti(attrs.MutationList or attrs.EventMutation)
end

-- An index entry is worth JumpXP plus cash far beyond the animal's own income
-- early on, so a missing one is ranked above every duplicate rather than being
-- folded into the same number.
local INDEX_BONUS = 1e9

local function eggScore(model)
    local attrs = model:GetAttributes()
    local score = predictCPS(model.Name, attrs)
    if CONFIG.indexFirst and not indexHas(model.Name) then
        score = score + INDEX_BONUS
    end
    return score
end

local function areaReachable(areaName)
    local idx = AREA_INDEX[areaName]
    if not idx then return false end
    if idx > CONFIG.maxAreaIndex then return false end
    local gate = AREA_GATES[idx]
    local need = (gate and gate.JumpPower or 0) + CONFIG.areaMargin
    return jumpPower() >= need
end

local function eggRoot(model)
    return model:FindFirstChild("EggRoot") or model.PrimaryPart
        or model:FindFirstChildWhichIsA("BasePart")
end

local function eggPrompt(model)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("ProximityPrompt") then return d end
    end
    return nil
end

-- Best egg across every REACHABLE area. Everything replicates from the plot,
-- so this costs no travel at all.
local function bestEgg()
    local stages = workspace:FindFirstChild("Map")
    stages = stages and stages:FindFirstChild("Stages")
    if not stages then return nil end
    local best, bestVal = nil, -1
    for _, stage in ipairs(stages:GetChildren()) do
        if areaReachable(stage.Name) then
            local folder = stage:FindFirstChild("SpawnedEggs")
            if folder then
                for _, egg in ipairs(folder:GetChildren()) do
                    local root = eggRoot(egg)
                    if root and eggPrompt(egg) then
                        local v = eggScore(egg)
                        if v > bestVal then best, bestVal = egg, v end
                    end
                end
            end
        end
    end
    return best, bestVal
end

-- ----------------------------------------------------------------- movement
-- Everything here pins on Heartbeat with the velocity zeroed. A bare CFrame
-- write drifts, and a drifting body is refused by the squat pad and misses the
-- egg prompt's 10 stud radius.
local function pinAt(position, seconds, stopWhen)
    local _, hrp = char()
    if not hrp then return false end
    local target = CFrame.new(position)
    local conn = RunService.Heartbeat:Connect(function()
        local c, h = char()
        if h then
            h.CFrame = target
            h.AssemblyLinearVelocity = Vector3.zero
        end
    end)
    local t = 0
    local hit = false
    while t < seconds do
        task.wait(0.1)
        t = t + 0.1
        if stopWhen and stopWhen() then hit = true break end
    end
    conn:Disconnect()
    return hit
end

local function groundUnder(position)
    local c = plr.Character
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = c and { c } or {}
    local hit = workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -60, 0), rp)
    return hit and hit.Position or nil
end

-- --------------------------------------------------------------- UI mutex
-- One routine owns the character at a time. Without it the steal run and the
-- training loop fight over the same body and neither finishes.
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

-- ---------------------------------------------------------------- training
local function stopTraining()
    if not squatting() then return true end
    pcall(function() Remotes.StopSquattingRequest:FireServer() end)
    local t = 0
    while squatting() and t < 3 do task.wait(0.2); t = t + 0.2 end
    return not squatting()
end

-- Start is position gated; continuing is not. So this only ever has to run
-- once per steal cycle, and the body is free the moment the attribute flips.
local function startTraining()
    if squatting() then return true end
    local spot = squatSpot()
    if not spot then note("no squat pad on the plot"); return false end
    local target = spot.Position + Vector3.new(0, 3.5, 0)
    pinAt(target, 6, function() return squatting() end)
    return squatting()
end

-- --------------------------------------------------------------- the steal
local function stealEgg(model)
    local root = eggRoot(model)
    local prompt = eggPrompt(model)
    if not root or not prompt then return false, "egg has no root or prompt" end

    -- THE ORDER MATTERS. While IsSquatting is true the prompt pays out nothing
    -- and reports nothing.
    if not stopTraining() then return false, "could not stop squatting" end

    local before = plr:GetAttribute("CarriedEggCount") or 0
    local target = root.Position + Vector3.new(0, 3, 0)

    -- Sit on it, fire once, and release the pin the frame the carry lands -
    -- guards aggro at 70 studs and standing around after a grab is how the egg
    -- gets taken back.
    local got = false
    local conn = RunService.Heartbeat:Connect(function()
        local _, hrp = char()
        if hrp then
            hrp.CFrame = CFrame.new(target)
            hrp.AssemblyLinearVelocity = Vector3.zero
        end
    end)
    task.wait(CONFIG.pinSeconds)
    pcall(function() fireproximityprompt(prompt) end)
    local t = 0
    while t < 2.5 do
        task.wait(0.1); t = t + 0.1
        if (plr:GetAttribute("CarriedEggCount") or 0) > before then got = true break end
    end
    conn:Disconnect()

    if got then
        STATE.stolen = STATE.stolen + 1
        STATE.lastEgg = model.Name
        note("stole " .. model.Name)
    end
    return got, got and nil or "prompt paid nothing"
end

-- Delivery is arriving on the plot. No remote, no pad.
local function goHome()
    local region = plotRegion()
    if not region then return false, "no plot region" end
    local target = region.Position + Vector3.new(0, 6, 0)
    pinAt(target, 4, function() return not carrying() end)
    return not carrying()
end

-- ---------------------------------------------------------------- placing
-- Walks a small grid over the plot so a spot that is already taken does not
-- block every later egg.
local function placeSpots(region)
    local out = {}
    local half = region.Size * 0.5
    local step = 6
    for dx = -half.X + step, half.X - step, step do
        for dz = -half.Z + step, half.Z - step, step do
            out[#out + 1] = region.Position + Vector3.new(dx, 0, dz)
        end
    end
    return out
end

local function eggTools()
    local out = {}
    local c = plr.Character
    for _, t in ipairs(plr.Backpack:GetChildren()) do
        if t:IsA("Tool") and t:GetAttribute("IsEggTool") then out[#out + 1] = t end
    end
    if c then
        for _, t in ipairs(c:GetChildren()) do
            if t:IsA("Tool") and t:GetAttribute("IsEggTool") then out[#out + 1] = t end
        end
    end
    return out
end

local function placeOne(tool, region, spots)
    local _, _, hum = char()
    if not hum then return false end
    local id = tool:GetAttribute("EggId")
    if not id then return false end

    pcall(function() hum:EquipTool(tool) end)
    task.wait(0.35)

    local before = placedEggCount()
    for _, spot in ipairs(spots) do
        local ground = groundUnder(spot)
        if ground then
            pcall(function() Remotes.PlaceEggRequest:FireServer(id, ground) end)
            task.wait(0.5)
            if placedEggCount() > before then
                STATE.placed = STATE.placed + 1
                note("placed " .. tostring(tool.Name))
                return true
            end
        end
    end
    return false
end

local function placeAll()
    local region = plotRegion()
    if not region then return 0 end
    local tools = eggTools()
    if #tools == 0 then return 0 end

    -- Placing needs the body on the plot; the same pin as the delivery.
    pinAt(region.Position + Vector3.new(0, 6, 0), 1.5)

    local spots = placeSpots(region)
    local n = 0
    for _, tool in ipairs(tools) do
        if tool.Parent == nil then break end
        if placeOne(tool, region, spots) then n = n + 1 end
        if _G.__JUMPANIMALS ~= GEN then break end
    end
    return n
end

-- ------------------------------------------------------------- free levers
-- Verified: the single-name form moved XP and Cash exactly as the config said.
-- The "__ALL__" sentinel is read out of AnimalIndexController's vocabulary next
-- to its ClaimAll button and is NOT verified, so it is only a first attempt and
-- the per-name loop is what actually does the work.
local function claimIndex()
    local pending = indexUnclaimed()
    if #pending == 0 then return 0 end
    pcall(function() Remotes.ClaimAnimalIndexReward:FireServer("__ALL__") end)
    task.wait(0.8)
    local n = 0
    for _, name in ipairs(indexUnclaimed()) do
        pcall(function() Remotes.ClaimAnimalIndexReward:FireServer(name) end)
        task.wait(0.35)
        n = n + 1
        if _G.__JUMPANIMALS ~= GEN then break end
    end
    local left = #indexUnclaimed()
    local done = #pending - left
    if done > 0 then
        STATE.claimed = STATE.claimed + done
        note(("index: claimed %d, %d left"):format(done, left))
    end
    return done
end

-- Harmless and not position gated. Measured a delta of 0 with one animal
-- placed, which is correct rather than dead - there was nothing to seat.
local function equipBest()
    pcall(function() Remotes.PetInventory:FireServer("EquipBest") end)
end

-- UNVERIFIED. The prompt exists (SquatZone.UpgradeB.Detector, "Upgrade
-- Barbell", 10 studs, hold 0) but was never confirmed by a charge, so the only
-- evidence accepted is BarbellLevel actually moving.
local function upgradeBarbell()
    local plot = myPlot()
    local ub = plot and plot:FindFirstChild("SquatZone")
    ub = ub and ub:FindFirstChild("UpgradeB")
    local det = ub and ub:FindFirstChild("Detector")
    local prompt = det and det:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then return false end

    local lvlValue = plr:FindFirstChild("BarbellLevel")
    local cur = lvlValue and lvlValue.Value or 0
    local levels = BarbellCfg and BarbellCfg.Levels
    local nxt = levels and levels[cur + 1]
    if not nxt or not nxt.CashPrice then return false end
    if money() < nxt.CashPrice then return false end

    pinAt(det.Position + Vector3.new(0, 3, 0), 1.2)
    pcall(function() fireproximityprompt(prompt) end)
    task.wait(1.2)
    local now = lvlValue and lvlValue.Value or cur
    if now > cur then
        note(("barbell %d -> %d"):format(cur, now))
        return true
    end
    return false
end

-- UNVERIFIED argument shape. Codes.List has exactly one enabled entry.
local function redeemCodes()
    if STATE.codeDone then return end
    STATE.codeDone = true
    local ok, CodesCfg = pcall(function() return require(Settings.Codes) end)
    if not ok or not CodesCfg or CodesCfg.Enabled ~= true then return end
    for code, entry in pairs(CodesCfg.List or {}) do
        if entry.Enabled == true then
            pcall(function() Remotes.Codes:FireServer("ClaimCode", code) end)
            task.wait(2.2)
        end
    end
end

-- UNVERIFIED argument shape.
local function claimOffline()
    if (plr:GetAttribute("OfflineCashPending") or 0) <= 0 then return end
    pcall(function() Remotes.OfflineRewards:FireServer("Claim") end)
end

-- ------------------------------------------------------------------- brain
local function farmCycle()
    if not alive() then note("dead - waiting for respawn"); return end

    -- 1. Anything in hand or in the backpack outranks a new egg. Leaving an
    --    egg undelivered poisons every later cycle, because you can only carry
    --    one and the next steal is then refused for a reason that has nothing
    --    to do with stealing.
    if carrying() then
        STATE.mode = "delivering"
        withUI("deliver", function()
            stopTraining()
            goHome()
        end)
        return
    end

    if CONFIG.autoPlace and #eggTools() > 0 then
        STATE.mode = "placing"
        withUI("place", function()
            stopTraining()
            placeAll()
        end)
        return
    end

    -- 2. Steal, if there is anywhere to put the result.
    if CONFIG.autoSteal and plotRoom() >= CONFIG.minPlotRoom then
        local egg, score = bestEgg()
        if egg then
            STATE.mode = "stealing"
            withUI("steal", function()
                local ok = stealEgg(egg)
                if ok then
                    goHome()
                    if CONFIG.autoPlace then placeAll() end
                end
            end)
            return
        end
    end

    -- 3. Nothing to fetch - train. Starting is position gated, so this walks
    --    home once and then the attribute carries the rest.
    if CONFIG.autoTrain then
        STATE.mode = "training"
        if not squatting() then
            withUI("train", function() startTraining() end)
        end
        return
    end

    STATE.mode = "idle"
end

-- --------------------------------------------------------------- loop driver
local function loop(period, key, fn)
    task.spawn(function()
        while _G.__JUMPANIMALS == GEN do
            if (key == nil or CONFIG[key]) and STATE.running then
                local ok, err = pcall(fn)
                if not ok then note(tostring(key or "loop") .. " failed: " .. tostring(err)) end
            end
            task.wait(period)
        end
    end)
end

loop(0.8,  nil,             farmCycle)
loop(20,   "autoIndex",     claimIndex)
loop(30,   "autoEquipBest", equipBest)
loop(25,   "autoBarbell",   upgradeBarbell)
loop(60,   "autoOffline",   claimOffline)
loop(45,   "autoCode",      redeemCodes)

-- Training seconds, for the panel only - a counter we increment ourselves is
-- not evidence of anything, so it is labelled as time, never as XP.
task.spawn(function()
    while _G.__JUMPANIMALS == GEN do
        task.wait(1)
        if squatting() then STATE.trainSecs = STATE.trainSecs + 1 end
    end
end)

-- --------------------------------------------------------------- debug hook
-- Assigned BEFORE the panel: anything that yields in the UI section would
-- otherwise leave this nil and the script would look like it failed to load.
_G.__JUMPANIMALS_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    farmCycle = farmCycle, bestEgg = bestEgg, eggScore = eggScore, predictCPS = predictCPS,
    stealEgg = stealEgg, goHome = goHome, placeAll = placeAll, placeOne = placeOne,
    startTraining = startTraining, stopTraining = stopTraining,
    claimIndex = claimIndex, indexUnclaimed = indexUnclaimed, indexHas = indexHas,
    equipBest = equipBest, upgradeBarbell = upgradeBarbell,
    redeemCodes = redeemCodes, claimOffline = claimOffline,
    eggTools = eggTools, plotRoom = plotRoom, squatSpot = squatSpot, plotRegion = plotRegion,
    money = money, level = level, jumpPower = jumpPower, areaReachable = areaReachable,
    AREA_GATES = AREA_GATES, AREA_INDEX = AREA_INDEX,
}

-- ------------------------------------------------------------------- panel
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__JUMPANIMALS_WIN then pcall(function() _G.__JUMPANIMALS_WIN:Destroy() end) end
if UI.sweep then UI.sweep("JUMPANIMALS_PANEL") end

UI.config("jumpanimals", CONFIG)

local win = UI.Window({
    title = "JUMP", accentTitle = "FOR ANIMALS", subtitle = "seltonmt",
    badge = "*", width = 920, height = 580, name = "JUMPANIMALS_PANEL",
})
_G.__JUMPANIMALS_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local cLoop = farm:Card("EGG LOOP", 1):Accent()
cLoop:Toggle("Auto steal", CONFIG.autoSteal, function(v) CONFIG.autoSteal = v end,
    "Warps to the best reachable egg and carries it home")
cLoop:Toggle("Auto place", CONFIG.autoPlace, function(v) CONFIG.autoPlace = v end,
    "Drops every carried egg into the pen")
cLoop:Toggle("Auto train", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
    "Squats whenever there is nothing to fetch")
cLoop:Stepper("Highest area", CONFIG.maxAreaIndex, 1, 10, 1, function(v) CONFIG.maxAreaIndex = v end,
    "Never enter an area above this")
cLoop:Stepper("Jump power margin", CONFIG.areaMargin, 0, 200, 10, function(v) CONFIG.areaMargin = v end,
    "Extra jump power required over an area's gate")

local cRank = farm:Card("RANKING", 2)
cRank:Toggle("Index first", CONFIG.indexFirst, function(v) CONFIG.indexFirst = v end,
    "A missing index animal outranks a richer duplicate", UI.theme.good)
cRank:Toggle("Auto claim index", CONFIG.autoIndex, function(v) CONFIG.autoIndex = v end,
    "Free jump XP and cash - the biggest lever in the game", UI.theme.good)
cRank:Toggle("Equip best", CONFIG.autoEquipBest, function(v) CONFIG.autoEquipBest = v end,
    "Unproven as a swapper, harmless")

local cExtra = farm:Card("UNVERIFIED", 0)
cExtra:Label("These were read out of the client but never confirmed by a server value moving.")
cExtra:Toggle("Auto barbell upgrade", CONFIG.autoBarbell, function(v) CONFIG.autoBarbell = v end,
    "Only counts BarbellLevel actually moving", UI.theme.warn)
cExtra:Toggle("Auto offline reward", CONFIG.autoOffline, function(v) CONFIG.autoOffline = v end,
    "Argument shape unverified", UI.theme.warn)
cExtra:Toggle("Redeem codes", CONFIG.autoCode, function(v) CONFIG.autoCode = v end,
    "One enabled code, argument shape unverified", UI.theme.warn)

local info = win:Page("INFO", UI.icon.info)
local cInfo = info:Card("STATUS", 0)
local out = cInfo:Readout(9)

local cWarn = info:Card("READ THIS", 0)
cWarn:Label("Training blocks every steal. The loop always stops squatting first - if you drive it by hand, do the same.")
cWarn:Label("Never burst the training remote. A flood disables training for about a minute, silently.")
cWarn:Label("Jumping cancels the squat, so the farm never jumps.")
cWarn:Label("The map resets every ~6 minutes and rerolls all eggs. A carried egg must be home before that.")

task.spawn(function()
    while _G.__JUMPANIMALS == GEN do
        pcall(function()
            local pending = #indexUnclaimed()
            local egg, score = bestEgg()
            out:set({
                "LOOP",
                ("  state %s%s"):format(STATE.mode, STATE.uiOwner and ("  owner "..STATE.uiOwner) or ""),
                ("  stolen %d   placed %d   index claimed %d"):format(
                    STATE.stolen, STATE.placed, STATE.claimed),
                ("  last egg %s   trained %ds"):format(STATE.lastEgg, STATE.trainSecs),
                "PEN",
                ("  %d eggs, %d animals, %d egg slots free"):format(
                    placedEggCount(), placedAnimalCount(), plotRoom()),
                ("  %d index rewards waiting to be claimed"):format(pending),
                "TARGET",
                egg and ("  %s in %s   score %.0f"):format(
                    egg.Name, tostring(egg:GetAttribute("AreaName")), score or 0)
                    or "  nothing reachable at this jump power",
            })
            win:SetStat(1, tostring(jumpPower()), "jump power")
            win:SetStat(2, tostring(level()), "level")
            win:SetStat(3, tostring(math.floor(plr:GetAttribute("CashPerSecond") or 0)), "cash/s")
            win:SetStatus(("%s   -   %s"):format(
                squatting() and "training" or "not training", STATE.note))
        end)
        task.wait(1)
    end
end)

pcall(function()
    win:SetMaster(STATE.running, "Auto Farm running")
    win:OnMaster(function(on) STATE.running = on end)
end)

pcall(function() win:Home() end)

print("[jumpanimals] loaded - gen " .. GEN .. ", RightShift for the panel")
