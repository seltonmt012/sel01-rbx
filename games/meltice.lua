--[[ meltice.lua - +1 Melt the Ice Adventure (Studio Icebound)

  Place 124569379724368. Measured 2026-10-22 - see games-clickers.md "meltice".

  THE ICE IS SIMULATED ENTIRELY IN THE CLIENT. The server hands out the loot of
  a segment (LootRequest) and pays a pickup (LootPickup) after checking one
  thing: that the body stands within LOOT.PICKUP_MAX_DISTANCE (25) of the cell.
  Whether the block was melted, or whether the power could melt it at all, is
  never asked - 27 power picked up a 1.31M bag of gold in segment 10 of world 1.
  So a run is: travel to the deepest segments, pick the most valuable items,
  ReturnToBase (the server teleports home and banks the backpack), SellAll.

  The WorldUnlock part at the far end of each field raises maxWorld on touch,
  with the same lack of a power check - a fresh account opened all five worlds
  in under a minute.

  Power comes from SwingCollect(n): a budget of 6 swings a second banked up to
  2 s, and the server multiplies the WHOLE batch by the training ice the body
  stands next to at the moment of the call (measured: 11 swings at 1.5x after
  one second on the ice). So every run ends with a hop onto the best unlocked
  ice and one SwingCollect(12). The ice itself is gated for real: rebirths or a
  game pass, and a locked one pays 1x.

  A rebirth resets POWER and nothing else - cash, melters, upgrades, worlds and
  pets all stay - and doubles the power multiplier, so it is taken the moment
  the level allows it.
]]

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CS         = game:GetService("CollectionService")

if not game:IsLoaded() then game.Loaded:Wait() end
local plr = Players.LocalPlayer
while not plr do
	task.wait(0.1)
	plr = Players.LocalPlayer
end

local ENV
do
	local ok, g = pcall(function() return getgenv() end)
	ENV = (ok and type(g) == "table") and g or _G
end
ENV.__MELTICE = (ENV.__MELTICE or 0) + 1
local GEN = ENV.__MELTICE
local function alive() return ENV.__MELTICE == GEN end

--------------------------------------------------------------------------------
-- the game's own modules
--------------------------------------------------------------------------------

local Framework = require(RS:WaitForChild("Framework", 30))
local LIST = RS:WaitForChild("Shared"):WaitForChild("List")

local function get(name)
	local ok, m = pcall(Framework.Get, name)
	if ok then return m end
end

-- The controllers register while the place loads, and the hub's teleport queue
-- can start this before they have. Wait for the ones everything depends on.
local G = {}
for _ = 1, 120 do
	G.Net, G.Data, G.Ice, G.IM = get("Net"), get("DataController"), get("IceFieldController"), get("IceMath")
	if G.Net and G.Data and G.Ice and G.IM and G.Data:IsLoaded() then break end
	task.wait(0.5)
end
G.Mult   = get("Multipliers") or require(RS.Shared.Modules.Multipliers)
G.Format = get("Format")
G.Aura   = get("AuraMath")

local GameConfig = require(RS.Shared.Config.Game)
local ICE        = GameConfig.ICE
local Items      = require(LIST.Items)
local Melters    = require(LIST.Melters)
local Upgrades   = require(LIST.Upgrades)
local Rebirths   = require(LIST.Rebirths)
local Worlds     = require(LIST.Worlds)
local Cubes      = require(LIST.TrainingCubes)
local Eggs       = require(LIST.Eggs)
local Pets       = require(LIST.Pets)
local Talents    = require(LIST.Talents)
local Runes      = require(LIST.Runes)
local Forge      = get("ForgeMath") or require(RS.Shared.Modules.ForgeMath)
local Ench       = get("EnchantMath") or require(RS.Shared.Modules.EnchantMath)

--------------------------------------------------------------------------------
-- config and state
--------------------------------------------------------------------------------

local CONFIG = {
	auto        = false,    -- the master switch: everything below only acts while on
	-- farm
	loot        = true,     -- loot runs into the deepest segments
	world       = "Auto",   -- Auto | Best loot | Best ice | 1 .. 5
	unlock      = true,     -- touch the WorldUnlock at the end of the field
	segments    = 3,        -- how many of the deepest segments a run searches
	extras      = true,     -- potions and enchant books lying in those segments
	step        = 150,      -- studs per hop when travelling
	-- power
	train       = true,     -- SwingCollect at the server's budget
	trainIce    = true,     -- cash the batch in on the best unlocked training ice
	rebirth     = true,
	-- spending
	melters     = true,
	upgrades    = true,
	eggs        = true,
	fuse        = true,
	equipPets   = true,
	deletePets  = true,
	talents     = true,
	potions     = true,
	auras       = true,     -- roll into EMPTY slots only
	auraReplace = false,    -- keep rolling once the slots are full (replaces the weakest)
	claims      = true,
	antiAfk     = true,
	-- boosts
	forge       = true,     -- collect the recipe items and craft the runes, power first
	enchant     = true,     -- enchant the equipped pets at the world-5 stand
	enchantGoal = "Strong V", -- Strong V | Inferno
	indexItems  = true,     -- pick up one of every item not in the index yet
	indexPets   = true,     -- hatch every egg until each pet is indexed in all three tiers
}

local STATE = {
	phase = "starting", note = "", runs = 0, items = 0, extras = 0, earned = 0,
	lastSale = 0, lastRun = 0, swings = 0, power = 0, rebirths = 0, hatches = 0,
	fuses = 0, deleted = 0, melters = 0, upgrades = 0, talents = 0, potions = 0,
	auras = 0, unlocks = 0, claims = 0, busy = false, started = os.clock(),
	ice = "-", lastSwing = 0,
	forged = 0, forgeWait = 0, enchRolls = 0, enchanted = 0, idxItems = 0, idxHatches = 0,
	idxMiss = {}, idxDone = {},
}

local function note(s) STATE.note = tostring(s) end

local function data() return G.Data:GetData() end

local function fmt(n)
	n = tonumber(n) or 0
	if G.Format and G.Format.suffix then
		local ok, s = pcall(G.Format.suffix, n)
		if ok and s then return tostring(s) end
	end
	return string.format("%.3g", n)
end

-- Net.invoke yields until the server answers, so it is only ever called from
-- our own threads. pcall: a remote the server refuses must not end the loop.
local function invoke(name, ...)
	local ok, res = pcall(G.Net.invoke, name, ...)
	if ok then return res end
	return nil
end

local function fire(name, ...)
	pcall(G.Net.fire, name, ...)
end

local function root()
	local c = plr.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if r and h and h.Health > 0 then return r end
end

