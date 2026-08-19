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

  Four things the game gives away, all measured against the server's own oracle:

  * THE CLICK UPGRADER IS A BALANCE REQUIREMENT, NOT A COST. The pads in
    workspace.StrengthBoosts read "+3K/Click - 100K Wins Required"; touching one
    from 47 studs set BaseStrength 2 -> 3000 and charged ZERO wins, and the tier
    survived the balance falling back under the requirement. Per click went from
    12,159 to 9,865,440 - an 811x, and it was the single biggest thing missing
    from the first version of this file. The model names lie (the second floor has
    five models called "+3MStrength" worth +2.5M to +100M), so both the gain and
    the price are read off the labels.

  * THE PAID TITLE ROLLS ARE FREE. TitleRoll:FireServer takes the roll TYPE, and
    "Golden" / "Diamond" / "Neon" are the Robux tiers - fired directly they cost
    nothing at all. 22 free Neon rolls produced Reality Breaker, the best title in
    the game: x20 strength and x7 WINS, confirmed on GetPlayerData. Titles are
    owned forever and the server always applies the best one, so a roll can never
    be a downgrade.

  * THE ROBUX EGG IS PRICED IN WINS. HatchPet("Robux", n, {}) charges 99 WINS, not
    99 Robux, and hands out the premium pets - Nyan Cat x3.2 against x1.6 for the
    500-wins Basic egg and x7.5 for the 500-MILLION Desert egg. The amount argument
    is capped at 10 per call and charged correctly. Pets are additive
    (PetMultiplier = 1 + sum of (multiplier - 1) over the equipped ones) and three
    identical pets craft into one of the next tier at x1.5.

  * AN AURA ROLL CAN BE PREVIEWED BEFORE IT IS KEPT. The server charges on Roll but
    only APPLIES the result once the client sends RollVisualFinished - so the
    result arrives on RollVisual first and only the good ones are confirmed. Bubble
    (5%, the best in pack 1) landed on the second roll and nothing can downgrade
    the worn aura any more. Six rolls without the confirmation earlier spent 6000
    wins for nothing, which is what pointed at it.

  Probed and NOT exploitable, so nobody re-derives them: worlds (the World2..5
  attributes gate RequestTeleportServer, and firing it with a locked place id just
  rejoins the same place), Cmdr (registered with giveWins/giveStrength but every
  command answers "You don't have permission"), the "Robux" argument of BuyUpgrade
  and TeleportToLane (ignored, nothing charged, no prompt), ToggleAutoClick,
  UnlockTitle, a spoofed aura pack number, a hatch amount above 10, and codes -
  the server answers "Invalid code" to everything except WELCOME.

  Never spends Robux: every Buy*Strength / BuyMultiplier / Buy*Roll / BuyRobuxEgg /
  SkipRebirth / BuyPotion remote (those are the real purchase prompts and are not
  touched), the "Robux" argument of BuyUpgrade and TeleportToLane, and any egg
  bought through the shop rather than hatched.
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
	upgrader = true,        -- the click upgrader pads: free, and the biggest lever
	titles = true,          -- free Neon rolls until the best title is owned
	pets = true,            -- Robux egg at 99 WINS, equip best, craft triples
	upgrades = true,        -- BuyUpgrade(name,"Win"); Punch Speed capped at level 10
	rebirth = true,         -- bank to the next training-zone milestone, then convert
	auras = true,           -- roll, preview, and only confirm the best in the pack
	freebies = true,        -- codes, daily, offline, the free potion

	trainSeconds = 45,      -- seconds parked in the zone before each climb
	laneSeconds = 12,       -- a lane that takes longer than this is claimed instead
	stallSeconds = 5,       -- no wall damage at all for this long -> claim
	runSeconds = 120,       -- hard cap on one climb
	laneCap = 0,            -- 0 = climb until the stall; otherwise stop at this lane
	petShare = 0.25,        -- share of everything earned that may go into eggs
	auraRolls = 6,          -- rolls per pass while hunting the best aura in the pack
	-- Stop converting at the x15 training zone. Past it the milestones cost more
	-- than they return: 100,000 rebirths (the x50 zone, a 3.3x) needs ~94M wins,
	-- and the SAME 94M wins held instead qualifies for the +100K/click pad against
	-- a base of 1 - five orders of magnitude. Rebirth is the one thing that takes
	-- the click upgrader away, because it zeroes the balance the pad is gated on.
	rebirthUntil = 5000,
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
	base = 1, pad = "-",
	pets = 0, petMul = 1,
	runs = 0, earned = 0, petSpent = 0,
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

