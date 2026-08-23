--!nocheck
-- [💎] Sell Ores ⛏️ - by seltonmt
--
-- Place 122572082932179. Loop: pull the roller lever, buy the rolled ore onto a
-- pedestal, let the drills fill a crate, pick the crate up, sell it, spend the
-- money on upgrades.
--
-- Everything below was measured through the bridge:
--
--   * The game fires no RemoteEvents for player actions. A full manual run was
--     recorded with a __namecall hook AND hookfunction on both FireServer and
--     InvokeServer - all three verified against self-tests - and not one call
--     appeared. Every action is either a ProximityPrompt or a SurfaceGui button
--     out in the world.
--   * Prompts are validated against the server's copy of the character, so the
--     position has to be held for a moment before firing, exactly like the other
--     prompt-driven games.
--   * SurfaceGui buttons on the base boards DO expose their Activated
--     connection, so upgrades are bought by firing those.
--   * BaseCrateStateChanged arrives every ~2.7s with the whole base state
--     (furnace, carried crate, crate count) and is the only reliable oracle.
--   * Base ownership is a plain attribute: Bases.BaseN.OwnerUserId.
--
-- Robux buttons are never touched. On the boards they are the ones priced
-- without a dollar sign (49, 19, 79, 399, 999).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local plr = Players.LocalPlayer

local CONFIG = {
	autoRoll = false,        -- pull the lever and buy what it rolls
	autoBuyOre = true,       -- buy the rolled ore onto a free pedestal
	autoEquip = false,       -- re-stock every tunnel with the best ores owned
	-- An ore is bought when it earns its price back inside maxPayback seconds,
	-- or when it is at least this rare, or when it belongs to a live event.
	maxPayback = 1800,       -- 30 minutes
	keepRarityRank = 5,      -- Legendary and above (see OreMetadata.RarityRank)
	waitForOreFactor = 3,    -- hold the lever while a wanted ore costs under 3x balance
	waitForEventOreFactor = 50, -- ...and far longer for event, mutated or rare drops
	eventWindow = 300,       -- seconds an announced event counts as still running
	-- Furnace throughput guards. It must be able to digest at least this share
	-- of current income, and never hold more than this many seconds of backlog,
	-- or crates are sold directly instead.
	furnaceBonus = 1.5,      -- "Furnace gives +50% money", straight off its board
	furnaceMaxBacklog = 120,
	-- An ore costing less than this many seconds of income is bought without
	-- any further argument - it cannot meaningfully cost us anything.
	trivialSeconds = 4,
	eventPaybackFactor = 2, -- an event drop may take twice as long to repay
	maxSpinsPerRound = 25,   -- banked lucky spins to burn through per pass
	-- A rare roll is only worth sitting on if the projected income actually gets
	-- there. Measured over incomeWindow seconds, it must be affordable within
	-- reachWithin seconds or the lever is pulled anyway.
	incomeWindow = 600,      -- rolling window used to measure income
	reachWithin = 600,       -- how far ahead we are willing to project
	autoPickup = false,      -- take the finished crate
	autoSell = false,        -- sell it at the table
	-- ON by default. Executing this file is meant to be the whole action: the
	-- farm loop lives inside the client and does not need the bridge, so a run
	-- must never sit idle waiting for someone to flip a switch from outside.
	-- Turn it off in the panel if you want to play by hand.
	auto = true,             -- one switch: runs the whole loop in order
	autoUpgrade = false,     -- drill speed / yield / regen, per floor, via remote
	autoRoller = false,      -- ore luck / extra rolling pedestals
	autoTunnels = false,     -- buy every affordable drill tunnel
	autoFloors = false,      -- unlock the next floor when it is affordable
	autoFurnace = false,     -- buy and upgrade the +50% furnace
	autoBoost = false,       -- unlock the money-boost showcase pedestals
	-- Growth gems boost ore regeneration, which is what every drone is waiting
	-- on, and they apply themselves on purchase. At the measured income the small
	-- one returns 24x its price, so this is now part of the master switch.
	autoGear = true,
	gemMinReturn = 3,        -- only buy a gem worth at least this many times its price
	-- On by default: pure remote calls for money already earned, no walking, no
	-- spending and nothing that can fail into a purchase prompt.
	autoRewards = true,      -- daily / playtime / offline / lucky spin
	maxUpgradesPerRound = 60,
	-- No payback ceiling on the drill boards. The maths says a level-25 Drill
	-- Yield needs 11,428s against 425s for a rolled Platinum, but every ceiling
	-- tried here ended with floors sitting half upgraded for hours, and the
	-- linear model cannot see that all four drones idle on OreNotReady. The
	-- ranking still buys the best one first; it just no longer refuses.
	maxUpgradePayback = math.huge,
	-- The per-tunnel ore levels DO keep a ceiling - they repay in ~50s, so
	-- anything slow there really is the wrong step to buy.
	maxOreLevelPayback = 3600,
	-- How much more a Regen level counts on a floor whose drone is waiting for
	-- ore to grow back (and how much less a Yield level counts there).
	--
	-- Neutral by default. At 4 it did what it was designed to do far too well:
	-- every floor reports OreNotReady, so Regen was worth 16x a Yield level and
	-- five upgrades in a row were all Ore Regen while Floor 2 sat at Drill Yield
	-- 20 and Floor 4 had never bought Drill Speed at all. The boards are meant to
	-- fill out evenly, so the tilt is off unless deliberately raised.
	regenBoost = 1,
	autoOreLevel = false,    -- raise the per-tunnel ore levels
	maxOreLevelsPerRound = 40,
	spendFraction = 0.6,     -- share of the balance a single upgrade may cost
	-- Seconds the character is pinned before a prompt is fired. Measured against
	-- the balance actually moving, three pickup+sell pairs per setting:
	--   1.20s -> 3/3 in 12.4s      0.40s -> 3/3 in 7.6s
	--   0.15s -> 3/3 in  6.1s      0.05s -> 1/3 (too fast, server misses it)
	-- 0.2 keeps a margin over the point where it starts failing and still halves
	-- the time the old value cost.
	settleTime = 0.2,
	cycleWait = 1.0,
	spendEvery = 8,          -- seconds between spending rounds
}

local STATE = {
	money = 0, moneyText = "$0",
	rolls = 0, oresBought = 0, pickups = 0, sells = 0, upgrades = 0,
	rollerUpgrades = 0, tunnels = 0, floors = 0, spins = 0, gear = 0,
	equips = 0, inventory = 0, drops = 0, furnaceLevel = 0, furnaceSkip = nil,
	oreLevels = 0,
	earned = 0, phase = "idle", note = "-", base = "-",
	crateCount = 0, carrying = "-",
}

_G.__SELLORES = (_G.__SELLORES or 0) + 1
local generation = _G.__SELLORES
if _G.__SELLORES_GUI then pcall(function() _G.__SELLORES_GUI:Destroy() end) end

local function shortNumber(n)
	n = tonumber(n) or 0
	for _, unit in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= unit[1] then return string.format("%.1f%s", n / unit[1], unit[2]) end
	end
	return tostring(math.floor(n))
end

-- "$3,286" / "$1.2K" -> number
local function parseMoney(text)
	if type(text) ~= "string" then return nil end
	local cleaned = text:gsub(",", "")
	local number, suffix = cleaned:match("%$%s*([%d%.]+)%s*(%a?)")
	if not number then return nil end
	number = tonumber(number)
	if not number then return nil end
	local scale = ({ K = 1e3, M = 1e6, B = 1e9, T = 1e12 })[suffix:upper()] or 1
	return number * scale
end

local function rootPart()
	local char = plr.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Decision log ------------------------------------------------------------------
--
-- Every decision that spends money or throws a roll away writes one timestamped
-- line here. This is the only way to check afterwards whether the script judged
-- correctly - the footer shows a single note and it is gone a second later, and
-- a counter the script increments itself has already been wrong three times in
-- this project. Read it from the bridge with:
--
--   python bridge.py exec "return _G.__SELLORES_DBG.tail(40)"
--
-- and it is mirrored to sellores-log.txt when the executor can write files.
local LOG = {}

local function logLine(category, text)
	local stamp = os.date("%H:%M:%S")
	local line = string.format("%s [%s] %s", stamp, category, text)
	table.insert(LOG, line)
	if #LOG > 400 then table.remove(LOG, 1) end
	return line
end

local function tailLog(count)
	local out = {}
	local from = math.max(1, #LOG - (count or 30) + 1)
	for i = from, #LOG do out[#out + 1] = LOG[i] end
	return out
end

-- Remote helpers. Kept up here on purpose: a local is invisible to every
-- function defined above it, and putting these next to their first heavy user
-- further down once made equipBest() resolve to nil at runtime.
local function remoteNamed(name)
	local remote = ReplicatedStorage:FindFirstChild(name, true)
	if remote and (remote:IsA("RemoteFunction") or remote:IsA("RemoteEvent")) then return remote end
	return nil
end

local function invoke(name, ...)
	local remote = remoteNamed(name)
	if not remote then return nil end
	local args = table.pack(...)
	local ok, response = pcall(function() return remote:InvokeServer(table.unpack(args, 1, args.n)) end)
	if not ok then return nil end
	return response
end

-- Base --------------------------------------------------------------------------

local myBase = nil

local function findBase()
	if myBase and myBase.Parent then return myBase end
	for _, base in ipairs(workspace.Bases:GetChildren()) do
		if base:GetAttribute("OwnerUserId") == plr.UserId then
			myBase = base
			STATE.base = base.Name
			return base
		end
	end
	STATE.note = "own base not found"
	return nil
end

-- Money -------------------------------------------------------------------------
-- leaderstats holds a formatted string ("$8,514"), so the number is parsed out of
-- it rather than read directly.

local function refreshMoney()
	local stats = plr:FindFirstChild("leaderstats")
	local money = stats and stats:FindFirstChild("Money")
	if not money then return end
	STATE.moneyText = tostring(money.Value)
	STATE.money = parseMoney(STATE.moneyText) or STATE.money
end

-- The base state the server pushes; the only trustworthy view of the furnace and
-- the crate the character is carrying.
do
	local stateEvent = ReplicatedStorage:FindFirstChild("Remotes")
	stateEvent = stateEvent and stateEvent:FindFirstChild("BaseCrateStateChanged", true)
	if stateEvent then
		stateEvent.OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" then return end
			STATE.crateCount = tonumber(payload.CrateCount) or STATE.crateCount
			STATE.carrying = tostring(payload.CarriedCrateType or "-")
		end)
	end
end

-- Interaction -------------------------------------------------------------------

-- Prompts only go through once the server sees the character standing there, so
-- the position is pinned on Heartbeat for a moment and then released.
local function usePrompt(prompt)
	if not prompt or not prompt.Enabled or not fireproximityprompt then return false end

	local part = prompt.Parent
	if not (part and part:IsA("BasePart")) then
		part = prompt:FindFirstAncestorWhichIsA("BasePart")
	end
	local hrp = rootPart()
	if not part or not hrp then return false end

	local anchor = part.Position + Vector3.new(0, 3, 0)
	local hold = RunService.Heartbeat:Connect(function()
		local root = rootPart()
		if root then root.CFrame = CFrame.new(anchor) end
	end)

	task.wait(CONFIG.settleTime)
	local fired = false
	if prompt.Enabled then
		fireproximityprompt(prompt)   -- once: these prompts toggle
		fired = true
	end
	task.wait(0.4)
	hold:Disconnect()
	return fired
end

local function fireButton(button)
	if not button or not getconnections then return false end
	local fired = false
	for _, connection in pairs(getconnections(button.Activated)) do
		pcall(function() connection:Fire() end)
		fired = true
	end
	return fired
end

local function promptAt(base, path, name)
	local node = base
	for segment in string.gmatch(path, "[^%.]+") do
		node = node and node:FindFirstChild(segment)
	end
	return node and node:FindFirstChild(name, true) or nil
end

-- Actions -----------------------------------------------------------------------

local function roll()
	local base = findBase()
	local lever = base and base:FindFirstChild("Roller")
	lever = lever and lever:FindFirstChild("Lever")
	local prompt = lever and lever:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt then return false end

	if usePrompt(prompt) then
		STATE.rolls += 1
		STATE.phase = "rolled"
		return true
	end
	return false
end

-- Ore value ----------------------------------------------------------------------
--
-- OreMetadata.ByName holds the whole economy: seedCost, baseIncome,
-- growTimeSeconds, rarity and an eventType on the ores that only appear during
-- a live event. Income per second is baseIncome / growTimeSeconds, so the honest
-- measure of an ore is how long it takes to earn its own price back.
--
-- Measured across all 70 ores, that ranking is the opposite of what the rarity
-- colours suggest: Stone Ore pays for itself in 100s, Coal in 175s, Copper and
-- Tin in 250s, while Amber needs 45 minutes, Emerald 2.7 hours and Platinum
-- almost 4. Buying the shiny expensive roll is a worse deal per dollar than
-- buying the cheap one - so the cheap ores are bought on sight and the expensive
-- ones only when they are genuinely rare or part of an event.
local ORES = select(2, pcall(function()
	return require(ReplicatedStorage:WaitForChild("OreMetadata", 10))
end))
if type(ORES) ~= "table" then ORES = {} end

