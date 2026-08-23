--!nocheck
-- [+1 Wings for Brainrots] place 84332574190497 - full farm loop.
--
-- Every mechanic below was measured against a server side value, not assumed:
--
--   * Cash pools per slot and is taken by touching Slots.SlotN.CollectTouch.
--     firetouchinterest works from any distance - one pass over an untouched
--     plot moved Money 200,110,818 -> 148,500,195,849.
--   * Picking a brainrot up is position gated. fireproximityprompt from 218
--     studs did nothing; pinning the HumanoidRootPart on the item for ~1.2s
--     first and then firing takes it every time.
--   * Remotes.PlaceBestRequested:FireServer() places whatever is carried into
--     the best free slot, from the base, with no walking to the slot.
--     Verified: IncomePerSecond 100,000,755 -> 1,100,000,755 after one God
--     brainrot.
--   * Income per placed brainrot = BaseIncome * mutation * 1.125^(level-1).
--     Measured mutation factors: Golden 2, Diamond 3, Rainbow 4.5, Lava 5,
--     Hacker 7 (Chillin Chili base 20M, Lava, level 1 -> exactly +100M/s).
--   * A slot upgrade costs BaseIncome * 1.5^(level-1) and adds 12.5% of the
--     brainrot's income. Measured on a God brainrot: $1.0B -> +125.0M/s,
--     $1.5B -> +140.6M/s, $2.25B -> +158.2M/s, $3.375B -> +178.0M/s.
--     So payback = 8s / mutation * 1.3333^(level-1) and the cheapest slot is
--     almost never the best one - the loop ranks by payback, not by price.
--     The Price label on the stand is NOT the price: it read "$825.8B" while
--     the server charged $1.5B. Never drive off that label.
--   * Events.RequestBaseUpgrade() is $250K then $1M and maxes at 2/2, which is
--     what unlocks Floor2 and Floor3 - 30 slots in total.
--   * Remotes.UpgradeRequested:FireServer("Speed"|"Stamina"|"Carry", n) is a
--     plain remote with no position check. Speed level 4 -> 21 cost $22,021.
--   * Rebirth is gated on flight speed, which is 20 + (SpeedLevel - 1), and the
--     requirement is 20 + 20 * (rebirths + 1). Events.RequestRebirth() then
--     resets speed, stamina and money and keeps every placed brainrot:
--     measured Rebirths 0 -> 1, Money 6.5B -> 228, IncomePerSecond
--     3,753,236,908 -> 5,629,855,363, which is exactly x1.5.
--   * Time rewards are claimed by firing the Activated connection of
--     GUI.Frames.TimeRewards.Container.<n>.Button. Passing the index to
--     TimeRewardClaimed:FireServer(n) does nothing at all. Verified +$1,000.
--   * Selling is the ProximityPrompt pair on Workspace.Sell.ProxPart
--     (SellEquipped / SellInventory), 13 studs, so the body has to be there.
--     Events.RequestSell:FireServer() on its own never paid a cent.
--
-- Deliberately NOT in here, and why:
--   Remotes.RollLuckyBlock  - fired with the block equipped it consumed
--                             nothing and produced nothing. The real path is
--                             unsolved, so the blocks are left alone rather
--                             than burned.
--   Anything Robux          - wings with premium=true or a RobuxCost, the
--                             rebirth skip, the AdminAbuse panel.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local plr = Players.LocalPlayer

-- Zone anchor points, ordered weakest to strongest. Spawner folders only exist
-- while somebody is near them, so the loop flies to the zone first and reads
-- Workspace.ItemSpawners afterwards.
local ZONES = {
	{ name = "Common",    cf = CFrame.new(31.100, 3.027, 114.864) },
	{ name = "Uncommon",  cf = CFrame.new(36.178, 1.555, 302.746) },
	{ name = "Rare",      cf = CFrame.new(40.034, 1.842, 508.451) },
	{ name = "Epic",      cf = CFrame.new(47.413, 2.615, 822.582) },
	{ name = "Legendary", cf = CFrame.new(27.442, 2.568, 1253.078) },
	{ name = "Mythical",  cf = CFrame.new(31.528, 4.352, 1808.659) },
	{ name = "Secret",    cf = CFrame.new(35.971, 2.516, 2549.793) },
	{ name = "Celestial", cf = CFrame.new(33.481, 2.370, 4043.213) },
	{ name = "Cosmic",    cf = CFrame.new(35.490, 1.627, 6127.182) },
	{ name = "God",       cf = CFrame.new(28.067, 3.874, 10006.592) },
}

-- Measured against placed brainrots whose Earnings label the server writes.
-- Anything not listed falls back to 1 rather than to a guess.
local MUTATION = {
	Normal = 1, Golden = 2, Diamond = 3, Galaxy = 4, Rainbow = 4.5, Lava = 5,
	Hacker = 7,
}

-- Easter and UFO have not been seen on a plot yet, so they have no measured
-- factor. Treating an unknown mutation as x1 is the dangerous default: a Galaxy
-- Pakrahmatmatina priced at x1 looked like the worst brainrot on the plot and
-- was the one the swap threw away, while it was actually earning 540M/s. An
-- unknown mutation is rare, and rare here means strong, so it prices high
-- enough never to be the one discarded.
local UNKNOWN_MUTATION = 4

local CONFIG = {
	autoCollect = true,      -- touch every CollectTouch on the plot
	collectEvery = 8,        -- seconds between collect passes
	autoFarm = false,        -- fly out, pick brainrots up, bring them home
	zoneMode = 1,            -- 1 = deepest that spawns, 2 = fixed below
	zone = 9,                -- index into ZONES for the fixed mode
	godWatch = true,         -- detour to the God zone on a timer, it is a
	                         -- timed event spawn and worth 1B base income
	godEvery = 60,           -- seconds between God zone checks. God holds the
	                         -- only brainrots with a billion-plus base income
	                         -- (Chicleteira 1B, Meowl 1.5B, Ketupat 1.9B,
	                         -- Avocadini 2.4B) against Cosmic's 30M top end,
	                         -- but it is an event spawn and usually empty, so
	                         -- Cosmic stays the standing farm and this is a
	                         -- cheap ~5s detour.
	godWait = 45,            -- seconds left on the God clock that are worth
	                         -- waiting out on the pad instead of flying back
	autoPlace = true,        -- PlaceBestRequested after every trip
	replaceWeak = true,      -- a full plot drops its worst brainrot for a better
	sellJunk = true,         -- sell what the swaps left in the backpack
	autoSlotUpgrade = false, -- level the placed brainrots up by payback
	paybackCap = 240,        -- seconds; refuse upgrades slower than this
	autoSpeed = true,        -- buy Speed, which is the rebirth requirement
	autoCarry = true,        -- more brainrots per trip, max level 6
	autoStamina = false,     -- flight only, and the loop teleports
	autoRebirth = false,     -- resets speed/stamina/money, keeps brainrots
	autoTimeRewards = true,  -- the 12 step ladder, up to $500M and a block
	autoFreeBrainrot = true, -- one free Matteo, harmless
	autoLuckyBlock = true,   -- open every block in the backpack, then keep or
	                         -- sell what falls out
	sellSpare = false,       -- sell what is still carried when the plot is full
}

local STATE = {
	money = 0, income = 0, rebirths = 0, speedLevel = 0, carryLevel = 0,
	flightSpeed = 0, rebirthNeed = 0,
	zone = "-", phase = "idle", note = "-", uiOwner = "-",
	picked = 0, placed = 0, collected = 0, collectedCash = 0,
	upgrades = 0, upgradeSpend = 0, incomeAdded = 0,
	rewards = 0, rebirthsDone = 0, sold = 0, replaced = 0, skipped = 0,
	blocksOpened = 0,
	freeSlots = 0, usedSlots = 0,
	lastGod = 0, godTaken = 0, godIn = -1,
	baseWorst = 0, baseBest = 0, speedCost = 0,
	rebirthPayback = 0, slotPayback = 0,
	startIncome = 0, startedAt = os.clock(),
}

_G.__WINGSBR = (_G.__WINGSBR or 0) + 1
local generation = _G.__WINGSBR

