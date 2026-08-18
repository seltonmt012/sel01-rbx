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
	buyGear = true,
	claimFree = true,     -- offline earnings, forever pack, codes
	moveSpeed = 90,       -- studs/s for the tween hops; the game does not check it
	clicksPerSec = 11,    -- DIG_MAX_CLICKS_PER_SECOND is 50
	sellAt = 0.8,         -- sell once the backpack is this full
	minRarityKeep = 3,    -- rarity index at or above which an item is displayed
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
	lastRarity = "-",
	goldRate = 0,
	lastGold = 0,
	lastGoldAt = 0,
	tutorial = -1,
	busy = false,
}

_G.__DIGCLEAN = (_G.__DIGCLEAN or 0) + 1
local GEN = _G.__DIGCLEAN

--------------------------------------------------------------------------------
-- network
--------------------------------------------------------------------------------

local netFolder = plr:WaitForChild("PlayerScripts"):WaitForChild("TS"):WaitForChild("network")
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

local function islandFolder()
	local d = data()
	local islands = Workspace:FindFirstChild("Islands")
	if not islands then return nil end
	-- The data's island id is not the folder name, so the current island is the
	-- one whose dig area is nearest - which is also the one we want to work in.
	local _, hrp = char()
	if not hrp then return islands:GetChildren()[1] end
	local best, bestDist
	for _, isl in ipairs(islands:GetChildren()) do
		local ok, pivot = pcall(function() return isl:GetPivot() end)
		if ok then
			local dist = (pivot.Position - hrp.Position).Magnitude
			if not bestDist or dist < bestDist then best, bestDist = isl, dist end
		end
	end
	return best
end

local function nearestTagged(tag)
	local _, hrp = char()
	if not hrp then return nil end
	local best, bestDist
	for _, z in ipairs(CollectionService:GetTagged(tag)) do
		local ok, pivot = pcall(function() return z:GetPivot() end)
		if ok then
			local dist = (pivot.Position - hrp.Position).Magnitude
			if not bestDist or dist < bestDist then best, bestDist = z, dist end
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
local function armNodeListener()
	if _G.__DC_NODECONN then pcall(function() _G.__DC_NODECONN:Disconnect() end) end
	_G.__DC_NODES = _G.__DC_NODES or {}
	local ok, conn = pcall(function()
		return net("DetectorNetwork").DetectorEvents.BuriedNodes:connect(function(nodes)
			if type(nodes) == "table" then _G.__DC_NODES = nodes end
		end)
	end)
	if ok then _G.__DC_NODECONN = conn end
end

local RARITY = {}
do
	local order = CfgItems.RARITY_ORDER
	if type(order) == "table" then
		for i, name in ipairs(order) do RARITY[name] = i end
	end
end

local function nodeList()
	local list = _G.__DC_NODES
	return type(list) == "table" and list or {}
end

