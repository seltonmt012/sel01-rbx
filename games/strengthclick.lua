--[[ strengthclick.lua - "[💪] +1 Strength Per Click" (place 120766736586332)

  The loop the game actually runs:

      click  -> Strength -> Level  (Level is what makes a click worth more)
      Strength -> break the walls of your lane -> the lane advances by ITSELF
      the win pad at the end of a lane pays BaseConfig.Wins[lane] and ends the run
      Wins -> title rolls, upgrades, eggs, and rebirths (1000 Wins = 1 Rebirth)
      Rebirths -> stronger training zones -> a permanent strength multiplier

  Everything below was measured through the bridge before it was written down.
  The five findings that shape this file:

  * ClickRemote:FireServer() takes no arguments, has no position check and - unlike
    every other clicker in this repo - NO server throttle. 40 calls/s credited 240
    of 240; 25 calls per frame still credited every one. The ceiling is the client
    frame rate (~75 calls/s), so more than a handful per frame buys nothing.

  * CLEARING A LANE'S WALLS ADVANCES THE LANE ON ITS OWN. Measured: Lane3 -> Lane8
    in 21 seconds without ever touching a win pad. The first version of this loop
    claimed after every lane and earned 3 wins/s; climbing first and claiming once
    at the bottom earned 1500 wins in a single touch. Never claim early.

  * The win pad pays Wins[the lane you are CURRENTLY in] and does not care whether
    that lane's walls are broken - a run that stalled on Lane8 still paid its full
    1500 - and it resets you to Lane1. So a run ends on a STALL, not on a timer.
    firetouchinterest reaches it from 183 studs; no walking.

  * Walls are hit by the game's OWN client loop (WallClient raycasts 20 studs down
    -Z into workspace.Stage[Lane]), so standing in front of a wall is the whole
    input. DamageWall:FireServer() is fired here as well, but SERVER_HIT_COOLDOWN
    is 0.4s, which also caps the Punch Speed upgrade at level 10 (value 2.5).

  * Rebirth converts ALL wins at once: 2121 wins became 2 rebirths and the 121
    remainder was destroyed. Since the rate is linear, banking to a milestone and
    rebirthing once costs the same wins but only one strength reset. The milestones
    are the training zones: 1, 25, 200, 5000, 100000, 10000000 rebirths.

  * The training multiplier only applies WHILE the body stands in the zone, and it
    drops back to 1 the moment the climb warps away - so the run is two phases,
    train then climb, not one. (It looked sticky at first only because the test
    disconnected the pin without ever moving the character out.) A zone above your
    rebirth count sets the multiplier to 1, which is worse than entering none at
    all; the gamepass zones (x3, x10, x250) carry Rebirth = 99999999999999 and are
    filtered by that attribute, never by name.

  Never spends Robux: every Buy*Strength / BuyMultiplier / Buy*Roll / BuyRobuxEgg /
  SkipRebirth / BuyPotion remote, the "Robux" argument of BuyUpgrade and
  TeleportToLane, and any egg whose Currency is not Wins.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

local GEN = (_G.__STRCLICK or 0) + 1
_G.__STRCLICK = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,
	click = true,           -- ClickRemote on Heartbeat; this is the strength engine
	clicksPerFrame = 5,     -- 25/frame measured only 14% better and costs frame time
	farm = true,            -- climb lanes, claim the deepest one, repeat
	training = true,        -- stand in the best zone the rebirth count allows
	titles = true,          -- 10 wins a roll, permanent, up to x20 strength
	upgrades = true,        -- BuyUpgrade(name,"Win"); Punch Speed capped at level 10
	rebirth = true,         -- bank to the next training-zone milestone, then convert
	eggs = false,           -- pets multiply strength but the cheapest egg is 25K wins
	auras = false,          -- a roll REPLACES the current aura and can downgrade it
	freebies = true,        -- codes, daily, offline, the free potion

	trainSeconds = 45,      -- seconds parked in the zone before each climb
	laneSeconds = 12,       -- a lane that takes longer than this is claimed instead
	stallSeconds = 5,       -- no wall damage at all for this long -> claim
	runSeconds = 120,       -- hard cap on one climb
	laneCap = 0,            -- 0 = climb until the stall; otherwise stop at this lane
	titleShare = 0.25,      -- share of everything earned that may go into rolls
	eggShare = 0.25,        -- same, for eggs
	rebirthUntil = 0,       -- 0 = no limit
}

