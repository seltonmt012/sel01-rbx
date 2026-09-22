--[[
    aimclick.lua - "[W3] +1 Aim Per Click"  (place 70990741130622, Dxr Studio)

    Verified against server-side values on 2026-09-22, account notpolpne.

    The loop the game wants:  shoot -> Aim,  Aim is the damage that breaks a
    wall,  a broken wall drops an item,  items sell for Money,  Money buys guns
    (and a gun's Aim figure IS the per-click value),  rebirth multiplies
    everything and respawns every wall.

    Everything below was READ out of the game's own client scripts (decompile
    works on all 42 of them, there are no Actor VMs) and then MEASURED against
    the server.  Nothing here was guessed.

    * GunFire:FireServer(lookVector, true) is the whole engine.  AimClient does
      exactly this on a mouse click and nothing else; the "AimClick" RemoteEvent
      that the name suggests is referenced by no client script at all.
      THE SERVER CREDITS EXACTLY 13 CALLS A SECOND.  Measured four ways in one
      window: 10/s -> 43 of 43 credited, 15.2/s -> 12.8/s, 31.8/s -> 13/s, one
      per frame (33.75/s) -> 13/s.  Firing faster than ~13/s is pure waste, so
      clickGap sits just inside it.  A control band that fired nothing gained
      exactly 0 - nothing accrues on its own.
    * Per click = the equipped gun's Aim x rebirth x index x aura x streak x
      friends x the server boost.  Pan measured at exactly 4.0/click.  The gun
      is therefore the single biggest lever in the game: Can 1, Pan 4, Revolver
      18 ... Gun22 7.3M ... Ragnarok 2.2e15.
    * The SHOOTING ZONES multiply it, and only while the body is inside one.
      Measured in the x1.5 zone: 5.64 per click against 4.00 at the base.  The
      free ones are gated purely on the rebirth count (x1.5 at 0, x2 at 2, x4
      at 5, x6 at 7, x8 at 10, x10 at 13, x13 at 16, x16 at 20).  x20 / x35 /
      x100 / x250 / x1000 carry a GamepassId - filter on THE FIELD, never on the
      name, and never touch them.
    * WALLS: damage per tick is the current AIM BALANCE, and Aim is NOT spent -
      it kept climbing at the full base rate the whole time a wall was being
      broken.  Overkill does not cascade: a 4,460 HP wall took 3,816 and then
      644, the remaining 3,172 of the second tick was thrown away.
    * THE WALL GATE IS WRITTEN OUT IN THE CLIENT:  WallClient's own warning
      reads "Grow to <maxHp/120> Aim to break it in time!" - a wall that is not
      finished inside its window heals back to full.  So a wall is reachable
      exactly when  aim >= MaxHealth / 120,  and no damage curve has to be
      derived.  Walls are NOT a chain: standing at wall 15 broke 14, 15, 16 and
      17 while 4-13 were still standing, so the target is simply the DEEPEST
      reachable one.
    * The equipped tool breaks walls BY ITSELF.  A control window that fired no
      remote at all, with the body merely pinned next to a wall, still broke it
      and still credited aim.  GunClient (inside the Tool) runs its own Heartbeat
      loop that aims at FindZoneAt() or else NearestWallTarget(pos, 30) and calls
      the very same GunFire remote, rate limited to 1 / FireRate.
    * SO THE TWO HALVES HAVE DIFFERENT CEILINGS, and this is the thing that made
      the first build useless:  AIM is credited 13 times a second, but WALL
      DAMAGE lands at the gun's FireRate, which is 2 on every gun in the game.
      Measured on a 1.43M wall: 14 damage ticks in 8s, ~21,000 each (exactly the
      aim balance), so 1.75 hits/s.  A wall therefore takes
          maxHp / (aim * 2)  seconds,
      and the first build sat on each wall for a flat 6s, left before anything
      fell, and the wall healed back to full - which is precisely what the panel
      was reporting ("The wall healed! Grow to ... Aim").  The target has to be
      the deepest wall that falls inside a TIME budget, not the deepest one the
      /120 rule calls reachable.
    * THE WALLS DROP THEIR LOOT ON THE FLOOR, and collecting it is the entire
      economy.  Broken walls spawn Models into workspace.SpawnedItems carrying
      ItemId / SourceZoneId, each with a PromptAnchor holding a "Pick up"
      ProximityPrompt (range 10, hold 0.35).  204 of them were lying around
      untouched while the first build farmed - one single "Toilet" sold for
      84,745 against a whole balance of 220, and the deep zones carry items
      worth 700K-800K of config Value before the cash multipliers.
    * MOST OF THE FLOOR IS GHOSTS, and this cost more time than everything else
      in this file put together.  workspace.SpawnedItems held a steady 204
      models, and the great majority of them are dead client replicas the server
      no longer has - already taken by somebody else, never cleaned up locally.
      They are indistinguishable from live loot: correct ItemId, live anchor,
      working prompt, PromptTriggered fires, and the server then says nothing.
      Because the picker ranks by value it kept handing back the SAME high value
      ghost ("Rocket ship", "Fish", "Coal") forever, and so did every hand
      written probe, which is why it looked like a global account lock that a
      rejoin had cured.  It was not: right after the rejoin the nearest item
      happened to be live.  Proof, once the refused id was excluded by hand:
      three pickups in a row, bag 5 -> 8 of 9.  ONE failure therefore strikes a
      model off permanently, and a miss is never treated as a lock.
    * The hold has to clear HoldDuration by a WIDE margin.  At HoldDuration +
      0.25s the prompt fired PromptButtonHoldBegan and PromptButtonHoldEnded
      with no PromptTriggered between them - the release beat the timer - and
      that is indistinguishable from a server refusal from the outside.  The
      event trace is the only thing that separates the two, so check it before
      concluding anything about a prompt: no Triggered means the INPUT was
      wrong, Triggered with no effect means the SERVER refused.
    * fireproximityprompt DOES NOT WORK IN THIS GAME - not on the item prompts
      and not on the shop NPCs either.  The prompts are Style = Custom and the
      handler is server side, so there is no client connection to fire and the
      executor's helper lands nowhere: three techniques (plain fire, zeroed
      HoldDuration, InputHoldBegin/End) all left the item on the floor from a
      measured distance of ZERO.  What works is the REAL key:
          VirtualInputManager:SendKeyEvent(true,  Enum.KeyCode.E, false, game)
          task.wait(> HoldDuration)
          VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
      with the body pinned next to the anchor until ProximityPromptService fires
      PromptShown.  That picked the item up on the first attempt.
    * SellRequest:InvokeServer(nil) sells the whole bag and is NOT position
      gated - 170 -> 870 for one item, fired from the wall corridor.  Passing an
      item name sells that one item.  The bag is the attribute InventoryItems (a
      comma separated string) against InventorySlots.
    * BUT A FIELD SALE SILENTLY LOCKS EVERY LATER PICKUP.  The money arrives in
      full and the bag string empties, and from then on the prompt triggers,
      the server answers nothing at all, and the item stays on the floor -
      measured across five value / rarity / zone buckets and sixteen seconds of
      repeated presses at distance 0, with no message on the Notify channel.
      This is the Cut Grass bag-LOAD trap again: the carried load only clears
      at the base.  BaseReturn:FireServer() is the game's own home button, it
      flips the OutsideBase attribute to false, and the very next pickup
      succeeded.  Every sale here is therefore followed by a trip home.
    * ShopRequest:InvokeServer("buy", key) -> (true, "Purchased") and it is NOT
      a rung-by-rung ladder: the Revolver (Order 4) was bought directly with
      Order 3 still unowned.  A bought gun equips itself.
    * RequestRebirth:InvokeServer() costs Aim and Level (3,852 -> 0, level 24 ->
      1) and keeps Money, every gun, the equipped gun and the index.  It grants
      +0.5 aim multiplier and +0.2 cash multiplier per rebirth, and - measured -
      IT RESPAWNS EVERY WALL, which is what makes the farm sustainable at all.
      The gate is the level: RebirthConfig.RequiredLevel(r) = 10 * r.

    There is no anti-cheat in this game.  A string sweep for Anti / Detect /
    Kick over 5,200 live functions returned nothing of the kind - the single
    "detects hooked remotes" hit belongs to bridge.lua's own spy, not to the
    place.

    Never touched:  UpgradeSkipRequest (the Robux skip), the Sell2x product
    3708681999, every gun carrying RobuxOnly / ProductId / RequiresGodmode
    (LavaSniper, Hellbreaker, Ragnarok), every aura without a numeric Price
    (the Admin aura is gamepass-only) or carrying RequiresGodmode, the five
    gamepass shooting zones, and the AutoClick gamepass 1951862607.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

----------------------------------------------------------------------------
-- modules / remotes
----------------------------------------------------------------------------

-- Never await a require on the main thread: a module that yields would park the
-- bridge and take the whole session with it.
local function safeRequire(inst, seconds)
    if not inst then return nil end
    local done, ok, res = false, false, nil
    task.spawn(function()
        if setthreadidentity then pcall(setthreadidentity, 2) end
        ok, res = pcall(function() return require(inst) end)
        done = true
    end)
    local waited = 0
    while not done and waited < (seconds or 8) do
        task.wait(0.1)
        waited = waited + 0.1
    end
    if not done or not ok then return nil end
    return res
end

local Modules = ReplicatedStorage:WaitForChild("Modules", 10)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Modules or not Remotes then
    warn("[aimclick] this is not +1 Aim Per Click - Modules/Remotes missing")
    return
end

local GunConfig      = safeRequire(Modules:FindFirstChild("GunConfig"))
local AuraConfig     = safeRequire(Modules:FindFirstChild("AuraConfig"))
local RebirthConfig  = safeRequire(Modules:FindFirstChild("RebirthConfig"))
local UpgradesConfig = safeRequire(Modules:FindFirstChild("UpgradesConfig"))
local ItemConfig     = safeRequire(Modules:FindFirstChild("ItemConfig"))
local ShootingRanges = safeRequire(Modules:FindFirstChild("ShootingRanges"))

if not GunConfig or not RebirthConfig then
    warn("[aimclick] core configs unreadable - wrong game, or the client is still loading")
    return
end

local GunFire        = Remotes:WaitForChild("GunFire", 10)
local ShopRequest    = Remotes:WaitForChild("ShopRequest", 10)
local SellRequest    = Remotes:WaitForChild("SellRequest", 10)
local UpgradeRequest = Remotes:WaitForChild("UpgradeRequest", 10)
local AuraRequest    = Remotes:FindFirstChild("AuraRequest")
local RequestRebirth = Remotes:WaitForChild("RequestRebirth", 10)
local BaseReturn    = Remotes:FindFirstChild("BaseReturn")
local FreeRewardClaim = Remotes:FindFirstChild("FreeRewardClaim")
local OfflineClaim   = Remotes:FindFirstChild("OfflineClaim")
local WallUpdate     = Remotes:FindFirstChild("WallUpdate")

if not GunFire or not SellRequest then
    warn("[aimclick] GunFire/SellRequest missing - wrong game")
    return
end

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    auto         = true,   -- master

    autoClick    = true,   -- GunFire at the credited rate, wherever the body is
    autoCollect  = true,   -- pick the loot up off the floor; this is the economy
    autoWalls    = true,   -- break the deepest wall that falls inside the budget
    autoTrain    = true,   -- when no wall is worth it, click in the best zone
    autoSell     = true,   -- sell the bag the moment it is full
    autoGuns     = true,   -- best affordable gun; no Robux gun is ever considered
    autoAuras    = true,   -- money-priced auras only
    autoBackpack = true,   -- more bag slots = more walls per sell trip
    autoSpeed    = false,  -- walkspeed does nothing for a pinned body (off)
    autoRebirth  = true,   -- level-gated, free, and it respawns every wall
    autoRewards  = true,   -- free reward + offline earnings

    clickGap     = 0.075,  -- 13.3/s, just inside the measured server ceiling
    wallSafety   = 1.25,   -- require aim >= maxHp/120 * this before committing
    wallBudget   = 25,     -- a wall is only worth taking if it falls this fast
    collectRange = 1600,   -- how far down the corridor loot is worth fetching
    nearRange    = 160,    -- ... and how close it has to be to be TRUSTED
    minItemValue = 0,      -- ignore anything cheaper than this (0 = take all)
    sellHeadroom = 0,      -- sell once the bag has this many free slots left
    gunShare     = 1.0,    -- share of the balance a gun may cost
    auraShare    = 0.35,   -- ... an aura
    upgradeShare = 0.25,   -- ... a backpack/speed level
    harvestFirst = true,   -- do not rebirth while a reachable wall still stands
    harvestStall = 45,     -- ... unless nothing has actually fallen for this long
}

