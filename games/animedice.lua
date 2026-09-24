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
--   * Level  LevelUpSlot:FireServer(slotNumber) +1 level on that slot's unit,
--            costs money on a ~1.6x/level curve (93,148,238,380,609,975,...).
--            Unit level does NOT change base income (income = f(rarity, mutation,
--            trait, grade, variant)); the slot level multiplier is applied server
--            side - lvl1 Huge Friza ~93/s, lvl8 ~256/s measured.
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
-- Deliberately left out, do not add without new evidence:
--   Fusing   pools return 0.375-1.125x of the input, 0.667x on average.
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
	autoCollect = true,   -- EquipBest: collect every slot + place the best units
	autoLevel   = true,   -- pour a share of money into placed-slot levels
	levelShare  = 0.3,    -- fraction of money slot-leveling may spend each pass
	saveMinutes = 5,      -- skip leveling while the next dice/rebirth is this close
	-- Grade/trait odds come from the configs' weights. Grades: D 45%, C 28%, B 15%,
	-- A 8%, A+ 3%, S 0.9%, S+ 0.11%, Z 0.03%, 神 0.002%. Waiting for S costs ~100
	-- Gems per unit on average; "A or better" (12%) costs ~8, so that is the default.
	-- Traits: ~66% are Damage/Health (no income at all); Money II+ (x1.5) is 8.4%.
	autoGrade   = true,   -- spend Gems rerolling the placed units' grades
	gradeMin    = 3,      -- keep grades worth >= this income x (A and better)
	autoTrait   = true,   -- spend Trait Rerolls on the placed units' traits
	traitMin    = 1.5,    -- keep traits worth >= this income x (Money II and better)
	autoBoost   = true,   -- activate owned Luck/Income boosts
	autoTower   = true,   -- farm a tower for boosts, gems and trait rerolls
	tower       = "Dragon Tower",
	autoDice    = true,   -- buy the best affordable dice we do not own, equip best
	autoUpgrade = true,   -- buy the cheapest affordable world-pad upgrade tier
	autoRebirth = true,   -- rebirth once money reaches nextCost x factor
	rebirthMult = 1,      -- rebirth wipes ALL money and nothing else, so rebirthing
	                      -- the moment the cost is met throws away the least
	autoSell    = true,   -- keep the backpack under its cap by selling junk
	sellRarity  = 3,      -- rarity sortOrder floor (3 = always sell below Rare)
	keepBest    = 20,     -- when the bag fills, keep this many best spares, sell rest
	autoCodes   = true,   -- redeem every code once
	autoClaim   = true,   -- claim offline / daily / group rewards
}

-- Which world-pad upgrade lines auto-buy. Damage/Health are tower-only and
-- Walkspeed is irrelevant to an idle build, so they are left out on purpose.
local UPGRADE_CATS = { "Money", "Luck", "Fortune", "Roll Speed", "Unit Storage", "Sell" }
local INV_CAP_BASE = 100   -- Unit Storage buff default; each owned tier adds +5

local RARITY_ORDER = {
	"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythical",
	"Divine", "Exotic", "Celestial", "Secret I / II", "Heavenly",
}

local STATE = {
	money = 0, rolls = 0, rebirth = 0, dice = "-", nextDice = "-",
	slotsUsed = 0, slotsMax = 4, incomePerSec = 0,
	invCount = 0, invCap = INV_CAP_BASE, nextUpgrade = "-",
	rolled = 0, collected = 0, diceBought = 0, rebirths = 0, leveled = 0,
	upgradesBought = 0, sold = 0, soldValue = 0,
	gradeRolls = 0, traitRolls = 0, boostsUsed = 0, luck = 0,
	towerRuns = 0, towerFloors = 0, towerBest = 0, towerFloor = 0, towerDrops = 0,
	codesDone = 0, claims = 0,
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
	RedeemCode      = svc("MonetizationService.RE.RedeemCode"),
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
}

