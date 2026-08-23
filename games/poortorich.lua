--!nocheck
-- poortorich.lua  --  "[💰] +1 Poor To Rich"  (place 96003649748017)
--
-- The whole game in one sentence: every step you take pays Cash and Speed-XP,
-- XP makes levels, levels make WalkSpeed and rebirths, the win pads at the end
-- of each of the thirteen stages pay Wins, and Wins buy the two permanent
-- multipliers - the held item ("Food") and the trail.
--
-- Everything below was measured against the server through the client's own data
-- API, which is the state oracle here:
--   require(ReplicatedStorage.Controllers.Data.DataAccessAPIClient):GetAPI()
--       :GetLocalProfile().Data
-- and it is complete: Wins, Rebirths, Currencies.Cash, Levels.Speed.{XP,Level},
-- Food.{Owned,Equipped}, Trails.{Owned,Equipped}. The player attributes mirror
-- the live multipliers (FoodMultiplier, TrailsMultiplier, WalkSpeed,
-- IsOnTreadmill) and are what the read-out shows.
--
-- Measured, all of it, with the automation off:
--   * INCOME IS MOVEMENT, not time. Standing still for 8s paid exactly 0. One
--     hum:Move() keeps paying by itself - the humanoid stays in a walking state
--     until the direction is changed, which is why the Cash kept climbing during
--     a snippet that never called Move again.
--   * The body does NOT have to travel. Pinned on one CFrame with hum:Move
--     running, the server credits every step: 1.05 cash/s at Carrot x1 with no
--     trail, 456/s at Golden Carrot x50 + 67 Trail x2.3, 3,597/s once the x3
--     treadmill was unlocked and the level had carried WalkSpeed to 90.
--   * THE WIN PADS ARE THE BIG LEVER AND THEY HAVE NO COOLDOWN WORTH THE NAME.
--     WinPart carries no TouchInterest - the touch is detected server side from
--     the body's position - so pinning on it pays about 4.3 times a second and
--     teleports the body back to spawn on every payout, which the pin undoes on
--     the next frame. Measured per stage, automation off:
--        stage 2  (+2)      6.8 wins/s        stage 10 (+500)     2,125/s
--        stage 6  (+35)     154/s             stage 11 (+1,000)   4,250/s
--        stage 9  (+200)    700/s             stage 12 (+2,000)   9,000/s
--                                             stage 13 (+10,000) 42,222/s
--     There is no level, speed or stage gate on any of them - stage 13 paid in
--     full at level 1.
--   * A STAGE THAT HAS NOT STREAMED IN YET PAYS NOTHING. The first 4s pin on
--     stage 13 credited exactly 0; the second, after the map around it had
--     loaded, credited 180,000. That is what the warm-up and the ladder below
--     are for - a stage that pays nothing is demoted, never hammered.
--   * Food is a real COST, not a threshold: Pumpkin took Wins 245,146 ->
--     145,146 and set FoodMultiplier 1 -> 40, auto-equipped. It is bought by
--     firing the stand's FoodPrompt with the body pinned next to it.
--   * Trails are a real cost too and need no body at all:
--     Net:RemoteEvent("TrailsBuy"):FireServer(name) charged 75 for the Fries
--     Trail and set TrailsMultiplier 1 -> 1.05, auto-equipped.
--   * Rebirth is Net:RemoteEvent("Rebirth"):FireServer() with NO arguments. It
--     needs Level >= 25 * (rebirths + 1) and it wipes Level, XP, Cash and
--     WalkSpeed while keeping Wins, Food and Trails. The multiplier is
--     GetRebirthInfo.GetMultiplier: 1 + 0.5 per rebirth to x5 at 8, then +0.1
--     each (x5.2 at 10, x6.2 at 20, x9.2 at 50, x14.2 at 100).
--   * The treadmills multiply the step award while the body is inside the zone
--     (the IsOnTreadmill attribute is the live proof). x1 Poor is free, x3 Trash
--     wants 2 rebirths and x5 Coin wants 5. Measured x3 against no treadmill in
--     the same minute: 3,597/s versus 677/s.
--   * ResetCharacterRemote:FireServer() rebuilds the character and is the
--     unstuck lever - the game rebuilds the body on every glow-up anyway, which
--     is why every loop here re-reads HumanoidRootPart instead of caching it.
--
-- Never touched, all Robux: DoubleWinModel on every stage (gamepass
-- 1796479170), the X10 / X27 / X50 treadmills (UnlockMode == "Product"), the
-- Premium food stands and every food entry carrying a DevProductId (Treasure
-- Chest, Gold Bars, Money Gun), the ShopGui coin packs and the AdsGui.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

