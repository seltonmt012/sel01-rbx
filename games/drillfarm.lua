--!nocheck
-- [Make a Drill Farm] - place 79315121100812, by seltonmt
--
-- The game runs on Knit, so every action is a plainly named RemoteFunction under
-- ReplicatedStorage.Source.Packages._Index.sleitnick_knit@1.5.1.knit.Services.
-- Nothing here was guessed; each claim below was measured through the bridge.
--
-- The loop: pull the lever -> a drill lands on a roll spot -> pay to keep it ->
-- place it on the grid -> it mines ore -> the miner carries ore to the minecart
-- -> ore turns into cash at 1 ore = $1.
--
-- Verified against server side values:
--
--   * SpinDrillService.RF.RequestSpin() takes NO arguments and returns true.
--     The return proves nothing - a bare call still counted while the inventory
--     stayed empty. The DailySpins quest counter moving 7 -> 8 is what proved it
--     works. SpinCooldown is 5s and SpinDuration 3s, so a spin fired inside the
--     cooldown is silently dropped while still answering true.
--
--   * The result does NOT go to the inventory on its own. It waits on the roll
--     spot and has to be bought:
--
--       OnSpinStartedSignal(baseName, {spot -> drillId}, {spot -> resultId},
--                           globalFeed, lockedSpots)
--       SpinDrillService.RF.BuyResult(resultId) -> (ok, message)
--
--     resultId is a GLOBAL incrementing integer, not the spot index. Calling
--     BuyResult(1) / (2) / (3) always answered "That drill is no longer
--     available." until the id was read off the signal. Verified: BuyResult
--     (42556) -> true, "You bought the Rusty Drill!", and Drill1 appeared in the
--     inventory. The cost is DrillsMetadata[id].Price.
--
--   * Results expire. Buying four minutes after the spin failed with the same
--     "no longer available", so the buy has to follow the spin immediately.
--
--   * Everything on the plot is a ProximityPrompt. Census of one base:
--     UnlockPrompt 504, PlacePrompt 336, LeverPrompt 1, CollectOresPrompt 1,
--     DepositOresPrompt 1, DialogPrompt 1. Prompts go straight to the server,
--     which is why a __namecall hook sees no traffic when a drill is placed.
--
--   * There is NO sell prompt anywhere in the game. Depositing IS selling: the
--     ore turns into cash at the minecart at 1 ore = $1, which is what the green
--     "SELL ORES" label on the deposit zone means. AutoSellSign is the 180 Robux
--     gamepass that does the collecting for you, and it is never touched.
--
--   * Grid cells are bought, not free: UnlockPrompt carries the price in its
--     prompt text ($1000, $16K, $96M, $1B ...). More cells is the only way to
--     run more drills at once, so unlocking outranks most other spending.
--
--   * Prices read off the plot signs: roll spot 2 = $2.5K, roll luck 1 = $5K,
--     ores per hit 10 -> 15 = $87, bonus chance 1 = $70K, player speed = $4B,
--     faster build time = $8T. Exchange rate is 1 ore = $1.
--
-- NOT solved, and deliberately left out rather than shipped broken:
--
--   * Placing a drill. Progress, but not solved:
--       - Knit.GetController("GridController"):SetPlacementMode(uid) DOES work
--         and flips 12 PlacePrompts from Enabled=false to true, so the client
--         side of placement is reachable.
--       - Firing one of those enabled prompts still places nothing (3 -> 3).
--       - HeldDrillMutationController._onToolEquipped shows drills become real
--         Tools when equipped, so the server almost certainly checks for the
--         Tool in the character, not for the client's placement mode.
--       - Dead ends: InventoryService.RE.OnEquippedChangedSignal fired client ->
--         server is ignored, the Equip Best button has 0 Activated connections
--         (1 on MouseButton1Down, firing it changed nothing), the inventory grid
--         only fills once the panel is genuinely opened, and no remote traffic
--         appears when a drill is placed by hand.
--     Auto placing is therefore OFF. Bought drills wait in the inventory for you
--     to place them, and the panel says so instead of pretending otherwise.
--
-- Never touched, all Robux: InstantSkip (49R$), SkipProcessing (15R$), AutoSell
-- (180R$), AdService.ShowRewardedAd, RequestAdSkip, RequestAdSkipBuild,
-- MonetizationService, GemShop, CandyBundle, MoneyDeal, SpecialOffer.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local plr = Players.LocalPlayer

