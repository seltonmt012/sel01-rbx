--!nocheck
-- REDLINER  -  seltonmt / Selux
--
-- A movement shooter that is half swordfight: melee, gun, grapple, dash, slide,
-- wallrun, and a PARRY that stops bullets as well as blades. Three places, all
-- three read from the game's own CEnum.PlaceIds:
--
--     MAIN_PLACE   94987506187454   hub + matchmaking
--     MATCH_PLACE  126691165749976  1v1 / 2v2 duels
--     FFA_PLACE    115875349872417  free-for-all, 12 players
--
-- WHAT WAS MEASURED, AND WHAT WAS NOT -----------------------------------------
--
-- Measured on a live FFA server, 8 entities, 2026-09-06:
--
--   * Enemies replicate in full. Characters are R6 Models in workspace.Entities
--     (NOT the Players service - a Players-keyed pool draws nothing), each with
--     a Humanoid and a Hurtboxes folder holding Head_Hurtbox, 1x1x1,
--     Transparency 1, CanQuery true. Read at 92-326 studs through walls.
--   * The camera write STICKS at RenderPriority.Camera + 1 under
--     CameraType.Custom: a 15 deg yaw write read 0.0000 deg against the wanted
--     CFrame and 15.0000 against the previous one, two frames later. So the aim
--     moves the camera directly and needs no mouse path.
--   * The crosshair reference is UserInputService:GetMouseLocation(). Measured
--     here: GetMouseLocation (597, 8) vs Mouse.X/Y (597, -50) - the 58px
--     GuiInset - and the cursor is FREE in the hub, so ViewportSize/2 is wrong
--     there too. This is the trap that put MvSD's FOV ring off the cursor.
--   * The map carries only 15 invisible-but-collidable parts (2341 total, 3ms
--     scan). There is no CLIP-brush wall like Counter Blox, so the visibility
--     ray needs no hand-maintained ignore list - the property test is enough.
--   * The state oracle is ReplicatedStorage.ReadOnly.Players.<userId> and it
--     replicates for EVERY player: yen, crimson, level, total_xp, killstreak,
--     casual_duel_winstreak, status, in_combat, rtt, equipped_title.
--
-- NOT measured, and the panel says so where it matters:
--
--   * THE PARRY WINDOW. The account never got out of the deploy menu, so no
--     attack was ever aimed at it and the delay between an attacker's animation
--     and the damage landing is unknown. Auto-parry therefore ships OFF, with a
--     delay slider and a live counter of what it actually achieved - see the
--     PARRY section. Nothing here claims a timing it did not measure.
--   * Enemy Humanoid.Health never moved across 356 attack animations in 31s of
--     observation, because everyone watched was swinging in the lobby rather
--     than fighting. So the health bar is drawn from the real property but has
--     not been seen to change; the INFO page states that outright.
--   * No remote is fired by this script AT ALL. The game's packet names are
--     hashed (_x8f3ef40a style, 100+ of them) and its client classes are
--     obfuscated, so the shot path was never reversed. The aim moves the camera,
--     the trigger presses the real mouse button, the parry presses the real
--     parry key. Whatever the server validates, it validates ordinary input.
--
-- THE PARRY SIGNAL ------------------------------------------------------------
--
-- ReplicatedStorage.Assets.Animations names all 76 animations, and the
-- third-person ones replicate to everybody. Recorded live, with counts over
-- ~5 minutes on an 8-player server:
--
--     Redliner.3P_RAerial  135285345042099   225x   <- NOT an attack, see below
--     Redliner.3P_LAerial  117251245513909   218x   <- NOT an attack
--     Redliner.3P_LAttack  105441036119013    89x
--     Redliner.3P_RAttack   87457990259233    47x
--     Redliner.3P_CAttack   71188211641772    27x
--     Castigate/Revolt 3P_Gunshot 110389010823335  21x   (one id for both guns)
--     Redliner.3P_Parry    117005726191901    15x
--     Redliner.3P_Deflect   95210445922999     3x
--
-- So an incoming attack is visible the moment the attacker starts it, which is
-- what an auto-parry needs. Redliner.ParrySuccess (88427023415444) plays on your
-- own character when a parry lands, and that is what the hit counter reads - the
-- feature grades itself instead of being believed.
--
-- ...but the two BIGGEST numbers in that table are not attacks at all, and
-- taking them at face value is what made the first build of the auto-parry
-- useless. The aerials are the jump and fall animations of a movement game where
-- everybody is airborne half the time - logged against our own character they
-- fire nowhere near the clicks that swing the sword. Details at ATTACK_MELEE.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local plr = Players.LocalPlayer
local cam = Workspace.CurrentCamera

--------------------------------------------------------------------------------
-- generation guard
--------------------------------------------------------------------------------
-- Re-executing does not restart the Lua VM, so the previous run's loops, render
-- bindings and Drawing objects are all still alive. Bump the generation, let the
-- loops notice, and clear the PIXELS by hand - a generation guard stops a loop
-- but a Drawing that nothing updates any more just stays on screen.

_G.__REDLINER = (_G.__REDLINER or 0) + 1
local GEN = _G.__REDLINER
local function live() return GEN == _G.__REDLINER end

if _G.__REDLINER_POOL then
    for _, set in pairs(_G.__REDLINER_POOL) do
        for _, obj in pairs(set) do pcall(function() obj:Remove() end) end
    end
end
_G.__REDLINER_POOL = {}
local POOL = _G.__REDLINER_POOL

if _G.__REDLINER_CHAMS then
    for _, hl in pairs(_G.__REDLINER_CHAMS) do pcall(function() hl:Destroy() end) end
end
_G.__REDLINER_CHAMS = {}
local CHAMS = _G.__REDLINER_CHAMS

for _, name in ipairs({ "__REDLINER_AIM", "__REDLINER_ESP" }) do
    pcall(function() RunService:UnbindFromRenderStep(name) end)
end

--------------------------------------------------------------------------------
-- places
--------------------------------------------------------------------------------

local PLACE_MAIN, PLACE_MATCH, PLACE_FFA = 94987506187454, 126691165749976, 115875349872417

local function placeKind()
    local id = game.PlaceId
    if id == PLACE_MAIN then return "HUB" end
    if id == PLACE_FFA then return "FFA" end
    if id == PLACE_MATCH then return "DUEL" end
    -- A duel runs on a reserved server, so its PlaceId is not always one of the
    -- three. The two flags in ReplicatedFirst are what the game itself reads.
    local m = ReplicatedFirst:FindFirstChild("IS_MATCH_PLACE")
    local mm = ReplicatedFirst:FindFirstChild("IS_MATCHMAKING_PLACE")
    if m and m.Value then return "DUEL" end
    if mm and mm.Value then return "HUB" end
    return "?"
end

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
    -- ESP
    esp = true,
    espBox = true,
    espName = true,
    espDist = true,
    -- OFF by default, and that is a measurement: across two live sessions,
    -- 470 attack animations produced ZERO changes in any entity's
    -- Humanoid.Health. The game replicates real health through its own chrono
    -- snapshots and leaves the Humanoid pinned at 100, so the bar would be a
    -- flat green line pretending to be information.
    espHealth = false,
    espHeadDot = false,
    espSkeleton = false,
    espTracer = false,
    espChams = false,
    espMaxDist = 900,
    espVisibleOnly = false,
    espTextSize = 14,
    espFont = "System",
    espColour = Color3.fromRGB(255, 64, 64),

    -- AIM
    aim = false,
    aimActivation = "Hotkey",       -- Hotkey / Always / While firing / Screen held
    aimKey = "MouseButton2",
    aimPart = "Head",               -- Head / Torso / Nearest
    aimPick = "Crosshair",          -- Crosshair / World / Lowest HP
    aimFov = 120,
    aimSmoothH = 8,
    aimSmoothV = 12,
    aimMaxDist = 400,
    aimVisibleOnly = true,
    aimSticky = true,
    aimShowFov = true,

    -- TRIGGER
    trigger = false,
    triggerActivation = "Hotkey",
    triggerKey = "C",
    triggerDelayMin = 60,
    triggerDelayMax = 140,
    triggerHeadOnly = false,
    triggerMaxDist = 400,
    triggerLockout = 250,

    -- PARRY  (UNPROVEN TIMING - see the header)
    parry = false,
    parryKey = "F",
    parryRange = 30,
    parryDelay = 120,               -- ms after the attack animation starts
    parryGun = false,               -- also react to a 3P_Gunshot
    parryGunRange = 250,
    parryFacing = true,             -- only when the attacker is looking at us
    parryCooldown = 350,

    -- KILL AURA  (melee, and this game is a swordfight before it is a shooter)
    aura = false,
    auraActivation = "Hotkey",
    auraKey = "V",
    -- 25, not 18, and not a guess any more: a swing while CLOSING from ~29
    -- studs produced impact effects on the target, one at 40 studs did not.
    auraRange = 25,
    -- The gate that makes this an aura rather than an aimbot: swing only when
    -- the target is ALREADY inside the arc you are looking at. Nothing moves
    -- your camera.
    auraAngle = 45,
    auraFaceTarget = false,         -- opt-in, and it DOES move your camera
    auraInterval = 660,
    auraNeedSword = true,
    auraVisibleOnly = true,

    -- MOVEMENT
    moveBhop = false,
    moveBhopKey = "Space",
    moveBhopRate = 60,
    moveSlide = false,
    moveSlideKey = "LeftControl",
    moveSlideEvery = 1200,

    -- HUMAN
    humanTurnCap = 420,             -- deg/s
    humanWindup = 60,               -- ms
    humanDeadzone = 2,              -- px
    humanReactMin = 40,
    humanReactMax = 110,
}

local DEFAULTS = {}
for k, v in pairs(CONFIG) do DEFAULTS[k] = v end

local STATE = {
    note = "",
    targets = 0,
    drawn = 0,
    target = nil,
    fps = 0,
    parryAttacks = 0,
    parryFired = 0,
    parrySuccess = 0,
    parryLast = "-",
    shots = 0,
    aimStep = 0,
    aimPeak = 0,
    healthMoves = 0,
    healthSamples = 0,
    auraClicks = 0,
    auraSwings = 0,
    auraHits = 0,
    lastSwingAt = 0,
    auraModel = nil,
    lastSwingSeen = 0,
    auraTarget = nil,
    bhops = 0,
    slides = 0,
}