--------------------------------------------------------------------------------
-- config / state
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,          -- master switch, drives the pin loop
	farmWins = true,       -- phase 1: pin on the deepest paying win pad
	gainCash = true,       -- phase 2: hum:Move on the best treadmill
	autoRebirth = true,
	autoFood = true,       -- the held item, wins-priced, x1 -> x50
	autoTrail = true,      -- the trail, wins-priced, x1.05 -> x2.3
	autoClaim = true,      -- offline earnings
	-- Wins buy nothing once both ladders are owned, so the farm normally moves on
	-- to levels. This keeps it on the pad anyway - wins are the leaderboard, and
	-- at 42K/s on stage 13 that is the only thing a board position costs.
	winsOnly = false,
	stage = 0,             -- 0 = the ladder picks, otherwise a fixed stage 2..13
}

local STATE = {
	note = "idle",
	phase = "-",           -- wins | level | shop
	target = nil,          -- Vector3 the pin writes every Heartbeat
	targetName = "-",
	wins = 0, cash = 0, level = 0, rebirths = 0, xp = 0,
	winsRate = 0, cashRate = 0,
	earned = 0,            -- cash ever gained; the balance itself is wiped by every
	lastCash = nil,        -- rebirth, so a rate read off it is 0 nearly all the time
	rateWins = nil, rateCash = nil, rateAt = nil,
	ladder = 13,           -- the stage the win farm is currently aiming at
	frontier = 13,         -- deepest stage that has ever paid
	stageSince = 0,        -- os.clock when the current stage was entered
	stageRef = 0,          -- wins at that moment
	food = "-", foodMult = 1,
	trail = "-", trailMult = 1,
	treadmill = "-", treadMult = 1,
	buying = nil,          -- name of the food stand the body is being walked to
	uiOwner = nil,
	blocked = nil,
	stalls = 0, stallRef = 0, stallAt = 0,
}

-- Re-executing does not restart the Lua VM, so the previous run's pin and loops
-- are still alive. Every loop captures this and exits when it stops matching.
_G.__P2R = (_G.__P2R or 0) + 1
local GEN = _G.__P2R

--------------------------------------------------------------------------------
-- the oracle and the remotes
--------------------------------------------------------------------------------

-- The executor runs at identity 8 and require() on a normal ModuleScript throws
-- there, so every require in this file goes through this one wrapper. The handle
-- is cached in _G because GetAPI() is not free and a re-execute must not build a
-- second one.
local function req(module)
	if setthreadidentity then pcall(setthreadidentity, 2) end
	local ok, value = pcall(require, module)
	if not ok then return nil, tostring(value) end
	return value
end

local function dataAPI()
	if _G.__P2R_API then return _G.__P2R_API end
	local client = ReplicatedStorage:WaitForChild("Controllers", 10)
	client = client and client:WaitForChild("Data", 10)
	client = client and client:WaitForChild("DataAccessAPIClient", 10)
	local mod = client and req(client)
	if not mod then return nil end
	local ok, handle = pcall(mod.GetAPI, mod)
	if ok and handle then _G.__P2R_API = handle end
	return _G.__P2R_API
end

-- Data.* is the server's own copy, replicated. Every before/after claim in the
-- header was read through here.
local function data()
	local api = dataAPI()
	if not api then return nil end
	local ok, p = pcall(api.GetLocalProfile, api)
	if not ok or type(p) ~= "table" then return nil end
	return p.Data
end

local Net = req(ReplicatedStorage:WaitForChild("Packages", 10):WaitForChild("Net", 10))
local remoteCache = {}
local function remote(name)
	if remoteCache[name] then return remoteCache[name] end
	if not Net then return nil end
	local ok, ev = pcall(function() return Net:RemoteEvent(name) end)
	if ok and ev then remoteCache[name] = ev end
	return remoteCache[name]
end

local function fire(name, ...)
	local ev = remote(name)
	if not ev then
		STATE.blocked = "remote " .. name .. " missing"
		return false
	end
	local args = table.pack(...)
	local ok, err = pcall(function() ev:FireServer(table.unpack(args, 1, args.n)) end)
	if not ok then STATE.note = name .. " failed: " .. tostring(err) end
	return ok
end

local RebirthInfo = req(ReplicatedStorage:WaitForChild("GetRebirthInfo", 10))
local FoodConfig = (function()
	local inv = ReplicatedStorage:WaitForChild("Inventory", 10)
	local food = inv and inv:WaitForChild("Food", 10)
	local cfg = food and food:WaitForChild("Config", 10)
	local mod = cfg and req(cfg)
	return mod and mod.FoodBalance or {}
end)()

-- Every trail is its own module. Costs.Wins is the free path; the ProductId
-- sitting next to it is only the other way to pay for the SAME trail, exactly
-- like the trails in Speed Monkey, so it is not a reason to skip an entry.
local TrailConfig = (function()
	local out = {}
	local inv = ReplicatedStorage:FindFirstChild("Inventory")
	local folder = inv and inv:FindFirstChild("Trails")
	if not folder then return out end
	for _, module in ipairs(folder:GetChildren()) do
		if module:IsA("ModuleScript") then
			local cfg = req(module)
			local price = cfg and cfg.Costs and cfg.Costs.Wins
			if cfg and type(price) == "number" and price > 0 then
				out[cfg.Name or module.Name] = {
					price = price,
					multi = cfg.SpeedMultiplier or 1,
					label = cfg.DisplayName or module.Name,
				}
			end
		end
	end
	return out
end)()

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------

