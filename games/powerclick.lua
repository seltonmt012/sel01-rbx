--[[ powerclick.lua - "[2X] +1 Power Per Click" (place 74889851913797)

  The loop the game actually runs:

      click -> Strength -> break walls in the cave -> cash out at a zone pad -> Wins
      Wins -> upgrades, swords -> more damage -> deeper walls -> more Wins

  Everything below was measured through the bridge before it was written down; the
  numbers live in CLAUDE.md. The three that shape this file:

  * ClickTrainEvent:FireServer() takes no arguments and the server throttles it.
    5 calls/s gave 8 strength/s, 20/s gave 10/s, 60/s gave 13/s - and three calls
    per frame (14/s) barely beat one per frame (12/s). So one call per Heartbeat
    is the entire budget and anything faster is wasted work.
  * Both halves are position-gated against the SERVER's copy of the position.
    350 wall hits from 20 studs away moved the cursor by zero. Pinned to the wall
    it went 3 -> 21 in twelve seconds.
  * The cashout pad resets CaveWall to 1. So cashing early throws the run away,
    and wall value explodes with depth (xp 5 at wall 10, 978 at wall 25, 113908 at
    wall 50). The run therefore ends on a STALL, not on a timer.

  Never spends Robux: CavePad2x_* pads, PassId training pads, GamepassId sword
  stands, every robuxPrice button, the Galaxy Egg and the rebirth-skip products
  are all filtered out by attribute, not by name.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local plr = Players.LocalPlayer

local GEN = (_G.__POWERCLICK or 0) + 1
_G.__POWERCLICK = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,
	click = true,          -- one ClickTrainEvent per Heartbeat, on the best pad
	trainPad = true,       -- stand on the strongest pad the rebirth count allows
	cave = true,           -- break walls and cash the run in
	upgrades = true,       -- buy the best wins upgrade, damage first
	swords = true,         -- stand on the pedestal of the best affordable sword
	rebirth = true,        -- rebirth as soon as the level allows it
	-- Off, and honestly so: hatching is position-gated and the pet pools were read
	-- but never verified against a server value. Turn it on once that is measured.
	eggs = false,
	trainSeconds = 45,     -- how long to train before going back into the cave
	caveSeconds = 90,      -- hard cap on one cave run
	stallSeconds = 8,      -- no wall progress for this long -> cash the run in
	hitGap = 0.03,         -- seconds between wall hits
	rebirthUntil = 0,      -- 0 = no limit
	spendEvery = 20,       -- seconds between spending passes
}

local STATE = {
	phase = "idle",
	note = "",
	strength = 0, wins = 0, level = 0, rebirths = 0,
	rate = 0,              -- strength per second, measured
	pad = "-", padMult = 1,
	wall = 1, deepest = 1,
	sword = 1, swordName = "-",
	runs = 0, cashed = 0,  -- cave runs finished, wins banked by this session
	busy = false, uiOwner = nil,
}

--------------------------------------------------------------------------------
-- small helpers (kept above every caller on purpose - a local is invisible above
-- its own definition, and inside pcall that surfaces as a quiet note, not a crash)
--------------------------------------------------------------------------------

local function short(n)
	n = tonumber(n) or 0
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if math.abs(n) >= u[1] then
			return string.format("%.2f%s", n / u[1], u[2])
		end
	end
	return string.format("%d", n)
end

local function value(name, default)
	local v = plr:FindFirstChild(name)
	if v and (v:IsA("NumberValue") or v:IsA("IntValue") or v:IsA("StringValue")) then
		return v.Value
	end
	return default
end

local function remote(name)
	return ReplicatedStorage:FindFirstChild(name)
end

local function char()
	local model = plr.Character
	if not model then return nil, nil, nil end
	return model, model:FindFirstChild("HumanoidRootPart"), model:FindFirstChildOfClass("Humanoid")
end

-- Pins the character on Heartbeat and returns a stop function. Everything in this
-- game is validated against the server's own copy of the position, and a single
-- CFrame write is not enough - see the 350 wasted wall hits in the header.
local function pin(getPos)
	local stop = false
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if stop or GEN ~= _G.__POWERCLICK then
			conn:Disconnect()
			return
		end
		local _, hrp = char()
		local pos = getPos()
		if hrp and pos then
			hrp.CFrame = CFrame.new(pos)
		end
	end)
	return function()
		stop = true
		pcall(function() conn:Disconnect() end)
	end
end