local function place(r, pos)
	r.CFrame = CFrame.new(pos)
	pcall(function() r.AssemblyLinearVelocity = Vector3.zero end)
end

-- Hops of CONFIG.step studs. A single 735-stud jump from the base into segment
-- 10 was put back at the spawn by the server once on a fresh account; hops of
-- 90-200 studs every 0.1-0.2 s never were. If the server does pull the body
-- back, the rest of the session travels in 60-stud hops.
local function travel(pos)
	local r = root()
	if not r then return false end
	local from = r.Position
	local delta = pos - from
	local step = math.max(40, CONFIG.step)
	if STATE.gentle then step = math.min(step, 60) end
	local n = math.max(1, math.ceil(delta.Magnitude / step))
	local last
	for i = 1, n do
		if not alive() then return false end
		r = root()
		if not r then return false end
		if last and (r.Position - last).Magnitude > 50 then
			STATE.gentle = true
			note("the server moved the body back - travelling in short hops from now on")
			return false
		end
		last = from + delta * (i / n)
		place(r, last)
		if i < n then task.wait(0.1) end
	end
	return true
end

local function worldNum(d) return tonumber((d or data()).world) or 1 end
local function maxWorld(d) return tonumber((d or data()).maxWorld) or 1 end

local function folderOf(w)
	local f = workspace:FindFirstChild("Worlds")
	f = f and f:FindFirstChild("World" .. w)
	return f and f:FindFirstChild("Interactables")
end

local function spawnOf(w)
	local i = folderOf(w)
	local s = i and i:FindFirstChild("WorldSpawn")
	return s and s.Position
end

-- The forge stall (worlds 1-4) and the enchant stall (world 5 only, in the same
-- spot) stand 19 studs east and 61 north of the world spawn in every world. The
-- part is streamed out until the body is near, so the offset is the fallback.
local function standOf(w, folder, name)
	local i = folderOf(w)
	local f = i and i:FindFirstChild(folder)
	local part = f and f:FindFirstChild(name, true)
	if part and part:IsA("BasePart") then return part.Position end
	local s = spawnOf(w)
	return s and (s + Vector3.new(19, 4, 61))
end

--------------------------------------------------------------------------------
-- forge and index planning
--------------------------------------------------------------------------------

-- Power first: one star of Magma Power took the forge multiplier from 1 to 4.6.
-- Then the slot runes, then cash. The speed runes only make the walk faster,
-- and nothing here walks.
local FORGE_ORDER = {
	"power5", "power4", "power3", "petPal", "auraPal", "power2", "power1",
	"bigBag", "eggPal", "luckPal", "cash5", "cash4", "cash3", "cash2", "cash1",
}

local function forgeTarget(d)
	if not CONFIG.forge then return nil end
	local skip = STATE.forgeSkip or {}
	for _, id in ipairs(FORGE_ORDER) do
		local r = Runes.fromId[id]
		local okM, maxed = pcall(Forge.isMaxed, d, r)
		local okD, dormant = pcall(Forge.isDormant, r)
		if r and not skip[id] and (tonumber(r.world) or 1) <= maxWorld(d) and okM and not maxed and okD and not dormant then
			return r
		end
	end
end

local function carried(d, id)
	local n = 0
	for _, e in ipairs(type(d.backpack) == "table" and d.backpack or {}) do
		if type(e) == "table" and e.id == id then n = n + 1 end
	end
	return n
end

-- What the rune still needs for EVERY star it has left, minus what is banked
-- and carried. SellAll keeps the tracked rune's whole recipe, so collecting for
-- all stars at once costs nothing and saves a trip to the forge per star.
local function forgeNeed(d, rune)
	local need = {}
	local cfg = Forge.cfg() or {}
	local costs = type(cfg.STAR_COST) == "table" and cfg.STAR_COST or {}
	for s = Forge.stars(d, rune.id) + 1, Forge.maxStars(rune) do
		local f = tonumber(costs[s]) or 1
		if rune.gold or f <= 0 or f > 1 then f = 1 end
		for _, c in ipairs(Forge.recipeOf(rune)) do
			need[c.id] = (need[c.id] or 0) + math.max(1, math.ceil(c.count * f - 1e-9))
		end
	end
	local short = false
	for id, n in pairs(need) do
		need[id] = n - Forge.normalCount(d, id) - carried(d, id)
		if need[id] > 0 then short = true end
	end
	return need, short
end

local function canForgeAny(d)
	for _, id in ipairs(FORGE_ORDER) do
		local ok, can = pcall(Forge.canForge, d, id)
		if ok and can then return true end
	end
	return false
end

-- Go to the forge once every star is covered, or after a dozen runs with at
-- least the next star in hand - a rare item must not hold the rest back.
local function forgeReady(d, rune)
	local _, short = forgeNeed(d, rune)
	if not short then return canForgeAny(d) end
	return STATE.forgeWait >= 12 and canForgeAny(d)
end

local function itemIndexed(d, id)
	local idx = type(d.index) == "table" and type(d.index.items) == "table" and d.index.items or {}
	return idx[id] == true
end

-- The lowest world that still has an item missing from the index and has not
-- come up empty six runs in a row in the last ten minutes.
local function indexWorld(d)
	if not CONFIG.indexItems then return nil end
	for w = 1, maxWorld(d) do
		if not STATE.idxDone[w] or os.clock() - STATE.idxDone[w] > 600 then
			for _, it in ipairs(Items.list) do
				if (tonumber(it.world) or 1) == w and not itemIndexed(d, it.id) then return w end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- worlds
--------------------------------------------------------------------------------

-- the best training ice the account has unlocked, in any world it can reach
local function bestIceAnywhere(d)
	local m, best = maxWorld(d), nil
	for _, cube in ipairs(Cubes.list) do
		local w = tonumber(cube.world) or 1
		local ok, open = pcall(Cubes.isUnlocked, d, cube)
		if w <= m and ok and open then
			local mult = tonumber(cube.mult) or 1
			if not best or mult > best.mult or (mult == best.mult and w > best.world) then
				best = { world = w, mult = mult, id = cube.id }
			end
		end
	end
	return best
end

local nextMelter, bestEgg

