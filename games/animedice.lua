--!nocheck
-- [Anime Dice] - full idle loop, every lever measured live against the server's
-- own data table, not assumed.
--
-- Oracle: require(RS.Framework.Features.Data.DataController).___X is the live,
-- server-mirrored player data (Money, Rolls, Rebirth, Dice, Inventory, Slots,
-- OwnedDice, ...). Every before/after check below reads it, so nothing here is a
-- client-only illusion.
--
-- What was verified (2026-09-24, bridge 1):
--   * Roll   RollService.RF.RollDice:InvokeServer() - FREE (costs no money, only
--            increments Rolls), returns { { result = <unitName> } }. No batch
--            argument works. Hard server cooldown ~2s: 40 fast calls over ~8s
--            registered only 4 rolls, and over-fast calls silently no-op (the
--            InvokeServer returns but nothing changes). So we roll at ~2.1s.
--   * Income Placed units sit on plot Slots ("1".."N" = {unitId, balance}) and
--            accrue `balance` per second. EquipBest collects EVERY slot balance
--            into Money AND re-places the best-income units into every unlocked
--            slot in one call - verified Money 235 -> 106016 (+105781) while
--            slots went 2 -> 4. It is the whole income engine.
--   * Collect CollectBalance:FireServer(slotNumber) empties one slot (number, not
--            string). EquipBest already does all of them, so this is only a
--            manual helper.
--   * Level  LevelUpSlot:FireServer(slotNumber) +1 level on that slot's unit.
--            income(attributes) = base x (1 + 0.25 x (level - 1)); price =
--            income(mutation only) x 1.6^(level-1). Payback therefore grows 1.6x
--            per level whatever the unit - levelled only up to a payback cap.
--            income() takes u.ATTRIBUTES; passing the entry drops mutation,
--            grade, trait and level (the first build did, and ranked wrong).
--   * Place  EquipBest ranks WITH level, so levelled weak units never leave.
--            placeBest ranks by level-1 income and swaps via Equip + InteractSlot.
--   * Dice   Dice.GetAll() -> {key, luck, price, rarity}. Higher luck rolls rarer
--            units, and rarity is the income driver (base Uncommon 100, Rare 1e3,
--            Epic 1e5, Legendary 1e7, Mythical 1e9 ... Heavenly 1e23). BuyDice
--            (key) costs Money, EquipDice(key) equips. Verified Water: -10000,
--            Normal -> Water.
--   * Rebirth Rebirth:FireServer() wipes ONLY Money (105963 -> 0), +1 Rebirth,
--            KEEPS Inventory, OwnedDice, equipped Dice, Slots and Upgrades. Each
--            level is a permanent x money AND x luck multiplier and unlocks one
--            more slot. Cost/mult ladder from Rebirths.Get(n): r1 50k x1.5,
--            r2 5M x2, r3 500M x2.5, r4 50B x3 ... r10 1e22 x14.
--   * Slots  PlotConfig.GetSlotRebirthRequirement(i): 1-4 free, 5=rb1, 6=rb2,
--            7=rb3, 8=rb4, 9=rb6 ... 15=rb12. GetMaxSlots = 15.
--   * AutoSell UpdateAutoSell:FireServer(order) sets the game's own auto-sell to
--            drop rolled units below that rarity sortOrder (Common 1, Uncommon 2,
--            Rare 3, Epic 4, Legendary 5 ...). Verified the flag stores.
--   * Codes  MonetizationConfig.Codes lists them; RedeemCode:FireServer(code)
--            redeems (RELEASE -> +10000 money verified, RedeemedCodes updated).
--   * Claims OfflineEarnings/DailyReward/GroupReward .Claim:FireServer().
--
--   * Luck   The roll only draws units whose 1-in-N chance is >= your luck and
--            weights them by luck/chance, so luck decides rarity outright. The
--            server's luck = GetBuff("Luck") x equipped die (2nd return of
--            RollDice). Dice + rebirth + boosts are the whole path to Legendary.
--   * Rerolls Grade (1 Gem) / trait (1 Trait Reroll) on the placed units, good
--            tiers protected by name so the server stops on them.
--   * Tower  The server simulates each floor; CompleteTowerFloor just asks for
--            the next one. Skipping the animation is the speed-up. CancelTower
--            only queues the end - a cancelled run must be drained or it blocks
--            every new PlayTower.
--
--   * Fuse   3 spare units -> 1 whose chance is ~0.667x their SUM, i.e. about
--            twice as rare as their mean. Balanced trios only (see doFuse).
--
-- Update of 2026-10-11, re-read from the server modules (they ship to the client):
--   * RollDice returns nothing while FusingService.Fusing is set - ONE 3s flag for
--            the whole server, set by every Fuse call before it checks the units,
--            so a failing fuse attempt still blocks everybody's rolls.
--   * The game's AutoSell is a 1-in-N chance: a rolled unit whose chance is below
--            it is sold on the spot. It was being sent a rarity index (1-11).
--   * InteractSlot with an EMPTY hand picks the slot's unit up into the hand, and
--            a unit in the hand is no longer protected from SellInventory.
--   * Units can be locked (attributes.locked); Sell and Fuse both skip them.
--   * Codes moved to Codes.CodesConfig + CodesService.RE.RedeemCode (0.5s debounce).
--   * New: rebirth points (RebirthService.AddStat, x(1 + 0.1 per point) on one
--            buff), daily/weekly quests paying Tickets (QuestService.Claim), and a
--            Ticket shop that sells gamepasses for Tickets only (QuestService.Buy).
--
-- Deliberately left out, do not add without new evidence:
--   Forging  ___X is a mirror; purchases are checked against the server copy.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local plr = Players.LocalPlayer

-- Generation guard: re-executing does not restart the VM, so every loop below
-- exits the moment a newer run bumps this counter.
_G.__ANIMEDICE = (_G.__ANIMEDICE or 0) + 1
local generation = _G.__ANIMEDICE
if _G.__ANIMEDICE_GUI then pcall(function() _G.__ANIMEDICE_GUI:Destroy() end) end

-------------------------------------------------------------------- config -----

local CONFIG = {
	auto        = false,  -- master switch; nothing below runs while it is off

	autoRoll    = true,   -- fire RollDice on the server cooldown
	autoSpins   = true,   -- activate Lucky/Jackpot Spins (x100/x1000 on the next roll)
	autoCollect = true,   -- EquipBest: collect every slot + place the best units
	smartPlace  = true,   -- place by level-free potential, not the game's EquipBest
	autoLevel   = true,   -- pour a share of money into placed-slot levels
	levelShare  = 0.3,    -- fraction of money slot-leveling may spend each pass
	levelPayback = 10,    -- only buy a level that pays itself back within N minutes
	saveMinutes = 15,     -- skip leveling/fusing while the next dice/rebirth is
	                      -- this close; at 5 the fuse machine ate every rebirth
	-- Grade/trait odds come from the configs' weights. Grades: D 45%, C 28%, B 15%,
	-- A 8%, A+ 3%, S 0.9%, S+ 0.11%, Z 0.03%, 神 0.002%. Waiting for S costs ~100
	-- Gems per unit on average; "A or better" (12%) costs ~8, so that is the default.
	-- Traits: ~66% are Damage/Health (no income at all); Money II+ (x1.5) is 8.4%.
	autoGrade   = true,   -- spend Gems rerolling the placed units' grades
	gradeMin    = 3,      -- keep grades worth >= this income x (A and better)
	autoTrait   = true,   -- spend Trait Rerolls on the placed units' traits
	traitMin    = 1.5,    -- keep traits worth >= this income x (Money II and better)
	autoBoost   = true,   -- activate owned Luck/Income/Roll Speed boosts
	-- Off by default and under a new key, so saved panels start off too: fusing
	-- eats units ("my units got stolen") and every attempt locks rolling for 3s.
	autoFusion  = false,  -- fuse spare units three at a time into rarer ones
	fuseShare   = 0.35,   -- share of money one fusion may cost...
	fuseSeconds = 30,     -- ...and never more than this many seconds of income
	autoTower   = true,   -- farm a tower for boosts, gems and trait rerolls
	tower       = "Auto (best)",  -- or a fixed tower name
	towerBoosts = true,   -- fire Damage boosts right before a tower run
	autoDice    = true,   -- buy the best affordable dice we do not own, equip best
	autoUpgrade = true,   -- buy the cheapest affordable world-pad upgrade tier
	autoRebirth = true,   -- rebirth once money reaches nextCost x factor
	rebirthMult = 1,      -- rebirth wipes ALL money and nothing else, so rebirthing
	                      -- the moment the cost is met throws away the least
	autoSell    = true,   -- keep the backpack under its cap by selling junk
	sellRarity  = 3,      -- rarity sortOrder floor (3 = always sell below Rare)
	keepBest    = 20,     -- when the bag fills, keep this many best spares, sell rest
	keepLuckX   = 10,     -- never sell a pull whose 1-in-N is >= this x your roll luck
	autoCodes   = true,   -- redeem every code once
	autoClaim   = true,   -- claim offline / daily / group rewards
	autoQuests  = true,   -- claim finished daily/weekly quests (they pay Tickets)
	autoPasses  = true,   -- buy the Ticket-shop gamepasses with Tickets (no Robux)
	autoStats   = true,   -- spend rebirth points
	statPick    = "Money",-- x1.5 money for 5 points beats x1.5 luck (~x1.34 income)
}

-- Which world-pad upgrade lines auto-buy. Damage/Health join them while the tower
-- is farmed (TOWER_CATS); Walkspeed is irrelevant to an idle build.
local UPGRADE_CATS = { "Money", "Luck", "Fortune", "Roll Speed", "Unit Storage", "Sell" }
local INV_CAP_BASE = 100   -- Unit Storage buff default; each owned tier adds +5

local RARITY_ORDER = {
	"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical",
	"Divine", "Exotic", "Celestial", "Secret I / II", "Heavenly", "Galactic", "Exclusive",
}

-- Ticket-shop gamepasses, best first: More Cash x2 money, Luck x1.5, Roll Speed
-- -0.6s per roll, Ultra Luck x3; grade/trait rolls only help the rerolls.
local PASS_ORDER = { "More Cash", "Luck", "Roll Speed", "Ultra Luck", "More Grades", "More Traits" }

