--[[ drainwater.lua - "+1 Drain Water Per Click" (place 103883942725157)

  The loop the game actually runs:

      stand in the pool of your current stage -> it drains by itself -> stage
      completes -> the fish of that pool become claimable -> claim them ->
      display the good ones in your tank (they pay forever) and sell the rest ->
      spend the cash on pumps, auras, upgrades, eggs -> rebirth.

  Everything below was measured through the bridge first. The four that shape
  this file:

  * The CLICK is not the engine. It credits from anywhere (the position check
    lives only in the client) but the server caps it at about 15/s: 10 calls/s
    credited 36 of 36, 50/s credited 58 of 121, one per frame 61 of 241. It only
    feeds your personal water, which is the level bar - not the pool.
  * The POOL drains from presence alone. Stage 1 went 120 -> 0 in 1.5s and stage
    2 went 1274 -> 0 in 4s with no clicks at all, and the water balance was never
    touched. Standing in the current stage's pool is the whole drain.
  * A DISPLAYED FISH pays 10% of its price per minute, forever
    (`onlineRatePerMinute` = price / 10, offline a tenth of that). Selling pays
    the price once. So a fish pays for itself in ten minutes of display, and the
    tank - not the sell pad - is the cash engine. A neighbour with 13 fish
    displayed was earning 21,959,585 cash per minute.
  * Selling is NOT position-gated (SellAllFish worked from inside a pool, 33
    studs below the sell pad) but DISPLAYING is: PlaceFishUI answers `TooFar`
    anywhere except on your own plot.

  No anti-cheat: two sweeps (name search over every script container, and
  `debug.getconstants` over 5,307 loaded functions) found no game-authored
  detector, no rate-limit strings and no decoy remotes. Every remote carries an
  explicit `[C-S]` / `[S-C]` direction tag.

  Never spends Robux: every pump, aura and egg without a `cashPrice` is skipped
  by its own flag, and no Robux product or gamepass prompt is ever touched.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

local GEN = (_G.__DRAINWATER or 0) + 1
_G.__DRAINWATER = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,
	drain = true,          -- stand in the current stage's pool
	click = true,          -- fire the click remote at the server's own ceiling
	clickRate = 12,        -- calls per second; the server credits ~15/s at best
	fish = true,           -- claim the fish of drained pools
	display = true,        -- put the best fish in the tank, they pay forever
	sell = true,           -- sell whatever does not beat what is displayed
	pumps = true,          -- the pump multiplies the drain, so it comes first
	auras = true,
	upgrades = true,       -- Speed, Backpack, FishDisplay
	eggs = true,           -- cash eggs only, Robux eggs are filtered by flag
	pets = true,           -- press EquipBest after every hatch
	rebirth = true,
	offline = true,        -- offline earnings and the tank's pending cash
	rebirthUntil = 0,      -- 0 = no limit
	spendEvery = 15,       -- seconds between spending passes
	diveSeconds = 45,      -- how long one dive may run before the loop breathes
	stallSeconds = 40,     -- no new stage for this long -> surface and cash in
	claimShare = 0.25,     -- while diving, only claim fish worth at least this
	                       -- share of the best one in reach
	pumpReach = 2.5,       -- reserve for the next pump once it is this close
	claimRadius = 14,      -- the prompt itself allows 15 studs
	settle = 1.0,          -- seconds pinned before an action; the server has to
	                       -- believe the position first
}

local STATE = {
	phase = "idle", note = "",
	stage = 1, remaining = 0, water = 0, cash = 0, level = 0, rebirth = 0,
	displayed = 0, slots = 0, backpack = 0, capacity = 0,
	pump = 1, pumpMult = 1, aura = 0, claimed = 0, sold = 0, placed = 0,
	rate = 0,              -- drain per second, measured
	deepest = 1, lastProgress = 0, reserve = 0,
	busy = false,
}

--------------------------------------------------------------------------------
-- helpers (every one above its first caller - a local is invisible above its own
-- definition, and inside pcall that surfaces as a quiet note instead of a crash)
--------------------------------------------------------------------------------

local function short(n)
	n = tonumber(n) or 0
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if math.abs(n) >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
	end
	return string.format("%d", n)
end

local function note(text) STATE.note = text end

-- The config tables store prices AND multipliers as abbreviated STRINGS: "3K",
-- "15K", "4M". tonumber() answers nil for every one of them, which silently made
-- the whole ladder above pump 3 invisible - 152,288 cash sat there while the
-- script kept the 300 pump. The game ships its own parser, so it is read out of
-- the game instead of guessed; anything it cannot parse returns nil and is
-- skipped, never treated as a small number.
local abbConvert
local function num(v)
	if type(v) == "number" then return v end
	if type(v) ~= "string" then return nil end
	local plain = tonumber(v)
	if plain then return plain end
	if abbConvert == nil then
		local utils = ReplicatedStorage:FindFirstChild("Utils")
		local module = utils and utils:FindFirstChild("AbbNumber")
		local ok, loaded = pcall(require, module)
		abbConvert = (ok and type(loaded) == "table" and loaded.ConvertToNumber) or false
	end
	if not abbConvert then return nil end
	local ok, parsed = pcall(abbConvert, v)
	return (ok and type(parsed) == "number") and parsed or nil
end

local function value(folder, key, default)
	local f = plr:FindFirstChild(folder)
	local v = f and f:FindFirstChild(key)
	return v and v.Value or default
end

local function char()
	local model = plr.Character
	if not model then return nil, nil, nil end
	return model, model:FindFirstChild("HumanoidRootPart"), model:FindFirstChildOfClass("Humanoid")
end

-- Pins the character on Heartbeat and returns a stop function. The pools, the
-- fish prompts and the plot all check the server's own copy of the position.
local function pin(getPos)
	local stop, conn = false, nil
	conn = RunService.Heartbeat:Connect(function()
		if stop or GEN ~= _G.__DRAINWATER then conn:Disconnect() return end
		local _, hrp = char()
		local pos = getPos()
		if hrp and pos then hrp.CFrame = CFrame.new(pos) end
	end)
	return function() stop = true pcall(function() conn:Disconnect() end) end
end

local function withLock(name, fn)
	if STATE.busy then return false end
	STATE.busy = true
	local ok, err = pcall(fn)
	STATE.busy = false
	if not ok then note(name .. " failed: " .. tostring(err)) end
	return ok
end

-- Every RemoteFunction here is called behind a wall-clock cap. One with no
-- server handler yields forever, and a yielding call parks whatever thread it
-- runs on - that is how the bridge itself was lost once.
local function invoke(fn, ...)
	if not fn then return nil end
	local args = table.pack(...)
	local out, done = nil, false
	task.spawn(function()
		local ok, res = pcall(function() return fn:InvokeServer(table.unpack(args, 1, args.n)) end)
		out, done = ok and res or nil, true
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < 5 do task.wait(0.05) end
	return out
end

local Remote = ReplicatedStorage:WaitForChild("Remote")
local EV, FN = Remote:WaitForChild("Event"), Remote:WaitForChild("Function")

local function ev(category, name)
	local folder = EV:FindFirstChild(category)
	return folder and folder:FindFirstChild(name)
end

local function fn(category, name)
	local folder = FN:FindFirstChild(category)
	return folder and folder:FindFirstChild(name)
end

-- The map folders are named in Chinese; spelled out in escapes so the file stays
-- pure ASCII and cannot be mangled on the way into the executor.
local SCENE = "\228\184\187\229\156\186\230\153\175"          -- main scene
local VERIFY = "\233\170\140\232\175\129\229\156\186\230\153\175" -- stage area
local STAGE_PREFIX = "\229\133\179\229\141\161"               -- "stage"
local WATER_PART = "\230\176\180\233\157\162"                 -- water surface
local PLACE_BUTTON = "\230\148\190\231\189\174\230\140\137\233\146\174"
local COLLECT_BUTTON = "\230\148\182\233\155\134\230\140\137\233\146\174"

local function verifyFolder()
	local scene = workspace:FindFirstChild(SCENE)
	return scene and scene:FindFirstChild(VERIFY)
end

local function poolOf(stageId)
	local verify = verifyFolder()
	local stage = verify and verify:FindFirstChild(STAGE_PREFIX .. tostring(stageId))
	return stage and stage:FindFirstChild(WATER_PART)
end

-- Stand ON the surface, not in the middle of the block. The water parts are solid
-- (CanCollide true) and the deep ones are nearly eight studs thick, so aiming at
-- Position + 3 puts the character inside the geometry and the physics engine
-- ejects it: at stage 7 that left it 45 studs away with the drain reading 0/s
-- while everything looked like it was working.
local function poolStand(part)
	if not part then return nil end
	return part.Position + Vector3.new(0, part.Size.Y / 2 + 3, 0)
end

local function stageRows()
	local out = invoke(fn("Stage", "[C-S]GetStageState"))
	return type(out) == "table" and out or {}
end

local function remainingOf(stageId)
	for _, row in ipairs(stageRows()) do
		if row.stageId == stageId then return row.remaining, row.required end
	end
	return nil
end

--------------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------------

local function refresh()
	STATE.stage = value("Stage", "stage", 1)
	STATE.water = value("Level", "water", 0)
	STATE.cash = value("Cash", "cash", 0)
	STATE.level = value("Level", "level", 0)
	STATE.rebirth = value("Rebirth", "rebirth", 0)
	STATE.backpack = value("BackpackData", "amount", 0)
	STATE.capacity = value("BackpackData", "capacity", 0)
	STATE.pump = plr:GetAttribute("EquippedPumpId") or 1
	STATE.aura = plr:GetAttribute("EquippedAuraId") or 0
	-- the config table is keyed by STRING ids while the attribute is a number,
	-- so cfg[STATE.pump] silently missed and the panel read x1 forever
	local cfg = rawget(_G, "__DRAINWATER_PUMPCFG")
	local row = cfg and (cfg[tostring(STATE.pump)] or cfg[STATE.pump])
	if row then STATE.pumpMult = num(row.multiplier) or STATE.pumpMult end
end

--------------------------------------------------------------------------------
-- the click
--------------------------------------------------------------------------------

local function startClicking()
	task.spawn(function()
		local remote = ev("Level", "[C-S]Click")
		while GEN == _G.__DRAINWATER do
			if CONFIG.auto and CONFIG.click and remote then
				pcall(function() remote:FireServer() end)
				task.wait(1 / math.max(1, CONFIG.clickRate))
			else
				task.wait(0.4)
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- fish
--------------------------------------------------------------------------------

local function worldFish()
	local verify = verifyFolder()
	local folder = verify and verify:FindFirstChild("WorldFish")
	return folder
end

local function claimableFish()
	local out = {}
	local folder = worldFish()
	if not folder then return out end
	for _, model in ipairs(folder:GetChildren()) do
		if model:GetAttribute("Claimed") ~= true then
			local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
			-- Enabled is the only honest signal: a fish from a pool you have not
			-- drained keeps its prompt disabled, and firing it from far away does
			-- nothing at all (tested at 713 studs).
			if prompt and prompt.Enabled then
				local parent = prompt.Parent
				local pos = parent:IsA("BasePart") and parent.Position
					or (parent:IsA("Model") and parent:GetPivot().Position)
				if pos then
					out[#out + 1] = {
						model = model, prompt = prompt, pos = pos,
						price = tonumber(model:GetAttribute("Price")) or 0,
						rarity = model:GetAttribute("Rarity"),
						mutation = model:GetAttribute("Mutation"),
					}
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.price > b.price end)
	return out
end

local function carried()
	local data = invoke(fn("Fish", "[C-S]GetCarryFishData"))
	if type(data) ~= "table" then return {}, 0, 0 end
	return data.Items or {}, tonumber(data.Count) or 0, tonumber(data.Capacity) or 0
end

local function tankState()
	local ui = invoke(fn("FishShow", "[C-S]GetUIState"))
	if type(ui) ~= "table" then return nil end
	STATE.displayed = tonumber(ui.displayedCount) or 0
	STATE.slots = tonumber(ui.unlockedSlots) or 0
	return ui
end

-- The worst fish currently on display, so a claimed one can be judged against it
-- rather than against nothing. Slots come back keyed in different shapes, so
-- walk them with pairs and take whatever carries a price.
local function worstDisplayed(ui)
	local worst
	for _, container in ipairs({ ui and ui.slots, ui and ui.displayed }) do
		if type(container) == "table" then
			for _, entry in pairs(container) do
				if type(entry) == "table" then
					local price = tonumber(entry.finalFishValue or entry.price)
					if price and (not worst or price < worst) then worst = price end
				end
			end
		end
	end
	return worst
end

local function claimNearby(budgetSeconds, minPrice)
	local list = claimableFish()
	if #list == 0 then return 0 end
	-- The backpack holds seven fish and the run resets the moment we surface, so a
	-- slot spent on a stage-1 fish worth 15 is a stage-8 fish worth 456,000 left
	-- in the pool. Only the top of what is reachable is worth carrying.
	if minPrice and minPrice > 0 then
		local keep = {}
		for _, fish in ipairs(list) do
			if fish.price >= minPrice then keep[#keep + 1] = fish end
		end
		list = keep
		if #list == 0 then return 0 end
	end
	local _, count, capacity = carried()
	local taken = 0
	local t0 = os.clock()
	for _, fish in ipairs(list) do
		if count + taken >= math.max(1, capacity) then break end
		if os.clock() - t0 > (budgetSeconds or 8) then break end
		local unpin = pin(function() return fish.pos + Vector3.new(0, 3, 0) end)
		task.wait(CONFIG.settle)
		pcall(function() fireproximityprompt(fish.prompt) end)
		task.wait(0.35)
		unpin()
		taken = taken + 1
		STATE.claimed = STATE.claimed + 1
		note("claimed " .. tostring(fish.rarity) .. " " .. short(fish.price) ..
			(fish.mutation and fish.mutation ~= "Normal" and ("  " .. fish.mutation) or ""))
	end
	return taken
end

local function plotButtons()
	local plot = workspace:FindFirstChild(tostring(plr:GetAttribute("FishShowPlotId")))
	if not plot then return nil, nil end
	local function posOf(name)
		local part = plot:FindFirstChild(name, true)
		if not part then return nil end
		if part:IsA("BasePart") then return part.Position end
		if part:IsA("Model") then return part:GetPivot().Position end
		local inner = part:FindFirstChildWhichIsA("BasePart", true)
		return inner and inner.Position
	end
	return posOf(PLACE_BUTTON), posOf(COLLECT_BUTTON)
end

-- One trip to the plot does the whole handover, in the order the game enforces:
--
--   1. stand on the place button - that moves the CARRIED fish into the tank
--      inventory. Carried fish are invisible to both sell remotes: SellFish
--      answers "NotFound" and SellAllFish ignores them.
--   2. PlaceFishUI(uid) for the best ones. A displayed fish is protected, which
--      is exactly why the sell step comes afterwards.
--   3. SellAllFish for whatever is left in the inventory. With everything
--      displayed it answers "AllFishProtected", which is a success, not a fault.
--   4. touch the collect button for the tank's pending cash.
local function plotTrip()
	local placePos, collectPos = plotButtons()
	if not placePos then note("no plot found") return false end

	local unpin = pin(function() return placePos + Vector3.new(0, 4, 0) end)
	task.wait(CONFIG.settle + 0.6)
	local ui = tankState()

	-- rank what is now in the inventory and display the best of it
	local inventory = {}
	if ui and type(ui.items) == "table" then
		for _, item in pairs(ui.items) do
			if type(item) == "table" and item.uid then inventory[#inventory + 1] = item end
		end
	end
	table.sort(inventory, function(a, b)
		return (tonumber(a.price) or 0) > (tonumber(b.price) or 0)
	end)

	local free = math.max(0, (STATE.slots or 0) - (STATE.displayed or 0))
	for _, item in ipairs(inventory) do
		if free <= 0 or not CONFIG.display then break end
		local reply = invoke(fn("FishShow", "[C-S]PlaceFishUI"), item.uid)
		if type(reply) == "table" and reply.success then
			STATE.placed = STATE.placed + 1
			free = free - 1
			note("displayed " .. tostring(item.name) .. " " .. short(item.price) ..
				"  (+" .. short((tonumber(item.price) or 0) / 10) .. "/min)")
		end
		task.wait(0.2)
	end
	invoke(fn("FishShow", "[C-S]BestFishUI"))

	if CONFIG.sell then
		local before = STATE.cash
		local reply = invoke(fn("Fish", "[C-S]SellAllFish"))
		task.wait(0.5)
		refresh()
		local gained = STATE.cash - before
		if gained > 0 then
			STATE.sold = STATE.sold + 1
			note("sold the rest for " .. short(gained))
		elseif type(reply) == "table" and reply.reason == "AllFishProtected" then
			note("nothing to sell - everything on display")
		end
	end

	if collectPos then
		unpin()
		unpin = pin(function() return collectPos + Vector3.new(0, 4, 0) end)
		task.wait(CONFIG.settle)
		refresh()
	end
	unpin()
	tankState()
	return true
end

--------------------------------------------------------------------------------
-- draining
--------------------------------------------------------------------------------

local function drainPhase(seconds)
	refresh()
	local stageId = STATE.stage
	local pool = poolOf(stageId)
	if not pool then note("no pool for stage " .. stageId) task.wait(1) return end

	local startRemaining = remainingOf(stageId) or 0
	local unpin = pin(function()
		local current = value("Stage", "stage", stageId)
		local part = (current == stageId) and pool or poolOf(current)
		if part then
			if current ~= stageId then stageId, pool = current, part end
			return poolStand(part)
		end
		return nil
	end)

	local t0 = os.clock()
	local baseline, baseAt, baseStage = startRemaining, os.clock(), stageId
	while os.clock() - t0 < seconds and CONFIG.auto and CONFIG.drain and GEN == _G.__DRAINWATER do
		task.wait(1)
		refresh()
		local left = remainingOf(STATE.stage)
		STATE.remaining = left or 0
		-- the rate is per stage: a stage change resets the baseline, otherwise the
		-- jump from "1.2K left" to "81K left" reads as a negative drain and shows 0
		if STATE.stage ~= baseStage then
			baseStage, baseline, baseAt = STATE.stage, left, os.clock()
			STATE.lastProgress = os.clock()
			if STATE.stage > STATE.deepest then STATE.deepest = STATE.stage end
			unpin()
			return true                      -- a pool just emptied: go claim its fish
		end
		local dt = os.clock() - baseAt
		if left and baseline and dt > 0.5 then
			STATE.rate = math.max(0, (baseline - left) / dt)
		end
		note(string.format("stage %d   %s left   %s/s   pump x%s",
			STATE.stage, short(STATE.remaining), short(STATE.rate), short(STATE.pumpMult)))
		local _, count, capacity = carried()
		if count >= math.max(1, capacity) then break end
	end
	unpin()
	return false
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

local function configModule(name)
	local root = ReplicatedStorage:FindFirstChild("Config") or ReplicatedStorage
	local module = root:FindFirstChild(name, true)
	if not module then return nil end
	local ok, loaded = pcall(require, module)
	return ok and loaded or nil
end

local function ladderBuy(helper, getter, buyEvent, equipEvent, ownedGetter, label)
	local cfg = configModule(helper)
	local all = cfg and cfg[getter] and select(2, pcall(cfg[getter]))
	if type(all) ~= "table" then return false end

	local owned = {}
	local data = invoke(ownedGetter)
	if type(data) == "table" and type(data.Owned) == "table" then
		-- Owned is a SET: { ["10"] = true, ["1"] = true, ... }. Reading the values
		-- instead of the keys stored `owned["true"]`, so the ownership check never
		-- matched and the buy remote was fired again for tiers already owned.
		for id, flag in pairs(data.Owned) do
			if flag then owned[tostring(id)] = true end
		end
	end
	local equipped = type(data) == "table" and data.Equipped or nil

	local best
	for id, entry in pairs(all) do
		local price = num(entry.cashPrice)
		local mult = num(entry.multiplier) or 0
		-- No cashPrice means the tier is sold for Robux only. Filter on the field,
		-- never on the name.
		if price and price <= STATE.cash then
			if not best or mult > best.mult then best = { id = id, mult = mult, price = price,
				name = tostring(entry.name or id) } end
		end
	end
	if not best then return false end

	local currentMult = 0
	for id, entry in pairs(all) do
		if tostring(id) == tostring(equipped) then currentMult = num(entry.multiplier) or 0 end
	end
	-- ids come back as strings from the config and as numbers from the attribute
	if best.mult <= currentMult then return false end

	local before = STATE.cash
	if not owned[tostring(best.id)] then
		pcall(function() buyEvent:FireServer(best.id) end)
		task.wait(0.35)                      -- the game's own UI waits 0.2s here
	end
	pcall(function() equipEvent:FireServer(best.id) end)
	task.wait(0.6)
	refresh()
	if STATE.cash < before or best.mult > currentMult then
		note(label .. " " .. best.name .. "  x" .. tostring(best.mult) .. " for " .. short(best.price))
		return true
	end
	return false
end

local function buyPump()
	if not rawget(_G, "__DRAINWATER_PUMPCFG") then
		local cfg = configModule("PumpHelper")
		local all = cfg and cfg.GetAllPumpConfig and select(2, pcall(cfg.GetAllPumpConfig))
		if type(all) == "table" then _G.__DRAINWATER_PUMPCFG = all end
	end
	return ladderBuy("PumpHelper", "GetAllPumpConfig",
		ev("Pump", "[C-S]BuyCashPump"), ev("Pump", "[C-S]EquipPump"),
		fn("Pump", "[C-S]GetPumpData"), "pump")
end

local function buyAura()
	return ladderBuy("AuraHelper", "GetAllAuraConfig",
		ev("Aura", "[C-S]BuyCashAura"), ev("Aura", "[C-S]EquipAura"),
		fn("Aura", "[C-S]GetAuraData"), "aura")
end

-- Speed, Backpack and FishDisplay. Backpack and FishDisplay both widen the
-- pipeline (more fish per trip, more fish paying per minute), so they are worth
-- more than Speed to a script that teleports anyway.
-- The pump is the depth lever and depth is worth orders of magnitude: a stage-1
-- fish is worth 15, a stage-8 one 456,000. So the next pump rung is fenced off
-- before anything else may spend - but only once it is within reach, or the
-- reserve would freeze every purchase for hours (the starvation pattern).
local function pumpReserve()
	local cfg = rawget(_G, "__DRAINWATER_PUMPCFG")
	if type(cfg) ~= "table" then return 0 end
	local cheapest
	for id, entry in pairs(cfg) do
		local price = num(entry.cashPrice)
		local mult = num(entry.multiplier) or 0
		if price and price > 0 and mult > (STATE.pumpMult or 0) then
			if not cheapest or price < cheapest then cheapest = price end
		end
	end
	if not cheapest then return 0 end
	return (cheapest <= STATE.cash * CONFIG.pumpReach) and cheapest or 0
end

local function spendable()
	local reserve = pumpReserve()
	STATE.reserve = reserve
	return math.max(0, STATE.cash - reserve)
end

-- Backpack first: every surfacing costs the entire run, so the number of fish one
-- dive can carry out is the real limit. FishDisplay second, Speed last.
local UPGRADE_ORDER = { "Backpack", "FishDisplay", "Speed" }

local function buyUpgrades()
	local data = invoke(fn("Upgrade", "[C-S]GetUpgradeData"))
	if type(data) ~= "table" then return false end
	local remote = ev("Upgrade", "[C-S]BuyCashUpgrade")
	if not remote then return false end
	local bought = false
	for _, name in ipairs(UPGRADE_ORDER) do
		local row = data[name]
		local price = num(row and (row.price or row.cost))
		local blocked = price and price > spendable()
		if type(row) == "table" and not blocked
			and (num(row.level) or 0) < (num(row.maxLevel) or 0) then
			local before = STATE.cash
			pcall(function() remote:FireServer(name) end)
			task.wait(0.5)
			refresh()
			if STATE.cash < before then
				note("upgrade " .. name .. " -> " .. tostring((num(row.level) or 0) + 1))
				bought = true
			end
		end
	end
	return bought
end

local function openEggs()
	local cfg = configModule("EggHelper")
	local all = cfg and cfg.GetAllEggConfig and select(2, pcall(cfg.GetAllEggConfig))
	if type(all) ~= "table" then return false end
	local best
	for id, entry in pairs(all) do
		local price = num(entry.cashPrice)
		-- a Robux egg has no cashPrice at all; sorting by price would put it first
		if price and price <= spendable() then
			if not best or price > best.price then best = { id = id, price = price } end
		end
	end
	if not best then return false end
	local can = invoke(fn("Egg", "[C-S]CanOpenEgg"), best.id, 1)
	if can == false then return false end
	local before = STATE.cash
	invoke(fn("Egg", "[C-S]OpenEgg"), best.id, 1)
	task.wait(0.8)
	refresh()
	if STATE.cash < before then
		note("egg " .. tostring(best.id) .. " opened for " .. short(best.price))
		if CONFIG.pets then
			local equip = ev("Pet", "EquipBest")
			if equip then pcall(function() equip:FireServer() end) end
		end
		return true
	end
	return false
end

local function claimFree()
	local before = STATE.cash
	invoke(fn("FishShow", "[C-S]ClaimOfflineCash"))
	task.wait(0.4)
	refresh()
	if STATE.cash > before then
		note("offline cash +" .. short(STATE.cash - before))
		return true
	end
	return false
end

local function doRebirth()
	local remote = ev("Rebirth", "[C - S]TryRebirth")   -- the spaces are literal
		or ev("Rebirth", "[C-S]TryRebirth")
	if not remote then return false end
	local before = STATE.rebirth
	if CONFIG.rebirthUntil > 0 and before >= CONFIG.rebirthUntil then return false end
	pcall(function() remote:FireServer() end)
	task.wait(1.2)
	refresh()
	-- the call answering proves nothing; only the counter moving does
	if STATE.rebirth > before then
		note("rebirth " .. STATE.rebirth)
		return true
	end
	return false
end

local function spendPass()
	withLock("spend", function()
		refresh()
		if CONFIG.offline then claimFree() end
		if CONFIG.pumps then buyPump() end
		if CONFIG.upgrades then buyUpgrades() end
		if CONFIG.auras then buyAura() end
		if CONFIG.eggs then openEggs() end
		if CONFIG.pets then
			local equip = ev("Pet", "EquipBest")
			if equip then pcall(function() equip:FireServer() end) end
		end
		-- the panel's own "place best": it swaps a weaker displayed fish for a
		-- better one sitting in the tank inventory, and costs nothing when there is
		-- nothing better (it simply answers false)
		if CONFIG.display then invoke(fn("FishShow", "[C-S]BestFishUI")) end
		if CONFIG.rebirth then doRebirth() end
	end)
end

--------------------------------------------------------------------------------
-- the cycle
--------------------------------------------------------------------------------

do
	local cfg = configModule("PumpHelper")
	local all = cfg and cfg.GetAllPumpConfig and select(2, pcall(cfg.GetAllPumpConfig))
	if type(all) == "table" then _G.__DRAINWATER_PUMPCFG = all end
end

-- the pump table is keyed by string and is needed by refresh(), so load it once
do
	local cfg = configModule("PumpHelper")
	local all = cfg and cfg.GetAllPumpConfig and select(2, pcall(cfg.GetAllPumpConfig))
	if type(all) == "table" then _G.__DRAINWATER_PUMPCFG = all end
end

startClicking()

task.spawn(function()
	local lastSpend = 0
	while GEN == _G.__DRAINWATER do
		if CONFIG.auto then
			refresh()
			if os.clock() - lastSpend > CONFIG.spendEvery then
				STATE.phase = "spend"
				spendPass()
				lastSpend = os.clock()
			end
			-- LEAVING THE STAGE AREA RESETS THE WHOLE RUN. Measured: stage 5 with
			-- StageRunRevision 56, one trip to the plot, and it came back stage 1
			-- revision 57 with every StageCompleted_* false again. The old cycle
			-- surfaced as soon as ONE fish was carried, so it never got past stage
			-- 5 while the deep pools hold fish worth millions each. So: dive until
			-- the backpack is FULL or the run genuinely stalls, and only then pay
			-- the reset.
			local completed = false
			if CONFIG.drain then
				STATE.phase = "dive"
				completed = drainPhase(CONFIG.diveSeconds)
			end
			if completed and CONFIG.fish then
				STATE.phase = "fish"
				withLock("fish", function()
					-- a fraction of the best fish this run has seen, so the bar
					-- rises with the depth instead of being a fixed number
					local best = 0
					for _, fish in ipairs(claimableFish()) do
						if fish.price > best then best = fish.price end
					end
					claimNearby(6, best * CONFIG.claimShare)
				end)
			end

			local _, count, capacity = carried()
			local full = capacity > 0 and count >= capacity
			local stalled = (os.clock() - STATE.lastProgress) > CONFIG.stallSeconds
			-- about to surface anyway: fill the remaining slots with whatever is
			-- still reachable, cheap or not
			if CONFIG.fish and stalled and not full then
				withLock("topup", function() claimNearby(8, 0) end)
				_, count, capacity = carried()
			end
			if CONFIG.fish and count > 0 and (full or stalled) then
				STATE.phase = "plot"
				withLock("plot", function() plotTrip() end)
				STATE.lastProgress = os.clock()
			end
			if not (CONFIG.drain or CONFIG.fish) then task.wait(1) end
		else
			STATE.phase = "stopped"
			task.wait(0.5)
		end
	end
end)

task.spawn(function()
	while GEN == _G.__DRAINWATER do
		refresh()
		task.wait(1)
	end
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__DRAINWATER_WIN then pcall(function() _G.__DRAINWATER_WIN:Destroy() end) end

local win = UI.Window({
	title = "DRAIN", accentTitle = "WATER", subtitle = "seltonmt",
	badge = "💧", width = 920, height = 580,
})
_G.__DRAINWATER_WIN = win

local page = win:Page("FARM", UI.icon.bolt)

local main = page:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	note(v and "running" or "stopped")
end, "drain, claim, display, sell, spend, repeat", UI.theme.good)
main:Toggle("Drain pools", CONFIG.drain, function(v) CONFIG.drain = v end,
	"stands in the current stage's pool - presence alone drains it")
main:Toggle("Click", CONFIG.click, function(v) CONFIG.click = v end,
	"only feeds the level bar; the server credits about 15/s at most")
main:Slider("Clicks/sec", 4, 20, CONFIG.clickRate, function(v)
	CONFIG.clickRate = math.floor(v)
end, "above 15 the server throws the rest away")
main:Toggle("Claim fish", CONFIG.fish, function(v) CONFIG.fish = v end,
	"only pools you have already drained hand their fish over")
main:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"resets the stage run, multiplies water and cash", UI.theme.warn)

local money = page:Card("FISH & SPENDING", 2)
money:Toggle("Display best fish", CONFIG.display, function(v) CONFIG.display = v end,
	"a displayed fish pays 10% of its price every minute, forever", UI.theme.good)
money:Toggle("Sell the rest", CONFIG.sell, function(v) CONFIG.sell = v end,
	"selling works from anywhere, no walk to the sell pad")
money:Toggle("Buy pumps", CONFIG.pumps, function(v) CONFIG.pumps = v end,
	"the pump multiplies the drain, so it is bought first", UI.theme.warn)
money:Toggle("Buy upgrades", CONFIG.upgrades, function(v) CONFIG.upgrades = v end,
	"FishDisplay and Backpack first, they widen the whole pipeline", UI.theme.warn)
money:Toggle("Buy auras", CONFIG.auras, function(v) CONFIG.auras = v end, nil, UI.theme.warn)
money:Toggle("Open eggs", CONFIG.eggs, function(v) CONFIG.eggs = v end,
	"cash eggs only; a Robux egg has no cash price and is skipped", UI.theme.warn)
money:Toggle("Free rewards", CONFIG.offline, function(v) CONFIG.offline = v end,
	"offline earnings and the tank's pending cash", UI.theme.good)
money:Button("Unstuck", function()
	CONFIG.auto = false
	STATE.busy = false
	note("unstuck, auto off")
end, UI.theme.bad)

local out = page:Card("STATUS", 0):Readout(11, function(text)
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__DRAINWATER do
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase     " .. tostring(STATE.phase),
			"  stage     " .. STATE.stage .. " (deepest " .. STATE.deepest .. ")   " ..
				short(STATE.remaining) .. " left   " .. short(STATE.rate) .. "/s",
			"  cash      " .. short(STATE.cash) .. "   water " .. short(STATE.water),
			"  level     " .. STATE.level .. "   rebirth " .. STATE.rebirth,
			"  pump      #" .. tostring(STATE.pump) .. " x" .. short(STATE.pumpMult) ..
				"   saving " .. short(STATE.reserve),
			"  tank      " .. STATE.displayed .. "/" .. STATE.slots .. " displayed",
			"  backpack  " .. STATE.backpack .. "/" .. STATE.capacity,
			"  claimed   " .. STATE.claimed .. "   displayed " .. STATE.placed ..
				"   sold " .. STATE.sold,
			"  " .. tostring(STATE.note),
		}
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s cash   stage %d   %s/s   tank %d/%d   %s",
				short(STATE.cash), STATE.stage, short(STATE.rate),
				STATE.displayed, STATE.slots, STATE.phase))
		end)
		task.wait(0.5)
	end
end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__DRAINWATER_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	refresh = refresh, short = short, pin = pin, invoke = invoke,
	poolOf = poolOf, poolStand = poolStand, stageRows = stageRows, remainingOf = remainingOf,
	claimableFish = claimableFish, claimNearby = claimNearby, carried = carried,
	tankState = tankState, worstDisplayed = worstDisplayed,
	plotTrip = plotTrip, plotButtons = plotButtons,
	drainPhase = drainPhase, spendPass = spendPass,
	buyPump = buyPump, buyAura = buyAura, buyUpgrades = buyUpgrades,
	openEggs = openEggs, claimFree = claimFree, doRebirth = doRebirth,
	configModule = configModule, num = num,
	pumpReserve = pumpReserve, spendable = spendable,
}

print("[drainwater] gen " .. GEN .. " ready - RightShift for the panel")