local STATE = {
	phase = "idle",
	note = "",
	strength = 0, wins = 0, level = 0, rebirths = 0,
	strRate = 0, winRate = 0,
	lane = "Lane1", laneNum = 1, deepest = 1,
	training = 1, zone = "-",
	title = "-", titleMul = 1, titles = 0,
	aura = "-", auraMul = 1,
	runs = 0, earned = 0, titleSpent = 0, eggSpent = 0,
	perClick = 0,
	busy = false, bodyOwner = nil,
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

local function value(name, default)
	local v = plr:FindFirstChild(name)
	if v and v:IsA("ValueBase") then return v.Value end
	return default
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Events = Remotes:WaitForChild("Events")
local Functions = Remotes:WaitForChild("Functions")
local Config = ReplicatedStorage:WaitForChild("Configuration")

local function conf(name)
	local mod = Config:FindFirstChild(name)
	if not mod then return nil end
	local ok, m = pcall(require, mod)
	return ok and m or nil
end

local BaseConfig = conf("BaseConfig") or {}
local MinStrength = conf("MinStrength") or {}
local Codes = conf("Codes") or {}
local Upgrades = conf("Upgrades")
local Eggs = conf("Eggs") or {}

local function fire(name, ...)
	local r = Events:FindFirstChild(name)
	if not r then return false end
	local args = { ... }
	local ok = pcall(function() r:FireServer(table.unpack(args)) end)
	return ok
end

-- Pins the character on Heartbeat and returns a stop function. A single CFrame
-- write is not enough anywhere the server re-checks the position; the wall hits
-- only count while the body is actually parked in front of the wall.
local function pin(getCFrame)
	local stop = false
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if stop or GEN ~= _G.__STRCLICK then
			conn:Disconnect()
			return
		end
		local _, hrp = char()
		local cf = getCFrame()
		if hrp and cf then hrp.CFrame = cf end
	end)
	return function()
		stop = true
		pcall(function() conn:Disconnect() end)
	end
end

-- One body lock. The farm holds the character almost continuously, so anything
-- that needs to stand somewhere else (a training zone, an egg) asks for it and the
-- farm hands it over between runs. Remote-only actions never take this lock -
-- in the last game a rebirth behind a mutex simply never fired.
local function withBody(name, fn)
	if STATE.bodyOwner then return false, "busy" end
	STATE.bodyOwner = name
	local ok, err = pcall(fn)
	STATE.bodyOwner = nil
	if not ok then note(name .. " failed: " .. tostring(err)) end
	return ok, err
end

-- The farm holds the body for a whole run, so anything else that needs to stand
-- somewhere asks here and the farm skips its next pass. Without this the training
-- zone was never entered once - the same shape as the rebirth that never fired
-- through a UI mutex in the last game.
local bodyRequest = false

local function requestBody(name, fn)
	bodyRequest = true
	local deadline = os.clock() + 20
	while STATE.bodyOwner and os.clock() < deadline do task.wait(0.2) end
	local ok, err = withBody(name, fn)
	bodyRequest = false
	return ok, err
end

local function loop(sec, key, fn)
	task.spawn(function()
		while GEN == _G.__STRCLICK do
			if CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
			end
			task.wait(sec)
		end
	end)
end

--------------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------------

local dataCache, dataAt = nil, 0

local function data(force)
	if not force and dataCache and os.clock() - dataAt < 8 then return dataCache end
	local ok, d = pcall(function() return Functions.GetPlayerData:InvokeServer() end)
	if ok and type(d) == "table" then
		dataCache, dataAt = d, os.clock()
	end
	return dataCache
end

local lastStr, lastWins, lastSample = 0, 0, 0

local function refresh()
	STATE.strength = value("nStrength", 0)
	STATE.wins = value("nWins", 0)
	STATE.rebirths = value("nRebirth", 0)
	local ls = plr:FindFirstChild("leaderstats")
	STATE.level = ls and ls:FindFirstChild("Level") and ls.Level.Value or 0
	STATE.lane = plr:GetAttribute("Lane") or "Lane1"
	STATE.laneNum = tonumber(STATE.lane:match("%d+")) or 1
	if STATE.laneNum > STATE.deepest then STATE.deepest = STATE.laneNum end
	STATE.training = plr:GetAttribute("TrainingMultiplier") or 1
	STATE.titleMul = plr:GetAttribute("TitleStrengthMultiplier")
		or (dataCache and dataCache.TitleStrengthMultiplier) or 1
	STATE.aura = plr:GetAttribute("AuraName") or "-"
	STATE.auraMul = plr:GetAttribute("AuraStrengthMultiplier") or 1

	local now = os.clock()
	if lastSample > 0 and now - lastSample >= 1 then
		local dt = now - lastSample
		if STATE.strength >= lastStr then STATE.strRate = (STATE.strength - lastStr) / dt end
		if STATE.wins >= lastWins then STATE.winRate = (STATE.wins - lastWins) / dt end
	end
	if now - lastSample >= 1 then
		lastStr, lastWins, lastSample = STATE.strength, STATE.wins, now
	end