-- Re-executing does not restart the Lua VM, so the previous run's panel is
-- still parented to CoreGui and stacks up - four of them after four ships.
-- The window object is kept in _G for exactly this, and the named ScreenGui is
-- swept as well, because a run that errored before it got that far never stored
-- one.
local PANEL_NAME = "WINGSBRAINROTS"
if _G.__WINGSBR_WIN then
	pcall(function() _G.__WINGSBR_WIN:Destroy() end)
	_G.__WINGSBR_WIN = nil
end
pcall(function()
	local host = (gethui and gethui()) or game:GetService("CoreGui")
	for _, child in ipairs(host:GetChildren()) do
		if child.Name == PANEL_NAME then child:Destroy() end
	end
end)

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local Events = ReplicatedStorage:WaitForChild("Events", 10)
local Funnels = ReplicatedStorage:WaitForChild("Funnels", 10)

local placeBest = Remotes:WaitForChild("PlaceBestRequested", 10)
local upgradeRequested = Remotes:WaitForChild("UpgradeRequested", 10)
local freeBrainrot = Remotes:WaitForChild("FreeBrainrotRequest", 10)
local logZoneReach = Funnels:WaitForChild("LogZoneReach", 10)
local slotUpgrade = Events:WaitForChild("RequestSlotUpgrade", 10)
local baseUpgrade = Events:WaitForChild("RequestBaseUpgrade", 10)
local rebirthRemote = Events:WaitForChild("RequestRebirth", 10)

local ItemConfig = require(ReplicatedStorage.Modules.ItemConfigurations)
local UpgradesConfig = require(ReplicatedStorage.Configs.UpgradesConfig)
local RebirthConfig = require(ReplicatedStorage.Configs.RebirthConfig)

-- Helpers -------------------------------------------------------------------

local function money()
	local ls = plr:FindFirstChild("leaderstats")
	local m = ls and ls:FindFirstChild("Money")
	return m and m.Value or 0
end

local function rebirths()
	local ls = plr:FindFirstChild("leaderstats")
	local r = ls and ls:FindFirstChild("Rebirths")
	return r and r.Value or 0
end

local function upgradeLevel(kind)
	local folder = plr:FindFirstChild("Upgrades")
	local v = folder and folder:FindFirstChild(kind .. "Level")
	return v and v.Value or 0
end

local function income()
	return plr:GetAttribute("IncomePerSecond") or 0
end

local function character()
	local char = plr.Character
	if not char or not char.Parent then return nil end
	return char, char:FindFirstChild("HumanoidRootPart")
end

local function short(n)
	n = tonumber(n) or 0
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if math.abs(n) >= u[1] then
			return string.format("%.1f%s", n / u[1], u[2])
		end
	end
	return string.format("%d", n)
end

local function note(text)
	STATE.note = text
end

-- The plot is named after the player, so it never has to be guessed from a
-- distance the way an owner-attribute search would.
local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return nil end
	return plots:FindFirstChild("Plot_" .. plr.Name)
end

local function homeCFrame()
	local plot = myPlot()
	local spawnPart = plot and plot:FindFirstChild("Spawn")
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart.CFrame + Vector3.new(0, 4, 0)
	end
	return CFrame.new(33.658, 3.020, 2.365)
end

-- Pin the root part on Heartbeat. The server validates a pickup against its own
-- copy of the position, and a single CFrame write is not enough - that is the
-- whole reason a prompt fired right after a teleport does nothing.
local function pin(cf, seconds)
	local _, hrp = character()
	if not hrp then return false end
	local target = cf
	local conn = RunService.Heartbeat:Connect(function()
		if hrp.Parent then hrp.CFrame = target end
	end)
	local deadline = os.clock() + (seconds or 1.2)
	while os.clock() < deadline and _G.__WINGSBR == generation do
		task.wait()
	end
	conn:Disconnect()
	return true
end

-- A pin that stays up while a callback runs, so several items can be taken on
-- one trip without letting the character fall between them.
local function withPin(getCFrame, fn)
	local _, hrp = character()
	if not hrp then return false, "no character" end
	local target = getCFrame()
	local conn = RunService.Heartbeat:Connect(function()
		if hrp.Parent then hrp.CFrame = target end
	end)
	local ok, err = pcall(fn, function(cf) target = cf end)
	conn:Disconnect()
	return ok, err
end

-- Interface mutex. Everything that moves the character or drives a panel goes
-- through this, so two routines can never fight over the same body.
local busy = false
local function withUI(name, fn)
	if busy then return false, "busy" end
	busy = true
	STATE.uiOwner = name
	local ok, err = pcall(fn)
	busy = false
	STATE.uiOwner = "-"
	if not ok then note(name .. " failed: " .. tostring(err)) end
	return ok, err
end

-- Value model ---------------------------------------------------------------

-- Forward declaration. The farm loop needs to spend while it waits at home, and
-- the spender is defined further down with the rest of the money code. A local
-- is invisible above its definition, and because every action runs inside pcall
-- that would have surfaced as a quiet note rather than an error.
local upgradeBestSlot

-- Every income figure the server reports already carries the rebirth
-- multiplier, so any model value has to be multiplied by it before the two can
-- be compared. Measured: 1 rebirth = x1.5, and the config agrees
-- (MultiplierPerLevel 0.5).
local function rebirthMultiplier()
	local ok, mult = pcall(RebirthConfig.GetMultiplier, rebirths())
	if ok and type(mult) == "number" and mult > 0 then return mult end
	return 1 + 0.5 * rebirths()
end

local function itemIncome(name, level, mutation)
	local cfg = ItemConfig.Items and ItemConfig.Items[name]
	if not cfg or not cfg.Income then return 0 end
	local mult = MUTATION[mutation or "Normal"] or UNKNOWN_MUTATION
	return cfg.Income * mult * (1.125 ^ ((level or 1) - 1))
end

-- "+540M/s" -> 540000000. The server writes this label on every placed
-- brainrot, so where it exists it beats the model outright: it already carries
-- the mutation, the level and the rebirth multiplier, including the mutations
-- nothing here has a factor for.
local SUFFIX = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qa = 1e15, Q = 1e15 }

local function parseAmount(text)
	if type(text) ~= "string" then return nil end
	local number, suffix = text:match("([%d%.]+)%s*([A-Za-z]*)")
	number = tonumber(number)
	if not number then return nil end
	if suffix == nil or suffix == "" or suffix == "s" then return number end
	local mult = SUFFIX[suffix] or SUFFIX[suffix:sub(1, 1):upper()]
	-- An unparsable suffix must not fall back to "that many dollars" - that is
	-- how a $1.56Q unlock once read as $1.56 in another game here.
	if not mult then return nil end
	return number * mult
end

local function baseIncomeOf(name)
	local cfg = ItemConfig.Items and ItemConfig.Items[name]
	return cfg and cfg.Income or 0
end

local function describe(inst)
	return string.format("%s %s lvl%d",
		tostring(inst:GetAttribute("Mutation")),
		tostring(inst:GetAttribute("OriginalName")),
		inst:GetAttribute("Level") or 1)
end

-- Plot ----------------------------------------------------------------------

local function eachSlot(fn)
	local plot = myPlot()
	if not plot then return end
	for _, floorName in ipairs({ "Floor1", "Floor2", "Floor3" }) do
		local floor = plot:FindFirstChild(floorName)
		local slots = floor and floor:FindFirstChild("Slots")
		if slots then
			for _, slot in ipairs(slots:GetChildren()) do
				local occupant
				local spawnPart = slot:FindFirstChild("Spawn")
				if spawnPart then
					for _, child in ipairs(spawnPart:GetChildren()) do
						if child:IsA("Model") and child:GetAttribute("OriginalName") then
							occupant = child
						end
					end
				end
				fn(floorName, slot, occupant)
			end
		end
	end
end

-- The map streams. Standing in the Cosmic zone, 6,000 studs out, the client
-- unloads the plot and every slot reads as empty - the first version then
-- believed the plot was 0/30, never swapped anything out and reported
-- "weakest: none" while 59 brainrots were placed. So a census taken away from
-- home is not a census, it is a missing chunk: the last reading from home is
-- kept and reused until the character is back.
local plotCache = { used = 0, free = 30, at = 0 }

local function nearHome()
	local _, hrp = character()
	if not hrp then return false end
	return (hrp.Position - homeCFrame().Position).Magnitude < 250
end