local function note(text)
	STATE.note = text
end

-- One interface lock. Two routines opening windows at once is how a panel ends up
-- fighting itself, and it made cleanup look random in earlier games.
local function withUI(name, fn)
	if STATE.busy then return false, "busy" end
	STATE.busy, STATE.uiOwner = true, name
	local ok, err = pcall(fn)
	STATE.busy, STATE.uiOwner = false, nil
	if not ok then note(name .. " failed: " .. tostring(err)) end
	return ok, err
end

local wallConfig
do
	local ok, cfg = pcall(require, ReplicatedStorage:FindFirstChild("WallConfig"))
	wallConfig = ok and cfg or nil
end

local function ownsPass(id)
	if not id then return true end
	local ok, owned = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(plr.UserId, id)
	end)
	return ok and owned or false
end

--------------------------------------------------------------------------------
-- state refresh
--------------------------------------------------------------------------------

-- There is NO Rebirths value on the Player - Strength, Wins and Level are there,
-- but the rebirth count only exists in the remote's reply. Reading it as a Player
-- value returns the default forever, which silently pinned the pad choice to the
-- weakest pad while two rebirths had already happened.
local rebirthCache, rebirthCachedAt = nil, 0

local function rebirthState(force)
	if not force and rebirthCache and os.clock() - rebirthCachedAt < 10 then
		return rebirthCache
	end
	local fn = remote("RebirthFunction")
	if not fn then return nil end
	local ok, state = pcall(function() return fn:InvokeServer("GetState") end)
	if ok and type(state) == "table" then
		rebirthCache, rebirthCachedAt = state, os.clock()
	end
	return rebirthCache
end

local function refresh()
	STATE.strength = value("Strength", 0)
	STATE.wins = value("Wins", 0)
	STATE.level = value("Level", 0)
	STATE.sword = value("EquippedDumbbellPower", 1)
	STATE.wall = plr:GetAttribute("CaveWall") or 1
	if STATE.wall > STATE.deepest then STATE.deepest = STATE.wall end
	local state = rebirthState()
	if state then
		STATE.rebirths = tonumber(state.Rebirths) or STATE.rebirths
		STATE.needLevel = tonumber(state.NextRequirement)
		STATE.multiplier = tonumber(state.RebirthMultiplier)
	end
end

--------------------------------------------------------------------------------
-- training: the click half
--------------------------------------------------------------------------------

-- Pads are BaseParts carrying Multiplier / RebirthReq / PassId. The NAME LIES:
-- TrainingPad_x100 has Multiplier = 75, so the attribute is the only truth.
local function trainingPads()
	local found = {}
	local area = workspace:FindFirstChild("PrototypeTrainingArea")
	if not area then return found end
	for _, d in ipairs(area:GetDescendants()) do
		if d:IsA("BasePart") and d.Name:find("TrainingPad") and not d.Name:find("_Base") then
			found[#found + 1] = {
				part = d,
				mult = tonumber(d:GetAttribute("Multiplier")) or 1,
				req = tonumber(d:GetAttribute("RebirthReq")) or 0,
				pass = d:GetAttribute("PassId"),
			}
		end
	end
	return found
end

local function bestPad()
	local best
	for _, pad in ipairs(trainingPads()) do
		if pad.req <= STATE.rebirths and (not pad.pass or ownsPass(pad.pass)) then
			if not best or pad.mult > best.mult then best = pad end
		end
	end
	return best
end

local function trainPhase(seconds)
	local ev = remote("ClickTrainEvent")
	if not ev then note("no ClickTrainEvent") return end

	local pad = CONFIG.trainPad and bestPad() or nil
	STATE.pad = pad and pad.part.Name or "none"
	STATE.padMult = pad and pad.mult or 1

	local unpin
	if pad then
		unpin = pin(function() return pad.part.Position + Vector3.new(0, 3, 0) end)
		task.wait(1)                       -- let the server catch up before the first call
	end

	local startStrength, t0 = value("Strength", 0), os.clock()
	local conn = RunService.Heartbeat:Connect(function()
		-- one per frame saturates the server's cooldown; more is thrown away
		pcall(function() ev:FireServer() end)
	end)

	while os.clock() - t0 < seconds and CONFIG.auto and CONFIG.click and GEN == _G.__POWERCLICK do
		task.wait(0.5)
		local dt = os.clock() - t0
		STATE.rate = dt > 0 and (value("Strength", 0) - startStrength) / dt or 0
		refresh()
		note(string.format("training on %s x%s   %s str/s",
			STATE.pad, tostring(STATE.padMult), short(STATE.rate)))
	end

	pcall(function() conn:Disconnect() end)
	if unpin then unpin() end