end

--------------------------------------------------------------------------------
-- the strength engine
--
-- One connection, `clicksPerFrame` calls in it. There is no server throttle here,
-- which is why this game climbs so much faster than the other clickers in this
-- repo - the whole limit is how many frames the client can render.
--------------------------------------------------------------------------------

local clickConn
local clickCount, clickAt, clickStr = 0, os.clock(), 0

local function startClicker()
	if clickConn then return end
	clickStr = value("nStrength", 0)
	clickConn = RunService.Heartbeat:Connect(function()
		if GEN ~= _G.__STRCLICK then
			clickConn:Disconnect()
			clickConn = nil
			return
		end
		if not (CONFIG.auto and CONFIG.click) then return end
		local remote = Events:FindFirstChild("ClickRemote")
		if not remote then return end
		for _ = 1, math.max(1, CONFIG.clicksPerFrame) do
			pcall(function() remote:FireServer() end)
			clickCount = clickCount + 1
		end
		if os.clock() - clickAt >= 3 then
			local str = value("nStrength", 0)
			if clickCount > 0 and str >= clickStr then
				STATE.perClick = (str - clickStr) / clickCount
			end
			clickCount, clickAt, clickStr = 0, os.clock(), str
		end
	end)
end

--------------------------------------------------------------------------------
-- training zones
--
-- The multiplier is sticky: entering a zone once sets TrainingMultiplier and it
-- survives walking away, so this costs one warp per rebirth rather than a
-- permanent parking spot. Entering a zone the rebirth count does NOT allow sets
-- the multiplier back to 1, so the gate is checked before moving, not after.
--------------------------------------------------------------------------------

-- A zone is a pile of decoration around one big trigger volume ("TouchPart", with
-- "Base" as the floor under it). Taking the first BasePart found lands on a random
-- dumbbell mesh a few studs off the pad, so the trigger is picked by name first and
-- by volume second.
local function zonePart(model)
	if model:IsA("BasePart") then return model end
	local touch = model:FindFirstChild("TouchPart", true) or model:FindFirstChild("Base", true)
	if touch and touch:IsA("BasePart") then return touch end
	local best, bestVol
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local vol = d.Size.X * d.Size.Y * d.Size.Z
			if not bestVol or vol > bestVol then best, bestVol = d, vol end
		end
	end
	return best
end

-- The map streams. Standing at Lane9 the whole training area is unloaded, so the
-- zone models are still there with no parts inside them and every position read
-- comes back nil - which made the zone silently never be entered. The positions
-- are therefore cached the moment they ARE loaded, and kept in _G so they survive
-- a re-execute.
_G.__STRCLICK_ZONES = _G.__STRCLICK_ZONES or {}

local function zonePosition(zone)
	local part = zonePart(zone)
	if part then
		_G.__STRCLICK_ZONES[zone.Name] = part.Position
		return part.Position
	end
	local ok, pivot = pcall(function() return zone:GetPivot().Position end)
	if ok and typeof(pivot) == "Vector3" and pivot.Magnitude > 1 then
		_G.__STRCLICK_ZONES[zone.Name] = pivot
		return pivot
	end
	return _G.__STRCLICK_ZONES[zone.Name]
end

local function cacheZones()
	local folder = workspace:FindFirstChild("TrainingZones")
	if not folder then return end
	for _, z in ipairs(folder:GetChildren()) do
		if z:GetAttribute("Multiplier") then zonePosition(z) end
	end
end

local function bestZone()
	local folder = workspace:FindFirstChild("TrainingZones")
	if not folder then return nil end
	local best, bestMul = nil, 0
	for _, z in ipairs(folder:GetChildren()) do
		local mul = z:GetAttribute("Multiplier")
		local req = z:GetAttribute("Rebirth")
		-- req is 99999999999999 on the gamepass zones; the same test filters them
		if mul and req and STATE.rebirths >= req and mul > bestMul then
			best, bestMul = z, mul
		end
	end
	return best, bestMul
end