local CONFIG = {
	auto = false,             -- master switch, runs everything below in order

	autoSpin = false,         -- pull the lever on cooldown
	autoBuy = false,          -- buy the rolled result
	minRarity = 1,            -- index into RARITY_ORDER, buy nothing below it
	maxSpend = 0.5,           -- share of the balance a single result may cost
	bagBeforePicky = 3,       -- drills waiting unplaced before only upgrades are bought

	autoCollect = false,      -- collect ore and carry it to the minecart
	collectEvery = 12,

	autoCells = false,        -- unlock grid cells, the only way to run more drills
	autoMiner = false,        -- ores per hit + bonus chance
	autoLever = false,        -- roll spots + roll luck
	autoPickaxe = false,      -- forge the pickaxe with essence
	autoSpeed = false,        -- player speed, very expensive
	autoBuildTime = false,    -- faster build time, very expensive

	autoRewards = false,      -- daily, offline, group, quests, wheel
	autoRebirth = false,      -- only once the requirements are actually met

	reserveShare = 0.25,      -- keep this share of the balance for results
}

local STATE = {
	cash = 0, gems = 0,
	spins = 0, bought = 0, skipped = 0, spent = 0,
	collects = 0, deposits = 0, upgrades = 0, claims = 0, rebirths = 0, cells = 0,
	lastDrill = "-", lastResult = "-", phase = "idle", note = "-",
	placed = 0, inventory = 0, spots = 0,
	oresPerHit = 0, minerLuck = 0, rollLuck = 0,
	pickaxe = "-", pickaxeLevel = 0,
	blocked = "-",
}

_G.__DRILLFARM = (_G.__DRILLFARM or 0) + 1
local generation = _G.__DRILLFARM
if _G.__DRILLFARM_GUI then pcall(function() _G.__DRILLFARM_GUI:Destroy() end) end

-- Knit ------------------------------------------------------------------------

local KNIT = ReplicatedStorage.Source.Packages._Index["sleitnick_knit@1.5.1"].knit.Services

-- Every call is pcall'd and returns all results, because a Knit RF answers
-- (false, "reason") on a refusal rather than throwing. Swallowing the second
-- value would throw away the only explanation the server gives.
local function rf(service, name, ...)
	local s = KNIT:FindFirstChild(service)
	local folder = s and s:FindFirstChild("RF")
	local remote = folder and folder:FindFirstChild(name)
	if not remote then return nil, "no such remote: " .. service .. "." .. name end
	local packed = table.pack(pcall(remote.InvokeServer, remote, ...))
	if not packed[1] then return nil, tostring(packed[2]) end
	return packed[2], packed[3]
end

local function re(service, name)
	local s = KNIT:FindFirstChild(service)
	local folder = s and s:FindFirstChild("RE")
	return folder and folder:FindFirstChild(name)
end

-- Metadata --------------------------------------------------------------------

local DRILLS = require(ReplicatedStorage.Source.Metadatas.DrillsMetadata)
local RARITIES = require(ReplicatedStorage.Source.Metadatas.RaritiesMetadata)
local LEVER = require(ReplicatedStorage.Source.Metadatas.LeverMetadata)
local MINER = require(ReplicatedStorage.Source.Metadatas.MinerMetadata)

local RARITY_ORDER = { "Common", "Uncommon", "Rare", "Epic", "Legendary",
	"Mythical", "Prismatic", "Limited" }

local function rarityRank(name)
	local values = RARITIES.Values or {}
	return values[name] or 0
end

local function shortNumber(n)
	n = tonumber(n) or 0
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, unit in ipairs(units) do
		if math.abs(n) >= unit[1] then
			return string.format("%.1f%s", n / unit[1], unit[2])
		end
	end
	return string.format("%d", n)
end

-- Base ------------------------------------------------------------------------

local BASE_NAME = "Player_" .. plr.UserId

local function base()
	local bases = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Bases")
	return bases and bases:FindFirstChild(BASE_NAME)
end

local function rootPart()
	local char = plr.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Cash is only exposed as a formatted leaderstats string ("4.19K"), so it has to
-- be parsed back. The suffixes come from the game's own Suffixes package order.
-- Built from the game's own Suffixes package rather than guessed. Guessing cost
-- a real bug: the table said Qa for quadrillion while the game uses Q, so a
-- "$1.56Q" unlock parsed as $1.56 and looked like the cheapest prompt on the
-- plot when it was in fact the most expensive. The package is an array where
-- index 1 is units, 2 is K, 3 is M, so entry i is 10^(3*(i-1)).
local SUFFIX = {}
do
	local ok, list = pcall(require, ReplicatedStorage.Source.Packages.Suffixes)
	if ok and type(list) == "table" then
		for index, name in pairs(list) do
			if type(index) == "number" and type(name) == "string" and name ~= "" then
				SUFFIX[name] = 10 ^ (3 * (index - 1))
			end
		end
	end
