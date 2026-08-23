--[[
    rollgnome.lua - "Roll A Gnome"  (place 117539213094671, 8 Digit Bros)

    Verified against server-side values on 2026-08-23, account polpne.

    The loop the game wants: roll for a gnome, buy it off the podium, plant it
    in your garden, and it plants crops by itself forever.  Crops grow, get
    harvested into a 100-slot inventory and sold.  Cash buys the upgrade tree,
    plot expansions and rebirths.

    How this game is wired, and why the script looks the way it does:

    * **EVERY REMOTE IN THIS GAME HAS AN EMPTY NAME.**  All 44 RemoteEvents and
      27 RemoteFunctions under `ReplicatedStorage.Communication` report
      `#Name == 0`, so no name scan finds anything.  The server creates them
      named; `Library.Imported.Network` binds them by name on the client and
      then *blanks the name locally* (`remote.Name = ""`).  The only way in is
      the module itself, with the name as the first argument:
          `Net:FireServer("Place", ...)` / `Net:InvokeServer("SellAll")`.
      `require` needs `setthreadidentity(2)` first - the executor runs at 8 and
      a plain require throws "Cannot require a non-RobloxScript module".
    * **`require(ReplicatedStorage.Replication).Data` is the state oracle** and
      it is complete: stats.money, farmers (placed), inventory (loose), plants,
      upgrades, upgrade_tree, plot_expansions, max_inventory, boosts, autos.
      **The table is REPLACED, not mutated** - the server ships a fresh one on
      `UpdateFullData` - so every read goes through `data()` and nothing caches
      the inner table.  Same trap as the Training To Climb currency store.
    * **PLACING NEEDS THE GNOME EQUIPPED AS A TOOL.**  This is the one rule that
      matters and it cost nine failed attempts.  `Place` takes exactly
      `("Farmer", <FarmerName>, <CFrame>, <floorId>)`, the payload was captured
      off a real manual placement and matched byte for byte - and the server
      still refused it every time, from any distance, on any spot, including
      the exact square a gnome had been standing on one second earlier.  What
      the client does that a bare remote call does not is hold the item:
      `Humanoid:EquipTool(tool)` first, then fire, and it works instantly.
      The Tools live in the Backpack carrying `type` ("Farmer" / "Plant"),
      `FarmerName`, `Id` and `Level` as attributes.  Same shape as the Logo
      fuer Brainrots stands.
    * **Everything else is position free.**  Measured: `CollectPlant` credited
      from 49 studs, `SellAll` paid from the middle of the field with no walk to
      the shop, `BuyFarmer` charged from 26 studs, `Upgrade` works from
      anywhere.  Only `Place` needs the hand, and not the feet.
    * **No collect throttle worth the name.**  25 `CollectPlant` calls at a 0.05s
      gap credited 25 of 25 in 3.5s.  The client's own `CanCollect` attribute
      read `false` during that and the server took every one of them, so it is a
      client-side animation gate and nothing else.
    * **Rolling is FREE.**  `Roll()` costs nothing at all (money unchanged over
      a roll) and drops one gnome per podium into `Plot.RNG.Preview`, mirrored
      in `Data.rng_preview`.  Buying is what costs: `BuyFarmer(previewModel)`
      charged exactly the config price (Corn Gnome 10, Strawberry Gnome 25).
      So the podium is rolled until something worth buying shows up.
    * `SellAll()` sells **plants only** - 34 crops for $2,205 while the farmers
      in the inventory were untouched.  Gnomes have their own `SellGnome` /
      `SellAllGnomes`, which this script never calls.
    * `Upgrade(branch, node)` is the hex tree: `("Main", "LuckI")` charged $500
      and moved the player attribute `RollLuck` 1 -> 1.3.  Branches are Main,
      Gnomes, Plants, Player, Pets; every node carries `Price` and `Requires`.

    Never touched: Auto Roll is a **gamepass** (the client answers
    `prompt("Auto Roll", "gamepass")`), `RequestLuckSpin` returns a product id
    and opens a Robux window, and the Weekly Deal / gift products are all paid.

    One thing worth knowing before "optimising" anything: this game **rolls
    money back**.  `Data.economy_rollbacks` holds real entries with thresholds
    (250 billion in the one on this account), so anything that inflates the
    balance instead of producing it gets reverted by the developers later.
    Only the honest loop is automated here.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------------------
-- module access
--
-- The executor thread runs at identity 8 and every one of these modules is a
-- plain ModuleScript, so `require` throws without the identity switch.  The
-- switch is restored afterwards because leaving the thread at 2 changes how
-- later calls behave.
----------------------------------------------------------------------------

local function requireIdent(inst)
    local previous
    pcall(function() previous = getthreadidentity and getthreadidentity() or nil end)
    pcall(function() setthreadidentity(2) end)
    local ok, result = pcall(require, inst)
    pcall(function() setthreadidentity(previous or 8) end)
    if not ok then error(tostring(result), 0) end
    return result
end

local Library = ReplicatedStorage:WaitForChild("Library", 20)
local Configs = Library:WaitForChild("Configs", 20)

local Net         = requireIdent(Library:WaitForChild("Imported", 20):WaitForChild("Network", 20))
local Replication = requireIdent(ReplicatedStorage:WaitForChild("Replication", 20))

local CfgFarmers  = requireIdent(Configs:WaitForChild("Farmers", 20))
local CfgPlants   = requireIdent(Configs:WaitForChild("Plants", 20))
local CfgTree     = requireIdent(Configs:WaitForChild("Upgrade Tree", 20))
local CfgRebirths = requireIdent(Configs:WaitForChild("Rebirths", 20))
local CfgExpand   = requireIdent(Configs:WaitForChild("Expand", 20))

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    auto          = false,  -- master switch

    autoCollect   = true,   -- harvest every READY plant
    autoSell      = true,   -- SellAll once the inventory fills up
    autoRoll      = true,   -- Roll costs nothing, so keep the podium stocked
    autoBuy       = true,   -- buy a rolled gnome when it earns more than we have
    autoPlace     = true,   -- equip + Place whatever is in the inventory
    autoUpgrade   = true,   -- the hex tree, cheapest useful node first
    autoExpand    = true,   -- ExpandPlot when it is comfortably affordable
    autoFreeGnome = true,   -- the free gnome timer
    autoRebirth   = false,  -- UNVERIFIED, see rebirthOnce()

    collectGap    = 0.06,   -- 25/25 credited at 0.05, this leaves headroom
    collectBatch  = 40,     -- per pass, so the loop stays responsive
    sellAt        = 0.85,   -- sell once the inventory is this full
    placeClear    = 3.0,    -- studs a placement spot keeps from anything else
    placeTries    = 6,      -- spots attempted per gnome per pass
    buyMargin     = 1.0,    -- buy when income/s beats the weakest placed x this
    expandKeep    = 3.0,    -- only expand while cash stays >= price * this
    reserveWindow = 90,     -- seconds of income a reserved gnome may be away
}

local STATE = {
    money = 0, rebirths = 0, phase = "starting", note = "",
    collected = 0, sold = 0, earned = 0, lastSale = 0,
    rolls = 0, bought = 0, placed = 0, upgrades = 0, expansions = 0,
    gnomes = 0, invUsed = 0, invMax = 0, ready = 0, growing = 0,
    rollLuck = 1, bestGnome = "-", weakest = "-", target = "-",
    placeFails = 0, plotFull = false, gnomeCap = 0, swaps = 0,
    rate = 0, reserve = 0, observed = 0,
}

_G.__ROLLGNOME = (_G.__ROLLGNOME or 0) + 1
local GEN = _G.__ROLLGNOME
local function alive() return _G.__ROLLGNOME == GEN end

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
end

----------------------------------------------------------------------------
-- oracle helpers
--
-- Never hold on to Replication.Data: the server replaces the whole table on
-- every full update, so a cached reference silently goes stale.
----------------------------------------------------------------------------

local function data()
    local d = Replication and Replication.Data
    return type(d) == "table" and d or {}
end

local function money()
    local s = data().stats
    return (type(s) == "table" and tonumber(s.money)) or 0
end

local function rebirths()
    local s = data().stats
    return (type(s) == "table" and tonumber(s.rebirths)) or 0
end

local function inventory()
    local inv = data().inventory
    return type(inv) == "table" and inv or {}
end

local function inventoryCounts()
    local plants, farmers, total = 0, 0, 0
    for _, item in pairs(inventory()) do
        total = total + 1
        if type(item) == "table" then
            if item.type == "Farmer" then farmers = farmers + 1
            elseif item.type == "Plant" then plants = plants + 1 end
        end
    end
    return plants, farmers, total
end

local function inventoryMax()
    return tonumber(data().max_inventory) or 100
end

local function placedFarmers()
    local f = data().farmers
    return type(f) == "table" and f or {}
end

local function placedCount()
    local n = 0
    for _ in pairs(placedFarmers()) do n = n + 1 end
    return n
end

----------------------------------------------------------------------------
-- remotes
--
-- Every RemoteFunction goes out inside a task.spawn behind a wall-clock cap.
-- A RemoteFunction that never returns parks the caller for good, and in this
-- project that has taken the bridge down twice.
----------------------------------------------------------------------------

local function fire(name, ...)
    local args = table.pack(...)
    local ok, err = pcall(function() Net:FireServer(name, table.unpack(args, 1, args.n)) end)
    if not ok then note("%s: %s", name, tostring(err)) end
    return ok
end

local function invoke(name, timeout, ...)
    local args = table.pack(...)
    local done, result = false, nil
    task.spawn(function()
        local ok, res = pcall(function() return Net:InvokeServer(name, table.unpack(args, 1, args.n)) end)
        result = ok and res or nil
        if not ok then note("%s: %s", name, tostring(res)) end
        done = true
    end)
    local started = os.clock()
    while not done and os.clock() - started < (timeout or 8) do
        task.wait(0.05)
    end
    if not done then note("%s did not answer", name) end
    return result, done
end

----------------------------------------------------------------------------
-- the plot
----------------------------------------------------------------------------

local function plot()
    local holder = LocalPlayer:FindFirstChild("Plot")
    local value = holder and holder.Value
    if value and value.Parent then return value end
    return nil
end

local function folderOf(name)
    local p = plot()
    return p and p:FindFirstChild(name) or nil
end

-- Everything that already occupies ground: growing plants, ready plants and
-- the gnomes themselves.  Used both for the census and for finding a spot.
local function occupiedPoints()
    local points = {}
    for _, name in ipairs({ "Plants", "ReadyToCollect", "Workers" }) do
        local folder = folderOf(name)
        if folder then
            for _, child in ipairs(folder:GetChildren()) do
                if child:IsA("Model") then
                    local ok, pivot = pcall(function() return child:GetPivot().Position end)
                    if ok then points[#points + 1] = pivot end
                end
            end
        end
    end
    return points
end

-- The garden floor.  Note that Floor1 covers the WHOLE 50x50 slab whether or
-- not the expansions behind it are bought, so its bounding box is not the
-- usable area - the area people actually farm on is where the plants are.
local function gardenBounds()
    local points = occupiedPoints()
    if #points == 0 then
        local p = plot()
        local pivot = p and p:FindFirstChild("GardenPivot")
        if pivot and pivot:IsA("BasePart") then
            local pos = pivot.Position
            return pos.X - 8, pos.X + 8, pos.Z - 8, pos.Z + 8, 2.0999982357025146
        end
        return nil
    end
    local minx, maxx, minz, maxz = math.huge, -math.huge, math.huge, -math.huge
    local y = 2.0999982357025146
    for _, point in ipairs(points) do
        if point.X < minx then minx = point.X end
        if point.X > maxx then maxx = point.X end
        if point.Z < minz then minz = point.Z end
        if point.Z > maxz then maxz = point.Z end
    end
    return minx, maxx, minz, maxz, y
end

-- Spots ranked by "just clear enough": the very emptiest square on the slab is
-- usually outside the part of the garden that is actually unlocked, so a
-- maximum-clearance pick walks straight off the useful area.
local function placementSpots(count)
    local minx, maxx, minz, maxz, y = gardenBounds()
    if not minx then return {} end
    local points = occupiedPoints()
    local function clearance(x, z)
        local nearest = math.huge
        for _, point in ipairs(points) do
            local dx, dz = point.X - x, point.Z - z
            local d = math.sqrt(dx * dx + dz * dz)
            if d < nearest then nearest = d end
        end
        return nearest
    end
    local candidates = {}
    local step = 1
    for x = minx - 2, maxx + 2, step do
        for z = minz - 2, maxz + 2, step do
            local c = clearance(x, z)
            if c >= CONFIG.placeClear then
                candidates[#candidates + 1] = { x = x, z = z, c = c }
            end
        end
    end
    table.sort(candidates, function(a, b) return a.c < b.c end)
    local out = {}
    for i = 1, math.min(count or CONFIG.placeTries, #candidates) do
        local pick = candidates[i]
        out[#out + 1] = Vector3.new(pick.x, y, pick.z)
    end
    return out
end

----------------------------------------------------------------------------
-- valuing a gnome
--
-- A gnome plants one crop every `plant_duration` seconds and that crop sells
-- for its plant's `sell_price`, so income per second is the honest comparison
-- and it is what the buy decision ranks on.  Prices and durations both come
-- out of the game's own config; nothing here is hand-written.
----------------------------------------------------------------------------

local function plantPrice(plantName)
    local cfg = CfgPlants[plantName]
    if type(cfg) ~= "table" then return 0 end
    return tonumber(cfg.sell_price) or 0
end

local function gnomeRate(farmerName)
    local cfg = CfgFarmers[farmerName]
    if type(cfg) ~= "table" then return 0 end
    local duration = cfg.plant_duration
    local seconds
    if type(duration) == "table" then
        local lo, hi = tonumber(duration[1]), tonumber(duration[2])
        if lo and hi then seconds = (lo + hi) / 2 else seconds = lo or hi end
    else
        seconds = tonumber(duration)
    end
    if not seconds or seconds <= 0 then return 0 end
    return plantPrice(cfg.plant) / seconds
end

local function gnomePrice(farmerName)
    local cfg = CfgFarmers[farmerName]
    return (type(cfg) == "table" and tonumber(cfg.price)) or math.huge
end

-- The weakest gnome standing in the garden, which is what a candidate has to
-- beat once the plot is full.  The key of the entry is the uid PickupFarmer
-- wants, so it is returned alongside the name.
local function weakestPlaced()
    local worstName, worstRate, worstUid = nil, math.huge, nil
    for uid, entry in pairs(placedFarmers()) do
        if type(entry) == "table" and entry.name then
            local rate = gnomeRate(entry.name)
            if rate < worstRate then
                worstRate, worstName, worstUid = rate, entry.name, uid
            end
        end
    end
    if not worstName then return nil, 0, nil end
    return worstName, worstRate, worstUid
end

-- The garden holds a fixed number of gnomes and the game says so in red across
-- the whole plot: "Buy more space to place gnome. (10 MAX)".  The number is
-- not in any config the client can read, so it is LEARNED instead: the first
-- placement refused while N gnomes are standing sets the cap to N.  Buying an
-- expansion or rebirthing clears it so it is measured again rather than
-- assumed - hardcoding 10 would go stale the moment the plot grows.
local function gardenFull()
    return STATE.gnomeCap > 0 and placedCount() >= STATE.gnomeCap
end

----------------------------------------------------------------------------
-- actions
----------------------------------------------------------------------------

local function collectReady()
    local folder = folderOf("ReadyToCollect")
    if not folder then return 0 end
    local _, _, used = inventoryCounts()
    local room = inventoryMax() - used
    if room <= 0 then return 0 end

    local fired = 0
    for _, model in ipairs(folder:GetChildren()) do
        if not alive() or fired >= CONFIG.collectBatch or room <= 0 then break end
        if model:IsA("Model")
            and model:GetAttribute("READY") == true
            and model:GetAttribute("FruitReady") ~= false then
            -- Fire and forget: the reply is only the payout and the inventory
            -- is the thing that proves a collect happened.
            task.spawn(function()
                pcall(function() Net:InvokeServer("CollectPlant", model) end)
            end)
            fired = fired + 1
            room = room - 1
            task.wait(CONFIG.collectGap)
        end
    end
    if fired > 0 then STATE.collected = STATE.collected + fired end
    return fired
end

local function sellPlants()
    local plants = select(1, inventoryCounts())
    if plants <= 0 then return 0 end
    local before = money()
    local result = invoke("SellAll", 8)
    task.wait(0.4)
    local gained = money() - before
    if gained > 0 then
        STATE.sold = STATE.sold + plants
        STATE.earned = STATE.earned + gained
        STATE.lastSale = gained
    elseif result == "No Plants" then
        note("sell: nothing to sell")
    end
    return gained
end

local function previewModels()
    local p = plot()
    local rng = p and p:FindFirstChild("RNG")
    local preview = rng and rng:FindFirstChild("Preview")
    if not preview then return {} end
    local out = {}
    for _, child in ipairs(preview:GetChildren()) do
        if child:IsA("Model") then out[#out + 1] = child end
    end
    return out
end

local function rollOnce()
    invoke("Roll", 8)
    STATE.rolls = STATE.rolls + 1
    task.wait(0.6)
end

-- Buy the podium gnome when it earns more per second than the weakest one we
-- already have standing, or when the garden still has room for anything at
-- all.  Cheap gnomes are worth buying early exactly because the plot is empty.
local function buyFromPodium()
    local models = previewModels()
    if #models == 0 then return false end

    local _, worstRate = weakestPlaced()
    local haveRoom = not gardenFull()
    local bestModel, bestName, bestRate = nil, nil, -1

    for _, model in ipairs(models) do
        local name = model.Name
        local rate = gnomeRate(name)
        local price = gnomePrice(name)
        if price <= money() and rate > bestRate then
            local worthIt = haveRoom or rate > worstRate * CONFIG.buyMargin
            if worthIt then bestModel, bestName, bestRate = model, name, rate end
        end
    end

    if not bestModel then return false end

    local before = money()
    fire("BuyFarmer", bestModel)
    task.wait(1.0)
    if money() < before then
        STATE.bought = STATE.bought + 1
        STATE.bestGnome = bestName
        note("bought %s ($%d, %.2f/s)", bestName, before - money(), bestRate)
        return true
    end
    return false
end

-- The gnome Tools waiting in the backpack, best earner first.
local function heldGnomeTools()
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not backpack then return {} end
    local tools = {}
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") and tool:GetAttribute("type") == "Farmer" then
            tools[#tools + 1] = tool
        end
    end
    table.sort(tools, function(a, b)
        return gnomeRate(a:GetAttribute("FarmerName") or a.Name)
             > gnomeRate(b:GetAttribute("FarmerName") or b.Name)
    end)
    return tools
end

-- Seat one gnome.  THE TOOL HAS TO BE IN THE HAND - see the header.  A refusal
-- is completely silent, so success is read off the placed count and nothing
-- else.
local function seatTool(tool, humanoid)
    local name = tool:GetAttribute("FarmerName") or tool.Name
    local spots = placementSpots(CONFIG.placeTries)
    if #spots == 0 then
        note("place: no spot found")
        return false
    end

    humanoid:EquipTool(tool)
    task.wait(0.35)

    for _, spot in ipairs(spots) do
        local before = placedCount()
        fire("Place", "Farmer", name, CFrame.new(spot), "1")
        task.wait(0.8)
        if placedCount() > before then
            STATE.placed = STATE.placed + 1
            STATE.plotFull = false
            STATE.placeFails = 0
            return true
        end
    end
    return false
end

-- Placement, the one thing that needs the item in the character's hand.  Once
-- the garden is full this turns into a swap: the weakest gnome standing is
-- picked back up and the better one takes its square.  The evicted one stays
-- in the inventory rather than being sold, because SellGnome has never been
-- measured on this account.
local function placeGnomes()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return 0 end

    local tools = heldGnomeTools()
    if #tools == 0 then return 0 end

    local placed = 0
    for _, tool in ipairs(tools) do
        if not alive() then break end

        if gardenFull() then
            local worstName, worstRate, worstUid = weakestPlaced()
            local mine = gnomeRate(tool:GetAttribute("FarmerName") or tool.Name)
            if not worstUid or mine <= worstRate * CONFIG.buyMargin then
                break
            end
            fire("PickupFarmer", worstUid)
            task.wait(1.0)
            if placedCount() >= STATE.gnomeCap then
                note("swap: %s would not come off the plot", tostring(worstName))
                break
            end
            STATE.swaps = STATE.swaps + 1
            note("swapping out %s (%.2f/s) for %.2f/s", tostring(worstName), worstRate, mine)
        end

        if seatTool(tool, humanoid) then
            placed = placed + 1
        else
            STATE.placeFails = STATE.placeFails + 1
            if STATE.placeFails >= 2 then
                -- Learn the cap from the refusal instead of guessing it.
                STATE.gnomeCap = placedCount()
                STATE.plotFull = true
                note("garden is full at %d gnomes", STATE.gnomeCap)
            end
            break
        end
    end

    -- Put the hand back to empty so nothing else trips over a held gnome.
    pcall(function() humanoid:UnequipTools() end)
    return placed
end

----------------------------------------------------------------------------
-- the upgrade tree
--
-- Every node carries Price and Requires; a node is buyable when it is not
-- owned and every entry in Requires already is.  Cheapest buyable node first,
-- which is what makes the early tree unfold quickly, with the money for a
-- pending gnome purchase fenced off first.
----------------------------------------------------------------------------

local BRANCHES = { "Main", "Gnomes", "Plants", "Player", "Pets" }

local function ownedNodes()
    local owned = data().upgrade_tree
    return type(owned) == "table" and owned or {}
end

local function requirementsMet(node, owned)
    local requires = node.Requires
    if type(requires) ~= "table" then return true end
    for _, needed in pairs(requires) do
        if not owned[needed] then return false end
    end
    return true
end

-- What the garden earns per second according to the CONFIG - base sell price
-- over plant duration, summed across the gnomes standing in it.  It is only a
-- floor: measured against real sales it read 148/s while the crops actually
-- paid 367/s, because every crop carries its own `Multi` and the gnomes gain
-- levels.  So it is used as a lower bound and the observed rate wins.
local function plotRate()
    local total = 0
    for _, entry in pairs(placedFarmers()) do
        if type(entry) == "table" and entry.name then
            total = total + gnomeRate(entry.name)
        end
    end
    return total
end

-- Income as actually banked, which is the number every payback decision needs.
-- Sampled once a second from the running total of sales.
local rateSamples = {}
local function observedRate()
    return STATE.observed or 0
end

local function sampleRate()
    local now = os.clock()
    rateSamples[#rateSamples + 1] = { t = now, v = STATE.earned }
    while #rateSamples > 45 do table.remove(rateSamples, 1) end
    local first = rateSamples[1]
    if first and now - first.t >= 5 then
        STATE.observed = (STATE.earned - first.v) / (now - first.t)
    end
end

local function income()
    return math.max(plotRate(), observedRate())
end

-- What a gnome purchase currently needs held back.  One reserve, asked by every
-- other spender.
--
-- The first version reserved the most expensive gnome on the podium
-- unconditionally and that froze the upgrade tree solid - zero nodes bought
-- across two measured windows while an $18,500 gnome sat there as a permanent
-- fence.  Two conditions fix it, and they are the same two that fixed Sell
-- Ores: the target has to be worth buying at all, and it has to be REACHABLE
-- from income inside a short window rather than merely expensive.
local function gnomeReserve()
    if not CONFIG.autoBuy then return 0 end
    local _, worstRate = weakestPlaced()
    local full = gardenFull()
    local perSecond = income()
    local cash = money()
    local reserve = 0
    for _, model in ipairs(previewModels()) do
        local name = model.Name
        local price = gnomePrice(name)
        local worthIt = (not full) or gnomeRate(name) > worstRate * CONFIG.buyMargin
        local reachable = price <= cash + perSecond * CONFIG.reserveWindow
        if worthIt and reachable and price < math.huge and price > reserve then
            reserve = price
        end
    end
    return reserve
end

local function spendable()
    return money() - gnomeReserve()
end

local function buyTreeNode()
    local owned = ownedNodes()
    local budget = spendable()
    local bestBranch, bestKey, bestNode, bestPrice = nil, nil, nil, math.huge

    for _, branch in ipairs(BRANCHES) do
        local nodes = CfgTree[branch]
        if type(nodes) == "table" then
            for key, node in pairs(nodes) do
                if type(node) == "table" and not owned[key] then
                    local price = tonumber(node.Price)
                    if price and price <= budget and price < bestPrice
                        and requirementsMet(node, owned) then
                        bestBranch, bestKey, bestNode, bestPrice = branch, key, node, price
                    end
                end
            end
        end
    end

    if not bestKey then return false end

    local before = money()
    local result = invoke("Upgrade", 8, bestBranch, bestKey)
    task.wait(0.5)
    if money() < before then
        STATE.upgrades = STATE.upgrades + 1
        note("upgrade %s ($%d)", bestNode.Name or bestKey, before - money())
        return true
    end
    if result == "Not Enough" or result == "Maxed" or result == "Invalid" then
        note("upgrade %s: %s", bestKey, tostring(result))
    end
    return false
end

----------------------------------------------------------------------------
-- plot expansion, free gnome, rebirth
----------------------------------------------------------------------------

local function expandPlot()
    local p = plot()
    local holder = p and p:FindFirstChild("ExpandPlot")
    if not holder then return false end
    for _, model in ipairs(holder:GetChildren()) do
        if model:IsA("Model") then
            -- The price lives in the game's Expand config keyed by the model
            -- name; the sign itself is decoration.
            local price = tonumber(CfgExpand[model.Name])
            if price and money() >= price * CONFIG.expandKeep
                and spendable() >= price then
                local before = money()
                fire("ExpandPlot", model)
                task.wait(1.2)
                if money() < before then
                    STATE.expansions = STATE.expansions + 1
                    -- More space means a bigger gnome cap, and the cap is
                    -- learned rather than known, so forget it and re-measure.
                    STATE.gnomeCap = 0
                    STATE.plotFull = false
                    STATE.placeFails = 0
                    note("expanded plot ($%d)", before - money())
                    return true
                end
            end
        end
    end
    return false
end

local function claimFreeGnome()
    local free = data().freeGnome
    if type(free) == "table" and free.canClaim == true then
        fire("ClaimFreeGnome")
        task.wait(0.8)
        note("claimed the free gnome")
        return true
    end
    return false
end

-- UNVERIFIED.  `Rebirth()` takes no arguments and answers truthy on success,
-- but it has never been fired on this account - the first requirement is
-- $1,000,000 plus a gnome list out of Rebirths.Rebirth<n>.requirements, and a
-- rebirth is not something to test blind on somebody's save.  It stays off by
-- default and prints what it would do.
local function rebirthOnce()
    local tier = CfgRebirths["Rebirth" .. tostring(rebirths() + 1)]
    if type(tier) ~= "table" then return false end
    local requirement = tonumber(tier.requirements and tier.requirements.money) or math.huge
    if money() < requirement then return false end
    if not CONFIG.autoRebirth then
        note("rebirth is affordable ($%d) - toggle it on to run it", requirement)
        return false
    end
    local result = invoke("Rebirth", 10)
    task.wait(1.5)
    if result then
        STATE.gnomeCap = 0
        STATE.plotFull = false
        STATE.placeFails = 0
        note("rebirthed")
    end
    return result and true or false
end

----------------------------------------------------------------------------
-- census
----------------------------------------------------------------------------

local function census()
    STATE.money = money()
    STATE.rebirths = rebirths()
    STATE.rollLuck = tonumber(LocalPlayer:GetAttribute("RollLuck")) or 1
    local plants, farmers, used = inventoryCounts()
    STATE.invUsed = used
    STATE.invMax = inventoryMax()
    STATE.gnomes = placedCount()

    local ready, growing = 0, 0
    local folder = folderOf("ReadyToCollect")
    if folder then
        for _, model in ipairs(folder:GetChildren()) do
            if model:IsA("Model") and model:GetAttribute("READY") == true then
                ready = ready + 1
            end
        end
    end
    local plantFolder = folderOf("Plants")
    if plantFolder then
        for _, model in ipairs(plantFolder:GetChildren()) do
            if model:IsA("Model") then growing = growing + 1 end
        end
    end
    STATE.ready = ready
    STATE.growing = growing

    local worstName = weakestPlaced()
    STATE.weakest = worstName or "-"
    sampleRate()
    STATE.rate = plotRate()
    STATE.reserve = gnomeReserve()
    return plants, farmers
end

----------------------------------------------------------------------------
-- loops
----------------------------------------------------------------------------

local function loop(name, gap, fn)
    task.spawn(function()
        while alive() do
            local ok, err = pcall(fn)
            if not ok then note("%s: %s", name, tostring(err)) end
            task.wait(gap)
        end
    end)
end

-- The farm.  Every step runs on every pass rather than returning as soon as
-- one of them did something: harvesting always has work, and an early return
-- is what starved the spending half of the loop in Sell Ores.
task.spawn(function()
    while alive() do
        if not CONFIG.auto then
            STATE.phase = "idle"
            task.wait(1)
        else
            local plants = census()

            if CONFIG.autoCollect then
                STATE.phase = "collecting"
                collectReady()
            end

            plants = select(1, inventoryCounts())
            if CONFIG.autoSell and plants > 0 then
                local full = STATE.invUsed >= STATE.invMax * CONFIG.sellAt
                local nothingReady = STATE.ready == 0
                if full or nothingReady then
                    STATE.phase = "selling"
                    sellPlants()
                end
            end

            if CONFIG.autoPlace then
                STATE.phase = "placing"
                placeGnomes()
            end

            if CONFIG.autoBuy then
                STATE.phase = "buying"
                buyFromPodium()
            end

            if CONFIG.autoRoll and #previewModels() == 0 then
                STATE.phase = "rolling"
                rollOnce()
            end

            task.wait(0.3)
        end
    end
end)

-- Spending runs on its own timer so a slow purchase pass cannot hold up the
-- harvest.
loop("spend", 6, function()
    if not CONFIG.auto then return end
    if CONFIG.autoUpgrade then buyTreeNode() end
    if CONFIG.autoExpand then expandPlot() end
    rebirthOnce()
end)

loop("free", 30, function()
    if not CONFIG.auto then return end
    if CONFIG.autoFreeGnome then claimFreeGnome() end
end)

loop("census", 1, census)

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__ROLLGNOME_WIN then pcall(function() _G.__ROLLGNOME_WIN:Destroy() end) end
for _, gui in ipairs(game:GetService("CoreGui"):GetChildren()) do
    if gui.Name == "ROLLGNOME" then pcall(function() gui:Destroy() end) end
end

local win = UI.Window({
    title = "ROLL A", accentTitle = "GNOME", subtitle = "seltonmt",
    name = "ROLLGNOME", badge = "\240\159\143\161", width = 820, height = 582,
})
_G.__ROLLGNOME_WIN = win

local page = win:Page("FARMING", UI.icon and UI.icon.leaf or nil)

local engine = page:Card("GARDEN", 1)
engine:Toggle("Auto harvest", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
    "collects every ready crop, works from across the plot")
engine:Toggle("Auto sell", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
    "sells the crops once the inventory fills up, gnomes are never sold")
engine:Toggle("Auto place", CONFIG.autoPlace, function(v) CONFIG.autoPlace = v end,
    "equips a bought gnome and seats it in the garden")

local rng = page:Card("ROLLING", 2)
rng:Toggle("Auto roll", CONFIG.autoRoll, function(v) CONFIG.autoRoll = v end,
    "rolling itself is free, only buying costs money")
rng:Toggle("Auto buy gnome", CONFIG.autoBuy, function(v) CONFIG.autoBuy = v end,
    "buys a rolled gnome that earns more than the weakest one placed")
rng:Slider("Buy margin", 100, 300, math.floor(CONFIG.buyMargin * 100),
    function(v) CONFIG.buyMargin = v / 100 end,
    "how much better a gnome has to be before it replaces one")

local spend = page:Card("SPENDING", 1)
spend:Toggle("Auto upgrades", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
    "buys the cheapest available node of the hex tree")
spend:Toggle("Auto expand plot", CONFIG.autoExpand, function(v) CONFIG.autoExpand = v end,
    "expands the garden while the cash covers it several times over")
spend:Toggle("Auto free gnome", CONFIG.autoFreeGnome, function(v) CONFIG.autoFreeGnome = v end,
    "claims the free gnome as soon as its timer is up")
spend:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "UNVERIFIED - never tested on a real save, off on purpose", UI.theme and UI.theme.bad)

local tuning = page:Card("TUNING", 2)
tuning:Slider("Harvest gap (ms)", 40, 300, math.floor(CONFIG.collectGap * 1000),
    function(v) CONFIG.collectGap = v / 1000 end,
    "25 of 25 crops credited at 50 ms, so this is already gentle")
tuning:Slider("Sell at (% full)", 40, 100, math.floor(CONFIG.sellAt * 100),
    function(v) CONFIG.sellAt = v / 100 end)
tuning:Slider("Placement clearance", 2, 8, math.floor(CONFIG.placeClear),
    function(v) CONFIG.placeClear = v end,
    "studs a new gnome keeps from the plants around it")

local readoutCard = page:Card("STATUS", 0)
local out = readoutCard:Readout(12)

local function abbreviate(n)
    n = tonumber(n) or 0
    local units = { "", "K", "M", "B", "T", "Qd", "Qn" }
    local index = 1
    while math.abs(n) >= 1000 and index < #units do
        n = n / 1000
        index = index + 1
    end
    if index == 1 then return string.format("%d", n) end
    return string.format("%.2f%s", n, units[index])
end

task.spawn(function()
    while alive() do
        local plants, farmers = inventoryCounts()
        out:set({
            "RUN",
            string.format("  phase %s   gnomes %d/%s   roll luck x%.2f",
                STATE.phase, STATE.gnomes,
                STATE.gnomeCap > 0 and tostring(STATE.gnomeCap) or "?", STATE.rollLuck),
            string.format("  ready %d   growing %d   inventory %d / %d",
                STATE.ready, STATE.growing, STATE.invUsed, STATE.invMax),
            string.format("  crops held %d   gnomes held %d", plants, farmers),
            "ECONOMY",
            string.format("  cash $%s   earned $%s   last sale $%s",
                abbreviate(STATE.money), abbreviate(STATE.earned), abbreviate(STATE.lastSale)),
            string.format("  income $%s/s measured   $%.0f/s from config   reserved $%s",
                abbreviate(STATE.observed), STATE.rate, abbreviate(STATE.reserve)),
            string.format("  harvested %d   sold %d   rolls %d   bought %d",
                STATE.collected, STATE.sold, STATE.rolls, STATE.bought),
            string.format("  placed %d   swaps %d   upgrades %d   expansions %d   rebirths %d",
                STATE.placed, STATE.swaps, STATE.upgrades, STATE.expansions, STATE.rebirths),
            string.format("  last gnome %s   weakest placed %s",
                tostring(STATE.bestGnome), tostring(STATE.weakest)),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        pcall(function()
            win:SetStat(1, abbreviate(STATE.money), "cash")
            win:SetStat(2, tostring(STATE.gnomes), "gnomes")
            win:SetStat(3, string.format("%d/%d", STATE.invUsed, STATE.invMax), "bag")
            win:SetStatus(string.format("$%s   %d gnomes   %d ready   %s",
                abbreviate(STATE.money), STATE.gnomes, STATE.ready, STATE.phase))
        end)
        task.wait(0.5)
    end
end)

pcall(function()
    win:SetMaster(CONFIG.auto, "Auto farm running")
    win:OnMaster(function(on) CONFIG.auto = on end)
end)

_G.__ROLLGNOME_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    Net = Net, Replication = Replication,
    data = data, money = money, inventoryCounts = inventoryCounts,
    plot = plot, occupiedPoints = occupiedPoints, placementSpots = placementSpots,
    collectReady = collectReady, sellPlants = sellPlants,
    rollOnce = rollOnce, buyFromPodium = buyFromPodium, placeGnomes = placeGnomes,
    buyTreeNode = buyTreeNode, expandPlot = expandPlot,
    claimFreeGnome = claimFreeGnome, rebirthOnce = rebirthOnce,
    gnomeRate = gnomeRate, gnomePrice = gnomePrice, weakestPlaced = weakestPlaced,
    gardenFull = gardenFull, heldGnomeTools = heldGnomeTools, seatTool = seatTool,
    placedCount = placedCount, placedFarmers = placedFarmers,
    previewModels = previewModels, census = census,
    fire = fire, invoke = invoke,
}

pcall(function() win:Home() end)

print("[rollgnome] running - RightShift toggles the panel")
