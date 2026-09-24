--[[ loottoforge.lua - "[Races]+1 Loot To Forge" (place 118805555015549, Good Bro Studio)

  The loop the game actually runs:

      stand in a TRAIN area  -> the game trains by itself -> power -> level
      enter a STAGE          -> enemies spawn, die, drop ORE
      collect + RETURN       -> the ore reaches the server inventory
      ForgeRF(ore)           -> a WEAPON; its Train stat is the whole multiplier
      equip the best one, sell the rest -> COINS -> OrePack / Train / Luck upgrades
      level >= 25 x (rebirth+1) -> rebirth -> a better train area

  Everything below was measured against the server (GetTotalDataRF) before it was
  written down. The findings that shape this file:

  * THE DEEPEST STAGE IS THE WHOLE GAME. Stage 5 dropped Ore_7..12 and forged a
    Train 500 weapon. Stage 27 dropped Ore_41..46 and forged Train 150,000,000 -
    300,000 times more from one run. The stage is entered by standing on its
    AreaPart; the enemies are killed through the game's own hit event (EnemyHitBE),
    the same path the client's own attack uses.

  * ORE ONLY COUNTS AFTER THE RETURN. Picked-up ore sits in the pickup bag (the
    0/6 counter) and is committed to the server inventory by ClaimedAllOreRE, which
    the game fires from the Return button (ExitFightBE:Fire(true)). Skip that step
    and the ore never exists server side. The bag caps how many drops a run keeps.

  * THE FORGE PAYLOAD IS STRICT AND FAILS BY EATING THE ORE. ConfigType is the
    CATEGORY "Weapon", not "Katana"; at most 4 ore types, at least 4 ore. A wrong
    payload is not refused - the server consumed 6 ore and made nothing
    (ForgeUtils:115 clamp error). So the payload is built by those rules only.

  * COINS COME FROM SELLING WEAPONS. A spare Train 25M weapon sold for 5,040,000
    (the rebirth coin bonus applies). The equipped one, enchanted ones and anything
    better than the worn weapon are never sold.

  * TRAINING IS JUST STANDING IN THE AREA. Touching Train_N sets AutoTrainAreaID
    and the game's own loop does the rest. Firing TrainOnceRE by hand is capped at
    ~6.7/s by server-issued UUIDs and two loops at once made the server ROLL BACK
    power, so this script never fires it.

  * NO HOOKS. bridge spy (a hookmetamethod on InvokeServer) broke this game twice:
    StageFinishedRF stopped returning, FinishStage waited forever and nothing
    dropped. Nothing in this file hooks anything.

  Never spends Robux: the IsPay train areas (9-11) are filtered, rebirth skip
  products and gamepasses are never touched, Dev.* remotes are never fired.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local plr = Players.LocalPlayer

local GEN = (_G.__LOOTTOFORGE or 0) + 1
_G.__LOOTTOFORGE = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,

	farm = true,         -- clear a stage, collect the ore, return to commit it
	stage = 0,           -- 0 = deepest stage passed; otherwise that stage number
	train = true,        -- stand in the best free train area between runs
	trainSecs = 20,      -- seconds of training between two stage runs
	forge = true,        -- forge whenever the server holds 4+ ore
	equip = true,        -- wear the weapon with the highest Train stat
	sell = true,         -- sell weapons weaker than the worn one (never enchanted)
	upgrade = true,      -- spend coins on upgrades
	orePackFirst = true, -- bag size first: more ore per run means better forges
	upgOrePack = true,
	upgTrain = true,
	upgLuck = true,
	coinKeep = 0,        -- coins never spent
	rebirth = true,      -- as soon as the level requirement is met
	antiAfk = true,
}

local STATE = {
	phase = "idle", note = "",
	level = 0, power = 0, coin = 0, rebirth = 0, stagePass = 0,
	needLevel = 0, area = 0, areaMult = 1, stage = 0,
	weapon = "-", weaponTrain = 0, weapons = 0, ore = 0, orePack = 0, orePackCap = 0,
	upg = { OrePack = 0, Train = 0, Luck = 0 },
	runs = 0, oreGot = 0, forged = 0, sold = 0, coinsSold = 0, upgrades = 0, rebirths = 0,
	lastRun = "-", lastForge = "-",
	busy = false,
}

local function note(t) STATE.note = tostring(t) end

--------------------------------------------------------------------------------
-- references. Every wait carries a timeout: in the wrong place an endless
-- WaitForChild parks whatever loaded this file.
--------------------------------------------------------------------------------

local function wfc(parent, name)
	return parent and parent:WaitForChild(name, 10)
end

-- A require can yield forever; run it behind a wall clock so a hung module
-- costs its own feature and nothing else.
local function safeRequire(mod)
	if not mod then return nil end
	local done, res = false, nil
	task.spawn(function()
		pcall(function() res = require(mod) end)
		done = true
	end)
	local t = 0
	while not done and t < 8 do task.wait(0.1); t = t + 0.1 end
	return res
end

pcall(function() if setthreadidentity then setthreadidentity(2) end end)

local Remote = wfc(ReplicatedStorage, "Remote")
local Config = wfc(ReplicatedStorage, "Config")
local LocalData = wfc(ReplicatedStorage, "LocalData")

local R = {
	total = wfc(wfc(Remote, "Profile"), "GetTotalDataRF"),
	forge = wfc(wfc(Remote, "Forge"), "ForgeRF"),
	rebirth = wfc(wfc(Remote, "Rebirth"), "TryRebirthRE"),
}

local Comm = safeRequire(wfc(wfc(ReplicatedStorage, "Utils"), "CommunicationUtils"))
local BackpackData = safeRequire(wfc(LocalData, "BackpackData"))
local UpgradeData = safeRequire(wfc(LocalData, "UpgradeData"))
local TrainAreaCfg = safeRequire(wfc(wfc(Config, "TrainArea"), "Config"))
local UpgradeCfg = safeRequire(wfc(wfc(Config, "Upgrade"), "Config"))
local RebirthHelper = safeRequire(wfc(wfc(Config, "Rebirth"), "Helper"))

local hitBE, exitBE
pcall(function()
	hitBE = Comm.TryGetBindableEvent("Attack", "EnemyHitBE")
	exitBE = Comm.TryGetBindableEvent("Stage", "ExitFightBE")
end)

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function short(n)
	n = tonumber(n) or 0
	local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 1
	while math.abs(n) >= 1000 and i < #units do n = n / 1000; i = i + 1 end
	if math.abs(n) >= 1000 then return string.format("%.2e", n) end
	return (string.format("%.2f", n):gsub("%.?0+$", "")) .. units[i]
end

local function hrp()
	local c = plr.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function dead()
	if plr:GetAttribute("Dead") then return true end
	local c = plr.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	return not h or h.Health <= 0
end

-- RemoteFunctions behind a wall clock: one that never answers must not park the
-- farm thread for good.
local function invoke(rf, ...)
	if not rf then return nil end
	local args = table.pack(...)
	local done, ok, res = false, false, nil
	task.spawn(function()
		ok, res = pcall(function() return rf:InvokeServer(table.unpack(args, 1, args.n)) end)
		done = true
	end)
	local t = 0
	while not done and t < 8 do task.wait(0.1); t = t + 0.1 end
	if not done or not ok then return nil end
	return res
end

-- The server's own view. Every decision reads this, never the client backpack
-- cache - the cache kept ore the server no longer had.
local function data()
	local d = invoke(R.total)
	if type(d) == "table" then STATE.data = d end
	return (type(d) == "table") and d or nil
end

local function trainValue(item)
	local m = item and item.MainAffix
	if m and m.Type == "Train" then return tonumber(m.Number) or 0 end
	return 0
end

-- one pin at a time; the body belongs to whichever pass set it last
local pinConn
local function pin(pos)
	if pinConn then pinConn:Disconnect(); pinConn = nil end
	if not pos then return end
	local cf = CFrame.new(pos)
	pinConn = RunService.Heartbeat:Connect(function()
		local r = hrp()
		if r then
			r.CFrame = cf
			r.AssemblyLinearVelocity = Vector3.zero
		end
	end)
end

local function unpin() pin(nil) end

local function streamAround(pos)
	pcall(function() plr:RequestStreamAroundAsync(pos, 5) end)
end

--------------------------------------------------------------------------------
-- state refresh
--------------------------------------------------------------------------------

local function refresh(withServer)
	local eco = plr:FindFirstChild("Eco")
	if eco then
		pcall(function()
			STATE.level = eco.level.Value
			STATE.power = eco.power.Value
			STATE.coin = eco.coin.Value
			STATE.rebirth = eco.rebirth.Value
		end)
	end
	pcall(function()
		STATE.needLevel = RebirthHelper.GetNeedLevel(STATE.rebirth + 1) or 0
	end)
	pcall(function() STATE.orePackCap = UpgradeData.GetMaxNum("OrePack") end)
	if not withServer then return end

	local d = data()
	if not d then return end
	STATE.stagePass = (d.Stats and tonumber(d.Stats.StagePass)) or STATE.stagePass
	local upg = d.Upgrade or {}
	for _, k in ipairs({ "OrePack", "Train", "Luck" }) do
		STATE.upg[k] = (upg[k] and tonumber(upg[k].Level)) or 0
	end
	local bp = d.Backpack or {}
	local eq = bp.equiped and bp.equiped.Weapon
	local ore, weapons = 0, 0
	for uid, it in pairs(bp.have or {}) do
		if it.Type == "Ore" then
			ore = ore + (tonumber(it.Number) or 1)
		elseif it.Type == "Weapon" then
			weapons = weapons + 1
			if uid == eq then
				STATE.weapon = tostring(it.ID)
				STATE.weaponTrain = trainValue(it)
			end
		end
	end
	STATE.ore, STATE.weapons = ore, weapons
end

--------------------------------------------------------------------------------
-- training: stand in the best free area and let the game train
--------------------------------------------------------------------------------

_G.__LTF_POS = _G.__LTF_POS or { train = {}, stage = {} }
local POS = _G.__LTF_POS

local function bestArea()
	local best, mult = 1, 1
	if type(TrainAreaCfg) ~= "table" then return best, mult end
	for i, v in ipairs(TrainAreaCfg) do
		if not v.IsPay and (tonumber(v.NeedRebirth) or 0) <= STATE.rebirth then
			if (tonumber(v.Basic) or 0) >= mult then best, mult = i, tonumber(v.Basic) end
		end
	end
	return best, mult
end

local function trainPos(i)
	local folder = Workspace:FindFirstChild("CanAttackFolder")
	folder = folder and folder:FindFirstChild("TrainArea")
	local m = folder and folder:FindFirstChild("Train_" .. i)
	if m then
		local ok, cf = pcall(function() return m:GetPivot() end)
		if ok and cf then POS.train[i] = cf.Position + Vector3.new(0, 2, 0) end
	end
	return POS.train[i]
end

local function trainPass(secs)
	local i, mult = bestArea()
	STATE.area, STATE.areaMult = i, mult
	local pos = trainPos(i)
	if not pos then
		streamAround(Vector3.new(-50, 4, -30))
		task.wait(1)
		pos = trainPos(i)
	end
	if not pos then note("train area " .. i .. " not loaded"); return end
	STATE.phase = "train"
	pin(pos)
	local t0 = os.clock()
	while os.clock() - t0 < secs and CONFIG.auto and CONFIG.train and GEN == _G.__LOOTTOFORGE do
		task.wait(0.5)
	end
	unpin()
end

--------------------------------------------------------------------------------
-- stage run: enter, kill through the game's hit event, collect, RETURN
--------------------------------------------------------------------------------

local function targetStage()
	if CONFIG.stage and CONFIG.stage > 0 then return math.floor(CONFIG.stage) end
	return math.max(1, math.min(STATE.stagePass, 27))
end

local function stagePos(n)
	local sm = Workspace:FindFirstChild("WorldModel")
	sm = sm and sm:FindFirstChild("StageMap")
	local ap = sm and sm:FindFirstChild("AreaPart")
	local part = ap and ap:FindFirstChild("Stage_" .. n)
	if part and part:IsA("BasePart") then
		POS.stage[n] = Vector3.new(part.Position.X, 4, part.Position.Z)
	end
	-- measured spacing, only until the real part has streamed in once
	return POS.stage[n] or Vector3.new(3.24, 4, -113 - 108 * (n - 1))
end

local function enemiesNear(z)
	local list = {}
	local ef = Workspace:FindFirstChild("EnemyFolder")
	if not ef then return list end
	for _, m in ipairs(ef:GetChildren()) do
		if not m:GetAttribute("Dead") then
			local ok, p = pcall(function() return m:GetPivot().Position end)
			if ok and math.abs(p.Z - z) < 80 then list[#list + 1] = m end
		end
	end
	return list
end

local function oreModels()
	local oc = Workspace:FindFirstChild("OreCache")
	return oc and oc:GetChildren() or {}
end

local function stageRun()
	if dead() then note("dead - waiting"); return end
	refresh(true)
	-- taken here, not after the return: the read-out loop refreshes in between
	local oreBefore = STATE.ore
	local n = targetStage()
	STATE.stage = n
	STATE.phase = "stage " .. n
	local pos = stagePos(n)
	streamAround(pos)
	pin(pos)

	-- the enemies only exist once the stage has been entered
	local t0 = os.clock()
	local found = {}
	while os.clock() - t0 < 5 do
		task.wait(0.4)
		found = enemiesNear(pos.Z)
		if #found > 0 and os.clock() - t0 > 1.5 then break end
	end
	pos = stagePos(n)

	local killed = 0
	for _ = 1, 3 do
		for _, m in ipairs(enemiesNear(pos.Z)) do
			pcall(function() hitBE:Fire(m.Name, 1e30, { Damage = 1e30 }) end)
			killed = killed + 1
		end
		task.wait(0.6)
		if #enemiesNear(pos.Z) == 0 then break end
	end

	-- drops appear a moment after the last enemy
	local t1 = os.clock()
	while #oreModels() == 0 and os.clock() - t1 < 4 do task.wait(0.3) end
	task.wait(0.8)
	local drops = #oreModels()
	for _, o in ipairs(oreModels()) do
		local pp = o:FindFirstChildWhichIsA("ProximityPrompt", true)
		if pp then pcall(function() fireproximityprompt(pp) end) end
	end
	task.wait(1)
	unpin()

	-- the Return button: commits the picked-up ore to the server inventory
	pcall(function() exitBE:Fire(true) end)
	task.wait(2)

	refresh(true)
	local got = math.max(0, STATE.ore - oreBefore)
	STATE.runs = STATE.runs + 1
	STATE.oreGot = STATE.oreGot + got
	STATE.lastRun = string.format("stage %d: %d killed, %d drops, +%d ore", n, killed, drops, got)
	note(STATE.lastRun)
end

--------------------------------------------------------------------------------
-- forge, equip, sell
--------------------------------------------------------------------------------

local function oreList(d)
	local list = {}
	for uid, it in pairs((d.Backpack and d.Backpack.have) or {}) do
		if it.Type == "Ore" then
			list[#list + 1] = {
				uuid = uid, id = tostring(it.ID), n = tonumber(it.Number) or 1,
				rank = tonumber(tostring(it.ID):match("%d+")) or 0,
			}
		end
	end
	table.sort(list, function(a, b) return a.rank > b.rank end)
	return list
end

local function weaponSet(d)
	local set = {}
	for uid, it in pairs((d.Backpack and d.Backpack.have) or {}) do
		if it.Type == "Weapon" then set[uid] = it end
	end
	return set
end

local function forgePass()
	for _ = 1, 6 do
		local d = data()
		if not d then return end
		local ores = oreList(d)
		-- the rules the server enforces by eating the ore: category, <=4 types, >=4 ore
		local list, total, used = {}, 0, {}
		for i = 1, math.min(4, #ores) do
			list[ores[i].uuid] = ores[i].n
			total = total + ores[i].n
			used[#used + 1] = ores[i].id .. "x" .. ores[i].n
		end
		if total < 4 then return end

		STATE.phase = "forge"
		local before = weaponSet(d)
		invoke(R.forge, { ConfigType = "Weapon", UUIDList = list })
		task.wait(0.8)
		local d2 = data()
		local made
		if d2 then
			for uid, it in pairs(weaponSet(d2)) do
				if not before[uid] then made = it end
			end
		end
		if not made then
			note("forge produced nothing (" .. table.concat(used, " ") .. ") - stopped")
			return
		end
		STATE.forged = STATE.forged + 1
		STATE.lastForge = string.format("%s Train %s from %s", tostring(made.ID), short(trainValue(made)),
			table.concat(used, " "))
		note("forged " .. STATE.lastForge)
	end
end

local function equipPass()
	local d = data()
	if not d then return end
	local eq = d.Backpack and d.Backpack.equiped and d.Backpack.equiped.Weapon
	local best, bestV = nil, -1
	for uid, it in pairs(weaponSet(d)) do
		local v = trainValue(it)
		if v > bestV then best, bestV = uid, v end
	end
	if best and best ~= eq then
		pcall(function() BackpackData.EquipedItem(best, "Weapon") end)
		task.wait(1)
		note("equipped Train " .. short(bestV))
	end
end

-- EnchanceNum is the number of enchant SLOTS and EnchanceList holds one table per
-- slot, empty until something is put in it. Reading either as "enchanted" kept
-- every forged weapon (they all come with slots) - only a filled slot counts.
local function enchanted(it)
	if type(it.EnchanceList) == "table" then
		for _, slot in pairs(it.EnchanceList) do
			if type(slot) ~= "table" or next(slot) ~= nil then return true end
		end
	end
	return it.Lock == true or it.Locked == true
end

local function sellPass()
	local d = data()
	if not d then return end
	local eq = d.Backpack and d.Backpack.equiped and d.Backpack.equiped.Weapon
	local set = weaponSet(d)
	local worn = eq and set[eq]
	if not worn then return end -- never sell without knowing what is worn
	local wornV = trainValue(worn)
	local coin0 = STATE.coin
	local n = 0
	for uid, it in pairs(set) do
		if uid ~= eq and not enchanted(it) and trainValue(it) < wornV then
			pcall(function() BackpackData.TrySellItem(uid, 1) end)
			n = n + 1
			task.wait(0.35)
		end
	end
	if n > 0 then
		task.wait(1)
		refresh(false)
		STATE.sold = STATE.sold + n
		STATE.coinsSold = STATE.coinsSold + math.max(0, STATE.coin - coin0)
		note(string.format("sold %d weapons, +%s coins", n, short(STATE.coin - coin0)))
	end
end

--------------------------------------------------------------------------------
-- upgrades: bag first, then Train and Luck by next price
--------------------------------------------------------------------------------

local function nextPrice(key)
	local ladder = type(UpgradeCfg) == "table" and UpgradeCfg[key]
	if type(ladder) ~= "table" then return nil end
	local step = ladder[(STATE.upg[key] or 0) + 1]
	return step and tonumber(step.Price) or nil
end

local function upgradePass()
	refresh(true)
	for _ = 1, 8 do
		local keys = {}
		local packOpen = CONFIG.upgOrePack and nextPrice("OrePack") ~= nil
		if CONFIG.orePackFirst and packOpen then
			keys = { "OrePack" }
		else
			if CONFIG.upgOrePack then keys[#keys + 1] = "OrePack" end
			if CONFIG.upgTrain then keys[#keys + 1] = "Train" end
			if CONFIG.upgLuck then keys[#keys + 1] = "Luck" end
		end
		local pick, price = nil, math.huge
		for _, k in ipairs(keys) do
			local p = nextPrice(k)
			if p and p < price then pick, price = k, p end
		end
		if not pick or STATE.coin - price < CONFIG.coinKeep then return end

		local lvl = STATE.upg[pick]
		pcall(function() UpgradeData.UpgradeOnce(pick) end)
		task.wait(1)
		refresh(true)
		if STATE.upg[pick] <= lvl then
			note(pick .. " upgrade refused at " .. short(price))
			return
		end
		STATE.upgrades = STATE.upgrades + 1
		note(string.format("%s -> level %d for %s", pick, STATE.upg[pick], short(price)))
	end
end

--------------------------------------------------------------------------------
-- rebirth
--------------------------------------------------------------------------------

local function rebirthPass()
	refresh(false)
	local need = STATE.needLevel
	if not need or need <= 0 or STATE.level < need then return end
	local r0 = STATE.rebirth
	R.rebirth:FireServer()
	task.wait(1.5)
	refresh(false)
	if STATE.rebirth > r0 then
		STATE.rebirths = STATE.rebirths + 1
		note("rebirth -> " .. STATE.rebirth)
	end
end

local function unstuck()
	unpin()
	local r = hrp()
	if r then r.Anchored = false end
	STATE.busy = false
	note("unstuck")
end

--------------------------------------------------------------------------------
-- debug handle, published BEFORE the panel is built
--------------------------------------------------------------------------------

_G.__LOOTTOFORGE_DBG = {
	CONFIG = CONFIG, STATE = STATE, POS = POS,
	data = data, refresh = refresh, bestArea = bestArea, targetStage = targetStage,
	trainPass = trainPass, stageRun = stageRun, forgePass = forgePass,
	equipPass = equipPass, sellPass = sellPass, upgradePass = upgradePass,
	rebirthPass = rebirthPass, unstuck = unstuck, pin = pin, unpin = unpin,
}

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

-- live read-out, whether the farm runs or not
task.spawn(function()
	local beat = 0
	while GEN == _G.__LOOTTOFORGE do
		pcall(function() refresh(beat % 5 == 0) end)
		beat = beat + 1
		task.wait(1)
	end
end)

-- One body, one owner: stage run, then everything that needs no body, then
-- training until the next run.
task.spawn(function()
	while GEN == _G.__LOOTTOFORGE do
		if CONFIG.auto then
			STATE.busy = true
			if CONFIG.farm then
				local ok, err = pcall(stageRun)
				if not ok then unpin(); note("stage failed: " .. tostring(err)) end
			end
			if CONFIG.forge then pcall(forgePass) end
			if CONFIG.equip then pcall(equipPass) end
			if CONFIG.sell then pcall(sellPass) end
			if CONFIG.upgrade then pcall(upgradePass) end
			if CONFIG.rebirth then pcall(rebirthPass) end
			if CONFIG.train then
				local ok, err = pcall(function() trainPass(CONFIG.trainSecs) end)
				if not ok then unpin(); note("train failed: " .. tostring(err)) end
			else
				task.wait(3)
			end
			STATE.busy = false
			STATE.phase = "idle"
		else
			if pinConn then unpin() end
			task.wait(1)
		end
	end
	unpin()
end)

-- anti-AFK: the farm runs for hours without input
pcall(function()
	if _G.__LTF_IDLE then _G.__LTF_IDLE:Disconnect() end
	local VirtualUser = game:GetService("VirtualUser")
	_G.__LTF_IDLE = plr.Idled:Connect(function()
		if not CONFIG.antiAfk then return end
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

-- UI.sweep pcalls each container on its own; a hand written list has a nil hole
-- that stops ipairs, and on some executors CoreGui THROWS rather than returning.
if UI.sweep then pcall(function() UI.sweep("LootToForgePanel") end) end

UI.config("loottoforge", CONFIG)

local win = UI.Window({
	name = "LootToForgePanel",
	title = "LOOT",
	accentTitle = "FORGE",
	subtitle = "seltonmt",
})

local farm = win:Page("FARM", UI.icon.bolt)

local loopCard = farm:Card("LOOP", 1):Accent()
loopCard:Toggle("Farm stages", CONFIG.farm, function(v) CONFIG.farm = v end,
	"Enters the stage, the enemies die, the ore is collected and brought home. Stage 27 dropped Ore_41-46, stage 5 only Ore_7-12.")
loopCard:Slider("Stage (0 = deepest)", 0, 27, CONFIG.stage, function(v) CONFIG.stage = v end)
loopCard:Toggle("Train", CONFIG.train, function(v) CONFIG.train = v end,
	"Stands in the best free train area; the game trains by itself there.")
loopCard:Slider("Training seconds", 5, 120, CONFIG.trainSecs, function(v) CONFIG.trainSecs = v end)
loopCard:Toggle("Rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"Fires as soon as the level reaches 25 x (rebirth + 1). Coins and weapons stay.")

local forgeCard = farm:Card("FORGE", 2):Accent()
forgeCard:Toggle("Forge", CONFIG.forge, function(v) CONFIG.forge = v end,
	"Forges a weapon from the 4 best ore types whenever 4 or more ore are home. Stage 27 ore forged Train 150M.")
forgeCard:Toggle("Equip best", CONFIG.equip, function(v) CONFIG.equip = v end,
	"Wears the weapon with the highest Train stat.")
forgeCard:Toggle("Sell weaker weapons", CONFIG.sell, function(v) CONFIG.sell = v end,
	"Sells every weapon below the worn one for coins. Enchanted and locked ones are kept.", UI.theme.warn)

local spendCard = farm:Card("UPGRADES", 1)
spendCard:Toggle("Buy upgrades", CONFIG.upgrade, function(v) CONFIG.upgrade = v end,
	"Spends coins on the upgrade station.")
spendCard:Toggle("Bag first", CONFIG.orePackFirst, function(v) CONFIG.orePackFirst = v end,
	"Ore bag until it is maxed: every slot is one more ore per run.")
spendCard:Toggle("Ore bag", CONFIG.upgOrePack, function(v) CONFIG.upgOrePack = v end)
spendCard:Toggle("Train boost", CONFIG.upgTrain, function(v) CONFIG.upgTrain = v end)
spendCard:Toggle("Luck", CONFIG.upgLuck, function(v) CONFIG.upgLuck = v end)

local manual = farm:Card("MANUAL", 2)
manual:Button("Run stage once", function() task.spawn(function() pcall(stageRun) end) end)
manual:Button("Forge now", function() task.spawn(function() pcall(forgePass); pcall(equipPass) end) end)
manual:Button("Unstuck", function() unstuck() end, UI.theme.bad)
manual:Toggle("Anti-AFK", CONFIG.antiAfk, function(v) CONFIG.antiAfk = v end)

local out = farm:Card("STATUS", 0):Readout(14)

task.spawn(function()
	while GEN == _G.__LOOTTOFORGE do
		local ok = pcall(function()
			out:set({
				"STATE",
				string.format("  phase      %s", STATE.phase),
				string.format("  level      %d / %d for rebirth %d", STATE.level, STATE.needLevel, STATE.rebirth + 1),
				string.format("  area       Train_%d  x%s", STATE.area, tostring(STATE.areaMult)),
				string.format("  stage      %d   (passed %d)", targetStage(), STATE.stagePass),
				"GEAR",
				string.format("  weapon     %s   Train %s   (%d owned)", STATE.weapon, short(STATE.weaponTrain), STATE.weapons),
				string.format("  ore home   %d   bag %d", STATE.ore, STATE.orePackCap),
				string.format("  upgrades   bag L%d  train L%d  luck L%d", STATE.upg.OrePack, STATE.upg.Train, STATE.upg.Luck),
				"SESSION",
				string.format("  runs %d  ore %d  forged %d  sold %d (+%s)  upgrades %d  rebirths %d",
					STATE.runs, STATE.oreGot, STATE.forged, STATE.sold, short(STATE.coinsSold), STATE.upgrades, STATE.rebirths),
				"  last run   " .. STATE.lastRun,
				"  last forge " .. STATE.lastForge,
				STATE.note ~= "" and ("  " .. STATE.note) or "  -",
			})
			win:SetStatus(string.format("%s coins   lv%d   %d rebirths   Train %s",
				short(STATE.coin), STATE.level, STATE.rebirth, short(STATE.weaponTrain)))
			win:SetStat(1, short(STATE.coin), "coins")
			win:SetStat(2, tostring(STATE.level), "level")
			win:SetStat(3, tostring(STATE.rebirth), "rebirths")
		end)
		if not ok then task.wait(2) end
		task.wait(1)
	end
end)

pcall(function()
	win:SetMaster(CONFIG.auto, "Auto Farm")
	win:OnMaster(function(on)
		CONFIG.auto = on
		if not on then unpin() end
		note(on and "auto on" or "auto off")
	end)
end)

pcall(function() win:Home() end)

note("ready")
