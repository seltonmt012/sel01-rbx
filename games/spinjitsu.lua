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
local PetConfig = require(Modules.Pets.PetConfig)
local AuraConfig= require(Modules.Auras.AuraConfig)
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
    autoAura    = true,   -- wins-priced auras, x1.5 up to x3.5 on wins
    autoItems   = true,   -- the restocking item shop, raises ItemJitsuMult
    itemShare   = 0.5,    -- of the balance per item
    worldReach  = 3,      -- start saving for the next world at a third of its price
    petKeep     = 40,     -- storage is 50; cull below this so hatching never jams
    petCullBatch= 8,      -- extra room freed per cull
    autoRewards = true,   -- codes, playtime, streak, milestones, offline gain
    wallTimeout = 10,     -- give up on a wall that outgrew the Jitsu
    stuckWait   = 10,     -- and go shopping before trying it again
    eggReserve  = 0,      -- wins held back from eggs once the team is full
    hatchBurst  = 5,      -- hatches per visit to an egg
    hopDelay    = 0.15,
}

local STATE = {
    jitsu = 0, wins = 0, rebirths = 0, level = 0, needLevel = 0,
    world = 1, variant = "-", perSecond = 0, stage = "-", phase = "starting",
    walls = 0, plates = 0, rebirthsDone = 0, hatched = 0, note = "",
    reached = 0, deepest = 0, inRun = false, deleted = 0,
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

-- Half of these live in sub-folders and are written with a dot in the game's own
-- code ("PetSystem.Hatch", "ItemSystem.Buy"). FindFirstChild does not walk a
-- path, so looking that name up returns nil and the call silently does nothing -
-- which is why the character stood on the egg without ever hatching one.
local function remote(name)
    local direct = Remotes:FindFirstChild(name, true)
    if direct then return direct end

    local node = Remotes
    for segment in tostring(name):gmatch("[^%.]+") do
        node = node and node:FindFirstChild(segment)
        if not node then return nil end
    end
    return node
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

-- There is exactly ONE body, so exactly one thing may move it. Without this the
-- stage loop pins the character to a wall on every Heartbeat while the shop is
-- trying to stand on an egg, the two writes fight, and the egg never hatches
-- even though the panel says it is buying one - which is precisely what it
-- looked like from the outside.
local MOVE = { owner = nil }

local function withBody(name, fn)
    local deadline = os.clock() + 20
    while MOVE.owner and MOVE.owner ~= name and os.clock() < deadline do task.wait(0.2) end
    MOVE.owner = name
    local ok, err = pcall(fn)
    MOVE.owner = nil
    if not ok then note("%s failed: %s", name, tostring(err)) end
    return ok
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
-- The next world is the single biggest jump available (world 2 = Magma, 1,000,000
-- wins, and its stage 16 alone pays 250,000 against the 100,000 of world 1's
-- last stage).  Once it is within reach the wins stop going into variants and
-- eggs, or the balance never gets there - the whole of world 1 is only worth
-- 194,439 wins per rebirth cycle.
local function worldReserve()
    local nextWorld = attr("MaxWorld", 1) + 1
    if nextWorld > (WorldCfg.Count or 3) then return 0 end
    local cost = WorldCfg.Costs and WorldCfg.Costs[nextWorld]
    if not cost then return 0 end
    if wins() * CONFIG.worldReach >= cost then return cost end
    return 0
end

local function spendable()
    return math.max(0, wins() - worldReserve())
end

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
            if cost <= spendable() and rate > currentPerSecond() and rate > (bestRate or 0) then
                best, bestRate, bestPad = variant, rate, pad
            end
        end
    end
    if not bestPad then return end

    local touch = bestPad:FindFirstChild("TouchPart", true) or partOf(bestPad)
    if not touch then return end
    local before = attr("SpinjitsuVariant", "")
    withBody("shop", function()
        holdAt(touch.Position + Vector3.new(0, 3, 0), 4, function()
            return attr("SpinjitsuVariant", "") ~= before
        end)
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

-- Break every wall of a stage. Returns true when the stage is open, false when
-- a wall outlasted the timeout (i.e. it is above the current Jitsu).
local function breakStage(stage)
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
                local broke = false
                withBody("stage", function()
                    broke = holdAt(part.Position, CONFIG.wallTimeout, function()
                        return wallBroken(wall.model)
                    end)
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

    return true
end

-- Taking a plate ENDS the run - every wall comes back - and each plate pays
-- exactly once.  Cashing stage 1 for its single win therefore throws a whole
-- run away, which is what the first version did on every pass.  So: push as
-- deep as the Jitsu allows, then cash the DEEPEST stage that is open and still
-- unpaid.
local function collectPlate(stage)
    local plate = winPlate(stage.folder)
    if not plate then return false end

    STATE.phase = "plate of stage " .. stage.number
    local before = wins()
    withBody("stage", function()
        holdAt(plate.Position + Vector3.new(0, 3, 0), 5, function() return wins() > before end)
    end)

    CLAIMED[stage.number] = true
    if wins() > before then
        STATE.plates = STATE.plates + 1
        STATE.deepest = math.max(STATE.deepest or 0, stage.number)
        note("cashed stage %d for %s wins", stage.number, abbreviate(wins() - before))
        return true
    end
    note("stage %d was already paid", stage.number)
    return false
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

-- A rebirth makes every plate payable again. The whole of world 1 is worth only
-- 194,439 wins if each plate paid once - the balance passed 420,000 across
-- thirteen rebirths, so they clearly reset. Anything that remembers a plate as
-- "done" therefore has to forget it here, or the script walks past its own
-- income.
local function doRebirth()
    local ok, required = pcall(RebirthCfg.GetRequiredLevel, rebirths())
    required = ok and required or math.huge
    STATE.needLevel = required
    if levelNow() < required then return end

    local before = rebirths()
    fire("RequestRebirth")
    task.wait(1.5)
    if rebirths() > before then
        STATE.rebirthsDone = STATE.rebirthsDone + 1
        for key in pairs(CLAIMED) do CLAIMED[key] = nil end
        note("rebirth %d - plates are payable again", rebirths())
    end
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

-- Eggs are priced in wins (`PetConfig.Eggs`): Grass 100, Fire 5,000,000, Storm
-- 100,000,000,000; everything flagged `Exclusive` or carrying a `ProductId` is
-- Robux and is skipped.  Hatching is position gated - the body has to be at the
-- egg model in the world.  The first pass never hatched a single pet because
-- the variant shop spent the balance down to zero first, so the first few pets
-- are bought BEFORE any variant (see the shop loop).
local function eggLadder()
    local list = {}
    for name, data in pairs(PetConfig.Eggs or {}) do
        local cost = data.Cost
        if cost and cost > 0 and not data.Exclusive and not data.ProductId then
            list[#list + 1] = { name = name, cost = cost }
        end
    end
    table.sort(list, function(a, b) return a.cost > b.cost end)
    return list
end

local function eggModel(name)
    local folder = worldFolder()
    local eggs = folder and folder:FindFirstChild("Eggs")
    if not eggs then return end
    local direct = eggs:FindFirstChild(name)
    if direct then return direct end
    return eggs:GetChildren()[1]
end

local function hatchEggs()
    local owned = LocalPlayer:FindFirstChild("Pets")
    local count = owned and #owned:GetChildren() or 0
    local budget = count < (PetConfig.EquippedLimit or 3) and wins() or spendable()

    for _, egg in ipairs(eggLadder()) do
        if egg.cost <= budget then
            local model = eggModel(egg.name)
            local part = model and partOf(model)
            if part then
                local before = count
                -- Hatching is position gated, so the body has to stay on the egg
                -- for the whole burst - and it only can if the stage loop is not
                -- pulling it back to a wall at the same time.
                withBody("eggs", function()
                    local pin = RunService.Heartbeat:Connect(function()
                        local body = root()
                        if body then body.CFrame = CFrame.new(part.Position + Vector3.new(0, 4, 0)) end
                    end)
                    task.wait(1.5)
                    for _ = 1, CONFIG.hatchBurst do
                        if wins() < egg.cost then break end
                        fire("PetSystem.Hatch", egg.name)
                        task.wait(0.6)
                    end
                    pin:Disconnect()
                end)
                local now = owned and #owned:GetChildren() or 0
                if now > before then
                    STATE.hatched = STATE.hatched + (now - before)
                    note("hatched %d from %s", now - before, egg.name)
                end
            end
            return
        end
    end
end

-- A pet is a StringValue whose Value is the species and whose Variant attribute
-- scales it: PetConfig.GetInfo(name).Multiplier times PetConfig.Variants[variant]
-- (Normal 1, Golden 1.5, Rainbow 3, Shiny 5).
local function petPower(pet)
    local ok, info = pcall(PetConfig.GetInfo, pet.Value)
    local base = (ok and type(info) == "table" and info.Multiplier) or 0
    local variant = (PetConfig.Variants or {})[pet:GetAttribute("Variant") or "Normal"] or 1
    return base * variant
end

-- Storage caps at 50 and hatching stops dead once it is full, which is what
-- quietly ended the pet climb. Delete the weakest unequipped ones - the server
-- takes a list of ids on PetSystem.DeleteMany (measured 50 -> 48 in one call).
local function cullPets()
    local folder = LocalPlayer:FindFirstChild("Pets")
    if not folder then return end
    local all = folder:GetChildren()
    if #all < CONFIG.petKeep then return end

    local spare = {}
    for _, pet in ipairs(all) do
        if not pet:GetAttribute("Equipped") then
            spare[#spare + 1] = { id = pet.Name, power = petPower(pet) }
        end
    end
    table.sort(spare, function(a, b) return a.power < b.power end)

    local doomed = {}
    local target = #all - CONFIG.petKeep + CONFIG.petCullBatch
    for index = 1, math.min(target, #spare) do doomed[#doomed + 1] = spare[index].id end
    if #doomed == 0 then return end

    fire("PetSystem.DeleteMany", doomed)
    task.wait(0.8)
    STATE.deleted = STATE.deleted + #doomed
    note("deleted %d weak pets (%d left)", #doomed, #folder:GetChildren())
end

local function pets()
    fire("PetSystem.SetAutoEquip", true)
    fire("PetSystem.EquipBest")
end

-- The players far ahead of us are not doing anything exotic - they simply have
-- the multipliers stacked. Read off a level 300 rebirth account in the same
-- server: PetMultiplier 19,683, AuraWinsMult 3.5, ItemJitsuMult 1.2, against
-- 1/1/1 here. Pets and auras are the wins-priced half of that (the
-- JitsuMultiplier / WinsMultiplier tiers in MultiplierConfig carry ProductIds
-- only, so they are Robux and stay untouched).
local function buyAura()
    local best, bestMult
    for _, aura in pairs(AuraConfig.Auras or {}) do
        local cost = aura.WinsCost
        local mult = aura.GainMultiplier or 0
        if cost and cost <= spendable() and mult > (bestMult or attr("AuraWinsMult", 1)) then
            best, bestMult = aura, mult
        end
    end
    if not best then return end
    fire("BuyAura", best.Id)
    task.wait(0.6)
    fire("EquipAura", best.Id)
    task.wait(0.4)
    if attr("AuraWinsMult", 1) >= bestMult then
        note("aura %s (x%s wins) for %s", tostring(best.Id), tostring(bestMult), abbreviate(best.WinsCost))
    end
end

-- The item shop restocks on a timer and its deals raise ItemJitsuMult.
local function buyItems()
    local offers = select(1, invoke("ItemSystem.GetShopOffers"))
    if type(offers) ~= "table" then return end
    local deals = offers.Deals or offers
    if type(deals) ~= "table" then return end

    for key, deal in pairs(deals) do
        if type(deal) == "table" then
            local cost = deal.Cost or deal.WinsCost or deal.Price
            local sold = deal.Purchased or deal.Sold
            if cost and not sold and cost <= wins() * CONFIG.itemShare then
                fire("ItemSystem.Buy", key)
                task.wait(0.5)
            end
        end
    end
    fire("ItemSystem.EquipBest")
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

local lastRebirths = rebirths()

loop("stats", 0.5, function()
    STATE.jitsu, STATE.wins = jitsu(), wins()
    STATE.rebirths, STATE.world = rebirths(), world()
    if STATE.rebirths ~= lastRebirths then
        lastRebirths = STATE.rebirths
        for key in pairs(CLAIMED) do CLAIMED[key] = nil end
    end
    STATE.variant = attr("SpinjitsuVariant", "-")
    STATE.perSecond = currentPerSecond()
    STATE.level = levelNow()
end)

loop("shop", 8, function()
    -- Never during a run. Every shop action walks the body somewhere else - the
    -- egg, a pad - and a run that gets interrupted loses the walls it had
    -- already opened, so the pass has to start from stage 1 again. Buying only
    -- happens between runs, right after a plate has been cashed.
    if STATE.inRun then return end
    -- Pets first while the team is not even full: a Grass Egg is 100 wins and
    -- the variant shop otherwise takes the balance to zero every single pass,
    -- which is why the first version owned no pets at all after an hour.
    local owned = LocalPlayer:FindFirstChild("Pets")
    local count = owned and #owned:GetChildren() or 0
    if CONFIG.autoPets then cullPets() end
    if CONFIG.autoPets and count < (PetConfig.EquippedLimit or 3) then hatchEggs() end
    if CONFIG.autoVariant then buyVariant() end
    if CONFIG.autoPets and count >= (PetConfig.EquippedLimit or 3) then hatchEggs() end
    if CONFIG.autoAura    then buyAura() end
    if CONFIG.autoItems   then buyItems() end
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
            -- The walls are a CHAIN: only the frontmost standing wall takes
            -- damage, so a stage further in cannot be started early.  Measured
            -- after a rebirth, which respawns everything: 5,248 Jitsu against a
            -- 100 health wall in stage 2 did nothing at all while stage 1 was
            -- standing again.  So every pass walks the stages in order and
            -- stops at the first wall that outlasts the timeout.
            -- One run: walk the chain from stage 1 and break everything the
            -- Jitsu can carry, remembering how far it got.  Only when the chain
            -- stops - a wall that outlasts the timeout, or the last stage - is
            -- a plate taken, and it is the deepest unpaid one, because taking
            -- it resets every wall behind us.
            STATE.inRun = true
            local open = {}
            for _, stage in ipairs(stageFolders()) do
                if not alive() or not CONFIG.autoStages then break end
                if not breakStage(stage) then break end
                open[#open + 1] = stage
                STATE.reached = stage.number
            end

            local progressed = false
            for index = #open, 1, -1 do
                local stage = open[index]
                if not CLAIMED[stage.number] then
                    progressed = collectPlate(stage)
                    break
                end
            end
            STATE.inRun = false

            -- Straight after the cash-out, in this order: rebirth if the level
            -- allows it (it makes every plate payable again and multiplies the
            -- tick), then buy. The shop loop alone was not enough - it is gated
            -- on "not in a run", and a run is almost always in progress, so with
            -- level 1050 against a requirement of 823 the rebirth simply never
            -- fired.
            if progressed then
                if CONFIG.autoRebirth then pcall(doRebirth) end
                if CONFIG.autoWorld   then pcall(climbWorld) end
                if CONFIG.autoPets    then pcall(cullPets) pcall(hatchEggs) end
                if CONFIG.autoVariant then pcall(buyVariant) end
                if CONFIG.autoAura    then pcall(buyAura) end
            end

            if not progressed and #open > 0 then
                -- everything we can reach is already paid; the only way forward
                -- is a deeper wall, so spend on the tick rate instead
                progressed = false
            end
            if not progressed then
                -- A wall that outlasts the timeout is not a bug, it is simply
                -- above the current Jitsu.  Standing in front of it is the worst
                -- thing to do: go spend what the last stages paid instead - a
                -- better variant or a pet raises the tick rate, which is the
                -- only thing that gets through that wall.
                STATE.phase = "between runs, spending"
                STATE.inRun = false
                if CONFIG.autoVariant then pcall(buyVariant) end
                if CONFIG.autoPets    then pcall(hatchEggs) end
                if CONFIG.autoAura    then pcall(buyAura) end
                if CONFIG.autoRebirth then pcall(doRebirth) end
                task.wait(CONFIG.stuckWait)
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
    "hatches the wins-priced eggs; pets multiply and are the biggest lever")
spend:Toggle("Auras", CONFIG.autoAura, function(v) CONFIG.autoAura = v end,
    "Natura 50K up to Galaxy 5T, x1.5 to x3.5 on every win")
spend:Toggle("Item shop", CONFIG.autoItems, function(v) CONFIG.autoItems = v end,
    "buys the restocking deals and equips the best")
spend:Toggle("Free rewards", CONFIG.autoRewards, function(v) CONFIG.autoRewards = v end,
    "codes, playtime, streak, milestones, gifts, offline gain")

local readout = page:Card("STATUS", 0)
local out = readout:Readout(10)

task.spawn(function()
    while alive() do
        out:set({
            "RUN",
            string.format("  world %d   %s   %s", STATE.world, STATE.stage, STATE.phase),
            string.format("  walls %d   plates %d   rebirths %d   pets -%d",
                STATE.walls, STATE.plates, STATE.rebirthsDone, STATE.deleted),
            string.format("  reached stage %d   best cashed %d%s", STATE.reached, STATE.deepest,
                worldReserve() > 0 and string.format("   saving %s for world %d",
                    abbreviate(worldReserve()), attr("MaxWorld", 1) + 1) or ""),
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
    buyVariant = buyVariant, breakStage = breakStage, collectPlate = collectPlate,
    stageFolders = stageFolders,
    CLAIMED = CLAIMED, winPlate = winPlate,
    doRebirth = doRebirth, climbWorld = climbWorld, freeRewards = freeRewards,
    hatchEggs = hatchEggs, eggLadder = eggLadder, buyAura = buyAura, buyItems = buyItems,
    cullPets = cullPets, petPower = petPower,
    MOVE = MOVE, withBody = withBody,
    levelNow = levelNow, currentPerSecond = currentPerSecond, holdAt = holdAt,
}

print("[spinjitsu] running - RightShift toggles the panel")