end

-- Returns nil when the suffix is not one the game uses. A number that cannot be
-- read must never fall back to "that many dollars" - that is how a quadrillion
-- became 1.56.
local function parseCash(text)
	text = tostring(text):gsub("[%$,%s]", "")
	local number, suffix = text:match("^([%d%.]+)(%a*)$")
	if not number then return nil end
	if suffix == "" then return tonumber(number) end
	local scale = SUFFIX[suffix]
	if not scale then return nil end
	return tonumber(number) * scale
end

local function refreshCash()
	local stats = plr:FindFirstChild("leaderstats")
	local cash = stats and stats:FindFirstChild("Cash")
	local parsed = cash and parseCash(cash.Value)
	if parsed then STATE.cash = parsed end
	return STATE.cash
end

-- Prompts ---------------------------------------------------------------------

-- Prompts validate against the server's copy of the character position, so a
-- one-shot CFrame write is not enough. Pinning on Heartbeat for a moment first
-- is what makes them fire reliably - the same lesson as Sell Ores.
local function firePrompt(prompt, settle)
	if not prompt or not prompt.Enabled then return false end
	local root = rootPart()
	if not root then return false end

	-- Prompts here hang off Attachments (PlacePromptAttach, UnlockPromptAttach),
	-- so WorldPosition is the exact spot; the parent part is only a fallback.
	local anchor = prompt.Parent
	local position
	if anchor:IsA("Attachment") then
		position = anchor.WorldPosition
	elseif anchor:IsA("BasePart") then
		position = anchor.Position
	elseif anchor.Parent and anchor.Parent:IsA("BasePart") then
		position = anchor.Parent.Position
	elseif anchor.Parent then
		position = anchor.Parent:GetPivot().Position
	end
	if not position then return false end

	local home = root.CFrame
	local pin = RunService.Heartbeat:Connect(function()
		root.CFrame = CFrame.new(position + Vector3.new(0, 4, 0))
	end)
	task.wait(settle or 1.2)
	local ok = pcall(fireproximityprompt, prompt)
	task.wait(0.2)
	pin:Disconnect()
	root.CFrame = home
	return ok
end

local function findPrompt(name)
	local root = base()
	if not root then return nil end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == name then return d end
	end
	return nil
end

-- Spinning --------------------------------------------------------------------

-- The result of a spin lives on the signal, not on any instance we can read
-- back, so the listener is installed once and keeps the newest results per spot
-- with the time they arrived. Anything older than RESULT_TTL is treated as gone,
-- which is what the server does too.
local RESULT_TTL = 12
local RESULTS = {}

-- The connection is stored in _G and disconnected before a new one is made.
-- A plain "already hooked" boolean is wrong here: it survives a re-execute, so
-- the second run skipped installing and the surviving listener kept writing into
-- the PREVIOUS script's RESULTS table. The new run then saw no results at all
-- and bought nothing while happily spinning - 3 spins, 0 buys.
local function watchSpins()
	local signal = re("SpinDrillService", "OnSpinStartedSignal")
	if not signal then return end
	if _G.__DRILLFARM_SPINHOOK then
		pcall(function() _G.__DRILLFARM_SPINHOOK:Disconnect() end)
	end

	_G.__DRILLFARM_SPINHOOK = signal.OnClientEvent:Connect(function(baseName, drillIds, resultIds)
		if tostring(baseName) ~= BASE_NAME then return end
		if type(drillIds) ~= "table" or type(resultIds) ~= "table" then return end
		local now = os.clock()
		for spot, id in pairs(resultIds) do
			RESULTS[spot] = { id = id, drill = drillIds[spot], at = now }
		end
	end)
end

local lastSpin = 0

local function spin()
	if os.clock() - lastSpin < (LEVER.SpinCooldown or 5) + 0.4 then return false end
	local ok = rf("SpinDrillService", "RequestSpin")
	lastSpin = os.clock()
	if ok then
		STATE.spins += 1
		STATE.phase = "spinning"
	end
	return ok and true or false
end

-- Forward declared: worthBuying below needs it, and a Lua local is invisible
-- above its definition - the trap this project has hit five times now.
local bestPlaced

-- Slowest drill actually running on the grid. Buying anything at or below this
-- only makes sense while the grid still has room.
local function weakestPlacedRate()
	local plot = base()
	if not plot or not plot:FindFirstChild("PlacedItems") then return 0 end
	local worst
	for _, item in ipairs(plot.PlacedItems:GetChildren()) do
		local meta = DRILLS[item:GetAttribute("DrillId")]
		if meta then
			local rate = tonumber(meta.OresPerSecond) or 0
			if not worst or rate < worst then worst = rate end
		end
	end
	return worst or 0