local STATE = {
	money = 0, rolls = 0, rebirth = 0, dice = "-", nextDice = "-",
	slotsUsed = 0, slotsMax = 4, incomePerSec = 0,
	invCount = 0, invCap = INV_CAP_BASE, nextUpgrade = "-",
	rolled = 0, collected = 0, diceBought = 0, rebirths = 0, leveled = 0,
	upgradesBought = 0, sold = 0, soldValue = 0,
	gradeRolls = 0, traitRolls = 0, boostsUsed = 0, luck = 0,
	towerRuns = 0, towerFloors = 0, towerBest = 0, towerFloor = 0, towerDrops = 0,
	fused = 0, fuseLast = "-", fuseBestChance = 0,
	towerPick = "-", towerPredict = 0, towerRate = 0,
	codesDone = 0, claims = 0, questsClaimed = 0, passesBought = 0, statsAdded = 0,
	phase = "idle", note = "-", uiOwner = "-",
}

-------------------------------------------------------------- game handles -----

local Network = ReplicatedStorage:WaitForChild("Network", 15)
local Framework = ReplicatedStorage:WaitForChild("Framework", 15)

local function svc(path)
	local node = Network
	for part in string.gmatch(path, "[^%.]+") do
		node = node and node:FindFirstChild(part)
	end
	return node
end

local R = {
	RollDice        = svc("RollService.RF.RollDice"),
	SetAutoRoll     = svc("RollService.RE.SetAutoRoll"),
	EquipBest       = svc("PlotService.RE.EquipBest"),
	CollectBalance  = svc("PlotService.RE.CollectBalance"),
	LevelUpSlot     = svc("PlotService.RE.LevelUpSlot"),
	BuyDice         = svc("DiceShopService.RE.BuyDice"),
	EquipDice       = svc("DiceShopService.RE.EquipDice"),
	Rebirth         = svc("RebirthService.RE.Rebirth"),
	BuyUpgrade      = svc("RE.BuyUpgrade"),
	SellInventory   = svc("SellService.RF.SellInventory"),
	UpdateAutoSell  = svc("SellService.RE.UpdateAutoSell"),
	RedeemCode      = svc("CodesService.RE.RedeemCode") or svc("MonetizationService.RE.RedeemCode"),
	QuestClaim      = svc("QuestService.RE.Claim"),
	QuestBuy        = svc("QuestService.RE.Buy"),
	AddStat         = svc("RebirthService.RE.AddStat"),
	UnequipUnit     = svc("UnitService.RF.Unequip"),
	ClaimOffline    = svc("OfflineEarningsService.RE.Claim"),
	ClaimDaily      = svc("DailyRewardService.RE.Claim"),
	ClaimGroup      = svc("GroupRewardService.RE.Claim"),
	GradeRoll       = svc("GradeService.RE.Roll"),
	GradeProtect    = svc("GradeService.RE.SetGradeProtected"),
	TraitRoll       = svc("TraitService.RE.Roll"),
	TraitProtect    = svc("TraitService.RE.SetTraitProtected"),
	BoostUse        = svc("BoostService.RE.Use"),
	PlayTower       = svc("Towers.RF.PlayTower"),
	CompleteFloor   = svc("Towers.RF.CompleteTowerFloor"),
	CancelTower     = svc("Towers.RF.CancelTower"),
	BestTowerTeam   = svc("Towers.RE.EquipBestTowerTeam"),
	InteractSlot    = svc("PlotService.RE.InteractSlot"),
	UseSpin         = svc("SpinService.RE.Use"),
	EquipUnit       = svc("UnitService.RF.Equip"),
	Fuse            = svc("FusingService.RE.Fuse"),
	FuseResult      = svc("FusingService.RE.Result"),
}

local DataController = require(Framework.Features.Data.DataController)
local Dice           = require(Framework.Features.Rolling.Dice)
local Rebirths       = require(Framework.Features.Rebirth.Rebirths)
local PlotConfig     = require(Framework.Features.Plot.PlotConfig)
local MonetConfig    = require(Framework.Features.Monetization.MonetizationConfig)
local UpgradeConfig  = require(Framework.Features.Upgrades.Upgrades)
local UpgradeTree
pcall(function() UpgradeTree = require(Framework.Features.Upgrades.TreeStructure) end)
local UnitConfig     = require(Framework.Features.Inventory.Kinds.Unit.UnitConfig)
local Grades         = require(Framework.Features.Grades.Grades)
local Traits         = require(Framework.Features.Traits.Traits)
local TowersConfig   = require(Framework.Features.Towers.Towers)
local BuffController = require(Framework.Features.Buffs.BuffController)
local FusingUtil     = require(Framework.Features.Fusing.FusingUtil)
local FusingConfig   = require(Framework.Features.Fusing.FusingConfig)
local UnitUtil
for _, m in ipairs(Framework:GetDescendants()) do
	if m.Name == "UnitUtil" and m:IsA("ModuleScript") then
		pcall(function() UnitUtil = require(m) end)
		break
	end
end
local BoostConfig
pcall(function() BoostConfig = require(Framework.Features.Inventory.Kinds.Boost.BoostConfig) end)
local BOOSTS = (BoostConfig and (BoostConfig.entries or BoostConfig)) or {}

-- Added by the 2026-10-11 update; every one optional so an older build still loads.
local CODES, QuestConfig, RebirthStats, UnitCtl
pcall(function() CODES = require(Framework.Features.Codes.CodesConfig) end)
CODES = CODES or MonetConfig.Codes or {}
pcall(function() QuestConfig = require(Framework.Features.Quests.QuestConfig) end)
pcall(function() RebirthStats = require(Framework.Features.Rebirth.RebirthStatsConfig) end)
pcall(function() UnitCtl = require(Framework.Features.Inventory.Kinds.Unit.UnitController) end)

-- rarity name -> sortOrder (Common 1, Uncommon 2, Rare 3, ...), for the sell floor.
local RARITY_SORT = {}
do
	local ok, Rar = pcall(require, Framework.Other.Rarities)
	if ok and Rar and Rar.Refs then
		for _, ref in pairs(Rar.Refs) do
			local info = select(2, pcall(Rar.Get, ref))
			if type(info) == "table" and info.sortOrder then RARITY_SORT[ref] = info.sortOrder end
		end
	end
end

local NumberFormatter
pcall(function() NumberFormatter = require(ReplicatedStorage.Packages.NumberFormatter) end)

local function fmt(n)
	if NumberFormatter and NumberFormatter.FormatCompact then
		local ok, s = pcall(NumberFormatter.FormatCompact, math.floor(tonumber(n) or 0))
		if ok then return s end
	end
	return tostring(math.floor(tonumber(n) or 0))
end

-- The live, server-mirrored data table. Read fresh every time - it updates in
-- place, so stale-currency mistakes are impossible as long as we never cache it.
local function data() return DataController.___X end

local function count(t)
	local n = 0
	if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
	return n
end