local STATE = {
    aim = 0, money = 0, level = 0, rebirth = 0,
    gun = "-", gunAim = 0, aura = "-", auraMult = 1,
    bag = 0, slots = 0, phase = "starting", note = "starting",
    wallTarget = "-", wallHp = 0, wallsAlive = 0, wallsTotal = 0,
    reach = 0, zone = "-", zoneMult = 1,
    broken = 0, sold = 0, earned = 0, gunsBought = 0, rebirthsDone = 0,
    collected = 0, lootValue = 0, onFloor = 0, wallSecs = 0,
    homeTrips = 0, pickupMisses = 0,
    uiOwner = nil,
}

_G.__AIMCLICK = (_G.__AIMCLICK or 0) + 1
local GEN = _G.__AIMCLICK

local function alive() return _G.__AIMCLICK == GEN end

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

----------------------------------------------------------------------------
-- oracles
--
-- The player ATTRIBUTES are the whole state oracle here and they are unusually
-- complete - AimExact and MoneyExact are the exact server-side numbers, not the
-- rounded leaderstats strings.
----------------------------------------------------------------------------

local function attr(name, fallback)
    local v = LocalPlayer:GetAttribute(name)
    if v == nil then return fallback end
    return v
end

local function aim()     return tonumber(attr("AimExact", 0)) or 0 end
local function money()   return tonumber(attr("MoneyExact", 0)) or 0 end

local function leaderstat(name)
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild(name)
    return v and tonumber(v.Value) or 0
end

local function level()   return leaderstat("Level") end
local function rebirth() return leaderstat("Rebirth") end