end

-- Worth keeping? A result costs DrillsMetadata[id].Price, and the balance has to
-- survive it - the whole point of the farm is the drills, but spending the last
-- of the cash on a Rusty Drill while a Titanium sits one spin away is backwards.
local function worthBuying(drillId)
	local meta = DRILLS[drillId]
	if not meta then return false, "unknown drill" end

	local rank = rarityRank(meta.Rarity)
	local floor = rarityRank(RARITY_ORDER[CONFIG.minRarity] or "Common")
	if rank < floor then return false, meta.Rarity .. " below floor" end

	-- Placing is manual for now, so drills queue up in the inventory. Once the
	-- queue is backing up, only a genuine upgrade is worth paying for: compared
	-- against the BEST drill already running, not the weakest. Comparing against
	-- the weakest let a 9 ore/s Iron Drill through while 18 drills sat unplaced,
	-- because almost everything beats a 3 ore/s Rusty.
	if STATE.inventory >= CONFIG.bagBeforePicky then
		local rate = tonumber(meta.OresPerSecond) or 0
		local _, bestRate = bestPlaced()
		if rate <= (bestRate or 0) then
			return false, string.format("%s ore/s under the best placed %s",
				shortNumber(rate), shortNumber(bestRate or 0))
		end
	end

	local price = tonumber(meta.Price) or 0
	local cash = refreshCash()
	if price > cash then return false, "costs " .. shortNumber(price) end
	if price > cash * CONFIG.maxSpend then
		return false, string.format("%s over %d%% of balance",
			shortNumber(price), CONFIG.maxSpend * 100)
	end
	return true, meta.Name
end

local function buyResults()
	local now = os.clock()
	for spot, entry in pairs(RESULTS) do
		if now - entry.at <= RESULT_TTL then
			local ok, why = worthBuying(entry.drill)
			if ok then
				local success, message = rf("SpinDrillService", "BuyResult", entry.id)
				RESULTS[spot] = nil
				if success then
					local meta = DRILLS[entry.drill]
					STATE.bought += 1
					STATE.spent += (meta and meta.Price or 0)
					STATE.lastDrill = meta and meta.Name or entry.drill
					STATE.note = "bought " .. STATE.lastDrill
				else
					STATE.lastResult = tostring(message)
					STATE.note = "buy refused: " .. tostring(message)
				end
			else
				STATE.skipped += 1
				STATE.blocked = why
				RESULTS[spot] = nil
			end
		else
			RESULTS[spot] = nil
		end
	end
end

-- Ore -------------------------------------------------------------------------

-- Collect fills the carry, deposit empties it into the minecart. DepositOres is
-- only enabled while actually carrying, so the enabled flag is the state check
-- and nothing has to be tracked by hand.
local function collectOres()
	local prompt = findPrompt("CollectOresPrompt")
	if prompt and prompt.Enabled then
		if firePrompt(prompt, 1.0) then
			STATE.collects += 1
			STATE.phase = "collecting"
		end
	end
	task.wait(0.4)
	local deposit = findPrompt("DepositOresPrompt")
	if deposit and deposit.Enabled then
		if firePrompt(deposit, 1.0) then
			STATE.deposits += 1
			STATE.phase = "depositing"
		end
	end
end

-- Spending --------------------------------------------------------------------

-- Keep a slice of the balance for buying results. Without it the upgrades eat
-- every cent and the lever - the only source of drills - never pays off.
-- Defined here rather than next to the upgrades because the cell unlocker below
-- calls it, and a local is invisible above its definition.
local function spendable()
	return refreshCash() * (1 - CONFIG.reserveShare)
end

-- Grid cells ------------------------------------------------------------------

-- The price sits in the prompt text, and the two fields are swapped between
-- tiles ("$1000 / Unlock" on some, "Unlock / $96M" on others), so both are
-- searched rather than trusting a fixed slot.
local function promptPrice(prompt)
	local text = prompt.ActionText .. " " .. prompt.ObjectText
	local number, suffix = text:match("%$([%d%.,]+)(%a*)")
	if not number then return nil end
	return parseCash(number:gsub(",", "") .. suffix)
end

