--[[ looksclick.lua - "[🌎W8] +1 Looks Per Click" (place 102355196524321)

  The loop the game actually runs:

      click -> Looks;  an AutoTrainer adds more Looks on its own while you stand on it
      Looks -> the NPCs you can out-mog;  mogging one pays Wins
      Wins  -> gear, and gear is what a click is WORTH
      Looks -> zones, and further out zones hold NPCs paying thousands of times more
      Rebirth -> stronger AutoTrainers;  eight worlds, each its own Looks wall

  This game speaks **Warp** (imezx_warp 1.0.14), not plain RemoteEvents: all of its
  traffic goes down three remotes and every channel is addressed by a hashed string
  id, so `ReplicatedStorage` looks almost empty. The client side is
  `require(ReplicatedStorage.Packages.warp).Client("<name>")` and the 64 channel
  names were read out of the decompiled controllers. Two consequences worth knowing:

  * The bridge/executor runs at identity 8 and `require` on a normal module fails
    with "Cannot require a non-RobloxScript module from a RobloxScript". Raising the
    thread identity to 2 around BOTH the require AND `warp.Client(...)` is needed -
    Client() loads its own submodules lazily, so wrapping only the require still
    throws.
  * There is no remote to enumerate; the channel list comes from the client source.

  Everything below was measured through the bridge before it was written down:

  * `GainLooks:Fire(true)` is the click and the server rate limits it HARD, and
    firing faster makes it worse: one call per frame (57/s) credited 3.75 looks/s,
    five per frame credited 1.5/s, a 0.5s gap credited 100% of a much smaller
    number. A 0.125s gap is the peak at ~3.75 credited clicks a second.
  * An AutoTrainer is a passive second engine and the two STACK: the x1 Bronze
    trainer alone made 10 looks/s, clicking alone 17/s, and standing on it while
    clicking made 27.5/s. Trainers are chosen by standing in their hitbox, which
    sets the `CurrentTrainer` attribute, and they are gated by rebirth count
    (x2 at 2 rebirths, x20 at 14, up to x113 in the config).
  * A mog is `ContestRequest:Fire(true, <npc model name>)` followed by
    `ContestClick:Fire(true, nil)`. It is **position gated** - from 300 studs the
    contest never starts, standing next to the NPC it always does - and it is over
    in about 0.9 seconds with five clicks whenever your Looks clearly beat the
    NPC's requirement. Four mogs of HumbleMogger (1300 Looks) paid exactly 4 x 325.
  * NPCs are CLIENT-side models in `workspace.ClientNPCs` carrying `NPCType` and
    `ZoneName`, and only the ones near the character exist - so the picker has to
    travel to a zone before it can see what lives there. Asking for an NPC of a
    zone that is out of reach is simply refused, no error.
  * Gear is bought by touching `<model>.ButtonTop` in the world's GearShop and
    `firetouchinterest` reaches it **from 108 studs** - no walking. It is a
    best-only ladder, not a sum: buying the 1-win Comb took `TotalLooksPerClick`
    from 1 to 5 and `BestGearMultiplier` from 0 to 5.

  Never spends Robux: the God Crown, the OP/Rainbow trainers, every `RobuxTier`
  entry, the Robux side of the teleport and rebirth panels and every
  `PromptProductPurchase` path are filtered out by their own fields, never by name.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

local GEN = (_G.__LOOKSCLICK or 0) + 1
_G.__LOOKSCLICK = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,
	click = true,           -- GainLooks; the server credits ~3.75/s and no more
	clickGap = 0.125,       -- measured peak; smaller is credited WORSE, not better
	trainer = true,         -- stand on the best AutoTrainer the rebirths allow
	mog = true,             -- travel to the strongest beatable NPC and out-mog it
	gear = true,            -- best affordable gear in this world, touched from afar
	portals = true,         -- take the world portal once its Looks wall is passed
	rebirth = true,         -- Rebirth("Max") the moment the Looks requirement is met
	eggs = true,            -- buy eggs with the Looks left over above the next rebirth
	auras = true,           -- roll the best affordable tier, equip the best owned
	pets = true,            -- keep the strongest pets equipped, up to PetSlots
	boosts = true,          -- burn any boost sitting in the inventory
	tokens = true,          -- spend FameTokens: Rebirth, then Aura, Luck, Pet
	freebies = true,        -- free spin, group reward, offline earnings, leave gift

	trainSeconds = 30,      -- seconds on the trainer before each mogging trip
	mogSeconds = 45,        -- hard cap; mogging stops early once the gear is funded
	contestSeconds = 10,    -- give up on one contest after this long
	rebirthUntil = 0,       -- 0 = no limit
	-- Looks are BOTH the rebirth price and the egg/aura price, so nothing else may
	-- touch what the next rebirth needs: only the surplus above requirement x this
	-- is spendable. 1.0 keeps the next rebirth fully funded and still lets an egg
	-- through; higher values hold more back.
	rebirthReserve = 1.0,
	cheapShare = 0.25,      -- ...unless it costs under this share of the next wall
}

local STATE = {
	phase = "idle",
	note = "",
	looks = 0, wins = 0, rebirths = 0, tokens = 0,
	looksRate = 0, winsRate = 0,
	perClick = 1, gear = "-", gearMul = 0,
	trainer = "-", trainerMul = 0,
	world = 1, zone = "-",
	npc = "-", npcPays = 0, mogs = 0,
	rebirthNeed = 0, pets = 0, petsEquipped = 0, petMul = 0, aura = "-", auraMul = 0,
	busy = false, bodyOwner = nil,
}

-- defined further down with the spenders; mogPhase needs to know what the next
-- gear rung costs so it can stop mogging the moment that is funded, and a local
-- is invisible above its own definition
local nextGear

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function short(n)
	n = tonumber(n) or 0
	local units = {
		{ 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" }, { 1e21, "Sx" },
		{ 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" },
		{ 1e6, "M" }, { 1e3, "K" },
	}
	for _, u in ipairs(units) do
		if math.abs(n) >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
	end
	return string.format("%.0f", n)
end

local function note(text) STATE.note = text end

local function char()
	local model = plr.Character
	if not model then return nil, nil, nil end
	return model, model:FindFirstChild("HumanoidRootPart"), model:FindFirstChildOfClass("Humanoid")
end

-- The executor thread runs at identity 8, where requiring a normal ModuleScript
-- throws "Cannot require a non-RobloxScript module from a RobloxScript". Raise it
-- for the call and put it straight back.
local function asGame(fn, ...)
	local restore = getthreadidentity and getthreadidentity() or nil
	if setthreadidentity then pcall(setthreadidentity, 2) end
	local ok, a, b = pcall(fn, ...)
	if setthreadidentity and restore then pcall(setthreadidentity, restore) end
	if not ok then return nil, a end
	return a, b
end

local moduleCache = {}

local function conf(name)
	if moduleCache[name] ~= nil then return moduleCache[name] end
	local folder = ReplicatedStorage:FindFirstChild("Shared")
	folder = folder and folder:FindFirstChild("Modules")
	local mod = folder and folder:FindFirstChild(name)
	if not mod then return nil end
	local value = asGame(require, mod)
	moduleCache[name] = value
	return value
end

-- warp.Client() loads its own submodules lazily, so it needs the raised identity
-- as well - wrapping only the require still throws.
_G.__LOOKSCLICK_WARP = _G.__LOOKSCLICK_WARP or {}
local warpLib

local function channel(name)
	local cache = _G.__LOOKSCLICK_WARP
	if cache[name] then return cache[name] end
	if not warpLib then
		warpLib = asGame(require, ReplicatedStorage:WaitForChild("Packages"):WaitForChild("warp"))
	end
	if not warpLib then return nil end
	local client = asGame(function() return warpLib.Client(name) end)
	cache[name] = client
	return client
end

local function fire(name, ...)
	local c = channel(name)
	if not c then return false end
	local args = { ... }
	return (pcall(function() c:Fire(table.unpack(args)) end))
end

local function pin(getCFrame)
	local stop = false
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if stop or GEN ~= _G.__LOOKSCLICK then conn:Disconnect() return end
		local _, hrp = char()
		local cf = getCFrame()
		if hrp and cf then hrp.CFrame = cf end
	end)
	return function()
		stop = true
		pcall(function() conn:Disconnect() end)
	end
end

local function withBody(name, fn)
	if STATE.bodyOwner then return false, "busy" end
	STATE.bodyOwner = name
	local ok, err = pcall(fn)
	STATE.bodyOwner = nil
	if not ok then note(name .. " failed: " .. tostring(err)) end
	return ok, err
end

local function loop(sec, key, fn)
	task.spawn(function()
		while GEN == _G.__LOOKSCLICK do
			if CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
			end
			task.wait(sec)
		end
	end)
end

local function stat(name, default)
	local ls = plr:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(name)
	return v and v.Value or default
end

--------------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------------

local lastLooks, lastWins, lastSample = 0, 0, 0

local function refresh()
	STATE.looks = stat("Looks", 0)
	STATE.wins = stat("Wins", 0)
	STATE.rebirths = stat("Rebirths", 0)
	STATE.tokens = stat("FameTokens", 0)
	STATE.perClick = plr:GetAttribute("TotalLooksPerClick") or 1
	STATE.gearMul = plr:GetAttribute("BestGearMultiplier") or 0
	STATE.trainer = plr:GetAttribute("CurrentTrainer")
	if STATE.trainer == nil or STATE.trainer == "" then STATE.trainer = "-" end
	STATE.world = plr:GetAttribute("CurrentWorld") or 1
	local worn = plr:GetAttribute("EquippedAura")
	if type(worn) == "string" and worn ~= "" then
		STATE.aura = worn
		local cfg = conf("AuraConfig")
		local info = cfg and cfg.Auras and cfg.Auras[worn]
		STATE.auraMul = info and tonumber(info.Multiplier) or STATE.auraMul
	end
	local equipped = plr:GetAttribute("EquippedPets")
	if type(equipped) == "string" then
		local n = 0
		for _ in equipped:gmatch("[^,]+") do n = n + 1 end
		STATE.petsEquipped = n
	end

	local now = os.clock()
	if lastSample > 0 and now - lastSample >= 1 then
		local dt = now - lastSample
		if STATE.looks >= lastLooks then STATE.looksRate = (STATE.looks - lastLooks) / dt end
		if STATE.wins >= lastWins then STATE.winsRate = (STATE.wins - lastWins) / dt end
	end
	if now - lastSample >= 1 then
		lastLooks, lastWins, lastSample = STATE.looks, STATE.wins, now
	end
end

--------------------------------------------------------------------------------
-- the click engine
--
-- One timed loop rather than a Heartbeat connection, because this is the one
-- clicker in the repo where firing FASTER credits LESS: 57 calls/s credited
-- 3.75 looks/s, 300 calls/s credited 1.5, and a 0.125s gap sits at the peak.
--------------------------------------------------------------------------------

task.spawn(function()
	while GEN == _G.__LOOKSCLICK do
		if CONFIG.auto and CONFIG.click then
			pcall(fire, "GainLooks", true)
		end
		task.wait(math.max(0.05, CONFIG.clickGap))
	end
end)

--------------------------------------------------------------------------------
-- the trainer: a passive second Looks engine that stacks with clicking
--------------------------------------------------------------------------------

local function worldFolder(index)
	return workspace:FindFirstChild("World" .. tostring(index or STATE.world or 1))
end

local function pivotOf(instance)
	if not instance then return nil end
	if instance:IsA("BasePart") then return instance.Position end
	local ok, cf = pcall(function() return instance:GetPivot() end)
	return ok and cf.Position or nil
end

-- Trainers are gated by rebirth count and the Robux ones carry RequiredPass /
-- RobuxTier, which is the field to filter on - "OPTrainer" would otherwise read
-- as just another entry.
local function bestTrainer()
	local cfg = conf("AutoTrainerConfig") or {}
	local folder = worldFolder()
	folder = folder and folder:FindFirstChild("AutoTrainers")
	if not folder then return nil end
	local best, bestMul
	for _, model in ipairs(folder:GetChildren()) do
		local entry = cfg[model.Name]
		local mul = entry and tonumber(entry.Multiplier)
		local paid = entry and (entry.RequiredPass or entry.RobuxTier)
		local need = entry and tonumber(entry.RequiredRebirths) or 0
		if mul and not paid and STATE.rebirths >= need then
			if not bestMul or mul > bestMul then best, bestMul = model, mul end
		end
	end
	return best, bestMul
end

local function trainPhase()
	local model, mul = bestTrainer()
	if not model then return end
	local pos = pivotOf(model)
	if not pos then return end
	STATE.trainerMul = mul or 0
	STATE.phase = "training x" .. tostring(mul)
	local target = CFrame.new(pos + Vector3.new(0, 4, 0))
	local stop = pin(function() return target end)
	local deadline = os.clock() + CONFIG.trainSeconds
	while os.clock() < deadline and GEN == _G.__LOOKSCLICK
		and CONFIG.auto and CONFIG.trainer do
		task.wait(0.3)
		STATE.trainer = plr:GetAttribute("CurrentTrainer") or STATE.trainer
	end
	stop()
end

--------------------------------------------------------------------------------
-- mogging: the Wins engine
--------------------------------------------------------------------------------

-- The zone to stand in is the furthest one this world offers whose RequiredLooks
-- we have passed; its NPCs only exist once the character is near them.
local function bestZone()
	local zones = conf("ZoneConfig") or {}
	local folder = worldFolder()
	folder = folder and folder:FindFirstChild("ZoneGrounds")
	if not folder then return nil end
	local best, bestNeed
	for name, entry in pairs(zones) do
		local need = tonumber(entry and entry.RequiredLooks)
		local ground = entry and entry.Ground and folder:FindFirstChild(entry.Ground)
		local world = tonumber(entry and entry.World) or 1
		if need and ground and world == STATE.world and need <= STATE.looks then
			if not bestNeed or need > bestNeed then best, bestNeed = ground, need end
		end
	end
	return best, bestNeed
end

-- Strongest NPC in reach that our Looks actually beat. Ranking on the payout
-- rather than on the requirement, because the two are not in the same order for
-- every entry in the table.
local function bestNPC()
	local cfg = conf("NPCsConfig") or {}
	local folder = workspace:FindFirstChild("ClientNPCs")
	if not folder then return nil end
	local best, bestEntry
	for _, model in ipairs(folder:GetChildren()) do
		local entry = cfg[model.Name]
		local need = entry and tonumber(entry.Looks)
		local pays = entry and tonumber(entry.Wins)
		if need and pays and need <= STATE.looks and model:FindFirstChild("HumanoidRootPart") then
			if not bestEntry or pays > tonumber(bestEntry.Wins) then best, bestEntry = model, entry end
		end
	end
	return best, bestEntry
end

local function mogOnce(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	local target = CFrame.new(root.Position + Vector3.new(0, 0, 5))
	local stop = pin(function() return target end)
	task.wait(0.35)
	fire("ContestRequest", true, model.Name)
	local deadline = os.clock() + 2
	repeat task.wait(0.1) until plr:GetAttribute("InContest") or os.clock() > deadline
	if not plr:GetAttribute("InContest") then
		stop()
		return false
	end
	local limit = os.clock() + CONFIG.contestSeconds
	repeat
		fire("ContestClick", true, nil)
		task.wait(0.06)
	until not plr:GetAttribute("InContest") or os.clock() > limit
	stop()
	return true
end

local function mogPhase()
	local ground, need = bestZone()
	if ground then
		STATE.zone = ground.Name .. " (" .. short(need or 0) .. ")"
		-- stand on the zone first so its NPCs stream in; they are client models
		local target = CFrame.new(ground.Position + Vector3.new(0, 6, 0))
		local stop = pin(function() return target end)
		task.wait(1.2)
		stop()
	end
	local deadline = os.clock() + CONFIG.mogSeconds
	while os.clock() < deadline and GEN == _G.__LOOKSCLICK and CONFIG.auto and CONFIG.mog do
		refresh()
		-- Wins buy exactly one thing: the next gear rung. Once that is funded there
		-- is nothing left to mog FOR, and every further second is a second not
		-- spent making the Looks that pay for the next rebirth.
		local _, rungCost = nextGear()
		if rungCost and STATE.wins >= rungCost then
			note("gear funded - back to looks")
			return
		end
		local model, entry = bestNPC()
		if not model then
			note("no beatable NPC in reach - training instead")
			return
		end
		STATE.npc = model.Name
		STATE.npcPays = tonumber(entry.Wins) or 0
		STATE.phase = "mogging " .. model.Name
		if mogOnce(model) then
			STATE.mogs = STATE.mogs + 1
		else
			task.wait(0.5)
		end
		task.wait(0.15)
	end
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

-- The cheapest gear tier that would actually be an upgrade. This is the reserve
-- every other spender has to respect: a rebirth zeroes the balance, so rebirthing
-- while saving for the next tier means the tier is never reached - the starvation
-- pattern, and it kept this farm on the 800-wins Sunscreen while the NPCs it was
-- mogging paid 100K a piece.
-- The shop is a LADDER and it is climbed one rung at a time: standing on the
-- Exfoliant (rung 12) with 17M wins against its 12M price bought nothing at all,
-- while the very next rung above the worn gear went through immediately. So the
-- only thing worth asking for is the cheapest entry whose Multiplier beats what
-- is worn - never the best affordable one.
local function gearLadder()
	local cfg = conf("GearConfig") or {}
	local shop = worldFolder()
	shop = shop and shop:FindFirstChild("GearShop")
	if not shop then return {} end
	local rungs = {}
	for _, model in ipairs(shop:GetChildren()) do
		local entry = cfg[model.Name]
		local cost = entry and tonumber(entry.Cost)
		local mul = entry and tonumber(entry.Multiplier)
		local order = entry and tonumber(entry.Order)
		-- entries with no numeric Cost/Order are the Robux ones (God Crown)
		if cost and mul and order and not entry.Premium then
			rungs[#rungs + 1] = { model = model, entry = entry, cost = cost, mul = mul, order = order }
		end
	end
	table.sort(rungs, function(a, b) return a.order < b.order end)
	return rungs
end

function nextGear()
	for _, rung in ipairs(gearLadder()) do
		if rung.mul > (STATE.gearMul or 0) then return rung.model, rung.cost, rung end
	end
	return nil
end

-- Gear is a best-only ladder and the shop model's ButtonTop is a TouchInterest
-- that answers from 108 studs, so this never moves the character.
local function gearPass()
	local _, hrp = char()
	if not hrp then return end
	-- climb as many rungs as the balance carries in one visit
	for _ = 1, 12 do
		refresh()
		local model, cost, rung = nextGear()
		if not (model and cost and cost <= STATE.wins) then return end
		local button
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Name == "ButtonTop" then button = d break end
		end
		if not button then return end
		local before = plr:GetAttribute("BestGearMultiplier") or 0
		-- the touch answers from about a hundred studs, but the trainer and the
		-- shop are a thousand apart, so park on the button when it is out of range
		local stop
		if (hrp.Position - button.Position).Magnitude > 80 then
			local target = CFrame.new(button.Position + Vector3.new(0, 3, 0))
			stop = pin(function() return target end)
			task.wait(0.8)
		end
		pcall(function()
			firetouchinterest(hrp, button, 0)
			task.wait(0.2)
			firetouchinterest(hrp, button, 1)
		end)
		task.wait(1)
		if stop then stop() end
		local after = plr:GetAttribute("BestGearMultiplier") or before
		if after <= before then return end
		STATE.gear = (rung.entry.Name) or model.Name
		STATE.gearMul = after
		note(string.format("gear %s x%s (%s wins)", STATE.gear, short(after), short(cost)))
	end
end

-- Rebirth is priced in LOOKS, not Wins - `RebirthConfig.Requirement(n)` is the
-- next one's price and it is deducted, not wiped, so anything above it survives.
-- It pays +0.6 on the multiplier every time (36 rebirths measured at x22.5) plus
-- three FameTokens, and it is what unlocks the stronger trainers, so this fires
-- the moment it can and everything else spends only the surplus above it.
local function rebirthNeed()
	local cfg = conf("RebirthConfig")
	if not (cfg and cfg.Requirement) then return nil end
	local ok, need = pcall(cfg.Requirement, STATE.rebirths)
	return ok and tonumber(need) or nil
end

local function spendableLooks()
	local need = rebirthNeed()
	if not need then return STATE.looks end
	return math.max(0, STATE.looks - need * CONFIG.rebirthReserve)
end

-- The reserve alone starves the permanent multipliers: the rebirth wall grows so
-- fast that the surplus is almost never larger than an egg, and the balance is
-- reset every few seconds by the rebirth itself. So anything small MEASURED
-- AGAINST THE WALL passes the guard outright - the "let trivially cheap steps
-- through" rule, keyed to the wall rather than to the noisy per-second rate,
-- which collapses to nothing right after every rebirth.
local function canSpendLooks(cost)
	if not cost or cost > STATE.looks then return false end
	if cost <= spendableLooks() then return true end
	local need = rebirthNeed()
	return need ~= nil and cost <= need * CONFIG.cheapShare
end

local function rebirthPass()
	if CONFIG.rebirthUntil > 0 and STATE.rebirths >= CONFIG.rebirthUntil then return end
	local need = rebirthNeed()
	STATE.rebirthNeed = need or 0
	if need and STATE.looks < need then return end
	local before = STATE.rebirths
	fire("Rebirth", true, "Max")
	task.wait(1.2)
	refresh()
	if STATE.rebirths > before then
		note(string.format("rebirth %s -> %s (%s looks)", short(before), short(STATE.rebirths),
			short(need or 0)))
	end
end

-- Worlds are walls of Looks, and the portal is a model in this world's
-- TravelPortals folder. UsePortal takes the world NUMBER.
local function portalPass()
	local cfg = conf("WorldConfig") or {}
	local nextWorld = (STATE.world or 1) + 1
	if nextWorld > 8 then return end
	local need = tonumber(cfg["World" .. nextWorld .. "Requirement"])
	if not need or STATE.looks < need then return end
	local folder = worldFolder()
	folder = folder and folder:FindFirstChild("TravelPortals")
	local model = folder and folder:FindFirstChild("World" .. nextWorld .. "Portal")
	local pos = pivotOf(model)
	if not pos then return end
	withBody("portal", function()
		STATE.phase = "portal to world " .. nextWorld
		local target = CFrame.new(pos)
		local stop = pin(function() return target end)
		task.wait(1)
		fire("UsePortal", true, nextWorld)
		task.wait(2)
		stop()
		refresh()
		note("world " .. tostring(STATE.world))
	end)
end

--------------------------------------------------------------------------------
-- inventory: pets, auras and boosts
--
-- InventoryState is a request/response channel - Fire(true) asks, the same channel
-- answers with { Pets, Auras, Boosts, Eggs, Locked }. Everything is acted on with
-- InventoryAction(true, <verb>, <id> [, qty]).
--------------------------------------------------------------------------------

local inventory, inventoryAt = nil, 0
local inventoryConn

local function askInventory()
	local ch = channel("InventoryState")
	if not ch then return nil end
	if not inventoryConn then
		inventoryConn = pcall(function()
			ch:Connect(function(data)
				if type(data) == "table" then inventory, inventoryAt = data, os.clock() end
			end)
		end)
	end
	if os.clock() - inventoryAt > 6 then pcall(function() ch:Fire(true) end) end
	return inventory
end

local function countOf(bag, id)
	local entry = bag and bag[id]
	if type(entry) == "table" then return tonumber(entry.Count) or tonumber(entry.Amount) or 1 end
	return tonumber(entry) or 0
end

-- Pets multiply looks; keep the strongest ones equipped up to PetSlots. Equipping
-- is idempotent enough that re-asserting the best set on a timer is cheap.
-- The inventory has its own "best" verbs - EquipBestPets / EquipBestAura /
-- EquipBestGear - so there is no reason to rank and equip by hand.
local function petPass()
	local inv = askInventory()
	local cfg = conf("PetConfig")
	if inv and cfg and cfg.Pets then
		local owned, best = 0, 0
		for id in pairs(inv.Pets or {}) do
			owned = owned + 1
			local info = cfg.Pets[id]
			best = math.max(best, info and tonumber(info.Multiplier) or 0)
		end
		STATE.pets = owned
		STATE.petMul = best
		if owned == 0 then return end
	end
	fire("InventoryAction", true, "EquipBestPets")
end

-- Eggs are priced in LOOKS, so they come out of the surplus above the next
-- rebirth and never out of the rebirth itself.
local function eggPass()
	local cfg = conf("PetConfig")
	if not (cfg and cfg.Eggs) then return end
	local best, bestCost
	for id, egg in pairs(cfg.Eggs) do
		local cost = tonumber(egg.Cost)
		local world = tonumber(egg.World) or 1
		if cost and world <= (STATE.world or 1) and canSpendLooks(cost) then
			if not bestCost or cost > bestCost then best, bestCost = id, cost end
		end
	end
	if not best then return end
	fire("BuyEgg", true, best, 1)
	task.wait(1.2)
	-- buying only puts the egg in the inventory; hatching is its own action and
	-- the pet does not exist until it runs
	fire("InventoryAction", true, "HatchEgg", best, 1)
	task.wait(1.5)
	note(string.format("egg %s (%s looks)", best, short(bestCost)))
	inventoryAt = 0
	if CONFIG.pets then petPass() end
end

-- A roll costs Looks and the result is added to the collection, so the worn aura
-- can only ever improve - equip the best owned one afterwards.
local function auraPass()
	local cfg = conf("AuraConfig")
	if not (cfg and cfg.Rolls) then return end
	local bestRoll, bestCost
	for name, roll in pairs(cfg.Rolls) do
		local cost = tonumber(roll.Cost)  -- entries without one are Robux/token rolls
		if cost and canSpendLooks(cost) and (not bestCost or cost > bestCost) then
			bestRoll, bestCost = name, cost
		end
	end
	if bestRoll then
		fire("AuraRoll", true, bestRoll, nil)
		task.wait(1.5)
	end
	fire("InventoryAction", true, "EquipBestAura")
	inventoryAt = 0
end

local function boostPass()
	local inv = askInventory()
	if not inv then return end
	for id, entry in pairs(inv.Boosts or {}) do
		local n = countOf(inv.Boosts, id)
		if n > 0 then
			fire("InventoryAction", true, "UseBoost", id, 1)
			note("boost " .. tostring(id))
			task.wait(0.4)
		end
	end
end

-- FameTokens arrive three per rebirth. Rebirth (500) is the cheapest and feeds
-- straight back into the thing that produces tokens, so it goes first.
local TOKEN_ORDER = { "Rebirth", "Aura", "Luck", "Pet" }

local function tokenPass()
	local cfg = conf("TokenUpgradesConfig")
	if not cfg then return end
	for _, id in ipairs(TOKEN_ORDER) do
		local entry = cfg[id]
		local price = entry and tonumber(entry.BasePrice)
		local level = plr:GetAttribute("TokenUpgrade_" .. id) or 0
		local max = entry and tonumber(entry.MaxBuyable) or -1
		if price and STATE.tokens >= price and (max < 0 or level < max) then
			fire("BuyTokenUpgrade", true, id)
			task.wait(0.6)
			refresh()
			note("token upgrade " .. id)
			return
		end
	end
end

local function freePass()
	fire("ClaimFreeSpin", true)
	task.wait(0.4)
	if (plr:GetAttribute("Spins") or 0) > 0 then
		fire("SpinWheel", true)
		task.wait(0.6)
	end
	if not plr:GetAttribute("GroupRewardClaimed") then
		fire("ClaimGroupReward", true)
		task.wait(0.4)
	end
	fire("OfflineEarningsClaim", true)
	task.wait(0.3)
	if plr:GetAttribute("LeaveRewardReady") then
		fire("LeaveRewardClaimed", true)
	end
	-- deliberately NOT ClaimRebirthTokens: it takes a COUNT and converts that many
	-- rebirths into three FameTokens each, so it spends the one multiplier that
	-- matters. The panel's own button does the same thing.
end

local function spendPass()
	-- gear runs inside the cycle instead, because buying it may need the body
	if CONFIG.portals then portalPass() end
	if CONFIG.tokens then tokenPass() end
	if CONFIG.eggs then eggPass() end
	if CONFIG.auras then auraPass() end
	if CONFIG.pets then petPass() end
	if CONFIG.boosts then boostPass() end
end

--------------------------------------------------------------------------------
-- the cycle
--------------------------------------------------------------------------------

local function cyclePass()
	if STATE.bodyOwner then return end
	withBody("cycle", function()
		if CONFIG.gear then gearPass() end
		if CONFIG.trainer then trainPhase() end
		if CONFIG.mog then mogPhase() end
	end)
end

task.spawn(function()
	while GEN == _G.__LOOKSCLICK do
		pcall(refresh)
		task.wait(0.5)
	end
end)

loop(0.4, nil, cyclePass)
-- rebirth on its own fast timer: it is the strongest thing in the game and every
-- second it waits is a second of looks piling up behind a wall already passed
loop(2, "rebirth", rebirthPass)
loop(8, nil, spendPass)
loop(90, "freebies", freePass)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__LOOKSCLICK_WIN then pcall(function() _G.__LOOKSCLICK_WIN:Destroy() end) end
for _, root in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui") }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "LooksClickPanel" then pcall(function() g:Destroy() end) end
		end
	end
end

local win = UI.Window({
	name = "LooksClickPanel",
	title = "LOOKS", accentTitle = "CLICK", subtitle = "seltonmt",
	badge = "🌎", width = 920, height = 580,
})
_G.__LOOKSCLICK_WIN = win

local page = win:Page("FARM", UI.icon.bolt)

local main = page:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	note(v and "running" or "stopped")
end, "train, mog, buy gear, rebirth, repeat", UI.theme.good)
main:Toggle("Click", CONFIG.click, function(v) CONFIG.click = v end,
	"the server credits ~3.75/s; firing faster credits LESS, not more")
main:Toggle("Auto trainer", CONFIG.trainer, function(v) CONFIG.trainer = v end,
	"passive looks that stack with clicking, gated by rebirths")
main:Toggle("Mog NPCs", CONFIG.mog, function(v) CONFIG.mog = v end,
	"travels to the strongest NPC your looks beat; the contest is position gated")
main:Stepper("Train for", function() return CONFIG.trainSeconds .. "s" end, function(dir)
	CONFIG.trainSeconds = math.clamp(CONFIG.trainSeconds + dir * 10, 0, 300)
end, "seconds on the trainer before each mogging trip")
main:Stepper("Mog for", function() return CONFIG.mogSeconds .. "s" end, function(dir)
	CONFIG.mogSeconds = math.clamp(CONFIG.mogSeconds + dir * 15, 15, 600)
end, "seconds spent mogging before going back to the trainer")

local spend = page:Card("SPENDING", 2)
spend:Toggle("Buy gear", CONFIG.gear, function(v) CONFIG.gear = v end,
	"best affordable in this world, touched from anywhere; best-only, not a sum",
	UI.theme.warn)
spend:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"Rebirth(\"Max\") - the only thing that unlocks stronger trainers", UI.theme.warn)
spend:Stepper("Rebirth reserve", function()
	return string.format("x%.1f", CONFIG.rebirthReserve)
end, function(dir)
	CONFIG.rebirthReserve = math.clamp(CONFIG.rebirthReserve + dir * 0.5, 1, 10)
end, "eggs and auras may only spend looks above the next rebirth times this")
spend:Toggle("Eggs", CONFIG.eggs, function(v) CONFIG.eggs = v end,
	"priced in looks, so only the surplus above the next rebirth is used", UI.theme.warn)
spend:Toggle("Auras", CONFIG.auras, function(v) CONFIG.auras = v end,
	"rolls the best affordable tier and equips the best one owned", UI.theme.warn)
spend:Toggle("Pets", CONFIG.pets, function(v) CONFIG.pets = v end,
	"keeps the strongest pets equipped up to PetSlots")
spend:Toggle("Boosts", CONFIG.boosts, function(v) CONFIG.boosts = v end,
	"uses anything sitting in the boost inventory")
spend:Toggle("Token upgrades", CONFIG.tokens, function(v) CONFIG.tokens = v end,
	"spends tokens you already hold; it never TRADES rebirths for them", UI.theme.good)
spend:Stepper("Rebirth until", function()
	return CONFIG.rebirthUntil == 0 and "no limit" or short(CONFIG.rebirthUntil)
end, function(dir)
	CONFIG.rebirthUntil = math.clamp(CONFIG.rebirthUntil + dir * 25, 0, 100000)
end, "stop rebirthing at this count")
spend:Toggle("Take portals", CONFIG.portals, function(v) CONFIG.portals = v end,
	"moves on to the next world once its looks wall is passed", UI.theme.warn)
spend:Toggle("Free rewards", CONFIG.freebies, function(v) CONFIG.freebies = v end,
	"free spin, group reward, offline earnings, leave gift", UI.theme.good)
spend:Button("Unstuck", function()
	CONFIG.auto = false
	STATE.bodyOwner = nil
	local _, _, hum = char()
	if hum then pcall(function() hum.PlatformStand = false hum.WalkSpeed = 16 end) end
	note("unstuck, auto off")
end, UI.theme.bad)

local out = page:Card("STATUS", 0):Readout(12, function(text)
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__LOOKSCLICK do
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase     " .. tostring(STATE.phase),
			"  looks     " .. short(STATE.looks) .. "   " .. short(STATE.looksRate) .. "/s",
			"  per click " .. short(STATE.perClick) .. "   gear x" .. short(STATE.gearMul),
			"  wins      " .. short(STATE.wins) .. "   " .. short(STATE.winsRate) .. "/s",
			"  gear      " .. tostring(STATE.gear),
			"  trainer   " .. tostring(STATE.trainer) .. "   x" .. tostring(STATE.trainerMul),
			"  world     " .. tostring(STATE.world) .. "   " .. tostring(STATE.zone),
			"  npc       " .. tostring(STATE.npc) .. "   pays " .. short(STATE.npcPays),
			"  mogs      " .. STATE.mogs .. "   pets " .. STATE.petsEquipped .. "/" .. STATE.pets
				.. " x" .. short(STATE.petMul),
			"  aura      " .. tostring(STATE.aura) .. "   x" .. short(STATE.auraMul),
			"  rebirths  " .. short(STATE.rebirths) .. "   next at " .. short(STATE.rebirthNeed),
			"  tokens    " .. short(STATE.tokens),
			"  " .. tostring(STATE.note),
		}
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s looks   %s wins   reb %s   W%s   %s",
				short(STATE.looks), short(STATE.wins), short(STATE.rebirths),
				tostring(STATE.world), STATE.phase))
		end)
		task.wait(0.5)
	end
end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__LOOKSCLICK_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	refresh = refresh, short = short, pin = pin, conf = conf,
	channel = channel, fire = fire, asGame = asGame,
	bestTrainer = bestTrainer, trainPhase = trainPhase,
	bestZone = bestZone, bestNPC = bestNPC, mogOnce = mogOnce, mogPhase = mogPhase,
	gearPass = gearPass, rebirthPass = rebirthPass, portalPass = portalPass,
	nextGear = nextGear, gearLadder = gearLadder,
	rebirthNeed = rebirthNeed, spendableLooks = spendableLooks, canSpendLooks = canSpendLooks,
	askInventory = askInventory, petPass = petPass, eggPass = eggPass,
	auraPass = auraPass, boostPass = boostPass, tokenPass = tokenPass,
	freePass = freePass, spendPass = spendPass, cyclePass = cyclePass,
	worldFolder = worldFolder,
}

print("[looksclick] gen " .. GEN .. " ready - RightShift for the panel")