local function splitList(s)
    local out = {}
    if type(s) == "string" and s ~= "" then
        for part in s:gmatch("[^,]+") do out[#out + 1] = part end
    end
    return out
end

local function bagItems() return splitList(attr("InventoryItems", "")) end
local function bagSlots() return tonumber(attr("InventorySlots", 3)) or 3 end

-- The bag is a LOAD, not a number of items: 31 of the item ids carry a Heavy
-- attribute on their world model and fill more of it, and that flag is on the
-- spawned Model rather than in ItemConfig, so it cannot be looked up from a
-- name in the inventory string.  InventoryCount is the server's own figure, so
-- the honest gauge is whichever of the two is larger.
local function bagLoad()
    return math.max(#bagItems(), tonumber(attr("InventoryCount", 0)) or 0)
end

local function ownedGuns()
    local set = {}
    for _, name in ipairs(splitList(attr("OwnedGuns", ""))) do set[name] = true end
    return set
end

local function ownedAuras()
    local set = {}
    for _, name in ipairs(splitList(attr("OwnedAuras", ""))) do set[name] = true end
    return set
end

local function abbreviate(n)
    if type(n) ~= "number" then return tostring(n) end
    local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc",
                    "Ud", "Dd", "Td", "Qad", "Qid", "Sxd", "Spd", "Ocd", "Nod", "Vg" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do n = n / 1000 i = i + 1 end
    return string.format(i == 1 and "%.0f%s" or "%.2f%s", n, units[i])
end

-- Every unknown RemoteFunction goes through this.  A RemoteFunction with no
-- OnServerInvoke bound yields FOREVER and would park the bridge; the spawned
-- thread parks instead and the caller always comes back.
local function invoke(remote, seconds, ...)
    if not remote then return nil end
    local args = table.pack(...)
    local done, ok, a, b = false, false, nil, nil
    task.spawn(function()
        ok, a, b = pcall(function() return remote:InvokeServer(table.unpack(args, 1, args.n)) end)
        done = true
    end)
    local waited = 0
    while not done and waited < (seconds or 8) do
        task.wait(0.1)
        waited = waited + 0.1
    end
    if not done then return nil, "timeout" end
    if not ok then return nil, tostring(a) end
    return a, b
end

----------------------------------------------------------------------------
-- body control
----------------------------------------------------------------------------

local function character()
    local ch = LocalPlayer.Character
    if not ch then return nil end
    -- The character is rebuilt on a respawn and for a moment has a Humanoid and
    -- no body parts, so nothing may cache the root part.
    return ch, ch:FindFirstChild("HumanoidRootPart"), ch:FindFirstChildOfClass("Humanoid")
end

local function isAlive()
    local _, _, hum = character()
    return hum ~= nil and hum.Health > 0
end

-- One body, one pin.  Two routines pinning on the same Heartbeat cancel each
-- other out, so the pin is a single connection driven by one target.
local pinTarget = nil       -- { pos = Vector3, look = Vector3 }
local pinConn

local function setPin(pos, look)
    pinTarget = pos and { pos = pos, look = look } or nil
end

local function startPin()
    if pinConn then return end
    pinConn = RunService.Heartbeat:Connect(function()
        if not alive() then
            pinConn:Disconnect()
            pinConn = nil
            return
        end
        if not pinTarget then return end
        local _, root = character()
        if not root then return end
        if pinTarget.look then
            root.CFrame = CFrame.new(pinTarget.pos, pinTarget.look)
        else
            root.CFrame = CFrame.new(pinTarget.pos)
        end
    end)
end

-- A picked up item is itself a Tool (it carries HeldItemId and swaps the hold
-- animation in), so "equip whatever Tool is around" would put a sofa in the
-- hands instead of the gun and the wall loop inside GunClient would stop.  Only
-- a Tool WITHOUT HeldItemId is a weapon.
local function isGunTool(tool)
    return tool:IsA("Tool") and tool:GetAttribute("HeldItemId") == nil
end

local function equipGun()
    local ch, _, hum = character()
    if not ch or not hum then return nil end
    for _, tool in ipairs(ch:GetChildren()) do
        if isGunTool(tool) then return tool end
    end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not backpack then return nil end
    for _, tool in ipairs(backpack:GetChildren()) do
        if isGunTool(tool) then
            pcall(function() hum:EquipTool(tool) end)
            return tool
        end
    end
    return nil
end

----------------------------------------------------------------------------
-- walls
--
-- Tagged "Wall", carrying WallId / MaxHealth / RequiredLevel.  CanCollide is
-- the alive flag: a broken wall is left in place with collision off, so the
-- world is NOT the progress signal until you read that field.
----------------------------------------------------------------------------

local function wallIndex(w)
    local id = tostring(w:GetAttribute("WallId") or "")
    return tonumber(id:match("(%d+)$")) or 0
end

local function wallList()
    local list = {}
    for _, w in ipairs(CollectionService:GetTagged("Wall")) do
        if w:IsDescendantOf(workspace) and w:IsA("BasePart") then
            list[#list + 1] = {
                inst  = w,
                id    = tostring(w:GetAttribute("WallId") or "?"),
                n     = wallIndex(w),
                maxHp = tonumber(w:GetAttribute("MaxHealth")) or 0,
                lvl   = tonumber(w:GetAttribute("RequiredLevel")) or 1,
                standing = w.CanCollide,
            }
        end
    end
    table.sort(list, function(a, b) return a.n < b.n end)
    return list
end

-- The client says it outright: "Grow to <maxHp/120> Aim to break it in time".
-- A wall below that heals back to full, so this is the real frontier, not a
-- damage curve to be fitted.
local function aimNeededFor(wall)
    return (wall.maxHp or 0) / 120
end

local function reachableDepth()
    local balance = aim()
    return balance * 120
end

-- Walls are not a chain here - wall 15 was broken while 4-13 stood - so the
-- target is simply the deepest one the current aim can finish, which is also
-- the one dropping the best item.
-- Wall damage lands at the gun's FireRate (2 on every gun in the game), not at
-- the 13/s the aim is credited at, so the honest cost of a wall is a TIME.
-- Shared helpers go ABOVE their first caller: a local defined below the function
-- that uses it resolves to nil at runtime, and because every action here runs
-- inside a pcall that shows up as a quiet footer note rather than a crash.
local function gunFireRate()
    local key = attr("EquippedGun", "Can")
    local cfg = GunConfig.Guns[key]
    return (cfg and tonumber(cfg.FireRate)) or 2
end

local function secondsToBreak(wall)
    local dps = aim() * gunFireRate()
    if dps <= 0 then return math.huge end
    return (wall.maxHp or 0) / dps
end

-- Two gates, and the first build only had one.  The /120 rule says whether the
-- server will let the wall fall at all; the time budget says whether it falls
-- before we would have been better off somewhere else.  Without the second one
-- the cursor parks on a 2.4M wall for a minute, leaves early, and the wall
-- heals back to full - which is exactly what "you shoot it and walk on" was.
local function pickWall()
    local list = wallList()
    local aliveCount, best, bestTime = 0, nil, nil
    local budget = aim() / CONFIG.wallSafety
    for _, w in ipairs(list) do
        if w.standing then
            aliveCount = aliveCount + 1
            if w.maxHp > 0 and budget >= aimNeededFor(w) then
                local secs = secondsToBreak(w)
                if secs <= CONFIG.wallBudget then
                    -- deepest wall that still fits the budget: deeper walls drop
                    -- the better items
                    if not best or w.n > best.n then best, bestTime = w, secs end
                end
            end
        end
    end
    STATE.wallsAlive = aliveCount
    STATE.wallsTotal = #list
    return best, bestTime
end

local function standSpotFor(wall)
    local part = wall.inst
    if not part or not part.Parent then return nil end
    local pos = part.Position
    -- The corridor runs along +X and the walls face -X; twelve studs short of
    -- the slab and three below its centre is where the body was measured to
    -- register, and the wall stays inside the server's own target radius.
    return pos - Vector3.new(12, 3, 0), pos
end

----------------------------------------------------------------------------
-- loot on the floor
--
-- This is where the money is, and the first build walked straight past it.  A
-- broken wall leaves a Model in workspace.SpawnedItems with an ItemId, and
-- ItemConfig gives that id a Value which the cash multipliers are applied to on
-- the sell (a 40,000 Value Toilet paid 84,745).
----------------------------------------------------------------------------

local itemStrikes = {}      -- one refusal and a model is written off as a ghost

-- A model that appears while we are watching is GUARANTEED to be live, which is
-- the one thing a floor scan cannot tell us.  Everything already lying there
-- when the script started is a coin flip, so the fresh ones are always taken
-- first and the scan is only the fallback.
local freshQueue = {}
do
    local folder = workspace:FindFirstChild("SpawnedItems")
    if folder then
        folder.ChildAdded:Connect(function(model)
            if not alive() then return end
            if model:GetAttribute("ItemId") then
                table.insert(freshQueue, { model = model, at = os.clock() })
                if #freshQueue > 60 then table.remove(freshQueue, 1) end
            end
        end)
    end
end

local function lootOnFloor()
    local folder = workspace:FindFirstChild("SpawnedItems")
    if not folder then return {} end
    local _, root = character()
    local here = root and root.Position or Vector3.new()
    local out = {}
    for _, model in ipairs(folder:GetChildren()) do
        local id = model:GetAttribute("ItemId")
        local cfg = id and ItemConfig and ItemConfig.Items and ItemConfig.Items[id]
        local anchor = model:FindFirstChild("PromptAnchor", true)
        local prompt = anchor and anchor:FindFirstChildOfClass("ProximityPrompt")
        -- ONE strike and the model is out for good.  The floor is full of dead
        -- replicas the server no longer has - a client that has been in the
        -- place a while carries hundreds of them - and they are indistinguishable
        -- from live loot until one is actually tried.  Retrying them is what made
        -- the collector look completely broken: the ranking handed back the same
        -- high value ghost forever and nothing else ever got a turn.
        if cfg and anchor and prompt and not itemStrikes[model] then
            local value = tonumber(cfg.Value) or 0
            if value >= CONFIG.minItemValue then
                out[#out + 1] = {
                    model = model, anchor = anchor, prompt = prompt,
                    id = id, value = value, rarity = cfg.Rarity,
                    dist = (anchor.Position - here).Magnitude,
                }
            end
        end
    end
    return out
end

-- Rank on value, but not blindly: a 5% better item a thousand studs away is a
-- long walk for nothing, so distance is a mild divisor rather than a filter.
local function entryFor(model)
    local id = model:GetAttribute("ItemId")
    local cfg = id and ItemConfig and ItemConfig.Items and ItemConfig.Items[id]
    local anchor = model:FindFirstChild("PromptAnchor", true)
    local prompt = anchor and anchor:FindFirstChildOfClass("ProximityPrompt")
    if not (cfg and anchor and prompt) then return nil end
    local _, root = character()
    local here = root and root.Position or Vector3.new()
    return {
        model = model, anchor = anchor, prompt = prompt, id = id,
        value = tonumber(cfg.Value) or 0, rarity = cfg.Rarity,
        dist = (anchor.Position - here).Magnitude,
    }
end

local function bestLoot()
    local list = lootOnFloor()

    -- Anything that spawned while we were watching is certainly real, so it
    -- jumps the queue whatever it is worth - a guaranteed cheap item beats a
    -- ghost that merely claims to be worth millions.
    while #freshQueue > 0 do
        local candidate = table.remove(freshQueue, 1)
        local model = candidate.model
        if model.Parent and not itemStrikes[model] then
            local e = entryFor(model)
            if e then
                e.fresh = true
                return e, #list
            end
        end
    end

    -- The "ghosts" are overwhelmingly DISTANT models.  With StreamingEnabled the
    -- client keeps stale copies of regions it left, so an item a thousand studs
    -- away may have been taken by somebody else minutes ago and our copy never
    -- heard - while the nearby ones, in a region the server is actively
    -- replicating, are real.  A value ranking therefore reaches straight for the
    -- furthest, most expensive lie in the list and sits on it.  So: rank by
    -- value only among the items that are genuinely loaded, and treat anything
    -- further out as a travel target to be re-judged on arrival.
    local best
    for _, e in ipairs(list) do
        if e.dist <= CONFIG.nearRange then
            e.score = e.value / (1 + e.dist / 120)
            if not best or e.score > best.score then best = e end
        end
    end
    if best then return best, #list end

    local nearest
    for _, e in ipairs(list) do
        if e.dist <= CONFIG.collectRange then
            if not nearest or e.dist < nearest.dist then nearest = e end
        end
    end
    return nearest, #list
end

-- fireproximityprompt does nothing in this game (measured from zero studs, on
-- the item prompts AND on the shop NPCs).  The real key event is what the
-- server accepts.
local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)

local function pressPickupKey(prompt)
    if not VIM then return false end
    local key = prompt.KeyboardKeyCode
    if key == Enum.KeyCode.Unknown then key = Enum.KeyCode.E end
    -- The hold has to clear HoldDuration by a wide margin.  At +0.25s the
    -- prompt answered PromptButtonHoldBegan and then PromptButtonHoldEnded with
    -- NO PromptTriggered in between - the release beat the timer - and that
    -- reads exactly like a server refusal.  A full extra second is what makes
    -- PromptTriggered fire every time.
    local hold = math.max((prompt.HoldDuration or 0) + 1.0, 1.4)
    local ok = pcall(function()
        VIM:SendKeyEvent(true, key, false, game)
        task.wait(hold)
        VIM:SendKeyEvent(false, key, false, game)
    end)
    return ok
end

local PromptService = game:GetService("ProximityPromptService")

local function collectOne(entry)
    if not entry or not entry.model.Parent then return false end
    local _, root = character()
    if not root then return false end

    -- With StreamingEnabled a distant item exists as a shell with nothing in it,
    -- so ask for the region before travelling into it.
    pcall(function() LocalPlayer:RequestStreamingAround(entry.anchor.Position) end)

    -- The key is only worth anything once Roblox's own prompt system has SHOWN
    -- this prompt, and PromptShown is a TRANSITION - so the approach is made
    -- from outside the ten stud range on purpose, and then waited for.  A flat
    -- 1.4s settle was not enough and produced a silent miss every single time.
    -- The prompt captured during the scan can be a DEAD instance by the time we
    -- arrive: with StreamingEnabled the region is rebuilt around the character,
    -- so the model comes back with a fresh PromptAnchor and a fresh prompt while
    -- our reference still points at the old one.  Pressing the stale object is
    -- accepted by the client - PromptShown even fires for the new one - and the
    -- server hears nothing, which is exactly the silent refusal that cost hours
    -- here.  So the prompt is taken from the event, or re-resolved, before use.
    local shown, livePrompt = false, nil
    local conn = PromptService.PromptShown:Connect(function(p)
        if p:IsDescendantOf(entry.model) then
            shown, livePrompt = true, p
        end
    end)

    setPin(entry.anchor.Position + Vector3.new(0, 2, 0))

    -- PromptShown is NOT permission.  Pressing the moment it fires was refused
    -- every time; the identical approach with a flat settle at the anchor took
    -- the item on the first try.  The server wants the character to have stood
    -- still there for a beat, so this is a fixed wait rather than a race - the
    -- shown flag is kept only to tell a missing prompt from a slow one.
    task.wait(2.2)
    conn:Disconnect()
    if not shown then STATE.promptNeverShown = (STATE.promptNeverShown or 0) + 1 end

    if not entry.model.Parent then return true end

    local prompt = livePrompt
    if not prompt or not prompt.Parent then
        local anchor = entry.model:FindFirstChild("PromptAnchor", true)
        prompt = anchor and anchor:FindFirstChildOfClass("ProximityPrompt")
    end
    if not prompt then return false end

    local bagBefore = #bagItems()
    pressPickupKey(prompt)

    -- The InventoryItems attribute is a round trip behind the key, so the
    -- confirmation is a poll, not a snapshot.  Reading it once at 0.8s counted
    -- real pickups as failures, which then sent the farm home for a lock that
    -- was never there.
    local got, waited = false, 0
    while waited < 2.4 do
        if entry.model.Parent == nil or #bagItems() > bagBefore then got = true break end
        task.wait(0.2)
        waited = waited + 0.2
    end
    if got then
        STATE.collected = STATE.collected + 1
        STATE.lootValue = STATE.lootValue + entry.value
        note("picked up %s (%s, value %s)", tostring(entry.id), tostring(entry.rarity),
            abbreviate(entry.value))
    else
        -- Never blacklist on a single failure: the ranking would simply hand the
        -- same item back forever, and a refusal is usually a timing hiccup.
        itemStrikes[entry.model] = true
    end
    return got
end

----------------------------------------------------------------------------
-- shooting zones
--
-- Models holding a "Zone" BasePart and a "Target" Attachment, with
-- AimMultiplier / RequiredRebirth / GamepassId.  The multiplier applies ONLY
-- while the body is inside the box.
----------------------------------------------------------------------------

local zoneCache, zoneCacheAt = nil, 0

local function zoneList()
    if zoneCache and (os.clock() - zoneCacheAt) < 20 then return zoneCache end
    local out = {}
    for _, d in ipairs(workspace:GetDescendants()) do
        if d.Name == "Zone" and d:IsA("BasePart") then
            local model = d:FindFirstAncestorWhichIsA("Model")
            if model then
                local target
                for _, x in ipairs(model:GetDescendants()) do
                    if x.Name == "Target" and x:IsA("Attachment") then target = x break end
                end
                if target then
                    local pass = tonumber(model:GetAttribute("GamepassId"))
                    out[#out + 1] = {
                        model = model,
                        zone  = d,
                        targetPos = target.WorldPosition,
                        mult  = tonumber(model:GetAttribute("AimMultiplier")) or 1.5,
                        reqRebirth = tonumber(model:GetAttribute("RequiredRebirth")) or 0,
                        -- filter on the FIELD; the names carry no hint at all
                        paid  = (pass ~= nil and pass > 0),
                    }
                end
            end
        end
    end
    zoneCache, zoneCacheAt = out, os.clock()
    return out
end

local function bestZone()
    local r, best = rebirth(), nil
    for _, z in ipairs(zoneList()) do
        if not z.paid and z.reqRebirth <= r then
            if not best or z.mult > best.mult then best = z end
        end
    end
    return best
end

----------------------------------------------------------------------------
-- spending
--
-- One shared guard, asked by every spender.  The gun is the biggest multiplier
-- in the game by orders of magnitude, so it is fenced off first and everything
-- else only ever spends the surplus.
----------------------------------------------------------------------------

local function gunIsFree(cfg)
    -- A Robux gun has RobuxOnly / ProductId / RobuxPrice and often no Price at
    -- all, so a "cheapest first" sort would put it on top.  RequiresGodmode is
    -- a separate item gate the money cannot open.
    if not cfg then return false end
    if cfg.RobuxOnly or cfg.ProductId or cfg.RobuxPrice then return false end
    if cfg.RequiresGodmode then return false end
    local price = tonumber(cfg.Price)
    return price ~= nil and price > 0
end

local function equippedGunAim()
    local key = attr("EquippedGun", "Can")
    local cfg = GunConfig.Guns[key] or GunConfig.Guns.Can
    local ok, value = pcall(GunConfig.AimFor, cfg, attr("OwnedGuns", ""))
    return (ok and tonumber(value)) or (cfg and tonumber(cfg.Aim)) or 1, key
end

-- The next gun worth having: the strongest one the balance covers that beats
-- what is worn.  There is no rung-by-rung ladder here (measured - Order 4 was
-- bought with Order 3 unowned), so this is a straight best-affordable pick.
local function nextGun()
    local owned = ownedGuns()
    local wornAim = (select(1, equippedGunAim()))
    local balance = money()
    local pick = nil
    for key, cfg in pairs(GunConfig.Guns) do
        if gunIsFree(cfg) and not owned[key] then
            local gainAim = tonumber(cfg.Aim) or 0
            if gainAim > wornAim and cfg.Price <= balance * CONFIG.gunShare then
                if not pick or gainAim > pick.aim then
                    pick = { key = key, aim = gainAim, price = cfg.Price, name = cfg.DisplayName or key }
                end
            end
        end
    end
    return pick
end

-- The gun is what everything else must not starve, so the reserve is the price
-- of the cheapest gun that would still be an upgrade - not the cheapest gun,
-- and not the one already worn.
local function gunReserve()
    local owned = ownedGuns()
    local wornAim = (select(1, equippedGunAim()))
    local cheapest = nil
    for key, cfg in pairs(GunConfig.Guns) do
        if gunIsFree(cfg) and not owned[key] and (tonumber(cfg.Aim) or 0) > wornAim then
            if not cheapest or cfg.Price < cheapest then cheapest = cfg.Price end
        end
    end
    return cheapest or 0
end

local function spendable(cost)
    local balance = money()
    local reserve = gunReserve()
    -- A trivially cheap step never waits behind a reserve it could never move.
    if cost <= balance * 0.02 then return balance >= cost end
    return (balance - reserve) >= cost
end

local function buyGun()
    local pick = nextGun()
    if not pick then return false end
    local before = money()
    local ok, reply = invoke(ShopRequest, 8, "buy", pick.key)
    if ok == true then
        STATE.gunsBought = STATE.gunsBought + 1
        note("gun %s (%s aim) for %s", pick.name, abbreviate(pick.aim), abbreviate(pick.price))
        return true
    end
    if reply then note("gun %s refused: %s", pick.name, tostring(reply)) end
    return false
end

-- A bought gun equips itself, but a rejoin can land on a weaker one, and
-- re-equipping something already owned is free.
local function equipBestGun()
    local owned = ownedGuns()
    local wornAim, wornKey = equippedGunAim()
    local best, bestAim = wornKey, wornAim
    for key in pairs(owned) do
        local cfg = GunConfig.Guns[key]
        local a = cfg and tonumber(cfg.Aim) or 0
        if a > bestAim then best, bestAim = key, a end
    end
    if best and best ~= wornKey then
        invoke(ShopRequest, 8, "equip", best)
    end
end

-- Every aura carries BOTH a money Price and a RobuxPrice/ProductId - the Robux
-- side is only the other way to pay for the same item, exactly like the Speed
-- Monkey trails.  The ones with no numeric Price at all (the Admin aura) are
-- gamepass-only, and Godmode wants 80 godmode items.
local function auraIsFree(cfg)
    if not cfg then return false end
    if cfg.RequiresGodmode then return false end
    if cfg.GamepassId then return false end
    local price = tonumber(cfg.Price)
    return price ~= nil and price > 0
end

local function buyAura()
    if not AuraConfig or not AuraRequest then return false end
    local owned = ownedAuras()
    local wornKey = attr("EquippedAura", "")
    local wornMult = 1
    if wornKey ~= "" and AuraConfig.Auras[wornKey] then
        wornMult = tonumber(AuraConfig.Auras[wornKey].Multiplier) or 1
    end

    local pick = nil
    for key, cfg in pairs(AuraConfig.Auras) do
        if auraIsFree(cfg) and not owned[key] then
            local mult = tonumber(cfg.Multiplier) or 1
            if mult > wornMult and cfg.Price <= money() * CONFIG.auraShare
               and spendable(cfg.Price) then
                if not pick or mult > pick.mult then
                    pick = { key = key, mult = mult, price = cfg.Price, name = cfg.DisplayName or key }
                end
            end
        end
    end

    -- Nothing new worth buying: make sure the best one owned is actually worn.
    if not pick then
        local best, bestMult = wornKey, wornMult
        for key in pairs(owned) do
            local cfg = AuraConfig.Auras[key]
            local mult = cfg and tonumber(cfg.Multiplier) or 0
            if mult > bestMult then best, bestMult = key, mult end
        end
        if best ~= "" and best ~= wornKey then invoke(AuraRequest, 8, "equip", best) end
        return false
    end

    local ok = invoke(AuraRequest, 8, "buy", pick.key)
    if ok == true then
        note("aura %s x%s for %s", pick.name, tostring(pick.mult), abbreviate(pick.price))
        invoke(AuraRequest, 8, "equip", pick.key)
        return true
    end
    return false
end

-- Two upgrades only: Backpack (bag slots) and Speed.  Speed buys nothing at all
-- for a body that is pinned and teleported - the same trap powerclick's
-- walkSpeed was - so it is off by default and stays a switch.
local function buyUpgrade(kind)
    if not UpgradesConfig or not UpgradeRequest then return false end
    local cfg = UpgradesConfig.Upgrades and UpgradesConfig.Upgrades[kind]
    if not cfg then return false end
    local lvl = tonumber(attr("Upgrade" .. kind, 0)) or 0
    if cfg.MaxLevel and lvl >= cfg.MaxLevel then return false end
    local ok, price = pcall(UpgradesConfig.PriceFor, kind, lvl)
    price = ok and tonumber(price) or nil
    if not price then return false end
    if price > money() * CONFIG.upgradeShare then return false end
    if not spendable(price) then return false end
    local reply = invoke(UpgradeRequest, 8, kind)
    if reply then
        note("%s upgrade -> lvl %d for %s", kind, lvl + 1, abbreviate(price))
        return true
    end
    return false
end

----------------------------------------------------------------------------
-- selling
--
-- Not position gated: the whole bag sells from the wall corridor.  The bag is
-- tiny (3 slots at the start), so a full bag silently refuses further drops -
-- selling early is what keeps the walls paying.
----------------------------------------------------------------------------

-- Selling in the field pays in full and then SILENTLY BLOCKS EVERY LATER
-- PICKUP.  This cost a long hunt: after one field sale, sixteen seconds of
-- repeated key presses on an item at distance 0 did nothing, with no refusal
-- message on the Notify channel and every rarity, value and zone bucket
-- failing identically - which reads exactly like a broken pickup path.  It is
-- the Cut Grass bag-LOAD trap in another costume: the money leaves but the
-- carried load only clears at the base.  BaseReturn:FireServer() is the
-- game's own "go home" button, it flips the OutsideBase attribute, and the
-- very next pickup succeeded.  So a sale is never finished until the body has
-- been home.
local function goHome()
    if not BaseReturn then return false end
    pcall(function() BaseReturn:FireServer() end)
    task.wait(2)
    STATE.homeTrips = STATE.homeTrips + 1
    return true
end

local function sellBag(force)
    local items = bagItems()
    if #items == 0 then return false end
    if not force then
        if bagLoad() < (bagSlots() - CONFIG.sellHeadroom) then return false end
    end
    local before = money()
    local paid = invoke(SellRequest, 8, nil)
    task.wait(0.3)
    local gained = money() - before
    if type(paid) == "number" and paid > 0 then gained = paid end
    if gained > 0 then
        STATE.sold = STATE.sold + #items
        STATE.earned = STATE.earned + gained
        note("sold %d item(s) for %s", #items, abbreviate(gained))
        goHome()
        return true
    end
    return false
end

----------------------------------------------------------------------------
-- rebirth
--
-- Free of currency, gated on the level (RequiredLevel(r) = 10r), and it
-- RESPAWNS EVERY WALL - which is the reason to want it, not a side effect.  It
-- wipes the aim bar, so the reachable depth collapses for a moment and has to
-- be regrown; the bag is sold first so nothing is left behind.
----------------------------------------------------------------------------

-- Every path that abandons the rebirth has to be able to time out, or the
-- ranking hands the same reason back forever: aim keeps growing, so a deeper
-- wall keeps becoming "reachable" and the harvest guard would never release.
local lastBreakAt = os.clock()

local function rebirthReady()
    local r = rebirth()
    local ok, need = pcall(RebirthConfig.RequiredLevel, r + 1)
    if not ok or type(need) ~= "number" then return false, 0 end
    return level() >= need, need
end

local function doRebirth()
    local ready, need = rebirthReady()
    if not ready then return false end

    -- Do not throw a harvest away: while a wall the current aim can still
    -- finish is standing, breaking it is worth more than resetting the board.
    if CONFIG.harvestFirst and (os.clock() - lastBreakAt) < CONFIG.harvestStall then
        local wall = pickWall()
        if wall then return false end
    end

    sellBag(true)
    task.wait(0.3)
    local before = rebirth()
    local reply = invoke(RequestRebirth, 8)
    task.wait(1.5)
    if rebirth() > before then
        STATE.rebirthsDone = STATE.rebirthsDone + 1
        note("rebirth %d at level %d (needed %d) - walls respawned", rebirth(), level(), need)
        return true
    end
    return false
end

----------------------------------------------------------------------------
-- free rewards
----------------------------------------------------------------------------

local function claimRewards()
    if OfflineClaim and attr("WelcomeBackPending", nil) ~= nil then
        pcall(function() OfflineClaim:FireServer() end)
        note("offline earnings claimed")
    end
    if FreeRewardClaim and attr("FreeRewardClaimed", false) ~= true then
        -- This one can answer with a group requirement, which is the user's
        -- call and not the script's; a refusal is simply left alone.
        local ok = invoke(FreeRewardClaim, 8)
        if ok == true then note("free reward claimed") end
    end
end

----------------------------------------------------------------------------
-- the engine
----------------------------------------------------------------------------

local function fireOnce(look)
    local _, root = character()
    if not root then return end
    local dir = look or root.CFrame.LookVector
    pcall(function() GunFire:FireServer(dir, true) end)
end

-- gap may be a number or a function, so a slider changes the cadence of a loop
-- that is already running instead of only the next reload.
local function loop(name, gap, fn)
    task.spawn(function()
        while alive() do
            if CONFIG.auto then
                local ok, err = pcall(fn)
                -- Every action runs inside a pcall, so a nil-value slip surfaces
                -- as a quiet footer note rather than a crash.  Read those notes.
                if not ok then note("%s failed: %s", name, tostring(err)) end
            end
            task.wait(type(gap) == "function" and gap() or gap)
        end
    end)
end

-- The click.  13 credited calls a second is the entire budget, measured; the
-- gap is deliberately a hair inside it rather than firing per frame, which
-- credits exactly the same and costs frames.
loop("click", function() return CONFIG.clickGap end, function()
    if not CONFIG.autoClick then return end
    if not isAlive() then return end
    local look = nil
    if pinTarget and pinTarget.look then
        local _, root = character()
        if root then look = (pinTarget.look - root.Position).Unit end
    end
    fireOnce(look)
end)

-- Selling is cheap and the bag is tiny, so it gets its own fast timer rather
-- than riding the slow spending pass.
loop("sell", 1.5, function()
    if not CONFIG.autoSell then return end
    STATE.bag, STATE.slots = bagLoad(), bagSlots()
    sellBag(false)
end)

-- Spending, slow pass.  Gun first, always: its Aim figure is the per-click
-- value and it runs from 1 to 2.2e15 across the ladder, so nothing else comes
-- close as a multiplier.
loop("spend", 5, function()
    if CONFIG.autoGuns then
        if not buyGun() then equipBestGun() end
    end
    if CONFIG.autoBackpack then buyUpgrade("Backpack") end
    if CONFIG.autoSpeed    then buyUpgrade("Speed") end
    if CONFIG.autoAuras    then buyAura() end
end)

loop("rebirth", 4, function()
    if not CONFIG.autoRebirth then return end
    doRebirth()
end)

loop("rewards", 120, function()
    if not CONFIG.autoRewards then return end
    claimRewards()
end)

loop("stats", 0.5, function()
    STATE.aim, STATE.money = aim(), money()
    STATE.level, STATE.rebirth = level(), rebirth()
    STATE.bag, STATE.slots = bagLoad(), bagSlots()
    STATE.reach = reachableDepth()
    local gunAim, gunKey = equippedGunAim()
    STATE.gunAim = gunAim
    local cfg = GunConfig.Guns[gunKey]
    STATE.gun = (cfg and cfg.DisplayName) or gunKey or "-"
    local auraKey = attr("EquippedAura", "")
    if auraKey ~= "" and AuraConfig and AuraConfig.Auras[auraKey] then
        STATE.aura = AuraConfig.Auras[auraKey].DisplayName or auraKey
        STATE.auraMult = tonumber(AuraConfig.Auras[auraKey].Multiplier) or 1
    else
        STATE.aura, STATE.auraMult = "-", 1
    end
end)

----------------------------------------------------------------------------
-- the run: break what is reachable, otherwise grow the aim in the best zone
--
-- Two phases and never both at once, because there is one body: the zone
-- multiplier only applies inside the zone and the walls are a thousand studs
-- away from it.
----------------------------------------------------------------------------

startPin()

task.spawn(function()
    while alive() do
        if not CONFIG.auto then
            STATE.phase = "off"
            setPin(nil)
            task.wait(1)
            continue
        end

        if not isAlive() then
            -- A dead character is refused by every remote in silence, and that
            -- reads exactly like a newly discovered server gate.  Wait it out.
            STATE.phase = "dead"
            setPin(nil)
            task.wait(1)
            continue
        end

        -- The bag is what the whole trip is for, so it is emptied before
        -- anything else decides where to go.
        if CONFIG.autoSell and bagLoad() >= bagSlots() then
            STATE.phase = "selling"
            sellBag(true)
            equipGun()
            task.wait(0.2)
            continue
        end

        local loot, floorCount = nil, 0
        if CONFIG.autoCollect then loot, floorCount = bestLoot() end
        STATE.onFloor = floorCount

        local wall, wallSecs = pickWall()
        STATE.wallSecs = wallSecs or 0

        if loot then
            STATE.phase = string.format("loot %s", tostring(loot.id))
            local got = collectOne(loot)
            -- A picked up item goes into the hands, and the gun's own wall loop
            -- stops while something else is held.
            equipGun()
            if got then
                STATE.pickupMisses = 0
            else
                -- ONE refusal is already the answer, and waiting for three was
                -- a deadlock: the server refuses in complete silence both when
                -- the load is full (a Heavy item fills two of three slots, so a
                -- two item bag can be full) and when a field sale has left the
                -- load uncleared.  Both are fixed by emptying the bag and going
                -- home, so that is done at once instead of cycling targets.
                -- A miss is a ghost, not a lock: the model is struck off above
                -- and the next target is tried immediately.  Going home on a
                -- miss cost five seconds each and was the biggest stall there
                -- was, because most of the floor is ghosts.
                STATE.pickupMisses = STATE.pickupMisses + 1
                if bagLoad() >= bagSlots() then
                    sellBag(true)
                    equipGun()
                end
            end

        elseif wall and CONFIG.autoWalls then
            local spot, look = standSpotFor(wall)
            if spot then
                STATE.phase = string.format("wall %d (%.0fs)", wall.n, wallSecs or 0)
                STATE.wallTarget = wall.id
                STATE.wallHp = wall.maxHp
                setPin(spot, look)
                equipGun()
                -- Stay until it actually falls.  The dwell is the MEASURED cost
                -- of the wall plus a margin, never a flat number - leaving early
                -- lets the server heal it back to full and throws the whole
                -- visit away.
                local limit = math.min((wallSecs or 5) * 2 + 4, CONFIG.wallBudget * 3)
                local started = os.clock()
                while alive() and CONFIG.auto and CONFIG.autoWalls
                      and wall.inst.Parent and wall.inst.CanCollide
                      and (os.clock() - started) < limit do
                    task.wait(0.25)
                end
                if wall.inst.Parent and not wall.inst.CanCollide then
                    STATE.broken = STATE.broken + 1
                    lastBreakAt = os.clock()
                else
                    note("wall %d did not fall in %.0fs - healing, backing off", wall.n, limit)
                end
            else
                task.wait(0.5)
            end

        elseif CONFIG.autoTrain then
            local zone = bestZone()
            if zone then
                STATE.phase = "train x" .. tostring(zone.mult)
                STATE.zone, STATE.zoneMult = zone.model.Name, zone.mult
                -- The zone box accepts a body from three studs below to twelve
                -- above, so a spot a little over the plate is comfortably inside.
                setPin(zone.zone.Position + Vector3.new(0, 3, 0), zone.targetPos)
                equipGun()
                task.wait(2)
            else
                STATE.phase = "no zone"
                STATE.zone, STATE.zoneMult = "-", 1
                setPin(nil)
                task.wait(2)
            end
        else
            STATE.phase = "idle"
            setPin(nil)
            task.wait(1)
        end

        task.wait(0.1)
    end
    setPin(nil)
end)

----------------------------------------------------------------------------
-- debug handle
--
-- Published BEFORE the panel is built: anything that yields in the UI section
-- would otherwise mean the handle never appears and the script reads as though
-- it failed to load at all.
----------------------------------------------------------------------------

_G.__AIMCLICK_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    aim = aim, money = money, level = level, rebirth = rebirth,
    bagItems = bagItems, bagSlots = bagSlots, bagLoad = bagLoad, goHome = goHome,
    wallList = wallList, pickWall = pickWall, aimNeededFor = aimNeededFor,
    secondsToBreak = secondsToBreak, gunFireRate = gunFireRate,
    lootOnFloor = lootOnFloor, bestLoot = bestLoot, collectOne = collectOne,
    pressPickupKey = pressPickupKey, equipGun = equipGun,
    zoneList = zoneList, bestZone = bestZone,
    nextGun = nextGun, gunReserve = gunReserve, spendable = spendable,
    buyGun = buyGun, equipBestGun = equipBestGun, buyAura = buyAura,
    buyUpgrade = buyUpgrade, sellBag = sellBag,
    rebirthReady = rebirthReady, doRebirth = doRebirth,
    claimRewards = claimRewards, fireOnce = fireOnce, invoke = invoke,
    setPin = setPin,
}

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__AIMCLICK_WIN then pcall(function() _G.__AIMCLICK_WIN:Destroy() end) end
if UI.sweep then pcall(function() UI.sweep("AIMCLICK") end) end

-- Merges the saved file into CONFIG before the panel exists, so every control
-- comes up on its saved state by itself.
UI.config("aimclick", CONFIG)

local win = UI.Window({
    title = "AIM", accentTitle = "CLICK", subtitle = "seltonmt",
    name = "Selux_aimclick",
})
_G.__AIMCLICK_WIN = win

local farmPage = win:Page("FARMING", UI.icon and UI.icon.pickaxe or nil)

local engine = farmPage:Card("ENGINE", 1):Accent()
engine:Toggle("Auto click", CONFIG.autoClick, function(v) CONFIG.autoClick = v end,
    "the server credits 13 calls a second, firing faster is wasted")
engine:Toggle("Collect loot", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
    "picks the dropped items up off the floor - this is where the money is")
engine:Toggle("Break walls", CONFIG.autoWalls, function(v) CONFIG.autoWalls = v end,
    "holds the deepest wall that actually falls inside the time budget")
engine:Toggle("Train in zone", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
    "when no wall is reachable, clicks in the best free multiplier zone")
engine:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "level gated and free; it also respawns every wall", UI.theme.warn)
engine:Toggle("Harvest before rebirth", CONFIG.harvestFirst, function(v) CONFIG.harvestFirst = v end,
    "never resets the board while a reachable wall is still standing")