local function short(n)
	if type(n) ~= "number" then return "?" end
	local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 1
	while n >= 1000 and i < #units do n = n / 1000 i = i + 1 end
	if i == 1 then return string.format("%d", n) end
	return string.format("%.2f%s", n, units[i])
end

-- The game rebuilds the whole character on every glow-up (a level can do it),
-- and for a second or two the model has a Humanoid and no body parts at all.
-- Nothing here may cache the HumanoidRootPart; that is what left an earlier
-- probe writing CFrames onto a destroyed part.
local function char()
	local c = plr.Character
	if not c then return nil end
	return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end

local function attr(name, fallback)
	local v = plr:GetAttribute(name)
	if v == nil then return fallback end
	return v
end

local function withUI(name, fn)
	if STATE.uiOwner then return false end
	STATE.uiOwner = name
	local ok, err = pcall(fn)
	STATE.uiOwner = nil
	if not ok then STATE.note = name .. " failed: " .. tostring(err) end
	return ok
end

--------------------------------------------------------------------------------
-- the map
--------------------------------------------------------------------------------

-- Workspace.StreamingEnabled is on and the corridor is 2,500 studs long, so the
-- deep stages simply do not exist until the body has been near them. These are
-- the measured positions of every WinPart, used as the target while the real
-- part is still streamed out; the live part always wins once it appears.
local WIN_FALLBACK = {
	[2] = Vector3.new(-527, 76, 1360),
	[3] = Vector3.new(-527, 76, 1200),
	[4] = Vector3.new(-527, 76, 1040),
	[5] = Vector3.new(-527, 76, 865),
	[6] = Vector3.new(-527, 76, 590),
	[7] = Vector3.new(-527, 76, 430),
	[8] = Vector3.new(-527, 76, 270),
	[9] = Vector3.new(-527, 101, 55),
	[10] = Vector3.new(-527, 101, -105),
	[11] = Vector3.new(-527, 101, -265),
	[12] = Vector3.new(-527, 101, -425),
	[13] = Vector3.new(-528, 74, -896),
}

-- What each pad is worth, read off its own billboard when it is loaded and
-- remembered in _G so a streamed-out stage still shows its value in the panel.
_G.__P2R_PAY = _G.__P2R_PAY or {
	[2] = 2, [3] = 4, [4] = 10, [5] = 20, [6] = 35, [7] = 50,
	[8] = 100, [9] = 200, [10] = 500, [11] = 1000, [12] = 2000, [13] = 10000,
}
local PAY = _G.__P2R_PAY

local function stagesFolder()
	local map = Workspace:FindFirstChild("MapPoorRich")
	return map and map:FindFirstChild("Stage's")
end

-- WinModel is the free pad. DoubleWinModel sits right beside it, pays double and
-- is the gamepass twin (DoubleWinsGamePassId 1796479170) - resolving "the first
-- WinPart under StageButton" would find it about half the time, so the model is
-- named explicitly.
local function winPart(stage)
	local folder = stagesFolder()
	local entry = folder and folder:FindFirstChild(tostring(stage))
	local button = entry and entry:FindFirstChild("StageButton")
	local model = button and button:FindFirstChild("WinModel")
	if not model then return nil end
	local part = model:FindFirstChild("WinPart", true)
	if not (part and part:IsA("BasePart")) then return nil end
	local label = model:FindFirstChild("Top", true)
	if label and label:IsA("TextLabel") then
		local n = tonumber((label.Text:gsub("[^%d]", "")))
		if n and n > 0 then PAY[stage] = n end
	end
	return part
end

local function winTarget(stage)
	local part = winPart(stage)
	if part then return part.Position + Vector3.new(0, 3, 0), true end
	local guess = WIN_FALLBACK[stage]
	if guess then
		pcall(function() plr:RequestStreamAroundAsync(guess) end)
		return guess + Vector3.new(0, 3, 0), false
	end
	return nil, false
end

-- The treadmill zones are models with one Info part carrying the whole rule:
-- TreadmillMultiplier, RequiredRebirths and UnlockMode. UnlockMode == "Product"
-- is the Robux gate (X10 / X27 / X50) and is filtered on the FIELD, never on the
-- name - Gold, Diamond and Robux are the three paid ones and nothing in their
-- names says so.
-- THE SPAWN IS STREAMED OUT WHILE THE BODY IS ON A DEEP STAGE. Stage 13 sits
-- ~2,500 studs down the corridor and from there the whole training area and the
-- food stands have no parts inside them at all - the first build read "no
-- treadmill" and could not find a single stand while both were plainly there on
-- screen a minute earlier. So every position is cached in _G the moment it is
-- readable, and the cache is what the phase switch aims at; the live part takes
-- over again as soon as it has streamed back in.
-- ...and a cache that is empty is not good enough either: executing the script
-- while the body already stands on stage 13 leaves nothing to cache and the
-- first build then reported "no treadmill" forever, because Workspace's own
-- SpawnLocation is streamed out from there too. These are the measured
-- positions of the three FREE zones and of every wins-priced food stand, used
-- only until the real parts are readable again.
local TREAD_FALLBACK = {
	{ name = "Poor", multi = 1, need = 0, stand = Vector3.new(-585, 86, 1561) },
	{ name = "Trash", multi = 3, need = 2, stand = Vector3.new(-585, 86, 1589) },
	{ name = "Coin", multi = 5, need = 5, stand = Vector3.new(-585, 86, 1533) },
}

