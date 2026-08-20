--!nocheck
-- selllemons.lua  --  "Sell Lemons 🍋"  (place 79268393072444, BloxByte Games)
--
-- A classic conveyor tycoon: 453 purchase buttons across thirteen areas, eight
-- income streams sitting on top of them, and a Rebirth -> Evolve -> Ascend
-- prestige ladder. Everything below was measured against the server through the
-- game's own client component API, which is the state oracle here:
--
--   local T  = require(ReplicatedStorage.Modules.Tycoon.Tycoon)
--   local lt = T.getLocal()
--   lt:GetComponent(require(ReplicatedStorage.Modules.Tycoon.Component.<X>))
--
-- and it is complete: TycoonBalances (cash, cashSpent, investors, tokens),
-- TycoonAnalyzer (all 453 purchases and all 8 earners, keyed by id, each with a
-- live .Instance), TycoonIncome, TycoonUpgrades, TycoonPowers, TycoonRebirth,
-- TycoonEvolution, TycoonAscension, TycoonPhoneOffers, TycoonCompanions.
--
-- ============================================================================
-- EVERY NUMBER IN THIS GAME IS A log10 FLOAT
-- ============================================================================
-- ReplicatedStorage.Modules.Huge is the game's own big-number library and every
-- currency, price, interval, income value and investor count is stored as its
-- base-10 logarithm. H.zero is -inf and H.one is 0, so a balance of $1 is the
-- number 0 and an empty balance is -inf. Verified:
--     H.toNumber(1.1760912590556813) = 15.0      H.formatTime(...)   = "15s"
--     H.formatAbbreviated(50.50261505280331)     = "318Qnd"
-- Never hand-roll a suffix table and never compare a Huge against a plain
-- number. H.formatAbbreviated is what the panel prints.
--
-- TRAP: the attribute and the component disagree. Values.Values carries
-- Investors = "0" as a STRING while TycoonBalances:GetInvestors() returns -inf.
-- The component is authoritative; the attributes are not.
--
-- TRAP: a purchase model's Name is not its Balance key. The model is called
-- "Lemon Stand", the id in Balance.PurchaseOrder / PurchasePrices is
-- "LemonStand". Only TycoonAnalyzer:GetPurchases() knows the mapping, so this
-- file never derives an id from a name.
--
-- ============================================================================
-- MEASURED, ALL OF IT, WITH THE AUTOMATION OFF
-- ============================================================================
--
--  * THE TYCOON ITSELF HAS NO PROXIMITY CHECK ANYWHERE. A purchase fired from
--    578 studs above the plot went through at the exact quoted price (cash $14
--    -> $8 for the $6 Juicer, Purchased flipped true). Waking a stream from 576
--    studs paid identically to waking it from 9 studs: +$76.28 in the same 10s
--    window, both times. Buying, upgrading, waking, the minigames, the drops
--    and the phone offers all work with the body parked wherever it stands.
--
--  * FRUIT IS THE EXCEPTION, AND IT IS ALSO THE BIGGEST EARNER IN THE GAME.
--    Five clicks on map fruit from 204 studs paid exactly 0. The same five from
--    6.2 studs paid twice. The ClickDetector's MaxActivationDistance is 16 and
--    the server honours it, so this is the one thing here that needs the body
--    moved - which is why harvestFruit() teleports and everything else does not.
--    Worth it: a 25-fruit teleport sweep took 6.6s, 9 of the 25 paid, and the
--    total was $3.21 QUADRILLION - about $483 trillion a second, against roughly
--    $25 billion a second from the trade minigame at the same moment.
--
--  * KLICKEN is earner:WakeAsync() -> TycoonIncome:WakeManualStreamAsync(name).
--    A stream with Automatic = false pays nothing on its own, so early on this
--    is the entire income. Payouts are server rate limited and SUBLINEAR in the
--    number of calls - 6s windows, same stream, $3.81 a payout:
--        0.5s spacing / 12 calls -> 6 payouts      0.1s  /  60 -> 9
--        0.3s spacing / 20 calls -> 7 payouts      0.05s / 120 -> 13
--        0.2s spacing / 30 calls -> 7 payouts
--    A separate 10s window at 0.5s spacing paid 20 times for 20 calls, which
--    only fits a token bucket: full after an idle stretch, burstable once, then
--    refilling at roughly the stream interval. Hammering it is therefore mostly
--    wasted, which is why the default spacing is 0.15s and not 0.
--
--  * VERBESSERN is earner:UpgradeAsync(n) -> the earner's Upgrade
--    RemoteFunction. UpgradeAsync(1) took LemonStand level 1 -> 2, charged
--    exactly the quoted $7.65 and moved the stream value $3.81 -> $5.84.
--    UpgradeAsync(10) DID NOTHING AT ALL - level, cash and stream value all
--    unchanged. The server silently drops any n above Count, and Count comes
--    from GetNextUpgradeInfo() and is driven by the UpgradeStack power (1 while
--    that power is unowned, then 5 / 25 / 100 / inf).
--    Both published scripts get this wrong: one doubles n (1, 2, 4, 8 ...) and
--    the other loops i = 1..10. Only the n = 1 call ever lands, and because the
--    remote answers without erroring their pcall still reports success.
--
--  * THE POWERS ARE PRICED IN INVESTORS, NOT CASH. Attempting Manage with $647
--    in the bank and zero investors answered, verbatim:
--        ServerTycoonPowers:130: insufficient investors
--    Tokens (25 on a fresh save) are not the powers currency either. Investors
--    come out of Rebirth, so Rebirth gates the powers and the powers gate
--    everything else. Investors are CONSUMED, not just required - buying one
--    took the balance 176 -> 76. Config.Powers prices, in investors:
--        Manage           100                     (no Bonuses table)
--        ClickFruitValue  250 / 1e6 / 1e18        Amt 2/4/6, Mult 2/4/8
--        WalkSpeed        400 / 1e9 / 1e27 / 1e72 1.5 / 2 / 3 / 4
--        UpgradeStack     1e3 / 1e12 / 1e33 / 1e63  Count 5 / 25 / 100 / inf
--        BuyNext          1e38 / 1e67 / 1e93      150 / 250 / inf
--        AutoFruit        1e42
--    Each one also carries a DevProductID, which is the Robux shortcut. This
--    file only ever spends investors.
--
--  * MANAGE IS 100 INVESTORS FOR A HUD TAB. It was bought to find out: level
--    0 -> 1, investors 176 -> 76, and nothing else moved - no stream turned
--    automatic, the upgrade Count stayed 1, income was unchanged. A getgc sweep
--    for the string finds it referenced only by UI.Layers.Manage.UIManageMenu
--    and the orchard billboard. It is a menu unlock, so this file skips it.
--
--  * REBIRTH, MEASURED END TO END. 93 buttons and $558Qn with 175 potential
--    investors went to 3 buttons, $31 and 176 investors, rebirths 0 -> 1. It
--    wipes the purchases and the balance and pays out the potential in full.
--
--  * THE TRADE MINIGAME IS THE BIGGEST LEVER IN THE GAME.
--    MinigameTradeService.Start returns {MaxEarnings, StartingCash, LineConfig}
--    where MaxEarnings is the server's own statement of a perfect run. Passing
--    that number straight back to .End paid +$7,548,571,798 in one call (cash
--    $368M -> $7.92B). 300s cooldown. This script submits the announced
--    MaxEarnings and nothing above it - that is playing the round perfectly,
--    not inventing a result.
--
--  * THE RACE MINIGAME PAYS ON A CLIENT-SUPPLIED PLACEMENT.
--    Config.MinigameRacePlacementCash = {[1] = 1, [2] = 0.5, [3] = 0.25,
--    [4] = 0}. Start returns the full prize up front, End(n) pays prize *
--    factor[n]. End(1) paid the announced $229 in full ($8 -> $237). 300s.
--
--  * CASH DROPS ARE REDEEMED BY ID AND TOUCHING THEM DOES NOTHING.
--    RemoteSignal "DropService.New" fires (id, kind, lifetime) - measured
--    ("994", "Cash", 1200). RemoteRequest "DropService.Redeem":InvokeServer(id)
--    answered 12.798968597564983, which is $6.3 TRILLION. Dragging the body
--    through the CashDrop part in workspace.Drops left it sitting there.
--    NOTE: the most-viewed published script listens on "CashDropService.New"
--    and "CashDropService.Redeem", neither of which exists in this place. Its
--    drop collector is dead code.
--
--  * PHONE OFFERS CAN BE HAGGLED, AND HAGGLING TOO HARD LOSES THEM.
--    The offer arrives on the tycoon's PhoneOffer RemoteEvent as a Huge number.
--    PhoneOffers:RaiseOffer() raised one from $12.336B -> $17.275B (+40%) and
--    then -> $19.088B (+10%). The THIRD raise returned the offer as nil - the
--    deal was gone. Measured once, so it is probably a per-raise roll; the
--    default here is one raise and the stepper stops at two.
--
--  * A FRUIT IS RIPE EXACTLY WHEN IT STILL HAS ITS ClickFruitPart.
--    Around 820 parts carry the ClickFruit tag across the whole map. A ripe one
--    is Transparency 0 and owns Fruit.ClickFruitPart.ClickDetector; a harvested
--    one is Transparency 1 and the ClickFruitPart is gone entirely, so the
--    presence of that child IS the ripeness test and nothing else has to be
--    read. They regrow on their own.
--    That test is what fixed the first version of this file: it filtered to the
--    player's own tycoon, and after one sweep all 36 fruits there were
--    transparent and detector-less while 448 ripe ones stood on the map trees
--    being ignored. Own plot, map trees and other players' plots all pay - the
--    only thing that matters is the detector and standing next to it.
--
--  * SpecialIncome IS THE PAYOUT ORACLE. The tycoon's SpecialIncome RemoteEvent
--    fires (sourceName, hugeAmount) for every one-off payout - "ClickFruit",
--    "MinigameRace" and so on. That is how this file reports what each feature
--    actually earned instead of guessing from the balance.
--
--  * THE PRESTIGE FORMULAS, read off the components:
--      GetPotentialInvestors = investors + cashToNewInvestors(cash + cashSpent)
--        with Balance.RebirthParameters.Investors = {1.8e17, 0.44}. Spending is
--        therefore never a loss - cashSpent counts towards the next rebirth
--        exactly as unspent cash does, which is why this file spends freely.
--      GetEvolutionProgress = (investors + investorsSpent + potential)
--                             / nextEvolutionInvestors(evolution), evolve at 1.
--      GetAscensionProgress = purchasedCount / 453, ascend at 1.
--      Rebirth / Evolve / Ascend all take NO arguments.
--      Config: EvolutionMultiplier 42, AscensionMultiplier 7.77,
--              AscensionPenalty 3.33, BaseInvestorBonus 0.01.
--
-- ============================================================================
-- NEVER TOUCHED
-- ============================================================================
--  * Purchase:InvokeServer(true) - the "forever purchase". Config.Products
--    lists PermanentPurchase with DevProductID 3558362570, so the published
--    scripts' "Use Forever Purchase" option is a Robux prompt. This file always
--    calls TryPurchaseAsync(), which sends no argument.
--  * earner:PromptBoostAsync() / GetBoostProductName() - EarnerBoost1..8, Robux.
--  * UseTimeCash / UseEarnerBoost / DoubleOfflineCash / FreeRebirth /
--    FreeEvolve / InvestorBoost / RateBoost - every one of them is a DevProduct.
--  * VideoAdService.ShowAd - free, but it plays a real rewarded video at the
--    player. Left out rather than made a surprise.
--  * Core.AdminService.RunCommandRemote - present, never fired.
--
-- ============================================================================
-- UNVERIFIED, AND SAID SO IN THE PANEL
-- ============================================================================
-- The whole Orchard subsystem is gated behind Config.Orchard.UnlockCashPrice =
-- 1e25 and the test account never got within twelve orders of magnitude of it,
-- so none of the orchard code below has ever been executed against a live
-- server. It is written from the module API (OrchardPlot.States = Empty 0,
-- TreeGrowing 1, FruitGrowing 2, FruitReady 3; RemoteRequest OrchardPlot.Plant
-- / .Harvest / .GetFruit / .UseItem / .SellUpgrade / .DestroyTree; the tycoon's
-- UnlockOrchard / UnlockPlot / SellFruits / EatFruit remotes) and it ships OFF.
-- Treat anything it reports as a claim, not a measurement.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local plr = Players.LocalPlayer