local DataController = require(Framework.Features.Data.DataController)
local Dice           = require(Framework.Features.Rolling.Dice)
local Rebirths       = require(Framework.Features.Rebirth.Rebirths)
local PlotConfig     = require(Framework.Features.Plot.PlotConfig)
local MonetConfig    = require(Framework.Features.Monetization.MonetizationConfig)
local UpgradeConfig  = require(Framework.Features.Upgrades.Upgrades)
local UnitConfig     = require(Framework.Features.Inventory.Kinds.Unit.UnitConfig)
local Grades         = require(Framework.Features.Grades.Grades)
local Traits         = require(Framework.Features.Traits.Traits)
local TowersConfig   = require(Framework.Features.Towers.Towers)
local BuffController = require(Framework.Features.Buffs.BuffController)
local BoostConfig
pcall(function() BoostConfig = require(Framework.Features.Inventory.Kinds.Boost.BoostConfig) end)
local BOOSTS = (BoostConfig and (BoostConfig.entries or BoostConfig)) or {}

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

-- The single strongest die we can pay for right now and do not already own.
local function bestAffordableDice()
	local d = data()
	local pick
	for _, die in ipairs(DICE) do
		if die.price and not d.OwnedDice[die.key] and d.Money >= die.price then
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

-- The lowest-tier upgrade in a category we do not yet own.
local function nextTier(cat)
	local owned = data().Upgrades
	for _, up in ipairs(UPGRADE_LINES[cat] or {}) do
		if not owned[up.name] then return up end
	end
	return nil
end

-- Across the enabled categories, the cheapest next tier we can pay for now.
local function bestUpgrade()
	local d = data()
	local pick
	for _, cat in ipairs(UPGRADE_CATS) do
		local up = nextTier(cat)
		if up and d.Money >= up.price then
			if not pick or up.price < pick.price then pick = up end
		end
	end
	return pick
end

-- Current backpack capacity: base 100 plus every owned Unit Storage tier's +5.
local function invCap()
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

------------------------------------------------------------------- actions -----

local function doRoll()
	if not R.RollDice then return end
	local ok = pcall(function() return R.RollDice:InvokeServer() end)
	if ok then STATE.rolled = STATE.rolled + 1 end
end

-- Collect every slot explicitly, THEN place best. EquipBest only banks the slots
-- it actually re-places, so once the plot is optimally filled it collects nothing
-- - the explicit CollectBalance per slot is what keeps the money flowing.
local function doCollectPlace()
	local d = data()
	local before = d.Money
	if R.CollectBalance then
		for key in pairs(d.Slots) do
			pcall(function() R.CollectBalance:FireServer(tonumber(key)) end)
		end
	end
	if R.EquipBest then R.EquipBest:FireServer() end
	task.wait(0.25)
	local gained = data().Money - before
	if gained > 0 then STATE.collected = STATE.collected + gained end
end

local function doDice()
	local pick = bestAffordableDice()
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