-- Phase A of the cycle: park in the zone and let the clicker run at the higher
-- multiplier. This is where strength is made, and strength is the only thing that
-- decides how deep the climb gets - which is what the wins are actually paid for.
local function trainPhase()
	local zone, mul = bestZone()
	if not zone or (mul or 1) <= 1 then return end
	STATE.zone = zone.Name
	local pos = zonePosition(zone)
	if not pos then
		note("training zone position unknown (streamed out)")
		return
	end
	STATE.phase = "training x" .. tostring(mul)
	pcall(function() plr:RequestStreamingAround(pos) end)
	local target = CFrame.new(pos + Vector3.new(0, 4, 0))
	local stop = pin(function() return target end)
	local deadline = os.clock() + CONFIG.trainSeconds
	while os.clock() < deadline and GEN == _G.__STRCLICK
		and CONFIG.auto and CONFIG.training do
		task.wait(0.3)
		-- refine the aim once the area has actually streamed in
		local part = zonePart(zone)
		if part then
			pos = part.Position
			_G.__STRCLICK_ZONES[zone.Name] = pos
			target = CFrame.new(pos + Vector3.new(0, 4, 0))
		end
		STATE.training = plr:GetAttribute("TrainingMultiplier") or 1
	end
	stop()
end

--------------------------------------------------------------------------------
-- the farm: climb, then claim once at the bottom
--------------------------------------------------------------------------------