-- The pad labels are abbreviated ("1.2K Wins Required", "600B", "1.5T") and a
-- hand-written suffix table is how the Drill Farm read a $1.56Q cell unlock as
-- $1.56. The ladder is therefore built by asking the game's OWN formatter what it
-- calls each power of ten, and anything that will not parse returns nil rather
-- than a number that looks plausible.
local FormatNumber = ReplicatedStorage:FindFirstChild("Modules")
FormatNumber = FormatNumber and FormatNumber:FindFirstChild("FormatNumber")
FormatNumber = FormatNumber and select(2, pcall(require, FormatNumber)) or nil

local SUFFIX = {}
do
	if FormatNumber and FormatNumber.Format then
		for exp = 3, 63, 3 do
			local ok, text = pcall(FormatNumber.Format, 10 ^ exp)
			local suffix = ok and type(text) == "string" and text:match("^[%d%.]+(%a+)$")
			if suffix then SUFFIX[#SUFFIX + 1] = { 10 ^ exp, suffix:upper() } end
		end
	end
	table.sort(SUFFIX, function(a, b) return a[1] > b[1] end)
end

local function parseAmount(text)
	if type(text) ~= "string" then return nil end
	local digits, suffix = text:gsub(",", ""):match("^%s*([%d%.]+)%s*(%a*)%s*$")
	local n = tonumber(digits)
	if not n then return nil end
	if suffix == "" then return n end
	suffix = suffix:upper()
	for _, row in ipairs(SUFFIX) do
		if row[2] == suffix then return n * row[1] end
	end
	return nil
end

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
	STATE.auraMul = plr:GetAttribute("AuraMultiplier") or 1
	STATE.base = plr:GetAttribute("BaseStrength") or 1
	STATE.petMul = plr:GetAttribute("PetMultiplier") or 1

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
-- the click upgrader
--
-- workspace.StrengthBoosts is the "Click Upgrader" shop and it is the biggest
-- lever in the game: the pads set BaseStrength, which every other multiplier is
-- applied on top of. Touching one is FREE - the wins figure is a balance
-- requirement, not a price, and the tier survives the balance falling back under
-- it. Rebirth is the one thing that takes it away, because it zeroes the balance.
--------------------------------------------------------------------------------

local UPGRADER_POS = Vector3.new(1730, 18, 2951)  -- refined from the pads themselves

local function boostPads()
	local root = workspace:FindFirstChild("StrengthBoosts")
	if not root then return {} end
	local pads = {}
	for _, floor in ipairs(root:GetChildren()) do
		if floor:IsA("Folder") then
			for _, model in ipairs(floor:GetChildren()) do
				local part = model:IsA("Model") and model:FindFirstChild("BoostPart")
				if part then
					local gain, price
					for _, d in ipairs(model:GetDescendants()) do
						if d:IsA("TextLabel") then
							-- the model name lies; five of them are called "+3MStrength"
							local g = d.Text:match("^%+([%d%.,]+%a*)/Click")
							local p = d.Text:match("^([%d%.,]+%a*)%s+Wins Required")
							gain = gain or (g and parseAmount(g))
							price = price or (p and parseAmount(p))
						end
					end
					if gain and price then
						pads[#pads + 1] = { part = part, gain = gain, price = price }
					end
				end
			end
		end
	end
	table.sort(pads, function(a, b) return a.gain > b.gain end)
	-- the pads stream out as soon as the climb goes deep, so the ladder is cached
	-- the moment it IS loaded; without it every cycle warps over there blind
	if #pads > 0 then
		local ladder = {}
		for _, pad in ipairs(pads) do ladder[#ladder + 1] = { gain = pad.gain, price = pad.price } end
		_G.__STRCLICK_PADS = ladder
	end
	return pads
end

-- What the balance qualifies for, answered from the cache so it costs no trip
local function bestAffordablePad()
	local ladder = _G.__STRCLICK_PADS
	if not ladder then return nil end
	local best
	for _, pad in ipairs(ladder) do
		if pad.price <= STATE.wins and (not best or pad.gain > best.gain) then best = pad end
	end
	return best
end

local function upgraderPass()
	local target = bestAffordablePad()
	if target then
		if target.gain <= (STATE.base or 1) then return end
	elseif _G.__STRCLICK_PADS then
		return  -- ladder known and nothing affordable beats what is held
	end
	STATE.phase = "click upgrader"
	pcall(function() plr:RequestStreamingAround(UPGRADER_POS) end)
	local aim = CFrame.new(UPGRADER_POS)
	local stop = pin(function() return aim end)
	task.wait(2)
	local list = boostPads()
	local best
	for _, pad in ipairs(list) do
		if pad.price <= STATE.wins and (not best or pad.gain > best.gain) then best = pad end
	end
	if best then
		local before = plr:GetAttribute("BaseStrength") or 1
		local _, hrp = char()
		if hrp then
			pcall(function()
				firetouchinterest(hrp, best.part, 0)
				task.wait(0.15)
				firetouchinterest(hrp, best.part, 1)
			end)
			task.wait(1.2)
		end
		STATE.base = plr:GetAttribute("BaseStrength") or before
		STATE.pad = "+" .. short(best.gain) .. "/click"
		if STATE.base > before then
			note(string.format("click upgrader %s -> %s (needs %s wins)",
				short(before), short(STATE.base), short(best.price)))
		end
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

-- One cycle, one lock: take the best click-upgrader pad, top the pets up, train at
-- the multiplier, then spend that strength climbing. Everything here wants the
-- body, so they run in order inside a single lock rather than fighting for it;
-- the remote-only spenders (titles, upgrades, auras, rebirth) never take it.
local petAt = 0
-- forward declaration: petPass is defined below with the other spenders, and a
-- local is invisible above its own definition - called from here it resolved to
-- nil and every cycle died in the pcall as a quiet footer note
local petPass

local function cyclePass()
	if STATE.bodyOwner or bodyRequest then return end
	withBody("cycle", function()
		if CONFIG.upgrader then upgraderPass() end
		if CONFIG.pets and os.clock() - petAt > 60 then
			petAt = os.clock()
			petPass()
		end
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
			or (name == "Pet Equip" and not CONFIG.pets)
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

-- The roll TYPE is an argument, and "Neon" is the Robux tier - fired directly it
-- costs nothing at all, which is what produced Reality Breaker (x20 strength, x7
-- wins) in 22 rolls. Titles are owned forever and the server always applies the
-- best owned one, so this only ever moves upward and stops once the top title in
-- the table is held.
local function bestTitle()
	local mod = Config:FindFirstChild("TitleMultipliers")
	mod = mod and mod:FindFirstChild("Chances")
	local ok, chances = pcall(require, mod)
	if not (ok and chances and chances.TitleMultipliers) then return nil end
	local name, mul
	for title, d in pairs(chances.TitleMultipliers) do
		if not mul or (d.strengthMultiplier or 0) > mul then
			name, mul = title, d.strengthMultiplier or 0
		end
	end
	return name, mul
end

local function rollTitles()
	local top, topMul = bestTitle()
	local d = data()
	local owned = 0
	if d and type(d.OwnedTitles) == "table" then
		for _ in pairs(d.OwnedTitles) do owned = owned + 1 end
	end
	STATE.titles = owned
	STATE.title = (d and d.TitleName) or STATE.title
	STATE.titleMul = (d and d.TitleStrengthMultiplier) or STATE.titleMul
	if top and d and d.OwnedTitles and d.OwnedTitles[top] then return end
	if topMul and STATE.titleMul >= topMul then return end
	local before = STATE.titleMul
	for _ = 1, 10 do
		if not (CONFIG.auto and CONFIG.titles) then break end
		fire("TitleRoll", "Neon")
		task.wait(0.9)
	end
	local after = data(true)
	STATE.titleMul = (after and after.TitleStrengthMultiplier) or before
	STATE.title = (after and after.TitleName) or STATE.title
	if STATE.titleMul > before then
		note(string.format("title %s x%.0f str / x%s wins (free)", tostring(STATE.title),
			STATE.titleMul, tostring(after and after.TitleWinMultiplier)))
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

-- Pets are additive: PetMultiplier = 1 + sum of (multiplier - 1) over the two
-- equipped ones. The egg to hatch is the Robux egg, because the server charges its
-- Cost of 99 in WINS - its Nyan Cat is x3.2 against x1.6 from the 500-wins Basic
-- egg and x7.5 from the 500-MILLION Desert egg. Hatching is position gated, the
-- amount is capped at 10 a call, and three identical pets craft into one of the
-- next tier at x1.5.
local function petList()
	local remote = Remotes:FindFirstChild("GetPets")
	if not remote then return {} end
	local ok, pets = pcall(function() return remote:InvokeServer() end)
	return (ok and type(pets) == "table") and pets or {}
end

local function changePet(id, action)
	local remote = Remotes:FindFirstChild("ChangePet")
	if not remote then return nil end
	local ok, a, b = pcall(function() return remote:InvokeServer(id, action) end)
	if not ok then return nil end
	return a, b
end

local function eggPlan()
	local folder = workspace:FindFirstChild("Eggs")
	local stand
	if folder then
		for _, name in ipairs({ "Basic", "Ocean", "Blossom", "Desert" }) do
			local model = folder:FindFirstChild(name)
			if model then stand = model break end
		end
	end
	-- the Robux egg has no model in the world; standing at any egg is enough
	local best, bestMul = "Robux", 0
	for _, pet in ipairs((Eggs.Robux or {}).Pets or {}) do
		bestMul = math.max(bestMul, tonumber(pet.BestPetMultiplier) or tonumber(pet.Multiplier) or 0)
	end
	local cost = tonumber((Eggs.Robux or {}).Cost) or 99
	return stand, best, cost, bestMul
end

function petPass()
	local pets = petList()
	STATE.pets = #pets
	STATE.petMul = plr:GetAttribute("PetMultiplier") or STATE.petMul

	-- craft first: it frees two slots per triple and raises the ceiling
	if #pets > 0 then
		local groups = {}
		for _, p in ipairs(pets) do
			if not p.Equipped then
				local key = tostring(p.Name) .. "#" .. tostring(p.Tier or 1)
				groups[key] = groups[key] or {}
				table.insert(groups[key], p)
			end
		end
		for _, group in pairs(groups) do
			if #group >= 3 then
				changePet(group[1].ID, "Craft")
				task.wait(0.6)
			end
		end
	end

	local maxStorage = plr:GetAttribute("MaxStorage") or 50
	local stand, egg, cost, top = eggPlan()
	local room = maxStorage - (plr:GetAttribute("PetStorage") or #pets)

	-- clear space by deleting the weakest unequipped pets, never an equipped one
	if room < 12 then
		local junk = {}
		for _, p in ipairs(petList()) do
			if not p.Equipped then junk[#junk + 1] = p end
		end
		table.sort(junk, function(a, b) return (a.Multiplier or 0) < (b.Multiplier or 0) end)
		for i = 1, math.min(#junk, 12 - room) do
			changePet(junk[i].ID, "Delete")
			task.wait(0.25)
		end
		room = maxStorage - (plr:GetAttribute("PetStorage") or 0)
	end

	local left = budget(STATE.petSpent, CONFIG.petShare)
	local batch = math.min(10, math.floor(room))
	if not stand or batch < 1 or left < cost or not canSpend(cost * batch) then
		changePet(nil, "EquipBest")
		return
	end
	local part = zonePart(stand)
	if not part then return end
	STATE.phase = "hatching " .. egg
	local aim = CFrame.new(part.Position + Vector3.new(0, 5, 0))
	local stop = pin(function() return aim end)
	task.wait(1.2)
	local remote = Remotes:FindFirstChild("HatchPet")
	local before = plr:GetAttribute("PetMultiplier") or 1
	if remote then
		pcall(function() remote:FireServer(egg, batch, {}) end)
		task.wait(2.5)
	end
	STATE.petSpent = STATE.petSpent + cost * batch
	changePet(nil, "EquipBest")
	task.wait(1)
	stop()
	STATE.petMul = plr:GetAttribute("PetMultiplier") or before
	STATE.pets = #petList()
	if STATE.petMul > before then
		note(string.format("pets x%.2f -> x%.2f (%s wins, top x%s)", before, STATE.petMul,
			short(cost * batch), tostring(top)))
	end
end

-- A roll REPLACES the worn aura, but the server only APPLIES it once the client
-- sends RollVisualFinished - the result arrives on RollVisual first. So the roll
-- is previewed and only the best entry in the pack is confirmed; everything else
-- is simply not acknowledged and the worn aura stays. Each roll is still charged,
-- which is what six unconfirmed rolls (6000 wins for nothing) made obvious.
local function rollAura()
	local mod = Config:FindFirstChild("AuraMultipliers")
	mod = mod and mod:FindFirstChild("Chances")
	local ok, chances = pcall(require, mod)
	if not (ok and chances and chances.Packs) then return end
	local pack = plr:GetAttribute("CurrentPack") or 1
	local entry = chances.Packs[pack]
	local table_ = chances.AuraMultipliers and chances.AuraMultipliers[pack]
	if not (entry and entry.currency == "Wins" and table_) then return end

	local want, wantMul = nil, 0
	for name, d in pairs(table_) do
		if (d.multiplier or 0) > wantMul then want, wantMul = name, d.multiplier or 0 end
	end
	if not want then return end
	if (plr:GetAttribute("AuraName") or "") == want then return end

	local last
	local conn = Events.RollVisual.OnClientEvent:Connect(function(name, mul, _, smul)
		last = { name = name, mul = mul, smul = smul }
	end)
	local rolled = 0
	for _ = 1, math.max(1, CONFIG.auraRolls) do
		if not (CONFIG.auto and CONFIG.auras) or not canSpend(entry.price) then break end
		last = nil
		fire("Roll", "Normal", pack)
		rolled = rolled + 1
		local deadline = os.clock() + 3
		repeat task.wait(0.1) until last or os.clock() > deadline
		if last and last.name == want then
			fire("RollVisualFinished")
			task.wait(1.2)
			break
		end
		task.wait(0.3)
	end
	conn:Disconnect()
	STATE.aura = plr:GetAttribute("AuraName") or STATE.aura
	STATE.auraMul = plr:GetAttribute("AuraMultiplier") or STATE.auraMul
	if STATE.aura == want then
		note(string.format("aura %s x%s wins after %d rolls", want, tostring(STATE.auraMul), rolled))
	end
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
	-- free first, then cheap, then the bank
	if CONFIG.titles then rollTitles() end
	if CONFIG.upgrades then buyUpgrades() end
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
spend:Toggle("Click upgrader", CONFIG.upgrader, function(v) CONFIG.upgrader = v end,
	"free: the wins figure on a pad is a requirement, not a price", UI.theme.good)
spend:Toggle("Free title rolls", CONFIG.titles, function(v) CONFIG.titles = v end,
	"fires the Neon (Robux) roll type, which costs nothing - up to x20", UI.theme.good)
spend:Toggle("Pets", CONFIG.pets, function(v) CONFIG.pets = v end,
	"Robux egg is charged in WINS (99); crafts triples, equips best", UI.theme.warn)
spend:Stepper("Pet budget", function()
	return math.floor(CONFIG.petShare * 100) .. "%"
end, function(dir)
	CONFIG.petShare = math.clamp(CONFIG.petShare + dir * 0.05, 0, 1)
end, "share of everything earned this session that may go into eggs")
spend:Toggle("Buy upgrades", CONFIG.upgrades, function(v) CONFIG.upgrades = v end,
	"cheapest useful first; Punch Speed stops at level 10, the cooldown caps it",
	UI.theme.warn)
spend:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"banks to the next training milestone, then converts in one go", UI.theme.warn)
spend:Stepper("Rebirth until", function()
	return CONFIG.rebirthUntil == 0 and "no limit" or short(CONFIG.rebirthUntil)
end, function(dir)
	local steps = { 0, 1, 25, 200, 5000, 100000, 10000000 }
	local at = 1
	for i, v in ipairs(steps) do if v == CONFIG.rebirthUntil then at = i end end
	CONFIG.rebirthUntil = steps[math.clamp(at + dir, 1, #steps)]
end, "past the x15 zone a rebirth costs more click-upgrader than it returns")

local extra = page:Card("EXTRAS", 1)
extra:Toggle("Training zone", CONFIG.training, function(v) CONFIG.training = v end,
	"parks in the best zone the rebirths allow; a locked one would set it to x1",
	UI.theme.good)
extra:Toggle("Free rewards", CONFIG.freebies, function(v) CONFIG.freebies = v end,
	"codes, daily, offline earnings and the free potion", UI.theme.good)
extra:Toggle("Roll auras", CONFIG.auras, function(v) CONFIG.auras = v end,
	"previews each roll and only confirms the best in the pack, so no downgrade",
	UI.theme.warn)
extra:Stepper("Aura rolls", function() return tostring(CONFIG.auraRolls) end, function(dir)
	CONFIG.auraRolls = math.clamp(CONFIG.auraRolls + dir, 1, 40)
end, "rolls per pass while hunting; each one is charged whether kept or not")
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
			"  per click " .. short(STATE.perClick) .. "   base " .. short(STATE.base),
			"  wins      " .. short(STATE.wins) .. "   " .. short(STATE.winRate) .. "/s",
			"  pad       " .. tostring(STATE.pad) .. "   level " .. STATE.level,
			"  lane      " .. STATE.lane .. "   deepest Lane" .. STATE.deepest,
			"  rebirths  " .. short(STATE.rebirths)
				.. (target and ("   next at " .. short(target) .. " wins") or "   maxed"),
			"  training  x" .. tostring(STATE.training) .. "   " .. tostring(STATE.zone),
			"  title     x" .. string.format("%.2f", STATE.titleMul)
				.. "   " .. STATE.titles .. " owned",
			"  aura      " .. tostring(STATE.aura) .. "   x" .. tostring(STATE.auraMul),
			"  pets      " .. STATE.pets .. "   x" .. string.format("%.2f", STATE.petMul),
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
	petPass = petPass, petList = petList, changePet = changePet, eggPlan = eggPlan,
	rollAura = rollAura, freePass = freePass, bestTitle = bestTitle,
	boostPads = boostPads, upgraderPass = upgraderPass, parseAmount = parseAmount,
	bestAffordablePad = bestAffordablePad,
	SUFFIX = SUFFIX,
	spendPass = spendPass, startClicker = startClicker,
	BaseConfig = BaseConfig, MinStrength = MinStrength, Eggs = Eggs,
}

print("[strengthclick] gen " .. GEN .. " ready - RightShift for the panel")
