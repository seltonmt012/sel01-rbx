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
    * **The item shop is a second economy and it was missed entirely.**
      `Configs.ItemShop` holds 8 sprinklers / fertilizers / watering cans /
      coffees, 2 to 3 of them in stock per 300s restock, bought with
      `InvokeServer("Purchase", "<Item Name>")` - verified 2026-08-27, the
      balance moved exactly the config price and the stock fell by one.  They
      land as Tools in the Backpack (`type`, `ItemName`, `Id`) and are placed
      with the SAME `Place` call as a gnome, the type in front:
      `Place("Sprinkler", "Basic Sprinkler", CFrame, "1")`.  All of them except
      the cans are timed area buffs, 120-300s over 11-25 studs, so they belong
      at the centre of the crops and not on the clear edge a gnome gets.
    * **Pets are NOT rolled on the podium** - an earlier guess in this file
      said they probably were, and it was wrong.  They walk around the middle
      of the map as `WorldPet_<Name>` under `workspace.PetSpawns.Pets`, 120 to
      600 studs from the garden, and carry a server-side `BuyPetPrompt`
      (12 studs, no line of sight).  Price is flat per species out of
      `Configs.Pets`; the `RolledRarity` on the model only decides the 1/N
      shown overhead.  They despawn after a few minutes.

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
local CfgShop     = requireIdent(Configs:WaitForChild("ItemShop", 20))
local CfgPets     = requireIdent(Configs:WaitForChild("Pets", 20))
local CfgSprink   = requireIdent(Configs:WaitForChild("Sprinklers", 20))
local CfgFert     = requireIdent(Configs:WaitForChild("Fertilizer", 20))

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
    autoPets      = true,   -- same again for pets, capped by max_equipped_pets
    autoUpgrade   = true,   -- the hex tree, cheapest useful node first
    autoExpand    = true,   -- ExpandPlot when it is comfortably affordable
    autoFreeGnome = true,   -- the free gnome timer
    autoRebirth   = false,  -- UNVERIFIED, see rebirthOnce()

    autoGear      = true,   -- buy the item shop's restock
    autoGearUse   = true,   -- and put it to work: place, give or water
    autoBuyPets   = true,   -- fetch a pet out of the field, see buyWorldPet()

    collectGap    = 0.06,   -- 25/25 credited at 0.05, this leaves headroom
    collectBatch  = 40,     -- per pass, so the loop stays responsive
    sellAt        = 0.85,   -- sell once the inventory is this full
    placeClear    = 3.0,    -- studs a placement spot keeps from anything else
    placeTries    = 6,      -- spots attempted per gnome per pass
    buyMargin     = 1.0,    -- buy when income/s beats the weakest placed x this
    expandKeep    = 3.0,    -- only expand while cash stays >= price * this
    reserveWindow = 90,     -- seconds of income a reserved gnome may be away

    gearMode      = "Sprinklers + fertilizer",  -- which shop types, see GEAR_MODES
    gearKeep      = 3.0,    -- only buy gear while cash stays >= price * this
    petRarity     = "Common",      -- lowest pet rarity worth walking over for
    petKeep       = 2.0,    -- only buy a pet while cash stays >= price * this
}

