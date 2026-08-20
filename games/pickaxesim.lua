--[[
    pickaxesim.lua - "[X3] Pickaxe Simulator!"  (place 82013336390273)

    Verified against server-side values on 2026-08-20, account Lumo_Studios.

    The loop the game wants: mine blocks -> ore -> sell it for Coins -> buy a
    better pickaxe; stand on a training stone -> Power -> spend Power on a
    Rebirth -> better stones, better worlds, better eggs.

    How this game is wired, and why the script looks the way it does:

    * There are only eleven RemoteEvents in the whole place, all of them under
      `ReplicatedStorage.Paper.Remotes`, because the game multiplexes through
      the Paper networking library.  Everything is
      `Paper.Network.FireServer(<action>, ...)` / `InvokeServer(<action>, ...)`
      with a plain English action name.
    * `ReplicatedStorage.Stats.<playerName>` is the state oracle and it is
      complete: Coins, Gems, Power, Rebirths, Ores, EquippedPickaxe, Settings,
      Upgrades, Gamepasses, PetStats.
    * The game ships its own automation and it is FREE - no gamepass:
      `FireServer("Toggle Setting", "AutoMine")` mines by itself (measured 0.35
      blocks/s with a Stone Pickaxe) and `"AutoTrain"` walks onto the best
      training stone and farms Power (measured ~2.2 Power/s on stone 1).  They
      are mutually exclusive: the body is either in the mine or on a stone, so
      this script runs them as phases instead of both at once.
    * **`InvokeServer("Sell Ore", id)` wants the ore id as a NUMBER.** With the
      string name from the Ores folder it returns nil, nil, nil - no error, no
      sale - which reads exactly like a position problem. With `tonumber(name)`
      it answers `(true, true, worth)`. It sells exactly ONE unit per call and
      has **no position check at all**: measured from 668 studs away, deep
      inside the mine and at the sell point alike.
    * Rebirth is priced in **Power**, not coins: the first one costs 250, every
      later one `n * 500 * (rebirths + 1)`. `InvokeServer("Rebirth", n)` answers
      `Can't Afford` below that.
    * `InvokeServer("Buy Pickaxe")` takes no arguments, buys the next one up the
      ladder and equips it (measured: coins 72 -> 22, Wooden -> Stone Pickaxe).
    * `InvokeServer("Hatch Egg", eggName, count)` IS position gated - it answers
      `Out Of Reach!` from the mine, so the body has to be at that egg.

    Never touched: every Robux stand, the gift/pass shop, `Revenue Metadata`,
    the DoubleDamage / DoubleSpeed product buttons and anything that opens a
    purchase prompt.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local Paper       = require(ReplicatedStorage:WaitForChild("Paper", 10))
local Mining      = require(ReplicatedStorage.Modules.Client.Mining)
local Tables      = ReplicatedStorage:WaitForChild("Tables", 10)
local PickaxeData = require(Tables.Pickaxes)
local EggData     = require(Tables.Eggs)
local RebirthData = require(Tables.Rebirths)
local WorldData   = require(Tables.Worlds)
local TrainData   = require(Tables.Training)
local PetLib      = require(ReplicatedStorage.Modules.Shared.PetLib)

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    autoMine     = true,    -- the game's own AutoMine setting, free
    autoTrain    = true,    -- the game's own AutoTrain setting, free
    autoSell     = true,    -- Sell Ore, numeric id, no position check
    autoPickaxe  = true,    -- Buy Pickaxe whenever the coins cover it
    autoRebirth  = true,    -- priced in Power
    autoHatch    = true,    -- walks to the egg first, it is position gated
    autoWorld    = true,    -- move up a world as soon as the rebirths allow
    autoRewards  = true,    -- daily reward, lucky block, the description code
    autoPets     = true,    -- EquipBest, and delete the overflow
    keepPets     = 30,      -- how many pets to keep before culling
    maxRebirthBatch = 25,   -- Tables.Rebirths is indexed by the amount
    powerHeadroom = 3,      -- stop training once power is this far past the price
    powerKeep    = 2,       -- rebirth only while the cost fits this often, so
                            -- damage is left over for the mining phase
    minePhase    = 90,      -- seconds of mining per cycle
    trainPhase   = 90,      -- seconds of training per cycle
    sellGap      = 0.05,    -- one call per ore unit; this is the pacing
    eggReserve   = 0.5,     -- never spend more than this share on one egg
}

local STATE = {
    coins = 0, gems = 0, power = 0, rebirths = 0, blocks = 0,
    pickaxe = "-", world = 1, phase = "starting", note = "",
    sold = 0, bought = 0, rebirthsDone = 0, hatched = 0, petsDeleted = 0, petPower = 0,
    nextRebirthCost = 0, nextPickaxe = "-", nextPickaxeCost = 0,
}

_G.__PICKSIM = (_G.__PICKSIM or 0) + 1
local GEN = _G.__PICKSIM
local function alive() return _G.__PICKSIM == GEN end

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

----------------------------------------------------------------------------
-- the stats folder is the oracle
----------------------------------------------------------------------------

local Stats = ReplicatedStorage:WaitForChild("Stats", 10):WaitForChild(LocalPlayer.Name, 20)
if not Stats then
    warn("[pickaxesim] no stats folder for " .. LocalPlayer.Name .. " - still loading?")
    return
end

local function stat(name, default)
    local value = Stats:FindFirstChild(name)
    if value then return value.Value end
    return default
end

local function setting(name)
    local folder = Stats:FindFirstChild("Settings")
    local value = folder and folder:FindFirstChild(name)
    return value and value.Value or false
end

local function coins()    return stat("Coins", 0) end
local function gems()     return stat("Gems", 0) end
local function power()    return stat("Power", 0) end
local function rebirths() return stat("Rebirths", 0) end

local function fire(...)  return pcall(Paper.Network.FireServer, ...) end
local function invoke(...)
    local results = { pcall(Paper.Network.InvokeServer, ...) }
    if not results[1] then return nil end
    return results[2], results[3], results[4]
end

local function abbreviate(n)
    if type(n) ~= "number" then return tostring(n) end
    local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do n = n / 1000 i = i + 1 end
    return string.format(i == 1 and "%.0f%s" or "%.2f%s", n, units[i])
end

-- Toggling is a flip, not a set, so always compare against the live value or
-- the two phases fight each other.
local function want(settingName, wanted)
    if setting(settingName) ~= wanted then
        fire("Toggle Setting", settingName)
        task.wait(0.35)
    end
end

----------------------------------------------------------------------------
-- actions
----------------------------------------------------------------------------

-- One call per ore unit, and the id has to be a number.
local function sellOres()
    local folder = Stats:FindFirstChild("Ores")
    if not folder then return end
    for _, entry in ipairs(folder:GetChildren()) do
        if not alive() or not CONFIG.autoSell then return end
        local count = entry.Value or 0
        local id = tonumber(entry.Name)
        if id and count > 0 then
            for _ = 1, math.min(count, 60) do
                local ok, sold = invoke("Sell Ore", id)
                if not (ok and sold) then break end
                STATE.sold = STATE.sold + 1
                task.wait(CONFIG.sellGap)
            end
        end
    end
end

-- The ladder is `Order`; `Cost` is in coins and the purchase equips itself.
local function pickaxeLadder()
    local list = {}
    for name, data in pairs(PickaxeData) do
        local cost = data.Cost or 0
        local order = data.Order or 0
        if cost > 0 and order > 0 then
            list[#list + 1] = { name = name, cost = cost, order = order, speed = data.Speed or 0 }
        end
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    return list
end

local LADDER = pickaxeLadder()

-- `Order` is not unique: order 3 holds the Iron Pickaxe at 500 coins AND the
-- Shadowstone at 5,000, and the event pickaxes sit on negative orders.  Taking
-- the first entry above BestPickaxe therefore picked a 100,000 coin axe while
-- the game's own shop offered the next rung for 2,500.  Pick the CHEAPEST entry
-- on the lowest order above the one already owned.
local function nextPickaxe()
    local best = stat("BestPickaxe", 1)
    local bestOrder
    for _, entry in ipairs(LADDER) do
        if entry.order > best and (not bestOrder or entry.order < bestOrder) then
            bestOrder = entry.order
        end
    end
    if not bestOrder then return end

    local pick
    for _, entry in ipairs(LADDER) do
        if entry.order == bestOrder and (not pick or entry.cost < pick.cost) then
            pick = entry
        end
    end
    return pick
end

local function buyPickaxes()
    for _ = 1, 12 do
        local pick = nextPickaxe()
        STATE.nextPickaxe = pick and pick.name or "max"
        STATE.nextPickaxeCost = pick and pick.cost or 0
        if not pick or coins() < pick.cost then return end
        local ok, bought = invoke("Buy Pickaxe")
        if not (ok and bought) then return end
        STATE.bought = STATE.bought + 1
        note("pickaxe %s for %s coins", pick.name, abbreviate(pick.cost))
        task.wait(0.4)
    end
end

-- Power, not coins: first rebirth 250, then n * 500 * (rebirths + 1).
local function rebirthCost(amount)
    local have = rebirths()
    if have == 0 and amount == 1 then return 250 end
    return amount * 500 * (have + 1)
end

-- Power IS the mining damage, and a rebirth spends it.  Rebirthing until the
-- bar reads zero is why the character went back into the mine and broke nothing
-- at all.  So a rebirth only happens out of the surplus: the cost has to fit
-- powerKeep times over, which leaves that much damage standing afterwards.
local function doRebirths()
    for _ = 1, CONFIG.maxRebirthBatch do
        local cost = rebirthCost(1)
        STATE.nextRebirthCost = cost
        if power() < cost * CONFIG.powerKeep then return end
        -- Buying several at once is the MaxRebirth GAMEPASS, not a price
        -- question: at 15 rebirths and 32,760 power, `Rebirth(1)` went through
        -- while `Rebirth(2)` answered "Can't Afford" - and a batch larger than
        -- the Rebirths table answers "Invalid index".  So it is always one at a
        -- time, in a loop, which costs nothing but a few remote calls.
        local ok, done, message = invoke("Rebirth", 1)
        if not (ok and done) then
            note("rebirth refused: %s", tostring(message))
            return
        end
        STATE.rebirthsDone = STATE.rebirthsDone + 1
        note("rebirth %d (%s power)", rebirths(), abbreviate(rebirthCost(1)))
        task.wait(0.8)
    end
end

-- Hatching is position gated - "Out Of Reach!" from anywhere else - so the body
-- goes to the egg, hatches, and the mining phase pulls it back on its own.
-- Coins are the pickaxe currency and the pickaxe is what makes the mining
-- faster, so the next rung is fenced off before an egg may touch the balance -
-- otherwise 10 and 100 coin eggs quietly eat the 100,000 that the next pickaxe
-- costs, which is exactly what happened over the first half hour.  Gem eggs are
-- free of that rule; nothing else spends gems.
local function eggFor(worldNumber)
    local best, bestCost
    local pick = nextPickaxe()
    local reserved = (CONFIG.autoPickaxe and pick) and pick.cost or 0
    for name, data in pairs(EggData) do
        if data.WorldNumber == worldNumber and (data.Cost or 0) > 0 then
            local currency = data.Currency
            local balance = currency == "Coins" and math.max(0, coins() - reserved)
                            or (currency == "Gems" and gems() or 0)
            if balance * CONFIG.eggReserve >= data.Cost then
                if not bestCost or data.Cost > bestCost then best, bestCost = name, data.Cost end
            end
        end
    end
    return best, bestCost
end

local function findEggModel(name)
    local folder = workspace:FindFirstChild("Eggs")
    if not folder then return end
    local direct = folder:FindFirstChild(name)
    if direct then return direct end
    for _, child in ipairs(folder:GetDescendants()) do
        if child.Name == name and (child:IsA("Model") or child:IsA("BasePart")) then return child end
    end
end

local function hatchEggs()
    local name = eggFor(stat("CurrentWorld", 1))
    if not name then return end

    local model = findEggModel(name)
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not (model and root) then return end

    local position = model:IsA("Model") and model:GetPivot().Position or model.Position
    local pin = RunService.Heartbeat:Connect(function()
        root.CFrame = CFrame.new(position + Vector3.new(0, 4, 0))
    end)
    task.wait(1.2)

    for _ = 1, 10 do
        local ok, hatched, message = invoke("Hatch Egg", name, 1)
        if not (ok and hatched) then
            if message then note("egg %s: %s", name, tostring(message)) end
            break
        end
        STATE.hatched = STATE.hatched + 1
        task.wait(0.35)
    end
    pin:Disconnect()
    note("hatched %s", name)
end

-- Worlds have a rebirth Requirement in the table, but that is not the gate: the
-- server answers "World not unlocked." until `WorldsUnlocked` has caught up, so
-- both have to be satisfied.
local function climbWorlds()
    local current = stat("CurrentWorld", 1)
    local have = rebirths()
    local unlocked = stat("WorldsUnlocked", 1)
    local target = current
    for number, data in pairs(WorldData) do
        if type(number) == "number" and number <= unlocked
           and (data.Requirement or 0) <= have and number > target then
            target = number
        end
    end
    if target ~= current then
        local ok, done, message = invoke("Set Current World", target)
        if ok and done then
            note("world %d -> %d (%s)", current, target, tostring(WorldData[target] and WorldData[target].WorldName))
        elseif message then
            note("world switch refused: %s", tostring(message))
        end
    end
end

-- The game equips hatched pets on its own but not the best ones: measured 9
-- pets owned, 5 equipped and PetPower 14 while the best single pet was worth
-- 40.  One EquipBest call took it to 57.
local function equipBestPets()
    invoke("Pet", { Action = "EquipBest" })
end

-- Storage is 50 by default and hatching fills it fast.  Delete takes a list of
-- pet ids; PetLib sorts the unequipped ones by power so the equipped team is
-- never touched.
local function cullPets()
    local petsFolder = Stats:FindFirstChild("Pets")
    local petStats = Stats:FindFirstChild("PetStats")
    if not (petsFolder and petStats) then return end

    local count = petStats:FindFirstChild("PetCount")
    local storage = petStats:FindFirstChild("PetStorage")
    count = count and count.Value or 0
    storage = storage and storage.Value or 50
    if count <= math.min(CONFIG.keepPets, storage - 5) then return end

    local ok, sorted = pcall(PetLib.SortUnequippedPetByPower, LocalPlayer)
    if not ok or type(sorted) ~= "table" then return end

    local doomed = {}
    for index = #sorted, 1, -1 do
        local entry = sorted[index]
        local name = type(entry) == "table" and (entry.Name or entry.Id) or (typeof(entry) == "Instance" and entry.Name)
        if name then
            doomed[#doomed + 1] = name
            if #doomed >= math.min(25, count - CONFIG.keepPets) then break end
        end
    end
    if #doomed == 0 then return end

    invoke("Pet", { Action = "Delete", Pets = doomed })
    STATE.petsDeleted = STATE.petsDeleted + #doomed
    note("deleted %d weak pets (%d owned)", #doomed, count)
end

local function freeRewards()
    invoke("Redeem Code", "update17")
    invoke("Claim Daily")
    invoke("Claim LuckyBlock")
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

loop("stats", 0.5, function()
    STATE.coins, STATE.gems = coins(), gems()
    STATE.power, STATE.rebirths = power(), rebirths()
    STATE.pickaxe = stat("EquippedPickaxe", "-")
    STATE.world = stat("CurrentWorld", 1)
    local analytics = Stats:FindFirstChild("Analytics")
    local mined = analytics and analytics:FindFirstChild("BlocksMined")
    STATE.blocks = mined and mined.Value or STATE.blocks
    STATE.nextRebirthCost = rebirthCost(1)
end)

loop("sell", 2, function()
    if CONFIG.autoSell then sellOres() end
end)

loop("spend", 6, function()
    if CONFIG.autoPickaxe then buyPickaxes() end
    if CONFIG.autoRebirth then doRebirths() end
    if CONFIG.autoWorld   then climbWorlds() end
end)

loop("eggs", 25, function()
    if CONFIG.autoHatch then hatchEggs() end
end)

loop("pets", 20, function()
    if not CONFIG.autoPets then return end
    equipBestPets()
    cullPets()
    local petStats = Stats:FindFirstChild("PetStats")
    local petPower = petStats and petStats:FindFirstChild("PetPower")
    STATE.petPower = petPower and petPower.Value or 0
end)

loop("rewards", 300, function()
    if CONFIG.autoRewards then freeRewards() end
end)

-- Mining and training cannot run together, so they take turns. Mining pays for
-- pickaxes, training pays for rebirths.
task.spawn(function()
    while alive() do
        -- Train only while the next rebirth is still out of reach.  A fixed
        -- 50/50 split kept training long after the power had run away from the
        -- rebirth price (measured 413,640 power against a 5,000 price) while
        -- the coins - which is what the next pickaxe costs - stood still.
        local needsPower = power() < rebirthCost(1) * CONFIG.powerHeadroom
        if CONFIG.autoTrain and (needsPower or not CONFIG.autoMine) then
            STATE.phase = "training"
            want("AutoMine", false)
            want("AutoTrain", true)
            local until_ = os.clock() + CONFIG.trainPhase
            while alive() and CONFIG.autoTrain and os.clock() < until_
                  and power() < rebirthCost(1) * CONFIG.powerHeadroom do
                task.wait(1)
            end
        end

        if CONFIG.autoMine then
            STATE.phase = "mining"
            want("AutoTrain", false)
            fire("Stop Training")
            -- AutoMine only starts once the body is actually at the mine: left
            -- on a training stone or at spawn it stays enabled and mines
            -- nothing, which reads like a broken setting.
            local folder = workspace:FindFirstChild("Worlds")
            local world = folder and folder:FindFirstChild(
                (WorldData[stat("CurrentWorld", 1)] or {}).WorldName or "Spawn")
            local surface = world and world:FindFirstChild("SurfaceTP")
            local character = LocalPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if surface and root then
                root.CFrame = CFrame.new(surface:GetPivot().Position + Vector3.new(0, 3, 0))
                task.wait(0.6)
            end
            want("AutoMine", true)
            local until_ = os.clock() + CONFIG.minePhase
            while alive() and CONFIG.autoMine and os.clock() < until_ do
                -- AutoMine only advances while the body is inside the mine.  A
                -- rebirth or an egg hatch puts it back on the surface and the
                -- setting then sits there enabled and idle - measured: 0 blocks
                -- in 100 seconds.  Mining.IsInMine() is the honest check and
                -- TpToCurrentBlock() is the fix (19 blocks in the next 12s).
                local ok, inMine = pcall(Mining.IsInMine)
                if ok and not inMine then pcall(Mining.TpToCurrentBlock) end
                task.wait(1)
            end
        end

        if not (CONFIG.autoMine or CONFIG.autoTrain) then
            STATE.phase = "idle"
            task.wait(1)
        end
    end
end)

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__PICKSIM_WIN then pcall(function() _G.__PICKSIM_WIN:Destroy() end) end
for _, gui in ipairs(game:GetService("CoreGui"):GetChildren()) do
    if gui.Name == "PICKAXESIM" then pcall(function() gui:Destroy() end) end
end

local win = UI.Window({
    title = "PICKAXE", accentTitle = "SIM", subtitle = "seltonmt",
    badge = "\226\155\143", width = 920, height = 580,
})
_G.__PICKSIM_WIN = win

local page = win:Page("FARMING", UI.icon and UI.icon.pickaxe or nil)

local engine = page:Card("ENGINE", 1)
engine:Toggle("Auto mine", CONFIG.autoMine, function(v) CONFIG.autoMine = v end,
    "the game's own AutoMine setting - free, no gamepass")
engine:Toggle("Auto train", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
    "AutoTrain on the best stone; power is what a rebirth costs")
engine:Toggle("Auto sell", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
    "Sell Ore per unit, numeric id, works from anywhere")
engine:Slider("Mine phase (s)", 15, 300, CONFIG.minePhase, function(v) CONFIG.minePhase = v end)
engine:Slider("Train phase (s)", 15, 300, CONFIG.trainPhase, function(v) CONFIG.trainPhase = v end)

local spend = page:Card("SPENDING", 2)
spend:Toggle("Buy pickaxes", CONFIG.autoPickaxe, function(v) CONFIG.autoPickaxe = v end,
    "climbs the ladder in order; the purchase equips itself")
spend:Toggle("Rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "costs power: 250 for the first, then n x 500 x (rebirths+1)", UI.theme.warn)
spend:Toggle("Hatch eggs", CONFIG.autoHatch, function(v) CONFIG.autoHatch = v end,
    "walks to the egg first - hatching is position gated")
spend:Toggle("Climb worlds", CONFIG.autoWorld, function(v) CONFIG.autoWorld = v end,
    "moves up as soon as the rebirths cover the requirement")
spend:Toggle("Free rewards", CONFIG.autoRewards, function(v) CONFIG.autoRewards = v end,
    "daily reward, lucky block and the code from the game description")
spend:Toggle("Pets", CONFIG.autoPets, function(v) CONFIG.autoPets = v end,
    "EquipBest (measured 14 -> 57 pet power) and deletes the overflow")

local readout = page:Card("STATUS", 0)
local out = readout:Readout(10)

task.spawn(function()
    while alive() do
        out:set({
            "RUN",
            string.format("  phase %s   world %d   pickaxe %s", STATE.phase, STATE.world, tostring(STATE.pickaxe)),
            string.format("  sold %d   pickaxes %d   rebirths %d   eggs %d   pets -%d",
                STATE.sold, STATE.bought, STATE.rebirthsDone, STATE.hatched, STATE.petsDeleted),
            string.format("  pet power %s", abbreviate(STATE.petPower)),
            "ECONOMY",
            string.format("  coins %s   gems %s", abbreviate(STATE.coins), abbreviate(STATE.gems)),
            string.format("  power %s / %s for the next rebirth",
                abbreviate(STATE.power), abbreviate(STATE.nextRebirthCost)),
            string.format("  next pickaxe %s (%s)", tostring(STATE.nextPickaxe), abbreviate(STATE.nextPickaxeCost)),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        win:SetStatus(string.format("%s coins   %s power   r%d   world %d   %s",
            abbreviate(STATE.coins), abbreviate(STATE.power), STATE.rebirths, STATE.world, STATE.phase))
        task.wait(0.5)
    end
end)

_G.__PICKSIM_DBG = {
    CONFIG = CONFIG, STATE = STATE, Stats = Stats, Paper = Paper,
    sellOres = sellOres, buyPickaxes = buyPickaxes, doRebirths = doRebirths,
    hatchEggs = hatchEggs, climbWorlds = climbWorlds, freeRewards = freeRewards,
    invoke = invoke, fire = fire, ladder = LADDER, rebirthCost = rebirthCost,
    nextPickaxe = nextPickaxe, eggFor = eggFor,
}

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste.
pcall(function() win:Home() end)

print("[pickaxesim] running - RightShift toggles the panel")