local function oreInfo(name)
	return ORES.ByName and ORES.ByName[name] or nil
end

local function orePayback(name)
	local info = oreInfo(name)
	if not info then return math.huge end
	local rate = (tonumber(info.baseIncome) or 0) / (tonumber(info.growTimeSeconds) or 1)
	if rate <= 0 then return math.huge end
	return (tonumber(info.seedCost) or math.huge) / rate
end

-- Events.
--
-- AdminEventClockState is NOT the detector. It reported active = false while a
-- GiantUFO was hovering over the map dropping ore, so it only tracks the
-- scheduled admin events. What actually says an event is running is the model in
-- the workspace: ReplicatedStorage.EventModels lists GiantUFO, BlackHole,
-- CrystalEvent, GalaxyEvent, BlizzardPart and RainPart, and the live copy is
-- parented to the workspace with an "Active" prefix.
local EVENT_MODELS = { "GiantUFO", "BlackHole", "CrystalEvent", "GalaxyEvent", "BlizzardPart", "RainPart" }
local EVENT = { active = false, id = "", title = "", mutation = "", startedAt = 0 }

local function eventModelPresent()
	for _, child in ipairs(workspace:GetChildren()) do
		for _, hint in ipairs(EVENT_MODELS) do
			if string.find(child.Name, hint, 1, true) then return child.Name end
		end
	end
	return nil
end

do
	local clock = ReplicatedStorage:FindFirstChild("Remotes")
	clock = clock and clock:FindFirstChild("AdminEventClockState", true)
	if clock and clock:IsA("RemoteEvent") then
		clock.OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" then return end
			EVENT.id = tostring(payload.eventId or "")
			EVENT.title = tostring(payload.eventTitle or "")
		end)
	end

	-- The best signal of all: when an event starts the server announces it on
	-- AlienEventDialogue with the mutation it hands out, e.g.
	-- {durationSeconds = 2, title = "RUST STORM EVENT", mutationName = "Rusty"}.
	-- Despite the name it is not Alien-specific.
	local dialogue = ReplicatedStorage:FindFirstChild("Remotes")
	dialogue = dialogue and dialogue:FindFirstChild("AlienEventDialogue", true)
	if dialogue and dialogue:IsA("RemoteEvent") then
		dialogue.OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" then return end
			EVENT.title = tostring(payload.title or EVENT.title)
			EVENT.mutation = tostring(payload.mutationName or "")
			EVENT.startedAt = os.clock()
			STATE.note = string.format("%s -> %s mutation",
				EVENT.title, EVENT.mutation ~= "" and EVENT.mutation or "?")
		end)
	end
end

-- Pulling the lever makes the server broadcast RollerRollEvent, which spells out
-- exactly what landed on every pedestal: {pedestalName, oreName, rarity,
-- seedCost}. seedCost is the purchase price, so the price never has to be
-- scraped off a label at all.
local ROLLED = {}

-- The weakest ore currently sitting in a tunnel, in income per second. Every
-- tunnel is full, so a new ore is only worth buying if it beats the one it would
-- replace - a 250 dollar Coal is a fine first purchase and a waste of a slot
-- once the drills are running Silver. EquipBest reports the whole loadout, so
-- this floor rises by itself as the base improves and never needs tuning.
-- worstRate/totalRate are in the metadata's own units (baseIncome per second of
-- grow time). Real money runs far ahead of that because every drill multiplier,
-- floor upgrade and furnace bonus sits on top - 21 drills summing to ~84 of
-- these units were producing 5,203 dollars a second. So the units are converted
-- with a scale measured from the two numbers we already have, rather than
-- guessed: scale = measured income / summed base rate.
local LOADOUT = { worstRate = 0, totalRate = 0, count = 0, perFloor = {} }

-- Money earned per second, from a rolling window of the last few minutes. It has
-- to be declared up here because oreWanted reads it, and a local declared below
-- its reader resolves to a nil global at runtime - this file has now hit that
-- trap twice.
local INCOME = { samples = {}, perSecond = 0 }

-- What the roll step is currently holding out for, set by pendingWorthKeeping
-- and read by the reserve helpers far below. Saving for an ore while every other
-- routine spends the balance is incoherent: it waits forever and never buys the
-- thing it was waiting for. Declared here because pendingWorthKeeping is defined
-- above the reserves that consume it.
local SAVING = { cost = 0, ore = nil }

local function oreRate(name)
	local info = oreInfo(name)
	if not info then return 0 end
	return (tonumber(info.baseIncome) or 0) / (tonumber(info.growTimeSeconds) or 1)
end

-- Is this roll worth paying for? Returns the verdict and the reason, which goes
-- straight into the footer so every purchase explains itself.
local function oreWanted(result)
	local info = oreInfo(result.oreName)
	if info and info.eventType then return true, "event " .. tostring(info.eventType) end

	-- A mutation multiplies what the ore is worth (Rusty x1.5 up to Galaxy x5),
	-- so a mutated roll is taken whatever the base numbers say.
	if result.mutation and result.mutation ~= "" then
		return true, "mutated " .. tostring(result.mutation)
	end

	-- Once every tunnel is full, anything that would not displace the weakest
	-- drill is dead weight however fast it pays for itself. This check sits
	-- ABOVE the event rule on purpose: during an event everything counted as
	-- wanted, which quietly disabled the filter and let 250 dollar Coal back in.
	-- Can it ever reach a drill? Every tunnel is full, so an ore that does not
	-- beat the weakest slot will sit in the inventory forever.
	--
	-- This check comes FIRST, before the cheap-ore shortcut. That order matters:
	-- with the weakest slot running an 18.9/s ore, Stone at 1.0, Coal at 1.4,
	-- Silver at 3.3 and even Amber at 5.6 are all unequippable - and the shortcut
	-- was buying every one of them on sight because they each cost under a second
	-- of income. Cheap and useless is still useless.
	local rate = oreRate(result.oreName)
	if LOADOUT.count > 0 and rate <= LOADOUT.worstRate then
		return false, string.format("weaker than every tunnel (%.1f/s vs %.1f/s)",
			rate, LOADOUT.worstRate)
	end

	-- Past that bar, anything costing a rounding error of income is taken without
	-- further argument - it will displace something the moment EquipBest runs.
	local cost = tonumber(result.seedCost) or math.huge
	if INCOME.perSecond > 0 and cost <= INCOME.perSecond * CONFIG.trivialSeconds then
		return true, string.format("beats worst slot, costs %.1fs of income",
			cost / INCOME.perSecond)
	end

	-- With every slot full the question is not "how long until this ore pays for
	-- itself" but "how long until the EXTRA income over the drill it replaces
	-- pays for it". Judging on absolute payback threw away a 600K Titanium worth
	-- 30/s against a 3.7/s slot, and a 40K Sulfur Crystal that was already
	-- affordable, because their sticker payback looked long in isolation.
	if LOADOUT.count > 0 and LOADOUT.totalRate > 0 and INCOME.perSecond > 0 then
		local scale = INCOME.perSecond / LOADOUT.totalRate
		local gain = (rate - LOADOUT.worstRate) * scale
		if gain > 0 then
			local seconds = (tonumber(result.seedCost) or math.huge) / gain
			if seconds <= CONFIG.maxPayback then
				return true, string.format("+%s/s, %ds to repay", shortNumber(gain), math.floor(seconds))
			end

			-- An event drop gets a longer leash, but not a blank cheque. The
			-- bypass used to wave through ANY ore of rare or better while an
			-- event ran, which parked the whole base on a 9,000,000 Celestium
			-- that needed 3,465 seconds to repay - it saved, bought nothing,
			-- rolled nothing and upgraded nothing for minutes on end.
			local rank = (ORES.RarityRank and ORES.RarityRank[result.rarity or ""]) or 0
			if EVENT.active and rank >= 3 and seconds <= CONFIG.maxPayback * CONFIG.eventPaybackFactor then
				return true, string.format("event drop, %ds to repay", math.floor(seconds))
			end

			return false, string.format("+%s/s but %ds to repay", shortNumber(gain), math.floor(seconds))
		end
	end

	local payback = orePayback(result.oreName)
	if payback <= CONFIG.maxPayback then
		return true, string.format("%ds payback", math.floor(payback))
	end

	-- A genuinely rare drop is worth taking even on a bad payback: it will not
	-- come round again soon, and rerolling it away is the one mistake that
	-- cannot be undone.
	local rank = (ORES.RarityRank and ORES.RarityRank[result.rarity or ""]) or 0
	if rank >= CONFIG.keepRarityRank then return true, tostring(result.rarity) end

	return false, string.format("%ds payback", math.floor(payback))
end

do
	local rollEvent = ReplicatedStorage:FindFirstChild("RollerRollEvent")
	if rollEvent and rollEvent:IsA("RemoteEvent") then
		rollEvent.OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" or type(payload.results) ~= "table" then return end
			for _, result in ipairs(payload.results) do
				if result.pedestalName then ROLLED[result.pedestalName] = result end
			end
		end)
	end
end

-- The rolled ore lands on a pedestal with a price tag and a Buy prompt.
--
-- The prompt to fire is the one under LocalRollingOreDisplay, NOT the one named
-- PurchaseOrePrompt: despite the names, PurchaseOrePrompt is Enabled = false at
-- all times, even standing on top of the pedestal, while the "rolling display"
-- prompt is the live one. Matching on the name bought nothing at all.
-- RollerPurchaseEvent is a server->client confirmation ONLY. Firing it back at
-- the server buys nothing: money and inventory stay put, both from across the
-- base and while pinned on top of the pedestal. An earlier reading that it
-- worked was a measurement error - the auto cycle was still running in the
-- background and buying through the prompts while the remote got the credit.
--
-- So the purchase stays on the prompt, and the prompt to fire is the one under
-- LocalRollingOreDisplay, NOT the one named PurchaseOrePrompt: despite the
-- names, PurchaseOrePrompt is Enabled = false at all times, even standing on the
-- pedestal, while the "rolling display" prompt is the live one.
--
-- Success is confirmed by the balance moving, never by the call returning.
local function buyRolledOre()
	local base = findBase()
	local pedestals = base and base:FindFirstChild("OrePedestals")
	if not pedestals then return false end

	-- cheapest first, so a 600 dollar Tin roll is never lost to a 300,000
	-- dollar Platinum roll that happened to be checked first. The pedestal count
	-- grows with RollerUpgradePedestal (up to 6), so never assume three.
	local pending = {}
	for _, pedestal in ipairs(pedestals:GetChildren()) do
		local result = ROLLED[pedestal.Name]
		if result then
			table.insert(pending, { pedestal = pedestal, result = result })
		end
	end
	table.sort(pending, function(a, b)
		return (tonumber(a.result.seedCost) or math.huge) < (tonumber(b.result.seedCost) or math.huge)
	end)

	local bought = false
	for _, entry in ipairs(pending) do
		local result = entry.result
		local cost = tonumber(result.seedCost) or math.huge
		local want, why = oreWanted(result)
		refreshMoney()

		if not want then
			STATE.note = string.format("skip %s (%s)", tostring(result.oreName), why)
			logLine("ORE-SKIP", string.format("%s %s cost %s rarity %s - %s",
				tostring(result.oreName), tostring(result.mutation or ""),
				shortNumber(cost), tostring(result.rarity), why))
			ROLLED[entry.pedestal.Name] = nil
		elseif cost <= STATE.money then
			local prompt
			for _, descendant in ipairs(entry.pedestal:GetDescendants()) do
				if descendant:IsA("ProximityPrompt") and descendant.Enabled
					and tostring(descendant.ActionText):lower():find("buy") then
					prompt = descendant
					break
				end
			end

			if prompt then
				local before = STATE.money
				usePrompt(prompt)
				task.wait(0.35)
				refreshMoney()
				if STATE.money < before then
					ROLLED[entry.pedestal.Name] = nil
					STATE.oresBought += 1
					STATE.note = string.format("bought %s %s (%s)",
						tostring(result.oreName), shortNumber(before - STATE.money), why)
					logLine("ORE-BUY", string.format("%s paid %s balance %s - %s",
						tostring(result.oreName), shortNumber(before - STATE.money),
						shortNumber(STATE.money), why))
					bought = true
				end
			end
		end
	end
	return bought
end