--------------------------------------------------------------------------------
-- config / state
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,           -- master switch, every loop is gated on it

	-- the tycoon floor
	autoBuy = true,         -- walk Balance.PurchaseOrder, buy the first affordable
	autoUpgrade = true,     -- VERBESSERN, always with the server-allowed Count
	autoWake = true,        -- KLICKEN, only on streams that are not Automatic
	wakeSpacing = 0.15,     -- seconds between wake sweeps; see the token bucket note

	-- one-off money
	autoFruit = true,       -- the teleport harvest route - the biggest earner
	fruitPerSweep = 30,     -- fruit per pass before re-scanning for regrowth
	autoRace = true,        -- 300s, End(1) = first place
	autoTrade = true,       -- 300s, End(MaxEarnings) = a perfect round
	autoDrops = true,       -- redeem by id off the DropService.New signal
	autoOffers = true,      -- phone offers
	offerRaises = 1,        -- 0..2. Three raises lost the offer outright.

	-- prestige
	autoPowers = true,      -- spend investors down the value-ranked order
	buyCosmeticPowers = false, -- Manage (a HUD tab) and WalkSpeed (we teleport)
	autoRebirth = false,    -- wipes the tycoon; off until the user says so
	rebirthFactor = 10,     -- rebirth when potential >= current investors * this
	rebirthMinimum = 100,   -- ...and never below this many potential investors
	autoEvolve = false,     -- wipes more than a rebirth does
	autoAscend = false,     -- wipes the most

	-- unverified, see the header
	autoOrchard = false,
}

local STATE = {
	note = "idle",
	cash = -math.huge, spent = -math.huge, investors = -math.huge,
	potential = -math.huge, tokens = 0,
	purchased = 0, rebirths = 0, evolution = 0, ascension = 0,
	evolveProgress = 0, ascendProgress = 0,
	incomeRate = 0, lastCash = nil, rateAt = nil, rateRef = nil,
	nextBuy = "-", nextBuyPrice = nil,
	nextUpgrade = "-", nextUpgradePrice = nil, nextUpgradeCount = 1,
	streams = {},
	wakes = 0, buys = 0, upgrades = 0, fruits = 0, fruitRipe = 0, fruitHome = nil,
	races = 0, trades = 0, drops = 0, offers = 0, powerBuys = 0,
	earnedRace = 0, earnedTrade = 0, earnedDrop = 0, earnedOffer = 0, earnedFruit = 0,
	raceIn = 0, tradeIn = 0,
	offerValue = nil, offerRaised = 0,
	powerLevels = {}, nextPower = "-", nextPowerPrice = nil,
	orchardUnlocked = false, orchardNote = "off (unverified)",
	blocked = nil,
}

