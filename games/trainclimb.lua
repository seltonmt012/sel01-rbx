--[[ trainclimb.lua - "Training To Climb" (world 1: 98001626946868, world 2: 101836932554047)

  The loop the game actually runs:

      stand at a machine -> click -> Arm / Leg / Body     (Power = the sum of the three)
      climb the wall     -> slide back down -> the slide pays Coin
      Coin               -> weapons, auras, coaches, eggs (every one of them permanent)
      Ascend             -> a training multiplier, gated on the WEAKEST muscle
      Trophy             -> unlocks the next world, and world 2 pays ~295,000x world 1

  Everything below was measured against the server through the bridge before it was
  written down. The four findings that shape this file:

  * THE CLIENT SENDS THE TRAINING MULTIPLIER AND THE SERVER TAKES IT.
    `RE_ApplyOnceTrain:FireServer(mult)`. The real client sends the combo value from
    `HandClickAPI.playClickTween()` - 1.0 rising to 1.5, or a flat 5.0 while the
    FireTrain buff runs. Measured: 62 calls at 1.0 gave +4 Power, the same 62 calls
    at 5.0 gave +20, exactly 5x. 1000 gave +1000, 100000 gave +101000 and 1e12 gave
    +156 trillion in six calls. There is no clamp anywhere. What IS capped is the
    rate: firing faster than ~3/s credits less per call, so the loop paces itself at
    0.3s and puts everything into the argument instead.

  * THE CLIMB IS SIMULATED ENTIRELY ON THE CLIENT. `Battle` computes the progress
    ratio locally every Heartbeat and only reports it at the end:
    `RE_PlayerFinishBattle:FireServer(progress)`. Fired bare, standing at a training
    machine, having never touched the climb trigger, `FireServer(1)` paid the full
    171,108,100 x coinMult. There is no state check and no cooldown - 40 calls in
    2.4s credited 40 of 40. `progress` is clamped to 1 server-side (1000 pays the
    same as 1), so the lever is the call count and the weapon's coin multiplier.

  * A TROPHY IS ONE CALL. `RE_PlayerTriggerTrophy:FireServer()` takes no arguments
    and has no server cooldown - the 1s debounce lives in TrophyManager on the
    client. 10,680 calls credited 10,680. That matters because the world gate is
    priced in trophies: world 2 costs 5, world 3 costs 10,000.

  * ASCEND IS A PURE UPGRADE AND THE GATE IS THE *WEAKEST* MUSCLE.
    `RE_RebirthUpgradeRequest:FireServer()` takes no arguments and consumes nothing
    at all - level 0 to 15 was climbed with the currencies unchanged. It was refused
    at 206K Power only because Leg was still 10; `RebirthHelper.getNextLvNeedStrength`
    is checked against min(Arm, Leg, Body), which is why this file always trains the
    lowest of the three rather than a fixed one.

  Two more things worth knowing before touching the remotes:

  * FLOODING ONE REMOTE SILENTLY KILLS EVERY OTHER REMOTE FOR MINUTES. 174,000
    finish-battle calls in 4s credited 3.4% and the server then paid the backlog out
    at a flat 135 B/s for four more minutes. While that drained, a weapon purchase,
    an egg draw and a trophy trigger all did nothing whatsoever - no error, no
    refusal - which reads exactly like an anti-cheat ban and is not one. Throughput
    peaked around 300 calls per frame; 1000 was worse AND dropped the client to 19
    FPS. `coinPerFrame` is capped at 300 and defaults to 20 for that reason.

  * WORLD 2 IS A DIFFERENT PLACE AND PAYS 295,000x. Same layout, same 11 machines,
    same remotes - but one finish-battle call paid 252.7 TRILLION there against
    855 million in world 1, with the identical weapon equipped. The first
    `TryTeleportWorld:FireServer(2)` only UNLOCKS (and charges the 5 trophies); the
    second one actually travels. Progress is a real datastore: every value survived
    the place change to the byte.

  Never spends Robux: `MarketHelper.Products` (47 of them), `MarketHelper.Passes`
  (30), every `isRobuxWeapon` / `isRobuxEgg` entry, the Robux auras and coaches, and
  `RE_PurchaseSkipRequest` - the "Jump Over" button on the ascend panel.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

local GEN = (_G.__TRAINCLIMB or 0) + 1
_G.__TRAINCLIMB = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,

	train = true,           -- RE_ApplyOnceTrain with a forged multiplier
	trainPower = 1e6,       -- the argument; the server multiplies the gain by it
	coin = true,            -- RE_PlayerFinishBattle(1), the whole income of the game
	coinPerFrame = 20,      -- 300 is the measured peak; past that the queue clogs
	trophy = true,          -- RE_PlayerTriggerTrophy, one per call, no cooldown
	trophyPerFrame = 10,

	ascend = true,          -- rebirth whenever the weakest muscle clears the gate
	weapons = true,         -- best affordable coin weapon, then equip the best coin one
	auras = true,           -- coin auras only
	coaches = true,         -- coin coaches only
	eggs = true,            -- best affordable coin egg, x10 draws
	pets = true,            -- equip best, fuse duplicates
	freebies = true,        -- daily, online, offline, friend, group, the free packs
	worlds = true,          -- unlock and travel to the highest world the trophies allow

	coinKeep = 0,           -- coin never spent (0 = spend everything)
}

local STATE = {
	phase = "idle",
	note = "",
	arm = 0, leg = 0, body = 0, coin = 0, trophy = 0,
	power = 0, ascendLv = 0, ascendNeed = 0, ratio = 1,
	world = 1, machine = "-", muscle = "-",
	coinRate = 0, powerRate = 0,
	weapon = "-", coinMult = 1,
	aura = "-", coach = "-",
	petCount = 0, petSlots = 0,
	spent = 0, earned = 0,
	busy = false,
}

--------------------------------------------------------------------------------
-- helpers (kept above their first caller - a local is invisible above its own
-- definition, and inside pcall that surfaces as a quiet note rather than a crash)
--------------------------------------------------------------------------------

local function short(n)
	n = tonumber(n) or 0
	local units = {
		{ 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" }, { 1e21, "Sx" },
		{ 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" },
		{ 1e6, "M" }, { 1e3, "K" },
	}
	for _, u in ipairs(units) do
		if math.abs(n) >= u[1] then
			return string.format("%.2f%s", n / u[1], u[2])
		end
	end
	return string.format("%.0f", n)
end

local function note(text)
	STATE.note = text
end

local function char()
	local model = plr.Character
	if not model then return nil, nil, nil end
	return model, model:FindFirstChild("HumanoidRootPart"), model:FindFirstChildOfClass("Humanoid")
end

--------------------------------------------------------------------------------
-- the game's own modules
--------------------------------------------------------------------------------

local Shared = ReplicatedStorage:WaitForChild("FrameWork_Shared")
local Remotes = Shared:WaitForChild("Remotes")
local L1 = Shared:WaitForChild("Configs"):WaitForChild("L1_Configs")

local WeaponHelper = require(L1:WaitForChild("WeaponHelper"))
local EggHelper = require(L1:WaitForChild("EggHelper"))
local RebirthHelper = require(L1:WaitForChild("RebirthHelper"))
local AuraConfig = require(L1:WaitForChild("AuraHelper"):WaitForChild("AuraConfig"))
local CoachConfig = require(L1:WaitForChild("CoachHelper"):WaitForChild("CoachConfig"))
local PackConfig = require(L1:WaitForChild("PackHelper"):WaitForChild("PackConfig"))

local ClientRoot = plr:WaitForChild("PlayerScripts"):WaitForChild("FrameWork_Client")
local ClientAPI = ClientRoot:WaitForChild("Modules"):WaitForChild("L0_ClientAPI")
local API = require(ClientRoot.Modules:WaitForChild("L1_APIManager"):WaitForChild("APIManager_Client"))
local StateValueAPI = require(ClientAPI:WaitForChild("StateValueAPI_Client"))
local WeaponAPI = require(ClientAPI:WaitForChild("WeaponAPI_Client"))
local DailyAPI = require(ClientAPI:WaitForChild("DailyRewardAPI_Client"))

-- A client data store is REPLACED on every server update, not mutated, so a table
-- pulled out of an upvalue once goes stale and reads the same number forever. Every
-- read here re-walks the upvalues; the accessor functions themselves are stable.
local function storeOf(fn, key)
	if type(fn) ~= "function" then return nil end
	local ok, ups = pcall(debug.getupvalues, fn)
	if not ok or type(ups) ~= "table" then return nil end
	for _, v in ipairs(ups) do
		if type(v) == "table" and v[key] ~= nil then return v end
	end
	return nil
end

local function currency(kind)
	local ok, v = pcall(API.CurrencyAPI.getPlayerCurrencyAmount, kind)
	return (ok and tonumber(v)) or 0
end

local function weaponStore()
	return storeOf(WeaponAPI.getBackageWeaponAmount, "weaponList")
end

local function auraStore()
	for _, fn in pairs(API.AuraAPI or {}) do
		local s = storeOf(fn, "have")
		if s then return s end
	end
	return nil
end

local function coachStore()
	for _, fn in pairs(API.CoachAPI or {}) do
		local s = storeOf(fn, "have")
		if s then return s end
	end
	return nil
end

local function petData()
	local ok, d = pcall(API.PetAPI.getPlayerPetsData)
	if ok and type(d) == "table" then return d end
	return { petList = {}, capacity = 0, slot = 0 }
end

local function stateValue(key)
	local ok, v = pcall(StateValueAPI.getPlayerStateValue, key)
	if ok then return v end
	return nil
end

local function permission(name)
	local P = API.PermissionAPI
	if not P then return false end
	local ok, v = pcall(P.isPlayerGotPermission, name)
	return ok and v == true
end

--------------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------------

-- key1 / key2 / key3 are the machine types; which muscle each one feeds was read
-- off the server, not off the name, because the numbering matches nothing.
local MUSCLE_OF = { key1 = "Body", key2 = "Leg", key3 = "Arm" }
local MACHINE_OF = { Body = "key1", Leg = "key2", Arm = "key3" }

local lastCoin, lastPower, lastSample = 0, 0, 0

local function refresh()
	STATE.arm = currency("Arm")
	STATE.leg = currency("Leg")
	STATE.body = currency("Body")
	STATE.coin = currency("Coin")
	STATE.trophy = currency("Trophy")
	STATE.power = plr:GetAttribute("Power") or 0
	STATE.ascendLv = tonumber(stateValue("Rebirth")) or 0
	STATE.world = tonumber(stateValue("CurrentWorld")) or 1
	STATE.machine = plr:GetAttribute("PPType") or "-"
	STATE.muscle = MUSCLE_OF[STATE.machine] or "-"

	local okNeed, need = pcall(RebirthHelper.getNextLvNeedStrength, STATE.ascendLv)
	STATE.ascendNeed = (okNeed and tonumber(need)) or math.huge
	local okRatio, ratio = pcall(RebirthHelper.getLvAddRatio, STATE.ascendLv)
	STATE.ratio = (okRatio and tonumber(ratio)) or 1

	local ws = weaponStore()
	STATE.weapon = (ws and ws.current) or "-"
	if ws and ws.current then
		local okC, c = pcall(WeaponHelper.getWeaponCoinValue, ws.current)
		STATE.coinMult = (okC and tonumber(c)) or 1
	end

	local as = auraStore()
	STATE.aura = (as and as.equip) or "-"
	-- there is no coach ownership store on the client, so the read-out keeps what
	-- the last equip set rather than blanking every refresh
	local cs = coachStore()
	if cs and cs.equip then STATE.coach = cs.equip end

	local pd = petData()
	local n = 0
	for _ in pairs(pd.petList or {}) do n = n + 1 end
	STATE.petCount = n
	STATE.petSlots = pd.slot or 0

	local now = os.clock()
	if lastSample > 0 and now - lastSample >= 1 then
		local dt = now - lastSample
		if STATE.coin >= lastCoin then STATE.coinRate = (STATE.coin - lastCoin) / dt end
		if STATE.power >= lastPower then STATE.powerRate = (STATE.power - lastPower) / dt end
	end
	if now - lastSample >= 1 then
		lastCoin, lastPower, lastSample = STATE.coin, STATE.power, now
	end
end

local function weakestMuscle()
	local best, bestVal = "Arm", math.huge
	for _, name in ipairs({ "Arm", "Leg", "Body" }) do
		local v = currency(name)
		if v < bestVal then best, bestVal = name, v end
	end
	return best, bestVal
end

-- All three muscles ordered lowest first. The ascend gate is the lowest one, so
-- that is the muscle to feed - but eleven machines are shared with everyone else
-- on the server and all four of a type can be occupied, which stalled the trainer
-- until this fell through to the next one instead.
local function muscleOrder()
	local list = {}
	for _, name in ipairs({ "Arm", "Leg", "Body" }) do
		table.insert(list, { name = name, value = currency(name) })
	end
	table.sort(list, function(a, b) return a.value < b.value end)
	return list
end

local function canSpend(amount)
	return STATE.coin - CONFIG.coinKeep >= amount
end

local function loop(sec, key, fn)
	task.spawn(function()
		while GEN == _G.__TRAINCLIMB do
			if CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
			end
			task.wait(sec)
		end
	end)
end

--------------------------------------------------------------------------------
-- training
--------------------------------------------------------------------------------

local function machineParts()
	local fw = workspace:FindFirstChild("FrameWork_WorkSpace")
	local train = fw and fw:FindFirstChild("Train")
	local folder = train and train:FindFirstChild("PPPart")
	if not folder then return {} end
	local out = {}
	for _, part in ipairs(folder:GetChildren()) do
		local prompt = part:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt then
			table.insert(out, { part = part, prompt = prompt, kind = prompt:GetAttribute("Type") })
		end
	end
	return out
end

-- A machine is taken when its prompt carries somebody else's UserID; the prompt is
-- disabled at the same time, so both are checked rather than the name.
local function mount(kind)
	if plr:GetAttribute("PPType") == kind and plr:GetAttribute("PPName") then return true end

	local model, root = char()
	if not root then return false, "no character" end

	pcall(function() Remotes.Train.RE_ApplyTrainEnd:FireServer() end)
	task.wait(0.4)

	for _, m in ipairs(machineParts()) do
		local owner = m.prompt:GetAttribute("UserID")
		if m.kind == kind and (owner == nil or owner == plr.UserId) then
			local locate = m.part:FindFirstChild("Locate")
			local spot = (locate and locate.Position) or m.part.Position
			pcall(function() model:PivotTo(CFrame.new(spot + Vector3.new(0, 3, 0))) end)
			task.wait(0.6)
			pcall(function() fireproximityprompt(m.prompt) end)
			task.wait(1)
			if plr:GetAttribute("PPType") == kind then return true end
		end
	end
	return false, "no free " .. tostring(kind)
end

local trainRunning = false

local function startTrainer()
	if trainRunning then return end
	trainRunning = true
	task.spawn(function()
		while GEN == _G.__TRAINCLIMB do
			if CONFIG.auto and CONFIG.train and not STATE.busy then
				local order = muscleOrder()
				local wanted = MACHINE_OF[order[1].name]
				if plr:GetAttribute("PPType") ~= wanted then
					STATE.busy = true
					local ok, err
					for _, entry in ipairs(order) do
						ok, err = mount(MACHINE_OF[entry.name])
						if ok then break end
					end
					STATE.busy = false
					if not ok then note("mount: " .. tostring(err)) end
				end
				if plr:GetAttribute("PPName") and plr:GetAttribute("Move") ~= true then
					pcall(function()
						Remotes.Train.RE_ApplyOnceTrain:FireServer(CONFIG.trainPower)
					end)
				end
			end
			-- 0.3s is deliberate: faster credits LESS per call, the value lives in
			-- the argument and not in the call count.
			task.wait(0.3)
		end
		trainRunning = false
	end)
end

--------------------------------------------------------------------------------
-- income: the finish-battle payout and the trophies
--------------------------------------------------------------------------------

local incomeRunning = false

local function startIncome()
	if incomeRunning then return end
	incomeRunning = true
	task.spawn(function()
		local finish = Remotes.Battle:WaitForChild("RE_PlayerFinishBattle")
		local trophy = Remotes.Battle:WaitForChild("RE_PlayerTriggerTrophy")
		while GEN == _G.__TRAINCLIMB do
			if CONFIG.auto and CONFIG.coin then
				local n = math.clamp(CONFIG.coinPerFrame, 1, 300)
				for _ = 1, n do
					pcall(function() finish:FireServer(1) end)
				end
			end
			if CONFIG.auto and CONFIG.trophy then
				local n = math.clamp(CONFIG.trophyPerFrame, 1, 300)
				for _ = 1, n do
					pcall(function() trophy:FireServer() end)
				end
			end
			RunService.Heartbeat:Wait()
		end
		incomeRunning = false
	end)
end

--------------------------------------------------------------------------------
-- ascend
--------------------------------------------------------------------------------

local function ascendPass()
	local before = tonumber(stateValue("Rebirth")) or 0
	local level = before
	for _ = 1, 20 do
		local _, weakest = weakestMuscle()
		local okNeed, need = pcall(RebirthHelper.getNextLvNeedStrength, level)
		need = (okNeed and tonumber(need)) or math.huge
		if weakest < need then break end
		pcall(function() Remotes.Rebirth.RE_RebirthUpgradeRequest:FireServer() end)
		task.wait(1.1)
		local now = tonumber(stateValue("Rebirth")) or level
		if now == level then break end
		level = now
	end
	if level > before then
		STATE.phase = "ascended"
		note("ascend " .. before .. " -> " .. level .. "  x" .. tostring(STATE.ratio))
	end
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

local WEAPON_KEYS = {}
for i = 1, 17 do WEAPON_KEYS[i] = "key" .. i end

local function weaponInfo(key)
	local okR, robux = pcall(WeaponHelper.isRobuxWeapon, key)
	local okP, price = pcall(WeaponHelper.getWeaponPrice, key)
	local okC, coin = pcall(WeaponHelper.getWeaponCoinValue, key)
	if not (okR and okP and okC) then return nil end
	return { robux = robux == true, price = tonumber(price) or 0, coin = tonumber(coin) or 0 }
end

-- Ranking is against what is WORN, never against the cheapest unowned rung: the
-- coin multiplier is the only thing that matters here and a "best affordable"
-- sweep that ignores it buys a downgrade.
local function weaponPass()
	local ws = weaponStore()
	if not ws then return end
	local owned = ws.weaponList or {}

	local bought = false
	for _, key in ipairs(WEAPON_KEYS) do
		local info = weaponInfo(key)
		if info and not info.robux and owned[key] ~= true and canSpend(info.price) then
			pcall(function() Remotes.Weapon.RE_PurchaseWeaponRequest:FireServer(key) end)
			task.wait(0.8)
			STATE.spent = STATE.spent + info.price
			bought = true
			note("weapon " .. key .. " for " .. short(info.price))
		end
	end
	if bought then
		-- the client store lags 1-2s behind the server; without the refresh the
		-- next pass re-buys what it already owns
		pcall(function() Remotes.DataUpdate.RE_GetDataFromServer:FireServer("Weapon") end)
		task.wait(1.5)
		ws = weaponStore() or ws
		owned = ws.weaponList or owned
	end

	local best, bestCoin = nil, -1
	for key, has in pairs(owned) do
		if has == true then
			local info = weaponInfo(key)
			if info and info.coin > bestCoin then best, bestCoin = key, info.coin end
		end
	end
	if best and ws.current ~= best then
		pcall(function() Remotes.Weapon.RE_EnquipWeaponRequest:FireServer(best) end)
		note("equipped " .. best .. "  coin x" .. tostring(bestCoin))
	end
end

local function auraPass()
	local store = auraStore()
	local have = (store and store.have) or {}

	local best, bestScore = nil, -1
	for name, cfg in pairs(AuraConfig) do
		local price = tonumber(cfg.Coin)
		local isRobux = cfg.Robux and cfg.Robux ~= false and cfg.Robux ~= "false"
		if price and not isRobux then
			local add = cfg.Add or {}
			local score = (tonumber(add.Coin) or 1) * (tonumber(add.Power) or 1)
			if have[name] ~= true and canSpend(price) then
				pcall(function() Remotes.Aura.TryBuyAura:FireServer(name) end)
				task.wait(0.8)
				STATE.spent = STATE.spent + price
				note("aura " .. name .. " for " .. short(price))
				have[name] = true
			end
			if have[name] == true and score > bestScore then best, bestScore = name, score end
		end
	end
	if best and store and store.equip ~= best then
		pcall(function() Remotes.Aura.EquipAura:FireServer(best) end)
		note("aura equipped " .. best)
	end
end

-- The client never gets a coach ownership list, so this fires the purchase for
-- every affordable coin coach and lets the server sort it out: a second buy of
-- something already owned is refused and charges NOTHING (measured, twice).
local function coachPass()
	local store = coachStore()
	local best, bestScore = nil, -1

	for name, cfg in pairs(CoachConfig) do
		local price = tonumber(cfg.Coin)
		local isRobux = cfg.Robux and cfg.Robux ~= false and cfg.Robux ~= "false"
		if price and not isRobux then
			local add = cfg.Add or {}
			local score = (tonumber(add.Train) or 1) * (tonumber(add.Coin) or 1)
			if canSpend(price) then
				local before = currency("Coin")
				pcall(function() Remotes.Coach.TryBuyCoach:FireServer(name) end)
				task.wait(0.8)
				local paid = before - currency("Coin")
				if paid > 0 then
					STATE.spent = STATE.spent + paid
					note("coach " .. name .. " for " .. short(paid))
				end
				if score > bestScore then best, bestScore = name, score end
			end
		end
	end
	if best and STATE.coach ~= best then
		pcall(function() Remotes.Coach.EquipCoach:FireServer(best) end)
		STATE.coach = best
		note("coach equipped " .. best)
	end
end

local EGG_ORDER = { "Egg6", "Egg5", "Egg4", "Egg3", "Egg2", "Egg1" }

local function eggPass()
	local pd = petData()
	local held = 0
	for _ in pairs(pd.petList or {}) do held = held + 1 end
	if held >= (pd.capacity or 30) - 10 then return end

	for _, egg in ipairs(EGG_ORDER) do
		local okR, robux = pcall(EggHelper.isRobuxEgg, egg)
		local okP, price = pcall(EggHelper.getEggPrice, egg)
		price = (okP and tonumber(price)) or math.huge
		if okR and robux ~= true and canSpend(price * 10) then
			pcall(function() Remotes.Egg.RE_ApplyDrawEgg:FireServer(egg, 10) end)
			STATE.spent = STATE.spent + price * 10
			note("10x " .. egg .. " for " .. short(price * 10))
			return
		end
	end
end

local function petPass()
	pcall(function() Remotes.Pet.RE_EquipBestPetsRequest:FireServer() end)
	task.wait(1)

	-- fuse duplicates: same pet, same star, never one that is equipped
	local pd = petData()
	local groups = {}
	for key, pet in pairs(pd.petList or {}) do
		if not pet.equipped then
			local id = tostring(pet.petId) .. ":" .. tostring(pet.star)
			groups[id] = groups[id] or {}
			table.insert(groups[id], key)
		end
	end
	for _, keys in pairs(groups) do
		if #keys >= 5 then
			pcall(function() Remotes.Pet.RE_FusePetsRequest:FireServer(keys) end)
			task.wait(1)
			note("fused " .. #keys .. " duplicates")
			return
		end
	end
end

local function spendPass()
	if CONFIG.weapons then weaponPass() end
	if CONFIG.auras then auraPass() end
	if CONFIG.coaches then coachPass() end
	if CONFIG.eggs then eggPass() end
	if CONFIG.pets then petPass() end
end

--------------------------------------------------------------------------------
-- free rewards
--------------------------------------------------------------------------------

local function freePass()
	pcall(function() Remotes.Offline.ClaimOfflineReward:FireServer() end)
	pcall(function() Remotes.FriendReward.RE_ApplyFriendReward:FireServer() end)
	pcall(function() Remotes.Group.RE_ApplyGroupReward:FireServer() end)

	local daily = storeOf(DailyAPI.jumpOut, "days")
	if daily and daily.days then
		for day, state in pairs(daily.days) do
			if state == "ok" then
				pcall(function() Remotes.DaliyReward.RE_ClaimRewardRequest:FireServer(day) end)
				task.wait(0.3)
			end
		end
	end

	for i = 1, 8 do
		pcall(function() Remotes.OnlineReward.RE_ClaimOnlineRewardRequest:FireServer(i) end)
		task.wait(0.2)
	end

	for index, pack in pairs(PackConfig) do
		local free = pack.IsFree
		if free == true or free == "true" then
			pcall(function() Remotes.Pack.TryClaimPackReward:FireServer(index) end)
			task.wait(0.15)
		end
	end
end

--------------------------------------------------------------------------------
-- worlds
--------------------------------------------------------------------------------

-- The first call UNLOCKS and charges the trophies; the second one travels. The
-- travel is a place change, so the hub loader re-arms this script on the far side.
local function worldPass()
	local world = tonumber(stateValue("CurrentWorld")) or 1
	if world >= 2 then return end
	if currency("Trophy") < 5 then return end

	if not permission("World2") then
		pcall(function() Remotes.World.TryTeleportWorld:FireServer(2) end)
		task.wait(2.5)
	end
	if permission("World2") then
		note("travelling to world 2 - it pays ~295,000x")
		STATE.phase = "travelling"
		task.wait(1)
		pcall(function() Remotes.World.TryTeleportWorld:FireServer(2) end)
	end
end

--------------------------------------------------------------------------------
-- unstuck
--------------------------------------------------------------------------------

local function unstuck()
	CONFIG.auto = false
	STATE.busy = false
	pcall(function() Remotes.Train.RE_ApplyTrainEnd:FireServer() end)
	pcall(function() Remotes.Coach.ChangeCoachState:FireServer("Normal") end)
	local model, _, hum = char()
	if hum then
		pcall(function()
			hum.WalkSpeed = 22
			hum.JumpPower = 50
			hum.PlatformStand = false
		end)
	end
	if model then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then pcall(function() d.Anchored = false end) end
		end
	end
	plr:SetAttribute("Climb", false)
	note("unstuck, auto off")
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

startTrainer()
startIncome()

-- The read-out has to be live whether the farm runs or not, so this one is NOT
-- routed through loop() - that helper only ticks while CONFIG.auto is on.
task.spawn(function()
	while GEN == _G.__TRAINCLIMB do
		pcall(refresh)
		task.wait(0.5)
	end
end)

loop(20, "ascend", ascendPass)
loop(15, nil, function()
	if CONFIG.weapons or CONFIG.auras or CONFIG.coaches or CONFIG.eggs or CONFIG.pets then
		STATE.phase = "spending"
		spendPass()
		STATE.phase = CONFIG.auto and "farming" or "idle"
	end
end)
loop(180, "freebies", freePass)
loop(30, "worlds", worldPass)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__TRAINCLIMB_WIN then pcall(function() _G.__TRAINCLIMB_WIN:Destroy() end) end
for _, root in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui") }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "TrainClimbPanel" then pcall(function() g:Destroy() end) end
		end
	end
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("trainclimb", CONFIG)

local win = UI.Window({
	name = "TrainClimbPanel",
	title = "TRAIN", accentTitle = "CLIMB", subtitle = "seltonmt",
	badge = "💪", width = 820, height = 582,
})
_G.__TRAINCLIMB_WIN = win

local page = win:Page("FARM", UI.icon.bolt)

local POWER_STEPS = { 1.5, 5, 100, 1e4, 1e6, 1e9, 1e12 }

local main = page:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.phase = v and "farming" or "idle"
	note(v and "running" or "stopped")
end, "train, cash out, ascend, spend, repeat", UI.theme.good)
main:Toggle("Train", CONFIG.train, function(v) CONFIG.train = v end,
	"always feeds the weakest muscle, because that one is the ascend gate")
main:Stepper("Train power", function() return "x" .. short(CONFIG.trainPower) end, function(dir)
	local at = 1
	for i, v in ipairs(POWER_STEPS) do if v == CONFIG.trainPower then at = i end end
	CONFIG.trainPower = POWER_STEPS[math.clamp(at + dir, 1, #POWER_STEPS)]
end, "the multiplier sent to the server; x1.5 is what a real click sends")
main:Toggle("Cash out", CONFIG.coin, function(v) CONFIG.coin = v end,
	"finish-battle pays without climbing; the only income in the game", UI.theme.good)
main:Slider("Calls/frame", 1, 300, CONFIG.coinPerFrame, function(v)
	CONFIG.coinPerFrame = v
end)
main:Toggle("Trophies", CONFIG.trophy, function(v) CONFIG.trophy = v end,
	"one per call, no cooldown - the worlds are priced in these")

local spend = page:Card("SPENDING", 2)
spend:Toggle("Auto ascend", CONFIG.ascend, function(v) CONFIG.ascend = v end,
	"consumes nothing; the gate is the weakest of the three muscles", UI.theme.good)
spend:Toggle("Weapons", CONFIG.weapons, function(v) CONFIG.weapons = v end,
	"coin weapons only, then wears the highest coin multiplier owned")
spend:Toggle("Auras", CONFIG.auras, function(v) CONFIG.auras = v end,
	"coin auras only; the Robux ones are skipped by their own flag")
spend:Toggle("Coaches", CONFIG.coaches, function(v) CONFIG.coaches = v end,
	"coin coaches only")
spend:Toggle("Eggs", CONFIG.eggs, function(v) CONFIG.eggs = v end,
	"draws the best affordable coin egg ten at a time", UI.theme.warn)
spend:Toggle("Pets", CONFIG.pets, function(v) CONFIG.pets = v end,
	"equips the best three and fuses duplicates into stars")

local extra = page:Card("EXTRAS", 1)
extra:Toggle("Free rewards", CONFIG.freebies, function(v) CONFIG.freebies = v end,
	"daily, online, offline, friend, group and the free packs", UI.theme.good)
extra:Toggle("Travel worlds", CONFIG.worlds, function(v) CONFIG.worlds = v end,
	"world 2 costs 5 trophies and pays about 295,000 times world 1", UI.theme.good)
extra:Button("Ascend now", function()
	task.spawn(ascendPass)
end)
extra:Button("Buy now", function()
	task.spawn(spendPass)
end)
extra:Button("Claim rewards", function()
	task.spawn(freePass)
end)
extra:Button("Unstuck", unstuck, UI.theme.bad)

local out = page:Card("STATUS", 0):Readout(12, function(text)
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__TRAINCLIMB do
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase     " .. tostring(STATE.phase),
			"  world     " .. tostring(STATE.world) .. "   machine " .. tostring(STATE.machine)
				.. " (" .. tostring(STATE.muscle) .. ")",
			"  coin      " .. short(STATE.coin) .. "   " .. short(STATE.coinRate) .. "/s",
			"  power     " .. short(STATE.power) .. "   " .. short(STATE.powerRate) .. "/s",
			"  arm       " .. short(STATE.arm) .. "   leg " .. short(STATE.leg)
				.. "   body " .. short(STATE.body),
			"  ascend    lv" .. tostring(STATE.ascendLv) .. "   x" .. tostring(STATE.ratio)
				.. "   next " .. short(STATE.ascendNeed),
			"  trophy    " .. short(STATE.trophy),
			"  weapon    " .. tostring(STATE.weapon) .. "   coin x" .. tostring(STATE.coinMult),
			"  aura      " .. tostring(STATE.aura) .. "   coach " .. tostring(STATE.coach),
			"  pets      " .. STATE.petCount .. "   slots " .. STATE.petSlots,
			"  spent     " .. short(STATE.spent),
			"  " .. tostring(STATE.note),
		}
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s coin   power %s   lv%s   world %s   %s",
				short(STATE.coin), short(STATE.power), tostring(STATE.ascendLv),
				tostring(STATE.world), tostring(STATE.phase)))
		end)
		pcall(function()
			win:SetStat(1, short(STATE.coin), "coin")
			win:SetStat(2, short(STATE.power), "power")
			win:SetStat(3, tostring(STATE.ascendLv), "ascend")
		end)
		task.wait(0.5)
	end
end)

pcall(function()
	win:SetMaster(CONFIG.auto, "Auto Farm")
	win:OnMaster(function(on)
		CONFIG.auto = on
		STATE.phase = on and "farming" or "idle"
	end)
end)

pcall(function() win:Home() end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__TRAINCLIMB_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	refresh = refresh, short = short,
	mount = mount, machineParts = machineParts, weakestMuscle = weakestMuscle,
	ascendPass = ascendPass, spendPass = spendPass, freePass = freePass,
	weaponPass = weaponPass, auraPass = auraPass, coachPass = coachPass,
	eggPass = eggPass, petPass = petPass, worldPass = worldPass, unstuck = unstuck,
	currency = currency, weaponStore = weaponStore, auraStore = auraStore,
	coachStore = coachStore, petData = petData, stateValue = stateValue,
	permission = permission, storeOf = storeOf,
	MUSCLE_OF = MUSCLE_OF, MACHINE_OF = MACHINE_OF,
}

print("[trainclimb] gen " .. GEN .. " ready - RightShift for the panel")