-- Something worth waiting for is sitting on a pedestal: rolling again would
-- throw it away. Only ores that are actually within reach count - one that costs
-- fifty times the balance is not being saved for, it is out of our league.
-- How far above the current balance an ore may sit before the lever is pulled
-- anyway. An ordinary roll is not worth waiting long for - another one is thirty
-- seconds away. An event drop or a genuinely rare ore is, because it will not
-- come round again, so it gets a far longer leash and is only rerolled when it
-- is truly absurd next to what we earn.
local function orePatience(result)
	local info = oreInfo(result.oreName)
	local rank = (ORES.RarityRank and ORES.RarityRank[result.rarity or ""]) or 0
	if (info and info.eventType)
		or (result.mutation and result.mutation ~= "")
		or rank >= CONFIG.keepRarityRank
		or EVENT.active then
		return CONFIG.waitForEventOreFactor
	end
	return CONFIG.waitForOreFactor
end

local function sampleIncome()
	-- The server keeps the real figure on the player as DroneEarningsPerMinute,
	-- and it is authoritative: it counts everything the drones dig, while the
	-- rolling window below only ever saw what this script itself sold. Measured
	-- side by side, the attribute read 4,801,000/min (80,017/s) against 40,429/s
	-- from the window - half. Every payback in this file divides by this number,
	-- so being wrong by 2x mis-ranked every purchase in the game.
	local perMinute = tonumber(plr:GetAttribute("DroneEarningsPerMinute"))
	if perMinute and perMinute > 0 then
		INCOME.perSecond = perMinute / 60
		return INCOME.perSecond
	end

	-- Fallbacks: the base billboard, then the rolling window.
	if INCOME.perSecond <= 0 then
		local base = findBase()
		local label = base and base:FindFirstChild("Earning", true)
		local billboard = label and parseMoney(label.Text)
		if billboard and billboard > 0 then INCOME.perSecond = billboard / 60 end
	end

	local now = os.clock()
	table.insert(INCOME.samples, { at = now, earned = STATE.earned })
	while #INCOME.samples > 1 and now - INCOME.samples[1].at > CONFIG.incomeWindow do
		table.remove(INCOME.samples, 1)
	end
	local first = INCOME.samples[1]
	local span = now - first.at
	if span >= 20 then
		INCOME.perSecond = (STATE.earned - first.earned) / span
	end
	return INCOME.perSecond
end

-- Can we realistically reach this price by just waiting?
--
-- A one-in-a-million roll is painful to throw away, but sitting on it while the
-- drills idle costs more than it is worth. So the answer is a projection rather
-- than a fixed multiple: current balance plus what we earn during the wait. If
-- the price is still out of reach by the end of that window, the lever gets
-- pulled and we go looking for something we can actually afford.
local function reachable(cost)
	refreshMoney()
	if cost <= STATE.money then return true, 0 end
	local rate = sampleIncome()
	if rate <= 0 then
		-- no measurement yet: fall back to the plain multiple
		return cost <= STATE.money * CONFIG.waitForOreFactor, -1
	end
	local seconds = (cost - STATE.money) / rate
	return seconds <= CONFIG.reachWithin, seconds
end

local function pendingWorthKeeping()
	refreshMoney()
	SAVING.cost, SAVING.ore = 0, nil
	for _, result in pairs(ROLLED) do
		local want = oreWanted(result)
		local cost = tonumber(result.seedCost) or math.huge
		if want then
			-- The projection is the rule. An earlier version also demanded the
			-- price sit inside a flat multiple of the balance, and the two
			-- together threw away a 200,000 roll that the income would have
			-- covered in a couple of minutes - the flat multiple was doing the
			-- deciding and the projection never got a say.
			local canReach, seconds = reachable(cost)
			if canReach then
				-- fence the money off so nothing else spends what we are waiting
				-- for; only the biggest target is held, not the sum of them
				if cost > (SAVING.cost or 0) then
					SAVING.cost, SAVING.ore = cost, result.oreName
				end
				return true, result, seconds
			end
		end
	end
	return false
end

-- REMOVED: collecting workspace.DroneOreDrops.
--
-- Those models look like loose ore lying on the map and each carries a
-- TouchInterest, so firing it seemed like free ore - the drop even disappears.
-- It grants nothing. Money, ore inventory and the reward events all stayed
-- exactly where they were, whether fired from 60 studs or while pinned standing
-- on top of it, and the drops spawn and despawn on their own regardless.
--
-- They are the *animation* of the event, not loot: the game's own tooltip reads
-- "Alien Event is active, The UFO will randomly grant your ores the Alien
-- Mutation!". The UFO mutates the ore already sitting in the tunnels, which is
-- why there is nothing to pick up. Verified afterwards in the loadout:
-- "Stone Ore lvl12 MUT=Alien".

-- BaseBuildTunnelAction(baseName, floorNumber, tunnelName, "EquipBest") is what
-- the HUD's Equip Best button fires, and it re-stocks EVERY tunnel on every
-- floor from one call - the floor and tunnel arguments do not limit it. The
-- reply reports inventoryCount, changedCount and the full loadout.
--
-- This mattered more than anything else: bought ores pile up in an inventory
-- rather than going into a drill, and 94 of them were sitting there unused.
local function equipBest()
	local base = findBase()
	if not base then return end
	local response = invoke("BaseBuildTunnelAction", base.Name, 1, "Tunnel1", "EquipBest")
	local result = type(response) == "table" and response.result or nil
	if type(result) ~= "table" then return end

	STATE.inventory = tonumber(result.inventoryCount) or STATE.inventory

	-- Remember the weakest drill so the ore filter can raise its own floor.
	--
	-- The equipped ore has to be judged on what it ACTUALLY produces, not on its
	-- base stats: the loadout's growTime already reflects the ore's level, and a
	-- mutation multiplies the payout on top. A level 12 Alien Stone Ore is worth
	-- many times a fresh Coal even though Coal wins on paper, so comparing base
	-- rates let 250 dollar Coal keep passing the filter.
	local worst, count, total = math.huge, 0, 0
	local perFloor = {}
	for _, slot in ipairs(result.equipped or {}) do
		local floor = tonumber(slot.floorNumber)
		if floor then perFloor[floor] = (perFloor[floor] or 0) + 1 end
	end
	LOADOUT.perFloor = perFloor

	for _, slot in ipairs(result.equipped or {}) do
		local info = oreInfo(slot.oreType)
		local income = info and tonumber(info.baseIncome) or 0
		local grow = tonumber(slot.growTime) or (info and tonumber(info.growTimeSeconds)) or 0
		if income > 0 and grow > 0 then
			local mutation = slot.mutation and ORES.Mutations and ORES.Mutations[slot.mutation]
			local multiplier = 1
			if type(mutation) == "table" then
				multiplier = tonumber(mutation.Multiplier or mutation.multiplier) or 1
			elseif tonumber(mutation) then
				multiplier = tonumber(mutation)
			end
			local rate = income * multiplier / grow
			count += 1
			total += rate
			if rate < worst then worst = rate end
		end
	end
	if count > 0 then
		LOADOUT.worstRate = worst
		LOADOUT.totalRate = total
		LOADOUT.count = count
	end

	if (tonumber(result.changedCount) or 0) > 0 then
		STATE.equips += 1
		STATE.note = string.format("equip best: %d swapped, %d in stock",
			result.changedCount, result.inventoryCount or 0)
	end
end

local function pickUpCrate()
	local base = findBase()
	local prompt = base and promptAt(base, "CrateMaker.CrateSpawnPoint", "PickUpOresPrompt")
	if not prompt or not prompt.Enabled then return false end
	if usePrompt(prompt) then
		STATE.pickups += 1
		STATE.phase = "carrying crate"
		return true
	end
	return false
end

local function sellOres()
	local base = findBase()
	local table_ = base and base:FindFirstChild("SellerTable")
	local prompt
	for _, descendant in ipairs(table_ and table_:GetDescendants() or {}) do
		if descendant:IsA("ProximityPrompt") and tostring(descendant.Name):find("Sell") then
			prompt = descendant
			break
		end
	end
	-- The sell prompt is only Enabled while a crate is actually carried.
	if not prompt or not prompt.Enabled then return false end

	local before = STATE.money
	if usePrompt(prompt) then
		task.wait(0.5)
		refreshMoney()
		local gained = STATE.money - before
		if gained > 0 then STATE.earned += gained end
		STATE.sells += 1
		STATE.note = gained > 0 and ("sold for " .. shortNumber(gained)) or "sold"
		return true
	end
	return false
end

-- Spending ----------------------------------------------------------------------
--
-- THE RULE FOR EVERY PAID REMOTE IN THIS FILE: read the price first, compare it
-- against the balance, and only then call. A call the server answers with
-- NotEnoughMoney makes the client pop the Robux "Skip 5m" developer product
-- (DeveloperProductPrompt 3610009242). Never probe a price by calling.

-- Robux is never spent by this script, but the game opens the "Skip 5m" product
-- window on its own whenever a paid remote answers NotEnoughMoney, and the
-- tunnel price labels are stale often enough that a bad call cannot be fully
-- ruled out by checking prices alone. So the purchase prompts are nailed shut
-- once, up front, and every price check below is the second line of defence.
do
	if not _G.__SELLORES_NOROBUX and hookfunction then
		local marketplace = game:GetService("MarketplaceService")
		local wrap = newcclosure or function(fn) return fn end
		for _, method in ipairs({
			"PromptProductPurchase", "PromptPurchase",
			"PromptGamePassPurchase", "PromptBundlePurchase",
			"PromptPremiumPurchase", "PromptSubscriptionPurchase",
		}) do
			-- reading a name the API does not have throws, so probe it safely
			local ok, fn = pcall(function() return marketplace[method] end)
			if ok and type(fn) == "function" then
				pcall(function() hookfunction(fn, wrap(function() return nil end)) end)
			end
		end
		_G.__SELLORES_NOROBUX = true
	end

	-- The window is not opened by MarketplaceService directly: the server pushes
	-- ReplicatedStorage.DeveloperProductPrompt and the game's own handler builds
	-- the panel. Killing that listener is what actually stops it appearing.
	if not _G.__SELLORES_NOPROMPT and getconnections then
		local prompt = ReplicatedStorage:FindFirstChild("DeveloperProductPrompt")
		if prompt and prompt:IsA("RemoteEvent") then
			pcall(function()
				for _, connection in ipairs(getconnections(prompt.OnClientEvent)) do
					if connection.Disable then connection:Disable() else connection:Disconnect() end
				end
			end)
			_G.__SELLORES_NOPROMPT = true
		end
	end
end

-- Board prices live in a TextButton next to a TextLabel carrying the name of the
-- upgrade, e.g. "Drill Yield" -> "$14,529". That button is the only honest price
-- source available before the purchase.
local function priceNextTo(root, labelText)
	if not root then return nil end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextLabel") and d.Text == labelText then
			local button = d.Parent and d.Parent:FindFirstChild("TextButton", true)
			if button then return parseMoney(button.Text) end
		end
	end
	return nil
end

local function canPay(price, reserve)
	if not price or price <= 0 then return false end
	refreshMoney()
	return STATE.money - (reserve or 0) >= price
end

-- Drill upgrades ------------------------------------------------------------------
--
-- BaseUpgradeDrillYield / DrillSpeed / OreRegenSpeed take (baseName, floorNumber).
-- The base name is a plain string and there is no proximity check at all - fired
-- from 150 studs away it still went through. The floor argument has to be the
-- NUMBER (2), not the model name ("Floor2"); a string silently falls back to
-- floor 1, which is why the per-floor boards looked dead at first.
-- Each upgrade type adds a FIXED amount to its multiplier per level, measured
-- across all three unlocked floors: the multiplier at level n is
-- 1 + (n - 1) * step, and the level is written on the board as "15 > 16". So the
-- relative gain of the next level is step / currentMultiplier, and it can be
-- worked out for nothing - no call, no risk of a NotEnoughMoney answer.
--
-- This matters because ranking by price is wrong. Measured on the live base:
--
--   F2 Drill Speed   50,000  1.000 -> 1.150   gain 0.150   0.300 per 100k
--   F1 Drill Yield   14,529  1.362 -> 1.388   gain 0.019   0.131 per 100k
--   F3 Ore Regen     12,106  1.061 -> 1.071   gain 0.010   0.079 per 100k
--   F3 Drill Speed  250,000  1.000 -> 1.150   gain 0.150   0.060 per 100k
--
-- Cheapest-first bought the bottom two over and over and never once bought the
-- 50,000 Drill Speed that is worth more than twice as much per dollar - the
-- balance was drained below its threshold every single round.
local UPGRADE_REMOTES = {
	{ remote = "BaseUpgradeDrillYield", label = "Drill Yield", step = 0.02586 },
	{ remote = "BaseUpgradeDrillSpeed", label = "Drill Speed", step = 0.15 },
	{ remote = "BaseUpgradeOreRegenSpeed", label = "Ore Regen Speed", step = 0.010111 },
}