local function wallsOf(laneName)
	local stage = workspace:FindFirstChild("Stage")
	local lane = stage and stage:FindFirstChild(laneName)
	local folder = lane and lane:FindFirstChild("Walls")
	if not folder then return {} end
	local list = {}
	for _, w in ipairs(folder:GetChildren()) do
		if w:IsA("BasePart") then list[#list + 1] = w end
	end
	-- the track runs towards -Z and the client raycasts 20 studs down -Z, so the
	-- wall with the highest Z is the one standing in front of the character
	table.sort(list, function(a, b) return a.Position.Z > b.Position.Z end)
	return list
end

local function laneHealth(list)
	local total = 0
	for _, w in ipairs(list) do total = total + (w:GetAttribute("Health") or 0) end
	return total
end

-- Pays Wins[lane] for whatever lane the player is in, from any distance, and
-- resets the run to Lane1. Verified at 183 studs and on a lane whose walls were
-- still standing.
local function claim(laneName)
	local winFolder = workspace:FindFirstChild("Map")
	winFolder = winFolder and winFolder:FindFirstChild("Win")
	local model = winFolder and winFolder:FindFirstChild(laneName)
	local part = model and model:FindFirstChild("WinPart")
	local _, hrp = char()
	if not (part and hrp) then return 0 end
	local before = value("nWins", 0)
	pcall(function()
		firetouchinterest(hrp, part, 0)
		task.wait(0.1)
		firetouchinterest(hrp, part, 1)
	end)
	-- the credit lands a beat after the touch; a 1s window read it as zero and the
	-- run counter never moved while the balance was climbing
	local deadline = os.clock() + 3
	repeat task.wait(0.2) until value("nWins", 0) > before or os.clock() > deadline
	local gained = value("nWins", 0) - before
	if gained > 0 then
		STATE.earned = STATE.earned + gained
		STATE.runs = STATE.runs + 1
	end
	return gained
end

local damageAt = 0

local function runOnce()
	local startedAt = os.clock()
	local reached = STATE.lane
	while GEN == _G.__STRCLICK and CONFIG.auto and CONFIG.farm do
		if os.clock() - startedAt > CONFIG.runSeconds then break end
		if bodyRequest then break end
		local laneName = plr:GetAttribute("Lane") or "Lane1"
		local num = tonumber(laneName:match("%d+")) or 1
		reached = laneName
		if CONFIG.laneCap > 0 and num >= CONFIG.laneCap then break end

		local list = wallsOf(laneName)
		if #list == 0 then break end

		local target = list[1]
		local aim = CFrame.new(target.Position + Vector3.new(0, -4, 6))
		local stop = pin(function() return aim end)

		local lastHp, lastMove = laneHealth(list), os.clock()
		local laneStart = os.clock()
		local cleared = false
		while GEN == _G.__STRCLICK and CONFIG.auto and CONFIG.farm do
			task.wait(0.12)
			-- the game's own WallClient loop does the hitting; this is a backup and
			-- the 0.4s server cooldown throws away anything faster
			if os.clock() - damageAt > 0.4 then
				damageAt = os.clock()
				fire("DamageWall")
			end
			local hp = laneHealth(list)
			if hp <= 0 then cleared = true break end
			if hp < lastHp then lastHp, lastMove = hp, os.clock() end
			for _, w in ipairs(list) do
				if (w:GetAttribute("Health") or 0) > 0 then
					aim = CFrame.new(w.Position + Vector3.new(0, -4, 6))
					break
				end
			end
			if os.clock() - lastMove > CONFIG.stallSeconds then break end
			-- The pad pays Wins[the lane you are in] whether or not its walls fell,
			-- so grinding a lane that is out of reach is pure loss: Lane9 took over
			-- 100s for +2300 against a 20s round trip that banks Lane8's 1500.
			if os.clock() - laneStart > CONFIG.laneSeconds then break end
			if os.clock() - startedAt > CONFIG.runSeconds then break end
			if bodyRequest then break end
		end

		if not cleared then
			stop()
			break
		end
		-- the lane advances by itself once the walls are down; wait for the server
		local deadline = os.clock() + 3
		repeat task.wait(0.1) until (plr:GetAttribute("Lane") or laneName) ~= laneName
			or os.clock() > deadline
		stop()
		STATE.phase = "climbing " .. tostring(plr:GetAttribute("Lane"))
	end

	local laneName = plr:GetAttribute("Lane") or reached
	STATE.phase = "claiming " .. laneName
	local gained = claim(laneName)
	local num = tonumber(laneName:match("%d+")) or 1
	note(string.format("run %d: %s -> +%s wins", STATE.runs, laneName, short(gained)))
	if num > STATE.deepest then STATE.deepest = num end
	-- claiming puts the run back to Lane1
	local deadline = os.clock() + 4
	repeat task.wait(0.15) until (plr:GetAttribute("Lane") or "Lane1") ~= laneName
		or os.clock() > deadline
end

-- One cycle: train at the multiplier, then spend that strength climbing. Both
-- halves want the body, so they share one lock instead of fighting for it.
local function cyclePass()
	if STATE.bodyOwner or bodyRequest then return end
	withBody("cycle", function()
		if CONFIG.training then trainPhase() end
		if CONFIG.farm then runOnce() end
	end)
end

--------------------------------------------------------------------------------
-- spending
--
-- Rebirth is linear (1 per 1000 wins) and destroys the remainder, so the only
-- thing that matters is WHEN it fires, not how often: the same wins buy the same
-- rebirths whether converted in one go or a thousand at a time, but every
-- conversion costs a full strength reset. It therefore banks to the next training
-- zone milestone and converts once.
--------------------------------------------------------------------------------

local MILESTONES = { 1, 25, 200, 5000, 100000, 10000000 }

local function nextMilestone()
	for _, m in ipairs(MILESTONES) do
		if STATE.rebirths < m then return m end
	end
	return nil
end

local function rebirthTarget()
	local m = nextMilestone()
	if not m then return nil end
	return (m - STATE.rebirths) * 1000
end

-- Everything below the rebirth bank is surplus, and the share steppers decide how
-- much of what this session earned may leave through each door. Tracking it
-- against `earned` rather than against the balance is what stops a spender from
-- draining the same balance again on every pass.
local function budget(spent, share)
	return STATE.earned * share - spent
end

-- One shared guard, asked by every spender. The rebirth bank is enormous by
-- design (175K wins for the 200-rebirth zone, 5M for the next), so fencing it off
-- absolutely would block a 10-wins title roll for an hour - the exact starvation
-- pattern that cost the most time in Sell Ores. Anything trivially cheap against
-- the bank therefore passes straight through.
local function canSpend(cost)
	if cost > STATE.wins then return false end
	local target = rebirthTarget()
	if not target then return true end
	if cost <= math.max(100, target * 0.02) then return true end
	return cost <= (STATE.wins - target)
end

local UPGRADE_NAMES = { "Punch Speed", "Title Luck", "Aura Luck", "Pet Luck", "Pet Equip" }

local function upgradeLevels()
	local d = data()
	return (d and d.Upgrades) or {}
end

local function buyUpgrades()
	if not Upgrades then return end
	local levels = upgradeLevels()
	local best, bestPrice, bestLevel
	for _, name in ipairs(UPGRADE_NAMES) do
		local lvl = levels[name] or 0
		local okMax, maxLvl = pcall(function() return Upgrades:GetMaxLevel(name) end)
		local okPrice, price = pcall(function() return Upgrades:GetPrice(name, lvl) end)
		-- Punch Speed only matters up to value 2.5: SERVER_HIT_COOLDOWN is 0.4s and
		-- the client clamps its own interval to that, so level 11+ buys nothing
		local capped = (name == "Punch Speed" and lvl >= 10)
			or (name == "Pet Equip" and not CONFIG.eggs)
		if okMax and okPrice and type(price) == "number" and lvl < (maxLvl or 0)
			and not capped then
			if not bestPrice or price < bestPrice then
				best, bestPrice, bestLevel = name, price, lvl
			end
		end
	end
	if not best then return end
	if not canSpend(bestPrice) then return end
	fire("BuyUpgrade", best, "Win")
	task.wait(0.6)
	data(true)
	local now = (upgradeLevels()[best] or 0)
	if now > bestLevel then
		note(string.format("upgrade %s -> %d (%s wins)", best, now, short(bestPrice)))
	end
end

-- 10 wins a roll, the title is kept forever and the server applies the best one
-- by itself, so a roll can never be a downgrade. Odds are 1/sqrt(rarity), which
-- runs from Weakling (x1.05, 33%) to Reality Breaker (x20).
local function rollTitles()
	local left = budget(STATE.titleSpent, CONFIG.titleShare)
	if left < 10 or not canSpend(10) then return end
	local rolls = math.min(math.floor(left / 10), math.floor(STATE.wins / 10), 15)
	if rolls <= 0 then return end
	local before = STATE.titleMul
	for _ = 1, rolls do
		if not (CONFIG.auto and CONFIG.titles) then break end
		fire("TitleRoll", "Normal")
		STATE.titleSpent = STATE.titleSpent + 10
		task.wait(0.8)
	end
	local d = data(true)
	local owned = 0
	if d and type(d.OwnedTitles) == "table" then
		for _ in pairs(d.OwnedTitles) do owned = owned + 1 end
	end
	STATE.titles = owned
	STATE.title = (d and d.TitleName) or STATE.title
	local after = plr:GetAttribute("TitleStrengthMultiplier") or before
	if after > before then
		note(string.format("title x%.2f -> x%.2f (%d owned)", before, after, owned))
	end
end

local function doRebirth()
	local target = rebirthTarget()
	if not target then return end
	if CONFIG.rebirthUntil > 0 and STATE.rebirths >= CONFIG.rebirthUntil then return end
	if STATE.wins < target then return end
	local before = STATE.rebirths
	fire("RebirthRemote")
	task.wait(2)
	refresh()
	if STATE.rebirths > before then
		note(string.format("rebirth %d -> %d (%s wins)", before, STATE.rebirths, short(target)))
		STATE.training = plr:GetAttribute("TrainingMultiplier") or 1
	end
end

-- Pets multiply strength. HatchPet(eggName, amount, deleteFilter) is what the UI
-- fires and the client picks the egg the body is standing at, so this warps first.
-- Any egg whose Currency is not Wins is a Robux egg and is filtered by that field.
local function hatchEggs()
	local left = budget(STATE.eggSpent, CONFIG.eggShare)
	if left <= 0 then return end
	local folder = workspace:FindFirstChild("Eggs")
	if not folder then return end
	local best, bestCost, bestMul
	for name, egg in pairs(Eggs) do
		local cost = tonumber(egg.Cost)
		if egg.Currency == "Wins" and cost and folder:FindFirstChild(name) then
			local top = 0
			for _, pet in ipairs(egg.Pets or {}) do
				top = math.max(top, tonumber(pet.Multiplier) or 0)
			end
			if cost <= left and canSpend(cost) and top > (bestMul or 0) then
				best, bestCost, bestMul = name, cost, top
			end
		end
	end
	if not best then return end
	local model = folder:FindFirstChild(best)
	local part = zonePart(model)
	if not part then return end
	requestBody("egg", function()
		STATE.phase = "hatching " .. best
		local target2 = CFrame.new(part.Position + Vector3.new(0, 5, 0))
		local stop = pin(function() return target2 end)
		task.wait(1.2)
		local remote = Remotes:FindFirstChild("HatchPet")
		if remote then
			pcall(function() remote:FireServer(best, 1, {}) end)
		end
		task.wait(1.5)
		stop()
		STATE.eggSpent = STATE.eggSpent + bestCost
		note("hatched " .. best .. " (" .. short(bestCost) .. " wins)")
	end)
end

-- A roll REPLACES the current aura rather than adding to a collection, so it can
-- hand back something worse than what is worn. Off by default for that reason.
local function rollAura()
	local Chances = Config:FindFirstChild("AuraMultipliers")
	Chances = Chances and Chances:FindFirstChild("Chances")
	if not Chances then return end
	local ok, ch = pcall(require, Chances)
	if not ok or not ch.Packs then return end
	local pack = plr:GetAttribute("CurrentPack") or 1
	local entry = ch.Packs[pack]
	if not (entry and entry.currency == "Wins") then return end
	if not canSpend(entry.price) then return end
	fire("Roll", "Normal", pack)
	task.wait(1.5)
	note("aura roll pack " .. pack .. " -> " .. tostring(plr:GetAttribute("AuraName")))
end

--------------------------------------------------------------------------------
-- free stuff
--------------------------------------------------------------------------------

local redeemed = false

local function freePass()
	if not redeemed then
		redeemed = true
		local d = data(true)
		local done = {}
		if d and type(d.RedeemedCodes) == "table" then
			for _, c in pairs(d.RedeemedCodes) do done[tostring(c)] = true end
		end
		for code in pairs(Codes) do
			if not done[code] then
				fire("RedeemCode", code)
				task.wait(0.6)
			end
		end
	end
	fire("ClaimDailyReward")
	task.wait(0.4)
	fire("ClaimOfflineEarnings")
	task.wait(0.4)
	if plr:GetAttribute("CanClaimFreePotion") then
		pcall(function() Functions.ClaimFreePotion:InvokeServer() end)
		task.wait(0.6)
	end
	-- 2x strength for 15 minutes; only started when none is running
	if (plr:GetAttribute("StrengthPotion") or 0) > 0
		and (plr:GetAttribute("StrengthPotionTimeLeft") or 0) <= 0 then
		pcall(function() Functions.UsePotion:InvokeServer("Strength") end)
		note("strength potion started")
	end
	if (plr:GetAttribute("WinsPotion") or 0) > 0
		and (plr:GetAttribute("WinsPotionTimeLeft") or 0) <= 0 then
		pcall(function() Functions.UsePotion:InvokeServer("Wins") end)
	end
end

local function spendPass()
	if CONFIG.upgrades then buyUpgrades() end
	if CONFIG.titles then rollTitles() end
	if CONFIG.eggs then hatchEggs() end
	if CONFIG.auras then rollAura() end
	if CONFIG.rebirth then doRebirth() end
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

task.spawn(function()
	while GEN == _G.__STRCLICK do
		pcall(refresh)
		task.wait(0.5)
	end
end)

startClicker()
pcall(cacheZones)
task.spawn(function()
	-- the zones are loaded at spawn and unloaded once the climb goes deep, so grab
	-- their positions early and keep topping the cache up while they are in range
	for _ = 1, 20 do
		if GEN ~= _G.__STRCLICK then return end
		pcall(cacheZones)
		task.wait(3)
	end
end)

loop(0.4, nil, cyclePass)
loop(10, nil, spendPass)
loop(60, "freebies", freePass)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
-- Re-executing stacks panels: destroy the stored handle AND sweep the named
-- ScreenGui, since a run that errored before storing the handle left one behind.
if _G.__STRCLICK_WIN then pcall(function() _G.__STRCLICK_WIN:Destroy() end) end
for _, root in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui") }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "StrengthClickPanel" then pcall(function() g:Destroy() end) end
		end
	end
end

local win = UI.Window({
	name = "StrengthClickPanel",
	title = "STRENGTH", accentTitle = "CLICK", subtitle = "seltonmt",
	badge = "💪", width = 920, height = 580,
})
_G.__STRCLICK_WIN = win

local page = win:Page("FARM", UI.icon.bolt)

local main = page:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	note(v and "running" or "stopped")
end, "click, climb the lanes, claim the deepest, spend, repeat", UI.theme.good)
main:Toggle("Click", CONFIG.click, function(v) CONFIG.click = v end,
	"no server throttle here - the client frame rate is the only limit")