-- Re-executing does not restart the Lua VM, so the previous run's loops are
-- still alive. Every loop captures this and exits when it stops matching.
_G.__LEMON = (_G.__LEMON or 0) + 1
local GEN = _G.__LEMON

--------------------------------------------------------------------------------
-- module access
--------------------------------------------------------------------------------

-- The executor runs at identity 8 and require() on a normal ModuleScript throws
-- there on some builds, so every require in this file goes through one wrapper.
local function req(module)
	if not module then return nil, "no module" end
	if setthreadidentity then pcall(setthreadidentity, 2) end
	local ok, value = pcall(require, module)
	if not ok then return nil, tostring(value) end
	return value
end

local function path(root, ...)
	local node = root
	for _, name in ipairs({ ... }) do
		if not node then return nil end
		node = node:FindFirstChild(name)
	end
	return node
end

local Huge = req(ReplicatedStorage:WaitForChild("Modules", 20)
	and path(ReplicatedStorage, "Modules", "Huge"))
local Balance = req(ReplicatedStorage:FindFirstChild("Balance"))
local Config = req(ReplicatedStorage:FindFirstChild("Config"))

if not Huge then
	warn("[selllemons] Modules.Huge missing - wrong game?")
	return
end

--------------------------------------------------------------------------------
-- Huge helpers
--
-- Every one of these takes and returns log10 floats. The only place a plain
-- number appears is the panel, and only through fmt().
--------------------------------------------------------------------------------

local NONE = -math.huge

local function isHuge(v) return type(v) == "number" end
local function hugeIsZero(v) return (not isHuge(v)) or v == NONE or v ~= v end

local function fmt(v)
	if hugeIsZero(v) then return "0" end
	local ok, text = pcall(Huge.formatAbbreviated, v)
	if ok and text then return text end
	return string.format("%.2f(log10)", v)
end

local function fmtTime(v)
	if hugeIsZero(v) then return "-" end
	local ok, text = pcall(Huge.formatTime, v)
	return ok and text or "-"
end

-- Plain-number view of a Huge, for rates and ratios only. Anything above ~1e308
-- comes back as inf, which every comparison below tolerates.
local function toNum(v)
	if hugeIsZero(v) then return 0 end
	local ok, n = pcall(Huge.toNumber, v)
	if ok and type(n) == "number" and n == n then return n end
	return 0
end

local function toHuge(n)
	if type(n) ~= "number" or n <= 0 then return NONE end
	local ok, v = pcall(Huge.toHuge, n)
	return ok and v or NONE
end

-- a >= b for two Huges, tolerating nil and -inf on either side
local function atLeast(a, b)
	if hugeIsZero(b) then return true end
	if hugeIsZero(a) then return false end
	return a >= b
end

--------------------------------------------------------------------------------
-- the tycoon and its components
--------------------------------------------------------------------------------

local Tycoon = req(path(ReplicatedStorage, "Modules", "Tycoon", "Tycoon"))
local ComponentFolder = path(ReplicatedStorage, "Modules", "Tycoon", "Component")

local componentCache = {}

-- Cached per component NAME, not per instance: getLocal() hands back the same
-- live tycoon for the whole session, and GetComponent is not free.
local function comp(name)
	if componentCache[name] then return componentCache[name] end
	if not (Tycoon and ComponentFolder) then return nil end
	local class = req(ComponentFolder:FindFirstChild(name))
	if not class then return nil end
	local ok, lt = pcall(Tycoon.getLocal)
	if not ok or not lt then return nil end
	local ok2, instance = pcall(function() return lt:GetComponent(class) end)
	if not ok2 or not instance then return nil end
	componentCache[name] = instance
	return instance
end

local function myTycoon()
	if _G.__LEMON_T and _G.__LEMON_T.Parent then return _G.__LEMON_T end
	for _, folder in ipairs(Workspace:GetChildren()) do
		if folder:IsA("Folder") and folder.Name:match("^Tycoon%d+$") then
			local owner = folder:FindFirstChild("Owner")
			if owner and owner:IsA("ObjectValue") and owner.Value == plr then
				_G.__LEMON_T = folder
				return folder
			end
		end
	end
	return nil
end

local function tycoonRemote(name)
	local t = myTycoon()
	if not t then return nil end
	local remotes = t:FindFirstChild("Remotes")
	return remotes and remotes:FindFirstChild(name)
end

local function coreRequest(name)
	return path(ReplicatedStorage, "Core", "RemoteRequest") and
		path(ReplicatedStorage, "Core", "RemoteRequest"):FindFirstChild(name)
end

local function coreSignal(name)
	local folder = path(ReplicatedStorage, "Core", "RemoteSignal")
	return folder and folder:FindFirstChild(name)
end

--------------------------------------------------------------------------------
-- oracle reads
--------------------------------------------------------------------------------

local function balances() return comp("TycoonBalances") end
local function analyzer() return comp("TycoonAnalyzer") end
local function income() return comp("TycoonIncome") end
local function upgrades() return comp("TycoonUpgrades") end
local function powers() return comp("TycoonPowers") end
local function rebirth() return comp("TycoonRebirth") end
local function evolution() return comp("TycoonEvolution") end
local function ascension() return comp("TycoonAscension") end
local function purchases() return comp("TycoonPurchases") end
local function phoneOffers() return comp("TycoonPhoneOffers") end
local function companions() return comp("TycoonCompanions") end

local function cash()
	local b = balances()
	if not b then return NONE end
	local ok, v = pcall(function() return b:GetCash() end)
	return (ok and isHuge(v)) and v or NONE
end

local function canAfford(price)
	if hugeIsZero(price) then return true end
	return atLeast(cash(), price)
end

--------------------------------------------------------------------------------
-- KAUFEN - the 453-button ladder
--
-- Balance.PurchaseOrder is the game's own build order and the ladder is walked
-- in exactly that sequence: the first entry that is Enabled and not yet
-- Purchased is the target, and it is bought as soon as it is affordable. There
-- is deliberately no cheapest-first shortcut - the areas gate each other
-- through the Requires attribute, so buying out of order just stalls on a
-- button whose prerequisite is still missing.
--------------------------------------------------------------------------------

local function nextPurchase()
	local a = analyzer()
	if not (a and Balance and Balance.PurchaseOrder) then return nil end
	local ok, all = pcall(function() return a:GetPurchases() end)
	if not ok or type(all) ~= "table" then return nil end
	for _, id in ipairs(Balance.PurchaseOrder) do
		local entry = all[id]
		if entry and entry.Instance and entry.Instance.Parent then
			local inst = entry.Instance
			if inst:GetAttribute("Enabled") and not inst:GetAttribute("Purchased") then
				return entry, id, Balance.PurchasePrices and Balance.PurchasePrices[id]
			end
		end
	end
	return nil
end

local function stepBuy()
	local entry, id, price = nextPurchase()
	if not entry then
		STATE.nextBuy, STATE.nextBuyPrice = "all bought", nil
		return
	end
	STATE.nextBuy, STATE.nextBuyPrice = id, price
	if not canAfford(price) then return end
	-- TryPurchaseAsync() with NO argument. Passing true asks for the Robux
	-- PermanentPurchase product instead.
	local ok = pcall(function() return entry:TryPurchaseAsync() end)
	if ok and entry.Instance:GetAttribute("Purchased") then
		STATE.buys = STATE.buys + 1
		STATE.note = "bought " .. tostring(id)
	end
end