-- "15 > 16" -> 15
local function levelFromBoard(board, label)
	if not board then return nil end
	for _, d in ipairs(board:GetDescendants()) do
		if d:IsA("TextLabel") and d.Text == label then
			local row = d.Parent
			local text = row and row:FindFirstChild("UpgradeText")
			local level = text and tonumber(tostring(text.Text):match("^%s*(%d+)"))
			if level then return level end
		end
	end
	return nil
end

-- One BaseUpgradesBoardFloor<n> exists per unlocked floor, so the boards double
-- as the list of floors worth upgrading.
local function unlockedFloors()
	local base = findBase()
	local boards = base and base:FindFirstChild("BaseUpgradesBoards")
	local out = {}
	if not boards then return out end
	for _, board in ipairs(boards:GetChildren()) do
		local number = tonumber(board.Name:match("Floor(%d+)$"))
		if number then table.insert(out, { number = number, board = board }) end
	end
	table.sort(out, function(a, b) return a.number < b.number end)
	return out
end

-- Price of the next floor, or nil. Unlocking a floor adds seven fresh drills and
-- is worth far more than another drill level, but a $15,000 upgrade fires every
-- few seconds and a $150,000 floor never would - the balance simply never gets
-- there. So once the balance is a quarter of the way to the floor, that amount is
-- fenced off from the upgrade budget. Below that mark upgrades run freely,
-- because raising income is the only way to reach the floor at all.
-- Forward declarations: furnaceReserve needs the furnace helpers, which live
-- below, but buyUpgrades right underneath here has to subtract it. Declaring the
-- locals up front is the only way a function defined later is visible to one
-- defined earlier - this file has been bitten by that three times now.
local floorReserve
local furnaceReserve
local tunnelReserve
local furnaceRate
local furnaceWorthUsing
local drillReserve

local function oreReserve()
	if not (CONFIG.auto or CONFIG.autoBuyOre) then return 0 end
	return SAVING.cost or 0
end

-- Each spender may dip into its OWN reserve but not into anybody else's. The
-- furnace used to check only the floor reserve, so it happily spent the money
-- being saved for a 9,000,000 ore and for the next tunnel.
local RESERVES = {
	floor = function() return floorReserve and floorReserve() or 0 end,
	furnace = function() return furnaceReserve and furnaceReserve() or 0 end,
	tunnel = function() return tunnelReserve and tunnelReserve() or 0 end,
	ore = oreReserve,
}

-- Save for ONE thing at a time - the cheapest goal that is currently active.
--
-- Summing every reserve froze the base solid: floor 5 at 10,000,000 plus the
-- next tunnel at 7,400,000 came to 17,400,000 fenced off against a 4,190,000
-- balance, so no drill upgrade could ever fire again. Holding only the nearest
-- goal reaches it fastest, and the next one takes over the moment it is bought.
-- How many seconds each goal takes to earn its own price back, so the money is
-- held for the goal that actually pays, not the one with the smallest sticker.
--
-- Worked out live at 22 drills and 38,165/s: the next floor-4 tunnel at
-- 7,400,000 adds one drill and repays in 4,265s, while floor 5 at 10,000,000
-- adds seven and repays in 823s. Picking the cheapest goal was picking the worst
-- one by a factor of five.
local function goalPayback(name, cost)
	if cost <= 0 then return math.huge end
	local income = INCOME.perSecond
	local slots = LOADOUT.count
	if income <= 0 or slots <= 0 then return math.huge end
	local perDrill = income / slots

	if name == "tunnel" then return cost / perDrill end
	if name == "floor" then return cost / (perDrill * 7) end
	-- the furnace is a throughput ceiling on everything, not an add-on, so it
	-- is judged against the income it is currently costing us
	if name == "furnace" then
		local rate = furnaceRate and furnaceRate() or 0
		local lost = math.max(income - rate, 0)
		if lost <= 0 then return math.huge end
		return cost / lost
	end
	-- an ore has already been vetted by oreWanted; treat it as worth having
	return 0
end

local function activeReserve()
	local bestName, bestCost, bestPayback
	for name, fn in pairs(RESERVES) do
		local cost = fn() or 0
		if cost > 0 then
			local payback = goalPayback(name, cost)
			if not bestPayback or payback < bestPayback then
				bestName, bestCost, bestPayback = name, cost, payback
			end
		end
	end
	return bestName, bestCost or 0, bestPayback
end

local function reservedExcept(mine)
	local name, cost = activeReserve()
	if not name or name == mine then return 0 end
	return cost
end

local function reservedMoney()
	local _, cost = activeReserve()
	return cost
end

-- What a given spender has to leave untouched.
--
-- The furnace reserve was being honoured by nobody: it correctly held 4,440,800
-- for the upgrade that would lift the furnace back over its break-even, but the
-- ore levels, the gems and the drill boards all checked only the ore and drill
-- pots, so the balance was spent down to 2,500,000 every time and the furnace
-- upgrade never happened. Only the largest applicable pot counts, never a sum.
local function guardFor(category)
	local largest = oreReserve()
	if category ~= "drill" then
		largest = math.max(largest, drillReserve and drillReserve() or 0)
	end
	-- while the furnace is under water everything below it gets out of its way
	if category ~= "furnace" and FURNACE.purchased
		and furnaceWorthUsing and not furnaceWorthUsing() then
		largest = math.max(largest, furnaceReserve and furnaceReserve() or 0)
	end
	return largest
end

-- Price of the cheapest tunnel still missing on an unlocked floor.
--
-- An empty tunnel is a drill that does not exist. Floor 4 sat unlocked with all
-- seven of its 650,000 dollar tunnels unbought - a quarter of the base idle -
-- because drill upgrades fire every eight seconds and never let the balance
-- climb that high. The price label is unreliable for telling bought from
-- unbought, but it is accurate about the PRICE, and the unlocked-floor drill
-- count from EquipBest says how many are actually missing.
function tunnelReserve()
	if not (CONFIG.auto or CONFIG.autoTunnels) then return 0 end
	local base = findBase()
	local floors = base and base:FindFirstChild("Floors")
	if not floors or LOADOUT.count == 0 then return 0 end

	local cheapest
	for _, floor in ipairs(unlockedFloors()) do
		local missing = 7 - (LOADOUT.perFloor[floor.number] or 0)
		if missing > 0 then
			local model = floors:FindFirstChild("Floor" .. floor.number)
			for _, tunnel in ipairs(model and model:GetChildren() or {}) do
				local purchase = tunnel:FindFirstChild("PurchaseModel")
				local label = purchase and purchase:FindFirstChild("PriceLabel", true)
				local price = label and parseMoney(label.Text)
				if price and (not cheapest or price < cheapest) then cheapest = price end
			end
		end
	end

	if not cheapest then return 0 end
	if STATE.money < cheapest * 0.25 then return 0 end
	return cheapest
end

function floorReserve()
	if not (CONFIG.auto or CONFIG.autoFloors) then return 0 end
	local base = findBase()
	local board = base and base:FindFirstChild("Boards") and base.Boards:FindFirstChild("UnlockFloorBoard")
	local button = board and board:FindFirstChild("TextButton", true)
	local price = button and parseMoney(button.Text)
	if not price then return 0 end
	if STATE.money < price * 0.25 then return 0 end
	return price
end

-- One line per floor: how many drills stand on it and where its three upgrades
-- are. This is the readout that says whether the lower floors are actually being
-- filled out before the upper ones, e.g.
--   F1 7d  Y24 S:Max R28   F4 5d  Y11 S1 R12
local function droneState()
	local base = findBase()
	local floors = base and base:FindFirstChild("Floors")
	local out = {}
	if not floors then return out end

	for _, floor in ipairs(unlockedFloors()) do
		local model = floors:FindFirstChild("Floor" .. floor.number)
		local drone = model and model:FindFirstChild("BaseBuildDrone_Floor" .. floor.number)
		if drone then
			local waiting = tostring(drone:GetAttribute("LastDrillError") or "")
			out[#out + 1] = {
				floor = floor.number,
				state = tostring(drone:GetAttribute("DrillState") or "?"),
				tunnel = tostring(drone:GetAttribute("CurrentTunnel") or "?"),
				payout = tonumber(drone:GetAttribute("LastPayout")) or 0,
				waitingOnOre = waiting == "OreNotReady",
			}
		end
	end
	return out
end