-- Only enabled prompts are real: the disabled ones belong to tiles that are
-- already unlocked or not reachable yet, and firing those does nothing.
local function unlockCells()
	local plot = base()
	if not plot then return end
	local budget = spendable()

	local cheapest, cheapestPrice
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "UnlockPrompt" and d.Enabled then
			local price = promptPrice(d)
			if price and price <= budget and (not cheapestPrice or price < cheapestPrice) then
				cheapest, cheapestPrice = d, price
			end
		end
	end

	if not cheapest then
		STATE.blocked = "no affordable grid cell"
		return
	end

	local before = refreshCash()
	if firePrompt(cheapest, 1.2) then
		task.wait(0.6)
		-- A prompt returns nothing, so the balance dropping is the only proof.
		if refreshCash() < before then
			STATE.cells += 1
			STATE.note = "unlocked a cell for $" .. shortNumber(cheapestPrice)
		else
			STATE.blocked = "cell unlock did not charge"
		end
	end
end

-- Upgrades --------------------------------------------------------------------

-- Every upgrade is a RemoteFunction with no proximity check, so none of these
-- need the character to walk anywhere. They answer (ok, reason).
local function tryUpgrade(service, name, label, ...)
	local ok, why = rf(service, name, ...)
	if ok then
		STATE.upgrades += 1
		STATE.note = label .. " upgraded"
		return true
	end
	STATE.blocked = label .. ": " .. tostring(why)
	return false
end

local function upgradeMiner()
	if spendable() <= 0 then return end
	tryUpgrade("PlotService", "UpgradeOresPerHit", "ores per hit")
	tryUpgrade("PlotService", "UpgradeMinerLuck", "bonus chance")
end

local function upgradeLever()
	if spendable() <= 0 then return end
	-- Spots come first: they multiply every future roll, luck only shifts the
	-- table. MaxCashSpots is 6, the last three are gem priced and left alone.
	tryUpgrade("SpinDrillService", "UpgradeSpots", "roll spot")
	tryUpgrade("SpinDrillService", "UpgradeLuck", "roll luck")
end

local function upgradePickaxe()
	local state = rf("PickaxeService", "GetForgeState")
	if type(state) ~= "table" then return end
	STATE.pickaxe = tostring(state.Name)
	STATE.pickaxeLevel = tonumber(state.Level) or 0
	if state.CanUpgrade then
		tryUpgrade("PickaxeService", "RequestUpgrade", "pickaxe")
	else
		STATE.blocked = string.format("pickaxe needs %s essence",
			shortNumber(state.EssenceCost or 0))
	end
end

local function upgradeSpeed()
	if spendable() <= 0 then return end
	tryUpgrade("PlotService", "UpgradePlayerSpeed", "player speed")
end

local function upgradeBuildTime()
	if spendable() <= 0 then return end
	tryUpgrade("PlotService", "UpgradeBuildTimeReduction", "build time")
end

-- Free money ------------------------------------------------------------------

local function claimRewards()
	local before = refreshCash()

	rf("DailyRewardService", "Claim")
	rf("OfflineRewardService", "ClaimReward")
	rf("GroupRewardService", "ClaimGroupReward")
	rf("ForeverPackService", "Claim")

	-- Quests pay gems and each entry claims by its own id.
	local quests = rf("QuestService", "GetQuests")
	if type(quests) == "table" then
		for _, group in pairs(quests) do
			if type(group) == "table" then
				for _, entry in ipairs(group) do
					if type(entry) == "table" and entry.Completed and not entry.Claimed then
						rf("QuestService", "ClaimQuest", entry.Id)
						STATE.claims += 1
					end
				end
			end
		end
	end

	-- The wheel spins for free on a timer; BuySpins costs Robux and is not used.
	rf("WheelService", "Spin")

	if refreshCash() > before then
		STATE.note = "claimed " .. shortNumber(refreshCash() - before)
	end
end

-- Rebirth ---------------------------------------------------------------------

-- Rebirth wants both a cash total and specific drills in hand. The state remote
-- spells all of it out, so nothing is attempted until the server itself says
-- CanRebirth - a refused rebirth is silent otherwise.
local function rebirthState()
	local state = rf("RebirthService", "GetRebirthState")
	return type(state) == "table" and state or nil
end

local function tryRebirth()
	local state = rebirthState()
	if not state then return end
	if not state.CanRebirth then
		STATE.blocked = string.format("rebirth needs %s (have %s)",
			shortNumber(state.CashRequired or 0), shortNumber(state.CashHave or 0))
		return
	end
	local ok = rf("RebirthService", "PerformRebirth")
	if ok then
		STATE.rebirths += 1
		STATE.note = "rebirthed to level " .. tostring((state.Level or 0) + 1)
	end
end

-- Status ----------------------------------------------------------------------