-- Rarest first, and among equals the nearest. Walking past a legendary to dig a
-- common is the one thing that actually costs value here.
local function pickNode()
	local _, hrp = char()
	if not hrp then return nil end
	local best, bestScore
	for _, n in ipairs(nodeList()) do
		if typeof(n.position) == "Vector3" then
			local rarity = RARITY[n.rarity] or 1
			local dist = (n.position - hrp.Position).Magnitude
			local score = rarity * 10000 - dist
			if not bestScore or score > bestScore then best, bestScore = n, score end
		end
	end
	return best
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

	-- Standing in a dig area is what makes the server scan for nodes at all.
	local zone, zoneDist = nearestTagged("DigZone")
	if zone and zoneDist and zoneDist > 60 then
		STATE.phase = "walk to dig area"
		local ok, pivot = pcall(function() return zone:GetPivot() end)
		if ok then hop(pivot.Position + Vector3.new(0, 5, 0)) end
	end

	fire("DetectorNetwork", "DetectorEvents", "SetDetectorHeld", true)

	local node = pickNode()
	if not node then
		-- A toggle forces a fresh scan; without it the list can stay empty after
		-- the last node of a batch was dug.
		fire("DetectorNetwork", "DetectorEvents", "SetDetectorHeld", false)
		task.wait(0.4)
		fire("DetectorNetwork", "DetectorEvents", "SetDetectorHeld", true)
		task.wait(2.5)
		node = pickNode()
	end
	if not node then STATE.note = "no buried nodes" return false end

	STATE.nodes = #nodeList()
	STATE.lastRarity = tostring(node.rarity)
	STATE.phase = "dig " .. tostring(node.rarity)
	hop(node.position + Vector3.new(0, 3, 0), 0.8)

	local finished
	if _G.__DC_ENDCONN then pcall(function() _G.__DC_ENDCONN:Disconnect() end) end
	local okConn, conn = pcall(function()
		return net("ShovelNetwork").ShovelEvents.DigSceneEnd:connect(function(userId, success)
			if userId == plr.UserId then finished = success end
		end)
	end)
	if okConn then _G.__DC_ENDCONN = conn end

	fire("ShovelNetwork", "ShovelEvents", "SetShovelEquipped", true)
	pcall(function() ctrl:attemptDig() end)
	task.wait(0.4)

	local interval = 1 / math.clamp(CONFIG.clicksPerSec, 1, 40)
	local deadline = os.clock() + 20
	while finished == nil and os.clock() < deadline and CONFIG.auto and GEN == _G.__DIGCLEAN do
		pcall(function() ctrl:onDigInput() end)
		task.wait(interval)
	end
	if okConn then pcall(function() conn:Disconnect() end) end

	if finished then
		STATE.digs = STATE.digs + 1
		STATE.note = "dug " .. tostring(node.rarity)
		return true
	end
	STATE.note = "dig timed out"
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