end

--------------------------------------------------------------------------------
-- the cave: the wins half
--------------------------------------------------------------------------------

local function cashPads()
	local pads = {}
	local cave = workspace:FindFirstChild("CaveWorld")
	local folder = cave and cave:FindFirstChild("Pads")
	if not folder then return pads end
	for _, d in ipairs(folder:GetDescendants()) do
		-- Is2x marks the Robux twin. Filter on the attribute, never on the name.
		if d:IsA("BasePart") and d:GetAttribute("Is2x") == false then
			pads[d.Name] = d
		end
	end
	return pads
end

-- A pad pays for COMPLETED zones only. Measured: cursor 40 (zone 4 opened but not
-- finished) paid nothing at the zone 4 pad and left the cursor untouched, while
-- cursor 17 -> zone 1 and cursor 21 -> zone 2 both paid and reset it. With ten
-- walls per zone the last finished zone is floor((cursor - 1) / WALLS_PER_ZONE).
local function completedZone(cursor)
	local per = (wallConfig and tonumber(wallConfig.WALLS_PER_ZONE)) or 10
	return math.floor((math.max(1, cursor) - 1) / per)
end

local function cashOut(cursor)
	local pads = cashPads()
	local zone = completedZone(cursor)
	if zone < 1 then
		note("nothing finished yet - not cashing")
		return 0
	end

	local before = value("Wins", 0)
	-- Walk down until one actually pays: a zone can be finished and its pad still
	-- refuse, and the reset is what proves the cashout landed.
	while zone >= 1 do
		local pad = pads["CavePad_Z" .. tostring(zone)]
		if pad then
			local unpin = pin(function() return pad.Position + Vector3.new(0, 3, 0) end)
			task.wait(2.5)                -- standing pays; no touch call is needed
			unpin()
			local gained = value("Wins", 0) - before
			if gained > 0 or (plr:GetAttribute("CaveWall") or 1) == 1 then
				STATE.cashed = STATE.cashed + gained
				STATE.runs = STATE.runs + 1
				return gained, zone
			end
		end
		zone = zone - 1
	end
	STATE.runs = STATE.runs + 1
	return 0, 0
end

local function cavePhase()
	local ev = remote("CaveHitEvent")
	if not (ev and wallConfig) then note("no cave") return end

	local unpin = pin(function()
		local n = plr:GetAttribute("CaveWall") or 1
		local ok, z = pcall(wallConfig.wallZ, n)
		if not ok then return nil end
		return Vector3.new(wallConfig.X, wallConfig.FLOOR_TOP + 4, z - 6)
	end)
	task.wait(1)

	local t0 = os.clock()
	local lastWall = plr:GetAttribute("CaveWall") or 1
	local lastMove = os.clock()

	while CONFIG.auto and CONFIG.cave and GEN == _G.__POWERCLICK do
		pcall(function() ev:FireServer() end)
		task.wait(CONFIG.hitGap)

		local now = plr:GetAttribute("CaveWall") or 1
		if now ~= lastWall then
			lastWall, lastMove = now, os.clock()
			if now > STATE.deepest then STATE.deepest = now end
			STATE.wall = now
			note("cave wall " .. now .. "   hp " ..
				short(select(2, pcall(wallConfig.wallHp, now)) or 0))
		end

		-- The run ends on a STALL, never on a fixed depth: the pad resets the
		-- cursor, so quitting while walls are still falling throws away the part
		-- of the run that is worth the most.
		if os.clock() - lastMove > CONFIG.stallSeconds then
			note("wall " .. lastWall .. " will not fall - cashing in")
			break
		end
		if os.clock() - t0 > CONFIG.caveSeconds then
			note("cave time up at wall " .. lastWall)
			break
		end
	end

	unpin()
	local gained, zone = cashOut(lastWall)
	refresh()
	note(string.format("run %d: wall %d, zone %d, +%s wins",
		STATE.runs, lastWall, zone or 0, short(gained)))
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

-- Damage and Click Power are the two that feed the loop: damage decides how deep
-- the walls fall, click power decides how fast strength arrives. Everything else
-- is bought only once those two are out of reach.
local UPGRADE_ORDER = { "damage", "clickPower", "attackSpeed", "wins", "walkSpeed" }