local function refreshState()
	refreshCash()

	local inv = rf("InventoryService", "GetInventory")
	if type(inv) == "table" then
		local n = 0
		for _ in pairs(inv.Drills or {}) do n += 1 end
		STATE.inventory = n
	end

	local plot = base()
	if plot and plot:FindFirstChild("PlacedItems") then
		STATE.placed = #plot.PlacedItems:GetChildren()
	end

	local forge = rf("PickaxeService", "GetForgeState")
	if type(forge) == "table" then
		STATE.pickaxe = tostring(forge.Name)
		STATE.pickaxeLevel = tonumber(forge.Level) or 0
	end
end

-- The best drill currently placed, and what the roll table could still give.
function bestPlaced()
	local plot = base()
	if not plot or not plot:FindFirstChild("PlacedItems") then return nil end
	local best, bestRate
	for _, item in ipairs(plot.PlacedItems:GetChildren()) do
		local id = item:GetAttribute("DrillId")
		local meta = id and DRILLS[id]
		if meta then
			local rate = tonumber(meta.OresPerSecond) or 0
			if not bestRate or rate > bestRate then best, bestRate = meta, rate end
		end
	end
	return best, bestRate or 0
end

local function totalRate()
	local plot = base()
	if not plot or not plot:FindFirstChild("PlacedItems") then return 0 end
	local sum = 0
	for _, item in ipairs(plot.PlacedItems:GetChildren()) do
		local id = item:GetAttribute("DrillId")
		local meta = id and DRILLS[id]
		if meta and not item:GetAttribute("Building") then
			sum += tonumber(meta.OresPerSecond) or 0
		end
	end
	return sum
end

