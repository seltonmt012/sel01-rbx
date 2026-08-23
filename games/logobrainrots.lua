--[[
    logobrainrots.lua - "Logo für Brainrots!"  place 123959902101040
    ------------------------------------------------------------------------
    Despite the name this is not a quiz game. It is a carry-and-place plot
    income game with a logo-quiz door between the stages, and the doors are
    irrelevant because the whole route is flown over them.

    The loop, as measured through the bridge on 2026-08-20:

      pick the richest brainrot lying in the world (all 110 are visible from
      home, they are NOT streamed out)
        -> fly to it, pin the root part on it ~1.2s, fireproximityprompt(Grab)
        -> plr:GetAttribute("Carrying") goes true, CarryingObject points at it
        -> fly home AT y = 300 and land on the plot; arriving on your own plot
           is the whole delivery, the server fires BrainrotSaved
        -> PlaceBrainrotOnStand:FireServer(standModel, toolName)
        -> CollectStandCash:FireServer("<n>") from anywhere

    Verified facts this script is built on (do not re-derive):

      * There is NO stage gate. A stage 10 brainrot was grabbed at rebirth 0
        with 2,490$ to the player's name. The MathDoors only gate the walking
        route, and every option part carries a readable IsCorrect attribute
        anyway.
      * Free CFrame teleporting works, no snapback, no reporting remote seen.
      * THE GROUND ROUTE HOME DROPS THE CARRY. Walking/warping back along the
        ground lost the brainrot every time at x ~ 2100. Crossing at y = 300
        carried a 2.92B/s Secret all the way from x 2657 to the plot. The
        cruise altitude is not decoration, it is the delivery.
      * CollectStandCash is NOT position gated - 26,231,128 collected from
        2,347 studs away.
      * Placement needs the brainrot EQUIPPED as a Tool. A freshly delivered
        one is equipped by the server; one pulled back off a stand only lands
        in Data.BrainrotsBackpack plus a Tool in the Backpack, and
        Humanoid:EquipTool(tool) is the missing step. Firing the place remote
        with the inventory key while nothing is held does nothing at all.
      * Income of a placed brainrot = brainrot_level_upgrade.GetIncome(
        CashPerSecond, Level) = cps * 1.0806976^(Level-1). The CashPerSecond
        stored on the model already includes the mutation multiplier, so it is
        the raw figure and comparable across brainrots. plr PerSecond is the
        sum of those TIMES the rebirth multiplier - never mix the two.
      * Level price = cps/5 * 1.17^(Level-1). Verified to the unit: predicted
        374,730, charged 374,730, income +226,798/s. Payback at level 1 is
        ~1.65s and only reaches ~126s around level 50. It is by far the
        strongest sink in the game.
      * REBIRTH WIPES THE WHOLE BALANCE, not just its price: 326,019,684 -> 0.
        It multiplies money by 1 + 0.5*rebirths and resets speed (30 -> 18), but
        it KEEPS every placed brainrot - measured on a full plot, rebirth 2 -> 3,
        all 21 seats byte-identical before and after and PerSecond 246.06B ->
        307.57B, exactly x1.25. The balance regenerates in about two minutes at
        that income, so it is on by default; the money is spent down into levels
        and base upgrades first because those survive the reset.
      * leaderstats.Money is a StringValue ("2,490$") for display. The real
        numbers all live in plr.Data (Money, Rebirth, StandsUnlocked, Stands,
        StandsCash, BrainrotsBackpack).
      * Stands above Data.StandsUnlocked have no prompt and the server refuses
        them, and UnlockStand is a server -> client NOTIFICATION - firing it
        upward in three argument shapes changed nothing. What widens the plot is
        the "Upgrade Base" screen standing on the plot (Plots.<n>.Upgrader), a
        plain ClickDetector at 32 studs: it reads "15 >> 16 / 100.0T $" and each
        base level is one more stand, so StandsUnlocked = 8 + base level and
        level 16 is the ceiling at 24 stands. The price is
        Modules.unlock_stands[nextLevel] (2.5M, 5M, 17.5M, 115M ... 100T) - take
        it from there, never from the abbreviated label. Verified end to end:
        saved to 103.57T, bought base level 16, 24 stands, then rebirthed.
      * LEVELS STOP AT 100. level_upgrades_manager greys the button out and
        answers "Max level reached!". Once the plot is maxed the base upgrade is
        the only sink left, which is why it gets a reserve instead of being
        outbid by levels forever.

    Panel: RightShift.  Console handle: _G.__LOGOBR_DBG
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local plr = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local Modules = ReplicatedStorage:WaitForChild("Modules", 10)

-- ---------------------------------------------------------------- generation
-- Re-running in the executor does not restart the Lua VM, so every loop below
-- captures this number and exits the moment it stops matching.
_G.__LOGOBR = (_G.__LOGOBR or 0) + 1
local GEN = _G.__LOGOBR

-- ------------------------------------------------------------------ configs
local LevelUpgrade, Brainrots, RebirthsMgr, SpeedMgr, UnlockStands
pcall(function() LevelUpgrade = require(Modules:WaitForChild("brainrot_level_upgrade", 10)) end)
pcall(function() Brainrots     = require(Modules:WaitForChild("brainrots", 10)) end)
pcall(function() RebirthsMgr   = require(Modules:WaitForChild("rebirths_manager", 10)) end)
pcall(function() SpeedMgr      = require(Modules:WaitForChild("speed_manager", 10)) end)
pcall(function() UnlockStands  = require(Modules:WaitForChild("unlock_stands", 10)) end)

-- Read off level_upgrades_manager: at 100 the button greys out and the client
-- answers "Max level reached!". Without this the payback ranking keeps putting
-- a maxed brainrot at the top of the list and the pass buys nothing forever.
local MAX_LEVEL = 100

local function levelIncome(cps, level)
    cps, level = tonumber(cps) or 0, tonumber(level) or 1
    if LevelUpgrade and LevelUpgrade.GetIncome then
        local ok, v = pcall(LevelUpgrade.GetIncome, cps, level)
        if ok and v then return v end
    end
    return math.floor(cps * 1.0806976 ^ (level - 1) + 0.5)
end

local function levelPrice(cps, level)
    cps, level = tonumber(cps) or 0, tonumber(level) or 1
    if LevelUpgrade and LevelUpgrade.GetPrice then
        local ok, v = pcall(LevelUpgrade.GetPrice, cps, level)
        if ok and v then return v end
    end
    return math.floor(cps / 5 * 1.17 ^ (level - 1) + 0.5)
end

-- ------------------------------------------------------------------- config
local CONFIG = {
    -- farming
    autoFarm      = false,  -- the whole carry loop
    minStage      = 1,      -- ignore anything below this stage
    maxStage      = 10,     -- ignore anything above (fractional stages count)
    autoCollect   = true,   -- CollectStandCash on every stand, from anywhere
    autoPlace     = true,   -- seat what was delivered
    autoSwap      = true,   -- pull the weakest stand when a better one arrives
    autoSell      = true,   -- sell inventory leftovers a stand would not take

    -- spending
    autoLevels    = true,   -- level placed brainrots - 1.65s payback at level 1
    autoBase      = true,   -- Upgrade Base: one more stand, priced from
                            -- unlock_stands; the only sink left once levels max
    autoSpeed     = false,  -- walking speed is pointless while we teleport
    autoRebirth   = true,   -- wipes the balance but keeps every brainrot

    -- freebies
    autoOffline   = true,
    autoQuests    = true,   -- JobSahur + the one-rebirth quest

    -- tuning
    cruiseY       = 300,    -- the altitude that keeps a carried brainrot
    hopSeconds    = 0.35,   -- pause per flight waypoint
    hops          = 8,      -- waypoints along the cruise leg
    streamWait    = 6,      -- seconds waited on arrival for the model's parts
                            -- to stream in; from the plot the target is a Model
                            -- with no children and therefore no Grab prompt
    grabHold      = 1.4,    -- pin time on the brainrot before firing the prompt
    grabWait      = 1.6,    -- time given to the server to answer the prompt
    deliverTimeout = 20,    -- seconds spent on the plot waiting for Carrying to
                            -- clear; the plot has to stream back in first
    dropAfter     = 3,      -- failed deliveries before the brainrot is dropped
    collectEvery  = 5,      -- other players can steal, so drain often
    spendEvery    = 12,
    levelsPerPass = 12,
    maxPayback    = 600,    -- never buy a level slower than this many seconds
    reserveWindow = 300,    -- a base upgrade is only reserved for when income
                            -- reaches it inside this many seconds; an
                            -- unreachable target is a wall, not a goal
    rebirthKeep   = 0.0,    -- fraction of the balance NOT spent before rebirth
}

-- -------------------------------------------------------------------- state
local STATE = {
    running     = false,
    phase       = "idle",
    note        = "",
    carried     = 0,
    placed      = 0,
    swapped     = 0,
    sold        = 0,
    levels      = 0,
    rebirths    = 0,
    collected   = 0,
    lastGrab    = "-",
    lastGrabCps = 0,
    target      = "-",
    failedGrabs = 0,
    stuckDeliveries = 0,
    baseUpgrades = 0,
    pinTarget   = nil,     -- Vector3 or nil; one shared Heartbeat honours it
    farmBusy    = false,   -- only one routine may drive the character
    uiOwner     = nil,
}

-- --------------------------------------------------------------- small util
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
    STATE.note = tostring(s)
end

local function character() return plr.Character end
local function humanoid()
    local ch = character()
    return ch and ch:FindFirstChildOfClass("Humanoid")
end
local function rootPart()
    local ch = character()
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

local Data = plr:WaitForChild("Data", 20)

local function dataNum(name, fallback)
    local v = Data and Data:FindFirstChild(name)
    if not v then return fallback or 0 end
    return tonumber(v.Value) or (fallback or 0)
end

local function money()      return dataNum("Money") end
local function rebirths()   return dataNum("Rebirth") end
local function unlocked()   return dataNum("StandsUnlocked", 8) end
local function perSecond()  return tonumber(plr:GetAttribute("PerSecond")) or 0 end

-- The rebirth multiplier is global, so it cancels in every brainrot-vs-brainrot
-- comparison. It belongs in one place only: the payback maths, where money
-- meets income.
local function moneyMultiplier()
    return 1 + rebirths() * 0.5
end

-- ------------------------------------------------------------------ my plot
local function myPlot()
    local name = plr:GetAttribute("PlotName")
    if not name then return nil end
    local plots = workspace:FindFirstChild("Plots")
    return plots and plots:FindFirstChild(tostring(name))
end

-- The plot streams out while we are in the far stages, so the home coordinate
-- is cached the first time it is readable. A census taken from a streamed-out
-- plot is a missing chunk, not a fact - every decision below waits until we
-- are home again.
-- Kept in _G on purpose. A reload out in the far stages starts with the plot
-- streamed out, and a nil home meant carryHome() bailed instantly and the
-- brainrot was dropped every single cycle - the loop looked like a delivery
-- bug when it was really "we never learned where home is".
local HOME = _G.__LOGOBR_HOME
local function homePos()
    local plot = myPlot()
    if plot then
        local sp = plot:FindFirstChild("SpawnPos")
        if sp then
            HOME = sp.Position + Vector3.new(0, 3.5, 0)
            _G.__LOGOBR_HOME = HOME
        end
    end
    return HOME
end
homePos()

-- Somewhere to aim at when the exact home is not known yet. From the far
-- stages every BasePart around the plot is streamed out - SpawnPos, the
-- SpawnLocation and the ReturnPart are all simply absent - but the plot FOLDER
-- survives and its Model children keep a readable WorldPivot. That pivot is
-- close enough to fly to; landing there brings the plot back into range and
-- homePos() resolves exactly on the next tick.
local function homeAnchor()
    local h = homePos()
    if h then return h end
    local plot = myPlot()
    if plot then
        for _, c in ipairs(plot:GetChildren()) do
            if c:IsA("Model") then
                local ok, pivot = pcall(function() return c:GetPivot().Position end)
                if ok and pivot and pivot.Magnitude > 1 then
                    return pivot + Vector3.new(0, 8, 0)
                end
            end
        end
    end
    for _, name in ipairs({ "SpawnLocation", "ReturnPart" }) do
        local part = workspace:FindFirstChild(name)
        if part and part:IsA("BasePart") then return part.Position + Vector3.new(0, 5, 0) end
    end
    return nil
end

local function atHome()
    local hrp, h = rootPart(), HOME
    if not (hrp and h) then return false end
    return (hrp.Position - h).Magnitude < 90
end

-- --------------------------------------------------------------- the pin
-- One shared Heartbeat. A RunService connection per routine is what turns a
-- Roblox script into a stutter, and two of them fight over the CFrame.
task.spawn(function()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if _G.__LOGOBR ~= GEN then conn:Disconnect(); return end
        local target = STATE.pinTarget
        if not target then return end
        local hrp = rootPart()
        if not hrp then return end
        hrp.CFrame = CFrame.new(target)
        hrp.AssemblyLinearVelocity = Vector3.zero
    end)
end)

local function warp(pos)
    local hrp = rootPart()
    if not hrp then return false end
    hrp.CFrame = CFrame.new(pos)
    hrp.AssemblyLinearVelocity = Vector3.zero
    return true
end

-- Fly from wherever we are to `dest`, climbing to the cruise altitude first and
-- only dropping at the very end. Going anywhere along the ground with a
-- brainrot in hand loses it.
local function flyTo(dest)
    local hrp = rootPart()
    if not hrp then return false end
    local from = hrp.Position
    local y    = CONFIG.cruiseY

    warp(Vector3.new(from.X, y, from.Z))
    task.wait(CONFIG.hopSeconds)

    local a = Vector3.new(from.X, y, from.Z)
    local b = Vector3.new(dest.X, y, dest.Z)
    local n = math.max(2, math.floor(CONFIG.hops))
    for i = 1, n do
        if _G.__LOGOBR ~= GEN then return false end
        warp(a:Lerp(b, i / n))
        task.wait(CONFIG.hopSeconds)
    end

    warp(dest)
    return true
end

-- ------------------------------------------------------------ world census
-- Every brainrot in the game sits as a Model directly under workspace, named
-- after its mutation ("Normal" / "Golden" / "Diamond" / ...) and carrying its
-- whole state in attributes. All 110 stayed readable from the plot, so the
-- target choice is a real ranking, not a scan of whatever happens to be near.
local function worldBrainrots()
    local out = {}
    for _, c in ipairs(workspace:GetChildren()) do
        if c:IsA("Model") then
            local name = c:GetAttribute("BrainrotName")
            local stage = tonumber(c:GetAttribute("Stage"))
            if name and stage then
                out[#out + 1] = {
                    model    = c,
                    name     = name,
                    stage    = stage,
                    cps      = tonumber(c:GetAttribute("CashPerSecond")) or 0,
                    mutation = c:GetAttribute("Mutation") or "Normal",
                    held     = c:GetAttribute("IsHeld") == true,
                }
            end
        end
    end
    return out
end

-- The model itself is replicated everywhere - that is what makes the ranking
-- honest - but its PARTS are streamed, so from the plot a stage 10 brainrot is
-- a Model with no children and no Grab prompt at all. Looking the prompt up
-- before flying there is what made 154 grabs fail in a row without the
-- character ever leaving the base.
local function grabPrompt(model, timeout)
    local deadline = os.clock() + (timeout or 0)
    repeat
        local part = model:FindFirstChild("Part")
        local prompt = part and part:FindFirstChild("Grab")
        if prompt and prompt:IsA("ProximityPrompt") then return prompt end
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("ProximityPrompt") then return d end
        end
        if os.clock() >= deadline then return nil end
        task.wait(0.2)
    until _G.__LOGOBR ~= GEN
    return nil
end

-- ------------------------------------------------------------------ stands
-- A stand is occupied when Data.Stands.<n> holds a Folder. The world model is
-- only the picture; the folder is the server's copy and the only thing worth
-- reading.
local function standEntry(n)
    local folder = Data and Data:FindFirstChild("Stands")
    local s = folder and folder:FindFirstChild(tostring(n))
    if not s then return nil end
    local e = s:FindFirstChildOfClass("Folder")
    if not e then return nil end
    local function val(k, d)
        local v = e:FindFirstChild(k)
        return v and v.Value or d
    end
    return {
        key      = e.Name,
        stand    = tostring(n),
        name     = val("BrainrotName", "?"),
        cps      = tonumber(val("CashPerSecond", 0)) or 0,
        level    = tonumber(val("Level", 1)) or 1,
        mutation = val("Mutation", "Normal"),
        rarity   = val("Rarity", "?"),
    }
end

local function standModel(n)
    local plot = myPlot()
    local stands = plot and plot:FindFirstChild("Stands")
    return stands and stands:FindFirstChild(tostring(n))
end

local function census()
    local free, used, total = {}, {}, unlocked()
    for i = 1, total do
        local e = standEntry(i)
        if e then
            e.income = levelIncome(e.cps, e.level)
            used[#used + 1] = e
        else
            free[#free + 1] = i
        end
    end
    return free, used, total
end

local function weakestStand()
    local _, used = census()
    local worst = nil
    for _, e in ipairs(used) do
        if (not worst) or e.income < worst.income then worst = e end
    end
    return worst
end

-- Everything below ranks brainrots on their BASE CashPerSecond, never on the
-- levelled income. A level costs cps/5 * 1.17^(L-1) and pays back in about a
-- second and a half, so the level a brainrot happens to sit at is a few seconds
-- of income, not an investment worth protecting - while the base value is
-- permanent. Ranking on levelled income let a tiny brainrot at level 40 out-rank
-- a fresh 235M one and hold a stand against it forever.
local function rank(e) return tonumber(e.cps) or 0 end

local function worstOf(list)
    local worst = nil
    for _, e in ipairs(list) do
        if (not worst) or rank(e) < rank(worst) then worst = e end
    end
    return worst
end

-- The bar a world brainrot has to clear to be worth the trip: an empty stand
-- means anything qualifies, a full plot means it has to beat the weakest one
-- that is already earning.
local function acceptanceFloor()
    local free, used, total = census()
    if #free > 0 then return 0, total end
    local worst = worstOf(used)
    return worst and rank(worst) or 0, total
end

local function bestTarget()
    local floorValue = acceptanceFloor()
    local best = nil
    for _, b in ipairs(worldBrainrots()) do
        if not b.held
           and b.stage >= CONFIG.minStage and b.stage <= CONFIG.maxStage
           and b.cps > floorValue then
            if (not best) or b.cps > best.cps then best = b end
        end
    end
    return best, floorValue
end

-- ---------------------------------------------------------------- inventory
local function inventoryEntries()
    local bb = Data and Data:FindFirstChild("BrainrotsBackpack")
    if not bb then return {} end
    local out = {}
    for _, c in ipairs(bb:GetChildren()) do
        local function val(k, d)
            local v = c:FindFirstChild(k)
            return v and v.Value or d
        end
        out[#out + 1] = {
            key   = c.Name,
            name  = val("BrainrotName", "?"),
            cps   = tonumber(val("CashPerSecond", 0)) or 0,
            level = tonumber(val("Level", 1)) or 1,
        }
    end
    return out
end

local function heldTool()
    local ch = character()
    if not ch then return nil end
    return ch:FindFirstChildOfClass("Tool")
end

-- A brainrot pulled back off a stand only lands in the inventory; the Tool is
-- created in the Backpack but nothing equips it, and the place remote does
-- nothing while the hands are empty.
local function equipKey(key)
    local hum = humanoid()
    if not hum then return false end
    local held = heldTool()
    if held and held.Name == key then return true end
    local tool = plr.Backpack:FindFirstChild(key)
    if not tool then return false end
    local ok = pcall(function() hum:EquipTool(tool) end)
    if not ok then return false end
    task.wait(0.4)
    return heldTool() ~= nil
end

-- ------------------------------------------------------------------ actions
local function collectAll()
    local before = money()
    for i = 1, 24 do
        pcall(function() Remotes.CollectStandCash:FireServer(tostring(i)) end)
    end
    task.wait(0.6)
    local gained = money() - before
    if gained > 0 then STATE.collected = STATE.collected + gained end
    return gained
end

-- Confirm the sale by the inventory entry disappearing, never by the balance
-- moving: at 150B/s the income between two reads dwarfs anything a spare
-- brainrot is worth, so a money delta says nothing at all.
local function sellKey(key)
    local bb = Data and Data:FindFirstChild("BrainrotsBackpack")
    if bb and not bb:FindFirstChild(key) then return false end
    pcall(function() Remotes.SellBrainrot:FireServer(key) end)
    task.wait(0.5)
    local gone = not (bb and bb:FindFirstChild(key))
    if gone then STATE.sold = STATE.sold + 1 end
    return gone
end

-- Seat whatever is currently held. Returns the stand name on success.
local function placeHeld()
    local tool = heldTool()
    if not tool then return nil end
    local free, used = census()

    if #free > 0 then
        local n = free[1]
        local model = standModel(n)
        if not model then return nil end
        Remotes.PlaceBrainrotOnStand:FireServer(model, tool.Name)
        task.wait(1.2)
        if standEntry(n) then
            STATE.placed = STATE.placed + 1
            return tostring(n)
        end
        return nil
    end

    if not CONFIG.autoSwap then return nil end

    -- The Tool carries no CashPerSecond attribute, so the base value comes from
    -- the inventory entry the Tool is named after.
    local incoming = 0
    for _, e in ipairs(inventoryEntries()) do
        if e.key == tool.Name then incoming = rank(e) end
    end

    local worst = worstOf(used)
    if not (worst and incoming > rank(worst)) then return nil end

    -- THE SERVER WILL NOT HAND A BRAINROT BACK WHILE YOUR HANDS ARE FULL. Firing
    -- GrabBrainrotFromStand with the incoming one equipped answers nothing and
    -- leaves the stand occupied - which reads exactly like "the swap remote does
    -- not work" and left eight brainrots piling up in the inventory while a
    -- $2.76K Cappuccino held a stand. Unequip, pull, re-equip, place.
    local model = standModel(worst.stand)
    if not model then return nil end
    local wanted = tool.Name

    local hum = humanoid()
    if hum then pcall(function() hum:UnequipTools() end) end
    task.wait(0.4)

    Remotes.GrabBrainrotFromStand:FireServer(model)
    task.wait(1.2)
    if standEntry(worst.stand) then
        note("swap refused on stand " .. worst.stand)
        equipKey(wanted)
        return nil
    end

    if not equipKey(wanted) then
        note("lost the tool during the swap")
        return nil
    end
    Remotes.PlaceBrainrotOnStand:FireServer(model, wanted)
    task.wait(1.2)
    if standEntry(worst.stand) then
        STATE.placed  = STATE.placed + 1
        STATE.swapped = STATE.swapped + 1
        if CONFIG.autoSell then sellKey(worst.key) end
        return worst.stand
    end
    return nil
end

-- Anything in the inventory that no stand would take is dead weight; the game
-- pays for it and the carry loop needs the slot free.
local function sellSurplus()
    local free, used = census()
    if #free > 0 then return 0 end
    local worst = worstOf(used)
    if not worst then return 0 end
    local n = 0
    for _, e in ipairs(inventoryEntries()) do
        if rank(e) <= rank(worst) then
            if sellKey(e.key) then n = n + 1 end
        end
    end
    return n
end

-- Seat whatever is sitting in the inventory but not on a stand. This is the
-- recovery path after a crash mid-cycle, and it is also how the very first
-- delivery gets seated when the panel is switched on with a full backpack.
local function placeInventory()
    local seated = 0
    for _ = 1, 24 do
        local free, used = census()
        local entries = inventoryEntries()
        if #entries == 0 then break end

        local best = nil
        for _, e in ipairs(entries) do
            if (not best) or rank(e) > best.inc then best = { e = e, inc = rank(e) } end
        end
        if not best then break end

        -- Bailing out on a full plot is what silently stopped the swap. The
        -- whole point of a full plot is that the inventory should be pushing
        -- the weakest stand off it: three brainrots worth 232M, 174M and 134M
        -- sat unplaced while a $2.76K Cappuccino held a stand, because this
        -- loop returned before placeHeld() ever got the chance to swap.
        if #free == 0 then
            if not CONFIG.autoSwap then break end
            local worst = worstOf(used)
            if not (worst and best.inc > rank(worst)) then break end
        end

        if not equipKey(best.e.key) then break end
        if not placeHeld() then break end
        seated = seated + 1
    end
    return seated
end

-- ------------------------------------------------------------- the carry run
local function grab(target)
    local model = target.model
    if not model or not model.Parent then return false end

    -- GetPivot works on a parts-less model, so the flight can be planned from
    -- the plot even though nothing of the brainrot is loaded yet.
    local pos = model:GetPivot().Position
    flyTo(pos + Vector3.new(0, 2, 0))
    STATE.pinTarget = pos + Vector3.new(0, 2, 0)

    local prompt = grabPrompt(model, CONFIG.streamWait)
    if not prompt then
        STATE.pinTarget = nil
        return false
    end

    task.wait(CONFIG.grabHold)
    pcall(function() fireproximityprompt(prompt, 1) end)
    task.wait(CONFIG.grabWait)
    STATE.pinTarget = nil

    return plr:GetAttribute("Carrying") == true
end

-- The delivery is a server-side check against the plot, and the plot has to
-- have streamed back in before it can fire. Landing once and waiting a fixed
-- 2.5s was not enough: one miss left the brainrot glued to the character,
-- Carrying stayed true, the next cycle flew out still holding it and every
-- grab from then on failed because you cannot carry two. So wait for the
-- attribute to actually clear, and shuffle around the spawn while waiting in
-- case the landing point sits just outside the trigger.
local function carryHome()
    local h = homeAnchor()
    if not h then return false end
    flyTo(h)
    -- Landing near the lobby spawn pulls the plot back into streaming range;
    -- once it is loaded the real home coordinate is known and we finish there.
    for _ = 1, 15 do
        local real = homePos()
        if real then
            if (real - h).Magnitude > 25 then flyTo(real) end
            h = real
            break
        end
        task.wait(0.3)
    end

    -- NEVER pin here. The delivery is a Touched on the plot, and the shared
    -- Heartbeat pin rewrites the CFrame every frame with zero velocity, so the
    -- character hovers at the pin point and never actually lands on anything.
    -- Pinned deliveries failed every time and dropped the brainrot; warping to
    -- a fresh point and letting it fall the last studs delivers immediately.
    STATE.pinTarget = nil

    local deadline = os.clock() + CONFIG.deliverTimeout
    local i = 0
    while plr:GetAttribute("Carrying") == true do
        if _G.__LOGOBR ~= GEN then return false end
        if os.clock() >= deadline then break end
        i = i + 1
        local base = homePos() or h
        warp(base + Vector3.new(math.cos(i) * 6, 0, math.sin(i) * 6))
        task.wait(0.6)
    end

    -- The tool is created a moment after Carrying clears.
    for _ = 1, 15 do
        if heldTool() then break end
        task.wait(0.2)
    end
    return plr:GetAttribute("Carrying") ~= true and heldTool() ~= nil
end

-- Last resort when the plot simply will not take it: give the brainrot back
-- rather than fly the rest of the session with it welded on.
local function dropCarried()
    pcall(function() Remotes.DropBrainrot:FireServer() end)
    task.wait(1)
    return plr:GetAttribute("Carrying") ~= true
end

local function farmCycle()
    if STATE.farmBusy then return end
    STATE.farmBusy = true

    local ok, err = pcall(function()
        -- Never fly out with something still on our back. Carrying two is
        -- impossible, so one failed delivery would otherwise poison every
        -- cycle that follows it.
        if plr:GetAttribute("Carrying") == true then
            STATE.phase = "re-delivering"
            if not carryHome() then
                STATE.stuckDeliveries = STATE.stuckDeliveries + 1
                if STATE.stuckDeliveries >= CONFIG.dropAfter then
                    if dropCarried() then
                        STATE.stuckDeliveries = 0
                        note("delivery kept failing - dropped the brainrot")
                    end
                else
                    note(("still carrying after %ds, retry %d/%d"):format(
                        CONFIG.deliverTimeout, STATE.stuckDeliveries, CONFIG.dropAfter))
                end
                return
            end
            STATE.stuckDeliveries = 0
        end

        -- Never decide anything about the plot from the far stages.
        if not atHome() then
            STATE.phase = "returning"
            local h = homeAnchor()
            if h then flyTo(h) end
            task.wait(0.5)
        end

        homePos()
        STATE.phase = "seating"
        if CONFIG.autoPlace then placeInventory() end
        if CONFIG.autoSell then sellSurplus() end

        STATE.phase = "choosing"
        local target, floorValue = bestTarget()
        if not target then
            STATE.target = "-"
            note(("nothing in the world beats %s/s"):format(fmt(floorValue)))
            task.wait(2)
            return
        end
        STATE.target = ("%s %s $%s/s (stage %s)"):format(
            target.mutation, target.name, fmt(target.cps), tostring(target.stage))

        STATE.phase = "flying out"
        -- A grab misses for two reasons that look identical from here: another
        -- player took it while we were in the air, or the character respawned
        -- mid-flight and the warp went nowhere. Both are fixed by picking the
        -- target again rather than by giving up on the cycle.
        local got = grab(target)
        if not got then
            STATE.failedGrabs = STATE.failedGrabs + 1
            local retry = bestTarget()
            if retry then
                target = retry
                STATE.target = ("%s %s $%s/s (stage %s)"):format(
                    target.mutation, target.name, fmt(target.cps), tostring(target.stage))
                got = grab(target)
            end
        end
        if not got then
            note("grab failed on " .. target.name)
            return
        end
        STATE.carried     = STATE.carried + 1
        STATE.lastGrab    = target.mutation .. " " .. target.name
        STATE.lastGrabCps = target.cps

        STATE.phase = "flying home"
        if not carryHome() then
            STATE.stuckDeliveries = STATE.stuckDeliveries + 1
            note("delivery did not clear Carrying - retrying next cycle")
            return
        end
        STATE.stuckDeliveries = 0

        STATE.phase = "placing"
        if CONFIG.autoPlace then
            local stand = placeHeld()
            if stand then
                note(("seated %s on stand %s"):format(target.name, stand))
            else
                -- Nothing on the plot is worse than what we just carried home,
                -- so it is dead weight. Sell it on the spot instead of letting
                -- the inventory grow - only the best belong on the stands.
                note("nothing on the plot is worse than " .. target.name)
                if CONFIG.autoSell then
                    local held = heldTool()
                    if held then sellKey(held.Name) end
                end
            end
        end
    end)

    STATE.farmBusy = false
    STATE.phase = "idle"
    if not ok then note("farm cycle failed: " .. tostring(err)) end
end

-- ------------------------------------------------------------ level upgrades
-- Rank every placed brainrot by payback, not by price. The cheapest level is
-- never the right one: price grows 1.17 per level while income only grows
-- 1.0807, so a low level on a big earner beats a high level on a small one by
-- orders of magnitude.
local function levelCandidates()
    local _, used = census()
    local out = {}
    for _, e in ipairs(used) do
        local price = levelPrice(e.cps, e.level)
        local gain  = (levelIncome(e.cps, e.level + 1) - e.income) * moneyMultiplier()
        if gain > 0 and e.level < MAX_LEVEL then
            out[#out + 1] = {
                stand   = e.stand,
                name    = e.name,
                level   = e.level,
                price   = price,
                gain    = gain,
                payback = price / gain,
            }
        end
    end
    -- Payback is price/gain, and both terms scale with the brainrot's own cps,
    -- so every brainrot sitting at the same level has the SAME payback. Sorting
    -- on payback alone therefore picks an arbitrary one and happily drove a
    -- $799/s Cappuccino to level 24 while a 37B/s Talpa waited. The level is
    -- the real ranking, and at equal level the bigger earner turns the same
    -- money into more income per second.
    table.sort(out, function(a, b)
        if math.abs(a.payback - b.payback) > 1e-6 then return a.payback < b.payback end
        return a.gain > b.gain
    end)
    return out
end

local function upgradeLevels(budget, maxCount)
    budget   = budget or money()
    maxCount = maxCount or CONFIG.levelsPerPass
    local bought = 0
    for _ = 1, maxCount do
        local list = levelCandidates()
        local pick = list[1]
        if not pick then break end
        if pick.payback > CONFIG.maxPayback then break end
        -- Re-read the balance immediately before every purchase; a collect pass
        -- or a level bought a moment ago makes a cached figure a lie.
        local cash = money()
        if pick.price > math.min(cash, budget) then break end
        local before = cash
        pcall(function() Remotes.UpgradeBrainrot:FireServer(pick.stand) end)
        task.wait(0.35)
        if money() >= before then break end   -- refused, do not spin on it
        budget = budget - pick.price
        bought = bought + 1
        STATE.levels = STATE.levels + 1
    end
    return bought
end

-- ------------------------------------------------------------ base upgrade
-- The "Upgrade Base" screen on the plot. It reads "15 >> 16 / 100.0T $" and
-- each level is one more stand, so StandsUnlocked = 8 + base level. The price
-- comes from Modules.unlock_stands rather than the label, because the label is
-- abbreviated and a hand-written suffix table is how these get misread.
local function baseUpgrade()
    local plot = myPlot()
    local up = plot and plot:FindFirstChild("Upgrader")
    local screen = up and up:FindFirstChild("Screen")
    if not screen then return nil end
    local cd = screen:FindFirstChildOfClass("ClickDetector")
    if not cd then return nil end

    local nextLevel
    local gui = screen:FindFirstChildOfClass("SurfaceGui")
    local buy = gui and gui:FindFirstChild("Buy")
    local levels = buy and buy:FindFirstChild("Levels")
    if levels then
        local _, b = tostring(levels.Text):match("(%d+)%s*>>%s*(%d+)")
        nextLevel = tonumber(b)
    end
    nextLevel = nextLevel or (unlocked() - 8 + 1)

    local price = UnlockStands and tonumber(UnlockStands[nextLevel])
    if not price then return nil end
    return { detector = cd, part = screen, nextLevel = nextLevel, price = price }
end

-- What one more stand is worth: it ends up holding at least what the weakest
-- seat holds, because anything better than that is what the carry loop brings
-- home next.
local function baseUpgradePayback()
    local info = baseUpgrade()
    if not (info and info.price > 0) then return nil end
    local _, used = census()
    local worst = worstOf(used)
    local gain = (worst and rank(worst) or 0) * moneyMultiplier()
    if gain <= 0 then return nil, info end
    return info.price / gain, info
end

local function tryBaseUpgrade()
    local payback, info = baseUpgradePayback()
    if not info then return false end
    if money() < info.price then return false end
    -- The ClickDetector is 32 studs, so this is the one purchase that has to
    -- happen at the plot.
    if not atHome() then return false end
    if type(fireclickdetector) ~= "function" then return false end

    local before = unlocked()
    pcall(function() fireclickdetector(info.detector) end)
    task.wait(1.5)
    if unlocked() > before then
        STATE.baseUpgrades = STATE.baseUpgrades + 1
        note(("base level %d bought for %s - %d stands, payback %s"):format(
            info.nextLevel, fmt(info.price), unlocked(),
            payback and (("%.0fs"):format(payback)) or "?"))
        return true
    end
    return false
end

-- ----------------------------------------------------------------- rebirth
local function rebirthCost()
    if RebirthsMgr and RebirthsMgr.getRebirthCost then
        local ok, v = pcall(RebirthsMgr.getRebirthCost, rebirths() + 1)
        if ok and v then return v end
    end
    return math.huge
end

-- Rebirth wipes the balance, so everything that can be turned into income has
-- to be bought first. Buying afterwards is buying with nothing.
local function tryRebirth()
    local cost = rebirthCost()
    if cost == math.huge then return false end
    if money() < cost then return false end

    collectAll()
    if money() < cost then return false end

    -- A rebirth is cheap and wipes the balance; a base level is expensive and
    -- permanent. So a reachable base level always goes first, or the cheap
    -- early rebirths quietly reset the savings every twenty seconds and the
    -- plot never gets wider. This cannot stall: unlock_stands ends at level 16
    -- and rebirth costs only climb x5 a tier.
    if CONFIG.autoBase then
        local _, info = baseUpgradePayback()
        if info and info.price and money() < info.price
           and info.price <= money() + perSecond() * CONFIG.reserveWindow then
            note(("saving %s for base level %d before rebirthing"):format(
                fmt(info.price), info.nextLevel))
            return false
        end
    end

    -- The rebirth wipes the balance, so anything permanent has to be bought
    -- first. The base upgrade outlives the reset; the money does not.
    local keep = math.floor(money() * CONFIG.rebirthKeep)
    if CONFIG.autoBase then
        for _ = 1, 3 do
            if not tryBaseUpgrade() then break end
        end
    end
    upgradeLevels(math.max(0, money() - math.max(cost, keep)), 40)

    if money() < cost then return false end
    local before = rebirths()
    pcall(function() Remotes.Rebirth:FireServer() end)
    task.wait(2.5)
    if rebirths() > before then
        STATE.rebirths = STATE.rebirths + 1
        note(("rebirth %d -> %d, money multiplier %sx"):format(before, rebirths(), moneyMultiplier()))
        return true
    end
    return false
end

-- ------------------------------------------------------------------ speed
local function speedCost()
    if SpeedMgr and SpeedMgr.getSingleSpeedCost then
        local ok, v = pcall(SpeedMgr.getSingleSpeedCost, dataNum("MaxSpeed", 18))
        if ok and v then return v end
    end
    return math.huge
end

local function buySpeed(n)
    n = n or 1
    local before = dataNum("MaxSpeed", 18)
    pcall(function() Remotes.BuySpeed:FireServer(n) end)
    task.wait(0.6)
    return dataNum("MaxSpeed", 18) > before
end

-- --------------------------------------------------------------- freebies
local function claimOffline()
    pcall(function() Remotes.ClaimOfflineMoney:FireServer() end)
end

local function claimQuests()
    if Data and Data:FindFirstChild("JobSahurClaimed") and Data.JobSahurClaimed.Value == false then
        pcall(function() Remotes.ClaimJobSahur:FireServer() end)
    end
    local q = Data and Data:FindFirstChild("RebirthOnceQuestNotClaimed")
    if q and q.Value == true and rebirths() > 0 then
        pcall(function() Remotes.RebirthOnceQuest:FireServer() end)
    end
end

-- ------------------------------------------------------------- loop driver
local function loop(period, key, fn)
    task.spawn(function()
        while _G.__LOGOBR == GEN do
            if CONFIG[key] and STATE.running then
                local ok, err = pcall(fn)
                if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
            end
            task.wait(period)
        end
    end)
end

loop(0.5, "autoFarm", farmCycle)
loop(CONFIG.collectEvery, "autoCollect", function() collectAll() end)

loop(CONFIG.spendEvery, "autoLevels", function()
    local budget = money()

    -- Levels stop at 100, and then the base upgrade is the only sink left. Hold
    -- its price back so the level pass cannot starve it - but only while it is
    -- actually reachable, because reserving for an unaffordable wall is what
    -- froze the balance in Sell Ores and Power Blast.
    -- Ranking it against a level payback would mean never buying it at all: a
    -- level pays back in seconds and a stand in days. But levels are capped at
    -- 100 and every swap resets one to 1, so a payback race against them never
    -- ends - and the plot would stay the width it started at. Reachability is
    -- the only gate: if income closes the gap inside the window, hold the price
    -- back; if it does not, it is a wall and must not freeze the balance.
    if CONFIG.autoBase then
        local _, info = baseUpgradePayback()
        if info and info.price then
            if info.price <= money() + perSecond() * CONFIG.reserveWindow then
                budget = math.max(0, money() - info.price)
            end
        end
    end

    upgradeLevels(budget, CONFIG.levelsPerPass)
end)

loop(8, "autoBase", function() tryBaseUpgrade() end)

loop(20, "autoRebirth", function() tryRebirth() end)
loop(15, "autoSpeed", function()
    if money() > speedCost() * 20 then buySpeed(1) end
end)
loop(90, "autoOffline", claimOffline)
loop(45, "autoQuests", claimQuests)

-- Keep the cached home coordinate fresh whenever the plot is loaded.
task.spawn(function()
    while _G.__LOGOBR == GEN do
        pcall(homePos)
        task.wait(5)
    end
end)

-- ------------------------------------------------------------------ panel
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

-- A run that errored early stores no handle, so sweep the named ScreenGui too.
if _G.__LOGOBR_WIN then pcall(function() _G.__LOGOBR_WIN:Destroy() end) end
for _, parent in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui"), plr:FindFirstChild("PlayerGui") }) do
    pcall(function()
        for _, g in ipairs(parent:GetChildren()) do
            if g.Name == "LOGOBR_PANEL" then g:Destroy() end
        end
    end)
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("logobrainrots", CONFIG)

local win = UI.Window({
    title = "LOGO", accentTitle = "BRAINROTS", subtitle = "seltonmt",
    badge = "*", width = 920, height = 580, name = "LOGOBR_PANEL",
})
_G.__LOGOBR_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local cFarm = farm:Card("CARRY LOOP", 1):Accent()
cFarm:Toggle("Auto farm", CONFIG.autoFarm, function(v)
    CONFIG.autoFarm = v
    STATE.running = v or STATE.running
end, "fly out, grab the richest brainrot, fly home at cruise altitude, seat it")

cFarm:Toggle("Auto place", CONFIG.autoPlace, function(v) CONFIG.autoPlace = v end,
    "seat what was delivered")
cFarm:Toggle("Swap out the weakest", CONFIG.autoSwap, function(v) CONFIG.autoSwap = v end,
    "on a full plot, pull the worst stand when something better arrives", UI.theme.good)
cFarm:Toggle("Sell leftovers", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
    "inventory entries no stand would take")

cFarm:Slider("Lowest stage", 1, 10, CONFIG.minStage, function(v) CONFIG.minStage = math.floor(v) end)
cFarm:Slider("Highest stage", 1, 10, CONFIG.maxStage, function(v) CONFIG.maxStage = math.floor(v) end)
cFarm:Slider("Cruise altitude", 120, 500, CONFIG.cruiseY, function(v) CONFIG.cruiseY = math.floor(v) end)

local cPlot = farm:Card("PLOT", 2)
cPlot:Toggle("Auto collect", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
    "CollectStandCash on all 24 stands, works at any distance", UI.theme.good)
cPlot:Slider("Collect every (s)", 2, 30, CONFIG.collectEvery, function(v) CONFIG.collectEvery = math.floor(v) end)
cPlot:Button("Collect now", function()
    task.spawn(function() note("collected " .. fmt(collectAll())) end)
end)
cPlot:Button("Seat inventory now", function()
    task.spawn(function() note("seated " .. placeInventory()) end)
end)
cPlot:Button("Fly home", function()
    task.spawn(function()
        local h = homeAnchor()
        if h then flyTo(h) end
    end)
end)

local spend = win:Page("SPEND", UI.icon.coin)

local cLevels = spend:Card("LEVELS", 1):Accent()
cLevels:Toggle("Level brainrots", CONFIG.autoLevels, function(v) CONFIG.autoLevels = v end,
    "price cps/5 * 1.17^(L-1), payback 1.65s at level 1 - the strongest sink", UI.theme.good)
cLevels:Slider("Levels per pass", 1, 40, CONFIG.levelsPerPass, function(v) CONFIG.levelsPerPass = math.floor(v) end)
cLevels:Slider("Max payback (s)", 30, 3600, CONFIG.maxPayback, function(v) CONFIG.maxPayback = math.floor(v) end)
cLevels:Button("Level now", function()
    task.spawn(function() note("bought " .. upgradeLevels(money(), 25) .. " levels") end)
end)

local cBase = spend:Card("BASE", 0)
cBase:Toggle("Upgrade base", CONFIG.autoBase, function(v) CONFIG.autoBase = v end,
    "one more stand per level, priced from unlock_stands - the sink after level 100",
    UI.theme.good)
cBase:Slider("Reserve window (s)", 60, 1800, CONFIG.reserveWindow,
    function(v) CONFIG.reserveWindow = math.floor(v) end)
cBase:Button("Upgrade base now", function() task.spawn(tryBaseUpgrade) end)

local cReb = spend:Card("REBIRTH", 2)
cReb:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "wipes the balance, keeps every brainrot; x1.5 -> x2 -> x2.5 money", UI.theme.warn)
cReb:Toggle("Buy speed", CONFIG.autoSpeed, function(v) CONFIG.autoSpeed = v end,
    "pointless while the route is flown")
cReb:Button("Rebirth now", function() task.spawn(tryRebirth) end, UI.theme.warn)

local cFree = spend:Card("FREE", 0)
cFree:Toggle("Offline money", CONFIG.autoOffline, function(v) CONFIG.autoOffline = v end)
cFree:Toggle("Quests", CONFIG.autoQuests, function(v) CONFIG.autoQuests = v end,
    "Job Job Job Sahur and the one-rebirth quest")

-- Readout lives on a card, never on a page.
local cStatus = farm:Card("STATUS", 0)
local out = cStatus:Readout(11)

task.spawn(function()
    while _G.__LOGOBR == GEN do
        local free, used, total = census()
        local worst, best = worstOf(used), nil
        for _, e in ipairs(used) do
            if (not best) or rank(e) > rank(best) then best = e end
        end

        win:SetStatus(("%s$   %s/s   stands %d/%d   R%d (%sx)"):format(
            fmt(money()), fmt(perSecond()), #used, total, rebirths(), moneyMultiplier()))
        pcall(function()
            win:SetStat(1, fmt(money()), "money")
            win:SetStat(2, fmt(perSecond()), "per second")
            win:SetStat(3, tostring(rebirths()), "rebirths")
        end)

        local nextLevel = levelCandidates()[1]
        local cost = rebirthCost()

        out:set({
            "FARM",
            ("  phase %s   carried %d   placed %d   swapped %d   failed %d"):format(
                STATE.phase, STATE.carried, STATE.placed, STATE.swapped, STATE.failedGrabs),
            "  target " .. tostring(STATE.target),
            ("  last %s ($%s/s)"):format(STATE.lastGrab, fmt(STATE.lastGrabCps)),
            "PLOT",
            ("  %d of %d stands used   inventory %d   sold %d"):format(
                #used, total, #inventoryEntries(), STATE.sold),
            ("  best %s base $%s/s   weakest %s base $%s/s (now $%s/s)"):format(
                best and best.name or "-", best and fmt(rank(best)) or "0",
                worst and worst.name or "-", worst and fmt(rank(worst)) or "0",
                worst and fmt(worst.income) or "0"),
            "ECONOMY",
            ("  collected %s   levels bought %d"):format(fmt(STATE.collected), STATE.levels),
            (nextLevel
                and ("  next level: stand %s %s L%d for %s, payback %.1fs"):format(
                    nextLevel.stand, nextLevel.name, nextLevel.level,
                    fmt(nextLevel.price), nextLevel.payback)
                or  "  next level: -"),
            ("  rebirth %d costs %s (%s)   done %d"):format(
                rebirths() + 1, cost < math.huge and fmt(cost) or "?",
                (cost < math.huge and money() >= cost) and "affordable" or "not yet",
                STATE.rebirths),
            (function()
                local pb, info = baseUpgradePayback()
                if not info then return "  base upgrade: -" end
                return ("  base level %d for %s, payback %s   bought %d"):format(
                    info.nextLevel, fmt(info.price),
                    pb and (("%.0fs"):format(pb)) or "?", STATE.baseUpgrades)
            end)(),
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
_G.__LOGOBR_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    farmCycle = farmCycle, grab = grab, carryHome = carryHome, dropCarried = dropCarried,
    flyTo = flyTo, warp = warp, homePos = homePos, atHome = atHome,
    worldBrainrots = worldBrainrots, bestTarget = bestTarget,
    census = census, standEntry = standEntry, standModel = standModel,
    weakestStand = weakestStand, acceptanceFloor = acceptanceFloor,
    rank = rank, worstOf = worstOf,
    placeHeld = placeHeld, placeInventory = placeInventory,
    inventoryEntries = inventoryEntries, equipKey = equipKey, heldTool = heldTool,
    collectAll = collectAll, sellKey = sellKey, sellSurplus = sellSurplus,
    levelCandidates = levelCandidates, upgradeLevels = upgradeLevels,
    levelIncome = levelIncome, levelPrice = levelPrice,
    tryRebirth = tryRebirth, rebirthCost = rebirthCost,
    baseUpgrade = baseUpgrade, baseUpgradePayback = baseUpgradePayback,
    tryBaseUpgrade = tryBaseUpgrade, MAX_LEVEL = MAX_LEVEL,
    buySpeed = buySpeed, speedCost = speedCost,
    claimOffline = claimOffline, claimQuests = claimQuests,
    money = money, perSecond = perSecond, rebirths = rebirths, fmt = fmt,
}

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
pcall(function() win:Home() end)

print("[logobrainrots] loaded - gen " .. GEN .. ", RightShift for the panel")