-- Auto: the best loot world while cash still buys something that matters - a
-- melter, or eggs when the balance is low - and the world of the best training
-- ice once it does not. The hysteresis keeps it from flapping between the two.
local function targetWorld(d)
	local m = maxWorld(d)
	local mode = tostring(CONFIG.world)
	local w = tonumber(mode)
	if w then return math.clamp(math.floor(w), 1, m), "fixed" end
	local ice = bestIceAnywhere(d)
	if mode == "Best ice" then return ice and ice.world or m, "best ice" end
	if mode ~= "Auto" then return m, "best loot" end
	if CONFIG.melters and nextMelter(d) then
		STATE.wantCash = true
		return m, "a melter is still to buy"
	end
	-- the forge: farm the rune's own world, and craft at a stall in worlds 1-4
	local rune = forgeTarget(d)
	if rune then
		if forgeReady(d, rune) then
			local here = worldNum(d)
			return (here <= 4) and here or 4, "forge: crafting " .. tostring(rune.name)
		end
		return tonumber(rune.world) or m, "forge: items for " .. tostring(rune.name)
	end
	local iw = indexWorld(d)
	if iw then return iw, "index: items of world " .. iw end
	if not ice or ice.world == m then return m, "best loot" end
	local egg = CONFIG.eggs and bestEgg(d)
	local cash = tonumber(d.cash) or 0
	if egg then
		if cash < egg.priceCash * 20 then STATE.wantCash = true end
		if cash > egg.priceCash * 200 then STATE.wantCash = false end
	else
		STATE.wantCash = false
	end
	if STATE.wantCash then return m, "cash for eggs" end
	return ice.world, "training ice x" .. tostring(ice.mult)
end

-- WorldTeleport answers true and the field controller follows a moment later;
-- a run started before it has would read the old world's layout.
local function ensureWorld()
	local d = data()
	local want, why = targetWorld(d)
	STATE.why = why
	if worldNum(d) == want and G.Ice:GetWorld() == want then return true end
	STATE.phase = "teleporting to world " .. want
	invoke("WorldTeleport", want)
	local t = os.clock() + 8
	while os.clock() < t and alive() do
		if worldNum() == want and G.Ice:GetWorld() == want and G.Ice:GetOriginCFrame() then
			task.wait(0.5)
			return true
		end
		task.wait(0.2)
	end
	note("world " .. want .. " did not load")
	return false
end

local function unlockNext()
	local d = data()
	local w = worldNum(d)
	if maxWorld(d) > w or not Worlds.isListed(w + 1) then return false end
	local i = folderOf(w)
	local part = i and i:FindFirstChild("WorldUnlock")
	if not part then return false end
	STATE.phase = "unlocking world " .. (w + 1)
	STATE.busy = true
	travel(part.Position + Vector3.new(0, 3, 0))
	local r = root()
	if r then
		for _ = 1, 3 do
			place(r, part.Position)
			pcall(function()
				firetouchinterest(r, part, 0)
				task.wait()
				firetouchinterest(r, part, 1)
			end)
			task.wait(0.4)
			if maxWorld() > w then break end
		end
	end
	STATE.busy = false
	if maxWorld() > w then
		STATE.unlocks = STATE.unlocks + 1
		note("world " .. (w + 1) .. " unlocked")
		invoke("ReturnToBase")
		return true
	end
	note("world " .. (w + 1) .. " did not unlock")
	return false
end

--------------------------------------------------------------------------------
-- training ice and the swing budget
--------------------------------------------------------------------------------

local function bestIce(d)
	local w, best, bestMult = worldNum(d), nil, 1
	for _, spot in ipairs(CS:GetTagged("TrainingCubeSpot")) do
		if spot:GetAttribute("World") == w then
			local cube = Cubes.fromId[spot:GetAttribute("CubeId")]
			local ok, open = pcall(Cubes.isUnlocked, d, cube)
			if cube and ok and open and (tonumber(cube.mult) or 1) > bestMult then
				best, bestMult = spot, tonumber(cube.mult)
			end
		end
	end
	return best, bestMult
end

-- One batch. The server credits min(asked, 6/s since the last credited call,
-- capped at 2 s), so asking for 12 never costs anything.
local function swing()
	if os.clock() - STATE.lastSwing < 0.9 then return end
	local p0 = tonumber(data().power) or 0
	STATE.lastSwing = os.clock()
	if invoke("SwingCollect", 12) then
		STATE.swings = STATE.swings + 1
		task.delay(0.6, function()
			local gain = (tonumber(data().power) or 0) - p0
			if gain > 0 then STATE.power = gain end
		end)
	end
end

local function trainHop()
	if not CONFIG.train then return end
	local d = data()
	local spot, mult = nil, 1
	if CONFIG.trainIce then spot, mult = bestIce(d) end
	STATE.ice = spot and (spot.Name .. "  x" .. fmt(mult)) or "none unlocked here (x1)"
	if spot then
		local r = root()
		if r then
			travel(spot.Position + Vector3.new(0, 3, 5))
			task.wait(0.15)
		end
	end
	swing()
end

--------------------------------------------------------------------------------
-- loot runs
--------------------------------------------------------------------------------

local function cellPos(origin, layout, seg, cell)
	local x, y, z = G.IM.fromCellId(cell)
	return G.IM.cellCFrame(origin, ICE, layout, seg, x, y, z).Position
end

local function pickup(e)
	local at = e.pos + Vector3.new(0, 6, 0)
	if not travel(at) then return false end
	-- the server reads its own copy of the position: 0.03 s after the hop was
	-- refused, 0.08 s accepted
	for try = 1, 4 do
		task.wait(try == 1 and 0.09 or 0.12)
		local r = root()
		if not r then return false end
		place(r, at)
		if invoke("LootPickup", e.seg, e.cell) == true then return true end
	end
	return false
end

local function backHome()
	invoke("ReturnToBase")
	local home = spawnOf(worldNum())
	local t = os.clock() + 1.5
	while os.clock() < t and alive() do
		local r = root()
		if r and home and (r.Position - home).Magnitude < 40 then break end
		task.wait(0.05)
	end
end

-- Always asked, even when the inventory reads empty: the bank happens on the
-- server and the replica can lag the ReturnToBase answer.
local function sell()
	local got = tonumber(invoke("SellAll")) or 0
	if got > 0 then
		STATE.earned = STATE.earned + got
		STATE.lastSale = got
	end
	return got
end