main:Slider("Clicks/frame", 1, 25, CONFIG.clicksPerFrame, function(v)
	CONFIG.clicksPerFrame = v
end)
main:Toggle("Climb lanes", CONFIG.farm, function(v) CONFIG.farm = v end,
	"clearing a lane advances it on its own; the pad is only touched at the end")
main:Stepper("Train for", function() return CONFIG.trainSeconds .. "s" end, function(dir)
	CONFIG.trainSeconds = math.clamp(CONFIG.trainSeconds + dir * 15, 0, 600)
end, "seconds parked in the training zone before each climb")
main:Stepper("Lane limit", function() return CONFIG.laneSeconds .. "s" end, function(dir)
	CONFIG.laneSeconds = math.clamp(CONFIG.laneSeconds + dir * 2, 2, 120)
end, "a lane slower than this is claimed instead of ground out")
main:Stepper("Lane cap", function()
	return CONFIG.laneCap == 0 and "stall" or ("Lane" .. CONFIG.laneCap)
end, function(dir)
	CONFIG.laneCap = math.clamp(CONFIG.laneCap + dir, 0, 25)
end, "0 climbs until the walls stop falling, which is always the best payout")

local spend = page:Card("SPENDING", 2)
spend:Toggle("Roll titles", CONFIG.titles, function(v) CONFIG.titles = v end,
	"10 wins a roll, kept forever, x1.05 up to x20 strength", UI.theme.warn)