local function doUpgrade()
	if not R.BuyUpgrade then return end
	local owned = data().Upgrades
	-- "Start" (price 0) unlocks the roll area; buy it once.
	if UpgradeConfig.Start and not owned.Start then
		R.BuyUpgrade:FireServer("Start")
		task.wait(0.15)
	end
	local up = bestUpgrade()
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
local function sellJunk(force)
	if not R.SellInventory then return end
	local d = data()
	local cap = invCap()
	local n = count(d.Inventory)
	local pressured = force or n >= cap - 3

	local placed = {}
	for _, slot in pairs(d.Slots) do if slot.unitId then placed[slot.unitId] = true end end

	-- Every unplaced unit with its income, weakest first.
	local units = {}
	for id, u in pairs(d.Inventory) do
		if not placed[id] then
			local e = UnitConfig.entries[u.name]
			local inc = 0
			if e then inc = tonumber(select(2, pcall(e.income, u))) or 0 end
			local order = e and RARITY_SORT[e.rarity] or 0
			units[#units + 1] = { id = id, inc = inc, order = order }
		end
	end
	table.sort(units, function(a, b) return a.inc < b.inc end)

	local sellable = math.max(0, #units - CONFIG.keepBest)   -- protect the best spares
	local list = {}
	for i, unit in ipairs(units) do
		local belowFloor = unit.order > 0 and unit.order < CONFIG.sellRarity
		local surplus = pressured and i <= sellable
		if belowFloor or surplus then
			list[#list + 1] = unit.id
			if #list >= 300 then break end        -- keep the payload bounded
		end
	end
	if #list == 0 then return end
	local ok, value, sold = pcall(function() return R.SellInventory:InvokeServer(list) end)
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

local function unitIncome(u)
	local e = u and UnitConfig.entries[u.name]
	if not e then return 0 end
	return tonumber(select(2, pcall(e.income, u))) or 0
end

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
local function syncProtection()
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

local function goodGrade(g)
	local def = g and Grades[g]
	return def and (tonumber(def.incomeMultiplier) or 0) >= CONFIG.gradeMin
end

local function goodTrait(t)
	local def = t and Traits[t]
	return def and (tonumber(def.incomeMultiplier) or 0) >= CONFIG.traitMin
end

-- Reroll grade and trait on the placed units until each lands on a kept tier.
-- Gems pay for grades (神 x50 at the top), Trait Rerolls for traits (Eternal x27).
local function doRerolls()
	syncProtection()
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
			if b.Luck or b["Money Multiplier"] then
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
	if R.BestTowerTeam then R.BestTowerTeam:FireServer(); task.wait(0.5) end
	local ok, started = pcall(function() return R.PlayTower:InvokeServer(CONFIG.tower) end)
	if not (ok and started) then
		drainTower()                                  -- a stale run is in the way
		task.wait(3.2)                                -- PlayTower's 3s debounce
		ok, started = pcall(function() return R.PlayTower:InvokeServer(CONFIG.tower) end)
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
local function doLevel()
	local d = data()
	local lowestKey, lowestLvl
	for key, slot in pairs(d.Slots) do
		if slot.unitId and d.Inventory[slot.unitId] then
			local u = d.Inventory[slot.unitId]
			local lvl = (u.attributes and u.attributes.level) or 1
			if not lowestLvl or lvl < lowestLvl then lowestLvl, lowestKey = lvl, key end
		end
	end
	if not lowestKey then return false end
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
local function levelSlots()
	local goal = nextLuckGoal()
	local money = data().Money
	if goal and money < goal and money + STATE.incomePerSec * CONFIG.saveMinutes * 60 >= goal then
		STATE.phase = "saving for luck"
		return
	end
	local floor = data().Money * (1 - math.clamp(CONFIG.levelShare, 0, 1))
	for _ = 1, 15 do
		if data().Money <= floor then break end
		if not doLevel() then break end
	end
end

local function doCodes()
	local d = data()
	local did = 0
	for code in pairs(MonetConfig.Codes) do
		if not d.RedeemedCodes[code] then
			R.RedeemCode:FireServer(code)
			did = did + 1
			task.wait(0.35)
		end
	end
	if did > 0 then STATE.codesDone = STATE.codesDone + did end
end

local function doClaims()
	for _, ev in ipairs({ R.ClaimOffline, R.ClaimDaily, R.ClaimGroup }) do
		if ev then pcall(function() ev:FireServer() end) end
	end
	STATE.claims = STATE.claims + 1
end

local function applyAutoSell()
	if not R.UpdateAutoSell then return end
	R.UpdateAutoSell:FireServer(CONFIG.autoSell and CONFIG.sellRarity or 0)
end

-- Debug/console handle: drive any single action or read state without clicking.
_G.__ANIMEDICE_DBG = {
	CONFIG = CONFIG, STATE = STATE, data = data,
	doRoll = doRoll, doCollectPlace = doCollectPlace, doDice = doDice,
	doUpgrade = doUpgrade, sellJunk = sellJunk, levelSlots = levelSlots,
	doRerolls = doRerolls, useBoosts = useBoosts, towerRun = towerRun, drainTower = drainTower,
	nextLuckGoal = nextLuckGoal, placedUnits = placedUnits,
	doRebirth = doRebirth, doLevel = doLevel, doCodes = doCodes,
	doClaims = doClaims, DICE = DICE, UPGRADE_LINES = UPGRADE_LINES,
	invCap = invCap, bestUpgrade = bestUpgrade,
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
toggle(rollCard, "Auto Roll", "autoRoll", "rolls on the ~2s server cooldown")
rollCard:Button("Roll once", function() doRoll() end)

local incomeCard = autoPage:Card("INCOME", 1)
toggle(incomeCard, "Auto Collect & Place", "autoCollect",
	"EquipBest: banks every slot + places the best units")
toggle(incomeCard, "Auto Level Slots", "autoLevel",
	"levels the placed units - a big income boost")
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
	"wipes money only; keeps units/dice/slots, +permanent x mult", UI.theme.warn)
rbCard:Stepper("Bank x cost",
	function() return tostring(CONFIG.rebirthMult) .. "x" end,
	function(delta) CONFIG.rebirthMult = math.clamp(CONFIG.rebirthMult + delta, 1, 20) end,
	"how many next-rebirth-costs to save before rebirthing")
rbCard:Button("Rebirth now", function()
	local prev = CONFIG.rebirthMult; CONFIG.rebirthMult = 1
	doRebirth(); CONFIG.rebirthMult = prev
end)

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
towerCard:Dropdown("Tower", { "Dragon Tower", "Cursed Tower", "Pirate Tower",
	"Hidden Leaf Tower", "Slayer Tower", "Infinity Tower" }, CONFIG.tower,
	function(choice) CONFIG.tower = choice end)
local towerLabel = towerCard:Label("tower -")
towerCard:Button("Run tower now", function() task.spawn(towerRun) end)

local boostCard = boostPage:Card("BOOSTS", 2)
toggle(boostCard, "Auto Use Boosts", "autoBoost",
	"luck and income boosts; different kinds multiply together")
local luckLabel = boostCard:Label("luck -")

-- REWARDS ---------------------------------------------------------------------
local rewPage = win:Page("REWARDS", UI.icon.bag)

local codeCard = rewPage:Card("CODES", 1):Accent()
toggle(codeCard, "Auto Redeem Codes", "autoCodes", "every code, once")
codeCard:Button("Redeem all now", function() task.spawn(doCodes) end)

local claimCard = rewPage:Card("CLAIMS", 1)
toggle(claimCard, "Auto Claim Rewards", "autoClaim", "offline / daily / group")
claimCard:Button("Claim now", function() doClaims() end)

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
		task.wait(2.1)
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
			if CONFIG.autoDice then pcall(doDice) end
			if CONFIG.autoUpgrade then pcall(doUpgrade) end
			if CONFIG.autoRebirth then pcall(doRebirth) end
			-- Leveling comes last so dice/upgrades/rebirth get first claim on the
			-- money; it then pours its share of whatever is left into the slots.
			if CONFIG.autoLevel then pcall(levelSlots) end
		else
			STATE.phase = "idle"
		end
		task.wait(3)
	end
end)

-- Codes once, then claims on a slow beat.
task.spawn(function()
	while _G.__ANIMEDICE == generation do
		if CONFIG.auto and CONFIG.autoCodes then pcall(doCodes) end
		if CONFIG.auto and CONFIG.autoClaim then pcall(doClaims) end
		task.wait(60)
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
		STATE.slotsUsed = count(d.Slots)
		STATE.slotsMax = unlockedSlots()
		local _, bestName = ownedLuck()
		local pick = bestAffordableDice()
		STATE.nextDice = pick and pick.key or ("best: " .. bestName)
		STATE.invCount = count(d.Inventory)
		STATE.invCap = invCap()
		local up = bestUpgrade()
		STATE.nextUpgrade = up and (up.name .. " " .. fmt(up.price)) or "-"
		-- Effective roll luck = buff luck x equipped die. The roll only draws units
		-- whose 1-in-N chance is >= this, so it is the number that decides rarity.
		local buffLuck = tonumber(select(2, pcall(BuffController.GetBuff, "Luck"))) or 1
		local dieLuck = 1
		for _, die in ipairs(DICE) do if die.key == d.Dice then dieLuck = die.luck end end
		STATE.luck = buffLuck * dieLuck

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
		towerLabel:set(string.format("floor %d   best %d   runs %d   drops %d",
			STATE.towerFloor, STATE.towerBest, STATE.towerRuns, STATE.towerDrops))
		luckLabel:set(string.format("roll luck %s   boosts used %d", fmt(STATE.luck), STATE.boostsUsed))

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
			string.format("  levels     %d", STATE.leveled),
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