--------------------------------------------------------------------------------
-- VERBESSERN - the earner upgrades
--
-- GetNextUpgradeInfo() returns {Count, Price, Max}. Count is what the server
-- will accept in a single call and it is re-read every time because the
-- UpgradeStack power moves it (1 -> 5 -> 25 -> 100 -> inf). Handing the remote
-- anything larger is silently dropped - no error, no charge, no level.
--------------------------------------------------------------------------------

local function earnerList()
	local a = analyzer()
	if not a then return {} end
	local ok, all = pcall(function() return a:GetEarners() end)
	return (ok and type(all) == "table") and all or {}
end

-- Cheapest next upgrade across all eight earners. Cheapest-first is right here
-- and wrong for the purchase ladder: the earners do not gate each other, so the
-- cheapest level is always the best price per level available.
local function bestUpgrade()
	local best, bestId, bestPrice, bestCount
	for id, earner in pairs(earnerList()) do
		local ok, info = pcall(function() return earner:GetNextUpgradeInfo() end)
		if ok and type(info) == "table" and not info.Max and isHuge(info.Price) then
			if (not bestPrice) or info.Price < bestPrice then
				best, bestId, bestPrice, bestCount = earner, id, info.Price, info.Count or 1
			end
		end
	end
	return best, bestId, bestPrice, bestCount
end

local function stepUpgrade()
	local earner, id, price, count = bestUpgrade()
	if not earner then
		STATE.nextUpgrade, STATE.nextUpgradePrice = "maxed", nil
		return
	end
	STATE.nextUpgrade, STATE.nextUpgradePrice, STATE.nextUpgradeCount = id, price, count
	if not canAfford(price) then return end
	local ok = pcall(function() return earner:UpgradeAsync(count) end)
	if ok then
		STATE.upgrades = STATE.upgrades + 1
		STATE.note = "upgraded " .. tostring(id) .. " x" .. tostring(count)
	end
end

--------------------------------------------------------------------------------
-- KLICKEN - waking the manual streams
--
-- A stream with Automatic = true is driven by its area's Manager purchase and
-- waking it is pointless, so those are skipped. Everything else pays only when
-- woken. Payouts come out of a server-side bucket (see the header), so this
-- sweeps rather than hammers.
--------------------------------------------------------------------------------

local function stepWake()
	local inc = income()
	if not inc then return end
	for id, earner in pairs(earnerList()) do
		if GEN ~= _G.__LEMON then return end
		local ok, auto = pcall(function() return inc:IsStreamAutomatic(id) end)
		if ok and not auto then
			pcall(function() earner:WakeAsync() end)
			STATE.wakes = STATE.wakes + 1
		end
	end
end

local function readStreams()
	local inc = income()
	if not inc then return end
	local rows = {}
	for id in pairs(earnerList()) do
		local function get(fn, ...)
			local ok, v = pcall(fn, ...)
			return ok and v or nil
		end
		rows[#rows + 1] = {
			id = id,
			auto = get(function() return inc:IsStreamAutomatic(id) end) and true or false,
			value = get(function() return inc:GetStreamRealValue(id) end),
			interval = get(function() return inc:GetStreamRealInterval(id) end),
			count = get(function() return inc:GetStreamCount(id) end) or 0,
		}
	end
	table.sort(rows, function(a, b)
		return (isHuge(a.value) and a.value or NONE) > (isHuge(b.value) and b.value or NONE)
	end)
	STATE.streams = rows
end

--------------------------------------------------------------------------------
-- fruit - the only thing here that moves the body
--
-- Ripeness is the presence of Fruit.ClickFruitPart; a harvested fruit loses
-- that child and turns transparent. Every tree on the map counts, not just the
-- ones on the player's own plot.
--
-- The sweep teleports rather than walks. Walking to 800 fruit at the game's
-- WalkSpeed would take the rest of the day, and the server only checks the
-- distance at the moment the detector fires, so a one-frame hop is enough.
-- The body is put back where it started when the sweep ends or the toggle goes
-- off, so turning the feature off leaves the player where they were.
--------------------------------------------------------------------------------

local FRUIT_REACH = 16      -- the ClickDetector's MaxActivationDistance
local FRUIT_HOP = 0.1       -- settle time after a teleport, before the click
local FRUIT_SETTLE = 0.1    -- and after it, before moving on

local function humanoidRoot()
	local char = plr.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- A fruit is ripe iff it still owns its ClickFruitPart with a ClickDetector.
