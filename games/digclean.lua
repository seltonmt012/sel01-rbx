--!nocheck
-- digclean.lua  --  "[UPD] Dig & Clean 🧼"  (place 83038462357724)
--
-- Loop: a detector reveals buried nodes in a dig area, you dig one out, spray it
-- clean, and then either sell it or put it on a pedestal in your museum where
-- tourists pay for it. Gold buys better shovels, sprays and detectors.
--
-- The game is roblox-ts with a proper network layer, so nothing here had to be
-- captured off the wire: `PlayerScripts.TS.network.<X>Network` exports typed
-- client wrappers and every remote is named in plain English.
--
--   local Items = require(plr.PlayerScripts.TS.network.ItemsNetwork)
--   Items.ItemsFunctions.beginCleaning:invoke(uid)   -- promise, :expect()
--   Items.ItemsEvents.finishCleaning:fire(uid)
--
-- Measured, all of it, against DataFunctions.requestDataUpdate (the state oracle
-- - Gold, Level, Xp, Inventory, Owned*, Equipped*, UnlockedIslands, ItemsDug):
--
--   * Dig: DigController:attemptDig() then :onDigInput() per click. One node took
--     5.2s at 11 clicks/s. DiggingConfig.DIG_MAX_CLICKS_PER_SECOND is 50, so the
--     rate here is well inside it.
--   * Clean: beginCleaning(uid) then finishCleaning(uid) 0.35s later finishes the
--     item in 2.0s and SKIPS the spray minigame outright.
--   * Sell: sellInventory() answered 474 gold for one item.
--   * Museum: a single Duck on pedestal 1 carried Gold 174 -> 2472 while one dig
--     was running. Tourists pay for what is on display, so the best finds stay.
--
-- Three server-side PROXIMITY rules, each of which fails as a silent `false`
-- rather than an error - that is what makes them expensive to find:
--   * buyGear(category, id) - positional, category "shovel", only at the GearNPC
--   * sellInventory()       - only at the SellerNPC
--   * placeItem(slot, uid)  - only on your own plot
--
-- And the gate that costs a whole evening if it is missed: **no buried node ever
-- spawns until the tutorial is finished**. GetTutorialState().step has to read 11.
-- Step 3 is "Click anywhere to start digging" and mouse1click() does not satisfy
-- it - the click has to go through the controller's own handler.
--
-- No anti-cheat exists in this game: no warning event, no audit flags, no
-- position validation. The only limiter is TS.utils.security.RateLimit and the
-- click ceiling above. Nothing here needs to fight anything.
--
-- Never touched, all Robux: the gamepass shop, ForeverPack/StarterPack/ExpertPack,
-- SkipPolishTiers, ItemRecovery, gifts and every `setGearPurchaseIntent` prompt.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")

local plr = Players.LocalPlayer

local Const = ReplicatedStorage.TS.constants
local CfgShovels = require(Const.digging.Shovels)
local CfgDig = require(Const.digging.DiggingConfig)
local CfgSprays = require(Const.cleaning.SprayBottles)
local CfgDetectors = require(Const.digging.Detectors)
local CfgItems = require(Const.items.Items)
local CfgBackpack = require(Const.inventory.BackpackCapacity)

--------------------------------------------------------------------------------
-- config / state
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,
	dig = true,
	clean = true,
	sell = true,
	display = true,       -- keep the best finds on museum pedestals
	polish = true,        -- raise item condition in the polishers
	plot = true,          -- unlock sections, polishers and upstairs pedestals
	islands = true,       -- unlock and move to the highest-luck island
	islandFirst = true,   -- hold gold back from gear once an island is in reach
	buyGear = true,
	claimFree = true,     -- offline earnings, forever pack, codes
	moveSpeed = 90,       -- studs/s for the tween hops; the game does not check it
	-- Progress is clickPower per click against a per-second decay, and both come
	-- out of digDifficultyFor(itemId, kg, shovelPower). An epic needs roughly 7.5
	-- clicks a second just to break even, an anomaly about 30. Clicking near the
	-- game's own ceiling of 50 is therefore the difference between "needs a better
	-- shovel" and getting the thing out of the ground.
	clicksPerSec = 35,    -- DIG_MAX_CLICKS_PER_SECOND is 50
	scan = true,          -- sweep the area before choosing what to dig
	scanPoints = 4,       -- hops per sweep
	scanDwell = 0.45,     -- pause at each hop; the stream ticks every 0.4s
	scanUntil = 6,        -- sweep while fewer than this many nodes are known
	scanEvery = 25,       -- and at most this often when the field is merely dull
	scanRarity = 3,       -- ...or while the best known node is below this rarity
	-- What the shovel can actually lift out of the ground, rather than a fixed
	-- rarity floor. See "what a find costs in clicks" below: with a plastic shovel
	-- everything above common is literally impossible, so "rarest first" spent the
	-- opening hour stalling on nodes it could never finish.
	rarityAuto = true,    -- rank nodes by gold per second for the equipped shovel
	-- Not a "keep it snappy" number: the RANKING is gold per second, so a slow find
	-- that pays is still the right pick (plastic shovel, measured: common 1.8s for
	-- 175 gold = 97/s, uncommon 4.4s for 714 = 162/s, rare 16.0s for 4072 = 254/s).
	-- This is only the wall that keeps a dig from eating a whole session.
	digSeconds = 25,      -- refuse a node predicted to take longer than this
	clickBudget = 0,      -- 0 = start from the click rate itself; measured from there
	probeEvery = 12,      -- every N digs, allow one slow node through anyway
	giveUpAfter = 4,      -- seconds without progress before abandoning a dig
	sellAt = 0.3,         -- sell once the backpack is this full
	gearEvery = 30,       -- seconds between gear-shopping trips
	swapExhibits = true,  -- replace the weakest exhibit when a better find turns up
	swapMargin = 1.2,     -- how much better it has to be before evicting one
}

local STATE = {
	note = "idle",
	phase = "-",
	gold = 0,
	level = 0,
	xp = 0,
	dug = 0,
	cleaned = 0,
	sold = 0,
	digs = 0,
	nodes = 0,
	power = 1,            -- power of the equipped shovel
	cps = 8,              -- learned click budget: clicks/s this setup really lands
	cap = "-",            -- best rarity that budget currently covers
	lastRarity = "-",
	goldRate = 0,
	lastGold = 0,
	lastGoldAt = 0,
	tutorial = -1,
	busy = false,
	nextGearAt = 0,
	gear = "-",
	island = "-",
}

_G.__DIGCLEAN = (_G.__DIGCLEAN or 0) + 1
local GEN = _G.__DIGCLEAN

--------------------------------------------------------------------------------
-- network
--------------------------------------------------------------------------------

local netFolder = plr:WaitForChild("PlayerScripts", 10):WaitForChild("TS", 10):WaitForChild("network", 10)
local netCache = {}
local function net(name)
	if not netCache[name] then netCache[name] = require(netFolder[name]) end
	return netCache[name]
end

-- Every "Function" here is a promise-returning invoke. `:expect()` raises on a
-- rejected promise, so it always travels inside a pcall.
local function invoke(modName, group, fn, ...)
	local args = table.pack(...)
	local ok, res = pcall(function()
		local m = net(modName)[group][fn]
		local p = m:invoke(table.unpack(args, 1, args.n))
		if p and p.expect then return p:expect() end
		return p
	end)
	return ok, res
end

local function fire(modName, group, ev, ...)
	local args = table.pack(...)
	pcall(function()
		net(modName)[group][ev]:fire(table.unpack(args, 1, args.n))
	end)
end

local function data()
	local ok, d = invoke("DataNetwork", "DataFunctions", "requestDataUpdate")
	return ok and type(d) == "table" and d or nil
end

local function tutorialStep()
	local ok, s = invoke("TutorialNetwork", "TutorialFunctions", "GetTutorialState")
	return ok and type(s) == "table" and s.step or -1
end

--------------------------------------------------------------------------------
-- movement
--------------------------------------------------------------------------------

-- Defined up here, not down with the panel: a local is invisible above its own
-- definition, and the plot routines below format prices with it.
local function short(n)
	if type(n) ~= "number" then return "?" end
	local units = { "", "K", "M", "B", "T", "Qa", "Qi" }
	local i = 1
	while n >= 1000 and i < #units do n = n / 1000 i = i + 1 end
	if i == 1 then return string.format("%d", n) end
	return string.format("%.2f%s", n, units[i])
end

local function char()
	local c = plr.Character
	if not c then return nil end
	return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end

-- A linear tween rather than a CFrame snap. Nothing in this game checks it, but a
-- warp reads as a warp to the other players standing around and costs nothing to
-- avoid.
local function hop(goal, extraWait)
	local _, hrp = char()
	if not hrp or not goal then return false end
	local dist = (goal - hrp.Position).Magnitude
	if dist < 4 then return true end
	local dur = math.max(dist / math.max(CONFIG.moveSpeed, 10), 0.1)
	TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Linear),
		{ CFrame = CFrame.new(goal) }):Play()
	task.wait(dur + (extraWait or 0.4))
	return true
end

--------------------------------------------------------------------------------
-- the world
--------------------------------------------------------------------------------

-- The workspace folder is named "Shipwreck Cove" while the data calls the island
-- "island2", so the two have to be matched through getIslands, which carries both.
local function islandNameFor(id)
	if not _G.__DC_ISLE_NAMES then
		local ok, list = invoke("TravelNetwork", "TravelFunctions", "getIslands")
		local map = {}
		if ok and type(list) == "table" then
			for _, entry in ipairs(list) do
				if entry.id and entry.name then map[entry.id] = entry.name end
			end
		end
		_G.__DC_ISLE_NAMES = map
	end
	return _G.__DC_ISLE_NAMES[id]