local function buyUpgrades()
	local fn = remote("UpgradeFunction")
	if not fn then return end
	local ok, reply = pcall(function() return fn:InvokeServer("GetState") end)
	if not (ok and reply and reply.upgrades or (reply and reply.state)) then return end
	local state = reply.state or reply
	local rows = {}
	for _, row in ipairs(state.upgrades or {}) do rows[row.id] = row end

	local wins = tonumber(state.wins) or value("Wins", 0)
	for _, id in ipairs(UPGRADE_ORDER) do
		local row = rows[id]
		-- The reply carries robuxPrice on every row; the wins path is the "Buy"
		-- action and the cost field, so nothing here can reach a Robux prompt.
		if row and not row.maxed and tonumber(row.cost) and tonumber(row.cost) <= wins then
			local bought, out = pcall(function() return fn:InvokeServer("Buy", id) end)
			if bought and out and out.success then
				wins = (out.state and tonumber(out.state.wins)) or (wins - row.cost)
				note("upgrade " .. (row.name or id) .. " -> lvl " .. tostring((row.level or 0) + 1))
				return true
			end
		end
	end
	return false
end

local function swordStands()
	local stands = {}
	local folder = workspace:FindFirstChild("ShopStands")
	if not folder then return stands end
	for _, m in ipairs(folder:GetChildren()) do
		local cost = tonumber(m:GetAttribute("SwordCost"))
		local power = tonumber(m:GetAttribute("SwordPower"))
		if cost and power then
			stands[#stands + 1] = {
				model = m, cost = cost, power = power,
				pass = m:GetAttribute("GamepassId"),
			}
		end
	end
	return stands
end

local function buyBestSword()
	local best
	for _, stand in ipairs(swordStands()) do
		-- A gamepass stand shows SwordCost 0, which would otherwise read as free.
		if not stand.pass and stand.power > STATE.sword and stand.cost <= STATE.wins then
			if not best or stand.power > best.power then best = stand end
		end
	end
	if not best then return false end

	local ped = best.model:FindFirstChild("ShopPedestal", true)
	if not ped then return false end
	local pos = ped:IsA("BasePart") and ped.Position or ped:GetPivot().Position
	local before = STATE.sword
	local unpin = pin(function() return pos + Vector3.new(0, 3, 0) end)
	task.wait(4)                          -- the stand hands it over while you stand there
	unpin()
	refresh()
	if STATE.sword > before then
		STATE.swordName = best.model.Name
		note("sword " .. best.model.Name .. "   power " .. short(STATE.sword))
		return true
	end
	return false
end

local function doRebirth()
	local fn = remote("RebirthFunction")
	if not fn then return false end
	local state = rebirthState(true)
	if not state then return false end
	local before = tonumber(state.Rebirths) or 0
	if CONFIG.rebirthUntil > 0 and before >= CONFIG.rebirthUntil then return false end
	if not state.CanRebirth then return false end

	-- "Rebirth" exactly. The same client script holds five Robux skip products.
	pcall(function() return fn:InvokeServer("Rebirth") end)
	task.wait(1)
	-- The call answering without error proves nothing; only the count moving does.
	local after = rebirthState(true)
	local now = after and tonumber(after.Rebirths) or before
	if now > before then
		STATE.deepest = 1
		refresh()
		note("rebirth " .. now .. "   multiplier x" .. tostring(STATE.multiplier or "?"))
		return true
	end
	note("rebirth refused at level " .. tostring(STATE.level))
	return false
end

local function spendPass()
	withUI("spend", function()
		refresh()
		if CONFIG.rebirth then doRebirth() end
		if CONFIG.upgrades then buyUpgrades() end
		if CONFIG.swords then buyBestSword() end
	end)
end

--------------------------------------------------------------------------------
-- the cycle
--------------------------------------------------------------------------------

task.spawn(function()
	local lastSpend = 0
	while GEN == _G.__POWERCLICK do
		if CONFIG.auto then
			refresh()
			if os.clock() - lastSpend > CONFIG.spendEvery then
				STATE.phase = "spend"
				spendPass()
				lastSpend = os.clock()
			end
			if CONFIG.click then
				STATE.phase = "train"
				trainPhase(CONFIG.trainSeconds)
			end
			if CONFIG.cave and CONFIG.auto then
				STATE.phase = "cave"
				cavePhase()
			end
			if not (CONFIG.click or CONFIG.cave) then task.wait(1) end
		else
			STATE.phase = "stopped"
			task.wait(0.5)
		end
	end
end)