local function drillState()
	local drones = {}
	for _, drone in ipairs(droneState()) do drones[drone.floor] = drone end

	local out = {}
	for _, floor in ipairs(unlockedFloors()) do
		local drills = LOADOUT.perFloor[floor.number] or 0
		local parts = {}
		for _, entry in ipairs(UPGRADE_REMOTES) do
			local level = levelFromBoard(floor.board, entry.label)
			local short = entry.label:sub(1, 1) == "D" and entry.label:sub(7, 7) or "R"
			parts[#parts + 1] = short .. (level and tostring(level) or "Max")
		end
		-- "!" marks a floor whose drone is idle waiting for ore to regrow
		local drone = drones[floor.number]
		local mark = drone and (drone.waitingOnOre and " !regen" or (" " .. shortNumber(drone.payout))) or ""
		out[#out + 1] = string.format("F%d %dd %s%s",
			floor.number, drills, table.concat(parts, " "), mark)
	end
	return out
end

-- Each floor has its own mining drone, and it carries the only honest per-floor
-- state in the game as attributes:
--   DrillState "Regrowing" / CurrentTunnel / DrillingTunnel / LastPayout
--   LastDrillError "OreNotReady"
--
-- The drone works one tunnel at a time and waits for the ore to grow back, so a
-- floor sitting on OreNotReady is limited by regrowth, not by yield - which is
-- exactly the difference between spending on Ore Regen Speed and on Drill Yield.
-- Cheapest drill-board upgrade still available on any unlocked floor.
--
-- The drill boards are the user's number one, but they cost hundreds of
-- thousands while an ore level costs a few thousand and repays in a hundred
-- seconds. Left alone, the cheap ones drain the balance every few seconds and
-- the boards are never affordable - measured: 0 drill upgrades bought while ore
-- levels ran continuously. So whatever the cheapest board step costs is fenced
-- off from everything below it in the order.
-- Every board carries THREE separate upgrades - Drill Speed, Drill Yield and
-- Ore Regen Speed - each with its own level and its own price, and all three
-- have to climb. Reserving for the cheapest of them was quietly abandoning the
-- expensive ones: Drill Speed on floors 3 and 4 sat at level 2 behind 5,000,000
-- and 25,000,000 while the balance was spent over and over on 1,200,000 Regen
-- levels, so it never got within reach.
--
-- Drill Speed is also the strongest step by a wide margin (+0.15 per level
-- against +0.026 for Yield), so the money is held for whatever the ranking
-- actually wants next, not for whatever happens to be cheapest.
local function bestDrillJob()
	local best
	for _, floor in ipairs(unlockedFloors()) do
		local drills = LOADOUT.perFloor[floor.number] or 0
		if LOADOUT.count == 0 then drills = 7 end
		if drills > 0 then
			for _, entry in ipairs(UPGRADE_REMOTES) do
				local price = priceNextTo(floor.board, entry.label)
				local level = levelFromBoard(floor.board, entry.label)
				if price and price > 0 and level then
					local multiplier = 1 + (level - 1) * entry.step
					local value = (entry.step / multiplier) * drills / price
					if not best or value > best.value then
						best = { entry = entry, floor = floor.number, price = price, value = value }
					end
				end
			end
		end
	end
	return best
end

function drillReserve()
	if not (CONFIG.auto or CONFIG.autoUpgrade) then return 0 end
	local best = bestDrillJob()
	if not best then return 0 end

	-- Activate as soon as the target is reachable from income, not once a
	-- quarter of it is already banked. The quarter rule never engaged: the
	-- balance touched 2,100,000 for a moment, the ore levels and ore buys pulled
	-- it back under the 1,250,000 mark, and the reserve switched off again -
	-- over and over, so the 5,000,000 Drill Speed stayed out of reach forever.
	if INCOME.perSecond > 0 then
		if best.price <= STATE.money + INCOME.perSecond * CONFIG.reachWithin then
			return best.price
		end
		return 0
	end
	if STATE.money < best.price * 0.25 then return 0 end
	return best.price
end

-- Per-ore levels ------------------------------------------------------------------
--
-- Every tunnel has its own ore level, shown on the BaseBuildTunnelGui panel as
-- "Level 1 - $550 / Ore" with a price button. It is driven by
--
--   BaseBuildTunnelAction(baseName, floorNumber, tunnelName, "IncreaseLevel")
--     -> {result = {Price, LevelsAdded, Level}, success}
--
-- and there is an "IncreaseLevel10" for ten at once. Verified live: Jade Ore on
-- Floor 1 Tunnel 1 went from level 2 to 3 and cost exactly the 5,110 the reply
-- reported. This is the mechanic behind the level 12 Stone Ore that was sitting
-- in a tunnel - it was never automated until now.
--
-- Levels raise INCOME PER ORE, not growth speed (growTime did not move), which
-- is precisely what a base whose drones all idle on OreNotReady needs: more
-- money per drill without needing the ore back any sooner.
--
-- OreMetadata gives both curves: income rises about 12% per level while the
-- price rises about 46%, so early levels are excellent and later ones fall off a
-- cliff. Ranking by payback keeps it on the good side of that curve.
local function upgradeOreLevels()
	local base = findBase()
	if not base or type(ORES.GetBaseIncome) ~= "function" or type(ORES.GetUpgradePrice) ~= "function" then
		return
	end

	local response = invoke("BaseBuildTunnelAction", base.Name, 1, "Tunnel1", "EquipBest")
	local loadout = type(response) == "table" and type(response.result) == "table"
		and response.result.equipped or nil
	if not loadout or LOADOUT.totalRate <= 0 or INCOME.perSecond <= 0 then return end
	local scale = INCOME.perSecond / LOADOUT.totalRate

	local bought = 0
	while bought < CONFIG.maxOreLevelsPerRound do
		local best
		for _, slot in ipairs(loadout) do
			local level = tonumber(slot.level) or 1
			local grow = tonumber(slot.growTime) or 0
			local okNow, incomeNow = pcall(ORES.GetBaseIncome, slot.oreType, level)
			local okNext, incomeNext = pcall(ORES.GetBaseIncome, slot.oreType, level + 1)
			local okPrice, price = pcall(ORES.GetUpgradePrice, slot.oreType, level)

			if okNow and okNext and okPrice and grow > 0 and price and price > 0 then
				local gain = ((incomeNext - incomeNow) / grow) * scale
				if gain > 0 then
					local repay = price / gain
					if repay <= CONFIG.maxOreLevelPayback
						and (not best or repay < best.repay) then
						best = {
							floor = slot.floorNumber, tunnel = slot.tunnelName,
							ore = slot.oreType, level = level,
							price = price, repay = repay, gain = gain, slot = slot,
						}
					end
				end
			end
		end

		if not best then break end
		refreshMoney()
		-- Ore levels rank third, so they honour the two pots above them - but only
		-- the LARGER of the two, never the sum. Adding them fenced off 3,690,000
		-- against a 988,000 balance and stopped the single best buy in the game
		-- dead: these repay in 19 to 88 seconds, the drill board they were
		-- waiting behind takes hours. One goal at a time, as everywhere else.
		local ahead = guardFor("orelevel")

		-- ...and a level that costs less than a few seconds of income ignores the
		-- fence entirely. The drill boards now cost over a million each, so the
		-- reserve is permanently active and was blocking 6,000 dollar levels that
		-- repay in nineteen seconds - holding up a one-second purchase to save
		-- for a twenty-five-second one. Same rule the cheap ore buys already use.
		local trivial = INCOME.perSecond > 0 and best.price <= INCOME.perSecond * CONFIG.trivialSeconds
		local budget = trivial and STATE.money or math.max(STATE.money - ahead, 0)
		if best.price > budget then break end

		local result = invoke("BaseBuildTunnelAction", base.Name, best.floor, best.tunnel, "IncreaseLevel")
		if type(result) ~= "table" or not result.success then break end

		bought += 1
		STATE.oreLevels += 1
		best.slot.level = (tonumber(result.result and result.result.Level) or best.level + 1)
		STATE.note = string.format("F%d %s %s -> lvl%d",
			best.floor, best.tunnel, best.ore:gsub(" Ore", ""), best.slot.level)
		logLine("ORE-LEVEL", string.format("F%d %s %s lvl%d paid %s +%s/s repay %ds balance %s",
			best.floor, best.tunnel, best.ore, best.slot.level, shortNumber(best.price),
			shortNumber(best.gain), math.floor(best.repay), shortNumber(STATE.money)))
		task.wait(0.1)
	end
end

local function buyUpgrades()
	local base = findBase()
	if not base then return end
	-- Top of the priority list, so only the ore being saved for stands above the
	-- drill boards - plus the furnace while it is under water, because that is a
	-- leak rather than a purchase.
	local reserve = guardFor("drill")

	-- Re-rank after every purchase: a bought level raises that upgrade's price
	-- and lowers its relative gain, so the best buy moves around constantly.
	-- Which floors are standing idle waiting for ore to grow back.
	local idle = {}
	for _, drone in ipairs(droneState()) do
		if drone.waitingOnOre then idle[drone.floor] = true end
	end

	local bought = 0
	while bought < CONFIG.maxUpgradesPerRound do
		local jobs = {}
		for _, floor in ipairs(unlockedFloors()) do
			for _, entry in ipairs(UPGRADE_REMOTES) do
				local price = priceNextTo(floor.board, entry.label)
				local level = levelFromBoard(floor.board, entry.label)
				-- A floor upgrade multiplies that floor's drills and nothing else,
				-- so it is worth exactly as much as the number of drills standing
				-- on it. Floor 4 was unlocked but none of its seven 650,000 dollar
				-- tunnels were bought, and the ranking happily poured money into
				-- F4 Ore Regen and F4 Drill Yield - multiplying zero drills.
				local drills = LOADOUT.perFloor[floor.number] or 0
				-- before the first EquipBest there is no loadout; assume a full
				-- floor rather than freezing every upgrade
				if LOADOUT.count == 0 then drills = 7 end

				if price and price > 0 and level and drills > 0 then
					local multiplier = 1 + (level - 1) * entry.step
					local share = (entry.step / multiplier) * drills / math.max(LOADOUT.count, 1)

					-- A drone that reports OreNotReady is not producing at all
					-- while it waits, so on that floor regrowth is the binding
					-- constraint and a Regen level is worth far more than the
					-- linear model says - while another Yield level multiplies
					-- output that is not happening.
					local weight = 1
					if idle[floor.number] then
						weight = entry.label == "Ore Regen Speed" and CONFIG.regenBoost
							or (1 / CONFIG.regenBoost)
					end
					share = share * weight

					local repay = INCOME.perSecond > 0 and (price / (share * INCOME.perSecond)) or 0

					-- Upgrades run into diminishing returns hard: the step is
					-- fixed but the multiplier it divides into keeps growing, so
					-- by level 20+ a 466,000 Drill Yield needed 8,203 seconds to
					-- repay while a 300,000 Platinum Ore needed 425. Money spent
					-- here is money not spent on the thing that is seven to
					-- thirty times better, so anything this slow is left alone.
					if repay <= CONFIG.maxUpgradePayback then
						table.insert(jobs, {
							entry = entry,
							floor = floor.number,
							price = price,
							drills = drills,
							repay = repay,
							value = share / price,
						})
					end
				end
			end
		end
		if #jobs == 0 then break end
		table.sort(jobs, function(a, b) return a.value > b.value end)

		refreshMoney()
		local spendable = math.max(STATE.money - reserve, 0)

		-- Drill boards are priority one, so EVERY affordable one may take the
		-- whole spendable balance, not just the top-ranked one. The old
		-- spendFraction buffer left Floor 2 on Drill Yield 20 and Floor 4 without
		-- Drill Speed at all, because only the single best-value step was ever
		-- allowed to spend freely and the rest waited behind a 60% cap.
		--
		-- But once the best step is within reach, stop buying the lesser ones:
		-- otherwise the 5,000,000 Drill Speed is never reached, because a
		-- 1,200,000 Regen level takes the money every twenty-five seconds. That
		-- is how floors 3 and 4 stayed on Drill Speed level 2 indefinitely.
		local top = jobs[1]
		if top and top.price > spendable and STATE.money >= top.price * 0.25 then
			STATE.note = string.format("saving %s for F%d %s",
				shortNumber(top.price), top.floor, top.entry.label)
			break
		end

		local job
		for _, candidate in ipairs(jobs) do
			if candidate.price <= spendable then job = candidate break end
		end
		if not job then break end

		local response = invoke(job.entry.remote, base.Name, job.floor)
		if type(response) ~= "table" or not response.success then break end
		bought += 1
		STATE.upgrades += 1
		STATE.note = string.format("F%d %s -> %d (%s)", job.floor, job.entry.label,
			response.state and response.state.level or 0, shortNumber(job.price))
		logLine("UPGRADE", string.format("F%d %s lvl%d paid %s value %.3f/100k balance %s",
			job.floor, job.entry.label, response.state and response.state.level or 0,
			shortNumber(job.price), job.value * 100000, shortNumber(STATE.money)))
		task.wait(0.12)
	end
	refreshMoney()
end

-- Roller upgrades -----------------------------------------------------------------
--
-- RollerUpgradeOreLuck / RollerUpgradePedestal sit in ReplicatedStorage itself,
-- not under Remotes, which is why searching Remotes for them found nothing. Same
-- shape as the drill upgrades: base name string, no proximity check.
local ROLLER_UPGRADES = {
	{ remote = "RollerUpgradeOreLuck", label = "Upgrade Ore Luck" },
	{ remote = "RollerUpgradePedestal", label = "Rolling Pedestals" },
}

local function buyRollerUpgrades()
	local base = findBase()
	local board = base and base:FindFirstChild("Boards") and base.Boards:FindFirstChild("RollUpgradesBoard")
	if not board then return end

	-- The floor money is fenced off here too. Without it the roller quietly ate
	-- the balance every cycle and the floor unlock, worth seven fresh drills,
	-- never came within reach: 153,000 in the bank against a 150,000 floor and
	-- still nothing bought.
	local reserve = reservedMoney()

	for _, entry in ipairs(ROLLER_UPGRADES) do
		local lastPrice
		for _ = 1, CONFIG.maxUpgradesPerRound do
			local price = priceNextTo(board, entry.label)
			-- the board label is repainted by the server a moment after the
			-- purchase; buying against the old price is what produced the one
			-- stray NotEnoughMoney, so an unchanged label ends the round
			if price == lastPrice then break end
			if not canPay(price, reserve) then break end

			local response = invoke(entry.remote, base.Name)
			if type(response) ~= "table" or not response.success then break end
			STATE.rollerUpgrades += 1
			STATE.note = string.format("%s -> %s", entry.label,
				tostring(response.count or response.level or "+1"))
			lastPrice = price
			task.wait(0.35)
		end
	end
end

-- Tunnels and floors ---------------------------------------------------------------
--
-- BaseBuildPurchaseTunnel(baseName, "FloorN", "TunnelM") and
-- BaseBuildPurchaseFloor(baseName, "FloorN") - here the floor really is the model
-- name. Unlocking floor 2 dropped its tunnel price from $13,500 to $1,200, so the
-- big number on a locked floor is the unlock cost, not the tunnel cost.
-- The PriceLabel on a tunnel's PurchaseModel cannot be trusted: it keeps showing
-- the floor's old unlock price and stays put after the tunnel is bought. So the
-- server's own answer is the source of truth - AlreadyUnlocked marks a tunnel as
-- done for good, and a NotEnoughMoney parks the whole step until the balance has
-- grown by half again, so the loop never hammers a price it cannot reach.
local tunnelOwned = {}
local tunnelWaitUntil = 0

local function buyTunnels()
	local base = findBase()
	local floors = base and base:FindFirstChild("Floors")
	if not floors then return end

	refreshMoney()
	if STATE.money < tunnelWaitUntil then return end
	local spendable = math.max(STATE.money - reservedExcept("tunnel"), 0)

	for _, floor in ipairs(unlockedFloors()) do
		local model = floors:FindFirstChild("Floor" .. floor.number)
		-- Skip floors that are already full. EquipBest reports one entry per
		-- working drill, so seven entries means nothing is missing - and without
		-- this the loop wasted a call on every long-owned tunnel every round.
		local missing = LOADOUT.count > 0 and (7 - (LOADOUT.perFloor[floor.number] or 0)) or 7
		if model and missing > 0 then
			for _, tunnel in ipairs(model:GetChildren()) do
				local key = model.Name .. "/" .. tunnel.Name
				local purchase = tunnel:FindFirstChild("PurchaseModel")
				local label = purchase and purchase:FindFirstChild("PriceLabel", true)
				local price = label and parseMoney(label.Text)
				-- The label lies about ownership but is right about the price, so
				-- it is used only to avoid calling when the money is clearly not
				-- there. A NotEnoughMoney is harmless now but still pointless.
				if price and price > spendable then
					tunnelWaitUntil = math.max(STATE.money * 1.5, 1)
					return
				end

				if purchase and not tunnelOwned[key] then
					local response = invoke("BaseBuildPurchaseTunnel", base.Name, model.Name, tunnel.Name)
					local result = type(response) == "table" and response.result or nil

					if result == "AlreadyUnlocked" then
						tunnelOwned[key] = true
					elseif type(response) == "table" and response.success then
						STATE.tunnels += 1
						STATE.note = "tunnel " .. key
						logLine("TUNNEL", string.format("bought %s for %s, balance %s",
							key, shortNumber(price or 0), shortNumber(STATE.money)))
						refreshMoney()
						task.wait(0.2)
					elseif result == "NotEnoughMoney" then
						tunnelWaitUntil = math.max(STATE.money * 1.5, 1)
						return
					elseif result == "FloorLocked" then
						break
					end
				end
			end
		end
	end
	tunnelWaitUntil = 0
end

local function unlockFloor()
	local base = findBase()
	local board = base and base:FindFirstChild("Boards") and base.Boards:FindFirstChild("UnlockFloorBoard")
	if not board then return end

	local button = board:FindFirstChild("TextButton", true)
	local text = board:FindFirstChild("FloorUnlockText", true)
	local price = button and parseMoney(button.Text)
	-- "2 > 3" - the number behind the arrow is the floor about to be unlocked
	local nextFloor = text and tonumber(tostring(text.Text):match(">%s*(%d+)"))
	if not nextFloor or not canPay(price) then return end

	local response = invoke("BaseBuildPurchaseFloor", base.Name, "Floor" .. nextFloor)
	if type(response) == "table" and response.success then
		STATE.floors += 1
		STATE.note = "unlocked floor " .. nextFloor
		task.wait(0.5)
	end
end

-- Furnace ---------------------------------------------------------------------------
--
-- The furnace (+50% money) is bought at a ProximityPrompt and upgraded through
-- BaseCrateAction(baseName, "UpgradeFurnace"). Its price is never on a label, but
-- the server broadcasts BaseCrateStateChanged with Purchased and UpgradePrice, so
-- listening is enough and no blind call is ever needed.
local FURNACE = { known = false, purchased = false, upgradePrice = math.huge }

-- The broadcast only arrives when something changes, so after a re-execute the
-- furnace would read as unowned until the next crate moved. The model carries
-- the truth as an attribute and it survives reloads.
local function refreshFurnaceFromWorld()
	local base = findBase()
	local furnace = base and base:FindFirstChild("Furnace")
	if not furnace then return end
	local purchased = furnace:GetAttribute("FurnacePurchased")
	if purchased ~= nil then FURNACE.purchased = purchased and true or false end
end

do
	local changed = remoteNamed("BaseCrateStateChanged")
	if changed and changed:IsA("RemoteEvent") then
		changed.OnClientEvent:Connect(function(payload)
			local furnace = type(payload) == "table" and payload.Furnace
			if type(furnace) ~= "table" then return end
			FURNACE.known = true
			FURNACE.purchased = furnace.Purchased and true or false
			FURNACE.upgradePrice = tonumber(furnace.UpgradePrice) or FURNACE.upgradePrice
		end)
	end
end

-- What the furnace can actually digest per second, read off its own board
-- ("$1,000/s"). This is the number that decides whether the furnace helps or
-- strangles the base.
function furnaceRate()
	local base = findBase()
	local furnace = base and base:FindFirstChild("Furnace")
	local label = furnace and furnace:FindFirstChild("CurrentProcessingRate", true)
	return (label and parseMoney(label.Text)) or 0
end

local function furnaceBacklog()
	local base = findBase()
	local furnace = base and base:FindFirstChild("Furnace")
	local label = furnace and furnace:FindFirstChild("AmountRemaining", true)
	return (label and parseMoney(label.Text)) or 0
end

-- Price of the next furnace upgrade, fenced off from every other purchase.
--
-- Without this the furnace never got upgraded once: drill upgrades ran on an
-- eight second timer and emptied the balance long before 100,000 could pile up,
-- so the furnace sat at its starting rate while a 28 MILLION dollar backlog
-- built up behind it - a 7.9 hour queue at $1,000/s, which cut measured income
-- from 6,529/s to 1,216/s. Clearing that bottleneck outranks another drill level
-- by a wide margin.
function furnaceReserve()
	if not (CONFIG.auto or CONFIG.autoFurnace) then return 0 end
	if not FURNACE.purchased then return 0 end
	-- Stop hoarding for it once it is comfortably ahead of what we produce;
	-- past that point the rate is no longer the thing holding the base back.
	local rate = furnaceRate()
	if INCOME.perSecond > 0 and rate >= INCOME.perSecond * 1.5 then return 0 end
	local base = findBase()
	local furnace = base and base:FindFirstChild("Furnace")
	local board = furnace and furnace:FindFirstChild("FurnaceUpgradeBoard")
	local button = board and board:FindFirstChild("UpgradeButton", true)
	local price = button and parseMoney(button.Text)
	if not price then return 0 end

	-- Reachable-from-income, same rule the drill reserve uses. The old quarter
	-- rule kept switching off: income outgrew the furnace (44.4K/s x1.5 = 66.6K/s
	-- against 87.2K/s raw, so crates go straight to the seller and the +50% is
	-- lost), and the 4,440,800 upgrade that would fix it never got saved for.
	if INCOME.perSecond > 0 then
		if price <= STATE.money + INCOME.perSecond * CONFIG.reachWithin then return price end
		return 0
	end
	if STATE.money < price * 0.25 then return 0 end
	return price
end

local function furnaceStep()
	local base = findBase()
	local furnace = base and base:FindFirstChild("Furnace")
	if not furnace then return end

	if not FURNACE.purchased then
		local prompt = furnace:FindFirstChild("PurchaseFurnacePrompt", true)
		-- the prompt is only Enabled once the balance covers it, so it doubles
		-- as the affordability check
		if prompt and prompt.Enabled and canPay(parseMoney(prompt.ObjectText)) then
			if usePrompt(prompt) then
				STATE.note = "bought furnace"
				task.wait(0.5)
			end
		end
		return
	end

	-- The upgrade price is on the furnace's own board as an UpgradeButton
	-- ("$100,000"). Reading it beats waiting for BaseCrateStateChanged, which
	-- only fires when a crate moves and so leaves the price unknown for minutes
	-- after a re-execute.
	-- Keep upgrading for as long as the balance allows. The furnace is the one
	-- purchase that gates everything behind it, so it does not wait its turn and
	-- it does not stop after one level.
	local board = furnace:FindFirstChild("FurnaceUpgradeBoard")
	for _ = 1, CONFIG.maxUpgradesPerRound do
		local button = board and board:FindFirstChild("UpgradeButton", true)
		local price = button and parseMoney(button.Text)
		if not price then price = FURNACE.known and FURNACE.upgradePrice or nil end
		-- the floor is fenced off, but nothing is fenced off FROM the furnace
		-- Fourth in the order normally, but while the furnace is below break-even
		-- it is plugging a leak rather than buying an improvement, so it may take
		-- the drill pot too - that pot was exactly what kept it under water.
		if not price or not canPay(price, guardFor("furnace")) then break end

		local response = invoke("BaseCrateAction", base.Name, "UpgradeFurnace")
		if type(response) ~= "table" or not response.success then break end
		STATE.furnaceLevel += 1
		STATE.note = string.format("furnace -> %s/s (paid %s)",
			shortNumber(furnaceRate()), shortNumber(price))
		logLine("FURNACE", string.format("upgraded to %s/s, paid %s, backlog %s, balance %s",
			shortNumber(furnaceRate()), shortNumber(price),
			shortNumber(furnaceBacklog()), shortNumber(STATE.money)))
		task.wait(0.3)
	end
end

-- Once the furnace is owned the crate takes a detour through it for +50% money:
-- carry the crate to PlaceCratesPrompt, let it process at BaseProcessingRate
-- (1000/s, x1.25 per level), then take it back out at PickUpCratesPrompt and
-- sell as usual. Both prompts are Enabled only when the step is actually
-- possible, so their state is the whole condition.
--
-- UNVERIFIED: the furnace costs $150,000 and had not been bought yet, so this
-- path has never run. It is gated behind FURNACE.purchased and cannot misfire.
local function takeCratesFromFurnace()
	if not FURNACE.purchased then return false end
	local base = findBase()
	local furnace = base and base:FindFirstChild("Furnace")
	local prompt = furnace and furnace:FindFirstChild("PickUpCratesPrompt", true)
	if not prompt or not prompt.Enabled then return false end
	if usePrompt(prompt) then
		STATE.note = "took ores from furnace"
		return true
	end
	return false
end

-- The furnace pays +50%, but only after it has processed the crate, and it
-- processes at a fixed rate. Feed it faster than that and the crates queue up:
-- measured live, a $1,000/s furnace had swallowed $28,305,327 - a 7.9 hour
-- backlog - and measured income had fallen from 6,529/s to 1,216/s. A 50% bonus
-- collected eight hours late is worth far less than selling now, so the crate
-- only goes in while the furnace can keep up, and the backlog it already holds
-- counts against it.
function furnaceWorthUsing()
	if not FURNACE.purchased then return false, "not owned" end
	local rate = furnaceRate()
	if rate <= 0 then return false, "rate unknown" end
	local income = INCOME.perSecond

	-- The break-even, done properly.
	--
	-- Feeding the furnace caps throughput at its rate but pays furnaceBonus on
	-- everything that gets through, so the comparison is
	--     min(income, rate) * bonus   against   income
	-- and the furnace wins whenever rate >= income / bonus.
	--
	-- The first version demanded rate >= 90% of income and simply forgot the
	-- bonus, which sent crates straight to the seller at 61,542/s while routing
	-- them through a 44,408/s furnace would have made 66,612/s - throwing away
	-- 8% of all income for no reason.
	if income > 0 then
		local throughFurnace = math.min(income, rate) * CONFIG.furnaceBonus
		if throughFurnace < income then
			return false, string.format("%s/s x%.1f = %s/s, under %s/s raw",
				shortNumber(rate), CONFIG.furnaceBonus,
				shortNumber(throughFurnace), shortNumber(income))
		end
	end
	local backlog = furnaceBacklog()
	if backlog > rate * CONFIG.furnaceMaxBacklog then
		return false, string.format("%s backlog (%dm)", shortNumber(backlog),
			math.floor(backlog / rate / 60))
	end
	return true
end

local function placeCratesInFurnace()
	local ok, why = furnaceWorthUsing()
	if not ok then
		STATE.furnaceSkip = why
		return false
	end
	STATE.furnaceSkip = nil

	local base = findBase()
	local furnace = base and base:FindFirstChild("Furnace")
	local prompt = furnace and furnace:FindFirstChild("PlaceCratesPrompt", true)
	if not prompt or not prompt.Enabled then return false end
	if usePrompt(prompt) then
		STATE.note = "crate into furnace"
		return true
	end
	return false
end

-- Gear ---------------------------------------------------------------------------------
--
-- GearMetadata carries both a Price (in-game money) and a DevProductId (Robux).
-- RequestGearPurchase(gearId) takes the money path - it answered NotEnoughMoney
-- rather than opening a product prompt, so the id alone is the whole call.
--
-- Only the Growth Gems are bought: they multiply ore regeneration (2x for 5
-- minutes at $500,000 up to 12x for 15 minutes) which feeds the same loop that
-- earns the money back. The Coatings apply a mutation to a single ore and are
-- left alone. Because a gem is a consumable that expires, it is only bought when
-- the balance is a full order of magnitude above its price - otherwise it is
-- simply a worse buy than another drill level.
-- Growth gems are the best money in the game and were being ignored.
--
-- They multiply ore REGENERATION, which is the exact thing every drone is
-- waiting on (all four report OreNotReady), and they apply themselves the moment
-- they are bought - no tool to equip, GrowthGemInventoryCount drops straight back
-- to zero and the tunnel's GrowthMultiplier attribute goes to the gem's value.
--
-- Worked out at 80,017/s income:
--   Small  x2 for  5m at        500,000 -> ~12,100,000 gained,  24.3x
--   Large  x4 for 10m at     50,000,000 -> ~72,800,000 gained,   1.5x
--   Super  x6 for 15m at 15,000,000,000 -> ~182,000,000 gained,  0.01x
--
-- So it is ranked by return, not by price - the old version bought the most
-- EXPENSIVE affordable gem, which is precisely backwards.
local function buyGear()
	local ok, metadata = pcall(function()
		return require(ReplicatedStorage:WaitForChild("GearMetadata", 10))
	end)
	if not ok or type(metadata) ~= "table" or type(metadata.List) ~= "function" then return end

	local listed = select(2, pcall(metadata.List))
	if type(listed) ~= "table" then return end
	if INCOME.perSecond <= 0 then return end

	refreshMoney()
	local spendable = math.max(STATE.money - guardFor("gem"), 0)

	local best
	for _, gear in pairs(listed) do
		if type(gear) == "table" and gear.Category == "GrowthGem" and gear.Id then
			local price = tonumber(gear.Price)
			local multiplier = tonumber(gear.Multiplier)
			local duration = tonumber(gear.DurationSeconds)
			if price and multiplier and duration and price > 0 then
				-- extra income the boost produces over its lifetime
				local gain = INCOME.perSecond * (multiplier - 1) * duration
				local ratio = gain / price
				if ratio >= CONFIG.gemMinReturn and price <= spendable
					and (not best or ratio > best.ratio) then
					best = { gear = gear, price = price, ratio = ratio }
				end
			end
		end
	end

	if not best then return end
	local response = invoke("RequestGearPurchase", best.gear.Id)
	if type(response) == "table" and response.success then
		STATE.gear += 1
		STATE.note = string.format("%s (%.0fx return)",
			tostring(best.gear.DisplayName or best.gear.Id), best.ratio)
		logLine("GEM", string.format("%s paid %s, %.1fx return, balance %s",
			tostring(best.gear.DisplayName), shortNumber(best.price), best.ratio,
			shortNumber(STATE.money)))
	end
end

-- Showcase pedestals -------------------------------------------------------------------
--
-- Two pedestals in the base grant a money multiplier while you are online. The
-- board button fires ShowcasePedestalAction(action, pedestalNumber, baseName) -
-- note the order, the base name comes LAST here while every other remote in this
-- game takes it first. "Purchase" is the only action it accepts; the boost is
-- then activated by placing an ore on the pedestal itself.
--
-- Its reply carries the full state even when it fails, so the price is known
-- without ever having to risk a blind purchase.
local function buyShowcasePedestals()
	local base = findBase()
	if not base then return end

	for index = 1, 2 do
		local response = invoke("ShowcasePedestalAction", "Purchase", index, base.Name)
		local state = type(response) == "table" and response.state or nil
		if state and not state.Unlocked and state.Price then
			if canPay(state.Price) then
				local retry = invoke("ShowcasePedestalAction", "Purchase", index, base.Name)
				if type(retry) == "table" and retry.success then
					STATE.note = "boost pedestal " .. index
					task.wait(0.3)
				end
			end
		end
	end
end

-- Rewards -----------------------------------------------------------------------------
--
-- All of these are remote-only, no walking to a board. Every one is checked
-- against its own state remote first so nothing is fired that could fail.
local function claimRewards()
	local before = STATE.money

	local daily = invoke("GetDailyRewardsState")
	if type(daily) == "table" and daily.isAvailable then
		local remote = remoteNamed("ClaimDailyReward")
		if remote then pcall(function() remote:FireServer() end) end
		task.wait(0.4)
	end

	-- The playtime rewards want the reward INDEX. Firing without one claims
	-- nothing; index 4 alone was worth $25,000 sitting unclaimed.
	local playtime = invoke("PlaytimeRewardsGetState")
	if type(playtime) == "table" and type(playtime.rewards) == "table" then
		local claim = remoteNamed("PlaytimeRewardsClaim")
		if claim then
			for _, reward in ipairs(playtime.rewards) do
				if not reward.claimed and (playtime.elapsed or 0) >= (reward.unlockAt or math.huge) then
					pcall(function() claim:FireServer(reward.index) end)
					STATE.note = "playtime reward " .. tostring(reward.index)
					task.wait(0.35)
				end
			end
		end
	end

	invoke("OfflineEarningsClaimRequest")

	-- Spin out everything banked.
	--
	-- `remaining` is only the countdown to the NEXT free spin, not a lock, and
	-- `spins` is the number already sitting there. The old rule demanded
	-- remaining <= 5 as well, so once spins accumulated they were never used -
	-- fourteen were banked and untouched. Each RequestLuckySpin consumes exactly
	-- one (14 -> 13, verified), and the reward is granted by the request itself;
	-- CompleteLuckySpin only confirms the animation.
	--
	-- The wheel pays gear, ore and time skips only - LuckySpinConfig.Products
	-- lists the Robux products separately and nothing here can reach them.
	local spin = invoke("GetLuckySpinState")
	local available = type(spin) == "table" and (tonumber(spin.spins) or 0) or 0
	for _ = 1, math.min(available, CONFIG.maxSpinsPerRound) do
		local result = invoke("RequestLuckySpin")
		if type(result) ~= "table" or not result.ok then break end
		if result.spinId then invoke("CompleteLuckySpin", result.spinId) end
		STATE.spins += 1
		STATE.note = "spin: " .. tostring(result.reward)
		logLine("SPIN", string.format("%s (%d left)", tostring(result.reward), available - _))
		task.wait(0.3)
	end

	refreshMoney()
	local gained = STATE.money - before
	if gained > 0 then
		STATE.earned += gained
		STATE.note = "claimed " .. shortNumber(gained)
	end
end

-- Everything the balance can be turned into, cheapest and most compounding
-- first: roller quality, then more drills, then a new floor, then drill levels,
-- then the furnace multiplier.
local function spendMoney()
	-- Order set by the user, and it overrides the payback maths on purpose:
	--
	--   1. drill upgrades   2. the ore itself   3. ore levels   4. furnace
	--
	-- Drill upgrades come first and are NOT held back by any reserve. Floor 1 sat
	-- half upgraded for hours because the reserves for floor 5 (10,000,000) and
	-- the next tunnel fenced off more money than the balance ever held, so the
	-- boards never got touched no matter how much came in.
	-- Exception to the order, and the only one: while the furnace sits BELOW its
	-- break-even it is not an upgrade competing for budget, it is a hole. Every
	-- crate then skips it and loses the +50%, which at the measured numbers costs
	-- 16,599 a second continuously.
	--
	--   furnace, two levels   9,991,800  ->  +16,599/s   repays in    601s
	--   top drill board      11,641,046  ->     +379/s   repays in 30,696s
	--
	-- Fifty-one times the return, and the drill reserve was fencing off the money
	-- that would have fixed it. So while it is under water the furnace goes
	-- first and ignores the drill pot; once it is above, it drops back to fourth
	-- where it belongs.
	local furnaceUnderwater = FURNACE.purchased and not furnaceWorthUsing()
	if furnaceUnderwater and (CONFIG.auto or CONFIG.autoFurnace) then
		pcall(furnaceStep)
	end

	if CONFIG.auto or CONFIG.autoUpgrade then pcall(buyUpgrades) end

	-- 2. buying the rolled ore happens in the cycle itself; what belongs here is
	--    leaving its savings target alone, which every step below honours.
	-- 3. the per-tunnel ore levels
	if CONFIG.auto or CONFIG.autoOreLevel then pcall(upgradeOreLevels) end

	-- 4. the furnace, which is still a throughput ceiling but no longer allowed
	--    to outbid the drills that feed it
	if CONFIG.auto or CONFIG.autoFurnace then pcall(furnaceStep) end

	-- Everything structural comes after: more drills only pay once the drills
	-- already standing are worth running.
	if CONFIG.auto or CONFIG.autoFloors then pcall(unlockFloor) end
	if CONFIG.auto or CONFIG.autoTunnels then
		pcall(buyTunnels)
		-- a fresh tunnel is an empty drill; fill it from the inventory at once
		if CONFIG.auto or CONFIG.autoEquip then pcall(equipBest) end
	end
	if CONFIG.auto or CONFIG.autoRoller then pcall(buyRollerUpgrades) end
	if CONFIG.auto or CONFIG.autoBoost then pcall(buyShowcasePedestals) end
	if CONFIG.auto or CONFIG.autoGear then pcall(buyGear) end
end

-- Cycle -------------------------------------------------------------------------

-- One switch runs the whole thing in the order that actually makes sense.
--
-- Every step runs on every pass. The earlier version returned as soon as one
-- step did something, and because selling and picking up crates ALWAYS have
-- work, the loop never got past them: 41 sells against 1 roll, 0 tunnels and
-- 0 floors. Returning early starves the half of the game that compounds.
--
-- Order matters: sell first so the hands are empty, then buy and roll ore
-- (which needs free hands), and only then pick the next crate back up.
local lastSpend = 0

local function cycle()
	refreshMoney()

	-- An event machine hovers for a few minutes and mutates the ore underneath
	-- it. Nothing has to be collected, but the roll rules loosen while it runs
	-- and the tunnels are re-stocked so the mutated ore is the ore in use.
	sampleIncome()
	refreshFurnaceFromWorld()
	EVENT.active = eventModelPresent() ~= nil
		or (EVENT.mutation ~= "" and os.clock() - EVENT.startedAt < CONFIG.eventWindow)
	if EVENT.active and (CONFIG.auto or CONFIG.autoEquip) then pcall(equipBest) end

	-- Anything the furnace has finished is worth +50%, so it comes out first and
	-- is sold in the same pass.
	if CONFIG.auto or CONFIG.autoFurnace then pcall(takeCratesFromFurnace) end

	if CONFIG.auto or CONFIG.autoSell then
		if sellOres() then STATE.phase = "sold" end
	end

	if CONFIG.auto or CONFIG.autoBuyOre then
		if buyRolledOre() then
			STATE.phase = "bought ore"
			-- a bought ore sits in the inventory until something equips it
			if CONFIG.auto or CONFIG.autoEquip then pcall(equipBest) end
		end
	end

	if CONFIG.auto or CONFIG.autoRoll then
		-- Never reroll over an ore that is worth having and within reach: the
		-- roll replaces all three pedestals at once, so one careless pull throws
		-- away every pending drop.
		local keep, pending, seconds = pendingWorthKeeping()
		if keep then
			STATE.phase = "saving for " .. tostring(pending and pending.oreName or "ore")
			STATE.note = string.format("waiting on %s (%s, %s)",
				tostring(pending and pending.oreName),
				shortNumber(pending and pending.seedCost or 0),
				(seconds or 0) > 0 and (math.floor(seconds) .. "s away") or "affordable")
		else
			-- Snapshot what is about to be destroyed BEFORE pulling the lever.
			-- The first version logged and cleared ROLLED *after* roll(), which
			-- meant it wiped the roll that had just landed - so the buy step
			-- always found an empty table, nothing was ever bought, and the log
			-- filled with "dropped ... (affordable now)" for ore that had only
			-- existed for a fraction of a second.
			local doomed = {}
			for pedestal, result in pairs(ROLLED) do doomed[pedestal] = result end

			for _, result in pairs(doomed) do
				local cost = tonumber(result.seedCost) or 0
				local _, why = oreWanted(result)
				local canReach, seconds = reachable(cost)
				-- reachable() returns 0 seconds for something already affordable,
				-- which the first version printed as "unreachable" - the exact
				-- opposite. Say why it was dropped, not just how far away it was.
				local distance
				if canReach and (seconds or 0) <= 0 then
					distance = "affordable now"
				elseif canReach then
					distance = math.floor(seconds) .. "s away"
				elseif (seconds or -1) > 0 then
					distance = math.floor(seconds) .. "s away, too far"
				else
					distance = "out of reach"
				end
				logLine("REROLL", string.format("dropped %s %s cost %s (%s) - %s",
					tostring(result.oreName), tostring(result.rarity), shortNumber(cost),
					distance, why))
			end
			-- Clear only the entries the lever is about to replace, then roll.
			-- ROLLED is refilled by the RollerRollEvent broadcast a moment later
			-- and must not be touched after that.
			for pedestal in pairs(doomed) do ROLLED[pedestal] = nil end

			if roll() then
				STATE.phase = "rolled"
				task.wait(1.2)
				if CONFIG.auto or CONFIG.autoBuyOre then
					if buyRolledOre() and (CONFIG.auto or CONFIG.autoEquip) then pcall(equipBest) end
				end
			end
		end
	end

	if CONFIG.auto or CONFIG.autoPickup then
		if pickUpCrate() then
			STATE.phase = "picked up"
			-- with a furnace the fresh crate goes in there instead of straight
			-- to the seller table; without one this is a no-op
			if CONFIG.auto or CONFIG.autoFurnace then pcall(placeCratesInFurnace) end
		end
	end

	-- Spending walks no distance but does talk to the server a lot, so it runs
	-- on its own interval rather than on every pass through the crate loop.
	if os.clock() - lastSpend >= CONFIG.spendEvery then
		lastSpend = os.clock()
		spendMoney()
		STATE.phase = "spent"
	end
end

-- Diagnosis -------------------------------------------------------------------------
--
-- What the script itself believes is holding the base back right now, in plain
-- words. Every line is derived from a number it already measured, so it is a
-- read-out of the actual decision inputs, not a guess.
local function bottleneck()
	local out = {}

	-- drones idling on regrowth
	local idle = 0
	for _, drone in ipairs(droneState()) do
		if drone.waitingOnOre then idle += 1 end
	end
	if idle > 0 then
		out[#out + 1] = string.format("%d/%d floors idle waiting for ore to regrow",
			idle, #droneState())
	end

	-- furnace throughput
	local rate = furnaceRate()
	if FURNACE.purchased and rate > 0 and INCOME.perSecond > 0 then
		if rate < INCOME.perSecond then
			out[#out + 1] = string.format("furnace %s/s under income %s/s - crates sold raw",
				shortNumber(rate), shortNumber(INCOME.perSecond))
		end
		local backlog = furnaceBacklog()
		if backlog > rate * 60 then
			out[#out + 1] = string.format("furnace backlog %s (%d min)",
				shortNumber(backlog), math.floor(backlog / rate / 60))
		end
	elseif not FURNACE.purchased then
		out[#out + 1] = "furnace not bought (+50% money)"
	end

	-- empty tunnels
	for _, floor in ipairs(unlockedFloors()) do
		local drills = LOADOUT.perFloor[floor.number] or 0
		if LOADOUT.count > 0 and drills < 7 then
			out[#out + 1] = string.format("floor %d has %d/7 drills", floor.number, drills)
		end
	end

	-- what the money is being held for
	local goalName, goalCost = activeReserve()
	if goalName and goalCost > 0 then
		out[#out + 1] = string.format("saving %s for %s (have %s)",
			shortNumber(goalCost), goalName, shortNumber(STATE.money))
	end
	local drill = drillReserve()
	if drill > 0 then
		out[#out + 1] = string.format("holding %s for the next drill board", shortNumber(drill))
	end
	if SAVING.ore then
		out[#out + 1] = string.format("holding %s for %s", shortNumber(SAVING.cost), SAVING.ore)
	end

	-- weakest slot
	if LOADOUT.count > 0 then
		out[#out + 1] = string.format("weakest drill runs %.1f/s ore - only better rolls are bought",
			LOADOUT.worstRate)
	end

	if #out == 0 then out[1] = "nothing blocking - everything affordable is being bought" end
	return out
end

-- The last few things that actually happened, newest first, in plain words.
local function recentActions(count)
	local out = {}
	for i = #LOG, 1, -1 do
		out[#out + 1] = LOG[i]
		if #out >= (count or 5) then break end
	end
	return out
end

-- UI ------------------------------------------------------------------------------
--
-- Built from ui-template.lua, the shared house design ported from the
-- Bloodline-style mock. The look lives there; only the pages are game specific.

local UI
do
	local ok, result = pcall(function()
		-- hub first, readfile is the fallback for a hand-shipped run
		return (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
	end)
	if not ok or type(result) ~= "table" then
		error("[sellores] ui-template.lua could not be loaded - put it in the "
			.. "executor workspace folder next to this script (" .. tostring(result) .. ")")
	end
	UI = result
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("sellores", CONFIG)

local win = UI.Window({
	name = "SellOres",
	title = "SELL",
	accentTitle = "ORES",
	subtitle = "seltonmt",
	badge = "⛏",
	width = 920,
	height = 580,
})
_G.__SELLORES_GUI = win.gui

local function toggle(card, text, key, hint, tone, onChange)
	return card:Toggle(text, CONFIG[key], function(value)
		CONFIG[key] = value
		if onChange then onChange(value) end
	end, hint, tone)
end

-- FARMING ---------------------------------------------------------------------
local farmPage = win:Page("FARMING", UI.icon.pickaxe)

local masterCard = farmPage:Card("MASTER", 1)
toggle(masterCard, "AUTO (everything, in order)", "auto",
	"leaks first, then drills, ores, ore levels, furnace", UI.theme.warn)
masterCard:Stepper("Cycle wait",
	function() return string.format("%.1fs", CONFIG.cycleWait) end,
	function(delta)
		CONFIG.cycleWait = math.clamp(CONFIG.cycleWait + delta * 0.5, 0.5, 10)
	end)

local oreCard = farmPage:Card("ORE", 1)
toggle(oreCard, "Auto Roll", "autoRoll",
	"one roll replaces all pedestals, so it waits for a keeper")
toggle(oreCard, "Buy rolled ore", "autoBuyOre",
	"prompt under LocalRollingOreDisplay, not PurchaseOrePrompt")
local refreshPrice = oreCard:Stepper("Max payback",
	function() return math.floor(CONFIG.maxPayback / 60) .. "m" end,
	function(delta)
		local steps = { 120, 300, 600, 900, 1800, 3600, 7200, 21600, 86400 }
		local index = 1
		for i, v in ipairs(steps) do if CONFIG.maxPayback >= v then index = i end end
		CONFIG.maxPayback = steps[math.clamp(index + delta, 1, #steps)]
	end,
	"seedCost / income per second, cheap ore beats rare ore")
toggle(oreCard, "Equip best ores", "autoEquip",
	"EquipBest re-stocks every tunnel on every floor")
toggle(oreCard, "Level up ores", "autoOreLevel",
	"income +12% per level; the biggest lever in the game")

local crateCard = farmPage:Card("CRATES", 2)
toggle(crateCard, "Pick up crates", "autoPickup")
toggle(crateCard, "Sell ores", "autoSell")
toggle(crateCard, "Furnace (+50%)", "autoFurnace",
	"only while its throughput beats raw income")

local rewardCard = farmPage:Card("FREE MONEY", 2)
toggle(rewardCard, "Claim rewards", "autoRewards",
	"daily, playtime, offline earnings and the lucky spin")
rewardCard:Button("Claim everything now", claimRewards)

local quickCard = farmPage:Card("MANUAL", 2)
quickCard:Button("Roll once", roll)
quickCard:Button("Pick up + sell now", function()
	pickUpCrate()
	task.wait(0.5)
	sellOres()
end)

-- SPENDING --------------------------------------------------------------------
local spendPage = win:Page("SPENDING", UI.icon.coin)

local drillCard = spendPage:Card("DRILLS", 1)
toggle(drillCard, "Buy drill upgrades", "autoUpgrade",
	"each board holds three: yield, speed, regen", UI.theme.warn)

local baseCard = spendPage:Card("BASE", 1)
toggle(baseCard, "Buy tunnels", "autoTunnels")
toggle(baseCard, "Unlock floors", "autoFloors",
	"unlocking a floor collapses its tunnel prices")

local rollerCard = spendPage:Card("ROLLER", 2)
toggle(rollerCard, "Buy roller upgrades", "autoRoller",
	"ore luck and pedestal count, pedestals cap at 6")

local extraCard = spendPage:Card("EXTRAS", 2)
toggle(extraCard, "Boost pedestals", "autoBoost",
	"a permanent while-online money multiplier")
toggle(extraCard, "Buy growth gems", "autoGear",
	"ranked by income x (mult-1) x duration / price", UI.theme.warn)

local reserveCard = spendPage:Card("RESERVE", 0)
local reserveOut = reserveCard:Readout(6)

-- STATUS ----------------------------------------------------------------------
local statusPage = win:Page("STATUS", UI.icon.chart)

local incomeCard = statusPage:Card("INCOME", 1)
local incomeOut = incomeCard:Readout(7)

local floorCard = statusPage:Card("FLOORS", 2)
local floorOut = floorCard:Readout(14)

local blockCard = statusPage:Card("WHAT IS HOLDING US BACK", 0)
local blockOut = blockCard:Readout(8)

local recentCard = statusPage:Card("LAST 5 ACTIONS", 0)
local recentOut = recentCard:Readout(5)

-- LOG -------------------------------------------------------------------------
local logPage = win:Page("LOG", UI.icon.list)

local logCard = logPage:Card("DECISIONS", 0)
-- Colour the log by what the line did, so a long run can be skimmed.
local logOut = logCard:Readout(26, function(text)
	if text:find("ORE%-LEVEL") then return UI.theme.good end
	if text:find("UPGRADE") then return UI.theme.accent end
	if text:find("REROLL") then return UI.theme.warn end
	return nil
end)

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste -
-- er ist immer das erste Icon und die Seite, auf der das Panel aufgeht.
pcall(function() win:Home() end)

win:Refresh()


-- Loops ---------------------------------------------------------------------------

task.spawn(function()
	while _G.__SELLORES == generation do
		pcall(cycle)
		task.wait(CONFIG.cycleWait)
	end
end)

task.spawn(function()
	while _G.__SELLORES == generation do
		pcall(refreshMoney)
		task.wait(2)
	end
end)

task.spawn(function()
	while _G.__SELLORES == generation do
		if CONFIG.auto or CONFIG.autoRewards then pcall(claimRewards) end
		task.wait(120)
	end
end)

task.spawn(function()
	while _G.__SELLORES == generation do
		refreshPrice()

		-- The header line stays readable with the panel collapsed, so it holds
		-- the four numbers worth glancing at.
		win:SetStatus(string.format("%s   %s/s   furnace %s/s   stock %d   %s%s",
			STATE.moneyText, shortNumber(INCOME.perSecond), shortNumber(furnaceRate()),
			STATE.inventory, STATE.phase,
			EVENT.active and ("   EVENT " .. (EVENT.title ~= "" and EVENT.title
				or (eventModelPresent() or ""))) or ""))

		incomeOut:set({
			"INCOME",
			string.format("  %s per second", shortNumber(INCOME.perSecond)),
			string.format("  %s per minute", shortNumber(INCOME.perSecond * 60)),
			string.format("  furnace  %s/s", shortNumber(furnaceRate())),
			string.format("  balance  %s", shortNumber(STATE.money)),
			string.format("  earned   %s", shortNumber(STATE.earned)),
			string.format("  rolls %d  ore %d  lvl %d  sells %d",
				STATE.rolls, STATE.oresBought, STATE.oreLevels, STATE.sells),
		})

		do
			local lines = { "FLOORS" }
			for _, line in ipairs(drillState()) do lines[#lines + 1] = "  " .. line end
			floorOut:set(lines)
		end

		do
			local lines = {}
			for _, line in ipairs(bottleneck()) do lines[#lines + 1] = line end
			blockOut:set(lines)
		end

		recentOut:set(recentActions(5))

		do
			-- activeReserve returns the single best-value target, never a sum:
			-- summing reserves once fenced off more than the whole balance and
			-- froze every purchase in the game.
			local name, cost, payback = activeReserve()
			reserveOut:set({
				"RESERVE",
				string.format("  saving for  %s", name or "nothing"),
				string.format("  held back   %s", shortNumber(cost or 0)),
				string.format("  spendable   %s",
					shortNumber(math.max(0, (STATE.money or 0) - (cost or 0)))),
				string.format("  payback     %s",
					payback and string.format("%.0fs", payback) or "-"),
				string.format("  upgrades %d  tunnels %d", STATE.upgrades, STATE.tunnels),
			})
		end

		logOut:set(recentActions(26))

		task.wait(0.5)
	end
	win:Destroy()
end)

_G.__SELLORES_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	roll = roll, buyRolledOre = buyRolledOre, pickUpCrate = pickUpCrate, sellOres = sellOres,
	buyUpgrades = buyUpgrades, claimRewards = claimRewards, findBase = findBase,
	refreshMoney = refreshMoney, parseMoney = parseMoney,
	buyRollerUpgrades = buyRollerUpgrades, buyTunnels = buyTunnels,
	unlockFloor = unlockFloor, furnaceStep = furnaceStep, spendMoney = spendMoney,
	unlockedFloors = unlockedFloors, priceNextTo = priceNextTo, FURNACE = FURNACE,
	buyShowcasePedestals = buyShowcasePedestals, ROLLED = ROLLED, cycle = cycle,
	equipBest = equipBest, oreWanted = oreWanted, orePayback = orePayback,
	pendingWorthKeeping = pendingWorthKeeping, EVENT = EVENT, ORES = ORES,
	buyGear = buyGear,
	eventModelPresent = eventModelPresent, orePatience = orePatience,
	takeCratesFromFurnace = takeCratesFromFurnace, placeCratesInFurnace = placeCratesInFurnace,
	levelFromBoard = levelFromBoard, reachable = reachable, INCOME = INCOME,
	sampleIncome = sampleIncome, LOG = LOG, tail = tailLog, LOADOUT = LOADOUT,
	furnaceRate = furnaceRate, furnaceBacklog = furnaceBacklog,
	furnaceWorthUsing = furnaceWorthUsing, furnaceReserve = furnaceReserve,
	floorReserve = floorReserve, reservedMoney = reservedMoney,
	tunnelReserve = tunnelReserve, oreRate = oreRate,
	SAVING = SAVING, oreReserve = oreReserve, reservedExcept = reservedExcept,
	activeReserve = activeReserve, drillState = drillState, goalPayback = goalPayback,
	droneState = droneState, upgradeOreLevels = upgradeOreLevels,
	drillReserve = drillReserve, bottleneck = bottleneck, recentActions = recentActions,
}

-- Mirror the decision log to disk so a long unattended run can be read back
-- afterwards, not just the last 400 lines held in memory.
task.spawn(function()
	if not writefile then return end
	local written = 0
	while _G.__SELLORES == generation do
		if #LOG > written then
			local chunk = {}
			for i = written + 1, #LOG do chunk[#chunk + 1] = LOG[i] end
			written = #LOG
			pcall(function()
				local existing = (isfile and isfile("sellores-log.txt") and readfile("sellores-log.txt")) or ""
				writefile("sellores-log.txt", existing .. table.concat(chunk, "\n") .. "\n")
			end)
		end
		task.wait(10)
	end
end)

findBase()
refreshMoney()
print("[sellores] by seltonmt - running (gen " .. generation .. ") - RightShift toggles the UI")
