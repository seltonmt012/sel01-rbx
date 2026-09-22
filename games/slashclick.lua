--[[
    slashclick.lua - "[SWORDS] +1 Slash Per Click!"  (place 101558013317432)

    Measured against server-side values on 2026-09-22, account hallowasgehtz2.
    The game is a PunchEscape reskin: the whole economy sits in
    ReplicatedStorage.PunchEscapeConfig and every remote is named.

    The loop the game wants:  slash -> Power,  Power breaks the personal wall
    row of a stage,  the stage's win pad pays Wins,  Wins buy swords / auras /
    lucky-block pets,  a rebirth resets Power and Level and doubles everything.

    What was measured, and what this script therefore does:

    * PunchRequest:FireServer(Vector3) is the ONE engine call.  The argument is
      the aim point - the server resolves it against the ACTIVE wall (the lowest
      unbroken one) and against the player's own position, so an arbitrary
      Vector3 is not enough.  Credited rate is ~2.6/s (measured gaps 336-433ms
      while firing 20/s), so firing faster than every 0.15s is wasted packets.
    * A punch that does not reach a wall still pays POWER:  FistPower x
      AuraMultiplier x PetMultiplier x (1 + Rebirths) - measured 2.4/punch with
      sword 2 and one pet, 13.7 power/s at sword 5, 24 power/s after one
      rebirth.
    * A wall breaks in ONE punch when Power >= its MaxHealth, and NOT AT ALL
      below it - 12 punches at Power 1,193 left a 5,000 HP wall untouched, and
      the same wall fell to a single punch once Power passed it.  There is no
      damage accumulation, so the wall table is a straight depth gate.
      MaximumWallPunchDistance is 90 studs and it is enforced on the PLAYER
      position, not on the aim point.
    * WINS COME FROM THE WIN PAD, NOT FROM THE WALLS.  Every stage has
      Stage<N>.WinPart."x1 Win" behind its row; touching it pays StageWins[N],
      teleports you back to spawn and RESETS EVERY WALL.  The user asked the
      obvious question - can we skip the walls and just teleport onto a deep pad?
      Measured: stage 6 pad +0, stage 10 pad +0, stage 15 pad +0, while the
      stage that had actually been broken in that run paid in full.  Re-touching
      a paid pad pays 0 three times in a row.  So the row IS the proof of work
      and the pad is only the payout.
    * That makes the depth the whole economy: stage 4 pays 25, stage 10 pays
      2,500, stage 15 pays 100,000 - per run, for the same ~0.4s per wall.
    * The game ships a FREE full autofarm ("Auto Win", no gamepass):
      AutoWinRequest:FireServer(true) walks the character, punches, claims.
      Measured 2.5 wins/s.  The warp loop in this script measured 4.9 wins/s
      over the same window, so the warp loop is the default and Auto Win is the
      "walk it legit" fallback on the panel.
    * Rebirth: RebirthRequest:FireServer() needs LEVEL, not wins -
      GetRebirthRequirement is 10, 25, 50, 75, 100, ... (+25).  Measured: level
      10 -> 1, Power 2,885 -> 100, Wins 375 kept, sword and aura kept, and the
      power rate went 13.7/s -> 24/s.  A batch rebirth wants the SUM of the
      steps (x10 from zero = 1,135 levels) and is fired as FireServer(count).
    * Swords are ProximityPrompts on the "Fist <n>" pads (Cost in wins, auto
      equipped).  Auras are the wins button inside the aura window - the Robux
      twin sits right next to it and is identified by its price label, never
      fired.  Both were verified: sword 3 cost 5 wins and moved FistPower 2->5,
      aura 1 cost 5 wins and moved AuraMultiplier 1->1.2.
    * Lucky blocks are the cheapest multiplier in the game:
      LuckyBlockOpenRequest:FireServer(tier, "Wins", count) for 10 / 500 /
      25,000 wins in world 1, pets from x1.1 to x3.6, three equip slots, and
      PetMultiplier is their SUM.  One 10-wins block took PetMultiplier
      1.2 -> 2.55.  The server validates the ring position ("STEP INTO THE RING
      FIRST"), so the body is pinned on Heartbeat before the call - a single
      CFrame write is refused.
    * The AFK pads (Train1-9) are ProximityPrompts that farm power hands-free at
      exactly 2 ticks/s x the pad multiplier, and while one is active the server
      IGNORES manual punches (measured: identical 16 credits / 48 power in 8s
      with and without firing).  So a pad is only worth it above x1.3, and the
      script leaves the pad before it punches again.

    Never touched:  the "x5 / x10 / x20 Win" pads (Robux), Train8/Train9
    (gamepass pads), VIP Fists, PurchaseRequest("SkipRebirth"),
    OfflineRewardRequest("Double"), the Lava lucky blocks and every
    DevProduct prompt.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local Config      = require(ReplicatedStorage:WaitForChild("PunchEscapeConfig", 10))
local LuckyConfig = require(ReplicatedStorage:WaitForChild("LuckyBlockConfig", 10))

local Remotes = ReplicatedStorage:WaitForChild("PunchEscapeRemotes", 10)

-- The remotes are split over two containers and nothing says which is which:
-- the punch, the rebirth and the pads live in PunchEscapeRemotes, while the
-- pet and lucky-block ones sit at the top of ReplicatedStorage. A bare
-- WaitForChild on the wrong one yields FOREVER, which parks the whole script
-- (and the bridge with it) with no error at all - so every lookup below is
-- bounded and the script refuses to start rather than hang.
local function remote(name)
    local found = (Remotes and Remotes:FindFirstChild(name))
        or ReplicatedStorage:FindFirstChild(name)
    if found then return found end
    found = ReplicatedStorage:WaitForChild(name, 5)
    return found
end

local PunchRequest       = remote("PunchRequest")
local RebirthRequest     = remote("RebirthRequest")
local AutoWinRequest     = remote("AutoWinRequest")
local MovementSpeed      = remote("MovementSpeedRequest")
local WorldTeleport      = remote("WorldTeleportRequest")
local SettingsPreference = remote("SettingsPreferenceRequest")
local OfflineReward      = remote("OfflineRewardRequest")
local GroupReward        = remote("GroupRewardRequest")
local AFKExitRequest     = remote("AFKExitRequest")
local PetInventoryAction = remote("PetInventoryAction")
local LuckyOpen          = remote("LuckyBlockOpenRequest")
local LuckyResult        = remote("LuckyBlockOpenResult")

if not (PunchRequest and RebirthRequest) then
    warn("[slashclick] the punch remotes are missing - wrong game?")
    return
end

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    autoRun       = true,   -- the warp loop: break the row, claim the pad, repeat
    autoClaim     = true,   -- touch the deepest cleared stage's x1 pad
    gameAutoWin   = false,  -- instead: the game's own Auto Win, which walks
    autoTrain     = true,   -- AFK pad while Power is the thing blocking the run
    autoDrop      = true,   -- grab the free sword the server drops on the map
    autoSword     = true,   -- best affordable sword of this world, never a downgrade
    autoAura      = true,   -- best affordable aura, wins button only
    autoLucky     = true,   -- lucky blocks with wins, pets are a straight multiplier
    autoPets      = true,   -- AutoMerge + EquipBest after every batch
    autoRebirth   = true,   -- fires the moment the level gate is reached
    multiRebirth  = true,   -- x10 / x100 / x1000 when the level covers the sum
    gameRebirth   = true,   -- and switch the game's OWN auto rebirth on as well
    autoWorld     = true,   -- move up a world once the server unlocks it
    autoSpeed     = true,   -- walkspeed to the maximum the level allows
    autoRewards   = true,   -- offline pile and the group reward
    luckyShare    = 0.25,   -- never spend more than this share of wins on blocks
    luckyBatch    = 10,     -- blocks per call
    keepPets      = 30,     -- everything below this rank is deleted
    punchGap      = 0.15,   -- ~2.6 credited punches/s, the server's own ceiling
    claimWait     = 1.6,    -- the pad teleports you home; give it time
    trainMin      = 1.3,    -- a pad is only better than slashing above this
    trainSeconds  = 25,     -- one AFK stint before the run is tried again
    stallRuns     = 2,      -- runs at the same depth before the pad is used
    maxPunches    = 900,    -- the deepest stage a single run may plan for
    runCap        = 180,    -- hard stop on one run, seconds
    stageCap      = 45,     -- give up on ONE stage after this and bank the run
}

local STATE = {
    power = 0, wins = 0, rebirths = 0, level = 0, levelNeed = 0,
    world = 1, stage = 0, deepest = 0, bestStage = 0,
    target = 0, costEstimate = 0, lastDeepest = 0, stalls = 0,
    earned = 0, saving = 0, startClock = os.clock(),
    runs = 0, claims = 0, rebirthsDone = 0, blocks = 0, swords = 0, auras = 0,
    fist = 0, aura = 1, pet = 1, train = 1, wallHp = 0,
    phase = "starting", note = "starting", running = true, uiOwner = nil,
}

_G.__SLASHCLICK = (_G.__SLASHCLICK or 0) + 1
local GEN = _G.__SLASHCLICK
local function alive() return _G.__SLASHCLICK == GEN end

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

local function abbreviate(n)
    n = tonumber(n) or 0
    local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
    for _, u in ipairs(units) do
        if n >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
    end
    return string.format("%.0f", n)
end

----------------------------------------------------------------------------
-- oracles.  every number below is the server's own replicated value.
----------------------------------------------------------------------------

local Numeric = LocalPlayer:WaitForChild("NumericStats", 10)
local Stats   = LocalPlayer:WaitForChild("PlayerStats", 10)

local function num(folder, name, fallback)
    local v = folder and folder:FindFirstChild(name)
    return v and v.Value or fallback
end

local function power()    return num(Numeric, "Power", 0) end
local function wins()     return num(Numeric, "Wins", 0) end
local function rebirths() return num(Numeric, "Rebirths", 0) end
local function level()    return num(Stats, "Level", 1) end
local function fistPower()return num(Stats, "FistPower", 1) end
local function afkPad()   return num(Stats, "AFKPad", 0) end
local function worldNow() return LocalPlayer:GetAttribute("CurrentWorld") or num(Stats, "CurrentWorld", 1) end
local function worldMax() return LocalPlayer:GetAttribute("MaxWorldUnlocked") or num(Stats, "MaxWorldUnlocked", 1) end

local function character()
    local char = LocalPlayer.Character
    if not char then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return char, root, hum
end

local function worldFolder(index)
    local worlds = workspace:FindFirstChild("Worlds")
    return worlds and worlds:FindFirstChild("World " .. (index or worldNow()))
end

local function worldSpec(index)
    return Config.Worlds[index or worldNow()]
end

----------------------------------------------------------------------------
-- body control.  the server re-checks the position on every pad, prompt and
-- lucky block, and a single CFrame write is not enough for any of them - the
-- refusal reads as a broken remote ("STEP INTO THE RING FIRST") rather than as
-- a position problem, which is exactly the trap in traps.md.
----------------------------------------------------------------------------

local pinTarget = nil
local pinConn

local function startPin()
    if pinConn then return end
    pinConn = RunService.Heartbeat:Connect(function()
        if not alive() then pinConn:Disconnect() pinConn = nil return end
        local _, root = character()
        if root and pinTarget then root.CFrame = CFrame.new(pinTarget) end
    end)
end

local function pin(position, seconds)
    pinTarget = position
    startPin()
    if seconds then task.wait(seconds) end
end

local function unpin()
    pinTarget = nil
end

local function warp(position)
    local _, root = character()
    if not root then return false end
    root.CFrame = CFrame.new(position)
    return true
end

----------------------------------------------------------------------------
-- walls.  one personal set per client, 10 walls per stage, 90 stages across
-- the six worlds.  the active wall is the lowest unbroken one INSIDE the
-- current world - a broken wall is CanQuery = false and fully transparent.
----------------------------------------------------------------------------

local function wallFolder()
    return workspace:FindFirstChild("PunchEscapePersonalWalls")
end

local function activeWall()
    local folder = wallFolder()
    local spec = worldSpec()
    if not folder or not spec then return nil end
    local best, bestKey
    for _, part in ipairs(folder:GetChildren()) do
        if part:IsA("BasePart") and part:GetAttribute("PersonalWall") then
            local stage = part:GetAttribute("Stage")
            if stage and stage >= spec.FirstStage and stage <= spec.LastStage
               and part.CanQuery and part.Transparency < 1 then
                local key = stage * 100 + (part:GetAttribute("WallOrder") or 0)
                if not bestKey or key < bestKey then best, bestKey = part, key end
            end
        end
    end
    return best
end

-- The deepest stage whose row is ACTUALLY finished.  Breaking walls happens in
-- order, so that is simply the stage in front of the active wall - and getting
-- this wrong is what made the script walk onto the stage 16 pad with six walls
-- of stage 16 still standing, where the pad paid exactly nothing and the whole
-- run was thrown away.  Never mark a stage from a single wall that fell.
local function deepestCleared()
    local spec = worldSpec()
    if not spec then return 0 end
    local wall = activeWall()
    if not wall then return spec.LastStage end
    return (wall:GetAttribute("Stage") or spec.FirstStage) - 1
end

local function winPad(stage)
    local folder = worldFolder()
    local walls  = folder and folder:FindFirstChild("Destructable walls")
    local entry  = walls and walls:FindFirstChild("Stage" .. stage)
    local part   = entry and entry:FindFirstChild("WinPart")
    -- "x1 Win" is the free one.  x5 / x10 / x20 are the Robux twins and are
    -- never touched, which is why the name is spelled out instead of scanned.
    return part and part:FindFirstChild("x1 Win")
end

local function stageWins(stage)
    return Config.StageWins[stage] or 0
end

-- A slash deals exactly the current Power as damage to the active wall and the
-- damage ACCUMULATES - measured on a 15,000 HP wall at Power 12,150: one slash
-- left 2,850, the next one broke it, and the Power balance never dropped, so
-- Power is a damage stat and not ammunition.  Depth is therefore not a wall
-- the run cannot pass, it is only a number of slashes.
local function punchesFor(stage, have)
    local wall = Config.Walls[stage]
    if not wall then return math.huge end
    return 10 * math.max(1, math.ceil(wall.MaxHealth / math.max(have, 1)))
end

-- Which stage is worth running.  A claim pays StageWins[S] but the run has to
-- break every row up to S, so the figure that matters is wins per slash and
-- there is a clear optimum: the payout climbs ~2.5x a stage while the wall
-- health climbs 3-5x.
local function bestTarget()
    local spec = worldSpec()
    if not spec then return 0, 0, 0 end
    local have = power()
    local best, bestScore, bestCost = spec.FirstStage, -1, 0
    local cumulative = 0
    for stage = spec.FirstStage, spec.LastStage do
        cumulative = cumulative + punchesFor(stage, have)
        if cumulative > CONFIG.maxPunches then break end
        local score = stageWins(stage) / cumulative
        if score > bestScore then best, bestScore, bestCost = stage, score, cumulative end
    end
    return best, bestScore, bestCost
end

local function reachableStage()
    return (bestTarget())
end

----------------------------------------------------------------------------
-- the engine
----------------------------------------------------------------------------

local function punchAt(position)
    PunchRequest:FireServer(position)
end

-- claim the deepest stage that is actually broken in this run.  claiming
-- resets every wall, so a shallow claim throws the whole run away.
local function claimStage(stage)
    local pad = winPad(stage)
    if not pad then note("stage %d has no win pad", stage) return false end
    local before = wins()
    pin(pad.Position + Vector3.new(0, 4, 0), CONFIG.claimWait)
    unpin()
    local gained = wins() - before
    if gained > 0 then
        STATE.claims = STATE.claims + 1
        STATE.earned = (STATE.earned or 0) + gained
        STATE.bestStage = math.max(STATE.bestStage, stage)
        note("stage %d claimed +%s wins", stage, abbreviate(gained))
        return true
    end
    note("stage %d pad paid nothing", stage)
    return false
end

-- AFK pads: RequiredRebirths is enforced by the server and a GamePassId means
-- Robux, so both are filtered out before the best multiplier is picked.
local function bestPad()
    local folder = worldFolder()
    local train  = folder and folder:FindFirstChild("Train")
    if not train then return nil end
    local have = rebirths()
    local best, bestMult
    for _, pad in ipairs(train:GetChildren()) do
        local mult = pad:GetAttribute("PowerMultiplier")
        local need = pad:GetAttribute("RequiredRebirths") or 0
        local pass = pad:GetAttribute("GamePassId") or 0
        if mult and pass == 0 and have >= need then
            if not bestMult or mult > bestMult then best, bestMult = pad, mult end
        end
    end
    return best, bestMult or 1
end

local function leavePad()
    if afkPad() > 0 then
        AFKExitRequest:FireServer()
        task.wait(0.4)
    end
    unpin()
end

-- power farming.  two engines, and the pad is only the better one above x1.3:
-- it ticks exactly 2/s while a manual punch credits ~2.6/s, and the server
-- ignores manual punches entirely while a pad is active.
local function farmPower(seconds, aim)
    local pad, mult = bestPad()
    local deadline = os.clock() + seconds

    if CONFIG.autoTrain and pad and mult >= CONFIG.trainMin then
        local prompt = pad:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then
            STATE.phase = string.format("AFK pad x%.2f", mult)
            pin(pad.Position + Vector3.new(0, 4, 0), 1.0)
            pcall(fireproximityprompt, prompt)
            while alive() and STATE.running and os.clock() < deadline and afkPad() > 0 do
                task.wait(0.5)
            end
            leavePad()
            return
        end
    end

    STATE.phase = "slashing for power"
    while alive() and STATE.running and os.clock() < deadline do
        local target = aim
        if not target then
            local _, root = character()
            target = root and (root.Position + Vector3.new(0, 0, -6))
        end
        if target then punchAt(target) end
        task.wait(CONFIG.punchGap)
    end
end

-- Every few minutes the server drops a free sword somewhere on the map and
-- announces it ("A sword has fallen from the sky - find it first to collect
-- it!").  It is a race against the whole server and it despawns in about two
-- minutes, so a warp wins it.  The folder holds a FallenSword model, a pile of
-- CraterRock parts and - this is the part that matters - a SwordDropAnchor part
-- carrying CollectSwordPrompt.  The prompt is a SIBLING of the sword model, not
-- a descendant of it, which is why the first version stood in the crater and
-- collected nothing.
local function collectSwordDrop()
    if not CONFIG.autoDrop then return false end
    local folder = workspace:FindFirstChild("ActiveSwordDrop")
    if not folder then return false end

    local prompt
    for _, item in ipairs(folder:GetDescendants()) do
        if item:IsA("ProximityPrompt") then prompt = item break end
    end
    if not prompt then return false end

    local anchor = prompt.Parent
    if not (anchor and anchor:IsA("BasePart")) then return false end

    local before = #(LocalPlayer:FindFirstChild("SwordUnlocks")
        and LocalPlayer.SwordUnlocks:GetChildren() or {})

    STATE.phase = "grabbing the dropped sword"
    pin(anchor.Position + Vector3.new(0, 3, 0), 1.4)
    pcall(fireproximityprompt, prompt)
    task.wait(math.max(prompt.HoldDuration or 0, 0.8))
    unpin()

    local after = #(LocalPlayer:FindFirstChild("SwordUnlocks")
        and LocalPlayer.SwordUnlocks:GetChildren() or {})
    STATE.drops = (STATE.drops or 0) + 1
    if after > before then
        note("collected the dropped sword")
    else
        note("went for the dropped sword (%d in the case)", after)
    end
    return true
end

-- one run: slash down the rows from the first unbroken wall to the target
-- stage, then touch that stage's pad.  The claim resets every wall, so the run
-- is worth exactly one claim and it must be the deepest one reached.
local function runOnce()
    local spec = worldSpec()
    if not spec then note("world %d unknown", worldNow()) task.wait(1) return end

    -- the server ignores every manual slash while an AFK pad is held, and that
    -- reads exactly like a wall that refuses to break.  Cost an hour here.
    leavePad()

    local target, score, cost = bestTarget()
    STATE.target, STATE.costEstimate = target, cost
    local deepest = spec.FirstStage - 1
    local started = os.clock()
    local onWall, wallPunches = nil, 0
    local stageAt, stageStarted = nil, os.clock()

    while alive() and STATE.running and CONFIG.autoRun do
        local wall = activeWall()
        if not wall then deepest = spec.LastStage break end

        local stage = wall:GetAttribute("Stage") or 0
        STATE.stage = stage
        if stage ~= stageAt then stageAt, stageStarted = stage, os.clock() end
        if collectSwordDrop() then stageStarted = os.clock() end

        -- Do not sit on one stage forever.  Everything behind it is already
        -- broken and the pad behind THAT stage pays right now, so banking the
        -- run, spending the wins on a better sword and coming back is strictly
        -- faster than grinding a row the current power cannot carry.
        deepest = deepestCleared()
        if os.clock() - stageStarted > CONFIG.stageCap and deepest >= spec.FirstStage then
            note("stage %d too slow, banking stage %d instead", stage, deepest)
            break
        end
        STATE.wallHp = wall:GetAttribute("CurrentHealth") or wall:GetAttribute("MaxHealth") or 0
        -- Power multiplies several times over during a single run (every slash
        -- pays), so the plan made at the start is always the pessimistic one.
        -- Re-cost it at each stage boundary and push the target deeper when the
        -- arithmetic has moved; never pull it back, the row is already broken.
        if stage > target then
            local again = bestTarget()
            if again > target then
                target = again
                STATE.target = target
            else
                break
            end
        end

        local _, root = character()
        if not root then task.wait(0.5) break end
        -- MaximumWallPunchDistance is 90 and it is checked against the PLAYER,
        -- not against the aim point, so the body only moves when it drifts out.
        if (wall.Position - root.Position).Magnitude > 60 then
            warp(wall.Position + Vector3.new(0, 3, 12))
            task.wait(0.15)
        end

        punchAt(wall.Position)
        task.wait(CONFIG.punchGap)

        if wall.Parent and wall.CanQuery and wall.Transparency < 1 then
            if wall == onWall then wallPunches = wallPunches + 1 else onWall, wallPunches = wall, 1 end
            -- a wall that will not fall is nearly always the position check,
            -- not the damage: step right in front of it and try again.
            if wallPunches % 25 == 0 then
                warp(wall.Position + Vector3.new(0, 3, 8))
                task.wait(0.3)
            end
            if wallPunches > 200 then
                note("stage %d wall will not fall, backing off", stage)
                break
            end
        else
            onWall, wallPunches = nil, 0
        end

        if os.clock() - started > CONFIG.runCap then
            note("run capped at %ds on stage %d", CONFIG.runCap, stage)
            break
        end
    end

    deepest = deepestCleared()
    STATE.deepest = deepest
    STATE.runs = STATE.runs + 1

    if deepest >= spec.FirstStage and CONFIG.autoClaim then
        STATE.phase = "claiming stage " .. deepest
        claimStage(deepest)
        task.wait(0.4)
    end

    -- the depth stopped moving: an AFK pad multiplies the power gain by far
    -- more than slashing a wall does, and power is what shortens every row.
    if deepest <= STATE.lastDeepest and deepest < spec.LastStage then
        STATE.stalls = STATE.stalls + 1
    else
        STATE.stalls = 0
    end
    STATE.lastDeepest = deepest

    if CONFIG.autoTrain and STATE.stalls >= CONFIG.stallRuns then
        STATE.stalls = 0
        STATE.phase = "training"
        farmPower(CONFIG.trainSeconds, nil)
        leavePad()
    end
end

----------------------------------------------------------------------------
-- spending
----------------------------------------------------------------------------

-- swords sit on numbered pads inside the world.  the prompt is the game's own
-- purchase path, the cost is in wins and the sword is equipped by the server.
local function buySword()
    local spec = worldSpec()
    local folder = worldFolder()
    local fists = folder and folder:FindFirstChild("Fists")
    if not spec or not fists then return end

    local have, balance = fistPower(), wins()
    local want, wantPower
    for index = spec.FirstFist, spec.LastFist do
        local entry = Config.Fists[index]
        -- rank against what is WORN.  "best affordable" bought a downgrade in
        -- three other games in this repo.
        if entry and entry.Cost and entry.Cost <= balance and entry.Power > have then
            if not wantPower or entry.Power > wantPower then want, wantPower = index, entry.Power end
        end
    end
    if not want then return end

    local pad = fists:FindFirstChild("Fist " .. want)
    local prompt = pad and pad:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not prompt then return end

    local anchor = prompt.Parent
    local position = anchor:IsA("BasePart") and anchor.Position or pad:GetPivot().Position
    pin(position + Vector3.new(0, 4, 3), 0.9)
    pcall(fireproximityprompt, prompt)
    task.wait(0.8)
    unpin()

    if fistPower() > have then
        STATE.swords = STATE.swords + 1
        note("sword %d bought, power %s -> %s", want, abbreviate(have), abbreviate(fistPower()))
    end
end

-- auras live in the HUD window, not on a pad.  each row carries two buttons -
-- the wins one and the Robux one - and they are told apart by the price label,
-- never by position, so a layout change cannot make this script spend Robux.
local function buyAura()
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    local ui  = gui and gui:FindFirstChild("PunchEscapeUI")
    local root = ui and ui:FindFirstChild("Root")
    local shade = root and root:FindFirstChild("ModalShade")
    local window = shade and shade:FindFirstChild("AuraWindow")
    local scroller = window and window:FindFirstChild("AuraContent")
    scroller = scroller and scroller:FindFirstChild("AuraScroller")
    if not scroller then return end

    local owned = LocalPlayer:FindFirstChild("OwnedAuras")
    local current = num(Stats, "AuraMultiplier", 1)
    local balance = wins()

    local want, wantMult
    for index, entry in ipairs(Config.Auras) do
        local have = owned and owned:FindFirstChild("Aura" .. index)
        local isOwned = have and have.Value == true
        if entry.Cost and entry.Cost > 0 and entry.Cost <= balance
           and not isOwned and entry.Multiplier > current then
            if not wantMult or entry.Multiplier > wantMult then want, wantMult = index, entry.Multiplier end
        end
    end
    if not want then return end

    local row = scroller:FindFirstChild("Aura" .. want)
    if not row then return end
    local price = tostring(Config.Auras[want].Cost)

    local button
    for _, child in ipairs(row:GetDescendants()) do
        if child:IsA("TextButton") then
            for _, label in ipairs(child:GetDescendants()) do
                if label:IsA("TextLabel") and label.Text == price then button = child break end
            end
        end
        if button then break end
    end
    if not button then return end

    local fired = 0
    for _, conn in ipairs(getconnections(button.Activated)) do
        pcall(function() conn:Fire() end)
        fired = fired + 1
    end
    if fired == 0 then return end
    task.wait(1.2)

    if num(Stats, "AuraMultiplier", 1) > current then
        STATE.auras = STATE.auras + 1
        note("aura %d bought x%.2f for %s wins", want, wantMult, abbreviate(Config.Auras[want].Cost))
    end
end

----------------------------------------------------------------------------
-- pets.  the cheapest multiplier in the game and the one the panel should be
-- loudest about: three slots, PetMultiplier is their sum, and a world-1 tier-1
-- block costs ten wins.
----------------------------------------------------------------------------

local function petList()
    local folder = LocalPlayer:FindFirstChild("PetInventory")
    local pets = {}
    if not folder then return pets end
    for _, entry in ipairs(folder:GetChildren()) do
        pets[#pets + 1] = {
            id = entry.Name,
            mult = entry:GetAttribute("Multiplier") or 0,
            equipped = entry:GetAttribute("Equipped") == true,
            favorite = entry:GetAttribute("Favorite") == true,
            name = entry:GetAttribute("PetName") or entry.Name,
        }
    end
    table.sort(pets, function(a, b) return a.mult > b.mult end)
    return pets
end

local function tierBestMultiplier(tier)
    local templates = ReplicatedStorage:FindFirstChild("LuckyBlockPetTemplates")
    local world = worldNow()
    local name = "Lucky Block " .. tier .. " Pets" .. (world > 1 and (" (World " .. world .. ")") or "")
    local folder = templates and templates:FindFirstChild(name)
    if not folder then return 0 end
    local best = 0
    for _, pet in ipairs(folder:GetChildren()) do
        best = math.max(best, pet:GetAttribute("PetMultiplier") or 0)
    end
    return best
end

local function luckyRing(tier)
    local world = worldNow()
    local name = "LuckyBlockFloorRing" .. tier .. (world > 1 and (" (World " .. world .. ")") or "")
    return workspace:FindFirstChild(name)
end

local function weakestEquipped()
    local worst
    for _, pet in ipairs(petList()) do
        if pet.equipped and (not worst or pet.mult < worst) then worst = pet.mult end
    end
    return worst or 0
end

-- the cheapest sword that is a real upgrade on what is worn, or nil
local function nextSwordCost()
    local spec = worldSpec()
    if not spec then return nil end
    local have = fistPower()
    local cheapest
    for index = spec.FirstFist, spec.LastFist do
        local entry = Config.Fists[index]
        if entry and entry.Power > have and entry.Cost and entry.Cost > 0 then
            if not cheapest or entry.Cost < cheapest then cheapest = entry.Cost end
        end
    end
    return cheapest
end

local function openLuckyBlocks()
    if not (LuckyOpen and LuckyResult) then return end
    local balance = wins()

    -- The starvation pattern from traps.md: a ten-wins block fires every pass
    -- and the sword ladder never gets paid for.  So blocks only get the money
    -- while the next sword is genuinely out of reach - more than twenty times
    -- the balance - and the moment it comes into range the wins are banked.
    local goal = nextSwordCost()
    if goal and balance < goal and goal <= balance * 20 then
        STATE.saving = goal
        return
    end
    STATE.saving = 0

    local budget = balance * CONFIG.luckyShare
    local floor = weakestEquipped()

    local want, wantCost
    for tier = 3, 1, -1 do
        local ok, cost = pcall(LuckyConfig.GetWinsCost, tier, 1)
        cost = ok and cost or nil
        -- a tier whose BEST pet cannot beat the weakest slot is finished
        -- business; buying it again only burns wins.
        if cost and cost <= budget and tierBestMultiplier(tier) > floor then
            want, wantCost = tier, cost
            break
        end
    end
    if not want then return end

    local count = math.clamp(math.floor(budget / wantCost), 1, CONFIG.luckyBatch)
    local ring = luckyRing(want)
    if not ring then return end

    local refused = false
    local conn = LuckyResult.OnClientEvent:Connect(function(_, ok, message)
        if ok == false then refused = true note("lucky block: %s", tostring(message)) end
    end)

    -- two seconds, not one: the server checks its own copy of the position and
    -- a short pin is refused with "STEP INTO THE RING FIRST", which reads as a
    -- broken remote rather than as a body that has not arrived yet.
    local pivot = ring:IsA("BasePart") and ring.Position or ring:GetPivot().Position
    pin(pivot + Vector3.new(0, 4, 0), 2.0)
    local before = wins()
    LuckyOpen:FireServer(want, "Wins", count)
    task.wait(2.5)
    unpin()
    conn:Disconnect()

    local spent = before - wins()
    if spent > 0 then
        STATE.blocks = STATE.blocks + count
        note("opened %d tier-%d blocks for %s wins", count, want, abbreviate(spent))
    elseif not refused then
        note("lucky block tier %d did not charge", want)
    end
end

local function tidyPets()
    if not PetInventoryAction then return end
    pcall(function() PetInventoryAction:FireServer("AutoMerge") end)
    task.wait(0.5)
    pcall(function() PetInventoryAction:FireServer("EquipBest") end)

    local pets = petList()
    if #pets <= CONFIG.keepPets then return end
    local doomed = {}
    for rank = CONFIG.keepPets + 1, #pets do
        local pet = pets[rank]
        if not pet.equipped and not pet.favorite then doomed[#doomed + 1] = pet.id end
    end
    if #doomed > 0 then
        pcall(function() PetInventoryAction:FireServer("BulkDelete", doomed) end)
        note("deleted %d weak pets", #doomed)
    end
end

----------------------------------------------------------------------------
-- rebirth, worlds, speed, free rewards
----------------------------------------------------------------------------

local function rebirthCost(count)
    local have = rebirths()
    local total = 0
    for step = 0, count - 1 do
        total = total + (Config.GetRebirthRequirement(have + step) or math.huge)
    end
    return total
end

-- The game has its OWN auto rebirth switch in the rebirth window and it is
-- free; leaving it on means a rebirth still happens on the exact level even
-- while this script is busy mid-row.  PlayerStats.AutoRebirth is the server's
-- copy of it, so this only ever fires when it is actually off.
local function syncGameRebirth()
    if not (CONFIG.gameRebirth and SettingsPreference) then return end
    local flag = Stats and Stats:FindFirstChild("AutoRebirth")
    if flag and flag.Value ~= true then
        SettingsPreference:FireServer("AutoRebirth", true)
        task.wait(0.4)
        if flag.Value == true then note("the game's own auto rebirth is on") end
    end
end

local function doRebirth()
    local have = level()
    STATE.levelNeed = Config.GetRebirthRequirement(rebirths()) or 0
    if have < STATE.levelNeed then return end

    local count = 1
    if CONFIG.multiRebirth then
        for _, batch in ipairs({ 1000, 100, 10 }) do
            if have >= rebirthCost(batch) then count = batch break end
        end
    end

    local before = rebirths()
    if count > 1 then
        RebirthRequest:FireServer(count)
    else
        RebirthRequest:FireServer()
    end
    task.wait(2)

    local gained = rebirths() - before
    if gained > 0 then
        STATE.rebirthsDone = STATE.rebirthsDone + gained
        note("rebirth x%d -> %d total (x%d strength)", gained, rebirths(), rebirths() + 1)
    end
end

-- Verified 2026-09-22: claiming the stage 15 pad flipped MaxWorldUnlocked to 2
-- and this Prepare/Commit pair moved CurrentWorld 1 -> 2 with the walls, pads,
-- sword pads and lucky-block rings all following.  It only ever fires while the
-- SERVER's own MaxWorldUnlocked is ahead of CurrentWorld, so it cannot push
-- into a world the account has not earned.
local function checkWorld()
    if not WorldTeleport then return end
    local here, unlocked = worldNow(), worldMax()
    if unlocked <= here then return end
    local target = here + 1

    -- The other world's models are streamed out: from inside world 2 the
    -- world-1 sword pads are simply not there ("Fist 13 is not a valid member
    -- of Folder"), and world 2's cheapest sword is 3.5M against world 1's
    -- 250K.  So every affordable upgrade in THIS world is bought before the
    -- door closes behind us.
    if CONFIG.autoSword then
        for _ = 1, 4 do
            local before = fistPower()
            buySword()
            if fistPower() <= before then break end
        end
    end
    WorldTeleport:FireServer("Prepare", target)
    task.wait(1.0)
    WorldTeleport:FireServer("Commit", target)
    task.wait(2.0)
    if worldNow() == target then
        note("moved to world %d", target)
    else
        note("world %d refused the move", target)
    end
end

local function setSpeed()
    if not MovementSpeed then return end
    local want = Config.GetMaxWalkSpeed(level()) or Config.DefaultWalkSpeed
    MovementSpeed:FireServer(want)
end

local function claimFreeRewards()
    if OfflineReward and (LocalPlayer:GetAttribute("OfflineRewardPending") or 0) > 0 then
        OfflineReward:FireServer("Claim")
        task.wait(0.6)
        note("offline reward claimed")
    end
    if GroupReward and LocalPlayer:GetAttribute("GroupRewardClaimed") == false then
        GroupReward:FireServer()
        task.wait(0.6)
    end
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

-- ONE routine owns the body.  Buying a sword, standing in a lucky-block ring
-- and running the wall row all move the character, so the spending pass is not
-- a parallel loop at all - it is called from the run loop between two runs,
-- which is the only moment nothing is mid-warp.  That is the whole interface
-- mutex, and it cannot deadlock because there is only ever one owner.
local lastSpend = 0

local function spendPass(force)
    if not force and os.clock() - lastSpend < 8 then return end
    lastSpend = os.clock()
    STATE.phase = "spending"
    pcall(syncGameRebirth)
    if CONFIG.autoRebirth then pcall(doRebirth) end
    if CONFIG.autoSword then pcall(buySword) end
    if CONFIG.autoAura then pcall(buyAura) end
    if CONFIG.autoLucky then pcall(openLuckyBlocks) end
    if CONFIG.autoPets then pcall(tidyPets) end
    if CONFIG.autoWorld then pcall(checkWorld) end
    unpin()
end

task.spawn(function()
    while alive() do
        if not STATE.running then
            STATE.phase = "paused"
            task.wait(0.6)
        elseif CONFIG.gameAutoWin then
            -- hands the whole thing to the game's own Auto Win: it walks,
            -- punches and claims by itself.  Half the throughput, zero warping.
            if AutoWinRequest and LocalPlayer:GetAttribute("AutoWin") ~= true then
                AutoWinRequest:FireServer(true)
            end
            STATE.phase = "game auto win"
            spendPass()
            task.wait(2)
        elseif CONFIG.autoRun then
            if AutoWinRequest and LocalPlayer:GetAttribute("AutoWin") == true then
                AutoWinRequest:FireServer(false)
                task.wait(0.5)
            end
            STATE.phase = "running"
            local ok, err = pcall(runOnce)
            if not ok then note("run failed: %s", tostring(err)) task.wait(1) end
            spendPass()
        else
            STATE.phase = "idle"
            task.wait(0.8)
        end
    end
end)

loop("speed", 20, function()
    if CONFIG.autoSpeed then setSpeed() end
end)

loop("rewards", 180, function()
    if CONFIG.autoRewards then claimFreeRewards() end
end)

loop("stats", 0.5, function()
    STATE.power, STATE.wins, STATE.rebirths = power(), wins(), rebirths()
    STATE.level = level()
    STATE.levelNeed = Config.GetRebirthRequirement(STATE.rebirths) or 0
    STATE.world = worldNow()
    STATE.fist = fistPower()
    STATE.aura = num(Stats, "AuraMultiplier", 1)
    STATE.pet = num(Stats, "PetMultiplier", 1)
    STATE.train = num(Stats, "TrainMultiplier", 1)
end)

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__SLASHCLICK_WIN then pcall(function() _G.__SLASHCLICK_WIN:Destroy() end) end
if UI.sweep then pcall(UI.sweep, "SLASHCLICK") end

UI.config("slashclick", CONFIG)

local win = UI.Window({
    title = "SLASH", accentTitle = "CLICK", subtitle = "seltonmt",
})
_G.__SLASHCLICK_WIN = win

local farmPage = win:Page("FARMING", UI.icon.sword)

local engine = farmPage:Card("RUN", 1):Accent()
engine:Toggle("Auto run", CONFIG.autoRun, function(v) CONFIG.autoRun = v end,
    "Breaks the wall row stage by stage and claims the pad behind it")
engine:Toggle("Auto claim", CONFIG.autoClaim, function(v) CONFIG.autoClaim = v end,
    "Always the deepest stage reached - a claim resets every wall")
engine:Toggle("Use the game's Auto Win", CONFIG.gameAutoWin, function(v) CONFIG.gameAutoWin = v end,
    "Walks instead of warping. Free, half the wins per second", UI.theme.warn)
engine:Toggle("AFK pad while power is short", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
    "Only above x1.3 - the pad ticks 2/s and blocks manual slashes")
engine:Toggle("Grab dropped swords", CONFIG.autoDrop, function(v) CONFIG.autoDrop = v end,
    "The server drops a free sword every few minutes and it is a race - unproven")

local spend = farmPage:Card("SPENDING", 2)
spend:Toggle("Swords", CONFIG.autoSword, function(v) CONFIG.autoSword = v end,
    "Best sword this world allows, never below the one worn")
spend:Toggle("Auras", CONFIG.autoAura, function(v) CONFIG.autoAura = v end,
    "Wins button only, the Robux twin is identified by its price and skipped")
spend:Toggle("Lucky blocks", CONFIG.autoLucky, function(v) CONFIG.autoLucky = v end,
    "Ten wins for a pet - the cheapest strength in the game")
spend:Toggle("Merge and equip pets", CONFIG.autoPets, function(v) CONFIG.autoPets = v end,
    "AutoMerge, EquipBest, and everything below the keep list is deleted")
spend:Toggle("Rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "Needs levels, not wins. Resets power and level, keeps everything bought", UI.theme.warn)
spend:Toggle("Multi rebirth", CONFIG.multiRebirth, function(v) CONFIG.multiRebirth = v end,
    "x10 / x100 / x1000 once the level covers the whole batch")
spend:Toggle("The game's own auto rebirth", CONFIG.gameRebirth, function(v) CONFIG.gameRebirth = v end,
    "Free switch in the rebirth window - it fires on the exact level, even mid-row")

local extras = farmPage:Card("EXTRAS", 1)
extras:Toggle("Next world", CONFIG.autoWorld, function(v) CONFIG.autoWorld = v end,
    "Moves up as soon as the server unlocks it - world 1 to 2 verified")
extras:Toggle("Walk speed", CONFIG.autoSpeed, function(v) CONFIG.autoSpeed = v end,
    "Raises movement to the cap the current level allows")
extras:Toggle("Free rewards", CONFIG.autoRewards, function(v) CONFIG.autoRewards = v end,
    "Offline pile and the group reward, never the Robux double")
extras:Slider("Lucky block budget %", 5, 80, CONFIG.luckyShare * 100, function(v)
    CONFIG.luckyShare = v / 100
end)
extras:Slider("Slash gap (ms)", 80, 600, CONFIG.punchGap * 1000, function(v)
    CONFIG.punchGap = v / 1000
end)
extras:Slider("Give up on a stage after (s)", 10, 180, CONFIG.stageCap, function(v)
    CONFIG.stageCap = v
end)
extras:Button("Claim the deepest stage now", function()
    task.spawn(function() claimStage(math.max(STATE.deepest, 1)) end)
end)
extras:Button("Open lucky blocks now", function() task.spawn(openLuckyBlocks) end, UI.theme.good)

local readout = farmPage:Card("STATUS", 0)
local out = readout:Readout(11)

task.spawn(function()
    while alive() do
        pcall(function()
            out:set({
                "RUN",
                string.format("  world %d   target stage %d   at stage %d   deepest %d",
                    STATE.world, STATE.target, STATE.stage, STATE.deepest),
                string.format("  runs %d   claims %d   phase %s", STATE.runs, STATE.claims, STATE.phase),
                string.format("  a stage %d run pays %s wins for ~%d slashes",
                    STATE.target > 0 and STATE.target or 1,
                    abbreviate(stageWins(STATE.target > 0 and STATE.target or 1)),
                    STATE.costEstimate or 0),
                "ECONOMY",
                string.format("  wins %s   power %s   rebirths %d",
                    abbreviate(STATE.wins), abbreviate(STATE.power), STATE.rebirths),
                string.format("  level %d/%d   sword %s   aura x%.2f   pets x%.2f",
                    STATE.level, STATE.levelNeed, abbreviate(STATE.fist), STATE.aura, STATE.pet),
                string.format("  bought: %d swords   %d auras   %d blocks%s",
                    STATE.swords, STATE.auras, STATE.blocks,
                    (STATE.saving or 0) > 0 and ("   saving for a %s sword"):format(abbreviate(STATE.saving)) or ""),
                string.format("  earned %s wins   %s/min   wall in front %s HP",
                    abbreviate(STATE.earned or 0),
                    abbreviate((STATE.earned or 0) / math.max((os.clock() - STATE.startClock) / 60, 0.1)),
                    abbreviate(STATE.wallHp or 0)),
                "NOTE",
                "  " .. tostring(STATE.note),
            })
            win:SetStat(1, abbreviate(STATE.wins), "wins")
            win:SetStat(2, abbreviate(STATE.power), "power")
            win:SetStat(3, tostring(STATE.rebirths), "rebirths")
            win:SetStatus(string.format("%s wins   %s power   r%d   stage %d",
                abbreviate(STATE.wins), abbreviate(STATE.power), STATE.rebirths, STATE.stage))
        end)
        task.wait(0.5)
    end
end)

pcall(function()
    win:SetMaster(STATE.running, "Auto Farm running")
    win:OnMaster(function(on)
        STATE.running = on
        if not on then leavePad() end
    end)
end)

pcall(function() win:Home() end)

task.spawn(claimFreeRewards)
task.spawn(setSpeed)

_G.__SLASHCLICK_DBG = {
    CONFIG = CONFIG, STATE = STATE, Config = Config,
    activeWall = activeWall, winPad = winPad, claimStage = claimStage,
    reachableStage = reachableStage, runOnce = runOnce, farmPower = farmPower,
    buySword = buySword, buyAura = buyAura, openLuckyBlocks = openLuckyBlocks,
    tidyPets = tidyPets, doRebirth = doRebirth, checkWorld = checkWorld,
    bestPad = bestPad, petList = petList, pin = pin, unpin = unpin,
    bestTarget = bestTarget, punchesFor = punchesFor, spendPass = spendPass,
}

note("ready - stage %d is the best run at %s power", reachableStage(), abbreviate(power()))