local function slotCensus()
	if not nearHome() and plotCache.at > 0 then
		STATE.usedSlots, STATE.freeSlots = plotCache.used, plotCache.free
		return plotCache.used, plotCache.free
	end
	local used, free = 0, 0
	eachSlot(function(_, _, occupant)
		if occupant then used = used + 1 else free = free + 1 end
	end)
	if used + free > 0 then
		plotCache.used, plotCache.free, plotCache.at = used, free, os.clock()
	end
	STATE.usedSlots, STATE.freeSlots = used, free
	return used, free
end

local function collectPlot()
	local _, hrp = character()
	local plot = myPlot()
	if not hrp or not plot then return 0 end
	-- CollectTouch parts stream out with the rest of the plot, so a pass fired
	-- from a zone touches nothing at all. The farm loop calls this again the
	-- moment it lands back home.
	if not nearHome() then return 0 end
	local before = money()
	local touched = 0
	for _, d in ipairs(plot:GetDescendants()) do
		if d.Name == "CollectTouch" and d:IsA("BasePart") then
			pcall(function()
				firetouchinterest(hrp, d, 0)
				firetouchinterest(hrp, d, 1)
			end)
			touched = touched + 1
		end
	end
	task.wait(0.4)
	local gained = money() - before
	if gained > 0 then
		STATE.collected = STATE.collected + 1
		STATE.collectedCash = STATE.collectedCash + gained
	end
	return gained, touched
end

-- Farming -------------------------------------------------------------------

local function spawnerFor(zoneName)
	local spawners = workspace:FindFirstChild("ItemSpawners")
	return spawners and spawners:FindFirstChild(zoneName)
end

local function carryCap()
	local base = (UpgradesConfig.Carry and UpgradesConfig.Carry.Base) or 1
	local growth = (UpgradesConfig.Carry and UpgradesConfig.Carry.GrowthPerLevel) or 1
	local level = math.max(upgradeLevel("Carry"), 1)
	return base + (level - 1) * growth
end

local function carriedCount()
	local char = character()
	if not char then return 0 end
	local n = 0
	for _, d in ipairs(char:GetChildren()) do
		if d:GetAttribute("OriginalName") then n = n + 1 end
	end
	return n
end

-- Take up to `limit` brainrots out of one zone, best first. The prompt is fired
-- once per item and the result is confirmed by the item leaving the workspace -
-- the prompt returns nothing, so firing twice would just be guessing.
local function harvestZone(zoneIndex, limit, minValue)
	local zone = ZONES[zoneIndex]
	if not zone then return 0 end
	minValue = minValue or 0
	STATE.zone = zone.name
	STATE.phase = "flying to " .. zone.name

	local taken = 0
	withPin(function() return zone.cf + Vector3.new(0, 5, 0) end, function(move)
		pcall(function() logZoneReach:FireServer(zone.name) end)
		task.wait(2)

		local spawner = spawnerFor(zone.name)
		if not spawner then
			note(zone.name .. ": nothing spawned")
			return
		end

		-- Raw values, the same scale the stands report. See the note by
		-- placedValue: the rebirth multiplier is global and must not be mixed
		-- into a comparison between two brainrots.
		local items = {}
		for _, item in ipairs(spawner:GetChildren()) do
			table.insert(items, {
				inst = item,
				value = itemIncome(item:GetAttribute("OriginalName"),
					item:GetAttribute("Level"), item:GetAttribute("Mutation")),
			})
		end
		table.sort(items, function(a, b) return a.value > b.value end)

		STATE.phase = "picking in " .. zone.name
		for _, entry in ipairs(items) do
			if taken >= limit or _G.__WINGSBR ~= generation then break end
			local item = entry.inst
			-- Sorted best first, so the first one under the floor ends the zone:
			-- everything after it is worse. Carrying a brainrot that is weaker
			-- than the worst one already placed only costs a trip.
			if entry.value <= minValue then
				STATE.skipped = STATE.skipped + 1
				break
			end
			if item:IsDescendantOf(workspace) then
				local ok, pivot = pcall(function() return item:GetPivot() end)
				if ok then
					move(pivot + Vector3.new(0, 3, 0))
					task.wait(1.1)
					local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
					if prompt then
						pcall(function() fireproximityprompt(prompt) end)
						task.wait(0.6)
						if not item:IsDescendantOf(workspace) then
							taken = taken + 1
							STATE.picked = STATE.picked + 1
							note("took " .. describe(item) .. " (" .. short(entry.value) .. "/s)")
						end
					end
				end
			end
		end
	end)
	return taken
end

-- Replacing the weak ones ---------------------------------------------------
--
-- A full plot is not the end of the run, it is the point where the plot has to
-- start throwing its worst brainrot away. Each slot carries a "Pick Up / Swap"
-- ProximityPrompt on its Spawn part, 8 studs, and firing it takes the placed
-- brainrot back into the BACKPACK as a Tool (verified: income fell by exactly
-- the removed brainrot's rate and "Lirili Larila lvl14" appeared in the
-- backpack with its Guid). The slot is free immediately afterwards, so the
-- carried one can be placed with the normal PlaceBestRequested.
local function placedValue(occupant)
	if not occupant then return 0 end
	-- The label the server writes wins over the model whenever it parses.
	local label = occupant:FindFirstChild("Earnings", true)
	if label and label:IsA("TextLabel") then
		local value = parseAmount(label.Text)
		-- Multiplier brainrots show "250%" instead of a rate; those are not
		-- comparable to a per-second figure and must never be ranked as if the
		-- number were dollars, so they fall through to the model.
		if value and not label.Text:find("%%") then return value end
	end
	return itemIncome(occupant:GetAttribute("OriginalName"),
		occupant:GetAttribute("Level"), occupant:GetAttribute("Mutation"))
end

-- Scale, because getting this wrong swapped a 355M/s brainrot out for a 100M/s
-- one and called it an upgrade:
--
--   * the Earnings label on a stand is the RAW value - base x mutation x level.
--     A freshly placed Tik Tak Sahur (base 100M, Normal, level 1) reads exactly
--     +100M/s at 9 rebirths.
--   * the player's IncomePerSecond attribute is the sum of those times the
--     rebirth multiplier.
--
-- So comparisons between brainrots run on raw values and the multiplier is left
-- out entirely - it is global and cancels. It is only needed where money meets
-- income, which is the upgrade payback, and it stays in that formula alone.

-- Same streaming caveat as the census: the slots have to be loaded, which means
-- the character has to be home. Callers that fly first pin home for a moment.
local worstCache = { value = 0, at = 0 }

-- The whole plot, valued slot by slot and kept in _G so it survives a reload.
-- This is the table every decision out in a zone is made against: what is the
-- worst thing currently earning, and is the brainrot lying in front of us worth
-- more than that. It has to be built at home, because from a zone the plot is
-- streamed out and every slot reads as empty.
_G.__WINGSBR_MAP = _G.__WINGSBR_MAP or { slots = {}, worst = 0, best = 0, at = 0, count = 0 }
local slotMap = _G.__WINGSBR_MAP

local function rebuildSlotMap()
	if not nearHome() then return slotMap end
	local rows, worst, best = {}, math.huge, 0
	eachSlot(function(floorName, slot, occupant)
		if not occupant then return end
		local value = placedValue(occupant)
		table.insert(rows, {
			floor = floorName, slot = slot.Name, value = value,
			name = occupant:GetAttribute("OriginalName"),
			mutation = occupant:GetAttribute("Mutation"),
			rarity = occupant:GetAttribute("Rarity"),
			level = occupant:GetAttribute("Level"),
		})
		if value < worst then worst = value end
		if value > best then best = value end
	end)
	if #rows == 0 then return slotMap end
	table.sort(rows, function(a, b) return a.value > b.value end)
	slotMap.slots, slotMap.count = rows, #rows
	slotMap.worst = (worst == math.huge) and 0 or worst
	slotMap.best, slotMap.at = best, os.clock()
	STATE.baseWorst, STATE.baseBest = slotMap.worst, slotMap.best
	return slotMap
end

local function weakestPlaced()
	local worst, worstValue = nil, math.huge
	eachSlot(function(floorName, slot, occupant)
		if not occupant then return end
		local value = placedValue(occupant)
		if value < worstValue then
			worst, worstValue = { floor = floorName, slot = slot, occupant = occupant }, value
		end
	end)
	if not worst then
		-- Streamed out, not empty. Report the last honest reading so the value
		-- filter keeps working while the character is out farming.
		return nil, worstCache.value
	end
	worstCache.value, worstCache.at = worstValue, os.clock()
	return worst, worstValue