local function ripeFruits()
	local out = {}
	for _, part in ipairs(CollectionService:GetTagged("ClickFruit")) do
		if part.Parent then
			local clickPart = part:FindFirstChild("ClickFruitPart")
			local detector = clickPart and clickPart:FindFirstChildOfClass("ClickDetector")
			if detector then out[#out + 1] = { part = part, detector = detector } end
		end
	end
	return out
end

local function stepFruit()
	if not fireclickdetector then
		STATE.blocked = "executor has no fireclickdetector - fruit harvesting off"
		return
	end
	local root = humanoidRoot()
	if not root then return end

	local ripe = ripeFruits()
	STATE.fruitRipe = #ripe
	if #ripe == 0 then return end

	-- Nearest first, so a sweep that is cut short by the toggle has still taken
	-- the fruit around the player rather than a random scatter.
	local origin = root.Position
	table.sort(ripe, function(a, b)
		return (a.part.Position - origin).Magnitude < (b.part.Position - origin).Magnitude
	end)

	local home = root.CFrame
	STATE.fruitHome = home

	-- Capped rather than "walk all 820": fruit regrows while the sweep runs, so
	-- coming back to re-scan beats finishing one stale list. At ~0.22s a fruit
	-- this is a six-second pass.
	local budget = math.clamp(CONFIG.fruitPerSweep or 30, 5, 200)

	for index, entry in ipairs(ripe) do
		if GEN ~= _G.__LEMON then break end
		if not (CONFIG.auto and CONFIG.autoFruit) then break end
		if index > budget then break end

		-- A fruit picked by somebody else between the scan and here is simply
		-- skipped; Luau has no goto, so this is an if rather than a continue.
		if entry.part.Parent then
			root = humanoidRoot()      -- the character can be rebuilt mid-sweep
			if not root then break end

			if (root.Position - entry.part.Position).Magnitude > FRUIT_REACH then
				root.CFrame = CFrame.new(entry.part.Position + Vector3.new(0, 3, 0))
				task.wait(FRUIT_HOP)
				root = humanoidRoot()
				if not root then break end
			end

			pcall(fireclickdetector, entry.detector)
			STATE.fruits = STATE.fruits + 1
			task.wait(FRUIT_SETTLE)
		end
	end

	local back = humanoidRoot()
	if back and home then pcall(function() back.CFrame = home end) end
end

--------------------------------------------------------------------------------
-- the two minigames
--
-- Both follow the same shape: a Start that returns what a perfect round is
-- worth, then an End that is told the result. Neither is simulated - the
-- announced value is handed straight back.
--------------------------------------------------------------------------------

local function raceAvailableAt()
	local svc = req(path(ReplicatedStorage, "Modules", "Service", "MinigameRaceService"))
	if not svc or not svc.GetRaceAvailableTime then return math.huge end
	local ok, t = pcall(svc.GetRaceAvailableTime)
	return (ok and type(t) == "number") and t or math.huge
end

local function tradeAvailableAt()
	local svc = req(path(ReplicatedStorage, "Modules", "Service", "MinigameTradeService"))
	if not svc or not svc.GetTradingAvailableTime then return math.huge end
	local ok, t = pcall(svc.GetTradingAvailableTime)
	return (ok and type(t) == "number") and t or math.huge
end

local function stepRace()
	local at = raceAvailableAt()
	STATE.raceIn = math.max(0, at - os.time())
	if at > os.time() then return end
	local startRemote = coreRequest("MinigameRaceService.Start")
	local endRemote = coreRequest("MinigameRaceService.End")
	if not (startRemote and endRemote) then return end
	local ok, prize = pcall(function() return startRemote:InvokeServer() end)
	if not ok or not isHuge(prize) then return end
	task.wait(0.3)
	-- Placement 1 is worth the whole prize; Config.MinigameRacePlacementCash
	-- scales 2nd to a half, 3rd to a quarter and 4th to nothing.
	local okEnd = pcall(function() return endRemote:InvokeServer(1) end)
	if okEnd then
		STATE.races = STATE.races + 1
		STATE.earnedRace = STATE.earnedRace + toNum(prize)
		STATE.note = "race won, " .. fmt(prize)
	end
end

local function stepTrade()
	local at = tradeAvailableAt()
	STATE.tradeIn = math.max(0, at - os.time())
	if at > os.time() then return end
	local startRemote = coreRequest("MinigameTradeService.Start")
	local endRemote = coreRequest("MinigameTradeService.End")
	if not (startRemote and endRemote) then return end
	local ok, cfg = pcall(function() return startRemote:InvokeServer() end)
	if not ok or type(cfg) ~= "table" or not isHuge(cfg.MaxEarnings) then return end
	task.wait(0.3)
	local okEnd = pcall(function() return endRemote:InvokeServer(cfg.MaxEarnings) end)
	if okEnd then
		STATE.trades = STATE.trades + 1
		STATE.earnedTrade = STATE.earnedTrade + toNum(cfg.MaxEarnings)
		STATE.note = "trade closed, " .. fmt(cfg.MaxEarnings)
	end
end

--------------------------------------------------------------------------------
-- cash drops
--
-- The id only ever exists on the wire, so the signal has to be tapped before
-- the first drop appears. The tap is stored in _G and disconnected on
-- re-execute: a boolean guard would survive the reload and leave the previous
-- run's closure writing into a table nobody reads any more.
--------------------------------------------------------------------------------

local dropQueue = {}

local function armDrops()
	if _G.__LEMON_DROPCONN then pcall(function() _G.__LEMON_DROPCONN:Disconnect() end) end
	local signal = coreSignal("DropService.New")
	if not signal then return end
	_G.__LEMON_DROPCONN = signal.OnClientEvent:Connect(function(id)
		if id ~= nil then dropQueue[#dropQueue + 1] = id end
	end)
end

local function stepDrops()
	if #dropQueue == 0 then return end
	local redeem = coreRequest("DropService.Redeem")
	if not redeem then return end
	local id = table.remove(dropQueue, 1)
	local ok, value = pcall(function() return redeem:InvokeServer(id) end)
	if ok and isHuge(value) then
		STATE.drops = STATE.drops + 1
		STATE.earnedDrop = STATE.earnedDrop + toNum(value)
		STATE.note = "drop " .. tostring(id) .. " = " .. fmt(value)
	end
end

--------------------------------------------------------------------------------
-- phone offers
--
-- Raising is worth real money and losing the offer costs all of it, so the
-- raise count is a hard stepper and never a loop-until-it-stops. After every
-- raise the current value is re-read; if it came back nil the deal is gone and
-- there is nothing left to accept.
--------------------------------------------------------------------------------

local function currentOffer()
	local po = phoneOffers()
	if not po then return nil end
	local ok, v = pcall(function() return po:GetCurrentOffer() end)
	return (ok and isHuge(v)) and v or nil
end

local function stepOffer()
	local po = phoneOffers()
	if not po then return end
	local value = currentOffer()
	STATE.offerValue = value
	if not value then return end

	local raised = 0
	for _ = 1, math.clamp(CONFIG.offerRaises or 0, 0, 2) do
		pcall(function() po:RaiseOffer() end)
		task.wait(1.2)
		local after = currentOffer()
		if not after then
			-- The third raise did exactly this in testing: the offer vanished.
			STATE.note = "offer lost on raise " .. (raised + 1)
			STATE.offerValue = nil
			return
		end
		raised = raised + 1
		STATE.offerValue = after
		value = after
	end

	local ok = pcall(function() po:AcceptOffer() end)
	if ok then
		STATE.offers = STATE.offers + 1
		STATE.offerRaised = raised
		STATE.earnedOffer = STATE.earnedOffer + toNum(value)
		STATE.note = "offer accepted " .. fmt(value) .. (raised > 0 and (" (+" .. raised .. " raise)") or "")
	end
end

--------------------------------------------------------------------------------
-- powers - the investor spend
--
-- Investors are consumed, not merely required: buying Manage took the balance
-- 176 -> 76, so a wasted power is permanently wasted. Priority, and why:
--
--   ClickFruitValue  FIRST, at 250. Its bonuses are {Amt 2, Mult 2} rising to
--                    {6, 8}, so level one alone is two fruit per click at
--                    double value - four times the income of the single
--                    biggest earner in the game, for a quarter of what the
--                    next power costs.
--   UpgradeStack     second, at 1,000. The only thing that lifts Count, and
--                    Count is how many earner levels one call may buy
--                    (1 -> 5 -> 25 -> 100 -> inf).
--   BuyNext          1e38 investors, and AutoFruit 1e42. Both far future, both
--                    worth taking the moment they are reachable.
--
-- SKIPPED ON PURPOSE, and both were paid for to find out:
--   Manage    100 investors, and it buys a HUD TAB. The only things that
--             reference the power are UI.Layers.Manage.UIManageMenu and the
--             orchard billboard. Bought it: investors 176 -> 76, level 0 -> 1,
--             and nothing moved - no stream became automatic, the upgrade
--             Count stayed at 1, income was unchanged. Useless to a script
--             that never opens the menu.
--   WalkSpeed 400 investors for 1.5x to 4x movement. This file teleports; it
--             never walks anywhere.
-- Both stay in SKIP_POWERS rather than being deleted, so the panel can offer
-- them to somebody who does play by hand.
--------------------------------------------------------------------------------

local POWER_ORDER = { "ClickFruitValue", "UpgradeStack", "BuyNext", "AutoFruit", "Manage", "WalkSpeed" }
local SKIP_POWERS = { Manage = true, WalkSpeed = true }

local function powerState()
	local pw = powers()
	if not pw then return {} end
	local ok, levels = pcall(function() return pw:GetLevels() end)
	if not ok or type(levels) ~= "table" then return {} end
	local out = {}
	for name, level in pairs(levels) do
		local okMax, max = pcall(function() return pw:GetMaxLevel(name) end)
		local okPrice, price = pcall(function() return pw:GetUpgradePrice(name) end)
		out[name] = {
			level = level,
			max = okMax and max or nil,
			price = (okPrice and isHuge(price)) and price or nil,
		}
	end
	return out
end

local function investors()
	local b = balances()
	if not b then return NONE end
	local ok, v = pcall(function() return b:GetInvestors() end)
	return (ok and isHuge(v)) and v or NONE
end

local function stepPowers()
	local pw = powers()
	if not pw then return end
	local state = powerState()
	STATE.powerLevels = state
	local have = investors()

	-- Buy the first AFFORDABLE entry in priority order rather than stopping at
	-- the first unaffordable one. The earlier version returned as soon as it hit
	-- a power it could not pay for, which meant that straight after a rebirth it
	-- sat on its investors staring at UpgradeStack and never bought anything.
	-- Starvation is not a risk here because the order is already ranked by
	-- value: once the cheap rung is owned its next level costs far more than the
	-- rung below it, so the cursor moves down on its own.
	local firstTarget, firstPrice
	for _, name in ipairs(POWER_ORDER) do
		local entry = state[name]
		local skipped = SKIP_POWERS[name] and not CONFIG.buyCosmeticPowers
		if entry and entry.price and not skipped and (not entry.max or entry.level < entry.max) then
			if not firstTarget then firstTarget, firstPrice = name, entry.price end
			if atLeast(have, entry.price) then
				-- Priced in INVESTORS. The server answers "insufficient
				-- investors" rather than "insufficient cash" when it is short.
				local ok = pcall(function() return pw:UpgradeAsync(name) end)
				if ok then
					STATE.powerBuys = STATE.powerBuys + 1
					STATE.note = "power " .. name .. " -> " .. tostring((entry.level or 0) + 1)
				end
				STATE.nextPower, STATE.nextPowerPrice = name, entry.price
				return
			end
		end
	end
	STATE.nextPower = firstTarget or "all owned"
	STATE.nextPowerPrice = firstPrice
end

--------------------------------------------------------------------------------
-- prestige
--
-- Spending never costs progress: potential investors are computed from
-- cash + cashSpent, so a dollar in the bank and a dollar already sunk into the
-- tycoon are worth the same towards the next rebirth. That is the whole reason
-- the buy and upgrade loops are allowed to run the balance to zero.
--------------------------------------------------------------------------------

local function potentialInvestors()
	local r = rebirth()
	if not r then return NONE end
	local ok, v = pcall(function() return r:GetPotentialInvestors() end)
	return (ok and isHuge(v)) and v or NONE
end

local function shouldRebirth()
	local potential = potentialInvestors()
	if hugeIsZero(potential) then return false end
	local minimum = toHuge(CONFIG.rebirthMinimum)
	if not atLeast(potential, minimum) then return false end
	local have = investors()
	if hugeIsZero(have) then return true end
	-- Both sides are log10, so a multiplication is an addition.
	local factor = math.log10(math.max(CONFIG.rebirthFactor or 1, 1))
	return potential >= have + factor
end

local function stepRebirth()
	if not shouldRebirth() then return end
	local r = rebirth()
	if not r then return end
	local before = potentialInvestors()
	local ok = pcall(function() return r:RebirthAsync() end)
	if ok then
		STATE.note = "rebirthed for " .. fmt(before) .. " investors"
		task.wait(2)
	end
end

local function stepEvolve()
	local e = evolution()
	if not e then return end
	local ok, progress = pcall(function() return e:GetEvolutionProgress() end)
	if not ok or type(progress) ~= "number" then return end
	STATE.evolveProgress = progress
	if progress < 1 then return end
	if pcall(function() return e:EvolveAsync() end) then
		STATE.note = "evolved"
		task.wait(2)
	end
end

local function stepAscend()
	local a = ascension()
	if not a then return end
	local ok, progress = pcall(function() return a:GetAscensionProgress() end)
	if not ok or type(progress) ~= "number" then return end
	STATE.ascendProgress = progress
	if progress < 1 then return end
	if pcall(function() return a:AscendAsync() end) then
		STATE.note = "ascended"
		task.wait(2)
	end
end

--------------------------------------------------------------------------------
-- companions
--
-- Cheap, harmless and entirely unmeasured beyond the API shape - GetPending()
-- was empty for the whole test session, so nothing was ever claimed. It runs
-- with the rest of the slow loop rather than getting its own toggle.
--------------------------------------------------------------------------------

local function stepCompanions()
	local c = companions()
	if not c then return end
	local ok, pending = pcall(function() return c:GetPending() end)
	if ok and type(pending) == "table" then
		for _, key in ipairs(pending) do
			pcall(function() return c:ClaimCompanionAsync(key) end)
		end
	end
	local okEq, equipped = pcall(function() return c:GetEquippedCompanion() end)
	if okEq and equipped == nil then
		local okUn, unlocked = pcall(function() return c:GetUnlocked() end)
		if okUn and type(unlocked) == "table" and unlocked[1] then
			pcall(function() return c:SetEquippedAsync(unlocked[1]) end)
		end
	end
end

--------------------------------------------------------------------------------
-- orchard - UNVERIFIED, see the file header
--
-- Never executed against a live server. The unlock alone is 1e25 cash and the
-- test account topped out around 1e12, so every line below is written from the
-- module API and nothing more. It ships off and the panel says so.
--------------------------------------------------------------------------------

local PLOT_EMPTY, PLOT_TREE_GROWING, PLOT_FRUIT_GROWING, PLOT_FRUIT_READY = 0, 1, 2, 3

local function orchardModule()
	return req(path(ReplicatedStorage, "Modules", "Tycoon", "Orchard", "Orchard"))
end

local function orchardIsUnlocked()
	local mod = orchardModule()
	if not (mod and Tycoon) then return false end
	local ok, lt = pcall(Tycoon.getLocal)
	if not ok or not lt then return false end
	local okO, orchard = pcall(function() return mod.getFromTycoon(lt) end)
	if not okO or not orchard then return false end
	local okU, unlocked = pcall(function() return orchard:IsUnlocked() end)
	return okU and unlocked or false
end

local function stepOrchard()
	STATE.orchardUnlocked = orchardIsUnlocked()

	if not STATE.orchardUnlocked then
		-- Config.Orchard.UnlockCashPrice is 1e25.
		local price = Config and Config.Orchard and Config.Orchard.UnlockCashPrice
		local hugePrice = price and toHuge(price) or nil
		if hugePrice and canAfford(hugePrice) then
			local remote = tycoonRemote("UnlockOrchard")
			if remote and remote:IsA("RemoteFunction") then
				if pcall(function() return remote:InvokeServer() end) then
					STATE.orchardNote = "unlock fired (unverified)"
				end
			end
		else
			STATE.orchardNote = "locked, needs " .. (hugePrice and fmt(hugePrice) or "1e25")
		end
		return
	end

	local t = myTycoon()
	local plots = t and path(t, "Orchard", "Plots")
	if not plots then return end

	local plant = coreRequest("OrchardPlot.Plant")
	local harvest = coreRequest("OrchardPlot.Harvest")
	local unlockPlot = tycoonRemote("UnlockPlot")
	local ready, planted, unlockedNow = 0, 0, 0

	for _, plot in ipairs(plots:GetChildren()) do
		if GEN ~= _G.__LEMON then return end
		local state = plot:GetAttribute("State")
		local enabled = plot:GetAttribute("Enabled")
		local base = plot:GetAttribute("BaseUnlocked")

		if not base and plot:GetAttribute("Available") and unlockPlot then
			if pcall(function() return unlockPlot:InvokeServer(plot.Name) end) then
				unlockedNow = unlockedNow + 1
			end
		elseif enabled and state == PLOT_FRUIT_READY and harvest then
			if pcall(function() return harvest:InvokeServer(plot) end) then ready = ready + 1 end
		elseif enabled and state == PLOT_EMPTY and plant then
			if pcall(function() return plant:InvokeServer(plot) end) then planted = planted + 1 end
		end
	end

	local sell = path(t, "Values", "SellFruits")
	if sell and sell:IsA("RemoteFunction") then
		pcall(function() return sell:InvokeServer() end)
	end

	STATE.orchardNote = string.format("unverified: %d harvested, %d planted, %d plots unlocked",
		ready, planted, unlockedNow)
end

--------------------------------------------------------------------------------
-- the SpecialIncome tap
--
-- The server announces every one-off payout as (sourceName, hugeAmount). It is
-- the only honest per-feature earnings figure available - a balance delta is
-- useless once the streams are paying trillions a second.
--------------------------------------------------------------------------------

local function armSpecialIncome()
	if _G.__LEMON_SICONN then pcall(function() _G.__LEMON_SICONN:Disconnect() end) end
	local remote = tycoonRemote("SpecialIncome")
	if not remote then return end
	_G.__LEMON_SICONN = remote.OnClientEvent:Connect(function(source, amount)
		if not isHuge(amount) then return end
		if source == "ClickFruit" then
			STATE.earnedFruit = STATE.earnedFruit + toNum(amount)
		end
	end)
end

--------------------------------------------------------------------------------
-- state refresh
--------------------------------------------------------------------------------

local RATE_WINDOW = 8

local function refresh()
	local b, p, r, e, a = balances(), purchases(), rebirth(), evolution(), ascension()
	if b then
		local function get(fn)
			local ok, v = pcall(fn)
			return (ok and isHuge(v)) and v or NONE
		end
		STATE.cash = get(function() return b:GetCash() end)
		STATE.spent = get(function() return b:GetCashSpent() end)
		STATE.investors = get(function() return b:GetInvestors() end)
		local okT, tokens = pcall(function() return b:GetTokens() end)
		STATE.tokens = okT and tokens or 0
	end
	if p then
		local ok, n = pcall(function() return p:GetPurchasedCount() end)
		STATE.purchased = ok and n or STATE.purchased
	end
	if r then
		STATE.potential = potentialInvestors()
		local ok, n = pcall(function() return r:GetRebirths() end)
		STATE.rebirths = ok and n or STATE.rebirths
	end
	if e then
		local ok, v = pcall(function() return e:GetEvolutionProgress() end)
		if ok and type(v) == "number" then STATE.evolveProgress = v end
		local okE, n = pcall(function() return e:GetEvolution() end)
		STATE.evolution = okE and n or STATE.evolution
	end
	if a then
		local ok, v = pcall(function() return a:GetAscensionProgress() end)
		if ok and type(v) == "number" then STATE.ascendProgress = v end
		local okA, n = pcall(function() return a:GetAscension() end)
		STATE.ascension = okA and n or STATE.ascension
	end

	STATE.raceIn = math.max(0, raceAvailableAt() - os.time())
	STATE.tradeIn = math.max(0, tradeAvailableAt() - os.time())

	-- Income rate off the balance is only honest while nothing is being spent,
	-- and this script spends constantly, so the rate is computed from
	-- cash + cashSpent, which only ever rises.
	local total = toNum(STATE.cash) + toNum(STATE.spent)
	local now = os.clock()
	if STATE.rateAt == nil then
		STATE.rateAt, STATE.rateRef = now, total
	elseif now - STATE.rateAt >= RATE_WINDOW then
		local span = now - STATE.rateAt
		local delta = total - (STATE.rateRef or total)
		if delta >= 0 then STATE.incomeRate = delta / span end
		STATE.rateAt, STATE.rateRef = now, total
	end
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(interval, key, fn)
	task.spawn(function()
		while GEN == _G.__LEMON do
			if CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then STATE.note = tostring(err) end
			end
			task.wait(interval)
		end
	end)
end

-- The wake sweep reads its own interval every pass so the slider takes effect
-- without a restart.
task.spawn(function()
	while GEN == _G.__LEMON do
		if CONFIG.auto and CONFIG.autoWake then
			pcall(stepWake)
		end
		task.wait(math.max(CONFIG.wakeSpacing or 0.15, 0.05))
	end
end)

loop(0.3, "autoBuy", stepBuy)
loop(0.4, "autoUpgrade", stepUpgrade)
loop(1, "autoFruit", stepFruit)
loop(1, "autoDrops", stepDrops)
loop(5, "autoOffers", stepOffer)
loop(8, "autoRace", stepRace)
loop(8, "autoTrade", stepTrade)
loop(4, "autoPowers", stepPowers)
loop(6, "autoRebirth", stepRebirth)
loop(6, "autoEvolve", stepEvolve)
loop(10, "autoAscend", stepAscend)
loop(20, nil, stepCompanions)
loop(15, "autoOrchard", stepOrchard)

-- The refresh loop runs whether or not the master switch is on: the panel has
-- to show the truth while the automation is stopped, which is exactly when
-- anything is being measured.
task.spawn(function()
	while GEN == _G.__LEMON do
		pcall(refresh)
		pcall(readStreams)
		task.wait(1)
	end
end)

armDrops()
armSpecialIncome()

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__LEMON_WIN then pcall(function() _G.__LEMON_WIN:Destroy() end) end

local win = UI.Window({
	title = "SELL", accentTitle = "LEMONS", subtitle = "seltonmt",
	badge = "🍋", width = 820, height = 582,
})
_G.__LEMON_WIN = win

local farm = win:Page("TYCOON", UI.icon.coin)

local main = farm:Card("LOOP", 1):Accent()
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.note = v and "running" or "stopped"
end, "buy, upgrade and collect - nothing here needs the body", UI.theme.good)
main:Toggle("Auto buy", CONFIG.autoBuy, function(v) CONFIG.autoBuy = v end,
	"walks the game's own build order, 453 buttons")
main:Toggle("Auto upgrade", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
	"cheapest earner first, always with the allowed stack size")
main:Toggle("Auto click earners", CONFIG.autoWake, function(v) CONFIG.autoWake = v end,
	"only streams without a manager - the rest pay by themselves")
main:Slider("Click spacing", 5, 100, math.floor((CONFIG.wakeSpacing or 0.15) * 100), function(v)
	CONFIG.wakeSpacing = v / 100
end)

local money = farm:Card("ONE-OFF MONEY", 2)
money:Toggle("Auto fruit", CONFIG.autoFruit, function(v) CONFIG.autoFruit = v end,
	"teleports tree to tree - the single biggest earner in the game", UI.theme.good)
money:Stepper("Fruit per sweep", function()
	return tostring(CONFIG.fruitPerSweep or 30)
end, function(dir)
	CONFIG.fruitPerSweep = math.clamp((CONFIG.fruitPerSweep or 30) + dir * 10, 10, 200)
end, "then it rescans, because fruit regrows while the sweep runs")
money:Toggle("Auto race", CONFIG.autoRace, function(v) CONFIG.autoRace = v end,
	"every five minutes, finished in first place")
money:Toggle("Auto trade", CONFIG.autoTrade, function(v) CONFIG.autoTrade = v end,
	"every five minutes, a perfect round - billions per call", UI.theme.good)
money:Toggle("Auto cash drops", CONFIG.autoDrops, function(v) CONFIG.autoDrops = v end,
	"redeemed by id, no walking to them")
money:Toggle("Auto phone offers", CONFIG.autoOffers, function(v) CONFIG.autoOffers = v end,
	"accepts the deal calls")
money:Stepper("Haggle", function()
	local n = CONFIG.offerRaises or 0
	return n == 0 and "never" or (n .. "x")
end, function(dir)
	CONFIG.offerRaises = math.clamp((CONFIG.offerRaises or 0) + dir, 0, 2)
end, "raising pays more, three raises lost the offer completely", UI.theme.warn)

local prestige = farm:Card("PRESTIGE", 1)
prestige:Toggle("Auto powers", CONFIG.autoPowers, function(v) CONFIG.autoPowers = v end,
	"spends investors - fruit value first, then the upgrade stack")
prestige:Toggle("Buy Manage and WalkSpeed", CONFIG.buyCosmeticPowers,
	function(v) CONFIG.buyCosmeticPowers = v end,
	"Manage only opens a HUD tab and this script teleports - both do nothing here",
	UI.theme.warn)
prestige:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
	"wipes the tycoon for investors - spending is never lost", UI.theme.warn)