local function valueOf(entry)
	local ok, v = pcall(function()
		return CfgItems.itemValueFor(entry.id, entry.kg, entry.condition)
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

local function doDisplay()
	local plotNum = plotNumber()
	if not plotNum then return false end
	local plot = Workspace:FindFirstChild("Plots")
	plot = plot and plot:FindFirstChild("Plot_" .. tostring(plotNum))
	local peds = plot and plot:FindFirstChild("Plot") and plot.Plot:FindFirstChild("Pedestals")
	if not peds then return false end

	local free = {}
	for _, p in ipairs(peds:GetChildren()) do
		if p:GetAttribute("Owned") and (p:GetAttribute("ItemUid") or "") == "" then
			free[#free + 1] = p:GetAttribute("Slot")
		end
	end
	if #free == 0 then return false end
	table.sort(free)

	-- Every qualifying item, most valuable first, into every free pedestal in one
	-- trip. Placing one per cycle meant a museum with seven empty slots earned
	-- nothing for the seven cycles it took to notice them.
	local candidates = {}
	for _, entry in ipairs(inventoryList()) do
		if not entry.dirty then
			local rarity = RARITY[(CfgItems.Items[entry.id] or {}).rarity] or 1
			if rarity >= CONFIG.minRarityKeep then
				entry.__value = valueOf(entry)
				candidates[#candidates + 1] = entry
			end
		end
	end
	if #candidates == 0 then return false end
	table.sort(candidates, function(a, b) return (a.__value or 0) > (b.__value or 0) end)

	STATE.phase = "display"
	local ok, pivot = pcall(function() return peds:GetPivot() end)
	if ok then hop(pivot.Position + Vector3.new(0, 4, 6)) end

	local placedCount = 0
	for index, slot in ipairs(free) do
		local entry = candidates[index]
		if not entry then break end
		local okPlace, placed = invoke("PedestalNetwork", "PedestalFunctions", "placeItem", slot, entry.uid)
		if okPlace and placed == true then
			placedCount = placedCount + 1
			task.wait(0.4)
		end
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

local function doBuyGear()
	local d = data()
	if not d then return false end
	local where = npcNamed("GearNPC")
	if not where then return false end

	local jobs = {
		{ cat = GEAR_CATEGORY.shovel, cfg = CfgShovels, order = "SHOVEL_TIER_ORDER",
		  tbl = "Shovels", owned = d.OwnedShovels, ownedKey = "OwnedShovels" },
		{ cat = GEAR_CATEGORY.spray, cfg = CfgSprays, order = "SPRAY_TIER_ORDER",
		  tbl = "SprayBottles", owned = d.OwnedSprays, ownedKey = "OwnedSprays" },
		{ cat = GEAR_CATEGORY.detector, cfg = CfgDetectors, order = "DETECTOR_TIER_ORDER",
		  tbl = "Detectors", owned = d.OwnedDetectors, ownedKey = "OwnedDetectors" },
	}

	local bought = false
	for _, job in ipairs(jobs) do
		-- Gold is re-read per job: buying the shovel first leaves the spray and
		-- detector checks comparing against a balance that is already spent, which
		-- silently picks something no longer affordable and the purchase answers a
		-- bare `false` with nothing to read.
		local fresh = data() or d
		local owned = fresh[job.ownedKey] or job.owned
		local pick = bestGear(job.cfg, job.order, job.tbl, owned, fresh.UnlockedIslands, fresh.Gold or 0)
		if pick then
			STATE.phase = "buy " .. job.cat
			hop(where + Vector3.new(0, 3, 4), 0.8)
			local ok, res = invoke("ShopNetwork", "ShopFunctions", "buyGear", job.cat, pick)
			if ok and res == true then
				invoke("ShopNetwork", "ShopFunctions", "equipGear", job.cat, pick)
				STATE.note = "bought " .. pick
				bought = true
				task.wait(0.6)
			else
				STATE.note = "buy " .. pick .. " refused (" .. tostring(res) .. ")"
			end
		end
	end
	return bought
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
			if CONFIG.plot then doUnlockSection() doPlotUpgrades() end
			if CONFIG.buyGear then doBuyGear() end
			closeModals()
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
end)

loop(120, function()
	if CONFIG.claimFree then claimFree() end
end)

armNodeListener()

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__DIGCLEAN_WIN then pcall(function() _G.__DIGCLEAN_WIN:Destroy() end) end

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
	CONFIG.clicksPerSec = math.floor(v)
end, "the game's own ceiling is 50 per second")

local extra = page:Card("MUSEUM & GEAR", 2)
extra:Toggle("Display best finds", CONFIG.display, function(v) CONFIG.display = v end,
	"tourists pay for what is on a pedestal - the passive half of the game")
extra:Stepper("Keep from rarity", function()
	local order = CfgItems.RARITY_ORDER
	return (type(order) == "table" and order[CONFIG.minRarityKeep]) or tostring(CONFIG.minRarityKeep)
end, function(dir)
	CONFIG.minRarityKeep = math.clamp(CONFIG.minRarityKeep + dir, 1, 8)
end, "anything below this is sold instead of displayed")
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

local out = page:Card("STATUS", 0):Readout(11, function(text)
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
			"  nodes    " .. STATE.nodes .. " visible, last " .. tostring(STATE.lastRarity),
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

win:Refresh()

--------------------------------------------------------------------------------

_G.__DIGCLEAN_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	data = data, tutorialStep = tutorialStep,
	doDig = doDig, doClean = doClean, doSell = doSell, doDisplay = doDisplay,
	doBuyGear = doBuyGear, claimFree = claimFree, unstuck = unstuck,
	doPolish = doPolish, doUnlockSection = doUnlockSection, doPlotUpgrades = doPlotUpgrades,
	closeModals = closeModals, plotNumber = plotNumber,
	pickNode = pickNode, nodeList = nodeList, digController = digController,
	invoke = invoke, fire = fire, hop = hop, npcNamed = npcNamed,
	inventoryList = inventoryList, backpackFullness = backpackFullness,
}

print("[digclean] gen " .. GEN .. " ready - RightShift for the panel")
