--!nocheck
-- [NEW] Clicker Simulator! (Cooked Click) - place 134719268825886
--
-- The game is clicks + pets. Clicking pays the Clicks currency, pets multiply
-- what a click is worth (their Clicks stats are summed), rebirths multiply it
-- again, and Clicks buy the eggs that hatch better pets. Gems (quests, safes)
-- buy the permanent upgrades. Everything below was measured on 2026-09-24:
--
--   * Remotes are all named "" - the real names live in
--     Library.Client.Network: `Network.Channel("<ch>"):FireServer("<name>", ...)`.
--   * Click income: Channel "Click" / FireServer("Click"). Not position gated.
--     The game's own autoclicker (bought for 50 gems) adds ~2.4 clicks/s,
--     firing at 0.1s (the game's GetClickInterval is 0.096) adds ~8 more:
--     802/s autoclicker alone vs 3564/s both, at a click multiplier of 337.
--   * Eggs: OpenEgg.Request(egg, count) - the game's own path. It IS position
--     gated: it works standing at the pad and silently does nothing from the
--     next island. The pads sit next to each other, so the body moves at most a
--     few dozen studs on the same level. It NEVER crosses to another island:
--     repeated 2000-stud warps froze the whole session once (UI gone, even the
--     player's own clicks dead) and only a rejoin fixed it.
--   * EquipBest: Channel "Pets" / FireServer("EquipBest").
--   * DeletePetsBulk: FireServer("DeletePetsBulk", {uid,...}) - measured to
--     delete exactly the listed uids and nothing else.
--   * Rebirth: Channel "Rebirths" / FireServer("Rebirth", buttonIndex). The
--     bare call without an index does nothing. Cost is
--     Balancing.Rebirths.GetCost(amount, Currency "Rebirths", mastery mult),
--     linear (~+209 per rebirth at R=56). The balance goes to ZERO on every
--     rebirth, whatever the cost was.
--   * Quest claims: the Claim remote answers false to every argument shape
--     tried. The quest panel's own Claim buttons work through getconnections.
--   * MiniUpgrades: InvokeServer("Purchase", id) -> true, priced in gems.
--   * Gem upgrades (ClickUpgrade, Combo, ...): bought through the Upgrades
--     panel's Buy buttons, same pattern as the quests. NOT yet measured - there
--     were never 1000 gems while this was written. The first buy is checked
--     against the level and backs off if nothing moved.
--
-- Honeypots: channel "gJKGFsvsjdhgvsiduzgvu" (FN Rebirth) and RNG2Rebirths
-- "R3birth" look exactly like the decoys in Cut Grass. The fire helpers refuse
-- them by name so no later edit can reintroduce them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

_G.__CLICKSIM = (_G.__CLICKSIM or 0) + 1
local GEN = _G.__CLICKSIM
local function alive() return _G.__CLICKSIM == GEN end

----------------------------------------------------------------------------
-- config / state
----------------------------------------------------------------------------

local CONFIG = {
    auto          = true,   -- master

    autoClick     = true,   -- fire the Click channel at clickGap
    gameClicker   = true,   -- keep the game's own autoclicker switched on
    autoEggs      = true,   -- hatch the egg with the best value per click
    autoEquip     = true,   -- EquipBest after every hatch
    autoPurge     = true,   -- delete pets that can never make the team
    autoRebirth   = true,   -- rebirth when it beats the best egg per click
    autoQuests    = true,   -- claim finished quests
    autoMilestones = true,  -- claim every reached milestone (achievement) stage
    autoGems      = true,   -- spend gems on mini upgrades and upgrades
    autoIslands   = true,   -- buy the next island gate with clicks
    bestIsland    = true,   -- stand on the highest unlocked island (boost + eggs)

    clickGap      = 0.1,    -- the game's own click interval is 0.096
    eggBias       = 1.5,    -- eggs are preferred by this factor over rebirths
    keepPets      = 50,     -- purge weak pets once the inventory holds this many
    eggRange      = 400,    -- only pads this close (horizontal studs) ...
    levelBand     = 60,     -- ... and on the same level are considered
    eggWait       = 60,     -- an egg may cost at most this many seconds of income
                            -- beyond the balance, or it is not a candidate
    minChance     = 0.01,   -- pets rarer than this are a lottery, not value
    islandSave    = 600,    -- save for the next island once it is this many
                            -- seconds of income away. 120 was too short: at
                            -- Sakura the rebirths reset the balance every
                            -- second and Volcano (15Q at 3.3T/s) never came
                            -- inside the window, so it was never saved for
    hatchPause    = 0.5,    -- pause after a hatch animation so the HUD shows
}

local STATE = {
    phase = "starting", note = "starting",
    clicks = 0, rate = 0, multi = 0, rebirths = 0, gems = 0,
    pets = 0, petMax = 200, slots = 4, teamSum = 0, worst = 0,
    bestEgg = "-", eggGain = 0, eggCost = 0,
    hatched = 0, deleted = 0, rebirthsDone = 0, claimed = 0, gemBuys = 0,
    lastBuy = "-", island = "-", nextIsland = "-", nextIslandCost = 0, islandsBought = 0,
    milestones = 0,
}

local function note(fmt, ...)
    STATE.note = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

----------------------------------------------------------------------------
-- modules (required behind a wall clock: a require that yields must cost
-- its own feature, never the whole script)
----------------------------------------------------------------------------

local function need(inst, timeout)
    if not inst then return nil end
    local done, ok, res = false, false, nil
    task.spawn(function()
        ok, res = pcall(require, inst)
        done = true
    end)
    local t = 0
    while not done and t < (timeout or 10) do
        task.wait(0.1)
        t = t + 0.1
    end
    if done and ok then return res end
    return nil
end

local Library = ReplicatedStorage:WaitForChild("Library", 10)
local Client = Library and Library:WaitForChild("Client", 10)
if not Client then
    warn("[clickersim] Library.Client not found - wrong game?")
    return
end

local Net           = need(Client:WaitForChild("Network", 10))
local Stats         = need(Client:WaitForChild("Stats", 10))
local Currency      = need(Client:WaitForChild("Currency", 10))
local ClickFrontend = need(Client:WaitForChild("ClickFrontend", 10))
local OpenEgg       = need(Client:WaitForChild("OpenEgg", 10))
local EggsFrontend  = need(Client:WaitForChild("EggsFrontend", 10))
local Mastery       = need(Client:WaitForChild("MasteryFrontend", 10))
local PetsFrontend  = need(Client:WaitForChild("Pets", 10))
local CustomGUI     = need(Client:WaitForChild("CustomGUI", 10))
local Settings      = need(Client:WaitForChild("Settings", 10))
local AchUtil       = Library:FindFirstChild("Utils")
    and need(Library.Utils:FindFirstChild("AchievementsUtil"), 5)
local Directory     = need(Library:WaitForChild("Directory", 10))
local Balancing     = need(Library:WaitForChild("Balancing", 10))
local Constants     = need(Library:WaitForChild("Constants", 10))
local Abbrev        = Library:FindFirstChild("Functions")
    and need(Library.Functions:FindFirstChild("AbbreviateNumber"), 5)

if not (Net and Stats and Currency and Directory and Balancing) then
    warn("[clickersim] core modules did not load")
    return
end

----------------------------------------------------------------------------
-- network helpers, honeypot-proof
----------------------------------------------------------------------------

local HONEYPOT_CHANNEL = { gJKGFsvsjdhgvsiduzgvu = true, RNG2Rebirths = true }
local HONEYPOT_NAME = { R3birth = true }

local channels = {}
local function chan(name)
    if HONEYPOT_CHANNEL[name] then return nil end
    local c = channels[name]
    if not c then
        local ok, res = pcall(Net.Channel, name)
        if not ok then return nil end
        c = res
        channels[name] = c
    end
    return c
end

local function fire(ch, name, ...)
    if HONEYPOT_NAME[name] then return false end
    local c = chan(ch)
    if not c then return false end
    return pcall(c.FireServer, c, name, ...)
end

local function invoke(ch, name, timeout, ...)
    if HONEYPOT_NAME[name] then return nil, "refused" end
    local c = chan(ch)
    if not c then return nil, "no channel" end
    local args = table.pack(...)
    local done, ok, res = false, false, nil
    task.spawn(function()
        ok, res = pcall(function()
            return c:InvokeServer(name, table.unpack(args, 1, args.n))
        end)
        done = true
    end)
    local t = 0
    while not done and t < (timeout or 8) do
        task.wait(0.1)
        t = t + 0.1
    end
    if not done then return nil, "timeout" end
    if not ok then return nil, tostring(res) end
    return res
end

----------------------------------------------------------------------------
-- oracles
----------------------------------------------------------------------------

local function data()
    local ok, d = pcall(Stats.Local)
    if ok and type(d) == "table" then return d end
    return nil
end

local function cur(name)
    local ok, v = pcall(Currency.Get, name)
    return ok and tonumber(v) or 0
end

local function root()
    local c = LocalPlayer.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    if h and h.Health <= 0 then return nil end
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function abbreviate(n)
    n = tonumber(n) or 0
    if Abbrev then
        local ok, s = pcall(Abbrev, n)
        if ok and s then return tostring(s) end
    end
    return tostring(math.floor(n))
end

local function clickMulti()
    if not ClickFrontend then return 0 end
    local ok, v = pcall(ClickFrontend.GetClickMulti)
    return ok and tonumber(v) or 0
end

----------------------------------------------------------------------------
-- pets
----------------------------------------------------------------------------

local function petStat(p)
    local ok, s = pcall(Balancing.GetPetStat, "Clicks", p.id, p.xp or 0, p.v, p.m, p.Shiny == true)
    return ok and tonumber(s) or 0
end

local baseCache = {}
local function baseStat(id)
    local s = baseCache[id]
    if s == nil then
        local ok, v = pcall(Balancing.GetPetStat, "Clicks", id, 0, "Normal", nil, false)
        s = ok and tonumber(v) or 0
        baseCache[id] = s
    end
    return s
end

-- The team is the best N pets OWNED, not the ones currently worn: EquipBest
-- seats exactly those, and reading the worn set right after a hatch would
-- compare against a team that is about to change.
-- d.MaxEquippedPets / MaxInventoryPets do NOT include the mini upgrades:
-- after buying PetEquip1 the field still read 4 while five pets were worn.
-- The frontend's Effective* accessors are the real limits.
local function effective(fnName, fallback)
    if PetsFrontend and PetsFrontend[fnName] then
        local ok, v = pcall(PetsFrontend[fnName])
        if ok and tonumber(v) then return tonumber(v) end
    end
    return fallback
end

local function teamInfo()
    local d = data()
    if not d then return nil end
    local slots = effective("GetEffectiveMaxEquippedPets", d.MaxEquippedPets or 4)
    local list = {}
    for uid, p in pairs(d.Pets or {}) do
        if type(p) == "table" and p.id then
            list[#list + 1] = { uid = uid, p = p, s = petStat(p) }
        end
    end
    table.sort(list, function(a, b) return a.s > b.s end)
    local top, sum = {}, 0
    for i = 1, math.min(slots, #list) do
        top[list[i].uid] = true
        sum = sum + list[i].s
    end
    local worst = (#list >= slots) and list[slots].s or 0
    return {
        list = list, top = top, sum = sum, worst = worst, slots = slots,
        count = #list, max = effective("GetEffectiveMaxInventoryPets", d.MaxInventoryPets or 200),
        equipped = d.EquippedPets or {},
    }
end

local function petCount()
    local d = data()
    local n = 0
    if d then for _ in pairs(d.Pets or {}) do n = n + 1 end end
    return n
end

local function equipBest()
    fire("Pets", "EquipBest")
end

-- Only plain low-rarity pets are ever deleted, and only when they cannot make
-- the team. Anything Legendary and up, every variant (golden, shiny, rainbow),
-- mutated, locked or untradable pet is left alone.
local DELETABLE_RARITY = { Basic = true, Rare = true, Epic = true }

local function isPlain(p)
    if p.Shiny or p.Locked then return false end
    if p.v ~= nil and p.v ~= "Normal" then return false end
    if type(p.m) == "table" and next(p.m) ~= nil then return false end
    if p.m ~= nil and type(p.m) ~= "table" then return false end
    return true
end

local function purge(force)
    local team = teamInfo()
    if not team then return 0 end
    if not force and team.count < CONFIG.keepPets then return 0 end
    local victims = {}
    for _, e in ipairs(team.list) do
        local dp = Directory.Pets[e.p.id]
        if not team.top[e.uid] and not team.equipped[e.uid]
            and dp and dp.Tradable == true and DELETABLE_RARITY[dp.Rarity]
            and isPlain(e.p) and e.s <= team.worst then
            victims[#victims + 1] = e.uid
        end
    end
    if #victims == 0 then return 0 end
    local before = team.count
    for i = 1, #victims, 50 do
        local chunk = {}
        for j = i, math.min(i + 49, #victims) do chunk[#chunk + 1] = victims[j] end
        fire("Pets", "DeletePetsBulk", chunk)
        task.wait(0.4)
    end
    task.wait(0.8)
    local gone = math.max(0, before - petCount())
    STATE.deleted = STATE.deleted + gone
    if gone > 0 then note("deleted %d weak pets", gone) end
    return gone
end

----------------------------------------------------------------------------
-- eggs
----------------------------------------------------------------------------

local eggBackoff = {}   -- egg -> os.clock() until which it is skipped

local function eggFolder()
    local map = workspace:FindFirstChild("_MAP")
    local inter = map and map:FindFirstChild("Interact")
    return inter and inter:FindFirstChild("Eggs")
end

local function isPaidEgg(name)
    if not EggsFrontend then return false end
    local r = false
    pcall(function() r = EggsFrontend.IsRobux(name) or EggsFrontend.IsExclusive(name) end)
    return r
end

local function eggCost(name, info)
    if EggsFrontend then
        local ok, c = pcall(EggsFrontend.GetEggCost, name)
        if ok and tonumber(c) then return tonumber(c) end
    end
    return tonumber(info.Cost) or math.huge
end

local function maxHatch(name)
    if not EggsFrontend then return 1 end
    local ok, n = pcall(EggsFrontend.GetMaxHatchCount, name)
    return (ok and tonumber(n)) and math.max(1, math.floor(n)) or 1
end

-- Value of an egg = expected rise of the team's summed Clicks stat per hatch,
-- i.e. sum over the pool of chance * how far that pet beats the weakest seat.
--
-- Two cuts, both measured the hard way on the first run: the SixSevenEgg
-- (100 billion) came out on top because one Divine pet at 0.00005% carries a
-- stat so large it dominated the expectation, and the script sat "saving"
-- for an egg that was 17 days of income away. So pets under minChance do not
-- count, and an egg must be affordable within eggWait seconds of income.
local function eggList(team)
    local out = {}
    local hrp = root()
    local folder = eggFolder()
    if not (hrp and folder and team) then return out end
    local here = hrp.Position
    local reach = cur("Clicks") + math.max(0, STATE.rate) * CONFIG.eggWait
    for _, m in ipairs(folder:GetChildren()) do
        local e = Directory.Eggs[m.Name]
        if e and e.Info and e.Info.Currency == "Clicks" and type(e.Pets) == "table"
            and not isPaidEgg(m.Name) and (eggBackoff[m.Name] or 0) < os.clock() then
            local okp, pos = pcall(function() return m:GetPivot().Position end)
            if okp and pos then
                local dy = math.abs(pos.Y - here.Y)
                local dxz = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(here.X, 0, here.Z)).Magnitude
                if dy <= CONFIG.levelBand and dxz <= CONFIG.eggRange then
                    local cost = eggCost(m.Name, e.Info)
                    if cost <= reach then
                        local W, gain = 0, 0
                        for _, pe in ipairs(e.Pets) do W = W + (tonumber(pe.Weight) or 0) end
                        if W > 0 then
                            for _, pe in ipairs(e.Pets) do
                                local chance = (tonumber(pe.Weight) or 0) / W
                                if chance >= CONFIG.minChance then
                                    gain = gain + chance * math.max(0, baseStat(pe.Value) - team.worst)
                                end
                            end
                        end
                        out[#out + 1] = { name = m.Name, pos = pos, cost = cost, gain = gain,
                            score = (cost > 0) and gain / cost or 0 }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.score > b.score end)
    return out
end

-- Every OpenEgg request takes Settings.ShowUI:Lock() and the HUD stays hidden
-- until that request's animation has played. Firing a hatch every second while
-- one animation lasts several queued them up: the lock count sat at 2-4 for a
-- full 20s sample and the player saw the HUD come back "after a long time".
-- So the next hatch waits for the lock to be free - hatching runs at the
-- speed of the animation, like a player's would.
local function uiLocks()
    if not (Settings and Settings.ShowUI) then return 0 end
    local ok, n = pcall(function() return Settings.ShowUI._count end)
    return ok and tonumber(n) or 0
end

local function waitUiFree(cap)
    local t = 0
    while uiLocks() > 0 and t < cap do
        task.wait(0.2)
        t = t + 0.2
    end
    return uiLocks() == 0
end

local function hatch(egg)
    local hrp = root()
    if not hrp then return false end
    -- something else may hold the lock (a menu the player opened); never
    -- stall on it for good
    waitUiFree(8)
    local count = math.min(maxHatch(egg.name), math.floor(cur("Clicks") / egg.cost))
    if count < 1 then return false end

    local team = teamInfo()
    if team and team.count + count > team.max - 5 then
        purge(true)
        if petCount() + count > (team.max - 5) then
            note("inventory full - purge found nothing deletable")
            return false
        end
    end

    -- Stand beside the pad. The body WALKS there (Humanoid:MoveTo) - the game
    -- validates positions and big warps froze the session once. Only a short
    -- hop is allowed as a fallback when the walk gets stuck. The body then
    -- stays at the pad, so repeated hatches never move it again.
    local spot = egg.pos + Vector3.new(0, 3, 6)
    if (hrp.Position - spot).Magnitude > 14 then
        local hum = hrp.Parent and hrp.Parent:FindFirstChildOfClass("Humanoid")
        if hum then
            hum:MoveTo(spot)
            local w = 0
            while w < 10 and (hrp.Position - spot).Magnitude > 12 do
                task.wait(0.25)
                w = w + 0.25
            end
        end
        if (hrp.Position - spot).Magnitude > 12 then
            if (hrp.Position - spot).Magnitude > 150 then
                eggBackoff[egg.name] = os.clock() + 60
                note("%s: pad not reachable on foot", egg.name)
                return false
            end
            hrp.CFrame = CFrame.new(spot)
        end
        task.wait(1.0)
    end

    -- Request invokes the server synchronously; in its own thread a request
    -- that never answers costs that thread, not the decision loop. Success is
    -- read off the pet count, never off the balance (income swamps the price).
    -- RestoreUI = true is what the game's own egg button passes. Without it
    -- the hatch animation hides the HUD and completeRequest never brings it
    -- back - the first build left the player's UI gone after every hatch
    -- until they opened an egg by hand.
    local n0 = petCount()
    task.spawn(function() pcall(OpenEgg.Request, egg.name, count, { RestoreUI = true }) end)
    local t = 0
    while t < 6 and petCount() <= n0 do
        task.wait(0.2)
        t = t + 0.2
    end
    local got = petCount() - n0
    if got <= 0 then
        -- one refusal is not a verdict (a hatch animation can still be
        -- running); back off briefly and let the next pass retry
        eggBackoff[egg.name] = os.clock() + 15
        note("%s: no pet arrived, retry in 15s", egg.name)
        return false
    end
    STATE.hatched = STATE.hatched + got
    note("hatched %d x %s", got, egg.name)
    waitUiFree(10)
    if CONFIG.autoEquip then equipBest() end
    task.wait(CONFIG.hatchPause)
    return true
end

----------------------------------------------------------------------------
-- rebirth
----------------------------------------------------------------------------

local function rebirthCost(amount, R)
    local mul = 1
    if Mastery then
        local d = data()
        local ok, m = pcall(Mastery.GetPower, d, "RebirthCostMultiplier")
        if ok and tonumber(m) then mul = tonumber(m) end
    end
    local ok, c = pcall(Balancing.Rebirths.GetCost, amount, R, mul)
    return ok and tonumber(c) or math.huge
end

-- Buttons 1-3 are free; 4 and up are bought with gems in the RebirthShop, one
-- after another, and count as usable once they appear in OwnedRebirthButtons
-- (the shop's own test: value == index, or [index] == true).
local function ownsRebirthButton(d, idx)
    for i, v in pairs(d.OwnedRebirthButtons or {}) do
        if v == idx or (v == true and tonumber(i) == idx) then return true end
    end
    return false
end

-- Largest affordable button. The balance resets to zero on any rebirth, so
-- the bigger the amount that fits, the less of the balance is thrown away.
local function rebirthPick()
    local d = data()
    if not (d and Constants and Constants.Rebirths) then return nil end
    local R = cur("Rebirths")
    local clicks = cur("Clicks")
    local best
    for i, b in pairs(Constants.Rebirths) do
        if type(i) == "number" and type(b) == "table" and (i <= 3 or ownsRebirthButton(d, i)) then
            local amt = b.Amount or 1
            local c = rebirthCost(amt, R)
            if c <= clicks and (not best or amt > best.amt) then
                best = { idx = i, amt = amt, cost = c }
            end
        end
    end
    return best
end

local function doRebirth(pick)
    local d = data()
    local before = d and d.TotalRebirths or 0
    fire("Rebirths", "Rebirth", pick.idx)
    local t = 0
    while t < 4 do
        task.wait(0.25)
        t = t + 0.25
        local dd = data()
        if dd and (dd.TotalRebirths or 0) > before then
            STATE.rebirthsDone = STATE.rebirthsDone + ((dd.TotalRebirths or 0) - before)
            note("rebirth +%d", (dd.TotalRebirths or 0) - before)
            return true
        end
    end
    note("rebirth (button %d) was not credited", pick.idx)
    return false
end

----------------------------------------------------------------------------
-- islands
--
-- The gates behind spawn are islands bought with Clicks (Directory.Islands:
-- Winter 1.25M, Forest 75M, Desert 900M, Candy 50B, ...), each chained to its
-- PreviousIsland. Standing on one adds its ClicksBoost to every click and
-- puts its eggs in reach; several rebirth buttons need one too. Travel uses
-- the game's own Portals:TeleportToIsland - server side, measured clean -
-- never a CFrame warp across islands.
----------------------------------------------------------------------------

local function unlockedSet(d)
    local s = {}
    for _, v in pairs(d.UnlockedIslands or {}) do s[tostring(v)] = true end
    return s
end

local function overworldIslands()
    local list = {}
    for id, isl in pairs(Directory.Islands or {}) do
        if type(isl) == "table" and isl.World == "Overworld" and tonumber(isl.IslandNumber) then
            list[#list + 1] = { id = id, n = tonumber(isl.IslandNumber),
                cost = tonumber(isl.Cost) or 0, prev = isl.PreviousIsland }
        end
    end
    table.sort(list, function(a, b) return a.n < b.n end)
    return list
end

local function islandInfo()
    local d = data()
    if not d then return nil end
    local have = unlockedSet(d)
    local best, nxt
    for _, isl in ipairs(overworldIslands()) do
        if have[isl.id] then
            best = isl
        elseif not nxt and (isl.prev == nil or have[isl.prev]) then
            nxt = isl
        end
    end
    return { best = best, next = nxt, current = d.CurrentIsland, have = have }
end

local lastIslandHop = 0

local function goBestIsland(info)
    info = info or islandInfo()
    if not (info and info.best) or info.current == info.best.id then return false end
    if os.clock() - lastIslandHop < 45 then return false end
    lastIslandHop = os.clock()
    local res = invoke("Portals", "TeleportToIsland", 10, info.best.id)
    task.wait(3)
    local d = data()
    if d and d.CurrentIsland == info.best.id then
        note("moved to %s", info.best.id)
        return true
    end
    note("teleport to %s was refused (%s)", info.best.id, tostring(res))
    return false
end

local function buyIsland(isl)
    local res = invoke("Portals", "PurchaseIsland", 8, isl.id)
    task.wait(1.2)
    local d = data()
    if d and unlockedSet(d)[isl.id] then
        STATE.islandsBought = STATE.islandsBought + 1
        note("unlocked %s for %s", isl.id, abbreviate(isl.cost))
        return true
    end
    note("buying %s was refused (%s)", isl.id, tostring(res))
    return false
end

----------------------------------------------------------------------------
-- quests
----------------------------------------------------------------------------

local claimNext = {}

local function questRows()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local ok, content = pcall(function()
        return pg.Main.Right.Expanded.Content.Quests.Scrolling.Content
    end)
    return ok and content or nil
end

local function claimQuests()
    if not getconnections then return end
    local d = data()
    local rows = questRows()
    if not (d and rows) then return end
    for id, q in pairs(d.Quests or {}) do
        if type(q) == "table" then
            -- Completed == true marks a questline that is FINISHED (Amount 0,
            -- no Claim row exists) - it is not a claimable quest.
            local amount = tonumber(q.Amount) or 0
            local ready = amount > 0 and (tonumber(q.Progress) or 0) >= amount
            local key = id .. "_" .. tostring(q.Tier)
            if ready and (claimNext[key] or 0) < os.clock() then
                local row = rows:FindFirstChild(key)   -- exact name, never a pattern
                local btn = row and row:FindFirstChild("Frame")
                btn = btn and btn:FindFirstChild("Bottom")
                btn = btn and btn:FindFirstChild("Claim")
                btn = btn and btn:FindFirstChild("Button")
                if btn then
                    claimNext[key] = os.clock() + 30
                    local tier = q.Tier
                    local progress = tonumber(q.Progress) or 0
                    for _, c in ipairs(getconnections(btn.Activated)) do
                        pcall(function() c:Fire() end)
                    end
                    task.wait(1.2)
                    local after = data()
                    local q2 = after and after.Quests and after.Quests[id]
                    if not q2 or q2.Tier ~= tier or (tonumber(q2.Progress) or 0) < progress then
                        STATE.claimed = STATE.claimed + 1
                        note("claimed quest %s", id)
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------------
-- milestones
--
-- The "Milestones" button opens the Achievements panel: Clicks, Eggs,
-- UniquePets, CollectedChests, Breakables, each with five stages (Bronze,
-- Silver, Ace, Master, Grandmaster) paying permanent buffs. The panel claims
-- with Achievements:FireServer("Claim", id) - one call, one stage (measured
-- Clicks 1 -> 2). Progress and claimedStage live in Stats.Local().Achievements.
----------------------------------------------------------------------------

local STAGE_ORDER = (AchUtil and type(AchUtil.Stages) == "table" and AchUtil.Stages)
    or { "Bronze", "Silver", "Ace", "Master", "Grandmaster" }

local function claimMilestones()
    local d = data()
    if not (d and d.Achievements and Directory.Achievements) then return end
    for id, a in pairs(Directory.Achievements) do
        if type(a) == "table" and type(a.Stages) == "table" then
            for _ = 1, #STAGE_ORDER do
                local s = d.Achievements[id]
                local claimed = s and tonumber(s.claimedStage) or 0
                local stageName = STAGE_ORDER[claimed + 1]
                local stage = stageName and a.Stages[stageName]
                local progress = s and tonumber(s.progress) or 0
                if not (stage and tonumber(stage.Requirement) and progress >= tonumber(stage.Requirement)) then
                    break
                end
                fire("Achievements", "Claim", id)
                task.wait(1.0)
                d = data()
                local s2 = d and d.Achievements and d.Achievements[id]
                if not s2 or (tonumber(s2.claimedStage) or 0) <= claimed then
                    note("milestone %s did not advance", id)
                    break
                end
                STATE.milestones = STATE.milestones + 1
                note("milestone %s -> %s", id, tostring(stageName))
            end
        end
    end
end

----------------------------------------------------------------------------
-- gems: mini upgrades and upgrades, strictly in this order
----------------------------------------------------------------------------

local GEM_PLAN = {
    { kind = "mini", id = "AutoClick" },
    { kind = "mini", id = "PetEquip1" },
    { kind = "rbtn", id = "RebirthButton" },   -- 25 / 75 / 125 ... per rebirth
    { kind = "up",   id = "ClickUpgrade" },
    { kind = "up",   id = "Combo" },
    { kind = "mini", id = "WalkSpeed1" },
    { kind = "up",   id = "HatchSpeed" },
    { kind = "up",   id = "CritChance" },
    { kind = "up",   id = "AutoClickSpeed" },
    { kind = "mini", id = "Storage1" },
}

local gemBackoff = {}

-- The shop sells rebirth buttons strictly in order: only the lowest one not
-- yet owned can be bought, and only once its island is unlocked.
local function nextRebirthButton(d)
    if not (Constants and Constants.Rebirths) then return nil end
    local have = unlockedSet(d)
    for i = 4, 64 do
        local b = Constants.Rebirths[i]
        if not b then return nil end
        if not ownsRebirthButton(d, i) then
            if b.RequiredIsland and not have[b.RequiredIsland] then return nil end
            return i, tonumber(b.Cost)
        end
    end
    return nil
end

local function gemPrice(item, d)
    if item.kind == "rbtn" then
        local idx, cost = nextRebirthButton(d)
        if not idx then return nil end
        item.idx = idx
        return cost, "Gems"
    end
    if item.kind == "mini" then
        local m = Directory.MiniUpgrades and Directory.MiniUpgrades[item.id]
        if not m or (d.MiniUpgrades and d.MiniUpgrades[item.id]) then return nil end
        return tonumber(m.Cost), m.Currency or "Gems"
    end
    local u = Directory.Upgrades and Directory.Upgrades[item.id]
    if not u or type(u.Tiers) ~= "table" then return nil end
    local lvl = (d.Upgrades and d.Upgrades[item.id]) or 0
    local t = u.Tiers[lvl + 1]
    if not t then return nil end
    return tonumber(t.Price), u.Currency or "Gems"
end

local function buyUpgradeViaPanel(id)
    if not getconnections then return false end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local ok, btn = pcall(function()
        return pg.Upgrades.Frame.Scrolling.Content[id].Content.Right.Buy.Button
    end)
    if not ok or not btn then return false end
    for _, c in ipairs(getconnections(btn.Activated)) do
        pcall(function() c:Fire() end)
    end
    return true
end

local function buyGemItem(item, price, currency)
    local d = data()
    if item.kind == "rbtn" then
        local idx = item.idx
        local res = invoke("RebirthShop", "BuyRebirthButton", 8, idx)
        task.wait(0.8)
        local dd = data()
        return res == true or (dd ~= nil and ownsRebirthButton(dd, idx))
    end
    if item.kind == "mini" then
        local res = invoke("MiniUpgrades", "Purchase", 8, item.id)
        task.wait(0.8)
        local dd = data()
        return res == true or (dd and dd.MiniUpgrades and dd.MiniUpgrades[item.id] == true)
    end
    local before = (d.Upgrades and d.Upgrades[item.id]) or 0
    if not buyUpgradeViaPanel(item.id) then return false end
    task.wait(1.2)
    local dd = data()
    return ((dd and dd.Upgrades and dd.Upgrades[item.id]) or 0) > before
end

local function spendGems()
    local d = data()
    if not d then return end
    local target
    for _, item in ipairs(GEM_PLAN) do
        local price, currency = gemPrice(item, d)
        if price and (gemBackoff[item.id] or 0) < os.clock() then
            local have = cur(currency)
            if not target then
                target = price
                if have >= price then
                    if buyGemItem(item, price, currency) then
                        STATE.gemBuys = STATE.gemBuys + 1
                        STATE.lastBuy = item.id
                        note("bought %s for %s %s", item.id, abbreviate(price), currency)
                    else
                        gemBackoff[item.id] = os.clock() + 120
                        note("%s: buy was not credited, retry in 2 min", item.id)
                    end
                    return
                end
            elseif price <= target * 0.1 and have >= price then
                -- trivially cheap next to what the gems are saved for
                if buyGemItem(item, price, currency) then
                    STATE.gemBuys = STATE.gemBuys + 1
                    STATE.lastBuy = item.id
                else
                    gemBackoff[item.id] = os.clock() + 120
                end
                return
            end
        end
    end
end

local function ensureAutoclicker()
    local d = data()
    if not d then return end
    if d.MiniUpgrades and d.MiniUpgrades.AutoClick and not (d.Autoclicker and d.Autoclicker.Enabled) then
        invoke("Click", "SetAutoclickerEnabled", 6, true)
    end
end

----------------------------------------------------------------------------
-- decision: egg or rebirth
--
-- Both are compared as "relative rise of the click multiplier per Click
-- spent". An egg raises the pets' summed stat by `gain` out of `teamSum`; a
-- rebirth raises the (1 + Rebirths) factor by one. At 56 rebirths a rebirth is
-- worth +1.75% for 12.8K while a Flower egg was worth ~+3.8% for 2.75K, so
-- eggs win by an order of magnitude until the team is saturated.
--
-- A rebirth's real price is the WHOLE balance, not the button price: the
-- balance drops to zero whatever the button cost. The first build divided by
-- the button price and burned 1.3M of a 1.5M balance on a 10-rebirth button.
--
-- Islands come first of all: a gate is permanent, raises every click and
-- opens the next eggs, so once one is within islandSave seconds of income
-- nothing else may touch the balance.
----------------------------------------------------------------------------

local lastPurge = 0

local function islandStep()
    local info = islandInfo()
    if not info then return false end
    STATE.island = info.current or "-"
    STATE.nextIsland = info.next and info.next.id or "-"
    STATE.nextIslandCost = info.next and info.next.cost or 0
    if CONFIG.autoIslands and info.next then
        local clicks = cur("Clicks")
        if clicks >= info.next.cost then
            STATE.phase = "unlocking " .. info.next.id
            if buyIsland(info.next) and CONFIG.bestIsland then goBestIsland() end
            return true
        elseif info.next.cost <= clicks + math.max(0, STATE.rate) * CONFIG.islandSave then
            local eta = math.floor((info.next.cost - clicks) / math.max(1, STATE.rate))
            STATE.phase = string.format("saving for %s (~%ds)", info.next.id, eta)
            if CONFIG.bestIsland then goBestIsland(info) end
            return true
        end
    end
    if CONFIG.bestIsland then goBestIsland(info) end
    return false
end

local function decide()
    -- Deleting runs HERE, between hatches, never beside one: a purge in
    -- another thread drops the pet count mid-hatch and reads as "no pet came".
    if CONFIG.autoPurge and os.clock() - lastPurge > 20 then
        lastPurge = os.clock()
        purge(false)
    end

    if islandStep() then return end

    local team = teamInfo()
    if not team then return end
    STATE.pets, STATE.petMax, STATE.slots = team.count, team.max, team.slots
    STATE.teamSum, STATE.worst = team.sum, team.worst

    local eggs = CONFIG.autoEggs and eggList(team) or {}
    local egg
    for _, e in ipairs(eggs) do
        if e.gain > 0 then egg = e break end
    end
    STATE.bestEgg = egg and egg.name or "-"
    STATE.eggGain = egg and egg.gain or 0
    STATE.eggCost = egg and egg.cost or 0

    local R = cur("Rebirths")
    local clicks = cur("Clicks")
    local pick = CONFIG.autoRebirth and rebirthPick() or nil
    local rebirthValue
    if pick then
        rebirthValue = (pick.amt / (1 + R)) / math.max(1, clicks)
    else
        rebirthValue = (1 / (1 + R)) / math.max(1, rebirthCost(1, R))
    end
    local eggValue = egg and (egg.gain / math.max(1, team.sum)) / math.max(1, egg.cost) or 0

    if egg and eggValue * CONFIG.eggBias >= rebirthValue then
        if clicks >= egg.cost then
            STATE.phase = "hatching " .. egg.name
            hatch(egg)
        else
            STATE.phase = "saving for " .. egg.name
        end
        return
    end

    if CONFIG.autoRebirth then
        if pick then
            STATE.phase = "rebirth"
            doRebirth(pick)
        else
            STATE.phase = "saving for rebirth"
        end
    else
        STATE.phase = egg and ("waiting (" .. egg.name .. " not worth it)") or "idle"
    end
end

----------------------------------------------------------------------------
-- loops
----------------------------------------------------------------------------

local function loop(interval, key, fn)
    task.spawn(function()
        while alive() do
            if CONFIG.auto and (key == nil or CONFIG[key]) then
                local ok, err = pcall(fn)
                if not ok then note("%s failed: %s", key or "loop", tostring(err)) end
            end
            task.wait(type(interval) == "function" and interval() or interval)
        end
    end)
end

-- click engine: its own thread, nothing else ever blocks it
task.spawn(function()
    local ch
    while alive() do
        if CONFIG.auto and CONFIG.autoClick then
            ch = ch or chan("Click")
            if ch then pcall(ch.FireServer, ch, "Click") end
        end
        task.wait(CONFIG.clickGap)
    end
end)

loop(10, "gameClicker", ensureAutoclicker)
loop(0.6, nil, decide)
loop(8, "autoQuests", claimQuests)
loop(10, "autoMilestones", claimMilestones)
loop(5, "autoGems", spendGems)
loop(15, "autoEquip", equipBest)

-- oracle sampler: rate is an EMA over rises only (spending and rebirths drop
-- the balance and are not income)
task.spawn(function()
    local last = cur("Clicks")
    while alive() do
        task.wait(1)
        local c = cur("Clicks")
        if c >= last then STATE.rate = STATE.rate * 0.7 + (c - last) * 0.3 end
        last = c
        STATE.clicks = c
        STATE.gems = cur("Gems")
        STATE.rebirths = cur("Rebirths")
        STATE.multi = clickMulti()
    end
end)

----------------------------------------------------------------------------
-- debug handle (published before the panel, see traps.md)
----------------------------------------------------------------------------

_G.__CLICKSIM_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    data = data, cur = cur, fire = fire, invoke = invoke,
    teamInfo = teamInfo, eggList = eggList, hatch = hatch, purge = purge,
    equipBest = equipBest, rebirthPick = rebirthPick, doRebirth = doRebirth,
    rebirthCost = rebirthCost, claimQuests = claimQuests, spendGems = spendGems,
    claimMilestones = claimMilestones,
    ensureAutoclicker = ensureAutoclicker, decide = decide,
    islandInfo = islandInfo, goBestIsland = goBestIsland, buyIsland = buyIsland,
    nextRebirthButton = nextRebirthButton, ownsRebirthButton = ownsRebirthButton,
}

----------------------------------------------------------------------------
-- panel
----------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__CLICKSIM_WIN then pcall(function() _G.__CLICKSIM_WIN:Destroy() end) end
if UI.sweep then pcall(function() UI.sweep("CLICKSIM") end) end

UI.config("clickersim", CONFIG)

local win = UI.Window({
    title = "CLICKER", accentTitle = "SIM", subtitle = "seltonmt",
    name = "Selux_clickersim",
})
_G.__CLICKSIM_WIN = win

local farmPage = win:Page("FARMING", UI.icon and UI.icon.pickaxe or nil)

local engine = farmPage:Card("ENGINE", 1):Accent()
engine:Toggle("Auto click", CONFIG.autoClick, function(v) CONFIG.autoClick = v end,
    "fires the click at the game's own rate, 10 a second")
engine:Toggle("Game autoclicker", CONFIG.gameClicker, function(v) CONFIG.gameClicker = v end,
    "keeps the built-in autoclicker switched on (bought for 50 gems)")
engine:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "only when a rebirth is worth more per click than the best egg", UI.theme.warn)
engine:Toggle("Claim quests", CONFIG.autoQuests, function(v) CONFIG.autoQuests = v end,
    "presses Claim on every finished quest")
engine:Toggle("Claim milestones", CONFIG.autoMilestones, function(v) CONFIG.autoMilestones = v end,
    "claims every reached stage in the Milestones panel")
engine:Toggle("Unlock islands", CONFIG.autoIslands, function(v) CONFIG.autoIslands = v end,
    "buys the next gate behind spawn and saves for it once it is close")
engine:Toggle("Stay on best island", CONFIG.bestIsland, function(v) CONFIG.bestIsland = v end,
    "the game's own teleport; the island boosts every click and has better eggs")

local eggsCard = farmPage:Card("EGGS", 2)
eggsCard:Toggle("Auto hatch", CONFIG.autoEggs, function(v) CONFIG.autoEggs = v end,
    "hatches the egg with the best value per click, on this island only")
eggsCard:Toggle("Equip best", CONFIG.autoEquip, function(v) CONFIG.autoEquip = v end,
    "seats the strongest pets after every hatch")
eggsCard:Toggle("Delete weak pets", CONFIG.autoPurge, function(v) CONFIG.autoPurge = v end,
    "only plain Basic/Rare/Epic pets that can never make the team")
eggsCard:Toggle("Spend gems", CONFIG.autoGems, function(v) CONFIG.autoGems = v end,
    "autoclicker, pet slot, rebirth buttons, click multiplier - in that order")

local tuning = farmPage:Card("TUNING", 1)
tuning:Slider("Egg preference x10", 5, 50, CONFIG.eggBias * 10, function(v)
    CONFIG.eggBias = v / 10
end)
tuning:Slider("Keep pets up to", 10, 190, CONFIG.keepPets, function(v)
    CONFIG.keepPets = math.floor(v)
end)
tuning:Slider("Save for island (min)", 1, 30, CONFIG.islandSave / 60, function(v)
    CONFIG.islandSave = math.floor(v) * 60
end)
tuning:Button("Equip best now", function() task.spawn(equipBest) end)
tuning:Button("Delete weak pets now", function() task.spawn(function() purge(true) end) end)
tuning:Button("Claim quests now", function() task.spawn(claimQuests) end)
tuning:Button("Rebirth now", function()
    task.spawn(function()
        local pick = rebirthPick()
        if pick then doRebirth(pick) else note("no rebirth affordable") end
    end)
end, UI.theme.warn)

local readout = farmPage:Card("STATUS", 0)
local out = readout:Readout(12)

win:SetMaster(CONFIG.auto, "Auto farm running")
win:OnMaster(function(on)
    CONFIG.auto = on
    if not on and CustomGUI and CustomGUI.RestoreHatchUI then
        task.delay(1.5, function() pcall(CustomGUI.RestoreHatchUI) end)
    end
end)

task.spawn(function()
    while alive() do
        pcall(function()
            local R = STATE.rebirths
            out:set({
                "RUN",
                string.format("  phase %s", STATE.phase),
                string.format("  clicks %s  (+%s/s)   multiplier %s",
                    abbreviate(STATE.clicks), abbreviate(STATE.rate), abbreviate(STATE.multi)),
                string.format("  rebirths %s   next costs %s", abbreviate(R), abbreviate(rebirthCost(1, R))),
                string.format("  island %s   next %s for %s   bought %d",
                    STATE.island, STATE.nextIsland, abbreviate(STATE.nextIslandCost), STATE.islandsBought),
                "PETS",
                string.format("  team %s (weakest seat %s)   slots %d   inventory %d/%d",
                    abbreviate(STATE.teamSum), abbreviate(STATE.worst), STATE.slots, STATE.pets, STATE.petMax),
                string.format("  best egg %s   +%.2f per hatch   costs %s",
                    STATE.bestEgg, STATE.eggGain, abbreviate(STATE.eggCost)),
                string.format("  hatched %d   deleted %d   rebirths %d   quests %d   milestones %d   gem buys %d",
                    STATE.hatched, STATE.deleted, STATE.rebirthsDone, STATE.claimed, STATE.milestones, STATE.gemBuys),
                "NOTE",
                "  " .. tostring(STATE.note),
            })
            win:SetStat(1, abbreviate(STATE.clicks), "clicks")
            win:SetStat(2, abbreviate(STATE.multi), "per click")
            win:SetStat(3, abbreviate(STATE.rebirths), "rebirths")
            win:SetStatus(string.format("%s clicks   x%s   r%s   %s",
                abbreviate(STATE.clicks), abbreviate(STATE.multi), abbreviate(STATE.rebirths), STATE.phase))
        end)
        task.wait(0.5)
    end
end)

pcall(function() win:Home() end)

print("[clickersim] running - RightShift toggles the panel")
