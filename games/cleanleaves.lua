--[[
    cleanleaves.lua  --  "🍂 Clean all the leaves!"  (place 92637789841354)

    Loop: leaves lie in Workspace.Leaves, you gather them into a bag, carry the
    bag to a dumpster and it pays PricePerLeaf per leaf.

    Everything below was measured against the server, not guessed:

      * LeafSim.collectMany(list) is the collect path and the SERVER credits it
        (Leaves 15 -> 25, LeavesCleared 32 -> 42 on a 20-leaf batch). Its return
        value is the CLIENT's count and lies -- a batch sent from 60+ studs
        returned 20 and credited 0. Always confirm against the Leaves attribute.
      * Server range check: batches at 20-24 and 24-30 studs credited 10/10,
        30-40 credited 3/10, 60+ credited nothing. COLLECT_RADIUS 26 is inside
        the wall with margin.
      * A refusal is SILENT. No CollectDenied is sent, and collectMany deletes
        the leaf from the folder anyway, so a bad batch is leaves destroyed for
        nothing. 2489 of 3940 vanished that way with nobody else on the server.
        Two defences: raycast each leaf first, and confirm every batch against
        the Leaves attribute before firing the next one.
      * What actually caused those refusals was the SETTLE time, not distance
        or batch size -- see CONFIG.settle. From a standing start, 10-leaf
        batches at 4-7, 7-10, 10-14, 14-20 and 20-26 studs all credited 10/10.
      * collectMany bypasses the per-pickup limit. Upg_Hand_Grasp level 0 reads
        "1 leaf" and a 20-leaf batch was still credited in full, so Grasp and
        Dexterity buy nothing for this script -- autoUpgrade is off by default.
      * The bag cap is the whole bottleneck. At cap 25 a measured burst did 11
        collect/deposit round trips in 16s for +2.75 cash. BagConfig: caps
        25/75/500/1000 for 2/10/35 cash. That is the only spend that matters.
      * Remotes.EmptyBackpack:FireServer() pays at the nearest dumpster; a
        dumpster only pays when its ZoneRequired matches the player's
        CurrentZone attribute (None 0.01, Backyard 0.02, Farm 0.03).
      * Zone locks gate SELLING, not collecting -- a batch inside the locked
        Farm was credited in full. That is a trap: those leaves are what the
        zone's own goal needs, and draining them stalls the map. zoneAware
        keeps us in zones whose MapConfig.zonePrereq are finished.

    Panel: RightShift.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local plr = Players.LocalPlayer

-- The lobby and the maps are SEPARATE places: the lobby is 92637789841354 and
-- a run teleports to its own place (The House came back as 100068273119174).
-- A hardcoded PlaceId therefore made the script exit in silence the moment a
-- run started -- it loaded fine, printed nothing and simply was not there.
-- Recognise the game by what it exposes instead, which also covers whatever
-- place id The Mansion turns out to have.
local KNOWN_PLACES = {
    [92637789841354] = "lobby",
    [100068273119174] = "map",
}

local function looksLikeThisGame()
    if KNOWN_PLACES[game.PlaceId] then return true end
    local ps = plr:FindFirstChild("PlayerScripts")
    if ps and ps:FindFirstChild("LeafSim") then return true end
    local rs = game:GetService("ReplicatedStorage")
    local remotes = rs:FindFirstChild("Remotes")
    if remotes and remotes:FindFirstChild("EmptyBackpack") then return true end
    if Workspace:FindFirstChild("Teams") and remotes and remotes:FindFirstChild("UpgradeBuy") then
        return true
    end
    return false
end

if not looksLikeThisGame() then return end

----------------------------------------------------------------------------
-- generation guard: re-executing must not leave the old loops running
----------------------------------------------------------------------------
_G.__LEAVES = (_G.__LEAVES or 0) + 1
local GEN = _G.__LEAVES

if _G.__LEAVES_UI then pcall(function() _G.__LEAVES_UI:Destroy() end) end

----------------------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------------------
local CONFIG = {
    auto          = false,   -- master switch, drives the farm loop
    autoDeposit   = true,    -- empty the bag when it is full
    autoBag       = true,    -- buy bag capacity, the only spend that pays off
    autoObjective = true,    -- tick off the journal objectives (Quest1..17)
    -- Clearing every zone does NOT end the run - the zones just respawn in new
    -- waves and the timer keeps going. What ends it is walking into
    -- Workspace.VentPassage, and only then does the server book the clear.
    -- Verified 2026-08-17: MapClears.House went nil -> 1, DifficultyCleared -> 1,
    -- MapRecords.House = 661.6s. Without this the run farms forever for nothing.
    autoFinish    = true,
    autoSkip      = true,    -- press SKIP on the opening and ending cutscenes

    -- lobby side
    lobbyUpgrades      = true,      -- spend diamonds on the permanent upgrades
    lobbySkipWalkSpeed = true,      -- warping makes walk speed worthless
    lobbyDaily         = true,
    lobbyGroup         = true,
    lobbyClassSpin     = false,     -- 40 diamonds, 40% chance of nothing
    lobbyClassReserve  = 150,       -- keep this much for upgrades before spinning
    lobbyStart         = true,      -- walk onto a pad and confirm a run
    lobbyDifficulty    = "Easy",    -- Easy 90m/1x … Impossible 20m/2.5x gems
    -- Auto = the furthest map that is unlocked, so a newly freed map is taken
    -- without touching this file. House | Mansion pin it instead.
    lobbyMap           = "Auto",

    autoVent      = false,   -- unlock vents (1 cash each), not needed to farm
    autoUpgrade   = false,   -- tool upgrades: useless while we batch-collect
    autoRake      = false,   -- buy the Rake for 7.99 cash
    antiAfk       = true,

    -- Off, and that is a correction of an earlier assumption. Collecting inside
    -- a locked zone raises that zone's OWN goal exactly like an unlocked one --
    -- measured in 24s: Backyard +1062, Basement +497, Pool +38, all while the
    -- zones read "lock". Nothing is wasted by working them, so restricting
    -- ourselves to unlocked zones only starves the bot once they run dry. What
    -- actually stalled the map was losing leaves, not choosing the wrong zone.
    zoneAware     = false,
    -- Off by default and it is not cosmetic: the glide anchors the root, which
    -- hands network ownership to the server, so our position stops replicating
    -- and the server refuses the batch we fire on arrival. Measured over 20s:
    -- smooth on 3.9 leaves/s at 5% hit rate, smooth off 12.1/s at 74%.
    smooth        = false,
    collectRadius = 26,      -- measured server grasp wall sits at ~30
    -- Small on purpose. A leaf the server refuses is deleted from the folder
    -- anyway and never comes back, and a zone's GoalTotal is exactly the number
    -- of leaves that spawn in it -- so every uncredited leaf makes that zone
    -- permanently uncompletable. Frontyard died that way at 1071 of 2224 with
    -- 100-leaf batches. A small batch loses little when it goes wrong.
    batchMax      = 25,
    loopTick      = 0.30,
    settle        = 1.00,    -- the server validates against ITS copy of our
                             -- position, and it lags a teleport. At 0.30 the
                             -- batch fired before the move landed server side
                             -- and 96% of it was silently refused and deleted;
                             -- the same batches credited 10/10 from a standing
                             -- start. This one number is the whole difference.
    hopCooldown   = 1.0,
    -- Every hop costs a probe leaf, so hop less: work a spot until it is nearly
    -- bare instead of leaving at the first thin patch.
    thinSpot      = 3,
    stuckSeconds  = 12,
}

local STATE = {
    cash = 0, leaves = 0, cap = 25, cleared = 0, field = 0, workable = 0,
    zone = "None", phase = "idle", note = "",
    banked = 0, cashStart = nil, startClock = os.clock(),
    rate = 0, deposits = 0, hops = 0, hitRate = 1, radius = 26, lost = 0, taken = 0,
    uiOwner = nil,
    -- set while the finisher owns the character, so the collector keeps its
    -- hands off; `finishAt` is the watchdog that clears it if the finisher dies
    finishing = false, finishAt = 0,
}

----------------------------------------------------------------------------
-- carrying AUTO across the teleport
----------------------------------------------------------------------------
-- A run is a different place, so the teleport starts a fresh Lua VM and _G is
-- gone with it. The loader re-arms itself and the script comes back up, but with
-- CONFIG.auto back at its default of false -- so the bot landed in the run and
-- sat there idle until someone pressed AUTO. That breaks the whole point of the
-- lobby -> run -> finish -> lobby loop.
--
-- The switch is therefore parked in a file. Only a recent write counts as a
-- teleport continuation: an old file must never silently start farming days
-- later just because the script got loaded.
local AUTO_FILE, AUTO_WINDOW = "leaves-auto.txt", 600

local function saveAuto()
    if not writefile then return end
    pcall(writefile, AUTO_FILE, (CONFIG.auto and "1" or "0") .. ";" .. tostring(os.time()))
end

local function loadAuto()
    if not (isfile and readfile) then return end
    local ok, raw = pcall(function()
        return isfile(AUTO_FILE) and readfile(AUTO_FILE) or nil
    end)
    if not ok or type(raw) ~= "string" then return end
    local on, stamp = raw:match("^(%d);(%d+)$")
    if on == "1" and tonumber(stamp) and os.time() - tonumber(stamp) <= AUTO_WINDOW then
        CONFIG.auto = true
    end
end

loadAuto()

----------------------------------------------------------------------------
-- game handles
----------------------------------------------------------------------------
local function tryRequire(inst)
    if not inst then return nil end
    local ok, m = pcall(require, inst)
    return ok and m or nil
end

-- FindFirstChild, never WaitForChild. LeafSim only exists inside a run, and in
-- the lobby WaitForChild("LeafSim", 10) waits forever: the script never reaches its
-- end, the bridge job never returns, the client stops polling, and from the
-- outside that is indistinguishable from a crashed client. Three "lobby
-- crashes" were this one line.
local PlayerScripts = plr:FindFirstChild("PlayerScripts")
local LeafSim      = PlayerScripts and tryRequire(PlayerScripts:FindFirstChild("LeafSim"))
local UpgradeConf  = tryRequire(ReplicatedStorage:FindFirstChild("UpgradeConfig"))
local BagConf      = tryRequire(ReplicatedStorage:FindFirstChild("BagConfig"))
local Remotes      = ReplicatedStorage:FindFirstChild("Remotes")

if not Remotes then
    warn("[leaves] no Remotes folder - wrong game?")
    return
end

local EmptyBackpack = Remotes:FindFirstChild("EmptyBackpack")
local BuyBagUpgrade = Remotes:FindFirstChild("BuyBagUpgrade")
local BuyUpgrade    = Remotes:FindFirstChild("BuyUpgrade")
local BuyToolCash   = Remotes:FindFirstChild("BuyToolCash")
local BuyVent       = Remotes:FindFirstChild("BuyVent")
local JournalOpened = Remotes:FindFirstChild("JournalOpened")
local GaragePressed = Remotes:FindFirstChild("GaragePressed")

-- The lobby and the run are two DIFFERENT places joined by a teleport, so this
-- script has to recognise which side it landed on. Surviving the teleport is the
-- loader's job (it re-arms itself with queue_on_teleport); carrying the AUTO
-- switch across is this file's, see loadAuto/saveAuto above.
local IN_RUN = LeafSim ~= nil
                 and typeof(LeafSim.collectMany) == "function"
                 and typeof(LeafSim.folder) == "Instance"

if not IN_RUN and not Workspace:FindFirstChild("Teams") then
    -- Neither side is loaded yet; give the client a moment before deciding.
    -- Kept short because this runs from autoexec, during the join.
    local t0 = os.clock()
    while os.clock() - t0 < 6 do
        local ps = plr:FindFirstChild("PlayerScripts")
        LeafSim = ps and tryRequire(ps:FindFirstChild("LeafSim"))
        if LeafSim and typeof(LeafSim.folder) == "Instance" then IN_RUN = true break end
        if Workspace:FindFirstChild("Teams") then break end
        task.wait(0.25)
    end
end

----------------------------------------------------------------------------
-- small helpers (kept above every caller on purpose)
----------------------------------------------------------------------------
local function alive() return _G.__LEAVES == GEN end
local function char() return plr.Character end
local function hrp()
    local c = char()
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function attr(name, fallback)
    local v = plr:GetAttribute(name)
    if v == nil then return fallback end
    return v
end

local function cashV()   return tonumber(attr("Cash", 0)) or 0 end
local function leavesV() return tonumber(attr("Leaves", 0)) or 0 end
local function capV()    return tonumber(attr("LeafCapacity", 25)) or 25 end
local function infBag()  return attr("InfiniteBag", false) == true or attr("PermInfiniteBag", false) == true end

local function note(text)
    STATE.note = text
end

local function fieldLeaves()
    local n = 0
    for _, l in ipairs(LeafSim.folder:GetChildren()) do
        if l:IsA("BasePart") then n += 1 end
    end
    return n
end

local function bagFull()
    if infBag() then return false end
    local cap = capV()
    if cap <= 0 or cap == math.huge then return false end
    return leavesV() >= cap
end

local function roomLeft()
    if infBag() then return CONFIG.batchMax end
    local mult = tonumber(attr("LeafMult", 1)) or 1
    return math.max(math.floor((capV() - leavesV()) / math.max(mult, 1)), 0)
end

----------------------------------------------------------------------------
-- movement
----------------------------------------------------------------------------
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true

-- Start the ray just above the leaf. Starting high catches the roof over an
-- indoor pile and lands us on top of the house with nothing in reach.
local function groundPos(pos)
    groundParams.FilterDescendantsInstances = { char(), LeafSim.folder }
    local hit = Workspace:Raycast(pos + Vector3.new(0, 3, 0), Vector3.new(0, -40, 0), groundParams)
    if hit and hit.Position.Y <= pos.Y + 3 then
        return hit.Position + Vector3.new(0, 3.5, 0)
    end
    return nil
end

local function warp(pos)
    local hp = hrp()
    if not hp then return false end
    hp.AssemblyLinearVelocity = Vector3.zero
    hp.CFrame = CFrame.new(pos)
    return true
end

-- Ends on exactly the same stud as a hard warp, so every server range check
-- still passes -- it just does not read as a teleport strobe. The root is
-- anchored for the trip; without it the character keeps its physics while
-- being dragged through geometry and drops under the map.
local function moveTo(pos)
    local hp = hrp()
    if not hp then return false end
    if not CONFIG.smooth then return warp(pos) end
    local startCF = hp.CFrame
    local dist = (pos - startCF.Position).Magnitude
    if dist < 3 then return warp(pos) end
    local dur = math.clamp(dist / 420, 0.08, 0.35)
    local target = CFrame.new(pos)
    local t0 = os.clock()
    local wasAnchored = hp.Anchored
    hp.Anchored = true
    while alive() do
        local a = (os.clock() - t0) / dur
        if a >= 1 then break end
        hp.CFrame = startCF:Lerp(target, a)
        RunService.Heartbeat:Wait()
        local cur = hrp()
        if not cur then return false end
        if cur ~= hp then
            pcall(function() hp.Anchored = wasAnchored end)
            hp = cur
            hp.Anchored = true
        end
    end
    hp.CFrame = target
    hp.Anchored = wasAnchored
    hp.AssemblyLinearVelocity = Vector3.zero
    return true
end

----------------------------------------------------------------------------
-- dumpsters
----------------------------------------------------------------------------
-- Found by the PricePerLeaf attribute rather than a hardcoded path, and the
-- model's "Leaves" part is the thing the server measures range to when the
-- model has one. The zone=None dumpster has no such part, so pivot is the
-- fallback -- reading .Position off a missing child is what broke the first
-- version of this.
local DUMPS = nil

local function dumpList()
    if DUMPS then return DUMPS end
    local found = {}
    local folder = Workspace:FindFirstChild("Map")
    folder = folder and folder:FindFirstChild("Dumpsters")
    if folder then
        for _, d in ipairs(folder:GetChildren()) do
            if d:IsA("Model") and d:GetAttribute("PricePerLeaf") then found[#found + 1] = d end
        end
    end
    if #found == 0 then
        for _, v in ipairs(Workspace:GetDescendants()) do
            if v:IsA("Model") and v:GetAttribute("PricePerLeaf") then found[#found + 1] = v end
        end
    end
    if #found == 0 then return nil end

    local out = {}
    for _, d in ipairs(found) do
        local part = d:FindFirstChild("Leaves")
        local pos
        if part and part:IsA("BasePart") then
            pos = part.Position
        else
            local ok, p = pcall(function() return d:GetPivot().Position end)
            pos = ok and p or nil
        end
        if pos then
            out[#out + 1] = {
                model = d, pos = pos,
                price = tonumber(d:GetAttribute("PricePerLeaf")) or 0.01,
                zone  = d:GetAttribute("ZoneRequired"),
                bench = 0,
            }
        end
    end
    table.sort(out, function(a, b) return a.price > b.price end)
    DUMPS = out
    return DUMPS
end

-- A dumpster only pays when its ZoneRequired matches CurrentZone, and
-- CurrentZone does not change just because we teleport onto it.
local function usableDump(d)
    return d.zone == nil or d.zone == "None" or d.zone == attr("CurrentZone", "None")
end

local function activeDump()
    local list = dumpList()
    if not list then return nil end
    local now = os.clock()
    local open, valid = {}, {}
    for _, d in ipairs(list) do
        if usableDump(d) then
            valid[#valid + 1] = d
            if now >= d.bench then open[#open + 1] = d end
        end
    end
    if #valid == 0 then return list[#list] end
    if #open == 0 then
        for _, d in ipairs(valid) do d.bench = 0 end
        open = valid
    end
    return open[1]                      -- list is sorted by price, richest first
end

----------------------------------------------------------------------------
-- zones
----------------------------------------------------------------------------
-- Map.MapConfig.zonePrereq spells the unlock tree out: Rooftop needs Porch,
-- Garage, Shed and Frontyard finished, Farm needs Maze, Basement needs "ALL".
-- A zone with no entry is open from the start.
--
-- This matters more than it looks. The server does NOT stop you collecting
-- inside a locked zone -- a 15-leaf batch in the locked Farm was credited in
-- full -- but those leaves are the material the zone's own goal needs. The
-- first version of this script stripped every zone at once, the whole field
-- ran dry, and no further wave spawned. Work the open zones only.
local MapCfg = tryRequire(Workspace:FindFirstChild("Map") and Workspace.Map:FindFirstChild("MapConfig"))

local zoneBoxes = nil

-- Each zone is collected as its individual spawn surfaces, not as one box round
-- the whole model. The zones overlap in plan view -- the Basement sits directly
-- under the front of the house -- so a single model box plus "first match wins"
-- handed surface leaves to the Basement and locked them away. The player was
-- standing in the Frontyard with 293 leaves in sight and the script saw one.
local function zoneList()
    if zoneBoxes then return zoneBoxes end
    local folder = Workspace:FindFirstChild("Map")
    folder = folder and folder:FindFirstChild("Leave_Locations")
    if not folder then return {} end
    local out = {}
    for _, z in ipairs(folder:GetChildren()) do
        local boxes = {}
        for _, part in ipairs(z:GetDescendants()) do
            if part:IsA("BasePart") then
                boxes[#boxes + 1] = { pos = part.Position, size = part.Size }
            end
        end
        if z:IsA("BasePart") then
            boxes[#boxes + 1] = { pos = z.Position, size = z.Size }
        end
        if #boxes == 0 then
            local ok, cf, size = pcall(function() return z:GetBoundingBox() end)
            if ok and cf then boxes[1] = { pos = cf.Position, size = size } end
        end
        if #boxes > 0 then
            out[#out + 1] = { name = z.Name, model = z, boxes = boxes }
        end
    end
    zoneBoxes = out
    return out
end

-- `Completed` is the flag, NOT GoalCollected >= GoalTotal. Every zone runs
-- WavesTotal waves and the goal pair counts the CURRENT wave only, so it resets
-- to 0/total the moment the next one spawns - watched live, the map total fell
-- 11747 -> 11039 while no zone lost its completion. `everyZoneDone` further down
-- was corrected for exactly this and this twin was missed, so a genuinely
-- finished zone read as unfinished every time a new wave spawned: with
-- zoneAware on, a dependent zone (Rooftop needs Porch/Garage/Shed/Frontyard)
-- stayed locked although its prerequisites were satisfied, and the zone table in
-- the panel flickered finished zones back to open.
local function zoneDone(name)
    local folder = Workspace:FindFirstChild("Map")
    folder = folder and folder:FindFirstChild("Leave_Locations")
    local z = folder and folder:FindFirstChild(name)
    if not z then return false end
    return z:GetAttribute("Completed") == true
end

local function zoneOpen(name)
    if not CONFIG.zoneAware then return true end
    local prereq = MapCfg and MapCfg.zonePrereq and MapCfg.zonePrereq[name]
    if prereq == nil then return true end
    if prereq == "ALL" then
        for _, z in ipairs(zoneList()) do
            if z.name ~= name and not zoneDone(z.name) then return false end
        end
        return true
    end
    if type(prereq) == "table" then
        for _, need in ipairs(prereq) do
            if not zoneDone(need) then return false end
        end
        return true
    end
    return true
end

-- Which zone a point sits in. Several zone models are flat planes (0.05 studs
-- tall), so the Y test gets a generous band or every leaf reads as "outside".
-- Vertically nearest surface wins. A leaf resting on the front path is a few
-- studs above the Frontyard plane and many studs above the Basement floor, so
-- the height gap is what tells the two apart -- plan position alone cannot.
local function zoneAt(pos)
    local best, bestGap = nil, math.huge
    for _, z in ipairs(zoneList()) do
        for _, b in ipairs(z.boxes) do
            local v = pos - b.pos
            if math.abs(v.X) <= b.size.X / 2 + 2 and math.abs(v.Z) <= b.size.Z / 2 + 2 then
                local gap = math.max(math.abs(v.Y) - b.size.Y / 2, 0)
                if gap <= 8 and gap < bestGap then
                    bestGap, best = gap, z.name
                end
            end
        end
    end
    return best
end

local openCache, openCacheAt = {}, 0

local function leafAllowed(pos)
    if not CONFIG.zoneAware then return true end
    local name = zoneAt(pos)
    if name == nil then return true end          -- outside every box: fair game
    if os.clock() - openCacheAt > 5 then
        openCache, openCacheAt = {}, os.clock()
    end
    local v = openCache[name]
    if v == nil then
        -- A finished zone is fair game: its goal is already met, so taking what
        -- is still lying there cannot stall anything and it is free money. Only
        -- zones we have not unlocked yet are off limits. (Shed finished with 172
        -- leaves still on the floor, and the first version walked past them.)
        v = zoneOpen(name)
        openCache[name] = v
    end
    return v
end

-- leaves we are actually allowed to take, which is what "the field is empty"
-- has to mean -- a map full of locked-zone leaves is not work for us
local function workableLeaves()
    local n = 0
    for _, l in ipairs(LeafSim.folder:GetChildren()) do
        if l:IsA("BasePart") and leafAllowed(l.Position) then n += 1 end
    end
    return n
end

----------------------------------------------------------------------------
-- collecting
----------------------------------------------------------------------------
local GRID_CELL     = 22
local CELL_MIN      = { 24, 10, 4 }
local ROAM_STAGE    = { 90, 170, 320, 900 }
local CELL_COOLDOWN = 8
local DEAD_COOLDOWN = 25

local cellState  = {}
local spotKey    = nil
local lastHop    = 0
local justHopped = false

local function cellKey(p)
    return math.floor(p.X / GRID_CELL) .. "," .. math.floor(p.Z / GRID_CELL)
end

local function markDead(key)
    if not key then return end
    local st = cellState[key] or {}
    st.dead = os.clock()
    cellState[key] = st
end

-- Densest cluster we have not just farmed or benched. Widens through
-- CELL_MIN x ROAM_STAGE, so nil here means the map really has nothing left.
local function bestSpot()
    local hp = hrp()
    if not hp then return nil end
    local dump = activeDump()
    local anchor = dump and dump.pos or hp.Position
    local now = os.clock()

    local grid = {}
    for _, leaf in ipairs(LeafSim.folder:GetChildren()) do
        if leaf:IsA("BasePart") and leafAllowed(leaf.Position) then
            local p = leaf.Position
            local key = cellKey(p)
            local st = cellState[key]
            if not (st and st.dead and now - st.dead < DEAD_COOLDOWN) then
                local g = grid[key]
                if not g then
                    g = { n = 0, x = 0, y = p.Y, z = 0, anchorD = (p - anchor).Magnitude }
                    grid[key] = g
                end
                g.n += 1
                g.x += p.X
                g.z += p.Z
                if p.Y < g.y then g.y = p.Y end   -- lowest leaf is the floor of the pile
            end
        end
    end

    for _, minN in ipairs(CELL_MIN) do
        for _, radius in ipairs(ROAM_STAGE) do
            local cells = {}
            for key, g in pairs(grid) do
                if g.n >= minN and g.anchorD <= radius then
                    local center = Vector3.new(g.x / g.n, g.y, g.z / g.n)
                    local st = cellState[key]
                    local recent = (st and st.farmed and now - st.farmed < CELL_COOLDOWN) and -1e6 or 0
                    cells[#cells + 1] = {
                        key = key, center = center,
                        -- distance weighted hard: work the pile you stand in
                        -- before crossing the map
                        score = g.n - (center - hp.Position).Magnitude * 0.25 + recent,
                    }
                end
            end
            table.sort(cells, function(a, b) return a.score > b.score end)
            for i = 1, math.min(6, #cells) do
                local land = groundPos(cells[i].center)
                -- reject a landing above the pile: that is a roof over an
                -- indoor cluster and we would arrive with nothing in reach
                if land and land.Y <= cells[i].center.Y + 8 then
                    cellState[cells[i].key] = cellState[cells[i].key] or {}
                    cellState[cells[i].key].farmed = now
                    return land, cells[i].key
                end
            end
        end
    end

    -- Last resort: the leftovers. A cell needs a minimum count and a floor the
    -- raycast can find, so the final handful of scattered leaves matched no
    -- cell at all and the loop sat in "nothing in sight" -> unstick -> roam
    -- forever with three leaves still on the map. Go stand on the nearest one.
    local nearest, nearestD = nil, math.huge
    for _, leaf in ipairs(LeafSim.folder:GetChildren()) do
        if leaf:IsA("BasePart") and leafAllowed(leaf.Position) then
            local key = cellKey(leaf.Position)
            local st = cellState[key]
            if not (st and st.dead and now - st.dead < DEAD_COOLDOWN) then
                local dist = (leaf.Position - hp.Position).Magnitude
                if dist < nearestD then
                    nearestD, nearest = dist, leaf
                end
            end
        end
    end
    if nearest then
        local land = groundPos(nearest.Position) or (nearest.Position + Vector3.new(0, 3.5, 0))
        return land, cellKey(nearest.Position)
    end
    return nil
end

local function goTo(pos, key)
    if not pos then return false end
    moveTo(pos)
    spotKey = key
    lastHop = os.clock()
    justHopped = true
    STATE.hops += 1
    task.wait(CONFIG.settle)
    return true
end

local function countNear(radius)
    local hp = hrp()
    if not hp then return 0 end
    local pos, n = hp.Position, 0
    for _, leaf in ipairs(LeafSim.folder:GetChildren()) do
        if leaf:IsA("BasePart") and (leaf.Position - pos).Magnitude <= radius then
            n += 1
            if n >= CONFIG.thinSpot then return n end
        end
    end
    return n
end

-- The server wants a clear line to the leaf. This is the single most expensive
-- thing this script got wrong: indoors, a 26-stud batch mostly points through
-- walls, the server silently refuses those leaves (no CollectDenied is sent)
-- and collectMany deletes them from the folder anyway. 3940 workable leaves
-- turned into 1451 credited that way, with nobody else on the server.
local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.IgnoreWater = true

-- Leaves lie ON the floor, so a ray to the leaf's centre clips the ground just
-- short of it and every leaf reads as blocked -- the first version of this
-- rejected practically the whole field ("nothing in sight") and throughput
-- collapsed. Aim slightly above the leaf and allow a hit that lands close to
-- it. Standing measurements credited 10/10 out to 26 studs with no sight test
-- at all, so this is a safety net, not the mechanism.
local function inSight(from, leaf)
    sightParams.FilterDescendantsInstances = { char(), LeafSim.folder }
    local target = leaf.Position + Vector3.new(0, 1, 0)
    local dir = target - from
    local hit = Workspace:Raycast(from, dir, sightParams)
    if not hit then return true end
    return (hit.Position - target).Magnitude <= 3
end

-- Credited/sent over the recent batches. Drives the radius: a spot where most
-- of the batch bounces is a spot to stand closer in, not to keep firing at.
local hitRate, radiusNow = 1.0, nil

-- Returns leaves the SERVER took and how many were sent. The client count from
-- collectMany is not proof and is deliberately ignored here.
local function collectHere(limit)
    local hp = hrp()
    if not hp then return 0, 0 end
    local room = roomLeft()
    if room <= 0 then return 0, 0 end
    radiusNow = radiusNow or CONFIG.collectRadius
    local budget = math.min(room, CONFIG.batchMax, limit or math.huge)
    local eye = hp.Position + Vector3.new(0, 1.5, 0)
    local near = {}
    for _, leaf in ipairs(LeafSim.folder:GetChildren()) do
        if leaf:IsA("BasePart") then
            local d = (leaf.Position - eye).Magnitude
            if d <= radiusNow and leafAllowed(leaf.Position) then
                near[#near + 1] = { part = leaf, d = d }
            end
        end
    end
    if #near == 0 then return 0, 0 end
    table.sort(near, function(a, b) return a.d < b.d end)

    local batch = {}
    for i = 1, #near do
        if #batch >= budget then break end
        if inSight(eye, near[i].part) then batch[#batch + 1] = near[i].part end
    end
    if #batch == 0 then return 0, 0 end

    local before = leavesV()
    pcall(LeafSim.collectMany, batch)

    -- Confirm this batch before anything else fires another one.
    local t0 = os.clock()
    while os.clock() - t0 < 1.2 do
        if leavesV() > before then break end
        task.wait(0.05)
    end
    task.wait(0.15)
    local credited = leavesV() - before

    local rate = credited / #batch
    hitRate = hitRate * 0.6 + rate * 0.4

    -- A shortfall means leaves were just destroyed for nothing. Stop pushing:
    -- give the server time to catch up before anything else is sent, and count
    -- the loss so the panel shows it instead of hiding it in an average.
    if credited < #batch then
        STATE.lost += (#batch - credited)
        task.wait(0.8)
    end
    STATE.taken += credited
    -- Bias towards the full radius: the measurements say 26 studs is fine from
    -- a standing start, so only a sustained refusal streak should pull it in,
    -- and it should climb back as soon as batches land again. Demanding 95%
    -- before growing pinned it at 8 and cut throughput to a third.
    if hitRate < 0.55 then
        radiusNow = math.max(8, radiusNow - 3)
    elseif hitRate > 0.80 then
        radiusNow = math.min(CONFIG.collectRadius, radiusNow + 4)
    end

    return credited, #batch
end

----------------------------------------------------------------------------
-- depositing
----------------------------------------------------------------------------
local function deposit()
    if not EmptyBackpack then return false end
    local have = leavesV()
    if have <= 0 then return false end
    local d = activeDump()
    if not d then return false end

    local back = hrp() and hrp().CFrame
    moveTo(d.pos + Vector3.new(0, 4, 0))
    task.wait(0.30)
    pcall(function() EmptyBackpack:FireServer() end)

    -- confirm: the bag actually shrank. A dumpster that refuses is benched
    -- rather than assumed broken forever.
    local t0 = os.clock()
    while os.clock() - t0 < 1.5 do
        if leavesV() < have then break end
        task.wait(0.1)
    end
    local paid = leavesV() < have
    if paid then
        STATE.deposits += 1
        STATE.banked += (have - leavesV())
        note(string.format("sold %d leaves at %.2f", have - leavesV(), d.price))
    else
        d.bench = os.clock() + 60
        note("dumpster refused (zone " .. tostring(d.zone) .. "), benched 60s")
    end
    if back then moveTo(back.Position) end
    return paid
end

----------------------------------------------------------------------------
-- spending
----------------------------------------------------------------------------
local function nextBagPrice()
    if not BagConf or type(BagConf.prices) ~= "table" then return nil end
    local lvl = tonumber(attr("BagLevel", 0)) or 0
    return BagConf.prices[lvl + 1]
end

local function buyBag()
    if not CONFIG.autoBag or not BuyBagUpgrade then return end
    local price = nextBagPrice()
    if not price or cashV() < price then return end
    local capBefore = capV()
    pcall(function() BuyBagUpgrade:FireServer() end)
    task.wait(1.0)
    if capV() > capBefore then
        note(string.format("bag %d -> %d", capBefore, capV()))
    end
end

-- The bag is the only purchase that speeds this script up, so everything else
-- waits until the bag ladder is finished or unaffordable.
local function bagDone()
    local price = nextBagPrice()
    return price == nil
end

local function buyRake()
    if not CONFIG.autoRake or not BuyToolCash then return end
    if attr("OwnsRake", false) == true then return end
    if not bagDone() then return end
    local price = (UpgradeConf and UpgradeConf.shop and UpgradeConf.shop.Rake and UpgradeConf.shop.Rake.cash) or 7.99
    if cashV() < price then return end
    pcall(function() BuyToolCash:FireServer("Rake") end)
    task.wait(1.0)
    if attr("OwnsRake", false) == true then note("bought the Rake") end
end

local function ventList()
    local out = {}
    local folder = Workspace:FindFirstChild("Map")
    folder = folder and folder:FindFirstChild("Vents")
    if not folder then return out end
    for _, v in ipairs(folder:GetChildren()) do
        out[#out + 1] = v
    end
    return out
end

-- Position gated exactly like the garage button: fired from across the map it
-- does nothing and says nothing, fired while standing on the vent it buys
-- immediately. The vent instance is the argument.
local function buyVents()
    if not CONFIG.autoVent or not BuyVent then return end
    if not bagDone() then return end
    local hp = hrp()
    if not hp then return end
    local back = hp.CFrame
    local bought = 0
    for _, v in ipairs(ventList()) do
        local cost = tonumber(v:GetAttribute("Cost")) or 0
        if v:IsA("BasePart") and v:GetAttribute("Unlocked") ~= true and cost > 0 and cashV() >= cost then
            local aim = v.Position + Vector3.new(0, 5, 0)
            warp(aim)
            local hold = RunService.Heartbeat:Connect(function()
                local cur = hrp()
                if cur then cur.CFrame = CFrame.new(aim) end
            end)
            task.wait(1.2)
            pcall(function() BuyVent:FireServer(v) end)
            task.wait(0.8)
            hold:Disconnect()
            if v:GetAttribute("Unlocked") == true then
                bought += 1
                note("vent unlocked for " .. cost)
            end
        end
    end
    if bought > 0 then warp(back.Position) end
end

-- Grasp and Dexterity do nothing for a batch collector (measured: level 0
-- reads "1 leaf" and a 20-leaf batch was credited in full), so this only runs
-- when the user explicitly turns it on and only after the bag is done.
local function cheapestUpgrade()
    if not UpgradeConf or type(UpgradeConf.tools) ~= "table" then return nil end
    local money, best = cashV(), nil
    for tk, tool in pairs(UpgradeConf.tools) do
        local ownsAttr = tool.ownsAttr
        local owns = ownsAttr == nil or attr(ownsAttr, false) == true
        if owns and type(tool.upgrades) == "table" then
            for un, u in pairs(tool.upgrades) do
                local lvl = tonumber(attr("Upg_" .. tk .. "_" .. un, 0)) or 0
                if type(u) == "table" and u.max and lvl < u.max and type(u.prices) == "table" then
                    local price = u.prices[lvl + 1]
                    if type(price) == "number" and price <= money and (not best or price < best.price) then
                        best = { tool = tk, name = un, price = price }
                    end
                end
            end
        end
    end
    return best
end

local function buyUpgrades()
    if not CONFIG.autoUpgrade or not BuyUpgrade then return end
    if not bagDone() then return end
    local up = cheapestUpgrade()
    if not up then return end
    pcall(function() BuyUpgrade:FireServer(up.tool, up.name) end)
    task.wait(0.6)
    note(string.format("upgrade %s %s for %.2f", up.tool, up.name, up.price))
end

----------------------------------------------------------------------------
-- journal objectives
----------------------------------------------------------------------------
-- QuestConfig numbers the 17 objectives and the player carries the counts as
-- Quest1..Quest17 attributes. Collecting and selling tick themselves off; the
-- rest are one-off button presses that the farm loop would never make.
-- Opening the garage is the one that matters -- Garage is a prerequisite for
-- Rooftop, and Rooftop gates Backyard, Maze and Pool.
local function questVal(i)
    return tonumber(attr("Quest" .. i, 0)) or 0
end

local function objectives()
    if not CONFIG.autoObjective then return end

    if questVal(3) < 1 and JournalOpened then
        pcall(function() JournalOpened:FireServer() end)
        task.wait(0.4)
        if questVal(3) >= 1 then note("objective: journal opened") end
    end

    -- the cheapest hand upgrade is 0.50 (Dexterity 1) and it exists only to
    -- tick this objective off -- it does nothing for a batch collector
    if questVal(4) < 1 and BuyUpgrade and cashV() >= 1 then
        pcall(function() BuyUpgrade:FireServer("Hand", "Dexterity") end)
        task.wait(0.5)
        if questVal(4) >= 1 then note("objective: hand upgraded") end
    end

    -- Position gated: fired from across the map it does nothing and reports
    -- nothing, fired while standing on Map.GarageButton it ticks immediately.
    -- The argument is ignored -- nil, the button and true all behaved the same.
    if questVal(5) < 1 and GaragePressed then
        local btn = Workspace:FindFirstChild("Map")
        btn = btn and btn:FindFirstChild("GarageButton")
        local hp = hrp()
        local back = hp and hp.CFrame
        if btn then
            local ok, p = pcall(function() return btn:GetPivot().Position end)
            if ok then
                warp(p + Vector3.new(0, 5, 0))
                task.wait(1.2)
            end
        end
        pcall(function() GaragePressed:FireServer() end)
        task.wait(0.6)
        if back then warp(back.Position) end
        if questVal(5) >= 1 then note("objective: garage opened") end
    end
end

local function questRows()
    local Q = tryRequire(ReplicatedStorage:FindFirstChild("QuestConfig"))
    local rows = {}
    if type(Q) ~= "table" then return rows end
    for i = 1, 17 do
        local q = Q[i]
        if type(q) == "table" and q.desc then
            local have, want = questVal(i), tonumber(q.total) or 1
            rows[#rows + 1] = string.format("  %s %-26s %d/%d",
                have >= want and "x" or " ", tostring(q.desc):sub(1, 26), have, want)
        end
    end
    return rows
end

----------------------------------------------------------------------------
-- zone progress, read straight off the map
----------------------------------------------------------------------------
local function zoneRows()
    local rows = {}
    local folder = Workspace:FindFirstChild("Map")
    folder = folder and folder:FindFirstChild("Leave_Locations")
    if not folder then return rows end
    local list = {}
    for _, z in ipairs(folder:GetChildren()) do
        local total = tonumber(z:GetAttribute("GoalTotal")) or 0
        local got   = tonumber(z:GetAttribute("GoalCollected")) or 0
        list[#list + 1] = { name = z.Name, total = total, got = got,
                            gems = tonumber(z:GetAttribute("Gems")) or 0 }
    end
    table.sort(list, function(a, b) return (a.got / math.max(a.total, 1)) > (b.got / math.max(b.total, 1)) end)
    for _, z in ipairs(list) do
        local mark = zoneDone(z.name) and "done" or (zoneOpen(z.name) and "open" or "lock")
        rows[#rows + 1] = string.format("  %-10s %5d/%-5d %3d%% %s",
            z.name, z.got, z.total, math.floor(100 * z.got / math.max(z.total, 1)), mark)
    end
    return rows
end

----------------------------------------------------------------------------
-- status
----------------------------------------------------------------------------
local function refreshStatus()
    STATE.cash    = cashV()
    STATE.leaves  = leavesV()
    STATE.cap     = capV()
    STATE.cleared = tonumber(attr("LeavesCleared", 0)) or 0
    STATE.zone    = tostring(attr("CurrentZone", "None"))
    STATE.field    = fieldLeaves()
    STATE.workable = workableLeaves()
    if STATE.cashStart == nil then STATE.cashStart = STATE.cash end
    local secs = math.max(os.clock() - STATE.startClock, 1)
    STATE.rate = (STATE.cash - STATE.cashStart) / secs
end

----------------------------------------------------------------------------
-- lobby
----------------------------------------------------------------------------
-- Same place, reached by teleport. Everything here is a plain remote except
-- starting a run, which goes through the game's own NewGame panel -- the panel
-- opens by standing on one of the Teams.Square pads and then auto-confirms
-- after 15 seconds all by itself, so all we really have to do is stand there.
local DailyClaim  = Remotes:FindFirstChild("DailyClaim")
local GroupClaim  = Remotes:FindFirstChild("GroupClaim")
local UpgradeBuy  = Remotes:FindFirstChild("UpgradeBuy")
local ClassSpin   = Remotes:FindFirstChild("ClassSpin")
local UpgradeCfg  = tryRequire(ReplicatedStorage:FindFirstChild("PlayerUpgradeConfig"))
local ClassCfg    = tryRequire(ReplicatedStorage:FindFirstChild("ClassConfig"))

local LOBBY = {
    diamonds = 0, class = "?", upgrades = {}, note = "", phase = "idle",
    daily = "", group = "", started = false,
}

local function myData()
    local f = Remotes:FindFirstChild("GetMyData")
    if not f then return nil end
    local ok, data = pcall(function() return f:InvokeServer() end)
    return ok and type(data) == "table" and data or nil
end

-- Order matters and it is not the cheapest-first order. Gems compounds into
-- every later upgrade and is the cheapest ladder (10/25/50/90/140), Cash is a
-- straight income multiplier, BagCapacity only saves deposit trips we already
-- teleport through, and WalkSpeed does nothing at all for a script that warps.
local UPGRADE_ORDER = { "Gems", "Cash", "BagCapacity", "WalkSpeed" }

local function upgradeCost(key, level)
    if not UpgradeCfg or type(UpgradeCfg.upgrades) ~= "table" then return nil end
    for _, u in pairs(UpgradeCfg.upgrades) do
        if u.key == key then
            if level >= (UpgradeCfg.MAX_LEVEL or 5) then return nil end
            return u.costs and u.costs[level + 1]
        end
    end
    return nil
end

local function buyLobbyUpgrades(data)
    if not CONFIG.lobbyUpgrades or not UpgradeBuy or not data then return data end
    local levels = data.Upgrades or {}
    local diamonds = tonumber(data.Diamonds) or 0
    for _, key in ipairs(UPGRADE_ORDER) do
        if CONFIG.lobbySkipWalkSpeed and key == "WalkSpeed" then
            -- deliberately last and off: we teleport, walking speed is noise
        else
            local cost = upgradeCost(key, tonumber(levels[key]) or 0)
            while cost and diamonds >= cost do
                local ok, reply = pcall(function() return UpgradeBuy:InvokeServer(key) end)
                task.wait(0.5)
                local fresh = myData()
                if not fresh then return data end
                local newLevel = tonumber((fresh.Upgrades or {})[key]) or 0
                if not ok or newLevel <= (tonumber(levels[key]) or 0) then
                    LOBBY.note = "upgrade " .. key .. " refused (" .. tostring(reply) .. ")"
                    return fresh
                end
                LOBBY.note = string.format("%s -> level %d for %d", key, newLevel, cost)
                data, levels, diamonds = fresh, fresh.Upgrades or {}, tonumber(fresh.Diamonds) or 0
                cost = upgradeCost(key, newLevel)
            end
        end
    end
    return data
end

-- The daily is refused in silence when it is not due -- claiming day 2 on day 1
-- returned no error and spent nothing -- so it is safe to simply try every day
-- that is not already ticked off.
local function claimDaily(data)
    if not CONFIG.lobbyDaily or not DailyClaim or not data then return end
    local claimed = data.DailyClaimed or {}
    for day = 1, 8 do
        if not claimed[day] and not claimed[tostring(day)] then
            pcall(function() DailyClaim:FireServer(day) end)
            task.wait(0.6)
            local fresh = myData()
            local now = fresh and (fresh.DailyClaimed or {}) or {}
            if now[day] or now[tostring(day)] then
                LOBBY.note = "daily day " .. day .. " claimed"
                return fresh
            end
        end
    end
end

local function claimGroup(data)
    if not CONFIG.lobbyGroup or not GroupClaim or not data then return end
    if data.GroupRewardClaimed then return end
    local ok, reply = pcall(function() return GroupClaim:InvokeServer() end)
    LOBBY.group = ok and tostring(reply) or "error"
    if LOBBY.group == "notmember" then
        CONFIG.lobbyGroup = false        -- nothing to retry, stop asking
        LOBBY.note = "group reward needs group membership, turned off"
    end
end

-- 40 diamonds a spin and Starter (no bonus at all) is 40% of the wheel, so this
-- competes directly with a guaranteed upgrade level. Off unless asked for.
local function spinClass(data)
    if not CONFIG.lobbyClassSpin or not ClassSpin or not data then return end
    local cost = (ClassCfg and ClassCfg.SPIN_COST) or 40
    if (tonumber(data.Diamonds) or 0) < cost + CONFIG.lobbyClassReserve then return end
    local ok, reply = pcall(function() return ClassSpin:InvokeServer() end)
    task.wait(1.0)
    local fresh = myData()
    if ok and fresh then LOBBY.note = "class spin -> " .. tostring(fresh.Class) end
end

-- Standing on a Teams.Square pad opens GAME SETTINGS, which then confirms
-- itself after 15s. Firing Confirm ourselves just skips that wait.
local function newGameGui()
    local gui = plr:FindFirstChild("PlayerGui")
    gui = gui and gui:FindFirstChild("Gui")
    return gui and gui:FindFirstChild("NewGame")
end

local function press(button)
    if not button then return false end
    local ok, conns = pcall(function() return getconnections(button.Activated) end)
    if not ok or #conns == 0 then return false end
    for _, c in ipairs(conns) do pcall(function() c:Fire() end) end
    return true
end

local function setDifficulty(target)
    local ng = newGameGui()
    if not ng then return false end
    local picker = ng.Main.DifficultySection.DifficultyPicker
    -- The picker wraps, so walking right always reaches every entry. Four
    -- difficulties plus slack; it stops as soon as the label matches.
    for _ = 1, 8 do
        local shown = tostring(picker.Difficulty.Text):upper()
        if shown == tostring(target):upper() then return true end
        if not press(picker.Right) then return false end
        task.wait(0.25)
    end
    LOBBY.note = "difficulty " .. tostring(target) .. " not reachable"
    return false
end

-- The map cards live in Gui.NewGame.MapPanel.Maps as one ImageButton per map
-- (House, Mansion, Grocery), each with a Lock and a Dim overlay for the ones
-- that are not available. CardTemplate is the hidden blueprint and must be
-- skipped or the picker "selects" a card that is not a map.
local function mapCards()
    local ng = newGameGui()
    local panel = ng and ng:FindFirstChild("MapPanel")
    local list = panel and panel:FindFirstChild("Maps")
    if not list then return {} end
    local out = {}
    for _, card in ipairs(list:GetChildren()) do
        if card:IsA("ImageButton") and card.Name ~= "CardTemplate" then
            local lock = card:FindFirstChild("Lock")
            local dim  = card:FindFirstChild("Dim")
            local name = card:FindFirstChild("MapName")
            out[#out + 1] = {
                card    = card,
                key     = card.Name,
                label   = name and name.Text or card.Name,
                locked  = (lock and lock.Visible) or (dim and dim.Visible) or false,
                best    = card:FindFirstChild("BestTime") and card.BestTime.Text or "",
            }
        end
    end
    return out
end

local function selectMap(target)
    if not target or target == "" then return true end

    -- "Auto" takes the last card that is not locked. The list is ordered by
    -- progression (House, Mansion, Grocery), so this follows the account: today
    -- it picks the Mansion, and the day Grocery stops reading COMING SOON it
    -- moves on by itself without anyone editing a config.
    if tostring(target):lower() == "auto" then
        local best
        for _, m in ipairs(mapCards()) do
            if not m.locked then best = m end
        end
        if not best then
            LOBBY.note = "no unlocked map in the list"
            return false
        end
        press(best.card)
        task.wait(0.35)
        LOBBY.note = "map " .. best.label .. " (auto)"
        return true
    end

    local want = tostring(target):lower()
    for _, m in ipairs(mapCards()) do
        if m.key:lower() == want or m.label:lower():find(want, 1, true) then
            if m.locked then
                LOBBY.note = "map " .. m.label .. " is locked"
                return false
            end
            press(m.card)
            task.wait(0.35)
            return true
        end
    end
    LOBBY.note = "map " .. tostring(target) .. " not in the list"
    return false
end

local function startRun()
    if not CONFIG.lobbyStart then return false end
    local teams = Workspace:FindFirstChild("Teams")
    if not teams then return false end

    -- You have to WALK IN. A Square is not a floor pad at all: it is four
    -- 14-stud Wall parts carrying TouchInterests, with no slab between them, so
    -- there is nothing to stand on that fires anything. Landing in the middle by
    -- CFrame touches no wall, and GAME SETTINGS then never opens -- which looked
    -- exactly like "the script walks into the start area and nothing happens".
    -- Crossing a wall is the trigger, so the character is placed outside and
    -- glided through it.
    local pad = teams:FindFirstChild("Square1") or teams:GetChildren()[1]
    if not pad then return false end

    local okBox, cf, size = pcall(function() return pad:GetBoundingBox() end)
    if not okBox or not cf then return false end
    local centre = cf.Position

    -- Stand at head height inside the walls, not at the model's centre: the box
    -- is 14 studs tall and its middle is mid-air.
    local floorY = math.huge
    local walls = {}
    for _, p in ipairs(pad:GetDescendants()) do
        if p:IsA("BasePart") then
            floorY = math.min(floorY, p.Position.Y - p.Size.Y / 2)
            if p:FindFirstChildOfClass("TouchTransmitter") then walls[#walls + 1] = p end
        end
    end
    if floorY == math.huge then floorY = centre.Y end
    local target = Vector3.new(centre.X, floorY + 4, centre.Z)
    local outside = target + Vector3.new(size.X / 2 + 8, 0, 0)

    -- Cross the wall plane in steps rather than in one jump, so the Touched
    -- actually fires; a single CFrame write from outside to inside skips over it.
    warp(outside)
    task.wait(0.25)
    local hp = hrp()
    for step = 1, 12 do
        if not alive() then return false end
        hp = hrp()
        if not hp then return false end
        hp.CFrame = CFrame.new(outside:Lerp(target, step / 12))
        RunService.Heartbeat:Wait()
    end

    -- Belt and braces: the walls are the things holding the TouchInterest, so
    -- fire them too now that the character is genuinely inside them.
    if firetouchinterest then
        local cur = hrp()
        if cur then
            for _, w in ipairs(walls) do
                pcall(firetouchinterest, cur, w, 0)
                pcall(firetouchinterest, cur, w, 1)
            end
        end
    end

    local hold = RunService.Heartbeat:Connect(function()
        local cur = hrp()
        if cur then cur.CFrame = CFrame.new(target) end
    end)

    local ng
    local t0 = os.clock()
    while os.clock() - t0 < 8 do
        ng = newGameGui()
        if ng and ng.Visible then break end
        task.wait(0.2)
    end

    if not (ng and ng.Visible) then
        -- Standing there long enough starts the run on its own, so a closed
        -- panel is not necessarily a failure. Hold a little longer, then let go.
        task.wait(3)
        hold:Disconnect()
        LOBBY.note = "held the pad; GAME SETTINGS never opened"
        return false
    end

    -- Map first: switching it resets the difficulty label on some cards, so
    -- picking the map afterwards would undo the difficulty that was just set.
    pcall(function() selectMap(CONFIG.lobbyMap) end)
    pcall(function() setDifficulty(CONFIG.lobbyDifficulty) end)
    task.wait(0.3)
    press(ng.Main.Footer.Confirm)
    task.wait(1.0)
    hold:Disconnect()
    LOBBY.note = "confirmed a run on " .. tostring(CONFIG.lobbyDifficulty)
    LOBBY.started = true
    return true
end

local function lobbyTick()
    local data = myData()
    if not data then return end
    LOBBY.diamonds = tonumber(data.Diamonds) or 0
    LOBBY.class = tostring(data.Class)
    LOBBY.upgrades = data.Upgrades or {}

    LOBBY.phase = "rewards"
    local fresh = claimDaily(data) or data
    claimGroup(fresh)

    LOBBY.phase = "upgrades"
    fresh = buyLobbyUpgrades(fresh) or fresh
    spinClass(fresh)

    LOBBY.diamonds = tonumber(fresh.Diamonds) or LOBBY.diamonds
    LOBBY.upgrades = fresh.Upgrades or LOBBY.upgrades
    LOBBY.class = tostring(fresh.Class)

    -- everything banked and spent, go play
    LOBBY.phase = "starting a run"
    startRun()
end

----------------------------------------------------------------------------
-- farm loop
----------------------------------------------------------------------------
local lastCash     = cashV()
local prevLeaves   = leavesV()
local lastProgress = os.clock()
local emptyStreak  = 0

task.spawn(function()
    while alive() and IN_RUN do
        local ok, err = pcall(function()
            refreshStatus()

            if not CONFIG.auto then
                STATE.phase = "idle"
                lastProgress = os.clock()
                emptyStreak = 0
                return
            end

            -- Hands off while the finisher is pushing the character into the
            -- fall pad. Without this the collector kept warping it back to the
            -- next spot mid-push and the run never ended -- the finisher looked
            -- like it ran (it set its note every time) while the character was
            -- 60 studs away. It only ever worked by hand because AUTO happened
            -- to be off during the test.
            if STATE.finishing then
                -- watchdog: an error inside the finisher must not park the farm
                if os.clock() - STATE.finishAt > 15 then
                    STATE.finishing = false
                else
                    lastProgress = os.clock()
                    return
                end
            end

            local hp = hrp()
            if not hp then
                STATE.phase = "no character"
                lastProgress = os.clock()
                return
            end

            -- void guard: fell through the map or into the fall cutscene
            local d = activeDump()
            local groundY = d and d.pos.Y or (hp.Position.Y - 3)
            if hp.Position.Y < groundY - 25 then
                STATE.phase = "recover"
                if d then warp(d.pos + Vector3.new(0, 4, 0)) end
                task.wait(0.2)
                lastProgress = os.clock()
                return
            end

            -- Progress is leaves the SERVER credited, or cash. On a big bag
            -- deposits are rare, so cash alone would trip the watchdog.
            local money = cashV()
            if money > lastCash then
                lastCash = money
                lastProgress = os.clock()
            end
            local lv = leavesV()
            if lv > prevLeaves then
                lastProgress = os.clock()
                emptyStreak = 0
            end
            prevLeaves = lv

            -- Nothing left that we may take. Either the wave is finished and
            -- the next one has not spawned, or every open zone is done and the
            -- next unlock is waiting on a zone we are not allowed into.
            -- Either way: bank the bag and idle, do not warp around.
            if STATE.workable == 0 then
                STATE.phase = (STATE.field > 0) and "waiting - only locked zones left" or "waiting for the next wave"
                if leavesV() > 0 and CONFIG.autoDeposit then
                    deposit()
                    prevLeaves = leavesV()
                end
                task.wait(1.0)
                lastProgress = os.clock()
                return
            end

            if bagFull() and CONFIG.autoDeposit then
                STATE.phase = "sell"
                deposit()
                prevLeaves = leavesV()
                task.wait(0.1)
                goTo(bestSpot())
                lastProgress = os.clock()
                return
            end

            -- stalled: bank what we have and take a FRESH cluster. Going back
            -- to the dumpster is going back to the empty spot.
            if os.clock() - lastProgress > CONFIG.stuckSeconds then
                STATE.phase = "unstick"
                if leavesV() > 0 and CONFIG.autoDeposit then
                    deposit()
                    prevLeaves = leavesV()
                end
                for _, st in pairs(cellState) do st.farmed = nil end
                markDead(spotKey)
                if not goTo(bestSpot()) then
                    if d then warp(d.pos + Vector3.new(0, 4, 0)) end
                end
                task.wait(0.2)
                emptyStreak = 0
                lastProgress = os.clock()
                return
            end

            STATE.phase = "collect"

            -- The batch fired straight after a hop is the one that gets refused,
            -- and a refused leaf is a destroyed leaf that the zone's goal never
            -- gets back. So probe with a SINGLE leaf, and the nearest one --
            -- collectHere sorts by distance, and single close collects have not
            -- failed once in testing. A three-leaf probe was costing 3 per hop:
            -- 46 hops came to 161 lost, and a whole map only has ~13k leaves
            -- against goals that need every one of them.
            local got, tried = 0, 0
            if justHopped then
                for _ = 1, 4 do
                    local g, t = collectHere(1)
                    got += g
                    tried += t
                    if g > 0 or t == 0 then break end
                    task.wait(0.4)
                end
                justHopped = false
                if got == 0 and tried > 0 then
                    markDead(spotKey or cellKey(hp.Position))
                    note("server has not caught up here, benched")
                    goTo(bestSpot())
                    return
                end
            else
                got, tried = collectHere()
            end

            -- Moving is what costs leaves: from a standing start the server
            -- takes the whole batch, right after a hop it refuses most of it
            -- and collectMany deletes the refused ones anyway. So once a spot
            -- pays, work it dry before hopping again -- that amortises the
            -- settle wait and keeps us in the 100% regime.
            if got > 0 then
                for _ = 1, 8 do
                    if roomLeft() <= 0 then break end
                    local g, t = collectHere()
                    got += g
                    tried += t
                    if g == 0 or t == 0 then break end
                end
            end
            STATE.hitRate = hitRate
            STATE.radius = radiusNow or CONFIG.collectRadius

            -- Nothing in reach, or the server took none of what we sent: this
            -- spot is not workable. Bench it instead of feeding it more leaves.
            if tried == 0 or got == 0 then
                emptyStreak += 1
                if emptyStreak >= 2 then
                    markDead(spotKey or cellKey(hp.Position))
                    markDead(cellKey(hp.Position))
                    note(tried == 0 and "nothing in sight, moving on"
                                    or "server took none here, benched")
                    goTo(bestSpot())
                    emptyStreak = 0
                    return
                end
            else
                emptyStreak = 0
            end

            if countNear(CONFIG.collectRadius + 6) < CONFIG.thinSpot
               and os.clock() - lastHop >= CONFIG.hopCooldown then
                STATE.phase = "roam"
                goTo(bestSpot())
            end
        end)
        if not ok then
            STATE.phase = "error"
            note("loop: " .. tostring(err))
        end
        task.wait(CONFIG.loopTick)
    end
end)

----------------------------------------------------------------------------
-- cutscenes
----------------------------------------------------------------------------
-- Every run opens with a cutscene and ends with one, and both carry a SKIP
-- button. Pressing it is worth real time over a session that plays run after
-- run. `Gui.SkipCutscene` is an ImageButton with one Activated connection, so
-- firing that connection is the game's own handler rather than an invented call.
--
-- Its label is named `Price`, which is why the text is checked and not just the
-- name: right now it reads "SKIP" and the skip is free, but the moment a number
-- or an R$ shows up there this leaves it alone. No Robux, ever.
local function skipCutscene()
    if not CONFIG.autoSkip then return end
    local gui = plr:FindFirstChild("PlayerGui")
    local g = gui and gui:FindFirstChild("Gui")
    local b = g and g:FindFirstChild("SkipCutscene")
    if not (b and b.Visible and b.Active) then return end

    local price = b:FindFirstChild("Price")
    local text = (price and price.Text) or ""
    if text:match("%d") or text:find("R%$") then
        note("skip button shows a price (" .. text .. ") - left alone")
        return
    end

    local ok, cons = pcall(function() return getconnections(b.Activated) end)
    if not ok or not cons then return end
    for _, c in ipairs(cons) do pcall(function() c:Fire() end) end
end

----------------------------------------------------------------------------
-- finishing the run
----------------------------------------------------------------------------
-- The part that was missing for the whole build. An empty map is not a cleared
-- map: every zone respawns in waves and the run timer runs on (measured, the
-- map went to 13079/13079 and the script sat in "waiting for the next wave"
-- while the clock kept ticking). The exit is Workspace.VentPassage, an
-- invisible non-collidable Part with a TouchInterest sitting in the basement
-- vent; entering it plays the end cutscene and the server books the clear.
-- `Completed` is the flag to read, NOT GoalCollected >= GoalTotal. Every zone
-- runs `WavesTotal` waves (2 on The House) and the goal pair counts the CURRENT
-- wave only, so it resets to 0/total when the next one spawns -- watched live,
-- the map total fell 11747 -> 11039 while no zone lost its completion. Reading
-- the goals would fire the finisher as soon as every zone happened to be full on
-- wave 1, long before the run can actually be ended.
local function everyZoneDone()
    local counted = 0
    for _, z in ipairs(zoneList()) do
        local m = z.model
        local total = tonumber(m and m:GetAttribute("GoalTotal")) or 0
        if total > 0 then
            counted += 1
            if m:GetAttribute("Completed") ~= true then return false end
        end
    end
    return counted > 0
end

local finishRetry = 0
local finishFlip = false

-- The Mansion does not end by falling, it ends by CLICKING the door that sits
-- in the middle of its hedge maze (`Map.HatchDoor`, whose upright 6.3x3.6x0.3
-- panel is the door itself -- the flat parts around it are only its frame, and
-- standing on those does nothing). Walking through it does nothing either; the
-- user demonstrated the click. Everything here is the game's own click path:
-- a ClickDetector if there is one, a SurfaceGui button if there is one, and the
-- HatchClicked remote only as a last resort.
local function clickExit(model)
    if not model then return false end

    local panel, any
    for _, c in ipairs(model:GetDescendants()) do
        if c:IsA("BasePart") then
            any = any or c
            -- upright and thin: that is the door leaf rather than its frame
            if c.Size.Y > 2 and c.Size.Y < 8 and (c.Size.Z < 1 or c.Size.X < 1) then
                panel = c
            end
        end
    end
    panel = panel or any
    if not panel then return false end

    -- Stand in front of it and hold, like every other position-gated action in
    -- this game.
    local aim = panel.Position + panel.CFrame.LookVector * 4 - Vector3.new(0, 1.5, 0)
    warp(aim)
    local hold = RunService.Heartbeat:Connect(function()
        local cur = hrp()
        if cur then cur.CFrame = CFrame.new(aim) end
    end)
    task.wait(CONFIG.settle)

    local fired = false
    for _, c in ipairs(model:GetDescendants()) do
        if c:IsA("ClickDetector") and fireclickdetector then
            pcall(fireclickdetector, c, 1)
            pcall(fireclickdetector, c)
            fired = true
        elseif c:IsA("TextButton") or c:IsA("ImageButton") then
            if press(c) then fired = true end
        end
    end

    if not fired then
        local hc = Remotes and Remotes:FindFirstChild("HatchClicked")
        if hc then
            pcall(function() hc:FireServer() end)
            pcall(function() hc:FireServer(model) end)
            fired = true
        end
    end

    task.wait(2.0)
    hold:Disconnect()
    return fired
end

local function finishRun()
    if not CONFIG.autoFinish or not IN_RUN then return end
    if os.clock() < finishRetry then return end
    if not everyZoneDone() then return end

    -- Aim at the hole, not at the door. `VentPassage` is only the entrance; the
    -- part that actually ends the run is `Map.PlayerFalling`, an invisible
    -- 7x1x7 pad about 35 studs further into the tunnel at ~(23.8, 46.5, -65.0).
    -- Targeting the vent's centre meant the character shuffled back and forth in
    -- the doorway forever, which is exactly what it looked like.
    local map = Workspace:FindFirstChild("Map")
    local vent = (map and map:FindFirstChild("PlayerFalling"))
        or Workspace:FindFirstChild("VentPassage")

    -- Not every map ends the same way. The House has PlayerFalling in a vent;
    -- the Mansion has neither that nor VentPassage nor a BasementVent, and its
    -- MapConfig says `finalZone = ALL`. So when the known names are missing,
    -- look for the shape instead: an invisible, non-collidable part with a
    -- TouchInterest that is not a leaf. On a cleared map there is very little
    -- else that matches, and it is checked only once the run is finishable.
    if not (vent and vent:IsA("BasePart")) then
        local best
        for _, v in ipairs(Workspace:GetDescendants()) do
            if v:IsA("BasePart") and v.Transparency > 0.8 and not v.CanCollide
                and v:FindFirstChildOfClass("TouchTransmitter")
                and not v.Name:lower():find("leaf")
                and not (v.Parent and v.Parent.Name:lower():find("leave")) then
                best = v
                break
            end
        end
        vent = best
    end

    -- No fall pad? Then this is a click map. The Mansion is one: its exit is the
    -- door in the middle of the hedge maze and it has to be clicked, not walked
    -- into. (An earlier read of this as "finalZone = ALL means the map ends by
    -- itself" was wrong -- that run was ended by hand.)
    if not (vent and vent:IsA("BasePart")) then
        local door = map and (map:FindFirstChild("HatchDoor") or map:FindFirstChild("EndDoor"))
        if door then
            STATE.phase = "finish"
            STATE.finishing = true
            STATE.finishAt = os.clock()
            note("every zone cleared - clicking the maze door")
            local ok = clickExit(door)
            STATE.finishing = false
            finishRetry = os.clock() + (ok and 25 or 10)
            return
        end
        note("run done but no exit found on this map")
        finishRetry = os.clock() + 60
        return
    end
    -- Short, because the approach side flips on every attempt: a long gate meant
    -- a wrong first guess cost half a minute of standing around.
    finishRetry = os.clock() + 6

    -- Anything still in the bag is paid on deposit and thrown away by the run
    -- ending, so sell before leaving rather than after.
    if leavesV() > 0 then pcall(deposit) end

    STATE.phase = "finish"
    STATE.finishing = true
    STATE.finishAt = os.clock()
    note("every zone cleared - dropping into the vent")

    -- The character has to MOVE through this part under physics. Everything
    -- cheaper was measured and failed: warping through it fired 18 Touched
    -- events client side and the run did not end, the same crossing stretched
    -- over 4 seconds did not either, `firetouchinterest` on it did not, and
    -- `BasementVentClick:FireServer()` from right beside it did not. The spy was
    -- then armed for a manual walk-through and recorded **zero** outgoing calls,
    -- so there is no remote to reproduce at all -- the server runs its own
    -- Touched here and does not believe a character that arrived by CFrame.
    --
    -- Humanoid:MoveTo is no good either: the game pins WalkSpeed at 0 once the
    -- map is clear, so the order is issued and the character does not move a
    -- stud. Writing AssemblyLinearVelocity every frame sidesteps the Humanoid
    -- while still being real replicated physics, and that is what works.
    -- Drop straight in. A horizontal shove across the pad was tried first and it
    -- overshot: at 26 studs/s the character sailed past the tube and fell into
    -- the void beside it, coming back at y -240 / -178 / -65 over and over. The
    -- pad is 7x1x7 and the tube under it is the whole target, so the only aim
    -- that cannot miss is its centre from directly above, with gravity doing the
    -- moving. That is still real physics, which is what the server wants to see.
    -- Just above the pad, not 14 studs up: there is solid floor between the two,
    -- so dropping from height lands on that floor and the character stands there
    -- at y 59 with the pad at 46.5, going nowhere.
    local above = vent.Position + Vector3.new(0, 2.5, 0)

    local hp = hrp()
    if not hp then return end
    hp.Anchored = false
    warp(above)
    task.wait(0.35)

    -- Kill the sideways drift every frame or the leftover velocity from the last
    -- hop carries the fall off centre, and drive downwards rather than waiting
    -- for gravity: from 2.5 studs a free fall is far too gentle to punch through
    -- and the character just sits on the pad.
    local push = RunService.Heartbeat:Connect(function()
        local cur = hrp()
        if cur then
            cur.AssemblyLinearVelocity = Vector3.new(0, -28, 0)
        end
    end)

    -- The vent drops you into the ending sequence, so falling out of the floor
    -- is the success signal, not a bug.
    local t0 = os.clock()
    local fell = false
    while os.clock() - t0 < 4 do
        if not alive() then break end
        local cur = hrp()
        if not cur then break end
        if cur.Position.Y < vent.Position.Y - 25 then fell = true break end
        task.wait(0.1)
    end
    push:Disconnect()

    -- Once it is through, back off -- but not for long. The ending plays out
    -- before the teleport and a 6s retry kept shoving the character back into
    -- the hole the whole time; 120s was the other extreme, because a drop that
    -- does NOT end the run leaves the bot standing on the upper floor at y 67
    -- with every condition met and nothing happening. 25s covers the ending and
    -- still recovers on its own.
    if fell then finishRetry = os.clock() + 25 end
    -- Give the fall sequence a moment before the collector is allowed to move
    -- the character again, or it warps straight back out of it.
    task.wait(2.5)
    STATE.finishing = false
end

----------------------------------------------------------------------------
-- spend loop
----------------------------------------------------------------------------
task.spawn(function()
    while alive() and IN_RUN do
        if CONFIG.auto then
            pcall(finishRun)
            pcall(objectives)
            pcall(buyBag)
            pcall(buyRake)
            pcall(buyVents)
            pcall(buyUpgrades)
        end
        task.wait(1.5)
    end
end)

----------------------------------------------------------------------------
-- lobby loop
----------------------------------------------------------------------------
-- One pass is enough: claim, spend, confirm a run. It repeats slowly so that
-- coming back from a finished run picks the next round up on its own.
task.spawn(function()
    while alive() and not IN_RUN do
        if CONFIG.auto then
            local ok, err = pcall(lobbyTick)
            if not ok then
                LOBBY.phase = "error"
                LOBBY.note = tostring(err)
            end
        else
            LOBBY.phase = "idle"
        end
        task.wait(6)
    end
end)

----------------------------------------------------------------------------
-- anti afk
----------------------------------------------------------------------------
do
    local VirtualUser = game:GetService("VirtualUser")
    if _G.__LEAVES_IDLE then pcall(function() _G.__LEAVES_IDLE:Disconnect() end) end
    _G.__LEAVES_IDLE = plr.Idled:Connect(function()
        if CONFIG.antiAfk and alive() then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end
    end)
end

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------
-- Set _G.__LEAVES_NOPANEL before executing to run headless. Used to bisect a
-- crash by halves; also handy if the panel is not wanted at all.
if _G.__LEAVES_NOPANEL then
    _G.__LEAVES_DBG = { CONFIG = CONFIG, STATE = STATE, LOBBY = LOBBY, IN_RUN = IN_RUN,
                        lobbyTick = lobbyTick, myData = myData, startRun = startRun }
    print("[leaves] headless, gen " .. GEN)
    return
end

-- A missing ui-template must not take the rest down with it -- the loops matter
-- more than the panel.
-- Under the hub the template is already loaded and shared; readfile is the
-- fallback for a run shipped by hand with `bridge.py file`.
local okUI, UI = pcall(function()
	return (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
end)
if not okUI or type(UI) ~= "table" then
    warn("[leaves] ui-template.lua missing from the workspace folder - no panel")
    _G.__LEAVES_DBG = { CONFIG = CONFIG, STATE = STATE, LOBBY = LOBBY }
    return
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
-- lobbyGroup is skipped: the script switches it off by itself the moment the
-- group reward is not claimable, and saved that would stay off for good - a
-- player who joins the group later would never see it try again.
UI.config("cleanleaves", CONFIG, { skip = { lobbyGroup = true } })

local win = UI.Window({
    name = "CleanLeaves", title = "CLEAN", accentTitle = "LEAVES",
    subtitle = "seltonmt", badge = "🍂", width = 900, height = 560,
})
_G.__LEAVES_UI = win

local farming = win:Page("FARMING", UI.icon.bag)
local mainCard = farming:Card("FARM", 1)
mainCard:Toggle("AUTO", CONFIG.auto, function(v)
    CONFIG.auto = v
    saveAuto()
    if v then
        STATE.cashStart = cashV()
        STATE.startClock = os.clock()
    end
end, "collect, sell, buy bag - the whole loop", UI.theme.good)
mainCard:Toggle("Auto sell", CONFIG.autoDeposit, function(v) CONFIG.autoDeposit = v end,
    "empty the bag at the richest dumpster your zone allows")
mainCard:Toggle("Smooth movement", CONFIG.smooth, function(v) CONFIG.smooth = v end,
    "glide between piles instead of snapping")
mainCard:Toggle("Respect zone locks", CONFIG.zoneAware, function(v)
    CONFIG.zoneAware = v
    openCache, openCacheAt = {}, 0
end, "on skips locked zones - measured pointless, they count their goal too", UI.theme.warn)
mainCard:Slider("Collect radius", 10, 30, CONFIG.collectRadius, function(v) CONFIG.collectRadius = v end)
mainCard:Slider("Batch size", 20, 200, CONFIG.batchMax, function(v) CONFIG.batchMax = v end)

local spendCard = farming:Card("SPEND", 2)
spendCard:Toggle("Buy bag capacity", CONFIG.autoBag, function(v) CONFIG.autoBag = v end,
    "25 -> 75 -> 500 -> 1000 for 2 / 10 / 35 cash", UI.theme.warn)
spendCard:Toggle("Buy the Rake", CONFIG.autoRake, function(v) CONFIG.autoRake = v end,
    "7.99 cash, only after the bag ladder is done", UI.theme.warn)
spendCard:Toggle("Unlock vents", CONFIG.autoVent, function(v) CONFIG.autoVent = v end,
    "1 cash each, they pay on the spot instead of in the bag", UI.theme.warn)
spendCard:Toggle("Buy tool upgrades", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
    "measured useless for this script - batch collect ignores Grasp", UI.theme.bad)
spendCard:Toggle("Do the objectives", CONFIG.autoObjective, function(v) CONFIG.autoObjective = v end,
    "journal, hand upgrade, garage - the garage gates Rooftop", UI.theme.good)
spendCard:Toggle("Finish the run", CONFIG.autoFinish, function(v) CONFIG.autoFinish = v end,
    "all zones clear -> push through the vent, that is what books the clear", UI.theme.good)
spendCard:Toggle("Skip cutscenes", CONFIG.autoSkip, function(v) CONFIG.autoSkip = v end,
    "presses SKIP, and never when that button shows a price", UI.theme.good)
spendCard:Button("Sell now", function() task.spawn(deposit) end)
spendCard:Button("Finish now", function() task.spawn(finishRun) end, UI.theme.good)
spendCard:Toggle("Anti-AFK", CONFIG.antiAfk, function(v) CONFIG.antiAfk = v end)

local lobbyPage = win:Page("LOBBY", UI.icon.coin)
local lobbyCard = lobbyPage:Card("LOBBY", 1)
lobbyCard:Toggle("Claim daily", CONFIG.lobbyDaily, function(v) CONFIG.lobbyDaily = v end,
    "tries every unticked day; a day that is not due is refused for free")
lobbyCard:Toggle("Claim group reward", CONFIG.lobbyGroup, function(v) CONFIG.lobbyGroup = v end,
    "turns itself off on 'notmember'")
lobbyCard:Toggle("Buy upgrades", CONFIG.lobbyUpgrades, function(v) CONFIG.lobbyUpgrades = v end,
    "Gems, then Cash, then Bag - walk speed never", UI.theme.warn)
lobbyCard:Toggle("Spin for a class", CONFIG.lobbyClassSpin, function(v) CONFIG.lobbyClassSpin = v end,
    "40 diamonds and Starter (no bonus) is 40% of the wheel", UI.theme.bad)
lobbyCard:Toggle("Start a run", CONFIG.lobbyStart, function(v) CONFIG.lobbyStart = v end,
    "stand on a team pad and confirm", UI.theme.good)
lobbyCard:Dropdown("Map", { "Auto", "House", "Mansion" }, CONFIG.lobbyMap,
    function(v) CONFIG.lobbyMap = v end,
    "Auto takes the furthest map that is unlocked")
lobbyCard:Dropdown("Difficulty", { "Easy", "Medium", "Hard", "Impossible" }, CONFIG.lobbyDifficulty,
    function(v) CONFIG.lobbyDifficulty = v end)
lobbyCard:Button("Start now", function() task.spawn(startRun) end, UI.theme.good)

local lobbyStatCard = lobbyPage:Card("ACCOUNT", 2)
local lobbyOut = lobbyStatCard:Readout(10)

local statusPage = win:Page("STATUS", UI.icon.chart)
local liveCard = statusPage:Card("LIVE", 1)
local liveOut = liveCard:Readout(9)
local zoneCard = statusPage:Card("ZONES", 2)
local zoneOut = zoneCard:Readout(12)
local questCard = statusPage:Card("OBJECTIVES", 0)
local questOut = questCard:Readout(17)
local noteCard = statusPage:Card("NOTES", 0)
local noteOut = noteCard:Readout(6)

local notes = {}
local lastNote = ""

task.spawn(function()
    while alive() do
        pcall(function()
            local up = LOBBY.upgrades or {}
            lobbyOut:set({
                "ACCOUNT",
                string.format("  diamonds    %d", LOBBY.diamonds),
                string.format("  class       %s", LOBBY.class),
                "UPGRADES",
                string.format("  gems        %s", tostring(up.Gems or 0)),
                string.format("  cash        %s", tostring(up.Cash or 0)),
                string.format("  bag         %s", tostring(up.BagCapacity or 0)),
                string.format("  walk speed  %s", tostring(up.WalkSpeed or 0)),
                "LOBBY",
                "  " .. LOBBY.phase .. (LOBBY.note ~= "" and (" - " .. LOBBY.note) or ""),
            })

            if not IN_RUN then
                win:SetStatus(string.format("LOBBY   %d diamonds   %s   %s",
                    LOBBY.diamonds, LOBBY.class, LOBBY.phase))
                return
            end

            refreshStatus()
            win:SetStatus(string.format("$%.2f   bag %d/%d   cleared %d   field %d   %s",
                STATE.cash, STATE.leaves, STATE.cap, STATE.cleared, STATE.field, STATE.phase))
            local d = activeDump()
            liveOut:set({
                "MONEY",
                string.format("  cash        %.2f", STATE.cash),
                string.format("  per second  %.3f", STATE.rate),
                string.format("  deposits    %d", STATE.deposits),
                "FIELD",
                string.format("  bag         %d / %d", STATE.leaves, STATE.cap),
                string.format("  workable    %d of %d", STATE.workable, STATE.field),
                string.format("  hit rate    %d%% at r%d", math.floor(STATE.hitRate * 100), STATE.radius),
                string.format("  taken/lost  %d / %d  (lost leaves never return)", STATE.taken, STATE.lost),
                string.format("  zone        %s", STATE.zone),
                string.format("  dumpster    %.2f/leaf", d and d.price or 0),
            })
            zoneOut:set(zoneRows())
            questOut:set(questRows())
            if STATE.note ~= "" and STATE.note ~= lastNote then
                lastNote = STATE.note
                table.insert(notes, 1, "  " .. STATE.note)
                while #notes > 5 do table.remove(notes) end
            end
            local shown = { "LAST ACTIONS" }
            for _, n in ipairs(notes) do shown[#shown + 1] = n end
            noteOut:set(shown)
        end)
        task.wait(0.5)
    end
end)

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste -
-- er ist immer das erste Icon und die Seite, auf der das Panel aufgeht.
pcall(function() win:Home() end)

win:Refresh()

----------------------------------------------------------------------------
-- debug handle: everything drivable from the bridge
----------------------------------------------------------------------------
_G.__LEAVES_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    LeafSim = LeafSim, UpgradeConf = UpgradeConf, BagConf = BagConf,
    collectHere = collectHere, deposit = deposit, bestSpot = bestSpot,
    goTo = goTo, moveTo = moveTo, warp = warp, groundPos = groundPos,
    dumpList = dumpList, activeDump = activeDump, ventList = ventList,
    buyBag = buyBag, buyRake = buyRake, buyVents = buyVents,
    buyUpgrades = buyUpgrades, cheapestUpgrade = cheapestUpgrade,
    objectives = objectives, questRows = questRows, questVal = questVal,
    finishRun = finishRun, everyZoneDone = everyZoneDone, skipCutscene = skipCutscene,
    clickExit = clickExit,
    IN_RUN = IN_RUN, LOBBY = LOBBY, myData = myData, lobbyTick = lobbyTick,
    startRun = startRun, setDifficulty = setDifficulty, press = press,
    selectMap = selectMap, mapCards = mapCards,
    buyLobbyUpgrades = buyLobbyUpgrades, claimDaily = claimDaily,
    claimGroup = claimGroup, spinClass = spinClass, upgradeCost = upgradeCost,
    nextBagPrice = nextBagPrice, zoneRows = zoneRows, fieldLeaves = fieldLeaves,
    workableLeaves = workableLeaves, zoneList = zoneList, zoneOpen = zoneOpen,
    zoneDone = zoneDone, zoneAt = zoneAt, leafAllowed = leafAllowed, MapCfg = MapCfg,
    cellState = cellState, markDead = markDead,
    saveAuto = saveAuto, loadAuto = loadAuto,
}

-- The skip button shows up in the lobby, during the opening cutscene and again
-- at the end, so this watches on both sides rather than living in a loop that is
-- gated on IN_RUN. It is cheap: two FindFirstChild calls and an early out.
task.spawn(function()
    while alive() do
        if CONFIG.auto then pcall(skipCutscene) end
        task.wait(0.4)
    end
end)

-- AUTO is polled rather than only written from its toggle: it is also flipped
-- from the bridge and from the lobby side, and every one of those has to survive
-- the teleport. Re-saving while it is on keeps the timestamp inside the window,
-- so a run that has been going for an hour still counts as a continuation.
task.spawn(function()
    local last
    while alive() do
        if CONFIG.auto ~= last or CONFIG.auto then
            last = CONFIG.auto
            saveAuto()
        end
        task.wait(20)
    end
end)

print("[leaves] loaded, gen " .. GEN .. " - RightShift for the panel")