end

-- The value the farm has to beat before a pickup is worth a backpack slot and a
-- trip. With a free slot anything counts; with a full plot only something
-- better than the worst thing already earning does.
local function farmFloor()
	local _, free = slotCensus()
	if free > 0 then return 0 end
	rebuildSlotMap()
	-- The map is the memory: rebuilt every time the loop is home, read while
	-- standing 6,000 studs away where the plot itself is unreadable. Anything
	-- worth less than the worst slot is left lying - carrying it home would
	-- displace something better, and selling it is not worth the trip either:
	-- a brainrot sells for roughly 17x its base income ONCE (Matteo, base 220,
	-- paid 3,794), which at this plot's rate is a fraction of a second of
	-- income.
	if slotMap.worst > 0 then return slotMap.worst end
	local _, worstValue = weakestPlaced()
	return worstValue
end

local function removeWeakest()
	-- Get the plot loaded again before deciding which one is the worst: called
	-- straight after a harvest the character is still 6,000 studs out and every
	-- slot would read as empty.
	if not nearHome() then pin(homeCFrame(), 1.0) end
	local worst = weakestPlaced()
	if not worst then return false end
	local spawnPart = worst.slot:FindFirstChild("Spawn")
	if not spawnPart then return false end
	local prompt
	for _, d in ipairs(spawnPart:GetChildren()) do
		if d:IsA("ProximityPrompt") and d.ActionText == "Pick Up / Swap" then prompt = d end
	end
	if not prompt then return false end

	local name = describe(worst.occupant)
	local anchor = spawnPart:IsA("BasePart") and spawnPart.CFrame or worst.slot:GetPivot()
	local removed = false
	withPin(function() return anchor + Vector3.new(0, 4, 0) end, function()
		task.wait(1.2)
		pcall(function() fireproximityprompt(prompt) end)
		task.wait(1.2)
		local occupied = false
		for _, d in ipairs(worst.slot:GetDescendants()) do
			if d:IsA("Model") and d:GetAttribute("OriginalName") then occupied = true end
		end
		removed = not occupied
	end)
	if removed then
		STATE.replaced = STATE.replaced + 1
		note("pulled " .. name .. " out to make room")
	end
	return removed
end

-- Lucky blocks ---------------------------------------------------------------
--
-- A block is a Tool in the backpack named after its kind (Lava, Hacker, Dragon,
-- Rainbow, UFO). Opening it is **`tool:Activate()` with the tool equipped** -
-- Roblox's own tool activation, which the server picks up. There is no remote
-- involved: the spy recorded zero outgoing calls across two opens, and
-- `Remotes.RollLuckyBlock` fired by hand does nothing at all, which is what made
-- this look unsolvable at first.
--
-- The reward does not appear instantly. It lands in the backpack as a brainrot
-- Tool a few seconds later, after the throw (0.6s) and the roll (3s) - the first
-- attempt was written off as a failure because it only checked for 4s and the
-- reward was still in flight. Verified: two Lava blocks paid two Lava Ganganzelli
-- Trulala, one Dragon block paid a Tik Tak Sahur.
--
-- Worth knowing before getting excited: most block rewards are *below* a
-- developed plot. Lava Ganganzelli is 1M base, Tik Tak Sahur 100M, while the
-- worst slot here was already earning 355M/s. The jackpots are the rare weights
-- in the Dragon pool - Ketchuru and Musturu at 10.54B base (weight 1 out of
-- ~9,600), Ben at 6B (weight 6), Los Tralalelitos at 3.2B (weight 31). So the
-- blocks are free lottery tickets, not a farm.
local BLOCK_NAMES = {}
do
	local ok, cfg = pcall(require, ReplicatedStorage.Configs.LuckyBlockConfig)
	if ok and type(cfg) == "table" and type(cfg.LuckyBlocks) == "table" then
		for name in pairs(cfg.LuckyBlocks) do BLOCK_NAMES[name] = true end
	else
		BLOCK_NAMES = { Lava = true, Hacker = true, Dragon = true,
			Rainbow = true, UFO = true }
	end
end

local function isBlock(tool)
	return BLOCK_NAMES[tool.Name] and not tool:GetAttribute("OriginalName")
end

local function openLuckyBlocks()
	local char, _ = character()
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return 0 end

	local blocks = {}
	for _, tool in ipairs(plr.Backpack:GetChildren()) do
		if isBlock(tool) then table.insert(blocks, tool) end
	end
	if #blocks == 0 then return 0 end

	local opened = 0
	for _, tool in ipairs(blocks) do
		if _G.__WINGSBR ~= generation then break end
		local name = tool.Name
		pcall(function() hum:EquipTool(tool) end)
		task.wait(0.6)
		local held = char:FindFirstChildOfClass("Tool")
		if held and isBlock(held) then
			pcall(function() held:Activate() end)
			-- Throw 0.6s + roll 3s, plus room for the server to hand the reward
			-- over. Confirmed by the block leaving the inventory, never by the
			-- call returning - Activate reports nothing either way.
			local deadline = os.clock() + 9
			while os.clock() < deadline and _G.__WINGSBR == generation do
				if not held.Parent then break end
				task.wait(0.5)
			end
			if not held.Parent then
				opened = opened + 1
				STATE.blocksOpened = STATE.blocksOpened + 1
				note("opened a " .. name .. " lucky block")
			end
		end
	end
	-- Put the block tool away again so the farm loop is not carrying one around.
	pcall(function() hum:UnequipTools() end)
	return opened
end

-- A reward is a Tool, and PlaceBestRequested ignores Tools - it only places what
-- is carried as a model after a zone pickup (measured: held Tik Tak Sahur, fired
-- the remote, income moved by 0.00006 and the tool stayed in hand). The way in
-- is the slot's own "Pick Up / Swap" prompt while holding it, which swaps the
-- held brainrot for the one on the stand.
local function placeToolIntoWorstSlot(tool)
	local worst = weakestPlaced()
	if not worst then return false end
	local char, _ = character()
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local spawnPart = worst.slot:FindFirstChild("Spawn")
	if not hum or not spawnPart then return false end
	local prompt
	for _, d in ipairs(spawnPart:GetChildren()) do
		if d:IsA("ProximityPrompt") and d.ActionText == "Pick Up / Swap" then prompt = d end
	end
	if not prompt then return false end

	local before = income()
	local anchor = spawnPart:IsA("BasePart") and spawnPart.CFrame or worst.slot:GetPivot()
	pcall(function() hum:EquipTool(tool) end)
	withPin(function() return anchor + Vector3.new(0, 4, 0) end, function()
		task.wait(1.2)
		pcall(function() fireproximityprompt(prompt) end)
		task.wait(1.2)
	end)
	local gained = income() - before
	if gained > 0 then
		STATE.incomeAdded = STATE.incomeAdded + gained
		STATE.replaced = STATE.replaced + 1
		note(string.format("swapped a reward in, income +%s/s", short(gained)))
		return true
	end
	return false
end

-- Rewards worth more than the worst slot go onto the plot; the rest are left for
-- the seller. Ranking uses the same yardstick as everything else so a lucky
-- Ketchuru (10.54B base) is never sold by accident.
local function placeGoodRewards()
	if not nearHome() then return 0 end
	rebuildSlotMap()
	local placed = 0
	for _, tool in ipairs(plr.Backpack:GetChildren()) do
		local name = tool:GetAttribute("OriginalName")
		if name then
			local value = itemIncome(name, tool:GetAttribute("Level"),
				tool:GetAttribute("Mutation"))
			if value > slotMap.worst then
				if placeToolIntoWorstSlot(tool) then
					placed = placed + 1
					rebuildSlotMap()
				end
			end
		end
	end
	return placed
end