local function lootRun()
	local d = data()
	local origin, layout = G.Ice:GetOriginCFrame(), G.Ice:GetLayout()
	if not (origin and layout and layout.count) then
		note("ice field not loaded")
		return
	end
	local t0 = os.clock()
	STATE.phase = "loot run"
	local room = (tonumber(G.Mult.getCarryCapacity(d)) or 3) - (type(d.backpack) == "table" and #d.backpack or 0)
	local items, extras = {}, {}
	local deepest = layout.count
	local here = worldNum(d)
	local rune = forgeTarget(d)
	local need = rune and (forgeNeed(d, rune)) or {}
	local hunting = indexWorld(d) == here
	-- recipe items and the common ones the index lacks sit in the SHALLOW
	-- segments, so either of those widens the search to the whole field
	local wide = hunting
	for _, n in pairs(need) do
		if n > 0 then wide = true end
	end
	local first = wide and 1 or math.max(1, deepest - CONFIG.segments + 1)
	-- the requests go out together; one round trip instead of one per segment
	local answers, pending = {}, 0
	for seg = deepest, first, -1 do
		pending = pending + 1
		task.spawn(function()
			answers[seg] = invoke("LootRequest", seg)
			pending = pending - 1
		end)
	end
	local waitUntil = os.clock() + 5
	while pending > 0 and os.clock() < waitUntil do task.wait() end
	for seg = deepest, first, -1 do
		for _, e in ipairs(type(answers[seg]) == "table" and answers[seg] or {}) do
			if type(e) == "table" and e.cellId then
				local entry = { seg = seg, cell = e.cellId }
				local ok, pos = pcall(cellPos, origin, layout, seg, e.cellId)
				if ok and pos then
					entry.pos = pos
					if e.itemId then
						entry.id, entry.value = e.itemId, Items.valueOf(e.itemId)
						items[#items + 1] = entry
					elseif e.potionId or e.books then
						entry.id = e.potionId or ((tonumber(e.books) or 1) .. " books")
						extras[#extras + 1] = entry
					end
				end
			end
		end
	end
	table.sort(items, function(a, b) return a.value > b.value end)
	local cap = math.max(0, room)
	local picks, taken = {}, {}
	local function take(e)
		picks[#picks + 1] = e
		taken[e] = true
	end
	-- 1. what the forge rune still needs
	local forgeSeen = 0
	for _, e in ipairs(items) do
		if (need[e.id] or 0) > 0 then
			forgeSeen = forgeSeen + 1
			if #picks < cap then
				need[e.id] = need[e.id] - 1
				e.forge = true
				take(e)
			end
		end
	end
	-- 2. one of every item the index is missing
	local unseen, idxSeen = {}, 0
	if CONFIG.indexItems then
		for _, e in ipairs(items) do
			if not taken[e] and not unseen[e.id] and not itemIndexed(d, e.id) then
				unseen[e.id] = true
				idxSeen = idxSeen + 1
				if #picks < cap then
					e.index = true
					take(e)
				end
			end
		end
	end
	-- 3. the rest by value
	for _, e in ipairs(items) do
		if #picks >= cap then break end
		if not taken[e] then take(e) end
	end
	if hunting then
		STATE.idxMiss[here] = idxSeen > 0 and 0 or (STATE.idxMiss[here] or 0) + 1
		if STATE.idxMiss[here] >= 6 then
			STATE.idxMiss[here] = 0
			STATE.idxDone[here] = os.clock()
			note("index: nothing new in world " .. here .. " for six runs - moving on")
		end
	end
	if rune then
		if canForgeAny(d) then STATE.forgeWait = STATE.forgeWait + 1 end
		-- a recipe item that never shows must not hold the farm in this world
		if tonumber(rune.world) == here then
			STATE.forgeIdle = forgeSeen > 0 and 0 or (STATE.forgeIdle or 0) + 1
			if STATE.forgeIdle >= 30 then
				STATE.forgeSkip = STATE.forgeSkip or {}
				STATE.forgeSkip[rune.id] = true
				STATE.forgeIdle = 0
				note("forge: no " .. tostring(rune.name) .. " items for 30 runs - skipped this session")
			end
		end
	end
	if CONFIG.extras then
		for _, e in ipairs(extras) do picks[#picks + 1] = e end
	end
	-- shallow to deep, then the server carries us home for free
	local oz = origin.Position
	table.sort(picks, function(a, b) return (a.pos - oz).Magnitude < (b.pos - oz).Magnitude end)
	STATE.busy = true
	local got = 0
	for _, e in ipairs(picks) do
		if not (alive() and CONFIG.auto and CONFIG.loot) then break end
		if pickup(e) then
			got = got + 1
			if e.value then STATE.items = STATE.items + 1 else STATE.extras = STATE.extras + 1 end
			if e.index then STATE.idxItems = STATE.idxItems + 1 end
		end
	end
	STATE.phase = "banking"
	backHome()
	STATE.busy = false
	local sold = sell()
	STATE.runs = STATE.runs + 1
	STATE.lastRun = os.clock() - t0
	if got == 0 and #picks > 0 then
		note("no pickup was accepted this run")
	elseif sold > 0 then
		note(string.format("run %d: %d picked, sold %s", STATE.runs, got, fmt(sold)))
	end
end

--------------------------------------------------------------------------------
-- forge and enchants
--------------------------------------------------------------------------------

-- SellAll keeps the TRACKED rune's recipe items, so the rune being farmed is
-- always the tracked one. ForgeTrack("") would clear it.
local function forgeTrack()
	local d = data()
	local rune = forgeTarget(d)
	STATE.forgeName = rune and rune.name or (CONFIG.forge and "all done" or "off")
	if not rune then return end
	local cur = type(d.forge) == "table" and d.forge.track or ""
	if cur ~= rune.id then fire("ForgeTrack", rune.id) end
end

-- ForgeCraft answers "far" anywhere but next to a forge stall; there is one in
-- worlds 1-4 and none in 5. Every rune in reach is crafted while we are here.
local function forgeCraft()
	local d = data()
	local w = worldNum(d)
	if w > 4 or not canForgeAny(d) then return false end
	local pos = standOf(w, "Forge", "ForgeStand")
	if not pos then return false end
	STATE.phase = "forging"
	STATE.busy = true
	travel(pos + Vector3.new(0, 3, 5))
	task.wait(0.3)
	local made = 0
	for _, id in ipairs(FORGE_ORDER) do
		for _ = 1, 6 do
			local ok, can = pcall(Forge.canForge, data(), id)
			if not (ok and can) or not alive() then break end
			local r = invoke("ForgeCraft", id)
			if type(r) == "table" and r.ok then
				made = made + 1
				STATE.forged = STATE.forged + 1
				note(string.format("forged %s - %d stars", tostring(Runes.fromId[id].name), tonumber(r.stars) or 0))
			else
				if type(r) == "table" and r.reason == "far" then
					local root2 = root()
					if root2 then place(root2, pos + Vector3.new(0, 3, 5)) end
				end
				break
			end
			task.wait(0.6)
		end
	end
	STATE.busy = false
	if made > 0 then STATE.forgeWait = 0 end
	return made > 0
end

local function enchantGoalMet(p)
	local goal = CONFIG.enchantGoal == "Inferno" and "inferno" or "strong"
	local ok, met = pcall(Ench.meets, p, goal)
	return ok and met
end

-- EnchantRoll answers "stall" away from the world-5 stand. Every roll replaces
-- the pet's enchant, so a pet is left alone the moment it reaches the goal
-- (Strong V = +100% of that pet's power, Inferno = +150% power and cash).
local function enchantStep()
	if not CONFIG.enchant or worldNum() ~= 5 then return false end
	local d = data()
	local todo = {}
	for uid in pairs(type(d.equippedPets) == "table" and d.equippedPets or {}) do
		local p = type(d.pets) == "table" and d.pets[uid]
		if p and not enchantGoalMet(p) then todo[#todo + 1] = uid end
	end
	if #todo == 0 then return false end
	local okW, why = pcall(Ench.whyNot, d, todo[1])
	if not okW or why then return false end
	local pos = standOf(5, "Enchants", "EnchantStand")
	if not pos then return false end
	STATE.phase = "enchanting"
	STATE.busy = true
	travel(pos + Vector3.new(0, 3, 5))
	task.wait(0.3)
	local stop = os.clock() + 10
	for _, uid in ipairs(todo) do
		while os.clock() < stop and alive() and CONFIG.auto do
			local r = invoke("EnchantRoll", uid)
			if type(r) ~= "table" or not r.ok then
				if type(r) == "table" and r.reason == "stall" then
					local root2 = root()
					if root2 then place(root2, pos + Vector3.new(0, 3, 5)) end
				end
				break
			end
			STATE.enchRolls = STATE.enchRolls + 1
			if enchantGoalMet({ enchant = { id = r.id, level = r.level } }) then
				STATE.enchanted = STATE.enchanted + 1
				note("enchant: " .. tostring(r.id) .. " " .. tostring(r.level) .. " on a pet")
				break
			end
			task.wait(0.27)
		end
	end
	STATE.busy = false
	return true
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

local function cashNow() return tonumber(data().cash) or 0 end

-- the cheapest melter that would still be an upgrade - what the egg waits for
function nextMelter(d)
	local best = Melters.bestOwnedMelter and Melters.bestOwnedMelter(d)
	local floor = best and best.basePower or 0
	local pick
	for _, m in ipairs(Melters.list) do
		if Melters.canCashBuy(d, m) and m.basePower > floor and (not pick or m.costCash < pick.costCash) then
			pick = m
		end
	end
	return pick
end

local function buyMelter()
	local d = data()
	local m = Melters.bestAffordable(d)
	if m then
		fire("MeltersBuy", m.id)
		task.wait(0.6)
		d = data()
		if d.melters and d.melters[m.id] then
			STATE.melters = STATE.melters + 1
			note("bought the " .. tostring(m.name))
			if d.equippedMelter ~= m.id and not Melters.holdsPremium(d) then fire("MeltersEquip", m.id) end
			return true
		end
	end
	-- the buy equips by itself; this only covers a melter bought by hand
	local best = Melters.bestOwnedMelter and Melters.bestOwnedMelter(d)
	if best and d.equippedMelter ~= best.id and not Melters.holdsPremium(d) then
		local cur = Melters.fromId[d.equippedMelter]
		if not cur or cur.basePower < best.basePower then fire("MeltersEquip", best.id) end
	end
	return false
end

-- capacity first: it is the only one a loot run is limited by
local UPGRADE_ORDER = { "capacity", "agility", "range", "mobility" }

local function buyUpgrades()
	local d = data()
	local lv = type(d.upgrades) == "table" and d.upgrades or {}
	for _, id in ipairs(UPGRADE_ORDER) do
		local u = Upgrades.fromId[id]
		local level = tonumber(lv[id]) or 0
		local cost = u and u.costs and u.costs[level + 1]
		if cost and cost <= cashNow() then
			fire("UpgradesBuy", id)
			STATE.upgrades = STATE.upgrades + 1
			task.wait(0.4)
			return true
		end
	end
	return false
end

local function petCount(d)
	local n = 0
	for _ in pairs(type(d.pets) == "table" and d.pets or {}) do n = n + 1 end
	return n
end

local function petPower(p)
	local e = Pets.fromId[p.id]
	if not e then return 0 end
	local ok, pw, cs = pcall(Pets.statsFor, e, tonumber(p.tier) or 1)
	if not ok then return 0 end
	return (tonumber(pw) or 0) + (tonumber(cs) or 0)
end

function bestEgg(d)
	local m, pick = maxWorld(d), nil
	for _, e in ipairs(Eggs.list) do
		if not e.exclusive and tonumber(e.priceCash) and (tonumber(e.world) or 1) <= m then
			if not pick or e.priceCash > pick.priceCash then pick = e end
		end
	end
	return pick
end

local function petIndex(d)
	return type(d.index) == "table" and type(d.index.pets) == "table" and d.index.pets or {}
end

local function idxCount(t)
	local n = 0
	for _, v in pairs(type(t) == "table" and t or {}) do
		if v then n = n + 1 end
	end
	return n
end

-- The pet index counts every TIER ("Cat#1", "Cat#2", "Cat#3"), +10% power per
-- five entries, so 30 hatchable pets x 3 tiers is worth up to x2.8. The first
-- egg with a pet missing from it, cheapest world first; pets under 1% of their
-- egg are left to luck - three tiers of one would take thousands of hatches.
local function indexEgg(d)
	if not CONFIG.indexPets then return nil end
	local idx = petIndex(d)
	for _, egg in ipairs(Eggs.list) do
		if not egg.exclusive and tonumber(egg.priceCash) and (tonumber(egg.world) or 1) <= maxWorld(d) then
			local total = 0
			for _, w in pairs(egg.pool or {}) do total = total + w end
			for petId, w in pairs(egg.pool or {}) do
				if total > 0 and w / total >= 0.01 then
					for tier = 1, 3 do
						if not idx[petId .. "#" .. tier] then return egg end
					end
				end
			end
		end
	end
end

-- One egg per call, from its own 2.1 s loop: the server hatches one every ~2 s
-- (gaps of 0.3-1 s were refused, 2 s went 3/3). Index eggs first, every fourth
-- the best egg, which is the one that makes the strongest pets.
local hatchTurn, lastEquip = 0, 0
local function hatch()
	local d = data()
	local storage = tonumber(G.Mult.getMaxPetStorage(d)) or 100
	if petCount(d) >= storage - 1 then return false end
	hatchTurn = hatchTurn + 1
	local ie = indexEgg(d)
	local egg = ie
	if CONFIG.eggs and (not egg or hatchTurn % 4 == 0) then egg = bestEgg(d) or ie end
	if not egg then return false end
	local cash = cashNow()
	if cash < egg.priceCash then return false end
	-- damage first: a melter within reach wins and the egg waits
	if CONFIG.melters and egg ~= ie then
		local nm = nextMelter(d)
		if nm and cash < nm.costCash + egg.priceCash and egg.priceCash * 4 > nm.costCash then return false end
	end
	local res = invoke("EggHatch", egg.id, 1)
	if type(res) == "table" and res.ok then
		STATE.hatches = STATE.hatches + 1
		if egg == ie then STATE.idxHatches = STATE.idxHatches + 1 end
		return true
	end
	return false
end

local function fusePets()
	local d = data()
	local groups = {}
	for uid, p in pairs(type(d.pets) == "table" and d.pets or {}) do
		local key = tostring(p.id) .. "#" .. tostring(p.tier)
		local g = groups[key]
		if not g then
			g = { id = p.id, tier = tonumber(p.tier) or 1, uids = {} }
			groups[key] = g
		end
		g.uids[#g.uids + 1] = uid
	end
	-- a group holding an enchanted pet is never fused: the server picks which
	-- ones it eats, and the enchant would go with it
	local fused = 0
	for _, g in pairs(groups) do
		local need = Pets.fuseCountFor(g.tier, g.id)
		local enchanted = false
		for _, uid in ipairs(g.uids) do
			if type(d.pets[uid].enchant) == "table" then enchanted = true end
		end
		if need and Pets.TIERS[g.tier + 1] and #g.uids >= need and not enchanted then
			if invoke("PetsFuse", g.uids[1]) ~= nil then
				STATE.fuses = STATE.fuses + 1
				fused = fused + 1
				task.wait(0.5)
				if fused >= 4 then break end
			end
		end
	end
	return fused > 0
end

-- Only when the storage is nearly full, only pets that are not equipped, the
-- weakest first, and never one that could still be fused up.
local function deleteWeak()
	local d = data()
	local storage = tonumber(G.Mult.getMaxPetStorage(d)) or 100
	local count = petCount(d)
	if count < storage - 2 then return false end
	local eq = type(d.equippedPets) == "table" and d.equippedPets or {}
	local same = {}
	for _, p in pairs(d.pets) do
		local key = tostring(p.id) .. "#" .. tostring(p.tier)
		same[key] = (same[key] or 0) + 1
	end
	-- the next tier of a pet the index still lacks is worth keeping fodder for;
	-- those go last, after every pet that is only weak
	local idx = petIndex(d)
	local cands = {}
	for uid, p in pairs(d.pets) do
		local tier = tonumber(p.tier) or 1
		local key = tostring(p.id) .. "#" .. tostring(p.tier)
		local need = Pets.fuseCountFor(tier, p.id)
		local fusable = need and Pets.TIERS[tier + 1] and same[key] >= 2
		local useful = Pets.TIERS[tier + 1] and not idx[tostring(p.id) .. "#" .. (tier + 1)]
		if not eq[uid] and not fusable and type(p.enchant) ~= "table" then
			cands[#cands + 1] = { uid = uid, v = petPower(p), useful = useful and 1 or 0 }
		end
	end
	table.sort(cands, function(a, b)
		if a.useful ~= b.useful then return a.useful < b.useful end
		return a.v < b.v
	end)
	local list = {}
	for i = 1, math.min(#cands, count - (storage - 8)) do list[#list + 1] = cands[i].uid end
	if #list == 0 then return false end
	fire("PetsDelete", list)
	STATE.deleted = STATE.deleted + #list
	return true
end

-- Pack (bag slots, faster pickups) carries the loot runs, Bond the pets that
-- multiply power and cash, Fortune the loot value; Heat only melts ice faster,
-- which nothing here needs.
local BRANCH_ORDER = { Pack = 1, Bond = 2, Fortune = 3, Heat = 4 }
local TALENT_ORDER = {}
for _, t in ipairs(Talents.list) do TALENT_ORDER[#TALENT_ORDER + 1] = t end
table.sort(TALENT_ORDER, function(a, b)
	local ba, bb = BRANCH_ORDER[a.branch] or 9, BRANCH_ORDER[b.branch] or 9
	if ba ~= bb then return ba < bb end
	return (a.order or 0) < (b.order or 0)
end)

local function learnTalents()
	local d = data()
	local ok, left = pcall(Talents.unspent, d)
	if not ok or (tonumber(left) or 0) <= 0 then return false end
	for _, t in ipairs(TALENT_ORDER) do
		local ok2, can = pcall(Talents.canLearn, d, t.id)
		if ok2 and can then
			fire("TalentLearn", t.id)
			STATE.talents = STATE.talents + 1
			task.wait(0.4)
			return true
		end
	end
	return false
end

local POTION_ORDER = { "mega", "power", "cash", "luck" }

-- TOO MUCH LUCK HIDES THE COMMON ITEMS. A rarity tier is rolled with chance
-- 16^-(order-1) x luck, so once segment luck x player luck reaches 16 the
-- uncommon tier takes everything and a common can no longer drop: at luck 15
-- (talents x the luck potion x the mega potion) world 1 segment 1 is luck 30,
-- and the three commons stayed out of the index. Without the two potions it is
-- 7.5. So while a common is missing, those two stay in the inventory.
local function commonMissing(d)
	if not CONFIG.indexItems then return false end
	for _, it in ipairs(Items.list) do
		if it.rarity == "common" and (tonumber(it.world) or 1) <= maxWorld(d) and not itemIndexed(d, it.id) then
			return true
		end
	end
	return false
end

local function usePotions()
	local d = data()
	local pot = type(d.potions) == "table" and d.potions or {}
	local owned = type(pot.owned) == "table" and pot.owned or {}
	local active = type(pot.active) == "table" and pot.active or {}
	local lowLuck = commonMissing(d)
	for _, id in ipairs(POTION_ORDER) do
		if lowLuck and (id == "luck" or id == "mega") then
			-- left for later, see commonMissing
		elseif (tonumber(owned[id]) or 0) > 0 and not active[id] then
			local r = invoke("PotionUse", id)
			if type(r) == "table" and r.ok then
				STATE.potions = STATE.potions + 1
				return true
			end
		end
	end
	return false
end

local function rollAura()
	local A = G.Aura
	if not A then return false end
	local d = data()
	local machine = A.machine(worldNum(d))
	if not machine then return false end
	local win = 0
	pcall(function() win = A.window() end)
	local okSrc, src = pcall(A.rollSource, d, win, machine.price)
	if not okSrc or not src then return false end
	local slot = A.defaultSlot(d)
	local okSlot, entry = pcall(A.slot, d, slot)
	if okSlot and entry and not CONFIG.auraReplace then return false end
	local res = invoke("AuraRoll", slot, false)
	if res ~= nil then
		STATE.auras = STATE.auras + 1
		return true
	end
	return false
end

local lastClaims, freeTried = 0, false
local function claims()
	if os.clock() - lastClaims < 60 then return end
	lastClaims = os.clock()
	local d = data()
	pcall(invoke, "DailyClaim")
	local off = type(d.offline) == "table" and d.offline or {}
	if (tonumber(off.pendingCash) or 0) > 0 or (tonumber(off.pendingPower) or 0) > 0 then invoke("OfflineClaim") end
	for _, kind in ipairs({ "items", "pets" }) do
		for _ = 1, 10 do
			local ok, n = pcall(G.Mult.claimableIndexSteps, data(), kind)
			if not ok or (tonumber(n) or 0) <= 0 then break end
			if invoke("IndexClaim", kind) == nil then break end
			STATE.claims = STATE.claims + 1
			task.wait(0.3)
		end
	end
	if not d.claimedShopFreePet then invoke("ShopFreePetClaim") end
	if not freeTried and not d.claimedFreeReward then
		freeTried = true
		invoke("FreeRewardClaim")
	end
end

local function spend()
	if CONFIG.melters then buyMelter() end
	if CONFIG.upgrades then buyUpgrades() end
	if CONFIG.talents then learnTalents() end
	if CONFIG.potions then usePotions() end
	local changed = false
	if CONFIG.fuse and fusePets() then changed = true end
	if CONFIG.deletePets then deleteWeak() end
	if CONFIG.equipPets and (changed or os.clock() - lastEquip > 20) then
		lastEquip = os.clock()
		fire("PetsEquipBest")
	end
	if CONFIG.auras then rollAura() end
	if CONFIG.claims then claims() end
end

local function tryRebirth()
	local d = data()
	local ok, can = pcall(Rebirths.canRebirth, d)
	if not (ok and can) then return false end
	local before = tonumber(d.rebirths) or 0
	if invoke("RebirthRequest") == true then
		STATE.rebirths = STATE.rebirths + 1
		note("rebirth " .. (before + 1))
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- the loop
--------------------------------------------------------------------------------

local function cycle()
	if not root() then
		STATE.phase = "waiting for the character"
		task.wait(1)
		return
	end
	if not ensureWorld() then task.wait(1) return end
	if CONFIG.unlock and unlockNext() then return end
	if CONFIG.forge then
		forgeTrack()
		if forgeCraft() then return end
	end
	if enchantStep() then return end
	if CONFIG.loot then
		trainHop()
		lootRun()
	elseif CONFIG.train then
		STATE.phase = "training"
		trainHop()
		task.wait(0.5)
	else
		STATE.phase = "idle"
		task.wait(0.5)
	end
	spend()
	if CONFIG.rebirth then tryRebirth() end
end

task.spawn(function()
	while alive() do
		if CONFIG.auto then
			local ok, err = pcall(cycle)
			if not ok then
				STATE.busy = false
				note("error: " .. tostring(err))
				task.wait(1)
			end
		else
			STATE.phase = "off"
			task.wait(0.5)
		end
		task.wait()
	end
end)

-- Hatching works from anywhere and does not move the body, so it has its own
-- loop at the server's pace instead of waiting for a cycle.
task.spawn(function()
	while alive() do
		if CONFIG.auto and (CONFIG.eggs or CONFIG.indexPets) then
			local ok, did = pcall(hatch)
			if ok and did then lastEquip = 0 end
		end
		task.wait(2.1)
	end
end)

-- With no training ice in this world the position does not matter, so the
-- budget is drawn every second from wherever the body is - mid-run included.
task.spawn(function()
	while alive() do
		if CONFIG.auto and CONFIG.train then
			local ok, spot = pcall(bestIce, data())
			if ok and not (CONFIG.trainIce and spot) then pcall(swing) end
		end
		task.wait(0.25)
	end
end)

-- anti-AFK: the game asks the server for a rejoin after 1080 s of Idled
pcall(function()
	local VU = game:GetService("VirtualUser")
	plr.Idled:Connect(function()
		if not alive() or not CONFIG.antiAfk then return end
		pcall(function() VU:CaptureController() VU:ClickButton2(Vector2.new()) end)
	end)
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if ENV.__MELTICE_WIN then pcall(function() ENV.__MELTICE_WIN:Destroy() end) end
if UI.sweep then UI.sweep("SeluxMeltIcePanel") end
UI.config("meltice", CONFIG)

local win = UI.Window({
	name = "SeluxMeltIcePanel", title = "MELT THE", accentTitle = "ICE", subtitle = "seltonmt",
})
ENV.__MELTICE_WIN = win

local statusOut
do
	local page = win:Page("FARM", UI.icon and (UI.icon.pickaxe or UI.icon.target) or nil)
	local run = page:Card("LOOT RUNS", 1):Accent()
	run:Toggle("Loot runs", CONFIG.loot, function(v) CONFIG.loot = v end,
		"picks the most valuable loot of the deepest segments, banks it at base and sells it")
	run:Dropdown("World", { "Auto", "Best loot", "Best ice", "1", "2", "3", "4", "5" }, CONFIG.world,
		function(v) CONFIG.world = v end)
	run:Label("Auto farms the best loot while cash still buys melters or eggs, then moves to the world with your best training ice")
	run:Toggle("Unlock the next world", CONFIG.unlock, function(v) CONFIG.unlock = v end,
		"touches the gate at the end of the field - no power needed")
	run:Slider("Deepest segments searched", 1, 10, CONFIG.segments, function(v) CONFIG.segments = math.floor(v) end,
		"segment 10 holds the best loot; more segments means more to choose from")
	run:Toggle("Potions and books too", CONFIG.extras, function(v) CONFIG.extras = v end,
		"they do not take a backpack slot")
	run:Slider("Studs per hop", 60, 300, CONFIG.step, function(v) CONFIG.step = math.floor(v) end,
		"smaller is gentler, larger is faster")

	local power = page:Card("POWER", 2)
	power:Toggle("Train power", CONFIG.train, function(v) CONFIG.train = v end,
		"the server credits 6 swings a second wherever you stand")
	power:Toggle("Cash swings in on the best ice", CONFIG.trainIce, function(v) CONFIG.trainIce = v end,
		"a hop onto the best unlocked training ice multiplies the whole batch")
	power:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
		"a rebirth only resets power - cash, melters and worlds stay")

	local shop = page:Card("SPENDING", 2)
	shop:Toggle("Buy the best melter", CONFIG.melters, function(v) CONFIG.melters = v end)
	shop:Toggle("Buy upgrades", CONFIG.upgrades, function(v) CONFIG.upgrades = v end,
		"capacity first - it is what a loot run is limited by")
	shop:Toggle("Learn talents", CONFIG.talents, function(v) CONFIG.talents = v end,
		"Pack, then Bond, then Fortune - Heat last")
	shop:Toggle("Drink potions", CONFIG.potions, function(v) CONFIG.potions = v end,
		"mega, power, cash and luck, whenever one is not running")

	statusOut = page:Card("STATUS", 0):Readout(11)
end

do
	local page = win:Page("PETS", UI.icon and (UI.icon.star or UI.icon.spark) or nil)
	local pets = page:Card("PETS", 1):Accent()
	pets:Toggle("Hatch the best egg", CONFIG.eggs, function(v) CONFIG.eggs = v end,
		"the egg of your best world; it waits while a melter is within reach")
	pets:Toggle("Fuse pets", CONFIG.fuse, function(v) CONFIG.fuse = v end,
		"5 of a pet make a Golden one, 3 Golden a Rainbow")
	pets:Toggle("Equip the best pets", CONFIG.equipPets, function(v) CONFIG.equipPets = v end)
	pets:Toggle("Delete the weakest pets when storage is full", CONFIG.deletePets,
		function(v) CONFIG.deletePets = v end,
		"never an equipped pet and never one that can still be fused", UI.theme and UI.theme.warn)

	local extra = page:Card("AURAS AND REWARDS", 2)
	extra:Toggle("Roll auras into empty slots", CONFIG.auras, function(v) CONFIG.auras = v end)
	extra:Toggle("Keep rolling when the slots are full", CONFIG.auraReplace,
		function(v) CONFIG.auraReplace = v end,
		"a new aura replaces your weakest one, even if it is worse", UI.theme and UI.theme.warn)
	extra:Toggle("Claim rewards", CONFIG.claims, function(v) CONFIG.claims = v end,
		"daily, index, offline earnings and the free shop pet")
	extra:Toggle("Anti-AFK", CONFIG.antiAfk, function(v) CONFIG.antiAfk = v end)
end

do
	local page = win:Page("BOOSTS", UI.icon and (UI.icon.bolt or UI.icon.flask) or nil)
	local forge = page:Card("FORGE AND ENCHANTS", 1):Accent()
	forge:Toggle("Forge runes", CONFIG.forge, function(v) CONFIG.forge = v end,
		"keeps the recipe items and crafts the runes, power first - one star of Magma Power took power from x1 to x4.6")
	forge:Toggle("Enchant the equipped pets", CONFIG.enchant, function(v) CONFIG.enchant = v end,
		"rolls your books at the world 5 stand until each pet has the goal")
	forge:Dropdown("Enchant goal", { "Strong V", "Inferno" }, CONFIG.enchantGoal,
		function(v) CONFIG.enchantGoal = v end)
	forge:Label("Strong V: +100% of that pet's power, about 1 roll in 100. Inferno: +150% power and cash, about 1 in 500")

	local index = page:Card("INDEX", 2)
	index:Toggle("Complete the item index", CONFIG.indexItems, function(v) CONFIG.indexItems = v end,
		"picks one of every item you have not found yet - +15% cash per 10 items")
	index:Toggle("Complete the pet index", CONFIG.indexPets, function(v) CONFIG.indexPets = v end,
		"hatches every egg until each pet is found in all three tiers - +10% power per 5")
end

win:Home()
pcall(function()
	win:SetMaster(CONFIG.auto, "Auto farm running")
	win:OnMaster(function(on) CONFIG.auto = on end)
end)

task.spawn(function()
	while alive() do
		pcall(function()
			local d = data()
			local lvl, need = 0, 0
			pcall(function() lvl, need = Rebirths.currentLevel(d), Rebirths.requiredLevel(d) end)
			local elapsed = math.max(1, os.clock() - STATE.started)
			local m = Melters.fromId[d.equippedMelter]
			statusOut:set({
				"phase     " .. STATE.phase,
				string.format("world     %d of %d unlocked   %s", worldNum(d), maxWorld(d), tostring(STATE.why or "-")),
				string.format("cash      %s   earned %s   %s/s", fmt(d.cash), fmt(STATE.earned), fmt(STATE.earned / elapsed)),
				string.format("runs      %d   items %d   extras %d   last sale %s   last run %.1fs", STATE.runs, STATE.items, STATE.extras, fmt(STATE.lastSale), STATE.lastRun),
				string.format("power     %s   level %d / %d   +%s per batch", fmt(d.power), lvl, need, fmt(STATE.power)),
				string.format("rebirths  %d   this session %d   ice %s", tonumber(d.rebirths) or 0, STATE.rebirths, STATE.ice),
				string.format("melter    %s   bought %d   upgrades %d   talents %d", m and m.name or tostring(d.equippedMelter), STATE.melters, STATE.upgrades, STATE.talents),
				string.format("pets      %d   hatched %d   fused %d   deleted %d   auras %d   potions %d", petCount(d), STATE.hatches, STATE.fuses, STATE.deleted, STATE.auras, STATE.potions),
				string.format("forge     %s   crafted %d   power x%s   enchant rolls %d   goals met %d", tostring(STATE.forgeName or "-"), STATE.forged, fmt(G.Mult.getForgePowerMult and G.Mult.getForgePowerMult(d) or 1), STATE.enchRolls, STATE.enchanted),
				string.format("index     items %d / %d   pets %d   this session +%d items, %d index hatches", idxCount(d.index and d.index.items), #Items.list, idxCount(petIndex(d)), STATE.idxItems, STATE.idxHatches),
				"note      " .. STATE.note,
			})
			win:SetStat(1, fmt(d.cash), "cash")
			win:SetStat(2, fmt(d.power), "power")
			win:SetStat(3, tostring(tonumber(d.rebirths) or 0), "rebirths")
		end)
		task.wait(0.5)
	end
end)

ENV.__MELTICE_DBG = {
	CONFIG = CONFIG, STATE = STATE, G = G,
	lootRun = lootRun, trainHop = trainHop, swing = swing, unlockNext = unlockNext,
	ensureWorld = ensureWorld, spend = spend, buyMelter = buyMelter, buyUpgrades = buyUpgrades,
	hatch = hatch, fusePets = fusePets, deleteWeak = deleteWeak, learnTalents = learnTalents,
	usePotions = usePotions, rollAura = rollAura, claims = claims, tryRebirth = tryRebirth,
	bestIce = bestIce, bestEgg = bestEgg,
	forgeTarget = forgeTarget, forgeNeed = forgeNeed, forgeCraft = forgeCraft, forgeTrack = forgeTrack,
	enchantStep = enchantStep, indexEgg = indexEgg, indexWorld = indexWorld, targetWorld = targetWorld,
}

print("[selux meltice] gen " .. GEN .. " ready - RightShift for the panel")