-- income() takes the unit's ATTRIBUTES (mutation, grade, trait, level). Passing
-- the whole inventory entry silently drops all four and made a Diamond Rare look
-- like a plain one - which is how the first build ranked, sold and fused wrong.
-- Income = base x (1 + 0.25 x (level - 1)), so:
--   curIncome   what the unit earns right now, level included (EquipBest's view)
--   baseIncome  the same at level 1 - its potential, since every placed unit is
--               levelled to the same payback cap anyway
local function curIncome(u)
	local e = u and UnitConfig.entries[u.name]
	if not e then return 0 end
	return tonumber(select(2, pcall(e.income, u.attributes or {}))) or 0
end

local function baseIncome(u)
	local e = u and UnitConfig.entries[u.name]
	if not e then return 0 end
	local a = u.attributes or {}
	return tonumber(select(2, pcall(e.income,
		{ mutation = a.mutation, grade = a.grade, trait = a.trait, level = 1 }))) or 0
end

---------------------------------------------------------------- dice model -----

-- Sorted once: name -> {luck, price}. Basic has no price (the free default).
local DICE = {}
do
	local ok, all = pcall(Dice.GetAll)
	if ok and type(all) == "table" then
		for key, def in pairs(all) do
			DICE[#DICE + 1] = {
				key = key,
				luck = tonumber(def.luck) or 0,
				price = tonumber(def.price),  -- nil for the free Basic die
			}
		end
		table.sort(DICE, function(a, b) return a.luck < b.luck end)
	end
end

local function ownedLuck()
	local d = data()
	local best, name = 0, "-"
	for _, die in ipairs(DICE) do
		if d.OwnedDice[die.key] and die.luck > best then best, name = die.luck, die.key end
	end
	return best, name
end

-- Effective roll luck = buff luck x equipped die (the 2nd return of RollDice).
-- The roll only draws units whose 1-in-N chance is >= this.
local function rollLuck()
	local d = data()
	local buffLuck = tonumber(select(2, pcall(BuffController.GetBuff, "Luck"))) or 1
	local dieLuck = 1
	for _, die in ipairs(DICE) do if die.key == d.Dice then dieLuck = die.luck end end
	return buffLuck * dieLuck
end

-- The single strongest die we can pay for right now and do not already own.
-- reserve: money that must stay untouched (a rebirth waiting for it).
local function bestAffordableDice(reserve)
	local d = data()
	local pick
	local spendable = d.Money - (reserve or 0)
	for _, die in ipairs(DICE) do
		if die.price and not d.OwnedDice[die.key] and spendable >= die.price then
			if not pick or die.luck > pick.luck then pick = die end
		end
	end
	return pick
end

------------------------------------------------------------- upgrade model -----

-- Roman numeral -> int, enough for the I..XIV tiers the game ships.
local ROMAN = { I=1, V=5, X=10 }
local function romanToInt(s)
	local total, prev = 0, 0
	for i = #s, 1, -1 do
		local v = ROMAN[s:sub(i, i)] or 0
		if v < prev then total = total - v else total = total + v end
		prev = v
	end
	return total
end

-- Per category: an ascending list of { name, price, storage } tiers.
local UPGRADE_LINES = {}
do
	for name, def in pairs(UpgradeConfig) do
		local cat, roman = name:match("^(.-)%s+([IVX]+)$")
		if cat and roman and def.price then
			UPGRADE_LINES[cat] = UPGRADE_LINES[cat] or {}
			local storage = 0
			if def.buffs and def.buffs["Unit Storage"] then
				storage = tonumber(def.buffs["Unit Storage"].amount) or 0
			end
			table.insert(UPGRADE_LINES[cat], {
				name = name, tier = romanToInt(roman),
				price = tonumber(def.price) or math.huge, storage = storage,
			})
		end
	end
	for _, list in pairs(UPGRADE_LINES) do
		table.sort(list, function(a, b) return a.tier < b.tier end)
	end
end

-- The lowest-tier upgrade in a category we do not yet own - IF it can be bought.
-- The pads are a tree (TreeStructure.GetParent) and BuyUpgrade silently refuses
-- a node whose parent is not owned. Health I hangs off Damage III, so the old
-- "cheapest next tier" picked Health I (1k) every tick, the server dropped it,
-- and not one other upgrade was bought for the whole session after that.
local function nextTier(cat)
	local owned = data().Upgrades
	for _, up in ipairs(UPGRADE_LINES[cat] or {}) do
		if not owned[up.name] then
			local parent = UpgradeTree and select(2, pcall(UpgradeTree.GetParent, up.name))
			if type(parent) == "string" and parent ~= "Start" and not owned[parent] then
				return nil                     -- locked behind another line
			end
			return up
		end
	end
	return nil
end

-- Across the enabled categories, the cheapest next tier we can pay for now.
-- Damage/Health lines only matter to the tower, so they join while it is farmed.
local TOWER_CATS = { "Damage", "Health" }

local function bestUpgrade(reserve)
	local d = data()
	local pick
	local spendable = d.Money - (reserve or 0)
	local cats = UPGRADE_CATS
	if CONFIG.autoTower then
		cats = {}
		for _, c in ipairs(UPGRADE_CATS) do cats[#cats + 1] = c end
		for _, c in ipairs(TOWER_CATS) do cats[#cats + 1] = c end
	end
	for _, cat in ipairs(cats) do
		local up = nextTier(cat)
		if up and spendable >= up.price then
			if not pick or up.price < pick.price then pick = up end
		end
	end
	return pick
end

-- Current backpack capacity. The server refuses a roll once the UNIT count
-- reaches the Unit Storage buff (+ Rolls - 1); items do not count. Fallback:
-- base 100 plus every owned Unit Storage tier's +5.
local function invCap()
	local buff = tonumber(select(2, pcall(BuffController.GetBuff, "Unit Storage")))
	if buff and buff > 0 then return buff end
	local cap = INV_CAP_BASE
	local owned = data().Upgrades
	for _, up in ipairs(UPGRADE_LINES["Unit Storage"] or {}) do
		if owned[up.name] then cap = cap + up.storage end
	end
	return cap
end

---------------------------------------------------------------- slot model -----

local function unlockedSlots()
	local rb, n = data().Rebirth, 0
	local maxS = 15
	pcall(function() maxS = PlotConfig.GetMaxSlots(rb) or 15 end)
	for i = 1, maxS do
		local req = 0
		pcall(function() req = PlotConfig.GetSlotRebirthRequirement(i) or 0 end)
		if req <= rb then n = n + 1 end
	end
	return n
end

local function nextRebirthCost()
	local d = data()
	local info
	pcall(function() info = Rebirths.Get(d.Rebirth + 1) end)
	if not info then pcall(function() info = Rebirths.GetNext(d.Rebirth) end) end
	return info and tonumber(info.cost), info and tonumber(info.moneyMultiplier)
end

--------------------------------------------------------------- unit safety -----

local function goodGrade(g)
	local def = g and Grades[g]
	return def and (tonumber(def.incomeMultiplier) or 0) >= CONFIG.gradeMin
end

local function goodTrait(t)
	local def = t and Traits[t]
	return def and (tonumber(def.incomeMultiplier) or 0) >= CONFIG.traitMin
end

-- The unit in the character's hand. The server does NOT protect it from
-- SellInventory, and InteractSlot with an empty hand puts a slot's unit there.
local function heldUnit()
	if not (UnitCtl and UnitCtl.EquippedUnit) then return nil end
	local ok, id = pcall(UnitCtl.EquippedUnit)
	return ok and id or nil
end

-- Units the automation never sells or fuses: locked in the game (the server
-- skips them too), limited (no roll chance, real trade value), carrying a grade
-- or trait that cost Gems / Trait Rerolls, or held in the hand. Three reports
-- ("my units got stolen") were spares like these going into Sell and Fuse.
local function isProtected(id, u)
	local a = u.attributes or {}
	if a.locked then return true end
	local e = UnitConfig.entries[u.name]
	if not e or e.limited then return true end
	if goodGrade(a.grade) or goodTrait(a.trait) then return true end
	return id == heldUnit()
end

-- Sell, fuse and placeBest each move units around and used to run in parallel:
-- a unit picked for a slot could be sold mid-swap. One owner at a time.
local unitOwner, unitSince = nil, 0
local function claimUnits(who)
	if unitOwner and unitOwner ~= who and os.clock() - unitSince < 20 then return false end
	unitOwner, unitSince = who, os.clock()
	return true
end
local function releaseUnits(who)
	if unitOwner == who then unitOwner = nil end
end

------------------------------------------------------------------- actions -----

-- Spins (SpinService, readable): Use(name) moves one Lucky Spin (x100) / Jackpot
-- Spin (x1000) into ActiveEntries, and the next RollDice multiplies its luck by it
-- and consumes it. The codes alone hand a new account ~20 Lucky Spins - luck 200
-- instead of 2 in the first minute. One is armed at a time, right before a roll.
local SPINS = { "Jackpot Spin", "Lucky Spin" }
local function armSpin()
	if not (CONFIG.autoSpins and R.UseSpin) then return end
	local d = data()
	for _, name in ipairs(SPINS) do
		local active = d.ActiveEntries and d.ActiveEntries[name]
		if active then return end                 -- one is already waiting
	end
	for _, name in ipairs(SPINS) do
		local item = d.Inventory[name]
		if item and (tonumber(item.amount) or 0) >= 1 then
			R.UseSpin:FireServer(name)
			STATE.note = "armed " .. name
			task.wait(0.25)
			return
		end
	end
end

local function doRoll()
	if not R.RollDice then return end
	pcall(armSpin)
	local ok = pcall(function() return R.RollDice:InvokeServer() end)
	if ok then STATE.rolled = STATE.rolled + 1 end
end

-- The server's own roll cooldown: the Roll Duration buff (2.5s base, -0.15s per
-- Roll Speed pad). A fixed interval rolls slower than allowed once those land.
local function rollInterval()
	local dur = tonumber(select(2, pcall(BuffController.GetBuff, "Roll Duration"))) or 2.5
	return math.max(0.3, dur + 0.05)
end

-- Placement by POTENTIAL. The game's EquipBest ranks by income WITH level, so a
-- level-30 Epic (131k base x 8.25) keeps its slot against a fresh level-1
-- Legendary with 2.5x its base - forever, since levels only go to placed units.
-- A level's payback grows 1.6x per level while its gain is linear, so every
-- placed unit ends at the same payback cap: the unit with the bigger base wins
-- there, and the few cheap levels to get it there cost seconds of income.
-- Swap = Equip(unit) into the hand, InteractSlot(slot) drops it in; the unit
-- that was there goes back to the inventory with its level intact.
local function placeBest()
	if not (R.EquipUnit and R.InteractSlot) then return false end
	if not claimUnits("place") then return false end
	local d = data()
	local n = unlockedSlots()

	local ranked = {}
	for id, u in pairs(d.Inventory) do
		if UnitConfig.entries[u.name] and (tonumber(u.amount) or 1) >= 1 then
			ranked[#ranked + 1] = { id = id, v = baseIncome(u) }
		end
	end
	table.sort(ranked, function(a, b) return a.v > b.v end)

	local want, bench = {}, {}
	for i = 1, math.min(n, #ranked) do want[ranked[i].id] = ranked[i].v end
	local placed = {}
	for i = 1, n do
		local s = d.Slots[tostring(i)]
		if s and s.unitId then placed[s.unitId] = true end
	end
	for i = 1, math.min(n, #ranked) do
		if not placed[ranked[i].id] then bench[#bench + 1] = ranked[i] end
	end
	if #bench == 0 then releaseUnits("place"); return false end

	-- Weakest slots first; an empty slot counts as 0.
	local slots = {}
	for i = 1, n do
		local s = d.Slots[tostring(i)]
		local u = s and s.unitId and d.Inventory[s.unitId]
		slots[#slots + 1] = { i = i, v = u and baseIncome(u) or 0, id = s and s.unitId }
	end
	table.sort(slots, function(a, b) return a.v < b.v end)

	local swapped = 0
	for k, cand in ipairs(bench) do
		local slot = slots[k]
		-- 10% margin so two near-equal units never swap back and forth.
		if slot and (slot.id == nil or not want[slot.id]) and cand.v > slot.v * 1.1 then
			-- Equip answers false on its 0.5s debounce or a vanished unit. With the
			-- hand empty, InteractSlot would pick the slot's unit UP instead - the
			-- plot empties and the unit sits unprotected in the hand. So only a
			-- confirmed equip may touch the slot.
			local ok, equipped = pcall(function() return R.EquipUnit:InvokeServer(cand.id) end)
			if ok and equipped == true then
				task.wait(0.55)                          -- PlotSlotInteraction 0.5s
				R.InteractSlot:FireServer(slot.i)
				task.wait(0.6)
				local now = d.Slots[tostring(slot.i)]
				if now and now.unitId == cand.id then
					swapped = swapped + 1
					local u = d.Inventory[cand.id]
					STATE.note = "placed " .. tostring(u and u.name)
				elseif R.UnequipUnit and heldUnit() then
					pcall(function() R.UnequipUnit:InvokeServer() end)
				end
			end
			task.wait(0.55)                              -- UnitAction debounce
		end
	end
	releaseUnits("place")
	STATE.swaps = (STATE.swaps or 0) + swapped
	return swapped > 0
end

-- Collect every slot explicitly, THEN place best. EquipBest only banks the slots
-- it actually re-places, so once the plot is optimally filled it collects nothing
-- - the explicit CollectBalance per slot is what keeps the money flowing.
local function doCollectPlace()
	local d = data()
	-- Count what the slots hold as they are banked. A Money delta read 0 here:
	-- levels and upgrades spend in the same seconds, and the panel then said
	-- "collected 0" while every slot was being emptied every 5s.
	local banked = 0
	if R.CollectBalance then
		for key, slot in pairs(d.Slots) do
			banked = banked + (tonumber(slot.balance) or 0)
			pcall(function() R.CollectBalance:FireServer(tonumber(key)) end)
		end
	end
	STATE.collected = STATE.collected + banked
	if CONFIG.smartPlace then
		pcall(placeBest)
	elseif R.EquipBest then
		R.EquipBest:FireServer()
	end
end

local function doDice(reserve)
	local pick = bestAffordableDice(reserve)
	if pick then
		local curLuck = ownedLuck()
		if pick.luck > curLuck then
			R.BuyDice:FireServer(pick.key)
			STATE.diceBought = STATE.diceBought + 1
			STATE.note = "bought " .. pick.key .. " dice"
			task.wait(0.2)
		end
	end
	-- Always keep the strongest owned die equipped.
	local _, bestName = ownedLuck()
	if bestName ~= "-" and data().Dice ~= bestName then
		R.EquipDice:FireServer(bestName)
	end
end

local function doUpgrade(reserve)
	if not R.BuyUpgrade then return end
	local owned = data().Upgrades
	-- "Start" (price 0) unlocks the roll area; buy it once.
	if UpgradeConfig.Start and not owned.Start then
		R.BuyUpgrade:FireServer("Start")
		task.wait(0.15)
	end
	local up = bestUpgrade(reserve)
	if up then
		R.BuyUpgrade:FireServer(up.name)
		STATE.upgradesBought = STATE.upgradesBought + 1
		STATE.note = "upgrade " .. up.name
		task.wait(0.15)
	end
end

-- Keep the backpack under its cap - a full bag silently blocks new rolls. Two
-- rules: always clear unplaced units below the rarity floor, and when the bag is
-- pressured, also sell the weakest surplus, keeping the best keepBest spares and
-- never a placed unit. Rolling higher rarities means junk is no longer only
-- Common/Uncommon, so surplus has to be ranked by income, not rarity alone.
-- A pull far above your luck (keepLuckX) is never surplus: it is the rare one.
local function sellJunk(force)
	if not R.SellInventory then return end
	if not claimUnits("sell") then return end
	local d = data()
	local cap = invCap()

	local placed = {}
	for _, slot in pairs(d.Slots) do if slot.unitId then placed[slot.unitId] = true end end
	for _, id in pairs(d.TowerTeam or {}) do placed[id] = true end
	local luckLine = CONFIG.keepLuckX > 0 and rollLuck() * CONFIG.keepLuckX or nil

	-- Every unplaced unit with its level-free income, weakest first.
	local units, owned = {}, 0
	for id, u in pairs(d.Inventory) do
		local e = UnitConfig.entries[u.name]
		if e then owned = owned + 1 end
		local chance = e and not e.limited
			and tonumber(select(2, pcall(e.chance, { mutation = u.attributes and u.attributes.mutation })))
		local lucky = luckLine and (chance or math.huge) >= luckLine
		if e and not placed[id] and not isProtected(id, u) and not lucky then
			units[#units + 1] = {
				id = id, inc = baseIncome(u), order = RARITY_SORT[e.rarity] or 0,
				mutated = u.attributes and u.attributes.mutation ~= nil,
			}
		end
	end
	table.sort(units, function(a, b) return a.inc < b.inc end)
	local pressured = force or owned >= cap - 3

	local sellable = math.max(0, #units - CONFIG.keepBest)   -- protect the best spares
	local list = {}
	for i, unit in ipairs(units) do
		-- A mutation outweighs rarity (Uncommon Diamond out-earns plain Epics),
		-- so the rarity floor only ever applies to unmutated units.
		local belowFloor = not unit.mutated and unit.order > 0 and unit.order < CONFIG.sellRarity
			and i <= sellable
		local surplus = pressured and i <= sellable
		if belowFloor or surplus then
			list[#list + 1] = unit.id
			if #list >= 300 then break end        -- keep the payload bounded
		end
	end
	if #list == 0 then
		releaseUnits("sell")
		-- Rolling stops on a full bag; say why instead of looking broken.
		if owned >= cap then STATE.note = "bag full of kept units - rolls blocked" end
		return
	end
	local ok, value, sold = pcall(function() return R.SellInventory:InvokeServer(list) end)
	releaseUnits("sell")
	if ok then
		STATE.sold = STATE.sold + (tonumber(sold) or #list)
		STATE.soldValue = STATE.soldValue + (tonumber(value) or 0)
		STATE.note = "sold " .. tostring(sold or #list) .. " units"
	end
end

------------------------------------------------------ rerolls, boosts, tower -----

local function itemAmount(key)
	local e = data().Inventory[key]
	return (e and tonumber(e.amount)) or 0
end

local function unitIncome(u) return baseIncome(u) end

-- The units that actually earn, strongest first: a reroll there pays the most.
local function placedUnits()
	local d = data()
	local list = {}
	for _, slot in pairs(d.Slots) do
		local u = slot.unitId and d.Inventory[slot.unitId]
		if u then list[#list + 1] = { id = slot.unitId, u = u, inc = unitIncome(u) } end
	end
	table.sort(list, function(a, b) return a.inc > b.inc end)
	return list
end

-- Protection is per grade/trait NAME and the server skips a protected one on a
-- reroll, so protecting every good tier turns "spam reroll" into "reroll until
-- it lands on something good, then stop". Only fires when a flag must change.
local function syncProtectionFlags()
	local d = data()
	for name, g in pairs(Grades) do
		if type(g) == "table" then
			local want = (tonumber(g.incomeMultiplier) or 0) >= CONFIG.gradeMin
			if R.GradeProtect and (d.ProtectedGrades[name] and true or false) ~= want then
				R.GradeProtect:FireServer(name, want)
			end
		end
	end
	for name, t in pairs(Traits) do
		if type(t) == "table" then
			local want = (tonumber(t.incomeMultiplier) or 0) >= CONFIG.traitMin
			if R.TraitProtect and (d.ProtectedTraits[name] and true or false) ~= want then
				R.TraitProtect:FireServer(name, want)
			end
		end
	end
end

-- Reroll grade and trait on the placed units until each lands on a kept tier.
-- Gems pay for grades (神 x50 at the top), Trait Rerolls for traits (Eternal x27).
local function doRerolls()
	syncProtectionFlags()
	local rolls = 0
	for _, p in ipairs(placedUnits()) do
		if rolls >= 8 then break end
		local attrs = p.u.attributes or {}
		if CONFIG.autoGrade and R.GradeRoll and not goodGrade(attrs.grade)
			and itemAmount("Gems") >= 1 then
			R.GradeRoll:FireServer(p.id)
			STATE.gradeRolls = STATE.gradeRolls + 1
			rolls = rolls + 1
			task.wait(0.25)
		end
		if CONFIG.autoTrait and R.TraitRoll and not goodTrait(attrs.trait)
			and itemAmount("Trait Reroll") >= 1 then
			R.TraitRoll:FireServer(p.id)
			STATE.traitRolls = STATE.traitRolls + 1
			rolls = rolls + 1
			task.wait(0.25)
		end
	end
end

-- Boosts are timed (2-5 min). Boosts of DIFFERENT categories multiply together,
-- so every owned Luck/Income boost is worth running; one of the same category is
-- never started while its twin is still ticking, that would waste it.
local boostUntil = {}
local function useBoosts()
	if not R.BoostUse then return end
	local d = data()
	for key, item in pairs(d.Inventory) do
		local def = type(key) == "string" and BOOSTS[key]
		if def and type(def) == "table" and def.buffs and (tonumber(item.amount) or 0) >= 1 then
			local b = def.buffs
			-- Roll Duration potions shorten the roll cooldown: more rolls, more pulls.
			if b.Luck or b["Money Multiplier"] or b["Roll Duration"] then
				local cat = def.category or key
				if (boostUntil[cat] or 0) < os.clock() then
					R.BoostUse:FireServer(key)
					boostUntil[cat] = os.clock() + (tonumber(def.duration) or 120) + 1
					STATE.boostsUsed = STATE.boostsUsed + 1
					STATE.note = "boost " .. key
					task.wait(0.3)
				end
			end
		end
	end
end

-- One tower run. The server simulates every floor and hands back the sequence the
-- client would animate; skipping that animation is the whole speed-up. Asking
-- before the server's per-floor clock (~1.5-2s) returns nil - that is "not yet",
-- the run is still alive, so we poll instead of cancelling like the client does.
--
-- Read from TowerService itself (it ships to the client): PlayTower refuses while
-- the player still has a run, and CancelTower does NOT end a run - it only queues
-- the ending, which the server carries out on the next CompleteTowerFloor. A run
-- that is cancelled and then left alone therefore blocks every new run forever.
-- Tower choice by simulation. TowerClass (server, ships to the client) is fully
-- deterministic except for the drop rolls: the team fights in order, a member
-- hits (damage), and if the enemy survives it hits back (enemyDamage); health
-- carries across floors and a fallen member hands the SAME enemy to the next.
-- A one-hit kill costs the member nothing. Member damage/health =
-- damage/health(attributes) x Damage/Health Multiplier - level and grade play no
-- part. Nothing is saved between runs and no tower is locked, so the only
-- question is which tower pays the most per second for THIS team. Drop tiers are
-- cumulative: from its minFloor on, every tier rolls on every floor.
local TOWER_WAIT = { initial = 0.76, transition = 0.38, hit = 0.62, done = 0.24, fall = 0.32 }

-- Rough worth of a drop in "luck-seconds": a boost is worth (mult - 1) x
-- duration, weighted by what that buff does for us. Luck decides rarity, so it
-- leads; gems and trait rerolls feed the income rerolls.
local DROP_WEIGHT = { Luck = 1, ["Money Multiplier"] = 0.5, ["Damage Multiplier"] = 0.15 }
local function dropValue(name)
	if name == "Gems" then return 40 end
	if name == "Trait Reroll" then return 25 end
	local def = BOOSTS[name]
	if type(def) ~= "table" or type(def.buffs) ~= "table" then return 0 end
	local v = 0
	for buff, b in pairs(def.buffs) do
		local w = DROP_WEIGHT[buff] or 0
		v = v + w * math.max(0, (tonumber(b.amount) or 1) - 1) * (tonumber(def.duration) or 0)
	end
	return v
end

local function towerTeam()
	local d = data()
	local dmgMul = tonumber(select(2, pcall(BuffController.GetBuff, "Damage Multiplier"))) or 1
	local hpMul = tonumber(select(2, pcall(BuffController.GetBuff, "Health Multiplier"))) or 1
	local team = {}
	for i = 1, 4 do
		local id = d.TowerTeam and d.TowerTeam[i]
		local u = id and d.Inventory[id]
		local e = u and UnitConfig.entries[u.name]
		if e then
			local a = u.attributes or {}
			team[#team + 1] = {
				dmg = (tonumber(select(2, pcall(e.damage, a))) or 0) * dmgMul,
				hp = (tonumber(select(2, pcall(e.health, a))) or 0) * hpMul,
			}
		end
	end
	return team
end

-- Returns floors cleared, seconds the server will make us wait, expected value.
local function simulateTower(tw, team)
	if #team == 0 then return 0, 0, 0 end
	local members = {}
	for i, m in ipairs(team) do members[i] = { dmg = m.dmg, hp = m.hp } end
	local cap = tw.maxFloors or 300          -- Infinity has none
	local floor, cur, secs, value = 1, 1, 0, 0
	while floor <= cap do
		local enemy = tonumber(select(2, pcall(tw.enemyHealth, floor))) or math.huge
		local hit = tonumber(select(2, pcall(tw.enemyDamage, floor))) or math.huge
		secs = secs + (floor == 1 and TOWER_WAIT.initial or TOWER_WAIT.transition)
		local cleared = false
		for _ = 1, 2000 do
			local m = members[cur]
			if not m then break end
			enemy = enemy - m.dmg
			secs = secs + TOWER_WAIT.hit
			if enemy <= 0 then cleared = true; break end
			m.hp = m.hp - hit
			secs = secs + TOWER_WAIT.hit
			if m.hp <= 0 then
				cur = cur + 1
				secs = secs + TOWER_WAIT.fall + TOWER_WAIT.transition
			end
		end
		if not cleared then break end
		secs = secs + TOWER_WAIT.done
		for _, tier in ipairs(tw.drops or {}) do
			if (tier.minFloor or 1) <= floor then
				for _, en in ipairs(tier.entries or {}) do
					value = value + (tonumber(en.chance) or 0) / 100
						* (tonumber(en.amount) or 1) * dropValue(en.name)
				end
			end
		end
		floor = floor + 1
	end
	return floor - 1, secs, value
end

-- The tower with the best expected value per second for the current team.
local function pickTower()
	local all = select(2, pcall(TowersConfig.GetAll))
	-- A saved tower the game no longer has falls back to the simulation.
	if CONFIG.tower ~= "Auto (best)" and type(all) == "table" and all[CONFIG.tower] then
		return CONFIG.tower
	end
	local team = towerTeam()
	local best, bestRate, bestFloors = nil, -1, 0
	if type(all) == "table" then
		for name, tw in pairs(all) do
			local floors, secs, value = simulateTower(tw, team)
			local rate = secs > 0 and value / (secs + 4) or 0     -- +4s run overhead
			if floors > 0 and rate > bestRate then
				best, bestRate, bestFloors = name, rate, floors
			end
		end
	end
	STATE.towerPick = best or "Dragon Tower"
	STATE.towerPredict = bestFloors
	STATE.towerRate = bestRate
	return STATE.towerPick
end

-- Damage boosts only help inside the tower, so they are fired at the start of a
-- run, one per category, never over a running one of the same category.
local function useTowerBoosts()
	if not (CONFIG.towerBoosts and R.BoostUse) then return end
	local d = data()
	for key, item in pairs(d.Inventory) do
		local def = type(key) == "string" and BOOSTS[key]
		if type(def) == "table" and type(def.buffs) == "table" and def.buffs["Damage Multiplier"]
			and (tonumber(item.amount) or 0) >= 1 then
			local cat = def.category or key
			if (boostUntil[cat] or 0) < os.clock() then
				R.BoostUse:FireServer(key)
				boostUntil[cat] = os.clock() + (tonumber(def.duration) or 120) + 1
				STATE.boostsUsed = STATE.boostsUsed + 1
				task.wait(0.3)
			end
		end
	end
end

local function drainTower()
	if not R.CancelTower then return end
	local okC, queued = pcall(function() return R.CancelTower:InvokeServer() end)
	if not (okC and queued) then return end          -- no run exists
	for _ = 1, 60 do
		local ok, seq = pcall(function() return R.CompleteFloor:InvokeServer() end)
		if ok and type(seq) == "table" then
			for _, ev in ipairs(seq) do
				if ev.action == "ended" then return end
			end
		end
		task.wait(0.3)
	end
end

local function towerRun()
	if not (R.PlayTower and R.CompleteFloor) then return end
	if R.BestTowerTeam then R.BestTowerTeam:FireServer(); task.wait(0.6) end
	-- Boosts first: the run snapshots Damage Multiplier at PlayTower, so the
	-- simulation must see the same multiplier or it undershoots (56 predicted vs
	-- ~100 reached before this order was fixed).
	useTowerBoosts()
	task.wait(0.4)
	local tower = pickTower()
	local ok, started = pcall(function() return R.PlayTower:InvokeServer(tower) end)
	if not (ok and started) then
		drainTower()                                  -- a stale run is in the way
		task.wait(3.2)                                -- PlayTower's 3s debounce
		ok, started = pcall(function() return R.PlayTower:InvokeServer(tower) end)
		if not (ok and started) then STATE.note = "tower refused"; return end
	end
	STATE.towerRuns = STATE.towerRuns + 1
	STATE.towerFloor = 0
	local misses, sawEnded = 0, false
	while _G.__ANIMEDICE == generation and CONFIG.auto and CONFIG.autoTower do
		local okF, seq = pcall(function() return R.CompleteFloor:InvokeServer() end)
		if not okF or seq == nil or (type(seq) == "table" and #seq == 0) then
			misses = misses + 1
			if misses > 50 then break end         -- ~15s with nothing: give up
			task.wait(0.3)
		else
			misses = 0
			local ended, done = false, false
			for _, ev in ipairs(seq) do
				if ev.action == "floorCompleted" then
					done = true
					STATE.towerFloor = tonumber(ev.floor) or (STATE.towerFloor + 1)
					if type(ev.rewards) == "table" then
						STATE.towerDrops = STATE.towerDrops + #ev.rewards
					end
				elseif ev.action == "ended" then
					ended = true
					-- the drops of the whole run arrive here, not per floor
					if type(ev.rewards) == "table" then
						STATE.towerDrops = STATE.towerDrops + #ev.rewards
					end
				end
			end
			if done then STATE.towerFloors = STATE.towerFloors + 1 end
			if STATE.towerFloor > STATE.towerBest then STATE.towerBest = STATE.towerFloor end
			if ended then sawEnded = true; break end   -- lost, or the run is over
			if not done then break end
			task.wait(0.2)
		end
	end
	-- Never leave a run hanging: it would block the next PlayTower.
	if not sawEnded then drainTower() end
	STATE.note = "tower ended at floor " .. tostring(STATE.towerFloor)
end

-- Fuse machine (FusingService, which ships to the client and decompiles):
-- Fuse(id1, id2, id3) sums the three units' 1-in-N chances (mutation included -
-- Diamond is x10000) and rolls a unit whose chance is that sum x a pool factor
-- averaging 0.667. So the result is on average TWICE as rare as the three
-- inputs' mean - rarity without luck, paid in money:
-- cost = S x 10000 x (S / 1e12)^0.2. The output is also the next fusion's fodder,
-- so fusing the spare pile greedily from the top climbs a ladder (three ~5.7M
-- -> ~11M+, the Legendary band). Inputs must be single, unlocked, non-limited.
-- The server lock is ONE flag for every player on the server, 3s long, so
-- "Please wait" just means retry.
local fuseResult
if R.FuseResult then
	local conn
	conn = R.FuseResult.OnClientEvent:Connect(function(unit, err, newId)
		if _G.__ANIMEDICE ~= generation then conn:Disconnect(); return end
		fuseResult = { unit = unit, err = err, newId = newId }
	end)
end

-- Trios the server refused for good ("No balanced fusion" once the sum outgrows
-- the rarest units, locked/limited units). Without this the top trio of a late
-- account is retried every pass and blocks every trio below it.
local badTrio = {}

-- Every Fuse call - a failing one included - sets FusingService.Fusing for 3s,
-- and RollDice returns nothing while it is set, for every player on the server.
-- Fusing every 4s therefore ate ~3/4 of the auto rolls ("auto roll didn't work").
local FUSE_GAP = 15
local fuseNext = 0

local function fuseOnce()
	local d = data()
	local busy = {}
	for _, slot in pairs(d.Slots) do if slot.unitId then busy[slot.unitId] = true end end
	for _, id in pairs(d.TowerTeam or {}) do busy[id] = true end
	-- Never fuse a unit that is good enough to be placed: the top (slots + 2) by
	-- level-free income stay out of the pile. The first build fused on chance
	-- alone and ate spares that should have been standing on the plot.
	do
		local ranked = {}
		for id, u in pairs(d.Inventory) do
			if UnitConfig.entries[u.name] then ranked[#ranked + 1] = { id = id, v = baseIncome(u) } end
		end
		table.sort(ranked, function(a, b) return a.v > b.v end)
		for i = 1, math.min(#ranked, unlockedSlots() + 2) do busy[ranked[i].id] = true end
	end

	local pile = {}
	for id, u in pairs(d.Inventory) do
		if not busy[id] and UnitConfig.entries[u.name] and not isProtected(id, u) then
			local ch = select(2, pcall(FusingUtil.GetChance, u))
			if type(ch) == "number" then pile[#pile + 1] = { id = id, ch = ch } end
		end
	end
	table.sort(pile, function(a, b) return a.ch > b.ch end)

	-- A share of the balance alone starves the rebirth: at 1e12 in the bank 35%
	-- was 350B per fusion, three fusions in 20s, and money fell while earning
	-- 8B/s. Capping by income-seconds keeps fusing proportional to what comes in.
	local budget = math.min(d.Money * math.clamp(CONFIG.fuseShare, 0, 1),
		math.max(STATE.incomePerSec, 0) * CONFIG.fuseSeconds)
	for i = 1, #pile - 2 do
		local a, b, c = pile[i], pile[i + 1], pile[i + 2]
		local sum = a.ch + b.ch + c.ch
		-- Only a balanced trio pays: the expected result must beat its best input,
		-- otherwise one strong unit gets diluted by two weak ones.
		local key = a.id .. b.id .. c.id
		-- The server's own "No balanced fusion" check, run here first: a refused
		-- attempt would still lock everybody's rolls for 3s.
		local okP, pools = pcall(FusingUtil.BuildPools, sum)
		if okP and not pools then badTrio[key] = true end
		if not badTrio[key] and sum * FusingConfig.AverageMultiplier >= a.ch then
			local cost = FusingConfig.GetCost(sum)
			if cost <= budget and cost <= d.Money then
				fuseResult = nil
				fuseNext = os.clock() + FUSE_GAP
				R.Fuse:FireServer(a.id, b.id, c.id)
				for _ = 1, 25 do
					if fuseResult then break end
					task.wait(0.2)
				end
				local r = fuseResult
				if r and r.unit then
					STATE.fused = STATE.fused + 1
					local ch = r.newId and d.Inventory[r.newId]
						and select(2, pcall(FusingUtil.GetChance, d.Inventory[r.newId]))
					if type(ch) == "number" and ch > STATE.fuseBestChance then STATE.fuseBestChance = ch end
					STATE.fuseLast = tostring(r.unit.name)
						.. (r.unit.attributes and r.unit.attributes.mutation
							and (" " .. r.unit.attributes.mutation) or "")
					STATE.note = "fused -> " .. STATE.fuseLast
					return true
				end
				local err = tostring(r and r.err or "no answer")
				STATE.note = "fuse: " .. err
				-- "Please wait" is the server-wide 3s lock and money errors fix
				-- themselves; anything else about THESE units is permanent.
				if r and r.err and not err:find("wait") and not err:find("money")
					and not err:find("trade") and not err:find("ready") then
					badTrio[key] = true
				end
				return false
			end
		end
	end
	return false
end

local function doFuse()
	if not R.Fuse or os.clock() < fuseNext then return false end
	if not claimUnits("fuse") then return false end
	local ok, did = pcall(fuseOnce)
	releaseUnits("fuse")
	return ok and did or false
end

local function doRebirth()
	local cost = nextRebirthCost()
	if not cost then return false end          -- max rebirth reached
	if data().Money >= cost * math.max(1, CONFIG.rebirthMult) then
		R.Rebirth:FireServer()
		STATE.rebirths = STATE.rebirths + 1
		STATE.note = "rebirth -> " .. tostring(data().Rebirth)
		task.wait(0.5)
		return true
	end
	return false
end

-- Level the weakest placed slot once. Cost grows and is server-checked, so an
-- unaffordable call simply no-ops. Returns true only if money actually dropped.
--
-- Price = income(mutation only) x 1.6^(level-1) (UnitUtil.GetLevelPrice), gain =
-- 0.25 x base x Money Multiplier per second. So payback grows 1.6x per level and
-- does not care which unit it is; at x23.6 money: lvl 10 12s, 15 2min, 20 21min,
-- 25 3.7h, 30 39h. The first build levelled to 26-31 and burned most of that.
-- Buy the shortest payback first and stop at the levelPayback cap.
local function levelPayback(u)
	if not (UnitUtil and UnitUtil.GetLevelPrice) then return math.huge end
	local price = tonumber(select(2, pcall(UnitUtil.GetLevelPrice, u.name, u.attributes or {})))
	local mult = tonumber(select(2, pcall(BuffController.GetBuff, "Money Multiplier"))) or 1
	local gain = 0.25 * baseIncome(u) * mult
	if not price or gain <= 0 then return math.huge end
	return price / gain
end

local function doLevel()
	local d = data()
	local lowestKey, lowestLvl
	for key, slot in pairs(d.Slots) do
		if slot.unitId and d.Inventory[slot.unitId] then
			local pb = levelPayback(d.Inventory[slot.unitId])
			if not lowestLvl or pb < lowestLvl then lowestLvl, lowestKey = pb, key end
		end
	end
	if not lowestKey or lowestLvl > CONFIG.levelPayback * 60 then return false end
	local before = d.Money
	R.LevelUpSlot:FireServer(tonumber(lowestKey))
	task.wait(0.12)
	if d.Money < before then
		STATE.leveled = STATE.leveled + 1
		return true
	end
	return false
end

-- The money the next LUCK step needs: the next stronger die, or the rebirth
-- threshold, whichever is cheaper. Luck is what unlocks rarer units (the roll
-- only picks units whose 1-in-N chance is at least your luck), so leveling must
-- not eat money that would buy the next luck step within a few minutes.
local function nextLuckGoal()
	local d = data()
	local curLuck = 0
	for _, die in ipairs(DICE) do
		if d.OwnedDice[die.key] and die.luck > curLuck then curLuck = die.luck end
	end
	local goal
	for _, die in ipairs(DICE) do
		if die.price and not d.OwnedDice[die.key] and die.luck > curLuck then
			if not goal or die.price < goal then goal = die.price end
		end
	end
	if CONFIG.autoRebirth then
		local cost = nextRebirthCost()
		if cost then
			local rb = cost * math.max(1, CONFIG.rebirthMult)
			if not goal or rb < goal then goal = rb end
		end
	end
	return goal
end

-- Pour a share of the current money into slot levels (the placed units' "Lvl x>y"
-- pads), weakest slot first so the cheapest levels go first. It protects a
-- fraction of money for dice/upgrades/rebirth, and stops the moment a level is
-- unaffordable. This is a real income lever: a leveled unit earns much more.
-- True while the next dice/rebirth is within saveMinutes of income: leveling and
-- fusing then hold back so the luck step is not pushed further away.
local function savingForLuck()
	local goal = nextLuckGoal()
	local money = data().Money
	return goal and money < goal and money + STATE.incomePerSec * CONFIG.saveMinutes * 60 >= goal
end

local function levelSlots()
	if savingForLuck() then
		STATE.phase = "saving for luck"
		return
	end
	local floor = data().Money * (1 - math.clamp(CONFIG.levelShare, 0, 1))
	for _ = 1, 15 do
		if data().Money <= floor then break end
		if not doLevel() then break end
	end
end

-- Codes live in Codes.CodesConfig since the 2026-10-11 update (the old
-- MonetizationConfig.Codes is gone) and RedeemCode has a 0.5s debounce.
local function doCodes()
	if not R.RedeemCode then return end
	local d = data()
	local did = 0
	for code in pairs(CODES) do
		if type(code) == "string" and not d.RedeemedCodes[code] then
			R.RedeemCode:FireServer(code)
			did = did + 1
			task.wait(0.6)
		end
	end
	if did > 0 then STATE.codesDone = STATE.codesDone + did end
end

-- Daily/weekly quests (Playtime, Rolls, Towers, UnitsSold) pay Tickets. The
-- server wants the period, the quest id and the period's expiresAt.
local function doQuests()
	if not (QuestConfig and QuestConfig.Periods and R.QuestClaim) then return end
	local d = data()
	for period, def in pairs(QuestConfig.Periods) do
		local q = d.Quests and d.Quests[period]
		if type(q) == "table" and type(q.progress) == "table" then
			for _, quest in ipairs(def.quests or {}) do
				local claimed = q.claimed and q.claimed[quest.id]
				if not claimed and (tonumber(q.progress[quest.id]) or 0) >= (tonumber(quest.target) or math.huge) then
					R.QuestClaim:FireServer(period, quest.id, q.expiresAt)
					STATE.questsClaimed = STATE.questsClaimed + 1
					STATE.note = "quest " .. period .. " " .. tostring(quest.id)
					task.wait(0.3)
				end
			end
		end
	end
end

-- The Ticket shop sells real gamepasses for Tickets alone (the server removes
-- Tickets and sets OwnedGamepasses - no Robux prompt anywhere on that path).
local function doPasses()
	if not (QuestConfig and QuestConfig.Shop and R.QuestBuy) then return end
	local d = data()
	local tickets = itemAmount("Tickets")
	local price = {}
	for _, item in ipairs(QuestConfig.Shop) do
		if item.gamepass then price[item.name] = tonumber(item.tickets) end
	end
	for _, name in ipairs(PASS_ORDER) do
		if price[name] and not (d.OwnedGamepasses and d.OwnedGamepasses[name]) then
			-- Best first: save up for it rather than buying something weaker.
			if tickets >= price[name] then
				R.QuestBuy:FireServer(name)
				STATE.passesBought = STATE.passesBought + 1
				STATE.note = "gamepass " .. name .. " for " .. price[name] .. " tickets"
			end
			return
		end
	end
end

-- One rebirth point per rebirth; each is x(1 + 0.1 x points) on one buff.
local function doStats()
	if not (RebirthStats and RebirthStats.Get and R.AddStat) then return end
	if not RebirthStats.Get(CONFIG.statPick) then return end
	local d = data()
	local left = tonumber(select(2, pcall(RebirthStats.GetRemaining, d.Rebirth, d.RebirthStats))) or 0
	for _ = 1, math.min(left, 30) do
		R.AddStat:FireServer(CONFIG.statPick)
		STATE.statsAdded = STATE.statsAdded + 1
		task.wait(0.15)                         -- AddRebirthStat debounce 0.1s
	end
end

local function doClaims()
	for _, ev in ipairs({ R.ClaimOffline, R.ClaimDaily, R.ClaimGroup }) do
		if ev then pcall(function() ev:FireServer() end) end
	end
	STATE.claims = STATE.claims + 1
end

-- The game's AutoSell is a 1-in-N chance, not a rarity: RollService sells a
-- freshly rolled unit whose chance is below it. "Sell below Rare" therefore
-- becomes the rarest-is-least chance of any Rare unit (~1.1k), so a mutated
-- Common worth more than that (Gold, Diamond...) is still kept, as in sellJunk.
local function autoSellThreshold()
	local floor
	for _, e in pairs(UnitConfig.entries) do
		if type(e) == "table" and not e.limited and RARITY_SORT[e.rarity] == CONFIG.sellRarity then
			local ch = tonumber(select(2, pcall(e.chance, {})))
			if ch and (not floor or ch < floor) then floor = ch end
		end
	end
	return floor and math.floor(floor) or 0
end

local function applyAutoSell()
	if not R.UpdateAutoSell then return end
	R.UpdateAutoSell:FireServer(CONFIG.autoSell and autoSellThreshold() or 0)
end

-- Debug/console handle: drive any single action or read state without clicking.
_G.__ANIMEDICE_DBG = {
	CONFIG = CONFIG, STATE = STATE, data = data,
	doRoll = doRoll, doCollectPlace = doCollectPlace, doDice = doDice,
	doUpgrade = doUpgrade, sellJunk = sellJunk, levelSlots = levelSlots,
	doRerolls = doRerolls, useBoosts = useBoosts, towerRun = towerRun, drainTower = drainTower,
	doFuse = doFuse, savingForLuck = savingForLuck, placeBest = placeBest,
	pickTower = pickTower, simulateTower = simulateTower, towerTeam = towerTeam,
	baseIncome = baseIncome, curIncome = curIncome, levelPayback = levelPayback,
	nextLuckGoal = nextLuckGoal, placedUnits = placedUnits,
	doRebirth = doRebirth, doLevel = doLevel, doCodes = doCodes,
	doClaims = doClaims, DICE = DICE, UPGRADE_LINES = UPGRADE_LINES,
	invCap = invCap, bestUpgrade = bestUpgrade,
	doQuests = doQuests, doPasses = doPasses, doStats = doStats,
	isProtected = isProtected, heldUnit = heldUnit, rollLuck = rollLuck,
	autoSellThreshold = autoSellThreshold, applyAutoSell = applyAutoSell,
}

--------------------------------------------------------------------- panel -----

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
UI.config("animedice", CONFIG)

local win = UI.Window({
	name = "AnimeDice",
	title = "ANIME",
	accentTitle = "DICE",
	subtitle = "seltonmt",
	badge = "◈",
})
_G.__ANIMEDICE_GUI = win.gui

local function toggle(card, text, key, hint, tone, onChange)
	return card:Toggle(text, CONFIG[key], function(value)
		CONFIG[key] = value
		if onChange then onChange(value) end
	end, hint, tone)
end

-- AUTO ------------------------------------------------------------------------
local autoPage = win:Page("AUTO", UI.icon.bolt)

local rollCard = autoPage:Card("ROLLING", 1):Accent()
toggle(rollCard, "Auto Roll", "autoRoll", "rolls exactly on the server cooldown")
toggle(rollCard, "Use Lucky Spins", "autoSpins", "x100 / x1000 luck on the next roll")
rollCard:Button("Roll once", function() doRoll() end)

local incomeCard = autoPage:Card("INCOME", 1)
toggle(incomeCard, "Auto Collect & Place", "autoCollect",
	"EquipBest: banks every slot + places the best units")
toggle(incomeCard, "Auto Level Slots", "autoLevel",
	"levels the placed units - a big income boost")
toggle(incomeCard, "Smart Placement", "smartPlace",
	"places by base income, so a fresh Legendary beats a levelled Epic")
incomeCard:Stepper("Level payback max",
	function() return tostring(CONFIG.levelPayback) .. " min" end,
	function(delta) CONFIG.levelPayback = math.clamp(CONFIG.levelPayback + delta, 1, 120) end,
	"a level costs 1.6x more each time; stop once it pays back slower")
incomeCard:Slider("Level budget %", 10, 90, math.floor(CONFIG.levelShare * 100),
	function(v) CONFIG.levelShare = v / 100 end,
	"share of money slot-leveling may spend each pass")
incomeCard:Button("Collect + place now", function() doCollectPlace() end)
incomeCard:Button("Level slots now", function() task.spawn(levelSlots) end)

local ladderOut = autoPage:Card("LADDER", 2):Readout(9)
local sessionOut = autoPage:Card("THIS SESSION", 2):Readout(8)

-- UPGRADES --------------------------------------------------------------------
local upPage = win:Page("UPGRADES", UI.icon.star)

local diceCard = upPage:Card("DICE", 1):Accent()
toggle(diceCard, "Auto Dice", "autoDice",
	"buys the best dice you can afford, equips the best owned")
local diceLabel = diceCard:Label("dice -")
diceCard:Button("Buy best dice now", function() doDice() end)

local rbCard = upPage:Card("REBIRTH", 1)
toggle(rbCard, "Auto Rebirth", "autoRebirth",
	"sets money to 0 for a permanent x money and luck; keeps units, dice, slots", UI.theme.warn)
rbCard:Stepper("Bank x cost",
	function() return tostring(CONFIG.rebirthMult) .. "x" end,
	function(delta) CONFIG.rebirthMult = math.clamp(CONFIG.rebirthMult + delta, 1, 20) end,
	"how many next-rebirth-costs to save before rebirthing")
rbCard:Button("Rebirth now", function()
	local prev = CONFIG.rebirthMult; CONFIG.rebirthMult = 1
	doRebirth(); CONFIG.rebirthMult = prev
end)
toggle(rbCard, "Auto Rebirth Points", "autoStats",
	"one point per rebirth, each x1.1 on the stat below")
rbCard:Dropdown("Points into", { "Money", "Luck", "Damage", "Health", "Trait Luck", "Grade Luck" },
	CONFIG.statPick, function(choice) CONFIG.statPick = choice end)

local upCard = upPage:Card("PAD UPGRADES", 2):Accent()
toggle(upCard, "Auto Upgrade", "autoUpgrade",
	"money, luck, roll speed, storage - cheapest tier first")
local upLabel = upCard:Label("next -")
upCard:Button("Buy upgrade now", function() task.spawn(doUpgrade) end)

local sellCard = upPage:Card("BACKPACK", 2)
toggle(sellCard, "Auto Sell junk", "autoSell",
	"sells unplaced units below the rarity floor to free space", UI.theme.warn,
	function(v) applyAutoSell() end)
sellCard:Stepper("Sell below",
	function() return RARITY_ORDER[math.clamp(CONFIG.sellRarity, 1, #RARITY_ORDER)] or tostring(CONFIG.sellRarity) end,
	function(delta)
		CONFIG.sellRarity = math.clamp(CONFIG.sellRarity + delta, 1, #RARITY_ORDER)
		applyAutoSell()
	end,
	"units below this rarity are sold when the bag fills")
sellCard:Stepper("Keep best spares",
	function() return tostring(CONFIG.keepBest) end,
	function(delta) CONFIG.keepBest = math.clamp(CONFIG.keepBest + delta, 0, 100) end,
	"when full, keep this many best spares and sell the rest")
sellCard:Stepper("Keep rare pulls",
	function() return CONFIG.keepLuckX > 0 and UI.tf("from %sx luck", CONFIG.keepLuckX) or UI.t("off") end,
	function(delta) CONFIG.keepLuckX = math.clamp(CONFIG.keepLuckX + delta * 5, 0, 1000) end,
	"a unit far rarer than your luck is never sold")
sellCard:Label("units locked in the game are never sold or fused")
local bagLabel = sellCard:Label("bag -")
sellCard:Button("Sell junk now", function() task.spawn(function() sellJunk(true) end) end)

-- BOOST -----------------------------------------------------------------------
local GRADE_STEPS = { 1.25, 1.75, 3, 4.5, 7, 10, 15, 25, 50 }
local GRADE_NAMES = { [1.25]="C", [1.75]="B", [3]="A", [4.5]="A+", [7]="S", [10]="S+",
	[15]="Z", [25]="Z+", [50]="神" }
local TRAIT_STEPS = { 1.2, 1.5, 2, 3, 5, 8, 15, 27 }
local function stepIn(list, value, delta)
	local idx = 1
	for i, v in ipairs(list) do if v <= value then idx = i end end
	return list[math.clamp(idx + delta, 1, #list)]
end

local boostPage = win:Page("BOOST", UI.icon.spark)

local rrCard = boostPage:Card("REROLLS", 1):Accent()
toggle(rrCard, "Auto Grade Reroll", "autoGrade",
	"spends Gems on the placed units until they hit the kept grade")
rrCard:Stepper("Keep grade from",
	function() return (GRADE_NAMES[CONFIG.gradeMin] or "?") .. "  x" .. tostring(CONFIG.gradeMin) end,
	function(delta) CONFIG.gradeMin = stepIn(GRADE_STEPS, CONFIG.gradeMin, delta) end,
	"A 12% / A+ 4% / S 1% per roll - higher costs far more Gems")
toggle(rrCard, "Auto Trait Reroll", "autoTrait",
	"spends Trait Rerolls until the trait is worth keeping")
rrCard:Stepper("Keep trait from",
	function() return "x" .. tostring(CONFIG.traitMin) end,
	function(delta) CONFIG.traitMin = stepIn(TRAIT_STEPS, CONFIG.traitMin, delta) end,
	"x1.5+ 8% / x2+ 2% / x3+ 0.7% per roll")
local rrLabel = rrCard:Label("gems -")
rrCard:Button("Reroll now", function() task.spawn(doRerolls) end)

local towerCard = boostPage:Card("TOWER", 2):Accent()
toggle(towerCard, "Auto Tower", "autoTower",
	"skips the fight animation; drops boosts, gems, trait rerolls")
-- Read from the game: a hardcoded list missed Shadow Tower when it shipped.
local TOWER_CHOICES = { "Auto (best)" }
do
	local names = {}
	local ok, all = pcall(TowersConfig.GetAll)
	if ok and type(all) == "table" then for name in pairs(all) do names[#names + 1] = name end end
	table.sort(names)
	for _, name in ipairs(names) do TOWER_CHOICES[#TOWER_CHOICES + 1] = name end
end
towerCard:Dropdown("Tower", TOWER_CHOICES, CONFIG.tower,
	function(choice) CONFIG.tower = choice end)
toggle(towerCard, "Damage boosts on start", "towerBoosts",
	"fires owned Damage boosts right before each run")
local towerPickLabel = towerCard:Label("pick -")
local towerLabel = towerCard:Label("tower -")
towerCard:Button("Run tower now", function() task.spawn(towerRun) end)

local fuseCard = boostPage:Card("FUSE MACHINE", 1)
toggle(fuseCard, "Auto Fuse", "autoFusion",
	"uses up 3 spares per fusion, and each one stops all rolls on the server for 3s",
	UI.theme.warn)
fuseCard:Slider("Fuse budget %", 5, 90, math.floor(CONFIG.fuseShare * 100),
	function(v) CONFIG.fuseShare = v / 100 end,
	"share of money one fusion may cost (and at most 30s of income)")
local fuseLabel = fuseCard:Label("fused -")
fuseCard:Button("Fuse now", function() task.spawn(doFuse) end)

local boostCard = boostPage:Card("BOOSTS", 2)
toggle(boostCard, "Auto Use Boosts", "autoBoost",
	"luck, income and roll speed boosts; different kinds multiply")
local luckLabel = boostCard:Label("luck -")

-- REWARDS ---------------------------------------------------------------------
local rewPage = win:Page("REWARDS", UI.icon.bag)

local codeCard = rewPage:Card("CODES", 1):Accent()
toggle(codeCard, "Auto Redeem Codes", "autoCodes", "every code, once")
codeCard:Button("Redeem all now", function() task.spawn(doCodes) end)

local claimCard = rewPage:Card("CLAIMS", 1)
toggle(claimCard, "Auto Claim Rewards", "autoClaim", "offline / daily / group")
claimCard:Button("Claim now", function() doClaims() end)

local questCard = rewPage:Card("QUESTS", 2):Accent()
toggle(questCard, "Auto Claim Quests", "autoQuests", "daily and weekly quests pay Tickets")
toggle(questCard, "Gamepasses for Tickets", "autoPasses",
	"More Cash, Luck, Roll Speed... bought with Tickets, never Robux")
local questLabel = questCard:Label("tickets -")
questCard:Button("Claim quests now", function() task.spawn(function() doQuests(); doPasses() end) end)

-- STATUS ----------------------------------------------------------------------
local statPage = win:Page("STATUS", UI.icon.chart)
local playerOut = statPage:Card("PLAYER", 1):Readout(9)
local diceInfoOut = statPage:Card("DICE", 2):Readout(11)

pcall(function() win:Home() end)
pcall(function() win:Settings() end)

win:SetMaster(CONFIG.auto, "Auto Play", "roll, collect, upgrade, rebirth")
win:OnMaster(function(on) CONFIG.auto = on end)
win:Refresh()

-- On start, push the auto-sell setting to match the saved config.
applyAutoSell()

--------------------------------------------------------------------- loops -----

-- Roll runs on its own clock so the cooldown paces it regardless of the economy.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto and CONFIG.autoRoll then pcall(doRoll) end
		task.wait(rollInterval())
	end
end)

-- Collect + place. Cheap and safe to run often; it is the money engine.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto and CONFIG.autoCollect then pcall(doCollectPlace) end
		task.wait(5)
	end
end)

-- Keep the backpack under its cap so rolls never silently stall on a full bag.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto and CONFIG.autoSell then pcall(sellJunk) end
		task.wait(4)
	end
end)

-- Grade/trait rerolls on the earning units, paid in Gems / Trait Rerolls.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto and (CONFIG.autoGrade or CONFIG.autoTrait) then pcall(doRerolls) end
		task.wait(3)
	end
end)

-- Fuse machine: one balanced trio per pass, off while saving for a luck step.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto and CONFIG.autoFusion and not savingForLuck() then pcall(doFuse) end
		task.wait(4)
	end
end)

-- Owned Luck/Income boosts, each category kept running.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto and CONFIG.autoBoost then pcall(useBoosts) end
		task.wait(10)
	end
end)

-- Tower farming: runs back to back; its drops feed the two loops above.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto and CONFIG.autoTower then
			pcall(towerRun)
			task.wait(3)
		else
			task.wait(2)
		end
	end
end)

-- The economy tick decides how to SPEND, in one place so the money reads stay
-- coherent: dice first (permanent luck), then rebirth (permanent x mult + slot),
-- then leftover into slot levels.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto then
			STATE.phase = "spending"
			-- Dice (permanent luck) and one upgrade tier (money/luck/roll speed/
			-- storage) each pass, then rebirth (permanent x mult + slot).
			-- The rebirth is the one purchase that wipes the balance, so it gets
			-- the money first. Once it is affordable, only the EXCESS it would wipe
			-- is spent on dice/upgrades, then it fires. Before that, a dice priced
			-- at or above the rebirth must wait, otherwise it takes the money the
			-- moment both are affordable (Solar 5e12 beat rebirth 5 that way) and
			-- the rebirth - x4/3 on every later second of income - slips again.
			local cost = CONFIG.autoRebirth and nextRebirthCost() or nil
			local need = cost and cost * math.max(1, CONFIG.rebirthMult) or nil
			if need and data().Money >= need then
				if CONFIG.autoDice then pcall(doDice, need) end
				if CONFIG.autoUpgrade then pcall(doUpgrade, need) end
				pcall(doRebirth)
			else
				local diceReserve, upReserve = 0, 0
				if need then
					local nextDice
					for _, die in ipairs(DICE) do
						if die.price and not data().OwnedDice[die.key] and die.luck > ownedLuck() then
							if not nextDice or die.price < nextDice then nextDice = die.price end
						end
					end
					if nextDice and nextDice >= need then diceReserve = need end
				end
				if savingForLuck() then upReserve = nextLuckGoal() or 0 end
				if CONFIG.autoDice then pcall(doDice, diceReserve) end
				if CONFIG.autoUpgrade then pcall(doUpgrade, upReserve) end
			end
			-- Leveling comes last so dice/upgrades/rebirth get first claim on the
			-- money; it then pours its share of whatever is left into the slots.
			if CONFIG.autoLevel then pcall(levelSlots) end
		else
			STATE.phase = "idle"
		end
		task.wait(3)
	end
end)

-- Codes once, then claims, quests, ticket gamepasses and rebirth points.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto and CONFIG.autoCodes then pcall(doCodes) end
		if CONFIG.auto and CONFIG.autoClaim then pcall(doClaims) end
		if CONFIG.auto and CONFIG.autoQuests then pcall(doQuests) end
		if CONFIG.auto and CONFIG.autoPasses then pcall(doPasses) end
		if CONFIG.auto and CONFIG.autoStats then pcall(doStats) end
		task.wait(30)
	end
end)

-- Snapshot for the UI + an income/s estimate from positive slot-balance deltas.
task.spawn(function()
	local lastSum, lastT = nil, os.clock()
	while _G.__ANIMEDICE == generation do
		local d = data()
		STATE.money = d.Money
		STATE.rolls = d.Rolls
		STATE.rebirth = d.Rebirth
		STATE.dice = d.Dice or "-"
		-- Filled slots and owned UNITS - the old counts took empty slot entries and
		-- every item (Gems, boosts, spins) and read as a full plot / full bag.
		local filled, units = 0, 0
		for _, slot in pairs(d.Slots) do if slot.unitId then filled = filled + 1 end end
		for _, u in pairs(d.Inventory) do if UnitConfig.entries[u.name] then units = units + 1 end end
		STATE.slotsUsed = filled
		STATE.slotsMax = unlockedSlots()
		local _, bestName = ownedLuck()
		local pick = bestAffordableDice()
		STATE.nextDice = pick and pick.key or ("best: " .. bestName)
		STATE.invCount = units
		STATE.invCap = invCap()
		local up = bestUpgrade()
		STATE.nextUpgrade = up and (up.name .. " " .. fmt(up.price)) or "-"
		STATE.luck = rollLuck()

		local sum = 0
		for _, slot in pairs(d.Slots) do sum = sum + (slot.balance or 0) end
		local now = os.clock()
		if lastSum and now > lastT then
			local delta = sum - lastSum
			if delta > 0 then STATE.incomePerSec = delta / (now - lastT) end
		end
		lastSum, lastT = sum, now

		task.wait(2)
	end
end)

-- UI refresh.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		win:SetStatus(string.format("%s money   %s/s   rb %d   %d/%d slots   %s",
			fmt(STATE.money), fmt(STATE.incomePerSec), STATE.rebirth,
			STATE.slotsUsed, STATE.slotsMax, STATE.phase))
		win:SetStat(1, fmt(STATE.money), "money")
		win:SetStat(2, fmt(STATE.incomePerSec), "per sec")
		win:SetStat(3, tostring(STATE.rebirth), "rebirth")

		diceLabel:set(string.format("%s  ->  %s", STATE.dice, STATE.nextDice))
		upLabel:set("next: " .. STATE.nextUpgrade)
		bagLabel:set(string.format("bag: %d / %d", STATE.invCount, STATE.invCap))
		rrLabel:set(string.format("gems %d   trait rerolls %d   rolls %d/%d",
			itemAmount("Gems"), itemAmount("Trait Reroll"), STATE.gradeRolls, STATE.traitRolls))
		towerPickLabel:set(string.format("%s   predicted floor %d",
			STATE.towerPick, STATE.towerPredict))
		towerLabel:set(string.format("floor %d   best %d   runs %d   drops %d",
			STATE.towerFloor, STATE.towerBest, STATE.towerRuns, STATE.towerDrops))
		luckLabel:set(string.format("roll luck %s   boosts used %d", fmt(STATE.luck), STATE.boostsUsed))
		fuseLabel:set(string.format("fused %d   best 1 in %s   last %s",
			STATE.fused, fmt(STATE.fuseBestChance), STATE.fuseLast))
		questLabel:set(string.format("tickets %d   quests %d   passes %d   points %d",
			itemAmount("Tickets"), STATE.questsClaimed, STATE.passesBought, STATE.statsAdded))

		local cost, mult = nextRebirthCost()
		ladderOut:set({
			"PROGRESS",
			string.format("  money     %s", fmt(STATE.money)),
			string.format("  income    %s/s", fmt(STATE.incomePerSec)),
			string.format("  luck      %s  (%s die)", fmt(STATE.luck), STATE.dice),
			string.format("  rebirth   %d", STATE.rebirth),
			string.format("  slots     %d / %d", STATE.slotsUsed, STATE.slotsMax),
			string.format("  bag       %d / %d", STATE.invCount, STATE.invCap),
			string.format("  next rb   %s (x%s)",
				cost and fmt(cost) or "max", mult and tostring(mult) or "-"),
			"NOTE  " .. tostring(STATE.note),
		})

		sessionOut:set({
			"SESSION",
			string.format("  rolled %s   collected %s", fmt(STATE.rolled), fmt(STATE.collected)),
			string.format("  dice buys  %d", STATE.diceBought),
			string.format("  upgrades   %d", STATE.upgradesBought),
			string.format("  rebirths   %d", STATE.rebirths),
			string.format("  levels %d   swaps %d", STATE.leveled, STATE.swaps or 0),
			string.format("  sold       %d (%s)", STATE.sold, fmt(STATE.soldValue)),
			string.format("  codes %d   claims %d", STATE.codesDone, STATE.claims),
		})

		playerOut:set({
			"PLAYER",
			string.format("  money    %s", fmt(STATE.money)),
			string.format("  income   %s/s", fmt(STATE.incomePerSec)),
			string.format("  rolls    %s", fmt(STATE.rolls)),
			string.format("  rebirth  %d", STATE.rebirth),
			string.format("  dice     %s", STATE.dice),
			string.format("  slots    %d / %d", STATE.slotsUsed, STATE.slotsMax),
			string.format("  bag      %d / %d", STATE.invCount, STATE.invCap),
			"  ui lock: " .. tostring(STATE.uiOwner),
		})

		local d = data()
		local diceLines = { "OWNED DICE" }
		for _, die in ipairs(DICE) do
			if d.OwnedDice[die.key] then
				local mark = (d.Dice == die.key) and " *" or ""
				diceLines[#diceLines + 1] =
					string.format("  %-9s luck %s%s", die.key, fmt(die.luck), mark)
			end
		end
		diceInfoOut:set(diceLines)

		task.wait(1)
	end
end)

STATE.note = "loaded - flip the master switch to start"