spend:Stepper("Title budget", function()
	return math.floor(CONFIG.titleShare * 100) .. "%"
end, function(dir)
	CONFIG.titleShare = math.clamp(CONFIG.titleShare + dir * 0.05, 0, 1)
end, "share of everything earned this session that may go into rolls")
spend:Toggle("Buy upgrades", CONFIG.upgrades, function(v) CONFIG.upgrades = v end,
	"cheapest useful first; Punch Speed stops at level 10, the cooldown caps it",
	UI.theme.warn)
spend:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"banks to the next training milestone, then converts in one go", UI.theme.warn)
spend:Stepper("Rebirth until", function()
	return CONFIG.rebirthUntil == 0 and "no limit" or tostring(CONFIG.rebirthUntil)
end, function(dir)
	CONFIG.rebirthUntil = math.clamp(CONFIG.rebirthUntil + dir * 5, 0, 1000)
end, "stop converting wins at this rebirth count")

local extra = page:Card("EXTRAS", 1)
extra:Toggle("Training zone", CONFIG.training, function(v) CONFIG.training = v end,
	"parks in the best zone the rebirths allow; a locked one would set it to x1",
	UI.theme.good)
extra:Toggle("Free rewards", CONFIG.freebies, function(v) CONFIG.freebies = v end,
	"codes, daily, offline earnings and the free potion", UI.theme.good)