local STATE = {
    money = 0, rebirths = 0, phase = "starting", note = "",
    collected = 0, sold = 0, earned = 0, lastSale = 0,
    rolls = 0, bought = 0, placed = 0, upgrades = 0, expansions = 0,
    gnomes = 0, invUsed = 0, invMax = 0, ready = 0, growing = 0,
    rollLuck = 1, bestGnome = "-", weakest = "-", target = "-",
    placeFails = 0, plotFull = false, gnomeCap = 0, swaps = 0,
    rate = 0, reserve = 0, observed = 0,
    pets = 0, petsPlaced = 0, petCap = 3,
    gearBought = 0, gearUsed = 0, gearLive = 0, lastGear = "-", restock = 0,
    petsBought = 0, petsOwned = 0, petSeen = 0, petBest = "-", petReserve = 0, petSwaps = 0,
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

-- One inventory holds the lot: crops, gnomes, pets and everything bought out of
-- the item shop, each entry tagged with its own `type` ("Plant" / "Farmer" /
-- "Pet" / "Sprinkler" / "Fertilizer" / "GnomeItem" / "WateringCan").  The two
-- extra return values are appended, so the older callers that take one or two
-- of them are untouched.
local function inventoryCounts()
    local plants, farmers, total, pets, gear = 0, 0, 0, 0, 0
    for _, item in pairs(inventory()) do
        total = total + 1
        if type(item) == "table" then
            local kind = item.type
            if kind == "Farmer" then farmers = farmers + 1
            elseif kind == "Plant" then plants = plants + 1
            elseif kind == "Pet" then pets = pets + 1
            elseif kind then gear = gear + 1 end
        end
    end
    return plants, farmers, total, pets, gear
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

-- Is anything standing on the podium still worth having?
--
-- This exists because rolling only when the podium is EMPTY deadlocks the whole
-- ladder, and it did: the podium grew to five slots, one Roll filled all five,
-- the script bought the four that beat its weakest gnome and left a 6.00/s
-- Carrot Gnome standing. The preview was then never empty again, so it never
-- rolled again - one worthless gnome froze the ladder while the garden held
-- five Corn Gnomes at 11/s and a 195/s gnome was affordable.
--
-- The price is deliberately NOT part of this test. A gnome worth buying but not
-- affordable yet must not be rolled away - that is exactly what gnomeReserve()
-- is holding the money for.
local function podiumWorthKeeping()
    local _, worstRate = weakestPlaced()
    local haveRoom = not gardenFull()
    for _, model in ipairs(previewModels()) do
        if haveRoom or gnomeRate(model.Name) > worstRate * CONFIG.buyMargin then
            return true
        end
    end
    return false
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

    -- Confirming a purchase by the balance dropping does NOT work here: the
    -- garden pays several hundred a second into the same number, so a $10
    -- gnome is invisible in it.  The honest signals are the inventory growing
    -- by a farmer and the podium model going away.
    local _, farmersBefore = inventoryCounts()
    fire("BuyFarmer", bestModel)
    task.wait(1.0)
    local _, farmersAfter = inventoryCounts()
    if farmersAfter > farmersBefore or bestModel.Parent == nil then
        STATE.bought = STATE.bought + 1
        STATE.bestGnome = bestName
        note("bought %s ($%s, %.2f/s)", bestName, tostring(gnomePrice(bestName)), bestRate)
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
-- pets
--
-- Pets follow the SAME rule as the gnomes: the Tool has to be in the hand.
-- The client asks the server first with `CanPlacePet(tool)` and only fires
-- `PlacePet(tool, cframe)` when that comes back true, which is worth copying -
-- it turns a silent refusal into an answer.  Three may stand at once
-- (`max_equipped_pets`), they sit in `Plot.ClientPets`, and `PickupPet(uid)`
-- takes one back.
--
-- Where pets come from was guesswork here for a long time and the guess was
-- WRONG: it is not the podium and it has nothing to do with `IsDay`.  Pets
-- walk around the middle of the map and are bought where they stand - see
-- buyWorldPet() further down.
----------------------------------------------------------------------------

-- The rarity ladder out of the game's own config, and the one every pet
-- decision is ranked on: which one to walk over for, which of the ones already
-- owned comes off the plot when a better one turns up.
local PET_TIERS = {
    Common = 1, Uncommon = 2, Rare = 3, Epic = 4,
    Legendary = 5, Mythic = 6, Godly = 7, IMPOSSIBLE = 8,
}
local PET_CHOICES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" }

local function petTier(name)
    local cfg = CfgPets[name]
    return (type(cfg) == "table" and PET_TIERS[cfg.rarity]) or 0
end

local function petPrice(name)
    local cfg = CfgPets[name]
    return (type(cfg) == "table" and tonumber(cfg.price)) or math.huge
end

local function maxPets()
    return tonumber(data().max_equipped_pets) or 3
end

local function placedPets()
    local folder = folderOf("ClientPets")
    if not folder then return 0 end
    local n = 0
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("Model") then n = n + 1 end
    end
    return n
end

-- Rarest first, so a Frog waiting in the backpack is offered a slot before a
-- second Dog is.
local function heldPetTools()
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not backpack then return {} end
    local tools = {}
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") and tool:GetAttribute("type") == "Pet" then
            tools[#tools + 1] = tool
        end
    end
    table.sort(tools, function(a, b)
        return petTier(a:GetAttribute("PetName") or a.Name)
             > petTier(b:GetAttribute("PetName") or b.Name)
    end)
    return tools
end

-- `Data.pets` holds ONLY the equipped ones: a PickupPet removes the entry
-- outright and the pet comes back as a Tool in the backpack, which is where
-- the loose ones are counted from instead.  Measured - equipped went 3 -> 2
-- and the entry vanished rather than flipping a flag.
local function weakestPlacedPet()
    local worstUid, worstName, worstTier
    for uid, entry in pairs(data().pets or {}) do
        if type(entry) == "table" and entry.name then
            local tier = petTier(entry.name)
            if not worstTier or tier < worstTier then
                worstUid, worstName, worstTier = uid, entry.name, tier
            end
        end
    end
    return worstUid, worstName, worstTier or 0
end

-- Once the garden holds its three, this turns into the same swap the gnomes
-- do: the weakest one standing is picked back up and the better one takes its
-- place.  Without it three Dogs bought in the first minute would lock the
-- slots for ever and a Frog could never get in - which is most of what "auto
-- buy RARE pets" has to mean.
local function placePets()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return 0 end

    local tools = heldPetTools()
    if #tools == 0 then return 0 end

    local seated = 0
    for _, tool in ipairs(tools) do
        if not alive() then break end

        if placedPets() >= maxPets() then
            local worstUid, worstName, worstTier = weakestPlacedPet()
            local mine = petTier(tool:GetAttribute("PetName") or tool.Name)
            if not worstUid or mine <= worstTier then break end
            fire("PickupPet", worstUid)
            task.wait(1.0)
            if placedPets() >= maxPets() then
                note("pet swap: the %s would not come off the plot", tostring(worstName))
                break
            end
            STATE.petSwaps = STATE.petSwaps + 1
            note("swapping the %s out for a %s", tostring(worstName),
                tostring(tool:GetAttribute("PetName") or tool.Name))
        end

        humanoid:EquipTool(tool)
        task.wait(0.35)
        -- The tool has to be in the character before the server will even
        -- answer the question, which is why the equip comes first.
        local allowed = invoke("CanPlacePet", 6, tool)
        if not allowed then
            note("pet %s: server says it cannot be placed", tool.Name)
            break
        end

        local spots = placementSpots(CONFIG.placeTries)
        local placedOne = false
        for _, spot in ipairs(spots) do
            local before = placedPets()
            fire("PlacePet", tool, CFrame.new(spot))
            task.wait(0.8)
            if placedPets() > before then
                placedOne = true
                seated = seated + 1
                STATE.petsPlaced = STATE.petsPlaced + 1
                note("placed pet %s", tool.Name)
                break
            end
        end
        if not placedOne then break end
    end

    pcall(function() humanoid:UnequipTools() end)
    return seated
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

-- Declared here and defined down with the pets: the tree, the shop and the
-- expansions must not spend a pet's money, and all three of them are written
-- above the pet code.
local petReserve

-- What the OTHER spenders are allowed to touch.  The two holders spend past
-- their own reserve (buyFromPodium works off money(), buyWorldPet off money()
-- minus the gnome reserve), exactly as buyFromPodium always has.
local function spendable()
    return money() - gnomeReserve() - (petReserve and petReserve() or 0)
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

    local result = invoke("Upgrade", 8, bestBranch, bestKey)
    task.wait(0.5)
    -- The tree writes the node into upgrade_tree, which is a fact; the balance
    -- is not, because income lands in it at the same time.
    if ownedNodes()[bestKey] then
        STATE.upgrades = STATE.upgrades + 1
        note("upgrade %s ($%s)", bestNode.Name or bestKey, tostring(bestPrice))
        return true
    end
    if result == "Not Enough" or result == "Maxed" or result == "Invalid" then
        note("upgrade %s: %s", bestKey, tostring(result))
    end
    return false
end

----------------------------------------------------------------------------
-- the item shop ("gear")
--
-- Measured 2026-08-27 on notpolpne: `InvokeServer("Purchase", "<Item Name>")`
-- answered `true`, the balance went 2,788 -> 788 (exactly the config price of
-- the Basic Sprinkler), `timedShop.stock["Basic Sprinkler"]` fell 1 -> 0 and a
-- Tool carrying `type = "Sprinkler"`, `ItemName` and `Id` appeared in the
-- Backpack.  So the shop is bought like anything else in this game and the
-- item lands in the same inventory as the gnomes.
--
-- The shop restocks every 300s (`Settings.RestockDuration`) with 2 to 3 of its
-- 8 entries; `ReplicatedStorage:GetAttribute("RestockSecondsLeft")` counts it
-- down.  Everything in it except the watering cans is a TIMED AREA BUFF - 120
-- to 300 seconds over 11 to 25 studs - which is why a purchase is followed
-- immediately by a placement, and why the placement goes in the MIDDLE of the
-- crops rather than on the tidy clear square a gnome gets.  A sprinkler
-- dropped where placementSpots() puts a gnome covers the empty margin of the
-- plot and nothing else.
----------------------------------------------------------------------------

-- The four things the shop sells are used in three different ways and every
-- one of them was measured on 2026-08-27:
--
--   Sprinkler / Fertilizer   Place(kind, name, CFrame, "1")
--                            an area buff standing on the plot for 120-300s
--   GnomeItem (the coffee)   GiveFarmerItem(<Workers model>, <Tool>)
--                            SINGLE gnome: the target's `GnomeSpeed` went
--                            1 -> 1.5, the config multi exactly, while the
--                            thirteen other gnomes on the plot stayed at 1
--   WateringCan              WaterPlant(<Plants model>)
--                            SINGLE plant and the can is consumed:
--                            `SecondsUntilReady` fell 81 -> 57 and the can
--                            left the inventory
--
-- **These last two take INSTANCES, not the uid strings**, and that cost an
-- hour: a spy that prints its arguments with tostring() renders a Model named
-- after its uid and a Tool named "Gnome Coffee" as exactly the two strings you
-- would have guessed, so the captured payload read as `(uid, "Gnome Coffee")`
-- and the server silently ignored every replay of it.  Print typeof() beside
-- the value or the capture is a guess wearing a measurement's clothes.
--
-- All three need the Tool in the hand first, the same rule as a gnome.  The
-- watering cans are the worst buy in the shop by a distance - $17,500 for
-- about twenty seconds off one crop, once - so the default mode leaves them.
local GEAR_MODES = {
    ["Sprinklers + fertilizer"] = { Sprinkler = true, Fertilizer = true },
    ["Sprinklers only"]         = { Sprinkler = true },
    ["Everything"]              = { Sprinkler = true, Fertilizer = true, GnomeItem = true, WateringCan = true },
}

local GEAR_KINDS     = { Sprinkler = true, Fertilizer = true, GnomeItem = true, WateringCan = true }
local GEAR_PLACEABLE = { Sprinkler = true, Fertilizer = true }

local function gearWanted(kind)
    local set = GEAR_MODES[CONFIG.gearMode] or GEAR_MODES["Sprinklers + fertilizer"]
    return set[kind] == true
end

local function shopStock()
    local shop = data().timedShop
    local stock = type(shop) == "table" and shop.stock or nil
    return type(stock) == "table" and stock or {}
end

local function shopEntries()
    local items = type(CfgShop) == "table" and CfgShop.Items or nil
    return type(items) == "table" and items or {}
end

-- How many of a kind are running on the plot right now.  `sprinklers` and
-- `fertilizer` in the oracle carry a `timeRemaining`, so this is the honest
-- "is a buff live" reading rather than a counter of our own.
local function gearLive()
    local n = 0
    for _, key in ipairs({ "sprinklers", "fertilizer" }) do
        local t = data()[key]
        if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    end
    return n
end

local function placedGear(kind)
    local t = data()[kind == "Fertilizer" and "fertilizer" or "sprinklers"]
    local n = 0
    if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
    return n
end

local function buyGear()
    local stock = shopStock()
    local cash, budget = money(), spendable()
    local bestName, bestPrice = nil, math.huge

    for name, entry in pairs(shopEntries()) do
        if type(entry) == "table" and (tonumber(stock[name]) or 0) > 0 and gearWanted(entry.type) then
            local price = tonumber(entry.price)
            -- A timed buff over an empty garden is money set on fire: the
            -- Basic Sprinkler runs its 120 seconds whether or not anything is
            -- growing under it.  The watering cans have no duration, so they
            -- are exempt from the gate.
            local usable = entry.type == "WateringCan" or placedCount() >= 2
            if price and usable and price < bestPrice
                and price <= budget and cash >= price * CONFIG.gearKeep then
                bestName, bestPrice = name, price
            end
        end
    end

    if not bestName then return false end

    local before = tonumber(stock[bestName]) or 0
    local result = invoke("Purchase", 8, bestName)
    task.wait(0.6)
    -- The balance cannot confirm this - the garden pays thousands a second
    -- into the same number - so the stock falling is what counts.
    if result == true or (tonumber(shopStock()[bestName]) or 0) < before then
        STATE.gearBought = STATE.gearBought + 1
        STATE.lastGear = bestName
        note("bought %s ($%s)", bestName, tostring(bestPrice))
        return true
    end
    note("shop: %s refused (%s)", bestName, tostring(result))
    return false
end

-- Each item's own radius, out of the game's config.  11 studs for a Basic
-- Sprinkler, 25 for Good Fertilizer.
local function gearRange(kind, name)
    local cfg = kind == "Fertilizer" and CfgFert or CfgSprink
    local entry = type(cfg) == "table" and cfg[name] or nil
    return (type(entry) == "table" and tonumber(entry.range)) or 11
end

-- WHERE a buff lands decides most of its worth, and the obvious answer is the
-- wrong one.  The first version aimed at the centroid of the garden: measured
-- on a plot spanning 38 x 41 studs with sixteen things standing in it, an
-- 11 stud Basic Sprinkler dropped on the centroid covered **2 of 16** - the
-- middle of a sparse rectangle is empty by definition.  So the square is
-- chosen the same way the answer would be checked: walk the garden and take
-- the spot with the most crops and gnomes inside this item's own range.
--
-- The fallbacks after the winner are kept half a radius apart from each other
-- and from it, because the six best squares are otherwise the same cluster and
-- a retry would offer the server the spot it just refused.
local function gearSpots(range)
    local minx, maxx, minz, maxz, y = gardenBounds()
    if not minx then return {} end
    local points = occupiedPoints()

    local candidates = {}
    for x = minx, maxx, 2 do
        for z = minz, maxz, 2 do
            local covered = 0
            for _, point in ipairs(points) do
                local dx, dz = point.X - x, point.Z - z
                if dx * dx + dz * dz <= range * range then covered = covered + 1 end
            end
            candidates[#candidates + 1] = { x = x, z = z, n = covered }
        end
    end
    table.sort(candidates, function(a, b) return a.n > b.n end)

    local spacing = math.max(range * 0.5, 3)
    local out = {}
    for _, pick in ipairs(candidates) do
        local far = true
        for _, taken in ipairs(out) do
            local dx, dz = taken.X - pick.x, taken.Z - pick.z
            if math.sqrt(dx * dx + dz * dz) < spacing then far = false break end
        end
        if far then
            out[#out + 1] = Vector3.new(pick.x, y, pick.z)
            if #out >= 4 then break end
        end
    end
    return out
end

local function gearTools()
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not backpack then return {} end
    local tools = {}
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") and GEAR_KINDS[tool:GetAttribute("type")] then
            tools[#tools + 1] = tool
        end
    end
    return tools
end

-- How many of a kind are still loose in the inventory.  The coffee and the can
-- leave no trace on the plot, so this is the only thing that can confirm they
-- were consumed.
local function gearHeld(kind)
    local n = 0
    for _, item in pairs(inventory()) do
        if type(item) == "table" and item.type == kind then n = n + 1 end
    end
    return n
end

-- Sprinkler and fertilizer: the same `Place` call a gnome takes, with the
-- item's own type in front, and it was accepted on the first spot offered.
local function seatGear(kind, name, spots)
    for _, spot in ipairs(spots) do
        local before = placedGear(kind)
        fire("Place", kind, name, CFrame.new(spot), "1")
        task.wait(0.7)
        if placedGear(kind) > before then
            note("placed %s", name)
            return true
        end
    end
    return false
end

-- The coffee is single target, so it goes to the gnome that earns most and has
-- not already got one: `GnomeSpeed` reads 1 on a plain gnome and 1.5 while a
-- coffee is running, which makes "already served" readable without a counter.
local function bestCoffeeGnome()
    local folder = folderOf("Workers")
    if not folder then return nil end
    local placed = placedFarmers()
    local best, bestRate
    for _, gnome in ipairs(folder:GetChildren()) do
        local entry = placed[gnome.Name]
        local farmer = (type(entry) == "table" and entry.name) or gnome:GetAttribute("FarmerName")
        local speed = tonumber(gnome:GetAttribute("GnomeSpeed")) or 1
        if farmer and speed <= 1 then
            local rate = gnomeRate(farmer)
            if not bestRate or rate > bestRate then best, bestRate = gnome, rate end
        end
    end
    return best, bestRate
end

local function giveGnomeItem(tool, name, gnome)
    local before = gearHeld("GnomeItem")
    fire("GiveFarmerItem", gnome, tool)
    task.wait(0.8)
    if gearHeld("GnomeItem") < before then
        note("gave the %s to a gnome", name)
        return true
    end
    return false
end

-- One can, one plant, and the can is gone afterwards - so it goes on whatever
-- is furthest from being ready, where the cut is worth the most.
local function slowestPlant()
    local folder = folderOf("Plants")
    if not folder then return nil end
    local best, worst
    for _, model in ipairs(folder:GetChildren()) do
        local left = tonumber(model:GetAttribute("SecondsUntilReady"))
        if left and (not worst or left > worst) then best, worst = model, left end
    end
    return best, worst
end

local function waterOne(name, model)
    local before = gearHeld("WateringCan")
    fire("WaterPlant", model)
    task.wait(0.8)
    if gearHeld("WateringCan") < before then
        note("watered a crop with the %s", name)
        return true
    end
    return false
end

-- Same rule as the gnomes: the item has to be IN THE HAND, whichever of the
-- three things happens to it next.
--
-- The target is worked out BEFORE the tool is equipped, and an item with no
-- target is skipped rather than tried: a coffee held while every gnome already
-- has one, or a can held with nothing growing, would otherwise cost an equip
-- and a second of waiting on every single pass of the farm loop, for ever.
local function useGear()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return 0 end

    local tools = gearTools()
    if #tools == 0 then return 0 end

    local used, touched = 0, false
    for _, tool in ipairs(tools) do
        if not alive() then break end
        local kind = tool:GetAttribute("type")
        local name = tool:GetAttribute("ItemName") or tool.Name

        local spots, gnome, plant
        if GEAR_PLACEABLE[kind] then       spots = gearSpots(gearRange(kind, name))
        elseif kind == "GnomeItem" then    gnome = bestCoffeeGnome()
        elseif kind == "WateringCan" then  plant = slowestPlant()
        end

        if (spots and #spots > 0) or gnome or plant then
            touched = true
            humanoid:EquipTool(tool)
            task.wait(0.35)

            local ok
            if spots then       ok = seatGear(kind, name, spots)
            elseif gnome then   ok = giveGnomeItem(tool, name, gnome)
            elseif plant then   ok = waterOne(name, plant)
            end

            if ok then
                used = used + 1
                STATE.gearUsed = STATE.gearUsed + 1
            else
                note("gear %s: the server did not take it", name)
                break
            end
        end
    end

    if touched then pcall(function() humanoid:UnequipTools() end) end
    return used
end

----------------------------------------------------------------------------
-- pets, and where they actually come from
--
-- NOT the podium.  Measured 2026-08-27: pets walk around the middle of the map
-- as `WorldPet_<Name>` models under `workspace.PetSpawns.Pets`, 120 to 600
-- studs from the garden, each one carrying `RolledRarity` (the 1/N it rolled),
-- a `Huge` flag and a `BuyPetPrompt` ProximityPrompt on its HumanoidRootPart -
-- ActionText "Buy", 12 studs, no line of sight, 0 client connections because
-- the handler is server side.
--
-- The overhead price matches `Configs.Pets[name].price` exactly on every one
-- of them (Cat 15,000 / Dog 25,000 / Cow 65,500 / Bee 750,000), so the roll
-- decides the RARITY and never the cost.  They despawn on a timer of a few
-- minutes, which is why this is checked on every pass of the farm loop rather
-- than on the slow spending timer.
----------------------------------------------------------------------------

-- How long this one stays.  The overhead clock is the ONLY place the despawn
-- is exposed - the model carries `RolledRarity`, `Huge` and `Mutations` and
-- nothing else - and it matters, because reserving the balance for a pet that
-- vanishes in ten seconds freezes the upgrade tree for nothing.
local function petSecondsLeft(model)
    local overhead = model:FindFirstChild("Overhead")
    local label = overhead and overhead:FindFirstChild("Timer")
    local text = label and label.Text or ""
    local minutes, seconds = text:match("(%d+)m%s*(%d+)s")
    if minutes then return tonumber(minutes) * 60 + tonumber(seconds) end
    local only = text:match("(%d+)s")
    return only and tonumber(only) or nil
end

local function worldPets()
    local spawns = workspace:FindFirstChild("PetSpawns")
    local folder = spawns and spawns:FindFirstChild("Pets")
    if not folder then return {} end
    local out = {}
    for _, model in ipairs(folder:GetChildren()) do
        local name = model.Name:match("^WorldPet_(.+)$")
        if name and type(CfgPets[name]) == "table" then
            out[#out + 1] = {
                model  = model,
                name   = name,
                tier   = petTier(name),
                price  = petPrice(name),
                huge   = model:GetAttribute("Huge") == true,
                rolled = tonumber(model:GetAttribute("RolledRarity")) or 0,
                left   = petSecondsLeft(model),
            }
        end
    end
    return out
end

-- The rarity a pet in the field has to reach before it is worth the walk.
--
-- With a slot free that is just whatever the user asked for.  With all three
-- taken it becomes the weakest pet STANDING, plus one - and the weakest one
-- STANDING is the point.  Not the weakest one owned: a Common that a better
-- pet already pushed off the plot is sitting loose in the inventory and will
-- never be placed again, so letting it set the bar buys pet after pet that can
-- never get in.
local function petFloor()
    local floor = PET_TIERS[CONFIG.petRarity] or 1
    if placedPets() >= maxPets() then
        floor = math.max(floor, select(3, weakestPlacedPet()) + 1)
    end
    return floor
end

-- Placed plus loose.  Only `max_equipped_pets` of them can ever stand in the
-- garden, so buying past that is buying a decoration.
local function ownedPets()
    local _, _, _, pets = inventoryCounts()
    return pets + placedPets()
end

-- Same shape as gnomeReserve() and for the same reason: without it the tree
-- takes the balance down to nothing every six seconds and a $125,000 Frog
-- standing in the field is never affordable for a single tick.  Measured
-- 2026-08-27 - the balance hit $28,726 with a Frog in the field and was back
-- at $3,684 twenty seconds later, all of it spent on gnomes and tree nodes.
--
-- And with the same two conditions that unfroze the gnome reserve, plus one
-- this needed of its own: the pet must be worth buying, it must be REACHABLE
-- from income, and it must still be there when the money arrives.
function petReserve()
    if not CONFIG.autoBuyPets then return 0 end
    local floor = petFloor()
    local cash, perSecond = money(), income()
    local reserve = 0
    for _, pet in ipairs(worldPets()) do
        local window = math.min(CONFIG.reserveWindow, pet.left or CONFIG.reserveWindow)
        local worthIt = pet.tier >= floor and (pet.left == nil or pet.left >= 20)
        local reachable = pet.price <= cash + perSecond * window
        if worthIt and reachable and pet.price > reserve then reserve = pet.price end
    end
    return reserve
end

-- The pet is halfway across the map and the prompt only reaches 12 studs, so
-- the character is pinned on Heartbeat next to it for the moment the prompt
-- fires and put straight back afterwards.  Pinning rather than a single CFrame
-- write is what this project has had to do everywhere a prompt is involved:
-- the server validates against ITS copy of the position, and a one-shot write
-- can be replicated away before the prompt lands.
local function fetchPet(pet)
    if not fireproximityprompt then
        note("pets: this executor has no fireproximityprompt")
        return false
    end
    local root = pet.model:FindFirstChild("HumanoidRootPart")
    local prompt = root and root:FindFirstChild("BuyPetPrompt")
    if not prompt then return false end

    local character = LocalPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    local home = hrp.CFrame
    local target = CFrame.new(pet.model:GetPivot().Position + Vector3.new(0, 4, 4))
    local before = ownedPets()

    local pin
    pin = RunService.Heartbeat:Connect(function()
        -- Self-releasing.  A re-execute bumps the generation and this has to
        -- let go of the character on its own, or the next run finds the body
        -- welded to a spot on the far side of the map by a connection nothing
        -- holds a reference to any more.
        if not alive() then pin:Disconnect() return end
        local ch = LocalPlayer.Character
        local body = ch and ch:FindFirstChild("HumanoidRootPart")
        if body then body.CFrame = target end
    end)

    -- Wrapped so the pin is always released, whatever the prompt does.
    pcall(function()
        task.wait(0.8)
        fireproximityprompt(prompt)
        task.wait(1.2)
    end)
    pin:Disconnect()

    pcall(function()
        local ch = LocalPlayer.Character
        local body = ch and ch:FindFirstChild("HumanoidRootPart")
        if body then body.CFrame = home end
    end)

    if ownedPets() > before then
        STATE.petsBought = STATE.petsBought + 1
        STATE.petBest = pet.name
        note("bought pet %s (1/%s, $%s)", pet.name, tostring(pet.rolled), tostring(pet.price))
        return true
    end
    note("pet %s: not sold", pet.name)
    return false
end

local function buyWorldPet()
    local pets = worldPets()
    STATE.petSeen = #pets
    if #pets == 0 then return false end

    local floor = petFloor()
    -- Spends past its own reserve but never past the gnomes' one, the same
    -- way buyFromPodium spends past the pet reserve and not past its own.
    local cash = money()
    local budget = cash - gnomeReserve()
    local best

    for _, pet in ipairs(pets) do
        if pet.tier >= floor and pet.price <= budget and cash >= pet.price * CONFIG.petKeep then
            -- Rarest first, a Huge one ahead of a plain one of the same tier.
            if not best
                or pet.tier > best.tier
                or (pet.tier == best.tier and pet.huge and not best.huge) then
                best = pet
            end
        end
    end

    if not best then return false end
    return fetchPet(best)
end

----------------------------------------------------------------------------
-- plot expansion, free gnome, rebirth
----------------------------------------------------------------------------

-- The expansion squares are NOT the children of Plot.ExpandPlot - that holds
-- one wrapper model.  The client finds them by walking for a part called
-- `BoundaryPart` and taking its PARENT, and that parent's name ("1", "2",
-- "1_L", "4_R", ...) is the key into the Expand config.  Looking the price up
-- under the wrapper's name returns nil, which reads as "no expansion for sale"
-- and quietly skips every one of them - that is what the first version did
-- while a $250 square sat there ready to buy.
local function expansionSquares()
    local p = plot()
    local holder = p and p:FindFirstChild("ExpandPlot")
    if not holder then return {} end
    local seen, out = {}, {}
    for _, descendant in ipairs(holder:GetDescendants()) do
        if descendant.Name == "BoundaryPart" and descendant:IsA("BasePart") then
            local parent = descendant.Parent
            if parent and parent.Name ~= "Highlight" and not seen[parent] then
                seen[parent] = true
                local price = tonumber(CfgExpand[parent.Name])
                if price then out[#out + 1] = { model = parent, price = price } end
            end
        end
    end
    table.sort(out, function(a, b) return a.price < b.price end)
    return out
end

local function expansionCount()
    local owned = data().plot_expansions
    local n = 0
    if type(owned) == "table" then for _ in pairs(owned) do n = n + 1 end end
    return n
end

local function expandPlot()
    for _, square in ipairs(expansionSquares()) do
        local model, price = square.model, square.price
        if money() >= price * CONFIG.expandKeep and spendable() >= price then
            local before = expansionCount()
            fire("ExpandPlot", model)
            task.wait(1.2)
            if expansionCount() > before then
                STATE.expansions = STATE.expansions + 1
                -- More space means a bigger gnome cap, and the cap is
                -- learned rather than known, so forget it and re-measure.
                STATE.gnomeCap = 0
                STATE.plotFull = false
                STATE.placeFails = 0
                note("expanded plot: %s ($%s)", model.Name, tostring(price))
                return true
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
    STATE.pets = placedPets()
    STATE.petCap = maxPets()
    STATE.petsOwned = ownedPets()
    STATE.petReserve = petReserve()
    STATE.gearLive = gearLive()
    STATE.restock = tonumber(ReplicatedStorage:GetAttribute("RestockSecondsLeft")) or 0
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

            -- Before placing: a pet standing in the field despawns after a few
            -- minutes, so the chance to buy one has to be taken on the pass it
            -- appears on, not on the next spending tick.
            if CONFIG.autoBuyPets then
                STATE.phase = "pet hunt"
                buyWorldPet()
            end

            if CONFIG.autoPets and #heldPetTools() > 0 then
                STATE.phase = "pets"
                placePets()
            end

            if CONFIG.autoGearUse and #gearTools() > 0 then
                STATE.phase = "gear"
                useGear()
            end

            if CONFIG.autoBuy then
                STATE.phase = "buying"
                buyFromPodium()
            end

            -- Not "the podium is empty" but "the podium has nothing left worth
            -- buying" - see podiumWorthKeeping().
            if CONFIG.autoRoll and not podiumWorthKeeping() then
                STATE.phase = "rolling"
                rollOnce()
            end

            task.wait(0.3)
        end
    end
end)

-- Spending runs on its own timer so a slow purchase pass cannot hold up the
-- harvest.
-- The tree comes first because its nodes are permanent and the shop's are two
-- to five minutes long.
loop("spend", 6, function()
    if not CONFIG.auto then return end
    if CONFIG.autoUpgrade then buyTreeNode() end
    if CONFIG.autoGear then buyGear() end
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

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("rollgnome", CONFIG)

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
engine:Toggle("Auto place pets", CONFIG.autoPets, function(v) CONFIG.autoPets = v end,
    "seats pets the same way, up to the three the game allows")

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

-- The item shop and the pet field are their own page: both are purchases made
-- somewhere other than the garden, and the FARMING page was already full.
local shopPage = win:Page("SHOP", UI.icon and UI.icon.bag or nil)

local gear = shopPage:Card("GEAR", 1):Accent()
gear:Toggle("Auto buy gear", CONFIG.autoGear, function(v) CONFIG.autoGear = v end,
    "buys the item shop's stock, which restocks every 5 minutes")
gear:Dropdown("Gear to buy", { "Sprinklers + fertilizer", "Sprinklers only", "Everything" },
    CONFIG.gearMode, function(v) CONFIG.gearMode = v end)
gear:Toggle("Auto use gear", CONFIG.autoGearUse, function(v) CONFIG.autoGearUse = v end,
    "places sprinklers, hands the coffee to a gnome, waters with a can")
gear:Slider("Gear cash multiple", 1, 10, math.floor(CONFIG.gearKeep),
    function(v) CONFIG.gearKeep = v end,
    "only buys while the balance covers the price this many times over")

local petCard = shopPage:Card("PETS", 2)
petCard:Toggle("Auto buy pets", CONFIG.autoBuyPets, function(v) CONFIG.autoBuyPets = v end,
    "pets walk around the middle of the map and are bought where they stand")
petCard:Dropdown("Lowest rarity", PET_CHOICES, CONFIG.petRarity,
    function(v) CONFIG.petRarity = v end)
petCard:Slider("Pet cash multiple", 1, 10, math.floor(CONFIG.petKeep),
    function(v) CONFIG.petKeep = v end,
    "only buys while the balance covers the price this many times over")
petCard:Label("Anything below the chosen rarity is left standing in the field. Only three pets can be seated at once, so buying stops there.")

local shopOut = shopPage:Card("STOCK", 0):Readout(13)

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
            string.format("  phase %s   gnomes %d/%s   pets %d/%d   roll luck x%.2f",
                STATE.phase, STATE.gnomes,
                STATE.gnomeCap > 0 and tostring(STATE.gnomeCap) or "?",
                STATE.pets, STATE.petCap, STATE.rollLuck),
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

        -- The shop page shows the server's own stock table rather than a
        -- wishlist, so an item reading 0 really is sold out this restock.
        local stock = shopStock()
        local lines = {
            "ITEM SHOP",
            string.format("  restock in %ds   bought %d   used %d   live on the plot %d",
                STATE.restock, STATE.gearBought, STATE.gearUsed, STATE.gearLive),
        }
        local names = {}
        for name in pairs(shopEntries()) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local entry = shopEntries()[name]
            local have = tonumber(stock[name]) or 0
            lines[#lines + 1] = string.format("  %-20s $%-10s %s",
                name, abbreviate(entry.price), have > 0 and ("x" .. have) or "-")
        end
        lines[#lines + 1] = "PETS"
        lines[#lines + 1] = string.format("  in the field %d   placed %d/%d   owned %d   bought %d   swaps %d",
            STATE.petSeen, STATE.pets, STATE.petCap, STATE.petsOwned,
            STATE.petsBought, STATE.petSwaps)
        lines[#lines + 1] = string.format("  held back for a pet $%s", abbreviate(STATE.petReserve))
        shopOut:set(lines)
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
    expansionSquares = expansionSquares, placePets = placePets,
    heldPetTools = heldPetTools, placedPets = placedPets, maxPets = maxPets,
    plotRate = plotRate, observedRate = observedRate, income = income,
    claimFreeGnome = claimFreeGnome, rebirthOnce = rebirthOnce,
    buyGear = buyGear, useGear = useGear, gearTools = gearTools,
    seatGear = seatGear, giveGnomeItem = giveGnomeItem, waterOne = waterOne,
    gearHeld = gearHeld, bestCoffeeGnome = bestCoffeeGnome, slowestPlant = slowestPlant,
    shopStock = shopStock, shopEntries = shopEntries, gearRange = gearRange,
    gearSpots = gearSpots, placedGear = placedGear, gearLive = gearLive,
    worldPets = worldPets, buyWorldPet = buyWorldPet, fetchPet = fetchPet,
    ownedPets = ownedPets, petTier = petTier, petPrice = petPrice,
    weakestPlacedPet = weakestPlacedPet, petFloor = petFloor,
    petReserve = petReserve, petSecondsLeft = petSecondsLeft, spendable = spendable,
    gnomeRate = gnomeRate, gnomePrice = gnomePrice, weakestPlaced = weakestPlaced,
    gardenFull = gardenFull, heldGnomeTools = heldGnomeTools, seatTool = seatTool,
    placedCount = placedCount, placedFarmers = placedFarmers,
    previewModels = previewModels, census = census,
    podiumWorthKeeping = podiumWorthKeeping,
    fire = fire, invoke = invoke,
}

pcall(function() win:Home() end)

print("[rollgnome] running - RightShift toggles the panel")