local function note(text) STATE.note = tostring(text) end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
UI.config("redliner", CONFIG)

--------------------------------------------------------------------------------
-- accessors  (all measured, see the header)
--------------------------------------------------------------------------------

local ENTITIES = Workspace:FindFirstChild("Entities")

local function entitiesFolder()
    if ENTITIES and ENTITIES.Parent then return ENTITIES end
    ENTITIES = Workspace:FindFirstChild("Entities")
    return ENTITIES
end

local function myChar() return plr.Character end

local function myRoot()
    local c = myChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- ReplicatedStorage.ReadOnly.Players.<userId>. Keyed by USER ID, not by name, so
-- a name lookup has to go through the Players service first.
local function roFolder()
    local ro = ReplicatedStorage:FindFirstChild("ReadOnly")
    return ro and ro:FindFirstChild("Players")
end

local function roEntry(name)
    local folder = roFolder()
    if not folder then return nil end
    local p = Players:FindFirstChild(name)
    if not p then return nil end
    return folder:FindFirstChild(tostring(p.UserId))
end

local function roValue(name, field, fallback)
    local e = roEntry(name)
    local v = e and e:FindFirstChild(field)
    if v and v:IsA("ValueBase") then return v.Value end
    return fallback
end

-- "Alive" is two things and both are needed: a dead body stays parented (so the
-- model existing proves nothing) and a player sitting in the deploy menu has a
-- character too, at (0, 50, 0), with status "suspended".
local function aliveOf(model)
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    local status = roValue(model.Name, "status", "alive")
    return status ~= "suspended" and status ~= "dead"
end

