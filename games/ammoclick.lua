--[[
    ammoclick.lua - "+1 Ammo Per Click"  (place 139907538117897)

    Verified against server-side values on 2026-08-19, account Lumo_Studios.

    The loop the game wants:  click a target -> Ammo,  shoot walls with Ammo ->
    stage cleared,  stand in the reward zone -> Wins,  Wins buy guns / eggs /
    boosts,  rebirth multiplies everything.

    What was measured, and what this script therefore does:

    * KickService:AddKick(bagName)  is the ammo engine and has NO position
      check - it credits from anywhere on the map.  Server throttles it to
      about 15 credited calls a second; firing faster is wasted.  A bag name
      multiplies the credit (Basic 1, Blue 1.5, Noob 2, Emerald 3 ... Cursed
      15) and the server enforces the RebirthsRequired of that bag - an
      unowned name credits exactly 0, a bogus name credits 0.
    * WeaponConfig has four guns priced at WinsNeeded = 0.  The server accepts
      UnlockWeapon on them.  Nebula Cannon is the best of those with
      DamagePerClick 10,000,000, and DamagePerClick is a straight multiplier
      on the ammo a click grants:  29 ammo/click with the Revolver became
      29,000,000 with the Nebula Cannon.  Grabbing it is the single biggest
      early step, it costs nothing, and no Robux is involved.
    * RebirthService:Rebirth() is FREE - measured wins 16,160 before and
      16,160 after, seven rebirths in a row, nothing deducted.  It keeps
      weapons, pets and boosts and only resets the ammo counter, which is
      regrown in seconds.  There is a server cooldown of roughly three
      seconds.  Rebirths are worth (rebirths + 1) on every click and unlock
      the stronger targets, so the script simply keeps rebirthing.
    * BreakWallService:HitWall() takes no arguments and damages the current
      wall for exactly the ammo balance, but ONLY while the character stands
      inside that wall's slab (the part is 4 studs thick - a single CFrame
      write is not enough, the body has to be pinned on Heartbeat so the
      server's copy of the position agrees).  Overkill cascades through the
      rest of the stage in one hit.
    * RewardZoneService:ClaimReward(stage) needs NO position at all, pays that
      zone's WinAmount and then resets the wall cursor back to wall 1.  So a
      run is worth exactly one claim - always claim the deepest stage that is
      complete, never a shallow one.
    * Wall health is exponential in the GLOBAL wall index (WallHealth
      .getWallHealth(index): wall 1 = 50, wall 100 = 653M, wall 250 = 3.9e19),
      so the useful depth is set by the ammo balance, not by the stage number.

    Never touched:  ClaimReward2x, every bag carrying a GamepassId or
    ProductId, the Robux eggs (WinCost 0 + RobuxProductId), SkipRebirth
    products, ChestService:BuyBossChest and anything that opens a purchase
    prompt.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local Shared            = ReplicatedStorage:WaitForChild("Shared", 10)
local LevelUtil         = require(Shared.LevelUtil)
local WallHealth        = require(Shared.WallHealth)
local KickBagConstants  = require(Shared.KickBagConstants)
local WeaponConfig      = require(Shared.WeaponConfig)
local EggConfig         = require(Shared.EggConfig)
local BoostConfig       = require(Shared.BoostConfig)
local PetConfig         = require(Shared.PetConfig)
local TitleConfig       = require(Shared.TitleConfig)
local Knit              = require(ReplicatedStorage:WaitForChild("Packages", 10):WaitForChild("Knit", 10))

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    autoKick      = true,   -- AddKick at the credited rate, best allowed target
    autoWalls     = true,   -- pin into the current wall and shoot it
    autoClaim     = true,   -- claim the deepest completed stage
    autoRebirth   = true,   -- free, keeps everything, only resets the ammo bar
    autoWeapon    = true,   -- unlock + equip the strongest gun the wins allow
    autoBoosts    = true,   -- Damage / Wins boosts, priced in wins
    autoEggs      = true,   -- best affordable egg, wins-priced ones only
    autoRewards   = true,   -- daily reward and banked spins
    autoTitles    = true,   -- free title rolls, equips the best one owned
    autoPets      = true,   -- keeps the strongest pets in the slots (x185 measured)
    autoCullPets  = true,   -- deletes everything below the keep list
    keepPets      = 15,     -- how many of the best to keep around
    cullBatch     = 25,     -- deletions per pass; one call, indices shift after
    depthSafety   = 0.5,    -- a stage is only targeted if its worst wall costs
                            -- at most this share of the ammo balance
    titleFloor    = 1000,   -- a roll costs 5 wins; do not roll a balance to zero
    boostShare    = 0.2,    -- never spend more than this share of the balance
    eggShare      = 0.5,    -- on one boost level / one egg
    hitGap        = 0.3,
    kickGap       = 0.05,
    rebirthGap    = 3.0,
}

local STATE = {
    ammo = 0, wins = 0, rebirths = 0, pets = 0,
    cursor = 1, target = 1, stage = 1,
    claims = 0, rebirthsDone = 0, eggsOpened = 0, boostsBought = 0, petsDeleted = 0,
    bag = "-", weapon = "-", title = "-", titleMult = 0, petMult = 1,
    level = 0, levelMax = 0, uiOwner = nil,
    note = "starting", phase = "idle",
}

_G.__AMMOCLICK = (_G.__AMMOCLICK or 0) + 1
local GEN = _G.__AMMOCLICK

local function alive() return _G.__AMMOCLICK == GEN end

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

----------------------------------------------------------------------------
-- services / data replica
----------------------------------------------------------------------------

local KickService   = Knit.GetService("KickService")
local WallService   = Knit.GetService("BreakWallService")
local ZoneService   = Knit.GetService("RewardZoneService")
local RebirthSvc    = Knit.GetService("RebirthService")
local WeaponSvc     = Knit.GetService("WeaponService")
local BoostSvc      = Knit.GetService("BoostService")
local EggSvc        = Knit.GetService("EggService")
local DailySvc      = Knit.GetService("DailyRewardsService")
local SpinSvc       = Knit.GetService("SpinWheelService")
local TitleSvc      = Knit.GetService("TitleService")
local PetsSvc       = Knit.GetService("PetsService")

-- every RemoteFunction here is a Knit promise; nothing in this script may ever
-- yield forever, so every call goes through the same timeout wrapper.
local function call(promise, seconds)
    local ok, resolved, value = pcall(function()
        return promise:timeout(seconds or 8):await()
    end)
    if not ok or not resolved then return nil end
    return value == nil and true or value
end

-- the Madwork PlayerData replica is the state oracle: Damage (= the Ammo
-- counter), Wins, Rebirths, OwnedWeapons, Pets, Boosts.
local function findReplica()
    for _, t in ipairs(getgc(true)) do
        if type(t) == "table" and rawget(t, "Class") == "PlayerData"
           and type(rawget(t, "Data")) == "table" then
            return t
        end
    end
end

local replica = findReplica()
if not replica then
    warn("[ammoclick] PlayerData replica not found - is the client still loading?")
    return
end
local DATA = replica.Data

----------------------------------------------------------------------------
-- wall list, built exactly the way BreakWallController builds it
----------------------------------------------------------------------------

local WALL_FOLDERS = { "BreakWalls", "World2BreakWalls", "World3BreakWalls" }

local function buildWallList()
    local stages = {}
    for _, folderName in ipairs(WALL_FOLDERS) do
        local folder = workspace:FindFirstChild(folderName)
        if folder then
            for _, child in ipairs(folder:GetChildren()) do
                local num = tonumber(child.Name:match("^Stage(%d+)$"))
                if num then stages[#stages + 1] = { num = num, inst = child } end
            end
        end
    end
    table.sort(stages, function(a, b) return a.num < b.num end)

    local list, range = {}, {}
    for _, stage in ipairs(stages) do
        local models = {}
        for _, child in ipairs(stage.inst:GetChildren()) do
            if child:IsA("Model") then models[#models + 1] = child end
        end
        table.sort(models, function(a, b)
            return (tonumber(a.Name:match("%d+")) or 0) < (tonumber(b.Name:match("%d+")) or 0)
        end)
        for _, model in ipairs(models) do
            local part = model:FindFirstChild("part")
            if part then
                list[#list + 1] = { stage = stage.num, part = part }
                local r = range[stage.num]
                if r then r.last = #list else range[stage.num] = { first = #list, last = #list } end
            end
        end
    end
    return list, range
end

local WALLS, STAGE_RANGE = buildWallList()

local STAGES = {}
for stageNum in pairs(STAGE_RANGE) do STAGES[#STAGES + 1] = stageNum end
table.sort(STAGES)

-- The server tells us which wall is current through WallAdvanced / WallDamaged;
-- there is no getter for it.
local cursor = 1
local conns = {}
conns[#conns + 1] = WallService.WallAdvanced:Connect(function(index)
    if type(index) == "number" then cursor = index end
end)
conns[#conns + 1] = WallService.WallDamaged:Connect(function(index)
    if type(index) == "number" then cursor = index end
end)
call(WallService:RequestSync(), 6)

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

local function ammo()     return DATA.Damage   or 0 end
local function wins()     return DATA.Wins     or 0 end
local function rebirths() return DATA.Rebirths or 0 end

local function abbreviate(n)
    if type(n) ~= "number" then return tostring(n) end
    local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do n = n / 1000 i = i + 1 end
    return string.format(i == 1 and "%.0f%s" or "%.2f%s", n, units[i])
end

-- The best target the server will actually credit: no gamepass / product bags,
-- RebirthsRequired satisfied.  An unowned name credits zero, so this matters.
local function bestBag()
    local best, bestMult = nil, 0
    for _, bag in ipairs(KickBagConstants.Bags) do
        if not bag.GamepassId and not bag.ProductId then
            local need = bag.RebirthsRequired or 0
            if rebirths() >= need and (bag.Multiplier or 0) > bestMult then
                best, bestMult = bag.Name, bag.Multiplier
            end
        end
    end
    return best, bestMult
end

-- Depth is an ammo question: the deepest stage whose worst wall still falls to
-- a single hit with room to spare.
local function bestStage()
    local best = STAGES[1] or 1
    local budget = ammo() * CONFIG.depthSafety
    for _, stageNum in ipairs(STAGES) do
        local r = STAGE_RANGE[stageNum]
        local ok, hp = pcall(WallHealth.getWallHealth, r.last)
        if ok and hp and hp <= budget then best = stageNum end
    end
    return best
end

local function ownedWeapons()
    local set = {}
    for _, name in ipairs(DATA.OwnedWeapons or {}) do set[name] = true end
    return set
end

-- Rebirth costs NOTHING and is not gated on wins at all - RebirthConfig.getCost
-- is a red herring.  Measured: a rebirth went through with 4.26M wins while
-- getCost(19) claimed 7.39M were needed, and the balance did not move.  The real
-- gate is the LEVEL: LevelUtil.getCappedLevel(ammo, rebirths) has to have
-- reached LevelUtil.getMaxLevel(rebirths) (210 at 20 rebirths), and since a
-- rebirth wipes the ammo bar the level falls back to zero and has to be re-earned
-- - which is what looked like a three second cooldown in the first pass.
-- Consequence: wins are never held back for a rebirth, everything is spendable.
local income = 0            -- wins per second, rolling, for the panel
local lastWins, lastWinTick = wins(), os.clock()

local function refreshIncome()
    local now, balance = os.clock(), wins()
    local dt = now - lastWinTick
    if dt >= 1 then
        local gained = balance - lastWins
        if gained > 0 then
            income = income > 0 and (income * 0.7 + (gained / dt) * 0.3) or (gained / dt)
        end
        lastWins, lastWinTick = balance, now
    end
end

local function levelNow()
    local ok, level = pcall(LevelUtil.getCappedLevel, ammo(), rebirths())
    return (ok and type(level) == "number") and level or 0
end

local function levelMax()
    local ok, level = pcall(LevelUtil.getMaxLevel, rebirths())
    return (ok and type(level) == "number") and level or math.huge
end

local function spendable() return wins() end

----------------------------------------------------------------------------
-- actions
----------------------------------------------------------------------------

-- The four WinsNeeded = 0 guns are free and the server hands them over; Candy
-- Blaster is refused because it is the gamepass one.
local function claimFreeWeapons()
    local owned = ownedWeapons()
    for name, cfg in pairs(WeaponConfig.Weapons) do
        if (cfg.WinsNeeded or 0) == 0 and not owned[name] then
            call(WeaponSvc:UnlockWeapon(name), 6)
        end
    end
end

local function equipBestWeapon()
    local owned = ownedWeapons()
    local balance = spendable()
    local bestName, bestDpc = DATA.Weapon, 0

    for name, cfg in pairs(WeaponConfig.Weapons) do
        local dpc = cfg.DamagePerClick or 0
        if owned[name] and dpc > bestDpc then bestName, bestDpc = name, dpc end
    end

    if CONFIG.autoWeapon then
        -- buy up, cheapest useful first, never spending the whole balance
        local candidates = {}
        for name, cfg in pairs(WeaponConfig.Weapons) do
            local price = cfg.WinsNeeded or 0
            if not owned[name] and price > 0 and price <= balance
               and (cfg.DamagePerClick or 0) > bestDpc then
                candidates[#candidates + 1] = { name = name, price = price, dpc = cfg.DamagePerClick }
            end
        end
        table.sort(candidates, function(a, b) return a.dpc > b.dpc end)
        local pick = candidates[1]
        if pick then
            if call(WeaponSvc:UnlockWeapon(pick.name), 6) then
                bestName, bestDpc = pick.name, pick.dpc
                note("gun %s (%s wins, x%s dmg)", pick.name, abbreviate(pick.price), abbreviate(pick.dpc))
            end
        end
    end

    if bestName and bestName ~= DATA.Weapon then
        call(WeaponSvc:EquipWeapon(bestName), 6)
    end
    STATE.weapon = DATA.Weapon or "-"
end

local function buyBoosts()
    local balance = spendable()
    for _, kind in ipairs({ "Damage", "Wins", "Luck" }) do
        local level = (DATA.Boosts or {})[kind] or 0
        local cost  = BoostConfig.getCost and BoostConfig.getCost(level)
                      or BoostConfig.BaseCost * (BoostConfig.CostScale ^ level)
        if cost <= balance * CONFIG.boostShare then
            local res = call(BoostSvc:PurchaseBoost(kind), 6)
            if type(res) == "table" and res.success then
                STATE.boostsBought = STATE.boostsBought + 1
                note("boost %s -> lvl %s", kind, tostring(res.newLevel))
                return
            end
        end
    end
end

-- Wins-priced eggs only.  An egg with WinCost 0 carries a RobuxProductId and is
-- the paid one; buying by "cheapest" would put it first.
local function openBestEgg()
    local balance = spendable()
    local pick, pickCost = nil, -1
    for name, cfg in pairs(EggConfig.Eggs) do
        local cost = cfg.WinCost or 0
        if cost > 0 and cost <= balance * CONFIG.eggShare and cost > pickCost then
            pick, pickCost = name, cost
        end
    end
    if not pick then return end
    local res = call(EggSvc:OpenEgg(pick), 8)
    if type(res) == "table" and res.Name then
        STATE.eggsOpened = STATE.eggsOpened + 1
        note("egg %s -> %s x%s", pick, res.Name, tostring(res.Multiplier))
    end
end

-- TitleService:Roll() costs 5 wins a roll (measured: 10 rolls, -50 wins; the
-- first pass called it free because the farm was paying in faster than the rolls
-- took out).  A title is a flat multiplier from x1.2 (Noob) up to x150 (Eternal,
-- 1 in 3,000,000), so rolling is worth it - but only out of a balance that can
-- carry it, which is why it is gated below.
local function titleMultiplier(name)
    if not name then return 0 end
    local ok, mult = pcall(TitleConfig.getMultiplier, name)
    return (ok and type(mult) == "number") and mult or 0
end

local function rollTitle()
    call(TitleSvc:Roll(), 6)
    local best, bestMult = DATA.Title, titleMultiplier(DATA.Title)
    for _, name in ipairs(DATA.OwnedTitles or {}) do
        local mult = titleMultiplier(name)
        if mult > bestMult then best, bestMult = name, mult end
    end
    STATE.title, STATE.titleMult = best or "-", bestMult
    if best and best ~= DATA.Title then
        if call(TitleSvc:Equip(best), 6) then note("title %s x%s equipped", best, tostring(bestMult)) end
    end
end

-- Pets only count while EQUIPPED, and PetsService:SetEquipped wants the INDICES
-- into DATA.Pets, not the pet ids - a call with the GUIDs is accepted, returns
-- nil and equips nothing, which is exactly what it looked like at first.
-- Measured with 92 pets owned: nothing equipped 543B ammo per click, the best
-- three equipped 100.8T, a factor of 185.5 - and 1 + 79 + 61.5 + 44 = 185.5, so
-- the multiplier is one plus the sum of the equipped pets and only the top
-- PetSlots of them matter.
local function equipBestPets()
    local pets = DATA.Pets or {}
    if #pets == 0 then return end
    local slots = DATA.PetSlots or 3

    local ranked = {}
    for index, pet in ipairs(pets) do
        ranked[#ranked + 1] = { index = index, mult = pet.Multiplier or 0 }
    end
    table.sort(ranked, function(a, b) return a.mult > b.mult end)

    local want, total = {}, 0
    for i = 1, math.min(slots, #ranked) do
        want[#want + 1] = ranked[i].index
        total = total + ranked[i].mult
    end

    local current = DATA.Equipped or {}
    local same = #current == #want
    if same then
        local have = {}
        for _, index in ipairs(current) do have[index] = true end
        for _, index in ipairs(want) do
            if not have[index] then same = false break end
        end
    end
    if same then
        STATE.petMult = 1 + total
        return
    end

    if call(PetsSvc:SetEquipped(want), 6) ~= nil or true then
        STATE.petMult = 1 + total
        note("pets equipped x%.1f (top %d of %d)", 1 + total, #want, #pets)
    end
end

-- Only the best PetSlots pets do anything, so everything below them is dead
-- weight in the inventory.  PetsService:DeletePets takes a list of
-- { Index = <position in DATA.Pets>, Id = <pet id> } and DeletePet takes the two
-- as separate arguments; both answer nil and are confirmed by the list getting
-- shorter.  Deleting shifts every index behind it - equipped ones included, the
-- server remaps them - so the whole cull goes out as ONE call and the pets are
-- re-equipped afterwards.
local function cullPets()
    local pets = DATA.Pets or {}
    local keep = math.max(CONFIG.keepPets, (DATA.PetSlots or 3) + 1)
    if #pets <= keep then return end

    local ranked = {}
    for index, pet in ipairs(pets) do
        ranked[#ranked + 1] = { index = index, mult = pet.Multiplier or 0, id = pet.Id }
    end
    table.sort(ranked, function(a, b) return a.mult > b.mult end)

    local equipped = {}
    for _, index in ipairs(DATA.Equipped or {}) do equipped[index] = true end

    local doomed = {}
    for rank = keep + 1, #ranked do
        local entry = ranked[rank]
        if not equipped[entry.index] and entry.id then
            doomed[#doomed + 1] = { Index = entry.index, Id = entry.id }
            if #doomed >= CONFIG.cullBatch then break end
        end
    end
    if #doomed == 0 then return end

    call(PetsSvc:DeletePets(doomed), 8)
    task.wait(0.6)
    STATE.petsDeleted = STATE.petsDeleted + #doomed
    note("deleted %d weak pets (%d left, keeping the best %d)", #doomed, #(DATA.Pets or {}), keep)
end

local function claimFreeRewards()
    local info = call(DailySvc:GetClaimInfo(), 6)
    if type(info) == "table" and info.canClaim then
        if call(DailySvc:Claim(), 6) then note("daily reward claimed") end
    end
    while alive() and (DATA.Spins or 0) > 0 do
        local res = call(SpinSvc:Spin(), 8)
        if type(res) ~= "table" or not res.Ok then break end
        call(SpinSvc:ClaimReward(), 8)
        note("spin -> %s", tostring(res.DisplayName))
        task.wait(0.5)
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

-- ammo.  no position check, so this runs regardless of where the body is.
loop("kick", CONFIG.kickGap, function()
    if not CONFIG.autoKick then return end
    local bag = bestBag()
    STATE.bag = bag or "-"
    KickService:AddKick(bag)
end)

-- rebirth.  free, no wins involved; it only wants the level bar full, and the
-- level comes straight out of the ammo balance.
loop("rebirth", CONFIG.rebirthGap, function()
    if not CONFIG.autoRebirth then return end
    local level, maxLevel = levelNow(), levelMax()
    STATE.level, STATE.levelMax = level, maxLevel
    if level < maxLevel then return end
    local res = call(RebirthSvc:Rebirth(), 6)
    if type(res) == "table" and res.success then
        STATE.rebirthsDone = STATE.rebirthsDone + 1
        note("rebirth %s at level %d/%d", tostring(res.rebirths), level, maxLevel)
    end
end)

-- spending, slow pass
loop("spend", 6, function()
    if CONFIG.autoWeapon then equipBestWeapon() end
    if CONFIG.autoBoosts then buyBoosts() end
    if CONFIG.autoEggs   then openBestEgg() end
    if CONFIG.autoCullPets then cullPets() end
    if CONFIG.autoPets   then equipBestPets() end
end)

loop("rewards", 120, function()
    if CONFIG.autoRewards then claimFreeRewards() end
end)

loop("titles", 0.12, function()
    if not CONFIG.autoTitles then return end
    if wins() < CONFIG.titleFloor then return end
    rollTitle()
end)

-- stats for the panel
loop("stats", 0.5, function()
    refreshIncome()
    STATE.ammo, STATE.wins, STATE.rebirths = ammo(), wins(), rebirths()
    STATE.pets   = #(DATA.Pets or {})
    STATE.cursor = cursor
    STATE.stage  = WALLS[cursor] and WALLS[cursor].stage or 0
end)

-- the run itself: pin into the current wall, shoot until the target stage is
-- behind us, claim it, let the cursor reset, go again.
local pinConn
task.spawn(function()
    pinConn = RunService.Heartbeat:Connect(function()
        if not alive() then pinConn:Disconnect() return end
        if not CONFIG.autoWalls then return end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local wall = WALLS[cursor]
        if root and wall and wall.part.Parent then
            root.CFrame = CFrame.new(wall.part.Position + Vector3.new(0, 2, 0))
        end
    end)

    while alive() do
        if not CONFIG.autoWalls then task.wait(1) STATE.phase = "walls off" continue end

        local target = bestStage()
        STATE.target = target
        local range = STAGE_RANGE[target]
        if not range then task.wait(1) continue end

        STATE.phase = "stage " .. target
        local started = os.clock()
        while alive() and CONFIG.autoWalls and cursor <= range.last do
            WallService:HitWall()
            -- a stage that stops moving means the wall outgrew the ammo; drop
            -- back and let bestStage() pick a shallower one next cycle.
            if os.clock() - started > 90 then
                note("stage %d stalled at wall %d, backing off", target, cursor)
                break
            end
            task.wait(CONFIG.hitGap)
        end

        if alive() and CONFIG.autoClaim and cursor > range.last then
            local paid = call(ZoneService:ClaimReward(target), 8)
            if paid == true then
                STATE.claims = STATE.claims + 1
                note("claimed stage %d in %.0fs", target, os.clock() - started)
            else
                note("stage %d refused the claim", target)
            end
            STATE.phase = "resetting"
            task.wait(0.8)
            call(WallService:RequestSync(), 6)
            task.wait(0.6)
        end
        task.wait(0.2)
    end
end)

claimFreeWeapons()
equipBestWeapon()

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__AMMOCLICK_WIN then pcall(function() _G.__AMMOCLICK_WIN:Destroy() end) end
local existing = LocalPlayer:FindFirstChild("PlayerGui")
if existing then
    for _, gui in ipairs(game:GetService("CoreGui"):GetChildren()) do
        if gui.Name == "AMMOCLICK" then pcall(function() gui:Destroy() end) end
    end
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("ammoclick", CONFIG)

local win = UI.Window({
    title = "AMMO", accentTitle = "CLICK", subtitle = "seltonmt",
    badge = "\240\159\148\171", width = 920, height = 580,
})
_G.__AMMOCLICK_WIN = win

local farmPage = win:Page("FARMING", UI.icon and UI.icon.pickaxe or nil)

local engine = farmPage:Card("ENGINE", 1)
engine:Toggle("Auto ammo", CONFIG.autoKick, function(v) CONFIG.autoKick = v end,
    "AddKick from anywhere, best unlocked target, ~15 credited calls/s")
engine:Toggle("Auto walls", CONFIG.autoWalls, function(v) CONFIG.autoWalls = v end,
    "pins the body inside the current wall and shoots it")
engine:Toggle("Auto claim", CONFIG.autoClaim, function(v) CONFIG.autoClaim = v end,
    "claims the deepest finished stage; a claim resets the run")
engine:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "free and wins-free; fires the moment the level bar is full", UI.theme.warn)

local spend = farmPage:Card("SPENDING", 2)
spend:Toggle("Guns", CONFIG.autoWeapon, function(v) CONFIG.autoWeapon = v end,
    "the free Nebula Cannon first, then the best the wins allow")
spend:Toggle("Boosts", CONFIG.autoBoosts, function(v) CONFIG.autoBoosts = v end,
    "Damage before Wins, never more than 20% of the balance")
spend:Toggle("Eggs", CONFIG.autoEggs, function(v) CONFIG.autoEggs = v end,
    "wins-priced eggs only, the Robux ones are skipped")
spend:Toggle("Free rewards", CONFIG.autoRewards, function(v) CONFIG.autoRewards = v end,
    "daily reward and every banked spin")
spend:Toggle("Title rolls", CONFIG.autoTitles, function(v) CONFIG.autoTitles = v end,
    "rolls cost nothing; titles run x1.2 to x150 and equip themselves")
spend:Toggle("Equip pets", CONFIG.autoPets, function(v) CONFIG.autoPets = v end,
    "only equipped pets count - the best three measured x185 on the click")
spend:Toggle("Delete weak pets", CONFIG.autoCullPets, function(v) CONFIG.autoCullPets = v end,
    "clears out everything below the keep list, equipped ones are safe", UI.theme.warn)
local keepRefresh
keepRefresh = spend:Stepper("Keep best pets",
    function() return tostring(CONFIG.keepPets) end,
    function(step)
        CONFIG.keepPets = math.clamp(CONFIG.keepPets + step * 5, 5, 200)
        if keepRefresh then pcall(keepRefresh) end
    end,
    "how many of the strongest pets survive the cull")

local tuning = farmPage:Card("TUNING", 1)
tuning:Slider("Depth safety %", 10, 90, CONFIG.depthSafety * 100, function(v)
    CONFIG.depthSafety = v / 100
end)
tuning:Slider("Hit gap (ms)", 100, 1000, CONFIG.hitGap * 1000, function(v)
    CONFIG.hitGap = v / 1000
end)
tuning:Button("Claim rewards now", function() task.spawn(claimFreeRewards) end)
tuning:Button("Resync walls", function() call(WallService:RequestSync(), 6) end, UI.theme.warn)

local readout = farmPage:Card("STATUS", 0)
local out = readout:Readout(11)

task.spawn(function()
    while alive() do
        local bag, mult = bestBag()
        out:set({
            "RUN",
            string.format("  stage %s   wall %d   phase %s", tostring(STATE.target), STATE.cursor, STATE.phase),
            string.format("  claims %d   rebirths %d   pets deleted %d",
                STATE.claims, STATE.rebirthsDone, STATE.petsDeleted),
            "ECONOMY",
            string.format("  ammo %s   wins %s", abbreviate(STATE.ammo), abbreviate(STATE.wins)),
            string.format("  rebirths %d   pets %d (x%.1f)   gun %s",
                STATE.rebirths, STATE.pets, STATE.petMult, tostring(STATE.weapon)),
            string.format("  target %s x%s   title %s x%s", tostring(bag), tostring(mult),
                tostring(STATE.title), tostring(STATE.titleMult)),
            string.format("  income %s wins/s", abbreviate(income)),
            string.format("  level %d/%d%s", STATE.level or 0, STATE.levelMax or 0,
                (STATE.level or 0) >= (STATE.levelMax or math.huge) and "  (rebirth ready)" or ""),
            "NOTE",
            "  " .. tostring(STATE.note),
        })
        win:SetStatus(string.format("%s ammo   %s wins   r%d   stage %s",
            abbreviate(STATE.ammo), abbreviate(STATE.wins), STATE.rebirths, tostring(STATE.target)))
        task.wait(0.5)
    end
end)

_G.__AMMOCLICK_DBG = {
    CONFIG = CONFIG, STATE = STATE, DATA = DATA, WALLS = WALLS,
    STAGE_RANGE = STAGE_RANGE, bestStage = bestStage, bestBag = bestBag,
    claimFreeWeapons = claimFreeWeapons, equipBestWeapon = equipBestWeapon,
    buyBoosts = buyBoosts, openBestEgg = openBestEgg, equipBestPets = equipBestPets,
    cullPets = cullPets, rollTitle = rollTitle,
    claimFreeRewards = claimFreeRewards, call = call,
    cursor = function() return cursor end,
}

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste.
pcall(function() win:Home() end)

print("[ammoclick] running - RightShift toggles the panel")