local spend = farmPage:Card("SPENDING", 2)
spend:Toggle("Buy guns", CONFIG.autoGuns, function(v) CONFIG.autoGuns = v end,
    "best affordable; the gun's Aim IS the per click value")
spend:Toggle("Sell bag", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
    "sells from anywhere, no walking home needed")
spend:Toggle("Backpack slots", CONFIG.autoBackpack, function(v) CONFIG.autoBackpack = v end,
    "more slots means more walls between sell trips")
spend:Toggle("Buy auras", CONFIG.autoAuras, function(v) CONFIG.autoAuras = v end,
    "money priced auras only, the Robux ones are skipped")
spend:Toggle("Speed upgrade", CONFIG.autoSpeed, function(v) CONFIG.autoSpeed = v end,
    "does nothing for a pinned body - off unless you play along")
spend:Toggle("Free rewards", CONFIG.autoRewards, function(v) CONFIG.autoRewards = v end,
    "free reward and offline earnings")

local tuning = farmPage:Card("TUNING", 1)
tuning:Slider("Wall safety %", 100, 300, CONFIG.wallSafety * 100, function(v)
    CONFIG.wallSafety = v / 100
end)
tuning:Slider("Wall time budget (s)", 5, 90, CONFIG.wallBudget, function(v)
    CONFIG.wallBudget = v
end)
tuning:Slider("Loot range (studs)", 200, 3000, CONFIG.collectRange, function(v)
    CONFIG.collectRange = v
end)
tuning:Slider("Aura share %", 5, 90, CONFIG.auraShare * 100, function(v)
    CONFIG.auraShare = v / 100
end)
tuning:Button("Sell bag now", function() task.spawn(function() sellBag(true) end) end)
tuning:Button("Claim rewards now", function() task.spawn(claimRewards) end)
tuning:Button("Rebirth now", function()
    task.spawn(function()
        sellBag(true)
        invoke(RequestRebirth, 8)
    end)
end, UI.theme.warn)