-- Junk sits in the backpack after a swap. It is sold one Tool at a time with
-- SellEquipped rather than with SellInventory, because the inventory also holds
-- the lucky blocks and SellInventory does not ask.
local function sellBackpackJunk()
	local sell = workspace:FindFirstChild("Sell")
	local prox = sell and sell:FindFirstChild("ProxPart")
	local prompt = prox and prox:FindFirstChild("SellEquipped")
	if not prompt then return 0 end
	local char, _ = character()
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return 0 end

	-- Only brainrots, and only ones the plot has already beaten. A lucky block
	-- can pay a Ketchuru and Musturu (10.54B base) into the same backpack the
	-- swapped-out junk lands in, and selling that by accident is unrecoverable.
	local junk = {}
	for _, tool in ipairs(plr.Backpack:GetChildren()) do
		local name = tool:GetAttribute("OriginalName")
		if name then
			local value = itemIncome(name, tool:GetAttribute("Level"),
				tool:GetAttribute("Mutation"))
			if slotMap.worst <= 0 or value <= slotMap.worst then
				table.insert(junk, tool)
			end
		end
	end
	if #junk == 0 then return 0 end

	local before = money()
	withPin(function() return sell:GetPivot() + Vector3.new(0, 5, 0) end, function()
		task.wait(1.2)
		for _, tool in ipairs(junk) do
			if _G.__WINGSBR ~= generation then break end
			pcall(function() hum:EquipTool(tool) end)
			task.wait(0.4)
			pcall(function() fireproximityprompt(prompt) end)
			task.wait(0.6)
		end
	end)
	local gained = money() - before
	if gained > 0 then
		STATE.sold = STATE.sold + #junk
		note(string.format("sold %d spare for %s", #junk, short(gained)))
	end
	return gained
end

local function goHomeAndPlace()
	STATE.phase = "placing"
	local before = income()
	pin(homeCFrame(), 1.0)
	if CONFIG.autoPlace then
		pcall(function() placeBest:FireServer() end)
		task.wait(1.5)
	end
	local gained = income() - before
	if gained > 0 then
		STATE.placed = STATE.placed + 1
		STATE.incomeAdded = STATE.incomeAdded + gained
		note(string.format("placed, income +%s/s", short(gained)))
	elseif carriedCount() > 0 then
		-- Placement only fails on a full plot. Make room once and retry rather
		-- than flying home with the brainrot still on our back.
		if CONFIG.replaceWeak and removeWeakest() then
			pin(homeCFrame(), 0.8)
			pcall(function() placeBest:FireServer() end)
			task.wait(1.5)
			gained = income() - before
			if gained > 0 then
				STATE.placed = STATE.placed + 1
				STATE.incomeAdded = STATE.incomeAdded + gained
				note(string.format("swapped in, income +%s/s", short(gained)))
			end
		else
			note("carried brainrot did not place - plot full")
		end
	end
	-- Standing on the plot anyway, and the collect pass is free from here. This
	-- is also the only reliable moment for it while the farm is running, since
	-- the pads are streamed out from a zone. Same for the slot map: this is when
	-- the plot is loaded, so this is when it gets re-read.
	if CONFIG.autoCollect then collectPlot() end
	rebuildSlotMap()
	return gained
end

-- Zone choice is a cursor, not a scan.
--
-- The first version scanned Workspace.ItemSpawners for the deepest folder that
-- had items in it. That reads sensible and is wrong: spawner folders only exist
-- while the character is near them, so standing at the base the only zones that
-- answer are the first few - and the loop farmed Epic forever while Cosmic sat
-- there with six brainrots worth thousands of times more. The cursor flies to
-- its zone first and judges it from inside.
local ladder = { cursor = 0, misses = 0 }

local function chooseZone()
	if CONFIG.zoneMode == 2 then return math.clamp(CONFIG.zone, 1, #ZONES) end
	if ladder.cursor == 0 then ladder.cursor = math.clamp(CONFIG.zone, 1, #ZONES - 1) end
	return ladder.cursor
end

local function farmCycle()
	-- Decide from home. Everything about the plot - how many slots are free and
	-- what the worst brainrot on it earns - is unreadable from a zone because
	-- the plot is streamed out at that distance.
	if not nearHome() then pin(homeCFrame(), 0.8) end
	local _, free = slotCensus()
	local full = free <= 0
	if full and not (CONFIG.replaceWeak or CONFIG.sellSpare) then
		note("plot full - turn on replace weak, or upgrade what is placed")
		STATE.phase = "plot full"
		task.wait(3)
		return
	end

	local floor = CONFIG.replaceWeak and farmFloor() or 0
	local limit = math.min(carryCap(), math.max(free, 1))
	local zoneIndex = chooseZone()
	local taken = harvestZone(zoneIndex, limit, floor)

	if taken > 0 then
		if full and CONFIG.replaceWeak then
			for _ = 1, taken do
				if not removeWeakest() then break end
			end
		end
		goHomeAndPlace()
		if CONFIG.sellJunk then sellBackpackJunk() end
		ladder.misses = 0
		-- A zone that delivers is worth probing one deeper: the deeper one only
		-- ever holds better brainrots, and God is left to the watcher.
		if CONFIG.zoneMode == 1 and zoneIndex < #ZONES - 1 then
			ladder.cursor = zoneIndex + 1
		end
	else
		ladder.misses = ladder.misses + 1
		if full then
			-- Nothing out there beats what is already earning. Stepping down a
			-- zone would only offer worse brainrots, so the right move is to
			-- stop flying and let the cash go into slot levels instead.
			--
			-- Waiting it out **at home** is the whole point: the first version
			-- parked in the zone, where the plot is streamed and the upgrade
			-- loop skips every pass, so the farm paused and the spending paused
			-- with it - 20s of "upgrading instead" bought nothing at all while a
			-- 87s-payback level sat there affordable.
			STATE.phase = "plot full, upgrading instead"
			note("nothing beats the plot - farming paused, spending on levels")
			pin(homeCFrame(), 1.0)
			for _ = 1, 8 do
				if _G.__WINGSBR ~= generation then break end
				if CONFIG.autoSlotUpgrade and not upgradeBestSlot() then break end
				task.wait(1)
			end
			task.wait(4)
		else
			-- An empty zone. Two misses in a row and it is not worth the trip.
			if CONFIG.zoneMode == 1 and ladder.misses >= 2 and zoneIndex > 1 then
				ladder.cursor = zoneIndex - 1
				ladder.misses = 0
				note("stepping down to " .. ZONES[ladder.cursor].name)
			end
			task.wait(1)
		end
	end
end

-- The God zone is a timed event spawn (Workspace.GOD_TIMER sits at z 10078),
-- not a zone that always holds six items like the others. One brainrot there is
-- worth a billion base income, so it gets its own cheap check on a timer.
-- The God spawn is on a clock and the clock is readable: the screen next to the
-- pad, Workspace.GOD_TIMER.Screen.SurfaceGui.Frame.Timer, reads
-- "GOD BRAINROT IN: 01:52". It only renders from close up, so the trip has to
-- happen anyway - but reading it once turns the blind 60s patrol into one
-- arrival per spawn, waiting the last seconds out on the pad.
local function godSecondsLeft()
	local timer = workspace:FindFirstChild("GOD_TIMER")
	local label = timer and timer:FindFirstChild("Timer", true)
	if not label or not label:IsA("TextLabel") then return nil end
	local minutes, seconds = label.Text:match("(%d+):(%d+)")
	if not minutes then return nil end
	return tonumber(minutes) * 60 + tonumber(seconds)
end

local function godCheck()
	if os.clock() - STATE.lastGod < CONFIG.godEvery then return end
	STATE.lastGod = os.clock()
	if not nearHome() then pin(homeCFrame(), 0.8) end
	local _, free = slotCensus()
	local full = free <= 0
	if full and not CONFIG.replaceWeak then return end
	local floor = CONFIG.replaceWeak and farmFloor() or 0
	local limit = math.min(carryCap(), math.max(free, 1))
	local taken = harvestZone(#ZONES, limit, floor)

	-- Empty pad: read the clock instead of flying back on a blind timer. Close
	-- to the spawn it is worth waiting the last seconds out right here, since
	-- one God brainrot outweighs a whole Cosmic trip.
	if taken == 0 then
		local left = godSecondsLeft()
		STATE.godIn = left or -1
		if left and left <= CONFIG.godWait then
			STATE.phase = string.format("waiting %ds for the God spawn", left)
			withPin(function() return ZONES[#ZONES].cf + Vector3.new(0, 5, 0) end, function()
				local deadline = os.clock() + left + 6
				while os.clock() < deadline and _G.__WINGSBR == generation do
					local spawner = spawnerFor(ZONES[#ZONES].name)
					if spawner and #spawner:GetChildren() > 0 then break end
					task.wait(0.5)
				end
			end)
			taken = harvestZone(#ZONES, limit, floor)
		elseif left then
			-- Come back just before it lands rather than every godEvery seconds.
			STATE.lastGod = os.clock() - CONFIG.godEvery + math.max(left - 8, 5)
			note(string.format("God brainrot in %ds", left))
		end
	end

	if taken > 0 then
		STATE.godTaken = STATE.godTaken + taken
		if full then
			for _ = 1, taken do
				if not removeWeakest() then break end
			end
		end
		goHomeAndPlace()
		if CONFIG.sellJunk then sellBackpackJunk() end
	end
end

-- Spending ------------------------------------------------------------------

-- price(level)  = BaseIncome * 1.5^(level-1)
-- gain(level)   = BaseIncome * mutation * 0.125 * 1.125^(level-1) * rebirthMult
-- so payback is independent of the brainrot's own size and only depends on its
-- mutation, its current level and the rebirth count. Ranking on price alone
-- would always pick the weakest brainrot on the plot, which is the exact
-- starvation pattern.
--
-- Both halves were checked against the server, not derived on paper: firing one
-- upgrade on a level 10 Blueberrinni charged exactly the predicted
-- $384,433,593 and paid +5,412,202/s against a predicted +3,608,134/s. The
-- factor between them is 1.5, which is the multiplier from one rebirth - the
-- income attribute already carries it, so the model has to as well or every
-- payback reads 50% too slow. rebirthMultiplier() is defined up with the value
-- model, because everything that compares two brainrots needs it.

-- Slots the server would not charge for, counted so a permanently unpriceable
-- one drops out of the ranking instead of holding the queue.
local refused = {}

local function upgradeCandidates()
	local out = {}
	local rebirthMult = rebirthMultiplier()
	eachSlot(function(floorName, slot, occupant)
		if not occupant then return end
		local name = occupant:GetAttribute("OriginalName")
		local level = occupant:GetAttribute("Level") or 1
		local mut = MUTATION[occupant:GetAttribute("Mutation") or "Normal"] or 1
		local base = baseIncomeOf(name)
		if base <= 0 then return end
		local price = base * (1.5 ^ (level - 1))
		local gain = base * mut * 0.125 * (1.125 ^ (level - 1)) * rebirthMult
		table.insert(out, {
			floor = floorName, slot = slot.Name, name = name, level = level,
			price = price, gain = gain, payback = price / math.max(gain, 1e-9),
		})
	end)
	table.sort(out, function(a, b) return a.payback < b.payback end)
	return out
end

function upgradeBestSlot()
	-- The candidate list is read off the placed models, so it is empty whenever
	-- the plot is streamed out. Wait for a moment at home rather than concluding
	-- there is nothing to upgrade.
	if not nearHome() then return false end
	local cash = money()
	for _, c in ipairs(upgradeCandidates()) do
		local key = c.floor .. "/" .. c.slot
		if refused[key] and refused[key] >= 3 then
			-- Three refusals is not a hiccup. Something about this slot does not
			-- fit the price model - a multiplier brainrot, a level cap - and it
			-- sits at the top of the payback ranking forever, so it is skipped
			-- rather than allowed to park the whole spending loop.
		elseif c.payback <= CONFIG.paybackCap and c.price <= cash then
			local beforeMoney, beforeIncome = money(), income()
			slotUpgrade:FireServer(c.floor, c.slot)
			task.wait(1.2)
			local spent = beforeMoney - money()
			local gained = income() - beforeIncome
			if spent > 0 then
				refused[key] = nil
				STATE.upgrades = STATE.upgrades + 1
				STATE.upgradeSpend = STATE.upgradeSpend + spent
				STATE.incomeAdded = STATE.incomeAdded + gained
				note(string.format("%s %s lvl%d: -%s -> +%s/s (%.0fs payback)",
					c.floor, c.slot, c.level, short(spent), short(gained),
					spent / math.max(gained, 1e-9)))
				return true
			end
			-- Charged nothing. Count it and move on to the next candidate in the
			-- same pass: returning here let one bad slot block every other
			-- upgrade in the game, and the loop then spent nothing at all while
			-- the note read "upgrade refused" over and over.
			refused[key] = (refused[key] or 0) + 1
			note("upgrade refused at " .. key .. " (" .. refused[key] .. ")")
		end
	end
	return false
end

local function rebirthRequirement()
	local base = (UpgradesConfig.Speed and UpgradesConfig.Speed.Base) or 20
	local ok, cost = pcall(RebirthConfig.GetCost, rebirths())
	return base + (ok and cost or 20)
end

local function flightSpeed()
	local base = (UpgradesConfig.Speed and UpgradesConfig.Speed.Base) or 20
	local growth = (UpgradesConfig.Speed and UpgradesConfig.Speed.GrowthPerLevel) or 1
	return base + (math.max(upgradeLevel("Speed"), 1) - 1) * growth
end

-- What the remaining speed ladder to the next rebirth costs. GetPrice takes
-- (level, amount) and already sums the levels, so one call is the whole ladder.
local function speedLadderCost()
	local need = rebirthRequirement()
	local missing = need - flightSpeed()
	if missing <= 0 then return 0, 0 end
	local ok, price = pcall(UpgradesConfig.Speed.GetPrice, upgradeLevel("Speed"), missing)
	if not ok or type(price) ~= "number" then return math.huge, missing end
	return price, missing
end

-- Rebirth is just another purchase and it has to be ranked like one.
--
-- It buys +0.5 on the multiplier, so at 8 rebirths going to 9 is 5.0 -> 5.5,
-- which is +10% of everything the plot earns. What it costs is the speed ladder
-- to the requirement - and speed prices grow 1.15 per level, so at level 178 a
-- single level already costs $8.65T. Measured at that point: ladder ~$43T
-- against +27.8B/s, so a payback near 1,550s, while slot upgrades were still
-- paying back inside 240s. Buying speed on a timer regardless, which is what
-- the first version did, spends the money that should have gone into levels.
local function rebirthPayback()
	local cost = speedLadderCost()
	local now = rebirthMultiplier()
	local ok, nextMult = pcall(RebirthConfig.GetMultiplier, rebirths() + 1)
	if not ok or type(nextMult) ~= "number" then nextMult = now + 0.5 end
	local gain = income() * ((nextMult / math.max(now, 0.001)) - 1)
	if gain <= 0 then return math.huge end
	return cost / gain
end

local function bestSlotPayback()
	local list = upgradeCandidates()
	for _, c in ipairs(list) do
		local key = c.floor .. "/" .. c.slot
		if not (refused[key] and refused[key] >= 3) then return c.payback, c end
	end
	return math.huge, nil
end

-- Speed is the rebirth gate and nothing else - the loop teleports, so the flight
-- value itself is worthless. Early it is free (levels 4 -> 21 cost $22,021 in
-- total) and gets bought without thinking; late it is the most expensive thing
-- in the game and only gets bought when the rebirth it unlocks beats the best
-- slot level available.
local function buySpeedTowardRebirth()
	local need = rebirthRequirement()
	STATE.rebirthNeed = need
	STATE.flightSpeed = flightSpeed()
	if flightSpeed() >= need then return end

	local cost = speedLadderCost()
	STATE.speedCost = cost
	local trivial = cost <= money() * 0.02
	if not trivial then
		local slotPayback = bestSlotPayback()
		local rp = rebirthPayback()
		STATE.rebirthPayback, STATE.slotPayback = rp, slotPayback
		-- A slot level that pays for itself faster wins. Only when the plot has
		-- run out of cheap levels does the multiplier become the better buy.
		if slotPayback <= math.min(rp, CONFIG.paybackCap) then
			STATE.phase = "levels beat rebirth"
			return
		end
	end

	local guard = 0
	while flightSpeed() < need and guard < 40 and _G.__WINGSBR == generation do
		local before = money()
		upgradeRequested:FireServer("Speed", 1)
		task.wait(0.2)
		if money() >= before then break end   -- refused: cannot afford it
		guard = guard + 1
	end
	STATE.flightSpeed = flightSpeed()
end

local function buyCarry()
	local maxLevel = (UpgradesConfig.Carry and UpgradesConfig.Carry.MaxLevel) or 6
	local level = upgradeLevel("Carry")
	if level >= maxLevel then return false end
	local ok, price = pcall(UpgradesConfig.Carry.GetPrice, level, 1)
	if not ok or type(price) ~= "number" then return false end
	-- Carry buys trips, not income. It only gets the surplus that the upgrade
	-- ladder has no use for, so it can never starve a slot upgrade.
	if price > money() * 0.25 then return false end
	local before = money()
	upgradeRequested:FireServer("Carry", 1)
	task.wait(0.8)
	if money() < before then
		note("carry -> level " .. upgradeLevel("Carry"))
		return true
	end
	return false
end

local function buyStamina()
	local level = math.max(upgradeLevel("Stamina"), 1)
	local ok, price = pcall(UpgradesConfig.Stamina.GetPrice, level, 1)
	if not ok or type(price) ~= "number" or price > money() * 0.1 then return false end
	upgradeRequested:FireServer("Stamina", 1)
	task.wait(0.5)
	return true
end

local function maxBaseUpgrade()
	-- $250K then $1M, and it is what unlocks Floor2 and Floor3. Fired twice with
	-- a check in between; the label reads MAX afterwards.
	for _ = 1, 2 do
		local before = money()
		baseUpgrade:FireServer()
		task.wait(1)
		if money() >= before then break end
		note("base upgrade bought")
	end
end

local function rebirthOnce()
	if flightSpeed() < rebirthRequirement() then return false end
	local before = { rb = rebirths(), inc = income() }
	rebirthRemote:FireServer()
	task.wait(2.5)
	if rebirths() > before.rb then
		STATE.rebirthsDone = STATE.rebirthsDone + 1
		note(string.format("rebirth %d -> %d, income %s/s -> %s/s",
			before.rb, rebirths(), short(before.inc), short(income())))
		return true
	end
	note("rebirth refused")
	return false
end

-- Rebirth resets Speed to level 1, so the requirement for the NEXT one is
-- immediately affordable again once the income has paid for the ladder - and
-- that ladder is trivial: levels 4 to 21 cost $22,021 in total. Waiting a full
-- loop interval between rebirths wastes the multiplier, so each success buys
-- the speed back and tries again in the same pass.
local function doRebirth()
	local did = false
	for _ = 1, 6 do
		if _G.__WINGSBR ~= generation then break end
		buySpeedTowardRebirth()
		if flightSpeed() < rebirthRequirement() then break end
		-- Rebirth wipes the balance, so anything still sitting there is about to
		-- be thrown away. Turn it into slot levels first - they survive.
		for _ = 1, 6 do
			if not upgradeBestSlot() then break end
		end
		if not rebirthOnce() then break end
		did = true
		task.wait(0.5)
	end
	return did
end

-- Free money ----------------------------------------------------------------

-- Passing the index to TimeRewardClaimed does nothing; the panel's own button
-- handler is what claims. Verified +$1,000 on the first entry.
local function claimTimeRewards()
	local gui = plr:FindFirstChild("PlayerGui")
	local frames = gui and gui:FindFirstChild("GUI") and gui.GUI:FindFirstChild("Frames")
	local container = frames and frames:FindFirstChild("TimeRewards")
	container = container and container:FindFirstChild("Container")
	if not container then return 0 end
	local before = money()
	local fired = 0
	for i = 1, 12 do
		local entry = container:FindFirstChild(tostring(i))
		local button = entry and entry:FindFirstChild("Button")
		if button then
			local ok, conns = pcall(getconnections, button.Activated)
			if ok and conns then
				for _, c in ipairs(conns) do pcall(function() c:Fire() end) end
				fired = fired + 1
			end
		end
		task.wait(0.15)
	end
	task.wait(1)
	local gained = money() - before
	if gained > 0 then
		STATE.rewards = STATE.rewards + 1
		note("time rewards +" .. short(gained))
	end
	return gained
end

local function claimFreeBrainrot()
	if plr:GetAttribute("IsFirstBrainrotClaimed") then return false end
	freeBrainrot:FireServer()
	task.wait(1)
	return true
end

-- Selling is the only way to clear a full plot without losing the trip, and it
-- is position gated: the prompts sit on Workspace.Sell.ProxPart, 13 studs.
local function sellEquipped()
	local sell = workspace:FindFirstChild("Sell")
	local prox = sell and sell:FindFirstChild("ProxPart")
	if not prox then return 0 end
	local before = money()
	withPin(function() return sell:GetPivot() + Vector3.new(0, 5, 0) end, function()
		task.wait(1.2)
		local prompt = prox:FindFirstChild("SellEquipped")
		if prompt then pcall(function() fireproximityprompt(prompt) end) end
		task.wait(1)
	end)
	local gained = money() - before
	if gained > 0 then
		STATE.sold = STATE.sold + 1
		note("sold spare for " .. short(gained))
	end
	return gained
end

-- Loops ---------------------------------------------------------------------

local function loop(interval, key, fn)
	task.spawn(function()
		while _G.__WINGSBR == generation do
			if CONFIG[key] then
				local ok, err = pcall(fn)
				if not ok then note(tostring(key) .. ": " .. tostring(err)) end
			end
			task.wait(interval)
		end
	end)
end

-- Stats refresh, always on: the panel reads nothing but STATE.
task.spawn(function()
	while _G.__WINGSBR == generation do
		STATE.money = money()
		STATE.income = income()
		STATE.rebirths = rebirths()
		STATE.speedLevel = upgradeLevel("Speed")
		STATE.carryLevel = upgradeLevel("Carry")
		STATE.flightSpeed = flightSpeed()
		STATE.rebirthNeed = rebirthRequirement()
		if STATE.startIncome == 0 and STATE.income > 0 then
			STATE.startIncome = STATE.income
		end
		slotCensus()
		task.wait(1)
	end
end)

loop(1, "autoFarm", function()
	withUI("farm", function()
		if CONFIG.godWatch then godCheck() end
		farmCycle()
	end)
end)

loop(CONFIG.collectEvery, "autoCollect", function()
	-- Collecting does not move the character, so it does not need the mutex.
	collectPlot()
end)

loop(3, "autoSlotUpgrade", function()
	upgradeBestSlot()
end)

loop(3, "autoSpeed", function()
	buySpeedTowardRebirth()
end)

loop(15, "autoCarry", function()
	buyCarry()
end)

loop(20, "autoStamina", function()
	buyStamina()
end)

-- No withUI here on purpose. Rebirth and the speed ladder are plain remotes
-- with no position check, and the farm loop holds the interface mutex almost
-- continuously - routing rebirth through it meant the requirement sat at 60/60
-- for minutes while the farm kept the lock and rebirthsDone stayed 0.
loop(4, "autoRebirth", function()
	if flightSpeed() >= rebirthRequirement() then
		doRebirth()
	end
end)

loop(60, "autoTimeRewards", function()
	claimTimeRewards()
end)

loop(120, "autoFreeBrainrot", function()
	claimFreeBrainrot()
end)

-- Blocks arrive from the time reward ladder (Lava at 5 and 12 minutes, Hacker at
-- 20, Dragon at 40) and from the Battle Pass free track, which hands out five of
-- them. Opening takes the character's hands for a moment, so it goes through the
-- mutex like anything else that touches the body.
loop(45, "autoLuckyBlock", function()
	local hasBlock = false
	for _, tool in ipairs(plr.Backpack:GetChildren()) do
		if isBlock(tool) then hasBlock = true end
	end
	if not hasBlock then return end
	withUI("lucky block", function()
		if not nearHome() then pin(homeCFrame(), 0.8) end
		openLuckyBlocks()
		placeGoodRewards()
	end)
end)

loop(30, "sellSpare", function()
	if carriedCount() > 0 and STATE.freeSlots <= 0 then
		withUI("sell", function() sellEquipped() end)
	end
end)

-- Panel ---------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("wingsbrainrots", CONFIG)

local win = UI.Window({
	name = PANEL_NAME,
	title = "WINGS", accentTitle = "BRAINROTS", subtitle = "seltonmt",
	badge = "🦅", width = 920, height = 580,
})
_G.__WINGSBR_WIN = win

local farmPage = win:Page("FARM", UI.icon.bolt)
local basePage = win:Page("BASE", UI.icon.grid)
local infoPage = win:Page("INFO", UI.icon.list)

local zoneNames = {}
for _, z in ipairs(ZONES) do table.insert(zoneNames, z.name) end

local farmCard = farmPage:Card("FARM LOOP", 1)
farmCard:Toggle("Auto farm", CONFIG.autoFarm, function(v) CONFIG.autoFarm = v end,
	"fly out, pick up, carry home, place")
farmCard:Toggle("God zone watch", CONFIG.godWatch, function(v) CONFIG.godWatch = v end,
	"timed event spawn, 1B base income each")
farmCard:Dropdown("Zone choice", { "deepest that spawns", "fixed zone" },
	"deepest that spawns", function(v)
		CONFIG.zoneMode = (v == "fixed zone") and 2 or 1
	end)
farmCard:Dropdown("Fixed zone", zoneNames, ZONES[CONFIG.zone].name, function(v)
	for i, z in ipairs(ZONES) do if z.name == v then CONFIG.zone = i end end
end)
farmCard:Toggle("Replace weak brainrots", CONFIG.replaceWeak,
	function(v) CONFIG.replaceWeak = v end,
	"full plot pulls its worst one out for a better one")
farmCard:Toggle("Sell what was pulled out", CONFIG.sellJunk,
	function(v) CONFIG.sellJunk = v end,
	"one tool at a time, never SellInventory - blocks live there too")
farmCard:Toggle("Sell spare when full", CONFIG.sellSpare, function(v) CONFIG.sellSpare = v end,
	"walks to the seller, prompt is position gated", UI.theme.warn)

local collectCard = farmPage:Card("CASH", 2)
collectCard:Toggle("Auto collect", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
	"touches every slot, works from any distance")
collectCard:Slider("Collect every (s)", 3, 30, CONFIG.collectEvery, function(v)
	CONFIG.collectEvery = v
end)
collectCard:Button("Collect now", function()
	task.spawn(function()
		local gained = collectPlot()
		note("collected " .. short(gained))
	end)
end)

local upgradeCard = basePage:Card("BRAINROT LEVELS", 1)
upgradeCard:Toggle("Auto upgrade slots", CONFIG.autoSlotUpgrade,
	function(v) CONFIG.autoSlotUpgrade = v end,
	"ranked by payback, never by the stand's price label")
upgradeCard:Slider("Payback cap (s)", 30, 600, CONFIG.paybackCap, function(v)
	CONFIG.paybackCap = v
end)
upgradeCard:Button("Upgrade best once", function()
	task.spawn(function() upgradeBestSlot() end)
end)
upgradeCard:Button("Max base upgrade ($1.25M)", function()
	task.spawn(function() maxBaseUpgrade() end)
end, UI.theme.warn)

local statCard = basePage:Card("STATS", 2)
statCard:Toggle("Auto speed", CONFIG.autoSpeed, function(v) CONFIG.autoSpeed = v end,
	"the rebirth gate, cheap - $22K to reach 40")
statCard:Toggle("Auto carry", CONFIG.autoCarry, function(v) CONFIG.autoCarry = v end,
	"more brainrots per trip, max level 6")
statCard:Toggle("Auto stamina", CONFIG.autoStamina, function(v) CONFIG.autoStamina = v end,
	"flight only - the loop teleports, so this is near useless")
statCard:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
	"resets speed/stamina/money, keeps every brainrot, x1.5 cash", UI.theme.warn)
statCard:Button("Rebirth now", function()
	task.spawn(function() doRebirth() end)
end, UI.theme.warn)

local freeCard = farmPage:Card("FREE", 0)
freeCard:Toggle("Auto time rewards", CONFIG.autoTimeRewards,
	function(v) CONFIG.autoTimeRewards = v end,
	"12 step ladder up to $500M and a Dragon block")
freeCard:Toggle("Claim free brainrot", CONFIG.autoFreeBrainrot,
	function(v) CONFIG.autoFreeBrainrot = v end, "one Matteo, once per account")
freeCard:Toggle("Auto open lucky blocks", CONFIG.autoLuckyBlock,
	function(v) CONFIG.autoLuckyBlock = v end,
	"tool:Activate() opens them; reward lands after ~5s")
freeCard:Button("Claim rewards now", function()
	task.spawn(function() claimTimeRewards() end)
end)
freeCard:Button("Open blocks now", function()
	task.spawn(function()
		withUI("lucky block", function()
			if not nearHome() then pin(homeCFrame(), 0.8) end
			openLuckyBlocks()
			placeGoodRewards()
		end)
	end)
end)

local readout = infoPage:Card("LIVE", 0):Readout(20)

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste -
-- er ist immer das erste Icon und die Seite, auf der das Panel aufgeht.
pcall(function() win:Home() end)

win:Refresh()

task.spawn(function()
	while _G.__WINGSBR == generation do
		local runtime = math.max(os.clock() - STATE.startedAt, 1)
		win:SetStatus(string.format("$%s   %s/s   rb %d   speed %d/%d   slots %d/%d   %s",
			short(STATE.money), short(STATE.income), STATE.rebirths,
			STATE.flightSpeed, STATE.rebirthNeed,
			STATE.usedSlots, STATE.usedSlots + STATE.freeSlots, STATE.phase))
		readout:set({
			"ECONOMY",
			string.format("  money      $%s", short(STATE.money)),
			string.format("  income     %s/s", short(STATE.income)),
			string.format("  gained     %s/s since start", short(STATE.income - STATE.startIncome)),
			string.format("  collected  %s in %d passes", short(STATE.collectedCash), STATE.collected),
			"FARM",
			string.format("  zone       %s", STATE.zone),
			string.format("  picked     %d   placed %d   god %d (next in %s)",
				STATE.picked, STATE.placed, STATE.godTaken,
				STATE.godIn >= 0 and (STATE.godIn .. "s") or "?"),
			string.format("  carry      %d/%d per trip", carriedCount(), carryCap()),
			string.format("  slots      %d used, %d free", STATE.usedSlots, STATE.freeSlots),
			string.format("  swaps      %d replaced, %d sold, %d too weak to take",
				STATE.replaced, STATE.sold, STATE.skipped),
			string.format("  blocks     %d opened, %d in the bag",
				STATE.blocksOpened, (function()
					local n = 0
					for _, t in ipairs(plr.Backpack:GetChildren()) do
						if isBlock(t) then n = n + 1 end
					end
					return n
				end)()),
			string.format("  base       worst %s/s, best %s/s over %d slots",
				short(STATE.baseWorst), short(STATE.baseBest), slotMap.count),
			string.format("  decision   level %.0fs vs rebirth %.0fs, ladder %s",
				STATE.slotPayback, STATE.rebirthPayback, short(STATE.speedCost)),
			"SPENDING",
			string.format("  upgrades   %d for %s", STATE.upgrades, short(STATE.upgradeSpend)),
			string.format("  rebirths   %d done, need speed %d", STATE.rebirthsDone, STATE.rebirthNeed),
			string.format("  runtime    %dm", math.floor(runtime / 60)),
			"NOTE",
			"  " .. tostring(STATE.note),
		})
		task.wait(1)
	end
end)

_G.__WINGSBR_DBG = {
	CONFIG = CONFIG, STATE = STATE, ZONES = ZONES, MUTATION = MUTATION,
	collectPlot = collectPlot, harvestZone = harvestZone,
	goHomeAndPlace = goHomeAndPlace, farmCycle = farmCycle, godCheck = godCheck,
	upgradeCandidates = upgradeCandidates, upgradeBestSlot = upgradeBestSlot,
	buySpeedTowardRebirth = buySpeedTowardRebirth, buyCarry = buyCarry,
	doRebirth = doRebirth, rebirthOnce = rebirthOnce, claimTimeRewards = claimTimeRewards,
	removeWeakest = removeWeakest, weakestPlaced = weakestPlaced,
	rebuildSlotMap = rebuildSlotMap, slotMap = slotMap,
	bestSlotPayback = bestSlotPayback, rebirthPayback = rebirthPayback,
	speedLadderCost = speedLadderCost, nearHome = nearHome,
	sellBackpackJunk = sellBackpackJunk, farmFloor = farmFloor,
	openLuckyBlocks = openLuckyBlocks, placeGoodRewards = placeGoodRewards,
	placeToolIntoWorstSlot = placeToolIntoWorstSlot, isBlock = isBlock,
	sellEquipped = sellEquipped, maxBaseUpgrade = maxBaseUpgrade,
	itemIncome = itemIncome, slotCensus = slotCensus, homeCFrame = homeCFrame,
}

print("[wingsbrainrots] loaded (gen " .. generation .. ") - RightShift toggles the panel")