task.spawn(function()
	while GEN == _G.__POWERCLICK do
		refresh()
		task.wait(1)
	end
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__POWERCLICK_WIN then pcall(function() _G.__POWERCLICK_WIN:Destroy() end) end

local win = UI.Window({
	title = "POWER", accentTitle = "CLICK", subtitle = "seltonmt",
	badge = "⚔", width = 920, height = 580,
})
_G.__POWERCLICK_WIN = win

local page = win:Page("FARM", UI.icon.bolt)

local main = page:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	note(v and "running" or "stopped")
end, "train, break walls, cash in, spend, repeat", UI.theme.good)
main:Toggle("Click", CONFIG.click, function(v) CONFIG.click = v end,
	"one call per frame; the server caps it at ~13 str/s")
main:Toggle("Best training pad", CONFIG.trainPad, function(v) CONFIG.trainPad = v end,
	"strongest pad the rebirth count allows, gamepass pads skipped")
main:Toggle("Break walls", CONFIG.cave, function(v) CONFIG.cave = v end,
	"pins to the current wall - hits from further away count for nothing")
main:Stepper("Train for", function() return CONFIG.trainSeconds .. "s" end, function(dir)
	CONFIG.trainSeconds = math.clamp(CONFIG.trainSeconds + dir * 15, 15, 300)
end, "seconds of clicking before each cave run")
main:Stepper("Stall limit", function() return CONFIG.stallSeconds .. "s" end, function(dir)
	CONFIG.stallSeconds = math.clamp(CONFIG.stallSeconds + dir * 2, 2, 60)
end, "no wall progress for this long ends the run and cashes it in")

local spend = page:Card("SPENDING", 2)
spend:Toggle("Buy upgrades", CONFIG.upgrades, function(v) CONFIG.upgrades = v end,
	"damage and click power first, wins path only", UI.theme.warn)
spend:Toggle("Buy swords", CONFIG.swords, function(v) CONFIG.swords = v end,
	"stands on the pedestal of the best affordable sword", UI.theme.warn)
spend:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"resets level, unlocks the stronger training pads", UI.theme.warn)
spend:Stepper("Rebirth until", function()
	return CONFIG.rebirthUntil == 0 and "no limit" or tostring(CONFIG.rebirthUntil)
end, function(dir)
	CONFIG.rebirthUntil = math.clamp(CONFIG.rebirthUntil + dir, 0, 300)
end, "stop rebirthing at this count")
spend:Button("Unstuck", function()
	CONFIG.auto = false
	STATE.busy = false
	local _, _, hum = char()
	if hum then pcall(function() hum.PlatformStand = false hum.WalkSpeed = 25 end) end
	note("unstuck, auto off")
end, UI.theme.bad)

local out = page:Card("STATUS", 0):Readout(10, function(text)
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__POWERCLICK do
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase    " .. tostring(STATE.phase),
			"  strength " .. short(STATE.strength) .. "   " .. short(STATE.rate) .. "/s",
			"  wins     " .. short(STATE.wins) .. "   banked " .. short(STATE.cashed),
			"  level    " .. STATE.level .. "   rebirths " .. STATE.rebirths,
			"  pad      " .. tostring(STATE.pad) .. "   x" .. tostring(STATE.padMult),
			"  wall     " .. STATE.wall .. "   deepest " .. STATE.deepest,
			"  sword    " .. short(STATE.sword) .. "   " .. tostring(STATE.swordName),
			"  runs     " .. STATE.runs,
			"  " .. tostring(STATE.note),
		}
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s str   %s wins   reb %d   wall %d   %s",
				short(STATE.strength), short(STATE.wins), STATE.rebirths, STATE.wall, STATE.phase))
		end)
		task.wait(0.5)
	end
end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__POWERCLICK_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	refresh = refresh, short = short, pin = pin,
	trainingPads = trainingPads, bestPad = bestPad, trainPhase = trainPhase,
	cashPads = cashPads, cashOut = cashOut, cavePhase = cavePhase,
	buyUpgrades = buyUpgrades, swordStands = swordStands, buyBestSword = buyBestSword,
	doRebirth = doRebirth, spendPass = spendPass,
	wallConfig = wallConfig,
}

print("[powerclick] gen " .. GEN .. " ready - RightShift for the panel")