extra:Toggle("Hatch eggs", CONFIG.eggs, function(v) CONFIG.eggs = v end,
	"pets multiply strength but the cheapest egg is 25K wins", UI.theme.warn)
extra:Toggle("Roll auras", CONFIG.auras, function(v) CONFIG.auras = v end,
	"1K wins and it REPLACES the current aura, so it can downgrade you", UI.theme.bad)
extra:Button("Claim now", function()
	task.spawn(function()
		local lane = plr:GetAttribute("Lane") or "Lane1"
		note("manual claim " .. lane .. " -> +" .. short(claim(lane)))
	end)
end)
extra:Button("Unstuck", function()
	CONFIG.auto = false
	STATE.bodyOwner = nil
	local _, _, hum = char()
	if hum then pcall(function() hum.PlatformStand = false hum.WalkSpeed = 18 end) end
	note("unstuck, auto off")
end, UI.theme.bad)

local out = page:Card("STATUS", 0):Readout(12, function(text)
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__STRCLICK do
		local target = rebirthTarget()
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase     " .. tostring(STATE.phase),
			"  strength  " .. short(STATE.strength) .. "   " .. short(STATE.strRate) .. "/s",
			"  per click " .. short(STATE.perClick) .. "   level " .. STATE.level,
			"  wins      " .. short(STATE.wins) .. "   " .. short(STATE.winRate) .. "/s",
			"  lane      " .. STATE.lane .. "   deepest Lane" .. STATE.deepest,
			"  rebirths  " .. short(STATE.rebirths)
				.. (target and ("   next at " .. short(target) .. " wins") or "   maxed"),
			"  training  x" .. tostring(STATE.training) .. "   " .. tostring(STATE.zone),
			"  title     x" .. string.format("%.2f", STATE.titleMul)
				.. "   " .. STATE.titles .. " owned",
			"  aura      " .. tostring(STATE.aura) .. "   x" .. tostring(STATE.auraMul),
			"  runs      " .. STATE.runs .. "   earned " .. short(STATE.earned),
			"  " .. tostring(STATE.note),
		}
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s str   %s wins   reb %s   %s   %s",
				short(STATE.strength), short(STATE.wins), short(STATE.rebirths),
				STATE.lane, STATE.phase))
		end)
		task.wait(0.5)
	end
end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__STRCLICK_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	refresh = refresh, data = data, short = short, pin = pin,
	wallsOf = wallsOf, laneHealth = laneHealth, claim = claim,
	runOnce = runOnce, cyclePass = cyclePass, trainPhase = trainPhase,
	bestZone = bestZone,
	zonePosition = zonePosition, cacheZones = cacheZones,
	buyUpgrades = buyUpgrades, upgradeLevels = upgradeLevels,
	rollTitles = rollTitles, doRebirth = doRebirth, rebirthTarget = rebirthTarget,
	canSpend = canSpend, budget = budget,
	hatchEggs = hatchEggs, rollAura = rollAura, freePass = freePass,
	spendPass = spendPass, startClicker = startClicker,
	BaseConfig = BaseConfig, MinStrength = MinStrength, Eggs = Eggs,
}

print("[strengthclick] gen " .. GEN .. " ready - RightShift for the panel")