end

-- Resolved from Data.CurrentIsland, NOT from whichever island happens to be
-- nearest. The museum plot sits on the starter island for everyone, so as soon as
-- the farm walked over to display something it "was" on Home Beach again - and
-- then bought gear from the Home Beach shop, where the whole island2 ladder does
-- not exist. Gold piled to 1.1M with a titanium shovel, an onyx detector and a
-- turquoise spray all affordable and none of them bought.
local function islandFolder()
	local islands = Workspace:FindFirstChild("Islands")
	if not islands then return nil end
	local d = data()
	local name = d and islandNameFor(d.CurrentIsland)
	local folder = name and islands:FindFirstChild(name)
	if folder then return folder end
	return islands:GetChildren()[1]
end

-- Nearest tagged instance, optionally restricted to a container. The restriction
-- is the whole point: dig zones exist on every island, and taking the globally
-- nearest one meant that standing at the museum - which is always on the starter
-- island - sent the farm back to Home Beach to dig at luck x1 while a paid-for
-- island2 sat unused at luck x2.
local function nearestTagged(tag, container)
	local _, hrp = char()
	if not hrp then return nil end
	local best, bestDist
	for _, z in ipairs(CollectionService:GetTagged(tag)) do
		if not container or z:IsDescendantOf(container) then
			local ok, pivot = pcall(function() return z:GetPivot() end)
			if ok then
				local dist = (pivot.Position - hrp.Position).Magnitude
				if not bestDist or dist < bestDist then best, bestDist = z, dist end
			end
		end
	end
	return best, bestDist
end

local function npcNamed(name)
	local isl = islandFolder()
	local npcs = isl and isl:FindFirstChild("NPCs")
	if not npcs then return nil end
	local found = npcs:FindFirstChild(name, true)
	if not found then return nil end
	local ok, pivot = pcall(function() return found:GetPivot() end)
	return ok and pivot.Position or nil
end

--------------------------------------------------------------------------------
-- buried nodes
--------------------------------------------------------------------------------

-- The connection lives in _G and is disconnected before reconnecting. A boolean
-- "already hooked" guard breaks on re-execute: the old run's listener survives and
-- keeps writing into the previous script's table while the new one sees nothing.
-- The server only streams the nodes within detector range, so a character standing
-- still sees one or two of the island's eleven. Replacing the list on every stream
-- threw away everything the last position had revealed; this MERGES by id and
-- keeps a timestamp instead, so a sweep across the area builds up a picture of the
-- whole field and the rarest of it can be chosen rather than whatever is underfoot.
-- BURIED_LIFETIME_MAX is 120, but that is the node's own life from ITS spawn, not
-- from when we first saw it - and another player can dig it out from under us at
-- any time. Remembering sightings for anything near 120s filled the map with
-- ghosts, and because the picker prefers rare ones it locked onto a dead epic and
-- burned a 20-second dig timeout on it over and over while nothing was dug at all.
-- A short memory keeps the choice wide without keeping the corpses.
local NODE_TTL = 25
local function armNodeListener()
	if _G.__DC_NODECONN then pcall(function() _G.__DC_NODECONN:Disconnect() end) end
	_G.__DC_SEEN = _G.__DC_SEEN or {}
	local ok, conn = pcall(function()
		return net("DetectorNetwork").DetectorEvents.BuriedNodes:connect(function(nodes)
			if type(nodes) ~= "table" then return end
			local now = os.clock()
			for _, n in ipairs(nodes) do
				if n.id and typeof(n.position) == "Vector3" then
					local kept = _G.__DC_SEEN[n.id]
					_G.__DC_SEEN[n.id] = {
						id = n.id, position = n.position, rarity = n.rarity,
						-- first sighting wins for ageing: the node dies 120s after IT
						-- spawned, not 120s after we last happened to walk past it
						seenAt = kept and kept.seenAt or now,
						-- ...but lastSeen tracks every stream, which is what tells us
						-- the server still considers it there right now
						lastSeen = now,
					}
				end
			end
		end)
	end)
	if ok then _G.__DC_NODECONN = conn end
end

local function forgetNode(id)
	if id and _G.__DC_SEEN then _G.__DC_SEEN[id] = nil end
end

local RARITY = {}
do
	local order = CfgItems.RARITY_ORDER
	if type(order) == "table" then
		for i, name in ipairs(order) do RARITY[name] = i end
	end
end

--------------------------------------------------------------------------------
-- what a find costs in seconds
--------------------------------------------------------------------------------

-- A dig is a race between `clickPower` per counted click and a `decay` per second,
-- and both come out of DiggingConfig.digDifficultyFor(itemId, kg, shovelPower). The
-- bar starts at DIG_PROGRESS_START and has to reach DIG_WIN_THRESHOLD, so with a
-- click rate of `cps` the whole thing collapses to one number per rarity:
--
--   seconds = (0.985 - 0.33) / (clickPower * cps - decay)
--
-- and if that denominator is not positive the find is simply out of reach. Measured
-- off the game's own config (median item of each band at its averageKg), the
-- break-even click rate decay/clickPower reads:
--
--   shovel      common uncommon rare  epic  legend mythic divine+
--   plastic p1    4.0     16.5  27.1  38.5   51.2   61.9   80.6
--   metal   p5    1.0      1.3   2.5  13.3   27.1   31.7   39.1
--   titanium p14  0.8      0.8   1.3   2.8    7.9   17.4   24.6
--   diamond p40   0.8      0.8   0.8   1.2    1.4    1.7    5.6
--
-- Which is why "rarest first" is right with a diamond shovel and ruinous with a
-- plastic one, and why "possible" is not the same question as "worth it": at 35
-- clicks a second a plastic shovel CAN take a rare, and a measured run spent the
-- whole 20-second dig timeout doing it and came away with one item in 105 seconds.
-- So the picker below ranks on gold per second - the band's median value against
-- its predicted dig time plus the walk - and refuses anything predicted slower than
-- CONFIG.digSeconds. That is the part that follows the shovel.
local DIG_SPAN = (CfgDig.DIG_WIN_THRESHOLD or 0.985) - (CfgDig.DIG_PROGRESS_START or 0.33)