local STAND_FALLBACK = {
	["Carrot"] = Vector3.new(-435, 77, 1537),
	["Broccolli"] = Vector3.new(-435, 77, 1549),
	["Milk"] = Vector3.new(-435, 77, 1561),
	["Tomato"] = Vector3.new(-435, 77, 1573),
	["Protein Bar"] = Vector3.new(-435, 77, 1585),
	["Protein Drink"] = Vector3.new(-420, 81, 1537),
	["Energy Drink"] = Vector3.new(-420, 81, 1549),
	["Grape"] = Vector3.new(-420, 81, 1561),
	["Lettuce"] = Vector3.new(-420, 81, 1573),
	["Watermelon"] = Vector3.new(-420, 81, 1585),
	["Pumpkin"] = Vector3.new(-407, 85, 1552),
	["Golden Carrot"] = Vector3.new(-407, 85, 1569),
}

_G.__P2R_CACHE = _G.__P2R_CACHE or { treadmills = {}, stands = {} }
local CACHE = _G.__P2R_CACHE
for key, pos in pairs(STAND_FALLBACK) do
	if not CACHE.stands[key] then CACHE.stands[key] = pos end
end

local function treadmillZones()
	local out = {}
	local map = Workspace:FindFirstChild("MapPoorRich")
	local spawn = map and map:FindFirstChild("Spawn")
	local training = spawn and spawn:FindFirstChild("Training")
	local function consider(part)
		if not (part and part:IsA("BasePart")) then return end
		local a = part:GetAttributes()
		if a.UnlockMode == "Product" or a.ProductId or a.AttributeId then return end
		local name = part.Parent and part.Parent.Name or part.Name
		local zone = {
			multi = tonumber(a.TreadmillMultiplier) or 1,
			need = tonumber(a.RequiredRebirths) or 0,
			name = name,
			stand = part.Position + Vector3.new(0, part.Size.Y / 2 + 2, 0),
		}
		CACHE.treadmills[name] = zone
		out[#out + 1] = zone
	end
	if training then
		for _, model in ipairs(training:GetChildren()) do
			consider(model:FindFirstChild("Info", true))
		end
	end
	local flat = Workspace:FindFirstChild("TreadmillParts")
	if flat and #out == 0 then
		for _, part in ipairs(flat:GetChildren()) do consider(part) end
	end
	if #out == 0 then
		for _, zone in pairs(CACHE.treadmills) do out[#out + 1] = zone end
	end
	if #out == 0 then
		for _, zone in ipairs(TREAD_FALLBACK) do out[#out + 1] = zone end
	end
	return out
end

local function bestTreadmill()
	local pick
	for _, zone in ipairs(treadmillZones()) do
		if zone.need <= STATE.rebirths and (not pick or zone.multi > pick.multi) then
			pick = zone
		end
	end
	if not pick then return nil end
	pcall(function() plr:RequestStreamAroundAsync(pick.stand) end)
	return pick.stand, pick
end

--------------------------------------------------------------------------------
-- the pin
--------------------------------------------------------------------------------

-- One connection does the whole farm. The win pad teleports the body back to
-- spawn on every payout, so the pin is not a convenience here - it IS the
-- cadence, and a frame without it costs a payout.
local pinConn
local function startPin()
	if pinConn then pinConn:Disconnect() end
	pinConn = RunService.Heartbeat:Connect(function()
		if GEN ~= _G.__P2R then pinConn:Disconnect() return end
		if not CONFIG.auto then return end
		local _, hrp, hum = char()
		if hrp and STATE.target then
			hrp.CFrame = CFrame.new(STATE.target)
		end
		-- Movement only outside the wins phase. The 42K/s on stage 13 was
		-- measured with the humanoid standing still, and nothing about that
		-- number is worth risking for the few hundred cash a second the walk
		-- would add on top.
		if hum and CONFIG.gainCash and STATE.phase ~= "wins" then
			hum:Move(Vector3.new(0, 0, -1), false)
		end
	end)
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

-- Robux food carries a DevProductId; the wins ladder is everything else, from
-- Carrot x1 (free) to Golden Carrot x50 at 500,000 wins. WinsRequired is the
-- price and it really is deducted.
local function foodLadder()
	local out = {}
	for key, entry in pairs(FoodConfig) do
		if type(entry) == "table" and not entry.DevProductId and entry.SpeedMultiplier then
			out[#out + 1] = {
				key = key,
				label = entry.DisplayName or key,
				multi = entry.SpeedMultiplier,
				price = entry.WinsRequired or 0,
			}
		end
	end
	table.sort(out, function(a, b) return a.multi > b.multi end)
	return out
end

local function foodStand(key)
	local map = Workspace:FindFirstChild("MapPoorRich")
	local spawn = map and map:FindFirstChild("Spawn")
	local folder = spawn and spawn:FindFirstChild("Folder")
	local stand = folder and folder:FindFirstChild("FoodStand")
	stand = stand and stand:FindFirstChild("FoodsStand")
	if not stand then return nil end
	for _, model in ipairs(stand:GetChildren()) do
		local part = model:FindFirstChild("Part35")
		local name = part and part:GetAttribute("Name")
		if name then CACHE.stands[name] = part.Position end
		if name == key then
			return part, part:FindFirstChild("FoodPrompt")
		end
	end
	return nil
end

-- The best food the balance covers and that beats what is worn. Ranked on the
-- multiplier, never on the price: the ladder happens to agree, but reading the
-- config is what keeps it honest if the dev reshuffles it.
local function nextFood(d)
	local owned = (d.Food and d.Food.Owned) or {}
	local worn = FoodConfig[(d.Food and d.Food.Equipped and d.Food.Equipped["1"]) or ""] or {}
	local wornMulti = worn.SpeedMultiplier or 0
	local pick
	for _, entry in ipairs(foodLadder()) do
		if not owned[entry.key] and entry.multi > wornMulti then
			if not pick or entry.multi > pick.multi then pick = entry end
		end
	end
	return pick, wornMulti
end

-- A prompt is validated against the SERVER's copy of the position, so a single
-- CFrame write is not enough - the body is held next to the stand for a moment
-- first. That is the same rule the rest of this repo hit on every prompt.
local function buyFood()
	if not CONFIG.autoFood then return end
	local d = data()
	if not d then return end
	local pick = nextFood(d)
	if not pick then return end
	if pick.price > (d.Wins or 0) then return end
	local part, prompt = foodStand(pick.key)
	local known = CACHE.stands[pick.key]
	if not (part or known) then
		STATE.blocked = "no stand for " .. pick.key
		return
	end
	withUI("food", function()
		STATE.buying = pick.key
		STATE.phase = "shop"
		STATE.target = ((part and part.Position) or known) + Vector3.new(0, 3, 4)
		STATE.targetName = "stand " .. pick.label
		STATE.note = "buying " .. pick.label .. " x" .. pick.multi .. " for " .. short(pick.price)
		-- Coming back from stage 13 the whole spawn is still streamed out, so the
		-- pin flies to the cached position first and the prompt is only resolved
		-- once the stand has actually loaded around the body.
		pcall(function() plr:RequestStreamAroundAsync(STATE.target) end)
		for _ = 1, 12 do
			task.wait(0.5)
			if not prompt then part, prompt = foodStand(pick.key) end
			if prompt then break end
		end
		if not prompt then
			STATE.blocked = "stand " .. pick.key .. " never streamed in"
			STATE.buying = nil
			return
		end
		task.wait(1.5)
		pcall(fireproximityprompt, prompt)
		task.wait(2)
		local after = data()
		local owned = after and after.Food and after.Food.Owned or {}
		if owned[pick.key] then
			STATE.note = "food " .. pick.label .. " x" .. pick.multi
			STATE.blocked = nil
		else
			STATE.blocked = "stand refused " .. pick.label
		end
		STATE.buying = nil
	end)
end

-- Trails need no body: the remote takes the internal name and charges the wins.
local function buyTrail()
	if not CONFIG.autoTrail then return end
	local d = data()
	if not d then return end
	local owned = (d.Trails and d.Trails.Owned) or {}
	local wornName = (d.Trails and d.Trails.Equipped and d.Trails.Equipped["1"]) or ""
	local worn = TrailConfig[wornName]
	local wornMulti = worn and worn.multi or 0
	local pickName, pick
	for name, entry in pairs(TrailConfig) do
		if not owned[name] and entry.multi > wornMulti and entry.price <= (d.Wins or 0) then
			if not pick or entry.multi > pick.multi then pickName, pick = name, entry end
		end
	end
	if not pick then return end
	if fire("TrailsBuy", pickName) then
		task.wait(1)
		STATE.note = "trail " .. pick.label .. " x" .. pick.multi .. " for " .. short(pick.price)
	end
end

-- What the wins are still FOR. Once the top food and the top trail are owned
-- nothing in this game takes wins any more, so the farm stops paying for itself
-- and the body belongs on a treadmill instead.
local function wantsWins(d)
	if CONFIG.winsOnly then return true, math.huge end
	if not d then return false, 0 end
	local need = 0
	local pick = nextFood(d)
	if CONFIG.autoFood and pick then need = math.max(need, pick.price) end
	if CONFIG.autoTrail then
		local owned = (d.Trails and d.Trails.Owned) or {}
		local wornName = (d.Trails and d.Trails.Equipped and d.Trails.Equipped["1"]) or ""
		local wornMulti = (TrailConfig[wornName] and TrailConfig[wornName].multi) or 0
		for name, entry in pairs(TrailConfig) do
			if not owned[name] and entry.multi > wornMulti then
				need = math.max(need, entry.price)
			end
		end
	end
	return need > 0 and (d.Wins or 0) < need, need
end

--------------------------------------------------------------------------------
-- progression
--------------------------------------------------------------------------------

local function levelRequirement(rebirths)
	if not RebirthInfo then return math.huge end
	local ok, need = pcall(RebirthInfo.GetLevelRequirement, rebirths)
	return ok and tonumber(need) or math.huge
end

local function rebirthMultiplier(rebirths)
	if not RebirthInfo then return 1 end
	local ok, m = pcall(RebirthInfo.GetMultiplier, rebirths)
	return ok and tonumber(m) or 1
end

-- Bare FireServer, no arguments. Refused below the level, silently, so the check
-- is done here rather than firing hopefully.
local function tryRebirth()
	if not CONFIG.autoRebirth then return end
	local need = levelRequirement(STATE.rebirths + 1)
	if STATE.level < need then return end
	fire("Rebirth")
	task.wait(1)
	local d = data()
	if d and (d.Rebirths or 0) > STATE.rebirths then
		STATE.note = "rebirth " .. d.Rebirths .. " (x" .. rebirthMultiplier(d.Rebirths) .. ")"
		STATE.blocked = nil
	end
end

local function claimFree()
	if not CONFIG.autoClaim then return end
	fire("OfflineEarnClaim")
end

--------------------------------------------------------------------------------
-- the stage ladder
--------------------------------------------------------------------------------

-- A stage pays nothing until the map around it has streamed in - the first pin
-- on stage 13 credited exactly 0 and the second, seconds later, credited
-- 180,000. So a silent stage is given a warm-up and then demoted one step
-- rather than hammered, and a stage that pays is remembered as the frontier so
-- the climb back is immediate.
local WARMUP = 6

local function enterStage(stage)
	STATE.ladder = math.clamp(stage, 2, 13)
	STATE.stageSince = os.clock()
	STATE.stageRef = STATE.wins
end

local function ladderStep(now)
	if CONFIG.stage > 0 then
		if STATE.ladder ~= CONFIG.stage then enterStage(CONFIG.stage) end
		return
	end
	local elapsed = now - (STATE.stageSince or now)
	if elapsed < WARMUP then return end
	if STATE.wins > STATE.stageRef then
		-- Paying. Every stage is worth strictly more than the one before it and
		-- none of them is gated, so a paying stage below 13 is only ever a
		-- leftover from a demotion - climb straight back out of it.
		STATE.frontier = math.max(STATE.frontier, STATE.ladder)
		if STATE.ladder < 13 then
			enterStage(STATE.ladder + 1)
		else
			STATE.stageRef = STATE.wins
			STATE.stageSince = now
		end
		return
	end
	-- silent for a whole warm-up window: drop one and try again, and let the
	-- next pass climb back the moment the deeper one starts paying.
	if STATE.ladder > 2 then
		enterStage(STATE.ladder - 1)
		STATE.note = "stage " .. (STATE.ladder + 1) .. " silent, down to " .. STATE.ladder
	else
		STATE.stageSince = now
	end
end

--------------------------------------------------------------------------------
-- the phase picker - one body, one target
--------------------------------------------------------------------------------

-- There is exactly one character and both halves of the game want it, so the
-- target is decided in one place. Shopping outranks everything (it is seconds),
-- then the wins phase while anything is still unaffordable, then the levels.
local function retarget(now)
	if STATE.buying then return end
	local d = data()
	local needWins = select(1, wantsWins(d))
	if CONFIG.farmWins and needWins then
		if STATE.phase ~= "wins" then
			STATE.phase = "wins"
			enterStage(math.max(STATE.frontier, 2))
		end
		ladderStep(now)
		local target, live = winTarget(STATE.ladder)
		if target then
			STATE.target = target
			STATE.targetName = "stage " .. STATE.ladder .. " (+" ..
				short(PAY[STATE.ladder] or 0) .. ")" .. (live and "" or " streaming")
		end
		return
	end
	STATE.phase = "level"
	local target, zone = bestTreadmill()
	if target then
		STATE.target = target
		STATE.treadmill = zone.name
		STATE.treadMult = zone.multi
		STATE.targetName = zone.name .. " treadmill x" .. zone.multi
	else
		-- Nothing cached yet and nothing loaded - that only happens when the
		-- script is executed while the body is already deep in the corridor.
		-- Walking back to the spawn is what makes the training area exist.
		local spawnPart = Workspace:FindFirstChild("SpawnLocation")
		STATE.treadmill = "-"
		STATE.treadMult = 1
		if spawnPart then
			STATE.target = spawnPart.Position + Vector3.new(0, 4, 0)
			STATE.targetName = "spawn (streaming the treadmills in)"
		else
			STATE.targetName = "no treadmill"
		end
	end
end

--------------------------------------------------------------------------------
-- watchdog
--------------------------------------------------------------------------------

-- The honest signal is a server value moving: wins while farming wins, cash
-- while levelling. A counter this script keeps itself proves nothing.
local STALL_SECONDS = 90

local function unstuck()
	CONFIG.auto = false
	local _, hrp, hum = char()
	if hrp then
		hrp.Anchored = false
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
	if hum then
		hum.PlatformStand = false
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	fire("ResetCharacterRemote")
	STATE.target = nil
	STATE.targetName = "-"
	STATE.note = "unstuck, auto off"
end

local function watchdog(now)
	if not CONFIG.auto or STATE.buying then
		STATE.stallAt = now
		return
	end
	-- earned, not cash: the balance is wiped by every rebirth and a watchdog
	-- watching it would call a perfectly healthy farm stalled every time.
	local progress = STATE.phase == "wins" and STATE.wins or STATE.earned
	if progress > (STATE.stallRef or 0) then
		STATE.stallRef, STATE.stallAt = progress, now
		return
	end
	STATE.stallAt = STATE.stallAt or now
	if now - STATE.stallAt < STALL_SECONDS then return end

	STATE.stalls = (STATE.stalls or 0) + 1
	STATE.stallAt = now
	STATE.stallRef = 0
	-- A rebirth zeroes the cash, so the levelling phase legitimately looks
	-- stalled for a moment; rebuilding the character is cheap and fixes the one
	-- case that is not legitimate - a body that never finished respawning.
	fire("ResetCharacterRemote")
	STATE.target = nil
	retarget(now)
	STATE.note = "stall " .. STATE.stalls .. ": rebuilt character, target " .. tostring(STATE.targetName)
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(interval, key, fn)
	task.spawn(function()
		while GEN == _G.__P2R do
			if CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then STATE.note = tostring(err) end
			end
			task.wait(interval)
		end
	end)
end

local RATE_WINDOW = 10

-- fast: read the oracle, keep the target honest, take every rebirth on offer
loop(1, nil, function()
	local d = data()
	if d then
		STATE.wins = d.Wins or 0
		STATE.cash = (d.Currencies and d.Currencies.Cash) or 0
		STATE.rebirths = d.Rebirths or 0
		local levels = d.Levels and d.Levels.Speed
		STATE.level = (levels and levels.Level) or 0
		STATE.xp = (levels and levels.XP) or 0
		STATE.food = (d.Food and d.Food.Equipped and d.Food.Equipped["1"]) or "-"
		STATE.trail = (d.Trails and d.Trails.Equipped and d.Trails.Equipped["1"]) or "-"
		-- A rebirth sets the cash back to zero, so only the rises are counted.
		if STATE.lastCash and STATE.cash > STATE.lastCash then
			STATE.earned = STATE.earned + (STATE.cash - STATE.lastCash)
		end
		STATE.lastCash = STATE.cash
	end
	STATE.foodMult = attr("FoodMultiplier", 1)
	STATE.trailMult = attr("TrailsMultiplier", 1)
	local now = os.clock()
	if STATE.rateAt == nil or now - STATE.rateAt >= RATE_WINDOW then
		if STATE.rateAt and now > STATE.rateAt then
			local span = now - STATE.rateAt
			local w = (STATE.wins - (STATE.rateWins or STATE.wins)) / span
			local c = (STATE.earned - (STATE.rateCash or STATE.earned)) / span
			if w >= 0 then STATE.winsRate = w end
			if c >= 0 then STATE.cashRate = c end
		end
		STATE.rateWins, STATE.rateCash, STATE.rateAt = STATE.wins, STATE.earned, now
	end
	retarget(now)
	tryRebirth()
	watchdog(now)
end)

-- slow: the things that only change every so often, and that move the body
loop(8, nil, function()
	buyTrail()
	buyFood()
end)

loop(300, "autoClaim", claimFree)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__P2R_WIN then pcall(function() _G.__P2R_WIN:Destroy() end) end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("poortorich", CONFIG)

local win = UI.Window({
	title = "POOR", accentTitle = "TO RICH", subtitle = "seltonmt",
	badge = "💰", width = 820, height = 582,
})
_G.__P2R_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local main = farm:Card("LOOP", 1):Accent()
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.note = v and "running" or "stopped"
end, "one body: wins first, then levels on the treadmill", UI.theme.good)
main:Toggle("Farm wins", CONFIG.farmWins, function(v) CONFIG.farmWins = v end,
	"pin on the deepest win pad, ~4.3 payouts a second")
main:Toggle("Gain cash", CONFIG.gainCash, function(v) CONFIG.gainCash = v end,
	"hum:Move on the treadmill - standing still pays exactly 0")
main:Stepper("Stage", function()
	return CONFIG.stage == 0 and "Ladder" or ("Stage " .. CONFIG.stage)
end, function(dir)
	local want = CONFIG.stage + dir
	if want < 2 then want = 0 end
	CONFIG.stage = math.clamp(want, 0, 13)
end, "0 = climb by itself, 13 pays +10,000 per touch")

local prog = farm:Card("PROGRESSION", 2)
prog:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
	"needs level 25 x (rebirths + 1), wipes level and cash", UI.theme.warn)
prog:Toggle("Claim offline", CONFIG.autoClaim, function(v) CONFIG.autoClaim = v end,
	"offline earnings, every five minutes")
prog:Label("treadmills: x1 free, x3 at 2 rebirths, x5 at 5")
prog:Button("Unstuck", unstuck, UI.theme.bad)

local spend = farm:Card("WINS SPENDING", 1)
spend:Toggle("Auto food", CONFIG.autoFood, function(v) CONFIG.autoFood = v end,
	"the held item, x1 Carrot to x50 Golden Carrot at 500K", UI.theme.warn)
spend:Toggle("Auto trail", CONFIG.autoTrail, function(v) CONFIG.autoTrail = v end,
	"x1.05 at 75 wins to x2.3 at 75K, stacks with the food", UI.theme.warn)
spend:Toggle("Nur Wins farmen", CONFIG.winsOnly, function(v) CONFIG.winsOnly = v end,
	"bleibt für das Leaderboard auf dem Feld, ~42K Wins/s auf Stage 13", UI.theme.good)
spend:Label("Robux food and the DoubleWin pads are never touched")

local out = farm:Card("STATUS", 0):Readout(14, function(text)
	if text:find("blocked") then return UI.theme.bad end
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__P2R do
		local need = levelRequirement(STATE.rebirths + 1)
		local _, want = wantsWins(data())
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase    " .. STATE.phase .. "   " .. tostring(STATE.targetName),
			"  wins     " .. short(STATE.wins) .. "   " .. short(STATE.winsRate) .. "/s",
			"  cash     " .. short(STATE.cash) .. "   " .. short(STATE.cashRate) .. "/s   (" ..
				short(STATE.earned) .. " earned)",
			"  level    " .. STATE.level .. (need < math.huge and ("  -> rebirth at " .. need) or ""),
			"  rebirth  " .. STATE.rebirths .. "   x" .. rebirthMultiplier(STATE.rebirths),
			"  food     " .. STATE.food .. "  x" .. short(STATE.foodMult),
			"  trail    " .. STATE.trail .. "  x" .. STATE.trailMult,
			"  treadmill " .. STATE.treadmill .. "  x" .. STATE.treadMult ..
				(attr("IsOnTreadmill", false) and "  (on)" or ""),
			"  walkspeed " .. string.format("%.0f", attr("WalkSpeed", 0)),
			"  ladder   stage " .. STATE.ladder .. ", frontier " .. STATE.frontier,
			"  next buy " .. (CONFIG.winsOnly and "wins only (leaderboard)"
				or (want > 0 and want < math.huge and short(want) .. " wins" or "all owned")),
			"  watchdog " .. STATE.stalls .. " stalls",
			"  " .. tostring(STATE.note),
		}
		if STATE.blocked then lines[#lines + 1] = "  blocked  " .. STATE.blocked end
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s wins   %s cash   lvl %d   reb %d   %s",
				short(STATE.wins), short(STATE.cash), STATE.level, STATE.rebirths, STATE.targetName))
		end)
		task.wait(0.5)
	end