-- What is holding the farm back, in the order it actually matters.
local function bottleneck()
	local out = {}
	local plot = base()

	if STATE.inventory > 0 then
		out[#out + 1] = string.format("%d drill(s) sitting in the inventory - "
			.. "placing is unsolved, place them by hand", STATE.inventory)
	end

	if plot then
		local building = 0
		for _, item in ipairs(plot.PlacedItems:GetChildren()) do
			if item:GetAttribute("Building") then building += 1 end
		end
		if building > 0 then
			out[#out + 1] = building .. " drill(s) still building"
		end
	end

	local best = bestPlaced()
	if best then
		out[#out + 1] = string.format("best placed: %s at %s ore/s",
			best.Name, shortNumber(best.OresPerSecond))
	end

	if STATE.blocked ~= "-" then out[#out + 1] = STATE.blocked end
	if #out == 0 then out[1] = "nothing blocking" end
	return out
end

-- Cycle -----------------------------------------------------------------------

local lastCollect = 0

local function cycle()
	if not CONFIG.auto and not CONFIG.autoSpin and not CONFIG.autoCollect then
		STATE.phase = "idle"
		return
	end

	refreshState()

	if CONFIG.auto or CONFIG.autoSpin then
		if spin() then
			-- The result needs the spin animation to finish before it exists.
			task.wait((LEVER.SpinDuration or 3) + 0.6)
			if CONFIG.auto or CONFIG.autoBuy then buyResults() end
		end
	end

	if (CONFIG.auto or CONFIG.autoCollect)
		and os.clock() - lastCollect > CONFIG.collectEvery then
		lastCollect = os.clock()
		pcall(collectOres)
	end

	STATE.phase = "running"
end

-- Spending runs on its own slower timer. Mixing it into the spin cycle starves
-- it, because the spin path always has work and would return first every time -
-- the exact bug that left Sell Ores rolling and never upgrading.
local function spendCycle()
	if CONFIG.auto or CONFIG.autoCells then pcall(unlockCells) end
	if CONFIG.auto or CONFIG.autoLever then pcall(upgradeLever) end
	if CONFIG.auto or CONFIG.autoMiner then pcall(upgradeMiner) end
	if CONFIG.auto or CONFIG.autoPickaxe then pcall(upgradePickaxe) end
	if CONFIG.autoSpeed then pcall(upgradeSpeed) end
	if CONFIG.autoBuildTime then pcall(upgradeBuildTime) end
	if CONFIG.autoRebirth then pcall(tryRebirth) end
end

-- UI --------------------------------------------------------------------------

local UI
do
	local ok, result = pcall(function()
		-- hub first, readfile is the fallback for a hand-shipped run
		return (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
	end)
	if not ok or type(result) ~= "table" then
		error("[drillfarm] ui-template.lua could not be loaded from the executor "
			.. "workspace folder (" .. tostring(result) .. ")")
	end
	UI = result
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("drillfarm", CONFIG)

local win = UI.Window({
	name = "DrillFarm",
	title = "DRILL",
	accentTitle = "FARM",
	subtitle = "seltonmt",
	badge = "⛏",
	width = 920,
	height = 580,
})
_G.__DRILLFARM_GUI = win.gui

local function toggle(card, text, key, hint, tone, onChange)
	return card:Toggle(text, CONFIG[key], function(value)
		CONFIG[key] = value
		if onChange then onChange(value) end
	end, hint, tone)
end

-- FARMING
local farmPage = win:Page("FARMING", UI.icon.pickaxe)

local masterCard = farmPage:Card("MASTER", 1)
toggle(masterCard, "AUTO (everything, in order)", "auto",
	"spin, buy, collect, then the slow spending pass", UI.theme.warn)

local spinCard = farmPage:Card("LEVER", 1)
toggle(spinCard, "Auto Spin", "autoSpin", "5s cooldown, 3s spin")
toggle(spinCard, "Buy the result", "autoBuy",
	"BuyResult(resultId) off the spin signal")
local refreshRarity = spinCard:Stepper("Min rarity",
	function() return RARITY_ORDER[CONFIG.minRarity] or "Common" end,
	function(delta)
		CONFIG.minRarity = math.clamp(CONFIG.minRarity + delta, 1, #RARITY_ORDER)
	end,
	"anything below this is left to expire")
spinCard:Stepper("Max spend",
	function() return math.floor(CONFIG.maxSpend * 100) .. "%" end,
	function(delta)
		CONFIG.maxSpend = math.clamp(CONFIG.maxSpend + delta * 0.05, 0.05, 1)
	end,
	"share of the balance one result may cost")

local oreCard = farmPage:Card("ORE", 2)
toggle(oreCard, "Collect and deposit", "autoCollect",
	"CollectOresPrompt then DepositOresPrompt")
oreCard:Stepper("Collect every",
	function() return CONFIG.collectEvery .. "s" end,
	function(delta) CONFIG.collectEvery = math.clamp(CONFIG.collectEvery + delta * 2, 4, 60) end)
oreCard:Button("Collect now", collectOres)

local rewardCard = farmPage:Card("FREE", 2)
toggle(rewardCard, "Claim rewards", "autoRewards",
	"daily, offline, group, quests and the free wheel spin")
rewardCard:Button("Claim everything now", claimRewards)

-- SPENDING
local spendPage = win:Page("SPENDING", UI.icon.coin)

local leverCard = spendPage:Card("LEVER", 1)
toggle(leverCard, "Roll spots + luck", "autoLever",
	"spots multiply every roll, so they go first")

local cellCard = spendPage:Card("GRID", 1)
toggle(cellCard, "Unlock grid cells", "autoCells",
	"cheapest affordable first, price read off the prompt")
cellCard:Button("Unlock one now", unlockCells)

local minerCard = spendPage:Card("MINER", 1)
toggle(minerCard, "Ores per hit + bonus", "autoMiner",
	"$87 for 10 > 15, bonus chance $70K")

local pickCard = spendPage:Card("PICKAXE", 2)
toggle(pickCard, "Forge pickaxe", "autoPickaxe",
	"paid in forge essence, not cash")

local lateCard = spendPage:Card("LATE GAME", 2)
toggle(lateCard, "Player speed ($4B)", "autoSpeed", nil, UI.theme.warn)
toggle(lateCard, "Faster build time ($8T)", "autoBuildTime", nil, UI.theme.warn)
toggle(lateCard, "Rebirth when allowed", "autoRebirth",
	"only fires once the server reports CanRebirth", UI.theme.bad)
lateCard:Button("Rebirth now", tryRebirth, UI.theme.bad)

local reserveCard = spendPage:Card("RESERVE", 0)
reserveCard:Stepper("Keep for results",
	function() return math.floor(CONFIG.reserveShare * 100) .. "%" end,
	function(delta)
		CONFIG.reserveShare = math.clamp(CONFIG.reserveShare + delta * 0.05, 0, 0.9)
	end,
	"upgrades never spend below this, or the lever starves")
local reserveOut = reserveCard:Readout(4)

-- STATUS
local statusPage = win:Page("STATUS", UI.icon.chart)

local liveCard = statusPage:Card("LIVE", 1)
local liveOut = liveCard:Readout(10)

local farmCard = statusPage:Card("FARM", 2)
local farmOut = farmCard:Readout(9)

local blockCard = statusPage:Card("WHAT IS HOLDING US BACK", 0)
local blockOut = blockCard:Readout(6)

-- DRILLS
local drillPage = win:Page("DRILLS", UI.icon.list)
local tableCard = drillPage:Card("BEST BY OUTPUT PER PRICE", 0)
local tableOut = tableCard:Readout(16)

do
	-- Ranked once at load: the metadata never changes during a session.
	local rows = {}
	for id, meta in pairs(DRILLS) do
		local price = tonumber(meta.Price) or 0
		local rate = tonumber(meta.OresPerSecond) or 0
		local chance = tonumber(meta.ChanceToSpawn) or 0
		if chance > 0 and price > 0 then
			rows[#rows + 1] = {
				id = id, name = meta.Name, rate = rate, price = price,
				build = tonumber(meta.BuildTime) or 0, chance = chance,
				payback = price / math.max(rate, 1),
			}
		end
	end
	table.sort(rows, function(a, b) return a.payback < b.payback end)

	local lines = { "PAYBACK IN SECONDS OF ORE" }
	for i = 1, math.min(15, #rows) do
		local r = rows[i]
		lines[#lines + 1] = string.format("  %-20s %8ss  %8s/s  %5.2f%%",
			string.sub(r.name, 1, 20), shortNumber(r.payback),
			shortNumber(r.rate), r.chance)
	end
	tableOut:set(lines)
end

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste -
-- er ist immer das erste Icon und die Seite, auf der das Panel aufgeht.
pcall(function() win:Home() end)

win:Refresh()

-- Loops -----------------------------------------------------------------------

watchSpins()

local function loop(interval, fn)
	task.spawn(function()
		while _G.__DRILLFARM == generation do
			pcall(fn)
			task.wait(interval)
		end
	end)
end

loop(1.0, cycle)
loop(20, spendCycle)
loop(120, function()
	if CONFIG.auto or CONFIG.autoRewards then claimRewards() end
end)

task.spawn(function()
	while _G.__DRILLFARM == generation do
		refreshState()

		win:SetStatus(string.format("$%s   %s ore/s   %d placed   %d bag   %s",
			shortNumber(STATE.cash), shortNumber(totalRate()),
			STATE.placed, STATE.inventory, STATE.phase))

		liveOut:set({
			"BALANCE",
			string.format("  cash      $%s", shortNumber(STATE.cash)),
			string.format("  ore/s     %s", shortNumber(totalRate())),
			string.format("  spent     $%s", shortNumber(STATE.spent)),
			"",
			"LEVER",
			string.format("  spins     %d", STATE.spins),
			string.format("  bought    %d", STATE.bought),
			string.format("  skipped   %d", STATE.skipped),
			string.format("  last      %s", STATE.lastDrill),
		})

		local best, bestRate = bestPlaced()
		farmOut:set({
			"FARM",
			string.format("  placed    %d", STATE.placed),
			string.format("  in bag    %d", STATE.inventory),
			string.format("  best      %s", best and best.Name or "-"),
			string.format("  best ore/s %s", shortNumber(bestRate)),
			string.format("  pickaxe   %s lvl %d", STATE.pickaxe, STATE.pickaxeLevel),
			string.format("  collects  %d / deposits %d", STATE.collects, STATE.deposits),
			string.format("  upgrades  %d / cells %d", STATE.upgrades, STATE.cells),
			string.format("  claims    %d", STATE.claims),
		})

		reserveOut:set({
			"RESERVE",
			string.format("  held back  $%s",
				shortNumber(STATE.cash * CONFIG.reserveShare)),
			string.format("  spendable  $%s", shortNumber(spendable())),
			"  " .. tostring(STATE.note),
		})

		blockOut:set(bottleneck())
		refreshRarity()

		task.wait(0.5)
	end
	win:Destroy()
end)

_G.__DRILLFARM_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	rf = rf, re = re, KNIT = KNIT,
	DRILLS = DRILLS, LEVER = LEVER, MINER = MINER, RARITIES = RARITIES,
	base = base, findPrompt = findPrompt, firePrompt = firePrompt,
	spin = spin, buyResults = buyResults, RESULTS = RESULTS,
	worthBuying = worthBuying, collectOres = collectOres,
	unlockCells = unlockCells, promptPrice = promptPrice, spendable = spendable,
	upgradeMiner = upgradeMiner, upgradeLever = upgradeLever,
	upgradePickaxe = upgradePickaxe, upgradeSpeed = upgradeSpeed,
	upgradeBuildTime = upgradeBuildTime,
	claimRewards = claimRewards, tryRebirth = tryRebirth, rebirthState = rebirthState,
	refreshCash = refreshCash, refreshState = refreshState, parseCash = parseCash,
	bestPlaced = bestPlaced, totalRate = totalRate, bottleneck = bottleneck,
	weakestPlacedRate = weakestPlacedRate,
	cycle = cycle, spendCycle = spendCycle,
}

refreshState()
print("[drillfarm] by seltonmt - running (gen " .. generation .. ") - RightShift toggles the UI")