prestige:Stepper("Rebirth at", function()
	return "x" .. tostring(CONFIG.rebirthFactor)
end, function(dir)
	CONFIG.rebirthFactor = math.clamp((CONFIG.rebirthFactor or 10) + dir, 2, 100)
end, "potential investors this many times what you already hold")
prestige:Stepper("Never below", function()
	return tostring(CONFIG.rebirthMinimum)
end, function(dir)
	local steps = { 10, 100, 1000, 10000, 100000 }
	local index = 1
	for i, v in ipairs(steps) do if v == CONFIG.rebirthMinimum then index = i end end
	CONFIG.rebirthMinimum = steps[math.clamp(index + dir, 1, #steps)]
end, "the cheapest power costs 100 investors")
prestige:Toggle("Auto evolve", CONFIG.autoEvolve, function(v) CONFIG.autoEvolve = v end,
	"ten fruit tiers, x42 each - wipes more than a rebirth", UI.theme.warn)
prestige:Toggle("Auto ascend", CONFIG.autoAscend, function(v) CONFIG.autoAscend = v end,
	"only once all 453 buttons are bought, x7.77", UI.theme.bad)

local extra = farm:Card("ORCHARD", 2)
extra:Toggle("Auto orchard", CONFIG.autoOrchard, function(v) CONFIG.autoOrchard = v end,
	"UNVERIFIED - never reached in testing, the unlock alone is 1e25", UI.theme.bad)
extra:Label("plant, harvest and sell on the 50 plots")
extra:Label("Robux is never touched: no boosts, no forever purchase")

local out = farm:Card("STATUS", 0):Readout(16, function(text)
	if text:find("UNVERIFIED") or text:find("blocked") then return UI.theme.bad end
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

local function short(n)
	if type(n) ~= "number" or n <= 0 then return "0" end
	return fmt(toHuge(n))
end

task.spawn(function()
	while GEN == _G.__LEMON do
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  cash      " .. fmt(STATE.cash) .. "   spent " .. fmt(STATE.spent),
			"  income    " .. short(STATE.incomeRate) .. "/s",
			"  buttons   " .. STATE.purchased .. " / 453   (" ..
				string.format("%.1f%%", (STATE.ascendProgress or 0) * 100) .. " to ascend)",
			"  investors " .. fmt(STATE.investors) .. "   potential " .. fmt(STATE.potential),
			"  rebirths  " .. STATE.rebirths .. "   evolution " .. STATE.evolution ..
				" (" .. string.format("%.1f%%", (STATE.evolveProgress or 0) * 100) .. ")",
			"  next buy  " .. tostring(STATE.nextBuy) ..
				(STATE.nextBuyPrice and ("  " .. fmt(STATE.nextBuyPrice)) or ""),
			"  next upg  " .. tostring(STATE.nextUpgrade) ..
				(STATE.nextUpgradePrice and ("  " .. fmt(STATE.nextUpgradePrice) ..
					"  x" .. tostring(STATE.nextUpgradeCount)) or ""),
			"  next pow  " .. tostring(STATE.nextPower) ..
				(STATE.nextPowerPrice and ("  " .. fmt(STATE.nextPowerPrice) .. " investors") or ""),
			"  race      " .. (STATE.raceIn > 0 and (math.floor(STATE.raceIn) .. "s") or "ready") ..
				"   won " .. STATE.races .. "  " .. short(STATE.earnedRace),
			"  trade     " .. (STATE.tradeIn > 0 and (math.floor(STATE.tradeIn) .. "s") or "ready") ..
				"   closed " .. STATE.trades .. "  " .. short(STATE.earnedTrade),
			"  drops     " .. STATE.drops .. "  " .. short(STATE.earnedDrop) ..
				"   offers " .. STATE.offers .. "  " .. short(STATE.earnedOffer),
			"  fruit     " .. STATE.fruits .. " picked  " .. short(STATE.earnedFruit) ..
				"   " .. STATE.fruitRipe .. " ripe on the map",
			"  clicks    " .. STATE.wakes .. " wakes   " .. STATE.upgrades .. " upgrades   " ..
				STATE.buys .. " buys",
		}

		local streamLine = "  streams   "
		local shown = 0
		for _, row in ipairs(STATE.streams or {}) do
			if shown < 3 and not hugeIsZero(row.value) then
				streamLine = streamLine .. row.id .. " " .. fmt(row.value) ..
					"/" .. fmtTime(row.interval) .. (row.auto and "(a) " or "(m) ")
				shown = shown + 1
			end
		end
		lines[#lines + 1] = shown > 0 and streamLine or "  streams   none producing yet"

		if CONFIG.autoOrchard then lines[#lines + 1] = "  orchard   " .. tostring(STATE.orchardNote) end
		lines[#lines + 1] = "  " .. tostring(STATE.note)
		if STATE.blocked then lines[#lines + 1] = "  blocked   " .. STATE.blocked end

		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s cash   %s/s   %d/453   reb %d   ev %d",
				fmt(STATE.cash), short(STATE.incomeRate), STATE.purchased,
				STATE.rebirths, STATE.evolution))
		end)
		task.wait(0.5)
	end
end)

pcall(function() win:Home() end)

win:SetStat(1, "-", "cash")
win:SetStat(2, "-", "cash/s")
win:SetStat(3, "-", "buttons")
win:SetMaster(CONFIG.auto, CONFIG.auto and "Auto Farm running" or "Stopped")
win:OnMaster(function(on)
	CONFIG.auto = on
	STATE.note = on and "running" or "stopped"
	win:Refresh()
end)

task.spawn(function()
	while GEN == _G.__LEMON do
		pcall(function()
			win:SetStat(1, fmt(STATE.cash))
			win:SetStat(2, short(STATE.incomeRate) .. "/s")
			win:SetStat(3, STATE.purchased .. "/453")
			win:SetMaster(CONFIG.auto, CONFIG.auto and "Auto Farm running" or "Stopped")
		end)
		task.wait(1)
	end
end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__LEMON_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	Huge = Huge, Balance = Balance, Config = Config,
	comp = comp, myTycoon = myTycoon, tycoonRemote = tycoonRemote,
	coreRequest = coreRequest, coreSignal = coreSignal,
	fmt = fmt, toNum = toNum, toHuge = toHuge, atLeast = atLeast,
	nextPurchase = nextPurchase, stepBuy = stepBuy,
	bestUpgrade = bestUpgrade, stepUpgrade = stepUpgrade,
	stepWake = stepWake, readStreams = readStreams,
	ripeFruits = ripeFruits, stepFruit = stepFruit, humanoidRoot = humanoidRoot,
	stepRace = stepRace, stepTrade = stepTrade,
	stepDrops = stepDrops, stepOffer = stepOffer, currentOffer = currentOffer,
	powerState = powerState, stepPowers = stepPowers,
	potentialInvestors = potentialInvestors, shouldRebirth = shouldRebirth,
	stepRebirth = stepRebirth, stepEvolve = stepEvolve, stepAscend = stepAscend,
	stepOrchard = stepOrchard, stepCompanions = stepCompanions,
	refresh = refresh, dropQueue = dropQueue,
}

print("[selllemons] gen " .. GEN .. " ready - RightShift for the panel")