local function rarityStats(power)
	local key = string.format("%.3f", power or 1)
	-- the cache carries its own name per SHAPE, not just per power: a re-execute
	-- keeps _G, so an older build's table (which held a bare number per rarity)
	-- was still sitting there and every read indexed a number
	_G.__DC_STATS2 = _G.__DC_STATS2 or {}
	if _G.__DC_STATS2[key] then return _G.__DC_STATS2[key] end
	local out = {}
	for _, rarity in ipairs(CfgItems.RARITY_ORDER or {}) do
		local powers, decays, values = {}, {}, {}
		for id, item in pairs(CfgItems.Items or {}) do
			if item.rarity == rarity then
				local ok, diff = pcall(CfgDig.digDifficultyFor, id, item.averageKg, power)
				if ok and type(diff) == "table" and (diff.clickPower or 0) > 0 then
					powers[#powers + 1] = diff.clickPower
					decays[#decays + 1] = diff.decay or 0
				end
				-- itemValueFor is (id, condition, kg) and answers `false` on a bad
				-- call rather than raising, so the guard is a type check, not a pcall
				local okv, value = pcall(CfgItems.itemValueFor, id, "ok", item.averageKg)
				if okv and type(value) == "number" then values[#values + 1] = value end
			end
		end
		-- the MEDIAN of each band, never its worst member: one very heavy item would
		-- otherwise write off a rarity that is mostly diggable (epic at power 5
		-- spreads 7.7 to 21.2 break-even clicks, legendary at 14 spreads 3.8 to 9.6)
		local function mid(t)
			table.sort(t)
			return t[math.ceil(#t / 2)]
		end
		out[rarity] = {
			clickPower = mid(powers) or 0,
			decay = mid(decays) or math.huge,
			value = mid(values) or 0,
		}
		out[rarity].cost = out[rarity].clickPower > 0
			and (out[rarity].decay / out[rarity].clickPower) or math.huge
	end
	_G.__DC_STATS2[key] = out
	return out
end

-- The click rate the SERVER counts is learned, not assumed: the loop fires
-- CONFIG.clicksPerSec of them, but bursts, latency and the server's own accounting
-- decide how many land, and nothing client-side reports it. Every dig that moves
-- the bar measures it exactly - progress per second, plus the decay it had to
-- overcome, divided by the click power - so one dig is enough to calibrate and each
-- later one refines it.
--
-- MEASURED: firing 35 a second, the bar moves as if 11.9 were counted, which is
-- DiggingConfig.DIG_EFFECTIVE_CLICKS_PER_SECOND (11) almost exactly. So that is the
-- opening guess, not the nominal rate - starting at 35 cost three lost digs of
-- calibration while it walked to rares it could never finish. The learned value
-- survives a re-execute in _G, because it belongs to this machine and connection
-- rather than to the shovel.
STATE.cps = tonumber(_G.__DC_CPS)
	or (CONFIG.clickBudget > 0 and CONFIG.clickBudget)
	or tonumber(CfgDig.DIG_EFFECTIVE_CLICKS_PER_SECOND)
	or 11

local function rarityOf(node)
	local stats = rarityStats(STATE.power)
	return node and stats[node.rarity] or nil
end

-- Predicted seconds to take this node out of the ground, math.huge when the decay
-- eats the clicks and the bar would never fill.
local function digSeconds(node)
	local s = rarityOf(node)
	if not s or s.clickPower <= 0 then return math.huge end
	local rate = s.clickPower * STATE.cps - s.decay
	if rate <= 0 then return math.huge end
	return DIG_SPAN / rate
end

local function digLimit()
	-- one dig in probeEvery is deliberately allowed to be slow: it is how a
	-- pessimistic estimate, a fresh shovel or a better connection gets noticed
	-- without waiting for the whole ladder to be re-derived
	return CONFIG.digSeconds * (STATE.probe and 2.5 or 1)
end

-- Highest rarity the current shovel and measured click rate can take inside the
-- time limit - what the panel calls the ceiling and what the sweep holds out for.
local function capIndex()
	local best = 1
	for i, rarity in ipairs(CfgItems.RARITY_ORDER or {}) do
		if digSeconds({ rarity = rarity }) <= CONFIG.digSeconds then best = i end
	end
	return best
end

-- Progress per second is the direct measurement of the counted click rate:
--   progressRate = clickPower * cps - decay   ->   cps = (rate + decay) / clickPower
-- An EMA rather than a replacement, because a single dig carries the server's
-- rounding and whatever the connection did during those five seconds.
-- `gained` is signed on purpose. A dig that LOSES ground is the most informative
-- sample there is: it says the counted click rate is under the break-even for this
-- band, and reading only the rises is what let a plastic shovel keep picking rares
-- whose bar fell from 33% to 28% and ended as a server-side loss - 0 digs in 103
-- seconds, with the model still insisting on 35 clicks a second.
local function learnRate(node, gained, seconds)
	local s = rarityOf(node)
	if not s or s.clickPower <= 0 then return end
	if type(gained) ~= "number" or seconds < 1.2 then return end
	local measured = (gained / seconds + s.decay) / s.clickPower
	if measured ~= measured then return end
	measured = math.max(measured, 0.5)
	STATE.cps = math.max(STATE.cps * 0.6 + measured * 0.4, 0.5)
	_G.__DC_CPS = STATE.cps
end

-- A stall is the other half of the measurement: the bar did not move at all, so
-- whatever the model said, this band is out of reach right now.
local function learnStall(node)
	local s = rarityOf(node)
	if not s or s.clickPower <= 0 then return end
	local ceiling = s.decay / s.clickPower
	if ceiling <= 0 or ceiling == math.huge then return end
	if STATE.cps > ceiling then
		STATE.cps = math.max(ceiling * 0.9, 1)
		_G.__DC_CPS = STATE.cps
	end
end

-- The shovel's power is what every cost above is computed from, so it is read off
-- the data oracle rather than guessed from the tool in hand: a purchase equips a
-- new shovel mid-cycle and the whole ladder has to move with it.
local function refreshShovel(d)
	local id = d and d.EquippedShovel or CfgShovels.DEFAULT_SHOVEL_ID
	local entry = CfgShovels.Shovels and CfgShovels.Shovels[id]
	STATE.power = tonumber(entry and entry.power) or 1
	local order = CfgItems.RARITY_ORDER or {}
	local idx = capIndex()
	local secs = digSeconds({ rarity = order[idx] })
	STATE.cap = string.format("%s in %.1fs  (p%s, %.0f counted clicks/s)",
		tostring(order[idx] or "?"), secs, tostring(STATE.power), STATE.cps)
end

local function nodeList()
	local seen = _G.__DC_SEEN
	if type(seen) ~= "table" then return {} end
	local now = os.clock()
	local out = {}
	for id, n in pairs(seen) do
		if now - (n.seenAt or 0) > NODE_TTL then
			seen[id] = nil
		else
			out[#out + 1] = n
		end
	end
	return out
end

-- Walks a short pattern across the dig area so the detector streams the nodes it
-- cannot see from one spot. The whole sweep is a handful of hops at move speed,
-- which is cheap next to a 5-second dig - and it is what turns "one node visible"
-- into a choice between several, which is the only way to steer towards rarer
-- drops without buying luck.
local function sweepArea(zone, points)
	if not zone or not zone:IsA("BasePart") then return end
	STATE.phase = "scan"
	local halfX, halfZ = zone.Size.X / 2, zone.Size.Z / 2
	local spots = {}
	local n = points or 4
	for i = 1, n do
		-- a rotating lattice rather than a fixed grid, so repeated sweeps do not
		-- keep re-walking the exact same four corners
		local angle = (i / n) * math.pi * 2 + (STATE.sweepPhase or 0)
		spots[#spots + 1] = (zone.CFrame * CFrame.new(
			math.cos(angle) * halfX * 0.65, 0, math.sin(angle) * halfZ * 0.65)).Position
			+ Vector3.new(0, 4, 0)
	end
	STATE.sweepPhase = ((STATE.sweepPhase or 0) + 0.7) % (math.pi * 2)
	for _, p in ipairs(spots) do
		if not CONFIG.auto or GEN ~= _G.__DIGCLEAN then return end
		hop(p, 0.15)
		task.wait(CONFIG.scanDwell)
	end
	STATE.nodes = #nodeList()
end

-- Rarest first, and among equals the nearest - but only among the nodes the
-- current shovel can finish. Walking past a legendary to dig a common costs value;
-- walking to a legendary a plastic shovel cannot move costs four seconds and
-- yields nothing, and that is the worse trade at the start of a save.
-- Second return value is true when nothing on the field was affordable and the
-- cheapest node was taken anyway: standing still measures nothing, and the outcome
-- of that dig is what corrects the budget.
local function pickNode()
	local _, hrp = char()
	if not hrp then return nil end
	local limit = digLimit()
	local speed = math.max(CONFIG.moveSpeed, 1)
	local best, bestScore, reach, reachSecs
	for _, n in ipairs(nodeList()) do
		if typeof(n.position) == "Vector3" then
			local dist = (n.position - hrp.Position).Magnitude
			if not CONFIG.rarityAuto then
				-- manual mode is the old rule: rarest first, nearest among equals
				local score = (RARITY[n.rarity] or 1) * 10000 - dist
				if not bestScore or score > bestScore then best, bestScore = n, score end
			else
				local secs = digSeconds(n)
				local stats = rarityOf(n)
				-- the walk is part of the price of a find, which is what stops the
				-- picker crossing the whole beach for a node worth a fraction more
				local total = secs + dist / speed + 1.5
				local score = ((stats and stats.value) or 0) / total
				if secs <= limit then
					if not bestScore or score > bestScore then best, bestScore = n, score end
				elseif not reachSecs or secs < reachSecs then
					reach, reachSecs = n, secs
				end
			end
		end
	end
	if best then return best, false end
	return reach, reach ~= nil
end

--------------------------------------------------------------------------------
-- the dig controller
--------------------------------------------------------------------------------

-- The click handler lives on a live controller instance, not on the module. The
-- instance is found by matching its metatable against the exported class, and it
-- is re-found whenever it goes stale (a respawn replaces it).
local DigClass
do
	local ctrl = plr.PlayerScripts.TS:FindFirstChild("controllers")
	local mod = ctrl and ctrl:FindFirstChild("DigController", true)
	if mod then
		local ok, m = pcall(require, mod)
		if ok and type(m) == "table" then DigClass = m.DigController end
	end
end

local function digController()
	local cached = _G.__DC_DIG
	if cached and getmetatable(cached) == DigClass then return cached end
	if not DigClass then return nil end
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and getmetatable(t) == DigClass then
			_G.__DC_DIG = t
			return t
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- actions
--------------------------------------------------------------------------------

-- Standing at the GearNPC opens its panel, and buying through the remote never
-- closes it again - the shop then sits over the whole screen while the farm keeps
-- running behind it. Fire the panel's own Close button rather than just hiding the
-- frame, so the controller's state goes back with it.
local function closeModals()
	local main = plr.PlayerGui:FindFirstChild("Main")
	if not main then return end
	for _, frame in ipairs(main:GetChildren()) do
		if frame:IsA("GuiObject") and frame.Visible then
			local closed = false
			local button = frame:FindFirstChild("Close", true)
			if button and (button:IsA("ImageButton") or button:IsA("TextButton")) then
				for _, conn in ipairs(getconnections(button.Activated)) do
					pcall(function() conn:Fire() end)
					closed = true
				end
			end
			if not closed then frame.Visible = false end
		end
	end
end

local function backpackTools()
	local out = {}
	for _, t in ipairs(plr.Backpack:GetChildren()) do
		if t:IsA("Tool") then out[#out + 1] = t end
	end
	local c = plr.Character
	if c then
		for _, t in ipairs(c:GetChildren()) do
			if t:IsA("Tool") then out[#out + 1] = t end
		end
	end
	return out
end

local function doDig()
	local ctrl = digController()
	if not ctrl then STATE.note = "no dig controller" return false end

	-- Standing INSIDE a dig area is what makes the server scan for nodes at all,
	-- and the old check only walked when further than 60 studs. Sitting 33 studs
	-- away - just outside the area, right next to it - left the detector held and
	-- the node list permanently empty, which reads as "the farm stopped finding
	-- anything" while everything else looks healthy.
	local zone, zoneDist = nearestTagged("DigZone", islandFolder())
	if zone then
		local inside = false
		if zone:IsA("BasePart") then
			local local_ = zone.CFrame:PointToObjectSpace(select(2, char()).Position)
			inside = math.abs(local_.X) <= zone.Size.X / 2
				and math.abs(local_.Z) <= zone.Size.Z / 2
		end
		if not inside then
			STATE.phase = "walk to dig area"
			local ok, pivot = pcall(function() return zone:GetPivot() end)
			if ok then hop(pivot.Position + Vector3.new(0, 5, 0)) end
			task.wait(0.6)
		end
	end

	fire("DetectorNetwork", "DetectorEvents", "SetDetectorHeld", true)

	-- Sweep first, then choose. Digging whatever is underfoot means the rarity of
	-- every find is pure luck; sweeping first turns it into a pick from the field.
	-- Sweep when the field is thin, or occasionally when everything known is
	-- mediocre - but NOT every cycle. The first version swept whenever the best
	-- node was below rare, and on a field of thirty commons that is always true, so
	-- it spent its whole life walking in circles over ground it had already
	-- uncovered instead of digging what it had found.
	-- One dig in `probeEvery` is allowed to be slow, so a shovel upgrade or a
	-- pessimistic estimate is noticed by measurement instead of by assumption.
	STATE.probe = CONFIG.rarityAuto and CONFIG.probeEvery > 0
		and ((STATE.digs + (STATE.tooHard or 0)) % CONFIG.probeEvery == 0)

	local node, stretched = pickNode()
	local known = #nodeList()
	local thin = known < CONFIG.scanUntil or not node
	-- The sweep target follows the shovel too. A fixed "hold out for rare" made the
	-- opening hour walk in circles on a field whose rares were unreachable anyway,
	-- and it stopped sweeping long before a diamond shovel had any reason to settle
	-- for an epic. `capIndex()` is the best band the current setup actually covers.
	local target = CONFIG.rarityAuto and capIndex() or CONFIG.scanRarity
	local mediocre = stretched or (node and (RARITY[node.rarity] or 1) < target)
	local cooled = os.clock() >= (STATE.nextScanAt or 0)
	if CONFIG.scan and (thin or (mediocre and cooled)) then
		STATE.nextScanAt = os.clock() + CONFIG.scanEvery
		sweepArea(zone, CONFIG.scanPoints)
		node, stretched = pickNode()
	end
	if not node then
		-- A toggle forces a fresh stream; without it the list can stay empty after
		-- the last node of a batch was dug.
		fire("DetectorNetwork", "DetectorEvents", "SetDetectorHeld", false)
		task.wait(0.3)
		fire("DetectorNetwork", "DetectorEvents", "SetDetectorHeld", true)
		task.wait(1.5)
		node, stretched = pickNode()
	end
	if not node then STATE.note = "no buried nodes" return false end

	local predicted = digSeconds(node)
	STATE.nodes = #nodeList()
	STATE.lastRarity = tostring(node.rarity)
	STATE.phase = string.format("dig %s (~%.0fs)", tostring(node.rarity),
		predicted == math.huge and 99 or predicted)
	hop(node.position + Vector3.new(0, 3, 0), 0.8)

	-- Standing on a remembered position is not the same as the detector having the
	-- node right now: the stream runs every 0.4s (DETECTOR_STREAM_INTERVAL) and
	-- attemptDig only bites on something currently detected. Waiting two ticks and
	-- then checking the node is still being streamed is what separates "it is
	-- there" from "it was there when we saw it", and it is why so many picks came
	-- back as stale after a hop across the beach.
	-- Give the stream two ticks to re-acquire, but do NOT refuse to dig on the
	-- strength of that alone: requiring a fresh sighting after every hop rejected
	-- every single node and the farm dug nothing at all. The cheap 1.6s
	-- start-timeout below is the honest test of whether the node is really there.
	task.wait(0.7)

	local finished, started
	if _G.__DC_ENDCONN then pcall(function() _G.__DC_ENDCONN:Disconnect() end) end
	if _G.__DC_STARTCONN then pcall(function() _G.__DC_STARTCONN:Disconnect() end) end
	local okConn, conn = pcall(function()
		return net("ShovelNetwork").ShovelEvents.DigSceneEnd:connect(function(userId, success)
			if userId == plr.UserId then finished = success end
		end)
	end)
	if okConn then _G.__DC_ENDCONN = conn end
	local okStart, startConn = pcall(function()
		return net("ShovelNetwork").ShovelEvents.DigSceneStart:connect(function(userId)
			if userId == plr.UserId then started = true end
		end)
	end)
	if okStart then _G.__DC_STARTCONN = startConn end

	fire("ShovelNetwork", "ShovelEvents", "SetShovelEquipped", true)
	pcall(function() ctrl:attemptDig() end)
	task.wait(0.4)

	-- The server answers a real dig with DigSceneStart almost immediately. If it
	-- does not, the node is not there any more and clicking at it for the full
	-- timeout is pure waste - that is what made three dead nodes in a row stall the
	-- farm for twenty seconds each.
	local interval = 1 / math.clamp(CONFIG.clicksPerSec, 1, 40)
	local startDeadline = os.clock() + 1.6
	while not started and finished == nil and os.clock() < startDeadline do
		pcall(function() ctrl:onDigInput() end)
		task.wait(interval)
	end
	if not started and finished == nil then
		if okConn then pcall(function() conn:Disconnect() end) end
		if okStart then pcall(function() startConn:Disconnect() end) end
		forgetNode(node.id)
		STATE.note = "stale node (" .. tostring(node.rarity) .. ")"
		return false
	end

	-- Some finds are simply out of reach for the current shovel: the decay eats the
	-- clicks and the bar sits still or slides back. Grinding the full timeout into
	-- one of those costs twenty seconds and yields nothing, so a dig that is not
	-- gaining ground gets abandoned and the node is dropped.
	local progConn
	if _G.__DC_PROGCONN then pcall(function() _G.__DC_PROGCONN:Disconnect() end) end
	local progress, bestProgress, bestAt = 0, 0, os.clock()
	local okProg, pc = pcall(function()
		return net("ShovelNetwork").ShovelEvents.DigSceneProgress:connect(function(userId, value)
			if userId == plr.UserId then progress = value or 0 end
		end)
	end)
	if okProg then progConn = pc _G.__DC_PROGCONN = pc end

	-- The deadline follows the prediction instead of sitting at a flat 20 seconds:
	-- a node predicted at 4s that is still going at 12 is not a slow dig, it is a
	-- wrong model, and the sooner that ends the sooner the model is corrected. The
	-- ceiling stays at DIG_SESSION_TIMEOUT so a genuinely long dig is never cut.
	local budgeted = math.clamp(
		(predicted == math.huge and 20 or predicted) * 2.5 + 3, 6,
		CfgDig.DIG_SESSION_TIMEOUT or 45)
	local started_at = os.clock()
	local firstProgress, firstAt, lastProgress, lastAt
	local deadline = started_at + budgeted
	local stalled = false
	while finished == nil and os.clock() < deadline and CONFIG.auto and GEN == _G.__DIGCLEAN do
		pcall(function() ctrl:onDigInput() end)
		task.wait(interval)
		-- every sample is kept, up OR down: the slope of the bar is the measurement
		if progress > 0 and progress ~= lastProgress then
			if not firstAt then firstProgress, firstAt = progress, os.clock() end
			lastProgress, lastAt = progress, os.clock()
		end
		if progress > bestProgress + 0.01 then
			bestProgress, bestAt = progress, os.clock()
		elseif os.clock() - bestAt > CONFIG.giveUpAfter then
			stalled = true
			break
		end
	end
	if okConn then pcall(function() conn:Disconnect() end) end
	if okStart then pcall(function() startConn:Disconnect() end) end
	if progConn then pcall(function() progConn:Disconnect() end) end

	-- Whatever the outcome, the bar's own speed is the measurement of how many
	-- clicks the server counted, and every dig that moved it refines the model.
	if firstAt and lastAt then
		learnRate(node, lastProgress - firstProgress, lastAt - firstAt)
	end

	if stalled and finished == nil then
		forgetNode(node.id)
		-- A dig that did not move at all is the honest proof that this band is out
		-- of reach right now, whatever the config said.
		learnStall(node)
		STATE.note = string.format("too hard for this shovel (%s, stuck at %.0f%%)",
			tostring(node.rarity), bestProgress * 100)
		STATE.tooHard = (STATE.tooHard or 0) + 1
		return false
	end

	-- Gone either way: a dug node is consumed, and a timed-out one is usually a
	-- node that expired underneath us. Leaving it in the map makes the picker
	-- return the same dead spot forever.
	forgetNode(node.id)

	if finished then
		STATE.digs = STATE.digs + 1
		STATE.note = string.format("dug %s in %.1fs (predicted %.1fs)",
			tostring(node.rarity), os.clock() - started_at,
			predicted == math.huge and 99 or predicted)
		return true
	end
	if finished == false then
		-- The server ends a dig as a loss once the bar falls past DIG_LOSE_THRESHOLD,
		-- which is what a band above the real click rate looks like from here: the
		-- slope measured above has already pulled the model down.
		STATE.note = string.format("lost the dig (%s, bar fell to %.0f%% in %.0fs)",
			tostring(node.rarity), bestProgress * 100, os.clock() - started_at)
		STATE.tooHard = (STATE.tooHard or 0) + 1
		return false
	end
	STATE.note = string.format("dig ran out of time (%s, %.0f%% after %.0fs)",
		tostring(node.rarity), bestProgress * 100, os.clock() - started_at)
	return false
end

-- beginCleaning + finishCleaning skips the spray minigame completely. Verified by
-- the item leaving the backpack clean and ItemsCleaned moving.
local function doClean()
	local cleaned = 0
	for _, tool in ipairs(backpackTools()) do
		if not CONFIG.auto or GEN ~= _G.__DIGCLEAN then break end
		if tool:GetAttribute("dirty") then
			local uid = tool:GetAttribute("inventoryId")
			if uid then
				STATE.phase = "clean"
				local ok = invoke("ItemsNetwork", "ItemsFunctions", "beginCleaning", uid)
				if ok then
					task.wait(0.35)
					fire("ItemsNetwork", "ItemsEvents", "finishCleaning", uid)
					cleaned = cleaned + 1
					task.wait(0.5)
				end
			end
		end
	end
	if cleaned > 0 then STATE.note = "cleaned " .. cleaned end
	return cleaned > 0
end

local function inventoryList()
	local d = data()
	if not d or type(d.Inventory) ~= "table" then return {} end
	local out = {}
	for _, entry in pairs(d.Inventory) do
		if type(entry) == "table" and entry.uid then out[#out + 1] = entry end
	end
	return out
end

-- itemValueFor(itemId, conditionNAME, kg) - in that order, with the condition as
-- the plain string. Called as (id, kg, condition) it throws inside the pcall and
-- every item scored 0, so "best" and "worst" were both zero: the museum never
-- swapped anything and the display order was arbitrary. Checked against the
-- in-game labels - duck / ok / 2kg comes back 391, which is what the pedestal says.
local function valueOf(entry)
	if not entry or not entry.id then return 0 end
	local ok, v = pcall(function()
		return CfgItems.itemValueFor(entry.id, entry.condition or "ok", tonumber(entry.kg) or 0)
	end)
	return ok and tonumber(v) or 0
end

-- The museum is the passive half of this game, so the rarest clean find goes on a
-- free pedestal before anything is sold. placeItem only answers true on the plot.
-- The plot number never changes for a session, and this runs twice a second, so
-- asking the server every cycle is a remote call per tick for a constant.
local function plotNumber()
	if _G.__DC_PLOT then return _G.__DC_PLOT end
	local ok, num = invoke("MiscNetwork", "MiscFunctions", "RequestPlotNumber")
	if ok and num then _G.__DC_PLOT = num end
	return _G.__DC_PLOT
end

-- There is more than one pedestal group. The ground floor sits in Plot.Pedestals
-- (slots 1-8, owned from the start), and a SECOND set of eight lives in
-- Plot.PlotComponents.Sections.Floor2.Pedestals as slots 9-16 - locked until the
-- Floor2 section is bought, and each one purchased separately after that. Reading
-- only the first folder meant the museum could never grow past eight exhibits no
-- matter how much was unlocked.
local function allPedestals(plotNum)
	local plot = Workspace:FindFirstChild("Plots")
	plot = plot and plot:FindFirstChild("Plot_" .. tostring(plotNum))
	local inner = plot and plot:FindFirstChild("Plot")
	if not inner then return {} end
	local out = {}
	for _, d in ipairs(inner:GetDescendants()) do
		if d:IsA("Model") and d.Name:sub(1, 9) == "Pedestal_" and d:GetAttribute("Slot") then
			out[#out + 1] = d
		end
	end
	table.sort(out, function(a, b)
		return (a:GetAttribute("Slot") or 0) < (b:GetAttribute("Slot") or 0)
	end)
	return out
end

local function doDisplay()
	local plotNum = plotNumber()
	if not plotNum then return false end
	local peds = allPedestals(plotNum)
	if #peds == 0 then return false end

	-- The inventory still lists an item that is standing on a pedestal, so the
	-- placed uids have to be subtracted or the same rare find is "missing from the
	-- museum" forever: every cycle drove to the plot, tried to place it again, got
	-- a bare false, and drove back. That ping-pong is what stalled the digging.
	local free, placed = {}, {}
	for _, p in ipairs(peds) do
		local uid = p:GetAttribute("ItemUid") or ""
		if uid ~= "" then
			placed[uid] = true
		elseif p:GetAttribute("Owned") then
			free[#free + 1] = p:GetAttribute("Slot")
		end
	end
	-- Deliberately NOT returning when every pedestal is busy: that early exit was
	-- left over from the fill-only version and it made the swap path below
	-- unreachable, so a 46,775 guitar sat in the bag while a 240 glass bottle kept
	-- its slot until the next sell trip threw the guitar away.
	table.sort(free)

	-- Every qualifying item, most valuable first, into every free pedestal in one
	-- trip. Placing one per cycle meant a museum with seven empty slots earned
	-- nothing for the seven cycles it took to notice them.
	-- An EMPTY pedestal earns nothing at all, so a common duck on it beats a rarity
	-- filter that leaves it bare. The rarity floor was keeping five of eight
	-- pedestals empty while the museum is the passive half of the game. Free slots
	-- take the best of whatever is in the bag; the floor only decides whether an
	-- item is worth evicting something that is already earning.
	local candidates = {}
	for _, entry in ipairs(inventoryList()) do
		if not entry.dirty and not placed[entry.uid] then
			entry.__value = valueOf(entry)
			candidates[#candidates + 1] = entry
		end
	end
	if #candidates == 0 then return false end
	table.sort(candidates, function(a, b) return (a.__value or 0) > (b.__value or 0) end)

	STATE.phase = "display"
	-- Pedestals is a FOLDER, and a Folder has no GetPivot. The call sat inside a
	-- pcall, so it failed silently and the hop to the plot never happened - which
	-- is why pickupItem kept refusing and not one exhibit was ever swapped. Aim at
	-- an actual pedestal model instead.
	local anchorPos
	for _, p in ipairs(peds) do
		local okPivot, pivot = pcall(function() return p:GetPivot() end)
		if okPivot then anchorPos = pivot.Position break end
	end
	if anchorPos then hop(anchorPos + Vector3.new(0, 4, 6), 0.6) end

	local placedCount = 0
	local nextCandidate = 1
	for _, slot in ipairs(free) do
		local entry = candidates[nextCandidate]
		if not entry then break end
		local okPlace, done = invoke("PedestalNetwork", "PedestalFunctions", "placeItem", slot, entry.uid)
		if okPlace and done == true then
			placedCount = placedCount + 1
			task.wait(0.35)
		end
		nextCandidate = nextCandidate + 1
	end

	-- Every slot busy: swap out the weakest exhibit whenever the bag holds
	-- something clearly better. Without this the museum freezes at whatever the
	-- first eight finds happened to be.
	-- Keep swapping while the bag still beats the museum, not once per cycle. A
	-- single swap per visit meant a 98KG fire hydrant went on display while two
	-- 474-gold old boots kept their slots and the rest of the haul was sold off
	-- before the next cycle ever looked at them.
	local swaps = 0
	if CONFIG.swapExhibits and #free == 0 then
		local used = {}
		for _ = 1, 8 do
			local worstSlot, worstValue
			for _, p in ipairs(peds) do
				local uid = p:GetAttribute("ItemUid") or ""
				local slot = p:GetAttribute("Slot")
				if uid ~= "" and not used[slot] then
					local v = valueOf({
						id = p:GetAttribute("ItemId"),
						kg = p:GetAttribute("Kg"),
						condition = p:GetAttribute("Condition"),
					})
					if not worstValue or v < worstValue then worstSlot, worstValue = slot, v end
				end
			end
			local top = candidates[nextCandidate]
			if not worstSlot or not top then break end
			if (top.__value or 0) <= (worstValue or 0) * CONFIG.swapMargin then break end

			-- Remember what was standing there: pickupItem empties the slot
			-- immediately and drops the exhibit into the world. If the follow-up
			-- placement is refused, the pedestal is left bare and the old piece is
			-- lying on the floor with a Pick Up prompt on it - so put it back.
			local evictedUid
			for _, p in ipairs(peds) do
				if p:GetAttribute("Slot") == worstSlot then evictedUid = p:GetAttribute("ItemUid") end
			end
			local okPick = invoke("PedestalNetwork", "PedestalFunctions", "pickupItem", worstSlot)
			if not okPick then break end
			task.wait(0.35)
			local okSwap, done = invoke("PedestalNetwork", "PedestalFunctions",
				"placeItem", worstSlot, top.uid)
			if not (okSwap and done == true) and evictedUid then
				invoke("PedestalNetwork", "PedestalFunctions", "placeItem", worstSlot, evictedUid)
				STATE.note = "swap refused, put the old exhibit back"
			end
			if okSwap and done == true then
				swaps = swaps + 1
				used[worstSlot] = true
				STATE.note = string.format("swapped %s -> %s (%s)",
					short(worstValue or 0), short(top.__value or 0),
					tostring((CfgItems.Items[top.id] or {}).displayName or top.id))
			else
				break
			end
			nextCandidate = nextCandidate + 1
			task.wait(0.3)
		end
	end
	if swaps > 0 then
		STATE.swaps = (STATE.swaps or 0) + swaps
		return true
	end

	if placedCount > 0 then
		STATE.note = "displayed " .. placedCount .. " item" .. (placedCount == 1 and "" or "s")
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- the plot itself
--------------------------------------------------------------------------------

-- Everything below spends gold on the base. None of it could be executed yet -
-- the cheapest step is the Polishing section at 1,500,000 and the balance during
-- development never got near it - so the call shapes come from the config and the
-- client components, and every one is wrapped so a wrong shape shows up in the
-- status line instead of silently doing nothing.
local CfgSections = require(Const.plot.PlotSections)
local CfgPolishing = require(Const.plot.Polishing)
local CfgUpstairs = require(Const.plot.UpstairsPedestals)

local function doUnlockSection()
	local d = data()
	if not d then return false end
	local unlocked = {}
	for _, id in ipairs(d.UnlockedSections or {}) do unlocked[id] = true end
	for _, id in ipairs(CfgSections.PLOT_SECTION_ORDER or {}) do
		local entry = (CfgSections.PlotSections or {})[id]
		local cost = entry and tonumber(entry.unlockCost)
		if entry and not unlocked[id] and cost and (d.Gold or 0) >= cost then
			STATE.phase = "unlock " .. id
			local ok, res = invoke("PlotSectionNetwork", "PlotSectionFunctions", "unlockSection", id)
			if ok and res == true then
				STATE.note = "unlocked section " .. id .. " for " .. short(cost)
				return true
			end
			STATE.note = "unlockSection(" .. id .. ") refused (" .. tostring(res) .. ")"
		end
	end
	return false
end

-- Polishing raises an item's condition (poor -> ok -> good -> great -> perfect ->
-- mint), and condition feeds itemValueFor, so a polished find is worth strictly
-- more both on a pedestal and at the seller.
local function doPolish()
	local d = data()
	if not d then return false end
	local unlocked = {}
	for _, id in ipairs(d.UnlockedSections or {}) do unlocked[id] = true end
	if not unlocked.Polishing then return false end

	local slots = CfgPolishing.POLISHER_SLOT_COUNT or 2
	local owned = tonumber(d.OwnedPolishers) or 1
	local acted = false

	-- collect anything finished first, so the slot is free for the next item
	for slot = 1, math.min(owned, slots) do
		local ok, res = invoke("PolisherNetwork", "PolisherFunctions", "collectPolish", slot)
		if ok and res then
			STATE.note = "collected polish " .. slot
			acted = true
			task.wait(0.4)
		end
	end

	-- then start the most valuable item that is not already at the top condition
	local order = require(Const.items.Conditions).CONDITION_ORDER or {}
	local topCondition = order[#order]
	local best, bestValue
	for _, entry in ipairs(inventoryList()) do
		if not entry.dirty and entry.condition ~= topCondition then
			local v = valueOf(entry)
			if not bestValue or v > bestValue then best, bestValue = entry, v end
		end
	end
	if best then
		for slot = 1, math.min(owned, slots) do
			local ok, res = invoke("PolisherNetwork", "PolisherFunctions", "startPolish", slot, best.uid)
			if ok and res == true then
				STATE.note = "polishing " .. tostring((CfgItems.Items[best.id] or {}).displayName or best.id)
				return true
			end
		end
	end
	return acted
end

local function doPlotUpgrades()
	local d = data()
	if not d then return false end
	local gold = d.Gold or 0
	local acted = false

	-- a second polisher, then levels on the ones already owned
	local owned = tonumber(d.OwnedPolishers) or 1
	local unlockCost = (CfgPolishing.POLISHER_UNLOCK_COSTS or {})[owned]
	if unlockCost and gold >= unlockCost then
		local ok, res = invoke("PolisherNetwork", "PolisherFunctions", "unlockPolisher", owned + 1)
		if ok and res == true then
			STATE.note = "unlocked polisher " .. (owned + 1)
			acted = true
		end
	end

	local levels = d.PolisherLevels or {}
	for slot = 1, math.min(owned, CfgPolishing.POLISHER_SLOT_COUNT or 2) do
		local level = tonumber(levels[slot]) or tonumber(levels[tostring(slot)]) or 1
		local entry = (CfgPolishing.POLISHER_LEVELS or {})[level]
		local cost = entry and tonumber(entry.upgradeCost)
		if cost and cost > 0 and gold >= cost and level < (CfgPolishing.POLISHER_MAX_LEVEL or 8) then
			local ok, res = invoke("PolisherNetwork", "PolisherFunctions", "upgradePolisher", slot)
			if ok and res == true then
				STATE.note = "polisher " .. slot .. " -> level " .. (level + 1)
				acted = true
			end
		end
	end

	-- upstairs pedestals, once Floor2 is open
	local count = tonumber(d.OwnedUpstairsPedestals) or 0
	local pedCost = (CfgUpstairs.UPSTAIRS_PEDESTAL_COSTS or {})[count + 1]
	if pedCost and gold >= pedCost then
		local slot = (CfgUpstairs.FIRST_BUYABLE_UPSTAIRS_SLOT or 10) + count
		local ok, res = invoke("PedestalNetwork", "PedestalFunctions", "buyPedestal", slot)
		if ok and res == true then
			STATE.note = "bought upstairs pedestal " .. slot
			acted = true
		end
	end

	return acted
end

local function backpackFullness()
	local d = data()
	if not d then return 0 end
	local count = #inventoryList()
	local limit = CfgBackpack.BASE_BACKPACK_CAPACITY + (d.BonusBackpackSlots or 0)
	local ok, lim = pcall(function() return CfgBackpack.BackpackCapacity.limitFor(d) end)
	if ok and tonumber(lim) then limit = lim end
	if limit <= 0 then return 0 end
	return count / limit
end

local function doSell()
	local where = npcNamed("SellerNPC")
	if not where then STATE.note = "no seller npc" return false end
	STATE.phase = "sell"
	hop(where + Vector3.new(0, 3, 4), 0.8)
	local ok, earned = invoke("SellNetwork", "SellFunctions", "sellInventory")
	if ok and tonumber(earned) then
		STATE.sold = STATE.sold + tonumber(earned)
		STATE.note = "sold for " .. tostring(math.floor(tonumber(earned)))
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- islands
--------------------------------------------------------------------------------

-- The islands carry a LUCK multiplier - 1, 2, 4, 8 - and luck is what decides how
-- rare a buried item rolls. That makes the island the single biggest upgrade in
-- the game and it is not gear: Shipwreck Cove costs 1,100,000 and doubles every
-- roll from then on, while a shovel at 45,000 only makes the same rolls faster.
--
-- This block sits ABOVE doBuyGear on purpose. It was written below it once, and
-- because a Lua local is invisible above its own definition, doBuyGear's call to
-- islandReserve() resolved to nil - and since the whole cycle runs inside pcall,
-- the farm just stopped with "attempt to call a nil value" in the footer instead
-- of crashing loudly.
local CfgIslands = require(Const.world.Islands)

local function islandInfo(id)
	return (CfgIslands.Islands or {})[id]
end

local function bestIsland(d)
	local unlocked = {}
	for _, id in ipairs(d.UnlockedIslands or {}) do unlocked[id] = true end
	local bestUnlocked, bestLuck = CfgIslands.STARTER_ISLAND_ID, 0
	local nextLocked, nextCost
	for _, id in ipairs(CfgIslands.ISLAND_ORDER or {}) do
		local entry = islandInfo(id)
		if entry then
			local luck = tonumber(entry.luck) or 1
			if unlocked[id] then
				if luck > bestLuck then bestUnlocked, bestLuck = id, luck end
			elseif not nextLocked then
				nextLocked, nextCost = id, tonumber(entry.cost) or math.huge
			end
		end
	end
	return bestUnlocked, bestLuck, nextLocked, nextCost
end

-- The reserve that stops the starvation pattern: once the next island is within
-- reach of the current income, gear may only spend the surplus above its price.
-- Without it a 45,000 shovel every few minutes means 1,100,000 is never reached.
-- An hour, not fifteen minutes. At a few hundred gold a second the next island is
-- roughly an hour of farming away, so a short window never declared it "in reach"
-- and gear kept eating the balance: a 190,000 shovel took the pile from 192,661
-- straight back to 4,109 while the 1,100,000 island - which DOUBLES the rarity of
-- every future roll - stayed out of view. The window has to be long enough that
-- the target counts as reachable, or the reserve never engages at all.
local RESERVE_WINDOW = 3600
local function islandReserve()
	local d = data()
	if not d then return 0 end
	local _, _, nextLocked, nextCost = bestIsland(d)
	if not nextLocked or not nextCost then return 0 end
	local gold = d.Gold or 0
	-- Two ways in, because the income figure is jumpy: one mythic sale is worth
	-- twenty commons, so a rate sampled over a few seconds swings between 90 and
	-- 300 a second and the reserve kept flicking off again. The second condition is
	-- a plain floor - once a sixth of the price is banked, stop spending it.
	local reachable = gold + math.max(STATE.goldRate, 0) * RESERVE_WINDOW
	if reachable >= nextCost or gold >= nextCost * 0.15 then return nextCost end
	return 0
end

local function doTravel()
	local d = data()
	if not d then return false end
	local best, luck, nextLocked, nextCost = bestIsland(d)

	-- buy the next island the moment it is affordable; nothing else competes
	if nextLocked and nextCost and (d.Gold or 0) >= nextCost then
		STATE.phase = "unlock " .. nextLocked
		local ok, res = invoke("TravelNetwork", "TravelFunctions", "travel", nextLocked)
		if ok and res ~= "poor" then
			STATE.note = "unlocked island " .. nextLocked .. " for " .. short(nextCost)
			_G.__DC_PLOT = nil
			return true
		end
		STATE.note = "travel(" .. nextLocked .. ") -> " .. tostring(res)
	end

	-- and make sure we are actually standing on the best one we own
	if d.CurrentIsland ~= best then
		STATE.phase = "travel " .. best
		local ok, res = invoke("TravelNetwork", "TravelFunctions", "travel", best)
		if ok and res ~= "poor" then
			STATE.note = "travelled to " .. best .. " (luck x" .. luck .. ")"
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------

-- Gear is island locked and only sold at that island's GearNPC. Ranked on power,
-- never on price - the ladders happen to agree today and that is not a guarantee.
local function bestGear(config, orderKey, tableKey, owned, unlockedIslands, gold)
	local list = config[tableKey]
	local order = config[orderKey]
	if type(list) ~= "table" or type(order) ~= "table" then return nil end
	local ownedSet = {}
	for _, id in ipairs(owned or {}) do ownedSet[id] = true end
	local islandSet = {}
	for _, id in ipairs(unlockedIslands or {}) do islandSet[id] = true end

	local pick, pickRank = nil, -1
	for index, id in ipairs(order) do
		local entry = list[id]
		if entry and not ownedSet[id] then
			local cost = tonumber(entry.cost) or math.huge
			-- The three gear types do not share a stat name: shovels carry `power`,
			-- detectors `range`, sprays `strength`. Reading only `power` made every
			-- detector rank zero and the loop bought the CHEAPEST tier instead of
			-- the best affordable one - copper at 500 while silver at 5000 was
			-- covered. The tier order is the tiebreaker when no stat is found.
			local rank = tonumber(entry.power) or tonumber(entry.range)
				or tonumber(entry.strength) or tonumber(entry.speed) or index
			if cost > 0 and cost <= gold and islandSet[entry.islandId] and rank > pickRank then
				pick, pickRank = id, rank
			end
		end
	end
	return pick
end

local GEAR_CATEGORY = { shovel = "shovel", spray = "spray", detector = "detector" }

-- Owning the best tier and HOLDING it are two different things, and only the second
-- one digs: `bestGear` skips anything already owned, so once the equipped item is
-- behind the inventory - a swap, a pack, a reward - nothing ever put it right and
-- the farm kept measuring a plastic shovel while a gold one sat in the bag.
local function equipBest(d, cfg, orderKey, tableKey, owned, equipped, category)
	local list, order = cfg[tableKey], cfg[orderKey]
	if type(list) ~= "table" or type(order) ~= "table" then return false end
	local rankOf = {}
	for index, id in ipairs(order) do
		local entry = list[id]
		rankOf[id] = entry and (tonumber(entry.power) or tonumber(entry.range)
			or tonumber(entry.strength) or index) or index
	end
	local pick, pickRank = nil, rankOf[equipped] or -1
	for _, id in ipairs(owned or {}) do
		if (rankOf[id] or -1) > pickRank then pick, pickRank = id, rankOf[id] end
	end
	if not pick then return false end
	local ok, res = invoke("ShopNetwork", "ShopFunctions", "equipGear", category, pick)
	if ok and res ~= false then
		STATE.note = "equipped " .. pick
		return true
	end
	return false
end

local function doBuyGear()
	local d = data()
	if not d then return false end
	local where = npcNamed("GearNPC")
	if not where then return false end

	local jobs = {
		{ cat = GEAR_CATEGORY.shovel, cfg = CfgShovels, order = "SHOVEL_TIER_ORDER",
		  tbl = "Shovels", owned = d.OwnedShovels, ownedKey = "OwnedShovels",
		  equippedKey = "EquippedShovel" },
		{ cat = GEAR_CATEGORY.spray, cfg = CfgSprays, order = "SPRAY_TIER_ORDER",
		  tbl = "SprayBottles", owned = d.OwnedSprays, ownedKey = "OwnedSprays",
		  equippedKey = "EquippedSpray" },
		{ cat = GEAR_CATEGORY.detector, cfg = CfgDetectors, order = "DETECTOR_TIER_ORDER",
		  tbl = "Detectors", owned = d.OwnedDetectors, ownedKey = "OwnedDetectors",
		  equippedKey = "EquippedDetector" },
	}

	-- Before spending anything: hold the best of what is already owned. This needs
	-- no NPC and no gold, and it is the only thing that repairs an equipped tier
	-- that has fallen behind the inventory.
	for _, job in ipairs(jobs) do
		equipBest(d, job.cfg, job.order, job.tbl, d[job.ownedKey],
			d[job.equippedKey], job.cat)
	end

	-- One trip buys as many tiers as the balance covers, not one per visit. Gold
	-- accumulates while digging, so a single-purchase trip left affordable gear
	-- sitting in the shop for as long as it took the backpack to fill again.
	local bought = false
	local rounds = 0
	repeat
	local boughtThisRound = false
	rounds = rounds + 1
	for _, job in ipairs(jobs) do
		-- Gold is re-read per job: buying the shovel first leaves the spray and
		-- detector checks comparing against a balance that is already spent, which
		-- silently picks something no longer affordable and the purchase answers a
		-- bare `false` with nothing to read.
		local fresh = data() or d
		local owned = fresh[job.ownedKey] or job.owned
		-- Spend only the surplus above the island reserve, except for anything so
		-- cheap next to the balance that blocking it would be silly.
		local gold = fresh.Gold or 0
		local reserve = CONFIG.islandFirst and islandReserve() or 0
		local budget = gold
		if reserve > 0 then budget = math.max(gold - reserve, gold * 0.01) end
		local pick = bestGear(job.cfg, job.order, job.tbl, owned, fresh.UnlockedIslands, budget)
		if pick then
			STATE.phase = "buy " .. job.cat
			hop(where + Vector3.new(0, 3, 4), 0.8)
			local ok, res = invoke("ShopNetwork", "ShopFunctions", "buyGear", job.cat, pick)
			if ok and res == true then
				invoke("ShopNetwork", "ShopFunctions", "equipGear", job.cat, pick)
				STATE.note = "bought " .. pick
				bought = true
				boughtThisRound = true
				task.wait(0.6)
			else
				STATE.note = "buy " .. pick .. " refused (" .. tostring(res) .. ")"
			end
		end
	end
	until not boughtThisRound or rounds >= 8
	return bought
end

-- True when something is affordable and unbought, so the shopping trip is only
-- walked when it would actually do something.
local function gearPending()
	local d = data()
	if not d then return false end
	local checks = {
		{ CfgShovels, "SHOVEL_TIER_ORDER", "Shovels", d.OwnedShovels,
		  d.EquippedShovel, GEAR_CATEGORY.shovel },
		{ CfgSprays, "SPRAY_TIER_ORDER", "SprayBottles", d.OwnedSprays,
		  d.EquippedSpray, GEAR_CATEGORY.spray },
		{ CfgDetectors, "DETECTOR_TIER_ORDER", "Detectors", d.OwnedDetectors,
		  d.EquippedDetector, GEAR_CATEGORY.detector },
	}
	for _, c in ipairs(checks) do
		if bestGear(c[1], c[2], c[3], c[4], d.UnlockedIslands, d.Gold or 0) then return true end
	end
	-- A better OWNED tier that is not in hand is also pending work, and it is the
	-- cheap kind: no walk, no gold, and it is what the trip existed for anyway.
	for _, c in ipairs(checks) do
		if equipBest(d, c[1], c[2], c[3], c[4], c[5], c[6]) then return false end
	end
	return false
end

local function claimFree()
	invoke("OfflineEarningsNetwork", "OfflineEarningsFunctions", "claimOfflineEarnings")
	fire("ForeverPackNetwork", "ForeverPackEvents", "claimFree")
end

local function unstuck()
	CONFIG.auto = false
	local c, hrp, hum = char()
	if hrp then hrp.Anchored = false end
	if hum then hum.PlatformStand = false end
	STATE.busy = false
	STATE.note = "unstuck, auto off"
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(interval, fn)
	task.spawn(function()
		while GEN == _G.__DIGCLEAN do
			if CONFIG.auto then
				local ok, err = pcall(fn)
				if not ok then STATE.note = tostring(err) end
			end
			task.wait(interval)
		end
	end)
end

-- The main cycle runs as ONE guarded routine rather than four independent loops:
-- digging, selling and buying all move the body, and two of them pulling in
-- opposite directions is how a farm ends up jogging on the spot forever.
loop(0.5, function()
	if STATE.busy then return end
	STATE.busy = true
	local ok, err = pcall(function()
		if STATE.tutorial >= 0 and STATE.tutorial < 11 then
			STATE.phase = "tutorial " .. STATE.tutorial
			STATE.note = "finish the tutorial first - no nodes spawn before step 11"
			task.wait(3)
			return
		end
		closeModals()
		if CONFIG.clean then doClean() end
		if CONFIG.polish then doPolish() end
		if CONFIG.display then doDisplay() end
		if CONFIG.sell and backpackFullness() >= CONFIG.sellAt then
			doSell()
			closeModals()
		end
		-- Shopping runs on its own clock. Hanging it off the sell trip meant that
		-- with a 50-slot backpack an affordable upgrade waited minutes for the
		-- inventory to fill, which reads exactly like "it never upgrades".
		if os.clock() >= (STATE.nextGearAt or 0) then
			STATE.nextGearAt = os.clock() + math.max(CONFIG.gearEvery, 10)
			-- Islands go before every other spend: they multiply every future roll.
			if CONFIG.islands then doTravel() end
			if CONFIG.plot then doUnlockSection() doPlotUpgrades() end
			if CONFIG.buyGear and gearPending() then
				doBuyGear()
				closeModals()
			end
		end
		if CONFIG.dig then doDig() end
	end)
	STATE.busy = false
	if not ok then STATE.note = tostring(err) end
end)

loop(6, function()
	local d = data()
	if not d then return end
	STATE.gold = d.Gold or 0
	STATE.level = d.Level or 0
	STATE.xp = d.Xp or 0
	STATE.dug = d.ItemsDug or 0
	STATE.cleaned = d.ItemsCleaned or 0
	local now = os.clock()
	if STATE.lastGoldAt > 0 and now > STATE.lastGoldAt then
		local rate = (STATE.gold - STATE.lastGold) / (now - STATE.lastGoldAt)
		if rate >= 0 then STATE.goldRate = rate end
	end
	STATE.lastGold, STATE.lastGoldAt = STATE.gold, now
	STATE.tutorial = tutorialStep()
	STATE.gear = tostring(d.EquippedShovel) .. " / " .. tostring(d.EquippedSpray) ..
		" / " .. tostring(d.EquippedDetector)
	refreshShovel(d)
	local best, luck, nextLocked, nextCost = bestIsland(d)
	STATE.island = tostring(d.CurrentIsland) .. " luck x" .. tostring(luck == 0 and 1 or luck) ..
		(nextLocked and ("   next " .. nextLocked .. " " .. short(nextCost)) or "   all owned")
	local reserve = islandReserve()
	if reserve > 0 then STATE.island = STATE.island .. "  (reserved)" end
end)

loop(120, function()
	if CONFIG.claimFree then claimFree() end
end)

armNodeListener()

-- The 6s refresh only runs while AUTO is on, so the ladder is read once at load -
-- otherwise the panel opens quoting a plastic shovel's ceiling on a diamond one.
task.spawn(function()
	local ok, d = pcall(data)
	refreshShovel(ok and d or nil)
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__DIGCLEAN_WIN then pcall(function() _G.__DIGCLEAN_WIN:Destroy() end) end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("digclean", CONFIG)

local win = UI.Window({
	title = "DIG", accentTitle = "CLEAN", subtitle = "seltonmt",
	badge = "🧼", width = 920, height = 580,
})
_G.__DIGCLEAN_WIN = win

local page = win:Page("FARM", UI.icon.pickaxe)

local main = page:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.note = v and "running" or "stopped"
end, "one guarded cycle: clean, display, sell, dig", UI.theme.good)
main:Toggle("Dig", CONFIG.dig, function(v) CONFIG.dig = v end,
	"rarest buried node first, then nearest")
main:Toggle("Clean", CONFIG.clean, function(v) CONFIG.clean = v end,
	"beginCleaning + finishCleaning, skips the spray minigame")
main:Toggle("Sell", CONFIG.sell, function(v) CONFIG.sell = v end,
	"walks to the seller once the backpack is full enough")
main:Slider("Clicks/sec", 4, 30, CONFIG.clicksPerSec, function(v)
	local was = CONFIG.clicksPerSec
	CONFIG.clicksPerSec = math.floor(v)
	-- The learned budget is measured AT a click rate, so halving the rate halves
	-- what the loop can take out of the ground. Scaling it here keeps the rarity
	-- target honest instead of waiting for a run of stalls to discover it.
	if was > 0 then
		STATE.cps = math.max(STATE.cps * (CONFIG.clicksPerSec / was), 1)
		_G.__DC_CPS = STATE.cps
	end
end, "the game's own ceiling is 50 per second")
main:Toggle("Scan the field", CONFIG.scan, function(v) CONFIG.scan = v end,
	"sweeps the area first so there is a choice of nodes instead of one underfoot")
main:Slider("Scan hops", 2, 10, CONFIG.scanPoints, function(v)
	CONFIG.scanPoints = math.floor(v)
end, "more hops reveal more of the field and cost about half a second each")
main:Toggle("Match the shovel", CONFIG.rarityAuto, function(v) CONFIG.rarityAuto = v end,
	"dig only what this shovel can finish, and raise the target as it improves",
	UI.theme.good)
main:Stepper("Give a node", function()
	return string.format("%ds", CONFIG.digSeconds)
end, function(dir)
	CONFIG.digSeconds = math.clamp(CONFIG.digSeconds + dir * 2, 4, 30)
end, "anything predicted slower than this is left in the ground")
main:Stepper("Hold out for", function()
	local order = CfgItems.RARITY_ORDER
	if CONFIG.rarityAuto then
		return "auto " .. tostring((type(order) == "table" and order[capIndex()]) or "?")
	end
	return (type(order) == "table" and order[CONFIG.scanRarity]) or tostring(CONFIG.scanRarity)
end, function(dir)
	CONFIG.scanRarity = math.clamp(CONFIG.scanRarity + dir, 1, 8)
end, "keep sweeping while the best known node is below this")

local extra = page:Card("MUSEUM & GEAR", 2)
extra:Toggle("Display best finds", CONFIG.display, function(v) CONFIG.display = v end,
	"tourists pay for what is on a pedestal - the passive half of the game")
extra:Toggle("Swap exhibits", CONFIG.swapExhibits, function(v) CONFIG.swapExhibits = v end,
	"once all pedestals are busy, evict the weakest for a clearly better find")
extra:Stepper("Swap margin", function()
	return string.format("%.0f%%", (CONFIG.swapMargin - 1) * 100)
end, function(dir)
	CONFIG.swapMargin = math.clamp(CONFIG.swapMargin + dir * 0.1, 1.05, 3)
end, "how much more a find must be worth before it takes a slot")
extra:Toggle("Unlock islands", CONFIG.islands, function(v) CONFIG.islands = v end,
	"luck x1 / x2 / x4 / x8 for 0 / 1.1M / 32M / 120M - the biggest upgrade there is",
	UI.theme.warn)
extra:Toggle("Island before gear", CONFIG.islandFirst, function(v) CONFIG.islandFirst = v end,
	"holds gold back once the next island is within reach of income")
extra:Toggle("Polish", CONFIG.polish, function(v) CONFIG.polish = v end,
	"raises condition, which raises value both on a pedestal and at the seller")
extra:Toggle("Expand plot", CONFIG.plot, function(v) CONFIG.plot = v end,
	"Polishing 1.5M, polisher 2 at 20M, Floor2 750M, upstairs pedestals 2B+", UI.theme.warn)
extra:Stepper("Sell at", function() return math.floor(CONFIG.sellAt * 100) .. "%" end,
	function(dir) CONFIG.sellAt = math.clamp(CONFIG.sellAt + dir * 0.1, 0.1, 1) end,
	"backpack fullness that triggers a trip to the seller")
extra:Toggle("Buy gear", CONFIG.buyGear, function(v) CONFIG.buyGear = v end,
	"best affordable shovel, spray and detector at the GearNPC", UI.theme.warn)
extra:Toggle("Claim free rewards", CONFIG.claimFree, function(v) CONFIG.claimFree = v end,
	"offline earnings and the forever pack")
extra:Slider("Move speed", 30, 200, CONFIG.moveSpeed, function(v)
	CONFIG.moveSpeed = math.floor(v)
end, "studs per second for the hops")
extra:Button("Unstuck", unstuck, UI.theme.bad)

local out = page:Card("STATUS", 0):Readout(14, function(text)
	if text:find("tutorial") then return UI.theme.warn end
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__DIGCLEAN do
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase    " .. tostring(STATE.phase),
			"  gold     " .. short(STATE.gold) .. "   " .. short(STATE.goldRate) .. "/s",
			"  level    " .. STATE.level .. "   xp " .. short(STATE.xp),
			"  dug      " .. STATE.dug .. " total, " .. STATE.digs .. " this session",
			"  cleaned  " .. STATE.cleaned,
			"  sold     " .. short(STATE.sold) .. " gold this session",
			"  gear     " .. tostring(STATE.gear),
			"  island   " .. tostring(STATE.island),
			"  nodes    " .. STATE.nodes .. " visible, last " .. tostring(STATE.lastRarity),
			"  digs up to " .. tostring(STATE.cap) ..
				(CONFIG.rarityAuto and "" or "   (manual target)"),
			"  backpack " .. string.format("%d%%", math.floor(backpackFullness() * 100)),
			"  " .. tostring(STATE.note),
		}
		if STATE.tutorial >= 0 and STATE.tutorial < 11 then
			lines[#lines + 1] = "  tutorial step " .. STATE.tutorial .. " of 11 - nodes are gated on this"
		end
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s gold   lvl %d   %d dug   %s",
				short(STATE.gold), STATE.level, STATE.dug, STATE.phase))
		end)
		task.wait(0.5)
	end
end)

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste -
-- er ist immer das erste Icon und die Seite, auf der das Panel aufgeht.
pcall(function() win:Home() end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__DIGCLEAN_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	data = data, tutorialStep = tutorialStep,
	doDig = doDig, doClean = doClean, doSell = doSell, doDisplay = doDisplay,
	doBuyGear = doBuyGear, claimFree = claimFree, unstuck = unstuck,
	doPolish = doPolish, doUnlockSection = doUnlockSection, doPlotUpgrades = doPlotUpgrades,
	doTravel = doTravel, bestIsland = bestIsland, islandReserve = islandReserve,
	closeModals = closeModals, plotNumber = plotNumber,
	pickNode = pickNode, nodeList = nodeList, digController = digController,
	sweepArea = sweepArea, forgetNode = forgetNode, armNodeListener = armNodeListener,
	rarityStats = rarityStats, digSeconds = digSeconds, digLimit = digLimit,
	capIndex = capIndex, learnRate = learnRate, learnStall = learnStall,
	rarityOf = rarityOf, refreshShovel = refreshShovel,
	invoke = invoke, fire = fire, hop = hop, npcNamed = npcNamed,
	inventoryList = inventoryList, backpackFullness = backpackFullness,
}

print("[digclean] gen " .. GEN .. " ready - RightShift for the panel")