local readout = farmPage:Card("STATUS", 0)
local out = readout:Readout(12)

win:SetMaster(CONFIG.auto, "Auto farm running")
win:OnMaster(function(on) CONFIG.auto = on end)

task.spawn(function()
    while alive() do
        local ready, need = rebirthReady()
        local pick = nextGun()
        out:set({
            "RUN",
            string.format("  phase %s   wall %s (%s hp)", STATE.phase, STATE.wallTarget, abbreviate(STATE.wallHp)),
            string.format("  walls standing %d/%d   reach %s hp",
                STATE.wallsAlive, STATE.wallsTotal, abbreviate(STATE.reach)),
            string.format("  broken %d   picked up %d   loot on floor %d",
                STATE.broken, STATE.collected, STATE.onFloor),
            string.format("  sold %d   earned %s", STATE.sold, abbreviate(STATE.earned)),
            "ECONOMY",
            string.format("  aim %s   money %s   bag %d/%d",
                abbreviate(STATE.aim), abbreviate(STATE.money), STATE.bag, STATE.slots),
            string.format("  gun %s (%s aim)   aura %s x%s",
                STATE.gun, abbreviate(STATE.gunAim), STATE.aura, tostring(STATE.auraMult)),
            string.format("  next gun %s", pick and
                string.format("%s for %s", pick.name, abbreviate(pick.price)) or "nothing better in reach"),
            string.format("  level %d/%d   rebirth %d%s",
                STATE.level, need or 0, STATE.rebirth, ready and "  (ready)" or ""),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        win:SetStat(1, abbreviate(STATE.aim), "aim")
        win:SetStat(2, abbreviate(STATE.money), "money")
        win:SetStat(3, tostring(STATE.rebirth), "rebirth")
        win:SetStatus(string.format("%s aim   %s money   r%d   %s",
            abbreviate(STATE.aim), abbreviate(STATE.money), STATE.rebirth, STATE.phase))
        task.wait(0.5)
    end
end)

pcall(function() win:Home() end)

print("[aimclick] running - RightShift toggles the panel")