end)

pcall(function() win:Home() end)

win:SetStat(1, "-", "wins")
win:SetStat(2, "-", "cash/s")
win:SetStat(3, "-", "rebirths")
win:SetMaster(CONFIG.auto, CONFIG.auto and "Auto Farm läuft" or "Gestoppt")
win:OnMaster(function(on)
	CONFIG.auto = on
	STATE.note = on and "running" or "stopped"
	win:Refresh()
end)
task.spawn(function()
	while GEN == _G.__P2R do
		pcall(function()
			win:SetStat(1, short(STATE.wins))
			win:SetStat(2, short(STATE.cashRate) .. "/s")
			win:SetStat(3, tostring(STATE.rebirths))
			win:SetMaster(CONFIG.auto, CONFIG.auto and "Auto Farm läuft" or "Gestoppt")
		end)
		task.wait(1)
	end
end)

win:Refresh()
startPin()

-- Seed the position cache while the body is still wherever it started, which on
-- a fresh join is the spawn with everything around it loaded.
pcall(treadmillZones)
pcall(foodStand, "Carrot")

--------------------------------------------------------------------------------

_G.__P2R_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	data = data, fire = fire, remote = remote,
	retarget = retarget, tryRebirth = tryRebirth, buyFood = buyFood, buyTrail = buyTrail,
	wantsWins = wantsWins, nextFood = nextFood, foodLadder = foodLadder,
	foodStand = foodStand, winPart = winPart, winTarget = winTarget,
	treadmillZones = treadmillZones, bestTreadmill = bestTreadmill,
	levelRequirement = levelRequirement, rebirthMultiplier = rebirthMultiplier,
	ladderStep = ladderStep, enterStage = enterStage, watchdog = watchdog,
	claimFree = claimFree, unstuck = unstuck, withUI = withUI,
	TrailConfig = TrailConfig, FoodConfig = FoodConfig, PAY = PAY,
}

print("[poortorich] gen " .. GEN .. " ready - RightShift for the panel")
