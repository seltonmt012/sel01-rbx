--!nocheck
--[[
    aurabrainrots.lua - "Aura For Brainrots"  place 122526789002601
    ------------------------------------------------------------------------
    An aura-wall ladder bolted onto a carry-and-place plot income game. The
    walls are the game's own progression gate and the whole point of this
    script is that the SERVER DOES NOT ENFORCE THEM for pickups - it only
    enforces them for unlocking the next world.

    The loop, measured through the bridge on 2026-08-20:

      pick the richest SpawnedItem in workspace.ItemSpawners.<Rarity>
        -> pin the root part on it ~1.1s, fireproximityprompt("Pick Up")
        -> it lands in Character.Gripped (carried) or, once MaxCarry is full,
           in the Backpack as a Tool
        -> pin on a plot slot's Spawn part, fire its ProximityPrompt
        -> firetouchinterest on every Slot.YourPadPart.CollectTouch, from
           anywhere, to bank the money

    Verified facts this script is built on (do not re-derive):

      * THERE IS NO ZONE GATE ON PICKUP. A Celestial DolphiniJetskini
        (2.5e25/s) was taken from x = -2366, behind all 21 walls, while the
        player stood at wall 2 with $0. That single item paid 3.5e26 within
        seconds. The walls are physical barriers only.
      * The bat is decoration. BatHitBindable.BatSwingRemote:FireServer()
        takes no arguments and 65 swings at a wall did EXACTLY 0 damage.
        Wall damage is passive and proximity-based: 5s standing at a wall did
        44 damage at PlayerDamage 5 (~1.76 ticks/s), 5s from 1400 studs did 0.
        Standing still IS the input.
      * BUT THE BAT MUST STAY IN INVENTORY SLOT 1. Never RequestSell
        ("Inventory") - that sells the whole backpack and the bat with it.
        Only RequestSell("Equipped"), and only ever with a brainrot held.
      * PLACING NEEDS THE ITEM EQUIPPED AS A TOOL. Firing a slot's prompt
        while the item merely sits in the backpack moves it nowhere; it reads
        exactly like a broken place remote. Humanoid:EquipTool(tool) first.
        Something still in Character.Gripped is already "held" and needs no
        equip.
      * AN OCCUPIED SLOT'S PROMPT PICKS UP, IT DOES NOT SWAP. ActionText
        "Pick Up / Swap" is a lie: the first fire pulls the seated item out,
        and only a SECOND fire seats what is held. Firing once and walking
        away leaves the slot empty and both items loose.
      * Collecting is NOT position gated - 5.5e26 banked from 1614 studs.
        Selling is not either - RequestSell("Equipped") worked from 1400.
      * Slot upgrade is the strongest sink in the game by a wide margin:
        RequestSlotUpgrade(FloorName, SlotName), income x1.2 and price x1.5
        per level. Level 1 -> 2 cost 8.96e24 and paid +2.66e25/s, a 0.34s
        payback. There is no throttle at all - 300 fires in a row all landed
        (income moved exactly x1.2^10). Payback only reaches ~165s around
        level 50.
      * TWO INCOME SCALES, AND MIXING THEM BREAKS THE SWAP LOGIC. The
        VisualItem's Earning attribute is base x mutation x slot level x
        rebirth multiplier x world multiplier; ItemConfigurations.Items[n]
        .Income is the raw base. Ranking a candidate's raw value against a
        placed item's Earning makes every placed item look ~300x better and
        nothing is ever swapped in. Everything here compares RAW values:
        Income x mutation x the world the item was caught in.
      * A FRESHLY PLACED ITEM HAS Earning = 0 FOR A MOMENT. Reading that as
        its value ranks it as the weakest slot, and the very next iteration
        throws it straight back out - a Diamond 3e25 was evicted for a Golden
        1e25 that way, then sold. slotValue() therefore always computes from
        the config and never trusts a zero.
      * Mutation multipliers, measured off Earning/base: Normal 1, Golden 2,
        Diamond 3, Galaxy 4, Lava 5. Rainbow (0.5% chance) never dropped and
        is priced HIGH on purpose - an unknown mutation valued at 1 is how a
        Galaxy earning 540M/s got thrown away in wingsbrainrots.
      * WORLDS ARE THE BIGGEST LEVER IN THE GAME and they multiply brainrot
        income: Forest 1, Galaxy x100, Candy x1e3, Heaven x1e4, Summer x1e5,
        Magmatic x1e6, Iceberg x1e7. TeleportWorld:FireServer(<world NAME>).
        The multiplier applies to items CAUGHT IN THAT WORLD, not to the plot
        - a fresh world-2 item on slot level 1 already beats a world-1 item on
        slot level 24, so a world jump means re-farming all 30 slots.
      * UNLOCKING A WORLD NEEDS THE WALLS ACTUALLY BROKEN. The server answers
        "Reach the end of the map to unlock a new world!" and a glide to
        x = -7434 with the walls still standing changed nothing. Break all 21,
        then travel to the end of the corridor - a single CFrame warp does not
        register, a per-Heartbeat glide does.
      * Wall HP scales with the world: Worlds[n].WallMult is 1, 1e3, 1e6, 1e9,
        1e12, 1e15, 1e18. Forest wall 21 is 2.6e15.
      * AURA: PurchaseAuraUpgrade:FireServer(n) ACCEPTS ONLY 1, 5 OR 10 - the
        three shop buttons. 25/50/100/250 are silently dropped. The shop's
        CurrentStrength is the LEVEL (purchase count); PlayerDamage is
        4.7 * e^(0.0536*level). Damage grows x1.057 per unit, price x1.125 per
        level, so the price eventually outruns the damage. A purchase that is
        not affordable is refused SILENTLY - that reads exactly like a dead
        remote, so always confirm on PlayerDamage.
      * Aura skins are a separate damage multiplier:
        AuraSkinEvent:FireServer("EquipAuraOrBuy", name), cash. Basic 1 ->
        Perdurple 4.75 (5e26) with rebirth-gated tiers above. It does NOT show
        up in PlayerDamage - it is applied server side at hit time.
        "BuyRobuxAura" is the paid path and is never fired.
      * REBIRTH NEEDS THE REQUIREMENT ITEM PLACED ON THE PLOT, not merely
        owned. Holding a LiriliLarila and firing RequestRebirth did nothing;
        seating it on a slot and firing worked immediately. The gate is
        Informations.RebirthRequiers[n] = {Aura = <log level>, Item, MoneyMult}
        and rebirth resets aura and speed but keeps money, plot and items.
      * The farm loop must not evict its own staged rebirth item. The first
        version seated Item67 and then swapped a SmurfCat over it in the same
        pass, forever. census() excludes the requirement item from the
        eviction list.
      * Functions.GetProfile:InvokeServer() hands the client the COMPLETE
        ProfileStore profile - Data holds Money, Rebirths, Damage, Speed,
        MaxCarry, BaseLevel, Plots, Inventory. Every RemoteFunction here goes
        through task.spawn plus a wall clock cap; a parked InvokeServer takes
        the bridge poll with it.
      * leaderstats.Money is a StringValue for display. The real number is the
        player attribute MoneyNumber.
      * Prices in the UI are abbreviated with the game's own ladder
        (N = 1e30, De = 1e33, Ud = 1e36 ...). parsePrice uses that table,
        cross-checked against Modules.NumberFormatter.Format.

    Robux, never touched: every BuyRobux button beside a cash one, the
    rebirth Skip product, "BuyRobuxAura", 2xCash / SuperLuck / 2xStrength,
    the x2 buttons and the shop's lucky block tiers.

    Panel: RightShift.  Console handle: _G.__AURABR_DBG
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local plr = Players.LocalPlayer

local Events    = ReplicatedStorage:WaitForChild("Events", 10)
local Functions = ReplicatedStorage:WaitForChild("Functions", 10)
local Modules   = ReplicatedStorage:WaitForChild("Modules", 10)
local Configs   = ReplicatedStorage:WaitForChild("Configurations", 10)

-- ---------------------------------------------------------------- generation
-- Re-running in the executor does not restart the Lua VM, so every loop below
-- captures this number and exits the moment it stops matching.
_G.__AURABR = (_G.__AURABR or 0) + 1
local GEN = _G.__AURABR

-- ------------------------------------------------------------------- configs
local ItemCfg, GlobalCfg, NumberFmt
pcall(function() ItemCfg   = require(Modules:WaitForChild("ItemConfigurations", 10)) end)
pcall(function() GlobalCfg = require(Configs:WaitForChild("GlobalConfiguration", 10)) end)
pcall(function() NumberFmt = require(Modules:WaitForChild("NumberFormatter", 10)) end)

local ITEMS  = (ItemCfg and ItemCfg.Items) or {}
local INFO   = (GlobalCfg and GlobalCfg.Informations) or {}
local WORLDS = (GlobalCfg and GlobalCfg.Worlds) or {}
local SKINS  = (GlobalCfg and GlobalCfg.AURA_SKINS) or {}
local REQS   = INFO.RebirthRequiers or {}

-- Measured off Earning/base on placed items. Rainbow never dropped in the
-- session this was built from; it is priced high so an unknown mutation can
-- never be ranked as junk and thrown away.
local MUT = { Normal = 1, Golden = 2, Diamond = 3, Galaxy = 4, Lava = 5, Rainbow = 7 }
local UNKNOWN_MUT = 4

-- world id -> brainrot money multiplier
local WORLD_MULT, WORLD_NAME = {}, {}
for name, w in pairs(WORLDS) do
    if w.Id then
        WORLD_MULT[w.Id] = w.BrainrotMoneyMult or 1
        WORLD_NAME[w.Id] = name
    end
end

-- The game's own suffix ladder, cross-checked against NumberFormatter.Format.
local SUFFIX = {
    [""] = 1, K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qd = 1e15, Qn = 1e18,
    Sx = 1e21, Sp = 1e24, Oc = 1e27, N = 1e30, De = 1e33, Ud = 1e36,
    Dd = 1e39, Td = 1e42, Qad = 1e45, Qid = 1e48,
}

local FLOORS = { "Floor1", "Floor2", "Floor3" }

-- -------------------------------------------------------------------- config
local CONFIG = {
    -- farming
    autoFarm    = false,  -- grab the best item on the field and seat it
    autoCollect = true,   -- firetouchinterest every slot, from anywhere
    autoSell    = true,   -- sell backpack leftovers below the plot floor

    -- spending, in payback order
    autoUpgrade = true,   -- slot levels: x1.2 income for x1.5 price
    autoBase    = true,   -- RequestBaseUpgrade, unlocks floors 2 and 3
    autoCarry   = true,   -- MaxCarry, lets one trip bring several items
    autoAura    = true,   -- aura levels, only out of surplus
    autoSkin    = true,   -- the cash-priced aura skin ladder

    -- progression
    autoRebirth = true,   -- seat the requirement item, then fire
    autoWorld   = false,  -- break the walls and push into the next world

    -- tuning
    auraReserve = 20,     -- only buy aura when the balance is this many x its price
    upgradeGap  = 0.04,   -- seconds between slot upgrade fires (no throttle exists)
    pinGrab     = 1.1,    -- seconds pinned on an item before firing its prompt
    pinPlace    = 0.7,    -- seconds pinned on a slot before firing its prompt
    wallHold    = 3.0,    -- seconds parked at a wall before moving to the next
    glideStep   = 14,     -- studs per Heartbeat when travelling to the map end
}

local STATE = {
    running   = false,
    phase     = "idle",
    note      = "-",
    grabs     = 0, swaps = 0, sells = 0, upgrades = 0, collects = 0,
    rebirths  = 0, worlds = 0, auraBuys = 0,
    lastGrab  = "-", lastSwap = "-",
    rebirthNote = "-", auraNote = "-", worldNote = "-",
}

-- ------------------------------------------------------------------- helpers
local function fmt(n)
    n = tonumber(n) or 0
    if NumberFmt and NumberFmt.Format then
        local ok, s = pcall(NumberFmt.Format, n)
        if ok and s then return tostring(s) end
    end
    return string.format("%.3e", n)
end

local function parsePrice(txt)
    if type(txt) ~= "string" then return nil end
    local num, suf = txt:match("%$?%s*([%d%.]+)%s*(%a*)")
    if not num then return nil end
    local n = tonumber(num)
    local m = SUFFIX[suf or ""]
    if not n or not m then return nil end
    return n * m
end

local function money()    return plr:GetAttribute("MoneyNumber") or 0 end
local function damage()   return plr:GetAttribute("PlayerDamage") or 0 end
local function worldId()  return plr:GetAttribute("WorldId") or 1 end
local function rebirths()
    local ls = plr:FindFirstChild("leaderstats")
    local r = ls and ls:FindFirstChild("Rebirths")
    return (r and r.Value) or 0
end

-- The rebirth panel's "Aura Level" is a log transform of PlayerDamage; the
-- shop's CurrentStrength is the same number. Read off RebirthUIController.
local function auraLevel()
    local d = damage()
    if d <= 0 then return 0 end
    return math.floor(math.log(d / 4.7) / 0.053588159169928734 + 0.5)
end

local function char() return plr.Character end
local function hrp()
    local c = char()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function hum()
    local c = char()
    return c and c:FindFirstChildOfClass("Humanoid")
end

-- Prompts validate against the server's copy of the position, so a single
-- CFrame write is not enough - the root part is held there on Heartbeat.
local function pin(pos, secs)
    local root = hrp()
    if not root then return false end
    local cf = CFrame.new(pos)
    local conn = RunService.Heartbeat:Connect(function()
        if root.Parent then root.CFrame = cf end
    end)
    task.wait(secs)
    conn:Disconnect()
    return true
end

-- A warp to the end of the corridor does not register with the server; a
-- glide does. This is what actually unlocks the next world.
local function glide(fromX, toX, y, z)
    local root = hrp()
    if not root then return false end
    local x = fromX
    local step = (toX < fromX) and -CONFIG.glideStep or CONFIG.glideStep
    local conn = RunService.Heartbeat:Connect(function()
        if root.Parent then
            root.CFrame = CFrame.new(x, y, z)
            x = x + step
        end
    end)
    while (step < 0 and x > toX) or (step > 0 and x < toX) do
        if _G.__AURABR ~= GEN then break end
        task.wait(0.05)
    end
    conn:Disconnect()
    return true
end

-- Every RemoteFunction goes through this. A parked InvokeServer inside the
-- poll loop is what takes the whole bridge down.
local function callRF(fn, cap, ...)
    local res, done = nil, false
    local args = table.pack(...)
    task.spawn(function()
        local ok, r = pcall(function() return fn:InvokeServer(table.unpack(args, 1, args.n)) end)
        res = ok and r or nil
        done = true
    end)
    local waited = 0
    while not done and waited < (cap or 6) do
        task.wait(0.2); waited = waited + 0.2
    end
    return res
end

local function profile()
    local p = callRF(Functions:FindFirstChild("GetProfile"), 6)
    return p and p.Data or nil
end

-- ---------------------------------------------------------------- valuation
-- RAW value only: base income x mutation x the world the item was caught in.
-- Slot level and the rebirth multiplier are deliberately left out because they
-- are the same for every candidate and cancel in a comparison.
local function rawValue(name, mutation, world)
    local d = ITEMS[name]
    local base = d and tonumber(d.Income) or 0
    local m = MUT[mutation] or UNKNOWN_MUT
    local wm = WORLD_MULT[world or worldId()] or 1
    return base * m * wm
end

local function plot()
    return workspace:FindFirstChild("Plot_" .. plr.Name)
end

local function requirementItem()
    local req = REQS[rebirths() + 1]
    return req and req.Item or nil
end

-- Slots, split into free and occupied. The occupied list is sorted weakest
-- first and NEVER contains the staged rebirth requirement item, or the farm
-- loop evicts its own ticket to the next rebirth.
local function census()
    local base = plot()
    local free, occupied, total = {}, {}, 0
    local protected = requirementItem()
    if not base then return { free = free, occupied = occupied, total = 0 } end
    for _, f in ipairs(FLOORS) do
        local fl = base:FindFirstChild(f)
        if fl and fl:FindFirstChild("Slots") then
            for i = 1, 10 do
                local s = fl.Slots:FindFirstChild("Slot" .. i)
                if s and s:FindFirstChild("Spawn") then
                    total = total + 1
                    local vi = s.Spawn:FindFirstChild("VisualItem")
                    local e = { slot = s, floor = f, name = "Slot" .. i, key = f .. "/Slot" .. i }
                    if vi then
                        e.item  = vi:GetAttribute("OriginalName")
                        e.mut   = vi:GetAttribute("Mutation")
                        e.world = vi:GetAttribute("WorldId") or 1
                        e.earn  = vi:GetAttribute("Earning") or 0
                        -- never trust a zero here: a slot seated a moment ago
                        -- still reports 0 and would rank as the weakest.
                        e.value = rawValue(e.item, e.mut, e.world)
                        if protected and e.item == protected then
                            e.protected = true
                        else
                            occupied[#occupied + 1] = e
                        end
                    else
                        free[#free + 1] = e
                    end
                end
            end
        end
    end
    table.sort(occupied, function(a, b) return a.value < b.value end)
    return { free = free, occupied = occupied, weakest = occupied[1], total = total }
end

local function totalIncome()
    local base, sum = plot(), 0
    if not base then return 0 end
    for _, f in ipairs(FLOORS) do
        local fl = base:FindFirstChild(f)
        if fl and fl:FindFirstChild("Slots") then
            for i = 1, 10 do
                local s = fl.Slots:FindFirstChild("Slot" .. i)
                local vi = s and s:FindFirstChild("Spawn") and s.Spawn:FindFirstChild("VisualItem")
                if vi then sum = sum + (vi:GetAttribute("Earning") or 0) end
            end
        end
    end
    return sum
end

-- ------------------------------------------------------------------ carrying
local function grippedList()
    local c = char()
    local g = c and c:FindFirstChild("Gripped")
    return g and g:GetChildren() or {}
end

local function backpackBrainrots()
    local t = {}
    for _, x in ipairs(plr.Backpack:GetChildren()) do
        if x:GetAttribute("OriginalName") then t[#t + 1] = x end
    end
    return t
end

-- The bat lives in slot 1 and is what the wall damage is bound to. It is put
-- back in hand after every action that had to equip a brainrot.
local function equipBat()
    local bat = plr.Backpack:FindFirstChild("Basic Bat")
    local h = hum()
    if bat and h then pcall(function() h:EquipTool(bat) end) end
end

local function equipNamed(name)
    local c = char()
    if c then
        for _, x in ipairs(c:GetChildren()) do
            if x:IsA("Tool") and x:GetAttribute("OriginalName") == name then return true end
        end
    end
    for _, x in ipairs(plr.Backpack:GetChildren()) do
        if x:GetAttribute("OriginalName") == name then
            local h = hum()
            if not h then return false end
            pcall(function() h:EquipTool(x) end)
            task.wait(0.3)
            return true
        end
    end
    return false
end

local function slotPrompt(s)
    return s:FindFirstChild("Spawn") and s.Spawn:FindFirstChildOfClass("ProximityPrompt")
end

local function fireSlot(s, hold)
    local pp = slotPrompt(s)
    if not pp then return false end
    pin(s.Spawn.Position + Vector3.new(0, 4, 0), hold or CONFIG.pinPlace)
    pcall(fireproximityprompt, pp)
    task.wait(0.45)
    return true
end

-- ----------------------------------------------------------------- the field
local function spawnedItems()
    local root = workspace:FindFirstChild("ItemSpawners")
    local out = {}
    if not root then return out end
    for _, sp in ipairs(root:GetChildren()) do
        for _, m in ipairs(sp:GetChildren()) do
            if m.Name == "SpawnedItem" and m.Parent then out[#out + 1] = m end
        end
    end
    return out
end

-- The best item on the field that actually beats the weakest seated one. With
-- a free slot anything qualifies.
local function bestCandidate()
    local c = census()
    local bar = (#c.free > 0) and -1 or ((c.weakest and c.weakest.value) or -1)
    local best, bestV = nil, bar
    for _, m in ipairs(spawnedItems()) do
        local v = rawValue(m:GetAttribute("OriginalName"), m:GetAttribute("Mutation"), worldId())
        if v > bestV then best, bestV = m, v end
    end
    return best, bestV, bar, c
end

local function grabItem(m)
    local pp
    for _, d in ipairs(m:GetDescendants()) do
        if d:IsA("ProximityPrompt") then pp = d break end
    end
    if not pp then return false end
    pin(m:GetPivot().Position + Vector3.new(0, 3, 0), CONFIG.pinGrab)
    pcall(fireproximityprompt, pp)
    task.wait(0.35)
    return true
end

-- Seat what is carried. On a full plot the weakest slot is emptied first,
-- because an occupied slot's prompt PICKS UP - it never swaps in one fire.
local function seat(name, target)
    local c = census()
    local tgt = target or c.free[1]
    local displaced = nil
    if not tgt then
        tgt = c.weakest
        if not tgt then return nil, "no slot" end
        displaced = tgt.item
        fireSlot(tgt.slot)                       -- fire 1: pull the weakest out
    end
    if #grippedList() == 0 then
        if not equipNamed(name) then return nil, "not held" end
    end
    fireSlot(tgt.slot)                           -- fire 2: seat ours
    equipBat()
    local vi = tgt.slot.Spawn:FindFirstChild("VisualItem")
    local seated = vi and vi:GetAttribute("OriginalName") or nil
    return tgt.key, displaced, seated
end

-- ------------------------------------------------------------------- economy
local function collectAll()
    local root, base = hrp(), plot()
    if not root or not base then return 0 end
    local n = 0
    for _, f in ipairs(FLOORS) do
        local fl = base:FindFirstChild(f)
        if fl and fl:FindFirstChild("Slots") then
            for i = 1, 10 do
                local s = fl.Slots:FindFirstChild("Slot" .. i)
                local pad = s and s:FindFirstChild("YourPadPart")
                local ct = pad and pad:FindFirstChild("CollectTouch")
                if ct then
                    pcall(function()
                        firetouchinterest(root, ct, 0)
                        firetouchinterest(root, ct, 1)
                    end)
                    n = n + 1
                end
            end
        end
    end
    STATE.collects = STATE.collects + 1
    return n
end

-- Only ever "Equipped", and only what is genuinely worse than the plot floor.
-- "Inventory" would take the bat with it.
local function sellSurplus(max)
    local c = census()
    local bar = (c.weakest and c.weakest.value) or 0
    local sold = 0
    for _ = 1, (max or 8) do
        local pick
        for _, x in ipairs(backpackBrainrots()) do
            local v = rawValue(x:GetAttribute("OriginalName"), x:GetAttribute("Mutation"),
                               x:GetAttribute("WorldId") or 1)
            if v < bar then pick = x break end
        end
        if not pick then break end
        local h = hum()
        if not h then break end
        pcall(function() h:EquipTool(pick) end)
        task.wait(0.28)
        Events.RequestSell:FireServer("Equipped")
        task.wait(0.4)
        sold = sold + 1
    end
    equipBat()
    STATE.sells = STATE.sells + sold
    return sold
end

-- x1.2 income for x1.5 price and no throttle whatsoever. Fired over every
-- occupied slot; the server refuses what cannot be paid for and says nothing,
-- which is fine here because the pass is cheap to repeat.
local function upgradePass()
    local base = plot()
    if not base then return 0 end
    local n = 0
    for _, f in ipairs(FLOORS) do
        local fl = base:FindFirstChild(f)
        if fl and fl:FindFirstChild("Slots") then
            for i = 1, 10 do
                local s = fl.Slots:FindFirstChild("Slot" .. i)
                if s and s:FindFirstChild("Spawn") and s.Spawn:FindFirstChild("VisualItem") then
                    Events.RequestSlotUpgrade:FireServer(f, "Slot" .. i)
                    n = n + 1
                    task.wait(CONFIG.upgradeGap)
                end
            end
        end
    end
    STATE.upgrades = STATE.upgrades + n
    return n
end

local function auraShopCard(which)
    local gui = plr:FindFirstChild("PlayerGui")
    local g = gui and gui:FindFirstChild("GUI")
    local frames = g and g:FindFirstChild("Frames")
    local up = frames and frames:FindFirstChild("Upgrades")
    local cont = up and up:FindFirstChild("Container")
    return cont and cont:FindFirstChild(which) or nil
end

local function auraPrice(which)
    local card = auraShopCard(which)
    local buy = card and card:FindFirstChild("BuyButtons")
    local b = buy and buy:FindFirstChild("Buy")
    local cost = b and b:FindFirstChild("Cost")
    return cost and parsePrice(cost.Text) or nil, cost and cost.Text or "?"
end

-- Only 1, 5 and 10 are accepted; anything else is dropped without a word. The
-- reserve keeps this from outbidding the slot levels, which pay back far
-- faster.
local function auraStep()
    if not CONFIG.autoAura then return "off" end
    local m = money()
    for _, pair in ipairs({ { "Aura10", 10 }, { "Aura5", 5 }, { "Aura1", 1 } }) do
        local price, label = auraPrice(pair[1])
        if price and m > price * CONFIG.auraReserve then
            Events.PurchaseAuraUpgrade:FireServer(pair[2])
            STATE.auraBuys = STATE.auraBuys + 1
            return "bought +" .. pair[2] .. " at " .. label
        end
    end
    return "saving"
end

-- The cash ladder only. Anything with an EC price is the event currency and
-- anything behind BuyRobuxAura is the paid path.
local function skinStep()
    if not CONFIG.autoSkin then return "off" end
    local ev = ReplicatedStorage:FindFirstChild("AuraSkinEvent")
    if not ev then return "no remote" end
    local best, bestMult = nil, tonumber(plr:GetAttribute("AuraDamageMultiplier")) or 1
    for _, s in ipairs(SKINS) do
        if s.Price and not s.EC and (s.multiplier or 0) > bestMult and s.Price <= money() then
            if (not s.RebirthRequired) or rebirths() >= s.RebirthRequired then
                if (not best) or s.multiplier > best.multiplier then best = s end
            end
        end
    end
    if not best then return "nothing better affordable" end
    ev:FireServer("EquipAuraOrBuy", best.auraName)
    task.wait(0.35)
    ev:FireServer("EquipAuraOrBuy", best.auraName)   -- buy, then equip
    return "bought " .. best.auraName .. " x" .. tostring(best.multiplier)
end

local function baseStep()
    if not CONFIG.autoBase then return "off" end
    Events.RequestBaseUpgrade:FireServer()
    return "fired"
end

local function carryStep()
    if not CONFIG.autoCarry then return "off" end
    Events.PurchaseCarry:FireServer()
    return "fired"
end

-- ------------------------------------------------------------------- rebirth
-- The requirement item has to be SEATED, not owned. Once it is on a slot the
-- rebirth fires in the same pass so the farm step cannot evict it first.
local function rebirthStep()
    if not CONFIG.autoRebirth then return "off" end
    local r = rebirths()
    local req = REQS[r + 1]
    if not req then return "max rebirths" end

    local base = plot()
    if not base then return "no plot" end
    local onPlot = false
    for _, f in ipairs(FLOORS) do
        local fl = base:FindFirstChild(f)
        if fl and fl:FindFirstChild("Slots") then
            for i = 1, 10 do
                local s = fl.Slots:FindFirstChild("Slot" .. i)
                local vi = s and s:FindFirstChild("Spawn") and s.Spawn:FindFirstChild("VisualItem")
                if vi and vi:GetAttribute("OriginalName") == req.Item then onPlot = true end
            end
        end
    end

    if onPlot then
        if auraLevel() < req.Aura then
            return ("staged, aura %d/%d"):format(auraLevel(), req.Aura)
        end
        Events.RequestRebirth:FireServer()
        task.wait(1.2)
        if rebirths() > r then
            STATE.rebirths = STATE.rebirths + 1
            return "REBIRTH " .. (r + 1)
        end
        return "refused"
    end

    for _, m in ipairs(spawnedItems()) do
        if m:GetAttribute("OriginalName") == req.Item then
            if grabItem(m) then
                local key = seat(req.Item)
                if auraLevel() >= req.Aura then
                    Events.RequestRebirth:FireServer()
                    task.wait(1.0)
                    if rebirths() > r then
                        STATE.rebirths = STATE.rebirths + 1
                        return "REBIRTH " .. (r + 1)
                    end
                end
                return "staged " .. req.Item .. " at " .. tostring(key)
            end
        end
    end
    return "waiting for " .. req.Item
end

-- --------------------------------------------------------------------- world
local function wallInfo(n)
    local folder = workspace:FindFirstChild("Wall")
    local w = folder and folder:FindFirstChild("Wall" .. n)
    if not w then return nil end
    local gui = w:FindFirstChild("WallInfo")
    local txt
    if gui then
        for _, d in ipairs(gui:GetDescendants()) do
            if d:IsA("TextLabel") then txt = d.Text break end
        end
    end
    return w, txt
end

local function wallStanding(n)
    local _, txt = wallInfo(n)
    if not txt then return false end
    local cur = txt:match("^([%d%.%a]+)%s*/")
    return not (cur == "0")
end

-- Break every wall, then travel to the end of the corridor. The server tracks
-- a progress cursor that only advances on a kill, so the glide alone is not
-- enough - and a single warp does not register either.
local function pushWorld()
    local folder = workspace:FindFirstChild("Wall")
    if not folder then return "no walls" end
    local broken, standing = 0, 0
    for n = 1, 21 do
        if _G.__AURABR ~= GEN or not CONFIG.autoWorld then return "stopped" end
        local w = wallInfo(n)
        if w then
            if wallStanding(n) then
                STATE.phase = "wall " .. n
                pin(w.Position + Vector3.new(9, -13, 0), CONFIG.wallHold)
            end
            if wallStanding(n) then standing = standing + 1 else broken = broken + 1 end
        end
    end
    if standing > 0 then
        return ("%d/21 broken, %d still standing - more aura needed"):format(broken, standing)
    end

    STATE.phase = "travelling to the end"
    glide(0, -7500, 6, -312)
    task.wait(0.6)

    local nextId = worldId() + 1
    local name = WORLD_NAME[nextId]
    if not name then return "no world above " .. worldId() end
    Events.TeleportWorld:FireServer(name)
    task.wait(2)
    if worldId() >= nextId then
        STATE.worlds = STATE.worlds + 1
        return "WORLD " .. name
    end
    return "refused - " .. name .. " still locked"
end

-- ---------------------------------------------------------------- farm cycle
local function farmCycle()
    if CONFIG.autoCollect then collectAll() end

    STATE.rebirthNote = rebirthStep()

    if CONFIG.autoFarm then
        STATE.phase = "hunting"
        local m, v, bar = bestCandidate()
        if m then
            local name = m:GetAttribute("OriginalName")
            local mut  = m:GetAttribute("Mutation")
            if grabItem(m) then
                STATE.grabs = STATE.grabs + 1
                STATE.lastGrab = tostring(name) .. "/" .. tostring(mut)
                local key, displaced = seat(name)
                if key then
                    STATE.swaps = STATE.swaps + 1
                    STATE.lastSwap = key .. " <- " .. tostring(name)
                        .. (displaced and (" (out: " .. tostring(displaced) .. ")") or "")
                end
            end
        else
            STATE.note = "nothing on the field beats " .. fmt(bar)
        end
    end

    if CONFIG.autoUpgrade then STATE.phase = "upgrading"; upgradePass() end
    if CONFIG.autoBase then baseStep() end
    if CONFIG.autoCarry then carryStep() end
    STATE.auraNote = auraStep()
    if CONFIG.autoSkin then skinStep() end
    if CONFIG.autoSell then sellSurplus(6) end

    equipBat()
    STATE.phase = "idle"
end

task.spawn(function()
    while _G.__AURABR == GEN do
        if STATE.running then
            local ok, err = pcall(farmCycle)
            if not ok then STATE.note = "ERR " .. tostring(err) end
        end
        task.wait(0.4)
    end
end)

-- The world push runs on its own loop: it parks the character at a wall for
-- seconds at a time and would otherwise fight the farm loop for the body.
task.spawn(function()
    while _G.__AURABR == GEN do
        if STATE.running and CONFIG.autoWorld then
            local wasFarm = CONFIG.autoFarm
            CONFIG.autoFarm = false            -- one body, one pin
            local ok, r = pcall(pushWorld)
            STATE.worldNote = ok and tostring(r) or ("ERR " .. tostring(r))
            CONFIG.autoFarm = wasFarm
            task.wait(5)
        else
            task.wait(1)
        end
    end
end)

-- --------------------------------------------------------------------- panel
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__AURABR_WIN then pcall(function() _G.__AURABR_WIN:Destroy() end) end
for _, parent in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui"), plr:FindFirstChild("PlayerGui") }) do
    pcall(function()
        for _, g in ipairs(parent:GetChildren()) do
            if g.Name == "AURABR_PANEL" then g:Destroy() end
        end
    end)
end

local win = UI.Window({
    title = "AURA", accentTitle = "BRAINROTS", subtitle = "seltonmt",
    badge = "*", width = 820, height = 582, name = "AURABR_PANEL",
})
_G.__AURABR_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local cFarm = farm:Card("FIELD", 1):Accent()
cFarm:Toggle("Auto farm", CONFIG.autoFarm, function(v)
    CONFIG.autoFarm = v
    STATE.running = v or STATE.running
end, "grab the best item on the field - the walls do not gate pickups")
cFarm:Toggle("Sell leftovers", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
    "only what is worse than the weakest slot, and never the bat")

local cPlot = farm:Card("PLOT", 2)
cPlot:Toggle("Auto collect", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
    "not position gated - banked from 1614 studs", UI.theme.good)
cPlot:Toggle("Slot levels", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
    "x1.2 income for x1.5 price, 0.34s payback at level 1", UI.theme.good)
cPlot:Toggle("Base upgrade", CONFIG.autoBase, function(v) CONFIG.autoBase = v end,
    "unlocks floor 2 and 3")
cPlot:Toggle("Carry", CONFIG.autoCarry, function(v) CONFIG.autoCarry = v end,
    "more items per trip")

local spend = win:Page("AURA", UI.icon.coin)

local cAura = spend:Card("AURA", 1):Accent()
cAura:Toggle("Buy aura levels", CONFIG.autoAura, function(v) CONFIG.autoAura = v end,
    "only 1, 5 and 10 are accepted - other amounts are dropped silently")
cAura:Toggle("Buy aura skins", CONFIG.autoSkin, function(v) CONFIG.autoSkin = v end,
    "cash ladder only, never the Robux one", UI.theme.warn)
cAura:Slider("Aura reserve", 2, 60, CONFIG.auraReserve, function(v)
    CONFIG.auraReserve = math.floor(v)
end)

local cProg = spend:Card("PROGRESSION", 2)
cProg:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
    "seats the requirement item first - owning it is not enough")
cProg:Toggle("Push next world", CONFIG.autoWorld, function(v) CONFIG.autoWorld = v end,
    "break all 21 walls, then travel to the end of the map", UI.theme.bad)
cProg:Button("Break walls now", function()
    task.spawn(function() STATE.worldNote = tostring(select(2, pcall(pushWorld))) end)
end)

local cStatus = farm:Card("STATUS", 0)
local out = cStatus:Readout(12)

task.spawn(function()
    while _G.__AURABR == GEN do
        local c = census()
        local used = #c.occupied
        local wid = worldId()

        win:SetStatus(("$%s   %s/s   slots %d/%d   R%d   %s"):format(
            fmt(money()), fmt(totalIncome()), used, c.total, rebirths(),
            (WORLD_NAME[wid] or "?") .. " x" .. tostring(WORLD_MULT[wid] or 1)))
        pcall(function()
            win:SetStat(1, fmt(money()), "money")
            win:SetStat(2, fmt(totalIncome()), "per second")
            win:SetStat(3, tostring(rebirths()), "rebirths")
        end)

        local req = REQS[rebirths() + 1]
        local p10 = auraPrice("Aura10")
        local worldMine = 0
        for _, e in ipairs(c.occupied) do
            if (e.world or 1) >= wid then worldMine = worldMine + 1 end
        end

        out:set({
            "FARM",
            ("  phase %s   grabs %d   seated %d   sold %d"):format(
                STATE.phase, STATE.grabs, STATE.swaps, STATE.sells),
            "  last " .. STATE.lastGrab,
            "  " .. STATE.lastSwap,
            "PLOT",
            ("  %d of %d used   %d caught in this world   collects %d"):format(
                used, c.total, worldMine, STATE.collects),
            ("  weakest %s (%s)   slot upgrades %d"):format(
                c.weakest and (c.weakest.item .. "/" .. tostring(c.weakest.mut)) or "-",
                c.weakest and fmt(c.weakest.value) or "0", STATE.upgrades),
            "AURA",
            ("  level %d   damage %s   +10 costs %s   %s"):format(
                auraLevel(), fmt(damage()), p10 and fmt(p10) or "?", STATE.auraNote),
            "PROGRESSION",
            ("  rebirth %d needs aura %s + %s -> %s"):format(
                rebirths() + 1, req and tostring(req.Aura) or "-",
                req and tostring(req.Item) or "-", STATE.rebirthNote),
            "  world: " .. STATE.worldNote,
        })
        win:Refresh()
        task.wait(0.5)
    end
end)

pcall(function()
    win:SetMaster(CONFIG.autoFarm, "Auto Farm laeuft")
    win:OnMaster(function(on)
        CONFIG.autoFarm = on
        STATE.running = on or STATE.running
    end)
end)

STATE.running = true

-- ---------------------------------------------------------------- debug hook
_G.__AURABR_DBG = {
    CONFIG = CONFIG, STATE = STATE,
    census = census, rawValue = rawValue, totalIncome = totalIncome,
    spawnedItems = spawnedItems, bestCandidate = bestCandidate,
    grabItem = grabItem, seat = seat, fireSlot = fireSlot,
    collectAll = collectAll, sellSurplus = sellSurplus, upgradePass = upgradePass,
    auraStep = auraStep, auraPrice = auraPrice, skinStep = skinStep,
    baseStep = baseStep, carryStep = carryStep,
    rebirthStep = rebirthStep, requirementItem = requirementItem,
    pushWorld = pushWorld, wallInfo = wallInfo, wallStanding = wallStanding,
    glide = glide, pin = pin, equipBat = equipBat, equipNamed = equipNamed,
    profile = profile, parsePrice = parsePrice, fmt = fmt,
    auraLevel = auraLevel, money = money, damage = damage, worldId = worldId,
    rebirths = rebirths, farmCycle = farmCycle,
    MUT = MUT, WORLD_MULT = WORLD_MULT, WORLD_NAME = WORLD_NAME, REQS = REQS,
}

pcall(function() win:Home() end)

print("[aurabrainrots] loaded - gen " .. GEN .. ", RightShift for the panel")