local function combatants()
    local folder = entitiesFolder()
    local out = {}
    if not folder then return out end
    local mine = myChar()
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") and m ~= mine and m.Name ~= plr.Name then
            local root = m:FindFirstChild("HumanoidRootPart")
            if root and aliveOf(m) then out[#out + 1] = m end
        end
    end
    return out
end

local function headHurtbox(model)
    local hb = model:FindFirstChild("Hurtboxes")
    local part = hb and hb:FindFirstChild("Head_Hurtbox")
    if part and part:IsA("BasePart") then return part end
    return model:FindFirstChild("Head")
end

local function bodyPart(model)
    return model:FindFirstChild("Torso") or model:FindFirstChild("HumanoidRootPart")
end

-- The equipped weapon is readable AND it replicates: every weapon model under a
-- character carries CharacterMotor6D.Equipped, whose Part0 is the limb holding
-- it. Measured: sword in hand -> Redliner.Equipped.Part0 = "Right Arm", gun
-- holstered -> Castigate.Unequipped.Part0 = "Left Leg". It works for every
-- player, which is why the ESP can say who is carrying what - and defined up
-- here, with the other accessors, because a Lua local is invisible above its own
-- definition and the render pass below needs it.
local function equippedWeapon(model)
    for _, m in ipairs(model:GetChildren()) do
        if m:IsA("Model") then
            local motors = m:FindFirstChild("CharacterMotor6D")
            local eq = motors and motors:FindFirstChild("Equipped")
            if eq and eq:IsA("Motor6D") and eq.Part0 then return m.Name end
        end
    end
    return nil
end

local function healthOf(model)
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum then return 0, 100 end
    return hum.Health, math.max(hum.MaxHealth, 1)
end

--------------------------------------------------------------------------------
-- visibility
--------------------------------------------------------------------------------
-- The rule is "everything a BULLET would not stop on", which is not the same as
-- "everything you cannot see". On this map that is 159 fully transparent,
-- non-collidable parts; the 15 invisible-but-solid ones (named "smooth",
-- "invis bump") ARE walls and stay in. Rebuilt on a timer rather than per frame.

local ignore = {}
local ignoreAt = 0

local function rebuildIgnore()
    local list = {}
    local folder = entitiesFolder()
    if folder then
        for _, m in ipairs(folder:GetChildren()) do list[#list + 1] = m end
    end
    local map = Workspace:FindFirstChild("Map")
    if map then
        for _, d in ipairs(map:GetDescendants()) do
            if d:IsA("BasePart") and d.Transparency >= 1 and not d.CanCollide then
                list[#list + 1] = d
            end
        end
    end
    local fx = Workspace:FindFirstChild("Effects")
    if fx then list[#list + 1] = fx end
    local debris = Workspace:FindFirstChild("Debris")
    if debris then list[#list + 1] = debris end
    ignore = list
    ignoreAt = os.clock()
end

local function ignoreList()
    if os.clock() - ignoreAt > 1 then rebuildIgnore() end
    return ignore
end

local function visibleTo(part)
    if not part then return false end
    local origin = cam.CFrame.Position
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignoreList()
    local dir = part.Position - origin
    local hit = Workspace:Raycast(origin, dir, params)
    return hit == nil
end

--------------------------------------------------------------------------------
-- drawing pool
--------------------------------------------------------------------------------
-- Drawing.new objects live outside the DataModel, so no client script of the
-- game can walk the tree and find them. Created once per model, then only
-- shown, hidden and moved - allocating per frame is felt immediately.

local FONTS = { UI = 0, System = 1, Plex = 2, Monospace = 3 }

local function fontId() return FONTS[CONFIG.espFont] or 1 end

local function make(kind, props)
    local ok, obj = pcall(function() return Drawing.new(kind) end)
    if not ok or not obj then return nil end
    for k, v in pairs(props or {}) do pcall(function() obj[k] = v end) end
    return obj
end

local BONES = {
    { "Head", "Torso" },
    { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
    { "Torso", "Left Leg" }, { "Torso", "Right Leg" },
}

local function objectsFor(model)
    local set = POOL[model]
    if set then return set end
    set = {}
    set.box = make("Square", { Thickness = 1, Filled = false, Color = Color3.new(1, 0, 0) })
    set.outline = make("Square", { Thickness = 3, Filled = false, Color = Color3.new(0, 0, 0) })
    set.name = make("Text", { Size = 14, Center = true, Outline = true, Font = 1 })
    set.info = make("Text", { Size = 13, Center = true, Outline = true, Font = 1 })
    set.hpBack = make("Square", { Thickness = 1, Filled = true, Color = Color3.new(0, 0, 0) })
    set.hpFill = make("Square", { Thickness = 1, Filled = true, Color = Color3.new(0, 1, 0) })
    set.head = make("Circle", { Thickness = 1, Filled = false, NumSides = 14 })
    set.tracer = make("Line", { Thickness = 1 })
    set.bones = {}
    for i = 1, #BONES do
        set.bones[i] = make("Line", { Thickness = 1 })
    end
    POOL[model] = set
    return set
end

local function hideSet(set)
    for k, obj in pairs(set) do
        if k == "bones" then
            for _, b in ipairs(obj) do if b then b.Visible = false end end
        elseif obj then
            obj.Visible = false
        end
    end
end

local function hideAll()
    for _, set in pairs(POOL) do hideSet(set) end
end

local function reapPool()
    for model, set in pairs(POOL) do
        if not model.Parent then
            for k, obj in pairs(set) do
                if k == "bones" then
                    for _, b in ipairs(obj) do if b then pcall(function() b:Remove() end) end end
                elseif obj then
                    pcall(function() obj:Remove() end)
                end
            end
            POOL[model] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- chams
--------------------------------------------------------------------------------
-- A Highlight has to be a real Instance, so the only question is where it lives.
-- gethui()/CoreGui with Adornee set renders identically and is not in the game's
-- tree. The candidate list is built by APPENDING: {gethui() or nil, CoreGui} is
-- a nil hole and ipairs stops at it, so the fallback would never be tried.

local chamRoot

local function chamsRoot()
    if chamRoot and chamRoot.Parent then return chamRoot end
    local candidates = {}
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then candidates[#candidates + 1] = hui end
    end
    local ok2, core = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and core then candidates[#candidates + 1] = core end
    candidates[#candidates + 1] = plr:FindFirstChildOfClass("PlayerGui")
    for _, parent in ipairs(candidates) do
        local made = pcall(function()
            local f = Instance.new("Folder")
            f.Name = "RL_" .. tostring(math.random(100000, 999999))
            f.Parent = parent
            chamRoot = f
        end)
        if made and chamRoot then return chamRoot end
    end
    return nil
end

local function chamFor(model)
    local hl = CHAMS[model]
    if hl and hl.Parent then return hl end
    local root = chamsRoot()
    if not root then return nil end
    local ok, made = pcall(function()
        local h = Instance.new("Highlight")
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.FillTransparency = 0.65
        h.OutlineTransparency = 0
        h.Adornee = model
        h.Parent = root
        return h
    end)
    if ok and made then
        CHAMS[model] = made
        return made
    end
    return nil
end

local function clearChams()
    for model, hl in pairs(CHAMS) do
        pcall(function() hl:Destroy() end)
        CHAMS[model] = nil
    end
end

--------------------------------------------------------------------------------
-- geometry
--------------------------------------------------------------------------------

local function dimmed(colour)
    local h, s, v = Color3.toHSV(colour)
    return Color3.fromHSV(h, s, v * 0.55)
end

-- Never Model:GetBoundingBox() - it reports an extent many times the real one
-- for a rigged character. The projected distance between the top of the head and
-- the bottom of the lower foot IS the on-screen height, so it scales with range
-- for free and follows a crouch exactly. R6 has no LeftFoot/RightFoot, so the
-- legs are the bottom.
local function screenRect(model)
    local head = model:FindFirstChild("Head")
    local ll = model:FindFirstChild("Left Leg")
    local rl = model:FindFirstChild("Right Leg")
    local root = model:FindFirstChild("HumanoidRootPart")
    if not head or not root then return nil end
    local low = ll
    if rl and (not ll or rl.Position.Y <= ll.Position.Y) then low = rl end
    local topPos = head.Position + Vector3.new(0, head.Size.Y / 2 + 0.35, 0)
    local botPos = low and (low.Position - Vector3.new(0, low.Size.Y / 2, 0))
        or (root.Position - Vector3.new(0, 3, 0))
    local sTop, onTop = cam:WorldToViewportPoint(topPos)
    local sBot = cam:WorldToViewportPoint(botPos)
    -- Z <= 0 is BEHIND the camera; the X/Y there is mirrored nonsense and drawing
    -- it puts a box on the wrong side of the screen for somebody behind you.
    if sTop.Z <= 0 or sBot.Z <= 0 or not onTop then return nil end
    local h = math.abs(sBot.Y - sTop.Y)
    if h < 3 then return nil end
    local w = h * 0.52
    return sTop.X - w / 2, sTop.Y, w, h
end

local function centreOf()
    local ok, loc = pcall(function() return UserInputService:GetMouseLocation() end)
    if ok and loc then return Vector2.new(loc.X, loc.Y) end
    return cam.ViewportSize / 2
end

--------------------------------------------------------------------------------
-- ESP render pass
--------------------------------------------------------------------------------

local fovCircle = make("Circle", { Thickness = 1, Filled = false, NumSides = 48,
    Color = Color3.fromRGB(200, 200, 200), Transparency = 0.7 })

local lastHealth = {}

local function renderPass()
    if not live() then return end
    local drawn = 0
    local list = combatants()
    STATE.targets = #list

    if not CONFIG.esp then
        hideAll()
        if fovCircle then fovCircle.Visible = false end
        clearChams()
        return
    end

    local root = myRoot()
    local seen = {}

    for _, model in ipairs(list) do
        seen[model] = true
        local set = objectsFor(model)
        local head = model:FindFirstChild("Head")
        local body = bodyPart(model)
        local dist = (root and body) and (root.Position - body.Position).Magnitude or 0

        -- health, sampled here so the INFO page can say honestly whether the
        -- value ever moves at all
        local hp, maxHp = healthOf(model)
        local prev = lastHealth[model]
        if prev and math.abs(prev - hp) > 0.5 then STATE.healthMoves = STATE.healthMoves + 1 end
        lastHealth[model] = hp
        STATE.healthSamples = STATE.healthSamples + 1

        local vis = (not CONFIG.espVisibleOnly) or visibleTo(headHurtbox(model))
        local inRange = dist <= CONFIG.espMaxDist

        -- Chams go OUTSIDE the on-screen gate on purpose: a Highlight is 3D and
        -- is the one thing that should work off screen and through a wall.
        if CONFIG.espChams and inRange then
            local hl = chamFor(model)
            if hl then
                hl.Adornee = model
                hl.FillColor = vis and CONFIG.espColour or dimmed(CONFIG.espColour)
                hl.OutlineColor = CONFIG.espColour
                hl.Enabled = true
            end
        elseif CHAMS[model] then
            CHAMS[model].Enabled = false
        end

        local x, y, w, h = nil, nil, nil, nil
        if inRange and (vis or not CONFIG.espVisibleOnly) then
            x, y, w, h = screenRect(model)
        end

        if not x then
            hideSet(set)
        else
            drawn = drawn + 1
            local colour = vis and CONFIG.espColour or dimmed(CONFIG.espColour)
            local textSize = math.max(12, math.floor(CONFIG.espTextSize))

            if CONFIG.espBox and set.box and set.outline then
                set.outline.Size = Vector2.new(w, h)
                set.outline.Position = Vector2.new(x, y)
                set.outline.Color = Color3.new(0, 0, 0)
                set.outline.Visible = true
                set.box.Size = Vector2.new(w, h)
                set.box.Position = Vector2.new(x, y)
                set.box.Color = colour
                set.box.Visible = true
            else
                if set.box then set.box.Visible = false end
                if set.outline then set.outline.Visible = false end
            end

            if CONFIG.espName and set.name then
                set.name.Text = model.Name
                set.name.Size = textSize
                set.name.Font = fontId()
                set.name.Color = colour
                set.name.Position = Vector2.new(x + w / 2, y - textSize - 2)
                set.name.Visible = true
            elseif set.name then set.name.Visible = false end

            if CONFIG.espDist and set.info then
                local lvl = roValue(model.Name, "level", nil)
                local streak = roValue(model.Name, "killstreak", nil)
                local bits = { math.floor(dist) .. "m" }
                if lvl then bits[#bits + 1] = "lv" .. tostring(lvl) end
                -- who is carrying what: the one thing the HUD never tells you,
                -- and in a game where the sword and the gun play completely
                -- differently it is the most useful word on the box
                local weapon = equippedWeapon(model)
                if weapon then bits[#bits + 1] = weapon end
                if streak and streak > 0 then bits[#bits + 1] = "x" .. tostring(streak) end
                set.info.Text = table.concat(bits, "  ")
                set.info.Size = math.max(12, textSize - 1)
                set.info.Font = fontId()
                set.info.Color = colour
                set.info.Position = Vector2.new(x + w / 2, y + h + 2)
                set.info.Visible = true
            elseif set.info then set.info.Visible = false end

            if CONFIG.espHealth and set.hpBack and set.hpFill then
                local frac = math.clamp(hp / maxHp, 0, 1)
                set.hpBack.Size = Vector2.new(3, h)
                set.hpBack.Position = Vector2.new(x - 6, y)
                set.hpBack.Visible = true
                set.hpFill.Size = Vector2.new(3, h * frac)
                set.hpFill.Position = Vector2.new(x - 6, y + h * (1 - frac))
                set.hpFill.Color = Color3.fromRGB(255 - math.floor(200 * frac), 60 + math.floor(180 * frac), 60)
                set.hpFill.Visible = true
            else
                if set.hpBack then set.hpBack.Visible = false end
                if set.hpFill then set.hpFill.Visible = false end
            end

            if CONFIG.espHeadDot and set.head and head then
                local sp = cam:WorldToViewportPoint(head.Position)
                if sp.Z > 0 then
                    set.head.Radius = math.max(2, h * 0.075)
                    set.head.Position = Vector2.new(sp.X, sp.Y)
                    set.head.Color = colour
                    set.head.Visible = true
                else
                    set.head.Visible = false
                end
            elseif set.head then set.head.Visible = false end

            if CONFIG.espTracer and set.tracer then
                set.tracer.From = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
                set.tracer.To = Vector2.new(x + w / 2, y + h)
                set.tracer.Color = colour
                set.tracer.Visible = true
            elseif set.tracer then set.tracer.Visible = false end

            if CONFIG.espSkeleton and set.bones then
                for i, bone in ipairs(BONES) do
                    local a = model:FindFirstChild(bone[1])
                    local b = model:FindFirstChild(bone[2])
                    local line = set.bones[i]
                    if line and a and b then
                        local pa = cam:WorldToViewportPoint(a.Position)
                        local pb = cam:WorldToViewportPoint(b.Position)
                        if pa.Z > 0 and pb.Z > 0 then
                            line.From = Vector2.new(pa.X, pa.Y)
                            line.To = Vector2.new(pb.X, pb.Y)
                            line.Color = colour
                            line.Visible = true
                        else
                            line.Visible = false
                        end
                    elseif line then
                        line.Visible = false
                    end
                end
            elseif set.bones then
                for _, line in ipairs(set.bones) do if line then line.Visible = false end end
            end
        end
    end

    for model, set in pairs(POOL) do
        if not seen[model] then hideSet(set) end
    end
    for model, hl in pairs(CHAMS) do
        if not seen[model] then hl.Enabled = false end
    end

    if fovCircle then
        if CONFIG.aim and CONFIG.aimShowFov then
            local c = centreOf()
            fovCircle.Position = c
            fovCircle.Radius = CONFIG.aimFov
            fovCircle.Visible = true
        else
            fovCircle.Visible = false
        end
    end

    STATE.drawn = drawn
end

--------------------------------------------------------------------------------
-- input helpers
--------------------------------------------------------------------------------

local TOUCH = UserInputService.TouchEnabled
    and not UserInputService.MouseEnabled
    and not UserInputService.KeyboardEnabled
if _G.__REDLINER_FORCE_TOUCH then TOUCH = true end

local keyCache = {}

local function resolveKey(name)
    if keyCache[name] ~= nil then return keyCache[name] end
    local found = nil
    -- Indexing a Roblox Enum with a name it does not have THROWS rather than
    -- returning nil, so both lookups are wrapped and the answer is cached.
    pcall(function()
        if Enum.UserInputType[name] then found = { kind = "mouse", value = Enum.UserInputType[name] } end
    end)
    if not found then
        pcall(function()
            if Enum.KeyCode[name] then found = { kind = "key", value = Enum.KeyCode[name] } end
        end)
    end
    keyCache[name] = found or false
    return keyCache[name]
end

local function reachable(name)
    local k = resolveKey(name)
    if not k then return false end
    if k.kind == "mouse" then return UserInputService.MouseEnabled end
    return UserInputService.KeyboardEnabled
end

local function screenHeld()
    local ok2, touches = pcall(function() return UserInputService:GetMouseButtonsPressed() end)
    if ok2 and touches then
        for _, t in ipairs(touches) do
            if t.UserInputType == Enum.UserInputType.Touch then return true end
        end
    end
    return false
end

local function keyHeld(name)
    local k = resolveKey(name)
    if not k then return false end
    local ok, down = pcall(function()
        if k.kind == "mouse" then
            return UserInputService:IsMouseButtonPressed(k.value)
        end
        return UserInputService:IsKeyDown(k.value)
    end)
    return ok and down or false
end

-- On a touch client a binding the device cannot produce falls back to holding
-- the screen, so an existing saved config comes back working instead of dead.
local function hotkeyHeld(name)
    if TOUCH and not reachable(name) then return screenHeld() end
    return keyHeld(name)
end

-- INPUT DELIVERY, AND WHY IT IS PROBED RATHER THAN ASSUMED --------------------
--
-- Measured in Potassium on 2026-09-06, counting what actually arrived at
-- UserInputService.InputBegan:
--
--     mouse1click()            x3  ->  0 inputs
--     mouse1press/mouse1release x3 ->  0 inputs
--     keypress(70) / keypress(102) ->  0 inputs   (neither throws)
--     VirtualInputManager:SendMouseButtonEvent  x3 ->  3 inputs
--     VirtualInputManager:SendKeyEvent             ->  1 input
--
-- So the executor's own input functions EXIST and DO NOTHING. Preferring them
-- because they are present - which is what every script in this genre does -
-- means the trigger reports shots it never fired and the auto-parry reports
-- parries that were never pressed. That is not a small bug: it is a panel
-- lying about its own state.
--
-- The fix is to find out at start-up instead of guessing. F13 is sent through
-- each transport in turn and UserInputService says which one arrived; it is a
-- key no game binds, so the probe cannot do anything in the world. Another
-- executor where mouse1click works keeps using it - nothing here is
-- Potassium-specific except the measurement that prompted it.

local INPUT = { key = "none", mouse = "none", probed = false }

local function vimService()
    local ok, vim = pcall(function() return game:GetService("VirtualInputManager") end)
    if ok then return vim end
    return nil
end

local function probeInput()
    if INPUT.probed then return end
    INPUT.probed = true
    local arrived = nil
    local conn = UserInputService.InputBegan:Connect(function(i)
        if i.KeyCode == Enum.KeyCode.F13 then arrived = true end
    end)

    local function tryPath(name, send)
        arrived = false
        pcall(send)
        local t = os.clock()
        while os.clock() - t < 0.25 and not arrived do task.wait() end
        if arrived and INPUT.key == "none" then INPUT.key = name end
        return arrived
    end

    if keypress and keyrelease then
        tryPath("keypress", function()
            keypress(Enum.KeyCode.F13.Value)
            task.wait(0.03)
            keyrelease(Enum.KeyCode.F13.Value)
        end)
    end
    local vim = vimService()
    if INPUT.key == "none" and vim then
        tryPath("VirtualInputManager", function()
            vim:SendKeyEvent(true, Enum.KeyCode.F13, false, game)
            task.wait(0.03)
            vim:SendKeyEvent(false, Enum.KeyCode.F13, false, game)
        end)
    end
    pcall(function() conn:Disconnect() end)

    -- The mouse cannot be probed the same way - a test click would fire the
    -- weapon - so it follows the keyboard's verdict. Both come from the same
    -- executor API family, and where the keyboard path is dead the mouse one
    -- measured dead too.
    if INPUT.key == "VirtualInputManager" then
        INPUT.mouse = "VirtualInputManager"
    elseif INPUT.key == "keypress" and mouse1click then
        INPUT.mouse = "mouse1click"
    elseif vim then
        INPUT.mouse = "VirtualInputManager"
    elseif mouse1click then
        INPUT.mouse = "mouse1click"
    end
    note("input: key " .. INPUT.key .. ", mouse " .. INPUT.mouse)
end

local function pullTrigger()
    if INPUT.mouse == "mouse1click" and mouse1click then
        mouse1click()
        return true
    end
    local vim = vimService()
    if not vim then
        if mouse1press and mouse1release then
            mouse1press() task.wait(0.02) mouse1release()
            return true
        end
        return false
    end
    local c = centreOf()
    local ok = pcall(function()
        vim:SendMouseButtonEvent(c.X, c.Y, 0, true, game, 0)
        task.wait(0.02)
        vim:SendMouseButtonEvent(c.X, c.Y, 0, false, game, 0)
    end)
    return ok
end

local function clickMethod()
    return INPUT.mouse == "none" and "NONE - nothing can fire" or INPUT.mouse
end

local function tapKey(name)
    local k = resolveKey(name)
    if not k or k.kind ~= "key" then return false end
    if INPUT.key == "keypress" and keypress and keyrelease then
        local ok = pcall(function()
            keypress(k.value.Value)
            task.wait(0.02)
            keyrelease(k.value.Value)
        end)
        if ok then return true end
    end
    local vim = vimService()
    if not vim then return false end
    return (pcall(function()
        vim:SendKeyEvent(true, k.value, false, game)
        task.wait(0.02)
        vim:SendKeyEvent(false, k.value, false, game)
    end))
end

local function holdKey(name, down)
    local k = resolveKey(name)
    if not k or k.kind ~= "key" then return false end
    local vim = vimService()
    if not vim then return false end
    return (pcall(function() vim:SendKeyEvent(down, k.value, false, game) end))
end

local function keyMethod()
    return INPUT.key == "none" and "NONE - nothing can be pressed" or INPUT.key
end

--------------------------------------------------------------------------------
-- PARRY
--------------------------------------------------------------------------------
-- The whole feature is: see the attack start on somebody else's character, wait
-- a configurable delay, press the real parry key. It fires no remote and
-- fabricates nothing - the game's own parry code runs exactly as it would for a
-- hand on the keyboard.
--
-- THE DELAY IS NOT MEASURED. Nothing here knows how long the game gives you
-- between an attacker's wind-up and the hit, because the account never got into
-- a real fight. So the feature ships OFF, the delay is a slider, and the panel
-- counts three separate things: attacks seen, parries fired, and
-- Redliner.ParrySuccess actually playing on our own character. The third number
-- is the only one that means anything.

-- THE AERIALS ARE NOT ATTACKS, and getting that wrong made the parry useless.
--
-- 3P_LAerial (117251245513909) and 3P_RAerial (135285345042099) were the two
-- most common animations in the whole first sweep - 218 and 225 against 89 for
-- LAttack - which read like "everybody spams aerial attacks". They are not.
-- Logged against our own character while clicking five times 740ms apart, the
-- aerials fired at 270, 285, 634, 1100, 1896, 2764, 3417, 3596, 3948, 4117 and
-- 4167 ms, i.e. nowhere near the clicks, while the three real swings landed at
-- 335, 1512 and 4279 as LAttack. They are the JUMP and FALL animations of a
-- movement game where everybody is airborne half the time.
--
-- Left in, an auto-parry fires at anybody who jumps - which is everybody, all
-- the time - and burns its cooldown before a real attack ever arrives.
local ATTACK_MELEE = {
    ["rbxassetid://105441036119013"] = "LAttack",
    ["rbxassetid://87457990259233"]  = "RAttack",
    ["rbxassetid://71188211641772"]  = "CAttack",
}

local ATTACK_GUN = {
    ["rbxassetid://110389010823335"] = "Castigate/Revolt",
    ["rbxassetid://96091952971711"]  = "Monarch",
    ["rbxassetid://82893125154254"]  = "Siege",
    ["rbxassetid://115498395958050"] = "Phoenix",
}

local PARRY_SUCCESS = "rbxassetid://88427023415444"   -- Redliner.ParrySuccess
local PARRY_OWN     = "rbxassetid://74124883232856"   -- Redliner.Parry

local lastParryAt = 0
local watchedHum = {}

-- "are WE looking at them" - the mirror of facingUs below, used by the aura
local function facingTarget(model)
    local body = bodyPart(model)
    if not body then return false end
    local to = body.Position - cam.CFrame.Position
    if to.Magnitude < 0.1 then return true end
    return cam.CFrame.LookVector:Dot(to.Unit) > 0.5
end

local function facingUs(model)
    local root = model:FindFirstChild("HumanoidRootPart")
    local mine = myRoot()
    if not root or not mine then return false end
    local toUs = (mine.Position - root.Position)
    if toUs.Magnitude < 0.1 then return true end
    return root.CFrame.LookVector:Dot(toUs.Unit) > 0.45
end

local function onAttackSeen(model, kind, label)
    if not live() or not CONFIG.parry then return end
    local mine = myRoot()
    local root = model:FindFirstChild("HumanoidRootPart")
    if not mine or not root then return end
    local dist = (mine.Position - root.Position).Magnitude
    local range = (kind == "gun") and CONFIG.parryGunRange or CONFIG.parryRange
    if dist > range then return end
    if kind == "gun" and not CONFIG.parryGun then return end
    if CONFIG.parryFacing and not facingUs(model) then return end
    local now = os.clock() * 1000
    if now - lastParryAt < CONFIG.parryCooldown then return end
    lastParryAt = now
    STATE.parryAttacks = STATE.parryAttacks + 1
    STATE.parryLast = label .. "  " .. math.floor(dist) .. "m"
    task.spawn(function()
        task.wait(CONFIG.parryDelay / 1000)
        if not live() or not CONFIG.parry then return end
        if tapKey(CONFIG.parryKey) then STATE.parryFired = STATE.parryFired + 1 end
    end)
end

-- OUR OWN ANIMATIONS DO NOT ARRIVE ON Humanoid.AnimationPlayed, and that is
-- measured: 12 clicks that provably swung the sword produced zero events there,
-- while the SAME clicks showed up on the Humanoid's Animator. Remote players are
-- the other way round - their replicated tracks do fire AnimationPlayed, which
-- is why watching only the Humanoid looked like it worked. Both are connected
-- now, and the handler is shared, so neither side can go quiet unnoticed.
-- Only the third-person ids: those are the ones that measurably fire on our own
-- character, and the aerials are movement rather than attacks (see above).
local MY_SWING = {
    ["rbxassetid://105441036119013"] = true,   -- 3P_LAttack
    ["rbxassetid://87457990259233"]  = true,   -- 3P_RAttack
    ["rbxassetid://71188211641772"]  = true,   -- 3P_CAttack
}

-- BOTH the Humanoid and its Animator are connected, because each one is the only
-- source for one side (ours vs remote players) - and some tracks fire on both,
-- which double-counted every swing: 9 clicks read as 14 swings on the first live
-- run. So the same animation on the same model inside 80ms is one event.
local lastAnim = {}

local function onAnimation(model, id)
    if not live() or not id then return end
    local key = tostring(model) .. id
    local now = os.clock()
    if lastAnim[key] and now - lastAnim[key] < 0.08 then return end
    lastAnim[key] = now
    if model == myChar() then
        if id == PARRY_SUCCESS then STATE.parrySuccess = STATE.parrySuccess + 1 end
        if MY_SWING[id] then
            -- One swing plays a first-person AND a third-person track, and they
            -- are different ids, so the per-id debounce above does not merge
            -- them: the first live run read 9 clicks as 21 swings. The game
            -- paces melee at ~640ms, so anything inside 300ms is the same swing
            -- being reported twice.
            if now - (STATE.lastSwingSeen or 0) > 0.3 then
                STATE.lastSwingSeen = now
                STATE.auraSwings = STATE.auraSwings + 1
            end
        end
        return
    end
    local melee = ATTACK_MELEE[id]
    if melee then return onAttackSeen(model, "melee", melee) end
    local gun = ATTACK_GUN[id]
    if gun then return onAttackSeen(model, "gun", gun) end
end

local function watchHumanoid(model)
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or watchedHum[hum] then return end
    watchedHum[hum] = true
    hum.AnimationPlayed:Connect(function(track)
        onAnimation(model, track.Animation and track.Animation.AnimationId)
    end)
    local animator = hum:FindFirstChildOfClass("Animator")
    if animator then
        animator.AnimationPlayed:Connect(function(track)
            onAnimation(model, track.Animation and track.Animation.AnimationId)
        end)
    end
end

local function startParryWatch()
    local folder = entitiesFolder()
    if not folder then return end
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") then task.defer(watchHumanoid, m) end
    end
    folder.ChildAdded:Connect(function(m)
        if not live() then return end
        task.defer(function()
            task.wait(0.2)
            if m:IsA("Model") then watchHumanoid(m) end
        end)
    end)
    plr.CharacterAdded:Connect(function(c)
        if not live() then return end
        task.wait(0.3)
        watchHumanoid(c)
    end)
    local c = myChar()
    if c then watchHumanoid(c) end
end

--------------------------------------------------------------------------------
-- KILL AURA
--------------------------------------------------------------------------------
-- REDLINER is a swordfight before it is a shooter, so the melee is the feature
-- that matters - and it needs no remote at all: the sword swings on a real left
-- click, exactly as it does for a hand on the mouse.
--
-- Measured on a live FFA round with gameplay control (menu closed, clicks
-- arriving with gameProcessed = false):
--
--     12 clicks 180ms apart  ->  4 swings
--     gaps between swings    ->  632, 651, 650 ms
--     and they ALTERNATE     ->  3P_LAttack, 3P_RAttack, 3P_LAttack, 3P_RAttack
--
-- So the game paces melee at about 640ms and clicking faster is thrown away -
-- the same "you measured the fire rate, not the kill list" answer the genre
-- keeps giving. The default interval is 660ms for that reason, and the panel
-- counts CLICKS SENT against SWINGS SEEN: the swing counter reads our own
-- Animator, which is the game confirming it really swung, so a wrong interval
-- shows up as a gap between two numbers instead of being believed.
--
-- NOT measured: the reach. Nobody stayed close enough long enough to find the
-- distance at which a swing connects, so `auraRange` is a slider with a guess
-- in it (18 studs) rather than a number this script can defend.

local function swordOut()
    local c = myChar()
    return c ~= nil and equippedWeapon(c) == "Redliner"
end

local function auraActive()
    if not CONFIG.aura then return false end
    local mode = CONFIG.auraActivation
    if mode == "Always" then return true end
    if mode == "Screen held" then return screenHeld() end
    return hotkeyHeld(CONFIG.auraKey)
end

-- "Is this one actually hittable right now?" - the whole feature, and the reason
-- it is not an aimbot. It never moves the camera; it only asks whether the
-- target already stands inside the arc the player is looking at, and swings if
-- it does. Three gates, each measured or configurable:
--
--   range  - a swing while closing from ~29 studs produced impact effects, one
--            at 40 studs produced none, so 25 is the default
--   angle  - measured A/B: 4 swings facing AWAY produced 0 impacts, 4 swings
--            facing the target produced 9 (HitParticles, SlashParticlesShards
--            and the game's own DamageNumber). So the arc is real and it is the
--            gate that decides whether a swing is worth anything at all.
--   sight  - a wall between you and them is a swing into the wall
local function hittable(model)
    local root = myRoot()
    local body = bodyPart(model)
    if not root or not body then return false, nil end
    local d = (root.Position - body.Position).Magnitude
    if d > CONFIG.auraRange then return false, d end
    local to = body.Position - cam.CFrame.Position
    if to.Magnitude > 0.1 then
        local dot = math.clamp(cam.CFrame.LookVector:Dot(to.Unit), -1, 1)
        if math.deg(math.acos(dot)) > CONFIG.auraAngle then return false, d end
    end
    if CONFIG.auraVisibleOnly and not visibleTo(body) then return false, d end
    return true, d
end

local function auraPick()
    local best, bestD
    for _, model in ipairs(combatants()) do
        local ok, d = hittable(model)
        if ok and (not bestD or d < bestD) then best, bestD = model, d end
    end
    return best, bestD
end

-- THE HIT COUNTER, and why it exists.
--
-- Enemy health does not replicate here (470 attack animations, zero changes), so
-- "did that swing do anything" cannot be read off the victim. What CAN be read is
-- the game's own damage popup: a part called DamageNumber spawns in
-- workspace.Effects right next to whoever was hit. One appearing near an ENEMY
-- shortly after we swung is the game confirming our swing landed; one appearing
-- near US is damage we took, and is not counted.
--
-- That makes the range and angle sliders tunable against something real instead
-- of against a feeling, which is the whole point of putting them on the panel.
local function watchHits()
    local fx = Workspace:FindFirstChild("Effects")
    if not fx then return end
    fx.DescendantAdded:Connect(function(o)
        if not live() or not o:IsA("BasePart") then return end
        if o.Name ~= "DamageNumber" then return end
        -- ours only: within a swing's echo, and nearer to an enemy than to us
        if os.clock() * 1000 - STATE.lastSwingAt > 1200 then return end
        local mine = myRoot()
        if mine and (o.Position - mine.Position).Magnitude < 12 then return end
        for _, m in ipairs(combatants()) do
            local b = bodyPart(m)
            if b and (o.Position - b.Position).Magnitude < 14 then
                STATE.auraHits = STATE.auraHits + 1
                return
            end
        end
    end)
end

local function auraLoop()
    task.wait()
    while live() do
        local ok = pcall(function()
            if not auraActive() then STATE.auraTarget = nil return end
            if CONFIG.auraNeedSword and not swordOut() then
                STATE.auraTarget = "no sword equipped"
                return
            end
            -- nearest in RANGE, arc ignored: this is what the optional turn
            -- aims at, and what the readout names when the arc is the only
            -- thing standing in the way
            local near, nd
            for _, m in ipairs(combatants()) do
                local b = bodyPart(m)
                local r = myRoot()
                if b and r then
                    local d = (r.Position - b.Position).Magnitude
                    if d <= CONFIG.auraRange and (not nd or d < nd) then near, nd = m, d end
                end
            end
            STATE.auraModel = near

            local target, dist = auraPick()
            if not target then
                -- say WHY nothing is happening rather than going quiet: a gate
                -- that blocks silently reads exactly like a broken feature
                if not near then
                    for _, m in ipairs(combatants()) do
                        local b = bodyPart(m)
                        local r = myRoot()
                        if b and r then
                            local d = (r.Position - b.Position).Magnitude
                            if not nd or d < nd then near, nd = m, d end
                        end
                    end
                end
                STATE.auraTarget = near
                    and UI.tf("nearest %s at %sm - out of reach or arc", near.Name, math.floor(nd))
                    or nil
                return
            end
            STATE.auraTarget = target.Name .. "  " .. math.floor(dist) .. "m"
            local now = os.clock() * 1000
            if now - STATE.lastSwingAt < CONFIG.auraInterval then return end
            STATE.lastSwingAt = now
            if pullTrigger() then STATE.auraClicks = STATE.auraClicks + 1 end
        end)
        if not ok then task.wait(0.2) end
        task.wait(0.03)
    end
end

--------------------------------------------------------------------------------
-- MOVEMENT
--------------------------------------------------------------------------------
-- WRITING WalkSpeed DOES NOTHING WORTH HAVING HERE, and that is a measurement
-- rather than caution. Sampled over 3.7s of ordinary play: `Humanoid.WalkSpeed`
-- read **16** while the character was actually travelling at up to **106
-- studs/s** flat, vertical velocity peaking at 145. The game runs its own
-- movement controller - the place description says "there is no speed limit"
-- and the character has `AutoRotate = false` - so the Humanoid number is not the
-- governor, and raising it would be a client-side placebo at best.
--
-- What IS real is the game's own movement tech, and the game itself treats it as
-- something to automate: its keybind settings carry **BHOP TOGGLE**, **SLIDE
-- TOGGLE** and **GRAPPLE TOGGLE**. So this page presses the same keys a hand
-- would, on a timer, and nothing else. Those keys are whatever YOU bound in the
-- game's own settings - they are rebindable and this script cannot read them, so
-- they are fields here rather than assumptions.

local function bhopLoop()
    task.wait()
    while live() do
        local ok = pcall(function()
            if not CONFIG.moveBhop then return end
            if tapKey(CONFIG.moveBhopKey) then STATE.bhops = STATE.bhops + 1 end
        end)
        if not ok then task.wait(0.3) end
        task.wait(math.max(CONFIG.moveBhopRate, 30) / 1000)
    end
end

local function slideLoop()
    task.wait()
    while live() do
        local ok = pcall(function()
            if not CONFIG.moveSlide then return end
            if tapKey(CONFIG.moveSlideKey) then STATE.slides = STATE.slides + 1 end
        end)
        if not ok then task.wait(0.3) end
        task.wait(math.max(CONFIG.moveSlideEvery, 200) / 1000)
    end
end

--------------------------------------------------------------------------------
-- aim assist
--------------------------------------------------------------------------------

local sticky = nil

local function aimActive()
    if not CONFIG.aim then return false end
    local mode = CONFIG.aimActivation
    if mode == "Always" then return true end
    if mode == "Screen held" then return screenHeld() end
    if mode == "While firing" then
        if TOUCH then return false end
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
    end
    return hotkeyHeld(CONFIG.aimKey)
end

local function aimTargetPart(model)
    if CONFIG.aimPart == "Head" then return headHurtbox(model) end
    if CONFIG.aimPart == "Torso" then return bodyPart(model) end
    local head, body = headHurtbox(model), bodyPart(model)
    if not head then return body end
    if not body then return head end
    local c = centreOf()
    local ph = cam:WorldToViewportPoint(head.Position)
    local pb = cam:WorldToViewportPoint(body.Position)
    local dh = (Vector2.new(ph.X, ph.Y) - c).Magnitude
    local db = (Vector2.new(pb.X, pb.Y) - c).Magnitude
    return dh <= db and head or body
end

local function pickTarget()
    local root = myRoot()
    if not root then return nil end
    local c = centreOf()
    local best, bestScore
    for _, model in ipairs(combatants()) do
        local part = aimTargetPart(model)
        if part then
            local dist = (root.Position - part.Position).Magnitude
            if dist <= CONFIG.aimMaxDist then
                local sp = cam:WorldToViewportPoint(part.Position)
                if sp.Z > 0 then
                    local px = (Vector2.new(sp.X, sp.Y) - c).Magnitude
                    if px <= CONFIG.aimFov then
                        if (not CONFIG.aimVisibleOnly) or visibleTo(part) then
                            local score
                            if CONFIG.aimPick == "World" then
                                score = dist
                            elseif CONFIG.aimPick == "Lowest HP" then
                                score = select(1, healthOf(model))
                            else
                                score = px
                            end
                            if not bestScore or score < bestScore then
                                best, bestScore = model, score
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

-- 1 = instant, 50 = about a second. Frame-rate independent, and a DIVISOR: a
-- plain per-frame Lerp is on target inside three frames at 200 FPS, which makes
-- every setting feel like a hard snap.
local function approach(smooth, dt)
    local base = 1 / math.max(1, smooth)
    return 1 - (1 - base) ^ math.max(dt * 60, 0.0001)
end

local function angleDelta(a, b)
    local d = (b - a) % (math.pi * 2)
    if d > math.pi then d = d - math.pi * 2 end
    return d
end

local function aimPass(dt)
    if not live() then return end
    if not aimActive() then
        sticky = nil
        STATE.target = nil
        STATE.aimStep = 0
        return
    end

    local target = sticky
    if CONFIG.aimSticky and target then
        local ok = target.Parent and aliveOf(target)
        if ok then
            local part = aimTargetPart(target)
            local sp = part and cam:WorldToViewportPoint(part.Position)
            if not sp or sp.Z <= 0 or (Vector2.new(sp.X, sp.Y) - centreOf()).Magnitude > CONFIG.aimFov * 1.6 then
                ok = false
            end
        end
        if not ok then target = nil end
    else
        target = nil
    end
    if not target then target = pickTarget() end
    sticky = target
    STATE.target = target and target.Name or nil
    if not target then STATE.aimStep = 0 return end

    local part = aimTargetPart(target)
    if not part then return end

    local pos = cam.CFrame.Position
    local curPitch, curYaw = cam.CFrame:ToOrientation()
    local wantPitch, wantYaw = CFrame.lookAt(pos, part.Position):ToOrientation()

    local dYaw = angleDelta(curYaw, wantYaw) * approach(CONFIG.aimSmoothH, dt)
    local dPitch = angleDelta(curPitch, wantPitch) * approach(CONFIG.aimSmoothV, dt)

    -- The degrees-per-second cap, applied to yaw and pitch TOGETHER so a diagonal
    -- flick is capped like a flat one. A smoothing divisor is a fraction of the
    -- REMAINING angle, so at point-blank range even a slow-looking divisor turns
    -- the camera at a few thousand degrees per second; this is the knob that
    -- makes it look like a hand instead of a servo.
    local step = math.sqrt(dYaw * dYaw + dPitch * dPitch)
    local cap = math.rad(CONFIG.humanTurnCap) * dt
    if cap > 0 and step > cap then
        local scale = cap / step
        dYaw, dPitch = dYaw * scale, dPitch * scale
        step = cap
    end

    -- A deadzone stops permanent pixel-perfect tracking.
    local sp = cam:WorldToViewportPoint(part.Position)
    if sp.Z > 0 and (Vector2.new(sp.X, sp.Y) - centreOf()).Magnitude < CONFIG.humanDeadzone then
        STATE.aimStep = 0
        return
    end

    cam.CFrame = CFrame.new(pos) * CFrame.fromOrientation(curPitch + dPitch, curYaw + dYaw, 0)

    -- The honest number is the step the SCRIPT applied, not the camera's total
    -- movement: the camera carries the player's mouse as well and nothing in it
    -- says which is which.
    local degS = math.deg(step) / math.max(dt, 1e-4)
    STATE.aimStep = degS
    if degS > STATE.aimPeak then STATE.aimPeak = degS end
end

--------------------------------------------------------------------------------
-- trigger
--------------------------------------------------------------------------------

local function trigActive()
    if not CONFIG.trigger then return false end
    local mode = CONFIG.triggerActivation
    if mode == "Always" then return true end
    if mode == "Screen held" then return screenHeld() end
    return hotkeyHeld(CONFIG.triggerKey)
end

local function underCrosshair()
    local root = myRoot()
    if not root then return nil end
    local origin = cam.CFrame.Position
    local c = centreOf()
    local ray = cam:ViewportPointToRay(c.X, c.Y)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local list = {}
    local mine = myChar()
    if mine then list[#list + 1] = mine end
    local map = Workspace:FindFirstChild("Map")
    if map then
        for _, d in ipairs(map:GetDescendants()) do
            if d:IsA("BasePart") and d.Transparency >= 1 and not d.CanCollide then
                list[#list + 1] = d
            end
        end
    end
    local fx = Workspace:FindFirstChild("Effects")
    if fx then list[#list + 1] = fx end
    params.FilterDescendantsInstances = list
    local hit = Workspace:Raycast(ray.Origin, ray.Direction * CONFIG.triggerMaxDist, params)
    if not hit or not hit.Instance then return nil end
    local inst = hit.Instance
    local folder = entitiesFolder()
    while inst and inst.Parent do
        if folder and inst.Parent == folder then
            if inst:IsA("Model") and inst ~= mine and aliveOf(inst) then
                if CONFIG.triggerHeadOnly then
                    local hb = headHurtbox(inst)
                    if hit.Instance ~= hb and hit.Instance.Name ~= "Head" then return nil end
                end
                local dist = (origin - hit.Position).Magnitude
                if dist <= CONFIG.triggerMaxDist then return inst end
            end
            return nil
        end
        inst = inst.Parent
    end
    return nil
end

local function triggerLoop()
    task.wait()   -- a task.spawn runs its first pass synchronously, in whatever
                  -- context executed the file; one wait moves it onto a normal
                  -- scheduler frame
    local lastShot = 0
    while live() do
        local ok = pcall(function()
            if not trigActive() then return end
            local now = os.clock() * 1000
            if now - lastShot < CONFIG.triggerLockout then return end
            if not underCrosshair() then return end
            local lo = math.min(CONFIG.triggerDelayMin, CONFIG.triggerDelayMax)
            local hi = math.max(CONFIG.triggerDelayMin, CONFIG.triggerDelayMax)
            task.wait(math.random(lo, hi) / 1000)
            -- Re-check AFTER the reaction delay: without this the trigger fires
            -- at where the enemy was 90ms ago, which on a strafing player is a
            -- miss and a give-away in equal measure.
            if not trigActive() or not underCrosshair() then return end
            if pullTrigger() then
                STATE.shots = STATE.shots + 1
                lastShot = os.clock() * 1000
            end
        end)
        if not ok then task.wait(0.2) end
        task.wait(0.01)
    end
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

RunService:BindToRenderStep("__REDLINER_ESP", Enum.RenderPriority.Camera.Value + 2, function()
    if not live() then
        pcall(function() RunService:UnbindFromRenderStep("__REDLINER_ESP") end)
        return
    end
    pcall(renderPass)
end)

RunService:BindToRenderStep("__REDLINER_AIM", Enum.RenderPriority.Camera.Value + 1, function(dt)
    if not live() then
        pcall(function() RunService:UnbindFromRenderStep("__REDLINER_AIM") end)
        return
    end
    STATE.fps = math.floor(1 / math.max(dt, 1e-4))
    pcall(aimPass, dt)
    -- The aura's optional turn. It is opt-in and separate from the aim assist on
    -- purpose: the aura's whole point is that it does NOT move the camera, and
    -- somebody who wants that behaviour anyway should be switching on something
    -- that says so. Capped by the same deg/s knob, so it cannot snap.
    if CONFIG.aura and CONFIG.auraFaceTarget and STATE.auraModel then
        pcall(function()
            local model = STATE.auraModel
            if not model.Parent then STATE.auraModel = nil return end
            local body = bodyPart(model)
            if not body then return end
            local pos = cam.CFrame.Position
            local curPitch, curYaw = cam.CFrame:ToOrientation()
            local wantPitch, wantYaw = CFrame.lookAt(pos, body.Position):ToOrientation()
            local dYaw = angleDelta(curYaw, wantYaw) * approach(CONFIG.aimSmoothH, dt)
            local dPitch = angleDelta(curPitch, wantPitch) * approach(CONFIG.aimSmoothV, dt)
            local step = math.sqrt(dYaw * dYaw + dPitch * dPitch)
            local cap = math.rad(CONFIG.humanTurnCap) * dt
            if cap > 0 and step > cap then
                local scale = cap / step
                dYaw, dPitch = dYaw * scale, dPitch * scale
            end
            cam.CFrame = CFrame.new(pos) * CFrame.fromOrientation(curPitch + dPitch, curYaw + dYaw, 0)
        end)
    end
end)

task.spawn(triggerLoop)
task.spawn(auraLoop)
task.spawn(function() task.wait() pcall(watchHits) end)
task.spawn(bhopLoop)
task.spawn(slideLoop)
task.spawn(function()
    task.wait()
    -- Before anything can press anything: find out which transport actually
    -- delivers. See the INPUT section - the executor's own click and key
    -- functions exist here and do nothing.
    pcall(probeInput)
end)
task.spawn(function()
    task.wait()
    startParryWatch()
    while live() do
        pcall(reapPool)
        task.wait(2)
    end
end)

--------------------------------------------------------------------------------
-- auto-arm
--------------------------------------------------------------------------------
-- Switching on Box while the master is off moved the row, lit the panel and
-- changed nothing on screen - from the outside that is a dead toggle, not a
-- gate. Watched from ONE place rather than wired into thirty callbacks, and
-- seeded from the current values so a panel that starts with drawings already on
-- does not arm itself.

local ARMED_BY = { "espBox", "espName", "espDist", "espHealth", "espHeadDot",
    "espSkeleton", "espTracer", "espChams" }

task.spawn(function()
    task.wait()
    local prev = {}
    for _, key in ipairs(ARMED_BY) do prev[key] = CONFIG[key] end
    while live() do
        for _, key in ipairs(ARMED_BY) do
            local now = CONFIG[key]
            if now and not prev[key] and not CONFIG.esp then
                CONFIG.esp = true
                note("ESP master armed by " .. key)
            end
            prev[key] = now
        end
        task.wait(0.2)
    end
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

-- The generation guard above clears the loops, the Drawings and the chams, but a
-- ScreenGui is none of those: without this a second execution leaves the first
-- panel on screen with nothing driving it, and two panels answer every click.
-- Measured here on the reload test - gen 2, two Selux ScreenGuis. UI.sweep()
-- rather than a hand-rolled loop: it pcalls gethui(), CoreGui and PlayerGui in
-- turn and skips the ones the executor refuses, and it also finds a panel that
-- fell through to PlayerGui under a renamed instance.
local PANEL_NAME = "RedlinerPanel"
if UI.sweep then pcall(UI.sweep, PANEL_NAME) end

local win = UI.Window({ name = PANEL_NAME, title = "RED", accentTitle = "LINER",
    subtitle = "seltonmt" })

local recording = nil

local function keyLabel(name)
    if not reachable(name) and TOUCH then return tostring(name) .. "  (screen)" end
    return tostring(name)
end

local function keyButton(card, caption, field)
    -- card:Button hands back the TextButton INSTANCE, not a wrapper, so the
    -- caption is changed through UI.setText - which is also what keeps the
    -- button translatable, because it stamps the original string as an
    -- attribute rather than overwriting it.
    local btn
    local function label(text) pcall(function() UI.setText(btn, text) end) end
    btn = card:Button(caption .. ":  " .. keyLabel(CONFIG[field]), function()
        recording = field
        label(caption .. ":  press a key...")
    end)
    -- keyboard on InputBegan (immediate, Escape cancels); mouse on InputENDED,
    -- because the click that armed the recorder has already fired its InputBegan
    -- by the time this handler runs.
    UserInputService.InputBegan:Connect(function(input, gp)
        if not live() or recording ~= field or gp then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        recording = nil
        if input.KeyCode ~= Enum.KeyCode.Escape then
            CONFIG[field] = input.KeyCode.Name
            keyCache = {}
        end
        label(caption .. ":  " .. keyLabel(CONFIG[field]))
    end)
    UserInputService.InputEnded:Connect(function(input)
        if not live() or recording ~= field then return end
        local t = input.UserInputType
        if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.MouseButton2
            and t ~= Enum.UserInputType.MouseButton3 then return end
        recording = nil
        CONFIG[field] = t.Name
        keyCache = {}
        label(caption .. ":  " .. keyLabel(CONFIG[field]))
    end)
    return btn
end

-- ESP ------------------------------------------------------------------------
local espPage = win:Page("ESP", UI.icon.eye)
do
    local c = espPage:Card("DRAWING", 1):Accent()
    c:Toggle("Box", CONFIG.espBox, function(v) CONFIG.espBox = v end,
        "outlined box, sized from the head and the lower leg")
    c:Toggle("Name", CONFIG.espName, function(v) CONFIG.espName = v end)
    c:Toggle("Distance and level", CONFIG.espDist, function(v) CONFIG.espDist = v end,
        "level and killstreak come from the ReadOnly oracle")
    c:Toggle("Health bar", CONFIG.espHealth, function(v) CONFIG.espHealth = v end,
        "reads the real Humanoid - see the note on the INFO page")
    c:Toggle("Head dot", CONFIG.espHeadDot, function(v) CONFIG.espHeadDot = v end)
    c:Toggle("Skeleton", CONFIG.espSkeleton, function(v) CONFIG.espSkeleton = v end, "R6 bones")
    c:Toggle("Tracer", CONFIG.espTracer, function(v) CONFIG.espTracer = v end)
    c:Toggle("Chams", CONFIG.espChams, function(v)
        CONFIG.espChams = v
        if not v then clearChams() end
    end, "through-wall highlight, drawn even off screen")

    local c2 = espPage:Card("LIMITS", 2)
    c2:Slider("Max distance", 100, 2000, CONFIG.espMaxDist, function(v) CONFIG.espMaxDist = v end)
    c2:Toggle("Visible only", CONFIG.espVisibleOnly, function(v) CONFIG.espVisibleOnly = v end,
        "hide anyone behind a wall")
    c2:Slider("Text size", 12, 24, CONFIG.espTextSize, function(v) CONFIG.espTextSize = v end)
    c2:Dropdown("Font", { "System", "UI", "Plex", "Monospace" }, CONFIG.espFont,
        function(v) CONFIG.espFont = v end)
    c2:Colour("Colour", CONFIG.espColour, function(v) CONFIG.espColour = v end,
        "behind a wall is the same hue at 55% brightness")

    local out = espPage:Card("LIVE", 0):Readout(3)
    task.spawn(function()
        task.wait()
        while live() do
            pcall(function()
                out:set({
                    UI.tf("  targets %s    drawn %s    %s fps", STATE.targets, STATE.drawn, STATE.fps),
                    UI.tf("  place %s", placeKind()),
                    "  " .. (STATE.note ~= "" and STATE.note or "-"),
                })
            end)
            task.wait(0.3)
        end
    end)
end

-- AIM ------------------------------------------------------------------------
local aimPage = win:Page("AIM", UI.icon.target)
do
    local c = aimPage:Card("ASSIST", 1):Accent()
    c:Toggle("Aim assist", CONFIG.aim, function(v) CONFIG.aim = v end,
        "moves the camera only - measured to stick at RenderPriority Camera+1")
    c:Dropdown("Activation", { "Hotkey", "Always", "While firing", "Screen held" },
        CONFIG.aimActivation, function(v) CONFIG.aimActivation = v end)
    keyButton(c, "Key", "aimKey")
    c:Dropdown("Aim at", { "Head", "Torso", "Nearest" }, CONFIG.aimPart,
        function(v) CONFIG.aimPart = v end)
    c:Dropdown("Choose target by", { "Crosshair", "World", "Lowest HP" }, CONFIG.aimPick,
        function(v) CONFIG.aimPick = v end)
    c:Toggle("Sticky target", CONFIG.aimSticky, function(v) CONFIG.aimSticky = v end,
        "keep the lock until it dies or leaves the FOV")

    local c2 = aimPage:Card("TUNING", 2)
    c2:Slider("FOV (px)", 20, 600, CONFIG.aimFov, function(v) CONFIG.aimFov = v end)
    c2:Slider("Smoothing horizontal", 1, 50, CONFIG.aimSmoothH, function(v) CONFIG.aimSmoothH = v end,
        "1 is instant, 50 is about a second")
    c2:Slider("Smoothing vertical", 1, 50, CONFIG.aimSmoothV, function(v) CONFIG.aimSmoothV = v end)
    c2:Slider("Max distance", 50, 1000, CONFIG.aimMaxDist, function(v) CONFIG.aimMaxDist = v end)
    c2:Toggle("Visible only", CONFIG.aimVisibleOnly, function(v) CONFIG.aimVisibleOnly = v end)
    c2:Toggle("Draw FOV ring", CONFIG.aimShowFov, function(v) CONFIG.aimShowFov = v end,
        "drawn at GetMouseLocation, which is where the crosshair really is")

    local out = aimPage:Card("LIVE", 0):Readout(3)
    task.spawn(function()
        task.wait()
        while live() do
            pcall(function()
                out:set({
                    UI.tf("  target %s", STATE.target or "-"),
                    UI.tf("  turn %s deg/s   peak %s   cap %s",
                        math.floor(STATE.aimStep), math.floor(STATE.aimPeak), CONFIG.humanTurnCap),
                    UI.tf("  crosshair reference  GetMouseLocation"),
                })
            end)
            task.wait(0.2)
        end
    end)
end

-- TRIGGER --------------------------------------------------------------------
local trigPage = win:Page("TRIGGER", UI.icon.bolt)
do
    local c = trigPage:Card("TRIGGER", 1):Accent()
    c:Toggle("Trigger", CONFIG.trigger, function(v) CONFIG.trigger = v end,
        "presses the real mouse button when an enemy is under the crosshair")
    c:Dropdown("Activation", { "Hotkey", "Always", "Screen held" }, CONFIG.triggerActivation,
        function(v) CONFIG.triggerActivation = v end)
    keyButton(c, "Key", "triggerKey")
    c:Toggle("Head only", CONFIG.triggerHeadOnly, function(v) CONFIG.triggerHeadOnly = v end)

    local c2 = trigPage:Card("TIMING", 2)
    c2:Slider("Reaction min (ms)", 0, 400, CONFIG.triggerDelayMin, function(v) CONFIG.triggerDelayMin = v end,
        "a fixed value is a pattern - this is a range on purpose")
    c2:Slider("Reaction max (ms)", 0, 600, CONFIG.triggerDelayMax, function(v) CONFIG.triggerDelayMax = v end)
    c2:Slider("Refire lockout (ms)", 0, 2000, CONFIG.triggerLockout, function(v) CONFIG.triggerLockout = v end)
    c2:Slider("Max distance", 50, 1000, CONFIG.triggerMaxDist, function(v) CONFIG.triggerMaxDist = v end)

    local out = trigPage:Card("LIVE", 0):Readout(2)
    task.spawn(function()
        task.wait()
        while live() do
            pcall(function()
                out:set({
                    UI.tf("  shots %s", STATE.shots),
                    UI.tf("  click method  %s", clickMethod()),
                })
            end)
            task.wait(0.4)
        end
    end)
end

-- PARRY ----------------------------------------------------------------------
local parryPage = win:Page("PARRY", UI.icon.shield)
do
    local c = parryPage:Card("AUTO PARRY", 1):Accent()
    c:Label("The timing here is NOT measured. The account never got out of the "
        .. "deploy menu, so nobody ever attacked it and the window between an "
        .. "attack starting and the hit landing is unknown. Turn it on, watch "
        .. "the three counters below, and move the delay until PARRY SUCCESS "
        .. "starts climbing. That counter reads the game's own "
        .. "Redliner.ParrySuccess animation, so it cannot flatter itself.")
    c:Toggle("Auto parry", CONFIG.parry, function(v) CONFIG.parry = v end, nil, UI.theme.warn)
    keyButton(c, "Parry key", "parryKey")
    c:Slider("Delay (ms)", 0, 500, CONFIG.parryDelay, function(v) CONFIG.parryDelay = v end,
        "measured from the moment the attacker's animation starts")
    c:Slider("Cooldown (ms)", 0, 1500, CONFIG.parryCooldown, function(v) CONFIG.parryCooldown = v end)

    local c2 = parryPage:Card("WHAT TO REACT TO", 2)
    c2:Slider("Melee range", 5, 80, CONFIG.parryRange, function(v) CONFIG.parryRange = v end)
    c2:Toggle("Also parry gunshots", CONFIG.parryGun, function(v) CONFIG.parryGun = v end,
        "the game lets you parry bullets")
    c2:Slider("Gun range", 20, 600, CONFIG.parryGunRange, function(v) CONFIG.parryGunRange = v end)
    c2:Toggle("Only when facing you", CONFIG.parryFacing, function(v) CONFIG.parryFacing = v end,
        "ignores somebody swinging at a third party")

    local out = parryPage:Card("LIVE", 0):Readout(4)
    task.spawn(function()
        task.wait()
        while live() do
            pcall(function()
                out:set({
                    UI.tf("  attacks seen   %s", STATE.parryAttacks),
                    UI.tf("  parries fired  %s   (%s)", STATE.parryFired, keyMethod()),
                    UI.tf("  PARRY SUCCESS  %s", STATE.parrySuccess),
                    UI.tf("  last  %s", STATE.parryLast),
                })
            end)
            task.wait(0.3)
        end
    end)
end

-- KILL AURA ------------------------------------------------------------------
local auraPage = win:Page("AURA", UI.icon.sword)
do
    local c = auraPage:Card("MELEE AURA", 1):Accent()
    c:Label("This is not an aimbot and it does not move your camera. It watches "
        .. "for somebody who is ALREADY hittable - inside your reach and inside "
        .. "the arc you are looking at - and swings then, on a real mouse click. "
        .. "Measured: 4 swings facing away from a target landed nothing, 4 swings "
        .. "facing it landed 9 impacts. So the arc is what decides whether a "
        .. "swing is worth anything, and that is the gate this uses.")
    c:Toggle("Kill aura", CONFIG.aura, function(v) CONFIG.aura = v end, nil, UI.theme.warn)
    c:Dropdown("Activation", { "Hotkey", "Always", "Screen held" }, CONFIG.auraActivation,
        function(v) CONFIG.auraActivation = v end)
    keyButton(c, "Key", "auraKey")
    c:Slider("Reach (studs)", 5, 60, CONFIG.auraRange, function(v) CONFIG.auraRange = v end,
        "a swing while closing from ~29 studs landed, one at 40 did not")
    c:Slider("Arc (degrees)", 5, 120, CONFIG.auraAngle, function(v) CONFIG.auraAngle = v end,
        "how far off centre a target may stand and still be swung at")
    c:Slider("Interval (ms)", 200, 1500, CONFIG.auraInterval, function(v) CONFIG.auraInterval = v end,
        "measured swing gaps were 632, 651 and 650 ms")

    local c2 = auraPage:Card("CONDITIONS", 2)
    c2:Toggle("Only with the sword out", CONFIG.auraNeedSword,
        function(v) CONFIG.auraNeedSword = v end,
        "read from CharacterMotor6D.Equipped, which replicates for every player")
    c2:Toggle("Only when in sight", CONFIG.auraVisibleOnly,
        function(v) CONFIG.auraVisibleOnly = v end,
        "a wall between you is a swing into the wall")
    c2:Toggle("Turn towards them", CONFIG.auraFaceTarget,
        function(v) CONFIG.auraFaceTarget = v end,
        "OFF by default - this one DOES move your camera and is the part that "
        .. "looks like an aimbot", UI.theme.warn)
    c2:Label("Tune Reach and Arc against the HITS counter below, not by feel. "
        .. "It reads the game's own damage popup, so it cannot flatter itself.")

    local out = auraPage:Card("LIVE", 0):Readout(4)
    task.spawn(function()
        task.wait()
        while live() do
            pcall(function()
                out:set({
                    UI.tf("  %s", STATE.auraTarget or "nobody in reach"),
                    UI.tf("  swings sent   %s   (%s)", STATE.auraClicks, clickMethod()),
                    UI.tf("  confirmed     %s", STATE.auraSwings),
                    UI.tf("  HITS          %s", STATE.auraHits),
                })
            end)
            task.wait(0.3)
        end
    end)
end

-- MOVEMENT -------------------------------------------------------------------
local movePage = win:Page("MOVE", UI.icon.wave)
do
    local c = movePage:Card("WHAT IS REAL HERE", 1):Accent()
    c:Label("There is no speed slider on this page on purpose. Measured over "
        .. "3.7s of ordinary play: Humanoid.WalkSpeed read 16 while the "
        .. "character was actually moving at up to 106 studs/s. The game runs "
        .. "its own movement controller, so writing WalkSpeed is a placebo. "
        .. "What works is pressing the game's OWN movement keys - its settings "
        .. "even ship BHOP TOGGLE, SLIDE TOGGLE and GRAPPLE TOGGLE.")
    c:Label("Set the keys below to whatever YOU have bound in the game's own "
        .. "settings. They are rebindable and this script cannot read them.")

    local c2 = movePage:Card("AUTO BHOP", 2)
    c2:Toggle("Auto bhop", CONFIG.moveBhop, function(v) CONFIG.moveBhop = v end,
        "taps the jump key on a timer")
    keyButton(c2, "Jump key", "moveBhopKey")
    c2:Slider("Every (ms)", 30, 400, CONFIG.moveBhopRate, function(v) CONFIG.moveBhopRate = v end)

    local c3 = movePage:Card("AUTO SLIDE", 2)
    c3:Toggle("Auto slide", CONFIG.moveSlide, function(v) CONFIG.moveSlide = v end)
    keyButton(c3, "Slide key", "moveSlideKey")
    c3:Slider("Every (ms)", 200, 4000, CONFIG.moveSlideEvery, function(v) CONFIG.moveSlideEvery = v end)

    local out = movePage:Card("LIVE", 0):Readout(3)
    task.spawn(function()
        task.wait()
        while live() do
            pcall(function()
                local ch = myChar()
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                local root = ch and ch:FindFirstChild("HumanoidRootPart")
                local v = root and root.AssemblyLinearVelocity
                local flat = v and math.floor(Vector3.new(v.X, 0, v.Z).Magnitude) or 0
                out:set({
                    UI.tf("  actual speed  %s studs/s   (WalkSpeed says %s)",
                        flat, hum and math.floor(hum.WalkSpeed) or "-"),
                    UI.tf("  bhop taps     %s   (%s)", STATE.bhops, keyMethod()),
                    UI.tf("  slide taps    %s", STATE.slides),
                })
            end)
            task.wait(0.3)
        end
    end)
end

-- INFO -----------------------------------------------------------------------
local infoPage = win:Page("INFO", UI.icon.chart)
do
    local c = infoPage:Card("YOU", 1):Accent()
    local mine = infoPage:Card("SERVER", 2)
    local out = c:Readout(6)
    local out2 = mine:Readout(6)
    task.spawn(function()
        task.wait()
        while live() do
            pcall(function()
                local n = plr.Name
                out:set({
                    UI.tf("  level      %s", tostring(roValue(n, "level", "-"))),
                    UI.tf("  yen        %s", tostring(roValue(n, "yen", "-"))),
                    UI.tf("  crimson    %s", tostring(roValue(n, "crimson", "-"))),
                    UI.tf("  killstreak %s", tostring(roValue(n, "killstreak", "-"))),
                    UI.tf("  winstreak  %s", tostring(roValue(n, "casual_duel_winstreak", "-"))),
                    UI.tf("  status     %s", tostring(roValue(n, "status", "-"))),
                })
                local moved = STATE.healthMoves
                out2:set({
                    UI.tf("  place      %s", placeKind()),
                    UI.tf("  enemies    %s", STATE.targets),
                    UI.tf("  ping       %s ms", math.floor((roValue(n, "rtt", 0) or 0) * 1000)),
                    UI.tf("  health seen to move  %s of %s samples", moved, STATE.healthSamples),
                    moved == 0 and "  enemy health has not been observed changing"
                        or "  enemy health does replicate",
                    "  no remote is fired by this script",
                })
            end)
            task.wait(0.5)
        end
    end)
end

-- HUMAN ----------------------------------------------------------------------
local humanPage = win:Page("HUMAN", UI.icon.wrench)
do
    local c = humanPage:Card("TELLS", 1):Accent()
    c:Slider("Turn speed cap (deg/s)", 30, 3000, CONFIG.humanTurnCap,
        function(v) CONFIG.humanTurnCap = v end,
        "the big one: a smoothing divisor is a fraction of the REMAINING angle, "
        .. "so point blank it turns at thousands of degrees per second")
    c:Slider("Deadzone (px)", 0, 20, CONFIG.humanDeadzone, function(v) CONFIG.humanDeadzone = v end,
        "stops permanent pixel-perfect tracking")

    local c2 = humanPage:Card("PANIC", 2)
    c2:Button("Everything off", function()
        CONFIG.aim = false
        CONFIG.trigger = false
        CONFIG.parry = false
        CONFIG.aura = false
        CONFIG.moveBhop = false
        CONFIG.moveSlide = false
        note("panic: aim, trigger, parry, aura and movement off")
    end, UI.theme.bad)
end

--------------------------------------------------------------------------------

win:Home()
win:Settings()
win:SetMaster(CONFIG.esp, "ESP")
win:OnMaster(function(on) CONFIG.esp = on end)

task.spawn(function()
    task.wait()
    while live() do
        pcall(function()
            win:SetStat(1, tostring(STATE.targets), "enemies")
            win:SetStat(2, tostring(STATE.parrySuccess), "parries")
            win:SetStat(3, tostring(STATE.fps), "fps")
            win:SetStatus(placeKind() .. "   " .. STATE.targets .. " enemies   "
                .. STATE.drawn .. " drawn")
        end)
        task.wait(0.5)
    end
end)

win:Refresh()

_G.__REDLINER_DBG = {
    CONFIG = CONFIG, STATE = STATE, DEFAULTS = DEFAULTS,
    combatants = combatants, aliveOf = aliveOf, headHurtbox = headHurtbox,
    visibleTo = visibleTo, screenRect = screenRect, centreOf = centreOf,
    pickTarget = pickTarget, underCrosshair = underCrosshair,
    aimTargetPart = aimTargetPart, placeKind = placeKind,
    roValue = roValue, tapKey = tapKey, pullTrigger = pullTrigger, holdKey = holdKey,
    equippedWeapon = equippedWeapon, swordOut = swordOut, auraPick = auraPick,
    hittable = hittable, auraActive = auraActive,
    probeInput = probeInput, INPUT = INPUT, clickMethod = clickMethod, keyMethod = keyMethod,
    ATTACK_MELEE = ATTACK_MELEE, ATTACK_GUN = ATTACK_GUN,
    POOL = POOL, CHAMS = CHAMS,
}

note("ready  -  " .. placeKind())
